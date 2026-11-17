#!/usr/bin/env bash
# sealed-run-requires: process-inspection
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_supervise.sh — L1: one `supervise` waiter wakes the orchestrator for every owned delegate that
# needs it (approval, question, idle-after-work, stalled, dead, limit), replays missed events, dedupes
# with a 20-minute reminder, and the stop guard is satisfied by a live supervise but not by nothing.
# Panes are real Claude Code 2.1 captures (fixtures/supervise) served by a file-backed fake tmux.
# Run: bash test_supervise.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"; FX="$SCRIPT_DIR/fixtures/supervise"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-supervise.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }; PIDS=""
trap 'for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/panes"; ln -s "$SCRIPT_DIR/fake-bin/tmux-files" "$TMP/bin/tmux"
export PATH="$TMP/bin:$PATH" FAKE_TMUX_DIR="$TMP/panes" OSRC_HEARTBEAT_DISABLED=1 OSRC_BLIND_TURN_GUARD=0 OSRC_STREAM=1
export OSRC_CLAUDE_PROJECTS_DIR="$TMP/projects" OSRC_CLAUDE_SESSIONS_DIR="$TMP/ccsessions"
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID
export OSRC_SUPERVISE_POLL=1 OSRC_SUPERVISE_CONFIRM=0 OSRC_SUPERVISE_SETTLE=0
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
# The hub/limits refresh tick (a full hub export, 3-6 s and probing the real agent CLIs) is not under
# test here (test_supervise_tick.py owns it): stamp it fresh so it is skipped. Left in, it ate the
# 20 s alarm under load (rc 142) and kept the stop-guard case's first supervise alive.
fresh() { export OSRC_HOME="$TMP/h$1"; mkdir -p "$OSRC_HOME/jobs" "$OSRC_HOME/sessions"; rm -f "$TMP/panes"/*.screen
  for s in S G nobody orch; do mkdir -p "$OSRC_HOME/supervise/$s"; date +%s > "$OSRC_HOME/supervise/$s/tick.time"; done; }
export OSRC_SUPERVISE_TICK_SECS=86400
own() { mkdir -p "$OSRC_HOME/owners/$1"; : > "$OSRC_HOME/owners/$1/$2"; }
pane() { cp "$FX/$2" "$TMP/panes/$1.screen"; }
sup() { perl -e 'alarm shift; exec @ARGV' "${T:-20}" "$SRC" supervise "$@" 2>"$TMP/err"; }
reg() { # <session> <event> [cc-session-id] [cwd]
  jq -cn --arg id "$1" --arg ev "$2" --arg cc "${3:-}" --arg cwd "${4:-}" \
    '{event:$ev,session_id:$id,provider:"cc",ts:(now|todate)} + (if $cc=="" then {} else {cc_session_id:$cc,cwd:$cwd} end)' >> "$OSRC_HOME/sessions/registry.jsonl"; }
ev_count() { grep -c "\"target\":\"$1\"" "$OSRC_HOME/lanes/events.jsonl" 2>/dev/null || echo 0; }

echo "=== fixtures classify (real Claude Code 2.1 panes) ==="
fresh 0
for pair in cc-idle-boot.txt:composer cc-idle-after-work.txt:idle cc-question-live.txt:question cc-working-hooks.txt:working cc-working-turn.txt:working codex-approval.ansi:approval; do
  f="${pair%%:*}"; want="${pair##*:}"; pane p "$f"
  got="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _sv_target_screen p | head -1 ) )"
  [ "$got" = "$want" ] && ok "$f -> $want" || no "$f -> $got (want $want)"
done

echo "=== approval wakes ==="
fresh 1; own S a1; pane a1 codex-approval.ansi
out="$(sup --session S)"; rc=$?
grep -q '^EVENT approval a1 [0-9]* approval prompt open' <<<"$out" && [ "$rc" = 0 ] && ok "approval -> EVENT approval, exit 0" || no "approval: rc=$rc [$out]"
grep -q '^NEXT OUTSOURCERER_TMUX=a1 .* session answer$' <<<"$(sed -n 2p <<<"$out")" && ok "approval NEXT is session answer (lists the options)" || no "approval NEXT wrong [$out]"

echo "=== question wakes (screen) and (transcript only) ==="
fresh 2; own S q1; pane q1 cc-question-live.txt
out="$(sup --session S)"; grep -q '^EVENT question q1 ' <<<"$out" && ok "a turn ending in a question -> EVENT question" || no "question: [$out]"
fresh 3; own S q2; pane q2 cc-idle-after-work.txt
mkdir -p "$OSRC_CLAUDE_PROJECTS_DIR/-w"; reg q2 start ccq2 /w
printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done with step 1.\nShould I also delete the old branch, or keep it for now"}]}}' > "$OSRC_CLAUDE_PROJECTS_DIR/-w/ccq2.jsonl"
out="$(sup --session S)"; grep -q '^EVENT question q2 .*transcript' <<<"$out" && ok "an empty-composer pane whose transcript asks -> question, not idle" || no "transcript question: [$out]"

echo "=== idle after work wakes; done all after ==="
fresh 4; own S i1; pane i1 cc-working-turn.txt
( sleep 2; cp "$FX/cc-idle-after-work.txt" "$TMP/panes/i1.screen" ) & PIDS="$PIDS $!"
out="$(sup --session S)"; grep -q '^EVENT idle i1 .*finished its turn' <<<"$out" && ok "working -> idle wakes as idle" || no "idle-after-work: [$out]"
# SUP (0.16.2): an idle lane short of done is still live work; a re-arm keeps watching it.
out="$(OSRC_SUPERVISE_MAX_SECS=3 sup --session S)"; ! grep -q '^EVENT done all ' <<<"$out" && ok "idle already reported, not done: re-arm keeps watching (no 'done all')" || no "idle lane settled: [$out]"
fresh 5; out="$(sup --session nobody)"; grep -q '^EVENT done all ' <<<"$out" && grep -q '^NEXT ' <<<"$out" && ok "no owned work -> EVENT done all + NEXT" || no "empty: [$out]"

echo "=== busy Codex flicker does NOT wake (synthetic frames) ==="
fresh 6; own S c1
printf '• Running cargo test\n  └ 12 passed\n\n• Working (14s • esc to interrupt)\n\n› \n' > "$TMP/busy"; printf '• Running cargo test\n  └ 12 passed\n\n› \n' > "$TMP/flick"
cp "$TMP/busy" "$TMP/panes/c1.screen"
( i=0; while [ $i -lt 30 ]; do cp "$TMP/flick" "$TMP/panes/c1.screen"; sleep 0.6; cp "$TMP/busy" "$TMP/panes/c1.screen"; sleep 0.6; i=$((i+1)); done ) & PIDS="$PIDS $!"
out="$(OSRC_SUPERVISE_CONFIRM=2 OSRC_SUPERVISE_MAX_SECS=7 sup --session S)"
grep -q '^EVENT idle' <<<"$out" && no "flicker woke as idle: [$out]" || ok "an idle-looking frame between busy frames never confirms"

echo "=== stalled wakes ==="
fresh 7; own S s1; pane s1 cc-working-turn.txt
out="$(OSRC_SUPERVISE_STALL=0 sup --session S)"; grep -q '^EVENT stalled s1 .*has not changed' <<<"$out" && ok "working with an unchanged screen past the stall window -> stalled" || no "stalled: [$out]"
printf 'garbage frame with nothing known\n' > "$TMP/panes/u1.screen"; own S u1; rm -f "$OSRC_HOME/owners/S/s1"
out="$(sup --session S)"; grep -q '^EVENT stalled u1 .*unrecognised' <<<"$out" && grep -q '^u1-' <<<"$(ls "$OSRC_HOME/fixtures-inbox/" 2>/dev/null)" \
  && ok "persistent unknown -> stalled + capture dropped in fixtures-inbox (E1/E2)" || no "unknown: [$out] inbox=$(ls "$OSRC_HOME/fixtures-inbox" 2>/dev/null)"

echo "=== dead pane wakes as failed; a deliberate stop does not ==="
fresh 8; own S d1; reg d1 start; own S d2; reg d2 start; reg d2 end
out="$(sup --session S)"; grep -q '^EVENT failed d1 .*gone' <<<"$out" && ok "pane gone with no stop recorded -> failed" || no "dead: [$out]"
grep -q ' d2 ' <<<"$out" && no "stopped session reported: [$out]" || ok "a session stopped on purpose is dropped silently"
[ ! -e "$OSRC_HOME/owners/S/d1" ] && ok "terminal targets leave the owner registry" || no "owner record kept"

echo "=== plan limit is its own event, never idle (E10) ==="
# banners print above the composer (in the history region), like every other turn output
above() { awk -v b="$2" '{l[NR]=$0} /^❯/{c=NR} END{for(i=1;i<=NR;i++){ if(i==c-1) print b; print l[i] }}' "$FX/$1"; }
fresh 9; own S l1; above cc-idle-after-work.txt "  ⎿  You've hit your usage limit · resets 3pm" > "$TMP/panes/l1.screen"
out="$(sup --session S)"; grep -q '^EVENT limit l1 ' <<<"$out" && ok "usage-limit banner -> EVENT limit" || no "limit: [$out]"

echo "=== batch: every actionable target in one wake, priority order ==="
fresh 10; own S b1; own S b2; own S b3; pane b1 cc-idle-after-work.txt; pane b2 codex-approval.ansi; pane b3 cc-question-live.txt
# The approval is visible at once; the quiet panes confirm one poll later. The settle window waits for them.
t0=$(date +%s); out="$(T=60 OSRC_SUPERVISE_SETTLE=40 sup --session S)"; dt=$(( $(date +%s) - t0 ))
[ "$dt" -lt 40 ] && ok "settle ends early once nothing is pending (${dt}s < 40s)" || no "settle waited the full window (${dt}s)"
[ "$(printf '%s\n' "$out" | grep -c '^EVENT ')" = 3 ] && [ "$(printf '%s\n' "$out" | grep -c '^NEXT ')" = 3 ] && ok "three targets -> three EVENT/NEXT pairs" || no "batch: [$out]"
[ "$(printf '%s\n' "$out" | grep '^EVENT' | awk '{print $2}' | tr '\n' ' ')" = "approval question idle " ] && ok "approval > question > idle" || no "order: $(printf '%s\n' "$out" | grep '^EVENT' | awk '{print $2}' | tr '\n' ' ')"

echo "=== dedupe + remind (5 min for approvals, S4) ==="
fresh 11; own S r1; pane r1 codex-approval.ansi
sup --session S >/dev/null
out="$(sup --session S --once)"; rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok "the same unresolved approval is not re-reported on the next arm" || no "dedupe: rc=$rc [$out]"
read -r h c ck ch cs lk lt < "$OSRC_HOME/lanes/state/r1"; echo "$h $c $ck $ch $cs $lk $((lt - 1300))" > "$OSRC_HOME/lanes/state/r1"
read -r fk ft < "$OSRC_HOME/lanes/state/r1.first"; echo "$fk $((ft - 1300))" > "$OSRC_HOME/lanes/state/r1.first"   # first sight, same fake clock
out="$(sup --session S --once)"; m="$(sed -n 's/^EVENT approval r1 .*still unresolved, waiting \([0-9]*\)m.*/\1/p' <<<"$out")"
[ "${m:-0}" -ge 21 ] && ok "re-reported after the reminder interval, with its age since first sight (${m}m)" || no "remind: [$out]"

echo "=== replay: events logged while nobody waited return at once ==="
fresh 12; own S p1; pane p1 codex-approval.ansi
( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _sv_observe_all beacon )
[ "$(ev_count p1)" = 1 ] && ok "the beacon pass appends to lanes/events.jsonl" || no "beacon did not log"
out="$(T=5 sup --session S)"; grep -q '^EVENT approval p1 ' <<<"$out" && ok "a later supervise replays it immediately" || no "replay: [$out]"
[ -s "$OSRC_HOME/supervise/S/cursor" ] && ok "per-orchestrator cursor advanced" || no "no cursor"

echo "=== stop guard ==="
guard() { printf '{"session_id":"%s"}' "$1" | OSRC_STOP_GUARD_MAX="${MAX:-2}" "$SRC" stop-guard 2>"$TMP/gerr"; }
fresh 13; own G q9; pane q9 cc-question-live.txt
out="$(guard G)"; printf '%s' "$out" | jq -e '.decision=="block"' >/dev/null 2>&1 && ok "an idle session parked on a question blocks the stop" || no "question not owed a waiter: [$out]"
grep -q 'supervise --session G' <<<"$(jq -r .reason <<<"$out")" && ok "the block names ONE supervise command" || no "reason: $(printf '%s' "$out" | jq -r .reason)"
fresh 14; own G i9; pane i9 cc-idle-after-work.txt
out="$(guard G)"; printf '%s' "$out" | jq -e '.decision=="block"' >/dev/null 2>&1 && ok "one unconfirmed idle read is not trusted (busy panes flicker idle)" || no "single idle read allowed the stop"
sup --session G >/dev/null   # supervise confirms and reports the idle
out="$(guard G)"; printf '%s' "$out" | jq -e '.decision=="block"' >/dev/null 2>&1 && ok "a confirmed idle session short of its done contract is owed a waiter (SUP)" || no "idle-not-done allowed the stop: [$out]"
mkdir -p "$OSRC_HOME/done" "$TMP/ws14"; : > "$TMP/ws14/i9.DONE"
jq -cn --arg p "$TMP/ws14/i9.DONE" --arg c "$TMP/ws14" '{spec:("file:"+$p),cwd:$c}' > "$OSRC_HOME/done/i9.json"
out="$(guard G)"; [ -z "$out" ] && ok "a confirmed idle session whose done contract holds does not block" || no "done idle blocked: [$out]"
own G w9; pane w9 cc-working-turn.txt
out="$(guard G)"; grep -q 'i9' <<<"$(jq -r .reason <<<"$out" 2>/dev/null)" && ok "an idle session IS owed a waiter while other owned work is live" || no "idle with live sibling: [$out]"
fresh 15; own G rl1; mkdir -p "$OSRC_HOME/remote"; echo '{}' > "$OSRC_HOME/remote/rl1.json"
out="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; osrc_remote_state() { echo live; }; printf '{"session_id":"G"}' | cmd_stop_guard 2>/dev/null ) )"
printf '%s' "$out" | jq -e '.decision=="block"' >/dev/null 2>&1 && ok "a remote lane with no waiter blocks the stop" || no "remote lane: [$out]"
fresh 16; own G q8; pane q8 codex-approval.ansi
sup --session G >/dev/null   # reports the approval and returns; the next arm has nothing new and blocks:
OSRC_SUPERVISE_REMIND=60 "$SRC" supervise --session G >/dev/null 2>&1 & SPID=$!; PIDS="$PIDS $SPID"
i=0; while [ $i -lt 150 ] && ! [ -e "$OSRC_HOME/supervise/G/armed.$SPID" ]; do sleep 0.2; i=$((i+1)); done
out="$(guard G)"; [ -z "$out" ] && ok "a live supervise covers every owned target" || no "blocked despite supervise: [$out]"
kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null   # exited: its armed file is gone or its pid is dead
out="$(MAX=1 guard G)"; out="$(MAX=1 guard G)"
[ -z "$out" ] && grep -q 'UNGUARDED' "$OSRC_HOME/owners/G/.unguarded" 2>/dev/null && ok "after max reminders the guard yields and writes .unguarded" || no "unguarded not written"
msg="$( ( export CLAUDE_CODE_SESSION_ID=G OSRC_STREAM=0; "$SRC" tab 2>&1 >/dev/null ) )"
grep -q 'UNGUARDED' <<<"$msg" && ok "the next outsourcerer call prints the unguarded line" || no "unguarded not surfaced: [$msg]"

echo "=== supervise never exits silently ==="
out="$("$SRC" supervise --bogus 2>/dev/null)"; rc=$?
[ "$rc" = 2 ] && grep -q '^EVENT failed supervise ' <<<"$out" && grep -q '^NEXT ' <<<"$out" && ok "internal error -> EVENT failed supervise + NEXT, exit 2" || no "error path: rc=$rc [$out]"
fresh 17; own S k1; pane k1 cc-working-turn.txt
"$SRC" supervise --session S > "$TMP/killed" 2>/dev/null & KP=$!
i=0; while [ $i -lt 100 ] && ! ls "$OSRC_HOME/supervise/S"/armed.* >/dev/null 2>&1; do sleep 0.2; i=$((i+1)); done
kill -TERM "$KP"; wait "$KP"; rc=$?
grep -q '^EVENT failed supervise .*signal' "$TMP/killed" && [ "$rc" = 2 ] && ok "SIGTERM -> EVENT failed supervise (re-arm NEXT), exit 2" || no "signal path rc=$rc [$(cat "$TMP/killed")]"

echo "=== lib/ loads through a symlink (LOADER.md) ==="
mkdir -p "$TMP/linkdir"; ln -s "$SRC" "$TMP/linkdir/outsourcerer"
fresh 19; export OSRC_HOME="$TMP/h19"; out="$("$TMP/linkdir/outsourcerer" supervise --session nobody 2>&1)"
grep -q '^EVENT done all ' <<<"$out" && ok "supervise works when run through a symlink" || no "symlinked supervise: [$out]"
own G sq1; pane sq1 cc-question-live.txt
out="$(printf '{"session_id":"G"}' | "$TMP/linkdir/outsourcerer" stop-guard 2>/dev/null)"
printf '%s' "$out" | jq -e '.decision=="block"' >/dev/null 2>&1 && ok "the stop guard (lib/stopguard.sh) is live through a symlink" || no "symlinked stop-guard silent: [$out]"
got="$( ( OSRC_SOURCED=1; . "$TMP/linkdir/outsourcerer" >/dev/null 2>&1; type -t cmd_supervise; type -t cmd_stop_guard ) | tr '\n' ' ')"
[ "$got" = "function function " ] && ok "sourcing through a symlink loads lib/ too" || no "sourced via symlink: [$got]"

echo "=== review round 2 ==="
# Finding 2: a run that finished between arms is reported, not pruned into "nothing owned".
fresh 20; mkdir -p "$OSRC_HOME/autodetach"; own orch run-a; : > "$OSRC_HOME/autodetach/run-a.log"; echo 0 > "$OSRC_HOME/autodetach/run-a.rc"
out="$(guard orch)"; [ ! -e "$OSRC_HOME/owners/orch/run-a" ] && ok "stop guard prunes the finished run's marker" || no "marker kept"
out="$(sup --session orch)"; grep -q '^EVENT done run-a .*exit 0' <<<"$out" && ok "the next supervise still reports it done (event logged before pruning, replayed by owner)" || no "finished run lost: [$out]"
# Finding 3: a fresh session (composer, no turn yet) is not an event and not live work.
fresh 21; own S f1; pane f1 cc-idle-boot.txt
out="$(sup --session S)"; grep -q '^EVENT done all ' <<<"$out" && ! grep -q 'unsent' <<<"$out" && ok "fresh session: no 'unsent text' event, nothing live" || no "fresh session: [$out]"
# Finding 4: the done contract is checked before the question.
fresh 22; own S dn1; pane dn1 cc-question-live.txt
out="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; osrc_done_state() { echo done; }; _sv_main S 0 ) )"
grep -q '^EVENT done dn1 .*it also asked' <<<"$out" && ok "a finished lane that closes with a question is done (question kept in the detail)" || no "done-before-question: [$out]"
# Integration 13:15: an API/login error wakes as failed after one automatic continue.
fresh 23; own S ae1; above cc-idle-after-work.txt "  ⎿  Please run /login · API Error: 403 Attention Required! | Cloudflare" > "$TMP/panes/ae1.screen"
mkdir -p "$TMP/sendlog"; cat > "$TMP/bin/send-shim" <<'SH'
#!/bin/bash
echo "$OUTSOURCERER_TMUX $*" >> "$SENDLOG"
SH
chmod +x "$TMP/bin/send-shim"
out="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; SCRIPT_PATH="$TMP/bin/send-shim"; export SENDLOG="$TMP/sendlog/log"; _sv_main S 0 ) )"
grep -q '^ae1 session send continue$' "$TMP/sendlog/log" 2>/dev/null && ok "API error: one automatic 'continue' through session send" || no "no auto continue: $(cat "$TMP/sendlog/log" 2>/dev/null)"
[ "$(wc -l < "$TMP/sendlog/log" | tr -d ' ')" = 1 ] && ok "exactly one automatic retry" || no "retries: $(wc -l < "$TMP/sendlog/log")"
grep -q '^EVENT failed ae1 .*API Error.*one automatic' <<<"$out" && grep -q "^NEXT OUTSOURCERER_TMUX=ae1 .* session send 'continue'$" <<<"$out" \
  && ok "still failing -> EVENT failed with NEXT session send 'continue'" || no "api error event: [$out]"
# Round 2 finding 1: words are not a banner. None of these may type anything or read `failed`.
neg() { # <id> <expected-kind-regex> <lines...>: screen = real cc pane with <lines> above the composer
  local id="$1" want="$2"; shift 2
  B="$(printf '%s\n' "$@")" awk '{l[NR]=$0} /^❯/{c=NR} END{for(i=1;i<=NR;i++){ if(i==c-1) print ENVIRON["B"]; print l[i] }}' "$FX/cc-idle-after-work.txt" > "$TMP/panes/$id.screen"
  [ -s "$TMP/panes/$id.screen" ] || no "test setup: empty screen for $id"
}
fresh 27; : > "$TMP/sendlog/log"
own S ng1; neg ng1 x "⏺ The deploy script printed Connection error twice. Should I drop the staging database and re-seed it, or stop here?"
own S ng2; neg ng2 x "⏺ Done. Added a retry for 429 Too Many Requests and ECONNRESET in fetch.ts. All 14 tests pass."
own S ng3; neg ng3 x "  ⎿  src/errors.ts:12: Overloaded = 529," "⏺ That is the only place it is defined."
own S ng4; neg ng4 x "⏺ Fixed the handler that logs API Error: 429 and Please run /login hints."
# Review r4: a tool RESULT under its tool-call header has the banner's shape; it is the log's text.
own S ng6; neg ng6 x "⏺ Bash(tail -1 app.log)" "  ⎿  API Error: 502 upstream timed out"
got="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; L="  ⎿  API Error: 502 upstream timed out"
  _sv_api_banner cc "$L" "⏺ Bash(tail -1 app.log)" && echo T; _sv_api_banner cc "$L" "❯ fix the build" && echo B; _sv_api_banner cc "$L" && echo B ) )"
