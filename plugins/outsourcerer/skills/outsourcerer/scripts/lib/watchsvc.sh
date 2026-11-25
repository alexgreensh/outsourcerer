# shellcheck shell=bash
# lib/watchsvc.sh: the per-user watcher, a waiter nobody has to re-arm.
#
#   outsourcerer.sh watcher install | uninstall | status | run
#
# `supervise` only helps while a session keeps one armed; when it is forgotten, killed or reaped,
# nothing watches that session's lanes (a watcher died at 02:36 and nine finished lanes waited
# 4-6 h). The watcher is one shell loop per user that does, every OSRC_WATCH_INTERVAL seconds
# (default 30), what supervise does for one session, for every owner:
#   1. observe every owned lane (_sv_observe_all): finished, idle, stalled, question/approval,
#      limit-hit rows land in lanes/events.jsonl. Files and screens only: zero model tokens.
#   2. installed only: send ONE `continue` to a lane parked on a provider limit once that limit's
#      reset time has passed, once per reset, and only while the lane still shows that limit.
#   3. wake each owner that has undelivered rows and no live supervise, through the first channel
#      that can reach it: OSRC_WATCH_DELIVER_CMD (summary as $1, EVENT/NEXT lines on stdin), or,
#      installed only, the session's own tmux pane (recorded by the stop guard, typed only into an
#      empty Claude Code composer, screen-verified). A delivery counts only when the channel proves
#      it (exit 0 / screen proof); failures retry with backoff (1, 5, then every 15 min, forever) and,
#      after OSRC_WATCH_WAKE_MAX (3) attempts, owners/<sid>/.wakefail is printed by every outsourcerer
#      call and one OS notification is shown. Delivered rows go into supervise's delivered ledger, so
#      the session never sees them twice. Repeated "still unresolved" reminders wake again at most
#      once per OSRC_WATCH_REWAKE seconds (default 3600).
# WAKING NEEDS TMUX OR A DELIVERY COMMAND. A Claude Code session in a plain terminal, an IDE or the
# desktop app cannot be typed into from outside; for it the watcher only observes and notifies, and
# the stop guard keeps asking for `supervise` instead of counting the watcher as a waiter.
# Backends: launchd (macOS), systemd --user (Linux), else a detached loop that any outsourcerer call
# restarts while installed (Windows Git Bash, containers). The unit runs watchsvc/launch, which every
# call repoints at the current plugin copy. `install` is explicit and idempotent; `uninstall` removes
# every backend's unit and all watcher state. Nothing else ever starts the watcher.

