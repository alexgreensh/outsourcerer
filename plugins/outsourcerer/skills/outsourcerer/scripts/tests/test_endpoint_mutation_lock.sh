#!/usr/bin/env bash
# test_endpoint_mutation_lock.sh — the endpoint mutation lock survives a nested state write and
# recovers from a leaked lock directory.
#
# Root cause guarded: _endpoint_mutation_lock used to be built on _state_lock_acquire, which is one
# global fd 9 plus one global kind variable. `session send` appends an obligation record (a state
# write, so a nested _state_lock_acquire/_release) while holding the mutation lock; the nested
# release cleared the shared kind, so the outer unlock became a no-op. On flock hosts the mutation
# lock was silently released before send-keys ran. On mkdir hosts (stock macOS has no flock) the
# lock DIRECTORY leaked forever and every later mutation on that pane stalled 5s and failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TMP="$(mktemp -d "$PWD/.test-mutation-lock.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
export HOME="$TMP/home"
mkdir -p "$OSRC_HOME" "$HOME"

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

set --
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
type -t _endpoint_mutation_lock >/dev/null || { echo "FAIL: _endpoint_mutation_lock not loaded"; exit 1; }
type -t _obligation_append >/dev/null || { echo "FAIL: _obligation_append not loaded"; exit 1; }

pane="lock-test-pane"
key="$(printf '%s' "$pane" | cksum | awk '{print $1}')"
lockdir="$OSRC_SESSIONS/mutation-$key.lock"

# ---------------------------------------------------------------------------
# 1. mkdir path (forced, so this runs on flock hosts too): a nested state write inside the
#    critical section must not clear the mutation lock, and the unlock must remove the directory.
export OSRC_FORCE_MKDIR_LOCK=1
if _endpoint_mutation_lock "$pane"; then
  [ -d "$lockdir" ] && ok "mkdir path: lock directory created" || bad "mkdir path: no lock directory at $lockdir"
  [ "${_ENDPOINT_MUTATION_KIND:-}" = mkdir ] && ok "mkdir path: kind recorded as mkdir" || bad "mkdir path: kind is [${_ENDPOINT_MUTATION_KIND:-}]"
  _obligation_append "send.test.1" "$pane" typing_started "" || bad "nested obligation append failed"
  [ "${_ENDPOINT_MUTATION_KIND:-}" = mkdir ] \
    && ok "a nested state write leaves the mutation lock kind intact" \
    || bad "a nested state write clobbered the mutation lock kind (now [${_ENDPOINT_MUTATION_KIND:-}])"
  _endpoint_mutation_unlock "$key"
  [ ! -d "$lockdir" ] && ok "unlock after a nested state write removes the lock directory" \
    || bad "LEAKED: $lockdir still exists after unlock"
  start=$(date +%s)
  if _endpoint_mutation_lock "$pane"; then
    took=$(( $(date +%s) - start ))
    [ "$took" -le 1 ] && ok "the pane can be locked again immediately (${took}s)" || bad "re-lock stalled ${took}s"
    _endpoint_mutation_unlock "$key"
  else
    bad "re-lock refused: the pane's control plane is wedged"
  fi
else
  bad "mkdir path: could not take the mutation lock"
fi

# ---------------------------------------------------------------------------
# 2. mkdir path: a leaked directory older than the stale threshold is reclaimed; a fresh one is not.
export OSRC_FORCE_MKDIR_LOCK=1
mkdir -p "$lockdir"
touch -t 202001010000 "$lockdir"
  start=$(date +%s)
  if _endpoint_mutation_lock "$pane"; then
    took=$(( $(date +%s) - start ))
    [ "$took" -le 2 ] && ok "a stale leaked lock directory is reclaimed (${took}s)" || bad "stale reclaim took ${took}s"
    _endpoint_mutation_unlock "$key"
  else
    bad "a stale leaked lock directory was never reclaimed"
    rmdir "$lockdir" 2>/dev/null || true
  fi
  mkdir -p "$lockdir"   # fresh: a live holder
  if _endpoint_mutation_lock "$pane"; then
    bad "a FRESH lock directory was reclaimed (a live holder was evicted)"
    _endpoint_mutation_unlock "$key"
  else
    [ -d "$lockdir" ] && ok "a fresh lock directory is respected (lock refused, directory kept)" || bad "fresh lock directory vanished"
  fi
rmdir "$lockdir" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. flock path (only where flock exists): the lock is still HELD across a nested state write and
#    is released by the unlock, observed from an independent process.
if command -v flock >/dev/null 2>&1; then
  unset OSRC_FORCE_MKDIR_LOCK
  if ! _endpoint_mutation_lock "$pane"; then bad "flock path: could not take the mutation lock"; else
  [ "${_ENDPOINT_MUTATION_KIND:-}" = flock ] && ok "flock path: kind recorded as flock" || bad "flock path: kind is [${_ENDPOINT_MUTATION_KIND:-}]"
  _obligation_append "send.test.2" "$pane" typing_started "" || bad "nested obligation append failed"
  if flock -n "$lockdir" true 2>/dev/null; then
    bad "flock path: the mutation lock was DROPPED by a nested state write"
  else
    ok "flock path: the mutation lock is still held after a nested state write"
  fi
  _endpoint_mutation_unlock "$key"
  if flock -n "$lockdir" true 2>/dev/null; then
    ok "flock path: unlock releases the lock"
  else
    bad "flock path: lock still held after unlock"
  fi
  fi
else
  echo "SKIP: flock not on this host; flock-path cases not run"
fi

# ---------------------------------------------------------------------------
# 4. The two lock kinds are independent state: a state lock cycle does not touch the mutation kind.
export OSRC_FORCE_MKDIR_LOCK=1
if ! _endpoint_mutation_lock "$pane"; then bad "could not take the mutation lock"; else
  _state_lock_acquire "$OSRC_HOME/some-state" && _state_lock_release "$OSRC_HOME/some-state"
  [ "${_ENDPOINT_MUTATION_KIND:-}" = mkdir ] && ok "a state lock cycle does not clear the mutation lock kind" \
    || bad "state lock cycle cleared the mutation lock kind"
  _endpoint_mutation_unlock "$key"
  [ ! -d "$lockdir" ] && ok "mutation lock released cleanly after a state lock cycle" || bad "mutation lock directory leaked"
fi

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
