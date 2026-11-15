#!/usr/bin/env bash
# Exercise a paused real rm and a replacement during failed PID publication.
set -uo pipefail
[ "$(uname -s)" = Linux ] || { echo 'SKIP: release syscall interposition requires Linux'; exit 0; }
command -v cc >/dev/null 2>&1 || { echo 'FAIL: release syscall test requires a C compiler'; exit 1; }
T="$(mktemp -d "${TMPDIR:-/tmp}/mutex-release-race.XXXXXX")" || exit 1
export HOME="$T/home" OSRC_HOME="$T/state"
mkdir -p "$HOME" "$OSRC_HOME"
a=""; holder=""; remover=""
cleanup() {
  : > "$T/orphan-go" 2>/dev/null || true
  [ -z "$a" ] || { kill "$a" 2>/dev/null || true; wait "$a" 2>/dev/null || true; }
  [ -z "$holder" ] || { kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; }
  # If the injected remover is still live, let container cleanup own its scratch.
  [ -z "$remover" ] || return 0
  rm -rf "$T"
}
trap cleanup EXIT
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/devin-lock.sh"
cc -shared -fPIC "$HERE/fixtures/pause-rmdir.c" -ldl -o "$T/pause.so" || exit 1
wait_file() {
  local deadline=$((SECONDS + 20))
  while [ ! -e "$1" ]; do [ "$SECONDS" -lt "$deadline" ] || return 1; command sleep 0.01; done
}
current_pid() {
  if [ -n "${BASHPID:-}" ]; then _BASHPID="$BASHPID"; return; fi
  local f="$T/self.$$.${RANDOM}"
  sh -c 'echo $PPID' > "$f"; read -r _BASHPID < "$f"; rm -f "$f"
}
lock="$OSRC_HOME/sample"; mx="$lock.mx"; failed=0
(
  current_pid
  _osrc_guarded_mutex_acquire "$lock" || exit 2
  : > "$T/a-acquired"; wait_file "$T/a-release" || exit 2
  export LD_PRELOAD="$T/pause.so" PAUSE_TARGET="$mx" PAUSE_READY="$T/a-paused" PAUSE_GO="$T/a-go"
  _osrc_guarded_mutex_release "$lock"
) > "$T/a.out" 2>&1 & a=$!
wait_file "$T/a-acquired" || { echo 'FAIL: first holder did not acquire'; exit 1; }
: > "$T/a-release"
wait_file "$T/a-paused" || { echo 'FAIL: release did not reach the removal syscall'; exit 1; }
[ ! -e "$mx/pid" ] || { echo 'FAIL: release pause was before PID removal'; exit 1; }
touch -t 202601010000 "$mx"
(
  current_pid; sleep() { :; }
  _osrc_guarded_mutex_acquire "$lock" || exit 1
  _osrc_guarded_mutex_release "$lock"
) > "$T/b.out" 2>&1
brc=$?
if [ "$brc" = 0 ]; then
  echo 'FAIL: a contender reclaimed a mutex while its live owner was paused in release'; failed=1
else
  echo 'PASS: a paused release remains protected from reclamation'
fi
: > "$T/a-go"; wait "$a" || { echo 'FAIL: paused release failed'; failed=1; }; a=""

# Force PID publication to fail after replacing the just-created directory with
# a live owner's generation, as in REV7's C/D step. Cleanup must not remove it.
(
  current_pid
  printf() {
    if [ "${1:-}" = '%s\n' ] && [ "${2:-}" = "$_BASHPID" ] && [ -d "$mx" ]; then
      command rm -f "$mx/pid"; command rmdir "$mx"; command mkdir "$mx"
      builtin printf '%s\n' "$$" > "$mx/pid"
      return 1
    fi
    builtin printf "$@"
  }
  _osrc_guarded_mutex_acquire "$lock"
) > "$T/c.out" 2>&1
crc=$?
if [ "$crc" != 0 ] && [ "$(cat "$mx/pid" 2>/dev/null)" = "$$" ]; then
  echo 'PASS: failed PID publication preserves the replacement owner'
else
  printf 'FAIL: failed PID publication removed or changed the replacement (rc=%s)\n' "$crc"; failed=1
fi
mkdir "$lock.mx.reaping"
sleep() { :; }
_osrc_guarded_mutex_release "$lock" > "$T/guarded-release.out" 2>&1
grc=$?
unset -f sleep
if [ "$grc" != 0 ] && [ "$(cat "$mx/pid" 2>/dev/null)" = "$$" ]; then
  echo 'PASS: release does not delete a mutex behind an active reaper guard'
else
  printf 'FAIL: release deleted a mutex behind an active reaper guard (rc=%s)\n' "$grc"; failed=1
fi
rmdir "$lock.mx.reaping"
(
  # Bash keeps $$ across subshells: an inherited owner hint is not child identity.
  _BASHPID="$$"
  _osrc_guarded_mutex_release "$lock"
) > "$T/inherited-release.out" 2>&1
irc=$?
if [ "$irc" != 0 ] && [ "$(cat "$mx/pid" 2>/dev/null)" = "$$" ]; then
  echo 'PASS: inherited owner identity cannot release the parent mutex'
