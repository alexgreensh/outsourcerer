#!/usr/bin/env bash
# test_watcher.sh — a detached job must never run unobserved without the tool saying so.
#
# Observed repeatedly in real sessions: the orchestrator launches a background job and then moves on,
# and nobody notices it wedged until the user asks. Documentation did not fix it, because "remember to
# watch" is exactly the kind of instruction a busy session drops. So the tool tracks attention itself:
# it demands a watcher at launch, and any later invocation reports jobs nobody has looked at.
set -uo pipefail
# Conformance disables the status beacon globally for isolation. This suite exercises
# the auto-arm path itself, so it deliberately opts back in.
export OSRC_HEARTBEAT_DISABLED=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# OSRC_DOCTOR_OFFLINE=1: this test calls `doctor` repeatedly to check watcher-warning behaviour,
# not lane liveness — the live network probes (OpenRouter credits, session-limit meter, claudex
# ping) are pure latency here and previously made the test take minutes and wedge the suite.
run() { PATH="/usr/bin:/bin" OSRC_HOME="$TMP" OSRC_DOCTOR_OFFLINE=1 /bin/bash "$SRC" "$@"; }
mkjob() { mkdir -p "$TMP/jobs/$1"; printf '%s\n' "$2" > "$TMP/jobs/$1/status"
          printf '%s\n' "$(( $(date +%s) - ${3:-600} ))" > "$TMP/jobs/$1/started_at"; }

# --- a live job nobody has looked at must be reported, unprompted ---
mkjob lonely running 600
out="$(run doctor 2>&1)"
printf '%s' "$out" | grep -q 'nobody has looked at them' \
  && ok "an unobserved running job is reported on the next invocation" \
  || bad "a job running for 10 minutes with no observer went unmentioned"
printf '%s' "$out" | grep -q 'watch lonely' \
  && ok "the warning names the exact command to start watching" \
  || bad "warning does not give the watch command"

# --- looking at it counts; the tool must stop nagging once you have ---
run status lonely >/dev/null 2>&1
run doctor 2>&1 | grep -q 'nobody has looked at them' \
  && bad "still warned about a job that was just inspected" \
  || ok "the warning clears once someone actually looks"

# --- a finished job is not 'unwatched'; only live work can be neglected ---
mkjob finished done 900
run doctor 2>&1 | grep -q 'finished' \
  && bad "a completed job was reported as needing a watcher" \
  || ok "terminal jobs are never reported as unwatched"

# --- a job that just started gets a grace period, or every launch would cry wolf ---
mkjob fresh running 5
run doctor 2>&1 | grep -q 'fresh' \
  && bad "warned about a job that started seconds ago (cries wolf on every launch)" \
  || ok "a just-launched job is given a grace period before it counts as neglected"

# --- the grace period is tunable rather than a magic number ---
grep -q 'OSRC_UNWATCHED_AFTER' "$SRC" \
  && ok "the neglect threshold is configurable" || bad "neglect threshold is hardcoded"

# --- launching must TELL you to watch, not offer it as one option among three ---
grep -q 'NOW WATCH IT' "$SRC" \
  && ok "a launch instructs you to watch rather than listing poll options" \
  || bad "launch output still presents watching as optional"

# --- the commands that mean 'someone looked' must record it, or the warning never clears ---
for c in cmd_status cmd_watch cmd_result; do
  awk "/^$c\(\) \{/,/_mark_watched/" "$SRC" | grep -q '_mark_watched' \
    && ok "$c records that the job was observed" \
    || bad "$c does not record attention (warning would never clear)"
done

# --- a detached worker must not warn about itself: it IS the work ---
awk '/Surface neglected jobs on EVERY invocation/,/esac/' "$SRC" | grep -q '__runjob' \
  && ok "the detached job process is exempt from its own warning" \
  || bad "a running job would warn about itself"

# --- fleet heartbeat: one collection per tick, generation dedupe, durable and attached sinks ---
src="$SRC"; set --; . "$src" >/dev/null 2>&1
trap 'rm -rf "$TMP"' EXIT
HB_TMP="$(mktemp -d "$PWD/.test-watcher-heartbeat.XXXXXX")"
old_home="$OSRC_HOME"; OSRC_HOME="$HB_TMP"; OSRC_JOBS="$HB_TMP/jobs"
OSRC_WAKE_QUEUE="$HB_TMP/wake-queue.jsonl"; OSRC_WAKE_ACK="$HB_TMP/wake-acks.jsonl"
OSRC_FLEET_SNAPSHOT="$HB_TMP/fleet-snapshot.json"; OSRC_HEARTBEAT="$HB_TMP/heartbeat"
_state_sync() { return 0; }
_fleet_snapshot_collect() {
  count="$(cat "$HB_TMP/collect.count" 2>/dev/null || echo 0)"
  count=$((count + 1)); printf '%s\n' "$count" > "$HB_TMP/collect.count"
  jq -cn --arg generation "$(cat "$HB_TMP/generation")" \
    '{schema_version:"1",generation:$generation,captured_at:"now",items:[]}'
}
printf '%s\n' generation-1 > "$HB_TMP/generation"
OSRC_HEARTBEAT_SINK="$HB_TMP/attached.log"; : > "$OSRC_HEARTBEAT_SINK"
_heartbeat_tick; _heartbeat_tick
[ "$(cat "$HB_TMP/collect.count")" = 2 ] \
  && ok "each heartbeat tick collects exactly one snapshot" \
  || bad "a heartbeat tick collected more than one snapshot"
[ "$(wc -l < "$HB_TMP/heartbeat/heartbeat.log" | tr -d ' ')" = 1 ] \
  && [ "$(wc -l < "$HB_TMP/attached.log" | tr -d ' ')" = 1 ] \
  && ok "unchanged generations are deduped across durable and attached sinks" \
  || bad "an unchanged generation emitted more than one line"

printf '%s\n' generation-2 > "$HB_TMP/generation"
OSRC_HEARTBEAT_SINK="$HB_TMP/missing/sink" _heartbeat_tick >/dev/null 2>&1 || true
pending="$(_wake_drain)"
[ "$(wc -l < "$HB_TMP/heartbeat/heartbeat.log" | tr -d ' ')" = 2 ] \
  && printf '%s' "$pending" | grep -q 'heartbeat-sink' \
  && ok "attached sink loss preserves the log and records unknown" \
  || bad "attached sink loss erased delivery or failed to surface unknown"
rm -rf "$HB_TMP"
OSRC_HOME="$old_home"

awk '/^_bg_launch\(\)/,/^}/' "$SRC" | grep -q '_heartbeat_start' \
  && ok "successful background launches auto-arm heartbeat" \
  || bad "background launch does not auto-arm heartbeat"
[ "$(grep -c '_heartbeat_start.*supervision state is unknown' "$SRC")" -ge 3 ] \
  && ok "background and interactive launch paths share heartbeat auto-arm" \
  || bad "one or more successful launch paths omit heartbeat auto-arm"
grep -q 'OSRC_HEARTBEAT_CADENCE:-120' "$SRC" \
  && ok "heartbeat cadence defaults to 120 seconds (~2min pulse; push-on-by-default)" \
  || bad "heartbeat cadence default is not 120 seconds"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
