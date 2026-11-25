# =============================================================================
# lib/spend.sh — paid-lane spend gate + per-lane usage caps
#
# Two guards that sit NEXT TO the plan-meter gate (lib/limits.sh):
#
#   osrc_lane_billing / _osrc_spend_gate
#     "Never use a paid lane without asking." Every launch path (run/bg/fanout/
#     session start/auto-routing/fallback hops/retries) resolves to a lane; the
#     gate classifies its billing and, for metered-or-unknown lanes, demands
#     consent: interactive y/N (default No), --spend-ok on THIS command, or the
#     per-job .spend-ok marker a consenting bg parent drops for its detached
#     child — the marker is BOUND to the resolved lane|model pair and consumed
#     (deleted) once dispatch starts. Non-interactive refusals emit
#     `EVENT approval ... paid-lane:...` + NEXT so supervise replays them.
#     --spend-ok is NEVER persisted, never implied by auto mode, the
#     cloud-consent file, or an inherited env var (the env block unsets
#     OSRC_SPEND_OK/OSRC_SPEND_GATE/OSRC_CAP_GATE before parsing; there is no
#     env kill-switch for these gates).
#
#   --cap / lane cap + _osrc_cap_gate / _osrc_cap_poll
#     Per-lane plan-window caps: `--cap weekly<=40 --cap 5h<=80` on a launch
#     (repeatable) plus standing `lane cap <lane> weekly<=40` until
#     `lane cap <lane> --clear`. Checked pre-launch (route_delegate + both
#     session start paths) and on every _supervise poll; a tripped cap refuses
#     new launches, emits `EVENT limit ... cap:... now:...` once per job/session,
#     and `session send` refuses new work to a capped lane (wrap-up messages
#     pass — see _osrc_cap_send_ok for the best-effort prefix match).
#
# Billing classes: subscription | free | metered | unknown. unknown is treated
# as metered — when auth state cannot be proven, the lane asks first.
# =============================================================================

# ---- billing classification --------------------------------------------------

# _osrc_billing_key <ENVNAME> -> rc0 when the key is exported OR present in ~/.env.
_osrc_billing_key() {
  local k="${1:-}"
  [ -n "$k" ] || return 1
  [ -n "$(eval "printf '%s' \"\${$k:-}\"" 2>/dev/null)" ] && return 0
  [ -n "$(_extract_kv_value "$k" 2>/dev/null)" ]
}

# _osrc_dir_key_material <dir> -> rc0 when ANY regular file at depth 1 in <dir>
# carries explicit API-key material ("apiKey"/"api_key"/"api-key"/"apikey" JSON
# fields). A plan session token is not API-key material; this only flags per-use
# credentials so a BYOK login stored in the lane's config dir cannot pass as a
# subscription off dir existence alone (same class as the claude credentials
# fix). Every file is scanned, not just auth-ish names: config.json /
# settings.json are where these CLIs keep bring-your-own-key models, and the
# field pattern is already narrow enough (8+ char value) that a filename filter
# only hides the common case. -I still skips binary files.
# KNOWN LIMITS (r11 F4, verified gaps — do not assume more coverage):
#   * depth-1 regular files only — a key in a SUBDIRECTORY (byok/keys.json) is missed;
#   * single-line JSON values only — `"apiKey":` with the value on the NEXT line is missed;
#   * JSON field names only — YAML (api_key: sk-...) and env-var key references
#     (api_key_env + a custom base URL) are missed;
#   * codex config.toml model_provider redirects are not scanned at all.
# Each missed shape classifies subscription/unknown only when no OTHER evidence
# contradicts it — the lane's own CLI status probes (codex login status,
# claude auth status apiKeySource) are the backstop for the cases above.
_osrc_dir_key_material() {
  local d="${1:-}" _hits
  [ -d "$d" ] || return 1
  _hits="$(find "$d" -maxdepth 1 -type f -exec grep -lsIE \
    '"(apiKey|api_key|api-key|apikey)"[[:space:]]*:[[:space:]]*"[^"]{8,}"' {} + 2>/dev/null)"
  [ -n "$_hits" ]
}

# _osrc_devin_free_for_spend <model> -> rc0 ONLY when the model is proven Free for SPEND
# purposes. Live catalog first: when `devin models list` is reachable, ONLY its cost_tier="Free"
# tag counts (exact model_uid / all-Free family_uid match — never a canon guess, so a paid
# -max/-medium variant cannot ride in on a free sibling's name). Offline, the static fallback
# is exactly two proven-free ids: SWE-2 High and SWE-2 Flash High — no family aliases, so
# swe-2 / swe-2-flash / glm / anything unproven still asks. Everything else is paid and the
# spend gate asks. Stricter than _devin_is_free_model, whose plan-included static list
# answers a different question (does it draw the paid ACU balance, not "is it free to run").
_osrc_devin_free_for_spend() {
  local t="${1:-}" ids
  # The EXACT id that launches, byte for byte: no vendor/ stripping and no case or dot
  # folding. Folding judged SWE-2-HIGH / swe.2.high Free while the launcher passed that
  # spelling verbatim (offline, or a bg pin), so the judged id was not the launched one.
  # Routed launches still match: the resolver returns the catalog's exact uid.
  [ -n "$t" ] || return 1
  if [ "${OSRC_FREE_CATALOG_CHECK:-1}" = "1" ]; then
    if ids="$(_devin_catalog_free_ids 2>/dev/null)"; then
      # Catalog reachable: ONLY its Free tag decides — the static fallback does not apply.
      case " $ids " in *" $t "*) return 0 ;; *) return 1 ;; esac
    fi
  fi
  case "$t" in
    swe-2-high|swe-2-flash-high) return 0 ;;
  esac
  return 1
}

