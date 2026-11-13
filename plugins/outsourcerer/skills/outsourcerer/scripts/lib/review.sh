#!/usr/bin/env bash
# lib/review.sh -- the single-reviewer queue. Sourced by outsourcerer.sh; functions only.
#
#   review queue add <lane-or-branch> [--brief FILE] [--repo R] | queue ls
#   review reviewer [<tmux-session> [--replace]]    set / show THE reviewer
#   review next [--force]       send the oldest queued item to the reviewer (one in flight, ever)
#   review show <item> | ack <item> | requeue <item> | drop <item> | sendback <item> | rotate | events
#
# Item = $OSRC_HOME/review/items/<lane>-<sha7>.json, created atomically (dedupe by lane + head sha).
# Verdict contract (item fields): sha_at_ready (the head we queued), sha_reviewed (the head the
# reviewer was briefed on and judged), verdict (MERGE|CHANGES|BLOCK), findings (path of the verdict
# file, body below its first line). A push after READY supersedes a queued review of the old sha and
# marks an in-flight or finished one `stale`, so an old MERGE can never be mistaken for the new head.
# Nothing here merges anything. Merging stays with the orchestrator; this only surfaces it.
#
# Send-back channel for lanes that cannot receive `session send` (cloud sessions): CHANGES/BLOCK
# verdicts print a NEXT of `review sendback <item>`, which writes review/REVIEW-<sha7>.md and prints a
# ready-to-relay message for the orchestrator to deliver however that lane takes input. Chosen over
# pushing a review/<lane> ref because a push is outward-facing and needs write access to a branch a
# cloud lane may own or protect; the orchestrator is already the relay, and a local file cannot fail
# on credentials at 03:00.

_osrc_rv_dir() { printf '%s/review' "$OSRC_HOME"; }
_osrc_rv_item() { printf '%s/review/items/%s.json' "$OSRC_HOME" "$1"; }

_osrc_review_reviewer() { local f="$OSRC_HOME/review/reviewer.json"; [ -f "$f" ] && jq -r '.session // ""' "$f" 2>/dev/null; }

# ---- reading the reviewer's screen ------------------------------------------------------------
# Prefers L3's osrc_screen_state when present. Until then a conservative wrapper: only a clearly
# empty composer with no spinner in the last lines counts as idle. Unknown never sends.
_osrc_review_screen() { # <session> -> idle|working|approval|unknown (first word only)
  local s="$1" st text tail_text
  if type osrc_screen_state >/dev/null 2>&1; then
    st="$(osrc_screen_state "$s" 2>/dev/null | head -1)"
    case "$st" in
      idle|composer) printf idle ;;
      working) printf working ;;
      approval|question) printf approval ;;
      *) printf unknown ;;
    esac
    return 0
  fi
  text="$(tmux capture-pane -p -t "$s" 2>/dev/null)" || { printf unknown; return 0; }
  tail_text="$(printf '%s\n' "$text" | grep -v '^[[:space:]]*$' | tail -n 14)"
  [ -n "$tail_text" ] || { printf unknown; return 0; }
  if printf '%s\n' "$tail_text" | grep -qE '\[y/N\]|\(y/n\)|Do you want to (proceed|continue|make)|❯[[:space:]]*[0-9]+\.[[:space:]]*Yes|Press enter to confirm'; then printf approval; return 0; fi
  if printf '%s\n' "$tail_text" | grep -qE 'esc to interrupt|^[[:space:]]*[✻✽✶✳✢·*⏺] [A-Za-zé]+… \(|[0-9]+[smh] · [↓↑]|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏'; then printf working; return 0; fi
  if printf '%s\n' "$tail_text" | grep -qE '^[[:space:]]*❯[[:space:]]*$'; then printf idle; return 0; fi
  printf unknown
}

_osrc_review_ctx_pct() { # <session> -> context-bar percent from the Claude Code footer, or empty
  tmux capture-pane -p -t "$1" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 6 \
    | grep -oE '[█▓▒░]{5,} *[0-9]{1,3}%' | tail -1 | grep -oE '[0-9]{1,3}%' | tr -d '%'
}

