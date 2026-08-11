#!/usr/bin/env bash
# test_version_gate.sh — `doctor --strict` must FAIL on version drift, not just warn.
#
# OSRC_VERSION in outsourcerer.sh can drift from plugin.json. Without --strict, doctor only prints
# the drift; a CI gate or caller cannot tell from the exit code that anything is wrong. The --strict
# flag promotes a non-empty _drift to rc=1 so the version check is a real GATE.
#
# WHY DIRECT-COMPARISON AGAINST A TEMP FIXTURE (not full `doctor --strict`):
# The task allows invoking full `doctor --strict` only if it is cheap and can be pointed at a temp
# fixture. It is neither. doctor probes many lanes regardless of OSRC_DOCTOR_OFFLINE (devin auth
# status, agy/gemini liveness, hermes state.db, cline providers.json, local-inference detect), reads
# real user files (~/.env, ~/.config/devin/skills, ~/.cline), and — decisively — returns EARLY with
# rc=0 from the "devin NOT INSTALLED" branch (line ~11567), which would bypass the end-gate on any
# devin-less machine and make the gate test pass when it should fail. None of that is
# environment-independent or deterministic. So we test the GATE SEMANTICS directly: we run the EXACT
# drift comparison doctor runs (jq '.version // empty' vs $OSRC_VERSION) against a temp plugin.json
# fixture, then apply the EXACT --strict rule added to doctor (non-empty _drift + --strict -> rc=1).
# This exercises the real OSRC_VERSION value and the real comparison expression, without the
# non-deterministic lane probes or the devin-early-return bypass.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed on $SRC"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Source the script to pick up OSRC_VERSION and the `have` helper. Sourcing runs main() with the
# (empty) test args, which hits the help branch silently under the redirection — no side effects.
. "$SRC" >/dev/null 2>&1
type -t have >/dev/null || { echo "FAIL: have() not loaded from $SRC"; exit 1; }

# The task requires reading OSRC_VERSION via grep (not just trusting the sourced value). Cross-check
# the two so a future refactor that changes how the constant is declared cannot silently desync.
GREP_VER="$(grep -m1 '^OSRC_VERSION=' "$SRC" | cut -d'"' -f2)"
[ -n "$GREP_VER" ] || { echo "FAIL: could not grep OSRC_VERSION from $SRC"; exit 1; }
if [ "$GREP_VER" != "$OSRC_VERSION" ]; then
  bad "grepped OSRC_VERSION ($GREP_VER) != sourced OSRC_VERSION ($OSRC_VERSION)"
else
  ok "OSRC_VERSION read via grep matches the sourced value ($GREP_VER)"
fi

# doctor's drift detection requires jq; without it _dver stays empty and the gate can never fire.
# Skip (not fail) on a jq-less box — the feature under test is jq-gated in doctor itself.
if ! have jq; then
  echo "SKIP: jq not on PATH (doctor's drift check itself requires jq); nothing to gate-test."
  echo
  echo "RESULT: $pass passed, $fail failed"
  exit 0
fi

# Mirror doctor()'s drift block EXACTLY against a given plugin.json fixture, then apply the EXACT
# --strict gate rule added at the end of doctor(). Returns the rc doctor would return for that
# fixture under that flag setting. This is the unit under test.
_gate() {
  local _mf="$1" _strict="$2" _dver="" _drift=""
  [ -f "$_mf" ] && have jq && _dver="$(jq -r '.version // empty' "$_mf" 2>/dev/null)"
  [ -n "$_dver" ] && [ "$_dver" != "$OSRC_VERSION" ] && _drift="version DRIFT"
  if [ "$_strict" = "1" ] && [ -n "$_drift" ]; then return 1; fi
  return 0
}

