#!/usr/bin/env bash
# Concurrent `session send` must wait for the obligation-ledger lock, never fail fast, never corrupt
# the ledger (lane osrc-l7-coord). Seen live: two sends to different lanes at nearly the same time,
# and the second was refused because the ledger lock was busy for more than the old 5 s.
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "${TMPDIR%/}/.test-send-lock.XXXXXX")" || { echo "FAIL: no scratch dir" >&2; exit 1; }
TEST_TMP="$TMP"; trap 'rm -rf "$TEST_TMP"' EXIT
pass=0; fail=0; ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
HOME="$TMP/home"; OSRC_HOME="$TMP/state"; export HOME OSRC_HOME; mkdir -p "$HOME"; set --; . "$SRC" >/dev/null 2>&1

# A holder that keeps the ledger lock longer than one acquire attempt (5 s) — what a slow
# critical section on a large ledger did to the second sender.
hold_lock() { # <seconds>
  ( _state_lock_acquire "$OSRC_OBLIGATIONS" || exit 9; : > "$TMP/held"; sleep "$1"; _state_lock_release "$OSRC_OBLIGATIONS" ) &
  HOLDER=$!
  i=0; while [ ! -f "$TMP/held" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}
_mkdir_private "$OSRC_HOME"; : >> "$OSRC_OBLIGATIONS"

# 1. Two writers at once, both behind a 7 s holder: both must wait and succeed.
hold_lock 7
( _obligation_admit send.a.1 lane-a && _obligation_append send.a.1 lane-a typing_started "" ) 2>"$TMP/e1" & w1=$!
( _obligation_admit send.b.1 lane-b && _obligation_append send.b.1 lane-b typing_started "" ) 2>"$TMP/e2" & w2=$!
wait "$w1"; r1=$?; wait "$w2"; r2=$?; wait "$HOLDER" 2>/dev/null
[ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && ok "two concurrent writers wait out a busy lock" \
  || bad "a writer failed fast on a busy lock (rc $r1/$r2): $(cat "$TMP/e1" "$TMP/e2")"

# 2. Many writers racing with no holder: every record lands, every line is valid JSON.
rm -f "$TMP/held"; k=0; pids=""
while [ "$k" -lt 8 ]; do
  ( _obligation_admit "send.race.$k" "lane-$k" && _obligation_append "send.race.$k" "lane-$k" submitted "" ) & pids="$pids $!"
  k=$((k + 1))
done
rc=0; for p in $pids; do wait "$p" || rc=1; done
bad_lines="$(while IFS= read -r l; do printf '%s' "$l" | jq -e . >/dev/null 2>&1 || echo x; done < "$OSRC_OBLIGATIONS" | grep -c x)"
n="$(jq -r 'select(.obligation_id|startswith("send.race.")) | .state' "$OSRC_OBLIGATIONS" | grep -c .)"
[ "$rc" -eq 0 ] && [ "$bad_lines" = 0 ] && [ "$n" = 16 ] && ok "8 racing writers: 16 records, ledger intact" \
  || bad "racing writers: rc=$rc bad_lines=$bad_lines records=$n"
[ "$(_obligation_latest_state send.race.3)" = submitted ] && ok "latest state still read per id" || bad "latest state wrong"

# 3. The wait is bounded and the error names the cause.
rm -f "$TMP/held"; hold_lock 12
start=$(date +%s)
OSRC_SEND_LOCK_WAIT_SECS=1 _obligation_admit send.c.1 lane-c 2>"$TMP/e3"; r3=$?
took=$(( $(date +%s) - start )); kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
[ "$r3" -ne 0 ] && [ "$took" -lt 11 ] && grep -q 'obligation ledger' "$TMP/e3" \
  && ok "lock wait is bounded (${took}s) with a clear error" || bad "bound: rc=$r3 took=${took}s err=$(cat "$TMP/e3")"
[ -z "$(_obligation_latest_state send.c.1)" ] && ok "a refused writer leaves no record" || bad "refused writer wrote a record"

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
