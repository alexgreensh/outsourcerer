#!/usr/bin/env bash
# Offline coverage for native and OpenRouter catalog discovery and benchmark ranking.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$SCRIPT_DIR"   # sourcing outsourcerer.sh re-points SCRIPT_DIR at scripts/; keep ours
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent (dynamic pool no-ops)"; echo "RESULT: 0 passed, 0 failed"; exit 0; }

T="$(mktemp -d)"; export HOME="$T/fakehome" OSRC_HOME="$T"; mkdir -p "$HOME"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/catalogs"
unset CODEX_HOME OPENROUTER_API_KEY
. "$SRC" >/dev/null 2>&1

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
ck()  { if [ "$2" = "$3" ]; then ok "$1 -> '$2'"; else bad "$1 -> '$2' (want '$3')"; fi; }

refresh_benchmarks() { return 1; }   # never let cmd_advise fetch from the network

# Bench cache keyed by real OpenRouter permaslugs, with the calibration models this feature cares
# about. deepseek-v4-pro at its real live score (44.3) MUST land 'capable', not 'mid'.
seed_bench() {
  cat > "$OSRC_BENCH_JSON" <<'BJSON'
{
  "data": [
    {"model_permaslug":"openai/gpt-5.6-sol-20260709","intelligence_index":58.9,"coding_index":77.4,"agentic_index":54,"pricing":{"prompt":"0.000005","completion":"0.00003"}},
    {"model_permaslug":"x-ai/grok-4.5-20260708","intelligence_index":53.8,"coding_index":70,"agentic_index":45,"pricing":{"prompt":"0.000003","completion":"0.000015"}},
    {"model_permaslug":"z-ai/glm-5.2-20260616","intelligence_index":51.1,"coding_index":68.8,"agentic_index":43.1,"pricing":{"prompt":"0.0000014","completion":"0.0000044"}},
    {"model_permaslug":"deepseek/deepseek-v4-pro-20260423","intelligence_index":44.3,"coding_index":60,"agentic_index":38,"pricing":{"prompt":"0.0000017","completion":"0.0000035"}},
    {"model_permaslug":"deepseek/deepseek-v4-flash-20260423","intelligence_index":40.3,"coding_index":55,"agentic_index":30,"pricing":{"prompt":"0.0000003","completion":"0.0000009"}},
    {"model_permaslug":"anthropic/claude-4.5-haiku-20251001","intelligence_index":29.6,"coding_index":43.9,"agentic_index":16.4,"pricing":{"prompt":"0.000001","completion":"0.000005"}}
  ],
  "meta":{"as_of":"2026-08-15T00:00:00.000Z","model_count":6}
}
BJSON
}

# === _tier_from_score: band mapping, boundaries, non-numeric safety. ===
ck "frontier band"    "$(_tier_from_score 60)"   frontier
ck "frontier edge"    "$(_tier_from_score 55)"   frontier
ck "capable band"     "$(_tier_from_score 50)"   capable
ck "capable edge"     "$(_tier_from_score 44)"   capable
ck "deepseek 44.3"    "$(_tier_from_score 44.3)" capable
ck "just below cap"   "$(_tier_from_score 43.9)" mid
ck "mid band"         "$(_tier_from_score 40)"   mid
ck "mid edge"         "$(_tier_from_score 38)"   mid
ck "budget edge"      "$(_tier_from_score 28)"   budget
ck "below budget raw" "$(_tier_from_score 10)"   raw
ck "empty -> raw"     "$(_tier_from_score "")"   raw
ck "junk -> raw"      "$(_tier_from_score abc)"  raw
ck "negative -> raw"  "$(_tier_from_score -5)"   raw
_err="$(_tier_from_score 'not a number' 2>&1 >/dev/null)"
[ -z "$_err" ] && ok "non-numeric is silent on stderr" || bad "non-numeric leaked stderr: '$_err'"

# === Calibration: each real model's live score reproduces the intended tier. ===
seed_bench
cal() {
  local id="$1" want="$2" got score
  score="$(_bench_lookup "$id" intelligence_index | cut -f1)"
  got="$(_tier_from_score "$score")"
  ck "calibrate $id (idx=$score) -> $want" "$got" "$want"
}
cal openai/gpt-5.6-sol           frontier
cal x-ai/grok-4.5                capable
cal z-ai/glm-5.2                 capable
cal deepseek/deepseek-v4-pro     capable
cal deepseek/deepseek-v4-flash   mid
cal anthropic/claude-4.5-haiku   budget

static_only="$(printf '%s\n' "$OSRC_MODEL_TABLE" | grep -v '^$')"

