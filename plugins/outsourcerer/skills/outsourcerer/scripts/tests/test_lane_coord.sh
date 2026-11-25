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
i=0; while [ ! -f "$TMP/w1.rc" ] && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
took=$(( $(date +%s) - start ))
[ "$(cat "$TMP/w1.rc" 2>/dev/null)" = 0 ] && grep -q 'ready for review' "$TMP/w1.out" && [ "$took" -le 10 ] \
  && ok "waiter woke on the message (${took}s)" || bad "waiter: rc=$(cat "$TMP/w1.rc" 2>/dev/null) took=${took}s out=$(cat "$TMP/w1.out")"
grep -q 'never permission' "$TMP/w1.out" && ok "woken inbox still says messages are data" || bad "data-not-permission header missing"
[ "$(_osrc_lane_unread laneA "" lane)" = 0 ] && ok "woken inbox marks the message read" || bad "message left unread"

# 2. Timeout: a distinct exit code.
as laneA osrc_lane_inbox --wait --timeout 1 >/dev/null 2>&1; rc=$?
[ "$rc" = 124 ] && ok "timeout exits 124" || bad "timeout rc=$rc"

# 3. Two waiters on one lane: one message is delivered once.
for n in 1 2; do ( as laneA osrc_lane_inbox --wait --timeout 10 > "$TMP/r$n.out" 2>/dev/null; echo $? > "$TMP/r$n.rc" ) & done
sleep 2
as laneB osrc_lane_msg laneA "only once" >/dev/null 2>&1
wait
hits="$(cat "$TMP/r1.out" "$TMP/r2.out" | grep -c 'only once')"
rcs="$(cat "$TMP/r1.rc" "$TMP/r2.rc" | sort | tr '\n' ' ')"
[ "$hits" = 1 ] && [ "$rcs" = "0 124 " ] && ok "racing waiters deliver one message once" || bad "race: hits=$hits rcs=$rcs"

# 4. No orphan: the waiter exits once the process that started it is gone (real CLI dispatch). It
# must be alive while its parent is, or a waiter that died at startup would pass.
OSRC_JOB_DIR="$OSRC_JOBS/laneA" sh -c '"$1" lane inbox --wait --timeout 60 >/dev/null 2>"$3" & echo $! > "$2"; sleep 2; kill -0 $! && echo alive > "$2.alive"' _ "$SRC" "$TMP/orphan.pid" "$TMP/orphan.err"
opid="$(cat "$TMP/orphan.pid")"; i=0
[ -f "$TMP/orphan.pid.alive" ] && ok "waiter is alive while its parent is" || bad "waiter died before its parent: $(cat "$TMP/orphan.err")"
while kill -0 "$opid" 2>/dev/null && [ "$i" -lt 250 ]; do sleep 0.1; i=$((i + 1)); done
kill -0 "$opid" 2>/dev/null && { bad "waiter outlived its parent"; kill "$opid"; } || ok "waiter exits when its parent is gone"
grep -q 'is gone' "$TMP/orphan.err" && ok "parent-gone exit says why (not a silent timeout)" || bad "parent-gone: $(cat "$TMP/orphan.err")"

# 5. A message that lands between reading the bodies and setting the cursor is not acked unseen.
#    A jq wrapper plays the sender, appending right after the drain's first read of the box.
jq() { command jq "$@"; local r=$?
  if [ -f "$TMP/inject" ] && case " $* " in *" --arg box "*) true ;; *) false ;; esac; then
    rm -f "$TMP/inject"; printf '{"id":%s,"from":"laneB","to":"laneA","ts":1,"text":"slipped in"}\n' "$(( $(wc -l < "$(_osrc_msgs_box laneA)") + 100 ))" >> "$(_osrc_msgs_box laneA)"
  fi; return "$r"; }
as laneB osrc_lane_msg laneA "first" >/dev/null 2>&1; : > "$TMP/inject"
as laneA osrc_lane_inbox > "$TMP/d1.out" 2>&1; unset -f jq
as laneA osrc_lane_inbox > "$TMP/d2.out" 2>&1
grep -q first "$TMP/d1.out" && grep -q 'slipped in' "$TMP/d2.out" && ok "a message appended mid-drain stays unread" \
  || bad "mid-drain message lost: first=$(cat "$TMP/d1.out") second=$(cat "$TMP/d2.out")"

