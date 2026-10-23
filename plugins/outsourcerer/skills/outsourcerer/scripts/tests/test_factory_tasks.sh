#!/usr/bin/env bash
# test_factory_tasks.sh -- factory track B: the plan/task store, readiness, claim atomicity, the
# context-handoff brief, hold/release, cancel/retry, done fallback, corrupt-file handling, and the
# CLI through a PATH symlink. No real delegate ever runs: _task_bg_launch is overridden after
# sourcing (the single seam into cmd_bg), except one end-to-end launch through the REAL bg path with
# a fake droid binary to prove the predicted worktree path/branch/base match what bg records.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

# Outside this checkout (system temp), and git told not to look above it, so no test repo, worktree or
# branch can ever land in the real repository.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-factory-tasks.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
export GIT_CEILING_DIRECTORIES="$(dirname "$TMP")"
HOME="$TMP/home"; export HOME; mkdir -p "$HOME"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"; mkdir -p "$OSRC_HOME"
export OSRC_FLEET_SUPERVISION=0 OSRC_HEARTBEAT_DISABLED=1 OSRC_BLIND_TURN_GUARD=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# A small git repo for ship tasks.
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main 2>/dev/null || { git -C "$REPO" init -q; git -C "$REPO" checkout -q -b main; }
echo hi > "$REPO/a.txt"; git -C "$REPO" add a.txt; git -C "$REPO" commit -q -m init
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

# Library harness: source the real script (factory files load from its folder), stub the launcher.
LIB="$TMP/lib.sh"
cat > "$LIB" <<EOF
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
LAUNCH_LOG="$TMP/launches"
_task_bg_launch() {
  local wd="\$1"; shift
  sleep "\${STUB_SLEEP:-0}"
  local id="20261022-120000-\$(printf '%06d' \$RANDOM)\${RANDOM}"
  mkdir -p "\$OSRC_JOBS/\$id"; echo running > "\$OSRC_JOBS/\$id/status"
  printf '%s|%s|%s|%s|%s\n' "\$id" "\$wd" "\${OSRC_WORKTREE:-}" "\${OSRC_WORKTREE_BASE:-}" "\${OSRC_TASK_REF:-}" >> "\$LAUNCH_LOG"
  printf '%s\n' "\$@" > "\$OSRC_JOBS/\$id/argv"
  [ "\${STUB_FAIL:-0}" = 1 ] && { echo "ERROR: stub refused" >&2; return 1; }
  echo "\$id"
}
EOF
L() { bash -c ". \"$LIB\"; $1"; }
O() { bash "$SRC" "$@"; }

# ---- loading
check "sourcing outsourcerer.sh loads the factory library" "L 'type _task_dispatch >/dev/null && type cmd_plan >/dev/null'"
mkdir -p "$TMP/bin"; ln -s "$SRC" "$TMP/bin/outsourcerer"
out="$(cd "$TMP" && PATH="$TMP/bin:$PATH" outsourcerer plan ls 2>&1)"
check "CLI through a PATH symlink finds factory-tasks.sh" "printf '%s' \"\$out\" | grep -q 'No plans yet'"

# ---- plan new / current / use
out="$(cd "$REPO" && O plan new alpha --goal 'ship the thing' 2>&1)"
pj="$OSRC_HOME/plans/alpha/plan.json"
check "plan new writes plan.json with schema, goal, repo, base_branch" \
  "[ \"\$(jq -r '[.schema,.name,.goal,.repo,.base_branch]|join(\"|\")' \"$pj\")\" = \"1|alpha|ship the thing|$REPO|main\" ]"
check "plan new makes the plan current" "[ \"\$(cat \"$OSRC_HOME/plans/current\")\" = alpha ]"
out="$(cd "$REPO" && O plan new alpha 2>&1)"; rc=$?
check "plan new refuses a duplicate name" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'already exists'"
out="$(cd "$TMP" && O plan new beta --no-repo --no-use 2>&1)"
check "--no-use keeps the current plan" "[ \"\$(cat \"$OSRC_HOME/plans/current\")\" = alpha ] && [ \"\$(jq -r .repo \"$OSRC_HOME/plans/beta/plan.json\")\" = '' ]"
O plan use beta >/dev/null 2>&1
check "plan use switches the current plan" "[ \"\$(cat \"$OSRC_HOME/plans/current\")\" = beta ]"
O plan use alpha >/dev/null 2>&1
out="$(O plan use nope 2>&1)"; rc=$?
check "plan use of a missing plan fails plainly" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'no plan named'"
out="$(O plan new 'bad name' 2>&1)"; rc=$?
check "invalid plan names are refused" "[ $rc -ne 0 ]"

# ---- ids + deps + readiness
SPEC="$TMP/spec.md"; printf 'SPEC-LINE-ONE\nThe widget must be blue.\n' > "$SPEC"
t1="$(O task add 'scout auth' --prompt 'map the auth flow' 2>/dev/null)"
t2="$(O task add 'build login' --shape ship --deps t1 --spec "$SPEC" --check 'make test' -m glm 2>/dev/null)"
t3="$(O task add 'write docs' --deps t1,t2 2>/dev/null)"
t4="$(O task add 'independent' 2>/dev/null)"
check "task ids are allocated t1..t4 in order" "[ \"$t1 $t2 $t3 $t4\" = 't1 t2 t3 t4' ]"
check "task JSON carries the contract fields and defaults" \
  "[ \"\$(jq -r '[.schema,.state,.shape,.verb,.deliver,.retries,.attempts,(.deps|join(\",\")),.model,.check]|join(\"|\")' \"$OSRC_HOME/plans/alpha/tasks/t2.json\")\" = '1|todo|ship|edit|local|1|0|t1|glm|make test' ]"
check "a scout task defaults to verb run and prompt = title when none given" \
  "[ \"\$(jq -r '.verb + \"|\" + .prompt' \"$OSRC_HOME/plans/alpha/tasks/t4.json\")\" = 'run|independent' ]"
check "spec is stored as an absolute path" "[ \"\$(jq -r .spec \"$OSRC_HOME/plans/alpha/tasks/t2.json\")\" = \"$SPEC\" ]"
out="$(O task add 'orphan' --deps t9 2>&1)"; rc=$?
check "a dependency on a task that does not exist is refused" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 't9 does not exist'"
check "ready = todo with every dep done (t1, t4)" "[ \"\$(L '_task_ready alpha' | tr '\n' ' ')\" = 't1 t4 ' ]"
check "derived state marks t2/t3 blocked" \
  "[ \"\$(L '_task_view alpha' | jq -r 'map(select(.derived==\"blocked\"))|map(.id)|join(\",\")')\" = 't2,t3' ]"

# ---- _task_update + events
L "_task_update alpha t1 '.state = \"done\" | .result = \"auth uses JWT in cookies\"'"
check "_task_update applies the filter and bumps updated" \
  "[ \"\$(jq -r .state \"$OSRC_HOME/plans/alpha/tasks/t1.json\")\" = done ] && [ -n \"\$(jq -r .updated \"$OSRC_HOME/plans/alpha/tasks/t1.json\")\" ]"
check "a state change is logged to events.jsonl" \
  "jq -e 'select(.task==\"t1\" and .event==\"state\" and .from==\"todo\" and .to==\"done\")' \"$OSRC_HOME/plans/alpha/events.jsonl\" >/dev/null"
before="$(cat "$OSRC_HOME/plans/alpha/tasks/t4.json")"
L "_task_update alpha t4 'error(\"nope\")'" 2>/dev/null; rc=$?
check "an erroring filter changes nothing and returns 1" "[ $rc -ne 0 ] && [ \"\$(cat \"$OSRC_HOME/plans/alpha/tasks/t4.json\")\" = \"\$before\" ]"
check "after t1 is done, t2 becomes ready (dependency order: t4 depth 0 first)" \
  "[ \"\$(L '_task_ready alpha' | tr '\n' ' ')\" = 't4 t2 ' ]"

# ---- dispatch (stubbed launcher)
jid="$(L '_task_dispatch alpha t2' 2>/dev/null)"; rc=$?
t2j="$OSRC_HOME/plans/alpha/tasks/t2.json"
check "dispatch prints the job id and records it" "[ $rc -eq 0 ] && [ -n \"$jid\" ] && [ \"\$(jq -r .job \"$t2j\")\" = \"$jid\" ] && [ \"\$(jq -r '.jobs|length' \"$t2j\")\" = 1 ]"
check "dispatch moves the task to running and counts the attempt" "[ \"\$(jq -r '.state + \"|\" + (.attempts|tostring)' \"$t2j\")\" = 'running|1' ]"
check "ship dispatch records worktree, branch, base_sha" \
  "[ \"\$(jq -r '[.worktree,.branch,.base_sha]|join(\"|\")' \"$t2j\")\" = \"$REPO/.outsourcerer/worktrees/$jid|outsourcerer/$jid|$HEAD_SHA\" ]"
line="$(grep "^$jid|" "$TMP/launches")"
check "ship launch runs in the plan repo with OSRC_WORKTREE=1 pinned to the base commit and a task ref" \
  "[ \"\$line\" = \"$jid|$REPO|1|$HEAD_SHA|alpha/t2\" ]"
