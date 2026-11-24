#!/usr/bin/env bash
# test_lane_coord.sh — lanes coordinating without the orchestrator in the middle (lane osrc-l7-coord):
# file leases (lib/lease.sh) and `lane inbox --wait` (lib/lanemsg.sh). Sandboxed: temp HOME and
# OSRC_HOME, stub tmux, no real delegation. Run: nice -n 19 bash test_lane_coord.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "${TMPDIR%/}/.test-lane-coord.XXXXXX")" || { echo "FAIL: no scratch dir" >&2; exit 1; }
TEST_TMP="$TMP"; trap 'jobs -p | xargs kill 2>/dev/null; rm -rf "$TEST_TMP"' EXIT
pass=0; fail=0; ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

for _v in $(env | sed -n 's/^\(CLAUDE_[A-Za-z0-9_]*\|OSRC_[A-Za-z0-9_]*\|TMUX[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$_v"; done
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc" OSRC_MC_AUTO_OPEN=0
mkdir -p "$HOME" "$TMP/bin"
printf '#!/bin/sh\ncase "$1" in has-session) exit "${TMUX_STUB_RC:-1}" ;; esac\nexit 0\n' > "$TMP/bin/tmux"; chmod +x "$TMP/bin/tmux"
export PATH="$TMP/bin:$PATH"
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1 || { echo "FAIL: source"; exit 1; }
mkdir -p "$OSRC_JOBS/laneA" "$OSRC_JOBS/laneB" "$OSRC_HOME/owners/sid-T"
: > "$OSRC_HOME/owners/sid-T/laneA"; : > "$OSRC_HOME/owners/sid-T/laneB"
as() { local who="$1"; shift; ( OSRC_JOB_DIR="$OSRC_JOBS/$who"; "$@" ); }

echo "== lane inbox --wait =="
# 1. A waiter wakes within seconds of a message, and prints it.
start=$(date +%s)
( as laneA osrc_lane_inbox --wait --timeout 20 > "$TMP/w1.out" 2>&1; echo $? > "$TMP/w1.rc" ) &
sleep 1.5
as laneB osrc_lane_msg laneA "ready for review" >/dev/null 2>&1
i=0; while [ ! -f "$TMP/w1.rc" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
took=$(( $(date +%s) - start ))
[ "$(cat "$TMP/w1.rc" 2>/dev/null)" = 0 ] && grep -q 'ready for review' "$TMP/w1.out" && [ "$took" -le 6 ] \
  && ok "waiter woke on the message (${took}s)" || bad "waiter: rc=$(cat "$TMP/w1.rc" 2>/dev/null) took=${took}s out=$(cat "$TMP/w1.out")"
grep -q 'never permission' "$TMP/w1.out" && ok "woken inbox still says messages are data" || bad "data-not-permission header missing"
[ "$(_osrc_lane_unread laneA "" lane)" = 0 ] && ok "woken inbox marks the message read" || bad "message left unread"

# 2. Timeout: a distinct exit code.
as laneA osrc_lane_inbox --wait --timeout 1 >/dev/null 2>&1; rc=$?
[ "$rc" = 124 ] && ok "timeout exits 124" || bad "timeout rc=$rc"

# 3. Two waiters on one lane: one message is delivered once.
for n in 1 2; do ( as laneA osrc_lane_inbox --wait --timeout 6 > "$TMP/r$n.out" 2>/dev/null; echo $? > "$TMP/r$n.rc" ) & done
sleep 1
as laneB osrc_lane_msg laneA "only once" >/dev/null 2>&1
wait
hits="$(cat "$TMP/r1.out" "$TMP/r2.out" | grep -c 'only once')"
rcs="$(cat "$TMP/r1.rc" "$TMP/r2.rc" | sort | tr '\n' ' ')"
[ "$hits" = 1 ] && [ "$rcs" = "0 124 " ] && ok "racing waiters deliver one message once" || bad "race: hits=$hits rcs=$rcs"

# 4. No orphan: the waiter exits once the process that started it is gone (real CLI dispatch).
OSRC_JOB_DIR="$OSRC_JOBS/laneA" sh -c '"$1" lane inbox --wait --timeout 60 >/dev/null 2>&1 & echo $! > "$2"; sleep 1' _ "$SRC" "$TMP/orphan.pid"
opid="$(cat "$TMP/orphan.pid")"; i=0
while kill -0 "$opid" 2>/dev/null && [ "$i" -lt 80 ]; do sleep 0.1; i=$((i + 1)); done
kill -0 "$opid" 2>/dev/null && { bad "waiter outlived its parent"; kill "$opid"; } || ok "waiter exits when its parent is gone"

echo "== file leases =="
R="$TMP/repo"; git init -q "$R"; git -C "$R" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
git -C "$R" worktree add -q "$TMP/wt" -b side 2>/dev/null
cd "$R" || exit 1
as laneA osrc_lease claim src/a.ts >/dev/null 2>&1 && ok "laneA claims src/a.ts" || bad "first claim refused"
err="$(as laneB osrc_lease claim src 2>&1)"; rc=$?
[ "$rc" = 3 ] && case "$err" in *"held by laneA"*until*) true ;; *) false ;; esac \
  && ok "overlapping claim refused with holder and expiry" || bad "conflict: rc=$rc err=$err"
