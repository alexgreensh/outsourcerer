#!/usr/bin/env bash
# sealed-run-requires: process-inspection
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_watchsvc.sh — the per-user watcher (lib/watchsvc.sh) and the waiter gaps it closes:
#   incident 1/2: a supervise hung in its hub/limits refresh kept its pid and armed file, so it
#     "covered" the session while it logged and delivered nothing (7 h; a done row 37 min late).
#   incident 3: the session's waiter died and finished lanes waited hours: the watcher wakes the
#     owner itself, verified, retried, loudly when it fails, once per row.
#   incident 4: lanes parked on a provider limit get one `continue` after the reset, once.
#   the stop guard: a watcher that can wake the session is a waiter; a yield starts one.
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
  local i=0; while [ "$i" -lt 30 ]; do S '_ws_tick'; eval "$1" && return 0; sleep 0.2; i=$((i+1)); done; return 1; }
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
out="$(printf '{"session_id":"sess1"}' | OSRC_WATCH_FALLBACK=0 "$SRC" stop-guard 2>/dev/null)"
grep -q '"decision":"block"' <<<"$out" && ok "stop guard blocks: the hung supervise does not satisfy it" || no "guard allowed the stop under a hung supervise [$out]"

echo "=== incident 2: a hung refresh cannot hold a logged done row back ==="
fresh 2; mkdir -p "$OSRC_HOME/supervise/sess2"; log done L9 'job finished (done)' sess2
out="$(OSRC_SUPERVISE_TICK_SECS=1 OSRC_SUPERVISE_TICK_TIMEOUT=2 OSRC_SUPERVISE_POLL=1 OSRC_SUPERVISE_SETTLE=0 perl -e 'alarm 20; exec @ARGV' \
  bash -c 'export OSRC_SOURCED=1; . "$0" >/dev/null 2>&1; cmd_hub_export() { sleep 120; }; cmd_supervise --session sess2' "$SRC" 2>/dev/null)"
grep -q '^EVENT done L9 ' <<<"$out" && ok "supervise delivers the done row although the hub refresh hangs" || no "done row held back by a hung refresh [$out]"

echo "=== incident 3: the watcher wakes the owner when no waiter is armed ==="
fresh 3; own sess1 J1; donejob J1
export OSRC_WATCH_DELIVER_CMD="cat >> '$TMP/got3'; printf '%s\n' \"\$1\" >> '$TMP/sum3'"
S '_ws_tick'   # first sight: baseline (no supervise cursor) then the observe pass logs the done row
grep -q '"kind":"done","target":"J1"' "$OSRC_HOME/lanes/events.jsonl" && ok "watcher observed the finished lane and logged it with its owner" || no "no done row logged"
tick_until '[ -s "$TMP/got3" ] && [ ! -f "$OSRC_HOME/watchsvc/sess1/inflight" ]' \
  && grep -q '^EVENT done J1 ' "$TMP/got3" && grep -q '^NEXT .* result J1' "$TMP/got3" \
  && ok "owner woken with the EVENT/NEXT lines (delivery verified by the channel's exit code)" || no "no wake delivered [$(cat "$TMP/got3" 2>/dev/null)]"
