#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_disk_policy.sh -- the disk pressure policy (lib/disk_policy.sh + _osrc_disk_gate in
# lib/cleanup.sh). Regression coverage for the lane incidents and every review finding:
#   1. an acknowledged ASK list let a launch through with almost no disk left
#   2. a build launched above the floor drained the disk while running and nothing reacted
#   3. a merged lane's worktree and scratch data stayed behind
# Real sleeps stand in for delegates; every signal the policy sends is checked with `ps`.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }
bash -n "$HERE/../lib/disk_policy.sh" || { echo "FAIL: bash -n failed for lib/disk_policy.sh"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR%/}/.diskpol-test.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }
KILL=""
cleanup_all() {
  local f p
  for f in "$TMP"/*/disk-policy/monitor.lock/owner; do [ -f "$f" ] && kill "$(cut -d'|' -f1 "$f")" 2>/dev/null; done
  for p in $KILL; do kill -CONT "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; done
  [ -n "${TMUX_TMPDIR:-}" ] && tmux kill-server 2>/dev/null
  sleep 0.2; rm -rf "$TMP"
}
trap cleanup_all EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1 OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0
export OSRC_DISK_POLICY_POLL=1 OSRC_DISK_MONITOR_IDLE_TICKS=1 FREEF="$TMP/free_kb"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
mkrepo() { local d="$1"; mkdir -p "$d"; ( cd "$d" && git init -q && printf 'v1\n' > app.txt \
  && printf '.env\nnode_modules/\nout/\n' > .gitignore && git add -A && git commit -qm init ); }
age() { find "$@" -exec touch -t 202001010000 {} + 2>/dev/null; }
manifest() { jq -cn --arg p "$1" --arg k "$2" --arg s "$3" --arg r "$4" --argjson t "$(date +%s)" \
  '{path:$p,kind:$k,session:$s,repo:$r,ts:$t}' >> "$OSRC_HOME/created.jsonl"; }
pstat() { ps -o stat= -p "$1" 2>/dev/null | tr -d '[:space:]'; }
stopped() { case "$(pstat "$1")" in *T*) return 0 ;; esac; return 1; }
lstart() { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g'; }
setfree() { printf '%s' "$1" > "$FREEF"; }
# osrc <home> <code> : run code with the library sourced and free space read from $FREEF.
osrc() {
  OSRC_HOME="$1" OSRC_SOURCED=1 bash -c '. "$0" >/dev/null 2>&1
    _osrc_free_kb() { cat "$FREEF" 2>/dev/null; }
    eval "$1"' "$SRC" "$2" 2>&1
}
settings() { mkdir -p "$1/disk-policy"; printf 'OSRC_DISK_MIN_GB=10\nOSRC_DISK_PAUSE_GB=4\nOSRC_DISK_CRITICAL_GB=1\n%s' "${2:-}" > "$1/disk-policy/settings"; }
owner_pid() { cut -d'|' -f1 "$1/disk-policy/monitor.lock/owner" 2>/dev/null; }
wait_for() { local i=0; while [ "$i" -lt "${2:-50}" ]; do eval "$1" && return 0; sleep 0.2; i=$((i+1)); done; return 1; }

echo "=== floors and settings ==="
fl="$(osrc "$TMP/f1" '_osrc_disk_floors_kb')"; set -- $fl
[ "$#" -eq 3 ] && [ "$3" -lt "$1" ] && [ "$2" -lt "$1" ] && ok "default floors ordered: $fl" || bad "default floors wrong: '$fl'"
fl="$(OSRC_DISK_MIN_GB=20 OSRC_DISK_PAUSE_GB=6 OSRC_DISK_CRITICAL_GB=2 osrc "$TMP/f1" '_osrc_disk_floors_kb')"
[ "$fl" = "20971520 6291456 2097152" ] && ok "explicit floors exact" || bad "override floors: '$fl'"
fl="$(OSRC_DISK_POLICY_OFF=1 osrc "$TMP/f1" '_osrc_disk_floors_kb')"
[ "$fl" = "10485760 0 0" ] && ok "policy off -> flat 10GB" || bad "policy-off floors: '$fl'"
fl="$(OSRC_DISK_MIN_GB=0 osrc "$TMP/f1" '_osrc_disk_floors_kb')"; set -- $fl
[ "$1" = 0 ] && [ "$3" = 0 ] && [ "$2" -gt 0 ] && ok "MIN_GB=0 disables launch+critical, keeps pause" || bad "MIN_GB=0: '$fl'"
# P2: an 8GiB volume must get a launch floor it can satisfy; an empty one launches.
fl="$(osrc "$TMP/f1" '_osrc_disk_vol_kb() { echo 8388608; }; _osrc_disk_floors_kb')"; set -- $fl
[ "$1" -le 2097152 ] && [ "$3" -lt "$1" ] && [ "$2" -lt "$1" ] && ok "small volume caps the default launch floor: $fl" || bad "small volume floors: '$fl'"
mkdir -p "$TMP/small/jobs"; setfree 7340032
g="$(osrc "$TMP/small" '_osrc_disk_vol_kb() { echo 8388608; }; _osrc_disk_gate; echo gate-rc=$?')"
grep -q 'gate-rc=0' <<<"$g" && ok "empty small volume is not blocked by the default" || bad "small volume blocked: $g"
# The settings file is the documented setting; the monitor reads ONLY it.
settings "$TMP/f2" 'OSRC_DISK_RECLAIM_MAX=0
'
fl="$(osrc "$TMP/f2" '_osrc_disk_floors_kb')"
[ "${fl%% *}" = 10485760 ] && ok "settings file sets the launch floor" || bad "settings ignored: '$fl'"
v="$(OSRC_DISK_RECLAIM_MAX=7 osrc "$TMP/f2" 'printf "%s/" "$(_osrc_disk_conf OSRC_DISK_RECLAIM_MAX)"; _OSRC_DISK_MONITOR=1; _osrc_disk_conf OSRC_DISK_RECLAIM_MAX')"
[ "$v" = "7/0" ] && ok "env wins per command; the monitor reads only shared settings" || bad "conf precedence: '$v'"

echo "=== incident 1: gate, ack and override ==="
GH="$TMP/gate"; export OSRC_HOME="$GH"; mkdir -p "$GH/jobs" "$TMP/outside-gate"
manifest "$TMP/outside-gate" job gate-sess ""
OSRC_HOME="$GH" bash "$SRC" cleanup --ack >/dev/null 2>&1
[ -f "$GH/cleanup/ask-ack" ] && ok "--ack wrote ask-ack" || bad "--ack did not write ask-ack"
export OSRC_DISK_MIN_GB=10 OSRC_DISK_CRITICAL_GB=1
setfree 51200
g="$(osrc "$GH" '_osrc_disk_gate; echo gate-rc=$?')"
grep -q 'critical floor' <<<"$g" && ! grep -q 'gate-rc=0' <<<"$g" && ok "ack cannot bypass the critical floor" || bad "critical with ack: $g"
g="$(OSRC_DISK_OK=1 osrc "$GH" '_osrc_disk_gate; echo gate-rc=$?')"
grep -q 'critical floor' <<<"$g" && ok "OSRC_DISK_OK cannot bypass the critical floor" || bad "OSRC_DISK_OK bypassed critical: $g"
setfree 6291456
g="$(osrc "$GH" '_osrc_disk_gate; echo gate-rc=$?')"
grep -q 'gate-rc=0' <<<"$g" && ok "acknowledged ASK passes in the launch band" || bad "band refused despite ack: $g"
# P1: a slow scan can let the disk fall under critical; re-read before admitting.
g="$(osrc "$GH" 'eval "$(declare -f _osrc_cleanup_items | sed "1s/_osrc_cleanup_items/_orig_items/")"
  _osrc_cleanup_items() { _orig_items "$@"; printf 51200 > "$FREEF"; }
  _osrc_disk_gate; echo gate-rc=$?')"
grep -q 'during the cleanup scan' <<<"$g" && ! grep -q 'gate-rc=0' <<<"$g" && ok "ack re-checks free space after the scan" || bad "admitted below critical after scan: $g"
setfree 6291456
rm -f "$GH/cleanup/ask-ack"
g="$(osrc "$GH" '_osrc_disk_gate; echo gate-rc=$?')"
grep -q 'need your decision' <<<"$g" && ok "unacked ASK refuses in the band" || bad "unacked band: $g"
code="$(sed -n 's/.*OSRC_DISK_OK=\([0-9a-f]\{8\}\).*/\1/p' <<<"$g" | head -1)"
[ -n "$code" ] && ok "refusal offers a one-use override code" || bad "no override code offered: $g"
# P1: an inherited OSRC_DISK_OK=1 (profile export) is not consent.
g="$(OSRC_DISK_OK=1 osrc "$GH" '_osrc_disk_gate; echo gate-rc=$?')"
grep -q 'gate-rc=0' <<<"$g" && bad "inherited OSRC_DISK_OK=1 admitted a launch" || ok "inherited OSRC_DISK_OK=1 is not consent"
code="$(sed -n 's/.*OSRC_DISK_OK=\([0-9a-f]\{8\}\).*/\1/p' <<<"$g" | head -1)"
g="$(OSRC_DISK_OK="$code" osrc "$GH" '_osrc_disk_gate; echo gate-rc=$?; ( _osrc_disk_gate; echo sub-rc=$? ); env | grep -c "^OSRC_DISK_OK=" ')"
grep -q 'gate-rc=0' <<<"$g" && grep -q 'sub-rc=0' <<<"$g" && ok "code admits this command and its internal launches" || bad "code refused: $g"
[ "$(tail -1 <<<"$g")" = 0 ] && ok "OSRC_DISK_OK scrubbed before any delegate runs" || bad "OSRC_DISK_OK still exported: $g"
grep -q 'free_kb=6291456' "$GH/disk-policy/override.log" 2>/dev/null && ok "override logged" || bad "override not logged"
g="$(OSRC_DISK_OK="$code" osrc "$GH" '_osrc_disk_gate; echo gate-rc=$?')"
grep -q 'gate-rc=0' <<<"$g" && bad "a used code admitted a second command" || ok "a code is bound to one command"
code="$(sed -n 's/.*OSRC_DISK_OK=\([0-9a-f]\{8\}\).*/\1/p' <<<"$g" | head -1)"
rm -f "$GH/disk-policy/override.log"; mkdir "$GH/disk-policy/override.log"
g="$(OSRC_DISK_OK="$code" osrc "$GH" '_osrc_disk_gate; echo gate-rc=$?')"
grep -q 'gate-rc=0' <<<"$g" && bad "override admitted without an audit record" || ok "override needs a successful audit append"
rmdir "$GH/disk-policy/override.log"
g="$(OSRC_DISK_MIN_GB=0 osrc "$GH" '_osrc_disk_gate; echo gate-rc=$?')"
grep -q 'gate-rc=0' <<<"$g" && ok "MIN_GB=0 disables the launch gate" || bad "MIN_GB=0 gate: $g"
# P1 (#86): the REAL state writer must report a failed write; the gate then refuses.
if [ -w /dev/full ]; then
  OSRC_HOME="$GH" bash "$SRC" cleanup --ack >/dev/null 2>&1
  g="$(osrc "$GH" 'ln -sf /dev/full "$(_osrc_cl_state).tmp.$$"; _osrc_cleanup_state_write "{}"; echo write-rc=$?
    ln -sf /dev/full "$(_osrc_cl_state).tmp.$$"; _osrc_disk_gate; echo gate-rc=$?')"
  grep -q 'write-rc=1' <<<"$g" && ok "real state writer returns failure after a write error" || bad "state writer masked failure: $g"
  grep -q 'state unknown' <<<"$g" && ! grep -q 'gate-rc=0' <<<"$g" && ok "gate refuses on a failed state refresh" || bad "gate passed on failed write: $g"
else echo "SKIP: no /dev/full for the state-write failure case"; fi
unset OSRC_DISK_MIN_GB OSRC_DISK_CRITICAL_GB

echo "=== incident 2: pause, hold, resume ==="
JH="$TMP/jobs"; mkdir -p "$JH/jobs"
export OSRC_DISK_MIN_GB=10 OSRC_DISK_PAUSE_GB=4 OSRC_DISK_CRITICAL_GB=1   # resume floor 7GB
mkjob() { # <name> <pid> <pgid> <sup_pid> -> job dir with verified identities
  local jd="$JH/jobs/$1"; mkdir -p "$jd"; echo running > "$jd/status"; : > "$jd/out.log"
  echo "$2" > "$jd/pid"; printf '%s\n' "$3" > "$jd/pgid"; lstart "$2" > "$jd/pid_start"
  [ -n "$4" ] && { echo "$4" > "$jd/supervisor_pid"; lstart "$4" > "$jd/supervisor_pid_start"; }
  printf '%s' "$jd"
}
set -m; ( exec sleep 300 ) & DEL=$!; ( exec sleep 300 ) & FRN=$!; set +m
sleep 300 & SUP=$!; sleep 300 & UNV=$!; sleep 300 & D2=$!; sleep 300 & S2=$!; sleep 300 & SIB=$!
KILL="$DEL $FRN $SUP $UNV $D2 $S2 $SIB"; disown $KILL 2>/dev/null
JD="$(mkjob job-a "$DEL" "$DEL" "$SUP")"
JU="$(mkjob job-unver "$UNV" "" "")"; echo bogus-start > "$JU/pid_start"
# P1: no recorded pgid -> must stop the delegate alone, never another group.
J2="$(mkjob job-nopgid "$D2" "" "$S2")"
tick() { setfree "$1"; osrc "$JH" '_osrc_disk_monitor_tick; echo tick-rc=$?'; }
# P1: pause before the slow report/reclaim scan.
t="$(setfree 3145728; osrc "$JH" '_osrc_cleanup_items() { ps -o stat= -p '"$DEL"' > "$OSRC_HOME/stat-at-scan"; }; _osrc_disk_monitor_tick')"
case "$(cat "$JH/stat-at-scan" 2>/dev/null)" in *T*) ok "jobs paused before the report/reclaim scan" ;; *) bad "scan ran before pause: $(cat "$JH/stat-at-scan" 2>/dev/null)" ;; esac
stopped "$DEL" && ok "delegate group frozen under the pause floor" || bad "delegate not stopped"
stopped "$SUP" && ok "supervisor frozen" || bad "supervisor not stopped"
stopped "$D2" && stopped "$S2" && ok "job without a pgid record: delegate and supervisor stopped by pid" || bad "no-pgid job not paused: $(pstat "$D2") $(pstat "$S2")"
stopped "$SIB" && bad "a process sharing the delegate's group was stopped" || ok "no group signal without a delegate-led group"
stopped "$FRN" && bad "FOREIGN process stopped" || ok "foreign process untouched"
stopped "$UNV" && bad "unverifiable job stopped" || ok "unverifiable job untouched"
grep -q "^proc|d|$DEL|1|" "$JD/disk-paused" && grep -q "^proc|s|$SUP|0|" "$JD/disk-paused" \
  && ok "pause record names each process, its group flag and identity" || bad "record: $(cat "$JD/disk-paused")"
