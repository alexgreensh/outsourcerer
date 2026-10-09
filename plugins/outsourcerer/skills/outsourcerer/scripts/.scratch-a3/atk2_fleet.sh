#!/usr/bin/env bash
# atk2_fleet: hostile job dirs through _fleet_snapshot_collect -> guard.
set -uo pipefail
S="/Users/alexgreenshpun/CascadeProjects/Prompts/PERSONAL_OS/PROJECTS/outsourcerer/sessions/2026-10-09-pr-sweep/wt-a-ttl/plugins/outsourcerer/skills/outsourcerer/scripts/outsourcerer.sh"
export OSRC_HOME; OSRC_HOME="$(mktemp -d)"
export OSRC_JOBS="$OSRC_HOME/jobs" OSRC_FLEET_SNAPSHOT="$OSRC_HOME/fleet.json"
export OSRC_CLAUDE_SESSIONS_DIR="$OSRC_HOME/nosess" OSRC_CLAUDE_PROJECTS_DIR="$OSRC_HOME/noproj"
export HOME; HOME="$(mktemp -d)"
mkdir -p "$OSRC_JOBS" "$OSRC_CLAUDE_SESSIONS_DIR" "$OSRC_CLAUDE_PROJECTS_DIR"
set --; OSRC_SOURCED=1 . "$S" >/dev/null 2>&1
have jq || { echo "no jq; skip"; exit 0; }

mkjob() { # <id> <status> [exit] [pid] [spid] ; "-" = absent file
  local d="$OSRC_JOBS/$1"; mkdir -p "$d"
  printf '%s' "$2" > "$d/status"
  [ "${3:-}" != "-" ] && printf '%s' "${3:-}" > "$d/exit"
  [ "${4:-}" != "-" ] && printf '%s' "${4:-}" > "$d/pid"
  [ "${5:-}" != "-" ] && printf '%s' "${5:-}" > "$d/supervisor_pid"
  printf '{"id":"%s","provider":"cc","verb":"run","model":"m","started":1,"cwd":"/tmp"}' "$1" > "$d/meta.json"
}
state_of() { # <id> -> fleet state from a fresh collect
  _fleet_snapshot_collect > "$OSRC_HOME/snap.json" 2>/dev/null
  jq -r --arg id "$1" '.items[] | select(.owner=="managed" and .job_id==$id) | .state' "$OSRC_HOME/snap.json" 2>/dev/null
}
guard_says() { _blind_turn_guard 2>&1 | head -3; echo "rc=$?"; }

# find two independently dead pids
probe_dead() { local p=$1; while kill -0 "$p" 2>/dev/null; do p=$((p+1)); [ $p -gt 999999 ] && { echo 0; return; }; done; echo "$p"; }
dead1="$(probe_dead 40000)"; dead2="$(probe_dead $((dead1+1)))"
sleep 61.43 & live_pid=$!

echo "== baseline: live blocked job stays blocked =="
mkjob j_live blocked - "$live_pid" -
echo "state=$(state_of j_live) (want blocked)"

echo "== exit file + live pid: exit wins -> stopped =="
mkjob j_exitlive blocked 3 "$live_pid" -
echo "state=$(state_of j_exitlive) (want stopped)"

echo "== garbage pid file, no exit =="
mkjob j_garbage blocked - "abc" -
echo "state=$(state_of j_garbage) (want blocked: corrupt != proven dead)"

echo "== multi-line pid file =="
printf '11111\n22222\n' > /dev/null # no-op
d="$OSRC_JOBS/j_multiline"; mkjob j_multiline blocked - x - ; printf '11111\n22222\n' > "$d/pid"
echo "state=$(state_of j_multiline) (want blocked: corrupt != proven dead)"

echo "== pid=0 =="
mkjob j_zero blocked - "0" -
echo "state=$(state_of j_zero) (want blocked: not a real job pid, unverifiable)"

echo "== pid=-1 =="
mkjob j_neg blocked - "-1" -
echo "state=$(state_of j_neg) (want blocked: unverifiable)"

echo "== recorded pid = our own live shell pid (recycled-pid shape) =="
mkjob j_ownpid blocked - "$$" -
echo "state=$(state_of j_ownpid) (want blocked without pid_start: live pid, can't disprove)"

echo "== recorded pid live BUT pid_start mismatch (true recycle) =="
mkjob j_recycle blocked - "$$" -
printf 'Sun Jan  1 00:00:00 1990' > "$OSRC_JOBS/j_recycle/pid_start"
echo "pid_start recorded=[$(cat "$OSRC_JOBS/j_recycle/pid_start")] live=[$(ps -o lstart= -p $$ | tr -s ' ')]"
echo "state=$(state_of j_recycle) (want stopped: live pid is a different process)"

echo "== recorded pid live WITH matching pid_start (genuinely ours) =="
mkjob j_ours blocked - "$$" -
ps -o lstart= -p $$ | tr -s ' ' > "$OSRC_JOBS/j_ours/pid_start"
echo "state=$(state_of j_ours) (want blocked: start matches, really live)"

echo "== missing status =="
d="$OSRC_JOBS/j_nostatus"; mkdir -p "$d"; rm -f "$d/status"
printf '{"id":"j_nostatus","provider":"cc","verb":"run","model":"m","started":1,"cwd":"/tmp"}' > "$d/meta.json"
echo "state=$(state_of j_nostatus)"

echo "== status with CRLF =="
mkjob j_crlf blocked - "$dead1" -
printf 'blocked\r\n' > "$OSRC_JOBS/j_crlf/status"
echo "state=$(state_of j_crlf)"

echo "== symlinked job dir =="
mkjob j_real blocked - "$dead1" "$dead2"
ln -sfn "$OSRC_JOBS/j_real" "$OSRC_JOBS/j_link"
echo "state(link)=$(state_of j_link) state(real)=$(state_of j_real)"

echo "(500-dir timing measured earlier: 48s baseline)"

kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
echo DONE