# ---- sending -----------------------------------------------------------------------------------
# Managed sessions (started with `session start`) go through the vetted send path. Anything else is a
# plain tmux pane: type literally, Enter, then prove the text left the composer (one Enter retry).
_osrc_review_send() { # <session> <one-line message>
  local s="$1" m="$2" probe tail_text i rc
  if type _managed_endpoint_live >/dev/null 2>&1 && _managed_endpoint_live "$s" "$s" 2>/dev/null; then
    _managed_session_send "$s" "$m"; rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; return
  fi
  tmux has-session -t "=$s" 2>/dev/null || return 1
  probe="$(printf '%s' "$m" | cut -c1-24)"
  tmux send-keys -t "$s" -l -- "$m" || return 1
  sleep "${OSRC_REVIEW_SEND_PAUSE:-0.3}"
  for i in 1 2; do
    tmux send-keys -t "$s" Enter || return 1
    sleep "${OSRC_REVIEW_SEND_PAUSE:-0.3}"
    tail_text="$(tmux capture-pane -p -t "$s" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 8)"
    # still sitting typed in the composer line? then Enter was eaten; try once more
    printf '%s\n' "$tail_text" | grep -qF "❯ $probe" || return 0
  done
  return 1
}

# ---- items -------------------------------------------------------------------------------------
_osrc_review_items() { local p; for p in "$OSRC_HOME"/review/items/*.json; do [ -f "$p" ] && printf '%s\n' "$p"; done; }

# _osrc_review_enqueue <lane> <head> [brief] [source]: atomic create-or-skip. 0 created, 1 existed.
_osrc_review_enqueue() {
  local lane="$1" head="$2" brief="${3:-}" src="${4:-manual}" sha7 id f lf branch url transport base now rer=false
  sha7="${head:0:7}"; id="$lane-$sha7"; f="$(_osrc_rv_item "$id")"
  mkdir -p "$OSRC_HOME/review/items" || return 1
  _osrc_review_item_exists_for_lane "$lane" && rer=true   # before we create our own file
  if ( set -C; : > "$f" ) 2>/dev/null; then :; else return 1; fi
  lf="$(_osrc_lane_json "$lane")"; now="$(_osrc_now)"
  if [ -f "$lf" ]; then
    branch="$(jq -r .branch "$lf")"; url="$(jq -r .url "$lf")"; transport="$(jq -r .transport "$lf")"; base="$(jq -r '.base // "main"' "$lf")"
    [ -n "$brief" ] || brief="$(jq -r '.brief // ""' "$lf")"
  else
    branch="${_OSRC_RV_BRANCH:-$lane}"; url="${_OSRC_RV_URL:-}"; transport="${_OSRC_RV_TRANSPORT:-git}"; base="${_OSRC_RV_BASE:-main}"
  fi
  jq -n --arg id "$id" --arg lane "$lane" --arg head "$head" --arg branch "$branch" --arg url "$url" --arg tr "$transport" \
    --arg base "$base" --arg brief "$brief" --arg src "$src" --argjson now "$now" --argjson rer "$rer" '
    {id:$id, lane:$lane, branch:$branch, url:$url, transport:$tr, base:$base, brief:$brief, source:$src,
     sha_at_ready:$head, sha_reviewed:"", head:$head, state:"queued", enq_ts:$now, sent_ts:0, rereview:$rer,
     verdict:"", verdict_ts:0, findings:"", stale:false, stale_by:"", acked:false, invalid_first_line:""}' > "$f.new" \
    && mv -f "$f.new" "$f" || { rm -f "$f" "$f.new"; return 1; }
  return 0
}

_osrc_review_item_exists_for_lane() { # any earlier item (any state) for this lane?
  local p
  for p in "$OSRC_HOME/review/items/$1"-*.json; do [ -s "$p" ] && return 0; done
  return 1
}

# Called by the lane poll when a lane's head moves.
_osrc_review_supersede() { # <lane> <new-head>
  local lane="$1" new="$2" p st h
  for p in $(_osrc_review_items); do
    [ "$(jq -r .lane "$p")" = "$lane" ] || continue
    h="$(jq -r .head "$p")"; [ "$h" != "$new" ] || continue
    st="$(jq -r .state "$p")"
    case "$st" in
      queued) _osrc_jq_set "$p" --arg by "$new" '.state="superseded" | .stale=true | .stale_by=$by' ;;
      inflight|verdict) _osrc_jq_set "$p" --arg by "$new" '.stale=true | .stale_by=$by' ;;
    esac
  done
}

_osrc_review_lane_removed() { # drop queued items of a removed lane
  local p
  for p in $(_osrc_review_items); do
    [ "$(jq -r .lane "$p")" = "$1" ] && [ "$(jq -r .state "$p")" = queued ] && _osrc_jq_set "$p" '.state="dropped"'
  done
}

_osrc_review_verdict_for() { # <lane> <head> -> verdict of a VALID (non-stale) review of exactly this head
  local p="$(_osrc_rv_item "$1-${2:0:7}")"
  [ -f "$p" ] || return 0
  [ "$(jq -r .state "$p")" = verdict ] && [ "$(jq -r .stale "$p")" = false ] && [ "$(jq -r .head "$p")" = "$2" ] && jq -r .verdict "$p"
  return 0
}

_osrc_review_last_verdict_ts() { # <lane>
  local p best=0 t
  for p in $(_osrc_review_items); do
    [ "$(jq -r .lane "$p")" = "$1" ] || continue
    t="$(jq -r '.verdict_ts // 0' "$p")"; [ "$t" -gt "$best" ] && best="$t"
  done
  printf '%s' "$best"
}

_osrc_review_resolve() { # <id-or-unique-prefix> -> item id
  local want="$1" p n=0 hit=""
  [ -f "$(_osrc_rv_item "$want")" ] && { printf '%s' "$want"; return 0; }
  for p in $(_osrc_review_items); do
    case "$(basename "$p" .json)" in "$want"*) n=$((n+1)); hit="$(basename "$p" .json)" ;; esac
  done
  # a bare lane id means its newest item
  if [ "$n" -ge 1 ]; then
    [ "$n" -eq 1 ] || hit="$(ls -t "$OSRC_HOME"/review/items/"$want"-*.json 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null | sed 's/\.json$//')"
    printf '%s' "$hit"; return 0
  fi
  return 1
}

# ---- verdict ingestion ----------------------------------------------------------------------
# A verdict file is <item>.VERDICT whose first line is MERGE|CHANGES|BLOCK (case-insensitive).
_osrc_review_ingest() {
  local p id vf first v now settle age
  now="$(_osrc_now)"; settle="${OSRC_VERDICT_SETTLE_SECS:-30}"
  for p in $(_osrc_review_items); do
    case "$(jq -r .state "$p")" in inflight) ;; *) continue ;; esac
    id="$(jq -r .id "$p")"; vf="$OSRC_HOME/review/$id.VERDICT"
    [ -s "$vf" ] || continue
    first="$(head -1 "$vf" | tr -d '\r' | sed 's/^[[:space:]#*]*//; s/[[:space:]*:.-]*$//' | tr '[:lower:]' '[:upper:]')"
    case "$first" in
      MERGE|CHANGES|BLOCK)
        _osrc_jq_set "$p" --arg v "$first" --argjson now "$now" --arg vf "$vf" \
          '.state="verdict" | .verdict=$v | .verdict_ts=$now | .sha_reviewed=.head | .findings=$vf | .invalid_first_line=""' ;;
      *)
        age=$(( $(date +%s) - $(stat -f %m "$vf" 2>/dev/null || stat -c %Y "$vf" 2>/dev/null || date +%s) ))   # real file mtime vs real clock
        [ "$age" -ge "$settle" ] && _osrc_jq_set "$p" --arg l "$(head -1 "$vf" | cut -c1-60)" '.invalid_first_line=$l' ;;
    esac
  done
}

