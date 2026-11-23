#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_disk_policy.sh -- the disk pressure policy (lib/disk_policy.sh + the
# _osrc_disk_gate floors in lib/cleanup.sh). Regression coverage for the three
# lane incidents:
#   1. an acknowledged ASK list let a launch through with almost no disk left
#      (the critical floor can never be bypassed by --ack or OSRC_DISK_OK)
#   2. a build launched above the floor drained the disk while running and
#      nothing reacted (verified supervised jobs get SIGSTOP under the pause
#      floor, SIGCONT on recovery; foreign/unverifiable processes untouched)
#   3. a merged lane's worktree and scratch stayed behind (auto-reclaim deletes
#      ONLY verdict-SAFE worktree/branch items; jobs, ASK items, unmerged work
#      and every protected path survive)
# Every assertion can fail. Real sleeps stand in for delegates; every signal the
# policy sends is checked with `ps`.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }
bash -n "$HERE/../lib/disk_policy.sh" || { echo "FAIL: bash -n failed for lib/disk_policy.sh"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR%/}/.diskpol-test.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }
DEL_PID=""; SUP_PID=""; FRN_PID=""; UNV_PID=""
trap 'for _p in $DEL_PID $SUP_PID $FRN_PID $UNV_PID; do [ -n "$_p" ] && kill -9 "$_p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1 OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0
# Spawned monitors must die fast: one tick, ~1s cadence, no live fleet -> exit.
export OSRC_DISK_POLICY_POLL=1 OSRC_DISK_MONITOR_IDLE_TICKS=1
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

mkrepo() { # <dir> -> repo with one commit on main
  local d="$1"; mkdir -p "$d"; (
    cd "$d" && git init -q
    printf 'v1\n' > app.txt
    printf '.env\nnode_modules/\nout/\n' > .gitignore
    git add -A; git commit -qm init
  )
}
age() { find "$@" -exec touch -t 202001010000 {} + 2>/dev/null; }
age2h() {
  local t
  t="$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)"
  find "$@" -exec touch -t "$t" {} + 2>/dev/null
}
manifest() { # <path> <kind> <session> <repo>   (uses $OSRC_HOME at call time via env)
  jq -cn --arg p "$1" --arg k "$2" --arg s "$3" --arg r "$4" --argjson t "$(date +%s)" \
    '{path:$p,kind:$k,session:$s,repo:$r,ts:$t}' >> "$OSRC_HOME/created.jsonl"
}
pstat() { ps -o stat= -p "$1" 2>/dev/null | tr -d '[:space:]'; }

echo "=== floors ==="
fl="$(OSRC_HOME="$TMP/f1" OSRC_SOURCED=1 bash -c '. "'"$SRC"'"; _osrc_disk_floors_kb' 2>/dev/null)"
set -- $fl
[ "$#" -eq 3 ] && [ "$1" -ge 10485760 ] 2>/dev/null && [ "$3" -lt "$1" ] 2>/dev/null \
  && ok "default floors: launch>=$1KB pause=$2KB crit=$3KB ordered" \
  || bad "default floors wrong: '$fl'"
fl2="$(OSRC_HOME="$TMP/f1" OSRC_SOURCED=1 OSRC_DISK_MIN_GB=20 OSRC_DISK_PAUSE_GB=6 OSRC_DISK_CRITICAL_GB=2 \
  bash -c '. "'"$SRC"'"; _osrc_disk_floors_kb' 2>/dev/null)"
[ "$fl2" = "20971520 6291456 2097152" ] && ok "explicit OSRC_DISK_*_GB floors exact" || bad "override floors: '$fl2'"
fl3="$(OSRC_HOME="$TMP/f1" OSRC_SOURCED=1 OSRC_DISK_POLICY_OFF=1 bash -c '. "'"$SRC"'"; _osrc_disk_floors_kb' 2>/dev/null)"
[ "$fl3" = "10485760 0 0" ] && ok "OSRC_DISK_POLICY_OFF falls back to flat 10GB" || bad "policy-off floors: '$fl3'"
fl4="$(OSRC_HOME="$TMP/f1" OSRC_SOURCED=1 OSRC_DISK_MIN_GB=0 bash -c '. "'"$SRC"'"; _osrc_disk_floors_kb' 2>/dev/null)"
set -- $fl4
[ "${1:-x}" = "0" ] && [ "${3:-x}" = "0" ] && [ "${2:-0}" -gt 0 ] 2>/dev/null \
  && ok "OSRC_DISK_MIN_GB=0 disables launch+critical, keeps pause" || bad "MIN_GB=0 floors: '$fl4'"
