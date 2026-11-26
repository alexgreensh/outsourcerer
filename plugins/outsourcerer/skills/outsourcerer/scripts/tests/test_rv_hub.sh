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

on F32 && dom F32

echo "RESULTS: $pass pass $fail fail"
[ "$fail" -eq 0 ]