# ---- brief -------------------------------------------------------------------------------------
_osrc_review_write_brief() { # <item-id> -> writes review/<id>.md
  local p="$(_osrc_rv_item "$1")" out="$OSRC_HOME/review/$1.md" lane branch head url tr base brief vf fetch
  lane="$(jq -r .lane "$p")"; branch="$(jq -r .branch "$p")"; head="$(jq -r .head "$p")"; url="$(jq -r .url "$p")"
  tr="$(jq -r .transport "$p")"; base="$(jq -r .base "$p")"; brief="$(jq -r .brief "$p")"; vf="$OSRC_HOME/review/$1.VERDICT"
  if [ "$tr" = gh ]; then fetch="https://github.com/$url.git"; else fetch="$url"; fi
  {
    printf '# Review request: %s @ %s\n\n' "$lane" "${head:0:7}"
    printf -- '- Lane: %s\n- Branch: %s\n- Head sha (review exactly this): %s\n- Remote: %s\n- Base to diff against: %s\n\n' "$lane" "$branch" "$head" "$fetch" "$base"
    printf '## Get the change\n\n```\ngit fetch %q %q && git log --oneline FETCH_HEAD -20\ngit diff origin/%s...FETCH_HEAD   # or: git diff $(git merge-base origin/%s FETCH_HEAD) FETCH_HEAD\n' "$fetch" "$branch" "$base" "$base"
    [ "$tr" = gh ] && printf 'gh api repos/%s/compare/%s...%s -H "Accept: application/vnd.github.diff"\n' "$url" "$base" "$branch"
    printf '```\n\nIf FETCH_HEAD is not %s, the lane moved: say so in the verdict and review %s anyway.\n\n' "${head:0:7}" "${head:0:7}"
    if [ -n "$brief" ] && [ -f "$brief" ]; then printf '## The lane'"'"'s own brief (what it was asked to build)\n\n'; cat "$brief"; printf '\n\n'; fi
    printf '## Where to write the verdict\n\nWrite exactly this file: %s\n\nFirst line: one word, MERGE, CHANGES or BLOCK. Below it: findings, most severe first, each with file:line and the fix. MERGE means no findings that must change before merge.\nDo not merge, push or edit the branch. You are the only reviewer; take items one at a time.\n' "$vf"
  } > "$out" || return 1
  printf '%s' "$out"
}

