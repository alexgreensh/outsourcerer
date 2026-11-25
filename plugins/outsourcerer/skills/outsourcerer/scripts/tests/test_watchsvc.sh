#!/usr/bin/env bash
# sealed-run-requires: process-inspection
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_watchsvc.sh — the per-user watcher (lib/watchsvc.sh) and the waiter gaps it closes:
#   incident 1/2: a supervise hung in its hub/limits refresh kept its pid and armed file, so it
#     "covered" the session while it logged and delivered nothing (7 h; a done row 37 min late).
#   incident 3: the session's waiter died and finished lanes waited hours: the watcher wakes the
#     owner itself, verified, retried, loudly when it fails, once per row.
#   incident 4: lanes parked on a provider limit get one `continue` after the reset, once.
#   the stop guard: a watcher that can wake the session is a waiter; the guard never starts one.
#   round 3: reminder rows never move a reset later, hung probes die with their whole tree, stale
#   failure notices clear, a loop without `ps -o` still knows itself, the unit survives a plugin move,
#   a failed install leaves nothing behind, and the tmux wake works end to end.
#   round 5: --loop re-arms only on its own exit code (no spin, no ping-pong) and covers only with a
#   reader; a repointed fallback loop re-runs itself; other tmux servers are skipped whatever the channel.
# Run: bash test_watchsvc.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-watchsvc.XXXXXX")" || exit 1; PIDS=""
trap 'for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
export HOME="$TMP/userhome"; mkdir -p "$HOME" "$TMP/bin"
export OSRC_HEARTBEAT_DISABLED=1 OSRC_BLIND_TURN_GUARD=0 OSRC_STREAM=1 OSRC_WATCH_NOTIFY=0 OSRC_SUPERVISE_TICK_SECS=86400
export OSRC_CLAUDE_SESSIONS_DIR="$TMP/ccsessions" OSRC_CLAUDE_PROJECTS_DIR="$TMP/projects"
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID OSRC_WATCH_DELIVER_CMD
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
fresh() { export OSRC_HOME="$TMP/h$1"; mkdir -p "$OSRC_HOME/jobs" "$OSRC_HOME/lanes"; }
S() { ( set +u; export OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; eval "$1" ); }   # run in a sourced shell (product code runs without -u)
own() { mkdir -p "$OSRC_HOME/owners/$1"; : > "$OSRC_HOME/owners/$1/$2"; }
donejob() { mkdir -p "$OSRC_HOME/jobs/$1"; echo done > "$OSRC_HOME/jobs/$1/status"; echo "$(osrc_test_dead_pid)" > "$OSRC_HOME/jobs/$1/pid"; }
log() { S "_sv_append $1 $2 '$3' 'next-cmd' test '${4:-sess1}'"; }
tick_until() { # <cond> : tick (delivery is async) until cond holds, max ~6 s
  local i=0; while [ "$i" -lt 30 ]; do S "${PRE:-} _ws_tick"; eval "$1" && return 0; sleep 0.2; i=$((i+1)); done; return 1; }
fake_supervise() { # <sid> <alive-age-secs>: a live process that looks like a supervise, armed for <sid>
  bash -c 'sleep 60; : supervise' & local p=$!; PIDS="$PIDS $p"
  mkdir -p "$OSRC_HOME/supervise/$1"; echo '*' > "$OSRC_HOME/supervise/$1/armed.$p"
  perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1]' $(( $(date +%s) - $2 )) "$OSRC_HOME/supervise/$1/armed.$p"
  echo $(( $(date +%s) - $2 )) > "$OSRC_HOME/supervise/$1/alive"; sleep 0.3; }

echo "=== incident 1: a supervise that stopped polling is not a waiter ==="
fresh 1; own sess1 L1
fake_supervise sess1 5
[ "$(S '_waited_ids sess1' | grep -cx '\*')" = 1 ] && ok "a polling supervise covers its session" || no "fresh supervise not counted"
fresh 1b; own sess1 L1; fake_supervise sess1 3000
[ "$(S '_waited_ids sess1' | grep -cx '\*')" = 0 ] && ok "a live supervise pid with no poll for 50 min no longer covers (hang is visible)" || no "hung supervise still counted as a waiter"
sleep 300 >/dev/null 2>&1 & w=$!; PIDS="$PIDS $w"
mkdir -p "$OSRC_HOME/jobs/L1"; echo running > "$OSRC_HOME/jobs/L1/status"; echo "$w" > "$OSRC_HOME/jobs/L1/pid"; echo "$w" > "$OSRC_HOME/jobs/L1/supervisor_pid"
out="$(printf '{"session_id":"sess1"}' | "$SRC" stop-guard 2>/dev/null)"
grep -q '"decision":"block"' <<<"$out" && ok "stop guard blocks: the hung supervise does not satisfy it" || no "guard allowed the stop under a hung supervise [$out]"

echo "=== incident 2: a hung refresh cannot hold a logged done row back ==="
fresh 2; mkdir -p "$OSRC_HOME/supervise/sess2"; log done L9 'job finished (done)' sess2
out="$(OSRC_SUPERVISE_TICK_SECS=1 OSRC_SUPERVISE_TICK_TIMEOUT=2 OSRC_SUPERVISE_POLL=1 OSRC_SUPERVISE_SETTLE=0 perl -e 'alarm 20; exec @ARGV' \
  bash -c 'export OSRC_SOURCED=1; . "$0" >/dev/null 2>&1; cmd_hub_export() { x="$(sleep 120)"; }; cmd_supervise --session sess2' "$SRC" 2>/dev/null)"
grep -q '^EVENT done L9 ' <<<"$out" && ok "supervise delivers the done row although the hub refresh hangs" || no "done row held back by a hung refresh [$out]"
S 'probe() { x="$(sleep 4711; :)"; }; _sv_bounded 1 probe'; rc=$?; sleep 0.5
[ "$rc" = 124 ] && ! pgrep -f 'sleep 4711' >/dev/null 2>&1 && ok "a timed-out probe dies with its grandchildren (no leak per refresh)" || { no "bounded probe leaked [rc $rc]"; pkill -f 'sleep 4711'; }

echo "=== incident 3: the watcher wakes the owner when no waiter is armed ==="
fresh 3; own sess1 J1; donejob J1
export OSRC_WATCH_DELIVER_CMD="cat >> '$TMP/got3'; printf '%s\n' \"\$1\" >> '$TMP/sum3'"
S '_ws_tick'   # first sight: baseline (no supervise cursor) then the observe pass logs the done row
PRE="osrc_hub_seen_lane() { echo \"\$1 \$2\" >> '$TMP/seen3'; };"
grep -q '"kind":"done","target":"J1"' "$OSRC_HOME/lanes/events.jsonl" && ok "watcher observed the finished lane and logged it with its owner" || no "no done row logged"
tick_until '[ -s "$TMP/got3" ] && [ ! -f "$OSRC_HOME/watchsvc/sess1/inflight" ]' \
  && grep -q '^EVENT done J1 ' "$TMP/got3" && grep -q '^NEXT .* result J1' "$TMP/got3" \
  && ok "owner woken with the EVENT/NEXT lines (delivery verified by the channel's exit code)" || no "no wake delivered [$(cat "$TMP/got3" 2>/dev/null)]"
