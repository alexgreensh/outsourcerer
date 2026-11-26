#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_rv_watch.sh -- 0.18.0 release-review findings on status, the remote watcher, supervise and
# Mission Control (lane osrc-fx-rv-watch). Each block names the finding it pins.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
LIB="$HERE/../lib"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR%/}/.rvwatch-test.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }
KILL=""
cleanup_all() { local p; for p in $KILL; do kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup_all EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
export OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0
mkdir -p "$HOME" "$XDG_CONFIG_HOME"; : > "$GIT_CONFIG_GLOBAL"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
osrc() {   # osrc <home> <code>: run code with the engine sourced
  OSRC_HOME="$1" OSRC_SOURCED=1 bash -c '. "$0" >/dev/null 2>&1; eval "$1"' "$SRC" "$2" 2>&1
}
home() { mkdir -p "$TMP/$1/jobs" "$TMP/$1/lanes"; printf '%s' "$TMP/$1"; }
lstart() { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g'; }

echo "=== F4: status keeps the progress text of a running job that is not disk-paused ==="
H="$(home f4)"; J=20261126-000000-bbbbbbbbbbbb; jd="$H/jobs/$J"; mkdir -p "$jd"
sleep 300 </dev/null >/dev/null 2>&1 & P=$!; KILL="$KILL $P"
echo running > "$jd/status"; echo "$P" > "$jd/pid"; lstart "$P" > "$jd/pid_start"; date +%s > "$jd/started_at"
printf '{"provider":"devin","model":"example-model","verb":"run"}\n' > "$jd/meta.json"
printf 'reading the parser\n' > "$jd/progress"
o="$(osrc "$H" "_status_line $J")"
grep -q "^$J running .*reading the parser" <<<"$o" && ok "running job shows its progress" || bad "status: $o"

echo "=== F21: a card nag reaches only the session that owns the card ==="
H="$(home f21)"
o="$(osrc "$H" '_sv_append card card "card for project-a is stale" "x hub report" supervise sess-a
  tj="$(_sv_target_set lane-b)"
  printf "B:%s\n" "$(_sv_read_range "$OSRC_HOME/lanes/events.jsonl" 0 - "$tj" sess-b | cut -f3)"
  printf "A:%s\n" "$(_sv_read_range "$OSRC_HOME/lanes/events.jsonl" 0 - "$(_sv_target_set lane-a)" sess-a | cut -f3)"')"
grep -qx 'B:' <<<"$o" && grep -qx 'A:card' <<<"$o" && ok "session B does not get session A's card nag; A does" || bad "card routing: $o"

echo "=== F22: a blocked card names why each lane waits ==="
J='[{"id":"a","short":"disk lane","status":"Blocked","note":"Paused: disk below 5G","state":"limit"},{"id":"b","short":"cap lane","status":"Building","state":"limit"},{"id":"c","short":"q lane","status":"Building","state":"question"}]'
o="$(osrc "$(home f22)" "_osrc_hub_derive '$J' 0")"
[ "$(jq -r .summary <<<"$o")" = "3 lanes: 1 paused (low disk), 1 at a usage limit, 1 waiting for an answer" ] \
  && [ "$(jq -r .next <<<"$o")" = "Unblock disk lane, cap lane, q lane: paused (low disk), at a usage limit, waiting for an answer" ] \
  && ok "disk-paused, limit-parked and question lanes are worded as such" || bad "derived: $o"
o="$(osrc "$(home f22)" "_osrc_hub_derive '[{\"id\":\"c\",\"short\":\"ask\",\"status\":\"Blocked\",\"state\":\"approval\"}]' 0")"
[ "$(jq -r .next <<<"$o")" = "Unblock ask: waiting for approval" ] && ok "an approval prompt still reads as one" || bad "approval: $o"

echo "=== F26: supervise --loop that cannot write its loop marker says so ==="
H="$(home f26)"; mkdir -p "$H/supervise"; : > "$H/supervise/sess-loop"   # a file where the session dir goes
o="$(OSRC_CARD_GUARD=0 CLAUDE_CODE_SESSION_ID=sess-loop perl -e 'alarm 60; exec @ARGV' bash -c 'OSRC_HOME="$1" OSRC_SOURCED=1; . "$0" >/dev/null 2>&1; cmd_supervise --session sess-loop --loop; echo "rc=$?"' "$SRC" "$H" 2>&1)"
grep -q '^EVENT failed supervise .*cannot write the loop marker' <<<"$o" && grep -q '^rc=2' <<<"$o" \
  && ok "EVENT failed supervise, rc 2" || bad "loop marker failure: $o"

echo "=== F27: a slow export keeps its single-flight lock; a follower does not start a second one ==="
H="$(home f27)"
o="$(OSRC_HUB_EXPORT_STALE=2 osrc "$H" 'slow() { echo x >> "$OSRC_HOME/runs"; sleep 6; echo "{\"r\":1}"; }
  _osrc_hub_single_flight k1 slow > "$OSRC_HOME/lead.out" & l=$!
  sleep 1; f="$(_osrc_hub_single_flight k1 slow)"; wait $l
  printf "runs=%s follower=%s leader=%s\n" "$(grep -c x "$OSRC_HOME/runs")" "$f" "$(cat "$OSRC_HOME/lead.out")"')"
[ "$o" = 'runs=1 follower={"r":1} leader={"r":1}' ] && ok "one export ran; the follower printed its result" || bad "single flight: $o"

echo "=== F28: a hub started for the same home spelled differently is ours ==="
mkdir -p "$TMP/f28/real" "$TMP/f28/other"; ln -s "$TMP/f28/real" "$TMP/f28/link"
sleep 300 </dev/null >/dev/null 2>&1 & P=$!; KILL="$KILL $P"
for oh in "$TMP/f28/real/" "$TMP/f28/link"; do
  OSRC_HOME="$oh" OSRC_SOURCED=1 bash -c '. "$0" >/dev/null 2>&1; _osrc_mc_hub_ours "$1" "python3 hub_server.py --osrc-home=$2 --port 1"' "$SRC" "$P" "$TMP/f28/real" \
    && ok "home $oh owns a hub started with --osrc-home=<real>" || bad "home $oh: hub not ours"
done
OSRC_HOME="$TMP/f28/other" OSRC_SOURCED=1 bash -c '. "$0" >/dev/null 2>&1; _osrc_mc_hub_ours "$1" "python3 hub_server.py --osrc-home=$2 --port 1"' "$SRC" "$P" "$TMP/f28/real" \
  && bad "another home claimed the hub" || ok "a different home is still not ours"

echo "=== F29: a hub that is only slow gets a longer second probe before it is stopped ==="
H="$(home f29)"; mkdir -p "$H/hub" "$H/mission-control" "$TMP/f29bin"
printf 'import time\ntime.sleep(300)\n' > "$TMP/f29bin/hub_server.py"
python3 "$TMP/f29bin/hub_server.py" --osrc-home="$H" --port 8799 </dev/null >/dev/null 2>&1 & P=$!; KILL="$KILL $P"
printf '0123456789abcdef0123456789abcdef\n' > "$H/hub/token"
# fake curl: answers 200 only when given a timeout of 5 s or more (a hub slow under load)
printf '#!/bin/sh\nm=0; while [ $# -gt 0 ]; do [ "$1" = -m ] && m=$2; shift; done\n[ "$m" -ge 5 ] && printf 200 || printf 000\n' > "$TMP/f29bin/curl"; chmod +x "$TMP/f29bin/curl"
o="$(PATH="$TMP/f29bin:$PATH" OSRC_HOME="$H" OSRC_SOURCED=1 bash -c '. "$0" >/dev/null 2>&1
  printf "{\"pid\":%s,\"port\":8799}\n" "$1" > "$(_osrc_mc_dir)/serve.json"
  _osrc_mc_stale_hub() { return 1; }   # same code: only liveness is under test
  u="$(_osrc_mc_hub_reuse "")"; echo "rc=$? url=$u"' "$SRC" "$P" 2>&1)"
sleep 0.3
kill -0 "$P" 2>/dev/null && grep -q 'rc=0 url=http://127.0.0.1:8799/?t=0123456789abcdef0123456789abcdef' <<<"$o" \
  && ok "the slow hub is kept and reused" || bad "slow hub: alive=$(kill -0 "$P" 2>/dev/null && echo y || echo n) $o"

echo "=== F30: relaunch keeps the MCP mode the session started with, whatever the relaunching shell says ==="
H="$(home f30)"
sx() { OSRC_HOME="$H" OSRC_SOURCED=1 OSRC_CC_SPAWN_PROBE_TICKS=0 bash -c 'c="$1"; set --; . "$0" >/dev/null 2>&1; eval "$c"' "$SRC" "$1" 2>&1; }
OSRC_CLAUDE_USER_CONFIG=1 sx 'SESSION_NAME=sfull _session_registry_append start cc example-model high started launch example-model 1' >/dev/null
sx 'SESSION_NAME=slean _session_registry_append start cc example-model high started launch example-model 1' >/dev/null
o="$(sx '_osrc_perm_restore_profile sfull; SESSION_NAME=sfull _session_relaunch_cc example-model high ""')"
case "$o" in *claude*) ! grep -q 'strict-mcp-config' <<<"$o" && ok "a session started full relaunches full from a plain shell" || bad "full relaunch: $o" ;; *) bad "full relaunch: $o" ;; esac
o="$(OSRC_CLAUDE_USER_CONFIG=1 sx '_osrc_perm_restore_profile slean; SESSION_NAME=slean _session_relaunch_cc example-model high ""')"
grep -q 'strict-mcp-config' <<<"$o" && ok "a session started lean relaunches lean from a full shell" || bad "lean relaunch: $o"

