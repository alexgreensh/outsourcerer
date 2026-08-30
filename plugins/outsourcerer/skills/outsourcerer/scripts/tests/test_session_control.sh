#!/usr/bin/env bash
# Bug B — lifecycle control and conversation must be separate planes. `session control
# <interrupt|exit|relaunch>` owns the per-lane mechanics, sends ONLY lifecycle keys (never a prompt
# the delegate would read as chat), verifies each action took effect, and never tears down or
# discards work (no kill-session, no worktree mutation).
#
# Self-contained: sources the script with OSRC_SOURCED=1 and fakes `tmux` as a function that logs
# send-keys/respawn-pane calls, returns canned capture-pane content, and flips the pane PID on
# respawn-pane. The real _pane_state_classify runs on the canned capture so the verify loops exercise
# the real classifier.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "$PWD/.test-control.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"; mkdir -p "$OSRC_HOME"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
OSRC_SOURCED=1; export OSRC_SOURCED; set --; . "$SRC" >/dev/null 2>&1

export OSRC_CONTROL_VERIFY_POLLS=3
PANE="sess-ctrl"

# Shared stubs for the mutation lock (the control functions hold it around the keystroke).
_endpoint_mutation_lock() { return 0; }
_endpoint_mutation_unlock() { return 0; }
# Relaunch lifecycle mechanics are isolated here. The launch finalizer has its own coverage.
_heartbeat_start() { return 0; }
_managed_endpoint_live() { return 0; }

# ---- interrupt (cc/claude -> Escape; others -> C-c) --------------------------------------------
# Before: a busy pane ("esc to interrupt"). After the keystroke: an idle prompt. The verify loop
# must poll until the busy signal clears and report the resulting state.
CAPTURE_FILE="$TMP/busy"; printf 'Thinking...\n(esc to interrupt)\n' > "$CAPTURE_FILE"
INTERRUPTED=0
SEND_LOG="$TMP/int-log"; : > "$SEND_LOG"
tmux() {
  case "$1" in
    capture-pane) if [ "${INTERRUPTED:-0}" = 1 ]; then printf '❯\n'; else cat "$CAPTURE_FILE"; fi ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG"; INTERRUPTED=1 ;;
    *) return 0 ;;
  esac
}
out="$(_session_control_interrupt "$PANE" cc)"; rc=$?
if [ "$rc" = 0 ] && grep -q 'send-keys -t sess-ctrl Escape' "$SEND_LOG" \
   && printf '%s' "$out" | grep -q 'receipt: interrupt sent; the busy signal cleared'; then
  ok "interrupt (cc) sends Escape and verifies the busy signal cleared"
else
  bad "interrupt (cc) failed (rc=$rc): $out"
fi

# interrupt for a non-cc provider sends C-c, not Escape.
INTERRUPTED=0; : > "$SEND_LOG"
out="$(_session_control_interrupt "$PANE" devin)"; rc=$?
if [ "$rc" = 0 ] && grep -q 'send-keys -t sess-ctrl C-c' "$SEND_LOG" && ! grep -q 'send-keys -t sess-ctrl Escape' "$SEND_LOG"; then
  ok "interrupt (devin) sends C-c, not Escape"
else
  bad "interrupt (devin) sent the wrong key (rc=$rc)"
fi

# interrupt that does NOT clear the busy signal -> rc 1 (honest failure, never falsely verified).
INTERRUPTED=0; : > "$SEND_LOG"
tmux() {
  case "$1" in
    capture-pane) cat "$CAPTURE_FILE" ;;   # busy signal never clears
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG" ;;
    *) return 0 ;;
  esac
}
out="$(_session_control_interrupt "$PANE" cc 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'did NOT clear'; then
  ok "interrupt that never clears -> rc 1 with an honest 'did NOT clear' report"
else
  bad "interrupt falsely verified a still-busy pane (rc=$rc)"
fi

