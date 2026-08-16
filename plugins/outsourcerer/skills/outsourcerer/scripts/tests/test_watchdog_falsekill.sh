#!/usr/bin/env bash
# test_watchdog_falsekill.sh — the reported watchdog false-kills (D1/D2 + research):
#   D2  a mutating (yolo/edit) job doing legit read-only investigation is SILENT and write-free for a
#       while before its first write. It must NOT be reaped faster than any other silent job — the
#       exploring? kill defaults to the tier stall window (kill_after), not a hard 180s. A genuinely
#       wedged (silent+writeless past the window) job must STILL be killed.
#   research  is read-only by design and must never be subject to the write-requirement exploring?
#       guard at all (v0.8.2 only half-exempted it).
#   D1  a slow cold-boot that is STILL emitting output past the no-init deadline must not be reaped.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

# D2-A (the reported bug): yolo, emit a progress line, silent 6s (read/reason) with NO writes, then done.
# warn=2 kill_after=100 hard=100, NO OSRC_NOWRITE_KILL -> nww_kill defaults to kill_after=100; 6s<100 -> SURVIVES.
A="$( TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"; mkdir -p "$OSRC_HOME/jobs"
  . "$SRC" >/dev/null 2>&1; OSRC_JOBS="$OSRC_HOME/jobs"; jd="$OSRC_JOBS/a"; mkdir -p "$jd"
  OSRC_JOB_VERB=yolo OSRC_NOWRITE_WARN=2 OSRC_POLL=1 \
    _supervise "$jd" 2 100 100 -- sh -c 'printf "%s\n" "OSRC::PROGRESS investigating"; sleep 6; printf "%s\n" "OSRC::DONE"' >/dev/null 2>&1
  printf '%s|%s' "$(cat "$jd/status" 2>/dev/null)" "$(cat "$jd/reason" 2>/dev/null)"; rm -rf "$TMP" )"
case "$A" in wedged*) bad "D2 false-kill: silent-before-write yolo was reaped ($A)";; *) ok "D2: a write-free yolo silent before its first write survives ($A)";; esac

# D2-B (regression guard): yolo, banner then silent forever, no writes, kill_after=3 -> nww_kill=3 -> KILLED.
B="$( TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"; mkdir -p "$OSRC_HOME/jobs"
  . "$SRC" >/dev/null 2>&1; OSRC_JOBS="$OSRC_HOME/jobs"; jd="$OSRC_JOBS/b"; mkdir -p "$jd"
  OSRC_JOB_VERB=yolo OSRC_NOWRITE_WARN=1 OSRC_POLL=1 \
    _supervise "$jd" 1 3 30 -- sh -c 'printf "%s\n" "OSRC::PROGRESS start"; sleep 30' >/dev/null 2>&1
  printf '%s|%s' "$(cat "$jd/status" 2>/dev/null)" "$(cat "$jd/reason" 2>/dev/null)"; rm -rf "$TMP" )"
case "$B" in wedged*) ok "D2: a genuinely silent+writeless yolo is still killed ($B)";; *) bad "D2 regression: a real wedge was NOT killed ($B)";; esac

# research: read-only, silent 6s, comfortable window -> never exploring-timeout (no longer 'mutating').
R="$( TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"; mkdir -p "$OSRC_HOME/jobs"
  . "$SRC" >/dev/null 2>&1; OSRC_JOBS="$OSRC_HOME/jobs"; jd="$OSRC_JOBS/r"; mkdir -p "$jd"
  OSRC_JOB_VERB=research OSRC_POLL=1 \
    _supervise "$jd" 2 100 100 -- sh -c 'printf "%s\n" "OSRC::PROGRESS grepping"; sleep 6; printf "%s\n" "OSRC::DONE"' >/dev/null 2>&1
  printf '%s|%s' "$(cat "$jd/status" 2>/dev/null)" "$(cat "$jd/reason" 2>/dev/null)"; rm -rf "$TMP" )"
case "$R" in *exploring-timeout) bad "research was killed by the exploring? guard it must be exempt from ($R)";; *) ok "research is exempt from the write-requirement exploring? guard ($R)";; esac

# D1: a cold-boot STILL emitting output past the no-init deadline (noinit=2) is alive -> not reaped.
# lines are launcher-prefixed ('>>> ') so they never count as model output; idle never reaches the
# silence floor (_ni_idle capped at noinit=2) between 1s prints -> survives, ends on its own.
D="$( TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"; mkdir -p "$OSRC_HOME/jobs"
  . "$SRC" >/dev/null 2>&1; OSRC_JOBS="$OSRC_HOME/jobs"; jd="$OSRC_JOBS/d"; mkdir -p "$jd"
  OSRC_JOB_VERB=run OSRC_NOINIT_SECS=2 OSRC_POLL=1 \
    _supervise "$jd" 100 100 100 -- sh -c 'for i in 1 2 3 4 5 6 7 8; do printf "%s\n" ">>> still booting $i"; sleep 1; done' >/dev/null 2>&1
  printf '%s|%s' "$(cat "$jd/status" 2>/dev/null)" "$(cat "$jd/reason" 2>/dev/null)"; rm -rf "$TMP" )"
case "$D" in *no-init*) bad "D1: a still-emitting cold-boot was falsely no-init-killed ($D)";; *) ok "D1: a cold-boot still emitting output past the deadline is not reaped ($D)";; esac

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