_ws_root() { printf '%s/watchsvc' "$OSRC_HOME"; }
_ws_stale() { _sv_num "${OSRC_WATCH_STALE:-}" 360; }   # > tick timeout + interval, so a slow tick gets no rival
_ws_alive() { [ $(( $(_sv_now) - $(_sv_num "$(cat "$(_ws_root)/alive" 2>/dev/null)" 0) )) -le "$(_ws_stale)" ]; }
_ws_log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$(_ws_root)/service.log" 2>/dev/null; }
# Git Bash `ps` has no -o: a live pid then counts only while the loop's alive stamp is fresh.
_ws_pid_ok() { kill -0 "$1" 2>/dev/null && case "$(ps -o command= -p "$1" 2>/dev/null)" in '') _ws_alive ;; *" watcher run"*) true ;; *) false ;; esac; }
# <pid> was forked by this loop: same command line as $$ (nothing to compare without `ps -o`: not provable).
_ws_ours() { local c; c="$(ps -o command= -p "$1" 2>/dev/null)"; [ -n "$c" ] && [ "$c" = "$(ps -o command= -p "$$" 2>/dev/null)" ]; }
_ws_daemon_pid() { local p; p="$(cat "$(_ws_root)/run.lock/pid" 2>/dev/null)"; [ -n "$p" ] && _ws_pid_ok "$p" && printf '%s' "$p"; }
_ws_env() { # the daemon's settings are the ones captured at install, not whatever the caller has set
  local v; [ -f "$(_ws_root)/env" ] && [ -O "$(_ws_root)/env" ] || return 0
  unset TMUX TMUX_PANE TMUX_TMPDIR   # the daemon's tmux server is the one captured at install, not the caller's
  for v in $(env | sed -n 's/^\(OSRC_WATCH_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
  . "$(_ws_root)/env"
}

# ---- the loop ------------------------------------------------------------------------------------
_ws_run() {
  local iv tmo l
  _ws_env
  mkdir -p "$(_ws_root)" 2>/dev/null || return 1
  l="$(_ws_root)/run.lock"
  if ! mkdir "$l" 2>/dev/null; then
    [ -n "$(_ws_daemon_pid)" ] && { echo "outsourcerer: watcher already running" >&2; return 0; }
    # a starter that has not published its pid yet keeps the lock for 10 s
    [ -f "$l/pid" ] || [ $(( $(_sv_now) - $(_sv_num "$(stat -c %Y "$l" 2>/dev/null || stat -f %m "$l" 2>/dev/null)" 0) )) -ge 10 ] || { echo "outsourcerer: watcher already starting" >&2; return 0; }
    rm -rf "$l"; mkdir "$l" 2>/dev/null || return 0
  fi
  printf '%s\n' "$$" > "$l/pid"; _sv_now > "$(_ws_root)/alive"   # known as alive from its first second (no `ps -o`)
  trap '_sv_bounded_kill; [ "$(cat "$(_ws_root)/run.lock/pid" 2>/dev/null)" = "$$" ] && rm -rf "$(_ws_root)/run.lock"' EXIT
  trap 'exit 0' INT TERM HUP
  iv="$(_sv_num "${OSRC_WATCH_INTERVAL:-}" 30)"; [ "$iv" -ge 1 ] || iv=30
  tmo="$(_sv_num "${OSRC_WATCH_TICK_TIMEOUT:-}" 300)"
  _ws_log "watcher run pid $$ every ${iv}s"
  # The lock is re-checked every pass: a loop whose lock was taken over (or removed by uninstall) exits.
  # One whose launcher now names another plugin copy re-runs itself from there, on every backend.
  while [ -d "$OSRC_HOME" ] && [ "$(cat "$l/pid" 2>/dev/null)" = "$$" ] \
        && { [ ! -f "$(_ws_root)/launch" ] || grep -qxF "# script: $SCRIPT_PATH" "$(_ws_root)/launch"; }; do
    _sv_bounded "$tmo" _ws_tick || _ws_log "tick failed or timed out (rc $?)"   # a hung probe never stops the loop
    sleep "$iv" & wait "$!" 2>/dev/null
  done
  [ -f "$(_ws_root)/installed" ] && [ -f "$(_ws_root)/launch" ] && [ "$(cat "$l/pid" 2>/dev/null)" = "$$" ] && { rm -rf "$l"; trap - EXIT; exec "$BASH" "$(_ws_root)/launch"; }
}

_ws_tick() {
  local sid r f; r="$(_ws_root)"; _sv_now > "$r/alive" 2>/dev/null   # stamped as it starts: a long tick is still a live loop
  # A session seen for the first time starts here: rows logged from this tick on are owed a wake.
  _WS_T0="$(_sv_num "$({ wc -c < "$(_sv_lanes)/events.jsonl"; } 2>/dev/null | tr -d ' ')" 0)"
  _sv_observe_all watcher >/dev/null 2>&1 || true
  _ws_limits || true
  for sid in $({ ls -1 "$OSRC_HOME/owners"; ls -1 "$r"; } 2>/dev/null | sort -u); do
    case "$sid" in run.lock|limits) continue ;; esac
    [ -d "$OSRC_HOME/owners/$sid" ] || [ -d "$r/$sid" ] || continue
    _ws_owner "$sid" || true
  done
  f="$r/service.log"
  [ "$(_sv_num "$({ wc -c < "$f"; } 2>/dev/null | tr -d ' ')" 0)" -le 262144 ] || { tail -c 65536 "$f" > "$f.1" && mv -f "$f.1" "$f"; }
  return 0
}

