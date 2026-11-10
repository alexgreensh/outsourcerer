#!/usr/bin/env bash
# test_devin_nowrite_floor.sh — the LANE-AWARE NO-WRITE FLOOR for the devin (dv) lane (issue #58).
#
# Root cause this guards: the exploring-timeout kill arm in _supervise judges on the two signals
# that stay dark during ANY single long devin command — out.log growth (devin's -p print mode
# emits nothing until exit) and _job_made_writes (a healthy test suite or build that only writes
# temp files outside the job cwd shows none). Its default window (OSRC_NOWRITE_KILL, 180s) then
# pre-empts the stall window the dv lane deliberately widened for exactly this signal vacuum (the
# OSRC_DEVIN_STALL_KILL floor in run_job) and reaps a healthy delegate mid-test-suite as
# exploring-timeout while its process is alive and working. On this lane a live-but-silent
# delegate is indistinguishable from a hung one, so the no-write KILL is floored up to the
# stall-kill window and defers the verdict to the stall arm at a tie. Flagging (the exploring?
# WARN, the no-progress-writes state) still surfaces on its original clock — flag early, kill late.
#
# The delegate below mimics the reporter's job: it speaks one line (passes the no-init gate), then
# runs one long QUIET command — no out.log growth, no writes under the job cwd — while dropping a
# witness line per second OUTSIDE the cwd (a test suite's temp files). The witnesses prove the
# process was alive and working past the no-write bound; the watchdog cannot see them, exactly as
# it cannot see the reporter's temp files.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"; export HOME="$TMP"
mkdir -p "$TMP/.local/share/devin/cli/logs"
cleanup() { rm -rf "$TMP"; }; trap cleanup EXIT
export OSRC_POLL=1 OSRC_NOINIT_SECS=60 OSRC_FS_PROGRESS=1 OSRC_HEARTBEAT_DISABLED=1
. "$SRC" >/dev/null 2>&1
mkdir -p "$OSRC_JOBS"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# run_case <label> <lane-meta> <lane-env> <warn> <kill> <hard> [env...] -> echoes "elapsed rc"
# The delegate: one plaintext line, then 120s of quiet work witnessed OUTSIDE the job cwd.
run_case() {
  local label="$1" lmeta="$2" lenv="$3" warn="$4" kill="$5" hard="$6"; shift 6
  local jd="$OSRC_JOBS/$label" w="$TMP/w-$label" wit="$TMP/wit-$label"; mkdir -p "$jd" "$w"
  if [ -n "$lmeta" ]; then
    printf '{"verb":"edit","lane":"%s","cwd":"%s","model":"kimi","started":%s}' "$lmeta" "$w" "$(date +%s)" > "$jd/meta.json"
  else
    printf '{"verb":"edit","cwd":"%s","model":"kimi","started":%s}' "$w" "$(date +%s)" > "$jd/meta.json"
  fi
  local t0; t0=$(date +%s)
  env "$@" WITNESS="$wit" OSRC_JOB_VERB=edit ${lenv:+OSRC_JOB_LANE="$lenv"} bash -c '
    set -uo pipefail; export OSRC_SOURCED=1; . "$0" >/dev/null 2>&1
    _supervise "$1" "$2" "$3" "$4" -- sh -c "echo Kicking off the full test suite now; i=0; while [ \$i -lt 120 ]; do i=\$((i+1)); sleep 1; date +%s >> \"\$WITNESS\"; done"' \
    "$SRC" "$jd" "$warn" "$kill" "$hard" >/dev/null 2>"$jd/sup.err"
  echo "$(( $(date +%s) - t0 ))"
}
wit()  { wc -l < "$TMP/wit-$1" 2>/dev/null || echo 0; }
st()   { cat "$OSRC_JOBS/$1/status" 2>/dev/null; }
rsn()  { cat "$OSRC_JOBS/$1/reason" 2>/dev/null; }

# 1. THE BUG: dv, no-write kill at 6s, stall kill at 18s. Before the fix the job died at ~6s as
#    exploring-timeout; now it must survive past the old bound and die at the STALL window with
#    the stall arm's verdict, which is the arm that consults every liveness input.
el=$(run_case c1 dv "" 300 18 60 OSRC_NOWRITE_WARN=3 OSRC_NOWRITE_KILL=6)
[ "$(wit c1)" -ge 12 ] && ok "dv quiet command survives past the OSRC_NOWRITE_KILL=6s bound (alive $(wit c1)s)" \
  || bad "dv job died at the no-write bound: only $(wit c1)s of witnesses (elapsed ${el}s)"
