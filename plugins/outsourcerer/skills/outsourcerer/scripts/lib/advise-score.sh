# lib/advise-score.sh — the `advise` command (moved out of outsourcerer.sh, engine-size
# budget) plus the B2 live-source scoring layer. Ranking when the source caches under
# $OSRC_ADVISE_DIR are warm: quality gate = max(absolute threshold, share x best-runnable
# score for the task class) with history/conserve folded onto live scores, qualifiers rank
# by REAL $/task (bench-measured -> list-price x tokens estimate; subscription lanes priced
# at list price), speed breaks ties. Cold cache -> the original cohort ranking verbatim.
# Fetch/refresh machinery: lib/advise-fetch.sh. Parsers + normalizer: lib/advise_parse.py.

_OSRC_LIB_DIR="${_OSRC_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"
OSRC_ADVISE_DIR="${OSRC_ADVISE_DIR:-$OSRC_HOME/advise}"

# cmd_advise: task-aware model recommendation with benchmark data.
# Usage: advise [--refresh] [--json] [--effort LEVEL] "<task prompt>"
# Classifies the task, scores all known models, recommends the best value model
# that meets the capability threshold. Explains WHY it picked that model.
# B2: when the live-source caches under $OSRC_ADVISE_DIR are warm, the quality bar is
# "share of best runnable score" (OSRC_ADVISE_QUALITY_SHARE, default 0.85) and qualifiers
# rank by REAL $/task (bench-measured, list-price estimate as fallback; subs priced at
# list), speed as tiebreak. Cold caches -> the original cohort ranking, byte-for-byte.
# The candidate pool is the curated OSRC_MODEL_TABLE UNIONED with the live catalog (cached
# dv.raw.json + models.json); see _advise_candidate_rows. OSRC_ADVISE_DYNAMIC_POOL=0 falls back to
# the static-only pool. Cost-safety is unchanged: the winning id still flows through
# _devin_resolve_model / _catalog_validate at delegate time.

# ---- B2 batched scoring ------------------------------------------------------
# Variant-family/weight ported to awk so the whole pass runs in-process; the bash
# _variant_family/_variant_weight above remain the reference implementation the
# tests pin (both are exercised). _avf = family, _avw = weight.
_OSRC_VW_AWK='
function _avf(id,  _t){ _t=tolower(id); gsub(/\./,"-",_t); sub(/^.*\//,"",_t)
  while(gsub(/-(none|minimal|low|medium|high|xhigh|max|1m|flash|lightning|mini|lite|turbo)$/,"",_t)); return _t }
function _avw(id,eff,  _t,_w,_r,_tg,_d){ _t=tolower(id); gsub(/\./,"-",_t); sub(/^.*\//,"",_t)
  _w=10; if(_t ~ /-(flash|lightning|mini|lite)(-|$)/) _w=0
  sub(/-1m$/,"",_t)
  _r=(_t ~ /-(none|minimal|low)$/)?0:(_t ~ /-medium$/)?1:(_t ~ /-high$/)?2:(_t ~ /-(xhigh|max)$/)?3:-1
  _tg=(eff ~ /^(minimal|low|none)$/)?0:(eff=="medium")?1:(eff=="high")?2:3
  _d=(_r<0)?1:((_r-_tg<0)?_tg-_r:_r-_tg); return _w+_d }
function laneof(t,   i,n,A,j){
  for(i=1;i<=nl;i++){
    if(ln[i]==t) return t
    if((" " la[i] " ") ~ (" " t " ")) return ln[i]
    if(ld[i] != "-" && ld[i]==t) return ln[i]
    n=split(ldb[i],A," "); for(j=1;j<=n;j++){ sub(/^[^=]*=/,"",A[j]); if(A[j]==t) return ln[i] }
  }
  return t }'

# _OSRC_SCORE_AWK: single pass over tagged rows -> scored candidates + side channels.
# Input tags: P|alias|resolved|lane|tier (pool), L|lane|aliases|disp|dbp|image|plan|clabel|windows,
# B|permaslug|score|pin|pout (bench), R|resolved|slug (slug map), M|id|pin|pout (models pricing),
# H|lane|mult (history), D|resolved (denied), X|alias (excluded), T|name|val (limits tokens).
# Output: R|<9 score cols>|plan, B|resolved|raw, N|C|conserve-note, N|L|limit-note, C|bench|total.
_OSRC_SCORE_AWK='
$1=="P"{ np++; pa[np]=$2; pr[np]=$3; pl[np]=$4; pt[np]=$5; next }
$1=="L"{ nl++; ln[nl]=$2; la[nl]=$3; ld[nl]=($4==""?"-":$4); ldb[nl]=$5; limg[$2]=$6; lplan[$2]=$7; lcl[$2]=$8; lwin[$2]=$9; lmarg[$2]=$10; next }
$1=="B"{ p=$2; if(!(p in bs)){ bseq[p]=++nb; bs[p]=$3; bpin[p]=$4; bpout[p]=$5 } next }
$1=="R"{ if($3!="") rslug[$2]=$3; next }
$1=="M"{ if(!($2 in mpin)){ mpin[$2]=$3; mpout[$2]=$4 } next }
$1=="H"{ if($3 ~ /^[0-9.]+$/) hm[$2]=$3+0; hbf[$2]=$7+0; next }
$1=="D"{ deny[$2]=1; next }
$1=="X"{ excl[$2]=1; next }
$1=="T"{ lim[$2]=$3; next }
$1=="T2"{ wres[$2]=$3; next }
$1=="L2"{ wn="probe_"$2
          if(lwin[$2] !~ ("(^| )"wn"( |$)")) lwin[$2]=lwin[$2]" "wn
          lim[wn]=100-$3; next }
END{
  px["frontier"]=55; px["capable"]=50; px["mid"]=40; px["budget"]=30
  gt=gate_thr; if(gt !~ /^[0-9.]+$/) gt=90
  for(i=1;i<=np;i++){
    a=pa[i]; res=pr[i]; lane=pl[i]; tier=pt[i]
    cl=laneof(lane)
    if(limg[cl]=="yes") continue
    if(res in deny) continue
    if((a in excl) || (res in excl)) continue
    if(gate_on==1){
      u=-1; bw=""; nw=split(lwin[cl],W," ")
      for(j=1;j<=nw;j++){ w=W[j]; if((w in lim) && lim[w] ~ /^[0-9.]+$/ && lim[w]+0>u){ u=lim[w]+0; bw=w } }
      stale=0
      if(nw>0){ co=1; for(j=1;j<=nw;j++) if(W[j] !~ /^codex/) co=0
        if(co && ("codexage" in lim) && lim["codexage"] ~ /^[0-9]+$/ && lim["codexage"]+0>stale_secs) stale=1 }
      if(u>=0 && !stale){ if(!(cl in hrem)){ hrem[cl]=1; print "HR|" cl "|" u }
        if(u>=gt){ print "N|L|" bw "=" u " >= " gt "% -> " lane " excluded"
          print "K|" a "|" res "|" lane "|" u "|" (bw in wres ? wres[bw] : ""); continue } }
    }
    tc++
    if(res in rslug){ s=rslug[res] } else { s=res; sub(/:free$/,"",s) }
    raw=""; pin="0"; pout="0"; hit=0
    if(s in bs){ hit=1; raw=bs[s]; pin=bpin[s]; pout=bpout[s] }
    else { bl=-1; bpm=""
      for(pp in bs) if(index(pp,s)==1){ L=length(pp)
        if(bl<0 || L<bl || (L==bl && bseq[pp]<bseq[bpm])){ bl=L; bpm=pp } }
      if(bl>0){ hit=1; raw=bs[bpm]; pin=bpin[bpm]; pout=bpout[bpm] } }
    if(hit){ bc++; score=raw }
    else { score=((tier in px)?px[tier]:35); if(res in mpin){ pin=mpin[res]; pout=mpout[res] } }
    print "B|" res "|" score
    m=((lane in hm)?hm[lane]:1.00); score=sprintf("%.4f",score*m)
    adj=0
    if(tier=="capable"){ adj+=8; if(eff=="high"||eff=="xhigh") adj+=2 }
    if(res=="kimi-k3" && dif=="hard" && cat=="reasoning") adj+=20
    if(eff=="max" && tier=="frontier") adj+=30
    score=sprintf("%.4f",score+adj)
    if(cons_on==1){
      cu=-1; nw2=split(lwin[cl],W2," ")
      for(j=1;j<=nw2;j++){ w=W2[j]; if((w in lim) && lim[w] ~ /^[0-9.]+$/ && lim[w]+0>cu) cu=lim[w]+0 }
      if(cu>=0 && cons_t<100 && cu>=cons_t){ cm=1-0.10*(cu-cons_t)/(100-cons_t); if(cm<0.90)cm=0.90; if(cm>1)cm=1.00 } else cm=1.00
      if(!(cl in wem)){ wem[cl]=1; print "W|" cl "|" cm }
      if(cm<1.0){ score=sprintf("%.4f",score*cm)
        if(!(cl in cseen)){ cseen[cl]=1
          lab=((cl in lcl) && lcl[cl]!="")?lcl[cl]:lane
          print "N|C|" lab " past conserve line -> score x" sprintf("%.4f",cm) } }
    }
    plan=(lplan[cl]=="yes" || lane=="dv")?1:0
    if(plan){ pin="0"; pout="0" }
    cpm=pin*1000000; cf=(cpm<0.01)?0.01:cpm
    vr=sprintf("%.2f",score/cf)
    meets=(score+0>=thr)?1:0
    cost=(plan==1)?"plan limits":sprintf("%.6f",cpm)
    print "R|" a "|" res "|" lane "|" tier "|" score "|" cost "|" vr "|" meets "|0|" plan
  }
  printf "C|%d|%d\n", bc+0, tc+0 }'

# _OSRC_MARG_AWK: catalog membership + _lane_marginal_cost for the rec lane set in ONE pass.
# Inputs: L/W/M/I rows (lane map, conserve mults, model prices, catalog ids) + Q|lane queries.
# canon() is byte-for-byte the function _model_lanes embeds; rid is the rec's resolved id.
# Output: "LANES|<or dv warp>" and "M|<lane>|<cost>|<basis>" per queried lane.
_OSRC_MARG_AWK='
function canon(s,  c){ c=tolower(s); sub(/^[^\/]*\//,"",c); sub(/-[0-9]{6,}$/,"",c)
  while(sub(/-(high|low|max|medium)$/,"",c)){} gsub(/\./,"-",c); return c }
BEGIN{ rkey=canon(rid) }
$1=="L"{ nl++; ln[nl]=$2; la[nl]=$3; ld[nl]=($4==""?"-":$4); ldb[nl]=$5; lmarg[$2]=$10; next }
$1=="W"{ wm[$2]=$3+0; next }
$1=="M"{ if(!($2 in mpin)){ mpin[$2]=$3; mpout[$2]=$4 } if(canon($2)==rkey) orhit=1; next }
$1=="I"{ if($2=="dv" && canon($3)==rkey) dvhit=1
         if($2=="warp" && canon($3)==rkey) warphit=1; next }
$1=="Q"{ if(!($2 in qseen)){ qseen[$2]=1; q[++nq]=$2 } next }
END{
  lanes=""; if(orhit)lanes="or"; if(dvhit)lanes=lanes (lanes?" dv":"dv"); if(warphit)lanes=lanes (lanes?" warp":"warp")
  print "LANES|" lanes
  for(i=1;i<=nq;i++){ lane=q[i]; cl=laneof(lane); cls=((cl in lmarg)?lmarg[cl]:"")
    if(cls==""){ if(lane=="dv"||lane=="gemini") cls="plan"; else cls="unknown" }
    if(cls=="metered"){ p=mpin[rid]
      if(p != "" && p ~ /^[0-9.-]+$/) printf "M|%s|%s est\n",lane,sprintf("%g",1000*p+0)
      else printf "M|%s|0 unknown\n",lane }
    else if(cls=="plan"){ m=((cl in wm)?wm[cl]:1.00)
      if(m+0<1.0) printf "M|%s|999 overage\n",lane; else printf "M|%s|0 plan\n",lane }
    else if(cls=="free") printf "M|%s|0 free\n",lane
    else printf "M|%s|-1 unknown\n",lane } }'

# _prof_mark/_prof_dump: micro-profiling for the advise hot path (debug flag _ADV_PROF).
_prof_mark() {
  [ -z "${_ADV_PROF:-}" ] && return 0
  local _n; _n="$(python3 -c 'import time;print(time.time())' 2>/dev/null)"
  _prof_marks="${_prof_marks}${1}:$(awk -v a="$_n" -v b="$_prof_last" 'BEGIN{printf "%.3f", a-b}') "
  _prof_last="$_n"
}
_prof_dump() { [ -n "${_ADV_PROF:-}" ] && printf 'advise-prof: %s\n' "$_prof_marks" >&2; }

# _adv_lane_id <lane> <alias> <resolved> -> the exact id the lane actually runs today.
# cc aliases resolve via OSRC_CLAUDE_CURRENT_IDS (fable->claude-fable-5-1, opus->claude-opus-5-5,
# sonnet->claude-sonnet-5-5, haiku->claude-haiku-5-5); gm aliases via the live agy token map
# (gemini-pro->gemini-4-neon-high today). Everything else keeps its model-table resolved id.
_adv_lane_id() {
  local lane="$1" a="$2" r="$3" pair e t=""
  case "$lane" in
    cc) # Current id comes from the LIVE catalog (newest claude-<alias>-* family in
        # rows.jsonl): OSRC_CLAUDE_CURRENT_IDS still says fable->5-1 while the
        # catalog already carries claude-fable-5-2. Env is the offline fallback.
        t="$(grep -o "\"family\":\"claude-${a}-[0-9][0-9-]*\"" \
             "$OSRC_ADVISE_DIR/rows.jsonl" 2>/dev/null | cut -d'"' -f4 | sort -u \
             | _vsort 2>/dev/null | tail -1)"
        if [ -n "$t" ]; then printf '%s' "$t"; return 0; fi
        for pair in $OSRC_CLAUDE_CURRENT_IDS; do
          e="${pair%%|*}"; [ "$e" = "$a" ] && { printf '%s' "${pair#*|}"; return 0; }
        done ;;
    gm) t="$(declare -f _agy_model_token >/dev/null && _agy_model_token "$a" 2>/dev/null)"
        [ -n "$t" ] && { printf '%s' "$t"; return 0; } ;;
  esac
  printf '%s' "$r"
}