[ "$(tr -d '\n' <<<"$got")" = BB ] && ok "the same line under a tool-call header is a tool result; under a prompt it is still a banner" || no "banner/tool header: [$got]"
out="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; SCRIPT_PATH="$TMP/bin/send-shim"; export SENDLOG="$TMP/sendlog/log"; OSRC_SUPERVISE_MAX_SECS=5 _sv_main S 0 ) )"
[ ! -s "$TMP/sendlog/log" ] && ok "a delegate's question / done summary / tool output naming errors types nothing" || no "typed into a lane: $(cat "$TMP/sendlog/log")"
grep -q '^EVENT failed' <<<"$out" && no "ordinary text read as failed: [$out]" || ok "none of them reads as failed"
grep -q '^EVENT question ng1 ' <<<"$out" && ok "the destructive question is reported as a question" || no "ng1 not a question: [$out]"
fresh 28; : > "$TMP/sendlog/log"; own S ng5; neg ng5 x "⏺ Done. Want me to also add a retry for API Error: 429?" "  ⎿  Please run /login · API Error: 403 Attention Required! | Cloudflare"
out="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; osrc_done_state() { echo done; }; SCRIPT_PATH="$TMP/bin/send-shim"; export SENDLOG="$TMP/sendlog/log"; OSRC_SUPERVISE_MAX_SECS=4 _sv_main S 0 ) )"
[ ! -s "$TMP/sendlog/log" ] && grep -q '^EVENT done ng5 ' <<<"$out" && ok "done contract holds -> done, never an automatic continue (even under a banner)" || no "done lane typed into / misread: [$out] $(cat "$TMP/sendlog/log")"
# Round 2 finding 3b: session id `..` is "no session", never the state home.
fresh 29; echo '{"x":1}' > "$OSRC_HOME/ledger.jsonl"; echo '{"y":1}' > "$OSRC_HOME/obligations.jsonl"
printf '{"session_id":".."}' | "$SRC" stop-guard >/dev/null 2>&1
[ -s "$OSRC_HOME/ledger.jsonl" ] && [ -s "$OSRC_HOME/obligations.jsonl" ] && ok "stop-guard with session_id '..' leaves the state home untouched" || no "state home files deleted"
out="$("$SRC" supervise --session .. 2>/dev/null)"; grep -q '^EVENT failed supervise ' <<<"$out" && ok "supervise --session .. is refused" || no "supervise accepted '..': [$out]"

