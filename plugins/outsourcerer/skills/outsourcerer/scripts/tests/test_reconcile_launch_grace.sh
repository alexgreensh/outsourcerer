#!/bin/bash
# test_reconcile_launch_grace.sh — regression for the launch race in _reconcile_status's
# running-branch: run_job writes status=running BEFORE it spawns the delegate and records
# pid/supervisor_pid. A reconcile (status/result/watch, or the heartbeat's read-only tick) landing
# in that window must NOT call the job interrupted/dead: nothing has had the chance to fail yet.
# Flip only when the launch is provably stuck: no pid file AND no delegate output AND past the
# bounded launch grace. Genuine death and pid-reuse handling must be untouched.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n $SRC"; exit 1; }

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d "$PWD/.test-reconcile-grace.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
mkdir -p "$OSRC_HOME/jobs" "$OSRC_HOME/sessions"

mkjob() { # <id> <age_seconds|now> -> job dir with status=running, empty out.log, no pid files
  local id="$1" age="$2" jd="$OSRC_HOME/jobs/$1" sa
  mkdir -p "$jd"; : > "$jd/out.log"; echo running > "$jd/status"
  if [ "$age" = now ]; then sa=$(date +%s); else sa=$(( $(date +%s) - age )); fi
  echo "$sa" > "$jd/started_at"
  [ "$age" = now ] || touch -d "@$sa" "$jd" 2>/dev/null || true
}
rc_of() { local id="$1"; ( set --; OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1; _reconcile_status "$id" ); }
rc_ro() { local id="$1"; ( set --; OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1; OSRC_RECONCILE_READ_ONLY=1 _reconcile_status "$id" ); }

# 1. young launch-window job (running, no pid files, empty out.log) is NOT called interrupted
mkjob J-young now
v="$(rc_of J-young)"
[ "$v" = running ] && ok "young pid-less running job is not flipped (write path)" || bad "young pid-less running job flipped to '$v'"
[ "$(cat "$OSRC_HOME/jobs/J-young/status")" = running ] && ok "young job status file untouched" || bad "young job status file mutated to $(cat "$OSRC_HOME/jobs/J-young/status")"

# 2. same via the heartbeat's read-only path (the #48 supervision-disarm route)
v="$(rc_ro J-young)"
[ "$v" = running ] && ok "read-only reconcile keeps young job running" || bad "read-only reconcile says '$v' for young job"

# 3. heartbeat keeps watching while a job is mid-launch
if ( set --; OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1; _heartbeat_active_work ); then
  ok "heartbeat sees active work during the launch window"
else
  bad "heartbeat disarms supervision during the launch window"
fi

# 4. the flip still happens once the launch is provably stuck (past grace, no pid, no output)
mkjob J-stuck 600
v="$(rc_of J-stuck)"
[ "$v" = interrupted ] && ok "stuck launch (old, no pid, no output) reconciles interrupted" || bad "stuck launch verdict '$v', want interrupted"

# 5. bounded grace: a job past a SHORT custom grace flips; the default would keep it
mkjob J-custom 60
v="$( ( set --; OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1; OSRC_LAUNCH_GRACE=30 _reconcile_status J-custom ) )"
[ "$v" = interrupted ] && ok "OSRC_LAUNCH_GRACE override bounds the window" || bad "custom grace verdict '$v', want interrupted"

# 6. unverifiable started_at falls back to job-dir mtime: young dir stays alive, never immortal-by-default
mkjob J-nodate now; rm -f "$OSRC_HOME/jobs/J-nodate/started_at"
v="$(rc_of J-nodate)"
[ "$v" = running ] && ok "missing started_at + young dir mtime stays running (no immortal default, no false flip)" || bad "missing started_at verdict '$v'"

# 7. ...and a pid-less job whose dir is OLD flips even without a parseable started_at (no immortality)
mkjob J-oldnodate now; echo garbage > "$OSRC_HOME/jobs/J-oldnodate/started_at"
touch -d '1 hour ago' "$OSRC_HOME/jobs/J-oldnodate"
v="$(rc_of J-oldnodate)"
[ "$v" = interrupted ] && ok "corrupt started_at + old dir flips via dir mtime (bounded, no immortal unknown)" || bad "corrupt started_at + old dir verdict '$v', want interrupted"

# 8. delegate output in the launch window changes nothing about the age bound: young stays running
mkjob J-speaking now; echo '>>> launcher banner' > "$OSRC_HOME/jobs/J-speaking/out.log"; echo 'partial model output' >> "$OSRC_HOME/jobs/J-speaking/out.log"
v="$(rc_of J-speaking)"
[ "$v" = running ] && ok "young output-bearing pid-less job stays running (mid-write gap)" || bad "young output-bearing pid-less job flipped to '$v'"

# 8b. ...but OLD + no pid files flips even with output (the pid record never landed: launch is lost)
mkjob J-oldspeak 600; echo '>>> launcher banner' > "$OSRC_HOME/jobs/J-oldspeak/out.log"; echo 'partial model output' >> "$OSRC_HOME/jobs/J-oldspeak/out.log"
v="$(rc_of J-oldspeak)"
[ "$v" = interrupted ] && ok "old output-bearing pid-less job flips (bounded, no immortal unknown)" || bad "old output-bearing pid-less job verdict '$v', want interrupted"

# 9. genuine death still reconciles: dead delegate pid + dead supervisor pid -> interrupted
mkjob J-dead now
echo 999999 > "$OSRC_HOME/jobs/J-dead/pid"; echo 999998 > "$OSRC_HOME/jobs/J-dead/supervisor_pid"
v="$(rc_of J-dead)"
[ "$v" = interrupted ] && ok "provably dead pids still reconcile interrupted" || bad "dead-pid job verdict '$v', want interrupted"

# 10. pid-reuse defense preserved: live pid whose recorded start does not match -> interrupted
mkjob J-reuse now
sleep 2; ( sleep 30 ) & faker=$!
echo "$faker" > "$OSRC_HOME/jobs/J-reuse/pid"
LC_ALL=C ps -o lstart= -p 1 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g' > "$OSRC_HOME/jobs/J-reuse/pid_start"
v="$(rc_of J-reuse)"; kill "$faker" 2>/dev/null
[ "$v" = interrupted ] && ok "recycled pid with mismatched start still reconciles interrupted" || bad "pid-reuse job verdict '$v', want interrupted"

echo "----"
echo "PASS=$pass FAIL=$fail"