# _devin_catalog_free_ids -> space-separated EXACT ids the live catalog marks cost_tier="Free":
# every variant model_uid tagged Free plus every family_uid whose variants are ALL Free.
# Exact ids (not canon keys) so a paid -max/-medium variant can never ride in on a free
# sibling's normalized name — the spend gate's Free proof depends on that precision.
# rc0 whenever the catalog is reachable/fresh (even with an empty set); rc1 offline, so
# callers can tell "reachable, nothing Free" apart from "cannot prove". The result is
# cached in $OSRC_HOME keyed by the raw catalog's mtime — billing lookups run in $( )
# subshells where in-process memos die, and this keeps `devin models list` to one fetch
# per catalog TTL instead of one per lookup. Lives here (not the engine) for the
# engine-size budget; its catalog helpers (_devin_catalog_rawf/_catalog_load/_catalog_fresh)
# stay engine-side and resolve at call time.
_OSRC_DV_FREE_IDS_MEMO=""; _OSRC_DV_FREE_IDS_DONE=""
_devin_catalog_free_ids() {
  [ "${OSRC_FREE_CATALOG_CHECK:-1}" = "1" ] || return 1
  # Per-process memo: a probe pass asks once per lane/model; without this each ask
  # re-runs the catalog freshness check + jq walk (~15 subprocesses per pass).
  [ -n "$_OSRC_DV_FREE_IDS_DONE" ] && { printf '%s' "$_OSRC_DV_FREE_IDS_MEMO"; return 0; }
  local rawf cf mt cmt cids ids
  rawf="$(_devin_catalog_rawf)" || return 1
  _catalog_load dv >/dev/null 2>&1 || true    # refresh attempt; freshness below decides
  _catalog_fresh dv || return 1               # only a LIVE (or just-fetched) catalog proves Free
  [ -f "$rawf" ] || return 1
  cf="$OSRC_HOME/.devin-free-ids"
  # GNU-first order (matches outsourcerer.sh's catalog mtime): on Linux `stat -f` is
  # --file-system and its output poisoned every cache line; BSD stat rejects -c silently.
  mt="$(stat -c %Y "$rawf" 2>/dev/null || stat -f %m "$rawf" 2>/dev/null || echo 0)"
  case "$mt" in ''|*[!0-9]*|0) mt=0 ;; esac
  if [ "$mt" != "0" ] && [ -f "$cf" ]; then
    # v2: the extractor version is part of the cache key. v1 rows were produced
    # by the cost_summary substring matcher and can contain paid Fusion ids whose
    # price text merely ends in "Sidekick: Free"; never trust them after the fix.
    local cver
    { IFS='|' read -r cver cmt cids < "$cf"; } 2>/dev/null
    if [ "$cver" = "v2" ] && [ "$cmt" = "$mt" ]; then
      _OSRC_DV_FREE_IDS_DONE=1; _OSRC_DV_FREE_IDS_MEMO="$cids"
      printf '%s' "$cids"; return 0
    fi
  fi
  local jqrc rawids
  rawids="$(jq -r '
    def isfree(o): (((o.cost_tier | strings) // "") | ascii_downcase) == "free";
    def uidok: (type == "string") and (test("^[A-Za-z0-9._/-]+$"));
    [ .families[]?
      | ( select((.variants|type) == "array" and (.variants|length) > 0 and all(.variants[]?; isfree(.))) | .family_uid ),
        ( .variants[]? | select(isfree(.)) | .model_uid ) ]
    | map(select(uidok)) | unique | .[]
  ' "$rawf" 2>/dev/null)"; jqrc=$?
  ids="$(printf '%s' "$rawids" | tr '\n' ' ' | sed 's/  */ /g;s/^ //;s/ $//')"
  # Never cache a jq failure: a corrupt/half-written raw catalog would otherwise pin an
  # empty Free set for this mtime and silently degrade discovery to the offline fallback.
  # Atomic write: a truncated concurrent read under fanout would otherwise decode garbage.
  [ "$jqrc" -eq 0 ] && [ "$mt" != "0" ] && {
    ( umask 077; printf 'v2|%s|%s\n' "$mt" "$ids" > "$cf.tmp.$$" && mv -f "$cf.tmp.$$" "$cf" ) 2>/dev/null || rm -f "$cf.tmp.$$" 2>/dev/null
  }
  _OSRC_DV_FREE_IDS_DONE=1; _OSRC_DV_FREE_IDS_MEMO="$ids"
  printf '%s' "$ids"
  return 0
}

# _osrc_rank_free_ids -> tab-separated rank rows for exact catalog Free ids:
# budget, qualifier-penalty, version-key, tier, raw-id. Design notes (Neon review):
# - Letters are meaningless across families and qualifier segments (-mini/-preview)
#   must not inflate a version, so the version key is DIGIT RUNS ONLY, zero-padded
#   (BSD sort has no -V). swe-2.1 > swe-2 and swe-10 > swe-2 both fall out naturally.
# - Matching is case-insensitive but column 5 keeps the catalog's exact raw id.
# - -none variants (zero reasoning, present in the live catalog) are tier 0.
_osrc_rank_free_ids() {
  awk '
  NF == 0 { next }
  {
    id = $0
    lid = tolower(id)
    budget = (lid ~ /(flash|fast|lightning)/) ? 1 : 0
    tier = 0
    base = lid
    if (lid ~ /-max$/)         { tier = 5; sub(/-max$/, "", base) }
    else if (lid ~ /-xhigh$/)  { tier = 4; sub(/-xhigh$/, "", base) }
    else if (lid ~ /-high$/)   { tier = 3; sub(/-high$/, "", base) }
    else if (lid ~ /-medium$/) { tier = 2; sub(/-medium$/, "", base) }
    else if (lid ~ /-low$/)    { tier = 1; sub(/-low$/, "", base) }
    else if (lid ~ /-none$/)   { tier = 0; sub(/-none$/, "", base) }
    gsub(/\./, "-", base)
    rest = base; vk = ""
    while (match(rest, /[0-9]+/)) {
      vk = vk sprintf("%012d", substr(rest, RSTART, RLENGTH) + 0) "-"
      rest = substr(rest, RSTART + RLENGTH)
    }
    nseg = split(base, seg, /-/); qual = 0; seen = 0
    for (i = 1; i <= nseg; i++) if (seg[i] ~ /^[a-z]+$/) { if (seen) qual++; seen = 1 }
    printf "%d\t%d\t%s\t%d\t%s\n", budget, qual, vk, tier, id
  }'
}

# Space-separated ids -> newline rows without glob expansion or IFS dependence
# (unquoted expansion of the id list could glob-match files in $PWD — Neon review).
_osrc_free_lines() { printf '%s' "$1" | tr ' ' '\n' | awk 'NF'; }

# _osrc_pick_best_free -> best id from newline rows on stdin: newest -high first
# (the lane default), otherwise the strongest/newest. sort drains fully into awk so
# no SIGPIPE can hit the producer under pipefail. LC_ALL=C pins byte-order collation.
_osrc_pick_best_free() {
  local rows high
  rows=$(cat)
  [ -n "$rows" ] || return 1
  high=$(printf '%s\n' "$rows" | awk 'tolower($0) ~ /-high$/')
  if [ -n "$high" ]; then printf '%s\n' "$high"; else printf '%s\n' "$rows"; fi     | _osrc_rank_free_ids     | LC_ALL=C sort -t$'\t' -k1,1n -k2,2n -k3,3r -k4,4nr     | awk -F'\t' 'NR == 1 { out = $5 } END { if (out != "") print out }'
}

# _devin_default_free_model -> the dv lane's implicit default, picked at RUN TIME from
# the live catalog's exact Free set so a bare `run`/`bg` prefers free models before any
# spend. Preference order (both reviewers verified the old one inverted it):
#   1. mainline partition first — flash/fast/lightning are used only when NO mainline
#      Free id exists at all;
#   2. the SWE coding family preferred within that partition, never required;
#   3. newest -high variant, then strongest/newest remaining.
# Catalog unreachable or nothing Free -> swe-2-high, the deliberately conservative offline
# fallback. Offline there is no fresh proof either way: swe-2-high/flash-high are static
# free-for-spend ids, so a bare run on them does NOT ask; if Devin re-prices them while
# the catalog is unreachable that is the accepted offline exception, never a silent hop
# to a DIFFERENT paid id. Lives here (not the engine) for the engine-size budget; callers:
# _route_provider_default_model, osrc_lane_billing dv.
_devin_default_free_model() {
  local ids rows main swe cand
  if ids="$(_devin_catalog_free_ids 2>/dev/null)" && [ -n "$ids" ]; then
    rows="$(_osrc_free_lines "$ids")"
    main=$(printf '%s\n' "$rows" | awk 'tolower($0) !~ /(flash|fast|lightning)/')
    [ -n "$main" ] || main="$rows"
    swe=$(printf '%s\n' "$main" | awk 'tolower($0) == "swe" || index(tolower($0), "swe-") == 1')
    [ -n "$swe" ] && main="$swe"
    cand=$(printf '%s\n' "$main" | _osrc_pick_best_free 2>/dev/null)
    [ -n "$cand" ] && { printf '%s' "$cand"; return 0; }
  fi
  printf 'swe-2-high'
}

# _osrc_flag_on <value> -> rc0 for truthy switch values (1/true/yes/on, any case);
# empty, 0 and false are off. CLAUDE_CODE_USE_* style env switches accept more than
# the literal "1" (the real CLI treats "true" the same), so billing must too.
_osrc_flag_on() { case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }
# _osrc_anthropic_redirect <url> -> rc0 when the URL sends Claude Code somewhere other than
# Anthropic's own first-party API. Empty or the stock https://api.anthropic.com (any case,
# trailing slashes, surrounding whitespace, which the SDK trims) is NOT a redirect: the Claude
# desktop app exports exactly that default into every session it spawns, and treating it as a
# proxy flagged plan logins as metered. Anything else is a redirect, failing toward asking:
# http://, a path (/v1), a port, userinfo (api.anthropic.com@evil.tld), a lookalike host.
_osrc_anthropic_redirect() {
  local u; u="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  u="${u#"${u%%[![:space:]]*}"}"; u="${u%"${u##*[![:space:]]}"}"
  [ -n "$u" ] || return 1
  while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
  case "$u" in https://api.anthropic.com) return 1 ;; *) return 0 ;; esac
}

# _osrc_claude_settings_metered -> rc0 when the ACTIVE Claude config dir's
# settings.json routes Claude through a per-use credential: an apiKeyHelper, or an
# env.* entry carrying a key, auth token or base-URL/provider redirect
# (ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN,
# CLAUDE_CODE_USE_BEDROCK/VERTEX/FOUNDRY). The config dir honours CLAUDE_CONFIG_DIR
# exactly like CODEX_HOME — a helper living there bills per-use even when
# ~/.claude/settings.json is clean. settings.local.json and project settings are
# covered by the CLI's own apiKeySource field in _osrc_claude_plan_login.
_osrc_claude_settings_metered() {
  local f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  [ -f "$f" ] || return 1
  # A file jq cannot parse (trailing comma, comment) falls through to the plain grep below.
  if have jq && jq empty "$f" >/dev/null 2>&1; then
    jq -e '.apiKeyHelper // empty' "$f" >/dev/null 2>&1 && return 0
    jq -e '[.env.ANTHROPIC_API_KEY, .env.ANTHROPIC_AUTH_TOKEN]
            | map(select(. != null and . != "" and . != "0" and . != "false")) | length > 0' \
       "$f" >/dev/null 2>&1 && return 0
    # A base URL is a redirect only when it is not the stock first-party endpoint (same rule as
    # the env var). A non-string value counts as a redirect; an unparsable file stays as before.
    local _bu; _bu="$(jq -r '.env.ANTHROPIC_BASE_URL | if . == null or . == "0" or . == "false" then "" elif type == "string" then . else "?" end' "$f" 2>/dev/null)" || _bu=""
    _osrc_anthropic_redirect "$_bu" && return 0
    jq -e '[.env.CLAUDE_CODE_USE_BEDROCK, .env.CLAUDE_CODE_USE_VERTEX, .env.CLAUDE_CODE_USE_FOUNDRY]
            | map(select(. != null)) | map(tostring | ascii_downcase)
            | map(select(. != "" and . != "0" and . != "false")) | length > 0' \
       "$f" >/dev/null 2>&1 && return 0
    return 1
  fi
  grep -qE 'apiKeyHelper|ANTHROPIC_API_KEY|ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_USE_(BEDROCK|VERTEX|FOUNDRY)' "$f" 2>/dev/null && return 0
  return 1
}

# osrc_lane_billing <lane|disp|provider|alias> [model] [disp] -> subscription|free|metered|unknown
# Evidence-based: `subscription` requires PROOF of a plan login AND the absence of every
# per-use redirect. For cc the only proof is `claude auth status` JSON carrying
# loggedIn+authMethod=claude.ai+apiProvider=firstParty+subscriptionType in
# pro|max|team|enterprise (_osrc_claude_plan_login) — a credentials file or keychain
# entry proves a login was written, not what it bills, so neither yields subscription.
# API keys,
# auth tokens, base-URL redirects, cloud vehicles (BEDROCK/VERTEX/OPENAI_BASE_URL/claude
# settings helpers), and BYOK paths are `metered` even when a plan login also exists. A CLI on
# PATH with no provable login is `unknown` — never assumed subscription. unknown is treated as
# metered by the spend gate (ask first, never assume free). The third arg (disp/vehicle) is
# NOT display-only: a disp containing cloud|hosted is metered on any lane — `cloud
# start` relies on this for hosted Devin sessions.
osrc_lane_billing() {
  local tok="${1:-}" model="${2:-}" disp="${3:-}" lane=""
  [ -n "$tok" ] || { printf 'unknown\n'; return; }
  # Engine names the session path passes ("devin", "agy", "factory") are not registry
  # tokens; unmapped they fell through to "unknown" and the gate called a plan model paid.
  case "$tok" in devin) tok=dv ;; agy|antigravity) tok=gm ;; factory) tok=droid ;; esac
  lane="$(_lane_by_disp "$tok" 2>/dev/null)" || lane=""
  [ -n "$lane" ] || lane="$(_lane_by_token "$tok" 2>/dev/null)" || lane=""
  [ -n "$lane" ] || lane="$(_lane_by_native "$tok" 2>/dev/null)" || lane=""
  [ -n "$lane" ] || lane="$(_lane_by_provider "$tok" 2>/dev/null)" || lane=""
  [ -n "$lane" ] || { printf 'unknown\n'; return; }
  # A hosted/cloud vehicle bills per-use on whatever plan login fronts it.
  case "$disp" in *cloud*|cloud|*hosted*) printf 'metered\n'; return ;; esac
  case "$lane" in
    opencode) printf 'metered\n'; return ;; # Go extra usage can bill; auth list does not prove its billing state.
    local) printf 'free\n'; return ;;
    or|tokenrouter|gi) printf 'metered\n'; return ;;          # API-key cash lanes by definition
    claudex) printf 'unknown\n'; return ;;                     # CLIProxyAPI upstream billing is not externally provable -> asks
    cc)
      if [ -n "${OSRC_ACCOUNT_DIR:-}" ]; then local CLAUDE_CONFIG_DIR="$OSRC_ACCOUNT_DIR"; export CLAUDE_CONFIG_DIR; fi
      # Native Claude Code: per-use evidence FIRST — an API key, an auth token, a base-URL
      # redirect, BEDROCK/VERTEX, or a settings.json key helper all bill cash even when a
      # claude.ai plan login also exists. Only a proven plan login with none of those is
      # subscription; a bare `claude` on PATH proves nothing.
      if _osrc_billing_key ANTHROPIC_API_KEY || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] \
         || _osrc_anthropic_redirect "${ANTHROPIC_BASE_URL:-}" || _osrc_flag_on "${CLAUDE_CODE_USE_BEDROCK:-}" \
         || _osrc_flag_on "${CLAUDE_CODE_USE_VERTEX:-}" || _osrc_flag_on "${CLAUDE_CODE_USE_FOUNDRY:-}" \
         || _osrc_claude_settings_metered; then
        printf 'metered\n'
      elif _osrc_claude_plan_login; then printf 'subscription\n'
      elif [ -n "${OSRC_ACCOUNT_DIR:-}" ] && _osrc_account_console; then printf 'metered\n'
      else printf 'unknown\n'; fi; return ;;
    cx|ci)   # ci rides the same codex-native auth as cx
      # Native Codex: OPENAI_API_KEY/CODEX_API_KEY (env) or an api-key auth.json bills cash;
      # OPENAI_BASE_URL redirects billing. Per-use evidence wins over any plan proof: the
      # CLI's "using an API key" answer or an OPENAI_API_KEY field beats a stale token
      # file. Plan proof is the CLI's "logged in using ChatGPT" or an OAuth access_token.
      # auth.json lives at ${CODEX_HOME:-$HOME/.codex} — the engine honours CODEX_HOME
      # elsewhere (parity-codex writes there), so billing must too. A definitive "not
      # logged in" beats a stale token file; {} / garbage / tokenless shapes are evidence
      # of NEITHER and fall through, never guessed subscription.
      if _osrc_billing_key OPENAI_API_KEY || _osrc_billing_key CODEX_API_KEY \
         || [ -n "${OPENAI_BASE_URL:-}" ]; then printf 'metered\n'; return; fi
      local _cs="" _cxj="${CODEX_HOME:-$HOME/.codex}/auth.json"
      if have codex; then
        # codex may print the status on stderr; capture both.
        _cs="$(_timeout "${OSRC_BRIEF_TIMEOUT:-5}" codex login status 2>&1)"
        if grep -qi "api key" <<<"$_cs"; then printf 'metered\n'; return; fi
      fi
      if [ -f "$_cxj" ] && have jq \
         && jq -e '.OPENAI_API_KEY // empty' "$_cxj" >/dev/null 2>&1; then
        printf 'metered\n'; return
      fi
      if grep -qi "not logged in" <<<"$_cs"; then printf 'unknown\n'; return; fi
      if grep -qi "logged in using chatgpt" <<<"$_cs"; then printf 'subscription\n'; return; fi
      if [ -f "$_cxj" ] && have jq \
         && jq -e '.tokens.access_token | select(type == "string" and length > 0)' \
              "$_cxj" >/dev/null 2>&1; then
        printf 'subscription\n'; return
      fi
      printf 'unknown\n'; return ;;
    gm)
      # Stored Antigravity keys still count. Keyless dispatch removes ambient API keys.
      if _osrc_dir_key_material "$HOME/.antigravity"; then printf 'metered\n'
      # Dir existence alone is not proof (same class as the credentials fix): a real
      # login writes at least one non-empty STATE file. Dotfiles (.DS_Store), argv.json
      # (written by an editor install before any sign-in) and logs do not count — only
      # a named state file does. Residual: the exact login filename is unverified
      # against a real install (r11 F4/F5 note in the hand-in).
      elif have agy && [ -d "$HOME/.antigravity" ] \
           && [ -n "$(find "$HOME/.antigravity" -maxdepth 1 -type f -size +0c \
                        ! -name '.*' ! -name 'argv.json' ! -name '*.log' \
                        -print -quit 2>/dev/null)" ]; then
        printf 'subscription\n'
      # agy keeps its Google sign-in under ~/.gemini, not ~/.antigravity (Antigravity is a
      # subscription lane; checking only ~/.antigravity labelled a signed-in plan "unknown" = paid).
      # The token file is not stable (agy rotated it away overnight), so a Google OAuth login with a
      # refresh token in ~/.gemini/oauth_creds.json counts too. API keys are judged by the branch above.
      elif have agy && { [ -s "${GEMINI_DIR:-$HOME/.gemini}/antigravity-cli/antigravity-oauth-token" ] \
           || jq -e '(.refresh_token // "") | length > 0' "${GEMINI_DIR:-$HOME/.gemini}/oauth_creds.json" >/dev/null 2>&1; }; then
        printf 'subscription\n'
      elif _osrc_billing_key GEMINI_API_KEY || _osrc_billing_key GOOGLE_API_KEY; then
        printf 'metered\n'
      else printf 'unknown\n'; fi; return ;;
    dv)
      # Devin: live-catalog Free (or the two-id offline fallback) rides the plan; every other
      # model draws the paid ACU balance -> metered. No CLI -> unprovable -> unknown.
      have devin || { printf 'unknown\n'; return; }
      # No explicit model -> the lane's RUN-TIME default (live-catalog Free pick,
      # offline swe-2-high), never the script-level DEFAULT_MODEL which can name a
      # metered model and misclassify a bare `run` as paid.
      local _m="${model:-}"
      [ -n "$_m" ] || _m="$(_devin_default_free_model 2>/dev/null)"
      [ -n "$_m" ] || _m='swe-2-high'
      if _osrc_devin_free_for_spend "$_m" 2>/dev/null; then printf 'subscription\n'; else printf 'metered\n'; fi
      return ;;
    cursor)
      # Cursor plan login is only provable via credential evidence; a bare cursor-agent on
      # PATH (e.g. installed but never logged in) is unknown. API key -> metered, whether
      # exported or stored as api-key material inside ~/.cursor's auth files.
      if _osrc_billing_key CURSOR_API_KEY || _osrc_dir_key_material "$HOME/.cursor"; then printf 'metered\n'
      elif { have cursor-agent || have agent; } && _osrc_dir_auth "$HOME/.cursor"; then printf 'subscription\n'
      else printf 'unknown\n'; fi; return ;;
    grokbot) printf 'unknown\n'; return ;;                  # keyed webhook: billing not externally provable
    droid|warp)
      # Factory/Warp plans are subscriptions proven by their auth dirs; BYOK keys bill cash.
      # A configured provider key — exported OR stored as api-key material inside the lane's
      # own auth dir — means metered; CLI+auth-dir without key material means subscription;
      # CLI alone or nothing provable means unknown.
      local _osrc_kd=""
      [ "$lane" = droid ] && _osrc_kd="$HOME/.factory"
      [ "$lane" = warp ] && _osrc_kd="$HOME/.warp"
      if _osrc_billing_key ANTHROPIC_API_KEY || _osrc_billing_key OPENAI_API_KEY \
         || _osrc_billing_key GEMINI_API_KEY || _osrc_billing_key GOOGLE_API_KEY \
         || _osrc_billing_key OPENROUTER_API_KEY \
         || { [ -n "$_osrc_kd" ] && _osrc_dir_key_material "$_osrc_kd"; }; then printf 'metered\n'
      elif [ "$lane" = droid ] && have droid && _osrc_dir_auth "$HOME/.factory"; then printf 'subscription\n'
      elif [ "$lane" = warp ] && have oz && _osrc_dir_auth "$HOME/.warp"; then printf 'subscription\n'
      else printf 'unknown\n'; fi; return ;;
    cline)
      # ClinePass subscription OR keys in ~/.cline. Keys present -> metered; a proven login
      # dir without keys -> subscription; nothing provable -> unknown.
      if [ -d "$HOME/.cline" ] && grep -rqsE '"(apiKey|api_key|key)"[[:space:]]*:[[:space:]]*"[^"]{8,}"' "$HOME/.cline" 2>/dev/null; then
        printf 'metered\n'
      elif have cline && _osrc_dir_auth "$HOME/.cline"; then printf 'subscription\n'
      else printf 'unknown\n'; fi; return ;;
    hermes|pi) printf 'unknown\n'; return ;;                  # provider/auth not externally provable
    *) printf 'unknown\n'; return ;;
  esac
}

