#!/usr/bin/env bash
# Do not trust external mkdir's status: some implementations accept EEXIST.
# Perl and Python expose the single atomic mkdir syscall without adding files
# to the directory, so existing rmdir-based releases and stale recovery work.
_osrc_atomic_mkdir() {
  if command -v perl >/dev/null 2>&1; then
    ( umask 077; perl -e 'mkdir $ARGV[0], 0700 or exit 1' "$1" ) 2>/dev/null && return 0
    [ ! -e "$1" ] && [ ! -L "$1" ] || return 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    ( umask 077; python3 -I -c 'import os,sys; os.mkdir(sys.argv[1], 0o700)' "$1" ) 2>/dev/null && return 0
    [ ! -e "$1" ] && [ ! -L "$1" ] || return 1
  fi
  # Only implementations known to use an exclusive mkdir syscall are safe.
  local version system
  system="$(uname -s 2>/dev/null)"
  case "$system" in
    Darwin|FreeBSD|OpenBSD|NetBSD|DragonFly) ( umask 077; /bin/mkdir "$1" ) 2>/dev/null; return $? ;;
  esac
  version="$(LC_ALL=C mkdir --version 2>/dev/null)" || version=""
  case "$version" in
    *uutils*|*Uutils*) printf 'outsourcerer: cannot claim %s: uutils mkdir requires working Perl or Python 3.\n' "$1" >&2; return 1 ;;
    *'GNU coreutils'*) ( umask 077; mkdir "$1" ) 2>/dev/null; return $? ;;
  esac
  printf 'outsourcerer: cannot claim %s: mkdir is not a known atomic implementation; install Perl or Python 3.\n' "$1" >&2
  return 1
}
