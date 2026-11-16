#!/bin/bash
# test_stderr_capture.sh -- _run_tee_stderr must (1) leave the errfile complete on return, (2) run the
# command in the CURRENT shell so a shell-function delegate's side effects survive (CI 43747039353),
# (3) keep stdout clean and the command's rc, (4) strip OSRC_JOB_DIR (L7), (5) stream stderr live, and
# (6) use nothing Windows Git Bash lacks (no FIFO). Pure bash, no engines.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/osrc"; HOME="$T/home"; OSRC_HOME="$T/osrc"; export HOME OSRC_HOME
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
[ ! -e "$f.fifo" ] && [ ! -e "$f.done" ] && ok "no helper files left behind" || bad "helper file left behind"

# Every stderr byte is echoed exactly once, in order (the pump's final pass, no duplicates, no loss).
: > "$f"; _run_tee_stderr "$f" delegate z 2>"$T/shown" >/dev/null
cmp -s "$f" "$T/shown" && ok "stderr echoed exactly once, byte-identical to the errfile" \
  || bad "echoed stderr differs from errfile ($(wc -l < "$T/shown") vs $(wc -l < "$f") lines)"

# LIVE: stderr reaches the caller's stderr WHILE the command still runs (the job log must grow, or the
# watchdog reads a codex-style stderr-only delegate as silent and kills it).
slow() { printf 'early\n' >&2; i=0; while [ $i -lt 30 ]; do [ -s "$T/live" ] && break; sleep 0.1; i=$((i+1)); done
         [ -s "$T/live" ] && LIVE=yes || LIVE=no; printf 'late\n' >&2; }
LIVE=""; : > "$T/live"; : > "$f"; _run_tee_stderr "$f" slow 2>"$T/live" >/dev/null
[ "$LIVE" = yes ] && ok "stderr is streamed live, before the command returns" || bad "stderr only appeared after return"
[ "$(cat "$T/live")" = "$(printf 'early\nlate')" ] && ok "live stream complete (early+late)" || bad "live stream: $(cat "$T/live")"

# An unwritable errfile must not block the delegate: it runs plain with its rc.
SIDE=""; _run_tee_stderr "$T/nodir/err" delegate w >/dev/null 2>&1; rc=$?
[ "$SIDE" = "ran:w" ] && [ "$rc" = 7 ] && ok "unwritable errfile: runs plain, rc kept" || bad "unwritable: side='$SIDE' rc=$rc"

# PORTABILITY (Windows Git Bash): no fifo, process substitution, /dev/fd, flock, setsid, fcntl or python
# anywhere in the bg-path modules.
_code="$(cat "$HERE/../lib/stderr-capture.sh" "$HERE/../lib/bg-pin.sh" | grep -v '^[[:space:]]*#')"
_hits="$(grep -nE 'mkfifo|setsid|flock|fcntl|/dev/fd|python|[<>]\(' <<<"$_code")"
[ -z "$_hits" ] && ok "bg-path modules use no mkfifo/setsid/flock/fcntl//dev/fd/python/proc-subst" || bad "forbidden primitive: $_hits"

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
