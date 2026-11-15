#!/usr/bin/env bash
# lib/hub.sh -- Mission Control: `hub export` builds SCHEMA project docs from
# outsourcerer state; `hub serve` runs the local page server (lib/hub_server.py).
# Sourced by outsourcerer.sh; defines functions only, runs nothing at load time.
#
# Projects group by owner session ($OSRC_HOME/owners/<sid>/<target>): one orchestrator
# session = one hub project. Lane state comes from the real registries: job dirs +
# meta.json, the session registry, tmux liveness via _owned_live_state, remote lanes
# via osrc_remote_state/osrc_done_state/review items when those modules are loaded.
# Card fields (name/tagline/themes/order/repo/status/pct/eta/flow/extraLinks) and
# per-lane overrides come from $OSRC_HOME/hub/projects/<slug>.json; decisions come
# from $OSRC_HOME/hub/decisions/<slug>.json. Nothing is invented: a field with no real
# source is omitted and the page shows its own default.

_osrc_hub_dir() { printf '%s/hub' "$OSRC_HOME"; }

_osrc_hub_slug_ok() { case "${1:-}" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac; [ "${#1}" -le 128 ]; }

# _osrc_hub_sanitize_note <text> -> one line, $HOME -> ~, capped.
_osrc_hub_note() {
  printf '%s' "${1:-}" | tr '\n\t' '  ' | sed "s|$HOME|~|g" | cut -c1-160
}

