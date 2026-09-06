#!/usr/bin/env bash
# test_heartbeat_stale_alarm.sh — staleness is ALARMED, not just displayed (SPEC
# heartbeat-liveness C): a supervised session whose status is stale past the stall window is
# surfaced as a wake event, once per (session, state) while unacked, and re-alarms after ack if
# still stale on a later generation.
#
# What is pinned here:
#   1. One tick over a stale fixture -> the wake queue gains an unresponsive? event naming the
#      session, with the evidence string in task_summary.
#   2. Re-running the wake pass with no state change -> NO duplicate unacked event with the same
#      generation-independent heartbeat.stale.* id.
#   3. Ack the event, bump the generation, tick again while still stale -> the alarm re-fires
#      (acts until seen, not once-ever).
#   4. A fresh session (no stale signature) -> no stale wake.
# 5. Quiescent/frozen-generation fleet (hardening): the generation is content-derived, so a
#      fleet whose only member is stuck NEVER changes it. After ack, the alarm must re-fire on
#      the very next tick at the SAME frozen generation -- not wait for a content change that
#      never comes -- and stay a single unacked event across repeated identical ticks.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d "$PWD/.test-heartbeat-stale.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
export HOME="$TMP/home"
mkdir -p "$OSRC_HOME/sessions" "$HOME"

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

STALE_ID="heartbeat.stale.sess-stale-1.unresponsive_"
EVIDENCE="CC status=working unchanged for 700s; long turn or approval wall"

# Fixture generation is read at tick time so a test can bump it without re-sourcing.
FIXT_GEN="$TMP/generation"
printf 'gen-stale-1\n' > "$FIXT_GEN"

queue_ids(){ _state_jsonl_read "$OSRC_WAKE_QUEUE" 2>/dev/null | jq -r '.event_id // empty'; }
ack_ids(){ _state_jsonl_read "$OSRC_WAKE_ACK" 2>/dev/null | jq -r '.event_id // empty'; }
count_id(){ printf '%s\n' "$1" | grep -Fx "$2" | wc -l | tr -d ' '; }
# Unacked = queue lines carrying the id MINUS the acked ones (comm on the multiset difference).
unacked_count(){
  local id="$1"
  queue_ids | grep -Fx "$id" | sort > "$TMP/.unacked.q.$$"
  ack_ids | grep -Fx "$id" | sort > "$TMP/.unacked.a.$$"
  comm -23 "$TMP/.unacked.q.$$" "$TMP/.unacked.a.$$" | wc -l | tr -d ' '
  rm -f "$TMP/.unacked.q.$$" "$TMP/.unacked.a.$$"
}