echo "=== F31: an interactive Claude lane names its MCP mode at start ==="
H="$(home f31)"
o="$(sx 'SESSION_LAUNCH=(); _session_cc_mcp_flags' 2>&1)"
grep -q 'MCP servers: none (lean default).*--with mcp=<names>, or OSRC_SESSION_MCP=full' <<<"$o" && ok "lean default says no servers and how to load them" || bad "lean note: $o"
o="$(OSRC_SESSION_MCP=full sx 'SESSION_LAUNCH=(); _session_cc_mcp_flags' 2>&1)"
grep -q 'MCP servers: full' <<<"$o" && ok "full mode says full" || bad "full note: $o"

# ---- remote watcher (lib/remote.sh): a local bare repo is the remote, the clock is fake --------
RH="$TMP/rstate"; mkdir -p "$RH" "$TMP/rwork"
REMOTE="$TMP/remote.git"; WORK="$TMP/rwork/w"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid GIT_TERMINAL_PROMPT=0
git init -q --bare "$REMOTE"; git clone -q "$REMOTE" "$WORK" 2>/dev/null
( cd "$WORK" && git checkout -q -b main && echo base > f.txt && git add f.txt && git commit -q -m base && git push -q origin main )
# rv <code>: run code in a shell with the engine sourced against the remote-lane home
rv() {
  OSRC_HOME="$RH" OSRC_SOURCED=1 OSRC_TIME_UNIT=1 OSRC_REMOTE_POLL_SECS=0 OSRC_SELF=osrc OSRC_STOP_GUARD=1 \
    OSRC_CARD_GUARD=0 CLAUDE_CODE_SESSION_ID=sess-rv bash -c 'c="$1"; set --; . "$0" >/dev/null 2>&1; eval "$c"' "$SRC" "$1" 2>&1
}
# rpush <branch> <message> <setup-shell> -> commit what setup-shell writes and push it
rpush() {
  ( cd "$WORK" && { git checkout -q "$1" 2>/dev/null || git checkout -q -b "$1" main; } && eval "$3" \
    && git add -A >/dev/null && git commit -q -m "$2" && git push -q origin "$1" 2>/dev/null && git rev-parse HEAD )
}

