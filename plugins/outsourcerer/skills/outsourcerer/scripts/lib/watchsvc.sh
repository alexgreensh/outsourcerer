# shellcheck shell=bash
# lib/watchsvc.sh: the per-user watcher, a waiter nobody has to re-arm.
#
#   outsourcerer.sh watcher install | uninstall | status | run [--transient] | tick
#
# `supervise` only helps while a session keeps one armed; when it is forgotten, killed or reaped,
# nothing watches that session's lanes (a watcher died at 02:36 and nine finished lanes waited
# 4-6 h). The watcher is one shell loop per user that does, every OSRC_WATCH_INTERVAL seconds
# (default 30), what supervise does for one session, for every owner:
#   1. observe every owned lane (_sv_observe_all): finished, idle, stalled, question/approval,
#      limit-hit rows land in lanes/events.jsonl. Files and screens only: zero model tokens.
#   2. send ONE `continue` to a lane parked on a provider limit once that limit's reset time has
#      passed, once per reset, and only while the lane still shows that limit.
#   3. wake each owner that has undelivered rows and no live supervise, through the first channel
#      that can reach it: OSRC_WATCH_DELIVER_CMD (summary as $1, EVENT/NEXT lines on stdin), the
#      session's own tmux pane (recorded by the stop guard, typed only into an empty Claude Code
#      composer, screen-verified), or, with OSRC_WATCH_RESUME=1, `claude -p --resume` for a session
#      that is provably closed. A delivery counts only when the channel proves it (exit 0 / screen
#      proof); failures retry with backoff (1, 5, then every 15 min, forever) and, after
#      OSRC_WATCH_WAKE_MAX (3) attempts, owners/<sid>/.wakefail is printed by every outsourcerer call
#      and an OS notification is shown. Delivered rows go into supervise's delivered ledger, so the
#      session never sees them twice. Repeated "still unresolved" reminders wake again at most once
#      per OSRC_WATCH_REWAKE seconds (default 3600).
# Backends: launchd (macOS), systemd --user (Linux), else a detached loop that the stop guard
# restarts while installed (Windows Git Bash, containers). `install` is explicit and idempotent,
# `uninstall` removes the unit and all watcher state. Without an install, the stop guard may start a
# --transient loop (exits after OSRC_WATCH_IDLE_EXIT s with nothing owned) instead of yielding into
# silence; OSRC_WATCH_FALLBACK=0 or OSRC_FLEET_SUPERVISION=0 turns that off.

_ws_root() { printf '%s/watchsvc' "$OSRC_HOME"; }
_ws_stale() { _sv_num "${OSRC_WATCH_STALE:-}" 180; }
_ws_alive() { [ $(( $(_sv_now) - $(_sv_num "$(cat "$(_ws_root)/alive" 2>/dev/null)" 0) )) -le "$(_ws_stale)" ]; }
_ws_log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$(_ws_root)/service.log" 2>/dev/null; }
_ws_pid_ok() { kill -0 "$1" 2>/dev/null && case "$(ps -o command= -p "$1" 2>/dev/null)" in *" watcher run"*) true ;; *) false ;; esac; }
_ws_daemon_pid() { local p; p="$(cat "$(_ws_root)/run.lock/pid" 2>/dev/null)"; [ -n "$p" ] && _ws_pid_ok "$p" && printf '%s' "$p"; }

