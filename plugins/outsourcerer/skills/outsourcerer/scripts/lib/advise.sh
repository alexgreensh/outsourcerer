# Rank fixed bands anchored at the highest remaining score to avoid chained ties.
_advise_rank() {
  awk -F'|' -v threshold="$1" 'BEGIN{OFS="|"} NF {
    cost=$6*1000000; ratio="unscored"
    if ($5!="unscored" && $6!="unknown") ratio=sprintf("%.2f",$5/(cost<0.01?0.01:cost))
    print $1,$2,$3,$4,$5,($6=="plan limits" || $6=="unknown"?$6:sprintf("%.6f",cost)),ratio,($5!="unscored" && $5+0>=threshold),$7,$8,$9
  }' | LC_ALL=C sort -s -t'|' -k5,5rn | awk -F'|' -v tie="${OSRC_ADVISE_TIE:-1.0}" '
    BEGIN {if (tie !~ /^[0-9]+([.][0-9]+)?$/) tie=1}
    NF {
      if ($5!="unscored" && (!group || top-$5 > tie+0.000000001)) {group++; top=$5}
      # Only siblings in the same score band, lane and cost class can displace each other.
      k=group SUBSEP $3 SUBSEP $6 SUBSEP $10
      if ($10!="" && (!(k in light) || $11+0<light[k])) light[k]=$11+0
      family[NR]=k; weight[NR]=$11; row[NR]=$0
      keys[NR]=($5=="unscored") "|" group "|" (1-$9) "|" ($6=="unknown"?999999999:$6+0)
    }
    END {for(i=1;i<=NR;i++) {
      heavier=(weight[i]!="" && weight[i]+0>light[family[i]])
      print keys[i] "|" heavier "|" i "|" row[i] "|" heavier
    }}
  ' | LC_ALL=C sort -s -t'|' -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n -k6,6n | cut -d'|' -f7-

}

_advise_native_catalog_rows() {
  local lane id path
  for lane in gm cx dv; do
    path="$OSRC_HOME/catalogs/$lane.json"
    while IFS= read -r id; do
      case "$id" in ""|*[!a-zA-Z0-9._/-]*) continue ;; esac
      printf '%s|%s|%s|raw\n' "$id" "$id" "$lane"
    done < <({
      [ -r "$path" ] && jq -r '.[] | strings' "$path" 2>/dev/null
      local cx_cache="${CODEX_HOME:-$HOME/.codex}/models_cache.json"
      if [ "$lane" = cx ] && [ -r "$cx_cache" ]; then
        jq -r '.models[]? | select(.visibility != "hide") | .slug // empty' "$cx_cache"
      fi
      if [ "$lane" = gm ] && [ -r "$(_agy_models_cache)" ]; then cat "$(_agy_models_cache)"; fi
      if [ "$lane" = dv ] && [ -r "$OSRC_HOME/catalogs/dv.raw.json" ]; then
        jq -r '.families[]?.variants[]?.model_uid' "$OSRC_HOME/catalogs/dv.raw.json"
      fi
    } | awk -F'|' -v lane="$lane" 'NR==FNR {if ($3==lane) seen[$2]=1;next} !seen[$0]++' <(printf '%s\n' "$OSRC_MODEL_TABLE") -)
  done
}

# Enumerate the cached OpenRouter catalog, including models awaiting measurements.
_advise_candidate_rows() {
  local field="${1:-intelligence_index}" id score tier max="${OSRC_ADVISE_DYNAMIC_MAX:-}" added=0
  local seen=$'\n' alias resolved lane
  while IFS='|' read -r alias resolved lane tier; do
    [ -n "$alias" ] || continue
    printf '%s|%s|%s|%s\n' "$alias" "$resolved" "$lane" "$tier"
    [ "$lane" != or ] || seen="$seen$resolved"$'\n'
  done <<< "$OSRC_MODEL_TABLE"
  [ "${OSRC_ADVISE_DYNAMIC_POOL:-1}" != 0 ] || return 0
  _advise_native_catalog_rows
  [ -r "$OSRC_MODELS_JSON" ] && have jq || return 0
  case "$max" in *[!0-9]*) max="" ;; esac
  while IFS='|' read -r id score; do
    [ -z "$max" ] || [ "$added" -lt "$max" ] || break
    case "$id" in ""|*[!a-zA-Z0-9._/:-]*) continue ;; esac
    case "$seen" in *$'\n'"$id"$'\n'*) continue ;; esac
    tier="$(_tier_from_score "$score")"
    printf '%s|%s|or|%s\n' "$id" "$id" "$tier"
    seen="$seen$id"$'\n'
    added=$((added+1))
  done < <(awk -F'|' '
    FILENAME==ARGV[1] {score[$1]=$2; next}
    {id=$0; sub(/:free$/, "", id); print $0 "|" ((id in score)?score[id]:-1)}
  ' <(_advise_bench_rows "$field") <(jq -r '.data[]?.id // empty' "$OSRC_MODELS_JSON" 2>/dev/null) |
    LC_ALL=C sort -s -t'|' -k2,2rn)
}

