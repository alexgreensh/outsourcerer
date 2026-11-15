#!/usr/bin/env bash
# lib/cleanup.sh -- manifest-scoped cleanup of Outsourcerer's own leftovers, plus
# cmd_cleanup/cmd_gc (moved here verbatim from outsourcerer.sh for the size ratchet).
# Sourced by outsourcerer.sh; defines functions only, runs nothing at load time.
#
# Manifest: every durable thing Outsourcerer creates gets one line in
# $OSRC_HOME/created.jsonl: {"path","kind","session","repo","ts"}. `cleanup` with no
# target is a DRY RUN over the manifest: each item gets its size and a verdict,
# SAFE or ASK(with reason). `cleanup --apply` deletes SAFE items only and logs each
# deletion to $OSRC_HOME/cleanup.log. `cleanup --ack` records that the user has seen
# the current ASK list, which unblocks the <10GB launch gate. `cleanup <job-id|fanout-gid>
# [--force]` keeps its old meaning: remove that target's git worktree(s).
#
# SAFE requires ALL of: owning session done or gone, older than 1h, no process has a
# file open under it, path under the manifest's recorded root. Worktrees and branches
# additionally need a clean git status, no commits missing from the remote or main,
# and the lane's PR merged. Anything failing a check is ASK, shown, never deleted.

# ---- manifest recording -------------------------------------------------------

# _osrc_created_record <path> <kind> <session> <repo> -> append one manifest line.
# Best-effort: never fails a launch. kind: job|worktree|branch|autodetach|fanout|loop|
# isolated|tmp. session = the outsourcerer target id that created it (job id, tmux
# session name, fanout gid, loop id) so cleanup can ask "is the owner done or gone".
_osrc_created_record() {
  have jq 2>/dev/null || return 0
  local p="$1" k="$2" s="$3" r="${4:-}"
  [ -n "$p" ] || return 0
  case "$p" in *$'\n'*|*$'\r'*) return 0 ;; esac
  local f="$OSRC_HOME/created.jsonl"
  _mkdir_private "$OSRC_HOME" >/dev/null 2>&1 || mkdir -p "$OSRC_HOME" 2>/dev/null || return 0
  jq -cn --arg p "$p" --arg k "$k" --arg s "$s" --arg r "$r" --argjson t "$(date +%s)" \
    '{path:$p,kind:$k,session:$s,repo:$r,ts:$t}' >> "$f" 2>/dev/null || true
  return 0
}

# ---- shared helpers -------------------------------------------------------------

_osrc_cl_root() { printf '%s/cleanup' "$OSRC_HOME"; }
_osrc_cl_state() { printf '%s/cleanup/state.json' "$OSRC_HOME"; }
_osrc_cl_ack() { printf '%s/cleanup/ask-ack' "$OSRC_HOME"; }
_osrc_cl_log() { printf '%s/cleanup.log' "$OSRC_HOME"; }

# _osrc_free_kb -> available KB on the filesystem holding OSRC_HOME (df -P columns).
_osrc_free_kb() {
  df -kP "$OSRC_HOME" 2>/dev/null | awk 'NR==2 {print $4}'
}

# _osrc_path_newest_mtime <path> -> epoch of the newest mtime among the path and its
# immediate children (status/meta files land beside the dir entries, so depth-1 sees
# them without walking a whole worktree).
_osrc_path_newest_mtime() {
  local p="$1" m c cm newest=0
  m="$(stat -c %Y "$p" 2>/dev/null || stat -f %m "$p" 2>/dev/null)"
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  newest="$m"
  for c in "$p"/* "$p"/.[!.]*; do
    [ -e "$c" ] || [ -L "$c" ] || continue
    cm="$(stat -c %Y "$c" 2>/dev/null || stat -f %m "$c" 2>/dev/null)"
    case "$cm" in ''|*[!0-9]*) continue ;; esac
    [ "$cm" -gt "$newest" ] && newest="$cm"
  done
  printf '%s' "$newest"
}

# _osrc_owner_state <id> -> live|idle|done|gone|ask. done/gone mean the owner record
# can go. Remote lanes defer to osrc_remote_state when L2's module is loaded; session
# done-contracts defer to osrc_done_state when L6's module is loaded.
_osrc_owner_state() {
  local id="$1" st
  if [ -f "$OSRC_HOME/remote/$id.json" ]; then
    if type osrc_remote_state >/dev/null 2>&1; then
      st="$(osrc_remote_state "$id" 2>/dev/null)"
      case "$st" in live|ready) printf 'live' ;; done|failed) printf 'done' ;; gone) printf 'gone' ;; *) printf 'ask' ;; esac
      return 0
    fi
    # Fallback without L2: derive the same verdict from the lane json fields.
    if [ "$(jq -r '.branch_deleted // false' "$OSRC_HOME/remote/$id.json" 2>/dev/null)" = "true" ]; then printf 'failed'; return 0; fi
    if [ "$(jq -r '.head_ready // false' "$OSRC_HOME/remote/$id.json" 2>/dev/null)" = "true" ]; then printf 'done'; return 0; fi
    printf 'live'; return 0
  fi
  if type osrc_done_state >/dev/null 2>&1; then
    st="$(osrc_done_state "$id" 2>/dev/null)"
    case "$st" in
      done*) printf 'done'; return 0 ;;
      not-done|error*) printf 'ask'; return 0 ;;
    esac
  fi
  if type _owned_live_state >/dev/null 2>&1; then
    _owned_live_state "$id" 2>/dev/null
    return 0
  fi
  printf 'ask'
}

# _osrc_owner_known <id> -> 0 when ANY record of the owner exists. An owner with
# no record at all outlived (or never had) its maker: ASK, never gone.
_osrc_owner_known() {
  [ -d "$OSRC_JOBS/$1" ] || [ -d "$OSRC_HOME/loops/$1" ] \
    || [ -d "$OSRC_HOME/fanout/$1" ] || [ -d "$OSRC_HOME/isolated/$1" ] \
    || [ -f "$OSRC_HOME/remote/$1.json" ] \
    || [ -e "$OSRC_HOME/autodetach/$1.log" ] || [ -e "$OSRC_HOME/autodetach/$1.rc" ] \
    || ls -d "$OSRC_HOME/owners"/*/"$1" >/dev/null 2>&1
}

