#!/bin/bash
# test_autodetach.sh — D3 invariant: a non-interactive slow-lane foreground run must auto-detach to
# the bg path so a harness tool-timeout can't kill it mid-run.
#
# The review required four genuine behavioral tests (not vacuous text-presence):
#   1. NEGATIVE CONTROL: actually EXECUTE a sabotaged engine (auto-detach branch removed) on a
#      non-interactive slow-lane run and assert NO job is created (it falls through to _fg_guard).
#   2. FULL RE-ENTRY: drive the real path _bg_launch -> __runjob -> route_delegate with a FAKED
#      model command; assert EXACTLY ONE job + child runs FOREGROUND under OSRC_STREAM=1/OSRC_JOB_DIR
#      (no infinite re-detach), including when OSRC_FORCE_AUTODETACH=1 is inherited.
#   3. TRIGGER TESTS: run with FORCE DISABLED + stdout redirected (non-TTY); assert slow detaches
#      and local/budget does NOT. Add a pseudo-TTY test proving slow stays foreground interactively.
#   4. STATUS/RESULT/WATCH + NONZERO EXIT: drive a fake job through the real bg machinery
#      (run_job/_supervise) with a nonzero fake child exit; assert status/result report the real exit.
# Uses FAKES — never a live model call.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$DIR/outsourcerer.sh"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

TMPDIR_AD="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_AD" 2>/dev/null' EXIT

# ============================================================================
# PART 3 (first, since #2/#4 depend on the fake setup): TRIGGER TESTS
# Run _autodetach_should with FORCE DISABLED + stdout redirected (non-TTY).
# The [ -t 1 ] check reads stdout: if stdout is a file/pipe, [ -t 1 ] is false (non-interactive).
# We run the function inside a subshell with stdout redirected to a file to simulate non-TTY.
# ============================================================================
EXTRACT="$TMPDIR_AD/funcs.sh"
{
  awk '/^die\(\)/,/^}/' "$ENGINE"
  awk '/^have\(\)/,/^}/' "$ENGINE"
  awk '/^_autodetach_should\(\)/,/^}/' "$ENGINE"
} > "$EXTRACT" 2>/dev/null
source "$EXTRACT"

# Helper: run _autodetach_should with stdout redirected to a file (simulates non-TTY).
# Args: <disp> <model-id> <tier> [env-assignments...]
# Returns the rc of _autodetach_should.
_check_should_notty() {
  local disp="$1" mid="$2" mtier="$3"; shift 3
  local _rcf="$TMPDIR_AD/.rc.$$"
  # CRITICAL: unset FORCE so ambient OSRC_FORCE_AUTODETACH=1 in the caller's env can't bypass
  # the lane/tier/TTY classification these tests exist to prove. The subshell must NOT inherit FORCE.
  ( unset OSRC_FORCE_AUTODETACH; export "$@"; _autodetach_should "$disp" "$mid" "$mtier" >/dev/null 2>&1; echo $? > "$_rcf" )
  local rc; rc="$(cat "$_rcf" 2>/dev/null || echo 1)"; rm -f "$_rcf"
  return "$rc"
}

# Helper: run _autodetach_should with a PSEUDO-TTY allocated via `script` (simulates interactive).
# On macOS, `script -q /dev/null bash -c '...'` allocates a PTY so [ -t 1 ] is true.
# IMPORTANT: do NOT redirect stdout inside the script command — the PTY IS the stdout.
# We redirect stderr to /dev/null only (stderr is not what [ -t 1 ] checks).
# Args: <disp> <model-id> <tier> [env-assignments...]
_check_should_tty() {
  local disp="$1" mid="$2" mtier="$3"; shift 3
  local _rcf="$TMPDIR_AD/.rc.$$"
  # Build the env-export + function call. source the extract inside the subshell.
  local _envs=""; local e; for e in "$@"; do _envs="$_envs export $e;"; done
  if command -v script >/dev/null 2>&1; then
    # macOS `script -q /dev/null` / Linux `script -qec` — try both forms.
    # NO stdout redirect on _autodetach_should — the PTY must be stdout so [ -t 1 ] is true.
    if script -q /dev/null bash -c "source '$EXTRACT'; $_envs _autodetach_should '$disp' '$mid' '$mtier' 2>/dev/null; echo \$? > '$_rcf'" 2>/dev/null; then
      :
    elif script -qec "source '$EXTRACT'; $_envs _autodetach_should '$disp' '$mid' '$mtier' 2>/dev/null; echo \$? > '$_rcf'" /dev/null 2>/dev/null; then
      :
    else
      echo "SKIP-TTY" > "$_rcf"
    fi
  else
    echo "SKIP-TTY" > "$_rcf"
  fi
  local rc; rc="$(cat "$_rcf" 2>/dev/null || echo "SKIP-TTY")"; rm -f "$_rcf"
  [ "$rc" = "SKIP-TTY" ] && return 99
  return "$rc"
}