ev1="$(jq -r 'select(.kind=="disk-paused")|.event_id' "$JH/wake-queue.jsonl" 2>/dev/null | tail -1)"
[ -n "$ev1" ] && ok "owner woken: $ev1" || bad "no disk-paused wake"
grep -q "auto  worktree\|reclaimable" "$JH/disk-policy/monitor.log" 2>/dev/null; grep -q 'swap' "$JH/disk-policy/monitor.log" && ok "pressure report logged" || bad "no report"
t="$(tick 5242880)"
stopped "$DEL" && ok "hysteresis holds the pause" || bad "dead zone resumed early"
osrc "$JH" 'printf "%s" "$(_osrc_disk_paused_secs '"$JD"')"' > "$TMP/ps1"
[ "$(cat "$TMP/ps1")" -ge 0 ] 2>/dev/null && ok "watchdog can read paused seconds while paused" || bad "paused_secs: $(cat "$TMP/ps1")"
t="$(tick 8388608)"
! stopped "$DEL" && ! stopped "$SUP" && ! stopped "$D2" && ! stopped "$S2" && ok "all resumed on recovery" || bad "still stopped after recovery"
[ ! -f "$JD/disk-paused" ] && [ -f "$JD/disk-paused-secs" ] && ok "record retired, pause time accumulated" || bad "record/secs wrong"
grep -q '"disk-resumed"' "$JH/wake-queue.jsonl" && ok "resume wake" || bad "no resume wake"
# P2: a second episode gets a new event id.
t="$(tick 3145728)"
ev2="$(jq -r 'select(.kind=="disk-paused")|.event_id' "$JH/wake-queue.jsonl" 2>/dev/null | tail -1)"
[ -n "$ev2" ] && [ "$ev2" != "$ev1" ] && ok "second episode wakes with a new id" || bad "episode ids: $ev1 / $ev2"
# P1: cancel while paused -> the stopped supervisor is resumed before the record goes.
echo canceled > "$JD/status"; kill -CONT "$DEL"; kill -9 "$DEL" 2>/dev/null
t="$(tick 3145728)"
! stopped "$SUP" && [ ! -f "$JD/disk-paused" ] && ok "canceled job: supervisor resumed, then record retired" || bad "supervisor stranded: $(pstat "$SUP")"
t="$(tick 8388608)"
# P1: the record must be durable BEFORE any SIGSTOP.
mkdir "$J2/disk-paused.tmp"
t="$(tick 3145728)"
! stopped "$D2" && [ ! -f "$J2/disk-paused" ] && ok "no record -> job left running" || bad "stopped without a durable record"
grep -q 'could not be verified' "$JH/wake-queue.jsonl" && ok "owner told some lanes keep running" || bad "unrecorded job not reported"
rmdir "$J2/disk-paused.tmp"; t="$(tick 8388608)"
# P2: recovery under pipefail with a long record list.
mkdir -p "$TMP/many/jobs"
i=0; while [ "$i" -lt 1500 ]; do mkdir -p "$TMP/many/jobs/j$i"; printf 'since|1\n' > "$TMP/many/jobs/j$i/disk-paused"; i=$((i+1)); done
setfree 8388608
osrc "$TMP/many" 'set -o pipefail; _osrc_disk_record_sweep() { :; }; _osrc_disk_monitor_tick' >/dev/null
[ -z "$(ls "$TMP"/many/jobs/*/disk-paused 2>/dev/null)" ] && ok "recovery sweeps every record under pipefail" || bad "records left under pipefail"

