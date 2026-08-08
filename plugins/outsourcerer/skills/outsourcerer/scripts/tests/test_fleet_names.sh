#!/usr/bin/env bash
set -uo pipefail

if [ "${OSRC_TEST_FLEET_NAME_RUNNER:-0}" = 1 ]; then
  printf '%s\n' "$*" >> "$MODEL_CALLS"
  model=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -m) model="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$model" in
    glm-5-2) exit 1 ;;
    swe-1-7) printf '   \n'; exit 0 ;;
    haiku) printf '%s\n' '1: Cache Human Fleet Names' '2: Repair Fleet Fallback Order' ;;
    *) exit 91 ;;
  esac
  exit 0
fi

if [ "${OSRC_TEST_FLEET_NAME_GROUP_RUNNER:-0}" = 1 ]; then
  model=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -m) model="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ "$model" = glm-5-2 ] || exit 1
  # The intermediate shell exits immediately, reparenting sleep away from this
  # runner's process tree while preserving the runner's isolated process group.
  sh -c 'sleep 30 & printf "%s\n" "$!" > "$1"' sh "$GROUP_CHILD_FILE"
  sleep 30
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
FIXTURE="$(mktemp -d "$PWD/.test-fleet-names.XXXXXX")"
trap 'kill "${live_pid:-}" 2>/dev/null || true; rm -rf "$FIXTURE"' EXIT

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

export OSRC_HOME="$FIXTURE/state"
export OSRC_CLAUDE_SESSIONS_DIR="$FIXTURE/claude-sessions"
export OSRC_CLAUDE_PROJECTS_DIR="$FIXTURE/claude-projects"
export OSRC_FLEET_SELF_PID=999998
mkdir -p "$OSRC_HOME" "$OSRC_CLAUDE_SESSIONS_DIR" "$OSRC_CLAUDE_PROJECTS_DIR/-project"

set --
. "$SRC" >/dev/null 2>&1
real_fleet_name_model="$(declare -f _fleet_name_model)"

model_calls="$FIXTURE/model-calls"
saved_script_path="$SCRIPT_PATH"
saved_have="$(declare -f have)"
SCRIPT_PATH="$HERE/test_fleet_names.sh"
have(){ return 0; }
export MODEL_CALLS="$model_calls" OSRC_TEST_FLEET_NAME_RUNNER=1
fallback_output="$(_fleet_name_model 'batch prompt')"; fallback_rc=$?
SCRIPT_PATH="$saved_script_path"
eval "$saved_have"
unset MODEL_CALLS OSRC_TEST_FLEET_NAME_RUNNER
[ "$fallback_rc" -eq 0 ] \
  && [ "$(printf '%s\n' "$fallback_output" | wc -l | tr -d ' ')" -eq 2 ] \
  && [ "$(wc -l < "$model_calls" | tr -d ' ')" -eq 3 ] \
  && sed -n '1p' "$model_calls" | grep -q '^run -m glm-5-2 batch prompt$' \
  && sed -n '2p' "$model_calls" | grep -q '^run -m swe-1-7 batch prompt$' \
  && sed -n '3p' "$model_calls" | grep -q '^run -m haiku batch prompt$' \
  && ! grep -q -- '--provider' "$model_calls" \
  && ok "batch model uses free Devin aliases before native fallbacks without --provider" \
  || bad "batch model fallback order or provider isolation was wrong"

command sleep 30 & live_pid=$!
now_ms="$(date +%s)000"
jq -cn --argjson pid "$live_pid" --argjson now "$now_ms" '
  {pid:$pid,sessionId:"name-one",cwd:"/project",startedAt:$now,updatedAt:$now,
   status:"working",statusUpdatedAt:$now,name:"gambit-b7"}' \
  > "$OSRC_CLAUDE_SESSIONS_DIR/name-one.json"
{
  jq -cn '{type:"user",message:{role:"user",content:[{type:"text",text:"Fix fleet session names using transcript context"}]}}'
  jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Implemented the cache and now checking tests"}]}}'
} > "$OSRC_CLAUDE_PROJECTS_DIR/-project/name-one.jsonl"

jq -cn --argjson pid "$live_pid" --argjson now "$now_ms" '
  {pid:$pid,sessionId:"name-two",cwd:"/project",startedAt:$now,updatedAt:$now,
   status:"working",statusUpdatedAt:$now,name:"gambit-c8"}' \
  > "$OSRC_CLAUDE_SESSIONS_DIR/name-two.json"
{
  jq -cn '{type:"user",message:{role:"user",content:[{type:"text",text:"Repair fallback lane ordering for fleet names"}]}}'
  jq -cn '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Added the Devin lane fixture and assertions"}]}}'
} > "$OSRC_CLAUDE_PROJECTS_DIR/-project/name-two.jsonl"

