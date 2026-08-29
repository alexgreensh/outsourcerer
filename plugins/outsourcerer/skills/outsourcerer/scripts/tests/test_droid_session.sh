#!/usr/bin/env bash
# test_droid_session.sh — droid interactive-session MODEL-PIN GUARD. The bug: the droid session
# lane appended ("--model" "$resolved_model") to interactive `droid` on the strength of a comment
# asserting "interactive droid accepts --model too". That assertion was FALSE (verified against the
# live `droid --help`: the top-level CLI has NO -m/--model; it exists only under `droid exec`).
# Usage is `droid [options] [prompt...]`, so --model fell through into the PROMPT and the run
# proceeded on droid's DEFAULT model (claude-opus-5), silently billing Claude quota.
#
# This asserts the adapter now REFUSES a pinned-model droid session (naming the model flag in the
# reason) instead of appending --model, while a no-model droid session still launches on
# `droid --auto medium`. Runs the adapter in a subshell because _session_launch_error calls die
# (exit 1). Skips if droid is absent.
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

# --- pinned model: the adapter must REFUSE (die) naming the model flag, and must NOT append
#     --model/-m to the launch (which would fall through to the prompt and bill on the default).
#     Run in a subshell: _session_launch_error -> die -> exit 1 would otherwise kill the test. ---
PROVIDER=droid; MODEL_EXPLICIT=1; MODEL="claude-opus-5"; EFFORT=""
SESSION_LAUNCH=()
_err="$TMP/err"; _rc=0
( _session_launch_adapter droid ) >"$_err" 2>&1 || _rc=$?
if [ "$_rc" -ne 0 ]; then
  _msg="$(cat "$_err" 2>/dev/null)"
  case "$_msg" in
    *model*) ok "pinned model: adapter REFUSED a pinned-model droid session naming the model flag" ;;
    *) no "pinned model: adapter refused but did not name the model flag: '$_msg'" ;;
  esac
else
  no "pinned model: adapter WRONGLY launched a pinned-model droid session instead of refusing (the bug): rc=0"
fi

# --- no model: base launch is `droid --auto medium ...`, and NO model flag. Runs in the current
#     shell (it succeeds, so no die) so SESSION_LAUNCH propagates for inspection. ---
PROVIDER=droid; MODEL_EXPLICIT=0; MODEL=""; EFFORT=""
SESSION_LAUNCH=()
if _session_launch_adapter droid 2>"$TMP/err2"; then
  _joined="${SESSION_LAUNCH[*]:-}"
  case "$_joined" in *droid*--auto*medium*) ok "no model: base launch is 'droid --auto medium ...'" ;;
    *) no "no model: bad base launch: '$_joined'" ;; esac
  case "$_joined" in *--model*|*" -m "*) no "no model: unexpected model flag: '$_joined'" ;;
    *) ok "no model: launch has no model flag (interactive droid on its configured/default model)" ;; esac
else
  no "no model: adapter errored unexpectedly: $(cat "$TMP/err2" 2>/dev/null)"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
