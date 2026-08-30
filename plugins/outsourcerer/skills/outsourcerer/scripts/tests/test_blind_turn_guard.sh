#!/usr/bin/env bash
# test_blind_turn_guard.sh — the orchestrator must not end its turn blind while live delegated work
# needs a human.
#
# The diagnosed failure: four delegated sessions sat parked on approval prompts for over an hour
# while the orchestrator's turn ended silently. Nothing was broken — the orchestrator simply walked
# away without checking, and the user found it by accident. The blind-turn guard fires at the exact
# moment of walking away and refuses to end blind. This test proves:
#   - a delegate ALIVE but BLOCKED awaiting input is reported as "WAITING ON YOU", DISTINCTLY from
#     a delegate that is genuinely working (silence — never block a healthy fleet), and DISTINCTLY
#     from a delegate that is stalled ("MAYBE STUCK").
#   - silence when everything is working, silence when only terminal work exists, silence when there
#     is no fleet view yet, and silence under the OSRC_BLIND_TURN_GUARD=0 escape hatch.
#   - the guard is a single bounded pass (no per-session subprocess fan-out).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

FIXTURE="$(mktemp -d "$PWD/.test-blind-turn.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
export OSRC_HOME="$FIXTURE/home"
mkdir -p "$OSRC_HOME"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Source the script to call _blind_turn_guard directly. The guard reads the fleet snapshot file
# ($OSRC_FLEET_SNAPSHOT, derived from OSRC_HOME) — it does NOT re-collect, so we control the view.
set --; . "$SRC" >/dev/null 2>&1

SNAP="$OSRC_FLEET_SNAPSHOT"
write_snapshot() { # <items-json-array>
  ( umask 077; printf '%s\n' "$1" > "$SNAP" ) 2>/dev/null
}
# Build a schema_version:"1" snapshot with the given item objects.
snapshot_with() { # <item-json>...
  local items='['; local first=1
  for it in "$@"; do
    [ "$first" = 1 ] && first=0 || items="$items,"
    items="$items$it"
  done
  items="$items]"
  jq -cn --argjson items "$items" '{schema_version:"1",generation:"g",captured_at:(now|todateiso8601),items:$items}'
}

# Item builders. The guard keys off .state (and .owner for the action wording).
managed_blocked='{"owner":"managed","job_id":"job-7","session_id":null,"state":"blocked?","state_label":"Waiting on you","waiting_for":"approval prompt","display_name":"ship the fix","cwd":"/repo"}'
managed_working='{"owner":"managed","job_id":"job-8","session_id":null,"state":"working","state_label":"Working","waiting_for":null,"display_name":"building","cwd":"/repo"}'
managed_stalled='{"owner":"managed","job_id":"job-9","session_id":null,"state":"unresponsive?","state_label":"Maybe stuck","waiting_for":null,"display_name":"silent runner","cwd":"/repo"}'
peer_blocked='{"owner":"cc-peer","job_id":null,"session_id":"sess-42","state":"blocked?","state_label":"Waiting on you","waiting_for":"transcript permission prompt","display_name":"review PR","cwd":"/repo"}'
managed_done='{"owner":"managed","job_id":"job-1","session_id":null,"state":"done","state_label":"Done","waiting_for":null,"display_name":"finished","cwd":"/repo"}'

# --- a blocked-awaiting-input delegate is reported, a working one is NOT (the diagnosed case) ---
write_snapshot "$(snapshot_with "$managed_blocked" "$managed_working")"
out="$(_blind_turn_guard 2>&1)"; rc=$?
[ "$rc" = 7 ] \
  && ok "guard REFUSES (rc=7) when a live delegate is blocked awaiting input" \
  || bad "guard did not refuse on a blocked delegate (rc=$rc)"
printf '%s' "$out" | grep -q 'WAITING ON YOU' \
  && ok "a blocked delegate is named 'WAITING ON YOU'" \
  || bad "blocked delegate was not labeled as waiting on you"