# ---- rotation ----------------------------------------------------------------------------------
# After K reviews (OSRC_REVIEW_ROTATE_K, default 6) or context bar over OSRC_REVIEW_CTX_MAX (60%).
_osrc_review_rotation_due() { # <session> -> prints reason, rc 0 when due
  local s="$1" f="$OSRC_HOME/review/reviewer.json" n k ctx max
  k="${OSRC_REVIEW_ROTATE_K:-6}"; max="${OSRC_REVIEW_CTX_MAX:-60}"
  n="$(jq -r '.reviews // 0' "$f" 2>/dev/null)"; [ -n "$n" ] || n=0
  if [ "$n" -ge "$k" ] 2>/dev/null; then printf '%s reviews done (limit %s)' "$n" "$k"; return 0; fi
  ctx="$(_osrc_review_ctx_pct "$s")"
  if [ -n "$ctx" ] && [ "$ctx" -gt "$max" ] 2>/dev/null; then printf 'context %s%% (limit %s%%)' "$ctx" "$max"; return 0; fi
  return 1
}

# ---- events ------------------------------------------------------------------------------------
osrc_review_events() {
  have jq || return 0
  [ -d "$OSRC_HOME/review/items" ] || [ -n "$(_osrc_review_reviewer)" ] || return 0
  local s now un renotify rv_renotify p id lane sha7 st inflight="" nq=0 oldest="" scr rot send_grace v nextc stale
  now="$(_osrc_now)"; s="$(_osrc_review_reviewer)"
  un="$(_osrc_mins "${OSRC_UNREVIEWED_MIN:-20}")"; renotify="$(_osrc_mins "${OSRC_RENOTIFY_MIN:-15}")"
  rv_renotify="$(_osrc_mins "${OSRC_REVIEW_IDLE_RENOTIFY_MIN:-2}")"; send_grace="${OSRC_REVIEW_SEND_GRACE_SECS:-45}"
  _osrc_review_ingest
  for p in $(_osrc_review_items); do
    id="$(jq -r .id "$p")"; lane="$(jq -r .lane "$p")"; sha7="$(jq -r '.head[0:7]' "$p")"; st="$(jq -r .state "$p")"
    stale="$(jq -r .stale "$p")"
    case "$st" in
      queued) nq=$((nq+1)); [ -n "$oldest" ] || oldest="$id"
        if [ $(( now - $(jq -r .enq_ts "$p") )) -ge "$un" ] && _osrc_ev_due "unreviewed:$id" "$un"; then
          _osrc_emit unreviewed "$lane" "READY $sha7 queued $(( (now - $(jq -r .enq_ts "$p")) / ${OSRC_TIME_UNIT:-60} ))m with no review started (item $id)" "$(_osrc_review_next_cmd "$s")"
        fi ;;
      inflight) inflight="$id" ;;
      verdict)
        [ "$(jq -r .acked "$p")" = false ] || continue
        v="$(jq -r .verdict "$p")"
        if [ "$stale" = true ]; then nextc="$(_osrc_self) review show $id"; else
          case "$v" in MERGE) nextc="$(_osrc_self) review show $id" ;; *) nextc="$(_osrc_self) review sendback $id" ;; esac
        fi
        if _osrc_ev_due "verdict:$id" "$renotify"; then
          _osrc_emit done "$lane" "VERDICT $v $sha7$( [ "$stale" = true ] && printf ' STALE: lane moved to %s, re-review pending' "$(jq -r '.stale_by[0:7]' "$p")")" "$nextc"
        fi ;;
    esac
    if [ "$st" = inflight ] && [ "$(jq -r .invalid_first_line "$p")" != "" ] && _osrc_ev_due "badverdict:$id" "$renotify"; then
      _osrc_emit question "$lane" "verdict file for $id has no MERGE/CHANGES/BLOCK first line (got: $(jq -r .invalid_first_line "$p"))" "OUTSOURCERER_TMUX=$s $(_osrc_self) session send \"first line of $OSRC_HOME/review/$id.VERDICT must be exactly MERGE, CHANGES or BLOCK\""
    fi
  done
  [ -n "$s" ] || return 0
  if ! tmux has-session -t "=$s" 2>/dev/null; then
    if _osrc_ev_due "rvgone:$s" "$renotify" && { [ "$nq" -gt 0 ] || [ -n "$inflight" ]; }; then
      _osrc_emit failed "$s" "reviewer session is gone with $nq queued and ${inflight:-no} item in flight" "$(_osrc_self) review rotate"
    fi
    return 0
  fi
  scr="$(_osrc_review_screen "$s")"
  if [ -n "$inflight" ]; then
    local sent; sent="$(jq -r .sent_ts "$(_osrc_rv_item "$inflight")")"
    if [ "$scr" = idle ] && [ $(( now - sent )) -ge "$send_grace" ] && _osrc_ev_due "rvstopped:$inflight" "$renotify"; then
      _osrc_emit idle "$s" "reviewer went idle without writing a verdict for $inflight (stopped, or asked a question)" "OUTSOURCERER_TMUX=$s $(_osrc_self) session read"
    elif [ "$scr" = approval ] && _osrc_ev_due "rvapproval:$s" "$renotify"; then
      _osrc_emit approval "$s" "reviewer is at a prompt while reviewing $inflight" "OUTSOURCERER_TMUX=$s $(_osrc_self) session read"
    fi
    return 0
  fi
  if [ "$nq" -gt 0 ] && [ "$scr" = idle ] && _osrc_ev_due "rvidle:$s" "$rv_renotify"; then
    rot="$(_osrc_review_rotation_due "$s")" && _osrc_emit idle "$s" "reviewer idle, $nq queued (oldest $oldest); rotation due: $rot, start a fresh reviewer" "$(_osrc_self) review rotate" \
      || _osrc_emit idle "$s" "reviewer idle, $nq queued (oldest $oldest)" "$(_osrc_self) review next"
  fi
  return 0
}

