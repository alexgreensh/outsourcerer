# agy-models.sh — Antigravity (agy) live model catalog, Gemini family resolution, and the
# advise benchmark-cache freshness check. Loaded by outsourcerer.sh's lib/*.sh glob; every
# function resolves its dependencies ($OSRC_HOME, _catalog_load, _timeout, _gemini_bench_slug,
# _NATIVE_BENCH_MAP, refresh_benchmarks, ...) at CALL time, so load order does not matter.
#
# ---- Gemini family resolution: LIVE catalog first, never a dated literal ---------------------
# Google retires dated Gemini ids every few weeks (3.5-flash was gone within a month of 0.10.1 and
# agy hard-errors on a retired id: "invalid model selection"/"not recognized as a known model"). So
# the family aliases (gemini-flash / gemini-pro / gemini-flash-lite / gemini-neon) are SYMBOLIC and
# resolve here, at dispatch time, to the NEWEST family member the vehicle actually serves:
#   1. an explicit pin wins: OSRC_AGY_{FLASH,PRO}_DEFAULT / OSRC_GEMINI_{FLASH,PRO,FLASH_LITE}_API_ID
#      (or a models.local row that maps the alias to a concrete id);
#   2. else the newest matching id in the live catalog (`agy models`, cached 24h in
#      $OSRC_HOME/agy-models.txt for family picks; the shared catalogs/gm.json for validation);
#   3. else, catalog unreachable, a LAST-KNOWN id so an offline run still has something to send.
# The last-known constants below are the only dated ids left in this feature. They are a fallback
# for a vehicle we cannot ask, never the first choice, and a test pins that ordering.
_AGY_FLASH_LASTKNOWN="gemini-3.8-flash"
_AGY_PRO_LASTKNOWN="gemini-3.1-pro"
_GI_FLASH_LASTKNOWN="gemini-3.5-flash"
_GI_PRO_LASTKNOWN="gemini-3.1-pro-preview"
_GI_FLASH_LITE_LASTKNOWN="gemini-3.1-flash-lite"
_GI_IMAGE_LASTKNOWN="gemini-2.5-flash-image"

# _agy_models_cache -> path of the 24h `agy models` id list. Separate from catalogs/gm.json on
# purpose: that file feeds dispatch VALIDATION on a short TTL, while family picks want a day-long
# memory — model families change on release cadence, not minute cadence, and `agy models` costs a
# real CLI spawn.
_agy_models_cache() { printf '%s/agy-models.txt' "$OSRC_HOME"; }

# _agy_models_fresh -> rc 0 when the cached list is younger than OSRC_AGY_MODELS_TTL (default 24h).
_agy_models_fresh() {
  local f now age mtime
  f="$(_agy_models_cache)"
  [ -f "$f" ] || return 1
  now="$(date +%s 2>/dev/null)" || return 1
  mtime="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( now - mtime ))
  [ "$age" -lt "${OSRC_AGY_MODELS_TTL:-86400}" ] 2>/dev/null
}

# _agy_models_parse <raw> -> one model id per line. Mirrors _catalog_normalize's gm branch:
# "<id><TAB><label>" rows behind a "Fetching available models..." status line; the status line has
# no tab so the tab split drops it. If a future agy stops tab-separating, fall back to the first
# whitespace token per line minus any "..."-terminated status line.
_agy_models_parse() {
  local raw="$1" _gm
  _gm="$(printf '%s' "$raw" | awk -F'\t' 'NF>=2{print $1}' | grep -E '^[A-Za-z0-9._/-]+$')"
  if [ -n "$_gm" ]; then printf '%s\n' "$_gm"; return; fi
  printf '%s' "$raw" | grep -v '\.\.\.[[:space:]]*$' \
    | sed 's/[│┃|]/ /g' \
    | tr ',' '\n' \
    | grep -viE 'MODEL[[:space:]]*ID' \
    | awk '{print $1}' \
    | grep -E '^[A-Za-z0-9._/-]+$'
}

