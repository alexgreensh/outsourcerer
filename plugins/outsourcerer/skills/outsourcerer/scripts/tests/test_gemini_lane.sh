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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

# One temp home for the whole test. The catalog used to be written to a first temp home that the
# line below then replaced, so the resolver fell through to the machine's real `agy models` and the
# result depended on whatever agy served that day.
TMP="$(mktemp -d)"; export OSRC_HOME="$TMP" HOME="$TMP/home"
mkdir -p "$HOME"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OSRC_HOME/catalogs"
printf '["gemini-3.7-flash-high","gemini-3.7-flash-medium","gemini-3.7-flash-low","gemini-3.6-flash-high","gemini-3.6-flash-medium","gemini-3.5-flash-low","gemini-3.1-pro-high","gemini-3.1-pro-low"]' > "$OSRC_HOME/catalogs/gm.json"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

. "$SRC" >/dev/null 2>&1

# A key for the separate image lane may coexist with the Google app login.
mkdir -p "$TMP/bin" "$HOME/.antigravity"
printf 'signed-in' > "$HOME/.antigravity/state"
cat > "$TMP/bin/agy" <<'FAKE'
#!/bin/sh
[ -z "${GEMINI_API_KEY+x}${GOOGLE_API_KEY+x}" ] || exit 1
echo keyless-dispatch
FAKE
chmod +x "$TMP/bin/agy"
if ( export PATH="$TMP/bin:$PATH" GEMINI_API_KEY=fixture GOOGLE_API_KEY=fixture
     MODEL_EXPLICIT=0; _session_launch_gm && "${SESSION_LAUNCH[@]}" ); then
  ok "interactive agy starts without either exported key"
else bad "interactive agy inherited a key"; fi
for family in gemini-pro gemini-flash gemini-flash-lite; do
  if (
    export PATH="$TMP/bin:$PATH" GEMINI_API_KEY=fixture GOOGLE_API_KEY=fixture
    IFS='|' read -r RESOLVED_ID lane TTIER <<<"$(resolve_model_row "$family")"
    [ "$lane" = gm ] && [ "$(osrc_lane_billing "$lane")" = subscription ] || exit 1
    REST=(probe); EFFORT=low
    record_ledger() { :; }
    wrapped_output="$(delegate_gmnative auto)" && grep -qx keyless-dispatch <<<"$wrapped_output"
  ); then ok "$family selects keyless agy with API keys present"
  else bad "$family keyless dispatch"; fi
done

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
{ _t3b_pipe="$(_agy_effort gemini-3.1-pro medium 2>&1 >/dev/null)" && grep -q 'has no' <<<"$_t3b_pipe"; } \
  && ok "clamping to a different effort level is announced on stderr" \
  || bad "effort was clamped silently"

# --- the flag must actually reach the CLI ---
grep -q -- '--effort "\$aeff"' "$SRC" \
  && ok "the agy invocation passes --effort (it refuses to run without one)" \
  || bad "agy is still invoked without --effort"
grep -qF -- '--model "$atok"' <<<"$(awk '/vehicle" = "agy"/,/record_ledger antigravity-agy/' "$SRC")" \
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
grep -qF 'rc=124' <<<"$(awk '/timeout waiting for response/,/rm -f "\$_aerr"/' "$SRC")" \
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

# --- Gemini 4 codenames: agy's live catalog is the only source that knows them -----------------
# `agy models` now serves the Gemini-4 families (neon/argon/hydrogen) plus 3.8-flash. The pro-class
# alias must follow the flagship agy actually serves — neon — not a dated pro id, and the whole
# `agy models` list is cached under OSRC_HOME for 24h so family picks do not respawn the CLI.
cat > "$TMP/bin/agy" <<'FAKE2'
#!/bin/sh
[ -z "${GEMINI_API_KEY+x}${GOOGLE_API_KEY+x}" ] || exit 1
if [ "${1:-}" = "models" ]; then
  echo call >> "$AGY_MODELS_CALLS"
  printf 'Fetching available models...\n'
  printf 'gemini-4-neon-low\tGemini 4 Neon (Low)\n'
  printf 'gemini-4-neon-medium\tGemini 4 Neon (Medium)\n'
  printf 'gemini-4-neon-high\tGemini 4 Neon (High)\n'
  printf 'gemini-4-neon-xhigh\tGemini 4 Neon (Extra High)\n'
  printf 'gemini-4-argon-low\tGemini 4 Argon (Low)\n'
  printf 'gemini-4-argon-medium\tGemini 4 Argon (Medium)\n'
  printf 'gemini-4-argon-high\tGemini 4 Argon (High)\n'
  printf 'gemini-4-hydrogen-low\tGemini 4 Hydrogen (Low)\n'
  printf 'gemini-4-hydrogen-medium\tGemini 4 Hydrogen (Medium)\n'
  printf 'gemini-4-hydrogen-high\tGemini 4 Hydrogen (High)\n'
  printf 'gemini-4-hydrogen-xhigh\tGemini 4 Hydrogen (Extra High)\n'
  printf 'gemini-3.8-flash-low\tGemini 3.8 Flash (Low)\n'
  printf 'gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)\n'
  printf 'gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n'
  printf 'claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)\n'
  exit 0
