#!/usr/bin/env bash
# lib/disk_policy.sh — disk pressure policy: launch floors, while-running pause/resume of
# supervised jobs, merged-lane auto-reclaim, and the detached monitor that enforces it.
# Sourced by the lib loader; defines functions only, runs nothing at load time. Bash 3.2 + Git Bash.
#
# Floors (all in KB, derived from the volume holding $OSRC_HOME):
#   launch   = max(OSRC_DISK_MIN_GB|unset->10GB, 5% of volume)  — no NEW lane launches under it
#   pause    = max(OSRC_DISK_PAUSE_GB|unset->4GB, 2% of volume) — live jobs get SIGSTOPped under it
#   critical = clamp(0.5% of volume or OSRC_DISK_CRITICAL_GB, 1GB..4GB)
#   resume   = pause + half the pause->launch gap (hysteresis: no pause/resume flapping)
#
# Rules this file keeps:
#   * An ack (--ack) or OSRC_DISK_OK=1 can NEVER launch below the critical floor.
#   * OSRC_DISK_OK=1 is the explicit per-command override: logged to
#     $OSRC_HOME/disk-policy/override.log, never persisted, never inherited as consent.
#   * The monitor only ever signals processes recorded in $OSRC_JOBS/*/{pid,pgid,
#     supervisor_pid} AFTER pid+start-time identity proof. It never kills, never touches
#     a process Outsourcerer did not launch, and resumes everything it paused before exit.
#   * Auto-reclaim deletes ONLY manifest items verdict-SAFE AND kind worktree|branch —
#     artifacts of a lane proven merged. Jobs, loops, autodetach logs, tmp dirs and every
#     ASK item stay manual (`cleanup --apply` / `--ack`).
#
# Escape hatches: OSRC_DISK_POLICY_OFF=1 disables pause/reclaim (floors fall back to the
# legacy flat 10GB launch gate); OSRC_DISK_RECLAIM_MAX=0 disables auto-reclaim;
# OSRC_DISK_POLICY_POLL (default 30s) and OSRC_DISK_MONITOR_IDLE_TICKS (default 40) tune
# the monitor; OSRC_DISK_WAKE_SECS (default 300) throttles repeat wakes.

# ---- floors ----------------------------------------------------------------------

# _osrc_disk_vol_kb -> total KB of the filesystem holding OSRC_HOME (df -kP field 2), or "".
_osrc_disk_vol_kb() {
  df -kP "$OSRC_HOME" 2>/dev/null | awk 'NR==2 {print $2}'
}

# _osrc_disk_gb_kb <n> -> KB for a non-negative integer GB, or "" when not a plain integer.
_osrc_disk_gb_kb() {
  case "${1:-}" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$(( $1 * 1048576 ))" ;; esac
}

# _osrc_disk_floors_kb -> "<launch_kb> <pause_kb> <crit_kb>". Defaults scale with volume so a
# big disk is not treated like a small one; explicit OSRC_DISK_*_GB env overrides win.
# Ordering is enforced: crit < launch whenever launch > 0 (a zero launch floor means the
# user disabled launch blocking, which also disables the critical line); pause is capped
# below launch so the resume band can never invert.
_osrc_disk_floors_kb() {
  local vol launch="" pause="" crit="" pmax
  if [ "${OSRC_DISK_POLICY_OFF:-0}" = "1" ]; then
    printf '10485760 0 0\n'; return 0
  fi
  vol="$(_osrc_disk_vol_kb)"; case "$vol" in ''|*[!0-9]*) vol=0 ;; esac
  # launch: explicit OSRC_DISK_MIN_GB (GB) wins outright; else max(10GB, 5% of volume).
  if [ -n "${OSRC_DISK_MIN_GB:-}" ]; then
    launch="$(_osrc_disk_gb_kb "$OSRC_DISK_MIN_GB")"
    case "$launch" in ''|*[!0-9]*) launch="" ;; esac
  fi
  [ -n "$launch" ] || { launch=$(( vol * 5 / 100 )); [ "$launch" -lt 10485760 ] && launch=10485760; }
  # pause: explicit OSRC_DISK_PAUSE_GB wins; else max(4GB, 2% of volume).
  if [ -n "${OSRC_DISK_PAUSE_GB:-}" ]; then
    pause="$(_osrc_disk_gb_kb "$OSRC_DISK_PAUSE_GB")"
    case "$pause" in ''|*[!0-9]*) pause="" ;; esac
  fi
  [ -n "$pause" ] || { pause=$(( vol * 2 / 100 )); [ "$pause" -lt 4194304 ] && pause=4194304; }
  # critical: explicit OSRC_DISK_CRITICAL_GB wins; else clamp(0.5% of volume, 1GB, 4GB).
  if [ -n "${OSRC_DISK_CRITICAL_GB:-}" ]; then
    crit="$(_osrc_disk_gb_kb "$OSRC_DISK_CRITICAL_GB")"
    case "$crit" in ''|*[!0-9]*) crit="" ;; esac
  fi
  if [ -z "$crit" ]; then
    crit=$(( vol / 200 ))
    [ "$crit" -lt 1048576 ] && crit=1048576
    [ "$crit" -gt 4194304 ] && crit=4194304
  fi
  # Ordering clamps (a broken ordering must never wedge the session).
  if [ "$launch" -le 0 ]; then
    crit=0                      # launch floor fully disabled -> no critical line either
  else
    [ "$crit" -ge "$launch" ] && crit=$(( launch / 2 ))
    pmax=$(( launch * 3 / 4 ))
    [ "$pause" -gt "$pmax" ] && pause="$pmax"
    [ "$pause" -lt 0 ] && pause=0
  fi
  printf '%s %s %s\n' "$launch" "$pause" "$crit"
}

