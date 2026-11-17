#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_stall.sh: no lane ever waits unseen (lib/stall.sh + lib/mc_alive.sh). One regression per
# incident in the 0.17 no-stalls brief, plus the edges the brief names. Panes are real Claude Code
# captures (fixtures/supervise/cc-*-bgshell-footer*.txt, 2026-11-17, see the README) served by the
# file-backed fake tmux. Fake clock: every observation is passed an explicit `now`, or the state file
# that holds a time is moved back; nothing here sleeps to wait for a window.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"; FX="$SCRIPT_DIR/fixtures/supervise"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-stall.XXXXXX")" || { echo "FAIL: no scratch dir" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/panes" "$TMP/home"
# The file-backed fake tmux, plus: Enter sent to <t> swaps in <t>.next when one is staged (an answer that
# lands and opens a different prompt).
ln -s "$SCRIPT_DIR/fake-bin/tmux-files-next" "$TMP/bin/tmux"; export FAKE_TMUX_FILES="$SCRIPT_DIR/fake-bin/tmux-files"
export HOME="$TMP/home" PATH="$TMP/bin:$PATH" FAKE_TMUX_DIR="$TMP/panes" OSRC_HEARTBEAT_DISABLED=1 OSRC_BLIND_TURN_GUARD=0 OSRC_STREAM=1
export OSRC_CLAUDE_PROJECTS_DIR="$TMP/projects" OSRC_CLAUDE_SESSIONS_DIR="$TMP/ccsessions" OSRC_MC_AUTO_OPEN=0
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID OSRC_SUPERVISE_REMIND OSRC_STALL_MIN OSRC_AUTONUDGE OSRC_HOLD_MIN
export OSRC_SUPERVISE_POLL=1 OSRC_SUPERVISE_CONFIRM=0 OSRC_SUPERVISE_SETTLE=0 OSRC_SUPERVISE_TICK_SECS=86400
# The nudge goes through `session send`, which needs a provably live pane; the fake pane is a file, so
# the sender is recorded instead (the seam lib/stall.sh documents).
cat > "$TMP/bin/nudge-rec" <<'EOF'
#!/bin/bash
printf '%s\t%s\n' "$1" "$2" >> "$FAKE_TMUX_DIR/nudges.log"
EOF
chmod +x "$TMP/bin/nudge-rec"; export OSRC_NUDGE_SEND_CMD="$TMP/bin/nudge-rec"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
fresh() { export OSRC_HOME="$TMP/h$1"; mkdir -p "$OSRC_HOME/jobs" "$OSRC_HOME/sessions" "$OSRC_HOME/supervise/S"
  date +%s > "$OSRC_HOME/supervise/S/tick.time"; rm -f "$TMP/panes"/*.screen "$TMP/panes"/*.log; }
own() { mkdir -p "$OSRC_HOME/owners/$1"; : > "$OSRC_HOME/owners/$1/$2"; }
pane() { cp "$FX/$2" "$TMP/panes/$1.screen"; }
lib() { ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; "$@" ); }
# obs <id> <now>: one supervise observation at a fake time; prints "kind|detail" of what it logged now
obs() { ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _sv_observe_emit "$1" "$2" supervise S; printf '%s|%s|%s\n' "${SV_K:-none}" "$SV_D" "$SV_NX" ); }
kinds() { jq -r --arg t "$1" 'select(.target==$t) | .kind' "$OSRC_HOME/lanes/events.jsonl" 2>/dev/null | tr '\n' ' '; }
nudges() { grep -c "^$1	" "$TMP/panes/nudges.log" 2>/dev/null || echo 0; }
sup() { perl -e 'alarm shift; exec @ARGV' "${T:-30}" "$SRC" supervise "$@" 2>"$TMP/err"; }
N0="$(date +%s)"

echo "=== incident 1: idle with its own background shell running (S3, 09:02-09:22) ==="
# The live screen: the turn summary lost the shell count, the footer kept it mid-line
# (`⏵⏵ auto mode on · 1 shell · ← 15 agents · ↓ to manage`). The old footer regex wanted `shell` at end
# of line, so supervise said `idle` once and then nothing for 20 minutes.
fresh 1; own S s3; pane s3 cc-idle-bgshell-footer-only.txt
st="$(lib _sv_target_screen s3 | head -1)"
[ "$st" = working ] && ok "footer '· 1 shell ·' mid-line: read as waiting on its shell, not idle" || no "S3 screen read as '$st'"
r="$(obs s3 "$N0")"; r="$(obs s3 $((N0 + 60)))"
case "$r" in none*) ok "inside OSRC_STALL_MIN: no event yet (a short background run is normal)" ;; *) no "early event: $r" ;; esac
r="$(obs s3 $((N0 + 301)))"
[ "$(nudges s3)" = 1 ] && ok "after 5 min unchanged: supervise nudged the lane itself, once" || no "nudges=$(nudges s3) r=$r"
grep -q 'background task' "$TMP/panes/nudges.log" && grep -q 'kill it and rerun in the foreground' "$TMP/panes/nudges.log" \
  && ok "the nudge is the brief's text (check output, kill+rerun in foreground, continue)" || no "nudge text: $(cat "$TMP/panes/nudges.log")"
[ "$(kinds s3)" = "nudged " ] && ok "the nudge is logged as an informational 'nudged' row, never idle" || no "rows: $(kinds s3)"
r="$(obs s3 $((N0 + 420)))"
[ "$(nudges s3)" = 1 ] && case "$r" in none*) true ;; *) false ;; esac && ok "one autonudge per stall: a later read inside the window sends nothing and wakes nobody" || no "second read: nudges=$(nudges s3) r=$r"
r="$(obs s3 $((N0 + 610)))"
case "$r" in "stalled|still stalled 5m after one autonudge: idle"*"background shell"*) ok "still stalled one window after the nudge: EVENT stalled to the orchestrator" ;; *) no "escalation: $r" ;; esac
[ -f "$OSRC_HOME/lanes/needs/s3" ] && ok "the escalation is a Mission Control needs-you row" || no "no needs row"
case "$(kinds s3)" in *idle*) no "an idle event was logged for a lane waiting on its shell: $(kinds s3)" ;; *) ok "no idle event at any point (rows: $(kinds s3))" ;; esac
r="$(obs s3 $((N0 + 700)))"; [ "$(kinds s3)" = "nudged stalled " ] && ok "the escalation is logged once, not every poll" || no "rows after repeat: $(kinds s3)"
r="$(obs s3 $((N0 + 610 + 301)))"
case "$(jq -r 'select(.target=="s3" and .kind=="stalled") | .detail' "$OSRC_HOME/lanes/events.jsonl" | tail -1)" in
  "still unresolved, waiting 5m: still stalled"*) ok "re-reported 5 min later with its age" ;; *) no "reminder: $(kinds s3)" ;; esac
# supervise delivers the escalation (and never wakes for the nudged row on its own)
fresh 1b; own S s3; pane s3 cc-idle-bgshell-footer-only.txt
obs s3 "$N0" >/dev/null; obs s3 $((N0 + 301)) >/dev/null
out="$(OSRC_SUPERVISE_MAX_SECS=2 sup --session S)"
grep -q '^EVENT nudged ' <<<"$out" && no "a nudged row woke the orchestrator: [$out]" || ok "supervise does not wake for the autonudge alone"
printf '%s bgshell sent 0 1\n' $((N0 - 400)) > "$OSRC_HOME/lanes/state/s3.nudge"   # fake clock: the nudge was 6+ min ago
read -r h c rest < "$OSRC_HOME/lanes/state/s3"; echo "$h $((N0 - 700)) $rest" > "$OSRC_HOME/lanes/state/s3"
out="$(sup --session S)"
grep -q '^EVENT stalled s3 .*after one autonudge' <<<"$out" && grep -q '^NEXT OUTSOURCERER_TMUX=s3 .* session read' <<<"$out" \
  && ok "supervise delivers EVENT stalled + NEXT after the nudge failed to move it" || no "supervise: [$out]"
# the real summary line variant (the shell count in `✻ Baked for ... · 1 shell still running`) too
fresh 1c; pane s3b cc-idle-bgshell-footer.txt
[ "$(lib _sv_target_screen s3b | head -1)" = working ] && ok "summary '· 1 shell still running' still reads as waiting on its shell" || no "summary variant"

echo "=== incident 1b: idle after promising to continue later, nothing running ==="
fresh 2; own S p2; pane p2 cc-idle-promise-noshell.txt
r="$(obs p2 "$N0")"; r="$(obs p2 "$N0")"
[ "$(nudges p2)" = 1 ] && ok "a promise ('after it reports I continue') with no shell: nudged at once" || no "promise: nudges=$(nudges p2) r=$r rows=$(kinds p2)"
grep -q 'after promising to continue later' "$OSRC_HOME/lanes/events.jsonl" && ok "the nudged row names the promise" || no "detail: $(cat "$OSRC_HOME/lanes/events.jsonl")"
fresh 2b; own S p2; pane p2 cc-idle-promise-noshell.txt
r="$(OSRC_AUTONUDGE=0 obs p2 "$N0")"; r="$(OSRC_AUTONUDGE=0 obs p2 "$N0")"
case "$r" in "stalled|idle after promising"*"|OUTSOURCERER_TMUX=p2 "*"session send "*) ok "OSRC_AUTONUDGE=0: EVENT stalled at once, NEXT is the nudge command" ;; *) no "autonudge off: $r" ;; esac
[ "$(nudges p2)" = 0 ] && ok "OSRC_AUTONUDGE=0 sends nothing itself" || no "sent with autonudge off"

echo "=== incident 2: an approval keystroke that did not land ==="
fresh 3; own S a3; pane a3 codex-approval.ansi
out="$(OUTSOURCERER_TMUX=a3 perl -e 'alarm 30; exec @ARGV' "$SRC" session answer 1 2>"$TMP/err")"; rc=$?
grep -q '^EVENT approval-not-landed a3 ' <<<"$out" && grep -q '^NEXT OUTSOURCERER_TMUX=a3 .* session answer' <<<"$out" \
  && ok "session answer re-reads the pane; the prompt survived the keystroke: EVENT approval-not-landed (rc $rc)" || no "answer: rc=$rc [$out] $(cat "$TMP/err")"
[ "$(kinds a3)" = "approval-not-landed " ] && jq -e 'select(.target=="a3") | .owner == "S"' "$OSRC_HOME/lanes/events.jsonl" >/dev/null \
  && ok "logged once for the owning orchestrator, so supervise delivers it" || no "rows: $(kinds a3)"
[ ! -f "$OSRC_HOME/lanes/state/a3.keysent" ] && ok "the answering command reported it; supervise will not report the same miss again" || no "keysent left"
# A keystroke sent by anyone else (noted, not verified): supervise sees the same prompt seconds later.
fresh 3b; own S a3; pane a3 codex-approval.ansi
lib osrc_keys_sent a3 "hub button"
f="$OSRC_HOME/lanes/state/a3.keysent"; ts=0; h=""; who=""; [ -f "$f" ] && IFS="$(printf '\t')" read -r ts h who < "$f"; printf '%s\t%s\t%s\n' $((ts - 8)) "$h" "$who" > "$f"
r="$(obs a3 "$ts")"
case "$r" in "approval-not-landed|an answer was sent "*"(hub button) but the same prompt is still open: retry it"*"|OUTSOURCERER_TMUX=a3 "*"session answer") ok "supervise: same prompt 8 s after an answer: approval-not-landed, NEXT session answer" ;; *) no "supervise not-landed: $r" ;; esac
lib osrc_keys_sent a3 "hub button"; cp "$FX/cc-working-turn.txt" "$TMP/panes/a3.screen"
ts=0; h=""; who=""; [ -f "$f" ] && IFS="$(printf '\t')" read -r ts h who < "$f"; printf '%s\t%s\t%s\n' $((ts - 8)) "$h" "$who" > "$f"
r="$(obs a3 "$ts")"; case "$r" in approval-not-landed*) no "landed answer reported as not landed" ;; *) ok "the prompt closed after the keystroke: no not-landed" ;; esac

echo "=== incident 3: idle alerts that are not idle, and the stuck lane they hid ==="
fresh 4; own S b4; pane b4 cc-idle-bgshell-footer.txt
r1="$(obs b4 "$N0")"; r2="$(obs b4 $((N0 + 30)))"
case "$r1$r2" in *idle*) no "a lane waiting on its shell raised idle: $r1 / $r2" ;; *) ok "waiting on its own shell is never an idle alert" ;; esac
fresh 4b; own S q4; pane q4 cc-idle-plain-2026-11-17.txt
r="$(obs q4 "$N0")"; r="$(obs q4 "$N0")"
case "$r" in idle*) ok "a plain idle with no hand-in: one idle event" ;; *) no "plain idle: $r" ;; esac
r="$(obs q4 $((N0 + 301)))"
[ "$(nudges q4)" = 1 ] && grep -q 'write its hand-in now' "$TMP/panes/nudges.log" && ok "unchanged 5 min: nudged once (no hand-in text, not the background-task text)" || no "quiet nudge: $(nudges q4) $r"
r="$(obs q4 $((N0 + 602)))"
case "$r" in "stalled|still stalled"*) ok "still idle a window later: escalates as stalled, a kind the orchestrator has not learned to skip" ;; *) no "quiet escalation: $r" ;; esac
[ "$(kinds q4)" = "idle nudged stalled " ] && ok "rows: idle, nudged, stalled (no idle repeats in between)" || no "rows: $(kinds q4)"

echo "=== incident 4: READY lanes waiting for review ==="
fresh 5; mkdir -p "$OSRC_HOME/review/items"; own S r5
jq -cn --argjson t $((N0 - 16 * 60)) '{id:"r5-abcdef0", lane:"r5", head:"abcdef0123", state:"queued", enq_ts:$t, stale:false, acked:false}' > "$OSRC_HOME/review/items/r5-abcdef0.json"
jq -cn '{session:"rv"}' > "$OSRC_HOME/review/reviewer.json"
ev="$(OSRC_NOW="$N0" lib osrc_review_events 2>/dev/null)"
grep -q '^EVENT unreviewed r5 .*queued 16m with no review started' <<<"$ev" && ok "READY 16 min with no review: EVENT unreviewed (reminds at 15, not 20)" || no "unreviewed: [$ev]"
p="$(lib osrc_mc_alerts S '{"id":"S"}')"
jq -e '.alerts[0] | .kind == "unreviewed" and .lane == "r5" and .since > 0' <<<"$p" >/dev/null && ok "Mission Control: needs-you row with the time it was queued (the page shows its age)" || no "mc alerts: $p"

echo "=== incident 5: a watcher that went away ==="
fresh 6; own S w6; pane w6 cc-working-turn.txt
old="$(date -r $((N0 - 300)) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$((N0 - 300)) +%Y%m%d%H%M.%S)"
touch -t "$old" "$OSRC_HOME/owners/S/w6"; printf '%s\n' $((N0 - 240)) > "$OSRC_HOME/supervise/S/alive"   # last supervise poll 4 min ago
err="$(CLAUDE_CODE_SESSION_ID=S OUTSOURCERER_TMUX=w6 perl -e 'alarm 30; exec @ARGV' "$SRC" session read 2>&1 >/dev/null)"
grep -q '^\[outsourcerer\] no watcher for 4m: 1 live lane(s) owned by this session and no supervise armed' <<<"$err" \
  && ok "the next engine call warns: no watcher for 4m, with the supervise command" || no "warning: [$err]"
p="$(lib osrc_mc_alerts S '{"id":"S"}')"
jq -e '.watcher.missingMin == 4 and .watcher.liveLanes == 1' <<<"$p" >/dev/null && ok "Mission Control: no watcher for 4 min" || no "mc watcher: $p"
printf '%s\n' "$(date +%s)" > "$OSRC_HOME/supervise/S/alive"
err="$(CLAUDE_CODE_SESSION_ID=S OUTSOURCERER_TMUX=w6 perl -e 'alarm 30; exec @ARGV' "$SRC" session read 2>&1 >/dev/null)"
grep -q 'no watcher' <<<"$err" && no "warned although a supervise just polled: [$err]" || ok "a supervise polled within 2 min: no warning"
out="$(T=4 OSRC_SUPERVISE_MAX_SECS=2 sup --session S)"
a="$(cat "$OSRC_HOME/supervise/S/alive" 2>/dev/null)"; [ "$(( $(date +%s) - ${a:-0} ))" -le 10 ] && ok "a running supervise stamps its liveness every poll" || no "alive stamp: $a"

echo "=== edges ==="
fresh 7; own S k7; pane k7 cc-working-bgshell-footer.txt
obs k7 "$N0" >/dev/null; r="$(obs k7 $((N0 + 6 * 60)))"
case "$r" in stalled*) no "a working lane (spinner) was called stalled after 6 min: $r" ;; *) ok "a working lane is never stalled inside its 15 min working window, shells or not" ;; esac
[ "$(nudges k7)" = 0 ] && ok "a working lane is never nudged" || no "working lane nudged"
fresh 8; own S q8; pane q8 cc-question-live.txt
r="$(obs q8 "$N0")"; r="$(obs q8 "$N0")"
case "$r" in question*) ok "a lane at a question: question event on first sight" ;; *) no "question: $r" ;; esac
obs q8 $((N0 + 30 * 60)) >/dev/null
[ "$(nudges q8)" = 0 ] && ok "a lane at a question is never autonudged (30 min later)" || no "question nudged"
grep -q '"kind":"question".*still unresolved, waiting 30m' "$OSRC_HOME/lanes/events.jsonl" && ok "an unanswered question repeats with its age ('waiting 30m')" || no "question reminder: $(kinds q8)"
fresh 9; own S ap9; pane ap9 codex-approval.ansi
obs ap9 "$N0" >/dev/null; obs ap9 $((N0 + 200)) >/dev/null
[ "$(kinds ap9)" = "approval " ] && ok "an open approval is not repeated inside 5 min" || no "approval early repeat: $(kinds ap9)"
obs ap9 $((N0 + 301)) >/dev/null
[ "$(nudges ap9)" = 0 ] && [ "$(kinds ap9)" = "approval approval " ] && grep -q 'still unresolved, waiting 5m: approval prompt open' "$OSRC_HOME/lanes/events.jsonl" \
  && ok "an open approval repeats every 5 min with its age and is never nudged" || no "approval: rows=$(kinds ap9) nudges=$(nudges ap9)"
fresh 10; own S d10; pane d10 cc-idle-bgshell-footer-only.txt
OSRC_NUDGE_SEND_CMD=false obs d10 "$N0" >/dev/null; r="$(OSRC_NUDGE_SEND_CMD=false obs d10 $((N0 + 301)))"
case "$r" in "stalled|"*"(the autonudge could not be sent)|OUTSOURCERER_TMUX=d10 "*) ok "a nudge that cannot be sent wakes the orchestrator at once, with the nudge as NEXT" ;; *) no "failed nudge: $r" ;; esac
fresh 11; own S rv; pane rv cc-idle-plain-2026-11-17.txt; mkdir -p "$OSRC_HOME/review"; jq -cn '{session:"rv"}' > "$OSRC_HOME/review/reviewer.json"
obs rv "$N0" >/dev/null; obs rv "$N0" >/dev/null; obs rv $((N0 + 601)) >/dev/null
[ "$(nudges rv)" = 0 ] && ok "the queue's reviewer, idle between items by design, is not nudged for being quiet" || no "reviewer nudged"

echo "=== round 2 ==="
# A message waiting on a person is idle for a person: the normal idle event, never a nudge.
mkp() { sed "s/^⏺ The mutation run.*/⏺ $2/" "$FX/cc-idle-promise-noshell.txt" > "$TMP/panes/$1.screen"; }
fresh 21; own S g21; mkp g21 "I'll continue with phase 2 when you give the go-ahead."
r="$(obs g21 "$N0")"; r="$(obs g21 "$N0")"
case "$r" in idle*) ok "'I'll continue ... when you give the go-ahead': the normal idle event" ;; *) no "go-ahead: $r" ;; esac
obs g21 $((N0 + 700)) >/dev/null
[ "$(nudges g21)" = 0 ] && [ "$(kinds g21)" = "idle idle " ] && ok "waiting on a person is never nudged or called stalled (11 min later: only idle reminders)" || no "person-wait: nudges=$(nudges g21) rows=$(kinds g21)"
fresh 22; own S g22; mkp g22 "Once the reviewer finishes I continue with round 2."
r="$(obs g22 "$N0")"; r="$(obs g22 "$N0")"
[ "$(nudges g22)" = 0 ] && case "$r" in idle*) true ;; *) false ;; esac && ok "'once the reviewer finishes': a person, so idle, not a promise" || no "reviewer-wait: $r nudges=$(nudges g22)"
fresh 23; own S g23; mkp g23 "I'll continue with phase 2."
r="$(obs g23 "$N0")"; r="$(obs g23 "$N0")"
[ "$(nudges g23)" = 0 ] && case "$r" in idle*) true ;; *) false ;; esac && ok "a bare 'I'll continue' is no promise: idle first, not an instant nudge" || no "bare continue: $r nudges=$(nudges g23)"

