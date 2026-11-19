#!/usr/bin/env bash
# lib/remote.sh -- remote lanes (Claude cloud sessions, Devin cloud, any CI/worker that pushes a
# branch). Sourced by outsourcerer.sh; defines functions only, runs nothing at load time.
#
#   lane add <id> --branch B [--repo owner/name|path|url] [--ready MARKER] [--base BR]
#                 [--brief FILE] [--done-when check:"CMD"]
#   lane ls | show <id> | poll [id] | rm <id> | events
#
# State: $OSRC_HOME/remote/<id>.json (one file per lane, written atomically). A lane is READY when
# the branch tip's commit SUBJECT carries the marker word (default READY) at its start or end, or the
# tip commit ADDED/CHANGED a root file <MARKER> / <id>.<MARKER> (a file committed earlier does not
# count, so later WIP pushes are not READY). Every poll is ONE network call (git ls-remote, or one
# `gh api .../commits/<branch>`), bounded by OSRC_NET_TIMEOUT (20s); more calls happen only when the
# head moved. Per-lane rate limit OSRC_REMOTE_POLL_SECS (default 60). Registered in the shared owner
# registry via _owner_record.
#
# Contract (CONTRACT.md): osrc_remote_state <id> -> live|ready|done|failed|gone (cache only, no
# network); osrc_remote_events -> EVENT/NEXT line pairs, never blocks. Review queue: lib/review.sh.
# Minutes are scaled by OSRC_TIME_UNIT (default 60 seconds per minute) so tests can run in seconds;
# OSRC_NOW overrides the clock for the same reason.

_osrc_now() { if [ -n "${OSRC_NOW:-}" ]; then printf '%s' "$OSRC_NOW"; else date +%s; fi; }
_osrc_mins() { # <minutes> -> seconds
  case "${1:-}" in ''|*[!0-9]*) set -- 0 ;; esac
  printf '%s' $(( $1 * ${OSRC_TIME_UNIT:-60} ))
}
_osrc_self() { if [ -n "${OSRC_SELF:-}" ]; then printf '%s' "$OSRC_SELF"; else printf '%q' "${SCRIPT_PATH:-outsourcerer}"; fi; }
_osrc_rdir() { printf '%s/remote' "$OSRC_HOME"; }
_osrc_lane_json() { printf '%s/remote/%s.json' "$OSRC_HOME" "$1"; }

_osrc_id_ok() { # lane ids are path components and ref names: keep them boring
  case "${1:-}" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

# _osrc_jq_set <file> <jq-args...>: apply a jq filter in place, atomically (tmp + mv).
_osrc_jq_set() {
  local f="$1" tmp; shift
  tmp="$f.tmp.$$.$RANDOM"
  if jq "$@" "$f" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then mv -f "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
}

# Tiny mkdir lock with stale breaking (a crashed poller must not wedge a lane forever).
_osrc_lock() { # <dir> -> 0 acquired
  local d="$1" age rc=1
  _osrc_guarded_mutex_acquire "$d" || return 1
  if _osrc_atomic_mkdir "$d"; then rc=0
  else
    age=$(( $(date +%s) - $(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || echo 0) ))
    if [ "$age" -gt "${OSRC_LOCK_STALE_SECS:-300}" ]; then
      rmdir "$d" 2>/dev/null && _osrc_atomic_mkdir "$d" && rc=0
    fi
  fi
  if [ "$rc" != 0 ]; then _osrc_guarded_mutex_release "$d" || return 1; fi
  return "$rc"
}
_osrc_unlock() {
  local owner
  _osrc_mutex_self_pid "$1.mx.candidates" || return 1
  owner="$(cat "$1.mx/pid" 2>/dev/null)"
  [ "$owner" = "$_OSRC_MUTEX_SELF" ] || return 1
  rmdir "$1" 2>/dev/null || true
  _osrc_guarded_mutex_release "$1"
}

# Event dedupe: one file per key under remote/.ev/<scope>/ holding the last emit time (interval 0 =
# once). The scope is the lane id (or .reviewer), so `lane rm` can clear exactly that lane's stamps
# and a lane re-added under the same id is announced afresh.
_osrc_ev_due() { # <scope> <key> <interval-secs>
  local d="$OSRC_HOME/remote/.ev/$1" k f last now
  k="$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-120)"; f="$d/$k"
  now="$(_osrc_now)"; mkdir -p "$d" 2>/dev/null
  if [ -f "$f" ]; then
    [ "${3:-0}" -gt 0 ] 2>/dev/null || return 1
    last="$(cat "$f" 2>/dev/null)"; case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $(( now - last )) -ge "$3" ] || return 1
  fi
  printf '%s' "$now" > "$f"
  return 0
}

# _osrc_emit <kind> <target> <detail> <next-command>: the two-line contract.
_osrc_emit() {
  local detail; detail="$(printf '%s' "$3" | tr '\n\r' '  ' | cut -c1-300)"
  printf 'EVENT %s %s %s %s\n' "$1" "$2" "$(_osrc_now)" "$detail"
  printf 'NEXT %s\n' "$4"
}

_osrc_run_timeout() { # <secs> <dir> <shell-command>  -> rc (124 on timeout), runs in its own process group
  python3 - "$1" "$2" "$3" <<'PY'
import os, signal, subprocess, sys
secs, cwd, cmd = float(sys.argv[1]), sys.argv[2], sys.argv[3]
p = subprocess.Popen(["/bin/bash", "-c", cmd], cwd=cwd, start_new_session=True)
try:
    sys.exit(p.wait(timeout=secs))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL); p.wait(); sys.exit(124)
