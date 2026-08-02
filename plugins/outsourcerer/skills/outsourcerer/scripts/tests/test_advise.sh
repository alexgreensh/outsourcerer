#!/usr/bin/env bash
# test_advise.sh — tests for the model advisory subcommand (advise).
# Exercises: task classification, benchmark lookup, scoring, recommendation logic,
# graceful degradation (no benchmark data), JSON output, flag parsing.
# All OFFLINE (no network, no real delegation). Run: bash test_advise.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
if [ ! -f "$SRC" ]; then echo FAIL: cannot find $SRC; exit 1; fi

# Keep every durable artifact inside this temp dir, never in ~/.outsourcerer.
TMP="$(mktemp -d)"
export OSRC_HOME="$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Load the source so the functions are defined. main is not run.
. "$SRC" >/dev/null 2>&1

pass=0; fail=0
ok()  { echo PASS: $1; pass=$((pass+1)); }
bad() { echo FAIL: $1; fail=$((fail+1)); }

# === 1. Task classification: keyword-based, five categories. ===
ck() { if [ "$2" = "$3" ]; then ok "$1 -> '$2'"; else bad "$1 -> '$2' (want '$3')"; fi; }

ck "code task"        "$(_classify_task "refactor the authentication module to use JWT tokens")"      code
ck "code task 2"      "$(_classify_task "fix a bug in the api endpoint and add unit test")"            code
ck "reasoning task"   "$(_classify_task "analyze the tradeoffs of microservices vs monolith")"        reasoning
ck "reasoning task 2" "$(_classify_task "evaluate the strategy and prove the mathematical claim")"    reasoning
ck "agentic task"     "$(_classify_task "execute a multi-step workflow with tool calls")"             agentic
ck "agentic task 2"   "$(_classify_task "orchestrate subagent fanout with file system access")"       agentic
ck "creative task"    "$(_classify_task "write a blog post about AI adoption")"                       creative
ck "creative task 2"  "$(_classify_task "write a story about a robot learning to paint")"             creative
ck "simple task"      "$(_classify_task "what is 2 plus 2")"                                          simple
ck "simple task 2"    "$(_classify_task "hello world")"                                               simple

# === 2. Score field mapping per category. ===
ck "code field"       "$(_bench_score_field code)"         coding_index
ck "agentic field"    "$(_bench_score_field agentic)"      agentic_index
ck "reasoning field"  "$(_bench_score_field reasoning)"    intelligence_index
ck "creative field"   "$(_bench_score_field creative)"     intelligence_index
ck "simple field"     "$(_bench_score_field simple)"       intelligence_index
ck "default field"    "$(_bench_score_field unknown)"      intelligence_index

# === 3. Threshold per category. ===
ck "code threshold"      "$(_bench_threshold_for code)"      60
ck "reasoning threshold" "$(_bench_threshold_for reasoning)" 45
ck "agentic threshold"   "$(_bench_threshold_for agentic)"   35
ck "creative threshold"  "$(_bench_threshold_for creative)"  45
ck "simple threshold"    "$(_bench_threshold_for simple)"    0

# === 4. Tier score proxy (when no benchmark data). ===
ck "frontier proxy" "$(_tier_score_proxy frontier)" 55
ck "capable proxy"  "$(_tier_score_proxy capable)"  50
ck "mid proxy"      "$(_tier_score_proxy mid)"      40
ck "budget proxy"   "$(_tier_score_proxy budget)"   30
ck "default proxy"  "$(_tier_score_proxy unknown)"  35

# === 5. Native benchmark slug resolution. ===
ck "fable slug"       "$(_resolve_bench_slug fable)"            anthropic/claude-5-fable
ck "opus slug"        "$(_resolve_bench_slug opus)"             anthropic/claude-4.8-opus
ck "sol slug"         "$(_resolve_bench_slug gpt-5.6-sol)"      openai/gpt-5.6-sol
ck "glm-5.2 slug"     "$(_resolve_bench_slug glm-5.2)"          z-ai/glm-5.2
ck "OR id slug"       "$(_resolve_bench_slug z-ai/glm-5.2)"     z-ai/glm-5.2
ck "free OR id slug"  "$(_resolve_bench_slug tencent/hy3:free)" tencent/hy3
ck "unknown slug"     "$(_resolve_bench_slug unknown-model)"    unknown-model

# === 6. Benchmark lookup with a synthetic cache. ===
# Create a minimal benchmark cache for offline testing.
cat > "$TMP/benchmarks.json" <<'BJSON'
{
  "data": [
    {"model_permaslug":"openai/gpt-5.6-sol-20260709","intelligence_index":58.9,"coding_index":77.4,"agentic_index":54,"pricing":{"prompt":"0.000005","completion":"0.00003"}},
    {"model_permaslug":"z-ai/glm-5.2-20260616","intelligence_index":51.1,"coding_index":68.8,"agentic_index":43.1,"pricing":{"prompt":"0.0000014","completion":"0.0000044"}},
    {"model_permaslug":"anthropic/claude-4.5-haiku-20251001","intelligence_index":29.6,"coding_index":43.9,"agentic_index":16.4,"pricing":{"prompt":"0.000001","completion":"0.000005"}}
  ],
  "meta":{"as_of":"2026-07-14T12:00:13.353Z","model_count":3}
}
BJSON

