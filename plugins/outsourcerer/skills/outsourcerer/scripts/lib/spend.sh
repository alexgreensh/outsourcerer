# =============================================================================
# lib/spend.sh — paid-lane spend gate + per-lane usage caps (L7 add-ons, Alex 14:30/14:32)
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
#     `EVENT approval ... paid-lane:...` + NEXT so L1's supervise replays them.
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

# _osrc_devin_free_for_spend <model> -> rc0 ONLY when the model is proven Free for SPEND
# purposes. Live catalog first: when `devin models list` is reachable, ONLY its cost_tier="Free"
# tag counts (exact model_uid / all-Free family_uid match — never a canon guess, so a paid
# -max/-medium variant cannot ride in on a free sibling's name). Offline, the static fallback
# is exactly two proven-free ids: SWE-2 High and SWE-2 Flash High — no family aliases, so
# swe-2 / swe-2-flash / glm / anything unproven still asks. Everything else is paid and the
# spend gate asks. Stricter than _devin_is_free_model, whose plan-included static list
# answers a different question (does it draw the paid ACU balance, not "is it free to run").
_osrc_devin_free_for_spend() {
  local m="${1:-}" t ids
  t="$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]' | sed -E 's#^[^/]*/##; s/\./-/g')"
  if [ "${OSRC_FREE_CATALOG_CHECK:-1}" = "1" ]; then
    if ids="$(_devin_catalog_free_ids 2>/dev/null)"; then
      # Catalog reachable: ONLY its Free tag decides — the static fallback does not apply.
      # Normalize the catalog side identically so a dotted/uppercase uid still matches.
      ids="$(printf '%s' "$ids" | tr '[:upper:]' '[:lower:]' | sed -E 's#^[^/]*/##; s/\./-/g')"
      case " $ids " in *" $t "*) return 0 ;; *) return 1 ;; esac
    fi
  fi
  case "$t" in
    swe-2-high|swe-2-flash-high) return 0 ;;
  esac
  return 1
}

# _osrc_claude_settings_metered -> rc0 when ~/.claude/settings.json routes Claude through a
# per-use credential (apiKeyHelper script or env.ANTHROPIC_API_KEY) instead of the plan login.
_osrc_claude_settings_metered() {
  local f="$HOME/.claude/settings.json"
  [ -f "$f" ] || return 1
  if have jq; then
    jq -e '.apiKeyHelper // empty' "$f" >/dev/null 2>&1 && return 0
    jq -e '.env.ANTHROPIC_API_KEY // empty' "$f" >/dev/null 2>&1 && return 0
    return 1
  fi
  grep -q 'apiKeyHelper' "$f" 2>/dev/null && return 0
  grep -q 'ANTHROPIC_API_KEY' "$f" 2>/dev/null && return 0
  return 1
}

