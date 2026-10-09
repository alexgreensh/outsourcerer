#!/usr/bin/env bash
# test_conformance_suite_timeout.sh — conformance.sh's per-suite wall-clock bound.
#
# A wedged suite must fail the gate loudly, not park it: without a bound a busy-spinning suite
# would hold the gate indefinitely. The bound is only worth something if
# the kill reaches the suite's whole tree (forked racers and background jobs) and leaves nothing
# behind, so these cases drive the runner's real bounded-run function, extracted from
# conformance.sh itself rather than a paraphrase, against throwaway suites in a temp dir. That
# exercises the gate's loop logic without recursively running the full gate.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/conformance.sh"
[ -f "$CONF" ] || { echo "FAIL: cannot find $CONF"; exit 1; }
bash -n "$CONF" || { echo "FAIL: bash -n failed for $CONF"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# The extraction must be guarded: if a rename in conformance.sh leaves these empty, the cases
# below would pass against functions that were never loaded (or fail on an unbound variable), and
# nobody could tell which. The regex is single-quoted and spliced: on bash 3.2 a double-quoted
# "${fn}()" inside a command substitution is misparsed (the () reads as function-definition
# syntax) and sed receives a mangled script.
for fn in _suite_descendants _suite_kill_tree _suite_ppid_of _run_unit_suite_bounded _report_unit_suite_result; do
  eval "$(sed -n '/^'"${fn}"'() {/,/^}/p' "$CONF")"
  type "$fn" >/dev/null 2>&1 || { echo "FAIL: could not extract $fn from $CONF"; exit 1; }
done
_SUITE_TIMEOUT_DEFAULT="$(sed -n 's/^_SUITE_TIMEOUT_DEFAULT=//p' "$CONF")"
case "$_SUITE_TIMEOUT_DEFAULT" in ''|*[!0-9]*) echo "FAIL: default bound missing in $CONF"; exit 1 ;; esac

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Record what _suite_kill_tree is aimed at: the pidfile's two numbers ("PID PPID") must never be
# fused into one pid, or a post-timeout walk could be aimed at an unrelated process. The
# real implementation is kept intact under a new name; the wrapper only logs its argument.
_kt_log="$TMP/kt.log"; : > "$_kt_log"
KTBODY="$(declare -f _suite_kill_tree | sed 's/^_suite_kill_tree ()/_suite_kill_tree_impl ()/')"
case "$KTBODY" in _suite_kill_tree_impl*) eval "$KTBODY" ;; *) echo "FAIL: could not rename _suite_kill_tree for recording"; exit 1 ;; esac
_suite_kill_tree() { printf '%s\n' "$1" >> "$_kt_log"; _suite_kill_tree_impl "$@"; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

_cmd_of() { ps -o command= -p "$1" 2>/dev/null; }

# Spin-wait (no sleeps of our own, which would race the scan) until no descendant of the test
# shell looks like a leftover watchdog timer or suite process, for up to 5s.
_leftover_free() {
  local deadline=$(( SECONDS + 5 )) p cmd
  while :; do
    _leftover=""
    for p in $(_suite_descendants "$$"); do
      cmd="$(_cmd_of "$p")"
      case "$cmd" in
        *sleep*|*"$TMP"*) _leftover="$p:$cmd"; break ;;
      esac
    done
    [ -z "$_leftover" ] && return 0
    [ "$SECONDS" -ge "$deadline" ] && return 1
  done
}

# _report_unit_suite_result with the gate's ok/bad stubbed, so the report line and the failure
# count can be asserted without corrupting this suite's own tally.
_capture_report() {   # <suite-name>
  rm -f "$TMP/rep"
  ( ok()  { printf 'OK:%s\n' "$1" >> "$TMP/rep"; }
    bad() { printf 'BAD:%s\n' "$1" >> "$TMP/rep"; }
    _report_unit_suite_result "$1" ) 2>&1
}

