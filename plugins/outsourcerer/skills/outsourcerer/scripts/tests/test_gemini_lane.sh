#!/usr/bin/env bash
# test_gemini_lane.sh — the Antigravity (agy) lane must send flags the CLI actually accepts, and must
# not be advertised as ready when it cannot answer.
#
# Reported from real use: two Gemini delegations failed in seconds and produced nothing.
#   agy: invalid model selection (--model "gemini-3.1-pro" --effort ""): requires --effort (low, high)
# Two causes, one root — a stale assumption written into a comment ("neither agy nor gemini-cli
# exposes a reasoning-effort knob") that stopped being true:
#   1. --effort was never passed, so agy received an empty one and refused the run outright.
#   2. The accepted levels are PER MODEL: pro takes low|high with no medium, flash takes low|medium|high.
# And the lane was listed as ready because the binary printed a version, while every real request
# timed out — which is how work gets routed somewhere that cannot serve it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

. "$SRC" >/dev/null 2>&1

# --- effort must be legal for the specific model ---
[ "$(_agy_effort gemini-3.1-pro medium 2>/dev/null)" = "high" ] \
  && ok "pro has no medium level, so medium is raised to high (never silently lowered)" \
  || bad "pro+medium did not clamp to a level pro accepts"
[ "$(_agy_effort gemini-3.1-pro low 2>/dev/null)" = "low" ] \
  && ok "a level the model supports is passed through untouched" || bad "pro+low was altered"
[ "$(_agy_effort gemini-3.5-flash medium 2>/dev/null)" = "medium" ] \
  && ok "flash keeps medium (its levels differ from pro's)" || bad "flash+medium was altered"

# An unset or nonsense effort must still produce a legal value: agy REFUSES to run on an empty one,
# which is the exact failure that returned in 17 seconds with nothing done.
for probe in "" garbage; do
  v="$(_agy_effort gemini-3.5-flash "$probe" 2>/dev/null)"
  case "$v" in low|medium|high) ok "effort '$probe' resolves to a legal level ($v), never empty" ;;
    *) bad "effort '$probe' produced '$v', which agy rejects outright" ;; esac
done

# The clamp must be announced. Quietly giving less (or more) thinking than asked for is the kind of
# change the caller cannot see in the output.
_agy_effort gemini-3.1-pro medium 2>&1 >/dev/null | grep -q 'has no' \
  && ok "clamping to a different effort level is announced on stderr" \
  || bad "effort was clamped silently"

# --- the flag must actually reach the CLI ---
grep -q -- '--effort "\$aeff"' "$SRC" \
  && ok "the agy invocation passes --effort (it refuses to run without one)" \
  || bad "agy is still invoked without --effort"
awk '/vehicle" = "agy"/,/record_ledger antigravity-agy/' "$SRC" | grep -q -- '--model "\$atok"' \
  && ok "the agy invocation passes an explicit --model" || bad "agy invoked without --model"

# --- installed is not ready ---
grep -q 'INSTALLED BUT NOT ANSWERING' "$SRC" \
  && ok "doctor distinguishes an installed CLI from one that can actually answer" \
  || bad "doctor still reports readiness from the binary alone"
grep -q 'OSRC_DOCTOR_PROBE' "$SRC" \
  && ok "the liveness probe can be turned off (it costs a real request)" \
  || bad "liveness probe is not opt-out"
grep -q 'OSRC_GEMINI_VEHICLE=gemini' "$SRC" \
  && ok "the down-lane message names the working alternative" \
  || bad "no fallback offered when the keyless vehicle is down"

# --- a dead lane must cost seconds and explain itself, not five silent minutes ---
grep -q 'accepted the request and never answered' "$SRC" \
  && ok "an agy generation timeout is translated into a plain explanation" \
  || bad "agy timeouts still surface as a bare CLI error"
grep -q 'OSRC_AGY_PRINT_TIMEOUT=%s was the wait' "$SRC" \
  && ok "the message names the knob that controls how long it waited" \
  || bad "no way for the user to fail faster on an unhealthy lane"
awk '/timeout waiting for response/,/rm -f "\$_aerr"/' "$SRC" | grep -q 'rc=124' \
  && ok "a lane that never answered exits non-zero (never mistaken for success)" \
  || bad "an unanswered request could still exit 0"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
