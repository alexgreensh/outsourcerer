#!/usr/bin/env bash
# test_heartbeat_arm_liveness.sh — nothing claims "armed"/"supervised" unless the watcher PID is
# verified alive (SPEC heartbeat-liveness A).
#
# What is pinned here:
#   1. A verified-live leader makes _heartbeat_arm_verify return 0 (and the verified pid is
#      reportable via `heartbeat start`).
#   2. A dead-pid owner.json + an instantly-exiting fake beacon -> rc 1, a loud greppable
#      NOT-ARMED line, and NEVER a positive "armed" claim.
#   3. A leader that dies between arm and verify gets EXACTLY ONE re-arm attempt, then NOT-ARMED.
#   4. A re-arm that succeeds on the second try returns rc 0 -- the retry is real, not decorative.
#   5. Static: the winpty session path arms BEFORE it prints "Started winpty session", the old
#      soft `|| echo` fallback is gone everywhere, and the winpty path writes the durable
# supervision marker like the bg path (hardening parity).
#   6. _bg_launch with a sabotaged beacon: the job id is still minted (stdout is ONLY the id),
#      stderr carries NOT-ARMED, and $jd/supervision durably records not-armed. A LATER verified
# arm stops the false !SUPERVISION:NOT-ARMED flag (hardening: the marker is re-evaluated,
#      not trusted forever).
# 7. Zombie leader (hardening): a dead-but-unreaped beacon passes kill -0 AND matches its
#      recorded pid_start (same process -- macOS keeps the ps row and lstart), so only the
#      `ps -o stat=` state check can reject it. _heartbeat_leader_alive must return 1 and
#      _heartbeat_arm_verify must go loud NOT-ARMED, never "verified live".
# 8. Beacon IDENTITY binding: a forged owner.json pinning a live same-uid NON-beacon
#      pid (perfect pid+pid_start) is NOT "verified live" — `heartbeat status`/`heartbeat start`
#      refuse it, and the same record passes only once the pid's ps command shows the
#      __heartbeat-beacon argv (via the OSRC_TEST_PS_ARGV seam).
# 9. Fresh-spawn token binding: the confirm loop requires owner_pid==child_pid AND
#      owner.json.token==$token; a claim with a wrong token, and a forged record naming another
#      live pid with the right token, both fail to confirm.
# 10. Join path: a pre-existing leader (different token, beacon argv) is still joined
#      through the argv-bound liveness gate.
# 11. Zombie eviction + confirm-loop refusal: a leader whose ps stat= begins with Z
#      is evicted as provably dead (kill -0 alone would wedge supervision NOT-ARMED forever), a
#      live (stat S) leader is never evicted, and the confirm loop refuses a zombie-claimed pid.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d "$PWD/.test-heartbeat-armlive.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
export HOME="$TMP/home"
mkdir -p "$OSRC_HOME/sessions" "$HOME"

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

dead_pid=999999
while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid - 1)); done

# A fake beacon binary: writes owner.json for its own pid (pid_start either fixed by the caller's
# mocked _pid_start_identity via HB_PID_START, or read from the real ps) then stays alive.
# OSRC_HEARTBEAT is a plain (non-exported) shell var in the sourced script, so the fallback keeps
# the beacon working whether or not the caller exported it.
FAKE_BEACON="$TMP/fake-beacon.sh"
cat > "$FAKE_BEACON" <<'SH'
#!/usr/bin/env bash
hb="${OSRC_HEARTBEAT:-${OSRC_HOME:?}/heartbeat}"
start="${HB_PID_START:-$(ps -o lstart= -p $$ 2>/dev/null | sed 's/^ *//; s/ *$//')}"
mkdir -p "$hb/leader"
# The token this beacon claims with MUST be the one the arm passed (OSRC_HEARTBEAT_TOKEN, or $2
# of the __heartbeat-beacon argv): the fresh-spawn confirm loop requires owner.json.token to
# equal the caller's token.
token="${OSRC_HEARTBEAT_TOKEN:-${2:-arm-liveness}}"
jq -cn --argjson pid "$$" --arg ps "$start" --arg token "$token" '{pid:$pid,pid_start:$ps,token:$token}' > "$hb/leader/owner.json"
sleep 30
SH
chmod +x "$FAKE_BEACON"