check "the launch passes the task's verb and model" \
  "[ \"\$(sed -n 1,3p \"$OSRC_HOME/jobs/$jid/argv\" | tr '\n' '|')\" = 'edit|-m|glm|' ]"
# #8: a small brief goes inline (lanes that can't read outside their workspace still get it);
# a large one goes by absolute path so the command line stays bounded.
argvp="$(sed -n '4,$p' "$OSRC_HOME/jobs/$jid/argv")"
check "the worker prompt names the task title and plan goal" \
  "printf '%s' \"\$argvp\" | grep -q '^Task alpha/t2: build login\$' && printf '%s' \"\$argvp\" | grep -q '^Plan goal: ship the thing\$'"
check "a small brief is passed inline, with the saved copy's path" \
  "printf '%s' \"\$argvp\" | grep -q '^# Task alpha/t2: build login' && printf '%s' \"\$argvp\" | grep -qF \"Saved copy: $OSRC_HOME/plans/alpha/tasks/t2/brief.md\""
bigp="$(OSRC_BRIEF_INLINE_MAX=10 L "_task_worker_prompt alpha t2 '$OSRC_HOME/plans/alpha/tasks/t2/brief.md'")"
check "a brief over the inline cap is passed by absolute path, and the prompt stays short" \
  "printf '%s' \"\$bigp\" | grep -qF \"read your full brief: $OSRC_HOME/plans/alpha/tasks/t2/brief.md\" && ! printf '%s' \"\$bigp\" | grep -q '^# Task alpha' && [ \"\$(printf '%s' \"\$bigp\" | wc -c | tr -d ' ')\" -lt 1200 ]"
check "the job dir gets a task_ref back-link" "[ \"\$(cat \"$OSRC_HOME/jobs/$jid/task_ref\")\" = alpha/t2 ]"
out="$(L '_task_dispatch alpha t2' 2>&1)"; rc=$?
check "dispatching a running task is refused" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'already underway'"
out="$(L '_task_dispatch alpha t3' 2>&1)"; rc=$?
check "dispatching a blocked task is refused and names the blocker" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'waits on t2 (running)'"
jid4="$(L '_task_dispatch alpha t4' 2>/dev/null)"
check "scout dispatch does not ask for a worktree" "grep -q \"^$jid4|$REPO|0||alpha/t4\$\" \"$TMP/launches\""

# ---- claim atomicity: two concurrent dispatches of one task, exactly one wins
t5="$(O task add 'race me' 2>/dev/null)"
: > "$TMP/race"
for i in 1 2 3; do ( STUB_SLEEP=0.2 L "_task_dispatch alpha $t5" >> "$TMP/race" 2>/dev/null ) & done
wait
check "concurrent dispatch: exactly one launch wins" \
  "[ \"\$(grep -c . \"$TMP/race\")\" = 1 ] && [ \"\$(grep -c 'alpha/$t5\$' \"$TMP/launches\")\" = 1 ] && [ \"\$(jq -r .attempts \"$OSRC_HOME/plans/alpha/tasks/$t5.json\")\" = 1 ]"
: > "$TMP/adds"
for i in 1 2 3 4 5; do ( O task add "par $i" >> "$TMP/adds" 2>/dev/null ) & done
wait
check "concurrent task add allocates five distinct ids" "[ \"\$(sort -u \"$TMP/adds\" | grep -c '^t[0-9]')\" = 5 ]"

# ---- launch failure is surfaced, not silent
t6="$(O task add 'will not launch' 2>/dev/null)"
out="$(STUB_FAIL=1 L "_task_dispatch alpha $t6" 2>&1)"; rc=$?
check "a failed launch fails the task with a reason" \
  "[ $rc -ne 0 ] && [ \"\$(jq -r .state \"$OSRC_HOME/plans/alpha/tasks/$t6.json\")\" = failed ] && jq -r .result \"$OSRC_HOME/plans/alpha/tasks/$t6.json\" | grep -q 'did not launch'"
check "a failed task raises a wake event for the heartbeat" \
  "grep -q '\"kind\":\"factory-task\".*\"task\":\"$t6\".*\"task_state\":\"failed\"' \"$OSRC_HOME/wake-queue.jsonl\""

# ---- the brief (context handoff)
# Make t2 a finished ship task with a report and t1's output in its job.
mkdir -p "$OSRC_HOME/jobs/J1"; echo done > "$OSRC_HOME/jobs/J1/status"
printf 'FULL-SCOUT-OUTPUT: login posts to /api/session\n' > "$OSRC_HOME/jobs/J1/last.txt"
L "_task_update alpha t1 '.job = \"J1\" | .hold.answer = \"use cookies, not localStorage\"'"
L "_task_update alpha t2 '.state = \"done\" | .result = \"login form built\" | .head_sha = \"abc123\"'"
mkdir -p "$OSRC_HOME/plans/alpha/tasks/t2"; printf 'REPORT-T2: added LoginForm.tsx\n' > "$OSRC_HOME/plans/alpha/tasks/t2/report.md"
L "_task_update alpha t3 '.state = \"held\" | .hold = {reason:\"tone: formal or casual?\",until:\"\",answer:\"\"}'"
O task release t3 --answer 'casual, short sentences' >/dev/null 2>&1
bp="$(L '_task_brief alpha t3')"
B="$(cat "$bp" 2>/dev/null)"
has() { printf '%s' "$B" | grep -qF -- "$1"; }
check "brief path is tasks/<tid>/brief.md" "[ \"$bp\" = \"$OSRC_HOME/plans/alpha/tasks/t3/brief.md\" ]"
check "brief opens with the plan goal" "has 'Plan goal: ship the thing'"
check "brief carries the task prompt" "has '## Your task' && has 'write docs'"
check "brief names each dependency with title and state" "has '### t1: scout auth (scout, done)' && has '### t2: build login (ship, done)'"
check "brief carries dep result summaries" "has 'Summary: auth uses JWT in cookies' && has 'Summary: login form built'"
check "brief carries dep output from the job's last.txt" "has 'FULL-SCOUT-OUTPUT: login posts to /api/session'"
check "brief prefers a dep's report.md and links the full report" "has 'REPORT-T2: added LoginForm.tsx' && has \"Full report: $OSRC_HOME/plans/alpha/tasks/t2/report.md\""
check "brief gives ship deps' branch and head commit" "has 'branch \`outsourcerer/' && has 'at commit abc123'"
check "brief carries a dependency's captain answer" "has 'Captain decided on t1: use cookies, not localStorage'"
check "brief carries this task's own captain decision" "has '## Decision from the captain' && has 'Question: tone: formal or casual?' && has 'casual, short sentences'"
check "a scout brief says change nothing" "has 'Do not change any files'"
b2="$(cat "$(L '_task_brief alpha t2')")"
check "a ship brief carries the spec contents and the check" \
  "printf '%s' \"\$b2\" | grep -q 'SPEC-LINE-ONE' && printf '%s' \"\$b2\" | grep -qF '\`make test\`' && printf '%s' \"\$b2\" | grep -q 'Commit your finished work'"
# bounded: a huge dep output is trimmed; a huge spec is linked not pasted
head -c 20000 /dev/zero | tr '\0' 'x' > "$OSRC_HOME/jobs/J1/last.txt"
BIG="$TMP/big.md"; head -c 70000 /dev/zero | tr '\0' 'y' > "$BIG"
t7="$(O task add 'big' --deps t1 --spec "$BIG" 2>/dev/null)"
b7="$(cat "$(L "_task_brief alpha $t7")")"
check "brief caps each dependency's output (~4KB) with a visible trim marker" \
  "[ \"\$(printf '%s' \"\$b7\" | wc -c | tr -d ' ')\" -lt 8000 ] && printf '%s' \"\$b7\" | grep -q 'trimmed'"
check "a spec over 64KB is linked by path, not pasted" "printf '%s' \"\$b7\" | grep -q \"Read it in full before you start: $BIG\""

# ---- hold / release
out="$(O task hold t4 --reason 'is this still needed?' 2>&1)"; rc=$?
check "hold refuses a running task" "[ $rc -ne 0 ]"
O task hold "$t7" --reason 'pick A or B' --until 'Friday' >/dev/null 2>&1
check "hold sets state held with reason and until" \
  "[ \"\$(jq -r '.state + \"|\" + .hold.reason + \"|\" + .hold.until' \"$OSRC_HOME/plans/alpha/tasks/$t7.json\")\" = 'held|pick A or B|Friday' ]"
check "hold raises a wake event" "grep -q '\"task\":\"$t7\".*\"task_state\":\"held\"' \"$OSRC_HOME/wake-queue.jsonl\""
out="$(L "_task_dispatch alpha $t7" 2>&1)"; rc=$?
check "a held task cannot be dispatched" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'held for a decision'"
show="$(O plan show 2>&1)"
check "plan show puts held and failed tasks in Captain's Call" \
  "printf '%s' \"\$show\" | sed -n \"/^Captain's Call/,/^Done/p\" | grep -q \"$t7 \\[held\\] big - needs a decision: pick A or B\" && printf '%s' \"\$show\" | sed -n \"/^Captain's Call/,/^Done/p\" | grep -q \"$t6 \\[failed\\]\""
