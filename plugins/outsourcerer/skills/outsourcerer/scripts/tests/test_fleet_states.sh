#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
FIXTURE="$(mktemp -d "$PWD/.test-fleet-states.XXXXXX")"
trap 'kill "${live_pid:-}" 2>/dev/null || true; rm -rf "$FIXTURE"' EXIT

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

export OSRC_HOME="$FIXTURE/state"
export OSRC_CLAUDE_SESSIONS_DIR="$FIXTURE/claude-sessions"
export OSRC_CLAUDE_PROJECTS_DIR="$FIXTURE/claude-projects"
export OSRC_FLEET_SELF_PID=999998
mkdir -p "$OSRC_HOME" "$OSRC_CLAUDE_SESSIONS_DIR" "$OSRC_CLAUDE_PROJECTS_DIR/-work"

set --
. "$SRC" >/dev/null 2>&1

command sleep 30 & live_pid=$!
now_ms="$(date +%s)000"
jq -cn --argjson pid "$live_pid" --argjson now "$now_ms" '
  {pid:$pid,sessionId:"odd-start",cwd:"/work",procStart:"unreadable/odd identity",
   startedAt:$now,updatedAt:$now,status:"working",statusUpdatedAt:$now,name:"raw-live"}' \
  > "$OSRC_CLAUDE_SESSIONS_DIR/odd-start.json"
peers="$(_fleet_cc_peer_observations)"
printf '%s' "$peers" | jq -e '.[] | select(.session_id=="odd-start" and .alive==true and .state=="working" and .state_label=="Working")' >/dev/null \
  && ok "kill -0 wins when procStart cannot be safely compared" \
  || bad "odd procStart mislabeled a live process as ended"

jq -cn --argjson pid "$live_pid" --argjson now "$now_ms" '
  {pid:$pid,sessionId:"permission-wait",cwd:"/work",startedAt:$now,updatedAt:$now,
   status:"working",statusUpdatedAt:$now,name:"prompt"}' \
  > "$OSRC_CLAUDE_SESSIONS_DIR/permission-wait.json"
jq -cn '{type:"assistant",message:{role:"assistant",content:[
  {type:"tool_use",id:"ask-1",name:"AskUserQuestion",input:{question:"Approve the change?"}}
]}}' > "$OSRC_CLAUDE_PROJECTS_DIR/-work/permission-wait.jsonl"
peers="$(_fleet_cc_peer_observations)"
printf '%s' "$peers" | jq -e '
  .[] | select(.session_id=="permission-wait" and .state=="blocked?" and .state_label=="Waiting on you")
  | select(.waiting_for=="transcript permission prompt")' >/dev/null \
  && ok "unanswered transcript permission prompt maps to Waiting on you" \
  || bad "permission prompt was not recognized as waiting"

labels="$(_fleet_state_label working)|$(_fleet_state_label blocked?)|$(_fleet_state_label unresponsive?)|$(_fleet_state_label idle)|$(_fleet_state_label done)|$(_fleet_state_label stopped)|$(_fleet_state_label failed)|$(_fleet_state_label ended)"
[ "$labels" = "Working|Waiting on you|Maybe stuck|Idle|Done|Stopped mid-task|Failed|Ended" ] \
  && ok "machine states map to the complete human vocabulary" \
  || bad "state label vocabulary drifted: $labels"

[ "$(_fleet_classify working 1 1 1 approval)" = 'blocked?' ] \
  && [ "$(_fleet_classify working 601 1 1)" = 'unresponsive?' ] \
  && [ "$(_fleet_classify idle 9999 1 1)" = idle ] \
  && [ "$(_fleet_classify waiting 1 1 0)" = ended ] \
  && ok "waitingFor, stale working, and idle classify distinctly" \
  || bad "live state classification collapsed distinct cases"

write_transcript(){
  local id="$1" body="$2"
  printf '%s\n' "$body" > "$OSRC_CLAUDE_PROJECTS_DIR/-work/$id.jsonl"
}

write_transcript done-one "$(jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Implemented the fix and all tests pass."}],stop_reason:"end_turn"}}')"
write_transcript stopped-tool "$(jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Checking the build."},{type:"tool_use",id:"tool-1",name:"Bash",input:{}}]}}')"
write_transcript stopped-user "$(jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"I can help."}]}}')
$(jq -cn '{type:"user",message:{role:"user",content:[{type:"text",text:"Please finish the remaining tests."}]}}')"
write_transcript failed-one "$(jq -cn '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"tool-1",is_error:true,content:"API failure"}]}}')"

[ "$(_fleet_ended_state done-one /work)" = done ] \
  && [ "$(_fleet_ended_state stopped-tool /work)" = stopped ] \
  && [ "$(_fleet_ended_state stopped-user /work)" = stopped ] \
  && [ "$(_fleet_ended_state failed-one /work)" = failed ] \
  && ok "transcript tails differentiate done, stopped, and failed endings" \
  || bad "ended transcript differentiation returned the wrong state"

snapshot="$(jq -cn '{items:[
  {owner:"cc-peer",task_summary:"wait",state:"blocked?",state_label:"Waiting on you"},
  {owner:"cc-peer",task_summary:"done",state:"done",state_label:"Done"}
]}')"
listing="$(_fleet_ls_group "$snapshot" cc-peer Peers)"
printf '%s' "$listing" | grep -q 'Waiting on you' \
  && printf '%s' "$listing" | grep -q 'Done' \
  && [ "$(printf '%s' "$listing" | grep -c 'needs-you')" -eq 1 ] \
  && ok "fleet table renders state labels and only waiting rows need you" \
  || bad "fleet table state labels or needs-you rendering is wrong"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
