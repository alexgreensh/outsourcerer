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

# A reaper excludes new acquisitions, then checks the same path again. Without
# that exclusion a stale check can be followed by a rename of a new live mutex.
_osrc_guarded_mutex_acquire() {
  local mx="$1.mx" guard="$1.mx.reaping" candidates="$1.mx.candidates" n=0 dead ticket p busy
  mkdir -p "$candidates" 2>/dev/null || return 1
  while [ "$n" -lt 100 ]; do
    if [ ! -d "$guard" ]; then
      # A ticket covers the mkdir-to-pid window, even if the creator is paused
      # for longer than the legacy ownerless-lock age threshold.
      ticket="$(umask 077; mktemp "$candidates/${_BASHPID:-$$}.XXXXXX")" || return 1
      if [ ! -d "$guard" ] && (umask 077; mkdir "$mx") 2>/dev/null; then
        if [ -d "$guard" ]; then
          rmdir "$mx" 2>/dev/null || { rm -f "$ticket"; return 1; }
        else
          printf '%s\n' "${_BASHPID:-$$}" > "$mx/pid" 2>/dev/null || {
            rm -f "$mx/pid" "$ticket" 2>/dev/null; rmdir "$mx" 2>/dev/null; return 1
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
        dead="$mx.dead.${_BASHPID:-$$}.$RANDOM"
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

_osrc_guarded_mutex_release() { rm -rf "$1.mx" 2>/dev/null; }
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