# _osrc_hub_repo_name <repo> <url> -> owner/name only, or nothing. Never emits a
# filesystem path or a full URL (the page links github.com/<repo>).
_osrc_hub_repo_name() {
  local v="${1:-}" u="${2:-}" x
  for x in "$v" "$u"; do
    case "$x" in
      ''|*/..*) continue ;;
    esac
    x="$(printf '%s' "$x" | sed -e 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||' -e 's|^[^@/]*@[^:]*/||' -e 's|\.git$||' -e 's|/$||')"
    x="${x#github.com/}"; x="${x#www.github.com/}"
    case "$x" in
      */*)
        local owner="${x%%/*}" name="${x#*/}"
        case "$owner/$name" in
          *[!A-Za-z0-9_.-]*|*//*) continue ;;
        esac
        # A path-like value (more than one slash, or a leading slash) is not owner/name.
        case "$x" in */*/*|/*|~*) continue ;; esac
        printf '%s' "$owner/$name"; return 0 ;;
    esac
  done
  return 0
}

# _osrc_hub_review_map -> jq program fragment: lane -> latest valid verdict.
# Prints a JSON object {"<lane>":"MERGE|CHANGES|BLOCK"} built once per export.
_osrc_hub_review_map() {
  local d="$OSRC_HOME/review/items"
  [ -d "$d" ] || { printf '{}'; return 0; }
  jq -cs '[.[] | select(.state=="verdict" and (.stale|not))]
          | group_by(.lane) | map(max_by(.verdict_ts // 0))
          | map({key:(.lane|tostring), value:(.verdict|tostring)}) | from_entries' \
    "$d"/*.json 2>/dev/null || printf '{}'
}

# _osrc_hub_review_verdict <lane> <map-json> -> verdict or empty
_osrc_hub_review_verdict() { jq -r --arg l "$1" '.[$l] // ""' <<<"$2" 2>/dev/null; }

# _osrc_hub_done_state <id> -> "done" | "" (uses osrc_done_state when defined)
_osrc_hub_done_state() {
  type osrc_done_state >/dev/null 2>&1 || return 0
  case "$(osrc_done_state "$1" 2>/dev/null)" in done*) printf 'done' ;; esac
  return 0
}

# _osrc_hub_lane_status <raw> <verdict> -> "STATUS|pct|note-extra"
# Maps internal states onto the SCHEMA lane vocabulary; unknown raw states pass through.
_osrc_hub_lane_status() {
  local raw="$1" rv="$2" extra="${3:-}"
  local st="$raw"
  case "$rv" in
    MERGE) st="Merged" ;;
    BLOCK) st="Blocked" ;;
    CHANGES) st="Building"; extra="${extra:+$extra; }changes requested by review" ;;
  esac
  case "$st" in
    live|working|running|launching|stalled\?|exploring\?|no-progress-writes|ready)
      [ "$rv" = "" ] && [ "$st" = "ready" ] && st="Review" || st="Building" ;;
    idle) st="Idle" ;;
    waiting) st="Blocked"; extra="${extra:+$extra; }waiting on the orchestrator (approval, question or limit)" ;;
    done|'done?') st="Done" ;;
    blocked|permission-blocked) st="Blocked" ;;
    failed|wedged|timeout) st="Failed" ;;
    canceled|interrupted) st="Canceled" ;;
    gone) st="" ;;
    Merged|Blocked|Done|Building|Review|Shipped|Idle|Failed|Canceled) : ;;
    *) st="Building" ;;
  esac
  local pct=""
  case "$st" in Done|Merged|Shipped) pct="100" ;; esac
  printf '%s|%s|%s' "$st" "$pct" "$extra"
}

# _osrc_hub_emit_lane <json-args...> -> prints one lane object (jq -cn).
# All fields optional-empty are dropped by the caller-side jq merge.

_osrc_hub_lane_job() { # <id> -> lane json or nothing
  local id="$1" jd="$OSRC_JOBS/$1"
  [ -d "$jd" ] || return 1
  have jq || return 1
  local st meta verb prov model lane cwd wt br task_ref reason note ds
  st="$(_reconcile_status "$id" 2>/dev/null || cat "$jd/status" 2>/dev/null || echo '?')"
  meta="$jd/meta.json"
  prov="$(jq -r '.provider // ""' "$meta" 2>/dev/null)"
  model="$(jq -r '.model // ""' "$meta" 2>/dev/null)"
  lane="$(jq -r '.lane // .provider // ""' "$meta" 2>/dev/null)"
  verb="$(jq -r '.verb // ""' "$meta" 2>/dev/null)"
  wt="$(jq -r '.worktree // ""' "$meta" 2>/dev/null)"
  br="$(jq -r '.branch // ""' "$meta" 2>/dev/null)"
  task_ref="$(cat "$jd/task_ref" 2>/dev/null | head -1)"
  [ -f "$jd/worktree.json" ] && { wt="${wt:-$(jq -r '.path // ""' "$jd/worktree.json" 2>/dev/null)}"; br="${br:-$(jq -r '.branch // ""' "$jd/worktree.json" 2>/dev/null)}"; }
  reason="$(head -1 "$jd/reason" 2>/dev/null)"
  ds="$(_osrc_hub_done_state "$id")"
  [ "$ds" = "done" ] && st="done"
  local mapped; mapped="$(_osrc_hub_lane_status "$st" "" "${reason:-$st}")"
  local mstat="${mapped%%|*}"; mapped="${mapped#*|}"; local mpct="${mapped%%|*}"; note="${mapped#*|}"
  note="$(_osrc_hub_note "$note")"
  local short="${task_ref:-}"
  [ -n "$short" ] || short="${lane:-$prov} ${verb:-run} ${id##*-}"
  jq -cn --arg id "$id" --arg short "$short" --arg status "$mstat" --arg pct "$mpct" \
    --arg note "$note" --arg model "$model" --arg br "$br" --arg wt "$wt" \
    '{id:$id, short:$short, status:$status}
     + (if $pct=="" then {} else {pct:($pct|tonumber)} end)
     + (if $note=="" then {} else {note:$note} end)
     + (if $model=="" then {} else {model:$model} end)
     + (if $br=="" then {} else {branch:$br} end)
     + (if $wt=="" then {} else {worktree:$wt} end)'
}

_osrc_hub_lane_session() { # <id> -> lane json or nothing (tmux/autodetach target)
  local id="$1" st prov model state
  have tmux 2>/dev/null && tmux has-session -t "=$id" 2>/dev/null || return 1
  st="$(_owned_live_state "$id" 2>/dev/null)"
  ds=""; ds="$(_osrc_hub_done_state "$id")"; [ "$ds" = "done" ] && st="done"
  case "$st" in gone) return 1 ;; esac
  prov="$(type _session_registry_last_event >/dev/null 2>&1 && _session_registry_last_event "$id" 2>/dev/null | jq -r '.provider // ""' 2>/dev/null)"
  model="$(type _session_registry_last_event >/dev/null 2>&1 && _session_registry_last_event "$id" 2>/dev/null | jq -r '.resolved_model // .model // ""' 2>/dev/null)"
  local note=""
  if [ -s "$OSRC_HOME/autodetach/$id.rc" ]; then note="auto-detached run finished (rc $(cat "$OSRC_HOME/autodetach/$id.rc" 2>/dev/null | tr -dc '0-9'))"
  elif [ -f "$OSRC_HOME/autodetach/$id.log" ]; then note="auto-detached run"
  else note="interactive session"; fi
  local mapped; mapped="$(_osrc_hub_lane_status "$st" "" "$note")"
  local mstat="${mapped%%|*}"; mapped="${mapped#*|}"; local mpct="${mapped%%|*}"; note="${mapped#*|}"
  note="$(_osrc_hub_note "$note")"
  jq -cn --arg id "$id" --arg short "$id" --arg status "$mstat" --arg pct "$mpct" \
    --arg note "$note" --arg model "$model" --arg sess "$id" \
    '{id:$id, short:$short, status:$status, session:$sess}
     + (if $pct=="" then {} else {pct:($pct|tonumber)} end)
     + (if $note=="" then {} else {note:$note} end)
     + (if $model=="" then {} else {model:$model} end)'
}

_osrc_hub_lane_remote() { # <id> -> lane json or nothing
  local id="$1" f="$OSRC_HOME/remote/$id.json"
  [ -f "$f" ] || return 1
  have jq || return 1
  local st branch head head7 msg repo rv mapped mstat mpct note short
  if type osrc_remote_state >/dev/null 2>&1; then st="$(osrc_remote_state "$id" 2>/dev/null)"; else
    st="live"
    [ "$(jq -r '.branch_deleted // false' "$f")" = "true" ] && st="failed"
    [ "$(jq -r '.check.head // ""' "$f")" = "$(jq -r '.head // ""' "$f")" ] && [ "$(jq -r '.check.rc // 0' "$f")" != "0" ] && st="failed"
    [ "$(jq -r '.head_ready // false' "$f")" = "true" ] && st="ready"
  fi
  case "$st" in gone) return 1 ;; esac
  branch="$(jq -r '.branch // ""' "$f")"
  head="$(jq -r '.head // ""' "$f")"; head7="${head:0:7}"
  msg="$(_osrc_hub_note "$(jq -r '.head_msg // ""' "$f")")"
  repo="$(_osrc_hub_repo_name "$(jq -r '.repo // ""' "$f")" "$(jq -r '.url // ""' "$f")")"
  # Verdict from the review queue (L2) when present; ready+verdict refines the state.
  rv=""
  if type _osrc_review_verdict_for >/dev/null 2>&1 && [ -n "$head" ]; then
    rv="$(_osrc_review_verdict_for "$id" "$head" 2>/dev/null)"
  fi
  local raw="$st"
  [ "$st" = "ready" ] && [ -n "$rv" ] && raw="verdict-$rv"
  [ "$st" = "done" ] && [ -z "$rv" ] && rv="MERGE"
  mapped="$(_osrc_hub_lane_status "$raw" "$rv" "${msg:+$msg}${head7:+ @${head7}}")"
  mstat="${mapped%%|*}"; mapped="${mapped#*|}"; mpct="${mapped%%|*}"; note="${mapped#*|}"
  note="$(_osrc_hub_note "$note")"
  jq -cn --arg id "$id" --arg short "$id" --arg status "$mstat" --arg pct "$mpct" \
    --arg note "$note" --arg br "$branch" --arg repo "$repo" \
    '{id:$id, short:$short, status:$status}
     + (if $pct=="" then {} else {pct:($pct|tonumber)} end)
     + (if $note=="" then {} else {note:$note} end)
     + (if $br=="" then {} else {branch:$br} end)
     + (if $repo=="" then {} else {repo:$repo} end)'
}

_osrc_hub_lane_fallback() { # <id> -> lane json or nothing
  local id="$1" st
  st="$(_owned_live_state "$id" 2>/dev/null)"
  case "$st" in gone|"") return 1 ;; esac
  ds="$(_osrc_hub_done_state "$id")"; [ "$ds" = "done" ] && st="done"
  local mapped; mapped="$(_osrc_hub_lane_status "$st" "" "$st")"
  local mstat="${mapped%%|*}"; mapped="${mapped#*|}"; local mpct="${mapped%%|*}"; local note="${mapped#*|}"
  note="$(_osrc_hub_note "$note")"
  jq -cn --arg id "$id" --arg short "$id" --arg status "$mstat" --arg pct "$mpct" --arg note "$note" \
    '{id:$id, short:$short, status:$status}
     + (if $pct=="" then {} else {pct:($pct|tonumber)} end)
     + (if $note=="" then {} else {note:$note} end)'
}

# _osrc_hub_lane_for <id> <rmap> -> lane json: remote -> job -> session -> fallback.
_osrc_hub_lane_for() {
  local id="$1" rmap="$2"
  if [ -f "$OSRC_HOME/remote/$id.json" ]; then _osrc_hub_lane_remote "$id" && return 0; fi
  if [ -d "$OSRC_JOBS/$id" ]; then
    local lj; lj="$(_osrc_hub_lane_job "$id")" && { local rv; rv="$(_osrc_hub_review_verdict "$id" "$rmap")"; if [ -n "$rv" ]; then lj="$(jq -c --arg rv "$rv" '.status = (if $rv=="MERGE" then "Merged" elif $rv=="BLOCK" then "Blocked" else .status end) + {pct:(if $rv=="MERGE" then 100 else .pct end)}' <<<"$lj")"; fi; printf '%s' "$lj"; return 0; }
  fi
  _osrc_hub_lane_session "$id" && return 0
  _osrc_hub_lane_fallback "$id"
}

# ---- decisions + project card ---------------------------------------------------

# _osrc_hub_decisions <slug> -> normalized decisions JSON array.
_osrc_hub_decisions() {
  local f="$OSRC_HOME/hub/decisions/$1.json"
  [ -f "$f" ] || { printf '[]'; return 0; }
  jq -c 'if type=="array" then . elif (.decisions|type)=="array" then .decisions else [] end
    | map(. + {id:(.id // ""), status:(.status // "wait"), weight:(.weight // "Medium"),
               options:(.options // []), affects:(.affects // []), q:(.q // .short // ""),
               short:(.short // .q // "")})
    | to_entries | map(.value + {id:(.value.id // ("D" + ((.key+1)|tostring)))}) | map(del(.key))' \
    "$f" 2>/dev/null || printf '[]'
}

# _osrc_hub_card <slug> <decisions-file-json> -> project card fields JSON object.
_osrc_hub_card() {
  local slug="$1" decfile="$OSRC_HOME/hub/decisions/$1.json" pf="$OSRC_HOME/hub/projects/$1.json"
  local base='{}'
  # decisions file may carry name/tagline as a fallback when no projects file exists.
  if [ -f "$decfile" ]; then
    base="$(jq -c '{name:(.name // empty), tagline:(.tagline // empty)} | with_entries(select(.value != null and .value != ""))' "$decfile" 2>/dev/null || printf '{}')"
  fi
  if [ -f "$pf" ]; then
    base="$(jq -cn --argjson a "$base" --argjson b "$(jq -c '{name,tagline,order,repo,themes,flow,extraLinks,status,pct,eta,etaNote,summary,summaryAt,lanes}
      | .extraLinks |= (if .==null then null else [.[]? | select(.url | type == "string" and startswith("https://"))] end)
      | with_entries(select(.value != null))' "$pf" 2>/dev/null || printf '{}')" '$a + $b')"
  fi
  printf '%s' "$base"
}

# _osrc_hub_apply_lane_overrides <lanes-json> <card-json> -> lanes with card.lanes overrides
# merged (only short/note/issues/theme may be overridden; status/pct/session stay computed).
_osrc_hub_apply_lane_overrides() {
  jq -c --argjson card "$2" '
    ($card.lanes // {}) as $ov |
    map(. as $l | ($ov[$l.id] // {}) as $o |
      $l + ($o | with_entries(select(.key as $k | ["short","note","issues","theme"] | index($k) != null))))' \
    <<<"$1" 2>/dev/null || printf '%s' "$1"
}

# _osrc_hub_build_project <slug> <now> <updated-str> -> one SCHEMA project doc.
_osrc_hub_build_project() {
  local slug="$1" now="$2" upd="$3"
  _osrc_hub_slug_ok "$slug" || return 1
  have jq || return 1
  local sid_dir="$OSRC_HOME/owners/$slug" lanes='[]' t lane act lact=0 llive=0
  type _osrc_hub_cache_get >/dev/null 2>&1 && _osrc_hub_cache_get "$slug" "$now" "$upd" && return 0   # settled project (MC2 r2 #4)
  local rmap; rmap="$(_osrc_hub_review_map)"
  if [ -d "$sid_dir" ]; then
    for t in "$sid_dir"/*; do
      [ -f "$t" ] || continue
      case "${t##*/}" in .*|watch.*) continue ;; esac   # watch.*: a supervise --watch, not a lane
      lane="$(_osrc_hub_lane_for "${t##*/}" "$rmap")"
      [ -n "$lane" ] && type _osrc_hub_lane_live_fields >/dev/null 2>&1 && lane="$(_osrc_hub_lane_live_fields "$lane")"   # state + times (MC2 r2 #5)
      [ -n "$lane" ] && lanes="$(jq -cn --argjson a "$lanes" --argjson b "$lane" '$a + [$b]')"
      act="$(_osrc_hub_lane_activity "${t##*/}")"
      [ "${act%% *}" -gt "$lact" ] 2>/dev/null && lact="${act%% *}"
      [ "${act##* }" = 1 ] && llive=1
    done
  fi
  local decs card out
  decs="$(_osrc_hub_decisions "$slug")"
  card="$(_osrc_hub_card "$slug")"
  lanes="$(_osrc_hub_apply_lane_overrides "$lanes" "$card")"
  # name: card > decisions-file already folded into card; fallback slug.
  local name order status pct eta etanote tagline repo themes flow extralinks
  name="$(jq -r '.name // ""' "$OSRC_HOME/hub/projects/$slug.json" 2>/dev/null)"; [ -n "$name" ] || name="$(_osrc_hub_derived_name "$slug")"
  order="$(jq -r '.order // 99' <<<"$card")"
  status="$(jq -r '.status // ""' <<<"$card")"
  pct="$(jq -r '.pct // ""' <<<"$card")"
  eta="$(jq -r '.eta // ""' <<<"$card")"
  etanote="$(jq -r '.etaNote // ""' <<<"$card")"
  tagline="$(jq -r '.tagline // ""' <<<"$card")"
  repo="$(jq -r '.repo // ""' <<<"$card")"
  local upda stale_hours="${OSRC_HUB_STALE_HOURS:-24}"; case "$stale_hours" in ''|*[!0-9]*) stale_hours=24 ;; esac
  upda="$(_osrc_hub_project_mtime "$slug" "$lact" "$llive")"
  out="$(jq -cn \
    --arg id "$slug" --arg name "$name" --argjson order "$order" --arg upd "$upd" \
    --arg upda "$upda" --argjson live "$llive" --argjson staleHours "$stale_hours" \
    --argjson now "$now" --argjson lanes "$lanes" --argjson decs "$decs" \
    --arg status "$status" --arg pct "$pct" --arg eta "$eta" --arg etanote "$etanote" \
    --arg tagline "$tagline" --arg repo "$repo" --argjson card "$card" '
    {id:$id, name:$name, order:$order, updated:$upd, exported_at:$now, lanes:$lanes, decisions:$decs, liveLanes:$live, staleHours:$staleHours}
    + (if $upda=="" then {} else {updatedAt:$upda} end)
    + (if $status=="" then {} else {status:$status} end)
    + (if $pct=="" then {} else {pct:($pct|tonumber)} end)
    + (if $eta=="" then {} else {eta:$eta} end)
    + (if $etanote=="" then {} else {etaNote:$etanote} end)
    + (if $tagline=="" then {} else {tagline:$tagline} end)
    + (if $repo=="" then {} else {repo:$repo} end)
    + (if ($card.themes|type)=="array" and ($card.themes|length)>0 then {themes:$card.themes} else {} end)
    + (if ($card.flow|type)=="array" and ($card.flow|length)>0 then {flow:$card.flow} else {} end)
    + (if ($card.extraLinks|type)=="array" and ($card.extraLinks|length)>0 then {extraLinks:$card.extraLinks} else {} end)
    + (if ($card.summary|type)=="string" and $card.summary!="" then {summary:$card.summary} + (if ($card.summaryAt|type)=="string" then {summaryAt:$card.summaryAt} else {} end) else {} end)
  ')"
  out="$(_osrc_hub_status_override "$slug" "$out" | jq -c 'if .liveLanes == 0 and ((.status // "building") | ascii_downcase) == "building" then .status="idle" else . end')"
  printf '%s\n' "$out"
  type _osrc_hub_cache_put >/dev/null 2>&1 && _osrc_hub_cache_put "$slug" "$out"
  return 0
}

