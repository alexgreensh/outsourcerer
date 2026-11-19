#!/usr/bin/env bash
# test_windows_drive_script_path.sh — the engine invoked by a Windows drive path must resolve itself.
#
# Defect: SCRIPT_PATH treated only `/...` as absolute. Under Git Bash the skill (and most callers)
# invoke the engine as `C:/Users/.../outsourcerer.sh`, so it was rewritten to `$PWD/C:/Users/...`.
# Two consequences, both silent:
#   1. `for _osrc_lib in "$SCRIPT_DIR"/lib/*.sh` matched nothing, so not one lib was sourced.
#   2. Every self re-exec ("$SCRIPT_PATH" ...: the bg route preflight, the detached __runjob
#      supervisor) hit "No such file or directory", so `bg`/auto-detached runs failed with
#      "route preflight returned non-zero" / "supervisor not executable ... (nothing started)".
# Invoking via `/c/Users/...` worked, which is why it hid behind the POSIX-path test suites.
#
# The resolution logic is checked on every platform by evaluating the exact block from the engine;
# the end-to-end lib-load and _canon_path checks need a real drive path and run under Git Bash/MSYS.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TMP="$(mktemp -d)"
mkdir -p "$TMP/home"; export HOME="$TMP/home"   # never the real home (test_tests_set_home)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# The SCRIPT_PATH resolution block, verbatim from the engine (first assignment through its esac).
BLOCK="$(awk '/^SCRIPT_PATH="\$\(command -v/ {on=1} on {print} on && /^esac/ {exit}' "$SRC")"
[ -n "$BLOCK" ] || { echo "FAIL: SCRIPT_PATH block not found in $SRC"; exit 1; }

# resolve <argv0> -> SCRIPT_PATH as the engine computes it, from cwd $TMP.
resolve() { ( cd "$TMP" && bash -c "$BLOCK"'
printf "%s" "$SCRIPT_PATH"' "$1" ); }

check() { # check <label> <argv0> <expected>
  local got; got="$(resolve "$2")"
  [ "$got" = "$3" ] && ok "$1" || bad "$1: got '$got', want '$3'"
}
TMPP="$(cd "$TMP" && pwd)"
check "drive path with forward slashes stays as-is"  'C:/Users/x/outsourcerer.sh'  'C:/Users/x/outsourcerer.sh'
check "drive path with backslashes stays as-is"      'D:\tools\outsourcerer.sh'    'D:\tools\outsourcerer.sh'
check "POSIX absolute path stays as-is"              '/opt/osrc/outsourcerer.sh'   '/opt/osrc/outsourcerer.sh'
check "relative path is anchored at \$PWD"            'rel/outsourcerer.sh'         "$TMPP/rel/outsourcerer.sh"

if command -v cygpath >/dev/null 2>&1; then
  WIN_SRC="$(cygpath -m "$(cd "$(dirname "$SRC")" && pwd)/outsourcerer.sh")"
  case "$WIN_SRC" in [A-Za-z]:/*) ;; *) bad "cygpath -m did not give a drive path: $WIN_SRC" ;; esac

  # End to end: run the engine by its drive path from an unrelated cwd. The factory scripts locate
  # their own libs via BASH_SOURCE, so a lib count alone hides the defect; what proves it is the
  # engine's own loader seeing an UNEXPANDED `lib/*.sh` glob (it matched nothing) in xtrace.
  # Grep a file: a large here-string fed to an early-exiting grep deadlocks on Git Bash,
  # and `printf | grep -q` SIGPIPEs under pipefail.
  (cd "$TMP" && OSRC_HOME="$TMP/home" bash -x "$WIN_SRC" __no_such_subcommand) > "$TMP/trace" 2>&1
  if grep -qF "/lib/*.sh'" "$TMP/trace"; then
    bad "engine invoked by drive path: its lib/*.sh glob matched nothing (libs not sourced)"
  elif grep -qE '^\+ \. [A-Za-z]:/.*/scripts/lib/[A-Za-z0-9_-]+\.sh$' "$TMP/trace"; then
    ok "engine invoked by drive path sources its libs from the drive path"
  else
    bad "engine invoked by drive path: no lib load from the drive path seen in xtrace"
  fi

  # _canon_path must not prefix $PWD to a drive path either.
  set --
  OSRC_HOME="$TMP/home" . "$SRC" >/dev/null 2>&1
  trap cleanup EXIT
  mkdir -p "$TMP/canon"
  want="$(cd "$TMP/canon" && pwd -P)/leaf"
  got="$(cd / && _canon_path "$(cygpath -m "$TMP/canon")/leaf")"
  [ "$got" = "$want" ] && ok "_canon_path keeps a drive path absolute" || bad "_canon_path: got '$got', want '$want'"
else
  echo "SKIP: end-to-end drive-path checks need Git Bash/MSYS (cygpath)"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