printf '%s' "$out" | grep -q 'job-7' \
  && ok "the blocked delegate is named by id" \
  || bad "the blocked delegate id was not named"
printf '%s' "$out" | grep -q 'approval prompt' \
  && ok "what the delegate is awaiting is surfaced" \
  || bad "the awaiting reason was not surfaced"
printf '%s' "$out" | grep -q 'watch job-7' \
  && ok "the notice names the exact command to start watching the blocked job" \
  || bad "the blocked delegate did not give a watch command"
# A working delegate must NOT be surfaced — silence on the healthy part of the fleet.
printf '%s' "$out" | grep -q 'job-8' \
  && bad "a WORKING delegate was surfaced (a healthy fleet must stay silent)" \
  || ok "a working delegate is NOT surfaced (silence on healthy work)"
printf '%s' "$out" | grep -qi 'working' \
  && bad "the word 'working' leaked into the guard notice" \
  || ok "no 'working' wording in the refusal (blocked is distinct from working)"

# --- a blocked cc-peer gives the peer action (session reply / fleet show), not the job action ---
write_snapshot "$(snapshot_with "$peer_blocked")"
out="$(_blind_turn_guard 2>&1)"; rc=$?
[ "$rc" = 7 ] && ok "guard refuses on a blocked cc-peer delegate" || bad "guard did not refuse on a blocked peer (rc=$rc)"
printf '%s' "$out" | grep -q 'session reply sess-42' \
  && ok "blocked peer names 'session reply <id>' as the answer command" \
  || bad "blocked peer did not name the session reply command"
printf '%s' "$out" | grep -q 'fleet show sess-42' \
  && ok "blocked peer names 'fleet show <id>' to inspect" \
  || bad "blocked peer did not name the fleet show command"

# --- a stalled delegate is reported DISTINCTLY (MAYBE STUCK, not WAITING ON YOU) ---
write_snapshot "$(snapshot_with "$managed_stalled")"
out="$(_blind_turn_guard 2>&1)"; rc=$?
[ "$rc" = 7 ] && ok "guard refuses on a stalled (unresponsive) delegate" || bad "guard did not refuse on a stalled delegate (rc=$rc)"
printf '%s' "$out" | grep -q 'MAYBE STUCK' \
  && ok "a stalled delegate is named 'MAYBE STUCK'" \
  || bad "a stalled delegate was not labeled as maybe stuck"
printf '%s' "$out" | grep -q 'WAITING ON YOU' \
  && bad "a stalled delegate was mislabeled as 'WAITING ON YOU' (stalled must be distinct from blocked)" \
  || ok "stalled and blocked are reported distinctly"
printf '%s' "$out" | grep -q 'explain job-9' \
  && ok "the stalled delegate names 'explain <id>' to diagnose" \
  || bad "the stalled delegate did not name the explain command"

# --- silence when everything is genuinely working (never block a healthy fleet) ---
write_snapshot "$(snapshot_with "$managed_working")"
out="$(_blind_turn_guard 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] \
  && ok "silence + rc=0 when the only live delegate is working" \
  || bad "a healthy working fleet was not silent (rc=$rc, out=$(printf '%s' "$out" | head -1))"

# --- silence when only terminal work exists ---
write_snapshot "$(snapshot_with "$managed_done")"
out="$(_blind_turn_guard 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] \
  && ok "silence when only terminal (done) work exists" \
  || bad "terminal work triggered the guard (rc=$rc)"

# --- silence when there is no fleet view yet (the heartbeat owns collection; guard does not collect) ---
rm -f "$SNAP"
out="$(_blind_turn_guard 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] \
  && ok "silence when no snapshot exists (guard does not re-collect)" \
  || bad "a missing snapshot was not silent (rc=$rc)"

