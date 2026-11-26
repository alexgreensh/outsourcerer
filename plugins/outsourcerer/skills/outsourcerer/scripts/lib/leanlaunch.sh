# Claude interactive launch shared by session start and winpty.
#
# Lean by default (lane osrc-l5): a local lane loads ONLY the MCP servers the brief or task
# declares (--with mcp=a,b, or OSRC_LEAN_MCP_CONFIG=<file>), else none. Each full MCP set cost about
# 17 helper processes and 0.85 GB per lane. OSRC_SESSION_MCP=full opts back in to the user's whole
# set. The engine's own flags do the work: --strict-mcp-config --mcp-config <json|file>.
_session_launch_cc() {
  have claude || die "claude not on PATH (needed for a claude session)"
  [ "$MODEL_EXPLICIT" = "1" ] && _session_assert_model_pinnable cc claude --help
  SESSION_LAUNCH=("env" "-u" "CLAUDECODE" "-u" "CLAUDE_CODE_ENTRYPOINT" "-u" "CLAUDE_CODE_SESSION_ID" "-u" "CLAUDE_CODE_CHILD_SESSION" "-u" "CLAUDE_CODE_EXECPATH")
  [ -n "${OSRC_ACCOUNT_DIR:-}" ] && SESSION_LAUNCH+=("CLAUDE_CONFIG_DIR=$OSRC_ACCOUNT_DIR")
  [ -n "$EFFORT" ] && SESSION_LAUNCH+=("MAX_THINKING_TOKENS=$(_effort_thinking_tokens "$EFFORT")")
  SESSION_LAUNCH+=("claude")
  [ "$MODEL_EXPLICIT" = "1" ] && SESSION_LAUNCH+=("--model" "$MODEL")
  local _ccflag; _ccflag="$(_cc_effort_flag "${EFFORT:-}")"
  if [ -n "$_ccflag" ] && _session_cc_effort_supported; then SESSION_LAUNCH+=("--effort" "$_ccflag"); fi
  _session_cc_mcp_flags
}

# _session_mcp_mode -> lean|full, the mode this shell's environment asks for (as _session_cc_mcp_flags
# reads it). Session start records it; relaunch restores the recorded one (_session_mcp_restore).
_session_mcp_mode() {
  if [ "${OSRC_LEAN_LAUNCH:-0}" = 1 ]; then printf lean
  elif [ "${OSRC_CLAUDE_USER_CONFIG:-0}" = 1 ] || [ "${OSRC_SESSION_MCP:-lean}" = full ]; then printf full
  else printf lean; fi
}
# _session_mcp_restore <session-id>: the MCP mode the session started with wins over the relaunching
# shell's environment (registry start record, field 6). Records without it keep the environment's.
_session_mcp_restore() {
  case "$(_session_record "$1" 2>/dev/null | cut -f6)" in
    full) OSRC_SESSION_MCP=full; OSRC_LEAN_LAUNCH=0 ;;
    lean) OSRC_SESSION_MCP=lean; OSRC_CLAUDE_USER_CONFIG=0 ;;
  esac
}

# _session_mcp_copy -> the private per-session copy of the declared MCP config. It can hold server env
# tokens, so _session_registry_end (every stop, exit and failed launch) removes it.
_session_mcp_copy() { printf '%s/sessions/mcp-%s.json' "$OSRC_HOME" "${SESSION_NAME:-$$}"; }

# _session_cc_mcp_flags -> append the MCP isolation flags for an interactive Claude lane.
# OSRC_CLAUDE_USER_CONFIG=1 (the headless lanes' escape hatch) means OSRC_SESSION_MCP=full here too.
# OSRC_LEAN_LAUNCH=1 always means lean, even when OSRC_SESSION_MCP=full is set elsewhere.
_session_cc_mcp_flags() {
  local mode="${OSRC_SESSION_MCP:-lean}"
  [ "${OSRC_CLAUDE_USER_CONFIG:-0}" != 1 ] || mode=full
  case "$mode" in
    full) [ "${OSRC_LEAN_LAUNCH:-0}" = 1 ] || return 0
      [ "${OSRC_CLAUDE_USER_CONFIG:-0}" != 1 ] || die "lean launch requires strict MCP isolation; unset OSRC_CLAUDE_USER_CONFIG or OSRC_LEAN_LAUNCH" ;;
    lean|'') ;;
    *) die "OSRC_SESSION_MCP must be lean or full (got '${OSRC_SESSION_MCP}')" ;;
  esac
  if [ -n "${OSRC_LEAN_MCP_CONFIG:-}" ]; then
    [ -f "$OSRC_LEAN_MCP_CONFIG" ] && jq -e '.mcpServers | type == "object"' "$OSRC_LEAN_MCP_CONFIG" >/dev/null 2>&1 || die "lean launch: invalid MCP config"
    SESSION_LAUNCH+=(--strict-mcp-config --mcp-config "$OSRC_LEAN_MCP_CONFIG")
    return 0
  fi
  # Declared servers (--with mcp=a,b): reuse the headless lanes' filter, then keep a private copy that
  # outlives this process (the pane starts claude after session start exits and removes its temp file).
  if type _with_mcp_requested >/dev/null 2>&1 && _with_mcp_requested; then
    local cfg; cfg="$(_session_mcp_copy)"
    build_mcp_flags_cc && [ -f "${CC_MCP_FLAGS[2]:-}" ] || die "lean launch: could not build the declared MCP config"
    _mkdir_private "$OSRC_HOME/sessions" 2>/dev/null || mkdir -p "$OSRC_HOME/sessions" || die "lean launch: cannot write $OSRC_HOME/sessions"
    ( umask 077; cp "${CC_MCP_FLAGS[2]}" "$cfg" ) || die "lean launch: cannot write $cfg"
    SESSION_LAUNCH+=(--strict-mcp-config --mcp-config "$cfg")
    return 0
  fi
  SESSION_LAUNCH+=(--strict-mcp-config --mcp-config '{"mcpServers":{}}')
}

# A new pane may still have canonical terminal input enabled when send-keys arrives.
# Carry the long Claude safe command in the pane environment and type only its invocation.
_session_create_pane() {
  local args=(new-session -d -s "$SESSION_NAME" -x 200 -y 50 -c "$PWD")
  case "$PROVIDER:${PERM_PROFILE:-default}" in
    cc:safe|claude:safe)
      args+=(-e "OSRC_PANE_LAUNCH=$launch")
      pane_command='bash -c "$OSRC_PANE_LAUNCH"' ;;
  esac
  tmux "${args[@]}"
}
