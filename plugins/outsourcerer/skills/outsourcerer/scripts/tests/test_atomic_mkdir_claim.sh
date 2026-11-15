#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib_race_barrier.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-atomic-claim.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home" HOME="$TMP/home" OSRC_HEARTBEAT_DISABLED=1
mkdir -p "$HOME"
set --
. "$DIR/../outsourcerer.sh" >/dev/null 2>&1
trap 'rm -rf "$TMP"' EXIT

# Mimic an external mkdir that reports success to every caller on an existing
# directory. The control proves the stub creates the double-winner condition.
mkdir() { command mkdir -p "$@"; }
mkdir "$TMP/control" && mkdir "$TMP/control" || { echo 'FAIL: lying mkdir control'; exit 1; }
echo 'PASS: lying mkdir reports success twice'

for mode in native python shell; do
  if [ "$mode" = python ] && ! command -v python3 >/dev/null 2>&1; then
    echo 'SKIP: Python is unavailable'; continue
  fi
  gate="$TMP/gate-$mode"; claim="$TMP/claim-$mode"
  command mkdir "$gate"
  pids=()
  for i in 1 2 3 4 5 6 7 8 9 10; do
    (
      osrc_race_ready "$gate" "$i" || exit 125
      if [ "$mode" != native ]; then
        command() {
          case "${1:-}:${2:-}" in
            -v:python3) [ "$mode" != shell ] || return 1 ;;
            -v:perl) return 1 ;;
          esac
          builtin command "$@"
        }
      fi
      _mkdir_claim "$claim"; printf '%s\n' "$?" > "$gate/result.$i"
    ) & pids[$i]=$!
  done
  osrc_race_release "$gate" 10 || exit 1
  for i in 1 2 3 4 5 6 7 8 9 10; do wait "${pids[$i]}" || exit 1; done
  wins=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    read -r rc < "$gate/result.$i"
    [ "$rc" != 0 ] || wins=$((wins + 1))
  done
  [ "$wins" = 1 ] || { echo "FAIL: $mode helper allowed $wins winners"; exit 1; }
  echo "PASS: $mode helper elects exactly one owner despite lying mkdir"
done

# An unavailable or broken interpreter must not turn an absent directory into
# a false collision, and Python must not load code from the caller's directory.
if command -v perl >/dev/null 2>&1; then
  (
    perl() { printf 'perl\n' >> "$TMP/order"; command perl "$@"; }
    python3() { printf 'python\n' >> "$TMP/order"; return 1; }
    _mkdir_claim "$TMP/perl-first" || exit 1
    [ "$(cat "$TMP/order")" = perl ] || exit 1
    ! _mkdir_claim "$TMP/perl-first" || exit 1
    ! grep -q python "$TMP/order" || exit 1
  ) || { echo 'FAIL: Perl was not preferred or an existing directory was claimed'; exit 1; }
  echo 'PASS: working Perl is preferred and existing directories are refused'
fi
(
  command() {
    case "${1:-}:${2:-}" in -v:perl) return 1 ;; esac
    builtin command "$@"
  }
  python3() { printf '%s\n' "${1:-}" >> "$TMP/python-args"; return 1; }
  _mkdir_claim "$TMP/python-failed" || exit 1
  [ "$(cat "$TMP/python-args")" = -I ] || exit 1
  ! _mkdir_claim "$TMP/python-failed" || exit 1
) || { echo 'FAIL: a broken Python did not safely fall back or was not isolated'; exit 1; }
echo 'PASS: broken isolated Python falls back for a missing directory and refuses an existing one'
(
  perl() { printf 'perl\n' >> "$TMP/broken-order"; return 1; }
  python3() { printf 'python %s\n' "${1:-}" >> "$TMP/broken-order"; return 1; }
  _mkdir_claim "$TMP/both-failed" || exit 1
  [ "$(cat "$TMP/broken-order")" = "$(printf 'perl\npython -I')" ] || exit 1
  ! _mkdir_claim "$TMP/both-failed" || exit 1
) || { echo 'FAIL: broken interpreters did not fall back in order'; exit 1; }
echo 'PASS: broken Perl and Python fall back in order without claiming an existing directory'
