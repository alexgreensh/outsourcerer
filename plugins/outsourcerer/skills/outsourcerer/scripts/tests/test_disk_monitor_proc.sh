#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_disk_monitor_proc.sh -- the detached disk monitor is identifiable and ends when idle.
#   1. `ps` shows it as osrc-disk-monitor (not a copy of whatever command launched it), it still
#      reads free space through the launching shell's functions, and its snapshot file is gone.
#   2. with the default idle setting it exits on its own once no job or lane is left to watch.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "${TMPDIR%/}/.test-disk-monitor-proc.XXXXXX")" || { echo "FAIL: scratch" >&2; exit 1; }
KILL=""; trap 'for p in $KILL; do kill -9 "$p" 2>/dev/null; done; p="$(cut -d"|" -f1 "$MH/disk-policy/monitor.lock/owner" 2>/dev/null)"; [ -z "$p" ] || kill "$p" 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0
export OSRC_DISK_POLICY_POLL=1 FREEF="$TMP/free_kb"; unset OSRC_DISK_MONITOR_IDLE_TICKS
mkdir -p "$HOME"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
osrc() { OSRC_HOME="$1" OSRC_SOURCED=1 bash -c '. "$0" >/dev/null 2>&1
    _osrc_free_kb() { cat "$FREEF" 2>/dev/null; }
    eval "$1"' "$SRC" "$2" 2>&1; }
wait_for() { local i=0; while [ "$i" -lt "${2:-50}" ]; do eval "$1" && return 0; sleep 0.2; i=$((i+1)); done; return 1; }
owner_pid() { cut -d'|' -f1 "$MH/disk-policy/monitor.lock/owner" 2>/dev/null; }
stopped() { case "$(ps -o stat= -p "$1" 2>/dev/null)" in *T*) return 0 ;; esac; return 1; }

MH="$TMP/mon"; mkdir -p "$MH/jobs/job-m" "$MH/disk-policy"
printf 'OSRC_DISK_MIN_GB=10\nOSRC_DISK_PAUSE_GB=4\nOSRC_DISK_CRITICAL_GB=1\n' > "$MH/disk-policy/settings"
sleep 300 & MJ=$!; KILL="$KILL $MJ"; disown "$MJ" 2>/dev/null
echo running > "$MH/jobs/job-m/status"; echo "$MJ" > "$MH/jobs/job-m/pid"
LC_ALL=C ps -o lstart= -p "$MJ" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g' > "$MH/jobs/job-m/pid_start"
printf '%s' 3145728 > "$FREEF"   # 3 GB: under the 4 GB pause floor, so the monitor must pause the job

osrc "$MH" '_osrc_disk_monitor_ensure' >/dev/null
wait_for '[ -n "$(owner_pid)" ]' 50
M="$(owner_pid)"
args="$(ps -o args= -p "$M" 2>/dev/null)"
case "$args" in osrc-disk-monitor*) ok "ps names the monitor osrc-disk-monitor ($M)" ;; *) bad "monitor $M shows as: $args" ;; esac
wait_for 'stopped '"$MJ" 50 && ok "the named monitor reads free space through the launcher's functions (paused the job)" || bad "job not paused: $(ps -o stat= -p "$MJ")"
[ -z "$(ls -A "$MH/disk-policy" | grep '^\.monitor\.')" ] && ok "the start snapshot is deleted once read" || bad "snapshot left: $(ls -A "$MH/disk-policy")"

# nothing left to watch: space back, job finished -> the monitor exits by itself (default idle)
printf '%s' 8388608 > "$FREEF"; kill -CONT "$MJ" 2>/dev/null; kill -9 "$MJ" 2>/dev/null; echo done > "$MH/jobs/job-m/status"
wait_for '! kill -0 '"$M"' 2>/dev/null' 75 && ok "monitor exits on its own once no job or lane is left" || bad "monitor $M still running: $(ps -o args= -p "$M")"
grep -q "monitor $M idle; exiting" "$MH/disk-policy/monitor.log" && ok "idle exit is logged" || bad "log: $(tail -3 "$MH/disk-policy/monitor.log")"

echo "test_disk_monitor_proc: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