out="$(O task release "$t7" 2>&1)"; rc=$?
check "release without an answer is refused" "[ $rc -ne 0 ]"
O task release "$t7" --answer 'B' >/dev/null 2>&1
check "release returns the task to todo with the answer kept" \
  "[ \"\$(jq -r '.state + \"|\" + .hold.answer' \"$OSRC_HOME/plans/alpha/tasks/$t7.json\")\" = 'todo|B' ]"
out="$(O task release "$t7" --answer 'again' 2>&1)"; rc=$?
check "release of a task that is not held is refused" "[ $rc -ne 0 ]"
t8="$(O task add 'pick winner' --hold 'which candidate?' 2>/dev/null)"
O task release "$t8" --answer 'candidate 2' --done >/dev/null 2>&1
check "release --done closes a decision task with the answer as its result" \
  "[ \"\$(jq -r '.state + \"|\" + .result' \"$OSRC_HOME/plans/alpha/tasks/$t8.json\")\" = 'done|candidate 2' ]"

# ---- failed dep blocks dependents; cancel/retry
t9="$(O task add 'after failed' --deps "$t6" 2>/dev/null)"
check "a failed dependency keeps dependents blocked" \
  "[ \"\$(L '_task_view alpha' | jq -r --arg id $t9 '.[]|select(.id==\$id)|.derived + \"|\" + (.blocked_by|map(.id+\":\"+.state)|join(\",\"))')\" = \"blocked|$t6:failed\" ]"
show="$(O plan show 2>&1)"
check "plan show names the failed blocker as needing the captain" "printf '%s' \"\$show\" | grep -q \"$t9 \\[blocked\\] after failed - waiting on $t6 (failed), needs the captain\""
check "plan show lists dependencies" "printf '%s' \"\$show\" | grep -q '^  t3 <- t1, t2\$'"
O task retry "$t6" >/dev/null 2>&1
check "retry puts a failed task back to todo and clears its job" \
  "[ \"\$(jq -r '.state + \"|\" + .job' \"$OSRC_HOME/plans/alpha/tasks/$t6.json\")\" = 'todo|' ]"
out="$(O task retry "$t6" 2>&1)"; rc=$?
check "retry of a todo task is refused" "[ $rc -ne 0 ]"
O task cancel "$t6" >/dev/null 2>&1
check "cancel marks the task canceled" "[ \"\$(jq -r .state \"$OSRC_HOME/plans/alpha/tasks/$t6.json\")\" = canceled ]"
check "a canceled dependency keeps dependents blocked" \
  "[ \"\$(L '_task_view alpha' | jq -r --arg id $t9 '.[]|select(.id==\$id)|.derived')\" = blocked ]"
O task retry "$t6" >/dev/null 2>&1
check "retry also revives a canceled task" "[ \"\$(jq -r .state \"$OSRC_HOME/plans/alpha/tasks/$t6.json\")\" = todo ]"
b6="$(cat "$(L "_task_brief alpha $t6")")"
check "a retried task's brief tells the worker what went wrong before" "printf '%s' \"\$b6\" | grep -q '## Earlier attempt'"

# ---- task done: fallback contract, then track C's hook when present
L "_task_update alpha t4 '.job = \"J4\"'"; mkdir -p "$OSRC_HOME/jobs/J4"; echo running > "$OSRC_HOME/jobs/J4/status"
out="$(O task done t4 2>&1)"; rc=$?
check "done refuses while the job is still running and restores the state" \
  "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'still running' && [ \"\$(jq -r .state \"$OSRC_HOME/plans/alpha/tasks/t4.json\")\" = running ]"
echo done > "$OSRC_HOME/jobs/J4/status"; printf 'Independent finding: all good\n' > "$OSRC_HOME/jobs/J4/last.txt"
out="$(O task done t4 2>&1)"; rc=$?
check "done passes on a finished job with a result (fallback contract)" "[ $rc -eq 0 ] && [ \"\$(jq -r .state \"$OSRC_HOME/plans/alpha/tasks/t4.json\")\" = done ]"
check "done copies a scout's output to report.md and fills the result" \
  "grep -q 'Independent finding' \"$OSRC_HOME/plans/alpha/tasks/t4/report.md\" && jq -r .result \"$OSRC_HOME/plans/alpha/tasks/t4.json\" | grep -q 'Independent finding'"
check "done passes through verifying (logged)" \
  "jq -e 'select(.task==\"t4\" and .to==\"verifying\")' \"$OSRC_HOME/plans/alpha/events.jsonl\" >/dev/null"
L "_task_update alpha $t5 '.job = \"J5\"'"; mkdir -p "$OSRC_HOME/jobs/J5"; echo done > "$OSRC_HOME/jobs/J5/status"; echo x > "$OSRC_HOME/jobs/J5/last.txt"
out="$(bash -c ". \"$LIB\"; _factory_done_check() { echo 'contract says no: no commits'; return 1; }; cmd_task done $t5" 2>&1)"; rc=$?
check "done uses _factory_done_check when track C defines it" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'contract says no'"
out="$(bash -c ". \"$LIB\"; _factory_done_check() { _task_update \"\$1\" \"\$2\" '.evidence = \$e | .head_sha = \$h' --arg e /x/evidence.json --arg h feed; echo 'contract ok'; return 0; }; cmd_task done $t5" 2>&1)"; rc=$?
check "a done check that writes the task itself (track C style) does not deadlock and is honored" \
  "[ $rc -eq 0 ] && [ \"\$(jq -r '.state + \"|\" + .evidence + \"|\" + .head_sha' \"$OSRC_HOME/plans/alpha/tasks/$t5.json\")\" = 'done|/x/evidence.json|feed' ]"
L "_task_update alpha $t5 '.state = \"running\" | .landed = true | .landed_into = \"main\" | .landed_sha = \"0123456789abcdef\" | .pr = \"https://example.invalid/pr/1\"'"
out="$(O task show "$t5" 2>&1)"
check "task show displays landed status and PR when track C set them" \
  "printf '%s' \"\$out\" | grep -q 'landed:   yes into main at 0123456789ab' && printf '%s' \"\$out\" | grep -q 'pr:       https://example.invalid/pr/1'"
O task done "$t5" --force --result 'did it by hand' >/dev/null 2>&1
check "done --force marks done by hand with a result" "[ \"\$(jq -r '.state + \"|\" + .result' \"$OSRC_HOME/plans/alpha/tasks/$t5.json\")\" = 'done|did it by hand' ]"
out="$(O task fail t4 --reason x 2>&1)"; rc=$?
check "fail of a done task is refused" "[ $rc -ne 0 ]"

# ---- ls / show / ready CLI
out="$(O task ls 2>&1)"
check "task ls prints a table with derived states" "printf '%s' \"\$out\" | grep -q '^ID' && printf '%s' \"\$out\" | grep -q 'scout auth'"
out="$(O task show t2 2>&1)"
check "task show prints the task with its files and events" "printf '%s' \"\$out\" | grep -q 'alpha/t2: build login' && printf '%s' \"\$out\" | grep -q 'recent events'"
check "task show --json is the raw task" "O task show t2 --json | jq -e '.id == \"t2\"' >/dev/null"
out="$(O task ready 2>&1)"
check "task ready lists ready tids with titles" "printf '%s' \"\$out\" | grep -q \"^$t6\""
out="$(O plan ls 2>&1)"
check "plan ls marks the current plan" "printf '%s' \"\$out\" | grep -q '^\\* alpha'"

# ---- corrupt files are survived, not fatal
echo '{not json' > "$OSRC_HOME/plans/alpha/tasks/$t9.json"
out="$(O task ls 2>&1)"
check "a damaged task file is skipped with a warning; the rest still list" \
  "printf '%s' \"\$out\" | grep -q 'skipping damaged task file' && printf '%s' \"\$out\" | grep -q 'scout auth'"
out="$(L "_task_get alpha $t9" 2>&1)"; rc=$?
check "_task_get on a damaged file returns 1 with a plain reason" "[ $rc -eq 1 ] && printf '%s' \"\$out\" | grep -q 'damaged'"
L "_task_update alpha $t9 '.state = \"todo\"'" >/dev/null 2>&1; rc=$?
check "_task_update on a damaged file refuses" "[ $rc -ne 0 ] && grep -q 'not json' \"$OSRC_HOME/plans/alpha/tasks/$t9.json\""
check "_task_get of a missing task returns 1" "! L '_task_get alpha t999' 2>/dev/null"
cp "$OSRC_HOME/plans/alpha/plan.json" "$TMP/plan.bak"; echo 'garbage' > "$OSRC_HOME/plans/alpha/plan.json"
out="$(O plan show alpha 2>&1)"; rc=$?
check "plan show survives a damaged plan.json" "[ $rc -eq 0 ] && printf '%s' \"\$out\" | grep -q 'damaged'"
cp "$TMP/plan.bak" "$OSRC_HOME/plans/alpha/plan.json"