# ---- the loop ------------------------------------------------------------------------------------
_ws_run() { # [--transient]
  local transient=0 idle=0 iv tmo
  [ "${1:-}" = --transient ] && transient=1
  [ -f "$(_ws_root)/env" ] && [ -O "$(_ws_root)/env" ] && . "$(_ws_root)/env"   # PATH and knobs captured at install
  mkdir -p "$(_ws_root)" 2>/dev/null || return 1
  if ! mkdir "$(_ws_root)/run.lock" 2>/dev/null; then
    [ -n "$(_ws_daemon_pid)" ] && { echo "outsourcerer: watcher already running" >&2; return 0; }
    rm -rf "$(_ws_root)/run.lock"; mkdir "$(_ws_root)/run.lock" 2>/dev/null || return 0
  fi
  printf '%s\n' "$$" > "$(_ws_root)/run.lock/pid"
  trap '[ "$(cat "$(_ws_root)/run.lock/pid" 2>/dev/null)" = "$$" ] && rm -rf "$(_ws_root)/run.lock"' EXIT
  trap 'exit 0' INT TERM HUP
  iv="$(_sv_num "${OSRC_WATCH_INTERVAL:-}" 30)"; [ "$iv" -ge 1 ] || iv=30
  tmo="$(_sv_num "${OSRC_WATCH_TICK_TIMEOUT:-}" 300)"
  _ws_log "watcher run pid $$ every ${iv}s (transient=$transient)"
  while [ -d "$OSRC_HOME" ]; do
    _sv_bounded "$tmo" _ws_tick || _ws_log "tick failed or timed out (rc $?)"   # a hung probe never stops the loop
    if [ "$transient" = 1 ]; then
      if ls "$OSRC_HOME"/owners/*/* >/dev/null 2>&1; then idle=0; else idle=$((idle + iv)); fi
      [ "$idle" -lt "$(_sv_num "${OSRC_WATCH_IDLE_EXIT:-}" 1800)" ] || { _ws_log "transient watcher: nothing owned, exiting"; return 0; }
    fi
    sleep "$iv" & wait "$!" 2>/dev/null
  done
}

_ws_tick() {
  local d sid
  # A session seen for the first time starts here: rows logged from this tick on are owed a wake.
  _WS_T0="$(_sv_num "$({ wc -c < "$(_sv_lanes)/events.jsonl"; } 2>/dev/null | tr -d ' ')" 0)"
  _sv_observe_all watcher >/dev/null 2>&1 || true
  _ws_limits || true
  for d in "$OSRC_HOME"/owners/*/ "$(_ws_root)"/*/; do
    [ -d "$d" ] || continue
    sid="$(basename "$d")"; case "$sid" in run.lock|limits) continue ;; esac
    _ws_owner "$sid" || true
  done
  mkdir -p "$(_ws_root)" 2>/dev/null && printf '%s\n' "$(_sv_now)" > "$(_ws_root)/alive"
}

# ---- per owner -----------------------------------------------------------------------------------
# Rows since this owner's cursor that nobody delivered (supervise's ledger, which the watcher also
# writes); the cursor moves only when none is left, so a failed or blocked wake is retried, never dropped.
_ws_owner() { # <sid>
  local sid="$1" s f gen size cur cg rows older="" tj now cover att next last
  s="$(_ws_root)/$sid"; mkdir -p "$s" 2>/dev/null || return 1
  [ -f "$s/inflight" ] && { _ws_settle "$sid" "$s"; return 0; }
  now="$(_sv_now)"; f="$(_sv_lanes)/events.jsonl"
  gen="$(_sv_num "$(cat "$(_sv_lanes)/events.gen" 2>/dev/null)" 0)"
  size="$(_sv_num "$({ wc -c < "$f"; } 2>/dev/null | tr -d ' ')" 0)"; cur=""; cg=""
  if [ -f "$s/cursor" ]; then read -r cur cg 2>/dev/null < "$s/cursor"
  else # first sight: start where this session's supervise left off (its history was handled)
    read -r cur cg 2>/dev/null < "$OSRC_HOME/supervise/$sid/cursor" || { cur="${_WS_T0:-$size}"; cg="$gen"; }
  fi
  cur="$(_sv_num "$cur" 0)"; cg="$(_sv_num "$cg" "$gen")"
  if [ "$cg" != "$gen" ]; then
    [ "$cg" = $((gen - 1)) ] && older="$(_sv_read_range "$f.1" "$cur" - '[]' "$sid")"
    cur=0
  fi
  [ "$cur" -le "$size" ] || cur=0
  tj="$(ls -1 "$OSRC_HOME/owners/$sid" 2>/dev/null | jq -R . | jq -cs . 2>/dev/null)"
  rows="$(printf '%s\n%s' "$older" "$(_sv_read_range "$f" "$cur" "$size" "${tj:-[]}" "$sid")" | grep .)"
  rows="$(_sv_ledger_filter "$OSRC_HOME/supervise/$sid/delivered" "$rows" \
    | awk -F '\t' '$3 != "approved" && $3 != "nudged" && $3 != "limit-resumed"')"
  # Reminders of rows already woken for wake again only after OSRC_WATCH_REWAKE.
  last="$(_sv_num "$(cat "$s/sent" 2>/dev/null)" 0)"
  if [ -n "$rows" ] && [ -z "$(printf '%s\n' "$rows" | awk -F '\t' 'NF && $5 !~ /^still unresolved, waiting /')" ] \
     && [ $((now - last)) -lt "$(_sv_num "${OSRC_WATCH_REWAKE:-}" 3600)" ]; then rows=""; fi
  if [ -z "$rows" ]; then
    printf '%s %s\n' "$size" "$gen" > "$s/cursor"; rm -f "$s/pending"
    [ -d "$OSRC_HOME/owners/$sid" ] || [ -f "$s/pane" ] || rm -rf "$s"
    return 0
  fi
  printf '%s\n' "$rows" | grep -c . > "$s/pending"
  # A live, polling supervise delivers what it covers (`*` = everything).
  cover="$(_sv_armed_cover "$sid" 2>/dev/null)"
  if [ -n "$cover" ]; then
    printf '%s\n' "$cover" | grep -qxF '*' && return 0
    rows="$(printf '%s\n' "$rows" | awk -F '\t' 'NR == FNR { c[$1] = 1; next } NF && !c[$4]' <(printf '%s\n' "$cover") -)"
    [ -n "$rows" ] || return 0
  fi
  att=""; next=""; read -r att next 2>/dev/null < "$s/try"; att="$(_sv_num "$att" 0)"; next="$(_sv_num "$next" 0)"
  [ "$now" -ge "$next" ] || return 0
  _ws_start "$sid" "$s" "$rows"
}

# The wake: EVENT/NEXT lines (one per target, highest priority first, as supervise prints them) in
# a file, and a one-line message pointing at it (a tmux composer cannot take newlines).
_ws_start() { # <sid> <dir> <rows>
  local sid="$1" s="$2" rows="$3" ch w n kinds tab; tab="$(printf '\t')"
  w="$s/wake-$(_sv_now).txt"
  printf '%s\n' "$rows" | sort -t "$tab" -k1,1n -k2,2nr | awk -F '\t' '!seen[$4]++' \
    | while IFS="$tab" read -r _p ts kind tgt detail next _id; do printf 'EVENT %s %s %s %s\nNEXT %s\n' "$kind" "$tgt" "$ts" "$detail" "$next"; done > "$w"
  ls -1t "$s"/wake-*.txt 2>/dev/null | tail -n +21 | while IFS= read -r f; do rm -f "$f"; done
  n="$(grep -c '^EVENT ' "$w")"; kinds="$(awk '/^EVENT /{printf "%s%s:%s", sep, $2, $3; sep=" "}' "$w" | cut -c1-200)"
  printf '[outsourcerer] watcher: %s event(s) on lanes you own (%s). Read %s for the exact NEXT command of each and act on them. The watcher keeps watching; nothing to re-arm.' \
    "$n" "$kinds" "$w" > "$s/msg"
  printf '%s\n' "$rows" > "$s/rows"
  if ! ch="$(_ws_channel "$sid")"; then
    _ws_failed "$sid" "$s" "no channel reaches this session (it is not in tmux, no OSRC_WATCH_DELIVER_CMD, and resume is off or it is still open)"
    return 0
  fi
  rm -f "$s/rc"
  ( _ws_send "$ch" "$sid" "$s" "$w"; printf '%s\n' "$?" > "$s/rc" ) </dev/null >/dev/null 2>&1 &
  printf '%s %s %s\n' "$!" "$(_sv_now)" "$ch" > "$s/inflight"
}

_ws_settle() { # <sid> <dir>: finish an in-flight delivery once its result is in
  local sid="$1" s="$2" pid t0 ch rc t l i=0
  pid=""; t0=""; ch=""; read -r pid t0 ch 2>/dev/null < "$s/inflight"
  rc="$(cat "$s/rc" 2>/dev/null)"
  if [ -z "$rc" ]; then
    if kill -0 "$(_sv_num "$pid" 0)" 2>/dev/null; then
      [ $(( $(_sv_now) - $(_sv_num "$t0" 0) )) -ge "$(_sv_num "${OSRC_WATCH_DELIVER_TIMEOUT:-}" 1800)" ] || return 0
      kill "$pid" 2>/dev/null; rc=124
    else rc=1; fi
  fi
  rm -f "$s/inflight" "$s/rc"
  if [ "$rc" != 0 ]; then _ws_failed "$sid" "$s" "delivery via $ch failed (rc $rc)"; return 0; fi
  _ws_log "woke $sid via $ch: $(cat "$s/msg" 2>/dev/null | cut -c1-160)"
  l="$OSRC_HOME/supervise/$sid/delivered"; mkdir -p "${l%/*}" 2>/dev/null
  until _sv_lock_try "$l.lock" 30; do i=$((i + 1)); [ "$i" -lt 50 ] || break; sleep 0.1; done
  _sv_ledger_add "$l" "$(cat "$s/rows" 2>/dev/null)"; _sv_lock_rel "$l.lock"
  printf '%s\n' "$(_sv_now)" > "$s/sent"
  # A finished lane has been reported: drop its owner record as supervise would, or it re-reminds.
  for t in $(awk -F '\t' 'NF {print $4}' "$s/rows" 2>/dev/null | sort -u); do
    [ -f "$OSRC_HOME/owners/$sid/$t" ] || continue
    case "$(_owned_live_state "$t" 2>/dev/null)" in done|gone) rm -f "$OSRC_HOME/owners/$sid/$t" ;; esac
  done
  rm -f "$s/try" "$s/pending" "$s/rows" "$s/wakefail" "$OSRC_HOME/owners/$sid/.wakefail" 2>/dev/null
}

_ws_failed() { # <sid> <dir> <why>: back off 1 / 5 / 15 min (then every 15) and say so loudly
  local sid="$1" s="$2" att next max f
  att=""; read -r att next 2>/dev/null < "$s/try"; att=$(( $(_sv_num "$att" 0) + 1 ))
  case "$att" in 1) next=60 ;; 2) next=300 ;; *) next=900 ;; esac
  printf '%s %s\n' "$att" $(( $(_sv_now) + next )) > "$s/try"
  _ws_log "wake for $sid not delivered (attempt $att): $3"
  max="$(_sv_num "${OSRC_WATCH_WAKE_MAX:-}" 3)"; [ "$att" -ge "$max" ] || return 0
  f="$OSRC_HOME/owners/$sid/.wakefail"; [ -d "${f%/*}" ] || f="$s/wakefail"
  printf 'WAKE NOT DELIVERED: the watcher has %s lane event(s) for session %s and could not wake it after %s attempts: %s. Get them now: %s supervise --session %s\n' \
    "$(cat "$s/pending" 2>/dev/null || echo some)" "$sid" "$att" "$3" "$SCRIPT_PATH" "$sid" > "$f" 2>/dev/null
  [ $(( (att - max) % 4 )) = 0 ] && _ws_notify "outsourcerer: lane events waiting" "Session $sid has undelivered lane events. Run: outsourcerer supervise --session $sid"
  return 0
}

# ---- channels ------------------------------------------------------------------------------------
_ws_session_running() { # <sid>: a live Claude Code process registered this session id
  local f p
  for f in $(grep -lF "\"$1\"" "$OSRC_CLAUDE_SESSIONS_DIR"/*.json 2>/dev/null); do
    p="$(jq -r --arg s "$1" 'select(.sessionId == $s) | .pid // empty' "$f" 2>/dev/null)"
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && return 0
  done
  return 1
}
_ws_pane_ok() { # <sid> <pane>: the pane still runs THIS Claude Code session
  local pp; pp="$(tmux display-message -p -t "$2" '#{pane_pid}' 2>/dev/null)" || return 1
  [ "$(_fleet_cc_session_for_pane "$pp" "$(cat "$(_ws_root)/$1/cwd" 2>/dev/null)" 2>/dev/null | cut -f1)" = "$1" ]
}
_ws_channel() { # <sid> -> custom | tmux | resume
  local p cwd
  [ -n "${OSRC_WATCH_DELIVER_CMD:-}" ] && { printf custom; return 0; }
  p="$(cat "$(_ws_root)/$1/pane" 2>/dev/null)"
  if [ -n "$p" ] && [ "${OSRC_WATCH_TMUX:-1}" != 0 ] && have tmux && _ws_pane_ok "$1" "$p"; then printf tmux; return 0; fi
  cwd="$(cat "$(_ws_root)/$1/cwd" 2>/dev/null)"
  if [ "${OSRC_WATCH_RESUME:-0}" = 1 ] && [ -d "$cwd" ] && have claude && ! _ws_session_running "$1"; then printf resume; return 0; fi
  return 1
}
_ws_send() { # <channel> <sid> <dir> <wake-file>: rc 0 only with proof the session got it
  local ch="$1" sid="$2" s="$3" w="$4" msg p cap base bhist snip
  msg="$(cat "$s/msg")"
  case "$ch" in
    custom) OSRC_WAKE_SESSION="$sid" OSRC_WAKE_EVENT="$(cat "$w")" sh -c "$OSRC_WATCH_DELIVER_CMD" osrc-watch "$msg" < "$w" ;;
    resume) cd "$(cat "$s/cwd")" && claude -p --resume "$sid" "$msg
$(cat "$w")" ;;
    tmux)
      p="$(cat "$s/pane")"; cap="$(tmux capture-pane -p -t "$p" 2>/dev/null)" || return 4
      _osrc_screen_analyze_text cc <<<"$cap"; base="$OSRC_SCR_STATE"
      # Only into an empty composer of an idle session: never over the user's typing or a prompt.
      [ "${OSRC_SCR_COMPOSER_FOUND:-0}" = 1 ] && [ -z "$(printf '%s' "$OSRC_SCR_COMPOSER" | tr -d ' \t\n')" ] || return 5
      case "$base" in idle|composer|limit|done) ;; *) return 5 ;; esac
      snip="$(printf '%s' "$msg" | cut -c1-24)"; bhist="$(_osrc_scr_history_count "$snip")"
      tmux send-keys -t "$p" -l -- "$msg" && tmux send-keys -t "$p" Enter || return 1
      _osrc_send_verify_screen "$p" cc "$snip" "$base" "$bhist" 0 ;;
    *) return 1 ;;
  esac
}

_ws_notify() { # <title> <body>: best effort, never blocks
  [ "${OSRC_WATCH_NOTIFY:-1}" = 0 ] && return 0
  case "${OSRC_PLATFORM:-}" in
    mac) command -v osascript >/dev/null 2>&1 && osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$1" "$2" >/dev/null 2>&1 </dev/null & ;;
    linux) command -v notify-send >/dev/null 2>&1 && notify-send "$1" "$2" >/dev/null 2>&1 </dev/null & ;;
  esac
  return 0
}

# ---- provider limits -----------------------------------------------------------------------------
# A `limit` row is remembered per lane with its reset epoch (limits/<id>: "<epoch>"); once that time
# has passed and the lane still shows a limit, it gets one `continue` and limits/<id>.done records
# the epoch, so a reset is answered once. A lane that moved on (no longer limit-parked) is forgotten.
_ws_limits() {
  [ "${OSRC_WATCH_LIMIT_AUTO:-1}" = 0 ] && return 0
  local d f cur size now t detail ts ep secs ph
  d="$(_ws_root)/limits"; mkdir -p "$d" 2>/dev/null || return 1
  f="$(_sv_lanes)/events.jsonl"; now="$(_sv_now)"
  size="$(_sv_num "$({ wc -c < "$f"; } 2>/dev/null | tr -d ' ')" 0)"
  cur="$(_sv_num "$(cat "$d/.cursor" 2>/dev/null)" "$size")"; [ "$cur" -le "$size" ] || cur=0
  while IFS="$(printf '\t')" read -r t detail ts; do
    case "$t" in ''|*/*|.*) continue ;; esac
    ls "$OSRC_HOME"/owners/*/"$t" >/dev/null 2>&1 || continue   # only lanes someone still owns
    ep="$(printf '%s' "$detail" | grep -oE 'epoch [0-9]+' | grep -oE '[0-9]+' | head -1)"
    if [ -z "$ep" ]; then
      ph="$(printf '%s' "$detail" | grep -oiE '(resets?|try again)[[:space:]][^·|]*' | head -1)"
      secs="$(_lane_limit_reset_secs "$ph" 2>/dev/null)"; case "$secs" in ''|*[!0-9]*) continue ;; esac
      case "$ph" in *" in "*) ep=$(( $(_sv_num "$ts" "$now") + secs )) ;; *) ep=$((now + secs)) ;; esac
    fi
    printf '%s\n' "$ep" > "$d/$t"
  done < <(tail -c +"$((cur + 1))" "$f" 2>/dev/null | head -c "$((size - cur))" \
    | jq -r 'select(type == "object" and .kind == "limit") | [.target, .detail, (.ts | tostring)] | map(tostring | gsub("[\t\n]"; " ")) | join("\t")' 2>/dev/null)
  printf '%s\n' "$size" > "$d/.cursor"
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    t="${f##*/}"; case "$t" in *.done) continue ;; esac
    ep="$(_sv_num "$(cat "$f")" 0)"
    _sv_state_read "$t"
    case "$SVS_LK" in limit:*) ;; *) rm -f "$f" "$f.done"; continue ;; esac   # moved on: not ours to continue
    [ "$now" -ge "$ep" ] || continue
    [ "$(cat "$f.done" 2>/dev/null)" = "$ep" ] && continue
    printf '%s\n' "$ep" > "$f.done"
    OUTSOURCERER_TMUX="$t" OSRC_STREAM=1 "$SCRIPT_PATH" session send "continue" >/dev/null 2>&1 </dev/null
    _sv_append limit-resumed "$t" "sent one 'continue' after the provider limit reset (epoch $ep)" \
      "OUTSOURCERER_TMUX=$t $SCRIPT_PATH session read" watcher "$(basename "$(dirname "$(ls -1 "$OSRC_HOME"/owners/*/"$t" 2>/dev/null | head -1)")")"
  done
}

