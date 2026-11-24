#!/usr/bin/env bash
# lib/disk_policy.sh — disk pressure policy: launch floors, while-running pause/resume of the
# processes Outsourcerer launched, merged-lane auto-reclaim, and the detached monitor.
# Sourced by the lib loader; defines functions only, runs nothing at load time. Bash 3.2 + Git Bash.
#
# Floors (KB, from the volume holding $OSRC_HOME; see references/jobs-and-safety.md):
#   launch   = OSRC_DISK_MIN_GB, else max(10GB, 5% of volume) capped at 25% of a small volume
#   pause    = OSRC_DISK_PAUSE_GB, else max(4GB, 2% of volume), always under 3/4 of launch
#   critical = OSRC_DISK_CRITICAL_GB, else 0.5% of volume clamped to 1..4GB, always under launch
#   resume   = pause + half the pause->launch gap (hysteresis)
# Settings: a per-command env var wins at the launch gate; the shared file
# $OSRC_HOME/disk-policy/settings (NAME=value lines, never sourced) is the only source the
# fleet-wide monitor reads, so one command's environment never governs later jobs.
#
# Rules: nothing bypasses the critical floor. OSRC_DISK_OK takes only the one-use code a
# refusal prints, binds to one command, is scrubbed from the delegate environment, and needs
# a successful audit append. Pausing writes its record BEFORE any SIGSTOP, signals only
# identity-verified processes Outsourcerer launched, never kills, and every monitor exit
# resumes what it paused. Auto-reclaim touches only a lane proven merged at a pinned commit.

_osrc_disk_dir() { printf '%s/disk-policy' "$OSRC_HOME"; }

# _osrc_disk_conf <NAME> -> setting value (see header). NAME is always an internal literal.
_osrc_disk_conf() {
  local v=""
  [ "${_OSRC_DISK_MONITOR:-0}" = 1 ] || v="${!1:-}"
  [ -n "$v" ] || v="$(sed -n "s/^$1=//p" "$(_osrc_disk_dir)/settings" 2>/dev/null | tail -1 | tr -d '[:space:]')"
  printf '%s' "$v"
}

# ---- floors ----------------------------------------------------------------------

_osrc_disk_vol_kb() { df -kP "$OSRC_HOME" 2>/dev/null | awk 'NR==2 {print $2}'; }

# _osrc_disk_gb_kb <n> -> KB for a non-negative integer GB, or "" when not a plain integer.
_osrc_disk_gb_kb() {
  case "${1:-}" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$(( $1 * 1048576 ))" ;; esac
}

# _osrc_disk_floors_kb -> "<launch_kb> <pause_kb> <crit_kb>". A zero launch floor (the
# user disabled launch blocking) also disables the critical line.
_osrc_disk_floors_kb() {
  local vol launch pause crit
  if [ "$(_osrc_disk_conf OSRC_DISK_POLICY_OFF)" = "1" ]; then printf '10485760 0 0\n'; return 0; fi
  vol="$(_osrc_disk_vol_kb)"; case "$vol" in ''|*[!0-9]*) vol=0 ;; esac
  launch="$(_osrc_disk_gb_kb "$(_osrc_disk_conf OSRC_DISK_MIN_GB)")"
  if [ -z "$launch" ]; then
    launch=$(( vol * 5 / 100 )); [ "$launch" -lt 10485760 ] && launch=10485760
    # A small volume must not be blocked forever by a default it can never satisfy.
    [ "$vol" -gt 0 ] && [ "$launch" -gt $(( vol / 4 )) ] && launch=$(( vol / 4 ))
  fi
  pause="$(_osrc_disk_gb_kb "$(_osrc_disk_conf OSRC_DISK_PAUSE_GB)")"
  [ -n "$pause" ] || { pause=$(( vol * 2 / 100 )); [ "$pause" -lt 4194304 ] && pause=4194304; }
  crit="$(_osrc_disk_gb_kb "$(_osrc_disk_conf OSRC_DISK_CRITICAL_GB)")"
  if [ -z "$crit" ]; then
    crit=$(( vol / 200 )); [ "$crit" -lt 1048576 ] && crit=1048576; [ "$crit" -gt 4194304 ] && crit=4194304
  fi
  if [ "$launch" -le 0 ]; then crit=0
  else
    [ "$crit" -ge "$launch" ] && crit=$(( launch / 2 ))
    [ "$pause" -gt $(( launch * 3 / 4 )) ] && pause=$(( launch * 3 / 4 ))
  fi
  printf '%s %s %s\n' "$launch" "$pause" "$crit"
}

_osrc_disk_resume_kb() { # <launch_kb> <pause_kb>
  local l="${1:-0}" p="${2:-0}"
  case "$l$p" in *[!0-9]*) printf '0\n'; return 0 ;; esac
  if [ "$l" -gt "$p" ]; then printf '%s\n' "$(( p + (l - p) / 2 ))"; else printf '%s\n' "$(( p + 1048576 ))"; fi
}

_osrc_disk_fmt_kb() { # <kb> -> "6.2G" / "800M"
  local k="${1:-0}" g
  case "$k" in ''|*[!0-9]*) k=0 ;; esac
  if [ "$k" -ge 1048576 ]; then g=$(( k * 10 / 1048576 )); printf '%s.%sG' "$(( g / 10 ))" "$(( g % 10 ))"
  elif [ "$k" -ge 1024 ]; then printf '%sM' "$(( k / 1024 ))"; else printf '%sK' "$k"; fi
}

# ---- reporting --------------------------------------------------------------------