# _osrc_disk_resume_kb <launch_kb> <pause_kb> -> resume threshold: pause floor plus half the
# gap to the launch floor (min 1GB headroom) so a hovering disk cannot flap jobs.
_osrc_disk_resume_kb() {
  local l="${1:-0}" p="${2:-0}"
  case "$l$p" in *[!0-9\ ]*) printf '0\n'; return 0 ;; esac
  if [ "$l" -gt "$p" ]; then printf '%s\n' "$(( p + (l - p) / 2 ))"; else printf '%s\n' "$(( p + 1048576 ))"; fi
}

# _osrc_disk_fmt_kb <kb> -> "6.2G" / "800M" style, one decimal under 10G.
_osrc_disk_fmt_kb() {
  local k="${1:-0}" g
  case "$k" in ''|*[!0-9]*) k=0 ;; esac
  if [ "$k" -ge 1048576 ]; then
    g=$(( k * 10 / 1048576 ))
    printf '%s.%sG' "$(( g / 10 ))" "$(( g % 10 ))"
  elif [ "$k" -ge 1024 ]; then printf '%sM' "$(( k / 1024 ))"; else printf '%sK' "$k"; fi
}

# ---- reporting --------------------------------------------------------------------

# _osrc_disk_swap -> "used/total" human swap reading, or "?" when unmeasurable.
# macOS: sysctl vm.swapusage (units M or G, kept verbatim). Linux/Git Bash: /proc/meminfo.
_osrc_disk_swap() {
  local line tot used
  line="$(sysctl -n vm.swapusage 2>/dev/null)"
  if [ -n "$line" ]; then
    tot="$(printf '%s' "$line" | sed -n 's/.*total = \([0-9.]*[MG]\).*/\1/p' | head -1)"
    used="$(printf '%s' "$line" | sed -n 's/.*used = \([0-9.]*[MG]\).*/\1/p' | head -1)"
    case "$tot$used" in *[!0-9.MG]*) : ;; *)
      [ -n "$tot" ] && [ -n "$used" ] && { printf '%s/%s' "$used" "$tot"; return 0; } ;;
    esac
  fi
  if [ -r /proc/meminfo ]; then
    tot="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
    local free_k; free_k="$(awk '/^SwapFree:/{print $2}' /proc/meminfo 2>/dev/null)"
    case "$tot" in ''|*[!0-9]*) tot=0 ;; esac
    case "$free_k" in ''|*[!0-9]*) free_k=0 ;; esac
    if [ "$tot" -gt 0 ]; then printf '%sM/%sM' "$(( (tot - free_k) / 1024 ))" "$(( tot / 1024 ))"; return 0; fi
  fi
  printf '?'
}