echo "=== PART 3: Trigger tests (FORCE disabled, real TTY/non-TTY detection) ==="

# (3a) Non-TTY + cloud lane (ccor) + mid tier -> SHOULD detach.
_check_should_notty ccor glm-5.2 mid OSRC_NO_AUTODETACH=0 OSRC_STREAM=0 OSRC_JOB_DIR=
rc=$?
[ "$rc" -eq 0 ] && ok "trigger(notty): cloud lane (ccor) + mid -> detaches" \
                || no "trigger(notty): cloud lane should detach (rc=$rc)"

# (3b) Non-TTY + codex-native (cxnative) + frontier -> SHOULD detach.
_check_should_notty cxnative sol frontier OSRC_NO_AUTODETACH=0 OSRC_STREAM=0 OSRC_JOB_DIR=
rc=$?
[ "$rc" -eq 0 ] && ok "trigger(notty): codex-native (cxnative) + frontier -> detaches" \
                || no "trigger(notty): codex-native should detach (rc=$rc)"

# (3c) Non-TTY + devin lane + capable -> SHOULD detach (any cloud lane).
_check_should_notty devin glm-5.2 capable OSRC_NO_AUTODETACH=0 OSRC_STREAM=0 OSRC_JOB_DIR=
rc=$?
[ "$rc" -eq 0 ] && ok "trigger(notty): devin (cloud) + capable -> detaches" \
                || no "trigger(notty): devin cloud lane should detach (rc=$rc)"

# (3d) Non-TTY + local lane -> should NOT detach (fast, no network).
_check_should_notty local ollama:llama3 budget OSRC_NO_AUTODETACH=0 OSRC_STREAM=0 OSRC_JOB_DIR=
rc=$?
[ "$rc" -ne 0 ] && ok "trigger(notty): local lane -> stays foreground" \
                || no "trigger(notty): local lane should stay foreground (rc=$rc)"

# (3e) Non-TTY + budget tier + cloud -> should NOT detach (quick model).
_check_should_notty ccor haiku budget OSRC_NO_AUTODETACH=0 OSRC_STREAM=0 OSRC_JOB_DIR=
rc=$?
[ "$rc" -ne 0 ] && ok "trigger(notty): budget tier (quick) + cloud -> stays foreground" \
                || no "trigger(notty): budget tier should stay foreground (rc=$rc)"

# (3f) Non-TTY + OSRC_STREAM=1 (already bg) -> should NOT detach (fork-bomb guard).
_check_should_notty ccor glm-5.2 mid OSRC_NO_AUTODETACH=0 OSRC_STREAM=1 OSRC_JOB_DIR=
rc=$?
[ "$rc" -ne 0 ] && ok "trigger(notty): OSRC_STREAM=1 (already bg) -> stays foreground (no fork-bomb)" \
                || no "trigger(notty): OSRC_STREAM=1 should not re-detach (rc=$rc)"

# (3g) Non-TTY + OSRC_NO_AUTODETACH=1 -> forces foreground even for slow cloud lane.
_check_should_notty ccor glm-5.2 frontier OSRC_NO_AUTODETACH=1 OSRC_STREAM=0 OSRC_JOB_DIR=
rc=$?
[ "$rc" -ne 0 ] && ok "escape hatch(notty): OSRC_NO_AUTODETACH=1 forces foreground" \
                || no "escape hatch(notty): OSRC_NO_AUTODETACH=1 should force foreground (rc=$rc)"