# ---- exit (cc/claude -> /exit + Enter; others -> C-d) ------------------------------------------
# Before: the TUI. After the quit keystroke: a shell prompt ($). The verify loop must poll until a
# shell prompt appears. Must NOT call kill-session.
CAPTURE_FILE="$TMP/tui"; printf 'Claude Code\n❯\n' > "$CAPTURE_FILE"
EXITED=0
SEND_LOG="$TMP/exit-log"; : > "$SEND_LOG"
KILL_CALLED=0
tmux() {
  case "$1" in
    capture-pane) if [ "${EXITED:-0}" = 1 ]; then printf 'user@host:repo$ \n'; else cat "$CAPTURE_FILE"; fi ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG"; case " $* " in *" Enter "*) EXITED=1 ;; esac ;;
    kill-session) KILL_CALLED=1 ;;
    display) printf '0\n' ;;
    *) return 0 ;;
  esac
}
out="$(_session_control_exit "$PANE" cc)"; rc=$?
if [ "$rc" = 0 ] && grep -q 'send-keys -t sess-ctrl -l -- /exit' "$SEND_LOG" && grep -q 'send-keys -t sess-ctrl Enter' "$SEND_LOG" \
   && [ "$KILL_CALLED" = 0 ] && printf '%s' "$out" | grep -q 'returned to a shell'; then
  ok "exit (cc) sends /exit + Enter, verifies a shell prompt, does NOT kill-session"
else
  bad "exit (cc) failed (rc=$rc, kill=$KILL_CALLED): $out"
fi

# exit for a non-cc provider sends C-d.
EXITED=0; : > "$SEND_LOG"; KILL_CALLED=0
tmux() {
  case "$1" in
    capture-pane) if [ "${EXITED:-0}" = 1 ]; then printf 'user@host:repo$ \n'; else printf 'devin\n❯\n'; fi ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG"; case " $* " in *" C-d "*) EXITED=1 ;; esac ;;
    kill-session) KILL_CALLED=1 ;;
    display) printf '0\n' ;;
    *) return 0 ;;
  esac
}
out="$(_session_control_exit "$PANE" devin)"; rc=$?
if [ "$rc" = 0 ] && grep -q 'send-keys -t sess-ctrl C-d' "$SEND_LOG" && [ "$KILL_CALLED" = 0 ]; then
  ok "exit (devin) sends C-d, does NOT kill-session"
else
  bad "exit (devin) failed (rc=$rc, kill=$KILL_CALLED)"
fi

# exit that never reaches a shell -> rc 1 (honest failure, no kill-session fallback).
EXITED=0; : > "$SEND_LOG"; KILL_CALLED=0
tmux() {
  case "$1" in
    capture-pane) cat "$CAPTURE_FILE" ;;   # TUI never exits
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG" ;;
    kill-session) KILL_CALLED=1 ;;
    display) printf '0\n' ;;
    *) return 0 ;;
  esac
}
out="$(_session_control_exit "$PANE" cc 2>&1)"; rc=$?
if [ "$rc" = 1 ] && [ "$KILL_CALLED" = 0 ] && printf '%s' "$out" | grep -q 'did NOT return to a shell'; then
  ok "exit that never reaches a shell -> rc 1, no kill-session fallback"
else
  bad "exit forced a kill or falsely verified (rc=$rc, kill=$KILL_CALLED)"
fi

# F4: a verified control exit is terminal lifecycle state, not only a pane receipt. It must end the
# registry entry so heartbeat active-work and fleet observations stop waking on the dead delegate.
(
  set --
  export OSRC_HOME="$TMP/control-exit-home" OSRC_HEARTBEAT_DISABLED=1 OSRC_SOURCED=1
  mkdir -p "$OSRC_HOME/sessions"
  . "$SRC" >/dev/null 2>&1
  SESSION_NAME=control-exit
  jq -cn '{schema_version:"1",event:"start",session_id:"control-exit",provider:"devin",model:"glm",requested_model:"glm",resolved_model:"glm",model_generation:1,effort:"high",state:"running",receipt:"receipt",endpoint:"tmux:control-exit",harness_pid:null,pid_start:null,owner:"managed",ts:"2026-01-01T00:00:00Z"}' > "$OSRC_SESSION_REGISTRY"
  EXITED=0
  tmux() {
    case "${1:-}" in
      capture-pane) if [ "$EXITED" = 1 ]; then printf 'user@host:repo$\n'; else printf 'devin\n❯\n'; fi ;;
      send-keys) case " $* " in *" C-d "*) EXITED=1 ;; esac ;;
      *) return 0 ;;
    esac
  }
  _endpoint_mutation_lock() { return 0; }
  _endpoint_mutation_unlock() { return 0; }
  _session_control_exit "$SESSION_NAME" devin >/dev/null 2>&1 || exit 1
  last="$(jq -rs 'last' "$OSRC_SESSION_REGISTRY")"
  [ "$(printf '%s' "$last" | jq -r '.event')" = end ] || exit 1
  [ "$(printf '%s' "$last" | jq -r '.receipt')" = control-exit ] || exit 1
  ! _heartbeat_interactive_work
) && ok "control exit appends end and stops heartbeat active-work wakes" \
  || bad "control exit returned without terminal registry state"

