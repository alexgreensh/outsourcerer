#!/usr/bin/env bash
# test_heartbeat_single_instance.sh — the heartbeat beacon is single-instance, and the fleet
# reader is a single grouping pass that spawns no per-session jq for dead sessions.
#
# Root cause guarded:
#   (a) _heartbeat_start used to spawn a fresh beacon on EVERY call. Repeated `session start`/`bg`
#       calls each forked a new __heartbeat-beacon; three nested beacons were observed alive at
#       once, each running the (formerly O(sessions)) tick until it lost the election. The fix is
#       _heartbeat_leader_alive: a verified-live leader (owner.json + kill -0 + pid_start match)
#       makes _heartbeat_start no-op.
#   (b) The fleet reader used to run ~11 jq subprocesses PER session PER tick to extract fields one
#       at a time, and never filtered dead harnesses — so 150 dead sessions each cost ~11 jq
#       forever (~1,700 jq/tick, 94% CPU). The fix is a single jq grouping pass that emits one
#       row per session; the bash loop does a kill -0 (builtin) per session and drops dead ones
#       BEFORE any per-session jq, so a dead session costs nothing.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d "$PWD/.test-heartbeat-single.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
export HOME="$TMP/home"
mkdir -p "$OSRC_HOME/sessions" "$HOME"

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

dead_pid=999999
while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid - 1)); done

# ---------------------------------------------------------------------------
# 1. _heartbeat_leader_alive returns false when no leader exists, true for a verified-live leader,
#    and false for a dead leader (so a crashed beacon does not wedge every future start).
(
  set --
  . "$SRC" >/dev/null 2>&1
  _state_sync(){ return 0; }
  # Mock _pid_start_identity directly so both _heartbeat_claim and _heartbeat_leader_alive see
  # the same fixed identity (a PATH wrapper on ps would not reach _heartbeat_leader_alive, which
  # calls _pid_start_identity without a PATH prefix).
  _pid_start_identity(){ printf 'Thu Jul 31 01:02:03 2026\n'; }
  start="$(_pid_start_identity "$$")"
  # No leader yet -> not alive.
  _heartbeat_leader_alive && { echo "FAIL: leader reported alive with no owner.json"; exit 1; }
  # Claim leadership for $$ (live).
  _heartbeat_claim "$$" "$start" first "" >/dev/null || { echo "FAIL: could not claim leadership"; exit 1; }
  _heartbeat_leader_alive || { echo "FAIL: verified-live leader reported not alive"; exit 1; }
  # A dead leader (owner.json points at the dead pid) -> not alive, so a crashed beacon does not
  # wedge every future _heartbeat_start.
  owner="$OSRC_HEARTBEAT/leader/owner.json"
  jq -cn --argjson pid "$dead_pid" --arg pid_start "Thu Jul 31 01:02:03 2026" --arg token first \
    '{pid:$pid,pid_start:$pid_start,token:$token}' > "$owner"
  _heartbeat_leader_alive && { echo "FAIL: dead leader reported alive"; exit 1; }
  exit 0
) && ok "_heartbeat_leader_alive: false for no leader, true for live, false for dead" \
  || bad "_heartbeat_leader_alive misclassified leader liveness"

# ---------------------------------------------------------------------------
# 2. _heartbeat_start no-ops (does not fork a beacon) when a verified-live leader already exists.
#    We mock the executable so a real fork would leave a marker file; the assertion is that NO
#    marker appears when a live leader is already present.
(
  set --
  . "$SRC" >/dev/null 2>&1
  _state_sync(){ return 0; }
  _pid_start_identity(){ printf 'Thu Jul 31 01:02:03 2026\n'; }
  # Clean up any leader from the previous test block (subshells share OSRC_HOME).
  rm -rf "$OSRC_HEARTBEAT/leader" 2>/dev/null || true
  start="$(_pid_start_identity "$$")"
  _heartbeat_claim "$$" "$start" first "" >/dev/null || { echo "FAIL: could not claim leadership"; exit 1; }
  # Fake executable: if _heartbeat_start forks, it writes a marker.
  fake="$TMP/fake-beacon.sh"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
printf 'forked\n' > "$HB_FORK_MARKER"
SH
  chmod +x "$fake"
  export OSRC_HEARTBEAT_EXECUTABLE="$fake"
  export HB_FORK_MARKER="$TMP/forked"
  rm -f "$HB_FORK_MARKER"
  _heartbeat_start
  # Give the fork a beat to land.
  for _ in 1 2 3 4 5; do [ -e "$HB_FORK_MARKER" ] || sleep 0.1; done
  [ -e "$HB_FORK_MARKER" ] && { echo "FAIL: _heartbeat_start forked a beacon despite a live leader"; exit 1; }
  exit 0
) && ok "_heartbeat_start does not fork a beacon when a live leader already exists" \
  || bad "_heartbeat_start forked a duplicate beacon"