# _osrc_disk_swap -> "used/total" swap, or "?". macOS sysctl; Linux/Git Bash /proc/meminfo.
_osrc_disk_swap() {
  local line tot used fr
  line="$(sysctl -n vm.swapusage 2>/dev/null)"
  tot="$(printf '%s' "$line" | sed -n 's/.*total = \([0-9.]*[MG]\).*/\1/p')"
  used="$(printf '%s' "$line" | sed -n 's/.*used = \([0-9.]*[MG]\).*/\1/p')"
  [ -n "$tot" ] && [ -n "$used" ] && { printf '%s/%s' "$used" "$tot"; return 0; }
  tot="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  fr="$(awk '/^SwapFree:/{print $2}' /proc/meminfo 2>/dev/null)"
  case "$tot$fr" in ''|*[!0-9]*) printf '?'; return 0 ;; esac
  [ "$tot" -gt 0 ] && { printf '%sM/%sM' "$(( (tot - fr) / 1024 ))" "$(( tot / 1024 ))"; return 0; }
  printf '?'
}

_osrc_disk_report_oneline() {
  local free_kb vol_kb launch pause crit
  free_kb="$(_osrc_free_kb 2>/dev/null)"; vol_kb="$(_osrc_disk_vol_kb)"
  read -r launch pause crit <<<"$(_osrc_disk_floors_kb 2>/dev/null)"
  printf '(free %s/%s, launch floor %s, pause %s, critical %s, swap %s)' \
    "$(_osrc_disk_fmt_kb "$free_kb")" "$(_osrc_disk_fmt_kb "$vol_kb")" "$(_osrc_disk_fmt_kb "$launch")" \
    "$(_osrc_disk_fmt_kb "$pause")" "$(_osrc_disk_fmt_kb "$crit")" "$(_osrc_disk_swap)"
}

# _osrc_disk_report [items] -> free space, swap, biggest dirs under OSRC_HOME, and a bounded
# list of the Outsourcerer-created items that could free space. Best-effort; never fails.
_osrc_disk_report() {
  local items="${1:-}" top
  printf 'disk %s\n' "$(_osrc_disk_report_oneline)"
  top="$(_timeout 20 du -sk "$OSRC_HOME"/* 2>/dev/null | sort -rn | head -3 | awk '{n=$2; sub(/.*\//,"",n); printf "%s=%sK ", n, $1}')"
  printf 'top under OSRC_HOME: %s\n' "${top:-none}"
  have jq 2>/dev/null || return 0
  [ -n "$items" ] || items="$(_osrc_cleanup_items --no-size 2>/dev/null)"
  [ -n "$items" ] || { printf 'outsourcerer-created reclaimable: none recorded\n'; return 0; }
  printf 'outsourcerer-created reclaimable (first 10; auto = deleted under pressure once the lane is proven merged):\n'
  printf '%s\n' "$items" | jq -r 'select(.verdict=="SAFE")
    | (if (.kind=="worktree" or .kind=="branch" or .kind=="tmp") then "auto" else "manual" end)
      + "  " + .kind + "  " + .path' 2>/dev/null | head -10 | sed 's/^/  /'
  printf '  %s ASK item(s) need review; dry run: %s cleanup\n' \
    "$(printf '%s\n' "$items" | jq -s '[.[]|select(.verdict=="ASK")]|length' 2>/dev/null)" "$0"
}

# ---- override (explicit, one command, logged) -------------------------------------

# _osrc_disk_override_offer -> mint a one-use code (15 min) and print how to use it.
_osrc_disk_override_offer() {
  local code d; d="$(_osrc_disk_dir)"
  _mkdir_private "$d" >/dev/null 2>&1 || return 0
  code="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ "${#code}" = 8 ] || return 0
  printf '%s %s\n' "$code" "$(( $(date +%s) + 900 ))" > "$d/override.code" 2>/dev/null || return 0
  printf ' To launch this one command anyway: OSRC_DISK_OK=%s <same command> (one command, expires in 15 min, logged to %s/override.log; never below the critical floor).' "$code" "$d"
}

# _osrc_disk_override_take <free_kb> <launch_kb> -> 0 when this command holds valid consent.
# Always scrubs OSRC_DISK_OK so no delegate inherits it. The code binds to the first process
# ($$ + start identity) that uses it; subshells of that command share $$, others are refused.
_osrc_disk_override_take() {
  local v="${OSRC_DISK_OK:-}" d code exp bound me now
  unset OSRC_DISK_OK
  me="$$|$(_pid_start_identity "$$" 2>/dev/null)"
  [ "${_OSRC_DISK_OVERRIDE_OK:-}" = "$me" ] && return 0
  [ -n "$v" ] || return 1
  d="$(_osrc_disk_dir)"; now="$(date +%s)"
  read -r code exp bound < "$d/override.code" 2>/dev/null || return 1
  case "$exp" in ''|*[!0-9]*) return 1 ;; esac
  [ "$v" = "$code" ] && [ "$now" -le "$exp" ] || return 1
  if [ -n "$bound" ]; then [ "$bound" = "$me" ] || return 1
  else printf '%s %s %s\n' "$code" "$exp" "$me" > "$d/override.code" 2>/dev/null || return 1
  fi
  printf '%s\tfree_kb=%s\tlaunch_kb=%s\tpid=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$$" \
    >> "$d/override.log" 2>/dev/null || return 1
  _OSRC_DISK_OVERRIDE_OK="$me"
}

# ---- process identity + trees ----------------------------------------------------------

# _osrc_disk_same <pid> <identity> -> 0 when pid is alive and still that process.
_osrc_disk_same() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$2" ] && kill -0 "$1" 2>/dev/null && [ "$(_pid_start_identity "$1" 2>/dev/null)" = "$2" ]
}

# _osrc_disk_etime <pid> -> seconds since the process started ("" when unknown).
_osrc_disk_etime() {
  local e d=0 a b c
  e="$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')"
  case "$e" in ''|*[!0-9:-]*) return 1 ;; esac
  case "$e" in *-*) d="${e%%-*}"; e="${e#*-}" ;; esac
  IFS=: read -r a b c <<<"$e"
  [ -n "$c" ] || { c="$b"; b="$a"; a=0; }
  printf '%s' "$(( 10#$d * 86400 + 10#$a * 3600 + 10#$b * 60 + 10#$c ))"
}