# 6. Leading-zero timeout and a garbage sleep knob.
as laneB osrc_lane_msg laneA "zero" >/dev/null 2>&1
as laneA osrc_lane_inbox --wait --timeout 08 > "$TMP/z.out" 2>&1 && grep -q zero "$TMP/z.out" \
  && ok "--timeout 08 is decimal" || bad "--timeout 08: $(cat "$TMP/z.out")"
OSRC_INBOX_WAIT_MAX_SLEEP=junk as laneA osrc_lane_inbox --wait --timeout 3 > /dev/null 2> "$TMP/ms.err"; rc=$?
[ "$rc" = 124 ] && ! grep -q 'sleep' "$TMP/ms.err" && ok "a garbage OSRC_INBOX_WAIT_MAX_SLEEP falls back" || bad "max sleep knob: rc=$rc $(cat "$TMP/ms.err")"

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
_osrc_lease_claim deadlane "$REPO" lib/x.sh
jq -c --argjson u "$(( $(date +%s) - 1 ))" 'map(if .holder == "deadlane" then .until = $u else . end)' "$OSRC_HOME/leases.json" > "$TMP/l.json" && mv "$TMP/l.json" "$OSRC_HOME/leases.json"
_osrc_lease_claim laneA "$REPO" lib/x.sh >/dev/null 2>&1 && ok "a lapsed lease expires on its own" || bad "expired lease still blocks"
sleep 30 & live=$!; printf '%s\n' "$live" > "$OSRC_JOBS/laneB/pid"
dead="$(osrc_test_dead_pid)"; mkdir -p "$OSRC_JOBS/gone"; printf '%s\n' "$dead" > "$OSRC_JOBS/gone/pid"
_osrc_lease_claim laneB "$REPO" app/live.c 600 && _osrc_lease_claim gone "$REPO" app/dead.c 600
soon=$(( $(date +%s) + 30 ))   # both about to lapse; only a renewal can push one past 30 s
jq -c --argjson u "$soon" 'map(.until = $u)' "$OSRC_HOME/leases.json" > "$TMP/l.json" && mv "$TMP/l.json" "$OSRC_HOME/leases.json"
_osrc_lease_renew_live
until_of() { jq -r --arg p "$1" '.[] | select(.path==$p) | .until' "$OSRC_HOME/leases.json"; }
[ "$(until_of app/live.c)" -gt "$soon" ] 2>/dev/null && ok "heartbeat renews a live holder's lease" || bad "live holder's lease not renewed"
[ "$(until_of app/dead.c)" = "$soon" ] && ok "a dead holder's lease is left to run out" || bad "dead holder's lease was renewed"
# A reused pid: alive, but not the process the job recorded. Its lease is not renewed.
sleep 30 & reused=$!; mkdir -p "$OSRC_JOBS/reused"; printf '%s\n' "$reused" > "$OSRC_JOBS/reused/pid"
printf 'Mon Jan  1 00:00:00 2001\n' > "$OSRC_JOBS/reused/pid_start"
_osrc_lease_claim reused "$REPO" app/reused.c 600
jq -c --argjson u "$soon" 'map(.until = $u)' "$OSRC_HOME/leases.json" > "$TMP/l.json" && mv "$TMP/l.json" "$OSRC_HOME/leases.json"
_osrc_lease_renew_live
[ "$(until_of app/reused.c)" = "$soon" ] && ok "a reused pid does not keep a dead job's lease" || bad "reused pid renewed the lease"
kill "$live" "$reused" 2>/dev/null

# A live holder renews its own leases through its own calls, beacon or not (Git Bash has none).
as laneA osrc_lease claim own/file >/dev/null 2>&1
jq -c --argjson u "$soon" 'map(.until = $u)' "$OSRC_HOME/leases.json" > "$TMP/l.json" && mv "$TMP/l.json" "$OSRC_HOME/leases.json"
as laneA osrc_lane_inbox >/dev/null 2>&1
[ "$(until_of own/file)" -gt "$soon" ] 2>/dev/null && ok "lane inbox renews the caller's own leases" || bad "own call did not renew"
# A TTL shorter than two heartbeat beats is raised, so a live lane never lapses between beats.
as laneB osrc_lease claim short/ttl --ttl 1 >/dev/null 2>&1
[ "$(jq -r '.[] | select(.path=="short/ttl") | .until - .ts' "$OSRC_HOME/leases.json")" -ge 660 ] 2>/dev/null \
  && ok "--ttl 1 is raised to the minimum" || bad "short TTL kept: $(jq -c '.[] | select(.path=="short/ttl")' "$OSRC_HOME/leases.json")"
