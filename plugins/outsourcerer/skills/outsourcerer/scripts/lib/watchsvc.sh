# shellcheck shell=bash
# lib/watchsvc.sh: the per-user watcher service — a watcher nobody can forget.
#
#   outsourcerer.sh watcher install|uninstall|status|run|tick|ensure
#
# Why this exists (the incidents it closes):
#   * `supervise` is a blocking waiter the orchestrator must RE-ARM after every wake; when the
#     session ends its turn, compacts, or is reaped, nothing observes or delivers.
#   * The heartbeat beacon exits as soon as `_heartbeat_active_work` finds no jobs and no
#     registry sessions, and it is spawned with nohup — it can die with its parent shell. Once
#     every lane is parked/finished it stops logging events entirely.
#   * The stop guard yields after OSRC_STOP_GUARD_MAX and only leaves a file the next outsourcerer
#     call prints — a yield nobody sees is a silent one.
#   * A `limit` event was logged and nothing ever resumed the lane after the provider reset.
#
# The service is ONE per-user daemon (launchd on macOS, systemd --user on Linux, a detached
# fallback loop everywhere else incl. Windows Git Bash). Each tick it:
#   1. runs the same observe pass the beacon runs (_sv_observe_all), so lanes/events.jsonl keeps
#      filling for EVERY owner even with zero sessions alive — pure files+screens, zero tokens;
#   2. auto-continues lanes parked on a provider limit once per reset epoch, only while the lane
#      is still limit-parked (lanes/state/<id>.limitresume records the epoch already served);
#   3. for each owner with wake-worthy undelivered events and no live waiter, delivers a wake:
#      OSRC_WATCH_DELIVER_CMD, a tmux target from watchsvc/deliver.map, or `claude --bg/-p
#      --resume` when the session is provably not running; verified, retried with backoff, and a
#      terminal failure is written to owners/<sid>/.wakefail where the stop guard prints it.
#
# Delivery is deliberately conservative: a session that `claude agents` still lists as running is
# NEVER injected into (a second writer on one transcript diverges state). For those the service
# leaves durable pending state, throttled OS notifications, and the stop guard's per-turn note —
# the failure is visible instead of silent.
#
# Install is explicit (`watcher install`); the detached fallback loop may also be armed
# opportunistically by the stop guard / supervise arm (OSRC_WATCH_FALLBACK=0 opts out, as does
# OSRC_FLEET_SUPERVISION=0). `watcher uninstall` reverses either in one command. All knobs are
# env vars; defaults suit a stranger's machine.

# ---- paths and knobs -----------------------------------------------------------------------------
_osrc_watch_root() { printf '%s/watchsvc' "$OSRC_HOME"; }
_osrc_watch_stamp() { mkdir -p "$(_osrc_watch_root)" 2>/dev/null; printf '%s\n' "$(_sv_now)" > "$(_osrc_watch_root)/alive" 2>/dev/null; return 0; }
_osrc_watch_num() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
_osrc_watch_interval() { local v; v="$(_osrc_watch_num "${OSRC_WATCH_INTERVAL:-}" 30)"; [ "$v" -ge 5 ] || v=30; printf '%s' "$v"; }

# ---- coverage -------------------------------------------------------------------------------------
# _osrc_watch_covered -> rc 0 when a watcher service ticked recently for THIS OSRC_HOME. The stamp
# is written at the end of every completed tick, so a hung or dead daemon stops covering within
# OSRC_WATCH_COVERAGE_SECS (default 180 = six missed 30 s ticks).
_osrc_watch_covered() {
  local f age max
  f="$(_osrc_watch_root)/alive"; [ -f "$f" ] || return 1
  age=$(( $(_sv_now) - $(_osrc_watch_num "$(cat "$f" 2>/dev/null)" 0) ))
  max="$(_osrc_watch_num "${OSRC_WATCH_COVERAGE_SECS:-}" 180)"; [ "$max" -ge 30 ] || max=180
  [ "$age" -le "$max" ]
}

# ---- single instance ------------------------------------------------------------------------------
# The daemon holds run.lock/<pid>. A lock is reclaimed only when its pid is provably dead, a
# zombie, or no longer a `watcher` process (pid reuse must not wedge the service forever).
_osrc_watch_pid_alive() { # <pid>
  local pid="$1" st cmd
  kill -0 "$pid" 2>/dev/null || return 1
  st="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"; case "$st" in Z*) return 1 ;; esac
  cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
  case " $cmd " in *" watcher "*) return 0 ;; esac
  return 1
}
_osrc_watch_lock() { # -> rc 0 when THIS process holds run.lock
  local d="$(_osrc_watch_root)/run.lock" pid i=0
  mkdir -p "$(_osrc_watch_root)" 2>/dev/null || return 1
  while [ "$i" -lt 100 ]; do
    if mkdir "$d" 2>/dev/null; then printf '%s\n' "$$" > "$d/pid" 2>/dev/null; return 0; fi
    pid="$(cat "$d/pid" 2>/dev/null)"
    if [ -n "$pid" ] && _osrc_watch_pid_alive "$pid"; then return 1; fi
    rm -f "$d/pid" 2>/dev/null; rmdir "$d" 2>/dev/null
    i=$((i + 1)); sleep 0.1
  done
  return 1
}
_osrc_watch_unlock() {
  local d="$(_osrc_watch_root)/run.lock"
  [ "$(cat "$d/pid" 2>/dev/null)" = "$$" ] && { rm -f "$d/pid" 2>/dev/null; rmdir "$d" 2>/dev/null; }
  return 0
}

