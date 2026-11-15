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
  # Last-resort shell-only gate. Fail closed if a killed creator leaves it.
  (
    umask 077
    local gate="$1.osrc-claim-gate"
    ( set -C; : > "$gate" ) 2>/dev/null || exit 1
    trap 'rm -f "$gate"' EXIT
    [ ! -e "$1" ] && [ ! -L "$1" ] || exit 1
    mkdir "$1" 2>/dev/null
  )
}