# (3h) PSEUDO-TTY: slow cloud lane + interactive (PTY) -> should NOT detach.
_check_should_tty ccor glm-5.2 frontier OSRC_NO_AUTODETACH=0 OSRC_STREAM=0 OSRC_JOB_DIR= OSRC_FORCE_AUTODETACH=0
rc=$?
if [ "$rc" -eq 99 ]; then
  echo "SKIP: pseudo-TTY test (script command unavailable on this platform)"
elif [ "$rc" -ne 0 ]; then
  ok "trigger(tty): slow cloud lane + interactive (PTY) -> stays foreground"
else
  no "trigger(tty): slow cloud lane should stay foreground interactively (rc=$rc)"
fi

# ============================================================================
# PART 2 + 4: FULL RE-ENTRY through the REAL engine with a FAKED model command.
# Strategy: create a fake `devin` on PATH that handles `auth status` + the model call.
# Run the REAL engine: `outsourcerer.sh run -m glm-5.2 "test"` with stdout redirected (non-TTY)
# + OSRC_CLOUD_ACK=1. This triggers:
#   route_delegate -> _autodetach_should (non-TTY + cloud + capable) -> _autodetach_run ->
#   _bg_launch -> nohup __runjob -> run_job -> _supervise ->
#   outsourcerer.sh --provider devin run -m glm-5.2 "test" (with OSRC_STREAM=1) ->
#   route_delegate -> _autodetach_should (OSRC_STREAM=1 -> return 1, no re-detach) ->
#   delegate() -> fake devin (exits with nonzero code)
# Then assert: EXACTLY ONE job created, child ran foreground (no re-detach), status/result
# report the real nonzero exit.
# ============================================================================
echo ""
echo "=== PART 2+4: Full re-entry through real engine (faked devin, nonzero exit) ==="

# Create the fake devin binary. It must:
# - `auth status` -> print "Logged in" (for logged_in check)
# - `--model X --permission-mode Y -p "task"` -> echo a fake result + OSRC::DONE, exit with
#   a NONZERO code (to test the exit-status contract)
# CRITICAL: the engine does `export PATH="$HOME/.local/bin:$PATH"` at line 85, which prepends
# ~/.local/bin AFTER any PATH we set. So the real devin at ~/.local/bin/devin would shadow our
# fake. Fix: set HOME to a temp dir and put the fake devin at $HOME/.local/bin/devin so the
# engine's PATH prepend finds OUR fake, not the real one.
FAKE_HOME="$TMPDIR_AD/fake-home"
FAKE_BIN="$FAKE_HOME/.local/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/devin" <<'FAKE_DEVIN'
#!/bin/bash
# Fake devin CLI for testing. Never makes a real API call.
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  echo "Logged in as test-user"
  exit 0
fi
# Model call: echo a fake result + OSRC::DONE marker, then exit NONZERO (test exit contract).
echo "FAKE DEVIN RESULT: test task completed"
echo "OSRC::DONE"
exit 7
FAKE_DEVIN
chmod +x "$FAKE_BIN/devin"

# Set up an isolated OSRC_HOME so we can count jobs precisely.
REENTRY_HOME="$TMPDIR_AD/reentry-home"
REENTRY_JOBS="$REENTRY_HOME/jobs"
mkdir -p -m 700 "$REENTRY_HOME"

# Run the REAL engine with HOME set to our fake home (so ~/.local/bin/devin is the fake),
# stdout redirected (non-TTY), cloud acked.
# OSRC_FORCE_AUTODETACH=1 ensures detach even if the test runner has a TTY on stdout.
# OSRC_POLL=1 makes _supervise poll every 1s so the job finishes quickly for the test.
# The fake devin exits 7 (nonzero) so we can test the exit-status contract in Part 4.
# OSRC_CATALOG_VALIDATE=0: this test's fake devin stubs `auth status` + the model call but NOT
# `devin models list --format json` (the catalog probe). With the gate on, the child's
# extra `devin models list` call to the fake binary disrupts the re-entry flow the test is
# asserting. Catalog validation has its own coverage; disable it here so this test isolates the
# autodetach/re-entry mechanics. (In production the real `devin models list` works fine.)
# OSRC_REQUIRE_INTERACTIVE=0: the default (ON) routes auto-detach to an interactive tmux session,
# not the bg path. This test exercises the bg re-entry path (fork-bomb guard, exit contract,
# status/result/watch), so it needs the headless bg opt-out. The interactive tmux path has its
# own dedicated suite (test_require_interactive.sh).
REENTRY_OUTPUT="$(HOME="$FAKE_HOME" \
  OSRC_HOME="$REENTRY_HOME" \
  OSRC_CLOUD_ACK=1 OSRC_CLOUD_ACKED=1 \
  OSRC_FORCE_AUTODETACH=1 \
  OSRC_REQUIRE_INTERACTIVE=0 \
  OSRC_POLL=1 \
  OSRC_CATALOG_VALIDATE=0 \
  OUTSOURCERER_DEPTH=0 \
  bash "$ENGINE" run -m glm-5.2 "test task" 2>"$TMPDIR_AD/reentry-stderr" </dev/null)"
