#!/usr/bin/env bash
# test_job_lifecycle.sh — the launching->running->terminal lifecycle and the phantom-job guards:
# a detached worker that never comes up must NOT become a status=running job with a ~56-year age that
# no watcher reaps. It must become `failed` (stillborn) with a sane age and a reason, and it must stay
# VISIBLE in `status --json` (never silently dropped for lacking meta.json).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required"; exit 1; }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"; mkdir -p "$OSRC_HOME/jobs"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

run(){ OSRC_HOME="$OSRC_HOME" bash "$SRC" "$@"; }

# --- Scenario 1: a STILLBORN job (launching sentinel, old start, no pid/log) -> failed, sane age. ---
JD="$OSRC_HOME/jobs/20260101-000000-stillborn"; mkdir -p "$JD"
echo launching > "$JD/status"; echo $(( $(date +%s) - 120 )) > "$JD/started_at"
line="$(run status 2>/dev/null | grep stillborn)"
echo "$line" | grep -q ' failed ' && ok "stillborn launching job -> failed" || bad "stillborn not marked failed ($line)"
echo "$line" | grep -qE '\b(1[0-9]{2}|[1-9][0-9])s\b' && ok "stillborn age is sane seconds, not a 56-year epoch age" \
  || bad "stillborn age not sane ($line)"
[ -s "$JD/error" ] && grep -qi 'stillborn' "$JD/error" && ok "stillborn reason recorded (actionable)" || bad "no stillborn reason"

# --- Scenario 2: the phantom is VISIBLE in status --json (not silently dropped for missing meta). ---
js="$(run status --json 2>/dev/null)"
echo "$js" | jq -e '.jobs[] | select(.job_id|test("stillborn"))' >/dev/null 2>&1 \
  && ok "meta-less job appears in status --json (control plane sees it)" \
  || bad "meta-less job dropped from status --json (phantom invisible)"
echo "$js" | jq -e '.jobs[] | select(.job_id|test("stillborn")) | .status=="failed"' >/dev/null 2>&1 \
  && ok "json reflects the failed status" || bad "json status wrong"

# --- Scenario 3: a meta-less job with NO start time shows age '?', never a 56-year age. ---
JD2="$OSRC_HOME/jobs/20260101-000001-noage"; mkdir -p "$JD2"; echo running > "$JD2/status"
aline="$(run status 2>/dev/null | grep noage)"
echo "$aline" | grep -q ' ? ' && ok "unknown start time shows age '?', not a fabricated 56-year age" \
  || bad "unknown-age job did not show '?' ($aline)"
echo "$aline" | grep -qE '17[0-9]{8}s|5[0-9] year' && bad "56-year phantom age is back" || ok "no 56-year phantom age"


# --- A dead job must not read as alive on ANY path. ---------------------------------------------
# status files record what was true when written. A delegate killed after "running" was written
# leaves that word on disk forever, so every reader that trusts it reports a corpse as a live job.
# The text path reconciled; the JSON control plane and the fanout waiter did not — which is how
# `status --json` showed phantom running jobs and how `fanout wait` could block on a dead member.
. "$SRC" >/dev/null 2>&1                 # need the functions themselves, not the CLI
OSRC_JOBS="$OSRC_HOME/jobs"
have() { command -v "$1" >/dev/null 2>&1; }

mkjob() { # <id> <status> — a job whose recorded pid is dead
  local jd="$OSRC_JOBS/$1"; mkdir -p "$jd"
  ( exec sh -c 'exit 0' ) & local p=$!; wait "$p" 2>/dev/null
  printf '%s\n' "$p" > "$jd/pid"; printf 'never-matches\n' > "$jd/pid_start"
  printf '%s\n' "$2" > "$jd/status"; date +%s > "$jd/started_at"
}
for st in running "stalled?" "exploring?"; do
  mkjob "dead-${st%\?}" "$st"
  got="$(_reconcile_status "dead-${st%\?}")"
  [ "$got" = "interrupted" ] \
    && ok "a dead job recorded as '$st' reconciles to interrupted" \
    || bad "dead job recorded as '$st' still reads '$got'"