# ---- per owner -----------------------------------------------------------------------------------
# Rows since this owner's cursor that nobody delivered (supervise's ledger, which the watcher also
# writes); the cursor moves only when none is left, so a failed or blocked wake is retried, never dropped.
_ws_owner() { # <sid>
  local sid="$1" s f gen size cur cg rows older="" tj now cover last
  s="$(_ws_root)/$sid"; mkdir -p "$s" 2>/dev/null || return 1
  [ -f "$s/inflight" ] && { _ws_settle "$sid" "$s"; return 0; }
  # Its lanes live on a tmux server this watcher cannot see: clear what this watcher left, then skip.
  _ws_foreign "$sid" && { rm -f "$OSRC_HOME/owners/$sid/.wakefail"; [ -d "$OSRC_HOME/owners/$sid" ] || rm -rf "$s"; return 0; }
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
    # Nothing owed (delivered by us or by a supervise): any failure notice is stale now.
    printf '%s %s\n' "$size" "$gen" > "$s/cursor"
    rm -f "$s/pending" "$s/try" "$s/wakefail" "$OSRC_HOME/owners/$sid/.wakefail"
    rmdir "$OSRC_HOME/owners/$sid" 2>/dev/null   # owns nothing, owed nothing: out (a marker written across it is lost; microseconds)
    [ -d "$OSRC_HOME/owners/$sid" ] || rm -rf "$s"
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
  _ws_due "$s/try" || return 0
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
    _ws_failed "$sid" "$s" "no channel reaches this session (not in tmux with an installed watcher, and no OSRC_WATCH_DELIVER_CMD)"
    return 0
  fi
  rm -f "$s/rc"
  ( _ws_send "$ch" "$sid" "$s" "$w"; printf '%s\n' "$?" > "$s/rc" ) </dev/null >/dev/null 2>&1 &
  printf '%s %s %s %s\n' "$!" "$(_sv_now)" "$ch" "$$" > "$s/inflight"
}

_ws_settle() { # <sid> <dir>: finish an in-flight delivery once its result is in
  local sid="$1" s="$2" pid t0 ch own rc t l i=0
  pid=""; t0=""; ch=""; own=""; read -r pid t0 ch own 2>/dev/null < "$s/inflight"
  rc="$(cat "$s/rc" 2>/dev/null)"
  if [ -z "$rc" ]; then
    # A live delivery is pending until its rc or the timeout, also one an earlier loop started (a
    # restart must not fail it while it lands). Only THIS loop's own fork is ever signalled.
    # A reused pid (reboot, crash) is no delivery: pending only while it is still a watcher fork.
    local cmd; cmd="$(ps -o command= -p "$(_sv_num "$pid" 0)" 2>/dev/null)"
    if kill -0 "$(_sv_num "$pid" 0)" 2>/dev/null && case "$cmd" in ''|*" watcher run"*) true ;; *) false ;; esac; then
      [ $(( $(_sv_now) - $(_sv_num "$t0" 0) )) -ge "$(_sv_num "${OSRC_WATCH_DELIVER_TIMEOUT:-}" 1800)" ] || return 0
      [ "$own" = "$$" ] && _ws_ours "$pid" && _kill_tree "$pid" 2>/dev/null; rc=124   # the whole delivery, not just its wrapper
    else rc="$(cat "$s/rc" 2>/dev/null)"; rc="${rc:-1}"; fi   # it may have finished since the first read
  fi
  if [ "$rc" = 0 ]; then
    # The ledger is shared with supervise: without its lock, try again next tick rather than race it.
    l="$OSRC_HOME/supervise/$sid/delivered"; mkdir -p "${l%/*}" 2>/dev/null
    until _sv_lock_try "$l.lock" 30; do i=$((i + 1)); [ "$i" -lt 50 ] || return 0; sleep 0.1; done
    _sv_ledger_add "$l" "$(cat "$s/rows" 2>/dev/null)"; _sv_lock_rel "$l.lock"
  fi
  rm -f "$s/inflight" "$s/rc"
  if [ "$rc" != 0 ]; then _ws_failed "$sid" "$s" "delivery via $ch failed (rc $rc)"; return 0; fi
  _ws_log "woke $sid via $ch: $(cat "$s/msg" 2>/dev/null | cut -c1-160)"
  printf '%s\n' "$(_sv_now)" > "$s/sent"
  # A finished lane has been reported: drop its owner record as supervise would, or it re-reminds.
  for t in $(awk -F '\t' 'NF {print $4}' "$s/rows" 2>/dev/null | sort -u); do
    [ -f "$OSRC_HOME/owners/$sid/$t" ] || continue
    case "$(_owned_live_state "$t" 2>/dev/null)" in
      done|gone) rm -f "$OSRC_HOME/owners/$sid/$t"
        type osrc_hub_seen_lane >/dev/null 2>&1 && osrc_hub_seen_lane "$sid" "$t" ;;
    esac
  done
  rm -f "$s/try" "$s/pending" "$s/rows" "$s/wakefail" "$OSRC_HOME/owners/$sid/.wakefail" 2>/dev/null
}

