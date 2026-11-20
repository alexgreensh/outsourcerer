# lib/advise-fetch.sh — live-source refreshers for `advise` (B2).
# One refresher per source; each writes a raw cache + a `<name>.meta` key=value file under
# $OSRC_ADVISE_DIR with a TTL. The worker fetches all sources in PARALLEL, then rebuilds
# rows.jsonl via lib/advise_parse.py. The pick path never fetches: cmd_advise fires the
# worker DETACHED when a source is past TTL, and only after the feature is bootstrapped
# (the advise dir already exists), so a fresh install never self-fires network.
#   OSRC_ADVISE_NET=0            master offline switch (tests): skips every fetch, parse still runs
#   OSRC_ADVISE_AUTO_REFRESH=0   never fire the detached refresh from the pick path
#   OSRC_ADVISE_SOURCES="..."    space-separated source allowlist (default: all four)

_OSRC_LIB_DIR="${_OSRC_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"
OSRC_ADVISE_DIR="${OSRC_ADVISE_DIR:-$OSRC_HOME/advise}"
OSRC_ADVISE_TTL_CURSORBENCH="${OSRC_ADVISE_TTL_CURSORBENCH:-259200}"  # 72h: page updates ~monthly
OSRC_ADVISE_TTL_TBENCH="${OSRC_ADVISE_TTL_TBENCH:-86400}"             # 24h: rows roll daily
OSRC_ADVISE_TTL_ORBENCH="${OSRC_ADVISE_TTL_ORBENCH:-86400}"           # 24h: as_of moves daily
OSRC_ADVISE_TTL_ENDPOINTS="${OSRC_ADVISE_TTL_ENDPOINTS:-21600}"       # 6h: 30-min telemetry
OSRC_ADVISE_EP_MAX="${OSRC_ADVISE_EP_MAX:-40}"                        # bound the endpoint fan-out

_advise_src_enabled() {  # <source-name> -> rc0 when enabled
  case " ${OSRC_ADVISE_SOURCES:-cursorbench tbench orbench endpoints} " in
    *" $1 "*) return 0 ;;
    *)        return 1 ;;
  esac
}

# _advise_meta_read <source> <key> -> value or empty. Meta files are key=value, written atomically.
_advise_meta_read() {
  [ -f "$OSRC_ADVISE_DIR/$1.meta" ] || return 1
  awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$OSRC_ADVISE_DIR/$1.meta" 2>/dev/null
}

# _advise_src_status -> "cursorbench 2d ok | tbench 6h ok | orbench 1d stale | endpoints 3h fetch-failed"
# One compact line for the advise output; age in d/h/m, stale when past TTL or not ok.
_advise_src_status() {
  local s name fetched age ttl fmt="" now
  now="$(date +%s)"
  for s in cursorbench tbench orbench endpoints; do
    name="$OSRC_ADVISE_DIR/$s"
    [ "$s" = orbench ] && name="$OSRC_ADVISE_DIR/orbench"
    if [ ! -f "$name.meta" ]; then
      fmt="$fmt $s:absent"; continue
    fi
    fetched="$(_advise_meta_read "$s" fetched_at)"
    case "$s" in
      cursorbench) ttl=$OSRC_ADVISE_TTL_CURSORBENCH ;;
      tbench)      ttl=$OSRC_ADVISE_TTL_TBENCH ;;
      orbench)     ttl=$OSRC_ADVISE_TTL_ORBENCH ;;
      endpoints)   ttl=$OSRC_ADVISE_TTL_ENDPOINTS ;;
    esac
    case "$fetched" in ''|*[!0-9]*) age="" ;; *) age=$(( now - fetched )) ;; esac
    local st; st="$(_advise_meta_read "$s" status)"; st="${st:-unknown}"
    local al
    case "$age" in
      '')                       al="?age" ;;
      *) if [ "$age" -ge 86400 ]; then al="$((age/86400))d"
         elif [ "$age" -ge 3600 ]; then al="$((age/3600))h"
         else al="$((age/60))m"; fi ;;
    esac
    local flag="$st"
    { [ -n "$age" ] && [ "$age" -gt "$ttl" ]; } && flag="stale"
    case "$st" in ok|"") ;; *) flag="$st" ;; esac
    fmt="$fmt $s:${al}/${flag}"
  done
  printf '%s' "${fmt# }"
}

