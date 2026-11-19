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

# === Merit discovery (R3): a never-seen OpenRouter id with a strong score is discovered and wins. ===
# Seed the synthetic id into BOTH models.json (OpenRouter catalog) and the bench cache. It is NOT in
# OSRC_MODEL_TABLE, so it can only be recommended if enumeration + scoring discover it on merit.
jq '.data += [{"model_permaslug":"acme/nova-max-1","intelligence_index":95,"coding_index":95,"agentic_index":95,"pricing":{"prompt":"0","completion":"0"}}]' \
  "$OSRC_BENCH_JSON" > "$OSRC_BENCH_JSON.tmp" && mv -f "$OSRC_BENCH_JSON.tmp" "$OSRC_BENCH_JSON"
cat > "$OSRC_MODELS_JSON" <<'MJSON'
{"data":[{"id":"acme/nova-max-1"},{"id":"x-ai/grok-4.5"},{"id":"or-unscored-xyz"}]}
MJSON
pool="$(_advise_candidate_rows intelligence_index)"
grep -q '^acme/nova-max-1|acme/nova-max-1|or|frontier$' <<<"$pool" \
  && ok "discovery: new OR id enters the pool with score-derived tier (frontier)" \
  || bad "discovery: new OR id missing or wrong tier"
# Discovered strong model wins the recommendation for a frontier-required task.
json="$(cmd_advise --json --effort max "refactor the authentication module" 2>&1)"
rec="$(printf '%s' "$json" | jq -r '.recommendation.alias' 2>/dev/null)"
[ "$rec" = "acme/nova-max-1" ] && ok "discovery: never-seen model wins on merit" || bad "advise picked '$rec' instead of acme/nova-max-1"

grep -qx 'or-unscored-xyz|or-unscored-xyz|or|raw' <<<"$pool" && ok "unscored OR model included" || bad "missing unscored catalog model"

cat > "$T/catalogs/dv.raw.json" <<'RAW'
{"families":[{"family_uid":"phantom","aliases":[],"variants":[{"model_uid":"phantom-v9-high","cost_summary":"Free"}]}]}
RAW
pool2="$(_advise_candidate_rows intelligence_index)"
grep -qx 'phantom-v9-high|phantom-v9-high|dv|raw' <<<"$pool2" && ok "Devin variant enters pool" || bad "missing Devin variant"
printf '%s\n' 'gemini-9-test-high' > "$T/agy-models.txt"
mkdir -p "$HOME/.codex"
printf '%s\n' '{"models":[{"slug":"gpt-future"}]}' > "$HOME/.codex/models_cache.json"
pool3="$(unset CODEX_HOME; _advise_candidate_rows)"
grep -qx 'gemini-9-test-high|gemini-9-test-high|gm|raw' <<< "$pool3" && ok "agy catalog candidate" || bad "missing agy id"
grep -qx 'gpt-future|gpt-future|cx|raw' <<< "$pool3" && ok "Codex catalog candidate" || bad "missing Codex id"
rm -f "$T/agy-models.txt" "$HOME/.codex/models_cache.json"
rm -f "$T/catalogs/dv.raw.json"

(
  OSRC_MODEL_TABLE=$'fable52|claude-fable-5-2|cc|frontier\nunknown|unknown|cc|raw'
  OSRC_ADVISE_ROUTER=0
  OSRC_BENCH_JSON="$T/real-shape.json"
  cat > "$OSRC_BENCH_JSON" <<'JSON'
{"meta":{"source":"artificial-analysis","task_type":"intelligence","as_of":"2026-11-19T12:00:35.472Z"},
 "data":[{"source":"artificial-analysis","model_permaslug":"anthropic/claude-fable-5.2-20261109",
          "intelligence_index":64.6,"coding_index":null,"agentic_index":null,"pricing":{"prompt":"0.000016"}},
         {"model_permaslug":null,"intelligence_index":99}]}
JSON
  refresh_benchmarks() {
    [ "$1" = coding ] || return 1
    printf '%s\n' '{"data":[{"model_permaslug":"anthropic/claude-fable-5.2-20261109","coding_index":72.5}]}' > "$OSRC_BENCH_JSON"
  }
  export OPENROUTER_API_KEY=test
  cmd_advise --json 'fix a bug' | jq -e '.shortlist[0].alias=="fable52" and .shortlist[0].score==72.5 and .unscored_catalog_count==3 and (.shortlist|length)==2' &&
    cmd_advise --json 'analyze tradeoffs' | jq -e '.shortlist[0].score==64.6 and .shortlist[1].unscored'
) >/dev/null && ok "task-specific refresh preserves intelligence and counts unscored catalog rows" || bad "real cache shape or task-specific refresh"

