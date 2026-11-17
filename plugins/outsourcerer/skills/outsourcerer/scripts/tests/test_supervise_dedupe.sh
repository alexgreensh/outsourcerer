#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_supervise_dedupe.sh — an event already delivered is never delivered again (lib/supervise_dedupe.sh),
# and an idle lane that handed in a watched <lane>.DONE reports done, not idle (lib/lane_life.sh).
# 2026-11-17 live log: two supervise processes armed for one orchestrator both logged and delivered
# `EVENT idle osrc-auto-S2 1794879921 finished its turn, composer empty (no done marker)`.
# Panes are real Claude Code 2.1 captures (fixtures/supervise) served by the file-backed fake tmux.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"; FX="$SCRIPT_DIR/fixtures/supervise"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-supervise-dedupe.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/panes" "$TMP/home"; ln -s "$SCRIPT_DIR/fake-bin/tmux-files" "$TMP/bin/tmux"
export HOME="$TMP/home" PATH="$TMP/bin:$PATH" FAKE_TMUX_DIR="$TMP/panes" OSRC_HEARTBEAT_DISABLED=1 OSRC_BLIND_TURN_GUARD=0 OSRC_STREAM=1
export OSRC_CLAUDE_PROJECTS_DIR="$TMP/projects" OSRC_CLAUDE_SESSIONS_DIR="$TMP/ccsessions"
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID
export OSRC_SUPERVISE_POLL=1 OSRC_SUPERVISE_CONFIRM=0 OSRC_SUPERVISE_SETTLE=0 OSRC_SUPERVISE_TICK_SECS=86400
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
# The hub refresh tick is test_supervise_tick.py's: stamp it fresh so it is skipped.
fresh() { export OSRC_HOME="$TMP/h$1"; mkdir -p "$OSRC_HOME/jobs" "$OSRC_HOME/sessions" "$OSRC_HOME/supervise/S"
  date +%s > "$OSRC_HOME/supervise/S/tick.time"; rm -f "$TMP/panes"/*.screen; }
own() { mkdir -p "$OSRC_HOME/owners/$1"; : > "$OSRC_HOME/owners/$1/$2"; }
pane() { cp "$FX/$2" "$TMP/panes/$1.screen"; }
sup() { perl -e 'alarm shift; exec @ARGV' "${T:-60}" "$SRC" supervise "$@" 2>"$TMP/err"; }
reg() { # <session> <iso-ts>
  jq -cn --arg id "$1" --arg ts "$2" '{event:"start",session_id:$id,provider:"cc",ts:$ts}' >> "$OSRC_HOME/sessions/registry.jsonl"; }
rows() { grep -c "\"target\":\"$1\"" "$OSRC_HOME/lanes/events.jsonl" 2>/dev/null || echo 0; }
lib() { ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; "$@" ); }

echo "=== a delivered row is never delivered again, whatever cursor the next supervise holds ==="
fresh 1; own S i1; pane i1 cc-idle-after-work.txt
out="$(sup --session S)"; grep -q '^EVENT idle i1 ' <<<"$out" && ok "first supervise delivers the idle" || no "no idle: [$out]"
ts="$(sed -n 's/^EVENT idle i1 \([0-9]*\) .*/\1/p' <<<"$out")"
# A second supervise armed before the first one printed still holds the old cursor in memory: replay it.
printf '0 0\n' > "$OSRC_HOME/supervise/S/cursor"
out="$(OSRC_SUPERVISE_MAX_SECS=3 sup --session S)"
grep -q "^EVENT idle i1 $ts " <<<"$out" && no "same idle row delivered twice: [$out]" || ok "a stale cursor does not re-deliver the idle row (ts $ts)"
grep -q '^EVENT stalled supervise ' <<<"$out" && ok "the re-armed supervise keeps blocking on the live idle lane" || no "re-arm: [$out]"
[ "$(rows i1)" = 1 ] && ok "one idle row in the log" || no "rows: $(rows i1)"
rid="$(jq -r 'select(.target=="i1") | .id' "$OSRC_HOME/lanes/events.jsonl" | head -1)"
[ -n "$rid" ] && grep -q "	$rid\$" "$OSRC_HOME/supervise/S/delivered" && ok "the ledger records the delivered row by its own id ($rid)" || no "ledger: $(cat "$OSRC_HOME/supervise/S/delivered" 2>/dev/null)"
# A new idle (the lane worked again, then stopped) is a new row and is delivered.
cp "$FX/cc-working-turn.txt" "$TMP/panes/i1.screen"; lib _sv_observe_all beacon
cp "$FX/cc-idle-after-work.txt" "$TMP/panes/i1.screen"
out="$(sup --session S)"; grep -q '^EVENT idle i1 ' <<<"$out" && ok "a later, new idle is still delivered" || no "new idle swallowed: [$out]"
# Ledger rows older than 24 h are pruned.
printf '1\told-row\n' >> "$OSRC_HOME/supervise/S/delivered"
lib _sv_ledger_add "$OSRC_HOME/supervise/S/delivered" "$(printf '6\t%s\tidle\tz\td\tn\tnew-row' "$(date +%s)")"
grep -q 'old-row' "$OSRC_HOME/supervise/S/delivered" && no "24h-old ledger row kept" || ok "ledger prunes rows older than 24 h"
grep -q '	new-row$' "$OSRC_HOME/supervise/S/delivered" && ok "ledger keys on the row id column" || no "ledger add: $(cat "$OSRC_HOME/supervise/S/delivered")"
# Two rows identical in ts/kind/target/detail are still two rows (review nit: key on a per-row id).
lid="$OSRC_HOME/supervise/S/delivered"; t="$(date +%s)"
got="$(lib _sv_ledger_filter "$lid" "$(printf '6\t%s\tidle\tq\tsame\tn\tid-a\n6\t%s\tidle\tq\tsame\tn\tid-b' "$t" "$t")")"
lib _sv_ledger_add "$lid" "$(printf '6\t%s\tidle\tq\tsame\tn\tid-a' "$t")"
got2="$(lib _sv_ledger_filter "$lid" "$(printf '6\t%s\tidle\tq\tsame\tn\tid-a\n6\t%s\tidle\tq\tsame\tn\tid-b' "$t" "$t")")"
[ "$(printf '%s\n' "$got" | grep -c .)" = 2 ] && [ "$(printf '%s\n' "$got2" | awk -F '\t' '{print $7}')" = id-b ] \
  && ok "two look-alike rows with different ids: delivering one does not hide the other" || no "look-alike rows: [$got] [$got2]"

echo "=== per-target lock: two observers never log the same change twice ==="
fresh 2; own S i2; pane i2 cc-idle-after-work.txt
mkdir -p "$OSRC_HOME/lanes/state"; mkdir "$OSRC_HOME/lanes/state/i2.lock"   # another process is on i2
got="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _sv_observe_emit i2 "$(date +%s)" supervise S; printf '%s %s %s' "${SV_K:-none}" "$SV_OUT" "$SV_PEND" ) )"
[ "$got" = "none 1 1" ] && [ "$(rows i2)" = 0 ] && ok "a held lock: no row, target stays pending and owed a waiter" || no "held lock: [$got] rows=$(rows i2)"
touch -t "$(date -r $(( $(date +%s) - 600 )) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$(( $(date +%s) - 600 )) +%Y%m%d%H%M.%S)" "$OSRC_HOME/lanes/state/i2.lock"
# a quiet state needs two reads to confirm (OSRC_SUPERVISE_CONFIRM=0: back to back)
lib _sv_observe_emit i2 "$(date +%s)" supervise S; lib _sv_observe_emit i2 "$(date +%s)" supervise S
[ "$(rows i2)" = 1 ] && [ ! -d "$OSRC_HOME/lanes/state/i2.lock" ] && ok "a lock left by a killed run (10 min old) is broken and released" || no "stale lock: rows=$(rows i2)"
lib _sv_observe_emit i2 "$(date +%s)" supervise S; lib _sv_observe_emit i2 "$(date +%s)" beacon S
[ "$(rows i2)" = 1 ] && ok "repeat observers of an unchanged idle add no row" || no "repeat rows=$(rows i2)"
# Locks a run holds are released by its EXIT trap (TERM/INT/HUP exit through it).
got="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _SV_HELD=""; _sv_target_lock zz && _sv_lock_try "$OSRC_HOME/supervise/S/delivered.lock" 30
          trap '_sv_main_exit' EXIT; trap 'exit 10' TERM INT HUP; kill -TERM "$(exec sh -c 'echo $PPID')"; sleep 5 ) 2>/dev/null; ls -d "$OSRC_HOME/lanes/state/zz.lock" "$OSRC_HOME/supervise/S/delivered.lock" 2>/dev/null)"