# _osrc_job_collected <id> -> 0 when nothing still points at the job's result:
# no owner record (the stop-guard reaps it only once the owner's turn ends with
# the result delivered) and no running wait/fanout wait covers it.
_osrc_job_collected() {
  ls -d "$OSRC_HOME/owners"/*/"$1" >/dev/null 2>&1 && return 1
  _waited_ids 2>/dev/null | grep -qxF "$1" && return 1
  return 0
}

# _osrc_lsof_busy <path> -> 0 busy, 1 clear, 2 cannot-verify (caller treats as ASK).
# macOS lsof returns 1 even when it lists files, so the exit code is useless: the
# listing itself is the signal (empty stdout = nothing open, any row = busy).
# Directories use `lsof +D`; plain files `lsof --` (lsof +D on a file only warns).
# stderr is discarded inside the wrapped call so a WARNING never reads as "busy"
# through _timeout's merged capture.
_osrc_lsof_busy() {
  have lsof 2>/dev/null || return 2
  local out rc
  if [ -d "$1" ]; then
    out="$(_timeout "${OSRC_CLEANUP_LSOF_TIMEOUT:-25}" bash -c 'exec lsof +D "$1" 2>/dev/null' _ "$1")"
  else
    out="$(_timeout "${OSRC_CLEANUP_LSOF_TIMEOUT:-25}" bash -c 'exec lsof -- "$1" 2>/dev/null' _ "$1")"
  fi
  rc=$?
  case "$rc" in 124) return 2 ;; esac   # timed out: doubt -> ASK
  case "$rc" in 0|1) : ;; *) return 2 ;; esac
  [ -n "$out" ] && return 0
  return 1
}

# _osrc_branch_merged <repo> <branch> [base_sha] -> 0 when the branch's commits are
# preserved: tip is an ancestor of the recorded base or any main-ish ref, or a MERGED
# PR exists for it. 1 otherwise (caller ASK).
_osrc_branch_merged() {
  local repo="$1" br="$2" base="${3:-}" ref
  git -C "$repo" rev-parse --verify "refs/heads/$br" >/dev/null 2>&1 || return 1
  local -a bases=()
  [ -n "$base" ] && bases+=("$base")
  for ref in origin/HEAD origin/main origin/master main master upstream/main upstream/master; do
    git -C "$repo" rev-parse --verify -q "$ref" >/dev/null 2>&1 && bases+=("$ref")
  done
  local b
  for b in "${bases[@]}"; do
    git -C "$repo" merge-base --is-ancestor "$br" "$b" 2>/dev/null && return 0
  done
  # No local ref contains it: a merged PR preserves the work ONLY when the PR's
  # merged head is this branch's current tip — commits made after the merge are
  # not preserved by that PR (review finding 2).
  if have gh 2>/dev/null; then
    local tip
    tip="$(git -C "$repo" rev-parse "$br" 2>/dev/null)"
    [ -n "$tip" ] \
      && (cd "$repo" 2>/dev/null && gh pr list --head "$br" --state merged \
            --json headRefOid --jq '.[].headRefOid' 2>/dev/null | grep -qx "$tip") \
      && return 0
  fi
  return 1
}

# _osrc_branch_checked_out <repo> <branch> -> 0 when a worktree still has it checked out.
_osrc_branch_checked_out() {
  git -C "$1" worktree list --porcelain 2>/dev/null | grep -qx "branch refs/heads/$2"
}

# _osrc_cleanup_verdict <manifest-json> -> prints "VERDICT<TAB>reason"
# VERDICT in SAFE|ASK|GONE.
_osrc_cleanup_verdict() {
  local item="$1" path kind sess repo ts rp root pp newest now st why
  path="$(jq -r '.path // ""' <<<"$item")"
  kind="$(jq -r '.kind // ""' <<<"$item")"
  sess="$(jq -r '.session // ""' <<<"$item")"
  repo="$(jq -r '.repo // ""' <<<"$item")"
  [ -n "$path" ] && [ -n "$kind" ] || { printf 'ASK\tmalformed manifest line\n'; return 0; }

  if [ "$kind" = "branch" ]; then
    [ -n "$repo" ] && git -C "$repo" rev-parse --verify "refs/heads/$path" >/dev/null 2>&1 \
      || { printf 'GONE\tbranch absent\n'; return 0; }
  else
    [ -e "$path" ] || [ -L "$path" ] || { printf 'GONE\tpath absent\n'; return 0; }
  fi

  # A manifest line must LOOK like what its kind makes before anything else is
  # trusted (review finding 5): per-kind shape, and '..' never in a real record.
  case "$path" in *..*) printf 'ASK\tpath contains ..\n'; return 0 ;; esac
  # Root containment: worktrees/branches are repo-scoped; every other kind lives under
  # $OSRC_HOME (jobs, fanout, loops, autodetach, isolated, tmp), so that is their root.
  case "$kind" in worktree|branch) root="$repo" ;; *) root="$OSRC_HOME" ;; esac
  [ -n "$root" ] || { printf 'ASK\tno recorded root\n'; return 0; }
  rp="$(_osrc_realpath "$root" 2>/dev/null)" || { printf 'ASK\trecorded root not resolvable\n'; return 0; }

  if [ "$kind" = "branch" ]; then
    case "$path" in ''|.*|*..*|*[!A-Za-z0-9._/-]*|-*|*//*) printf 'ASK\tbad branch name\n'; return 0 ;; esac
  else
    pp="$(_osrc_realpath "$path" 2>/dev/null)" || { printf 'ASK\tpath not resolvable\n'; return 0; }
    case "$pp" in "$rp"/*) : ;; *) printf 'ASK\tpath outside recorded root\n'; return 0 ;; esac
    case "$pp" in
      "$rp"|"$OSRC_HOME"|"$HOME"|"/") printf 'ASK\trefusing protected root\n'; return 0 ;;
    esac
    case "${pp##*/}" in
      node_modules|.venv|venv|store|state|.env|.git|.outsourcerer) printf 'ASK\tload-bearing path\n'; return 0 ;;
    esac
    case "$kind" in
      job)        case "$pp" in "$OSRC_HOME"/jobs/"$sess") : ;; *) printf 'ASK\tnot the shape of a job dir\n'; return 0 ;; esac ;;
      loop)       case "$pp" in "$OSRC_HOME"/loops/"$sess") : ;; *) printf 'ASK\tnot the shape of a loop dir\n'; return 0 ;; esac ;;
      fanout)     case "$pp" in "$OSRC_HOME"/fanout/"$sess") : ;; *) printf 'ASK\tnot the shape of a fanout dir\n'; return 0 ;; esac ;;
      isolated)   case "$pp" in "$OSRC_HOME"/isolated/"$sess") : ;; *) printf 'ASK\tnot the shape of an isolated dir\n'; return 0 ;; esac ;;
      autodetach) case "$pp" in "$OSRC_HOME"/autodetach/"$sess".log|"$OSRC_HOME"/autodetach/"$sess".rc) : ;; *) printf 'ASK\tnot the shape of an autodetach file\n'; return 0 ;; esac ;;
      worktree)   case "$pp" in "$rp"/.outsourcerer/worktrees/"$sess") : ;; *) printf 'ASK\tnot the shape of a worktree\n'; return 0 ;; esac ;;
      tmp)        case "$pp" in "$OSRC_HOME"/tmp/?*) : ;; *) printf 'ASK\tnot the shape of a tmp path\n'; return 0 ;; esac ;;
      *)          printf 'ASK\tunknown kind %s\n' "$kind"; return 0 ;;
    esac
  fi

  # Owning session done or gone; 'gone' still needs a record to have existed.
  st="$(_osrc_owner_state "$sess")"
  case "$st" in
    done) : ;;
    gone) _osrc_owner_known "$sess" \
        || { printf 'ASK\towner %s has no record at all\n' "$sess"; return 0; } ;;
    ask) printf 'ASK\towner state undecidable\n'; return 0 ;;
    *) printf 'ASK\towner %s still %s\n' "$sess" "$st"; return 0 ;;
  esac

  if [ "$kind" != "branch" ]; then
    newest="$(_osrc_path_newest_mtime "$pp")"
    now="$(date +%s)"
    case "$newest" in ''|*[!0-9]*|0) printf 'ASK\tcannot read modification time\n'; return 0 ;; esac
    [ $(( now - newest )) -ge "${OSRC_CLEANUP_MIN_AGE:-3600}" ] \
      || { printf 'ASK\tyounger than 1h\n'; return 0; }
    _osrc_lsof_busy "$pp"; local lrc=$?
    case "$lrc" in
      1) : ;;
      0) printf 'ASK\tfiles open under it\n'; return 0 ;;
      *) printf 'ASK\topen-file check could not verify\n'; return 0 ;;
    esac
  fi

  case "$kind" in
    job)
      # A job dir is the lane's evidence. SAFE only when it finished clean AND its
      # result was collected, or it is past the same 3-day TTL gc uses; a blocked
      # or failed dir keeps its evidence until then (review finding 4).
      local jstat
      jstat="$(_reconcile_status "$sess" 2>/dev/null || printf '?')"
      case "$jstat" in
        # 'done?' means finished-but-unverified: it keeps evidence like any
        # other non-clean status until the TTL, never cleans up early (B4).
        done)
          _osrc_job_collected "$sess" \
            || { printf 'ASK\tjob done but result not collected\n'; return 0; } ;;
        *) [ $(( now - newest )) -ge "${OSRC_CLEANUP_JOB_TTL:-259200}" ] \
             || { printf 'ASK\tjob status %s — evidence kept for 3d\n' "${jstat:-?}"; return 0; } ;;
      esac
      ;;
    worktree)
      [ -d "$pp" ] || { printf 'ASK\tworktree path is not a directory\n'; return 0; }
      # --untracked-files=all beats a repo's status.showUntrackedFiles=no:
      # hidden untracked files must still read as uncommitted changes (review B1).
      [ -z "$(git -C "$pp" status --porcelain --untracked-files=all 2>/dev/null | head -1)" ] \
        || { printf 'ASK\tworktree has uncommitted changes\n'; return 0; }
      # Ignored files are invisible to the check above: a .env or a gitignored
      # deliverable would die with a "clean" worktree. Disposable caches only;
      # .env* and anything else is ASK, named (review finding 1). This call uses
      # --untracked-files=normal, not =all: it still overrides a user's
      # showUntrackedFiles=no but keeps ignored dirs collapsed to '!! dir/', so
      # an allowlisted cache like node_modules/ matches whole (finding 1, r3).
      local ig ifile igbad=""
      ig="$(git -C "$pp" status --porcelain --ignored --untracked-files=normal 2>/dev/null | sed -n 's/^!! //p')"
      if [ -n "$ig" ]; then
        while IFS= read -r ifile; do
          [ -n "$ifile" ] || continue
          case "${ifile%/}" in
            # Only pure dependency caches are disposable. dist/build/target
            # can hold the lane's actual deliverable (review B3).
            node_modules|.venv|__pycache__) : ;;
            *) local lbl="${ifile%/}"
               # A collapsed '!! dir/' entry names the folder but not what is
               # in it; expand a few contents so the ASK reason shows what
               # would be lost (r4 smaller).
               case "$ifile" in
                 */) local ex
                     ex="$(git -C "$pp" status --porcelain --ignored --untracked-files=all 2>/dev/null \
                       | awk -v d="!! $ifile" 'index($0,d)==1 { sub(d,""); print }' \
                       | head -3 | paste -sd', ' -)"
                     [ -n "$ex" ] && lbl="$lbl ($ex)" ;;
               esac
               igbad="${igbad:+$igbad, }$lbl" ;;
          esac
        done <<<"$ig"
        [ -z "$igbad" ] || { printf 'ASK\tignored files in worktree: %s\n' "$igbad"; return 0; }
      fi
      local wj br base
      wj="$OSRC_JOBS/$sess/worktree.json"; [ -f "$wj" ] || wj="$OSRC_HOME/loops/$sess/worktree.json"
      br="$(jq -r '.branch // ""' "$wj" 2>/dev/null)"; base="$(jq -r '.base_sha // ""' "$wj" 2>/dev/null)"
      [ -n "$br" ] || br="$(git -C "$pp" rev-parse --abbrev-ref HEAD 2>/dev/null)"
      [ -n "$br" ] && [ "$br" != "HEAD" ] || { printf 'ASK\tcannot determine worktree branch\n'; return 0; }
      _osrc_branch_merged "$repo" "$br" "$base" \
        || { printf 'ASK\tbranch %s has commits missing from remote/main and no merged PR\n' "$br"; return 0; }
      ;;
    branch)
      _osrc_branch_checked_out "$repo" "$path" \
        && { printf 'ASK\tbranch still checked out in a worktree\n'; return 0; }
      local wj2 base2
      wj2="$OSRC_JOBS/$sess/worktree.json"; [ -f "$wj2" ] || wj2="$OSRC_HOME/loops/$sess/worktree.json"
      base2="$(jq -r '.base_sha // ""' "$wj2" 2>/dev/null)"
      _osrc_branch_merged "$repo" "$path" "$base2" \
        || { printf 'ASK\tcommits missing from remote/main and no merged PR\n'; return 0; }
      ;;
    fanout)
      local gd2="$OSRC_HOME/fanout/$sess" jid2 st2 bad=0
      if [ -f "$gd2/members.tsv" ]; then
        while IFS="$(printf '\t')" read -r jid2 _lbl; do
          [ -n "$jid2" ] || continue
          st2="$(_osrc_owner_state "$jid2")"
          case "$st2" in done|gone) : ;; *) bad=1 ;; esac
        done < "$gd2/members.tsv"
        [ "$bad" = 0 ] || { printf 'ASK\ta fanout member is still live\n'; return 0; }
      fi
      ;;
    loop)
      # Same evidence rule as jobs (review B2): SAFE only on a clean finish
      # whose result was collected, or past the 3-day TTL. A blocked or
      # still-running loop's state file is evidence, not trash.
      local lst
      lst="$(cat "$OSRC_HOME/loops/$sess/state" 2>/dev/null)"
      case "$lst" in
        success|done)
          _osrc_job_collected "$sess" \
            || { printf 'ASK\tloop finished but result not collected\n'; return 0; } ;;
        *) [ $(( now - newest )) -ge "${OSRC_CLEANUP_JOB_TTL:-259200}" ] \
             || { printf 'ASK\tloop state %s — evidence kept for 3d\n' "${lst:-unknown}"; return 0; } ;;
      esac
      ;;
    autodetach)
      # Same evidence rule as jobs (review B2). The .rc marker holds the pane's
      # exit code; only a 0 exit is a clean finish. A missing marker means the
      # run never finished reporting — that log is evidence, not trash.
      local arc
      [ -f "$OSRC_HOME/autodetach/$sess.rc" ] \
        && arc="$(tr -dc '0-9' < "$OSRC_HOME/autodetach/$sess.rc")" || arc=""
      case "$arc" in
        0)
          _osrc_job_collected "$sess" \
            || { printf 'ASK\tautodetach exited 0 but result not collected\n'; return 0; } ;;
        *) [ $(( now - newest )) -ge "${OSRC_CLEANUP_JOB_TTL:-259200}" ] \
             || { printf 'ASK\tautodetach exit %s — evidence kept for 3d\n' "${arc:-none}"; return 0; } ;;
      esac
      ;;
  esac
  printf 'SAFE\t\n'
}

