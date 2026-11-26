# shellcheck shell=bash
# lib/stopguard_pre.sh: the Claude Code Stop hook's fast path (hooks/hooks.json runs this file).
#
# The stop guard runs at every turn end of every session. Most turns belong to a session that owns no
# lane and has no Mission Control card, and for those the full engine (~0.25 s just to load) can only
# answer "allow". This file decides that case from four path tests, without loading the engine, and
# hands everything else (input unchanged) to `outsourcerer.sh stop-guard`. When in doubt it hands over.
# Sourced by the engine as a library, it only defines functions.

# _sg_pre_quiet <osrc-home> <sid> -> 0 when the stop guard has nothing to act on for <sid>: no owner
# registry, no Mission Control record, no card, no decisions. rc 1 for anything unusual (it then runs).
_sg_pre_quiet() {
  local h="$1" s="$2"
  case "$s" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#s}" -le 128 ] || return 1
  [ -d "$h" ] || return 0
  [ -e "$h/owners/$s" ] || [ -e "$h/hub/seen/$s" ] || [ -e "$h/hub/projects/$s.json" ] || [ -e "$h/hub/decisions/$s.json" ] && return 1
  return 0
}

_sg_pre_main() { # <engine>
  local in s
  [ "${OSRC_STOP_GUARD:-1}" = 0 ] && return 0
  in="$(head -c 65536 2>/dev/null)" || in=""
  s=""; case "$in" in *'"session_id"'*) s="${in#*\"session_id\"}"; s="${s#*\"}"; s="${s%%\"*}" ;; esac
  [ -n "$s" ] || s="${CLAUDE_CODE_SESSION_ID:-}"
  _sg_pre_quiet "${OSRC_HOME:-$HOME/.outsourcerer}" "$s" && return 0
  printf '%s' "$in" | "$1" stop-guard
}

# Executed as the hook: never fail the turn (any error allows the stop, as the full guard does).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then _sg_pre_main "$@"; exit 0; fi