_ws_backoff() { # <try-file> -> attempts so far; the next one is due in 1 / 5 / 15 min (then every 15)
  local att next; att=""; read -r att next 2>/dev/null < "$1"; att=$(( $(_sv_num "$att" 0) + 1 ))
  case "$att" in 1) next=60 ;; 2) next=300 ;; *) next=900 ;; esac
  printf '%s %s\n' "$att" $(( $(_sv_now) + next )) > "$1"; printf '%s' "$att"
}
_ws_due() { local att next; att=""; next=""; read -r att next 2>/dev/null < "$1"; [ "$(_sv_now)" -ge "$(_sv_num "$next" 0)" ]; }
_ws_failed() { # <sid> <dir> <why>: back off and say so loudly, once
  local sid="$1" s="$2" att max f
  att="$(_ws_backoff "$s/try")"
  _ws_log "wake for $sid not delivered (attempt $att): $3"
  max="$(_sv_num "${OSRC_WATCH_WAKE_MAX:-}" 3)"; [ "$att" -ge "$max" ] || return 0
  f="$OSRC_HOME/owners/$sid/.wakefail"; [ -d "${f%/*}" ] || f="$s/wakefail"
  printf 'WAKE NOT DELIVERED: the watcher has %s lane event(s) for session %s and could not wake it after %s attempts: %s. Get them now: %s supervise --session %s\n' \
    "$(cat "$s/pending" 2>/dev/null || echo some)" "$sid" "$att" "$3" "$SCRIPT_PATH" "$sid" > "$f" 2>/dev/null
  [ "$att" = "$max" ] && _ws_notify "outsourcerer: lane events waiting" "Session $sid has undelivered lane events. Run: outsourcerer supervise --session $sid"
  return 0
}

