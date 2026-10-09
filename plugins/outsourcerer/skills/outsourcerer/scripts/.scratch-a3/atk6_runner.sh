#!/usr/bin/env bash
# atk6_runner: drive hostile suites through the real _run_unit_suite_bounded
# (extracted verbatim from conformance.sh into runner_extract.sh).
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
SCR="$D/suites"; mkdir -p "$SCR"
have() { command -v "$1" >/dev/null 2>&1; }
pass=0; fail=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }
note() { echo "NOTE: $1"; }
. "$D/runner_extract.sh"

mk() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SCR/$1"; chmod +x "$SCR/$1"; }

echo "== suite daemonizes a grandchild (double fork) then exits 0 =="
mk daemon.sh 'bash -c "sleep 61.47 </dev/null >/dev/null 2>&1 &"; exit 0'
OSRC_SUITE_TIMEOUT=10 _run_unit_suite_bounded "$SCR/daemon.sh"
echo "rc=$_suite_rc timed_out=$_suite_timed_out"
[ "$_suite_rc" = 0 ] && [ "$_suite_timed_out" = 0 ] \
  && ok "daemonizing suite still passes (rc=0)" \
  || bad "daemonizing suite misjudged (rc=$_suite_rc out=$_suite_timed_out)"
daemon_live="$(ps -eo pid=,ppid=,command= | awk '$2==1 && /61.47/ {print $1}')"
[ -n "$daemon_live" ] && note "daemonized grandchild survives past suite end (pid $daemon_live, reparented): pre-existing orphan class" && kill -KILL $daemon_live 2>/dev/null

echo "== suite exits before pidfile write (immediate exit) =="
mk fast.sh 'exit 3'
OSRC_SUITE_TIMEOUT=10 _run_unit_suite_bounded "$SCR/fast.sh"
[ "$_suite_rc" = 3 ] && [ "$_suite_timed_out" = 0 ] \
  && ok "instant-exit suite keeps its own rc=3 (no timeout verdict)" \
  || bad "instant exit: rc=$_suite_rc timed_out=$_suite_timed_out"

echo "== suite printing ~50MB =="
mk big.sh 'yes ABCDEFGHIJKLMNOP | head -c 50000000; exit 0'
SECONDS=0; OSRC_SUITE_TIMEOUT=60 _run_unit_suite_bounded "$SCR/big.sh"
[ "$_suite_rc" = 0 ] && ok "50MB suite output captured, rc=0 in ${SECONDS}s (out bytes=${#_suite_out})" \
  || bad "50MB suite: rc=$_suite_rc"

echo "== suite name/path with spaces =="
mkdir -p "$SCR/dir with space"; cp "$SCR/fast.sh" "$SCR/dir with space/my suite.sh"
OSRC_SUITE_TIMEOUT=10 _run_unit_suite_bounded "$SCR/dir with space/my suite.sh"
[ "$_suite_rc" = 3 ] && ok "suite at a spaced path runs (rc=3)" || bad "spaced path: rc=$_suite_rc"

echo "== OSRC_SUITE_TIMEOUT=1 vs a 0.6s suite x20 (boundary race) =="
mk under.sh 'sleep 0.6; exit 0'
to=0; badrc=0
for i in $(seq 1 20); do
  OSRC_SUITE_TIMEOUT=1 _run_unit_suite_bounded "$SCR/under.sh"
  [ "$_suite_timed_out" = 1 ] && to=$((to+1))
  [ "$_suite_rc" != 0 ] && badrc=$((badrc+1))
done
echo "  timeouts=$to rc-not-0=$badrc (want 0/0)"
[ "$to" = 0 ] && [ "$badrc" = 0 ] && ok "sub-bound suite never misjudged in 20 runs" || bad "boundary: timeouts=$to badrc=$badrc"

echo "== OSRC_SUITE_TIMEOUT=1 vs a 3s suite: must time out, tree killed =="
mk wedged.sh 'sleep 61.48 & echo "spawned=$!" > "$1"; sleep 61.49' _ "$SCR/wedged.marks"
rm -f "$SCR/wedged.marks"
OSRC_SUITE_TIMEOUT=1 _run_unit_suite_bounded "$SCR/wedged.sh"
[ "$_suite_timed_out" = 1 ] && [ "$_suite_rc" = 124 ] \
  && ok "wedged suite times out with rc=124" || bad "wedged suite: rc=$_suite_rc out=$_suite_timed_out"
sleep 2
for f in 61.48 61.49; do
  left="$(ps -eo pid=,command= | awk -v s="$f" '$NF==s && $(NF-1) ~ /sleep$/ {print $1}')"
  [ -z "$left" ] && ok "no leftover sleep $f from wedged suite" || { bad "leftover sleep $f: $left"; kill -KILL $left 2>/dev/null; }
done

echo "== TMPDIR with spaces =="
td="$(mktemp -d)/sub dir"; mkdir -p "$td"
TMPDIR="$td" OSRC_SUITE_TIMEOUT=10 _run_unit_suite_bounded "$SCR/fast.sh"
[ "$_suite_rc" = 3 ] && ok "TMPDIR with spaces works (rc=3)" || bad "TMPDIR spaces: rc=$_suite_rc out=$_suite_out"

echo "== TMPDIR non-writable =="
nw="$(mktemp -d)/nw"; mkdir -p "$nw"; chmod 555 "$nw"
TMPDIR="$nw" OSRC_SUITE_TIMEOUT=10 _run_unit_suite_bounded "$SCR/fast.sh"
echo "rc=$_suite_rc timed_out=$_suite_timed_out"
[ "$_suite_rc" != 0 ] && ok "non-writable TMPDIR fails loudly (rc=$_suite_rc)" || note "non-writable TMPDIR: rc=$_suite_rc"
chmod 755 "$nw"

echo "== two runners at once (no shared temp names) =="
mk slow.sh 'sleep 0.5; exit 0'
OSRC_SUITE_TIMEOUT=10 _run_unit_suite_bounded "$SCR/slow.sh" &
r1=$!
OSRC_SUITE_TIMEOUT=10 _run_unit_suite_bounded "$SCR/slow.sh" &
r2=$!
wait $r1 $r2 2>/dev/null
ok "two concurrent bounded runs completed"

echo "== INT mid-suite kills the suite tree (gate trap) =="
mk intwedged.sh 'sleep 61.51 & wait'
( OSRC_SUITE_TIMEOUT=60 _run_unit_suite_bounded "$SCR/intwedged.sh"; echo "gate_rc=$?" > "$SCR/int.rc" ) &
gp=$!
sleep 1
kill -INT "$gp" 2>/dev/null
sleep 2
[ -f "$SCR/int.rc" ] && echo "  $(cat "$SCR/int.rc")" || note "gate still running after INT? gate_alive=$(kill -0 $gp 2>/dev/null && echo Y || echo N)"
left="$(ps -eo pid=,command= | awk '$NF=="61.51" && $(NF-1) ~ /sleep$/ {print $1}')"
[ -z "$left" ] && ok "INT sweep left no sleep 61.51" || { bad "INT leaked sleep 61.51: $left"; kill -KILL $left 2>/dev/null; }
kill "$gp" 2>/dev/null; wait "$gp" 2>/dev/null

echo "----"
echo "RESULT: $pass passed, $fail failed"
