#!/usr/bin/env bash
# test_supervise_pgroup_kill.sh — the _supervise watchdog must actually REAP a wedged
# delegate whose grandchild ignores SIGTERM and re-parents to PID 1 when its parent dies.
#
# Root cause this guards: _supervise launched its delegate in the supervisor's own
# process group and tore the tree down with _kill_tree, which walks via ppid
# (_descendants / pgrep -P) and re-snapshots AFTER the TERM pass to decide what to
# SIGKILL. A grandchild immune to SIGTERM survives the TERM pass; its parent dies on
# TERM; the grandchild re-parents to PID 1 and leaves the tree; the KILL pass's second
# _descendants snapshot never re-discovers it — so it keeps its inherited socket/file
# and the stall-kill floor never reaps. Incident (2026-08-24): a wedged `devin acp`
# held an ESTABLISHED TCP to the model backend for 4h21m (15,660s), 8.7x past the 1800s
# devin stall-kill floor, while the watchdog believed it had killed the job.
#
# Fix under test: _supervise launches the delegate as its own process-group leader
# (set -m, portable — macOS ships no setsid) and records the PGID in <job-dir>/pgid;
# _kill_job kills the whole group by negative PGID (TERM -> grace -> KILL), which
# reaches every member regardless of reparenting, since PGID membership does not change
# when a process is re-parented. SIGKILL on the group cannot be caught, so a grandchild
# that ignored SIGTERM still dies.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Honor an override so the same test can be run against an unpatched source to prove it
# catches the regression, without mutating the working tree.
SRC="${OSRC_TEST_SRC:-$SCRIPT_DIR/../outsourcerer.sh}"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"
export OSRC_HOME="$TMP"
export HOME="$TMP"
_REAP_PIDS=""
cleanup() {
  # Never leak a wedged `sleep 600` grandchild if an assertion aborts mid-run.
  [ -n "$_REAP_PIDS" ] && kill -KILL $_REAP_PIDS 2>/dev/null || true
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
# Re-arm AFTER sourcing: the engine installs its own EXIT trap, which replaces this one
# and would leak the temp dir (and any wedged grandchild) per run.
trap cleanup EXIT

for fn in _kill_tree _kill_process_group _supervise; do
  type "$fn" >/dev/null 2>&1 || { echo "FAIL: $fn not defined"; exit 1; }
done
# _kill_job is the fix's helper; it is absent in the unpatched source. The source-level
# check below reports its absence as a FAIL, but the runtime wedge test must still run
# so the surviving-grandchild regression is demonstrated against the old code too.
_have_kill_job=0; type _kill_job >/dev/null 2>&1 && _have_kill_job=1

# A process is gone once it no longer exists OR is a zombie awaiting reaping. kill -0 is
# true for a zombie, so the state must be checked too. Used for the grandchild liveness
# assertion that is the heart of this test.
_proc_gone() {   # <pid> -> 0 if dead/gone/zombie
  local p="$1" st
  kill -0 "$p" 2>/dev/null || return 0
  st="$(ps -o stat= -p "$p" 2>/dev/null | tr -d '[:space:]')"
  case "$st" in ''|Z*) return 0 ;; esac
  return 1
}

# Poll for reaping: launchd/init reaps an orphaned zombie asynchronously, so a SIGKILL'd
# grandchild can read as a live zombie for a fraction of a second before it vanishes.
# Wait briefly for that reap before declaring it a survivor.
_wait_gone() {   # <pid> -> 0 if gone within ~2s, 1 if still live
  local p="$1" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    _proc_gone "$p" && return 0
    sleep 0.2
  done
  return 1
}

# ------------------------------------------------------------- SOURCE-LEVEL
# _kill_job exists and routes through the process-group killer (with a tree-walk
# fallback for job dirs that have no isolated PGID on record).
if [ "$_have_kill_job" = "1" ] && grep -aqE '^_kill_job\(\)' "$SRC"; then
  ok "source: _kill_job helper is defined"
else
  bad "source: _kill_job helper missing"
fi
# Capture function bodies in variables rather than piping awk -> grep: under
# `set -o pipefail`, `grep -q` closing the pipe early sends SIGPIPE to awk (rc=141),
# which makes the pipeline fail even when the pattern IS present.
_killjob_body="$(awk '/^_kill_job\(\)/{f=1} f{print} f&&/^}/{exit}' "$SRC" 2>/dev/null)"
printf '%s' "$_killjob_body" | grep -q _kill_process_group \
  && ok "source: _kill_job routes through _kill_process_group" \
  || bad "source: _kill_job does not call _kill_process_group"
# _supervise records an isolated PGID for the job and uses _kill_job on every exit arm.
_supervise_body="$(awk '/^_supervise\(\)/{f=1} f{print} f&&/^}/{exit}' "$SRC" 2>/dev/null)"
printf '%s' "$_supervise_body" | grep -aq '\$jd/pgid' \
  && ok "source: _supervise records the delegate PGID in \$jd/pgid" \
  || bad "source: _supervise does not record a job PGID"