# ---- lock: a dead holder's lock is reclaimed
mkdir -p "$OSRC_HOME/plans/alpha/.lock"; echo '999999 Thu Jan  1 00:00:00 1970' > "$OSRC_HOME/plans/alpha/.lock/owner"
L "_task_update alpha t1 '.result = \"after stale lock\"'" 2>/dev/null; rc=$?
check "a stale lock from a dead process is reclaimed" "[ $rc -eq 0 ] && [ \"\$(jq -r .result \"$OSRC_HOME/plans/alpha/tasks/t1.json\")\" = 'after stale lock' ] && [ ! -d \"$OSRC_HOME/plans/alpha/.lock\" ]"

# ---- plan rm / plan run delegation
tr_="$(O task add 'keep running' 2>/dev/null)"; L "_task_dispatch alpha $tr_" >/dev/null 2>&1
out="$(O plan rm alpha 2>&1)"; rc=$?
check "plan rm refuses while work is underway" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'still has work underway'"
O plan rm beta >/dev/null 2>&1
check "plan rm removes an idle plan" "[ ! -d \"$OSRC_HOME/plans/beta\" ]"
if L 'type cmd_plan_run >/dev/null 2>&1'; then
  ok "plan run is provided by factory-flow.sh (delegation not exercised)"
else
  out="$(O plan run 2>&1)"; rc=$?
  check "plan run without factory-flow.sh says what is missing" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'factory-flow.sh'"
fi
check "ship task in a plan without a repo fails closed" \
  "O plan new norepo --no-repo >/dev/null 2>&1 && O task add 'build' --shape ship --check true >/dev/null 2>&1 && ! L '_task_dispatch norepo t1' 2>/dev/null && jq -r .result \"$OSRC_HOME/plans/norepo/tasks/t1.json\" | grep -q 'no repo'"

# ---- end to end through the REAL bg path (fake droid binary, no model call)
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"; printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/droid"; chmod +x "$FAKEBIN/droid"
(cd "$REPO" && O plan new e2e --goal 'real launch' >/dev/null 2>&1)
O task add 'real ship' --shape ship --check true --provider droid --plan e2e >/dev/null 2>&1
jid="$(cd "$TMP" && PATH="$FAKEBIN:$PATH" OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 O task start t1 --plan e2e 2>/dev/null | head -1)"
i=0; while [ "$i" -lt 100 ]; do [ -f "$OSRC_HOME/jobs/$jid/meta.json" ] && break; i=$((i+1)); sleep 0.1; done
ej="$OSRC_HOME/plans/e2e/tasks/t1.json"
if [ -n "$jid" ] && [ -f "$OSRC_HOME/jobs/$jid/meta.json" ]; then
  check "real bg launch: the job's worktree/branch/base match what the task recorded" \
    "[ \"\$(jq -r '[.worktree,.branch,.base_sha]|join(\"|\")' \"$OSRC_HOME/jobs/$jid/meta.json\")\" = \"\$(jq -r '[.worktree,.branch,.base_sha]|join(\"|\")' \"$ej\")\" ]"
  check "real bg launch: the task is running on that job" "[ \"\$(jq -r '.state + \"|\" + .job' \"$ej\")\" = \"running|$jid\" ]"
  check 'R3 S18 real bg launch records the attempt token in its job receipt' \
    "[ \"\$(cat \"$OSRC_HOME/jobs/$jid/task_attempt\")\" = \"\$(jq -r .attempt_token \"$ej\")\" ]"
else
  bad "real bg launch produced no job (jid='$jid'): $(cat "$OSRC_HOME/plans/e2e/tasks/t1/launch.log" 2>/dev/null | tail -3)"
fi
i=0; while [ "$i" -lt 100 ]; do case "$(cat "$OSRC_HOME/jobs/$jid/status" 2>/dev/null)" in running|launching) sleep 0.1; i=$((i+1)) ;; *) break ;; esac; done
# Let the detached job finish its bookkeeping (ledger/outcome rows) before the temp dir goes.
i=0; while [ "$i" -lt 150 ] && pgrep -f "$TMP" >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done
git -C "$REPO" worktree remove --force "$REPO/.outsourcerer/worktrees/$jid" >/dev/null 2>&1 || true

# ---- global flags work with the factory commands like every other command
O plan new gflags --no-repo --cloud-ack >/dev/null 2>&1; rc=$?
check "plan new accepts --cloud-ack anywhere" "[ $rc -eq 0 ] && [ -f \"$OSRC_HOME/plans/gflags/plan.json\" ]"
gt1="$(bash "$SRC" --provider droid task add "lead" --plan gflags 2>/dev/null | head -1)"
gt2="$(O task add "own" --plan gflags --provider cursor 2>/dev/null | head -1)"
check "a leading global --provider becomes the task's lane" "[ \"\$(jq -r .provider \"$OSRC_HOME/plans/gflags/tasks/$gt1.json\")\" = droid ]"
check "a task's own --provider still wins" "[ \"\$(jq -r .provider \"$OSRC_HOME/plans/gflags/tasks/$gt2.json\")\" = cursor ]"

# ---- a ship worker that cannot get its own worktree must never fall back to the caller's checkout
# Outside every repo, and git told not to look above it.
NOGIT="$(mktemp -d)"; NOGIT="$(cd "$NOGIT" && pwd -P)"
( cd "$NOGIT" && GIT_CEILING_DIRECTORIES="$(dirname "$NOGIT")" OSRC_WORKTREE=1 OSRC_WORKTREE_REQUIRED=1 bash -c ". \"$LIB\"; run_job wtreq droid edit 'touch SHOULD_NOT_EXIST'" ) >/dev/null 2>&1
check "required worktree unavailable: the job fails closed" "[ \"\$(cat \"$OSRC_HOME/jobs/wtreq/status\" 2>/dev/null)\" = failed ] && grep -q worktree-required-unavailable \"$OSRC_HOME/jobs/wtreq/reason\""
check "required worktree unavailable: nothing ran in the caller's folder" "[ ! -e \"$NOGIT/SHOULD_NOT_EXIST\" ]"
rm -rf "$NOGIT"

# ======================================================================= review-1 / review-3 fixes
OSRC_JOBS="$OSRC_HOME/jobs"
TJ() { printf '%s/plans/%s/tasks/%s.json' "$OSRC_HOME" "$1" "$2"; }
(cd "$REPO" && O plan new fx --goal 'fix suite' >/dev/null 2>&1)

# ---- #1: an option given as the LAST argument, with no value, fails plainly instead of spinning
nohang() {   # run the CLI with a 5s watchdog; rc 99 = it hung
  bash "$SRC" "$@" > "$TMP/nh.out" 2>&1 & local p=$! i=0
  while kill -0 "$p" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$p" 2>/dev/null; then kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 99; fi
  wait "$p"
}
hung=""; quiet=""
while IFS= read -r argl; do
  [ -n "$argl" ] || continue
  eval "set -- $argl"
  nohang "$@"; rc=$?
  if [ "$rc" = 99 ]; then hung="$hung [$argl]"
  elif [ "$rc" = 0 ] || ! grep -q 'needs a value' "$TMP/nh.out"; then quiet="$quiet [$argl]"; fi
done <<'ARGS'
plan new zz1 --no-repo --goal
plan new zz2 --repo
plan new zz3 --base
plan show --plan
task add x --prompt
task add x --prompt-file
task add x --shape
task add x --deps
task add x --spec
task add x --check
task add x --verb
task add x -m
task add x --provider
task add x --deliver
task add x --retries
task add x --hold
task add x --flow
task add x --stage
task ls --state
task hold t1 --reason
task hold t1 --until
task release t1 --answer
task done t1 --result
task fail t1 --reason
task ls --plan
ARGS
check "#1 every option missing its value fails fast (no spin)" "[ -z \"$hung\" ]"
[ -z "$hung" ] || echo "  hung:$hung"
check "#1 ... and says the option needs a value" "[ -z \"$quiet\" ]"
[ -z "$quiet" ] || echo "  no plain message:$quiet"
check "#1 a half-parsed plan new left nothing behind" "[ ! -e \"$OSRC_HOME/plans/zz1\" ]"

# ---- #5 / review-3 #2: the plan lock never robs a LIVE holder, however old the lock
sleep 30 & HOLDER=$!
HID="$(L "_pid_start_identity $HOLDER")"
LK="$OSRC_HOME/plans/fx/.lock"; mkdir -p "$LK"; printf '%s %s\n' "$HOLDER" "$HID" > "$LK/owner"
touch -t 200001010000 "$LK" 2>/dev/null
fxt1="$(O task add 'lock target' --plan fx 2>/dev/null)"; rc=$?
check "#5 a live holder's lock is not stolen even when it is very old" \
  "[ $rc -ne 0 ] && [ -z \"$fxt1\" ] && [ \"\$(cat \"$LK/owner\" 2>/dev/null)\" = \"$HOLDER $HID\" ]"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
