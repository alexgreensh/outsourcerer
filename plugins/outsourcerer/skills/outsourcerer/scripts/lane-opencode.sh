# =============================================================================
# OPENCODE GO LANE (--provider opencode): the OpenCode Go subscription, driven
# through the user's `opencode` CLI (`opencode run`). The lane owns its catalog:
# -m is a Go model id (`glm-5.3-flash`, or full `opencode-go/glm-5.3-flash`),
# never an Outsourcerer alias. Only `opencode-go/*` ids bill the Go plan — a
# non-Go provider prefix (`opencode/<id>` = Zen pay-as-you-go or free tier, or
# any other configured provider) is REFUSED unless OSRC_OPENCODE_ALLOW_NONGO=1,
# so a Go request can never silently become a Zen bill. There is no -free
# exception: catalog membership does not prove a $0 price (a repriced model can
# keep its suffix), so even Zen's free tier needs the explicit opt-in. No
# hardcoded default model: `opencode run` without -m would fall back to whatever
# the user configured, which may not be a Go model — so the lane requires -m,
# and is skipped as a failover TARGET (a hop can only rebuild argv without -m,
# which would die here).
#
# Dispatch: `opencode [--standalone] run --agent <a> -m opencode-go/<id>[#variant]
# -- "<prompt>" </dev/null`. Stdin is ALWAYS closed: a non-TTY `opencode run`
# with an open stdin blocks waiting for input and the job hangs until the
# watchdog kills it. `--` keeps a prompt starting with '-' from being parsed as
# flags. The v1/v2 split is detected once via _opencode_ver: v1 keeps its
# original `permission` map + `--variant`; v2 needs --standalone (a SHARED
# background server never sees the CLI's env, so OPENCODE_CONFIG_CONTENT only
# reaches a private one — verified on v2.2.6) and folds effort into -m as
# provider/model#variant. An UNPARSEABLE version refuses the read-only and
# edit tiers outright (same fail-closed posture as the cline lane): guessing
# the v1 shape at a real v2 install would launch unenforced.
#
# Posture is enforced by a PER-RUN config: OPENCODE_CONFIG_CONTENT carries an
# inline JSON merged over the user's global config for that invocation only —
# ~/.config/opencode is never written. run/explore deny EVERYTHING and re-allow
# only the read family (read/glob/grep/question): a named deny list can never
# be complete (task/subagent, webfetch, websearch, skill, MCP and plugin tools
# all have their own actions). On v2 this is also asserted as `policies`
# (tool.use statements), the layer applied AFTER agent rules and saved
# approvals — without it the shipped `plan` agent (which may write under
# ~/.opencode/plan) or a user's `agents.plan.permissions` allow-all silently
# re-opens writes. Policies are still not the last word: a project
# opencode.json(c)/.opencode/ loads AFTER the inline config and its own
# policies evaluate last — verified on v2.2.6 that a hostile project
# `policies` + `agents.plan` allow-all reopened writes through both the root
# opencode.json and .opencode/opencode.json forms — so read-only runs also set
# OPENCODE_DISABLE_PROJECT_CONFIG=1 and skip the project layer entirely
# (verified on v2.2.6: with the var set the same hostile configs denied the
# write again). v1 has no hard policy layer, so a user's own agent-level
# permission overrides remain the residual gap there (v1 is deprecated). The
# broad read allow would otherwise mask opencode's built-in *.env/*.env.* "ask"
# — sensitive files are re-denied after the allows (.env.example stays
# readable). The staged skill bundle lives outside the job dir, so its root is
# carved back as an external_directory allow or --with would be unreadable on a
# read-only run. edit gets `--agent build --auto`: file tools are scoped to the
# job dir (hard external_directory deny + bundle exception) but SHELL IS NOT
# CONTAINED — opencode's own docs call command-directory inference best-effort,
# so a shell command can still touch anything your user can — and mutating
# tiers HONOUR project config, so the project's own opencode.json can widen
# them further. research/autonomous REFUSES: opencode has no OS sandbox (same
# answer as claude-native/cc). yolo pre-allows everything, by definition.
#
# Failure classes (repo conventions: lane-down markers + refusal evidence):
#   * region refusal ("hosted outside Europe and the United States") — PER-MODEL
#     refusal, never lane-down: the console instruction is surfaced and the
#     failover signal is written confirmed so the machinery may hop models.
#   * expired key ("API key has expired") — AUTH failure: this lane is marked
#     down and the renewal instruction surfaced; not a rate limit, never an
#     outage for other lanes.
#   * plan/usage-limit phrasing — Go limits are PER-MODEL (monthly allowance
#     plus rolling windows), so _opencode_plan_limit probes a sibling model
#     but marks the lane DOWN only when the probe's own refusal names an
#     account-wide window; a second model-scoped refusal stays a model refusal.
#     Bare 429/throttling is transport, not a plan limit: the detector anchors
#     on explicit plan/allowance/window wording like the sibling lanes.
# =============================================================================

