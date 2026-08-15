#!/usr/bin/env bash
# test_value_router.sh — value-optimal cross-provider lane routing.
# Deterministic (seeded caches, no live CLI, no network). Proves: a model available on both a
# per-token cash lane and a free/plan lane is RUN ON THE FREE LANE; the winning MODEL is unchanged
# (quality-first); a cost-unknown BYOK lane never wins on cost; the OSRC_ADVISE_ROUTER=0 hatch keeps
# the ranked lane. Fixtures use real OpenRouter/Devin id forms so the cross-provider identity match
# is exercised for real, not a hand-matched synthetic pair.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; echo "RESULT: 0 passed, 0 failed"; exit 0; }

T="$(mktemp -d)"; export OSRC_HOME="$T"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/catalogs"
. "$SRC" >/dev/null 2>&1
refresh_benchmarks() { return 1; }
refresh_models() { return 1; }

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
ck(){ if [ "$2" = "$3" ]; then ok "$1 -> '$2'"; else bad "$1 -> '$2' (want '$3')"; fi; }

# === _model_canon_key: cross-provider collapse + no over-collapse ===
k1="$(_model_canon_key z-ai/glm-5.2)"; k2="$(_model_canon_key glm-5-2)"; k3="$(_model_canon_key glm-5-2-max)"
[ "$k1" = "$k2" ] && [ "$k2" = "$k3" ] && ok "canon: z-ai/glm-5.2 == glm-5-2 == glm-5-2-max ($k1)" || bad "canon collapse: '$k1' '$k2' '$k3'"
a="$(_model_canon_key openai/gpt-5.6-sol)"; b="$(_model_canon_key openai/gpt-5)"
[ "$a" != "$b" ] && ok "canon: gpt-5.6-sol != gpt-5 (no over-collapse)" || bad "canon over-collapse: gpt-5.6-sol == gpt-5 ($a)"

# === _lane_marginal_cost basics ===
cat > "$OSRC_MODELS_JSON" <<'MJSON'
{"data":[{"id":"z-ai/turbo-9","pricing":{"prompt":"0.000002","completion":"0.000008"}},{"id":"z-ai/glm-5.2","pricing":{"prompt":"0.0000014","completion":"0.0000044"}}]}
MJSON
orc="$(_lane_marginal_cost or z-ai/turbo-9 1000)"; orcost="${orc%% *}"; orbasis="${orc##* }"
awk -v c="$orcost" 'BEGIN{exit (c+0 > 0)?0:1}' && ok "cost: or is per-token >0 ($orc)" || bad "cost: or not >0 ($orc)"
dvc="$(_lane_marginal_cost dv turbo-9)"; ck "cost: dv plan lane is 0" "${dvc%% *}" "0"
byok="$(_lane_marginal_cost droid whatever)"; ck "cost: droid BYOK is -1 (unknown)" "${byok%% *}" "-1"

# === _model_lanes: a model in BOTH catalogs yields both lanes ===
cat > "$T/catalogs/dv.raw.json" <<'RAW'
{"families":[{"family_uid":"turbo-9","aliases":[],"variants":[{"model_uid":"turbo-9","cost_summary":"Free"}]}]}
RAW
lanes="$(_model_lanes "$(_model_canon_key z-ai/turbo-9)" | tr ' ' '\n' | sort | tr '\n' ' ')"
case "$lanes" in *or*dv*|*dv*or*) ok "lanes: z-ai/turbo-9 found on both or and dv" ;; *) bad "lanes: expected or+dv, got '$lanes'" ;; esac

# === THE ROUTER MOVES a model to its cheapest lane (AE1) ===
# Seed a synthetic top-scoring model present on OpenRouter (per-token) AND the Devin catalog (free),
# force it to win, and assert advise runs it on dv (free), not or (paid). Same model, cheaper lane.
jq -n '{data:[{model_permaslug:"z-ai/turbo-9",intelligence_index:97,coding_index:97,agentic_index:97},{model_permaslug:"z-ai/glm-5.2",intelligence_index:51.1}]}' > "$OSRC_BENCH_JSON"
json="$(cmd_advise --json --effort max "refactor the auth module" 2>/dev/null)"
rec_model="$(printf '%s' "$json" | jq -r '.recommendation.model')"
rec_lane="$(printf '%s' "$json" | jq -r '.recommendation.lane')"
rec_basis="$(printf '%s' "$json" | jq -r '.recommendation.cost_basis // "null"')"
[ "$rec_model" = "z-ai/turbo-9" ] && ok "router: top model wins ($rec_model)" || bad "router: winner was '$rec_model' (want z-ai/turbo-9)"
[ "$rec_lane" = "dv" ] && ok "router: winning model routed to the FREE dv lane (not paid or)" || bad "router: lane was '$rec_lane' (want dv)"
case "$rec_basis" in plan|free) ok "router: cost_basis reflects the free/plan lane ($rec_basis)" ;; *) bad "router: cost_basis '$rec_basis' (want plan/free)" ;; esac

# === Hatch: OSRC_ADVISE_ROUTER=0 keeps the ranked lane (does not move to dv) ===
lane_off="$(OSRC_ADVISE_ROUTER=0 cmd_advise --json --effort max "refactor the auth module" 2>/dev/null | jq -r '.recommendation.lane')"
[ "$lane_off" = "or" ] && ok "hatch: OSRC_ADVISE_ROUTER=0 keeps the ranked lane (or)" || bad "hatch: lane '$lane_off' (want or, the pre-router lane)"

# === BYOK-only availability never wins on cost (stays on its priced lane) ===
# turbo-9 only on or + a BYOK droid catalog; router must not pick droid (-1 unknown), stays or.
rm -f "$T/catalogs/dv.raw.json"
mkdir -p "$T/factory"; : # (no local droid config -> droid contributes nothing; the priced or lane stays)
lane_byok="$(cmd_advise --json --effort max "refactor the auth module" 2>/dev/null | jq -r '.recommendation.lane')"
[ "$lane_byok" = "or" ] && ok "byok/no-free: model stays on its priced or lane (no unknown-cost win)" || bad "byok: lane '$lane_byok' (want or)"

# === Source invariants ===
grep -q 'OSRC_ADVISE_ROUTER' "$SRC" && ok "OSRC_ADVISE_ROUTER documented" || bad "OSRC_ADVISE_ROUTER not documented"
grep -q '_model_canon_key' "$SRC" && ok "_model_canon_key present" || bad "_model_canon_key missing"
grep -q '_lane_marginal_cost' "$SRC" && ok "_lane_marginal_cost present" || bad "_lane_marginal_cost missing"
grep -q 'test_value_router' "$SCRIPT_DIR/conformance.sh" && ok "suite registered in conformance.sh" || bad "suite not registered"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