# ---- channels ------------------------------------------------------------------------------------
# The tmux server this process's tmux talks to ($TMUX's socket, else the default), directory resolved as tmux does.
_ws_sock() { local t="${TMUX:-}" d; t="${t%%,*}"; [ -n "$t" ] || t="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/default"
  d="$(cd "${t%/*}" 2>/dev/null && pwd -P)" || d="${t%/*}"; printf '%s/%s' "$d" "${t##*/}"; }
_ws_foreign() { local k; k="$(cat "$(_ws_root)/$1/sock" 2>/dev/null)" && [ -n "$k" ] && [ "$k" != "$(_ws_sock)" ]; }
_ws_pane_ok() { # <sid> <pane>: the pane still runs THIS Claude Code session
  local pp; pp="$(tmux display-message -p -t "$2" '#{pane_pid}' 2>/dev/null)" || return 1
  [ "$(_fleet_cc_session_for_pane "$pp" "$(cat "$(_ws_root)/$1/cwd" 2>/dev/null)" 2>/dev/null | cut -f1)" = "$1" ]
}
_ws_channel() { # <sid> -> custom | tmux
  local p
  _ws_foreign "$1" && return 1   # on another tmux server (`tmux -L/-S`, TMUX_TMPDIR): out of reach, whatever the channel
  [ -n "${OSRC_WATCH_DELIVER_CMD:-}" ] && { printf custom; return 0; }
  [ -f "$(_ws_root)/installed" ] || return 1   # typing into the user's pane is for a watcher they installed
  p="$(cat "$(_ws_root)/$1/pane" 2>/dev/null)"
  [ -n "$p" ] && have tmux && _ws_pane_ok "$1" "$p" && { printf tmux; return 0; }
  return 1
}
_ws_send() { # <channel> <sid> <dir> <wake-file>: rc 0 only with proof the session got it
  local ch="$1" sid="$2" s="$3" w="$4" msg p cap base bhist snip
  msg="$(cat "$s/msg")"
  case "$ch" in
    custom) OSRC_WAKE_SESSION="$sid" OSRC_WAKE_EVENT="$(cat "$w")" sh -c "$OSRC_WATCH_DELIVER_CMD" osrc-watch "$msg" < "$w" ;;
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

# ---- provider limits (installed watcher only) ---------------------------------------------------
# The FIRST `limit` row of a banner is remembered per lane with its reset epoch (limits/<id>:
# "<epoch>"); its "still unresolved" reminders are ignored, so a relative "try again in 2 hours" or a
# recomputed epoch never pushes the reset later. Once that time has passed and the lane still shows a
# limit, it gets one `continue`; limits/<id>.done records the epoch once the send went out, so a reset
# is answered once and a failed send is retried with backoff (limits/<id>.try). A lane that moved on,
# or that nobody owns any more when the send is due, is forgotten. With no cursor yet (first run, or a
# reinstall) the whole log is read, so a lane parked on a limit before the install is still continued.
_ws_limits() {
  [ "${OSRC_WATCH_LIMIT_AUTO:-1}" = 0 ] && return 0
  [ -f "$(_ws_root)/installed" ] || return 0
  local d f cur cg c2 gen size now t detail ts ep secs ph rc older=""
  d="$(_ws_root)/limits"; mkdir -p "$d" 2>/dev/null || return 1
  f="$(_sv_lanes)/events.jsonl"; now="$(_sv_now)"
  size="$(_sv_num "$({ wc -c < "$f"; } 2>/dev/null | tr -d ' ')" 0)"
  gen="$(_sv_num "$(cat "$(_sv_lanes)/events.gen" 2>/dev/null)" 0)"
  cur=""; cg=""; read -r cur cg 2>/dev/null < "$d/.cursor"; cur="$(_sv_num "$cur" 0)"; cg="$(_sv_num "$cg" "$gen")"
  if [ "$cg" != "$gen" ]; then   # the log rotated: finish the old file, then read the new one whole
    [ "$cg" = $((gen - 1)) ] && older="$f.1"
    [ -n "$older" ] || cur=0
  fi
  [ -n "$older" ] || [ "$cur" -le "$size" ] || cur=0
  c2="$cur"; [ -z "$older" ] || c2=0
  while IFS="$(printf '\t')" read -r t detail ts; do
    case "$t" in ''|*/*|.*) continue ;; esac
    ep="$(printf '%s' "$detail" | grep -oE 'epoch [0-9]+' | grep -oE '[0-9]+' | head -1)"
    if [ -z "$ep" ]; then
      ph="$(printf '%s' "$detail" | grep -oiE '(resets?|try again)[[:space:]][^·|]*' | head -1)"
      secs="$(_lane_limit_reset_secs "$ph" 2>/dev/null)"; case "$secs" in ''|*[!0-9]*) continue ;; esac
      case "$ph" in *" in "*) ep=$(( $(_sv_num "$ts" "$now") + secs )) ;; *) ep=$((now + secs)) ;; esac
    fi
    printf '%s\n' "$ep" > "$d/$t"; rm -f "$d/$t.try"   # a new banner starts without the old backoff
  done < <({ [ -z "$older" ] || tail -c +"$((cur + 1))" "$older"; tail -c +"$((c2 + 1))" "$f" | head -c "$((size - c2))"; } 2>/dev/null \
    | jq -r 'select(type == "object" and .kind == "limit" and ((.detail // "") | tostring | startswith("still unresolved, waiting ") | not))
             | [.target, .detail, (.ts | tostring)] | map(tostring | gsub("[\t\n]"; " ")) | join("\t")' 2>/dev/null)
  printf '%s %s\n' "$size" "$gen" > "$d/.cursor"
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    t="${f##*/}"; case "$t" in *.done|*.try) continue ;; esac
    ep="$(_sv_num "$(cat "$f")" 0)"
    _sv_state_read "$t"
    # Not owned any more (checked at send time), or moved on: not ours to continue.
    { ls "$OSRC_HOME"/owners/*/"$t" >/dev/null 2>&1 && case "$SVS_LK" in limit:*) true ;; *) false ;; esac; } || { rm -f "$f" "$f.done" "$f.try"; continue; }
    [ "$now" -ge "$ep" ] || continue
    [ "$(cat "$f.done" 2>/dev/null)" = "$ep" ] && continue
    _ws_due "$f.try" || continue
    OUTSOURCERER_TMUX="$t" OSRC_STREAM=1 "$SCRIPT_PATH" session send "continue" >/dev/null 2>&1 </dev/null; rc=$?
    # rc 0 verified, rc 2 submitted but unverified (never resend: that would be a second continue).
    case "$rc" in 0|2) ;; *) _ws_log "continue to $t after its limit reset failed (rc $rc; attempt $(_ws_backoff "$f.try")), retrying with backoff"; continue ;; esac
    printf '%s\n' "$ep" > "$f.done"; rm -f "$f.try"
    _sv_append limit-resumed "$t" "sent one 'continue' after the provider limit reset (epoch $ep)$([ "$rc" = 2 ] && printf ', delivery not verified')" \
      "OUTSOURCERER_TMUX=$t $SCRIPT_PATH session read" watcher "$(basename "$(dirname "$(ls -1 "$OSRC_HOME"/owners/*/"$t" 2>/dev/null | head -1)")")"
  done
}