# _osrc_watch_ensure -> rc 0 when the watcher is covered or a fallback daemon was just armed.
# Called by the stop guard and by supervise's arm path: cheap stamp check when healthy, one
# detached spawn when not. Never blocks, never fails its caller.
_osrc_watch_ensure() {
  local d pid
  [ "${OSRC_WATCH_FALLBACK:-1}" = "0" ] && return 1
  [ "${OSRC_FLEET_SUPERVISION:-1}" = "0" ] && return 1
  _osrc_watch_covered && return 0
  d="$(_osrc_watch_root)/run.lock"; pid="$(cat "$d/pid" 2>/dev/null)"
  [ -n "$pid" ] && _osrc_watch_pid_alive "$pid" && return 0   # mid-start: first tick has not stamped yet
  mkdir -p "$(_osrc_watch_root)" 2>/dev/null || return 1
  OSRC_WATCH_INTERVAL="$(_osrc_watch_interval)" \
    nohup "$SCRIPT_PATH" watcher run >> "$(_osrc_watch_root)/service.log" 2>&1 &
  disown 2>/dev/null || true
  return 0
}

# ---- the daemon -----------------------------------------------------------------------------------
_osrc_watchd() { # `watcher run`: the foreground loop the service managers spawn
  _osrc_watch_lock || { echo "outsourcerer: watcher already running" >&2; return 0; }
  trap '_osrc_watch_unlock; exit 0' EXIT
  trap 'exit 0' INT TERM HUP
  local interval; interval="$(_osrc_watch_interval)"
  while :; do
    _osrc_watch_tick || true
    sleep "$interval" &
    wait "$!" 2>/dev/null
  done
}

# One full pass. Order matters: observe first (fresh state + fresh events), then limit resumes
# (they read the fresh per-target state), then delivery, then the liveness stamp — a tick that
# dies before the stamp correctly stops covering.
_osrc_watch_tick() {
  local now; now="$(_sv_now)"
  if type _sv_observe_all >/dev/null 2>&1; then _sv_observe_all watchsvc >/dev/null 2>&1 || true; fi
  _osrc_watch_limits "$now" || true
  _osrc_watch_deliver_all || true
  _osrc_watch_stamp "$now"
  return 0
}

# ---- event scan per owner -------------------------------------------------------------------------
# First run baselines at the newest supervise cursor for this owner: everything a waiter already
# delivered stays baseline, so installing the service does not re-wake for handled history.
# Reminder rows ("still unresolved ...") recur while an event is open, which is what lets deferred
# and re-wake decisions refresh without rescanning delivered history.
_osrc_watch_baseline() { # <sid> <gen> -> byte offset
  local sid="$1" gen="$2" f off g best=0
  for f in "$OSRC_HOME/supervise/$sid/cursor" "$OSRC_HOME/supervise/@all/cursor"; do
    [ -f "$f" ] || continue
    read -r off g 2>/dev/null < "$f"
    [ "$(_osrc_watch_num "$g" -1)" = "$gen" ] || continue
    off="$(_osrc_watch_num "$off" 0)"; [ "$off" -gt "$best" ] && best="$off"
  done
  printf '%s' "$best"
}

# _osrc_watch_scan <sid> <state-dir> <targets-json> -> wake-relevant TSV rows since the cursor.
# Sets _OSRC_WATCH_SCAN_SIZE/_OSRC_WATCH_SCAN_GEN for the caller's cursor write. Handles the
# events.jsonl rotation exactly like _sv_main: finish .1 first when the generation moved.
_osrc_watch_scan() {
  local sid="$1" sdir="$2" tj="$3" f gen cgen cursor size older=""
  f="$(_sv_lanes)/events.jsonl"
  _OSRC_WATCH_SCAN_SIZE=0; _OSRC_WATCH_SCAN_GEN=0
  if [ ! -f "$sdir/cursor" ]; then
    cursor="0"
  else
    read -r cursor cgen 2>/dev/null < "$sdir/cursor"; cursor="$(_osrc_watch_num "${cursor:-}" 0)"
  fi
  gen="$(_osrc_watch_num "$(cat "$(_sv_lanes)/events.gen" 2>/dev/null)" 0)"
  cgen="$(_osrc_watch_num "${cgen:-}" "$gen")"
  if [ ! -f "$sdir/cursor" ]; then
    cursor="$(_osrc_watch_baseline "$sid" "$gen")"
  elif [ "$cgen" != "$gen" ]; then
    [ "$cgen" = $(( gen - 1 )) ] && older="$(_sv_read_range "$f.1" "$cursor" - "$tj" "$sid")"
    cursor=0; cgen="$gen"
  fi
  size="$(_osrc_watch_num "$(wc -c 2>/dev/null < "$f" | tr -d ' ')" 0)"
  [ "$cursor" -le "$size" ] || cursor=0
  _OSRC_WATCH_SCAN_SIZE="$size"; _OSRC_WATCH_SCAN_GEN="$gen"
  printf '%s\n%s' "$older" "$(_sv_read_range "$f" "$cursor" "$size" "$tj" "$sid")" | grep . || true
}

# ---- wake ledger ----------------------------------------------------------------------------------
# $OSRC_HOME/watchsvc/<sid>/woken: "<key>\t<ts>\t<state>\t<attempts>\t<next>" per event key.
# key = kind|target|cksum(detail minus the "still unresolved" reminder prefix): a reminder maps to
# the SAME key as the event it re-reports, so one wake covers the event and its reminders.
# states: sent (wake delivered) | covered (a live waiter had it) | pend (delivery pending/backoff)
#         | deferred (no safe channel yet: session running, notify-only) | failed (attempts spent,
#         still retried slowly and marked in owners/<sid>/.wakefail)
_osrc_watch_informational() { # kinds that never trigger a wake on their own
  case "$1" in approved|nudged|limit-resumed|watcher-wake) return 0 ;; esac
  return 1
}
_osrc_watch_key() { # <kind> <target> <detail> -> dedupe key (reminder prefix stripped)
  local d; d="$(printf '%s' "$3" | sed -E 's/^still unresolved, waiting [0-9]+m: //')"
  printf '%s|%s|%s' "$1" "$2" "$(printf '%s' "$d" | cksum | awk '{print $1}')"
}
_osrc_watch_reminder() { case "${1:-}" in "still unresolved, waiting "*) return 0 ;; esac; return 1; }

