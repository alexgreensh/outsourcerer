# shellcheck shell=bash
# factory-land.sh -- Track C of the 0.14 "factory": the DONE CONTRACT and the MERGE GATE (`land`).
# Sourced by outsourcerer.sh (never run directly). bash 3.2 safe, set -u safe.
#
# Reuses, never reinvents: _crew_check / _loop_check (bounded check runner), _check_signature,
# _crew_worktree_clean (tracked-only cleanliness), OSRC_SECRET_VALUE_ERE (the _crew_scan_staged
# patterns), _mkdir_claim + _pid_start_identity (house lock pattern), _wake_append, _new_job_id.
# Task store calls (Track B): _plan_dir, _plan_resolve, _task_get, _task_update, _task_event.
#
# Worker worktrees are NEVER removed here (that stays with `cleanup`). The only worktree this file
# creates is the throwaway integration worktree, and a trap removes it on every exit path.

# Own names (never _factory_*): this file is sourced AFTER factory-tasks.sh, so redefining that
# file's helpers here would silently replace its JSON validation and private (umask 077) writes.
_fl_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Native Windows jq emits CRLF; retain jq's failure status while normalizing output.
_fl_jq() ( set -o pipefail; jq "$@" | tr -d '\r'; )

# _fl_write_json <path> <json> -> validate, refuse symlinks, then write private via tmp + mv (atomic).
_fl_write_json() {
  local p="$1" tmp
  [ -L "$p" ] && { echo "refusing to write through a symlink: $p" >&2; return 1; }
  printf '%s' "$2" | jq -e . >/dev/null 2>&1 || { echo "refusing to write broken JSON to $p" >&2; return 1; }
  tmp="$p.tmp.$$.${RANDOM:-0}"
  if ( umask 077; printf '%s\n' "$2" > "$tmp" ) 2>/dev/null && mv -f "$tmp" "$p" 2>/dev/null; then return 0; fi
  rm -f "$tmp" 2>/dev/null; return 1
}

# _fl_self_pid -> sets _FL_PID to the pid of THIS (sub)shell. bash 3.2 (stock macOS) has no BASHPID
# and $$ is the top-level script, which outlives a SIGKILLed land subshell; a child's PPID is the
# honest answer. Sets a variable (never call it in $(...): that would be yet another subshell).
_fl_self_pid() {
  if [ -n "${BASHPID:-}" ]; then _FL_PID="$BASHPID"; return 0; fi
  local f="$OSRC_HOME/land/.pid.$$.${RANDOM:-0}" p=""
  mkdir -p "${f%/*}" 2>/dev/null
  sh -c 'echo "$PPID"' > "$f" 2>/dev/null; { read -r p < "$f"; } 2>/dev/null; rm -f "$f" 2>/dev/null
  case "$p" in ''|*[!0-9]*) p="$$" ;; esac
  _FL_PID="$p"
}