PY
}

# Every network call (git ls-remote, gh api, git fetch) goes through this: argv run directly in its own
# process group, killed after OSRC_NET_TIMEOUT seconds (default 20), rc 124 + "timed out" on stderr.
# A hung connection must not hold the lane lock or block osrc_remote_events.
_osrc_net() { # <command> [args...]
  python3 - "${OSRC_NET_TIMEOUT:-20}" "$@" <<'PY'
import os, signal, subprocess, sys
secs, argv = float(sys.argv[1]), sys.argv[2:]
try:
    p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, start_new_session=True)
except OSError as e:
    sys.stderr.write("%s\n" % e); sys.exit(127)
try:
    sys.exit(p.wait(timeout=secs))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL); p.wait()
    sys.stderr.write("timed out after %ds\n" % secs); sys.exit(124)
PY
}

# ---- repo resolution --------------------------------------------------------------------------
# Prints "<transport>\t<url-or-owner/name>". transport git = local path or any git URL, gh = GitHub
# owner/name polled through `gh api` (git fetches then use https://github.com/<o>/<n>.git).
_osrc_repo_resolve() { # <repo-arg-or-empty>
  local r="${1:-}" top url
  if [ -z "$r" ]; then
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
    r="$top"
  fi
  if [ -d "$r" ]; then
    if [ "$(git -C "$r" rev-parse --is-bare-repository 2>/dev/null)" = "true" ]; then
      printf 'git\t%s' "$(cd "$r" && pwd)"; return 0
    fi
    url="$(git -C "$r" remote get-url origin 2>/dev/null)" || return 1
    printf 'git\t%s' "$url"; return 0
  fi
  case "$r" in
    *://*|git@*) printf 'git\t%s' "$r"; return 0 ;;
    */*/*|*[!A-Za-z0-9_./-]*) return 1 ;;
    */*) printf 'gh\t%s' "$r"; return 0 ;;
  esac
  return 1
}

_osrc_lane_fetch_url() { # <lane-json> -> URL git can fetch
  local t u
  t="$(jq -r '.transport' "$1")"; u="$(jq -r '.url' "$1")"
  if [ "$t" = gh ]; then printf 'https://github.com/%s.git' "$u"; else printf '%s' "$u"; fi
}

# Fetch the lane branch into a per-lane bare cache; prints the cache dir. rc!=0 on failure.
_osrc_lane_cache() { # <id> <lane-json>
  local c="$OSRC_HOME/remote/$1.git" url b
  url="$(_osrc_lane_fetch_url "$2")"; b="$(jq -r '.branch' "$2")"
  [ -d "$c" ] || git init -q --bare "$c" 2>/dev/null || return 1
  _osrc_net git --git-dir="$c" fetch -q --no-tags "$url" "+refs/heads/$b:refs/heads/lane" 2>>"$OSRC_HOME/remote/$1.fetch.err" || return 1
  printf '%s' "$c"
}

# ---- gh error classes --------------------------------------------------------------------------
_osrc_gh_err_kind() { # <stderr-text> -> auth|rate|missing|net
  case "$1" in
    *"rate limit"*|*"API rate"*|*"secondary rate"*|*"abuse detection"*) printf rate ;;
    *"HTTP 401"*|*"Bad credentials"*|*"gh auth login"*|*"authentication"*|*"not logged"*|*"HTTP 403"*) printf auth ;;
    *"HTTP 404"*|*"Not Found"*) printf missing ;;
    *) printf net ;;
  esac
}

# ---- poll --------------------------------------------------------------------------------------
# _osrc_lane_poll <id> [force]: refresh one lane. At most one network call unless the head moved. A
# finished background check is collected on EVERY call (cheap, no network); only the network part is
# rate limited.
_osrc_lane_poll() {
  local id="$1" force="${2:-}" f now poll last lk
  f="$(_osrc_lane_json "$id")"; [ -f "$f" ] || return 1
  lk="$OSRC_HOME/remote/$id.lock"
  _osrc_lock "$lk" || return 0
  now="$(_osrc_now)"; poll="${OSRC_REMOTE_POLL_SECS:-60}"
  _osrc_lane_check_collect "$id" "$f" "$now"
  last="$(jq -r '.last_poll_ts // 0' "$f")"
  if [ -n "$force" ] || [ $(( now - last )) -ge "$poll" ]; then _osrc_lane_poll_locked "$id" "$f" "$now"; fi
  _osrc_unlock "$lk"
  return 0
}

