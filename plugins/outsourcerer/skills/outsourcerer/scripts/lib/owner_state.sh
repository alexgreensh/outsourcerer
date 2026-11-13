#!/usr/bin/env bash
# lib/owner_state.sh -- owner liveness shared by the stop guard, the hub, and the
# cleanup manifest. Moved here from outsourcerer.sh for the file-size ratchet;
# neutral name because several lanes call it (it is not hub-owned state).

# _owned_live_state <id> -> prints live|done|gone. done/gone mean the owner record can go.
_owned_live_state() {
  local id="$1" st
  if [ -d "$OSRC_JOBS/$id" ]; then
    st="$(_reconcile_status "$id" 2>/dev/null || printf '?')"
    case "$st" in
      done|'done?'|blocked|permission-blocked|failed|wedged|timeout|interrupted|canceled) printf 'done' ;;
      *) printf 'live' ;;
    esac
    return 0
  fi
  if [ -e "$OSRC_HOME/autodetach/$id.log" ] || [ -e "$OSRC_HOME/autodetach/$id.rc" ]; then
    if [ -s "$OSRC_HOME/autodetach/$id.rc" ]; then printf 'done'
    elif have tmux && tmux has-session -t "=$id" 2>/dev/null; then printf 'live'
    else printf 'gone'; fi
    return 0
  fi
  if have tmux && tmux has-session -t "=$id" 2>/dev/null; then
    # An interactive session counts only while it is working a turn; an idle REPL is not owed a wait.
    st="$(_fleet_snapshot_read 2>/dev/null | jq -r --arg id "$id" '[.items[]? | select(.session_id==$id) | .state][0] // empty' 2>/dev/null)"
    case "$st" in working|unresponsive\?) printf 'live' ;; *) printf 'idle' ;; esac
    return 0
  fi
  printf 'gone'
}
