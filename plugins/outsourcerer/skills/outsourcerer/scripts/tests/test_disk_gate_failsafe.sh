#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_disk_gate_failsafe.sh -- release-gate review of the disk policy (lane osrc-fx-disk).
# Each block names the finding it pins; every check fails on the code before the fix.
#   EH = error-handling review, CC = concurrency review, AR = architecture, PR = pattern, LR = language
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR%/}/.diskfs-test.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }
KILL=""
cleanup_all() {
  local f p
  for f in "$TMP"/*/disk-policy/monitor.lock/owner; do [ -f "$f" ] && kill "$(cut -d'|' -f1 "$f")" 2>/dev/null; done
  for p in $KILL $(cat "$TMP"/*/jobs/*/pid 2>/dev/null); do kill -CONT "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; done
  sleep 0.2; rm -rf "$TMP"
}
trap cleanup_all EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
export OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0 OSRC_DISK_POLICY_POLL=1 OSRC_DISK_MONITOR_IDLE_TICKS=1 FREEF="$TMP/free_kb"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
setfree() { printf '%s' "$1" > "$FREEF"; }
# osrc <home> <code>: run code with the engine sourced and free space read from $FREEF.
osrc() {
  OSRC_HOME="$1" OSRC_SOURCED=1 bash -c '. "$0" >/dev/null 2>&1
    _osrc_free_kb() { cat "$FREEF" 2>/dev/null; }
    eval "$1"' "$SRC" "$2" 2>&1
}
home() { mkdir -p "$TMP/$1/jobs" "$TMP/$1/disk-policy"
  printf 'OSRC_DISK_MIN_GB=10\nOSRC_DISK_PAUSE_GB=4\nOSRC_DISK_CRITICAL_GB=1\n' > "$TMP/$1/disk-policy/settings"; printf '%s' "$TMP/$1"; }
code_of() { sed -n 's/.*OSRC_DISK_OK=\([0-9a-f]\{8\}\).*/\1/p' <<<"$1" | head -1; }
pstat() { ps -o stat= -p "$1" 2>/dev/null | tr -d '[:space:]'; }
stopped() { case "$(pstat "$1")" in *T*) return 0 ;; esac; return 1; }
# fakejob <home> <id> -> a running bg job record whose delegate is a real sleep; prints the pid.
fakejob() {
  local jd="$1/jobs/$2" p
  mkdir -p "$jd"; sleep 300 </dev/null >/dev/null 2>&1 & p=$!
  echo running > "$jd/status"; echo "$p" > "$jd/pid"
  LC_ALL=C ps -o lstart= -p "$p" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g' > "$jd/pid_start"
  printf '%s' "$p"
}

echo "=== EH F1: unreadable free space refuses, with its own message and the override ==="
H="$(home f1)"; : > "$FREEF"
g="$(osrc "$H" '_osrc_disk_gate fg; echo gate-rc=$?')"
grep -q 'cannot read free disk' <<<"$g" && ! grep -q 'gate-rc=0' <<<"$g" && ok "df that prints nothing refuses the launch" || bad "unreadable df passed: $g"
c="$(code_of "$g")"
[ -n "$c" ] && ok "the refusal offers the one-use code" || bad "no code offered: $g"
g="$(OSRC_DISK_OK="$c" osrc "$H" '_osrc_disk_gate fg; echo gate-rc=$?')"
grep -q 'gate-rc=0' <<<"$g" && ok "the code admits one command when df never parses" || bad "code refused with df broken: $g"
g="$(osrc "$H" '_osrc_disk_gate probe; echo gate-rc=$?')"
! grep -q 'gate-rc=0' <<<"$g" && ok "factory probe refuses when df is unreadable" || bad "probe passed: $g"

