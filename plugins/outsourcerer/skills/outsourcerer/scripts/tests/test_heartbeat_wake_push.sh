#!/usr/bin/env bash
# test_heartbeat_wake_push.sh — the ACTIVE async push (OSRC_HEARTBEAT_WAKE) and the async-supervision
# guard. Root cause guarded: the beacon only ever WROTE a pulse to a tty/sink. A message-driven caller
# (one turn per inbound message, e.g. Miss Chief on WhatsApp) has no turn loop and never reads that tty,
# so delegated work went silent until the user pinged. The wake hook lets the beacon TRIGGER the caller's
# own notifier on state changes/digests; the guard warns at launch when a headless run has no push armed.
#
# Sharp both ways: the notifier must RECEIVE the event (summary as $1, JSON on stdin), must be a no-op
# when unset, must NOT let a malicious task summary inject shell, and must never gate/wedge the caller.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"
export OSRC_HOME="$TMP"
export HOME="$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

. "$SRC" >/dev/null 2>&1

for fn in _wake_notify_external _async_supervision_notice; do
  type "$fn" >/dev/null 2>&1 || { echo "FAIL: $fn not defined"; exit 1; }
done

evt='{"event_id":"e1","kind":"fleet-state","state":"blocked","task_summary":"GLM wedged at step 2/4"}'

# ---------------------------------------------------------------- no-op when unset
unset OSRC_HEARTBEAT_WAKE
rm -f "$TMP/fired"
_wake_notify_external "$evt"
[ -e "$TMP/fired" ] && bad "notifier ran with OSRC_HEARTBEAT_WAKE unset" || ok "notifier is a no-op when no wake command is armed"

# ---------------------------------------------------------------- fires + receives contract
export OSRC_HEARTBEAT_WAKE='printf "%s\n" "$1" > "$OSRC_HOME/arg1"; cat > "$OSRC_HOME/stdin"'
rm -f "$TMP/arg1" "$TMP/stdin"
_wake_notify_external "$evt"
# the notifier is backgrounded + bounded; give it a beat, polling rather than a fixed long sleep
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/arg1" ] && [ -s "$TMP/stdin" ] && break; sleep 0.2; done
if grep -q "GLM wedged at step 2/4" "$TMP/arg1" 2>/dev/null; then ok "notifier receives the compact summary as \$1"
else bad "notifier did not receive the summary as \$1 (got: $(cat "$TMP/arg1" 2>/dev/null))"; fi
if grep -q '"event_id":"e1"' "$TMP/stdin" 2>/dev/null; then ok "notifier receives the full event JSON on stdin"
else bad "notifier did not receive the event JSON on stdin"; fi

# ---------------------------------------------------------------- injection safety
# A task summary containing shell metacharacters must NOT execute — it is data, never part of the cmd.
export OSRC_HEARTBEAT_WAKE='cat > /dev/null'   # benign consumer; the payload must not run on its own
rm -f "$TMP/PWNED"
evil='{"event_id":"e2","state":"blocked","task_summary":"x\"; touch '"$TMP"'/PWNED; echo \""}'
_wake_notify_external "$evil"
sleep 0.6
[ -e "$TMP/PWNED" ] && bad "a malicious task summary injected shell (PWNED created)" || ok "task summary is data, not code — no injection"

# ---------------------------------------------------------------- async-supervision guard
# Guard is about the headless case; under a tty it must stay quiet. In this test harness stdin/out/err
# are pipes (not ttys), so the headless branch is exercised directly.
unset OSRC_HEARTBEAT_WAKE OSRC_HEARTBEAT_SINK
out="$(_async_supervision_notice 2>&1)"
case "$out" in *"ASYNC SUPERVISION"*) ok "guard warns when headless with no wake/sink armed" ;; *) bad "guard did not warn in the headless no-wake case: '$out'" ;; esac

export OSRC_HEARTBEAT_WAKE='true'
out="$(_async_supervision_notice 2>&1)"
[ -z "$out" ] && ok "guard is silent once a wake command is armed" || bad "guard still warned with a wake armed: '$out'"

unset OSRC_HEARTBEAT_WAKE
export OSRC_HEARTBEAT_SINK="$TMP/sink"; : > "$OSRC_HEARTBEAT_SINK"
out="$(_async_supervision_notice 2>&1)"
[ -z "$out" ] && ok "guard is silent once an explicit sink is armed" || bad "guard still warned with a sink armed: '$out'"

unset OSRC_HEARTBEAT_SINK
export OSRC_FLEET_SUPERVISION=0
out="$(_async_supervision_notice 2>&1)"
[ -z "$out" ] && ok "guard respects supervision opt-out" || bad "guard warned despite OSRC_FLEET_SUPERVISION=0: '$out'"
unset OSRC_FLEET_SUPERVISION

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