# ---- session notes (stop guard) and the fallback loop ------------------------------------------------
_ws_note_session() { # <sid> <cwd>: what a channel needs, recorded from inside the session's hook
  local s; s="$(_ws_root)/$1"; mkdir -p "$s" 2>/dev/null || return 0
  [ -n "${2:-}" ] && [ -d "$2" ] && printf '%s\n' "$2" > "$s/cwd"
  if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then printf '%s\n' "$TMUX_PANE" > "$s/pane"; fi
  return 0
}
# The watcher reaches <sid>: alive, and a channel exists right now.
_ws_covers() { _ws_alive && _ws_channel "$1" >/dev/null 2>&1; }

_ws_spawn() { # [--transient]: start the detached loop unless one runs; never blocks the caller
  [ "${OSRC_WATCH_FALLBACK:-1}" != 0 ] && [ "${OSRC_FLEET_SUPERVISION:-1}" != 0 ] || return 1
  [ "${1:-}" != --transient ] || [ "${OSRC_HEARTBEAT_DISABLED:-0}" != 1 ] || return 1
  [ -n "$(_ws_daemon_pid)" ] && return 0
  mkdir -p "$(_ws_root)" 2>/dev/null || return 1
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$SCRIPT_PATH" watcher run "$@" </dev/null >>"$(_ws_root)/service.log" 2>&1 7>&- 8>&- 9>&- &
  else
    nohup "$SCRIPT_PATH" watcher run "$@" </dev/null >>"$(_ws_root)/service.log" 2>&1 7>&- 8>&- 9>&- &
  fi
  return 0
}
# Called by the stop guard: an installed fallback loop that died comes back; otherwise a transient one.
_ws_ensure() {
  _ws_alive && [ -n "$(_ws_daemon_pid)" ] && return 0
  if [ -f "$(_ws_root)/installed" ]; then _ws_spawn; else _ws_spawn --transient; fi
}