cmd_advise() {
  local _prof_last="" _prof_marks=""
  [ -n "${_ADV_PROF:-}" ] && _prof_last="$(python3 -c 'import time;print(time.time())' 2>/dev/null)"
  local do_refresh=0 json_out=0 legacy_out="${OSRC_ADVISE_LEGACY:-0}" task="" selection_effort="${OUTSOURCERER_EFFORT:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --refresh) do_refresh=1; shift ;;
      --json)    json_out=1; shift ;;
      --legacy)  legacy_out=1; shift ;;
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
      refresh_benchmarks || true
      _advise_refresh_worker        # B2: every live source in parallel + rows.jsonl rebuild
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

  # B2: a source past its TTL fires a DETACHED refresh — this pick always reads the warm
  # cache. Gated on the advise dir already existing (bootstrap is `advise --refresh`), so a
  # feature-off install never self-fires network from the pick path.
  if [ "${OSRC_ADVISE_AUTO_REFRESH:-1}" != "0" ] && [ "${OSRC_ADVISE_NET:-1}" != "0" ] \
     && [ -d "$OSRC_ADVISE_DIR" ] && _advise_sources_expired; then
    _advise_refresh_detached
  fi

  local category field threshold difficulty frontier_needed=0
  category="$(_classify_task "$task")"
  field="$(_bench_score_field "$category")"
  threshold="$(_bench_threshold_for "$category")"
  difficulty="$(_task_difficulty "$task")"
  if [ -z "$selection_effort" ]; then
    case "$difficulty" in hard) selection_effort=high ;; *) selection_effort=medium ;; esac
  fi
  _frontier_needed "$task" "$selection_effort" && frontier_needed=1
  [ -z "${_ADV_PROF:-}" ] || _prof_mark classify

  # Live per-lane limits, read once, so a nearly-exhausted subscription lane is deprioritized in the
  # recommendation itself (not only by the separate conserve-routing layer). Best-effort; empty -> no
  # penalty anywhere. Opt out with OSRC_ADVISE_CONSERVE=0.
  # Live per-lane limits, read once, so a nearly-exhausted subscription lane is deprioritized in the
  # recommendation itself (not only by the separate conserve-routing layer). Best-effort; empty -> no
  # penalty anywhere. Opt out with OSRC_ADVISE_CONSERVE=0.
  # LIMIT GATE: a lane at/over OSRC_LANE_LIMIT_PCT on a FRESH meter is excluded outright — the
  # hard edge, independent of the soft conserve haircut below. Stale readings count as unknown.
  # OSRC_LANE_LIMIT_GATE=0 disables. The meter is read ONCE and shared by conserve and gate.
  # The three independent slow reads (limits meter, outcome-history fold, dv/warp catalog ids)
  # run in BACKGROUND subshells writing pid-keyed scratch files under the advise cache dir, so
  # they overlap the foreground prepass. Consumed below after `wait`; files removed
  # after use. Scratch lives under $OSRC_HOME (always exists) — never mkdir $OSRC_ADVISE_DIR
  # here: its mere existence toggles the "sources:" status line in the output.
  local _adv_limits="" _gate_limits="" _limits_once=""
  local _par_lim="" _par_hist="" _par_cat="" _p_lim="" _p_hist="" _p_cat=""
  local _par_root="${OSRC_HOME:-$HOME/.outsourcerer}"
  if [ "${OSRC_ADVISE_CONSERVE:-1}" != "0" ] || [ "${OSRC_LANE_LIMIT_GATE:-1}" != "0" ]; then
    _par_lim="$_par_root/.par-lim.$$"; _par_res="$_par_root/.par-res.$$"
    ( _session_limits >"$_par_lim" 2>/dev/null ) & _p_lim=$!
    ( _osrc_meter_windows >"$_par_res" 2>/dev/null ) & _p_res=$!
  fi
  _par_cat="$_par_root/.par-cat.$$"
  ( { _dvf="$(_catalog_path dv 2>/dev/null)" && _dvf="${_dvf%.json}.raw.json" \
        && [ -f "$_dvf" ] && jq -r '.families[]?.variants[]?.model_uid // empty' "$_dvf" 2>/dev/null \
        | awk '{print "I|dv|"$0}'
      _wpf="$(_catalog_path warp 2>/dev/null)" && [ -f "$_wpf" ] \
        && jq -r '.[] // empty' "$_wpf" 2>/dev/null | awk '{print "I|warp|"$0}'
    } >"$_par_cat" 2>/dev/null ) & _p_cat=$!
  [ "${OSRC_ADVISE_CONSERVE:-1}" != "0" ] && _adv_limits="$_limits_once"
  [ "${OSRC_LANE_LIMIT_GATE:-1}" != "0" ] && _gate_limits="$_limits_once"
  [ -z "${_ADV_PROF:-}" ] || _prof_mark limits

  # Score each candidate — BATCHED. Every per-candidate evidence source is precomputed into tagged
  # rows first, then ONE awk pass applies the scoring rules verbatim. This is what keeps the warm
  # path under 1s: the original per-row loop spawned ~10 subprocesses per candidate (lane flags,
  # bench jq, history jq, conserve awk, score awks) — ~25s on a 46-row pool.
  local results="" results_p="" has_bench=0 bench_count=0 total_count=0 base_map=""
  local conserve_notes="" _limit_notes="" _gate_seen="" _gate_rows=""
  local _pool _lane_rows="" _slug_rows="" _hist_rows="" _deny_rows="" _excl_rows="" _lim_rows="" _w_rows="" _scored _hr_rows="" _parked_rows=""
  _pool="$(_advise_candidate_rows "$field")"
  [ -z "${_ADV_PROF:-}" ] || _prof_mark pool

  # Lane descriptors once: image/plan/conserve fields + the tokens _lane_by_token resolves on.
  local _l _d _fl _fa _fd _fdb _fi _fp _fcl _fcw _fmc
  for _l in $OSRC_LANE_REGISTRY; do
    _d="$(lane_descriptor_"$_l" 2>/dev/null)"
    _fa=""; _fd=""; _fdb=""; _fi=""; _fp=""; _fcl=""; _fcw=""; _fmc=""
    while IFS= read -r _fl; do
      case "$_fl" in
        aliases=*) _fa="${_fl#*=}" ;;
        disp=*) _fd="${_fl#*=}" ;;
        disp_by_provider=*) _fdb="${_fl#*=}" ;;
        image_lane=*) _fi="${_fl#*=}" ;;
        plan_limited=*) _fp="${_fl#*=}" ;;
        conserve_label=*) _fcl="${_fl#*=}" ;;
        conserve_windows=*) _fcw="${_fl#*=}" ;;
        marginal_class=*) _fmc="${_fl#*=}" ;;
      esac
    done <<_ADV_LANE_FIELDS
