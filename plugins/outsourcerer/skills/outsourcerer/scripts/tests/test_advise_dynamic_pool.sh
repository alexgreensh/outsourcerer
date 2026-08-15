#!/usr/bin/env bash
# test_advise_dynamic_pool.sh — the dynamic advise candidate pool + score-derived tiering.
# Deterministic (seeded caches, no live CLI, no network). Covers:
#   - _tier_from_score band mapping + non-numeric safety + real-score calibration.
#   - _advise_candidate_rows: OpenRouter scored-only discovery, a never-seen model wins on merit,
#     an UNSCORED id is skipped, no Devin catalog uid enters the pool, escape hatch, offline ==
#     static baseline, empty/garbage cache fail-open, the top-N cap, no fetch on the hot path.
#   - cost-safety + die-loud validation unchanged at delegate, suite registered.
# The benchmark cache is keyed by OpenRouter permaslugs (e.g. z-ai/glm-5.2-...), so discovery
# uses OpenRouter-form ids from models.json; Devin catalog uids do NOT match bench and are not
# enumerated. Fixtures use real id forms so the id/bench matching is exercised for real.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent (dynamic pool no-ops)"; echo "RESULT: 0 passed, 0 failed"; exit 0; }

T="$(mktemp -d)"; export OSRC_HOME="$T"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/catalogs"
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
printf '%s\n' "$pool" | grep -q '^acme/nova-max-1|acme/nova-max-1|or|frontier$' \
  && ok "discovery: new OR id enters the pool with score-derived tier (frontier)" \
  || bad "discovery: new OR id missing or wrong tier"
# Discovered strong model wins the recommendation for a frontier-required task.
json="$(cmd_advise --json --effort max "refactor the authentication module" 2>&1)"
rec="$(printf '%s' "$json" | jq -r '.recommendation.alias' 2>/dev/null)"
[ "$rec" = "acme/nova-max-1" ] && ok "discovery: never-seen model wins on merit" || bad "advise picked '$rec' instead of acme/nova-max-1"

# === Scored-only (perf + merit guard): an UNSCORED OpenRouter id is NOT added to the pool. ===
printf '%s\n' "$pool" | grep -q 'or-unscored-xyz' && bad "scored-only violated: unscored id entered the pool" || ok "scored-only: an unscored OR id is skipped"

# === No Devin noise: the pool's dv-lane rows are exactly the static table's (no discovered uids). ===
# Seed a Devin catalog with a variant uid that is NOT in bench; it must NEVER appear as a candidate.
cat > "$T/catalogs/dv.raw.json" <<'RAW'
{"families":[{"family_uid":"phantom","aliases":[],"variants":[{"model_uid":"phantom-v9-high","cost_summary":"Free"}]}]}
RAW
pool2="$(_advise_candidate_rows intelligence_index)"
printf '%s\n' "$pool2" | grep -q 'phantom-v9-high' && bad "a Devin catalog uid leaked into the pool" || ok "no Devin catalog uid enters the pool (bench-unmatched noise excluded)"
dv_dyn="$(printf '%s\n' "$pool2" | awk -F'|' '$3=="dv"{print $2}' | sort -u)"
dv_static="$(printf '%s\n' "$static_only" | awk -F'|' '$3=="dv"{print $2}' | sort -u)"
[ "$dv_dyn" = "$dv_static" ] && ok "dv-lane candidates == static table only" || bad "dv-lane candidates diverged from the static table"
rm -f "$T/catalogs/dv.raw.json"

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

# === Escape hatch (R5): OSRC_ADVISE_DYNAMIC_POOL=0 == the static table, byte-identical. ===
cat > "$OSRC_MODELS_JSON" <<'MJSON'
{"data":[{"id":"acme/nova-max-1"},{"id":"z-ai/glm-5.2"}]}
MJSON
hatch_out="$(OSRC_ADVISE_DYNAMIC_POOL=0 _advise_candidate_rows)"
[ "$hatch_out" = "$static_only" ] && ok "escape hatch: output == static table (byte-identical)" || bad "escape hatch diverged from static table"
printf '%s\n' "$hatch_out" | grep -q 'acme/nova-max-1' && bad "escape hatch leaked a dynamic id" || ok "escape hatch drops dynamic ids"

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
grep -q '_advise_candidate_rows "\$field"' "$SRC" && ok "ranking loop sources _advise_candidate_rows" || bad "ranking loop not swapped"
grep -q 'OSRC_ADVISE_DYNAMIC_POOL' "$SRC" && ok "OSRC_ADVISE_DYNAMIC_POOL documented" || bad "OSRC_ADVISE_DYNAMIC_POOL not documented"
grep -q 'OSRC_ADVISE_DYNAMIC_MAX'  "$SRC" && ok "OSRC_ADVISE_DYNAMIC_MAX documented" || bad "OSRC_ADVISE_DYNAMIC_MAX not documented"
grep -q '_tier_from_score' "$SRC" && ok "_tier_from_score present" || bad "_tier_from_score missing"
grep -q 'test_advise_dynamic_pool' "$SCRIPT_DIR/conformance.sh" && ok "suite registered in conformance.sh" || bad "suite not registered"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