else
  printf 'FAIL: inherited owner identity released the parent mutex (rc=%s)\n' "$irc"; failed=1
fi
(
  current_pid
  _osrc_guarded_mutex_release "$lock"
) > "$T/wrong-release.out" 2>&1
rrc=$?
if [ "$rrc" != 0 ] && [ "$(cat "$mx/pid" 2>/dev/null)" = "$$" ]; then
  echo 'PASS: a non-owner cannot release the replacement mutex'
else
  printf 'FAIL: non-owner release changed the replacement (rc=%s)\n' "$rrc"; failed=1
fi
(
  current_pid; sleep() { :; }
  _osrc_guarded_mutex_acquire "$lock"
) > "$T/e.out" 2>&1
if [ $? -eq 0 ]; then
  echo 'FAIL: another contender acquired while the replacement owner was live'; failed=1
else
  echo 'PASS: a live replacement excludes another contender'
fi
(
  unset BASHPID
  _osrc_mutex_self_pid "$lock.mx.candidates" || exit 1
  sh -c 'echo $PPID' > "$T/expected-pid"
  [ "$_OSRC_MUTEX_SELF" = "$(cat "$T/expected-pid")" ]
) && echo 'PASS: PID fallback identifies the current shell' \
  || { echo 'FAIL: PID fallback did not identify the current shell'; failed=1; }
(
  unset BASHPID
  lock="$OSRC_HOME/bash3"
  _osrc_guarded_mutex_acquire "$lock" || exit 1
  _osrc_guarded_mutex_release "$lock" || exit 1
  [ ! -e "$lock.mx" ] && [ -z "$(find "$lock.mx.candidates" -type f -print)" ]
) && echo 'PASS: PID fallback releases the mutex and both tickets' \
  || { echo 'FAIL: PID fallback left a mutex or ticket'; failed=1; }
(
  lock="$OSRC_HOME/delete-failure"
  current_pid; owner="$_BASHPID"
  _osrc_guarded_mutex_acquire "$lock" || exit 1
  mkdir "$T/rm-bin"
  cat > "$T/rm-bin/rm" <<'SH'
#!/bin/sh
if [ "${1:-}" = -rf ] && [ "${2:-}" = "$FAIL_MX" ]; then exit 1; fi
exec /bin/rm "$@"
SH
  chmod +x "$T/rm-bin/rm"
  export FAIL_MX="$lock.mx" PATH="$T/rm-bin:$PATH"
  _osrc_guarded_mutex_release "$lock" 2> "$T/delete.err" && exit 1
  set -- "$lock.mx.candidates/$owner."*
  [ -e "$1" ] && grep -q 'protection remains' "$T/delete.err"
) && echo 'PASS: failed deletion retains its live release ticket' \
  || { echo 'FAIL: failed deletion exposed a partially released mutex'; failed=1; }

# A killed releasing shell must not strand an active rm without a live ticket.
lock="$OSRC_HOME/orphan"; mx="$lock.mx"
(
  current_pid; _osrc_guarded_mutex_acquire "$lock" || exit 2
  : > "$T/orphan-acquired"; wait_file "$T/orphan-release" || exit 2
  export LD_PRELOAD="$T/pause.so" PAUSE_TARGET="$mx" PAUSE_READY="$T/orphan-paused" PAUSE_GO="$T/orphan-go"
  _osrc_guarded_mutex_release "$lock"
) > "$T/orphan.out" 2>&1 & holder=$!
wait_file "$T/orphan-acquired" || { echo 'FAIL: orphan holder did not acquire'; exit 1; }
: > "$T/orphan-release"
wait_file "$T/orphan-paused" || { echo 'FAIL: orphan remover did not pause'; exit 1; }
remover="$(cat "$T/orphan-paused")"
kill -KILL "$holder"; wait "$holder" 2>/dev/null || true; holder=""
touch -t 202601010000 "$mx"
(
  current_pid; sleep() { :; }
  _osrc_guarded_mutex_acquire "$lock" || exit 1
  _osrc_guarded_mutex_release "$lock"
) > "$T/orphan-contender.out" 2>&1
if [ $? -eq 0 ]; then
  echo 'FAIL: another contender acquired while an orphaned remover was active'; failed=1
else
  echo 'PASS: an orphaned remover retains live protection'
fi
: > "$T/orphan-go"
deadline=$((SECONDS + 20))
while [ -r "/proc/$remover/stat" ]; do
  state="$(awk '{print $3}' "/proc/$remover/stat" 2>/dev/null)"
  [ "$state" = Z ] && break
  [ "$SECONDS" -lt "$deadline" ] || { echo 'FAIL: orphaned remover did not exit'; exit 1; }
  sleep 0.01
done
remover=""
exit "$failed"