echo "=== EH F4: broken floor computation keeps a 1GB critical floor ==="
H="$(home f4)"; setfree 524288
g="$(osrc "$H" '_osrc_disk_floors_kb() { echo broken; }; _osrc_disk_gate fg; echo gate-rc=$?')"
c="$(code_of "$g")"
grep -q 'critical floor (1GB)' <<<"$g" && ok "512MB free with broken floors hits the 1GB critical floor" || bad "critical floor gone: $g"
g="$(OSRC_DISK_OK=deadbeef osrc "$H" 'printf "deadbeef %s\n" "$(( $(date +%s) + 900 ))" > "$OSRC_HOME/disk-policy/override.code"
  _osrc_disk_floors_kb() { echo broken; }; _osrc_disk_gate fg; echo gate-rc=$?')"
! grep -q 'gate-rc=0' <<<"$g" && ok "a valid code cannot pass 512MB free with broken floors" || bad "override admitted at 512MB: $g"

echo "=== EH F8 / AR F2: a disk lib that did not load refuses launches ==="
H="$(home f8)"; setfree 52428800
g="$(osrc "$H" 'unset -f _osrc_disk_cmd; _osrc_disk_gate fg; echo gate-rc=$?')"
grep -q 'did not load' <<<"$g" && ! grep -q 'gate-rc=0' <<<"$g" && ok "a half-loaded disk_policy.sh refuses" || bad "missing lib passed: $g"
g="$(osrc "$H" 'unset -f _osrc_disk_gate; _osrc_disk_session_gate start 2>/dev/null || echo refused')"
grep -q refused <<<"$g" && ok "a missing gate returns non-zero to its call site" || bad "missing gate read as pass: $g"
n="$(grep -c 'type _osrc_disk_gate' "$SRC" "$HERE/../lib/factory-parallel.sh" | awk -F: '{s+=$2} END {print s}')"
[ "$n" = 0 ] && ok "no launch path guards the disk gate with 'type ... &&'" || bad "$n guarded disk gate call(s) remain"
grep -q '_osrc_disk_gate job || die' "$SRC" && grep -q '_osrc_disk_gate fg || die' "$SRC" \
  && grep -q '_osrc_disk_session_gate "$@" || die' "$SRC" && ok "bg, route_delegate and session call the gate unguarded" || bad "call sites not fail-closed"

echo "=== EH F2: lsof 'cannot verify' is never 'clear' ==="
H="$(home f2)"; mkdir -p "$H/x"
r="$(osrc "$H" 'have() { [ "$1" = lsof ] && return 0; command -v "$1" >/dev/null; }; _timeout() { return 1; }; _osrc_lsof_busy "$OSRC_HOME/x"; echo rc=$?')"
[ "$r" = rc=2 ] && ok "_timeout setup failure (rc 1, no output) is cannot-verify" || bad "_timeout failure read as: $r"
mkdir -p "$TMP/fb"; printf '#!/bin/sh\necho "COMMAND PID USER"\necho "sleep 1 me $2"\nexit 1\n' > "$TMP/fb/lsof"; chmod +x "$TMP/fb/lsof"
r="$(PATH="$TMP/fb:$PATH" osrc "$H" '_osrc_lsof_busy "$OSRC_HOME/x"; echo rc=$?')"
[ "$r" = rc=0 ] && ok "a listing is busy even with lsof rc 1 (macOS)" || bad "listing read as: $r"
printf '#!/bin/sh\nexit 1\n' > "$TMP/fb/lsof"
r="$(PATH="$TMP/fb:$PATH" osrc "$H" '_osrc_lsof_busy "$OSRC_HOME/x"; echo rc=$?')"
[ "$r" = rc=1 ] && ok "lsof that ran and listed nothing is clear" || bad "clean run read as: $r"
printf '#!/bin/sh\nkill -SEGV $$\n' > "$TMP/fb/lsof"
r="$(PATH="$TMP/fb:$PATH" osrc "$H" '_osrc_lsof_busy "$OSRC_HOME/x"; echo rc=$?')"
[ "$r" = rc=2 ] && ok "lsof that crashed is cannot-verify" || bad "crash read as: $r"