$_d
_ADV_LANE_FIELDS
    _lane_rows="${_lane_rows}L|${_l}|${_fa}|${_fd}|${_fdb}|${_fi}|${_fp}|${_fcl}|${_fcw}|${_fmc}
"
  done
  [ -z "${_ADV_PROF:-}" ] || _prof_mark lanes

  # Bench slugs once per source: native map rows verbatim, the 3 symbolic gemini fams once, and
  # agy-resolved gemini-4 variants only for rows actually in the pool.
  _slug_rows="$(printf '%s\n' "$_NATIVE_BENCH_MAP" | awk -F'|' 'NF>=2{print "R|"$1"|"$2}')"
  local _r _sl
  for _r in "gemini-flash-lite|flash-lite" "gemini-flash|flash" "gemini-pro|pro"; do
    _sl="$(_gemini_bench_slug "${_r#*|}" 2>/dev/null)"
    [ -n "$_sl" ] && _slug_rows="${_slug_rows}R|${_r%%|*}|${_sl}
"
  done
  while IFS= read -r _r; do
    [ -n "$_r" ] || continue
    _sl="$(_agy_or_bench_slug "$_r" 2>/dev/null)"
    [ -n "$_sl" ] && _slug_rows="${_slug_rows}R|${_r}|${_sl}
"
  done < <(printf '%s\n' "$_pool" | awk -F'|' '$2 ~ /^gemini-.+-(neon|argon|hydrogen|carbon)/{print $2}' | sort -u)
  [ -z "${_ADV_PROF:-}" ] || _prof_mark slugs

  # Local outcome history folded ONCE for every lane at this category (same math as _history_mult,
  # grouped by lane instead of re-run per candidate). _hist_rows = "lane|mult|neff|peff|scope".
  local -a _of=(); local _f _rk; _rk="$(_repo_key)"
  while IFS= read -r _f; do [ -n "$_f" ] && _of+=("$_f"); done < <(_outcomes_files)
  if [ "${#_of[@]}" -gt 0 ] && have jq; then
    _par_hist="$_par_root/.par-hist.$$"
    ( jq -rR --arg cat "$category" --arg rk "$_rk" '
      fromjson? // empty
      | select(.event=="outcome" and .task_class==$cat and (.lane|type)=="string"
             and (.outcome=="passed" or .outcome=="failed" or .outcome=="reverted" or .outcome=="blocked"))
      | (try (.ts|fromdateiso8601) catch null) as $t | select($t != null)
      | ((now - $t) / 86400) as $age | select($age <= 90)
      | [ .lane, (if .repo_key==$rk then 1 else 0 end), (if $age<0 then 0 else $age end), (if .outcome=="passed" then 1 else 0 end), (.outcome|tostring), (.reason//""|tostring) ]
      | @tsv' "${_of[@]}" 2>/dev/null | awk -F'\t' '
      NF<4{next}
      { l=$1; if($5=="blocked" && $6=="provider_error" && $3<=1) bf[l]++
        if($5!="blocked"){ w=0.5^($3/60); tw[l]+=w; tp[l]+=w*$4; if($2==1){rw[l]+=w;rp[l]+=w*$4;rc[l]++} } }
      END{ for(l in tw){ K=8;prior=0.70
        if(rc[l]>=3 && rw[l]>=2.5){n=rw[l];s=rp[l];sc="repo"}else{n=tw[l];s=tp[l];sc="global"}
        if(n<=0)continue
        m=((K*prior)+s)/(prior*(K+n)); if(m<0.80)m=0.80; if(m>1.20)m=1.20
        printf "H|%s|%.2f|%.2f|%.2f|%s|%d\n",l,m,n,s,sc,bf[l]+0 } }' >"$_par_hist" 2>/dev/null ) & _p_hist=$!
  fi
  [ -z "${_ADV_PROF:-}" ] || _prof_mark history

  # Deny/exclude in ONE batch: _exclude_hits already folds the whole matcher into a single awk
  # pass when given all names at once (per-name calls re-scan the entry table each time — ~0.9s
  # on a 46-row pool). Every hit name becomes an X row; the scorer tests it against BOTH the
  # alias and the resolved id, which reproduces _model_excluded(alias) + _model_denied(resolved)
  # exactly — a hit on either name is an exclusion either way. The denylist glob check is tiny
  # and stays in-process. Everything is skipped when the lists are inactive — the fast path.
  if _exclude_active 2>/dev/null || [ -n "${OSRC_MODEL_DENYLIST:-}" ]; then
    local _id _xh="" _xn _pat
    local -a _narr=()
    while IFS= read -r _xn; do [ -n "$_xn" ] && _narr+=("$_xn"); done \
      < <(printf '%s\n' "$_pool" | awk -F'|' 'NF{print $2; print $1}')
    if _exclude_active 2>/dev/null && [ "${#_narr[@]}" -gt 0 ]; then
      _xh="$(_exclude_hits "${_narr[@]}" 2>/dev/null)"
      _excl_rows="$(printf '%s\n' "$_xh" | awk -F'\t' 'NF{print "X|"$1}')"
      [ -n "$_excl_rows" ] && _excl_rows="${_excl_rows}
"
    fi
    # D rows: denylist exact/*-glob on resolved (usually empty -> zero work).
    if [ -n "${OSRC_MODEL_DENYLIST:-}" ]; then
      while IFS= read -r _id; do
        [ -n "$_id" ] || continue
        local IFS=', ' _hf=0
        case "$-" in *f*) _hf=1 ;; esac
        set -f; set -- ${OSRC_MODEL_DENYLIST:-}
        [ "$_hf" = 0 ] && set +f
        for _pat in "$@"; do
          [ "$_id" = "$_pat" ] && { _deny_rows="${_deny_rows}D|${_id}
"; break; }
          case "$_pat" in *'*'*) case "$_id" in $_pat) _deny_rows="${_deny_rows}D|${_id}
"; break ;; esac ;; esac
        done
      done < <(printf '%s\n' "$_pool" | awk -F'|' 'NF{print $2}')
    fi
  fi
  [ -z "${_ADV_PROF:-}" ] || _prof_mark deny

  # Collect the backgrounded reads. `wait` is per-pid so unrelated jobs are never reaped.
  [ -n "$_p_lim" ] && wait "$_p_lim"
  [ -n "$_par_lim" ] && [ -f "$_par_lim" ] && _limits_once="$(cat "$_par_lim")"
  [ -n "$_p_hist" ] && wait "$_p_hist"
  [ -n "$_par_hist" ] && [ -f "$_par_hist" ] && _hist_rows="$(cat "$_par_hist")"
  rm -f "$_par_lim" "$_par_hist" 2>/dev/null
  [ "${OSRC_ADVISE_CONSERVE:-1}" != "0" ] && _adv_limits="$_limits_once"
  [ "${OSRC_LANE_LIMIT_GATE:-1}" != "0" ] && _gate_limits="$_limits_once"

  local _tok _models_rows=""
  for _tok in $_limits_once; do _lim_rows="${_lim_rows}T|${_tok%%=*}|${_tok#*=}
"; done
  # MC's own probe caches are the lane quota meters: agy /usage (gm) reports a
  # weekly "left%" that _session_limits never sees. 0% left parks the lane the
  # same way codexwk does, with its real renews_at as the reset.
  if declare -f _osrc_probe_cache >/dev/null && have jq; then
    _pj="$(_osrc_probe_cache agy 2>/dev/null)"
    if [ -n "$_pj" ]; then
      _al="$(jq -r '[.groups[]?.windows[]? | select(.kind=="week" and .left != null) | .left] | min // empty' <<<"$_pj" 2>/dev/null)"
      _ar="$(jq -r '[.groups[]?.windows[]? | select(.kind=="week" and .left != null) | .renews_at] | max // empty' <<<"$_pj" 2>/dev/null)"
      case "$_al" in ''|*[!0-9.]*) ;; *) _lim_rows="${_lim_rows}L2|gm|${_al}
