# shellcheck shell=bash
# lib/supervise.sh: ONE blocking waiter for everything an orchestrator owns.
#
#   outsourcerer.sh supervise [--session SID | --all] [--loop] [--watch DIR|FILE ...] [id ...]
#   outsourcerer.sh supervise --unwatch DIR|FILE
#
# Blocks until something the current Claude Code session owns ($OSRC_HOME/owners/<sid>/, or the
# explicit ids) needs the orchestrator, then prints, per CONTRACT.md, one pair per target:
#   EVENT <kind> <target-id> <unix-ts> <one-line detail>
#   NEXT <exact shell command to run>
# and exits 0. Kinds, highest priority first: approval question failed limit done idle stalled
# unreviewed drift (plus watcher-lost/approved passed through from other modules).
#
# Durable, replayable: every observation that is an event is appended to the append-only
# $OSRC_HOME/lanes/events.jsonl (by supervise itself and by the heartbeat beacon on each tick).
# Each orchestrator keeps a byte cursor under $OSRC_HOME/supervise/<sid>/cursor, so a supervise
# re-armed after hours (compaction, restart, a reaped background shell) returns AT ONCE with
# everything that happened while nobody was waiting. With the beacon down, supervise polls itself.
#
# Dedupe: observe+emit of a target runs under a per-target lock, and every printed row goes into a
# per-orchestrator delivered ledger so no second supervise prints it again (lib/supervise_dedupe.sh).
# Per target, the last event's kind+screen hash is kept in $OSRC_HOME/lanes/state/<id>; the
# same unresolved event is appended again only after its reminder interval (5 min for idle/stalled/
# question/approval, 20 for the rest, OSRC_SUPERVISE_REMIND for all; lib/stall.sh), so
# a skipped event cannot sleep forever. Batching: after the first new event, supervise keeps polling
# for OSRC_SUPERVISE_SETTLE seconds (default 20) so near-simultaneous events land in one wake.
# No owned live work -> `EVENT done all`. Any internal error -> `EVENT failed supervise`, exit 2.
# --watch: hand-in files (*.DONE, *VERDICT*, *QUESTION*) keyed on name+mtime+size+hash, so a lane
# rewriting the same DONE file fires again (lib/supervise_watch.sh).
# --loop (with a session; for wrapper scripts reading stdout, NEVER an agent's background task) arms again
# after each delivered batch. A waiter only for OSRC_SUPERVISE_HUNG s after a batch went to a pipe/terminal.
# Into a file nobody reads it runs once, like plain supervise, so its exit still wakes the agent.
#
# Screen reading is NOT done here: osrc_screen_state (lib/screen.sh) classifies a pane. Until it
# lands, a thin wrapper over the existing detectors stands in (defined only if it is missing).

_SV_SELF="${BASH_SOURCE[0]}"
_sv_num() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
_sv_lanes() { printf '%s/lanes' "$OSRC_HOME"; }
_sv_now() { if [ -n "${OSRC_NOW:-}" ]; then printf '%s' "$OSRC_NOW"; else date +%s; fi; }   # OSRC_NOW pins the clock (tests)

# ---- reading a target --------------------------------------------------------------------------
# Screen classification lives in lib/screen.sh (osrc_screen_state / _osrc_screen_analyze_text). This
# module only adds the session facts, read from the screen reader's history region (the lines above the composer,
# so text the orchestrator typed into the composer is never evidence): plan limits, API/login errors,
# the done contract, and the Claude transcript.

_sv_cc_busy_re() { printf '%s' '^[[:space:]]*[^[:alnum:][:space:]]{1,4}[[:space:]]+[A-Z][^[:space:]]*…'; }

# Normalized screen text for change detection: no ANSI, no digits (timers, token counts), no spinner
# glyphs, and no busy line (Claude Code rotates its spinner verb while a tool runs).
_sv_pane_text() { # <pane> [capture]
  { if [ -n "${2:-}" ]; then printf '%s\n' "$2"; else tmux capture-pane -p -t "$1" 2>/dev/null; fi; } | _managed_strip_ansi \
    | grep -Ev 'esc to interrupt|ctrl\+c to interrupt|esc to cancel' | grep -Ev "$(_sv_cc_busy_re)" \
    | sed -E 's/(⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|✻|✶|✳|✢|✽|·|●|◐|◓|◑|◒)//g' | tr -d '0-9'
}

_sv_plan_limit_re() {
  printf '%s|%s|%s|%s|%s|%s|%s' "${_CX_PLAN_LIMIT_RE:-x^}" "${_CC_PLAN_LIMIT_RE:-x^}" "${_CURSOR_PLAN_LIMIT_RE:-x^}" \
    "${_WARP_PLAN_LIMIT_RE:-x^}" "${_DROID_PLAN_LIMIT_RE:-x^}" "${_CLINE_PLAN_LIMIT_RE:-x^}" "${_AGY_PLAN_LIMIT_RE:-x^}"
}
# A reviewer sat 55 min on "Please run /login · API Error: 403 ... Cloudflare".
# The BANNER, not words (bare phrases matched a delegate's own question and a "Done"
# summary, and supervise typed `continue` into them). Only the LAST history line counts, and only in
# the shape the CLI prints it: Claude Code's `⎿` result line carrying `API Error: <code>` or
# `Please run /login`; other engines: a line that STARTS with one of those (after at most a glyph).
# A TOOL RESULT has the same `⎿` shape (`⏺ Bash(tail -1 app.log)` then
# `⎿  API Error: 502 ...` is the log's text), so a line whose previous non-blank line is a tool-call
# header (`⏺ Name(`) is never a banner.
_sv_api_banner() { # <engine> <line> [line-above] -> 0 when <line> is an API/login error banner
  local re
  printf '%s\n' "${3:-}" | grep -Eq '^[[:space:]]*⏺[[:space:]]+[A-Za-z_][A-Za-z0-9_.:-]*\(' && return 1
  case "$1" in
    cc) re='^[[:space:]]*⎿[[:space:]]+(.*[[:space:]·])?(API Error: [0-9]{3}|Please run /login)' ;;
    *)  re='^[[:space:]]*([^[:alnum:][:space:]]{1,3}[[:space:]]+)?(API Error: [0-9]{3}|Please run /login)' ;;
  esac
  printf '%s\n' "$2" | grep -Eq "$re"
}

# The last N lines of the screen reader's history region (needs _osrc_screen_analyze_text to have run in this shell).
_sv_history_tail() { # [n]
  local n="${1:-${OSRC_SUPERVISE_HISTORY_TAIL:-6}}" end i
  end="${OSRC_SCR_HIST_END:--1}"; [ "$end" -ge 0 ] 2>/dev/null || end=$(( ${_SCR_N:-0} - 1 ))
  i=$(( end - n + 1 )); [ "$i" -ge 0 ] || i=0
  while [ "$i" -le "$end" ]; do printf '%s\n' "${_SCR_L[$i]}"; i=$((i + 1)); done
}

# agy parks on its own plan timer: "⚠ Individual quota reached ... Resets in 1h13m1s", or a bare
# retry/backoff countdown. Both are a limit (the lane cannot take a turn until the clock fires),
# never "unrecognised". The detail names the model the footer shows and carries the reset two ways:
# a clock for the person reading, an epoch for anything parsing the event. Needs the analyze
# globals (_SCR_L, OSRC_SCR_HIST_END); reads the last 10 history lines for the banner and the whole
# capture for the model name. -> "<Model> quota reached, resets HH:MM (epoch N)" | rc1
_sv_agy_limit() {
  local hist line kind model="" phrase="" secs="" ep="" clock="" i
  hist="$(_sv_history_tail 10)"
  line="$(printf '%s\n' "$hist" | grep -Ei "${_AGY_PLAN_LIMIT_RE:-individual[[:space:]]+quota[[:space:]]+(reached|exceeded|exhausted)}" | tail -1)"
  if [ -n "$line" ]; then kind=quota
  else
    line="$(printf '%s\n' "$hist" | grep -Ei 'resets?[[:space:]]+in[[:space:]]+[0-9]+[smhd]|(retr(y|ying)|back ?off|rate[ -]?limited)[^.]{0,40}in[[:space:]]+[0-9]+[smh]' | tail -1)"
    [ -n "$line" ] || return 1; kind=backoff
  fi
  i=0
  while [ "$i" -lt "$_SCR_N" ]; do
    case "${_SCR_L[$i]}" in *"Gemini 4 "*) model="$(printf '%s\n' "${_SCR_L[$i]}" | grep -oE 'Gemini 4 [A-Z][a-z]+' | head -1 | awk '{print $3}')" ;; esac
    i=$((i + 1))
  done
  [ -n "$model" ] || model=Antigravity
  phrase="$(printf '%s\n' "$hist" | grep -oiE '(resets?|retr(y|ying)|back ?off)[[:space:]]+in[[:space:]]+[0-9][0-9smhd :]*' | head -1 \
    | sed -E 's/^.*[[:space:]]+in[[:space:]]+/resets in /i')"
  [ -n "$phrase" ] && secs="$(_lane_limit_reset_secs "$phrase" 2>/dev/null)"
  case "$secs" in ''|*[!0-9]*) ep="" ;; *) ep=$(( $(_sv_now) + secs )); clock="$(date -r "$ep" '+%H:%M' 2>/dev/null || date -d "@$ep" '+%H:%M' 2>/dev/null)" ;; esac
  line="$(printf '%s' "$line" | tr -s ' ' | cut -c1-100)"
  if [ "$kind" = backoff ]; then
    if [ -n "$ep" ]; then printf '%s waiting on its own timer, next try %s (epoch %s)' "$model" "$clock" "$ep"
    else printf '%s waiting on its own timer: %s' "$model" "$line"; fi
  else
    if [ -n "$ep" ]; then printf '%s quota reached, resets %s (epoch %s)' "$model" "$clock" "$ep"
    else printf '%s quota reached: %s' "$model" "$line"; fi
  fi
}

