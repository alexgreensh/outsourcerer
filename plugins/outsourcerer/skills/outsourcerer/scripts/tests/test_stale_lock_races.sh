#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# A paused stale reaper must not remove a later generation of the lock.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d "${TMPDIR%/}/osrc-stale-lock.XXXXXX")" || exit 1
export HOME="$T/home" OSRC_HOME="$T/state" OSRC_HEARTBEAT_DISABLED=1
mkdir -p "$HOME" "$OSRC_HOME"
a=""; b=""
cleanup() {
  : > "$T/go"; : > "$T/finish"
  [ -z "$a" ] || { kill "$a" 2>/dev/null || true; wait "$a" 2>/dev/null || true; }
  [ -z "$b" ] || { kill "$b" 2>/dev/null || true; wait "$b" 2>/dev/null || true; }
  rm -rf "$T"
}
trap cleanup EXIT
set --; . "$HERE/../outsourcerer.sh" >/dev/null 2>&1
trap cleanup EXIT
wait_file() {
  local deadline=$((SECONDS + 25))
  while [ ! -e "$1" ]; do [ "$SECONDS" -lt "$deadline" ] || return 1; command sleep 0.01; done
}
mkdir -p "$OSRC_HOME/done"
for kind in remote done heavy; do
  [ -z "${OSRC_STALE_TEST:-}" ] || [ "$OSRC_STALE_TEST" = "$kind" ] || continue
  rm -f "$T/paused" "$T/go" "$T/finish" "$T/a.rc" "$T/b.rc" "$T/started"
  if [ "$kind" = remote ]; then
    lock="$T/remote"; mkdir "$lock"; touch -t 202001010000 "$lock"
  elif [ "$kind" = done ]; then
    lock="$OSRC_HOME/done/race.checklock"; mkdir "$lock"; printf '1\n' > "$lock/epoch"
  else
    lock="$(_osrc_heavy_lockdir)"; mkdir "$lock"; printf '1\n' > "$lock/epoch"
  fi
  (
    rmdir() {
      if [ "$kind" = remote ] && [ "${1:-}" = "$lock" ]; then : > "$T/paused"; wait_file "$T/go" || exit 2; fi
      command rmdir "$@"
    }
    mv() {
      if [ "$kind" = done ] && [ "${1:-}" = "$lock" ]; then : > "$T/paused"; wait_file "$T/go" || exit 2; fi
      command mv "$@"
    }
    rm() {
      if [ "$kind" = heavy ] && [ "${1:-}" = -rf ] && [ "${2:-}" = "$lock" ]; then : > "$T/paused"; wait_file "$T/go" || exit 2; fi
      command rm "$@"
    }
    rc=0
    case "$kind" in remote) _osrc_lock "$lock" || rc=$? ;; done) _osrc_done_check_lock race || rc=$? ;; heavy) _osrc_heavy_lock 0 || rc=$? ;; esac
    printf '%s\n' "$rc" > "$T/a.rc"
    if [ "$rc" = 0 ] && [ "$kind" != done ]; then
      wait_file "$T/finish" || exit 2
      if [ "$kind" = remote ]; then _osrc_unlock "$lock"; else _osrc_heavy_unlock; fi
    fi
  ) > "$T/a.out" 2>&1 & a=$!
  wait_file "$T/paused" || { echo "FAIL: $kind reaper did not pause"; exit 1; }
  (
    : > "$T/started"; rc=0
    case "$kind" in remote) _osrc_lock "$lock" || rc=$? ;; done) _osrc_done_check_lock race || rc=$? ;; heavy) _osrc_heavy_lock 0 || rc=$? ;; esac
    if [ "$rc" = 0 ] && [ "$kind" = done ]; then date +%s > "$lock/epoch"; fi
    printf '%s\n' "$rc" > "$T/b.rc"
    if [ "$rc" = 0 ] && [ "$kind" != done ]; then
      wait_file "$T/finish" || exit 2
      if [ "$kind" = remote ]; then _osrc_unlock "$lock"; else _osrc_heavy_unlock; fi
    fi
  ) > "$T/b.out" 2>&1 & b=$!
  wait_file "$T/started" || exit 1
  # Legacy B can replace the lock now. Guarded B instead waits for A.
  n=0; while [ ! -e "$T/b.rc" ] && [ "$n" -lt 100 ]; do command sleep 0.01; n=$((n + 1)); done
  : > "$T/go"
  wait_file "$T/a.rc" && wait_file "$T/b.rc" || { echo "FAIL: $kind racers timed out"; exit 1; }
  ar="$(cat "$T/a.rc")"; br="$(cat "$T/b.rc")"
  : > "$T/finish"; wait "$a" || exit 1; a=""; wait "$b" || exit 1; b=""
  if [ "$ar" = 0 ] && [ "$br" = 0 ]; then echo "FAIL: $kind stale reaper admitted two owners"; exit 1; fi
  [ "$ar" = 0 ] || [ "$br" = 0 ] || { echo "FAIL: $kind elected no owner"; exit 1; }
  echo "PASS: $kind stale reaper cannot replace a live owner"
