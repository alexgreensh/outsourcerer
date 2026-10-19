#!/usr/bin/env bash
# test_devin_grant_lock_share.sh — Devin dispatches with the SAME skill grant set share the
# skills-home grant lock instead of serializing behind it.
#
# The incident (0.13.5): one long ungranted `devin yolo` job held the grant lock for its whole run.
# A 5-job Devin fanout started two minutes later; every job sat silent in the lock's `sleep 1`
# loop right after the CLOUD DISCLOSURE banner, and the no-init watchdog killed all five at 150s as
# "delegate never started". `classify` then called each one REUSE-OUTPUT false-stall:deliverable,
# because the only body line in last.txt was bash's own "Terminated: 15  sleep 1" notice.
#
# Locked out here:
#   - same-set dispatches join a live holder immediately and leave the home untouched;
#   - the lock survives until the LAST holder leaves, whichever order they leave in;
#   - a different set still waits (the original isolation guarantee), and says so on stderr;
#   - a joiner never joins before the creator has finished scoping (no grants file yet; a new
#     invariant of the shared lock, not part of the incident);
#   - a dead joiner never keeps the lock alive, and pid-less debris (a holder killed between
#     mkdir and its pid write) is reaped once it is old, never left to wedge the lane;
#   - a queued job writes $OSRC_JOB_DIR/lockwait while waiting and removes it once it holds the lock;
#   - the bg watchdog, driven for real, does not count a lock queue as no-init, and the hard timeout
#     still fires while queued;
#   - a contended lock writes nothing stray into the job log;
#   - classify never treats a job-control notice, an engine shell diagnostic, or a no-init job as a
#     deliverable.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TD="$(mktemp -d "${TMPDIR:-/tmp}/osrc-glock.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }; trap 'rm -rf "$TD"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

export OSRC_HOME="$TD/state"
HOME_REAL="$HOME"; HOME="$TD/home"; export HOME
. "$SRC" >/dev/null 2>&1
for fn in _devin_with_prepare _devin_skills_lock_acquire _devin_skills_lock_release _classify_job; do
  type -t "$fn" >/dev/null || { echo "FAIL: $fn not loaded"; exit 1; }
done

SKH="$HOME/.config/devin/skills"
LOCK="$SKH/.outsourcerer-grants.lock.d"
SK="$HOME/.claude/skills/confskill"; mkdir -p "$SK"; printf '# confskill\n' > "$SK/SKILL.md"
SK2="$HOME/.claude/skills/plugskill"; mkdir -p "$SK2"; printf '# plugskill\n' > "$SK2/SKILL.md"

# hold <tag> <with-spec> -> background dispatch that prepares, then "runs" until $TD/release-<tag>.
hold() {
  ( WITH_SPEC="$2" _devin_with_prepare >/dev/null 2>&1 || exit 1
    : > "$TD/held-$1"
    while [ ! -f "$TD/release-$1" ]; do sleep 0.1 2>/dev/null || sleep 1; done
    _devin_skills_lock_release ) &
}
wait_for() { local n=0; while [ ! -e "$1" ] && [ "$n" -lt 100 ]; do sleep 0.1 2>/dev/null || sleep 1; n=$((n+1)); done; [ -e "$1" ]; }

# --- 1. the incident: an ungranted run in flight, a second ungranted run joins at once ------------
rm -rf "$SKH"; rm -f "$TD"/held-* "$TD"/release-*
hold A ''; APID=$!
wait_for "$TD/held-A" || bad "setup: A never acquired"
start=$(date +%s)
( WITH_SPEC='' OSRC_DEVIN_LOCK_WAIT_MAX=8 _devin_with_prepare >/dev/null 2>&1 || exit 1; _devin_skills_lock_release )
rc=$?; took=$(( $(date +%s) - start ))
[ "$rc" -eq 0 ] && [ "$took" -lt 5 ] && ok "an ungranted dispatch joins a live ungranted holder (${took}s)" \
  || bad "ungranted dispatch blocked behind an ungranted holder (rc=$rc, ${took}s)"

# --- 2. five same-set dispatches at once all hold the lock together -------------------------------
hold B1 ''; hold B2 ''; hold B3 ''; hold B4 ''
all=1; for t in B1 B2 B3 B4; do wait_for "$TD/held-$t" || all=0; done
[ "$all" = "1" ] && [ -d "$LOCK" ] && ok "4 more ungranted dispatches hold the lock alongside A (the 5-job fanout shape)" \
  || bad "a same-set fanout serialized on the grant lock"

