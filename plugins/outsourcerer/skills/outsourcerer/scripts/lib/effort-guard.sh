# lib/effort-guard.sh -- keep `/effort` out of Claude Code panes and keep effort
# changes session-scoped. Sourced by outsourcerer.sh through the lib/*.sh
# loader; defines functions only, no side effects at source time. bash 3.2 safe,
# set -u safe.
#
# `/effort` is a Claude Code GLOBAL command: it persists effortLevel into
# ~/.claude/settings.json, so a "per-session" effort typed into a pane silently
# re-defaults EVERY future claude session (the 2026-11-13 TR-orchestrator leak:
# the intent was `session effort high`, what reached the pane was `/effort high`,
# and every new session -- Fable included -- came up high until the user put it
# back by hand). `session effort` itself never types it: cc effort is applied
# per-session inside the relaunched process (MAX_THINKING_TOKENS env plus the
# session-scoped `claude --effort` flag, and `--continue` so the conversation
# survives the respawn), which cannot touch settings. This guard closes the
# remaining door -- free-text sends -- for the same class: a LEADING /effort
# aimed at a pane that cannot be proven NOT to be claude is refused with the
# safe path named. Only a leading /effort is a command; the word inside prose
# is prompt text and passes.
#
# Guard order: explicit override env -> registry/flag provider -> the pane's
# live foreground command -> the claude footer -> the pane's process tree ->
# identified-non-claude allow -> fail closed. OSRC_SEND_ALLOW_EFFORT=1 is the
# operator override for a pane proven not to be Claude Code.

_session_send_effort_guard() { # <tmux-pane> <message> -> 0 allow, 1 refuse
  local pane="$1" msg="$2" prov cmd
  msg="$(printf '%s' "$msg" | sed -e 's/^[[:space:]]*//')"
  printf '%s' "$msg" | grep -qiE '^/effort([[:space:]=:]|$)' || return 0
  [ "${OSRC_SEND_ALLOW_EFFORT:-0}" = "1" ] && return 0
  prov="$(_state_jsonl_read "$OSRC_SESSION_REGISTRY" 2>/dev/null | jq -r --arg id "$pane" 'select(.event=="start" and .session_id==$id) | .provider // empty' | tail -1)"
  [ -n "$prov" ] || prov="${PROVIDER:-}"
  case "$prov" in cc|claude) return 1 ;; esac
  # Records and flags are stale-able; what runs in the pane NOW decides. A
  # stock Claude Code screen has no ContextQ footer, so the process name is
  # the remaining proof for unmanaged/adopted panes.
  cmd="$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)"
  case "$cmd" in *[Cc]laude*) return 1 ;; esac
  # A Claude Code footer ("<model> | <effort> | ... | ContextQ:") means /effort
  # here WOULD persist globally, so footer proof refuses even over a codex record.
  [ "$(_session_model_observe_cc_builtin "$pane" 2>/dev/null)" != "unknown" ] && return 1
  # A wrapper foreground (bash/node/ssh) can still have claude underneath it.
  _session_pane_tree_has_claude "$pane" && return 1
  # Identified as something else: the keystrokes cannot reach a claude /effort.
  [ -n "$cmd" ] && return 0
  # Cannot identify the pane at all: fail closed rather than guess.
  return 1
}

# _session_pane_tree_has_claude <tmux-pane> -> 0 when any process in the pane's
# tree looks like claude (comm args match). Walks children of pane_pid; the
# depth cap keeps a pathological pid graph from looping forever.
_session_pane_tree_has_claude() {
  local pane="$1" root frontier next p c args i=0
  root="$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)"
  case "$root" in ''|*[!0-9]*) return 1 ;; esac
  frontier="$root"
  while [ -n "$frontier" ] && [ "$i" -lt 50 ]; do
    i=$((i + 1)); next=""
    for p in $frontier; do
      args="$(ps -o args= -p "$p" 2>/dev/null)"
      printf '%s\n' "$args" | grep -qiE '(^|[[:space:]/])claude([[:space:]]|$)' && return 0
      for c in $(pgrep -P "$p" 2>/dev/null); do
        case " $next " in *" $c "*) ;; *) next="$next $c" ;; esac
      done
    done
    frontier="$next"
  done
  return 1
}

# _cc_effort_flag <effort> -> the value for claude's session-scoped --effort
# flag (low|medium|high|xhigh|max). The flag has no minimal/none level; those
# map to low and still carry the MAX_THINKING_TOKENS=0 env cap.
_cc_effort_flag() {
  case "$1" in
    minimal|none) printf 'low' ;;
    low|medium|high|xhigh|max) printf '%s' "$1" ;;
    *) printf '' ;;
  esac
}

# _session_cc_effort_supported -> 0 when the installed claude advertises
# --effort in its help. The env cap applies either way; the flag is added only
# where verified so an older claude cannot fail to spawn on an unknown arg.
_session_cc_effort_supported() {
  local help_text
  help_text="$(_session_probe_help claude --help 2>/dev/null)" || return 1
  grep -q -- '--effort' <<<"$help_text"
}