# Emit canonical releases first and exact ids last so an exact score wins in the join.
_advise_bench_rows() {
  [ -r "$OSRC_BENCH_JSON" ] && have jq || return 0
  jq -r --arg field "$1" '
    [.data[]? | select(.[$field] | type == "number")] as $models
    | (($models[] | select(.model_permaslug|test("-[0-9]{8}$")) |
       [(.model_permaslug|sub("-[0-9]{8}$"; "")), .[$field], (.pricing.prompt // "unknown")]),
       ($models[] | [.model_permaslug, .[$field], (.pricing.prompt // "unknown")]))
    | map(tostring) | join("|")
  ' "$OSRC_BENCH_JSON" 2>/dev/null
}

_advise_scored_rows() {
  local field="$1" alias slug
  awk -F'|' '
    FILENAME==ARGV[1] {slug[$1]=$2; next}
    FILENAME==ARGV[2] {
      score[$1]=$2; price[$1]=$3
      bare=substr($1,index($1,"/")+1); gsub(/\./,"-",bare)
      if (!(bare in provider)) provider[bare]=$1
      else if (provider[bare]!=$1) provider[bare]=""
      next
    }
    {key=$2; if(key in slug) key=slug[key]
     else if ($3=="cx" && key ~ /^gpt-/) key="openai/" key
     else if ($3=="gm" && key ~ /^gemini-[0-9]/) {
       sub(/-(low|medium|high|xhigh|max)$/, "", key); key="google/" key
     } else if ($3=="dv") {bare=key; gsub(/\./,"-",bare); key=provider[bare]}
     sub(/:free$/, "", key)
     print $0 "|" ((key in score)?score[key]:"unscored") "|" ((key in price)?price[key]:"unknown")}
  ' <({
    printf '%s\n' "$_NATIVE_BENCH_MAP"
    for alias in gemini-pro gemini-flash gemini-flash-lite; do
      slug="$(_resolve_bench_slug "$alias")"; printf '%s|%s\n' "$alias" "$slug"
    done
  }) <(_advise_bench_rows "$field") <(_advise_candidate_rows "$field")
}

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

  if [ "$do_refresh" -eq 1 ] || [ ! -f "$OSRC_BENCH_JSON" ]; then
    # On explicit --refresh, show diagnostics (don't suppress stderr).
    if [ "$do_refresh" -eq 1 ]; then
      refresh_benchmarks >&2 || true
    elif [ "$json_out" -eq 1 ]; then
      # --json must emit ONLY JSON: suppress the refresh success line (stdout) too, not just stderr.
      refresh_benchmarks >/dev/null 2>&1 || true
    else
      refresh_benchmarks 2>/dev/null || true
    fi
  fi

  # Benchmark freshness: a cache dated >7 days ago refreshes automatically when an OpenRouter
  # key is configured; otherwise the stale age is called out once in the output below.
  local _bstale=""
  _bstale="$(_bench_cache_stale 2>/dev/null)"
  if [ -n "$_bstale" ] && { [ -n "${OPENROUTER_API_KEY:-}" ] || [ -n "$(_extract_kv_value OPENROUTER_API_KEY)" ]; }; then
    if [ "$json_out" -eq 1 ]; then refresh_benchmarks >/dev/null 2>&1 || true
    else refresh_benchmarks 2>/dev/null || true; fi
    _bstale="$(_bench_cache_stale 2>/dev/null)"
  fi

  local category field threshold difficulty
  category="$(_classify_task "$task")"
  field="$(_bench_score_field "$category")"
  threshold="$(_bench_threshold_for "$category")"
  difficulty="$(_task_difficulty "$task")"
  if [ -z "$selection_effort" ]; then
    case "$difficulty" in hard) selection_effort=high ;; *) selection_effort=medium ;; esac
  fi

  local _adv_limits="" conserve_notes="" _gate_limits="" _limit_notes="" _excluded_notes="" skipped_lanes=" "
  local limits=""
  if [ "${OSRC_ADVISE_CONSERVE:-1}" != 0 ] || [ "${OSRC_LANE_LIMIT_GATE:-1}" != 0 ]; then
    limits="$(_session_limits 2>/dev/null)"
  fi
  [ "${OSRC_ADVISE_CONSERVE:-1}" = 0 ] || _adv_limits="$limits"
  [ "${OSRC_LANE_LIMIT_GATE:-1}" = 0 ] || _gate_limits="$limits"
  local results="" has_bench=0 bench_count=0 total_count=0
  local alias resolved lane tier score price_in cost_per_m value_ratio meets
  local variant_pref="${OSRC_ADVISE_VARIANT_PREF:-1}" family weight
  _frontier_needed "$task" "$selection_effort" && variant_pref=0
  local last_lane="" image_lane plan_limited conserve blocked
  while IFS='|' read -r alias resolved lane tier score price_in; do
    [ -n "$alias" ] || continue
    if [ "$last_lane" != "$lane" ]; then
      last_lane="$lane"
      image_lane="$(_lane_field "$lane" image_lane)"
      plan_limited="$(_lane_field "$lane" plan_limited)"
      [ "$lane" != dv ] || plan_limited=yes
      conserve=1
      [ -z "$_adv_limits" ] || conserve="$(_lane_conserve_mult "$lane" "$_adv_limits")"
      blocked=0
      if [ -n "$_gate_limits" ] && _osrc_limit_exceeded "$lane" "$_gate_limits"; then
        blocked=1
        case "$skipped_lanes" in *" $lane "*) ;; *)
          skipped_lanes="$skipped_lanes$lane "
          _limit_notes="${_limit_notes:+$_limit_notes; }$(_osrc_lane_limit "$lane" "$_gate_limits") >= $(_osrc_limit_threshold)% -> $lane excluded"
        esac
      fi
    fi
    [ "$image_lane" != yes ] && [ "$blocked" = 0 ] || continue
    if _model_denied "$resolved" || _model_excluded "$alias" || _model_excluded "$lane"; then
      _excluded_notes="${_excluded_notes:+$_excluded_notes, }$alias"
      continue
    fi
    total_count=$((total_count+1))
    [ "$score" = unscored ] || bench_count=$((bench_count+1))
    if [ "${conserve#0.}" != "$conserve" ]; then
      conserve_notes="Lane headroom breaks ties within ${OSRC_ADVISE_TIE:-1.0} points."
    fi
    [ "$plan_limited" != yes ] || price_in="plan limits"
    family=""; weight=""
    if [ "$variant_pref" = 1 ] && [ "$lane" = dv ] && [ "$score" != unscored ]; then
      family="$(_variant_family "$resolved")"; weight="$(_variant_weight "$resolved" "$selection_effort")"
    fi
    results="$results$alias|$resolved|$lane|$tier|$score|$price_in|$conserve|$family|$weight
"
  done < <(_advise_scored_rows "$field")

  local rec_alias rec_resolved rec_lane rec_tier rec_score rec_reason highest
  results="$(printf '%s' "$results" | _advise_rank "$threshold")"
  IFS='|' read -r rec_alias rec_resolved rec_lane rec_tier rec_score _ <<< "$results"
  highest="$(printf '%s\n' "$results" | awk -F'|' '$5!="unscored"{if (!found || $5+0>max) max=$5+0; found=1} END{if(found) print max}')"
  if [ "$rec_score" = unscored ]; then
    rec_reason="picked $rec_alias: all available models are unscored for ${field%_index}"
  elif awk -v a="$rec_score" -v b="$highest" 'BEGIN{exit !(a==b)}'; then
    rec_reason="picked $rec_alias: highest ${field%_index} score ($rec_score) among models you can run now"
  else
    rec_reason="picked $rec_alias: ${field%_index} score $rec_score is within ${OSRC_ADVISE_TIE:-1.0} points of $highest; cost, lane headroom or a lighter sibling broke the tie"
  fi

  # Lane routing: the quality logic above chose the MODEL; keep it, but run it on its cheapest
  # AVAILABLE lane. The same model often lives on a per-token cash lane (OpenRouter) AND a plan lane
  # the user already pays for (a free Devin tier, a Warp/Claude/Codex sub), whose marginal cost is
  # ~0 -- so a sunk subscription is spent before real cash. Only the lane moves; the winning model is
  # never downgraded. A cost-unknown (BYOK) lane never wins on cost. OSRC_ADVISE_ROUTER=0 keeps the
  # pre-router lane.
  local rec_cost_basis=""
  if [ "${OSRC_ADVISE_ROUTER:-1}" != "0" ] && [ -n "$rec_resolved" ]; then
    local _rk _rlanes _l _lc _lcost _lbasis
    _rk="$(_model_canon_key "$rec_resolved" 2>/dev/null)"
    _rlanes="$(_model_lanes "$_rk" 2>/dev/null)"
    # Seed with the current pick's own marginal cost so a tie keeps the originally-chosen lane.
    _lc="$(_lane_marginal_cost "$rec_lane" "$rec_resolved" 2>/dev/null)"
    _lcost="${_lc%% *}"; rec_cost_basis="${_lc##* }"
    case "$_lcost" in ''|-1|*[!0-9.]*) _lcost="" ; rec_cost_basis="${_lc##* }" ;; esac
    local _bestcost="$_lcost"
    [ "$rec_cost_basis" != unknown ] || _bestcost=""
    for _l in $_rlanes; do
      [ "$_l" = "$rec_lane" ] && continue
      _model_excluded "$_l" && continue
      [ -n "$_gate_limits" ] && _osrc_limit_exceeded "$_l" "$_gate_limits" && continue
      _lc="$(_lane_marginal_cost "$_l" "$rec_resolved" 2>/dev/null)"
      _lcost="${_lc%% *}"; _lbasis="${_lc##* }"
      [ "$_lbasis" != unknown ] || continue
      case "$_lcost" in ''|-1|*[!0-9.]*) continue ;; esac   # unknown/BYOK never wins on cost
      if [ -z "$_bestcost" ] || awk -v a="$_lcost" -v b="$_bestcost" 'BEGIN{exit (a+0 < b+0)?0:1}'; then
        _bestcost="$_lcost"; rec_lane="$_l"; rec_cost_basis="$_lbasis"
      fi
    done
  fi

  [ -z "$_excluded_notes" ] || _limit_notes="${_limit_notes:+$_limit_notes; }skipped excluded models: $_excluded_notes"

  # Determine benchmark data quality: live (majority), partial, or none.
  if [ "$bench_count" -gt 0 ] && [ "$total_count" -gt 0 ] && [ "$bench_count" -ge $((total_count / 2)) ]; then
    has_bench=1
  elif [ "$bench_count" -gt 0 ]; then
    has_bench=2  # partial
  else
    has_bench=0
  fi

  # Guard: if no candidates at all (empty model table), fail gracefully.
  if [ -z "$rec_alias" ] && [ -n "$_limit_notes" ]; then
    die "advise: no eligible candidates (${_limit_notes}). Wait for a window reset, or set OSRC_LANE_LIMIT_GATE=0."
  fi
  [ -n "$rec_alias" ] || die "advise: no models found in the alias table to score"

  # Keep history metadata for JSON consumers. It does not affect selection.
  local _rh rec_mult rec_neff rec_peff rec_scope _rhrest
  _rh="$(_history_mult "$rec_lane" "$rec_resolved" "$category")"
  rec_mult="${_rh%%|*}"; _rhrest="${_rh#*|}"; rec_neff="${_rhrest%%|*}"; _rhrest="${_rhrest#*|}"; rec_peff="${_rhrest%%|*}"; rec_scope="${_rh##*|}"
  case "$rec_mult" in ''|*[!0-9.]*) rec_mult="1.00" ;; esac

  local shortlist_json="[]"
  if [ "$json_out" -eq 1 ]; then
    shortlist_json="$(printf '%s' "$results" | jq -Rs '
      split("\n") | map(select(length>0) | split("|") |
      {alias:.[0], model:.[1], lane:.[2], meets:(.[7]=="1"),
       score:(.[4]|tonumber? // null), unscored:(.[4]=="unscored"),
       value_ratio:(.[6]|tonumber? // null), lighter_sibling_preferred:(.[11]=="1")})')"
  fi

  local _bstale_json=false _bench_asof=""
  [ -n "$_bstale" ] && { _bstale_json=true; _bench_asof="${_bstale#*$'\t'}"; }
  if [ "$json_out" -eq 1 ]; then
    jq -n \
      --arg task "$task" --arg category "$category" --arg field "$field" --arg threshold "$threshold" \
      --arg rec_alias "$rec_alias" --arg rec_resolved "$rec_resolved" --arg rec_lane "$rec_lane" \
      --arg rec_cost_basis "$rec_cost_basis" \
      --arg rec_tier "$rec_tier" --arg effort "$selection_effort" --arg difficulty "$difficulty" \
      --arg rec_reason "$rec_reason" --arg has_bench "$has_bench" --argjson bench_count "$bench_count" --argjson total_count "$total_count" \
      --arg hmult "$rec_mult" --arg hneff "$rec_neff" --arg hpeff "$rec_peff" --arg hscope "$rec_scope" \
      --arg conserve "$conserve_notes" --arg limit_gate "$_limit_notes" \
      --arg bench_asof "$_bench_asof" --argjson bench_stale "$_bstale_json" \
      --argjson shortlist "$shortlist_json" \
      '{task:$task, category:$category, difficulty:$difficulty, effort:$effort, score_field:$field, threshold:$threshold,
        recommendation:{alias:$rec_alias, model:$rec_resolved, lane:$rec_lane, cost_basis:(if $rec_cost_basis=="" then null else $rec_cost_basis end), tier:$rec_tier, reason:$rec_reason},
        shortlist:($shortlist | .[0].lane=$rec_lane),
        conservation:(if $conserve=="" then null else $conserve end),
        limit_gate:(if $limit_gate=="" then null else $limit_gate end),
        benchmark_data_available:($has_bench=="1"),
        benchmark_stale:$bench_stale,
        benchmark_as_of:(if $bench_asof=="" then null else $bench_asof end),
        benchmark_coverage:((($bench_count|tostring) + "/" + ($total_count|tostring))),
        history:{multiplier:($hmult|tonumber? // 1.0), effective_samples:($hneff|tonumber? // 0),
                 passed_effective:($hpeff|tonumber? // 0), scope:$hscope}}'

  else
    echo "== outsourcerer advise =="
    echo "   task: $task"
    echo "   category: $category"
    echo "   difficulty: $difficulty"
    echo "   effort: $selection_effort"
    echo "   effort tip: start at this level, re-run the same task one rung lower; if quality holds, keep the cheaper rung (medium often matches high at lower cost)."
    echo "   scoring by: $field (threshold: $threshold)"
    if [ "$has_bench" = "1" ]; then
      echo "   benchmark data: live (OpenRouter, $(jq -r '.meta.as_of // "?"' "$OSRC_BENCH_JSON" 2>/dev/null), $bench_count/$total_count models)"
    elif [ "$has_bench" = "2" ]; then
      echo "   benchmark data: partial ($bench_count/$total_count models have live scores, rest are unscored, run: $0 advise --refresh \"$task\")"
    else
      echo "   benchmark data: none (all models unscored, run: $0 advise --refresh \"$task\")"
    fi
    if [ -n "$_bstale" ]; then
      local _bd="${_bstale%%$'\t'*}" _ba="${_bstale#*$'\t'}" _bage
      if [ "$_bd" = "unknown" ]; then _bage="an unknown age"; else _bage="$_bd days old"; fi
      echo "   benchmark cache is $_bage (as of $_ba); refresh: $0 advise --refresh \"$task\""
    fi
    [ -n "$conserve_notes" ] && echo "   conservation: $conserve_notes "
    [ -n "$_limit_notes" ] && echo "   limit-gate: $_limit_notes"
    echo
    echo "--- recommendation ---"
    echo "   model: $rec_alias ($rec_resolved)"
    echo "   lane:  $rec_lane${rec_cost_basis:+ (cost: $rec_cost_basis)}"
    echo "   why:   $rec_reason"
    echo
    echo "--- all candidates (ranked by benchmark, >> = recommended) ---"
    printf '%s\n' "$results" | while IFS='|' read -r alias resolved lane tier score cost vr meets conserve family weight _pref; do
      [ -n "$alias" ] || continue
      local mark="  " verdict
      [ "$alias" = "$rec_alias" ] && mark=">>"
      if [ "$score" = unscored ]; then verdict=unscored
      elif [ "$_pref" = 1 ]; then verdict='OK (lighter sibling preferred)'
      elif [ "$meets" != "1" ]; then verdict='below threshold'

      else verdict=OK; fi
      printf '%s %-16s %-28s lane=%-3s score=%-5s $/M=%-14s ratio=%-7s %s\n' \
        "$mark" "$alias" "$resolved" "$lane" "$score" "$cost" "$vr" "$verdict"
    done
    echo
    echo "Run with:  $0 run -m $rec_alias --effort $selection_effort \"$task\""
    echo "Override:  $0 run -m <any-model> --effort $selection_effort \"$task\"   (you know better, pick your own)"
  fi
}