done

# The JSON control plane must agree with the text path — an orchestrator polls JSON, not prose.
if have jq; then
  mkjob dead-json running
  j="$(_job_json dead-json 2>/dev/null | jq -r '.status' 2>/dev/null)"
  [ "$j" = "interrupted" ] && ok "status --json reports a dead job as interrupted, not running" \
    || bad "status --json still reports '$j' for a dead job (phantom on the control plane)"
fi

# A supervisor pid that has been RECYCLED by an unrelated process must not resurrect a dead job.
mkjob dead-suprecycle running
printf '%s\n' "$$" > "$OSRC_JOBS/dead-suprecycle/supervisor_pid"      # live pid...
printf 'a-different-start-time\n' > "$OSRC_JOBS/dead-suprecycle/supervisor_pid_start"  # ...but not ours
got="$(_reconcile_status dead-suprecycle)"
[ "$got" = "interrupted" ] \
  && ok "a recycled supervisor pid does not resurrect a dead job" \
  || bad "recycled supervisor pid reported the job as '$got' (liveness fails open)"


# --- A slow setup phase is not a dead job. --------------------------------------------------------
# `git worktree add` on a large repo runs BEFORE the supervisor writes a pid or out.log, which is the
# exact signature of a job the environment killed. Judged by the 45s launch grace, a healthy job that
# is merely slow to start gets reported as stillborn and the user chases a failure that never happened.
JD3="$OSRC_HOME/jobs/20260101-000002-setup"; mkdir -p "$JD3"
echo launching > "$JD3/status"; echo $(( $(date +%s) - 300 )) > "$JD3/started_at"   # 5 min in
printf 'worktree\n' > "$JD3/setup"
st="$(_reconcile_status 20260101-000002-setup >/dev/null 2>&1; run status 20260101-000002-setup 2>/dev/null | awk '{print $2}')"
[ "$st" = "launching" ] \
  && ok "a job still in its setup phase stays launching past the 45s grace" \
  || bad "slow setup was declared stillborn (got '$st')"

# ...but a setup phase that hangs forever must still terminate, not become a permanent phantom.
echo $(( $(date +%s) - 2000 )) > "$JD3/started_at"
st="$(run status 20260101-000002-setup 2>/dev/null | awk '{print $2}')"
[ "$st" = "failed" ] && ok "a setup phase that never finishes still fails (bounded, not phantom)" \
  || bad "hung setup never terminated (got '$st')"
grep -qi 'setup phase' "$JD3/error" 2>/dev/null \
  && ok "the failure names the setup phase, not a generic launcher failure" \
  || bad "setup failure message is not specific"


# --- The 0-writes flag must actually reach the operator. -----------------------------------------
# _job_acts is read through a command substitution, so a value it EXPORTED died with the subshell and
# the caller saw its default forever. The flag that tells you "this mutating job has read and grepped
# for minutes and written nothing" could therefore never appear — the one signal that distinguishes a
# delegate exploring in circles from one doing the work.
jd4="$OSRC_HOME/jobs/x-explore"; mkdir -p "$jd4"
sleep 60 & LP=$!
printf '%s\n' '{"name":"Read"}' '{"name":"Read"}' '{"name":"Bash"}' > "$jd4/out.log"
echo running > "$jd4/status"; echo $(( $(date +%s) - 400 )) > "$jd4/started_at"
echo "$LP" > "$jd4/pid"; ps -o lstart= -p "$LP" | tr -s ' ' > "$jd4/pid_start"
printf '{"verb":"edit","model":"glm","started":%s}' "$(( $(date +%s) - 400 ))" > "$jd4/meta.json"
_status_line x-explore 2>/dev/null | grep -q 'exploring(0-writes)' \
  && ok "a mutating job with zero writes is flagged to the operator" \
  || bad "0-writes flag never reaches the caller (exported from a subshell?)"
