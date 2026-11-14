# shellcheck shell=bash
# lib/stopguard.sh: who owns what, who is watching it, and the Claude Code Stop hook.
# Sourced by outsourcerer.sh (moved out of the legacy file, which may only shrink). Function
# definitions only: nothing here runs at source time.

# ---- unwatched-job detection --------------------------------------------------------------------
# A detached job nobody is watching is the failure mode this tool exists to prevent: it accepts work,
# goes quiet, and the orchestrator finds out minutes or hours later. Telling the orchestrator to
# "remember to watch" does not survive a busy session, so the tool tracks attention itself and says so
# at the next opportunity, rather than relying on anyone's memory.
_mark_watched() { [ -n "${1:-}" ] && [ -d "$OSRC_JOBS/$1" ] && date +%s > "$OSRC_JOBS/$1/last_seen" 2>/dev/null || true; }

# _unwatched_jobs -> lines "<id> <seconds-since-anyone-looked>" for RUNNING jobs nobody is tracking.
_unwatched_jobs() {
  local jd id st seen now age; now=$(date +%s)
  [ -d "$OSRC_JOBS" ] || return 0
  for jd in "$OSRC_JOBS"/*/; do
    [ -d "$jd" ] || continue
    id="$(basename "$jd")"
    st="$(cat "$jd/status" 2>/dev/null || echo '?')"
    case "$st" in running|launching|"stalled?"|"exploring?"|no-progress-writes) ;; *) continue ;; esac
    seen="$(cat "$jd/last_seen" 2>/dev/null)"
    case "$seen" in ''|*[!0-9]*) seen="$(cat "$jd/started_at" 2>/dev/null)" ;; esac
    case "$seen" in ''|*[!0-9]*) continue ;; esac
    age=$(( now - seen ))
    [ "$age" -ge "${OSRC_UNWATCHED_AFTER:-120}" ] && printf '%s %s\n' "$id" "$age"
  done
}

# The stop guard yields after OSRC_STOP_GUARD_MAX blocks (loop safety). When it does, the owned work
# has NO waiter, so it leaves a loud note that every later outsourcerer call prints until a
# `supervise` is armed (which clears it) or the owned work is settled (the guard clears it).
_sg_print_unguarded() {
  local s f; s="$(_owner_sid)"; [ -n "$s" ] || return 0
  f="$OSRC_HOME/owners/$s/.unguarded"; [ -s "$f" ] || return 0
  sed 's/^/>>> [outsourcerer] /' "$f" >&2
}

# _warn_unwatched -> loud, actionable notice on stderr when live jobs are going unobserved.
_warn_unwatched() {
  _sg_print_unguarded
  local out n; out="$(_unwatched_jobs)"; [ -n "$out" ] || return 0
  n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  printf '>>> [outsourcerer] %s job(s) are RUNNING and nobody has looked at them:\n' "$n" >&2
  printf '%s\n' "$out" | while read -r _i _a; do
    printf '>>>   %s  (unobserved %ss)   watch it: %s watch %s\n' "$_i" "$_a" "$0" "$_i" >&2
  done
  printf '>>>   An unwatched job is how a wedge becomes a lost hour. Watch it, or cancel it.\n' >&2
}

# ---- stop guard (Claude Code Stop hook) ---------------------------------------------------
# Claude Code takes a turn only on user input or when a background command it started exits.
# A delegate launched without a background waiter therefore finishes unnoticed, and the agent keeps
# telling the user it is "still going" (issue #48). The plugin's Stop hook runs `stop-guard`: when
# the session that is about to end its turn owns delegates that still need it and nothing is
# waiting on them, it blocks the stop and names ONE `supervise` command to start.
#
# Owed a waiter (the 2026-11-13 overnight root cause was that idle sessions were not):
#   live     a job/remote lane/session that is working
#   waiting  a session parked on an approval or question, a plan-limit banner, or a READY remote lane
#   idle     an interactive session at an empty composer: owed a waiter ONLY while something else
#            the orchestrator owns is live or waiting (an idle reviewer with queued work).
# A running `supervise` for this session covers every owned target; a `wait <id>` covers its id.
#
# Ownership: every launch made from a Claude Code session records its id under
# $OSRC_HOME/owners/<session-id>/. Other sessions' work never blocks this one.
# Loop safety: the same unwaited set is blocked at most OSRC_STOP_GUARD_MAX times (default 2), then
# the stop is allowed and owners/<sid>/.unguarded is written. A new set blocks again.
# OSRC_STOP_GUARD=0 turns the guard off. Any error allows the stop.
#
# _owner_sid / _owner_record live in lib/handover.sh (L8), one copy for every lane.

# _owned_live_state lives in lib/owner_state.sh (shared with the hub, lane status and cleanup).

# One screen read can catch a busy Codex pane in an idle-looking frame (FINDINGS 8), and when that
# lane is the only owned target the stop would be allowed. Idle counts only once supervise (or the
# beacon) has confirmed it: an idle event was logged, or the same quiet screen held for the confirm window.
_sg_confirmed_quiet() { # <id> <kind> -> idle|live
  _sv_state_read "$1"
  case "$SVS_LK" in idle:*|done:*) printf 'idle'; return 0 ;; esac
  if [ "$SVS_CK" = "$2" ] && [ $(( $(date +%s) - SVS_CS )) -ge "$(_sv_num "${OSRC_SUPERVISE_CONFIRM:-}" 20)" ]; then printf 'idle'; return 0; fi
  printf 'live'
}

# _waited_ids [owner-sid] -> ids a running `wait` / `fanout wait` covers, one per line. A line `*`
# means a live `supervise` for that owner covers every target it owns.
_waited_ids() {
  local line rest gid
  [ -z "${1:-}" ] || _sv_armed_cover "$1"
  ps -axo command= 2>/dev/null | grep -E 'outsourcerer(\.sh)?[^ ]* (.* )?wait( |$)' | grep -v 'stop-guard' | while IFS= read -r line; do
    rest="${line##* wait }"
    case "$line" in
      *" fanout wait "*)
        gid="${line##* fanout wait }"; gid="${gid%% *}"
        [ -f "$(_fanout_dir "$gid" 2>/dev/null)/members.tsv" ] && cut -f1 "$(_fanout_dir "$gid")/members.tsv" 2>/dev/null
        ;;
      *) printf '%s\n' "${rest%% *}" ;;
    esac
  done
}

cmd_stop_guard() {
  [ "${OSRC_STOP_GUARD:-1}" = "0" ] && return 0
  have jq || return 0
  local input sid dir need="" idle="" id state waited n reason key cnt unwaited="" max="${OSRC_STOP_GUARD_MAX:-2}"
  case "$max" in ''|*[!0-9]*) max=2 ;; esac
  input="$(head -c 65536 2>/dev/null)" || input=""
  sid="$(_owner_sid "$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)")"
  [ -n "$sid" ] || sid="$(_owner_sid)"
  [ -n "$sid" ] || return 0
  dir="$OSRC_HOME/owners/$sid"
  [ -d "$dir" ] || return 0
  for id in $(ls -1 "$dir" 2>/dev/null); do
    state="$(_owned_live_state "$id" 2>/dev/null)"
    case "$state" in
      done|gone)
        # Log the terminal event BEFORE the marker goes, tagged with this owner, so the next
        # supervise replays "finished" instead of reporting "nothing owned" (review finding 2).
        # If that log write fails, keep the marker: the next pass tries again.
        if type _sv_observe >/dev/null 2>&1; then
          _sv_observe "$id" "$(date +%s)" stopguard "$sid" >/dev/null 2>&1
          _sv_emit "$id" "$(date +%s)" stopguard "$sid" >/dev/null 2>&1 || continue
        fi
        rm -f "$dir/$id" 2>/dev/null ;;
      idle) idle="$idle $id" ;;
      *) need="$need $id" ;;
    esac
  done
  if [ -z "$need" ]; then
    rm -f "$dir/.stop-blocks" "$dir/.unguarded" 2>/dev/null
    rmdir "$dir" 2>/dev/null
    return 0
  fi
  need="${need# }${idle}"
  waited="$(_waited_ids "$sid" 2>/dev/null)"
  if printf '%s\n' "$waited" | grep -qxF '*'; then
    rm -f "$dir/.stop-blocks" "$dir/.unguarded" 2>/dev/null
    return 0
  fi
  for id in $need; do printf '%s\n' "$waited" | grep -qxF "$id" || unwaited="$unwaited $id"; done
  unwaited="${unwaited# }"
  [ -n "$unwaited" ] || return 0
  # Loop safety: count consecutive blocks for this exact set.
  key="$(printf '%s' "$unwaited" | cksum | awk '{print $1}')"
  cnt="$(awk -v k="$key" '$1==k{print $2}' "$dir/.stop-blocks" 2>/dev/null)"; cnt="${cnt:-0}"
  if [ "$cnt" -ge "$max" ]; then
    printf '%s UNGUARDED: %s owned by this session have NO waiter (stop-guard yielded after %s reminders). Nothing will wake you. Arm: %s supervise --session %s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$unwaited" "$cnt" "$SCRIPT_PATH" "$sid" > "$dir/.unguarded" 2>/dev/null
    printf '[outsourcerer] stop-guard: %s need a waiter and have none; letting the turn end after %s reminders. Recorded in %s.\n' "$unwaited" "$cnt" "$dir/.unguarded" >&2
    return 0
  fi
  printf '%s %s\n' "$key" "$((cnt + 1))" > "$dir/.stop-blocks" 2>/dev/null
  n="$(printf '%s\n' $unwaited | grep -c .)"
  reason="$(printf 'Outsourcerer: %s delegate(s) you own still need you (%s), and nothing will wake you when they do. Before ending your turn, start ONE background command (Bash with run_in_background: true):\n  %s supervise --session %s' "$n" "$unwaited" "$SCRIPT_PATH" "$sid")"
  reason="$reason$(printf '\nIt returns with EVENT/NEXT lines the moment any of them is blocked, asks a question, finishes, or stalls. Run each NEXT, then arm supervise again. Tell the user what is running.')"
  jq -cn --arg r "$reason" '{decision:"block", reason:$r}'
  return 0
}
