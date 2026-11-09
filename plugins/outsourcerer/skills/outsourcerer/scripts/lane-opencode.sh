# =============================================================================
# OPENCODE GO LANE (--provider opencode): the OpenCode Go subscription, driven
# through the user's `opencode` CLI (`opencode run`). The lane owns its catalog:
# -m is a Go model id (`glm-5.3-flash`, or full `opencode-go/glm-5.3-flash`),
# never an Outsourcerer alias. Only `opencode-go/*` ids bill the Go plan — a
# non-Go provider prefix (`opencode/<id>` = Zen pay-as-you-go, or any other
# configured provider) is REFUSED unless OSRC_OPENCODE_ALLOW_NONGO=1, so a Go
# request can never silently become a Zen bill. No hardcoded default model:
# `opencode run` without -m would fall back to whatever the user configured,
# which may not be a Go model — so the lane requires -m.
#
# Dispatch: `opencode run --agent <a> -m opencode-go/<id> "<prompt>" </dev/null`.
# Stdin is ALWAYS closed: a non-TTY `opencode run` with an open stdin blocks
# waiting for input and the job hangs until the watchdog kills it.
#
# Posture is enforced by a PER-RUN config: OPENCODE_CONFIG_CONTENT carries an
# inline JSON merged over global/project config for that invocation only — the
# user's ~/.config/opencode is never written. run/explore get `--agent plan`
# PLUS explicit denies on every mutating permission (edit/write/patch/bash and
# paths outside the job dir). An explicit deny beats a user's wildcard allow —
# verified on opencode 1.19.5 — so read-only holds even when the user's own
# config allows everything. The staged skill bundle lives outside the job dir,
# so its root is carved back as an allow exception or --with would be unreadable
# on a read-only run. Mutating tiers get `--agent build --auto` (build is the
# editing agent; --auto auto-approves the remaining `ask` prompts a headless
# run cannot answer). --auto is never combined with the deny list — it is only
# used on the tiers where mutation is wanted.
#
# Failure classes (repo conventions: lane-down markers + refusal evidence):
#   * region refusal ("hosted outside Europe and the United States") — PER-MODEL
#     refusal, never lane-down: the console instruction is surfaced and the
#     failover signal is written confirmed so the machinery may hop models.
#   * expired key ("API key has expired") — AUTH failure: this lane is marked
#     down and the renewal instruction surfaced; not a rate limit, never an
#     outage for other lanes.
#   * plan-limit phrasing — the shared plan-limit block probes the cheapest Go
#     model (glm-5.3-flash) and confirms before marking, same as cline/droid.
# =============================================================================

# Anchored-ish phrasing only; tested against a FAILED run's captured stderr. Go
# limits are per-model monthly allowance plus rolling 5h/weekly windows; whatever
# exact wording the API returns for "over the allowance" should land here.
_OPENCODE_PLAN_LIMIT_RE='rate.?limit|usage limit|quota[^.]{0,30}(exceeded|exhausted|reached)|insufficient (funds?|credits?|balance|quota)|too many requests|resource_exhausted|monthly allowance|plan limit|limit (reached|exceeded|exhausted)'

_opencode_go_authed() {
  # Go credentials live in opencode's own auth store; `opencode auth list` prints
  # an "OpenCode Go" entry when one exists (a plain "OpenCode" entry is the Zen
  # pay-as-you-go credential and does NOT count). Output may carry ANSI markup.
  have opencode || return 1
  opencode auth list 2>/dev/null | tr -d '\033' | sed 's/\[[0-9;]*[A-Za-z]//g' | grep -qi 'opencode *go'
}

_opencode_cli_missing() {
  die "opencode CLI not on PATH (OpenCode Go lane). Install: https://opencode.ai/docs (brew install opencode-ai/tap/opencode or npm i -g opencode-ai), then 'opencode auth login' and pick OpenCode Go. -m is a Go model id (glm-5.3-flash, kimi-k3.1-pro, ...); 'opencode models' lists them under opencode-go/."
}

_opencode_gate() {  # lane gate_fn: cli presence is handled by the cli= field
  _opencode_go_authed || die "the opencode lane needs OpenCode Go credentials: run 'opencode auth login' and choose OpenCode Go (https://opencode.ai). 'opencode auth list' shows the stored credentials — a plain 'OpenCode' entry is Zen pay-as-you-go and does not work here."
}

_opencode_route_check() { _opencode_cli_missing; _opencode_gate; }