as laneB osrc_lease claim octal/ttl --ttl 08 >/dev/null 2>"$TMP/oct.err" && ok "--ttl 08 is decimal" || bad "--ttl 08: $(cat "$TMP/oct.err")"

# Spellings of one file, a glob against a directory, the repo root, paths outside the repo.
as laneA osrc_lease claim sp/api.c >/dev/null 2>&1
as laneB osrc_lease claim sp//api.c >/dev/null 2>&1; [ $? = 3 ] && ok "sp//api.c and sp/api.c are one file" || bad "// spelling got its own lease"
as laneA osrc_lease claim 'gd/*/index.ts' >/dev/null 2>&1
as laneB osrc_lease claim gd/api >/dev/null 2>&1; [ $? = 3 ] && ok "a directory under a held glob is refused" || bad "glob vs directory disjoint"
as laneA osrc_lease claim gd2/api >/dev/null 2>&1
as laneB osrc_lease claim 'gd2/*/index.ts' >/dev/null 2>&1; [ $? = 3 ] && ok "a glob reaching into a held directory is refused" || bad "directory vs glob disjoint"
as laneB osrc_lease claim 'gd3/ap*' >/dev/null 2>&1 && as laneA osrc_lease claim gd3/a >/dev/null 2>&1 \
  && ok "a glob does not overlap a sibling name it cannot match" || bad "gd3/ap* vs gd3/a refused"
git -C "$R" config core.ignorecase true
as laneA osrc_lease claim Case/File.ts >/dev/null 2>&1
as laneB osrc_lease claim case/file.ts >/dev/null 2>&1; [ $? = 3 ] && ok "case spellings collide where git says case-insensitive" || bad "case spelling got its own lease"
git -C "$R" config core.ignorecase false
as laneB osrc_lease claim C:/x/y >/dev/null 2>&1 && bad "a drive path was stored as relative" || ok "a drive path outside the repo is refused"
ln -s "$R" "$TMP/link"
as laneB osrc_lease claim "$TMP/link/sp/api.c" >/dev/null 2>&1; [ $? = 3 ] && ok "an absolute path through a symlink resolves into the repo" || bad "symlinked absolute path not resolved"
mkdir -p "$TMP/solo"; git init -q "$TMP/solo"
( cd "$TMP/solo" && as laneA osrc_lease claim . >/dev/null 2>&1 ) && ok "the repo root can be leased" || bad "lease claim . refused"
( cd "$TMP/solo" && as laneB osrc_lease claim any/file >/dev/null 2>&1 ); [ $? = 3 ] && ok "a root lease covers every file" || bad "root lease did not cover a file"

# A ledger that does not parse is never overwritten by a claim, release or renewal.
cp "$OSRC_HOME/leases.json" "$TMP/good.json"; head -c 40 "$TMP/good.json" > "$OSRC_HOME/leases.json"; cp "$OSRC_HOME/leases.json" "$TMP/bad.json"
as laneA osrc_lease claim new/file >/dev/null 2>"$TMP/corrupt.err"; rc=$?
as laneA osrc_lease release --all >/dev/null 2>&1; _osrc_lease_renew_live; as laneA osrc_lane_inbox >/dev/null 2>&1
[ "$rc" != 0 ] && cmp -s "$OSRC_HOME/leases.json" "$TMP/bad.json" && grep -q unreadable "$TMP/corrupt.err" \
  && ok "a corrupt ledger is refused, not wiped" || bad "corrupt ledger: rc=$rc err=$(cat "$TMP/corrupt.err") now=$(cat "$OSRC_HOME/leases.json")"
cp "$TMP/good.json" "$OSRC_HOME/leases.json"

# Two lanes claiming one path at the same instant: exactly one wins.
( _osrc_lease_claim racer1 "$REPO" hot/file 2>/dev/null; echo $? > "$TMP/c1" ) &
( _osrc_lease_claim racer2 "$REPO" hot/file 2>/dev/null; echo $? > "$TMP/c2" ) &
wait
[ "$(cat "$TMP/c1" "$TMP/c2" | sort | tr '\n' ' ')" = "0 3 " ] && ok "simultaneous claims: one wins" \
  || bad "simultaneous claims: $(cat "$TMP/c1" "$TMP/c2" | tr '\n' ' ')"

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
