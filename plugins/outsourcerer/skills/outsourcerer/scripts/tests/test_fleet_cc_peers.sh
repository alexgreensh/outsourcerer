#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
FIXTURE="$(mktemp -d "$PWD/.test-fleet-cc.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

export OSRC_HOME="$FIXTURE/state"
export OSRC_CLAUDE_SESSIONS_DIR="$FIXTURE/claude-sessions"
export OSRC_CLAUDE_PROJECTS_DIR="$FIXTURE/claude-projects"
mkdir -p "$OSRC_HOME" "$OSRC_CLAUDE_SESSIONS_DIR" "$OSRC_CLAUDE_PROJECTS_DIR"

set --
. "$SRC" >/dev/null 2>&1

dead_pid=999999
while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid - 1)); done
now_ms="$(date +%s)000"
jq -cn --argjson pid "$dead_pid" --argjson now "$now_ms" '
  {pid:$pid,sessionId:"dead-waiting",cwd:"/",startedAt:$now,updatedAt:$now,
   status:"waiting",statusUpdatedAt:$now,waitingFor:"approval"}' \
  > "$OSRC_CLAUDE_SESSIONS_DIR/dead-waiting.json"

peers="$(_fleet_cc_peer_observations)"
printf '%s' "$peers" | jq -e '
  .[] | select(.session_id=="dead-waiting" and .state=="dead")
  | select(.state_evidence | contains("not live"))' >/dev/null \
  && ok "fresh waiting file with a dead PID classifies dead" \
  || bad "dead PID was promoted to needs-you state"

[ "$(_fleet_classify idle 7200 1 1)" = idle ] \
  && ok "long-idle transcript activity remains idle" \
  || bad "long-idle transcript activity became needs-you"

rm -f "$OSRC_CLAUDE_SESSIONS_DIR"/*.json
jq -cn --argjson pid "$$" --argjson now "$now_ms" '
  {pid:$pid,sessionId:"cwd-mismatch",cwd:"/",startedAt:$now,updatedAt:$now,status:"idle"}' \
  > "$OSRC_CLAUDE_SESSIONS_DIR/cwd-mismatch.json"
self_key="$(OSRC_FLEET_SELF_PID="$$" _fleet_self_key)"; self_rc=$?
[ "$self_key" = "?" ] && [ "$self_rc" -eq 2 ] \
  && ok "unresolved self match fails closed with self?" \
  || bad "unresolved self match was treated as a peer"

rm -f "$OSRC_CLAUDE_SESSIONS_DIR"/*.json
mkdir -p "$OSRC_JOBS/healthy" "$(dirname "$OSRC_SESSION_REGISTRY")"
printf '%s\n' running > "$OSRC_JOBS/healthy/status"
date +%s > "$OSRC_JOBS/healthy/started_at"
printf '%s\n' "$$" > "$OSRC_JOBS/healthy/pid"
jq -cn --argjson pid "$dead_pid" --argjson now "$now_ms" '
  {pid:$pid,sessionId:"stale-peer",cwd:"/",startedAt:$now,updatedAt:$now,
   status:"waiting",statusUpdatedAt:$now,waitingFor:"approval",name:"stale peer"}' \
  > "$OSRC_CLAUDE_SESSIONS_DIR/stale-peer.json"
snapshot="$(_fleet_snapshot_collect)"
digest="$(_fleet_digest "$snapshot")"
pulse="$(_heartbeat_line "$snapshot")"
printf '%s' "$snapshot" | jq -e '.items[] | select(.job_id=="healthy" and .state=="working")' >/dev/null \
  && ! printf '%s' "$digest" | grep -q 'stale-peer' \
  && printf '%s' "$pulse" | grep -q '1 running' \
  && ok "stale CC peers do not alter managed bearings or running count" \
  || bad "stale CC peer leaked into existing managed readers"

printf '%s\n' "$(jq -cn --argjson pid "$dead_pid" '
  {event:"start",session_id:"stale-merged",provider:"cc",endpoint:"tmux:stale-merged",
   harness_pid:$pid,cc_session_id:"stale-merged",cc_pid:$pid,ts:"2026-08-08T00:00:00Z"}')" \
  > "$OSRC_SESSION_REGISTRY"
jq -cn --argjson pid "$dead_pid" --argjson now "$now_ms" '
  {pid:$pid,sessionId:"stale-merged",cwd:"/",startedAt:$now,updatedAt:$now,
   status:"waiting",statusUpdatedAt:$now,waitingFor:"approval"}' \
  > "$OSRC_CLAUDE_SESSIONS_DIR/stale-merged.json"
snapshot="$(_fleet_snapshot_collect)"
printf '%s' "$snapshot" | jq -e '
  [.items[] | select(.session_id=="stale-merged")] as $rows
  | ($rows|length)==1 and $rows[0].owner=="managed"
    and $rows[0].state=="unknown" and $rows[0].cc_state=="dead"' >/dev/null \
  && ok "stale CC state annotates but does not clobber a managed row" \
  || bad "stale CC state clobbered or duplicated a managed row"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
