#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TMP="$(mktemp -d)"
export OSRC_HOME="$TMP"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

set --
. "$SRC" >/dev/null 2>&1

# Preserve the real lock/read helpers under new names so the locked-rewrite block can trace and inject
# around them (bash 3.2: re-emit the function body under a new name). The trace file is created
# here because the wrappers are active from the start (set -u: they append to it on every call).
TRACE="$TMP/trace"
: > "$TRACE"   # the wrappers are active from the start (set -u), so the file must exist
INJECT="$TMP/inject-on-lock" # created (existence-gated) only inside the locked-rewrite block below
eval "_state_jsonl_read_real() $(declare -f _state_jsonl_read | tail -n +2)"
eval "_state_lock_acquire_real() $(declare -f _state_lock_acquire | tail -n +2)"
eval "_state_lock_release_real() $(declare -f _state_lock_release | tail -n +2)"
_state_jsonl_read() { printf 'read %s\n' "$1" >> "$TRACE"; _state_jsonl_read_real "$@"; }
_state_lock_acquire() {
  printf 'lock %s\n' "$1" >> "$TRACE"
  # Simulate a concurrent _wake_append racing the re-arm: it lands exactly when the queue lock is
  # taken -- inside the lock, before the drain. (A direct printf, not _wake_append, to avoid
  # recursing into the wrapped lock helpers.)
  case "$1" in
    "$OSRC_WAKE_QUEUE") [ -e "$INJECT" ] && printf '%s\n' '{"event_id":"wake-3","kind":"blocked"}' >> "$OSRC_WAKE_QUEUE" ;;
  esac
  _state_lock_acquire_real "$@"
}
_state_lock_release() { _state_lock_release_real "$@"; }
reset_wrappers() {
  # Restore pass-through behavior (no tracing, no injection).
  _state_jsonl_read() { _state_jsonl_read_real "$@"; }
  _state_lock_acquire() { _state_lock_acquire_real "$@"; }
  _state_lock_release() { _state_lock_release_real "$@"; }
}

if _wake_append '{"event_id":"wake-1","kind":"blocked"}' && _wake_append '{"event_id":"wake-2","kind":"unknown"}'; then
  ok "wake records append"
else
  bad "wake append failed"
fi
pending="$(_wake_drain)"
if printf '%s' "$pending" | grep -q 'wake-1' && printf '%s' "$pending" | grep -q 'wake-2'; then
  ok "unacknowledged wakes drain"
else
  bad "wake drain omitted a pending event"
fi

if _wake_ack wake-1; then
  ok "wake acknowledgement appends"
else
  bad "wake acknowledgement failed"
fi
pending="$(_wake_drain)"
if ! printf '%s' "$pending" | grep -q 'wake-1' && printf '%s' "$pending" | grep -q 'wake-2'; then
  ok "acknowledged wake is excluded without losing the next wake"
else
  bad "wake acknowledgement filtering is wrong ($pending)"
fi

if _wake_append '{"kind":"missing-id"}' >/dev/null 2>&1; then
  bad "wake without an id was accepted"
else
  ok "wake without an id is rejected"
fi

# ---------------------------------------------------------------------------
# Locked rewrite — _wake_rearm_id must drain the queue UNDER the WAKE_QUEUE lock. The old code read
# the queue before acquiring the lock, so a concurrently appended wake landing between the
# snapshot and the rewrite was clobbered by the stale snapshot — a silently lost alarm.
#
# Two deterministic pins, no real concurrency needed:
#   a) ORDER: the queue read happens after the queue lock is taken (traced via wrappers).
#   b) BEHAVIOR: a wake appended "at lock time" (injected by the lock wrapper, i.e. after the old
#      unlocked snapshot would have been taken but before the drain) SURVIVES the re-arm rewrite.
#      Under the old read-before-lock code the same injection is clobbered — the test discriminates.
TRACE="$TMP/trace"
: > "$TRACE"   # keep only the re-arm call's trace for the ordering assertions
: > "$INJECT"   # existence-gates the lock-time wake-3 injection below
_wake_rearm_id wake-1 || bad "wake_rearm_id returned an error"
q="$(_wake_drain)"
if printf '%s' "$q" | grep -q 'wake-2' && printf '%s' "$q" | grep -q 'wake-3' && ! printf '%s' "$q" | grep -q 'wake-1'; then
  ok "a wake appended during the re-arm lock survives the rewrite (no lost alarm)"
else
  bad "concurrent wake was lost by the re-arm rewrite (queue: $q)"
fi

# (a) Order: the queue lock must be taken BEFORE the queue is read.
qlock="$(grep -n "^lock $OSRC_WAKE_QUEUE\$" "$TRACE" | head -1 | cut -d: -f1)"
qread="$(grep -n "^read $OSRC_WAKE_QUEUE\$" "$TRACE" | head -1 | cut -d: -f1)"
if [ -n "$qlock" ] && [ -n "$qread" ] && [ "$qlock" -lt "$qread" ]; then
  ok "wake_rearm_id drains the queue under the WAKE_QUEUE lock"
else
  bad "wake_rearm_id read the queue before taking the lock (lock line $qlock, read line $qread)"
fi

# The ack trace is untouched discipline-wise: ack first, then queue (crash-safe ordering).
alock="$(grep -n "^lock $OSRC_WAKE_ACK\$" "$TRACE" | head -1 | cut -d: -f1)"
if [ -n "$alock" ] && [ "$alock" -lt "$qlock" ]; then
  ok "ack is still dropped before the queue lines (crash-safe ordering preserved)"
else
  bad "rearm ordering changed: ack lock line $alock is not before queue lock line $qlock"
fi
reset_wrappers

# Basic rearm semantics still hold: the ack of the re-armed id is consumed, so a fresh alarm
# under the SAME id is deliverable instead of suppressed by the delivered copies.
_wake_ack wake-2
_wake_rearm_id wake-2
_wake_append '{"event_id":"wake-2","kind":"blocked"}'   # the fresh alarm the re-arm un-traps
pending="$(_wake_drain)"
if printf '%s' "$pending" | grep -q 'wake-2' && printf '%s' "$pending" | grep -q 'wake-3'; then
  ok "rearm consumes the ack so the same id can re-fire"
else
  bad "rearm broke deliverable state (queue: $pending)"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