# _advise_sources_expired -> rc0 when an ENABLED source is absent, past TTL, or not ok.
_advise_sources_expired() {
  local s fetched ttl now
  now="$(date +%s)"
  for s in cursorbench tbench orbench endpoints; do
    _advise_src_enabled "$s" || continue
    [ -f "$OSRC_ADVISE_DIR/$s.meta" ] || return 0
    case "$(_advise_meta_read "$s" status)" in ok) ;; *) return 0 ;; esac
    fetched="$(_advise_meta_read "$s" fetched_at)"
    case "$fetched" in ''|*[!0-9]*) return 0 ;; esac
    case "$s" in
      cursorbench) ttl=$OSRC_ADVISE_TTL_CURSORBENCH ;;
      tbench)      ttl=$OSRC_ADVISE_TTL_TBENCH ;;
      orbench)     ttl=$OSRC_ADVISE_TTL_ORBENCH ;;
      endpoints)   ttl=$OSRC_ADVISE_TTL_ENDPOINTS ;;
    esac
    [ $(( now - fetched )) -gt "$ttl" ] && return 0
  done
  return 1
}

# --- fetch primitives ---------------------------------------------------------
# _advise_curl <url> <out-tmp> [auth] -> rc0 on HTTP 200. Auth header goes via a
# 0600 header file (same pattern as refresh_benchmarks: no key in ps args).
_advise_curl() {
  local url="$1" out="$2" auth="${3:-}" hf=""
  have curl || return 1
  if [ -n "$auth" ]; then
    hf="$(mktemp "$OSRC_ADVISE_DIR/.hdr.$$.XXXXXX" 2>/dev/null)" || return 1
    printf 'Authorization: Bearer %s\n' "$auth" > "$hf"; chmod 600 "$hf"
    curl -fsS -m "${OSRC_CURL_TIMEOUT:-30}" -H @"$hf" "$url" -o "$out" 2>/dev/null
  else
    curl -fsSL -m "${OSRC_CURL_TIMEOUT:-30}" -A 'outsourcerer-advise/1.0' "$url" -o "$out" 2>/dev/null
  fi
  local rc=$?
  [ -n "$hf" ] && rm -f "$hf"
  return $rc
}

_advise_or_key() {  # -> OpenRouter key or empty (never dies)
  local k; k="$(_extract_kv_value OPENROUTER_API_KEY 2>/dev/null)"
  printf '%s' "${k:-${OPENROUTER_API_KEY:-}}"
}

# --- per-source refreshers. Each: fetch -> validate -> atomic promote -> meta. ---
_advise_fetch_cursorbench() {
  local tmp; tmp="$(mktemp "$OSRC_ADVISE_DIR/.cb.XXXXXX")" || return 1
  if _advise_curl "https://cursor.com/cursorbench" "$tmp" \
     && grep -q '<table' "$tmp" && grep -qi 'cost per task\|Cost' "$tmp"; then
    mv -f "$tmp" "$OSRC_ADVISE_DIR/cursorbench.html"
    printf 'fetched_at=%s\nstatus=fetched\n' "$(date +%s)" > "$OSRC_ADVISE_DIR/cursorbench.meta.tmp"
    mv -f "$OSRC_ADVISE_DIR/cursorbench.meta.tmp" "$OSRC_ADVISE_DIR/cursorbench.meta"
    return 0
  fi
  rm -f "$tmp"; printf 'fetched_at=%s\nstatus=fetch-failed\n' "$(date +%s)" > "$OSRC_ADVISE_DIR/cursorbench.meta.tmp"
  mv -f "$OSRC_ADVISE_DIR/cursorbench.meta.tmp" "$OSRC_ADVISE_DIR/cursorbench.meta"; return 1
}

_advise_fetch_tbench() {
  local tmp; tmp="$(mktemp "$OSRC_ADVISE_DIR/.tb.XXXXXX")" || return 1
  if _advise_curl "https://www.tbench.ai/" "$tmp" && grep -q 'leaderboard_id' "$tmp"; then
    mv -f "$tmp" "$OSRC_ADVISE_DIR/tbench.html"
    printf 'fetched_at=%s\nstatus=fetched\n' "$(date +%s)" > "$OSRC_ADVISE_DIR/tbench.meta.tmp"
    mv -f "$OSRC_ADVISE_DIR/tbench.meta.tmp" "$OSRC_ADVISE_DIR/tbench.meta"
    return 0
  fi
  rm -f "$tmp"; printf 'fetched_at=%s\nstatus=fetch-failed\n' "$(date +%s)" > "$OSRC_ADVISE_DIR/tbench.meta.tmp"
  mv -f "$OSRC_ADVISE_DIR/tbench.meta.tmp" "$OSRC_ADVISE_DIR/tbench.meta"; return 1
}