# ---- scan ---------------------------------------------------------------------

# _osrc_cleanup_items -> one JSON object per manifest line (deduped, last record wins,
# with verdict+why). Args: [--no-size] skips du.
_osrc_cleanup_items() {
  have jq 2>/dev/null || return 1
  local mf="$OSRC_HOME/created.jsonl" nosize=0 a line item verdict why ksize
  [ "${1:-}" = "--no-size" ] && nosize=1
  [ -f "$mf" ] || return 0
  jq -cs 'group_by(.path + "" + .kind) | map(last)' "$mf" 2>/dev/null | jq -c '.[]' | \
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    verdict="$(_osrc_cleanup_verdict "$item")"
    why="${verdict#*$'\t'}"; verdict="${verdict%%$'\t'*}"
    ksize=""
    if [ "$nosize" = 0 ] && [ "$verdict" != "GONE" ]; then
      local pp; pp="$(jq -r '.path' <<<"$item")"
      if [ -d "$pp" ]; then
        local du_out du_rc
        du_out="$(_timeout "${OSRC_CLEANUP_DU_TIMEOUT:-30}" du -sk "$pp" 2>/dev/null | awk '{print $1}')"
        case "$du_out" in ''|*[!0-9]*) du_out="" ;; esac
        ksize="$du_out"
      fi
    fi
    jq -cn --argjson m "$item" --arg v "$verdict" --arg w "$why" --arg k "$ksize" \
      '$m + {verdict:$v, why:$w, size_kb:(if $k=="" then null else ($k|tonumber) end)}'
  done
}

