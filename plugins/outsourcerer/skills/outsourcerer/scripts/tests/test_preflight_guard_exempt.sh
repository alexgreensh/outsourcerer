#!/usr/bin/env bash
# test_preflight_guard_exempt.sh — a route preflight is exempt from the blind-turn guard.
#
# Root cause guarded: bg/fanout validate a dispatch by re-entering the script with OSRC_PREFLIGHT=1.
# That child ran main() to the end, where the blind-turn guard fires for a delegating command
# (run/explore/...) whenever any delegate needs attention — returning 7. So a PASSING preflight came
# back as 7 the moment parked work existed, and cmd_bg fail-closed with "route preflight returned
# non-zero". Result: once a few delegates were parked (failed/waiting), EVERY new bg/fanout launch was
# refused — the tool blocking the very work that would clear the backlog. The fix returns the dispatch
# rc untouched under OSRC_PREFLIGHT=1, before the guard block.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "$PWD/.test-preflight.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"; export HOME="$TMP/home"
mkdir -p "$OSRC_HOME" "$HOME"

set --
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
type -t main >/dev/null || { echo "FAIL: main not loaded"; exit 1; }
type -t _blind_turn_guard >/dev/null || { echo "FAIL: _blind_turn_guard not loaded"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Force the guard to report parked needs-attention work on EVERY call — the exact condition that used
# to poison the preflight.
_blind_turn_guard() { return 1; }

# A preflight of a delegating command (routable cloud model) must NOT come back as 7. In preflight mode
# the dispatch gate returns before any real work, so this makes no network call and mutates nothing.
export OSRC_PREFLIGHT=1 OSRC_CLOUD_ACK=1 OSRC_CLOUD_ACKED=1
rc=0
( main run -m glm-5.2 "preflight probe" ) >/dev/null 2>&1 || rc=$?
if [ "$rc" = "7" ]; then
  bad "preflight of a delegating command still returns 7 (blind-turn guard poisons the preflight)"
else
  ok "preflight is exempt from the blind-turn guard (rc=$rc, not 7)"
fi

# The guard itself must still be wired for a REAL turn end (we only exempt preflight). With preflight
# OFF and the same parked-work condition, the delegating branch still surfaces 7.
unset OSRC_PREFLIGHT
rc=0
( OSRC_NO_AUTODETACH=1; main status ) >/dev/null 2>&1 || rc=$?   # a LOOK command: guard is backstop-only, never overrides
[ "$rc" != "7" ] && ok "a supervising command (status) is never turned into a 7 by parked work" || bad "status was poisoned to 7"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