echo "=== foreground and tmux lanes ==="
FH="$TMP/fg"; mkdir -p "$FH/jobs"; settings "$FH"; setfree 20971520
osrc "$FH" 'route_delegate() { _osrc_disk_gate; }; route_delegate; sleep 300 & echo $! > "$OSRC_HOME/child"; disown; sleep 3' >/dev/null &
LP=$!; wait_for '[ -s "$FH/child" ]' 20; FC="$(cat "$FH/child" 2>/dev/null)"; KILL="$KILL $FC"
ls "$FH"/disk-policy/procs/fg-* >/dev/null 2>&1 && ok "foreground launch registered" || bad "no fg registration"
setfree 3145728; osrc "$FH" '_osrc_disk_monitor_tick' >/dev/null
stopped "$FC" && ok "foreground lane's work paused" || bad "fg child not paused: $(pstat "$FC")"
setfree 8388608; osrc "$FH" '_osrc_disk_monitor_tick' >/dev/null
! stopped "$FC" && ok "foreground lane resumed" || bad "fg child stranded"
wait "$LP" 2>/dev/null
g="$(OSRC_RUN_ID=x osrc "$TMP/fg2" 'mkdir -p "$OSRC_HOME"; _osrc_disk_register_caller route_delegate; ls "$OSRC_HOME/disk-policy/procs" 2>/dev/null | wc -l')"
[ "$(tail -1 <<<"$g" | tr -d ' ')" = 0 ] && ok "inside a bg job: no duplicate fg registration" || bad "bg job registered as fg: $g"
if command -v tmux >/dev/null 2>&1; then
  export TMUX_TMPDIR="$TMP/tmux"; mkdir -p "$TMUX_TMPDIR"; unset TMUX
  TH="$TMP/tui"; mkdir -p "$TH/jobs"
  osrc "$TH" 'SESSION_NAME=osrc-tui; OSRC_PLATFORM=linux; _osrc_disk_register_caller session' >/dev/null
  tmux new-session -d -s osrc-tui -x 80 -y 24 "env PS1='$ ' bash --norc --noprofile -i"
  sleep 0.5; tmux send-keys -t osrc-tui "bash -c 'stty raw -echo; exec sleep 600'" Enter
  wait_for '[ "$(tmux display-message -p -t osrc-tui "#{pane_current_command}")" = sleep ]' 25
  PTTY="$(tmux display-message -p -t osrc-tui '#{pane_tty}')"; RAW="$(stty -g < "$PTTY")"
  setfree 3145728; osrc "$TH" '_osrc_disk_monitor_tick' >/dev/null
  wait_for '[ "$(tmux display-message -p -t osrc-tui "#{pane_current_command}")" = bash ]' 25 \
    && ok "TUI paused: its pane shell took job control" || bad "TUI not paused: $(tmux display-message -p -t osrc-tui '#{pane_current_command}')"
  out="$(osrc "$TH" '_osrc_disk_cmd resume')"
  grep -q 'resumed 1' <<<"$out" && ok "one command resumes the paused lane" || bad "disk resume: $out"
  wait_for '[ "$(tmux display-message -p -t osrc-tui "#{pane_current_command}")" = sleep ]' 25 \
    && ok "TUI back in the foreground" || bad "TUI left in job control: $(tmux display-message -p -t osrc-tui '#{pane_current_command}')"
  [ "$(stty -g < "$PTTY")" = "$RAW" ] && ok "TUI terminal mode restored" || bad "tty mode not restored"
  osrc "$TH" '_osrc_disk_monitor_tick' >/dev/null
  [ "$(tmux display-message -p -t osrc-tui '#{pane_current_command}')" = sleep ] && ok "manual resume holds new pauses" || bad "re-paused after manual resume"
  # A session that predates the registration (the user's own) is never bound.
  tmux new-session -d -s user-own "sleep 600"
  printf 'tmux|user-own|%s|||\n' "$(( $(date +%s) + 100 ))" > "$TH/disk-policy/procs/tmux-user-own"
  rm -f "$TH/disk-policy/hold"; osrc "$TH" '_osrc_disk_pause_reg "$OSRC_HOME/disk-policy/procs/tmux-user-own"' >/dev/null
  [ ! -f "$TH/disk-policy/procs/tmux-user-own" ] && ok "pre-existing session not adopted" || bad "foreign session bound"
  setfree 8388608; osrc "$TH" '_osrc_disk_monitor_tick' >/dev/null
  # A session start still in progress (its launcher alive) is left alone: no tmux call.
  printf 'tmux|not-yet|%s|||%s\n' "$(date +%s)" "$$" > "$TH/disk-policy/procs/tmux-not-yet"
  osrc "$TH" 'tmux() { echo called >> "$OSRC_HOME/tmux-calls"; command tmux "$@"; }; _osrc_disk_reg_root "$OSRC_HOME/disk-policy/procs/tmux-not-yet"' >/dev/null
  [ -f "$TH/disk-policy/procs/tmux-not-yet" ] && [ ! -f "$TH/tmux-calls" ] && ok "pending tmux registration makes no tmux call" || bad "pending registration probed tmux"