_sv_cc_transcript() { # <session-id>
  local rec ccid cwd cache; cache="$(_sv_lanes)/state/$1.cc"
  [ -s "$cache" ] && { cat "$cache"; return 0; }
  [ -e "$cache" ] && [ $(( $(_sv_now) - $(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null || echo 0) )) -lt 120 ] && return 1
  # One grep + one jq: _state_jsonl_read spawns a jq per registry line, and this runs per pane per poll.
  [ -f "$OSRC_SESSION_REGISTRY" ] || return 1
  rec="$(grep -F "\"$1\"" "$OSRC_SESSION_REGISTRY" 2>/dev/null | grep -F cc_session_id | jq -r --arg id "$1" 'select(.session_id==$id and (.cc_session_id // "") != "") | .cc_session_id + "\t" + (.cwd // "")' 2>/dev/null | tail -1)"
  ccid="${rec%%	*}"; cwd="${rec#*	}"; [ "$rec" != "$ccid" ] || cwd=""
  mkdir -p "$(_sv_lanes)/state" 2>/dev/null
  [ -n "$ccid" ] && [ -n "$cwd" ] || { : > "$cache" 2>/dev/null; return 1; }   # negative cache, 2 min
  printf '%s\t%s\n' "$ccid" "$cwd" | tee "$cache" 2>/dev/null
}

# 0 when the session's last finished assistant turn asks the user something (prose question,
# AskUserQuestion, or a permission request). Transcript, not screen: wrapped text cannot fool it.
_sv_transcript_question() { # <session-id>
  local pair ccid cwd path text
  pair="$(_sv_cc_transcript "$1")" || return 1
  ccid="${pair%%	*}"; cwd="${pair#*	}"
  _fleet_transcript_waiting "$ccid" "$cwd" && return 0
  path="$(_fleet_transcript_path "$ccid" "$cwd")"; [ -f "$path" ] || return 1
  text="$(tail -n 60 "$path" 2>/dev/null | jq -rs '
    def role: .message.role? // .role? // "";
    map(select(type=="object" and (role=="assistant" or role=="user"))) | last // {}
    | select(role=="assistant") | (.message.content? // .content? // "")
    | if type=="string" then . else ([.[]? | select(.type?=="text") | .text] | join("\n")) end' 2>/dev/null)"
  [ -n "$text" ] || return 1
  text="$(printf '%s\n' "$text" | grep -v '^[[:space:]]*$' | tail -3)"
  printf '%s' "$text" | tail -1 | grep -Eq '\?[[:space:]*_)"]*$' && return 0
  printf '%s' "$text" | grep -Eiq '(should I|shall I|do you want|would you like|want me to|let me know (if|whether|which|how)|please confirm|waiting for your|your call|which (one|option) (do|should|would))'
}

# _sv_target_screen <session-id> [capture] -> state \n evidence. the screen reader plus, in this order:
#   a quiet pane whose done contract holds (osrc_done_state) -> done, even if it closed politely
#     with a question ("Done. Want me to also update the docs?" is done). This also wins over a
#     composer holding unsent text: a finished lane's lost send is not worth a wake.
#   a cc session whose last turn asks something (transcript or screen) -> question
#   the LAST history line is an API/login error banner -> failed
#   plan-limit banner in the history tail -> limit (never idle)
_sv_target_screen() {
  local id="$1" cap="${2:-}" eng st ev hist hit q=""
  if [ -z "$cap" ]; then cap="$(_osrc_screen_capture "$id")" || { printf 'unknown\npane capture failed\n'; return 0; }; fi
  eng="$(_osrc_screen_engine_of "$id" 2>/dev/null)"
  _osrc_screen_analyze_text "$eng" <<<"$cap"
  st="${OSRC_SCR_STATE:-unknown}"; ev="$(printf '%s' "${OSRC_SCR_EVIDENCE:-}" | tr '\n' ' ' | cut -c1-160)"
  case "$st" in approval|working) printf '%s\n%s\n' "$st" "$ev"; return 0 ;; esac
  # agy parked on its own quota timer / retry backoff is a limit, whatever shape the composer
  # gives the screen — it must never reach the "no turn yet" shortcut or the unknown tail.
  if [ "${OSRC_SCR_ENGINE:-$eng}" = agy ] && hit="$(_sv_agy_limit)"; then printf 'limit\n%s\n' "$hit"; return 0; fi
  case "$st:$ev" in composer:*"no turn yet"*) printf 'composer\n%s\n' "$ev"; return 0 ;; esac
  # A lane that asked something, or whose done contract holds, is never `failed`, whatever its
  # text mentions: those checks come first.
  [ "$st" = question ] && q="$ev"
  if [ -z "$q" ] && _sv_transcript_question "$id"; then q="last assistant turn asks for an answer (transcript)"; fi
  if type -t osrc_done_state >/dev/null 2>&1; then
    case "$st" in idle|question|composer)
      if [ "$(osrc_done_state "$id" 2>/dev/null)" = done ]; then
        printf 'done\ndone contract holds%s\n' "${q:+; it also asked: $q}"; return 0
      fi ;;
    esac
  fi
  [ -n "$q" ] && { printf 'question\n%s\n' "$q"; return 0; }
  # Turn ended but its own background shell still runs: Claude Code wakes it when the shell exits.
  if [ "$st" = idle ] && hit="$(_sv_bg_shell)"; then printf 'working\nbackground shell still running: %s\n' "$hit"; return 0; fi
  # What an idle lane's last words wait on: a promise to continue when something finishes (a stall if
  # nothing runs), or a person (plain idle). lib/stall.sh _sv_idle_words.
  if [ "$st" = idle ] && type _sv_idle_words >/dev/null 2>&1 && hit="$(_sv_idle_words)"; then
    case "$hit" in promise*) ev="promises to continue later: ${hit#*	}" ;; person*) ev="waits for a person: ${hit#*	}" ;; esac
  fi
  hist="$(_sv_history_tail)"
  hit="$(printf '%s\n' "$hist" | tail -1)"
  if _sv_api_banner "${OSRC_SCR_ENGINE:-$eng}" "$hit" "$(printf '%s\n' "$hist" | sed '$d' | grep -v '^[[:space:]]*$' | tail -1)"; then printf 'failed\napi-error: %s\n' "$(printf '%s' "$hit" | cut -c1-160)"; return 0; fi
  hit="$(printf '%s\n' "$hist" | grep -Ei "$(_sv_plan_limit_re)" | tail -1 | cut -c1-160)"
  [ -z "$hit" ] || { printf 'limit\n%s\n' "$hit"; return 0; }
  # A watched hand-in file named for this lane (out/<lane>.DONE) is a done marker, checked last: a
  # running shell, an error banner, a limit or a question each outrank a file, which may be the
  # previous round's (_sv_handin_file only counts one newer than the latest working stretch).
  case "$st" in idle|composer)
    if hit="$(_sv_handin_file "$id")"; then
      if _sv_handin_moved_on "$id" "$(_sv_fp "$hit")" "$(_sv_pane_text "$id" "$cap" | cksum | awk '{print $1}')"; then
        ev="$ev (screen changed since $(basename "$hit") was reported; no new hand-in)"
      else printf 'done\nhand-in %s written\n' "$(basename "$hit")"; return 0; fi
    fi ;;
  esac
  printf '%s\n%s\n' "$st" "$ev"
}