fl5="$(OSRC_HOME="$TMP/f1" OSRC_SOURCED=1 OSRC_DISK_MIN_GB=abc bash -c '. "'"$SRC"'"; _osrc_disk_floors_kb' 2>/dev/null)"
set -- $fl5
[ "${1:-x}" -ge 10485760 ] 2>/dev/null && ok "invalid OSRC_DISK_MIN_GB ignored (computed floor)" || bad "invalid MIN_GB floors: '$fl5'"

echo "=== incident 1: ack/override cannot bypass the critical floor ==="
GH="$TMP/osrc-gate"; export OSRC_HOME="$GH"; mkdir -p "$GH/jobs"
# One deterministic ASK item: an existing path outside every recorded root.
mkdir -p "$TMP/outside-gate"
manifest "$TMP/outside-gate" job gate-sess ""
# Prove it verdicts ASK before trusting the gate behaviour.
vd="$(OSRC_HOME="$GH" OSRC_SOURCED=1 bash -c '. "'"$SRC"'" >/dev/null 2>&1; _osrc_cleanup_verdict "{\"path\":\"'"$TMP"'/outside-gate\",\"kind\":\"job\",\"session\":\"gate-sess\",\"repo\":\"\",\"ts\":0}"' 2>/dev/null)"
grep -q '^ASK' <<<"$vd" && ok "fixture item is ASK" || bad "fixture not ASK: $vd"
OSRC_HOME="$GH" bash "$SRC" cleanup --ack >/dev/null 2>&1
[ -f "$GH/cleanup/ask-ack" ] && ok "--ack wrote ask-ack" || bad "--ack did not write ask-ack"

# 50MB free: under the critical floor on every machine (crit is clamped to <=4GB).
gc="$(OSRC_HOME="$GH" OSRC_SOURCED=1 OSRC_TEST_FREE_KB=51200 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_free_kb() { printf "%s" "${OSRC_TEST_FREE_KB:-0}"; }
  _osrc_disk_gate; echo "gate-rc=$?"' 2>&1)"
grep -q 'critical floor' <<<"$gc" && grep -q 'refusing new lane launches' <<<"$gc" \
  && ok "ack cannot bypass critical floor (incident 1)" || bad "gate passed/refused wrong at 50MB: $gc"
grep -q 'gate-rc=0' <<<"$gc" && bad "gate returned 0 below critical floor" || ok "gate refused below critical floor"

# OSRC_DISK_OK is the explicit override — still never below critical.
gok="$(OSRC_HOME="$GH" OSRC_SOURCED=1 OSRC_TEST_FREE_KB=51200 OSRC_DISK_OK=1 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_free_kb() { printf "%s" "${OSRC_TEST_FREE_KB:-0}"; }
  _osrc_disk_gate; echo "gate-rc=$?"' 2>&1)"
grep -q 'critical floor' <<<"$gok" && ok "OSRC_DISK_OK cannot bypass critical floor either" || bad "OSRC_DISK_OK bypassed critical: $gok"

# 6GB free: above critical (<=4GB) and below launch (>=10GB) on every machine —
# the acknowledged ASK list still passes, exactly the pre-policy contract.
gb="$(OSRC_HOME="$GH" OSRC_SOURCED=1 OSRC_TEST_FREE_KB=6291456 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_free_kb() { printf "%s" "${OSRC_TEST_FREE_KB:-0}"; }
  _osrc_disk_gate; echo "gate-rc=$?"' 2>&1)"
grep -q 'gate-rc=0' <<<"$gb" && ok "acknowledged ASK still passes in the launch band" || bad "band gate refused despite ack: $gb"

# Without the ack the same band refuses on the unanswered ASK list.
rm -f "$GH/cleanup/ask-ack"
gn="$(OSRC_HOME="$GH" OSRC_SOURCED=1 OSRC_TEST_FREE_KB=6291456 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_free_kb() { printf "%s" "${OSRC_TEST_FREE_KB:-0}"; }
  _osrc_disk_gate; echo "gate-rc=$?"' 2>&1)"
grep -q 'need your decision' <<<"$gn" && ok "unacked ASK refuses in the band" || bad "unacked band gate wrong: $gn"

# OSRC_DISK_OK=1 in the band: passes for exactly this command and is logged.
go="$(OSRC_HOME="$GH" OSRC_SOURCED=1 OSRC_TEST_FREE_KB=6291456 OSRC_DISK_OK=1 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_free_kb() { printf "%s" "${OSRC_TEST_FREE_KB:-0}"; }
  _osrc_disk_gate; echo "gate-rc=$?"' 2>&1)"
grep -q 'gate-rc=0' <<<"$go" && ok "OSRC_DISK_OK passes in the band" || bad "OSRC_DISK_OK refused in band: $go"
grep -q 'free_kb=6291456' "$GH/disk-policy/override.log" 2>/dev/null \
  && ok "OSRC_DISK_OK use logged to disk-policy/override.log" || bad "override not logged"

# OSRC_DISK_MIN_GB=0 remains the documented "never block launches" escape.
gz="$(OSRC_HOME="$GH" OSRC_SOURCED=1 OSRC_TEST_FREE_KB=51200 OSRC_DISK_MIN_GB=0 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_free_kb() { printf "%s" "${OSRC_TEST_FREE_KB:-0}"; }
  _osrc_disk_gate; echo "gate-rc=$?"' 2>&1)"
grep -q 'gate-rc=0' <<<"$gz" && ok "OSRC_DISK_MIN_GB=0 disables the launch gate" || bad "MIN_GB=0 gate wrong: $gz"

# Issue #86: the gate decides from the live scan. Seed a VALID state.json + a
# matching ask-ack (the old code path would pass on these), then fail the state
# refresh: the gate must refuse as state unknown — never read the old file,
# never honor the old ack.
OSRC_HOME="$GH" bash "$SRC" cleanup >/dev/null 2>&1      # dry run refreshes state.json
OSRC_HOME="$GH" bash "$SRC" cleanup --ack >/dev/null 2>&1 # ask-ack matches the live ASK hash
[ -f "$GH/cleanup/state.json" ] && [ -f "$GH/cleanup/ask-ack" ] \
  && ok "seeded valid state.json + ask-ack for #86" || bad "#86 seed incomplete"
gs="$(OSRC_HOME="$GH" OSRC_SOURCED=1 OSRC_TEST_FREE_KB=6291456 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_free_kb() { printf "%s" "${OSRC_TEST_FREE_KB:-0}"; }
  _osrc_cleanup_state_write() { return 1; }
  _osrc_disk_gate; echo "gate-rc=$?"' 2>&1)"
grep -q 'state unknown' <<<"$gs" && grep -q 'refusing new lane launches' <<<"$gs" \
  && ok "failed state refresh refuses as unknown, stale file+ack unread (issue #86)" \
  || bad "gate honored stale state/ack on failed write: $gs"
grep -q 'gate-rc=0' <<<"$gs" && bad "gate passed on failed state write" || ok "no pass on failed state write"

echo "=== incident 2: running jobs pause under the pause floor, resume on recovery ==="
JHOME="$TMP/osrc-jobs"; mkdir -p "$JHOME/jobs"
# A verified delegate in its OWN process group (the _supervise set -m pattern),
# a verified supervisor sharing OUR group (must never be group-signalled), and a
# foreign process in its own group that no job dir claims.
set -m
( exec sleep 300 ) & DEL_PID=$!
( exec sleep 300 ) & FRN_PID=$!
set +m
sleep 300 & SUP_PID=$!
sleep 300 & UNV_PID=$!
DELPgid="$(ps -o pgid= -p "$DEL_PID" 2>/dev/null | tr -d ' ')"
[ "$DELPgid" = "$DEL_PID" ] && ok "delegate spawned as its own process-group leader" \
  || bad "delegate pgid='$DELPgid' pid='$DEL_PID' (group-stop path untested)"
JD="$JHOME/jobs/job-demo"; mkdir -p "$JD"
echo running > "$JD/status"; echo "$DEL_PID" > "$JD/pid"; echo "$DELPgid" > "$JD/pgid"
echo "$SUP_PID" > "$JD/supervisor_pid"; : > "$JD/out.log"
LC_ALL=C ps -o lstart= -p "$DEL_PID" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g' > "$JD/pid_start"
LC_ALL=C ps -o lstart= -p "$SUP_PID" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g' > "$JD/supervisor_pid_start"
# Unverifiable job: live pid but a pid_start record that cannot match -> never signalled.
JU="$JHOME/jobs/job-unver"; mkdir -p "$JU"
echo running > "$JU/status"; echo "$UNV_PID" > "$JU/pid"; echo "not-a-real-start-time" > "$JU/pid_start"; : > "$JU/out.log"
# Terminal job: must never be paused even with a live pid file lying around.
JT="$JHOME/jobs/job-done"; mkdir -p "$JT"
echo done > "$JT/status"; echo "$UNV_PID" > "$JT/pid"; : > "$JT/out.log"

tick_at() { # <free_kb> -> run one monitor tick with that free-space reading
  OSRC_HOME="$JHOME" OSRC_SOURCED=1 OSRC_TEST_FREE_KB="$1" \
  OSRC_DISK_MIN_GB=10 OSRC_DISK_PAUSE_GB=4 OSRC_DISK_CRITICAL_GB=1 \
  bash -c '. "'"$SRC"'" >/dev/null 2>&1
    _osrc_free_kb() { printf "%s" "${OSRC_TEST_FREE_KB:-0}"; }
    _osrc_disk_monitor_tick; echo "tick-rc=$?"' 2>&1
}

# 3GB free: under the 4GB pause floor, above the 1GB critical floor.
tp="$(tick_at 3145728)"
grep -q 'tick-rc=0' <<<"$tp" || bad "pressure tick failed: $tp"
case "$(pstat "$DEL_PID")" in *T*) ok "delegate frozen under pause floor (SIGSTOP)" ;; *) bad "delegate not stopped: $(pstat "$DEL_PID")" ;; esac
case "$(pstat "$SUP_PID")" in *T*) ok "supervisor frozen too (no watchdog arms while paused)" ;; *) bad "supervisor not stopped: $(pstat "$SUP_PID")" ;; esac
case "$(pstat "$FRN_PID")" in *T*) bad "FOREIGN process was stopped!" ;; *) ok "foreign process untouched" ;; esac
case "$(pstat "$UNV_PID")" in *T*) bad "unverifiable-pid job was stopped!" ;; *) ok "unverifiable pid_start job untouched" ;; esac
[ -f "$JD/disk-paused" ] && ok "disk-paused marker written" || bad "no disk-paused marker"
grep -q 'disk-policy: job paused' "$JD/out.log" && ok "pause keepalive appended to out.log" || bad "no keepalive in out.log"
grep -q 'disk\.pause\.' "$JHOME/wake-queue.jsonl" 2>/dev/null \
  && ok "owner woken with disk.pause event" || bad "no disk.pause wake event"
