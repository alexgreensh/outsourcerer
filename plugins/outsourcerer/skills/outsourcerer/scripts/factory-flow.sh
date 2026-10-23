# factory-flow.sh -- Outsourcerer software factory, Track D: the scheduler (`plan run`) and
# flows (`flow ls|show|run`). Sourced by outsourcerer.sh near the end of its definitions; it
# defines functions only and runs nothing at source time.
#
# Depends on (never re-implements):
#   Track B (factory-tasks.sh): _plan_dir _plan_resolve _task_get _task_update _task_list
#                               _task_view _task_ready _task_dispatch _task_event _task_new
#                               (_plan_cli_new, _task_finish_from_output, _task_stop_job when present)
#   Wakes: the task store already sends a wake whenever a task turns held or failed, so this file
#   only adds "plan finished" and "auto-land failed" wakes (never a second one for held/failed).
#   Track C (factory-land.sh):  _factory_done_check cmd_land
#   Track A (optional):         _model_excluded <model>  (rc0 = excluded)
#   Engine:                     die have cmd_wait _reconcile_status _wake_append _mkdir_claim
#                               _pid_start_identity
#
# Extra task fields this track reads or writes (the task store keeps unknown fields as-is):
#   hold_after_deps (bool)  -- a flow stage with "hold":true. Created as state todo; when its deps
#                              finish the scheduler flips it to held (decision for the captain) and
#                              clears the flag. Only the scheduler moves it; a worker never finishes it.
#   gate (bool)             -- a hold stage with no prompt: a pure decision. After `task release
#                              --answer`, the scheduler marks it done with the answer as its result
#                              (`task release --done` does the same by hand). A hold stage WITH a
#                              prompt is dispatched after release, with the answer in its brief.
#   land_target (tid)       -- a flow stage with "land":"<stage>". No worker runs: when ready, the
#                              scheduler lands the target task through `land` and records the outcome.
#                              land_attempts / land_started_at count and time those tries.
#   require_verdict (bool)  -- a flow stage with "verdict":true (a reviewer). The last content line
#                              before trailing OSRC completion metadata
#                              of its job's last.txt must be exactly `VERDICT: PASS` or
#                              `VERDICT: FAIL - <reason>`. FAIL sends the build it reviewed back for a
#                              redo (within that build's retries), then reviews again. No clear verdict
#                              holds it for the captain.
#   verdict_failed (object) -- {target, reason}: set on a reviewer held after a FAIL with no redo left.
#   fallback (array)        -- the stage's ordered model candidates (primary first). Re-picked at
#                              dispatch (an excluded model is skipped) and advanced on each retry.
#   prompt_orig (string)    -- the prompt before a review note was appended (so redos never pile up).
#   attempt_base (number)   -- attempts already used before a re-review started (its own budget restarts).
#   land_error (string)     -- an --auto-land that failed; the task stays done and the captain is told.
#   verifying_at/_pid/_start -- checker ownership; age or proven death permits takeover.
#   reviewed_head           -- the build commit this reviewer was dispatched to inspect.
#   auto_land_pending       -- durable intent recorded together with completion, replayed on restart.
#   claimed_at              -- (task store, when present) when the task was claimed for dispatch.
# bash 3.2 compatible: no associative arrays, no mapfile, no ${x,,}.

_FF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# Exit codes of `plan run`.
_FF_RC_BUSY=4

# ---------------------------------------------------------------- small helpers

_ff_need_jq() { have jq || die "the factory needs jq; install it (brew install jq, or apt install jq) and try again"; }
# Native Windows jq emits CRLF; preserve its exit status while normalizing output.
_ff_jq() ( set -o pipefail; jq "$@" | tr -d '\r' )
_ff_owner_dead() {
  local cur rc=0
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  cur="$(_pid_start_identity "$1" 2>/dev/null)" || rc=$?
  [ "$rc" = 2 ] && return 0
  [ "$rc" = 0 ] && [ -n "$2" ] && [ "$cur" != "$2" ] && return 0
  # Permission errors and unavailable process inspection cannot prove death.
  return 1
}
_ff_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_ff_name_ok() { case "${1:-}" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }
_ff_num() {
  local n="${1:-}"
  case "$n" in ''|*[!0-9]*) n="${2:-0}" ;; esac
  while [ "${#n}" -gt 1 ] && [ "${n#0}" != "$n" ]; do n="${n#0}"; done
  printf '%s' "$n"
}
_ff_need_fns() {   # <fn>... -> die naming the first missing piece of the factory
  local f
  for f in "$@"; do
    declare -F "$f" >/dev/null 2>&1 || die "this build is missing part of the factory ($f); reinstall outsourcerer or update it"
  done
}

# _ff_epoch <task-json> <jq-expr> -> seconds since epoch of a timestamp field (ISO-8601 Z or a number); 0 if unknown.
_ff_epoch() {
  printf '%s' "$1" | _ff_jq -r "($2) as \$x
    | if (\$x | type) == \"number\" then \$x
      elif (\$x | type) == \"string\" and (\$x | test(\"^[0-9]+\$\")) then (\$x | tonumber)
      elif (\$x | type) == \"string\" and \$x != \"\" then (\$x | try fromdateiso8601 catch 0)
      else 0 end | floor" 2>/dev/null || echo 0
}

# _ff_wake <plan> <tid|-> <kind> <summary>: queue a wake event for the heartbeat. Best-effort: a
# full or locked wake queue never stops the scheduler. Event ids stay inside the queue's charset.
_ff_wake() {
  local plan="$1" tid="$2" kind="$3" summary="$4" id
  declare -F _wake_append >/dev/null 2>&1 || return 0
  id="factory.$(printf '%s' "$plan" | tr -c 'A-Za-z0-9._-' '_').$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_').$kind.$(date +%s).$$"
  _wake_append "$(_ff_jq -cn --arg event_id "$id" --arg kind "factory-$kind" --arg plan "$plan" --arg task "$tid" \
      --arg s "$summary" '{event_id:$event_id,kind:$kind,state:"blocked",plan:$plan,task:$task,task_summary:$s}')" \
    >/dev/null 2>&1 || true
}

_ff_event() { declare -F _task_event >/dev/null 2>&1 && _task_event "$@" >/dev/null 2>&1; return 0; }

# The exact command a person types next, always with --plan so it works whatever plan is current.
_ff_cmd() { local plan="$1"; shift; printf 'outsourcerer %s --plan %s' "$*" "$plan"; }

# ---------------------------------------------------------------- deadline (--max-minutes)
_FF_DEADLINE=0
_ff_out_of_time() { [ "$_FF_DEADLINE" -gt 0 ] && [ "$(date +%s)" -ge "$_FF_DEADLINE" ]; }

# ---------------------------------------------------------------- run lock (one driver per plan)
# mkdir lock with a "pid start-identity" owner record, the house pattern. A lock whose owner is dead
# (or whose pid was recycled) is reclaimed, but only under a second "steal" lock and only if the
# owner record is still the one judged stale: a driver that was slow between reading the owner and
# removing the lock can never delete a fresh lock another driver just took.
_FF_LOCK=""
_FF_LOCK_HOLDER=""
_FF_LOCK_OWNER=""
_ff_lock_acquire() {   # <lockdir> -> 0 claimed | 1 held by a live driver (_FF_LOCK_HOLDER) | 2 cannot write
  local dir="$1" own="$1/owner" me ident opid oident tries=0 seen seen2 stale
  _factory_self_pid "${dir%/*}"; me="$_FACTORY_SELF_PID"
  while [ "$tries" -lt 5 ]; do
    tries=$((tries + 1))
    if _mkdir_claim "$dir"; then
      ident="$(_pid_start_identity "$me" 2>/dev/null)"
      if printf '%s %s\n' "$me" "$ident" > "$dir/.own.$me" 2>/dev/null && [ -s "$dir/.own.$me" ] \
         && mv -f "$dir/.own.$me" "$own" 2>/dev/null; then
        _FF_LOCK="$dir"; _FF_LOCK_OWNER="$me $ident"; return 0
      fi
      # Never hold a lock nobody can identify: a live driver with no owner record would look dead
      # to the next run, which would take the plan over while this one still drives it.
      rm -rf "$dir" 2>/dev/null
      _FF_LOCK_HOLDER="could not record this run as the lock owner in $dir (disk full or not writable?)"
      return 2
    fi
    seen="$(cat "$own" 2>/dev/null)"
    opid=""; oident=""
    [ -n "$seen" ] && read -r opid oident <<EOF
$seen
EOF
    stale=0
    if [ -n "$opid" ]; then
      if ! _ff_owner_dead "$opid" "$oident"; then
        _FF_LOCK_HOLDER="$opid"; return 1
      fi
      stale=1
    elif [ -n "$(find "$dir" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      stale=1   # ownerless for over a minute: the claimer died between mkdir and writing its owner
    else
      _FF_LOCK_HOLDER="unknown"; return 1
    fi
    [ "$stale" = 1 ] || continue
    # A steal guard left by a stealer that died is itself reclaimed after a minute.
    [ -n "$(find "$dir.steal" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$dir.steal" 2>/dev/null
    if _mkdir_claim "$dir.steal"; then
      seen2="$(cat "$own" 2>/dev/null)"
      if [ -d "$dir" ] && [ "$seen2" = "$seen" ]; then
        if mv "$dir" "$dir.dead.$me" 2>/dev/null; then
          if [ "$(cat "$dir.dead.$me/owner" 2>/dev/null)" = "$seen" ]; then
            rm -rf "$dir.dead.$me" 2>/dev/null
          else
            [ -e "$dir" ] || mv "$dir.dead.$me" "$dir" 2>/dev/null
          fi
        fi
      fi
      rmdir "$dir.steal" 2>/dev/null
    else
      sleep 0.2
    fi
  done
  _FF_LOCK_HOLDER="unknown"; return 1
}
_ff_lock_release() {
  local owner=""
  [ -n "$_FF_LOCK" ] || return 0
  owner="$(cat "$_FF_LOCK/owner" 2>/dev/null)"
  [ "$owner" = "$_FF_LOCK_OWNER" ] && rm -rf "$_FF_LOCK" 2>/dev/null
  _FF_LOCK=""
  return 0
}

# ---------------------------------------------------------------- scheduler: job outcome

# _ff_job_outcome <job>: sets _FF_OUT (ok|live|blocked|failed) and _FF_REASON. Reads job state the
# same way `wait` does (cmd_wait --for 0: done|done? = 0, blocked = 3, failure or dead orphan = 1,
# still live = 124), so the scheduler and `wait` can never disagree about a job. One exception: a
# job that never got a worker (no status, or launching/running with no process ever recorded) for
# longer than OSRC_FACTORY_JOB_STALE_SECS (default 900) counts as failed, so it can never wait forever.
_FF_OUT=""; _FF_REASON=""
_ff_job_outcome() {
  local job="$1" rc st r jd started age stale
  _FF_OUT=failed; _FF_REASON=""
  if [ -z "$job" ]; then _FF_REASON="no job was recorded for it"; return 0; fi
  jd="$OSRC_JOBS/$job"
  if [ ! -d "$jd" ]; then _FF_REASON="its job $job has no record on disk"; return 0; fi
  ( cmd_wait "$job" --for 0 ) >/dev/null 2>&1; rc=$?
  st="$(_reconcile_status "$job" 2>/dev/null || echo unknown)"
  r="$(head -1 "$jd/reason" 2>/dev/null | tr -d '\r' | cut -c1-160)"
  case "$rc" in
    0)   _FF_OUT=ok ;;
    124)
      _FF_OUT=live
      if [ ! -s "$jd/pid" ] && [ ! -s "$jd/supervisor_pid" ]; then
        case "$st" in ''|'?'|unknown|launching|running)
          started="$(cat "$jd/started_at" 2>/dev/null)"
          case "$started" in ''|*[!0-9]*) started="$(_mtime "$jd" 2>/dev/null)" ;; esac
          started="$(_ff_num "$started" 0)"
          stale="$(_ff_num "${OSRC_FACTORY_JOB_STALE_SECS:-900}" 900)"
          age=$(( $(date +%s) - started ))
          if [ "$started" -gt 0 ] && [ "$age" -ge "$stale" ]; then
            _FF_OUT=failed
            _FF_REASON="its job $job never got a worker (status '${st:-none}', no process after ${age}s)"
          fi ;;
        esac
      fi ;;
    3)   _FF_OUT=blocked; _FF_REASON="its worker is $st and needs input${r:+ ($r)}" ;;
    *)   _FF_OUT=failed; _FF_REASON="job $job ended $st${r:+ ($r)}" ;;
  esac
}

# _ff_find_job_by_ref <plan> <tid> <task-json> -> the unique unrecorded job for this attempt.
# Returns 2 for ambiguous receipts; a nested or older job must never win by filename order.
_ff_find_job_by_ref() {
  local plan="$1" tid="$2" t="$3" f j best="" tok linked count=0
  tok="$(printf '%s' "$t" | _ff_jq -r '.attempt_token // ""')"
  for f in "$OSRC_JOBS"/*/task_ref; do
    [ -f "$f" ] || continue
    linked="$(tr -d '\r\n' < "$f")"
    [ "$linked" = "$plan/$tid" ] || [ "$linked" = "$plan/$tid/$tok" ] || continue
    j="${f%/task_ref}"; j="${j##*/}"
    if [ -n "$tok" ] && [ "$linked" != "$plan/$tid/$tok" ]; then
      # factory-tasks.sh and the engine write the link as task_attempt; older names kept as fallbacks.
      linked="$(cat "$OSRC_JOBS/$j/task_attempt" 2>/dev/null | tr -d '\r\n')"
      [ -n "$linked" ] || linked="$(cat "$OSRC_JOBS/$j/task_attempt_token" 2>/dev/null | tr -d '\r\n')"
      [ -n "$linked" ] || linked="$(cat "$OSRC_JOBS/$j/attempt_token" 2>/dev/null | tr -d '\r\n')"
      [ "$linked" = "$tok" ] || continue
    fi
    printf '%s' "$t" | _ff_jq -e --arg j "$j" '(.jobs // []) | index($j) != null' >/dev/null 2>&1 && continue
    best="$j"; count=$((count + 1))
  done
  # Never guess between a parent and a nested job (including legacy tokenless receipts).
  [ "$count" -gt 1 ] && return 2
  [ "$count" = 1 ] && printf '%s' "$best"
  return 0
}