# osrc_lane_billing <lane|disp|provider|alias> [model] [disp] -> subscription|free|metered|unknown
# Evidence-based: `subscription` requires PROOF of a plan login (same credential evidence the
# limits feed's _osrc_harness_auth reads) AND the absence of every per-use redirect. API keys,
# auth tokens, base-URL redirects, cloud vehicles (BEDROCK/VERTEX/OPENAI_BASE_URL/claude
# settings helpers), and BYOK paths are `metered` even when a plan login also exists. A CLI on
# PATH with no provable login is `unknown` — never assumed subscription. unknown is treated as
# metered by the spend gate (ask first, never assume free). The third arg (disp/vehicle) is
# NOT display-only: a disp containing cloud|hosted is metered on any lane — L10's `cloud
# start` relies on this for hosted Devin sessions (CONTRACT.md L7 sign-off).
osrc_lane_billing() {
  local tok="${1:-}" model="${2:-}" disp="${3:-}" lane=""
  [ -n "$tok" ] || { printf 'unknown\n'; return; }
  lane="$(_lane_by_disp "$tok" 2>/dev/null)" || lane=""
  [ -n "$lane" ] || lane="$(_lane_by_token "$tok" 2>/dev/null)" || lane=""
  [ -n "$lane" ] || lane="$(_lane_by_native "$tok" 2>/dev/null)" || lane=""
  [ -n "$lane" ] || lane="$(_lane_by_provider "$tok" 2>/dev/null)" || lane=""
  [ -n "$lane" ] || { printf 'unknown\n'; return; }
  # A hosted/cloud vehicle bills per-use on whatever plan login fronts it.
  case "$disp" in *cloud*|cloud|*hosted*) printf 'metered\n'; return ;; esac
  case "$lane" in
    local) printf 'free\n'; return ;;
    or|tokenrouter|gi) printf 'metered\n'; return ;;          # API-key cash lanes by definition
    ci|claudex) printf 'subscription\n'; return ;;           # ChatGPT-plan-backed proxy lanes
    cc)
      # Native Claude Code: per-use evidence FIRST — an API key, an auth token, a base-URL
      # redirect, BEDROCK/VERTEX, or a settings.json key helper all bill cash even when a
      # claude.ai plan login also exists. Only a proven plan login with none of those is
      # subscription; a bare `claude` on PATH proves nothing.
      if _osrc_billing_key ANTHROPIC_API_KEY || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] \
         || [ -n "${ANTHROPIC_BASE_URL:-}" ] || [ "${CLAUDE_CODE_USE_BEDROCK:-}" = "1" ] \
         || [ "${CLAUDE_CODE_USE_VERTEX:-}" = "1" ] || _osrc_claude_settings_metered; then
        printf 'metered\n'
      elif have claude && _osrc_harness_auth claude; then printf 'subscription\n'
      else printf 'unknown\n'; fi; return ;;
    cx)
      # Native Codex: OPENAI_API_KEY/CODEX_API_KEY (env) or an api-key auth.json bills cash;
      # OPENAI_BASE_URL redirects billing. A ChatGPT OAuth auth.json (tokens, no api key) or a
      # `codex login status` "logged in" is the plan proof. No jq means auth.json cannot be
      # classified -> unknown, never guessed subscription.
      if _osrc_billing_key OPENAI_API_KEY || _osrc_billing_key CODEX_API_KEY \
         || [ -n "${OPENAI_BASE_URL:-}" ]; then printf 'metered\n'; return; fi
      if [ -f "$HOME/.codex/auth.json" ]; then
        if have jq; then
          if jq -e '.OPENAI_API_KEY // empty' "$HOME/.codex/auth.json" >/dev/null 2>&1; then
            printf 'metered\n'
          else printf 'subscription\n'; fi
        else printf 'unknown\n'; fi
        return
      fi
      if have codex && _timeout "${OSRC_BRIEF_TIMEOUT:-5}" codex login status 2>/dev/null \
         | grep -qi "logged in"; then printf 'subscription\n'; return; fi
      printf 'unknown\n'; return ;;
    gm)
      # agy is keyless Google app-login: subscription ONLY with the login dir present.
      # agy on PATH without ~/.antigravity proves nothing -> unknown.
      if have agy && [ -d "$HOME/.antigravity" ]; then printf 'subscription\n'
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
      # PATH (e.g. installed but never logged in) is unknown. API key -> metered.
      if _osrc_billing_key CURSOR_API_KEY; then printf 'metered\n'
      elif { have cursor-agent || have agent; } && _osrc_dir_auth "$HOME/.cursor"; then printf 'subscription\n'
      else printf 'unknown\n'; fi; return ;;
    grokbot) printf 'unknown\n'; return ;;                  # keyed webhook: billing not externally provable
    droid|warp)
      # Factory/Warp plans are subscriptions proven by their auth dirs; BYOK keys bill cash.
      # A configured provider key means metered; CLI+auth-dir means subscription; CLI alone
      # or nothing provable means unknown.
      if _osrc_billing_key ANTHROPIC_API_KEY || _osrc_billing_key OPENAI_API_KEY \
         || _osrc_billing_key GEMINI_API_KEY || _osrc_billing_key GOOGLE_API_KEY \
         || _osrc_billing_key OPENROUTER_API_KEY; then printf 'metered\n'
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
  [ "${OSRC_SPEND_OK:-0}" = "1" ] && return 0
  local jd="${OSRC_JOB_DIR:-}" tok="${OSRC_JOB_TOKEN:-}"
  [ -n "$jd" ] && [ -n "$tok" ] || return 1
  local jobs="${OSRC_JOBS:-${OSRC_HOME:-}/jobs}" rest
  case "$jd" in "$jobs"/*) ;; *) return 1 ;; esac
  rest="${jd#"$jobs"/}"
  case "$rest" in ""|*/*|*..*) return 1 ;; esac
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
    _osrc_spend_marker_pairs "$prov" "$@"
  ) > "$mf" 2>/dev/null || true
  [ -s "$mf" ] || rm -f "$mf" 2>/dev/null
}