(
  set --
  # A fresh state home per block (blocks share nothing), and an UNWRITABLE sink so
  # _wake_consume cannot ack events out from under the assertions — a stale alarm must STAY
  # unacked/queued, which is exactly the state the dedup is defined over.
  export OSRC_HOME="$TMP/state-alarm" OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  mkdir -p "$OSRC_HOME/sessions"
  . "$SRC" >/dev/null 2>&1
  export OSRC_HEARTBEAT_SINK="$TMP/missing/sink"
  _state_sync(){ return 0; }
  # The snapshot is the fixture: one managed session parked past the stall window. Mocking the
  # collector is equivalent to a real registry row with an old status mtime, but deterministic.
  _fleet_snapshot_collect(){
    jq -cn --arg gen "$(cat "$FIXT_GEN")" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ev "$EVIDENCE" \
      '{schema_version:"1",generation:$gen,captured_at:$ts,items:[{schema_version:"1",
        session_id:"sess-stale-1",owner:"managed",harness:"cc",lane:"cc",requested_model:"m",
        observed_model:"m",effort:"high",endpoint:"tmux:stale",harness_pid:123456,pid_start:null,
        started_at:null,state:"unresponsive?",state_evidence:$ev,composer_state:"unknown",
        claim:null,task_summary:"sess-stale-1"}]}'
  }
  _heartbeat_tick >/dev/null 2>&1
  # 1. The stale session is alarmed, named, with the WHY in task_summary.
  [ "$(unacked_count "$STALE_ID")" -eq 1 ] || { echo "FAIL: expected exactly 1 unacked $STALE_ID, got $(unacked_count "$STALE_ID")"; exit 1; }
  ev="$(_state_jsonl_read "$OSRC_WAKE_QUEUE" 2>/dev/null | jq -r 'select(.event_id=="'"$STALE_ID"'") | .task_summary')"
  printf '%s' "$ev" | grep -qF 'unchanged for 700s' || { echo "FAIL: task_summary lacks the evidence: $ev"; exit 1; }
  sid="$(_state_jsonl_read "$OSRC_WAKE_QUEUE" 2>/dev/null | jq -r 'select(.event_id=="'"$STALE_ID"'") | .session_id')"
  [ "$sid" = "sess-stale-1" ] || { echo "FAIL: event does not name the session: $sid"; exit 1; }
  # 2. Re-run the wake pass (cursor reset, SAME generation, no state change): no duplicate
  #    unacked event with the same id.
  _heartbeat_cursor_write wakes ""
  _heartbeat_tick >/dev/null 2>&1
  [ "$(count_id "$(queue_ids)" "$STALE_ID")" -eq 1 ] || { echo "FAIL: duplicate queued event with $STALE_ID (count $(count_id "$(queue_ids)" "$STALE_ID"))"; exit 1; }
  [ "$(unacked_count "$STALE_ID")" -eq 1 ] || { echo "FAIL: duplicate unacked stale alarm"; exit 1; }
  # 3. Ack the event, bump the generation, tick again while still stale: the alarm re-fires.
  _wake_ack "$STALE_ID" >/dev/null 2>&1
  printf 'gen-stale-2\n' > "$FIXT_GEN"
  _heartbeat_tick >/dev/null 2>&1
  [ "$(unacked_count "$STALE_ID")" -eq 1 ] || { echo "FAIL: stale alarm did not re-fire after ack on a new generation"; exit 1; }
  # The re-fire CONSUMES the ack (acks are per-id): the fresh alarm must be deliverable, not
  # trapped behind the delivered copies of the same generation-independent id (hardening).
  [ "$(count_id "$(ack_ids)" "$STALE_ID")" -eq 0 ] || { echo "FAIL: the re-fired alarm is still suppressed by the old ack record"; exit 1; }
  exit 0
) && ok "stale session alarms once, dedupes unacked, re-fires after ack" \
  || bad "stale alarm lifecycle broken"

# ---------------------------------------------------------------------------
# 4. A fresh session (working, no stale signature) -> no stale wake. Also: a blocked? stale
#    signature gets the same generation-independent treatment.
(
  set --
  # Fresh state home for this block: the previous block's wake queue must not leak in.
  export OSRC_HOME="$TMP/state-fresh" OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  mkdir -p "$OSRC_HOME/sessions"
  . "$SRC" >/dev/null 2>&1
  export OSRC_HEARTBEAT_SINK="$TMP/missing/sink"
  _state_sync(){ return 0; }
  _fleet_snapshot_collect(){
    jq -cn --arg gen "gen-fresh" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{schema_version:"1",generation:$gen,captured_at:$ts,items:[{schema_version:"1",
        session_id:"sess-fresh-1",owner:"managed",harness:"cc",lane:"cc",requested_model:"m",
        observed_model:"m",effort:"high",endpoint:"tmux:fresh",harness_pid:123456,pid_start:null,
        started_at:null,state:"working",state_evidence:"CC status=working, updated 5s ago",
        composer_state:"unknown",claim:null,task_summary:"sess-fresh-1"}]}'
  }
  _heartbeat_tick >/dev/null 2>&1
  [ -z "$(queue_ids | grep 'heartbeat.stale.')" ] || { echo "FAIL: fresh session produced a stale wake: $(queue_ids | grep 'heartbeat.stale.')"; exit 1; }
  # A blocked? stale signature (waiting_for fixture) also alarms, once, with its own id.
  _fleet_snapshot_collect(){
    jq -cn --arg gen "gen-blocked" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{schema_version:"1",generation:$gen,captured_at:$ts,items:[{schema_version:"1",
        session_id:"sess-wait-1",owner:"managed",harness:"cc",lane:"cc",requested_model:"m",
        observed_model:"m",effort:"high",endpoint:"tmux:wait",harness_pid:123456,pid_start:null,
        started_at:null,state:"blocked?",state_evidence:"CC status=waiting: tool approval",
        composer_state:"unknown",claim:null,task_summary:"sess-wait-1"}]}'
  }
  _heartbeat_tick >/dev/null 2>&1
  [ "$(unacked_count "heartbeat.stale.sess-wait-1.blocked_")" -eq 1 ] \
    || { echo "FAIL: blocked? fixture did not alarm exactly once"; exit 1; }
  exit 0
) && ok "fresh session stays silent; blocked? signature alarms under its own id" \
  || bad "stale wake scoping broken (fresh alarm or blocked? path)"