# A guard identifies the exact attempt and checker, even when a task returns to the same state.
_ff_guard() {
  printf '%s' "$1" | _ff_jq -r '
    [.state, (.job // ""), (.attempt_token // ""), (.verifying_token // ""),
     (.verifying_pid // ""), (.verifying_start // ""), (.verifying_at // "")]
    | "([.state, (.job // \"\"), (.attempt_token // \"\"), (.verifying_token // \"\"), (.verifying_pid // \"\"), (.verifying_start // \"\"), (.verifying_at // \"\")] == " + tojson + ")"'
}

_ff_review_target() {
  printf '%s' "$2" | _ff_jq -r --argjson deps "$(printf '%s' "$1" | _ff_jq -c '.deps // []')" '
    [.[] | select(.shape == "ship" and (.id as $id | $deps | index($id)) != null) | .id]
    | if length == 1 then .[0] else "" end'
}

# Recovery is idempotent and does not overwrite a cancellation or another external change.
# The plan lock makes both writes one transition to concurrent task commands. The journal
# makes an interrupted transition finish before the scheduler can launch either task.
_ff_pair_recover() {
  local plan="$1" pd data id old new cur
  pd="$(_plan_dir "$plan")"
  [ -f "$pd/review-transaction.json" ] || return 0
  data="$(cat "$pd/review-transaction.json")"
  printf '%s' "$data" | _ff_jq -e 'type == "array" and length == 2 and
    all(.[]; (.before.id == .after.id) and (.after.id | test("^t[1-9][0-9]*$")))' >/dev/null || return 1
  for id in $(printf '%s' "$data" | _ff_jq -r '.[].after.id'); do
    old="$(printf '%s' "$data" | _ff_jq -c --arg id "$id" '.[] | select(.after.id == $id) | .before')"
    new="$(printf '%s' "$data" | _ff_jq -c --arg id "$id" '.[] | select(.after.id == $id) | .after')"
    cur="$(_task_get "$plan" "$id")" || return 1
    if [ "$cur" = "$old" ]; then
      _factory_write_json "$pd/tasks/$id.json" "$new" || return 1
    elif [ "$cur" != "$new" ]; then
      # A captain acted after a crash. Never resurrect that task.
      _ff_event "$plan" "$id" review-recovery-skipped "task changed after interrupted review transition"
    fi
  done
  rm -f "$pd/review-transaction.json"
}

_ff_pair_commit() {
  local plan="$1" pd data
  shift
  pd="$(_plan_dir "$plan")"
  data="$(printf '%s\n' "$@" | _ff_jq -cs '[{before:.[0],after:.[1]},{before:.[2],after:.[3]}]')" || return 1
  _factory_write_json "$pd/review-transaction.json" "$data" || return 1
  _ff_pair_recover "$plan"
}

# ---------------------------------------------------------------- models (fallback re-pick)

_ff_excluded() { declare -F _model_excluded >/dev/null 2>&1 && _model_excluded "$1" >/dev/null 2>&1; }

# _ff_next_model <task-json> <dispatch|retry> -> the model to use. dispatch: keep the current one
# unless it is empty or now excluded. retry: move to the next allowed candidate after the current one
# (a failing model is not tried twice in a row while another is allowed). Empty = let the router pick.
_ff_next_model() {
  local t="$1" mode="$2" cur cands m n i idx=-1 k
  cur="$(printf '%s' "$t" | _ff_jq -r '.model // ""')"
  cands="$(printf '%s' "$t" | _ff_jq -r '(.fallback // []) | map(select(type == "string" and . != "")) | .[]')"
  if [ -z "$cands" ]; then
    # No stored fallbacks: an excluded model goes to the router (which honours the exclude list).
    if [ -n "$cur" ] && _ff_excluded "$cur"; then printf ''; else printf '%s' "$cur"; fi
    return 0
  fi
  if [ "$mode" = dispatch ] && [ -n "$cur" ] && ! _ff_excluded "$cur"; then printf '%s' "$cur"; return 0; fi
  set -f
  # shellcheck disable=SC2086
  set -- $cands
  set +f
  n=$#
  if [ -n "$cur" ]; then
    i=0; for m in "$@"; do [ "$m" = "$cur" ] && { idx=$i; break; }; i=$((i + 1)); done
  fi
  k=1
  while [ "$k" -le "$n" ]; do
    i=$(( (idx + k) % n )); [ "$i" -lt 0 ] && i=$((i + n))
    eval "m=\${$((i + 1))}"
    if ! _ff_excluded "$m"; then
      if [ "$mode" = dispatch ] || [ "$m" != "$cur" ] || [ "$n" -eq 1 ]; then printf '%s' "$m"; return 0; fi
    fi
    k=$((k + 1))
  done
  # Retry with no other allowed candidate: keep the current one if it is still allowed.
  if [ -n "$cur" ] && ! _ff_excluded "$cur"; then printf '%s' "$cur"; return 0; fi
  printf ''
}

# ---------------------------------------------------------------- scheduler: state changes

# _ff_attempts <task-json> -> attempts used in the current budget window.
_ff_attempts() {
  printf '%s' "$1" | _ff_jq -r '([(.attempts // 0), ((.jobs // []) | length)] | max) - (.attempt_base // 0) | if . < 0 then 0 else . end'
}

# _ff_fail_class <reason> -> why an attempt failed, which decides how the retry differs:
#   work       the done check said no (or nothing more specific is known): retry with the reason
#   transient  a launch, network or rate-limit problem: retry the same model, the task was never tried
#   model      the model, its plan or its lane failed (unknown model, empty answer, quota, auth, a
#              launch the lane refused): switch model
#   too_big    the run timed out, wedged, stalled or ran out of room: retry asking for a smaller piece
_ff_fail_class() {
  local r
  # Job ids carry digits (20261023-131700-a503b) that could look like an HTTP code, so drop them first.
  r="$(printf '%s' "$1" | sed -E 's/[0-9]{8}-[0-9]{6}-[0-9A-Za-z]+/JOB/g' | tr '[:upper:]' '[:lower:]')"
  case "$r" in
    "the done check said no"*) echo work; return ;;
  esac
  if printf '%s' "$r" | grep -Eq 'rate[ _-]?limit|too many requests|(^|[^0-9])(429|50[234])([^0-9]|$)|overloaded|network|connection (reset|refused|closed)|econn|temporar(il)?y unavailable|service unavailable'; then echo transient; return; fi
  if printf '%s' "$r" | grep -Eq 'context (length|window)|too long|max(imum)?[ _-]?tokens|token limit|output limit|truncat|wedged|timeout|timed out|(^|[^a-z])stall'; then echo too_big; return; fi
  if printf '%s' "$r" | grep -Eq 'model (not found|unavailable|is not|not supported|error)|unknown model|invalid model|unsupported model|empty (output|answer|response|result)|no output|quota|usage limit|plan limit|credits?|billing|unauthori[sz]ed|(^|[^0-9])40[13]([^0-9]|$)|did not launch|launch failure'; then echo model; return; fi
  if printf '%s' "$r" | grep -Eq 'never launched|never got a worker|no job was recorded|no record on disk|ended interrupted'; then echo transient; return; fi
  echo work
}

# _ff_fail_or_retry <plan> <tid> <reason> [guard-jq]: retry while attempts remain, putting the reason
# into the task so the next brief says why the last try failed; otherwise fail and call the captain.
# How it retries depends on _ff_fail_class: same model for a launch or network blip, the next model
# for a model or lane problem, a smaller piece for a run that was too big. The same model or too-big
# failure twice in a row is held for the captain to re-plan, since another identical try rarely helps.
# The guard (default: always) makes the change only if the task is still in the state this pass saw.
_ff_fail_or_retry() {
  local plan="$1" tid="$2" reason="$3" guard="${4:-true}" t n retries m cur cls prev note
  t="$(_task_get "$plan" "$tid")" || return 1
  n="$(_ff_num "$(_ff_attempts "$t")" 0)"
  retries="$(_ff_num "$(printf '%s' "$t" | _ff_jq -r '.retries // 0')" 0)"
  cls="$(_ff_fail_class "$reason")"
  prev="$(printf '%s' "$t" | _ff_jq -r '.last_fail_class // ""')"
  cur="$(printf '%s' "$t" | _ff_jq -r '.model // ""')"
  # Too big twice is held even on the last attempt: a re-plan beats a bare "failed". Model twice is
  # held only while retries remain; out of budget it fails as usual.
  if [ "$cls" = "$prev" ] && { [ "$cls" = too_big ] || { [ "$cls" = model ] && [ "$n" -le "$retries" ]; }; }; then
    case "$cls" in
      too_big) note="it failed twice for being too big to finish in one run ($reason). Split it into smaller tasks, or answer to try once more" ;;
      model)   note="two attempts in a row failed on a model or lane problem ($reason). Check that lane and its plan, or answer to try once more" ;;
    esac
    _task_update "$plan" "$tid" "if ($guard) | not then error(\"moved\") else .last_fail_class = \$c end" --arg c "$cls" >/dev/null 2>&1 || return 1
    _ff_hold "$plan" "$tid" "$note: $(_ff_cmd "$plan" task release "$tid" --answer '"<what to change>"')" "$guard" || return 1
    _ff_event "$plan" "$tid" retry "attempt $n failed ($cls, twice in a row): held for a re-plan"
    return 0
  fi
  if [ "$n" -le "$retries" ]; then
    case "$cls" in
      transient) m="$cur"
                 [ "$prev" = transient ] && m="$(_ff_next_model "$t" retry)"
                 note="previous attempt failed because $reason. That was a launch or network problem, not the work itself, so start the task fresh." ;;
      model)     m="$(_ff_next_model "$t" retry)"
                 note="previous attempt failed because $reason. That was a problem with the model or its lane, not the task." ;;
      too_big)   m="$cur"
                 note="previous attempt failed because $reason. The task was too big to finish in one run: this time do the smallest piece you can finish and verify, commit it, and list everything left under OPEN ITEMS in your final message." ;;
      *)         m="$(_ff_next_model "$t" retry)"
                 note="previous attempt failed because $reason" ;;
    esac
    # Same reset as `task retry`; .result carries the reason, which the next brief prints under
    # "Earlier attempt", so the next worker knows what went wrong.
    FACTORY_EVENT_NOTE="retry ($cls): $reason" _task_update "$plan" "$tid" \
      "if ($guard) | not then error(\"moved\") else . end
       | .state = \"todo\" | .job = \"\" | .worktree = \"\" | .branch = \"\" | .base_sha = \"\" | .head_sha = \"\" | .evidence = \"\"
       | del(.launch_failed, .auto_land_pending, .auto_land_complete) | del(.verifying_at) | del(.verifying_pid, .verifying_start, .verifying_token)
       | (if ((.fallback // []) | length) > 0 then .model = \$m else . end)
       | .last_fail_class = \$c | .result = \$note" \
      --arg note "$note" --arg m "$m" --arg c "$cls" >/dev/null 2>&1 || return 1
    _ff_event "$plan" "$tid" retry "attempt $n failed ($cls): $reason"
    printf '  %s: retrying%s (attempt %s failed, %s: %s)\n' "$tid" \
      "$( [ -n "$m" ] && [ "$m" != "$cur" ] && printf ' on %s' "$m")" "$n" "$(_ff_class_words "$cls")" "$reason"
  else
    FACTORY_EVENT_NOTE="failed: $reason" _task_update "$plan" "$tid" \
      "if ($guard) | not then error(\"moved\") else . end
       | .state = \"failed\" | .last_fail_class = \$c | .result = (\"failed after \" + \$n + \" attempt(s): \" + \$r)
       | del(.verifying_at) | del(.verifying_pid, .verifying_start, .verifying_token)
       | .hold = ((.hold // {}) + {reason: (\"failed after \" + \$n + \" attempt(s): \" + \$r + \". Run it again: \" + \$retry + \" (or cancel it: \" + \$cancel + \")\")})" \
      --arg r "$reason" --arg n "$n" --arg c "$cls" --arg retry "$(_ff_cmd "$plan" task retry "$tid")" --arg cancel "$(_ff_cmd "$plan" task cancel "$tid")" \
      >/dev/null 2>&1 || return 1
    printf '  %s: failed for good after %s attempt(s): %s. Next: %s\n' "$tid" "$n" "$reason" "$(_ff_cmd "$plan" task retry "$tid")"
  fi
}

_ff_class_words() {
  case "$1" in transient) echo "launch or network problem" ;; model) echo "model or lane problem" ;; too_big) echo "too big for one run" ;; *) echo "the work fell short" ;; esac
}