" ;; esac
      if [ -n "$_ar" ] && [ "$_ar" -gt "$(date +%s)" ] 2>/dev/null; then
        _at="$(date -r "$_ar" '+%a %d %b %H:%M' 2>/dev/null || date -d "@$_ar" '+%a %d %b %H:%M' 2>/dev/null)"
        [ -n "$_at" ] && _lim_rows="${_lim_rows}T2|probe_gm|${_at}
"
      fi
    fi
  fi
  [ -n "${_p_res:-}" ] && wait "$_p_res" 2>/dev/null
  while IFS=$'\t' read -r _mw _mp _mr _ma; do
    if [ -n "$_mw" ] && [ "$_mr" != "-" ] && [ "$_mr" -gt "$(date +%s)" ] 2>/dev/null; then
      _mt="$(date -r "$_mr" '+%a %d %b %H:%M' 2>/dev/null || date -d "@$_mr" '+%a %d %b %H:%M' 2>/dev/null)"
      [ -n "$_mt" ] && _lim_rows="${_lim_rows}T2|${_mw}|${_mt}
"
    fi
  done < "$_par_res" 2>/dev/null
  rm -f "$_par_res"
  if [ -f "$OSRC_MODELS_JSON" ] && have jq; then
    _models_rows="$(jq -r '
      .data[] | ["M",.id,(.pricing.prompt//"0"),(.pricing.completion//"0")] | join("|")' "$OSRC_MODELS_JSON" 2>/dev/null)"
    _models_rows="${_models_rows:+${_models_rows}
}"
  fi

  _scored="$({
    printf '%s\n' "$_pool" | awk -F'|' 'NF{print "P|"$0}'
    printf '%s' "$_lane_rows"
    [ -f "$OSRC_BENCH_JSON" ] && have jq && jq -r --arg f "$field" '
      .data[] | ["B",.model_permaslug,(.[$f]//0),(.pricing.prompt//"0"),(.pricing.completion//"0")] | join("|")' "$OSRC_BENCH_JSON" 2>/dev/null
    printf '%s' "$_slug_rows"
    printf '%s' "$_models_rows"
    printf '%s' "$_hist_rows"
    printf '%s' "$_deny_rows$_excl_rows"
    printf '%s' "$_lim_rows"
  } | awk -F'|' -v OFS='|' \
      -v thr="$threshold" -v eff="$selection_effort" -v dif="$difficulty" -v cat="$category" \
      -v gate_on="$([ -n "$_gate_limits" ] && echo 1 || echo 0)" -v gate_thr="${OSRC_LANE_LIMIT_PCT:-90}" \
      -v stale_secs="${OSRC_LIMITS_STALE_SECS:-21600}" \
      -v cons_on="$([ -n "$_adv_limits" ] && echo 1 || echo 0)" -v cons_t="${OSRC_CONSERVE_THRESHOLD:-50}" \
      "$_OSRC_VW_AWK$_OSRC_SCORE_AWK")"

  # Demux the scored stream: results_p keeps the hidden plan column for the cohort pick;
  # results is the 9-col shape every downstream reader expects.
  local _line _n
  while IFS= read -r _line; do
    case "$_line" in
      R\|*) results_p="${results_p}${_line#R|}
" ;;
      B\|*) base_map="${base_map}${_line#B|}
" ;;
      N\|C\|*) _n="${_line#N|C|}"; conserve_notes="${conserve_notes:+$conserve_notes; }$_n" ;;
      W\|*) _w_rows="${_w_rows}${_line}
" ;;
      N\|L\|*) _n="${_line#N|L|}"
        _gln="${_n##*-> }"; _gln="${_gln% excluded}"
        case "$_gate_seen" in *"|${_gln}|"*) ;; *)
          _gate_seen="${_gate_seen}|${_gln}|"; _limit_notes="${_limit_notes:+$_limit_notes; }$_n"
          _gate_rows="${_gate_rows}${_n}
" ;; esac ;;
      C\|*) _n="${_line#C|}"; bench_count="${_n%%|*}"; total_count="${_n##*|}" ;;
      HR\|*) _hr_rows="${_hr_rows}${_line}
" ;;
      K\|*) _parked_rows="${_parked_rows}${_line}
" ;;
    esac
  done <<<"$_scored"
  results="$(printf '%s' "$results_p" | cut -d'|' -f1-9)"
  [ -z "${_ADV_PROF:-}" ] || _prof_mark score

  # VARIANT PREFERENCE pass (see _variant_weight): among capable rows that MEET the threshold, find each
  # family's lightest variant (per lane); every heavier sibling gets pref=1 = "a lighter sibling
  # qualifies", which keeps it out of capable_best contention below (it stays listed, labeled). Off at
  # effort=max or when the task requires the frontier — then the heavier rung is the point.
  local variant_pref=1
  { [ "$selection_effort" = "max" ] || [ "$frontier_needed" = "1" ] || [ "${OSRC_ADVISE_VARIANT_PREF:-1}" = "0" ]; } && variant_pref=0
  if [ "$variant_pref" = "1" ]; then
    results_p="$(printf '%s\n' "$results_p" | awk -F'|' -v eff="$selection_effort" \
      "$_OSRC_VW_AWK"'
      { r[++n]=$0; split($0,F,"|")
        if(F[8]=="1" && F[4]=="capable"){ f=_avf(F[2])"|"F[3]; w=_avw(F[2],eff)
          if(!(f in fm) || w+0<fm[f]+0) fm[f]=w }
        vw[n]=_avw(F[2],eff); ff[n]=_avf(F[2])"|"F[3]; mt[n]=F[8]; tr[n]=F[4] }
      END{ for(i=1;i<=n;i++){ p=0
          if(mt[i]=="1" && tr[i]=="capable" && vw[i]+0 > fm[ff[i]]+0) p=1
          split(r[i],F,"|"); F[9]=p
          printf "%s",F[1]; for(j=2;j<=10;j++) printf "|%s",F[j]; printf "\n" } }')"
    results="$(printf '%s' "$results_p" | cut -d'|' -f1-9)"
  fi
  [ -z "${_ADV_PROF:-}" ] || _prof_mark variant

  # ---- B2 live-source factor pass ------------------------------------------
  # Per candidate: quality from the best-covering source for this task class, REAL $/task
  # (bench-measured; else list-price x measured/median tokens), speed telemetry. rows.jsonl
  # is rebuilt by the detached refresher; absent/cold -> legacy ranking below, unchanged.
  local _fx="" have_factors=0 results2="" _share="${OSRC_ADVISE_QUALITY_SHARE:-0.85}"
  case "$difficulty" in light) _dshare="${OSRC_ADVISE_QUALITY_SHARE_LIGHT:-0.75}" ;;
                        hard)  _dshare="${OSRC_ADVISE_QUALITY_SHARE_HARD:-0.97}" ;;
                        *)     _dshare="$_share" ;; esac
  local f_q="" f_qsrc="" f_cost="" f_csrc="" f_tok="" f_tps="" f_lat="" f_secs=""
  # rec_* declared here (unconditionally, once per call): a `local rec_alias=""` below the
  # warm pick would silently wipe the chosen row — and did, leaking the pick's factor values
  # onto the cohort fallback's model. Declaring it inside the factors `if` would be just as
  # wrong: on cold caches the cohorts would inherit a stale global from a prior in-process call.
  local rec_alias="" rec_resolved="" rec_lane="" rec_tier="" rec_reason=""
  if [ "${OSRC_ADVISE_FACTORS:-1}" != "0" ] && [ -s "$OSRC_ADVISE_DIR/rows.jsonl" ] && have python3; then
    # Join on the id the LANE actually runs, not the table alias: fable->
    # claude-fable-5-2, opus->claude-opus-5-5 etc. come from the lane resolver,
    # never a hand list. Unresolvable keeps the original resolved id.
    local _fx_in="" _fr_map="" _smap="" _fa _fr _fl _frest _fkey _frid
    while IFS='|' read -r _fa _fr _fl _frest; do
      [ -n "$_fa" ] || continue
      _frid="$(_adv_lane_id "$_fl" "$_fa" "$_fr")"
      _fx_in="${_fx_in}${_fa}|${_frid}|${_fl}|${_frest}
