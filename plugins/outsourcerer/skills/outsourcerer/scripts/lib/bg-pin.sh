# The relay owns the result pipe. Fd 18 is original stderr for spend prompts;
# the relay's one-shot secret descriptor is closed before the script is sourced.

_osrc_preflight_record() {
  [ "${OSRC_PREFLIGHT:-0}" = 1 ] && [ "${_OSRC_PREFLIGHT_FD:-0}" = 1 ] || return 0
  _OSRC_PREFLIGHT_LANE="$1"; _OSRC_PREFLIGHT_MODEL="$2"; _OSRC_PREFLIGHT_AUTH="$3"
}

# The routing shell never holds the relay's result pipe. Only the authenticated
# route record is sent through the private FIFO after all preflight gates pass.
_osrc_route_dispatch() {
  if [ "${_OSRC_PREFLIGHT_FD:-0}" != 1 ]; then route_delegate "$@"; return $?; fi
  _OSRC_PREFLIGHT_LANE=""; _OSRC_PREFLIGHT_MODEL=""; _OSRC_PREFLIGHT_AUTH=0; ROUTE_LANE=""
  route_delegate "$@" || return $?
  [ -n "${_OSRC_PREFLIGHT_LANE:-}" ] && [ -n "${_OSRC_PREFLIGHT_MODEL:-}" ] && [ -n "${ROUTE_LANE:-}" ] && [ -n "${PROVIDER:-}" ] || return 1
  local pin_provider; pin_provider="$(_osrc_pin_provider "$ROUTE_LANE")" || return 1
  _osrc_relay_emit "$_OSRC_PREFLIGHT_LANE|$_OSRC_PREFLIGHT_MODEL|$ROUTE_LANE|$pin_provider|$_OSRC_PREFLIGHT_AUTH"
}

_osrc_relay_emit() { printf '%s\n' "$_OSRC_RELAY_SECRET" | "$_OSRC_RELAY_PYTHON" -I "$_OSRC_FACTORY_DIR/lib/bg-relay.py" --emit "$_OSRC_RELAY_FIFO" "$1"; }

_osrc_pinned_assert() {
  [ -n "${_OSRC_PIN_DISP:-}" ] || return 0
  [ "$1" = "$_OSRC_PIN_DISP" ] && [ "$2" = "$_OSRC_PIN_MODEL" ] || die "bg: pinned route changed from $_OSRC_PIN_DISP/$_OSRC_PIN_MODEL to $1/$2; refusing to dispatch."
}

_osrc_pin_provider() {
  case "$1" in
    devin) printf devin ;; cxnative|codexor) printf codex ;; ccnative|ccor) printf cc ;;
    gmnative) printf gemini ;; local|claudex|droid|cursor|hermes|warp|cline|pi|grokbot|tokenrouter|opencode) printf '%s' "$1" ;;
    *) return 1 ;;
  esac
}

# A pinned child reuses the approved dispatch, but still runs the lane's CLI
# and provider-conflict guards before the normal quota, spend and cloud gates.
_osrc_pinned_resolve() {
  [ "$MODEL" = "$_OSRC_PIN_MODEL" ] || die "bg: pinned model changed; refusing to dispatch."
  [ "$PROVIDER" = "$(_osrc_pin_provider "$_OSRC_PIN_DISP")" ] || die "bg: pinned provider changed; refusing to dispatch."
  # The internal flag is still user-supplied argv, so it cannot bypass image
  # or unambiguous native-family guards. Engine providers own their catalogs.
  if ! _provider_owns_catalog "$PROVIDER" && [ "$PROVIDER" != claudex ]; then
    local _pin_row _pin_lane _pin_family
    _pin_row="$(resolve_model_row "$MODEL")"
    if [ -n "$_pin_row" ]; then
      _pin_lane="${_pin_row#*|}"; _pin_lane="${_pin_lane%%|*}"
      _lane_flag "$_pin_lane" image_lane && _die_image_lane
    fi
    _pin_family="$(lane_from_name "$MODEL" 2>/dev/null)"
    case "$_pin_family" in
      cc) [ "$_OSRC_PIN_DISP" = ccnative ] || die "bg: pinned model requires the Claude native lane." ;;
      cx) [ "$_OSRC_PIN_DISP" = cxnative ] || die "bg: pinned model requires the Codex native lane." ;;
      gm) [ "$_OSRC_PIN_DISP" = gmnative ] || die "bg: pinned model requires the Gemini native lane." ;;
      opencode) [ "$_OSRC_PIN_DISP" = opencode ] || die "bg: pinned model requires the OpenCode lane." ;;
    esac
  fi
  RESOLVED_ID="$_OSRC_PIN_MODEL"; disp="$_OSRC_PIN_DISP"
  case "$disp" in
    ccnative) _route_check_cc ;;
    cxnative) _route_check_cx ;;
    claudex) RESOLVED_LANE="$(lane_from_name "$MODEL" 2>/dev/null)"; _route_provider_claudex ;;
    droid|cursor|hermes|warp|cline|pi|grokbot|tokenrouter|opencode) _lane_cli_gate "$(_lane_by_provider "$PROVIDER")" ;;
  esac
}

