#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# A failed ps lookup must not let a contender steal a live factory lock.
set -uo pipefail
TEST_ROOT="$(mktemp -d "${TMPDIR%/}/lock-owner-test.XXXXXX")" || exit 1
export HOME="$TEST_ROOT/home" OSRC_HOME="$TEST_ROOT/osrc"
holder=""
cleanup() { [ -z "$holder" ] || { kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; }; rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
mkdir -p "$HOME" "$OSRC_HOME" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
FACTORY="$HERE/../factory-tasks.sh"
eval "$(sed -n '/^_pid_start_valid() {/,/^}/p; /^_pid_start_identity() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^_factory_owner_dead() {/,/^}/p' "$FACTORY")"
sleep 120 & holder=$!
identity="$(_pid_start_identity "$holder")" || { echo 'FAIL: cannot identify live holder'; exit 1; }
ps() {
  if [ "${4:-}" = "$holder" ]; then return 1; fi
  command ps "$@"
}
if _factory_owner_dead "$holder" "$identity"; then
  echo 'FAIL: failed ps lookup classified a live lock holder as dead'; exit 1
fi
echo 'PASS: failed ps lookup keeps a live lock holder'
dead="$holder"; kill "$holder"; wait "$holder" 2>/dev/null || true; holder=""
if ! _factory_owner_dead "$dead" "$identity"; then
  echo 'FAIL: departed lock holder was not recognized'; exit 1
fi
echo 'PASS: departed lock holder can be reclaimed'