# _bench_lookup returns "score\tprice_in\tprice_out"
bl="$(_bench_lookup gpt-5.6-sol coding_index)"
ck "bench lookup sol code score"    "$(printf '%s' "$bl" | cut -f1)" 77.4
ck "bench lookup sol code price_in" "$(printf '%s' "$bl" | cut -f2)" 0.000005

bl="$(_bench_lookup glm-5.2 agentic_index)"
ck "bench lookup glm agentic score" "$(printf '%s' "$bl" | cut -f1)" 43.1

bl="$(_bench_lookup haiku coding_index)"
ck "bench lookup haiku code score"  "$(printf '%s' "$bl" | cut -f1)" 43.9

# Lookup for unknown model returns empty.
bl="$(_bench_lookup nonexistent-model coding_index)"
ck "bench lookup unknown empty" "$bl" ""

# === 7. cmd_advise end-to-end with synthetic benchmark data (human output). ===
out="$(cmd_advise "refactor the authentication module" 2>&1)"
if printf '%s' "$out" | grep -q '== outsourcerer advise =='; then ok "advise prints header"; else bad "advise missing header"; fi
if printf '%s' "$out" | grep -q 'category: code'; then ok "advise classifies as code"; else bad "advise wrong category"; fi
if printf '%s' "$out" | grep -q 'coding_index'; then ok "advise uses coding_index field"; else bad "advise wrong field"; fi
if printf '%s' "$out" | grep -q 'recommendation'; then ok "advise prints recommendation"; else bad "advise missing recommendation"; fi
if printf '%s' "$out" | grep -q 'Run with:'; then ok "advise prints run command"; else bad "advise missing run command"; fi
if printf '%s' "$out" | grep -q 'benchmark data:'; then ok "advise reports benchmark status"; else bad "advise missing benchmark status"; fi

# === 8. cmd_advise JSON output. ===
json="$(cmd_advise --json "refactor the authentication module" 2>&1)"
if printf '%s' "$json" | jq -e '.category == "code"' >/dev/null 2>&1; then ok "json has category=code"; else bad "json category wrong"; fi
if printf '%s' "$json" | jq -e '.recommendation.alias' >/dev/null 2>&1; then ok "json has recommendation.alias"; else bad "json missing recommendation.alias"; fi
if printf '%s' "$json" | jq -e '.benchmark_coverage' >/dev/null 2>&1; then ok "json reports benchmark_coverage"; else bad "json benchmark flag wrong"; fi

# === 9. cmd_advise graceful degradation (no benchmark cache). ===
rm -f "$TMP/benchmarks.json"
# Mock refresh_benchmarks to prevent network calls (it would succeed with OR key from ~/.env).
refresh_benchmarks() { return 1; }
out="$(cmd_advise "refactor the authentication module" 2>&1)"
if printf '%s' "$out" | grep -q 'benchmark data: none'; then ok "advise falls back to tier proxy"; else bad "advise missing fallback message"; fi
if printf '%s' "$out" | grep -q 'recommendation'; then ok "advise still recommends without benchmarks"; else bad "advise fails without benchmarks"; fi
# Restore real refresh_benchmarks for subsequent tests.
unset -f refresh_benchmarks

# === 10. cmd_advise flag parsing. ===
out="$(cmd_advise --json "simple task" 2>&1)"
if printf '%s' "$out" | jq -e '.category == "simple"' >/dev/null 2>&1; then ok "json simple category"; else bad "json simple category wrong"; fi

# === 11. cmd_advise dies on empty task. ===
# Run in a subshell so die() doesn't exit the test shell.
err_msg="$(bash -c '. "$0" >/dev/null 2>&1; cmd_advise "" 2>&1' "$SRC" 2>&1)"
if printf '%s' "$err_msg" | grep -q 'advise needs a task'; then ok "advise rejects empty task"; else bad "advise accepts empty task: '$err_msg'"; fi

# === 12. cmd_advise recommendation favors capable value above the threshold. ===
cat > "$TMP/benchmarks.json" <<'BJSON'
{
  "data": [
    {"model_permaslug":"openai/gpt-5.6-sol-20260709","intelligence_index":58.9,"coding_index":77.4,"agentic_index":54,"pricing":{"prompt":"0.000005","completion":"0.00003"}},
    {"model_permaslug":"z-ai/glm-5.2-20260616","intelligence_index":51.1,"coding_index":68.8,"agentic_index":43.1,"pricing":{"prompt":"0.0000014","completion":"0.0000044"}},
    {"model_permaslug":"anthropic/claude-4.5-haiku-20251001","intelligence_index":29.6,"coding_index":43.9,"agentic_index":16.4,"pricing":{"prompt":"0.000001","completion":"0.000005"}}
  ],
  "meta":{"as_of":"2026-07-14T12:00:13.353Z","model_count":3}
}
BJSON
json="$(cmd_advise --json "refactor the authentication module" 2>&1)"
rec_alias="$(printf '%s' "$json" | jq -r '.recommendation.alias')"
# The capable GLM lane clears the coding threshold and is preferred over a frontier model that is
# unnecessary for this medium-effort task.
if [ "$rec_alias" = "glm" ] || [ "$rec_alias" = "glm-5.2" ] || [ "$rec_alias" = "z-ai/glm-5.2" ]; then
  ok "advise recommends capable value for ordinary code work"