# ------------------------------------------------------- 1. wedged suite: tree-kill + loud fail
W="$TMP/wedge"; mkdir -p "$W"
cat > "$W/wedged.sh" <<EOF
#!/usr/bin/env bash
# Parent plus 3 forked children, all busy-spinning. Killing only the direct child
# leaves the spinners running, so every pid must be recorded and re-checked.
spin() { while :; do :; done; }
P="$W"
spin & echo \$! >> "\$P/pids"
spin & echo \$! >> "\$P/pids"
spin & echo \$! >> "\$P/pids"
echo \$\$ >> "\$P/pids"
spin
EOF
: > "$W/pids"
# The scenario is itself bounded: if the bound regresses, this suite reports a failure and stops
# instead of hanging the gate it is supposed to protect.
( OSRC_SUITE_TIMEOUT=2 _run_unit_suite_bounded "$W/wedged.sh"
  printf '%s\n' "$_suite_timed_out" "$_suite_rc" > "$W/result" ) 2>"$W/werr" & wrap=$!
deadline=$(( SECONDS + 20 ))
while kill -0 "$wrap" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
if kill -0 "$wrap" 2>/dev/null; then
  bad "runner did not return after the 2s bound (it hung)"
  _suite_kill_tree "$wrap" 2>/dev/null
  wait "$wrap" 2>/dev/null
else
  wait "$wrap" 2>/dev/null
fi
if [ -f "$W/result" ]; then
  _t="$(sed -n '1p' "$W/result")"; _r="$(sed -n '2p' "$W/result")"
  [ "$_t" = 1 ] && ok "wedged suite flagged TIMED OUT" \
                || bad "wedged suite not flagged timed out (timed_out=$_t rc=$_r)"
  [ "$_r" -ne 0 ] && ok "timed-out suite counted as a failure (rc=$_r)" \
                  || bad "timed-out suite exited 0"
else
  bad "no result recorded from the wedged-suite run"
  _t=0; _r=0
fi
[ -s "$W/pids" ] || bad "wedged suite recorded no pids to check"
alive=0; deadline=$(( SECONDS + 5 ))
while :; do
  alive=0
  for p in $(cat "$W/pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && alive=1; done
  { [ "$alive" = 0 ] || [ "$SECONDS" -ge "$deadline" ]; } && break
  sleep 0.2
done
[ "$alive" = 0 ] && ok "no process from the wedged suite survived (all recorded pids dead)" \
                 || bad "processes from the wedged suite survived the kill: $(tr '\n' ' ' < "$W/pids")"
grep -q 'Terminated' "$W/werr" 2>/dev/null && bad "watchdog kill printed 'Terminated' noise into the log: $(head -1 "$W/werr")" \
                                       || ok "watchdog kill is silent (no 'Terminated' in the log)"
# Every kill-tree target must be a pid the suite itself recorded (root or descendants); the
# post-timeout walk must never aim at a glued "PID PPID" concatenation or any recycled pid.
kt_ok=1; kt_n=0
while IFS= read -r a; do
  [ -z "$a" ] && continue
  kt_n=$((kt_n+1))
  grep -Fqx "$a" "$W/pids" 2>/dev/null || kt_ok=0
done < "$_kt_log"
[ "$kt_n" -gt 0 ] || kt_ok=0
[ "$kt_ok" = 1 ] && ok "kill-tree targeted only real suite pids ($kt_n target(s): $(tr '\n' ' ' < "$_kt_log"))" \
                 || bad "kill-tree aimed at a pid outside the suite's recorded tree: $(tr '\n' ' ' < "$_kt_log")"
kt_root="$(sed -n '$p' "$W/pids")"
kt_last="$(tail -1 "$_kt_log")"
[ "$kt_last" = "$kt_root" ] && ok "the post-timeout walk targeted the suite root ($kt_root)" \
                             || bad "post-timeout walk targeted '$kt_last', expected the suite root $kt_root"
# Drive the report from the wedged run's real recorded state (the run happened in a subshell).
_suite_timed_out="$_t"; _suite_rc="$_r"; _suite_secs="2"; _suite_out=""
rep="$(_capture_report wedged)"; rep_f="$(cat "$TMP/rep")"
case "$rep_f" in
  *"BAD:unit suite wedged TIMED OUT after 2s"*)
    ok "gate reports: unit suite wedged TIMED OUT after 2s" ;;
  *) bad "gate report line wrong or missing: $(printf '%s' "$rep_f" | head -2 | tr '\n' '|')" ;;