[ "$(rsn c1)" = "stall-kill" ] && ok "dv verdict at the tie belongs to the stall arm (reason=stall-kill)" \
  || bad "dv verdict: reason='$(rsn c1)' (want stall-kill, never exploring-timeout)"
[ "$(st c1)" = "wedged" ] && ok "dv silent job is still bounded (stall window reaps it)" || bad "dv final status '$(st c1)'"

# 2. Flagging is NOT deferred — only the kill is. The exploring? WARN fires on the original clock
#    and quotes the FLOORED bound, so the warning never promises an earlier kill than happens.
grep -q 'ZERO file writes' "$OSRC_JOBS/c1/sup.err" && ok "exploring? WARN still surfaces on the original clock" \
  || bad "exploring? WARN missing for a write-free dv job"
grep -q 'stopped after 18s' "$OSRC_JOBS/c1/sup.err" && ok "WARN quotes the floored no-write window (18s, not 6s)" \
  || bad "WARN quotes the pre-floor window: $(grep -o 'stopped after [0-9]*s' "$OSRC_JOBS/c1/sup.err" | head -1)"

# 3. Escape hatch: OSRC_DEVIN_NOWRITE_KILL=0 restores the pre-fix behavior exactly.
el=$(run_case c3 dv "" 300 18 60 OSRC_NOWRITE_WARN=3 OSRC_NOWRITE_KILL=6 OSRC_DEVIN_NOWRITE_KILL=0)
[ "$(rsn c3)" = "exploring-timeout" ] && [ "$(wit c3)" -le 12 ] \
  && ok "OSRC_DEVIN_NOWRITE_KILL=0 disables the floor (killed at ~6s, exploring-timeout)" \
  || bad "escape hatch: reason='$(rsn c3)' witnesses=$(wit c3) (elapsed ${el}s)"

# 4. A custom OSRC_DEVIN_NOWRITE_KILL sets the floor explicitly (12s < stall window 60s): the
#    no-write arm fires at 12s, not at 6s (pre-floor) and not at 60s (stall).
el=$(run_case c4 dv "" 300 60 120 OSRC_NOWRITE_WARN=3 OSRC_NOWRITE_KILL=6 OSRC_DEVIN_NOWRITE_KILL=12)
[ "$(rsn c4)" = "exploring-timeout" ] && [ "$(wit c4)" -ge 8 ] && [ "$(wit c4)" -le 18 ] \
  && ok "custom OSRC_DEVIN_NOWRITE_KILL=12 floors the kill at ~12s (alive $(wit c4)s)" \
  || bad "custom floor: reason='$(rsn c4)' witnesses=$(wit c4) (elapsed ${el}s)"

# 5. Other lanes are untouched: the no-write kill on cc fires at the unfloored 6s bound.
el=$(run_case c5 cc "" 300 18 60 OSRC_NOWRITE_WARN=3 OSRC_NOWRITE_KILL=6)
[ "$(rsn c5)" = "exploring-timeout" ] && [ "$(wit c5)" -le 12 ] \
  && ok "non-devin lane unchanged (killed at ~6s, exploring-timeout)" \
  || bad "cc lane behavior changed: reason='$(rsn c5)' witnesses=$(wit c5) (elapsed ${el}s)"

# 6. The floor never LOWERS a window the user set higher: explicit OSRC_NOWRITE_KILL=15 with a
#    custom floor of 12s still kills at ~15s.
el=$(run_case c6 dv "" 300 60 120 OSRC_NOWRITE_WARN=3 OSRC_NOWRITE_KILL=15 OSRC_DEVIN_NOWRITE_KILL=12)
[ "$(rsn c6)" = "exploring-timeout" ] && [ "$(wit c6)" -ge 11 ] \
  && ok "floor never lowers a higher user window (OSRC_NOWRITE_KILL=15 honored, alive $(wit c6)s)" \
  || bad "floor lowered a user window: reason='$(rsn c6)' witnesses=$(wit c6) (elapsed ${el}s)"

# 7. Lane detection works without jq/meta: OSRC_JOB_LANE carries the lane into _supervise (the
#    OSRC_JOB_VERB precedent), so a meta.json with no lane key still gets the floor.
el=$(run_case c7 "" dv 300 18 60 OSRC_NOWRITE_WARN=3 OSRC_NOWRITE_KILL=6)
[ "$(wit c7)" -ge 12 ] && [ "$(rsn c7)" = "stall-kill" ] \
  && ok "OSRC_JOB_LANE env carry applies the floor when meta.json has no lane key" \
  || bad "env carry: reason='$(rsn c7)' witnesses=$(wit c7) (elapsed ${el}s)"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