# Fleet-row state for a managed pane: managed rows used to be hardcoded "unknown".
_sv_fleet_state() { # <endpoint> -> state<US>evidence
  local pane st ev out
  case "$1" in tmux:?*) pane="${1#tmux:}" ;; *) printf 'unknown\037managed registry'; return 0 ;; esac
  have tmux || { printf 'unknown\037managed registry'; return 0; }
  out="$(_sv_target_screen "$pane" 2>/dev/null)"
  st="$(printf '%s\n' "$out" | head -1)"; ev="$(printf '%s\n' "$out" | sed -n 2p | tr -d '\037')"
  case "$st" in
    approval|question) printf 'blocked?\037%s: %s' "$st" "$ev" ;;
    limit) printf 'blocked?\037plan limit: %s' "$ev" ;;
    failed) printf 'blocked?\037%s' "$ev" ;;
    working) printf 'working\037%s' "$ev" ;;
    done) printf 'completed\037%s' "$ev" ;;
    idle|composer) printf 'idle\037%s' "$ev" ;;
    *) printf 'unknown\037%s' "${ev:-managed pane unrecognised}" ;;
  esac
}

# ---- per-target state ------------------------------------------------------------------------------
# $OSRC_HOME/lanes/state/<id>: hash changed_at cand_kind cand_hash cand_since last_key last_ts
_sv_state_read() { # <id> -> sets SVS_* globals
  SVS_HASH=-; SVS_CHANGED=0; SVS_CK=-; SVS_CH=-; SVS_CS=0; SVS_LK=-; SVS_LT=0
  local f; f="$(_sv_lanes)/state/$1"
  [ -f "$f" ] && read -r SVS_HASH SVS_CHANGED SVS_CK SVS_CH SVS_CS SVS_LK SVS_LT 2>/dev/null < "$f"
  SVS_CHANGED="$(_sv_num "$SVS_CHANGED" 0)"; SVS_CS="$(_sv_num "$SVS_CS" 0)"; SVS_LT="$(_sv_num "$SVS_LT" 0)"
  return 0
}
_sv_state_write() { # <id>
  local d; d="$(_sv_lanes)/state"; mkdir -p "$d" 2>/dev/null || return 1
  printf '%s %s %s %s %s %s %s\n' "${SVS_HASH:--}" "$SVS_CHANGED" "${SVS_CK:--}" "${SVS_CH:--}" "$SVS_CS" "${SVS_LK:--}" "$SVS_LT" > "$d/$1.tmp.$$" \
    && mv -f "$d/$1.tmp.$$" "$d/$1"
}

# A quiet state (idle/question/composer/unknown) counts only when seen with the same screen on two
# polls at least OSRC_SUPERVISE_CONFIRM seconds apart: a busy Codex pane flickers through an
# idle-looking frame between tool calls (FINDINGS 8). Returns 0 once confirmed.
_sv_confirm() { # <kind> <hash> <now>
  local need; need="$(_sv_num "${OSRC_SUPERVISE_CONFIRM:-}" 20)"
  if [ "$SVS_CK" = "$1" ] && [ "$SVS_CH" = "$2" ]; then
    [ $(( $3 - SVS_CS )) -ge "$need" ]; return
  fi
  SVS_CK="$1"; SVS_CH="$2"; SVS_CS="$3"; return 1
}

_sv_fixture_drop() { # <pane> <why>: an unrecognised screen becomes a fixture for the classifier
  local d f; d="$OSRC_HOME/fixtures-inbox"; mkdir -p "$d" 2>/dev/null || return 0
  f="$d/$(printf '%s' "$1" | tr -cd 'A-Za-z0-9._-')-$(date +%s).txt"
  { printf '# %s\n' "$2"; tmux capture-pane -e -p -t "$1" 2>/dev/null; } > "$f" 2>/dev/null
  ls -1t "$d" 2>/dev/null | tail -n +51 | while IFS= read -r old; do rm -f "$d/$old"; done
}

# `wait` on a session whose pane stays unrecognised used to loop forever. 0 = persistent unknown.
_sv_unknown_persistent() { # <session-id>
  local id="$1" now h rc=1
  now="$(_sv_now)"; h="$(_sv_pane_text "$id" | cksum | awk '{print $1}')"
  _sv_state_read "$id"
  if _sv_confirm unknown "$h" "$now"; then rc=0; _sv_fixture_drop "$id" "wait: persistent unknown"; fi
  _sv_state_write "$id"; return "$rc"
}

# ---- observe one target -> SV_K (event kind or empty), SV_D, SV_H, SV_OUT (1 = still owed a waiter),
# SV_DROP (1 = terminal: the owner record goes once the event is logged)

