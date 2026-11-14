#!/usr/bin/env bash
# lib/owner_state.sh -- owner liveness shared by the stop guard, the hub, and the
# cleanup manifest. Moved here from outsourcerer.sh for the file-size ratchet;
# neutral name because several lanes call it (it is not hub-owned state).

# One copy, used by the stop guard, supervise's callers, the hub, lane status and cleanup.
# States: live (working), waiting (parked on an approval/question/limit/error, or a READY remote
# lane: it needs the orchestrator), idle (quiet and confirmed), done, gone. done/gone mean the
# owner record can go. Screen reading is L3's, through L1's _sv_target_screen.
# _owned_live_state <id> -> live|waiting|idle|done|gone. done/gone mean the owner record can go.
_owned_live_state() {
  local id="$1" st
  # A hand-in watch (supervise --watch) is live until --unwatch: a lane can re-hand-in at any time.
  case "$id" in watch.*) if [ -f "$OSRC_HOME/watch/$id.path" ]; then printf 'live'; else printf 'gone'; fi; return 0 ;; esac
  if [ -f "$OSRC_HOME/remote/$id.json" ] && type osrc_remote_state >/dev/null 2>&1; then
    case "$(osrc_remote_state "$id" 2>/dev/null)" in
      ready) printf 'waiting' ;;
      done|failed) printf 'done' ;;
      gone) printf 'gone' ;;
      *) printf 'live' ;;
    esac
    return 0
  fi
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
    # Read the pane itself (osrc_screen_state), not the fleet snapshot: the snapshot can be stale or
    # missing, and it used to call every non-working session "idle", including one parked on a
    # question. An unreadable pane counts as live: it cannot be proven settled.
    local out ev; out="$(_sv_target_screen "$id" 2>/dev/null)"; st="${out%%$'\n'*}"; ev="${out#*$'\n'}"
    case "$st" in
      approval|question|limit|failed) printf 'waiting' ;;
      done) printf 'idle' ;;
      composer) case "$ev" in *"no turn yet"*) printf 'idle' ;; *) _sg_confirmed_quiet "$id" composer ;; esac ;;
      idle) _sg_confirmed_quiet "$id" idle ;;
      *) printf 'live' ;;
    esac
    return 0
  fi
  printf 'gone'
}