# ---- spend consent ------------------------------------------------------------

# _osrc_spend_ok [lane] [model] -> rc0 when THIS command carries spend consent:
# --spend-ok parsed into OSRC_SPEND_OK (env-inherited values are unset by the env
# block before parse, so they can never reach here), or the per-job .spend-ok
# marker a consenting bg parent wrote for its detached child.
#
# The marker is accepted ONLY in the real detached-job context: OSRC_JOB_DIR must
# name a job dir directly under $OSRC_JOBS (single path component, no traversal —
# an arbitrary inherited OSRC_JOB_DIR consents nothing), and OSRC_JOB_TOKEN must
# equal the per-job secret the parent exported to that child alone (delegates get
# it scrubbed with OSRC_JOB_DIR at spawn, so a nested call cannot borrow it).
# The marker file itself must carry that token on its header line, so a marker
# copied into a forged dir — or left behind by a sibling job — matches nothing.
#
# Consent is BOUND to the exact lane|model pair: both sides must be non-empty,
# "*" is never a wildcard, and an empty resolved model cannot ride a marker.
# On a match the path is recorded in _OSRC_SPEND_MARKER so the gate can consume
# (delete) it once dispatch starts — consent is single-use.
_OSRC_SPEND_MARKER=""
_osrc_spend_ok() {
  local lane="${1:-}" model="${2:-}"
  if [ "${OSRC_SPEND_OK:-0}" = "1" ]; then
    if [ -n "${_OSRC_SPEND_BOUND_LANE:-}" ]; then
      [ "$_OSRC_SPEND_BOUND_LANE" = "$lane" ] && [ "${_OSRC_SPEND_BOUND_MODEL:-}" = "$model" ] || return 1
    fi
    # A supervised job's marker limits even a forwarded flag to its approved pair.
    local _jd="${OSRC_JOB_DIR:-}" _jobs="${OSRC_JOBS:-${OSRC_HOME:-}/jobs}" _rest _mf _header _l _m _match=0
    case "$_jd" in "$_jobs"/*)
      _rest="${_jd#"$_jobs"/}"
      case "$_rest" in ""|.|*/*|*..*) ;; *)
        _mf="$_jd/.spend-ok"
        if [ ! -L "$_jd" ] && [ -f "$_mf" ] && [ -n "${OSRC_JOB_TOKEN:-}" ]; then
          IFS= read -r _header < "$_mf"
          [ "$_header" = "#osrc-spend-ok token=$OSRC_JOB_TOKEN" ] || return 1
          while IFS='|' read -r _l _m; do
            [ "$_l" = "$lane" ] && [ -n "$_m" ] && [ "$_m" = "$model" ] && _match=1
          done < "$_mf"
          [ "$_match" = 1 ] || return 1
          rm -f "$_mf" 2>/dev/null || true
        elif [ "${_job_child:-0}" = 1 ] && [ -z "${_OSRC_SPEND_BOUND_LANE:-}" ]; then
          return 1
        fi ;;
      esac ;;
    esac
    return 0
  fi
  local jd="${OSRC_JOB_DIR:-}" tok="${OSRC_JOB_TOKEN:-}"
  [ -n "$jd" ] && [ -n "$tok" ] || return 1
  local jobs="${OSRC_JOBS:-${OSRC_HOME:-}/jobs}" rest
  case "$jd" in "$jobs"/*) ;; *) return 1 ;; esac
  rest="${jd#"$jobs"/}"
  case "$rest" in ""|.|*/*|*..*) return 1 ;; esac
  local mf="$jd/.spend-ok" l m mtok="" _hd
  [ -f "$mf" ] || return 1
  _hd="$(head -n 1 "$mf" 2>/dev/null)"
  case "$_hd" in "#osrc-spend-ok token="*) mtok="${_hd#*=}" ;; *) return 1 ;; esac
  [ -n "$mtok" ] && [ "$mtok" = "$tok" ] || return 1
  [ -n "$lane" ] && [ -n "$model" ] || return 1
  while IFS='|' read -r l m; do
    [ -n "$l" ] && [ "$l" = "$lane" ] || continue
    [ -n "$m" ] && [ "$m" != "*" ] && [ "$m" = "$model" ] \
      && { _OSRC_SPEND_MARKER="$mf"; return 0; }
  done < "$mf"
  return 1
}