# An instantly-exiting fake beacon: any spawn dies immediately (arm must fail closed).
DEAD_BEACON="$TMP/dead-beacon.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$DEAD_BEACON"
chmod +x "$DEAD_BEACON"

# A fake job supervisor for _bg_launch (the detached __runjob child exits instantly; we are testing
# the arm, not the job).
FAKE_JOB="$TMP/fake-runjob.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_JOB"
chmod +x "$FAKE_JOB"

# ---------------------------------------------------------------------------
# 1. Live leader present -> _heartbeat_arm_verify rc 0, and the verified pid is reportable.
(
  set --
  export OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  _state_sync(){ return 0; }
  _pid_start_identity(){ printf 'Thu Jul 31 01:02:03 2026\n'; }
  # Exported (not env-prefixed) so the spawned fake beacon child inherits the pinned identity.
  export OSRC_HEARTBEAT HB_PID_START="Thu Jul 31 01:02:03 2026" OSRC_HEARTBEAT_EXECUTABLE="$FAKE_BEACON" OSRC_HEARTBEAT_START_TIMEOUT=3
  _heartbeat_start || { echo "FAIL: could not arm against the fake beacon"; exit 1; }
  _heartbeat_arm_verify; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: arm_verify rc=$rc with a live leader"; exit 1; }
  vpid="$(jq -r '.pid' "$OSRC_HEARTBEAT/leader/owner.json")"
  kill -0 "$vpid" || { echo "FAIL: owner pid $vpid is not alive"; exit 1; }
  # The verified pid is reportable by the manual arm command.
  out="$(cmd_heartbeat start 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: heartbeat start rc=$rc"; exit 1; }
  printf '%s' "$out" | grep -q "beacon pid $vpid verified live" || { echo "FAIL: heartbeat start output missing verified pid: $out"; exit 1; }
  kill "$vpid" 2>/dev/null || true   # stop the fake beacon; later blocks must see a clean state
  exit 0
) && ok "live leader: arm verified (rc 0) and the verified pid is reportable" \
  || bad "arm verification failed with a live leader"

# ---------------------------------------------------------------------------
# 2. Dead-pid owner.json + instantly-exiting fake beacon -> rc 1, loud NOT-ARMED, never a positive
#    "armed" claim.
(
  set --
  export OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  _state_sync(){ return 0; }
  _pid_start_identity(){ printf 'Thu Jul 31 01:02:03 2026\n'; }
  owner="$OSRC_HEARTBEAT/leader/owner.json"
  mkdir -p "$(dirname "$owner")"
  jq -cn --argjson pid "$dead_pid" --arg ps "Thu Jul 31 01:02:03 2026" '{pid:$pid,pid_start:$ps,token:"dead"}' > "$owner"
  export OSRC_HEARTBEAT_EXECUTABLE="$DEAD_BEACON" OSRC_HEARTBEAT_START_TIMEOUT=1
  err="$(_heartbeat_arm_verify 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -eq 1 ] || { echo "FAIL: rc=$rc (expected 1)"; exit 1; }
  printf '%s' "$err" | grep -q 'NOT-ARMED' || { echo "FAIL: no NOT-ARMED on stderr"; exit 1; }
  # NEVER a false positive: any 'armed' mention that is NOT the NOT-ARMED warning is a claim.
  claim="$(printf '%s' "$err" | grep -i 'armed' | grep -vi 'not-armed')"
  [ -z "$claim" ] || { echo "FAIL: positive armed claim over a dead watcher: $claim"; exit 1; }
  exit 0
) && ok "dead watcher: rc 1, loud NOT-ARMED, no false armed claim" \
  || bad "dead-watcher path is not loud or claims armed"