# Only local entries and catalog IDs are candidates. Repeated lane IDs count once.
printf '%s\n' '["model-a","model-a","model-b-high"]' > "$T/catalogs/dv.json"
echo 'chosen|model-a|dv|mid' > "$T/models.local"
echo '{"data":[{"model_permaslug":"vendor/model-a","intelligence_index":40,"pricing":{"prompt":".000001","completion":".000002"}},{"model_permaslug":"vendor/model-b-20261119","intelligence_index":80}]}' > "$OSRC_BENCH_JSON"
json="$(cmd_advise --json hello)"
ck "deduplicated catalog" "$(jq '.candidates|length' <<<"$json")" 2
ck "local alias retained" "$(jq -r '.recommendation.alias' <<<"$json")" chosen
ck "dated family score" "$(jq '.candidates[]|select(.model=="model-b-high")|.score' <<<"$json")" 80
ck "missing list price" "$(jq '.candidates[]|select(.model=="model-b-high")|.price' <<<"$json")" null
ck "local only mode" "$(OSRC_ADVISE_DYNAMIC_POOL=0 cmd_advise --json hello | jq '.candidates|length')" 1
# One refresh supplies all task indices. Invalid slugs cannot acquire a score.
mkdir -p "$HOME/.codex"
echo '{"models":[{"slug":"model-c"},{"slug":"hidden","visibility":"hide"}]}' > "$HOME/.codex/models_cache.json"
echo model-d-high > "$T/agy-models.txt"
echo '{"families":[{"variants":[{"model_uid":"model-e"}]}]}' > "$T/catalogs/dv.raw.json"
echo '{"data":[{"id":"vendor/model-f","pricing":{"prompt":"0.000001","completion":"0.000001"}}]}' > "$OSRC_MODELS_JSON"
refresh_benchmarks() {
  echo "$1" >> "$T/calls"
  jq -n --arg now "$(date -u +%FT%TZ)" '{meta:{as_of:$now},data:[
    {model_permaslug:null,engineering_index:100},
    {model_permaslug:"openai/model-c",intelligence_index:95,engineering_index:95,pricing:{prompt:".000001",completion:".000002"}},
    {model_permaslug:"google/model-d-20261119",engineering_index:70},
    {model_permaslug:"vendor/model-f",engineering_index:0}]}' > "$OSRC_BENCH_JSON"
}
json="$(cmd_advise --refresh --json --effort max "fix a bug")"
ck "refresh uses intelligence once" "$(cat "$T/calls")" intelligence
ck "native Codex discovery" "$(jq -r '.recommendation.model' <<<"$json")" model-c
ck "hidden CLI ID is absent" "$(jq 'any(.candidates[];.model=="hidden")' <<<"$json")" false
ck "agy effort variant joins its provider" "$(jq '.candidates[]|select(.model=="model-d-high")|.score' <<<"$json")" 70
ck "Devin raw variant is reported" "$(jq 'any(.candidates[];.model=="model-e" and .unscored)' <<<"$json")" true
_session_limits() { echo codexwk=100; }
json="$(cmd_advise --json --effort low "fix a bug")"
ck "limit gate removes exhausted lane before ranking" "$(jq -r '.recommendation.model' <<<"$json")" vendor/model-f
ck "limit note identifies lane" "$(jq -r '.limit_gate' <<<"$json")" cx
ck "measured zero is valid" "$(jq '.recommendation.score' <<<"$json")" 0
ck "current cache serves more tasks without refresh" "$(wc -l < "$T/calls" | tr -d ' ')" 1

# === No fetch on the hot path: a trap `devin` on PATH must never be invoked by enumeration. ===
fb="$T/fakebin"; mkdir -p "$fb"; marker="$T/devin-called.marker"
cat > "$fb/devin" <<EOF
#!/usr/bin/env bash
touch "$marker"; exit 1
EOF
chmod +x "$fb/devin"
cat > "$OSRC_MODELS_JSON" <<'MJSON'
{"data":[{"id":"z-ai/glm-5.2"}]}
MJSON
( PATH="$fb:$PATH" _advise_catalog >/dev/null 2>&1 )
[ -e "$marker" ] && bad "advise hot path invoked devin (fetch leaked)" || ok "advise hot path never invokes devin (cache-only)"
rm -rf "$fb" "$marker"

# === Cost-safety (R6): a discovered glm family still resolves to the FREE variant at delegate. ===
cat > "$T/catalogs/dv.raw.json" <<'RAW'
{"families":[{"family_uid":"glm-5.2","aliases":["glm"],"variants":[{"model_uid":"glm-5-2","cost_summary":"Free"},{"model_uid":"glm-5-2-max","cost_summary":"$0.7 / MTok In"}]}]}
RAW
jq -r '[.families[].variants[].model_uid]' "$T/catalogs/dv.raw.json" > "$T/catalogs/dv.json"
export OSRC_CATALOG_VALIDATE=1 OSRC_DEVIN_DYNAMIC_RESOLVE=1 OSRC_CATALOG_TTL=100000
_dr="$(_devin_resolve_model glm 2>/dev/null)"
[ "$_dr" = "glm-5-2" ] && ok "cost-safety: glm family resolves to FREE glm-5-2 (not -max)" || bad "cost-safety: glm resolved to '$_dr' (want glm-5-2)"
( _catalog_validate dv "totally-bogus-xyz" ) >/dev/null 2>&1 && bad "unknown id wrongly passed _catalog_validate" || ok "unknown id still dies loud at delegate (contract unchanged)"
unset OSRC_CATALOG_TTL

grep -q 'test_advise_dynamic_pool' "$TESTS_DIR/conformance.sh" && ok "suite registered in conformance.sh" || bad "suite not registered"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