# _osrc_lane_spendable <lane> [model] -> rc0 when the lane may be used WITHOUT asking:
# billing subscription|free, or spend consent already granted for this command. Fallback
# pickers call this so auto-routing never lands on a metered lane quietly.
_osrc_lane_spendable() {
  local b; b="$(osrc_lane_billing "${1:-}" "${2:-}" 2>/dev/null)"
  case "$b" in subscription|free) return 0 ;; esac
  _osrc_spend_ok "${1:-}" "${2:-}"
}

# Failover skip tracking (engine _failover_* calls these; they live here for the
# engine-size budget and because they feed the spend-consent stop message). The
# picker runs under a command substitution, so skipped lanes are recorded in a
# per-process file — $$ is shared by $( ) subshells, one file per route_delegate
# call after the matching _failover_*_clear.
_failover_cash_file() { printf '%s/.failover.cash.%s' "$OSRC_HOME" "$$"; }
_failover_cash_skipped() { local _cf; _cf="$(_failover_cash_file)"; [ -f "$_cf" ] || return 0; tr '\n' ' ' < "$_cf" 2>/dev/null | sed -E 's/[[:space:]]+$//'; }
_failover_cash_clear() { rm -f "$(_failover_cash_file)" 2>/dev/null; }
_failover_cash_record() {  # <lane> — remember a skipped cash lane for the stop line
  local l="${1:-}"; case " $_FAILOVER_CASH_SKIPPED " in *" $l "*) return 0 ;; esac
  _FAILOVER_CASH_SKIPPED="${_FAILOVER_CASH_SKIPPED:+$_FAILOVER_CASH_SKIPPED }$l"
  ( umask 077; printf '%s\n' "$l" >> "$(_failover_cash_file)" ) 2>/dev/null || true
}
# Spend-blocked lanes (metered/unknown billing, ANY cost class) — same mechanism.
_failover_spend_file() { printf '%s/.failover.spend.%s' "$OSRC_HOME" "$$"; }
_failover_spend_skipped() { local _sf; _sf="$(_failover_spend_file)"; [ -f "$_sf" ] || return 0; tr '\n' ' ' < "$_sf" 2>/dev/null | sed -E 's/[[:space:]]+$//'; }
_failover_spend_clear() { rm -f "$(_failover_spend_file)" 2>/dev/null; }
_failover_spend_record() {  # <lane> — remember a spend-blocked lane for the stop line
  local l="${1:-}"; case " $_FAILOVER_SPEND_SKIPPED " in *" $l "*) return 0 ;; esac
  _FAILOVER_SPEND_SKIPPED="${_FAILOVER_SPEND_SKIPPED:+$_FAILOVER_SPEND_SKIPPED }$l"; ( umask 077; printf '%s\n' "$l" >> "$(_failover_spend_file)" ) 2>/dev/null || true
}
# Both skip-marker files for THIS process — call once the hop decision consumed them
# (or abandoned them) so they never linger past their seconds-long lifetime.
_failover_skip_clear() { _failover_cash_clear; _failover_spend_clear; }