_advise_fetch_orbench() {
  # Reuses the existing refresh_benchmarks (writes $OSRC_BENCH_JSON), then mirrors the
  # canonical copy under advise/ so the parse pipeline sees a uniform layout. The
  # function is stubbable in tests (they override refresh_benchmarks).
  if refresh_benchmarks >/dev/null 2>&1 && [ -f "$OSRC_BENCH_JSON" ]; then
    cp -f "$OSRC_BENCH_JSON" "$OSRC_ADVISE_DIR/or-bench.json" 2>/dev/null || return 1
    printf 'fetched_at=%s\nstatus=fetched\n' "$(date +%s)" > "$OSRC_ADVISE_DIR/orbench.meta.tmp"
    mv -f "$OSRC_ADVISE_DIR/orbench.meta.tmp" "$OSRC_ADVISE_DIR/orbench.meta"
    return 0
  fi
  # No key / offline: mirror an existing benchmark cache if one exists, else fail honestly.
  if [ -f "$OSRC_BENCH_JSON" ]; then
    cp -f "$OSRC_BENCH_JSON" "$OSRC_ADVISE_DIR/or-bench.json" 2>/dev/null
    printf 'fetched_at=%s\nstatus=mirrored-stale\n' "$(date +%s)" > "$OSRC_ADVISE_DIR/orbench.meta.tmp"
    mv -f "$OSRC_ADVISE_DIR/orbench.meta.tmp" "$OSRC_ADVISE_DIR/orbench.meta"
    return 0
  fi
  printf 'fetched_at=%s\nstatus=fetch-failed\n' "$(date +%s)" > "$OSRC_ADVISE_DIR/orbench.meta.tmp"
  mv -f "$OSRC_ADVISE_DIR/orbench.meta.tmp" "$OSRC_ADVISE_DIR/orbench.meta"; return 1
}

# _advise_pool_ids -> OpenRouter catalog ids to probe /endpoints for: candidate
# resolved ids that exist verbatim in the cached models.json (only those have a
# real endpoints route). Capped at OSRC_ADVISE_EP_MAX.
_advise_pool_ids() {
  { [ -f "$OSRC_MODELS_JSON" ] && have jq; } || return 0
  local resolved_ids
  resolved_ids="$(_advise_candidate_rows intelligence_index 2>/dev/null | awk -F'|' '{print $2}' | sort -u)"
  printf '%s\n' "$resolved_ids" | awk 'NF && index($0,"/")' \
    | awk 'NR==FNR{ok[$1]=1;next} ok[$1]' - <(jq -r '.data[]?.id // empty' "$OSRC_MODELS_JSON" 2>/dev/null) \
    | head -"$OSRC_ADVISE_EP_MAX"
}