esac
case "$rep_f" in
  *"unit suite wedged FAILED"*) bad "timeout was also mislabelled as an ordinary FAILED" ;;
  *) ok "timeout is not mislabelled as an ordinary FAILED" ;;
esac
printf 'FAIL: inner wedged evidence\n' > "$W/rep-expected"
_suite_out="$(cat "$W/rep-expected")"
rep="$(_capture_report wedged)"
case "$rep" in
  *"      FAIL: inner wedged evidence"*) ok "captured suite output tail is shown on a timeout" ;;
  *) bad "captured suite output tail not shown on a timeout: $(printf '%s' "$rep" | head -3 | tr '\n' '|')" ;;
esac

# ------------------------------------------------------- 2. passing suite: untouched by the bound
cat > "$TMP/passing.sh" <<'EOF'
#!/usr/bin/env bash
echo "hello from passing suite"
EOF
unset OSRC_SUITE_TIMEOUT
_run_unit_suite_bounded "$TMP/passing.sh"
[ "$_suite_rc" -eq 0 ] && ok "passing suite keeps rc 0" || bad "passing suite rc changed to $_suite_rc"
[ "$_suite_timed_out" -eq 0 ] && ok "passing suite not flagged timed out" \
                              || bad "passing suite wrongly flagged timed out"
case "$_suite_out" in *"hello from passing suite"*) ok "passing suite output captured intact" ;; *) bad "passing suite output lost: $_suite_out" ;; esac
# An odd bound value makes any leftover timer identifiable: only our watchdog sleeps exactly 37s.
OSRC_SUITE_TIMEOUT=37 _run_unit_suite_bounded "$TMP/passing.sh"
[ "$_suite_rc" -eq 0 ] || bad "passing suite rc changed under an explicit bound ($_suite_rc)"
if _leftover_free; then ok "no leftover sleep/watchdog/suite process after a suite finishes"
else bad "leftover process after a normal suite run: $_leftover"; fi

# ------------------------------------------------------- 3. failing suite: ordinary failure, not timeout
cat > "$TMP/failing.sh" <<'EOF'
#!/usr/bin/env bash
echo "FAIL: inner failure for the gate to surface"
exit 3
EOF
unset OSRC_SUITE_TIMEOUT
_run_unit_suite_bounded "$TMP/failing.sh"
[ "$_suite_rc" -eq 3 ] && ok "failing suite keeps its real exit code 3" \
                       || bad "failing suite rc is $_suite_rc, expected 3"
[ "$_suite_timed_out" -eq 0 ] && ok "failing suite not flagged timed out" \
                              || bad "ordinary failure wrongly flagged timed out"
rep="$(_capture_report failing)"; rep_f="$(cat "$TMP/rep")"
case "$rep_f" in
  *"BAD:unit suite failing FAILED"*) ok "gate reports an ordinary FAILED for rc 3" ;;
  *) bad "gate report line wrong or missing: $(printf '%s' "$rep_f" | head -2 | tr '\n' '|')" ;;
esac
case "$rep_f" in *"TIMED OUT"*) bad "ordinary failure mislabelled as TIMED OUT" ;; *) ok "no TIMED OUT label on an ordinary failure" ;; esac

# ------------------------------------------------------- 4. OSRC_SUITE_TIMEOUT: 0 and non-numeric
cat > "$TMP/slow.sh" <<'EOF'
#!/usr/bin/env bash
sleep 1
echo "slow suite done"
EOF
OSRC_SUITE_TIMEOUT=0 _run_unit_suite_bounded "$TMP/slow.sh"
[ "$_suite_rc" -eq 0 ] && [ "$_suite_timed_out" -eq 0 ] && ok "OSRC_SUITE_TIMEOUT=0 runs unbounded (1s suite passes)" \
                       || bad "OSRC_SUITE_TIMEOUT=0 did not run unbounded (rc=$_suite_rc timed_out=$_suite_timed_out)"
