#!/usr/bin/env bash
# lib/disk_policy.sh — disk pressure policy: launch floors, while-running pause/resume of the
# processes Outsourcerer launched, merged-lane auto-reclaim, and the detached monitor.
# Sourced by the lib loader; defines functions only, runs nothing at load time. Bash 3.2 + Git Bash.
#
# Floors (KB, from the volume holding $OSRC_HOME; see references/jobs-and-safety.md):
#   launch   = OSRC_DISK_MIN_GB, else max(10GB, 5% of volume) capped at 25% of a small volume
#   pause    = OSRC_DISK_PAUSE_GB, else max(4GB, 2% of volume), always under 3/4 of launch
#   critical = OSRC_DISK_CRITICAL_GB, else 0.5% of volume clamped to 1..4GB, under a non-zero launch
#   resume   = pause + half the pause->launch gap (hysteresis)
# Settings come ONLY from $OSRC_HOME/disk-policy/settings (NAME=value lines, never sourced):
# no environment variable moves a floor, so an inherited export cannot open the gate.
#
# Rules: nothing bypasses the critical floor. OSRC_DISK_OK takes only the one-use code a
# refusal prints, binds to one command (a bg/fanout job it launches gets a one-use admit
# token), is scrubbed from the delegate environment, and needs a successful audit append.
# Pausing writes its record BEFORE any SIGSTOP, signals only identity-verified processes
# Outsourcerer launched, never kills, and defers (to the next tick) a lane that holds an
# Outsourcerer lock or runs a young git command. A monitor exit resumes what is paused only
# when space is back above the pause floor, the owner ran `disk resume`, or free space cannot
# be read; otherwise the records stay for the next monitor. Auto-reclaim touches only a lane
# proven merged at a pinned commit. A stopped lock holder still passes `kill -0`, so lock
# breakers treat it as alive (paused), never as dead.

_osrc_disk_dir() { printf '%s/disk-policy' "$OSRC_HOME"; }

# _osrc_disk_conf <NAME> -> setting value from the settings file. NAME is an internal literal.
_osrc_disk_conf() { sed -n "s/^$1=//p" "$(_osrc_disk_dir)/settings" 2>/dev/null | tail -1 | tr -d '[:space:]'; }

# ---- floors ----------------------------------------------------------------------

_osrc_disk_vol_kb() { df -kP "$OSRC_HOME" 2>/dev/null | awk 'NR==2 {print $2}'; }

# _osrc_disk_gb_kb <n> -> KB for a whole number of GB (at most 7 digits, capped at 1,000,000 GB so
# the product never wraps), or "" when not one: the caller uses the default, `disk status` names it.
_osrc_disk_gb_kb() {
  case "${1:-}" in ''|*[!0-9]*|????????*) printf '' ;;
    *) local g=$(( 10#$1 )); [ "$g" -le 1000000 ] || g=1000000; printf '%s' "$(( g * 1048576 ))" ;; esac
}

_osrc_disk_rejected() { # -> "NAME=value ..." for each floor setting the floors ignored
  local n v out=""
  for n in OSRC_DISK_MIN_GB OSRC_DISK_PAUSE_GB OSRC_DISK_CRITICAL_GB; do
    v="$(_osrc_disk_conf "$n")"; [ -n "$v" ] && [ -z "$(_osrc_disk_gb_kb "$v")" ] && out="$out $n=$v"
  done
  printf '%s' "${out# }"
}

# _osrc_disk_floors_kb -> "<launch_kb> <pause_kb> <crit_kb>". The critical floor stays when
# launch blocking is off (launch 0 or POLICY_OFF, which also turns pausing off).
_osrc_disk_floors_kb() {
  local vol launch pause="" crit
  vol="$(_osrc_disk_vol_kb)"; case "$vol" in ''|*[!0-9]*) vol=0 ;; esac
  crit="$(_osrc_disk_gb_kb "$(_osrc_disk_conf OSRC_DISK_CRITICAL_GB)")"
  if [ -z "$crit" ]; then
    crit=$(( vol / 200 )); [ "$crit" -lt 1048576 ] && crit=1048576; [ "$crit" -gt 4194304 ] && crit=4194304
  fi
  if [ "$(_osrc_disk_conf OSRC_DISK_POLICY_OFF)" = "1" ]; then launch=10485760; pause=0
  else launch="$(_osrc_disk_gb_kb "$(_osrc_disk_conf OSRC_DISK_MIN_GB)")"; pause="$(_osrc_disk_gb_kb "$(_osrc_disk_conf OSRC_DISK_PAUSE_GB)")"
  fi
  if [ -z "$launch" ]; then
    launch=$(( vol * 5 / 100 )); [ "$launch" -lt 10485760 ] && launch=10485760
    # A small volume must not be blocked forever by a default it can never satisfy.
    [ "$vol" -gt 0 ] && [ "$launch" -gt $(( vol / 4 )) ] && launch=$(( vol / 4 ))
  fi
  [ -n "$pause" ] || { pause=$(( vol * 2 / 100 )); [ "$pause" -lt 4194304 ] && pause=4194304; }
  if [ "$launch" -gt 0 ]; then
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
  top="$(_osrc_disk_rejected)"
  [ -z "$top" ] || printf 'settings rejected (not a whole number of GB, at most 7 digits), default used: %s\n' "$top"
  top="$(_timeout 20 du -sk "$OSRC_HOME"/* 2>/dev/null | sort -rn | head -3 | awk '{n=$2; sub(/.*\//,"",n); printf "%s=%sK ", n, $1}')"
  printf 'top under OSRC_HOME: %s\n' "${top:-none}"
  have jq 2>/dev/null || return 0
  [ -n "$items" ] || items="$(_osrc_cleanup_items --no-size 2>/dev/null)"
  [ -n "$items" ] || { printf 'outsourcerer-created reclaimable: none recorded\n'; return 0; }
  printf 'outsourcerer-created reclaimable (first 10; auto = deleted under pressure once the lane is proven merged):\n'
  printf '%s\n' "$items" | jq -r 'select(.verdict=="SAFE")
    | (if (.kind=="worktree" or .kind=="branch") then "auto" else "manual" end)
      + "  " + .kind + "  " + .path' 2>/dev/null | head -10 | sed 's/^/  /'
  printf '  %s ASK item(s) need review; dry run: %s cleanup\n' \
    "$(printf '%s\n' "$items" | jq -s '[.[]|select(.verdict=="ASK")]|length' 2>/dev/null)" "$0"
}