fxt1="$(O task add 'lock target' --plan fx 2>/dev/null)"; rc=$?
check "#5 once that holder is dead its lock is reclaimed" "[ $rc -eq 0 ] && [ \"$fxt1\" = t1 ] && [ ! -d \"$LK\" ]"
mkdir -p "$LK"; touch -t 200001010000 "$LK" 2>/dev/null
L "_task_update fx t1 '.result = \"after ownerless\"'" >/dev/null 2>&1; rc=$?
check "#5 an ownerless lock older than the grace window is reclaimed" "[ $rc -eq 0 ] && [ ! -d \"$LK\" ]"
mkdir -p "$LK"
L "OSRC_PLAN_LOCK_TRIES=5 _task_update fx t1 '.result = \"young\"'" >/dev/null 2>&1; rc=$?
check "#5 a fresh ownerless lock (holder still publishing) is left alone" "[ $rc -ne 0 ] && [ -d \"$LK\" ]"
rmdir "$LK"
out="$(L 'x="$( _plan_lock fx; cat "$(_plan_dir fx)/.lock/owner"; _plan_unlock fx )"; echo "${x%% *} $$"')"
check "#5 a lock taken inside a subshell records the subshell's own pid (not the parent's)" \
  "set -- \$out; [ -n \"\$1\" ] && [ \"\$1\" != \"\$2\" ]"
L '_plan_lock fx; echo "999999 someone else" > "$(_plan_dir fx)/.lock/owner"; _plan_unlock fx' >/dev/null 2>&1
check "#5 unlock never removes a lock that is no longer ours" "[ -d \"$LK\" ] && grep -q 'someone else' \"$LK/owner\""
rm -rf "$LK"
mkdir -p "$LK" "$LK.steal"; echo '999999 dead' > "$LK/owner"
L "OSRC_PLAN_LOCK_TRIES=5 _task_update fx t1 '.result = \"guarded\"'" >/dev/null 2>&1; rc=$?
check "#5 while another waiter holds the steal guard, a dead lock is not broken twice" "[ $rc -ne 0 ] && [ -d \"$LK\" ]"
touch -t 200001010000 "$LK.steal" 2>/dev/null
L "_task_update fx t1 '.result = \"guard reclaimed\"'" >/dev/null 2>&1; rc=$?
check "#5 an abandoned steal guard is cleared and the dead lock then reclaimed" \
  "[ $rc -eq 0 ] && [ ! -d \"$LK\" ] && [ ! -d \"$LK.steal\" ] && [ \"\$(jq -r .result \"\$(TJ fx t1)\")\" = 'guard reclaimed' ]"

# ---- #19: _task_new validates dep ids and ignores protected fields
out="$(L "_task_new fx '{\"title\":\"evil\",\"deps\":[\"../t1\"]}'" 2>&1)"; rc=$?
check "#19 a dependency that is not a task id is refused" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'not a task id'"
out="$(L "_task_new fx '{\"title\":\"evil\",\"state\":\"done\"}'" 2>&1)"; rc=$?
check "#19 a new task cannot start done" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'starts as todo or held'"
nt="$(L "_task_new fx '{\"title\":\"sneaky\",\"id\":\"t99\",\"plan\":\"other\",\"attempts\":5,\"job\":\"J\",\"jobs\":[\"J\"],\"worktree\":\"/etc\",\"landed\":true}'" 2>/dev/null)"
check "#19 protected fields passed to _task_new are ignored" \
  "[ \"$nt\" = t2 ] && [ \"\$(jq -c '[.id,.plan,.attempts,.job,.jobs,.worktree,(.landed // null)]' \"\$(TJ fx t2)\")\" = '[\"t2\",\"fx\",0,\"\",[],\"\",null]' ]"
nh="$(L "_task_new fx '{\"title\":\"ask\",\"state\":\"held\",\"hold\":{\"reason\":\"q\",\"until\":\"\",\"answer\":\"\"}}'" 2>/dev/null)"
check "#19 a new task may still start held (decision up front)" "[ \"\$(jq -r .state \"\$(TJ fx $nh)\")\" = held ]"

# ---- review-3 #3: captain gates, decisions and land steps are never dispatched as workers
g1="$(L "_task_new fx '{\"title\":\"gate\",\"gate\":true,\"hold_after_deps\":true}'")"
g2="$(L "_task_new fx '{\"title\":\"ask later\",\"hold_after_deps\":true,\"prompt\":\"review\"}'")"
g3="$(L "_task_new fx '{\"title\":\"land it\",\"land_target\":\"t1\"}'")"
o1="$(O task start "$g1" --plan fx 2>&1)"; r1=$?; o2="$(O task start "$g2" --plan fx 2>&1)"; r2=$?; o3="$(O task start "$g3" --plan fx 2>&1)"; r3=$?
check "#R3-3 task start refuses a captain decision with the next step" \
  "[ $r1 -ne 0 ] && [ $r2 -ne 0 ] && printf '%s' \"\$o1\" | grep -q 'captain decision' && printf '%s' \"\$o2\" | grep -q 'task release'"
check "#R3-3 task start refuses a land step and names the land command" "[ $r3 -ne 0 ] && printf '%s' \"\$o3\" | grep -q 'outsourcerer land t1 --plan fx'"
check "#R3-3 nothing launched and the steps stay todo" \
  "! grep -q 'fx/$g1\$\\|fx/$g2\$\\|fx/$g3\$' \"$TMP/launches\" && [ \"\$(jq -r .state \"\$(TJ fx $g1)\")\$(jq -r .state \"\$(TJ fx $g3)\")\" = todotodo ]"

# ---- #20: the claim reads only the task's own deps (no full _task_list under the lock)
c1="$(O task add 'claim dep' --plan fx 2>/dev/null)"; c2="$(O task add 'claim me' --deps "$c1" --plan fx 2>/dev/null)"
out="$(L "_task_list() { echo 'LIST CALLED' >&2; return 1; }; _task_dispatch fx $c2" 2>&1)"; rc=$?
check "#20 a blocked task is still refused without listing every task" \
  "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q \"waits on $c1 (todo)\" && ! printf '%s' \"\$out\" | grep -q 'LIST CALLED'"
L "_task_update fx $c1 '.state = \"done\"'" >/dev/null
cj="$(L "_task_list() { echo 'LIST CALLED' >&2; return 1; }; _task_dispatch fx $c2" 2>/dev/null)"; rc=$?
check "#20 a ready task is claimed and launched without listing every task" "[ $rc -eq 0 ] && [ \"\$(jq -r .job \"\$(TJ fx $c2)\")\" = \"$cj\" ]"
check "#R3-1 the claim records claimed_at (epoch seconds)" "jq -e '.claimed_at | type == \"number\" and . > 1700000000' \"\$(TJ fx $c2)\" >/dev/null"