# Anchored phrasing only, matched against a FAILED run's captured stderr. Only
# explicit plan / allowance / window wording lands here — the same principle the
# sibling lane matchers use (cline: inference_cap_error + window nouns; cc/cx:
# "usage limit reached"). Bare `rate limit`/`429`/`too many requests`/
# `resource_exhausted` are deliberately ABSENT: they fire on task prose ("assert
# the rate limit renders") and on transient provider throttling, which is a
# transport failure, not a spent plan.
_OPENCODE_PLAN_LIMIT_RE='usage[ -]?limit[^.]{0,40}(reached|exceeded|exhausted|hit)|monthly allowance|allowance[^.]{0,30}(reached|exceeded|exhausted|spent)|(5[- ]?hour|daily|weekly|monthly)[[:space:]]+(usage[[:space:]]+)?(limit|window|allowance|quota)[^.]{0,40}(reached|exceeded|exhausted|hit|spent)|quota[^.]{0,30}(exceeded|exhausted|reached|spent)|insufficient[[:space:]]+(funds?|credits?|balance|quota)|plan[ -]?wide[[:space:]]+(limit|quota)[^.]{0,30}(reached|exceeded)'
# Wording that names an ACCOUNT-WIDE scope (rather than one model's allowance):
# only when a refusal carries one of these does a confirmed probe refusal mean
# the whole lane is spent. Kept deliberately narrow — marking a per-model
# refusal lane-down is the failure mode this avoids.
_OPENCODE_ACCOUNT_LIMIT_RE='account[- ]wide|across[[:space:]]+(all[[:space:]]+)?models|all[[:space:]]+models|whole[[:space:]]+(plan|account)|plan[- ]wide|workspace[- ]wide|organi[sz]ation[- ]wide|team[- ]wide|shared[[:space:]]+(limit|window|allowance|quota|bucket)'

_opencode_go_authed() {
  # Go credentials live in opencode's own auth store; `opencode auth list` prints
  # an "OpenCode Go" entry when one exists (a plain "OpenCode" entry is the Zen
  # pay-as-you-go credential and does NOT count). Output may carry ANSI markup.
  have opencode || return 1
  _timeout 10 opencode auth list 2>/dev/null | tr -d '\033' | sed 's/\[[0-9;]*[A-Za-z]//g' | grep -qi 'opencode *go'
}

_opencode_cli_missing() {
  die "opencode CLI not on PATH (OpenCode Go lane). Install: https://opencode.ai/docs (brew install opencode — or brew install anomalyco/tap/opencode-v2 — or npm i -g @opencode/cli@latest), then 'opencode auth login' and pick OpenCode Go. -m is a Go model id (glm-5.3-flash, kimi-k3.1-pro, ...); 'opencode models' lists them under opencode-go/."
}