# _osrc_watch_ledger_get <file> <key> -> sets LW_TS LW_STATE LW_ATT LW_NEXT (empty state: no entry)
_osrc_watch_ledger_get() {
  LW_TS=0; LW_STATE=""; LW_ATT=0; LW_NEXT=0
  [ -f "$1" ] || return 0
  local line; line="$(awk -F '\t' -v k="$2" '$1==k{print; exit}' "$1" 2>/dev/null)"
  [ -n "$line" ] || return 0
  LW_TS="$(printf '%s' "$line" | cut -f2)"; LW_STATE="$(printf '%s' "$line" | cut -f3)"
  LW_ATT="$(printf '%s' "$line" | cut -f4)"; LW_NEXT="$(printf '%s' "$line" | cut -f5)"
  LW_TS="$(_osrc_watch_num "$LW_TS" 0)"; LW_ATT="$(_osrc_watch_num "$LW_ATT" 0)"; LW_NEXT="$(_osrc_watch_num "$LW_NEXT" 0)"
  return 0
}
# _osrc_watch_ledger_put <file> <key> <ts> <state> <attempts> <next>: upsert + prune (>7d, cap 2000)
_osrc_watch_ledger_put() {
  local f="$1" key="$2" ts="$3" st="$4" att="$5" nxt="$6" now; now="$(_sv_now)"
  mkdir -p "${f%/*}" 2>/dev/null || return 1
  local tmp="$f.tmp.$$"
  { [ ! -f "$f" ] || awk -F '\t' -v k="$key" '$1!=k' "$f"
    printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$ts" "$st" "$att" "$nxt"
  } | awk -F '\t' -v since="$(( now - 604800 ))" '$2 >= since' > "$tmp" 2>/dev/null \
    && { tail -2000 "$tmp" > "$tmp.2" 2>/dev/null && mv -f "$tmp.2" "$tmp"; mv -f "$tmp" "$f"; } \
    || rm -f "$tmp"
  return 0
}

# ---- waiter coverage ------------------------------------------------------------------------------
# What a live waiter already covers for <sid>: prints covered target ids, `*` = everything.
# armed.* (a live supervise) + `wait <id>` processes (ps scan, cached once per tick in
# _OSRC_WATCH_WAITS). Same sources _waited_ids uses, composed once for the whole pass.
_osrc_watch_waited() { # <sid> -> covered ids / *
  local sid="$1"
  type _sv_armed_cover >/dev/null 2>&1 && _sv_armed_cover "$sid"
  printf '%s\n' "${_OSRC_WATCH_WAITS:-}"
}
_osrc_watch_target_covered() { # <sid> <target> <waited-lines>
  local sid="$1" t="$2" w="$3"
  printf '%s\n' "$w" | grep -qxF '*' && return 0
  printf '%s\n' "$w" | grep -qxF "$t" && return 0
  # a session-scoped supervise armed file holds `*`; an explicit one holds its ids — target ids
  # are what wait/supervise coverage is defined over, so this is the whole contract.
  return 1
}

# ---- delivery channels ----------------------------------------------------------------------------
# Order: OSRC_WATCH_DELIVER_CMD (user's own notifier, heartbeat-wake contract) -> tmux target from
# watchsvc/deliver.map (opt-in, types the wake as user input) -> `claude` resume injection, ONLY
# when `claude agents` proves the session is not running. Anything else -> deferred + notification.

_osrc_watch_notify() { # <title> <body>: OS notification, best-effort, never blocks the tick
  [ "${OSRC_WATCH_NOTIFY:-1}" = "0" ] && return 0
  local t="$1" b="$2"
  case "${OSRC_PLATFORM:-}" in
    mac)
      command -v osascript >/dev/null 2>&1 || return 0
      ( osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' -- "$t" "$b" ) >/dev/null 2>&1 </dev/null &
      ;;
    linux)
      command -v notify-send >/dev/null 2>&1 || return 0
      notify-send --app-name=outsourcerer "$t" "$b" >/dev/null 2>&1 </dev/null &
      ;;
  esac
  return 0
}

# claude agents --json (active sessions only), fetched once per tick and cached in globals.
# MUST be called directly (not via $()): the cache lives in the caller's shell.
_osrc_watch_agents() {
  [ "${_OSRC_WATCH_AGENTS_ONCE:-0}" = "1" ] && return 0
  _OSRC_WATCH_AGENTS_ONCE=1; _OSRC_WATCH_AGENTS_JSON=""
  have claude || return 0
  _OSRC_WATCH_AGENTS_JSON="$(claude agents --json 2>/dev/null)" || _OSRC_WATCH_AGENTS_JSON=""
  return 0
}
# _osrc_watch_session_state <sid> -> running | closed | unknown
_osrc_watch_session_state() {
  local sid="$1" agents
  _osrc_watch_agents
  agents="$_OSRC_WATCH_AGENTS_JSON"
  [ -n "$agents" ] || { printf 'unknown'; return 0; }
  printf '%s' "$agents" | jq -e 'type=="array"' >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  if printf '%s' "$agents" | jq -e --arg s "$sid" \
      '[.[]? | select(((.sessionId // .session_id // "") | tostring) == $s)] | length > 0' >/dev/null 2>&1; then
    printf 'running'; return 0
  fi
  printf 'closed'
}

# tmux delivery target for <sid>: one "sid<TAB>tmux-target" line per session in
# watchsvc/deliver.map. User-maintained = explicit consent; no auto-discovery.
_osrc_watch_tmux_target() { # <sid>
  local map line s t
  map="$(_osrc_watch_root)/deliver.map"; [ -f "$map" ] || return 1
  while IFS="$(printf '\t')" read -r s t; do
    case "$s" in ''|\#*) continue ;; esac
    [ "$s" = "$1" ] && [ -n "$t" ] && { printf '%s' "$t"; return 0; }
  done < "$map"
  return 1
}