# _osrc_hub_status_override <slug> <project-json> -> project with the user's Mark done
# override from $OSRC_HOME/hub/status/<slug>.json (written by hub_server.py) merged LAST,
# so no card/orchestrator write can change a status whose shippedBy is "user".
# A Move back ("restore") record carries what the card said about shipping at click time
# (cardStatus, cardShippedAt). It holds through any number of card rewrites and yields only
# when the card says something new about shipping (MC-5 #2). Symlinks (the status folder or
# the file) are never followed.
_osrc_hub_status_override() {
  local d="$OSRC_HOME/hub/status" pf="$OSRC_HOME/hub/projects/$1.json" card='{}'
  local f="$d/$1.json"
  { [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$f" ] && [ ! -L "$f" ]; } || { printf '%s' "$2"; return 0; }
  { [ -f "$pf" ] && [ ! -L "$pf" ]; } && card="$(jq -c 'if type == "object" then {status, shippedAt} else {} end' "$pf" 2>/dev/null || printf '{}')"
  jq -c --slurpfile o "$f" --argjson card "$card" '
    ($o[0] // {}) as $o
    | (if ($o.prevStatus // "") == "" or $o.prevStatus == "shipped" then "building" else $o.prevStatus end) as $prev
    | if ($o | type) != "object" then .
      elif $o.shippedBy == "user" then
        . + {status:"shipped", shippedBy:"user", shippedAt:($o.shippedAt // null), prevStatus:$prev}
      elif $o.restoredBy == "user" and ($o | has("cardStatus")) and .status == "shipped"
           and ($card.status // null) == ($o.cardStatus // null)
           and ($card.shippedAt // null) == ($o.cardShippedAt // null) then
        .status = $prev
      else . end' <<<"$2" 2>/dev/null || printf '%s' "$2"
}

# _osrc_hub_mt <path...> -> newest mtime (epoch) of the paths that exist, 0 when none. Stat only.
_osrc_hub_mt() {
  local b=0 f m
  for f in "$@"; do
    [ -e "$f" ] || continue
    m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"   # GNU first: GNU `stat -f` is filesystem status (CI run 5)
    [ "$m" -gt "$b" ] 2>/dev/null && b="$m"
  done
  printf '%s' "$b"
}

# (MC2 r2 #4; here, not in hub-perf.sh, because suites source hub.sh alone.)
# _osrc_hub_reg_ts <id> -> newest registry ts (epoch) for the id, "" when unknown. Uses the memo index
# when open; returns 1 when no index exists so the caller can fall back to its own scan.
_osrc_hub_reg_ts() {
  [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -f "$_OSRC_HUB_MEMO/reg/.indexed" ] || return 1
  cat "$_OSRC_HUB_MEMO/reg/$1.ts" 2>/dev/null
  return 0
}

# _osrc_hub_tmux_row <id> -> "<created> <activity>" for a live tmux session (memo list, else tmux).
_osrc_hub_tmux_row() {
  if [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -f "$_OSRC_HUB_MEMO/tmux" ]; then
    awk -v s="$1" '$1 == s { print $2, $3; f = 1; exit } END { exit !f }' "$_OSRC_HUB_MEMO/tmux"
  else
    tmux has-session -t "=$1" 2>/dev/null && tmux display-message -p -t "=$1" '#{session_created} #{window_activity}' 2>/dev/null
  fi
}

# _osrc_hub_lane_activity <id> -> "<epoch> <live>": newest real activity of one owned lane (job dir files:
# meta.json, log, rc, status..., remote lane file, its review items, autodetach log/rc, tmux session_activity)
# and live=1 when the lane is working right now (a reconciled running job, a live remote lane, a working
# tmux session). MC-9: a busy project must never look stale because its card was not rewritten.
_osrc_hub_lane_activity() {
  local id="$1" b live=0 st ta
  b="$(_osrc_hub_mt "$OSRC_JOBS/$id"/* "$OSRC_HOME/remote/$id.json" "$OSRC_HOME/review/items/$id"-*.json "$OSRC_HOME/autodetach/$id.log" "$OSRC_HOME/autodetach/$id.rc")"
  if [ -d "$OSRC_JOBS/$id" ]; then
    st="$(_reconcile_status "$id" 2>/dev/null || cat "$OSRC_JOBS/$id/status" 2>/dev/null)"
    case "$st" in running|live|working|launching|stalled\?|exploring\?|no-progress-writes) live=1 ;; esac
  elif [ -f "$OSRC_HOME/remote/$id.json" ]; then
    type osrc_remote_state >/dev/null 2>&1 && [ "$(osrc_remote_state "$id" 2>/dev/null)" = live ] && live=1
  elif have tmux 2>/dev/null && ta="$(_osrc_hub_tmux_row "$id")" && [ -n "$ta" ]; then
    ta="${ta##* }"
    case "$ta" in ''|*[!0-9]*) ;; *) [ "$ta" -gt "$b" ] && b="$ta" ;; esac
    case "$(_owned_live_state "$id" 2>/dev/null)" in working|live|running) live=1 ;; esac
  fi
  # Session registry events and the done contract + its file hand-in are activity too (MC-9 r2 #1).
  local dc="$OSRC_HOME/done/$id.json" spec cwd hf r
  r="$(_osrc_hub_mt "$dc")"; [ "$r" -gt "$b" ] && b="$r"
  if [ -f "$dc" ] && have jq; then
    spec="$(jq -r '.spec // ""' "$dc" 2>/dev/null)"; cwd="$(jq -r '.cwd // ""' "$dc" 2>/dev/null)"
    case "$spec" in file:*) hf="${spec#file:}"; case "$hf" in /*) ;; *) hf="${cwd:-.}/$hf" ;; esac
      r="$(_osrc_hub_mt "$hf")"; [ "$r" -gt "$b" ] && b="$r" ;; esac
  fi
  if r="$(_osrc_hub_reg_ts "$id")"; then
    case "$r" in ''|*[!0-9]*) ;; *) [ "$r" -gt "$b" ] && b="$r" ;; esac
  elif [ -f "${OSRC_SESSION_REGISTRY:-}" ] && have jq; then
    r="$(jq -r --arg id "$id" 'select(.session_id==$id) | .ts // empty | if type=="number" then floor else (try fromdateiso8601 catch empty) end' "$OSRC_SESSION_REGISTRY" 2>/dev/null | sort -n | tail -1)"
    case "$r" in ''|*[!0-9]*) ;; *) [ "$r" -gt "$b" ] && b="$r" ;; esac
  fi
  # A satisfied done contract ends "working" for every lane kind, not only jobs (MC-9 r2 #2).
  [ "$live" = 1 ] && [ "$(_osrc_hub_done_state "$id")" = done ] && live=0
  printf '%s %s' "$b" "$live"
}

# _osrc_hub_project_mtime <slug> [lane-activity-epoch] [live] -> ISO-8601 of the project's newest real
# activity: its inputs (owner links, card, decisions) and, since MC-9, its owned lanes' activity. A live
# working lane makes it "now": stale means nothing moved. "" when nothing exists. Feeds the page's alarm.
_osrc_hub_project_mtime() {
  local slug="$1" best=0 la="${2:-0}"
  _osrc_hub_slug_ok "$slug" || { printf ''; return 0; }
  best="$(_osrc_hub_mt "$OSRC_HOME/owners/$slug"/* "$OSRC_HOME/hub/projects/$slug.json" "$OSRC_HOME/hub/decisions/$slug.json")"
  [ "$la" -gt "$best" ] 2>/dev/null && best="$la"
  [ "${3:-0}" = 1 ] && best="$(date +%s)"
  [ "$best" -gt 0 ] || { printf ''; return 0; }
  date -u -r "$best" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$best" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf ''
}

# osrc_hub_tick_touch <owner-session-id>: supervise's tick (every <= 10 min while an orchestrator runs)
# calls this. It rewrites the card's summary from the live lanes ("3 lanes: 2 building, 1 done") and
# summaryAt, keeping every other card field, so the narrative never reads older than one tick (MC-9 r2 #3).
osrc_hub_tick_touch() {
  local slug="${1:-}" f pj sum now tmp
  f="$OSRC_HOME/hub/projects/$slug.json"
  _osrc_hub_slug_ok "$slug" && [ -f "$f" ] && [ ! -L "$f" ] && have jq || return 1
  pj="$(_osrc_hub_build_project "$slug" "$(date +%s)" "$(date -u '+%a %d %b, %H:%M UTC')")" || return 1
  sum="$(jq -r '(.lanes // []) as $l | if ($l|length)==0 then "No lanes running." else
    "\($l|length) lane\(if ($l|length)==1 then "" else "s" end): " + ([$l[].status // "Building" | ascii_downcase] | group_by(.) | map("\(length) \(.[0])") | join(", ")) end' <<<"$pj" 2>/dev/null)" || return 1
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; tmp="$f.tick.$$"
  jq --arg s "$sum" --arg at "$now" '. + {summary:$s, summaryAt:$at}' "$f" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# _osrc_hub_unowned_project -> project doc for targets no owner session claims
# (jobs launched without CLAUDE_CODE_SESSION_ID, remote lanes added the same way).
_osrc_hub_unowned_project() {
  local now="$1" upd="$2" rmap lanes='[]' id lane claimed
  rmap="$(_osrc_hub_review_map)"
  local _nl='
'
  claimed="$(for d in "$OSRC_HOME"/owners/*/; do [ -d "$d" ] && for f in "$d"/*; do [ -f "$f" ] && printf '%s\n' "${f##*/}"; done; done 2>/dev/null)"
  # Unowned remote lanes.
  local rf
  for rf in "$OSRC_HOME"/remote/*.json; do
    [ -f "$rf" ] || continue
    id="$(basename "$rf" .json)"
    case "$_nl$claimed$_nl" in *"$_nl$id$_nl"*) continue ;; esac   # no grep per dir (MC2 r2 #4)
    lane="$(_osrc_hub_lane_remote "$id")" && [ -n "$lane" ] && lanes="$(jq -cn --argjson a "$lanes" --argjson b "$lane" '$a+[$b]')"
  done
  # Unowned job dirs (recent or live only — ancient done dirs are gc's job, not the hub's).
  local jd st mt now_s
  now_s="$(date +%s)"
  for jd in "$OSRC_JOBS"/*/; do
    [ -d "$jd" ] || continue
    id="$(basename "$jd")"
    case "$_nl$claimed$_nl" in *"$_nl$id$_nl"*) continue ;; esac   # no grep per dir (MC2 r2 #4)
    st="$(cat "$jd/status" 2>/dev/null || echo '?')"
    mt="$(stat -c %Y "$jd" 2>/dev/null || stat -f %m "$jd" 2>/dev/null || echo 0)"
    case "$st" in done|'done?'|failed|blocked|timeout|wedged|canceled|permission-blocked|interrupted)
      [ $(( now_s - ${mt:-0} )) -lt 86400 ] || continue ;; esac
    lane="$(_osrc_hub_lane_job "$id")" && [ -n "$lane" ] && lanes="$(jq -cn --argjson a "$lanes" --argjson b "$lane" '$a+[$b]')"
  done
  [ "$lanes" != "[]" ] || return 0
  local card upda live=0 act; card="$(_osrc_hub_card unowned)"
  for id in $(jq -r '.[].id' <<<"$lanes"); do act="$(_osrc_hub_lane_activity "$id")"; [ "${act##* }" = 1 ] && live=1; done
  upda="$(_osrc_hub_project_mtime unowned 0 "$live")"
  jq -cn --arg id unowned --arg name "Unowned runs" --argjson order 999 --arg upd "$upd" \
    --arg upda "$upda" --argjson live "$live" \
    --argjson now "$now" --argjson lanes "$lanes" --argjson decs '[]' --argjson card "$card" '
    {id:$id, name:$name, order:$order, updated:$upd, exported_at:$now, lanes:$lanes, decisions:$decs,
     tagline:"Runs launched without an owning orchestrator session.", liveLanes:$live, status:(if $live == 1 then "building" else "idle" end)}
    + (if $upda=="" then {} else {updatedAt:$upda} end)'
}

# ---- limits (the Lanes and limits rail) ------------------------------------------

# _osrc_hh_mm <epoch-seconds> -> "HH:MM" within 36h, else "Fri HH:MM"; empty input -> "".
_osrc_hh_mm() {
  case "${1:-}" in ''|*[!0-9]*) printf ''; return 0 ;; esac
  local now=$(( $(date +%s) ))
  # One clock across the page: everything displayed is UTC (review finding 5).
  if [ $(( $1 - now )) -le 129600 ]; then
    date -u -r "$1" '+%H:%M' 2>/dev/null || date -u -d "@$1" '+%H:%M' 2>/dev/null
  else
    date -u -r "$1" '+%a %H:%M' 2>/dev/null || date -u -d "@$1" '+%a %H:%M' 2>/dev/null
  fi
}