# === Dedup, static wins: an id in both models.json and the static table appears once, static row. ===
cat > "$OSRC_MODELS_JSON" <<'MJSON'
{"data":[{"id":"z-ai/glm-5.2"}]}
MJSON
cnt="$(_advise_candidate_rows | awk -F'|' -v r='z-ai/glm-5.2' '$2==r{c++} END{print c+0}')"
cnt_static="$(printf '%s\n' "$static_only" | awk -F'|' -v r='z-ai/glm-5.2' '$2==r{c++} END{print c+0}')"
[ "$cnt" = "$cnt_static" ] && ok "dedup: static id count unchanged (static wins, no dynamic dup)" || bad "dedup: dynamic pass duplicated a static id ($cnt != $cnt_static)"

# === Top-N cap: OSRC_ADVISE_DYNAMIC_MAX bounds how many discovered ids are added. ===
jq -n '{data: [range(0;10) | {model_permaslug: ("acme/m\(.)" ), intelligence_index: (50 + .)}]}' > "$OSRC_BENCH_JSON"
jq -n '{data: [range(0;10) | {id: ("acme/m\(.)")}]}' > "$OSRC_MODELS_JSON"
n_added="$(OSRC_ADVISE_DYNAMIC_MAX=3 _advise_candidate_rows | awk -F'|' '$3=="or" && $1 ~ /^acme\/m/{c++} END{print c+0}')"
[ "$n_added" = "3" ] && ok "top-N cap: OSRC_ADVISE_DYNAMIC_MAX=3 adds exactly 3 discovered ids" || bad "top-N cap: added $n_added (want 3)"
# And they are the STRONGEST three (m9,m8,m7 at scores 59,58,57), not an arbitrary three.
top3="$(OSRC_ADVISE_DYNAMIC_MAX=3 _advise_candidate_rows | awk -F'|' '$3=="or" && $1 ~ /^acme\/m/{print $1}' | sort)"
[ "$top3" = "$(printf 'acme/m7\nacme/m8\nacme/m9')" ] && ok "top-N cap: keeps the strongest-scoring ids" || bad "top-N cap: kept '$top3' (want m7,m8,m9)"
seed_bench

# The tie window is anchored at the highest score, so it cannot chain through a third model.
rank_rows=$'high|high|or|raw|80|0.0002|1\nnear|near|cc|raw|79|plan limits|1\nfar|far|cx|raw|78.9|plan limits|1\nmissing|missing|dv|raw|unscored|plan limits|1'
ck "near tie chooses plan cost" "$(OSRC_ADVISE_TIE=1 _advise_rank 0 <<< "$rank_rows" | cut -d'|' -f1 | paste -sd, -)" "near,high,far,missing"
ck "zero window chooses raw score" "$(OSRC_ADVISE_TIE=0 _advise_rank 0 <<< "$rank_rows" | cut -d'|' -f1 | paste -sd, -)" "high,near,far,missing"

# Exercise filtering and missing fields through the public command with a tiny, deterministic pool.
advice="$(
  OSRC_MODEL_TABLE=$'free|gpt-6.2-astra|cx|frontier\npaid|acme/b|or|raw\nmissing|acme/c|or|raw'
  OSRC_ADVISE_DYNAMIC_POOL=0
  OSRC_ADVISE_ROUTER=0
  OSRC_BENCH_JSON="$T/filter-bench.json"
  printf '%s\n' '{"data":[{"model_permaslug":"openai/gpt-6.2-astra","coding_index":87},{"model_permaslug":"acme/b","coding_index":0},{"model_permaslug":"acme/c","intelligence_index":99}]}' > "$OSRC_BENCH_JSON"
  _session_limits() { printf 'codexwk=100'; }
  cmd_advise --json "refactor code"
)"
jq -e '.recommendation.alias=="paid" and .shortlist[0].score==0 and .shortlist[1].unscored and (.limit_gate|contains("cx excluded"))' <<< "$advice" >/dev/null \
  && ok "exhausted lane skipped; measured zero beats missing coding score" || bad "incorrect limit or missing-field fallback"