# --- the escape hatch disables the guard even with blocked work present ---
write_snapshot "$(snapshot_with "$managed_blocked")"
out="$(OSRC_BLIND_TURN_GUARD=0 _blind_turn_guard 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] \
  && ok "OSRC_BLIND_TURN_GUARD=0 silences the guard (escape hatch)" \
  || bad "the escape hatch did not silence the guard (rc=$rc)"

# --- end-to-end through main: a DELEGATING command refuses to end blind (rc=7) when work is blocked.
# OSRC_PREFLIGHT=1 makes route_delegate return 0 without dispatching, so `run` reaches the turn-end
# hook cleanly — the guard then refuses because the snapshot has a blocked delegate. ---
write_snapshot "$(snapshot_with "$managed_blocked")"
out="$(OSRC_HEARTBEAT_DISABLED=1 OSRC_PREFLIGHT=1 OUTSOURCERER_DEPTH=0 bash "$SRC" run "x" 2>&1)"; rc=$?
[ "$rc" = 7 ] \
  && ok "main returns 7 (refuse to end blind) after a DELEGATING command with blocked work" \
  || bad "a delegating command did not refuse (rc=$rc) with blocked work present"
printf '%s' "$out" | grep -q 'blind-turn guard' \
  && ok "the guard notice fires through main at a delegating command's turn-end" \
  || bad "the guard notice did not fire through main on a delegating command"

# --- end-to-end: a NON-delegating command surfaces the guard as a backstop NOTICE but keeps its own
# exit code (a successful utility command must not turn non-zero because of parked fleet state). ---
write_snapshot "$(snapshot_with "$managed_blocked")"
out="$(OSRC_HEARTBEAT_DISABLED=1 bash "$SRC" tab 2>&1)"; rc=$?
[ "$rc" = 0 ] \
  && ok "a non-delegating command (tab) keeps exit 0 even with blocked fleet work" \
  || bad "a non-delegating command's exit code was overridden by the guard (rc=$rc)"
printf '%s' "$out" | grep -q 'blind-turn guard' \
  && ok "the guard still surfaces as a backstop notice on a non-delegating command" \
  || bad "the guard did not surface on a non-delegating command"

# --- end-to-end: a LOOKING command does NOT trigger the guard (the orchestrator is supervising) ---
out="$(OSRC_HEARTBEAT_DISABLED=1 bash "$SRC" fleet ls 2>&1)"; rc=$?
# fleet ls calls _fleet_snapshot_refresh which overwrites $SNAP with a real (empty) collect; that is
# fine — we only assert the guard did not append a refusal to a looking command's output.
printf '%s' "$out" | grep -q 'blind-turn guard' \
  && bad "the guard fired on a looking command (fleet) — it must not interrupt supervision" \
  || ok "a looking command (fleet) does not trigger the blind-turn guard"

# --- the guard is a single bounded pass: it must not spawn a jq per session. Verify structurally
# that the guard body contains exactly one jq invocation over the snapshot (the selection pass),
# then confirm a 40-item healthy fleet stays silent (no per-item fan-out, no false refusal). ---
# "have jq" is a presence check, not a jq pass; count only real invocations (jq with a flag).
guard_jq="$(awk '/^_blind_turn_guard\(\)/,/^}/' "$SRC" | grep -c 'jq -')"
[ "$guard_jq" = 1 ] \
  && ok "the guard makes exactly one jq pass over the snapshot (bounded, not per-session)" \
  || bad "the guard makes $guard_jq jq pass(es) (expected exactly 1)"
# Newline-separated so command substitution word-splits into 40 distinct item args.
write_snapshot "$(snapshot_with $(for i in $(seq 1 40); do
  printf '{"owner":"managed","job_id":"j%d","session_id":null,"state":"working","state_label":"Working","waiting_for":null,"display_name":"w%d","cwd":"/r"}\n' "$i" "$i"
done))"
out="$(_blind_turn_guard 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] \
  && ok "40 working delegates stay silent (healthy fleet, bounded pass)" \
  || bad "40 working delegates were not silent (rc=$rc)"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