# session answer: the answer landed and a DIFFERENT prompt opened -> no approval-not-landed.
fresh 24; own S a24; pane a24 codex-approval.ansi; cp "$SCRIPT_DIR/fixtures/screen/cx-approval.ansi" "$TMP/panes/a24.next"
cmp -s "$TMP/panes/a24.screen" "$TMP/panes/a24.next" && no "fixture: the two prompts must differ"
out="$(OUTSOURCERER_TMUX=a24 perl -e 'alarm 30; exec @ARGV' "$SRC" session answer 1 2>"$TMP/err")"
grep -q 'approval-not-landed' <<<"$out" && no "a landed answer followed by a new prompt reported as not landed: [$out]" || ok "answer landed, a different prompt opened: no approval-not-landed"
[ "$(kinds a24)" = "" ] && ok "nothing logged for it" || no "rows: $(kinds a24)"

# supervise: after an approval-not-landed, the open prompt is not logged again at once, and its age runs
# from when the prompt was first seen.
fresh 25; own S a25; pane a25 codex-approval.ansi
obs a25 $((N0 - 600)) >/dev/null
lib osrc_keys_sent a25 "hub button"; f="$OSRC_HOME/lanes/state/a25.keysent"
ts=0; h=""; who=""; [ -f "$f" ] && IFS="$(printf '\t')" read -r ts h who < "$f"; printf '%s\t%s\t%s\n' $((ts - 8)) "$h" "$who" > "$f"
obs a25 "$ts" >/dev/null; obs a25 $((ts + 10)) >/dev/null
[ "$(kinds a25)" = "approval approval-not-landed " ] && ok "after approval-not-landed the same prompt is not re-logged as a new approval" || no "rows: $(kinds a25)"
obs a25 $((ts + 301)) >/dev/null
d="$(jq -r 'select(.target=="a25" and .kind=="approval") | .detail' "$OSRC_HOME/lanes/events.jsonl" | tail -1)"
case "$d" in "still unresolved, waiting 1"[0-9]"m: "*) ok "the reminder keeps the original age ($d)" ;; *) no "age after not-landed: $d / rows $(kinds a25)" ;; esac