model_marker="$FIXTURE/model-called"
model_prompt="$FIXTURE/model-prompt"
printf '%s\n' '1: Cache Human Fleet Session Names' '2: Repair Fleet Naming Fallback Order' > "$FIXTURE/model-output"
_fleet_name_model(){ printf 'called\n' >> "$model_marker"; printf '%s' "$1" > "$model_prompt"; command cat "$FIXTURE/model-output"; }
snapshot="$(jq -cn '{items:[
  {owner:"cc-peer",session_id:"name-one",cwd:"/project",task_summary:"gambit-b7"},
  {owner:"cc-peer",session_id:"name-two",cwd:"/project",task_summary:"gambit-c8"}
]}')"
_fleet_names_refresh "$snapshot" 0 12 1
mtime="$(_fleet_transcript_mtime name-one /project)"
cached="$(_fleet_name_cache_get name-one "$mtime")"
mtime_two="$(_fleet_transcript_mtime name-two /project)"
cached_two="$(_fleet_name_cache_get name-two "$mtime_two")"
[ "$cached" = "Cache Human Fleet Session Names" ] \
  && [ "$cached_two" = "Repair Fleet Naming Fallback Order" ] \
  && [ "$(wc -l < "$model_marker" | tr -d ' ')" -eq 1 ] \
  && grep -q '^Name each coding session in 4-8 words\.' "$model_prompt" \
  && grep -q '^1) task=Fix fleet session names using transcript context activity=Implemented the cache and now checking tests$' "$model_prompt" \
  && grep -q '^2) task=Repair fallback lane ordering for fleet names activity=Added the Devin lane fixture and assertions$' "$model_prompt" \
  && [ "$(_portable_mode "$OSRC_FLEET_NAMES")" = 600 ] \
  && ok "one batch model output names and caches every uncached session in a 0600 file" \
  || bad "batch naming did not make one call and persist both fixture names"

rm -f "$model_marker"
_fleet_names_refresh "$snapshot" 0 12 1
[ ! -e "$model_marker" ] \
  && ok "cache hit skips the naming model" \
  || bad "cached transcript was summarized again"

peers="$(_fleet_cc_peer_observations)"
printf '%s' "$peers" | jq -e '.[] | select(.session_id=="name-one" and .display_name=="Cache Human Fleet Session Names")' >/dev/null \
  && ok "cached derived name appears in JSON observations" \
  || bad "cached display_name was not applied to the session"

jq -cn --argjson pid "$live_pid" --argjson now "$now_ms" '
  {pid:$pid,sessionId:"lane-down",cwd:"/project",startedAt:$now,updatedAt:$now,
   status:"idle",statusUpdatedAt:$now,name:"raw-z9"}' \
  > "$OSRC_CLAUDE_SESSIONS_DIR/lane-down.json"
jq -cn '{type:"user",message:{role:"user",content:[{type:"text",text:"Investigate a lane outage without blocking fleet list"}]}}' \
  > "$OSRC_CLAUDE_PROJECTS_DIR/-project/lane-down.jsonl"
_fleet_name_model(){ return 1; }
down_snapshot="$(jq -cn '{items:[{owner:"cc-peer",session_id:"lane-down",cwd:"/project",task_summary:"raw-z9"}]}')"
_fleet_names_refresh "$down_snapshot" 0 12 1 >/dev/null 2> "$FIXTURE/lane-down.err"; down_rc=$?
down_peers="$(_fleet_cc_peer_observations)"
[ "$down_rc" -eq 0 ] \
  && printf '%s' "$down_peers" | jq -e '.[] | select(.session_id=="lane-down" and .display_name=="raw-z9 (unnamed)")' >/dev/null \
  && grep -q 'naming lane unavailable' "$FIXTURE/lane-down.err" \
  && ok "lane failure is non-fatal and falls back to marked raw name" \
  || bad "lane failure blocked listing or lost the raw name"

jq -cn --argjson pid "$live_pid" --argjson now "$now_ms" '
  {pid:$pid,sessionId:"bad-line",cwd:"/project",startedAt:$now,updatedAt:$now,
   status:"idle",statusUpdatedAt:$now,name:"raw-q4"}' \
  > "$OSRC_CLAUDE_SESSIONS_DIR/bad-line.json"