echo "=== F17: a READY tip whose commit touches 20000 files is still READY ==="
export NOW0=1000000
rv "OSRC_NOW=$NOW0 cmd_lane add big1 --branch cloud/big1 --repo '$REMOTE'" >/dev/null
rpush cloud/big1 "vendor everything" 'mkdir -p zz; i=0; while [ $i -lt 20000 ]; do : > zz/vendored_file_$i.txt; i=$((i+1)); done; echo "READY big1" > big1.READY' >/dev/null
o="$(rv "OSRC_NOW=$((NOW0+60)) osrc_remote_events")"
[ "$(jq -r .head_ready "$RH/remote/big1.json")" = true ] && grep -q '^EVENT done big1 .*READY' <<<"$o" \
  && ok "head_ready=true and a done READY event" || bad "big READY tip missed: ready=$(jq -r .head_ready "$RH/remote/big1.json") events: $o"

echo "=== F23: a quiet lane with a launch session says what is known, and says it again each stall interval ==="
rv "OSRC_NOW=$NOW0 cmd_lane add quiet1 --branch cloud/quiet1 --repo '$REMOTE'" >/dev/null
jq '.session_ref="url:https://example.invalid/session/abc"' "$RH/remote/quiet1.json" > "$TMP/q.json" && mv "$TMP/q.json" "$RH/remote/quiet1.json"
e1="$(rv "OSRC_NOW=$((NOW0+50)) osrc_remote_events" | grep '^EVENT stalled quiet1')"
e2="$(rv "OSRC_NOW=$((NOW0+60)) osrc_remote_events" | grep '^EVENT stalled quiet1')"
e3="$(rv "OSRC_NOW=$((NOW0+145)) osrc_remote_events" | grep '^EVENT stalled quiet1')"
grep -q 'the launch reported session https://example.invalid/session/abc' <<<"$e1" && ! grep -q 'is live' <<<"$e1" \
  && ok "the stalled row says the launch reported a session, not that it is live" || bad "first row: $e1"
