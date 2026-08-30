#!/usr/bin/env bash
# test_session_registry_end.sh — session lifecycle: end events, dead-harness reap, crash-safe
# compaction, and the dead-pid filter in the fleet reader.
#
# Root cause guarded: registry.jsonl only ever held `start`/`effort` events. Nothing wrote an `end`
# on any teardown path, so 150 provably-dead sessions were counted as live forever ("+149 more"
# noise) and the beacon burned a core churning jq over them. This suite proves:
#   1. `session stop` writes an `end` event (reason stop) and is idempotent on a double-stop.
#   2. `_session_registry_reap_dead` writes an `end` (reason crash-reap) for a harness whose pid is
#      provably gone — the catch-all for natural exit / external kill / watchdog / cancel / reboot.
#   3. The fleet reader DROPS a session whose harness_pid is provably dead (a dead pid is ended,
#      not "unknown"), and KEEPS a session whose harness is live.
#   4. `_session_registry_compact` keeps the last event per live session and drops ended sessions,
#      and never loses a live session's record. Threshold-gated (no-op below it).
#   5. `_wake_queue_compact` keeps every unacked wake and clears the ack log; an unacked wake is
#      never lost.
#   6. `_heartbeat_log_rotate` caps the log to the last N lines and never loses a kept line.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d "$PWD/.test-registry-end.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
export HOME="$TMP/home"
mkdir -p "$OSRC_HOME/sessions" "$HOME"

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

# A dead pid we can rely on across the suite.
dead_pid=999999
while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid - 1)); done

# ---------------------------------------------------------------------------
# 1. `session stop` writes an `end` event (reason stop) and is idempotent.
# We exercise _session_registry_end directly (the helper session stop calls) so the test does not
# depend on tmux/winpty being installed. SESSION_NAME is the contract: _session_registry_end reads
# it to find the session's last record.
(
  set --
  . "$SRC" >/dev/null 2>&1
  _pid_start_identity(){ printf 'Mon Jan 1 00:00:00 2024\n'; }
  : > "$OSRC_SESSION_REGISTRY"
  SESSION_NAME="stop-me"
  _session_registry_append start cc sonnet high running receipt sonnet 1 >/dev/null
  end_before="$(wc -l < "$OSRC_SESSION_REGISTRY" | tr -d ' ')"
  _session_registry_end stop >/dev/null
  end_after="$(wc -l < "$OSRC_SESSION_REGISTRY" | tr -d ' ')"
  [ "$end_after" -eq $((end_before + 1)) ] || { echo "FAIL: stop did not append an end event"; exit 1; }
  last_event="$(jq -rs 'sort_by(.ts // "") | last | .event // empty' "$OSRC_SESSION_REGISTRY" 2>/dev/null)"
  [ "$last_event" = end ] || { echo "FAIL: last event is '$last_event', expected end"; exit 1; }
  last_receipt="$(jq -rs 'sort_by(.ts // "") | last | .receipt // empty' "$OSRC_SESSION_REGISTRY" 2>/dev/null)"
  [ "$last_receipt" = stop ] || { echo "FAIL: end receipt is '$last_receipt', expected stop"; exit 1; }
  # Idempotent: a second stop must NOT stack another end event.
  _session_registry_end stop >/dev/null
  end_again="$(wc -l < "$OSRC_SESSION_REGISTRY" | tr -d ' ')"
  [ "$end_again" -eq "$end_after" ] || { echo "FAIL: double-stop stacked a second end event"; exit 1; }
  exit 0
) && ok "session stop writes an idempotent end event (reason stop)" \
  || bad "session stop did not write a correct/idempotent end event"

