#!/usr/bin/env bash
# test_no_phantom_jobs.sh — an invalid invocation must never mint a job id.
#
# What made them expensive was not the error, it was the ORDER of events. cmd_bg accepted anything it did
# not recognise as a task, _bg_launch minted a job dir, nohup-detached, and printed an id. The caller got
# an id and believed work had started. The command only died later inside the detached child, which wrote
# the error into out.log and set status=failed. A session therefore moved on from work that never ran, and
# the only record lived in a job nobody reads. A wrong quoting pattern can emit a whole run of these,
# every one launched from a literal, unexpanded variable.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Each case runs in its own OSRC_HOME so "did a job dir appear?" is an exact question.
# cmd_bg is invoked in a SUBSHELL because it `die`s, and die exits the process.
try_bg() {   # <desc> -> echoes "<exit>|<jobdirs>"
  local home; home="$(mktemp -d)"
  local out rc
  out="$( OSRC_HOME="$home" bash "$SRC" bg "$@" 2>&1 )"; rc=$?
  local n; n="$(ls -1d "$home"/jobs/*/ 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s|%s|%s' "$rc" "$n" "$out"
  rm -rf "$home"
}

# --- the literal unexpanded variable: a classic quoting bug, and a phantom-job source ---------------
r="$(try_bg '$cmd' 'some task')"
rc="${r%%|*}"; rest="${r#*|}"; n="${rest%%|*}"; msg="${rest#*|}"
[ "$n" = "0" ] && ok "an unexpanded shell variable mints NO job dir" \
               || bad "a bogus first argument still created $n job dir(s)"
[ "$rc" != "0" ] && ok "it exits non-zero instead of reporting a launch" || bad "exited 0 on a bogus launch"
case "$msg" in *"unexpanded shell variable"*) ok "the error names the actual caller bug (quoting)" ;;
  *) bad "the error does not explain the quoting mistake: $msg" ;; esac
case "$msg" in *"Nothing was started"*) ok "it states plainly that nothing was started" ;;
  *) bad "the caller is not told that nothing started" ;; esac

# --- flags with no task at all ---------------------------------------------------------------------
r="$(try_bg run -m glm)"
rest="${r#*|}"; n="${rest%%|*}"; msg="${rest#*|}"
[ "$n" = "0" ] && ok "a flags-only invocation mints NO job dir" || bad "flags-only created $n job dir(s)"
case "$msg" in *"no task text"*) ok "the error says the task is missing" ;; *) bad "unclear flags-only error"; esac

# --- -m before the verb: the second most common caller mistake -------------------------------------
# This used to die with "unknown subcommand '-m'". It is unambiguous, so it must be ACCEPTED, not
# refused: refusing it costs a whole round trip to teach the caller our argument order.
r="$(try_bg -m glm --dry-run-parse-only 'a real task')"
msg="${r#*|}"; msg="${msg#*|}"
case "$msg" in
  *"unknown subcommand '-m'"*) bad "-m before the verb is still rejected instead of hoisted" ;;
  *) ok "-m before the verb is accepted rather than rejected" ;;
esac

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
