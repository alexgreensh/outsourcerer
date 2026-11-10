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

TMP="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; exit 1; }
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
# A short reply that opens with a status word still reads as chatter at this level
# ("Starting work on the parser now" is textually indistinguishable from a status
# line); that residual is covered at the _supervise level by the live-devin-log
# init signal, tested below. Machine-state openers (Waiting/Connecting/Retrying/...)
# are denied at ANY length — a hung-hook or reconnect-storm status line must never
# count as a first turn no matter how verbose its path or URL makes it.
noise="$TMP/no-init-noise.log"; progress="$TMP/no-init-progress"
for line in \
  'Retrying connection attempt 1 of 5' \
  'Waiting for Devin to respond' \
  'Starting work on the parser now' \
  'SessionStart: loading project config' \
  'PostToolUse: bash returned 0' \
  'Hook: PreToolUse matched' \
  '{"type":"message","subtype":"init"}' \
  '{"text":"Connection error"}' \
  'Retrying the request to https://api.devin.ai/v3/sessions/abc123 after ECONNRESET; attempt 4 of 8, backoff 32s, will keep trying' \
  'Waiting for the upstream model stream to reconnect after a long network partition on the corporate proxy, attempt backoff continues' \
  'Connecting to wss://api.devin.ai/v3/stream?token=abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890 (retry 3)' \
  '⠋'
do
  printf '%s\n' "$line" > "$noise"
  if _delegate_has_model_output "$noise" "$progress"; then
    bad "no-init noise falsely proves model initialization: $line"
  else
    ok "no-init noise leaves watchdog armed: $line"
  fi
done
# Lines >=120 chars are presumed prose by the length guard — a LONG reply that opens with a
# status word counts as output. Two boundaries pinned here: retry-churn tokens keep a status
# opener denied at ANY length (the >=120 noise case above — a hung connect-retry loop is not
# a reply), and churn tokens WITHOUT a status opener still count (the last case below — real
# prose mentioning attempts is model output, not launcher chatter).
for line in \
  '{"type":"content_block_delta","delta":{"text":"x"}}' \
  '{"role":"assistant","content":"here is the plan"}' \
  'Here is the fix you asked for' \
  'Starting the fix round. First: pull, read the review and brief, and invoke the calc-domain skill since this touches pension math.Pulled, head is as expected.' \
  'The test failed on attempt 4 of 8, will retry the flaky case with backoff 32s before moving on to the next module'
do
  printf '%s\n' "$line" > "$noise"
  _delegate_has_model_output "$noise" "$progress" \
    && ok "known model-output signal initializes: $line" \
    || bad "known model-output signal was ignored: $line"
done

# The 119/120 boundary itself, pinned exactly on the CONVERSATIONAL set: a 119-char
# status line is still chatter, a 120-char one counts as prose. (Machine-state openers
# are denied at any length instead — pinned by the >=120 noise cases above.)
denied119="Starting $(printf '%0110d' 0 | tr '0' 'x')"    # exactly 119 chars
printf '%s\n' "$denied119" > "$noise"
[ "${#denied119}" -eq 119 ] || bad "test bug: boundary case is ${#denied119} chars, not 119"
if _delegate_has_model_output "$noise" "$progress"; then
  bad "119-char status line counted as output: $denied119"
else
  ok "119-char status line stays denied"
fi
counted120="Starting $(printf '%0111d' 0 | tr '0' 'x')"   # exactly 120 chars
printf '%s\n' "$counted120" > "$noise"
[ "${#counted120}" -eq 120 ] || bad "test bug: boundary case is ${#counted120} chars, not 120"
_delegate_has_model_output "$noise" "$progress" \
  && ok "120-char status opener counts as output" \
  || bad "120-char status opener was denied"

# ---------------------------------------------------------------- unit
# A log belonging to a LIVE descendant is found.
sleep 60 & child=$!; kids="$kids $child"
# This regression needs one observable parent/child edge. Some restricted
# sandboxes deny both pgrep and process-table reads, so they cannot exercise
# the contract at all. Skip there instead of reporting a product failure.
if ! pgrep -P "$$" 2>/dev/null | grep -qx "$child"; then
  echo "SKIP: process-tree enumeration unavailable; Devin liveness regression requires a visible child process"
  # A SKIP must not erase failures already recorded above it.
  [ "$fail" -eq 0 ] || { echo "---"; echo "passed=$pass failed=$fail"; exit 1; }
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
OSRC_NOINIT_SECS=30 OSRC_POLL=1 _supervise "$jd2" 2 6 60 -- bash "$TMP/silent_dead.sh" >/dev/null 2>&1
rc_dead=$?
st_dead="$(cat "$jd2/status" 2>/dev/null)"
[ "$rc_dead" = "125" ] && ok "genuinely hung devin job still stall-killed (rc=125)" \
                       || bad "hung job NOT reaped (rc=$rc_dead, status=$st_dead) — watchdog disabled"
