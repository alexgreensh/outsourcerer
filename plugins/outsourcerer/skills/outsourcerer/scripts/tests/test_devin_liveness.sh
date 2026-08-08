#!/usr/bin/env bash
# test_devin_liveness.sh — the watchdog must not stall-kill a devin delegate that is
# demonstrably alive.
#
# Root cause this guards: devin's `-p` (print) mode writes NOTHING to stdout until the
# process exits — documented as "print response and exit", with no streaming output
# format to opt into. Verified against the real CLI through both a pipe and a PTY: the
# whole answer arrives in one burst at the end. The watchdog's primary liveness signal is
# out.log byte growth, so it is blind to this lane BY CONSTRUCTION and killed every devin
# job that outlived the stall window no matter how healthy it was.
#
# The signature that this is happening, rather than a theory about it: wedges occur only
# on the non-streaming lane and never on the lanes that stream, start->kill times cluster
# on OSRC_STALL_KILL rather than on anything the delegate did, and devin's own log for a
# killed job keeps being written right up to the kill, showing active file reads.
#
# The FS-progress fallback cannot cover this: read-only verbs (explore/research) write no
# files by design, which is exactly the long-and-quiet case.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"
export OSRC_HOME="$TMP"
export HOME="$TMP"
DLOGS="$TMP/.local/share/devin/cli/logs"
mkdir -p "$DLOGS"
kids=""
cleanup() { for k in $kids; do kill -KILL "$k" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

. "$SRC" >/dev/null 2>&1
type _devin_live_mtime >/dev/null 2>&1 || { echo "FAIL: _devin_live_mtime not defined"; exit 1; }

# Cold-start chatter, spinner frames, hook notices, and untyped streaming JSON
# must leave the no-init watchdog armed. Only positive assistant output disarms it.
noise="$TMP/no-init-noise.log"; progress="$TMP/no-init-progress"
for line in \
  'Retrying connection attempt 1 of 5' \
  'Waiting for Devin to respond' \
  'SessionStart: loading project config' \
  'PostToolUse: bash returned 0' \
  'Hook: PreToolUse matched' \
  '{"type":"message","subtype":"init"}' \
  '{"text":"Connection error"}' \
  '⠋'
do
  printf '%s\n' "$line" > "$noise"
  if _delegate_has_model_output "$noise" "$progress"; then
    bad "no-init noise falsely proves model initialization: $line"
  else
    ok "no-init noise leaves watchdog armed: $line"
  fi
done
for line in \
  '{"type":"content_block_delta","delta":{"text":"x"}}' \
  '{"role":"assistant","content":"here is the plan"}' \
  'Here is the fix you asked for'
do
  printf '%s\n' "$line" > "$noise"
  _delegate_has_model_output "$noise" "$progress" \
    && ok "known model-output signal initializes: $line" \
    || bad "known model-output signal was ignored: $line"
done

# ---------------------------------------------------------------- unit
# A log belonging to a LIVE descendant is found.
sleep 60 & child=$!; kids="$kids $child"
# This regression needs one observable parent/child edge. Some restricted
# sandboxes deny both pgrep and process-table reads, so they cannot exercise
# the contract at all. Skip there instead of reporting a product failure.
if ! pgrep -P "$$" 2>/dev/null | grep -qx "$child"; then
  echo "SKIP: process-tree enumeration unavailable; Devin liveness regression requires a visible child process"
  exit 0
fi
touch "$DLOGS/devin_20260722-000000_${child}.log"
mt="$(_devin_live_mtime "$$")"
[ -n "$mt" ] && ok "finds the devin log of a live descendant" \
             || bad "did not find the devin log of a live descendant"

# A log belonging to some OTHER process must NOT vouch for this job. Concurrent fanout
# jobs each spawn their own devin, so "newest log in the directory" would let a busy
# sibling keep a genuinely hung job alive forever.
other=999999
touch "$DLOGS/devin_20260722-000000_${other}.log"
sleep 1
touch "$DLOGS/devin_20260722-000000_${other}.log"   # newest file in the dir, wrong pid
mt2="$(_devin_live_mtime "$$")"
mt_other="$(stat -f %m "$DLOGS/devin_20260722-000000_${other}.log" 2>/dev/null \
            || stat -c %Y "$DLOGS/devin_20260722-000000_${other}.log" 2>/dev/null)"
[ "$mt2" != "$mt_other" ] && ok "ignores a devin log belonging to an unrelated pid" \
                          || bad "a sibling's devin log vouched for this job"

kill -KILL "$child" 2>/dev/null; wait "$child" 2>/dev/null
# No live descendant -> no liveness claim.
mt3="$(_devin_live_mtime "$$")" || mt3=""
[ -z "$mt3" ] && ok "claims no liveness once the descendant is gone" \
              || bad "still claimed liveness with no live descendant"

# ---------------------------------------------------------------- runtime
# A delegate that prints NOTHING but whose devin log keeps growing must survive a stall
# window it would otherwise be killed in.
# ISOLATION: the job dir must NOT sit inside the job's cwd. The watchdog's FS-progress fallback
# scans the cwd for recently-modified files, and the supervisor writes status/progress into the job
# dir on every poll — so a job dir nested under the cwd makes the supervisor's own bookkeeping look
# like delegate progress and resets the stall timer forever. That would let both scenarios below
# "pass" without the devin-log signal ever being consulted. An empty work dir keeps the devin log
# the ONLY thing that can vouch for liveness.
WORK="$TMP/work"; mkdir -p "$WORK"
jd="$TMP/jobs/job-alive"; mkdir -p "$jd"
printf '{"verb":"explore","cwd":"%s"}\n' "$WORK" > "$jd/meta.json"
cat > "$TMP/silent_alive.sh" <<EOF
#!/usr/bin/env bash
# Prints nothing at all (devin print-mode), but keeps its CLI log warm like a working
# devin does. The log is keyed by THIS process's pid, exactly as devin names it.
for i in \$(seq 1 12); do
  touch "$DLOGS/devin_20260722-111111_\$\$.log"
  sleep 1
done
EOF
chmod +x "$TMP/silent_alive.sh"
# warn 2s, kill 5s, hard 60s: without the devin-log signal a 12s silent job dies at 5s.
# OSRC_POLL=1 so judgement happens repeatedly WHILE the job is alive — the liveness check has to
# keep winning, not merely get lucky with a poll interval wider than the kill window.
OSRC_POLL=1 _supervise "$jd" 2 5 60 -- bash "$TMP/silent_alive.sh" >/dev/null 2>&1
rc_alive=$?
st_alive="$(cat "$jd/status" 2>/dev/null)"
[ "$rc_alive" != "125" ] && ok "silent-but-alive devin job NOT stall-killed (rc=$rc_alive)" \
                         || bad "silent-but-alive devin job was stall-killed (rc=125, status=$st_alive)"
[ "$st_alive" != "wedged" ] && ok "status is not 'wedged' for a live delegate (status=$st_alive)" \
                            || bad "status wrongly 'wedged' for a live delegate"

# NEGATIVE CONTROL: the same job, with the liveness check switched OFF, must die. Without this the
# scenario above could be passing for some unrelated reason and we would be certifying a guard that
# is not doing the work.
jd0="$TMP/jobs/job-control"; mkdir -p "$jd0"
printf '{"verb":"explore","cwd":"%s"}\n' "$WORK" > "$jd0/meta.json"
OSRC_DEVIN_LIVENESS=0 OSRC_POLL=1 _supervise "$jd0" 2 5 60 -- bash "$TMP/silent_alive.sh" >/dev/null 2>&1
rc_ctl=$?
[ "$rc_ctl" = "125" ] && ok "control: with OSRC_DEVIN_LIVENESS=0 the same job IS stall-killed (rc=125)" \
                      || bad "control: job survived (rc=$rc_ctl) even with liveness disabled — the test does not prove the fix"

# ---------------------------------------------------------------- backstop intact
# The fix must NOT make the watchdog immortal: a job that is silent AND whose devin log
# has gone cold must still be reaped. A liveness signal that never expires is just a
# disabled watchdog.
jd2="$TMP/jobs/job-dead"; mkdir -p "$jd2"
printf '{"verb":"explore","cwd":"%s"}\n' "$WORK" > "$jd2/meta.json"
cat > "$TMP/silent_dead.sh" <<EOF
#!/usr/bin/env bash
# Writes its log ONCE, then goes silent forever — a genuine hang.
touch "$DLOGS/devin_20260722-222222_\$\$.log"
sleep 60
EOF
chmod +x "$TMP/silent_dead.sh"
OSRC_POLL=1 _supervise "$jd2" 2 6 60 -- bash "$TMP/silent_dead.sh" >/dev/null 2>&1
rc_dead=$?
st_dead="$(cat "$jd2/status" 2>/dev/null)"
[ "$rc_dead" = "125" ] && ok "genuinely hung devin job still stall-killed (rc=125)" \
                       || bad "hung job NOT reaped (rc=$rc_dead, status=$st_dead) — watchdog disabled"
[ "$st_dead" = "wedged" ] && ok "hung job status is 'wedged'" \
                          || bad "hung job status is '$st_dead', expected 'wedged'"

# ------------------------------------------------------- NO POST-MORTEM WEDGE
# Sibling watchdog defect found while fixing the above. The poll loop only re-tests its while
# condition at the TOP, so a delegate that finishes during the sleep still gets judged once — with
# an `idle` measured against a process that has already exited. A job that went quiet and then
# COMPLETED was killed post-mortem and reported `wedged` instead of `done`.
# Here: poll 10s, kill window 5s, and a silent job that exits after ~2s. At the first (and only)
# poll the delegate is long gone and idle reads 10 >= 5.
jd3="$TMP/jobs/job-finished"; mkdir -p "$jd3"
printf '{"verb":"explore","cwd":"%s"}\n' "$WORK" > "$jd3/meta.json"
printf '#!/usr/bin/env bash\nsleep 2\n' > "$TMP/quick_quiet.sh"; chmod +x "$TMP/quick_quiet.sh"
OSRC_POLL=10 _supervise "$jd3" 2 5 60 -- bash "$TMP/quick_quiet.sh" >/dev/null 2>&1
rc_fin=$?
st_fin="$(cat "$jd3/status" 2>/dev/null)"
[ "$rc_fin" != "125" ] && ok "a silent job that FINISHED is not wedged post-mortem (rc=$rc_fin, status=$st_fin)" \
                       || bad "finished job reported wedged post-mortem (rc=125) — killing a corpse"

# ---------------------------------------------------------------- opt-out
grep -aq 'OSRC_DEVIN_LIVENESS' "$SRC" \
  && ok "devin liveness check has an opt-out (OSRC_DEVIN_LIVENESS)" \
  || bad "no opt-out for the devin liveness check"

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
