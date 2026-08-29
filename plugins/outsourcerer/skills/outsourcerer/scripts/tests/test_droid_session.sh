#!/usr/bin/env bash
# test_droid_session.sh — droid interactive-session EXEC-FLAG LEAK guards. TWO bugs in the same
# block, same root cause: the interactive launch was assembled from the EXEC flag set.
#
# BUG 1 (model): the lane appended ("--model" "$resolved_model") to interactive `droid` on the
# strength of a comment asserting "interactive droid accepts --model too". FALSE (verified against
# the live `droid --help`: top-level has NO -m/--model; it exists only under `droid exec`).
# `droid [options] [prompt...]` -> --model fell through into the PROMPT and the run proceeded on
# droid's DEFAULT model (claude-opus-5), silently billing Claude quota.
#
# BUG 2 (effort): the lane appended ("-r" "$de") for reasoning effort. FALSE at the top level:
# `droid --help` documents `-r, --resume [sessionId]` (Resume a session), NOT reasoning effort.
# `-r, --reasoning-effort <level>` exists ONLY under `droid exec --help`. So
# `droid --auto medium -r high` tried to RESUME a session named "high", found none, and EXITED
# SILENTLY TO A BARE SHELL with exit code 0 and no error — an invisible non-start. _droid_effort
# emits off/none/low/medium/high, none of which is ever a real session id.
#
# This asserts the adapter now REFUSES a pinned-model AND an explicit-effort droid session (naming
# the flag in the reason) instead of appending either, while a bare droid session still launches on
# `droid --auto medium` with NO -r and NO --model. Runs the adapter in a subshell because
# _session_launch_error calls die (exit 1). Skips if droid is absent.
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

# --- BUG 1: pinned model must REFUSE, naming the model flag. Subshell (die -> exit 1). ---
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
  no "pinned model: adapter WRONGLY launched a pinned-model droid session instead of refusing (bug 1): rc=0"
fi

# --- BUG 2: explicit effort must REFUSE, naming resume/effort. Subshell (die -> exit 1). ---
PROVIDER=droid; MODEL_EXPLICIT=0; MODEL=""; EFFORT="high"
SESSION_LAUNCH=()
_err="$TMP/err3"; _rc=0
( _session_launch_adapter droid ) >"$_err" 2>&1 || _rc=$?
if [ "$_rc" -ne 0 ]; then
  _msg="$(cat "$_err" 2>/dev/null)"
  case "$_msg" in
    *resume*|*effort*|*-r*) ok "explicit effort: adapter REFUSED an --effort droid session naming the -r/resume collision" ;;
    *) no "explicit effort: adapter refused but did not name the -r/resume/effort reason: '$_msg'" ;;
  esac
else
  no "explicit effort: adapter WRONGLY launched an --effort droid session instead of refusing (bug 2): rc=0"
fi

# --- no model, no effort: base launch is `droid --auto medium ...` with NO -r and NO --model.
#     Runs in the current shell (it succeeds, so no die) so SESSION_LAUNCH propagates. ---
PROVIDER=droid; MODEL_EXPLICIT=0; MODEL=""; EFFORT=""
SESSION_LAUNCH=()
if _session_launch_adapter droid 2>"$TMP/err2"; then
  _joined="${SESSION_LAUNCH[*]:-}"
  case "$_joined" in *droid*--auto*medium*) ok "no model/effort: base launch is 'droid --auto medium ...'" ;;
    *) no "no model/effort: bad base launch: '$_joined'" ;; esac
  case "$_joined" in *--model*|*" -m "*) no "no model/effort: unexpected model flag: '$_joined'" ;;
    *) ok "no model/effort: launch has no model flag" ;; esac
  # The bug-2 leak: -r must NEVER appear in an interactive droid launch (it means RESUME at the
  # top level, not effort; an effort value would be treated as a session id to resume).
  case "$_joined" in *" -r "*|*" --resume"*) no "no model/effort: launch LEAKED -r/--resume (bug 2): '$_joined'" ;;
    *) ok "no model/effort: launch has no -r/--resume (effort/resume collision closed)" ;; esac
else
  no "no model/effort: adapter errored unexpectedly: $(cat "$TMP/err2" 2>/dev/null)"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