_osrc_review_next_cmd() { # <reviewer-or-empty>
  if [ -z "$1" ]; then printf '%s review reviewer <tmux-session>' "$(_osrc_self)"
  else printf '%s review next' "$(_osrc_self)"; fi
}

# ---- commands ----------------------------------------------------------------------------------
cmd_review() {
  local sub="${1:-}"; shift || true
  have jq || die "review needs jq"
  case "$sub" in
    queue) case "${1:-}" in add) shift; _osrc_review_queue_add "$@" ;; ls|list|"") _osrc_review_queue_ls ;; *) die "review queue add <lane-or-branch> [--brief F] [--repo R] | ls" ;; esac ;;
    reviewer) _osrc_review_set_reviewer "$@" ;;
    next) _osrc_review_next "$@" ;;
    show) _osrc_review_show "${1:-}" ;;
    ack) local i; i="$(_osrc_review_resolve "${1:-}")" || die "no such review item"; _osrc_jq_set "$(_osrc_rv_item "$i")" '.acked=true' && echo "acked $i" ;;
    requeue) local i; i="$(_osrc_review_resolve "${1:-}")" || die "no such review item"
             _osrc_jq_set "$(_osrc_rv_item "$i")" '.state="queued" | .sent_ts=0' && echo "requeued $i" ;;
    drop) local i; i="$(_osrc_review_resolve "${1:-}")" || die "no such review item"; _osrc_jq_set "$(_osrc_rv_item "$i")" '.state="dropped"' && echo "dropped $i" ;;
    sendback) _osrc_review_sendback "${1:-}" ;;
    rotate) _osrc_review_rotate ;;
    events) osrc_review_events ;;
    *) die "review: queue add <lane-or-branch> [--brief F] | queue ls | reviewer [<tmux-session> [--replace]] | next [--force] | show|ack|requeue|drop|sendback <item> | rotate | events" ;;
  esac
}