# --- 3. the creator leaving first does not drop the lock under the joiners ------------------------
touch "$TD/release-A"; wait "$APID"
[ -d "$LOCK" ] && ok "lock stays while joiners still run after the creator exits" \
  || bad "the creator's release removed the lock under live joiners"
( WITH_SPEC='skills=confskill' OSRC_DEVIN_LOCK_WAIT_MAX=1 _devin_with_prepare ) >/dev/null 2>&1
[ $? -ne 0 ] && [ ! -e "$SKH/confskill" ] && ok "a different set still cannot re-scope the home under the joiners" \
  || bad "a different grant set re-scoped the home while same-set joiners were running"
for t in B1 B2 B3 B4; do touch "$TD/release-$t"; done; wait
[ ! -d "$LOCK" ] && ok "the last holder out removes the lock" || bad "lock left behind after every holder released"

# --- 4. a different set waits, says why, and gets the lock once the holder leaves -----------------
rm -f "$TD"/held-* "$TD"/release-*
hold C 'skills=confskill'; CPID=$!
wait_for "$TD/held-C" || bad "setup: C never acquired"
err="$( ( WITH_SPEC='skills=plugskill' OSRC_DEVIN_LOCK_WAIT_MAX=1 _devin_with_prepare ) 2>&1 >/dev/null )"
case "$err" in *"waiting for the Devin skills-home grant lock"*"pid "*) ok "a waiting dispatch prints why it is silent, naming the holder" ;;
  *) bad "no waiting line on stderr: $err" ;; esac
[ -L "$SKH/confskill" ] && [ ! -e "$SKH/plugskill" ] && ok "the waiter never touched the holder's scoped home" \
  || bad "a waiter mutated the home"
( WITH_SPEC='skills=confskill' OSRC_DEVIN_LOCK_WAIT_MAX=3 _devin_with_prepare ) >/dev/null 2>&1
[ $? -eq 0 ] && ok "a granted dispatch joins a holder with the identical grant set" || bad "identical granted set did not join"
touch "$TD/release-C"; wait "$CPID"
( WITH_SPEC='skills=plugskill' _devin_with_prepare >/dev/null 2>&1; _devin_skills_lock_release )
[ $? -eq 0 ] && [ -L "$SKH/plugskill" ] && [ ! -e "$SKH/confskill" ] && [ ! -d "$LOCK" ] \
  && ok "after the holder leaves, the other set scopes the home and releases cleanly" \
  || bad "the other set failed to take over after the holder left"

# --- 5. no join before the creator published its set (scoping still in progress) -----------------
rm -rf "$SKH"; mkdir -p "$LOCK/holders"
sleep 300 & LIVE=$!
printf '%s\n' "$LIVE" > "$LOCK/pid"; : > "$LOCK/holders/$LIVE"
( WITH_SPEC='' OSRC_DEVIN_LOCK_WAIT_MAX=1 _devin_with_prepare ) >/dev/null 2>&1
[ $? -ne 0 ] && ok "no join while the creator has not yet published its grant set" \
  || bad "joined a lock whose home was still being scoped"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null

# --- 6. dead holders never keep the lock alive -----------------------------------------------------
rm -rf "$SKH"; mkdir -p "$LOCK/holders"
sh -c 'exit 0' & DEAD=$!; wait "$DEAD"
: > "$LOCK/holders/$DEAD"; printf '\n' > "$LOCK/grants"
( WITH_SPEC='skills=confskill' OSRC_DEVIN_LOCK_WAIT_MAX=3 _devin_with_prepare >/dev/null 2>&1; _devin_skills_lock_release )
[ $? -eq 0 ] && [ -L "$SKH/confskill" ] && ok "a lock held only by dead holders is reaped" \
  || bad "a dead holder wedged the lock"

