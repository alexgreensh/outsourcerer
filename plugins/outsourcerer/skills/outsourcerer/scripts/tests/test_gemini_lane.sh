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

# Isolate from the very env vars this feature reads: OSRC_AGY_{FLASH,PRO}_DEFAULT repin the bare-family
# defaults, so a developer (or CI) that exports one would flip the "with the override unset" assertions
# below into false failures. Unset them here; the override IS exercised inline where it belongs.
unset OSRC_AGY_FLASH_DEFAULT OSRC_AGY_PRO_DEFAULT
# Hermetic catalog: the ids below are what this test names, so the resolver treats them as served
# (a retired id would otherwise be healed to the newest member, which is the newer test's job).
TMP_CAT="$(mktemp -d)"; trap 'rm -rf "$TMP_CAT"' EXIT
export OSRC_HOME="$TMP_CAT"; mkdir -p "$OSRC_HOME/catalogs"
printf '["gemini-3.7-flash-high","gemini-3.7-flash-medium","gemini-3.7-flash-low","gemini-3.6-flash-high","gemini-3.6-flash-medium","gemini-3.5-flash-low","gemini-3.1-pro-high","gemini-3.1-pro-low"]' > "$OSRC_HOME/catalogs/gm.json"

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

# --- an explicit, serveable model choice must never be rewritten ---
# The substring arms in _agy_model_token translate gemini-API-only ids into agy's catalog, but they
# used to match on SUBSTRING alone, so they also swallowed ids that were ALREADY valid agy tokens:
# `-m gemini-3.7-flash` dispatched gemini-3.5-flash, silently, with nothing in the output saying a
# substitution had happened. Every newer release agy adds hits the same path, so this worsens over
# time, and the caller's own effort/cost reasoning is made against a model that never ran.
[ "$(_agy_model_token gemini-3.7-flash)" = "gemini-3.7-flash" ] \
  && ok "an explicit newer flash release is dispatched as asked, not collapsed to the default" \
  || bad "an explicit -m gemini-3.7-flash is still silently rewritten to another model"
[ "$(_agy_model_token gemini-3.6-flash-high)" = "gemini-3.6-flash-high" ] \
  && ok "an effort-suffixed agy id survives (agy serves these; they are not API-only forms)" \
  || bad "an effort-suffixed agy id was rewritten"

# ...but the translation those arms exist for must SURVIVE. agy does not silently fall back on an
# unknown token, it hard-errors ("--effort is not supported for model X"), so passing an API-only
# id straight through would turn the documented gemini-pro / gemini-flash-lite aliases into a hard
# failure. These two are the ids the alias table actually resolves to.
[ "$(_agy_model_token gemini-3.1-pro-preview 2>/dev/null)" = "$(_agy_family_default pro)" ] \
  && ok "the -preview suffix is still stripped (agy rejects preview ids outright)" \
  || bad "gemini-pro now resolves to a token agy refuses to run"
[ "$(_agy_model_token gemini-3.1-flash-lite 2>/dev/null)" = "$(_agy_family_default flash)" ] \
  && ok "flash-lite still collapses to flash (agy has no lite tier)" \
  || bad "gemini-flash-lite now resolves to a token agy refuses to run"

# --- passing an id through is only half the job: it must then be sent WITHOUT --effort ---
# Found by running the real CLI rather than a fake one. Letting an explicit id survive the token map
# (above) makes it reach agy for the first time, and agy refuses a model that already names its
# effort if --effort is also present: "--model gemini-3.7-flash-high conflicts with --effort=medium".
# This is the normal case, not an edge case — EVERY id in agy's published catalog carries a
# -low/-medium/-high suffix, so before this, pinning any real model id was a guaranteed hard failure.
for suffixed in gemini-3.7-flash-high gemini-3.6-flash-medium gemini-3.5-flash-low gemini-3.1-pro-low; do
  [ -z "$(_agy_effort "$suffixed" medium 2>/dev/null)" ] \
    && ok "$suffixed carries its own effort, so no --effort is produced for it" \
    || bad "$suffixed would still be sent with --effort, the pair agy rejects"
done

# The bare-family path must be untouched by that: those ids carry no level, and agy refuses them
# with an EMPTY effort just as hard, so dropping the flag everywhere would break the common case.
[ -n "$(_agy_effort gemini-3.5-flash medium 2>/dev/null)" ] \
  && ok "a bare family id still gets an effort (the flag is dropped only when the id names one)" \
  || bad "the bare family id lost its --effort, which agy also refuses"

# Assert the call site actually honours the empty return. The function can be right while the
# dispatch still interpolates --effort unconditionally, which is exactly how this shipped.
if grep -q -- '--model "$atok" ${aeffflag\[@\]+"${aeffflag\[@\]}"}' "$SRC"; then
  ok "the agy dispatch builds --effort conditionally instead of always interpolating it"
else
  bad "the agy dispatch still passes --effort unconditionally"
fi

# The bare family defaults stay overridable: agy's catalog gains new dated releases, so a hardcoded
# default goes stale and a caller needs a way to move it without waiting on this table.
[ "$(OSRC_AGY_FLASH_DEFAULT=gemini-3.7-flash _agy_model_token flash)" = "gemini-3.7-flash" ] \
  && ok "the bare flash default can be repinned without editing the table" \
  || bad "OSRC_AGY_FLASH_DEFAULT does not move the bare flash default"
[ "$(_agy_model_token flash 2>/dev/null)" = "$(_agy_family_default flash)" ] \
  && ok "with the override unset the bare flash default is unchanged" \
  || bad "the bare flash default changed when no override was set"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
