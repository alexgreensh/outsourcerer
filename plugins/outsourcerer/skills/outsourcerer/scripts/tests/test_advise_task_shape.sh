#!/usr/bin/env bash
# Offline checks for task classification, native variant metadata, and measured scores.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"; export HOME="$TMP"
cleanup() { rm -rf "$TMP"; }; trap cleanup EXIT
export OSRC_ADVISE_CONSERVE=0 OSRC_ADVISE_DYNAMIC_POOL=1 OSRC_HEARTBEAT_DISABLED=1
. "$SRC" >/dev/null 2>&1
refresh_benchmarks() { return 1; }   # never touch the network
have jq || { echo "SKIP: jq required for advise"; exit 0; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
ck()  { if [ "$2" = "$3" ]; then ok "$1 -> '$2'"; else bad "$1 -> '$2' (want '$3')"; fi; }

# Seeded cache: glm-5.2 at its real agentic_index (43.1) so a LIVE-scored capable model is present;
# the 5.3 family is deliberately absent (as in the real cache today) and remains unscored.
cat > "$OSRC_BENCH_JSON" <<'BJSON'
{"data":[
 {"model_permaslug":"openai/gpt-5.6-sol-20260709","intelligence_index":58.9,"coding_index":77.4,"agentic_index":54,"pricing":{"prompt":"0.000005","completion":"0.00003"}},
 {"model_permaslug":"z-ai/glm-5.2-20260616","intelligence_index":51.1,"coding_index":68.8,"agentic_index":43.1,"pricing":{"prompt":"0.0000014","completion":"0.0000044"}},
 {"model_permaslug":"anthropic/claude-4.5-haiku-20251001","intelligence_index":29.6,"coding_index":43.9,"agentic_index":16.4,"pricing":{"prompt":"0.000001","completion":"0.000005"}}
],"meta":{"as_of":"2026-08-15T00:00:00.000Z","model_count":3}}
BJSON

EDIT_TASK="edit brain9-task-pipeline.js to fix a resume bug, run the test suite, verify"
REASON_TASK="analyze and evaluate the tradeoffs of the two architectures, assess the implications, critique the strategy and justify the decision"

# === classification: task shape ===
ck "edit-run-verify prompt"             "$(_classify_task "$EDIT_TASK")" agentic
ck "blended: code + 2 agentic hits"     "$(_classify_task "fix the bug, run the tests, make the tests pass")" agentic
ck "pure code stays code"               "$(_classify_task "fix a bug in the api endpoint and add unit test")" code
ck "pure reasoning stays reasoning"     "$(_classify_task "analyze the tradeoffs of microservices vs monolith")" reasoning
ck "edit-run-verify is hard (4 hits)"   "$(_task_difficulty "$EDIT_TASK")" hard


# === table + resolution: GLM-5.3 family with Devin's real (dashed) ids ===
for a in glm-5.3:glm-5-3 glm-5.3-high:glm-5-3-high glm-5.3-flash:glm-5-3-flash glm-5.3-flash-high:glm-5-3-flash-high; do
  row="$(resolve_model_row "${a%%:*}")"; ck "table: ${a%%:*} resolves" "${row%%|*}" "${a##*:}"
  ck "table: ${a%%:*} lane/tier" "$(printf '%s' "$row" | cut -d'|' -f2-3)" "dv|capable"
  _devin_is_free_model "${a##*:}" && ok "plan-included: ${a##*:}" || bad "plan-included predicate misses ${a##*:}"
done
ck "offline sibling map: glm-5.3-flash-high" "$(OSRC_DEVIN_DYNAMIC_RESOLVE=0 _devin_resolve_model glm-5.3-flash-high)" glm-5-3-flash-high
grep -q '^glm-5-3-flash-high|z-ai/glm-5.3-flash$' "$SRC" && ok "bench map: glm-5-3-flash-high -> z-ai/glm-5.3-flash" || bad "bench map entry missing for glm-5-3-flash-high"
grep -q '^glm-5-3|z-ai/glm-5.3$' "$SRC" && ok "bench map: glm-5-3 -> z-ai/glm-5.3" || bad "bench map entry missing for glm-5-3"

# === variant preference helpers ===
ck "family: glm-5-3-flash-high" "$(_variant_family glm-5-3-flash-high)" glm-5-3
ck "family: glm-5-3-high"       "$(_variant_family glm-5-3-high)"       glm-5-3
ck "family: glm-5.2"            "$(_variant_family glm-5.2)"            glm-5-2
ck "family: deepseek-v4-pro-max" "$(_variant_family deepseek-v4-pro-max)" deepseek-v4-pro
w_fh="$(_variant_weight glm-5-3-flash-high high)"; w_h="$(_variant_weight glm-5-3-high high)"; w_f="$(_variant_weight glm-5-3-flash high)"
[ "$w_fh" -lt "$w_h" ] && ok "weight@high: flash-high ($w_fh) lighter than high ($w_h)" || bad "weight@high: flash-high $w_fh vs high $w_h"
[ "$w_fh" -lt "$w_f" ] && ok "weight@high: flash-high ($w_fh) beats bare flash ($w_f) at the requested rung" || bad "weight@high: flash-high $w_fh vs flash $w_f"
[ "$(_variant_weight glm-5-3-flash-low low)" -lt "$(_variant_weight glm-5-3-flash-high low)" ] && ok "weight@low: the low rung wins at --effort low" || bad "weight@low: rung distance not honored"

# A cache from before engineering_index uses the legacy numeric agentic index.
mkdir -p "$OSRC_HOME/catalogs"
echo '["model-a"]' > "$OSRC_HOME/catalogs/dv.json"
echo '{"data":[{"model_permaslug":"vendor/model-a","agentic_index":54,"pricing":{"prompt":"0.000001","completion":"0.000003"}}]}' > "$OSRC_BENCH_JSON"
json="$(cmd_advise --json --effort high "$EDIT_TASK")"
ck "legacy agentic score field" "$(jq -r '.score_field' <<<"$json")" agentic_index
ck "legacy agentic winner" "$(jq -r '.recommendation.model' <<<"$json")" model-a
ck "hard reasoning classification" "$(_task_difficulty "$REASON_TASK")" hard

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