# --- 6b. pid-less debris: an old one is reaped, a fresh one is respected ------------------------
rm -rf "$SKH" "$LOCK.mx"; mkdir -p "$SKH" "$LOCK.mx"
touch -t 202601010000 "$LOCK.mx"
( WITH_SPEC='' OSRC_DEVIN_LOCK_WAIT_MAX=3 _devin_with_prepare >/dev/null 2>&1; _devin_skills_lock_release )
[ $? -eq 0 ] && [ ! -d "$LOCK.mx" ] && ok "an old pid-less mutex is reaped" || bad "a pid-less mutex wedged the lock"
rm -rf "$SKH"; mkdir -p "$LOCK"; touch -t 202601010000 "$LOCK"
( WITH_SPEC='' OSRC_DEVIN_LOCK_WAIT_MAX=3 _devin_with_prepare >/dev/null 2>&1; _devin_skills_lock_release )
[ $? -eq 0 ] && [ ! -d "$LOCK" ] && ok "an old empty lock dir (no holders, no pid) is reaped" || bad "an empty lock dir wedged the lane"
rm -rf "$SKH"; mkdir -p "$LOCK"
( WITH_SPEC='' OSRC_DEVIN_LOCK_WAIT_MAX=1 _devin_with_prepare ) >/dev/null 2>&1
[ $? -ne 0 ] && [ -d "$LOCK" ] && ok "a fresh empty lock dir is treated as mid-creation, not reaped" \
  || bad "a lock still being created was reaped"
rm -rf "$SKH"

# --- 7. lockwait marks a queued job for the watchdog, and is cleared once it holds the lock --------
rm -rf "$SKH"; rm -f "$TD"/held-* "$TD"/release-*
mkdir -p "$TD/jobq"
hold D 'skills=confskill'; DPID=$!
wait_for "$TD/held-D" || bad "setup: D never acquired"
( OSRC_JOB_DIR="$TD/jobq" WITH_SPEC='skills=plugskill' _devin_with_prepare >/dev/null 2>&1; _devin_skills_lock_release ) &
QPID=$!
if wait_for "$TD/jobq/lockwait"; then ok "a queued job writes lockwait while it waits"; else bad "no lockwait file while queued"; fi
touch "$TD/release-D"; wait "$DPID"; wait "$QPID"; qrc=$?
[ "$qrc" -eq 0 ] && [ ! -e "$TD/jobq/lockwait" ] && ok "lockwait is removed once the job holds the lock" \
  || bad "lockwait left behind or queued job failed (rc=$qrc)"

# --- 7a. the bg watchdog, driven for real: a lock queue is not a no-init, the hard bound still is -----
# A fake delegate stands in for a queued dispatch: it writes lockwait, stays silent past the no-init
# deadline, clears lockwait, then answers. Same _supervise call shape as test_nowrite_watchdog.sh.
mkjd() { local jd="$OSRC_HOME/jobs/$1"; mkdir -p "$jd" "$TD/w-$1"
  printf '{"verb":"run","lane":"dv","cwd":"%s","model":"x","started":%s}' "$TD/w-$1" "$(date +%s)" > "$jd/meta.json"
  printf '%s' "$jd"; }
supq() { # <jd> <hard> <script>   (the script gets the job dir as $1)
  env OSRC_POLL=1 OSRC_NOINIT_SECS=3 OSRC_HEARTBEAT_DISABLED=1 OSRC_JOB_VERB=run bash -c '
    set -uo pipefail; export OSRC_SOURCED=1; . "$0" >/dev/null 2>&1
    _supervise "$1" 30 60 "$2" -- sh -c "$3" _ "$1"' "$SRC" "$1" "$2" "$3" >/dev/null 2>"$1/sup.err"; }
QUEUED='touch "$1/lockwait"; sleep 6; rm -f "$1/lockwait"; echo "hello from the model"; sleep 1; echo "OSRC::DONE"'
jd="$(mkjd wq)"; supq "$jd" 60 "$QUEUED"
case "$(cat "$jd/reason" 2>/dev/null)" in no-init:*) bad "a job queued on the grant lock past OSRC_NOINIT_SECS was killed as no-init" ;;
  *) case "$(cat "$jd/status" 2>/dev/null)" in ''|running|wedged) false ;; esac && grep -q 'OSRC::DONE' "$jd/out.log" && ok "the bg watchdog does not kill a lock-queued job as no-init (status $(cat "$jd/status"))" \
       || bad "a lock-queued job was wedged ($(cat "$jd/reason" 2>/dev/null))" ;; esac
