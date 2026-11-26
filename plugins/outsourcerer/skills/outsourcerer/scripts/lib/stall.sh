# shellcheck shell=bash
# lib/stall.sh: stalled lanes, the autonudge, reminder intervals, approval keystrokes that did not land,
# and watcher liveness. Sourced by outsourcerer.sh (lib loader); function definitions only. Screen reads
# and files, never a model call.
#
# A lane is STALLED when it is idle and
#   bgshell  its own background shell still runs, and the screen has not changed for OSRC_STALL_MIN
#            minutes (default 5); or
#   promise  its last prose promises to continue when something finishes ("after it reports I
#            continue") and nothing is running that could wake it: at once (after the confirm read); or
#   quiet    a plain idle whose screen has not changed for OSRC_STALL_MIN minutes.
# A lane whose last words wait on a person (you, a go-ahead, an approval, a review, the orchestrator, a
# decision) is idle, never stalled: it raises the normal idle event.
# A stall gets ONE nudge typed into the lane (OSRC_AUTONUDGE=0: none; the stall then wakes the
# orchestrator with the nudge as NEXT), logged as an informational `nudged` row. Still stalled
# OSRC_STALL_MIN after it: EVENT stalled plus a Mission Control needs-you row. A lane that worked after
# its nudge and stalls again gets a fresh nudge, up to OSRC_NUDGE_MAX (3) before a stall escalates at
# once. A lane at a question or an approval is never nudged.

_sv_stall_secs() { printf '%s' $(( $(_sv_num "${OSRC_STALL_MIN:-}" 5) * 60 )); }

# Reminder interval per kind: the prompt-like kinds re-report every 5 minutes, the rest every 20.
# OSRC_SUPERVISE_REMIND (minutes) overrides every kind; an observation may set SV_RM (seconds) instead.
_sv_remind_secs() { # <kind>
  if [ -n "${OSRC_SUPERVISE_REMIND:-}" ]; then printf '%s' $(( $(_sv_num "$OSRC_SUPERVISE_REMIND" 5) * 60 )); return 0; fi
  case "$1" in idle|stalled|question|approval|approval-not-landed) printf 300 ;; *) printf 1200 ;; esac
}

# ---- what an idle lane's last words say ---------------------------------------------------------------
# Read from the last prose lines of the history region (never the composer, so the orchestrator's own
# typed text is not evidence); the turn-summary line is skipped.
_SV_PROMISE_RE='((after|once|when) (it|that|this|they|the [^.;]{1,60}) (reports|report|finishes|finish|completes|complete|is done|are done|returns|lands|exits|comes back)|(waiting|wait) (for|on) (it|that|this|the [^.;]{1,40}) to (finish|report|complete|return))'
_SV_PERSON_RE='(^|[^[:alnum:]])(you|your|go-ahead|go ahead|approval|approve|review|reviewer|reviewed|orchestrator|decision|decide|sign-off|confirm|confirmation)([^[:alnum:]]|$)'
_sv_last_words() { # -> the last 3 prose lines of the history region
  _sv_history_tail 8 | grep -v '^[[:space:]]*$' | grep -Ev '^[[:space:]]*[^[:alnum:][:space:]]{1,3}[[:space:]]+[A-Z][a-z]+ for [0-9]' | tail -3
}
# _sv_idle_words -> "promise<TAB>line" | "person<TAB>line" | rc 1. Waiting on a person wins.
_sv_idle_words() {
  local w line
  w="$(_sv_last_words)"; [ -n "$w" ] || return 1
  line="$(printf '%s\n' "$w" | grep -Ei "$_SV_PROMISE_RE" | tail -1)"
  if printf '%s\n' "$w" | grep -Eiq "$_SV_PERSON_RE"; then
    line="$(printf '%s\n' "$w" | grep -Ei "$_SV_PERSON_RE" | tail -1)"
    printf 'person\t%s' "$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//' | cut -c1-120)"; return 0
  fi
  [ -n "$line" ] || return 1
  printf 'promise\t%s' "$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//' | cut -c1-120)"
}