[ -z "$e2" ] && [ -n "$e3" ] && ok "no repeat inside the stall interval, a repeat after it" || bad "repeat: e2=[$e2] e3=[$e3]"

echo "=== F24: a lane whose record does not parse says so, once per renotify window ==="
rv "OSRC_NOW=$NOW0 cmd_lane add broken1 --branch cloud/broken1 --repo '$REMOTE'" >/dev/null
printf '{"id":"broken1", not json\n' > "$RH/remote/broken1.json"
e1="$(rv "OSRC_NOW=$((NOW0+200)) osrc_remote_events" | grep '^EVENT failed broken1')"
e2="$(rv "OSRC_NOW=$((NOW0+210)) osrc_remote_events" | grep '^EVENT failed broken1')"
e3="$(rv "OSRC_NOW=$((NOW0+200+15*60)) osrc_remote_events" | grep '^EVENT failed broken1')"
grep -q 'lane record unreadable' <<<"$e1" && [ -z "$e2" ] && [ -n "$e3" ] \
  && ok "one failed event, repeated after the renotify window" || bad "unreadable: e1=[$e1] e2=[$e2] e3=[$e3]"
[ "$(rv 'osrc_remote_state broken1')" = failed ] && ok "osrc_remote_state reports it failed" || bad "state: [$(rv 'osrc_remote_state broken1')]"
rm -f "$RH/remote/broken1.json"

echo "=== F25: READY then a RESULT with a failing rc is failed, not queued for review ==="
rv "OSRC_NOW=$NOW0 cmd_lane add rcfail --branch cloud/rcfail --repo '$REMOTE'" >/dev/null
rv "OSRC_NOW=$NOW0 cmd_lane add rcok --branch cloud/rcok --repo '$REMOTE'" >/dev/null
rpush cloud/rcfail "early marker" 'echo "READY rcfail" > rcfail.READY' >/dev/null
rpush cloud/rcok "early marker" 'echo "READY rcok" > rcok.READY' >/dev/null
rv "OSRC_NOW=$((NOW0+300)) osrc_remote_events" >/dev/null
rpush cloud/rcfail "hand in" 'printf "sha=0000000\nrc=2\nconformance red\n" > rcfail.RESULT' >/dev/null
rpush cloud/rcok "hand in" 'printf "sha=0000000\nrc=0\nall green\n" > rcok.RESULT' >/dev/null
o="$(rv "OSRC_NOW=$((NOW0+400)) osrc_remote_events")"
grep -q '^EVENT failed rcfail .*rcfail.RESULT reports rc=2' <<<"$o" && ! grep -q '^EVENT done rcfail .*queued for review' <<<"$o" \
  && ok "a failing RESULT emits failed, no review queued" || bad "rcfail events: $o"
[ "$(rv 'osrc_remote_state rcfail')" = failed ] && ok "osrc_remote_state rcfail is failed" || bad "state: $(rv 'osrc_remote_state rcfail')"
grep -q '^EVENT done rcok .*queued for review' <<<"$o" && ok "a RESULT with rc=0 is still READY for review" || bad "rcok events: $o"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