grep -q 'nothing to re-arm' "$TMP/sum3" && ok "wake text says no re-arm is needed" || no "wake text [$(cat "$TMP/sum3")]"
grep -qF "$(grep -o '"id":"[^"]*"' "$OSRC_HOME/lanes/events.jsonl" | head -1 | cut -d'"' -f4)" "$OSRC_HOME/supervise/sess1/delivered" \
  && ok "delivered rows are in supervise's ledger (a later supervise will not repeat them)" || no "ledger not updated"
[ ! -e "$OSRC_HOME/owners/sess1/J1" ] && ok "the reported finished lane leaves the owner registry (no reminder storm)" || no "owner marker kept"
grep -qx 'sess1 J1' "$TMP/seen3" 2>/dev/null && ok "the finished lane is marked seen on the hub, as supervise does" || no "hub not told [$(cat "$TMP/seen3" 2>/dev/null)]"
PRE=""
for i in 1 2 3; do S '_ws_tick'; done
[ "$(grep -c '^EVENT' "$TMP/got3")" = 1 ] && ok "one wake per row: later ticks deliver nothing again" || no "redelivered: $(grep -c '^EVENT' "$TMP/got3")"

fresh 3b; own sess1 .keep; S '_ws_tick'; rm -f "$TMP/got3"
log idle L2 'finished its turn'; rid="$(tail -1 "$OSRC_HOME/lanes/events.jsonl" | jq -r .id)"
mkdir -p "$OSRC_HOME/supervise/sess1"; printf '%s\t%s\n' "$(date +%s)" "$rid" > "$OSRC_HOME/supervise/sess1/delivered"
S '_ws_tick'; sleep 1; S '_ws_tick'; [ ! -s "$TMP/got3" ] && ok "a row a supervise already printed is not woken again" || no "duplicated a supervise delivery"
fresh 3c; own sess1 .keep; S '_ws_tick'; rm -f "$TMP/got3"; fake_supervise sess1 2; log idle L2 'finished its turn'
S '_ws_tick'; sleep 1; S '_ws_tick'; [ ! -s "$TMP/got3" ] && [ -s "$OSRC_HOME/watchsvc/sess1/pending" ] && ok "a live, polling supervise delivers instead; the row stays pending" || no "watcher raced a live supervise"

echo "=== incident 3: failed delivery retries with backoff and becomes loud ==="
fresh 3d; own sess1 .keep; S '_ws_tick'
export OSRC_WATCH_DELIVER_CMD="echo try >> '$TMP/tries'; exit 1"; log question L3 'stopped and asked'
tick_until '[ -f "$OSRC_HOME/watchsvc/sess1/try" ]'; t0="$(date +%s)"
[ "$(grep -c . "$TMP/tries" 2>/dev/null)" = 1 ] && ok "failed delivery recorded (attempt 1)" || no "tries: $(cat "$TMP/tries")"
S '_ws_tick'; [ "$(grep -c . "$TMP/tries" 2>/dev/null)" = 1 ] && ok "no retry inside the backoff window" || no "retried at once"
att() { [ "$(cut -d' ' -f1 "$OSRC_HOME/watchsvc/sess1/try" 2>/dev/null)" = "$1" ] && [ ! -f "$OSRC_HOME/watchsvc/sess1/inflight" ]; }
OSRC_NOW=$((t0 + 61)) tick_until 'att 2'; OSRC_NOW=$((t0 + 400)) tick_until 'att 3' 
[ "$(grep -c . "$TMP/tries" 2>/dev/null)" -ge 3 ] && [ -s "$OSRC_HOME/owners/sess1/.wakefail" ] && ok "after 3 failed attempts .wakefail is written" || no "tries=$(grep -c . "$TMP/tries" 2>/dev/null) wakefail=$(cat "$OSRC_HOME/owners/sess1/.wakefail" 2>/dev/null)"
grep -q 'WAKE NOT DELIVERED' <<<"$(CLAUDE_CODE_SESSION_ID=sess1 S '_sg_print_unguarded' 2>&1)" && ok "every outsourcerer call prints the delivery failure" || no "failure not printed"
grep -q 'sess1: 1 event(s) pending, channel=custom, DELIVERY FAILING' <<<"$("$SRC" watcher status 2>/dev/null)" && ok "watcher status shows the failing delivery" || no "status: $("$SRC" watcher status 2>&1)"
export OSRC_WATCH_DELIVER_CMD="cat > '$TMP/got3d'"
OSRC_NOW=$((t0 + 4000)) tick_until "[ -s '$TMP/got3d' ] && [ ! -f '$OSRC_HOME/watchsvc/sess1/inflight' ]"
[ ! -e "$OSRC_HOME/owners/sess1/.wakefail" ] && grep -q '^EVENT question L3' "$TMP/got3d" && ok "a later success delivers and clears the failure" || no "recovery failed"
unset OSRC_WATCH_DELIVER_CMD
fresh 3g; own sess1 .keep; S '_ws_tick'; log question L6 'stopped and asked'; rid="$(tail -1 "$OSRC_HOME/lanes/events.jsonl" | jq -r .id)"
OSRC_WATCH_WAKE_MAX=1 S '_ws_tick'
[ -s "$OSRC_HOME/owners/sess1/.wakefail" ] || no "setup: no .wakefail"
mkdir -p "$OSRC_HOME/supervise/sess1"; printf '%s\t%s\n' "$(date +%s)" "$rid" > "$OSRC_HOME/supervise/sess1/delivered"   # the recommended supervise got it
S '_ws_tick'
[ ! -e "$OSRC_HOME/owners/sess1/.wakefail" ] && [ ! -e "$OSRC_HOME/watchsvc/sess1/try" ] \
  && ok "once a supervise delivered the rows, the failure notice and retry state are gone" || no "stale .wakefail kept"
rm -f "$OSRC_HOME/owners/sess1/.keep"; S '_ws_tick'
[ ! -d "$OSRC_HOME/owners/sess1" ] && [ ! -d "$OSRC_HOME/watchsvc/sess1" ] && ok "an owner dir with nothing owned or owed leaves the loop" || no "empty owner dir kept: polled forever"
fresh 3h; mkdir -p "$OSRC_HOME/watchsvc/gone1"; echo '%9' > "$OSRC_HOME/watchsvc/gone1/pane"; S '_ws_tick'
[ ! -d "$OSRC_HOME/watchsvc/gone1" ] && ok "a session with a recorded pane but nothing owned is reclaimed" || no "pane dir kept forever"
fresh 3i; mkdir -p "$OSRC_HOME/owners/sess1" "$OSRC_HOME/watchsvc/sess1"
[ "$(S "_ws_owner() { echo \"\$1\"; }; _ws_tick")" = sess1 ] && ok "an owner in both lists is processed once per tick" || no "owner processed twice"
mkdir -p "$OSRC_HOME/watchsvc/sess1"; echo "999999 0 custom $$" > "$OSRC_HOME/watchsvc/sess1/inflight"
S 'kill() { [ "$1" = -0 ] && { echo 0 > "$OSRC_HOME/watchsvc/sess1/rc"; return 1; }; builtin kill "$@"; }; _ws_settle sess1 "$OSRC_HOME/watchsvc/sess1"'
[ ! -e "$OSRC_HOME/watchsvc/sess1/try" ] && [ -f "$OSRC_HOME/watchsvc/sess1/sent" ] && ok "a delivery that finishes between the two checks counts as delivered" || no "settle race scored a success as failed"
printf '1\tr-x\n' > "$OSRC_HOME/watchsvc/sess1/rows"; echo "1 $(date +%s) custom" > "$OSRC_HOME/watchsvc/sess1/inflight"; echo 0 > "$OSRC_HOME/watchsvc/sess1/rc"
mkdir -p "$OSRC_HOME/supervise/sess1/delivered.lock"
S '_ws_settle sess1 "$OSRC_HOME/watchsvc/sess1"'
[ -f "$OSRC_HOME/watchsvc/sess1/inflight" ] && [ ! -s "$OSRC_HOME/supervise/sess1/delivered" ] && ok "ledger lock held by a supervise: settle waits for the next tick" || no "wrote the ledger without its lock"
rmdir "$OSRC_HOME/supervise/sess1/delivered.lock"; S '_ws_settle sess1 "$OSRC_HOME/watchsvc/sess1"'
[ ! -f "$OSRC_HOME/watchsvc/sess1/inflight" ] && [ -s "$OSRC_HOME/supervise/sess1/delivered" ] && ok "and records it once the lock is free" || no "never settled"
sleep 300 & st=$!; PIDS="$PIDS $st"; rm -f "$OSRC_HOME/watchsvc/sess1/rc"
echo "$st 1 custom" > "$OSRC_HOME/watchsvc/sess1/inflight"; S '_ws_settle sess1 "$OSRC_HOME/watchsvc/sess1"'
kill -0 "$st" 2>/dev/null && [ ! -f "$OSRC_HOME/watchsvc/sess1/inflight" ] && ok "a delivery recorded before a restart is over: its pid (now a stranger's) is never signalled" || no "killed a process the watcher did not start"
echo "$st 1 custom $$" > "$OSRC_HOME/watchsvc/sess1/inflight"; S '_ws_settle sess1 "$OSRC_HOME/watchsvc/sess1"'
kill -0 "$st" 2>/dev/null && [ ! -f "$OSRC_HOME/watchsvc/sess1/inflight" ] && ok "a timed-out pid that is not this loop's fork is given up on, not killed" || no "killed a reused pid"
kill "$st" 2>/dev/null
printf '#!/bin/sh\necho "$*" >> %s/notes\n' "$TMP" > "$TMP/bin/notify-send"; chmod +x "$TMP/bin/notify-send"
# The script sets OSRC_PLATFORM from uname, so on a Mac the notifier is osascript: stub it too, or the
# suite pops real desktop notifications and never counts them.
printf '#!/bin/sh\necho "$*" >> %s/notes\n' "$TMP" > "$TMP/bin/osascript"; chmod +x "$TMP/bin/osascript"
PATH="$TMP/bin:$PATH" OSRC_WATCH_NOTIFY=1 OSRC_PLATFORM=linux S 'for i in 1 2 3 4 5 6 7 8 9; do _ws_failed sess1 "$OSRC_HOME/watchsvc/sess1" test; done'; sleep 0.5
[ "$(grep -c . "$TMP/notes" 2>/dev/null)" = 1 ] && ok "a failing wake notifies once, not hourly forever" || no "notifications: $(grep -c . "$TMP/notes" 2>/dev/null)"
rm -f "$TMP/notes"
head -c 300000 /dev/zero | tr '\0' 'x' > "$OSRC_HOME/watchsvc/service.log"; S '_ws_tick'
[ "$(wc -c < "$OSRC_HOME/watchsvc/service.log" | tr -d ' ')" -le 262144 ] && ok "service.log stays bounded" || no "service.log unbounded"
fresh 3e; own sess1 .keep; S '_ws_tick'; log idle L4 'finished its turn'; S '_ws_tick'
[ -f "$OSRC_HOME/watchsvc/sess1/try" ] && [ ! -f "$OSRC_HOME/watchsvc/sess1/inflight" ] && ok "no channel (not in tmux, no command, session open): counted as a failed wake, not dropped" || no "no-channel case"

echo "=== reminders do not re-wake within OSRC_WATCH_REWAKE ==="
fresh 3f; own sess1 .keep; S '_ws_tick'; export OSRC_WATCH_DELIVER_CMD="cat >> '$TMP/got3f'"
log idle L5 'finished its turn'; tick_until "[ -s '$TMP/got3f' ] && [ ! -f '$OSRC_HOME/watchsvc/sess1/inflight' ]"
log idle L5 'still unresolved, waiting 5m: finished its turn'; for i in 1 2 3; do S '_ws_tick'; done
[ "$(grep -c '^EVENT' "$TMP/got3f")" = 1 ] && ok "an ignored lane's reminder rows do not burn a wake every 5 min" || no "reminder re-woke"
OSRC_NOW=$(( $(date +%s) + 4000 )) S "_sv_append idle L5 'still unresolved, waiting 70m: finished its turn' n test sess1"
OSRC_NOW=$(( $(date +%s) + 4000 )) tick_until "[ \$(grep -c '^EVENT' '$TMP/got3f') = 2 ]" && ok "after an hour the reminder wakes once more" || no "no rewake"
unset OSRC_WATCH_DELIVER_CMD

echo "=== incident 4: one continue per limit reset, only for limit-parked lanes ==="
fresh 4; printf '#!/bin/sh\necho "$OUTSOURCERER_TMUX $*" >> %s/sent4\n' "$TMP" > "$TMP/bin/fake-osrc"; chmod +x "$TMP/bin/fake-osrc"
for l in A B C; do own sess1 $l; done
now="$(date +%s)"
limit_state() { S "_sv_state_read $1; SVS_LK='$2'; _sv_state_write $1"; }
limit_state A limit:111; limit_state B limit:222; limit_state C working:1
log limit A "plan limit hit: quota reached, resets 23:00 (epoch $((now - 10)))"
log limit B "plan limit hit: quota reached, resets later (epoch $((now + 3600)))"
log limit C "plan limit hit: quota reached (epoch $((now - 10)))"
lim() { S "SCRIPT_PATH='$TMP/bin/fake-osrc'; ${1:-} _ws_limits"; }
lim; [ ! -s "$TMP/sent4" ] && ok "a watcher nobody installed never types a continue" || no "uninstalled watcher continued a lane"
mkdir -p "$OSRC_HOME/watchsvc"; echo fallback > "$OSRC_HOME/watchsvc/installed"
lim   # no limits/.cursor yet: banners logged before the install still count
grep -qx 'A session send continue' "$TMP/sent4" && ok "reset passed + still limit-parked -> one continue, also for a banner older than the install" || no "no continue for A [$(cat "$TMP/sent4" 2>/dev/null)]"
! grep -q '^B ' "$TMP/sent4" && ok "reset not yet passed -> waits" || no "B continued early"
! grep -q '^C ' "$TMP/sent4" && ok "a lane no longer on the limit is never continued" || no "C continued"
grep -q '"kind":"limit-resumed","target":"A"' "$OSRC_HOME/lanes/events.jsonl" && ok "the continue is logged (informational row)" || no "no limit-resumed row"
lim; lim; [ "$(grep -c '^A ' "$TMP/sent4")" = 1 ] && ok "once per reset: no resend while the banner stays" || no "A resent"
lim "OSRC_NOW=$((now + 3700))"; [ "$(grep -c '^B ' "$TMP/sent4")" = 1 ] && ok "after its reset B gets its one continue" || no "B never continued"
log limit A "plan limit hit: again (epoch $((now + 7000)))"; lim "OSRC_NOW=$((now + 7100))"
[ "$(grep -c '^A ' "$TMP/sent4")" = 2 ] && ok "a NEW limit later gets its own continue" || no "second limit ignored"
rm -f "$OSRC_HOME/owners/sess1/A"; log limit A "plan limit hit: x (epoch $((now + 8000)))"; lim "OSRC_NOW=$((now + 8100))"
[ "$(grep -c '^A ' "$TMP/sent4")" = 2 ] && ok "a lane nobody owns any more is left alone" || no "continued an unowned lane"
own sess1 D; limit_state D limit:444; t0=$((now + 20000))
OSRC_NOW=$t0 log limit D "plan limit hit: try again in 2 hours"; lim "OSRC_NOW=$t0"
OSRC_NOW=$((t0 + 1200)) log limit D "still unresolved, waiting 20m: plan limit hit: try again in 2 hours"; lim "OSRC_NOW=$((t0 + 1200))"
lim "OSRC_NOW=$((t0 + 7300))"; grep -q '^D ' "$TMP/sent4" && ok "a reminder of a relative banner does not push the reset later" || no "reset snoozed by its own reminder [$(cat "$OSRC_HOME/watchsvc/limits/D")]"
own sess1 E; limit_state E limit:555; printf '#!/bin/sh\necho x >> %s/fails4; exit 1\n' "$TMP" > "$TMP/bin/fail-osrc"; chmod +x "$TMP/bin/fail-osrc"
log limit E "plan limit hit: x (epoch $((now - 5)))"; S "SCRIPT_PATH='$TMP/bin/fail-osrc'; _ws_limits"
[ ! -e "$OSRC_HOME/watchsvc/limits/E.done" ] && ! grep -q '"kind":"limit-resumed","target":"E"' "$OSRC_HOME/lanes/events.jsonl" && ok "a failed continue is not logged as sent; it is retried" || no "failed continue marked done"
S "SCRIPT_PATH='$TMP/bin/fail-osrc'; _ws_limits"; [ "$(grep -c . "$TMP/fails4")" = 1 ] && ok "a failed continue backs off (no full script spawn every tick)" || no "retried at once: $(grep -c . "$TMP/fails4")"
lim "OSRC_NOW=$(( $(date +%s) + 61 ))"; [ "$(grep -c '^E ' "$TMP/sent4")" = 1 ] && ok "the retry sends it once" || no "E retry"
own sess1 G; limit_state G limit:777; log limit G "plan limit hit: z (epoch $((now + 100)))"; lim; rm -f "$OSRC_HOME/owners/sess1/G"
lim "OSRC_NOW=$((now + 200))"; ! grep -q '^G ' "$TMP/sent4" && ok "ownership is checked again when the continue is due" || no "continued a lane disowned after its banner"
own sess1 F; limit_state F limit:666; log limit F "plan limit hit: y (epoch $((now - 5)))"
f4="$OSRC_HOME/lanes/events.jsonl"; mv "$f4" "$f4.1"; : > "$f4"; echo 1 > "$OSRC_HOME/lanes/events.gen"
lim; [ "$(grep -c '^F ' "$TMP/sent4")" = 1 ] && ok "a limit row logged just before log rotation is still seen" || no "rotation skipped the limit row"

echo "=== stop guard: a watcher that can wake the session is a waiter; the guard starts none ==="
fresh 5; sleep 300 >/dev/null 2>&1 & w=$!; PIDS="$PIDS $w"
mkdir -p "$OSRC_HOME/jobs/R1"; echo running > "$OSRC_HOME/jobs/R1/status"; echo "$w" > "$OSRC_HOME/jobs/R1/pid"; echo "$w" > "$OSRC_HOME/jobs/R1/supervisor_pid"; own sess5 R1
guard() { printf '{"session_id":"sess5","cwd":"%s"}' "$TMP" | "$SRC" stop-guard 2>"$TMP/err5"; }
guard >/dev/null; [ ! -e "$OSRC_HOME/watchsvc" ] && ok "no watcher on this machine: the hook leaves no watcher state" || no "watchsvc/<sid> made with no watcher"
rm -f "$OSRC_HOME/owners/sess5/.stop-blocks"
mkdir -p "$OSRC_HOME/watchsvc"; date +%s > "$OSRC_HOME/watchsvc/alive"
out="$(guard)"; grep -q '"decision":"block"' <<<"$out" && ok "watcher alive but no channel to this session: still blocks" || no "allowed with no channel [$out]"
out="$(OSRC_WATCH_DELIVER_CMD=true guard)"; grep -q '"decision":"block"' <<<"$out" && ok "a fresh stamp without a live watcher process is not a waiter" || no "allowed with no watcher process [$out]"
bash -c 'sleep 300; : watcher run' & wp=$!; PIDS="$PIDS $wp"; mkdir -p "$OSRC_HOME/watchsvc/run.lock"; echo "$wp" > "$OSRC_HOME/watchsvc/run.lock/pid"; sleep 0.3
out="$(OSRC_WATCH_DELIVER_CMD=true guard)"; [ -z "$out" ] && ok "watcher alive and able to wake the session: the stop is allowed" || no "blocked [$out]"
echo 'WAKE NOT DELIVERED: test' > "$OSRC_HOME/owners/sess5/.wakefail"
out="$(OSRC_WATCH_DELIVER_CMD=true guard)"; grep -q '"decision":"block"' <<<"$out" && ok "a channel that keeps failing (.wakefail) is not a waiter" || no "failing channel trusted [$out]"
rm -f "$OSRC_HOME/owners/sess5/.wakefail" "$OSRC_HOME/owners/sess5/.stop-blocks"
printf 'export PATH=%q\n' "$PATH" > "$OSRC_HOME/watchsvc/env"
out="$(OSRC_WATCH_DELIVER_CMD=true guard)"; grep -q '"decision":"block"' <<<"$out" && ok "coverage is judged by the watcher's settings, not the hook's" || no "hook-only delivery command trusted [$out]"
rm -f "$OSRC_HOME/watchsvc/env"; kill "$wp" 2>/dev/null; rm -rf "$OSRC_HOME/watchsvc/run.lock"
[ "$(cat "$OSRC_HOME/watchsvc/sess5/cwd" 2>/dev/null)" = "$TMP" ] && ok "the hook records the session's cwd for the channels" || no "cwd not recorded"
rm -f "$OSRC_HOME/watchsvc/alive"
guard >/dev/null; out="$(guard)"; out="$(guard)"
[ -z "$out" ] && grep -q 'NO watcher is running' "$OSRC_HOME/owners/sess5/.unguarded" && ok "loop safety kept: yields after the max, and says no watcher runs" || no "yield [$out] $(cat "$OSRC_HOME/owners/sess5/.unguarded" 2>/dev/null)"
rm -f "$OSRC_HOME/owners/sess5/.stop-blocks" "$OSRC_HOME/owners/sess5/.unguarded"; guard >/dev/null; guard >/dev/null
out="$(PATH="$TMP/bin:$PATH" OSRC_WATCH_NOTIFY=1 guard)"; out="$(PATH="$TMP/bin:$PATH" OSRC_WATCH_NOTIFY=1 guard)"; sleep 1
[ -z "$out" ] && [ ! -d "$OSRC_HOME/watchsvc/run.lock" ] && ! grep -rq 'watcher run' "$OSRC_HOME/watchsvc/service.log" 2>/dev/null \
  && grep -q 'ask the user to run' "$OSRC_HOME/owners/sess5/.unguarded" && ok "the yield starts no daemon; it names the install command for the user" || no "guard started a watcher [$out]"
[ "$(grep -c . "$TMP/notes" 2>/dev/null)" = 1 ] && ok "one notification per yield, not one per turn end" || no "notifications: $(grep -c . "$TMP/notes" 2>/dev/null)"
grep -q 'ask the user to run' <<<"$(rm -f "$OSRC_HOME/owners/sess5/.stop-blocks"; guard)" && ok "the block reason asks the user to install, the agent does not" || no "block reason invites an install"
printf '{"session_id":"sess5"}' | OSRC_HOME="$TMP/broken-home-$$" "$SRC" stop-guard >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "guard on a missing home exits 0 (never traps the user)" || no "guard rc $rc"

echo "=== watcher run: single instance, stamps, a loop without its lock exits ==="
fresh 6; OSRC_WATCH_INTERVAL=1 "$SRC" watcher run >/dev/null 2>&1 & d=$!; PIDS="$PIDS $d"; sleep 1.5
[ -f "$OSRC_HOME/watchsvc/alive" ] && ok "daemon ticks and stamps" || no "no stamp"
grep -q 'already running' <<<"$("$SRC" watcher run 2>&1)" && ok "a second run exits (single instance)" || no "second instance ran"
mkdir -p "$TMP/nops"; printf '#!/bin/sh\ncase " $* " in *" -o "*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v ps)" > "$TMP/nops/ps"; chmod +x "$TMP/nops/ps"
grep -q 'already running' <<<"$(PATH="$TMP/nops:$PATH" perl -e 'alarm 5; exec @ARGV' "$SRC" watcher run 2>&1)" && [ "$(cat "$OSRC_HOME/watchsvc/run.lock/pid")" = "$d" ] \
  && ok "without ps -o (Git Bash) a live loop still holds its lock" || no "lock stolen when ps -o is missing"
sleep 300 & st=$!; PIDS="$PIDS $st"; mkdir -p "$TMP/h6x/watchsvc/run.lock"; echo "$st" > "$TMP/h6x/watchsvc/run.lock/pid"
[ -z "$(PATH="$TMP/nops:$PATH" OSRC_HOME="$TMP/h6x" S '_ws_daemon_pid')" ] && ok "without ps -o a live pid with no fresh tick is not the watcher (never signalled)" || no "stranger pid taken for the watcher"
kill "$st" 2>/dev/null
echo 1 > "$OSRC_HOME/watchsvc/run.lock/pid"; i=0; while kill -0 "$d" 2>/dev/null && [ "$i" -lt 25 ]; do sleep 0.2; i=$((i+1)); done
! kill -0 "$d" 2>/dev/null && ok "a loop whose lock was taken over exits (no pile-up)" || no "loop kept running without its lock"
fresh 6b; mkdir -p "$OSRC_HOME/watchsvc"; printf '# script: %s\n' "$SRC" > "$OSRC_HOME/watchsvc/launch"; echo fallback > "$OSRC_HOME/watchsvc/installed"
ln -s "$SCRIPT_DIR/.." "$TMP/plugin-v2"
OSRC_WATCH_INTERVAL=1 "$SRC" watcher run >/dev/null 2>&1 & d=$!; PIDS="$PIDS $d"; sleep 1.5
kill -0 "$d" 2>/dev/null || no "setup: loop did not start under its own launcher"
S "SCRIPT_PATH='$TMP/plugin-v2/outsourcerer.sh'; _ws_launcher"; i=0; until { grep -q 'plugin-v2/outsourcerer.sh watcher run' <<<"$(ps -o command= -p "$d" 2>/dev/null)" && [ "$(cat "$OSRC_HOME/watchsvc/run.lock/pid" 2>/dev/null)" = "$d" ]; } || [ "$i" -ge 25 ]; do sleep 0.2; i=$((i+1)); done
p="$(cat "$OSRC_HOME/watchsvc/run.lock/pid" 2>/dev/null)"
[ "$p" = "$d" ] && grep -q 'plugin-v2/outsourcerer.sh watcher run' <<<"$(ps -o command= -p "$d" 2>/dev/null)" && ok "a fallback loop whose launcher now names another plugin copy re-runs itself there (nobody has to restart it)" || no "repointed loop not running on the new copy [pid $p: $(ps -o command= -p "$d" 2>/dev/null)]"
S '_ws_stop_loop'
fresh 6c; OSRC_SOURCED=1 OSRC_WATCH_INTERVAL=1 bash -c '. "$0" >/dev/null 2>&1; _ws_tick() { x="$(sleep 4713; :)"; }; _ws_run' "$SRC" watcher run >/dev/null 2>&1 & d=$!; PIDS="$PIDS $d"
i=0; until pgrep -f '^sleep 4713' >/dev/null 2>&1 || [ "$i" -ge 25 ]; do sleep 0.2; i=$((i+1)); done
S '_ws_stop_loop'; sleep 0.5
! kill -0 "$d" 2>/dev/null && ! pgrep -f '^sleep 4713' >/dev/null 2>&1 && ok "stopping the loop takes its in-flight tick with it" || { no "tick orphaned by stop"; pkill -f '^sleep 4713'; }
fresh 6d; mkdir -p "$OSRC_HOME/supervise/sess6"
OSRC_SUPERVISE_TICK_SECS=1 OSRC_SUPERVISE_TICK_TIMEOUT=600 bash -c 'export OSRC_SOURCED=1; . "$0" >/dev/null 2>&1; cmd_hub_export() { x="$(sleep 4714; :)"; }; cmd_supervise --session sess6' "$SRC" >/dev/null 2>&1 & d=$!; PIDS="$PIDS $d"
i=0; until pgrep -f '^sleep 4714' >/dev/null 2>&1 || [ "$i" -ge 50 ]; do sleep 0.2; i=$((i+1)); done
kill -TERM "$d"; i=0; while kill -0 "$d" 2>/dev/null && [ "$i" -lt 40 ]; do sleep 0.2; i=$((i+1)); done; sleep 0.5
! pgrep -f '^sleep 4714' >/dev/null 2>&1 && ok "a supervise signalled mid-refresh takes the hung probe with it" || { no "probe orphaned by a signalled supervise"; pkill -f '^sleep 4714'; }

echo "=== supervise --loop: re-arms only after a delivered batch, covers only with a reader ==="
job() { sleep 300 >/dev/null 2>&1 & local w=$!; PIDS="$PIDS $w"; mkdir -p "$OSRC_HOME/jobs/$1"; echo running > "$OSRC_HOME/jobs/$1/status"; echo "$w" > "$OSRC_HOME/jobs/$1/pid"; echo "$w" > "$OSRC_HOME/jobs/$1/supervisor_pid"; own "$2" "$1"; }
covers() { [ "$(S "_waited_ids $1" 2>/dev/null | grep -cx '\*')" -ge 1 ]; }
until_t() { local i=0; until eval "$1" || [ "$i" -ge 40 ]; do sleep 0.2; i=$((i+1)); done; eval "$1"; }
export OSRC_SUPERVISE_POLL=1 OSRC_SUPERVISE_SETTLE=0
fresh 13a; own sessH N1   # owned, never dropped, nothing live (a lane with "no turn yet")
# The alarm only catches a hot spin (which prints many done-all lines); 30 s, not 8, so a loaded machine
# that ends correctly but slowly is not failed (seen at load 34).
out="$(perl -e 'alarm 30; exec @ARGV' bash -c 'export OSRC_SOURCED=1; . "$0" >/dev/null 2>&1
  _sv_observe() { SV_K=""; SV_D=""; SV_H=0; SV_OUT=0; SV_DROP=0; SV_PEND=0; SV_NX=""; SV_WT=""; SV_STOPPED=0; SV_RM=""; SV_HA=""; SV_STALL_START=""; }
  cmd_supervise --session sessH --loop' "$SRC" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^EVENT done all' <<<"$out")" = 1 ] && ok "--loop ends on done all (no hot spin while a lane has no turn yet)" || no "rc=$rc, $(grep -c '^EVENT done all' <<<"$out") done-all lines"
fresh 13b; job R5 sessP
"$SRC" supervise --session sessP --loop > "$TMP/pa" 2>&1 & a=$!; PIDS="$PIDS $a"; sleep 2.5
"$SRC" supervise --session sessP --loop > "$TMP/pb" 2>&1 & b=$!; PIDS="$PIDS $b"; sleep 4
"$SRC" supervise --session sessP > "$TMP/pc" 2>&1 & c=$!; PIDS="$PIDS $c"; sleep 4
! kill -0 "$a" 2>/dev/null && ! kill -0 "$b" 2>/dev/null && kill -0 "$c" 2>/dev/null \
  && [ "$(grep -c superseded "$TMP/pa")" = 1 ] && [ "$(grep -c superseded "$TMP/pb")" = 1 ] && ! grep -q superseded "$TMP/pc" \
  && ok "two --loop arms and a plain supervise: each older one is superseded once and stays gone (no ping-pong)" \
  || no "ping-pong: alive a=$(kill -0 "$a" 2>/dev/null && echo y) b=$(kill -0 "$b" 2>/dev/null && echo y) c=$(kill -0 "$c" 2>/dev/null && echo y); superseded a=$(grep -c superseded "$TMP/pa") b=$(grep -c superseded "$TMP/pb") c=$(grep -c superseded "$TMP/pc")"
kill "$c" "$a" "$b" 2>/dev/null
fresh 13c; job R6 sessR
"$SRC" supervise --session sessR --loop > "$TMP/lf" 2>/dev/null & lf=$!; PIDS="$PIDS $lf"; sleep 1.5
log idle R6 'finished its turn' sessR; until_t "grep -q '^EVENT idle R6' '$TMP/lf'"; sleep 0.5
# Review r5: into a file nobody reads, --loop runs as a plain supervise, so its exit wakes the agent.
until_t "! kill -0 $lf 2>/dev/null"
! kill -0 "$lf" 2>/dev/null && [ -z "$(ls "$OSRC_HOME/supervise/sessR"/loop.* 2>/dev/null)" ] && ! covers sessR \
  && ok "a --loop writing into a file (an agent's background task) exits on its first batch, like plain supervise" || no "file-backed loop kept running: alive=$(kill -0 "$lf" 2>/dev/null && echo y)"
kill "$lf"; until_t "! kill -0 $lf 2>/dev/null"
fresh 13d; job R3 sessL
( "$SRC" supervise --session sessL --loop 2>/dev/null | cat > "$TMP/loop13" ) & lp=$!; PIDS="$PIDS $lp"
until_t "ls '$OSRC_HOME/supervise/sessL'/loop.* >/dev/null 2>&1"; sleep 1
! covers sessL && ok "a --loop into a pipe covers nothing before a batch went through it" || no "loop covered with no reader proven"
log idle R3 'finished its turn' sessL; until_t "covers sessL" && ok "after a batch went into the pipe it covers the session" || no "piped loop never covered"
gaps=0; for i in $(seq 1 40); do covers sessL || gaps=$((gaps+1)); [ "$i" = 15 ] && log idle R3 'finished its turn again' sessL; sleep 0.1; done
until_t "[ \$(grep -c '^EVENT ' '$TMP/loop13') -ge 2 ]"
[ "$gaps" = 0 ] && [ "$(grep -c '^EVENT ' "$TMP/loop13")" -ge 2 ] && ok "and delivers batch after batch with no gap in between" || no "gaps=$gaps events=$(grep -c '^EVENT ' "$TMP/loop13")"
f="$(ls "$OSRC_HOME/supervise/sessL"/loop.* 2>/dev/null | head -1)"; kill "${f##*.}"; until_t "[ -z \"\$(ls '$OSRC_HOME/supervise/sessL'/loop.* 2>/dev/null)\" ]"
[ -z "$(ls "$OSRC_HOME/supervise/sessL"/loop.* 2>/dev/null)" ] && ! covers sessL && ok "and stops covering once it exits" || no "loop marker left behind"
unset OSRC_SUPERVISE_POLL OSRC_SUPERVISE_SETTLE
h="$(sed -n '2,/^$/p' "$SCRIPT_DIR/../lib/supervise.sh" | grep . | tail -1 | sed 's/^# //')"
[ "$("$SRC" supervise --help | grep . | tail -1)" = "$h" ] && ok "supervise --help prints the whole header" || no "help cut short"

echo "=== round 5: other tmux servers, a watcher's first tick, deliveries across a restart, limit backoff ==="
# Review r5 P2: a session on another tmux server is recorded as foreign when it first owns a lane, not
# at its first Stop, so the watcher's very first tick skips its lanes (no false gone rows).
fresh 17b; mkdir -p "$OSRC_HOME/watchsvc"; : > "$OSRC_HOME/watchsvc/installed"
S 'export CLAUDE_CODE_SESSION_ID=sessG TMUX="'"$TMP"'/work-sock,9,0" TMUX_PANE=%3; _owner_record G7'
[ -f "$OSRC_HOME/owners/sessG/G7" ] && [ -s "$OSRC_HOME/watchsvc/sessG/sock" ] && S 'unset TMUX TMUX_PANE; _ws_foreign sessG' \
  && ok "owning a lane records the session's tmux server, so the watcher skips it from the first tick" || no "no server recorded at ownership: $(cat "$OSRC_HOME/watchsvc/sessG/sock" 2>/dev/null)"
S 'unset TMUX TMUX_PANE; _ws_tick'; ! grep -q '"src":"watcher"' "$OSRC_HOME/lanes/events.jsonl" 2>/dev/null \
  && ok "first tick logs no rows for a foreign session's lanes" || no "false watcher rows: $(grep -c watcher "$OSRC_HOME/lanes/events.jsonl")"
fresh 17; own sessF G1; mkdir -p "$OSRC_HOME/watchsvc/sessF"; echo "$TMP/other-sock" > "$OSRC_HOME/watchsvc/sessF/sock"
export OSRC_WATCH_DELIVER_CMD="cat > '$TMP/got17'"; S '_ws_tick'; log idle G1 'finished its turn' sessF; S '_ws_tick'; sleep 1; S '_ws_tick'; unset OSRC_WATCH_DELIVER_CMD
[ ! -e "$TMP/got17" ] && [ -f "$OSRC_HOME/owners/sessF/G1" ] && ! grep -q '"src":"watcher"' "$OSRC_HOME/lanes/events.jsonl" \
  && ok "a session on another tmux server is skipped even with a delivery command (no rows, no wake, markers kept)" || no "foreign session handled: got=$(cat "$TMP/got17" 2>/dev/null) rows=$(grep -c watcher "$OSRC_HOME/lanes/events.jsonl")"
bash -c 'sleep 300; : watcher run' & wp=$!; PIDS="$PIDS $wp"; mkdir -p "$OSRC_HOME/watchsvc/run.lock"; echo "$wp" > "$OSRC_HOME/watchsvc/run.lock/pid"; date +%s > "$OSRC_HOME/watchsvc/alive"; sleep 0.3
! OSRC_WATCH_DELIVER_CMD=true S '_ws_covers sessF' && OSRC_WATCH_DELIVER_CMD=true S 'rm -f "$OSRC_HOME/watchsvc/sessF/sock"; _ws_covers sessF' \
  && ok "and the stop guard does not count the watcher for it (it does once the session is on the watcher's server)" || no "guard trusts a watcher on another tmux server"
kill "$wp" 2>/dev/null
fresh 18; OSRC_SOURCED=1 OSRC_WATCH_INTERVAL=1 bash -c '. "$0" >/dev/null 2>&1; _ws_tick() { sleep 30; }; _ws_run' "$SRC" watcher run >/dev/null 2>&1 & d=$!; PIDS="$PIDS $d"; sleep 1
[ "$(PATH="$TMP/nops:$PATH" S '_ws_daemon_pid')" = "$d" ] && ok "without ps -o a loop in its first (slow) tick is still known as the watcher (no rival)" || no "starting loop not recognised without ps -o"
kill "$d" 2>/dev/null
fresh 19; mkdir -p "$OSRC_HOME/watchsvc/sessI"; bash -c 'sleep 300; : watcher run' & st=$!; PIDS="$PIDS $st"   # a delivery is a fork of the watcher
echo "$st $(date +%s) custom 999999" > "$OSRC_HOME/watchsvc/sessI/inflight"; S '_ws_settle sessI "$OSRC_HOME/watchsvc/sessI"'
[ -f "$OSRC_HOME/watchsvc/sessI/inflight" ] && [ ! -e "$OSRC_HOME/watchsvc/sessI/try" ] && kill -0 "$st" && ok "a delivery an earlier loop started is pending while it runs, not failed" || no "running delivery failed by a restart"
# Review r5: after a reboot the recorded pid may be a stranger's; that is no delivery to wait 30 min for.
fresh 19b; mkdir -p "$OSRC_HOME/watchsvc/sessJ"; sleep 300 & sj=$!; PIDS="$PIDS $sj"
echo "$sj $(date +%s) custom 999999" > "$OSRC_HOME/watchsvc/sessJ/inflight"; S '_ws_settle sessJ "$OSRC_HOME/watchsvc/sessJ"'
[ ! -f "$OSRC_HOME/watchsvc/sessJ/inflight" ] && kill -0 "$sj" && ok "a reused pid (not a watcher fork) is no pending delivery, and is never signalled" || no "stranger pid held the delivery: $(cat "$OSRC_HOME/watchsvc/sessJ/inflight" 2>/dev/null)"
kill "$sj" 2>/dev/null
kill "$st" 2>/dev/null
fresh 20; mkdir -p "$OSRC_HOME/watchsvc/limits"; echo fallback > "$OSRC_HOME/watchsvc/installed"; own sess1 K; S "_sv_state_read K; SVS_LK='limit:1'; _sv_state_write K"
echo "3 $(( $(date +%s) + 900 ))" > "$OSRC_HOME/watchsvc/limits/K.try"; log limit K "plan limit hit: x (epoch $(( $(date +%s) - 5 )))"
S "SCRIPT_PATH='$TMP/bin/fake-osrc'; _ws_limits"; grep -q '^K ' "$TMP/sent4" && ok "a new limit banner does not inherit the old banner's backoff" || no "new banner waited out a stale backoff"

echo "=== install / uninstall: explicit, idempotent, reversible ==="
fresh 7; printf '#!/bin/sh\necho "systemctl $*" >> %s/sysd.log\n' "$TMP" > "$TMP/bin/systemctl"; chmod +x "$TMP/bin/systemctl"
inst() { PATH="$TMP/bin:$PATH" OSRC_WATCH_SYSTEMD_DIR="$TMP/units" OSRC_WATCH_BACKEND=systemd OSRC_WATCH_INTERVAL=7 "$SRC" watcher "$@" 2>&1; }
inst install >/dev/null; c1="$(cat "$TMP/units/outsourcerer-watcher.service" 2>/dev/null)"; inst install >/dev/null
[ -n "$c1" ] && [ "$c1" = "$(cat "$TMP/units/outsourcerer-watcher.service")" ] && [ "$(ls "$TMP/units" | wc -l | tr -d ' ')" = 1 ] && ok "install twice: one identical unit" || no "unit not idempotent"
grep -q 'Restart=always' <<<"$c1" && grep -q "OSRC_HOME=$OSRC_HOME" <<<"$c1" && grep -q 'enable outsourcerer-watcher' "$TMP/sysd.log" && ok "systemd unit restarts and is enabled" || no "unit: $c1"
grep -q "OSRC_WATCH_INTERVAL=7" "$OSRC_HOME/watchsvc/env" && grep -q '^export PATH=' "$OSRC_HOME/watchsvc/env" && ok "install captures PATH and the watcher knobs for the service" || no "env not captured"
grep -q "^ExecStart=\"$BASH\" \"$OSRC_HOME/watchsvc/launch\"\$" <<<"$c1" && ! grep -qF "$SRC" <<<"$c1" && grep -qxF "# script: $SRC" "$OSRC_HOME/watchsvc/launch" \
  && ok "the unit runs a launcher under \$BASH, never the versioned plugin path" || no "unit: $c1 / launch: $(cat "$OSRC_HOME/watchsvc/launch" 2>/dev/null)"
S "SCRIPT_PATH='$TMP/plugin-v2/outsourcerer.sh'; _ws_refresh"
grep -q "plugin-v2/outsourcerer.sh' watcher run\|plugin-v2/outsourcerer.sh watcher run" "$OSRC_HOME/watchsvc/launch" && [ ! -d "$OSRC_HOME/watchsvc/run.lock" ] \
  && ok "a call from a new plugin copy repoints the launcher (and starts nothing under systemd)" || no "launcher not refreshed: $(cat "$OSRC_HOME/watchsvc/launch")"
inst uninstall >/dev/null
[ ! -e "$TMP/units/outsourcerer-watcher.service" ] && [ ! -d "$OSRC_HOME/watchsvc" ] && grep -q 'disable --now' "$TMP/sysd.log" && ok "uninstall removes the unit and all watcher state in one command" || no "uninstall incomplete"
fresh 8; OSRC_WATCH_BACKEND=fallback OSRC_WATCH_INTERVAL=1 "$SRC" watcher install >/dev/null 2>&1; sleep 1.5
p="$(cat "$OSRC_HOME/watchsvc/run.lock/pid" 2>/dev/null)"; [ -n "$p" ] && PIDS="$PIDS $p"
[ "$(cat "$OSRC_HOME/watchsvc/installed" 2>/dev/null)" = fallback ] && [ -n "$p" ] && kill -0 "$p" && ok "fallback backend: a detached loop runs" || no "fallback not running"
"$SRC" watcher status >/dev/null 2>&1 && ok "status rc 0 while covered" || no "status rc"
"$SRC" watcher uninstall >/dev/null 2>&1; sleep 0.5
! kill -0 "$p" 2>/dev/null && [ ! -d "$OSRC_HOME/watchsvc" ] && ok "uninstall stops the fallback loop" || no "fallback loop survived uninstall"
"$SRC" watcher status >/dev/null 2>&1; [ "$?" = 3 ] && ok "status rc 3 when nothing watches" || no "status rc when down"
fresh 9; printf '#!/bin/sh\necho "systemctl $*" >> %s/sysd9.log\ncase "$*" in *restart*) exit 1 ;; esac\n' "$TMP" > "$TMP/bin/systemctl"
OSRC_WATCH_INTERVAL=1 "$SRC" watcher run >/dev/null 2>&1 & d=$!; PIDS="$PIDS $d"; sleep 1
out="$(OSRC_WATCH_INTERVAL=1 inst install)"; sleep 1.5; p="$(cat "$OSRC_HOME/watchsvc/run.lock/pid" 2>/dev/null)"; [ -n "$p" ] && PIDS="$PIDS $p"
! kill -0 "$d" 2>/dev/null && ok "install stops a loop that was already running" || no "old loop survived install"
[ ! -e "$TMP/units/outsourcerer-watcher.service" ] && grep -q 'disable --now' "$TMP/sysd9.log" && [ "$(cat "$OSRC_HOME/watchsvc/installed")" = fallback ] && [ -n "$p" ] && kill -0 "$p" \
  && ok "a failed systemd start removes the unit and falls back to the loop" || no "failed install left: $(ls "$TMP/units" 2>/dev/null) installed=$(cat "$OSRC_HOME/watchsvc/installed" 2>/dev/null) [$out]"
"$SRC" watcher uninstall >/dev/null 2>&1; sleep 0.5; ! kill -0 "$p" 2>/dev/null && ok "and one uninstall removes it" || no "fallback after failed install survived"
fresh 10; mkdir -p "$TMP/units"; echo stale > "$TMP/units/outsourcerer-watcher.service"
inst uninstall >/dev/null; [ ! -e "$TMP/units/outsourcerer-watcher.service" ] && ok "uninstall removes a unit even with no install record" || no "orphan unit kept"

echo "=== tmux wake, end to end (fake pane) ==="
fresh 11; U=11111111-2222-4333-8444-555555555555; mkdir -p "$TMP/proj" "$TMP/pane" "$OSRC_CLAUDE_SESSIONS_DIR" "$OSRC_HOME/watchsvc/$U"; own "$U" .keep
sleep 300 & cc=$!; PIDS="$PIDS $cc"
printf '{"pid":%s,"cwd":"%s","sessionId":"%s","startedAt":%s000}\n' "$cc" "$TMP/proj" "$U" "$(date +%s)" > "$OSRC_CLAUDE_SESSIONS_DIR/a.json"
printf '#!/bin/bash\nD=%s; c="$1"; shift\ncase "$c" in\n display-message) echo %s ;;\n capture-pane) cat "$D/screen" ;;\n send-keys) echo "$*" >> "$D/keys.log"; case " $* " in *" Enter "*) [ -f "$D/next" ] && mv -f "$D/next" "$D/screen" ;; esac ;;\nesac\n' "$TMP/pane" "$$" > "$TMP/bin/tmux"; chmod +x "$TMP/bin/tmux"
cp "$SCRIPT_DIR/fixtures/screen/cc-composer-idle.ansi" "$TMP/pane/screen"; cp "$SCRIPT_DIR/fixtures/screen/cc-working-hooks.ansi" "$TMP/pane/next"
echo '%7' > "$OSRC_HOME/watchsvc/$U/pane"; echo "$TMP/proj" > "$OSRC_HOME/watchsvc/$U/cwd"; S '_ws_sock' > "$OSRC_HOME/watchsvc/$U/sock"
export PATH="$TMP/bin:$PATH"; S '_ws_tick'; log idle L7 'finished its turn' "$U"
S '_ws_tick'; [ -f "$OSRC_HOME/watchsvc/$U/try" ] && [ ! -s "$TMP/pane/keys.log" ] && ok "a watcher nobody installed never types into the pane" || no "uninstalled watcher typed"
rm -f "$OSRC_HOME/watchsvc/$U/try"; echo fallback > "$OSRC_HOME/watchsvc/installed"
OSRC_SEND_VERIFY_SECS=3 tick_until "[ -f '$OSRC_HOME/watchsvc/$U/sent' ]"
grep -q -- '-l -- \[outsourcerer\] watcher: 1 event(s)' "$TMP/pane/keys.log" && grep -q ' Enter' "$TMP/pane/keys.log" && [ ! -f "$OSRC_HOME/watchsvc/$U/try" ] \
  && ok "tmux: the wake is typed into the session's empty composer and verified on screen" || no "tmux wake [$(cat "$TMP/pane/keys.log" 2>/dev/null)] try=$(cat "$OSRC_HOME/watchsvc/$U/try" 2>/dev/null)"

echo "=== the guard judges a tmux channel on the watcher's tmux server ==="
sleep 300 >/dev/null 2>&1 & w=$!; PIDS="$PIDS $w"
mkdir -p "$OSRC_HOME/jobs/R4"; echo running > "$OSRC_HOME/jobs/R4/status"; echo "$w" > "$OSRC_HOME/jobs/R4/pid"; echo "$w" > "$OSRC_HOME/jobs/R4/supervisor_pid"; own "$U" R4
bash -c 'sleep 300; : watcher run' & wp=$!; PIDS="$PIDS $wp"; mkdir -p "$OSRC_HOME/watchsvc/run.lock"; echo "$wp" > "$OSRC_HOME/watchsvc/run.lock/pid"; date +%s > "$OSRC_HOME/watchsvc/alive"; sleep 0.3
g11() { rm -f "$OSRC_HOME/owners/$U/.stop-blocks"; printf '{"session_id":"%s","cwd":"%s"}' "$U" "$TMP/proj" | TMUX="$1,1,0" TMUX_PANE=%7 "$SRC" stop-guard 2>/dev/null; }
out="$(g11 "$(S 'unset TMUX_TMPDIR; _ws_sock')")"; [ -z "$out" ] && ok "a session on the watcher's (default) tmux server is covered" || no "default server blocked [$out]"
out="$(g11 "$TMP/work-sock")"; grep -q '"decision":"block"' <<<"$out" && ok "a session on another tmux server (tmux -L/-S) is not covered: the daemon cannot reach it" || no "trusted a pane the daemon cannot reach [$out]"
printf 'export PATH=%q\nexport TMUX=%q\n' "$PATH" "$TMP/work-sock" > "$OSRC_HOME/watchsvc/env"
out="$(g11 "$TMP/work-sock")"; [ -z "$out" ] && ok "a watcher installed from that tmux server covers it" || no "captured server not matched [$out]"
inst2="$(cd "$TMP" && TMUX="$TMP/work-sock,9,0" TMUX_TMPDIR="$TMP" OSRC_WATCH_BACKEND=fallback OSRC_WATCH_INTERVAL=1 OSRC_HOME="$TMP/h11b" "$SRC" watcher install 2>&1)"
grep -qx "export TMUX=$TMP/work-sock" "$TMP/h11b/watchsvc/env" && grep -qx "export TMUX_TMPDIR=$TMP" "$TMP/h11b/watchsvc/env" && ok "install captures the tmux server (socket and TMUX_TMPDIR) for the daemon" || no "tmux server not captured [$inst2]"
OSRC_HOME="$TMP/h11b" "$SRC" watcher uninstall >/dev/null 2>&1

echo
echo "watchsvc: $pass passed, $fail failed"
[ "$fail" = 0 ]
