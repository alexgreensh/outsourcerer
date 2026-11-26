#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_rv_hub.sh -- release review, second pass (F32-F51): Mission Control says only what is true, and
# its token stays with its own hub. One section per finding; each failed on the reviewed commit.
# Usage: test_rv_hub.sh [F32 F36 ...]   (no argument: every section). Sandboxed HOME + OSRC_HOME.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"; LIB="$HERE/../lib"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-rv-hub.XXXXXX")" || { echo "FAIL: no scratch dir" >&2; exit 1; }
PIDS=""
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
no() { echo "FAIL: $1"; fail=$((fail+1)); }
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc" OSRC_HEARTBEAT_DISABLED=1 OSRC_HUB_NO_OPEN=1 OSRC_CATALOG_VALIDATE=0 GIT_CONFIG_NOSYSTEM=1
export OSRC_JOBS="$OSRC_HOME/jobs" OSRC_CLAUDE_SESSIONS_DIR="$HOME/.claude/sessions" OSRC_CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
unset CLAUDE_CODE_SESSION_ID OSRC_HUB_FAST OSRC_HUB_PORT TMUX
mkdir -p "$OSRC_CLAUDE_SESSIONS_DIR" "$OSRC_CLAUDE_PROJECTS_DIR" "$OSRC_JOBS" "$OSRC_HOME/hub/projects"
lib() { ( unset OUTSOURCERER_DEPTH; OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
  _reconcile_status() { cat "$OSRC_JOBS/$1/status" 2>/dev/null; }
  "$@" ); }
SEL="$*"
on() { [ -z "$SEL" ] && return 0; case " $SEL " in *" $1 "*) return 0 ;; esac; return 1; }
NODE="$(command -v node 2>/dev/null || true)"
dom() {   # <section>: the page checks in hub_rv_dom.js
  [ -n "$NODE" ] || { echo "SKIP: node not installed ($1 page checks)"; return 0; }
  local r rc; r="$("$NODE" "$HERE/hub_rv_dom.js" "$LIB" "$1" 2>&1)"; rc=$?
  printf '%s\n' "$r" | grep -E '^(PASS|FAIL)'
  pass=$((pass + $(grep -c '^PASS' <<<"$r"))); fail=$((fail + $(grep -c '^FAIL' <<<"$r")))
  [ "$rc" = 0 ] || [ "$(grep -c '^FAIL' <<<"$r")" -gt 0 ] || no "hub_rv_dom.js $1 exited $rc: $r"
}

# srv_start <engine-script-body> -> a real hub_server.py on a free port with a fake engine; sets SRV_PORT,
# SRV_TOK, SRV_HOME. The engine is a shell script that stands in for `outsourcerer.sh hub export`.
SRV_N=0
srv_start() {
  SRV_N=$((SRV_N + 1)); SRV_HOME="$TMP/srv$SRV_N"; mkdir -p "$SRV_HOME/hub"; chmod 700 "$SRV_HOME/hub"
  printf '#!/bin/sh\n%s\n' "$1" > "$SRV_HOME/engine"; chmod +x "$SRV_HOME/engine"
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "$SRV_HOME/hub/export.json"
  SRV_TOK="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  OSRC_HUB_TOKEN="$SRV_TOK" python3 -I "$LIB/hub_server.py" --bind 127.0.0.1 --port 0 --page "$LIB/hub.html" \
    --engine "$SRV_HOME/engine" --osrc-home "$SRV_HOME" --no-open > "$SRV_HOME/out" 2> "$SRV_HOME/err" &
  PIDS="$PIDS $!"; SRV_PID=$!
  local i; SRV_PORT=""
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    SRV_PORT="$(sed -n 's|.*http://127\.0\.0\.1:\([0-9]*\)/.*|\1|p' "$SRV_HOME/out" 2>/dev/null | head -1)"
    [ -n "$SRV_PORT" ] && break; sleep 0.25
  done
  [ -n "$SRV_PORT" ]
}
srv_get() { curl -s -m 10 -H "X-Hub-Token: $SRV_TOK" "http://127.0.0.1:$SRV_PORT$1"; }
SAVED='{"generated_at":1700000000,"projects":[{"id":"p1","name":"P1","lanes":[{"id":"l1","status":"Building"}]}]}'

on F32 && dom F32

if on F33; then
  dom F33
  if srv_start 'sleep 1; echo "engine broke" >&2; exit 1' "$SAVED"; then
    sleep 2.5; j="$(srv_get /api/projects)"
    jq -e '(.export_error | test("engine broke")) and (.export_error_since | type == "number") and .export_error_since > 1700000000' >/dev/null 2>&1 <<<"$j" \
      && ok "F33: a failing export is sent to the page with export_error and since when" || no "F33: payload: $j"
  else no "F33: the hub did not start: $(cat "$SRV_HOME/err")"; fi
fi

if on F34; then
  dom F34
  if srv_start 'sleep 4; exit 1' "$SAVED"; then
    j="$(srv_get /api/projects)"
    jq -e '.warming == true and .projects[0].id == "p1"' >/dev/null 2>&1 <<<"$j" \
      && ok "F34: a warm start serves the saved export marked warming" || no "F34: payload: $j"
  else no "F34: the hub did not start: $(cat "$SRV_HOME/err")"; fi
fi

echo "RESULTS: $pass pass $fail fail"
[ "$fail" -eq 0 ]