# _osrc_spend_marker_pairs <provider> [inner-args...] -> prints the exact "lane|model"
# lines a bg job's .spend-ok marker should carry. The detached child re-resolves its
# own lane/model from the inner argv, so the parent writes every plausible EXACT pair:
# the provider-resolved lane with the -m/--model token (raw, plus the alias-table
# resolved id when known), an inner --provider override's lane the same way, and —
# when no model was given — the lane's own default model. NEVER a wildcard: "*" or an
# empty model field would authorize models the consenting command never named.
# Best-effort: pairs the parent cannot prove are simply absent, and the child's gate
# then refuses closed with a runnable NEXT.
_osrc_spend_marker_pairs() {
  local prov="${1:-}"; shift || true
  local iprov="$prov" imodel="" row rl ri
  _osrc_marker_lane() {  # <provider-token> -> lane code or the token itself
    local p="${1:-}" l
    l="$(_lane_by_provider "$p" 2>/dev/null)"; [ -n "$l" ] || l="$(_lane_by_native "$p" 2>/dev/null)"
    [ -n "$l" ] || l="$(_lane_by_token "$p" 2>/dev/null)"
    printf '%s' "${l:-$p}"
  }
  _osrc_marker_emit() {  # <provider-token> <model-token|"">
    local pl mt dm
    pl="$(_osrc_marker_lane "$1")"; mt="${2:-}"
    if [ -n "$mt" ]; then
      printf '%s|%s\n' "$pl" "$mt"                     # raw token on the provider lane
      row="$(resolve_model_row "$mt" 2>/dev/null)"
      if [ -n "$row" ]; then
        ri="${row%%|*}"; rl="${row#*|}"; rl="${rl%%|*}"
        [ -n "$rl" ] && printf '%s|%s\n' "$rl" "$ri"    # alias-resolved lane|id
      fi
    else
      # No -m: the child will dispatch the lane's own default — bind THAT, never "*".
      dm="$(_route_provider_default_model "$1" 2>/dev/null)"
      [ -n "$dm" ] && printf '%s|%s\n' "$pl" "$dm"
    fi
  }
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider)   [ -n "${2:-}" ] && { iprov="$2"; shift; } ;;
      --provider=*) iprov="${1#--provider=}" ;;
      -m|--model)   [ -n "${2:-}" ] && { imodel="$2"; shift; } ;;
      --model=*)    imodel="${1#--model=}" ;;
      -m?*)         imodel="${1#-m}" ;;
    esac
    shift
  done
  _osrc_marker_emit "$prov" "$imodel"
  [ "$iprov" != "$prov" ] && _osrc_marker_emit "$iprov" "$imodel"
}