_sv_observe() { # <id> <now> [src] [owner]
  local id="$1" now="$2" src="${3:-supervise}" owner="${4:-}" st code h out ev stall cap sig rf
  SV_K=""; SV_D=""; SV_H=0; SV_OUT=0; SV_DROP=0; SV_PEND=0; SV_NX=""; SV_WT=""; SV_STOPPED=0; SV_RM=""; SV_HA=""; SV_STALL_START=""
  case "$id" in watch.*) _sv_observe_watch "$id" "$src" "$owner"; return 0 ;; esac
  # Disk-paused (SIGSTOPped by lib/disk_policy.sh): its screen and log are frozen on purpose. Owed a
  # waiter, no event (the disk policy wakes once), and the stall clock restarts so a resumed lane is
  # never read as stalled for the time it spent paused.
  if type _osrc_disk_target_paused >/dev/null 2>&1 && _osrc_disk_target_paused "$id"; then
    _sv_state_read "$id"; SV_OUT=1; SV_PEND=1; SV_D="disk-paused: resumes when disk space returns ($SCRIPT_PATH disk status)"
    SVS_CHANGED="$now"; SVS_CK=-; _sv_state_write "$id"; return 0
  fi
  stall=$(( $(_sv_num "${OSRC_SUPERVISE_STALL:-}" 15) * 60 ))
  _sv_state_read "$id"
  if [ -f "$OSRC_HOME/remote/$id.json" ] && type osrc_remote_state >/dev/null 2>&1; then
    st="$(osrc_remote_state "$id" 2>/dev/null)"
    case "$st" in
      done) SV_K=done; SV_D="remote lane finished"; SV_DROP=1 ;;
      failed) SV_K=failed; SV_D="remote lane failed"; SV_DROP=1 ;;
      gone) SV_DROP=1 ;;
      *) SV_OUT=1; SV_PEND=1 ;;   # live/ready: osrc_remote_events reports READY/unreviewed itself
    esac
    SV_H="$(printf '%s' "$st" | cksum | awk '{print $1}')"
  elif [ -d "$OSRC_JOBS/$id" ]; then
    st="$(_reconcile_status "$id" 2>/dev/null || printf '?')"
    h="$(printf '%s %s %s' "$st" "$(wc -c 2>/dev/null < "$OSRC_JOBS/$id/out.log")" "$(tail -1 "$OSRC_JOBS/$id/progress" 2>/dev/null)" | cksum | awk '{print $1}')"
    SV_H="$h"
    case "$st" in
      done|'done?') SV_K=done; SV_D="job finished ($st)"; SV_DROP=1 ;;
      blocked|permission-blocked) SV_K=approval; SV_D="headless job ended $st: it hit a permission wall"; SV_DROP=1 ;;
      failed|wedged|timeout|interrupted|canceled) SV_K=failed; SV_D="job $st: $(head -c 120 "$OSRC_JOBS/$id/reason" 2>/dev/null | tr '\n' ' ')"; SV_DROP=1 ;;
      'stalled?'|no-progress-writes)
        SV_STALL_START="$(stat -c %Y "$OSRC_JOBS/$id/status" 2>/dev/null || stat -f %m "$OSRC_JOBS/$id/status")"
        SV_K=stalled; SV_D="job reports $st"; SV_OUT=1 ;;
      *) SV_OUT=1; SV_PEND=1 ;;
    esac
  elif [ -e "$OSRC_HOME/autodetach/$id.log" ] || [ -e "$OSRC_HOME/autodetach/$id.rc" ]; then
    SV_H="$(wc -c 2>/dev/null < "$OSRC_HOME/autodetach/$id.log" | tr -d ' ')"; SV_H="${SV_H:-0}"
    if [ -s "$OSRC_HOME/autodetach/$id.rc" ]; then
      code="$(tr -dc '0-9' < "$OSRC_HOME/autodetach/$id.rc")"; SV_DROP=1
      if [ "${code:-1}" = 0 ]; then SV_K=done; SV_D="run finished (exit 0)"; else SV_K=failed; SV_D="run exited ${code:-?}"; fi
    elif have tmux && tmux has-session -t "=$id" 2>/dev/null; then SV_OUT=1; SV_PEND=1
    else SV_K=failed; SV_D="run ended without an exit code (stopped or killed)"; SV_DROP=1; fi
  elif have tmux && tmux has-session -t "=$id" 2>/dev/null; then
    # the approver acts first (policy `safe` approves read-only/test prompts once; `off` = rc 1).
    if type osrc_approver_tick >/dev/null 2>&1; then
      out="$(osrc_approver_tick "$id" "$id" 2>/dev/null)"; code=$?
      case "$code" in
        0) # approved and verified closed: informational, never a wake; the lane is working again
           _sv_append approved "$id" "$(_sv_ev_detail "$out")" "$(_sv_ev_next "$out")" "$src" "$owner"
           SV_OUT=1; SV_PEND=1; SVS_CK=-; SVS_LK=-; _sv_state_write "$id"; return 0 ;;
        2) # held and reported now (new hold, or past OSRC_HOLD_MIN): the approver's line, its NEXT; its kind
           # is approval, or approval-not-landed when it pressed and the prompt stayed open
           case "$out" in "EVENT approval-not-landed "*) code=approval-not-landed ;; *) code=approval ;; esac
           _sv_append "$code" "$id" "$(_sv_ev_detail "$out")" "$(_sv_ev_next "$out")" "$src" "$owner"
           SV_OUT=1; SVS_CK=-; SVS_LK="approval:approver"; SVS_LT="$now"; _sv_state_write "$id"; return 0 ;;
        3) # held, already reported: the approver owns the reminder clock
           SV_OUT=1; SVS_CK=-; _sv_state_write "$id"; return 0 ;;
      esac
    fi
    cap="$(_osrc_screen_capture "$id" 2>/dev/null)"
    out="$(_sv_target_screen "$id" "$cap")"; st="${out%%$'\n'*}"
    ev="$(printf '%s\n' "$out" | sed -n 2p | cut -c1-140)"
    h="$(_sv_pane_text "$id" "$cap" | cksum | awk '{print $1}')"; SV_H="$h"
    [ "$h" = "$SVS_HASH" ] || { SVS_HASH="$h"; SVS_CHANGED="$now"; }
    _sv_stretch_note "$id" "$st" "$now"
    rf="$(_sv_lanes)/state/$id.retry"
    [ "$st" = failed ] || rm -f "$rf" 2>/dev/null
    case "$st" in
      approval) SV_K=approval; SV_D="approval prompt open: $ev"; SV_OUT=1; SVS_CK=-
        # An answer was typed and the same prompt is still there: retry it, never assume it landed.
        # SV_HA: the prompt's own key, so the approval it stays carries on (no second row, same age).
        if type _sv_not_landed >/dev/null 2>&1 && rf="$(_sv_not_landed "$id" "$now" "$h")"; then
          SV_K=approval-not-landed; SV_D="$rf: $ev"; SV_H="nl$now"; SV_HA="approval:$h"; SV_NX="OUTSOURCERER_TMUX=$id $SCRIPT_PATH session answer"
        fi ;;
      limit) SV_K=limit; SV_D="plan limit hit: $ev"; SVS_CK=- ;;
      failed)
        # API/login error banner: one automatic `continue` (through session send, which refuses
        # modals), then wake with the same command as NEXT if the same error is still there.
        SV_OUT=1; sig="$(printf '%s' "$ev" | tr -d '0-9' | cksum | awk '{print $1}')"; SV_H="$sig"
        # Same banner screen on two reads OSRC_SUPERVISE_CONFIRM apart before anything is typed.
        if ! _sv_confirm failed "$h" "$now"; then SV_PEND=1
        elif [ "${OSRC_SUPERVISE_AUTORETRY:-1}" != 0 ] && [ "$(cat "$rf" 2>/dev/null)" != "$sig" ]; then
          mkdir -p "$(_sv_lanes)/state" 2>/dev/null; printf '%s\n' "$sig" > "$rf"
          OUTSOURCERER_TMUX="$id" OSRC_STREAM=1 "$SCRIPT_PATH" session send "continue" >/dev/null 2>&1
          SV_PEND=1
        else
          SV_K=failed; SV_NX="OUTSOURCERER_TMUX=$id $SCRIPT_PATH session send 'continue'"
          if [ -s "$rf" ]; then SV_D="$ev (one automatic 'continue' was sent; the error is still there)"; else SV_D="$ev"; fi
        fi ;;
      composer)
        case "$ev" in
          *"no turn yet"*) SVS_CK=- ;;   # fresh session, nothing asked of it yet: not an event, not live
          *) SV_OUT=1   # not done: still owed a waiter after the idle event 
             if _sv_confirm composer "$h" "$now"; then SV_K=idle; SV_D="idle with unsent text in its composer (a send did not land): $ev"
             else SV_PEND=1; fi ;;
        esac ;;
      working)
        SV_OUT=1; SV_PEND=1; SVS_CK=-
        case "$ev" in
          "background shell still running"*)
            # Its turn ended while its own shell runs: after OSRC_STALL_MIN of unchanged screen it is
            # stalled (lib/stall.sh).
            _sv_stall_observe "$id" "$now" bgshell "${ev#background shell still running: }" "$src" "$owner" || SVS_LK=- ;;
          *) _sv_stall_working "$id" "$now"
             if [ $(( now - SVS_CHANGED )) -ge "$stall" ]; then
               SV_K=stalled; SV_RM="$stall"   # a long foreground tool: reminded every OSRC_SUPERVISE_STALL, not 5 min
               SV_D="working but the screen has not changed for $(( (now - SVS_CHANGED) / 60 ))m: $ev"
             else SVS_LK=-; fi ;;   # healthy: forget the last event so a repeat of it reports again
        esac ;;
      *)
        case "$st" in question|idle|done) ;; *) st=unknown ;; esac
        if _sv_confirm "$st" "$h" "$now"; then
          case "$st" in
            question) SV_K=question; SV_D="stopped and asked: $ev"; SV_OUT=1 ;;
            done) SV_K=done; SV_D="finished: $ev"; _sv_stall_reset "$id"
                  # Key on the hand-in (contract file or branch tip), not only the screen: a lane
                  # that re-hands in by rewriting its DONE file is a new event.
                  rf="$(_sv_done_fp "$id")"
                  [ -n "$rf" ] && { SV_H="$(printf '%s' "$rf" | cksum | awk '{print $1}')"; SV_D="$SV_D (hand-in ${rf#*:})"; }
                  # first report of a watched hand-in: remember the screen it was reported on
                  case "$ev:$SVS_LK" in "hand-in "*:"done:$SV_H") ;; "hand-in "*) _sv_handin_note "$id" "$rf" "$h" ;; esac ;;
            idle)
              SV_OUT=1   # short of done: report it once, then keep watching for its next change
              # A promise to continue later, or a plain idle unchanged for OSRC_STALL_MIN, is a stall; a
              # lane waiting on a person is plain idle.
              case "$ev" in "promises to continue later: "*) rf=promise ;; "waits for a person: "*) rf=person ;; *) rf=quiet ;; esac
              if [ "$rf" != person ] && _sv_stall_observe "$id" "$now" "$rf" "${ev#promises to continue later: }" "$src" "$owner"; then :
              elif [ "$(type -t osrc_done_state >/dev/null 2>&1 && osrc_done_state "$id" 2>/dev/null)" = not-done ]; then
                SV_K=idle; SV_D="finished its turn but its done contract does not hold yet"
              elif [ -f "$OSRC_HOME/done/$id.json" ] || [ -n "$(ls "$OSRC_HOME/watch" 2>/dev/null)" ]; then
                SV_K=idle; SV_D="finished its turn, composer empty (no done marker)"
              else SV_K=idle; SV_D="finished its turn, composer empty (no done marker registered: re-arm with --watch <hand-in dir>, or start lanes with --done-when)"; fi ;;
            unknown) SV_K=stalled; SV_D="screen unrecognised and unchanged for ${OSRC_SUPERVISE_CONFIRM:-20}s+: ${ev:-no signal}"; SV_OUT=1
                     [ "$SVS_LK" = "stalled:$h" ] || _sv_fixture_drop "$id" "supervise: persistent unknown" ;;
          esac
        else SV_OUT=1; SV_PEND=1; fi ;;
    esac
  else
    _sv_observe_gone "$id"   # stopped (recorded stop) | done (handed in, then closed) | failed (lib/lane_life.sh)
  fi
  _sv_state_write "$id"
}