[ -z "$got" ] && ok "TERM releases the target lock and the ledger lock this run held" || no "locks left after TERM: $got"

echo "=== M3: two supervises armed for one session: only the newest delivers ==="
fresh 3; own S i3; pane i3 cc-working-turn.txt
armed_n() { ls "$OSRC_HOME/supervise/S"/armseq.[0-9]* 2>/dev/null | grep -c .; }
waitfor() { local i=0; while [ "$i" -lt 600 ] && ! eval "$1"; do sleep 0.1; i=$((i+1)); done; eval "$1"; }
( sup --session S > "$TMP/a.out" ) & pa=$!
waitfor '[ "$(armed_n)" -ge 1 ]' || no "first supervise never armed"
( sup --session S > "$TMP/b.out" ) & pb=$!
waitfor '[ "$(armed_n)" -ge 2 ]' || no "second supervise never armed"
cp "$FX/cc-idle-after-work.txt" "$TMP/panes/i3.screen"   # the event arrives after both are armed
wait "$pa" "$pb"
grep -q '^EVENT idle i3 ' "$TMP/b.out" && ok "the newest supervise delivers the idle" || no "newest did not deliver: a=[$(cat "$TMP/a.out")] b=[$(cat "$TMP/b.out")]"
grep -q '^EVENT' "$TMP/a.out" && no "the older, unread supervise took an event: [$(cat "$TMP/a.out")]" || ok "the older supervise delivers nothing"
grep -q 'superseded by a newer supervise for this session' "$TMP/a.out" && ok "the older one exits with a 'superseded' line" || no "no superseded line: [$(cat "$TMP/a.out")]"
[ "$(rows i3)" = 1 ] && ok "one idle row logged between them" || no "concurrent rows=$(rows i3)"
[ -z "$(ls "$OSRC_HOME/supervise/S"/armseq.[0-9]* 2>/dev/null)" ] && ok "both removed their arm records on exit" || no "arm records left: $(ls "$OSRC_HOME/supervise/S")"