_osrc_review_queue_add() {
  local target="${1:-}" brief="" repo="" lf head id rr n
  [ -n "$target" ] || die "review queue add <lane-or-branch> [--brief F] [--repo R]"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in --brief) brief="${2:-}"; shift 2 ;; --repo) repo="${2:-}"; shift 2 ;; *) die "review queue add: unknown option '$1'" ;; esac
  done
  [ -z "$brief" ] || [ -f "$brief" ] || die "--brief file not found: $brief"
  [ -z "$brief" ] || brief="$(cd "$(dirname "$brief")" && pwd)/$(basename "$brief")"
  lf="$(_osrc_lane_json "$target")"
  if [ -f "$lf" ]; then
    _osrc_lane_poll "$target" force
    head="$(jq -r .head "$lf")"; [ -n "$head" ] || die "lane $target has no pushed branch yet"
    id="$target"
  else
    # a bare branch name: resolve the repo now, no lane record needed
    case "$target" in *[!A-Za-z0-9._/-]*|-*|"") die "'$target' is neither a registered lane nor a usable branch name" ;; esac
    rr="$(_osrc_repo_resolve "$repo")" || die "cannot resolve a repo for branch '$target' (pass --repo)"
    _OSRC_RV_TRANSPORT="${rr%%	*}"; _OSRC_RV_URL="${rr#*	}"; _OSRC_RV_BRANCH="$target"
    if [ "$_OSRC_RV_TRANSPORT" = gh ]; then head="$(gh api "repos/$_OSRC_RV_URL/commits/$target" --jq .sha 2>/dev/null)"
    else head="$(git ls-remote "$_OSRC_RV_URL" "refs/heads/$target" 2>/dev/null | awk 'NR==1{print $1}')"; fi
    [ -n "$head" ] || die "branch $target not found on $_OSRC_RV_URL"
    id="$(printf '%s' "$target" | tr '/' '-')"
    export _OSRC_RV_TRANSPORT _OSRC_RV_URL _OSRC_RV_BRANCH
  fi
  if _osrc_review_enqueue "$id" "$head" "$brief" manual; then
    n=$(_osrc_review_count_queued)
    echo "queued $id-${head:0:7} (position $n of $n queued)"
  else
    echo "already queued or reviewed: $id-${head:0:7} (dedupe by lane + head sha). Use: review requeue $id-${head:0:7}"
  fi
  unset _OSRC_RV_TRANSPORT _OSRC_RV_URL _OSRC_RV_BRANCH
}

_osrc_review_count_queued() { local p n=0; for p in $(_osrc_review_items); do [ "$(jq -r .state "$p")" = queued ] && n=$((n+1)); done; printf '%s' "$n"; }