# ---- event emission (L1 lanes/events.jsonl contract) ---------------------------
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
  case "$bill" in subscription|free) return 0 ;; esac
  local lname; lname="$(_lane_plan_display "$lane" 2>/dev/null)"; [ -n "$lname" ] || lname="$lane"
  # Show the model actually being dispatched; when none was resolved, the lane's own
  # default — never DEFAULT_MODEL, which is the SCRIPT's default and can name a
  # different engine's model entirely (the `paid-lane:cc/glm-5.2` lie).
  local mname; mname="${model:-}"
  [ -n "$mname" ] || mname="$(_lane_field "$lane" default_model 2>/dev/null)"
  [ -n "$mname" ] || mname="default"
  if _osrc_spend_ok "$lane" "$model"; then
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
  if [ -t 0 ] && [ -t 2 ]; then
    printf '>>> [spend] PAID LANE: %s (%s) / %s bills %s%s.\n' "$lname" "$disp" "$mname" "$bill" "${est:+ — est $est}" >&2
    printf '>>>   why: %s. This lane is not subscription/free; approve spend for THIS command only.\n' "$why" >&2
    local ans=""; IFS= read -r ans || ans=""
    case "$ans" in
      y|Y|yes|YES)
        OSRC_SPEND_OK=1
        printf 'OSRC_SPEND_CONSENT=1\n'   # machine token: a bg preflight parent greps this to carry consent forward
        printf '>>> [spend] approved for this command only (never persisted).\n' >&2
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

# =============================================================================
# Per-lane usage caps (--cap / lane cap)
# =============================================================================

# $OSRC_HOME/lane-caps: standing caps, one per line: "<lane> <meter><=<pct>".
_lane_caps_file() { printf '%s/lane-caps' "$OSRC_HOME"; }

# _osrc_cap_valid <spec> -> rc0 for meter<=pct where pct is a REAL number in [0,100]
# (digits with at most one dot — "<=.." or "<=1.2.3" or "<=abc" are not caps, they are
# typos that would otherwise trip on every reading or never trip at all).
_osrc_cap_valid() {
  case "$1" in
    *=*) local m="${1%%<=*}" p="${1##*<=}"
         [ "$m" = "$1" ] && return 1   # no <= separator
         case "$p" in ''|*.*.*|*[!0-9.]*) return 1 ;; esac
         case "$p" in *[0-9]*) ;; *) return 1 ;; esac
         case "$m" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
         awk -v p="$p" 'BEGIN{exit !(p+0>=0 && p+0<=100)}' || return 1
         return 0 ;;
    *) return 1 ;;
  esac
}

# _osrc_cap_window <lane> <meter> -> the lane's conserve_window this meter caps.
# Accepts a raw window name (claude7d, codexwk...) or a class: 5h | weekly|7d|week.
_osrc_cap_window() {
  local lane="${1:-}" meter="${2:-}" cw w
  cw="$(_lane_field "$lane" conserve_windows 2>/dev/null)" || return 1
  [ -n "$cw" ] || return 1
  for w in $cw; do [ "$w" = "$meter" ] && { printf '%s' "$w"; return 0; }; done
  case "$meter" in
    5h|5-hour|five-hour)
      for w in $cw; do case "$w" in *5h*) printf '%s' "$w"; return 0 ;; esac; done ;;
    weekly|7d|week|w)
      for w in $cw; do case "$w" in *7d*|*wk*|*week*) printf '%s' "$w"; return 0 ;; esac; done ;;
  esac
  return 1
}