# ---------------------------------------------------------------------------
# 2. _session_registry_reap_dead writes an end (reason crash-reap) for a provably-dead harness,
#    and leaves a live harness alone.
(
  set --
  . "$SRC" >/dev/null 2>&1
  _pid_start_identity(){ printf 'Mon Jan 1 00:00:00 2024\n'; }
  : > "$OSRC_SESSION_REGISTRY"
  # Two sessions: one with a dead harness_pid, one with a live one ($$).
  # Write the dead session directly (not via _session_registry_append, which would record the
  # live $$ as harness_pid) with a FUTURE timestamp so it is the last event for that session.
  jq -cn --argjson pid "$dead_pid" --arg ts "2020-01-01T00:00:01Z" \
    '{schema_version:"1",event:"start",session_id:"reap-dead",provider:"cc",model:"sonnet",
      requested_model:"sonnet",resolved_model:"sonnet",model_generation:1,effort:"high",
      state:"running",receipt:"receipt",endpoint:"tmux:reap-dead",harness_pid:$pid,
      pid_start:"Mon Jan 1 00:00:00 2024",owner:"managed",ts:$ts}' >> "$OSRC_SESSION_REGISTRY"
  SESSION_NAME="reap-live"
  _session_registry_append start cc sonnet high running receipt sonnet 1 >/dev/null
  before_live="$(wc -l < "$OSRC_SESSION_REGISTRY" | tr -d ' ')"
  _session_registry_reap_dead >/dev/null
  after_live="$(wc -l < "$OSRC_SESSION_REGISTRY" | tr -d ' ')"
  [ "$after_live" -eq $((before_live + 1)) ] || { echo "FAIL: reap did not append exactly one end (before=$before_live after=$after_live)"; exit 1; }
  dead_last="$(jq -rs '[.[] | select(.session_id=="reap-dead")] | sort_by(.ts // "") | last | .receipt // empty' "$OSRC_SESSION_REGISTRY" 2>/dev/null)"
  [ "$dead_last" = crash-reap ] || { echo "FAIL: reap-dead last receipt is '$dead_last', expected crash-reap"; exit 1; }
  live_last="$(jq -rs '[.[] | select(.session_id=="reap-live")] | sort_by(.ts // "") | last | .event // empty' "$OSRC_SESSION_REGISTRY" 2>/dev/null)"
  [ "$live_last" = start ] || { echo "FAIL: reap-live was reaped (last event='$live_last'), expected start"; exit 1; }
  # Idempotent: a second reap must not append another end for the already-ended session.
  _session_registry_reap_dead >/dev/null
  after_again="$(wc -l < "$OSRC_SESSION_REGISTRY" | tr -d ' ')"
  [ "$after_again" -eq "$after_live" ] || { echo "FAIL: double-reap stacked a second end event"; exit 1; }
  exit 0
) && ok "reap writes crash-reap for a dead harness and leaves a live one alone (idempotent)" \
  || bad "reap did not correctly end a dead harness / spare a live one"

# F4: the pane_pid is the shell, not the delegate engine. If the engine child exits while that shell
# remains alive, supervision must use the recorded engine identity and append crash-reap.
(
  set --
  export OSRC_HOME="$TMP/engine-child-home" OSRC_SOURCED=1
  mkdir -p "$OSRC_HOME/sessions"
  . "$SRC" >/dev/null 2>&1
  SESSION_NAME=engine-child
  ENGINE_FILE="$TMP/engine-child-pid"
  bash -c 'sleep 30 & printf "%s\n" "$!" > "$1"; wait' _ "$ENGINE_FILE" &
  PANE_PID=$!
  ENGINE_PID=""
  while [ ! -s "$ENGINE_FILE" ] && [ -n "$PANE_PID" ]; do sleep 0.1; done
  ENGINE_PID="$(cat "$ENGINE_FILE" 2>/dev/null || true)"
  trap 'kill "$PANE_PID" "$ENGINE_PID" 2>/dev/null || true; wait "$PANE_PID" 2>/dev/null || true' EXIT
  tmux() {
    case "${1:-}" in
      display-message) printf '%s\n' "$PANE_PID" ;;
      *) return 0 ;;
    esac
  }
  _session_registry_append start devin glm high running receipt glm 1 >/dev/null 2>&1 || exit 1
  recorded="$(jq -rs 'last' "$OSRC_SESSION_REGISTRY")"
  [ "$(printf '%s' "$recorded" | jq -r '.harness_pid')" = "$PANE_PID" ] || exit 1
  [ "$(printf '%s' "$recorded" | jq -r '.engine_pid')" = "$ENGINE_PID" ] || exit 1
  kill "$ENGINE_PID" 2>/dev/null || true
  wait "$ENGINE_PID" 2>/dev/null || true
  _session_registry_reap_dead >/dev/null 2>&1
  last="$(jq -rs 'last' "$OSRC_SESSION_REGISTRY")"
  [ "$(printf '%s' "$last" | jq -r '.event')" = end ] || exit 1
  [ "$(printf '%s' "$last" | jq -r '.receipt')" = crash-reap ]
) && ok "engine-child exit is reaped even while the pane shell remains alive" \
  || bad "reaper trusted the live pane shell instead of the dead engine child"