# Finding 1: the approver's four return codes.
fresh 24; own S ap1; own S ap2; own S ap3; own S ap4; pane ap1 codex-approval.ansi; pane ap2 codex-approval.ansi; pane ap3 codex-approval.ansi; pane ap4 codex-approval.ansi
# (bash 3.2 misparses `case` inside $( ), so the stub lives in a file)
cat > "$TMP/tick.sh" <<'SH'
osrc_approver_tick() {
  case "$1" in
    ap1) printf 'EVENT approved ap1 1 approved once by policy safe (read-only): ls\nNEXT X session read\n'; return 0 ;;
    ap2) printf 'EVENT approval ap2 1 held by policy safe (rm outside worktree): rm -rf /\nNEXT X session answer\n'; return 2 ;;
    ap3) return 3 ;;
    *) return 1 ;;
  esac
}
SH
out="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; . "$TMP/tick.sh"; OSRC_SUPERVISE_MAX_SECS=4 _sv_main S 0 ) )"
grep -q '^EVENT approval ap2 [0-9]* held by policy safe' <<<"$out" && grep -q '^NEXT X session answer$' <<<"$out" && ok "rc 2: the approver's own EVENT approval + NEXT wake" || no "rc2: [$out]"
grep -q '^EVENT approval ap4 .*approval prompt open' <<<"$out" && ok "rc 1: supervise reports the prompt itself" || no "rc1: [$out]"
grep -q ' ap3 ' <<<"$out" && no "rc 3 re-reported: [$out]" || ok "rc 3: already-held prompt is not re-reported"
grep -q '"kind":"approved","target":"ap1"' "$OSRC_HOME/lanes/events.jsonl" && ok "rc 0: EVENT approved is logged" || no "approved not logged"
fresh 25; own S ap5; pane ap5 cc-working-turn.txt
out="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
  osrc_approver_tick() { printf 'EVENT approved ap5 1 approved once: ls\nNEXT X session read\n'; return 0; }
  OSRC_SUPERVISE_MAX_SECS=3 _sv_main S 0 ) )"