# Check the actual JSON contract, including a missing field alongside a true zero.
jq -e 'has("conservation") and .conservation==null' <<< "$advice" >/dev/null && ok "JSON includes conservation metadata" || bad "JSON conservation field missing"
(
  OSRC_BENCH_JSON="$T/fable-vs-glm.json"
  printf '%s\n' '{"data":[{"model_permaslug":"anthropic/claude-5.1-fable","intelligence_index":59.9},{"model_permaslug":"z-ai/glm-5.2","intelligence_index":59.1}]}' > "$OSRC_BENCH_JSON"
  OSRC_ADVISE_DYNAMIC_POOL=0
  OSRC_ADVISE_CONSERVE=0
  OSRC_LANE_LIMIT_GATE=0
  cmd_advise --json "Analyze the tradeoffs of three caching architectures and recommend one" |
    jq -e '.recommendation.alias=="fable" and (.recommendation.reason|contains("highest intelligence score (59.9)")) and .shortlist[0].score==59.9'
) >/dev/null && ok "Fable beats GLM by raw reasoning score" || bad "caching architecture recommendation"
# === Escape hatch (R5): OSRC_ADVISE_DYNAMIC_POOL=0 == the static table, byte-identical. ===
cat > "$OSRC_MODELS_JSON" <<'MJSON'
{"data":[{"id":"acme/nova-max-1"},{"id":"z-ai/glm-5.2"}]}
MJSON
hatch_out="$(OSRC_ADVISE_DYNAMIC_POOL=0 _advise_candidate_rows)"
[ "$hatch_out" = "$static_only" ] && ok "escape hatch: output == static table (byte-identical)" || bad "escape hatch diverged from static table"
grep -q 'acme/nova-max-1' <<<"$hatch_out" && bad "escape hatch leaked a dynamic id" || ok "escape hatch drops dynamic ids"

# === Offline: no caches -> output == static table (the pre-dynamic candidate set). ===
rm -f "$OSRC_MODELS_JSON" "$OSRC_BENCH_JSON"
[ "$(_advise_candidate_rows)" = "$static_only" ] && ok "offline: no caches -> output == static table" || bad "offline diverged from static table"

# === Empty / garbage caches: zero dynamic rows, no crash (fail-open). ===
seed_bench
printf '[]' > "$OSRC_MODELS_JSON"
[ "$(_advise_candidate_rows 2>&1)" = "$static_only" ] && ok "empty models.json ([]) -> static only, no crash" || bad "empty models.json broke fail-open"
printf 'not json' > "$OSRC_MODELS_JSON"
[ "$(_advise_candidate_rows 2>&1)" = "$static_only" ] && ok "garbage models.json -> static only, no crash" || bad "garbage models.json broke fail-open"
printf 'not json' > "$OSRC_BENCH_JSON"
[ "$(_advise_candidate_rows 2>&1)" = "$static_only" ] && ok "garbage bench -> static only, no crash" || bad "garbage bench broke fail-open"
seed_bench

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
( PATH="$fb:$PATH" _advise_candidate_rows >/dev/null 2>&1 )
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

# === Source-level invariants: loop swapped, hatch + cap documented, suite registered. ===
grep -q '_advise_candidate_rows "\$field"' "${SRC%/*}/lib/advise.sh" && ok "ranking loop sources _advise_candidate_rows" || bad "ranking loop not swapped"
grep -q 'OSRC_ADVISE_DYNAMIC_POOL' "${SRC%/*}/lib/advise.sh" && ok "OSRC_ADVISE_DYNAMIC_POOL documented" || bad "OSRC_ADVISE_DYNAMIC_POOL not documented"
grep -q 'OSRC_ADVISE_DYNAMIC_MAX'  "${SRC%/*}/lib/advise.sh" && ok "OSRC_ADVISE_DYNAMIC_MAX documented" || bad "OSRC_ADVISE_DYNAMIC_MAX not documented"
grep -q '_tier_from_score' "$SRC" && ok "_tier_from_score present" || bad "_tier_from_score missing"
grep -q 'test_advise_dynamic_pool' "$TESTS_DIR/conformance.sh" && ok "suite registered in conformance.sh" || bad "suite not registered"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