# _osrc_cap_specs_for <lane> -> all cap specs applying to this lane: standing
# (lane-caps file rows for the lane) then per-launch OSRC_CAPS (space-separated).
_osrc_cap_specs_for() {
  local lane="${1:-}" cf spec
  cf="$(_lane_caps_file)"
  [ -f "$cf" ] && while IFS=' ' read -r _cl _cs; do
    [ "$_cl" = "$lane" ] && [ -n "$_cs" ] && printf '%s\n' "$_cs"
  done < "$cf"
  local _w
  for _w in ${OSRC_CAPS:-}; do printf '%s\n' "$_w"; done
}

# _osrc_cap_now <window> <limits-line> -> current pct for one window, rc1 unmeasured.
_osrc_cap_now() {
  local w="${1:-}" tok
  for tok in ${2:-}; do
    case "$tok" in "$w="*) printf '%s' "${tok#*=}"; return 0 ;; esac
  done
  return 1
}

# _osrc_cap_tripped <lane> [limits-line] -> rc0 + prints "spec now<pct>" for the
# FIRST cap at/past its line (standing caps first, then per-launch). rc1 = clear.
_osrc_cap_tripped() {
  local lane="${1:-}" limits="${2:-}" spec m p w now hit=""
  [ -n "$lane" ] || return 1
  [ -n "$limits" ] || limits="$(_osrc_limits_snapshot 2>/dev/null)"
  [ -n "$limits" ] || return 1
  while IFS= read -r spec; do
    _osrc_cap_valid "$spec" || continue
    m="${spec%%<=*}"; p="${spec##*<=}"
    w="$(_osrc_cap_window "$lane" "$m" 2>/dev/null)" || continue
    now="$(_osrc_cap_now "$w" "$limits" 2>/dev/null)" || continue
    case "$now" in ''|*[!0-9.]*) continue ;; esac
    if awk -v a="$now" -v b="$p" 'BEGIN{exit !(a+0>=b+0)}'; then
      hit="$spec now$now"; break
    fi
  done <<EOF
$(_osrc_cap_specs_for "$lane")
EOF
  [ -n "$hit" ] || return 1
  printf '%s\n' "$hit"; return 0
}

# _osrc_cap_unbound <lane> -> prints cap specs for this lane whose meter does NOT bind to
# any of the lane's conserve windows (silently inert — the cap can never trip). rc1 when
# every spec binds or none exist.
_osrc_cap_unbound() {
  local lane="${1:-}" spec m out=""
  [ -n "$lane" ] || return 1
  while IFS= read -r spec; do
    _osrc_cap_valid "$spec" || continue
    m="${spec%%<=*}"
    _osrc_cap_window "$lane" "$m" >/dev/null 2>&1 || out="$out $spec"
  done <<EOF
$(_osrc_cap_specs_for "$lane")
EOF
  out="${out# }"
  [ -n "$out" ] || return 1
  printf '%s' "$out"; return 0
}

# _osrc_cap_unread <lane> [limits-line] -> prints bound cap specs whose window has NO
# fresh reading (the cap exists but cannot be evaluated — a silent hole). rc1 when every
# bound spec has a reading or none exist.
_osrc_cap_unread() {
  local lane="${1:-}" limits="${2:-}" spec m w now out=""
  [ -n "$lane" ] || return 1
  [ -n "$limits" ] || limits="$(_osrc_limits_snapshot 2>/dev/null)"
  while IFS= read -r spec; do
    _osrc_cap_valid "$spec" || continue
    m="${spec%%<=*}"
    w="$(_osrc_cap_window "$lane" "$m" 2>/dev/null)" || continue   # unbound handled elsewhere
    now="$(_osrc_cap_now "$w" "$limits" 2>/dev/null)" || { out="$out $spec"; continue; }
    case "$now" in ''|*[!0-9.]*) out="$out $spec" ;; esac
  done <<EOF
$(_osrc_cap_specs_for "$lane")
EOF
  out="${out# }"
  [ -n "$out" ] || return 1
  printf '%s' "$out"; return 0
}