# ---------------------------------------------------------------------------
# 3. The fleet reader is a single grouping pass: it spawns ONE jq to build all rows (not N), and a
#    dead session costs ZERO per-session jq. We count jq invocations by shadowing jq with a
#    counter wrapper, then run the reader over a registry with many dead sessions and a few live
#    ones, and assert the jq count is small and constant in the dead-session count.
#
#    The old reader ran ~11 jq PER session. With 50 dead + 2 live sessions the old code would have
#    spawned ~572 jq; the new code spawns 1 (grouping) + 2 (one item-build per LIVE session) = 3.
#    Dead sessions contribute zero jq because the kill -0 filter drops them before any per-session
#    jq. We assert the count is well under the old baseline and does not grow with dead sessions.
(
  set --
  . "$SRC" >/dev/null 2>&1
  _pid_start_identity(){ printf 'Mon Jan 1 00:00:00 2024\n'; }
  tmux(){ return 1; }
  # Mock _session_model_observe to avoid adapter-specific jq; we are measuring the reader's own
  # jq cost, not the adapter's. The reader calls it once per LIVE session only.
  _session_model_observe(){ printf 'unknown\n'; }
  # Mock the external discovery helpers (file/tmux/process-table scans) to no-ops so their jq
  # calls don't pollute the count — we are measuring the REGISTRY READER's jq cost only.
  _fleet_recent_session_files(){ :; }
  _external_session_observation(){ printf '%s' "$1"; }
  # Shadow jq with a counter. The wrapper delegates to the real jq (resolved by absolute path so
  # the wrapper does not recurse) and increments a file counter on each call.
  real_jq="$(command -v jq)"
  jq_dir="$TMP/jq-wrap"
  mkdir -p "$jq_dir"
  cat > "$jq_dir/jq" <<SH
#!/usr/bin/env bash
printf 'x\n' >> "$TMP/jq-count"
exec "$real_jq" "\$@"
SH
  chmod +x "$jq_dir/jq"
  # Build a registry: 50 dead-harness sessions + 2 live-harness sessions.
  : > "$OSRC_SESSION_REGISTRY"
  i=0
  while [ "$i" -lt 50 ]; do
    "$real_jq" -cn --argjson i "$i" --argjson pid "$dead_pid" --arg ts "2026-08-08T00:00:0${i}Z" \
      '{schema_version:"1",event:"start",session_id:("dead-" + ($i|tostring)),provider:"cc",model:"sonnet",
        requested_model:"sonnet",resolved_model:"sonnet",model_generation:1,effort:"high",
        state:"running",receipt:"receipt",endpoint:"tmux:dead",harness_pid:$pid,
        pid_start:"Mon Jan 1 00:00:00 2024",owner:"managed",ts:$ts}' >> "$OSRC_SESSION_REGISTRY"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt 2 ]; do
    "$real_jq" -cn --argjson i "$i" --argjson live "$$" --arg ts "2026-08-08T00:00:0${i}Z" \
      '{schema_version:"1",event:"start",session_id:("live-" + ($i|tostring)),provider:"cc",model:"sonnet",
        requested_model:"sonnet",resolved_model:"sonnet",model_generation:1,effort:"high",
        state:"running",receipt:"receipt",endpoint:"tmux:live",harness_pid:$live,
        pid_start:"Mon Jan 1 00:00:00 2024",owner:"managed",ts:$ts}' >> "$OSRC_SESSION_REGISTRY"
    i=$((i + 1))
  done
  rm -f "$TMP/jq-count"
  items="$(PATH="$jq_dir:$PATH" _external_session_observations '[]' 2>/dev/null)"
  jq_calls="$(wc -l < "$TMP/jq-count" 2>/dev/null | tr -d ' ')"
  # _state_jsonl_read spawns 1 jq per line (52 lines = 52 jq) — that is a pre-existing shared cost,
  # not per-session extraction. The grouping pass is 1 jq. Per LIVE session: 1 item-build jq (2).
  # Total = 52 + 1 + 2 = 55. The OLD reader would have spawned 52 + 52*11 = 624 jq. Assert the
  # count is far below the old baseline and does NOT include per-session extraction for dead
  # sessions (if it did, it would be 52 + 52*11 = 624).
  [ "$jq_calls" -lt 100 ] || { echo "FAIL: reader spawned $jq_calls jq calls (old baseline ~624, expected <100)"; exit 1; }
  # And the dead sessions were dropped: only the 2 live rows are in items.
  live_rows="$(printf '%s' "$items" | "$real_jq" -r '[.[] | select(.session_id | startswith("live-"))] | length' 2>/dev/null)"
  [ "$live_rows" = 2 ] || { echo "FAIL: reader returned $live_rows live rows, expected 2"; exit 1; }
  dead_rows="$(printf '%s' "$items" | "$real_jq" -r '[.[] | select(.session_id | startswith("dead-"))] | length' 2>/dev/null)"
  [ "$dead_rows" = 0 ] || { echo "FAIL: reader returned $dead_rows dead rows, expected 0 (dropped)"; exit 1; }
  exit 0
) && ok "fleet reader is one grouping pass; dead sessions cost zero per-session jq" \
  || bad "fleet reader spawned excessive jq or did not drop dead sessions"

