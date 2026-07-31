#!/usr/bin/env bash
# test_lane_fallback.sh — availability-aware routing + --effort strip (no CLI leak).
# Exercises the pure helpers offline + asserts the routing wire-in via source inspection.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Extract + eval only the pure functions (avoid running main).
eval "$(sed -n '/^parse_model() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^_devin_model_for() {/,/^}/p' "$SRC")"
DEFAULT_MODEL="glm-5.2"; OUTSOURCERER_EFFORT=""
die(){ echo "unexpected die: $*" >&2; return 1; }

# --- Scenario 1: parse_model strips --effort (the Devin CLI crash fix). ---
parse_model -m swe-1.7 --effort high "do the thing"
[ "${REST[*]}" = "do the thing" ] && ok "parse_model strips --effort from the prompt" || bad "REST leaked flags: [${REST[*]}]"
[ "$EFFORT" = "high" ] && ok "parse_model captures EFFORT for the advisory" || bad "EFFORT not captured"
[ "$MODEL" = "swe-1.7" ] && ok "parse_model keeps -m model" || bad "MODEL wrong: $MODEL"

# --- Scenario 2: parse_model strips --tier/--with/--allow-downgrade/--cloud-ack too. ---
OSRC_ALLOW_DOWNGRADE=0; OSRC_CLOUD_ACK=0
parse_model -m glm --tier capable --with skills=x --allow-downgrade --cloud-ack "task body"
[ "${REST[*]}" = "task body" ] && ok "parse_model strips all osrc flags (only prompt in REST)" || bad "flags leaked: [${REST[*]}]"
[ "$OSRC_ALLOW_DOWNGRADE" = "1" ] && ok "--allow-downgrade consumed" || bad "--allow-downgrade not set"
[ "$OSRC_CLOUD_ACK" = "1" ] && ok "--cloud-ack consumed" || bad "--cloud-ack not set"

# A fallback reconstruction must not promote an implicit provider to an explicit one.
PROVIDER=devin; PROVIDER_EXPLICIT=0
parse_model -m glm "task body"
[ "$PROVIDER_EXPLICIT" = "0" ] && ok "model reconstruction preserves implicit provider provenance" || bad "fallback reconstruction changed provider provenance"
grep -q 'OSRC_PROVIDER_EXPLICIT="${PROVIDER_EXPLICIT:-0}"' "$SRC" && grep -q '_run_provider=()' "$SRC" && ok "detached jobs preserve provider provenance" || bad "detached provider provenance missing"
grep -q '_fallback_provider_for_lane' "$SRC" && grep -q 'local _fb_new=(--provider "$_fb_provider" -m "$_fb_alias")' "$SRC" \
  && ok "fallback rebuilds provider and explicit provenance together" || bad "fallback can retain mismatched provider provenance"

# --- Scenario 3: _devin_model_for maps the dual-lane model, empty for OR-only. ---
[ "$(_devin_model_for glm)" = "glm-5.2" ] && ok "glm -> Devin sibling glm-5.2" || bad "glm sibling wrong"
[ "$(_devin_model_for z-ai/glm-5.2)" = "glm-5.2" ] && ok "z-ai/glm-5.2 -> Devin sibling" || bad "OR-id sibling wrong"
[ -z "$(_devin_model_for hy3)" ] && ok "hy3 has no Devin sibling (OR-only)" || bad "hy3 wrongly mapped"
# deepseek became dual-lane when Devin added deepseek-v4-pro (verified via the live model probe, 2026-07).
[ "$(_devin_model_for deepseek)" = "deepseek-v4-pro" ] && ok "deepseek maps to Devin sibling deepseek-v4-pro" || bad "deepseek Devin sibling wrong: '$(_devin_model_for deepseek)'"
[ -z "$(_devin_model_for hy3)" ] && ok "hy3 has no Devin sibling (OR-only)" || bad "hy3 wrongly mapped"
[ -z "$(_devin_model_for sol)" ] && ok "sol (single-lane) no Devin sibling" || bad "sol wrongly mapped"

# --- Scenario 4: routing wire-in present (availability-aware reroute + ORIG model rewrite). ---
grep -q '_devin_model_for "$MODEL"' "$SRC" && ok "route_delegate consults _devin_model_for in the or) case" || bad "reroute not wired"
grep -q 'served by BOTH OpenRouter and Devin' "$SRC" && ok "reroute prints the dual-lane banner" || bad "reroute banner missing"
grep -q 'ORIG\[$((_i+1))\]="$_dvm"' "$SRC" && ok "reroute rewrites the model token in ORIG for the Devin lane" || bad "ORIG model rewrite missing"

# --- Scenario 5: Devin effort is advisory and never masquerades as a native flag. ---
grep -q 'advisory: prompt directive; Devin lane has no native effort knob' "$SRC" && ok "Devin lane labels effort advisory" || bad "Devin effort advisory missing"
# The Devin CLI invocation must NOT include an unsupported --effort flag.
grep -q 'devin --model "$MODEL" --permission-mode "$perm" ${sbx' "$SRC" && ok "devin CLI invocation unchanged (no --effort arg)" || bad "devin CLI invocation altered unexpectedly"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