[ "$st_dead" = "wedged" ] && ok "hung job status is 'wedged'" \
                          || bad "hung job status is '$st_dead', expected 'wedged'"
# rc/status alone cannot tell WHICH arm reaped it (both no-init and stall give 125/wedged).
# The reason must name the stall bucket, not no-init: this job DID start, it just hung.
[ "$(cat "$jd2/reason" 2>/dev/null)" = "silent-delegate" ] \
  && ok "hung job reason is silent-delegate, not no-init" \
  || bad "hung job reason is '$(cat "$jd2/reason" 2>/dev/null)', expected silent-delegate"

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

# --------------------------------------------------- NO-INIT DISARM VIA LIVE DEVIN LOG
# devin -p prints nothing until exit, so at the no-init deadline out.log can hold ONLY
# launcher noise: a healthy delegate may have no qualifying line even after the <120-char
# fix (a short reply can also still read as status chatter, per the unit cases above).
# The delegate's own live CLI log is positive proof a turn started, so no-init must stay
# disarmed while it is warm. noinit=3 sits inside every other window, so only this signal
# can save the job.
jd4="$TMP/jobs/job-noinit-alive"; mkdir -p "$jd4"
printf '{"verb":"explore","cwd":"%s"}\n' "$WORK" > "$jd4/meta.json"
OSRC_NOINIT_SECS=3 OSRC_POLL=1 _supervise "$jd4" 30 45 60 -- bash "$TMP/silent_alive.sh" >/dev/null 2>&1
rc_ni=$?
if grep -aq '^no-init' "$jd4/reason" 2>/dev/null; then
  bad "live devin log did not disarm no-init (rc=$rc_ni, reason=$(cat "$jd4/reason" 2>/dev/null))"
else
  ok "live devin log disarms no-init for a silent devin job (rc=$rc_ni)"
fi

# NEGATIVE CONTROL: with the liveness signal off, the same silent job hits the deadline.
jd5="$TMP/jobs/job-noinit-ctl"; mkdir -p "$jd5"
printf '{"verb":"explore","cwd":"%s"}\n' "$WORK" > "$jd5/meta.json"
OSRC_DEVIN_LIVENESS=0 OSRC_NOINIT_SECS=3 OSRC_POLL=1 _supervise "$jd5" 30 45 60 -- bash "$TMP/silent_alive.sh" >/dev/null 2>&1
grep -aq '^no-init' "$jd5/reason" 2>/dev/null \
  && ok "control: no-init still fires with OSRC_DEVIN_LIVENESS=0" \
  || bad "control: no-init did not fire even with liveness disabled"

# STALE LOG: a devin log that PREDATES this job must never disarm no-init. The pid glob is a
# number, so a log left by an earlier process whose pid the kernel reused would otherwise
# vouch for a job that never launched devin. Backdating the mtime makes the freshness gate
# the ONLY thing that can refuse it — deterministic, unlike same-second timing races.
jd6="$TMP/jobs/job-stale-log"; mkdir -p "$jd6"
printf '{"verb":"explore","cwd":"%s"}\n' "$WORK" > "$jd6/meta.json"
cat > "$TMP/stale_log.sh" <<EOF
#!/usr/bin/env bash
touch "$DLOGS/devin_20200101-000000_\$\$.log"
touch -t 202001010000.00 "$DLOGS/devin_20200101-000000_\$\$.log"
sleep 60
EOF
chmod +x "$TMP/stale_log.sh"
OSRC_NOINIT_SECS=3 OSRC_POLL=1 _supervise "$jd6" 30 45 60 -- bash "$TMP/stale_log.sh" >/dev/null 2>&1
grep -aq '^no-init' "$jd6/reason" 2>/dev/null \
  && ok "stale (backdated) devin log does NOT disarm no-init" \
  || bad "a pre-existing devin log disarmed no-init — pid-reuse/stale-log hole"