jd="$(mkjd wn)"; supq "$jd" 60 'sleep 6; echo "hello from the model"'
case "$(cat "$jd/reason" 2>/dev/null)" in no-init:*) ok "control: the same silence WITHOUT lockwait is still a no-init kill" ;;
  *) bad "control: a silent job without lockwait was not killed as no-init (status $(cat "$jd/status"), reason $(cat "$jd/reason" 2>/dev/null))" ;; esac
jd="$(mkjd wh)"; supq "$jd" 4 'touch "$1/lockwait"; sleep 20'
grep -q '^hard-timeout:' "$jd/reason" 2>/dev/null && ok "lockwait never suspends the hard timeout" \
  || bad "a job parked in lockwait outlived the hard timeout (status $(cat "$jd/status"), reason $(cat "$jd/reason" 2>/dev/null))"

# --- 7b. a queued different-set waiter stops new same-set joiners from starving it ---------------
rm -rf "$SKH"; rm -f "$TD"/held-* "$TD"/release-*
hold A ''; APID=$!
wait_for "$TD/held-A" || bad "setup: A never acquired"
( WITH_SPEC='skills=confskill' OSRC_DEVIN_LOCK_WAIT_MAX=8 _devin_with_prepare >/dev/null 2>&1 \
    && _devin_skills_lock_release ) &
WPID=$!
wait_for "$LOCK.pending/$WPID" || bad "setup: the different-set waiter never filed a pending entry"
( WITH_SPEC='' OSRC_DEVIN_LOCK_WAIT_MAX=1 _devin_with_prepare ) >/dev/null 2>&1
[ $? -ne 0 ] && ok "a same-set dispatch can no longer join ahead of a queued different-set waiter" \
  || bad "a same-set joiner cut the line ahead of the pending waiter"
touch "$TD/release-A"; wait "$APID"
wait "$WPID"; wrc=$?
[ "$wrc" -eq 0 ] && [ ! -e "$LOCK.pending/$WPID" ] \
  && ok "the queued waiter gets the lock once the holder leaves and drops its pending entry" \
  || bad "queued waiter failed after the holder left (rc=$wrc) or left pending debris"

# --- 7c. a legacy pid-only lock (a pre-share outsourcerer) still blocks, judged by its pid -------
rm -rf "$SKH"; mkdir -p "$LOCK"
sleep 300 & LPID=$!
printf '%s\n' "$LPID" > "$LOCK/pid"
( WITH_SPEC='' OSRC_DEVIN_LOCK_WAIT_MAX=1 _devin_with_prepare ) >/dev/null 2>&1
[ $? -ne 0 ] && [ -d "$LOCK" ] && ok "a live legacy pid-only lock blocks an ungranted dispatch, untouched" \
  || bad "a live legacy lock was reaped or let a dispatch through"
kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
( WITH_SPEC='' OSRC_DEVIN_LOCK_WAIT_MAX=3 _devin_with_prepare >/dev/null 2>&1; _devin_skills_lock_release )
[ $? -eq 0 ] && [ ! -d "$LOCK" ] && ok "once the legacy holder dies the lock is reaped and the dispatch succeeds" \
  || bad "a dead legacy lock wedged the lane"

# --- 7d. the lock's creator may not re-scope the home under a live joiner -------------------------
rm -rf "$SKH"; rm -f "$TD"/held-* "$TD"/release-* "$TD"/reenter
# E re-enters in its own process: that is what makes the re-entry branch see pid == me. A die
# inside the second prepare ends the subshell, so its exit code IS the re-entry's result.
( WITH_SPEC='' _devin_with_prepare >/dev/null 2>&1 || exit 1
  : > "$TD/held-E"
  while [ ! -f "$TD/reenter" ]; do sleep 0.1 2>/dev/null || sleep 1; done
  WITH_SPEC='skills=confskill' OSRC_DEVIN_LOCK_WAIT_MAX=1 _devin_with_prepare >/dev/null 2>&1 \
    && _devin_skills_lock_release ) &
EPID=$!
wait_for "$TD/held-E" || bad "setup: creator E never acquired"
( WITH_SPEC='' _devin_with_prepare >/dev/null 2>&1 || exit 1
  : > "$TD/held-F"
  while [ ! -f "$TD/release-F" ]; do sleep 0.1 2>/dev/null || sleep 1; done
  _devin_skills_lock_release ) &