echo "=== R3-1: a newer supervise with a narrower scope never silences a session-wide one ==="
fresh 9; own S i1; own S i2; pane i1 cc-working-turn.txt; pane i2 cc-working-turn.txt
( sup --session S > "$TMP/a9.out" ) & pa=$!
waitfor '[ "$(armed_n)" -ge 1 ]' || no "session-wide supervise never armed"
( OSRC_SUPERVISE_MAX_SECS=4 sup --session S i2 > "$TMP/b9.out" ) & pb=$!
waitfor '[ "$(armed_n)" -ge 2 ]' || no "scoped supervise never armed"
cp "$FX/cc-idle-after-work.txt" "$TMP/panes/i1.screen"   # i1, outside the newer one's scope, goes idle
wait "$pa" "$pb"
# The session-wide waiter keeps observing i1; either waiter may print the row (both read the
# session's rows), the ledger makes it exactly once.
[ "$(cat "$TMP/a9.out" "$TMP/b9.out" | grep -c '^EVENT idle i1 ')" = 1 ] && ok "i1's idle is reported exactly once after 'supervise --session S i2' arms" || no "i1 lost or doubled: a=[$(cat "$TMP/a9.out")] b=[$(cat "$TMP/b9.out")]"
grep -q superseded "$TMP/a9.out" && no "session-wide waiter superseded by a narrower one" || ok "a narrower newer scope does not supersede"
cov() { ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; printf '%s\n' "$1" > "$TMP/n.arm"; printf '%s\n' "$2" > "$TMP/m.arm"; _sv_scope_covers "$TMP/n.arm" "$TMP/m.arm" && echo y || echo n ); }
[ "$(cov '*' 'i1')$(cov '*' '*')$(cov "$(printf 'i1\ni2')" i1)$(cov i2 '*')$(cov i2 i1)" = yyynn ] \
  && ok "scope covers: * > anything, a list > its subset, never a list > * or a disjoint list" || no "scope table: $(cov '*' 'i1')$(cov '*' '*')$(cov "$(printf 'i1\ni2')" i1)$(cov i2 '*')$(cov i2 i1)"

echo "=== R3-3: a supervise whose parent is killed leaves no ghost worker ==="
fresh 11; own S w11; pane w11 cc-working-turn.txt
out="$(T=3 sup --session S)"; rc=$?   # SIGALRM kills the parent; the worker must not outlive it
[ -z "$(ls "$OSRC_HOME/supervise/S"/armed.* 2>/dev/null)" ] && ok "parent killed (rc $rc): the worker exited too, no armed file left" || no "ghost worker: $(ls "$OSRC_HOME/supervise/S")"

