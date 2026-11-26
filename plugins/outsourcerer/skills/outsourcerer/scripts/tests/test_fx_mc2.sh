#!/usr/bin/env bash
# sealed-run-requires: process-inspection
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_fx_mc2.sh: the 0.18.0 release-gate fixes for Mission Control, the watcher and speed (lane
# osrc-fx-mc2). One section per review finding; every check failed before its fix.
# Run: bash test_fx_mc2.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"; FX="$SCRIPT_DIR/fixtures/supervise"
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-fxmc2.XXXXXX")" || exit 1; PIDS=""
trap 'for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/panes" "$TMP/home"
ln -s "$SCRIPT_DIR/fake-bin/tmux-files-next" "$TMP/bin/tmux"; export FAKE_TMUX_FILES="$SCRIPT_DIR/fake-bin/tmux-files"
export HOME="$TMP/home" PATH="$TMP/bin:$PATH" FAKE_TMUX_DIR="$TMP/panes" OSRC_HEARTBEAT_DISABLED=1 OSRC_BLIND_TURN_GUARD=0 OSRC_STREAM=1
export OSRC_CLAUDE_PROJECTS_DIR="$TMP/projects" OSRC_CLAUDE_SESSIONS_DIR="$TMP/ccsessions" OSRC_MC_AUTO_OPEN=0 OSRC_WATCH_NOTIFY=0
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID OSRC_WATCH_DELIVER_CMD OSRC_SUPERVISE_REMIND
export OSRC_SUPERVISE_POLL=1 OSRC_SUPERVISE_CONFIRM=0 OSRC_SUPERVISE_SETTLE=0 OSRC_SUPERVISE_TICK_SECS=86400
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
fresh() { export OSRC_HOME="$TMP/h$1"; mkdir -p "$OSRC_HOME/jobs" "$OSRC_HOME/sessions" "$OSRC_HOME/lanes"; rm -f "$TMP/panes"/*.screen; }
own() { mkdir -p "$OSRC_HOME/owners/$1"; : > "$OSRC_HOME/owners/$1/$2"; }
pane() { cp "$FX/$2" "$TMP/panes/$1.screen"; }
lib() { ( set +u; OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; "$@" ); }
S() { ( set +u; export OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; eval "$1" ); }
ago() { local t; t="$(date -r $(( $(date +%s) - $2 )) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$(( $(date +%s) - $2 )) +%Y%m%d%H%M.%S)"; touch -t "$t" "$1"; }
# A standing watcher that can wake every session: a live "watcher run" process holding the lock, a
# fresh tick, and a delivery command captured at install.
fake_watcher() {
  bash -c 'sleep 120; : watcher run' & local p=$!; PIDS="$PIDS $p"; sleep 0.2
  mkdir -p "$OSRC_HOME/watchsvc/run.lock"; echo "$p" > "$OSRC_HOME/watchsvc/run.lock/pid"
  date +%s > "$OSRC_HOME/watchsvc/alive"; echo fallback > "$OSRC_HOME/watchsvc/installed"
  printf 'export OSRC_WATCH_DELIVER_CMD=true\n' > "$OSRC_HOME/watchsvc/env"
}
N0="$(date +%s)"

echo "=== pattern F2: one 'is this session watched' rule ==="
fresh 1; own S w1; pane w1 cc-working-turn.txt; ago "$OSRC_HOME/owners/S/w1" 300
g="$(lib osrc_watcher_gap S)"; [ -n "$g" ] && ok "no watcher at all: the gap shows ($g)" || no "no gap without any watcher"
fake_watcher
lib _ws_covers S && ok "the fake standing watcher covers the session (stop guard's view)" || no "fake watcher does not cover"
g="$(lib osrc_watcher_gap S)" && no "watcher covers S but the gap still says '$g'" || ok "osrc_watcher_gap honors the standing watcher"
p="$(lib osrc_mc_alerts S '{"id":"S"}')"
jq -e 'has("watcher") | not' <<<"$p" >/dev/null && ok "hub export carries no watcher field while the watcher covers" || no "export: $p"
err="$(CLAUDE_CODE_SESSION_ID=S OUTSOURCERER_TMUX=w1 perl -e 'alarm 30; exec @ARGV' "$SRC" session read 2>&1 >/dev/null)"
grep -q 'no watcher' <<<"$err" && no "per-command warning fired under a covering watcher: [$err]" || ok "per-command warning is silent under a covering watcher"
out="$(printf '{"session_id":"S"}' | "$SRC" stop-guard 2>/dev/null)"
grep -q '"decision":"block"' <<<"$out" && no "stop guard blocked under the watcher [$out]" || ok "stop guard agrees: no block"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