# The wake text the owning session receives. It must stand alone: the durable log is the authority,
# this only says what happened and what to arm.
_osrc_watch_wake_text() { # <sid> <summary>
  printf '[outsourcerer] watcher wake for your session: %s. The durable event log is %s/lanes/events.jsonl — each row has a `next` command; handle them, then arm ONE background waiter so the next event wakes you without anyone re-arming by hand: %s supervise --session %s (it prints EVENT/NEXT and exits; re-arm after each wake).' \
    "$2" "$OSRC_HOME" "$SCRIPT_PATH" "$1"
}

# Channel executor — runs inside the detached deliverer subshell with env:
#   OSRC_WATCH_CHANNEL, OSRC_WATCH_MSG_FILE, OSRC_WATCH_EVENT_FILE, OSRC_WATCH_TMUX_T,
#   OSRC_WATCH_SID, OSRC_WATCH_SUMMARY.
_osrc_watch_deliver_exec() {
  local msg
  case "${OSRC_WATCH_CHANNEL:-}" in
    custom)
      OSRC_WAKE_EVENT="$(cat "$OSRC_WATCH_EVENT_FILE" 2>/dev/null)" \
        sh -c "$OSRC_WATCH_DELIVER_CMD" osrc-watch "$OSRC_WATCH_SUMMARY" < "$OSRC_WATCH_EVENT_FILE" ;;
    tmux)
      msg="$(cat "$OSRC_WATCH_MSG_FILE" 2>/dev/null)"; [ -n "$msg" ] || return 1
      tmux display-message -p -t "$OSRC_WATCH_TMUX_T" '#{pane_id}' >/dev/null 2>&1 || return 1
      tmux send-keys -t "$OSRC_WATCH_TMUX_T" -l -- "$msg" \
        && tmux send-keys -t "$OSRC_WATCH_TMUX_T" Enter ;;
    claude)
      msg="$(cat "$OSRC_WATCH_MSG_FILE" 2>/dev/null)"; [ -n "$msg" ] || return 1
      case "${OSRC_WATCH_INJECT:-bg}" in
        print) "${OSRC_WATCH_CLAUDE:-claude}" -p --resume "$OSRC_WATCH_SID" "$msg" ;;
        *)     "${OSRC_WATCH_CLAUDE:-claude}" --bg --resume "$OSRC_WATCH_SID" "$msg" \
                 || "${OSRC_WATCH_CLAUDE:-claude}" -p --resume "$OSRC_WATCH_SID" "$msg" ;;
      esac ;;
    *) return 1 ;;
  esac
}

# _osrc_watch_deliver_spawn <sid> <sdir> <summary> <keys...>: pick a channel and fork the
# deliverer. wake.job = "<pid> <rcfile> <started> <channel>"; wake.keys = the ledger keys it settles.
_osrc_watch_deliver_spawn() {
  local sid="$1" sdir="$2" summary="$3"; shift 3
  local chan="" t="" now msgf evf jf rc pid
  now="$(_sv_now)"
  if [ -n "${OSRC_WATCH_DELIVER_CMD:-}" ]; then chan=custom
  elif t="$(_osrc_watch_tmux_target "$sid")"; then chan=tmux
  elif [ "${OSRC_WATCH_INJECT:-bg}" != off ] && [ "$(_osrc_watch_session_state "$sid")" = closed ]; then chan=claude
  fi
  [ -n "$chan" ] || return 1
  mkdir -p "$sdir" 2>/dev/null || return 1
  msgf="$sdir/wake.msg"; evf="$sdir/wake.event.json"; jf="$sdir/wake.job"; rc="$sdir/wake.rc"
  _osrc_watch_wake_text "$sid" "$summary" > "$msgf"
  printf '%s\n' "$summary" > "$evf"   # the event JSON contract carries the batch summary; rows stay in events.jsonl
  rm -f "$rc"
  printf '%s\n' "$*" > "$sdir/wake.keys"
  (
    OSRC_WATCH_CHANNEL="$chan" OSRC_WATCH_MSG_FILE="$msgf" OSRC_WATCH_EVENT_FILE="$evf" \
      OSRC_WATCH_TMUX_T="$t" OSRC_WATCH_SID="$sid" OSRC_WATCH_SUMMARY="$summary" \
      OSRC_WATCH_CLAUDE="${OSRC_WATCH_CLAUDE:-claude}" OSRC_WATCH_INJECT="${OSRC_WATCH_INJECT:-bg}" \
      OSRC_WATCH_DELIVER_CMD="${OSRC_WATCH_DELIVER_CMD:-}" \
      _osrc_watch_deliver_exec >/dev/null 2>&1 </dev/null
    printf '%s\n' "$?" > "$rc"
  ) &
  pid=$!
  local pstart; pstart="$(type _pid_start_identity >/dev/null 2>&1 && _pid_start_identity "$pid" 2>/dev/null)"
  printf '%s %s %s %s %s\n' "$pid" "$rc" "$now" "$chan" "$pstart" > "$jf"
  return 0
}