_osrc_review_queue_ls() {
  local p any=0 s now; s="$(_osrc_review_reviewer)"; now="$(_osrc_now)"
  _osrc_review_ingest
  echo "reviewer: ${s:-(none: review reviewer <tmux-session>)}"
  printf '%-34s %-10s %-8s %-7s %s\n' ITEM STATE VERDICT AGE NOTE
  for p in $(_osrc_review_items); do
    any=1
    printf '%-34s %-10s %-8s %-7s %s\n' "$(jq -r .id "$p")" "$(jq -r .state "$p")" "$(jq -r '.verdict // ""' "$p")" \
      "$(( (now - $(jq -r .enq_ts "$p")) / ${OSRC_TIME_UNIT:-60} ))m" \
      "$( [ "$(jq -r .stale "$p")" = true ] && printf 'STALE (lane at %s)' "$(jq -r '.stale_by[0:7]' "$p")"; [ "$(jq -r .rereview "$p")" = true ] && printf ' re-review')"
  done
  [ "$any" = 1 ] || echo "(queue empty)"
}

_osrc_review_set_reviewer() {
  local s="${1:-}" replace="" old f="$OSRC_HOME/review/reviewer.json"
  if [ -z "$s" ]; then
    old="$(_osrc_review_reviewer)"; [ -n "$old" ] && echo "$old" || echo "(no reviewer set)"; return 0
  fi
  [ "${2:-}" != "--replace" ] || replace=1
  case "$s" in ''|*[!A-Za-z0-9._-]*) die "invalid tmux session name '$s'" ;; esac
  tmux has-session -t "=$s" 2>/dev/null || die "no tmux session '$s' (start the reviewer first: session start ...)"
  old="$(_osrc_review_reviewer)"
  if [ -n "$old" ] && [ "$old" != "$s" ] && tmux has-session -t "=$old" 2>/dev/null && [ -z "$replace" ]; then
    die "reviewer '$old' is still alive. There is one reviewer at a time: stop it first ($(_osrc_self) with OUTSOURCERER_TMUX=$old session stop), or pass --replace to switch anyway (the old one is left running, not killed)"
  fi
  mkdir -p "$OSRC_HOME/review"
  if [ "$old" = "$s" ]; then echo "reviewer is already $s"; return 0; fi
  jq -n --arg s "$s" --argjson now "$(_osrc_now)" '{session:$s, since_ts:$now, reviews:0}' > "$f.new" && mv -f "$f.new" "$f"
  _owner_record "$s"
  echo "reviewer set: $s${old:+ (replaced $old)}"
  [ -z "$old" ] || [ -z "$replace" ] || echo "note: $old is still running; stop it so there is only one reviewer"
}

_osrc_review_next() {
  local force="" s p chosen="" inflight="" scr id brief msg vf now rot lk n
  [ "${1:-}" != "--force" ] || force=1
  s="$(_osrc_review_reviewer)"; [ -n "$s" ] || { echo "no reviewer set: review reviewer <tmux-session>" >&2; return 2; }
  tmux has-session -t "=$s" 2>/dev/null || { echo "reviewer session '$s' is gone: $(_osrc_self) review rotate" >&2; return 2; }
  mkdir -p "$OSRC_HOME/review"; lk="$OSRC_HOME/review/.next.lock"
  _osrc_lock "$lk" || { echo "another review next is running" >&2; return 3; }
  now="$(_osrc_now)"
  _osrc_review_ingest
  for p in $(_osrc_review_items); do
    case "$(jq -r .state "$p")" in
      inflight) inflight="$(jq -r .id "$p")" ;;
      queued) [ -n "$chosen" ] || chosen="$p" ;;
    esac
  done
  # oldest queued first (items list is name-sorted, so order explicitly by enqueue time)
  chosen=""
  for p in $(_osrc_review_items); do
    [ "$(jq -r .state "$p")" = queued ] || continue
    if [ -z "$chosen" ] || [ "$(jq -r .enq_ts "$p")" -lt "$(jq -r .enq_ts "$chosen")" ]; then chosen="$p"; fi
  done
  if [ -n "$inflight" ]; then _osrc_unlock "$lk"; echo "one review in flight already: $inflight (never more than one). Verdict goes to $OSRC_HOME/review/$inflight.VERDICT"; return 3; fi
  if [ -z "$chosen" ]; then _osrc_unlock "$lk"; echo "queue empty"; return 0; fi
  if [ -z "$force" ] && rot="$(_osrc_review_rotation_due "$s")"; then
    _osrc_unlock "$lk"; echo "reviewer rotation due ($rot): $(_osrc_self) review rotate   (or --force to send anyway)" >&2; return 5
  fi
  scr="$(_osrc_review_screen "$s")"
  if [ "$scr" != idle ]; then _osrc_unlock "$lk"; echo "reviewer $s is $scr, not idle: not sending" >&2; return 4; fi
  id="$(jq -r .id "$chosen")"
  brief="$(_osrc_review_write_brief "$id")" || { _osrc_unlock "$lk"; echo "could not write the review brief" >&2; return 1; }
  vf="$OSRC_HOME/review/$id.VERDICT"; rm -f "$vf"
  msg="Review request $id: read $brief and follow it. Write your verdict to $vf (first line MERGE, CHANGES or BLOCK). One review at a time."
  if _osrc_review_send "$s" "$msg"; then
    _osrc_jq_set "$chosen" --argjson now "$now" '.state="inflight" | .sent_ts=$now'
    n="$OSRC_HOME/review/reviewer.json"
    [ -f "$n" ] && _osrc_jq_set "$n" '.reviews=((.reviews // 0) + 1)'
    _osrc_unlock "$lk"
    echo "sent $id to $s. Verdict file: $vf"
    return 0
  fi
  _osrc_unlock "$lk"
  echo "send to $s failed; $id stays queued" >&2
  return 1
}