# _factory_job_status <job-id> -> the raw status word ("" when the job dir is missing).
_factory_job_status() {
  [ -n "${1:-}" ] || return 0
  case "$1" in */*|*..*) return 0 ;; esac
  cat "$OSRC_JOBS/$1/status" 2>/dev/null | head -1 | tr -d '\r'
}

# _factory_job_ok <job-id> -> rc0 when the job ended in terminal success (done, or done? = exited 0
# without the marker, which the contract counts as success; the check is what proves the work).
_factory_job_ok() {
  case "$(_factory_job_status "${1:-}")" in done|'done?') return 0 ;; esac
  return 1
}

# _factory_job_wait_reason <job-id> -> one plain line explaining why the job does not count as finished.
_factory_job_wait_reason() {
  local st; st="$(_factory_job_status "$1" | grep . || echo missing)"
  case "$st" in
    running|launching|working|stalled*|verifying)
      printf 'worker job %s is still running (status: %s); wait for it with: outsourcerer wait %s' "$1" "$st" "$1" ;;
    *) printf 'worker job %s has not finished successfully (status: %s); retry the task or read: outsourcerer explain %s' "$1" "$st" "$1" ;;
  esac
}

# _factory_scan_range <dir> <base> <head> -> rc0 = a live secret VALUE was added in base..head (block),
# rc1 = clean, rc2 = history could not be read (callers fail closed). Same hardening as
# _crew_scan_staged: --text/--no-ext-diff/--no-textconv defeat a planted .gitattributes, and the diff
# is captured BEFORE grep so a big diff can't SIGPIPE git into a false "clean". Inspect every new
# commit, including merge-parent diffs, so deleting a secret later cannot hide leaked history.
_factory_scan_range() {
  local _sd
  _sd="$(git -C "$1" log -p -m --root --format= --text --no-ext-diff --no-textconv --no-color "$2..$3" -- 2>/dev/null)" || return 2
  # Only ADDED lines, only key VALUES: removing a leaked key, or code that merely names
  # OPENROUTER_API_KEY, must never block a land.
  grep -Eq "$OSRC_SECRET_ADDED_ERE" <<<"$_sd" && return 0
  return 1
}

# _factory_check_run <dir> <check> <outfile> -> runs the check (bounded) and fills _FG_CHECK_RC,
# _FG_SIG (cksum of the normalized signature) and _FG_TAIL (last lines, capped).
_factory_check_run() {
  local rc=0
  _crew_check "$1" "$2" "$3"; rc=$?
  _FG_CHECK_RC="$rc"
  _FG_SIG="$(_check_signature < "$3" 2>/dev/null | cksum | awk '{print $1}')"
  _FG_TAIL="$(tail -n 20 "$3" 2>/dev/null | cut -c1-300 | head -c 4000)"
  return "$rc"
}

_factory_gate_reset() {
  _FG_BASE=""; _FG_HEAD=""; _FG_BRANCH=""; _FG_AHEAD=0; _FG_CHECK=""; _FG_CHECK_RC=""
  _FG_SIG=""; _FG_TAIL=""; _FG_SECRET="not_run"; _FG_REASON=""
}

# _factory_gate_ship <worktree> <base_sha> <job-id> <check> <outdir>
# The ship rules of the done contract, in cheapest-first order. rc0 pass / rc1 fail; the reason is in
# _FG_REASON (one plain line, says what to do next). Fills _FG_* for the evidence record.
_factory_gate_ship() {
  local wt="$1" base="$2" job="$3" check="$4" outdir="$5" st cont dirtyf rc
  _FG_BASE="$base"; _FG_CHECK="$check"
  if [ -z "$job" ]; then _FG_REASON="no worker job is on record for this work yet; start it first"; return 1; fi
  if ! _factory_job_ok "$job"; then
    _FG_REASON="$(_factory_job_wait_reason "$job")"
    return 1
  fi
  if [ -z "$wt" ]; then _FG_REASON="no worktree is on record (ship work must run in its own worktree)"; return 1; fi
  if ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _FG_REASON="the worktree $wt is missing or is not a git checkout"; return 1
  fi
  _FG_HEAD="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  _FG_BRANCH="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -z "$base" ] || ! git -C "$wt" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1; then
    _FG_REASON="no usable base commit is on record, so new commits can't be counted"; return 1
  fi
  _FG_BASE="$(git -C "$wt" rev-parse "$base^{commit}")"; [ "$_FG_HEAD" != "$_FG_BASE" ] || ! type _osrc_harness_commit >/dev/null 2>&1 || ! _osrc_harness_commit "$wt" "$job" || _FG_HEAD="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  _FG_AHEAD="$(git -C "$wt" rev-list --count "$_FG_BASE..$_FG_HEAD" 2>/dev/null)"; _FG_AHEAD="${_FG_AHEAD:-0}"
  if [ "$_FG_AHEAD" -lt 1 ] 2>/dev/null; then
    _FG_REASON="the worker made no commits beyond the base ${_FG_BASE:0:12}; there is nothing to land"; return 1
  fi
  if ! _crew_worktree_clean "$wt"; then
    dirtyf="$(git -C "$wt" status --porcelain -uno 2>/dev/null | head -1 | cut -c4-)"
    _FG_REASON="the worktree has uncommitted changes to tracked files (${dirtyf:-?}); commit or discard them in $wt, then check again"
    return 1
  fi
  # Reachable from a NAMED branch (refs are shared by every worktree of the repo), not only a detached HEAD.
  cont="$(git -C "$wt" for-each-ref --contains "$_FG_HEAD" --format='%(refname:short)' refs/heads/ 2>/dev/null)"
  if [ -z "$cont" ]; then
    _FG_REASON="the latest commit ${_FG_HEAD:0:12} is not on any branch (detached HEAD); put it on a branch, then check again"
    return 1
  fi
  [ -n "$_FG_BRANCH" ] || _FG_BRANCH="$(printf '%s\n' "$cont" | head -1)"
  _factory_scan_range "$wt" "$_FG_BASE" "$_FG_HEAD"; rc=$?
  case "$rc" in
    0) _FG_SECRET="blocked"
       _FG_REASON="the changes contain what looks like a live secret (API key, token or private key); remove it from the branch history, then check again"
       return 1 ;;
    2) _FG_SECRET="blocked"
       _FG_REASON="could not read the diff to scan it for secrets; refusing to pass it unscanned"
       return 1 ;;
  esac
  _FG_SECRET="clean"
  if [ -n "$check" ]; then
    mkdir -p "$outdir" 2>/dev/null
    _factory_check_run "$wt" "$check" "$outdir/check.out"; rc=$?
    case "$rc" in
      0) ;;
      124) _FG_REASON="the check timed out in the worktree: $check"; return 1 ;;
      125) _FG_REASON="the check could not be started in the worktree: $check"; return 1 ;;
      *)   _FG_REASON="the check failed in the worktree (exit $rc): $check"; return 1 ;;
    esac
  fi
  if [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" != "$_FG_HEAD" ] || ! _crew_worktree_clean "$wt"; then
    _FG_REASON="the check changed HEAD or tracked files; checks must verify the committed tree without changing it"
    return 1
  fi
  local cmsg="no check set"; [ -n "$check" ] && cmsg="check passed"
  _FG_REASON="$_FG_AHEAD new commit(s) on $_FG_BRANCH, $cmsg, no secrets found"
  return 0
}

# _factory_evidence_json <task-or-job> <shape> <job> <verdict> <reason> -> evidence JSON from _FG_*.
_factory_evidence_json() {
  jq -cn --arg task "$1" --arg shape "$2" --arg job "$3" --arg verdict "$4" --arg reason "$5" \
    --arg base "${_FG_BASE:-}" --arg head "${_FG_HEAD:-}" --arg cmd "${_FG_CHECK:-}" \
    --arg rc "${_FG_CHECK_RC:-}" --arg sig "${_FG_SIG:-}" --arg tail "${_FG_TAIL:-}" \
    --arg sec "${_FG_SECRET:-not_run}" --arg ts "$(_fl_now)" \
    '{task:$task,shape:$shape,job:$job,base_sha:$base,head_sha:$head,
      check:{cmd:$cmd,rc:(if $rc=="" then null else ($rc|tonumber) end),signature:$sig,tail:$tail},
      secret_scan:$sec,verdict:$verdict,reason:$reason,ts:$ts}'
}

# _factory_done_eval <plan> <tid> <outdir> [check-override]
# The done contract, evaluated WITHOUT writing anything to the task or its evidence (the check's own
# output goes to <outdir>/check.out). Fills, in the caller's shell: _FDC_RC (0 done / 1 not done),
# _FDC_REASON, _FDC_SHAPE, _FDC_JOB, _FDC_TDIR, _FDC_REPORT (scout text) and the _FG_* gate fields
# (_FG_HEAD = the exact commit that was verified). Call it directly, never inside $(...), so the
# verified head stays private to the caller and can't be swapped by a concurrent evidence write.
_factory_done_eval() {
  local plan="${1:-}" tid="${2:-}" outdir="${3:-}" ovr_set=0 ovr=""
  [ $# -ge 4 ] && { ovr_set=1; ovr="$4"; }
  _FDC_RC=1; _FDC_REASON=""; _FDC_SHAPE="ship"; _FDC_JOB=""; _FDC_TDIR=""; _FDC_REPORT=""
  _factory_gate_reset
  local tj; tj="$(_task_get "$plan" "$tid" 2>/dev/null)" || { _FDC_REASON="there is no task $tid in plan $plan"; return 1; }
  local pd shape job check wt base wj
  pd="$(_plan_dir "$plan")"; _FDC_TDIR="$pd/tasks/$tid"; [ -n "$outdir" ] || outdir="$_FDC_TDIR"
  shape="$(_fl_jq -r '.shape // "ship"' <<<"$tj")"
  job="$(_fl_jq -r '.job // ""' <<<"$tj")"; _FDC_JOB="$job"
  check="$(_fl_jq -r '.check // ""' <<<"$tj")"; [ "$ovr_set" = 1 ] && check="$ovr"
  wt="$(_fl_jq -r '.worktree // ""' <<<"$tj")"; base="$(_fl_jq -r '.base_sha // ""' <<<"$tj")"
  # Fall back to the job's worktree receipt for anything the task record is missing.
  if [ -n "$job" ] && { [ -z "$wt" ] || [ -z "$base" ]; }; then
    wj="$OSRC_JOBS/$job/worktree.json"
    if [ -f "$wj" ]; then
      [ -n "$wt" ] || wt="$(_fl_jq -r '.path // ""' "$wj" 2>/dev/null)"
      [ -n "$base" ] || base="$(_fl_jq -r '.base_sha // ""' "$wj" 2>/dev/null)"
    fi
  fi
  if [ "$shape" = "scout" ]; then
    _FDC_SHAPE="scout"
    local res="" src=""
    if [ -z "$job" ]; then _FDC_REASON="no worker job is on record for this task yet; start it first"
    elif ! _factory_job_ok "$job"; then
      _FDC_REASON="$(_factory_job_wait_reason "$job")"
    else
      if [ -s "$OSRC_JOBS/$job/last.txt" ]; then src="$OSRC_JOBS/$job/last.txt"
      elif [ -s "$OSRC_JOBS/$job/out.log" ]; then src="$OSRC_JOBS/$job/out.log"; fi
      [ -n "$src" ] && res="$(cat "$src" 2>/dev/null)"
      if [ -z "$(printf '%s' "$res" | tr -d '[:space:]')" ]; then
        _FDC_REASON="worker job $job finished but left no result to read; retry it"
      else
        _FDC_REPORT="$res"; _FDC_REASON="report saved to $_FDC_TDIR/report.md"; _FDC_RC=0
      fi
    fi
  else
    if _factory_gate_ship "$wt" "$base" "$job" "$check" "$outdir"; then _FDC_RC=0; fi
    _FDC_REASON="$_FG_REASON"
  fi
  return "$_FDC_RC"
}

# _factory_done_record <plan> <tid> -> persist what _factory_done_eval found: report.md (scout),
# evidence.json, and the task's .evidence (+ .head_sha for ship). rc1 when the evidence could not be
# saved (a pass is then downgraded: no proof on disk, no pass).
_factory_done_record() {
  local plan="$1" tid="$2" tdir="$_FDC_TDIR" ev verdict ej
  mkdir -p "$tdir" 2>/dev/null; ev="$tdir/evidence.json"
  if [ "$_FDC_SHAPE" = scout ] && [ "$_FDC_RC" = 0 ]; then
    local rtmp="$tdir/report.md.tmp.$$"
    if ( umask 077; printf '%s\n' "$_FDC_REPORT" > "$rtmp" ) 2>/dev/null && mv -f "$rtmp" "$tdir/report.md"; then :
    else rm -f "$rtmp" 2>/dev/null; _FDC_RC=1; _FDC_REASON="could not save the report to $tdir/report.md"; fi
  fi
  verdict="not_done"; [ "$_FDC_RC" = 0 ] && verdict="done"
  ej="$(_factory_evidence_json "$tid" "$_FDC_SHAPE" "$_FDC_JOB" "$verdict" "$_FDC_REASON")"
  if ! _fl_write_json "$ev" "$ej"; then
    echo "warning: could not write $ev" >&2
    if [ "$_FDC_RC" = 0 ]; then _FDC_RC=1; _FDC_REASON="could not save the evidence to $ev; fix the folder's permissions, then check again"; fi
    return 1
  fi
  if [ "$_FDC_SHAPE" = ship ] && [ -n "${_FG_HEAD:-}" ]; then
    _task_update "$plan" "$tid" '.evidence=$e | .head_sha=$h' --arg e "$ev" --arg h "$_FG_HEAD" >/dev/null 2>&1 || true
  else
    _task_update "$plan" "$tid" '.evidence=$e' --arg e "$ev" >/dev/null 2>&1 || true
  fi
  return 0
}

# _factory_done_check <plan> <tid> [check-override]
# The done contract. rc0 = done, rc1 = not done. Writes tasks/<tid>/evidence.json, records its path
# (and head_sha for ship) on the task, and prints ONE plain line: "<tid> done: ..." / "<tid> not done: ...".
# The optional 3rd arg replaces the task's check. It updates the task via _task_update, so do NOT
# call it while holding the plan lock.
_factory_done_check() {
  local plan="${1:-}" tid="${2:-}"
  have jq || die "the factory needs jq; install it (brew install jq / apt install jq) and try again"
  [ -n "$plan" ] && [ -n "$tid" ] || { echo "usage: _factory_done_check <plan> <tid>"; return 1; }
  if ! _task_get "$plan" "$tid" >/dev/null 2>&1; then echo "$tid not done: there is no task $tid in plan $plan"; return 1; fi
  if [ $# -ge 3 ]; then _factory_done_eval "$plan" "$tid" "" "$3"; else _factory_done_eval "$plan" "$tid" ""; fi
  _factory_done_record "$plan" "$tid"
  if [ "$_FDC_RC" = 0 ]; then echo "$tid done: $_FDC_REASON"; else echo "$tid not done: $_FDC_REASON"; fi
  return "$_FDC_RC"
}

# ---------------------------------------------------------------------------------------------
# Merge queue lock: one land at a time per repository (mkdir lock, pid + start-identity owner,
# provably-dead owners reclaimed; a live owner is never broken by age).
# ---------------------------------------------------------------------------------------------
_land_lock_dir() {
  local key common
  common="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in /*|[A-Za-z]:[\\/]*) ;; *) common="$1/$common" ;; esac
  common="$(cd "$common" && pwd -P)" || return 1
  key="$(printf '%s' "$common" | cksum | awk '{print $1}')"
  printf '%s/locks/land-%s' "$OSRC_HOME" "$key"
}

# Missing process inspection is unknown, not death. Only ESRCH proves absence when ps is denied.
_land_owner_dead() {
  local pid="$1" start="$2" cur rc=0 err
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  cur="$(_pid_start_identity "$pid" 2>/dev/null)" || rc=$?
  [ "$rc" = 2 ] && return 0
  [ "$rc" = 0 ] && [ -n "$start" ] && [ "$cur" != "$start" ] && return 0
  if [ "$rc" = 1 ]; then
    err="$(LC_ALL=C kill -0 "$pid" 2>&1)" && return 1
    case "$err" in *'No such process'*|*'no such process'*) return 0 ;; esac
  fi
  return 1
}

# Creation, reclamation and release use the same guard, closing the check/mkdir race too.
_land_guard_acquire() {
  local guard="$1.steal" me="$2" gp gs gline=""
  if ! _mkdir_claim "$guard"; then
    { IFS= read -r gline < "$guard/owner"; } 2>/dev/null || return 1
    read -r gp gs <<<"$gline"
    _land_owner_dead "$gp" "$gs" || return 1
    # A killed reclaimer can leave its guard behind. Reclaim it with the same ownership protocol.
    _land_lock_break "$guard" "$gline" "$me" || return 1
    _mkdir_claim "$guard" || return 1
  fi
  if ! printf '%s %s\n' "$me" "$(_pid_start_identity "$me" 2>/dev/null)" > "$guard/owner"; then
    rm -f "$guard/owner"; rmdir "$guard" 2>/dev/null; return 1
  fi
}

_land_guard_release() {
  rm -f "$1.steal/owner"; rmdir "$1.steal" 2>/dev/null || true
}

# Reclaimers serialize, then check the moved directory too. Never delete a replacement owner.
_land_lock_break() {
  local lk="$1" seen="$2" me="$3" cur="" moved="" corpse rc=1
  _land_guard_acquire "$lk" "$me" || return 1
  { IFS= read -r cur < "$lk/owner"; } 2>/dev/null || cur=""
  if [ -d "$lk" ] && [ "$cur" = "$seen" ]; then
    corpse="$lk.stale.$me.${RANDOM:-0}"
    if mv "$lk" "$corpse" 2>/dev/null; then
      { IFS= read -r moved < "$corpse/owner"; } 2>/dev/null || moved=""
      if [ "$moved" = "$seen" ]; then rm -rf "$corpse"; rc=0
      else [ -e "$lk" ] || mv "$corpse" "$lk"; fi
    fi
  fi
  _land_guard_release "$lk"
  return "$rc"
}

# _land_lock_acquire <repo-root> <holder-description> -> rc0 holding (_LAND_LOCK set), rc1 timed out.
_land_lock_acquire() {
  local lk wait start now said=0 o_pid o_start o_line holder me age grace
  lk="$(_land_lock_dir "$1")" || return 1
  mkdir -p "${lk%/*}" 2>/dev/null
  wait="${OSRC_LAND_LOCK_WAIT:-900}"; case "$wait" in ''|*[!0-9]*) wait=900 ;; esac
  grace="${OSRC_STATE_LOCK_STALE_SECS:-30}"
  _fl_self_pid; me="$_FL_PID"; start="$(date +%s)"
  while :; do
    if _land_guard_acquire "$lk" "$me"; then
      if _mkdir_claim "$lk"; then
        _LAND_LOCK_OWNER="$me $(_pid_start_identity "$me" 2>/dev/null)"
        if ! { printf '%s\n' "$_LAND_LOCK_OWNER" > "$lk/owner.tmp" 2>/dev/null \
          && mv -f "$lk/owner.tmp" "$lk/owner" 2>/dev/null; }; then
          rm -f "$lk/owner.tmp"; rmdir "$lk" 2>/dev/null || true
          _land_guard_release "$lk"
          _LAND_LOCK_OWNER=""
          echo "[land] could not publish merge-queue ownership; nothing was changed." >&2
          return 1
        fi
        printf '%s (since %s)\n' "$2" "$(_fl_now)" > "$lk/holder" 2>/dev/null
        _LAND_LOCK="$lk"; _land_guard_release "$lk"; return 0
      fi
      _land_guard_release "$lk"
    fi
    o_pid=""; o_start=""; o_line=""
    if [ -f "$lk/owner" ]; then
      { IFS= read -r o_line < "$lk/owner"; } 2>/dev/null || true
      read -r o_pid o_start <<<"$o_line"
      if _land_owner_dead "$o_pid" "$o_start" && _land_lock_break "$lk" "$o_line" "$me"; then
        echo "[land] cleared a leftover merge-queue lock from a land that is no longer running (pid $o_pid)." >&2
        continue
      fi
    else
      age="$(_mtime "$lk" 2>/dev/null)"; case "$age" in ''|*[!0-9]*) age=0 ;; esac
      if [ "$age" -gt 0 ] && [ $(( $(date +%s) - age )) -ge "$grace" ]; then
        _land_lock_break "$lk" "" "$me" && continue
      fi
    fi
    holder="$(head -1 "$lk/holder" 2>/dev/null)"
    if [ "$said" = 0 ]; then
      echo "[land] waiting in the merge queue: ${holder:-another land} is merging into this repo (pid ${o_pid:-?}). Lands go one at a time." >&2
      said=1
    fi
    now="$(date +%s)"
    if [ $(( now - start )) -ge "$wait" ]; then
      echo "[land] gave up after ${wait}s waiting for: ${holder:-another land} (pid ${o_pid:-?}). If it is stuck, stop that process and run land again; OSRC_LAND_LOCK_WAIT sets the wait." >&2
      return 1
    fi
    sleep 1
  done
}

_land_lock_release() {
  [ -n "${_LAND_LOCK:-}" ] || return 0
  [ -n "${_LAND_LOCK_OWNER:-}" ] && _land_lock_break "$_LAND_LOCK" "$_LAND_LOCK_OWNER" "${_FL_PID:-$$}"
  _LAND_LOCK=""; _LAND_LOCK_OWNER=""
}

# _land_checkout_of <root> <branch> -> path of the worktree that has <branch> checked out (empty = none).
_land_checkout_of() {
  git -C "$1" worktree list --porcelain 2>/dev/null \
    | awk -v ref="refs/heads/$2" '/^worktree /{p=substr($0,10)} $0=="branch " ref {print p; exit}'
}

# _land_wake <id> <summary> -> best-effort wake event so a sleeping orchestrator hears about it.
_land_wake() {
  type _wake_append >/dev/null 2>&1 || return 0
  local eid; eid="land.$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_').$(date +%s)"
  _wake_append "$(jq -cn --arg e "$eid" --arg s "$2" '{event_id:$e,kind:"land",state:"failed",task_summary:$s}')" >/dev/null 2>&1 || true
}

_land_cleanup() {
  if [ -n "${_LAND_IWT:-}" ] && [ -n "${_LAND_ROOT:-}" ]; then
    git -C "$_LAND_IWT" merge --abort >/dev/null 2>&1 || true
    git -C "$_LAND_ROOT" worktree remove --force "$_LAND_IWT" >/dev/null 2>&1 || rm -rf "$_LAND_IWT" 2>/dev/null
    git -C "$_LAND_ROOT" worktree prune >/dev/null 2>&1 || true
    rm -f "$OSRC_HOME/land/active/${_LAND_IWT##*/}" 2>/dev/null
    _LAND_IWT=""
  fi
  _land_lock_release
}

