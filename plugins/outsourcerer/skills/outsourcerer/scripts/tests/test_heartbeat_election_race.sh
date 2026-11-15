#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# Pause one stale reaper while another contender attempts the same election.
set -uo pipefail
T="$(mktemp -d "${TMPDIR%/}/heartbeat-election-race.XXXXXX")" || exit 1
export HOME="$T/home" OSRC_HOME="$T/state" OSRC_FORCE_MKDIR_ELECTION=1 OSRC_STATE_LOCK_STALE_SECS=0
mkdir -p "$HOME" "$OSRC_HOME"
a=""; b=""
cleanup() {
  [ -z "$a" ] || kill "$a" 2>/dev/null || true
  [ -z "$b" ] || kill "$b" 2>/dev/null || true
  [ -z "$a" ] || wait "$a" 2>/dev/null || true
  [ -z "$b" ] || wait "$b" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT
HERE="$(cd "$(dirname "$0")" && pwd)"
src="$HERE/../outsourcerer.sh"; set --; . "$src" >/dev/null 2>&1
trap cleanup EXIT
_state_sync() { return 0; }
_heartbeat_reclaim_dead_pending() { return 0; }
wait_file() {
  local deadline=$((SECONDS + 20))
  while [ ! -e "$1" ]; do [ "$SECONDS" -lt "$deadline" ] || return 1; sleep 0.01; done
}
mkdir -p "$OSRC_HEARTBEAT/.election"
lock="$OSRC_HEARTBEAT/.election"
touch -t 202601010000 "$lock"
start='Sat Aug 2 01:02:03 2026'
(
  mv() {
    if [ "$1" = "$lock" ]; then
      : > "$T/paused"
      wait_file "$T/release-a" || exit 125
    fi
    command mv "$@"
  }
  rc=0; _heartbeat_election_acquire "$lock" "${BASHPID:-$$}" "$start" || rc=$?
  printf '%s\n' "$rc" > "$T/a.rc"
  [ "$rc" != 0 ] || _heartbeat_election_release "$lock"
) > "$T/a.out" 2>&1 & a=$!
wait_file "$T/paused" || { echo 'FAIL: first reaper never reached the forced interleaving'; exit 1; }
(
  sleep() { :; }
  rc=0; _heartbeat_election_acquire "$lock" "${BASHPID:-$$}" "$start" || rc=$?
  printf '%s\n' "$rc" > "$T/b.rc"
  if [ "$rc" = 0 ]; then
    while [ ! -e "$T/finish-b" ]; do command sleep 0.01; done
    _heartbeat_election_release "$lock"
  fi
) > "$T/b.out" 2>&1 & b=$!
wait_file "$T/b.rc" || { echo 'FAIL: second contender did not return'; exit 1; }
: > "$T/release-a"
wait "$a" || true; a=""
: > "$T/finish-b"
wait "$b" || true; b=""
arc="$(cat "$T/a.rc" 2>/dev/null)"; brc="$(cat "$T/b.rc" 2>/dev/null)"
if [ "$arc" = 0 ] && [ "$brc" != 0 ]; then
  echo 'PASS: a second contender cannot replace the election during stale recovery'
else
  printf 'FAIL: stale recovery admitted both contenders (a=%s b=%s)\n' "$arc" "$brc"
  cat "$T/a.out" "$T/b.out"; exit 1
fi