# ---- override (explicit, one command, logged) -------------------------------------

# _osrc_disk_code_live <file> -> "<code> <expiry>" when it holds a code with more than two
# minutes left that no command has claimed yet (claimed = override.taken.<code> exists).
_osrc_disk_code_live() {
  local code exp d; d="$(_osrc_disk_dir)"
  read -r code exp 2>/dev/null < "$1" || return 1
  case "$code:$exp" in *[!0-9a-f:]*|:*|*:) return 1 ;; esac
  [ "$(( exp - $(date +%s) ))" -gt 120 ] && [ ! -e "$d/override.taken.$code" ] && printf '%s %s' "$code" "$exp"
}

# _osrc_disk_override_offer -> print how to use the one-use code (15 min). A still-valid,
# unclaimed code is reused, so a refusal (another orchestrator's, a retry) never kills a code
# already shown. Only an expired or claimed code is replaced: it is renamed aside first and a
# new one created exclusively, so two refusals racing converge on one code.
_osrc_disk_override_offer() {
  local code exp d t cur
  [ "${_OSRC_DISK_KIND:-}" = probe ] && return 0
  d="$(_osrc_disk_dir)"; _mkdir_private "$d" >/dev/null 2>&1 || return 0
  if ! cur="$(_osrc_disk_code_live "$d/override.code")"; then
    t="$d/override.code.old.$$"
    if mv "$d/override.code" "$t" 2>/dev/null && cur="$(_osrc_disk_code_live "$t")"; then mv -f "$t" "$d/override.code" 2>/dev/null
    else
      rm -f "$t" "$d"/override.taken.* 2>/dev/null; cur=""
      code="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
      [ "${#code}" = 8 ] && ( set -C; printf '%s %s\n' "$code" "$(( $(date +%s) + 900 ))" > "$d/override.code" ) 2>/dev/null
      cur="$(_osrc_disk_code_live "$d/override.code")" || return 0
    fi
  fi
  read -r code exp <<<"$cur"
  printf ' To launch this one command anyway: OSRC_DISK_OK=%s <same command> (one command, expires in %s min, logged to %s/override.log; never below the critical floor).' \
    "$code" "$(( (exp - $(date +%s) + 59) / 60 ))" "$d"
}

# _osrc_disk_override_take <free_kb> <launch_kb> -> 0 when this command holds valid consent.
# Always scrubs OSRC_DISK_OK and _OSRC_DISK_ADMIT so no delegate inherits them. The code binds
# to the first process ($$ + start identity) that claims it, by exclusive create of
# override.taken.<code>; subshells of that command share $$. A job launch (_OSRC_DISK_KIND=job)
# it admits exports a one-use admit token for the detached job's own gate.
_osrc_disk_override_take() {
  local v="${OSRC_DISK_OK:-}" a="${_OSRC_DISK_ADMIT:-}" d code exp me now how=code
  unset OSRC_DISK_OK _OSRC_DISK_ADMIT
  me="$$|$(_pid_start_identity "$$" 2>/dev/null)"
  d="$(_osrc_disk_dir)"; now="$(date +%s)"
  if [ "${_OSRC_DISK_OVERRIDE_OK:-}" = "$me" ]; then how=same-command
  elif case "$a" in ''|*[!0-9a-f]*) false ;; esac && read -r exp 2>/dev/null < "$d/admit.$a" \
       && rm "$d/admit.$a" 2>/dev/null && [ "$now" -le "${exp:-0}" ] 2>/dev/null; then how=job-admit  # rm: one taker
  else
    [ -n "$v" ] || return 1
    read -r code exp 2>/dev/null < "$d/override.code" || return 1
    case "$code:$exp" in *[!0-9a-f:]*|:*|*:) return 1 ;; esac
    [ "$v" = "$code" ] && [ "$now" -le "$exp" ] || return 1
    ( set -C; printf '%s\n' "$me" > "$d/override.taken.$code" ) 2>/dev/null \
      || [ "$(cat "$d/override.taken.$code" 2>/dev/null)" = "$me" ] || return 1
  fi
  printf '%s\tfree_kb=%s\tlaunch_kb=%s\tpid=%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$$" "$how" \
    >> "$d/override.log" 2>/dev/null || return 1
  _OSRC_DISK_OVERRIDE_OK="$me"
  if [ "${_OSRC_DISK_KIND:-}" = job ]; then
    a="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    printf '%s\n' "$(( now + 900 ))" > "$d/admit.$a" 2>/dev/null && export _OSRC_DISK_ADMIT="$a"
  fi
  return 0
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
_osrc_disk_any_paused() { [ -n "$(_osrc_disk_records)" ]; }
_osrc_disk_recorded_pids() { _osrc_disk_records | while IFS= read -r f; do awk -F'|' '$1=="proc"{print $3}' "$f" 2>/dev/null; done; }