else echo "SKIP: tmux not installed (TUI resume cases)"; fi

echo "=== monitor lifecycle ==="
MH="$TMP/mon"; mkdir -p "$MH/jobs"; settings "$MH"
sleep 300 & MJ=$!; KILL="$KILL $MJ"; disown "$MJ" 2>/dev/null
MJD="$MH/jobs/job-m"; mkdir -p "$MJD"; echo running > "$MJD/status"; echo "$MJ" > "$MJD/pid"; lstart "$MJ" > "$MJD/pid_start"; : > "$MJD/out.log"
setfree 3145728
# P1: the monitor must not hold the caller's fd 5 (background preflight stderr) open.
t0="$(date +%s)"
out="$(OSRC_DISK_MONITOR_IDLE_TICKS=30 osrc "$MH" 'exec 5>&1; _osrc_disk_monitor_ensure; echo launched')"
el=$(( $(date +%s) - t0 ))
[ "$el" -lt 8 ] && grep -q launched <<<"$out" && ok "captured launch returns while the monitor runs (${el}s)" || bad "caller blocked ${el}s"
wait_for '[ -n "$(owner_pid "$MH")" ] && stopped '"$MJ" 40
M1="$(owner_pid "$MH")"
[ -n "$M1" ] && kill -0 "$M1" 2>/dev/null && ok "live verified monitor owner $M1" || bad "no live monitor owner"
stopped "$MJ" && ok "running monitor paused the job" || bad "monitor did not pause: $(pstat "$MJ")"
# P1: a second launch while it lives must not start another watcher.
for i in 1 2 3; do osrc "$MH" '_osrc_disk_monitor_ensure' >/dev/null; done; sleep 2
[ "$(grep -c 'monitor .* started' "$MH/disk-policy/monitor.log")" = 1 ] && [ "$(owner_pid "$MH")" = "$M1" ] \
  && ok "one watcher across concurrent launches" || bad "watchers: $(grep -c 'started' "$MH/disk-policy/monitor.log")"
