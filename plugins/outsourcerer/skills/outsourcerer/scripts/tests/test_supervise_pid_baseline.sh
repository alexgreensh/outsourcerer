#!/usr/bin/env bash
# test_supervise_pid_baseline.sh — a transient `ps` failure at spawn must not become a
# guaranteed kill of the watchdog's own healthy child one poll later (issue #60).
#
# Root cause this guards: _supervise recorded the delegate's start time for PID-reuse
# detection with an inline `ps -o lstart=` read, and on an empty result fell back to
# `_stime="${_stime:-$t0}"` — epoch digits. The in-loop guard reads `ps lstart` fresh each
# poll and string-compares; the first poll where ps recovers returns a real lstart string,
# which can never equal epoch digits, so the watchdog misread its own healthy child as a
# reused pid and killed the job instantly (rc=130, interrupted:pid-reuse). A one-shot ps
# outage at exactly spawn time became a guaranteed kill one poll later.
#
# Fix under test: unknown stays unknown. The spawn-time record and the in-loop read both go
# through _pid_start_identity; on a failed spawn read no baseline is stored (and no epoch
# placeholder is written to pid_start — every reader treats a missing record as "cannot
# tell", which fails safe), and the guard engages only once a genuine baseline exists,
# latching the first real lstart it can read (which also heals the on-disk record).
#
# Scenario B pins the other direction: a REAL pid reuse (live read returns a different,
# valid lstart than the recorded baseline) must still kill the job as interrupted:pid-reuse.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Honor an override so the same test can be run against an unpatched source to prove it
# catches the regression, without mutating the working tree.
SRC="${OSRC_TEST_SRC:-$SCRIPT_DIR/../outsourcerer.sh}"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"
export OSRC_HOME="$TMP" HOME="$TMP" OSRC_POLL=1
mkdir -p "$TMP/bin"
_REAL_PS="$(command -v ps)"
[ -n "$_REAL_PS" ] || { echo "FAIL: no real ps on PATH"; exit 1; }

# ps shim. Modes (OSRC_SHIM_MODE):
#   fail-first-N : the first OSRC_SHIM_FAILS lstart reads fail (empty stdout, rc 1) — a
#                  transient process-table hiccup at exactly spawn time; later reads pass through.
#   fake-after-N : the first OSRC_SHIM_FAILS lstart reads pass through; every later lstart
#                  read returns a VALID but fabricated lstart — a different process now holds
#                  the pid (real reuse).
#   fail-always  : every lstart read fails — a host whose ps cannot report lstart at all.
# Non-lstart ps calls always pass through.
cat > "$TMP/bin/ps" <<'SHIM'
#!/usr/bin/env bash
case " $* " in
  *lstart=*) ;;
  *) exec "$_REAL_PS" "$@" ;;
esac
n=$(cat "$OSRC_SHIM_COUNT" 2>/dev/null || echo 0)
n=$((n+1)); echo "$n" > "$OSRC_SHIM_COUNT"
case "$OSRC_SHIM_MODE" in
  fail-first-N)
    if [ "$n" -le "$OSRC_SHIM_FAILS" ]; then exit 1; fi
    ;;
  fake-after-N)
    if [ "$n" -gt "$OSRC_SHIM_FAILS" ]; then
      printf 'Mon Jan 1 00:00:01 2024\n'
      exit 0
    fi
    ;;
  fail-always)
    exit 1
    ;;
esac
exec "$_REAL_PS" "$@"
SHIM
chmod +x "$TMP/bin/ps"
export _REAL_PS OSRC_SHIM_COUNT="$TMP/pscount"
export PATH="$TMP/bin:$PATH"

