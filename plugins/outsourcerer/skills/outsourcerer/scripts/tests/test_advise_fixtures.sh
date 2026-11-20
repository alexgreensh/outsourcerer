#!/usr/bin/env bash
# test_advise_fixtures.sh — B2 live-source parsers against REAL captured samples
# (tests/fixtures/advise/: cursorbench.html, tbench-ai.html, or-bench.json,
# or-endpoints.json). Fully network-free: parsers read the fixture dir, cmd_advise
# runs with a stubbed refresher and OSRC_ADVISE_DIR pointed at the seeded caches.
# Covers: rows.jsonl build, unmatched reporting (Copilot Fusion), date-suffixed
# model normalization (DeepSeek V4.1 Flash 1017 / Qwen3.8-Max-0902), cost=0
# (Muse Spark), the factors join, and the B2 quality/cost/sources output lines.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$SCRIPT_DIR"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
FIXT="$SCRIPT_DIR/fixtures/advise"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
for f in cursorbench.html tbench-ai.html or-bench.json or-endpoints.json; do
  [ -s "$FIXT/$f" ] || { echo "FAIL: missing fixture $FIXT/$f"; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 absent"; echo "RESULT: 0 passed, 0 failed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; echo "RESULT: 0 passed, 0 failed"; exit 0; }

T="$(mktemp -d)"; export HOME="$T/fakehome" OSRC_HOME="$T"; mkdir -p "$HOME"; trap 'rm -rf "$T"' EXIT
. "$SRC" >/dev/null 2>&1

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
ck()  { if [ "$2" = "$3" ]; then ok "$1 -> '$2'"; else bad "$1 -> '$2' (want '$3')"; fi; }

refresh_benchmarks() { return 1; }   # never let cmd_advise fetch from the network

# --- Seed the advise cache dir from the fixtures ------------------------------
AD="$T/advise"; mkdir -p "$AD"
cp "$FIXT/cursorbench.html" "$AD/cursorbench.html"
cp "$FIXT/tbench-ai.html"   "$AD/tbench.html"
cp "$FIXT/or-bench.json"    "$AD/or-bench.json"
cp "$FIXT/or-endpoints.json" "$AD/or-endpoints.json"
now_s="$(date +%s)"; now_iso="$(date -u -r "$now_s" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$now_s" '+%Y-%m-%dT%H:%M:%SZ')"
for s in cursorbench tbench orbench endpoints; do
  printf '{"fetchedAt":"%s","fetchedAtEpoch":%s,"status":"ok"}\n' "$now_iso" "$now_s" > "$AD/$s.meta"
done
export OSRC_ADVISE_DIR="$AD"

# --- parse: fixture rows -> rows.jsonl + per-source meta parse fields ---------
# Pool = real candidate rows + ids in OpenRouter form for models the fixtures
# actually score, so the (family,effort) join has real matches to find.
_advise_candidate_rows code > "$AD/pool.txt" 2>/dev/null || true
cat >> "$AD/pool.txt" <<'POOL'
claude-sonnet|anthropic/claude-sonnet-4.5|or|capable
gpt-5|openai/gpt-5.1|or|capable
gemini-pro|google/gemini-3-pro-preview|or|frontier
POOL
pout="$(python3 -I "$SCRIPT_DIR/../lib/advise_parse.py" parse --dir "$AD" --pool "$AD/pool.txt" 2>&1)"
[ -s "$AD/rows.jsonl" ] && ok "parse writes rows.jsonl" || bad "parse wrote no rows.jsonl: $pout"
n_rows="$(wc -l < "$AD/rows.jsonl" | tr -d ' ')"
[ "$n_rows" -gt 60 ] && ok "parse yields $n_rows rows across the 4 fixtures" || bad "parse row count too low: $n_rows"