# ---- nudge ----------------------------------------------------------------------------------------
_SV_NUDGE_BG='You are idle while waiting on a background task. Check its output now; if it hung, kill it and rerun in the foreground, then continue your brief.'
_SV_NUDGE_QUIET='You have been idle with no hand-in for a while. If your brief is finished, write its hand-in now; if you are waiting on something, check it now; otherwise continue your brief.'
_sv_nudge_text() { case "$1" in quiet) printf '%s' "$_SV_NUDGE_QUIET" ;; *) printf '%s' "$_SV_NUDGE_BG" ;; esac; }
_sv_nudge_cmd() { # <id> <why> -> the shell command that nudges (a NEXT)
  printf 'OUTSOURCERER_TMUX=%s %s session send %q' "$1" "$SCRIPT_PATH" "$(_sv_nudge_text "$2")"
}
_sv_nudge_send() { # <id> <why>: through session send, which refuses to type into a menu and verifies
  # the text was submitted. OSRC_NUDGE_SEND_CMD (tests) receives <id> <text> instead.
  if [ -n "${OSRC_NUDGE_SEND_CMD:-}" ]; then "$OSRC_NUDGE_SEND_CMD" "$1" "$(_sv_nudge_text "$2")" >/dev/null 2>&1; return; fi
  OUTSOURCERER_TMUX="$1" OSRC_STREAM=1 "$SCRIPT_PATH" session send "$(_sv_nudge_text "$2")" >/dev/null 2>&1
}
_sv_is_reviewer() { # <id>: the queue's reviewer sits idle between items by design
  type _osrc_review_reviewer >/dev/null 2>&1 && [ "$(_osrc_review_reviewer 2>/dev/null)" = "$1" ]
}

# Mission Control needs-you rows: lanes/needs/<id> = "<kind>\t<since>\t<detail>".
_sv_needs_set() { # <id> <kind> <since> <detail>
  local d; d="$(_sv_lanes)/needs"; mkdir -p "$d" 2>/dev/null || return 0
  printf '%s\t%s\t%s\n' "$2" "$3" "$(printf '%s' "$4" | tr '\t\n' '  ' | cut -c1-200)" > "$d/$1.tmp.$$" && mv -f "$d/$1.tmp.$$" "$d/$1"
}
_sv_needs_clear() { rm -f "$(_sv_lanes)/needs/$1" 2>/dev/null; return 0; }

# state/<id>.nudge = "<ts> <why> <sent|failed> <worked-after 0|1> <nudges this run>"
_sv_nudge_read() { # <id> -> sets NG_TS NG_WHY NG_ST NG_OK NG_N (NG_TS empty: no record)
  NG_TS=""; NG_WHY=""; NG_ST=""; NG_OK=0; NG_N=0
  local f; f="$(_sv_lanes)/state/$1.nudge"
  [ -f "$f" ] && read -r NG_TS NG_WHY NG_ST NG_OK NG_N 2>/dev/null < "$f"
  NG_OK="$(_sv_num "$NG_OK" 0)"; NG_N="$(_sv_num "$NG_N" 0)"
  [ -n "$NG_TS" ] && NG_TS="$(_sv_num "$NG_TS" 0)"
  return 0
}
_sv_nudge_write() { # <id> <ts> <why> <status> <worked> <n>
  local f; f="$(_sv_lanes)/state/$1.nudge"; mkdir -p "${f%/*}" 2>/dev/null
  printf '%s %s %s %s %s\n' "$2" "$3" "$4" "$5" "$6" > "$f"
}