# ---- session notes (stop guard) ------------------------------------------------------------------
_ws_note_session() { # <sid> <cwd>: what a channel needs, recorded from inside the session's hook
  local s; s="$(_ws_root)/$1"
  [ -f "$(_ws_root)/installed" ] || [ -d "$(_ws_root)/run.lock" ] || return 0   # no watcher on this machine: no state
  mkdir -p "$s" 2>/dev/null || return 0
  [ -n "${2:-}" ] && [ -d "$2" ] && printf '%s\n' "$2" > "$s/cwd"
  if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then printf '%s\n' "$TMUX_PANE" > "$s/pane"; _ws_sock > "$s/sock"; fi
  return 0
}
# The watcher reaches <sid>: a live, recently ticking loop with a channel judged by ITS settings.
# A channel that keeps failing (.wakefail) is no waiter: the guard keeps the turn open instead.
_ws_covers() { _ws_alive && [ -n "$(_ws_daemon_pid)" ] && [ ! -s "$OSRC_HOME/owners/$1/.wakefail" ] && ( unset TMUX TMUX_PANE TMUX_TMPDIR; _ws_env; _ws_channel "$1" >/dev/null 2>&1 ); }

# ---- install -------------------------------------------------------------------------------------
_ws_spawn() { # start the detached loop unless one runs; never blocks the caller
  [ -n "$(_ws_daemon_pid)" ] && return 0
  mkdir -p "$(_ws_root)" 2>/dev/null || return 1
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$SCRIPT_PATH" watcher run </dev/null >>"$(_ws_root)/service.log" 2>&1 7>&- 8>&- 9>&- &
  else
    nohup "$SCRIPT_PATH" watcher run </dev/null >>"$(_ws_root)/service.log" 2>&1 7>&- 8>&- 9>&- &
  fi
  return 0
}
_ws_stop_loop() { local p i=0; p="$(_ws_daemon_pid)" || return 0
  kill "$p" 2>/dev/null; while kill -0 "$p" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; }
# The unit runs this launcher, never a versioned plugin path: a plugin update moves SCRIPT_PATH, and
# every outsourcerer call repoints the launcher at the copy it runs from (_ws_refresh).
_ws_launcher() {
  local l sp="$SCRIPT_PATH"; l="$(_ws_root)/launch"   # SCRIPT_PATH is absolute (outsourcerer.sh)
  grep -qxF "# script: $sp" "$l" 2>/dev/null && return 0
  printf '#!%s\n# script: %s\nexec %q %q watcher run\n' "$BASH" "$sp" "$BASH" "$sp" > "$l.tmp" && chmod +x "$l.tmp" && mv -f "$l.tmp" "$l"
}
_ws_refresh() { # any outsourcerer call: keep an INSTALLED watcher pointed at this copy, and its fallback loop alive
  local be; be="$(cat "$(_ws_root)/installed" 2>/dev/null)" || return 0
  _ws_launcher
  [ "$be" != fallback ] || _ws_spawn
  return 0
}

_ws_backend() {
  case "${OSRC_WATCH_BACKEND:-}" in launchd|systemd|fallback) printf '%s' "$OSRC_WATCH_BACKEND"; return 0 ;; esac
  if [ "${OSRC_PLATFORM:-}" = mac ] && command -v launchctl >/dev/null 2>&1; then printf launchd
  elif [ "${OSRC_PLATFORM:-}" = linux ] && command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then printf systemd
  else printf fallback; fi
}
_ws_unit() { case "$1" in launchd) printf '%s/com.outsourcerer.watcher.plist' "${OSRC_WATCH_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}" ;;
  systemd) printf '%s/outsourcerer-watcher.service' "${OSRC_WATCH_SYSTEMD_DIR:-$HOME/.config/systemd/user}" ;; esac; }