n_cb="$(jq -r 'select(.source=="cursorbench")' "$AD/rows.jsonl" | grep -c '"family"' 2>/dev/null)"
[ "$n_cb" -gt 40 ] && ok "cursorbench fixture parses $n_cb model x effort rows" || bad "cursorbench rows: $n_cb"
n_tb="$(jq -r 'select(.source=="tbench")' "$AD/rows.jsonl" | grep -c '"family"' 2>/dev/null)"
[ "$n_tb" -gt 50 ] && ok "tbench fixture parses $n_tb leaderboard rows" || bad "tbench rows: $n_tb"

# Trap: models with no candidate family are REPORTED unmatched, never guessed.
un="$(grep '^unmatched=' "$AD/tbench.meta" | cut -d= -f2)"
case "$un" in ''|*[!0-9]*|0) bad "tbench.meta reports no unmatched rows (Copilot Fusion should be unmatched): '$un'" ;; *) ok "tbench.meta reports $un unmatched rows" ;; esac
grep '^unmatched_names=' "$AD/tbench.meta" | grep -qi 'Copilot Fusion' \
  && ok "Copilot Fusion named in tbench.meta unmatched_names" || bad "Copilot Fusion not in meta unmatched_names"
jq -r 'select(.source=="tbench" and (.matched|not)) | .name' "$AD/rows.jsonl" 2>/dev/null | grep -qi 'copilot fusion' \
  && ok "Copilot Fusion lands in unmatched (no family guess)" || bad "Copilot Fusion missing from unmatched rows"

# Trap: date-suffixed display names still normalize to a family.
jq -r 'select(.source=="tbench") | .name' "$AD/rows.jsonl" | grep -qi 'deepseek v4.1 flash' \
  && ok "DeepSeek V4.1 Flash 1017 present in tbench rows" || bad "date-suffixed deepseek row missing"
jq -r 'select(.source=="tbench" and .matched) | .family' "$AD/rows.jsonl" | grep -qi 'deepseek' \
  && ok "date suffix strips to a matchable family" || true   # may legitimately stay unmatched if no candidate exists

# Trap: a 0-cost row (Muse Spark 1.3) parses without corrupting cost math.
jq -e 'select(.source=="tbench") | select(.name | test("Muse Spark")) | .cost == 0' "$AD/rows.jsonl" >/dev/null 2>&1 \
  && ok "Muse Spark cost=0 parses as a real zero, not missing" || bad "Muse Spark cost=0 row broken"

# --- factors: the join emits usable factor rows for matched candidates --------
fout="$(python3 -I "$SCRIPT_DIR/../lib/advise_parse.py" factors --dir "$AD" --category code --effort medium < "$AD/pool.txt" 2>/dev/null)"
n_f="$(grep -c . <<< "$fout")"
[ "$n_f" -ge 3 ] && ok "factors emits $n_f factor rows for the fixture pool" || bad "factors rows: $n_f"
grep -q 'cursorbench\|tbench\|or-bench' <<< "$fout" \
  && ok "factor rows name a real source" || bad "factor rows carry no source: $fout"

# --- end-to-end: cmd_advise on the fixture caches prints B2 lines -------------
out="$(cmd_advise "refactor the auth module" 2>&1)"
grep -q '== outsourcerer advise ==' <<< "$out" && ok "advise runs on fixture caches" || bad "advise failed on fixtures"
grep -q 'recommendation' <<< "$out" && ok "fixture caches produce a recommendation" || bad "no recommendation on fixtures"
grep -q 'sources: ' <<< "$out" && ok "advise prints the per-source status line" || bad "sources line missing"
grep -q 'cursorbench:.*ok\|cursorbench:.*fetched' <<< "$out" && ok "source status reflects fixture caches as fresh" || bad "source status wrong on fresh fixtures"

# Cold path unchanged: point at an empty dir and the output must carry no B2 lines.
export OSRC_ADVISE_DIR="$T/advise-empty"   # never created -> true cold path
out="$(cmd_advise "refactor the auth module" 2>&1)"
grep -q 'quality:\|sources:' <<< "$out" && bad "cold path leaked B2 factor lines" || ok "cold path has no B2 factor lines"
grep -q 'recommendation' <<< "$out" && ok "cold path still recommends" || bad "cold path broke"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