_osrc_preflight_native() {
  [ "${_OSRC_PREFLIGHT_FD:-0}" = 1 ] || return 0
  local original="$RESOLVED_ID" resolved="$RESOLVED_ID"
  case "$disp" in
    devin) resolved="$(_devin_resolve_model "$RESOLVED_ID")" ;;
    droid|warp) resolved="$(_lane_model_for "$disp" "$RESOLVED_ID")" ;;
    opencode) resolved="$(_opencode_model "$RESOLVED_ID")" || die "bg: invalid OpenCode model; specify -m." ;;
  esac
  [ -n "$resolved" ] || die "bg: could not resolve the provider's model; specify -m."
  _exclude_refuse_resolved "$original" "$resolved"
  RESOLVED_ID="$resolved"
}

# Replace only leading model flags, never task text or another flag's value.
_osrc_pin_argv() {
  local verb="$1"; shift
  _OSRC_PIN_ARGV=("$verb" -m "$_OSRC_PIN_MODEL")
  while [ $# -gt 0 ]; do
    case "$1" in
      -m|--model) shift 2 ;;
      --tier|--with|--perm|--account|--cap|--trust-lane|--effort|--reasoning) _OSRC_PIN_ARGV+=("$1" "$2"); shift 2 ;;
      --perm=*|--cap=*|--allow-downgrade|--force-lane|--spend-ok|--no-advise|--cloud-ack|--wait|--foreground) _OSRC_PIN_ARGV+=("$1"); shift ;;
      *) _OSRC_PIN_ARGV+=("$@"); break ;;
    esac
  done
}

_osrc_pin_internal_args() {
  _OSRC_PIN_ARGS=()
  [ -z "${_OSRC_PIN_DISP:-}" ] || _OSRC_PIN_ARGS=(--osrc-pinned-route "$_OSRC_PIN_DISP" "$_OSRC_PIN_MODEL")
}

_osrc_preflight_unpack() {
  local record="$1" extra=""
  IFS='|' read -r _OSRC_PIN_LANE _OSRC_PIN_MODEL _OSRC_PIN_DISP _OSRC_PIN_PROVIDER _OSRC_PIN_AUTH extra <<EOF_PIN
$record
EOF_PIN
  case "$record" in *[[:space:]]*) return 1 ;; esac
  [ -n "$_OSRC_PIN_LANE" ] && [ -n "$_OSRC_PIN_MODEL" ] && [ -n "$_OSRC_PIN_DISP" ] && [ -n "$_OSRC_PIN_PROVIDER" ] && [ -z "$extra" ] || return 1
  # These are engine placeholders, not runnable model IDs. Pinning them would
  # silently change a provider-default launch into an invalid explicit model.
  case "$_OSRC_PIN_MODEL" in droid-default|cursor-default|hermes-default|warp-default|cline-default|pi-default|grokbot-default) echo "bg: provider default model cannot be pinned; specify -m explicitly." >&2; return 1 ;; esac
  case "$_OSRC_PIN_AUTH" in 0|1) ;; *) return 1 ;; esac
  _OSRC_PREFLIGHT_PAIR=""
  [ "$_OSRC_PIN_AUTH" = 1 ] && _OSRC_PREFLIGHT_PAIR="$_OSRC_PIN_LANE|$_OSRC_PIN_MODEL"
  return 0
}
