# Claude interactive launch shared by session start and winpty.
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
  if [ "${OSRC_LEAN_LAUNCH:-0}" = 1 ]; then
    if [ -n "${OSRC_LEAN_MCP_CONFIG:-}" ]; then
      [ -f "$OSRC_LEAN_MCP_CONFIG" ] && jq -e '.mcpServers | type == "object"' "$OSRC_LEAN_MCP_CONFIG" >/dev/null 2>&1 || die "lean launch: invalid MCP config"
      SESSION_LAUNCH+=(--strict-mcp-config --mcp-config "$OSRC_LEAN_MCP_CONFIG")
    else
      SESSION_LAUNCH+=(--strict-mcp-config --mcp-config '{"mcpServers":{}}')
    fi
  fi
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
