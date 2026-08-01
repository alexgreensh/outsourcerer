#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
pass=0; fail=0; ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

s="$SRC"; set --; . "$s" >/dev/null 2>&1

line() { _heartbeat_line "$1"; }
past() { date -u -v-"$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$2" +%Y-%m-%dT%H:%M:%SZ; }

# Idle fleet reads as quiet, not as a row of zeroes.
out="$(line '{"items":[]}')"
case "$out" in *"all quiet"*) ok "idle fleet reads as quiet prose" ;; *) bad "idle line not human: $out" ;; esac

# Read-only external observations are a compact count, never enumerated in the pulse.
out="$(line '{"items":[{"owner":"external","state":"unknown","session_id":"a"},{"owner":"external","state":"unknown","session_id":"b"}]}')"
case "$out" in *"2 other sessions seen"*) ok "external sessions summarized as a count" ;; *) bad "external count missing: $out" ;; esac
case "$out" in *"external session"*|*"session_id"*) bad "external sessions were enumerated in the pulse" ;; *) ok "external sessions are not enumerated" ;; esac

# Active work names who, on what, and for how long.
p="$(past 14M '14 minutes ago')"
snap="$(jq -cn --arg p "$p" '{items:[{owner:"managed",state:"working",observed_model:"sol",task_summary:"refactor auth",started_at:$p}]}')"
out="$(line "$snap")"
case "$out" in *"sol on 'refactor auth'"*) ok "active work names agent and task" ;; *) bad "active work detail missing: $out" ;; esac
case "$out" in *"(14m)"*) ok "elapsed time renders from started_at" ;; *) bad "elapsed missing: $out" ;; esac
case "$out" in *"nothing needs you"*) ok "quiet-but-working states nothing needs the user" ;; *) bad "reassurance missing: $out" ;; esac

# A blocked job is surfaced as needing the user.
snap='{"items":[{"owner":"managed","state":"blocked","observed_model":"glm","task_summary":"migrate db"}]}'
out="$(line "$snap")"
case "$out" in *"⚠ needs you"*"glm 'migrate db' blocked"*) ok "blocked work is flagged as needing you" ;; *) bad "blocked not surfaced: $out" ;; esac

# A missing started_at degrades to no elapsed, never to a crash or a bogus duration.
snap='{"items":[{"owner":"managed","state":"working","observed_model":"sol","task_summary":"x"}]}'
out="$(line "$snap")"
case "$out" in *"sol on 'x'"*) ok "missing start time degrades cleanly" ;; *) bad "missing start time broke the line: $out" ;; esac

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