# P1: TERM resumes everything it paused.
kill -TERM "$M1"
wait_for '! kill -0 '"$M1"' 2>/dev/null' 40 && ok "monitor $M1 exited on TERM" || bad "monitor ignored TERM"
! stopped "$MJ" && ok "TERM exit resumed the paused job" || bad "job frozen after monitor exit"
[ ! -d "$MH/disk-policy/monitor.lock" ] && ok "lock released on exit" || bad "lock left behind"
# P1: abrupt death -> heartbeat brings a monitor back, which resumes once space returns.
osrc "$MH" '_osrc_disk_monitor_tick' >/dev/null; stopped "$MJ" || bad "re-pause for kill -9 case failed"
mkdir -p "$MH/disk-policy/monitor.lock"; echo "999999|Mon Jan  1 00:00:00 2001" > "$MH/disk-policy/monitor.lock/owner"
setfree 8388608
osrc "$MH" '_osrc_disk_heartbeat' >/dev/null
wait_for '! stopped '"$MJ" 40 && ok "heartbeat recovered a dead monitor's pause" || bad "job still frozen after heartbeat"
M2="$(owner_pid "$MH")"
[ -n "$M2" ] && [ "$M2" != 999999 ] && ok "stale owner replaced by verified monitor $M2" || bad "stale lock kept: $M2"
# P3: with nothing live it exits on its own; a later launch gets a new one.
kill -9 "$MJ" 2>/dev/null; echo done > "$MJD/status"
wait_for '! kill -0 '"$M2"' 2>/dev/null' 50 && ok "monitor $M2 exits when idle" || bad "monitor $M2 never exited"
ns="$(grep -c 'started' "$MH/disk-policy/monitor.log")"
osrc "$MH" '_osrc_disk_monitor_ensure' >/dev/null
wait_for '[ "$(grep -c started "$MH/disk-policy/monitor.log")" -gt '"$ns"' ]' 25 && ok "launch after idle exit gets a fresh monitor" || bad "no respawn"