# _osrc_cleanup_state_write <items-json-lines> -> state.json for the disk gate.
_osrc_cleanup_state_write() {
  local items="$1" free_kb free_gb ask_hash n_safe n_ask
  have jq 2>/dev/null || return 1
  free_kb="$(_osrc_free_kb)"; case "$free_kb" in ''|*[!0-9]*) free_kb=0 ;; esac
  free_gb=$(( free_kb / 1048576 ))
  n_safe="$(printf '%s' "$items" | jq -s '[.[]|select(.verdict=="SAFE")]|length' 2>/dev/null)"; n_safe="${n_safe:-0}"
  n_ask="$(printf '%s' "$items" | jq -s '[.[]|select(.verdict=="ASK")]|length' 2>/dev/null)"; n_ask="${n_ask:-0}"
  ask_hash="$(printf '%s' "$items" | jq -s '[.[]|select(.verdict=="ASK")|.path+""+.kind]|sort|join("\n")' 2>/dev/null | cksum | awk '{print $1}')"
  mkdir -p "$(_osrc_cl_root)" 2>/dev/null || return 1
  jq -cn --argjson ts "$(date +%s)" --argjson fg "$free_gb" --argjson t "$n_safe" --argjson a "$n_ask" --arg h "$ask_hash" \
    '{ts:$ts, free_gb:$fg, safe:$t, ask:$a, ask_hash:$h}' > "$(_osrc_cl_state).tmp.$$" 2>/dev/null \
    && mv -f "$(_osrc_cl_state).tmp.$$" "$(_osrc_cl_state)" || rm -f "$(_osrc_cl_state).tmp.$$"
}