# A real working read (spinner, not idle-with-shell). NG_OK: 0 = no work seen since the nudge,
# 1 = obeyed, any larger value = epoch of the first working read after it. A nudge counts as obeyed
# only after OSRC_OBEY_SECS (default 90) of work, so a lane that answers "still running" and goes
# idle again is not reset. Two windows of work after the nudge end the run of nudges entirely.
_sv_obey_secs() { _sv_num "${OSRC_OBEY_SECS:-90}" 90; }
_sv_stall_working() { # <id> <now>
  _sv_needs_clear "$1"
  _sv_nudge_read "$1"; [ -n "$NG_TS" ] || return 0
  if [ $(( $2 - NG_TS )) -ge $(( 2 * $(_sv_stall_secs) )) ]; then rm -f "$(_sv_lanes)/state/$1.nudge"; return 0; fi
  [ "$2" -gt "$NG_TS" ] || return 0
  if [ "$NG_OK" = 0 ]; then _sv_nudge_write "$1" "$NG_TS" "$NG_WHY" "$NG_ST" "$2" "$NG_N"
  elif [ "$NG_OK" != 1 ] && [ $(( $2 - NG_OK )) -ge "$(_sv_obey_secs)" ]; then _sv_nudge_write "$1" "$NG_TS" "$NG_WHY" "$NG_ST" 1 "$NG_N"
  fi
  return 0
}
_sv_stall_reset() { rm -f "$(_sv_lanes)/state/$1.nudge" 2>/dev/null; _sv_needs_clear "$1"; }

# _sv_stall_observe <id> <now> <why: bgshell|promise|quiet> <evidence> [src] [owner]
# Called by _sv_observe with SVS_* loaded. rc 0 = a stall (SV_K/SV_D/SV_NX/SV_H set, or a nudge sent and
# logged as `nudged`); rc 1 = not (yet) a stall, caller keeps its own reading.
_sv_stall_observe() {
  local id="$1" now="$2" why="$3" ev="$4" src="${5:-supervise}" owner="${6:-}" win age what max
  win="$(_sv_stall_secs)"; age=$(( now - SVS_CHANGED )); max="$(_sv_num "${OSRC_NUDGE_MAX:-}" 3)"
  case "$why" in bgshell|quiet) [ "$age" -ge "$win" ] || return 1 ;; esac
  [ "$why" = quiet ] && _sv_is_reviewer "$id" && return 1
  case "$why" in
    bgshell) what="idle $(( age / 60 ))m while its background shell still runs ($ev)" ;;
    promise) what="idle after promising to continue later, with nothing running to wake it: \"$ev\"" ;;
    *)       what="idle $(( age / 60 ))m with no hand-in and no change on screen" ;;
  esac
  SV_OUT=1
  _sv_nudge_read "$id"
  # A nudge the lane worked after is spent: this is a new stall, with its own nudge. Work too short
  # to count as obeyed leaves the nudge unspent, so this stall escalates on schedule.
  [ -n "$NG_TS" ] && [ "$NG_OK" = 1 ] && NG_TS=""
  if [ -n "$NG_TS" ] && [ "$NG_OK" -gt 1 ]; then _sv_nudge_write "$id" "$NG_TS" "$NG_WHY" "$NG_ST" 0 "$NG_N"; NG_OK=0; fi
  if [ -z "$NG_TS" ]; then
    if [ "${OSRC_AUTONUDGE:-1}" = 0 ] || [ "$NG_N" -ge "$max" ]; then
      SV_K=stalled; SV_NX="$(_sv_nudge_cmd "$id" "$why")"
      if [ "$NG_N" -ge "$max" ] && [ "${OSRC_AUTONUDGE:-1}" != 0 ]; then SV_D="$what (stalled again after $NG_N autonudges)"; else SV_D="$what"; fi
      SV_H="$(printf 'stall:%s:%s' "$why" "$SVS_HASH" | cksum | awk '{print $1}')"
      _sv_needs_set "$id" stalled "$SVS_CHANGED" "$SV_D"
      return 0
    fi
    if _sv_nudge_send "$id" "$why"; then
      _sv_nudge_write "$id" "$now" "$why" sent 0 $(( NG_N + 1 ))
      _sv_append nudged "$id" "autonudged: $what" "OUTSOURCERER_TMUX=$id $SCRIPT_PATH session read" "$src" "$owner"
      SV_PEND=1; return 0
    fi
    # The nudge could not be typed: nobody else will move this lane, so wake the orchestrator now.
    _sv_nudge_write "$id" "$now" "$why" failed 0 $(( NG_N + 1 ))
    SV_K=stalled; SV_D="$what (the autonudge could not be sent)"; SV_NX="$(_sv_nudge_cmd "$id" "$why")"
    SV_H="$(printf 'escalate:%s' "$now" | cksum | awk '{print $1}')"
    _sv_needs_set "$id" stalled "$SVS_CHANGED" "$SV_D"
    return 0
  fi
  if [ $(( now - NG_TS )) -lt "$win" ]; then SV_PEND=1; return 0; fi
  SV_K=stalled
  if [ "$NG_ST" = sent ]; then SV_D="still stalled $(( (now - NG_TS) / 60 ))m after one autonudge: $what"
  else SV_D="still stalled $(( (now - NG_TS) / 60 ))m; the autonudge could not be sent: $what"; SV_NX="$(_sv_nudge_cmd "$id" "$why")"; fi
  SV_H="$(printf 'escalate:%s' "$NG_TS" | cksum | awk '{print $1}')"   # one escalation per nudge, then reminders
  [ -n "$SV_NX" ] || SV_NX="OUTSOURCERER_TMUX=$id $SCRIPT_PATH session read"
  _sv_needs_set "$id" stalled "$NG_TS" "$SV_D"
  return 0
}

