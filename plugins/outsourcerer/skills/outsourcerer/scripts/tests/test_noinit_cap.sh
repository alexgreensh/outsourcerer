#!/usr/bin/env bash
# Exercise startup with real log writes and a controlled, portable log lookup.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
export HOME="$T" OSRC_HOME="$T" OSRC_POLL=1
. "$DIR/../outsourcerer.sh" >/dev/null 2>&1
mkdir -p "$T/work"
LIVE_LOG="$T/live.log"
_devin_live_mtime() { : > "$T/scanned"; [ -f "$LIVE_LOG" ] && { stat -c %Y "$LIVE_LOG" 2>/dev/null || stat -f %m "$LIVE_LOG" 2>/dev/null; }; }
_kill_job() { kill "$2" 2>/dev/null || :; }
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
job() { mkdir -p "$T/$1"; printf '{"verb":"explore","lane":"%s","cwd":"%s"}\n' "$2" "$T/work" > "$T/$1/meta.json"; }
job warm dv
start=$(date +%s)
OSRC_NOINIT_SECS=5 _supervise "$T/warm" 45 50 32 -- /bin/bash -c 'while :; do touch "$1"; sleep 1; done' _ "$LIVE_LOG" >/dev/null 2>&1
rc=$?; elapsed=$(( $(date +%s) - start ))
if [ "$rc" = 124 ] && [ "$elapsed" -ge 32 ] && grep -q '^hard-timeout:' "$T/warm/reason"; then
  ok "warm log hands off at cap to hard timeout (${elapsed}s)"
else
  bad "warm log handoff rc=$rc elapsed=$elapsed reason=$(cat "$T/warm/reason" 2>/dev/null)"
fi
rm -f "$LIVE_LOG"
job cold dv
start=$(date +%s)
OSRC_NOINIT_SECS=3 _supervise "$T/cold" 30 45 30 -- /bin/bash -c 'sleep 2; touch "$1"; sleep 30' _ "$LIVE_LOG" >/dev/null 2>&1
rc=$?; elapsed=$(( $(date +%s) - start )); reason=$(cat "$T/cold/reason" 2>/dev/null)
if [ "$rc" = 125 ] && [ "$elapsed" -ge 4 ] && [ "$elapsed" -lt 20 ] && printf '%s\n' "$reason" | grep -Eq '^no-init: delegate never started after [0-9]+s'; then
  reported=$(printf '%s\n' "$reason" | sed -E 's/^no-init: delegate never started after ([0-9]+)s.*/\1/')
  if [ "$reported" -ge 4 ] && [ "$reported" -le "$elapsed" ]; then ok "cold log triggers no-init with elapsed time"; else bad "incorrect elapsed time: $reason"; fi
else
  bad "cold log rc=$rc elapsed=$elapsed reason=$reason"
fi
for value in 5m 150s; do
  rm -f "$LIVE_LOG"; job "invalid-$value" dv
  OSRC_NOINIT_SECS="$value" _supervise "$T/invalid-$value" 30 45 4 -- /bin/bash -c 'while :; do touch "$1"; sleep 1; done' _ "$LIVE_LOG" >/dev/null 2>&1
  rc=$?
  if [ "$rc" = 124 ] && grep -q '^hard-timeout:' "$T/invalid-$value/reason"; then ok "$value defaults to 150 without aborting supervisor"; else bad "$value rc=$rc"; fi
done
rm -f "$LIVE_LOG"; job leading dv
OSRC_NOINIT_SECS=08 _supervise "$T/leading" 30 45 20 -- /bin/bash -c 'sleep 30' >/dev/null 2>&1
rc=$?
if [ "$rc" = 125 ] && grep -Eq '^no-init: delegate never started after ([89]|[1-9][0-9]+)s' "$T/leading/reason"; then ok '08 is decimal eight'; else bad "08 rc=$rc reason=$(cat "$T/leading/reason" 2>/dev/null)"; fi
rm -f "$LIVE_LOG" "$T/scanned"; job other cc
OSRC_NOINIT_SECS=2 _supervise "$T/other" 30 45 10 -- /bin/bash -c 'sleep 30' >/dev/null 2>&1
rc=$?
if [ "$rc" = 125 ] && [ ! -e "$T/scanned" ] && grep -q '^no-init:' "$T/other/reason"; then ok 'non-Devin startup does not scan Devin logs'; else bad "non-Devin scan or verdict rc=$rc"; fi
printf 'passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