# _osrc_cap_gate <lane> <model> <disp> [nohop] -> pre-launch cap check, placed next
# to _osrc_limit_gate in route_delegate and the session paths. rc0 clear/consented;
# dies on refusal; rc10 = a zero-cost hop was armed (caller `continue`s).
_osrc_cap_gate() {
  local lane="${1:-}" model="${2:-}" disp="${3:-}" nohop="${4:-}"
  [ -n "$lane" ] || return 0
  local hit; hit="$(_osrc_cap_tripped "$lane" 2>/dev/null)" || {
    # Clear of a TRIPPED cap — but a cap that cannot be evaluated is not "clear":
    # unbound specs warn (they can never trip), bound specs with no fresh reading warn
    # too, and under an explicit pin both refuse loudly instead of silently proceeding.
    local unb unr lname0
    lname0="$(_lane_plan_display "$lane" 2>/dev/null)"; [ -n "$lname0" ] || lname0="$lane"
    unb="$(_osrc_cap_unbound "$lane" 2>/dev/null)"
    unr="$(_osrc_cap_unread "$lane" 2>/dev/null)"
    if [ -n "$unb$unr" ]; then
      [ -n "$unb" ] && printf '>>> [cap] %s: cap spec(s) %s do not bind to any %s window — they can never trip.\n' "$lname0" "$unb" "$lane" >&2
      [ -n "$unr" ] && printf '>>> [cap] %s: capped meter has no fresh reading for %s — cap cannot be verified.\n' "$lname0" "$unr" >&2
      if [ "${_fb_user_pinned:-0}" = "1" ] && [ "${OSRC_FALLBACK_PINNED:-0}" != "1" ]; then
        die "cap gate: ${lname0} has unverifiable cap(s) (${unb:+unbound:$unb }${unr:+unread:$unr}) and this run pinned ${model:-?} — refusing rather than launching with a cap that cannot be checked. Fix the cap (lane cap ${lane} ...) or re-run unpinned."
      fi
    fi
    return 0
  }
  local spec nowpct m p w
  spec="${hit%% now*}"; nowpct="${hit##* now}"
  m="${spec%%<=*}"; p="${spec##*<=}"
  w="$(_osrc_cap_window "$lane" "$m" 2>/dev/null)"
  local lname; lname="$(_lane_plan_display "$lane" 2>/dev/null)"; [ -n "$lname" ] || lname="$lane"
  printf '>>> [cap] %s lane %s is at %s%% — at/over its cap %s (window %s).\n' \
    "$lname" "${w:-$m}" "$nowpct" "$spec" "${w:-?}" >&2
  # A cap is a user-set guardrail: consent paths are --force-lane or raising the cap.
  [ "${OSRC_FORCE_LANE:-0}" = "1" ] && return 0
  if [ "${_fb_user_pinned:-0}" = "1" ] && [ "${OSRC_FALLBACK_PINNED:-0}" != "1" ]; then
    die "cap gate: ${lname} lane meter ${w:-$m} is at ${nowpct}% — at/over cap ${spec}. This run pinned -m ${model:-?}; raise the cap (lane cap ${lane} ${m}<=<pct> or --cap ${m}<=<pct>), clear it (lane cap ${lane} --clear), or re-run with --force-lane."
  fi
  if [ "$nohop" != "nohop" ] && _fallback_enabled && [ "${tier:-auto}" = "auto" ]; then
    if _gate_hop "$disp"; then
      printf '>>> [cap] %s at cap %s — skipping to %s (lane %s); no dispatch, so this skip is free of the attempt budget.\n' \
        "$lname" "$spec" "${_fb_alias:-?}" "${_fb_lane:-?}" >&2
      return 10
    fi
  fi
  die "cap gate: ${lname} lane meter ${w:-$m} is at ${nowpct}% — at/over cap ${spec}. Raise the cap, clear it (lane cap ${lane} --clear), switch lane, or re-run with --force-lane."
}