grep -q 'swap' "$JHOME/disk-policy/monitor.log" 2>/dev/null \
  && ok "pressure report (swap + top dirs) logged" || bad "monitor.log lacks pressure report"

# Dead zone: 5GB is above pause(4GB) but below resume(7GB) -> hold, no resume yet.
td="$(tick_at 5242880)"
grep -q 'tick-rc=0' <<<"$td" || bad "dead-zone tick failed: $td"
case "$(pstat "$DEL_PID")" in *T*) ok "dead zone holds the pause (hysteresis)" ;; *) bad "dead zone resumed early" ;; esac
[ -f "$JD/disk-paused" ] && ok "marker kept in dead zone" || bad "marker dropped in dead zone"

# Recovery: 8GB >= resume floor -> SIGCONT, marker gone, resume wake.
tr="$(tick_at 8388608)"
grep -q 'tick-rc=0' <<<"$tr" || bad "resume tick failed: $tr"
case "$(pstat "$DEL_PID")" in *T*) bad "delegate still stopped after recovery" ;; *) ok "delegate resumed (SIGCONT)" ;; esac
case "$(pstat "$SUP_PID")" in *T*) bad "supervisor still stopped after recovery" ;; *) ok "supervisor resumed" ;; esac
[ ! -f "$JD/disk-paused" ] && ok "disk-paused marker removed on resume" || bad "marker survived resume"
grep -q 'disk\.resume\.' "$JHOME/wake-queue.jsonl" 2>/dev/null \
  && ok "owner woken with disk.resume event" || bad "no disk.resume wake event"