echo "=== EH F5: a failing git status in the SAFE classifier is ASK ==="
H="$(home f5)"; R="$TMP/f5repo"; mkdir -p "$R"
( cd "$R" && git init -q && echo a > a && git add a && git commit -qm a && git update-ref refs/remotes/origin/main HEAD \
  && git worktree add -q "$R/.outsourcerer/worktrees/w5" -b outsourcerer/w5 HEAD ) >/dev/null 2>&1
mkdir -p "$H/jobs/w5"; echo done > "$H/jobs/w5/status"
find "$R/.outsourcerer/worktrees/w5" -exec touch -t 202001010000 {} + 2>/dev/null
it="$(jq -cn --arg p "$R/.outsourcerer/worktrees/w5" --arg r "$R" '{path:$p,kind:"worktree",session:"w5",repo:$r,ts:0}')"
v="$(OSRC_HOME="$H" OSRC_SOURCED=1 bash -c '. "$0" >/dev/null 2>&1; _osrc_owner_state() { printf done; }; _osrc_lsof_busy() { return 1; }
  git() { case " $* " in *" status "*) return 128 ;; esac; command git "$@"; }
  _osrc_cleanup_verdict "$1"' "$SRC" "$it" 2>&1)"
grep -q 'ASK.*git status failed' <<<"$v" && ok "git status rc 128 -> ASK (not clean)" || bad "failing git status verdict: $v"
v="$(OSRC_HOME="$H" OSRC_SOURCED=1 bash -c '. "$0" >/dev/null 2>&1; _osrc_owner_state() { printf done; }; _osrc_lsof_busy() { return 1; }
  _osrc_cleanup_verdict "$1"' "$SRC" "$it" 2>&1)"
grep -q '^SAFE' <<<"$v" && ok "the same clean worktree held by a remote is SAFE" || bad "clean pushed worktree: $v"

echo "=== spec F5: SAFE needs a remote or a merged PR, not a local branch or tag ==="
( cd "$R" && git branch keep-local outsourcerer/w5 && git tag t5 outsourcerer/w5 && git update-ref -d refs/remotes/origin/main ) >/dev/null 2>&1
r="$(OSRC_HOME="$H" OSRC_SOURCED=1 bash -c '. "$0" >/dev/null 2>&1; have() { [ "$1" = gh ] && return 1; command -v "$1" >/dev/null; }
  _osrc_branch_merged "$1" outsourcerer/w5; echo safe-rc=$?; _osrc_branch_merged "$1" outsourcerer/w5 --any-ref; echo any-rc=$?' "$SRC" "$R" 2>&1)"
grep -q 'safe-rc=1' <<<"$r" && ok "a tip held only by a local branch and a tag is not SAFE" || bad "local-only tip SAFE: $r"
grep -q 'any-rc=0' <<<"$r" && ok "cleanup <id> (--any-ref) still sees the local branch" || bad "--any-ref: $r"

echo "=== EH F6: gh pr list in the gate path is bounded ==="
printf '#!/bin/sh\nsleep 40\n' > "$TMP/fb/gh"; chmod +x "$TMP/fb/gh"
t0="$(date +%s)"
r="$(PATH="$TMP/fb:$PATH" OSRC_CLEANUP_GH_TIMEOUT=2 OSRC_HOME="$H" OSRC_SOURCED=1 bash -c '. "$0" >/dev/null 2>&1; _osrc_branch_merged "$1" outsourcerer/w5; echo rc=$?' "$SRC" "$R" 2>&1)"
t1="$(date +%s)"
[ "$r" = rc=1 ] && [ $(( t1 - t0 )) -lt 20 ] && ok "a hung gh is ASK within its bound ($(( t1 - t0 ))s)" || bad "gh bound: $r after $(( t1 - t0 ))s"
H="$(home f6du)"; setfree 6291456
t1="$(date +%s)"
g="$(osrc "$H" 'du() { sleep 40; }; _osrc_disk_gate fg; echo gate-rc=$?')"
t2="$(date +%s)"
grep -q 'launch floor' <<<"$g" && [ $(( t2 - t1 )) -lt 35 ] && ok "a hung du in the gate is bounded ($(( t2 - t1 ))s)" || bad "du bound: $(( t2 - t1 ))s: $g"

