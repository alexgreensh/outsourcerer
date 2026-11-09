# =============================================================================
# OPENCODE GO LANE (--provider opencode): the OpenCode Go subscription, driven
# through the user's `opencode` CLI (`opencode run`). The lane owns its catalog:
# -m is a Go model id (`glm-5.3-flash`, or full `opencode-go/glm-5.3-flash`),
# never an Outsourcerer alias. Only `opencode-go/*` ids bill the Go plan — a
# non-Go provider prefix (`opencode/<id>` = Zen pay-as-you-go, or any other
# configured provider) is REFUSED unless OSRC_OPENCODE_ALLOW_NONGO=1, so a Go
# request can never silently become a Zen bill. The `opencode/<id>-free`
# exception passes only after the id is verified against the LIVE catalog
# (`opencode models`): a repriced model keeping the -free suffix would otherwise
# quietly spend cash. No hardcoded default model: `opencode run` without -m
# would fall back to whatever the user configured, which may not be a Go model
# — so the lane requires -m, and is skipped as a failover TARGET (a hop can
# only rebuild argv without -m, which would die here).
#
# Dispatch: `opencode [--standalone] run --agent <a> -m opencode-go/<id>[#variant]
# -- "<prompt>" </dev/null`. Stdin is ALWAYS closed: a non-TTY `opencode run`
# with an open stdin blocks waiting for input and the job hangs until the
# watchdog kills it. `--` keeps a prompt starting with '-' from being parsed as
# flags. v2.x runs get --standalone: a SHARED background server never sees the
# CLI's env, so OPENCODE_CONFIG_CONTENT only reaches a private one (verified on
# v2.2.6 — without it the per-run permission rules silently do nothing).
#
# Posture is enforced by a PER-RUN config: OPENCODE_CONFIG_CONTENT carries an
# inline JSON merged over global/project config for that invocation only — the
# user's ~/.config/opencode is never written. run/explore deny EVERYTHING and
# re-allow only the read family (read/glob/grep/question): a named deny list can
# never be complete (task/subagent, webfetch, websearch, skill, MCP and plugin
# tools all have their own actions), verified on v2.2.6 with a wildcard-allow
# user config. The staged skill bundle lives outside the job dir, so its root is
# carved back as an allow exception or --with would be unreadable on a read-only
# run. edit gets `--agent build --auto` PLUS external_directory scoping to the
# job dir. research/autonomous REFUSES: opencode has no OS sandbox (same answer
# as claude-native/cc). yolo pre-allows everything, by definition.
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
  _timeout 10 opencode auth list 2>/dev/null | tr -d '\033' | sed 's/\[[0-9;]*[A-Za-z]//g' | grep -qi 'opencode *go'
}

_opencode_cli_missing() {
  die "opencode CLI not on PATH (OpenCode Go lane). Install: https://opencode.ai/docs (brew install opencode-ai/tap/opencode or npm i -g opencode-ai), then 'opencode auth login' and pick OpenCode Go. -m is a Go model id (glm-5.3-flash, kimi-k3.1-pro, ...); 'opencode models' lists them under opencode-go/."
}

# _opencode_v2 -> rc0 when the installed CLI is v2.x+. v2 changes the run
# surface: per-run env config is only honored by a PRIVATE server (--standalone,
# the shared background service ignores it), --variant is folded into -m as
# provider/model#variant, and the permission ruleset is action/resource/effect
# (bash -> shell, task -> subagent). v1 keeps its original invocation.
_opencode_v2() {
  local v; v="$(opencode --version 2>/dev/null | tr -cd '0-9.' | cut -d. -f1)"
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  [ "$v" -ge 2 ]
}

_opencode_gate() {  # lane gate_fn: cli presence is handled by the cli= field
  _opencode_go_authed || die "the opencode lane needs OpenCode Go credentials: run 'opencode auth login' and choose OpenCode Go (https://opencode.ai). 'opencode auth list' shows the stored credentials — a plain 'OpenCode' entry is Zen pay-as-you-go and does not work here."
}

_opencode_route_check() { _opencode_cli_missing; _opencode_gate; }

_ready_probe_opencode() { have opencode && _opencode_go_authed && printf 'opencode=go'; }