# ---------------------------------------------------------------------------
# 4. (BUG 2c) A live interactive session counts as active work, so the beacon does not exit on
#    the first tick when only interactive sessions are live. _heartbeat_active_work used to scan
#    ONLY $OSRC_JOBS for bg/fanout job statuses; interactive `session start` sessions are not jobs
#    and were invisible, so the beacon started, counted zero work, broke, and exited immediately.
#    This is critical because interactive is now the mandatory mode for delegates (c19dd73).
(
  set --
  . "$SRC" >/dev/null 2>&1
  _pid_start_identity(){ printf 'Mon Jan 1 00:00:00 2024\n'; }
  tmux(){ return 1; }
  # No jobs directory at all — the interactive-only case.
  rm -rf "$OSRC_JOBS" 2>/dev/null || true
  : > "$OSRC_SESSION_REGISTRY"
  # No live sessions -> active_work must return false (beacon should exit when nothing is live).
  _heartbeat_active_work && { echo "FAIL: active_work returned true with no jobs and no sessions"; exit 1; }
  # One live interactive session (harness_pid = $$) -> active_work must return true.
  jq -cn --argjson live "$$" --arg ts "2020-01-01T00:00:00Z" \
    '{schema_version:"1",event:"start",session_id:"interactive-1",provider:"cc",model:"sonnet",
      requested_model:"sonnet",resolved_model:"sonnet",model_generation:1,effort:"high",
      state:"running",receipt:"receipt",endpoint:"tmux:interactive-1",harness_pid:$live,
      pid_start:"Mon Jan 1 00:00:00 2024",owner:"managed",ts:$ts}' >> "$OSRC_SESSION_REGISTRY"
  _heartbeat_active_work || { echo "FAIL: active_work returned false with a live interactive session"; exit 1; }
  # A dead interactive session (harness_pid = dead_pid) -> active_work must return false.
  : > "$OSRC_SESSION_REGISTRY"
  jq -cn --argjson pid "$dead_pid" --arg ts "2020-01-01T00:00:00Z" \
    '{schema_version:"1",event:"start",session_id:"interactive-dead",provider:"cc",model:"sonnet",
      requested_model:"sonnet",resolved_model:"sonnet",model_generation:1,effort:"high",
      state:"running",receipt:"receipt",endpoint:"tmux:interactive-dead",harness_pid:$pid,
      pid_start:"Mon Jan 1 00:00:00 2024",owner:"managed",ts:$ts}' >> "$OSRC_SESSION_REGISTRY"
  _heartbeat_active_work && { echo "FAIL: active_work returned true with only a dead session"; exit 1; }
  # An ended session (event=end) -> active_work must return false even if the pid is somehow live.
  : > "$OSRC_SESSION_REGISTRY"
  jq -cn --argjson live "$$" --arg ts "2020-01-01T00:00:00Z" \
    '{schema_version:"1",event:"end",session_id:"interactive-ended",provider:"cc",model:"sonnet",
      requested_model:"sonnet",resolved_model:"sonnet",model_generation:1,effort:"high",
      state:"ended",receipt:"stop",endpoint:"tmux:interactive-ended",harness_pid:$live,
      pid_start:"Mon Jan 1 00:00:00 2024",owner:"managed",ts:$ts}' >> "$OSRC_SESSION_REGISTRY"
  _heartbeat_active_work && { echo "FAIL: active_work returned true for an ended session"; exit 1; }
  # A session with no harness_pid (unprovably dead) -> active_work must return true (honest unknown).
  : > "$OSRC_SESSION_REGISTRY"
  jq -cn --arg ts "2020-01-01T00:00:00Z" \
    '{schema_version:"1",event:"start",session_id:"interactive-nopid",provider:"cc",model:"sonnet",
      requested_model:"sonnet",resolved_model:"sonnet",model_generation:1,effort:"high",
      state:"running",receipt:"receipt",endpoint:"tmux:interactive-nopid",harness_pid:null,
      pid_start:null,owner:"managed",ts:$ts}' >> "$OSRC_SESSION_REGISTRY"
  _heartbeat_active_work || { echo "FAIL: active_work returned false for an unprovably-dead session (should keep beacon alive)"; exit 1; }
  exit 0
) && ok "active_work counts live interactive sessions; exits on dead/ended/empty" \
  || bad "active_work is blind to interactive sessions or does not exit when nothing is live"