# --- temp plugin.json fixtures (environment-independent; never touch real ~/.claude files) --------
mkdir -p "$TMP/.claude-plugin"
MATCH_FIX="$TMP/.claude-plugin/plugin.json"
MISMATCH_FIX="$TMP/.claude-plugin/plugin-mismatch.json"
printf '{"name":"outsourcerer","version":"%s"}\n' "$OSRC_VERSION" > "$MATCH_FIX"
# A version that is guaranteed != the current one: bump the patch by 1, fall back to a sentinel.
_mismatch_ver="$(( ${GREP_VER##*.} + 1 ))"
_mismatch_ver="${GREP_VER%.*}.$_mismatch_ver"
[ "$_mismatch_ver" != "$OSRC_VERSION" ] || _mismatch_ver="99.99.99"
printf '{"name":"outsourcerer","version":"%s"}\n' "$_mismatch_ver" > "$MISMATCH_FIX"

# --- case 1: matching versions + --strict -> gate PASSES (rc 0) ----------------------------------
_gate "$MATCH_FIX" 1; rc=$?
[ "$rc" -eq 0 ] && ok "matching versions + --strict -> gate passes (rc 0)" \
                 || bad "matching versions + --strict returned rc=$rc (expected 0)"

# --- case 2: mismatched versions + --strict -> gate FAILS (rc 1) ---------------------------------
_gate "$MISMATCH_FIX" 1; rc=$?
[ "$rc" -eq 1 ] && ok "mismatched versions + --strict -> gate fails (rc 1)" \
                 || bad "mismatched versions + --strict returned rc=$rc (expected 1)"

# --- case 3: mismatched versions, NO --strict -> default warn-only, rc unchanged (0) --------------
# This is the regression guard: the new flag must not change doctor's default behavior.
_gate "$MISMATCH_FIX" 0; rc=$?
[ "$rc" -eq 0 ] && ok "mismatched versions without --strict -> default warn-only (rc 0, unchanged)" \
                 || bad "mismatched versions without --strict returned rc=$rc (expected 0; default changed)"

# --- case 4: matching versions, NO --strict -> rc 0 ----------------------------------------------
_gate "$MATCH_FIX" 0; rc=$?
[ "$rc" -eq 0 ] && ok "matching versions without --strict -> rc 0" \
                 || bad "matching versions without --strict returned rc=$rc (expected 0)"

# --- case 5: missing plugin.json entirely -> no drift detectable, gate stays open (rc 0) ----------
# doctor is best-effort when there is nothing to compare; --strict must not invent a failure.
_gate "$TMP/.claude-plugin/does-not-exist.json" 1; rc=$?
[ "$rc" -eq 0 ] && ok "missing plugin.json + --strict -> no false failure (rc 0)" \
                 || bad "missing plugin.json + --strict returned rc=$rc (expected 0)"

# --- cases 6-7: the real doctor path must apply the gate before its devin-missing return ----------
mkdir -p "$TMP/plugins/outsourcerer/skills/outsourcerer/scripts" "$TMP/plugins/outsourcerer/.claude-plugin" "$TMP/home"
SCRIPT_PATH="$TMP/plugins/outsourcerer/skills/outsourcerer/scripts/outsourcerer.sh"
HOME="$TMP/home"; OSRC_HOME="$TMP/state"; PROVIDER=cc; OSRC_DOCTOR_OFFLINE=1
export HOME OSRC_HOME OSRC_DOCTOR_OFFLINE
have(){ [ "${1:-}" = jq ]; } # jq exists for drift detection; devin and every other optional CLI do not.

printf '{"name":"outsourcerer","version":"%s"}\n' "$_mismatch_ver" > "$TMP/plugins/outsourcerer/.claude-plugin/plugin.json"
doctor --strict >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "real doctor: drift + strict + devin absent -> drift wins (rc 1)" \
                 || bad "real doctor: drift + strict + devin absent returned rc=$rc (expected 1)"

printf '{"name":"outsourcerer","version":"%s"}\n' "$OSRC_VERSION" > "$TMP/plugins/outsourcerer/.claude-plugin/plugin.json"
doctor --strict >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "real doctor: no drift + strict + devin absent + provider cc -> rc 0" \
                 || bad "real doctor: no drift + strict + devin absent + provider cc returned rc=$rc (expected 0)"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