_osrc_lane_poll_locked() { # <id> <json> <now>
  local id="$1" f="$2" now="$3" transport branch url prev head="" msg="" err="" out rc=0 kind="" ready=false
  local marker names cache sha7
  transport="$(jq -r '.transport' "$f")"; branch="$(jq -r '.branch' "$f")"; url="$(jq -r '.url' "$f")"
  prev="$(jq -r '.head // ""' "$f")"; marker="$(jq -r '.ready_marker' "$f")"
  names=""
  if [ "$transport" = gh ]; then
    have gh || { _osrc_lane_poll_err "$id" "$f" "$now" auth "gh CLI not installed or not on PATH"; return 0; }
    out="$(_osrc_net gh api "repos/$url/commits/$branch" 2>"$f.err")" || rc=$?
    err="$(cat "$f.err" 2>/dev/null)"; rm -f "$f.err"
    if [ "$rc" -ne 0 ]; then
      kind="$(_osrc_gh_err_kind "$err")"
      if [ "$kind" = missing ]; then head=""; rc=0; else _osrc_lane_poll_err "$id" "$f" "$now" "$kind" "$err"; return 0; fi
    else
      head="$(printf '%s' "$out" | jq -r '.sha // ""')"
      msg="$(printf '%s' "$out" | jq -r '.commit.message // ""')"
      names="$(printf '%s' "$out" | jq -r '.files[]?.filename' 2>/dev/null)"
    fi
  else
    out="$(_osrc_net git ls-remote "$url" "refs/heads/$branch" 2>"$f.err")" || rc=$?
    err="$(cat "$f.err" 2>/dev/null)"; rm -f "$f.err"
    if [ "$rc" -ne 0 ]; then _osrc_lane_poll_err "$id" "$f" "$now" net "$err"; return 0; fi
    head="$(printf '%s\n' "$out" | awk 'NR==1{print $1}')"
  fi
  # success path: clear error state, record the poll
  _osrc_jq_set "$f" --argjson now "$now" '.last_poll_ts=$now | .last_ok_ts=$now | .err_count=0 | .err_kind="" | .err_msg=""'
  if [ -z "$head" ]; then
    # branch absent: only a failure if we had seen it before (deleted), otherwise not pushed yet
    if [ "$(jq -r '.seen_branch' "$f")" = true ]; then
      _osrc_jq_set "$f" '.branch_deleted=true'
    fi
    return 0
  fi
  _osrc_jq_set "$f" '.branch_deleted=false | .seen_branch=true'
  [ "$head" != "$prev" ] || return 0

  # head moved: find the commit message and READY evidence for the NEW tip
  if [ "$transport" != gh ]; then
    cache="$(_osrc_lane_cache "$id" "$f")" || { _osrc_lane_poll_err "$id" "$f" "$now" net "fetch of $branch failed: $(tail -1 "$OSRC_HOME/remote/$id.fetch.err" 2>/dev/null)"; return 0; }
    msg="$(git --git-dir="$cache" log -1 --format=%B "$head" 2>/dev/null)"
    # files the TIP COMMIT added or changed (not the whole tree): a READY file committed once must not
    # make every later push READY. The gh path gets the same list from the commits response (.files).
    names="$(git --git-dir="$cache" diff-tree --no-commit-id --name-only -r --root "$head" 2>/dev/null)"
  fi
  if _osrc_msg_ready "$msg" "$marker" || printf '%s\n' "$names" | grep -qxE "$marker|$id\\.$marker"; then
    ready=true
  fi
  sha7="${head:0:7}"
  _osrc_jq_set "$f" --arg head "$head" --arg msg "$(printf '%s' "$msg" | head -1 | cut -c1-160)" \
    --argjson now "$now" --argjson ready "$ready" \
    '.head=$head | .head_msg=$msg | .last_push_ts=$now | .head_ready=$ready'
  # a push invalidates reviews of older heads, whether or not the new head is READY
  type _osrc_review_supersede >/dev/null 2>&1 && _osrc_review_supersede "$id" "$head"
  if [ "$ready" = true ]; then
    _osrc_jq_set "$f" --argjson now "$now" --arg head "$head" '.ready_head=$head | .ready_ts=$now'
    _osrc_lane_check_and_enqueue "$id" "$f" "$head" "$now"
  elif type _osrc_review_item_exists_for_lane >/dev/null 2>&1 \
       && [ "${OSRC_REVIEW_REREVIEW_ANY:-0}" = 1 ] && _osrc_review_item_exists_for_lane "$id"; then
    _osrc_lane_check_and_enqueue "$id" "$f" "$head" "$now"
  fi
  return 0
}

# ONE marker rule, shared with the done contract (lib/done.sh, _osrc_done_marker_hit) when loaded: the
# marker must be a whole word at the START or END of the commit SUBJECT line, and a marker negated
# by "not" never counts. Body text and mid-subject mentions ("docs: explain the READY marker",
# "wip: not READY, tests red") do not make a lane READY. The local copy below is that same rule for
# when done.sh is not loaded.
_osrc_msg_ready() { # <commit message> <marker>
  local subj; subj="$(printf '%s' "$1" | head -1)"
  if type _osrc_done_marker_hit >/dev/null 2>&1; then _osrc_done_marker_hit "$subj" "$2"; else _osrc_marker_hit_local "$subj" "$2"; fi
}
_osrc_marker_hit_local() { # <subject> <marker>
  local subj="$1" marker="$2" rest pre pt
  [ -n "$subj" ] && [ -n "$marker" ] || return 1
  case "$subj" in
    "$marker"*) rest="${subj#"$marker"}"; case "$rest" in ''|[!A-Za-z0-9_]*) return 0 ;; esac ;;
  esac
  case "$subj" in
    *"$marker")
      pre="${subj%"$marker"}"
      case "$pre" in ''|*[!A-Za-z0-9_]) ;; *) return 1 ;; esac
      pt="${pre%"${pre##*[![:space:]]}"}"
      printf '%s' "$pt" | grep -qiE '(^|[^a-z0-9_])not$' && return 1
      return 0 ;;
  esac
  return 1
}

# Poll failure bookkeeping. auth and rate-limit are reported on the FIRST occurrence (silence is the
# failure we are fixing); other errors become a `failed` event after OSRC_REMOTE_ERR_MAX in a row.
_osrc_lane_poll_err() { # <id> <json> <now> <kind> <msg>
  local f="$2" now="$3" kind="$4" msg
  msg="$(printf '%s' "$5" | tr '\n\r' '  ' | cut -c1-200)"
  _osrc_jq_set "$f" --argjson now "$now" --arg k "$kind" --arg m "$msg" \
    '.last_poll_ts=$now | .err_count=((.err_count // 0) + 1) | .err_kind=$k | .err_msg=$m'
}