# ONE WRITE BUYS ONE WINDOW: a devin log written during supervision proves the CLI booted,
# not that a turn started — a hung SessionStart cold-start looks exactly like this. The
# freshness push moves the no-init deadline to the last log write, so a one-shot log buys
# noinit seconds past its own mtime and the job then dies as no-init, with the RIGHT reason —
# never as silent-delegate at the stall window, whose advice a hung startup cannot use.
jd7="$TMP/jobs/job-late-log"; mkdir -p "$jd7"
printf '{"verb":"explore","cwd":"%s"}\n' "$WORK" > "$jd7/meta.json"
cat > "$TMP/late_log.sh" <<EOF
#!/usr/bin/env bash
sleep 2
touch "$DLOGS/devin_20260722-333333_\$\$.log"
sleep 60
EOF
chmod +x "$TMP/late_log.sh"
t0_late=$(date +%s)
OSRC_NOINIT_SECS=3 OSRC_POLL=1 _supervise "$jd7" 30 45 60 -- bash "$TMP/late_log.sh" >/dev/null 2>&1
elapsed_late=$(( $(date +%s) - t0_late ))
grep -aq '^no-init' "$jd7/reason" 2>/dev/null \
  && ok "one-shot devin log buys one window, then no-init fires (elapsed=${elapsed_late}s)" \
  || bad "one-shot log held no-init off or the wrong arm fired (reason=$(cat "$jd7/reason" 2>/dev/null))"
[ "$elapsed_late" -ge 4 ] \
  && ok "the mid-run write pushed the deadline to write+noinit, not t0+noinit" \
  || bad "killed at ${elapsed_late}s — the +2s write bought nothing"

# --------------------------------------------- NO-INIT CLOCK ISOLATION (ni0)
# The devin-log push goes to ni0, a clock ONLY no-init reads. The zero-write guard reads
# qt0/age instead: if log activity also fed qt0, a live devin -p job that writes ZERO files
# on a mutating verb would never be flagged exploring? — the guard against a write-free
# burn would silently die on exactly the lane this feature exists for. Pin the isolation:
# an initialized edit job with a warm log and no writes must still hit exploring-timeout.
jd8="$TMP/jobs/job-nowrite"; mkdir -p "$jd8"
printf '{"verb":"edit","cwd":"%s"}\n' "$WORK" > "$jd8/meta.json"
cat > "$TMP/warm_nowrite.sh" <<EOF
#!/usr/bin/env bash
# Initializes (long prose reply), keeps the devin log warm, writes nothing to the cwd.
echo 'Here is the fix you asked for, written out at length so the line is plainly prose and not a status-word opener, well past one hundred and twenty characters in total.'
for i in \$(seq 1 25); do touch "$DLOGS/devin_20260722-555555_\$\$.log"; sleep 1; done
EOF
chmod +x "$TMP/warm_nowrite.sh"
OSRC_NOWRITE_WARN=3 OSRC_NOWRITE_KILL=3 OSRC_NOINIT_SECS=3 OSRC_POLL=1 \
  _supervise "$jd8" 30 45 60 -- bash "$TMP/warm_nowrite.sh" >/dev/null 2>&1
[ "$(cat "$jd8/reason" 2>/dev/null)" = "exploring-timeout" ] \
  && ok "warm devin log does NOT shield a zero-write edit job from exploring-timeout" \
  || bad "warm log disabled the no-write guard (reason=$(cat "$jd8/reason" 2>/dev/null))"

# SLOW WRITER: the no-init check must measure age AFTER the push, not against the previous
# poll's mtime — a delegate whose log advances every 2s inside a 3s window is alive.
jd9="$TMP/jobs/job-slow-writer"; mkdir -p "$jd9"
printf '{"verb":"explore","cwd":"%s"}\n' "$WORK" > "$jd9/meta.json"
cat > "$TMP/slow_writer.sh" <<EOF
#!/usr/bin/env bash
for i in \$(seq 1 5); do touch "$DLOGS/devin_20260722-666666_\$\$.log"; sleep 2; done
EOF
chmod +x "$TMP/slow_writer.sh"
OSRC_NOINIT_SECS=3 OSRC_POLL=1 _supervise "$jd9" 30 45 60 -- bash "$TMP/slow_writer.sh" >/dev/null 2>&1
rc_sw=$?
if grep -aq '^no-init' "$jd9/reason" 2>/dev/null; then
  bad "a 2s-cadence devin log was killed by no-init inside a 3s window (rc=$rc_sw)"