REENTRY_RC=$?
REENTRY_STDERR="$(cat "$TMPDIR_AD/reentry-stderr" 2>/dev/null)"

# (2a) The engine returned 0 (auto-detach launch succeeded) and printed a job id.
REENTRY_JOB_ID="$(printf '%s' "$REENTRY_OUTPUT" | tail -1)"
if [ "$REENTRY_RC" -eq 0 ] && [ -n "$REENTRY_JOB_ID" ] && [ -d "$REENTRY_JOBS/$REENTRY_JOB_ID" ]; then
  ok "re-entry: engine returned 0 + job id ($REENTRY_JOB_ID) + job dir exists"
else
  no "re-entry: engine failed (rc=$REENTRY_RC, output=[$REENTRY_OUTPUT], jobdir=$([ -d "$REENTRY_JOBS/$REENTRY_JOB_ID" ] && echo yes || echo no))"
  # Debug: show stderr to help diagnose
  printf '   stderr: %.200s\n' "$REENTRY_STDERR" >&2
fi

# EMPTY-JOB-ID GUARD: if the job id is empty, every downstream status/watch/result assertion that
# uses it is vacuous (grep -q "" matches anything). Fail hard here so the rest of Part 4 is skipped
# with a clear signal, not silently passing on empty-string matches.
if [ -z "$REENTRY_JOB_ID" ]; then
  no "FATAL: REENTRY_JOB_ID is empty — all Part 4 status/watch/result assertions would be vacuous (grep -q '' matches anything). Aborting Part 4."
fi

# (2b) EXACTLY ONE job was created (no fork-bomb / re-detach loop).
JOB_COUNT="$(find "$REENTRY_JOBS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
if [ "$JOB_COUNT" -eq 1 ]; then
  ok "re-entry: exactly ONE job created (no fork-bomb / re-detach loop)"
else
  no "re-entry: expected 1 job, found $JOB_COUNT (fork-bomb?)"
  ls -la "$REENTRY_JOBS" 2>/dev/null | head -10 >&2
fi

# (2c) The child ran FOREGROUND (no re-detach): the job's out.log should contain the fake devin
# output (FAKE DEVIN RESULT), proving the child reached delegate() -> devin, not another detach.
# Wait for the job to finish (fake devin exits immediately, but _supervise polls every 1s).
sleep 5
JOB_OUTLOG="$REENTRY_JOBS/$REENTRY_JOB_ID/out.log"
if [ -f "$JOB_OUTLOG" ] && grep -q "FAKE DEVIN RESULT" "$JOB_OUTLOG" 2>/dev/null; then
  ok "re-entry: child ran foreground (out.log has fake devin output, no re-detach)"
else
  no "re-entry: child did not reach fake devin (out.log missing or no FAKE DEVIN RESULT)"
  [ -f "$JOB_OUTLOG" ] && printf '   out.log: %.200s\n' "$(cat "$JOB_OUTLOG" 2>/dev/null)" >&2
fi

# (2d) The auto-detach receipt was printed to stderr.
if printf '%s' "$REENTRY_STDERR" | grep -q '\[auto-detach\]'; then
  ok "re-entry: auto-detach receipt printed to stderr"
else
  no "re-entry: auto-detach receipt missing from stderr"
fi