# _opencode_model <raw -m token> -> the launchable `provider/id` for `opencode run -m`,
# or rc1 on refusal (the caller dies so the error is not lost inside $( ) as it would
# be if this function died in the subshell and the caller kept going with empty output).
_opencode_model() {
  local m="${1:-}"
  case "$m" in
    ''|*//*|*/) return 1 ;;                               # empty, empty id, or // path
    opencode-go/?*) printf '%s' "$m" ;;
    opencode/?*-free) _opencode_free_member "$m" && printf '%s' "$m" || return 1 ;;  # Zen $0 free tier — verified against the live catalog, never trusted on suffix alone
    */*) [ "${OSRC_OPENCODE_ALLOW_NONGO:-0}" = "1" ] && printf '%s' "$m" || return 1 ;;
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

# _opencode_free_member <opencode/id-free> -> rc0 when the id is a REAL Zen free
# model in the live catalog. The -free suffix alone is not a billing guarantee:
# a repriced or renamed id that keeps the suffix would silently spend Zen cash.
_opencode_free_member() {
  have opencode || return 1
  _timeout "${OSRC_LANE_PROBE_SECS:-30}" opencode models 2>/dev/null | grep -qxF "$1"
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

# _opencode_config_json <readonly|scoped|allowall> [bundle_root] -> per-run config JSON.
# readonly: deny EVERYTHING first, then re-allow only the read family — a deny
# list that names mutating tools can never be complete (task/subagent, webfetch,
# websearch, skill, MCP and plugin tools all have their own actions and would
# slip through any enumeration). scoped: the mutating tiers — the model may work
# freely INSIDE the job dir but reads/writes/bash outside it are denied (the
# staged skill bundle, which lives outside the job dir, is the only exception).
# allowall: yolo only.
_opencode_config_json() {
  local mode="$1" root="${2:-}"
  if _opencode_v2; then
    case "$mode" in
      readonly)
        if [ -n "$root" ]; then
          jq -cn --arg root "$root" '{permissions:[{action:"*",resource:"*",effect:"deny"},{action:"read",resource:"*",effect:"allow"},{action:"glob",resource:"*",effect:"allow"},{action:"grep",resource:"*",effect:"allow"},{action:"question",resource:"*",effect:"allow"},{action:"external_directory",resource:$root,effect:"allow"},{action:"external_directory",resource:($root+"/*"),effect:"allow"},{action:"external_directory",resource:($root+"/**"),effect:"allow"}]}'
        else
          printf '%s' '{"permissions":[{"action":"*","resource":"*","effect":"deny"},{"action":"read","resource":"*","effect":"allow"},{"action":"glob","resource":"*","effect":"allow"},{"action":"grep","resource":"*","effect":"allow"},{"action":"question","resource":"*","effect":"allow"}]}'
        fi ;;
      scoped)
        if [ -n "$root" ]; then
          jq -cn --arg root "$root" '{permissions:[{action:"*",resource:"*",effect:"allow"},{action:"external_directory",resource:"*",effect:"deny"},{action:"external_directory",resource:$root,effect:"allow"},{action:"external_directory",resource:($root+"/*"),effect:"allow"},{action:"external_directory",resource:($root+"/**"),effect:"allow"}]}'
        else
          printf '%s' '{"permissions":[{"action":"*","resource":"*","effect":"allow"},{"action":"external_directory","resource":"*","effect":"deny"}]}'
        fi ;;
      allowall) printf '%s' '{"permissions":[{"action":"*","resource":"*","effect":"allow"}]}' ;;
      *)        printf '%s' '{}' ;;
    esac
  else
    case "$mode" in
      readonly)
        if [ -n "$root" ]; then
          jq -cn --arg root "$root" '{permission:{"*":"deny",edit:"deny",write:"deny",patch:"deny",bash:"deny",doom_loop:"deny",task:"deny",webfetch:"deny",websearch:"deny",read:"allow",glob:"allow",grep:"allow",list:"allow",question:"allow",external_directory:{"*":"deny",($root):"allow",($root+"/*"):"allow",($root+"/**"):"allow"}}}'
        else
          printf '%s' '{"permission":{"*":"deny",edit:"deny",write:"deny",patch:"deny",bash:"deny",doom_loop:"deny",task:"deny",webfetch:"deny",websearch:"deny",read:"allow",glob:"allow",grep:"allow",list:"allow",question:"allow","external_directory":"deny"}}'
        fi ;;
      scoped)
        if [ -n "$root" ]; then
          jq -cn --arg root "$root" '{permission:{"*":"allow",external_directory:{"*":"deny",($root):"allow",($root+"/*"):"allow",($root+"/**"):"allow"}}}'
        else
          printf '%s' '{"permission":{"*":"allow","external_directory":"deny"}}'
        fi ;;
      allowall) printf '%s' '{"permission":{"*":"allow","doom_loop":"allow","external_directory":{"*":"allow"}}}' ;;
      *)        printf '%s' '{}' ;;
    esac
  fi
}

# _opencode_classify <errfile> <model> <rc> -> rc0 when the failure was
# classified (evidence + failover signal already written), rc1 to fall through.
_opencode_classify() {
  local f="$1" m="$2" rc="${3:-1}"
  [ "$rc" -ne 0 ] || return 1
  [ -n "$f" ] && [ -s "$f" ] || return 1
  local _cf; _cf="$(LC_ALL=C tr -d '\033' < "$f" | LC_ALL=C sed 's/\[[0-9;]*[A-Za-z]//g')"
  if printf '%s' "$_cf" | grep -qi 'hosted outside Europe and the United States\|Select Global at .*opencode' 2>/dev/null; then
    printf '>>> [opencode] PER-MODEL REGION REFUSAL: %s is hosted outside Europe and the United States and your Go privacy setting does not allow it — select Global at https://opencode.ai/console -> Settings > Privacy > Regions, or pick another Go model. The lane itself is UP; this is not a lane outage.\n' "$m" >&2
    _failover_signal_write opencode "$m" confirmed "model refused by region setting" "" 2>/dev/null || true
    return 0
  fi
  if printf '%s' "$_cf" | grep -qi 'API key has expired\|Create a new API key in OpenCode Console' 2>/dev/null; then
    printf '>>> [opencode] AUTH FAILURE: this API key has expired — create a new key in OpenCode Console (https://opencode.ai/console) and re-login with opencode auth login. Not a rate limit; other lanes unaffected.\n' >&2
    _lane_down_mark opencode "${OSRC_LANE_DOWN_TTL:-300}" "OpenCode Go API key expired" 2>/dev/null || true
    _failover_signal_write opencode "$m" confirmed "OpenCode Go API key expired" "" 2>/dev/null || true
    return 0
  fi
  if printf '%s' "$_cf" | grep -qiE "$_OPENCODE_PLAN_LIMIT_RE" 2>/dev/null; then
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
  case "$secs" in ''|*[!0-9]*) secs=30 ;; esac
  if _mkdir_private "$OSRC_HOME" >/dev/null 2>&1; then
    out="$(_lane_probe_file opencode)"; : > "$out" 2>/dev/null && chmod 600 "$out" 2>/dev/null || out=""
  fi
  if ! have opencode; then [ -n "$out" ] && printf 'opencode CLI not on PATH\n' > "$out"; printf 'unreachable'; return 0; fi
  local sa=(); _opencode_v2 && sa=(--standalone)
  _timeout "$secs" env OPENCODE_CONFIG_CONTENT="$(_opencode_config_json readonly)" opencode ${sa[@]+"${sa[@]}"} run --agent plan -m "$(_opencode_probe_model "$1")" "reply OK" </dev/null > "${out:-/dev/null}" 2>&1 || rc=$?
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
  id="$(_opencode_model "$id")" || die "opencode lane: -m '$id' is not an OpenCode Go model — it would bill OpenCode Zen pay-as-you-go or another configured provider, NOT your Go plan. Pass a Go id (glm-5.3-flash, opencode-go/<id>; list: opencode models | grep '^opencode-go/'), or set OSRC_OPENCODE_ALLOW_NONGO=1 to force."
  _validate_model_token "$id"
  local aflag=() posture cfg v2=0
  _opencode_v2 && v2=1
  case "$tier" in
    auto)         aflag=(--agent plan);         cfg=readonly; posture="READ-ONLY (--agent plan + per-run * deny, re-allowing read/glob/grep only)" ;;
    accept-edits) aflag=(--agent build --auto); cfg=scoped;   posture="MUTATING (build agent, --auto, work scoped to the job dir — no sandbox)" ;;
    autonomous)   die "opencode lane has NO OS sandbox; 'research' is unsafe here (a build agent would run with your full user rights). Use --provider codex/devin for sandboxed exec, or run/explore/edit/yolo on this lane. Nothing was run." ;;
    dangerous)    aflag=(--agent build --auto); cfg=allowall; posture="DANGER (build agent, --auto, all permissions pre-allowed; no sandbox)" ;;
    *) die "delegate_opencode: bad tier: $tier" ;;
  esac
  local eff=() oe=""
  if [ -n "${EFFORT:-}" ]; then
    oe="$(_opencode_effort "$EFFORT")"
    if [ -n "$oe" ]; then
      if [ "$v2" = 1 ]; then id="$id#$oe"; else eff=(--variant "$oe"); fi
    else
      printf '%s\n' "note: opencode: --effort $EFFORT has no variant equivalent; ignoring" >&2
    fi
  fi
  local ttier; ttier="$(resolve_tier "${MODEL:-}" "${TTIER:-}")" || ttier="capable"
  _with_preamble_render "bundle"
  local wrapped; wrapped="$(_build_prompt "$id" "$task" "$ttier" "bundle")"
  local oc_cfg; oc_cfg="$(_opencode_config_json "$cfg" "${WITH_BUNDLE_ROOT:-}")"
  [ "$cfg" != readonly ] || [ -n "$oc_cfg" ] || die "opencode: refusing to run unenforced — the read-only permission config came out empty (jq is required to build it when a skill bundle is staged). Nothing was run."
  _tier_banner "opencode (OpenCode Go)" "$id" "$ttier" "$posture | $(_lane_cost_disclosure opencode)"
  local rc=0 _lerr sa=(); _lerr="$(_lane_errfile)"
  [ "$v2" = 1 ] && sa=(--standalone)   # the shared background server ignores the per-run env config; a private one reads it
  OPENCODE_CONFIG_CONTENT="$oc_cfg" _run_tee_stderr "$_lerr" opencode ${sa[@]+"${sa[@]}"} run ${aflag[@]+"${aflag[@]}"} -m "$id" ${eff[@]+"${eff[@]}"} -- "$wrapped" </dev/null || rc=$?
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
    "family_globs=opencode-go/* opencode/*" \
    "model_globs=opencode-go/* opencode/*" \
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
    local _pt _prc=0 _dps="${OSRC_DOCTOR_PROBE_TIMEOUT_SECS:-30}" _dsa=()
    case "$_dps" in ''|*[!0-9]*) _dps=30 ;; esac
    _opencode_v2 && _dsa=(--standalone)
    _pt="$(_timeout "$_dps" env OPENCODE_CONFIG_CONTENT="$(_opencode_config_json readonly)" opencode ${_dsa[@]+"${_dsa[@]}"} run --agent plan -m opencode-go/glm-5.3-flash "Reply with exactly: OK" </dev/null 2>&1)" || _prc=$?
    case "$_pt" in
      *"hosted outside Europe"*|*"Select Global"*)
        echo "    opencode liveness: LANE UP, probe model region-refused — glm-5.3-flash is hosted outside Europe/US; select Global at https://opencode.ai/console -> Settings > Privacy > Regions, or run with another Go model" ;;
      *"API key has expired"*|*"Create a new API key"*)
        echo "    opencode liveness: AUTH FAILURE — the Go API key has expired; create a new key in OpenCode Console and re-login: opencode auth login"
        _lane_down_mark opencode "${OSRC_LANE_DOWN_TTL:-300}" "OpenCode Go API key expired" 2>/dev/null || true ;;
      *OK*|*Ok*)
        if [ "$_prc" -eq 0 ]; then echo "    opencode liveness: READY — opencode-go/glm-5.3-flash answered (plan agent, read-only config, stdin closed)"; else echo "    opencode liveness: probe echoed OK but exited rc=$_prc — Go lane suspect"; fi ;;
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