# _osrc_limit_state <pct-used> [resets_at-epoch] -> ok|low|out|wait|unknown.
# Boundaries mirror L7: <50 working, 50-89 running low, >=90 spent — `wait`
# (waiting for reset) when the window publishes a reset time, else `out`.
# Anything unreadable is `unknown`, never invented.
_osrc_limit_state() {
  case "${1:-}" in ''|*[!0-9.]*) printf 'unknown'; return 0 ;; esac
  if awk -v p="$1" 'BEGIN{ exit !(p>=90) }'; then
    case "${2:-}" in ''|*[!0-9]*) printf 'out' ;; *) printf 'wait' ;; esac
  elif awk -v p="$1" 'BEGIN{ exit !(p>=50) }'; then printf 'low'; else printf 'ok'; fi
}

# _osrc_limit_row <id> <name> <state> <left> <renews> <models> <note> <paid> <order> <updated> [source] [updatedAt-ISO]
_osrc_limit_row() {
  local bill=unknown token=''
  case "$1" in claude*) token=cc ;; chatgpt*) token=cx ;; devin) token=dv ;; agy) token=gm ;; openrouter) token=or ;; local) token=local ;; esac
  if [ -n "$token" ] && type osrc_lane_billing >/dev/null 2>&1; then bill="$(osrc_lane_billing "$token" 2>/dev/null)"; fi
  [ "$1" != openrouter ] || bill=metered
  [ "$1" != local ] || bill=free
  jq -cn --arg billing "${bill:-unknown}" --arg id "$1" --arg name "$2" --arg state "$3" --arg left "$4" --arg renews "$5" \
        --arg models "$6" --arg note "$7" --argjson paid "${8:-false}" --argjson order "${9:-99}" --arg updated "${10}" --arg source "${11:-}" \
        --arg upda "${12:-}" \
    '{id:$id,name:$name,state:$state,order:$order,billing:$billing}
     + (if $left=="" then {} else {left:$left} end)
     + (if $renews=="" then {} else {renews:$renews} end)
     + (if $models=="" then {} else {models:$models} end)
     + (if $note=="" then {} else {note:$note} end)
     + (if $updated=="" then {} else {updated:$updated} end)
     + (if $source=="" then {} else {source:$source} end)
     + (if $upda=="" then {} else {updatedAt:$upda} end)
     + (if $paid then {paid:true} else {} end)'
}

