#!/usr/bin/env bash
# sealed-run-requires: process-inspection
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_sandbox.sh" || { echo "FAIL: sandbox library" >&2; exit 1; }
osrc_test_sandbox || { echo "FAIL: sandbox" >&2; exit 1; }
# test_supervise_lifecycle.sh — SUP (0.16.2): three supervise / stop-guard bugs seen live 2026-11-15.
#  1. A Claude lane that ended its turn with its own background shell still running ("1 shell still
#     running"), or any idle lane short of its done contract, was "settled": EVENT done all.
#  2. A lane its owner ended (session stop / tmux kill after handing in) read as
#     "EVENT failed ... session is gone (pane dead, no stop recorded)".
#  3. The stop guard counted any ps line mentioning `outsourcerer.sh wait <id>` (echo, comment) as a
#     waiter, while every real command shape (env prefix, cd x &&, full path, | tail -N) must count.
# Panes are real Claude Code 2.1.325 captures (fixtures/supervise/cc-idle-bg-shell.txt,
# cc-bg-shell-finished-working.txt) served by a file-backed fake tmux. No real tmux server is used.
# OSRC_TEST_SRC=<scripts dir> runs this suite against another checkout (the red run on base).
# Run: nice -n 19 bash test_supervise_lifecycle.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SD="${OSRC_TEST_SRC:-$HERE/..}"; SRC="$SD/outsourcerer.sh"; FX="$HERE/fixtures/supervise"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-sv-life.XXXXXX")" || { echo "FAIL: no scratch dir" >&2; exit 1; }; PIDS=""
trap 'for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; rm -rf "$TMP" 2>/dev/null || { sleep 2; rm -rf "$TMP"; }; rm -rf "$OSRC_TEST_ROOT" 2>/dev/null' EXIT
mkdir -p "$TMP/bin" "$TMP/panes"
# fake tmux: tmux-files plus a kill-session that records whether the registry already held the stop.
cat > "$TMP/bin/tmux" <<'EOF'
#!/bin/bash
D="${FAKE_TMUX_DIR:?}"; cmd="$1"; shift; t=""
while [ "$#" -gt 0 ]; do case "$1" in -t) t="$2"; shift 2 ;; *) shift ;; esac; done
t="${t#=}"; t="${t%%:*}"
case "$cmd" in
  has-session) [ -f "$D/$t.screen" ] ;;
  capture-pane) [ -f "$D/$t.screen" ] && cat "$D/$t.screen" ;;
  send-keys) echo "send-keys $t" >> "$D/keys.log" ;;
  kill-session) [ -f "$D/$t.screen" ] || exit 1
    if grep -F "\"$t\"" "$OSRC_HOME/sessions/registry.jsonl" 2>/dev/null | tail -1 | grep -q '"event":"end"'; then echo "kill $t: stop already recorded" >> "$D/kill.log"
    else echo "kill $t: no stop recorded yet" >> "$D/kill.log"; fi
    rm -f "$D/$t.screen" ;;
  list-panes|display-message|display) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/tmux"