# ---------------------------------------------------------------------------
# 5. Quiescent/frozen-generation fleet (hardening): one wedged session, nothing else, so the
#    content-derived generation is FROZEN at the same value on every tick. After the alarm is
#    acked, the next tick runs at the SAME generation (wake cursor == generation) and the alarm
#    must still re-fire. The old cursor-gated pass skipped the whole wake loop once the cursor
#    matched, so the acked alarm never came back -- the session stayed parked and silent forever.
(
  set --
  # Fresh state home: this block shares nothing with the earlier ones.
  export OSRC_HOME="$TMP/state-frozen" OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  mkdir -p "$OSRC_HOME/sessions"
  . "$SRC" >/dev/null 2>&1
  export OSRC_HEARTBEAT_SINK="$TMP/missing/sink"
  _state_sync(){ return 0; }
  # The fixture is bit-identical every call except captured_at (which is excluded from the
  # canonical hash by design) -- exactly the "maximally stuck fleet" the fix targets.
  _fleet_snapshot_collect(){
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ev "$EVIDENCE" \
      '{schema_version:"1",generation:"gen-frozen",captured_at:$ts,items:[{schema_version:"1",
        session_id:"sess-stale-1",owner:"managed",harness:"cc",lane:"cc",requested_model:"m",
        observed_model:"m",effort:"high",endpoint:"tmux:stale",harness_pid:123456,pid_start:null,
        started_at:null,state:"unresponsive?",state_evidence:$ev,composer_state:"unknown",
        claim:null,task_summary:"sess-stale-1"}]}'
  }
  _heartbeat_tick >/dev/null 2>&1
  [ "$(unacked_count "$STALE_ID")" -eq 1 ] || { echo "FAIL: frozen fleet did not alarm: $(unacked_count "$STALE_ID")"; exit 1; }
  _wake_ack "$STALE_ID" >/dev/null 2>&1
  # Tick N+1 at the SAME frozen generation, nothing changed: the alarm must re-fire.
  _heartbeat_tick >/dev/null 2>&1
  [ "$(unacked_count "$STALE_ID")" -eq 1 ] || { echo "FAIL: acked stale alarm did NOT re-fire at the same frozen generation (count $(unacked_count "$STALE_ID"))"; exit 1; }
  # And while unacked it stays exactly ONE logical event across further identical ticks: no
  # duplicate appends, and the delivered copies were retired by the re-arm (hardening).
  _heartbeat_tick >/dev/null 2>&1
  _heartbeat_tick >/dev/null 2>&1
  [ "$(unacked_count "$STALE_ID")" -eq 1 ] || { echo "FAIL: duplicate stale alarms across frozen-generation ticks (count $(unacked_count "$STALE_ID"))"; exit 1; }
  [ "$(count_id "$(queue_ids)" "$STALE_ID")" -eq 1 ] || { echo "FAIL: queue holds $(count_id "$(queue_ids)" "$STALE_ID") copies of the stale id (expected exactly 1)"; exit 1; }
  exit 0
) && ok "frozen-generation fleet: acked stale alarm re-fires on the next tick, deduped while unacked" \
  || bad "stale alarm does not re-fire on a quiescent fleet (F2)"

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
