# lib/advise.sh — MODEL ADVISORY helpers (task classification, benchmark lookup, scoring,
# candidate pool, lane marginal cost). Moved verbatim out of outsourcerer.sh (engine-size
# budget / B2 build). The command + live-source scoring live in lib/advise-score.sh; the
# fetch/refresh workers in lib/advise-fetch.sh; parsing in lib/advise_parse.py.
# This file may only shrink or stay (B-rules); new advise code goes in the advise-* modules.

# =============================================================================
# MODEL ADVISORY: task-aware model recommendation with benchmark data.
# Answers "which model should I use for this task?" with data, not guesses.
# Data source: OpenRouter benchmarks API (intelligence/coding/agentic indices + pricing).
# Graceful degradation: OR benchmarks -> cached models.json pricing -> tier proxy scores.
# =============================================================================

OSRC_BENCH_JSON="$OSRC_HOME/benchmarks.json"

# Native model -> OR benchmark permaslug prefix. Native subscription models (claude/codex/
# gemini lanes) need explicit mapping because their resolved ids don't appear in the OR catalog.
# Keyed by RESOLVED id (column 2 of OSRC_MODEL_TABLE), not the alias.
_NATIVE_BENCH_MAP="
fable|anthropic/claude-5-fable
opus|anthropic/claude-4.8-opus
sonnet|anthropic/claude-sonnet-5
haiku|anthropic/claude-4.5-haiku
gpt-5.6-sol|openai/gpt-5.6-sol
gpt-5.6-terra|openai/gpt-5.6-terra
gpt-5.6-luna|openai/gpt-5.6-luna
gpt-5.5|openai/gpt-5.5
glm-5.2|z-ai/glm-5.2
glm-5-3|z-ai/glm-5.3
glm-5-3-high|z-ai/glm-5.3
glm-5-3-flash|z-ai/glm-5.3-flash
glm-5-3-flash-high|z-ai/glm-5.3-flash
gemini-4-neon-high|google/gemini-4-neon
gemini-4-neon|google/gemini-4-neon
"
# Symbolic Gemini family aliases map to the NEWEST google/gemini-<ver>-<family> slug in the cached
# OpenRouter catalog, so a benchmark lookup for gemini-flash follows the release train instead of a
# row that goes stale. Empty when the catalog is not cached (the caller then has no score, as before).
_gemini_bench_slug() {
  local fam="$1"
  [ -f "$OSRC_MODELS_JSON" ] && have jq || return 1
  jq -r '.data[]?.id // empty' "$OSRC_MODELS_JSON" 2>/dev/null \
    | LC_ALL=C sed -n -E "s#^(google/gemini-[0-9]+(\.[0-9]+)?-${fam})(-preview)?\$#\1\3 \3#p" \
    | awk '{ split($1, f, "-"); split(f[2], v, "."); pre=($2=="" ? 0 : 1);
             printf "%d %d %d %s\n", v[1], (v[2]=="" ? 0 : v[2]), pre, $1 }' \
    | sort -k1,1nr -k2,2nr -k3,3n | awk 'NR==1{print $4}'
}

# Task classification keywords, pipe-separated phrases. Category with most hits wins; default: simple.
_TASK_KW_CODE='function|class method|bug|fix|refactor|implement|compile|error|stack trace|debug|unit test|api endpoint|sql query|regex|algorithm|data structure|code review|pull request|merge conflict|lint|type error|import|module|package|deploy|ci/cd|docker|kubernetes'
_TASK_KW_REASONING='analyze|compare|evaluate|assess|critique|reason|prove|derive|tradeoff|trade-off|implication|consequence|strategy|architect|design system|decision|justify|deduce|infer|formal|mathematical|proof|logical'
_TASK_KW_AGENTIC='agent|tool use|tool call|multi-step|autonomous|execute command|run shell|file system|web search|browser|orchestrat|workflow|pipeline|subagent|delegate|parallel|fanout|run the tests|run the test suite|run tests|make the tests pass|verify the fix|iterate until|edit and run|fix and verify|then verify'
_TASK_KW_CREATIVE='write a story|write a blog|write an article|essay|creative|generate content|copywriting|headline|tagline|brand voice|narrative|storytelling|poem|screenplay|dialogue'

# Good-enough thresholds per category (benchmark index minimum).
_THRESH_CODE=60
_THRESH_REASONING=45
_THRESH_AGENTIC=35
_THRESH_CREATIVE=45