FPID=$!
wait_for "$TD/held-F" || bad "setup: joiner F never acquired"
touch "$TD/reenter"
wait "$EPID"; erc=$?
[ "$erc" -ne 0 ] && [ ! -e "$SKH/confskill" ] \
  && ok "the creator cannot re-scope the home while a same-set joiner is live" \
  || bad "the creator re-scoped the home under a live joiner"
touch "$TD/release-F"; wait "$FPID" 2>/dev/null

# --- 7e. a waiter filed while the creator is still scoping cannot be starved by joiners ---------
# Hand-build a creator mid-scoping (holders + pid, no grants yet), then queue an EMPTY-set waiter.
# A missing grants file reads as "" - the empty set - so before the ticket carried a set and was
# filed unconditionally, this waiter never queued and same-set joiners starved it after publish.
rm -rf "$SKH"
sleep 300 & SPID=$!
mkdir -p "$LOCK/holders"; : > "$LOCK/holders/$SPID"; printf '%s\n' "$SPID" > "$LOCK/pid"
( WITH_SPEC='' OSRC_DEVIN_LOCK_WAIT_MAX=8 _devin_with_prepare >/dev/null 2>&1 \
    && _devin_skills_lock_release ) &
WPID=$!
wait_for "$LOCK.pending/$WPID" || bad "setup: the pre-publish waiter never filed a pending ticket"
ln -sfn "$SK" "$SKH/confskill"; printf 'confskill\n' > "$LOCK/grants"   # the creator finishes scoping
sleep 2   # give the waiter another pass so its ticket is live and refreshed
# It must fail on the lock wait itself, not on some other prepare check.
( WITH_SPEC='skills=confskill' OSRC_DEVIN_LOCK_WAIT_MAX=1 _devin_with_prepare ) >/dev/null 2>"$TD/7e.err"
[ $? -ne 0 ] && grep -q 'held the skills-home grant lock' "$TD/7e.err" \
  && ok "a joiner cannot cut ahead of a different-set waiter filed before publish" \
  || bad "a joiner cut the line ahead of a waiter that queued while the creator was still scoping"
kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
wait "$WPID"; wrc=$?
[ "$wrc" -eq 0 ] && [ ! -e "$LOCK.pending/$WPID" ] \
  && ok "the pre-publish waiter gets the lock once the holder dies and drops its ticket" \
  || bad "pre-publish waiter failed after the holder died (rc=$wrc) or left pending debris"

# Two waiters for the SAME set queued before publish must not refuse each other once it lands.
rm -rf "$SKH"
sleep 300 & SPID=$!
mkdir -p "$LOCK/holders"; : > "$LOCK/holders/$SPID"; printf '%s\n' "$SPID" > "$LOCK/pid"
( WITH_SPEC='' OSRC_DEVIN_LOCK_WAIT_MAX=8 _devin_with_prepare >/dev/null 2>&1 \
    && _devin_skills_lock_release ) &
W1=$!
( WITH_SPEC='' OSRC_DEVIN_LOCK_WAIT_MAX=8 _devin_with_prepare >/dev/null 2>&1 \
    && _devin_skills_lock_release ) &
W2=$!
wait_for "$LOCK.pending/$W1" && wait_for "$LOCK.pending/$W2" \
  || bad "setup: a same-set waiter never filed a pending ticket"
: > "$LOCK/grants"
wait "$W1"; w1rc=$?
wait "$W2"; w2rc=$?
[ "$w1rc" -eq 0 ] && [ "$w2rc" -eq 0 ] \
  && ok "two same-set waiters queued before publish both join once the empty set lands" \
  || bad "same-set waiters blocked each other (rc=$w1rc/$w2rc)"
kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null

# --- 7g. a contended lock never writes stray diagnostics into the job log ------------------------
# The debris probe read a mutex pid file that its holder had just released, and `read < f 2>/dev/null`
# applies the input redirect before the stderr one, so bash printed "No such file or directory" on
# the dispatch's stderr (about 1 in 4 dispatches under a 10-wide fanout). That line lands in out.log,
# and classify then read it as a deliverable. Behavioral check plus a source guard for the shape.
rm -rf "$SKH"; mkdir -p "$TD/err"
for r in 1 2 3; do
  for w in 1 2 3 4 5 6 7 8; do
    ( WITH_SPEC='' _devin_with_prepare >/dev/null 2>>"$TD/err/$r.$w"; _devin_skills_lock_release 2>>"$TD/err/$r.$w" ) &
  done; wait