# ---------------------------------------------------------------------------
# 3. The fleet reader DROPS a session whose harness_pid is provably dead, and KEEPS a live one.
(
  set --
  . "$SRC" >/dev/null 2>&1
  _pid_start_identity(){ printf 'Mon Jan 1 00:00:00 2024\n'; }
  tmux(){ return 1; }
  # Dead-harness session: must be dropped by the reader.
  jq -cn --argjson pid "$dead_pid" --arg ts "2026-08-08T00:00:00Z" \
    '{schema_version:"1",event:"start",session_id:"drop-dead",provider:"cc",model:"sonnet",
      requested_model:"sonnet",resolved_model:"sonnet",model_generation:1,effort:"high",
      state:"running",receipt:"receipt",endpoint:"tmux:drop-dead",harness_pid:$pid,
      pid_start:"Mon Jan 1 00:00:00 2024",owner:"managed",ts:$ts}' > "$OSRC_SESSION_REGISTRY"
  items="$(_external_session_observations '[]' 2>/dev/null)"
  has_dead="$(printf '%s' "$items" | jq -r '[.[] | select(.session_id=="drop-dead")] | length' 2>/dev/null)"
  [ "$has_dead" = 0 ] || { echo "FAIL: reader kept a dead-harness session ($has_dead rows)"; exit 1; }
  # Live-harness session: must be kept.
  jq -cn --argjson live "$$" --arg ts "2026-08-08T00:00:00Z" \
    '{schema_version:"1",event:"start",session_id:"keep-live",provider:"cc",model:"sonnet",
      requested_model:"sonnet",resolved_model:"sonnet",model_generation:1,effort:"high",
      state:"running",receipt:"receipt",endpoint:"tmux:keep-live",harness_pid:$live,
      pid_start:"Mon Jan 1 00:00:00 2024",owner:"managed",ts:$ts}' > "$OSRC_SESSION_REGISTRY"
  items="$(_external_session_observations '[]' 2>/dev/null)"
  has_live="$(printf '%s' "$items" | jq -r '[.[] | select(.session_id=="keep-live")] | length' 2>/dev/null)"
  [ "$has_live" = 1 ] || { echo "FAIL: reader dropped a live-harness session ($has_live rows)"; exit 1; }
  exit 0
) && ok "fleet reader drops a dead-harness session and keeps a live one" \
  || bad "fleet reader did not filter dead harnesses correctly"