# Score-band edges for deriving a capability tier from a LIVE benchmark score (_tier_from_score).
# Kept beside the _THRESH_* knobs so every score-scale constant lives in one place. Calibrated
# against the live intelligence_index distribution so the budget-price/frontier-capability models
# land in `capable`: gpt-5.6-sol (58.9) -> frontier, grok-4.5 (53.8) / glm-5.2 (51.1) /
# deepseek-v4-pro (44.3) -> capable, deepseek-flash (40.3) / glm-5.1 (40.2) -> mid, haiku (29.6)
# -> budget. The capable floor sits below deepseek-v4-pro (44.3) and above the flash/5.1 mid cluster
# (~40). A score below BUDGET or none at all -> raw (in the pool, ranks low, never silently promoted).
_TIER_BAND_FRONTIER=55
_TIER_BAND_CAPABLE=44
_TIER_BAND_MID=38
_TIER_BAND_BUDGET=28

# refresh_benchmarks: fetch benchmark data from OpenRouter API, cache locally.
# Needs OPENROUTER_API_KEY. Graceful failure: returns 1, caller falls back to tier proxy.
refresh_benchmarks() {
  _mkdir_private "$OSRC_HOME" || true
  have curl || { echo "curl needed to refresh benchmarks" >&2; return 1; }
  have jq || { echo "jq needed to refresh benchmarks" >&2; return 1; }
  # Extract key WITHOUT _or_load_key (which dies on missing key, killing the script).
  # ~/.env wins; an exported OPENROUTER_API_KEY is the fallback so `advise`'s auto-refresh
  # and a bare `export OPENROUTER_API_KEY=...` shell both work.
  local _k; _k="$(_extract_kv_value OPENROUTER_API_KEY)"; [ -n "$_k" ] || _k="${OPENROUTER_API_KEY:-}"
  [ -n "$_k" ] || { echo "OPENROUTER_API_KEY needed for benchmark data (put it in ~/.env)" >&2; return 1; }
  # Pass key via temp file to avoid exposure in process args (ps table).
  local _hdr; _hdr="$(mktemp "$OSRC_HOME/.hdr.$$.XXXXXX" 2>/dev/null)" || { echo "cannot create temp file" >&2; return 1; }
  printf 'Authorization: Bearer %s\n' "$_k" > "$_hdr"; chmod 600 "$_hdr"
  local _tmp; _tmp="$(mktemp "$OSRC_HOME/.bench.XXXXXX" 2>/dev/null)" || { rm -f "$_hdr"; echo "cannot create temp file" >&2; return 1; }
  if curl -fsS -m "${OSRC_CURL_TIMEOUT:-30}" -H @"$_hdr" \
    "https://openrouter.ai/api/v1/benchmarks?source=artificial-analysis&task_type=intelligence&max_results=100" \
    -o "$_tmp" 2>/dev/null; then
    # Validate JSON before promoting to cache (prevents HTML error pages / truncated responses from poisoning the cache).
    if jq -e '.data | type == "array"' "$_tmp" >/dev/null 2>&1; then
      mv -f "$_tmp" "$OSRC_BENCH_JSON" || { rm -f "$_tmp" "$_hdr"; echo "failed to write benchmark cache" >&2; return 1; }
      echo "refreshed benchmark cache ($(jq -r '.meta.model_count // "?"' "$OSRC_BENCH_JSON" 2>/dev/null) models, as of $(jq -r '.meta.as_of // "?"' "$OSRC_BENCH_JSON" 2>/dev/null))"
    else
      rm -f "$_tmp"
      echo "benchmark refresh failed (response was not valid JSON with .data array)" >&2; rm -f "$_hdr"; return 1
    fi
  else
    rm -f "$_tmp"
    echo "benchmark refresh failed (offline? no OR key?)" >&2; rm -f "$_hdr"; return 1
  fi
  rm -f "$_hdr"
}