done
stray="$(cat "$TD"/err/* 2>/dev/null | grep -v 'waiting for the Devin skills-home grant lock')"
[ -z "$stray" ] && ok "24 contended same-set dispatches print nothing but the documented wait line" \
  || bad "stray stderr from contended dispatches: $(printf '%s' "$stray" | head -n 2)"
leaky="$(grep -nE '^[^#]*read( -r)? [A-Za-z_ ]+ < "[^"]+" 2>/dev/null' "$SRC")"
[ -z "$leaky" ] && ok "no 'read < file 2>/dev/null' (the redirect error escapes it; group with braces)" \
  || bad "leaky read redirect(s): $leaky"

# --- 8. classify: job-control notices and no-init jobs are not deliverables ----------------------
JOBS="$OSRC_HOME/jobs"
mkjob() {
  local jd="$JOBS/$1"; mkdir -p "$jd" "$TD/work-$1"
  printf 'wedged' > "$jd/status"; printf '125' > "$jd/exit"
  printf '{"cwd":"%s","lane":"dv"}\n' "$TD/work-$1" > "$jd/meta.json"
  cat > "$jd/last.txt" <<EOF
>>> [route] RESOLVED lane=devin model=swe-2-max explicit=--provider devin
>>> [outsourcerer] CLOUD DISCLOSURE: delegating to a CLOUD lane (devin / swe-2-max).
>>>   training    : paid/non-training route (no training on your data)
$SRC: line 2319: 80681 Terminated: 15          sleep 1
EOF
  cp "$jd/last.txt" "$jd/out.log"
}
mkjob jc-noise
printf 'stall-kill\n' > "$JOBS/jc-noise/reason"
v="$(_classify_job jc-noise)"
case "$v" in REUSE-OUTPUT*) bad "a bash Terminated notice was classified as a deliverable ($v)" ;;
  *) ok "a bash job-control notice is not a deliverable ($v)" ;; esac
mkjob jc-noinit
printf 'Some text that would otherwise look like a reply body.\n' >> "$JOBS/jc-noinit/last.txt"
printf 'no-init: delegate never started within 150s\n' > "$JOBS/jc-noinit/reason"
v="$(_classify_job jc-noinit)"
case "$v" in REUSE-OUTPUT*) bad "a no-init job was classified as reusable ($v)" ;;
  *) ok "a no-init job never has a deliverable ($v)" ;; esac
mkjob jc-abrt
printf 'stall-kill\n' > "$JOBS/jc-abrt/reason"
printf '%s: line 88: 4242 Abort trap: 6           devin -p x\n>>> [devin] waiting for the Devin skills-home grant lock: pid 1 holds it.\n' "$SRC" >> "$JOBS/jc-abrt/last.txt"
v="$(_classify_job jc-abrt)"
case "$v" in REUSE-OUTPUT*) bad "an Abort trap notice or the lock-wait line was classified as a deliverable ($v)" ;;
  *) ok "other signal notices and the lock-wait line are not deliverables ($v)" ;; esac
mkjob jc-diag
printf 'stall-kill\n' > "$JOBS/jc-diag/reason"
printf '%s: line 2339: %s/.outsourcerer-grants.lock.d.mx/pid: No such file or directory\n' "$SRC" "$SKH" >> "$JOBS/jc-diag/last.txt"
v="$(_classify_job jc-diag)"
case "$v" in REUSE-OUTPUT*) bad "an engine shell diagnostic was classified as a deliverable ($v)" ;;
  *) ok "any engine shell diagnostic (<path>/outsourcerer.sh: line N: ...) is not a deliverable ($v)" ;; esac
mkjob jc-real
printf 'stall-kill\n' > "$JOBS/jc-real/reason"
printf 'Here is the finished audit: three stale references fixed in README.md.\n' >> "$JOBS/jc-real/last.txt"
v="$(_classify_job jc-real)"
[ "$v" = "REUSE-OUTPUT	false-stall:deliverable" ] && ok "a real reply body after the banner is still a deliverable" \
  || bad "real deliverable no longer recognized ($v)"

HOME="$HOME_REAL"
echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