echo "=== M2: a busy ledger lock never moves the cursor past an undelivered event ==="
fresh 7; own S q7; pane q7 cc-question-live.txt
mkdir "$OSRC_HOME/supervise/S/delivered.lock"   # left by a run killed mid-delivery, still fresh
out="$(OSRC_SUPERVISE_LEDGER_STALE=3600 OSRC_SUPERVISE_MAX_SECS=8 sup --session S)"
grep -q '^EVENT question q7 ' <<<"$out" && no "delivered while the ledger was locked: [$out]" || ok "ledger locked: nothing printed"
read -r cur _ 2>/dev/null < "$OSRC_HOME/supervise/S/cursor"
[ "$(rows q7)" = 1 ] && [ "${cur:-0}" -lt "$(wc -c < "$OSRC_HOME/lanes/events.jsonl" | tr -d ' ')" ] \
  && ok "the question is logged and the cursor did not move past it (cursor ${cur:-none})" || no "cursor moved past the undelivered question: cursor=${cur:-none} rows=$(rows q7)"
rmdir "$OSRC_HOME/supervise/S/delivered.lock"
out="$(sup --session S)"
grep -q '^EVENT question q7 ' <<<"$out" && ok "the logged question is delivered once the lock is free (cursor was not advanced)" || no "question lost: [$out]"

echo "=== an idle lane that handed in a watched <lane>.DONE is done, not idle ==="
fresh 4; own S osrc-auto-S3; pane osrc-auto-S3 cc-idle-after-work.txt
reg osrc-auto-S3 "$(date -u -r $(( $(date +%s) - 60 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$(( $(date +%s) - 60 )) +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$TMP/out4"
out="$(OSRC_SUPERVISE_MAX_SECS=3 sup --session S --watch "$TMP/out4")"
grep -q '^EVENT idle osrc-auto-S3 .*(no done marker)$' <<<"$out" && ok "before the hand-in: idle, with a watch registered" || no "pre hand-in: [$out]"
: > "$TMP/out4/S3.DONE"
# the watch's done fires at once; the lane's own done after its confirm read, inside the settle window
out="$(OSRC_SUPERVISE_SETTLE=5 sup --session S)"
grep -q '^EVENT done osrc-auto-S3 .*hand-in S3.DONE' <<<"$out" && ok "S3.DONE written -> EVENT done osrc-auto-S3 (session id ends in -S3)" || no "hand-in not done: [$out]"
grep -q '^EVENT idle osrc-auto-S3 ' <<<"$out" && no "still reported idle: [$out]" || ok "no idle event once handed in"
out="$(OSRC_SUPERVISE_MAX_SECS=3 sup --session S)"
grep -q '^EVENT done osrc-auto-S3 ' <<<"$out" && no "done re-delivered: [$out]" || ok "the done is not re-delivered on the next arm"
printf 'again\n' > "$TMP/out4/S3.DONE"
out="$(OSRC_SUPERVISE_SETTLE=5 sup --session S)"; grep -q '^EVENT done osrc-auto-S3 ' <<<"$out" && ok "a rewritten DONE (re-hand-in) is a new done" || no "re-hand-in: [$out]"
# The stop guard reads the same hand-in: the lane is settled, not owed a waiter (the watch itself
# stays live work until --unwatch, which is the orchestrator's call).
lib _sv_idle_owed osrc-auto-S3; [ "$?" = 1 ] && ok "the stop guard counts the handed-in lane as settled" || no "handed-in lane still owed a waiter"
st="$(lib _owned_live_state osrc-auto-S3)"; [ "$st" = idle ] && ok "owned state of the handed-in lane: idle (settled)" || no "owned state: $st"
# A DONE left over from before this session started never counts.
fresh 5; own S osrc-auto-S4; pane osrc-auto-S4 cc-idle-after-work.txt
mkdir -p "$TMP/out5"; : > "$TMP/out5/S4.DONE"; touch -t 202601010000 "$TMP/out5/S4.DONE"
reg osrc-auto-S4 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
out="$(sup --session S --watch "$TMP/out5")"
grep -q '^EVENT idle osrc-auto-S4 ' <<<"$out" && ok "a DONE older than the session start stays idle" || no "stale DONE: [$out]"
echo "=== M1: a reused session's previous-round DONE never outranks its live screen ==="
fresh 8; own S osrc-auto-S5; pane osrc-auto-S5 cc-idle-after-work.txt
past() { date -r $(( $(date +%s) - $1 )) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$(( $(date +%s) - $1 )) +%Y%m%d%H%M.%S; }
reg osrc-auto-S5 "$(date -u -r $(( $(date +%s) - 120 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$(( $(date +%s) - 120 )) +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$TMP/out8"; : > "$TMP/out8/S5.DONE"; touch -t "$(past 60)" "$TMP/out8/S5.DONE"   # round 1, inside this session
out="$(OSRC_SUPERVISE_SETTLE=5 sup --session S --watch "$TMP/out8")"
grep -q '^EVENT done osrc-auto-S5 ' <<<"$out" && ok "round 1: S5.DONE -> done" || no "round 1: [$out]"
# Round 2 on the same session: it works again (supervise sees it), then the screen changes.
pane osrc-auto-S5 cc-working-turn.txt; lib _sv_observe_all beacon
scr() { lib _sv_target_screen osrc-auto-S5 | head -1; }
pane osrc-auto-S5 cc-idle-bg-shell.txt
[ "$(scr)" = working ] && ok "round 2, background shell running: working, not the old DONE" || no "bg shell read as $(scr)"
pane osrc-auto-S5 cc-question-live.txt
[ "$(scr)" = question ] && ok "round 2, live question: question, not the old DONE" || no "question read as $(scr)"
lib _sv_idle_owed osrc-auto-S5; [ "$?" = 0 ] && ok "round 2 question: owed a waiter" || no "round 2 question read as settled"
pane osrc-auto-S5 cc-idle-after-work.txt
[ "$(scr)" = idle ] && ok "round 2 stopped without a new DONE: idle" || no "round 2 idle read as $(scr)"
lib _sv_idle_owed osrc-auto-S5; [ "$?" = 0 ] && ok "round 2 idle with only the old DONE: owed a waiter" || no "stale DONE settled the lane"
lib _sv_observe_all beacon
touch -t "$(past -5)" "$TMP/out8/S5.DONE"   # round 2's own hand-in (5 s ahead: never the same second as a read)
[ "$(scr)" = done ] && ok "round 2's own DONE: done" || no "round 2 DONE read as $(scr)"