grep -q 'disk-policy: job resumed' "$JD/out.log" && ok "resume keepalive appended" || bad "no resume keepalive"

# A second job dir pointing at the same live pid but with an unverifiable
# pid_start must never be paused or marked, even under renewed pressure.
JT2="$JHOME/jobs/job-stopped-dead"; mkdir -p "$JT2"
echo running > "$JT2/status"; echo "$DEL_PID" > "$JT2/pid"
echo "not-a-real-start-time" > "$JT2/pid_start"; : > "$JT2/out.log"
tp2="$(tick_at 3145728)"
case "$(pstat "$DEL_PID")" in *T*) ok "re-paused on renewed pressure" ;; *) bad "second pause failed: $(pstat "$DEL_PID")" ;; esac
[ ! -f "$JT2/disk-paused" ] && ok "unverifiable second job dir never marked/paused" || bad "phantom marker on unverifiable job"
tr2="$(tick_at 8388608)"
case "$(pstat "$DEL_PID")" in *T*) bad "delegate stuck stopped after second recovery" ;; *) ok "second recovery resumed delegate" ;; esac

echo "=== incident 3: auto-reclaim removes only merged-lane worktree/branch ==="
RH="$TMP/osrc-reclaim"; mkdir -p "$RH/jobs"
R="$TMP/repo-r"; mkrepo "$R"
export OSRC_HOME="$RH"
# SAFE merged lane: worktree+branch at main tip, clean, owner done, aged.
git -C "$R" worktree add -q "$R/.outsourcerer/worktrees/wt-gone" -b outsourcerer/wt-gone HEAD
mkdir -p "$RH/jobs/wt-gone"; echo done > "$RH/jobs/wt-gone/status"
# ASK unmerged lane: one commit ahead -> worktree and branch must survive.
git -C "$R" worktree add -q "$R/.outsourcerer/worktrees/wt-keep" -b outsourcerer/wt-keep HEAD
( cd "$R/.outsourcerer/worktrees/wt-keep" && printf 'wip\n' > wip.txt && git add wip.txt && git commit -qm wip )
mkdir -p "$RH/jobs/wt-keep"; echo done > "$RH/jobs/wt-keep/status"
# SAFE-kind job evidence: reclaim must NOT touch it (only worktree/branch are auto-eligible).
JE="$RH/jobs/job-evidence"; mkdir -p "$JE"; echo done > "$JE/status"
manifest "$R/.outsourcerer/worktrees/wt-gone" worktree wt-gone "$R"
manifest "outsourcerer/wt-gone" branch wt-gone "$R"
manifest "$R/.outsourcerer/worktrees/wt-keep" worktree wt-keep "$R"
manifest "outsourcerer/wt-keep" branch wt-keep "$R"
manifest "$JE" job job-evidence ""
age "$R/.outsourcerer/worktrees/wt-gone" "$R/.outsourcerer/worktrees/wt-keep" \
  "$RH/jobs/wt-gone" "$RH/jobs/wt-keep" "$JE"