# _agy_models_list -> the ids `agy models` currently serves, one per line. Fresh 24h cache first;
# on miss/stale a bounded live fetch rewrites the cache atomically. Empty output on any failure —
# callers fall back to the last-known constants. A response with NO gemini- id at all is treated
# as a broken probe, not cached: caching it would pin family resolution to last-known for a day.
_agy_models_list() {
  local f tmp raw ids
  f="$(_agy_models_cache)"
  if _agy_models_fresh; then cat "$f" 2>/dev/null; return; fi
  have agy || return 1
  raw="$(_timeout "${OSRC_CATALOG_FETCH_TIMEOUT:-10}" env -u GEMINI_API_KEY -u GOOGLE_API_KEY agy models 2>/dev/null)"
  [ -n "$raw" ] || return 1
  ids="$(_agy_models_parse "$raw")"
  printf '%s\n' "$ids" | grep -q '^gemini-' || return 1
  _mkdir_private "$OSRC_HOME" || true
  tmp="${f}.tmp.$$"
  printf '%s\n' "$ids" > "$tmp" && mv -f "$tmp" "$f" || { rm -f "$tmp" 2>/dev/null; return 1; }
  printf '%s\n' "$ids"
}

# _gemini_newest <lane gm|gi> <family flash|pro|flash-lite|flash-image> -> newest family id in that
# lane's live catalog (agy effort suffixes stripped; a -preview id is kept as named but loses to a GA
# id of the same version), or empty.
# Version order is numeric on major.minor, so 3.10 beats 3.8 and a two-digit minor never sorts wrong.
_gemini_newest() {
  local lane="$1" fam="$2" _cat
  _cat="$(_catalog_load "$lane" 2>/dev/null)"; [ -n "$_cat" ] || return 1
  printf '%s\n' "$_cat" \
    | LC_ALL=C sed -n -E "s/^(gemini-[0-9]+(\.[0-9]+)?-${fam})(-(low|medium|high|xhigh))?(-preview)?$/\1\5 \5/p" \
    | awk '{ split($1, f, "-"); split(f[2], v, "."); pre=($2=="" ? 0 : 1);
             printf "%d %d %d %s\n", v[1], (v[2]=="" ? 0 : v[2]), pre, $1 }' \
    | sort -k1,1nr -k2,2nr -k3,3n | awk 'NR==1{print $4}'
}

# _agy_newest <family> -> newest gemini-<ver>-<family> id in the 24h `agy models` list, effort
# suffix stripped to the bare family token (the -low/-medium/-high/-xhigh rung is re-applied via
# --effort at dispatch). Same version ordering as _gemini_newest, different cache.
_agy_newest() {
  local fam="$1" _cat
  _cat="$(_agy_models_list 2>/dev/null)"; [ -n "$_cat" ] || return 1
  printf '%s\n' "$_cat" \
    | LC_ALL=C sed -n -E "s/^(gemini-[0-9]+(\.[0-9]+)?-${fam})(-(low|medium|high|xhigh))?(-preview)?$/\1\5 \5/p" \
    | awk '{ split($1, f, "-"); split(f[2], v, "."); pre=($2=="" ? 0 : 1);
             printf "%d %d %d %s\n", v[1], (v[2]=="" ? 0 : v[2]), pre, $1 }' \
    | sort -k1,1nr -k2,2nr -k3,3n | awk 'NR==1{print $4}'
}

# _agy_flagship -> the concrete id of the top non-flash Gemini family agy serves, for the pro-class
# aliases. Gemini 4 renamed the tiers to codenames, so "pro" is now whichever flagship the catalog
# lists: ranked newest-version-first, then by known tier order (carbon > neon > argon > hydrogen >
# legacy pro > anything unrecognized), then by effort rung — `high` first because it is agy's
# documented default thinking level for these families (xhigh exists but is the "Extra" opt-in).
# Returns e.g. gemini-4-neon-high. Empty when the list has no pro-class family.
_agy_flagship() {
  local _cat
  _cat="$(_agy_models_list 2>/dev/null)"; [ -n "$_cat" ] || return 1
  printf '%s\n' "$_cat" | awk '
    function famrank(f) { return (f=="carbon")?10:(f=="neon")?20:(f=="argon")?30:(f=="hydrogen")?40:(f=="pro")?50:90 }
    function effrank(e) { return (e=="high")?1:(e=="xhigh")?2:(e=="medium")?3:(e=="low")?4:(e=="minimal")?5:(e=="none")?6:(e=="")?7:(e=="preview")?8:9 }
    /^gemini-[0-9]/ {
      n = split($0, t, "-")
      if (n < 3 || n > 4) next
      ver = t[2]; fam = t[3]; eff = (n == 4 ? t[4] : "")
      if (fam !~ /^[a-z][a-z0-9]*$/ || fam == "flash") next
      if (eff != "" && eff !~ /^(none|minimal|low|medium|high|xhigh|preview)$/) next
      split(ver, v, ".")
      printf "%d %d %d %d %s\n", v[1]+0, (v[2]=="" ? 0 : v[2]+0), famrank(fam), effrank(eff), $0
    }' \
    | sort -k1,1nr -k2,2nr -k3,3n -k4,4n | awk 'NR==1{print $5}'
}

