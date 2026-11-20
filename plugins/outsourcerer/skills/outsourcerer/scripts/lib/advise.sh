cmd_advise() {
  # advise takes its task from argv only. A helper that reads stdin would wait forever on an open
  # terminal (tests pass because their stdin is closed), so the whole command runs with stdin closed.
  if [ -z "${_OSRC_ADVISE_NOSTDIN:-}" ]; then _OSRC_ADVISE_NOSTDIN=1 cmd_advise "$@" </dev/null; return; fi
  local do_refresh=0 json_out=0 task="" selection_effort="${OUTSOURCERER_EFFORT:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --refresh) do_refresh=1; shift ;;
      --json)    json_out=1; shift ;;
      --effort|--reasoning)
                 [ -n "${2:-}" ] || die "advise: --effort needs minimal|low|medium|high|xhigh|max|none"
                 case "$2" in minimal|low|medium|high|xhigh|max|none) selection_effort="$2" ;;
                   *) die "advise: invalid effort '$2' (use minimal|low|medium|high|xhigh|max|none)" ;; esac
                 shift 2 ;;
      --)        shift; task="${*:-}"; break ;;
      --*)       task="${task:+$task }$1"; shift ;;   # unknown --flags treated as task text
      *)         task="${task:+$task }$1"; shift ;;
    esac
  done
  [ -n "$task" ] || die "advise needs a task description (try: $0 advise \"refactor auth module\")"
  # JSON output requires jq; fail explicitly rather than emitting empty output.
  if [ "$json_out" -eq 1 ] && ! have jq; then
    die "advise --json requires jq (install it or run without --json for text output)"
  fi

  local category field difficulty
  category="$(_classify_task "$task")"
  field="$(_bench_score_field "$category")"

  # The quality bar is a share of the best score among models runnable now (owner's choice,
  # 2026-11-19): light 75%, normal 85%, hard 97%. Override with OSRC_ADVISE_BAR_{LIGHT,NORMAL,HARD}.
  local stale percentile="${OSRC_ADVISE_BAR_NORMAL:-85}"
  stale="$(_bench_cache_stale)"
  if [ "$do_refresh" = 1 ]; then
    refresh_benchmarks intelligence >&2 || return 1
  elif { [ -n "${OPENROUTER_API_KEY:-}" ] || [ -n "$(_extract_kv_value OPENROUTER_API_KEY)" ]; } &&
       { [ -n "$stale" ] || ! jq -e --arg f "$field" 'any(.data[]?;
         (.[$f]|type)=="number" or ($f!="intelligence_index" and (.engineering_index|type)=="number"))' "$OSRC_BENCH_JSON" >/dev/null 2>&1; }; then
    refresh_benchmarks intelligence >/dev/null 2>&1 || :
  fi
  stale="$(_bench_cache_stale)"
  difficulty="$(_task_difficulty "$task")"
  if _frontier_needed "$task" "$selection_effort" || [ "$difficulty" = hard ]; then
    percentile="${OSRC_ADVISE_BAR_HARD:-97}"; difficulty=hard
  elif [ "$category" = simple ] || [[ "$selection_effort" =~ ^(minimal|low|none)$ ]]; then
    percentile="${OSRC_ADVISE_BAR_LIGHT:-75}"; difficulty=light
  fi
  if [ -z "$selection_effort" ]; then
    case "$difficulty" in hard) selection_effort=high ;; light) selection_effort=low ;; *) selection_effort=medium ;; esac
  fi

  local candidate_rows lanes lane limits="" skipped="" limit_notes="" plans=" dv " names hits="" name reading
  local -a check_names
  candidate_rows="$(_advise_catalog)"
  lanes="$(awk -F'|' 'NF==4 && !seen[$3]++ {print $3}' <<<"$candidate_rows")"
  [ "${OSRC_LANE_LIMIT_GATE:-1}" = 0 ] || limits="$(_session_limits 2>/dev/null)"
  for lane in $lanes; do
    [ "$(_lane_field "$lane" plan_limited)" != yes ] || plans="$plans$lane "
    if [ "$(_lane_field "$lane" image_lane)" = yes ] || _model_excluded "$lane"; then
      skipped="$skipped $lane"
    elif [ -n "$limits" ] && _osrc_limit_exceeded "$lane" "$limits"; then
      skipped="$skipped $lane"
      reading="$(_osrc_lane_limit "$lane" "$limits" 2>/dev/null)"
      limit_notes="${limit_notes:+$limit_notes; }${reading:-$lane} >= $(_osrc_limit_threshold)% -> $lane excluded"
    fi
  done
  if _exclude_active; then
    names="$(awk -F'|' '{for(i=1;i<=2;i++) if(!seen[$i]++) print $i}' <<<"$candidate_rows")"
    check_names=()
    while IFS= read -r name; do check_names+=("$name"); done <<<"$names"
    hits="$(_exclude_hits "${check_names[@]}")"
  fi
  local report
  report="$(_advise_value "$OSRC_BENCH_JSON" "$OSRC_MODELS_JSON" \
    "$category" "$field" "$percentile" "$difficulty" "$skipped" "${OSRC_MODEL_DENYLIST:-}" \
    "${OSRC_ADVISE_ROUTER:-1}" "$plans" "${OSRC_ADVISE_DYNAMIC_MAX:-}" /dev/fd/3 3<<<"$hits" 4<<<"$candidate_rows")" || return 1

  local winner model basis="" history=""
  winner="$(jq -r '.recommendation.lane // empty' <<<"$report")"
  model="$(jq -r '.recommendation.model // empty' <<<"$report")"
  if [ -n "$winner" ]; then
    basis="$(_lane_marginal_cost "$winner" "$model")"; basis="${basis##* }"
    history="$(_history_mult "$winner" "$model" "$category")"
  fi
  if [ "$json_out" = 1 ]; then
    jq --arg task "$task" --arg effort "$selection_effort" --arg basis "$basis" --arg stale "$stale" \
      --arg limits "$limit_notes" \
      --arg history "$history" '.task=$task | .effort=$effort | .benchmark_stale=($stale!="")
      | if $limits != "" then .limit_gate_reasons=$limits else . end
      | if .recommendation then .recommendation.cost_basis=$basis else . end
      | ($history|split("|")) as $h | .history={multiplier:($h[0]|tonumber? // 1),
        effective_samples:($h[1]|tonumber? // 0),passed_effective:($h[2]|tonumber? // 0),scope:$h[3]}' <<<"$report"
  else
    echo "== outsourcerer advise =="
    echo "   task: $task"
    echo "   category: $category"
    echo "   difficulty: $difficulty"
    echo "   effort: $selection_effort"
    jq -r --arg limits "$limit_notes" '"   scoring by: \(.score_field) (threshold: \(.threshold))",
      "   benchmark coverage: \(.benchmark_coverage)",
      (select($limits != "") | "   limit-gate: \($limits) (lanes at/over OSRC_LANE_LIMIT_PCT excluded; disable with OSRC_LANE_LIMIT_GATE=0)"),
      (select(.limit_gate) | "   skipped: \(.limit_gate)"),
      (if .recommendation then "   model: \(.recommendation.alias) (\(.recommendation.model))",
       "   lane:  \(.recommendation.lane)", "   why:   \(.recommendation.reason)"
       else "   no recommendation: no priced candidate clears the measured bar" end),
      (.candidates[] | "   \(.model) lane=\(.lane) score=\(.score // "unscored") $/M=\(.price // "unknown") value=\(.value_ratio // "unknown") \(.missing|join(", "))")' <<<"$report"
    [ -z "$stale" ] || echo "   benchmark cache is stale; run advise --refresh"
    if [ -n "$winner" ]; then
      local provider
      provider="$(_fallback_provider_for_lane "$winner")"
      printf 'Run with: %q ' "$0"
      [ -z "$provider" ] || printf '%s %q ' --provider "$provider"
      printf 'run -m %q --effort %q %q\n' "$model" "$selection_effort" "$task"
    fi
  fi
}

_advise_catalog() {
  if [ -r "$OSRC_HOME/models.local" ]; then
    LC_ALL=C awk '{sub(/#.*/,""); gsub(/[ \t\r]/,"")} /^[A-Za-z0-9._:\/@+-]+\|[]A-Za-z0-9._:\/@+[-]+\|[a-z]+\|[a-z]+$/ {print}' "$OSRC_HOME/models.local"
  fi
  [ "${OSRC_ADVISE_DYNAMIC_POOL:-1}" != 0 ] || return 0
  local path lane
  for path in "$OSRC_HOME"/catalogs/*.json; do
    [ -r "$path" ] || continue
    lane="${path##*/}"; lane="${lane%.json}"
    case "$lane" in *.raw) continue ;; esac
    jq -r --arg lane "$lane" '.[]|strings|[.,.,$lane,"raw"]|join("|")' "$path"
  done
  path="${CODEX_HOME:-$HOME/.codex}/models_cache.json"
  [ ! -r "$path" ] || jq -r '.models[]?|select(.visibility!="hide")|.slug|[.,.,"cx","raw"]|join("|")' "$path"
  path="$(_agy_models_cache)"
  [ ! -r "$path" ] || awk 'NF {print $0 "|" $0 "|gm|raw"}' "$path"
  path="$OSRC_HOME/catalogs/dv.raw.json"
  [ ! -r "$path" ] || jq -r '.families[]?.variants[]?.model_uid|[.,.,"dv","raw"]|join("|")' "$path"
  [ ! -r "$OSRC_MODELS_JSON" ] || jq -r '.data[]?.id|[.,.,"or","raw"]|join("|")' "$OSRC_MODELS_JSON"
}