export PATH="$TMP/bin:$PATH" FAKE_TMUX_DIR="$TMP/panes" OSRC_HEARTBEAT_DISABLED=1 OSRC_BLIND_TURN_GUARD=0 OSRC_STREAM=1
export OSRC_CLAUDE_PROJECTS_DIR="$TMP/projects" OSRC_CLAUDE_SESSIONS_DIR="$TMP/ccsessions" HOME="$TMP/home"
mkdir -p "$HOME"
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID OSRC_SESSION_REGISTRY
export OSRC_SUPERVISE_POLL=1 OSRC_SUPERVISE_CONFIRM=0 OSRC_SUPERVISE_SETTLE=0
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
# The hub/limits refresh tick (~6 s a run) is not under test here: stamp it fresh so it is skipped.
fresh() { export OSRC_HOME="$TMP/h$1"; mkdir -p "$OSRC_HOME/jobs" "$OSRC_HOME/sessions"; rm -f "$TMP/panes"/*
  for s in S W; do mkdir -p "$OSRC_HOME/supervise/$s"; date +%s > "$OSRC_HOME/supervise/$s/tick.time"; done; }
export OSRC_SUPERVISE_TICK_SECS=86400
own() { mkdir -p "$OSRC_HOME/owners/$1"; : > "$OSRC_HOME/owners/$1/$2"; }
pane() { cp "$FX/$2" "$TMP/panes/$1.screen"; }
sup() { perl -e 'alarm shift; exec @ARGV' "${T:-20}" "$SRC" supervise "$@" 2>"$TMP/err"; }
guard() { printf '{"session_id":"%s"}' "$1" | "$SRC" stop-guard 2>/dev/null; }
reg() { # <session> <event> [receipt] [ts]
  jq -cn --arg id "$1" --arg ev "$2" --arg r "${3:-}" --arg ts "${4:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
    '{event:$ev,session_id:$id,provider:"cc",model:"haiku",resolved_model:"haiku",model_generation:1,effort:"",receipt:$r,ts:$ts}' >> "$OSRC_HOME/sessions/registry.jsonl"; }
screen_of() { ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _sv_target_screen "$1" ) 2>/dev/null; }
iso_ago() { date -u -r $(( $(date +%s) - $1 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }

echo "=== 1. idle-but-waiting: a running background shell is live work ==="
fresh 1; pane b1 cc-idle-bg-shell.txt
out="$(screen_of b1)"
[ "$(head -1 <<<"$out")" = working ] && grep -q 'background shell still running: .*1 shell still running' <<<"$out" \
  && ok "real capture '✻ Crunched for 44s · done 11:45 PM · 1 shell still running' -> working" || no "bg-shell capture: [$out]"
# Footer alone (the turn summary scrolled off): still a running shell.
grep -v 'shell still running' "$FX/cc-idle-bg-shell.txt" > "$TMP/panes/b2.screen"
out="$(screen_of b2)"; [ "$(head -1 <<<"$out")" = working ] && grep -q 'status bar: .*1 shell' <<<"$out" \
  && ok "footer '⏵⏵ auto mode on · 1 shell' alone -> working" || no "footer-only: [$out]"
pane b3 cc-bg-shell-finished-working.txt
out="$(screen_of b3)"; [ "$(head -1 <<<"$out")" = working ] && ! grep -q 'background shell' <<<"$out" \
  && ok "real capture after the shell ended (new turn running) -> plain working" || no "after-shell: [$out]"
# Look-alikes: the lane's own prose, and text typed into the composer, never count.
sed 's/^⏺ ok$/⏺ Note: 1 shell still running · 2 shells/' "$FX/cc-idle-after-work.txt" > "$TMP/panes/b4.screen"
out="$(screen_of b4)"; [ "$(head -1 <<<"$out")" = idle ] && ok "lane prose '1 shell still running · 2 shells' -> still idle (not chrome)" || no "prose look-alike: [$out]"
sed -E 's/^([[:space:]]*)⏵⏵ auto mode on · 1 shell$/\1⏵⏵ auto mode on (shift+tab to cycle)/; s/^✻ Crunched for 44s · done 11:45 PM · 1 shell still running$/✻ Crunched for 44s · done 11:45 PM/' "$FX/cc-idle-bg-shell.txt" > "$TMP/panes/b5.screen"
out="$(screen_of b5)"; [ "$(head -1 <<<"$out")" = idle ] && ok "same frame without the shell markers -> idle (control)" || no "control: [$out]"

fresh 2; own S b1; pane b1 cc-idle-bg-shell.txt
out="$(OSRC_SUPERVISE_MAX_SECS=4 T=20 sup --session S)"
! grep -q '^EVENT done all' <<<"$out" && grep -q '^EVENT stalled supervise .*live work' <<<"$out" \
  && ok "supervise keeps watching a lane whose shell still runs (no 'done all')" || no "bg-shell lane settled: [$out]"
[ "$(grep -c '"kind":"idle"' "$OSRC_HOME/lanes/events.jsonl" 2>/dev/null || echo 0)" = 0 ] && ok "no idle event while the shell runs" || no "idle logged for a running shell"
( sleep 2; cp "$FX/cc-idle-after-work.txt" "$TMP/panes/b1.screen" ) & PIDS="$PIDS $!"
out="$(T=20 sup --session S)"; grep -q '^EVENT idle b1 ' <<<"$out" && ok "...and wakes on its next real change (turn ended, no shell)" || no "no wake on change: [$out]"
out="$(guard S)"; grep -q '"decision":"block"' <<<"$out" && ok "stop guard: an idle lane short of done is owed a waiter" || no "guard let an idle-not-done lane go: [$out]"

echo "=== 1b. idle short of done stays live after its idle event; done contract settles it ==="
fresh 3; own S i1; pane i1 cc-idle-after-work.txt; reg i1 start
out="$(T=20 sup --session S)"; grep -q '^EVENT idle i1 ' <<<"$out" && ok "first arm: EVENT idle" || no "idle: [$out]"
out="$(OSRC_SUPERVISE_MAX_SECS=4 T=20 sup --session S)"
! grep -q '^EVENT done all' <<<"$out" && ok "re-armed after the idle event: still watching, not 'done all' (live bug: osrc-auto-MC3)" || no "idle lane settled on re-arm: [$out]"
mkdir -p "$OSRC_HOME/done" "$TMP/w3"; : > "$TMP/w3/i1.DONE"
jq -cn --arg p "$TMP/w3/i1.DONE" --arg c "$TMP/w3" '{spec:("file:"+$p),cwd:$c}' > "$OSRC_HOME/done/i1.json"
out="$(T=20 sup --session S)"; grep -q '^EVENT done i1 ' <<<"$out" && ok "done contract holds -> EVENT done" || no "done contract: [$out]"
out="$(guard S)"; [ -z "$out" ] && ok "stop guard: a lane whose done contract holds is settled" || no "guard blocked a done lane: [$out]"
fresh 4; own S f1; pane f1 cc-idle-boot.txt
out="$(guard S)"; [ -z "$out" ] && ok "stop guard: a fresh never-prompted session is not owed a waiter" || no "guard blocked a fresh session: [$out]"

echo "=== 2. a lane its owner ended is stopped or done, never failed; crashes stay failed ==="
fresh 5; own S s1; pane s1 cc-idle-after-work.txt; reg s1 start
OUTSOURCERER_TMUX=s1 "$SRC" session stop >"$TMP/stop.out" 2>&1
grep -q 'kill s1: stop already recorded' "$TMP/panes/kill.log" 2>/dev/null && ok "session stop records the stop BEFORE it kills the pane" || no "kill before stop record: [$(cat "$TMP/panes/kill.log" 2>/dev/null)]"
out="$(T=20 sup --session S)"; ! grep -q '^EVENT failed' <<<"$out" && grep -q '^EVENT done all .*stopped: s1' <<<"$out" \
  && ok "session stop -> reads as stopped, no failed event" || no "stopped lane: [$out]"
fresh 6; own S c1; reg c1 start; reg c1 end crash-reap
mkdir -p "$OSRC_HOME/lanes/state"; echo "123 0 - - 0 - 0" > "$OSRC_HOME/lanes/state/c1"
out="$(T=20 sup --session S)"; grep -q '^EVENT failed c1 .*session is gone' <<<"$out" && ok "a beacon crash-reap is a crash -> EVENT failed (was silently dropped)" || no "crash-reap: [$out]"
fresh 7; own S osrc-auto-L7; reg osrc-auto-L7 start "" "$(iso_ago 300)"
mkdir -p "$OSRC_HOME/lanes/state" "$TMP/out7"; echo "123 0 - - 0 - 0" > "$OSRC_HOME/lanes/state/osrc-auto-L7"
( cd "$TMP/out7" && OSRC_SUPERVISE_MAX_SECS=1 T=10 "$SRC" supervise --session W --watch "$TMP/out7" >/dev/null 2>&1 )
: > "$TMP/out7/L7.DONE"
out="$(T=20 sup --session S)"; grep -q '^EVENT done osrc-auto-L7 .*hand-in L7.DONE.*session closed' <<<"$out" && ! grep -q '^EVENT failed osrc-auto-L7' <<<"$out" \
  && ok "tmux-killed after writing out/L7.DONE -> EVENT done" || no "handed-in then killed: [$out]"
fresh 8; own S osrc-auto-L8; reg osrc-auto-L8 start
mkdir -p "$OSRC_HOME/lanes/state" "$TMP/out8"; echo "123 0 - - 0 - 0" > "$OSRC_HOME/lanes/state/osrc-auto-L8"
: > "$TMP/out8/L8.DONE"; touch -t 202601010000 "$TMP/out8/L8.DONE"
( OSRC_SUPERVISE_MAX_SECS=1 T=10 "$SRC" supervise --session W --watch "$TMP/out8" >/dev/null 2>&1 )
out="$(T=20 sup --session S)"; grep -q '^EVENT failed osrc-auto-L8 ' <<<"$out" && ok "a DONE file older than the session's start does not hide a crash" || no "stale DONE: [$out]"
fresh 9; own S d9; pane d9 cc-idle-after-work.txt; reg d9 start
mkdir -p "$OSRC_HOME/done" "$TMP/w9"; : > "$TMP/w9/d9.DONE"
jq -cn --arg p "$TMP/w9/d9.DONE" --arg c "$TMP/w9" '{spec:("file:"+$p),cwd:$c}' > "$OSRC_HOME/done/d9.json"
out="$(T=20 sup --session S)"; grep -q '^EVENT done d9 ' <<<"$out" && ok "lane reported done" || no "d9 done: [$out]"
own S d9; rm -f "$TMP/panes/d9.screen"; rm -f "$OSRC_HOME/done/d9.json"
out="$(T=20 sup --session S)"; ! grep -q '^EVENT failed d9' <<<"$out" && ok "reported done, then the orchestrator ran tmux kill-session -> not failed" || no "done-then-killed: [$out]"
fresh 10; own S x1; pane x1 cc-working-turn.txt; reg x1 start
out="$(OSRC_SUPERVISE_MAX_SECS=3 T=20 sup --session S)"; rm -f "$TMP/panes/x1.screen"
out="$(T=20 sup --session S)"; grep -q '^EVENT failed x1 .*no stop recorded' <<<"$out" && ok "a working lane that vanishes with no stop is still EVENT failed" || no "real crash hidden: [$out]"

echo "=== 3. the stop guard: real waiter shapes count, look-alikes do not ==="
parse() { ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _sg_osrc_args "$1" ) 2>/dev/null; }
for l in "/bin/bash /p/x/outsourcerer.sh wait j1" "bash outsourcerer.sh wait j1" "/opt/x/outsourcerer.sh wait j1" \
         "/bin/bash /Users/a/Library/Mobile Documents/x/outsourcerer.sh wait j1" "/bin/bash -e /p/outsourcerer.sh wait j1"; do
  [ "$(parse "$l" | awk '{print $1, $2}')" = "wait j1" ] && ok "waiter process: $l" || no "missed waiter process: $l -> [$(parse "$l")]"
done
for l in "bash -c echo /p/outsourcerer.sh wait j1" "bash -c sleep 30 # outsourcerer.sh wait j1" \
         "/bin/zsh -c -l source /s && eval 'cd /x && FOO=1 /p/outsourcerer.sh wait j1 | tail -5'" \
         "bash -lc /p/outsourcerer.sh wait j1" "grep outsourcerer.sh wait j1" "vim /p/outsourcerer.sh" \
         "/usr/bin/vim /p/outsourcerer.sh wait j1" "/bin/bash /x/wrap.sh /p/outsourcerer.sh wait j1"; do
  parse "$l" >/dev/null && no "look-alike accepted: $l" || ok "not a waiter: $l"
done
fresh 11; own S w1; pane w1 cc-working-turn.txt
bash -c "echo outsourcerer.sh wait w1 >/dev/null; sleep 30 # $SRC wait w1" & lp=$!; PIDS="$PIDS $lp"; sleep 1
out="$(guard S)"; grep -q '"decision":"block"' <<<"$out" && ok "live look-alike process (echo + comment naming 'outsourcerer.sh wait w1') does not satisfy the guard" || no "look-alike satisfied the guard: [$out]"
kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
for shape in env cd full tail; do
  case $shape in
    env) cmd="FOO=1 OSRC_SUPERVISE_POLL=1 $SRC supervise --session S" ;;
    cd) cmd="cd $TMP && $SRC supervise --session S" ;;
    full) cmd="$SRC supervise --session S" ;;
    tail) cmd="cd $TMP && FOO=1 $SRC supervise --session S 2>&1 | tail -5" ;;
  esac
  perl -e 'alarm 15; exec @ARGV' bash -c "$cmd" >/dev/null 2>&1 & bp=$!; PIDS="$PIDS $bp"; sleep 3
  out="$(guard S)"; [ -z "$out" ] && ok "supervise armed as '$shape' satisfies the guard" || no "supervise '$shape' not seen: [$out]"
  pkill -P "$bp" 2>/dev/null; kill "$bp" 2>/dev/null; wait "$bp" 2>/dev/null
  rm -f "$OSRC_HOME/owners/S/.stop-blocks"
done
perl -e 'alarm 15; exec @ARGV' bash -c "cd $TMP && FOO=1 $SRC wait w1 2>&1 | tail -3" >/dev/null 2>&1 & bp=$!; PIDS="$PIDS $bp"; sleep 2
out="$(guard S)"; [ -z "$out" ] && ok "'cd x && FOO=1 /full/outsourcerer.sh wait w1 | tail -3' satisfies the guard" || no "real wait shape not seen: [$out]"
pkill -P "$bp" 2>/dev/null; kill "$bp" 2>/dev/null; wait "$bp" 2>/dev/null

echo "=== LOADER.md: the new module loads through a symlink ==="
mkdir -p "$TMP/link"; ln -s "$SRC" "$TMP/link/outsourcerer.sh"
got="$( ( OSRC_SOURCED=1; . "$TMP/link/outsourcerer.sh" >/dev/null 2>&1; for f in _sv_bg_shell _sv_observe_gone _sv_idle_owed _sg_osrc_args; do type "$f" >/dev/null 2>&1 && printf '%s ' "$f"; done ) )"
[ "$got" = "_sv_bg_shell _sv_observe_gone _sv_idle_owed _sg_osrc_args " ] && ok "lib/lane_life.sh functions load through a symlinked outsourcerer.sh" || no "symlink load: [$got]"
fresh 12; own S b1; pane b1 cc-idle-bg-shell.txt
out="$(OSRC_SUPERVISE_MAX_SECS=3 perl -e 'alarm 20; exec @ARGV' "$TMP/link/outsourcerer.sh" supervise --session S 2>/dev/null)"
! grep -q '^EVENT done all' <<<"$out" && ok "symlinked supervise sees the running background shell" || no "symlinked supervise: [$out]"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