# ---------------------------------------------------------------------------
# 3. Arm succeeds, then the leader is dead between arm and verify: EXACTLY ONE re-arm attempt,
#    then NOT-ARMED. First _heartbeat_start "arms" by planting a dead-pid owner.json (the fake
#    beacon died right after writing it); the verify then sees kill -0 fail.
(
  set --
  export OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  _state_sync(){ return 0; }
  _pid_start_identity(){ printf 'Thu Jul 31 01:02:03 2026\n'; }
  n_file="$TMP/arm-count-t3"; printf '0\n' > "$n_file"
  _heartbeat_start(){
    n="$(cat "$n_file")"; n=$((n+1)); printf '%s\n' "$n" > "$n_file"
    if [ "$n" -eq 1 ]; then
      mkdir -p "$OSRC_HEARTBEAT/leader"
      jq -cn --argjson pid "$dead_pid" --arg ps "Thu Jul 31 01:02:03 2026" '{pid:$pid,pid_start:$ps,token:"dying"}' > "$OSRC_HEARTBEAT/leader/owner.json"
      return 0
    fi
    return 1
  }
  export OSRC_HEARTBEAT_EXECUTABLE="$DEAD_BEACON" OSRC_HEARTBEAT_START_TIMEOUT=1
  err="$(_heartbeat_arm_verify 2>&1 >/dev/null)"; rc=$?
  n="$(cat "$n_file")"
  [ "$rc" -eq 1 ] || { echo "FAIL: rc=$rc (expected 1)"; exit 1; }
  [ "$n" -eq 2 ] || { echo "FAIL: _heartbeat_start called $n times (expected exactly 2 = 1 arm + 1 re-arm)"; exit 1; }
  printf '%s' "$err" | grep -q 'NOT-ARMED' || { echo "FAIL: no NOT-ARMED after the single re-arm"; exit 1; }
  exit 0
) && ok "leader dead between arm and verify: exactly ONE re-arm, then NOT-ARMED" \
  || bad "re-arm count wrong or missing NOT-ARMED"

# ---------------------------------------------------------------------------
# 4. Re-arm succeeds on the second try -> rc 0. The first arm leaves no live leader (fake died);
#    the second arms for real (claims a live leader). Proves the retry is real.
(
  set --
  export OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  _state_sync(){ return 0; }
  _pid_start_identity(){ printf 'Thu Jul 31 01:02:03 2026\n'; }
  # the "successful re-arm" plants a claim for $$ (a plain bash), so the beacon-argv
  # identity binding is satisfied through the OSRC_TEST_PS_ARGV seam (OSRC_TEST_MODE=1 only).
  export OSRC_TEST_MODE=1 OSRC_TEST_PS_ARGV="/bin/bash $SRC __heartbeat-beacon retry"
  n_file="$TMP/arm-count-t4"; printf '0\n' > "$n_file"
  _heartbeat_start(){
    n="$(cat "$n_file")"; n=$((n+1)); printf '%s\n' "$n" > "$n_file"
    if [ "$n" -ge 2 ]; then
      # The second arm "sticks": plant a live-leader claim (pid $$ is alive for the whole subshell).
      mkdir -p "$OSRC_HEARTBEAT/leader"
      jq -cn --argjson pid "$$" --arg ps "Thu Jul 31 01:02:03 2026" '{pid:$pid,pid_start:$ps,token:"retry"}' > "$OSRC_HEARTBEAT/leader/owner.json"
    fi
    return 0
  }
  rm -rf "$OSRC_HEARTBEAT/leader" 2>/dev/null || true   # clean slate: no claim from earlier blocks
  err="$(_heartbeat_arm_verify 2>&1 >/dev/null)"; rc=$?
  n="$(cat "$n_file")"
  [ "$rc" -eq 0 ] || { echo "FAIL: rc=$rc after a successful re-arm"; exit 1; }
  [ "$n" -eq 2 ] || { echo "FAIL: _heartbeat_start called $n times (expected 2)"; exit 1; }
  _heartbeat_leader_alive || { echo "FAIL: leader not alive after the successful re-arm"; exit 1; }
  exit 0
) && ok "re-arm succeeds on the second try: rc 0 after exactly one retry" \
  || bad "re-arm retry is not real"

