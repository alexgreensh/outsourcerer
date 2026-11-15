#!/bin/bash
# Keep fixture paths identical to paths resolved by the product on macOS.
TMPDIR="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || {
  printf '%s\n' 'FAIL: cannot resolve scratch base' >&2
  exit 1
}
export TMPDIR

# osrc_test_dead_pid -> prints a pid that is PROVABLY dead: a child this shell forked and reaped.
# Its number cannot come back until the kernel's pid counter wraps all the way round (99,999 forks
# on macOS, pid_max on Linux), which never happens inside one test. Never find a "dead" pid by
# scanning for one that `kill -0` rejects: kill -0 also rejects a pid whose process is still being
# CREATED (macOS ESRCH while in creation) and a pid just ahead of the allocator, so the "dead"
# supervisor can be alive a moment later and the product correctly refuses to call it dead.
# Proven on macOS: scanning down from a fresh child picked a pid that was alive 20 ms later in
# 3 of 300 tries under fork churn (a same-user mdworker_shared and two sleeps); that is the
# test_devin_free_guard "got ''" CI flake (run 43751567057). Starting the scan from a fixed number
# (99991) is worse on a Mac whose counter is already in the 90k range.
osrc_test_dead_pid() {
  local _p
  ( exit 0 ) & _p=$!
  wait "$_p" 2>/dev/null
  printf '%s\n' "$_p"
}

# osrc_test_mkdir_p <args...> -> "mkdir -p" that tolerates a caller's own -p. Lying-mkdir shims wrap
# `mkdir -p "$@"`, and the product already calls `mkdir -p dir`, so the shim ran `mkdir -p -p dir`.
# GNU accepts the repeat; uutils 0.0.24 (Ubuntu 24.04) rejects it with rc 1, so under uutils every
# contender "lost" and the lock suites saw zero owners. Drop the caller's -p, then add exactly one.
osrc_test_mkdir_p() {
  local _a=() _x
  for _x in "$@"; do [ "$_x" = -p ] || _a+=("$_x"); done
  builtin command mkdir -p ${_a[@]+"${_a[@]}"}
}