# ---- user-facing commands -------------------------------------------------------

_osrc_human_kb() { # <kb> -> "1.2G" style
  local k="${1:-0}"
  case "$k" in ''|*[!0-9]*) k=0 ;; esac
  if [ "$k" -ge 1048576 ]; then printf '%sG' "$(( k / 1048576 ))"
  elif [ "$k" -ge 1024 ]; then printf '%sM' "$(( k / 1024 ))"
  else printf '%sK' "$k"; fi
}

_osrc_cleanup_dryrun() {
  have jq 2>/dev/null || die "cleanup needs jq"
  local mf="$OSRC_HOME/created.jsonl" items n_safe n_ask n_gone free_gb
  if [ ! -f "$mf" ]; then
    echo "[outsourcerer] cleanup: no manifest yet ($mf). Nothing Outsourcerer-created is recorded."
    return 0
  fi
  items="$(_osrc_cleanup_items)"
  _osrc_cleanup_state_write "$items" || true
  n_safe="$(printf '%s' "$items" | jq -s '[.[]|select(.verdict=="SAFE")]|length' 2>/dev/null)"; n_safe="${n_safe:-0}"
  n_ask="$(printf '%s' "$items" | jq -s '[.[]|select(.verdict=="ASK")]|length' 2>/dev/null)"; n_ask="${n_ask:-0}"
  n_gone="$(printf '%s' "$items" | jq -s '[.[]|select(.verdict=="GONE")]|length' 2>/dev/null)"; n_gone="${n_gone:-0}"
  free_gb="$(( $(_osrc_free_kb) / 1048576 ))"
  echo "[outsourcerer] cleanup (dry run) — free disk ${free_gb}GB; $n_safe SAFE, $n_ask ASK, $n_gone already gone."
  printf '%s\n' "$items" | jq -r 'select(.verdict != "GONE")
    | "  " + .verdict + "  " + ((.size_kb // 0) | tostring) + "KB  " + (.kind // "?") + "  " + (.path // "?")
      + (if .why != "" then "  — " + .why else "" end)' 2>/dev/null
  [ "$n_gone" -gt 0 ] && echo "  ($n_gone manifest entries already gone; left in the log.)"
  echo "[outsourcerer] SAFE items delete with: $0 cleanup --apply"
  [ "$n_ask" -gt 0 ] && echo "[outsourcerer] ASK items need your call; after reviewing: $0 cleanup --ack"
}

_osrc_cleanup_apply() {
  have jq 2>/dev/null || die "cleanup --apply needs jq"
  local mf="$OSRC_HOME/created.jsonl"
  [ -f "$mf" ] || { echo "[outsourcerer] cleanup: no manifest yet."; return 0; }
  local items line item verdict path kind repo sess pp deleted=0 failed=0
  # Order matters: a branch is only SAFE once its worktree is gone (checked-out check),
  # so worktrees delete before branches regardless of manifest order.
  items="$(have jq 2>/dev/null && _osrc_cleanup_items --no-size | jq -sc \
    'sort_by(if .kind=="worktree" then 0 elif .kind=="branch" then 2 else 1 end, .path) | .[]' 2>/dev/null)"
  [ -n "$items" ] || items="$(_osrc_cleanup_items --no-size)"
  _osrc_cleanup_state_write "$items" || true
  local log; log="$(_osrc_cl_log)"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    # Re-verify EVERY item at delete time, not just scan-SAFE ones: the scan snapshot
    # may be seconds old (an owner can come back live, a file can open), and an ASK
    # can become SAFE mid-apply (a branch's worktree is removed earlier in this loop).
    # Doubt at delete = skip; only a fresh SAFE verdict deletes.
    local re_verdict
    re_verdict="$(_osrc_cleanup_verdict "$(jq -c 'del(.verdict,.why,.size_kb)' <<<"$item")")"
    [ "${re_verdict%%$'\t'*}" = "SAFE" ] || continue
    verdict="SAFE"
    path="$(jq -r '.path' <<<"$item")"; kind="$(jq -r '.kind' <<<"$item")"
    repo="$(jq -r '.repo // ""' <<<"$item")"; sess="$(jq -r '.session // ""' <<<"$item")"
    pp="$path"
    [ "$kind" != "branch" ] && pp="$(_osrc_realpath "$path" 2>/dev/null)"
    case "$kind" in
      worktree)
        if git -C "$repo" worktree remove "$pp" 2>/dev/null; then
          git -C "$repo" worktree prune 2>/dev/null || true
          printf '%s\tremoved-worktree\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pp" >> "$log"
          deleted=$((deleted+1))
        else
          printf '%s\tFAILED-worktree\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pp" >> "$log"
          failed=$((failed+1))
        fi ;;
      branch)
        if git -C "$repo" branch -D "$path" >/dev/null 2>&1; then
          printf '%s\tremoved-branch\t%s (%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$path" "$repo" >> "$log"
          deleted=$((deleted+1))
        else
          printf '%s\tFAILED-branch\t%s (%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$path" "$repo" >> "$log"
          failed=$((failed+1))
        fi ;;
      *)
        if [ -d "$pp" ]; then rm -rf "$pp" 2>/dev/null
        elif [ -e "$pp" ] || [ -L "$pp" ]; then rm -f "$pp" 2>/dev/null; fi
        if [ ! -e "$pp" ] && [ ! -L "$pp" ]; then
          printf '%s\tremoved\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pp" >> "$log"
          deleted=$((deleted+1))
        else
          printf '%s\tFAILED\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pp" >> "$log"
          failed=$((failed+1))
        fi ;;
    esac
  done <<<"$items"
  # Refresh state after deletion so the gate sees the new ASK/SAFE split.
  items="$(_osrc_cleanup_items --no-size)"; _osrc_cleanup_state_write "$items" || true
  echo "[outsourcerer] cleanup --apply: removed $deleted item(s), $failed failed; log: $log"
}