# ---------------------------------------------------------------------------
# 4. _session_registry_compact keeps the last event per live session, drops ended sessions, never
#    loses a live session, and is threshold-gated (no-op below the threshold).
(
  set --
  . "$SRC" >/dev/null 2>&1
  _pid_start_identity(){ printf 'Mon Jan 1 00:00:00 2024\n'; }
  # Build a registry with: one live session (start), one ended session (start+end), and enough
  # extra lines to cross the default 200-line threshold.
  : > "$OSRC_SESSION_REGISTRY"
  SESSION_NAME="compact-live"
  _session_registry_append start cc sonnet high running receipt sonnet 1 >/dev/null
  SESSION_NAME="compact-ended"
  _session_registry_append start cc sonnet high running receipt sonnet 1 >/dev/null
  SESSION_NAME="compact-ended"; _session_registry_end stop >/dev/null
  # Pad with start events for a third live session to cross the threshold without affecting the
  # two sessions we assert on.
  SESSION_NAME="compact-pad"
  _session_registry_append start cc sonnet high running receipt sonnet 1 >/dev/null
  i=0
  while [ "$i" -lt 210 ]; do
    jq -cn --argjson i "$i" --arg ts "2026-08-08T00:00:0${i}Z" \
      '{schema_version:"1",event:"effort",session_id:"compact-pad",provider:"cc",model:"sonnet",
        requested_model:"sonnet",resolved_model:"sonnet",model_generation:1,effort:"high",
        state:"running",receipt:"receipt",endpoint:"tmux:compact-pad",harness_pid:1,
        pid_start:"Mon Jan 1 00:00:00 2024",owner:"managed",ts:$ts}' >> "$OSRC_SESSION_REGISTRY"
    i=$((i + 1))
  done
  before="$(wc -l < "$OSRC_SESSION_REGISTRY" | tr -d ' ')"
  [ "$before" -gt 200 ] || { echo "FAIL: setup did not cross the compact threshold (before=$before)"; exit 1; }
  _session_registry_compact
  after="$(wc -l < "$OSRC_SESSION_REGISTRY" | tr -d ' ')"
  # compact-live (1) + compact-pad (1) = 2 lines. compact-ended must be gone.
  [ "$after" -eq 2 ] || { echo "FAIL: compact left $after lines, expected 2 (live+pad, ended dropped)"; exit 1; }
  has_live="$(jq -rs '[.[] | select(.session_id=="compact-live")] | length' "$OSRC_SESSION_REGISTRY" 2>/dev/null)"
  [ "$has_live" = 1 ] || { echo "FAIL: compact lost the live session (rows=$has_live)"; exit 1; }
  has_ended="$(jq -rs '[.[] | select(.session_id=="compact-ended")] | length' "$OSRC_SESSION_REGISTRY" 2>/dev/null)"
  [ "$has_ended" = 0 ] || { echo "FAIL: compact kept an ended session (rows=$has_ended)"; exit 1; }
  # Threshold-gated: a small registry must NOT be rewritten.
  : > "$OSRC_SESSION_REGISTRY"
  SESSION_NAME="tiny"; _session_registry_append start cc sonnet high running receipt sonnet 1 >/dev/null
  tiny_before="$(wc -l < "$OSRC_SESSION_REGISTRY" | tr -d ' ')"
  _session_registry_compact
  tiny_after="$(wc -l < "$OSRC_SESSION_REGISTRY" | tr -d ' ')"
  [ "$tiny_after" -eq "$tiny_before" ] || { echo "FAIL: compact rewrote a sub-threshold registry ($tiny_before -> $tiny_after)"; exit 1; }
  exit 0
) && ok "registry compact keeps last event per live session, drops ended, threshold-gated" \
  || bad "registry compact lost a live session / kept an ended one / ignored threshold"