# A long foreground tool (spinner, screen still): one stalled at 15 min, then every 15, not every 5.
fresh 26; own S f26; pane f26 cc-working-bgshell-footer.txt
obs f26 "$N0" >/dev/null; obs f26 $((N0 + 901)) >/dev/null; obs f26 $((N0 + 901 + 301)) >/dev/null
[ "$(kinds f26)" = "stalled " ] && ok "a foreground run still at 15 min: one stalled, no 5-min repeat" || no "rows: $(kinds f26)"
obs f26 $((N0 + 901 + 901)) >/dev/null
[ "$(kinds f26)" = "stalled stalled " ] && ok "repeated after another 15 min" || no "rows: $(kinds f26)"

# A nudge the lane obeyed (it worked after it) and a new stall: a fresh nudge, not an escalation.
fresh 27; own S n27; pane n27 cc-idle-bgshell-footer-only.txt
obs n27 "$N0" >/dev/null; obs n27 $((N0 + 301)) >/dev/null
pane n27 cc-working-bgshell-footer.txt; obs n27 $((N0 + 320)) >/dev/null
pane n27 cc-idle-bgshell-footer-only.txt; obs n27 $((N0 + 340)) >/dev/null; r="$(obs n27 $((N0 + 341 + 301)))"
[ "$(nudges n27)" = 2 ] && case "$r" in stalled*) false ;; *) true ;; esac && ok "worked after its nudge, stalled again: a fresh nudge (2), no escalation" || no "obeyed: nudges=$(nudges n27) r=$r rows=$(kinds n27)"
t=$((N0 + 341 + 301))   # nudge 2; each later cycle: works 20 s after its nudge, stalls again 5 min on
for k in 1 2; do pane n27 cc-working-bgshell-footer.txt; obs n27 $((t + 20)) >/dev/null
  pane n27 cc-idle-bgshell-footer-only.txt; obs n27 $((t + 40)) >/dev/null; t=$((t + 41 + 301)); r="$(obs n27 "$t")"; done