# ---- #7 / review-3 #1: a cancel that races the launch wins; the orphan worker is stopped
k1="$(O task add 'cancel mid-launch' --plan fx 2>/dev/null)"
out="$(L "eval \"_stub_\$(declare -f _task_bg_launch)\"
  _task_bg_launch() { local id; id=\"\$(_stub__task_bg_launch \"\$@\")\" || return 1; _task_update fx $k1 '.state = \"canceled\"' >/dev/null; echo \"\$id\"; }
  _task_dispatch fx $k1" 2>&1)"; rc=$?
kj="$(grep "|fx/$k1\$" "$TMP/launches" | tail -1 | cut -d'|' -f1)"
check "#7 cancel during launch: dispatch fails and the task stays canceled with no job" \
  "[ $rc -ne 0 ] && [ \"\$(jq -r '.state + \"|\" + .job + \"|\" + (.jobs|length|tostring)' \"\$(TJ fx $k1)\")\" = 'canceled||0' ]"
check "#7 cancel during launch: the just-launched job is stopped and the event logged" \
  "[ -n \"$kj\" ] && [ \"\$(cat \"$OSRC_JOBS/$kj/status\" 2>/dev/null)\" = canceled ] && grep -q '\"task\":\"$k1\",\"event\":\"orphan-stopped\"' \"$OSRC_HOME/plans/fx/events.jsonl\""
k2="$(O task add 'cancel before launch' --plan fx 2>/dev/null)"
out="$(L "eval \"_orig_\$(declare -f _task_brief)\"
  _task_brief() { _task_update fx $k2 '.state = \"canceled\"' >/dev/null; _orig__task_brief \"\$@\"; }
  _task_dispatch fx $k2" 2>&1)"; rc=$?
check "#7 cancel before launch: no worker is started at all" \
  "[ $rc -ne 0 ] && ! grep -q '|fx/$k2\$' \"$TMP/launches\" && [ \"\$(jq -r .state \"\$(TJ fx $k2)\")\" = canceled ]"
k3="$(O task add 'launcher died' --plan fx 2>/dev/null)"
L "_task_update fx $k3 '.state = \"running\" | .job = \"\" | .claimed_at = now | .claimed_by = \"999999 Thu Jan  1 00:00:00 1970\"'" >/dev/null
out="$(O task start "$k3" --plan fx 2>&1)"
check "#7 a stuck launch is named as such, with the recovery command" "printf '%s' \"\$out\" | grep -q 'being launched right now' && printf '%s' \"\$out\" | grep -q \"task retry $k3\""
O task retry "$k3" --plan fx >/dev/null 2>&1
check "#7 retry recovers a running task whose launcher died before recording a job" "[ \"\$(jq -r .state \"\$(TJ fx $k3)\")\" = todo ]"
k4="$(O task add 'launch in progress' --plan fx 2>/dev/null)"
L "_task_update fx $k4 '.state = \"running\" | .job = \"\" | .claimed_at = (now|floor) | .claimed_by = \$by' --arg by \"$$ \$(_pid_start_identity $$)\"" >/dev/null
out="$(O task retry "$k4" --plan fx 2>&1)"; rc=$?
check "#7 retry never resets a launch whose launcher is alive and recent" "[ $rc -ne 0 ] && [ \"\$(jq -r .state \"\$(TJ fx $k4)\")\" = running ]"
L "_task_update fx $k4 '.claimed_at = 1000'" >/dev/null
O task retry "$k4" --plan fx >/dev/null 2>&1
check "#7 ... but does recover one whose claim is older than the stale window" "[ \"\$(jq -r .state \"\$(TJ fx $k4)\")\" = todo ]"
k5="$(O task add 'launch fails' --plan fx 2>/dev/null)"
STUB_FAIL=1 L "_task_dispatch fx $k5" >/dev/null 2>&1
check "#R3-13 a launch failure is marked launch_failed with a 'launch failed' reason (attempt counted)" \
  "[ \"\$(jq -r '[.state,(.launch_failed|tostring),(.attempts|tostring)] | join(\"|\")' \"\$(TJ fx $k5)\")\" = 'failed|true|1' ] && jq -r .result \"\$(TJ fx $k5)\" | grep -q '^launch failed: '"
O task retry "$k5" --plan fx >/dev/null 2>&1
check "#R3-13 retry clears launch_failed" "[ \"\$(jq -r '.launch_failed' \"\$(TJ fx $k5)\")\" = false ]"

# ---- #6 / review-3 #22: task done transitions are guarded
d1="$(O task add 'done races cancel' --plan fx 2>/dev/null)"
L "_task_update fx $d1 '.state = \"running\" | .job = \"JD1\"'" >/dev/null
out="$(bash -c ". \"$LIB\"; _factory_done_check() { _task_update fx $d1 '.state = \"canceled\"' >/dev/null; echo ok; return 0; }; cmd_task done $d1 --plan fx" 2>&1)"; rc=$?
check "#6 a cancel during a passing check is not overwritten by done" "[ $rc -ne 0 ] && [ \"\$(jq -r .state \"\$(TJ fx $d1)\")\" = canceled ]"
d2="$(O task add 'done fails after cancel' --plan fx 2>/dev/null)"
L "_task_update fx $d2 '.state = \"running\" | .job = \"JD2\"'" >/dev/null
bash -c ". \"$LIB\"; _factory_done_check() { _task_update fx $d2 '.state = \"canceled\"' >/dev/null; echo no; return 1; }; cmd_task done $d2 --plan fx" >/dev/null 2>&1
check "#6 a failing check does not restore over a concurrent cancel" "[ \"\$(jq -r .state \"\$(TJ fx $d2)\")\" = canceled ]"
d3="$(O task add 'done interrupted' --plan fx 2>/dev/null)"
L "_task_update fx $d3 '.state = \"running\" | .job = \"JD3\"'" >/dev/null
bash -c ". \"$LIB\"; _factory_done_check() { sleep 1; echo ok; return 0; }; cmd_task done $d3 --plan fx" >/dev/null 2>&1 & DP=$!
i=0; while [ "$i" -lt 50 ] && [ "$(jq -r .state "$(TJ fx $d3)")" != verifying ]; do sleep 0.1; i=$((i + 1)); done
kill -TERM "$DP" 2>/dev/null; wait "$DP"; rc=$?
check "#6 an interrupted done check puts the task back (not stuck in verifying)" \
  "[ $rc -eq 130 ] && [ \"\$(jq -r .state \"\$(TJ fx $d3)\")\" = running ]"
L "_task_update fx $d3 '.state = \"verifying\"'" >/dev/null
out="$(O task done "$d3" --plan fx 2>&1)"; rc=$?
check "#R3-22 task done refuses a task another verifier is already checking" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'already being checked'"

# ---- #8: the brief is complete but bounded, whatever the inputs hold
(cd "$REPO" && O plan new huge --goal "$(head -c 6000 /dev/zero | tr '\0' 'g')" --no-use >/dev/null 2>&1)
BIGP="$TMP/bigprompt.txt"; head -c 50000 /dev/zero | tr '\0' 'p' > "$BIGP"
L 'for i in $(seq 1 20); do t="$(_task_new huge "{\"title\":\"dep $i\"}")"; _task_update huge "$t" ".state = \"done\" | .result = \$r | .hold.answer = \$r" --arg r "$(head -c 10000 /dev/zero | tr "\0" "r")" >/dev/null; done' 2>/dev/null
hb="$(O task add 'consumer' --plan huge --prompt-file "$BIGP" --deps "$(seq -s, 1 20 | sed 's/\([0-9][0-9]*\)/t\1/g')" 2>/dev/null)"
hbj="$(L "_task_dispatch huge $hb" 2>/dev/null)"
HB="$OSRC_HOME/plans/huge/tasks/$hb/brief.md"
check "#8 a brief with a huge goal, prompt, 20 deps and huge results stays bounded" \
  "[ -n \"$hbj\" ] && [ \"\$(wc -c < \"$HB\" | tr -d ' ')\" -lt 160000 ]"
check "#8 the brief shows at most 12 dependency sections and lists the rest with where to read them" \
  "[ \"\$(grep -c '^### t[0-9]*: dep' \"$HB\")\" = 12 ] && grep -q '^### 8 more finished input(s) not shown here' \"$HB\" && grep -qF 't13, t14' \"$HB\" && grep -qF \"$OSRC_HOME/plans/huge/tasks/<id>/report.md\" \"$HB\""
check "#8 each cut says where the full text is" \
  "grep -q 'trimmed; the full text is in .*plan.json' \"$HB\" && grep -q 'trimmed; the full text is in .*$hb.json (field prompt)' \"$HB\" && grep -q 'field hold.answer' \"$HB\""
check "#8 the worker's command-line prompt stays short however big the brief" \
  "[ \"\$(sed -n '2,\$p' \"$OSRC_JOBS/$hbj/argv\" | wc -c | tr -d ' ')\" -lt 1200 ] && grep -qF \"read your full brief: $HB\" \"$OSRC_JOBS/$hbj/argv\""

# ---- #21: a plan new that fails half way leaves nothing behind
out="$(bash -c ". \"$LIB\"; _factory_write_json() { return 1; }; cmd_plan new halfmade --no-repo" 2>&1)"; rc=$?
check "#21 plan new removes the folder it made when a later step fails" \
  "[ $rc -ne 0 ] && [ ! -e \"$OSRC_HOME/plans/halfmade\" ] && printf '%s' \"\$out\" | grep -q 'Nothing was kept'"
out="$(cd "$REPO" && O plan new halfmade --goal again --no-use 2>&1)"; rc=$?
check "#21 ... so the same name works on the next try" "[ $rc -eq 0 ] && [ -f \"$OSRC_HOME/plans/halfmade/plan.json\" ]"

# ---- #22: retry releases the old worker worktree when safe (branch kept); --retries normalized
w1="$(O task add 'retry wt' --shape ship --plan fx 2>/dev/null)"
WT1="$REPO/.outsourcerer/worktrees/JW1"; git -C "$REPO" worktree add -q -b outsourcerer/JW1 "$WT1" HEAD 2>/dev/null
L "_task_update fx $w1 '.state = \"failed\" | .job = \"JW1\" | .worktree = \$w | .branch = \"outsourcerer/JW1\"' --arg w \"$WT1\"" >/dev/null
out="$(O task retry "$w1" --plan fx 2>&1)"
check "#22 retry removes a clean old worktree and keeps its branch" \
  "[ ! -d \"$WT1\" ] && git -C \"$REPO\" rev-parse -q --verify refs/heads/outsourcerer/JW1 >/dev/null && printf '%s' \"\$out\" | grep -q 'branch outsourcerer/JW1 is kept'"
w2="$(O task add 'retry dirty wt' --shape ship --plan fx 2>/dev/null)"
WT2="$REPO/.outsourcerer/worktrees/JW2"; git -C "$REPO" worktree add -q -b outsourcerer/JW2 "$WT2" HEAD 2>/dev/null; echo wip > "$WT2/wip.txt"
L "_task_update fx $w2 '.state = \"failed\" | .job = \"JW2\" | .worktree = \$w | .branch = \"outsourcerer/JW2\"' --arg w \"$WT2\"" >/dev/null
out="$(O task retry "$w2" --plan fx 2>&1)"
check "#22 retry keeps an old worktree that has uncommitted work and says so" \
  "[ -f \"$WT2/wip.txt\" ] && printf '%s' \"\$out\" | grep -q 'uncommitted changes' && [ \"\$(jq -r .state \"\$(TJ fx $w2)\")\" = todo ]"
git -C "$REPO" worktree remove --force "$WT2" >/dev/null 2>&1
w3="$(L "_task_new fx '{\"title\":\"outside\",\"shape\":\"ship\"}'")"
mkdir -p "$TMP/outside-wt"; L "_task_update fx $w3 '.state = \"failed\" | .worktree = \$w' --arg w \"$TMP/outside-wt\"" >/dev/null
O task retry "$w3" --plan fx >/dev/null 2>&1
check "#22 retry never removes a folder outside the repo's worktree area" "[ -d \"$TMP/outside-wt\" ]"
r7="$(O task add 'zero padded' --retries 007 --plan fx 2>/dev/null)"
check "#22 --retries 007 is stored as 7" "[ \"\$(jq -r .retries \"\$(TJ fx $r7)\")\" = 7 ]"
out="$(O task add 'too many' --retries 123456 --plan fx 2>&1)"; rc=$?
check "#22 an absurd --retries is refused plainly" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q '999 or less'"