[ "$_suite_secs" = 0 ] || bad "resolved bound under 0 is $_suite_secs, expected 0"
OSRC_SUITE_TIMEOUT=abc _run_unit_suite_bounded "$TMP/slow.sh"
[ "$_suite_rc" -eq 0 ] && [ "$_suite_timed_out" -eq 0 ] && ok "non-numeric bound falls back to the default (1s suite passes)" \
                       || bad "non-numeric bound broke the run (rc=$_suite_rc timed_out=$_suite_timed_out)"
[ "$_suite_secs" = "$_SUITE_TIMEOUT_DEFAULT" ] && ok "non-numeric bound resolves to the default (${_SUITE_TIMEOUT_DEFAULT}s)" \
                       || bad "non-numeric bound resolved to $_suite_secs, expected $_SUITE_TIMEOUT_DEFAULT"
rep="$(_capture_report slow)"; rep_f="$(cat "$TMP/rep")"
case "$rep_f" in *"TIMED OUT after 0s"*) bad "report says TIMED OUT after 0s on the unbounded path" ;; *) ok "report never says TIMED OUT after 0s" ;; esac
case "$rep_f" in *"OK:unit suite slow green"*) ok "unbounded run reports green" ;; *) bad "unbounded run not reported green: $rep_f" ;; esac
unset OSRC_SUITE_TIMEOUT

# ------------------------------------------------- 5. INT disposition: suite traps must still work
# A background-job suite starts with SIGINT ignored at entry, and a shell cannot trap or reset a
# signal that was ignored there, so every INT trap in a suite or in the engine (_supervise, the
# obligation guard, the fifo streamer) would silently never install. This suite arms an INT trap
# and signals itself; it exits 1 exactly when the trap did not fire.
cat > "$TMP/int_trap.sh" <<'EOF'
#!/usr/bin/env bash
trap 'echo INT-TRAPPED; exit 0' INT
kill -INT $$
sleep 5
echo "trap did not fire"
exit 1
EOF
unset OSRC_SUITE_TIMEOUT
_run_unit_suite_bounded "$TMP/int_trap.sh"
[ "$_suite_rc" -eq 0 ] && ok "suite keeps default INT dispositions (self-trapped INT, rc 0)" \
                       || bad "suite INT trap did not fire through the runner (rc=$_suite_rc out=$_suite_out)"
case "$_suite_out" in *"INT-TRAPPED"*) ok "INT-TRAPPED observed in the suite's captured output" ;; *) bad "INT-TRAPPED missing from captured output: $_suite_out" ;; esac

# ------------------------------------------------- 6. mktemp failure: fail the suite, run nothing
# An unchecked 'mktemp -d' would leave OSRC_HOME empty and run the suite against the user's real
# ~/.outsourcerer. A counting stub fails on the second call (the OSRC_HOME allocation) and, after
# a reset, on the first (the capture file); the suite must never run in either case.
cat > "$TMP/mkprobe.sh" <<EOF
#!/usr/bin/env bash
echo ran > "$TMP/mk-ran"
EOF
REAL_MKTEMP="$(command -v mktemp)"
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/mktemp" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$STUB/count" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$STUB/count"
[ "\$n" -ge 2 ] && exit 1
exec "$REAL_MKTEMP" "\$@"
EOF
chmod +x "$STUB/mktemp"
rm -f "$TMP/mk-ran"
PATH="$STUB:$PATH" _run_unit_suite_bounded "$TMP/mkprobe.sh"
[ "$_suite_rc" -eq 127 ] || bad "OSRC_HOME mktemp failure did not report rc 127 (got $_suite_rc)"
[ -f "$TMP/mk-ran" ] && bad "suite RAN against an empty OSRC_HOME" \
                    || ok "suite never ran when the OSRC_HOME mktemp failed"
echo 1 > "$STUB/count"
PATH="$STUB:$PATH" _run_unit_suite_bounded "$TMP/mkprobe.sh"
[ "$_suite_rc" -eq 127 ] || bad "capture-file mktemp failure did not report rc 127 (got $_suite_rc)"
[ -f "$TMP/mk-ran" ] && bad "suite RAN with a broken temp allocator" \
                    || ok "suite never ran when the first mktemp failed"

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