# _osrc_disk_report -> human report: volume, swap, biggest dirs under OSRC_HOME, and the
# count of Outsourcerer-created items still SAFE to reclaim. Best-effort; never fails.
_osrc_disk_report() {
  local free_kb vol_kb free_g launch pause crit floors top safe_n ask_n items
  free_kb="$(_osrc_free_kb 2>/dev/null)"; case "$free_kb" in ''|*[!0-9]*) free_kb=0 ;; esac
  vol_kb="$(_osrc_disk_vol_kb)"; case "$vol_kb" in ''|*[!0-9]*) vol_kb=0 ;; esac
  floors="$(_osrc_disk_floors_kb 2>/dev/null)"
  launch="${floors%% *}"; pause="$(printf '%s' "$floors" | awk '{print $2}')"; crit="${floors##* }"
  case "$launch" in ''|*[!0-9]*) launch=0 ;; esac
  case "$pause" in ''|*[!0-9]*) pause=0 ;; esac
  case "$crit" in ''|*[!0-9]*) crit=0 ;; esac
  printf 'free %s of %s; floors launch>=%s pause>=%s critical>=%s; swap %s\n' \
    "$(_osrc_disk_fmt_kb "$free_kb")" "$(_osrc_disk_fmt_kb "$vol_kb")" \
    "$(_osrc_disk_fmt_kb "$launch")" "$(_osrc_disk_fmt_kb "$pause")" "$(_osrc_disk_fmt_kb "$crit")" \
    "$(_osrc_disk_swap)"
  top="$(du -sk "$OSRC_HOME"/* 2>/dev/null | sort -rn | head -3 | awk '{n=$2; sub(/.*\//,"",n); printf "%s=%s ", n, $1}')"
  printf 'top under OSRC_HOME: %s\n' "${top:-none}"
  if have jq 2>/dev/null && [ -f "$OSRC_HOME/created.jsonl" ]; then
    items="$(_osrc_cleanup_items --no-size 2>/dev/null)"
    safe_n="$(printf '%s' "$items" | jq -s '[.[]|select(.verdict=="SAFE")]|length' 2>/dev/null)"; safe_n="${safe_n:-0}"
    ask_n="$(printf '%s' "$items" | jq -s '[.[]|select(.verdict=="ASK")]|length' 2>/dev/null)"; ask_n="${ask_n:-0}"
    printf 'outsourcerer-created reclaimable: %s SAFE item(s) (auto-eligible only when lane-merged: worktree/branch); %s ASK need review; dry run: %s cleanup\n' \
      "$safe_n" "$ask_n" "$0"
  fi
}

# _osrc_disk_report_oneline -> one-line variant for gate/wake messages. Cheap: no du, no scan.
_osrc_disk_report_oneline() {
  local free_kb vol_kb floors launch crit
  free_kb="$(_osrc_free_kb 2>/dev/null)"; case "$free_kb" in ''|*[!0-9]*) free_kb=0 ;; esac
  vol_kb="$(_osrc_disk_vol_kb)"; case "$vol_kb" in ''|*[!0-9]*) vol_kb=0 ;; esac
  floors="$(_osrc_disk_floors_kb 2>/dev/null)"
  launch="${floors%% *}"; case "$launch" in ''|*[!0-9]*) launch=0 ;; esac
  crit="${floors##* }"; case "$crit" in ''|*[!0-9]*) crit=0 ;; esac
  printf '(free %s/%s, launch floor %s, critical %s, swap %s)' \
    "$(_osrc_disk_fmt_kb "$free_kb")" "$(_osrc_disk_fmt_kb "$vol_kb")" \
    "$(_osrc_disk_fmt_kb "$launch")" "$(_osrc_disk_fmt_kb "$crit")" "$(_osrc_disk_swap)"
}

# ---- override logging ---------------------------------------------------------------

# _osrc_disk_override_log <free_kb> <launch_kb> — record one OSRC_DISK_OK use. Best-effort.
_osrc_disk_override_log() {
  local dir f
  dir="$OSRC_HOME/disk-policy"; _mkdir_private "$dir" >/dev/null 2>&1 || return 0
  f="$dir/override.log"
  printf '%s\tfree_kb=%s\tlaunch_kb=%s\tpid=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${BASHPID:-$$}" >> "$f" 2>/dev/null || true
  return 0
}

# ---- wakes ---------------------------------------------------------------------------

# _osrc_disk_wake <kind> <event_id> <summary> — throttled durable wake. kind file
# .wake-<kind> holds the last wake epoch; repeat wakes of the same kind wait
# OSRC_DISK_WAKE_SECS (default 300). _wake_append dedupes unacked ids itself.
_osrc_disk_wake() {
  local kind="$1" eid="$2" summary="$3" dir stamp now last
  [ -n "${OSRC_HOME:-}" ] || return 0
  type _wake_append >/dev/null 2>&1 || return 0
  have jq 2>/dev/null || return 0
  dir="$OSRC_HOME/disk-policy"; _mkdir_private "$dir" >/dev/null 2>&1 || return 0
  stamp="$dir/.wake-$kind"; now="$(date +%s)"
  last="$(cat "$stamp" 2>/dev/null)"; case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( now - last )) -ge "${OSRC_DISK_WAKE_SECS:-300}" ] || return 0
  _wake_append "$(jq -cn --arg eid "$eid" --arg k "disk-$kind" --arg s "$summary" \
    '{event_id:$eid,kind:$k,state:"disk",task_summary:$s}' 2>/dev/null)" >/dev/null 2>&1 || return 0
  printf '%s\n' "$now" > "$stamp" 2>/dev/null || true
  return 0
}

# ---- job pause/resume ---------------------------------------------------------------

# _osrc_disk_terminal_status <status> -> 0 when the job is finished (nothing to pause).
_osrc_disk_terminal_status() {
  case "${1:-}" in
    done|'done?'|failed|blocked|timeout|wedged|canceled|permission-blocked|interrupted) return 0 ;;
  esac
  return 1
}