fi
if [ "${REJECT_AGY:-}" = 1 ]; then echo 'invalid model selection' >&2; exit 2; fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = --model ]; then echo "$2"; exit 0; fi
  shift
done
FAKE2
chmod +x "$TMP/bin/agy"
export AGY_MODELS_CALLS="$TMP/agy_models_calls.txt"; : > "$AGY_MODELS_CALLS"
# Resolve against this fake only, never an agy installed on the machine; keyless like dispatch.
export PATH="$TMP/bin:$PATH" GEMINI_API_KEY=fixture GOOGLE_API_KEY=fixture
# Drop both caches so every id below is resolved against THIS fake's catalog, not the fixture above.
rm -f "$OSRC_HOME/agy-models.txt" "$OSRC_HOME/catalogs/gm.json"

# An explicit id agy serves passes through untouched (and warms catalogs/gm.json for the
# knows-checks below, so later `agy models` calls are only the 24h family-list cache).
[ "$(_agy_model_token gemini-4-neon-high 2>/dev/null)" = "gemini-4-neon-high" ] \
  && ok "a served Gemini-4 id passes through untouched" \
  || bad "served gemini-4-neon-high was rewritten: $(_agy_model_token gemini-4-neon-high 2>/dev/null)"

[ -s "$OSRC_HOME/catalogs/gm.json" ] && ok "concrete lookup cached the keyless catalog" || bad "concrete lookup failed with keys set"
run_low() (
  MODEL="$1"; EFFORT=low; REST=(probe)
  IFS='|' read -r RESOLVED_ID lane TTIER <<<"$(resolve_model_row "$MODEL")"
  record_ledger() { :; }
  delegate_gmnative auto
)
for pair in gemini-neon:gemini-4-neon-low gemini-4-neon-high:gemini-4-neon-high; do
  [ "$(run_low "${pair%:*}" 2>/dev/null)" = "${pair#*:}" ] && ok "low effort dispatch $pair" || bad "low effort dispatch $pair"
done

# The flagship pick: newest version first, then codename tier (neon > argon > hydrogen > pro),
# then the high effort rung — agy's documented default thinking level for these families.
[ "$(_agy_flagship 2>/dev/null)" = "gemini-4-neon-high" ] \
  && ok "the pro-class flagship is gemini-4-neon-high (neon beats argon/hydrogen, high is the default rung)" \
  || bad "flagship pick wrong: $(_agy_flagship 2>/dev/null)"
[ "$(_agy_model_token gemini-pro 2>/dev/null)" = "gemini-4-neon-high" ] \
  && ok "gemini-pro resolves to the top Gemini 4 model agy serves (Neon)" \
  || bad "gemini-pro resolved to $(_agy_model_token gemini-pro 2>/dev/null)"
[ "$(EFFORT=low _agy_model_token gemini-pro 2>/dev/null)" = "gemini-4-neon-low" ] \
  && ok "gemini-pro with --effort low runs the served low rung" \
  || bad "effort low on gemini-pro resolved to $(EFFORT=low _agy_model_token gemini-pro 2>/dev/null)"
[ "$(EFFORT=max _agy_model_token gemini-pro 2>/dev/null)" = "gemini-4-neon-xhigh" ] \
  && ok "--effort max maps to the xhigh rung" || bad "effort max on gemini-pro: $(EFFORT=max _agy_model_token gemini-pro 2>/dev/null)"
[ "$(_agy_newest flash 2>/dev/null)" = "gemini-3.8-flash" ] \
  && ok "the newest served flash family resolves bare (gemini-3.8-flash)" \
  || bad "newest flash wrong: $(_agy_newest flash 2>/dev/null)"
[ "$(_agy_model_token gemini-flash 2>/dev/null)" = "gemini-3.8-flash" ] \
  && ok "gemini-flash resolves to the newest flash agy serves" \
  || bad "gemini-flash resolved to $(_agy_model_token gemini-flash 2>/dev/null)"