# _agy_catalog_knows <token> -> 0 served (exactly, or as the bare family of an effort-suffixed id),
# 1 NOT served by a reachable catalog, 2 catalog unreachable (the caller must fail OPEN on 2).
_agy_catalog_knows() {
  local tok="$1" _cat v
  _cat="$(_catalog_load gm 2>/dev/null)"; [ -n "$_cat" ] || return 2
  for v in "$tok" "$tok-low" "$tok-medium" "$tok-high" "$tok-xhigh"; do
    grep -qxF "$v" <<<"$_cat" && return 0
  done
  return 1
}

# _agy_effort_rung <id> -> the same family at the rung --effort asked for, when agy serves it.
# Gemini 4 ids name their effort (gemini-4-neon-high) and agy refuses a separate --effort flag, so
# without this a family request with --effort low would still run the high rung.
_agy_effort_rung() {
  local id="$1" want base
  case "${EFFORT:-}" in minimal|low) want=low ;; medium) want=medium ;; high) want=high ;; xhigh|max) want=xhigh ;; *) printf '%s' "$id"; return 0 ;; esac
  case "$id" in *-low|*-medium|*-high|*-xhigh) base="${id%-*}" ;; *) printf '%s' "$id"; return 0 ;; esac
  if grep -qx "$base-$want" <<<"$(_agy_models_list 2>/dev/null)"; then printf '%s' "$base-$want"; else printf '%s' "$id"; fi
}

# _agy_family_default <flash|pro> -> the id agy should run for a bare family request (see the
# precedence above). agy has no flash-lite tier, so lite callers ask for flash.
_agy_family_default() {
  local fam="$1" pin="" live=""
  case "$fam" in pro) pin="${OSRC_AGY_PRO_DEFAULT:-}" ;; *) fam=flash; pin="${OSRC_AGY_FLASH_DEFAULT:-}" ;; esac
  [ -n "$pin" ] && { printf '%s' "$pin"; return 0; }
  if [ "$fam" = pro ]; then
    live="$(_agy_flagship)" && [ -n "$live" ] && { _agy_effort_rung "$live"; return 0; }
  else
    live="$(_agy_newest flash)" && [ -n "$live" ] && { printf '%s' "$live"; return 0; }
  fi
  # Catalog had no match (or was unreachable): the shared gm catalog still knows the legacy
  # flash/pro spellings, then the last-known constants are the final offline answer.
  live="$(_gemini_newest gm "$fam")" && [ -n "$live" ] && { printf '%s' "$live"; return 0; }
  case "$fam" in pro) printf '%s' "$_AGY_PRO_LASTKNOWN" ;; *) printf '%s' "$_AGY_FLASH_LASTKNOWN" ;; esac
}

# _agy_model_token <alias or id> -> the token the Antigravity `agy` CLI accepts.
#   - a symbolic family alias (gemini-flash, gemini-pro, gemini-flash-lite, gemini-neon, or an
#     API-only -preview/-lite id) -> _agy_family_default;
#   - an id already shaped like agy's catalog (gemini-<ver>-<family>[...], incl. the
#     effort-suffixed forms) passes through UNCHANGED when the live catalog serves it, or when the
#     catalog cannot be read (agy is the authority; it will say so itself);
#   - an id the live catalog confirms is RETIRED is replaced by the family's newest member, LOUDLY,
#     with the retired id named and every pin mechanism listed. Silent substitution was the 0.10.0
#     bug (`-m gemini-3.7-flash` ran 3.5 with no notice); a hard failure on a retired default was
#     the 0.10.1 bug (issue #21). Announced self-healing is the middle that keeps both promises.
_agy_model_token() {
  local want="$1" fam tok
  case "$want" in
    gemini-neon) _agy_model_token gemini-4-neon-high gemini-neon; return ;;
    *-preview|*-lite) : ;;
    gemini-[0-9]*.[0-9]*-flash*|gemini-[0-9]*.[0-9]*-pro*|gemini-[0-9]*-flash*|gemini-[0-9]*-pro*|\