as laneB osrc_lease claim 'src/*.ts' >/dev/null 2>&1; [ $? = 3 ] && ok "glob over a held file refused" || bad "glob conflict not seen"
as laneB osrc_lease claim docs >/dev/null 2>&1 && ok "disjoint claim allowed" || bad "disjoint claim refused"
as laneA osrc_lease claim src/a.ts >/dev/null 2>&1 && ok "holder re-claim renews" || bad "holder re-claim refused"
( cd "$TMP/wt" && as laneB osrc_lease claim src/a.ts >/dev/null 2>&1 ); [ $? = 3 ] \
  && ok "another worktree of the repo sees the lease" || bad "worktree bypassed the lease"
as laneB osrc_lease claim ../outside >/dev/null 2>&1 && bad "path escaping the repo accepted" || ok "path escaping the repo refused"
( as laneA osrc_lease claim tail/flag --ttl >/dev/null 2>&1 ) & tp=$!; i=0
while kill -0 "$tp" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
kill -0 "$tp" 2>/dev/null && { bad "a trailing --ttl hangs"; kill "$tp"; } || ok "a trailing --ttl does not hang"
lst="$(osrc_lease list)"
case "$lst" in *laneA*src/a.ts*) case "$lst" in *laneB*docs*) ok "list shows both leases" ;; *) bad "list: $lst" ;; esac ;; *) bad "list: $lst" ;; esac
as laneB osrc_lease release src/a.ts >/dev/null 2>&1 && bad "non-holder released a lease" || ok "only the holder releases"
as laneA osrc_lease release src/a.ts >/dev/null 2>&1 && as laneB osrc_lease claim src >/dev/null 2>&1 \
  && ok "release frees the path" || bad "release did not free the path"

# Expiry and heartbeat renewal.
REPO="$(_osrc_lease_repo .)"
_osrc_lease_claim deadlane "$REPO" lib/x.sh 1 && sleep 2
_osrc_lease_claim laneA "$REPO" lib/x.sh >/dev/null 2>&1 && ok "a lapsed lease expires on its own" || bad "expired lease still blocks"
sleep 30 & live=$!; printf '%s\n' "$live" > "$OSRC_JOBS/laneB/pid"
dead="$(osrc_test_dead_pid)"; mkdir -p "$OSRC_JOBS/gone"; printf '%s\n' "$dead" > "$OSRC_JOBS/gone/pid"
_osrc_lease_claim laneB "$REPO" app/live.c 3 && _osrc_lease_claim gone "$REPO" app/dead.c 3
sleep 2; _osrc_lease_renew_live; sleep 2
[ -n "$(_osrc_lease_live "$(date +%s)" | jq -r '.[] | select(.path=="app/live.c") | .holder')" ] \
  && ok "heartbeat renews a live holder's lease" || bad "live holder's lease lapsed"
[ -z "$(_osrc_lease_live "$(date +%s)" | jq -r '.[] | select(.path=="app/dead.c") | .holder')" ] \
  && ok "a dead holder's lease runs out" || bad "dead holder's lease was renewed"
kill "$live" 2>/dev/null

# Two lanes claiming one path at the same instant: exactly one wins.
( _osrc_lease_claim racer1 "$REPO" hot/file 2>/dev/null; echo $? > "$TMP/c1" ) &
( _osrc_lease_claim racer2 "$REPO" hot/file 2>/dev/null; echo $? > "$TMP/c2" ) &
wait
[ "$(cat "$TMP/c1" "$TMP/c2" | sort | tr '\n' ' ')" = "0 3 " ] && ok "simultaneous claims: one wins" \
  || bad "simultaneous claims: $(cat "$TMP/c1" "$TMP/c2" | tr '\n' ' ')"

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
