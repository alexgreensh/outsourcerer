#!/usr/bin/env bash
# test_advise_task_shape.sh — advise routes by TASK SHAPE, not just keyword tally. Pins the fixes for
# the 2026-09-15 incident: an edit + run-tests + verify prompt classifies `agentic` (multi-step tool
# use) and does NOT pick kimi #1 (its near-frontier bump is reasoning-only now); the GLM-5.3 family is
# in the table with Devin's real ids; the lighter variant (glm-5.3-flash-high) is preferred over
# glm-5.3-high at effort <= high but NOT at effort max; a hard pure-reasoning prompt STILL picks kimi.
# All OFFLINE: a seeded benchmark cache, refresh stubbed, conservation off.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
SRC_LIB="$SRC $SCRIPT_DIR/../lib/advise.sh $SCRIPT_DIR/../lib/advise-score.sh $SCRIPT_DIR/../lib/advise-fetch.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"; export HOME="$TMP"
cleanup() { rm -rf "$TMP"; }; trap cleanup EXIT
export OSRC_ADVISE_CONSERVE=0 OSRC_ADVISE_DYNAMIC_POOL=0 OSRC_HEARTBEAT_DISABLED=1
. "$SRC" >/dev/null 2>&1
refresh_benchmarks() { return 1; }   # never touch the network
have jq || { echo "SKIP: jq required for advise"; exit 0; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
ck()  { if [ "$2" = "$3" ]; then ok "$1 -> '$2'"; else bad "$1 -> '$2' (want '$3')"; fi; }

# Seeded cache: glm-5.2 at its real agentic_index (43.1) so a LIVE-scored capable model is present;
# the 5.3 family is deliberately absent (as in the real cache today) and scores via the tier proxy.
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

# === scoring: the kimi bump is reasoning-only ===
ck "kimi bump on hard reasoning"  "$(_score 50 capable reasoning high hard kimi-k3)" 80.0000
ck "NO kimi bump on hard agentic" "$(_score 50 capable agentic high hard kimi-k3)"   60.0000
ck "NO kimi bump on hard code"    "$(_score 50 capable code high hard kimi-k3)"      60.0000

# === table + resolution: GLM-5.3 family with Devin's real (dashed) ids ===
for a in glm-5.3:glm-5-3 glm-5.3-high:glm-5-3-high glm-5.3-flash:glm-5-3-flash glm-5.3-flash-high:glm-5-3-flash-high; do
  row="$(resolve_model_row "${a%%:*}")"; ck "table: ${a%%:*} resolves" "${row%%|*}" "${a##*:}"
  ck "table: ${a%%:*} lane/tier" "$(printf '%s' "$row" | cut -d'|' -f2-3)" "dv|capable"
  _devin_is_free_model "${a##*:}" && ok "plan-included: ${a##*:}" || bad "plan-included predicate misses ${a##*:}"
done
ck "offline sibling map: glm-5.3-flash-high" "$(OSRC_DEVIN_DYNAMIC_RESOLVE=0 _devin_resolve_model glm-5.3-flash-high)" glm-5-3-flash-high
grep -q '^glm-5-3-flash-high|z-ai/glm-5.3-flash$' $SRC_LIB && ok "bench map: glm-5-3-flash-high -> z-ai/glm-5.3-flash" || bad "bench map entry missing for glm-5-3-flash-high"
grep -q '^glm-5-3|z-ai/glm-5.3$' $SRC_LIB && ok "bench map: glm-5-3 -> z-ai/glm-5.3" || bad "bench map entry missing for glm-5-3"

# === variant preference helpers ===
ck "family: glm-5-3-flash-high" "$(_variant_family glm-5-3-flash-high)" glm-5-3
ck "family: glm-5-3-high"       "$(_variant_family glm-5-3-high)"       glm-5-3
ck "family: glm-5.2"            "$(_variant_family glm-5.2)"            glm-5-2
ck "family: deepseek-v4-pro-max" "$(_variant_family deepseek-v4-pro-max)" deepseek-v4-pro
w_fh="$(_variant_weight glm-5-3-flash-high high)"; w_h="$(_variant_weight glm-5-3-high high)"; w_f="$(_variant_weight glm-5-3-flash high)"
[ "$w_fh" -lt "$w_h" ] && ok "weight@high: flash-high ($w_fh) lighter than high ($w_h)" || bad "weight@high: flash-high $w_fh vs high $w_h"
[ "$w_fh" -lt "$w_f" ] && ok "weight@high: flash-high ($w_fh) beats bare flash ($w_f) at the requested rung" || bad "weight@high: flash-high $w_fh vs flash $w_f"
[ "$(_variant_weight glm-5-3-flash-low low)" -lt "$(_variant_weight glm-5-3-flash-high low)" ] && ok "weight@low: the low rung wins at --effort low" || bad "weight@low: rung distance not honored"

# === end-to-end advise ===
pick() { cmd_advise --effort "$1" "$2" 2>/dev/null | awk -F': *' '/^   model:/{print $2; exit}' | awk '{print $1}'; }
_adv="$(cmd_advise --effort high "$EDIT_TASK" 2>/dev/null)"
grep -q '^   category: agentic' <<<"$_adv" && ok "advise: edit-run-verify -> category agentic" || bad "advise: category not agentic"
grep -q 'score field: agentic_index' <<<"$_adv" && ok "advise: scored on agentic_index" || bad "advise: wrong score field"
_pick="$(printf '%s' "$_adv" | awk -F': *' '/^   model:/{print $2; exit}' | awk '{print $1}')"
case "$_pick" in kimi|kimi-k3|kimi-k2.7) bad "advise: kimi is #1 on the edit-run-verify task ($_pick)" ;; *) ok "advise: kimi is NOT #1 (pick: $_pick)" ;; esac
[ "$_pick" = "glm-5.3-flash-high" ] && ok "advise: recommends glm-5.3-flash-high" || bad "advise: pick '$_pick' (want glm-5.3-flash-high)"
{ _t3b_pipe="$(printf '%s' "$_adv" | grep -E '^\s+glm-5\.3-high ')" && grep -q 'lighter sibling preferred' <<<"$_t3b_pipe"; } && ok "advise: glm-5.3-high listed as 'lighter sibling preferred' at effort high" || bad "advise: glm-5.3-high not demoted"
{ _t3b_pipe="$(printf '%s' "$_adv" | grep -E '^>> glm-5\.3-flash-high ')" && grep -q ' OK$' <<<"$_t3b_pipe"; } && ok "advise: flash-high row is the recommended (>>) OK row" || bad "advise: flash-high row not marked recommended"
_json="$(cmd_advise --json --effort high "$EDIT_TASK" 2>/dev/null)"
[ "$(printf '%s' "$_json" | jq -r '.recommendation.alias')" = "glm-5.3-flash-high" ] && ok "advise --json: recommendation.alias" || bad "advise --json: alias '$(printf '%s' "$_json" | jq -r '.recommendation.alias')'"
[ "$(printf '%s' "$_json" | jq -r '.shortlist[0].alias')" = "glm-5.3-flash-high" ] && ok "advise --json: shortlist[0] is the pick (demoted siblings leave the top group)" || bad "advise --json: shortlist[0] '$(printf '%s' "$_json" | jq -r '.shortlist[0].alias')'"
[ "$(printf '%s' "$_json" | jq -r '[.shortlist[]|select(.alias=="glm-5.3-high")|.lighter_sibling_preferred][0]')" = "true" ] && ok "advise --json: glm-5.3-high flagged lighter_sibling_preferred" || bad "advise --json: flag missing on glm-5.3-high"
# effort max: variant preference OFF (the heavier rung is the point)
_max="$(cmd_advise --effort max "$EDIT_TASK" 2>/dev/null)"
grep -q 'lighter sibling preferred' <<<"$_max" && bad "advise --effort max: variant preference still demoting" || ok "advise --effort max: no variant demotion"
# OSRC_ADVISE_VARIANT_PREF=0 escape hatch
{ _t3b_pipe="$(OSRC_ADVISE_VARIANT_PREF=0 cmd_advise --effort high "$EDIT_TASK" 2>/dev/null)" && grep -q 'lighter sibling preferred' <<<"$_t3b_pipe"; } && bad "OSRC_ADVISE_VARIANT_PREF=0 ignored" || ok "OSRC_ADVISE_VARIANT_PREF=0 disables the preference"
# hard pure-reasoning: kimi STILL wins
_r="$(cmd_advise --effort high "$REASON_TASK" 2>/dev/null)"
grep -q '^   category: reasoning' <<<"$_r" && grep -q '^   difficulty: hard' <<<"$_r" && ok "reasoning task: category reasoning, difficulty hard" || bad "reasoning task: classification drifted"
_rp="$(printf '%s' "$_r" | awk -F': *' '/^   model:/{print $2; exit}' | awk '{print $1}')"
case "$_rp" in kimi|kimi-k3) ok "reasoning task: kimi still #1 ($_rp)" ;; *) bad "reasoning task: kimi lost #1 to '$_rp'" ;; esac
{ _t3b_pipe="$(printf '%s' "$_r" | grep -E '^>> kimi ')" && grep -q 'score=80' <<<"$_t3b_pipe"; } && ok "reasoning task: kimi carries the +20 near-frontier bump (score 80)" || bad "reasoning task: kimi score not 80"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