# ---- age of an unresolved event --------------------------------------------------------------------
# state/<id>.first holds "<key> <first-seen>" lines (newest 8): when each event (kind+hash) was first
# reported, so a reminder says how long it has waited even after another kind was reported between.
_sv_first_seen() { # <id> <key> <now> -> epoch the key was first reported (records it when new)
  local f t; f="$(_sv_lanes)/state/$1.first"
  t="$(awk -v k="$2" '$1 == k { print $2; exit }' "$f" 2>/dev/null)"
  if [ -n "$t" ]; then _sv_num "$t" "$3"; return 0; fi
  mkdir -p "${f%/*}" 2>/dev/null
  { tail -7 "$f" 2>/dev/null; printf '%s %s\n' "$2" "$3"; } > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
  printf '%s' "$3"
}

# ---- approval keystrokes that did not land ---------------------------------------------------------
# Every outsourcerer path that types an answer into a prompt notes it: state/<id>.keysent =
# "<ts>\t<screen hash>\t<who>". If the same prompt screen is still open OSRC_NOT_LANDED_SECS (default 5)
# later, supervise reports approval-not-landed once, so the answer is retried instead of assumed.
# Same capture path and normalization as _sv_observe's screen hash, so the two compare.
_sv_screen_hash() { _sv_pane_text "$1" "${2:-$(_osrc_screen_capture "$1" 2>/dev/null)}" | cksum | awk '{print $1}'; }
osrc_keys_sent() { # <pane> <who> [screen hash taken before the keys]
  local f; f="$(_sv_lanes)/state/$1.keysent"; mkdir -p "${f%/*}" 2>/dev/null || return 0
  printf '%s\t%s\t%s\n' "$(_sv_now)" "${3:-$(_sv_screen_hash "$1")}" "$2" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}