# ---- install -------------------------------------------------------------------------------------
_ws_backend() {
  case "${OSRC_WATCH_BACKEND:-}" in launchd|systemd|fallback) printf '%s' "$OSRC_WATCH_BACKEND"; return 0 ;; esac
  if [ "${OSRC_PLATFORM:-}" = mac ] && command -v launchctl >/dev/null 2>&1; then printf launchd
  elif [ "${OSRC_PLATFORM:-}" = linux ] && command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then printf systemd
  else printf fallback; fi
}
_ws_unit() { case "$1" in launchd) printf '%s/com.outsourcerer.watcher.plist' "${OSRC_WATCH_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}" ;;
  systemd) printf '%s/outsourcerer-watcher.service' "${OSRC_WATCH_SYSTEMD_DIR:-$HOME/.config/systemd/user}" ;; esac; }
_ws_xml() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

_ws_install() {
  local be u v; be="$(_ws_backend)"; u="$(_ws_unit "$be")"
  mkdir -p "$(_ws_root)" || return 1
  # launchd/systemd start with a bare PATH and none of the user's knobs: capture them now.
  { printf 'export PATH=%q\n' "$PATH"
    for v in $(env | sed -n 's/^\(OSRC_WATCH_[A-Z_]*\)=.*/\1/p'); do printf 'export %s=%q\n' "$v" "${!v}"; done; } > "$(_ws_root)/env"
  case "$be" in
    systemd)
      mkdir -p "${u%/*}" && printf '[Unit]\nDescription=Outsourcerer lane watcher\n\n[Service]\nExecStart=/bin/bash "%s" watcher run\nEnvironment="OSRC_HOME=%s"\nRestart=always\nRestartSec=10\nNice=10\n\n[Install]\nWantedBy=default.target\n' \
        "$SCRIPT_PATH" "$OSRC_HOME" > "$u" \
        && systemctl --user daemon-reload && systemctl --user enable outsourcerer-watcher.service >/dev/null 2>&1 \
        && systemctl --user restart outsourcerer-watcher.service || { echo "outsourcerer: systemd --user install failed" >&2; return 1; } ;;
    launchd)
      mkdir -p "${u%/*}" && printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n<key>Label</key><string>com.outsourcerer.watcher</string>\n<key>ProgramArguments</key><array><string>/bin/bash</string><string>%s</string><string>watcher</string><string>run</string></array>\n<key>EnvironmentVariables</key><dict><key>OSRC_HOME</key><string>%s</string></dict>\n<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ProcessType</key><string>Background</string>\n</dict></plist>\n' \
        "$(_ws_xml "$SCRIPT_PATH")" "$(_ws_xml "$OSRC_HOME")" > "$u" || return 1
      launchctl bootout "gui/$(id -u)/com.outsourcerer.watcher" >/dev/null 2>&1
      launchctl bootstrap "gui/$(id -u)" "$u" || { echo "outsourcerer: launchctl bootstrap failed" >&2; return 1; } ;;
    *) OSRC_WATCH_FALLBACK=1 OSRC_FLEET_SUPERVISION=1 _ws_spawn || return 1 ;;
  esac
  printf '%s\n' "$be" > "$(_ws_root)/installed"
  echo "outsourcerer: watcher installed ($be${u:+, $u}). It watches every session's lanes, wakes the owning session, and continues limit-parked lanes after the reset. Remove: $SCRIPT_PATH watcher uninstall"
}

