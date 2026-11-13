#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_sandbox.sh" || { echo "FAIL: sandbox library" >&2; exit 1; }
osrc_test_sandbox || { echo "FAIL: sandbox" >&2; exit 1; }
# Guard against OSRC_VERSION drifting from plugin.json. The version literal in outsourcerer.sh and the
# "version" in .claude-plugin/plugin.json are two hand-maintained copies; a release that bumps one and
# not the other makes `doctor` report a drift and `--version` lie. This test fails when they diverge,
# so the literal is kept in sync mechanically instead of by memory.
#
# Complements test_version_gate.sh: that one proves `doctor --strict` PROMOTES a drift to a failing
# exit code (the gate mechanism); this one asserts the two real files are actually in sync right now.
#
# Adapted from PR #23 (pr-a-version-drift) by @danikdanik — thank you.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
MF="$HERE/../../../../.claude-plugin/plugin.json"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
[ -f "$MF" ]  || { echo "FAIL: cannot find plugin.json at $MF"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# Same grep-the-literal technique doctor already uses for its second-copy drift check.
sv="$(grep -m1 '^OSRC_VERSION=' "$SRC" | cut -d'"' -f2)"
pv="$(grep -m1 '"version"'      "$MF"  | cut -d'"' -f4)"

[ -n "$sv" ] || bad "could not read OSRC_VERSION literal from $SRC"
[ -n "$pv" ] || bad "could not read \"version\" from $MF"

if [ -n "$sv" ] && [ "$sv" = "$pv" ]; then
  ok "OSRC_VERSION literal ($sv) matches plugin.json ($pv)"
elif [ -n "$sv" ]; then
  bad "version drift: OSRC_VERSION literal is $sv but plugin.json is $pv — bump the literal in outsourcerer.sh"
fi

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