"
      _fr_map="${_fr_map}K2|${_frid}|${_fa}
"
      case "$_fr" in
        claude-fable-*|claude-opus-*|claude-sonnet-*|claude-haiku-*)
          _ff="${_fr#claude-}"; _sf="claude-${_ff%%-*}"
          case "$_smap" in *"|${_sf}:"*) ;; *)
            _sn="$(grep -o "\"family\":\"${_sf}-[0-9][0-9-]*\"" \
                   "$OSRC_ADVISE_DIR/rows.jsonl" 2>/dev/null | cut -d'"' -f4 \
                   | sort -u | _vsort 2>/dev/null | tail -1)"
            _smap="${_smap}|${_sf}:${_sn}" ;; esac
          _sn="${_smap#*|${_sf}:}"; _sn="${_sn%%|*}"
          [ -n "$_sn" ] && [ "$_sn" != "$_fr" ] && _parked_rows="${_parked_rows}S2|${_fr}|${_sn}
" ;; esac
    done <<<"$results"
    _fx="$(printf '%s' "$_fx_in" \
           | python3 -I "$_OSRC_LIB_DIR/advise_parse.py" factors --dir "$OSRC_ADVISE_DIR" \
                      --category "$category" --effort "$selection_effort" 2>/dev/null)"
    [ -n "$_fx" ] && have_factors=1
  fi
  if [ "$have_factors" = 1 ]; then
    # results2 = results + |q|qsrc|cost|csrc|tokens|tps|lat|secs (cols 10-17), meets recomputed:
    # rows with live quality q must clear max(abs threshold, share x best-runnable q); the
    # score/raw ratio folds history+conserve onto q so a failing lane still drops out.
    results2="$({
      printf '%s\n' "$base_map" | awk -F'|' 'NF{print "B|"$0}'
      printf '%s' "$_fr_map"
      printf '%s\n' "$_fx"      | awk -F'|' 'NF{print "F|"$0}'

      printf '%s' "$_models_rows"
      printf '%s' "$_hist_rows"
      printf '%s\n' "$results"  | awk 'NF'
    } | awk -F'|' -v OFS='|' -v th="$threshold" -v share="$_dshare" '
      $1=="B" { raw[$2]=$3; next }
      $1=="M" { mpin[$2]=$3; mpout[$2]=$4; next }
      $1=="H" { hbf[$2]=$7+0; next }
      $1=="K2"{ nr[$2]=nr[$2]" "$3; next }
      $1=="F" { fe=""; fb=$2
                if (!($2 in nr) && match(fb, /@[^@]+$/)) { fe=substr(fb,RSTART+1); fb=substr(fb,1,RSTART-1) }
                nk=split(nr[fb],KS," "); if(nk==0){ nk=1; KS[1]=fb }
                for(ki=1;ki<=nk;ki++){ k=KS[ki]
                  if(fe!=""){ k=k"@"fe; effs[KS[ki]]=effs[KS[ki]]" "fe }
                  q[k]=$3; qs[k]=$4; co[k]=$5; cs[k]=$6; tk[k]=$7; tp[k]=$8; lt[k]=$9; sc[k]=$10 }
                src=$4; if ($3+0 > bq[src]+0) bq[src]=$3+0; next }
      NF {
        o2=$2; nv=split(effs[o2],EV," ")
        if(nv==0) emitrow(o2,o2)
        else for(vi=1;vi<=nv;vi++) emitrow(o2,o2"@"EV[vi])
      }
      function emitrow(base,key,   qq,eqq,bar,coc,csc,rk,pi,po,b2){
        qq=q[key]; eqq=qq; bar=""
        if (qq!="" && raw[base]+0>0) eqq = qq*(($5+0)/(raw[base]+0))
        # Bar is RELATIVE to the best runnable score on the same source —
        # absolute index thresholds were calibrated for another scale and
        # wrongly dropped Opus 5.5 High (54.5 cb) and Neon Medium (57.7 cb).
        if (qq!="") { bar=share*bq[qs[key]]; $8 = (eqq+0 >= bar) ? 1 : 0 }
        # No measured $/task -> estimate from models.json list price x the token
        # estimate the factor pass already emitted (measured or class median).
        coc=co[key]; csc=cs[key]
        if (coc=="" && tk[key]+0>0) {
          rk=base; pi=""; po=""
          if (rk in mpin) { pi=mpin[rk]; po=mpout[rk] }
          else { b2=rk; sub(/:.*/,"",b2); if (b2 in mpin) { pi=mpin[b2]; po=mpout[b2] } }
          if (pi!="") { coc = tk[key]*(0.75*pi+0.25*(po+0)); csc = "est:list-price x tok"; coc = sprintf("%.4f", coc) }
        }
        $2=key
        print $0, qq, qs[key], coc, csc, tk[key], tp[key], lt[key], sc[key], hbf[$3]+0, bar
      }')"
    # Warm pick: cheapest qualifier by REAL cost (speed tiebreak); demoted variants never
    # qualify; frontier-required tasks stay frontier-tier. No cost -> never wins on cost.
    local _pick
    _pick="$(printf '%s\n' "$results2" | awk -F'|' -v fn="$frontier_needed" '
      NF>=18 && $8=="1" && $9!="1" && $12!="" && $18<3 && (fn!="1" || $4=="frontier") {
        c=$12+0; t=$15+0; s=$17+0
        if (!n || c<bc || (c==bc && t>bt) || (c==bc && t==bt && s<bs))
          { n++; bc=c; bt=t; bs=s; keep=$0 }
        if ($11!="") {
          if (!ns || c<bcs || (c==bcs && t>bts) || (c==bcs && t==bts && s<bss))
            { ns++; bcs=c; bts=t; bss=s; keeps=$0 }
        }
      } END { if (ns) print keeps; else if (n) print keep }')"
    if [ -n "$_pick" ]; then
      rec_alias="$(printf '%s' "$_pick" | cut -d'|' -f1)"
      rec_resolved="$(printf '%s' "$_pick" | cut -d'|' -f2)"
      rec_lane="$(printf '%s' "$_pick" | cut -d'|' -f3)"
      rec_tier="$(printf '%s' "$_pick" | cut -d'|' -f4)"
      f_q="$(printf '%s' "$_pick" | cut -d'|' -f10)";   f_qsrc="$(printf '%s' "$_pick" | cut -d'|' -f11)"
      f_cost="$(printf '%s' "$_pick" | cut -d'|' -f12)"; f_csrc="$(printf '%s' "$_pick" | cut -d'|' -f13)"
      f_tok="$(printf '%s' "$_pick" | cut -d'|' -f14)"
      f_tps="$(printf '%s' "$_pick" | cut -d'|' -f15)"; f_lat="$(printf '%s' "$_pick" | cut -d'|' -f16)"
      f_secs="$(printf '%s' "$_pick" | cut -d'|' -f17)"
      rec_reason="cheapest qualifying model on real cost per task (effort $selection_effort)"
      [ -z "$f_qsrc" ] && rec_reason="cheapest runnable fallback (no live-source score; tier-proxy only)"
    fi
    # Fold updated meets back into the 9-col shape every downstream reader expects.
    results="$(printf '%s\n' "$results2" | cut -d'|' -f1-9)"
  fi

  if [ -n "${_ADV_TABLE:-}" ]; then
    printf 'ADV-TABLE category=%s bar=%sx-best-on-source\n' "$category" "$_dshare" >&2
    printf 'resolved|quality|qsrc|cost|csrc|tps|lat_ms|lane|left%%|meets|demoted|lane_fails_24h|note\n' >&2
    { printf '%s' "$_hr_rows"; printf '%s' "$_parked_rows";
      [ -n "$results2" ] && printf '%s\n' "$results2"; } | awk -F'|' '
      $1=="HR"{ hr[$2]=$3; next }
      $1=="K"{ note="at/over limit"
        if($6!=""){ note="blocked until " $6 }
        printf "%s|||||||%s|%s||PARKED|%s\n",$3,$4,(100-$5),note; next }
      $1=="S2"{ stale[$2]=$3; next }
      NF>=19 && $2!=""{ if(seen[$2"|"$3]++)next
        rb=$2; sub(/@.*/,"",rb); note=(stale[rb]!="" ? "stale-id(lane-current:"stale[rb]") " : "")
        if($10=="")note=note"unscored:no live-source row"
        else if($8!="1")note=note"below bar "$19
        else if($12=="")note=note"no cost (cannot win)"
        else if($18+0>=3)note=note"lane failing(24h)"
        printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n",$2,$10,$11,$12,$13,$15,$16,$3,(hr[$3]==""?"?":100-hr[$3]),$8,$9,$18,note }' >&2
  fi

  [ -z "${_ADV_PROF:-}" ] || _prof_mark factors
  # Pick recommendation in two cohorts to avoid subscription lanes dominating value ratio.
  # Subscription lanes (cx/cc/dv/gm): ranked by score (cost is plan-limited, not comparable to per-token).
  # Paid lanes (or/codex): ranked by value ratio (score / cost_per_m).
  # Prefer subscription if it meets threshold; else best paid by value ratio; else highest score overall.
  local capable_best_alias="" capable_best_resolved="" capable_best_lane="" capable_best_tier="" capable_best_vr=""
  local frontier_best_alias="" frontier_best_resolved="" frontier_best_lane="" frontier_best_tier="" frontier_best_score=""
  local sub_best_alias="" sub_best_resolved="" sub_best_lane="" sub_best_score=""
  local paid_best_alias="" paid_best_resolved="" paid_best_lane="" paid_best_vr=""
  local any_best_alias="" any_best_resolved="" any_best_lane="" any_best_score=""
  # One awk over the post-factor results picks all five cohort bests — the same strict->
  # first-wins rules as the original loop, with the variant-weight tiebreak on capable ties.
  # Plan-limited membership comes from the lane map, not a per-row function call.
  local _coh
  _coh="$({
    printf '%s' "$_lane_rows"
    printf '%s\n' "$results" | awk 'NF'
  } | awk -F'|' -v eff="$selection_effort" "$_OSRC_VW_AWK"'
    $1=="L"{ nl++; ln[nl]=$2; la[nl]=$3; ld[nl]=($4==""?"-":$4); ldb[nl]=$5
             lplan[$2]=$7; next }
    NF>=9{ a=$1; s=$5+0; v=$7+0; cl=laneof($3)
      if(s>as){ as=s; av=$0 }
      if($8!="1") next
      if($4=="capable" && $9+0!=1){ w=_avw($2,eff)
        if(!cn || v>cv || (v==cv && w+0<cw+0)){ cn=1; cv=v; cw=w; cb=$0 } }
      if($4=="frontier" && s>fs){ fs=s; fb=$0 }
      if(lplan[cl]=="yes" || $3=="dv"){ if(s>ss){ ss=s; sb=$0 } }
      else if(!pn || v>pv){ pn=1; pv=v; pb=$0 } }
    END{ if(av!=""){split(av,F,"|"); print "ANY|"F[1]"|"F[2]"|"F[3]"|"F[4]"|"F[5]}
         if(cb!=""){split(cb,F,"|"); print "CAP|"F[1]"|"F[2]"|"F[3]"|"F[4]"|"F[7]}
         if(fb!=""){split(fb,F,"|"); print "FRO|"F[1]"|"F[2]"|"F[3]"|"F[4]"|"F[5]}
         if(sb!=""){split(sb,F,"|"); print "SUB|"F[1]"|"F[2]"|"F[3]"|"F[4]"|"F[5]}
         if(pb!=""){split(pb,F,"|"); print "PAID|"F[1]"|"F[2]"|"F[3]"|"F[4]"|"F[7]} }')"
  local _ck _cv _cr _cl2 _ct _cx
  while IFS='|' read -r _ck _ca _cr _cl2 _ct _cx; do
    [ -n "$_ck" ] || continue
    case "$_ck" in
      ANY)  any_best_alias="$_ca"; any_best_resolved="$_cr"; any_best_lane="$_cl2"; any_best_score="$_cx" ;;
      CAP)  capable_best_alias="$_ca"; capable_best_resolved="$_cr"; capable_best_lane="$_cl2"; capable_best_tier="$_ct"; capable_best_vr="$_cx" ;;
      FRO)  frontier_best_alias="$_ca"; frontier_best_resolved="$_cr"; frontier_best_lane="$_cl2"; frontier_best_tier="$_ct"; frontier_best_score="$_cx" ;;
      SUB)  sub_best_alias="$_ca"; sub_best_resolved="$_cr"; sub_best_lane="$_cl2"; sub_best_score="$_cx" ;;
      PAID) paid_best_alias="$_ca"; paid_best_resolved="$_cr"; paid_best_lane="$_cl2"; paid_best_vr="$_cx" ;;
    esac
  done <<<"$_coh"

  [ -z "${_ADV_PROF:-}" ] || _prof_mark cohort
  # Prefer capable-tier value unless the task explicitly needs the frontier.
  if [ -n "$rec_alias" ]; then
    : # B2 warm-path pick already chosen above; cohorts stay the cold-cache fallback.
  elif [ "$frontier_needed" = "1" ] && [ -n "$frontier_best_alias" ]; then
    rec_alias="$frontier_best_alias"; rec_resolved="$frontier_best_resolved"; rec_lane="$frontier_best_lane"; rec_tier="$frontier_best_tier"
    rec_reason="frontier required (score $frontier_best_score, ${category} threshold $threshold, effort $selection_effort)"
  elif [ -n "$capable_best_alias" ]; then
    rec_alias="$capable_best_alias"; rec_resolved="$capable_best_resolved"; rec_lane="$capable_best_lane"; rec_tier="$capable_best_tier"
    rec_reason="best capable-tier value (ratio $capable_best_vr, meets ${category} threshold $threshold, effort $selection_effort)"
  elif [ -n "$sub_best_alias" ]; then
    rec_alias="$sub_best_alias"; rec_resolved="$sub_best_resolved"; rec_lane="$sub_best_lane"
    rec_reason="best subscription model (score $sub_best_score, meets ${category} threshold $threshold, plan-limited cost)"
  elif [ -n "$paid_best_alias" ]; then
    rec_alias="$paid_best_alias"; rec_resolved="$paid_best_resolved"; rec_lane="$paid_best_lane"
    rec_reason="best value (ratio $paid_best_vr, meets ${category} threshold $threshold)"
  else
    rec_alias="$any_best_alias"; rec_resolved="$any_best_resolved"; rec_lane="$any_best_lane"
    rec_reason="highest score (score $any_best_score, no model met ${category} threshold $threshold, consider escalating)"
  fi
  # rec_effort is the effort the PICKED row actually carries (resolved may be
  # opus@high), never the requested selection_effort — the reason must not contradict the pick.
  local rec_effort="${rec_resolved##*@}"
  [ "$rec_effort" = "$rec_resolved" ] && rec_effort="$selection_effort"
  rec_reason="${rec_reason/effort $selection_effort/effort $rec_effort}"
  if [ -z "$rec_tier" ]; then
    local _rec_row; _rec_row="$(resolve_model_row "$rec_alias")"; rec_tier="${_rec_row##*|}"
  fi

  # Lane routing: the quality logic above chose the MODEL; keep it, but run it on its cheapest
  # AVAILABLE lane. The same model often lives on a per-token cash lane (OpenRouter) AND a plan lane
  # the user already pays for (a free Devin tier, a Warp/Claude/Codex sub), whose marginal cost is
  # ~0 -- so a sunk subscription is spent before real cash. Only the lane moves; the winning model is
  # never downgraded. A cost-unknown (BYOK) lane never wins on cost. OSRC_ADVISE_ROUTER=0 keeps the
  # pre-router lane.
  local rec_cost_basis=""
  if [ "${OSRC_ADVISE_ROUTER:-1}" != "0" ] && [ -n "$rec_resolved" ]; then
    local _rlanes _l _lc _lcost _lbasis _marg _marg_map _dvf _wpf _t _ml _mc _mb
    # Catalog membership + marginal cost for the rec lane set in ONE pass — same canon() and
    # marginal_class rules the per-call _model_lanes/_lane_marginal_cost use, fed by the maps
    # already in memory (the per-call versions stay the reference impl for other callers).
    [ -n "$_p_cat" ] && wait "$_p_cat"
    local _cat_rows=""; [ -f "$_par_cat" ] && _cat_rows="$(cat "$_par_cat")"
    rm -f "$_par_cat" 2>/dev/null
    _marg="$({
      printf '%s' "$_lane_rows"
      printf '%s' "$_w_rows"
      printf '%s' "$_models_rows"
      printf '%s\n' "$_cat_rows"
      for _l in $rec_lane $OSRC_LANE_REGISTRY or dv warp local; do printf 'Q|%s\n' "$_l"; done
    } | awk -F'|' -v rid="$rec_resolved" "$_OSRC_VW_AWK$_OSRC_MARG_AWK")"
    [ -n "${_ADV_DEBUG:-}" ] && printf 'MARG>>>\n%s\n<<<\n' "$_marg" >&2
    local _mline
    _rlanes=""; _marg_map=""
    while IFS= read -r _mline; do
      case "$_mline" in
        LANES\|*) _rlanes="${_mline#LANES|}" ;;
        M\|*) _marg_map="${_marg_map}${_mline}