# _osrc_disk_tree <root> -> live descendants of root, excluding this process, the monitor
# (a launcher may be its parent) and their children.
_osrc_disk_tree() {
  local m; m="$(cut -d'|' -f1 "$(_osrc_disk_dir)/monitor.lock/owner" 2>/dev/null)"
  ps -axo pid=,ppid= 2>/dev/null | awk -v r="$1" -v x="${_OSRC_DISK_ME:-$$}" -v m="${m:-0}" '
    { par[$1+0] = $2+0 }
    END { for (p in par) { if (p == x || p == m || p == r) continue; q = p; d = 0
            while ((q in par) && d++ < 32) { q = par[q]; if (q == x || q == m) break; if (q == r) { print p; break } } } }'
}

# ---- pause records ---------------------------------------------------------------------
# A record holds 'since|<epoch>', 'proc|<d|s>|<pid>|<group 0|1>|<start identity>' (d = work
# process, s = supervisor) and, for a tmux lane, 'pane|<session>|<tty>|<stty -g>'.
# Jobs: $OSRC_JOBS/<id>/disk-paused. Foreground/tmux lanes: disk-policy/paused/<reg>.

_osrc_disk_records() {
  local f
  for f in "$OSRC_JOBS"/*/disk-paused "$(_osrc_disk_dir)"/paused/*; do [ -f "$f" ] && printf '%s\n' "$f"; done
}
_osrc_disk_any_paused() {
  local f
  for f in "$OSRC_JOBS"/*/disk-paused "$(_osrc_disk_dir)"/paused/*; do [ -f "$f" ] && return 0; done
  return 1
}
_osrc_disk_recorded_pids() { _osrc_disk_records | while IFS= read -r f; do awk -F'|' '$1=="proc"{print $3}' "$f" 2>/dev/null; done; }

# _osrc_disk_rec_write <file> <content> -> 0 only when the record reads back intact.
_osrc_disk_rec_write() {
  local f="$1"
  if printf '%s' "$2" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null \
     && [ "$(cat "$f" 2>/dev/null)" = "$(printf '%s' "$2")" ]; then return 0; fi
  rm -f "$f.tmp" "$f" 2>/dev/null
  return 1
}

_osrc_disk_log() { printf '%s disk-policy: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$(_osrc_disk_dir)/monitor.log" 2>/dev/null || true; }

_osrc_disk_keepalive() { # <jd> <paused|resumed>
  printf '>>> [outsourcerer] disk-policy: job %s (free %s)\n' "$2" "$(_osrc_disk_fmt_kb "$(_osrc_free_kb 2>/dev/null)")" \
    >> "$1/out.log" 2>/dev/null || true
}

_osrc_disk_terminal_status() {
  case "${1:-}" in done|'done?'|failed|blocked|timeout|wedged|canceled|permission-blocked|interrupted) return 0 ;; esac
  return 1
}

# _osrc_disk_stop_rec <record> — SIGSTOP every process the (already persisted) record names.
_osrc_disk_stop_rec() {
  local tag role pid grp id
  while IFS='|' read -r tag role pid grp id; do
    [ "$tag" = proc ] && _osrc_disk_same "$pid" "$id" || continue
    if [ "$grp" = 1 ]; then kill -STOP -- "-$pid" 2>/dev/null; else kill -STOP "$pid" 2>/dev/null; fi
  done < "$1"
}

# _osrc_disk_pause_job <jd> -> 0 paused, 1 nothing to pause, 2 unverifiable, 3 record failed.
_osrc_disk_pause_job() {
  local jd="$1" pid spid did sid grp=0 own c q
  _osrc_disk_terminal_status "$(cat "$jd/status" 2>/dev/null)" && return 1
  [ -f "$jd/disk-paused" ] && return 1
  pid="$(cat "$jd/pid" 2>/dev/null)"; case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  [ "$pid" != "$$" ] && [ "$pid" != "${_OSRC_DISK_ME:-$$}" ] || return 1
  _pid_start_file_match "$pid" "$jd/pid_start" >/dev/null 2>&1 || return 2
  did="$(_pid_start_identity "$pid" 2>/dev/null)" || return 2
  # Group-signal only a delegate-led group: recorded pgid == pid == live pgid, and not ours.
  own="$(ps -o pgid= -p "${_OSRC_DISK_ME:-$$}" 2>/dev/null | tr -d ' ')"
  [ "$(cat "$jd/pgid" 2>/dev/null)" = "$pid" ] && [ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$pid" ] \
    && [ "$own" != "$pid" ] && grp=1
  c="since|$(date +%s)"$'\n'"proc|d|$pid|$grp|$did"$'\n'
  if [ "$grp" = 0 ]; then
    for q in $(_osrc_disk_tree "$pid"); do c="${c}proc|d|$q|0|$(_pid_start_identity "$q" 2>/dev/null)"$'\n'; done
  fi
  spid="$(cat "$jd/supervisor_pid" 2>/dev/null)"
  if _pid_start_file_match "$spid" "$jd/supervisor_pid_start" >/dev/null 2>&1 && sid="$(_pid_start_identity "$spid" 2>/dev/null)"; then
    c="${c}proc|s|$spid|0|$sid"$'\n'
  fi
  _osrc_disk_rec_write "$jd/disk-paused" "$c" || { _osrc_disk_log "cannot record pause of $jd; left running"; return 3; }
  _osrc_disk_stop_rec "$jd/disk-paused"
  _osrc_disk_keepalive "$jd" "paused under the disk pause floor; resumes automatically when space returns, or now: $0 disk resume"
}

# ---- foreground and tmux lanes ----------------------------------------------------------
# The launch gate registers what it cannot see in $OSRC_JOBS: a foreground launcher process
# (fg|pid|identity) or a tmux session about to start (tmux|name|registered-at|pane_pid|identity|
# launcher pid). A tmux registration stays pending, with no tmux call, while its launcher lives.

_osrc_disk_register_caller() { # <calling function>
  local d; d="$(_osrc_disk_dir)/procs"
  case "${1:-}" in
    route_delegate)
      [ -z "${OSRC_RUN_ID:-}" ] || return 0          # inside a bg job: the job record covers it
      local id; id="$(_pid_start_identity "$$" 2>/dev/null)" || return 0
      _mkdir_private "$d" >/dev/null 2>&1 && printf 'fg|%s|%s\n' "$$" "$id" > "$d/fg-$$" 2>/dev/null ;;
    session)
      [ "${OSRC_PLATFORM:-}" != windows ] && have tmux || return 0
      case "${SESSION_NAME:-}" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
      _mkdir_private "$d" >/dev/null 2>&1 && printf 'tmux|%s|%s|||%s\n' "$SESSION_NAME" "$(date +%s)" "$$" > "$d/tmux-$SESSION_NAME" 2>/dev/null ;;
  esac
  return 0
}

# _osrc_disk_reg_root <reg> -> the verified root pid whose descendants are the lane's work.
# Drops a registration that no longer names the process/session it was made for. A tmux
# pane binds on first sight, and only when its shell started after the registration.
_osrc_disk_reg_root() {
  local r="$1" kind a b c d e cur et
  IFS='|' read -r kind a b c d e < "$r" 2>/dev/null || return 1
  [ "$kind" = tmux ] && [ -z "$c" ] && [ -n "$e" ] && kill -0 "$e" 2>/dev/null && return 1
  case "$kind" in
    fg) _osrc_disk_same "$a" "$b" && { printf '%s' "$a"; return 0; } ;;
    tmux)
      if have tmux && tmux has-session -t "=$a" 2>/dev/null; then
        cur="$(tmux display-message -p -t "=$a:" '#{pane_pid}' 2>/dev/null)"
        if [ -z "$c" ]; then
          et="$(_osrc_disk_etime "$cur")" && [ $(( $(date +%s) - et + 5 )) -ge "${b:-0}" ] \
            && d="$(_pid_start_identity "$cur" 2>/dev/null)" \
            && printf 'tmux|%s|%s|%s|%s\n' "$a" "$b" "$cur" "$d" > "$r" 2>/dev/null && { printf '%s' "$cur"; return 0; }
        elif [ "$cur" = "$c" ] && _osrc_disk_same "$c" "$d"; then printf '%s' "$c"; return 0
        fi
      fi ;;
  esac
  rm -f "$r" 2>/dev/null; return 1
}

# _osrc_disk_pause_reg <reg> -> 0 paused, 1 nothing to pause, 3 record failed.
_osrc_disk_pause_reg() {
  local r="$1" key root c q have_pids tty="" st="" name
  key="${r##*/}"
  [ -f "$(_osrc_disk_dir)/paused/$key" ] && return 1
  root="$(_osrc_disk_reg_root "$r")" || return 1
  have_pids=" $(_osrc_disk_recorded_pids | tr '\n' ' ') "
  c="since|$(date +%s)"$'\n'
  for q in $(_osrc_disk_tree "$root"); do
    case "$have_pids" in *" $q "*) continue ;; esac
    c="${c}proc|d|$q|0|$(_pid_start_identity "$q" 2>/dev/null)"$'\n'
  done
  case "$c" in *proc*) : ;; *) return 1 ;; esac
  case "$key" in tmux-*)
    name="${key#tmux-}"
    tty="$(tmux display-message -p -t "=$name:" '#{pane_tty}' 2>/dev/null)"
    [ -c "$tty" ] && st="$(stty -g < "$tty" 2>/dev/null)"
    c="${c}pane|$name|$tty|$st"$'\n' ;;
  esac
  _mkdir_private "$(_osrc_disk_dir)/paused" >/dev/null 2>&1
  _osrc_disk_rec_write "$(_osrc_disk_dir)/paused/$key" "$c" || { _osrc_disk_log "cannot record pause of $key; left running"; return 3; }
  _osrc_disk_stop_rec "$(_osrc_disk_dir)/paused/$key"
}