echo "=== incident 3: merged-lane reclaim ==="
RH="$TMP/reclaim"; mkdir -p "$RH/jobs" "$RH/tmp"; export OSRC_HOME="$RH"
R="$TMP/repo"; mkrepo "$R"
lane() { # <name> -> worktree + branch + receipt, merged (at main), owner done
  git -C "$R" worktree add -q "$R/.outsourcerer/worktrees/$1" -b "outsourcerer/$1" HEAD
  mkdir -p "$RH/jobs/$1"; echo done > "$RH/jobs/$1/status"
  jq -cn --arg b "outsourcerer/$1" --arg s "$(git -C "$R" rev-parse HEAD)" '{branch:$b,base_sha:$s}' > "$RH/jobs/$1/worktree.json"
  manifest "$R/.outsourcerer/worktrees/$1" worktree "$1" "$R"; manifest "outsourcerer/$1" branch "$1" "$R"
}
lane gone; lane deps; lane detached; lane race
mkdir -p "$RH/tmp/gone-scratch" "$RH/tmp/keep-scratch" "$RH/tmp/user-notes"
echo x > "$RH/tmp/gone-scratch/build.o"; echo x > "$RH/tmp/keep-scratch/build.o"; echo mine > "$RH/tmp/user-notes/n.txt"
manifest "$RH/tmp/gone-scratch" tmp gone ""; manifest "$RH/tmp/keep-scratch" tmp wt-keep ""
mkdir -p "$RH/tmp/gone-env"; echo SECRET=1 > "$RH/tmp/gone-env/.env"; manifest "$RH/tmp/gone-env" tmp gone ""
# Unmerged lane.
git -C "$R" worktree add -q "$R/.outsourcerer/worktrees/wt-keep" -b outsourcerer/wt-keep HEAD
( cd "$R/.outsourcerer/worktrees/wt-keep" && echo w > wip.txt && git add wip.txt && git commit -qm wip )
mkdir -p "$RH/jobs/wt-keep"; echo done > "$RH/jobs/wt-keep/status"
manifest "$R/.outsourcerer/worktrees/wt-keep" worktree wt-keep "$R"; manifest outsourcerer/wt-keep branch wt-keep "$R"
# P1: ignored dependency dir holding a .env -> never auto-deleted.
mkdir -p "$R/.outsourcerer/worktrees/deps/node_modules/pkg"; echo TOKEN=1 > "$R/.outsourcerer/worktrees/deps/node_modules/pkg/.env"
# P1: detached HEAD carrying the only copy of a fix.
( cd "$R/.outsourcerer/worktrees/detached" && git checkout -q --detach && echo fix > fix.txt && git add fix.txt && git commit -qm fix )
FIX="$(git -C "$R/.outsourcerer/worktrees/detached" rev-parse HEAD)"
# P1: unrelated worktree on a "disconnected drive" keeps its admin record (no prune).
git -C "$R" worktree add -q "$TMP/usb-wt" -b user/usb HEAD; rm -rf "$TMP/usb-wt"
age "$R/.outsourcerer/worktrees" "$RH/jobs" "$RH/tmp"
rep="$(osrc "$RH" '_osrc_disk_report')"
grep -q "auto  worktree  $R/.outsourcerer/worktrees/gone" <<<"$rep" && ok "report names reclaimable items by path and kind" || bad "report: $rep"
n="$(OSRC_DISK_RECLAIM_MAX=0 osrc "$RH" '_osrc_disk_reclaim')"
[ "$n" = 0 ] && [ -d "$R/.outsourcerer/worktrees/gone" ] && ok "RECLAIM_MAX=0 disables reclaim" || bad "max=0: $n"
# P2: the shared setting governs a monitor regardless of a launch's env.
settings "$RH" 'OSRC_DISK_RECLAIM_MAX=0
'
n="$(OSRC_DISK_RECLAIM_MAX=10 osrc "$RH" '_OSRC_DISK_MONITOR=1; _osrc_disk_reclaim')"
[ "$n" = 0 ] && [ -d "$R/.outsourcerer/worktrees/gone" ] && ok "monitor reclaim obeys the shared setting, not launch env" || bad "env overrode shared setting: $n"
rm -f "$RH/disk-policy/settings"
# P1: a branch that moves just before deletion is kept (conditional ref delete).
n="$(osrc "$RH" '_osrc_branch_checked_out() { [ "${FUNCNAME[1]}" = _osrc_disk_reclaim_lane ] && [ "$2" = outsourcerer/race ] && git -C "$1" update-ref refs/heads/outsourcerer/race "$(git -C "$1" commit-tree -p refs/heads/outsourcerer/race -m moved "refs/heads/outsourcerer/race^{tree}")"; return 1; }
  _osrc_disk_reclaim')"
