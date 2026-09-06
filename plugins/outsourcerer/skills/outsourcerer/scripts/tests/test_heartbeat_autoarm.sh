#!/usr/bin/env bash
# test_heartbeat_autoarm.sh — bg, fanout, and session launches arm supervision in the same turn
# with no opt-in required, and OSRC_FLEET_SUPERVISION=0 still opts out silently
# (SPEC heartbeat-liveness B + escape-hatch constraint).
#
# What is pinned here:
#   1. cmd_bg on the local lane auto-arms: owner.json exists after launch and its pid is alive.
#   2. A two-task cmd_fanout on the local lane arms from the parent turn (owner pid alive).
#   3. OSRC_FLEET_SUPERVISION=0 bg: NO owner.json, NO NOT-ARMED, $jd/supervision = opted-out.
#   4. `heartbeat start` CLI: rc 0 + verified-live message when armable; rc 1 + NOT-ARMED when the
#      executable is sabotaged; rc 2 + opted-out message when OSRC_FLEET_SUPERVISION=0.
#   5. `fleet supervise` routes to the same arm path (no longer the reserved rc-2 stub).
# 6. rc 2 names the RIGHT escape hatch (hardening): OSRC_HEARTBEAT_DISABLED=1 and
#      OSRC_FLEET_SUPERVISION=0 are different knobs, and the message must not misattribute.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d "$PWD/.test-heartbeat-autoarm.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
export HOME="$TMP/home"
mkdir -p "$OSRC_HOME/sessions" "$HOME"

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

# A fake beacon binary: writes owner.json for its own pid, then stays alive. HB_PID_START pins the
# identity for in-shell tests that mock _pid_start_identity; unset = use the real ps identity
# (for black-box subprocess runs).
FAKE_BEACON="$TMP/fake-beacon.sh"
cat > "$FAKE_BEACON" <<'SH'
#!/usr/bin/env bash
hb="${OSRC_HEARTBEAT:-${OSRC_HOME:?}/heartbeat}"
# Normalize exactly like _pid_start_identity does (LC_ALL=C, trimmed, single-spaced) so a
# black-box parent's leader check matches what the beacon records.
start="$(LC_ALL=C ps -o lstart= -p $$ 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g')"
start="${HB_PID_START:-$start}"
mkdir -p "$hb/leader"
# Claim under the token the arm passed (OSRC_HEARTBEAT_TOKEN / argv $2): the fresh-spawn confirm
# loop requires owner.json.token to equal the caller's token.
token="${OSRC_HEARTBEAT_TOKEN:-${2:-autoarm}}"
jq -cn --argjson pid "$$" --arg ps "$start" --arg token "$token" '{pid:$pid,pid_start:$ps,token:$token}' > "$hb/leader/owner.json"
sleep 30
SH
chmod +x "$FAKE_BEACON"

# A fake job supervisor: the detached __runjob child exits instantly; the arm is what we test.
FAKE_JOB="$TMP/fake-runjob.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_JOB"
chmod +x "$FAKE_JOB"