# _osrc_spend_marker_write <jobdir> <provider> [inner-args...] -> drop the bound
# consent marker for a consenting bg launch. No-op unless OSRC_SPEND_OK=1. The
# header line carries OSRC_JOB_TOKEN — the per-job secret run_job exports to this
# child alone — so the marker consents only inside its own job's process.
_osrc_spend_marker_write() {
  local jd="${1:-}" prov="${2:-}"; shift 2 || true
  [ "${OSRC_SPEND_OK:-0}" = "1" ] && [ -n "$jd" ] && [ -n "${OSRC_JOB_TOKEN:-}" ] || return 0
  local mf="$jd/.spend-ok"
  ( umask 077
    printf '#osrc-spend-ok token=%s\n' "$OSRC_JOB_TOKEN"
    if [ -n "${_OSRC_PREFLIGHT_PAIR:-}" ]; then
      printf '%s\n' "$_OSRC_PREFLIGHT_PAIR"
    else
      _osrc_spend_marker_pairs "$prov" "$@"
    fi
  ) > "$mf" 2>/dev/null || true
  [ -s "$mf" ] || rm -f "$mf" 2>/dev/null
}

# Buffer diagnostics while fd 5 keeps an interactive spend prompt on the terminal.
_osrc_bg_preflight() { _osrc_bg_preflight_capture "$@" 5>&2; }
_osrc_bg_preflight_capture() {
  local buf pair tail rc=0 _osrc_preflight_key
  export -n _osrc_preflight_key
  _osrc_preflight_key="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  [ "${#_osrc_preflight_key}" = 32 ] || return 1
  buf="$({ pair="$(BASH_ENV= ENV= OSRC_NO_ADVISE=1 "${BASH:-bash}" -c 'set +x; export -n _osrc_preflight_key; IFS= read -r _osrc_preflight_key <&4 || exit 1; exec 4<&-; . "$0" "$@"' "$@" --osrc-preflight-internal --osrc-preflight-pair-fd ${_pf_provider[@]+"${_pf_provider[@]}"} ${_pf_spend[@]+"${_pf_spend[@]}"} ${_pf_args[@]+"${_pf_args[@]}"} 4<<<"$_osrc_preflight_key" 3>&-)"; rc=$?; pair="${pair##*$'\n'}"; printf '\n__OSRC_PAIR__%s\n' "$pair"; exit "$rc"; } 2>&1)" || rc=$?
  tail="${buf##*$'\n'}"
  case "$tail" in __OSRC_PAIR__*) pair="${tail#__OSRC_PAIR__}" ;; *) return 1 ;; esac
  if [ "$rc" -ne 0 ]; then buf="${buf%$'\n'*}"; printf '%s\n' "$buf" | grep -aE 'ERROR:|^EVENT |^NEXT ' | head -6 >&2; return "$rc"; fi
  pair="${pair##*$'\n'}"
  case "$pair" in "__OSRC_ROUTE__$_osrc_preflight_key|"*) pair="${pair#"__OSRC_ROUTE__$_osrc_preflight_key|"}" ;; *) return 1 ;; esac
  printf '%s\n' "$pair"
  return "$rc"
}

# ---- event emission (lanes/events.jsonl contract) ---------------------------
# Schema matches lib/supervise.sh's _sv_append: {ts,kind,target,detail,next,src}.
# Prints the `EVENT <kind> <target> <ts> <detail>` + `NEXT <cmd>` pair supervise replays.
_osrc_event() {  # <kind> <target> <detail> <next> [src]
  local kind="$1" target="$2" detail="$3" next="$4" src="${5:-spend}"
  local ts; ts="$(date +%s 2>/dev/null || echo 0)"
  local f="$OSRC_HOME/lanes/events.jsonl"
  _mkdir_private "$OSRC_HOME/lanes" >/dev/null 2>&1 || true
  if have jq; then
    jq -cn --argjson ts "$ts" --arg k "$kind" --arg t "$target" --arg d "$detail" \
      --arg n "$next" --arg s "$src" \
      '{ts:$ts,kind:$k,target:$t,detail:$d,next:$n,src:$s}' >> "$f" 2>/dev/null || true
  else
    # jq-less fallback: single-line JSON with quotes/backslashes stripped from detail.
    local d1; d1="$(printf '%s' "$detail" | tr '\n"\\' '   ' | cut -c1-300)"
    local n1; n1="$(printf '%s' "$next" | tr '\n"\\' '   ' | cut -c1-300)"
    printf '{"ts":%s,"kind":"%s","target":"%s","detail":"%s","next":"%s","src":"%s"}\n' \
      "$ts" "$kind" "$target" "$d1" "$n1" "$src" >> "$f" 2>/dev/null || true
  fi
  printf 'EVENT %s %s %s %s\n' "$kind" "$target" "$ts" "$detail"
  printf 'NEXT %s\n' "$next"
}

