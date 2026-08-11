#!/usr/bin/env bash
# test_fg_guard_forgery.sh — a foreground delegate that echoes an UNSIGNED terminal marker must not
# arm the teardown kill timer, and a SIGKILLed half-finished run must never report rc=0.
#
# _fg_guard supervises a foreground delegate. Its teardown trigger used an UNSIGNED grep, so a cheap
# delegate that printed "OSRC::DONE" at line start armed the kill timer and got SIGKILLed mid-work.
# The rc mapping then read _last_marker, which falls back to accepting UNSIGNED anchored markers even
# when OSRC_MARK is set, returned OSRC::DONE, and fell through to `*) rc=0` — so a killed, half-finished
# run reported SUCCESS. The fix routes both the trigger and the rc mapping through _fg_teardown_seen,
# which trusts a marker ONLY when it carries the #${OSRC_MARK} signature (or, when OSRC_MARK is empty,
# the bare anchored form). A kill never returns 0 without a trusted DONE.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

export OSRC_MARK='deadbeef'
export OSRC_SOURCED=1            # source the script's functions WITHOUT running main
. "$SRC" >/dev/null 2>&1

# A test that silently does not load the functions reports success by returning empty strings, which
# is exactly the kind of green that means nothing. Refuse to continue unless they are really here.
type -t _fg_guard         >/dev/null || { echo "FAIL: _fg_guard not loaded"; exit 1; }
type -t _fg_teardown_seen >/dev/null || { echo "FAIL: _fg_teardown_seen not loaded"; exit 1; }

# Fast, deterministic watchdog windows. The watchdog loop polls every 2s, so the hard cap must be
# strictly greater than 2 to give the loop at least one hard-cap check. Teardown is short so a
# genuine terminal that wedges is caught fast; the forgery case must NOT arm it at all.
export OSRC_FG_TIMEOUT=5
export OSRC_FG_TEARDOWN=2

# Run _fg_guard with the foreground-supervisor path enabled (not bypassed, not already-active, not a
# bg stream) and capture its exit code.
run_guard() {  # $1 = delegate function name
  local fn="$1"
  OSRC_FG_GUARD=1 OSRC_FG_GUARD_ACTIVE=0 OSRC_STREAM=0 _fg_guard "$fn" budget >/dev/null 2>&1
}

# --- A) FORGERY: an UNSIGNED `OSRC::DONE` at line start then hang -> teardown must NOT arm; rc=124 ---
forge_hang() { printf 'OSRC::DONE\n'; sleep 30; }
rc=0; run_guard forge_hang; rc=$?
if [ "$rc" -eq 124 ]; then
  ok "A) forged unsigned OSRC::DONE did not read as success (rc=$rc, NOT 0)"
else
  bad "A) forged unsigned OSRC::DONE returned rc=$rc (expected 124, NOT 0)"
fi

# --- B) GENUINE PLAIN: a signed `OSRC::DONE#deadbeef` on its own line -> teardown arms, rc=0 ---
genuine_plain() { printf 'OSRC::DONE#%s real work done\n' "$OSRC_MARK"; }
rc=0; run_guard genuine_plain; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "B) genuine signed terminal on its own line -> rc=0"
else
  bad "B) genuine signed terminal on its own line returned rc=$rc (expected 0)"
fi

# --- C) GENUINE IN JSON STREAM: the signed marker embedded inside a JSON event-stream line -> rc=0 ---
genuine_json() { printf '{"event":"message","text":"OSRC::DONE#%s finished"}\n' "$OSRC_MARK"; }
rc=0; run_guard genuine_json; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "C) signed terminal embedded in a JSON stream line -> rc=0"
else
  bad "C) signed terminal embedded in a JSON stream line returned rc=$rc (expected 0)"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
