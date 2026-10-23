#!/usr/bin/env bash
# test_factory_pstack.sh -- three factory guards: a brief too thin to act on is held before a worker
# is spent; a held decision can carry a default answer that applies when its deadline passes; and a
# failed attempt is retried according to why it failed (same model, next model, smaller piece, or a
# re-plan after the same failure twice). No real delegate runs: _task_bg_launch is stubbed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
for t in jq git; do command -v "$t" >/dev/null 2>&1 || { echo "FAIL: $t is required"; exit 1; }; done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-factory-pstack.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
export GIT_CEILING_DIRECTORIES="$(dirname "$TMP")"
HOME="$TMP/home"; export HOME; mkdir -p "$HOME"
trap "[ -n \"${KEEP:-}\" ] || rm -rf \"$TMP\"" EXIT
export OSRC_HOME="$TMP/state"; mkdir -p "$OSRC_HOME"
export OSRC_FLEET_SUPERVISION=0 OSRC_HEARTBEAT_DISABLED=1 OSRC_BLIND_TURN_GUARD=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main 2>/dev/null || { git -C "$REPO" init -q; git -C "$REPO" checkout -q -b main; }
echo hi > "$REPO/a.txt"; git -C "$REPO" add a.txt; git -C "$REPO" commit -q -m init

LIB="$TMP/lib.sh"
cat > "$LIB" <<EOF
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
_task_bg_launch() {
  local id="20261023-120000-\$(printf '%06d' \$RANDOM)\${RANDOM}"
  mkdir -p "\$OSRC_JOBS/\$id"; echo running > "\$OSRC_JOBS/\$id/status"
  echo "\$id" >> "$TMP/launches"
  echo "\$id"
}
EOF
L() { bash -c ". \"$LIB\"; $1"; }
O() { bash "$SRC" "$@"; }
J() { jq -r "$2" "$OSRC_HOME/plans/p/tasks/$1.json"; }
launches() { [ -f "$TMP/launches" ] && wc -l < "$TMP/launches" | tr -d ' ' || echo 0; }

( cd "$REPO" && O plan new p --goal 'guards' >/dev/null 2>&1 )

echo "=== a thin brief is held before a worker is spent ==="
t1="$(O task add 'build it' --shape ship 2>/dev/null)"
out="$(L "_task_dispatch p $t1" 2>&1)"; rc=$?
check "a ship task with no spec, check or dependency does not start" "[ $rc -ne 0 ] && [ \"\$(launches)\" = 0 ]"
check "it is held with a reason that names what is missing" "[ \"\$(J $t1 .state)\" = held ] && J $t1 .hold.reason | grep -q 'too thin' && J $t1 .hold.reason | grep -q 'spec, a check'"
check "no attempt is used up" "[ \"\$(J $t1 .attempts)\" = 0 ]"
check "the message says how to add the detail" "printf '%s' \"\$out\" | grep -q 'task release'"
O task release "$t1" --plan p --answer 'done when a.txt says bye; check: grep bye a.txt' >/dev/null 2>&1
L "_task_dispatch p $t1" >/dev/null 2>&1
check "after the captain adds the detail, it starts" "[ \"\$(J $t1 .state)\" = running ] && [ \"\$(launches)\" = 1 ]"
t2="$(O task add 'build with check' --shape ship --check 'true' 2>/dev/null)"
L "_task_dispatch p $t2" >/dev/null 2>&1
check "a ship task with a check starts" "[ \"\$(J $t2 .state)\" = running ]"
t3="$(O task add 'scout it' 2>/dev/null)"
L "_task_dispatch p $t3" >/dev/null 2>&1
check "a scout task with only a title starts" "[ \"\$(J $t3 .state)\" = running ]"
t4="$(L "_task_new p '{\"title\":\"\",\"prompt\":\"\"}'" 2>/dev/null)"
L "_task_dispatch p $t4" >/dev/null 2>&1
check "a task with no words at all is held" "[ \"\$(J $t4 .state)\" = held ] && J $t4 .hold.reason | grep -q 'no prompt or title'"
t5="$(O task add 'build on scout' --shape ship --after "$t3" 2>/dev/null)"
t5b="$(L "_task_new p '{\"title\":\"cand\",\"shape\":\"ship\",\"flow\":{\"name\":\"best-of-n\",\"stage\":\"candidate\"}}'" 2>/dev/null)"
check "a flow stage is trusted to its template" "[ -z \"\$(L \"_task_brief_lint \\\"\\\$(_task_get p $t5b)\\\"\")\" ]"
check "a ship task that builds on finished work passes the check" "[ -z \"\$(L \"_task_brief_lint \\\"\\\$(_task_get p $t5)\\\"\")\" ]"