_CHILD_PIDS=""
cleanup() {
  [ -n "$_CHILD_PIDS" ] && kill -KILL $_CHILD_PIDS 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Clear argv before sourcing: the engine dispatches on "$@", so any argument passed to
# this test would be interpreted as a subcommand and could abort the suite mid-run.
set --
. "$SRC" >/dev/null 2>&1
# Re-arm AFTER sourcing: the engine installs its own EXIT trap, which replaces this one.
trap cleanup EXIT

for fn in _supervise _pid_start_identity _pid_start_valid; do
  type "$fn" >/dev/null 2>&1 || { echo "FAIL: $fn not defined"; exit 1; }
done

# run_supervised <name> -> runs _supervise over a healthy child that sleeps ~2s and then
# leaves a marker; prints "<rc>". Fills globals: JD, MARKER.
run_supervised() {
  JD="$TMP/job-$1"; mkdir -p "$JD"
  MARKER="$TMP/marker-$1"
  : > "$OSRC_SHIM_COUNT"
  _supervise "$JD" 300 300 3600 -- bash -c 'sleep 2; : > "$OSRC_MARKER"' &
  local sup=$!
  wait "$sup"; local rc=$?
  _CHILD_PIDS="$_CHILD_PIDS $(cat "$JD/pid" 2>/dev/null)"
  return "$rc"
}
export OSRC_MARKER

# --- Scenario A: transient spawn-time outage must NOT false-kill (the issue #60 bug) ---
export OSRC_SHIM_MODE=fail-first-N OSRC_SHIM_FAILS=2 OSRC_MARKER="$TMP/marker-A"
run_supervised A; rc=$?
if [ "$rc" != "130" ] && [ "$(cat "$JD/reason" 2>/dev/null)" != "interrupted:pid-reuse" ]; then
  ok "transient spawn-time ps failure: healthy child NOT killed as interrupted:pid-reuse (rc=$rc)"
else
  bad "transient spawn-time ps failure: job killed as interrupted:pid-reuse (rc=$rc) — issue #60"
fi
if [ -f "$TMP/marker-A" ]; then
  ok "transient spawn-time ps failure: child ran to completion"
else
  bad "transient spawn-time ps failure: child never completed"
fi
# The first successful in-loop read must latch the baseline and heal the on-disk record:
# pid_start holds a real, valid lstart — never epoch digits.
_rec="$(cat "$JD/pid_start" 2>/dev/null)"
if [ -z "$_rec" ]; then
  bad "pid_start empty/absent after ps recovered — latch did not heal the record"
elif _pid_start_valid "$_rec"; then
  ok "baseline latched and pid_start healed with a real lstart record"
else
  case "$_rec" in
    *[!0-9]*) bad "pid_start holds a non-lstart record after recovery: '$_rec'" ;;
    *)        bad "pid_start holds bare epoch digits '$_rec' — the #60 placeholder is back" ;;
  esac
fi

# --- Scenario B: REAL pid reuse must still kill (guard not neutered) ---
export OSRC_SHIM_MODE=fake-after-N OSRC_SHIM_FAILS=2 OSRC_MARKER="$TMP/marker-B"
run_supervised B; rc=$?
if [ "$rc" = "130" ] && [ "$(cat "$JD/reason" 2>/dev/null)" = "interrupted:pid-reuse" ]; then
  ok "genuine pid reuse still detected: rc=130 interrupted:pid-reuse"
else
  bad "genuine pid reuse NOT detected (rc=$rc reason=$(cat "$JD/reason" 2>/dev/null)) — guard regressed"
fi

# --- Scenario C: persistent lstart outage — guard never engages, no false kill ---
export OSRC_SHIM_MODE=fail-always OSRC_SHIM_FAILS=0 OSRC_MARKER="$TMP/marker-C"
run_supervised C; rc=$?
if [ "$rc" != "130" ] && [ "$(cat "$JD/reason" 2>/dev/null)" != "interrupted:pid-reuse" ]; then
  ok "persistent ps outage: job completes, guard never engages (rc=$rc)"
else
  bad "persistent ps outage: job killed as interrupted:pid-reuse (rc=$rc)"
fi
if [ -f "$TMP/marker-C" ]; then
  ok "persistent ps outage: child ran to completion"
else
  bad "persistent ps outage: child never completed"
fi

# --- Scenario D: no outage at all — normal supervision unaffected ---
export OSRC_SHIM_MODE=fail-first-N OSRC_SHIM_FAILS=0 OSRC_MARKER="$TMP/marker-D"
run_supervised D; rc=$?
if [ "$rc" != "130" ] && [ -f "$TMP/marker-D" ]; then
  ok "no outage: healthy child supervised normally (rc=$rc)"
else
  bad "no outage: healthy child disturbed (rc=$rc reason=$(cat "$JD/reason" 2>/dev/null))"
fi
# With no outage the baseline is recorded at spawn, exactly as before.
if _pid_start_valid "$(cat "$JD/pid_start" 2>/dev/null)"; then
  ok "no outage: pid_start recorded at spawn in canonical form"
else
  bad "no outage: pid_start not recorded at spawn"
fi

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