# _classify_task <prompt> -> echoes category: code|reasoning|agentic|creative|simple
# Keyword-based, most hits wins. Ties: code > reasoning > agentic > creative > simple.
# Uses grep -oE with pipe-separated phrases to count distinct keyword matches.
_classify_task() {
  local prompt="$*" lc
  lc="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')"
  local code reasoning agentic creative
  code="$(printf '%s' "$lc" | grep -oE "$_TASK_KW_CODE" 2>/dev/null | wc -l | tr -d ' ')"
  reasoning="$(printf '%s' "$lc" | grep -oE "$_TASK_KW_REASONING" 2>/dev/null | wc -l | tr -d ' ')"
  agentic="$(printf '%s' "$lc" | grep -oE "$_TASK_KW_AGENTIC" 2>/dev/null | wc -l | tr -d ' ')"
  creative="$(printf '%s' "$lc" | grep -oE "$_TASK_KW_CREATIVE" 2>/dev/null | wc -l | tr -d ' ')"
  code="${code:-0}"; reasoning="${reasoning:-0}"; agentic="${agentic:-0}"; creative="${creative:-0}"
  # TASK-SHAPE FIT (blended rule): a prompt that carries BOTH code hits and at least two agentic hits
  # ("edit X to fix the bug, run the test suite, verify") describes multi-step tool use — edit, run,
  # observe, iterate — not one code operation. Under most-hits-wins it tied on code (fix/bug vs
  # pipeline/run-the-tests) and code won the tie, so advise scored it on coding_index and let a
  # reasoning-heavy model float to #1 for a job that is all about turning tools quickly. Agentic first.
  if [ "$code" -ge 1 ] && [ "$agentic" -ge 2 ]; then printf 'agentic'; return; fi
  # edit-verb + code-noun = code: "add a retry to the upload client" hits no
  # keyword yet is plainly a code change. Multi-step tool tasks still go
  # agentic above; bare questions never reach this line (no edit verb).
  if printf '%s' "$lc" | grep -qE '\b(add|fix|refactor|implement|change|update|remove|create|write|build|patch|modify|extend|rename|move|revert|optimi[sz]e|improve)\b' \
    && printf '%s' "$lc" | grep -qE '\b(client|server|api|endpoint|handler|function|method|class|module|package|file|code|component|service|worker|queue|request|response|parser|serializer|middleware|route|controller|schema|migration|query|spec|config|pipeline|retry|timeout|upload|download|cache|auth|session|token|validation|logging)\b'; then
    printf 'code'; return
  fi
  local best=simple best_n=0
  [ "$code" -gt "$best_n" ] && { best=code; best_n=$code; }
  [ "$reasoning" -gt "$best_n" ] && { best=reasoning; best_n=$reasoning; }
  [ "$agentic" -gt "$best_n" ] && { best=agentic; best_n=$agentic; }
  [ "$creative" -gt "$best_n" ] && { best=creative; best_n=$creative; }
  printf '%s' "$best"
}

# _bench_score_field <category> -> benchmark JSON field name for that category.
_bench_score_field() {
  case "$1" in
    code)      printf 'coding_index' ;;
    agentic)   printf 'agentic_index' ;;
    reasoning|creative|simple|*) printf 'intelligence_index' ;;
  esac
}

# _bench_threshold_for <category> -> numeric threshold (0 for simple = no floor).
_bench_threshold_for() {
  case "$1" in
    code)      printf '%s' "$_THRESH_CODE" ;;
    reasoning) printf '%s' "$_THRESH_REASONING" ;;
    agentic)   printf '%s' "$_THRESH_AGENTIC" ;;
    creative)  printf '%s' "$_THRESH_CREATIVE" ;;
    *)         printf '0' ;;
  esac
}

# _resolve_bench_slug <alias-or-resolved-id> -> OR benchmark permaslug prefix, or empty.
# Checks native map first, then strips :free and uses the id directly.
_resolve_bench_slug() {
  local mapped
  case "$1" in
    gemini-flash-lite) mapped="$(_gemini_bench_slug flash-lite)" ;;
    gemini-flash)      mapped="$(_gemini_bench_slug flash)" ;;
    gemini-pro)        mapped="$(_gemini_bench_slug pro)" ;;
    gemini-*-neon*|gemini-*-argon*|gemini-*-hydrogen*|gemini-*-carbon*)
                     mapped="$(_agy_or_bench_slug "$1")" ;;
    *) mapped="$(printf '%s\n' "$_NATIVE_BENCH_MAP" | awk -F'|' -v a="$1" '$1==a{print $2; exit}')" ;;
  esac
  [ -n "$mapped" ] && { printf '%s' "$mapped"; return 0; }
  printf '%s' "${1%:free}"
}