# ---------------------------------------------------------------------------
# 5. _wake_queue_compact keeps every unacked wake and clears the ack log; an unacked wake is
#    never lost. Threshold-gated.
(
  set --
  . "$SRC" >/dev/null 2>&1
  _pid_start_identity(){ printf 'Mon Jan 1 00:00:00 2024\n'; }
  : > "$OSRC_WAKE_QUEUE"
  : > "$OSRC_WAKE_ACK"
  # 210 unacked wakes — cross the 200-line threshold.
  i=0
  while [ "$i" -lt 210 ]; do
    jq -cn --argjson i "$i" --arg ts "2026-08-08T00:00:0${i}Z" \
      '{event_id:("e" + ($i|tostring)),kind:"fleet-state",state:"blocked",task_summary:"t",ts:$ts}' >> "$OSRC_WAKE_QUEUE"
    i=$((i + 1))
  done
  # Acknowledge the first 50 — they must be drained (not in the compacted queue).
  i=0
  while [ "$i" -lt 50 ]; do
    _wake_ack "e${i}" >/dev/null 2>&1 || true
    i=$((i + 1))
  done
  before_q="$(wc -l < "$OSRC_WAKE_QUEUE" | tr -d ' ')"
  [ "$before_q" -gt 200 ] || { echo "FAIL: wake queue did not cross threshold ($before_q)"; exit 1; }
  _wake_queue_compact
  after_q="$(wc -l < "$OSRC_WAKE_QUEUE" | tr -d ' ')"
  # 210 unacked - 50 acked = 160 unacked remain.
  [ "$after_q" -eq 160 ] || { echo "FAIL: compacted wake queue has $after_q lines, expected 160 unacked"; exit 1; }
  # An unacked wake near the end must survive.
  has_tail="$(jq -rs '[.[] | select(.event_id=="e209")] | length' "$OSRC_WAKE_QUEUE" 2>/dev/null)"
  [ "$has_tail" = 1 ] || { echo "FAIL: an unacked wake (e209) was lost by compaction"; exit 1; }
  # An acked wake must be gone from the queue.
  has_acked="$(jq -rs '[.[] | select(.event_id=="e10")] | length' "$OSRC_WAKE_QUEUE" 2>/dev/null)"
  [ "$has_acked" = 0 ] || { echo "FAIL: an acked wake (e10) survived compaction"; exit 1; }
  # The ack log must be cleared.
  ack_lines="$(wc -l < "$OSRC_WAKE_ACK" 2>/dev/null | tr -d ' ')"
  [ "$ack_lines" = 0 ] || { echo "FAIL: ack log was not cleared ($ack_lines lines)"; exit 1; }
  # Threshold-gated: a small queue must NOT be rewritten.
  : > "$OSRC_WAKE_QUEUE"
  jq -cn '{event_id:"tiny",kind:"fleet-state",state:"blocked",task_summary:"t",ts:"2026-08-08T00:00:00Z"}' >> "$OSRC_WAKE_QUEUE"
  tiny_before="$(wc -l < "$OSRC_WAKE_QUEUE" | tr -d ' ')"
  _wake_queue_compact
  tiny_after="$(wc -l < "$OSRC_WAKE_QUEUE" | tr -d ' ')"
  [ "$tiny_after" -eq "$tiny_before" ] || { echo "FAIL: compact rewrote a sub-threshold wake queue ($tiny_before -> $tiny_after)"; exit 1; }
  exit 0
) && ok "wake queue compact keeps unacked wakes, clears ack log, threshold-gated" \
  || bad "wake queue compact lost an unacked wake / kept an acked one / ignored threshold"

# ---------------------------------------------------------------------------
# 6. _heartbeat_log_rotate caps the log to the last N lines and never loses a kept line.
(
  set --
  . "$SRC" >/dev/null 2>&1
  _pid_start_identity(){ printf 'Mon Jan 1 00:00:00 2024\n'; }
  log="$OSRC_HEARTBEAT/heartbeat.log"
  mkdir -p "$OSRC_HEARTBEAT"
  : > "$log"
  i=1
  while [ "$i" -le 100 ]; do
    printf 'line %s\n' "$i" >> "$log"
    i=$((i + 1))
  done
  OSRC_HEARTBEAT_LOG_LINES=20 _heartbeat_log_rotate
  rotated="$(wc -l < "$log" | tr -d ' ')"
  [ "$rotated" -eq 20 ] || { echo "FAIL: rotated log has $rotated lines, expected 20"; exit 1; }
  # The last kept line must be line 100.
  last="$(tail -n 1 "$log")"
  [ "$last" = "line 100" ] || { echo "FAIL: last kept line is '$last', expected 'line 100'"; exit 1; }
  # The first kept line must be line 81 (100 - 20 + 1).
  first="$(head -n 1 "$log")"
  [ "$first" = "line 81" ] || { echo "FAIL: first kept line is '$first', expected 'line 81'"; exit 1; }
  # Threshold-gated: a small log must NOT be rewritten.
  : > "$log"
  printf 'only one\n' >> "$log"
  small_before="$(wc -l < "$log" | tr -d ' ')"
  OSRC_HEARTBEAT_LOG_LINES=20 _heartbeat_log_rotate
  small_after="$(wc -l < "$log" | tr -d ' ')"
  [ "$small_after" -eq "$small_before" ] || { echo "FAIL: rotate rewrote a sub-threshold log ($small_before -> $small_after)"; exit 1; }
  exit 0
) && ok "heartbeat log rotate caps to last N lines and is threshold-gated" \
  || bad "heartbeat log rotate lost a kept line / ignored threshold"

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