# Done contract: run `--done-when check:"CMD"` on the READY sha in a throwaway worktree before the
# reviewer is spent on it. The check runs in the BACKGROUND, detached from the caller's pipes, so
# osrc_remote_events never blocks on it: the lane reads `live` with check.state=running until the
# runner writes remote/<id>-<sha7>.rc, which the next poll collects. Pass -> enqueue; fail or a dead
# runner -> `failed` event, no review spent. NOTE the command executes code pushed by the remote lane,
# on this machine, with the user's own rights and no sandbox.
_osrc_lane_check_and_enqueue() { # <id> <json> <head> <now>
  local id="$1" f="$2" head="$3" now="$4" check
  check="$(jq -r '.done_when // ""' "$f")"
  if [ -z "$check" ] && type osrc_proof_remote_ready >/dev/null 2>&1; then
    osrc_proof_remote_ready "$id" "$f" "$head"; case $? in 0) check="$_PR_REMOTE_CHECK" ;; 2) _osrc_jq_set "$f" --arg h "$head" '.proof_back=$h'; return 0 ;; esac   # lib/proof.sh
  fi
  if [ -n "$check" ]; then _osrc_lane_check_start "$id" "$f" "$head" "$now" "$check"; return 0; fi
  type _osrc_review_enqueue >/dev/null 2>&1 || return 0
  _osrc_review_enqueue "$id" "$head" "$(jq -r '.brief // ""' "$f")" auto >/dev/null 2>&1 || true
}

_osrc_lane_check_start() { # <id> <json> <head> <now> <command>
  local id="$1" f="$2" head="$3" now="$4" check="$5" sha7 cache log rcfile pid
  sha7="${head:0:7}"; log="$OSRC_HOME/remote/$id-$sha7.check.log"; rcfile="$OSRC_HOME/remote/$id-$sha7.rc"
  if ! cache="$(_osrc_lane_cache "$id" "$f")"; then
    _osrc_jq_set "$f" --arg h "$head" --argjson now "$now" '.check={head:$h,state:"done",rc:125,ts:$now,log:"",pid:0,why:"could not fetch the branch to run the check"}'
    return 0
  fi
  rm -f "$rcfile"
  _osrc_jq_set "$f" --arg h "$head" --argjson now "$now" --arg log "$log" '.check={head:$h,state:"running",rc:null,ts:$now,log:$log,pid:0,why:""}'
  ( trap '' HUP; _osrc_lane_check_run "$id" "$cache" "$head" "$check" "$log" "$rcfile" ) </dev/null >/dev/null 2>&1 &
  pid=$!; disown 2>/dev/null || true
  _osrc_jq_set "$f" --argjson pid "$pid" '.check.pid=$pid'
}

_osrc_lane_check_run() { # <id> <cache> <head> <command> <log> <rcfile>   (background)
  local id="$1" cache="$2" head="$3" check="$4" log="$5" rcfile="$6" wt rc=0
  wt="$OSRC_HOME/remote/wt/$id-${head:0:7}"
  mkdir -p "$OSRC_HOME/remote/wt"; rm -rf "$wt"
  if git --git-dir="$cache" worktree add -q --detach "$wt" "$head" >"$log" 2>&1; then
    if type osrc_proof_remote_run >/dev/null 2>&1; then osrc_proof_remote_run "$id" "$wt" "$head" "$check" "$log" "$cache" || rc=$?
    else _osrc_run_timeout "${OSRC_CHECK_TIMEOUT:-900}" "$wt" "$check" >>"$log" 2>&1 || rc=$?; fi
    git --git-dir="$cache" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    git --git-dir="$cache" worktree prune >/dev/null 2>&1
  else
    rc=125
  fi
  printf '%s' "$rc" > "$rcfile.tmp" && mv -f "$rcfile.tmp" "$rcfile"
}

_osrc_lane_check_collect() { # <id> <json> <now>   (called under the lane lock)
  local id="$1" f="$2" head sha7 rcfile rc pid
  [ "$(jq -r '.check.state // ""' "$f")" = running ] || return 0
  head="$(jq -r '.check.head' "$f")"; sha7="${head:0:7}"; rcfile="$OSRC_HOME/remote/$id-$sha7.rc"; pid="$(jq -r '.check.pid // 0' "$f")"
  if [ ! -s "$rcfile" ]; then
    # runner gone without a result (killed, reaped by a sandbox)? say so instead of waiting forever
    if [ "$pid" -gt 0 ] 2>/dev/null && ! kill -0 "$pid" 2>/dev/null && [ ! -s "$rcfile" ]; then
      _osrc_jq_set "$f" '.check.state="done" | .check.rc=125 | .check.why="check runner died before writing a result"'
    fi
    return 0
  fi
  rc="$(cat "$rcfile")"; case "$rc" in ''|*[!0-9]*) rc=125 ;; esac
  _osrc_jq_set "$f" --argjson rc "$rc" '.check.state="done" | .check.rc=$rc'
  [ "$rc" -eq 0 ] || ! type osrc_proof_sendback >/dev/null 2>&1 || OSRC_PROOF_NO_SEND=1 osrc_proof_sendback "$id" "proof failed on ${sha7}: $(osrc_proof_stamp "$id")" "remote:$head" counted
  # only a check on the CURRENT head may enqueue; a lane that has pushed since moved on
  if [ "$rc" -eq 0 ] && [ "$(jq -r '.head' "$f")" = "$head" ] && type _osrc_review_enqueue >/dev/null 2>&1; then
    _osrc_review_enqueue "$id" "$head" "$(jq -r '.brief // ""' "$f")" auto >/dev/null 2>&1 || true
  fi
}