# _bench_lookup <resolved-id> <field> -> "score\tprice_in\tprice_out" or empty.
# Queries the cached benchmark JSON. Prefers exact match, falls back to shortest prefix match.
_bench_lookup() {
  [ -f "$OSRC_BENCH_JSON" ] && have jq || return 0
  local slug; slug="$(_resolve_bench_slug "$1")"
  [ -n "$slug" ] || return 0
  # Try exact match first, then prefix match sorted by slug length (shortest = most canonical).
  local result
  result="$(jq -r --arg slug "$slug" --arg field "$2" '
    .data[] | select(.model_permaslug == $slug)
    | "\(.[$field] // 0)\t\(.pricing.prompt // "0")\t\(.pricing.completion // "0")"
  ' "$OSRC_BENCH_JSON" 2>/dev/null | head -1)"
  if [ -z "$result" ]; then
    # Prefix match: collect into array, sort by slug length, take shortest. Empty array -> no output.
    result="$(jq -r --arg slug "$slug" --arg field "$2" '
      [.data[] | select(.model_permaslug | startswith($slug))]
      | if length > 0 then sort_by(.model_permaslug | length) | .[0]
        | "\(.[$field] // 0)\t\(.pricing.prompt // "0")\t\(.pricing.completion // "0")"
        else empty end
    ' "$OSRC_BENCH_JSON" 2>/dev/null | head -1)"
  fi
  printf '%s' "$result"
}

# _tier_score_proxy <tier> -> rough capability score when no benchmark data exists.
_tier_score_proxy() {
  case "$1" in
    frontier) printf '55' ;;
    capable)  printf '50' ;;
    mid)      printf '40' ;;
    budget)   printf '30' ;;
    *)        printf '35' ;;
  esac
}

# _tier_from_score <score> -> capability tier derived from a LIVE benchmark score, the inverse of
# _tier_score_proxy. Used for dynamic pool candidates that have no hand-set tier in OSRC_MODEL_TABLE:
# a never-before-seen model gets ranked by the same capability bands as the curated ones, so a new
# strong model is recommendable on merit the day it appears. Empty/non-numeric -> raw (present in
# the pool, ranks low, never silently promoted). awk does the numeric compare so a non-numeric
# string can't crash under `set -u` or leak a shell error.
_tier_from_score() {
  local s="${1:-}"
  case "$s" in ''|*[!0-9.-]*) printf 'raw'; return 0 ;; esac
  awk -v s="$s" -v f="$_TIER_BAND_FRONTIER" -v c="$_TIER_BAND_CAPABLE" \
          -v m="$_TIER_BAND_MID" -v b="$_TIER_BAND_BUDGET" '
    BEGIN {
      if (s+0 >= f+0)      print "frontier"
      else if (s+0 >= c+0) print "capable"
      else if (s+0 >= m+0) print "mid"
      else if (s+0 >= b+0) print "budget"
      else                 print "raw"
    }'
}

# _model_canon_key <id-or-permaslug> -> canonical model identity key. The same model is
# referenced under different id forms across OpenRouter (vendor-prefixed, dotted versions,
# release-date suffixes) and Devin (hyphenated versions, effort suffixes). Collapsing those
# surface differences to one bare family+version token lets a model match itself across
# providers and across id forms, so dedup and routing treat one model as one model. Only
# cosmetic shape is folded: a leading vendor prefix segment, a trailing release date, a
# trailing effort suffix, and the . vs - separator inside a version token. Variant and
# family segments are preserved, so gpt-5.6-sol and gpt-5 stay distinct keys.
_model_canon_key() {
  local k="${1:-}"
  k="$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')"
  # Strip ANY leading vendor prefix (everything up to the first "/"), not a fixed vendor list, so a
  # brand-new provider's OpenRouter id (vendor/model) still collapses onto the bare Devin/Warp uid.
  k="${k#*/}"
  k="$(printf '%s' "$k" | sed -E 's/-[0-9]{6,}$//')"
  while :; do
    case "$k" in
      *-high|*-low|*-max|*-medium) k="${k%-*}" ;;
      *) break ;;
    esac
  done
  k="$(printf '%s' "$k" | tr '.' '-')"
  printf '%s' "$k"
}

# _task_difficulty <prompt> -> normal|hard. Several independent work signals indicate that selection
# should favor a near-frontier capable model instead of treating the request as a single operation.
_task_difficulty() {
  local prompt="$*" lc hits
  lc="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')"
  hits="$(printf '%s' "$lc" | grep -oE "$_TASK_KW_CODE|$_TASK_KW_REASONING|$_TASK_KW_AGENTIC" 2>/dev/null | wc -l | tr -d ' ')"
  hits="${hits:-0}"
  if [ "$hits" -ge 4 ] || [ "${#prompt}" -ge 240 ]; then printf 'hard'; else printf 'normal'; fi
}