grep -q '^EVENT approved' <<<"$out" && no "approved woke the orchestrator: [$out]" || ok "rc 0 alone never wakes (informational)"
# Finding 8: rotation does not lose events written before it.
fresh 26; own S rt1; pane rt1 cc-working-turn.txt
( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; mkdir -p "$OSRC_HOME/supervise/S"; _sv_append idle zz "pre" "n" t; printf '%s 0\n' "$(wc -c < "$OSRC_HOME/lanes/events.jsonl" | tr -d ' ')" > "$OSRC_HOME/supervise/S/cursor"
  _sv_append question rt1 "written before rotation" "n" t S; OSRC_LANES_LOG_MAX=1 _sv_append idle zz "rotates" "n" t )
out="$(T=8 OSRC_SUPERVISE_MAX_SECS=3 sup --session S)"; grep -q '^EVENT question rt1 .*before rotation' <<<"$out" && ok "an event logged just before a rotation still replays" || no "rotation lost it: [$out]"

echo "=== E11 model aliases, E1 managed rows, E2 wait ==="
( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
  _session_model_matches claude-sonnet-5-5 claude-sonnet-5-5 sonnet && echo A
  _session_model_matches sonnet "" claude-sonnet-5-5 && echo B
  _session_model_matches claude-sonnet-5-5 "" claude-opus-5-5 || echo C
  _session_model_matches claude-sonnet-5-5 "" claude-sonnet-4-5 || echo D ) > "$TMP/e11"
