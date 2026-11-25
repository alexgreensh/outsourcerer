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

# 3. The wait is bounded and the error names the cause. The holder releases on its own: killing it
#    would strand a mkdir lock on bash 3.2 without flock (no BASHPID, so it names the live test shell).
rm -f "$TMP/held"; hold_lock 4
start=$(date +%s)
OSRC_SEND_LOCK_WAIT_SECS=1 _obligation_admit send.c.1 lane-c 2>"$TMP/e3"; r3=$?
took=$(( $(date +%s) - start )); wait "$HOLDER" 2>/dev/null
[ "$r3" -ne 0 ] && [ "$took" -le 3 ] && grep -q 'obligation ledger' "$TMP/e3" \
  && ok "lock wait is bounded (${took}s) with a clear error" || bad "bound: rc=$r3 took=${took}s err=$(cat "$TMP/e3")"
[ -z "$(_obligation_latest_state send.c.1)" ] && ok "a refused writer leaves no record" || bad "refused writer wrote a record"

# 4. A binary byte (a crash's NUL-padded tail) or a non-compact record must not hide a live state,
#    or the same reply is admitted and sent twice.
_obligation_append send.d.1 lane-d typing_started "" && printf '\000\000\000\n' >> "$OSRC_OBLIGATIONS"
[ "$(_obligation_latest_state send.d.1)" = typing_started ] && ok "a NUL byte in the ledger hides no state" || bad "NUL hid the state"
_obligation_admit send.d.1 lane-d 2>/dev/null; [ $? = 2 ] && ok "a NUL byte does not let a live obligation be admitted again" || bad "re-admitted after NUL"
printf '{ "obligation_id": "send.e.1", "session_id": "lane-e", "state": "submitted" }\n' >> "$OSRC_OBLIGATIONS"
[ "$(_obligation_latest_state send.e.1)" = submitted ] && ok "a non-compact record still counts" || bad "non-compact record missed"

# 7. The mkdir lock (no flock: stock macOS) is bounded by the clock, not just by its try count: under
#    load each try forks and a 1 s wait took 4 s. Slow tries (0.3 s each, like a loaded Mac) must still
#    give up within 2 s of a 1 s wait.
if command -v flock >/dev/null 2>&1; then ok "mkdir-lock clock bound: n/a (flock present)"
else
  ( _mkdir_claim() { sleep 0.3; return 1; }; s0=$SECONDS; _OSRC_LOCK_WAIT=1 _state_lock_acquire "$TMP/slow.jsonl"; echo "rc=$? took=$(( SECONDS - s0 ))" ) > "$TMP/slow.out" 2>/dev/null
  case "$(cat "$TMP/slow.out")" in "rc=1 took="[012]) ok "slow mkdir-lock tries stop on the clock ($(cat "$TMP/slow.out"))" ;; *) bad "mkdir-lock wait overshot: $(cat "$TMP/slow.out")" ;; esac
fi
echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