# ---- state + events ----------------------------------------------------------------------------
osrc_remote_state() { # <id> -> live|ready|done|failed|gone  (cache only: no network, safe in hooks)
  local id="$1" f head v ch_state
  f="$(_osrc_lane_json "$id")"; [ -f "$f" ] || { printf gone; return 0; }
  if [ "$(jq -r '.branch_deleted' "$f")" = true ]; then printf failed; return 0; fi
  head="$(jq -r '.head // ""' "$f")"
  ch_state=""; [ "$(jq -r '.check.head // ""' "$f")" = "$head" ] && ch_state="$(jq -r '.check.state // ""' "$f")"
  if [ "$ch_state" = done ] && [ "$(jq -r '.check.rc // 0' "$f")" != 0 ]; then printf failed; return 0; fi
  [ -z "$head" ] || [ "$(jq -r '.proof_back // ""' "$f")" != "$head" ] || { printf live; return 0; }   # sent back for proof
  if [ "$(jq -r '.head_ready' "$f")" = true ]; then
    [ "$ch_state" != running ] || { printf live; return 0; }     # done-when check still running
    v=""; type _osrc_review_verdict_for >/dev/null 2>&1 && v="$(_osrc_review_verdict_for "$id" "$head")"
    # CHANGES: the ball is back with the lane, so it is live (and gets a stall clock from the verdict)
    case "$v" in MERGE|BLOCK) printf done; return 0 ;; CHANGES) printf live; return 0 ;; esac
    # An item closed as merged means this head already landed: the lane is done, not ready.
    type _osrc_review_item_closed_merged >/dev/null 2>&1 && _osrc_review_item_closed_merged "$id" "$head" && { printf done; return 0; }
    printf ready; return 0
  fi
  printf live
}