[ "$(tr -d '\n' < "$TMP/e11")" = ABCD ] && ok "sonnet alias matches claude-sonnet-5-5; different models/versions still drift" || no "E11: $(cat "$TMP/e11")"
fresh 18; pane m1 codex-approval.ansi; pane m2 cc-working-turn.txt; pane m3 cc-idle-boot.txt
got="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; for p in m1 m2 m3; do _sv_fleet_state "tmux:$p" | cut -d "$(printf '\037')" -f1; done; _sv_fleet_state "" | cut -d "$(printf '\037')" -f1 ) | tr '\n' ' ')"
[ "$got" = "blocked? working idle unknown " ] && ok "managed panes get a real fleet state (was hardcoded unknown)" || no "E1 states: $got"
grep -q 'state:\$pst,state_evidence:\$pev' "$SRC" && ok "the managed fleet row uses the classified pane state" || no "managed row still hardcoded"
grep -q 'unknown) _sv_unknown_persistent' "$SRC" && ok "wait has an unknown branch (no infinite loop)" || no "wait unknown branch missing"

echo "=== hand-ins: a rewritten DONE / VERDICT fires again (name + mtime + size + hash) ==="
fresh 40; W="$TMP/ws40"; mkdir -p "$W/out" "$W/reviews"; : > "$W/out/L1.DONE"; echo report > "$W/out/L1-REPORT.md"; echo old > "$W/reviews/L1-VERDICT.md"
touch -m -t 202601010000 "$W/out/L1.DONE" "$W/reviews/L1-VERDICT.md"
out="$(sup --session S --watch "$W/out" --watch "$W/reviews" --once)"; rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok "registering a watch baselines the hand-ins already there (no event, still blocking)" || no "baseline fired: rc=$rc [$out]"
grep -q '^watch\.' <<<"$(ls "$OSRC_HOME/owners/S/")" && ok "a watch is an owned target in the registry" || no "watch not registered"
touch -m -t 202601010100 "$W/out/L1.DONE"   # same name, same (empty) content, new mtime: a re-hand-in
out="$(sup --session S --once)"
grep -q '^EVENT done L1.DONE [0-9]* hand-in L1.DONE rewritten (re-hand-in)' <<<"$out" && ok "an existing DONE rewritten -> EVENT done (file names unchanged)" || no "rewritten DONE missed: [$out]"
grep -q '^NEXT cat [^;|&]*/out/L1-REPORT\.md$' <<<"$out" && ok "its NEXT reads the lane's report" || no "DONE NEXT: [$out]"
out="$(sup --session S --once)"; rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok "the same hand-in never fires twice" || no "repeat fired: rc=$rc [$out]"
printf 'sha1111\n' > "$W/out/L1.DONE"; sup --session S --once >/dev/null
touch -r "$W/out/L1.DONE" "$TMP/ref40"; printf 'sha2222\n' > "$W/out/L1.DONE"; touch -m -r "$TMP/ref40" "$W/out/L1.DONE"
out="$(sup --session S --once)"
grep -q '^EVENT done L1.DONE .*re-hand-in' <<<"$out" && ok "same name, mtime and size, new sha inside -> fires (content hash)" || no "content-only rewrite missed: [$out]"
echo new > "$W/reviews/L1-VERDICT.md"; printf 'which branch?\n' > "$W/out/L2.QUESTION"
out="$(sup --session S --once)"
grep -q '^EVENT done L1-VERDICT.md .*review verdict L1-VERDICT.md rewritten' <<<"$out" && grep -q '^EVENT question L2.QUESTION .*written' <<<"$out" \
  && ok "a rewritten verdict and a new question in one batch -> two pairs" || no "verdict/question: [$out]"
