#!/usr/bin/env bash
# atk3_guard: hostile snapshots + caller-identification edges for _blind_turn_guard.
set -uo pipefail
S="/Users/alexgreenshpun/CascadeProjects/Prompts/PERSONAL_OS/PROJECTS/outsourcerer/sessions/2026-10-09-pr-sweep/wt-a-ttl/plugins/outsourcerer/skills/outsourcerer/scripts/outsourcerer.sh"
export OSRC_HOME; OSRC_HOME="$(mktemp -d)"; export HOME; HOME="$(mktemp -d)"
export OSRC_CLAUDE_SESSIONS_DIR="$OSRC_HOME/nosess" OSRC_CLAUDE_PROJECTS_DIR="$OSRC_HOME/noproj"
mkdir -p "$OSRC_CLAUDE_SESSIONS_DIR" "$OSRC_CLAUDE_PROJECTS_DIR"
export OSRC_FLEET_SNAPSHOT="$OSRC_HOME/fleet.json"
set --; OSRC_SOURCED=1 . "$S" >/dev/null 2>&1
have jq || { echo "no jq"; exit 0; }
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export OSRC_FLEET_SELF_PID=$$

snap() { jq -cn --arg now "$NOW" '{schema_version:"1",generation:"t",captured_at:$now,items:.}'; }
snap_items() { jq -cn --arg now "$NOW" --slurpfile it /dev/stdin '{schema_version:"1",generation:"t",captured_at:$now,items:$it[0]}'; }
run() { _blind_turn_guard 2>&1; echo "rc=$?"; }

echo "== malformed JSON (must be rc=0, no crash under set -u) =="
echo '{"schema_version":"1","items":[' > "$OSRC_FLEET_SNAPSHOT"
run | tail -2

echo "== empty file =="
: > "$OSRC_FLEET_SNAPSHOT"; run | tail -1

echo "== items not an array =="
jq -cn --arg now "$NOW" '{schema_version:"1",captured_at:$now,items:{a:1}}' > "$OSRC_FLEET_SNAPSHOT"; run | tail -1

echo "== valid shell, hostile rows =="
# cc-peer blocked row with STRING pid equal to an ancestor pid
anc=" $(_fleet_self_ancestors 2>/dev/null) "
anctok="$(printf '%s' "$anc" | awk '{print $1}')"
printf 'ancestors=[%s] first=%s\n' "$anc" "$anctok"
jq -cn --arg now "$NOW" --arg tok "$anctok" '{schema_version:"1",captured_at:$now,items:[{schema_version:"1",owner:"cc-peer",harness_pid:$tok,pid:$tok,session_id:"other-sid",state:"blocked",job_id:"spid"}]}' > "$OSRC_FLEET_SNAPSHOT"
echo "-- cc-peer blocked, pid as STRING matching an ancestor (want excluded -> rc=0):"
run | tail -2

echo "-- managed row, pid IS an ancestor, sid matches: must still report (never exclude managed)"
jq -cn --arg now "$NOW" --arg pid "$anctok" --arg sid "${CLAUDE_CODE_SESSION_ID:-nosid}" \
  '{schema_version:"1",captured_at:$now,items:[{schema_version:"1",owner:"managed",harness:"job",pid:($pid|tonumber),session_id:$sid,state:"blocked",job_id:"mj1",state_evidence:"blocked"}]}' \
  > "$OSRC_FLEET_SNAPSHOT"
run | tail -3

echo "-- cc-peer pid is a PREFIX of an ancestor pid (123 vs 12345): must report"
jq -cn --arg now "$NOW" \
  '{schema_version:"1",captured_at:$now,items:[{schema_version:"1",owner:"cc-peer",pid:123,session_id:"x",state:"blocked",job_id:"pref"}]}' \
  > "$OSRC_FLEET_SNAPSHOT"
run | tail -2

echo "-- session_id null in row, CLAUDE sid set: must report (null != sid)"
jq -cn --arg now "$NOW" '{schema_version:"1",captured_at:$now,items:[{schema_version:"1",owner:"cc-peer",pid:null,session_id:null,state:"blocked",job_id:"nullsid"}]}' > "$OSRC_FLEET_SNAPSHOT"
run | tail -2

echo "-- CLAUDE_CODE_SESSION_ID carrying quotes/newline/metachars: no crash, sid-match rows report"
export CLAUDE_CODE_SESSION_ID='we"ird\nsid$(touch /tmp/x)`id`'
jq -cn --arg now "$NOW" '{schema_version:"1",captured_at:$now,items:[{schema_version:"1",owner:"cc-peer",pid:9876,session_id:"s",state:"blocked",job_id:"wsid"}]}' > "$OSRC_FLEET_SNAPSHOT"
run | tail -2
unset CLAUDE_CODE_SESSION_ID

echo "-- 2000 items timing"
jq -cn --arg now "$NOW" '{schema_version:"1",captured_at:$now,items:[range(2000)|{schema_version:"1",owner:(if .%2==0 then "managed" else "cc-peer" end),pid:(.+500000),session_id:("s"+tostring),state:"blocked",job_id:("j"+tostring)}]}' > "$OSRC_FLEET_SNAPSHOT"
SECONDS=0; out="$(run)"; echo "2000 items: ${SECONDS}s, first line: $(printf '%s' "$out" | head -1)"

echo "-- pid as object/array: no crash, reported"
jq -cn --arg now "$NOW" '{schema_version:"1",captured_at:$now,items:[{schema_version:"1",owner:"cc-peer",pid:{a:1},session_id:"s",state:"blocked",job_id:"objpid"}]}' > "$OSRC_FLEET_SNAPSHOT"
run | tail -2
echo DONE
