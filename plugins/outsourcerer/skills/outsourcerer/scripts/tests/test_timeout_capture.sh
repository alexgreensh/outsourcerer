#!/usr/bin/env bash
# test_timeout_capture.sh : a fast `_timeout` child must not cost the full bound,
# and a reaped watchdog must not leave its timer process behind.
#
# The diagnosed failure: the watchdog subshell inherited the caller's
# stdout/stderr. `kill` reaped the subshell but ORPHANED its `sleep`, and the
# orphan held a captured or piped stdout open until the bound elapsed, so every
# `x="$(_timeout N ...)"` measured N seconds (5.03s on bash 3.2 for N=5),
# which is what pushed the lane-down TTL 10s late in CI.
#
# The second pin: the orphaned `sleep` itself. Even with its output detached it
# still burns the rest of the bound as a child of init: one orphan per fast
# call. _timeout must kill its timer, not just its watchdog shell.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

FIXTURE="$(mktemp -d "$PWD/.test-timeout-capture.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
export OSRC_HOME="$FIXTURE/home"
mkdir -p "$OSRC_HOME"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

set --; . "$SRC" >/dev/null 2>&1

# --- captured fast call returns well under the bound ---
SECONDS=0
x="$(_timeout 5 true)"
[ "$SECONDS" -lt 3 ] \
  && ok "captured \`_timeout 5 true\` returns in ${SECONDS}s (<3s), not the bound" \
  || bad "captured _timeout took ${SECONDS}s, the watchdog still holds the caller's pipe open"

# --- captured output survives the private file round-trip ---
out="$(_timeout 5 echo hello)"
[ "$out" = hello ] \
  && ok "captured output is intact" \
  || bad "captured output mangled: '$out'"

# --- piped form gets the same treatment ---
out="$(_timeout 5 echo hi | cat)"
[ "$out" = hi ] \
  && ok "piped _timeout output is intact" \
  || bad "piped output mangled: '$out'"

# --- the bound still fires: rc=124, and the child does not outrun its kill ---
SECONDS=0
_timeout 2 sleep 30 >/dev/null 2>&1; rc=$?
[ "$rc" = 124 ] && [ "$SECONDS" -lt 8 ] \
  && ok "the bound still fires: rc=124 in ${SECONDS}s, child reaped" \
  || bad "bound misfired: rc=$rc elapsed=${SECONDS}s"

# --- no stray timer sleep survives a fast call ---
# The child sleeps 0.5s so the watchdog is deterministically inside `sleep`
# when it is reaped. With an instant child the kill can land before the timer
# even execs, which makes this check racy. A duration nobody else plausibly
# launches pins the scan to THIS call. The leaked sleep reparents to init when
# its watchdog subshell dies, so a literal child-of-$$ check can never see it,
# scan the whole table, and ALSO check direct children so a future structure
# that leaves the timer as our own child is caught the same way. `ps -ef` is
# what _descendants itself falls back to when pgrep is absent: same layout
# caveat, same availability story on Git Bash.
STRAY_SECS=44.4
SECONDS=0
x="$(_timeout "$STRAY_SECS" sleep 0.5)"
[ "$SECONDS" -lt 5 ] \
  && ok "a captured call returns when its CHILD exits (${SECONDS}s), not when the bound does" \
  || bad "captured call stalled ${SECONDS}s, an orphan is still holding the pipe"
sleep 1
scan="$(ps -ef 2>/dev/null | awk -v pp="$$" -v s="$STRAY_SECS" '
  NR==1 { for(i=1;i<=NF;i++){u=toupper($i); if(u=="PID")pc=i; else if(u=="PPID")ppc=i} next }
  pc {
    if ($NF==s && $(NF-1) ~ /(^|\/)sleep$/) stray=stray" "$pc
    if (ppc && $ppc==pp && ($NF ~ /(^|\/)sleep$/ || $(NF-1) ~ /(^|\/)sleep$/)) own=own" "$pc
  }
  END { print "stray:" stray; print "own:" own }')"
if [ -z "$scan" ]; then
  echo "SKIP: process table unreadable here; stray-sleep leak check not exercised"
else
  stray="$(printf '%s\n' "$scan" | sed -n 's/^stray: *//p')"
  own="$(printf '%s\n' "$scan" | sed -n 's/^own: *//p')"
  [ -z "$stray" ] \
    && ok "no \`sleep $STRAY_SECS\` survives a fast call (timer killed, not orphaned to init)" \
    || bad "orphan timer sleep leaked per call: pids$stray"
  [ -z "$own" ] \
    && ok "no stray sleep left as a child of the test shell" \
    || bad "stray sleep child(ren) of the test shell: pids$own"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