# ---------------------------------------------------------------------------
# 5. (BUG 2d) A stale leader claim (dead pid in owner.json) is evicted by _heartbeat_start, while
#    a live leader claim is respected. The beacon is spawned with nohup but can die when its
#    parent shell exits, leaving owner.json holding a dead pid that wedges future arming.
(
  set --
  . "$SRC" >/dev/null 2>&1
  _state_sync(){ return 0; }
  _pid_start_identity(){ printf 'Thu Jul 31 01:02:03 2026\n'; }
  rm -rf "$OSRC_HEARTBEAT/leader" 2>/dev/null || true
  # Plant a stale claim with a dead pid.
  owner="$OSRC_HEARTBEAT/leader/owner.json"
  mkdir -p "$(dirname "$owner")"
  jq -cn --argjson pid "$dead_pid" --arg pid_start "Thu Jul 31 01:02:03 2026" --arg token stale \
    '{pid:$pid,pid_start:$pid_start,token:$token}' > "$owner"
  # _heartbeat_leader_alive must return false (dead pid).
  _heartbeat_leader_alive && { echo "FAIL: leader reported alive for a dead pid"; exit 1; }
  # _heartbeat_leader_evict_stale must remove the stale claim.
  _heartbeat_leader_evict_stale
  [ -f "$owner" ] && { echo "FAIL: stale leader claim was not evicted"; exit 1; }
  # Now plant a LIVE claim ($$) and verify it is NOT evicted.
  start="$(_pid_start_identity "$$")"
  _heartbeat_claim "$$" "$start" live-token "" >/dev/null || { echo "FAIL: could not claim leadership"; exit 1; }
  _heartbeat_leader_evict_stale
  [ -f "$owner" ] || { echo "FAIL: live leader claim was evicted"; exit 1; }
  # And _heartbeat_leader_alive must still return true for the live claim.
  _heartbeat_leader_alive || { echo "FAIL: live leader reported not alive after eviction check"; exit 1; }
  exit 0
) && ok "stale leader claim evicted (dead pid); live leader respected" \
  || bad "stale leader claim not evicted or live leader was evicted"