# _osrc_disk_rec_write <file> <content> -> 0 only when the record reads back intact; 2 when a
# record already exists (another sweep paused it first). The record is created exclusively (a hard
# link of the complete temp file; noclobber + rename where links are unsupported), so two overlapping
# sweeps never overwrite each other's record: the loser's mv -f used to replace the winner's list
# with only the pids the winner had not listed, leaving those SIGSTOPped with no record naming them.
_osrc_disk_rec_write() {
  local t="$1.${_OSRC_DISK_ME:-$$}"
  printf '%s' "$2" > "$t" 2>/dev/null || { rm -f "$t" 2>/dev/null; return 1; }
  if ! ln "$t" "$1" 2>/dev/null; then
    [ -e "$1" ] && { rm -f "$t" 2>/dev/null; return 2; }
    { ( set -C; : > "$1" ) 2>/dev/null || { rm -f "$t" 2>/dev/null; [ -e "$1" ] && return 2; return 1; }; } && mv -f "$t" "$1" 2>/dev/null
  fi
  rm -f "$t" 2>/dev/null
  [ "$(cat "$1" 2>/dev/null)" = "$(printf '%s' "$2")" ] && return 0
  rm -f "$1" 2>/dev/null; return 1
}

_osrc_disk_log() { printf '%s disk-policy: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$(_osrc_disk_dir)/monitor.log" 2>/dev/null || true; }

_osrc_disk_keepalive() { # <jd> <paused|resumed>
  printf '>>> [outsourcerer] disk-policy: job %s (free %s)\n' "$2" "$(_osrc_disk_fmt_kb "$(_osrc_free_kb 2>/dev/null)")" \
    >> "$1/out.log" 2>/dev/null || true
}

_osrc_disk_terminal_status() { case "${1:-}" in done|'done?'|failed|blocked|timeout|wedged|canceled|permission-blocked|interrupted) return 0 ;; esac; return 1; }

# _osrc_disk_busy_pids -> " pid pid " of processes a SIGSTOP must not freeze: owners of an
# Outsourcerer mkdir lock (*.lock/owner under OSRC_HOME, leading pid) and git commands under two
# minutes old (they may hold index/ref/config locks other orchestrators need). A longer git run
# (a big clone or fetch) is paused like anything else. One ps and one find per sweep.
_osrc_disk_busy_pids() {
  printf ' %s ' "$( { find "$OSRC_HOME" -maxdepth 4 -path '*.lock/owner' -type f -exec awk 'FNR==1 && match($0, /^[0-9]+/) { print substr($0, 1, RLENGTH) }' {} + 2>/dev/null
    ps -axo pid=,etime=,comm= 2>/dev/null | awk '$3 ~ /(^|\/)git(-[a-z-]+)?$/ { n = split($2, t, /[-:]/); s = t[n] + 60 * t[n-1]; if (n > 2) s += 3600 * t[n-2]; if (n > 3) s += 86400 * t[1]; if (s < 120) print $1 }'
  } | tr '\n' ' ')"
}

# _osrc_disk_rec_busy <content> -> 0 when a process the record would stop is in _OSRC_DISK_BUSY.
_osrc_disk_rec_busy() {
  local tag role pid rest
  while IFS='|' read -r tag role pid rest; do
    [ "$tag" = proc ] && case "${_OSRC_DISK_BUSY:- }" in *" $pid "*) return 0 ;; esac
  done <<<"$1"
  return 1
}

# _osrc_disk_held -> 0 when the owner's `disk resume` hold applies to this sweep (the tick sets
# _OSRC_DISK_HONOR_HOLD=1 while free space is above the critical floor). Checked again after each
# SIGSTOP: a resume that wrote its hold meanwhile may have listed the records before this one.
_osrc_disk_held() { [ "${_OSRC_DISK_HONOR_HOLD:-0}" = 1 ] && [ -f "$(_osrc_disk_dir)/hold" ]; }

# _osrc_disk_stop_rec <record> — SIGSTOP every process the (already persisted) record names.
_osrc_disk_stop_rec() {
  local tag role pid grp id
  while IFS='|' read -r tag role pid grp id; do
    [ "$tag" = proc ] && _osrc_disk_same "$pid" "$id" || continue
    if [ "$grp" = 1 ]; then kill -STOP -- "-$pid" 2>/dev/null; else kill -STOP "$pid" 2>/dev/null; fi
  done < "$1"
}

