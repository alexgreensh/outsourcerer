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

mkdir_banner="$(command mkdir --version 2>/dev/null)" || mkdir_banner=""
host_system="$(uname -s 2>/dev/null)"
shell_usable=0; shell_error='mkdir is not a known atomic implementation'
case "$host_system" in
  Darwin|FreeBSD|OpenBSD|NetBSD|DragonFly) shell_usable=1 ;;
  *) case "$mkdir_banner" in
       *uutils*|*Uutils*) shell_error='uutils mkdir requires working Perl or Python 3' ;;
       *'GNU coreutils'*) shell_usable=1 ;;
     esac ;;
esac

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
      _mkdir_claim "$claim" 2> "$gate/error.$i"; printf '%s\n' "$?" > "$gate/result.$i"
    ) & pids[$i]=$!
  done
  osrc_race_release "$gate" 10 || exit 1
  for i in 1 2 3 4 5 6 7 8 9 10; do wait "${pids[$i]}" || exit 1; done
  wins=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    read -r rc < "$gate/result.$i"
    [ "$rc" != 0 ] || wins=$((wins + 1))
  done
  if [ "$mode" = shell ] && [ "$shell_usable" = 0 ]; then
    [ "$wins" = 0 ] && [ ! -e "$claim" ] || { echo "FAIL: unsafe shell helper allowed $wins winners"; exit 1; }
    for i in 1 2 3 4 5 6 7 8 9 10; do
      grep -Fq "$shell_error" "$gate/error.$i" || { echo "FAIL: shell refusal lacked diagnostic for racer $i"; exit 1; }
    done
    echo 'PASS: unsafe shell mkdir refuses every contender with a diagnostic'
  else
    [ "$wins" = 1 ] || { echo "FAIL: $mode helper allowed $wins winners"; exit 1; }
    echo "PASS: $mode helper elects exactly one owner despite lying mkdir"
  fi
done

case "$mkdir_banner" in *'GNU coreutils'*) gnu_mkdir=1 ;; *) gnu_mkdir=0 ;; esac
if [ "$gnu_mkdir" = 1 ]; then
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
  rc=0; _mkdir_claim "$TMP/python-failed" 2> "$TMP/python-failed.err" || rc=$?
  if [ "$shell_usable" = 1 ]; then [ "$rc" = 0 ] || exit 1
  else
    [ "$rc" != 0 ] && [ ! -e "$TMP/python-failed" ] && grep -Fq "$shell_error" "$TMP/python-failed.err" || exit 1
    builtin command mkdir "$TMP/python-failed" || exit 1
  fi
  [ "$(cat "$TMP/python-args")" = -I ] || exit 1
  ! _mkdir_claim "$TMP/python-failed" || exit 1
) || { echo 'FAIL: a broken Python did not safely fall back or was not isolated'; exit 1; }
echo 'PASS: broken isolated Python follows the safe host fallback and refuses an existing directory'
(
  mkdir() { builtin command mkdir "$@"; }
  perl() { printf 'perl\n' >> "$TMP/broken-order"; return 1; }
  python3() { printf 'python %s\n' "${1:-}" >> "$TMP/broken-order"; return 1; }
  rc=0; _mkdir_claim "$TMP/both-failed" 2> "$TMP/both-failed.err" || rc=$?
  if [ "$shell_usable" = 1 ]; then [ "$rc" = 0 ] || exit 1
  else
    [ "$rc" != 0 ] && [ ! -e "$TMP/both-failed" ] && grep -Fq "$shell_error" "$TMP/both-failed.err" || exit 1
    builtin command mkdir "$TMP/both-failed" || exit 1
  fi
  [ "$(cat "$TMP/broken-order")" = "$(printf 'perl\npython -I')" ] || exit 1
  ! _mkdir_claim "$TMP/both-failed" || exit 1
) || { echo 'FAIL: broken interpreters did not fall back in order'; exit 1; }
echo 'PASS: broken Perl and Python use the safe host fallback without claiming an existing directory'