# _osrc_disk_job_pids <jd> -> prints "<delegate_pid> <pgid> <supervisor_pid>" for a job whose
# delegate pid is PROVABLY the recorded process (pid + pid_start identity, rc 0 only; rc 2
# "cannot tell" is treated as NOT ours — never signal it). Prints nothing when the job is
# terminal, unverifiable, self-referential, or has no live delegate.
_osrc_disk_job_pids() {
  local jd="$1" st pid pgid spid
  st="$(cat "$jd/status" 2>/dev/null)"
  _osrc_disk_terminal_status "$st" && return 1
  pid="$(cat "$jd/pid" 2>/dev/null)"; case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" != "$$" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  _pid_start_file_match "$pid" "$jd/pid_start" >/dev/null 2>&1 || return 1
  pgid="$(cat "$jd/pgid" 2>/dev/null)"; case "$pgid" in ''|*[!0-9]*) pgid="" ;; esac
  # The recorded PGID is only safe when the live delegate still sits in it (same guard
  # _kill_job uses against PID/PGID recycling).
  if [ -n "$pgid" ]; then
    [ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$pgid" ] || pgid=""
  fi
  spid="$(cat "$jd/supervisor_pid" 2>/dev/null)"; case "$spid" in ''|*[!0-9]*) spid="" ;; esac
  printf '%s %s %s\n' "$pid" "$pgid" "$spid"
}

# _osrc_disk_stop_verified <pid> <start-file> -> rc 0 when pid is proven ours (liveness plus
# pid+start identity). Used for the supervisor, which is stopped by single pid only: its
# process group is the CALLER's group and must never be group-signalled.
_osrc_disk_stop_verified() {
  local pid="$1" sf="$2"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" != "$$" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  _pid_start_file_match "$pid" "$sf" >/dev/null 2>&1
}

# _osrc_disk_own_pgid -> this process's pgid (never a valid pause target).
_osrc_disk_own_pgid() { ps -o pgid= -p "$$" 2>/dev/null | tr -d ' '; }

# _osrc_disk_pause_job <jd> — SIGSTOP the delegate's process group (whole tree, including
# re-parented grandchildren that would keep writing) and the supervisor so no watchdog
# wall-clock arm can fire while frozen. Writes $jd/disk-paused. Never signals an unverified
# pid or our own process group. rc 0 when at least the delegate was stopped.
_osrc_disk_pause_job() {
  local jd="$1" ids pid pgid spid own stopped=0
  ids="$(_osrc_disk_job_pids "$jd")" || return 1
  pid="${ids%% *}"; pgid="$(printf '%s' "$ids" | awk '{print $2}')"; spid="$(printf '%s' "$ids" | awk '{print $3}')"
  own="$(_osrc_disk_own_pgid)"
  if [ -n "$pgid" ] && [ "$pgid" != "$own" ] && [ "$pgid" -gt 1 ] 2>/dev/null; then
    kill -STOP -- "-$pgid" 2>/dev/null && stopped=1
  else
    # No verified isolated group: stop only the proven delegate root (partial pause —
    # grandchildren may keep running; still ours, still safe).
    kill -STOP "$pid" 2>/dev/null && stopped=1
  fi
  [ "$stopped" = 1 ] || return 1
  if [ -n "$spid" ] && _osrc_disk_stop_verified "$spid" "$jd/supervisor_pid_start"; then
    kill -STOP "$spid" 2>/dev/null || true
  fi
  printf '%s\t%s\n' "$(date +%s)" "$(_osrc_free_kb 2>/dev/null)" > "$jd/disk-paused" 2>/dev/null || true
  # Keepalive: one appended line now and one per tick while paused. If the supervisor was
  # left running it reads this as liveness; if it was frozen, the size delta on resume
  # resets its idle clock. '>>> ' prefix keeps it out of every delegate-output check.
  _osrc_disk_keepalive "$jd" paused || true
  return 0
}