# LOW: after spawning, an owner PID whose start identity cannot be read is unknown, not verified
# live. _heartbeat_start must fail closed instead of accepting the unreadable identity.
(
  set --
  export OSRC_HOME="$TMP/unreadable-owner-home" OSRC_HEARTBEAT="$TMP/unreadable-owner-home/heartbeat" OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  _pid_start_identity() {
    if [ "$1" = "$$" ]; then printf 'Mon Jan 1 00:00:00 2024\n'; return 0; fi
    return 1
  }
  _heartbeat_leader_alive() { return 1; }
  _heartbeat_leader_evict_stale() { return 0; }
  fake="$TMP/unreadable-beacon"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
mkdir -p "$OSRC_HEARTBEAT/leader"
printf '%s\n' "$$" > "$HB_CHILD_PID"
jq -cn --argjson pid "$$" --arg start "Mon Jan 1 00:00:00 2024" '{pid:$pid,pid_start:$start,token:"unreadable"}' > "$OSRC_HEARTBEAT/leader/owner.json"
sleep 5
SH
  chmod +x "$fake"
  export OSRC_HEARTBEAT_EXECUTABLE="$fake" OSRC_HEARTBEAT_START_TIMEOUT=1 HB_CHILD_PID="$TMP/unreadable-child-pid"
  set +e
  _heartbeat_start >/dev/null 2>&1
  rc=$?
  set -e
  child="$(cat "$HB_CHILD_PID" 2>/dev/null || true)"
  [ -n "$child" ] && kill "$child" 2>/dev/null || true
  [ "$rc" -ne 0 ]
) && ok "heartbeat spawn refuses an owner with unreadable pid_start" \
  || bad "heartbeat spawn accepted an unreadable owner identity"

# The companion guarantee: an owner whose start identity IS readable but DIFFERENT from the recorded
# one is a reused pid, never our beacon. Refuse it and kill the child we spawned.
(
  set --
  export OSRC_HOME="$TMP/reused-owner-home" OSRC_HEARTBEAT="$TMP/reused-owner-home/heartbeat" OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  _pid_start_identity() {
    if [ "$1" = "$$" ]; then printf 'Mon Jan 1 00:00:00 2024\n'; return 0; fi
    printf 'Tue Feb 2 00:00:00 2025\n'; return 0
  }
  _heartbeat_leader_alive() { return 1; }
  _heartbeat_leader_evict_stale() { return 0; }
  fake="$TMP/reused-beacon"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
mkdir -p "$OSRC_HEARTBEAT/leader"
printf '%s\n' "$$" > "$HB_CHILD_PID"
jq -cn --argjson pid "$$" --arg start "Mon Jan 1 00:00:00 2024" '{pid:$pid,pid_start:$start,token:"reused"}' > "$OSRC_HEARTBEAT/leader/owner.json"
sleep 5
SH
  chmod +x "$fake"
  export OSRC_HEARTBEAT_EXECUTABLE="$fake" OSRC_HEARTBEAT_START_TIMEOUT=1 HB_CHILD_PID="$TMP/reused-child-pid"
  set +e
  _heartbeat_start >/dev/null 2>&1
  rc=$?
  set -e
  child="$(cat "$HB_CHILD_PID" 2>/dev/null || true)"
  sleep 0.3
  alive=0; [ -n "$child" ] && kill -0 "$child" 2>/dev/null && alive=1
  [ -n "$child" ] && kill "$child" 2>/dev/null || true
  [ "$rc" -ne 0 ] && [ "$alive" -eq 0 ]
) && ok "heartbeat spawn refuses an owner whose readable identity differs (pid reuse) and kills the child" \
  || bad "heartbeat spawn accepted a reused pid as its beacon, or left the child running"

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
