#!/usr/bin/env bash
# lib/owner_state.sh -- owner liveness shared by the stop guard, the hub, and the
# cleanup manifest. Moved here from outsourcerer.sh for the file-size ratchet;
# neutral name because several lanes call it (it is not hub-owned state).

# One copy, used by the stop guard, supervise's callers, the hub, lane status and cleanup.
# States: live (working), waiting (parked on an approval/question/limit/error, or a READY remote
# lane: it needs the orchestrator), idle (quiet and confirmed), done, gone. done/gone mean the
# owner record can go. Screen reading lives in the screen reader, reached through _sv_target_screen.
# _osrc_ols_tmux_live <id> -> rc 0 when a live tmux session exists for the lane. Inside a hub export
# the memoised session list answers without touching the tmux server, whose queue is then free for
# the pane reads that actually need it; everywhere else this is the same has-session check as before.
_osrc_ols_tmux_live() {
  if [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -f "$_OSRC_HUB_MEMO/tmux" ] \
      && type _osrc_hub_tmux_row >/dev/null 2>&1; then
    _osrc_hub_tmux_row "$1" >/dev/null 2>&1; return
  fi
  have tmux && tmux has-session -t "=$1" 2>/dev/null
}

# _owned_live_state <id> -> live|waiting|idle|done|gone. done/gone mean the owner record can go.
_owned_live_state() {
  local id="$1" st
  # A hand-in watch (supervise --watch) is live until --unwatch: a lane can re-hand-in at any time.
  case "$id" in watch.*) if [ -f "$OSRC_HOME/watch/$id.path" ]; then printf 'live'; else printf 'gone'; fi; return 0 ;; esac
  if [ -f "$OSRC_HOME/remote/$id.json" ] && type osrc_remote_state >/dev/null 2>&1; then
    _osrc_ols_remote "$(osrc_remote_state "$id" 2>/dev/null)"; printf '%s' "$_OLS_ST"; return 0
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
    elif _osrc_ols_tmux_live "$id"; then printf 'live'
    else printf 'gone'; fi
    return 0
  fi
  if _osrc_ols_tmux_live "$id"; then
    # Read the pane itself (osrc_screen_state), not the fleet snapshot: the snapshot can be stale or
    # missing, and it used to call every non-working session "idle", including one parked on a
    # question. An unreadable pane counts as live: it cannot be proven settled.
    local out ev; out="$(_sv_target_screen "$id" 2>/dev/null)"; st="${out%%$'\n'*}"; ev="${out#*$'\n'}"
    type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "ols.$id.scr"
    case "$st" in
      approval|question|limit|failed) printf 'waiting' ;;
      done) printf 'idle' ;;
      composer) case "$ev" in *"no turn yet"*) printf 'idle' ;; *) _sg_confirmed_quiet "$id" composer ;; esac ;;
      idle) _sg_confirmed_quiet "$id" idle ;;
      *) printf 'live' ;;
    esac
    type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "ols.$id.sg"
    return 0
  fi
  printf 'gone'
}

_osrc_ols_remote() { # <remote state> -> _OLS_ST, the owner state (no subshell: the batch calls it per lane)
  case "$1" in ready) _OLS_ST=waiting ;; done|failed) _OLS_ST=done ;; gone) _OLS_ST=gone ;; *) _OLS_ST=live ;; esac
}

# _owned_live_states <id>... -> "<id> <state>" per id, the same answers as _owned_live_state, for the
# stop hook, which used to pay ~10-18 ms per owned marker (a jq per remote lane, ~8 forks per job).
# Remote lanes: ONE jq over every lane file. Jobs: a running job whose delegate is alive with the
# recorded start time is live from ONE `ps` for all of them, and a terminal status is done as read;
# anything else (launching, a dead or unmatched pid, a locale-rendered record) goes to
# _reconcile_status, the single owner of those decisions. Other ids take _owned_live_state as before.
_owned_live_states() {
  local id st f pids="" jobs="" rest="" remotes="" line fn lst pid rec live
  for id in "$@"; do
    case "$id" in ''|*/*|.|..) continue ;; watch.*) rest="$rest $id"; continue ;; esac
    if [ -f "$OSRC_HOME/remote/$id.json" ] && type _osrc_remote_rec_set >/dev/null 2>&1; then remotes="$remotes $id"
    elif [ -d "$OSRC_JOBS/$id" ]; then
      st=""; read -r st 2>/dev/null < "$OSRC_JOBS/$id/status"
      case "$st" in
        done|'done?'|blocked|permission-blocked|failed|wedged|timeout|interrupted|canceled) printf '%s done\n' "$id" ;;
        running|stalled\?|exploring\?|no-progress-writes)
          pid=""; read -r pid 2>/dev/null < "$OSRC_JOBS/$id/pid"
          case "$pid" in ''|*[!0-9]*) rest="$rest $id" ;; *) jobs="$jobs $id:$pid"; pids="$pids${pids:+,}$pid" ;; esac ;;
        *) rest="$rest $id" ;;
      esac
    else rest="$rest $id"; fi
  done
  if [ -n "$remotes" ]; then
    local us=$'\037' done_r=" "; local -a files=()
    for id in $remotes; do files[${#files[@]}]="$OSRC_HOME/remote/$id.json"; done
    while IFS= read -r line; do
      fn="${line%%"$us"*}"; id="${fn##*/}"; id="${id%.json}"
      case "$remotes " in *" $id "*) ;; *) continue ;; esac
      _osrc_remote_rec_set "${line#*"$us"}"
      _osrc_ols_remote "$(_osrc_remote_state_rec "$id" 2>/dev/null)"; printf '%s %s\n' "$id" "$_OLS_ST"; done_r="$done_r$id "
    done < <(jq -r "$_OSRC_RR_DEF input_filename + \"\\u001f\" + ($_OSRC_RR_ROW)" "${files[@]}" 2>/dev/null)
    for id in $remotes; do case "$done_r" in *" $id "*) ;; *) rest="$rest $id" ;; esac; done   # unreadable file: one by one
  fi
  if [ -n "$jobs" ]; then
    lst="$(LC_ALL=C ps -o pid=,lstart= -p "$pids" 2>/dev/null)"
    for f in $jobs; do
      id="${f%%:*}"; pid="${f#*:}"; live=""; rec=""
      [ -f "$OSRC_JOBS/$id/pid_start" ] && { read -r rec 2>/dev/null < "$OSRC_JOBS/$id/pid_start"; set -f; set -- $rec; rec="$*"; set +f; }
      while read -r line; do
        [ "${line%% *}" = "$pid" ] || continue
        set -f; set -- ${line#* }; set +f; [ -n "$rec" ] && [ "$*" = "$rec" ] && live=1; break
      done <<<"$lst"
      if [ -n "$live" ]; then printf '%s live\n' "$id"; else rest="$rest $id"; fi
    done
  fi
  for id in $rest; do printf '%s %s\n' "$id" "$(_owned_live_state "$id" 2>/dev/null)"; done
}