_advise_value() {
  python3 - "$@" <<'PYTHON'
"""Join CLI catalog IDs to OpenRouter releases and rank eligible model/lane pairs."""
import fnmatch
import json
import math
import re
import sys
from collections import defaultdict

bench, models, category, legacy, percentile, difficulty, skipped, denied, router, plans, cap, hits = sys.argv[1:]


def cache(path):
    try:
        with open(path, encoding="utf-8") as stream:
            data = json.load(stream)
            return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def price(row):
    try:
        rates = [float(row["pricing"][key]) for key in ("prompt", "completion")]
    except (KeyError, TypeError, ValueError):
        return None
    if all(math.isfinite(r) and r >= 0 for r in rates):
        return sum(rates) * 500000


def family(slug):
    return re.sub(r"-[0-9]{8}$", "", slug).replace(".", "-").lower()


data = cache(bench)
records = [r for r in data.get("data") or []
           if isinstance(r, dict) and isinstance(r.get("model_permaslug"), str)]
field = legacy
if category in ("code", "agentic") and any(isinstance(r.get("engineering_index"), (int, float)) for r in records):
    field = "engineering_index"
scores, exact = {}, {}
families = defaultdict(set)
for r in sorted(records, key=lambda r: r.get("model_permaslug", "")):
    slug = r.get("model_permaslug", "")
    key = family(slug)
    exact[slug] = r
    families[key.split("/")[-1]].add(key)
    scores[key] = r
catalog_prices, family_prices = {}, {}
for r in cache(models).get("data", []):
    if isinstance(r, dict) and isinstance(r.get("id"), str):
        catalog_prices[r["id"]] = price(r)
        key = family(r["id"])
        families[key.split("/")[-1]].add(key)
        if catalog_prices[r["id"]] is not None:
            family_prices[key] = catalog_prices[r["id"]]

with open(hits, encoding="utf-8") as stream:
    excluded = dict(line.rstrip().split("\t", 2)[:2] for line in stream if "\t" in line)
skips = set(skipped.split())
notes = sorted(skips)
patterns = denied.replace(",", " ").split()
rows, seen = [], set()
for line in open("/dev/fd/4", encoding="utf-8"):
    parts = line.rstrip().split("|")
    if len(parts) != 4 or not all(parts):
        continue
    alias, model, lane, tier = parts
    if lane in skips or (lane, model) in seen:
        continue
    if alias in excluded or model in excluded or any(model == pat or ("*" in pat and fnmatch.fnmatchcase(model, pat)) for pat in patterns):
        notes.append(excluded.get(alias) or excluded.get(model) or model)
        continue
    seen.add((lane, model))
    base = family(re.sub(r":free$", "", model))
    provider, _, bare = base.rpartition("/")
    provider = provider or {"cx": "openai", "gm": "google", "cc": "anthropic"}.get(lane, "")
    while True:
        keys = {k for k in families[bare] if not provider or k.startswith(provider + "/")}
        if keys or not re.search(r"-(low|medium|high|xhigh|max|fast)$", bare):
            break
        bare = bare.rsplit("-", 1)[0]
    key = next(iter(keys)) if len(keys) == 1 else base
    record = exact.get(model, scores.get(key, {}))
    pinned = re.search(r"-([0-9]{8})$", model)
    if pinned and not record.get("model_permaslug", "").endswith(pinned.group()):
        record = {}
    score = record.get(field)
    if not isinstance(score, (int, float)):
        score = None
    cost = price(record)
    if cost is None or model.endswith(":free"):
        cost = catalog_prices.get(model, catalog_prices.get(record.get("model_permaslug", ""), cost))
    if cost is None and not pinned:
        cost = family_prices.get(key)
    if cost == 0 and lane in plans.split():
        cost = None
    missing = []
    if score is None:
        missing.append("OpenRouter benchmarks missing " + field)
    if cost is None:
        missing.append("OpenRouter benchmarks and models missing prompt/completion list price")
    value = None
    if score is not None and cost is not None:
        value = score / cost if cost else "unlimited"
    rows.append(dict(release=record.get("model_permaslug"), alias=alias, model=model, lane=lane, tier=tier, score=score, price=cost,
                     value_ratio=value, unscored=score is None, missing=missing))

if cap.isdigit():
    discovered = [r for r in rows if r["lane"] == "or" and r["tier"] == "raw"]
    discovered.sort(key=lambda r: -(r["score"] if r["score"] is not None else -1))
    omitted = {id(r) for r in discovered[int(cap):]}
    rows = [r for r in rows if id(r) not in omitted]
measured = {r["release"]: r["score"] for r in rows if r["score"] is not None}
values = sorted(measured.values())
# Bar = a share of the best measured score among the runnable rows (skipped lanes are already out).
bar = round(max(values) * float(percentile) / 100, 1) if values else None
for row in rows:
    row["meets"] = row["score"] is not None and row["score"] >= bar


def lane_order(lane):
    if lane in plans.split():
        return 0
    return 1 if lane == "or" else 2


def order(row):
    value = row["value_ratio"]
    return (not row["meets"], value is None, -float("inf") if value == "unlimited" else -(value or 0),
            -(row["score"] or 0), row["release"] or row["model"],
            lane_order(row["lane"]) if router != "0" else 0)


rows.sort(key=order)
shortlist = [r for r in rows if r["meets"] and r["value_ratio"] is not None]
winner = shortlist[0].copy() if shortlist else None
if winner:
    winner["reason"] = ("picked {alias}: clears the bar for " + difficulty + " " + category +
                        " (score {score} >= bar " + str(bar) +
                        ") at the best quality per cost (${price:g}/M)").format(**winner)
count = sum(r["score"] is not None for r in rows)
print(json.dumps(dict(category=category, difficulty=difficulty, score_field=field, threshold=bar,
                      percentile=int(percentile), recommendation=winner, shortlist=shortlist, candidates=rows,
                      benchmark_coverage=f"{count}/{len(rows)}", benchmark_data_available=count > 0,
                      benchmark_as_of=data.get("meta", {}).get("as_of"), unscored_catalog_count=len(rows)-count,
                      conservation=None, limit_gate=", ".join(dict.fromkeys(notes)) or None)))
PYTHON
}
