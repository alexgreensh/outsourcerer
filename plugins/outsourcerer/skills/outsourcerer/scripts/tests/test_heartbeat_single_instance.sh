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

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
