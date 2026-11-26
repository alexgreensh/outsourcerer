#!/usr/bin/env bash
# lib_sigint.sh: a gate started as a background job of a non-interactive shell (`nohup bash
# conformance.sh &`) inherits SIGINT ignored. Bash can neither trap nor reset a signal ignored at
# entry, so every suite that asserts an INT trap would FAIL for a reason that is not its own.
# _osrc_sigint_restore re-execs the caller once with SIGINT at default through a python3 or perl
# shim (both only call sigaction + exec); with neither, the caller SKIPs those suites and says why.
_osrc_sigint_ignored() { [ "$(trap ':' INT; trap -p INT)" = "trap -- '' SIGINT" ]; }

# _osrc_sigint_restore "$@" -> returns 0 when SIGINT is usable, 1 when it stays ignored; on success
# with a shim it does not return (the script restarts with the same argv).
_osrc_sigint_restore() {
  if ! _osrc_sigint_ignored; then unset OSRC_SIGINT_REEXEC; return 0; fi
  [ -z "${OSRC_SIGINT_REEXEC:-}" ] || return 1   # already re-exec'd once and still ignored
  export OSRC_SIGINT_REEXEC=1
  if command -v python3 >/dev/null 2>&1; then
    exec python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' "${BASH:-bash}" "$0" "$@"
  fi
  if command -v perl >/dev/null 2>&1; then
    exec perl -e '$SIG{INT} = "DEFAULT"; exec { $ARGV[0] } @ARGV or die "exec: $!\n"' "${BASH:-bash}" "$0" "$@"
  fi
  return 1
}