touch -m -t 202601010200 "$W/out/L1.DONE"
out="$(sup --session S --watch "$W/out" --once)"
grep -q '^EVENT done L1.DONE .*re-hand-in' <<<"$out" && ok "re-registering a watch never re-baselines (a rewrite between arms still fires)" || no "re-register swallowed it: [$out]"
touch -m -t 202601010300 "$W/out/L1.DONE"
( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _sv_observe_all beacon )
out="$(sup --session S --once)"
grep -q '^EVENT done L1.DONE .*re-hand-in' <<<"$out" && ok "a rewrite logged by the beacon with no supervise armed replays on the next arm" || no "beacon hand-in lost: [$out]"
wid="$(ls "$OSRC_HOME/owners/S/" | grep '^watch\.' | head -1)"
got="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _owned_live_state "$wid" ) )"
[ "$got" = live ] && ok "the stop guard treats a registered watch as live work owed a waiter" || no "watch state: $got"
"$SRC" supervise --session S --unwatch "$W/out" 2>/dev/null; "$SRC" supervise --session S --unwatch "$W/reviews" 2>/dev/null
[ -z "$(ls "$OSRC_HOME/owners/S/" | grep '^watch\.')" ] && [ "$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _owned_live_state "$wid" ) )" = gone ] \
  && ok "--unwatch removes the watch and its owner record" || no "unwatch left: $(ls "$OSRC_HOME/owners/S/")"
