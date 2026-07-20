#!/usr/bin/env bash
# test_devin_printmode_hang.sh — _supervise must abort a headless devin that hits
# "Print mode: rejecting tool exec that requires confirmation" immediately with
# status=permission-blocked (exit 3), instead of waiting for the byte-growth
# stall-kill (default 900s/15min for capable tier).
#
# Root cause this guards: a headless devin (`-p` / print mode) that attempts a
# tool exec requiring confirmation cannot prompt, so it rejects the tool and
# then HANGS — it does not exit, it does not retry, it goes silent. Observed in
# the wild on long-running background jobs: devin finishes its file writes in
# 3-6 minutes, hits this rejection on a final validation/commit command, and
# then sits idle for 2-5 hours until an external reaper kills the shell with an
# ambiguous "killed" status. The byte-growth stall-kill would eventually catch
# it (15 min), but that wastes a quarter-hour on a process that is already
# dead-in-the-water. A single occurrence is a reliable death signal, so we abort
# immediately.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"
export OSRC_HOME="$TMP"
export HOME="$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Source the main script for function access (same technique as test_hardening.sh).
. "$SRC" >/dev/null 2>&1

# --- Scenario 1: source-level — the print-mode rejection check is wired into _supervise. ---
grep -aq "Print mode: rejecting tool exec that requires confirmation" "$SRC" \
  && ok "source: _supervise detects devin print-mode rejection string" \
  || bad "source: print-mode rejection detection missing from _supervise"
grep -aq 'OSRC_NO_PRINTMODE_ABORT' "$SRC" \
  && ok "source: print-mode abort has an opt-out (OSRC_NO_PRINTMODE_ABORT)" \
  || bad "source: no opt-out for print-mode abort"

# --- Scenario 2: runtime — a delegate that emits the print-mode rejection then hangs
# is aborted with status=permission-blocked + exit 3, well before the stall-kill window. ---
# Fake delegate: writes the exact devin log line, then sleeps forever (simulates the hang).
FAKE_DELEGATE="$TMP/fake-delegate.sh"
cat > "$FAKE_DELEGATE" <<'EOF'
#!/usr/bin/env bash
echo "2026-07-19T04:31:25.494338Z  INFO chisel::repl::handler: Print mode: rejecting tool exec that requires confirmation"
sleep 3600
EOF
chmod +x "$FAKE_DELEGATE"

# Use short windows so the test finishes fast. stall-kill=60s would be the fallback if
# our check didn't fire; the test should finish in ~OSRC_POLL seconds, not 60s.
jd="$TMP/jobs/printmode-hang"
mkdir -p -m 700 "$jd"
echo '{"verb":"edit"}' > "$jd/meta.json"

OSRC_POLL=1 _supervise "$jd" 5 60 120 -- "$FAKE_DELEGATE" >/dev/null 2>&1
rc=$?

if [ "$rc" -eq 3 ]; then
  ok "runtime: print-mode hang aborted with exit 3 (permission-blocked)"
else
  bad "runtime: expected exit 3, got $rc (stall-kill would be 125, timeout 124)"
fi

status="$(cat "$jd/status" 2>/dev/null)"
if [ "$status" = "permission-blocked" ]; then
  ok "runtime: job status is 'permission-blocked'"
else
  bad "runtime: job status is '$status' (expected 'permission-blocked')"
fi

# --- Scenario 3: the opt-out disables the fast abort; the stall-kill backstop still applies.
# This proves the check is gated by OSRC_NO_PRINTMODE_ABORT, not unconditional. ---
jd2="$TMP/jobs/printmode-optout"
mkdir -p -m 700 "$jd2"
echo '{"verb":"edit"}' > "$jd2/meta.json"

# With the opt-out set, the print-mode check is skipped. Use a short stall-kill (3s) so
# the test finishes fast via the wedged backstop, proving the opt-out actually disabled
# the fast abort (otherwise we'd get exit 3 in ~1s, not exit 125 in ~3s).
OSRC_POLL=1 OSRC_NO_PRINTMODE_ABORT=1 _supervise "$jd2" 2 3 120 -- "$FAKE_DELEGATE" >/dev/null 2>&1
rc2=$?
status2="$(cat "$jd2/status" 2>/dev/null)"

if [ "$rc2" -eq 125 ]; then
  ok "opt-out: with OSRC_NO_PRINTMODE_ABORT=1, falls through to stall-kill (exit 125, wedged)"
else
  bad "opt-out: expected exit 125 (wedged) with opt-out, got $rc2 (status=$status2)"
fi

if [ "$status2" = "wedged" ]; then
  ok "opt-out: job status is 'wedged' (stall-kill backstop), not 'permission-blocked'"
else
  bad "opt-out: job status is '$status2' (expected 'wedged')"
fi

# --- Scenario 4: a delegate that does NOT emit the print-mode string is NOT false-positived.
# A normal-finishing delegate must still get its real exit code, not 3. ---
jd3="$TMP/jobs/normal-finish"
mkdir -p -m 700 "$jd3"
echo '{"verb":"edit"}' > "$jd3/meta.json"

FAKE_OK="$TMP/fake-ok.sh"
cat > "$FAKE_OK" <<'EOF'
#!/usr/bin/env bash
echo "OSRC::DONE"
echo "work completed normally"
exit 0
EOF
chmod +x "$FAKE_OK"

OSRC_POLL=1 _supervise "$jd3" 5 60 120 -- "$FAKE_OK" >/dev/null 2>&1
rc3=$?
status3="$(cat "$jd3/status" 2>/dev/null)"

if [ "$rc3" -eq 0 ]; then
  ok "no-false-positive: normal-finishing delegate gets exit 0 (not 3)"
else
  bad "no-false-positive: expected exit 0 for normal finish, got $rc3 (status=$status3)"
fi

if [ "$status3" != "permission-blocked" ]; then
  ok "no-false-positive: normal finish not marked permission-blocked (status=$status3)"
else
  bad "no-false-positive: normal finish was falsely marked permission-blocked"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