printf '%s' "$_supervise_body" | grep -aq '_kill_job "\$jd" "\$pid"' \
  && ok "source: _supervise tear-down uses _kill_job (not a bare _kill_tree)" \
  || bad "source: _supervise still tears down with _kill_tree directly"
# The portable isolation primitive is `set -m`, not setsid (macOS ships none).
printf '%s' "$_supervise_body" | grep -aq 'set -m' \
  && ok "source: _supervise isolates the delegate via set -m (portable, no setsid)" \
  || bad "source: _supervise does not use set -m for process-group isolation"
# No _kill_tree "$pid" should remain inside _supervise (the whole point of the fix).
if printf '%s' "$_supervise_body" | grep -aq '_kill_tree "\$pid"'; then
  bad "source: a direct _kill_tree \"\$pid\" survives inside _supervise — kill can still miss the grandchild"
else
  ok "source: no direct _kill_tree \"\$pid\" remains inside _supervise"
fi

# --------------------------------------------- WEDGE: TERM-immune grandchild
# The delegate spawns a grandchild that IGNORES SIGTERM/INT and outlives its parent,
# then parks on `wait`. The delegate itself dies on SIGTERM (default disposition), which
# orphans the grandchild to PID 1 — exactly the incident's `devin -p` -> `devin acp`
# shape. Only a process-group SIGKILL can reach the grandchild once it has re-parented
# out of the ppid tree. The grandchild records its own pid, pgid, and start time so the
# assertion can distinguish "our grandchild, still alive" from a recycled PID.
GRANDCHILD="$TMP/wedge-grandchild.sh"
cat > "$GRANDCHILD" <<'EOF'
#!/usr/bin/env bash
# A wedged backend holder: ignore the graceful signals a tree walk sends first, write
# identifying state, then hold a pretend socket forever. SIGKILL is the only way out.
trap '' TERM
trap '' INT
gp="$1"; gg="$2"; gs="$3"
printf '%s\n' "$$" > "$gp"
printf '%s\n' "$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]')" > "$gg"
ps -o lstart= -p "$$" 2>/dev/null | tr -s ' ' > "$gs"
sleep 600
EOF
chmod +x "$GRANDCHILD"

FAKE_WEDGE="$TMP/fake-wedge.sh"
cat > "$FAKE_WEDGE" <<EOF
#!/usr/bin/env bash
# The delegate: fork the wedged grandchild, then block on wait. Emits NOTHING to stdout
# so the byte-growth watchdog sees a stall and fires the kill floor.
"$GRANDCHILD" "$TMP/wedge.pid" "$TMP/wedge.pgid" "$TMP/wedge.start" &
wait
EOF
chmod +x "$FAKE_WEDGE"

jd="$TMP/jobs/wedge"
mkdir -p -m 700 "$jd"; echo '{"verb":"run"}' > "$jd/meta.json"
rm -f "$TMP/wedge.pid" "$TMP/wedge.pgid" "$TMP/wedge.start"
# warn=2 / kill=3 / hard=60. Disable the filesystem-progress and devin-log liveness
# resets so a foreign file write (or a devin log dir) cannot prop up idle and prevent
# the stall-kill from firing — the test must reach the kill deterministically.
OSRC_POLL=1 OSRC_FS_PROGRESS=0 OSRC_DEVIN_LIVENESS=0 _supervise "$jd" 2 3 60 -- "$FAKE_WEDGE" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 125 ]; then
  ok "wedge: stall-kill fired (exit 125, wedged)"
else
  bad "wedge: expected exit 125 (wedged/stall-kill), got $rc"
fi

gp="$(cat "$TMP/wedge.pid" 2>/dev/null | tr -d '[:space:]')"
gc_pgid="$(cat "$TMP/wedge.pgid" 2>/dev/null | tr -d '[:space:]')"
gstart="$(cat "$TMP/wedge.start" 2>/dev/null | tr -s ' ')"
[ -n "$gp" ] && _REAP_PIDS="$_REAP_PIDS $gp"

# The grandchild must have shared the job's isolated process group — that is the
# invariant that makes a negative-PGID kill reach it after it re-parents.
job_pgid="$(cat "$jd/pgid" 2>/dev/null | tr -d '[:space:]')"
if [ -n "$job_pgid" ] && [ -n "$gc_pgid" ] && [ "$job_pgid" = "$gc_pgid" ]; then
  ok "wedge: grandchild shared the job's process group (pgid=$gc_pgid) — PG kill can reach it"
else
  bad "wedge: grandchild pgid=${gc_pgid:-<none>} != job pgid=${job_pgid:-<none>} — the grandchild was NOT in the isolated group"
fi

if [ -z "$gp" ]; then
  bad "wedge: grandchild never wrote its pid (test setup did not run it)"
elif _wait_gone "$gp"; then
  # Rule out PID reuse: only call it dead if the live process (if any) is NOT our
  # grandchild. A recycled PID will have a different start time and a different pgid.
  live_start="$(ps -o lstart= -p "$gp" 2>/dev/null | tr -s ' ')"
  live_pgid="$(ps -o pgid= -p "$gp" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$gstart" ] && [ -n "$live_start" ] && [ "$live_start" = "$gstart" ] && [ "$live_pgid" = "$gc_pgid" ]; then
    bad "wedge: PID $gp matches our grandchild's start/pgid yet reads live — SIGKILL did not take (REGRESSION)"
  else
    ok "wedge: grandchild was reaped (gone or PID recycled) — process-group SIGKILL reached the re-parented grandchild"
  fi