_ready_probe_opencode() { have opencode && _opencode_go_authed && printf 'opencode=go'; }

# _opencode_model <raw -m token> -> the launchable `provider/id` for `opencode run -m`.
_opencode_model() {
  local m="${1:-}"
  case "$m" in
    opencode-go/*)    printf '%s' "$m" ;;
    opencode/*-free)  printf '%s' "$m" ;;  # Zen's free-tier ids are still $0
    opencode/*|*/*)
      [ "${OSRC_OPENCODE_ALLOW_NONGO:-0}" = "1" ] || die "opencode lane: -m '$m' is not an OpenCode Go model — it would bill OpenCode Zen pay-as-you-go or another configured provider, NOT your Go plan. Pass a Go id (glm-5.3-flash, opencode-go/<id>; list: opencode models | grep '^opencode-go/'), or set OSRC_OPENCODE_ALLOW_NONGO=1 to force."
      printf '%s' "$m" ;;
    *) printf 'opencode-go/%s' "$m" ;;
  esac
}

_opencode_effort() { # tier -> opencode --variant
  case "$1" in
    minimal|none|off) printf 'minimal' ;;
    low)    printf 'low' ;;
    medium) printf 'medium' ;;
    high|xhigh) printf 'high' ;;
    max)    printf 'max' ;;
    *)      printf '' ;;
  esac
}

# _opencode_probe_model <refused-model>: cheapest Go id for plan-limit
# verification (mirrors _devin_plan_probe_model).
_opencode_probe_model() {
  local refused; refused="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$refused" in
    *glm-5.3-flash*) printf 'opencode-go/glm-5.3' ;;
    *)               printf 'opencode-go/glm-5.3-flash' ;;
  esac
}

# _opencode_config_json <readonly|allowall> [bundle_root] -> per-run config JSON.
_opencode_config_json() {
  local mode="$1" root="${2:-}"
  case "$mode" in
    readonly)
      if [ -n "$root" ]; then
        jq -cn --arg root "$root" '{permission:{edit:"deny",write:"deny",patch:"deny",bash:"deny",doom_loop:"deny",external_directory:{"*":"deny",($root):"allow",($root+"/*"):"allow",($root+"/**"):"allow"}}}'
      else
        printf '%s' '{"permission":{"edit":"deny","write":"deny","patch":"deny","bash":"deny","doom_loop":"deny","external_directory":"deny"}}'
      fi ;;
    allowall) printf '%s' '{"permission":{"*":"allow","doom_loop":"allow","external_directory":{"*":"allow"}}}' ;;
    *)        printf '%s' '{}' ;;
  esac
}

# _opencode_classify <errfile> <model> <rc> -> rc0 when the failure was
# classified (evidence + failover signal already written), rc1 to fall through.
_opencode_classify() {
  local f="$1" m="$2" rc="${3:-1}"
  [ "$rc" -ne 0 ] || return 1
  [ -n "$f" ] && [ -s "$f" ] || return 1
  if grep -qi 'hosted outside Europe and the United States\|Select Global at .*opencode' "$f" 2>/dev/null; then
    printf '>>> [opencode] PER-MODEL REGION REFUSAL: %s is hosted outside Europe and the United States and your Go privacy setting does not allow it — select Global at https://opencode.ai/console -> Settings > Privacy > Regions, or pick another Go model. The lane itself is UP; this is not a lane outage.\n' "$m" >&2
    _failover_signal_write opencode "$m" confirmed "model refused by region setting" "" 2>/dev/null || true
    return 0
  fi
  if grep -qi 'API key has expired\|Create a new API key in OpenCode Console' "$f" 2>/dev/null; then
    printf '>>> [opencode] AUTH FAILURE: this API key has expired — create a new key in OpenCode Console (https://opencode.ai/console) and re-login with opencode auth login. Not a rate limit; other lanes unaffected.\n' >&2
    _lane_down_mark opencode "${OSRC_LANE_DOWN_TTL:-300}" "OpenCode Go API key expired" 2>/dev/null || true
    _failover_signal_write opencode "$m" confirmed "OpenCode Go API key expired" "" 2>/dev/null || true
    return 0
  fi
  if grep -qiE "$_OPENCODE_PLAN_LIMIT_RE" "$f" 2>/dev/null; then
    _lane_plan_limit_block opencode "$f" "$m"
    return 0
  fi
  return 1
}