# _osrc_session_cap_gate -> session-start form (nohop): both session paths call this
# next to _osrc_session_limit_gate. MODEL_EXPLICIT plays the pinned role.
_osrc_session_cap_gate() {
  local _sc_p="${PROVIDER:-}" _sc_lane="" _sc_disp=""
  _sc_lane="$(_lane_by_native "$_sc_p" 2>/dev/null)"; [ -n "$_sc_lane" ] || _sc_lane="$(_lane_by_token "$_sc_p" 2>/dev/null)"; [ -n "$_sc_lane" ] || _sc_lane=""
  [ -n "$_sc_lane" ] && _sc_disp="$(_lane_field "$_sc_lane" disp 2>/dev/null)"
  [ -n "$_sc_disp" ] || _sc_disp="$_sc_p"
  local _fb_user_pinned="${MODEL_EXPLICIT:-0}"
  _osrc_cap_gate "$_sc_lane" "${MODEL:-$DEFAULT_MODEL}" "$_sc_disp" nohop
}

# _osrc_cap_poll <id> <lane> <model> -> supervise-side check: emits EVENT limit once
# per (job,cap-spec) when a running lane crosses its cap. Never blocks the job —
# "told to wrap up" is the orchestrator's NEXT, not a kill.
_osrc_cap_poll() {
  local id="${1:-}" lane="${2:-}" model="${3:-}"
  [ -n "$lane" ] || return 0
  # meta.json .lane is normally the canonical code already; normalize defensively so a
  # disp/provider value still resolves before the caps file and window lookup.
  lane="$(_lane_by_disp "$lane" 2>/dev/null || _lane_by_token "$lane" 2>/dev/null || _quota_lane_key "$lane" 2>/dev/null || printf '%s' "$lane")"
  local hit; hit="$(_osrc_cap_tripped "$lane" 2>/dev/null)" || return 0
  local spec nowpct
  spec="${hit%% now*}"; nowpct="${hit##* now}"
  # Dedupe: one event per JOB per spec. The marker lives in the job dir when known
  # (already per-job); without one it is keyed by job/session id so two sessions on
  # the same lane+spec each get their own event instead of the first silencing the rest.
  local marker="${OSRC_JOB_DIR:-$OSRC_HOME}/.caplimit.${id:-session}.$(printf '%s' "$spec" | tr -c 'A-Za-z0-9' '_')"
  [ -f "$marker" ] && return 0
  ( umask 077; : > "$marker" ) 2>/dev/null || true
  local next
  next="$0 lane cap ${lane} --clear   # or: $0 lane cap ${lane} ${spec%<=*}<=<higher>   # or stop the lane"
  _osrc_event limit "${id:-$lane}" "cap:$spec now:$nowpct" "$next" cap >&2
  printf '>>> [cap] job %s: %s lane crossed cap %s (now %s%%) — wrapping up is advised; no new work should be sent.\n' \
    "${id:-?}" "$lane" "$spec" "$nowpct" >&2
  return 0
}

# _osrc_cap_send_ok <text> -> rc0 when a session-send text is a wrap-up/stop message
# (allowed through the cap gate); rc1 = new work (refused while capped).
_osrc_cap_send_ok() {
  # Wrap-up intent = the message STARTS with a wrap/stop keyword (optionally after "please").
  # Prefix match, not full-line: "finish the refactor" is wrap-up; "mark done and add X" is not
  # (it does not start with the keyword). Best-effort — the pre-launch gate is the hard bound.
  printf '%s' "${1:-}" | grep -qiE '^[[:space:]]*(please[[:space:]]+)?(wrap[ -]?up|wrap|finish|wind[ -]?down|stop|halt|conclude|complete|done|shut[ -]?down)([[:space:].!,]|$)'
}