_osrc_cleanup_ack() {
  have jq 2>/dev/null || die "cleanup --ack needs jq"
  local items ah n_ask
  items="$(_osrc_cleanup_items --no-size)"
  n_ask="$(printf '%s' "$items" | jq -s '[.[]|select(.verdict=="ASK")]|length' 2>/dev/null)"; n_ask="${n_ask:-0}"
  [ "${n_ask:-0}" -gt 0 ] || { echo "[outsourcerer] cleanup: no ASK items — nothing to acknowledge."; return 0; }
  ah="$(printf '%s' "$items" | jq -s '[.[]|select(.verdict=="ASK")|.path+""+.kind]|sort|join("\n")' 2>/dev/null | cksum | awk '{print $1}')"
  mkdir -p "$(_osrc_cl_root)" 2>/dev/null || die "cannot create $(_osrc_cl_root)"
  printf '%s\n' "$ah" > "$(_osrc_cl_ack)"
  echo "[outsourcerer] cleanup: ASK list acknowledged. New leftovers will re-block launches below ${OSRC_DISK_MIN_GB:-10}GB free until reviewed."
}

# ---- supervisor hook ------------------------------------------------------------

# _osrc_cleanup_tick_run -> one scan + conditional apply + ASK wake. Runs detached
# from the heartbeat so lsof/du never stall the beacon.
_osrc_cleanup_tick_run() {
  have jq 2>/dev/null || return 0
  local free_kb free_gb items n_ask n_safe ah last_alerted alert_dir
  free_kb="$(_osrc_free_kb)"; case "$free_kb" in ''|*[!0-9]*) return 0 ;; esac
  free_gb=$(( free_kb / 1048576 ))
  items="$(_osrc_cleanup_items --no-size)"
  _osrc_cleanup_state_write "$items" || true
  n_ask="$(printf '%s' "$items" | jq -s '[.[]|select(.verdict=="ASK")]|length' 2>/dev/null)"; n_ask="${n_ask:-0}"
  n_safe="$(printf '%s' "$items" | jq -s '[.[]|select(.verdict=="SAFE")]|length' 2>/dev/null)"; n_safe="${n_safe:-0}"
  # Review finding 6: until the SAFE-verdict findings are proven the heartbeat
  # SCANS and WAKES only — it never applies. Apply stays a typed `cleanup --apply`.
  if [ "$n_ask" -gt 0 ] && type _wake_append >/dev/null 2>&1; then
    ah="$(printf '%s' "$items" | jq -s '[.[]|select(.verdict=="ASK")|.path+""+.kind]|sort|join("\n")' 2>/dev/null | cksum | awk '{print $1}')"
    alert_dir="$(_osrc_cl_root)"; mkdir -p "$alert_dir" 2>/dev/null || return 0
    last_alerted="$(cat "$alert_dir/.alerted" 2>/dev/null)"
    if [ "$ah" != "$last_alerted" ]; then
      printf '%s\n' "$ah" > "$alert_dir/.alerted" 2>/dev/null || true
      _wake_append "$(jq -cn --arg h "$ah" --argjson n "$n_ask" --argjson fg "$free_gb" \
        '{event_id:("cleanup.ask." + $h),kind:"cleanup-ask",state:"ask",task_summary:("outsourcerer cleanup: " + ($n|tostring) + " leftover item(s) need your decision; free disk " + ($fg|tostring) + "GB. Dry run: outsourcerer cleanup; apply SAFE: cleanup --apply; acknowledge ASK: cleanup --ack")}')" >/dev/null 2>&1 || true
    fi
  fi
  return 0
}

# _osrc_cleanup_tick -> hourly gate called from _heartbeat_tick. Cheap stat check per
# tick; the real scan runs detached in _osrc_cleanup_tick_run.
_osrc_cleanup_tick() {
  local stamp now age
  stamp="$(_osrc_cl_root)/.tick"
  now="$(date +%s)"
  if [ -f "$stamp" ]; then
    age=$(( now - $(cat "$stamp" 2>/dev/null || echo 0) ))
    case "$age" in ''|*[!0-9]*) age=999999 ;; esac
    [ "$age" -lt "${OSRC_CLEANUP_TICK_SECS:-3600}" ] && return 0
  fi
  mkdir -p "$(_osrc_cl_root)" 2>/dev/null || return 0
  local lock="$(_osrc_cl_root)/.lock" lage token corpse current
  _osrc_guarded_mutex_acquire "$lock" || return 0
  if ! _osrc_atomic_mkdir "$lock"; then
    lage=$(( now - $(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo 0) ))
    corpse="$lock.stale.${BASHPID:-$$}.$RANDOM"
    if ! { [ "$lage" -gt 600 ] && mv "$lock" "$corpse" 2>/dev/null \
      && rm -rf "$corpse" 2>/dev/null && _osrc_atomic_mkdir "$lock"; }; then
      _osrc_guarded_mutex_release "$lock" || true
      return 0
    fi
  fi
  token="${BASHPID:-$$}.$RANDOM.$RANDOM"
  if ! printf '%s\n' "$token" > "$lock/owner" 2>/dev/null; then
    rm -f "$lock/owner" 2>/dev/null
    rmdir "$lock" 2>/dev/null || true
    _osrc_guarded_mutex_release "$lock" || true
    return 0
  fi
  date +%s > "$stamp" 2>/dev/null || true
  _osrc_guarded_mutex_release "$lock" || return 0
  ( _osrc_cleanup_tick_run
    if _osrc_guarded_mutex_acquire "$lock"; then
      current="$(cat "$lock/owner" 2>/dev/null)"
      if [ "$current" = "$token" ]; then rm -f "$lock/owner"; rmdir "$lock" 2>/dev/null || true; fi
      _osrc_guarded_mutex_release "$lock" || true
    fi ) >/dev/null 2>&1 &
  return 0
}

