# =============================================================================
# OpenCode lane. Bare model IDs use opencode-go; provider/model IDs pass through.
# Billing is unproven, so the shared spend gate requires per-command consent.
# There is no implicit model or failover target.
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
# opencode.json and .opencode/opencode.json forms — so all runs set
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
# tiers deny task/subagent calls, which could select another billed model.
# research/autonomous REFUSES: opencode has no OS sandbox. Yolo permits other tools.
#
# Failure classes (repo conventions: lane-down markers + refusal evidence):
#   * region refusal ("hosted outside Europe and the United States") — PER-MODEL
#     refusal, never lane-down: the console instruction is surfaced and the
#     failover signal is written confirmed so the machinery may hop models.
#   * expired key ("API key has expired") — AUTH failure: this lane is marked
#     down and the renewal instruction surfaced; not a rate limit, never an
#     outage for other lanes.
#   * plan/usage limits do not trigger another potentially paid probe.
#   * bare 429/throttling is transport, not a plan limit.
# =============================================================================

# Anchored phrasing only, matched against a FAILED run's captured stderr. Only
# explicit plan / allowance / window wording lands here — the same principle the
# sibling lane matchers use (cline: inference_cap_error + window nouns; cc/cx:
# "usage limit reached"). Bare `rate limit`/`429`/`too many requests`/
# `resource_exhausted` are deliberately ABSENT: they fire on task prose ("assert
# the rate limit renders") and on transient provider throttling, which is a
# transport failure, not a spent plan.
unset _OPENCODE_VER
_OPENCODE_PLAN_LIMIT_RE='usage[ -]?limit[^.]{0,40}(reached|exceeded|exhausted|hit)|monthly allowance|allowance[^.]{0,30}(reached|exceeded|exhausted|spent)|(5[- ]?hour|daily|weekly|monthly)[[:space:]]+(usage[[:space:]]+)?(limit|window|allowance|quota)[^.]{0,40}(reached|exceeded|exhausted|hit|spent)|quota[^.]{0,30}(exceeded|exhausted|reached|spent)|insufficient[[:space:]]+(funds?|credits?|balance|quota)|plan[ -]?wide[[:space:]]+(limit|quota)[^.]{0,30}(reached|exceeded)'

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

_opencode_gate() { :; }

_opencode_route_check() { have opencode || _opencode_cli_missing; _opencode_gate; }

_ready_probe_opencode() { have opencode && _opencode_go_authed && printf 'opencode=go'; }