(
  command() {
    case "${1:-}:${2:-}" in -v:perl|-v:python3) return 1 ;; esac
    builtin command "$@"
  }
  # uutils ships on Linux; on Darwin/BSD the helper rightly uses native /bin/mkdir instead.
  uname() { echo Linux; }
  mkdir() {
    [ "${1:-}" != --version ] || { echo 'mkdir (uutils coreutils) 0.10.0'; return 0; }
    command mkdir -p "$@"
  }
  if _osrc_atomic_mkdir "$TMP/uutils-only" 2> "$TMP/uutils.err"; then exit 1; fi
  [ ! -e "$TMP/uutils-only" ] && grep -q 'uutils mkdir requires working Perl or Python 3' "$TMP/uutils.err"
) || { echo 'FAIL: unsafe uutils fallback was not refused with a diagnostic'; exit 1; }
echo 'PASS: uutils without an interpreter fails closed with a named diagnostic'

# A contended claim whose holder releases between our refused mkdir and any follow-up check must
# just lose: no fall-through to the next interpreter or the shell, no uutils diagnostic on stderr
# (CI run 43751567057: "cannot claim ...lock.d.mx: uutils mkdir requires working Perl or Python 3"
# leaked into contended Devin dispatches). Real Perl refuses the existing dir; the wrapper then
# releases it, exactly the holder's rm -rf landing in the window.
for interp in perl python3; do
  command -v "$interp" >/dev/null 2>&1 || { echo "SKIP: $interp unavailable for the release-window case"; continue; }
  (
    rm -f "$TMP/rw.order"
    builtin command mkdir "$TMP/rw-$interp"
    uname() { echo Linux; }
    mkdir() {
      [ "${1:-}" != --version ] || { echo 'mkdir (uutils coreutils) 0.10.0'; return 0; }
      builtin command mkdir "$@"
    }
    if [ "$interp" = perl ]; then
      perl() { local r=0; printf 'perl\n' >> "$TMP/rw.order"; builtin command perl "$@" || r=$?; rmdir "$TMP/rw-perl"; return "$r"; }
      python3() { printf 'python3\n' >> "$TMP/rw.order"; return 1; }
    else
      command() { case "${1:-}:${2:-}" in -v:perl) return 1 ;; esac; builtin command "$@"; }
      python3() { local r=0; printf 'python3\n' >> "$TMP/rw.order"; builtin command python3 "$@" || r=$?; rmdir "$TMP/rw-python3"; return "$r"; }
    fi
    rc=0; _osrc_atomic_mkdir "$TMP/rw-$interp" 2> "$TMP/rw.err" || rc=$?
    [ "$rc" != 0 ] || { echo "rc=0 claimed a refused directory"; exit 1; }
    [ ! -s "$TMP/rw.err" ] || { echo "stderr: $(cat "$TMP/rw.err")"; exit 1; }
    [ "$(cat "$TMP/rw.order")" = "$interp" ] || { echo "fell through: $(tr '\n' ' ' < "$TMP/rw.order")"; exit 1; }
  ) || { echo "FAIL: a $interp refusal followed by a release fell through to the next claim mechanism"; exit 1; }
  echo "PASS: a $interp refusal is final even when the holder releases inside the window"
done

# A shell-only caller paused before the real mkdir must lose to a Perl caller.
if command -v perl >/dev/null 2>&1; then
  (
    command() {
      case "${1:-}:${2:-}" in -v:perl|-v:python3) return 1 ;; esac
      builtin command "$@"
    }
    uname() { echo Linux; }  # the GNU fallback path; Darwin/BSD use native /bin/mkdir
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
  if [ "$shell_usable" = 1 ]; then
    _osrc_atomic_mkdir "$TMP/old-gate"
  else
    if _osrc_atomic_mkdir "$TMP/old-gate" 2> "$TMP/old-gate.err"; then exit 1; fi
    [ ! -e "$TMP/old-gate" ] && grep -Fq "$shell_error" "$TMP/old-gate.err"
  fi
) || { echo 'FAIL: obsolete sibling gate still wedges an atomic mkdir'; exit 1; }
echo 'PASS: obsolete sibling gate does not change safe fallback behavior'

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
