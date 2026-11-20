#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_session_exit_liveness.sh — an engine that exits 0 to a bare shell is NOT a started session.
#
# The droid -r/resume bug: `droid --auto medium -r high` tried to RESUME a session named "high"
# (top-level `-r, --resume [sessionId]`, NOT reasoning-effort), found none, and EXITED SILENTLY
# TO A BARE SHELL with exit code 0 and no error. `session start` reported "Started" while the pane
# was a dead shell — an invisible non-start. _session_launch_liveness_check polls the pane's
# foreground command after send-keys and refuses if it is still the login shell after the budget,
# because an engine that exits 0 immediately is not a started session.
#
# This test exercises _session_launch_liveness_check with a FAKE tmux that controls
# #{pane_current_command} so the behavior is deterministic and does not need a real tmux server:
#   - pane stays a bare shell (bash)  -> check RETURNS 1 (refuses: invisible non-start detected)
#   - pane becomes an engine (droid)  -> check RETURNS 0 (healthy start)
#   - pane becomes zsh then droid     -> check RETURNS 0 (engine took over after a tick)
#   - OSRC_SESSION_LIVENESS_SECS=0    -> check RETURNS 0 (opt-out honored)
# It also re-asserts the droid launch never contains -r (the leak that caused the silent exits).
# Run: bash test_session_exit_liveness.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TMP="$(mktemp -d "${TMPDIR%/}/osrc-liveness.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home"; export OSRC_SOURCED=1; mkdir -p "$OSRC_HOME"
BIN="$TMP/bin"; mkdir -p "$BIN"

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

# --- fake tmux: has-session always succeeds; display-message -p answers #{pane_current_command}
#     from a file (changeable mid-poll to simulate the engine taking over) and #{pane_pid} from a
#     second file (the slow-boot tests point it at a REAL pid whose children are the boot-evidence
#     the grace window keys on); kill-session is a no-op. ---
TMUX_CMD_FILE="$TMP/pane_cmd"
TMUX_PID_FILE="$TMP/pane_pid"
echo "bash" > "$TMUX_CMD_FILE"
echo "999999" > "$TMUX_PID_FILE"
cat > "$BIN/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  has-session) exit 0 ;;
  kill-session) exit 0 ;;
  display-message)
    # The format string is the last argument.
    case "\${!#}" in
      *pane_pid*)             cat "$TMUX_PID_FILE" 2>/dev/null || echo 999999 ;;
      *pane_current_command*) cat "$TMUX_CMD_FILE" 2>/dev/null || echo bash ;;
      *)                      cat "$TMUX_CMD_FILE" 2>/dev/null || echo bash ;;
    esac
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/tmux"

# Fake droid: the adapter probes `droid --help` before assembling the launch, and CI runners have
# no droid binary — without a stub, check 6 dies inside _session_launch_error (which `die`s, i.e.
# EXITs the sourced test shell) before the -r assertion can even run. The help text advertises
# exactly the three capabilities the adapter gates on (interactive-by-default, exec as the
# non-interactive path, bounded --auto levels).
cat > "$BIN/droid" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  cat <<'HELP'
Usage: droid [options] [prompt...]
Starts interactive mode by default when no subcommand is given.
  exec <prompt>   Run a single non-interactive prompt for scripts/automation
  --auto <level>  Bounded interactive autonomy: low, medium, high
HELP
  exit 0
fi
exit 0
EOF
chmod +x "$BIN/droid"
export PATH="$BIN:$PATH"

. "$SRC" >/dev/null 2>&1
type -t _session_launch_liveness_check >/dev/null || { echo "FAIL: _session_launch_liveness_check not loaded"; exit 1; }

# --- 1. bare shell (bash) for the whole budget -> REFUSES (returns 1). This is the droid -r
#        silent-exit shape: the engine exited 0 and the pane dropped back to the shell. ---
echo "bash" > "$TMUX_CMD_FILE"
export OSRC_SESSION_LIVENESS_SECS=2
if ( _session_launch_liveness_check osrc-test droid "droid --auto medium -r high" ) >/dev/null 2>&1; then
  no "bare shell (bash): liveness check WRONGLY passed (the bug: a dead pane reported as started)"
else
  ok "bare shell (bash): liveness check REFUSED an engine that exited to a bare shell (rc!=0)"
fi