out="$("$SRC" supervise --session S --watch "$TMP/nope" 2>/dev/null)"; rc=$?
[ "$rc" = 2 ] && grep -q '^EVENT failed supervise .*--watch' <<<"$out" && ok "--watch on a missing path fails loudly" || no "missing watch: rc=$rc [$out]"
# Review r4 finding 1: a lane-written file name must never become shell in NEXT.
fresh 42; W="$TMP/ws42"; mkdir -p "$W/out" "$TMP/run42"; : > "$W/out/L5.DONE"
"$SRC" supervise --session S --watch "$W/out" --once >/dev/null 2>&1
evil="x';touch\${IFS}PWNED;'.DONE"; : > "$W/out/$evil"; : > "$W/out/a b.DONE"; : > "$W/out/-rf.DONE"; : > "$W/out/\$(touch PWNED2).DONE"
touch -m -t 202601010500 "$W/out/L5.DONE"
out="$(sup --session S --once)"; err1="$(cat "$TMP/err")"
grep -q '^EVENT done L5.DONE ' <<<"$out" && ok "a well-named hand-in next to hostile names still fires" || no "L5.DONE lost: [$out]"
[ "$(grep -c '^EVENT' <<<"$out")" = 1 ] && ok "hostile / spaced / dash-led / \$( ) names produce no event" || no "hostile name produced an event: [$out]"
[ "$(grep -c 'ignored hand-in file with an unusual name' <<<"$err1")" = 4 ] && ! grep -q "[';\$ ]PWNED\|touch\\$" <<<"$(grep 'ignored hand-in' <<<"$err1" | sed 's/^.*: //')" \
  && ok "each unusual name is reported once on stderr, with its unusual characters removed" || no "notice: [$err1]"
touch -m -t 202601010600 "$W/out/L5.DONE"; sup --session S --once >/dev/null; err2="$(cat "$TMP/err")"
grep -q 'ignored hand-in' <<<"$err2" && no "the notice repeats on every pass: [$err2]" || ok "the notice is said once, not on every pass"
grep '^NEXT ' <<<"$out" | sed 's/^NEXT //' > "$TMP/run42/next.sh"
next_file_scan() {
  local names rc
  names="$(ls "$1" 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] && return 2
  grep -q '^PWNED' <<<"$names"
}
next_file_scan "$TMP/missing-watch-dir"; scan_rc=$?
[ "$scan_rc" -ge 2 ] && ok "NEXT file scan reports a missing directory" || no "NEXT file scan accepted a missing directory (rc=$scan_rc)"
( cd "$TMP/run42" && bash next.sh >/dev/null 2>&1 )
next_file_scan "$W/out"; scan_rc=$?
if [ "$scan_rc" -ge 2 ]; then
  no "NEXT file scan failed (rc=$scan_rc)"
elif [ "$scan_rc" -eq 1 ] && [ ! -e "$TMP/run42/PWNED" ] && [ ! -e "$TMP/run42/PWNED2" ]; then
  ok "running every printed NEXT in a temp dir creates nothing"
else
  no "a NEXT created a file: $(ls "$TMP/run42" "$W/out")"