# _osrc_disk_resume_job <jd> — SIGCONT what _osrc_disk_pause_job stopped, then drop the
# marker. Re-verifies identity at resume time: a pid that died or was recycled while
# paused is NEVER signalled (its group may now belong to someone else).
_osrc_disk_resume_job() {
  local jd="$1" ids pid pgid spid own
  [ -f "$jd/disk-paused" ] || return 1
  # Order: feed the log first so a thawed supervisor sees fresh bytes, then thaw delegate
  # group, then the supervisor (it reaps/classifies a delegate that died mid-pause).
  _osrc_disk_keepalive "$jd" resumed || true
  ids="$(_osrc_disk_job_pids "$jd")" && {
    pid="${ids%% *}"; pgid="$(printf '%s' "$ids" | awk '{print $2}')"; spid="$(printf '%s' "$ids" | awk '{print $3}')"
    own="$(_osrc_disk_own_pgid)"
    if [ -n "$pgid" ] && [ "$pgid" != "$own" ] && [ "$pgid" -gt 1 ] 2>/dev/null; then
      kill -CONT -- "-$pgid" 2>/dev/null || true
    else
      kill -CONT "$pid" 2>/dev/null || true
    fi
    if [ -n "$spid" ] && _osrc_disk_stop_verified "$spid" "$jd/supervisor_pid_start"; then
      kill -CONT "$spid" 2>/dev/null || true
    fi
  } || {
    # Delegate unverifiable/dead: still thaw a proven supervisor so the job can be reaped
    # and classified instead of sitting frozen forever.
    spid="$(cat "$jd/supervisor_pid" 2>/dev/null)"
    _osrc_disk_stop_verified "$spid" "$jd/supervisor_pid_start" \
      && kill -CONT "$spid" 2>/dev/null || true
    printf 'disk-policy: delegate unverifiable at resume; possible stopped leftovers in job group (inspect %s)\n' "$jd" \
      >> "$OSRC_HOME/disk-policy/monitor.log" 2>/dev/null || true
  }
  rm -f "$jd/disk-paused" 2>/dev/null || true
  return 0
}

# _osrc_disk_keepalive <jd> <paused|resumed> — append the liveness/pause line to out.log.
_osrc_disk_keepalive() {
  local jd="$1" what="$2" free_g fk
  fk="$(_osrc_free_kb 2>/dev/null)"; case "$fk" in ''|*[!0-9]*) fk=0 ;; esac
  free_g=$(( fk / 1048576 ))
  case "$what" in
    paused)  printf '>>> [outsourcerer] disk-policy: job paused (free %sGB under pause floor); resumes automatically when space returns\n' "$free_g" >> "$jd/out.log" 2>/dev/null || true ;;
    resumed) printf '>>> [outsourcerer] disk-policy: job resumed (free %sGB)\n' "$free_g" >> "$jd/out.log" 2>/dev/null || true ;;
  esac
}

# _osrc_disk_paused_jobs -> one job dir per line that carries a disk-paused marker.
_osrc_disk_paused_jobs() {
  local f
  for f in "$OSRC_JOBS"/*/disk-paused; do
    [ -f "$f" ] && printf '%s\n' "${f%/disk-paused}"
  done
}

# _osrc_disk_marker_sweep — drop disk-paused markers whose job is terminal or whose
# delegate is provably gone (nothing left to resume). Runs every tick.
_osrc_disk_marker_sweep() {
  local jd st pid
  while IFS= read -r jd; do
    [ -n "$jd" ] || continue
    st="$(cat "$jd/status" 2>/dev/null)"
    if _osrc_disk_terminal_status "$st"; then rm -f "$jd/disk-paused" 2>/dev/null; continue; fi
    pid="$(cat "$jd/pid" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) continue ;; esac   # launching: keep marker, job may appear
    kill -0 "$pid" 2>/dev/null || rm -f "$jd/disk-paused" 2>/dev/null
  done <<_OSRC_PAUSED
$(_osrc_disk_paused_jobs)
_OSRC_PAUSED
}

# _osrc_disk_pause_sweep — pause every live supervised job not already paused.
# Returns the number newly paused.
_osrc_disk_pause_sweep() {
  local jd n=0 already
  already="$(_osrc_disk_paused_jobs)"
  for jd in "$OSRC_JOBS"/*/; do
    [ -d "$jd" ] || continue
    printf '%s\n' "$already" | grep -qxF "${jd%/}" && continue
    _osrc_disk_pause_job "${jd%/}" && n=$((n+1))
  done
  printf '%s' "$n"
}

# _osrc_disk_resume_sweep — resume every marked job (or drop the marker for dead ones).
_osrc_disk_resume_sweep() {
  local jd
  while IFS= read -r jd; do
    [ -n "$jd" ] || continue
    _osrc_disk_resume_job "$jd" || rm -f "$jd/disk-paused" 2>/dev/null
  done <<_OSRC_PAUSED
$(_osrc_disk_paused_jobs)
_OSRC_PAUSED
}

# _osrc_disk_keepalive_sweep — append the pause keepalive to every still-paused job.
_osrc_disk_keepalive_sweep() {
  local jd
  while IFS= read -r jd; do
    [ -n "$jd" ] && [ -f "$jd/disk-paused" ] && _osrc_disk_keepalive "$jd" paused
  done <<_OSRC_PAUSED
$(_osrc_disk_paused_jobs)
_OSRC_PAUSED
}

# ---- merged-lane auto-reclaim ---------------------------------------------------------