# _osrc_disk_gate -> refuse new lane launches while free disk < OSRC_DISK_MIN_GB (10)
# and the CURRENT ASK list has not been acknowledged. Called from _bg_launch,
# route_delegate and session start; dies with the fix when it refuses. Under
# pressure it rescans live: the tick's state file can be an hour old, and an ack
# must match the list as it is now (review finding 8).
_osrc_disk_gate() {
  local free_kb free_gb state ah ch an ns items top
  free_kb="$(_osrc_free_kb)"
  case "$free_kb" in ''|*[!0-9]*) return 0 ;; esac
  free_gb=$(( free_kb / 1048576 ))
  [ "$free_gb" -lt "${OSRC_DISK_MIN_GB:-10}" ] || return 0
  items="$(_osrc_cleanup_items --no-size 2>/dev/null)"
  _osrc_cleanup_state_write "$items" || true
  state="$(_osrc_cl_state)"
  if [ ! -f "$state" ]; then
    die "outsourcerer: free disk is ${free_gb}GB (< ${OSRC_DISK_MIN_GB:-10}GB) and cleanup state is unknown — refusing new lane launches. Run '$0 cleanup' to see what can go, then '$0 cleanup --apply' and/or '$0 cleanup --ack'."
  fi
  an="$(jq -r '.ask // 0' "$state" 2>/dev/null)"
  if [ "${an:-0}" -gt 0 ]; then
    ah="$(jq -r '.ask_hash // ""' "$state" 2>/dev/null)"
    ch="$(cat "$(_osrc_cl_ack)" 2>/dev/null)"
    [ -n "$ah" ] && [ "$ah" = "$ch" ] && return 0
    die "outsourcerer: free disk is ${free_gb}GB (< ${OSRC_DISK_MIN_GB:-10}GB); ${an} leftover item(s) need your decision — refusing new lane launches. Run '$0 cleanup' (dry run), then '$0 cleanup --apply' and/or '$0 cleanup --ack'."
  fi
  # ASK list is empty: never demand an ack of nothing. Say the disk is full and
  # name what is using it (review finding 8).
  ns="$(jq -r '.safe // 0' "$state" 2>/dev/null)"
  top="$(du -sk "$OSRC_HOME"/* 2>/dev/null | sort -rn | head -3 | awk '{printf "%s(%sK) ", $2, $1}')"
  if [ "${ns:-0}" -gt 0 ]; then
    die "outsourcerer: free disk is ${free_gb}GB (< ${OSRC_DISK_MIN_GB:-10}GB); ${ns} recorded item(s) are SAFE to delete — run '$0 cleanup --apply' (no ASK items need acknowledging). Biggest under OSRC_HOME: ${top:-unknown}"
  fi
  die "outsourcerer: free disk is ${free_gb}GB (< ${OSRC_DISK_MIN_GB:-10}GB) and nothing Outsourcerer-created is pending cleanup — the space is held elsewhere. Biggest under OSRC_HOME: ${top:-unknown} Free space outside Outsourcerer, or launch with OSRC_DISK_MIN_GB=0 to override."
}

# =============================================================================
# cmd_cleanup <job-id|fanout-gid> [--force] -> remove a job's (or a whole fanout's) git
# worktree(s). CONSERVATIVE: refuses to delete a worktree with uncommitted (dirty) or
# unmerged (ahead>0) work unless --force. Isolation is automatic; destruction is
# deliberate. With NO target this is the manifest dry run (see header); --apply deletes
# SAFE items only; --ack acknowledges the ASK list.
# =============================================================================
_cmd_cleanup_target() {
  local force="$2" target="$1"
  local gd; gd="$(_fanout_dir "$target")"
  if [ -f "$gd/members.tsv" ]; then       # a fanout gid -> clean each member
    local jid label; while IFS="$(printf '\t')" read -r jid label; do
      [ -n "$jid" ] || continue
      if [ "$force" = 1 ]; then cmd_cleanup "$jid" --force; else cmd_cleanup "$jid"; fi
    done < "$gd/members.tsv"
    echo "[outsourcerer] cleaned fanout $target"; return 0
  fi
  # Cleanup can race a live supervisor (or recover after one was killed).  Stop the delegate's
  # complete tree before removing its worktree so grandchildren cannot survive as poisoned orphans.
  local live_pid; live_pid="$(cat "$OSRC_JOBS/$target/pid" 2>/dev/null)"
  [ -n "$live_pid" ] && _kill_job "$OSRC_JOBS/$target" "$live_pid"
  local wj="$OSRC_JOBS/$target/worktree.json"
  [ -f "$wj" ] || wj="$OSRC_HOME/loops/$target/worktree.json"
  [ -f "$wj" ] || wj="$OSRC_HOME/isolated/$target/worktree.json"   # foreground auto-isolated run
  [ -f "$wj" ] || { echo "[outsourcerer] $target has no worktree to clean."; return 0; }
  have jq || die "cleanup needs jq"
  local path branch dirty ahead base rp
  path="$(jq -r '.path' "$wj")"; branch="$(jq -r '.branch' "$wj")"; base="$(jq -r '.base_sha // ""' "$wj")"
  # Never trust the serialized path: a lexical glob can be bypassed with
  # worktrees/../../..., so canonicalize and require strict containment first.
  # Worktrees live at <repo>/.outsourcerer/worktrees/<id> (see _worktree_setup), NOT
  # under $OSRC_HOME — anchor on the canonical path's own shape, with the trailing
  # component bound to the id being cleaned so one job's receipt cannot point at
  # another job's worktree.
  case "$path" in *'..'*) die "refusing to remove path containing '..': $path" ;; esac
  rp="$(cd "$path" 2>/dev/null && pwd -P)" || die "refusing to remove non-canonical worktree path: $path"
  case "$rp" in */.outsourcerer/worktrees/"$target") path="$rp" ;; *) die "refusing to remove path outside worktree root: $path" ;; esac
  # Re-read LIVE git state, not the job-completion snapshot: anything edited after the job (user, hook,
  # another process) must be seen, or --force could destroy it. Fall back to the json only if the worktree
  # is already gone.
  if git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    [ -n "$(git -C "$path" status --porcelain 2>/dev/null | head -1)" ] && dirty=true || dirty=false
    ahead="$(git -C "$path" rev-list --count "${base:-HEAD}..HEAD" 2>/dev/null)"; ahead="${ahead:-0}"
  else
    dirty="$(jq -r '.dirty' "$wj")"; ahead="$(jq -r '.ahead // 0' "$wj")"
  fi
  if [ "$force" != 1 ] && { [ "$dirty" = "true" ] || [ "${ahead:-0}" -gt 0 ]; }; then
    echo "[outsourcerer] REFUSING to remove $target: branch '$branch' has unmerged work (dirty=$dirty ahead=$ahead)." >&2
    echo "  inspect: git -C \"$path\" log --oneline; git -C \"$path\" status" >&2
    echo "  integrate e.g.: git cherry-pick $branch   OR force-remove: outsourcerer cleanup $target --force" >&2
    return 1
  fi
  local maindir="${path%/.outsourcerer/worktrees/*}"
  [ -d "$maindir/.git" ] || maindir="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$maindir" ] && [ -d "$maindir/.git" ]; then
    git -C "$maindir" worktree remove --force "$path" 2>/dev/null || rm -rf "$path"
    git -C "$maindir" branch -D "$branch" 2>/dev/null || true
    git -C "$maindir" worktree prune 2>/dev/null || true
  else
    rm -rf "$path"
  fi
  rm -f "$wj"
  echo "[outsourcerer] removed worktree for $target (branch $branch)"
}