grep -q 'nothing to re-arm' "$TMP/sum3" && ok "wake text says no re-arm is needed" || no "wake text [$(cat "$TMP/sum3")]"
grep -qF "$(grep -o '"id":"[^"]*"' "$OSRC_HOME/lanes/events.jsonl" | head -1 | cut -d'"' -f4)" "$OSRC_HOME/supervise/sess1/delivered" \
  && ok "delivered rows are in supervise's ledger (a later supervise will not repeat them)" || no "ledger not updated"
[ ! -e "$OSRC_HOME/owners/sess1/J1" ] && ok "the reported finished lane leaves the owner registry (no reminder storm)" || no "owner marker kept"
for i in 1 2 3; do S '_ws_tick'; done
[ "$(grep -c '^EVENT' "$TMP/got3")" = 1 ] && ok "one wake per row: later ticks deliver nothing again" || no "redelivered: $(grep -c '^EVENT' "$TMP/got3")"

fresh 3b; mkdir -p "$OSRC_HOME/owners/sess1"; S '_ws_tick'; rm -f "$TMP/got3"
log idle L2 'finished its turn'; rid="$(tail -1 "$OSRC_HOME/lanes/events.jsonl" | jq -r .id)"
mkdir -p "$OSRC_HOME/supervise/sess1"; printf '%s\t%s\n' "$(date +%s)" "$rid" > "$OSRC_HOME/supervise/sess1/delivered"
S '_ws_tick'; sleep 1; S '_ws_tick'; [ ! -s "$TMP/got3" ] && ok "a row a supervise already printed is not woken again" || no "duplicated a supervise delivery"
fresh 3c; mkdir -p "$OSRC_HOME/owners/sess1"; S '_ws_tick'; rm -f "$TMP/got3"; fake_supervise sess1 2; log idle L2 'finished its turn'
S '_ws_tick'; sleep 1; S '_ws_tick'; [ ! -s "$TMP/got3" ] && [ -s "$OSRC_HOME/watchsvc/sess1/pending" ] && ok "a live, polling supervise delivers instead; the row stays pending" || no "watcher raced a live supervise"

echo "=== incident 3: failed delivery retries with backoff and becomes loud ==="
fresh 3d; mkdir -p "$OSRC_HOME/owners/sess1"; S '_ws_tick'
export OSRC_WATCH_DELIVER_CMD="echo try >> '$TMP/tries'; exit 1"; log question L3 'stopped and asked'
tick_until '[ -f "$OSRC_HOME/watchsvc/sess1/try" ]'; t0="$(date +%s)"
[ "$(wc -l < "$TMP/tries")" = 1 ] && ok "failed delivery recorded (attempt 1)" || no "tries: $(cat "$TMP/tries")"
S '_ws_tick'; [ "$(wc -l < "$TMP/tries")" = 1 ] && ok "no retry inside the backoff window" || no "retried at once"
att() { [ "$(cut -d' ' -f1 "$OSRC_HOME/watchsvc/sess1/try" 2>/dev/null)" = "$1" ] && [ ! -f "$OSRC_HOME/watchsvc/sess1/inflight" ]; }
OSRC_NOW=$((t0 + 61)) tick_until 'att 2'; OSRC_NOW=$((t0 + 400)) tick_until 'att 3' 
[ "$(wc -l < "$TMP/tries")" -ge 3 ] && [ -s "$OSRC_HOME/owners/sess1/.wakefail" ] && ok "after 3 failed attempts .wakefail is written" || no "tries=$(wc -l < "$TMP/tries") wakefail=$(cat "$OSRC_HOME/owners/sess1/.wakefail" 2>/dev/null)"
grep -q 'WAKE NOT DELIVERED' <<<"$(CLAUDE_CODE_SESSION_ID=sess1 S '_sg_print_unguarded' 2>&1)" && ok "every outsourcerer call prints the delivery failure" || no "failure not printed"
grep -q 'sess1: 1 event(s) pending, channel=custom, DELIVERY FAILING' <<<"$("$SRC" watcher status 2>/dev/null)" && ok "watcher status shows the failing delivery" || no "status: $("$SRC" watcher status 2>&1)"
export OSRC_WATCH_DELIVER_CMD="cat > '$TMP/got3d'"
OSRC_NOW=$((t0 + 4000)) tick_until "[ -s '$TMP/got3d' ] && [ ! -f '$OSRC_HOME/watchsvc/sess1/inflight' ]"
[ ! -e "$OSRC_HOME/owners/sess1/.wakefail" ] && grep -q '^EVENT question L3' "$TMP/got3d" && ok "a later success delivers and clears the failure" || no "recovery failed"
unset OSRC_WATCH_DELIVER_CMD
fresh 3e; mkdir -p "$OSRC_HOME/owners/sess1"; S '_ws_tick'; log idle L4 'finished its turn'; S '_ws_tick'
[ -f "$OSRC_HOME/watchsvc/sess1/try" ] && [ ! -f "$OSRC_HOME/watchsvc/sess1/inflight" ] && ok "no channel (not in tmux, no command, session open): counted as a failed wake, not dropped" || no "no-channel case"

echo "=== reminders do not re-wake within OSRC_WATCH_REWAKE ==="
fresh 3f; mkdir -p "$OSRC_HOME/owners/sess1"; S '_ws_tick'; export OSRC_WATCH_DELIVER_CMD="cat >> '$TMP/got3f'"
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
mkdir -p "$OSRC_HOME/watchsvc/limits"; echo 0 > "$OSRC_HOME/watchsvc/limits/.cursor"
lim
grep -qx 'A session send continue' "$TMP/sent4" && ok "reset passed + still limit-parked -> one continue" || no "no continue for A [$(cat "$TMP/sent4" 2>/dev/null)]"
! grep -q '^B ' "$TMP/sent4" && ok "reset not yet passed -> waits" || no "B continued early"
! grep -q '^C ' "$TMP/sent4" && ok "a lane no longer on the limit is never continued" || no "C continued"
grep -q '"kind":"limit-resumed","target":"A"' "$OSRC_HOME/lanes/events.jsonl" && ok "the continue is logged (informational row)" || no "no limit-resumed row"
lim; lim; [ "$(grep -c '^A ' "$TMP/sent4")" = 1 ] && ok "once per reset: no resend while the banner stays" || no "A resent"
lim "OSRC_NOW=$((now + 3700))"; [ "$(grep -c '^B ' "$TMP/sent4")" = 1 ] && ok "after its reset B gets its one continue" || no "B never continued"
log limit A "plan limit hit: again (epoch $((now + 7000)))"; lim "OSRC_NOW=$((now + 7100))"
[ "$(grep -c '^A ' "$TMP/sent4")" = 2 ] && ok "a NEW limit later gets its own continue" || no "second limit ignored"
rm -f "$OSRC_HOME/owners/sess1/A"; log limit A "plan limit hit: x (epoch $((now + 8000)))"; lim "OSRC_NOW=$((now + 8100))"
[ "$(grep -c '^A ' "$TMP/sent4")" = 2 ] && ok "a lane nobody owns any more is left alone" || no "continued an unowned lane"

echo "=== stop guard: watcher that can wake the session is a waiter; a yield starts one ==="
fresh 5; sleep 300 >/dev/null 2>&1 & w=$!; PIDS="$PIDS $w"
mkdir -p "$OSRC_HOME/jobs/R1"; echo running > "$OSRC_HOME/jobs/R1/status"; echo "$w" > "$OSRC_HOME/jobs/R1/pid"; echo "$w" > "$OSRC_HOME/jobs/R1/supervisor_pid"; own sess5 R1
guard() { printf '{"session_id":"sess5","cwd":"%s"}' "$TMP" | "$SRC" stop-guard 2>"$TMP/err5"; }
mkdir -p "$OSRC_HOME/watchsvc"; date +%s > "$OSRC_HOME/watchsvc/alive"
out="$(OSRC_WATCH_FALLBACK=0 guard)"; grep -q '"decision":"block"' <<<"$out" && ok "watcher alive but no channel to this session: still blocks" || no "allowed with no channel [$out]"
out="$(OSRC_WATCH_DELIVER_CMD=true guard)"; [ -z "$out" ] && ok "watcher alive and able to wake the session: the stop is allowed" || no "blocked [$out]"
[ "$(cat "$OSRC_HOME/watchsvc/sess5/cwd" 2>/dev/null)" = "$TMP" ] && ok "the hook records the session's cwd for the channels" || no "cwd not recorded"
rm -f "$OSRC_HOME/watchsvc/alive"
OSRC_WATCH_FALLBACK=0 guard >/dev/null; out="$(OSRC_WATCH_FALLBACK=0 guard)"; out="$(OSRC_WATCH_FALLBACK=0 guard)"
[ -z "$out" ] && grep -q 'NO watcher is running' "$OSRC_HOME/owners/sess5/.unguarded" && ok "loop safety kept: yields after the max, and says no watcher runs" || no "yield [$out] $(cat "$OSRC_HOME/owners/sess5/.unguarded" 2>/dev/null)"
rm -f "$OSRC_HOME/owners/sess5/.stop-blocks"; guard >/dev/null; guard >/dev/null
out="$(OSRC_HEARTBEAT_DISABLED=0 OSRC_WATCH_INTERVAL=1 guard)"; sleep 2
p="$(cat "$OSRC_HOME/watchsvc/run.lock/pid" 2>/dev/null)"; [ -n "$p" ] && PIDS="$PIDS $p"
[ -z "$out" ] && [ -n "$p" ] && kill -0 "$p" 2>/dev/null && grep -q 'a watcher loop observes them' "$OSRC_HOME/owners/sess5/.unguarded" \
  && ok "the yield starts a watcher loop instead of leaving the work unwatched" || no "no watcher started on yield [p=$p] $(cat "$OSRC_HOME/owners/sess5/.unguarded" 2>/dev/null)"
printf '{"session_id":"sess5"}' | OSRC_HOME="$TMP/broken-home-$$" "$SRC" stop-guard >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "guard on a missing home exits 0 (never traps the user)" || no "guard rc $rc"

echo "=== watcher run: single instance, stamps, transient exits when idle ==="
fresh 6; OSRC_WATCH_INTERVAL=1 OSRC_WATCH_IDLE_EXIT=4 "$SRC" watcher run --transient >/dev/null 2>&1 & d=$!; PIDS="$PIDS $d"; sleep 1.5
[ -f "$OSRC_HOME/watchsvc/alive" ] && ok "daemon ticks and stamps" || no "no stamp"
grep -q 'already running' <<<"$("$SRC" watcher run 2>&1)" && ok "a second run exits (single instance)" || no "second instance ran"
i=0; while kill -0 "$d" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i+1)); done
! kill -0 "$d" 2>/dev/null && [ ! -d "$OSRC_HOME/watchsvc/run.lock" ] && ok "transient loop exits with nothing owned and releases its lock" || no "transient loop lingered"

