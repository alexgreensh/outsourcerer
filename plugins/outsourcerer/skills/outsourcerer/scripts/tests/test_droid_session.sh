#!/usr/bin/env bash
# test_droid_session.sh — droid interactive-session PARITY. The bug: _session_launch_adapter
# demanded the model flag appear in the TOP-LEVEL `droid --help`, but droid documents `-m,--model`
# only under `droid exec --help`, so a pinned-model droid session was forced headless. This asserts
# the adapter now builds a real interactive launch WITH the model flag. Skips if droid is absent.
# Run: bash test_droid_session.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-droid.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home"; export OSRC_SOURCED=1; mkdir -p "$OSRC_HOME"
. "$SRC" >/dev/null 2>&1
type -t _session_launch_adapter >/dev/null || { echo "FAIL: _session_launch_adapter not loaded"; exit 1; }
if ! have droid; then echo "SKIP: droid not installed"; echo "RESULT: 0 passed, 0 failed"; exit 0; fi

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

# --- pinned model: build must be `droid --auto medium ... <model-flag> <model>` (no die) ---
PROVIDER=droid; MODEL_EXPLICIT=1; MODEL="claude-opus-5"; EFFORT=""
SESSION_LAUNCH=()
if _session_launch_adapter droid 2>/tmp/droid_err; then
  joined="${SESSION_LAUNCH[*]}"
  case "$joined" in *droid*--auto*medium*) ok "pinned model: base launch is 'droid --auto medium ...'" ;; *) no "pinned model: bad base launch: '$joined'" ;; esac
  case "$joined" in *"--model claude-opus-5"*|*"-m claude-opus-5"*) ok "pinned model: interactive model flag + model present" ;; *) no "pinned model: NO model flag (the bug): '$joined'" ;; esac
else
  no "pinned model: adapter errored (should launch): $(cat /tmp/droid_err 2>/dev/null)"
fi

# --- no model: base launch, and NO model flag ---
PROVIDER=droid; MODEL_EXPLICIT=0; MODEL=""; EFFORT=""
SESSION_LAUNCH=()
if _session_launch_adapter droid 2>/dev/null; then
  joined="${SESSION_LAUNCH[*]}"
  case "$joined" in *--model*|*" -m "*) no "no model: unexpected model flag: '$joined'" ;; *) ok "no model: launch has no model flag" ;; esac
else
  no "no model: adapter errored unexpectedly"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