echo "=== EH F7: the factory resource gate fails closed, with a timeout ==="
H="$(home f7)"; setfree 52428800; FR="$TMP/f7repo"; mkdir -p "$FR"
printf '#!/bin/sh\nexit 2\n' > "$FR/gate.sh"; chmod +x "$FR/gate.sh"
r="$(OSRC_FACTORY_LOAD_MAX=0 OSRC_FACTORY_GATE="$FR/gate.sh" osrc "$H" '_osrc_fp_gate_can_run; echo rc=$?; echo "why=$_OSRC_FP_GATE_REASON"')"
grep -q 'rc=1' <<<"$r" && grep -q 'rc=2' <<<"$r" && ok "a gate exiting 2 holds the pass and names the rc" || bad "gate rc 2: $r"
printf '#!/bin/sh\nsleep 40\n' > "$FR/gate.sh"
t0="$(date +%s)"
r="$(OSRC_FACTORY_LOAD_MAX=0 OSRC_FACTORY_GATE="$FR/gate.sh" OSRC_FACTORY_GATE_TIMEOUT=2 osrc "$H" '_osrc_fp_gate_can_run; echo rc=$?; echo "why=$_OSRC_FP_GATE_REASON"')"
t1="$(date +%s)"
grep -q 'rc=1' <<<"$r" && grep -q 'did not answer' <<<"$r" && [ $(( t1 - t0 )) -lt 20 ] && ok "a hung gate holds the pass within its bound" || bad "hung gate: $r ($(( t1 - t0 ))s)"
printf '#!/bin/sh\nexit 0\n' > "$FR/gate.sh"
r="$(OSRC_FACTORY_LOAD_MAX=0 OSRC_FACTORY_GATE="$FR/gate.sh" osrc "$H" '_osrc_fp_gate_can_run; echo rc=$?')"
grep -q 'rc=0' <<<"$r" && ok "a gate exiting 0 lets the pass run" || bad "gate rc 0: $r"

echo "=== CC F4 / PR F3: a refusal never kills a code already shown ==="
H="$(home f9)"; setfree 6291456; mkdir -p "$TMP/outside9"
jq -cn --arg p "$TMP/outside9" '{path:$p,kind:"job",session:"s9",repo:"",ts:0}' > "$H/created.jsonl"
a="$(code_of "$(osrc "$H" '_osrc_disk_gate fg')")"; b="$(code_of "$(osrc "$H" '_osrc_disk_gate fg')")"
[ -n "$a" ] && [ "$a" = "$b" ] && ok "a second refusal re-offers the same live code" || bad "codes differ: '$a' '$b'"
OSRC_FACTORY_LOAD_MAX=0 osrc "$H" '_osrc_fp_gate_can_run >/dev/null; echo "$_OSRC_FP_GATE_REASON"' > "$TMP/fp.out"
grep -q 'need your decision' "$TMP/fp.out" && ! grep -q OSRC_DISK_OK "$TMP/fp.out" && ok "a factory pass holds without minting a code" || bad "factory pass: $(cat "$TMP/fp.out")"
g="$(OSRC_DISK_OK="$a" osrc "$H" '_osrc_disk_gate fg; echo gate-rc=$?')"
grep -q 'gate-rc=0' <<<"$g" && ok "the code shown first still admits after other refusals and a factory pass" || bad "first code dead: $g"
c="$(code_of "$(osrc "$H" '_osrc_disk_gate fg')")"
[ -n "$c" ] && [ "$c" != "$a" ] && ok "a claimed code is replaced on the next refusal" || bad "claimed code re-offered: '$c'"
# Two different commands racing one code: exactly one claims it.
rm -f "$H/disk-policy/override.log"
for i in 1 2 3 4; do ( OSRC_DISK_OK="$c" osrc "$H" '_osrc_disk_gate fg >/dev/null 2>&1; echo gate-rc=$?' > "$TMP/race.$i" ) & done; wait
n="$(cat "$TMP"/race.* | grep -c 'gate-rc=0')"
[ "$n" = 1 ] && ok "four racing commands: one admitted" || bad "racing take admitted $n"