# _osrc_disk_pause_job <jd> -> 0 paused, 1 nothing to pause, 2 unverifiable, 3 record failed,
# 4 deferred to the next tick (a process holds a lock or runs git).
_osrc_disk_pause_job() {
  local jd="$1" pid="" spid did sid grp=0 own c q st=""
  read -r st 2>/dev/null < "$jd/status"; _osrc_disk_terminal_status "$st" && return 1
  [ -f "$jd/disk-paused" ] && return 1
  read -r pid 2>/dev/null < "$jd/pid"; case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  [ "$pid" != "$$" ] && [ "$pid" != "${_OSRC_DISK_ME:-$$}" ] || return 1
  _pid_start_file_match "$pid" "$jd/pid_start" >/dev/null 2>&1 || return 2
  did="$(_pid_start_identity "$pid" 2>/dev/null)" || return 2
  # Group-signal only a delegate-led group: recorded pgid == pid == live pgid, and not ours.
  own="$(ps -o pgid= -p "${_OSRC_DISK_ME:-$$}" 2>/dev/null | tr -d ' ')"
  [ "$(cat "$jd/pgid" 2>/dev/null)" = "$pid" ] && [ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$pid" ] \
    && [ "$own" != "$pid" ] && grp=1
  c="since|$(date +%s)"$'\n'"proc|d|$pid|$grp|$did"$'\n'
  # Descendants always: a build the agent put in its own process group is not in the delegate's.
  for q in $(_osrc_disk_tree "$pid"); do c="${c}proc|d|$q|0|$(_pid_start_identity "$q" 2>/dev/null)"$'\n'; done
  spid="$(cat "$jd/supervisor_pid" 2>/dev/null)"
  if _pid_start_file_match "$spid" "$jd/supervisor_pid_start" >/dev/null 2>&1 && sid="$(_pid_start_identity "$spid" 2>/dev/null)"; then
    c="${c}proc|s|$spid|0|$sid"$'\n'
  fi
  _osrc_disk_rec_busy "$c" && { _osrc_disk_log "deferred pause of $jd: it holds a lock or runs git"; return 4; }
  _osrc_disk_rec_write "$jd/disk-paused" "$c"; q=$?; [ "$q" = 2 ] && return 1
  [ "$q" = 0 ] || { _osrc_disk_log "cannot record pause of $jd; left running"; return 3; }
  _osrc_disk_stop_rec "$jd/disk-paused"
  _osrc_disk_held && { _osrc_disk_resume_rec "$jd/disk-paused"; return 1; }
  _osrc_disk_keepalive "$jd" "paused under the disk pause floor; resumes automatically when space returns, or now: $0 disk resume"
}

# ---- foreground and tmux lanes ----------------------------------------------------------
# The launch gate registers what it cannot see in $OSRC_JOBS: a foreground launcher process
# (fg|pid|identity) or a tmux session about to start (tmux|name|registered-at|pane_pid|identity|
# launcher pid[|previous pane pid|its identity]). A tmux registration stays pending, with no tmux
# call, while its launcher lives. A respawn (relaunch, effort) re-registers the session pending,
# remembering the current pane, so the new pane binds and a failed respawn keeps the old one.

_osrc_disk_register_caller() { # <fg|job|tmux|tmux-respawn|probe> (the launch kind)
  local d; d="$(_osrc_disk_dir)/procs"
  [ "$(_osrc_disk_conf OSRC_DISK_POLICY_OFF)" = 1 ] && return 0
  case "${1:-}" in
    fg)
      [ -z "${OSRC_RUN_ID:-}" ] || return 0          # inside a bg job: the job record covers it
      local id; id="$(_pid_start_identity "$$" 2>/dev/null)" || return 0
      _mkdir_private "$d" >/dev/null 2>&1 && printf 'fg|%s|%s\n' "$$" "$id" > "$d/fg-$$" 2>/dev/null ;;
    tmux|tmux-respawn)
      [ "${OSRC_PLATFORM:-}" != windows ] && have tmux || return 0
      case "${SESSION_NAME:-}" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
      local k="" n="" t="" c="" i="" e="" pp="" pi=""   # keep a record bound to a live pane, or pending from an earlier (finished) start
      if IFS='|' read -r k n t c i e 2>/dev/null < "$d/tmux-$SESSION_NAME" && _osrc_disk_same "$c" "$i"; then
        [ "$1" = tmux ] && return 0
        pp="$c"; pi="$i"
      elif [ "$1" = tmux ] && [ -n "$k" ] && [ -z "$c" ] && ! kill -0 "${e:-0}" 2>/dev/null; then return 0
      fi
      _mkdir_private "$d" >/dev/null 2>&1 && printf 'tmux|%s|%s|||%s|%s|%s\n' "$SESSION_NAME" "$(date +%s)" "$$" "$pp" "$pi" > "$d/tmux-$SESSION_NAME" 2>/dev/null ;;
  esac
  return 0
}

# _osrc_disk_reg_root <reg> -> the verified root pid whose descendants are the lane's work.
# Drops a registration that no longer names the process/session it was made for. A tmux
# pane binds on first sight, and only when its shell started after the registration.
_osrc_disk_reg_root() {
  local r="$1" kind a b c d e f g cur et
  IFS='|' read -r kind a b c d e f g 2>/dev/null < "$r" || return 1
  [ "$kind" = tmux ] && [ -z "$c" ] && [ -n "$e" ] && kill -0 "$e" 2>/dev/null && return 1
  case "$kind" in
    fg) _osrc_disk_same "$a" "$b" && { printf '%s' "$a"; return 0; } ;;
    tmux)
      if have tmux && tmux has-session -t "=$a" 2>/dev/null; then
        cur="$(tmux display-message -p -t "=$a:" '#{pane_pid}' 2>/dev/null)"
        if [ -z "$c" ]; then
          { { [ -n "$f" ] && [ "$cur" = "$f" ] && _osrc_disk_same "$f" "$g"; } \
            || { et="$(_osrc_disk_etime "$cur")" && [ $(( $(date +%s) - et + 5 )) -ge "${b:-0}" ]; }; } \
            && d="$(_pid_start_identity "$cur" 2>/dev/null)" \
            && printf 'tmux|%s|%s|%s|%s\n' "$a" "$b" "$cur" "$d" > "$r" 2>/dev/null && { printf '%s' "$cur"; return 0; }
        elif [ "$cur" = "$c" ] && _osrc_disk_same "$c" "$d"; then printf '%s' "$c"; return 0
        fi
      fi ;;
  esac
  rm -f "$r" 2>/dev/null; return 1
}

# _osrc_disk_pause_reg <reg> -> 0 paused, 1 nothing to pause, 3 record failed, 4 deferred.
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
  _osrc_disk_rec_busy "$c" && { _osrc_disk_log "deferred pause of $key: it holds a lock or runs git"; return 4; }
  _mkdir_private "$(_osrc_disk_dir)/paused" >/dev/null 2>&1
  _osrc_disk_rec_write "$(_osrc_disk_dir)/paused/$key" "$c"; q=$?; [ "$q" = 2 ] && return 1
  [ "$q" = 0 ] || { _osrc_disk_log "cannot record pause of $key; left running"; return 3; }
  _osrc_disk_stop_rec "$(_osrc_disk_dir)/paused/$key"
  _osrc_disk_held && { _osrc_disk_resume_rec "$(_osrc_disk_dir)/paused/$key"; return 1; }
  return 0
}

