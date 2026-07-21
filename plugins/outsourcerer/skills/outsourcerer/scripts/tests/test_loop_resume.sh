#!/usr/bin/env bash
# test_loop_resume.sh — a loop must be bounded even when the CHECK hangs, and must be resumable.
#
# Two defects this pins down:
#
# 1. The acceptance check ran unbounded (`cout="$(bash -c "$check" 2>&1)"`). The loop's time guard is
#    only consulted BETWEEN attempts, so a check that hangs means --max-minutes never fires at all and
#    a "bounded" loop runs forever. That is the single promise a bounded loop makes.
#
# 2. A loop that stopped without converging (blocked / max_turns / max_time) was a dead end: the task,
#    the check and the accumulated failure feedback were all on disk, but the only way forward was to
#    start again at attempt 1 and pay for the same ground twice.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

. "$SRC" >/dev/null 2>&1
# A suite that silently fails to load the functions passes by doing nothing. Refuse to run blind.
for fn in _loop_check cmd_loop _check_signature; do
  type -t "$fn" >/dev/null || { echo "FAIL: $fn not loaded from $SRC"; exit 1; }
done

export OSRC_HOME="$TMP/state"; mkdir -p "$OSRC_HOME"
SCRIPT_PATH="$TMP/delegate"
DELEGATE_LOG="$TMP/delegate.log"; export DELEGATE_LOG
cat > "$SCRIPT_PATH" <<'EOF'
#!/usr/bin/env bash
printf '%s\n---\n' "$*" >> "$DELEGATE_LOG"
exit 0
EOF
chmod +x "$SCRIPT_PATH"

# ---------------------------------------------------------------------------------------------
# 1. A hung check is killed, recorded as a timeout, and counted as a FAILED attempt.
# ---------------------------------------------------------------------------------------------
_new_job_id() { printf 'timeout-test'; }
t0=$(date +%s)
OSRC_CHECK_TIMEOUT=2 cmd_loop verify -m fake --max 1 --check 'sleep 60' 'exercise timeout' >/dev/null 2>&1
rc=$?
el=$(( $(date +%s) - t0 ))
d="$OSRC_HOME/loops/timeout-test"

[ "$el" -lt 20 ] \
  && ok "a hung acceptance check is bounded (${el}s, not the full 60s sleep)" \
  || bad "the check ran unbounded (${el}s) — --max-minutes can never fire behind a hung check"
[ "$rc" -eq 2 ] \
  && ok "a timed-out check exits non-zero (never mistaken for success)" \
  || bad "timed-out loop exited $rc (expected 2)"
grep -q 'TIMED OUT after 2s' "$d/check-1.out" 2>/dev/null \
  && ok "the timeout is written into the check artifact, so the reason survives the run" \
  || bad "no timeout recorded in check-1.out"
grep -q 'timed out after 2s' "$d/last_fail" 2>/dev/null \
  && ok "last_fail names the timeout rather than an empty failure" \
  || bad "last_fail does not record the timeout"

# The killer must not leave the check's children behind: a leaked `sleep 60` outliving the loop is how
# a "bounded" loop quietly keeps consuming the machine.
sleep 1
if pgrep -f 'sleep 60' >/dev/null 2>&1; then
  bad "the timed-out check left a child process running (kill did not reach the tree)"
else
  ok "the timed-out check's process tree was actually reaped"
fi

# ---------------------------------------------------------------------------------------------
# 2. Resume continues from the saved attempt and feedback instead of restarting at 1.
# ---------------------------------------------------------------------------------------------
: > "$DELEGATE_LOG"
_new_job_id() { printf 'resume-test'; }
cmd_loop verify -m fake --max 1 --check 'printf "first failure\n"; false' 'fix the failure' >/dev/null 2>&1
first_rc=$?
rd="$OSRC_HOME/loops/resume-test"

[ "$first_rc" -eq 2 ] \
  && ok "the initial loop exhausts its single attempt and reports max_turns" \
  || bad "initial loop exited $first_rc (expected 2)"
[ "$(cat "$rd/attempt" 2>/dev/null)" = "1" ] \
  && ok "the stopped loop records the attempt it reached" \
  || bad "attempt state not persisted"
[ -s "$rd/feedback" ] \
  && ok "the failing check output is persisted for a later resume" \
  || bad "no feedback persisted (resume would hand the delegate a blank slate)"

# These calls are EXPECTED to `die`. die exits the process, and cmd_loop is sourced into this one, so
# every refusal case must run in a subshell or the first one silently ends the suite mid-run.
# Refusing to resume without headroom: same ceiling would start at 2 and exit having done nothing.
( cmd_loop resume resume-test --max 1 ) >/dev/null 2>&1 \
  && bad "resume accepted a ceiling that leaves no room to run" \
  || ok "resume refuses a ceiling that is not greater than the original"

( cmd_loop resume resume-test --max 2 ) >/dev/null 2>&1
resume_rc=$?
[ "$(cat "$rd/attempt" 2>/dev/null)" = "2" ] \
  && ok "resume continues at attempt 2 rather than restarting at 1" \
  || bad "resume restarted the count (attempt=$(cat "$rd/attempt" 2>/dev/null))"
grep -q 'first failure' "$DELEGATE_LOG" \
  && ok "the resumed delegate receives the saved failure as feedback" \
  || bad "resumed delegate got no prior feedback (the ground would be re-covered)"
[ "$resume_rc" -eq 3 ] \
  && ok "the stall guard survives the restart: an identical failure stops rather than spins" \
  || bad "resumed loop exited $resume_rc (expected 3 = blocked by the preserved stall guard)"

# A successful loop is not a thing you re-run.
printf 'success\n' > "$rd/state"
( cmd_loop resume resume-test --max 9 ) >/dev/null 2>&1 \
  && bad "resume re-ran a loop that had already succeeded" \
  || ok "resume refuses a loop that already succeeded"

( cmd_loop resume no-such-loop-id ) >/dev/null 2>&1 \
  && bad "resume accepted a loop id that does not exist" \
  || ok "resume refuses an unknown loop id"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