# ---- event log ------------------------------------------------------------------------------------
_sv_next() { # <kind> <id> -> the command the orchestrator should run
  local s="$SCRIPT_PATH" id="$2"
  if [ -d "$OSRC_JOBS/$id" ]; then
    case "$1" in done) printf '%s result %s' "$s" "$id" ;; stalled) printf '%s status %s' "$s" "$id" ;; *) printf '%s explain %s' "$s" "$id" ;; esac
    return 0
  fi
  if [ -e "$OSRC_HOME/autodetach/$id.log" ] || [ -e "$OSRC_HOME/autodetach/$id.rc" ]; then printf '%s wait %s' "$s" "$id"; return 0; fi
  case "$1" in
    failed) printf '%s fleet ls' "$s" ;;
    approval) printf 'OUTSOURCERER_TMUX=%s %s session answer' "$id" "$s" ;;   # lists the options
    limit) printf '%s fleet ls  # lane parked on its plan timer: move the work to another lane or wait for the reset' "$s" ;;
    *) printf 'OUTSOURCERER_TMUX=%s %s session read' "$id" "$s" ;;
  esac
}

_sv_ev_detail() { printf '%s\n' "$1" | sed -n '1s/^EVENT [^ ]* [^ ]* [^ ]* //p'; }
_sv_ev_next() { printf '%s\n' "$1" | sed -n 's/^NEXT //p' | head -1; }

_sv_append() { # <kind> <target> <detail> <next> <src> [owner]
  local f; f="$(_sv_lanes)/events.jsonl"; mkdir -p "$(_sv_lanes)" 2>/dev/null || return 1
  if [ "$(wc -c 2>/dev/null < "$f" | tr -d ' ')" -gt "$(_sv_num "${OSRC_LANES_LOG_MAX:-}" 5000000)" ] 2>/dev/null; then
    # Rotation bumps the generation; a cursor from the previous generation finishes .1 first.
    mv -f "$f" "$f.1" 2>/dev/null && printf '%s\n' $(( $(_sv_num "$(cat "$(_sv_lanes)/events.gen" 2>/dev/null)" 0) + 1 )) > "$(_sv_lanes)/events.gen"
  fi
  _SV_SEQ=$(( ${_SV_SEQ:-0} + 1 ))   # row id: unique per append (ts, pid, sequence, random)
  jq -cn --argjson ts "$(_sv_now)" --arg k "$1" --arg t "$2" --arg d "$3" --arg n "$4" --arg src "$5" --arg o "${6:-}" \
    --arg id "${7:-$(_sv_now)-$$-$_SV_SEQ-$RANDOM}" \
    '{id:$id,ts:$ts,kind:$k,target:$t,detail:$d,next:$n,src:$src} + (if $o == "" then {} else {owner:$o} end)' >> "$f"
}

# Log SV_K for <id> unless the same kind+hash was logged within OSRC_SUPERVISE_REMIND minutes.
_sv_emit() { # <id> <now> <src> [owner]
  local id="$1" now="$2" key remind detail
  [ -n "$SV_K" ] || return 0
  remind="${SV_RM:-$(_sv_remind_secs "$SV_K")}"   # 5 min for idle/stalled/question/approval, else 20
  key="$SV_K:$SV_H"
  _sv_state_read "$id"
  if [ "$SVS_LK" = "$key" ]; then
    [ $(( now - SVS_LT )) -ge "$remind" ] || return 0
    detail="still unresolved, waiting $(( (now - $(_sv_first_seen "$id" "$key" "$now")) / 60 ))m: $SV_D"
  else _sv_first_seen "$id" "$key" "$now" >/dev/null; detail="$SV_D"; fi
  local delivery_id=""
  if [ "$SV_K" = stalled ]; then delivery_id="$(_sv_stall_id "$id" "${SV_STALL_START:-$SVS_CHANGED}")"; fi
  _sv_append "$SV_K" "$id" "$detail" "${SV_NX:-$(_sv_next "$SV_K" "$id")}" "$3" "${4:-}" "$delivery_id" || return 1
  SVS_LK="${SV_HA:-$key}"; SVS_LT="$now"; _sv_state_write "$id"   # SV_HA: the event a not-landed stands for
}

# Observe every owned target of every orchestrator and log events. The heartbeat beacon calls this
# each tick, so the log fills even while no supervise is running.
_sv_observe_all() { # [src]
  local now d id o; now="$(_sv_now)"
  [ -d "$OSRC_HOME/owners" ] || return 0
  for d in "$OSRC_HOME"/owners/*/; do
    [ -d "$d" ] || continue
    o="$(basename "$d")"
    [ "${1:-}" != watcher ] || ! _ws_foreign "$o" || continue   # lanes on a tmux server the watcher cannot see
    for id in $(ls -1 "$d" 2>/dev/null); do
      _sv_observe_emit "$id" "$now" "${1:-beacon}" "$o"
    done
  done
  _sv_remote_poll "${1:-beacon}"
}

# Remote lanes print EVENT/NEXT pairs; distinguish done events for new branch heads.
_sv_remote_poll() { # <src>
  type osrc_remote_events >/dev/null 2>&1 || return 0
  local owner marker line kind="" tgt detail next key now _e _ts head delivery_id; now="$(_sv_now)"
  osrc_remote_events 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      EVENT\ *) read -r _e kind tgt _ts detail <<< "$line"; next="" ;;
      NEXT\ *) next="${line#NEXT }"
        [ -n "$kind" ] && [ -n "$tgt" ] || continue
        head=""
        if [ "$kind" = done ] && type _osrc_id_ok >/dev/null 2>&1 && _osrc_id_ok "$tgt"; then
          head="$(jq -r '.head // ""' "$OSRC_HOME/remote/$tgt.json" 2>/dev/null)"
        fi
        key="$kind:$(printf '%s\n%s' "$detail" "$head" | cksum | awk '{print $1}')"
        _sv_target_lock "remote.$tgt" || { kind=""; continue; }   # another supervise is logging it
        _sv_state_read "remote.$tgt"
        if [ "$SVS_LK" != "$key" ] || [ $(( now - SVS_LT )) -ge "$(_sv_remind_secs "$kind")" ]; then
          owner=""
          case "$tgt" in */*|.|..) ;; *)
            for marker in "$OSRC_HOME"/owners/*/"$tgt"; do
              [ -f "$marker" ] || continue
              owner="${marker%/*}"; owner="${owner##*/}"; break
            done ;;
          esac
          delivery_id=""
          [ "$kind" != stalled ] || delivery_id="$(_sv_stall_id "$tgt" "$_ts")"
          _sv_append "$kind" "$tgt" "$detail" "$next" "$1" "$owner" "$delivery_id" && { SVS_LK="$key"; SVS_LT="$now"; _sv_state_write "remote.$tgt"; }
        fi
        _sv_target_unlock "remote.$tgt"
        kind="" ;;
    esac
  done
}