gemini-[0-9]*-neon*|gemini-[0-9]*-argon*|gemini-[0-9]*-hydrogen*|gemini-[0-9]*-carbon*)
      _agy_catalog_knows "$want"
      case $? in 0|2)
        if [ "${2:-}" = gemini-neon ] && [ "$want" = gemini-4-neon-high ]; then
          _agy_effort_rung "$want"
        else
          printf '%s' "$want"
        fi
        return 0 ;;
      esac
      case "$want" in *pro*|*neon*|*argon*|*hydrogen*|*carbon*) fam=pro ;; *) fam=flash ;; esac
      tok="$(_agy_family_default "$fam")"
      printf '>>> [gemini] agy no longer serves "%s" (its live catalog is `agy models`); running %s, the newest %s it serves. To pin a different id: -m <id>, OSRC_AGY_%s_DEFAULT=<id>, or a "%s|<id>|gm|<tier>" row in %s/models.local.\n' \
        "$want" "$tok" "$fam" "$(printf '%s' "$fam" | tr a-z A-Z)" "$want" "$OSRC_HOME" >&2
      printf '%s' "$tok"; return 0 ;;
  esac
  case "$want" in
    *pro*|*neon*|*argon*|*hydrogen*|*carbon*) _agy_family_default pro ;;
    *flash*) _agy_family_default flash ;;   # covers flash + flash-lite (agy has no lite tier)
    *)       printf '%s' "$want" ;;
  esac
}

# _gemini_api_id <alias or id> -> a concrete id for the gemini-cli (API key) vehicle. Same
# precedence as agy: env pin > newest in the live API model list > last-known. Explicit dated ids
# pass through untouched (the API is the authority on its own catalog).
_gemini_api_id() {
  local want="$1" fam pin live
  case "$want" in
    gemini-flash-lite)             fam=flash-lite;  pin="${OSRC_GEMINI_FLASH_LITE_API_ID:-}" ;;
    gemini-flash)                  fam=flash;       pin="${OSRC_GEMINI_FLASH_API_ID:-}" ;;
    gemini-pro)                    fam=pro;         pin="${OSRC_GEMINI_PRO_API_ID:-}" ;;
    nano-banana|gemini-flash-image) fam=flash-image; pin="${OSRC_GEMINI_IMAGE_API_ID:-}" ;;
    *) printf '%s' "$want"; return 0 ;;
  esac
  [ -n "$pin" ] && { printf '%s' "$pin"; return 0; }
  live="$(_gemini_newest gi "$fam")" && [ -n "$live" ] && { printf '%s' "$live"; return 0; }
  case "$fam" in
    pro)         printf '%s' "$_GI_PRO_LASTKNOWN" ;;
    flash-lite)  printf '%s' "$_GI_FLASH_LITE_LASTKNOWN" ;;
    flash-image) printf '%s' "$_GI_IMAGE_LASTKNOWN" ;;
    *)           printf '%s' "$_GI_FLASH_LASTKNOWN" ;;
  esac
}

