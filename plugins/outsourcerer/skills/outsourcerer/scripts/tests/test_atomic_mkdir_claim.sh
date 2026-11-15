#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib_race_barrier.sh"
TMP="$(mktemp -d "${TMPDIR%/}/osrc-atomic-claim.XXXXXX")" || exit 1
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
      if [ "$mode" = shell ]; then mkdir() { builtin command mkdir "$@"; }; fi
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

if command mkdir --version 2>/dev/null | grep -q 'GNU coreutils'; then
  for platform in MSYS_NT-10.0 MINGW64_NT-10.0 CYGWIN_NT-10.0; do
    (
      command() {
        case "${1:-}:${2:-}" in -v:perl|-v:python3) return 1 ;; esac
        builtin command "$@"
      }
      uname() { printf '%s\n' "$platform"; }
      mkdir() { builtin command mkdir "$@"; }
      _osrc_atomic_mkdir "$TMP/gnu-$platform" || exit 1
      ! _osrc_atomic_mkdir "$TMP/gnu-$platform" || exit 1
    ) || { echo "FAIL: $platform could not use GNU mkdir atomically"; exit 1; }
    echo "PASS: $platform accepts genuine GNU mkdir"
  done
fi

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
  mkdir() { builtin command mkdir "$@"; }
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
  mkdir() { builtin command mkdir "$@"; }
  perl() { printf 'perl\n' >> "$TMP/broken-order"; return 1; }
  python3() { printf 'python %s\n' "${1:-}" >> "$TMP/broken-order"; return 1; }
  _mkdir_claim "$TMP/both-failed" || exit 1
  [ "$(cat "$TMP/broken-order")" = "$(printf 'perl\npython -I')" ] || exit 1
  ! _mkdir_claim "$TMP/both-failed" || exit 1
) || { echo 'FAIL: broken interpreters did not fall back in order'; exit 1; }
echo 'PASS: broken Perl and Python fall back in order without claiming an existing directory'

(
  command() {
    case "${1:-}:${2:-}" in -v:perl|-v:python3) return 1 ;; esac
    builtin command "$@"
  }
  mkdir() {
    [ "${1:-}" != --version ] || { echo 'mkdir (uutils coreutils) 0.10.0'; return 0; }
    command mkdir -p "$@"
  }
  if _osrc_atomic_mkdir "$TMP/uutils-only" 2> "$TMP/uutils.err"; then exit 1; fi
  [ ! -e "$TMP/uutils-only" ] && grep -q 'uutils mkdir requires working Perl or Python 3' "$TMP/uutils.err"
) || { echo 'FAIL: unsafe uutils fallback was not refused with a diagnostic'; exit 1; }
echo 'PASS: uutils without an interpreter fails closed with a named diagnostic'

# A shell-only caller paused before the real mkdir must lose to a Perl caller.
if command -v perl >/dev/null 2>&1; then
  (
    command() {
      case "${1:-}:${2:-}" in -v:perl|-v:python3) return 1 ;; esac
      builtin command "$@"
    }
    mkdir() {
      [ "${1:-}" != --version ] || { echo 'mkdir (GNU coreutils)'; return 0; }
      : > "$TMP/mixed-paused"
      deadline=$((SECONDS + 20))
      while [ ! -f "$TMP/mixed-go" ]; do [ "$SECONDS" -lt "$deadline" ] || exit 2; sleep 0.01; done
      builtin command mkdir "$@"
    }
    rc=0; _osrc_atomic_mkdir "$TMP/mixed" || rc=$?
    printf '%s\n' "$rc" > "$TMP/mixed.rc"
  ) & mixed_pid=$!
  deadline=$((SECONDS + 20))
  while [ ! -f "$TMP/mixed-paused" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { kill "$mixed_pid" 2>/dev/null; wait "$mixed_pid" 2>/dev/null; echo 'FAIL: mixed contender did not pause'; exit 1; }
    sleep 0.01
  done
  _osrc_atomic_mkdir "$TMP/mixed" || { echo 'FAIL: Perl mixed contender did not win'; exit 1; }
  : > "$TMP/mixed-go"; wait "$mixed_pid" || exit 1
  [ "$(cat "$TMP/mixed.rc")" != 0 ] || { echo 'FAIL: both mixed-backend contenders won'; exit 1; }
  echo 'PASS: atomic external mkdir excludes a simultaneous Perl owner'
fi

# A leftover file from the old shell-gate implementation cannot wedge claims.
(
  command() {
    case "${1:-}:${2:-}" in -v:perl|-v:python3) return 1 ;; esac
    builtin command "$@"
  }
  mkdir() { builtin command mkdir "$@"; }
  : > "$TMP/old-gate.osrc-claim-gate"
  _osrc_atomic_mkdir "$TMP/old-gate"
) || { echo 'FAIL: obsolete sibling gate still wedges an atomic mkdir'; exit 1; }
echo 'PASS: obsolete sibling gate does not wedge a claim'

# The host name alone cannot make an unknown PATH mkdir trustworthy. Native
# BSD hosts must bypass it; MSYS-family hosts must reject its mystery banner.
for platform in Darwin FreeBSD OpenBSD NetBSD DragonFly MSYS_NT-10.0 MINGW64_NT-10.0 CYGWIN_NT-10.0; do
  (
    command() {
      case "${1:-}:${2:-}" in -v:perl|-v:python3) return 1 ;; esac
      builtin command "$@"
    }
    uname() { printf '%s\n' "$platform"; }
    mkdir() {
      printf 'called\n' >> "$TMP/mystery-$platform.calls"
      if [ "${1:-}" = --version ]; then echo 'mystery mkdir 1.0'; return 0; fi
      builtin command mkdir -p "$@"
    }
    claim="$TMP/mystery-$platform"; ar=0; br=0
    _osrc_atomic_mkdir "$claim" 2> "$TMP/mystery-$platform.err" || ar=$?
    _osrc_atomic_mkdir "$claim" 2>> "$TMP/mystery-$platform.err" || br=$?
    case "$platform" in
      Darwin|FreeBSD|OpenBSD|NetBSD|DragonFly)
        [ "$ar" = 0 ] && [ "$br" != 0 ] && [ -d "$claim" ] && [ ! -e "$TMP/mystery-$platform.calls" ] ;;
      *)
        [ "$ar" != 0 ] && [ "$br" != 0 ] && [ ! -e "$claim" ] \
          && grep -q 'mkdir is not a known atomic implementation' "$TMP/mystery-$platform.err" ;;
    esac
  ) || { echo "FAIL: $platform trusted a mystery PATH mkdir"; exit 1; }
  echo "PASS: $platform rejects or bypasses a mystery PATH mkdir"
done