# ---- relaunch (respawn-pane changes #{pane_pid}; new start record appended) --------------------
# Fake tmux returns PID 11101 before respawn and 22202 after. respawn-pane flips the PID.
PID_NOW=11101
RESPAWNED=0
SEND_LOG="$TMP/rel-log"; : > "$SEND_LOG"
tmux() {
  case "$1" in
    has-session) return 0 ;;
    display-message) printf '%s\n' "$PID_NOW" ;;
    respawn-pane) printf 'RESPAWN: %s\n' "$*" >> "$SEND_LOG"; PID_NOW=22202; RESPAWNED=1 ;;
    *) return 0 ;;
  esac
}
# Stub the registry read (generation) and the append so the test does not depend on model resolution.
_state_jsonl_read() { printf '{"event":"start","session_id":"sess-ctrl","model_generation":1}\n'; }
_session_registry_append() { printf 'APPEND: %s\n' "$*" >> "$SEND_LOG"; return 0; }
out="$(_session_control_relaunch "$PANE" devin glm-4.6 high 2>&1)"; rc=$?
if [ "$rc" = 0 ] \
   && grep -q 'RESPAWN: respawn-pane -k -t sess-ctrl devin --model .glm-4.6. --respect-workspace-trust false' "$SEND_LOG" \
   && printf '%s' "$out" | grep -q 'New pane PID 22202 (was 11101)'; then
  ok "relaunch respawns the pane, verifies the PID changed, preserves the session"
else
  bad "relaunch failed (rc=$rc): $out"
fi

# relaunch must NOT kill-session (it respawns in place).
if ! grep -q 'kill-session' "$SEND_LOG"; then ok "relaunch does NOT call kill-session"; else bad "relaunch called kill-session"; fi

# relaunch for an unsupported provider refuses with a stop+start hint, no respawn.
: > "$SEND_LOG"
tmux() {
  case "$1" in
    has-session) return 0 ;;
    display-message) printf '11101\n' ;;
    respawn-pane) printf 'RESPAWN: %s\n' "$*" >> "$SEND_LOG" ;;
    *) return 0 ;;
  esac
}
out="$(_session_control_relaunch "$PANE" warp some-model '' 2>&1)"; rc=$?
if [ "$rc" = 1 ] && [ ! -s "$SEND_LOG" ] && printf '%s' "$out" | grep -qi 'not wired'; then
  ok "relaunch refuses an unsupported provider without respawning"
else
  bad "relaunch did not refuse an unsupported provider (rc=$rc): $out"
fi

# ---- static: control plane is strictly separate from send; lifecycle is keys, not chat ---------
grep -q 'session control <interrupt|exit|relaunch>' "$SRC" && ok "control subcommand in usage" || bad "control not in usage"
grep -q 'strictly separate from .session send.' "$SRC" && ok "control documented as separate from send" || bad "separation not documented"
# interrupt/exit send lifecycle KEYS (Escape/C-c/C-d) or a quit command, never a chat prompt typed
# through `session send`'s text path.
grep -q 'send-keys -t "$pane" Escape' "$SRC" && grep -q 'send-keys -t "$pane" C-c' "$SRC" && ok "interrupt uses lifecycle keys (Escape/C-c)" || bad "interrupt keys missing"
grep -q 'respawn-pane -k' "$SRC" && ok "relaunch uses respawn-pane (in-place, no teardown)" || bad "relaunch does not use respawn-pane"
# control must never print "sent" (that is the send plane's receipt word).
! grep -E 'control.*(echo|printf).*sent' "$SRC" >/dev/null 2>&1 && ok "control plane does not reuse the send 'sent' receipt" || bad "control reuses the send receipt word"

echo "----"
echo "session-control: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
