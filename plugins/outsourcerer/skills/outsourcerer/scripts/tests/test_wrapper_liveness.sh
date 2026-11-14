#!/usr/bin/env bash
# test_wrapper_liveness.sh — issues #47 and #48.
#
# #47: an auto-detached run puts outsourcerer.sh itself in the tmux pane. It is a bash script, so
# tmux reports the pane as "bash", the same name an idle prompt has. The launch check read that as
# "the engine exited", killed a healthy run, and reported a failed launch. A run that finished in a
# few seconds was reported the same way.
# #48: agent harnesses only wake when a background command exits, so `wait` must work on tmux runs,
# and a silent print-mode delegate that is still working must not be reaped as stalled.
#
# Uses a real tmux on a private socket when tmux is installed; the rest runs without it.
# Run: bash test_wrapper_liveness.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"
WDLIB="$(dirname "$SRC")/lib/watchdog.sh"   # _supervise and friends live in lib/ (size rule)
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TMP="$(mktemp -d /tmp/osrc-wl.XXXXXX)" || { echo "FAIL: mktemp"; exit 1; }
export TMUX_TMPDIR="$TMP/t"; mkdir -p "$TMUX_TMPDIR"
[ -d "$TMUX_TMPDIR" ] || { echo "FAIL: tmux sandbox missing"; exit 1; }
unset TMUX TMUX_PANE
# Every tmux call — this test's and the sourced engine's — goes through a PATH shim onto a
# private named socket inside the sandbox dir, so no call can reach the real tmux server.
_wl_tmux="$(command -v tmux 2>/dev/null || true)"
if [ -n "$_wl_tmux" ]; then
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\nexec "%s" -L osrc-test-%s "$@"\n' "$_wl_tmux" "$$" > "$TMP/bin/tmux"
  chmod +x "$TMP/bin/tmux"
  PATH="$TMP/bin:$PATH"; export PATH
fi
trap "env -u TMUX -u TMUX_PANE tmux -L osrc-test-$$ kill-server >/dev/null 2>&1; rm -rf \"\$TMP\"" EXIT
export OSRC_HOME="$TMP/home"; export OSRC_SOURCED=1; mkdir -p "$OSRC_HOME"
# shellcheck disable=SC1090
source "$SRC" >/dev/null 2>&1

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

echo "=== the wrapper is told apart from a shell ==="
_session_command_is_osrc_wrapper "/bin/bash /x/y/outsourcerer.sh --provider cursor run hi" \
  && ok "bash running outsourcerer.sh is the wrapper" || no "wrapper not recognised"
_session_command_is_osrc_wrapper "bash outsourcerer.sh run hi" \
  && ok "relative outsourcerer.sh is the wrapper" || no "relative wrapper not recognised"
_session_command_is_osrc_wrapper "-bash" && no "a login shell was taken for the wrapper" || ok "a login shell is not the wrapper"
_session_command_is_osrc_wrapper "bash /x/not-outsourcerer.sh.bak" && no "a lookalike name matched" || ok "a lookalike name does not match"

echo "=== a finished run's screen comes back clean ==="
LOG="$TMP/pane.log"
printf 'Last login: x\r\nprompt$ export PATH=x; clear; OSRC_NO_AUTODETACH=1 outsourcerer.sh run hi; printf %%s\\n "$?" > rc\r\n\033[H\033[2J\033[1m>>> [route] RESOLVED lane=cursor\033[0m\r\nCURSOR_OK\r\nprompt$ ' > "$LOG"
out="$(_autodetach_finished_output "$LOG")"
case "$out" in *CURSOR_OK*) ok "the answer is kept" ;; *) no "the answer was lost: [$out]" ;; esac
case "$out" in *"export PATH"*|*"Last login"*) no "the typed command line leaked: [$out]" ;; *) ok "the typed command line is dropped" ;; esac
case "$out" in *'prompt$'*) no "the trailing prompt leaked: [$out]" ;; *) ok "the trailing prompt is dropped" ;; esac
case "$out" in *$'\033'*|*$'\r'*) no "control codes leaked" ;; *) ok "control codes are stripped" ;; esac