# Events in <file> between two byte offsets that belong to this orchestrator, as TSV:
# prio ts kind target detail next id (id: the row's own, or ts/kind/target/detail for rows without). An event belongs when it carries this owner sid (so a target the
# stop guard or supervise already pruned still replays) or names one of the given targets.
_sv_read_range() { # <file> <from> <to|-> <targets-json> <owner>
  [ -f "$1" ] || return 0
  { if [ "$3" = - ]; then tail -c +"$(( $2 + 1 ))" "$1"; else tail -c +"$(( $2 + 1 ))" "$1" | head -c "$(( $3 - $2 ))"; fi; } 2>/dev/null \
  | jq -r --argjson set "$4" --arg all "${_sv_all:-0}" --arg owner "$5" --argjson since "$(( $(_sv_now) - 86400 ))" '
    select(type=="object" and .ts >= $since and ($all == "1" or ($owner != "" and .owner == $owner) or (.target as $t | $set | index($t))))
    | ({approval:1,"approval-not-landed":1,question:2,failed:3,limit:4,done:5,idle:6,stalled:7,unreviewed:8,drift:9,"watcher-lost":10,approved:11}[.kind] // 12) as $p
    | def f: (. // "" | tostring | gsub("[\t\n\r]";" ")) | if . == "" then "-" else . end;
      [($p|tostring), (.ts|tostring), (.kind|f), (.target|f), (.detail|f), (.next|f),
       ((.id // "\(.ts)/\(.kind)/\(.target)/\(.detail)") | f)] | join("\t")' 2>/dev/null   # not @tsv: it doubles every backslash in a %q NEXT
}

_sv_approval_summary() { # <new TSV rows>: report only at an actual wake
  local count; count="$(printf '%s\n' "$1" | awk -F '\t' '$3 == "approved" { n++ } END { print n+0 }')"
  [ "$count" -eq 0 ] || printf '[outsourcerer] %s auto-approval(s); log: %s/approvals.log\n' "$count" "$OSRC_HOME" >&2
}

_sv_tick() { # <owner state dir> <epoch>: refresh both project rows and limits atomically
  local dir="$1" now="$2" interval last tmp
  interval="$(_sv_num "${OSRC_SUPERVISE_TICK_SECS:-}" 600)"; [ "$interval" -gt 0 ] || interval=600
  last="$(_sv_num "$(cat "$dir/tick.time" 2>/dev/null)" 0)"
  [ "$last" -eq 0 ] || [ $((now - last)) -ge "$interval" ] || return 0
  type cmd_hub_export >/dev/null 2>&1 || return 1
  # Keep each card's summary current from real lane state, so the page never shows an old narrative.
  if type osrc_hub_tick_touch >/dev/null 2>&1; then
    local od slug
    for od in "$OSRC_HOME"/owners/*/; do
      slug="$(basename "$od")"
      [ -f "$OSRC_HOME/hub/projects/$slug.json" ] && osrc_hub_tick_touch "$slug" >/dev/null 2>&1 || true
    done
  fi
  tmp="$dir/hub.json.tmp.$$"
  # The page's cached path (lib/hub-perf.sh): limits and settled lanes from their caches, refreshed off
  # this clock, instead of recomputing the plan meters inline every tick.
  if ! OSRC_HUB_FAST=1 cmd_hub_export > "$tmp" || ! jq -e '(.projects | type) == "array" and (.limits | type) == "array"' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; return 1
  fi
  mv -f "$tmp" "$dir/hub.json" || return 1
  printf '%s\n' "$now" > "$dir/tick.time"
  _sv_card_event "${dir##*/}"
}

_sv_card_event() { # <owner sid>: the stop-guard card check (lib/card_fresh.sh), as a wake for orchestrators that rarely stop
  local why; type _sg_card_nag >/dev/null 2>&1 || return 0   # it decides: a card, or lanes owned with none
  why="$(_SG_CARD_OWNED=1 _sg_card_nag "$1")" || return 0
  _sv_append card card "$(printf '%s' "$why" | head -1 | cut -c1-400)" "$SCRIPT_PATH hub report --board <board.json> --next \"<one line>\"" supervise "$1"
}

_sv_auto_filter() { # <rows> <owner state dir>: only consume a verified READY -> review next
  local rows="$1" dir="$2" row p ts kind target detail next head state key mark
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS="$(printf '\t')" read -r p ts kind target detail next _id <<< "$row"
    if [ "$kind" = done ] && type _osrc_id_ok >/dev/null 2>&1 && _osrc_id_ok "$target" \
      && [ "$next" = "$(_osrc_self) review next" ] && [ -f "$OSRC_HOME/remote/$target.json" ]; then
      key="$(printf '%s' "$row" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
      case "$key" in *[!0-9a-f]*|'') printf '%s\n' "$row"; continue ;; esac
      [ "${#key}" -eq 64 ] || { printf '%s\n' "$row"; continue; }
      mark="$dir/auto.$key"
      [ -f "$mark" ] && continue
      head="$(jq -r '.head // ""' "$OSRC_HOME/remote/$target.json" 2>/dev/null)"
      state="$(type _osrc_review_item_state >/dev/null 2>&1 && _osrc_review_item_state "$target" "$head")"
      case "$detail" in
        "READY ${head:0:7} "*)
          if [ -n "$head" ] && [ "$state" = queued ]; then
            if _osrc_atomic_mkdir "$mark.lock"; then
              if [ -f "$mark" ]; then rmdir "$mark.lock" 2>/dev/null; continue; fi
              if ( cmd_review next --exact "$target" "$head" >/dev/null 2>&1 ) && printf '%s\n' "$ts" > "$mark"; then
                rmdir "$mark.lock" 2>/dev/null; continue
              fi
              rmdir "$mark.lock" 2>/dev/null
            fi
          fi ;;
      esac
    fi
    printf '%s\n' "$row"
  done <<< "$rows"
}

# A live pid is not a live waiter: a supervise hung in a probe kept its armed file and pid while it
# logged and delivered nothing (7 h unwatched; a done row 37 min undelivered). It covers only while it
# has polled (supervise/<sid>/alive) or armed within OSRC_SUPERVISE_HUNG seconds (default 600). A --loop
# counts only through loop.<pid>: its mtime is its last batch written into a pipe or terminal (created old).
_sv_armed_cover() { # <sid> -> `*` or the explicit ids a live, polling supervise for <sid> covers
  local f pid alive m
  alive="$(_sv_num "$(cat "$OSRC_HOME/supervise/$1/alive" 2>/dev/null)" 0)"
  for f in "$OSRC_HOME/supervise/$1"/armed.* "$OSRC_HOME/supervise/$1"/loop.*; do
    [ -f "$f" ] || continue
    pid="${f##*.}"
    if kill -0 "$pid" 2>/dev/null && ps -o command= -p "$pid" 2>/dev/null | grep -q 'supervise'; then
      m="$(_sv_num "$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)" 0)"
      case "$f" in */armed.*) [ ! -f "${f%/*}/loop.$pid" ] || continue; [ "$m" -gt "$alive" ] || m="$alive" ;; esac
      [ $(( $(_sv_now) - m )) -le "$(_sv_num "${OSRC_SUPERVISE_HUNG:-}" 600)" ] && cat "$f" 2>/dev/null
    else rm -f "$f"; fi
  done
}

# Run <cmd> with a deadline; rc 124 when it had to be killed. A probe that never returns must not
# stop a waiter from observing and delivering.
_sv_bounded() { # <secs> <cmd...>
  local n p i=0; n=$(( $(_sv_num "$1" 60) * 10 )); shift
  "$@" & p=$!; _SV_BOUNDED="$p"
  while kill -0 "$p" 2>/dev/null; do
    if [ "$i" -ge "$n" ]; then
      _sv_bounded_kill; wait "$p" 2>/dev/null; return 124   # the probe sits below a $(...): kill the whole tree
    fi
    sleep 0.1; i=$((i + 1))
  done
  _SV_BOUNDED=""; wait "$p"
}
# Also from an EXIT trap: a waiter signalled mid-probe takes the probe with it. Only a child this
# shell still lists as running is signalled, never a pid that may have been reused.
_sv_bounded_kill() {
  case " $(jobs -pr 2>/dev/null | tr '\n' ' ') " in *" ${_SV_BOUNDED:-x} "*) _kill_tree "$_SV_BOUNDED" 2>/dev/null ;; esac
  _SV_BOUNDED=""
}

# ---- the command ----------------------------------------------------------------------------------
_sv_fail() { # <reason> <rearm>
  printf 'EVENT failed supervise %s %s\n' "$(_sv_now)" "$(printf '%s' "$1" | tr '\n' ' ' | cut -c1-200)"
  printf 'NEXT %s\n' "$2"
}

cmd_supervise() {
  local _sv_all=0 scope="" sid="" ids="" once=0 loop=0 rearm rc watches="" unwatch="" w wid auto="" kind
  # A signal before the worker starts must still print the failure line, never exit silently.
  trap '_sv_fail "killed by a signal before it armed" "$SCRIPT_PATH supervise"; exit 2' TERM INT HUP
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) sid="$(_owner_sid "${2:-}")"; shift 2 ;;
      --session=*) sid="$(_owner_sid "${1#--session=}")"; shift ;;
      --all) _sv_all=1; shift ;;
      --once) once=1; shift ;;
      --loop) { [ -p /dev/stdout ] || [ -t 1 ]; } && loop=1; shift ;;   # into a file nobody reads: plain supervise, whose exit wakes the agent
      --auto|--auto=*)
        if [ "$1" = --auto ]; then [ "$#" -ge 2 ] || { _sv_fail "--auto needs a value" "$SCRIPT_PATH supervise"; return 2; }; auto="$2"; shift 2; else auto="${1#--auto=}"; shift; fi
        case "$auto" in ''|,*|*,|*,,*|*[!A-Za-z,]*) _sv_fail "--auto needs done and/or limits" "$SCRIPT_PATH supervise"; return 2 ;; esac
        for kind in $(printf '%s' "$auto" | tr ',' ' '); do case "$kind" in done|limits) ;; *) _sv_fail "--auto cannot run $kind" "$SCRIPT_PATH supervise"; return 2 ;; esac; done ;;
      --watch|--watch=*)
        if [ "$1" = --watch ]; then w="${2:-}"; shift 2; else w="${1#--watch=}"; shift; fi
        # the list below is newline-separated: refuse control characters before they split a path
        case "$w" in *[[:cntrl:]]*) _sv_fail "--watch: path has control characters: $(printf '%s' "$w" | tr -d '[:cntrl:]')" "$SCRIPT_PATH supervise --watch <dir|file>"; return 2 ;; esac
        watches="$watches
