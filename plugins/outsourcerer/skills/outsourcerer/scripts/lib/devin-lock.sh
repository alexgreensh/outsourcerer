#!/usr/bin/env bash
# Lock recovery must not treat an inconclusive liveness check as death.
_devin_pid_gone() {
  local result
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  result="$(LC_ALL=C kill -0 "$1" 2>&1)" && return 1
  case "$result" in *'No such process'*) return 0 ;; *) return 1 ;; esac
}

_devin_lock_debris() {
  local o=""; { read -r o < "$1/pid"; } 2>/dev/null
  if [ -n "$o" ]; then _devin_pid_gone "$o"; return; fi
  [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]
}

# BASHPID is not available in Bash 3.2, and $$ can identify a parent shell.
_osrc_mutex_self_pid() {
  if [ -n "${BASHPID:-}" ]; then _OSRC_MUTEX_SELF="$BASHPID"; return 0; fi
  local f
  f="$(umask 077; mktemp "$1/.pid.XXXXXX")" || return 1
  _OSRC_MUTEX_SELF=""
  sh -c 'echo $PPID' > "$f" 2>/dev/null && { read -r _OSRC_MUTEX_SELF < "$f"; } 2>/dev/null
  rm -f "$f" 2>/dev/null
  case "$_OSRC_MUTEX_SELF" in ''|*[!0-9]*) return 1 ;; esac
}

# A reaper excludes new acquisitions, then checks the same path again. Without
# that exclusion a stale check can be followed by a rename of a new live mutex.
_osrc_guarded_mutex_acquire() {
  local mx="$1.mx" guard="$1.mx.reaping" candidates="$1.mx.candidates" n=0 dead ticket p busy owner
  mkdir -p "$candidates" 2>/dev/null || return 1
  _osrc_mutex_self_pid "$candidates" || return 1
  owner="$_OSRC_MUTEX_SELF"
  while [ "$n" -lt 100 ]; do
    if [ ! -d "$guard" ]; then
      # A ticket covers the mkdir-to-pid window, even if the creator is paused
      # for longer than the legacy ownerless-lock age threshold.
      ticket="$(umask 077; mktemp "$candidates/$owner.XXXXXX")" || return 1
      if [ ! -d "$guard" ] && (umask 077; mkdir "$mx") 2>/dev/null; then
        if [ -d "$guard" ]; then
          # The pathname may already name a different generation. Leave an
          # unowned directory for guarded stale recovery rather than deleting it.
          rm -f "$ticket" 2>/dev/null
          return 1
        else
          printf '%s\n' "$owner" > "$mx/pid" 2>/dev/null || {
            # A failed write does not prove this pathname is still ours.
            rm -f "$ticket" 2>/dev/null; return 1
          }
          rm -f "$ticket" 2>/dev/null
          return 0
        fi
      fi
      rm -f "$ticket" 2>/dev/null
    fi
    if [ ! -d "$guard" ] && _devin_lock_debris "$mx" && (umask 077; mkdir "$guard") 2>/dev/null; then
      busy=0
      for ticket in "$candidates"/*; do
        [ -e "$ticket" ] || continue
        p="${ticket##*/}"; p="${p%%.*}"
        if _devin_pid_gone "$p"; then rm -f "$ticket" 2>/dev/null; else busy=1; fi
      done
      if [ "$busy" = 0 ] && _devin_lock_debris "$mx"; then
        dead="$mx.dead.$owner.$RANDOM"
        if mv "$mx" "$dead" 2>/dev/null; then
          if _devin_lock_debris "$dead"; then
            rm -rf "$dead" 2>/dev/null
          elif [ ! -e "$mx" ] && mv "$dead" "$mx" 2>/dev/null; then
            :
          else
            # Keep the guard if restoration fails: never admit a second owner.
            printf 'outsourcerer: cannot safely restore mutex %s; repair %s before retrying.\n' "$mx" "$guard" >&2
            return 1
          fi
        fi
      fi
      rmdir "$guard" 2>/dev/null || return 1
    fi
    n=$((n + 1))
    sleep 0.1 2>/dev/null || sleep 1
  done
  [ ! -d "$guard" ] || printf 'outsourcerer: mutex reclamation guard %s is still present; no lock was claimed.\n' "$guard" >&2
  return 1
}

_osrc_guarded_mutex_release() {
  local mx="$1.mx" guard="$1.mx.reaping" candidates="$1.mx.candidates" ticket pid owner n=0 nonce worker rc=0
  [ -d "$mx" ] || return 0
  mkdir -p "$candidates" 2>/dev/null || return 1
  _osrc_mutex_self_pid "$candidates" || return 1
  owner="$_OSRC_MUTEX_SELF"
  # Keep a live ticket until rm completes, including its ownerless window.
  ticket="$(umask 077; mktemp "$candidates/$owner.XXXXXX")" || return 1
  # A guard already held may have scanned candidates before this ticket existed.
  # Once it clears, any later reaper must observe our ticket before deleting.
  while [ -d "$guard" ]; do
    n=$((n + 1))
    if [ "$n" -ge 100 ]; then
      rm -f "$ticket" 2>/dev/null
      printf 'outsourcerer: mutex release deferred while reclamation guard %s is present.\n' "$guard" >&2
      return 1
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
  pid="$(cat "$mx/pid" 2>/dev/null)"
  if [ "$pid" != "$owner" ]; then rm -f "$ticket" 2>/dev/null; return 1; fi
  # The deleting process holds its own ticket across exec. If the calling shell
  # dies while rm is paused, the reaper still sees the live remover's PID.
  nonce="$RANDOM.$RANDOM"
  (
    _osrc_mutex_self_pid "$candidates" || exit 1
    local worker_ticket="$candidates/$_OSRC_MUTEX_SELF.$nonce"
    (umask 077; set -o noclobber; : > "$worker_ticket") 2>/dev/null || exit 1
    [ -f "$ticket" ] && kill -0 "$owner" 2>/dev/null || exit 1
    exec rm -rf "$mx"
  ) 2>/dev/null &
  worker=$!
  wait "$worker" || rc=$?
  if [ "$rc" != 0 ]; then
    printf 'outsourcerer: mutex release failed for %s; protection remains at %s.\n' "$mx" "$ticket" >&2
    return 1
  fi
  rm -f "$candidates/$worker.$nonce" "$ticket" 2>/dev/null
}
_devin_lock_mutex_acquire() { _osrc_guarded_mutex_acquire "$@"; }
_devin_lock_mutex_release() { _osrc_guarded_mutex_release "$@"; }

_devin_lock_stale() {
  local lock="$1" h p live=0
  [ -d "$lock/holders" ] || [ -s "$lock/pid" ] || { _devin_lock_debris "$lock"; return; }
  for h in "$lock"/holders/*; do
    [ -e "$h" ] || continue
    p="${h##*/}"
    case "$p" in ''|*[!0-9]*) rm -f "$h" 2>/dev/null; continue ;; esac
    if _devin_pid_gone "$p"; then rm -f "$h" 2>/dev/null; else live=1; fi
  done
  p="$(cat "$lock/pid" 2>/dev/null)"
  [ -n "$p" ] && ! _devin_pid_gone "$p" && live=1
  [ "$live" = "0" ]
}