done

if [ -z "${OSRC_STALE_TEST:-}" ] || [ "$OSRC_STALE_TEST" = cleanup ]; then
  rm -f "$T/paused" "$T/go" "$T/finish" "$T/a.rc" "$T/b.rc" "$T/started"
  lock="$(_osrc_cl_root)/.lock"; mkdir -p "$lock"; touch -t 202001010000 "$lock"
  export OSRC_CLEANUP_TICK_SECS=0
  _osrc_cleanup_tick_run() { : > "$T/tick-$role"; wait_file "$T/finish"; }
  (
    role=a
    rmdir() {
      if [ "${1:-}" = "$lock" ]; then : > "$T/paused"; wait_file "$T/go" || exit 2; fi
      command rmdir "$@"
    }
    mv() {
      if [ "${1:-}" = "$lock" ]; then : > "$T/paused"; wait_file "$T/go" || exit 2; fi
      command mv "$@"
    }
    _osrc_cleanup_tick; : > "$T/a.rc"
  ) > "$T/a.out" 2>&1 & a=$!
  wait_file "$T/paused" || { echo 'FAIL: cleanup reaper did not pause'; exit 1; }
  ( role=b; : > "$T/started"; _osrc_cleanup_tick; : > "$T/b.rc" ) > "$T/b.out" 2>&1 & b=$!
  wait_file "$T/started" || exit 1
  n=0; while [ ! -e "$T/b.rc" ] && [ "$n" -lt 100 ]; do command sleep 0.01; n=$((n + 1)); done
  : > "$T/go"
  wait_file "$T/a.rc" && wait_file "$T/b.rc" || { echo 'FAIL: cleanup racers timed out'; exit 1; }
  wait "$a" || exit 1; a=""; wait "$b" || exit 1; b=""
  n=0; while [ ! -f "$T/tick-a" ] && [ ! -f "$T/tick-b" ] && [ "$n" -lt 200 ]; do command sleep 0.01; n=$((n + 1)); done
  command sleep 0.1
  if [ -e "$T/tick-a" ] && [ -e "$T/tick-b" ]; then : > "$T/finish"; echo 'FAIL: cleanup stale reaper admitted two workers'; exit 1; fi
  [ -e "$T/tick-a" ] || [ -e "$T/tick-b" ] || { echo 'FAIL: cleanup elected no worker'; exit 1; }
  : > "$T/finish"
  n=0; while [ -d "$lock" ] && [ "$n" -lt 200 ]; do command sleep 0.01; n=$((n + 1)); done
  [ ! -d "$lock" ] || { echo 'FAIL: cleanup worker did not release its lock'; exit 1; }
  echo 'PASS: cleanup stale reaper cannot replace a live worker'
fi

# A queued probe must not inherit a later owner's token after a clear/reclaim.
_osrc_done_check_lock replacement || { echo 'FAIL: initial done claim'; exit 1; }
old_token="$_OSRC_DONE_CLAIM_TOKEN"
osrc_done_clear replacement || exit 1
_osrc_done_check_lock replacement || { echo 'FAIL: replacement done claim'; exit 1; }
new_token="$_OSRC_DONE_CLAIM_TOKEN"
_OSRC_DONE_CLAIM_TOKEN="$old_token"
if _osrc_done_check_spawn replacement "$T" true spec; then
  echo 'FAIL: old done claim spawned under a replacement owner'; exit 1
fi
[ "$(cat "$OSRC_HOME/done/replacement.checklock/owner")" = "$new_token" ] \
  || { echo 'FAIL: old done claim disturbed the replacement owner'; exit 1; }
echo 'PASS: old done claimant cannot use a replacement owner token'