# ---------------------------------------------------------------------------
# 5. Static: in the winpty start block the arm call precedes the "Started winpty session" print,
#    and the old soft `|| echo` arm fallback is gone from every launch path.
(
  print_line="$(grep -n 'Started winpty session' "$SRC" | head -1 | cut -d: -f1)"
  [ -n "$print_line" ] || { echo "FAIL: winpty start print not found"; exit 1; }
  arm_line="$(awk -v pl="$print_line" 'NR < pl && /_heartbeat_arm_verify/ { last = NR } END { print last + 0 }' "$SRC")"
  [ "$arm_line" -gt 0 ] || { echo "FAIL: no _heartbeat_arm_verify before the winpty print"; exit 1; }
  [ "$arm_line" -lt "$print_line" ] || { echo "FAIL: winpty arm (line $arm_line) is not before the print (line $print_line)"; exit 1; }
  grep -q '_heartbeat_start >/dev/null 2>&1 || echo "outsourcerer: heartbeat auto-arm unavailable' "$SRC" \
    && { echo "FAIL: the soft unverified arm fallback still exists"; exit 1; }
  # Winpty parity for the durable supervision marker (hardening): the session path must record
  # the arm outcome in $sdir/supervision like _bg_launch records it in $jd/supervision.
  grep -q 'not-armed > "$sdir/supervision"' "$SRC" || { echo "FAIL: winpty path writes no not-armed marker"; exit 1; }
  grep -q 'opted-out > "$sdir/supervision"' "$SRC" || { echo "FAIL: winpty path writes no opted-out marker"; exit 1; }
  exit 0
) && ok "winpty path arms before its success claim; soft arm fallback removed" \
  || bad "winpty ordering or soft-fallback static check failed"

# ---------------------------------------------------------------------------
# 6. _bg_launch with a sabotaged beacon executable: job id still minted, stdout ONLY the id,
#    stderr NOT-ARMED, $jd/supervision records not-armed, and status surfaces it.
(
  set --
  export OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  _state_sync(){ return 0; }
  _pid_start_identity(){ printf 'Thu Jul 31 01:02:03 2026\n'; }
  PROVIDER=local
  SCRIPT_PATH="$FAKE_JOB"
  export OSRC_HEARTBEAT_EXECUTABLE="$TMP/no-such-beacon" OSRC_HEARTBEAT_START_TIMEOUT=1
  rm -rf "$OSRC_HEARTBEAT/leader" 2>/dev/null || true   # no leader claim may leak in from earlier blocks
  out="$(_bg_launch run "task" 2>"$TMP/bg.err")"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: _bg_launch rc=$rc (launch must not fail)"; exit 1; }
  case "$out" in ''|*[!A-Za-z0-9-]*) echo "FAIL: stdout is not exactly a job id: '$out'"; exit 1 ;; esac
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "1" ] || { echo "FAIL: stdout is not a single line"; exit 1; }
  grep -q 'NOT-ARMED' "$TMP/bg.err" || { echo "FAIL: no NOT-ARMED on stderr"; exit 1; }
  claim="$(grep -i 'armed' "$TMP/bg.err" | grep -vi 'not-armed')"
  [ -z "$claim" ] || { echo "FAIL: positive armed claim: $claim"; exit 1; }
  [ "$(cat "$OSRC_JOBS/$out/supervision" 2>/dev/null)" = "not-armed" ] || { echo "FAIL: \$jd/supervision is not 'not-armed'"; exit 1; }
  # The durable marker surfaces on every status read while supervision is still not armed.
  _status_line "$out" 2>/dev/null | grep -q 'SUPERVISION:NOT-ARMED' || { echo "FAIL: status line does not surface SUPERVISION:NOT-ARMED"; exit 1; }
  # A LATER successful arm must stop the false flag (hardening): arm for real, then the same
  # stale marker no longer renders !SUPERVISION:NOT-ARMED -- status re-evaluates, never trusts
  # the marker file forever.
  export OSRC_HEARTBEAT_EXECUTABLE="$FAKE_BEACON" OSRC_HEARTBEAT_START_TIMEOUT=3 HB_PID_START="Thu Jul 31 01:02:03 2026"
  _heartbeat_arm_verify; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: follow-up arm rc=$rc (expected a verified arm)"; exit 1; }
  _status_line "$out" 2>/dev/null | grep -q 'SUPERVISION:NOT-ARMED' \
    && { echo "FAIL: !SUPERVISION:NOT-ARMED still rendered after a later verified arm"; exit 1; }
  [ "$(cat "$OSRC_JOBS/$out/supervision" 2>/dev/null)" = "not-armed" ] \
    || { echo "FAIL: the not-armed marker itself was disturbed by the later arm"; exit 1; }
  exit 0
) && ok "_bg_launch over a dead watcher: id minted, durable not-armed marker, stdout pure" \
  || bad "_bg_launch arm-failure handling broken"