echo "=== a held decision with a default ==="
t6="$(O task add 'pick a db' 2>/dev/null)"
out="$(O task hold "$t6" --plan p --reason 'postgres or sqlite?' --default sqlite 2>&1)"; rc=$?
check "--default without --until is refused" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q 'needs --until'"
out="$(O task hold "$t6" --plan p --reason 'postgres or sqlite?' --default sqlite --until tomorrow 2>&1)"; rc=$?
check "an unreadable --until is refused when a default rides on it" "[ $rc -ne 0 ] && printf '%s' \"\$out\" | grep -q '+30m'"
now="$(date +%s)"
out="$(O task hold "$t6" --plan p --reason 'postgres or sqlite?' --default sqlite --until +2h 2>&1)"; rc=$?
check "--until +2h stores a deadline about two hours out" "[ $rc -eq 0 ] && e=\$(J $t6 .hold.until_epoch) && [ \$((e - now)) -ge 7190 ] && [ \$((e - now)) -le 7210 ]"
check "the deadline is also stored as a readable UTC time" "J $t6 .hold.until | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'"
check "hold says what happens with no answer" "printf '%s' \"\$out\" | grep -q 'default: sqlite'"
out="$(O task show "$t6" --plan p 2>&1)"
check "task show lists the default" "printf '%s' \"\$out\" | grep -q 'default:  sqlite'"
L "_ff_apply_defaults p" >/dev/null 2>&1
check "before the deadline, nothing changes" "[ \"\$(J $t6 .state)\" = held ] && [ \"\$(J $t6 .hold.answer)\" = '' ]"
# A plan whose only task is a held decision with a default: plan run waits for it, --once says when.
( cd "$REPO" && O plan new q --goal 'decide' --no-use >/dev/null 2>&1 )
q1="$(O task add 'choose' --plan q 2>/dev/null)"
O task hold "$q1" --plan q --reason 'a or b?' --default a --until +1h >/dev/null 2>&1
out="$(cd "$REPO" && L "cmd_plan run q --once" 2>&1)"; rc=$?
check "plan run --once stops for the captain and names the pending default" "[ $rc -eq 3 ] && printf '%s' \"\$out\" | grep -q 'goes ahead with its default'"
L "_task_update q $q1 '.hold.until_epoch = (now | floor) + 2'" >/dev/null 2>&1
out="$(cd "$REPO" && L "cmd_plan run q --interval 1 --max-minutes 1" 2>&1)"; rc=$?
check "a full plan run waits for the deadline instead of stopping, then applies the default" "printf '%s' \"\$out\" | grep -q 'waiting: $q1' && printf '%s' \"\$out\" | grep -q 'nobody answered' && [ \"\$(jq -r .hold.answer \"$OSRC_HOME/plans/q/tasks/$q1.json\")\" = a ]"
L "_task_update p $t6 '.hold.until_epoch = 1'" >/dev/null 2>&1
out="$(L "_ff_apply_defaults p" 2>&1)"
check "after the deadline, the task goes ahead with the default" "[ \"\$(J $t6 .state)\" = todo ] && [ \"\$(J $t6 .hold.answer)\" = sqlite ] && [ \"\$(J $t6 .hold.defaulted)\" = true ]"
check "it says so" "printf '%s' \"\$out\" | grep -q 'nobody answered'"
check "the default reaches the next brief as the captain's decision" "L '_task_brief p $t6' >/dev/null 2>&1; grep -q sqlite \"$OSRC_HOME/plans/p/tasks/$t6/brief.md\""
out="$(O task hold "$t6" --plan p --reason 'when?' --default 'friday' --until 2030-01-02T03:04Z 2>&1)"
check "an ISO deadline parses" "[ \"\$(J $t6 .hold.until_epoch)\" = 1893553440 ]"
O task release "$t6" --plan p --answer monday >/dev/null 2>&1
check "a person's answer wins and clears the deadline" "[ \"\$(J $t6 .hold.answer)\" = monday ] && [ \"\$(J $t6 .hold.defaulted)\" = false ] && [ \"\$(J $t6 .hold.until_epoch)\" = 0 ]"
L "_task_update p $t6 '.state = \"held\" | .hold.default = \"x\" | .hold.until_epoch = 1'" >/dev/null 2>&1
L "_ff_hold p $t6 'a new question'" >/dev/null 2>&1
L "_ff_apply_defaults p" >/dev/null 2>&1
check "a new hold drops the old default, so it cannot fire on the new question" "[ \"\$(J $t6 .state)\" = held ] && [ \"\$(J $t6 .hold.default)\" = '' ]"