[ "$(_agy_model_token gemini-flash-lite 2>/dev/null)" = "gemini-3.8-flash" ] \
  && ok "gemini-flash-lite still collapses to the newest flash" \
  || bad "flash-lite resolved to $(_agy_model_token gemini-flash-lite 2>/dev/null)"

# The advisor's new alias row: gemini-neon -> gemini-4-neon-high, lane gm, tier frontier.
[ "$(resolve_model_row gemini-neon)" = "gemini-4-neon-high|gm|frontier" ] \
  && ok "gemini-neon table row resolves to gemini-4-neon-high on the gm lane at frontier tier" \
  || bad "gemini-neon row wrong: $(resolve_model_row gemini-neon)"
[ "$(_agy_model_token gemini-neon 2>/dev/null)" = "gemini-4-neon-high" ] \
  && ok "the gemini-neon alias dispatches to the served Neon id" \
  || bad "gemini-neon resolved to $(_agy_model_token gemini-neon 2>/dev/null)"

# The 24h cache: agy-models.txt under OSRC_HOME, honored while fresh, refetched once stale.
[ -f "$OSRC_HOME/agy-models.txt" ] && grep -qx 'gemini-4-neon-high' "$OSRC_HOME/agy-models.txt" \
  && ok "the agy models list is cached at \$OSRC_HOME/agy-models.txt" \
  || bad "no agy-models.txt cache written"
calls_now="$(wc -l < "$AGY_MODELS_CALLS" | tr -d ' ')"
_agy_model_token gemini-pro >/dev/null 2>&1; _agy_model_token gemini-flash >/dev/null 2>&1
[ "$(wc -l < "$AGY_MODELS_CALLS" | tr -d ' ')" = "$calls_now" ] \
  && ok "a fresh agy-models.txt is reused — no respawn of agy models" \
  || bad "fresh cache was ignored (agy models called again)"
touch -t 202001010000 "$OSRC_HOME/agy-models.txt"
_agy_model_token gemini-pro >/dev/null 2>&1
[ "$(wc -l < "$AGY_MODELS_CALLS" | tr -d ' ')" -gt "$calls_now" ] \
  && ok "a cache older than 24h is refetched from agy models" \
  || bad "stale agy-models.txt was not refetched"

# A Gemini-4-family id agy does NOT serve heals to the flagship, loudly, like the flash/pro ids.
out="$(_agy_model_token gemini-4-neon-max 2>"$TMP/err-g4")"
[ "$out" = "gemini-4-neon-high" ] && grep -q 'gemini-4-neon-max' "$TMP/err-g4" \
  && ok "a retired Gemini-4 id is replaced by the flagship pick, naming the retired id" \
  || bad "retired neon id resolved to '$out' (notice: $(cat "$TMP/err-g4"))"

# The env pin still beats the live catalog for the pro-class pick.
[ "$(OSRC_AGY_PRO_DEFAULT=gemini-4-argon-high _agy_model_token gemini-pro 2>/dev/null)" = "gemini-4-argon-high" ] \
  && ok "OSRC_AGY_PRO_DEFAULT repins the flagship pick without editing any table" \
  || bad "pro pin lost to the live catalog"

if REJECT_AGY=1 run_low gemini-pro >/dev/null 2>&1; then
  bad "rejected model reported success"
elif [ -e "$OSRC_HOME/catalogs/gm.json" ] || [ -e "$OSRC_HOME/agy-models.txt" ]; then
  bad "rejected model survived in a catalog"
else ok "model rejection drops both populated catalogs"; fi

# agy missing entirely -> the last-known offline constants, never a guess.
( export OSRC_HOME="$TMP/osrc-noagy" PATH="/usr/bin:/bin"
  mkdir -p "$OSRC_HOME"
  [ "$(_agy_model_token gemini-pro 2>/dev/null)" = "$_AGY_PRO_LASTKNOWN" ] \
    && echo "PASS: no agy -> gemini-pro falls back to the last-known pro id" \
    || echo "FAIL: no agy -> gemini-pro gave $(_agy_model_token gemini-pro 2>/dev/null)"
  [ "$(_agy_model_token gemini-flash 2>/dev/null)" = "$_AGY_FLASH_LASTKNOWN" ] \
    && echo "PASS: no agy -> gemini-flash falls back to the last-known flash id" \
    || echo "FAIL: no agy -> gemini-flash gave $(_agy_model_token gemini-flash 2>/dev/null)"
) > "$TMP/sub-g4.out"
while IFS= read -r line; do case "$line" in PASS:*) ok "${line#PASS: }" ;; *) bad "${line#FAIL: }" ;; esac; done < "$TMP/sub-g4.out"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