$w" ;;
      --unwatch) unwatch="${2:-}"; shift 2 ;;   # tests: one pass (plus settle), exit 1 when nothing is new
      -h|--help) sed -n '2,/^$/p' "$_SV_SELF" 2>/dev/null | sed 's/^# \{0,1\}//'; return 0 ;;
      -*) _sv_fail "unknown flag $1" "$SCRIPT_PATH supervise"; return 2 ;;
      *) case "$1" in */*|.|..) ;; *) ids="$ids $1" ;; esac; shift ;;
    esac
  done
  if [ "$_sv_all" = 1 ]; then
    if [ -n "$sid$ids$watches$unwatch" ]; then _sv_fail "--all requires a separate watcher" "$SCRIPT_PATH supervise --all"; return 2; fi
    scope=" --all"
  else
    [ -n "$sid" ] || sid="$(_owner_sid)"
    scope="${sid:+ --session $sid}"
  fi
  if [ -n "$unwatch" ]; then
    wid="$(_sv_watch_rm "$unwatch" "$sid")"; printf '[outsourcerer] supervise: stopped watching %s (%s)\n' "$unwatch" "$wid" >&2; return 0
  fi
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    wid="$(_sv_watch_add "$w")"; rc=$?
    case "$rc" in
      0) ;;
      2) _sv_fail "--watch: path has control characters: $(printf '%s' "$w" | tr -d '[:cntrl:]')" "$SCRIPT_PATH supervise --watch <dir|file>"; return 2 ;;
      *) _sv_fail "--watch: no such file or directory: $(printf '%s' "$w" | tr -d '[:cntrl:]')" "$SCRIPT_PATH supervise --watch <dir|file>"; return 2 ;;
    esac
    if [ -n "$sid" ]; then mkdir -p "$OSRC_HOME/owners/$sid" && : > "$OSRC_HOME/owners/$sid/$wid"
    else case " $ids " in *" $wid "*) ;; *) ids="$ids $wid" ;; esac; fi
  done <<< "$watches"
  rearm="$SCRIPT_PATH supervise$scope${auto:+ --auto $auto}$([ "$loop" = 0 ] || printf ' --loop')${ids}"
  if [ "$_sv_all" = 0 ] && [ -z "$sid" ] && [ -z "$ids" ]; then
    _sv_fail "no Claude Code session id (CLAUDE_CODE_SESSION_ID unset) and no target ids" "$SCRIPT_PATH supervise --session <your-session-id>"
    return 2
  fi
  have jq || { _sv_fail "jq is required" "$rearm"; return 2; }
  [ "$loop" = 0 ] || [ -n "$sid" ] || { _sv_fail "--loop needs a session" "$SCRIPT_PATH supervise --session <your-session-id> --loop"; return 2; }
  # The worker may be inside a redirected refresh when signalled. The parent owns the event so
  # its output cannot disappear into that refresh's temporary file.
  local child="" signalled=0
  export OSRC_SUPERVISE_AUTO="$auto" OSRC_SUPERVISE_LOOP="$loop"
  w="$OSRC_HOME/supervise/$sid/loop.$$"; [ "$loop" = 0 ] || { mkdir -p "${w%/*}" && printf '%s\n' ${ids:-'*'} > "$w" && touch -t 200001010000 "$w"; } || return 2
  trap 'if [ "$signalled" = 0 ]; then signalled=1; _sv_fail "killed by a signal" "$rearm"; fi; kill -TERM "$child" 2>/dev/null' TERM INT HUP
  while [ "$signalled" = 0 ]; do
    ( _sv_main "$sid" "$once" $ids ) & child=$!
    [ "$signalled" = 0 ] || kill -TERM "$child" 2>/dev/null   # a signal that landed just before the fork
    while :; do
      wait "$child"; rc=$?
      kill -0 "$child" 2>/dev/null || break
    done
    [ "$rc" = 20 ] || break; rc=0   # --loop: only after a delivered batch, never on done all, superseded (ping-pong) or error
  done
  trap - TERM INT HUP
  [ "$loop" = 0 ] || rm -f "$OSRC_HOME/supervise/$sid/loop.$$"
  [ "$signalled" != 1 ] || return 2
  case "$rc" in
    0) return 0 ;;
    1) [ "$once" = 1 ] && return 1; _sv_fail "internal error (rc 1)" "$rearm"; return 2 ;;
    10) _sv_fail "killed by a signal" "$rearm"; return 2 ;;
    11) return 2 ;;
    *) _sv_fail "internal error (rc $rc)" "$rearm"; return 2 ;;
  esac
}

_sv_main() { # <sid> <once> [ids...]
  local sid="$1" once="$2"; shift 2
  local explicit="$*" seen="" pend=0 key dir cursor size targets tj now poll settle first="" maxs t0 id out=0 new nl idle_list stopped_list=""
  local scope="${scope:-${sid:+ --session $sid}}" fowner gen cgen older="" real f armed ledger drc newer head rc
  key="${sid:-ids-$(printf '%s' "$explicit" | cksum | awk '{print $1}')}"
  [ "${_sv_all:-0}" = 0 ] || key="@all"
  dir="$OSRC_HOME/supervise/$key"; mkdir -p "$dir" "$(_sv_lanes)" || exit 1
  ledger="$dir/delivered"   # per orchestrator key: sid-less explicit-id runs get their own
  armed="$dir/armed.$$"; _SV_HELD=""; _SV_MAIN_DIR="$dir"
  trap '_sv_bounded_kill; _sv_main_exit' EXIT   # removes the armed/arm-seq files and releases every lock this run holds
  trap 'exit 10' TERM INT HUP
  printf '%s\n' "${explicit:-*}" | tr ' ' '\n' | grep . > "$armed"
  _sv_arm_seq "$dir" || exit 1
  if [ -n "$sid" ] && [ -s "$OSRC_HOME/owners/$sid/.unguarded" ]; then
    sed 's/^/[outsourcerer] was: /' "$OSRC_HOME/owners/$sid/.unguarded" >&2; rm -f "$OSRC_HOME/owners/$sid/.unguarded"
  fi
  poll="$(_sv_num "${OSRC_SUPERVISE_POLL:-}" 10)"; [ "$poll" -gt 0 ] || poll=10
  settle="$(_sv_num "${OSRC_SUPERVISE_SETTLE:-}" 20)"; maxs="$(_sv_num "${OSRC_SUPERVISE_MAX_SECS:-}" 0)"
  # cursor file: "<offset> <generation>"; a rotation since then means: finish events.jsonl.1 first.
  f="$(_sv_lanes)/events.jsonl"
  read -r cursor cgen 2>/dev/null < "$dir/cursor"; cursor="$(_sv_num "${cursor:-}" 0)"
  gen="$(_sv_num "$(cat "$(_sv_lanes)/events.gen" 2>/dev/null)" 0)"; cgen="$(_sv_num "${cgen:-}" "$gen")"
  t0="$(_sv_now)"
  while :; do
    now="$(_sv_now)"
    if newer="$(_sv_superseded "$dir")"; then _sv_superseded_exit "$newer"; fi
    # The parent (cmd_supervise, pid $$) died without forwarding a signal (SIGKILL, an uncaught
    # SIGALRM): an orphan worker would poll on as a ghost waiter, covering the stop guard and holding
    # the caller's pipe open. Exit with it.
    kill -0 "$$" 2>/dev/null || exit 12
    osrc_watcher_alive "$dir" "$now"   # liveness stamp for osrc_watcher_gap (lib/stall.sh)
    # The refresh probes agent CLIs; bounded so a hung probe cannot starve the observe loop below.
    _sv_bounded "$(_sv_num "${OSRC_SUPERVISE_TICK_TIMEOUT:-}" 120)" _sv_tick "$dir" "$now"; rc=$?
    if [ "$rc" = 124 ]; then
      printf '%s\n' "$now" > "$dir/tick.time"   # retry after the normal interval, not every poll
      printf '[outsourcerer] supervise: project and limits refresh timed out; watching on\n' >&2
    elif [ "$rc" != 0 ]; then
      _sv_fail "project and limits refresh failed" "$SCRIPT_PATH supervise$scope${OSRC_SUPERVISE_AUTO:+ --auto $OSRC_SUPERVISE_AUTO}${explicit:+ $explicit}"
      exit 11
    fi
    if [ "${_sv_all:-0}" = 1 ]; then
      targets="$(for fowner in "$OSRC_HOME"/owners/*/*; do [ ! -f "$fowner" ] || basename "$fowner"; done | sort -u)"
    elif [ -n "$explicit" ]; then targets="$explicit"
    else targets="$(ls -1 "$OSRC_HOME/owners/$sid" 2>/dev/null | tr '\n' ' ')"; fi
    out=0; pend=0; idle_list=""; stopped_list=""
    for id in $targets; do
      _sv_observe_emit "$id" "$now" supervise "$sid"
      [ "$SV_OUT" = 1 ] && out=1
      [ "$SV_PEND" = 1 ] && pend=1
      [ "$SV_K" = idle ] && idle_list="$idle_list $id"
      [ "$SV_STOPPED" = 1 ] && stopped_list="$stopped_list $id"   # ended by its owner: settled, not a crash
      [ -n "$SV_WT" ] && seen="$seen $SV_WT"   # hand-in files are their own event targets
      if [ "${_sv_all:-0}" = 0 ] && [ "$SV_DROP" = 1 ] && [ -z "$explicit" ]; then
        # keep the target in this batch's filter, drop it from the registry
        rm -f "$OSRC_HOME/owners/$sid/$id" 2>/dev/null
        type osrc_hub_seen_lane >/dev/null 2>&1 && osrc_hub_seen_lane "$sid" "$id"   # listed as finished
      fi
    done
    _sv_remote_poll supervise
    seen="$(printf '%s\n' $seen $targets | sort -u | tr '\n' ' ')"   # a target dropped mid-settle still has its event in this batch
    tj="$(printf '%s\n' $seen supervise card | jq -R . | jq -cs .)"
    gen="$(_sv_num "$(cat "$(_sv_lanes)/events.gen" 2>/dev/null)" 0)"
    if [ "$cgen" != "$gen" ]; then
      [ "$cgen" = $(( gen - 1 )) ] && older="$older$(_sv_read_range "$f.1" "$cursor" - "$tj" "$sid")"
      cursor=0; cgen="$gen"
    fi
    size="$(wc -c 2>/dev/null < "$f" | tr -d ' ')"; size="$(_sv_num "$size" 0)"
    [ "$cursor" -le "$size" ] || cursor=0
    new="$(printf '%s\n%s' "$older" "$(_sv_read_range "$f" "$cursor" "$size" "$tj" "$sid")" | grep .)"
    new="$(_sv_ledger_filter "$ledger" "$new")"   # rows another supervise for this orchestrator already printed
    case ",${OSRC_SUPERVISE_AUTO:-}," in *,done,*) new="$(_sv_auto_filter "$new" "$dir")" ;; esac
    real="$(printf '%s\n' "$new" | awk -F '\t' '$3 != "approved" && $3 != "nudged"' | grep .)"
    if [ -n "$real" ]; then
      [ -n "$first" ] || first="$now"
      # Settle only while some target could still produce an event (working / not yet confirmed).
      if [ $(( now - first )) -ge "$settle" ] || [ "$pend" = 0 ]; then
        # One pair per target; a row a concurrent supervise printed meanwhile is not printed again.
        _SV_DIR="$dir" _sv_deliver "$ledger" "$new" batch; drc=$?
        case "$drc" in
          0) _sv_approval_summary "$new"; printf '%s %s\n' "$size" "$gen" > "$dir/cursor"
             [ "${OSRC_SUPERVISE_LOOP:-0}" = 0 ] || { touch "$dir/loop.$$"; exit 20; }
             printf '[outsourcerer] supervise: act on each NEXT, then re-arm: %s supervise%s%s%s\n' "$SCRIPT_PATH" "$scope" "${OSRC_SUPERVISE_AUTO:+ --auto $OSRC_SUPERVISE_AUTO}" "${explicit:+ $explicit}" >&2
             exit 0 ;;
          1) first=""; older=""; cursor="$size"; printf '%s %s\n' "$size" "$gen" > "$dir/cursor" ;;   # all delivered elsewhere
          3) _sv_superseded_exit "$(_sv_superseded "$dir")" ;;
          *) : ;;   # ledger busy (rc 2): keep the cursor and the batch, deliver on the next poll
        esac
      fi
    elif [ "$out" = 0 ] && [ -z "$first" ]; then
      nl="$(printf '%s' "$targets" | wc -w | tr -d ' ')"
      head="$(printf 'EVENT done all %s no owned live work (%s target(s) settled%s%s)\nNEXT %s fleet ls' "$now" "$nl" "${idle_list:+; idle:$idle_list}" "${stopped_list:+; stopped:$stopped_list}" "$SCRIPT_PATH")"
      drc=1; [ -z "$new" ] || { _SV_DIR="$dir" _SV_HEAD="$head" _sv_deliver "$ledger" "$new" all; drc=$?; }
      case "$drc" in
        0|1) [ "$drc" = 0 ] || printf '%s\n' "$head"   # rc 0 printed the head with the rows
             _sv_approval_summary "$new"; printf '%s %s\n' "$size" "$gen" > "$dir/cursor"; exit 0 ;;
        3) _sv_superseded_exit "$(_sv_superseded "$dir")" ;;
      esac   # rc 2, ledger busy: nothing printed, cursor kept; try again on the next poll
    fi
    if [ "$once" = 1 ] && [ -z "$first" ]; then exit 1; fi
    if [ "$maxs" -gt 0 ] && [ $(( now - t0 )) -ge "$maxs" ]; then
      _sv_approval_summary "$new"
      printf 'EVENT stalled supervise %s OSRC_SUPERVISE_MAX_SECS=%s reached with live work and no event\n' "$now" "$maxs"
      printf 'NEXT %s supervise%s%s%s\n' "$SCRIPT_PATH" "$scope" "${OSRC_SUPERVISE_AUTO:+ --auto $OSRC_SUPERVISE_AUTO}" "${explicit:+ $explicit}"
      exit 0
    fi
    if [ -n "$first" ]; then
      nl=$(( settle - (now - first) )); [ "$nl" -lt 1 ] && nl=1; [ "$nl" -gt "$poll" ] && nl="$poll"; sleep "$nl"
    else sleep "$poll"; fi
  done
}