# Reclaim disabled -> deletes nothing.
rc0="$(OSRC_HOME="$RH" OSRC_DISK_RECLAIM_MAX=0 OSRC_SOURCED=1 bash -c '. "'"$SRC"'" >/dev/null 2>&1; _osrc_disk_reclaim' 2>/dev/null)"
[ "$rc0" = "0" ] && [ -d "$R/.outsourcerer/worktrees/wt-gone" ] \
  && ok "OSRC_DISK_RECLAIM_MAX=0 disables auto-reclaim" || bad "reclaim-max=0 wrong: '$rc0'"

rcn="$(OSRC_HOME="$RH" OSRC_SOURCED=1 bash -c '. "'"$SRC"'" >/dev/null 2>&1; _osrc_disk_reclaim' 2>/dev/null)"
[ "$rcn" = "2" ] && ok "reclaim deleted exactly the merged worktree+branch (n=$rcn)" || bad "reclaim count wrong: '$rcn'"
[ ! -d "$R/.outsourcerer/worktrees/wt-gone" ] && ok "merged-lane worktree removed" || bad "merged worktree survived"
git -C "$R" rev-parse --verify -q refs/heads/outsourcerer/wt-gone >/dev/null 2>&1 \
  && bad "merged branch survived reclaim" || ok "merged branch removed after its worktree"