# _osrc_disk_reclaim — under disk pressure, delete ONLY manifest items that are verdict-SAFE
# AND kind worktree|branch: the artifacts of a lane proven merged (clean tree, tip preserved
# on remote/main or a tip-matched merged PR, owner done, aged, no open files). Everything else
# — job evidence, loops, autodetach logs, tmp dirs, every ASK item — stays manual. Each item is
# re-verified fresh at delete time; worktrees delete before branches (a branch is only SAFE
# once its worktree is gone, so branches are re-scanned after worktree deletion).
# OSRC_DISK_RECLAIM_MAX bounds deletes per call (default 10).
_osrc_disk_reclaim() {
  have jq 2>/dev/null || { printf '0'; return 0; }
  local max="${OSRC_DISK_RECLAIM_MAX:-10}" n=0 log
  case "$max" in ''|*[!0-9]*) max=10 ;; esac
  [ "$max" -gt 0 ] || { printf '0'; return 0; }
  log="$(_osrc_cl_log)"; mkdir -p "$(_osrc_cl_root)" 2>/dev/null || true
  n="$(_osrc_disk_reclaim_kinds worktree "$max" "$log")"
  local left=$(( max - ${n:-0} ))
  [ "$left" -gt 0 ] && n=$(( ${n:-0} + $(_osrc_disk_reclaim_kinds branch "$left" "$log") ))
  [ "${n:-0}" -gt 0 ] && _osrc_cleanup_state_write "$(_osrc_cleanup_items --no-size 2>/dev/null)" || true
  printf '%s' "${n:-0}"
}

# _osrc_disk_reclaim_kinds <worktree|branch> <max> <log> -> count deleted this phase.
_osrc_disk_reclaim_kinds() {
  local want="$1" max="$2" log="$3" items cands item raw verdict
  local path kind repo pp n=0
  items="$(_osrc_cleanup_items --no-size 2>/dev/null)" || return 0
  cands="$(printf '%s\n' "$items" | jq -sc --arg w "$want" '
    [ .[] | select(.verdict=="SAFE" and .kind==$w) ] | sort_by(.path) | .[]' 2>/dev/null)"
  [ -n "$cands" ] || { printf '0'; return 0; }
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    [ "$n" -ge "$max" ] && break
    raw="$(jq -c 'del(.verdict,.why,.size_kb)' <<<"$item" 2>/dev/null)" || continue
    verdict="$(_osrc_cleanup_verdict "$raw" 2>/dev/null)"
    [ "${verdict%%$'\t'*}" = "SAFE" ] || continue
    path="$(jq -r '.path // ""' <<<"$item")"; repo="$(jq -r '.repo // ""' <<<"$item")"
    [ -n "$path" ] || continue
    if [ "$want" = "worktree" ]; then
      pp="$(_osrc_realpath "$path" 2>/dev/null)" || continue
      # stdout must stay clean: this function's return is captured as a count.
      if git -C "$repo" worktree remove "$pp" >/dev/null 2>&1; then
        git -C "$repo" worktree prune >/dev/null 2>&1 || true
        printf '%s\tremoved-worktree\tdisk-policy\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pp" >> "$log" 2>/dev/null || true
        n=$((n+1))
      fi
    else
      if git -C "$repo" branch -D "$path" >/dev/null 2>&1; then
        printf '%s\tremoved-branch\tdisk-policy\t%s (%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$path" "$repo" >> "$log" 2>/dev/null || true
        n=$((n+1))
      fi
    fi
  done <<_OSRC_CANDS
$cands
_OSRC_CANDS
  printf '%s' "$n"
}

# ---- the policy tick -----------------------------------------------------------------