printf '%s\n' '{"name":"Write"}' >> "$jd4/out.log"
_status_line x-explore 2>/dev/null | grep -q 'exploring(0-writes)' \
  && bad "flag still set after the job started writing" \
  || ok "the flag clears as soon as real writes appear"
kill $LP 2>/dev/null


# --- Progress is work, not chatter. ---------------------------------------------------------------
# The stall watchdog measured log growth, so it measured how TALKATIVE a delegate is. A delegate that
# prints nothing while writing files is working, and killing it is a failure the watchdog causes
# rather than prevents — including delegates following this tool's own advice to write findings to a
# file and print only at the end. The log cannot answer this (a silent delegate emits no tool-call
# markers either), so the filesystem is consulted at the moment of judgement.
W="$OSRC_HOME/fswork"; mkdir -p "$W"
jda="$OSRC_HOME/jobs/fs-dead"; mkdir -p "$jda"; printf '{"cwd":"%s"}' "$W" > "$jda/meta.json"
OSRC_POLL=1 _supervise "$jda" 1 3 30 -- sh -c 'printf "%s\n" ">>> banner"; sleep 10' >/dev/null 2>&1
[ "$(cat "$jda/status" 2>/dev/null)" = "wedged" ] \
  && ok "a job that is silent AND writing nothing is still killed" \
  || bad "watchdog stopped killing genuinely dead jobs (got '$(cat "$jda/status" 2>/dev/null)')"

jdb="$OSRC_HOME/jobs/fs-worker"; mkdir -p "$jdb"; printf '{"cwd":"%s"}' "$W" > "$jdb/meta.json"
OSRC_POLL=1 _supervise "$jdb" 1 3 30 -- sh -c 'printf "%s\n" ">>> banner"; for i in 1 2 3 4 5 6 7 8; do sleep 1; date > "'"$W"'/o.$i"; done; printf "%s\n" "OSRC::DONE"' >/dev/null 2>&1
[ "$(cat "$jdb/status" 2>/dev/null)" = "done" ] \
  && ok "a delegate writing files survives the stall window while silent" \
  || bad "silent-but-working delegate was killed (got '$(cat "$jdb/status" 2>/dev/null)')"

# The check must use POSIX -newer: -newermt @epoch is a GNU extension that BSD find fails to parse,
# which would make this guard quietly dead on macOS — passing tests, protecting nothing.
grep -v '^[[:space:]]*#' "$SRC" | grep -q -- '-newermt' && bad "filesystem-progress check uses the GNU-only -newermt" \
  || ok "filesystem-progress check is POSIX (-newer), so it works on BSD find too"


# --- "no log" must say WHICH kind of no-log. -----------------------------------------------------
# A job that is still starting, a job id that does not exist, and a job that died before writing all
# produced the identical "no log for <id>". The status file that distinguishes them sits right beside
# the missing log and was never consulted, so the message sent people hunting for a broken job when
# the answer was "wait a moment", or hunting for a typo when the id was fine.
jl="$OSRC_HOME/jobs/still-launching"; mkdir -p "$jl"
echo launching > "$jl/status"; date +%s > "$jl/started_at"
out="$(run logs still-launching 2>&1)"
printf '%s' "$out" | grep -qi 'still starting up' \
  && ok "a launching job says it is still starting, not that the log is missing" \
  || bad "launching job still reports a bare missing-log error: $(printf '%s' "$out" | tail -1)"
printf '%s' "$out" | grep -q 'watch still-launching' \
  && ok "the message offers the command that shows the job live" \
  || bad "no actionable next step for a launching job"

out="$(run logs no-such-job-id 2>&1)"
printf '%s' "$out" | grep -qi 'no such job' \
  && ok "an unknown job id is reported as unknown, not as a missing log" \
  || bad "unknown job id is indistinguishable from a missing log"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