# _opencode_model <raw -m token> -> the launchable `provider/id` for `opencode run -m`,
# or rc1 on refusal (the caller dies so the error is not lost inside $( ) as it would
# be if this function died in the subshell and the caller kept going with empty output).
_opencode_model() {
  local m="${1:-}"
  case "$m" in
    ''|*//*|*/) return 1 ;;                               # empty, empty id, or // path
    opencode-go/?*) printf '%s' "$m" ;;
    */*) printf '%s' "$m" ;;
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

# _osrc_native_path <path> -> the path as a native Windows program sees it.
# OpenCode on Windows is a node program: it matches external_directory against
# C:/Users/... paths, never the MSYS /c/Users/... spelling Git Bash hands us.
# Without this the rule depended on MSYS silently rewriting the bare /c/... argv
# passed to jq.exe (off under MSYS_NO_PATHCONV=1 / MSYS2_ARG_CONV_EXCL, absent
# with a non-native jq), so the bundle carve-out could name a folder OpenCode
# never sees. cygpath -m is a no-op on an already-native C:/ path.
# Mac/Linux paths pass through unchanged.
_osrc_native_path() {
  local p="$1" w
  if [ "${OSRC_PLATFORM:-}" = "windows" ] && command -v cygpath >/dev/null 2>&1; then
    w="$(cygpath -m "$p" 2>/dev/null)" && [ -n "$w" ] && p="$w"
  fi
  printf '%s\n' "$p"
}

# _opencode_config_json <readonly|scoped|allowall> [bundle_root] -> per-run config JSON.
# readonly: deny EVERYTHING first, then re-allow only the read family — a deny
# list that names mutating tools can never be complete (task/subagent, webfetch,
# websearch, skill, MCP and plugin tools all have their own actions and would
# slip through any enumeration). scoped: the mutating tiers — file tools are
# denied outside the job dir but SHELL IS NOT (opencode's docs call directory
# inference best-effort, so a shell command keeps your user's full rights).
# allowall: yolo, except task/subagent calls.
#
# v2 emits BOTH `permissions` and `policies` (tool.use statements). Policies are
# the layer applied AFTER agent rules and saved approvals — top-level
# permissions alone lose to `agents.<id>.permissions` appended later (the
# shipped `plan` agent can write under ~/.opencode/plan; a user allow-all agent
# silently re-opens everything). A PROJECT config (opencode.json(c)/.opencode/)
# loads after this inline one and its own policies evaluate last, so it can
# still reopen everything — all callers set
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
  [ -n "$root" ] && root="$(_osrc_native_path "$root")"
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
          jq -cn --arg root "$root" '{permission:{"*":"allow",task:"deny",read:{"*.env":"deny","*.env.*":"deny","*.envrc":"deny","*.env.example":"allow"},external_directory:{"*":"deny",($root):"allow",($root+"/*"):"allow",($root+"/**"):"allow"}}}'
        else
          printf '%s' '{"permission":{"*":"allow","task":"deny","read":{"*.env":"deny","*.env.*":"deny","*.envrc":"deny","*.env.example":"allow"},"external_directory":"deny"}}'
        fi ;;
      allowall) printf '%s' '{"permission":{"*":"allow","task":"deny","doom_loop":"allow","external_directory":"allow"}}' ;;
      *)        printf '%s' '{}' ;;
    esac
    return
  fi
  if [ -z "$ver" ]; then case "$mode" in readonly|scoped) return 0 ;; esac; fi
  case "$mode" in
    readonly)
      if [ -n "$root" ]; then
        jq -cn --arg root "$root" '{permissions:[{action:"*",resource:"*",effect:"deny"},{action:"read",resource:"*",effect:"allow"},{action:"read",resource:"*.env",effect:"deny"},{action:"read",resource:"*.env.*",effect:"deny"},{action:"read",resource:"*.envrc",effect:"deny"},{action:"read",resource:"*.env.example",effect:"allow"},{action:"glob",resource:"*",effect:"allow"},{action:"grep",resource:"*",effect:"allow"},{action:"question",resource:"*",effect:"allow"},{action:"external_directory",resource:$root,effect:"allow"},{action:"external_directory",resource:($root+"/*"),effect:"allow"},{action:"external_directory",resource:($root+"/**"),effect:"allow"}],policies:[{action:"tool.use",resource:"*",effect:"deny"},{action:"tool.use",resource:"read:*",effect:"allow"},{action:"tool.use",resource:"read:*.env",effect:"deny"},{action:"tool.use",resource:"read:*.env.*",effect:"deny"},{action:"tool.use",resource:"read:*.envrc",effect:"deny"},{action:"tool.use",resource:"read:*.env.example",effect:"allow"},{action:"tool.use",resource:"glob:*",effect:"allow"},{action:"tool.use",resource:"grep:*",effect:"allow"},{action:"tool.use",resource:"question:*",effect:"allow"},{action:"tool.use",resource:("external_directory:"+$root),effect:"allow"},{action:"tool.use",resource:("external_directory:"+$root+"/*"),effect:"allow"},{action:"tool.use",resource:("external_directory:"+$root+"/**"),effect:"allow"}]}'
      else
        printf '%s' '{"permissions":[{"action":"*","resource":"*","effect":"deny"},{"action":"read","resource":"*","effect":"allow"},{"action":"read","resource":"*.env","effect":"deny"},{"action":"read","resource":"*.env.*","effect":"deny"},{"action":"read","resource":"*.envrc","effect":"deny"},{"action":"read","resource":"*.env.example","effect":"allow"},{"action":"glob","resource":"*","effect":"allow"},{"action":"grep","resource":"*","effect":"allow"},{"action":"question","resource":"*","effect":"allow"}],"policies":[{"action":"tool.use","resource":"*","effect":"deny"},{"action":"tool.use","resource":"read:*","effect":"allow"},{"action":"tool.use","resource":"read:*.env","effect":"deny"},{"action":"tool.use","resource":"read:*.env.*","effect":"deny"},{"action":"tool.use","resource":"read:*.envrc","effect":"deny"},{"action":"tool.use","resource":"read:*.env.example","effect":"allow"},{"action":"tool.use","resource":"glob:*","effect":"allow"},{"action":"tool.use","resource":"grep:*","effect":"allow"},{"action":"tool.use","resource":"question:*","effect":"allow"}]}'
      fi ;;
    scoped)
      if [ -n "$root" ]; then
        jq -cn --arg root "$root" '{permissions:[{action:"*",resource:"*",effect:"allow"},{action:"task",resource:"*",effect:"deny"},{action:"read",resource:"*.env",effect:"deny"},{action:"read",resource:"*.env.*",effect:"deny"},{action:"read",resource:"*.envrc",effect:"deny"},{action:"read",resource:"*.env.example",effect:"allow"},{action:"external_directory",resource:"*",effect:"deny"},{action:"external_directory",resource:$root,effect:"allow"},{action:"external_directory",resource:($root+"/*"),effect:"allow"},{action:"external_directory",resource:($root+"/**"),effect:"allow"}],policies:[{action:"tool.use",resource:"task:*",effect:"deny"},{action:"tool.use",resource:"read:*.env",effect:"deny"},{action:"tool.use",resource:"read:*.env.*",effect:"deny"},{action:"tool.use",resource:"read:*.envrc",effect:"deny"},{action:"tool.use",resource:"read:*.env.example",effect:"allow"},{action:"tool.use",resource:"external_directory:*",effect:"deny"},{action:"tool.use",resource:("external_directory:"+$root),effect:"allow"},{action:"tool.use",resource:("external_directory:"+$root+"/*"),effect:"allow"},{action:"tool.use",resource:("external_directory:"+$root+"/**"),effect:"allow"}]}'
      else
        printf '%s' '{"permissions":[{"action":"*","resource":"*","effect":"allow"},{"action":"task","resource":"*","effect":"deny"},{"action":"read","resource":"*.env","effect":"deny"},{"action":"read","resource":"*.env.*","effect":"deny"},{"action":"read","resource":"*.envrc","effect":"deny"},{"action":"read","resource":"*.env.example","effect":"allow"},{"action":"external_directory","resource":"*","effect":"deny"}],"policies":[{"action":"tool.use","resource":"task:*","effect":"deny"},{"action":"tool.use","resource":"read:*.env","effect":"deny"},{"action":"tool.use","resource":"read:*.env.*","effect":"deny"},{"action":"tool.use","resource":"read:*.envrc","effect":"deny"},{"action":"tool.use","resource":"read:*.env.example","effect":"allow"},{"action":"tool.use","resource":"external_directory:*","effect":"deny"}]}'
      fi ;;
    allowall) printf '%s' '{"permissions":[{"action":"*","resource":"*","effect":"allow"},{"action":"task","resource":"*","effect":"deny"}],"policies":[{"action":"tool.use","resource":"task:*","effect":"deny"}]}' ;;
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

# Never issue a second request to classify a limit: Go extra usage may bill.
_opencode_plan_limit() {
  local f="$1" m="$2" reset secs=""
  reset="$(_lane_limit_reset_phrase "$f")"
  [ -n "$reset" ] && secs="$(_lane_limit_reset_secs "$reset")"
  printf '>>> [opencode plan limit] model %s was refused; no additional paid probe was run.\n' "$m" >&2
  _failover_signal_write opencode "$m" inconclusive "model refused citing a plan/usage limit" "$secs" 2>/dev/null || true
  _quota_note_refusal opencode "$m" 2>/dev/null || true
}

delegate_opencode() {
  local tier="$1"
  [ "${#REST[@]}" -gt 0 ] || die "no task prompt given"
  local task="${REST[*]}" id="${MODEL:-}"
  have opencode || _opencode_cli_missing
  [ -n "$id" ] || die "the opencode lane needs -m <go-model-id> (e.g. glm-5.3-flash or opencode-go/glm-5.3-flash; the lane has no default — a bare run would fall back to opencode's own configured model, which may not bill your Go plan). Nothing was run."
  id="$(_opencode_model "$id")" || die "opencode: invalid model id. Nothing was run."
  _validate_model_token "$id"
  local aflag=() posture cfg v; v="$(_opencode_ver)"
  case "$tier" in
    auto)         aflag=(--agent plan);         cfg=readonly; posture="READ-ONLY (--agent plan + per-run deny-all policy re-allowing read/glob/grep/question only)" ;;
    accept-edits) aflag=(--agent build --auto); cfg=scoped;   posture="MUTATING (build agent, --auto; file tools scoped to the job dir, shell runs with full user rights — no sandbox)" ;;
    autonomous)   die "opencode lane has NO OS sandbox; 'research' is unsafe here (a build agent would run with your full user rights). Use --provider codex/devin for sandboxed exec, or run/explore/edit/yolo on this lane. Nothing was run." ;;
    dangerous)    aflag=(--agent build --auto); cfg=allowall; posture="DANGER (build agent, --auto, task subagents denied; no sandbox)" ;;
    *) die "delegate_opencode: bad tier: $tier" ;;
  esac
  case "$tier:$v" in auto:|accept-edits:|dangerous:)
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
  # evaluate last, so every tier skips the project layer.
  pcenv=(OPENCODE_DISABLE_PROJECT_CONFIG=1)
  _run_tee_stderr "$_lerr" env -u OPENCODE_CONFIG -u OPENCODE_CONFIG_DIR -u OPENCODE_PERMISSION OPENCODE_CONFIG_CONTENT="$oc_cfg" ${pcenv[@]+"${pcenv[@]}"} opencode ${sa[@]+"${sa[@]}"} run ${aflag[@]+"${aflag[@]}"} -m "$id" ${eff[@]+"${eff[@]}"} -- "$wrapped" </dev/null || rc=$?
  _opencode_classify "$_lerr" "$id" "$rc" || true
  [ -n "$_lerr" ] && rm -f "$_lerr" 2>/dev/null
  record_ledger opencode "$id" "$ttier" "$tier" "$task" "" opencode
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
    "cost_class=credits" \
    "cost_disclosure=billing may be paid; spend consent required when unproven" \
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
  echo "    opencode liveness: probe skipped (billing cannot be verified without spend consent)"
}

_opencode_fanout_check() {
  local model="${1:-}" route="${2:-}" label="${3:-}" front="${4:-}"
  [ -z "$model" ] && [ -n "$route" ] && model="$(_route_match "$label" "$route")"
  [ -n "$model" ] || model="$front"
  [ -n "$model" ] || die "fanout: lane 'opencode' needs a model for every job. Nothing was started."
}
