# lib/effort-guard.sh -- keep `/effort` out of Claude Code panes. Sourced by
# outsourcerer.sh through the lib/*.sh loader; defines functions only, no side
# effects at source time. bash 3.2 safe, set -u safe.
#
# `/effort` is a Claude Code GLOBAL command: it persists effortLevel into
# ~/.claude/settings.json, so a "per-session" effort typed into a pane silently
# re-defaults EVERY future claude session (the 2026-11-13 TR-orchestrator leak:
# the intent was `session effort high`, what reached the pane was `/effort high`,
# and every new session -- Fable included -- came up high until the user put it
# back by hand). `session effort` itself never types it: cc effort is applied
# per-session inside the relaunched process (MAX_THINKING_TOKENS env / the
# session-scoped --effort flag), which cannot touch settings. This guard closes
# the remaining door -- free-text sends -- for the same class: a LEADING /effort
# aimed at a claude pane is refused with the safe path named. Only a leading
# /effort is a command; the word inside prose is prompt text and passes.

_session_send_effort_guard() { # <tmux-pane> <message> -> 0 allow, 1 refuse
  local pane="$1" msg="$2" prov
  msg="$(printf '%s' "$msg" | sed -e 's/^[[:space:]]*//')"
  printf '%s' "$msg" | grep -qiE '^/effort([[:space:]=:]|$)' || return 0
  prov="$(_state_jsonl_read "$OSRC_SESSION_REGISTRY" 2>/dev/null | jq -r --arg id "$pane" 'select(.event=="start" and .session_id==$id) | .provider // empty' | tail -1)"
  [ -n "$prov" ] || prov="${PROVIDER:-}"
  case "$prov" in cc|claude) return 1 ;; esac
  # Records and flags did not prove a claude pane; the live footer is the remaining evidence.
  # A Claude Code footer ("<model> | <effort> | ... | ContextQ:") means /effort here WOULD
  # persist globally, so the guard refuses on footer proof too.
  [ "$(_session_model_observe_cc_builtin "$pane" 2>/dev/null)" != "unknown" ] && return 1
  return 0
}