" ;;
      esac
    done <<<"$_marg"
    # Seed with the current pick's own marginal cost so a tie keeps the originally-chosen lane.
    _lc=""
    while IFS='|' read -r _t _ml _lc; do
      [ "$_ml" = "$rec_lane" ] && break
    done <<<"$_marg_map"
    [ "$_ml" = "$rec_lane" ] || _lc=""
    _lcost="${_lc%% *}"; rec_cost_basis="${_lc##* }"
    case "$_lcost" in ''|-1|*[!0-9.]*) _lcost="" ; rec_cost_basis="${_lc##* }" ;; esac
    local _bestcost="$_lcost"
    for _l in $_rlanes; do
      [ "$_l" = "$rec_lane" ] && continue
      _lc=""
      while IFS='|' read -r _t _ml _lc; do
        [ "$_ml" = "$_l" ] && break
      done <<<"$_marg_map"
      [ "$_ml" = "$_l" ] || _lc=""
      _lcost="${_lc%% *}"; _lbasis="${_lc##* }"
      case "$_lcost" in ''|-1|*[!0-9.]*) continue ;; esac   # unknown/BYOK never wins on cost
      if [ -z "$_bestcost" ] || awk -v a="$_lcost" -v b="$_bestcost" 'BEGIN{exit (a+0 < b+0)?0:1}'; then
        _bestcost="$_lcost"; rec_lane="$_l"; rec_cost_basis="$_lbasis"
      fi
    done
  fi

  [ -z "${_ADV_PROF:-}" ] || _prof_mark router
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
    die "advise: every candidate lane is at/over OSRC_LANE_LIMIT_PCT (${_limit_notes}). Wait for a window reset, or set OSRC_LANE_LIMIT_GATE=0."
  fi
  [ -n "$rec_alias" ] || die "advise: no models found in the alias table to score"

  # Recompute the recommended model's history for the human/json explanation (raw + effective).
  # Pulled from the same _hist_rows map the scorer folded — one fold, no per-candidate re-query.
  local _rh rec_mult rec_neff rec_peff rec_scope _rhrest _hl _rest
  _rh=""
  while IFS='|' read -r _htag _hl _rest; do
    [ "$_hl" = "$rec_lane" ] && { _rh="$_rest"; break; }
  done <<<"${_hist_rows:-}"
  [ -n "$_rh" ] || _rh="1.00|0.00|0.00|none"
  rec_mult="${_rh%%|*}"; _rhrest="${_rh#*|}"; rec_neff="${_rhrest%%|*}"; _rhrest="${_rhrest#*|}"; rec_peff="${_rhrest%%|*}"; rec_scope="${_rh##*|}"
  case "$rec_mult" in ''|*[!0-9.]*) rec_mult="1.00" ;; esac
  local rec_pct; rec_pct="$(awk -v m="$rec_mult" 'BEGIN{printf "%+.0f", (m-1)*100}')"
  # Ranked fallback shortlist: the SAME preference order the recommendation uses, as an ordered list so
  # a caller can retry the next candidate when the top pick hits a transport failure (rate limit / 5xx /
  # timeout). Rank groups mirror the picker exactly: capable value leads normally, frontier leads when
  # required, and everything below threshold follows by score, so shortlist[0] IS
  # the recommendation. Ordering only: this ranks candidates, it never asserts any of them will succeed.
  local _sl _sl_sorted
  _sl="$(printf '%s\n' "$results" | awk -F'|' -v eff="$selection_effort" -v fn="$frontier_needed" \
    "$_OSRC_VW_AWK"'
    NF>=9{ a=$1; g=2; p=$5+0
      if(fn=="1"){ if($8=="1" && $4=="frontier"){g=0;p=$5+0}
        else if($8=="1" && $4=="capable"){g=1;p=$7+0} }
      else { if($8=="1" && $4=="capable"){g=0;p=$7+0}
        else if($8=="1"){g=1;p=$5+0} }
      if($9+0==1 && g==0){ g=1; p=$5+0 }
      printf "%d|%s|%s|%s|%s|%s|%s|%s|%s|%d\n", g, p, $1, $2, $3, $8, $5, $7, $9, _avw($2,eff) }')"
  # group asc, then the group-appropriate primary desc. -s (stable) so ties keep input (table) order,
  # matching the picker's first-wins on equal score/ratio — this is what makes shortlist[0] == the pick.
  _sl_sorted="$(printf '%s' "$_sl" | grep -v '^$' | sort -s -t'|' -k1,1n -k2,2rn -k10,10n)"

  # group asc, then the group-appropriate primary desc. -s (stable) so ties keep input (table) order,
  # matching the picker's first-wins on equal score/ratio — this is what makes shortlist[0] == the pick.
  local _sl_sorted; _sl_sorted="$(printf '%s' "$_sl" | grep -v '^$' | sort -s -t'|' -k1,1n -k2,2rn -k10,10n)"
  local shortlist_json="[]"
  if have jq; then
    shortlist_json="$(printf '%s\n' "$_sl_sorted" \
      | jq -R 'select(length>0)|split("|")|{alias:.[2],model:.[3],lane:.[4],meets:(.[5]=="1"),score:(.[6]|tonumber?),value_ratio:(.[7]|tonumber?),lighter_sibling_preferred:(.[8]=="1")}' 2>/dev/null \
      | jq -s '.' 2>/dev/null)"
    [ -n "$shortlist_json" ] || shortlist_json="[]"
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
      --arg fq "$f_q" --arg fqsrc "$f_qsrc" --arg fcost "$f_cost" --arg fcsrc "$f_csrc" \
      --arg ftps "$f_tps" --arg fsecs "$f_secs" --arg srcs "$(_advise_src_status 2>/dev/null)" \
      '{task:$task, category:$category, difficulty:$difficulty, effort:$effort, score_field:$field, threshold:$threshold,
        recommendation:{alias:$rec_alias, model:$rec_resolved, lane:$rec_lane, cost_basis:(if $rec_cost_basis=="" then null else $rec_cost_basis end), tier:$rec_tier, reason:$rec_reason},
        factors:(if $fq=="" and $fcost=="" then null else {quality:(if $fq=="" then null else ($fq|tonumber?) end), quality_source:(if $fqsrc=="" then null else $fqsrc end),
                 cost_per_task:(if $fcost=="" then null else ($fcost|tonumber?) end), cost_source:(if $fcsrc=="" then null else $fcsrc end),
                 tok_per_s_p50:(if $ftps=="" then null else ($ftps|tonumber?) end), task_secs:(if $fsecs=="" then null else ($fsecs|tonumber?) end)} end),
        sources:(if $srcs=="" then null else $srcs end),
        shortlist:$shortlist,
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
    if [ -n "$f_qsrc" ]; then
      echo "   bar:   >= ${_dshare}x best runnable score on the same source (source: $f_qsrc)"
    else
      echo "   bar:   >= ${_dshare}x best runnable score on the same source (score field: $field)"
    fi
    echo "   effort tip: start at this level, re-run the same task one rung lower; if quality holds, keep the cheaper rung (medium often matches high at lower cost)."
    if [ "$has_bench" = "1" ]; then
      echo "   benchmark data: live (OpenRouter, $(jq -r '.meta.as_of // "?"' "$OSRC_BENCH_JSON" 2>/dev/null), $bench_count/$total_count models)"
    elif [ "$has_bench" = "2" ]; then
      echo "   benchmark data: partial ($bench_count/$total_count candidates scored from live sources; unscored shown as 'unscored', refresh: $0 advise --refresh \"$task\")"
    else
      echo "   benchmark data: none (no live source scores, refresh: $0 advise --refresh \"$task\")"
    fi
    if [ -n "$_bstale" ]; then
      local _bd="${_bstale%%$'\t'*}" _ba="${_bstale#*$'\t'}" _bage
      if [ "$_bd" = "unknown" ]; then _bage="an unknown age"; else _bage="$_bd days old"; fi
      echo "   benchmark cache is $_bage (as of $_ba); refresh: $0 advise --refresh \"$task\""
    fi
    [ -n "$conserve_notes" ] && echo "   conservation: $conserve_notes (limits-left folded into the score; disable with OSRC_ADVISE_CONSERVE=0)"
    if [ -n "$_gate_rows" ]; then
      local _gate_txt="" _gate_phrs="" _g _gbw _gu _glane _gres _gph _kt _ka _kr _kl _ku _kres
      while IFS= read -r _g; do
        [ -n "$_g" ] || continue
        _gbw="${_g%%=*}"; _gu="${_g#*=}"; _gu="${_gu%% *}"
        _glane="${_g##*-> }"; _glane="${_glane% excluded}"
        _gres=""
        while IFS='|' read -r _kt _ka _kr _kl _ku _kres; do
          [ "$_kt" = "K" ] && [ "$_kl" = "$_glane" ] && { _gres="$_kres"; break; }
        done <<<"$_parked_rows"
        case "$_gbw" in
          probe_gm) _gph="Antigravity quota used up" ;;
          codexwk)  _gph="Codex weekly quota at ${_gu}%" ;;
          codex5h)  _gph="Codex 5-hour quota at ${_gu}%" ;;
          claude5h) _gph="Claude 5-hour quota at ${_gu}%" ;;
          claude7d) _gph="Claude 7-day quota at ${_gu}%" ;;
          *)        _gph="${_gbw} at ${_gu}%" ;;
        esac
        _gate_txt="${_gate_txt:+$_gate_txt · }${_glane} parked — ${_gph}${_gres:+, back $_gres}"
        _gate_phrs="${_gate_phrs}${_glane}|${_gph}${_gres:+, back $_gres}