# (2e) FORK-BOMB GUARD with inherited OSRC_FORCE_AUTODETACH=1: the child re-enters route_delegate
# with OSRC_FORCE_AUTODETACH=1 inherited from the parent env, BUT OSRC_STREAM=1 is set by run_job
# BEFORE the child re-enters, so _autodetach_should must return 1 (no re-detach) despite FORCE.
# We already asserted exactly ONE job above; this is the explicit assertion that FORCE does NOT
# override the OSRC_STREAM guard. (If it did, we'd see 2+ jobs — a fork-bomb.)
if [ "$JOB_COUNT" -eq 1 ]; then
  ok "re-entry: OSRC_FORCE_AUTODETACH=1 inherited by child but OSRC_STREAM=1 guard prevents re-detach"
else
  no "re-entry: OSRC_STREAM=1 guard failed to prevent re-detach despite FORCE (fork-bomb)"
fi

# ============================================================================
# PART 4: Exercise real status/watch/result commands + nonzero fake child exit.
# The job from Part 2 used a fake devin that exits 7 (nonzero). _supervise captures this
# and writes "failed" + exit code 7 to the job dir. We run the REAL status/result/watch
# commands and assert they report the real (nonzero) exit.
# ============================================================================
echo ""
echo "=== PART 4: Real status/result/watch + nonzero exit ==="

# Wait for _supervise to finish (polls every 1s with OSRC_POLL=1, fake devin exits immediately).
sleep 8

# (4a) status command reports the job AND its terminal 'failed' state (not just the job ID).
# Sol: the old assert only checked the output contains the job ID — `grep -q ""` on an empty ID
# matches anything. Now: require non-empty ID, assert the output contains BOTH the ID and 'failed'.
if [ -n "$REENTRY_JOB_ID" ]; then
  STATUS_OUTPUT="$(HOME="$FAKE_HOME" OSRC_HOME="$REENTRY_HOME" bash "$ENGINE" status "$REENTRY_JOB_ID" 2>/dev/null)"
  if printf '%s' "$STATUS_OUTPUT" | grep -q "$REENTRY_JOB_ID" && printf '%s' "$STATUS_OUTPUT" | grep -q 'failed'; then
    ok "status: human output reports job $REENTRY_JOB_ID with terminal 'failed' state"
  else
    no "status: output missing job ID or 'failed' state (output=[$STATUS_OUTPUT])"
  fi
else
  no "status: REENTRY_JOB_ID is empty — assertion skipped (would be vacuous)"
fi

# (4b) The job status is "failed" (nonzero exit from fake devin).
JOB_STATUS="$(cat "$REENTRY_JOBS/$REENTRY_JOB_ID/status" 2>/dev/null || echo '?')"
if [ "$JOB_STATUS" = "failed" ]; then
  ok "status: job status is 'failed' (nonzero exit from fake devin correctly classified)"
else
  no "status: job status should be 'failed', got '$JOB_STATUS'"
fi

# (4c) The exit code is 7 (the fake devin's exit code).
JOB_EXIT="$(cat "$REENTRY_JOBS/$REENTRY_JOB_ID/exit" 2>/dev/null || echo '?')"
if [ "$JOB_EXIT" = "7" ]; then
  ok "exit contract: job exit code is 7 (fake devin's real nonzero exit preserved)"
else
  no "exit contract: job exit code should be 7, got '$JOB_EXIT'"
fi

# (4d) result command prints the fake devin's output (last.txt or out.log tail).
if [ -n "$REENTRY_JOB_ID" ]; then
  RESULT_OUTPUT="$(HOME="$FAKE_HOME" OSRC_HOME="$REENTRY_HOME" bash "$ENGINE" result "$REENTRY_JOB_ID" 2>/dev/null)"
  if printf '%s' "$RESULT_OUTPUT" | grep -q "FAKE DEVIN RESULT"; then
    ok "result: command prints the fake devin output (FAKE DEVIN RESULT)"
  else
    no "result: command did not print fake devin output (output=[$RESULT_OUTPUT])"
  fi
else
  no "result: REENTRY_JOB_ID is empty — assertion skipped (would be vacuous)"
fi