_osrc_remote_ids() { local p; for p in "$OSRC_HOME"/remote/*.json; do [ -f "$p" ] && basename "$p" .json; done; }

# Prints EVENT/NEXT pairs for every registered remote lane, plus the review queue's. Never blocks.
osrc_remote_events() {
  have jq || return 0
  local id f now stall renotify head sha7 st last_move vts errn errk
  now="$(_osrc_now)"
  stall="$(_osrc_mins "${OSRC_REMOTE_STALL:-90}")"
  renotify="$(_osrc_mins "${OSRC_RENOTIFY_MIN:-15}")"
  for id in $(_osrc_remote_ids); do
    f="$(_osrc_lane_json "$id")"
    _osrc_lane_poll "$id" || true
    head="$(jq -r '.head // ""' "$f")"; sha7="${head:0:7}"
    # poll trouble: auth / rate limit at once, anything else after N consecutive failures
    errn="$(jq -r '.err_count // 0' "$f")"; errk="$(jq -r '.err_kind // ""' "$f")"
    if [ "$errn" -gt 0 ] && { [ "$errk" = auth ] || [ "$errk" = rate ] || [ "$errn" -ge "${OSRC_REMOTE_ERR_MAX:-5}" ]; }; then
      if _osrc_ev_due "$id" "pollerr:$errk" "$renotify"; then
        case "$errk" in
          auth) _osrc_emit failed "$id" "gh/git auth failure polling $(jq -r .branch "$f"): $(jq -r .err_msg "$f")" "gh auth status" ;;
          rate) _osrc_emit failed "$id" "rate limited polling $(jq -r .branch "$f"): $(jq -r .err_msg "$f")" "gh api rate_limit --jq .rate" ;;
          *) _osrc_emit failed "$id" "polling failed ${errn}x ($errk): $(jq -r .err_msg "$f")" "$(_osrc_self) lane poll $id" ;;
        esac
      fi
    fi
    if [ "$(jq -r '.branch_deleted' "$f")" = true ] && _osrc_ev_due "$id" deleted "$renotify"; then
      _osrc_emit failed "$id" "branch $(jq -r .branch "$f") was deleted from the remote" "$(_osrc_self) lane show $id"
    fi
    if [ -n "$head" ] && [ "$(jq -r '.check.head // ""' "$f")" = "$head" ] && [ "$(jq -r '.check.state // ""' "$f")" = done ] \
       && [ "$(jq -r '.check.rc // 0' "$f")" != 0 ] && _osrc_ev_due "$id" "checkfail:$head" "$renotify"; then
      _osrc_emit failed "$id" "done-when check failed on $sha7 (rc=$(jq -r .check.rc "$f")$(jq -r '.check.why // "" | if . == "" then "" else ", " + . end' "$f")), no review spent; log $(jq -r '.check.log' "$f")$(type osrc_proof_remote_note >/dev/null 2>&1 && osrc_proof_remote_note "$id")" "$(nx=""; ! type osrc_proof_remote_next >/dev/null 2>&1 || nx="$(osrc_proof_remote_next "$id")"; [ -n "$nx" ] && printf '%s' "$nx" || printf 'tail -40 %q' "$(jq -r '.check.log' "$f")")"
    fi
    if [ -n "$head" ] && [ "$(jq -r '.proof_back // ""' "$f")" = "$head" ] && _osrc_ev_due "$id" "proofback:$head" "$renotify"; then
      _osrc_emit failed "$id" "READY $sha7 not reviewed: $(osrc_proof_gate "$id" "$head")$(osrc_proof_remote_note "$id")" "$(osrc_proof_remote_next "$id")"
    fi
    st="$(osrc_remote_state "$id")"
    if [ "$st" = ready ] && [ "$(jq -r '.ready_head // ""' "$f")" = "$head" ] && _osrc_ev_due "$id" "ready:$head" 0; then
      _osrc_emit done "$id" "READY $sha7 on $(jq -r .branch "$f"): $(jq -r .head_msg "$f") (queued for review)" "$(_osrc_next_for_ready)"
    fi
    # backstop: READY with no live review item for this head (removed and re-added lane, dropped or
    # lost item) is the "sat READY for hours" class. Say so instead of staying quiet.
    if [ "$st" = ready ] && [ -n "$head" ] && type _osrc_review_item_state >/dev/null 2>&1; then
      case "$(_osrc_review_item_state "$id" "$head")" in
        queued|inflight|verdict|closed) ;;
        *) if _osrc_ev_due "$id" "noitem:$head" "$renotify"; then
             _osrc_emit unreviewed "$id" "READY $sha7 has no review item queued, in flight or finished" "$(_osrc_review_requeue_cmd "$id" "$head")"
           fi ;;
      esac
    fi
    if [ "$st" = live ] && [ -n "$stall" ] && [ "$stall" -gt 0 ]; then
      last_move="$(jq -r '.last_push_ts // .created_ts' "$f")"
      vts="$(type _osrc_review_last_verdict_ts >/dev/null 2>&1 && _osrc_review_last_verdict_ts "$id" || echo 0)"
      [ "$vts" -gt "$last_move" ] 2>/dev/null && last_move="$vts"
      if [ $(( now - last_move )) -ge "$stall" ] && _osrc_ev_due "$id" stalled "$stall"; then
        _osrc_emit stalled "$id" "no push on $(jq -r .branch "$f") for $(( (now - last_move) / ${OSRC_TIME_UNIT:-60} ))m (head ${sha7:-none}, last: $(jq -r '.head_msg // ""' "$f"))" "$(_osrc_self) lane show $id"
      fi
    fi
  done
  type osrc_review_events >/dev/null 2>&1 && osrc_review_events
  type osrc_proof_events >/dev/null 2>&1 && osrc_proof_events   # lib/proof.sh: lanes stopped by a pin mismatch
  return 0
}

_osrc_next_for_ready() { # best next command when something just became READY
  if type _osrc_review_reviewer >/dev/null 2>&1 && [ -n "$(_osrc_review_reviewer)" ]; then
    printf '%s review next' "$(_osrc_self)"
  else
    printf '%s review reviewer <tmux-session>' "$(_osrc_self)"
  fi
}

# ---- commands ----------------------------------------------------------------------------------
cmd_lane() {
  local sub="${1:-}"; shift || true
  # L7 verbs (cap|billing|summary|limits, handlers in lib/spend.sh) need no jq;
  # the remote-lane verbs below do.
  case "$sub" in cap|billing|summary|limits) ;; *) have jq || die "lane needs jq" ;; esac
  case "$sub" in
    add) _osrc_lane_add "$@" ;;
    ls|list) _osrc_lane_ls ;;
    show) [ -n "${1:-}" ] || die "lane show <id>"; [ -f "$(_osrc_lane_json "$1")" ] || die "no lane '$1'"
          jq . "$(_osrc_lane_json "$1")"; printf 'state: %s\n' "$(osrc_remote_state "$1")" ;;
    poll) if [ -n "${1:-}" ]; then [ -f "$(_osrc_lane_json "$1")" ] || die "no lane '$1'"; _osrc_lane_poll "$1" force
          else local i; for i in $(_osrc_remote_ids); do _osrc_lane_poll "$i" force; done; fi ;;
    rm|remove) _osrc_lane_rm "${1:-}" ;;
    events) osrc_remote_events ;;
    msg) [ -n "${1:-}" ] && [ -n "${2:-}" ] || die "lane msg <to|all|orchestrator> \"<text>\""; osrc_lane_msg "$@" ;;
    inbox) osrc_lane_inbox "$@" ;;
    # L7 spend/cap verbs (lib/spend.sh + lib/limits.sh): billing classifier, standing caps, limits feed.
    cap)     osrc_lane_cap "$@" ;;
    billing) [ -n "${1:-}" ] || die "usage: lane billing <lane> [model]"; osrc_lane_billing "$@" ;;
    summary) osrc_lane_summary "$@" ;;
    limits)  osrc_lane_limits ;;
    *) die "lane: add <id> --branch B [--repo R] [--ready M] [--base BR] [--brief F] [--done-when check:\"CMD\"] | ls | show <id> | poll [id] | rm <id> | events | msg <to> \"<text>\" | inbox [--peek] | cap <lane> <meter><=pct>|--clear | billing <lane> [model] | summary [--json] | limits" ;;
  esac
}

_osrc_lane_add() {
  local id="${1:-}" branch="" repo="" marker=READY base=main brief="" donewhen="" rr transport url now
  [ -n "$id" ] || die "lane add <id> --branch <remote-branch> [--repo R] [--ready M] [--base BR] [--brief F] [--done-when check:\"CMD\"]"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --branch) branch="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --ready) marker="${2:-}"; shift 2 ;;
      --base) base="${2:-}"; shift 2 ;;
      --brief) brief="${2:-}"; shift 2 ;;
      --done-when) donewhen="${2:-}"; shift 2 ;;
      *) die "lane add: unknown option '$1'" ;;
    esac
  done
  _osrc_id_ok "$id" || die "lane id must match [A-Za-z0-9._-]+ (max 64, no leading dot): '$id'"
  [ -n "$branch" ] || die "lane add needs --branch"
  case "$branch" in *[!A-Za-z0-9._/-]*|-*|*..*) die "branch '$branch' has characters this tool will not poll (allowed: A-Za-z0-9._/-)" ;; esac
  case "$marker" in ''|*[!A-Za-z0-9_-]*) die "--ready must be a single word [A-Za-z0-9_-]+" ;; esac
  case "$base" in ''|*[!A-Za-z0-9._/-]*) die "bad --base '$base'" ;; esac
  if [ -n "$donewhen" ]; then
    case "$donewhen" in check:?*) donewhen="${donewhen#check:}" ;; *) die "--done-when must look like check:\"<command>\"" ;; esac
  fi
  [ -z "$brief" ] || { [ -f "$brief" ] || die "--brief file not found: $brief"; brief="$(cd "$(dirname "$brief")" && pwd)/$(basename "$brief")"; }
  rr="$(_osrc_repo_resolve "$repo")" || die "cannot resolve a repo from '${repo:-the current directory}' (give owner/name, a git URL, or a path to a clone or bare repo)"
  transport="${rr%%	*}"; url="${rr#*	}"
  mkdir -p "$(_osrc_rdir)" || die "cannot create $(_osrc_rdir)"
  [ ! -e "$(_osrc_lane_json "$id")" ] || die "lane '$id' already exists (lane rm $id first)"
  now="$(_osrc_now)"
  jq -n --arg id "$id" --arg branch "$branch" --arg repo "${repo:-$PWD}" --arg transport "$transport" --arg url "$url" \
    --arg marker "$marker" --arg base "$base" --arg brief "$brief" --arg dw "$donewhen" --argjson now "$now" '
    {id:$id, branch:$branch, repo:$repo, transport:$transport, url:$url, ready_marker:$marker, base:$base, brief:$brief,
     done_when:$dw, created_ts:$now, last_poll_ts:0, last_ok_ts:0, err_count:0, err_kind:"", err_msg:"",
     seen_branch:false, branch_deleted:false, head:"", head_msg:"", head_ready:false, last_push_ts:$now,
     ready_head:"", ready_ts:0, check:null}' > "$(_osrc_lane_json "$id").new" && mv -f "$(_osrc_lane_json "$id").new" "$(_osrc_lane_json "$id")" \
    || die "could not write lane record"
  [ -s "$(_osrc_lane_json "$id")" ] || die "lane record was not written"
  _owner_record "$id"
  printf 'lane %s registered: %s %s branch %s (READY marker: %s%s)\n' "$id" "$transport" "$url" "$branch" "$marker" "${donewhen:+, done-when check set}"
  _osrc_lane_poll "$id" force
  printf 'state: %s   (events: %s lane events)\n' "$(osrc_remote_state "$id")" "$(_osrc_self)"
}

_osrc_lane_ls() {
  local id f any=0
  printf '%-22s %-7s %-30s %-8s %s\n' LANE STATE BRANCH HEAD LAST-PUSH
  for id in $(_osrc_remote_ids); do
    f="$(_osrc_lane_json "$id")"; any=1
    printf '%-22s %-7s %-30s %-8s %s\n' "$id" "$(osrc_remote_state "$id")" "$(jq -r .branch "$f" | cut -c1-30)" \
      "$(jq -r '.head[0:7]' "$f")" "$(( ( $(_osrc_now) - $(jq -r '.last_push_ts' "$f") ) / ${OSRC_TIME_UNIT:-60} ))m ago"
  done
  [ "$any" = 1 ] || echo "(no remote lanes; add one with: lane add <id> --branch <b> --repo <owner/name>)"
}

_osrc_lane_rm() {
  local id="${1:-}" d w h7='[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'
  [ -n "$id" ] || die "lane rm <id>"
  _osrc_id_ok "$id" || die "bad lane id"
  [ -f "$(_osrc_lane_json "$id")" ] || die "no lane '$id'"
  rm -f "$(_osrc_lane_json "$id")"
  rm -rf "$OSRC_HOME/remote/$id.git" "$OSRC_HOME/remote/$id.lock" "$OSRC_HOME/remote/.ev/$id"
  # exactly <id>-<sha7>: a bare "$id-*" glob would also hit lane "$id-other"
  for w in "$OSRC_HOME/remote/wt/$id"-$h7; do [ -e "$w" ] && rm -rf "$w"; done
  for w in "$OSRC_HOME/remote/$id"-$h7.check.log "$OSRC_HOME/remote/$id"-$h7.rc; do [ -e "$w" ] && rm -f "$w"; done
  for d in "$OSRC_HOME"/owners/*/"$id"; do [ -f "$d" ] && rm -f "$d" && { type osrc_hub_seen_lane >/dev/null 2>&1 && osrc_hub_seen_lane "$(basename "$(dirname "$d")")" "$id"; }; done
  type _osrc_review_lane_removed >/dev/null 2>&1 && _osrc_review_lane_removed "$id"
  echo "lane $id removed"
}

