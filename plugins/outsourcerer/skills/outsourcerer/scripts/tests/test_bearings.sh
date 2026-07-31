#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TMP="$(mktemp -d "$PWD/.test-bearings.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
run() { OSRC_HOME="$TMP/state" bash "$SRC" "$@"; }

mkdir -p "$TMP/state/jobs/landed" "$TMP/state/jobs/call" "$TMP/state/jobs/observed"
printf '%s\n' done > "$TMP/state/jobs/landed/status"
printf '%s\n' blocked > "$TMP/state/jobs/call/status"
printf '%s\n' running > "$TMP/state/jobs/observed/status"
date +%s > "$TMP/state/jobs/landed/started_at"
date +%s > "$TMP/state/jobs/call/started_at"
date +%s > "$TMP/state/jobs/observed/started_at"

out="$(run rundown 2>&1)"
sections="$(printf '%s\n' "$out" | grep -E "^(Captain's Call|Recently Landed|Underway|Charted Next)$")"
expected="$(printf "%s\n" "Captain's Call" "Recently Landed" Underway "Charted Next")"
[ "$sections" = "$expected" ] && ok "rundown renders the four sections in fixed order" \
  || bad "rundown section order changed"
printf '%s' "$out" | grep -q -- '- call \[blocked\]' \
  && ok "rundown classifies current blocked work" \
  || bad "blocked work was not placed in Captain's Call"
printf '%s' "$out" | grep -q -- '- landed \[completed\]' \
  && ok "rundown classifies recently landed work" \
  || bad "completed work was not placed in Recently Landed"
[ "$(cat "$TMP/state/jobs/observed/status")" = running ] \
  && ok "rundown discovery does not mutate managed job state" \
  || bad "rundown discovery rewrote managed job state"

before="$(jq -r '.generation' "$TMP/state/fleet-snapshot.json")"
out="$(run bearings 2>&1)"
after="$(jq -r '.generation' "$TMP/state/fleet-snapshot.json")"
[ "$before" = "$after" ] && printf '%s' "$out" | grep -q '^Underway$' \
  && ok "bearings reads the published snapshot without rediscovery" \
  || bad "bearings changed or failed to read the published snapshot"

empty="$TMP/empty"
out="$(OSRC_HOME="$empty" bash "$SRC" bearings 2>&1)"
printf '%s' "$out" | grep -q -- '- unknown \[unknown\] fleet state unavailable' \
  && ok "missing evidence fails to unknown" \
  || bad "missing evidence was promoted to a known state"

line="$(OSRC_HOME="$TMP/line" bash -c 'src="$1"; snapshot="$2"; set --; . "$src" >/dev/null 2>&1; _heartbeat_line "$snapshot"' bash "$SRC" \
  '{"schema_version":"1","generation":"g","captured_at":"now","items":[{"state":"working","job_id":"agent-1","session_id":null,"observed_model":"sol","lane":"cx","task_summary":"map auth"}]}')"
printf '%s' "$line" | grep -q '▶ agent-1: sol@cx · map auth' \
  && ok "heartbeat line names the active agent, model, lane, and work" \
  || bad "heartbeat line omitted active work detail"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