# _osrc_disk_pane_restore <session> <tty> <stty> <pids> — after SIGCONT. `fg` is typed only
# when the pane shell owns the terminal and shares no group with the paused lane: a job-control
# prompt holding the parked TUI. A lane already in the foreground gets its terminal mode back
# and a redraw. Anything else is never typed into; it stays parked and the owner gets one event.
_osrc_disk_pane_restore() {
  local name="$1" tty="$2" st="$3" pids="$4" sh sg tp p g ours=0 shared=0 i=0
  have tmux && tmux has-session -t "=$name" 2>/dev/null || return 0
  sh="$(tmux display-message -p -t "=$name:" '#{pane_pid}' 2>/dev/null)"
  sg="$(ps -o pgid= -p "$sh" 2>/dev/null | tr -d ' ')"; tp="$(ps -o tpgid= -p "$sh" 2>/dev/null | tr -d ' ')"
  for p in $pids; do
    g="$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')"
    [ "$g" = "$sg" ] && shared=1; [ -n "$g" ] && [ "$g" = "$tp" ] && ours=1
  done
  if [ -n "$sg" ] && [ "$tp" = "$sg" ] && [ "$shared" = 0 ]; then
    tmux send-keys -t "=$name:" fg Enter 2>/dev/null
    while [ "$i" -lt 30 ] && [ "$(ps -o tpgid= -p "$sh" 2>/dev/null | tr -d ' ')" = "$sg" ]; do sleep 0.1; i=$((i+1)); done
  elif [ "$ours" = 0 ]; then
    _osrc_disk_wake "parked-$name" "tmux session $name: its resumed lane is not in the foreground and the pane is not at a shell prompt, so nothing was typed. Attach and bring it back yourself (usually: fg)."
    return 0
  fi
  [ -n "$st" ] && [ -c "$tty" ] && stty "$st" < "$tty" 2>/dev/null
  for p in $pids; do kill -WINCH "$p" 2>/dev/null; done
  return 0
}

# ---- resume -----------------------------------------------------------------------------