# _frontier_needed <task> <effort> -> true when the request explicitly calls for the frontier.
_frontier_needed() {
  local task="$1" effort="$2" lc
  [ "$effort" = "max" ] && return 0
  lc="$(printf '%s' "$task" | tr '[:upper:]' '[:lower:]')"
  # Here-string, not `printf | grep -q`: the task text is unbounded, and once it outgrows the pipe
  # buffer grep's early exit SIGPIPEs printf, which pipefail reports as a miss on a present cue.
  grep -qE 'frontier[- ]required|safety[- ]critical|mission[- ]critical|formal proof' <<<"$lc"
}

# _score <base> <tier> <category> <effort> <difficulty> <model> -> selection score.
# Capable models get a value preference, Kimi K3 gets a hard-work near-frontier adjustment, and an
# explicit frontier requirement outweighs both. Benchmark and history remain the base evidence.
# The Kimi adjustment is REASONING-SHAPED ONLY: it used to fire on every hard non-creative task, which
# floated kimi to #1 (score 80) for an edit-run-verify job — where its long pure-reasoning bursts are
# exactly the wrong shape (the 2026-09-15 incident: two ~17-min zero-write burns). Kimi's edge is deep
# analysis; a hard reasoning task still lets it win, a hard code/agentic task does not.
_score() {
  local base="$1" tier="$2" category="$3" effort="$4" difficulty="$5" model="$6"
  awk -v s="$base" -v t="$tier" -v c="$category" -v e="$effort" -v d="$difficulty" -v m="$model" '
    BEGIN {
      if (t == "capable") s += 8
      if (t == "capable" && (e == "high" || e == "xhigh")) s += 2
      if (m == "kimi-k3" && d == "hard" && c == "reasoning") s += 20
      if (e == "max" && t == "frontier") s += 30
      printf "%.4f", s
    }'
}

# ---- VARIANT PREFERENCE (cheaper capable variant within a family) ---------------------------------
# Devin ships families as effort/size variants (glm-5-3-high, glm-5-3-flash-high, deepseek-v4-pro-max).
# When two variants of ONE family both clear the task threshold, the lighter one is the better
# recommendation unless the caller asked for max effort or the task requires the frontier: same
# capability class, less quota draw. On plan lanes cost is a flat "plan limits", so value-ratio cannot
# separate them; this weight is the tiebreaker that makes flash-high beat high. Never a price (prices
# rot); a shape rule. OSRC_ADVISE_VARIANT_PREF=0 disables.
# _variant_family <resolved-id> -> family key: provider prefix dropped, '.'->'-', size/effort suffixes
# stripped repeatedly (glm-5-3-flash-high -> glm-5-3; glm-5.2 -> glm-5-2; deepseek-v4-pro-max -> deepseek-v4-pro).
_variant_family() {
  local id prev=""; id="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr '.' '-')"; id="${id##*/}"
  while [ "$id" != "$prev" ]; do
    prev="$id"
    id="$(printf '%s' "$id" | sed -E 's/-(none|minimal|low|medium|high|xhigh|max|1m|flash|lightning|mini|lite|turbo)$//')"
  done
  printf '%s' "$id"
}
# _variant_weight <resolved-id> <effort> -> smaller = preferred. Two parts: a LIGHT family member
# (flash/lightning/mini/lite) scores 0, a full-size one 10, so light always beats full-size; plus the
# distance between the variant's effort rung and the REQUESTED effort (none/low=0, medium=1, high=2,
# xhigh/max=3; an un-rung family id counts as distance 1), so at --effort high the -high rung of the
# light member wins over its bare id and over every full-size rung.
_variant_weight() {
  local id w=10 rung=-1 target=2 d; id="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr '.' '-')"; id="${id##*/}"
  case "$id" in *-flash|*-flash-*|*-lightning|*-lightning-*|*-mini|*-mini-*|*-lite|*-lite-*) w=0 ;; esac
  id="${id%-1m}"
  case "$id" in *-none|*-minimal|*-low) rung=0 ;; *-medium) rung=1 ;; *-high) rung=2 ;; *-xhigh|*-max) rung=3 ;; esac
  case "${2:-}" in minimal|low|none) target=0 ;; medium) target=1 ;; high) target=2 ;; xhigh|max) target=3 ;; esac
  if [ "$rung" -lt 0 ]; then d=1; else d=$(( rung - target )); [ "$d" -lt 0 ] && d=$(( -d )); fi
  printf '%s' $(( w + d ))
}