_ff_hold() {   # <plan> <tid> <reason> [guard-jq]   (the task store sends the wake)
  local plan="$1" tid="$2" reason="$3" guard="${4:-true}"
  FACTORY_EVENT_NOTE="$reason" _task_update "$plan" "$tid" \
    "if ($guard) | not then error(\"moved\") else . end
     | .state = \"held\" | .hold_after_deps = false | del(.verifying_at) | del(.verifying_pid, .verifying_start, .verifying_token)
     | .hold = ((.hold // {}) + {reason: \$r, answer: \"\", until: \"\", until_epoch: 0, default: \"\", defaulted: false})" \
    --arg r "$reason" >/dev/null 2>&1 || return 1
  printf '  %s: held for the captain: %s\n' "$tid" "$reason"
}

_ff_is_land_target() {   # <tasks-json> <tid> -> 0 when some flow land stage owns landing this task
  printf '%s' "$1" | _ff_jq -e --arg t "$2" 'any(.[]; (.land_target // "") == $t)' >/dev/null 2>&1
}

# ---------------------------------------------------------------- reviewer verdicts

# _ff_verdict <job> -> sets _FF_VERDICT (pass|fail|none|ambiguous) and _FF_VERDICT_LINE. Strict on
# purpose: only the job's last.txt (never out.log, which can echo the brief), only its last content
# line, and only the exact form `VERDICT: PASS` or `VERDICT: FAIL - <reason>`. Markup, quotes, a
# template echo ("VERDICT: PASS or VERDICT: FAIL"), or an earlier verdict that says the opposite
# all fail closed (held for the captain), so a worker cannot talk a reviewer into a PASS.
_FF_VERDICT=""; _FF_VERDICT_LINE=""
_ff_verdict() {
  local job="$1" f line re='^VERDICT: (PASS|FAIL)( - .*)?$' word rest
  _FF_VERDICT=none; _FF_VERDICT_LINE=""
  f="$OSRC_JOBS/$job/last.txt"
  [ -n "$job" ] && [ -s "$f" ] || return 0
  # Strip only trailing protocol metadata. Track Markdown fences before selecting a verdict.
  line="$(tr -d '\r' < "$f" | awk '
    { lines[NR] = $0 }
    END {
      n = NR
      while (n > 0 && (lines[n] ~ /^[[:space:]]*$/ || lines[n] ~ /^OSRC::(DONE|BLOCKED|PROGRESS)([#:[:space:]]|$)/ || lines[n] ~ /^>>> \[/)) n--
      fence = ""; width = 0
      for (i = 1; i <= n; i++) {
        s = lines[i]; sub(/^   ? ?/, "", s)
        if (s ~ /^```/ || s ~ /^~~~/) {
          ch = substr(s, 1, 1); run = 0
          while (substr(s, run + 1, 1) == ch) run++
          if (fence == "") { fence = ch; width = run }
          else if (ch == fence && run >= width && substr(s, run + 1) ~ /^[[:space:]]*$/) fence = ""
          if (i == n) exit
        }
      }
      if (fence == "") print lines[n]
    }')"
  _FF_VERDICT_LINE="$(printf '%s' "$line" | cut -c1-200)"
  [[ "$line" =~ $re ]] || return 0
  word="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
  if [ "$word" = PASS ]; then
    case "$rest" in *FAIL*) _FF_VERDICT=ambiguous; return 0 ;; esac
    # Any earlier verdict-looking line that says FAIL contradicts the final PASS.
    if tr -d '\r' < "$f" | grep -E '^[[:space:]>*#`_-]*VERDICT[[:space:]]*:' | grep -q 'FAIL'; then
      _FF_VERDICT=ambiguous; return 0
    fi
    _FF_VERDICT=pass
  else
    case "$rest" in *PASS*) _FF_VERDICT=ambiguous; return 0 ;; esac
    if tr -d '\r' < "$f" | grep -E '^[[:space:]>*#`_-]*VERDICT[[:space:]]*:' | grep -q 'PASS'; then
      _FF_VERDICT=ambiguous; return 0
    fi
    _FF_VERDICT=fail
  fi
}

# Shared with `task done`; the engine completion marker is not review content.
_factory_review_verdict() {
  local t job
  t="$(_task_get "$1" "$2")" || { echo AMBIGUOUS; return 2; }
  job="$(printf '%s' "$t" | _ff_jq -r '.job // ""')"
  _ff_verdict "$job"
  case "$_FF_VERDICT" in
    pass) echo PASS; return 0 ;;
    fail) echo FAIL; return 1 ;;
    *) echo AMBIGUOUS; return 2 ;;
  esac
}

# _ff_review_failed <plan> <reviewer-tid> <tasks-json>: the reviewer said FAIL. Send the build it
# reviewed back for a redo (with the reviewer's reason in its brief) and re-run the review after it,
# while the build still has retries left. Otherwise hold the reviewer with the exact commands.
# $1..$3 plus optional 4th arg "captain" = the captain asked for one more round (ignores the budget).
_ff_review_failed() (
  local plan="$1" vt="$2" tasks="$3" who="${4:-}" v r target n retries rstate landed br head out note vnote answer cmds pd
  _plan_lock "$plan" || return 1
  trap '_plan_unlock "$plan"' EXIT
  _ff_pair_recover "$plan" || return 1
  v="$(_task_get "$plan" "$vt")" || return 1
  local expected="${5:-$v}" guard nv nt
  guard="$(_ff_guard "$expected")"
  printf '%s' "$v" | _ff_jq -e "$guard" >/dev/null || return 1
  if [ "$who" = captain ]; then
    [ "$(printf '%s' "$v" | _ff_jq -r .state)" = todo ] || return 1
  else
    [ "$(printf '%s' "$v" | _ff_jq -r .state)" = verifying ] || return 1
  fi
  pd="$(_plan_dir "$plan")"
  # This pass's verdict line; the reason stored at the last hold only when the captain asks for a redo.
  if [ "$who" = captain ]; then r="$(printf '%s' "$v" | _ff_jq -r '.verdict_failed.reason // ""')"
  else r="${_FF_VERDICT_LINE#VERDICT: FAIL}"; r="${r# - }"; fi
  [ -n "$r" ] || r="no reason given"
  answer="$(printf '%s' "$v" | _ff_jq -r '.hold.answer // ""')"
  # The build under review: the reviewer's direct dependencies that are build (ship) tasks.
  target="$(printf '%s' "$tasks" | _ff_jq -r --argjson d "$(printf '%s' "$v" | _ff_jq -c '.deps // []')" \
    '[.[] | select((.id as $i | $d | index($i)) != null) | select((.shape // "") == "ship") | .id] | if length == 1 then .[0] else "" end')"
  out="$OSRC_JOBS/$(printf '%s' "$v" | _ff_jq -r '.job // ""')/last.txt"
  [ -f "$out" ] || out="$pd/tasks/$vt/report.md"
  cmds="Accept the build anyway: $(_ff_cmd "$plan" task done "$vt" --force). One more redo: $(_ff_cmd "$plan" task release "$vt" --answer '"<what to fix>"'). Stop here: $(_ff_cmd "$plan" task cancel "$vt")"
  if [ -z "$target" ]; then
    _task_update "$plan" "$vt" '.verdict_failed = {target: "", reason: $r} | .result = ("reviewer said FAIL: " + $r)' --arg r "$r" >/dev/null 2>&1
    _ff_hold "$plan" "$vt" "the reviewer said FAIL ($r) and there is no single build task to redo. Read the review: $out. $cmds" || return 1
    return 0
  fi
  local t; t="$(_task_get "$plan" "$target")" || return 1
  rstate="$(printf '%s' "$t" | _ff_jq -r '.state')"; landed="$(printf '%s' "$t" | _ff_jq -r '.landed // false')"
  n="$(_ff_num "$(_ff_attempts "$t")" 0)"; retries="$(_ff_num "$(printf '%s' "$t" | _ff_jq -r '.retries // 0')" 0)"
  if [ "$rstate" != done ] || [ "$landed" = true ] || { [ "$who" != captain ] && [ "$n" -gt "$retries" ]; }; then
    local why="its redo budget is used up ($n attempt(s))"
    [ "$rstate" != done ] && why="$target is $rstate, not done"
    [ "$landed" = true ] && why="$target has already landed"
    _task_update "$plan" "$vt" '.verdict_failed = {target: $t, reason: $r} | .result = ("reviewer said FAIL: " + $r)' \
      --arg t "$target" --arg r "$r" >/dev/null 2>&1
    _ff_hold "$plan" "$vt" "the reviewer said FAIL on $target ($r); $why. Read the review: $out. $cmds" || return 1
    return 0
  fi
  br="$(printf '%s' "$t" | _ff_jq -r '.branch // ""')"; head="$(printf '%s' "$t" | _ff_jq -r '.head_sha // ""')"
  note="A reviewer ($vt) did not pass your previous attempt: $r"
  [ -n "$answer" ] && note="$note
The captain adds: $answer"
  note="$note
Full review: $out"
  [ -n "$br" ] && note="$note
Your previous attempt is on branch $br${head:+ at commit $head}; you may start from it (for example: git merge $br) and fix what the reviewer found."
  # The build goes back in line with the review in its prompt (replaced, never piled up); its retries
  # budget counts this redo. The captain's extra round raises the budget by one so the count stays honest.
  nt="$(printf '%s' "$t" | _ff_jq -c \
    'if .state != "done" or (.landed // false) then error("moved") else . end
     | .prompt_orig = (.prompt_orig // .prompt)
     | .prompt = (.prompt_orig + "\n\n## Review of your previous attempt\n\n" + $note)
     | .state = "todo" | .job = "" | .worktree = "" | .branch = "" | .base_sha = "" | .head_sha = "" | .evidence = ""
     | .result = "" | del(.land_error) | (if $cap == "1" then .retries = ((.retries // 0) + 1) else . end)' \
    --arg note "$note" --arg cap "$( [ "$who" = captain ] && echo 1 || echo 0)")" || return 1
  vnote="You reviewed an earlier attempt of $target and failed it: $r
That build was redone. Review the new attempt from scratch, and check that this problem is fixed."
  nv="$(printf '%s' "$v" | _ff_jq -c \
    '.prompt_orig = (.prompt_orig // .prompt)
     | .prompt = (.prompt_orig + "\n\n## Earlier review\n\n" + $note)
     | .state = "todo" | .job = "" | .evidence = "" | .result = "" | del(.verdict_failed)
     | .hold = ((.hold // {}) + {answer: ""}) | del(.verifying_at) | del(.verifying_pid, .verifying_start, .verifying_token)
     | .attempt_base = ([(.attempts // 0), ((.jobs // []) | length)] | max)' \
    --arg note "$vnote")" || return 1
  _ff_pair_commit "$plan" "$t" "$nt" "$v" "$nv" || return 1
  _ff_event "$plan" "$vt" review-failed "redo $target: $r"
  printf '  %s: reviewer said FAIL (%s); %s goes back for a redo, then %s reviews again\n' "$vt" "$r" "$target" "$vt"
  _FF_MOVED=1
)

# ---------------------------------------------------------------- scheduler: verify + land

# _ff_verify <plan> <tid> <tasks-json>: the caller holds the verifying claim; the done contract decides.
_ff_verify() {
  local plan="$1" tid="$2" tasks="$3" out rc t shape ev pd job guard
  t="$(_task_get "$plan" "$tid")" || return 1
  guard="$(_ff_guard "$t")"
  local expected="$t"
  [ "$(printf '%s' "$t" | _ff_jq -r .state)" = verifying ] || return 1
  out="$( _factory_done_check "$plan" "$tid" 2>&1 )"; rc=$?
  out="$(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g; s/ $//' | cut -c1-200)"
  if [ "$rc" -ne 0 ]; then
    _ff_fail_or_retry "$plan" "$tid" "the done check said no: ${out:-no reason given}" "$guard"
    return 0
  fi
  t="$(_task_get "$plan" "$tid")" || return 1
  printf '%s' "$t" | _ff_jq -e "$guard" >/dev/null || return 0
  shape="$(printf '%s' "$t" | _ff_jq -r '.shape // "scout"')"
  pd="$(_plan_dir "$plan")"; ev=""; [ -f "$pd/tasks/$tid/evidence.json" ] && ev="$pd/tasks/$tid/evidence.json"
  if [ "$(printf '%s' "$t" | _ff_jq -r '.require_verdict // false')" = "true" ]; then
    job="$(printf '%s' "$t" | _ff_jq -r '.job // ""')"
    _ff_verdict "$job"
    case "$_FF_VERDICT" in
      pass)
        local target current reviewed
        target="$(_ff_review_target "$t" "$(_task_list "$plan")")"
        if [ -n "$target" ] && printf '%s' "$t" | _ff_jq -e 'has("reviewed_head")' >/dev/null; then
          current="$(_task_get "$plan" "$target" | _ff_jq -r '.head_sha // ""')"
          reviewed="$(printf '%s' "$t" | _ff_jq -r '.reviewed_head // ""')"
          if [ "$current" != "$reviewed" ]; then
            _task_update "$plan" "$tid" "if ($guard) then .state = \"todo\" | .job = \"\"
              | .result = \"build changed during review; review again\"
              | del(.verifying_at, .verifying_pid, .verifying_start, .verifying_token)
              | .attempt_base = ([(.attempts // 0), ((.jobs // []) | length)] | max) else error(\"moved\") end" >/dev/null 2>&1
            return 0
          fi
        fi ;;
      fail)
        _task_update "$plan" "$tid" "if ($guard) then .evidence = \$e else error(\"moved\") end" --arg e "$ev" >/dev/null 2>&1
        _ff_review_failed "$plan" "$tid" "$tasks" "" "$expected"
        return 0 ;;
      *)
        _task_update "$plan" "$tid" "if ($guard) then .evidence = \$e | .result = (\"no clear verdict: \" + \$v) else error(\"moved\") end" \
          --arg e "$ev" --arg v "${_FF_VERDICT_LINE:-(empty)}" >/dev/null 2>&1
        _ff_hold "$plan" "$tid" "the reviewer gave no clear verdict (its last line must be exactly 'VERDICT: PASS' or 'VERDICT: FAIL - <reason>'; it was: ${_FF_VERDICT_LINE:-empty}$( [ "$_FF_VERDICT" = ambiguous ] && echo ', and its answer says both')). Read it: $OSRC_JOBS/$job/last.txt. Accept: $(_ff_cmd "$plan" task done "$tid" --force). Review again: $(_ff_cmd "$plan" task release "$tid" --answer '"review again"')" "$guard"
        return 0 ;;
    esac
  fi
  _plan_lock "$plan" || return 1
  if ! _task_get "$plan" "$tid" | _ff_jq -e "$guard" >/dev/null; then _plan_unlock "$plan"; return 0; fi
  declare -F _task_finish_from_output >/dev/null 2>&1 && _task_finish_from_output "$plan" "$tid"
  FACTORY_EVENT_NOTE="$out" _task_update "$plan" "$tid" "if ($guard) | not then error(\"moved\") else . end
      | .state = \"done\" | del(.verifying_at, .verifying_pid, .verifying_start, .verifying_token)
      | (if \$e != \"\" then .evidence = \$e else . end)
      | .result = (if (.result // \"\") == \"\" or (.result | startswith(\"previous attempt failed\")) then \$o else .result end)
      | if \$pending then .auto_land_pending = true else . end" \
    --arg e "$ev" --arg o "$out" --argjson pending "$(
      if [ "$_FF_AUTO_LAND" = 1 ] && [ "$shape" = ship ] && [ -z "$(printf '%s' "$t" | _ff_jq -r '.flow.name // ""')" ] && ! _ff_is_land_target "$tasks" "$tid"; then echo true; else echo false; fi)" >/dev/null 2>&1
  rc=$?; _plan_unlock "$plan"
  [ "$rc" = 0 ] || return 0
  printf '  %s: done\n' "$tid"
  # --auto-land: only plain build tasks. A flow's build tasks are reviewed, compared or picked after
  # they finish, and the flow lands them itself through its own land stage (or the captain does).
  if [ "$_FF_AUTO_LAND" = 1 ] && [ "$shape" = ship ] \
     && [ -z "$(printf '%s' "$t" | _ff_jq -r '.flow.name // ""')" ] && ! _ff_is_land_target "$tasks" "$tid"; then
    if _ff_out_of_time; then
      printf '  %s: not landed: time cap reached; land it with: %s\n' "$tid" "$(_ff_cmd "$plan" land "$tid")"
      _task_update "$plan" "$tid" '.land_error = "not landed before the time cap"' >/dev/null 2>&1
      return 0
    fi
    _ff_auto_land "$plan" "$tid"
  fi
}

# _ff_land_setup <plan> <owner-tid> <target-tid> -> the --setup command for land: the land stage's own
# `setup`, else the build's, else `plan run --setup`. Empty = none.
_FF_SETUP=""
_ff_land_setup() {
  local s1 s2
  s1="$(_task_get "$1" "$2" 2>/dev/null | _ff_jq -r '.setup // ""' 2>/dev/null)"
  s2="$(_task_get "$1" "$3" 2>/dev/null | _ff_jq -r '.setup // ""' 2>/dev/null)"
  printf '%s' "${s1:-${s2:-$_FF_SETUP}}"
}
# _ff_run_land <plan> <target-tid> <setup>: cmd_land, passing --setup only when given and supported.
_ff_run_land() {
  if [ -n "$3" ] && { declare -f _land_run 2>/dev/null; declare -f _land_usage 2>/dev/null; } | grep -q -- '--setup'; then
    cmd_land "$2" --plan "$1" --setup "$3"
  else
    cmd_land "$2" --plan "$1"
  fi
}

# _ff_auto_land <plan> <tid>: land a done build. A failed land never undoes the build: the task stays
# done, the failure is recorded in .land_error, and the captain gets a wake with the exact command.
_ff_auto_land() {
  local plan="$1" tid="$2" out rc st
  declare -F cmd_land >/dev/null 2>&1 || { printf '  %s: landing is not available in this build; update, then: %s\n' "$tid" "$(_ff_cmd "$plan" land "$tid")"; return 1; }
  out="$( _ff_run_land "$plan" "$tid" "$(_ff_land_setup "$plan" "$tid" "$tid")" 2>&1 )"; rc=$?
  out="$(printf '%s' "$out" | tail -3 | tr '\n' ' ' | sed 's/^ERROR: //' | cut -c1-200)"
  if [ "$rc" -eq 0 ]; then
    _task_update "$plan" "$tid" 'del(.land_error, .land_error_at, .auto_land_pending) | .auto_land_complete = true' >/dev/null 2>&1
    printf '  %s: landed\n' "$tid"; return 0
  fi
  st="$(_task_get "$plan" "$tid" | _ff_jq -r '.state')"
  _task_update "$plan" "$tid" '.land_error = $o | .land_error_at = $now | .auto_land_pending = false' --arg o "$out" --argjson now "$(date +%s)" >/dev/null 2>&1
  [ "$st" = done ] && _ff_wake "$plan" "$tid" land-failed "plan $plan: landing $tid failed: $out. Fix it, then: $(_ff_cmd "$plan" land "$tid")"
  printf '  %s: landing failed (the build stays %s): %s. Next: %s\n' "$tid" "$st" "$out" "$(_ff_cmd "$plan" land "$tid")"
}

# _ff_land_stage <plan> <stage-tid> <target-tid>: a flow land stage. Claimed todo->running with an
# attempt count; success -> done; failure -> held with the exact commands (never an endless relaunch).
_ff_land_stage() {
  local plan="$1" lt="$2" target="$3" out rc tst
  FACTORY_EVENT_NOTE="landing $target" _task_update "$plan" "$lt" \
    'if .state != "todo" then error("moved") else . end
     | .state = "running" | .land_attempts = ((.land_attempts // 0) + 1) | .land_started_at = $now' \
    --arg now "$(_ff_now)" >/dev/null 2>&1 || return 0
  if ! declare -F cmd_land >/dev/null 2>&1; then
    _ff_hold "$plan" "$lt" "landing is not available in this build; update, run $(_ff_cmd "$plan" land "$target"), then: $(_ff_cmd "$plan" task done "$lt" --force)"
    return 0
  fi
  out="$( _ff_run_land "$plan" "$target" "$(_ff_land_setup "$plan" "$lt" "$target")" 2>&1 )"; rc=$?
  out="$(printf '%s' "$out" | tail -3 | tr '\n' ' ' | sed 's/^ERROR: //' | cut -c1-200)"
  # A land step is done only when its target really merged, or when the target asked for branch/pr delivery.
  if [ "$rc" -eq 0 ] && ! _task_get "$plan" "$target" | _ff_jq -e '(.landed // false) or ((.deliver // "local") != "local")' >/dev/null 2>&1; then
    rc=1; out="land finished but $target is not recorded as landed: $out"
  fi
  if [ "$rc" -eq 0 ]; then
    _task_update "$plan" "$lt" 'if .state != "running" then error("moved") else . end | .state = "done" | .result = ("landed " + $t + ": " + $o)' \
      --arg t "$target" --arg o "$out" >/dev/null 2>&1
    printf '  %s: landed %s\n' "$lt" "$target"
    _FF_MOVED=1
    return 0
  fi
  tst="$(_task_get "$plan" "$target" | _ff_jq -r '.state')"
  local recovery=""
  if [ "$tst" = held ]; then
    recovery="Resolve the build first: $(_ff_cmd "$plan" task release "$target" --answer '"<resolve conflict>"'), then run outsourcerer plan run $plan to rebuild and re-review. "
  fi
  _ff_hold "$plan" "$lt" "${recovery}landing $target failed: $out ($target is $tst). Fix it, then land again: $(_ff_cmd "$plan" task release "$lt" --answer '"land again"'). Or land it by hand ($(_ff_cmd "$plan" land "$target")) and close this step: $(_ff_cmd "$plan" task done "$lt" --force)" \
    '.state == "running"'
}

# _ff_land_stage_recover <plan> <stage-tid> <task-json>: a land stage found running at the start of a
# pass means a previous driver stopped mid-land. Done if the target landed, else relaunch within its
# attempts, else hold.
_ff_land_stage_recover() {
  local plan="$1" lt="$2" t="$3" target tt n max
  target="$(printf '%s' "$t" | _ff_jq -r '.land_target')"
  tt="$(_task_get "$plan" "$target" 2>/dev/null)"
  if [ "$(printf '%s' "$tt" | _ff_jq -r '.landed // false' 2>/dev/null)" = true ]; then
    _task_update "$plan" "$lt" 'if .state != "running" then error("moved") else . end | .state = "done" | .result = ("landed " + $t)' \
      --arg t "$target" >/dev/null 2>&1 && printf '  %s: %s had already landed\n' "$lt" "$target"
    _FF_MOVED=1
    return 0
  fi
  n="$(_ff_num "$(printf '%s' "$t" | _ff_jq -r '.land_attempts // 0')" 0)"
  max=$(( $(_ff_num "$(printf '%s' "$t" | _ff_jq -r '.retries // 1')" 1) + 1 ))
  if [ "$n" -lt "$max" ]; then
    FACTORY_EVENT_NOTE="land interrupted; trying again" _task_update "$plan" "$lt" \
      'if .state != "running" then error("moved") else . end | .state = "todo"' >/dev/null 2>&1 \
      && printf '  %s: an earlier land of %s was interrupted; trying again\n' "$lt" "$target"
  else
    _ff_hold "$plan" "$lt" "landing $target was interrupted $n time(s). Check $target, then land again: $(_ff_cmd "$plan" task release "$lt" --answer '"land again"')" \
      '.state == "running"'
  fi
}

# ---------------------------------------------------------------- scheduler: reconcile

# _ff_apply_defaults <plan>: a held decision with a default answer and a deadline that has passed is
# released with that default, exactly as if the captain had answered it, so an unattended plan does
# not stall overnight on a question that already had a sensible answer. Guarded per task.
# _ff_next_default <plan> -> "<epoch> <tid>" for the held decision whose default fires soonest, or
# nothing when no held task has a default waiting.
_ff_next_default() {
  _task_list "$1" | _ff_jq -r '[.[] | select(.state == "held" and ((.hold.default // "") | test("\\S"))
      and ((.hold.until_epoch // 0) | type == "number") and (.hold.until_epoch // 0) > 0)]
    | sort_by(.hold.until_epoch) | first // empty | "\(.hold.until_epoch | floor) \(.id)"' 2>/dev/null
}

_ff_apply_defaults() {
  local plan="$1" tid now d
  now="$(date +%s)"
  for tid in $(_task_list "$plan" | _ff_jq -r --argjson now "$now" '.[]
      | select(.state == "held" and ((.hold.default // "") | test("\\S")) and ((.hold.until_epoch // 0) | type == "number")
               and (.hold.until_epoch // 0) > 0 and (.hold.until_epoch // 0) <= $now) | .id'); do
    d="$(_task_get "$plan" "$tid" | _ff_jq -r '.hold.default // ""')"
    FACTORY_EVENT_NOTE="no answer by the deadline; used the default: $d" _task_update "$plan" "$tid" \
      'if .state != "held" or ((.hold.until_epoch // 0) > $now) or (.hold.until_epoch // 0) <= 0 or (.hold.default // "") == "" then error("moved")
       else .state = "todo" | .hold.answer = .hold.default | .hold.defaulted = true | .hold.until_epoch = 0 end' \
      --argjson now "$now" >/dev/null 2>&1 || continue
    printf '  %s: nobody answered by the deadline, so it goes ahead with the default: %s\n' "$tid" "$d"
  done
}

_ff_reconcile() {   # <plan>
  local plan="$1" tasks tid t st job grace age now vstale vpid j tok guard me ident vtoken old target head reviewed receipt w br base rc
  _plan_lock "$plan" || return 1
  if [ -f "$(_plan_dir "$plan")/flow-expansion.json" ]; then
    echo "plan $plan has an incomplete flow expansion; rerun outsourcerer flow run $(_ff_jq -r .flow "$(_plan_dir "$plan")/flow-expansion.json") --plan $plan with the original variables to replace it" >&2
    _plan_unlock "$plan"; return 1
  fi
  _ff_pair_recover "$plan" || { _plan_unlock "$plan"; return 1; }
  _plan_unlock "$plan"
  _ff_apply_defaults "$plan"
  tasks="$(_task_list "$plan")" || return 1
  # Invalidate an approval before any dependent land step is dispatched.
  for tid in $(printf '%s' "$tasks" | _ff_jq -r '.[] | select(.state == "done" and .require_verdict == true and has("reviewed_head")) | .id'); do
    t="$(_task_get "$plan" "$tid")" || continue
    target="$(_ff_review_target "$t" "$tasks")"; [ -n "$target" ] || continue
    head="$(_task_get "$plan" "$target" | _ff_jq -r '.head_sha // ""')"
    reviewed="$(printf '%s' "$t" | _ff_jq -r '.reviewed_head // ""')"
    if [ "$reviewed" != "$head" ]; then
      guard="$(_ff_guard "$t")"
      _task_update "$plan" "$tid" "if ($guard) then .state = \"todo\" | .job = \"\" | .evidence = \"\" | .result = \"build revision changed; review again\"
        | .attempt_base = ([(.attempts // 0), ((.jobs // []) | length)] | max) else error(\"moved\") end" >/dev/null 2>&1
    fi
  done
  tasks="$(_task_list "$plan")" || return 1
  _factory_self_pid "$(_plan_dir "$plan")"; me="$_FACTORY_SELF_PID"
  ident="$(_pid_start_identity "$me" 2>/dev/null)"
  grace="$(_ff_num "${OSRC_FACTORY_LAUNCH_GRACE:-300}" 300)"
  vstale="$(_ff_num "${OSRC_FACTORY_VERIFY_STALE_SECS:-900}" 900)"
  for tid in $(printf '%s' "$tasks" | _ff_jq -r '.[] | select(.state == "running" or .state == "verifying" or .state == "failed" or .state == "done") | .id'); do
    _ff_out_of_time && return 0
    t="$(_task_get "$plan" "$tid")" || continue
    st="$(printf '%s' "$t" | _ff_jq -r '.state')"
    job="$(printf '%s' "$t" | _ff_jq -r '.job // ""')"
    tok="$(printf '%s' "$t" | _ff_jq -r '.attempt_token // ""')"
    guard="$(_ff_guard "$t")"
    # A captain's decision or a land step is moved only by the scheduler, never by a worker's output.
    if [ -n "$job" ] && printf '%s' "$t" | _ff_jq -e '(.gate // false) or ((.land_target // "") != "") or (.hold_after_deps // false)' >/dev/null 2>&1; then
      declare -F _task_stop_job >/dev/null 2>&1 && _task_stop_job "$job" >/dev/null 2>&1
      _ff_hold "$plan" "$tid" "a worker was started by hand on this $(printf '%s' "$t" | _ff_jq -r 'if (.land_target // "") != "" then "land step" else "decision step" end'); its output does not count. Decide: $(_ff_cmd "$plan" task release "$tid" --answer '"<your decision>"')" \
        "(.state == \"running\" or .state == \"verifying\") and (.job // \"\") == \"$job\""
      continue
    fi
    case "$st" in
      done)
        if printf '%s' "$t" | _ff_jq -e '.auto_land_pending == true and ((.landed // false) | not)' >/dev/null; then
          _ff_auto_land "$plan" "$tid"
        elif [ "$_FF_AUTO_LAND" = 1 ] && ! _ff_is_land_target "$tasks" "$tid" && printf '%s' "$t" | _ff_jq -e '
          .shape == "ship" and (.flow.name // "") == "" and ((.landed // false) | not)
          and (.land_error // "") == "" and (.pr // "") == "" and ((.auto_land_pending // false) | not)
          and (.deliver // "local") == "local" and ((.auto_land_complete // false) | not)' >/dev/null; then
          _task_update "$plan" "$tid" "if ($guard) then .auto_land_pending = true else error(\"moved\") end" >/dev/null 2>&1 && _ff_auto_land "$plan" "$tid"
        fi ;;
      failed)
        if printf '%s' "$t" | _ff_jq -e '.launch_failed == true' >/dev/null && [ "$(_ff_attempts "$t")" -le "$(printf '%s' "$t" | _ff_jq -r '.retries // 0')" ]; then
          _ff_fail_or_retry "$plan" "$tid" "persisted launch failure: $(printf '%s' "$t" | _ff_jq -r '.result // ""')" "$guard"
        fi ;;
      running)
        if [ -z "$job" ]; then
          if [ -n "$(printf '%s' "$t" | _ff_jq -r '.land_target // ""')" ]; then
            _ff_land_stage_recover "$plan" "$tid" "$t"; continue
          fi
          # Claimed but no job yet: a launch is in flight (it takes seconds) unless the claim is old.
          now="$(date +%s)"
          age=$(( now - $(_ff_num "$(_ff_epoch "$t" '.claimed_at // .updated')" 0) ))
          if [ "$age" -lt "$grace" ]; then
            printf '  %s: still launching (claimed %ss ago)\n' "$tid" "$age"; continue
          fi
          j="$(_ff_find_job_by_ref "$plan" "$tid" "$t")"; rc=$?
          if [ "$rc" = 2 ]; then
            _ff_hold "$plan" "$tid" "multiple jobs match this attempt; inspect them before retrying: $(_ff_cmd "$plan" task show "$tid")" "$guard"
            continue
          fi
          if [ -n "$j" ]; then
            receipt="{}"
            [ ! -f "$OSRC_JOBS/$j/meta.json" ] || receipt="$(_ff_jq -c . "$OSRC_JOBS/$j/meta.json" 2>/dev/null)"
            if [ -f "$OSRC_JOBS/$j/worktree.json" ]; then
              receipt="$(_ff_jq -c . "$OSRC_JOBS/$j/worktree.json" 2>/dev/null)"
            fi
            [ -n "$receipt" ] || receipt="{}"
            w="$(printf '%s' "$receipt" | _ff_jq -r '.path // .worktree // ""')"
            br="$(printf '%s' "$receipt" | _ff_jq -r '.branch // ""')"
            base="$(printf '%s' "$receipt" | _ff_jq -r '.base_sha // ""')"
            FACTORY_EVENT_NOTE="recovered job $j" _task_update "$plan" "$tid" \
              "if ($guard) | not then error(\"moved\") else . end | .job = \$j | .jobs = ((.jobs // []) + [\$j])
               | .worktree = (if \$w != \"\" then \$w else (.worktree // \"\") end)
               | .branch = (if \$b != \"\" then \$b else (.branch // \"\") end)
               | .base_sha = (if \$s != \"\" then \$s else (.base_sha // \"\") end) | .claimed_by = \"\"" \
              --arg j "$j" --arg w "$w" --arg b "$br" --arg s "$base" >/dev/null 2>&1 || continue
            printf '  %s: found its job %s (its launcher stopped before recording it)\n' "$tid" "$j"
            job="$j"; t="$(_task_get "$plan" "$tid")"; guard="$(_ff_guard "$t")"
          else
            _ff_fail_or_retry "$plan" "$tid" "its worker never launched (no job ${age}s after it was claimed)" \
              "$guard"
            continue
          fi
        fi
        _ff_job_outcome "$job"
        case "$_FF_OUT" in
          live)    ;;
          ok)
            # Verifying claim: only the pass that moves running -> verifying runs the done check, so a
            # concurrent `task done` (or a second driver) never checks or lands the same work twice.
            vtoken="$(date +%s)-$me-$RANDOM"
            _task_update "$plan" "$tid" "if ($guard) | not then error(\"moved\") else . end
                | .state = \"verifying\" | .verifying_at = \$now | .verifying_pid = \$pid | .verifying_start = \$start | .verifying_token = \$token" \
              --argjson now "$(date +%s)" --arg pid "$me" --arg start "$ident" --arg token "$vtoken" >/dev/null 2>&1 || continue
            _ff_verify "$plan" "$tid" "$tasks" ;;
          blocked) _ff_hold "$plan" "$tid" "$_FF_REASON. Answer it: $(_ff_cmd "$plan" task release "$tid" --answer '"<your answer>"') (a new worker starts with your answer)" \
                     "$guard" ;;
          *)       _ff_fail_or_retry "$plan" "$tid" "$_FF_REASON" "$guard" ;;
        esac ;;
      verifying)
        # Someone is checking it (a `task done`, or this driver's previous run that stopped mid-check).
        # Take it over only when that checker is gone or the claim is stale.
        vpid="$(printf '%s' "$t" | _ff_jq -r '.verifying_pid // ""')"
        old="$(printf '%s' "$t" | _ff_jq -r '.verifying_start // ""')"
        age=$(( $(date +%s) - $(_ff_num "$(_ff_epoch "$t" '.verifying_at // .updated')" 0) ))
        if [ "$age" -lt "$vstale" ] && ! _ff_owner_dead "$vpid" "$old"; then continue; fi
        vtoken="$(date +%s)-$me-$RANDOM"
        _task_update "$plan" "$tid" "if ($guard) | not then error(\"moved\") else . end
            | .verifying_at = \$now | .verifying_pid = \$pid | .verifying_start = \$start | .verifying_token = \$token" \
          --argjson now "$(date +%s)" --arg pid "$me" --arg start "$ident" --arg token "$vtoken" >/dev/null 2>&1 || continue
        _ff_verify "$plan" "$tid" "$tasks" ;;
    esac
  done
}

# ---------------------------------------------------------------- scheduler: dispatch

_FF_MOVED=0
_ff_dispatch() {   # <plan> <max-parallel>
  local plan="$1" max="$2" tasks active tid t out rc st answer target m lf ready
  _FF_MOVED=0
  _plan_lock "$plan" || return 1
  if [ -f "$(_plan_dir "$plan")/flow-expansion.json" ]; then _plan_unlock "$plan"; return 1; fi
  _ff_pair_recover "$plan" || { _plan_unlock "$plan"; return 1; }
  ready="$(_task_ready "$plan")"
  _plan_unlock "$plan"
  tasks="$(_task_list "$plan")" || return 1
  active="$(printf '%s' "$tasks" | _ff_jq '[.[] | select(.state == "running" or .state == "verifying")] | length')"
  for tid in $ready; do
    _ff_out_of_time && return 0
    t="$(_task_get "$plan" "$tid")" || continue
    [ "$(printf '%s' "$t" | _ff_jq -r '.state')" = todo ] || continue
    if [ "$(printf '%s' "$t" | _ff_jq -r '.hold_after_deps // false')" = "true" ]; then
      _ff_hold "$plan" "$tid" "captain's decision: $(printf '%s' "$t" | _ff_jq -r '.title // ""')$(_ff_pick_hint "$plan" "$t" "$tasks"). Decide: $(_ff_cmd "$plan" task release "$tid" --answer '"<your decision>"')" '.state == "todo"'
      _FF_MOVED=1
      continue
    fi
    target="$(printf '%s' "$t" | _ff_jq -r '.land_target // ""')"
    if [ -n "$target" ]; then
      _ff_land_stage "$plan" "$tid" "$target"
      continue
    fi
    answer="$(printf '%s' "$t" | _ff_jq -r '.hold.answer // ""')"
    if [ "$(printf '%s' "$t" | _ff_jq -r '.gate // false')" = "true" ]; then
      # A decision gate is done only with the captain's answer (`task release --answer`).
      if [ -z "$answer" ]; then
        _ff_hold "$plan" "$tid" "captain's decision: $(printf '%s' "$t" | _ff_jq -r '.title // ""'). Decide: $(_ff_cmd "$plan" task release "$tid" --answer '"<your decision>"')" '.state == "todo"'
      else
        _task_update "$plan" "$tid" 'if .state != "todo" then error("moved") else . end | .state = "done" | .result = $a' --arg a "$answer" >/dev/null 2>&1 \
          && printf '  %s: decided by the captain: %s\n' "$tid" "$answer"
      fi
      _FF_MOVED=1
      continue
    fi
    # A reviewer the captain released after a FAIL: the answer asks for one more redo of the build.
    if [ -n "$answer" ] && [ -n "$(printf '%s' "$t" | _ff_jq -r '.verdict_failed.target // ""')" ]; then
      _ff_review_failed "$plan" "$tid" "$tasks" captain && _FF_MOVED=1
      continue
    fi
    [ "$active" -lt "$max" ] || continue
    # Model: skip one the exclude list now names; the stored fallbacks keep the stage's intent.
    m="$(_ff_next_model "$t" dispatch)"
    if [ "$m" != "$(printf '%s' "$t" | _ff_jq -r '.model // ""')" ]; then
      _task_update "$plan" "$tid" 'if .state != "todo" then error("moved") else . end | .model = $m' --arg m "$m" >/dev/null 2>&1 \
        && printf '  %s: model %s is excluded now; using %s\n' "$tid" "$(printf '%s' "$t" | _ff_jq -r '.model // "(none)"')" "${m:-whatever the router picks}"
    fi
    if [ "$(printf '%s' "$t" | _ff_jq -r '.require_verdict // false')" = true ]; then
      target="$(_ff_review_target "$t" "$(_task_list "$plan")")"
      if [ -n "$target" ]; then
        _task_update "$plan" "$tid" 'if .state != "todo" then error("moved") else . end
          | .reviewed_head = $h | .review_target = $t' \
          --arg h "$(_task_get "$plan" "$target" | _ff_jq -r '.head_sha // ""')" --arg t "$target" >/dev/null 2>&1 || continue
      fi
    fi
    out="$( _task_dispatch "$plan" "$tid" 2>&1 )"; rc=$?
    if [ "$rc" -eq 0 ]; then
      active=$((active + 1))
      printf '  %s: started job %s\n' "$tid" "$(printf '%s' "$out" | tail -1)"
    else
      out="$(printf '%s' "$out" | tail -2 | tr '\n' ' ' | sed 's/^ERROR: //' | cut -c1-200)"
      t="$(_task_get "$plan" "$tid")"
      st="$(printf '%s' "$t" | _ff_jq -r '.state')"
      if [ "$st" = failed ]; then
        # A launch failure counts as a failed attempt: retried within the task's budget. The task
        # store marks it with launch_failed:true when it can; older stores leave the reason text.
        lf="$(printf '%s' "$t" | _ff_jq -r 'if has("launch_failed") then (.launch_failed | tostring) else ((.result // "") | test("did not launch") | tostring) end')"
        if [ "$lf" = true ]; then
          _ff_fail_or_retry "$plan" "$tid" "the worker did not launch: $out" "$(_ff_guard "$t")"
        else
          printf '  %s: could not start: %s\n' "$tid" "$out"
        fi
      elif [ "$st" = held ]; then printf '  %s: held for the captain: %s\n' "$tid" "$(printf '%s' "$t" | _ff_jq -r '.hold.reason // ""')"
      else printf '  %s: not started this pass (%s); will try again\n' "$tid" "$out"; fi
    fi
  done
}

# _ff_pick_hint <plan> <task-json> <tasks-json>: for a decision that picks among builds (best-of-n),
# say how to land the winner once picked, since a flow never lands a candidate on its own.
_ff_pick_hint() {
  local plan="$1" t="$2" tasks="$3" ships
  ships="$(printf '%s' "$tasks" | _ff_jq -r --arg f "$(printf '%s' "$t" | _ff_jq -r '.flow.name // ""')" \
    '[.[] | select($f != "" and (.flow.name // "") == $f and (.shape // "") == "ship" and .state == "done") | .id] | join(", ")')"
  case "$ships" in *,*) printf ' (candidates: %s; after you pick, land the winner: %s)' "$ships" "$(_ff_cmd "$plan" land '<tid>')" ;; esac
}

# ---------------------------------------------------------------- summary + stop reasons

# All of these read _task_view (the task store's derived ready/blocked state + blocked_by), so the
# scheduler and `task ls` never disagree about what is ready or what waits on what.

# A done build whose --auto-land failed still needs the captain.
_FF_JQ_LANDFAIL='(.state == "done" and ((.land_error // "") != "") and ((.landed // false) | not))'

# _ff_counts <plan> -> "total done canceled failed held running ready blocked todo landfail" (one line)
_ff_counts() {
  _task_view "$1" | _ff_jq -r '
    def n(f): [.[] | select(f)] | length;
    [length, n(.state == "done"), n(.state == "canceled"), n(.state == "failed"), n(.state == "held"),
     n(.state == "running" or .state == "verifying"), n(.derived == "ready"), n(.derived == "blocked"),
     n(.state == "todo"), n('"$_FF_JQ_LANDFAIL"')] | map(tostring) | join(" ")'
}

# _ff_summary <plan> [tick]: the four buckets on one compact line.
_ff_summary() {
  _task_view "$1" | _ff_jq -r --arg plan "$1" --arg tick "${2:-}" '
    def ids(f): [.[] | select(f) | .id] | (if length > 6 then (.[0:6] + ["+\(length - 6)"]) else . end) | join(",");
    def paren(s): if s == "" then "" else " (" + s + ")" end;
    def cc: (.state == "held" or .state == "failed" or '"$_FF_JQ_LANDFAIL"');
    "[\($plan)\(if $tick == "" then "" else " tick \($tick)" end)] "
    + "Captain'"'"'s Call: \([.[] | select(cc)] | length)" + paren(ids(cc))
    + " | Landed/Done: \([.[] | select(.state == "done")] | length)"
    + " | Underway: \([.[] | select(.state == "running" or .state == "verifying")] | length)" + paren(ids(.state == "running" or .state == "verifying"))
    + " | Next: \([.[] | select(.derived == "ready")] | length) ready" + paren(ids(.derived == "ready"))
    + ", \([.[] | select(.derived == "blocked")] | length) waiting"'
}

# _ff_why_stuck <plan>: one plain line naming what is held, failed, or blocked, with the next command.
_ff_why_stuck() {
  _task_view "$1" | _ff_jq -r --arg plan "$1" '
    def cmd(s): "outsourcerer " + s + " --plan " + $plan;
    ([.[] | select(.state == "held") | .id + " (" + cmd("task release " + .id + " --answer \"...\"") + ")"]) as $held
    | ([.[] | select(.state == "failed") | .id + " (" + cmd("task retry " + .id) + ")"]) as $failed
    | ([.[] | select('"$_FF_JQ_LANDFAIL"') | .id + " (" + cmd("land " + .id) + ")"]) as $landfail
    | ([.[] | select(.derived == "blocked")
        | "\(.id) waits on \((.blocked_by // []) | map(.id + " (" + .state + ")") | join(", "))"]) as $blocked
    | [ (if ($held | length) > 0 then "held: " + ($held | join(", ")) else empty end),
        (if ($failed | length) > 0 then "failed: " + ($failed | join(", ")) else empty end),
        (if ($landfail | length) > 0 then "landing failed: " + ($landfail | join(", ")) else empty end),
        (if ($blocked | length) > 0 then "blocked: " + ($blocked | join("; ")) else empty end) ]
    | join(" · ")'
}

# ---------------------------------------------------------------- `plan run`

_FF_AUTO_LAND=0
_FF_SLEEPER=""
_FF_SAVED_INT=""; _FF_SAVED_TERM=""
_ff_restore_traps() {
  if [ -n "$_FF_SAVED_INT" ]; then eval "$_FF_SAVED_INT"; else trap - INT; fi
  if [ -n "$_FF_SAVED_TERM" ]; then eval "$_FF_SAVED_TERM"; else trap - TERM; fi
}
_ff_on_signal() {   # <exit-code>: stop now, release the lock, put the caller's traps back
  [ -n "$_FF_SLEEPER" ] && kill "$_FF_SLEEPER" 2>/dev/null
  _FF_SLEEPER=""
  _ff_lock_release
  _ff_restore_traps
  echo "stopped: interrupted; running jobs keep going. Run 'plan run' again to pick up where this left off." >&2
  exit "$1"
}
# Sleep in the background and wait for it, so INT/TERM interrupt the wait at once.
_ff_sleep() { sleep "$1" & _FF_SLEEPER=$!; wait "$_FF_SLEEPER" 2>/dev/null; _FF_SLEEPER=""; }

cmd_plan_run() {
  local plan="" max=3 once=0 interval=30 maxmin=240 a pd t0 tick=0 c total done_n canceled failed held running ready todo landfail why sl rc pass pend="" lastpend=""
  _FF_AUTO_LAND=0; _FF_SETUP=""
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --max-parallel) _factory_optval "$1" "$#" || return 1; max="$2"; shift 2 ;;
      --max-parallel=*) max="${a#*=}"; shift ;;
      --interval) _factory_optval "$1" "$#" || return 1; interval="$2"; shift 2 ;;
      --interval=*) interval="${a#*=}"; shift ;;
      --max-minutes) _factory_optval "$1" "$#" || return 1; maxmin="$2"; shift 2 ;;
      --max-minutes=*) maxmin="${a#*=}"; shift ;;
      --once) once=1; shift ;;
      --auto-land) _FF_AUTO_LAND=1; shift ;;
      --setup) [ -n "${2:-}" ] || die "plan run --setup needs a command, e.g. --setup \"npm ci\""; _FF_SETUP="$2"; shift 2 ;;
      --setup=*) _FF_SETUP="${a#*=}"; shift ;;
      --plan) _factory_optval "$1" "$#" || return 1; plan="$2"; shift 2 ;;
      -h|--help) _ff_plan_run_usage; return 0 ;;
      -*) die "plan run: unknown option '$a' ($(_ff_plan_run_usage | head -1))" ;;
      *) [ -z "$plan" ] || die "plan run takes one plan name (got '$plan' and '$a')"; plan="$a"; shift ;;
    esac
  done
  case "$max" in ''|*[!0-9]*|0) die "plan run --max-parallel needs a whole number of 1 or more" ;; esac
  case "$interval" in ''|*[!0-9]*|0) die "plan run --interval needs a whole number of seconds (1 or more)" ;; esac
  case "$maxmin" in ''|*[!0-9]*|0) die "plan run --max-minutes needs a whole number of minutes (1 or more)" ;; esac
  max="$(_ff_num "$max")"; interval="$(_ff_num "$interval")"; maxmin="$(_ff_num "$maxmin")"
  [ "$max" -gt 0 ] && [ "$interval" -gt 0 ] && [ "$maxmin" -gt 0 ] || die "plan run limits must be greater than zero"
  _ff_need_jq
  _ff_need_fns _plan_dir _plan_resolve _task_get _task_update _task_list _task_view _task_ready _task_dispatch _factory_done_check
  plan="$(_plan_resolve ${plan:+"$plan"})" || return 1
  [ -n "$plan" ] || die "no plan given and no current plan; name one: plan run <plan>"
  pd="$(_plan_dir "$plan")" || return 1
  [ -d "$pd" ] || die "no plan named '$plan' (see: plan ls)"

  _ff_lock_acquire "$pd/run.lock"; rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "another 'plan run' is already driving $plan (pid $_FF_LOCK_HOLDER); not starting a second one so nothing runs twice." >&2
    return "$_FF_RC_BUSY"
  elif [ "$rc" -ne 0 ]; then
    echo "plan run: $_FF_LOCK_HOLDER. Free some space and try again." >&2
    return 1
  fi
  # Released on every return path and on Ctrl-C/TERM; the caller's own INT/TERM traps are saved and
  # put back. Deliberately NOT chained onto the EXIT trap: inside a subshell that would also fire a
  # sourcing caller's own EXIT handler. If the process dies hard (kill -9, die), the lock's owner pid
  # is dead and the next `plan run` reclaims it.
  _FF_SAVED_INT="$(trap -p INT)"; _FF_SAVED_TERM="$(trap -p TERM)"
  trap '_ff_on_signal 130' INT; trap '_ff_on_signal 143' TERM

  t0=$(date +%s); _FF_DEADLINE=$(( t0 + maxmin * 60 ))
  while :; do
    tick=$((tick + 1))
    _ff_reconcile "$plan" || { _ff_lock_release; _ff_restore_traps; return 3; }
    _ff_dispatch "$plan" "$max"
    # A decision or land that finished this pass frees its dependents now, not one interval later.
    pass=1
    while [ "$_FF_MOVED" = 1 ] && [ "$pass" -lt 5 ] && ! _ff_out_of_time; do
      pass=$((pass + 1)); _ff_dispatch "$plan" "$max"
    done
    _ff_summary "$plan" "$tick"
    c="$(_ff_counts "$plan")" || { _ff_lock_release; _ff_restore_traps; die "could not read the tasks of $plan"; }
    set -- $c; total=$1 done_n=$2 canceled=$3 failed=$4 held=$5 running=$6 ready=$7 todo=$9 landfail=${10}
    rc=""; pend=""
    if [ "$total" -eq 0 ]; then
      echo "stopped: $plan has no tasks yet; add some with 'task add' or 'flow run'."; rc=0
    elif [ "$running" -eq 0 ] && [ "$ready" -eq 0 ]; then
      if [ "$failed" -eq 0 ] && [ "$held" -eq 0 ] && [ "$todo" -eq 0 ] && [ "$landfail" -eq 0 ]; then
        if [ "$canceled" -gt 0 ]; then echo "stopped: $plan is finished ($done_n done, $canceled canceled)."
        else echo "stopped: $plan is finished ($done_n done)."; fi
        _ff_wake_finished "$plan" "$done_n"
        rc=0
      else
        pend="$(_ff_next_default "$plan")"
        if [ -n "$pend" ] && [ "$once" != 1 ] && ! _ff_out_of_time; then
          # A held decision has a default with a deadline still ahead: wait for it instead of stopping.
          [ "$pend" = "$lastpend" ] || printf '  waiting: %s goes ahead with its default at %s unless you answer first\n' "${pend#* }" "$(_ff_jq -nr --argjson e "${pend%% *}" '$e | todate')"
          lastpend="$pend"
        else
          why="$(_ff_why_stuck "$plan")"
          echo "stopped: $plan needs the captain, nothing else can move. ${why}"
          [ -n "$pend" ] && echo "  ${pend#* } goes ahead with its default at $(_ff_jq -nr --argjson e "${pend%% *}" '$e | todate') unless you answer first; the next plan run after that applies it."
          rc=3
        fi
      fi
    elif _ff_out_of_time; then
      echo "stopped: time cap of $maxmin minutes reached with $running still underway (their jobs keep running). Run 'plan run $plan' again to pick up where this left off."
      rc=2
    elif [ "$once" = 1 ]; then
      echo "one tick done: $running underway, $ready ready. Run 'plan run $plan' to keep driving it."; rc=124
    fi
    if [ -n "$rc" ]; then
      _ff_lock_release; _ff_restore_traps
      return "$rc"
    fi
    sl="$interval"
    [ $(( _FF_DEADLINE - $(date +%s) )) -lt "$sl" ] && sl=$(( _FF_DEADLINE - $(date +%s) ))
    if [ -n "$pend" ] && [ $(( ${pend%% *} - $(date +%s) + 1 )) -lt "$sl" ]; then sl=$(( ${pend%% *} - $(date +%s) + 1 )); fi
    [ "$sl" -lt 1 ] && sl=1
    _ff_sleep "$sl"
  done
}

_ff_wake_finished() {   # <plan> <done-count>: one wake per distinct finished state, not one per tick
  local plan="$1" n="$2" pd sig
  pd="$(_plan_dir "$plan")"
  sig="$(_task_list "$plan" | _ff_jq -r '[.[] | .id + ":" + .state] | sort | join(",")' | cksum | cut -d' ' -f1)"
  [ "$(cat "$pd/.finished-woken" 2>/dev/null)" = "$sig" ] && return 0
  _ff_wake "$plan" "-" finished "plan $plan finished: $n task(s) done"
  printf '%s\n' "$sig" > "$pd/.finished-woken.$$" 2>/dev/null && mv -f "$pd/.finished-woken.$$" "$pd/.finished-woken" 2>/dev/null
  return 0
}

_ff_plan_run_usage() {
  cat <<'EOF'
usage: plan run [plan] [--max-parallel N] [--once] [--interval S] [--auto-land] [--max-minutes M] [--setup CMD]
  Drives a plan: checks running work, finishes or retries it, starts ready tasks (up to N at once, default 3).
  --once         one pass, then exit (for the heartbeat or an orchestrator turn)
  --interval S   seconds between passes (default 30)
  --auto-land    land each finished plain build task through the merge gate (flow builds land through
                 the flow's own land stage, after their review)
  --max-minutes  stop driving after M minutes (default 240); running jobs keep going
  --setup CMD    default command land runs in the merged checkout before the check (e.g. "npm ci");
                 a task's or flow stage's own `setup` wins
  exit: 0 all done | 3 needs the captain | 2 time cap | 124 --once with work underway | 4 another run drives it | 1 error
EOF
}

# ---------------------------------------------------------------- one line per active plan (bearings/rundown)
# One jq pass over every active plan's task files. A plan that finished (its .finished-woken marker is
# newer than every task file) is skipped without reading its tasks at all.
_factory_plans_digest() {
  local root="$OSRC_HOME/plans" d plan files="" out
  [ -d "$root" ] && have jq || return 0
  for d in "$root"/*/; do
    [ -f "$d/plan.json" ] || continue
    ls "$d"tasks/t*.json >/dev/null 2>&1 || continue
    if [ -f "$d.finished-woken" ] && [ -z "$(find "$d"tasks -name 't*.json' -newer "$d.finished-woken" 2>/dev/null | head -1)" ]; then
      continue
    fi
    files="$files$d
"
  done
  [ -n "$files" ] || return 0
  out="$(printf '%s' "$files" | while IFS= read -r d; do [ -n "$d" ] && cat "$d"tasks/t*.json 2>/dev/null; echo; done \
    | _ff_jq -rs '
      group_by(.plan)[]
      | (map({key: .id, value: .state}) | from_entries) as $s
      | map(. + {derived: (if .state == "todo" then (if all((.deps // [])[]; $s[.] == "done") then "ready" else "blocked" end) else .state end)}) as $v
      | def n(f): [$v[] | select(f)] | length;
        {plan: $v[0].plan, need: (n(.state == "failed") + n(.state == "held")), done: n(.state == "done"),
         run: n(.state == "running" or .state == "verifying"), todo: n(.state == "todo"), ready: n(.derived == "ready")}
      | select(.need + .run + .todo > 0)
      | "plan \(.plan): \(.need) need you · \(.done) done · \(.run) underway · \(.todo) next (\(.ready) ready)"' 2>/dev/null)" || out=""
  if [ -z "$out" ] && declare -F _task_view >/dev/null 2>&1; then
    # A damaged task file breaks the single pass: fall back to one plan at a time.
    local c
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      plan="$(basename "$d")"
      c="$(_ff_counts "$plan" 2>/dev/null)" || continue
      set -- $c
      [ "${1:-0}" -gt 0 ] || continue
      [ $(( $4 + $5 + $6 + $9 )) -gt 0 ] || continue
      printf 'plan %s: %s need you · %s done · %s underway · %s next (%s ready)\n' "$plan" "$(( $4 + $5 ))" "$2" "$6" "$9" "$7"
    done <<EOF
$files
EOF
    return 0
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# ================================================================ flows

_ff_flow_dirs() {   # user flows first so they override built-ins by name
  printf '%s\n' "$OSRC_HOME/flows"
  printf '%s\n' "${OSRC_FLOWS_BUILTIN_DIR:-$_FF_DIR/../references/flows}"
}

_ff_flow_path() {   # <name> -> path of the winning flow file (rc1 if none)
  local name="$1" d
  _ff_name_ok "$name" || return 1
  while IFS= read -r d; do
    [ -f "$d/$name.json" ] && { printf '%s\n' "$d/$name.json"; return 0; }
  done <<EOF
$(_ff_flow_dirs)
EOF
  return 1
}

# Flow validation. Fails closed: if this jq program itself errors, the flow is refused.
_FF_FLOW_CHECK_JQ='
def sid: "^[A-Za-z0-9_-]+$";
def strlist: type == "array" and all(.[]; type == "string");
def optstr(f): (f | type) as $t | ($t == "null" or $t == "string");
def optbool(f): (f | type) as $t | ($t == "null" or $t == "boolean");
if type != "object" then "the file must hold one JSON object"
elif (.stages | type) != "array" or (.stages | length) == 0 then "it has no stages"
elif ((.vars // {}) | type) != "object" then "vars must be an object"
elif ([.stages | to_entries[] | select((.value | type) != "object") | .key + 1] | length) > 0
  then "stage \([.stages | to_entries[] | select((.value | type) != "object") | .key + 1][0]) is not an object"
else
  (.stages | map(.id)) as $ids
  | (.stages | map(select(has("repeat")) | .id)) as $rep
  | (.stages | map(select((.land // "") != "") | .id)) as $landers
  | (.stages | map(select((.land // "") != "") | .land)) as $lands
  | ([.stages | to_entries[] | .key as $k | .value as $s
      | if ($s.id | type) != "string" or ($s.id | test(sid) | not) then "stage \($k + 1) has a missing or bad id"
        elif ([$ids[] | select(. == $s.id)] | length) > 1 then "stage id \($s.id) is used twice"
        elif ($s | has("deps")) and (($s.deps | strlist) | not) then "stage \($s.id): deps must be a list of stage ids"
        elif ($s | has("models")) and (($s.models | strlist) | not) then "stage \($s.id): models must be a list of model names"
        elif ($s | has("fallback")) and (($s.fallback | strlist) | not) then "stage \($s.id): fallback must be a list of model names"
        elif ([("title","prompt","check","setup","model","provider","land","shape","verb","deliver") as $f | select(optstr($s[$f]) | not) | $f] | length) > 0
          then "stage \($s.id): \([("title","prompt","check","setup","model","provider","land","shape","verb","deliver") as $f | select(optstr($s[$f]) | not) | $f][0]) must be text"
        elif (optbool($s.hold) and optbool($s.verdict)) | not then "stage \($s.id): hold and verdict must be true or false"
        elif ($s | has("repeat")) and (($s.repeat | type) as $t | ($t == "string" or $t == "number") | not) then "stage \($s.id): repeat must be a number"
        elif ($s | has("retries")) and (($s.retries | type) != "number" or $s.retries < 0 or $s.retries > 10 or ($s.retries | floor) != $s.retries)
          then "stage \($s.id): retries must be a whole number from 0 to 10"
        elif ($s.land // "") != "" and (($s.hold // false) or ($s.verdict // false) or ($s | has("repeat")) or (($s.prompt // "") != ""))
          then "stage \($s.id): a land stage only lands; it cannot also hold, review, repeat or have a prompt"
        elif ($s.land // "") == "" and (($s.shape // "scout") | IN("scout","ship") | not) then "stage \($s.id): shape must be scout or ship"
        elif ($s.land // "") == "" and (($s.verb // "run") | IN("run","research","edit","yolo") | not) then "stage \($s.id): verb must be run, research, edit or yolo"
        elif ([($s.deps // [])[] | . as $d | select(($ids[0:$k] | index($d)) == null)] | length) > 0
          then "stage \($s.id) depends on \([($s.deps // [])[] | . as $d | select(($ids[0:$k] | index($d)) == null)] | join(", ")), which is not an earlier stage"
        elif ($s.land // "") != "" and (($ids[0:$k] | index($s.land)) == null) then "stage \($s.id) lands \($s.land), which is not an earlier stage"
        elif ($s.land // "") != "" and (($rep | index($s.land)) != null) then "stage \($s.id) lands \($s.land), which repeats; a land stage lands exactly one build (land the winner by hand)"
        elif ($s.land // "") != "" and (($landers | index($s.land)) != null) then "stage \($s.id) lands \($s.land), which is itself a land stage"
        elif ($s.land // "") != "" and ([$lands[] | select(. == $s.land)] | length) > 1 then "build stage \($s.land) is landed by more than one stage"
        elif ($s.land // "") == "" and ($s.hold // false) != true and (($s.prompt // "") == "") then "stage \($s.id) has no prompt"
        elif ($s.hold // false) == true and ($s.verdict // false) == true and (($s.prompt // "") == "")
          then "stage \($s.id): a captain'"'"'s decision with no prompt has no output to review; drop verdict or add a prompt"
        else empty end] | first) // ""
end'

# _ff_flow_load <name> -> validated flow JSON (dies with a plain reason when it is malformed)
_ff_flow_load() {
  local name="$1" path err tgt
  _ff_name_ok "$name" || die "flow names use letters, digits, dot, dash and underscore only (got '$name')"
  path="$(_ff_flow_path "$name")" || die "no flow named '$name' (see: flow ls)"
  _ff_jq -e . "$path" >/dev/null 2>&1 || die "flow file $path is not valid JSON"
  err="$(_ff_jq -r "$_FF_FLOW_CHECK_JQ" "$path" 2>/dev/null)" || die "flow '$name' ($path) could not be checked (its layout is not what a flow file looks like); fix it against references/factory-flow-cli.md"
  [ -z "$err" ] || die "flow '$name' ($path) is broken: $err"
  # Land targets must be build (ship) stages.
  tgt="$(_ff_jq -r '. as $f | [.stages[] | select((.land // "") != "") | .land as $l | select(([$f.stages[] | select(.id == $l) | (.shape // "scout")][0]) != "ship") | .id + " lands " + $l] | first // ""' "$path" 2>/dev/null)" \
    || die "flow '$name' ($path) could not be checked"
  [ -z "$tgt" ] || die "flow '$name' ($path) is broken: stage $tgt, which is not a build (ship) stage"
  _ff_jq -c --arg src "$path" '. + {_source: $src}' "$path"
}

# _ff_flow_vars_used <flow-json> -> newline list of {{var}} names used in the stages
_ff_flow_vars_used() {
  printf '%s' "$1" | _ff_jq -r '[.stages[] | (.title, .prompt, .check, .setup, .repeat, .model, (.fallback // [])[], (.models // [])[])
     | select(type == "string") | [match("\\{\\{([A-Za-z_][A-Za-z0-9_]*)\\}\\}"; "g") | .captures[0].string][]] | unique[]'
}

# _ff_pick_model <candidate>... -> first one not on the exclude list (empty when all are excluded).
# _FF_AVOID (space-separated) names models already given to earlier copies of the same stage; they
# are used only when nothing else is allowed, so copies never collapse onto one model.
_FF_AVOID=""
_ff_pick_model() {
  local m first=""
  for m in "$@"; do
    [ -n "$m" ] || continue
    _ff_excluded "$m" && continue
    [ -n "$first" ] || first="$m"
    case " $_FF_AVOID " in *" $m "*) continue ;; esac
    printf '%s\n' "$m"; return 0
  done
  [ -n "$first" ] && printf '%s\n' "$first"
  return 0
}

# _ff_jq_with <json-a> <json-b> <jq args...>: run _ff_jq -n with the two JSON documents on stdin, so big
# values (a huge --var) never hit the per-argument size limit. The filter reads them with
# `input as $a | input as $b | ...`.
_ff_jq_with() {
  local a="$1" b="$2"; shift 2
  { printf '%s\n' "$a"; printf '%s\n' "$b"; } | _ff_jq -c -n "$@"
}

# _ff_subst <json-string-value> <vars-json>: single-pass {{var}} substitution done inside jq. Values
# are inserted literally (never evaluated, never re-scanned), so quotes, $(...) and backticks in a
# value stay plain text. Unknown placeholders are left in place (caught earlier by validation).
_FF_SUBST_JQ='def sub($v): if type == "string" then gsub("\\{\\{(?<k>[A-Za-z_][A-Za-z0-9_]*)\\}\\}"; ($v[.k] // ("{{" + .k + "}}"))) else . end;'

# _ff_flow_expand <flow-json> <vars-json> -> JSON array of concrete stages (repeat expanded, vars
# substituted, models chosen against the exclude list). Each item keeps "sid" (stage id), "copy_of"
# (base stage id for repeated stages), the original deps (stage ids) and "cands" (model candidates).
_ff_flow_expand() {
  local flow="$1" vars="$2" n i k cnt base stage out="[]" model models
  n="$(printf '%s' "$flow" | _ff_jq '.stages | length')"
  i=0
  while [ "$i" -lt "$n" ]; do
    stage="$(printf '%s' "$flow" | _ff_jq -c --argjson i "$i" '.stages[$i]')"
    cnt="$(_ff_jq_with "$vars" "$stage" -r "$_FF_SUBST_JQ"' input as $v | input | (.repeat // "1") | tostring | sub($v)')"
    case "$cnt" in ''|*[!0-9]*) die "stage $(printf '%s' "$stage" | _ff_jq -r .id) repeats '$cnt' times; that must be a whole number (for example --var n=3)" ;; esac
    { [ "$cnt" -ge 1 ] && [ "$cnt" -le 10 ]; } || die "stage $(printf '%s' "$stage" | _ff_jq -r .id) repeats $cnt times; pick 1 to 10"
    k=1; _FF_AVOID=""
    while [ "$k" -le "$cnt" ]; do
      # Per-copy vars add {{i}} (copy number) and {{n}} (copy count); flow vars win if they define them.
      base="$(_ff_jq_with "$vars" "$stage" --arg i "$k" --arg n "$cnt" "$_FF_SUBST_JQ"'
        input as $v | input
        | ({i: $i, n: $n} + $v) as $vv
        | . as $s
        | {sid: (if ($s | has("repeat")) then $s.id + "-" + $i else $s.id end), copy_of: $s.id,
           title: (($s.title // $s.id) | sub($vv)), shape: ($s.shape // "scout"), verb: ($s.verb // "run"),
           prompt: (($s.prompt // "") | sub($vv)), check: (($s.check // "") | sub($vv)), setup: (($s.setup // "") | sub($vv)),
           deps: ($s.deps // []), hold: ($s.hold // false), land: ($s.land // ""), verdict: ($s.verdict // false),
           retries: ($s.retries // 1), deliver: ($s.deliver // "local"),
           provider: ($s.provider // ""),
           cands: ((if ($s.models // []) | length > 0
                    then ($s.models | length) as $L | [range(0; $L)] | map($s.models[(. + ($i | tonumber) - 1) % $L])
                    else [($s.model // "")] + ($s.fallback // []) end) | map(sub($vv)) | map(select(. != "")))}')" \
        || die "could not expand stage $(printf '%s' "$stage" | _ff_jq -r .id)"
      models="$(printf '%s' "$base" | _ff_jq -r '.cands[]')"
      # shellcheck disable=SC2086
      model="$(set -f; _ff_pick_model $models)"
      [ -n "$model" ] && _FF_AVOID="$_FF_AVOID $model"
      if [ -n "$models" ] && [ -z "$model" ] && [ "$(printf '%s' "$base" | _ff_jq -r '.land')" = "" ]; then
        echo "note: every model named for stage $(printf '%s' "$base" | _ff_jq -r .sid) is on your exclude list; the router will pick one." >&2
      fi
      out="$(_ff_jq_with "$out" "$base" --arg m "$model" 'input as $o | input as $b | $o + [($b + {model: $m})]')" \
        || die "could not expand stage $(printf '%s' "$stage" | _ff_jq -r .id)"
      k=$((k + 1))
    done
    i=$((i + 1))
  done
  _FF_AVOID=""
  printf '%s\n' "$out"
}

# _ff_parse_vars <flow-json> <JSON array of "k=v" strings> -> merged vars JSON (defaults applied);
# dies on a missing required var or an unknown one. Values stay data end to end (_ff_jq --arg / stdin),
# never eval'd, and never passed as one giant argument.
_ff_parse_vars() {
  local flow="$1" kvs="$2" vars="{}" kv k v missing unknown used cnt i
  cnt="$(printf '%s' "$kvs" | _ff_jq 'length')"; i=0
  while [ "$i" -lt "$cnt" ]; do
    kv="$(printf '%s' "$kvs" | _ff_jq -r --argjson i "$i" '.[$i]')"; i=$((i + 1))
    case "$kv" in *=*) ;; *) die "--var needs name=value (got '$(printf '%s' "$kv" | cut -c1-60)')" ;; esac
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in ''|[0-9]*|*[!A-Za-z0-9_]*) die "--var name '$(printf '%s' "$k" | cut -c1-60)' must be letters, digits and underscore" ;; esac
    vars="$(_ff_jq_with "$vars" "$(printf '%s' "$v" | _ff_jq -Rs .)" --arg k "$k" 'input as $c | input as $v | $c + {($k): $v}')" \
      || die "could not read --var $k"
  done
  unknown="$(_ff_jq_with "$flow" "$vars" -r 'input as $f | input as $v | ($f.vars // {}) as $d | [$v | keys[] | . as $k | select(($d | has($k)) | not)] | join(", ")')"
  [ -z "$unknown" ] || die "flow $(printf '%s' "$flow" | _ff_jq -r .name) has no variable $unknown (it takes: $(printf '%s' "$flow" | _ff_jq -r '(.vars // {}) | keys | join(", ")'))"
  missing="$(_ff_jq_with "$flow" "$vars" -r 'input as $f | input as $v | [($f.vars // {}) | to_entries[] | select(.value == "required" and (($v[.key] // "") == "")) | .key] | join(", ")')"
  [ -z "$missing" ] || die "flow $(printf '%s' "$flow" | _ff_jq -r .name) needs $(printf '%s' "$missing" | sed 's/\([A-Za-z0-9_]*\)/--var \1=.../g')"
  vars="$(_ff_jq_with "$flow" "$vars" 'input as $f | input as $v | $f
    | reduce ((.vars // {}) | to_entries[]) as $e ({};
      . + {($e.key): (if ($e.value | type) == "object" then ($e.value.default // "" | tostring)
                      elif $e.value == "required" or $e.value == "optional" then ""
                      else ($e.value | tostring) end)}) + $v')"
  used="$(_ff_flow_vars_used "$flow")"
  for k in $used; do
    case "$k" in i|n) continue ;; esac
    printf '%s' "$vars" | _ff_jq -e --arg k "$k" 'has($k)' >/dev/null || die "flow $(printf '%s' "$flow" | _ff_jq -r .name) uses {{$k}} but does not declare it under vars"
  done
  printf '%s\n' "$vars"
}

# _ff_plan_ensure <plan> <goal> <repo-arg> <needs-repo 0|1> <must-be-new 0|1>: create the plan if
# missing (data model exactly as the task store writes it), refuse a code-building flow without a git
# repo, refuse a --repo that is not the existing plan's repo. Sets _FF_PLAN_CREATED=1 when it made it.
# rc 2 = must-be-new and the name is taken (the caller picks another).
_FF_PLAN_CREATED=0
_ff_plan_ensure() {
  local plan="$1" goal="$2" repoarg="$3" needrepo="$4" new="${5:-0}" pd repo="" base="" now tmp want
  _FF_PLAN_CREATED=0
  pd="$(_plan_dir "$plan")" || return 1
  if [ -e "$pd" ]; then
    [ "$new" = 1 ] && return 2
    [ -f "$pd/plan.json" ] || die "$pd exists but is not a plan; pick another name with --plan"
    repo="$(_ff_jq -r '.repo // ""' "$pd/plan.json")"
    if [ -n "$repoarg" ]; then
      want="$(git -C "$repoarg" rev-parse --show-toplevel 2>/dev/null)" || die "--repo $repoarg is not inside a git repository"
      want="$(cd "$want" && pwd -P)"
      [ "$want" = "$( [ -n "$repo" ] && cd "$repo" 2>/dev/null && pwd -P)" ] \
        || die "plan $plan works in ${repo:-no repo}, not $want. Drop --repo to add to it, or pass --plan with a new name"
    fi
    [ "$needrepo" = 0 ] || [ -n "$repo" ] || die "plan $plan has no git repo, and this flow builds code; use a plan made inside a repo, or pass --plan with a new name and --repo <path>"
    return 0
  fi
  if [ -n "$repoarg" ]; then
    repo="$(git -C "$repoarg" rev-parse --show-toplevel 2>/dev/null)" || die "--repo $repoarg is not inside a git repository"
  else
    repo="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  [ "$needrepo" = 0 ] || [ -n "$repo" ] || die "this flow builds code, so it needs a git repo; run it inside one or pass --repo <path>"
  [ -n "$repo" ] && base="$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if declare -F _plan_cli_new >/dev/null 2>&1; then
    # The task store's own `plan new` (base-branch checks, events, private dirs). Made current only
    # when there is no current plan yet, so a flow never steals focus from the plan you are on.
    set -- "$plan" --goal "$goal"
    if [ -n "$repo" ]; then set -- "$@" --repo "$repo"; else set -- "$@" --no-repo; fi
    [ -s "$OSRC_HOME/plans/current" ] && set -- "$@" --no-use
    if ! ( _plan_cli_new "$@" ) >/dev/null 2>"$OSRC_HOME/.ff-plan-new.$$"; then
      if [ "$new" = 1 ] && [ -e "$pd" ]; then rm -f "$OSRC_HOME/.ff-plan-new.$$"; return 2; fi   # lost a same-name race
      cat "$OSRC_HOME/.ff-plan-new.$$" >&2 2>/dev/null; rm -f "$OSRC_HOME/.ff-plan-new.$$"
      die "could not create plan $plan"
    fi
    rm -f "$OSRC_HOME/.ff-plan-new.$$"
    _FF_PLAN_CREATED=1
    return 0
  fi
  now="$(_ff_now)"
  mkdir -p "$(dirname "$pd")" || die "could not create $(dirname "$pd")"
  mkdir "$pd" 2>/dev/null || { [ "$new" = 1 ] && return 2; die "could not create the plan folder $pd"; }
  mkdir -p "$pd/tasks" || die "could not create the plan folder $pd"
  _FF_PLAN_CREATED=1
  tmp="$pd/.plan.json.$$"
  _ff_jq -n --arg name "$plan" --arg goal "$goal" --arg repo "$repo" --arg base "$base" --arg now "$now" \
    '{schema:1,name:$name,goal:$goal,repo:$repo,base_branch:$base,created:$now,updated:$now}' > "$tmp" \
    && mv -f "$tmp" "$pd/plan.json" || die "could not write $pd/plan.json"
  [ -s "$OSRC_HOME/plans/current" ] || { printf '%s\n' "$plan" > "$OSRC_HOME/plans/current.$$" && mv -f "$OSRC_HOME/plans/current.$$" "$OSRC_HOME/plans/current"; }
  return 0
}

cmd_flow() {
  local sub="${1:-}"; shift || true
  _ff_need_jq
  case "$sub" in
    ls|list)   _ff_flow_ls ;;
    show)      [ -n "${1:-}" ] || die "usage: flow show <name>"; _ff_flow_show "$1" ;;
    run)       _ff_flow_run "$@" ;;
    ""|-h|--help|help)
      cat <<'EOF'
usage: flow ls | flow show <name> | flow run <name> [--plan p] [--var k=v ...] [--repo path] [--dry-run]
  A flow is a reusable recipe of tasks (scouts, builds, reviews, captain decisions). `flow run` turns
  it into tasks in a plan; then `plan run <plan>` drives them. Your own flows in ~/.outsourcerer/flows/
  (or $OSRC_HOME/flows/) override the built-in ones by name.
EOF
      ;;
    *) die "flow: unknown action '$sub' (use: flow ls | flow show <name> | flow run <name>)" ;;
  esac
}

_ff_flow_ls() {
  local d f name seen="" src
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    for f in "$d"/*.json; do
      [ -f "$f" ] || continue
      name="$(basename "$f" .json)"
      _ff_name_ok "$name" || continue
      case " $seen " in *" $name "*) continue ;; esac
      seen="$seen $name"
      src="built-in"; [ "$d" = "$OSRC_HOME/flows" ] && src="yours"
      printf '%-16s %-8s %s\n' "$name" "$src" "$(_ff_jq -r '.description // "" | tostring | gsub("[[:cntrl:]]"; " ") | .[0:110]' "$f" 2>/dev/null || echo '(unreadable)')"
    done
  done <<EOF
$(_ff_flow_dirs)
EOF
  [ -n "$seen" ] || echo "no flows found"
}

_ff_flow_show() {
  local flow
  flow="$(_ff_flow_load "$1")" || return 1
  printf '%s' "$flow" | _ff_jq -r '
    "\(.name): \(.description // "")",
    "from: \(._source)",
    "vars: " + ((.vars // {}) | to_entries | map(.key + (if .value == "required" then " (required)" elif .value == "optional" then " (optional)" elif (.value | type) == "object" then " (default " + (.value.default // "" | tostring) + ")" else " (default " + (.value | tostring) + ")" end)) | join(", ")),
    "stages:",
    (.stages[] | "  " + .id
       + (if (.land // "") != "" then "  lands " + .land
          else "  " + (.shape // "scout") + "/" + (.verb // "run")
               + (if (.models // []) | length > 0 then "  models " + (.models | join("|"))
                  elif (.model // "") != "" then "  model " + .model + (if (.fallback // []) | length > 0 then " (then " + (.fallback | join(", ")) + ")" else "" end)
                  else "" end) end)
       + (if (.repeat // null) != null then "  x" + (.repeat | tostring) else "" end)
       + (if (.deps // []) | length > 0 then "  after " + (.deps | join(",")) else "" end)
       + (if .hold == true then "  [captain decides]" else "" end)
       + (if .verdict == true then "  [must say VERDICT: PASS]" else "" end)
       + "  - " + (.title // ""))'
}

# _ff_flow_rollback <plan>: remove only the expansion named by its durable marker, under the plan
# lock. Keep the plan and unrelated tasks, including work added before this expansion acquired it.
_ff_flow_rollback() {
  local plan="$1" pd t token
  pd="$(_plan_dir "$plan")"
  [ -f "$pd/flow-expansion.json" ] || return 0
  token="$(_ff_jq -r '.token' "$pd/flow-expansion.json")" || return 1
  # The caller holds the plan lock. Remove only this expansion, never the whole plan.
  for t in $(_task_list "$plan" | _ff_jq -r --arg token "$token" '.[] | select(.flow_expansion == $token) | .id'); do
    rm -f "$pd/tasks/$t.json"
    rm -rf "$pd/tasks/$t"
  done
  rm -f "$pd/flow-expansion.json"
  _ff_event "$plan" "" flow-rolled-back "interrupted expansion $token"
}

_ff_flow_run() (
  local name="" plan="" repo="" dry=0 a flow vars stages goal needrepo n i st sid tid map="" deps_json json model title rows="" copy land
  local kvs="[]" auto=0 base k rc made="" ltid bad pd token committed=0
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --plan) _factory_optval "$1" "$#" || return 1; plan="$2"; shift 2 ;;
      --plan=*) plan="${a#*=}"; shift ;;
      --repo) _factory_optval "$1" "$#" || return 1; repo="$2"; shift 2 ;;
      --repo=*) repo="${a#*=}"; shift ;;
      --var) [ "$#" -ge 2 ] || die "--var needs name=value"; kvs="$(_ff_jq_with "$kvs" "$(printf '%s' "$2" | _ff_jq -Rs .)" 'input as $c | input as $v | $c + [$v]')"; shift 2 ;;
      --var=*) kvs="$(_ff_jq_with "$kvs" "$(printf '%s' "${a#--var=}" | _ff_jq -Rs .)" 'input as $c | input as $v | $c + [$v]')"; shift ;;
      --dry-run) dry=1; shift ;;
      -*) die "flow run: unknown option '$a'" ;;
      *) [ -z "$name" ] || die "flow run takes one flow name (got '$name' and '$a')"; name="$a"; shift ;;
    esac
  done
  [ -n "$name" ] || die "usage: flow run <name> [--plan p] [--var k=v ...] [--repo path]"
  _ff_need_fns _plan_dir _task_new
  # Everything is validated and expanded before anything is written.
  flow="$(_ff_flow_load "$name")" || return 1
  vars="$(_ff_parse_vars "$flow" "$kvs")" || return 1
  [ -n "$vars" ] || return 1
  stages="$(_ff_flow_expand "$flow" "$vars")" || return 1
  [ -n "$stages" ] || return 1
  bad="$(printf '%s' "$stages" | _ff_jq -r '. as $all | [.[] | select(.land != "") | .land as $l | select(([$all[] | select(.sid == $l or .copy_of == $l)] | length) != 1) | .sid] | first // ""')"
  [ -z "$bad" ] || die "stage $bad must land exactly one task"
  goal="$(printf '%s' "$vars" | _ff_jq -r '.goal // ""')"
  [ -n "$goal" ] || goal="$(printf '%s' "$flow" | _ff_jq -r '.description // .name')"
  needrepo="$(printf '%s' "$stages" | _ff_jq -r 'if any(.[]; .shape == "ship" and .land == "") then 1 else 0 end')"
  if [ -z "$plan" ]; then auto=1; plan="$name-$(date +%Y%m%d-%H%M%S)"; fi
  _ff_name_ok "$plan" || die "plan names use letters, digits, dot, dash and underscore only (got '$plan')"

  if [ "$dry" = 1 ]; then
    echo "flow $name would add to plan $plan:"
    printf '%s' "$stages" | _ff_jq -r '.[] | "  " + .sid + "  " + (if .land != "" then "lands " + .land else .shape + "/" + .verb + (if .model != "" then " on " + .model else "" end) end) + (if (.deps | length) > 0 then "  after " + (.deps | join(",")) else "" end) + (if .hold then "  [captain decides]" else "" end) + "  - " + .title'
    return 0
  fi
  if [ "$auto" = 1 ]; then
    # A generated name is always a NEW plan: two runs in the same second never share one.
    base="$plan"; k=1
    while :; do
      _ff_plan_ensure "$plan" "$goal" "$repo" "$needrepo" 1; rc=$?
      [ "$rc" -eq 2 ] || break
      k=$((k + 1)); [ "$k" -le 50 ] || die "could not find a free plan name like $base; pass --plan <name>"
      plan="$base-$k"
    done
    [ "$rc" -eq 0 ] || return 1
  else
    _ff_plan_ensure "$plan" "$goal" "$repo" "$needrepo" 0 || return 1
  fi

  pd="$(_plan_dir "$plan")"
  _plan_lock "$plan" || return 1
  # Ordinary errors/signals roll back our tasks. SIGKILL leaves the marker and held tasks;
  # scheduling refuses them, and the next flow run rolls back under this same lock.
  trap '[ "$committed" = 1 ] || _ff_flow_rollback "$plan"; _plan_unlock "$plan"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  _ff_flow_rollback "$plan" || return 1
  _factory_self_pid "$pd"; token="$(date +%s)-$_FACTORY_SELF_PID-$RANDOM"
  _factory_write_json "$pd/flow-expansion.json" "$(_ff_jq -cn --arg token "$token" --arg name "$name" '{token:$token,flow:$name}')" || return 1

  n="$(printf '%s' "$stages" | _ff_jq 'length')"; i=0
  while [ "$i" -lt "$n" ]; do
    st="$(printf '%s' "$stages" | _ff_jq -c --argjson i "$i" '.[$i]')"
    sid="$(printf '%s' "$st" | _ff_jq -r .sid)"
    # Translate stage-id deps into tids. A dep on a repeated stage means every copy.
    deps_json="$(printf '%s' "$st" | _ff_jq -c --arg map "$map" '
      ($map | split("\n") | map(select(. != "") | split("=") | {stage: .[0], copy: .[1], tid: .[2]})) as $m
      | [.deps[] as $d | $m[] | select(.stage == $d or .copy == $d) | .tid] | unique')"
    land="$(printf '%s' "$st" | _ff_jq -r .land)"
    ltid=""
    if [ -n "$land" ]; then
      ltid="$(printf '%s' "$map" | awk -F= -v s="$land" '$2 == s || $1 == s { print $3 }' | head -2)"
      if [ "$(printf '%s\n' "$ltid" | grep -c .)" != 1 ]; then
        # shellcheck disable=SC2086
        _ff_flow_rollback "$plan" $made
        die "stage $sid lands '$land', which must be exactly one task; nothing was added"
      fi
      deps_json="$(printf '%s' "$deps_json" | _ff_jq -c --arg t "$ltid" '(. + [$t]) | unique')"
    fi
    json="$(printf '%s' "$st" | _ff_jq -c --argjson deps "$deps_json" --arg flow "$name" --arg ltid "$ltid" --arg now "$(_ff_now)" --arg token "$token" '
      {flow_expansion:$token,schema:1, title:.title, shape:(if .land != "" then "scout" else .shape end), state:"held", deps:$deps,
       prompt:(if .land != "" then "" else .prompt end), spec:"", check:.check,
       verb:(if .land != "" then "run" else .verb end), model:.model, provider:.provider,
       deliver:(if .land != "" then "local" else .deliver end), retries:.retries, attempts:0,
       job:"", jobs:[], worktree:"", branch:"", base_sha:"", head_sha:"",
       hold:{reason:"",until:"",answer:""}, result:"", evidence:"",
       flow:{name:$flow, stage:.sid}, created:$now, updated:$now,
       hold_after_deps:.hold, gate:(.hold and .prompt == "" and .land == ""), land_target:$ltid, require_verdict:.verdict,
       fallback:(if .land != "" then [] else .cands end)}
      + (if .setup != "" then {setup: .setup} else {} end)')" || { _ff_flow_rollback "$plan" $made; die "could not build stage $sid; nothing was added"; }
    tid="$(_task_new "$plan" "$json")" || {
      # shellcheck disable=SC2086
      _ff_flow_rollback "$plan" $made
      die "could not add stage $sid to plan $plan; nothing was added"; }
    made="$made $tid"
    copy="$(printf '%s' "$st" | _ff_jq -r .copy_of)"
    map="$map$sid=$copy=$tid
"
    model="$(printf '%s' "$st" | _ff_jq -r .model)"; title="$(printf '%s' "$st" | _ff_jq -r .title | cut -c1-120)"
    rows="$rows$(printf '  %-14s -> %-4s %s%s' "$sid" "$tid" "${model:+[$model] }" "$title")
"
    i=$((i + 1))
  done
  for tid in $made; do
    _task_update "$plan" "$tid" 'if .flow_expansion != $token or .state != "held" then error("expansion changed") else .state = "todo" end' --arg token "$token" >/dev/null || return 1
  done
  rm -f "$pd/flow-expansion.json" || return 1
  committed=1
  _plan_unlock "$plan"
  trap - EXIT INT TERM
  echo "flow $name added $n task(s) to plan $plan:"
  printf '%s' "$rows"
  echo "next: outsourcerer plan run $plan"
)
