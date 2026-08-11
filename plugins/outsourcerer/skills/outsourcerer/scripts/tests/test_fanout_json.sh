#!/usr/bin/env bash
# test_fanout_json.sh — `fanout status --json` must reconcile each member before counting.
#
# _fanout_status routes every per-job status read through _reconcile_status. Its JSON summary
# counts `done?` as done, `canceled`/`interrupted` as failed, and must NOT inflate a dead job
# whose on-disk status still says `running` into the running bucket. The reconciliation flips
# a running job whose delegate pid is gone (and is not a recycled pid) to `interrupted`, which
# the summary then counts as failed.
#
# This test builds a fanout group of four fake member job dirs with exactly the files
# _reconcile_status reads (status / pid / pid_start / meta.json) and checks the JSON summary:
#   job1  status=done?      -> done
#   job2  status=running + a guaranteed-dead high pid + stale pid_start
#                          -> _reconcile_status flips to interrupted -> failed
#   job3  status=done       -> done
#   job4  status=canceled   -> failed
#
# Faithful expected summary (the code's case statement counts BOTH interrupted and canceled
# into `fail`, so failed=2, not 1): total=4, running=0, done=2, blocked=0, failed=2.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed on $SRC"; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required for this test"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-fanout-json.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# OSRC_HOME must be set BEFORE sourcing: outsourcerer.sh pins OSRC_HOME/OSRC_JOBS at source
# time (lines ~238-239). OSRC_SOURCED=1 keeps the source guard from running main().
export OSRC_HOME="$TMP/home"
export OSRC_SOURCED=1
mkdir -p "$OSRC_HOME/jobs"
. "$SRC" >/dev/null 2>&1

# Refuse a false green: if the functions we are testing did not load, the assertions below
# would silently no-op. Verify they exist before doing anything.
type -t _fanout_status   >/dev/null || { echo "FAIL: _fanout_status not loaded";   exit 1; }
type -t _reconcile_status >/dev/null || { echo "FAIL: _reconcile_status not loaded"; exit 1; }
type -t _fanout_dir       >/dev/null || { echo "FAIL: _fanout_dir not loaded";     exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

GID="grp-test"
GD="$OSRC_HOME/fanout/$GID"
mkdir -p "$GD/findings"

# A pid this high is guaranteed not to exist on macOS/Linux, so kill -0 fails and
# _reconcile_status cannot keep the job alive via the delegate pid. We also write a stale
# pid_start so that even if kill -0 somehow succeeded, the saved start time would not match
# the live process's lstart and the job would still be reaped.
DEAD_PID=999999999
STALE_PID_START="Mon Jan  1 00:00:00 1970"

make_job() {
  # make_job <jid> <status> [pid] [pid_start]
  local jid="$1" st="$2" pid="${3:-}" pstart="${4:-}"
  local jd="$OSRC_JOBS/$jid"
  mkdir -p "$jd"
  printf '%s\n' "$st" > "$jd/status"
  [ -n "$pid" ]    && printf '%s\n' "$pid"    > "$jd/pid"
  [ -n "$pstart" ] && printf '%s\n' "$pstart" > "$jd/pid_start"
  # Minimal but valid meta.json — _job_json slurpfiles it; every field is `// null` so this
  # shape is sufficient and keeps the jobs[] array populated for the JSON path.
  printf '{"id":"%s","model":"free","verb":"research","started":1700000000}\n' "$jid" > "$jd/meta.json"
}

make_job "job1" 'done?'
make_job "job2" 'running' "$DEAD_PID" "$STALE_PID_START"
make_job "job3" 'done'
make_job "job4" 'canceled'

# members.tsv is the file _fanout_status walks: one `jid<TAB>label` line per member.
: > "$GD/members.tsv"
printf 'job1\talpha\n' >> "$GD/members.tsv"
printf 'job2\tbeta\n'  >> "$GD/members.tsv"
printf 'job3\tgamma\n' >> "$GD/members.tsv"
printf 'job4\tdelta\n' >> "$GD/members.tsv"

# --- unit check: the dead running job must be reconciled OUT of running ---
r="$(_reconcile_status job2 2>/dev/null || echo '?')"
case "$r" in
  interrupted) ok "job2 (running + dead pid) reconciled to interrupted" ;;
  *) bad "job2 reconciled to [$r], expected interrupted (dead job inflated as live?)"
     bad "on-disk status after reconcile: [$(cat "$OSRC_JOBS/job2/status" 2>/dev/null)]" ;;
esac

# --- the JSON summary path ---
out="$(_fanout_status --json "$GID" 2>/dev/null)"
[ -n "$out" ] || { bad "_fanout_status --json produced no output"; echo; echo "RESULT: $pass passed, $fail failed"; exit 1; }

total="$(printf '%s' "$out" | jq -r '.summary.total')"
run="$(printf '%s' "$out"   | jq -r '.summary.running')"
done_="$(printf '%s' "$out" | jq -r '.summary.done')"
blk="$(printf '%s' "$out"   | jq -r '.summary.blocked')"
fail_="$(printf '%s' "$out" | jq -r '.summary.failed')"

check() { # check <field> <got> <want>
  local f="$1" g="$2" w="$3"
  [ "$g" = "$w" ] && ok "summary.$f=$g" || bad "summary.$f=$g, expected $w"
}

check total   "$total" 4
check running "$run"   0
check done    "$done_" 2
check blocked "$blk"   0
check failed  "$fail_" 2

# --- the jobs[] array must carry all 4 members and report the reconciled per-job status ---
jobs_count="$(printf '%s' "$out" | jq -r '.jobs | length')"
[ "$jobs_count" = 4 ] && ok "jobs[] has 4 entries" || bad "jobs[] has $jobs_count entries, expected 4"

job2_status="$(printf '%s' "$out" | jq -r '.jobs[] | select(.job_id=="job2") | .status')"
[ "$job2_status" = "interrupted" ] && ok "job2 reported as interrupted in jobs[]" \
                                    || bad "job2 reported as [$job2_status] in jobs[], expected interrupted"

# wait and collect must agree with status: a canceled member is a failed fanout outcome.
_fanout_wait "$GID" >/dev/null 2>&1; wait_rc=$?
[ "$wait_rc" -ne 0 ] && ok "fanout wait returns nonzero for canceled member" \
                       || bad "fanout wait returned 0 despite canceled member"
_fanout_collect "$GID" >/dev/null 2>&1; collect_rc=$?
[ "$collect_rc" -ne 0 ] && ok "fanout collect returns nonzero for canceled member" \
                          || bad "fanout collect returned 0 despite canceled member"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