echo "=== CC F1: the monitor is detached from its launcher ==="
H="$(home m1)"; setfree 52428800
OSRC_DISK_MONITOR_IDLE_TICKS=40 osrc "$H" 'echo $$ > "$OSRC_HOME/launcher.pid"; ps -o pgid= -p $$ | tr -d " " > "$OSRC_HOME/launcher.pgid"; _osrc_disk_monitor_ensure; sleep 2' >/dev/null
i=0; while [ "$i" -lt 25 ] && [ ! -s "$H/disk-policy/monitor.lock/owner" ]; do sleep 0.2; i=$((i+1)); done
M="$(cut -d'|' -f1 "$H/disk-policy/monitor.lock/owner" 2>/dev/null)"; L="$(cat "$H/launcher.pid")"
mp="$(ps -o ppid= -p "${M:-0}" 2>/dev/null | tr -d ' ')"; mg="$(ps -o pgid= -p "${M:-0}" 2>/dev/null | tr -d ' ')"
[ -n "$M" ] && [ "$mp" != "$L" ] && [ "$mg" != "$(cat "$H/launcher.pgid")" ] && ok "monitor $M is neither the launcher's child nor in its group" \
  || bad "monitor M=$M ppid=$mp pgid=$mg launcher=$L/$(cat "$H/launcher.pgid")"
kill "$M" 2>/dev/null

echo "=== CC F1 + LR F1: a TERMed monitor under the pause floor keeps pauses, and TERM is prompt ==="
H="$(home m2)"; setfree 2097152
V="$(fakejob "$H" job2)"
OSRC_DISK_POLICY_POLL=30 OSRC_DISK_MONITOR_IDLE_TICKS=40 osrc "$H" '_osrc_disk_monitor_ensure' >/dev/null
i=0; while [ "$i" -lt 50 ] && ! stopped "$V"; do sleep 0.2; i=$((i+1)); done
stopped "$V" && ok "under the pause floor the monitor paused the job" || bad "job not paused (stat=$(pstat "$V"))"
M="$(cut -d'|' -f1 "$H/disk-policy/monitor.lock/owner" 2>/dev/null)"; sleep 1
t0="$(date +%s)"; kill -TERM "$M" 2>/dev/null
i=0; while [ "$i" -lt 100 ] && kill -0 "$M" 2>/dev/null; do sleep 0.1; i=$((i+1)); done; t1="$(date +%s)"
! kill -0 "$M" 2>/dev/null && [ $(( t1 - t0 )) -lt 5 ] && ok "TERM ends the monitor in $(( t1 - t0 ))s, not after its 30s sleep" || bad "TERM took $(( t1 - t0 ))s"
stopped "$V" && [ -f "$H/jobs/job2/disk-paused" ] && ok "free still under the pause floor: the job stays paused, record kept" || bad "job resumed under the floor (stat=$(pstat "$V"))"
osrc "$H" '_osrc_disk_heartbeat' >/dev/null
i=0; while [ "$i" -lt 50 ] && ! [ -s "$H/disk-policy/monitor.lock/owner" ]; do sleep 0.2; i=$((i+1)); done
M2="$(cut -d'|' -f1 "$H/disk-policy/monitor.lock/owner" 2>/dev/null)"
[ -n "$M2" ] && [ "$M2" != "$M" ] && ok "the heartbeat starts a successor for the kept records" || bad "no successor monitor"
setfree 52428800
i=0; while [ "$i" -lt 50 ] && stopped "$V"; do sleep 0.2; i=$((i+1)); done
! stopped "$V" && ok "the successor resumes the job once space returns" || bad "job still stopped after recovery"
kill "$M2" 2>/dev/null; sleep 0.3