# _osrc_disk_resume_rec <record> -> 0 when retired. SIGCONTs every recorded process that is
# still the same process (and the group of a dead group leader); keeps the record if any
# required SIGCONT fails. A job's pause time is banked BEFORE any SIGCONT, so the watchdog
# reading _osrc_disk_paused_secs never counts it twice or misses it.
_osrc_disk_resume_rec() {
  local rec="$1" tag a b c d keep=0 banked=1 live="" panes="" jd="" t
  [ -f "$rec" ] || return 0
  case "$rec" in */disk-paused)
    jd="${rec%/disk-paused}"; t="$rec.${_OSRC_DISK_ME:-$$}"   # a failed rewrite keeps the old record
    printf '%s\n' "$(_osrc_disk_paused_secs "$jd")" > "$jd/disk-paused-secs" 2>/dev/null || banked=0
    [ "$banked" = 1 ] \
      && grep -v '^since|' "$rec" > "$t" 2>/dev/null && mv -f "$t" "$rec" 2>/dev/null || rm -f "$t" 2>/dev/null ;;
  esac
  while IFS='|' read -r tag a b c d; do
    case "$tag" in
      proc)
        if ! _osrc_disk_same "$b" "$d"; then [ "$c" = 1 ] && kill -CONT -- "-$b" 2>/dev/null; continue; fi
        [ "$c" = 1 ] && [ "$(ps -o pgid= -p "$b" 2>/dev/null | tr -d ' ')" = "$b" ] && { kill -CONT -- "-$b" 2>/dev/null || keep=1; }
        kill -CONT "$b" 2>/dev/null || keep=1
        live="$live $b" ;;
      pane) panes="$panes$a|$b|$c"$'\n' ;;
    esac
  done < "$rec"
  if [ "$keep" = 1 ]; then
    [ -n "$jd" ] && printf 'since|%s\n' "$(date +%s)" >> "$rec" 2>/dev/null
    _osrc_disk_log "SIGCONT failed for $rec; record kept"; return 1
  fi
  while IFS='|' read -r a b c; do [ -n "$a" ] && _osrc_disk_pane_restore "$a" "$b" "$c" "$live"; done <<<"$panes"
  [ -n "$jd" ] && _osrc_disk_keepalive "$jd" resumed
  # Bank lost (full disk): keep the record so its since line still shifts the job's clocks.
  [ "$banked" = 1 ] && rm -f "$rec" 2>/dev/null
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
  local jd r n=0 u=0 rc _OSRC_DISK_BUSY
  _OSRC_DISK_BUSY="$(_osrc_disk_busy_pids)"
  for jd in "$OSRC_JOBS"/*/; do
    [ -d "$jd" ] || continue
    _osrc_disk_held && break
    _osrc_disk_pause_job "${jd%/}"; rc=$?
    case "$rc" in 0) n=$((n+1)) ;; 2|3) u=$((u+1)) ;; esac
  done
  for r in "$(_osrc_disk_dir)"/procs/*; do
    [ -f "$r" ] || continue
    _osrc_disk_held && break
    _osrc_disk_pause_reg "$r"; rc=$?
    case "$rc" in 0) n=$((n+1)) ;; 3) u=$((u+1)) ;; esac
  done
  printf '%s %s' "$n" "$u"
}

# ---- wakes (one per transition per pressure episode) -----------------------------------

_osrc_disk_episode() { # -> current episode id, creating one when asked (arg "new")
  local f e; f="$(_osrc_disk_dir)/.episode"; e="$(cat "$f" 2>/dev/null)"
  [ -z "$e" ] && [ "${1:-}" = new ] && { e="$(date +%s).$$.$RANDOM"; printf '%s\n' "$e" > "$f" 2>/dev/null; }
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
# must match the receipt and HEAD must be the proven commit; no untracked or ignored file, so
# every visible file is tracked at a preserved commit), then the recorded branch (conditional
# on the proven commit and not checked out anywhere).
_osrc_disk_reclaim_lane() {
  local s="$1" items="$2" wj br base repo wt sha pp n=0 k
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
    _osrc_wt_remove "$repo" "$pp" disk-policy; k=$?
    [ "$k" = 2 ] && _osrc_disk_log "kept $pp: untracked or ignored content (review: $0 cleanup)"
    [ "$k" = 0 ] || { printf 0; return 0; }
    n=$((n+1))
  fi
  if [ -n "$(printf '%s\n' "$items" | jq -r --arg s "$s" --arg b "$br" 'select(.session==$s and .kind=="branch" and .path==$b) | .path' 2>/dev/null)" ] \
     && ! _osrc_branch_checked_out "$repo" "$br" \
     && git -C "$repo" update-ref -d "refs/heads/$br" "$sha" >/dev/null 2>&1; then
    _osrc_disk_cl_log removed-branch "$br@$sha ($repo)"; n=$((n+1))
  fi
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

# _osrc_disk_readings -> "<free_kb> <launch> <pause> <crit>", rc1 when any is not a number.
_osrc_disk_readings() {
  local f l p c
  f="$(_osrc_free_kb 2>/dev/null)"; read -r l p c <<<"$(_osrc_disk_floors_kb 2>/dev/null)"
  case "$f:$l:$p:$c" in *[!0-9:]*|:*|*::*|*:) return 1 ;; esac
  printf '%s %s %s %s' "$f" "$l" "$p" "$c"
}

# _osrc_disk_monitor_tick — one pass; never fails. Order under pressure: pause and wake
# first, then the (slow) report scan and bounded reclaim. A reading that cannot be read with
# pauses on record fails toward resume (pausing is the risky action), with one wake.
_osrc_disk_monitor_tick() {
  local d free_kb launch pause crit resume counts n u items k _OSRC_DISK_HONOR_HOLD=0
  d="$(_osrc_disk_dir)"; _mkdir_private "$d" >/dev/null 2>&1
  if ! k="$(_osrc_disk_readings)"; then
    _osrc_disk_any_paused || return 0
    k="$(_osrc_disk_resume_all)"; _osrc_disk_episode new >/dev/null
    _osrc_disk_wake unreadable "disk policy cannot read free space for $OSRC_HOME (df -kP failed or printed no number); $k paused lane(s) resumed so nothing stays frozen, and launches are refused until it reads. Check: df -kP $OSRC_HOME"
    return 0
  fi
  read -r free_kb launch pause crit <<<"$k"
  resume="$(_osrc_disk_resume_kb "$launch" "$pause")"; [ "$pause" -gt 0 ] || resume=0   # pausing off: resume all
  for k in "$d"/admit.*; do read -r n 2>/dev/null < "$k"; [ "${n:-0}" -lt "$(date +%s)" ] 2>/dev/null && rm -f "$k"; done
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
  [ "$free_kb" -ge "$crit" ] && _OSRC_DISK_HONOR_HOLD=1   # owner ran `disk resume`: hold above critical
  if _osrc_disk_held; then counts="0 0"; else counts="$(_osrc_disk_pause_sweep)"; fi
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
  k="$(_osrc_disk_reclaim "${items:-}")"   # the next tick resumes once reclaim freed enough
  [ "${k:-0}" = 0 ] || _osrc_disk_log "reclaimed $k merged-lane item(s); free now $(_osrc_disk_fmt_kb "$(_osrc_free_kb 2>/dev/null)")"
  return 0
}

# ---- monitor ------------------------------------------------------------------------------
# Ownership is a lock dir (monitor.lock/owner = "pid|start identity") held for the monitor's
# whole life and re-verified every tick. A launch writes a fresh demand token BEFORE checking
# the owner; the monitor releases the lock BEFORE its last demand check, so a launch racing an
# idle exit either keeps the old monitor running or spawns a new one.

_osrc_disk_lock_alive() { # [owner file]
  local lk c pid id m; lk="$(_osrc_disk_dir)/monitor.lock"
  [ -d "$lk" ] || return 1
  c="$(cat "${1:-$lk/owner}" 2>/dev/null)"
  if [ -z "$c" ]; then   # being created: alive for a few seconds
    m="$(stat -c %Y "$lk" 2>/dev/null || stat -f %m "$lk" 2>/dev/null || echo 0)"
    [ $(( $(date +%s) - m )) -lt 10 ]; return
  fi
  pid="${c%%|*}"; id="${c#*|}"
  if [ -n "$id" ]; then _osrc_disk_same "$pid" "$id"; else kill -0 "$pid" 2>/dev/null; fi
}

# The only claim is an exclusive create of owner, so exactly one claimant wins. A stale owner is
# first renamed aside (a rename that grabbed a live owner puts it back). The dir is never removed.
_osrc_disk_lock_take() {
  local lk t; lk="$(_osrc_disk_dir)/monitor.lock"; t="$lk/owner.$_OSRC_DISK_ME"
  if ! mkdir "$lk" 2>/dev/null; then
    _osrc_disk_lock_alive && return 1
    mv "$lk/owner" "$t" 2>/dev/null && [ -s "$t" ] && _osrc_disk_lock_alive "$t" && { mv "$t" "$lk/owner"; return 1; }   # empty = a claim whose write failed: dead
    rm -f "$t"
  fi
  ( set -C; printf '%s|%s\n' "$_OSRC_DISK_ME" "$_OSRC_DISK_ME_ID" > "$lk/owner" ) 2>/dev/null
}
_osrc_disk_lock_mine() { [ "$(cat "$(_osrc_disk_dir)/monitor.lock/owner" 2>/dev/null)" = "$_OSRC_DISK_ME|$_OSRC_DISK_ME_ID" ]; }
_osrc_disk_lock_release() { _osrc_disk_lock_mine && rm -rf "$(_osrc_disk_dir)/monitor.lock"; _OSRC_DISK_OWNER=0; }

# _osrc_disk_exit_may_resume -> 0 when a dying monitor should resume every pause: free space at or
# above the pause floor, pausing off, the owner's `disk resume` hold, or a reading that cannot be
# read (fail toward resume). Otherwise the records stay and the next monitor (heartbeat, launch,
# `disk status`) carries them; resuming here would let the builds drain a disk under the floor.
_osrc_disk_exit_may_resume() {
  local f l p c r
  r="$(_osrc_disk_readings)" || return 0
  read -r f l p c <<<"$r"
  [ "$p" = 0 ] || [ "$f" -ge "$p" ] || [ -f "$(_osrc_disk_dir)/hold" ]
}

# Every orderly exit and TERM goes through here, then the lock is let go.
_osrc_disk_monitor_exit() {
  [ "${_OSRC_DISK_OWNER:-0}" = 1 ] || return 0
  [ -n "${_OSRC_DISK_SLEEP:-}" ] && kill "$_OSRC_DISK_SLEEP" 2>/dev/null
  if _osrc_disk_exit_may_resume; then
    _osrc_disk_resume_all >/dev/null; _osrc_disk_lock_release
    _osrc_disk_log "monitor $_OSRC_DISK_ME exited; recorded pauses resumed"
  else
    _osrc_disk_lock_release
    _osrc_disk_log "monitor $_OSRC_DISK_ME exited under the pause floor; pause records kept for the next monitor"
  fi
}

# _osrc_disk_fleet_live -> 0 while any job, registered lane or pause record is live.
_osrc_disk_fleet_live() {
  local jd pid r st
  _osrc_disk_any_paused && return 0
  for jd in "$OSRC_JOBS"/*/; do
    st=""; pid=""; read -r st 2>/dev/null < "$jd/status"; _osrc_disk_terminal_status "$st" && continue
    read -r pid 2>/dev/null < "$jd/pid"
    case "$pid" in ''|*[!0-9]*) [ "$st" = launching ] && return 0; continue ;; esac
    kill -0 "$pid" 2>/dev/null && return 0
  done
  for r in "$(_osrc_disk_dir)"/procs/*; do [ -f "$r" ] && _osrc_disk_reg_root "$r" >/dev/null && return 0; done
  return 1
}

_osrc_disk_monitor_loop() {
  trap '' HUP; set +m
  local d poll maxidle idle=0 dem last sz
  d="$(_osrc_disk_dir)"
  unset OSRC_DISK_OK _OSRC_DISK_ADMIT
  exec >>"$d/monitor.log" 2>&1 || exec >/dev/null 2>&1
  _OSRC_DISK_ME="${BASHPID:-}"
  if [ -z "$_OSRC_DISK_ME" ]; then   # bash 3.2: a direct child's PPID is this subshell
    sz="$(mktemp "$d/.me.XXXXXX" 2>/dev/null)" && sh -c 'echo "$PPID"' > "$sz" 2>/dev/null
    _OSRC_DISK_ME="$(cat "$sz" 2>/dev/null)"; rm -f "$sz" 2>/dev/null
  fi
  case "$_OSRC_DISK_ME" in ''|*[!0-9]*) exit 0 ;; esac
  # Detached start: let the forking subshell exit first, so no lane's process tree (a foreground
  # launcher is a registered lane) still holds it when the first tick pauses that tree.
  sz=0; while [ -n "${_OSRC_DISK_FORKER:-}" ] && kill -0 "$_OSRC_DISK_FORKER" 2>/dev/null && [ "$sz" -lt 50 ]; do sleep 0.1; sz=$((sz+1)); done
  _OSRC_DISK_ME_ID="$(_pid_start_identity "$_OSRC_DISK_ME" 2>/dev/null)"
  _osrc_disk_lock_take || exit 0
  _OSRC_DISK_OWNER=1
  trap '_osrc_disk_monitor_exit' EXIT
  trap 'exit 0' TERM
  poll="${OSRC_DISK_POLICY_POLL:-30}"; case "$poll" in ''|*[!0-9]*|0) poll=30 ;; esac; [ "$poll" -le 30 ] || poll=30   # env may only poll faster
  maxidle="${OSRC_DISK_MONITOR_IDLE_TICKS:-2}"; case "$maxidle" in ''|*[!0-9]*|0) maxidle=2 ;; esac   # no job or lane left: gone within ~2 polls
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
    # A backgrounded sleep plus `wait`: a TERM runs the trap at once, not after the sleep.
    sleep "$poll" & _OSRC_DISK_SLEEP=$!; wait "$_OSRC_DISK_SLEEP" 2>/dev/null; _OSRC_DISK_SLEEP=""
  done
}

# _osrc_disk_monitor_exec — become the monitor as its own process named osrc-disk-monitor (what
# `ps` shows), started from a snapshot of this shell: every function (wrapper and test overrides
# included) and the non-exported OSRC_/SCRIPT_ settings (exported ones, secrets among them, travel
# in the environment, never in the file). The private snapshot is deleted once read. Falls back
# to running the loop in place when the exec cannot happen.
_osrc_disk_monitor_exec() {
  local snap v line fl
  if [ -n "${BASH:-}" ] && snap="$(mktemp "$(_osrc_disk_dir)/.monitor.XXXXXX" 2>/dev/null)"; then
    { declare -f
      for v in $(compgen -v); do
        case "$v" in OSRC_*|_OSRC_*|SCRIPT_*|SESSION_NAME) ;; *) continue ;; esac
        case "$v" in *KEY*|*TOKEN*|*SECRET*|*PASS*) continue ;; esac
        line="$(declare -p "$v" 2>/dev/null)" || continue
        fl="${line#declare -}"; case "${fl%% *}" in *x*) continue ;; esac   # exported: already in the env
        printf '%s\n' "$line"
      done; } > "$snap" 2>/dev/null
    shopt -s execfail
    exec -a osrc-disk-monitor "$BASH" -c '. "$1" 2>/dev/null; rm -f "$1"; _osrc_disk_monitor_loop' osrc-disk-monitor "$snap"
    rm -f "$snap"
  fi
  _osrc_disk_monitor_loop
}

# _osrc_disk_monitor_ensure — called on every launch: post demand, spawn a monitor unless a
# verified owner is alive. The child closes every inherited descriptor 3-31 (a caller's fd 5, or
# bash's saved copies of a capture pipe at 10+) so it never holds a caller's pipe open. It is
# detached from its launcher: a double fork (re-parented to init, out of the launcher's tree) with
# job control on, so it leads its own process group and a cancel/timeout of the launcher's group
# or tree never reaches it. Bash 3.2 and Linux alike; Git Bash keeps the plain background child.
_osrc_disk_monitor_ensure() {
  [ "$(_osrc_disk_conf OSRC_DISK_POLICY_OFF)" = "1" ] && return 0
  [ -n "${OSRC_HOME:-}" ] && [ -d "$OSRC_HOME" ] || return 0
  local d; d="$(_osrc_disk_dir)"
  _mkdir_private "$d" >/dev/null 2>&1 || return 0
  printf '%s.%s.%s\n' "$(date +%s)" "$$" "$RANDOM" > "$d/demand" 2>/dev/null
  _osrc_disk_lock_alive && return 0
  if [ "${OSRC_PLATFORM:-}" = windows ]; then
    ( i=3; while [ "$i" -lt 32 ]; do eval "exec $i>&-"; i=$((i+1)); done; _osrc_disk_monitor_exec ) </dev/null >/dev/null 2>&1 &
  else
    ( set -m; _OSRC_DISK_FORKER="${BASHPID:-$(sh -c 'echo "$PPID"')}"; ( i=3; while [ "$i" -lt 32 ]; do eval "exec $i>&-"; i=$((i+1)); done; _osrc_disk_monitor_exec ) </dev/null >/dev/null 2>&1 & ) </dev/null >/dev/null 2>&1
  fi
  return 0
}

# _osrc_disk_heartbeat — no live monitor while pause records exist (it died abruptly, or left them
# under the floor) or while free space is under the pause floor: start one.
_osrc_disk_heartbeat() {
  local f l p c r
  _osrc_disk_lock_alive && return 0
  if _osrc_disk_any_paused || { r="$(_osrc_disk_readings)" && read -r f l p c <<<"$r" && [ "$f" -lt "$p" ]; }; then _osrc_disk_monitor_ensure; fi
  return 0
}

# _osrc_disk_target_paused <id> -> 0 when the job or tmux lane <id> is disk-paused right now
# (supervise and the watcher report it as paused, never stalled).
_osrc_disk_target_paused() {
  case "${1:-}" in ''|*/*) return 1 ;; esac
  [ -f "$OSRC_JOBS/$1/disk-paused" ] && grep -q '^since|' "$OSRC_JOBS/$1/disk-paused" 2>/dev/null && return 0
  [ -f "$(_osrc_disk_dir)/paused/tmux-$1" ]
}

