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
grep -q "	idle	i1	" "$OSRC_HOME/supervise/S/delivered" && ok "the ledger records the delivered row" || no "ledger: $(cat "$OSRC_HOME/supervise/S/delivered" 2>/dev/null)"
# A new idle (the lane worked again, then stopped) is a new row and is delivered.
cp "$FX/cc-working-turn.txt" "$TMP/panes/i1.screen"; lib _sv_observe_all beacon
cp "$FX/cc-idle-after-work.txt" "$TMP/panes/i1.screen"; sleep 1
out="$(sup --session S)"; grep -q '^EVENT idle i1 ' <<<"$out" && ok "a later, new idle is still delivered" || no "new idle swallowed: [$out]"
# Ledger rows older than 24 h are pruned.
printf '1\tidle\told\tx\n' >> "$OSRC_HOME/supervise/S/delivered"
lib _sv_ledger_add "$OSRC_HOME/supervise/S/delivered" "$(printf '6\t%s\tidle\tz\td\tn' "$(date +%s)")"
grep -q '	old	' "$OSRC_HOME/supervise/S/delivered" && no "24h-old ledger row kept" || ok "ledger prunes rows older than 24 h"

echo "=== per-target lock: two observers never log the same change twice ==="
fresh 2; own S i2; pane i2 cc-idle-after-work.txt
mkdir -p "$OSRC_HOME/lanes/state"; mkdir "$OSRC_HOME/lanes/state/i2.lock"   # another process is on i2
got="$(lib sh -c '_sv_observe_emit i2 "$(date +%s)" supervise S; printf "%s %s %s" "${SV_K:-none}" "$SV_OUT" "$SV_PEND"' 2>/dev/null)"
got="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _sv_observe_emit i2 "$(date +%s)" supervise S; printf '%s %s %s' "${SV_K:-none}" "$SV_OUT" "$SV_PEND" ) )"
[ "$got" = "none 1 1" ] && [ "$(rows i2)" = 0 ] && ok "a held lock: no row, target stays pending and owed a waiter" || no "held lock: [$got] rows=$(rows i2)"
touch -t "$(date -r $(( $(date +%s) - 600 )) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$(( $(date +%s) - 600 )) +%Y%m%d%H%M.%S)" "$OSRC_HOME/lanes/state/i2.lock"
# a quiet state needs two reads to confirm (OSRC_SUPERVISE_CONFIRM=0: back to back)
lib _sv_observe_emit i2 "$(date +%s)" supervise S; lib _sv_observe_emit i2 "$(date +%s)" supervise S
[ "$(rows i2)" = 1 ] && [ ! -d "$OSRC_HOME/lanes/state/i2.lock" ] && ok "a lock left by a killed run (10 min old) is broken and released" || no "stale lock: rows=$(rows i2)"
lib _sv_observe_emit i2 "$(date +%s)" supervise S; lib _sv_observe_emit i2 "$(date +%s)" beacon S
[ "$(rows i2)" = 1 ] && ok "repeat observers of an unchanged idle add no row" || no "repeat rows=$(rows i2)"
# Two supervise processes at once for the same orchestrator: one row, one delivery in total.
fresh 3; own S i3; pane i3 cc-idle-after-work.txt
( sup --session S > "$TMP/a.out" ) & pa=$!; ( sup --session S > "$TMP/b.out" ) & pb=$!
# whichever finishes first leaves the other blocking on the reported idle: end it once one is done
i=0; while [ "$i" -lt 600 ] && ! grep -q '^EVENT' "$TMP/a.out" "$TMP/b.out" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
sleep 3; kill "$pa" "$pb" 2>/dev/null; wait "$pa" "$pb" 2>/dev/null
n="$(cat "$TMP/a.out" "$TMP/b.out" | grep -c '^EVENT idle i3 ')"
[ "$(rows i3)" = 1 ] && ok "two concurrent supervises log one idle row" || no "concurrent rows=$(rows i3)"
[ "$n" = 1 ] && ok "and deliver it once between them" || no "delivered $n times: $(cat "$TMP/a.out" "$TMP/b.out")"

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
# No watch and no contract: the idle says how to register a done marker.
fresh 6; own S i6; pane i6 cc-idle-after-work.txt
out="$(sup --session S)"; grep -q '^EVENT idle i6 .*no done marker registered: re-arm with --watch' <<<"$out" && ok "idle with nothing registered names --watch / --done-when" || no "hint: [$out]"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
