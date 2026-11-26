#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_heartbeat_immortal_beacon.sh — the heartbeat never counts a flatlined job as active work.
#
# Root cause guarded: _heartbeat_active_work read each job's `status` file RAW and treated
# launching|running|exploring?|stalled? as active. A delegate killed after `running` was written (kill
# -9, crash, machine sleep) leaves that word on disk forever, so the beacon saw perpetual "active work",
# never broke its loop, and kept beating for jobs that died weeks earlier — the immortal-beacon bug. The
# fix routes the status through _reconcile_status (READ-ONLY on this hot path), which re-derives the real
# state from pid + process-start liveness, so a dead job no longer reads as active.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d "${TMPDIR%/}/.test-immortal.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
export HOME="$TMP/home"
mkdir -p "$OSRC_HOME/jobs" "$OSRC_HOME/sessions" "$HOME"

set --
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
type -t _heartbeat_active_work >/dev/null || { echo "FAIL: _heartbeat_active_work not loaded"; exit 1; }
type -t _reconcile_status >/dev/null || { echo "FAIL: _reconcile_status not loaded"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

JOBS="$OSRC_HOME/jobs"

# A flatlined job: status says `running`, but its recorded delegate pid is provably dead and there is no
# live supervisor. This is exactly what a kill -9 / crash leaves on disk.
mkdir -p "$JOBS/deadjob"
echo running > "$JOBS/deadjob/status"
echo 999999  > "$JOBS/deadjob/pid"   # provably dead: ps works, no such process

# 1. reconcile no longer reports the corpse as active
st="$(OSRC_RECONCILE_READ_ONLY=1 _reconcile_status deadjob 2>/dev/null || echo '?')"
case "$st" in
  running|stalled\?|exploring\?|launching) bad "dead job still reconciles to an active status: '$st'" ;;
  *) ok "dead job reconciles to a terminal status ('$st'), not active" ;;
esac

# 2. THE bug: with only a flatlined job present, the beacon must see NO active work (so it can exit).
if _heartbeat_active_work; then
  bad "beacon counts a flatlined job as active work — the immortal beacon would keep beating forever"
else
  ok "beacon does not count a flatlined job as active work (immortal beacon fixed)"
fi

# 3. Regression guard the other direction: a genuinely LIVE job IS still counted (empty pid_start means
#    'legacy/unknown start' -> reconcile trusts the live kill -0, so this process stands in for a delegate).
mkdir -p "$JOBS/livejob"
echo running > "$JOBS/livejob/status"
echo "$$"    > "$JOBS/livejob/pid"
: > "$JOBS/livejob/pid_start"
if _heartbeat_active_work; then
  ok "beacon still counts a live job as active work (no false exit)"
else
  bad "beacon missed a live job — would exit while real work runs"
fi

# 4. Lost-update guard: a dead-pid job whose status was ALREADY written terminal (the supervisor won
#    the race and wrote `done`) must NOT be reconciled back to `interrupted`. Reconcile re-reads before
#    flipping, so a genuinely-finished job is never mislabeled failed by a late reconciler or gc pass.
mkdir -p "$JOBS/finishedjob"
echo done   > "$JOBS/finishedjob/status"   # supervisor already wrote the terminal verdict
echo 999999 > "$JOBS/finishedjob/pid"       # delegate pid is long dead
got="$(_reconcile_status finishedjob 2>/dev/null || echo '?')"
[ "$got" = "done" ] && ok "a dead-pid job already marked terminal stays 'done' (no interrupted clobber)" \
  || bad "reconcile clobbered a terminal 'done' with '$got' (lost update)"

# 5. The beacon ends with its last job, not a full cadence later. A 300 s cadence with the last job
#    finishing 1 s in: the beacon must tick once more (reporting the finish) and exit within seconds.
#    Claim/ownership/tick are stubbed; only the beacon's own wait loop is under test.
WORK="$TMP/work-flag"; : > "$WORK"; TICKS="$TMP/ticks"; : > "$TICKS"
(
  set +u   # the beacon's EXIT trap names its local token after the function has returned
  _pid_start_identity() { echo fixed; }; _heartbeat_claim() { return 0; }; _heartbeat_stop() { :; }
  _heartbeat_is_owner() { return 0; }; _heartbeat_tick() { echo t >> "$TICKS"; }
  _heartbeat_active_work() { [ -f "$WORK" ]; }; _OSRC_CALLER_EXIT=""
  OSRC_HEARTBEAT_CADENCE=300 OSRC_HEARTBEAT_IDLE_CHECK=1 _heartbeat_beacon tok
) &
bpid=$!
sleep 1; rm -f "$WORK"
i=0; while kill -0 "$bpid" 2>/dev/null && [ "$i" -lt 80 ]; do sleep 0.1; i=$((i+1)); done
if kill -0 "$bpid" 2>/dev/null; then
  bad "beacon still alive 8s after its last job finished (it sleeps the whole cadence)"
  pkill -P "$bpid" 2>/dev/null; kill "$bpid" 2>/dev/null
else
  [ "$(wc -l < "$TICKS" | tr -d ' ')" -ge 2 ] && ok "beacon ends within seconds of its last job, after one final tick" \
    || bad "beacon ended without a final tick (ticks=$(wc -l < "$TICKS" | tr -d ' '))"
fi
wait "$bpid" 2>/dev/null

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