echo "=== wait on a tmux run returns its output and exit code ==="
mkdir -p "$OSRC_HOME/autodetach"
cp "$LOG" "$OSRC_HOME/autodetach/osrc-ad-test-ok.log"; echo 0 > "$OSRC_HOME/autodetach/osrc-ad-test-ok.rc"
out="$(OSRC_POLL=1 _wait_session osrc-ad-test-ok 0 0 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && ok "a finished run waits to exit 0" || no "finished run gave rc=$rc"
case "$out" in *CURSOR_OK*) ok "wait prints the run's answer" ;; *) no "wait output: [$out]" ;; esac
cp "$LOG" "$OSRC_HOME/autodetach/osrc-ad-test-bad.log"; echo 2 > "$OSRC_HOME/autodetach/osrc-ad-test-bad.rc"
( OSRC_POLL=1 _wait_session osrc-ad-test-bad 0 0 >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 1 ] && ok "a failed run waits to exit 1" || no "failed run gave rc=$rc"
cp "$LOG" "$OSRC_HOME/autodetach/osrc-ad-test-gone.log"
( OSRC_POLL=1 _wait_session osrc-ad-test-gone 0 0 >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 1 ] && ok "a run whose window vanished without an exit code is a failure, not a hang" || no "vanished run gave rc=$rc"
( _wait_session no-such-run 0 0 >/dev/null 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && ok "an unknown id is refused" || no "an unknown id was accepted"
( cmd_wait osrc-ad-test-ok >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && ok "cmd_wait routes a session id to the session waiter" || no "cmd_wait session route rc=$rc"

echo "=== CPU time of a process tree ==="
c="$(_tree_cpu_centis $$)"
case "$c" in ''|*[!0-9]*) no "cpu centis not a number: [$c]" ;; *) ok "cpu centis is a number ($c)" ;; esac
_tree_cpu_centis notapid >/dev/null 2>&1 && no "a non-pid was accepted" || ok "a non-pid is refused"
grep -q 'OSRC_CPU_LIVENESS' "$SRC" "$WDLIB" && grep -q '_tree_cpu_centis "$pid"' "$SRC" "$WDLIB" \
  && ok "the stall watchdog consults CPU time before reaping a silent delegate" \
  || no "the watchdog has no CPU liveness probe"

echo "=== launch messages tell an agent how to be woken ==="
grep -q '_wake_on_finish_hint "$_ad_sess"' "$SRC" && ok "an auto-detached run prints the WAKE line" || no "auto-detach has no WAKE line"
[ "$(grep -c '_wake_on_finish_hint "$id"' "$SRC")" -ge 3 ] && ok "every bg launch path prints the WAKE line" || no "a bg launch path lacks the WAKE line"

if tmux -L osrc-test-T5 -V >/dev/null 2>&1; then
  echo "=== real tmux: a running wrapper counts as a live launch ==="
  mkdir -p "$TMP/w"
  printf '#!/usr/bin/env bash\nsleep 8\n' > "$TMP/w/outsourcerer.sh"; chmod +x "$TMP/w/outsourcerer.sh"
  tmux new-session -d -s wl-live -x 100 -y 20 "bash --norc --noprofile" 2>/dev/null
  tmux send-keys -t wl-live "$TMP/w/outsourcerer.sh" Enter
  OSRC_SESSION_LIVENESS_SECS=3 _session_launch_liveness_check wl-live cursor "outsourcerer.sh" 2>/dev/null \
    && ok "a pane running outsourcerer.sh passes the launch check" || no "a running wrapper was called a dead launch (#47)"
  pp="$(tmux display-message -p -t wl-live '#{pane_pid}' 2>/dev/null)"
  [ -n "$(_session_engine_pid wl-live "$pp")" ] && ok "the wrapper is recorded as the engine (heartbeat sees it alive)" \
    || no "no engine pid for a running wrapper"
  tmux kill-session -t wl-live 2>/dev/null
  tmux new-session -d -s wl-idle -x 100 -y 20 "bash --norc --noprofile" 2>/dev/null
  OSRC_SESSION_LIVENESS_SECS=2 _session_launch_liveness_check wl-idle droid "droid -r high" 2>/dev/null \
    && no "an idle prompt passed the launch check" || ok "an idle prompt still fails the launch check (droid -r guard kept)"
  tmux kill-session -t wl-idle 2>/dev/null
else
  echo "SKIP: a usable tmux is unavailable; real-pane checks skipped"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