# Resolve an in-flight deliverer: rcfile -> verdict; dead pid without rcfile -> failed;
# elapsed > OSRC_WATCH_WAKE_TIMEOUT -> kill + failed. On success marks every wake.keys entry sent.
_osrc_watch_deliver_check() { # <sid> <sdir>
  local sid="$1" sdir="$2" jf="$sdir/wake.job" pid rc started chan pstart keys key now att nxt st live
  [ -f "$jf" ] || return 0
  read -r pid rc started chan pstart <<< "$(head -1 "$jf" 2>/dev/null)"
  pid="$(_osrc_watch_num "$pid" 0)"; started="$(_osrc_watch_num "$started" 0)"
  now="$(_sv_now)"
  # pid must be a real process id (>1): a corrupt wake.job must settle, never signal ourselves.
  [ "$pid" -gt 1 ] 2>/dev/null || { _osrc_watch_deliver_settle "$sid" "$sdir" 1 "${chan:-unknown}"; return 0; }
  # PID-reuse guard: the recorded start identity must still match before we trust liveness or kill.
  if [ -n "$pstart" ] && type _pid_start_identity >/dev/null 2>&1; then
    live="$(_pid_start_identity "$pid" 2>/dev/null)"
    [ -n "$live" ] && [ "$live" != "$pstart" ] && { _osrc_watch_deliver_settle "$sid" "$sdir" 1 "${chan:-unknown}"; return 0; }
  fi
  if [ -f "$rc" ]; then
    local code; code="$(cat "$rc" 2>/dev/null)"; code="${code:-1}"
    _osrc_watch_deliver_settle "$sid" "$sdir" "$code" "$chan"
    return 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    _osrc_watch_deliver_settle "$sid" "$sdir" 1 "$chan"; return 0
  fi
  if [ $(( now - started )) -gt "$(_osrc_watch_num "${OSRC_WATCH_WAKE_TIMEOUT:-}" 1800)" ]; then
    [ -z "$pstart" ] || [ "$(type _pid_start_identity >/dev/null 2>&1 && _pid_start_identity "$pid" 2>/dev/null)" = "$pstart" ] && kill "$pid" 2>/dev/null
    _osrc_watch_deliver_settle "$sid" "$sdir" 124 "$chan"
  fi
  return 0
}
_osrc_watch_deliver_settle() { # <sid> <sdir> <rc> <channel>
  local sid="$1" sdir="$2" code="$3" chan="$4" keys key led att nxt ok=0
  led="$sdir/woken"; keys="$(cat "$sdir/wake.keys" 2>/dev/null)"
  case "$code" in 0) ok=1 ;; esac
  if [ "$ok" = 1 ]; then
    for key in $keys; do _osrc_watch_ledger_put "$led" "$key" "$(_sv_now)" sent 0 0; done
    rm -f "$sdir/wakefail" "$sdir/wake.pending" "$sdir/wake.attempts" 2>/dev/null
    _sv_append watcher-wake "watchsvc" "delivered wake to session $sid via $chan" \
      "$SCRIPT_PATH watcher status" "watchsvc" "$sid" 2>/dev/null || true
  else
    att="$(_osrc_watch_num "$(cat "$sdir/wake.attempts" 2>/dev/null)" 0)"; att=$((att + 1))
    printf '%s\n' "$att" > "$sdir/wake.attempts"
    local max; max="$(_osrc_watch_num "${OSRC_WATCH_WAKE_MAX:-}" 5)"
    if [ "$att" -ge "$max" ]; then
      for key in $keys; do _osrc_watch_ledger_put "$led" "$key" "$(_sv_now)" failed "$att" $(( $(_sv_now) + 3600 )); done
      printf 'watcher could not deliver %s event(s) to session %s after %s attempt(s) (last channel %s, rc %s). Pending rows stay in %s/lanes/events.jsonl.\n' \
        "$(printf '%s\n' "$keys" | grep -c .)" "$sid" "$att" "$chan" "$code" "$OSRC_HOME" \
        > "$OSRC_HOME/owners/$sid/.wakefail" 2>/dev/null
      _osrc_watch_notify "outsourcerer: wake delivery failing" \
        "$sid: $(printf '%s\n' "$keys" | grep -c .) event(s) undelivered after $att attempts"
    else
      nxt=$(( $(_sv_now) + ( att <= 1 ? 60 : att == 2 ? 300 : att == 3 ? 900 : 1800 ) ))
      for key in $keys; do _osrc_watch_ledger_put "$led" "$key" "$(_sv_now)" pend "$att" "$nxt"; done
    fi
  fi
  rm -f "$sdir/wake.job" "$sdir/wake.keys" "$sdir/wake.rc" 2>/dev/null
  return 0
}

# ---- per-owner pass -------------------------------------------------------------------------------
# Fold the scanned rows into the ledger, then either mark covered, defer, or deliver once.
_osrc_watch_process() { # <sid> <sdir> <rows>
  local sid="$1" sdir="$2" rows="$3" now led waited p ts kind target detail next id key
  local LW_TS LW_STATE LW_ATT LW_NEXT reminder covered_ids="" pend_keys="" pend_desc="" woken_any=0
  now="$(_sv_now)"; led="$sdir/woken"
  waited="$(_osrc_watch_waited "$sid")"
  while IFS="$(printf '\t')" read -r p ts kind target detail next id; do
    [ -n "$kind" ] || continue
    _osrc_watch_informational "$kind" && continue
    key="$(_osrc_watch_key "$kind" "$target" "$detail")"
    reminder=0; _osrc_watch_reminder "$detail" && reminder=1
    if _osrc_watch_target_covered "$sid" "$target" "$waited"; then
      _osrc_watch_ledger_get "$led" "$key"
      [ "$LW_STATE" = sent ] || _osrc_watch_ledger_put "$led" "$key" "$now" covered 0 0
      continue
    fi
    _osrc_watch_ledger_get "$led" "$key"
    case "$LW_STATE" in
      sent)
        # Re-wake only on a reminder row (proof the event is still unresolved) and only after
        # OSRC_WATCH_REWAKE seconds — an ignored wake must not become a per-reminder token burn.
        local rw; rw="$(_osrc_watch_num "${OSRC_WATCH_REWAKE:-}" 3600)"
        if [ "$reminder" = 1 ] && [ "$rw" -gt 0 ] && [ $(( now - LW_TS )) -ge "$rw" ]; then
          pend_keys="$pend_keys $key"; pend_desc="$pend_desc $kind:$target"
        fi ;;
      covered) pend_keys="$pend_keys $key"; pend_desc="$pend_desc $kind:$target" ;;   # waiter died
      failed) [ "$now" -ge "$LW_NEXT" ] && { pend_keys="$pend_keys $key"; pend_desc="$pend_desc $kind:$target"; } ;;
      pend|deferred) [ "$now" -ge "$LW_NEXT" ] && { pend_keys="$pend_keys $key"; pend_desc="$pend_desc $kind:$target"; } ;;
      *) pend_keys="$pend_keys $key"; pend_desc="$pend_desc $kind:$target" ;;          # never seen
    esac
  done <<< "$rows"
  [ -n "$pend_keys" ] || return 0
  pend_keys="${pend_keys# }"; pend_desc="${pend_desc# }"
  # Collapse the batch to one wake: count + the distinct kind:target pairs (cap the text).
  local summary n
  n="$(printf '%s\n' $pend_desc | sort -u | wc -l | tr -d ' ')"
  summary="${n} event(s) need this session: $(printf '%s\n' $pend_desc | sort -u | head -8 | tr '\n' ' ')"
  printf '%s\t%s\n' "$now" "$summary" > "$sdir/wake.pending" 2>/dev/null
  if [ -f "$sdir/wake.job" ]; then
    # A deliverer is already running. Brand-new keys still get a pend entry so they are not lost
    # when this batch settles — they re-evaluate on a later tick.
    for key in $pend_keys; do
      _osrc_watch_ledger_get "$led" "$key"
      [ -n "$LW_STATE" ] || _osrc_watch_ledger_put "$led" "$key" "$now" pend 0 $(( now + 120 ))
    done
    return 0
  fi
  if _osrc_watch_deliver_spawn "$sid" "$sdir" "$summary" $pend_keys; then
    for key in $pend_keys; do _osrc_watch_ledger_put "$led" "$key" "$now" pend 0 "$(( now + 60 ))"; done
    return 0
  fi
  # No safe channel: the session is still running (or claude is unavailable). Defer visibly —
  # durable pending state + a throttled notification — rather than inject into a live transcript.
  local nts last_nt
  nts="$(_osrc_watch_num "${OSRC_WATCH_NOTIFY_SECS:-}" 1800)"
  last_nt="$(_osrc_watch_num "$(cat "$sdir/notify.ts" 2>/dev/null)" 0)"
  for key in $pend_keys; do _osrc_watch_ledger_put "$led" "$key" "$now" deferred 0 $(( now + 300 )); done
  if [ $(( now - last_nt )) -ge "$nts" ]; then
    printf '%s\n' "$now" > "$sdir/notify.ts"
    _osrc_watch_notify "outsourcerer: $n lane event(s) waiting" \
      "session ${sid:0:8}: $summary — run \`$SCRIPT_PATH supervise --session $sid\` or check $OSRC_HOME/lanes/events.jsonl"
  fi
  return 0
}