jq -cn '{type:"user",message:{role:"user",content:[{type:"text",text:"Keep malformed batch names nonfatal"}]}}' \
  > "$OSRC_CLAUDE_PROJECTS_DIR/-project/bad-line.jsonl"
_fleet_name_model(){ printf '1: Too Short'; }
bad_snapshot="$(jq -cn '{items:[{owner:"cc-peer",session_id:"bad-line",cwd:"/project",task_summary:"raw-q4"}]}')"
_fleet_names_refresh "$bad_snapshot" 0 12 1 >/dev/null 2> "$FIXTURE/bad-line.err"; bad_rc=$?
bad_mtime="$(_fleet_transcript_mtime bad-line /project)"
bad_cached="$(_fleet_name_cache_get bad-line "$bad_mtime")" || bad_cached=""
bad_peers="$(_fleet_cc_peer_observations)"
[ "$bad_rc" -eq 0 ] \
  && [ -z "$bad_cached" ] \
  && printf '%s' "$bad_peers" | jq -e '.[] | select(.session_id=="bad-line" and .display_name=="raw-q4 (unnamed)")' >/dev/null \
  && grep -q 'could not parse 1 session name' "$FIXTURE/bad-line.err" \
  && ok "unparseable batch line stays uncached and marked unnamed without crashing" \
  || bad "unparseable batch line was cached or made refresh fail"

rm -f "$model_marker"
_fleet_name_model(){ printf 'called\n' >> "$model_marker"; return 1; }
_fleet_snapshot_refresh(){ printf '%s' "$down_snapshot"; }
cmd_fleet_ls --json >/dev/null; ls_rc=$?
[ "$ls_rc" -eq 0 ] && [ ! -e "$model_marker" ] \
  && ok "base fleet ls stays lazy and never waits on a naming lane" \
  || bad "base fleet ls invoked or depended on the naming model"

signals="$(_fleet_name_signals name-one /project)"
printf '%s' "$signals" | jq -e '
  .first_task=="Fix fleet session names using transcript context" and
  .latest_activity=="Implemented the cache and now checking tests" and
  (.first_task|length)<=600 and (.latest_activity|length)<=400' >/dev/null \
  && ok "naming signals use first user task and latest assistant activity" \
  || bad "transcript naming signals selected the wrong messages"

# Drive the real bounded naming path with a fake runner. Its intermediate shell reparents a child
# before the deadline, so a process-tree-only cleanup cannot find it; the launch PGID must reap it.
group_child_file="$FIXTURE/group-orphan.pid"
eval "$real_fleet_name_model"
saved_script_path="$SCRIPT_PATH"
saved_have="$(declare -f have)"
SCRIPT_PATH="$HERE/test_fleet_names.sh"
have(){ [ "$1" = devin ]; }
export OSRC_TEST_FLEET_NAME_GROUP_RUNNER=1 GROUP_CHILD_FILE="$group_child_file"
OSRC_FLEET_NAME_TIMEOUT=1 _fleet_name_model 'bounded group fixture' >/dev/null 2>&1; group_rc=$?
SCRIPT_PATH="$saved_script_path"
eval "$saved_have"
unset OSRC_TEST_FLEET_NAME_GROUP_RUNNER GROUP_CHILD_FILE
group_orphan="$(cat "$group_child_file" 2>/dev/null)"
orphan_live=0
if kill -0 "$group_orphan" 2>/dev/null; then
  orphan_stat="$(ps -o stat= -p "$group_orphan" 2>/dev/null | tr -d ' ')"
  case "$orphan_stat" in Z*) ;; *) orphan_live=1 ;; esac
fi
[ "$group_rc" -ne 0 ] && [ -n "$group_orphan" ] && [ "$orphan_live" -eq 0 ] \
  && ok "bounded naming launch reaps a reparented delegate through its process group" \
  || { [ -n "$group_orphan" ] && kill -KILL "$group_orphan" 2>/dev/null || true; bad "bounded naming launch left a reparented delegate alive"; }

# PGID discovery is best-effort. A missing value must still kill the root tree and log the orphan risk
# rather than returning silently and blocking forever in the caller's wait.
sleep 30 & fallback_root=$!
_kill_process_group "" "$fallback_root" 2> "$FIXTURE/group-fallback.err" || true
kill -0 "$fallback_root" 2>/dev/null \
  && { kill -KILL "$fallback_root" 2>/dev/null || true; bad "missing-PGID fallback left the naming root alive"; } \
  || grep -q 'orphan may remain' "$FIXTURE/group-fallback.err" \
    && ok "missing-PGID cleanup falls back to the root tree and logs orphan risk" \
    || bad "missing-PGID cleanup did not report orphan risk"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