# ---- moved verbatim from outsourcerer.sh (a remote-branch lane: waits on a branch the bot pushes) ----
delegate_grokbot() {
  local tier="$1"
  [ "${#REST[@]}" -gt 0 ] || die "no task prompt given"
  local task="${REST[*]}"
  have curl || die "curl not on PATH (the grokbot lane needs it)"
  have jq   || die "jq not on PATH (the grokbot lane needs it)"
  have git  || die "git not on PATH (the grokbot lane delivers through a git branch)"
  _gb_load
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "the grokbot lane runs inside a git repo: the bot delivers by pushing a branch to its origin."
  local repo base branch mode posture
  repo="$(git remote get-url origin 2>/dev/null)" || die "this repo has no 'origin' remote; the bot needs one to clone and push to."
  base="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"; [ "$base" != "HEAD" ] || base="$(git rev-parse HEAD)"
  branch="osrc/grokbot-$(_new_job_id)"
  case "$tier" in
    auto) mode="read-only"; posture="READ-ONLY by instruction (the bot is asked to change nothing but its result file; Grok Bot has no enforced read-only mode)" ;;
    accept-edits|autonomous|dangerous) mode="edit"; posture="MUTATING on its own branch (the bot edits a clone and pushes $branch; nothing is merged here)" ;;
    *) die "bad tier: $tier" ;;
  esac
  if [ -n "$(git status --porcelain 2>/dev/null)" ] || [ -n "$(git log --oneline "@{u}..HEAD" 2>/dev/null)" ]; then
    printf '>>> [grokbot] NOTE: you have uncommitted or unpushed work. The bot clones %s from origin, so it will not see it.\n' "$base" >&2
  fi
  [ -n "$EFFORT" ] && printf '>>> [effort] reasoning=%s (advisory only: Grok Bot has no effort setting; folded into the prompt)\n' "$EFFORT" >&2
  local ttier; ttier="$(resolve_tier "${MODEL:-}" "${TTIER:-}")" || ttier="capable"
  _with_preamble_render "bundle"
  local wrapped; wrapped="$(_build_prompt "${MODEL:-grokbot}" "$task" "$ttier" "bundle")"
  local delivery
  delivery="DELIVERY (required): clone $repo, check out $base, and create the branch $branch. Do the task there."
  if [ "$mode" = "read-only" ]; then
    delivery="$delivery This is a read-only task: change no files except OUTSOURCERER_RESULT.md."
  fi
  delivery="$delivery Write your final message to OUTSOURCERER_RESULT.md at the repo root, commit, and push $branch to origin. Pushing that branch is the only way your result is collected."
  _tier_banner "grokbot (Grok Bot routine)" "grokbot-default" "$ttier" "$posture | $(_lane_cost_disclosure grokbot)"
  local body resp code
  body="$(mktemp "$OSRC_HOME/.gb.$$.XXXXXX")"; resp="$(mktemp "$OSRC_HOME/.gbr.$$.XXXXXX")"
  chmod 600 "$body" "$resp" 2>/dev/null || true
  jq -n --arg repo "$repo" --arg base "$base" --arg branch "$branch" --arg mode "$mode" \
        --arg delivery "$delivery" --arg task "$wrapped" \
        '{source:"outsourcerer", repo:$repo, base:$base, branch:$branch, mode:$mode, instructions:($delivery + "\n\n" + $task)}' > "$body"
  code="$(_curl_with_auth "$GROKBOT_WEBHOOK_KEY" -sS --max-time 30 -o "$resp" -w '%{http_code}' \
            -X POST -H 'Content-Type: application/json' --data @"$body" "$GROKBOT_WEBHOOK_URL" 2>/dev/null)" || code="000"
  rm -f "$body" 2>/dev/null
  case "$code" in
    2??) printf '>>> [grokbot] routine started (HTTP %s). Waiting for the bot to push %s.\n' "$code" "$branch" >&2 ;;
    *) local why; why="$(head -c 300 "$resp" 2>/dev/null | tr -d '\r')"; rm -f "$resp"
       die "grokbot: the webhook did not start the routine (HTTP $code). ${why:+Response: $why}" ;;
  esac
  rm -f "$resp" 2>/dev/null
  local timeout="${OSRC_GROKBOT_TIMEOUT:-3600}" poll="${OSRC_GROKBOT_POLL:-20}" t0 sha="" elapsed=0
  case "$timeout" in ''|*[!0-9]*) timeout=3600 ;; esac
  case "$poll" in ''|*[!0-9]*|0) poll=20 ;; esac
  t0=$(date +%s)
  while :; do
    sha="$(git ls-remote --heads origin "$branch" 2>/dev/null | awk 'NR==1{print $1}')"
    [ -n "$sha" ] && break
    elapsed=$(( $(date +%s) - t0 ))
    if [ "$elapsed" -ge "$timeout" ]; then
      record_ledger grokbot "grokbot-default" "$ttier" "$tier" "$task" "" grokbot
      printf '>>> [grokbot] no branch after %ss. The routine may still be running: check Grok Bot, then look for %s on origin.\n' "$elapsed" "$branch" >&2
      return 124
    fi
    # Keep the watchdog fed: this lane is waiting on a remote machine, not hung.
    printf 'OSRC::PROGRESS#%s waiting for Grok Bot to push %s (%ss)\n' "${OSRC_MARK:-}" "$branch" "$elapsed"
    sleep "$poll"
  done
  git fetch -q origin "refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null || true
  local result; result="$(git show "$sha:OUTSOURCERER_RESULT.md" 2>/dev/null)" || result=""
  if [ -n "$result" ]; then printf '%s\n' "$result"
  else printf '(the bot pushed %s without OUTSOURCERER_RESULT.md; its last commit says:)\n%s\n' "$branch" "$(git log -1 --format=%B "$sha" 2>/dev/null)"; fi
  printf '>>> [grokbot] delivered on branch %s (%s). Review: git diff %s...origin/%s\n' "$branch" "${sha:0:12}" "$base" "$branch" >&2
  record_ledger grokbot "grokbot-default" "$ttier" "$tier" "$task" "" grokbot
  printf '>>> [receipt] %s.\n' "$(_lane_cost_disclosure grokbot)" >&2
  return 0
}
