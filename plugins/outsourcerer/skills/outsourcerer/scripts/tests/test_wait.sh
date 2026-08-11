#!/usr/bin/env bash
# test_wait.sh — the `wait <job-id> [--for N]` verb: BLOCK until a job reaches a terminal state,
# then exit with an HONEST code. The return code is the contract:
#   0   done | done?
#   3   blocked | permission-blocked
#   1   failed | wedged | timeout | interrupted | canceled
#   124 --for N elapsed while the job is STILL LIVE (non-terminal)
#
# Self-contained: sources the script with OSRC_SOURCED=1, points OSRC_HOME/OSRC_JOBS at a temp
# dir, builds fake job dirs, and drives the status file (plus the pid/pid_start that
# _reconcile_status reads) so every exit code is asserted deterministically WITHOUT real long
# sleeping. The one timed case uses --for 1 + OSRC_POLL=1, so the whole suite stays sub-second
# aside from that single ~1s cap.
#
# Run: bash test_wait.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-wait.XXXXXX")"; trap 'rm -rf "$TMP"; [ -n "${SLEEP_PID:-}" ] && kill "$SLEEP_PID" 2>/dev/null || true' EXIT

# OSRC_HOME must be set BEFORE sourcing: outsourcerer.sh pins OSRC_HOME/OSRC_JOBS at source time.
# OSRC_SOURCED=1 keeps the source guard from running main().
export OSRC_HOME="$TMP/home"
export OSRC_SOURCED=1
mkdir -p "$OSRC_HOME/jobs"
. "$SRC" >/dev/null 2>&1

# Refuse a false green: if the function under test did not load, the assertions would silently no-op.
type -t cmd_wait           >/dev/null || { echo "FAIL: cmd_wait not loaded";           exit 1; }
type -t _reconcile_status  >/dev/null || { echo "FAIL: _reconcile_status not loaded";  exit 1; }
type -t _status_line       >/dev/null || { echo "FAIL: _status_line not loaded";       exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

OSRC_JOBS="$OSRC_HOME/jobs"

# make_job <jid> <status> — writes status + a minimal meta.json + an empty out.log so _status_line's
# heartbeat has something to read without crashing. Terminal states need nothing else: _reconcile_status
# passes them through untouched (it only rewrites running|stalled?|exploring?|launching).
make_job() {
  local jid="$1" st="$2"
  local jd="$OSRC_JOBS/$jid"
  mkdir -p "$jd"
  printf '%s\n' "$st" > "$jd/status"
  printf '{"id":"%s","model":"glm-5-2","verb":"edit","provider":"devin","started":1700000000}\n' "$jid" > "$jd/meta.json"
  : > "$jd/out.log"
  date +%s > "$jd/started_at"
}

# --- Build one fake job per case. ---
make_job "j-done"    "done"
make_job "j-doneq"   "done?"
make_job "j-perm"    "permission-blocked"
make_job "j-failed"  "failed"

# A job that STAYS live: _reconcile_status returns `running` only while the delegate pid is alive
# (and pid_start matches, or is empty for the legacy fallback). Spawn a real background sleep and
# write its pid; leave pid_start empty so the legacy branch keeps _alive=1 for the cap window.
make_job "j-run" "running"
sleep 30 & SLEEP_PID=$!
printf '%s\n' "$SLEEP_PID" > "$OSRC_JOBS/j-run/pid"

# --- Helper: run cmd_wait, capture ONLY the return code (heartbeats go to stderr). ---
wait_rc() { local rc=0; cmd_wait "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

# --- Already-terminal jobs return their mapped code on the FIRST iteration (no sleeping). ---
rc="$(wait_rc j-done)"
[ "$rc" = "0" ] && ok "j-done: wait returns 0 (done)" || bad "j-done: expected 0, got $rc"

rc="$(wait_rc j-doneq)"
[ "$rc" = "0" ] && ok "j-doneq: wait returns 0 (done?)" || bad "j-doneq: expected 0, got $rc"

rc="$(wait_rc j-perm)"
[ "$rc" = "3" ] && ok "j-perm: wait returns 3 (permission-blocked)" || bad "j-perm: expected 3, got $rc"

rc="$(wait_rc j-failed)"
[ "$rc" = "1" ] && ok "j-failed: wait returns 1 (failed)" || bad "j-failed: expected 1, got $rc"

# --- A job that stays live with --for 1 hits the cap while non-terminal -> 124. ---
# OSRC_POLL=1 so the loop wakes at 1s; the cap is wall-clock from invocation, so this returns in
# ~1s (never sleeps the full 30s of the backing process).
rc="$(OSRC_POLL=1 wait_rc j-run --for 1)"
[ "$rc" = "124" ] && ok "j-run --for 1: wait returns 124 (cap elapsed while still live)" || bad "j-run --for 1: expected 124, got $rc"

# --- Sanity: _reconcile_status actually reported j-run as running during that window, not a
# terminal state that would have short-circuited the cap. If reconcile flipped it (e.g. the pid
# died), the 124 above would be a lie. Confirm the backing pid is still alive AND reconcile still
# says running.
kill -0 "$SLEEP_PID" 2>/dev/null && ok "j-run: backing pid still alive (cap was genuine)" || bad "j-run: backing pid died mid-test"
live_st="$(_reconcile_status j-run 2>/dev/null || printf '?')"
[ "$live_st" = "running" ] && ok "j-run: _reconcile_status still reports running (124 was honest)" || bad "j-run: _reconcile_status reported '$live_st', not running"

# --- Argument validation: --for with a non-integer must die (exit 1 via die), not loop forever. ---
bad_rc=0
( OSRC_POLL=1 cmd_wait j-run --for notanumber >/dev/null 2>&1 ) || bad_rc=$?
[ "$bad_rc" -ne 0 ] && ok "wait --for notanumber: rejected (rc=$bad_rc)" || bad "wait --for notanumber: accepted (rc=0)"

# --- F3: --for may appear FLAGS-FIRST (id after the flag), not only positionally as $2/$3. ---
rc="$(OSRC_POLL=1 wait_rc --for 1 j-run)"
[ "$rc" = "124" ] && ok "wait --for 1 j-run (flags first): 124" || bad "flags-first --for: expected 124, got $rc"

# --- F3: --for 0 = check once now -> immediate 124 on a live job (NOT an infinite wait). ---
t0=$(date +%s); rc="$(OSRC_POLL=1 wait_rc j-run --for 0)"; el=$(( $(date +%s) - t0 ))
{ [ "$rc" = "124" ] && [ "$el" -lt 3 ]; } && ok "wait --for 0 on live job: immediate 124 (${el}s)" || bad "--for 0: expected fast 124, got rc=$rc in ${el}s"

# --- F1: a NON-terminal job whose worker pid is DEAD is an orphan -> wait returns 1 fast, never
# hangs. (Whether _reconcile_status flips it to a terminal state or the orphan guard fires, the
# contract is: rc 1, bounded time.) ---
make_job "j-orphan" "stalled?"
printf '999999\n' > "$OSRC_JOBS/j-orphan/pid"          # a pid that is not alive
printf 'bogus start\n' > "$OSRC_JOBS/j-orphan/pid_start"
orc=0; t0=$(date +%s)
( OSRC_POLL=1 cmd_wait j-orphan >/dev/null 2>&1 ) || orc=$?
el=$(( $(date +%s) - t0 ))
{ [ "$orc" = "1" ] && [ "$el" -lt 8 ]; } && ok "j-orphan: dead-worker non-terminal -> rc 1 in ${el}s (no hang)" || bad "j-orphan: expected rc 1 fast, got rc=$orc in ${el}s"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