# _osrc_disk_monitor_tick — one policy pass. Safe to call from the monitor loop AND
# synchronously; never dies, always returns 0. Order: dead-marker sweep -> resume when
# recovered -> dead-zone hold -> pressure (episode report, reclaim, then pause+wake).
_osrc_disk_monitor_tick() {
  local free_kb floors launch_kb pause_kb crit_kb resume_kb free_gb n pcount paused_now ph
  free_kb="$(_osrc_free_kb 2>/dev/null)"; case "$free_kb" in ''|*[!0-9]*) return 0 ;; esac
  floors="$(_osrc_disk_floors_kb 2>/dev/null)"
  case "$floors" in ''|*[!0-9\ ]*) return 0 ;; esac
  launch_kb="${floors%% *}"; pause_kb="$(printf '%s' "$floors" | awk '{print $2}')"; crit_kb="${floors##* }"
  case "$pause_kb$crit_kb" in *[!0-9]*) return 0 ;; esac
  resume_kb="$(_osrc_disk_resume_kb "$launch_kb" "$pause_kb")"
  free_gb=$(( free_kb / 1048576 ))
  local dir; dir="$OSRC_HOME/disk-policy"
  _mkdir_private "$dir" >/dev/null 2>&1 || true
  _osrc_disk_marker_sweep
  if [ "$free_kb" -ge "$resume_kb" ]; then
    rm -f "$dir/.pressure" 2>/dev/null || true
    if _osrc_disk_paused_jobs | grep -q .; then
      _osrc_disk_resume_sweep
      _osrc_disk_wake resumed "disk.resume.$(date +%s)" \
        "disk recovered to $(_osrc_disk_fmt_kb "$free_kb") (resume floor $(_osrc_disk_fmt_kb "$resume_kb")); paused jobs resumed" || true
    fi
    return 0
  fi
  if [ "$free_kb" -ge "$pause_kb" ]; then
    # Dead zone between pause and resume floors: hold existing pauses, add none, keep
    # paused supervisors fed so an unfrozen one cannot stall-kill a frozen delegate.
    _osrc_disk_keepalive_sweep
    return 0
  fi
  # Pressure: one full report per episode, then reclaim merged-lane artifacts — freeing
  # beats freezing.
  if [ ! -f "$dir/.pressure" ]; then
    { printf '=== disk pressure %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; _osrc_disk_report; } \
      >> "$dir/monitor.log" 2>/dev/null || true
    date +%s > "$dir/.pressure" 2>/dev/null || true
  fi
  n="$(_osrc_disk_reclaim 2>/dev/null)"; n="${n:-0}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -gt 0 ]; then
    free_kb="$(_osrc_free_kb 2>/dev/null)"; case "$free_kb" in ''|*[!0-9]*) free_kb=0 ;; esac
    free_gb=$(( free_kb / 1048576 ))
    printf 'disk-policy: reclaimed %s merged-lane item(s); free now %s\n' "$n" "$(_osrc_disk_fmt_kb "$free_kb")" \
      >> "$dir/monitor.log" 2>/dev/null || true
  fi
  if [ "$free_kb" -ge "$resume_kb" ]; then
    rm -f "$dir/.pressure" 2>/dev/null || true
    _osrc_disk_paused_jobs | grep -q . && _osrc_disk_resume_sweep
    _osrc_disk_wake resumed "disk.resume.$(date +%s)" \
      "disk recovered to $(_osrc_disk_fmt_kb "$free_kb") after reclaim; paused jobs resumed" || true
    return 0
  fi
  if [ "$free_kb" -ge "$pause_kb" ]; then
    _osrc_disk_keepalive_sweep; return 0
  fi
  # Still under the pause floor: freeze live jobs and wake the owner (throttled).
  paused_now="$(_osrc_disk_pause_sweep)"
  _osrc_disk_keepalive_sweep
  pcount="$( _osrc_disk_paused_jobs | grep -c . 2>/dev/null)"; pcount="${pcount:-0}"
  if [ "${paused_now:-0}" -gt 0 ] || [ "$pcount" -gt 0 ]; then
    ph="$( _osrc_disk_paused_jobs | sed 's|.*/||' | sort | cksum | awk '{print $1}')"
    _osrc_disk_wake paused "disk.pause.$ph" \
      "disk pressure: free $free_gb GB under pause floor $(_osrc_disk_fmt_kb "$pause_kb"); ${pcount} job(s) SIGSTOPped (never killed), ${n} merged-lane item(s) reclaimed; they resume when space returns. $(_osrc_disk_report_oneline)" || true
  fi
  if [ "$free_kb" -lt "$crit_kb" ] && [ "$crit_kb" -gt 0 ]; then
    _osrc_disk_wake critical "disk.critical" \
      "CRITICAL disk: free $free_gb GB under critical floor $(_osrc_disk_fmt_kb "$crit_kb"); launches refused even with --ack/OSRC_DISK_OK. Free space now: $0 cleanup --apply, then empty Trash/caches. $(_osrc_disk_report_oneline)" || true
  fi
  return 0
}

# ---- monitor --------------------------------------------------------------------------------