# _land_prune_stale <root> -> remove scratch land-* worktrees left by a land that was killed
# (SIGKILL skips the trap). Called only while holding this repo's merge-queue lock, and a scratch
# worktree whose recorded owner is still alive is always kept.
_land_prune_stale() {
  local root="$1" d n own o_pid o_start
  for d in "$root/.outsourcerer/worktrees"/land-*; do
    [ -e "$d" ] || continue
    n="${d##*/}"; own="$OSRC_HOME/land/active/$n"
    if [ -f "$own" ]; then
      o_pid=""; o_start=""; { read -r o_pid o_start < "$own"; } 2>/dev/null || true
      case "$o_pid" in
        ''|*[!0-9]*) ;;
        *) _land_owner_dead "$o_pid" "$o_start" || continue ;;
      esac
    fi
    git -C "$root" worktree remove --force "$d" >/dev/null 2>&1 || rm -rf "$d" 2>/dev/null
    rm -f "$own" 2>/dev/null
    echo "[land] removed a leftover scratch worktree from a land that is no longer running: $n" >&2
  done
  git -C "$root" worktree prune >/dev/null 2>&1 || true
}

# _land_branch_busy <root> <branch> -> prints "a rebase|a bisect in <path>" when <branch> is in the
# middle of one in ANY worktree of the repo (the branch then shows as detached, so the checkout test
# can't see it, and moving the ref would pull it out from under the operation). Empty = not busy.
_land_branch_busy() {
  local root="$1" br="$2" common gd what wtp hn
  common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || return 0
  case "$common" in /*) ;; [A-Za-z]:[\\/]*) ;; *) common="$root/$common" ;; esac
  for gd in "$common" "$common"/worktrees/*; do
    [ -d "$gd" ] || continue
    what=""
    for hn in "$gd/rebase-merge/head-name" "$gd/rebase-apply/head-name"; do
      [ -f "$hn" ] && [ "$(head -1 "$hn" 2>/dev/null)" = "refs/heads/$br" ] && what="a rebase"
    done
    if [ -z "$what" ] && [ -f "$gd/BISECT_START" ]; then
      case "$(head -1 "$gd/BISECT_START" 2>/dev/null)" in "$br"|"refs/heads/$br") what="a bisect" ;; esac
    fi
    [ -n "$what" ] || continue
    if [ "$gd" = "$common" ]; then wtp="$(git -C "$root" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
    else wtp="$(sed 's#/\.git$##' "$gd/gitdir" 2>/dev/null)"; fi
    printf '%s in %s' "$what" "${wtp:-$gd}"
    return 0
  done
  return 0
}

# _land_untracked_collisions <checkout> <git-diff-range...> -> prints (max 20) paths the update would
# ADD that already exist in <checkout> as untracked or git-ignored files (local config, .env ...).
# A fast-forward silently overwrites ignored files, so land refuses instead.
_land_untracked_collisions() {
  local co="$1" p pre rest comp hit; shift
  git -C "$co" diff --name-only --no-renames -z --diff-filter=A "$@" 2>/dev/null \
  | while IFS= read -r -d '' p; do
      hit=""; pre=""; rest="$p"
      while :; do
        case "$rest" in */*) ;; *) break ;; esac
        comp="${rest%%/*}"; rest="${rest#*/}"; pre="${pre:+$pre/}$comp"
        if [ -L "$co/$pre" ] || { [ -e "$co/$pre" ] && [ ! -d "$co/$pre" ]; }; then hit="$pre"; break; fi
      done
      if [ -z "$hit" ] && { [ -e "$co/$p" ] || [ -L "$co/$p" ]; }; then hit="$p"; fi
      [ -n "$hit" ] || continue
      [ -z "$(git -C "$co" ls-files -- ":(literal)$hit" 2>/dev/null | head -1)" ] && printf '%s\n' "$hit"
    done | sort -u | head -20
}