# (4e) watch --for 5 returns (doesn't hang) and shows the terminal 'failed' state.
# Sol: the old assert only checked rc=0 + job ID presence — it would pass even if watch printed
# only the ID or incorrectly showed 'running'. Now: require non-empty ID, assert the output
# contains BOTH the ID and the terminal 'failed' state.
if [ -n "$REENTRY_JOB_ID" ]; then
  WATCH_OUTPUT="$(HOME="$FAKE_HOME" OSRC_HOME="$REENTRY_HOME" OSRC_POLL=1 bash "$ENGINE" watch "$REENTRY_JOB_ID" --for 5 2>/dev/null)"
  WATCH_RC=$?
  if [ "$WATCH_RC" -eq 0 ] && printf '%s' "$WATCH_OUTPUT" | grep -q "$REENTRY_JOB_ID" && printf '%s' "$WATCH_OUTPUT" | grep -q 'failed'; then
    ok "watch --for 5: returns 0 + shows job with terminal 'failed' state (not just the ID)"
  else
    no "watch --for 5: missing job ID or 'failed' state (rc=$WATCH_RC, output=[$WATCH_OUTPUT])"
  fi
else
  no "watch: REENTRY_JOB_ID is empty — assertion skipped (would be vacuous)"
fi

# (4f) status --json reports the job with correct exit code.
if command -v jq >/dev/null 2>&1; then
  if [ -n "$REENTRY_JOB_ID" ]; then
    JSON_OUTPUT="$(HOME="$FAKE_HOME" OSRC_HOME="$REENTRY_HOME" bash "$ENGINE" status --json "$REENTRY_JOB_ID" 2>/dev/null)"
    JSON_EXIT="$(printf '%s' "$JSON_OUTPUT" | jq -r '.exit // .exit_code // empty' 2>/dev/null)"
    if [ "$JSON_EXIT" = "7" ]; then
      ok "status --json: reports exit code 7 (nonzero exit in machine-readable form)"
    else
      no "status --json: exit code should be 7, got '$JSON_EXIT' (output=[$JSON_OUTPUT])"
    fi
  else
    no "status --json: REENTRY_JOB_ID is empty — assertion skipped (would be vacuous)"
  fi
else
  echo "SKIP: status --json test (jq unavailable)"
fi

# ============================================================================
# PART 1: REAL NEGATIVE CONTROL — execute a SABOTAGED engine (auto-detach branch removed)
# on a non-interactive slow-lane run and assert NO job is created (it falls through to _fg_guard).
# This proves the test would catch a regression that removes the auto-detach routing.
# ============================================================================
echo ""
echo "=== PART 1: Real negative control (sabotaged engine, no auto-detach) ==="

# Create a sabotaged copy of the engine with the auto-detach branch removed from route_delegate.
SABOTAGED="$TMPDIR_AD/sabotaged-engine.sh"
sed '/if _autodetach_should/,/^  fi$/d' "$ENGINE" > "$SABOTAGED" 2>/dev/null
chmod +x "$SABOTAGED"

# Verify the sabotage worked: the `if _autodetach_should` call is GONE from route_delegate.
SAB_RD_START=$(grep -n '^route_delegate()' "$SABOTAGED" | head -1 | cut -d: -f1)
# Scan the WHOLE route_delegate body (until the next top-level function definition), not a fixed
# line window — the function grows over time and a magic +200 silently drifts off the branch.
SAB_HAS_AUTODETACH=$(awk -v s="$SAB_RD_START" 'NR>s { if (/^[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{/) exit; if (/if _autodetach_should/){print NR; exit} }' "$SABOTAGED")
if [ -n "$SAB_HAS_AUTODETACH" ]; then
  no "negative control: sabotage failed (auto-detach branch still present in route_delegate)"