else
  # Still live AND it is genuinely our grandchild (same start time + pgid): the kill
  # missed it. This is the watchdog bug, reproduced. When ps -o lstart= is unavailable
  # (busybox/Alpine/MSYS), gstart is empty and we CANNOT distinguish our grandchild
  # from a recycled PID — fail conservatively rather than false-pass, since this is a
  # regression test and a false-pass is worse than a false-fail.
  live_start="$(ps -o lstart= -p "$gp" 2>/dev/null | tr -s ' ')"
  if [ -z "$gstart" ]; then
    bad "wedge: grandchild PID $gp still ALIVE after the kill floor, but ps -o lstart= is unavailable for identity check — cannot confirm reap (fail conservative)"
  elif [ "$live_start" = "$gstart" ]; then
    bad "wedge: grandchild PID $gp still ALIVE after the kill floor — the re-parented grandchild escaped the tree walk (REGRESSION of the watchdog bug)"
  else
    ok "wedge: PID $gp now belongs to another process (start mismatch) — our grandchild was reaped"
  fi
fi

# ----------------------------------- COOPERATIVE grandchild: graceful TERM path
# Prove the fix did not remove the graceful SIGTERM step. A grandchild that HONORS TERM
# must exit on the TERM pass (recording that it received it), so the KILL pass is a
# no-op rather than the thing that stops it. Otherwise an over-eager KILL-only path
# would tear down a cooperative delegate that could have cleaned up.
COOP_GC="$TMP/coop-grandchild.sh"
cat > "$COOP_GC" <<'EOF'
#!/usr/bin/env bash
trap 'printf term-received > "'"$1"'"; exit 0' TERM
trap '' INT
printf '%s\n' "$$" > "$2"
sleep 600
EOF
chmod +x "$COOP_GC"

FAKE_COOP="$TMP/fake-coop.sh"
cat > "$FAKE_COOP" <<EOF
#!/usr/bin/env bash
"$COOP_GC" "$TMP/coop.term" "$TMP/coop.pid" &
wait
EOF
chmod +x "$FAKE_COOP"

jd2="$TMP/jobs/coop"
mkdir -p -m 700 "$jd2"; echo '{"verb":"run"}' > "$jd2/meta.json"
rm -f "$TMP/coop.term" "$TMP/coop.pid"
OSRC_POLL=1 OSRC_FS_PROGRESS=0 OSRC_DEVIN_LIVENESS=0 _supervise "$jd2" 2 3 60 -- "$FAKE_COOP" >/dev/null 2>&1
rc2=$?
[ "$rc2" -eq 125 ] && ok "coop: cooperative wedged delegate still stopped with exit 125" \
                    || bad "coop: expected exit 125 for a silent cooperative delegate, got $rc2"
cpid="$(cat "$TMP/coop.pid" 2>/dev/null | tr -d '[:space:]')"
[ -n "$cpid" ] && _REAP_PIDS="$_REAP_PIDS $cpid"
if [ -f "$TMP/coop.term" ]; then
  ok "coop: grandchild received SIGTERM and exited gracefully (graceful path intact, no SIGKILL needed)"
else
  bad "coop: grandchild never received SIGTERM — the graceful TERM step was lost (KILL-only regression)"
fi
if [ -n "$cpid" ] && _wait_gone "$cpid"; then
  ok "coop: cooperative grandchild is gone after the kill"
else
  bad "coop: cooperative grandchild PID ${cpid:-<none>} still alive — kill did not complete"
fi

# ------------------------------------------- NORMAL FINISH: no false positive
# A delegate that finishes cleanly with no grandchild must keep its real exit code and
# never be killed by the watchdog. Guards against an over-broad change that kills every
# job's group on exit.
FAKE_OK="$TMP/fake-ok.sh"
cat > "$FAKE_OK" <<'EOF'
#!/usr/bin/env bash
echo "OSRC::DONE"
echo "work completed normally"
exit 0
EOF
chmod +x "$FAKE_OK"

jd3="$TMP/jobs/normal"
mkdir -p -m 700 "$jd3"; echo '{"verb":"run"}' > "$jd3/meta.json"
OSRC_POLL=1 _supervise "$jd3" 5 60 120 -- "$FAKE_OK" >/dev/null 2>&1
rc3=$?
status3="$(cat "$jd3/status" 2>/dev/null)"
if [ "$rc3" -eq 0 ]; then
  ok "normal: clean-finishing delegate keeps exit 0 (not false-killed)"
else
  bad "normal: expected exit 0 for a clean finish, got $rc3 (status=$status3)"
fi
case "$status3" in
  done|done?) ok "normal: clean finish not marked wedged/timed-out (status=$status3)" ;;
  *)          bad "normal: clean finish wrongly marked '$status3'" ;;
esac

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