echo "=== R3-2: an unseen short turn after a reported DONE reads idle, not done ==="
fresh 10; own S osrc-auto-S6; pane osrc-auto-S6 cc-idle-after-work.txt
reg osrc-auto-S6 "$(date -u -r $(( $(date +%s) - 120 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$(( $(date +%s) - 120 )) +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$TMP/out10"; : > "$TMP/out10/S6.DONE"; touch -t "$(past 60)" "$TMP/out10/S6.DONE"
out="$(OSRC_SUPERVISE_SETTLE=5 sup --session S --watch "$TMP/out10")"
grep -q '^EVENT done osrc-auto-S6 ' <<<"$out" && ok "round 1 reported done" || no "round 1: [$out]"
# A whole turn between two polls: never seen working, ends idle on a new screen, no new DONE.
sed 's/^⏺ ok$/⏺ Pushed the fix to feature\/x./' "$FX/cc-idle-after-work.txt" > "$TMP/panes/osrc-auto-S6.screen"
st="$(lib _sv_target_screen osrc-auto-S6 | head -1)"
[ "$st" = idle ] && ok "same DONE, changed screen: idle" || no "unseen short turn read as $st"
lib _sv_idle_owed osrc-auto-S6; [ "$?" = 0 ] && ok "and owed a waiter" || no "unseen short turn settled the lane"
out="$(sup --session S)"; grep -q '^EVENT idle osrc-auto-S6 ' <<<"$out" && ok "the idle is reported" || no "no event for the short turn: [$out]"
touch -t "$(past -5)" "$TMP/out10/S6.DONE"
st="$(lib _sv_target_screen osrc-auto-S6 | head -1)"
[ "$st" = done ] && ok "a new hand-in after it reads done again" || no "re-hand-in read as $st"

# No watch and no contract: the idle says how to register a done marker.
fresh 6; own S i6; pane i6 cc-idle-after-work.txt
out="$(sup --session S)"; grep -q '^EVENT idle i6 .*no done marker registered: re-arm with --watch' <<<"$out" && ok "idle with nothing registered names --watch / --done-when" || no "hint: [$out]"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