_osrc_watch_owner_tick() { # <sid>
  local sid="$1" dir sdir rows tj
  dir="$OSRC_HOME/owners/$sid"; [ -d "$dir" ] || return 0
  sdir="$(_osrc_watch_root)/$sid"; mkdir -p "$sdir" 2>/dev/null || return 0
  _osrc_watch_deliver_check "$sid" "$sdir"
  tj="$(ls -1 "$dir" 2>/dev/null | grep -v '^\.' | jq -R . 2>/dev/null | jq -cs . 2>/dev/null)"
  [ -n "$tj" ] || tj='[]'
  # NOT $(): _osrc_watch_scan sets _OSRC_WATCH_SCAN_SIZE/_GEN in the caller's shell (a command
  # substitution would run it in a subshell and the cursor write below would see unset vars).
  local rf="$sdir/.scan.$$"
  _osrc_watch_scan "$sid" "$sdir" "$tj" > "$rf" 2>/dev/null || true
  rows="$(cat "$rf" 2>/dev/null)"; rm -f "$rf"
  [ -n "$rows" ] && _osrc_watch_process "$sid" "$sdir" "$rows"
  # The scanned byte range is consumed either way: rows belonging to other owners were filtered
  # out by _sv_read_range and never need re-reading. Writing the cursor after process keeps a
  # mid-process crash retry-safe (keys dedupe by ledger).
  printf '%s %s\n' "$_OSRC_WATCH_SCAN_SIZE" "$_OSRC_WATCH_SCAN_GEN" > "$sdir/cursor" 2>/dev/null
  return 0
}