H="$(home m3)"; setfree 2097152
V="$(fakejob "$H" job3)"
OSRC_DISK_POLICY_POLL=30 OSRC_DISK_MONITOR_IDLE_TICKS=40 osrc "$H" '_osrc_disk_monitor_ensure' >/dev/null
i=0; while [ "$i" -lt 50 ] && ! stopped "$V"; do sleep 0.2; i=$((i+1)); done
M="$(cut -d'|' -f1 "$H/disk-policy/monitor.lock/owner" 2>/dev/null)"; setfree 5242880; kill -TERM "$M" 2>/dev/null
i=0; while [ "$i" -lt 50 ] && stopped "$V"; do sleep 0.2; i=$((i+1)); done
! stopped "$V" && [ ! -f "$H/jobs/job3/disk-paused" ] && ok "a TERMed monitor above the pause floor resumes and clears the record" || bad "not resumed above pause floor"

echo "=== EH F3: an unreadable reading with pauses on record resumes, with one wake ==="
H="$(home f3)"; setfree 2097152
V="$(fakejob "$H" job4)"
osrc "$H" '_osrc_disk_pause_sweep >/dev/null' >/dev/null
stopped "$V" && ok "job paused under the floor" || bad "job4 not paused"
: > "$FREEF"
r="$(osrc "$H" 'n=0; _wake_append() { echo "$1" >> "$OSRC_HOME/wakes"; }; _osrc_disk_monitor_tick; _osrc_disk_monitor_tick; echo ticked')"
! stopped "$V" && [ ! -f "$H/jobs/job4/disk-paused" ] && ok "df failing after a pause resumes the job" || bad "job frozen with df broken (stat=$(pstat "$V"))"
[ "$(grep -c 'disk-unreadable' "$H/wakes" 2>/dev/null)" = 1 ] && ok "one wake names the unreadable reading" || bad "wakes: $(cat "$H/wakes" 2>/dev/null)"

echo "=== CC F5: disk resume racing a tick ==="
H="$(home f5r)"; setfree 2097152
V="$(fakejob "$H" job5)"
r="$(osrc "$H" 'date +%s > "$(_osrc_disk_dir)/hold"; _OSRC_DISK_HONOR_HOLD=1; _osrc_disk_pause_job "$OSRC_JOBS/job5"; echo rc=$?')"
! stopped "$V" && [ ! -f "$H/jobs/job5/disk-paused" ] && ok "a hold that is down when the sweep reaches a lane pauses nothing" || bad "paused despite hold: $r"
rm -f "$H/disk-policy/hold"; osrc "$H" '_osrc_disk_pause_sweep >/dev/null' >/dev/null
r="$(osrc "$H" '_osrc_disk_resume_all() { [ -f "$(_osrc_disk_dir)/hold" ] && echo HOLD-FIRST >&2; printf 1; }; _osrc_disk_cmd resume' 2>&1)"
grep -q HOLD-FIRST <<<"$r" && ok "disk resume writes the hold before it resumes" || bad "hold after resume: $r"
osrc "$H" '_osrc_disk_resume_all >/dev/null'

echo "=== CC F6: a lane holding an Outsourcerer lock is not frozen ==="
H="$(home f6)"; setfree 2097152
V="$(fakejob "$H" job6)"; mkdir -p "$H/sessions/registry.jsonl.lock"; printf '%s 123\n' "$V" > "$H/sessions/registry.jsonl.lock/owner"
r="$(osrc "$H" '_osrc_disk_pause_sweep')"
! stopped "$V" && [ ! -f "$H/jobs/job6/disk-paused" ] && ok "lock owner deferred to the next tick" || bad "lock owner stopped: $r"
rm -rf "$H/sessions/registry.jsonl.lock"; osrc "$H" '_osrc_disk_pause_sweep >/dev/null' >/dev/null
stopped "$V" && ok "paused once it let go of the lock" || bad "not paused after the lock went"
osrc "$H" '_osrc_disk_resume_all >/dev/null'