# _opencode_free_probe -> printed verdict for _lane_free_probe's opencode arm
# (answered | limit-refused | unreachable). Probe: cheapest Go model, bounded,
# stdin closed, plan agent (no tools needed to say OK).
_opencode_free_probe() {
  local out="" rc=0 secs="${OSRC_LANE_PROBE_SECS:-30}"
  if _mkdir_private "$OSRC_HOME" >/dev/null 2>&1; then
    out="$(_lane_probe_file opencode)"; : > "$out" 2>/dev/null && chmod 600 "$out" 2>/dev/null || out=""
  fi
  if ! have opencode; then [ -n "$out" ] && printf 'opencode CLI not on PATH\n' > "$out"; printf 'unreachable'; return 0; fi
  _timeout "$secs" env OPENCODE_CONFIG_CONTENT='{"permission":{"edit":"deny","write":"deny","patch":"deny","bash":"deny","external_directory":"deny","doom_loop":"deny"}}' opencode run --agent plan -m "$(_opencode_probe_model "$1")" "reply OK" </dev/null > "${out:-/dev/null}" 2>&1 || rc=$?
  if [ -n "$out" ] && grep -qiE "$_OPENCODE_PLAN_LIMIT_RE" "$out" 2>/dev/null; then printf 'limit-refused'; return 0; fi
  if [ "$rc" -eq 0 ] && grep -qi '\bOK\b' "${out:-/dev/null}" 2>/dev/null; then printf 'answered'; return 0; fi
  printf 'unreachable'; return 0
}

delegate_opencode() {
  local tier="$1"
  [ "${#REST[@]}" -gt 0 ] || die "no task prompt given"
  local task="${REST[*]}" id="${MODEL:-}"
  have opencode || _opencode_cli_missing
  [ -n "$id" ] || die "the opencode lane needs -m <go-model-id> (e.g. glm-5.3-flash or opencode-go/glm-5.3-flash; the lane has no default — a bare run would fall back to opencode's own configured model, which may not bill your Go plan). Nothing was run."
  id="$(_opencode_model "$id")"; _validate_model_token "$id"
  local aflag=() posture cfg
  case "$tier" in
    auto)         aflag=(--agent plan);         cfg=readonly; posture="READ-ONLY (--agent plan + per-run denies on edit/write/patch/bash and paths outside the job dir)" ;;
    accept-edits) aflag=(--agent build --auto); cfg=none;     posture="MUTATING (build agent, --auto; opencode has no sandbox — it runs with your user's rights)" ;;
    autonomous)   aflag=(--agent build --auto); cfg=none;     posture="MUTATING, NO SANDBOX (build agent, --auto)" ;;
    dangerous)    aflag=(--agent build --auto); cfg=allowall; posture="DANGER (build agent, --auto, all permissions pre-allowed; no sandbox)" ;;
    *) die "delegate_opencode: bad tier: $tier" ;;
  esac
  local eff=() oe=""
  if [ -n "${EFFORT:-}" ]; then
    oe="$(_opencode_effort "$EFFORT")"
    [ -n "$oe" ] && eff=(--variant "$oe") || printf '%s\n' "note: opencode: --effort $EFFORT has no --variant equivalent; ignoring" >&2
  fi
  local ttier; ttier="$(resolve_tier "${MODEL:-}" "${TTIER:-}")" || ttier="capable"
  _with_preamble_render "bundle"
  local wrapped; wrapped="$(_build_prompt "$id" "$task" "$ttier" "bundle")"
  local oc_cfg; oc_cfg="$(_opencode_config_json "$cfg" "${WITH_BUNDLE_ROOT:-}")"
  _tier_banner "opencode (OpenCode Go)" "$id" "$ttier" "$posture | $(_lane_cost_disclosure opencode)"
  local rc=0 _lerr; _lerr="$(_lane_errfile)"
  OPENCODE_CONFIG_CONTENT="$oc_cfg" _run_tee_stderr "$_lerr" opencode run ${aflag[@]+"${aflag[@]}"} -m "$id" ${eff[@]+"${eff[@]}"} "$wrapped" </dev/null || rc=$?
  _opencode_classify "$_lerr" "$id" "$rc" || true
  [ -n "$_lerr" ] && rm -f "$_lerr" 2>/dev/null
  record_ledger opencode "$id" "$ttier" "$tier" "$task" "$(_fg_run_cost opencode 0 "")" opencode
  return "$rc"
}