# ---------------------------------------------------------------------------
# 7. Zombie leader (hardening): a real, unreaped corpse. The fixture execs a parent into
#    `sleep` (sleep never reaps) with a child that exits immediately, so the child's pid stays
#    in the process table with state Z. On macOS that corpse PASSES kill -0 and its lstart
#    equals its own pid_start (same process), so kill -0 + identity -- and therefore the old
#    check alone -- would call it "verified live" forever. _heartbeat_leader_alive must reject
#    it via the ps state check, and _heartbeat_arm_verify must go loud NOT-ARMED.
(
  set --
  export OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  _state_sync(){ return 0; }
  # NO _pid_start_identity mock here: the whole point is the real ps reads against a real corpse.
  zomb_dir="$TMP/zomb-f1"; mkdir -p "$zomb_dir"
  pid_file="$zomb_dir/zpid"
  ZOMB_SH="$zomb_dir/zombifier.sh"
  cat > "$ZOMB_SH" <<'SH'
#!/usr/bin/env bash
( exit 0 ) &                     # exits immediately; the exec'd parent below never reaps it
printf '%s\n' "$!" > "$ZPID_FILE"
exec sleep 20                    # sleep cannot wait(): the exited child stays a zombie
SH
  chmod +x "$ZOMB_SH"
  # The fixture is racy under load: the exiting subshell can be reaped by its parent bash before
  # the exec'd sleep takes over, leaving no corpse. Retry with a fresh zombifier until one
  # materializes (up to 5 attempts x ~5s of condition polling each).
  zomb_proc=""; zomb_pid=""
  attempt=0
  while [ "$attempt" -lt 5 ]; do
    ZPID_FILE="$pid_file" "$ZOMB_SH" &
    zomb_proc=$!
    zomb_pid=""
    i=0
    while [ "$i" -lt 50 ]; do
      zomb_pid="$(cat "$pid_file" 2>/dev/null || true)"
      if [ -n "$zomb_pid" ] && case "$(LC_ALL=C ps -o stat= -p "$zomb_pid" 2>/dev/null | sed 's/^[[:space:]]*//')" in Z*) true ;; *) false ;; esac; then
        break
      fi
      sleep 0.1
      i=$((i + 1))
    done
    case "$(LC_ALL=C ps -o stat= -p "$zomb_pid" 2>/dev/null | sed 's/^[[:space:]]*//')" in
      Z*) break ;;
    esac
    kill "$zomb_proc" 2>/dev/null || true; wait "$zomb_proc" 2>/dev/null || true
    attempt=$((attempt + 1))
  done
  case "$(LC_ALL=C ps -o stat= -p "$zomb_pid" 2>/dev/null | sed 's/^[[:space:]]*//')" in
    Z*) : ;;
    *) kill "$zomb_proc" 2>/dev/null || true; echo "FAIL: fixture failed, pid $zomb_pid is not a zombie (stat=$(LC_ALL=C ps -o stat= -p "$zomb_pid" 2>/dev/null))"; exit 1 ;;
  esac
  # Premise check: kill -0 SUCCEEDS on the zombie (this is the bug class -- the old check alone
  # could never see this death).
  kill -0 "$zomb_pid" 2>/dev/null || { kill "$zomb_proc" 2>/dev/null || true; echo "FAIL: premise broken, kill -0 failed on the zombie"; exit 1; }
  # Plant the zombie as the recorded leader with its REAL, normalized lstart as pid_start.
  zstart="$(LC_ALL=C ps -o lstart= -p "$zomb_pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g')"
  rm -rf "$OSRC_HEARTBEAT/leader" 2>/dev/null || true
  mkdir -p "$OSRC_HEARTBEAT/leader"
  jq -cn --argjson pid "$zomb_pid" --arg ps "$zstart" '{pid:$pid,pid_start:$ps,token:"zombie"}' > "$OSRC_HEARTBEAT/leader/owner.json"
  # The fix: the leader is a zombie -> NOT alive.
  _heartbeat_leader_alive && { kill "$zomb_proc" 2>/dev/null || true; echo "FAIL: a zombie leader passed _heartbeat_leader_alive"; exit 1; }
  # And the full arm gate goes loud NOT-ARMED (rc 1), never a verified-live claim.
  export OSRC_HEARTBEAT_EXECUTABLE="$DEAD_BEACON" OSRC_HEARTBEAT_START_TIMEOUT=1
  err="$(_heartbeat_arm_verify 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -eq 1 ] || { kill "$zomb_proc" 2>/dev/null || true; echo "FAIL: arm_verify rc=$rc over a zombie leader (expected 1)"; exit 1; }
  printf '%s' "$err" | grep -q 'NOT-ARMED' || { kill "$zomb_proc" 2>/dev/null || true; echo "FAIL: no NOT-ARMED over a zombie leader"; exit 1; }
  claim="$(printf '%s' "$err" | grep -i 'armed' | grep -vi 'not-armed')"
  [ -z "$claim" ] || { kill "$zomb_proc" 2>/dev/null || true; echo "FAIL: positive armed claim over a zombie: $claim"; exit 1; }
  kill "$zomb_proc" 2>/dev/null || true   # ends the unreaping parent; launchd reaps the corpse
  exit 0
) && ok "zombie leader: kill -0 + identity pass, yet liveness rejects it and the arm goes NOT-ARMED" \
  || bad "zombie liveness check broken (F1)"