_osrc_disk_pause_since() { sed -n 's/^since|//p' "$OSRC_JOBS/$1/disk-paused" "$(_osrc_disk_dir)/paused/tmux-$1" 2>/dev/null | head -1; }

# _osrc_disk_paused_note <id> -> the one line status, the hub and supervise show for a disk-paused lane.
_osrc_disk_paused_note() {
  local l p c
  _osrc_disk_target_paused "${1:-}" || return 1
  read -r l p c <<<"$(_osrc_disk_floors_kb 2>/dev/null)"
  printf 'Paused: disk below %s (pause floor); SIGSTOPped, resumes when space returns, or now: %s disk resume' "$(_osrc_disk_fmt_kb "$p")" "$0"
}

# _osrc_disk_session_gate <session args...> — the disk gate for `session`: start and model switch
# gate as a tmux launch; control relaunch and effort start a new pane process, so they gate and
# re-register the pane (the new pid stays covered by pause-not-kill).
_osrc_disk_session_gate() {
  case "${1:-}:${2:-}" in
    start:*|model:*) _osrc_disk_gate tmux ;;
    control:relaunch|effort:?*) _osrc_disk_gate tmux-respawn ;;
  esac
}

# `outsourcerer disk [status|resume]` — resume is the one-command way back: it resumes every
# paused lane now (TUIs return to the foreground) and holds new pauses until the disk
# recovers or crosses the critical floor.
_osrc_disk_cmd() {
  local d; d="$(_osrc_disk_dir)"
  case "${1:-status}" in
    status)
      _osrc_disk_heartbeat
      _osrc_disk_report
      _osrc_disk_records | sed 's/^/paused: /' ;;
    resume)
      # The hold goes down BEFORE the resume, so a monitor tick in between pauses nothing new (it
      # re-checks the hold per lane and after each SIGSTOP). Only when something is paused, so no
      # stale hold outlives its episode.
      local n=0
      if _osrc_disk_any_paused; then _mkdir_private "$d" >/dev/null 2>&1; date +%s > "$d/hold" 2>/dev/null; n="$(_osrc_disk_resume_all)"; fi
      printf '[outsourcerer] disk: resumed %s paused lane(s); no new pauses until space recovers or falls under the critical floor.\n' "$n" ;;
    *) die "disk: status | resume" ;;
  esac
}