# _osrc_disk_pane_restore <session> <tty> <stty> <pids> — after SIGCONT, a TUI that its pane
# shell parked in job control is brought back with `fg`, its saved terminal mode is restored
# and it is told to redraw.
_osrc_disk_pane_restore() {
  local name="$1" tty="$2" st="$3" pids="$4" cur i=0 p
  have tmux && tmux has-session -t "=$name" 2>/dev/null || return 0
  cur="$(tmux display-message -p -t "=$name:" '#{pane_current_command}' 2>/dev/null)"
  case "${cur#-}" in bash|zsh|sh|dash|ksh|fish)
    tmux send-keys -t "=$name:" fg Enter 2>/dev/null
    while [ "$i" -lt 30 ]; do
      cur="$(tmux display-message -p -t "=$name:" '#{pane_current_command}' 2>/dev/null)"
      case "${cur#-}" in bash|zsh|sh|dash|ksh|fish) sleep 0.1; i=$((i+1)) ;; *) break ;; esac
    done ;;
  esac
  [ -n "$st" ] && [ -c "$tty" ] && stty "$st" < "$tty" 2>/dev/null
  for p in $pids; do kill -WINCH "$p" 2>/dev/null; done
  return 0
}

# ---- resume -----------------------------------------------------------------------------

# _osrc_disk_resume_rec <record> -> 0 when retired. SIGCONTs every recorded process that is
# still the same process; keeps the record if any required SIGCONT fails.
_osrc_disk_resume_rec() {
  local rec="$1" tag a b c d since="" keep=0 live="" panes="" jd now
  [ -f "$rec" ] || return 0
  while IFS='|' read -r tag a b c d; do
    case "$tag" in
      since) since="$a" ;;
      proc)
        _osrc_disk_same "$b" "$d" || continue
        [ "$c" = 1 ] && [ "$(ps -o pgid= -p "$b" 2>/dev/null | tr -d ' ')" = "$b" ] && { kill -CONT -- "-$b" 2>/dev/null || keep=1; }
        kill -CONT "$b" 2>/dev/null || keep=1
        live="$live $b" ;;
      pane) panes="$panes$a|$b|$c"$'\n' ;;
    esac
  done < "$rec"
  [ "$keep" = 0 ] || { _osrc_disk_log "SIGCONT failed for $rec; record kept"; return 1; }
  while IFS='|' read -r a b c; do [ -n "$a" ] && _osrc_disk_pane_restore "$a" "$b" "$c" "$live"; done <<<"$panes"
  case "$rec" in */disk-paused)
    jd="${rec%/disk-paused}"; now="$(date +%s)"
    case "$since" in ''|*[!0-9]*) : ;; *)
      b="$(cat "$jd/disk-paused-secs" 2>/dev/null)"; case "$b" in ''|*[!0-9]*) b=0 ;; esac
      printf '%s\n' "$(( b + now - since ))" > "$jd/disk-paused-secs" 2>/dev/null ;;
    esac
    _osrc_disk_keepalive "$jd" resumed ;;
  esac
  rm -f "$rec" 2>/dev/null
}