# _land_contained_via_land <evidence-land-json> <into> <head> <root> [plan] -> rc0 when <head> reached
# <into> through an earlier land (this work's own land record, or a landed task of the plan whose
# landed commit contains it). Anything else got there without the merged-result check.
_land_contained_via_land() {
  local prev="$1" into="$2" head="$3" root="$4" plan="${5:-}" f ls
  if [ -n "$prev" ] && [ "$(_fl_jq -r '.verdict // ""' <<<"$prev" 2>/dev/null)" = landed ] \
     && [ "$(_fl_jq -r '.into // ""' <<<"$prev" 2>/dev/null)" = "$into" ]; then return 0; fi
  [ -n "$plan" ] || return 1
  for f in "$(_plan_dir "$plan")"/tasks/t*.json; do
    [ -f "$f" ] || continue
    ls="$(_fl_jq -r --arg i "$into" 'if (.landed == true) and ((.landed_into // "") == $i) then (.landed_sha // "") else "" end' "$f" 2>/dev/null)"
    [ -n "$ls" ] || continue
    git -C "$root" merge-base --is-ancestor "$head" "$ls" 2>/dev/null && return 0
  done
  return 1
}

# States a land may start from: the work ran (running/verifying) or passed (done). failed only with
# --force; todo, held and canceled never. Used as a jq guard so every task write re-checks it.
_LAND_OK_JQ='(.state == "running" or .state == "verifying" or .state == "done" or ($force == "1" and .state == "failed"))'

_land_attempt() {
  _fl_jq -c '[.attempt_token // "", .job // "", .worktree // "", .branch // "", .base_sha // "", .attempts // 0]'
}

# Check both state and attempt before publishing anything, including PRs.
_land_assert_current() {
  local current refusal
  current="$(_task_get "$1" "$2")" || die "land: task $1/$2 disappeared"
  refusal="$(_land_state_refusal "$2" "$current" "$3" "$1")" && die "land: $refusal"
  [ "$(printf '%s' "$current" | _land_attempt)" = "$_LAND_ATTEMPT" ] \
    || die "land: $1/$2 changed attempts while landing; run outsourcerer land $2 --plan $(printf %q "$1") again"
  _land_reviews_current "$1" "$2" "$4"
}

# Older plans without reviewed_head retain their existing contract. New reviews bind to a SHA.
_land_reviews_current() {
  local plan="$1" tid="$2" head="$3" f
  for f in "$(_plan_dir "$plan")"/tasks/t*.json; do
    [ -f "$f" ] || continue
    if _fl_jq -e --arg t "$tid" --arg h "$head" \
      '(.require_verdict == true) and ((.deps // [] | index($t)) != null) and has("reviewed_head")
       and (.reviewed_head != $h or .state != "done")' "$f" >/dev/null; then
      die "land: review ${f##*/} does not approve revision ${head:0:12}; run outsourcerer plan run --plan $(printf %q "$plan") before outsourcerer land $tid --plan $(printf %q "$plan")"
    fi
  done
}

_land_error() {
  local plan="$1" tid="$2" why="$3"
  _task_update "$plan" "$tid" \
    'if ([.attempt_token // "", .job // "", .worktree // "", .branch // "", .base_sha // "", .attempts // 0] == $owner)
     then .land_error=$r | .land_error_at=$ts else error("attempt changed") end' \
    --argjson owner "$_LAND_ATTEMPT" --arg r "$why" --arg ts "$(_fl_now)" >/dev/null 2>&1
}

# _land_state_refusal <tid> <task-json> <force> -> rc0 + prints a plain refusal when the state forbids landing.
_land_state_refusal() {
  local tid="$1" tj="$2" force="$3" st p
  printf -v p '%q' "${4:-${plan:-<plan>}}"
  st="$(_fl_jq -r '.state // ""' <<<"$tj")"
  case "$st" in
    running|verifying|done) return 1 ;;
    failed)
      [ "$force" = 1 ] && return 1
      printf '%s failed (%s). Fix it and run it again (outsourcerer task retry %s --plan %s), or, if you have checked the work yourself, land it anyway with: outsourcerer land %s --plan %s --force' \
        "$tid" "$(_fl_jq -r '.result // "no reason recorded"' <<<"$tj" | head -1 | cut -c1-160)" "$tid" "$p" "$tid" "$p" ;;
    held)
      printf '%s is on hold (%s). Settle it first: outsourcerer task release %s --plan %s --answer "..." (add --done if the work is ready), then land again' \
        "$tid" "$(_fl_jq -r '.hold.reason // "no reason recorded"' <<<"$tj" | head -1 | cut -c1-160)" "$tid" "$p" ;;
    canceled) printf '%s was canceled; retry it first if you still want it (outsourcerer task retry %s --plan %s)' "$tid" "$tid" "$p" ;;
    todo) printf '%s has not run yet; start it first (outsourcerer task start %s --plan %s)' "$tid" "$tid" "$p" ;;
    *) printf '%s is in state "%s", which is not one land can start from' "$tid" "$st" ;;
  esac
  return 0
}