_ws_unit_rm() { # <backend>: unload and delete its unit, if one is on disk
  local u; u="$(_ws_unit "$1")"; [ -f "$u" ] || return 0
  case "$1" in
    systemd) command -v systemctl >/dev/null 2>&1 && systemctl --user disable --now outsourcerer-watcher.service >/dev/null 2>&1
      rm -f "$u"; command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload >/dev/null 2>&1 ;;
    launchd) command -v launchctl >/dev/null 2>&1 && launchctl bootout "gui/$(id -u)/com.outsourcerer.watcher" >/dev/null 2>&1; rm -f "$u" ;;
  esac
  return 0
}
_ws_xml() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

_ws_install() {
  local be u v l; be="$(_ws_backend)"; u="$(_ws_unit "$be")"; l="$(_ws_root)/launch"
  mkdir -p "$(_ws_root)" || return 1
  # launchd/systemd start with a bare PATH and none of the user's knobs: capture them now.
  { printf 'export PATH=%q\n' "$PATH"
    [ -z "${TMUX:-}" ] || printf 'export TMUX=%q\n' "${TMUX%%,*}"   # the user's tmux server (-L/-S), socket only
    [ -z "${TMUX_TMPDIR:-}" ] || printf 'export TMUX_TMPDIR=%q\n' "$TMUX_TMPDIR"
    for v in $(env | sed -n 's/^\(OSRC_WATCH_[A-Z_]*\)=.*/\1/p'); do printf 'export %s=%q\n' "$v" "${!v}"; done; } > "$(_ws_root)/env"
  _ws_launcher || return 1
  _ws_stop_loop   # a loop already holding the lock would make the new unit exit and respawn forever
  case "$be" in
    systemd)
      { mkdir -p "${u%/*}" && printf '[Unit]\nDescription=Outsourcerer lane watcher\n\n[Service]\nExecStart="%s" "%s"\nEnvironment="OSRC_HOME=%s"\nRestart=always\nRestartSec=10\nNice=10\n\n[Install]\nWantedBy=default.target\n' \
        "$BASH" "$l" "$OSRC_HOME" > "$u" \
        && systemctl --user daemon-reload && systemctl --user enable outsourcerer-watcher.service >/dev/null 2>&1 \
        && systemctl --user restart outsourcerer-watcher.service; } \
        || { echo "outsourcerer: systemd --user install failed; using the fallback loop instead" >&2; _ws_unit_rm systemd; be=fallback; } ;;
    launchd)
      { mkdir -p "${u%/*}" && printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n<key>Label</key><string>com.outsourcerer.watcher</string>\n<key>ProgramArguments</key><array><string>%s</string><string>%s</string></array>\n<key>EnvironmentVariables</key><dict><key>OSRC_HOME</key><string>%s</string></dict>\n<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ProcessType</key><string>Background</string>\n</dict></plist>\n' \
        "$(_ws_xml "$BASH")" "$(_ws_xml "$l")" "$(_ws_xml "$OSRC_HOME")" > "$u" \
        && { launchctl bootout "gui/$(id -u)/com.outsourcerer.watcher" >/dev/null 2>&1
             launchctl bootstrap "gui/$(id -u)" "$u" || { sleep 1; launchctl bootstrap "gui/$(id -u)" "$u"; }; }; } \
        || { echo "outsourcerer: launchctl bootstrap failed (no GUI login session?); using the fallback loop instead" >&2; _ws_unit_rm launchd; be=fallback; } ;;
  esac
  if [ "$be" = fallback ]; then u=""; _ws_spawn || return 1; fi
  printf '%s\n' "$be" > "$(_ws_root)/installed"
  echo "outsourcerer: watcher installed ($be${u:+, $u}). It watches every session's lanes, wakes the owning session (inside tmux, or through OSRC_WATCH_DELIVER_CMD), and continues limit-parked lanes after the reset. Remove: $SCRIPT_PATH watcher uninstall"
}

_ws_uninstall() {
  local be; be="$(cat "$(_ws_root)/installed" 2>/dev/null)"
  _ws_unit_rm systemd; _ws_unit_rm launchd   # both, whatever `installed` says: a failed install leaves no unit behind
  _ws_stop_loop
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
    run) _ws_run ;;
    -h|--help|help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) echo "usage: $SCRIPT_PATH watcher install|uninstall|status|run" >&2; return 2 ;;
  esac
}