git -C "$R" rev-parse -q --verify refs/heads/outsourcerer/race >/dev/null && ok "branch that moved after the proof survives" || bad "moved branch deleted"
[ ! -d "$R/.outsourcerer/worktrees/gone" ] && ok "merged worktree removed" || bad "merged worktree kept"
git -C "$R" rev-parse -q --verify refs/heads/outsourcerer/gone >/dev/null && bad "merged branch kept" || ok "merged branch removed"
[ ! -d "$RH/tmp/gone-scratch" ] && ok "merged lane's scratch removed (incident 3)" || bad "scratch left behind"
[ -f "$RH/tmp/gone-env/.env" ] && ok "scratch holding .env kept" || bad ".env scratch deleted!"
[ -d "$RH/tmp/keep-scratch" ] && [ -f "$RH/tmp/user-notes/n.txt" ] && ok "unmerged lane's scratch and user data kept" || bad "adjacent data deleted!"
[ -f "$R/.outsourcerer/worktrees/deps/node_modules/pkg/.env" ] && ok "worktree with ignored node_modules/.env kept" || bad "protected files deleted!"
git -C "$R" cat-file -e "$FIX" 2>/dev/null && [ -d "$R/.outsourcerer/worktrees/detached" ] && ok "detached worktree with an unmerged fix kept" || bad "detached fix lost"
[ -d "$R/.outsourcerer/worktrees/wt-keep" ] && git -C "$R" rev-parse -q --verify refs/heads/outsourcerer/wt-keep >/dev/null \
  && ok "unmerged lane kept" || bad "UNMERGED lane deleted!"
[ -d "$R/.git/worktrees/usb-wt" ] && ok "unrelated worktree's admin record not pruned" || bad "repository-wide prune ran"
grep -q 'removed-branch.*outsourcerer/gone@' "$RH/cleanup.log" && grep -q removed-scratch "$RH/cleanup.log" \
  && ok "deletions logged with the verified commit" || bad "cleanup.log: $(cat "$RH/cleanup.log" 2>/dev/null)"

echo ""
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