# ---- #18: a delegate never inherits this job's worktree switches
FB2="$TMP/fakebin2"; mkdir -p "$FB2"
printf '#!/usr/bin/env bash\nenv > "$ENVDUMP"\necho "OSRC::DONE env dumped"\n' > "$FB2/droid"; chmod +x "$FB2/droid"
( cd "$REPO" && PATH="$FB2:$PATH" ENVDUMP="$TMP/envdump" OSRC_WORKTREE=1 OSRC_WORKTREE_REQUIRED=1 OSRC_WORKTREE_BASE="$HEAD_SHA" OSRC_TASK_REF=fx/t1 OSRC_TASK_ATTEMPT=env-token \
  OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 bash -c ". \"$LIB\"; SCRIPT_PATH=\"$SRC\"; run_job envjob droid run 'say hi'" ) >/dev/null 2>&1
check "#18 the job itself still ran in its own worktree" "[ \"\$(jq -r '.worktree // \"\"' \"$OSRC_JOBS/envjob/meta.json\" 2>/dev/null)\" = \"$REPO/.outsourcerer/worktrees/envjob\" ]"
check "#18 the delegate's environment has no OSRC_WORKTREE* switches" \
  "[ -s \"$TMP/envdump\" ] && ! grep -q '^OSRC_WORKTREE' \"$TMP/envdump\""
check 'R3 S18 delegate cannot pass task linkage to nested jobs' \
  "[ -s \"$TMP/envdump\" ] && ! grep -qE '^OSRC_TASK_(REF|ATTEMPT)=' \"$TMP/envdump\""
git -C "$REPO" worktree remove --force "$REPO/.outsourcerer/worktrees/envjob" >/dev/null 2>&1 || true

