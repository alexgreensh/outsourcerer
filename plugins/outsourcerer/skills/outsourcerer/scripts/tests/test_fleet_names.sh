#!/usr/bin/env bash
set -uo pipefail

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

model_marker="$FIXTURE/model-called"
_fleet_name_model(){ printf 'called\n' >> "$model_marker"; printf 'Cache Human Fleet Session Names'; }
snapshot="$(jq -cn '{items:[{owner:"cc-peer",session_id:"name-one",cwd:"/project",task_summary:"gambit-b7"}]}')"
_fleet_names_refresh "$snapshot" 0 12 1
mtime="$(_fleet_transcript_mtime name-one /project)"
cached="$(_fleet_name_cache_get name-one "$mtime")"
[ "$cached" = "Cache Human Fleet Session Names" ] \
  && [ "$(wc -l < "$model_marker" | tr -d ' ')" -eq 1 ] \
  && [ "$(_portable_mode "$OSRC_FLEET_NAMES")" = 600 ] \
  && ok "uncached session is named once and cached in a 0600 file" \
  || bad "first naming pass did not persist a private cache record"

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

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