# _opencode_ver -> '1' | '2' | '' (unparseable), parsed ONCE per process. The
# v1/v2 split decides the whole invocation surface: v2 needs --standalone (a
# shared background server never sees the CLI's env, so OPENCODE_CONFIG_CONTENT
# only reaches a private one), folds effort into -m as provider/model#variant,
# and speaks the action/resource/effect ruleset + hard `policies` layer; v1
# keeps its `permission` map + `--variant`. An unparseable or unknown major
# (v3+) returns EMPTY — callers must fail closed, never guess v1: a real v2
# install given the v1 schema and no --standalone launches UNENFORCED (same
# posture as the cline lane's version gate).
_opencode_ver() {
  if [ -z "${_OPENCODE_VER+x}" ]; then
    _OPENCODE_VER="$(opencode --version 2>/dev/null | tr -cd '0-9.\n' | grep -oE '[0-9]+' | head -1)"
    case "$_OPENCODE_VER" in 1|2) ;; *) _OPENCODE_VER= ;; esac
  fi
  printf '%s' "$_OPENCODE_VER"
}
_opencode_v2() { [ "$(_opencode_ver)" = "2" ]; }

_opencode_gate() {  # lane gate_fn: cli presence is handled by the cli= field
  # A non-Go provider/id model does not need Go credentials at all: without the
  # opt-in the delegate refuses it with the billing error, and with
  # OSRC_OPENCODE_ALLOW_NONGO=1 it runs on the chosen provider's own auth.
  case "${MODEL:-}" in */*) case "$MODEL" in opencode-go/*) ;; *) return 0 ;; esac ;; esac
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
# slip through any enumeration). scoped: the mutating tiers — file tools are
# denied outside the job dir but SHELL IS NOT (opencode's docs call directory
# inference best-effort, so a shell command keeps your user's full rights).
# allowall: yolo only.
#
# v2 emits BOTH `permissions` and `policies` (tool.use statements). Policies are
# the layer applied AFTER agent rules and saved approvals — top-level
# permissions alone lose to `agents.<id>.permissions` appended later (the
# shipped `plan` agent can write under ~/.opencode/plan; a user allow-all agent
# silently re-opens everything). A PROJECT config (opencode.json(c)/.opencode/)
# loads after this inline one and its own policies evaluate last, so it can
# still reopen everything — read-only callers set
# OPENCODE_DISABLE_PROJECT_CONFIG=1 on the opencode invocation to skip the
# project layer entirely (verified on v2.2.6: hostile project
# policies+agents.plan allow-all reopened writes via both the root
# opencode.json and .opencode/opencode.json forms; the env var denied both).
#
# The broad read allow (and scoped `*` allow) masks opencode's built-in
# `*.env`/`*.env.*` "ask" — sensitive files are re-denied AFTER the allows in
# both layers (.env.example stays readable, matching the built-in exception).
#
# The staged skill bundle lives outside the job dir, so its root is carved back
# as an external_directory allow in both layers or --with would be unreadable.
#
# v1 emits its `permission` map (bash/task action names, no policies — that
# layer does not exist on v1, so user agent-level overrides remain a residual
# gap there). An UNPARSEABLE version emits NOTHING for readonly/scoped: the
# caller's non-empty guard then refuses to launch unenforced.
_opencode_config_json() {
  local mode="$1" root="${2:-}" ver; ver="$(_opencode_ver)"
  if [ "$ver" = "1" ]; then
    case "$mode" in
      readonly)
        if [ -n "$root" ]; then
          jq -cn --arg root "$root" '{permission:{"*":"deny",edit:"deny",write:"deny",patch:"deny",bash:"deny",doom_loop:"deny",task:"deny",webfetch:"deny",websearch:"deny",read:{"*":"allow","*.env":"deny","*.env.*":"deny","*.envrc":"deny","*.env.example":"allow"},glob:"allow",grep:"allow",list:"allow",question:"allow",external_directory:{"*":"deny",($root):"allow",($root+"/*"):"allow",($root+"/**"):"allow"}}}'
        else
          printf '%s' '{"permission":{"*":"deny","edit":"deny","write":"deny","patch":"deny","bash":"deny","doom_loop":"deny","task":"deny","webfetch":"deny","websearch":"deny","read":{"*":"allow","*.env":"deny","*.env.*":"deny","*.envrc":"deny","*.env.example":"allow"},"glob":"allow","grep":"allow","list":"allow","question":"allow","external_directory":"deny"}}'
        fi ;;
      scoped)
        if [ -n "$root" ]; then
          jq -cn --arg root "$root" '{permission:{"*":"allow",read:{"*.env":"deny","*.env.*":"deny","*.envrc":"deny","*.env.example":"allow"},external_directory:{"*":"deny",($root):"allow",($root+"/*"):"allow",($root+"/**"):"allow"}}}'
        else
          printf '%s' '{"permission":{"*":"allow","read":{"*.env":"deny","*.env.*":"deny","*.envrc":"deny","*.env.example":"allow"},"external_directory":"deny"}}'
        fi ;;
      allowall) printf '%s' '{"permission":{"*":"allow","doom_loop":"allow","external_directory":"allow"}}' ;;
      *)        printf '%s' '{}' ;;
    esac
    return
  fi
  if [ -z "$ver" ]; then case "$mode" in readonly|scoped) return 0 ;; esac; fi
  case "$mode" in
    readonly)
      if [ -n "$root" ]; then
        jq -cn --arg root "$root" '{permissions:[{action:"*",resource:"*",effect:"deny"},{action:"read",resource:"*",effect:"allow"},{action:"read",resource:"*.env",effect:"deny"},{action:"read",resource:"*.env.*",effect:"deny"},{action:"read",resource:"*.envrc",effect:"deny"},{action:"read",resource:"*.env.example",effect:"allow"},{action:"glob",resource:"*",effect:"allow"},{action:"grep",resource:"*",effect:"allow"},{action:"question",resource:"*",effect:"allow"},{action:"external_directory",resource:$root,effect:"allow"},{action:"external_directory",resource:($root+"/*"),effect:"allow"},{action:"external_directory",resource:($root+"/**"),effect:"allow"}],policies:[{action:"tool.use",resource:"*",effect:"deny"},{action:"tool.use",resource:"read:*",effect:"allow"},{action:"tool.use",resource:"read:*.env",effect:"deny"},{action:"tool.use",resource:"read:*.env.*",effect:"deny"},{action:"tool.use",resource:"read:*.envrc",effect:"deny"},{action:"tool.use",resource:"read:*.env.example",effect:"allow"},{action:"tool.use",resource:"glob:*",effect:"allow"},{action:"tool.use",resource:"grep:*",effect:"allow"},{action:"tool.use",resource:"question:*",effect:"allow"},{action:"tool.use",resource:("external_directory:"+$root),effect:"allow"},{action:"tool.use",resource:("external_directory:"+$root+"/*"),effect:"allow"}]}'
      else
        printf '%s' '{"permissions":[{"action":"*","resource":"*","effect":"deny"},{"action":"read","resource":"*","effect":"allow"},{"action":"read","resource":"*.env","effect":"deny"},{"action":"read","resource":"*.env.*","effect":"deny"},{"action":"read","resource":"*.envrc","effect":"deny"},{"action":"read","resource":"*.env.example","effect":"allow"},{"action":"glob","resource":"*","effect":"allow"},{"action":"grep","resource":"*","effect":"allow"},{"action":"question","resource":"*","effect":"allow"}],"policies":[{"action":"tool.use","resource":"*","effect":"deny"},{"action":"tool.use","resource":"read:*","effect":"allow"},{"action":"tool.use","resource":"read:*.env","effect":"deny"},{"action":"tool.use","resource":"read:*.env.*","effect":"deny"},{"action":"tool.use","resource":"read:*.envrc","effect":"deny"},{"action":"tool.use","resource":"read:*.env.example","effect":"allow"},{"action":"tool.use","resource":"glob:*","effect":"allow"},{"action":"tool.use","resource":"grep:*","effect":"allow"},{"action":"tool.use","resource":"question:*","effect":"allow"}]}'
      fi ;;
    scoped)
      if [ -n "$root" ]; then
        jq -cn --arg root "$root" '{permissions:[{action:"*",resource:"*",effect:"allow"},{action:"read",resource:"*.env",effect:"deny"},{action:"read",resource:"*.env.*",effect:"deny"},{action:"read",resource:"*.envrc",effect:"deny"},{action:"read",resource:"*.env.example",effect:"allow"},{action:"external_directory",resource:"*",effect:"deny"},{action:"external_directory",resource:$root,effect:"allow"},{action:"external_directory",resource:($root+"/*"),effect:"allow"},{action:"external_directory",resource:($root+"/**"),effect:"allow"}],policies:[{action:"tool.use",resource:"read:*.env",effect:"deny"},{action:"tool.use",resource:"read:*.env.*",effect:"deny"},{action:"tool.use",resource:"read:*.envrc",effect:"deny"},{action:"tool.use",resource:"read:*.env.example",effect:"allow"},{action:"tool.use",resource:"external_directory:*",effect:"deny"},{action:"tool.use",resource:("external_directory:"+$root),effect:"allow"},{action:"tool.use",resource:("external_directory:"+$root+"/*"),effect:"allow"}]}'
      else
        printf '%s' '{"permissions":[{"action":"*","resource":"*","effect":"allow"},{"action":"read","resource":"*.env","effect":"deny"},{"action":"read","resource":"*.env.*","effect":"deny"},{"action":"read","resource":"*.envrc","effect":"deny"},{"action":"read","resource":"*.env.example","effect":"allow"},{"action":"external_directory","resource":"*","effect":"deny"}],"policies":[{"action":"tool.use","resource":"read:*.env","effect":"deny"},{"action":"tool.use","resource":"read:*.env.*","effect":"deny"},{"action":"tool.use","resource":"read:*.envrc","effect":"deny"},{"action":"tool.use","resource":"read:*.env.example","effect":"allow"},{"action":"tool.use","resource":"external_directory:*","effect":"deny"}]}'
      fi ;;
    allowall) printf '%s' '{"permissions":[{"action":"*","resource":"*","effect":"allow"}]}' ;;
    *)        printf '%s' '{}' ;;
  esac
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
    _opencode_plan_limit "$f" "$m"
    return 0
  fi
  return 1
}

# _opencode_plan_limit <errfile> <model>: probe-then-decide with PER-MODEL
# semantics — Go limits live on the model (monthly allowance plus rolling
# windows), so a refused model plus a refused probe model does NOT prove the
# lane is spent the way it would on a shared-bucket lane. The lane goes DOWN
# only when the probe's own refusal names an ACCOUNT-WIDE window
# (_OPENCODE_ACCOUNT_LIMIT_RE); every other outcome is a confirmed model
# refusal: the failover machinery may hop to another Go model, and no lane
# marker is written.
_opencode_plan_limit() {
  local f="$1" m="$2" line reset secs="" ttl verdict pline
  line="$(_lane_plan_limit_line opencode "$f")"
  reset="$(_lane_limit_reset_phrase "$f")"
  [ -n "$reset" ] && secs="$(_lane_limit_reset_secs "$reset")"
  ttl="${OSRC_LANE_PLAN_DOWN_TTL:-3600}"; case "$ttl" in ''|*[!0-9]*) ttl=3600 ;; esac
  [ -n "$secs" ] && ttl=$(( secs + 60 ))
  printf '>>> [opencode plan limit] OpenCode Go refused "%s" citing a plan/usage limit%s. Go limits are per model — verifying with one sibling model before deciding anything.\n' "$m" "${reset:+ (it says: $reset)}" >&2
  [ -n "$line" ] && printf '>>> [opencode plan limit] exact wording (for tightening this detector): %s\n' "$line" >&2
  verdict="$(_lane_free_probe opencode "$m")"
  pline=""; [ -s "$(_lane_probe_file opencode)" ] && pline="$(LC_ALL=C head -c 160 "$(_lane_probe_file opencode)" | LC_ALL=C tr '\n' ' ' | _utf8_sanitize 2>/dev/null | LC_ALL=C sed -E 's/[[:space:]]+$//')"
  case "$verdict" in
    limit-refused)
      printf '>>> [opencode plan limit] probe CONFIRMED an account-wide window%s — lane marked DOWN for %s (clear early with: %s posture reset). Dispatch + fallback skip it until then.\n' "${pline:+ ($pline)}" "$(_fmt_secs_human "$ttl")" "$0" >&2
      _lane_down_mark opencode "$ttl" "plan limit exhausted (account-wide window)" "${line:-}${pline:+ | probe: $pline}" || true ;;
    answered)
      printf '>>> [opencode plan limit] probe ANSWERED — the lane is up; only "%s" is spent. Signalling a model hop.\n' "$m" >&2 ;;
    model-refused)
      printf '>>> [opencode plan limit] probe model refused on ITS OWN model-scoped terms%s — the lane stays UP: two models at their own limits is not a lane outage. Signalling a model hop.\n' "${pline:+ ($pline)}" >&2 ;;
    *)
      printf '>>> [opencode plan limit] probe INCONCLUSIVE — nothing proven either way; the lane stays unmarked (per-model refusals never mark it). Retries handle each refusal on its own.\n' >&2 ;;
  esac
  case "$verdict" in
    unreachable) _failover_signal_write opencode "$m" inconclusive "refused \"$m\" citing a plan/usage limit; probe inconclusive" "${secs:-}" 2>/dev/null ;;
    *)           _failover_signal_write opencode "$m" confirmed "model refused citing its plan/usage limit${secs:+ (resets in $(_fmt_secs_human "$secs"))}" "${secs:-}" 2>/dev/null ;;
  esac || true
  rm -f "$(_lane_probe_file opencode)" 2>/dev/null
  _quota_note_refusal opencode "$m" 2>/dev/null || true
  return 0
}

# _opencode_free_probe -> printed verdict for _lane_free_probe's opencode arm.
# Probe: cheapest Go model, bounded, stdin closed, plan agent. Verdicts:
#   answered        the probe model said OK — the lane works
#   limit-refused   the probe's refusal names an ACCOUNT-WIDE window — the only
#                   verdict that may mark the lane down
#   model-refused   the probe refused on model-scoped terms (region, or a
#                   per-model allowance) — proves nothing about the lane
#   unreachable     timeout / CLI missing / anything else
_opencode_free_probe() {
  local out="" rc=0 secs="${OSRC_LANE_PROBE_SECS:-30}" po sa=()
  case "$secs" in ''|*[!0-9]*) secs=30 ;; esac
  if _mkdir_private "$OSRC_HOME" >/dev/null 2>&1; then
    out="$(_lane_probe_file opencode)"; : > "$out" 2>/dev/null && chmod 600 "$out" 2>/dev/null || out=""
  fi
  if ! have opencode; then [ -n "$out" ] && printf 'opencode CLI not on PATH\n' > "$out"; printf 'unreachable'; return 0; fi
  [ "$(_opencode_ver)" = "2" ] && sa=(--standalone)
  _timeout "$secs" env OPENCODE_CONFIG_CONTENT="$(_opencode_config_json readonly)" OPENCODE_DISABLE_PROJECT_CONFIG=1 opencode ${sa[@]+"${sa[@]}"} run --agent plan -m "$(_opencode_probe_model "$1")" "reply OK" </dev/null > "${out:-/dev/null}" 2>&1 || rc=$?
  po=""; [ -n "$out" ] && po="$(LC_ALL=C tr -d '\033' < "$out" 2>/dev/null | LC_ALL=C sed 's/\[[0-9;]*[A-Za-z]//g')"
  if printf '%s' "$po" | grep -qi 'hosted outside Europe and the United States\|Select Global at ' 2>/dev/null; then printf 'model-refused'; return 0; fi
  if printf '%s' "$po" | grep -qiE "$_OPENCODE_PLAN_LIMIT_RE" 2>/dev/null; then
    if printf '%s' "$po" | grep -qiE "$_OPENCODE_ACCOUNT_LIMIT_RE" 2>/dev/null; then printf 'limit-refused'; else printf 'model-refused'; fi
    return 0
  fi
  if [ "$rc" -eq 0 ] && printf '%s' "$po" | grep -qiE '(^|[^A-Za-z])OK([^A-Za-z]|$)' 2>/dev/null; then printf 'answered'; return 0; fi
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
  local aflag=() posture cfg v; v="$(_opencode_ver)"
  case "$tier" in
    auto)         aflag=(--agent plan);         cfg=readonly; posture="READ-ONLY (--agent plan + per-run deny-all policy re-allowing read/glob/grep/question only)" ;;
    accept-edits) aflag=(--agent build --auto); cfg=scoped;   posture="MUTATING (build agent, --auto; file tools scoped to the job dir, shell runs with full user rights — no sandbox)" ;;
    autonomous)   die "opencode lane has NO OS sandbox; 'research' is unsafe here (a build agent would run with your full user rights). Use --provider codex/devin for sandboxed exec, or run/explore/edit/yolo on this lane. Nothing was run." ;;
    dangerous)    aflag=(--agent build --auto); cfg=allowall; posture="DANGER (build agent, --auto, all permissions pre-allowed; no sandbox)" ;;
    *) die "delegate_opencode: bad tier: $tier" ;;
  esac
  case "$tier:$v" in auto:|accept-edits:)
    die "opencode lane: cannot parse 'opencode --version' — supported majors are 1.x (read-only posture enforced; user agent-rule overrides remain a residual gap) and 2.x (recommended, adds the hard policies layer). A 0.x install (brew install opencode-ai/tap/opencode, npm i -g opencode-ai) predates both — upgrade with brew install opencode or npm i -g @opencode/cli@latest. Guessing the schema would launch '$tier' unenforced, so refusing (same fail-closed posture as the cline lane). Nothing was run." ;; esac
  local eff=() oe=""
  if [ -n "${EFFORT:-}" ]; then
    oe="$(_opencode_effort "$EFFORT")"
    if [ -n "$oe" ]; then
      if [ "$v" = "2" ]; then id="$id#$oe"; elif [ "$v" = "1" ]; then eff=(--variant "$oe"); else printf '%s\n' "note: opencode: --effort $EFFORT skipped — version unparseable, variant syntax unknown" >&2; fi
    else
      printf '%s\n' "note: opencode: --effort $EFFORT has no variant equivalent; ignoring" >&2
    fi
  fi
  local ttier; ttier="$(resolve_tier "${MODEL:-}" "${TTIER:-}")" || ttier="capable"
  _with_preamble_render "bundle"
  local wrapped; wrapped="$(_build_prompt "$id" "$task" "$ttier" "bundle")"
  if [ -n "${WITH_BUNDLE_ROOT:-}" ] && ! have jq; then die "opencode: jq is required to carve the staged skill bundle into the per-run config. Nothing was run."; fi
  local oc_cfg; oc_cfg="$(_opencode_config_json "$cfg" "${WITH_BUNDLE_ROOT:-}")"
  [ -n "$oc_cfg" ] || die "opencode: refusing to run unenforced — the per-run permission config came out empty. Nothing was run."
  if have jq && ! printf '%s' "$oc_cfg" | jq -e . >/dev/null 2>&1; then die "opencode: refusing to run unenforced — the per-run permission config is not valid JSON. Nothing was run."; fi
  _tier_banner "opencode (OpenCode Go)" "$id" "$ttier" "$posture | $(_lane_cost_disclosure opencode)"
  local rc=0 _lerr sa=() pcenv=(); _lerr="$(_lane_errfile)"
  [ "$v" = "2" ] && sa=(--standalone)   # the shared background server ignores the per-run env config; a private one reads it
  # A project opencode.json(c)/.opencode/ loads AFTER the inline config and its own policies
  # evaluate last, so a hostile project reopens the denies (verified on v2.2.6). Read-only runs
  # skip the project layer entirely; mutating tiers honour it by design.
  [ "$cfg" = "readonly" ] && pcenv=(OPENCODE_DISABLE_PROJECT_CONFIG=1)
  _run_tee_stderr "$_lerr" env OPENCODE_CONFIG_CONTENT="$oc_cfg" ${pcenv[@]+"${pcenv[@]}"} opencode ${sa[@]+"${sa[@]}"} run ${aflag[@]+"${aflag[@]}"} -m "$id" ${eff[@]+"${eff[@]}"} -- "$wrapped" </dev/null || rc=$?
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
    echo "    opencode: NOT on PATH — install: https://opencode.ai/docs (brew install opencode or anomalyco/tap/opencode-v2 or npm i -g @opencode/cli@latest), then 'opencode auth login' -> OpenCode Go"
    return 0
  fi
  echo "    opencode: $(opencode --version 2>/dev/null | head -1 || echo present)$([ -n "$(_opencode_ver)" ] || printf ' — WARNING: version unparseable (supported majors: 1.x, 2.x), read-only/edit tiers will refuse until resolved') — route: --provider opencode run -m <go-model-id> \"task\" (a bare id becomes opencode-go/<id>; 'opencode models' lists them)"
  if ! _opencode_go_authed; then
    echo "    opencode Go: NO OpenCode Go credential — run 'opencode auth login' and choose OpenCode Go (a plain 'OpenCode' entry is Zen pay-as-you-go, not Go)"
    return 0
  fi
  echo "    opencode Go: credential present. Models: opencode models | grep '^opencode-go/'"
  if [ "$_doff" = "1" ]; then echo "    opencode liveness: probe skipped (OSRC_DOCTOR_OFFLINE)"
  elif [ "${OSRC_DOCTOR_PROBE:-1}" = "1" ]; then
    local _pt _pte _prc=0 _dps="${OSRC_DOCTOR_PROBE_TIMEOUT_SECS:-30}" _dsa=()
    case "$_dps" in ''|*[!0-9]*) _dps=30 ;; esac
    _opencode_v2 && _dsa=(--standalone)
    _pt="$(_timeout "$_dps" env OPENCODE_CONFIG_CONTENT="$(_opencode_config_json readonly)" OPENCODE_DISABLE_PROJECT_CONFIG=1 opencode ${_dsa[@]+"${_dsa[@]}"} run --agent plan -m opencode-go/glm-5.3-flash "Reply with exactly: OK" </dev/null 2>&1)" || _prc=$?
    case "$_pt" in
      *"hosted outside Europe"*|*"Select Global"*)
        echo "    opencode liveness: LANE UP, probe model region-refused — glm-5.3-flash is hosted outside Europe/US; select Global at https://opencode.ai/console -> Settings > Privacy > Regions, or run with another Go model" ;;
      *"API key has expired"*|*"Create a new API key"*)
        echo "    opencode liveness: AUTH FAILURE — the Go API key has expired; create a new key in OpenCode Console and re-login: opencode auth login"
        _lane_down_mark opencode "${OSRC_LANE_DOWN_TTL:-300}" "OpenCode Go API key expired" 2>/dev/null || true ;;
      *)
        # READY needs the same anchored word-boundary OK _opencode_free_probe uses, anchored to
        # the END of the ANSI-stripped output (its last line): an HTTP "200 OK" status line or an
        # OK substring inside an error page must never read as a healthy answer (the probe asks
        # for exactly: OK). Portable ERE grep — no \b, no grep -w.
        _pte="$(printf '%s' "$_pt" | LC_ALL=C tr -d '\033' | LC_ALL=C sed 's/\[[0-9;]*[A-Za-z]//g')"
        _pte="${_pte%"${_pte##*[![:space:]]}"}"
        if printf '%s' "$_pt" | grep -qiE "$_OPENCODE_PLAN_LIMIT_RE"; then
          echo "    opencode liveness: lane UP but Go plan allowance spent on the probe model (per-model monthly + 5h/weekly windows — OpenCode Console has the live figure)"
        elif [ "$_prc" -eq 0 ] && printf '%s\n' "$_pte" | tail -1 | grep -qiE '(^|[^A-Za-z])OK[[:space:]]*$' 2>/dev/null; then
          echo "    opencode liveness: READY — opencode-go/glm-5.3-flash answered (plan agent, read-only config, stdin closed)"
        elif [ "$_prc" -eq 0 ]; then
          echo "    opencode liveness: probe returned but did not echo OK — Go lane suspect"
        elif printf '%s' "$_pte" | grep -qiE '(^|[^A-Za-z])OK([^A-Za-z]|$)' 2>/dev/null; then
          echo "    opencode liveness: probe echoed OK but exited rc=$_prc — Go lane suspect"
        else
          echo "    opencode liveness: NOT ANSWERING (rc=$_prc) — try a manual 'opencode run -m opencode-go/glm-5.3-flash \"reply OK\" </dev/null'"
          _lane_down_mark opencode "${OSRC_LANE_DOWN_TTL:-300}" "doctor probe rc=$_prc" 2>/dev/null || true
        fi ;;
    esac
  fi
}