# _osrc_spend_gate <lane> <model> <disp> <why> -> the paid-lane gate. Unconditional:
# callers invoke it on EVERY dispatch path, including when lane resolution came back
# empty (an unresolvable lane is billing=unknown -> asks, never silently dispatches).
# rc0 proceed (free/subscription, consented). Dies on refusal; the caller treats any
# non-zero as "do not dispatch" and invokes the gate BEFORE any side effects.
_osrc_spend_gate() {
  local lane="${1:-}" model="${2:-}" disp="${3:-}" why="${4:-launch}"
  local bill; bill="$(osrc_lane_billing "$lane" "$model" "$disp" 2>/dev/null)"
  # Devin bills per model: a caller that cannot name the model it launches (a picker choice)
  # gets no Free default. Launch paths with no -m pass the default id itself (lib/spend-paths.sh).
  case "$lane" in dv|devin) [ -n "$model" ] || bill=unknown ;; esac
  # unknown is treated as METERED everywhere — cloud sessions included. A hosted
  # session's plan login is proven by the same billing probes as a local launch
  # (claude auth status / codex login status / devin catalog), and hosted-session
  # consent never substitutes for spend approval (CONTRACT.md).
  case "$bill" in subscription|free)
    if [ "${OSRC_SPEND_OK:-0}" = 1 ] && [ -z "${_OSRC_SPEND_BOUND_LANE:-}" ]; then
      _OSRC_SPEND_BOUND_LANE="$lane"; _OSRC_SPEND_BOUND_MODEL="$model"
    fi
    _osrc_preflight_record "$lane" "$model" "${OSRC_SPEND_OK:-0}"
    return 0 ;;
  esac
  local lname; lname="$(_lane_plan_display "$lane" 2>/dev/null)"; [ -n "$lname" ] || lname="$lane"
  # Show the model actually being dispatched; when none was resolved, the lane's own
  # default — never DEFAULT_MODEL, which is the SCRIPT's default and can name a
  # different engine's model entirely (the `paid-lane:cc/glm-5.2` lie).
  local mname; mname="${model:-}"
  [ -n "$mname" ] || mname="$(_lane_field "$lane" default_model 2>/dev/null)"
  [ -n "$mname" ] || mname="default"
  if _osrc_spend_ok "$lane" "$model"; then
    _OSRC_SPEND_BOUND_LANE="$lane"; _OSRC_SPEND_BOUND_MODEL="$model"
    _osrc_preflight_record "$lane" "$model" 1
    # Marker consent is single-use: consume it now that dispatch is committed, so it
    # cannot authorize a second launch (or leak into a sibling job via a shared dir).
    [ "${OSRC_SPEND_OK:-0}" != "1" ] && [ -n "$_OSRC_SPEND_MARKER" ] \
      && rm -f "$_OSRC_SPEND_MARKER" 2>/dev/null
    printf '>>> [spend] %s lane (%s / %s) bills %s — proceeding on this command'"'"'s spend consent.\n' \
      "$lname" "$disp" "$mname" "$bill" >&2
    return 0
  fi
  # Estimate when one exists (metered lanes price per-token in the catalog).
  local est="" mcost
  mcost="$(_lane_marginal_cost "$lane" "$mname" 1000 2>/dev/null)"
  case "$mcost" in ''|*[!0-9.]*) ;; *) est="$mcost" ;; esac
  local detail="paid-lane:$lane/$mname ($bill) — $why"
  local nexthint="${OSRC_SPEND_NEXT:-$0 --spend-ok}"
  if [ -t 0 ] && { [ -t 2 ] || { [ "${_OSRC_PREFLIGHT_FD:-0}" = 1 ] && [ -t 5 ]; }; }; then
    local prompt_fd=2; [ "${_OSRC_PREFLIGHT_FD:-0}" = 1 ] && [ -t 5 ] && prompt_fd=5
    printf '>>> [spend] PAID LANE: %s (%s) / %s bills %s%s.\n' "$lname" "$disp" "$mname" "$bill" "${est:+ — est $est}" >&"$prompt_fd"
    printf '>>>   why: %s. This lane is not subscription/free; approve spend for THIS command only.\n' "$why" >&"$prompt_fd"
    local ans=""; IFS= read -r ans || ans=""
    case "$ans" in
      y|Y|yes|YES)
        OSRC_SPEND_OK=1
        _OSRC_SPEND_BOUND_LANE="$lane"; _OSRC_SPEND_BOUND_MODEL="$model"
        _osrc_preflight_record "$lane" "$model" 1
        printf '>>> [spend] approved for this command only (never persisted).\n' >&"$prompt_fd"
        return 0 ;;
    esac
    _osrc_event approval "${lane:-launch}" "$detail" "$nexthint" spend >&2
    die "spend gate: declined paid lane $lname ($disp / $mname, billing=$bill). Re-run with --spend-ok to approve this one command, or pick a subscription/free lane."
  fi
  _osrc_event approval "${lane:-launch}" "$detail" "$nexthint" spend >&2
  die "spend gate: $lname ($disp / $mname) bills $bill and this run is non-interactive — refusing rather than spending silently. Re-run with --spend-ok to approve THIS command only (never persisted), or pick a subscription/free lane."
}

# _osrc_session_spend_gate -> session-start form: resolves PROVIDER to its native
# lane + the session model, then runs the same gate (no hop concept; consent or refuse).
# NOTE the lane-resolution chain uses [ -n ] tests, not bare ||, so a lookup that prints
# nothing cannot empty $lane and skip the remaining fallbacks (the `lane cap codex` bug class).
_osrc_session_spend_gate() {
  local _sp_p="${PROVIDER:-}" _sp_lane="" _sp_model="${MODEL:-}"
  _sp_lane="$(_lane_by_native "$_sp_p" 2>/dev/null)"; [ -n "$_sp_lane" ] || _sp_lane="$(_lane_by_token "$_sp_p" 2>/dev/null)"; [ -n "$_sp_lane" ] || _sp_lane=""
  [ -n "$_sp_lane" ] || _sp_lane="$_sp_p"
  # NEXT = the refused command verbatim + --spend-ok right after `start` (built from
  # the user's original argv snapshot; an inherited parent NEXT wins — a job child's
  # refusal must forward the OUTER command, not a session-flavored rebuild).
  if [ -z "${OSRC_SPEND_NEXT:-}" ]; then
    if type _osrc_spend_next_build >/dev/null 2>&1; then
      _osrc_spend_next_build start
    else
      OSRC_SPEND_NEXT="$0 --spend-ok session start ${_sp_p:+--provider $_sp_p} ${MODEL:+-m $MODEL}"
    fi
  fi
  _osrc_spend_gate "$_sp_lane" "$_sp_model" "$_sp_p" "interactive session start"
}

# _osrc_spend_next_build <verb> [fallback-args...] -> OSRC_SPEND_NEXT = the user's
# ORIGINAL command with --spend-ok inserted directly after <verb>. NEXT must equal
# the refused command plus consent: rebuilding from post-parse state used to drop
# --provider/--cloud-ack/-m and append consent after the task text, producing a
# NEXT that routed to a different lane or model than the EVENT named. The verb is
# the first argv token equal to <verb> in main()'s _OSRC_USER_ARGV snapshot
# (sentinels stripped, global flags intact, original order preserved); an existing
# --spend-ok token is left alone rather than doubled. %q keeps it copy-paste safe.
# With no snapshot (direct internal calls) it falls back to "$0 <verb> --spend-ok
# <args>". Lives here (not the engine) for the engine-size budget; callers: main(),
# cmd_bg, _osrc_session_spend_gate.
_osrc_spend_next_build() {
  local verb="${1:-}"; shift || true
  [ -n "$verb" ] || return 1
  local out="$0" a seen=0 had=0
  if [ "${_OSRC_USER_ARGV+set}" = "set" ] && [ "${#_OSRC_USER_ARGV[@]}" -gt 0 ]; then
    for a in "${_OSRC_USER_ARGV[@]}"; do [ "$a" = "--spend-ok" ] && had=1; done
    for a in "${_OSRC_USER_ARGV[@]}"; do
      out="$out $(printf '%q' "$a")"
      [ "$had" = 0 ] && [ "$seen" = 0 ] && [ "$a" = "$verb" ] && { out="$out --spend-ok"; seen=1; }
    done
    [ "$seen" = 0 ] && [ "$had" = 0 ] && out="$out --spend-ok"
  else
    out="$out $verb --spend-ok"
    for a in "$@"; do out="$out $(printf '%q' "$a")"; done
  fi
  OSRC_SPEND_NEXT="$out"
}