# _advise_candidate_rows [field] -> emit `alias|resolved|lane|tier` rows for the advise ranking
# loop, replacing the old static-only `printf '%s\n' "$OSRC_MODEL_TABLE"` source. The pool is the
# UNION of:
#   1. OSRC_MODEL_TABLE verbatim   -- curated: lane+tier authoritative, and the offline fallback.
#   2. live OpenRouter ids         -- from the cached models.json (.data[].id), SCORED-ONLY.
# Static rows WIN on dedup: a resolved id present in OSRC_MODEL_TABLE is emitted from the static
# row only, so curated lane routing (e.g. deepseek -> or vs dv) and hand-set tiers are preserved.
# A dynamic id absent from the static table gets a tier DERIVED from its live benchmark score via
# _tier_from_score, so a never-before-seen strong model is recommendable on merit the day it shows
# up in the catalog, with zero manual table edits.
#
# Only OpenRouter ids are enumerated, and only those that CARRY a benchmark score. The Devin catalog
# is deliberately NOT enumerated: its uids (glm-5-2, deepseek-v4-pro-high) do not match the
# OpenRouter-keyed benchmark data, so every one would score empty and rank as raw -- pure noise and
# a needless jq storm. Merit-based discovery only works where a score exists (OpenRouter); the
# curated Devin models are already routed through OSRC_MODEL_TABLE. An id with no score has no merit
# signal to be "recommended on merit" and is skipped.
#
# Cache-only and fail-open: reads the already-cached benchmarks.json + models.json DIRECTLY (never a
# refresh/fetch -- that would block advise on the network). Missing/empty caches -> zero dynamic
# rows and the static pool carries, byte-for-byte the offline behavior. Escape hatch
# OSRC_ADVISE_DYNAMIC_POOL=0 forces the static-only pool. OSRC_ADVISE_DYNAMIC_MAX (default 25) caps
# how many of the strongest-scoring discovered ids are added, bounding both the pool and the
# downstream ranking cost. The optional <field> is the score field for the task category.
_advise_candidate_rows() {
  local field="${1:-intelligence_index}"
  local _nl=$'\n' _tab; _tab="$(printf '\t')"
  local seen="$_nl" alias resolved lane tier id sc bench_map or_ids scored
  local max="${OSRC_ADVISE_DYNAMIC_MAX:-25}" added=0
  case "$max" in ''|*[!0-9]*) max=25 ;; esac   # empty/non-numeric/negative -> safe default; 0 means none
  # Static rows first. Iterate via process substitution (not a pipe) so `seen` accumulates in this
  # shell and the dynamic pass can dedup against it without associative arrays (bash-3.2 safe).
  while IFS='|' read -r alias resolved lane tier; do
    [ -n "$alias" ] || continue
    printf '%s|%s|%s|%s\n' "$alias" "$resolved" "$lane" "$tier"
    seen="$seen$resolved$_nl"
  done < <(printf '%s\n' "$OSRC_MODEL_TABLE")
  [ "${OSRC_ADVISE_DYNAMIC_POOL:-1}" = "0" ] && return 0
  { [ -f "$OSRC_BENCH_JSON" ] && [ -f "$OSRC_MODELS_JSON" ] && have jq; } || return 0
  # ONE jq pass builds a "permaslug<TAB>score" map; a SINGLE awk then joins EVERY OpenRouter id
  # against it in-process. A per-id awk/subprocess lookup would reintroduce an O(N) latency cliff as
  # the catalog grows -- the whole join runs in one awk instead. The match is boundary-aware: an id
  # matches a permaslug only on an exact hit or at a '-' segment boundary, so a short id like
  # openai/gpt-5 cannot steal a longer model's score (openai/gpt-5.6-...); ties break to the shortest
  # (canonical) permaslug, mirroring _bench_lookup. Ids are charset-filtered (a third-party catalog id
  # with a '|' or a shell metachar can't corrupt the alias|resolved|lane|tier row or reach any eval).
  # The ranking loop recomputes the authoritative score, so this only gates scored-vs-not, the tier
  # band, and the top-N selection.
  bench_map="$(jq -r --arg f "$field" '.data[]? | select(.[$f] != null) | "\(.model_permaslug)\t\(.[$f])"' "$OSRC_BENCH_JSON" 2>/dev/null)"
  [ -n "$bench_map" ] || return 0
  or_ids="$(jq -r '.data[]?.id // empty' "$OSRC_MODELS_JSON" 2>/dev/null)"
  scored="$(awk -F"$_tab" '
    # canon(): drop a trailing -<digits> release-date segment so a dated permaslug reduces to the
    # bare model id (z-ai/glm-5.2-20260616 -> z-ai/glm-5.2). Matching is then an O(1) hash lookup,
    # exact then canonical -- O(N+M) overall, and a short id can only match its OWN canonical id,
    # never borrow a longer siblings score.
    function canon(p,   c) { c=p; sub(/-[0-9]+$/, "", c); return c }
    NR==FNR {
      if (!($1 in exact)) exact[$1]=$2
      c=canon($1); if (!(c in cano)) cano[c]=$2
      next
    }
    {
      id=$1
      if (id !~ "^[A-Za-z0-9._/-]+$") next
      s=id; sub(/:free$/, "", s)
      if (s in exact)     print id "\t" exact[s]
      else if (s in cano) print id "\t" cano[s]
    }
  ' <(printf '%s\n' "$bench_map") <(printf '%s\n' "$or_ids") | sort -t"$_tab" -k2 -rn)"
  while IFS="$_tab" read -r id sc; do
    [ "$added" -ge "$max" ] && break
    [ -n "$id" ] || continue
    case "$seen" in *"$_nl$id$_nl"*) continue ;; esac
    printf '%s|%s|or|%s\n' "$id" "$id" "$(_tier_from_score "$sc")"
    seen="$seen$id$_nl"
    added=$((added + 1))
  done <<EOF