# ---------------------------------------------------------------------------
# 8. Beacon IDENTITY binding: a forged owner.json pinning a live
#    same-uid NON-beacon pid with a perfect pid+pid_start used to certify "verified live" at every
#    claim site. The liveness proof must additionally bind the pid's ps command to the
#    __heartbeat-beacon argv this script spawns. No real process is forked: the pid named is this
#    subshell's own $$, and the beacon argv is exercised through the OSRC_TEST_PS_ARGV seam
#    (OSRC_TEST_MODE=1 only) -- first ABSENT (forged non-beacon command), then set (real beacon).
(
  set --
  export OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  _state_sync(){ return 0; }
  _pid_start_identity(){ printf 'Thu Jul 31 01:02:03 2026\n'; }
  # Forged record: pid = $$ (live, same-uid), exact pid_start per the mocked identity adapter.
  rm -rf "$OSRC_HEARTBEAT/leader" 2>/dev/null || true
  mkdir -p "$OSRC_HEARTBEAT/leader"
  jq -cn --argjson pid "$$" --arg ps "Thu Jul 31 01:02:03 2026" '{pid:$pid,pid_start:$ps,token:"forged"}' > "$OSRC_HEARTBEAT/leader/owner.json"
  # No argv seam: the pid's ps command is this test's bash -- NOT a beacon. Liveness must refuse.
  _heartbeat_leader_alive && { echo "FAIL: forged non-beacon owner verified live"; exit 1; }
  out="$(cmd_heartbeat status 2>/dev/null)"; rc=$?
  [ "$rc" -eq 1 ] || { echo "FAIL: heartbeat status rc=$rc over a forgery (expected 1)"; exit 1; }
  printf '%s' "$out" | grep -q 'no verified-live heartbeat leader' || { echo "FAIL: status claimed liveness over a forgery: $out"; exit 1; }
  # And the full arm gate goes loud NOT-ARMED (rc 1) -- never a positive "armed" claim.
  export OSRC_HEARTBEAT_EXECUTABLE="$DEAD_BEACON" OSRC_HEARTBEAT_START_TIMEOUT=1
  err="$(_heartbeat_arm_verify 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -eq 1 ] || { echo "FAIL: arm_verify rc=$rc over a forged owner (expected 1)"; exit 1; }
  printf '%s' "$err" | grep -q 'NOT-ARMED' || { echo "FAIL: no NOT-ARMED over a forged owner"; exit 1; }
  claim="$(printf '%s' "$err" | grep -i 'armed' | grep -vi 'not-armed')"
  [ -z "$claim" ] || { echo "FAIL: positive armed claim over a forged owner: $claim"; exit 1; }
  # The SAME record, now with the pid's ps command carrying the beacon argv (the seam stands in
  # for a genuinely spawned beacon): liveness accepts it -- the binding is identity, not blanket
  # refusal.
  export OSRC_TEST_MODE=1 OSRC_TEST_PS_ARGV="/bin/bash $SRC __heartbeat-beacon forged-seam"
  _heartbeat_leader_alive || { echo "FAIL: a live pid running the beacon argv was rejected"; exit 1; }
  exit 0
) && ok "forged non-beacon owner is never 'verified live'; the argv binding accepts a real beacon" \
  || bad "beacon identity binding broken"