# --- 2. engine takes over immediately (droid) -> PASSES (returns 0). Healthy start. ---
echo "droid" > "$TMUX_CMD_FILE"
export OSRC_SESSION_LIVENESS_SECS=2
if ( _session_launch_liveness_check osrc-test droid "droid --auto medium" ) >/dev/null 2>&1; then
  ok "engine (droid): liveness check passed — non-shell foreground command detected"
else
  no "engine (droid): liveness check WRONGLY refused a live engine"
fi

# --- 3. shell for one tick, then engine -> PASSES. Simulates the engine booting after send-keys. ---
export OSRC_SESSION_LIVENESS_SECS=4
( echo "bash" > "$TMUX_CMD_FILE"; sleep 1.5; echo "droid" > "$TMUX_CMD_FILE" ) &
_bg=$!
if ( _session_launch_liveness_check osrc-test droid "droid --auto medium" ) >/dev/null 2>&1; then
  ok "shell-then-engine: liveness check passed once the engine took over the pane"
else
  no "shell-then-engine: liveness check did not recognize the engine taking over"
fi
wait $_bg 2>/dev/null || true

# --- 4. zsh (a different shell) for the whole budget -> REFUSES. The check must recognize ANY
#        login shell, not just bash. ---
echo "zsh" > "$TMUX_CMD_FILE"
export OSRC_SESSION_LIVENESS_SECS=2
if ( _session_launch_liveness_check osrc-test droid "droid --auto medium" ) >/dev/null 2>&1; then
  no "bare shell (zsh): liveness check WRONGLY passed for a zsh bare shell"
else
  ok "bare shell (zsh): liveness check REFUSED a zsh bare shell (any login shell recognized)"
fi

# --- 5. opt-out (OSRC_SESSION_LIVENESS_SECS=0) -> PASSES immediately, even on a bare shell. ---
echo "bash" > "$TMUX_CMD_FILE"
export OSRC_SESSION_LIVENESS_SECS=0
if ( _session_launch_liveness_check osrc-test droid "droid --auto medium" ) >/dev/null 2>&1; then
  ok "opt-out (SECS=0): liveness check skipped on a bare shell as configured"
else
  no "opt-out (SECS=0): liveness check did not honor the opt-out"
fi
unset OSRC_SESSION_LIVENESS_SECS

# --- 6. SLOW BOOT tolerated (agy/devin take 10-20s): the pane stays a shell name past the fast
#        window while the pane shell still has a live descendant (the typed launch chain — an
#        export/clear prefix, a shim resolving node, an auth preflight — is still running).
#        The grace window must keep waiting on the SAME pane and pass when the engine takes
#        over. The descendant must be a GRANDCHILD behind a shell child — a non-shell direct
#        child already counts as the engine via _session_engine_pid, so the real miss shape is
#        pane-shell -> bash wrapper -> engine. Nested bash models exactly that: the inner bash
#        is skipped as a shell, the sleep behind it is the boot evidence. ---
bash -c 'bash -c "sleep 60; true" & wait' & _WRAP_PID=$!
echo "$_WRAP_PID" > "$TMUX_PID_FILE"
echo "bash" > "$TMUX_CMD_FILE"
export OSRC_SESSION_LIVENESS_SECS=2 OSRC_SESSION_LIVENESS_GRACE_SECS=15
( sleep 4; echo "agy" > "$TMUX_CMD_FILE" ) &
_bg=$!
if ( _session_launch_liveness_check osrc-test gemini "agy --mode auto" ) >/dev/null 2>&1; then
  ok "slow boot: grace waited past the fast window for a live-descendant pane, passed on engine take-over"
else
  no "slow boot: check refused a pane still booting with a live descendant (the reported 'did not become live' bug)"
fi
wait $_bg 2>/dev/null || true

# --- 7. DEAD launch exits the grace window EARLY: bare shell + pane shell has NO descendants
#        means the typed chain exited — refuse at the first grace poll, not after the full
#        budget. pane_pid points at a childless `sleep` (a real pid with no descendants). ---
sleep 60 & _CHILDLESS=$!
echo "$_CHILDLESS" > "$TMUX_PID_FILE"
echo "bash" > "$TMUX_CMD_FILE"
export OSRC_SESSION_LIVENESS_SECS=2 OSRC_SESSION_LIVENESS_GRACE_SECS=15
_t0=$SECONDS
if ( _session_launch_liveness_check osrc-test droid "droid --auto medium" ) >/dev/null 2>&1; then
  no "dead launch: check WRONGLY passed a bare shell with no live descendant"
