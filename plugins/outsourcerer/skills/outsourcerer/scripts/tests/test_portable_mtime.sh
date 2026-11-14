#!/usr/bin/env bash
# GNU stat -f succeeds with filesystem data, so the GNU file query must run first.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_sandbox.sh" || { echo "FAIL: sandbox library" >&2; exit 1; }
osrc_test_sandbox || { echo "FAIL: sandbox" >&2; exit 1; }
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/cleanup.sh"
. "$HERE/../lib/supervise_watch.sh"
mkdir -p "$OSRC_HOME/fixture"
printf test > "$OSRC_HOME/fixture/L1.DONE"
stat() {
  if [ "$1" = -c ]; then
    [ "$TEST_STAT" = gnu ] || return 1
    printf '12345\n'
  elif [ "$TEST_STAT" = gnu ]; then
    printf 'filesystem statistics\n'
  else
    printf '12345\n'
  fi
}
for TEST_STAT in gnu bsd; do
  [ "$(_osrc_path_newest_mtime "$OSRC_HOME/fixture")" = 12345 ] || { echo "FAIL: $TEST_STAT cleanup"; exit 1; }
  case "$(_sv_fp "$OSRC_HOME/fixture/L1.DONE")" in
    L1.DONE:12345:4:*) ;;
    *) echo "FAIL: $TEST_STAT fingerprint"; exit 1 ;;
  esac
  echo "PASS: $TEST_STAT cleanup and watch fingerprint"
done