_osrc_disk_resume_all() {
  local r n=0
  while IFS= read -r r; do [ -n "$r" ] && _osrc_disk_resume_rec "$r" && n=$((n+1)); done <<<"$(_osrc_disk_records)"
  printf '%s' "$n"
}

# _osrc_disk_paused_secs <jd> -> total seconds the job has spent disk-paused, including an
# ongoing pause. The watchdog subtracts this from its wall-clock deadlines.
_osrc_disk_paused_secs() {
  local t s
  t="$(cat "$1/disk-paused-secs" 2>/dev/null)"; case "$t" in ''|*[!0-9]*) t=0 ;; esac
  s="$(sed -n 's/^since|//p' "$1/disk-paused" 2>/dev/null)"
  case "$s" in ''|*[!0-9]*) : ;; *) t=$(( t + $(date +%s) - s )) ;; esac
  printf '%s' "$t"
}

# _osrc_disk_record_sweep — retire records whose work is over: the job turned terminal (e.g.
# canceled while paused) or no recorded work process survives. Survivors (a stopped
# supervisor) are resumed first, so nothing is left frozen.
_osrc_disk_record_sweep() {
  local r tag a b c d alive
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$r" in */disk-paused)
      _osrc_disk_terminal_status "$(cat "${r%/disk-paused}/status" 2>/dev/null)" && { _osrc_disk_resume_rec "$r"; continue; } ;;
    esac
    alive=0
    while IFS='|' read -r tag a b c d; do
      [ "$tag$a" = procd ] && _osrc_disk_same "$b" "$d" && { alive=1; break; }
    done < "$r"
    [ "$alive" = 1 ] || _osrc_disk_resume_rec "$r"
  done <<<"$(_osrc_disk_records)"
}