# _osrc_session_cap_send <session-id> <text> -> the "no new work at cap" enforcement for
# interactive sessions: resolves the session's lane from its start record and refuses NEW
# work when that lane sits at/over a cap. Wrap-up/stop messages always pass (they are how the
# lane gets told to finish). rc0 = send allowed; dies on refusal.
_osrc_session_cap_send() {
  local sess="${1:-}" text="${2:-}" rec prov model lane
  [ -n "$sess" ] || return 0
  rec="$(_session_record "$sess" 2>/dev/null)" || rec=""
  prov="$(printf '%s' "$rec" | cut -f1)"; model="$(printf '%s' "$rec" | cut -f2)"
  [ -n "$prov" ] || return 0    # no record -> cannot prove a lane -> do not block the send
  lane="$(_lane_by_native "$prov" 2>/dev/null)" || lane="$(_lane_by_token "$prov" 2>/dev/null)" || lane=""
  [ -n "$lane" ] || return 0
  local hit; hit="$(_osrc_cap_tripped "$lane" 2>/dev/null)" || return 0
  _osrc_cap_send_ok "$text" && return 0
  local spec nowpct
  spec="${hit%% now*}"; nowpct="${hit##* now}"
  # Dedupe the EVENT per session (keyed by session id + spec, not the spec alone) so
  # repeated refused sends do not spam lanes/events.jsonl — the refusal itself always fires.
  local marker="${OSRC_JOB_DIR:-$OSRC_HOME}/.caplimit.${sess}.$(printf '%s' "$spec" | tr -c 'A-Za-z0-9' '_')"
  if [ ! -f "$marker" ]; then
    ( umask 077; : > "$marker" ) 2>/dev/null || true
    _osrc_event limit "$sess" "cap:$spec now:$nowpct" \
      "$0 lane cap $lane --clear   # or raise the cap / stop the session" cap >&2
  fi
  die "session send refused: $lane lane is at ${nowpct}% — at/over cap $spec. Wrap-up messages (wrap up / finish / stop) still go through; new work does not. Raise the cap ('$0 lane cap $lane ${spec%%<=*}<=<pct>'), clear it ('$0 lane cap $lane --clear'), or stop the session."
}

# ---- lane verb handlers (dispatched from cmd_lane in lib/remote.sh) -----------------
#
# L2 owns the `lane` command: cmd_lane lives in lib/remote.sh (remote lanes + review
# queue) and carries these L7 cases alongside its own add|ls|show|poll|rm|events:
#   lane cap <lane> <meter><=pct> | lane cap <lane> --clear  -> osrc_lane_cap
#   lane billing <lane> [model]                             -> osrc_lane_billing
#   lane summary [--json]                                   -> osrc_lane_summary
#   lane limits                                            -> osrc_lane_limits
# (the old `lane ls` billing+caps table; `lane ls` itself is L2's remote-lane list.
#  `lane summary|limits` used to share the feed alias — `limits` now means the table.)
# `lane billing` dispatches to the osrc_lane_billing classifier itself — its
# <lane|disp|provider|alias> [model] [disp] signature is a superset of the verb's args.

