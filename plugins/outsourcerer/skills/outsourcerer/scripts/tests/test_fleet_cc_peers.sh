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

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