# ---- small session fixes -----------------------------------------------------------------------
# `claude-sonnet-5-5` and the alias `sonnet` are the same model; string equality called it drift.
_osrc_model_canon() { # <model> -> lowercase id; a Claude family alias maps to its family
  local m; m="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/\[1m\]$//')"
  printf '%s' "$m" | sed -E 's/^(anthropic\/|us\.anthropic\.)?(claude-)?(opus|sonnet|haiku|fable)([-.][0-9][0-9.-]*)?(-latest)?$/\3/'
}
_session_model_matches() { # <requested> <resolved> <observed>
  local requested="$1" resolved="$2" observed="$3" o r
  [ -n "$observed" ] && [ "$observed" != unknown ] || return 1
  o="$(printf '%s' "$observed" | tr '[:upper:]' '[:lower:]')"
  for r in "$requested" "$resolved"; do
    [ -n "$r" ] || continue
    r="$(printf '%s' "$r" | tr '[:upper:]' '[:lower:]')"
    [ "$o" = "$r" ] && return 0
    # An alias on either side matches a versioned id of the same family (never two different versions).
    case "$o:$r" in *[0-9]*:*[0-9]*) continue ;; esac
    [ "$(_osrc_model_canon "$o")" = "$(_osrc_model_canon "$r")" ] && return 0
  done
  return 1
}

# `wait` rebuilt the whole fleet snapshot every 10 s per waiter. Reuse one collected within
# OSRC_WAIT_SNAPSHOT_REUSE seconds (default 20) by anyone (beacon or another waiter).
_sv_snapshot_recent() {
  local snap max; max="$(_sv_num "${OSRC_WAIT_SNAPSHOT_REUSE:-}" 20)"
  if [ "$max" -gt 0 ] && snap="$(_fleet_snapshot_read 2>/dev/null)" \
     && printf '%s' "$snap" | jq -e --argjson max "$max" '(.captured_at | fromdateiso8601?) as $c | $c != null and (now - $c) >= 0 and (now - $c) <= $max' >/dev/null 2>&1; then
    printf '%s' "$snap"; return 0
  fi
  _fleet_snapshot_refresh
}