echo "=== failure classes ==="
cls() { L "_ff_fail_class \"$1\""; }
check "the done check saying no is work, even if it mentions a timeout" "[ \"\$(cls 'the done check said no: timeout in test')\" = work ]"
check "a 429 is transient" "[ \"\$(cls 'job 20261023-131700-ab ended failed (HTTP 429)')\" = transient ]"
check "a 503 is transient" "[ \"\$(cls 'job 20261023-131700-ab ended failed (503 Service Unavailable)')\" = transient ]"
check "digits inside a job id are not an HTTP code" "[ \"\$(cls 'job 20261023-131700-a503b ended failed (exit 1)')\" = work ]"
check "a worker that never launched is transient" "[ \"\$(cls 'its worker never launched (no job 300s after it was claimed)')\" = transient ]"
check "wedged is too big" "[ \"\$(cls 'job 20261023-131700-ab ended wedged')\" = too_big ]"
check "a timeout is too big" "[ \"\$(cls 'job 20261023-131700-ab ended timeout')\" = too_big ]"
check "a full context window is too big" "[ \"\$(cls 'job x ended failed (context length exceeded)')\" = too_big ]"
check "npm install is not a stall" "[ \"\$(cls 'job x ended failed (npm install failed)')\" = work ]"
check "an unknown model is a model problem" "[ \"\$(cls 'job x ended failed (model not found)')\" = model ]"
check "an empty answer is a model problem" "[ \"\$(cls 'job x ended failed (empty output)')\" = model ]"
check "a refused launch is a lane problem, so it moves on" "[ \"\$(cls 'the worker did not launch: lane is down')\" = model ]"
check "a quota error is a model problem" "[ \"\$(cls 'job x ended failed (usage limit reached)')\" = model ]"

echo "=== retry by failure mode ==="
mk() { local id; id="$(O task add "$1" --retries 3 2>/dev/null)"
  L "_task_update p $id '.state = \"running\" | .attempts = 1 | .model = \"m1\" | .fallback = [\"m1\",\"m2\",\"m3\"]'" >/dev/null 2>&1; echo "$id"; }
again() { L "_task_update p $1 '.state = \"running\" | .attempts = (.attempts + 1)'" >/dev/null 2>&1; }
r1="$(mk transient)"; L "_ff_fail_or_retry p $r1 'job 20261023-131700-ab ended failed (HTTP 429)'" >/dev/null 2>&1
check "transient: retried on the same model" "[ \"\$(J $r1 .state)\" = todo ] && [ \"\$(J $r1 .model)\" = m1 ] && [ \"\$(J $r1 .last_fail_class)\" = transient ]"
check "transient: the brief note says it was not the work" "J $r1 .result | grep -q 'not the work itself'"
again "$r1"; L "_ff_fail_or_retry p $r1 'job 20261023-131700-ab ended failed (HTTP 429)'" >/dev/null 2>&1
check "transient twice: moves to the next model" "[ \"\$(J $r1 .model)\" = m2 ]"
r2="$(mk model)"; L "_ff_fail_or_retry p $r2 'job x ended failed (model not found)'" >/dev/null 2>&1
check "model: switches to the next model" "[ \"\$(J $r2 .state)\" = todo ] && [ \"\$(J $r2 .model)\" = m2 ]"
again "$r2"; L "_ff_fail_or_retry p $r2 'job x ended failed (empty output)'" >/dev/null 2>&1
check "model twice in a row: held for a re-plan" "[ \"\$(J $r2 .state)\" = held ] && J $r2 .hold.reason | grep -q 'model or lane problem'"
r3="$(mk big)"; L "_ff_fail_or_retry p $r3 'job x ended wedged'" >/dev/null 2>&1
check "too big: same model, asked for a smaller piece with OPEN ITEMS" "[ \"\$(J $r3 .model)\" = m1 ] && J $r3 .result | grep -q 'smallest piece' && J $r3 .result | grep -q 'OPEN ITEMS'"
again "$r3"; out="$(L "_ff_fail_or_retry p $r3 'job x ended timeout'" 2>&1)"
check "too big twice: held, asking to split it" "[ \"\$(J $r3 .state)\" = held ] && J $r3 .hold.reason | grep -q 'Split it'"
r4="$(mk work)"; L "_ff_fail_or_retry p $r4 'the done check said no: tests fail'" >/dev/null 2>&1
again "$r4"; L "_ff_fail_or_retry p $r4 'the done check said no: tests still fail'" >/dev/null 2>&1
check "work twice: keeps retrying within the budget" "[ \"\$(J $r4 .state)\" = todo ] && J $r4 .result | grep -q 'tests still fail'"
r5="$(O task add 'out of budget' --retries 0 2>/dev/null)"
L "_task_update p $r5 '.state = \"running\" | .attempts = 1'" >/dev/null 2>&1
L "_ff_fail_or_retry p $r5 'the done check said no: nope'" >/dev/null 2>&1
check "out of retries: fails for good as before" "[ \"\$(J $r5 .state)\" = failed ] && [ \"\$(J $r5 .last_fail_class)\" = work ]"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