case "$r" in "stalled|"*"stalled again after 3 autonudges"*) ok "after OSRC_NUDGE_MAX (3) nudges a new stall escalates at once" ;; *) no "cap: nudges=$(nudges n27) r=$r" ;; esac
# A nudge that could not be sent never reads as "after one autonudge".
fresh 28; own S x28; pane x28 cc-idle-bgshell-footer-only.txt
OSRC_NUDGE_SEND_CMD=false obs x28 "$N0" >/dev/null; OSRC_NUDGE_SEND_CMD=false obs x28 $((N0 + 301)) >/dev/null
r="$(OSRC_NUDGE_SEND_CMD=false obs x28 $((N0 + 602)))"
case "$r" in *"after one autonudge"*) no "claims a nudge that was not sent: $r" ;; "stalled|still stalled"*"the autonudge could not be sent"*) ok "escalation after a failed nudge says it was not sent" ;; *) no "failed-nudge escalation: $r" ;; esac

echo "=== lib loads through a symlinked engine (LOADER.md) ==="
ln -s "$SRC" "$TMP/osrc-link.sh"
got="$( ( OSRC_SOURCED=1; . "$TMP/osrc-link.sh" >/dev/null 2>&1; type _sv_stall_observe osrc_mc_auto_open >/dev/null 2>&1 && echo yes ) )"
[ "$got" = yes ] && ok "stall.sh and mc_alive.sh load through a symlink to outsourcerer.sh" || no "symlink load"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