else
  # Set up an isolated OSRC_HOME for the sabotaged run.
  SAB_HOME="$TMPDIR_AD/sab-home"
  SAB_JOBS="$SAB_HOME/jobs"
  mkdir -p -m 700 "$SAB_HOME"

  # EXECUTE the sabotaged engine on a non-interactive slow-lane run (same as Part 2 but no auto-detach).
  # With the branch removed, route_delegate falls through to _fg_guard -> __osrc_fg_dispatch -> delegate()
  # -> fake devin. NO job should be created in SAB_JOBS (the run is foreground, not detached).
  # We use OSRC_FG_GUARD=0 so _fg_guard runs inline (no fifo watchdog) for a clean foreground run.
  SAB_OUTPUT="$(HOME="$FAKE_HOME" \
    OSRC_HOME="$SAB_HOME" \
    OSRC_CLOUD_ACK=1 OSRC_CLOUD_ACKED=1 \
    OSRC_FORCE_AUTODETACH=1 \
    OSRC_REQUIRE_INTERACTIVE=0 \
    OUTSOURCERER_DEPTH=0 \
    OSRC_FG_GUARD=0 \
    bash "$SABOTAGED" run -m glm-5.2 "test task" 2>"$TMPDIR_AD/sab-stderr" </dev/null)"
  SAB_RC=$?

  # Count jobs in the sabotaged run's OSRC_HOME. Should be ZERO (no auto-detach -> no bg job).
  SAB_JOB_COUNT="$(find "$SAB_JOBS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"

  if [ "$SAB_JOB_COUNT" -eq 0 ]; then
    ok "negative control: sabotaged engine created ZERO jobs (auto-detach removed -> foreground, no detach)"
  else
    no "negative control: sabotaged engine created $SAB_JOB_COUNT job(s) — auto-detach not fully removed?"
  fi

  # The sabotaged engine should still have run the fake devin (foreground), so output has FAKE DEVIN RESULT.
  if printf '%s' "$SAB_OUTPUT" | grep -q "FAKE DEVIN RESULT"; then
    ok "negative control: sabotaged engine ran foreground (fake devin output present, no detach)"
  else
    no "negative control: sabotaged engine did not run foreground (output=[$SAB_OUTPUT])"
  fi

  # Contrast: the REAL engine (Part 2) created ONE job. The sabotaged engine created ZERO.
  # This proves the test catches the regression: removing the auto-detach branch changes the
  # observable behavior (job created vs not created).
  if [ "$JOB_COUNT" -eq 1 ] && [ "$SAB_JOB_COUNT" -eq 0 ]; then
    ok "negative control: behavioral contrast confirmed (real=1 job, sabotaged=0 jobs -> test catches regression)"
  else
    no "negative control: no behavioral contrast (real=$JOB_COUNT, sabotaged=$SAB_JOB_COUNT)"
  fi
fi

# Also verify the REAL engine still HAS the branch (sabotage didn't affect the original).
REAL_RD_START=$(grep -n '^route_delegate()' "$ENGINE" | head -1 | cut -d: -f1)
REAL_HAS_AUTODETACH=$(awk -v s="$REAL_RD_START" 'NR>s { if (/^[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{/) exit; if (/if _autodetach_should/){print NR; exit} }' "$ENGINE")
if [ -n "$REAL_HAS_AUTODETACH" ]; then
  ok "negative control: real engine still has the auto-detach branch (unaffected by sabotage)"
else
  no "negative control: real engine LOST the auto-detach branch (sabotage affected the original!)"
fi

# ============================================================================
# Structural tests (kept from before — they're cheap and catch wiring regressions)
# ============================================================================
echo ""
echo "=== Structural tests ==="

grep -q 'local tier="$1" verb="$2"; shift 2' "$ENGINE" \
  && ok "structural: route_delegate accepts verb as 2nd arg" \
  || no "structural: route_delegate missing verb arg"

grep -q -- '--wait|--foreground) OSRC_NO_AUTODETACH=1' "$ENGINE" \
  && ok "structural: --wait/--foreground flag wired into _consume_flags" \
  || no "structural: --wait/--foreground flag missing from _consume_flags"

grep -A5 '^_autodetach_run()' "$ENGINE" | grep -q '_bg_launch' \
  && ok "structural: _autodetach_run reuses _bg_launch (existing bg machinery)" \
  || no "structural: _autodetach_run does not reuse _bg_launch"

grep -q 'route_delegate "auto" "\$cmd"' "$ENGINE" \
  && ok "structural: main() passes verb (\$cmd) to route_delegate" \
  || no "structural: main() missing verb arg to route_delegate"

# second_opinion is now any-lane (both opinions resolve their own lane/id/tier), so it consults
# _autodetach_should per opinion lane ($_l1 / $_l2) instead of a hardcoded `ccor`.
grep -q '_autodetach_should "\$_l1" "\$_id1" "\$_t1"' "$ENGINE" \
  && grep -q '_autodetach_should "\$_l2" "\$_id2" "\$_t2"' "$ENGINE" \
  && ok "structural: second_opinion has an auto-detach branch for both opinion lanes" \
  || no "structural: second_opinion missing per-lane auto-detach branch"

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
