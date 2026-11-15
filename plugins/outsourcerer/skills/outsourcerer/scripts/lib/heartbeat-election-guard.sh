#!/usr/bin/env bash
# Serialize mkdir-election recovery as well as the claim it protects. The
# flock path already owns an OS lease and does not need the sidecar mutex.
_heartbeat_election_acquire() {
  if [ "${OSRC_FORCE_MKDIR_ELECTION:-0}" != 1 ] && command -v flock >/dev/null 2>&1; then
    _heartbeat_election_acquire_inner "$@"
    return $?
  fi
  _bashpid_into
  _osrc_guarded_mutex_acquire "$1" || return 1
  if _heartbeat_election_acquire_inner "$@"; then
    _HEARTBEAT_ELECTION_GUARDED=1
    return 0
  fi
  _osrc_guarded_mutex_release "$1"
  return 1
}

_heartbeat_election_release() {
  local lock="$1"
  case "${_HEARTBEAT_ELECTION_KIND:-}" in
    flock) flock -u 8 2>/dev/null || true; exec 8>&- ;;
    mkdir) _heartbeat_remove_tree "$lock" || true ;;
  esac
  _HEARTBEAT_ELECTION_KIND=""
  if [ "${_HEARTBEAT_ELECTION_GUARDED:-0}" = 1 ]; then
    _osrc_guarded_mutex_release "$lock"
    _HEARTBEAT_ELECTION_GUARDED=0
  fi
}