# _osrc_hub_limits -> JSON array for the rail's "Lanes and limits" panel.
# Preferred feed: L7's `osrc_limits_summary --json` (lib/spend.sh) — one live
# record per detected harness, recomputed on every export/poll. Its `updated`
# is an ISO checked-at; we mirror it into `updatedAt` (what the page's stale
# stamp parses) and trim the display field to HH:MM. When spend.sh is not
# loaded, rows are built below from the same L7 meter sources.
_osrc_hub_limits() {
  have jq 2>/dev/null || { printf '[]'; return 0; }
  if type osrc_limits_summary >/dev/null 2>&1; then
    local lsum; lsum="$(osrc_limits_summary --json 2>/dev/null)"
    # An EMPTY feed is not authoritative: it lists only provably-logged-in harnesses,
    # while the local builder below also covers artifact-evidenced rows (rate-limits
    # files, paid keys, installed-but-unmetered lanes). Fall back on [] too.
    if [ -n "$lsum" ] && jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"$lsum"; then
      jq -c '[.[] | . + {updatedAt: (.updatedAt // .updated // "")}
               | (if (.updated | type == "string") and (.updated | test("T")) then .updated = (.updated[11:16] + " UTC") else . end)]' <<<"$lsum"
      return 0
    fi
  fi
  _osrc_hub_limits_local
}