# _osrc_disk_fleet_live -> rc 0 when at least one supervised job is non-terminal with a
# live-or-launching delegate. Drives the monitor's idle self-termination.
_osrc_disk_fleet_live() {
  local jd st pid
  [ -d "$OSRC_JOBS" ] || return 1
  for jd in "$OSRC_JOBS"/*/; do
    [ -d "$jd" ] || continue
    st="$(cat "$jd/status" 2>/dev/null)"
    _osrc_disk_terminal_status "$st" && continue
    case "$st" in running|launching|stalled\?|exploring\?|no-progress-writes) : ;; *) continue ;; esac
    pid="$(cat "$jd/pid" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    kill -0 "$pid" 2>/dev/null && return 0
  done
  return 1
}

# _osrc_disk_monitor_loop — the detached watcher. Stamps liveness, runs one policy tick per
# OSRC_DISK_POLICY_POLL (default 30s), exits after OSRC_DISK_MONITOR_IDLE_TICKS (default 40)
# ticks with no live fleet — ALWAYS resuming anything it paused before leaving, and dropping
# its liveness files so the next ensure respawns immediately.
_osrc_disk_monitor_loop() {
  trap '' HUP
  local dir poll maxidle idle=0 now sz
  dir="$OSRC_HOME/disk-policy"
  # Log inside the loop so a full disk can never fail the spawn itself.
  exec >>"$dir/monitor.log" 2>&1 || exec >/dev/null 2>&1
  poll="${OSRC_DISK_POLICY_POLL:-30}"; case "$poll" in ''|*[!0-9]*) poll=30 ;; esac
  [ "$poll" -lt 1 ] && poll=30
  maxidle="${OSRC_DISK_MONITOR_IDLE_TICKS:-40}"; case "$maxidle" in ''|*[!0-9]*) maxidle=40 ;; esac
  while :; do
    now="$(date +%s)"
    printf '%s\n' "$now" > "$dir/alive" 2>/dev/null || break
    # Rotate the log if it ever grows past ~512K.
    sz="$(wc -c < "$dir/monitor.log" 2>/dev/null | tr -d ' ')"
    case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    if [ "$sz" -gt 524288 ]; then
      tail -n 200 "$dir/monitor.log" > "$dir/monitor.log.tmp" 2>/dev/null \
        && mv -f "$dir/monitor.log.tmp" "$dir/monitor.log" 2>/dev/null || rm -f "$dir/monitor.log.tmp"
    fi
    if _osrc_disk_fleet_live; then idle=0; else idle=$(( idle + 1 )); fi
    _osrc_disk_monitor_tick || true
    if [ "$idle" -ge "$maxidle" ]; then
      _osrc_disk_resume_sweep || true
      _osrc_disk_marker_sweep || true
      rm -f "$dir/alive" "$dir/monitor.pid" 2>/dev/null || true
      printf 'disk-policy monitor: no live jobs for %s ticks; exiting\n' "$maxidle"
      break
    fi
    sleep "$poll"
  done
  return 0
}

# _osrc_disk_monitor_ensure — spawn the detached monitor unless a fresh liveness stamp says
# one is already running. Deduped by an atomic spawn claim; safe to call on every launch.
_osrc_disk_monitor_ensure() {
  [ "${OSRC_DISK_POLICY_OFF:-0}" = "1" ] && return 0
  [ -n "${OSRC_HOME:-}" ] && [ -d "$OSRC_HOME" ] || return 0
  local dir poll now alive claim cage mpid fresh
  dir="$OSRC_HOME/disk-policy"
  _mkdir_private "$dir" >/dev/null 2>&1 || return 0
  poll="${OSRC_DISK_POLICY_POLL:-30}"; case "$poll" in ''|*[!0-9]*) poll=30 ;; esac
  [ "$poll" -lt 1 ] && poll=30
  now="$(date +%s)"
  alive="$(cat "$dir/alive" 2>/dev/null)"; case "$alive" in ''|*[!0-9]*) alive=0 ;; esac
  # Fresh stamp -> a monitor ticked recently -> it is alive. Freshness = 3 polls, min 120s.
  fresh=$(( poll * 3 )); [ "$fresh" -lt 120 ] && fresh=120
  [ $(( now - alive )) -lt "$fresh" ] && return 0
  claim="$dir/.spawn"
  if [ -d "$claim" ]; then
    cage=$(( now - $(stat -c %Y "$claim" 2>/dev/null || stat -f %m "$claim" 2>/dev/null || echo 0) ))
    case "$cage" in ''|*[!0-9]*) cage=999999 ;; esac
    [ "$cage" -le 120 ] && return 0
    rm -rf "$claim" 2>/dev/null || true
  fi
  _osrc_atomic_mkdir "$claim" 2>/dev/null || return 0
  # Re-check under the claim: a monitor may have stamped between our first read and the mkdir.
  alive="$(cat "$dir/alive" 2>/dev/null)"; case "$alive" in ''|*[!0-9]*) alive=0 ;; esac
  if [ $(( now - alive )) -lt "$fresh" ]; then rmdir "$claim" 2>/dev/null || true; return 0; fi
  # fds 7/8/9 are the codebase's lock channels (state/endpoint/election); the beacon closes
  # them for the same reason — an inherited flock would be held for the monitor's lifetime.
  ( _osrc_disk_monitor_loop ) 7>&- 8>&- 9>&- </dev/null >/dev/null 2>&1 &
  mpid=$!
  printf '%s\n' "$now" > "$dir/alive" 2>/dev/null || true
  printf '%s\n' "$mpid" > "$dir/monitor.pid" 2>/dev/null || true
  rmdir "$claim" 2>/dev/null || true
  return 0
}