lane_descriptor_opencode() {
  printf '%s\n' \
    "name=opencode" \
    "providers=opencode" \
    "provider_is_lane=yes" \
    "owns_catalog=yes" \
    "cli=opencode" \
    "cli_missing_hint=opencode CLI not on PATH (OpenCode Go lane). Install: https://opencode.ai/docs, then 'opencode auth login' and pick OpenCode Go." \
    "gate_fn=_opencode_gate" \
    "route_check_fn=_opencode_route_check" \
    "ready_fn=_ready_probe_opencode" \
    "disp=opencode" \
    "dispatch=delegate_opencode" \
    "effort_fn=_opencode_effort" \
    "family_globs=opencode-go/*" \
    "model_globs=opencode-go/*" \
    "quota_key=opencode" \
    "cost_class=limited" \
    "plan_limited=yes" \
    "compare_class=plan" \
    "cost_disclosure=\$0 cash, spends your OpenCode Go plan allowance (per-model monthly, plus 20% per 5h and 50% per week windows — live usage in the OpenCode Console)" \
    "is_cloud=yes" \
    "fallback_provider=opencode" \
    "participates_health=yes"
}

_doctor_opencode() {
  echo "  -- OpenCode Go lane (opencode CLI + OpenCode Go subscription, $(_lane_cost_disclosure opencode)) --"
  if ! have opencode; then
    echo "    opencode: NOT on PATH — install: https://opencode.ai/docs (brew install opencode-ai/tap/opencode or npm i -g opencode-ai), then 'opencode auth login' -> OpenCode Go"
    return 0
  fi
  echo "    opencode: $(opencode --version 2>/dev/null | head -1 || echo present) — route: --provider opencode run -m <go-model-id> \"task\" (a bare id becomes opencode-go/<id>; 'opencode models' lists them)"
  if ! _opencode_go_authed; then
    echo "    opencode Go: NO OpenCode Go credential — run 'opencode auth login' and choose OpenCode Go (a plain 'OpenCode' entry is Zen pay-as-you-go, not Go)"
    return 0
  fi
  echo "    opencode Go: credential present. Models: opencode models | grep '^opencode-go/'"
  if [ "$_doff" = "1" ]; then echo "    opencode liveness: probe skipped (OSRC_DOCTOR_OFFLINE)"
  elif [ "${OSRC_DOCTOR_PROBE:-1}" = "1" ]; then
    local _pt _prc=0
    _pt="$(_timeout "${OSRC_DOCTOR_PROBE_TIMEOUT_SECS:-30}" env OPENCODE_CONFIG_CONTENT='{"permission":{"edit":"deny","write":"deny","patch":"deny","bash":"deny","external_directory":"deny","doom_loop":"deny"}}' opencode run --agent plan -m opencode-go/glm-5.3-flash "Reply with exactly: OK" </dev/null 2>&1)" || _prc=$?
    case "$_pt" in
      *"hosted outside Europe"*|*"Select Global"*)
        echo "    opencode liveness: LANE UP, probe model region-refused — glm-5.3-flash is hosted outside Europe/US; select Global at https://opencode.ai/console -> Settings > Privacy > Regions, or run with another Go model" ;;
      *"API key has expired"*|*"Create a new API key"*)
        echo "    opencode liveness: AUTH FAILURE — the Go API key has expired; create a new key in OpenCode Console and re-login: opencode auth login"
        _lane_down_mark opencode "${OSRC_LANE_DOWN_TTL:-300}" "OpenCode Go API key expired" 2>/dev/null || true ;;
      *OK*|*Ok*)
        [ "$_prc" -eq 0 ] && echo "    opencode liveness: READY — opencode-go/glm-5.3-flash answered (plan agent, read-only config, stdin closed)" ;;
      *)
        if printf '%s' "$_pt" | grep -qiE "$_OPENCODE_PLAN_LIMIT_RE"; then
          echo "    opencode liveness: lane UP but Go plan allowance spent on the probe model (per-model monthly + 5h/weekly windows — OpenCode Console has the live figure)"
        elif [ "$_prc" -ne 0 ]; then
          echo "    opencode liveness: NOT ANSWERING (rc=$_prc) — try a manual 'opencode run -m opencode-go/glm-5.3-flash \"reply OK\" </dev/null'"
          _lane_down_mark opencode "${OSRC_LANE_DOWN_TTL:-300}" "doctor probe rc=$_prc" 2>/dev/null || true
        else
          echo "    opencode liveness: probe returned but did not echo OK — Go lane suspect"
        fi ;;
    esac
  fi
}