# ---------------------------------------------------------------------------
# 9. Fresh-spawn token binding: the confirm loop must require owner_pid==child_pid AND
#    owner.json.token==$token.
#    9a: the spawned child claims with a token that is NOT the caller's -> never confirmed, the
#        child is killed, arm fails.
#    9b: a record naming a DIFFERENT live pid ($PPID) even WITH the correct token -> the join path
#        rejects it because the pid's ps command is not a beacon.
(
  set --
  export OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  _state_sync(){ return 0; }
  _pid_start_identity(){ printf 'Thu Jul 31 01:02:03 2026\n'; }
  # 9a: a beacon that claims under someone else's token.
  wrongtok="$TMP/wrong-token-beacon.sh"
  cat > "$wrongtok" <<'SH'
#!/usr/bin/env bash
hb="${OSRC_HEARTBEAT:-${OSRC_HOME:?}/heartbeat}"
start="${HB_PID_START:?}"
printf '%s\n' "$$" > "$HB_CHILD_PID"
mkdir -p "$hb/leader"
jq -cn --argjson pid "$$" --arg ps "$start" '{pid:$pid,pid_start:$ps,token:"forged-token"}' > "$hb/leader/owner.json"
sleep 30
SH
  chmod +x "$wrongtok"
  rm -rf "$OSRC_HEARTBEAT/leader" 2>/dev/null || true
  export OSRC_HEARTBEAT_EXECUTABLE="$wrongtok" OSRC_HEARTBEAT_START_TIMEOUT=1 HB_CHILD_PID="$TMP/wrong-token-child" HB_PID_START="Thu Jul 31 01:02:03 2026"
  _heartbeat_start >/dev/null 2>&1; rc=$?
  child="$(cat "$HB_CHILD_PID" 2>/dev/null || true)"
  [ -n "$child" ] && kill "$child" 2>/dev/null || true
  [ "$rc" -ne 0 ] || { echo "FAIL: _heartbeat_start confirmed a claim with a foreign token"; exit 1; }
  # 9b: forged record naming another live pid, but carrying the CORRECT token -- still refused,
  # because the join path accepts only an argv-bound beacon.
  notbeacon="$TMP/forged-other-pid-beacon.sh"
  cat > "$notbeacon" <<'SH'
#!/usr/bin/env bash
hb="${OSRC_HEARTBEAT:-${OSRC_HOME:?}/heartbeat}"
printf '%s\n' "$$" > "$HB_CHILD_PID"
mkdir -p "$hb/leader"
jq -cn --argjson pid "$PPID" --arg ps "${HB_PID_START:?}" --arg token "${OSRC_HEARTBEAT_TOKEN:?}" \
  '{pid:$pid,pid_start:$ps,token:$token}' > "$hb/leader/owner.json"
sleep 30
SH
  chmod +x "$notbeacon"
  rm -rf "$OSRC_HEARTBEAT/leader" 2>/dev/null || true
  export OSRC_HEARTBEAT_EXECUTABLE="$notbeacon" HB_CHILD_PID="$TMP/forged-other-pid-child" HB_PID_START="Thu Jul 31 01:02:03 2026"
  _heartbeat_start >/dev/null 2>&1; rc=$?
  child="$(cat "$HB_CHILD_PID" 2>/dev/null || true)"
  [ -n "$child" ] && kill "$child" 2>/dev/null || true
  [ "$rc" -ne 0 ] || { echo "FAIL: _heartbeat_start confirmed a forged record naming a live non-beacon pid"; exit 1; }
  exit 0
) && ok "confirm loop binds fresh-spawn claims to child pid + token; rejects forged non-beacon pids" \
  || bad "fresh-spawn confirm binding broken"

