#!/usr/bin/env bash
# test_conformance_suite_timeout.sh — conformance.sh's per-suite wall-clock bound.
#
# A wedged suite must fail the gate loudly, not park it: one contributor run sat for 16+ hours on
# ~7 cores because a busy-spinning suite had no time bound. The bound is only worth something if
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
for fn in _suite_descendants _suite_kill_tree _run_unit_suite_bounded _report_unit_suite_result; do
  eval "$(sed -n '/^'"${fn}"'() {/,/^}/p' "$CONF")"
  type "$fn" >/dev/null 2>&1 || { echo "FAIL: could not extract $fn from $CONF"; exit 1; }
done
_SUITE_TIMEOUT_DEFAULT="$(sed -n 's/^_SUITE_TIMEOUT_DEFAULT=//p' "$CONF")"
case "$_SUITE_TIMEOUT_DEFAULT" in ''|*[!0-9]*) echo "FAIL: default bound missing in $CONF"; exit 1 ;; esac

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

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
# Incident shape: parent plus 3 forked children, all busy-spinning. Killing only the direct child
# leaves the spinners burning CPU for hours, so every pid must be recorded and re-checked.
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
  printf '%s\n' "$_suite_timed_out" "$_suite_rc" > "$W/result" ) & wrap=$!
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
unset OSRC_SUITE_TIMEOUT

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
