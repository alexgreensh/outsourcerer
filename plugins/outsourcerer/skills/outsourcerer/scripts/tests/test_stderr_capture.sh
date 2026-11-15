#!/bin/bash
# test_stderr_capture.sh -- _run_tee_stderr must (1) leave the errfile complete on return, (2) run the
# command in the CURRENT shell so a shell-function delegate's side effects survive (CI 43747039353),
# (3) keep stdout clean and the command's rc, (4) strip OSRC_JOB_DIR (L7). Pure bash, no engines.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
# shellcheck source=/dev/null
. "$HERE/../lib/spend.sh" >/dev/null 2>&1 || true
type _osrc_nojob >/dev/null 2>&1 || { echo "FAIL: _osrc_nojob not loaded from lib/spend.sh"; exit 1; }
. "$HERE/../lib/stderr-capture.sh"

f="$T/err"
SIDE=""; delegate() { SIDE="ran:$*"; printf 'OUT\n'; i=0; while [ $i -lt 400 ]; do printf 'err line %s\n' "$i" >&2; i=$((i+1)); done; return 7; }
: > "$f"; out="$(_run_tee_stderr "$f" delegate a b 2>/dev/null)"; rc=$?
[ "$rc" = 7 ] && ok "command rc kept" || bad "rc=$rc, want 7"
[ "$out" = "OUT" ] && ok "stdout untouched (stderr not mixed in)" || bad "stdout: $out"
[ "$(wc -l < "$f" | tr -d ' ')" = 400 ] && ok "errfile complete on return" || bad "errfile has $(wc -l < "$f") lines"
[ ! -e "$f.fifo" ] && ok "fifo removed" || bad "fifo left behind"

SIDE=""; : > "$f"; _run_tee_stderr "$f" delegate x >/dev/null 2>&1
[ "$SIDE" = "ran:x" ] && ok "runs in the current shell (side effect kept)" || bad "side effect lost: '$SIDE'"

seen=""; jobprobe() { seen="${OSRC_JOB_DIR-unset}"; }
OSRC_JOB_DIR=/x; export OSRC_JOB_DIR; : > "$f"; _run_tee_stderr "$f" jobprobe 2>/dev/null
[ "$seen" = unset ] && ok "OSRC_JOB_DIR stripped for the delegate" || bad "delegate saw OSRC_JOB_DIR=$seen"
[ "${OSRC_JOB_DIR-}" = /x ] && ok "OSRC_JOB_DIR restored after" || bad "caller lost OSRC_JOB_DIR"
unset OSRC_JOB_DIR

SIDE=""; _run_tee_stderr "" delegate y >/dev/null 2>&1; rc=$?
[ "$SIDE" = "ran:y" ] && [ "$rc" = 7 ] && ok "empty errfile: plain in-process run" || bad "plain run: side='$SIDE' rc=$rc"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