else
  [ $((SECONDS - _t0)) -le 5 ] \
    && ok "dead launch: refused early in the grace window (~$((SECONDS - _t0))s, not the full budget)" \
    || no "dead launch: refused but waited $((SECONDS - _t0))s — the descendant probe did not short-circuit"
fi

# --- 8. grace opt-out: OSRC_SESSION_LIVENESS_GRACE_SECS=0 restores the old contract — a slow
#        booting pane (descendant alive) still refuses at the fast budget. ---
echo "$_WRAP_PID" > "$TMUX_PID_FILE"
echo "bash" > "$TMUX_CMD_FILE"
export OSRC_SESSION_LIVENESS_SECS=2 OSRC_SESSION_LIVENESS_GRACE_SECS=0
_t0=$SECONDS
if ( _session_launch_liveness_check osrc-test gemini "agy --mode auto" ) >/dev/null 2>&1; then
  no "grace opt-out: check WRONGLY passed a still-booting shell pane"
else
  [ $((SECONDS - _t0)) -le 4 ] \
    && ok "grace opt-out (GRACE=0): refused at the fast budget (~$((SECONDS - _t0))s)" \
    || no "grace opt-out: refused but waited $((SECONDS - _t0))s beyond the fast budget"
fi

# --- 9. bounded: a pane that stays a shell WITH a live descendant for the whole grace still
#        refuses at the deadline — the retry window is bounded, never an open-ended wait. ---
echo "$_WRAP_PID" > "$TMUX_PID_FILE"
echo "bash" > "$TMUX_CMD_FILE"
export OSRC_SESSION_LIVENESS_SECS=1 OSRC_SESSION_LIVENESS_GRACE_SECS=2
_t0=$SECONDS
if ( _session_launch_liveness_check osrc-test gemini "agy --mode auto" ) >/dev/null 2>&1; then
  no "bounded grace: check WRONGLY passed a pane that never became an engine"
else
  _el=$((SECONDS - _t0))
  [ "$_el" -ge 3 ] && [ "$_el" -le 6 ] \
    && ok "bounded grace: refused at the deadline (~${_el}s = 1s fast + 2s grace)" \
    || no "bounded grace: refused after ${_el}s — expected ~3s, the window is not bounded"
fi
unset OSRC_SESSION_LIVENESS_SECS OSRC_SESSION_LIVENESS_GRACE_SECS
kill "$_WRAP_PID" "$_CHILDLESS" 2>/dev/null || true
echo "999999" > "$TMUX_PID_FILE"; echo "bash" > "$TMUX_CMD_FILE"

# --- 10. the droid launch built by _session_launch_adapter must NEVER contain -r (the leak that
#        caused the silent exits). Re-assert here so this test owns the liveness contract end-to-end. ---
PROVIDER=droid; MODEL_EXPLICIT=0; MODEL=""; EFFORT=""
SESSION_LAUNCH=()
if _session_launch_adapter droid 2>/dev/null; then
  _joined="${SESSION_LAUNCH[*]:-}"
  case "$_joined" in
    *" -r "*|*" --resume"*) no "droid launch LEAKED -r/--resume (the silent-exit cause): '$_joined'" ;;
    *) ok "droid launch has no -r/--resume (the silent-exit leak is closed)" ;;
  esac
else
  no "droid adapter errored unexpectedly during the no-flag launch: $(cat "$TMP/err6" 2>/dev/null)"
fi

# --- 7. source-level: session start invokes the shared finalizer after send-keys, and the finalizer
#        itself checks liveness before writing the registry start event. ---
_block="$(awk '/tmux send-keys -t "\$SESSION_NAME" "export PATH/{f=1} f{print} /_session_launch_finalize "\$SESSION_NAME"/{if(f)exit}' "$SRC")"
_finalizer="$(awk '/^_session_launch_finalize\(\)/,/^}/' "$SRC")"
_live_line="$(printf '%s\n' "$_finalizer" | grep -n '_session_launch_liveness_check' | head -1 | cut -d: -f1)"
_registry_line="$(printf '%s\n' "$_finalizer" | grep -n '_session_registry_append start' | head -1 | cut -d: -f1)"
if grep -q '_session_launch_finalize' <<<"$_block" \
   && grep -q 'tmux send-keys' <<<"$_block" \
   && grep -q '_session_registry_append start' <<<"$_finalizer" \
   && [ -n "$_live_line" ] && [ -n "$_registry_line" ] && [ "$_live_line" -lt "$_registry_line" ]; then
  ok "shared finalizer is wired into session start and checks liveness before registry append"
else
  no "shared finalizer does not enforce liveness before the registry append"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