_osrc_watch_deliver_all() {
  local d sid
  [ -d "$OSRC_HOME/owners" ] || return 0
  _OSRC_WATCH_WAITS="$(type _sg_ps_waits >/dev/null 2>&1 && _sg_ps_waits 2>/dev/null)"
  _OSRC_WATCH_AGENTS_ONCE=0; _OSRC_WATCH_AGENTS_JSON=""
  for d in "$OSRC_HOME"/owners/*/; do
    [ -d "$d" ] || continue
    sid="$(basename "$d")"
    _osrc_watch_owner_tick "$sid" || true
  done
  unset _OSRC_WATCH_WAITS
  return 0
}

# ---- provider-limit auto-continue -----------------------------------------------------------------
# A lane parked on a plan/provider limit gets ONE `continue` per reset epoch, only while it is
# still limit-parked (lanes/state/<id> last-key starts with limit:) and still owned. The epoch
# comes from the event detail ("(epoch N)" for agy timers; "resets at/in ..." parsed by
# _lane_limit_reset_secs); a limit with no parseable reset is left for the lane's own timer.
_osrc_watch_limit_epoch() { # <detail> <row-ts> <now> -> epoch or rc1
  local detail="$1" rts="$2" now="$3" ep secs
  ep="$(printf '%s' "$detail" | grep -oE 'epoch [0-9]+' | grep -oE '[0-9]+' | head -1)"
  [ -n "$ep" ] && { printf '%s' "$ep"; return 0; }
  type _lane_limit_reset_secs >/dev/null 2>&1 || return 1
  secs="$(_lane_limit_reset_secs "$detail" 2>/dev/null)"
  case "$secs" in ''|*[!0-9]*) return 1 ;; esac
  case "$(printf '%s' "$detail" | tr '[:upper:]' '[:lower:]')" in
    *" in "*) printf '%s' $(( rts + secs )) ;;   # relative phrase: reset = banner time + delta
    *)         printf '%s' $(( now + secs )) ;;  # absolute clock/epoch phrase
  esac
}

_osrc_watch_limits() { # <now>
  [ "${OSRC_WATCH_LIMIT_AUTO:-1}" = "0" ] && return 0
  local now="$1" f lc cursor cgen gen size rows target detail ts ep rf sent m
  f="$(_sv_lanes)/events.jsonl"; lc="$(_osrc_watch_root)/limits.cursor"
  [ -f "$f" ] || return 0
  cursor=0; cgen=""
  [ -f "$lc" ] && read -r cursor cgen 2>/dev/null < "$lc"
  cursor="$(_osrc_watch_num "$cursor" 0)"
  gen="$(_osrc_watch_num "$(cat "$(_sv_lanes)/events.gen" 2>/dev/null)" 0)"
  cgen="$(_osrc_watch_num "$cgen" "$gen")"
  size="$(_osrc_watch_num "$(wc -c 2>/dev/null < "$f" | tr -d ' ')" 0)"
  [ "$cursor" -le "$size" ] || cursor=0
  # kind==limit rows only, no owner filter: a limit resume is per-lane, not per-orchestrator.
  rows="$( { tail -c +"$(( cursor + 1 ))" "$f" 2>/dev/null | head -c "$(( size - cursor ))"; } \
    | jq -r 'select(type=="object" and .kind=="limit") | [(.target|tostring),(.detail|tostring),(.ts|tostring)] | @tsv' 2>/dev/null )"
  sent=0
  while IFS="$(printf '\t')" read -r target detail ts; do
    [ -n "$target" ] || continue
    ep="$(_osrc_watch_limit_epoch "$detail" "$(_osrc_watch_num "$ts" "$now")" "$now")" || continue
    [ "$now" -lt "$ep" ] && continue
    _sv_state_read "$target" 2>/dev/null
    case "$SVS_LK" in limit:*) ;; *) continue ;; esac
    m=""; for m in "$OSRC_HOME"/owners/*/"$target"; do [ -f "$m" ] && break; done
    [ -f "$m" ] || continue
    _osrc_ols_tmux_live "$target" 2>/dev/null || continue
    rf="$(_sv_lanes)/state/$target.limitresume"
    [ "$(awk '{print $1}' "$rf" 2>/dev/null)" = "$ep" ] && continue
    [ "$sent" -ge "$(_osrc_watch_num "${OSRC_WATCH_LIMIT_MAX:-}" 5)" ] && break
    OUTSOURCERER_TMUX="$target" OSRC_STREAM=1 "$SCRIPT_PATH" session send "continue" >/dev/null 2>&1 </dev/null
    printf '%s %s\n' "$ep" "$now" > "$rf" 2>/dev/null
    _sv_append limit-resumed "$target" "auto-continued after provider limit reset (epoch $ep)" \
      "OUTSOURCERER_TMUX=$target $SCRIPT_PATH session read" watchsvc "" 2>/dev/null || true
    sent=$((sent + 1))
  done <<< "$rows"
  printf '%s %s\n' "$size" "$gen" > "$lc" 2>/dev/null
  return 0
}

# ---- pending summary for the stop guard ------------------------------------------------------------
# _osrc_watch_pending <sid> -> "<n>" count of events still owed a wake, or nothing.
_osrc_watch_pending() {
  local sid="$1" led n=0 line st
  led="$(_osrc_watch_root)/$sid/woken"; [ -f "$led" ] || return 1
  while IFS="$(printf '\t')" read -r _k _t st _a _n; do
    case "$st" in pend|deferred|failed) n=$((n + 1)) ;; esac
  done < "$led"
  [ "$n" -gt 0 ] && printf '%s' "$n"
  return 0
}

# ---- install / uninstall / status ------------------------------------------------------------------
_osrc_watch_plist_label() { printf 'com.outsourcerer.watchd'; }
_osrc_watch_launchd_dir() { printf '%s' "${OSRC_WATCH_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}"; }
_osrc_watch_systemd_dir() { printf '%s' "${OSRC_WATCH_SYSTEMD_DIR:-$HOME/.config/systemd/user}"; }