osrc_keys_landed() { rm -f "$(_sv_lanes)/state/$1.keysent" 2>/dev/null; return 0; }
_sv_not_landed() { # <id> <now> <screen-hash> -> 0 + detail when a sent answer left this prompt open
  local f ts h who; f="$(_sv_lanes)/state/$1.keysent"
  [ -f "$f" ] || return 1
  IFS="$(printf '\t')" read -r ts h who 2>/dev/null < "$f"; ts="$(_sv_num "$ts" 0)"
  [ $(( $2 - ts )) -ge "$(_sv_num "${OSRC_NOT_LANDED_SECS:-}" 5)" ] || return 1
  rm -f "$f"
  [ "$h" = "$3" ] || return 1   # the screen moved: the answer landed (a new prompt is its own event)
  printf 'an answer was sent %ss ago (%s) but the same prompt is still open: retry it' "$(( $2 - ts ))" "${who:-unknown}"
}
# The answering command saw its own keystroke fail: log and print the event now (and clear the note,
# so supervise does not report the same miss a second time).
osrc_not_landed_emit() { # <pane> <who>
  local id="$1" now d o next owners=""
  now="$(_sv_now)"; d="the prompt is still open after $2 sent its answer: retry it"
  next="OUTSOURCERER_TMUX=$id $SCRIPT_PATH session answer"
  rm -f "$(_sv_lanes)/state/$id.keysent" 2>/dev/null
  for o in "$OSRC_HOME"/owners/*/"$id"; do [ -e "$o" ] && owners="$owners $(basename "$(dirname "$o")")"; done
  if [ -z "$owners" ]; then _sv_append approval-not-landed "$id" "$d" "$next" answer
  else for o in $owners; do _sv_append approval-not-landed "$id" "$d" "$next" answer "$o"; done; fi
  printf 'EVENT approval-not-landed %s %s %s\nNEXT %s\n' "$id" "$now" "$d" "$next"
}

# ---- watcher liveness -------------------------------------------------------------------------------
# ONE answer to "is this session watched", for the stop guard, Mission Control and the per-command
# warning: a live, polling supervise covering everything (`*`), or the standing watcher (lib/watchsvc.sh)
# while it ticks and can wake the session. A supervise naming explicit ids covers only those ids.
osrc_session_watched() { # <sid>
  _sv_armed_cover "$1" 2>/dev/null | grep -qxF '*' && return 0
  type _ws_covers >/dev/null 2>&1 && _ws_covers "$1"
}
# supervise stamps supervise/<key>/alive every poll. A session that owns live lanes nobody watches
# (osrc_session_watched) for more than OSRC_WATCHER_GRACE seconds (default 120) is unwatched.
osrc_watcher_alive() { printf '%s\n' "${2:-$(_sv_now)}" > "$1/alive" 2>/dev/null; return 0; }
osrc_watcher_gap() { # <sid> [now] -> minutes unwatched + live lane count; rc 1 when watched or nothing live
  local sid="$1" now="${2:-$(_sv_now)}" d f last=0 start=0 m live=0 t cover
  case "$sid" in ''|.*|*/*) return 1 ;; esac
  d="$OSRC_HOME/owners/$sid"; [ -d "$d" ] || return 1
  osrc_session_watched "$sid" && return 1
  last="$(_sv_num "$(cat "$OSRC_HOME/supervise/$sid/alive" 2>/dev/null)" 0)"
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in .*|watch.*) continue ;; esac
    m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)"; m="$(_sv_num "$m" 0)"
    { [ "$start" = 0 ] || [ "$m" -lt "$start" ]; } && start="$m"
  done
  [ "$start" -gt 0 ] || return 1
  [ "$last" -gt "$start" ] && start="$last"
  [ $(( now - start )) -gt "$(_sv_num "${OSRC_WATCHER_GRACE:-}" 120)" ] || return 1
  cover="$(_sv_armed_cover "$sid" 2>/dev/null)"
  for f in "$d"/*; do
    [ -f "$f" ] || continue; t="${f##*/}"
    case "$t" in .*|watch.*) continue ;; esac
    printf '%s\n' "$cover" | grep -qxF "$t" && continue   # an explicit supervise covers this one
    case "$(_owned_live_state "$t" 2>/dev/null)" in live|waiting) live=$((live + 1)) ;; esac
  done
  [ "$live" -gt 0 ] || return 1
  printf '%s %s\n' $(( (now - start) / 60 )) "$live"
}
osrc_watcher_warn() { # [sid]: one stderr line when this session's lanes have nobody watching
  local sid="${1:-}" g
  [ -n "$sid" ] || sid="$(_owner_sid 2>/dev/null)"
  g="$(osrc_watcher_gap "$sid")" || return 0
  printf '[outsourcerer] no watcher for %sm: %s live lane(s) owned by this session and no supervise armed. Run as a background command: %s supervise --session %s\n' \
    "${g%% *}" "${g##* }" "$SCRIPT_PATH" "$sid" >&2
}