_ws_uninstall() {
  local be p i; be="$(cat "$(_ws_root)/installed" 2>/dev/null)"
  case "$be" in
    systemd) systemctl --user disable --now outsourcerer-watcher.service >/dev/null 2>&1; rm -f "$(_ws_unit systemd)"; systemctl --user daemon-reload >/dev/null 2>&1 ;;
    launchd) launchctl bootout "gui/$(id -u)/com.outsourcerer.watcher" >/dev/null 2>&1; rm -f "$(_ws_unit launchd)" ;;
  esac
  if p="$(_ws_daemon_pid)"; then
    kill "$p" 2>/dev/null; i=0; while kill -0 "$p" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  fi
  rm -rf "$(_ws_root)"
  echo "outsourcerer: watcher uninstalled${be:+ ($be)}; its unit and state are gone."
}

_ws_status() {
  local p d sid n=0 rc=0
  p="$(_ws_daemon_pid)"
  printf 'watcher: installed=%s daemon=%s last_tick=%ss ago\n' "$(cat "$(_ws_root)/installed" 2>/dev/null || echo no)" "${p:-not-running}" \
    "$(( $(_sv_now) - $(_sv_num "$(cat "$(_ws_root)/alive" 2>/dev/null)" 0) ))"
  _ws_alive || { echo "coverage: NONE (no tick within $(_ws_stale)s). Install: $SCRIPT_PATH watcher install"; rc=3; }
  for d in "$(_ws_root)"/*/; do
    [ -f "$d/pending" ] || continue; sid="$(basename "$d")"; n=$((n + 1))
    printf '  %s: %s event(s) pending, channel=%s%s\n' "$sid" "$(cat "$d/pending")" "$(_ws_channel "$sid" 2>/dev/null || echo none)" \
      "$( [ -s "$OSRC_HOME/owners/$sid/.wakefail" ] || [ -s "$d/wakefail" ] && echo ', DELIVERY FAILING')"
  done
  [ "$n" -gt 0 ] || echo "  no undelivered events"
  return "$rc"
}

cmd_watcher() {
  local sub="${1:-status}"; shift 2>/dev/null
  case "$sub" in
    install) _ws_install ;;
    uninstall) _ws_uninstall ;;
    status) _ws_status ;;
    run) _ws_run "$@" ;;
    tick) _ws_tick ;;
    -h|--help|help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) echo "usage: $SCRIPT_PATH watcher install|uninstall|status|run [--transient]|tick" >&2; return 2 ;;
  esac
}