"
      done <<<"$_gate_rows"
      echo "   limit-gate: $_gate_txt (OSRC_LANE_LIMIT_GATE=0 disables)"
    fi
    echo
    echo "--- recommendation ---"
    echo "   model: $rec_alias ($rec_resolved)"
    local _rlft=""
    while IFS='|' read -r _ht _hl _hu; do
      [ "$_ht" = "HR" ] && [ "$_hl" = "$rec_lane" ] && _rlft="$((100 - ${_hu%%.*}))" && break
    done <<<"$_hr_rows"
    case "$rec_cost_basis" in
      plan|free) echo "   lane:  $rec_lane (${rec_cost_basis}${_rlft:+, left% $_rlft})" ;;
      *)         echo "   lane:  $rec_lane${rec_cost_basis:+ (cost: $rec_cost_basis)}" ;;
    esac
    echo "   why:   $rec_reason"
    if [ -n "$f_q" ]; then
      local _bq _shp
      _bq="$(printf '%s\n' "${results2:-}" | awk -F'|' 'NF>=17 && $10!=""{if($10+0>m)m=$10+0}END{printf "%.1f", m}')"
      _shp="$(awk -v q="$f_q" -v b="$_bq" 'BEGIN{if(b>0)printf "%.0f",100*q/b; else print "?"}')"
      echo "   quality: $f_q ($f_qsrc) — ${_shp}% of best runnable ($_bq); gate: >= ${_dshare}x best-on-source"
    fi
    [ -n "$f_cost" ] && echo "   cost:    \$$(awk -v c="$f_cost" 'BEGIN{printf "%.2f",c}')/task ($f_csrc)"
    local _runner _r2 _r3 _rc _rs
    _runner="$(printf '%s\n' "$results2" | awk -F'|' -v win="$rec_resolved" -v fn="$frontier_needed" '
      NF>=18 && $8=="1" && $9!="1" && $12!="" && $18<3 && $2!=win && $11!="" && (fn!="1" || $4=="frontier") {
        c=$12+0; if (!n || c<bc) { n++; bc=c; keep=$0 }
      } END { if (n) print keep }')"
    if [ -n "$_runner" ]; then
      _r2="$(cut -d'|' -f2 <<<"$_runner")"; _r3="$(cut -d'|' -f3 <<<"$_runner")"
      _rc="$(cut -d'|' -f12 <<<"$_runner")"; _rs="$(cut -d'|' -f13 <<<"$_runner")"
      echo "   runner-up: $_r2 on $_r3 — \$$(awk -v c="$_rc" 'BEGIN{printf "%.2f",c}')/task ($_rs)"
    fi
    if [ -n "$f_tps" ] || [ -n "$f_secs" ]; then
      echo "   speed:   ${f_tps:-?} tok/s p50 (OR 30m telemetry${f_lat:+, lat ${f_lat}ms})${f_secs:+ · ~$(awk -v s="$f_secs" 'BEGIN{printf "%.0f",s}')s/task (tbench)}"
    fi
    [ -d "$OSRC_ADVISE_DIR" ] && echo "   sources: $(_advise_src_status)"
    # Show the local-history adjustment when there is any (else stay silent — pure benchmark pick).
    if [ "$rec_scope" != "none" ] && awk -v n="$rec_neff" 'BEGIN{exit (n+0>0)?0:1}'; then
      echo "   local: ${rec_pct}% from ${rec_neff} effective runs (${rec_scope}: this ${category})"
    fi
    echo
    if [ "$legacy_out" != 1 ] && [ -n "$results2" ]; then
      echo "--- candidates (factor table; 'unscored' = no live-source row) ---"
      printf '   %-24s %-24s %-30s %-4s %-4s %s\n' "model@effort" "quality" "cost/task" "lane" "left" "verdict"
      { printf '%s' "$_gate_phrs" | awk -F'|' 'NF{print "G|"$0}'
        printf '%s' "$_hr_rows"
        printf '%s' "$_parked_rows"
        printf '%s\n' "$results2"
      } | awk -F'|' -v win="$rec_resolved|$rec_lane" '
        $1=="G"{ gph[$2]=$3; next }
        $1=="HR"{ hr[$2]=$3; next }
        $1=="S2"{ stale[$2]=$3; next }
        $1=="K"{ if(seen["PARK"$3"|"$4]++)next
          printf "2|   %-24s %-24s %-30s %-4s %-4s parked%s\n",$3,"-","-",$4,(100-$5)"%",(gph[$4]!=""?": "gph[$4]:""); next }
        NF>=19 && $2!="" { if(seen[$2"|"$3]++)next
          rb=$2; sub(/@.*/,"",rb); v=(stale[rb]!="" ? "stale-id(lane-current:"stale[rb]") " : "")
          sk="1"$2
          if($10=="")v=v"unscored: no live-source row"
          else if($8!="1")v=v"below bar "$19
          else if($12=="")v=v"no cost"
          else if($18+0>=3)v=v"lane failing (24h)"
          else { v=v"qualifies"; sk="0"sprintf("%012.4f",$12) }
          pk=($2"|"$3==win)?">>":"  "
          if(pk==">>"){ v="pick"; sk="00"sprintf("%012.4f",$12+0) }
          lft=(hr[$3]==""?"?":(100-hr[$3])"%")
          printf "%s|%s %-24s %-24s %-30s %-4s %-4s %s\n",sk,pk,$2,($10==""?"unscored":$10" ("$11")"),($12==""?"-":("$"sprintf("%.2f",$12)" ("$13")")),$3,lft,v }' \
      | sort -t'|' -k1,1 | cut -d'|' -f2-
    else
      echo "--- all candidates (legacy scorer: value ratio, >> = recommended) ---"
      printf '%s\n' "$results" | sort -t'|' -k7 -rn | while IFS='|' read -r alias resolved lane tier score cost vr meets _pref; do
        [ -n "$alias" ] || continue
        local mark="  " verdict
        [ "$alias" = "$rec_alias" ] && mark=">>"
        if [ "$meets" != "1" ]; then verdict='below threshold'
        elif [ "${_pref:-0}" = "1" ]; then verdict='OK (lighter sibling preferred)'
        else verdict=OK; fi
        printf '%s %-16s %-28s lane=%-3s score=%-5s $/M=%-14s ratio=%-7s %s\n' \
          "$mark" "$alias" "$resolved" "$lane" "$score" "$cost" "$vr" "$verdict"
      done
    fi
    echo
    _prof_dump
  echo "Run with:  $0 run -m $rec_alias --effort $rec_effort \"$task\""
    echo "Override:  $0 run -m <any-model> --effort $rec_effort \"$task\"   (you know better, pick your own)"
  fi
}