osrc_lane_cap() {
  local lane="${1:-}" act="${2:-}"
  [ -n "$lane" ] || die "usage: lane cap <lane> <meter><=pct> | lane cap <lane> --clear"
  # Lane context, NOT quota/provider context: `cc` must stay the native-claude LANE
  # (quota_key would fold the provider token cc->or and silently cap the wrong pool).
  # Keep the ORIGINAL token through the fallback chain — a lookup that prints nothing
  # must not empty $lane and skip the remaining resolutions (the `lane cap codex` bug).
  local _tok="$lane"
  lane="$(_lane_by_token "$_tok" 2>/dev/null)"; [ -n "$lane" ] || lane="$(_lane_by_native "$_tok" 2>/dev/null)"
  [ -n "$lane" ] || lane="$(_lane_by_provider "$_tok" 2>/dev/null)"
  [ -n "$lane" ] || die "lane cap: unknown lane '$_tok' (use a lane code like cx/cc/dv/gm or a provider name like codex/claude)"
  local cf; cf="$(_lane_caps_file)"
  if [ "$act" = "--clear" ] || [ "$act" = "clear" ]; then
    # Cap-event dedupe markers are per (job|session,spec): clearing the caps must also
    # clear them, or a re-added identical cap would never re-notify. Done unconditionally —
    # per-launch --cap markers exist even when no standing caps file does.
    rm -f "$OSRC_HOME"/.caplimit.* "$OSRC_HOME"/jobs/*/.caplimit.* 2>/dev/null || true
    [ -f "$cf" ] || { echo "lane cap: no standing caps declared for $lane (cap-event markers cleared)."; return 0; }
    local tmp="$cf.tmp.$$"
    grep -v "^$lane " "$cf" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$cf" 2>/dev/null || { rm -f "$tmp"; die "lane cap: could not update $cf"; }
    echo "lane cap: cleared standing caps for $lane (and their cap-event markers)"
    return 0
  fi
  _osrc_cap_valid "$act" || die "usage: lane cap <lane> <meter><=pct>  (e.g. lane cap cx weekly<=40, lane cap cc 5h<=80)"
  # Refuse a cap whose meter cannot bind to this lane's windows — a stored cap that can
  # never trip is a lie, not a guardrail.
  _osrc_cap_window "$lane" "${act%%<=*}" >/dev/null 2>&1 \
    || die "lane cap: meter '${act%%<=*}' does not bind to lane '$lane' (no matching conserve window — the cap could never trip). Use a window this lane meters (e.g. $( _lane_field "$lane" conserve_windows 2>/dev/null | tr ' ' ',' ))."
  _mkdir_private "$OSRC_HOME" >/dev/null 2>&1 || die "cannot write state home $OSRC_HOME"
  # Replace an existing spec for the same meter on this lane; append otherwise.
  local m="${act%%<=*}" tmp="$cf.tmp.$$" found=0
  if [ -f "$cf" ]; then
    while IFS=' ' read -r l s; do
      [ "$l" = "$lane" ] && [ "${s%%<=*}" = "$m" ] && { found=1; continue; }
      [ -n "$l" ] && printf '%s %s\n' "$l" "$s"
    done < "$cf" > "$tmp"
  fi
  printf '%s %s\n' "$lane" "$act" >> "$tmp"
  mv -f "$tmp" "$cf" 2>/dev/null || { rm -f "$tmp"; die "lane cap: could not update $cf"; }
  echo "lane cap: $lane $act$( [ "$found" = 1 ] && echo ' (replaced)' )"
}

# _osrc_brief_caps <limits-line> -> one "caps" line for cmd_brief / handover briefs:
# every standing cap rendered as "<lane> cap <pct>% <window-class>, now <pct>%".
# Silent (rc1) when no standing caps exist.
_osrc_brief_caps() {
  local cf limits="${1:-}" l spec m p w now out=""
  cf="$(_lane_caps_file)"
  [ -f "$cf" ] || return 1
  [ -n "$limits" ] || limits="$(_osrc_limits_snapshot 2>/dev/null)"
  while IFS=' ' read -r l spec; do
    [ -n "$l" ] && [ -n "$spec" ] || continue
    _osrc_cap_valid "$spec" || continue
    m="${spec%%<=*}"; p="${spec##*<=}"
    w="$(_osrc_cap_window "$l" "$m" 2>/dev/null)" || w="$m"
    now=""; [ -n "$limits" ] && now="$(_osrc_cap_now "$w" "$limits" 2>/dev/null)"
    out="$out · $l cap ${p}% ${m}, now ${now:-?}%"
  done < "$cf"
  [ -n "$out" ] || return 1
  printf 'caps        :%s\n' "${out# · }"
  return 0
}

osrc_lane_limits() {
  local cf; cf="$(_lane_caps_file)"
  printf '%-10s %-12s %s\n' LANE BILLING CAPS "$([ -f "$cf" ] && echo '(standing)')"
  local l b caps now
  for l in $OSRC_LANE_REGISTRY; do
    b="$(osrc_lane_billing "$l" 2>/dev/null)"
    caps=""
    [ -f "$cf" ] && caps="$(awk -v l="$l" '$1==l{printf "%s%s ",$2,$3}' "$cf" 2>/dev/null)"
    [ -n "${OSRC_CAPS:-}" ] && caps="$caps(per-launch: $OSRC_CAPS)"
    [ -n "$caps" ] || caps="-"
    printf '%-10s %-12s %s\n' "$l" "$b" "$caps"
  done
}


# osrc_limits_summary — the limits feed's ORIGINAL name (pre-rename callers, CONTRACT).
# The implementation moved to lib/limits.sh with the rest of the meter readers; this
# alias keeps the old entry point working. `lane summary` is the CLI surface.
osrc_limits_summary() { osrc_lane_summary "$@"; }