echo
# Round 3: regressions run in subshells so injected failures never leak between cases.
O plan new r3 --repo "$REPO" --no-use >/dev/null 2>&1
r3_task() { _task_new r3 '{"title":"round 3"}'; }
r3_verdict() (
  . "$LIB"
  local id; id="$(r3_task)"
  _task_update r3 "$id" '.state="running" | .require_verdict=true' || exit 1
  _factory_done_check() { echo passed; }
  _factory_review_verdict() { echo FAIL; return 1; }
  (cmd_task done "$id" --plan r3) >/dev/null 2>&1 && exit 1
  [ "$(_task_get r3 "$id" | jq -r .state)" = running ] || exit 1
  _factory_review_verdict() { echo AMBIGUOUS; return 2; }
  (cmd_task done "$id" --plan r3) >/dev/null 2>&1 && exit 1
  cmd_task done "$id" --force --plan r3 >/dev/null || exit 1
  [ "$(_task_get r3 "$id" | jq -r .state)" = done ]
)
check 'R3 S4 manual done refuses FAIL/AMBIGUOUS; force overrides' r3_verdict
r3_review_binds() (
  . "$LIB"
  local b r; b="$(_task_new r3 '{"title":"build","shape":"ship"}')"
  _task_update r3 "$b" '.state="done" | .head_sha="feedface"' || exit 1
  r="$(_task_new r3 "$(jq -nc --arg b "$b" '{title:"review",deps:[$b]}')")"
  _task_update r3 "$r" '.state="running" | .require_verdict=true' || exit 1
  _factory_done_check() { echo passed; }
  _factory_review_verdict() { echo PASS; return 0; }
  cmd_task done "$r" --plan r3 >/dev/null || exit 1
  _task_get r3 "$r" | jq -e --arg b "$b" '.state=="done" and .reviewed_head=="feedface" and .review_target==$b' >/dev/null
)
check 'R3 S3 a review closed by hand binds to the build head it approved' r3_review_binds
r3_verify_owner() (
  . "$LIB"
  local id; id="$(r3_task)"
  _task_update r3 "$id" '.state="running"' || exit 1
  _factory_done_check() {
    _task_get r3 "$id" | jq -e '.verifying_pid != null and .verifying_start != null and .verifying_at > 0' >/dev/null || return 1
    echo checked
  }
  cmd_task done "$id" --plan r3 >/dev/null || exit 1
  _task_get r3 "$id" | jq -e '.state=="done" and .verifying_pid==null and .verifying_start==null and .verifying_at==null' >/dev/null
)
check 'R3 S12 manual verification publishes and clears ownership' r3_verify_owner
r3_verify_replaced() (
  . "$LIB"
  local id; id="$(r3_task)"
  _task_update r3 "$id" '.state="running" | .attempt_token="old"' || exit 1
  _factory_done_check() {
    _task_update r3 "$id" '.attempt_token="new" | .verifying_pid="replacement" | .verifying_start="other" | .result="replacement"' || return 1
    echo checked
  }
  (cmd_task done "$id" --plan r3 --result stale) >/dev/null 2>&1 && exit 1
  _task_get r3 "$id" | jq -e '.state=="verifying" and .result=="replacement" and .verifying_pid=="replacement"' >/dev/null
)
check 'R3 S12 replaced verifier cannot finalize or overwrite the result' r3_verify_replaced
r3_claim_replace() (
  . "$LIB"
  local id; id="$(r3_task)"
  _task_bg_launch() {
    mkdir -p "$OSRC_JOBS/20261022-120000-replaced"
    echo running > "$OSRC_JOBS/20261022-120000-replaced/status"
    _task_update r3 "$id" '.attempt_token="replacement"' || return 1
    echo 20261022-120000-replaced
  }
  _task_dispatch r3 "$id" >/dev/null 2>&1 && exit 1
  _task_get r3 "$id" | jq -e '.job=="" and .attempt_token=="replacement"' >/dev/null || exit 1
  [ "$(cat "$OSRC_JOBS/20261022-120000-replaced/status")" = canceled ]
)
check 'R3 S7 replaced claim cannot adopt the original launcher job' r3_claim_replace
r3_failure_replace() (
  . "$LIB"
  local id; id="$(r3_task)"
  _task_bg_launch() { _task_update r3 "$id" '.attempt_token="replacement"'; return 1; }
  _task_dispatch r3 "$id" >/dev/null 2>&1 && exit 1
  _task_get r3 "$id" | jq -e '.state=="running" and .attempt_token=="replacement" and .launch_failed==false' >/dev/null
)
check 'R3 S7 old launch failure cannot fail a replacement claim' r3_failure_replace
r3_adopt() (
  . "$LIB"
  local OSRC_JOBS="$TMP/jobs with spaces"; mkdir -p "$OSRC_JOBS"
  local id jd; id="$(r3_task)"; jd="$OSRC_JOBS/20261022-120000-adopt"
  _task_update r3 "$id" '.state="running" | .claimed_at=1 | .attempt_token="adopt-token"' || exit 1
  mkdir -p "$jd"; printf 'r3/%s\n' "$id" > "$jd/task_ref"
  echo adopt-token > "$jd/task_attempt"; echo running > "$jd/status"
  jq -n --arg w "$REPO/.outsourcerer/worktrees/adopt" --arg s "$HEAD_SHA" \
    '{worktree:$w,branch:"outsourcerer/adopt",base_sha:$s}' > "$jd/meta.json"
  mkdir -p "$OSRC_JOBS/20261022-120000-nested"
  printf 'r3/%s\n' "$id" > "$OSRC_JOBS/20261022-120000-nested/task_ref"
  echo another-token > "$OSRC_JOBS/20261022-120000-nested/task_attempt"
  cmd_task retry "$id" --plan r3 >/dev/null || exit 1
  _task_get r3 "$id" | jq -e --arg s "$HEAD_SHA" '.state=="running" and .job=="20261022-120000-adopt" and .branch=="outsourcerer/adopt" and .base_sha==$s and (.worktree|endswith("/adopt"))' >/dev/null
)
check 'R3 S17/S18 stale retry adopts the matching attempt and full receipt' r3_adopt
r3_model() (
  . "$LIB"
  local id job; id="$(r3_task)"
  _task_update r3 "$id" '.model="sol" | .fallback=["sol","opus"]' || exit 1
  _model_excluded() { [ "$1" = sol ]; }
  job="$(_task_dispatch r3 "$id")" || exit 1
  grep -qx opus "$OSRC_JOBS/$job/argv" && ! grep -qx sol "$OSRC_JOBS/$job/argv"
)
check 'R3 S19 manual dispatch chooses the stored allowed fallback' r3_model
r3_publish_fail() (
  . "$LIB"
  mv() { case "$*" in */.lock/owner*) return 1 ;; esac; command mv "$@"; }
  _plan_lock r3 >/dev/null 2>&1 && exit 1
  [ ! -d "$OSRC_HOME/plans/r3/.lock" ] && [ "$_FACTORY_LOCK_DEPTH" = 0 ]
)
check 'R3 S21 failed owner publication fails acquisition and removes the lock' r3_publish_fail
r3_unknown_pid() (
  . "$LIB"
  _pid_start_identity() { return 1; }
  kill() { return 1; }
  ! _factory_owner_dead 1234 unknown
)
check 'R3 D11 inaccessible process is not proof of death' r3_unknown_pid
r3_rm_lock() (
  . "$LIB"
  cmd_plan new locked-rm --no-repo --no-use >/dev/null || exit 1
  _plan_lock locked-rm || exit 1
  OSRC_PLAN_LOCK_TRIES=1 O plan rm locked-rm >/dev/null 2>&1
  local rc=$?
  [ "$rc" -ne 0 ] && [ -f "$OSRC_HOME/plans/locked-rm/plan.json" ]
)
check 'R3 D3 plan removal waits for the plan lock' r3_rm_lock
r3_crlf() (
  . "$LIB"
  jq() { command jq "$@" | sed 's/$/\r/'; return "${PIPESTATUS[0]}"; }
  local id job; id="$(r3_task)"; job="$(_task_dispatch r3 "$id")" || exit 1
  [ -n "$job" ] && _task_get r3 "$id" | command jq -e '.state=="running" and (.job|length)>0' >/dev/null
)
check 'R3 D4 native jq CRLF does not break task dispatch' r3_crlf
check 'R3 D22 task header references published documentation' "! head -n 5 \"$HERE/../factory-tasks.sh\" | grep -q CONTRACT.md"
r3_hint() (
  . "$LIB"
  local id out; id="$(r3_task)"
  out="$(cmd_task hold "$id" --plan r3 --reason decision)" || exit 1
  printf '%s' "$out" | grep -q "task release $id --plan r3" || exit 1
  out="$(cmd_plan show r3)" || exit 1
  printf '%s' "$out" | grep -q "task release $id --plan r3"
)
check 'R3 S15 task and plan recovery hints name the selected plan' r3_hint
r3_claim_tokens() (
  . "$LIB"
  local id first second; id="$(r3_task)"
  _plan_lock r3 || exit 1
  _task_claim_locked r3 "$id" || exit 1
  first="$(_task_get r3 "$id" | jq -r '.attempt_token // ""')"
  _task_update_locked r3 "$id" '.state="todo"' || exit 1
  _task_claim_locked r3 "$id" || exit 1
  second="$(_task_get r3 "$id" | jq -r '.attempt_token // ""')"
  _plan_unlock r3
  [[ "$first" =~ ^[0-9]+-[0-9]+-[0-9]+ ]] && [ "$first" != "$second" ]
)
check 'R3 S7 every claim has a distinct epoch-pid-random token' r3_claim_tokens
r3_before_launch_replace() (
  . "$LIB"
  local id; id="$(r3_task)"
  _task_brief() {
    _task_update r3 "$id" '.attempt_token="replacement"' || return 1
    echo brief > "$TMP/replaced-brief"; echo "$TMP/replaced-brief"
  }
  _task_bg_launch() { echo launched > "$TMP/replaced-launch"; }
  _task_dispatch r3 "$id" >/dev/null 2>&1 && exit 1
  [ ! -f "$TMP/replaced-launch" ]
)
check 'R3 S7 replacement before launch prevents spending a worker' r3_before_launch_replace
r3_recovery_replace() (
  . "$LIB"
  local id; id="$(r3_task)"
  _task_update r3 "$id" '.state="running" | .claimed_at=1 | .attempt_token="old"' || exit 1
  _task_find_job_by_ref() { _task_update r3 "$id" '.attempt_token="new"' >/dev/null; }
  (cmd_task retry "$id" --plan r3) >/dev/null 2>&1 && exit 1
  _task_get r3 "$id" | jq -e '.state=="running" and .attempt_token=="new"' >/dev/null
)
check 'R3 S7 stale recovery cannot reset a replacement with the same timestamp' r3_recovery_replace
r3_legacy_ambiguous() (
  . "$LIB"
  local id j; id="$(r3_task)"
  _task_update r3 "$id" '.state="running" | .claimed_at=1' || exit 1
  for j in ambiguous1 ambiguous2; do
    mkdir -p "$OSRC_JOBS/$j"; printf 'r3/%s\n' "$id" > "$OSRC_JOBS/$j/task_ref"
  done
  (cmd_task retry "$id" --plan r3) >/dev/null 2>&1 && exit 1
  _task_get r3 "$id" | jq -e '.state=="running" and .job==""' >/dev/null
)
check 'R3 S18 ambiguous legacy receipts are refused without resetting the task' r3_legacy_ambiguous
r3_pid_cases() (
  . "$LIB"
  _pid_start_identity() { echo new; }
  _factory_owner_dead 1234 old || exit 1
  _factory_owner_dead 1234 new && exit 1
  _pid_start_identity() { return 2; }
  _factory_owner_dead 1234 old || exit 1
  _pid_start_identity() { return 1; }
  kill() { echo 'kill: (1234) - No such process' >&2; return 1; }
  _factory_owner_dead 1234 old
)
check 'R3 D11 process identity handles reused, live, missing and ESRCH owners' r3_pid_cases
r3_jq_status() (
  . "$LIB"
  _ft_jq -e 'false' <<< '{}' >/dev/null && exit 1
  _ft_jq -e '.' <<< 'broken' >/dev/null 2>&1 && exit 1
  _ft_jq -e 'true' <<< '{}' >/dev/null
)
check 'R3 D4 jq normalization preserves false and parse-error exit statuses' r3_jq_status
r3_early_receipt() (
  . "$LIB"
  local id job=20261022-120000-early; id="$(r3_task)"
  _task_update r3 "$id" '.shape="ship" | .check="true"' || exit 1
  _task_bg_launch() {
    _task_get r3 "$id" | jq -e --arg s "$OSRC_WORKTREE_BASE" '.base_sha==$s' >/dev/null || return 1
    mkdir -p "$OSRC_JOBS/$job"
    echo running > "$OSRC_JOBS/$job/status"
    printf 'r3/%s\n' "$id" > "$OSRC_JOBS/$job/task_ref"
    echo "$OSRC_TASK_ATTEMPT" > "$OSRC_JOBS/$job/task_attempt"
    # Simulate the launcher dying before returning its id, while setup has no metadata yet.
    _task_update r3 "$id" '.claimed_at=1' || return 1
    cmd_task retry "$id" --plan r3 >/dev/null || return 1
    _task_get r3 "$id" | jq -e --arg s "$OSRC_WORKTREE_BASE" \
      '.base_sha==$s and .branch=="outsourcerer/20261022-120000-early" and (.worktree|endswith("/20261022-120000-early"))' > "$TMP/early-receipt-ok"
    echo "$job"
  }
  _task_dispatch r3 "$id" >/dev/null 2>&1 || exit 1
  grep -qx true "$TMP/early-receipt-ok" && [ "$(cat "$OSRC_JOBS/$job/status")" = running ]
)
check 'R3 S18 ship adoption restores its receipt even before metadata is published' r3_early_receipt
r3_model_without_flow() (
  . "$LIB"
  unset -f _ff_next_model
  _model_excluded() { if [ "$1" = sol ]; then echo sol; return 0; fi; return 1; }
  [ "$(_task_dispatch_model '{"model":"sol","fallback":["sol","opus"]}')" = opus ]
)
check 'R3 S19 fallback selection without the flow module emits only the chosen model' r3_model_without_flow
r3_retry_replaced_failure() (
  . "$LIB"
  local id; id="$(r3_task)"
  _task_update r3 "$id" '.state="failed" | .attempt_token="old"' || exit 1
  _task_claim_stale() { _task_update r3 "$id" '.attempt_token="new"'; return 1; }
  (cmd_task retry "$id" --plan r3) >/dev/null 2>&1 && exit 1
  _task_get r3 "$id" | jq -e '.state=="failed" and .attempt_token=="new"' >/dev/null
)
check 'R3 S7 retry cannot reset a different attempt that already failed' r3_retry_replaced_failure
r3_rm_atomic() (
  . "$LIB"
  cmd_plan new remove-atomic --no-repo --no-use >/dev/null || exit 1
  rm() {
    # Recursively removing the published directory can expose it after .lock is deleted.
    case "$*" in *"$OSRC_HOME/plans/remove-atomic"*) return 1 ;; esac
    command rm "$@"
  }
  (cmd_plan rm remove-atomic) >/dev/null 2>&1 || exit 1
  [ ! -d "$OSRC_HOME/plans/remove-atomic" ]
)
check 'R3 D3 plan removal unpublishes the locked directory before recursive cleanup' r3_rm_atomic
r3_adopted_verifier() (
  . "$LIB"
  local id job=20261022-120000-verifying; id="$(r3_task)"
  _task_bg_launch() {
    mkdir -p "$OSRC_JOBS/$job"; echo running > "$OSRC_JOBS/$job/status"
    _task_update r3 "$id" '.job=$j | .jobs=[$j] | .state="verifying"' --arg j "$job" || return 1
    echo "$job"
  }
  _task_dispatch r3 "$id" >/dev/null 2>&1 || exit 1
  [ "$(cat "$OSRC_JOBS/$job/status")" = running ] && _task_get r3 "$id" | jq -e '.state=="verifying"' >/dev/null
)
check 'R3 S18 returning launcher preserves its adopted job after verification begins' r3_adopted_verifier

echo "factory tasks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