[ -d "$R/.outsourcerer/worktrees/wt-keep" ] && ok "unmerged worktree preserved" || bad "UNMERGED worktree deleted!"
git -C "$R" rev-parse --verify -q refs/heads/outsourcerer/wt-keep >/dev/null 2>&1 \
  && ok "unmerged branch preserved" || bad "unmerged branch deleted!"
[ -d "$JE" ] && ok "SAFE job evidence NOT auto-reclaimed (manual cleanup --apply only)" || bad "job evidence auto-deleted!"
grep -q 'disk-policy' "$RH/cleanup.log" 2>/dev/null \
  && ok "auto-reclaim deletions logged to cleanup.log" || bad "reclaim not logged"

echo "=== monitor lifecycle ==="
MH="$TMP/osrc-mon"; mkdir -p "$MH/jobs"
mon="$(OSRC_HOME="$MH" OSRC_DISK_POLICY_POLL=1 OSRC_DISK_MONITOR_IDLE_TICKS=2 OSRC_SOURCED=1 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_disk_monitor_ensure || { echo ensure-failed; exit 1; }
  [ -f "$OSRC_HOME/disk-policy/alive" ] && [ -f "$OSRC_HOME/disk-policy/monitor.pid" ] \
    && echo armed || echo not-armed
  mp1="$(cat "$OSRC_HOME/disk-policy/monitor.pid" 2>/dev/null)"
  _osrc_disk_monitor_ensure
  mp2="$(cat "$OSRC_HOME/disk-policy/monitor.pid" 2>/dev/null)"
  [ "$mp1" = "$mp2" ] && echo deduped || echo respawned' 2>&1)"
grep -q 'armed' <<<"$mon" && ok "monitor armed on ensure" || bad "monitor not armed: $mon"
grep -q 'deduped' <<<"$mon" && ok "second ensure dedupes on live monitor" || bad "ensure respawned: $mon"
# Idle exit: no live jobs -> monitor leaves and clears its liveness files.
i=0; gone=0
while [ "$i" -lt 40 ]; do
  [ ! -f "$MH/disk-policy/monitor.pid" ] && [ ! -f "$MH/disk-policy/alive" ] && { gone=1; break; }
  sleep 0.3; i=$((i+1))
done
[ "$gone" = 1 ] && ok "monitor self-terminates when fleet is idle" || bad "monitor did not exit"
# A fresh ensure after exit respawns immediately (liveness files were cleared).
mon2="$(OSRC_HOME="$MH" OSRC_DISK_POLICY_POLL=1 OSRC_DISK_MONITOR_IDLE_TICKS=2 OSRC_SOURCED=1 bash -c '
  . "'"$SRC"'" >/dev/null 2>&1
  _osrc_disk_monitor_ensure; sleep 0.5
  [ -f "$OSRC_HOME/disk-policy/monitor.pid" ] && echo respawned || echo no-respawn' 2>&1)"
grep -q 'respawned' <<<"$mon2" && ok "ensure respawns after idle exit" || bad "no respawn: $mon2"

echo "=== report ==="
rep="$(OSRC_HOME="$RH" OSRC_SOURCED=1 bash -c '. "'"$SRC"'" >/dev/null 2>&1; _osrc_disk_report' 2>/dev/null)"
grep -q 'free ' <<<"$rep" && grep -q 'swap' <<<"$rep" && grep -q 'OSRC_HOME' <<<"$rep" \
  && ok "disk report names free space, swap, top dirs, reclaimable counts" || bad "report wrong: $rep"

echo ""
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