# _osrc_hub_limits_local -> rows built from the raw meter sources (fallback when
# lib/spend.sh is not loaded). Rows exist only for lanes detected for this user
# (installed AND logged in — the meter artifacts are themselves login
# evidence). Metered rows read L7's sources: the claude rate-limits artifact
# ($OSRC_HOME/rate-limits.json, then the token-optimizer copy — same
# precedence, 10-min freshness gate), and L7's _session_limits/
# _codex_rate_limits when lib/limits.sh is loaded for the ChatGPT windows. A
# stale or missing reading is `unknown`, never invented; Gemini CLI is retired
# and never listed. OpenRouter carries the paid tag.
_osrc_hub_limits_local() {
  have jq 2>/dev/null || { printf '[]'; return 0; }
  local now ts_ms stale c5='' c5r='' c7='' c7r='' cand raw arr='[]' upd='' upda='' src='statusline'
  now="$(date +%s)"
  # Claude windows: first fresh artifact wins.
  for cand in "$OSRC_HOME/rate-limits.json" "$HOME/.claude/token-optimizer/rate-limits.json"; do
    [ -f "$cand" ] && jq -e . "$cand" >/dev/null 2>&1 || continue
    raw="$(jq -r '"\(.five_hour.used_percentage // "")|\(.five_hour.resets_at // "")|\(.seven_day.used_percentage // "")|\(.seven_day.resets_at // "")|\(.timestamp // "")|\(.source // "statusline")"' "$cand" 2>/dev/null)"
    IFS='|' read -r c5 c5r c7 c7r ts_ms src <<EOF
$raw
EOF
    # Expired windows reset the reading rather than report an old percentage.
    case "$c5r" in ''|*[!0-9]*) : ;; *) [ "$c5r" -lt "$now" ] && c5="" ;; esac
    case "$c7r" in ''|*[!0-9]*) : ;; *) [ "$c7r" -lt "$now" ] && c7="" ;; esac
    case "$ts_ms" in ''|*[!0-9]*) stale=1; upd=""; upda="" ;;
      *) [ $(( now - ts_ms / 1000 )) -gt 600 ] && stale=1 || stale=0
         upd="$(date -u -r $(( ts_ms / 1000 )) '+%H:%M UTC' 2>/dev/null || date -u -d "@$(( ts_ms / 1000 ))" '+%H:%M UTC' 2>/dev/null)"
         upda="$(date -u -r $(( ts_ms / 1000 )) '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$(( ts_ms / 1000 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" ;;
    esac
    [ -n "$c5$c7" ] || stale=1
    [ "$stale" = 0 ] && break
  done
  local st leftr
  if [ -n "$c5$c7" ]; then
    local note5 note7
    note5="Session window, resets every 5 hours."
    note7="Weekly window — the binding cap in practice."
    [ "${stale:-1}" = 1 ] && { note5="$note5 Last reading is stale — treated as not checked, not exhausted."; note7="$note7 Last reading is stale — treated as not checked, not exhausted."; }
    if [ -n "$c5" ]; then
      st="$(_osrc_limit_state "$c5" "$c5r")"; [ "$stale" = 1 ] && st=unknown
      leftr="$(( 100 - ${c5%.*} ))% left"; [ "${c5%.*}" -ge 100 ] 2>/dev/null && leftr="0% left"
      arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row claude-5h 'Claude Code — 5 hour' "$st" "$leftr" "$(_osrc_hh_mm "$c5r")" 'claude-* on your Claude subscription' "$note5" false 1 "$upd" "$src" "$upda")" '$a+[$b]')"
    fi
    if [ -n "$c7" ]; then
      st="$(_osrc_limit_state "$c7" "$c7r")"; [ "$stale" = 1 ] && st=unknown
      leftr="$(( 100 - ${c7%.*} ))% left"; [ "${c7%.*}" -ge 100 ] 2>/dev/null && leftr="0% left"
      arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row claude-weekly 'Claude Code — weekly' "$st" "$leftr" "$(_osrc_hh_mm "$c7r")" 'claude-* on your Claude subscription' "$note7" false 2 "$upd" "$src" "$upda")" '$a+[$b]')"
    fi
  elif command -v claude >/dev/null 2>&1 || [ -d "$HOME/.claude" ]; then
    arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row claude 'Claude Code' unknown '' '' 'claude-* on your Claude subscription' 'Installed but no fresh limit reading — the statusline artifact is missing or over 10 minutes old.' false 1 '' '')" '$a+[$b]')"
  fi
  # ChatGPT windows via L7's normalized reader when it is loaded; codexage marks
  # a stale reading (a floor, never a measurement).
  local lim tok x5='' xw='' xage='' xraw x5r='' xwr=''
  if type _session_limits >/dev/null 2>&1; then
    lim="$(_session_limits 2>/dev/null)"
    for tok in $lim; do case "$tok" in codex5h=*) x5="${tok#*=}" ;; codexwk=*) xw="${tok#*=}" ;; codexage=*) xage="${tok#*=}" ;; esac; done
    if type _codex_rate_limits >/dev/null 2>&1; then
      xraw="$(_codex_rate_limits 2>/dev/null)" || xraw=''
      case "$xraw" in *\|*) x5r="$(printf '%s' "$xraw" | cut -d'|' -f3)"; xwr="$(printf '%s' "$xraw" | cut -d'|' -f4)" ;; esac
    fi
  fi
  if [ -n "$x5$xw" ]; then
    local updx=''
    case "$xage" in ''|*[!0-9]*) ;; *) updx="$(date -u -r $(( now - xage )) '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$(( now - xage ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" ;; esac
    if [ -n "$x5" ]; then
      st="$(_osrc_limit_state "$x5" "$x5r")"; [ -n "$xage" ] && st=unknown
      leftr="$(( 100 - ${x5%.*} ))% left"; [ "${x5%.*}" -ge 100 ] 2>/dev/null && leftr="0% left"
      arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row chatgpt-5h 'ChatGPT — 5 hour' "$st" "$leftr" "$(_osrc_hh_mm "$x5r")" 'sol, terra, gpt-5.* on your ChatGPT plan' "$([ -n "$xage" ] && printf 'Reading is %ss old — a floor, not a measurement.' "$xage" || printf 'Session window, resets every 5 hours.')" false 3 "$upd" 'codex rollout' "$updx")" '$a+[$b]')"
    fi
    if [ -n "$xw" ]; then
      st="$(_osrc_limit_state "$xw" "$xwr")"; [ -n "$xage" ] && st=unknown
      leftr="$(( 100 - ${xw%.*} ))% left"; [ "${xw%.*}" -ge 100 ] 2>/dev/null && leftr="0% left"
      arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row chatgpt-weekly 'ChatGPT — weekly' "$st" "$leftr" "$(_osrc_hh_mm "$xwr")" 'sol, terra, gpt-5.* on your ChatGPT plan' "$([ -n "$xage" ] && printf 'Reading is %ss old — a floor, not a measurement.' "$xage" || printf 'Weekly window — the binding cap in practice.')" false 4 "$upd" 'codex rollout' "$updx")" '$a+[$b]')"
    fi
  elif command -v codex >/dev/null 2>&1 || [ -d "$HOME/.codex" ]; then
    arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row chatgpt 'ChatGPT (Codex)' unknown '' '' 'sol, terra, gpt-5.* on your ChatGPT plan' 'Codex installed but no limit reading yet.' false 3 '' '')" '$a+[$b]')"
  fi
  # Unmetered lanes, only when detected installed: nothing invented about their
  # quota, so they read unknown (Devin/Antigravity) or trivially ok (paid/local).
  if command -v devin >/dev/null 2>&1; then
    arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row devin 'Devin' unknown 'plan quota, no meter' '' 'glm, swe, devin-* on your Devin plan' 'A plan refusal is only detectable when a run hits it.' false 5 '' '')" '$a+[$b]')"
  fi
  if command -v agy >/dev/null 2>&1; then
    arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row agy 'Antigravity' unknown 'no meter' '' 'gemini-*, nano-banana' 'No published meter.' false 6 '' '')" '$a+[$b]')"
  fi
  if [ -n "${OPENROUTER_API_KEY:-}" ] || grep -qs '^OPENROUTER_API_KEY=' "$HOME/.env" 2>/dev/null; then
    arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row openrouter 'OpenRouter' ok 'pay per use' '' 'OpenRouter model ids' 'Billed from your balance — outsourcerer asks before every run.' true 7 '' '')" '$a+[$b]')"
  fi
  if command -v ollama >/dev/null 2>&1 || [ -d "$HOME/.lmstudio" ]; then
    arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row local 'Local' ok 'free, your hardware' '' 'ollama:*, lmstudio:*, local:*' 'No meter, no bill.' false 8 '' '')" '$a+[$b]')"
  fi
  # Gemini CLI is retired — never listed.
  printf '%s' "$arr"
}