fi
( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _sv_observe_all beacon ) 2>/dev/null
! grep -q 'PWNED' "$OSRC_HOME/lanes/events.jsonl" && ok "the beacon never logs a hostile name either (events.jsonl clean)" || no "events.jsonl carries the name"
nx="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; f="$W/out/L5.DONE"; printf 'cat %q' "$f" ) )"
grep -q "^NEXT $(printf '%s' "$nx" | sed 's/[][\.*^$/]/\\&/g')$" <<<"$out" && ok "NEXT is built with printf %q" || no "NEXT not %q-quoted: [$out] want [$nx]"
# Review r5 #3: the orchestrator's own watch path may hold spaces, quotes, `$`; NEXT carries it via %q.
fresh 43; W="$TMP/ws43/Mobile Documents/it's \$HOME (x)"; mkdir -p "$W"; : > "$W/L7.DONE"; echo report7 > "$W/L7-REPORT.md"
"$SRC" supervise --session S --watch "$W" --once >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && { _t3b_pipe="$(ls "$OSRC_HOME/owners/S/" 2>/dev/null)" && grep -q '^watch\.' <<<"$_t3b_pipe"; } && ok "a watch path with spaces, a quote and \$ is accepted" || no "spaced watch path refused: rc=$rc $(cat "$TMP/err" 2>/dev/null)"
touch -m -t 202601010700 "$W/L7.DONE"; out="$(sup --session S --once)"; mkdir -p "$TMP/run43"
grep -q '^EVENT done L7.DONE ' <<<"$out" && [ "$(cd "$TMP/run43" && bash -c "$(sed -n 's/^NEXT //p' <<<"$out")" 2>&1)" = report7 ] && [ -z "$(ls "$TMP/run43")" ] \
  && ok "its NEXT runs as one plain cat of the report (printf %q), creating nothing" || no "spaced NEXT: [$out] ran: [$(cd "$TMP/run43" && bash -c "$(sed -n 's/^NEXT //p' <<<"$out")" 2>&1)] left: [$(ls "$TMP/run43")]"
mkdir -p "$TMP/ws43/a
b"; out="$("$SRC" supervise --session S --watch "$TMP/ws43/a
b" 2>/dev/null)"; rc=$?
[ "$rc" = 2 ] && grep -q '^EVENT failed supervise .*--watch: path has control characters' <<<"$out" && ok "a watch path with a newline is refused" || no "newline path: rc=$rc [$out]"
# Review r5 #1: a symlink in the watched folder is not a hand-in (a lane could point it anywhere).
fresh 44; W="$TMP/ws44"; mkdir -p "$W"; : > "$W/L8.DONE"; "$SRC" supervise --session S --watch "$W" --once >/dev/null 2>&1
ln -s /etc/hosts "$W/LINK.DONE"; touch -m -t 202601010800 "$W/L8.DONE"
out="$(sup --session S --once)"; err1="$(cat "$TMP/err")"
grep -q '^EVENT done L8.DONE ' <<<"$out" && ! grep -q 'LINK' <<<"$out" && ! grep -q 'LINK' "$OSRC_HOME/lanes/events.jsonl" \
  && ok "LINK.DONE -> /etc/hosts gives no event (the real hand-in beside it still does)" || no "symlink hand-in: [$out]"
[ "$(grep -c 'ignored hand-in symlink' <<<"$err1")" = 1 ] && ok "the symlink is reported once" || no "symlink notice: [$err1]"
touch -m -t 202601010900 "$W/L8.DONE"; sup --session S --once >/dev/null; grep -q 'ignored hand-in' "$TMP/err" && no "symlink notice repeats" || ok "the symlink notice is not repeated"

# A tmux lane whose done contract is a file: the re-hand-in is a new done even on the same screen.
fresh 41; own S dn2; pane dn2 cc-idle-after-work.txt; mkdir -p "$OSRC_HOME/done" "$TMP/ws41"; : > "$TMP/ws41/dn2.DONE"
jq -cn --arg p "$TMP/ws41/dn2.DONE" '{spec:("file:"+$p),cwd:"/"}' > "$OSRC_HOME/done/dn2.json"
dn() { ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; osrc_done_state() { echo done; }; _sv_main S 1 ) 2>/dev/null; }
dn >/dev/null   # first poll only proposes the quiet state; the second confirms it
o1="$(dn)"; o2="$(dn)"; touch -m -t 202601010400 "$TMP/ws41/dn2.DONE"; o3="$(dn)"
grep -q '^EVENT done dn2 .*hand-in' <<<"$o1" && ! grep -q '^EVENT done dn2' <<<"$o2" && grep -q '^EVENT done dn2 .*hand-in' <<<"$o3" \
  && ok "a lane's done contract file rewritten -> EVENT done again, same screen" || no "contract re-hand-in: [$o1] [$o2] [$o3]"

# Identical event text must not hide a new remote head within the reminder window.
fresh 44; mkdir -p "$OSRC_HOME/remote"
jq -n '{head:"aaaaaaa111111111111111111111111111111111"}' > "$OSRC_HOME/remote/rh.json"
(
  OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
  osrc_remote_events() { printf 'EVENT done rh 100 READY same detail\nNEXT inspect rh\n'; }
  _sv_remote_poll test; _sv_remote_poll test
  jq '.head="aaaaaaa222222222222222222222222222222222"' "$OSRC_HOME/remote/rh.json" > "$TMP/rh.json"
  mv "$TMP/rh.json" "$OSRC_HOME/remote/rh.json"
  _sv_remote_poll test; _sv_remote_poll test
)
[ "$(jq -s 'map(select(.target == "rh" and .kind == "done")) | length' "$OSRC_HOME/lanes/events.jsonl")" = 2 ] \
  && ok "remote re-hand-in with identical detail and new full sha fires once" || no "remote re-hand-in lost or duplicated"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