_advise_fetch_endpoints() {
  local key ids id enc tmp ok=0 n=0
  key="$(_advise_or_key)"; [ -n "$key" ] || {
    printf 'fetched_at=%s\nstatus=no-key\n' "$(date +%s)" > "$OSRC_ADVISE_DIR/endpoints.meta.tmp"
    mv -f "$OSRC_ADVISE_DIR/endpoints.meta.tmp" "$OSRC_ADVISE_DIR/endpoints.meta"; return 1; }
  ids="$(_advise_pool_ids)"
  [ -n "$ids" ] || {
    printf 'fetched_at=%s\nstatus=no-pool\n' "$(date +%s)" > "$OSRC_ADVISE_DIR/endpoints.meta.tmp"
    mv -f "$OSRC_ADVISE_DIR/endpoints.meta.tmp" "$OSRC_ADVISE_DIR/endpoints.meta"; return 1; }
  mkdir -p "$OSRC_ADVISE_DIR/endpoints.d"
  # Parallel fan-out; each response validated as JSON with an endpoints array.
  # Pids tracked so `wait` only blocks on OUR curls, never an unrelated bg job.
  local _pids=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    enc="$(printf '%s' "$id" | tr '/:' '__')"
    ( tmp="$OSRC_ADVISE_DIR/endpoints.d/$enc.tmp"
      if _advise_curl "https://openrouter.ai/api/v1/models/$id/endpoints" "$tmp" "$key" \
         && jq -e '.data.endpoints | type == "array"' "$tmp" >/dev/null 2>&1; then
        mv -f "$tmp" "$OSRC_ADVISE_DIR/endpoints.d/$enc.json"
      else rm -f "$tmp"; fi ) &
    _pids="$_pids $!"
  done <<EOF
$ids
EOF
  [ -n "$_pids" ] && wait $_pids 2>/dev/null
  # Merge per-model responses into one cache file.
  local merged="$OSRC_ADVISE_DIR/endpoints.d/.merged.json"
  { printf '{"fetched_at":%s,"models":{' "$(date +%s)"
    local first=1 f mid
    for f in "$OSRC_ADVISE_DIR"/endpoints.d/*.json; do
      [ -f "$f" ] || continue
      mid="$(jq -r '.data.id // empty' "$f" 2>/dev/null)"; [ -n "$mid" ] || continue
      [ "$first" = 1 ] || printf ','
      first=0; n=$((n+1))
      printf '%s:%s' "$(jq -cn --arg m "$mid" '$m')" "$(jq -c '.data' "$f" 2>/dev/null)"
      ok=1
    done
    printf '}}'
  } > "$merged"
  if [ "$ok" = 1 ]; then
    mv -f "$merged" "$OSRC_ADVISE_DIR/or-endpoints.json"
    printf 'fetched_at=%s\nstatus=fetched\nmodels=%s\n' "$(date +%s)" "$n" > "$OSRC_ADVISE_DIR/endpoints.meta.tmp"
    mv -f "$OSRC_ADVISE_DIR/endpoints.meta.tmp" "$OSRC_ADVISE_DIR/endpoints.meta"
    return 0
  fi
  rm -f "$merged"
  printf 'fetched_at=%s\nstatus=fetch-failed\n' "$(date +%s)" > "$OSRC_ADVISE_DIR/endpoints.meta.tmp"
  mv -f "$OSRC_ADVISE_DIR/endpoints.meta.tmp" "$OSRC_ADVISE_DIR/endpoints.meta"; return 1
}

# --- worker: parallel fetches, then pool + parse. Runs detached or in foreground. ---
_advise_refresh_worker() {
  _mkdir_private "$OSRC_ADVISE_DIR" 2>/dev/null || mkdir -p "$OSRC_ADVISE_DIR" 2>/dev/null || return 1
  local net="${OSRC_ADVISE_NET:-1}"
  if [ "$net" != "0" ]; then
    local _pids=""
    _advise_src_enabled cursorbench && { _advise_fetch_cursorbench & _pids="$_pids $!"; }
    _advise_src_enabled tbench      && { _advise_fetch_tbench & _pids="$_pids $!"; }
    _advise_src_enabled orbench     && { _advise_fetch_orbench & _pids="$_pids $!"; }
    _advise_src_enabled endpoints   && { _advise_fetch_endpoints & _pids="$_pids $!"; }
    [ -n "$_pids" ] && wait $_pids 2>/dev/null
  fi
  # Candidate pool for the family vocabulary (after orbench refresh so the dynamic
  # pool sees fresh scores). Parse runs even when fetches failed: stale data beats none.
  _advise_candidate_rows intelligence_index > "$OSRC_ADVISE_DIR/pool.txt" 2>/dev/null
  if have python3; then
    python3 -I "$_OSRC_LIB_DIR/advise_parse.py" parse --dir "$OSRC_ADVISE_DIR" \
      --pool "$OSRC_ADVISE_DIR/pool.txt" 2>/dev/null
  fi
  # Summary line (visible on explicit --refresh; silent on detached).
  printf 'sources: %s\n' "$(_advise_src_status)"
}

# _advise_refresh_detached -> fire-and-forget worker with a mkdir lock (60s stampede guard).
_advise_refresh_detached() {
  local lock="$OSRC_ADVISE_DIR/.refresh.lock"
  if [ -d "$lock" ]; then
    local mt; mt="$(mtime_epoch "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null)"
    case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
    [ $(( $(date +%s) - mt )) -lt 60 ] && return 0
    rmdir "$lock" 2>/dev/null || return 0
  fi
  mkdir "$lock" 2>/dev/null || return 0
  ( _advise_refresh_worker >/dev/null 2>&1; rmdir "$lock" 2>/dev/null ) &
  return 0
}