$scored
EOF
  return 0
}

# _model_lanes <canon-key> -> echo the space-separated set of lane codes whose CACHED catalog
# contains a model whose _model_canon_key equals <canon-key>. Cache-only: it reads the three
# already-on-disk artifacts and NEVER triggers a fetch, so a routing decision can ask "which
# lanes can run this model" without a network round-trip or a CLI probe. A missing/unreadable
# source is skipped cleanly (no error, no partial lane). Each lane is emitted at most once.
#
# Each source is ONE jq pass to pull ids + ONE awk pass to canon-collapse and match, mirroring
# _model_canon_key inside awk (lowercase, drop the known vendor prefix segment, strip a trailing
# -<6+digit> release date, strip -high/-low/-max/-medium effort suffixes, then '.'->'-'). A
# per-id _model_canon_key subprocess loop would reintroduce an O(catalog) latency cliff as the
# catalog grows; the in-awk canon keeps each source a single subprocess and exits on first hit.
_model_lanes() {
  local key="${1:-}" f ids hit out=""
  [ -n "$key" ] || { printf '\n'; return 0; }
  have jq || { printf '\n'; return 0; }
  # or: OpenRouter cached models.json (.data[].id). First match prints a marker and exits.
  f="$OSRC_MODELS_JSON"
  if [ -f "$f" ]; then
    ids="$(jq -r '.data[]?.id // empty' "$f" 2>/dev/null)"
    if [ -n "$ids" ]; then
      hit="$(printf '%s\n' "$ids" | awk -v k="$key" '
        function canon(s,   c) {
          c = tolower(s)
          sub(/^[^\/]*\//, "", c)
          sub(/-[0-9]{6,}$/, "", c)
          while (sub(/-(high|low|max|medium)$/, "", c)) {}
          gsub(/\./, "-", c)
          return c
        }
        { if (canon($0) == k) { print "1"; exit } }
      ' 2>/dev/null)"
      [ -n "$hit" ] && out="$out or"
    fi
  fi
  # dv: the STRUCTURED catalog (dv.raw.json), not the flat dv.json. variants[].model_uid is the
  # launchable id form; family_uid/aliases collapse to the same canon key in practice and would
  # only add duplicate hits, so variants alone are the faithful, dedup-clean source. The
  # ${f%.json}.raw.json derivation mirrors _devin_catalog_raw so the path stays in lockstep.
  f="$(_catalog_path dv 2>/dev/null)" || f=""
  if [ -n "$f" ]; then
    f="${f%.json}.raw.json"
    if [ -f "$f" ]; then
      ids="$(jq -r '.families[]?.variants[]?.model_uid // empty' "$f" 2>/dev/null)"
      if [ -n "$ids" ]; then
        hit="$(printf '%s\n' "$ids" | awk -v k="$key" '
          function canon(s,   c) {
            c = tolower(s)
            sub(/^[^\/]*\//, "", c)
            sub(/-[0-9]{6,}$/, "", c)
            while (sub(/-(high|low|max|medium)$/, "", c)) {}
            gsub(/\./, "-", c)
            return c
          }
          { if (canon($0) == k) { print "1"; exit } }
        ' 2>/dev/null)"
        [ -n "$hit" ] && out="$out dv"
      fi
    fi
  fi
  # warp: flat JSON array of id strings (one id per element). Same single-awk canon pass.
  f="$(_catalog_path warp 2>/dev/null)" || f=""
  if [ -n "$f" ] && [ -f "$f" ]; then
    ids="$(jq -r '.[] // empty' "$f" 2>/dev/null)"
    if [ -n "$ids" ]; then
      hit="$(printf '%s\n' "$ids" | awk -v k="$key" '
        function canon(s,   c) {
          c = tolower(s)
          sub(/^[^\/]*\//, "", c)
          sub(/-[0-9]{6,}$/, "", c)
          while (sub(/-(high|low|max|medium)$/, "", c)) {}
          gsub(/\./, "-", c)
          return c
        }
        { if (canon($0) == k) { print "1"; exit } }
      ' 2>/dev/null)"
      [ -n "$hit" ] && out="$out warp"
    fi
  fi
  out="${out# }"
  printf '%s\n' "$out"
}

# _lane_marginal_cost <lane> <resolved-id> [est_tokens] -> echo two space-separated fields:
# a numeric comparable cost and a basis label. Pure-read: consults only cached prices and the
# existing conserve read, never a fetch. The cost is what a value-ranking caller compares to
# pick the cheapest lane that can run a model; the basis label says HOW the number was derived
# so a caller never mistakes an estimate for a metered price or a sentinel for a real zero.
#
#   or                -> est_tokens * cached OpenRouter per-token prompt price; basis "est".
#                       No price on file -> "0 unknown" (an unpriced id must not win on cost it
#                       cannot prove). est_tokens defaults to 1000.
#   cc/cx/dv/gm/warp/  -> "0 plan" (subscription/keyless: cost is quota-limited, not per-token,
#   gemini              so the comparable cost is zero for value ranking) UNLESS the lane is past
#                       its conserve line, in which case "999 overage" forces value routing OFF a
#                       nearly-exhausted sub. Reuses _lane_conserve_mult: a multiplier <1 means a
#                       measurable lane is past the conserve line; unmeasurable lanes return 1.00
#                       and stay "0 plan" (we never invent a limit we cannot read).
#   local             -> "0 free" (local inference: no per-token cost, no sub quota to exhaust).
#   droid/cline/cursor -> "-1 unknown" sentinel: pass-through BYOK bills the caller's own key, so
#                       this lane has no comparable cost HERE. Callers MUST treat -1 as "not
#                       comparable / never wins on value", never as the cheapest lane.
_lane_marginal_cost() {
  local lane="${1:-}" id="${2:-}" est price cost mult
  # Descriptor-first: marginal_class selects the cost shape (plan/metered/free; absent ->
  # the -1 unknown sentinel). The residual case covers unported lanes AND the `gemini`
  # token quirk: `gemini` resolves to the gi lane (metered), but the old arm priced that
  # token as plan — gi cannot carry marginal_class=plan without mis-pricing its own
  # canonical code, so the token is kept here.
  local _ml _cls=""
  _ml="$(_lane_by_token "$lane" 2>/dev/null)" && _cls="$(_lane_field "$_ml" marginal_class 2>/dev/null)"
  if [ -z "$_cls" ]; then
    case "$lane" in
      dv|gemini)   _cls=plan ;;      # unported dv + the gemini token quirk above
      *)           _cls=unknown ;;
    esac
  fi
  case "$_cls" in
    metered)
      est="${3:-1000}"
      case "$est" in ''|*[!0-9.]*) est="1000" ;; esac
      if [ -f "$OSRC_MODELS_JSON" ] && have jq; then
        price="$(jq -r --arg id "$id" '.data[]|select(.id==$id)|.pricing.prompt // empty' "$OSRC_MODELS_JSON" 2>/dev/null | head -1)"
      fi
      case "$price" in ''|*[!0-9.-]*) printf '0 unknown\n'; return ;; esac
      cost="$(awk -v e="$est" -v p="$price" 'BEGIN{printf "%g", e*p}')"
      printf '%s est\n' "$cost"
      ;;
    plan)
      mult="$(_lane_conserve_mult "$lane" "$(_session_limits 2>/dev/null)" 2>/dev/null)"
      case "$mult" in ''|*[!0-9.-]*) mult="1.00" ;; esac
      if awk -v m="$mult" 'BEGIN{exit !(m+0 < 1.0)}'; then
        printf '999 overage\n'
      else
        printf '0 plan\n'
      fi
      ;;
    free)
      printf '0 free\n'
      ;;
    *)
      # Unknown lane: no basis to compare. Same unknown sentinel, never a zero that would win.
      printf -- '-1 unknown\n'
      ;;
  esac
}