# ---------------------------------------------------------------------------
# 10. Join path: a pre-existing leader from an earlier arm carries a DIFFERENT token, so
#     the confirm loop accepts it through the argv-bound liveness gate instead. The fake beacon
#     does not claim for itself: it publishes a record naming its parent ($PPID, live) under the
#     earlier arm's token. With the OSRC_TEST_PS_ARGV seam marking that pid as a beacon, the arm
#     must confirm (join kept working); the forged-pid refusal without the seam is pinned in 9b.
(
  set --
  export OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  export OSRC_TEST_MODE=1 OSRC_TEST_PS_ARGV="/bin/bash $SRC __heartbeat-beacon earlier-arm"
  . "$SRC" >/dev/null 2>&1
  _state_sync(){ return 0; }
  _pid_start_identity(){ printf 'Thu Jul 31 01:02:03 2026\n'; }
  joiner="$TMP/joiner-beacon.sh"
  cat > "$joiner" <<'SH'
#!/usr/bin/env bash
hb="${OSRC_HEARTBEAT:-${OSRC_HOME:?}/heartbeat}"
printf '%s\n' "$$" > "$HB_CHILD_PID"
mkdir -p "$hb/leader"
# A pre-existing leader won the claim; our child joined it (claim rc 2) and exits.
jq -cn --argjson pid "$PPID" --arg ps "${HB_PID_START:?}" '{pid:$pid,pid_start:$ps,token:"earlier-arm-token"}' > "$hb/leader/owner.json"
exit 0
SH
  chmod +x "$joiner"
  rm -rf "$OSRC_HEARTBEAT/leader" 2>/dev/null || true
  export OSRC_HEARTBEAT_EXECUTABLE="$joiner" OSRC_HEARTBEAT_START_TIMEOUT=1 HB_CHILD_PID="$TMP/joiner-child" HB_PID_START="Thu Jul 31 01:02:03 2026"
  _heartbeat_start >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: _heartbeat_start rc=$rc joining a pre-existing leader (expected 0)"; exit 1; }
  exit 0
) && ok "join path still arms against a pre-existing leader through the argv-bound gate" \
  || bad "join path broken"

# ---------------------------------------------------------------------------
# 11. Zombie eviction + confirm-loop refusal: a zombie PASSES kill -0 and keeps its
#     lstart, so the old kill -0 eviction never fired and supervision wedged NOT-ARMED forever.
#     No real corpse is forked: the ps stat= is injected with OSRC_TEST_PS_STATE (OSRC_TEST_MODE=1
#     only), the same seam discipline as the _timeout injection.
(
  set --
  export OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  _state_sync(){ return 0; }
  _pid_start_identity(){ printf 'Thu Jul 31 01:02:03 2026\n'; }
  export OSRC_TEST_MODE=1
  owner="$OSRC_HEARTBEAT/leader/owner.json"
  # (a) A leader whose stat begins with Z is PROVABLY dead: evicted, though kill -0 passes.
  export OSRC_TEST_PS_STATE=Z
  rm -rf "$OSRC_HEARTBEAT/leader" 2>/dev/null || true
  mkdir -p "$OSRC_HEARTBEAT/leader"
  jq -cn --argjson pid "$$" --arg ps "Thu Jul 31 01:02:03 2026" '{pid:$pid,pid_start:$ps,token:"zombie"}' > "$owner"
  kill -0 "$$" || { echo "FAIL: premise broken, $$ is not alive"; exit 1; }
  _heartbeat_leader_alive && { echo "FAIL: zombie leader passed liveness"; exit 1; }
  _heartbeat_leader_evict_stale || { echo "FAIL: zombie eviction rc=$?"; exit 1; }
  [ -f "$owner" ] && { echo "FAIL: zombie leader claim was not evicted"; exit 1; }
  # (b) A live (stat S) leader is still never evicted by the same breaker.
  export OSRC_TEST_PS_STATE=S
  mkdir -p "$OSRC_HEARTBEAT/leader"
  jq -cn --argjson pid "$$" --arg ps "Thu Jul 31 01:02:03 2026" '{pid:$pid,pid_start:$ps,token:"live"}' > "$owner"
  _heartbeat_leader_evict_stale || { echo "FAIL: live-leader eviction check rc=$?"; exit 1; }
  [ -f "$owner" ] || { echo "FAIL: a live leader was evicted"; exit 1; }
  # (c) The confirm loop refuses to confirm over a zombie: the spawned beacon claims (pid+token
  #     would satisfy the fresh-spawn binding), but its injected stat Z skips confirmation, the
  #     loop gives up, and the child is killed.
  export OSRC_TEST_PS_STATE=Z
  rm -rf "$OSRC_HEARTBEAT/leader" 2>/dev/null || true
  export OSRC_HEARTBEAT_EXECUTABLE="$FAKE_BEACON" OSRC_HEARTBEAT_START_TIMEOUT=1 HB_PID_START="Thu Jul 31 01:02:03 2026"
  _heartbeat_start >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || { echo "FAIL: _heartbeat_start confirmed over a zombie (expected failure)"; exit 1; }
  exit 0
) && ok "zombie leader is evicted as provably dead; live leader respected; confirm loop refuses a zombie" \
  || bad "zombie eviction / confirm-loop refusal broken"

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