echo "=== install / uninstall: explicit, idempotent, reversible ==="
fresh 7; printf '#!/bin/sh\necho "systemctl $*" >> %s/sysd.log\n' "$TMP" > "$TMP/bin/systemctl"; chmod +x "$TMP/bin/systemctl"
inst() { PATH="$TMP/bin:$PATH" OSRC_WATCH_SYSTEMD_DIR="$TMP/units" OSRC_WATCH_BACKEND=systemd OSRC_WATCH_INTERVAL=7 "$SRC" watcher "$@" 2>&1; }
inst install >/dev/null; c1="$(cat "$TMP/units/outsourcerer-watcher.service" 2>/dev/null)"; inst install >/dev/null
[ -n "$c1" ] && [ "$c1" = "$(cat "$TMP/units/outsourcerer-watcher.service")" ] && [ "$(ls "$TMP/units" | wc -l | tr -d ' ')" = 1 ] && ok "install twice: one identical unit" || no "unit not idempotent"
grep -q 'Restart=always' <<<"$c1" && grep -q "OSRC_HOME=$OSRC_HOME" <<<"$c1" && grep -q 'enable outsourcerer-watcher' "$TMP/sysd.log" && ok "systemd unit restarts and is enabled" || no "unit: $c1"
grep -q "OSRC_WATCH_INTERVAL=7" "$OSRC_HOME/watchsvc/env" && grep -q '^export PATH=' "$OSRC_HOME/watchsvc/env" && ok "install captures PATH and the watcher knobs for the service" || no "env not captured"
inst uninstall >/dev/null
[ ! -e "$TMP/units/outsourcerer-watcher.service" ] && [ ! -d "$OSRC_HOME/watchsvc" ] && grep -q 'disable --now' "$TMP/sysd.log" && ok "uninstall removes the unit and all watcher state in one command" || no "uninstall incomplete"
fresh 8; OSRC_WATCH_BACKEND=fallback OSRC_WATCH_INTERVAL=1 "$SRC" watcher install >/dev/null 2>&1; sleep 1.5
p="$(cat "$OSRC_HOME/watchsvc/run.lock/pid" 2>/dev/null)"; [ -n "$p" ] && PIDS="$PIDS $p"
[ "$(cat "$OSRC_HOME/watchsvc/installed" 2>/dev/null)" = fallback ] && [ -n "$p" ] && kill -0 "$p" && ok "fallback backend: a detached loop runs" || no "fallback not running"
"$SRC" watcher status >/dev/null 2>&1 && ok "status rc 0 while covered" || no "status rc"
"$SRC" watcher uninstall >/dev/null 2>&1; sleep 0.5
! kill -0 "$p" 2>/dev/null && [ ! -d "$OSRC_HOME/watchsvc" ] && ok "uninstall stops the fallback loop" || no "fallback loop survived uninstall"
"$SRC" watcher status >/dev/null 2>&1; [ "$?" = 3 ] && ok "status rc 3 when nothing watches" || no "status rc when down"

echo
echo "watchsvc: $pass passed, $fail failed"
[ "$fail" = 0 ]
