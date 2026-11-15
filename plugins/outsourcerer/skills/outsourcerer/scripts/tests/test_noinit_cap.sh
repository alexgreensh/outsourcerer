#!/usr/bin/env bash
# Exercise the no-init clock with a real growing log and a controlled log lookup.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
export HOME="$T" OSRC_HOME="$T" OSRC_POLL=1 OSRC_NOINIT_SECS=3
. "$DIR/../outsourcerer.sh" >/dev/null 2>&1
mkdir -p "$T/job" "$T/work"
printf '{"verb":"explore","cwd":"%s"}\n' "$T/work" > "$T/job/meta.json"
LIVE_LOG="$T/live.log"
_devin_live_mtime() { [ -f "$LIVE_LOG" ] && { stat -f %m "$LIVE_LOG" 2>/dev/null || stat -c %Y "$LIVE_LOG"; }; }
_kill_job() { kill "$2" 2>/dev/null || :; }
start=$(date +%s)
_supervise "$T/job" 30 45 60 -- /bin/bash -c 'while :; do touch "$1"; sleep 1; done' _ "$LIVE_LOG" >/dev/null 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
if [ "$rc" = 125 ] && grep -q '^no-init' "$T/job/reason" && [ "$elapsed" -ge 14 ] && [ "$elapsed" -lt 30 ]; then
  echo "PASS: growing log reaches capped no-init (elapsed=${elapsed}s)"
  echo 'passed=1 failed=0'
else
  echo "FAIL: cap (rc=$rc elapsed=${elapsed}s reason=$(cat "$T/job/reason" 2>/dev/null))"
  echo 'passed=0 failed=1'
  exit 1
fi