else
  bad "advise recommended '$rec_alias' instead of a capable GLM lane"
fi

# === 13. Image lanes are excluded from advisory. ===
out="$(cmd_advise "refactor the authentication module" 2>&1)"
if printf '%s' "$out" | grep -q 'nano-banana'; then bad "advise includes image lane (nano-banana)"; else ok "advise excludes image lanes"; fi
if printf '%s' "$out" | grep -q 'gpt-image'; then bad "advise includes image lane (gpt-image)"; else ok "advise excludes gpt-image lane"; fi

# === 14. Source-level invariants (conformance cross-check). ===
grep -q 'cmd_advise'                 "$SRC" && ok "cmd_advise wired in source"           || bad "cmd_advise missing from source"
grep -q 'advise)'                    "$SRC" && ok "advise in main() dispatch"            || bad "advise not in main() dispatch"
grep -q '_classify_task'             "$SRC" && ok "_classify_task present"               || bad "_classify_task missing"
grep -q '_bench_lookup'              "$SRC" && ok "_bench_lookup present"                || bad "_bench_lookup missing"
grep -q 'refresh_benchmarks'         "$SRC" && ok "refresh_benchmarks present"           || bad "refresh_benchmarks missing"
grep -q 'OSRC_BENCH_JSON'            "$SRC" && ok "OSRC_BENCH_JSON cache path defined"   || bad "OSRC_BENCH_JSON missing"
grep -q '_NATIVE_BENCH_MAP'          "$SRC" && ok "_NATIVE_BENCH_MAP defined"            || bad "_NATIVE_BENCH_MAP missing"
# Help text includes advise.
grep -q 'advise'                     "$SRC" && ok "advise in help text"                  || bad "advise not in help text"

# ---- limits-left folded into the recommendation (per-lane conservation) ---------------------------
# A measurable subscription lane past the conserve line takes a gentle score haircut; unmeasurable lanes
# never do (we never invent a limit we can't read). At/below the line -> 1.00.
[ "$(_lane_conserve_mult cc 'claude5h=8')"   = "1.00"   ] && ok "cc at headroom (8%) -> no haircut" || bad "cc penalized below the conserve line"
[ "$(_lane_conserve_mult cc 'claude5h=50')"  = "1.0000" ] && ok "cc exactly at the line -> no haircut" || bad "cc penalized at the line"
awk -v m="$(_lane_conserve_mult cc 'claude5h=100')" 'BEGIN{exit !(m<1.0 && m>=0.90)}' && ok "cc fully spent -> capped ~0.90 haircut" || bad "cc full-spend haircut out of range"
[ "$(_lane_conserve_mult cx 'codex5h=60 codexwk=90')" = "0.9200" ] && ok "cx uses the MORE-spent of 5h/weekly (90%)" || bad "cx did not pick the more-spent window"
[ "$(_lane_conserve_mult dv 'claude5h=100')" = "1.00" ] && ok "devin lane is never haircut (unmeasured, never invent)" || bad "devin got a fabricated limit penalty"
[ "$(_lane_conserve_mult or 'claude5h=100')" = "1.00" ] && ok "openrouter lane is never haircut (unmeasured)" || bad "openrouter got a fabricated limit penalty"
# integration: with a lane forced past the line, advise prints the conservation line; opt-out silences it.
# Stub _session_limits high, capture output, then restore the real definition.
_advise_real_limits="$(declare -f _session_limits)"
_session_limits() { printf 'claude5h=95 codexwk=90\n'; }
_adv_on="$(cmd_advise "refactor the auth module" 2>/dev/null)"
_adv_off="$(OSRC_ADVISE_CONSERVE=0 cmd_advise "refactor the auth module" 2>/dev/null)"
[ -n "$_advise_real_limits" ] && eval "$_advise_real_limits"   # restore real limits reader
printf '%s' "$_adv_on"  | grep -qi 'conservation:' && ok "advise surfaces the conservation line when a lane is past the line" || bad "advise did not surface conservation"
printf '%s' "$_adv_off" | grep -qi 'conservation:' && bad "OSRC_ADVISE_CONSERVE=0 did not disable the haircut" || ok "OSRC_ADVISE_CONSERVE=0 disables conservation"
grep -q 'conservation:(if $conserve==""' "$SRC" && ok "conservation exposed in --json output" || bad "conservation missing from json"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL ($fail failures)" >&2; exit 1; fi
echo "RESULT: PASS ($pass checks passed, 0 failures)"