# _agy_effort <agy-model-token> <requested-effort> -> an effort level that model actually accepts.
# agy REQUIRES --effort for a BARE family id and rejects the run outright without it
# ("invalid model selection (--model X --effort \"\"): requires --effort"), and the accepted set is
# per-model: pro offers low|high with NO medium, flash offers low|medium|high. An unsupported level is
# rounded UP rather than down, because silently giving less thinking than asked for is the failure the
# caller cannot see; the clamp is announced.
# The mirror image also holds and is easy to miss: an id that already NAMES its effort must be sent
# with NO --effort at all, because agy rejects that pair just as hard ("--model gemini-3.7-flash-high
# conflicts with --effort=medium"). Returning empty here is the signal to drop the flag.
_agy_effort() {
  local tok="$1" want="${2:-medium}" out
  case "$want" in low|medium|high) ;; *) want=medium ;; esac
  case "$tok" in
    # An id that already NAMES its effort takes no --effort flag: agy rejects the pair outright
    # ("--model gemini-3.7-flash-high conflicts with --effort=medium"). Every id in agy's catalog is
    # of this form, so this is the normal case for an explicitly pinned model, not an edge case.
    # Emit nothing and let the caller omit the flag. -xhigh is the Gemini-4 "Extra" rung and counts
    # as named effort too.
    *-low|*-medium|*-high|*-xhigh) return 0 ;;
  esac
  case "$tok" in
    *pro*)   case "$want" in medium) out=high ;; *) out="$want" ;; esac ;;
    *flash*) out="$want" ;;
    *)       out="$want" ;;
  esac
  [ "$out" != "$want" ] && printf '>>> [effort] %s has no "%s" level (accepts low|high) — using "%s" rather than quietly giving you less thinking.\n' "$tok" "$want" "$out" >&2
  printf '%s' "$out"
}

# ---- OpenRouter benchmark slug + cache freshness (advise) --------------------------------------

# _agy_or_bench_slug <resolved-id> -> OpenRouter permaslug prefix for the Gemini-4 codename families
# (neon/argon/hydrogen/carbon), or empty. Prefers the NEWEST google/gemini-<ver>-<fam> id in the
# cached OpenRouter catalog (same shape rule as _gemini_bench_slug, any codename), then the static
# _NATIVE_BENCH_MAP row, then nothing — an unmatched id scores via the tier proxy, by design.
_agy_or_bench_slug() {
  local id="$1" fam mapped
  fam="$(printf '%s' "$id" | sed -nE 's/^gemini-[0-9]+(\.[0-9]+)?-([a-z][a-z0-9]*)(-[a-z0-9]+)*$/\2/p')"
  case "$fam" in neon|argon|hydrogen|carbon) ;; *) return 0 ;; esac
  mapped="$(_gemini_bench_slug "$fam" 2>/dev/null)"
  [ -n "$mapped" ] && { printf '%s' "$mapped"; return 0; }
  mapped="$(printf '%s\n' "${_NATIVE_BENCH_MAP:-}" | awk -F'|' -v a="$id" '$1==a{print $2; exit}')"
  [ -n "$mapped" ] && printf '%s' "$mapped"
  return 0
}

# _iso_epoch_utc <iso-8601> -> epoch seconds (UTC), empty on failure. as_of fields are always Z;
# a non-Z offset is stripped and still read as UTC, which is correct for this data source.
_iso_epoch_utc() {
  local s="${1:-}"
  [ -n "$s" ] || return 1
  s="$(printf '%s' "$s" | sed -E 's/\.[0-9]+//; s/[+-][0-9]{2}:?[0-9]{2}$//; s/Z$//; s/T/ /')"
  TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' "$s" +%s 2>/dev/null \
    || date -u -d "$s UTC" +%s 2>/dev/null
}

# _bench_cache_stale -> rc 0 and "DAYS<TAB>AS_OF" when benchmarks.json is dated older than 7 days.
# DAYS is "unknown" when the cache exists but carries no parseable date — an undated cache cannot
# prove it is fresh, so it is reported stale rather than trusted.
_bench_cache_stale() {
  [ -f "$OSRC_BENCH_JSON" ] && have jq || return 1
  local asof ep now age
  asof="$(jq -r '.meta.as_of // empty' "$OSRC_BENCH_JSON" 2>/dev/null)"
  ep="$(_iso_epoch_utc "$asof" 2>/dev/null)"
  now="$(date +%s)"
  if [ -z "$ep" ]; then printf 'unknown\t%s\n' "${asof:-no-date}"; return 0; fi
  age=$(( now - ep )); [ "$age" -lt 0 ] && age=0
  [ "$age" -gt $((7 * 86400)) ] || return 1
  printf '%s\t%s\n' "$(( age / 86400 ))" "$asof"
}