# ---- commands --------------------------------------------------------------------

# _osrc_hub_need <tool...> -> die naming every missing tool. hub export used to
# degrade to an empty projects/limits doc when a tool it calls was absent from
# PATH — the failure mode was indistinguishable from "nothing running".
_osrc_hub_need() {
  local t miss=""
  for t in "$@"; do have "$t" || miss="$miss $t"; done
  [ -z "$miss" ] || die "hub: required tool(s) not on PATH:$miss"
}

# cmd_hub_export [--project <slug>] -> SCHEMA docs JSON on stdout.
cmd_hub_export() {
  _osrc_hub_need jq date stat sort tr sed cut basename awk grep cat head
  local proj="" a
  while [ "$#" -gt 0 ]; do case "$1" in --project) proj="${2:-}"; shift 2 ;; *) shift ;; esac; done
  [ -z "$proj" ] || _osrc_hub_slug_ok "$proj" || die "hub export: bad project slug '$proj'"
  local now upd projects='[]' slug found=0
  now="$(date +%s)"; upd="$(date -u '+%a %d %b, %H:%M UTC')"
  type _osrc_hub_memo_begin >/dev/null 2>&1 && _osrc_hub_memo_begin   # one pane read per lane per export (MC2 r2 #4)
  # Slugs: every owner session + every decisions/projects file + unowned.
  local slugs=""
  local d f
  for d in "$OSRC_HOME"/owners/*/; do [ -d "$d" ] && slugs="$slugs $(basename "$d")"; done
  for f in "$OSRC_HOME"/hub/decisions/*.json "$OSRC_HOME"/hub/projects/*.json; do
    [ -f "$f" ] && slugs="$slugs $(basename "$f" .json)"
  done
  # de-dup
  slugs="$(printf '%s\n' $slugs | sort -u | tr '\n' ' ')"
  for slug in $slugs; do
    [ -n "$slug" ] || continue
    [ -n "$proj" ] && [ "$slug" != "$proj" ] && continue
    local pj; pj="$(_osrc_hub_build_project "$slug" "$now" "$upd")" || continue
    [ -n "$pj" ] && { projects="$(jq -cn --argjson a "$projects" --argjson b "$pj" '$a+[$b]')"; [ "$slug" = "$proj" ] && found=1; }
  done
  if [ -z "$proj" ]; then
    local uj; uj="$(_osrc_hub_unowned_project "$now" "$upd")"
    [ -n "$uj" ] && projects="$(jq -cn --argjson a "$projects" --argjson b "$uj" '$a+[$b]')"
  elif [ "$found" = 0 ]; then
    echo "hub export: no project '$proj' (slugs: owners/*, hub/decisions/*.json, hub/projects/*.json)" >&2
  fi
  local limits; if type _osrc_hub_limits_cached >/dev/null 2>&1; then limits="$(_osrc_hub_limits_cached)"; else limits="$(_osrc_hub_limits 2>/dev/null)"; fi
  case "$limits" in ''|*'error'*) limits='[]' ;; esac
  type _osrc_hub_memo_end >/dev/null 2>&1 && _osrc_hub_memo_end
  jq -cn --argjson now "$now" --argjson ps "$projects" --argjson ls "$limits" '{generated_at:$now, projects:$ps, limits:$ls}'
}

# cmd_hub_serve [--port N] [--no-open] [--new-token] -> local Mission Control
# on 127.0.0.1. Token persists in $OSRC_HOME/hub/token (0600) so the printed
# URL stays bookmarkable across restarts; --new-token rotates it. Default
# port is fixed; the server slides to the next free port and says so.
cmd_hub_serve() {
  local port="${OSRC_HUB_PORT:-}" noopen="${OSRC_HUB_NO_OPEN:-0}" newtok=0 scan=0
  while [ "$#" -gt 0 ]; do case "$1" in
    --port) port="${2:-}"; scan=0; shift 2 ;;
    --no-open) noopen=1; shift ;;
    --new-token) newtok=1; shift ;;
    *) die "hub serve: unknown option '$1' (usage: hub serve [--port N] [--no-open] [--new-token])" ;;
  esac; done
  if [ -z "$port" ]; then port=8788; scan=10; fi   # fixed default, slide up to 8798
  case "$port" in *[!0-9]*) die "hub serve: --port must be a number" ;; esac
  _osrc_hub_need python3 od cat tr mkdir chmod
  local dir="${_OSRC_FACTORY_DIR:-$SCRIPT_DIR}"
  local server="$dir/lib/hub_server.py" page="$dir/lib/hub.html" engine="$dir/outsourcerer.sh"
  [ -f "$server" ] && [ -f "$page" ] && [ -f "$engine" ] \
    || die "hub files missing under $dir/lib (hub_server.py, hub.html) or $engine"
  local tokf="$OSRC_HOME/hub/token" tok=""
  mkdir -p "$OSRC_HOME/hub"
  chmod 700 "$OSRC_HOME/hub" 2>/dev/null || die "hub serve: cannot chmod 700 $OSRC_HOME/hub"
  [ -L "$tokf" ] && die "hub serve: $tokf is a symlink — refusing a planted token file"
  if [ "$newtok" != 1 ] && [ -f "$tokf" ]; then
    tok="$(cat "$tokf" 2>/dev/null | tr -d ' \n')"
    case "$tok" in *[!0-9a-fA-F]*|'') tok="" ;; esac   # corrupt file -> mint below
    [ "${#tok}" -eq 32 ] || tok=""                   # exactly 16 bytes of hex
  fi
  if [ -z "$tok" ]; then
    tok="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [ -n "$tok" ] || die "hub serve: cannot read /dev/urandom for the access token — refusing to run with a guessable one"
    ( umask 077 && printf '%s\n' "$tok" > "$tokf" ) || die "hub serve: cannot write $tokf"
    [ "$newtok" = 1 ] && echo "hub serve: rotated the access token — old bookmarks are dead" >&2
  fi
  chmod 600 "$tokf" 2>/dev/null || die "hub serve: cannot chmod 600 $tokf"
  export OSRC_HUB_TOKEN="$tok"
  local -a args=(--bind 127.0.0.1 --port "$port" --page "$page" --engine "$engine" --osrc-home "$OSRC_HOME" --scan "$scan")
  [ "$noopen" = 1 ] && args+=(--no-open)
  exec python3 -I "$server" "${args[@]}"
}

cmd_hub() {
  local sub="${1:-}"
  case "$sub" in
    export) shift; cmd_hub_export "$@" ;;
    serve) shift; cmd_hub_serve "$@" ;;
    *) die "hub: export [--project SLUG] | serve [--port N] [--no-open] [--new-token]" ;;
  esac
}
