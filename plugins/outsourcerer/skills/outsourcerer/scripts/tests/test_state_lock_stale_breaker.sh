#!/usr/bin/env bash
# test_state_lock_stale_breaker.sh — the mkdir state-lock (the active path on stock macOS, which ships
# no flock) recovers from a crashed holder instead of wedging every state write forever.
#
# Root cause guarded: _state_lock_acquire's no-flock branch used to `mkdir` a `.lock` dir and, on a
# crash while held, leave it behind permanently. Every later acquire then looped 50x0.1s and returned
# "state lock unavailable", so the registry, obligations, wake-queue and fleet-name writes all failed
# closed until a human deleted the dir by hand. The fix records the holder's identity (pid + process
# start marker) in `<lock>/owner` on claim, and a later waiter breaks the lock ONLY when that owner is
# PROVABLY dead — never on a live owner, an unwritten owner, or an unprovable `ps`. The break is an
# atomic rename so two waiters can never delete each other's freshly acquired lock.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d "$PWD/.test-statelock.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
export HOME="$TMP/home"
mkdir -p "$OSRC_HOME" "$HOME"

set --
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
type -t _state_lock_acquire >/dev/null || { echo "FAIL: _state_lock_acquire not loaded"; exit 1; }
type -t _pid_start_identity >/dev/null || { echo "FAIL: _pid_start_identity not loaded"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

file="$OSRC_HOME/x.jsonl"
lock="$file.lock"

# If flock exists on this runner (e.g. Linux CI), the mkdir path is not exercised — skip cleanly rather
# than assert against a branch that never runs here.
if command -v flock >/dev/null 2>&1; then
  echo "SKIP: flock present, mkdir lock path not active on this host"
  exit 0
fi

# Precondition: a very high pid must be provably dead (ps works, no such process => rc 2). If the host
# cannot prove it, skip rather than flake.
_pid_start_identity 999999 >/dev/null 2>&1
[ "$?" -eq 2 ] || { echo "SKIP: cannot prove a dead pid on this host (ps semantics differ)"; exit 0; }

# 1. A stale lock whose owner is provably dead is broken, and acquire succeeds.
rm -rf "$lock"; mkdir "$lock"; printf '%s %s\n' 999999 'Thu Jan  1 00:00:00 2020' > "$lock/owner"
if _state_lock_acquire "$file"; then ok "stale (dead-owner) lock is broken and re-acquired"; else bad "failed to break a stale dead-owner lock (the wedge is still present)"; fi

# 2. Release removes the lock dir AND its owner file (no residue to wedge the next writer).
_state_lock_release "$file"
[ ! -e "$lock" ] && ok "release removed the lock dir and owner file" || bad "release left lock residue: $(ls -a "$lock" 2>/dev/null)"

# 3. A fresh claim records a readable owner identity (pid first field) for the NEXT waiter to judge.
_state_lock_acquire "$file" || bad "could not acquire a free lock"
if [ -f "$lock/owner" ]; then
  read -r op _ < "$lock/owner" 2>/dev/null || op=""
  [ "$op" = "$$" ] && ok "claim records the holder pid in <lock>/owner" || bad "owner pid wrong: got '$op', want '$$'"
else
  bad "claim did not write an owner identity file"
fi
_state_lock_release "$file"

# 4. SAFETY: a lock held by a LIVE owner (this very process) is NOT broken — acquire must fail. This is
#    the property that separates an identity breaker from a dangerous age timer. (~5s: the full retry loop.)
rm -rf "$lock"; mkdir "$lock"; printf '%s %s\n' "$$" "$(_pid_start_identity "$$" 2>/dev/null)" > "$lock/owner"
if _state_lock_acquire "$file"; then
  bad "broke a LIVE owner's lock — unsafe, would corrupt concurrent state writes"
  _state_lock_release "$file"
else
  ok "a live owner's lock is respected, never stolen"
fi
rm -rf "$lock"

# 5. End-to-end: a crashed holder's residue does not stop a real state append from landing.
mkdir "$lock"; printf '%s %s\n' 999999 'Thu Jan  1 00:00:00 2020' > "$lock/owner"
if _state_append "$file" '{"probe":1}'; then
  tail -n1 "$file" | grep -q '"probe":1' && ok "state append recovers past a crashed holder's stale lock" || bad "append returned 0 but did not write the record"
else
  bad "state append still fails closed behind a stale lock (the wedge is not fixed)"
fi

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