_osrc_review_show() {
  local i p; i="$(_osrc_review_resolve "${1:-}")" || die "review show <item>"
  p="$(_osrc_rv_item "$i")"; _osrc_review_ingest
  jq . "$p"
  [ -f "$OSRC_HOME/review/$i.VERDICT" ] && { echo "--- verdict file ---"; cat "$OSRC_HOME/review/$i.VERDICT"; }
  [ "$(jq -r .stale "$p")" != true ] || echo "NOTE: STALE. The lane moved to $(jq -r .stale_by "$p"); this verdict is for $(jq -r .head "$p") only."
  return 0
}

_osrc_review_sendback() {
  local i p out v lane sha7
  i="$(_osrc_review_resolve "${1:-}")" || die "review sendback <item>"
  p="$(_osrc_rv_item "$i")"; v="$(jq -r .verdict "$p")"; [ -n "$v" ] || die "$i has no verdict yet"
  lane="$(jq -r .lane "$p")"; sha7="$(jq -r '.head[0:7]' "$p")"; out="$OSRC_HOME/review/REVIEW-$sha7.md"
  { printf '# Review of %s @ %s: %s\n\n' "$lane" "$sha7" "$v"
    [ "$(jq -r .stale "$p")" != true ] || printf 'NOTE: the lane has pushed %s since; findings apply to %s.\n\n' "$(jq -r '.stale_by[0:7]' "$p")" "$sha7"
    tail -n +2 "$(jq -r .findings "$p")"; } > "$out"
  echo "wrote $out"
  echo "--- relay this to lane '$lane' (cloud session message, PR comment, or relaunch brief) ---"
  printf 'Review of your branch %s at %s: %s. Findings are below; fix them, push, and mark the new head READY.\n\n' "$(jq -r .branch "$p")" "$sha7" "$v"
  cat "$out"
  echo "--- then: $(_osrc_self) review ack $i ---"
}

_osrc_review_rotate() {
  local s why; s="$(_osrc_review_reviewer)"
  why="$( [ -n "$s" ] && _osrc_review_rotation_due "$s" )"
  echo "Reviewer rotation${why:+ ($why)}. One reviewer at a time:"
  echo "  1. start a fresh reviewer (same model as the old one), e.g. OUTSOURCERER_TMUX=${s:-reviewer}-r$(( $(jq -r '.reviews // 0' "$OSRC_HOME/review/reviewer.json" 2>/dev/null || echo 0) + 1 )) $(_osrc_self) session start --provider cc -m <model>"
  echo "  2. stop the old one: OUTSOURCERER_TMUX=${s:-<old>} $(_osrc_self) session stop   (only after any in-flight verdict is in)"
  echo "  3. $(_osrc_self) review reviewer <new-session>   (counters reset; queued items carry over)"
}