cmd_cleanup() {
  local force=0 apply=0 ack=0 target="" a
  for a in "$@"; do
    case "$a" in
      --force) force=1 ;;
      --apply) apply=1 ;;
      --ack) ack=1 ;;
      --dry-run) : ;;   # explicit form of the default
      *) target="$a" ;;
    esac
  done
  if [ -n "$target" ]; then
    [ "$apply$ack" = "00" ] || die "cleanup: --apply/--ack take no job id (manifest mode)"
    _cmd_cleanup_target "$target" "$force"; return $?
  fi
  [ "$force" = 0 ] || die "cleanup --force needs a job id or fanout group id"
  if [ "$ack" = 1 ]; then _osrc_cleanup_ack; return; fi
  if [ "$apply" = 1 ]; then _osrc_cleanup_apply; return; fi
  _osrc_cleanup_dryrun
}

# gc [--older-than DAYS]. Delete completed job dirs whose mtime is older than N days.
# Only terminal states (done/done?/failed/blocked/timeout/wedged/canceled/permission-blocked)
# are removed; running/interrupted jobs are left alone.
cmd_gc() {
  local days="${OSRC_JOB_TTL_DAYS:-3}" auto=0 cap=0
  if [ "${1:-}" = "--auto" ]; then
    auto=1
    cap="${OSRC_AUTO_GC_MAX:-20}"
  elif [ "${1:-}" = "--older-than" ]; then
    [ -n "${2:-}" ] || die "gc --older-than needs a positive integer number of days"
    days="$2"
  elif [ -n "${1:-}" ]; then
    die "gc: usage: gc [--older-than DAYS]"
  fi
  case "$days" in ''|*[!0-9]*|'0'* ) die "gc --older-than needs a positive integer, got '$days'" ;; esac
  case "$cap" in 0) ;; *[!0-9]*|'') cap=20 ;; esac
  [ -d "$OSRC_JOBS" ] || { echo "[outsourcerer] no jobs to gc."; return 0; }
  local removed=0 skipped=0 checked=0 d st mtime now cutoff
  now=$(date +%s)
  cutoff=$(( now - days * 86400 ))
  for d in "$OSRC_JOBS"/*/; do
    [ -d "$d" ] || continue
    # Auto-GC examines only a small oldest-first sample.  Manual gc remains a
    # complete maintenance operation; launch-time housekeeping never becomes a
    # proportional shell walk as history grows.
    if [ "$auto" = 1 ] && [ "$checked" -ge "$cap" ]; then break; fi
    checked=$((checked+1))
    st="$(cat "$d/status" 2>/dev/null || echo running)"
    # Auto-heal a stale non-terminal job through the SHARED reconciler instead of an ad-hoc pid check.
    # The old inline check looked at the delegate pid only (never the supervisor) and wrote `interrupted`
    # without re-reading — so a job whose supervisor wrote `done` in the same instant got its success
    # clobbered to a bogus `interrupted` (a lost update that misreported a good job as failed). The
    # reconciler checks both pids and re-reads before flipping, so it can only reap a truly-dead job.
    case "$st" in
      running|stalled\?|exploring\?|no-progress-writes|launching) st="$(_reconcile_status "$(basename "$d")" 2>/dev/null || echo "$st")" ;;
    esac
    case "$st" in done|'done?'|failed|blocked|timeout|wedged|canceled|permission-blocked|interrupted) ;;
      *) skipped=$((skipped+1)); continue ;;
    esac
    mtime="$(_mtime "$d")"
    if [ -z "$mtime" ] || ! printf '%s\n' "$mtime" | grep -q '^[0-9][0-9]*$'; then
      skipped=$((skipped+1)); continue
    fi
    if [ "$mtime" -lt "$cutoff" ]; then
      rm -rf "$d"
      removed=$((removed+1))
    else
      skipped=$((skipped+1))
    fi
  done
  if [ "$auto" = 1 ]; then
    echo "[outsourcerer] auto-gc: removed $removed job dirs older than $days days; checked $checked (cap $cap)"
  else
    echo "[outsourcerer] gc: removed $removed job dirs older than $days days; skipped $skipped (non-terminal or younger)"
  fi
}
