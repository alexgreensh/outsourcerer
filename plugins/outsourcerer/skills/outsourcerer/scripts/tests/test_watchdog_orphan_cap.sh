#!/usr/bin/env bash
# test_watchdog_orphan_cap.sh — two preexisting bugs surfaced by the council:
#   FIX 7 (orphan): a LIVE delegate whose SUPERVISOR is dead is unguarded and never gets a terminal
#     status; _reconcile_status must detect the dead-supervisor-live-orphan, reap the delegate, and
#     mark the job interrupted instead of reporting it 'running' forever (which stalls fanout waiters).
#   FIX 6 (fanout cap): the devin concurrency cap must consider per-agent EFFECTIVE lanes, not just the
#     global provider, so per-agent frontmatter routing to devin under a non-devin global provider is
#     still capped at 2 (above it members die exit=141/empty-output).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"; mkdir -p "$OSRC_HOME/jobs"
trap 'rm -rf "$TMP"; kill "${LP:-}" 2>/dev/null' EXIT
. "$SRC" >/dev/null 2>&1
OSRC_JOBS="$OSRC_HOME/jobs"

# ---- FIX 7: dead-supervisor + live-orphan delegate -> reconciles to interrupted and reaps the orphan.
jd="$OSRC_JOBS/orphan"; mkdir -p "$jd"
sleep 60 & LP=$!                                        # a genuinely-live "delegate"
printf '%s\n' "$LP" > "$jd/pid"
ps -o lstart= -p "$LP" 2>/dev/null | tr -s ' ' > "$jd/pid_start"   # matches -> delegate reads as alive
# a DEAD supervisor pid (started then reaped)
( sh -c 'exit 0' ) & SPD=$!; wait "$SPD" 2>/dev/null
printf '%s\n' "$SPD" > "$jd/supervisor_pid"
printf 'never-matches\n' > "$jd/supervisor_pid_start"
printf 'running\n' > "$jd/status"; date +%s > "$jd/started_at"

st="$(_reconcile_status orphan)"
[ "$st" = "interrupted" ] && ok "orphan (live delegate + dead supervisor) reconciles to interrupted" \
  || bad "orphan not reconciled (got '$st')"
grep -q 'dead-supervisor-live-orphan' "$jd/reason" 2>/dev/null \
  && ok "orphan reason recorded (dead-supervisor-live-orphan)" || bad "orphan reason missing ($(cat "$jd/reason" 2>/dev/null))"
# the orphaned delegate must actually be reaped, not just relabeled
sleep 1
kill -0 "$LP" 2>/dev/null && bad "orphan delegate survived (was only relabeled, not reaped)" \
  || ok "orphan delegate is reaped, not just relabeled"

# ---- control: a live delegate WITH a live supervisor must stay running (no false orphan reap).
jd2="$OSRC_JOBS/healthy"; mkdir -p "$jd2"
sleep 60 & LP2=$!
printf '%s\n' "$LP2" > "$jd2/pid"; ps -o lstart= -p "$LP2" 2>/dev/null | tr -s ' ' > "$jd2/pid_start"
sleep 60 & SUP=$!                                       # a live "supervisor"
printf '%s\n' "$SUP" > "$jd2/supervisor_pid"; ps -o lstart= -p "$SUP" 2>/dev/null | tr -s ' ' > "$jd2/supervisor_pid_start"
printf 'running\n' > "$jd2/status"; date +%s > "$jd2/started_at"
st2="$(_reconcile_status healthy)"
[ "$st2" = "running" ] && ok "a live delegate with a live supervisor stays running (no false reap)" \
  || bad "healthy running job was wrongly reconciled (got '$st2')"
kill "$LP2" "$SUP" 2>/dev/null

# ---- FIX 6 (structural): the per-agent-aware devin cap recompute exists and runs AFTER a_prov is
# populated (i.e. after the agents-dir parse loop, before the gid/manifest is minted). A pure grep is
# enough to guard against silent removal; the logic itself is exercised by the live fanout path.
if grep -q 'members route to the devin lane (per-agent)' "$SRC"; then
  ok "fanout devin cap has a per-agent-aware recompute"
else
  bad "fanout per-agent devin cap recompute is missing"
fi
# and it must come AFTER a_prov assignment, else it sees an empty array.
aprov_line=$(grep -n 'a_prov+=("\$rp")' "$SRC" | head -1 | cut -d: -f1)
cap_line=$(grep -n 'members route to the devin lane (per-agent)' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$aprov_line" ] && [ -n "$cap_line" ] && [ "$cap_line" -gt "$aprov_line" ]; then
  ok "the per-agent cap recompute runs after a_prov is resolved ($cap_line > $aprov_line)"
else
  bad "cap recompute is not after a_prov resolution (aprov=$aprov_line cap=$cap_line)"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