# _osrc_route_launched_model -> the model id the delegate will actually launch with
# for the current route (reads route_delegate's dynamic scope: ROUTE_LANE, ROUTE_MODEL,
# RESOLVED_ID, MODEL). dv/droid/warp re-resolve at dispatch — delegate_devin runs
# _devin_resolve_model on the raw -m token (live catalog: family kimi -> kimi-k9-free),
# the engine lanes run _lane_model_for — so the RESOLVED receipt must print THAT id,
# not the family/alias the route table resolved. Every other lane launches
# RESOLVED_ID verbatim. Lives here for the engine-size budget; caller: _route_receipt.
_osrc_route_launched_model() {
  local rid="${RESOLVED_ID:-${ROUTE_MODEL:-}}"
  case "${ROUTE_LANE:-}" in
    devin|dv)   rid="${_OSRC_DV_LAUNCH_ID:-$(_devin_resolve_model "${MODEL:-}" 2>/dev/null)}" ;;   # the gated launch id
    droid|warp) rid="$(_lane_model_for "$ROUTE_LANE" "${RESOLVED_ID:-${MODEL:-}}" 2>/dev/null)" ;;
  esac
  printf '%s' "${rid:-${RESOLVED_ID:-${ROUTE_MODEL:-}}}"
}

# _osrc_envrun [-u NAME]... [NAME=VALUE]... CMD [ARGS...] -> run CMD with the listed
# vars unset (-u) or overridden (NAME=VALUE, exported like env(1) assignments), then
# restore EVERY touched var to its exact prior state — value AND export attribute —
# and return CMD's rc. env(1) cannot do this job: it execs the real binary, so
# shell-function mocks of delegate CLIs never run. Running CMD in-shell keeps function
# resolution AND keeps the vars out of the child's environment. Each var's declaration
# is snapshotted with declare -p and replayed through eval, which is bash-3.2-safe
# (no nameref/${var@a}); a var set-but-unexported before stays unexported after.
# Arrays and integer-attributed vars are NOT restored (declare -p output for them is
# not replayed faithfully); no caller passes one today — every scrubbed name is a
# plain string. If a future caller needs one, extend the snapshot first.
# NOTE: while CMD runs the vars are changed in THIS shell too (dynamic scope) — no
# EXIT/TERM/signal trap handler may read them; restore happens only after CMD returns.
_osrc_envrun() {
  local _er_unset=() _er_set=() _er_names=() _er_sv=() _er_a _er_d _er_i=0 _er_rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -u)  shift; [ $# -gt 0 ] && _er_unset+=("$1"); shift ;;
      --)  shift; break ;;
      *=*) _er_set+=("$1"); shift ;;
      *)   break ;;
    esac
  done
  [ $# -gt 0 ] || return 127
  for _er_a in ${_er_unset[@]+"${_er_unset[@]}"}; do _er_names+=("$_er_a"); done
  for _er_a in ${_er_set[@]+"${_er_set[@]}"}; do _er_names+=("${_er_a%%=*}"); done
  for _er_a in ${_er_names[@]+"${_er_names[@]}"}; do
    if _er_d="$(declare -p "$_er_a" 2>/dev/null)"; then _er_sv+=("$_er_d"); else _er_sv+=("unset"); fi
  done
  for _er_a in ${_er_unset[@]+"${_er_unset[@]}"}; do unset "$_er_a" 2>/dev/null || true; done
  for _er_a in ${_er_set[@]+"${_er_set[@]}"}; do export "$_er_a"; done
  "$@"; _er_rc=$?
  for _er_a in ${_er_names[@]+"${_er_names[@]}"}; do
    _er_d="${_er_sv[$_er_i]}"; _er_i=$((_er_i+1))
    case "$_er_d" in
      unset) unset "$_er_a" 2>/dev/null || true ;;
      "declare -x "*)
        case "$_er_d" in
          *"="*) eval "export ${_er_d#declare -x }" ;;
          *)     eval "unset $_er_a 2>/dev/null; export $_er_a" ;;
        esac ;;
      "declare -- "*) eval "${_er_d#declare -- }"; export -n "$_er_a" 2>/dev/null || true ;;
      "declare "*)    eval "$_er_d"; export -n "$_er_a" 2>/dev/null || true ;;
      *)              eval "$_er_d" ;;
    esac
  done
  return "$_er_rc"
}

# _osrc_nojob <cmd...> -> run the command with OSRC_JOB_DIR and OSRC_JOB_TOKEN UNSET,
# then restore them exactly, returning the command's rc. Delegates must never inherit
# the job env (a nested outsourcerer call would see THIS job's .spend-ok marker and
# cap-dedupe state as its own consent context). See _osrc_envrun for the mechanism
# and the trap caveat (vars are unset in this shell while the command runs).
_osrc_nojob() { _osrc_envrun -u OSRC_JOB_DIR -u OSRC_JOB_TOKEN "$@"; }

# _osrc_claude_plan_login -> rc0 ONLY when `claude auth status` proves a claude.ai PLAN
# login. The CLI's exit code is captured FIRST: a non-zero exit is not proof even if
# JSON was printed (rc1 -> billing unknown, the spend gate asks). The CLI pretty-prints
# its status (JSON.stringify(_, null, 2) — ~16 indented lines), so the WHOLE output is
# parsed as a JSON stream, never line-by-line: sed drops anything before the first line
# that opens a JSON object (a warning banner cannot poison the parse) and jq's stream
# reader takes the first object via first(), which stops before any trailing junk the
# CLI may print after the payload (update notices, stub PONG lines). That object must carry loggedIn==true,
# authMethod=="claude.ai", apiProvider=="firstParty", apiKeySource==null (a key/helper
# source configured beside the plan login bills per-use — the CLI reports it in this
# field, covering settings.local.json and project settings the file check cannot see),
# and a subscriptionType that is a known plan (pro|max|team|enterprise,
# case-insensitive) or a variant starting with one (max_20x); anything else is not
# proof. KNOWN LIMIT (r11 F6, as specified): the prefix rule trusts names nobody has
# seen — pro_api or team_premium classify plan while "maximum" does not. If tighter
# proof is ever wanted the CLI's planTier field is the candidate; until then the
# prefix list is the documented contract. jq emits only the verdict word or nothing — email, org, ids and tokens are
# never printed, cached or logged. A credentials file or keychain entry existing proves
# a login was once written, not what it bills, so neither is consulted. The probe runs
# under _osrc_envrun -u CLAUDECODE so an orchestrator's nested-session marker cannot
# make the CLI misreport its login.
_osrc_claude_plan_login() {
  have claude && have jq || return 1
  local _out _rc
  _out="$(_osrc_envrun -u CLAUDECODE _timeout "${OSRC_BRIEF_TIMEOUT:-5}" claude auth status 2>/dev/null)"; _rc=$?
  [ "$_rc" -eq 0 ] || return 1
  [ "$(printf '%s\n' "$_out" | sed -n '/^[[:space:]]*{/,$p' | jq -n -r '
    first(inputs | objects) |
    if (.loggedIn == true) and (.authMethod == "claude.ai") and (.apiProvider == "firstParty")
       and (.apiKeySource == null)
       and ((.subscriptionType | tostring | ascii_downcase) as $st |
            ($st == "pro" or $st == "max" or $st == "team" or $st == "enterprise"
             or ($st | (startswith("pro_") or startswith("pro-") or startswith("max_") or startswith("max-")
                        or startswith("team_") or startswith("team-") or startswith("enterprise_") or startswith("enterprise-")))))
    then "plan" else "" end' 2>/dev/null)" = "plan" ]
}

# osrc_limits_summary — the limits feed's ORIGINAL name (pre-rename callers, CONTRACT).
# The implementation moved to lib/limits.sh with the rest of the meter readers; this
# alias keeps the old entry point working. `lane summary` is the CLI surface.
osrc_limits_summary() { osrc_lane_summary "$@"; }