_land_usage() {
  cat <<'EOF2'
usage: outsourcerer land <task-id|job-id> [--plan P] [--check CMD | --no-check] [--setup CMD]
                         [--into BRANCH] [--pr] [--dry-run] [--force]
  Merges finished ship work into a branch, one land at a time per repo, only when it passes the
  done contract and the check still passes on the merged result.
  --plan P       plan the task belongs to (default: the current plan)
  --check CMD    check to run (default: the task's own check). A bare job id has no check of its
                 own, so it needs --check or an explicit --no-check
  --no-check     land without running any check (explicit opt-out)
  --setup CMD    run CMD in the scratch checkout of the merged result before the check (the merged
                 result is checked in a CLEAN checkout: no node_modules, .venv or other untracked
                 files; e.g. --setup "npm ci")
  --into BRANCH  branch to land on (default: the plan's base branch, else the repo's current branch)
  --pr           push the branch and open a pull request instead of moving BRANCH
  --dry-run      do every step in scratch, but leave BRANCH, the task and its evidence untouched
  --force        land a task that is marked failed (never a held or canceled one)
  Task delivery: pr acts as --pr; branch verifies and records the branch without merging.
EOF2
}

cmd_land() { ( _land_run "$@" ); }

# _land_run -- body of `land`, always in a subshell so its EXIT trap (integration worktree + lock
# cleanup) never replaces the main script's traps, and a die() anywhere still cleans up.
_land_run() {
  local target="" plan_arg="" check="" check_set=0 nocheck=0 setup="" into="" pr=0 dry=0 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --plan)     [ -n "${2:-}" ] || die "land --plan needs a plan name"; plan_arg="$2"; shift 2 ;;
      --check)    [ $# -ge 2 ] || die "land --check needs a command"; check="$2"; check_set=1; shift 2 ;;
      --no-check) nocheck=1; shift ;;
      --setup)    [ -n "${2:-}" ] || die "land --setup needs a command, e.g. --setup \"npm ci\""; setup="$2"; shift 2 ;;
      --into)     [ -n "${2:-}" ] || die "land --into needs a branch name"; into="$2"; shift 2 ;;
      --pr)       pr=1; shift ;;
      --dry-run)  dry=1; shift ;;
      --force)    force=1; shift ;;
      -h|--help)  _land_usage; return 0 ;;
      -*)         die "land: unknown option $1 (see: outsourcerer land --help)" ;;
      *)          [ -z "$target" ] || die "land takes one task or job id (got '$target' and '$1')"; target="$1"; shift ;;
    esac
  done
  [ -n "$target" ] || { _land_usage >&2; exit 1; }
  have git || die "land needs git"
  have jq || die "the factory needs jq; install it (brew install jq / apt install jq) and try again"
  [ "$pr" = 1 ] && [ "$dry" = 1 ] && die "land: pick --pr or --dry-run, not both"
  [ "$nocheck" = 1 ] && [ "$check_set" = 1 ] && die "land: pick --check or --no-check, not both"
  if [ "$nocheck" = 1 ]; then check=""; check_set=1; fi

  local mode plan="" tid="" jid="" tj="" wt="" branch="" base="" title="" repo="" evf="" ev_dir="" pd=""
  local deliver=local _LAND_ATTEMPT="" intent="" retry_hint=""
  case "$target" in
    t[0-9]*) mode=task ;;
    *) case "$target" in */*|*..*) die "land: '$target' is not a task or job id" ;; esac
       [ -d "$OSRC_JOBS/$target" ] || die "land: no task or job named '$target' (tasks look like t3; see: outsourcerer task ls --plan $(printf %q "${plan_arg:-<plan>}"))"
       mode=job ;;
  esac

  if [ "$mode" = task ]; then
    type _task_get >/dev/null 2>&1 || die "land: the task store is not loaded (factory-tasks.sh missing); update outsourcerer"
    plan="$(_plan_resolve ${plan_arg:+"$plan_arg"})" || exit 1
    [ -n "$plan" ] || die "land: no plan given and no current plan set (use --plan or: outsourcerer plan use <name>)"
    tid="$target"
    tj="$(_task_get "$plan" "$tid" 2>/dev/null)" || die "land: there is no task $tid in plan $plan (see: outsourcerer task ls --plan $(printf %q "$plan"))"
    _LAND_ATTEMPT="$(printf '%s' "$tj" | _land_attempt)"
    deliver="$(_fl_jq -r '.deliver // "local"' <<<"$tj")"
    [ "$deliver" = pr ] && pr=1
    [ "$pr" = 1 ] && deliver=pr
    intent="$(_fl_jq -c '.land_intent // empty' <<<"$tj")"
    retry_hint="outsourcerer land $tid --plan $(printf %q "$plan")"
    pd="$(_plan_dir "$plan")"; ev_dir="$pd/tasks/$tid"; evf="$ev_dir/evidence.json"
    local shape landed refusal
    shape="$(_fl_jq -r '.shape // "ship"' <<<"$tj")"
    landed="$(_fl_jq -r '.landed // false' <<<"$tj")"
    [ "$shape" = scout ] && die "land: $tid is a scout task; it produces a report, not code, so there is nothing to merge"
    [ "$landed" = true ] && { echo "$tid is already landed ($(_fl_jq -r '.landed_sha // "" | .[0:12]' <<<"$tj") on $(_fl_jq -r '.landed_into // "?"' <<<"$tj")); nothing to do."; return 0; }
    jid="$(_fl_jq -r '.job // ""' <<<"$tj")"
    wt="$(_fl_jq -r '.worktree // ""' <<<"$tj")"; branch="$(_fl_jq -r '.branch // ""' <<<"$tj")"
    base="$(_fl_jq -r '.base_sha // ""' <<<"$tj")"; title="$(_fl_jq -r '.title // ""' <<<"$tj")"
    [ "$check_set" = 1 ] || check="$(_fl_jq -r '.check // ""' <<<"$tj")"
    repo="$(_fl_jq -r '.repo // ""' "$pd/plan.json" 2>/dev/null)"
    [ -n "$into" ] || into="$(_fl_jq -r '.base_branch // ""' "$pd/plan.json" 2>/dev/null)"
  else
    [ "$force" = 1 ] && die "land: --force only applies to a plan task marked failed, not to a bare job"
    [ "$check_set" = 1 ] || die "land: a bare job has no check of its own. Pass --check \"<cmd>\" to verify it (or --no-check to land it unverified, on purpose)."
    jid="$target"; ev_dir="$OSRC_JOBS/$jid"; evf="$ev_dir/evidence.json"
    retry_hint="outsourcerer land $(printf %q "$jid") --check $(printf %q "$check")"
    local wj="$OSRC_JOBS/$jid/worktree.json"
    [ -f "$wj" ] || die "land: job $jid did not run in its own worktree, so there is no branch to land (launch it with --worktree)"
    title="$(_fl_jq -r '.task_summary // .task // ""' "$OSRC_JOBS/$jid/meta.json" 2>/dev/null | head -1 | cut -c1-72)"
  fi
  if [ -n "$jid" ] && [ -f "$OSRC_JOBS/$jid/worktree.json" ]; then
    [ -n "$wt" ] || wt="$(_fl_jq -r '.path // ""' "$OSRC_JOBS/$jid/worktree.json")"
    [ -n "$branch" ] || branch="$(_fl_jq -r '.branch // ""' "$OSRC_JOBS/$jid/worktree.json")"
    [ -n "$base" ] || base="$(_fl_jq -r '.base_sha // ""' "$OSRC_JOBS/$jid/worktree.json")"
  fi
  [ -n "$wt" ] || die "land: no worktree is on record for $target, so there is nothing to merge"
  case "$wt" in *'..'*) die "land: refusing a worktree path containing '..': $wt" ;; esac

  # Repository: the plan's repo, else the main checkout that owns the worker's worktree.
  if [ -z "$repo" ]; then
    case "$wt" in */.outsourcerer/worktrees/*) repo="${wt%/.outsourcerer/worktrees/*}" ;; esac
    [ -n "$repo" ] || repo="$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)"
  fi
  local root; root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" \
    || die "land: $repo is not a git repository"
  root="$(cd "$root" && pwd -P)"
  if [ -z "$into" ]; then
    into="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
      || die "land: $root has a detached HEAD, so there's no branch to land on; pass --into <branch>"
  fi
  git check-ref-format --branch "$into" >/dev/null 2>&1 || die "land: '$into' is not a valid branch name"
  git -C "$root" rev-parse --verify --quiet "refs/heads/$into" >/dev/null || die "land: branch '$into' does not exist in $root"

  local label; if [ "$mode" = task ]; then label="$plan/$tid"; else label="$jid"; fi
  [ -n "$title" ] || title="${branch:-$label}"
  local msg="land($label): $title"

  # A dry run writes NOTHING to the task or its evidence: its outputs go to a scratch folder.
  local out_dir="$ev_dir"
  if [ "$dry" = 1 ]; then
    out_dir="$OSRC_HOME/land/dry-run/$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '_')"
    rm -rf "$out_dir" 2>/dev/null; mkdir -p "$out_dir" 2>/dev/null || die "land: could not create $out_dir for the dry run"
  fi
  # The previous land record, read BEFORE the done check rewrites the evidence file.
  local prev_land=""; [ -s "$evf" ] && prev_land="$(jq -c '.land // empty' "$evf" 2>/dev/null)"
  if [ "$mode" = job ] && [ -s "$evf" ]; then intent="$(_fl_jq -c '.land_intent // empty' "$evf")"; fi

  # Recover a completed ref move before re-running checks or rejecting a later cancellation.
  # The receipt describes work already published, so preserve any intervening task state.
  local receipt_sha="" receipt_head="" recorded_head="" receipt_tip=""
  if [ -n "$intent" ] && [ "$pr" = 0 ] && [ "$deliver" = local ]; then
    receipt_sha="$(_fl_jq -r --arg i "$into" 'if .target == $i then .merged_sha // "" else "" end' <<<"$intent")"
    receipt_head="$(_fl_jq -r '.verified_head // ""' <<<"$intent")"
    if [ "$mode" = task ]; then recorded_head="$(_fl_jq -r '.head_sha // ""' <<<"$tj")"
    else recorded_head="$(_fl_jq -r '.head_sha // ""' "$evf")"; fi
    if [ -n "$receipt_sha" ] && [ -n "$receipt_head" ] && [ "$receipt_head" = "$recorded_head" ]; then
      _LAND_ROOT="$root"; _LAND_IWT=""; _LAND_LOCK=""
      trap '_land_cleanup' EXIT
      trap 'exit 130' INT TERM
      _land_lock_acquire "$root" "recover land $label into $into" || exit 1
      [ "$dry" = 1 ] || _land_prune_stale "$root"
      receipt_tip="$(git -C "$root" rev-parse "refs/heads/$into")"
      if git -C "$root" merge-base --is-ancestor "$receipt_sha" "$receipt_tip" 2>/dev/null \
        && git -C "$root" merge-base --is-ancestor "$receipt_head" "$receipt_sha" 2>/dev/null; then
        if [ "$dry" = 0 ]; then
          _land_record "$evf" "$(_fl_jq -cn --arg i "$into" --arg h "$receipt_head" --arg m "$receipt_sha" \
            '{into:$i,head_sha:$h,merged_sha:$m,verdict:"landed",reconciled:true}')" || die "land: could not reconcile evidence; run $retry_hint again"
          if [ "$mode" = task ]; then
            _task_update "$plan" "$tid" \
              "if ([.attempt_token // \"\", .job // \"\", .worktree // \"\", .branch // \"\", .base_sha // \"\", .attempts // 0] == \$owner)
               then .landed=true | .landed_sha=\$m | .landed_into=\$i | del(.land_error, .land_error_at)
                 | (if $_LAND_OK_JQ then .state=\"done\" else . end) else error(\"attempt changed\") end" \
              --argjson owner "$_LAND_ATTEMPT" --arg m "$receipt_sha" --arg i "$into" --arg force "$force" >/dev/null \
              || die "land: could not reconcile task receipt; run $retry_hint again"
          fi
        fi
        echo "$label is already contained in $into by an earlier land; recovered its landing receipt (dry-run=$dry)."
        return 0
      fi
      _land_lock_release
    fi
  fi
  if [ "$mode" = task ]; then
    refusal="$(_land_state_refusal "$tid" "$tj" "$force" "$plan")" && die "land: not landing $label. $refusal."
  fi

  # ---- 1. Done contract (outside the queue lock). Evaluated in THIS shell: the head it verified
  #         stays in a private variable, so a concurrent write to evidence.json can't swap what we
  #         merge, and later edits in the worker worktree can't sneak in. ----
  local head reason
  if [ "$mode" = task ]; then
    if [ "$check_set" = 1 ]; then _factory_done_eval "$plan" "$tid" "$out_dir" "$check"
    else _factory_done_eval "$plan" "$tid" "$out_dir"; fi
    [ "$dry" = 1 ] || _factory_done_record "$plan" "$tid"
    [ "$_FDC_RC" = 0 ] || die "land: not landing $label. $tid not done: $_FDC_REASON"
    reason="$tid done: $_FDC_REASON"
  else
    mkdir -p "$ev_dir" 2>/dev/null
    _factory_gate_reset
    if _factory_gate_ship "$wt" "$base" "$jid" "$check" "$out_dir"; then
      if [ "$dry" = 0 ]; then
        local job_evidence
        job_evidence="$(_factory_evidence_json "$jid" ship "$jid" done "$_FG_REASON")"
        if [ -n "$intent" ]; then job_evidence="$(_fl_jq --argjson receipt "$intent" '.land_intent=$receipt' <<<"$job_evidence")"; fi
        _fl_write_json "$evf" "$job_evidence" \
          || die "land: could not save the evidence to $evf; fix the folder's permissions, then run land again"
      fi
      reason="$jid done: $_FG_REASON"
    else
      [ "$dry" = 1 ] || _fl_write_json "$evf" "$(_factory_evidence_json "$jid" ship "$jid" not_done "$_FG_REASON")" || true
      die "land: not landing $jid. $_FG_REASON"
    fi
    [ -n "$check" ] || echo "[land] note: --no-check given; neither the work nor the merged result is verified by a check." >&2
  fi
  head="${_FG_HEAD:-}"
  [ -n "$head" ] || die "land: the done check passed but recorded no head commit; run land again"
  git -C "$root" cat-file -e "$head^{commit}" 2>/dev/null \
    || die "land: the verified commit ${head:0:12} is not in $root; run land again"
  echo "[land] $reason" >&2

  if [ "$mode" = task ]; then
    _land_assert_current "$plan" "$tid" "$force" "$head"
    if [ "$deliver" = branch ]; then
      [ "$(git -C "$root" rev-parse "refs/heads/$branch" 2>/dev/null)" = "$head" ] \
        || die "land: branch $branch no longer points at the verified head; run $retry_hint again"
      if [ "$dry" = 0 ]; then
        _task_update "$plan" "$tid" \
          "if $_LAND_OK_JQ and ([.attempt_token // \"\", .job // \"\", .worktree // \"\", .branch // \"\", .base_sha // \"\", .attempts // 0] == \$owner)
           then .delivered=\"branch\" | .delivered_branch=\$b | .delivered_head=\$h | .state=\"done\" | del(.land_error, .land_error_at)
           else error(\"task changed\") end" --argjson owner "$_LAND_ATTEMPT" --arg force "$force" --arg b "$branch" --arg h "$head" \
          >/dev/null || die "land: task changed before recording branch delivery; run $retry_hint again"
      fi
      echo "verified branch $branch for $label at ${head:0:12}; delivery mode branch leaves $into untouched (dry-run=$dry)."
      return 0
    fi
  fi

  # ---- 2. The merge queue (per-repo lock) ----
  _LAND_ROOT="$root"; _LAND_IWT=""; _LAND_LOCK=""
  trap '_land_cleanup' EXIT
  trap 'exit 130' INT TERM
  _land_lock_acquire "$root" "land $label into $into" || exit 1
  _land_prune_stale "$root"
  # The task may have been held or canceled while we waited in the queue.
  if [ "$mode" = task ]; then
    _land_assert_current "$plan" "$tid" "$force" "$head"
    [ "$dry" = 1 ] || { type _task_event >/dev/null 2>&1 && _task_event "$plan" "$tid" land_started "into $into" >/dev/null 2>&1; }
  fi
  local busy; busy="$(_land_branch_busy "$root" "$into")"
  [ -z "$busy" ] || die "land: $into is in the middle of $busy. Finish or abort it there (git rebase --continue/--abort, or git bisect reset), then run land again. Nothing was changed."

  local before; before="$(git -C "$root" rev-parse "refs/heads/$into")"
  if git -C "$root" merge-base --is-ancestor "$head" "$before" 2>/dev/null; then
    if ! _land_contained_via_land "$prev_land" "$into" "$head" "$root" "$plan"; then
      die "land: not landing $label. Its commit ${head:0:12} is already in $into, but it did not get there through land, so the merged result was never checked by the gate. Check $into yourself; if it is good, mark the task with: outsourcerer task done ${tid:-<task>} --plan $(printf %q "${plan:-<plan>}") --force. Nothing was changed."
    fi
    echo "$label is already contained in $into (${before:0:12}) by an earlier land; nothing to merge."
    if [ "$mode" = task ] && [ "$dry" = 0 ] && [ "$pr" = 0 ]; then
      _task_update "$plan" "$tid" ".landed=true | .landed_sha=\$m | .landed_into=\$i | (if $_LAND_OK_JQ then .state=\"done\" else . end)" \
        --arg m "$before" --arg i "$into" --arg force "$force" >/dev/null 2>&1 || true
    fi
    return 0
  fi

  # Fail fast (before any work) if the target's checkout can't be fast-forwarded safely.
  local co="" coll=""
  if [ "$pr" = 0 ] && [ "$dry" = 0 ]; then
    co="$(_land_checkout_of "$root" "$into")"
    if [ -n "$co" ]; then
      _crew_worktree_clean "$co" \
        || die "land: $into is checked out at $co with uncommitted changes; commit or stash them there, then run land again (nothing was changed)"
      coll="$(_land_untracked_collisions "$co" "$before...$head")"
      [ -z "$coll" ] || die "land: not landing $label. The work adds files that already exist, untracked or git-ignored, in your checkout of $into at $co: $(printf '%s' "$coll" | tr '\n' ' ')- landing would overwrite them. Move or back them up, then run land again (or land with --into another branch). Nothing was changed."
    fi
  fi

  # ---- 3. Fresh integration worktree at the target tip; no-ff merge of the VERIFIED head ----
  local lid nohooks; lid="land-$(_new_job_id)"
  nohooks="$OSRC_HOME/land/nohooks"; mkdir -p "$nohooks" "$OSRC_HOME/land/active" "$root/.outsourcerer/worktrees" 2>/dev/null
  type _osrc_git_exclude_state >/dev/null 2>&1 && _osrc_git_exclude_state "$root"
  _fl_self_pid
  printf '%s %s\n' "$_FL_PID" "$(_pid_start_identity "$_FL_PID" 2>/dev/null)" > "$OSRC_HOME/land/active/$lid" 2>/dev/null
  _LAND_IWT="$root/.outsourcerer/worktrees/$lid"
  # Hooks off for the checkout too: `worktree add` runs post-checkout.
  git -C "$root" -c "core.hooksPath=$nohooks" worktree add -q --detach "$_LAND_IWT" "$before" >/dev/null 2>&1 \
    || { _LAND_IWT=""; rm -f "$OSRC_HOME/land/active/$lid"; die "land: could not create a scratch worktree to merge in (under $root/.outsourcerer/worktrees)"; }
  local -a gc=(-c "core.hooksPath=$nohooks" -c commit.gpgsign=false)
  if [ -z "$(git -C "$root" config user.email 2>/dev/null)" ]; then
    gc+=(-c user.name=outsourcerer -c user.email=outsourcerer@users.noreply.github.com)
  fi
  local rec_evf="$evf"; [ "$dry" = 1 ] && rec_evf="$out_dir/evidence.json"
  local mlog="$out_dir/land-merge.log"; mkdir -p "$out_dir" 2>/dev/null
  local land_json now_ts
  if ! git -C "$_LAND_IWT" "${gc[@]}" merge --no-ff --no-edit -m "$msg" "$head" > "$mlog" 2>&1; then
    local conf; conf="$(git -C "$_LAND_IWT" diff --name-only --diff-filter=U 2>/dev/null | head -10 | tr '\n' ' ')"
    conf="${conf% }"
    git -C "$_LAND_IWT" merge --abort >/dev/null 2>&1 || true
    now_ts="$(_fl_now)"
    land_json="$(jq -cn --arg into "$into" --arg before "$before" --arg head "$head" --arg files "$conf" --arg ts "$now_ts" \
      --arg mode "$( [ "$dry" = 1 ] && echo dry-run || echo merge)" \
      '{into:$into,target_before:$before,head_sha:$head,verdict:"conflict",conflicts:($files|split(" ")|map(select(.!=""))),mode:$mode,ts:$ts}')"
    _land_record "$rec_evf" "$land_json"
    local hwhy="merge conflict with $into: ${conf:-unknown files}; rebase the task branch or retry"
    if [ "$mode" = task ] && [ "$dry" = 0 ]; then
      _land_error "$plan" "$tid" "$hwhy"
      type _task_event >/dev/null 2>&1 && _task_event "$plan" "$tid" land_conflict "${conf:-unknown files}" >/dev/null 2>&1
    elif [ "$mode" = job ] && [ "$dry" = 0 ]; then
      _land_wake "$label" "land $label: merge conflict with $into"
    fi
    if [ "$mode" = task ]; then
      die "land: not landed. ${branch:-$label} conflicts with $into in: ${conf:-unknown files}. Rebase the branch onto $into in $wt and commit, then run $retry_hint (flow reviews must approve the new revision first). $into is untouched."
    fi
    die "land: not landed. ${branch:-$label} conflicts with $into in: ${conf:-unknown files}. Bring the branch up to date with $into, then land again. $into is untouched."
  fi
  local merged; merged="$(git -C "$_LAND_IWT" rev-parse HEAD)"

  # ---- 4. Optional setup, then re-run the check on the MERGED result (a clean checkout) ----
  local srec="" src=0 ssecs stail=""
  if [ -n "$setup" ]; then
    ssecs="${OSRC_LAND_SETUP_TIMEOUT:-900}"; case "$ssecs" in ''|*[!0-9]*) ssecs=900 ;; esac
    echo "[land] running setup in the scratch checkout: $setup" >&2
    ( cd "$_LAND_IWT" 2>/dev/null && _loop_check "$ssecs" "$setup" "$out_dir/land-setup.out" ) </dev/null; src=$?
    stail="$(tail -n 20 "$out_dir/land-setup.out" 2>/dev/null | cut -c1-300 | head -c 4000)"
    srec="$(jq -cn --arg c "$setup" --argjson r "$src" --arg t "$stail" '{cmd:$c,rc:$r,tail:$t}')"
  fi
  _FG_CHECK_RC=""; _FG_SIG=""; _FG_TAIL=""
  local crc=0 cverdict="none"
  if [ "$(git -C "$_LAND_IWT" rev-parse HEAD 2>/dev/null)" != "$merged" ] || ! _crew_worktree_clean "$_LAND_IWT"; then
    cverdict=tree_changed
  elif [ -n "$setup" ] && [ "$src" != 0 ]; then
    cverdict="setup_failed"
  elif [ -n "$check" ]; then
    _factory_check_run "$_LAND_IWT" "$check" "$out_dir/land-check.out"; crc=$?
    if [ "$crc" = 0 ]; then cverdict="pass"; else cverdict="fail"; fi
  fi
  if [ "$(git -C "$_LAND_IWT" rev-parse HEAD 2>/dev/null)" != "$merged" ] || ! _crew_worktree_clean "$_LAND_IWT"; then
    cverdict=tree_changed
  fi
  now_ts="$(_fl_now)"
  local lmode; if [ "$dry" = 1 ]; then lmode="dry-run"; elif [ "$pr" = 1 ]; then lmode="pr"; else lmode="ff"; fi
  _land_json() { # <verdict> [pr_url]
    jq -cn --arg into "$into" --arg before "$before" --arg head "$head" --arg merged "$merged" \
      --arg cmd "$check" --arg rc "${_FG_CHECK_RC:-}" --arg sig "${_FG_SIG:-}" --arg tail "${_FG_TAIL:-}" \
      --arg verdict "$1" --arg pr "${2:-}" --arg mode "$lmode" --arg ts "$now_ts" --arg setup "$srec" \
      '{into:$into,target_before:$before,head_sha:$head,merged_sha:$merged,
        check:{cmd:$cmd,rc:(if $rc=="" then null else ($rc|tonumber) end),signature:$sig,tail:$tail},
        verdict:$verdict,mode:$mode,ts:$ts} + (if $pr=="" then {} else {pr_url:$pr} end)
        + (if $setup=="" then {} else {setup:($setup|fromjson)} end)'
  }
  if [ "$cverdict" = tree_changed ]; then
    _land_record "$rec_evf" "$(_land_json tree_changed)"
    [ "$mode" = task ] && [ "$dry" = 0 ] && _land_error "$plan" "$tid" "setup or check changed HEAD or tracked files"
    die "land: setup or check changed HEAD or tracked files in the merged result; $into is untouched. Fix the command, then run ${retry_hint:-land again}."
  fi
  if [ "$cverdict" = setup_failed ]; then
    _land_record "$rec_evf" "$(_land_json setup_failed)"
    [ "$mode" = task ] && [ "$dry" = 0 ] && _land_error "$plan" "$tid" "setup failed (exit $src)"
    [ "$mode" = job ] && [ "$dry" = 0 ] && _land_wake "$label" "land $label: the setup command failed"
    echo "[land] last lines of the setup:" >&2; printf '%s\n' "$stail" | tail -n 8 >&2
    die "land: not landed. The --setup command failed (exit $src) in the scratch checkout of the merged result: $setup. Fix the command (it runs in a clean checkout with no untracked files), then land again. $into is untouched; output in $out_dir/land-setup.out."
  fi
  if [ "$cverdict" = fail ]; then
    _land_record "$rec_evf" "$(_land_json check_failed)"
    local why="merge breaks check"
    case "$crc" in 124) why="merge breaks check (the check timed out)" ;; 125) why="merge breaks check (the check could not start)" ;; esac
    if [ "$mode" = task ] && [ "$dry" = 0 ]; then
      _land_error "$plan" "$tid" "$why"
      type _task_event >/dev/null 2>&1 && _task_event "$plan" "$tid" land_failed "$why" >/dev/null 2>&1
      _land_wake "$label" "land $label: $why on $into"
    elif [ "$mode" = job ] && [ "$dry" = 0 ]; then
      _land_wake "$label" "land $label: $why on $into"
    fi
    echo "[land] last lines of the check:" >&2; printf '%s\n' "${_FG_TAIL:-}" | tail -n 8 >&2
    local sh_hint=" If it fails only because something is missing there (node_modules, .venv, build output), add --setup \"<install command>\"."
    [ -n "$setup" ] && sh_hint=""
    die "land: not landed. After merging into $into the check fails (exit $crc): $check. The check runs in a clean checkout of the merged result, with none of the untracked files from the worker's worktree.$sh_hint $into is untouched; details in $out_dir/land-check.out. Fix the check, then run ${retry_hint:-land again}."
  fi
  local cnote="the check passed on the merged result"; [ "$cverdict" = none ] && cnote="no check set, merged result not re-verified"

  # ---- 5a. Dry run: stop before anything moves ----
  if [ "$dry" = 1 ]; then
    _land_record "$rec_evf" "$(_land_json dry_run_ok)"
    echo "dry run: $label would land on $into as ${merged:0:12} (merge of ${head:0:12}); $cnote. Nothing was moved and the task was not changed (dry-run outputs: $out_dir)."
    return 0
  fi

  # ---- 5b. --pr: push the verified head to its branch and open a PR (explicit opt-in only) ----
  if [ "$pr" = 1 ]; then
    have gh || die "land --pr needs the GitHub CLI (gh); install it, or land without --pr"
    [ -n "$branch" ] || die "land --pr: no branch name is on record to push"
    git -C "$root" remote get-url origin >/dev/null 2>&1 || die "land --pr: this repo has no 'origin' remote to push to"
    [ "$mode" = task ] && _land_assert_current "$plan" "$tid" "$force" "$head"
    git -C "$root" push -q origin "$head:refs/heads/$branch" >/dev/null 2>&1 \
      || die "land --pr: could not push $branch to origin; check your access, then run land --pr again"
    local body url
    body="$(printf 'Landed by outsourcerer.\n\n- work: %s\n- head: %s\n- %s (merged against %s at %s)\n' "$label" "$head" "$cnote" "$into" "${before:0:12}")"
    [ "$mode" = task ] && _land_assert_current "$plan" "$tid" "$force" "$head"
    url="$(cd "$root" && gh pr create --base "$into" --head "$branch" --title "$msg" --body "$body" 2>&1)" \
      || die "land --pr: gh could not open the pull request: $(printf '%s' "$url" | tail -1)"
    url="$(printf '%s\n' "$url" | grep -Eo 'https?://[^[:space:]]+' | tail -1)"
    _land_record "$evf" "$(_land_json pr_opened "$url")"
    if [ "$mode" = task ]; then
      _task_update "$plan" "$tid" \
        'if ([.attempt_token // "", .job // "", .worktree // "", .branch // "", .base_sha // "", .attempts // 0] == $owner)
         then .pr=$u | del(.land_error, .land_error_at) else error("attempt changed") end' \
        --argjson owner "$_LAND_ATTEMPT" --arg u "$url" >/dev/null 2>&1 || true
      type _task_event >/dev/null 2>&1 && _task_event "$plan" "$tid" pr_opened "$url" >/dev/null 2>&1
    fi
    echo "opened a pull request for $label into $into: ${url:-?} ($cnote). $into was not moved."
    return 0
  fi

  # ---- 5c. Fast-forward the target, never clobbering a checkout ----
  # Last look before anything moves: the task's state, the target's tip, and any rebase/bisect.
  if [ "$mode" = task ]; then
    _land_assert_current "$plan" "$tid" "$force" "$head"
  fi
  local now_tip; now_tip="$(git -C "$root" rev-parse "refs/heads/$into")"
  [ "$now_tip" = "$before" ] || die "land: $into moved while landing (now ${now_tip:0:12}); nothing was changed, run land again"
  busy="$(_land_branch_busy "$root" "$into")"
  [ -z "$busy" ] || die "land: $into is in the middle of $busy. Finish or abort it there (git rebase --continue/--abort, or git bisect reset), then run land again. Nothing was changed."
  co="$(_land_checkout_of "$root" "$into")"
  intent="$(_fl_jq -cn --arg t "$into" --arg h "$head" --arg m "$merged" --arg ts "$(_fl_now)" \
    '{target:$t,verified_head:$h,merged_sha:$m,ts:$ts}')"
  if [ "$mode" = task ]; then
    _task_update "$plan" "$tid" \
      "if $_LAND_OK_JQ and ([.attempt_token // \"\", .job // \"\", .worktree // \"\", .branch // \"\", .base_sha // \"\", .attempts // 0] == \$owner)
       then .land_intent=\$receipt else error(\"task changed\") end" \
      --argjson owner "$_LAND_ATTEMPT" --argjson receipt "$intent" --arg force "$force" >/dev/null \
      || die "land: could not persist landing receipt; $into is untouched"
  else
    _fl_write_json "$evf" "$(_fl_jq --argjson receipt "$intent" '.land_intent=$receipt' "$evf")" \
      || die "land: could not persist landing receipt; $into is untouched"
  fi
  [ "$mode" = task ] && _land_assert_current "$plan" "$tid" "$force" "$head"
  if [ -z "$co" ]; then
    git -C "$root" update-ref -m "$msg" "refs/heads/$into" "$merged" "$before" >/dev/null 2>&1 \
      || die "land: could not move $into (it changed underneath us); nothing was changed, run land again"
  else
    _crew_worktree_clean "$co" || die "land: $into is checked out at $co with uncommitted changes; commit or stash them there, then run land again (nothing was changed)"
    [ "$(git -C "$co" rev-parse HEAD 2>/dev/null)" = "$before" ] || die "land: the checkout of $into at $co is not at the expected commit; nothing was changed, run land again"
    coll="$(_land_untracked_collisions "$co" "$before" "$merged")"
    [ -z "$coll" ] || die "land: not landing $label. The merged result adds files that already exist, untracked or git-ignored, in your checkout of $into at $co: $(printf '%s' "$coll" | tr '\n' ' ')- landing would overwrite them. Move or back them up, then run land again. Nothing was changed."
    local -a ffo=(--ff-only -q)
    git merge -h 2>&1 | grep -q -- 'overwrite-ignore' && ffo+=(--no-overwrite-ignore)
    git -C "$co" -c "core.hooksPath=$nohooks" merge "${ffo[@]}" "$merged" >/dev/null 2>&1 \
      || die "land: could not fast-forward $into in $co (an untracked file there may be in the way); nothing was changed"
  fi
  [ "$(git -C "$root" rev-parse "refs/heads/$into")" = "$merged" ] || die "land: $into did not end up at the merged commit; check it by hand"
  _land_record "$evf" "$(_land_json landed)"
  if [ "$mode" = task ]; then
    # The code IS on the target now, so landed is always recorded; the state only moves to done
    # from a state land may finish (a hold/cancel that slipped in after the last look is kept).
    _task_update "$plan" "$tid" ".landed=true | .landed_sha=\$m | .landed_into=\$i | .evidence=\$e | del(.land_error, .land_error_at) | (if $_LAND_OK_JQ then .state=\"done\" else . end)" \
      --arg m "$merged" --arg i "$into" --arg e "$evf" --arg force "$force" >/dev/null 2>&1 || true
    type _task_event >/dev/null 2>&1 && _task_event "$plan" "$tid" landed "$into at ${merged:0:12}" >/dev/null 2>&1
    local fst; fst="$(_task_get "$plan" "$tid" 2>/dev/null | _fl_jq -r '.state // ""')"
    [ "$fst" = done ] || echo "[land] note: $tid became $fst while landing; its code is on $into now, so it is marked landed but its state was left as $fst." >&2
  fi
  echo "landed $label on $into at ${merged:0:12} (merge of ${head:0:12}); $cnote."
  return 0
}

# _land_record <evidence.json> <land-json> -> merge {land: ...} into the evidence file (atomic).
_land_record() {
  local evf="$1" cur="{}"
  [ -s "$evf" ] && cur="$(cat "$evf" 2>/dev/null)"
  printf '%s' "$cur" | jq -e . >/dev/null 2>&1 || cur="{}"
  _fl_write_json "$evf" "$(jq -cn --argjson c "$cur" --argjson l "$2" '$c + {land:$l}')" \
    || { echo "warning: could not record the land result in $evf" >&2; return 1; }
}