echo "=== CC F7: supervise reports a disk-paused job as paused, never stalled ==="
H="$(home f7s)"; mkdir -p "$H/jobs/job7"; echo 'stalled?' > "$H/jobs/job7/status"; printf 'since|%s\n' "$(date +%s)" > "$H/jobs/job7/disk-paused"
r="$(osrc "$H" '_reconcile_status() { echo "stalled?"; }; _sv_observe job7 "$(date +%s)"; echo "k=[$SV_K] out=$SV_OUT"')"
grep -q 'k=\[disk-paused\] out=1' <<<"$r" && ok "a disk-paused job is reported paused (never stalled), still owed a waiter" || bad "paused job observed as: $r"
rm -f "$H/jobs/job7/disk-paused"
r="$(osrc "$H" '_reconcile_status() { echo "stalled?"; }; _sv_observe job7 "$(date +%s)"; echo "k=[$SV_K]"')"
grep -q 'k=\[stalled\]' <<<"$r" && ok "the same job unpaused still reports stalled" || bad "control case: $r"

echo "=== AR F3 / CC F6: relaunch and effort pass the gate and keep pause coverage ==="
H="$(home f8s)"; setfree 6291456; mkdir -p "$TMP/outside8"
jq -cn --arg p "$TMP/outside8" '{path:$p,kind:"job",session:"s8",repo:"",ts:0}' > "$H/created.jsonl"
for v in "control relaunch" "effort high" "model x" "start"; do
  g="$(osrc "$H" "_osrc_disk_session_gate $v; echo gate-rc=\$?")"
  grep -q 'launch floor' <<<"$g" && ! grep -q 'gate-rc=0' <<<"$g" && ok "session $v is disk-gated" || bad "session $v passed: $g"
done
g="$(osrc "$H" '_osrc_disk_session_gate control read; echo gate-rc=$?')"
grep -q 'gate-rc=0' <<<"$g" && ok "session control read is not gated" || bad "read gated: $g"
# Re-registration: a bound pane, then a respawn registration; the new (younger) pane binds, and a
# respawn that never happened binds back to the old pane instead of dropping the lane.
sleep 300 </dev/null >/dev/null 2>&1 & P1=$!; KILL="$KILL $P1"; sleep 2
r="$(osrc "$H" 'SESSION_NAME=lane8; have() { [ "$1" = tmux ] || command -v "$1" >/dev/null; }
  d="$(_osrc_disk_dir)/procs"; mkdir -p "$d"
  printf "tmux|lane8|1|%s|%s\n" '"$P1"' "$(_pid_start_identity '"$P1"')" > "$d/tmux-lane8"
  _osrc_disk_register_caller tmux-respawn; cat "$d/tmux-lane8"')"
grep -q "^tmux|lane8|[0-9]*|||[0-9]*|$P1|" <<<"$r" && ok "a respawn re-registers pending and remembers the old pane" || bad "respawn record: $r"
r="$(osrc "$H" 'tmux() { case "$1" in has-session) return 0 ;; display-message) echo '"$P1"' ;; esac; }; have() { [ "$1" = tmux ] || command -v "$1" >/dev/null; }
  _osrc_disk_reg_root "$(_osrc_disk_dir)/procs/tmux-lane8"; echo " rc=$?"')"
grep -q "^$P1 rc=0" <<<"$r" && ok "a respawn that did not happen keeps the old pane covered" || bad "old pane dropped: $r"
sleep 300 </dev/null >/dev/null 2>&1 & P2=$!; KILL="$KILL $P2"
osrc "$H" 'SESSION_NAME=lane8; have() { [ "$1" = tmux ] || command -v "$1" >/dev/null; }; _osrc_disk_register_caller tmux-respawn' >/dev/null
r="$(osrc "$H" 'have() { [ "$1" = tmux ] || command -v "$1" >/dev/null; }
  tmux() { case "$1" in has-session) return 0 ;; display-message) echo '"$P2"' ;; esac; }; _osrc_disk_reg_root "$(_osrc_disk_dir)/procs/tmux-lane8"; echo " rc=$?"')"
grep -q "^$P2 rc=0" <<<"$r" && ok "the respawned pane binds" || bad "new pane not bound: $r"

echo
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
