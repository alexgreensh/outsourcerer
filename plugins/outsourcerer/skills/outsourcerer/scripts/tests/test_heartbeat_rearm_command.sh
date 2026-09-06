#!/usr/bin/env bash
# test_heartbeat_rearm_command.sh — the manual re-arm path the tool's own messages point at is
# real (SPEC heartbeat-liveness A/B glue). Three messages tell the user to run `$0 heartbeat
# start` (interactive launch failure, relaunch, effort relaunch); before this fix the command did
# not exist and the pointer was dead.
#
# What is pinned here:
#   1. Every remediation message in the source prints a command this script actually dispatches.
#   2. `heartbeat start` (black-box) arms and verifies on a fresh home: rc 0 + verified-live.
#   3. `heartbeat status` reports leader liveness (live -> 0, none -> 1 with a remediation hint).
#   4. An unknown heartbeat subcommand dies with usage.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d "$PWD/.test-heartbeat-rearm.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
export HOME="$TMP/home"
mkdir -p "$OSRC_HOME/sessions" "$HOME"

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

FAKE_BEACON="$TMP/fake-beacon.sh"
cat > "$FAKE_BEACON" <<'SH'
#!/usr/bin/env bash
hb="${OSRC_HEARTBEAT:-${OSRC_HOME:?}/heartbeat}"
# Normalize exactly like _pid_start_identity does (LC_ALL=C, trimmed, single-spaced).
start="$(LC_ALL=C ps -o lstart= -p $$ 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g')"
mkdir -p "$hb/leader"
# Claim under the token the arm passed (OSRC_HEARTBEAT_TOKEN / argv $2): the fresh-spawn confirm
# loop requires owner.json.token to equal the caller's token.
token="${OSRC_HEARTBEAT_TOKEN:-${2:-rearm}}"
jq -cn --argjson pid "$$" --arg ps "$start" --arg token "$token" '{pid:$pid,pid_start:$ps,token:$token}' > "$hb/leader/owner.json"
sleep 30
SH
chmod +x "$FAKE_BEACON"

kill_beacon() {
  local p; p="$(jq -r '.pid // empty' "$1" 2>/dev/null)"
  [ -n "$p" ] && kill "$p" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 1. The remediation pointers are real: every "heartbeat start" the messages print must resolve
#    through the main dispatch (a heartbeat subcommand exists and handles start|status).
(
  # The messages that point at `$0 heartbeat start` still exist...
  grep -q 'Arm it with: %s heartbeat start' "$SRC" || { echo "FAIL: remediation messages were removed"; exit 1; }
  # ...and the command they name is dispatched (not a dead pointer).
  awk '/^main\(\)/,0' "$SRC" | grep -q 'heartbeat)[[:space:]]*cmd_heartbeat' \
    || { echo "FAIL: heartbeat is not wired into the main dispatch"; exit 1; }
  grep -q 'supervise) cmd_heartbeat start' "$SRC" || { echo "FAIL: fleet supervise does not route to the arm path"; exit 1; }
  exit 0
) && ok "remediation pointers reference a dispatched command" \
  || bad "heartbeat remediation pointer is dead"

# ---------------------------------------------------------------------------
# 2. `heartbeat start` (black-box, the exact string the messages print) arms + verifies: rc 0.
(
  h="$TMP/hb-start"
  mkdir -p "$h"
  out="$(OSRC_HOME="$h" OSRC_HEARTBEAT_DISABLED=0 OSRC_HEARTBEAT_EXECUTABLE="$FAKE_BEACON" OSRC_HEARTBEAT_START_TIMEOUT=3 \
    bash "$SRC" heartbeat start 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: heartbeat start rc=$rc"; exit 1; }
  printf '%s' "$out" | grep -q 'supervision armed, beacon pid .* verified live' \
    || { echo "FAIL: unexpected output: $out"; exit 1; }
  kill_beacon "$h/heartbeat/leader/owner.json"
  exit 0
) && ok "heartbeat start arms and verifies (rc 0)" \
  || bad "heartbeat start does not arm"

# ---------------------------------------------------------------------------
# 3. `heartbeat status` reports leader liveness from _heartbeat_leader_alive.
(
  # No leader -> rc 1 with a remediation hint.
  h="$TMP/hb-status-empty"
  mkdir -p "$h"
  out="$(OSRC_HOME="$h" OSRC_HEARTBEAT_DISABLED=0 bash "$SRC" heartbeat status 2>/dev/null)"; rc=$?
  [ "$rc" -eq 1 ] || { echo "FAIL: status with no leader rc=$rc (expected 1)"; exit 1; }
  printf '%s' "$out" | grep -q 'no verified-live heartbeat leader' || { echo "FAIL: unexpected empty-home output: $out"; exit 1; }
  # A live leader (arm first, then ask) -> rc 0 and the pid is named.
  h2="$TMP/hb-status-live"
  mkdir -p "$h2"
  OSRC_HOME="$h2" OSRC_HEARTBEAT_DISABLED=0 OSRC_HEARTBEAT_EXECUTABLE="$FAKE_BEACON" OSRC_HEARTBEAT_START_TIMEOUT=3 \
    bash "$SRC" heartbeat start >/dev/null 2>&1 || { echo "FAIL: could not arm for status"; exit 1; }
  vpid="$(jq -r '.pid' "$h2/heartbeat/leader/owner.json")"
  out="$(OSRC_HOME="$h2" OSRC_HEARTBEAT_DISABLED=0 bash "$SRC" heartbeat status 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: status with a live leader rc=$rc"; exit 1; }
  printf '%s' "$out" | grep -q "pid $vpid verified live" || { echo "FAIL: status output missing the live pid: $out"; exit 1; }
  kill_beacon "$h2/heartbeat/leader/owner.json"
  exit 0
) && ok "heartbeat status reports leader liveness honestly" \
  || bad "heartbeat status contract broken"

# ---------------------------------------------------------------------------
# 4. Unknown heartbeat subcommand dies with usage.
(
  h="$TMP/hb-usage"
  mkdir -p "$h"
  out="$(OSRC_HOME="$h" OSRC_HEARTBEAT_DISABLED=0 bash "$SRC" heartbeat frobnicate 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] || { echo "FAIL: unknown subcommand exited 0"; exit 1; }
  printf '%s' "$out" | grep -q 'heartbeat subcommand: start | status' || { echo "FAIL: no usage in error: $out"; exit 1; }
  exit 0
) && ok "unknown heartbeat subcommand dies with usage" \
  || bad "heartbeat usage handling broken"

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