else
  ok "devin log advancing every 2s keeps no-init off (rc=$rc_sw)"
fi

# FUTURE-DATED MTIME: a log stamped ahead of the clock (skew, or deliberate) must not
# ratchet the no-init clock; only mtimes <= now may advance it.
jd10="$TMP/jobs/job-future-log"; mkdir -p "$jd10"
printf '{"verb":"explore","cwd":"%s"}\n' "$WORK" > "$jd10/meta.json"
cat > "$TMP/future_log.sh" <<EOF
#!/usr/bin/env bash
touch "$DLOGS/devin_20260722-777777_\$\$.log"
touch -t 203001010000.00 "$DLOGS/devin_20260722-777777_\$\$.log"
sleep 60
EOF
chmod +x "$TMP/future_log.sh"
OSRC_NOINIT_SECS=3 OSRC_POLL=1 _supervise "$jd10" 30 45 60 -- bash "$TMP/future_log.sh" >/dev/null 2>&1
grep -aq '^no-init' "$jd10/reason" 2>/dev/null \
  && ok "future-dated devin log mtime cannot disarm no-init" \
  || bad "future-dated log held no-init off (reason=$(cat "$jd10/reason" 2>/dev/null))"

# SAME ISOLATION, UNINITIALIZED: a silent edit job's warm log correctly holds NO-INIT off
# (the log is alive — never-started is the wrong verdict) while the write-free burn still
# dies as exploring-timeout. Two clocks, two different arms, one log.
jd11="$TMP/jobs/job-silent-edit"; mkdir -p "$jd11"
printf '{"verb":"edit","cwd":"%s"}\n' "$WORK" > "$jd11/meta.json"
cat > "$TMP/silent_edit.sh" <<EOF
#!/usr/bin/env bash
for i in \$(seq 1 25); do touch "$DLOGS/devin_20260722-888888_\$\$.log"; sleep 1; done
EOF
chmod +x "$TMP/silent_edit.sh"
OSRC_NOWRITE_WARN=3 OSRC_NOWRITE_KILL=3 OSRC_NOINIT_SECS=3 OSRC_POLL=1 \
  _supervise "$jd11" 30 45 60 -- bash "$TMP/silent_edit.sh" >/dev/null 2>&1
[ "$(cat "$jd11/reason" 2>/dev/null)" = "exploring-timeout" ] \
  && ok "silent warm-log edit job: no-init held off, exploring-timeout still bounds the burn" \
  || bad "silent edit job ended wrong (reason=$(cat "$jd11/reason" 2>/dev/null))"

# FUTURE MTIME, STALL ARM: the same distrust applies to the liveness reset — a log stamped
# ahead of now must not hold the stall-kill off. This job speaks once (so stall-kill, not
# silent-delegate, is the right reason), stamps its log ahead, then hangs: bounded.
jd12="$TMP/jobs/job-stall-future"; mkdir -p "$jd12"
printf '{"verb":"explore","cwd":"%s"}\n' "$WORK" > "$jd12/meta.json"
cat > "$TMP/stall_future.sh" <<EOF
#!/usr/bin/env bash
echo 'a real delegate line so the stall reason is stall-kill'
touch "$DLOGS/devin_20260722-999999_\$\$.log"
touch -t 203001010000.00 "$DLOGS/devin_20260722-999999_\$\$.log"
sleep 30
EOF
chmod +x "$TMP/stall_future.sh"
t0_sf=$(date +%s)
OSRC_POLL=1 _supervise "$jd12" 3 8 30 -- bash "$TMP/stall_future.sh" >/dev/null 2>&1
el_sf=$(( $(date +%s) - t0_sf ))
[ "$(cat "$jd12/reason" 2>/dev/null)" = "stall-kill" ] && [ "$el_sf" -lt 20 ] \
  && ok "future-dated log does not hold the stall-kill off (elapsed=${el_sf}s)" \
  || bad "future-dated log defeated the stall arm (reason=$(cat "$jd12/reason" 2>/dev/null), elapsed=${el_sf}s)"

# ---------------------------------------------------------------- opt-out
grep -aq 'OSRC_DEVIN_LIVENESS' "$SRC" \
  && ok "devin liveness check has an opt-out (OSRC_DEVIN_LIVENESS)" \
  || bad "no opt-out for the devin liveness check"

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