kill_beacon() { # <owner.json> — stop the fake beacon a test armed
  local p; p="$(jq -r '.pid // empty' "$1" 2>/dev/null)"
  [ -n "$p" ] && kill "$p" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 1. cmd_bg on the local lane with OSRC_FLEET_SUPERVISION unset -> owner.json exists after launch
#    and its pid passes kill -0. (SCRIPT_PATH is faked so the route preflight re-exec and the
#    detached __runjob child are instant no-ops; the launch + arm machinery is the real thing.)
(
  set --
  export OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  _state_sync(){ return 0; }
  _pid_start_identity(){ printf 'Thu Jul 31 01:02:03 2026\n'; }
  PROVIDER=local
  SCRIPT_PATH="$FAKE_JOB"
  export OSRC_HEARTBEAT_EXECUTABLE="$FAKE_BEACON" OSRC_HEARTBEAT_START_TIMEOUT=3 HB_PID_START="Thu Jul 31 01:02:03 2026"
  unset OSRC_FLEET_SUPERVISION
  cmd_bg run "task" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: cmd_bg rc=$rc"; exit 1; }
  owner="$OSRC_HEARTBEAT/leader/owner.json"
  [ -f "$owner" ] || { echo "FAIL: no owner.json after bg launch (auto-arm did not run)"; exit 1; }
  vpid="$(jq -r '.pid' "$owner")"
  kill -0 "$vpid" || { echo "FAIL: armed beacon pid $vpid is not alive"; exit 1; }
  kill_beacon "$owner"
  exit 0
) && ok "bg run auto-arms supervision in the same turn (no opt-in)" \
  || bad "bg run did not auto-arm a live beacon"

# ---------------------------------------------------------------------------
# 2. Two-task fanout on the local lane -> the beacon is armed from the PARENT turn (owner pid
#    alive before members finish), not hidden inside a member's command substitution.
(
  set --
  export OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  _state_sync(){ return 0; }
  _pid_start_identity(){ printf 'Thu Jul 31 01:02:03 2026\n'; }
  PROVIDER=local
  SCRIPT_PATH="$FAKE_JOB"
  export OSRC_HEARTBEAT_EXECUTABLE="$FAKE_BEACON" OSRC_HEARTBEAT_START_TIMEOUT=3 HB_PID_START="Thu Jul 31 01:02:03 2026"
  unset OSRC_FLEET_SUPERVISION
  cmd_fanout -- "t1" "t2" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: cmd_fanout rc=$rc"; exit 1; }
  owner="$OSRC_HEARTBEAT/leader/owner.json"
  [ -f "$owner" ] || { echo "FAIL: no owner.json after fanout (parent arm did not run)"; exit 1; }
  vpid="$(jq -r '.pid' "$owner")"
  kill -0 "$vpid" || { echo "FAIL: fanout-armed beacon pid $vpid is not alive"; exit 1; }
  kill_beacon "$owner"
  exit 0
) && ok "fanout arms supervision once in the parent turn" \
  || bad "fanout parent-turn arm broken"

# ---------------------------------------------------------------------------
# 3. OSRC_FLEET_SUPERVISION=0 bg run -> NO owner.json, NO NOT-ARMED on stderr, and
#    $jd/supervision = opted-out. The escape hatch is silent.
(
  set --
  export OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  _state_sync(){ return 0; }
  _pid_start_identity(){ printf 'Thu Jul 31 01:02:03 2026\n'; }
  PROVIDER=local
  SCRIPT_PATH="$FAKE_JOB"
  export OSRC_HEARTBEAT_EXECUTABLE="$FAKE_BEACON" OSRC_FLEET_SUPERVISION=0
  rm -rf "$OSRC_HEARTBEAT/leader" 2>/dev/null || true   # no leader claim may leak in from earlier blocks
  out="$(_bg_launch run "task" 2>"$TMP/opt.err")"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: _bg_launch rc=$rc under opt-out"; exit 1; }
  [ -f "$OSRC_HEARTBEAT/leader/owner.json" ] && { echo "FAIL: beacon armed despite OSRC_FLEET_SUPERVISION=0"; exit 1; }
  grep -qi 'not-armed' "$TMP/opt.err" && { echo "FAIL: NOT-ARMED warning fired under opt-out"; exit 1; }
  [ "$(cat "$OSRC_JOBS/$out/supervision" 2>/dev/null)" = "opted-out" ] || { echo "FAIL: \$jd/supervision is not 'opted-out'"; exit 1; }
  exit 0
) && ok "OSRC_FLEET_SUPERVISION=0 opts out silently with a durable opted-out marker" \
  || bad "escape hatch is not silent / not durable"

# ---------------------------------------------------------------------------
# 4. `heartbeat start` CLI, black-box: rc 0 + verified-live message when armable; rc 1 + NOT-ARMED
#    when the executable is sabotaged; rc 2 + opted-out message under OSRC_FLEET_SUPERVISION=0.
(
  h1="$TMP/hb-ok"
  mkdir -p "$h1"
  out="$(OSRC_HOME="$h1" OSRC_HEARTBEAT_DISABLED=0 OSRC_HEARTBEAT_EXECUTABLE="$FAKE_BEACON" OSRC_HEARTBEAT_START_TIMEOUT=3 \
    bash "$SRC" heartbeat start 2>"$TMP/hb-ok.err")"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: heartbeat start rc=$rc"; exit 1; }
  printf '%s' "$out" | grep -q 'verified live' || { echo "FAIL: no verified-live message: $out"; exit 1; }
  kill_beacon "$h1/heartbeat/leader/owner.json"
  # Sabotaged executable -> rc 1 + NOT-ARMED, and no positive armed claim.
  h2="$TMP/hb-dead"
  mkdir -p "$h2"
  err="$(OSRC_HOME="$h2" OSRC_HEARTBEAT_DISABLED=0 OSRC_HEARTBEAT_EXECUTABLE="$TMP/no-such-beacon" OSRC_HEARTBEAT_START_TIMEOUT=1 \
    bash "$SRC" heartbeat start 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -eq 1 ] || { echo "FAIL: sabotaged heartbeat start rc=$rc (expected 1)"; exit 1; }
  printf '%s' "$err" | grep -q 'NOT-ARMED' || { echo "FAIL: no NOT-ARMED on stderr"; exit 1; }
  claim="$(printf '%s' "$err" | grep -i 'armed' | grep -vi 'not-armed')"
  [ -z "$claim" ] || { echo "FAIL: positive armed claim: $claim"; exit 1; }
  # Opted out -> rc 2 + explicit message, never NOT-ARMED.
  h3="$TMP/hb-opt"
  mkdir -p "$h3"
  out="$(OSRC_HOME="$h3" OSRC_HEARTBEAT_DISABLED=0 OSRC_FLEET_SUPERVISION=0 bash "$SRC" heartbeat start 2>"$TMP/hb-opt.err")"; rc=$?
  [ "$rc" -eq 2 ] || { echo "FAIL: opted-out heartbeat start rc=$rc (expected 2)"; exit 1; }
  printf '%s' "$out" | grep -q 'opted out via OSRC_FLEET_SUPERVISION=0' || { echo "FAIL: no opted-out message: $out"; exit 1; }
  grep -qi 'not-armed' "$TMP/hb-opt.err" && { echo "FAIL: NOT-ARMED fired under opt-out"; exit 1; }
  exit 0
) && ok "heartbeat start CLI: rc 0 verified / rc 1 NOT-ARMED / rc 2 silent opt-out" \
  || bad "heartbeat start CLI contract broken"

# ---------------------------------------------------------------------------
# 5. `fleet supervise` routes to the same arm path: rc 0 + verified message on a fresh home
#    (the old _fleet_todo stub returned 2 "reserved for a sibling track").
(
  h="$TMP/hb-supervise"
  mkdir -p "$h"
  out="$(OSRC_HOME="$h" OSRC_HEARTBEAT_DISABLED=0 OSRC_HEARTBEAT_EXECUTABLE="$FAKE_BEACON" OSRC_HEARTBEAT_START_TIMEOUT=3 \
    bash "$SRC" fleet supervise 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: fleet supervise rc=$rc"; exit 1; }
  printf '%s' "$out" | grep -q 'verified live' || { echo "FAIL: fleet supervise did not arm: $out"; exit 1; }
  printf '%s' "$out" | grep -q 'reserved for a sibling track' && { echo "FAIL: still the reserved stub"; exit 1; }
  kill_beacon "$h/heartbeat/leader/owner.json"
  exit 0
) && ok "fleet supervise routes to the verified arm path" \
  || bad "fleet supervise does not arm supervision"