# _osrc_disk_pause_sweep -> "<paused> <unverifiable>" counts for this sweep.
_osrc_disk_pause_sweep() {
  local jd r n=0 u=0 rc
  for jd in "$OSRC_JOBS"/*/; do
    [ -d "$jd" ] || continue
    _osrc_disk_pause_job "${jd%/}"; rc=$?
    case "$rc" in 0) n=$((n+1)) ;; 2|3) u=$((u+1)) ;; esac
  done
  for r in "$(_osrc_disk_dir)"/procs/*; do
    [ -f "$r" ] || continue
    _osrc_disk_pause_reg "$r"; rc=$?
    case "$rc" in 0) n=$((n+1)) ;; 3) u=$((u+1)) ;; esac
  done
  printf '%s %s' "$n" "$u"
}

# ---- wakes (one per transition per pressure episode) -----------------------------------

_osrc_disk_episode() { # -> current episode id, creating one when asked (arg "new")
  local f e; f="$(_osrc_disk_dir)/.episode"
  e="$(cat "$f" 2>/dev/null)"
  if [ -z "$e" ] && [ "${1:-}" = new ]; then
    e="$(date +%s).$$.$RANDOM"; printf '%s\n' "$e" > "$f" 2>/dev/null
  fi
  printf '%s' "$e"
}

_osrc_disk_wake() { # <kind> <summary>
  local d ep; d="$(_osrc_disk_dir)"
  type _wake_append >/dev/null 2>&1 && have jq 2>/dev/null || return 0
  ep="$(_osrc_disk_episode)"; [ -n "$ep" ] || ep="$(date +%s)"
  [ "$(cat "$d/.woke-$1" 2>/dev/null)" = "$ep" ] && return 0
  _wake_append "$(jq -cn --arg eid "disk.$ep.$1" --arg k "disk-$1" --arg s "$2" \
    '{event_id:$eid,kind:$k,state:"disk",task_summary:$s}' 2>/dev/null)" >/dev/null 2>&1 || return 0
  printf '%s\n' "$ep" > "$d/.woke-$1" 2>/dev/null
  return 0
}

_osrc_disk_episode_end() { rm -f "$(_osrc_disk_dir)/.episode" "$(_osrc_disk_dir)/hold" 2>/dev/null; }

# ---- merged-lane auto-reclaim -------------------------------------------------------------

# _osrc_disk_protected_inside <dir> -> 0 when the tree holds anything never auto-deleted.
_osrc_disk_protected_inside() {
  [ -n "$(find "$1" -mindepth 1 \( -path "$1/.git" -prune \) -o \( -name '.env' -o -name '.env.*' \
    -o -name .venv -o -name venv -o -name node_modules -o -name '*[Bb]ackup*' -o -name '*.bak' \
    -o -name .git -o -name store -o -name state \) -print 2>/dev/null | head -1)" ]
}

# _osrc_disk_lane_sha <repo> <branch> <base> -> the branch tip, only when it is preserved
# on main/remote (or a tip-matched merged PR) and did not move during the proof.
_osrc_disk_lane_sha() {
  local sha
  sha="$(git -C "$1" rev-parse -q --verify "refs/heads/$2" 2>/dev/null)" || return 1
  _osrc_branch_merged "$1" "$2" "$3" || return 1
  [ "$(git -C "$1" rev-parse -q --verify "refs/heads/$2" 2>/dev/null)" = "$sha" ] && printf '%s' "$sha"
}

_osrc_disk_cl_log() { printf '%s\t%s\tdisk-policy\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$(_osrc_cl_log)" 2>/dev/null || true; }

# _osrc_disk_reclaim_lane <session> <items> -> count deleted. Order: worktree (live branch
# must match the receipt and HEAD must be the proven commit; no untracked, ignored or
# protected content), then the recorded branch (conditional on the proven commit and not
# checked out anywhere), then the lane's SAFE scratch (no protected content).
_osrc_disk_reclaim_lane() {
  local s="$1" items="$2" wj br base repo wt sha pp n=0 t
  wj="$OSRC_JOBS/$s/worktree.json"; [ -f "$wj" ] || wj="$OSRC_HOME/loops/$s/worktree.json"
  br="$(jq -r '.branch // ""' "$wj" 2>/dev/null)"; base="$(jq -r '.base_sha // ""' "$wj" 2>/dev/null)"
  [ -n "$br" ] || { printf 0; return 0; }
  # Any worktree of this lane that is not SAFE (dirty, live owner...) keeps the whole lane.
  [ -z "$(printf '%s\n' "$items" | jq -r --arg s "$s" 'select(.session==$s and .kind=="worktree" and .verdict=="ASK") | .path' 2>/dev/null)" ] || { printf 0; return 0; }
  repo="$(printf '%s\n' "$items" | jq -r --arg s "$s" 'select(.session==$s and (.kind=="worktree" or .kind=="branch")) | .repo' 2>/dev/null | head -1)"
  [ -n "$repo" ] || { printf 0; return 0; }
  sha="$(_osrc_disk_lane_sha "$repo" "$br" "$base")" || { printf 0; return 0; }
  wt="$(printf '%s\n' "$items" | jq -c --arg s "$s" 'select(.session==$s and .kind=="worktree" and .verdict=="SAFE")' 2>/dev/null | head -1)"
  if [ -n "$wt" ]; then
    [ "$(_osrc_cleanup_verdict "$(jq -c 'del(.verdict,.why,.size_kb)' <<<"$wt")" 2>/dev/null | cut -f1)" = SAFE ] || { printf 0; return 0; }
    pp="$(_osrc_realpath "$(jq -r '.path' <<<"$wt")" 2>/dev/null)" || { printf 0; return 0; }
    if [ "$(git -C "$pp" symbolic-ref -q HEAD 2>/dev/null)" != "refs/heads/$br" ] \
       || [ "$(git -C "$pp" rev-parse -q --verify HEAD 2>/dev/null)" != "$sha" ]; then
      _osrc_disk_log "kept $pp: live HEAD is not the receipt branch at the proven commit"; printf 0; return 0
    fi
    if [ -n "$(git -C "$pp" status --porcelain --ignored --untracked-files=all 2>/dev/null | head -1)" ] \
       || _osrc_disk_protected_inside "$pp"; then
      _osrc_disk_log "kept $pp: untracked, ignored or protected content (review: $0 cleanup)"; printf 0; return 0
    fi
    git -C "$repo" worktree remove "$pp" >/dev/null 2>&1 || { printf 0; return 0; }
    _osrc_disk_cl_log removed-worktree "$pp"; n=$((n+1))
  fi
  if [ -n "$(printf '%s\n' "$items" | jq -r --arg s "$s" --arg b "$br" 'select(.session==$s and .kind=="branch" and .path==$b) | .path' 2>/dev/null)" ] \
     && ! _osrc_branch_checked_out "$repo" "$br" \
     && git -C "$repo" update-ref -d "refs/heads/$br" "$sha" >/dev/null 2>&1; then
    _osrc_disk_cl_log removed-branch "$br@$sha ($repo)"; n=$((n+1))
  fi
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [ "$(_osrc_cleanup_verdict "$t" 2>/dev/null | cut -f1)" = SAFE ] || continue
    pp="$(jq -r '.path' <<<"$t")"
    _osrc_disk_protected_inside "$pp" && { _osrc_disk_log "kept scratch $pp: protected content"; continue; }
    rm -rf "$pp" 2>/dev/null && [ ! -e "$pp" ] && { _osrc_disk_cl_log removed-scratch "$pp"; n=$((n+1)); }
  done <<<"$(printf '%s\n' "$items" | jq -c --arg s "$s" 'select(.session==$s and .kind=="tmp" and .verdict=="SAFE") | del(.verdict,.why,.size_kb)' 2>/dev/null)"
  printf '%s' "$n"
}

# _osrc_disk_reclaim [items] -> count deleted, at most OSRC_DISK_RECLAIM_MAX lanes' worth
# (default 10, 0 disables).
_osrc_disk_reclaim() {
  local max items s n=0 k
  have jq 2>/dev/null || { printf 0; return 0; }
  max="$(_osrc_disk_conf OSRC_DISK_RECLAIM_MAX)"; case "$max" in ''|*[!0-9]*) max=10 ;; esac
  [ "$max" -gt 0 ] || { printf 0; return 0; }
  items="${1:-$(_osrc_cleanup_items --no-size 2>/dev/null)}"
  while IFS= read -r s; do
    [ -n "$s" ] && [ "$max" -gt 0 ] || continue
    k="$(_osrc_disk_reclaim_lane "$s" "$items")"; case "$k" in ''|*[!0-9]*) k=0 ;; esac
    n=$((n+k)); max=$((max-1))
  done <<<"$(printf '%s\n' "$items" | jq -r 'select(.verdict=="SAFE" and (.kind=="worktree" or .kind=="branch")) | .session' 2>/dev/null | sort -u)"
  printf '%s' "$n"
}

# ---- the policy tick --------------------------------------------------------------------

# _osrc_disk_monitor_tick — one pass; never fails. Order under pressure: pause and wake
# first, then the (slow) report scan and bounded reclaim, then remeasure and maybe resume.
_osrc_disk_monitor_tick() {
  local d free_kb launch pause crit resume counts n u items k
  d="$(_osrc_disk_dir)"; _mkdir_private "$d" >/dev/null 2>&1
  free_kb="$(_osrc_free_kb 2>/dev/null)"; case "$free_kb" in ''|*[!0-9]*) return 0 ;; esac
  read -r launch pause crit <<<"$(_osrc_disk_floors_kb 2>/dev/null)"
  case "$launch$pause$crit" in ''|*[!0-9]*) return 0 ;; esac
  resume="$(_osrc_disk_resume_kb "$launch" "$pause")"
  _osrc_disk_record_sweep
  if [ "$free_kb" -ge "$resume" ]; then
    if _osrc_disk_any_paused; then
      k="$(_osrc_disk_resume_all)"
      _osrc_disk_wake resumed "disk recovered to $(_osrc_disk_fmt_kb "$free_kb"); $k paused lane(s) resumed"
    fi
    _osrc_disk_episode_end; return 0
  fi
  [ "$free_kb" -ge "$pause" ] && return 0      # between pause and resume: hold, add nothing
  _osrc_disk_episode new >/dev/null
  if [ -f "$d/hold" ] && [ "$free_kb" -ge "$crit" ]; then counts="0 0"   # owner ran `disk resume`
  else counts="$(_osrc_disk_pause_sweep)"; fi
  read -r n u <<<"$counts"
  if _osrc_disk_any_paused || [ "${u:-0}" -gt 0 ]; then
    _osrc_disk_wake paused "disk pressure: free $(_osrc_disk_fmt_kb "$free_kb") under the pause floor; $(_osrc_disk_records | grep -c .) lane(s) SIGSTOPped (never killed), ${u:-0} could not be verified and keep running. They resume when space returns; resume now: $0 disk resume. $(_osrc_disk_report_oneline)"
  fi
  [ "$crit" -gt 0 ] && [ "$free_kb" -lt "$crit" ] && _osrc_disk_wake critical \
    "CRITICAL disk: free $(_osrc_disk_fmt_kb "$free_kb") under the critical floor; launches refused. Free space: $0 cleanup, then empty Trash/caches. $(_osrc_disk_report_oneline)"
  [ "$(cat "$d/.reported" 2>/dev/null)" = "$(_osrc_disk_episode)" ] && return 0
  _osrc_disk_episode > "$d/.reported" 2>/dev/null
  have jq 2>/dev/null && items="$(_osrc_cleanup_items --no-size 2>/dev/null)"
  { printf '=== disk pressure %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; _osrc_disk_report "${items:-}"; } >> "$d/monitor.log" 2>/dev/null
  k="$(_osrc_disk_reclaim "${items:-}")"; case "$k" in ''|*[!0-9]*) k=0 ;; esac
  [ "$k" -gt 0 ] || return 0
  free_kb="$(_osrc_free_kb 2>/dev/null)"; case "$free_kb" in ''|*[!0-9]*) return 0 ;; esac
  _osrc_disk_log "reclaimed $k merged-lane item(s); free now $(_osrc_disk_fmt_kb "$free_kb")"
  if [ "$free_kb" -ge "$resume" ]; then
    k="$(_osrc_disk_resume_all)"
    _osrc_disk_wake resumed "disk recovered to $(_osrc_disk_fmt_kb "$free_kb") after merged-lane reclaim; $k lane(s) resumed"
    _osrc_disk_episode_end
  fi
  return 0
}

# ---- monitor ------------------------------------------------------------------------------
# Ownership is a lock dir (monitor.lock/owner = "pid|start identity") held for the monitor's
# whole life and re-verified every tick. A launch writes a fresh demand token BEFORE checking
# the owner; the monitor releases the lock BEFORE its last demand check, so a launch racing an
# idle exit either keeps the old monitor running or spawns a new one.

_osrc_disk_lock_alive() {
  local lk c pid id m; lk="$(_osrc_disk_dir)/monitor.lock"
  [ -d "$lk" ] || return 1
  c="$(cat "$lk/owner" 2>/dev/null)"
  if [ -z "$c" ]; then   # being created: alive for a few seconds
    m="$(stat -c %Y "$lk" 2>/dev/null || stat -f %m "$lk" 2>/dev/null || echo 0)"
    [ $(( $(date +%s) - m )) -lt 10 ]; return
  fi
  pid="${c%%|*}"; id="${c#*|}"
  if [ -n "$id" ]; then _osrc_disk_same "$pid" "$id"; else kill -0 "$pid" 2>/dev/null; fi
}

_osrc_disk_lock_take() {
  local lk; lk="$(_osrc_disk_dir)/monitor.lock"
  if ! mkdir "$lk" 2>/dev/null; then
    _osrc_disk_lock_alive && return 1
    mv "$lk" "$lk.stale.$_OSRC_DISK_ME" 2>/dev/null && rm -rf "$lk.stale.$_OSRC_DISK_ME"
    mkdir "$lk" 2>/dev/null || return 1
  fi
  printf '%s|%s\n' "$_OSRC_DISK_ME" "$_OSRC_DISK_ME_ID" > "$lk/owner" 2>/dev/null && return 0
  rm -rf "$lk"; return 1
}
_osrc_disk_lock_mine() { [ "$(cat "$(_osrc_disk_dir)/monitor.lock/owner" 2>/dev/null)" = "$_OSRC_DISK_ME|$_OSRC_DISK_ME_ID" ]; }
_osrc_disk_lock_release() { _osrc_disk_lock_mine && rm -rf "$(_osrc_disk_dir)/monitor.lock"; _OSRC_DISK_OWNER=0; }

# Every orderly exit and TERM/INT goes through here: resume what we paused, then let go.
_osrc_disk_monitor_exit() {
  [ "${_OSRC_DISK_OWNER:-0}" = 1 ] || return 0
  _osrc_disk_resume_all >/dev/null
  _osrc_disk_lock_release
  _osrc_disk_log "monitor $_OSRC_DISK_ME exited; recorded pauses resumed"
}

# _osrc_disk_fleet_live -> 0 while any job, registered lane or pause record is live.
_osrc_disk_fleet_live() {
  local jd pid r
  _osrc_disk_any_paused && return 0
  for jd in "$OSRC_JOBS"/*/; do
    [ -d "$jd" ] || continue
    _osrc_disk_terminal_status "$(cat "$jd/status" 2>/dev/null)" && continue
    pid="$(cat "$jd/pid" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) [ "$(cat "$jd/status" 2>/dev/null)" = launching ] && return 0; continue ;; esac
    kill -0 "$pid" 2>/dev/null && return 0
  done
  for r in "$(_osrc_disk_dir)"/procs/*; do [ -f "$r" ] && _osrc_disk_reg_root "$r" >/dev/null && return 0; done
  return 1
}

_osrc_disk_monitor_loop() {
  trap '' HUP
  local d poll maxidle idle=0 dem last sz
  d="$(_osrc_disk_dir)"
  _OSRC_DISK_MONITOR=1
  unset OSRC_DISK_OK OSRC_DISK_MIN_GB OSRC_DISK_PAUSE_GB OSRC_DISK_CRITICAL_GB OSRC_DISK_POLICY_OFF OSRC_DISK_RECLAIM_MAX
  exec >>"$d/monitor.log" 2>&1 || exec >/dev/null 2>&1
  _OSRC_DISK_ME="${BASHPID:-}"
  if [ -z "$_OSRC_DISK_ME" ]; then   # bash 3.2: a direct child's PPID is this subshell
    sz="$(mktemp "$d/.me.XXXXXX" 2>/dev/null)" && sh -c 'echo "$PPID"' > "$sz" 2>/dev/null
    _OSRC_DISK_ME="$(cat "$sz" 2>/dev/null)"; rm -f "$sz" 2>/dev/null
  fi
  case "$_OSRC_DISK_ME" in ''|*[!0-9]*) exit 0 ;; esac
  _OSRC_DISK_ME_ID="$(_pid_start_identity "$_OSRC_DISK_ME" 2>/dev/null)"
  _osrc_disk_lock_take || exit 0
  _OSRC_DISK_OWNER=1
  trap '_osrc_disk_monitor_exit' EXIT
  trap 'exit 0' TERM INT
  poll="${OSRC_DISK_POLICY_POLL:-30}"; case "$poll" in ''|*[!0-9]*|0) poll=30 ;; esac
  maxidle="${OSRC_DISK_MONITOR_IDLE_TICKS:-40}"; case "$maxidle" in ''|*[!0-9]*) maxidle=40 ;; esac
  last="$(cat "$d/demand" 2>/dev/null)"
  _osrc_disk_log "monitor $_OSRC_DISK_ME started"
  while :; do
    _osrc_disk_lock_mine || { _OSRC_DISK_OWNER=0; exit 0; }   # another monitor owns it now
    sz="$(wc -c < "$d/monitor.log" 2>/dev/null | tr -d ' ')"
    if [ "${sz:-0}" -gt 524288 ] 2>/dev/null; then
      tail -n 200 "$d/monitor.log" > "$d/monitor.log.tmp" 2>/dev/null && mv -f "$d/monitor.log.tmp" "$d/monitor.log" 2>/dev/null
    fi
    dem="$(cat "$d/demand" 2>/dev/null)"; [ "$dem" = "$last" ] || { idle=0; last="$dem"; }
    if _osrc_disk_fleet_live; then idle=0; else idle=$((idle+1)); fi
    _osrc_disk_monitor_tick
    if [ "$idle" -ge "$maxidle" ]; then
      _osrc_disk_lock_release
      dem="$(cat "$d/demand" 2>/dev/null)"
      if [ "$dem" != "$last" ] && _osrc_disk_lock_take; then _OSRC_DISK_OWNER=1; idle=0; last="$dem"; continue; fi
      _osrc_disk_log "monitor $_OSRC_DISK_ME idle; exiting"
      exit 0
    fi
    sleep "$poll"
  done
}

# _osrc_disk_monitor_ensure — called on every launch: post demand, spawn a monitor unless a
# verified owner is alive. The child closes every inherited descriptor (fd 5 is a caller's
# stderr during background preflight) so it never holds a caller's pipe open.
_osrc_disk_monitor_ensure() {
  [ "$(_osrc_disk_conf OSRC_DISK_POLICY_OFF)" = "1" ] && return 0
  [ -n "${OSRC_HOME:-}" ] && [ -d "$OSRC_HOME" ] || return 0
  local d; d="$(_osrc_disk_dir)"
  _mkdir_private "$d" >/dev/null 2>&1 || return 0
  printf '%s.%s.%s\n' "$(date +%s)" "$$" "$RANDOM" > "$d/demand" 2>/dev/null
  _osrc_disk_lock_alive && return 0
  ( _osrc_disk_monitor_loop ) 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- </dev/null >/dev/null 2>&1 &
  return 0
}

# _osrc_disk_heartbeat — the heartbeat's recovery hook: pause records with no live monitor
# (it died abruptly) get a fresh monitor, which resumes them once space allows.
_osrc_disk_heartbeat() {
  _osrc_disk_any_paused || return 0
  _osrc_disk_lock_alive || _osrc_disk_monitor_ensure
  return 0
}

# `outsourcerer disk [status|resume]` — resume is the one-command way back: it resumes every
# paused lane now (TUIs return to the foreground) and holds new pauses until the disk
# recovers or crosses the critical floor.
_osrc_disk_cmd() {
  local d; d="$(_osrc_disk_dir)"
  case "${1:-status}" in
    status)
      _osrc_disk_report
      _osrc_disk_records | sed 's/^/paused: /' ;;
    resume)
      _mkdir_private "$d" >/dev/null 2>&1
      date +%s > "$d/hold" 2>/dev/null
      printf '[outsourcerer] disk: resumed %s paused lane(s); no new pauses until space recovers or falls under the critical floor.\n' "$(_osrc_disk_resume_all)" ;;
    *) die "disk: status | resume" ;;
  esac
}