_osrc_watch_unit_write() { # <path>
  local p="$1"
  cat > "$p" <<EOF
[Unit]
Description=Outsourcerer per-user lane watcher
After=default.target

[Service]
Type=simple
ExecStart=/bin/bash "$SCRIPT_PATH" watcher run
Restart=always
RestartSec=10
Nice=10
Environment=OSRC_HOME="$OSRC_HOME"

[Install]
WantedBy=default.target
EOF
}
_osrc_watch_plist_write() { # <path>
  local p="$1" label
  label="$(_osrc_watch_plist_label)"
  cat > "$p" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(printf '%s' "$SCRIPT_PATH" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</string>
    <string>watcher</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>OSRC_HOME</key><string>$(printf '%s' "$OSRC_HOME" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$(_osrc_watch_root)/launchd.log</string>
  <key>StandardErrorPath</key><string>$(_osrc_watch_root)/launchd.log</string>
</dict>
</plist>
EOF
}

_osrc_watch_install_launchd() { # -> rc0 installed+started
  local dir label plist uid domain
  dir="$(_osrc_watch_launchd_dir)"; label="$(_osrc_watch_plist_label)"; plist="$dir/$label.plist"
  command -v launchctl >/dev/null 2>&1 || return 1
  mkdir -p "$dir" "$(_osrc_watch_root)" 2>/dev/null || return 1
  _osrc_watch_plist_write "$plist" || return 1
  uid="$(id -u)"; domain="gui/$uid"
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1 \
    || launchctl load -w "$plist" >/dev/null 2>&1 || { rm -f "$plist"; return 1; }
  printf '{"backend":"launchd","label":"%s","plist":"%s","installed_at":%s}\n' \
    "$label" "$plist" "$(_sv_now)" > "$(_osrc_watch_root)/install.json" 2>/dev/null
  return 0
}
_osrc_watch_uninstall_launchd() {
  local dir label plist uid domain
  dir="$(_osrc_watch_launchd_dir)"; label="$(_osrc_watch_plist_label)"; plist="$dir/$label.plist"
  uid="$(id -u)"; domain="gui/$uid"
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || launchctl unload -w "$plist" >/dev/null 2>&1 || true
  rm -f "$plist" 2>/dev/null
}

_osrc_watch_install_systemd() {
  local dir unit
  dir="$(_osrc_watch_systemd_dir)"; unit="$dir/outsourcerer-watch.service"
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user show-environment >/dev/null 2>&1 || return 1   # no user bus -> cannot manage
  mkdir -p "$dir" "$(_osrc_watch_root)" 2>/dev/null || return 1
  _osrc_watch_unit_write "$unit" || return 1
  systemctl --user daemon-reload >/dev/null 2>&1 || { rm -f "$unit"; return 1; }
  systemctl --user enable --now outsourcerer-watch.service >/dev/null 2>&1 \
    || { rm -f "$unit"; systemctl --user daemon-reload >/dev/null 2>&1; return 1; }
  printf '{"backend":"systemd","unit":"outsourcerer-watch.service","unit_path":"%s","installed_at":%s}\n' \
    "$unit" "$(_sv_now)" > "$(_osrc_watch_root)/install.json" 2>/dev/null
  return 0
}
_osrc_watch_uninstall_systemd() {
  local dir unit
  dir="$(_osrc_watch_systemd_dir)"; unit="$dir/outsourcerer-watch.service"
  command -v systemctl >/dev/null 2>&1 || { rm -f "$unit" 2>/dev/null; return 0; }
  systemctl --user disable --now outsourcerer-watch.service >/dev/null 2>&1 || true
  rm -f "$unit" 2>/dev/null
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}

_osrc_watch_install_fallback() { # detached loop; honest about its limits
  mkdir -p "$(_osrc_watch_root)" 2>/dev/null || return 1
  _osrc_watch_ensure || return 1
  printf '{"backend":"fallback","note":"detached loop; survives until logout/reboot — run watcher install on launchd/systemd for permanence","installed_at":%s}\n' \
    "$(_sv_now)" > "$(_osrc_watch_root)/install.json" 2>/dev/null
  return 0
}
_osrc_watch_uninstall_fallback() {
  local d pid
  d="$(_osrc_watch_root)/run.lock"; pid="$(cat "$d/pid" 2>/dev/null)"
  [ -n "$pid" ] && _osrc_watch_pid_alive "$pid" && kill "$pid" 2>/dev/null
  rm -f "$d/pid" 2>/dev/null; rmdir "$d" 2>/dev/null
  return 0
}

_osrc_watch_backend() { # -> launchd | systemd | fallback | none (detection only, no side effects)
  case "${OSRC_WATCH_BACKEND:-}" in launchd|systemd|fallback) printf '%s' "$OSRC_WATCH_BACKEND"; return 0 ;; esac
  case "${OSRC_PLATFORM:-}" in
    mac) command -v launchctl >/dev/null 2>&1 && { printf 'launchd'; return 0; } ;;
    linux) command -v systemctl >/dev/null 2>&1 && { printf 'systemd'; return 0; } ;;
  esac
  printf 'fallback'
}

cmd_watcher() {
  local sub="${1:-status}"; shift 2>/dev/null || true
  case "$sub" in
    install)
      local be; be="$(_osrc_watch_backend)"
      case "$be" in
        launchd)  _osrc_watch_install_launchd || { echo "outsourcerer: launchd install failed" >&2; return 1; } ;;
        systemd)  _osrc_watch_install_systemd || { echo "outsourcerer: systemd --user install failed (no user bus?) — falling back to detached loop" >&2; _osrc_watch_install_fallback || return 1; } ;;
        *)        _osrc_watch_install_fallback || { echo "outsourcerer: fallback arm failed" >&2; return 1; } ;;
      esac
      echo "outsourcerer: watcher installed ($be). It observes every owner's lanes, wakes sessions on events, resumes limit-parked lanes once per reset, and costs zero tokens while idle. Remove with: $SCRIPT_PATH watcher uninstall"
      ;;
    uninstall)
      case "$(_osrc_watch_backend)" in
        launchd)  _osrc_watch_uninstall_launchd ;;
        systemd)  _osrc_watch_uninstall_systemd ;;
      esac
      _osrc_watch_uninstall_fallback
      rm -f "$(_osrc_watch_root)/install.json" 2>/dev/null
      echo "outsourcerer: watcher uninstalled."
      ;;
    status)
      local be inst pid age pend fails owners
      be="$(_osrc_watch_backend)"
      inst="$(jq -r '.backend // empty' "$(_osrc_watch_root)/install.json" 2>/dev/null)"
      pid="$(cat "$(_osrc_watch_root)/run.lock/pid" 2>/dev/null)"
      age="-"; [ -f "$(_osrc_watch_root)/alive" ] && age=$(( $(_sv_now) - $(_osrc_watch_num "$(cat "$(_osrc_watch_root)/alive" 2>/dev/null)" 0) ))
      owners="$(ls -1 "$OSRC_HOME/owners" 2>/dev/null | grep -c . || true)"
      pend=0; fails=0
      for d in "$(_osrc_watch_root)"/*/; do
        [ -d "$d" ] || continue
        local n; n="$(_osrc_watch_pending "$(basename "$d")" 2>/dev/null)"; pend=$((pend + ${n:-0}))
        [ -f "$d/wakefail" ] && fails=$((fails + 1))
      done
      printf 'watcher: backend=%s installed=%s daemon=%s alive_age=%ss owners=%s pending_wakes=%s failed_deliveries=%s\n' \
        "$be" "${inst:-none}" "$([ -n "$pid" ] && _osrc_watch_pid_alive "$pid" && echo "pid $pid" || echo dead)" \
        "$age" "$owners" "$pend" "$fails"
      _osrc_watch_covered && echo "coverage: live (stamped ${age}s ago)" || echo "coverage: NONE — owned work has no watcher"
      ;;
    run|__run) _osrc_watchd ;;
    tick)      _osrc_watch_tick ;;
    ensure)    _osrc_watch_ensure && echo "watcher: covered or armed" || { echo "watcher: not covered (fallback disabled?)"; return 1; } ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" 2>/dev/null | sed 's/^# \{0,1\}//'; return 0 ;;
    *) echo "usage: $SCRIPT_PATH watcher install|uninstall|status|run|tick|ensure" >&2; return 2 ;;
  esac
}