# ---------------------------------------------------------------------------
# 6. rc 2 names the RIGHT escape hatch (hardening): with OSRC_HEARTBEAT_DISABLED=1 the message
#    must blame OSRC_HEARTBEAT_DISABLED=1, never OSRC_FLEET_SUPERVISION=0 (the old message was
#    unconditional and misattributed the knob).
(
  h="$TMP/hb-opt-disabled"
  mkdir -p "$h"
  out="$(OSRC_HOME="$h" OSRC_HEARTBEAT_DISABLED=1 bash "$SRC" heartbeat start 2>"$TMP/hb-dis.err")"; rc=$?
  [ "$rc" -eq 2 ] || { echo "FAIL: disabled heartbeat start rc=$rc (expected 2)"; exit 1; }
  printf '%s' "$out" | grep -q 'opted out via OSRC_HEARTBEAT_DISABLED=1' \
    || { echo "FAIL: rc 2 message does not name OSRC_HEARTBEAT_DISABLED=1: $out"; exit 1; }
  printf '%s' "$out" | grep -q 'OSRC_FLEET_SUPERVISION=0' \
    && { echo "FAIL: rc 2 message misattributes to OSRC_FLEET_SUPERVISION=0: $out"; exit 1; }
  grep -qi 'not-armed' "$TMP/hb-dis.err" && { echo "FAIL: NOT-ARMED fired while disabled"; exit 1; }
  # The other knob still renders its own name (no regression in the FLEET_SUPERVISION branch).
  h2="$TMP/hb-opt-fs"
  mkdir -p "$h2"
  out="$(OSRC_HOME="$h2" OSRC_HEARTBEAT_DISABLED=0 OSRC_FLEET_SUPERVISION=0 bash "$SRC" heartbeat start 2>/dev/null)"; rc=$?
  [ "$rc" -eq 2 ] || { echo "FAIL: FLEET_SUPERVISION=0 heartbeat start rc=$rc (expected 2)"; exit 1; }
  printf '%s' "$out" | grep -q 'opted out via OSRC_FLEET_SUPERVISION=0' \
    || { echo "FAIL: rc 2 message does not name OSRC_FLEET_SUPERVISION=0: $out"; exit 1; }
  exit 0
) && ok "rc 2 distinguishes OSRC_HEARTBEAT_DISABLED=1 from OSRC_FLEET_SUPERVISION=0" \
  || bad "rc 2 opt-out message misattributes the knob"

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
