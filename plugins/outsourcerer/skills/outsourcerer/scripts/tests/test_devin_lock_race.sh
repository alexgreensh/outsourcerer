#!/usr/bin/env bash
set -uo pipefail
T="$(mktemp -d "${TMPDIR:-/tmp}/devin-lock-race.XXXXXX")" || exit 1
export HOME="$T/home" OSRC_HOME="$T/osrc"
trap 'rm -rf "$T"' EXIT
mkdir -p "$HOME" "$OSRC_HOME"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/devin-lock.sh"

permission_probe() (
  lock="$T/permission"; mkdir -p "$lock/holders"
  printf '%s\n' "$$" > "$lock/pid"; : > "$lock/holders/$$"
  kill() { printf 'Operation not permitted\n' >&2; return 1; }
  if _devin_lock_debris "$lock"; then
    echo 'FAIL: denied liveness probe classified a live mutex as debris'; return 1
  fi
  if _devin_lock_stale "$lock"; then
    echo 'FAIL: denied liveness probe reaped a live grant holder'; return 1
  fi
  [ -e "$lock/holders/$$" ] || { echo 'FAIL: denied probe removed holder record'; return 1; }
  echo 'PASS: denied liveness probe retains the holder'
)

replacement_probe() (
  lock="$T/replace"; mx="$lock.mx"; mkdir "$mx"
  : > "$mx/dead-marker"; first=1; _BASHPID=$$
  # Replace the judged-dead mutex before the reaper acts, then simulate a third
  # contender acquiring the temporarily absent path if the live mutex is moved.
  _devin_lock_debris() {
    if [ "$1" = "$mx" ] && [ "$first" = 1 ]; then
      first=0; rm -rf "$mx"; mkdir "$mx"; : > "$mx/live-marker"; return 0
    fi
    return 1
  }
  mv() {
    command mv "$@" || return $?
    if [ "$1" = "$mx" ]; then mkdir "$mx"; : > "$mx/competitor"; fi
  }
  sleep() { :; }
  _devin_lock_mutex_acquire "$lock" >/dev/null 2>&1 || :
  if [ ! -e "$mx/live-marker" ]; then
    echo 'FAIL: stale reaper moved or deleted a replacement live mutex'; return 1
  fi
  echo 'PASS: stale reaper leaves a replacement live mutex in place'
)

paused_creator_probe() (
  lock="$T/paused"; mx="$lock.mx"; mkdir "$mx" "$mx.candidates"
  : > "$mx/live-marker"; : > "$mx.candidates/$$.paused"
  touch -t 202601010000 "$mx"
  _BASHPID=$$; sleep() { :; }
  _devin_lock_mutex_acquire "$lock" >/dev/null 2>&1 || :
  [ -e "$mx/live-marker" ] || { echo 'FAIL: reaped a paused live mutex creator'; return 1; }
  echo 'PASS: a paused live creator prevents ownerless mutex reclamation'
)

stuck_guard_probe() (
  lock="$T/guard"; mkdir "$lock.mx.reaping"
  _BASHPID=$$; sleep() { :; }
  if _devin_lock_mutex_acquire "$lock" 2> "$T/guard.err"; then
    echo 'FAIL: acquisition bypassed a reclamation guard'; return 1
  fi
  [ ! -e "$lock.mx" ] && grep -q 'guard .* still present' "$T/guard.err" || {
    echo 'FAIL: stuck guard was silent or allowed a mutex claim'; return 1
  }
  echo 'PASS: a stuck reclamation guard fails closed and is named'
)

failed=0
permission_probe || failed=1
replacement_probe || failed=1
paused_creator_probe || failed=1
stuck_guard_probe || failed=1
exit "$failed"
