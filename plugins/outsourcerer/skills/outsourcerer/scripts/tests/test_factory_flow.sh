#!/usr/bin/env bash
# test_factory_flow.sh -- Track D: the `plan run` scheduler and `flow` expansion.
# The task store (Track B) and done contract / land (Track C) are SHIMMED here, in the test only,
# against the contract's function names and data model. Jobs are fake job dirs (status files),
# never real model calls.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
FLOW="$HERE/../factory-flow.sh"
[ -f "$SRC" ] && [ -f "$FLOW" ] || { echo "FAIL: cannot find $SRC or $FLOW"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "$HOME/.test-factory-flow.XXXXXX")"
export GIT_CEILING_DIRECTORIES="$TMP"
HOME="$TMP/home"; export HOME; mkdir -p "$HOME"
export OSRC_HOME="$TMP/state"; mkdir -p "$OSRC_HOME/jobs"
SLEEPERS=""
trap 'for p in $SLEEPERS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
. "$FLOW"
export OSRC_HEARTBEAT_DISABLED=1

# Review content precedes the engine's completion protocol. Fenced examples are never verdicts.
mkdir -p "$OSRC_JOBS/verdict-regression"
printf 'Review complete\nVERDICT: PASS\n\nOSRC::PROGRESS#abc done\nOSRC::DONE#abc complete\n' > "$OSRC_JOBS/verdict-regression/last.txt"
_ff_verdict verdict-regression
[ "$_FF_VERDICT" = pass ] && ok 'D1: completion metadata follows a valid verdict' || bad 'D1: completion metadata follows a valid verdict'
printf 'Review complete\nVERDICT: PASS\nOSRC::DONE#abc complete\n>>> [receipt] job 123 ok\n' > "$OSRC_JOBS/verdict-regression/last.txt"
_ff_verdict verdict-regression
[ "$_FF_VERDICT" = pass ] && ok 'D1: a trailing engine receipt line does not hide the verdict' || bad "D1: receipt line made verdict $_FF_VERDICT"
printf '```text\nVERDICT: PASS\n' > "$OSRC_JOBS/verdict-regression/last.txt"
_ff_verdict verdict-regression
[ "$_FF_VERDICT" != pass ] && ok 'S22: unfinished fence cannot approve' || bad 'S22: unfinished fence cannot approve'

# ------------------------------------------------------------------ task store (Track B)
# When factory-tasks.sh sits next to the engine (after integration) the REAL task store is used and
# only its launch seam (_task_bg_launch) is faked. Otherwise these shims mirror B's documented API:
# _task_new, _task_view (.derived/.blocked_by), _task_update (guarded, held/failed -> wake),
# _task_dispatch (claim + attempts+1, brief with "Earlier attempt", launch failure -> task failed).
REAL_B=0
if [ -f "$HERE/../factory-tasks.sh" ]; then . "$HERE/../factory-tasks.sh"; REAL_B=1; fi
echo "INFO: task store under test: $([ "$REAL_B" = 1 ] && echo 'real factory-tasks.sh' || echo 'test shims')"
if [ "$REAL_B" = 0 ]; then
_plan_dir() { printf '%s\n' "$OSRC_HOME/plans/$1"; }
_plan_resolve() {
  local p="${1:-}"; [ -n "$p" ] || p="$(cat "$OSRC_HOME/plans/current" 2>/dev/null)"
  [ -n "$p" ] || die "no plan"; printf '%s\n' "$p"
}
_task_get() { cat "$OSRC_HOME/plans/$1/tasks/$2.json" 2>/dev/null; }
_task_update() {
  local plan="$1" tid="$2" filter="$3" f old new tmp; shift 3
  f="$OSRC_HOME/plans/$plan/tasks/$tid.json"; [ -f "$f" ] || return 1
  old="$(jq -r .state "$f")"
  tmp="$(jq -e "$@" "($filter) | .updated = \"now\"" "$f" 2>/dev/null)" || return 1
  printf '%s\n' "$tmp" > "$f.tmp" && mv -f "$f.tmp" "$f" || return 1
  new="$(jq -r .state "$f")"
  if [ "$old" != "$new" ]; then
    printf '{"task":"%s","event":"state","from":"%s","to":"%s"}\n' "$tid" "$old" "$new" >> "$OSRC_HOME/plans/$plan/events.jsonl"
    case "$new" in held|failed)
      _wake_append "$(jq -cn --arg id "factory.$plan.$tid.$new.$RANDOM" --arg p "$plan" --arg t "$tid" --arg s "$new" \
        '{event_id:$id,kind:"factory-task",plan:$p,task:$t,state:"blocked",task_state:$s,task_summary:"x"}')" >/dev/null 2>&1 ;;
    esac
  fi
  return 0
}
_task_list() { local d="$OSRC_HOME/plans/$1/tasks"; if ls "$d"/t*.json >/dev/null 2>&1; then jq -s 'sort_by(.id | ltrimstr("t") | tonumber)' "$d"/t*.json; else echo '[]'; fi; }
_task_view() {
  _task_list "$1" | jq -c '(map({key: .id, value: .state}) | from_entries) as $s
    | map(. as $t | ([($t.deps // [])[] | {id: ., state: ($s[.] // "missing")} | select(.state != "done")]) as $bl
          | . + {blocked_by: $bl, derived: (if $t.state == "todo" then (if ($bl | length) == 0 then "ready" else "blocked" end) else $t.state end)})'
}
_task_ready() { _task_view "$1" | jq -r '.[] | select(.derived == "ready") | .id'; }
_task_event() { printf '{"task":"%s","event":"%s","note":"%s"}\n' "$2" "$3" "${4:-}" >> "$OSRC_HOME/plans/$1/events.jsonl"; }
_task_new() {
  local plan="$1" fields="$2" n d
  d="$OSRC_HOME/plans/$plan/tasks"; mkdir -p "$d"
  for x in $(printf '%s' "$fields" | jq -r '(.deps // [])[]'); do [ -f "$d/$x.json" ] || { echo "missing dep $x" >&2; return 1; }; done
  n="$(ls "$d" | sed -n 's/^t\([0-9]*\)\.json$/\1/p' | sort -n | tail -1)"; n="t$(( ${n:-0} + 1 ))"
  jq -n --arg id "$n" --arg plan "$plan" --argjson f "$fields" '
    {schema:1,title:"",shape:"scout",state:"todo",deps:[],prompt:"",spec:"",check:"",verb:"",model:"",provider:"",deliver:"local",
     retries:1,attempts:0,job:"",jobs:[],worktree:"",branch:"",base_sha:"",head_sha:"",hold:{reason:"",until:"",answer:""},
     result:"",evidence:"",flow:{name:"",stage:""}} * $f | .id = $id | .plan = $plan
    | if .prompt == "" then .prompt = .title else . end' > "$d/$n.json" || return 1
  mkdir -p "$d/$n"; echo "$n"
}
_task_brief() {
  local plan="$1" tid="$2" t f
  t="$(_task_get "$plan" "$tid")"; f="$OSRC_HOME/plans/$plan/tasks/$tid/brief.md"; mkdir -p "${f%/*}"
  { printf '%s\n\n' "$(printf '%s' "$t" | jq -r .prompt)"
    [ "$(printf '%s' "$t" | jq -r .hold.answer)" != "" ] && printf '## Decision from the captain\n\n%s\n\n' "$(printf '%s' "$t" | jq -r .hold.answer)"
    if [ "$(printf '%s' "$t" | jq -r .attempts)" -gt 0 ] && [ -n "$(printf '%s' "$t" | jq -r .result)" ]; then
      printf '## Earlier attempt\n\nWhat went wrong: %s\n' "$(printf '%s' "$t" | jq -r .result)"; fi; } > "$f"
  echo "$f"
}
_task_dispatch() {
  local plan="$1" tid="$2" jid
  _task_update "$plan" "$tid" 'if .state != "todo" then error("no") else .state = "running" | .attempts += 1 | .job = "" end' || { echo "not ready" >&2; return 1; }
  _task_brief "$plan" "$tid" >/dev/null
  jid="$( export OSRC_TASK_REF="$plan/$tid"; _task_bg_launch "$PWD" run "x" )" || {
    _task_update "$plan" "$tid" '.state = "failed" | .result = $r' --arg r "the worker did not launch"; echo "launch failed" >&2; return 1; }
  _task_update "$plan" "$tid" '.job = $j | .jobs += [$j]' --arg j "$jid"
  echo "$jid"
}
fi
# The launch seam (both modes): a FAKE job whose status comes from $TMP/outcomes/<tid>, one line per
# attempt (done | failed | blocked | running). Copies the brief the worker would have received.
_task_bg_launch() {
  local ref="${OSRC_TASK_REF:-}" plan tid n out job
  plan="${ref%%/*}"; tid="${ref#*/}"
  [ -f "$TMP/dispatch-refuse-$tid" ] && { echo "ERROR: lane is down for $tid" >&2; return 1; }
  [ -f "$TMP/slow-$plan-$tid" ] && sleep "$(cat "$TMP/slow-$plan-$tid")"
  n=$(( $(cat "$TMP/count-$plan-$tid" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$TMP/count-$plan-$tid"
  echo "$plan/$tid" >> "$TMP/launches"
  out="$(sed -n "${n}p" "$TMP/outcomes/$tid" 2>/dev/null)"; [ -n "$out" ] || out=done
  job="$(date +%Y%m%d-%H%M%S)-$plan$tid$n$RANDOM"; job="$(printf '%s' "$job" | tr -cd '0-9A-Za-z-')"
  mkdir -p "$OSRC_JOBS/$job"
  printf '%s\n' "$out" > "$OSRC_JOBS/$job/status"
  date +%s > "$OSRC_JOBS/$job/started_at"
  [ "$out" = running ] && printf '%s\n' "$$" > "$OSRC_JOBS/$job/pid"
  [ "$out" = failed ] && printf 'exit-nonzero:rc=1\n' > "$OSRC_JOBS/$job/reason"
  # Worker output: per-attempt file first (lasttxt-<plan>-<tid>-<n>), then the per-task one. A
  # nolast-<tid> marker leaves last.txt empty and puts the text in out.log only.
  local lt="$TMP/lasttxt-$plan-$tid-$n"; [ -f "$lt" ] || lt="$TMP/lasttxt-$tid"
  if [ -f "$TMP/nolast-$tid" ]; then : > "$OSRC_JOBS/$job/last.txt"; cat "$lt" > "$OSRC_JOBS/$job/out.log" 2>/dev/null
  else printf 'result of %s attempt %s\n%s\n' "$tid" "$n" "$(cat "$lt" 2>/dev/null)" > "$OSRC_JOBS/$job/last.txt"; fi
  local a prevm="" usedm=""; for a in "$@"; do [ "$prevm" = "-m" ] && usedm="$a"; prevm="$a"; done
  echo "$plan/$tid ${usedm:-none}" >> "$TMP/models"
  cp "$OSRC_HOME/plans/$plan/tasks/$tid/brief.md" "$TMP/brief-$plan-$tid-$n" 2>/dev/null
  echo "$job"
}
# ------------------------------------------------------------------ Track C shims (test only, both modes:
# the real done contract needs real worktrees + commits; track C tests it on its own)
_factory_done_check() {
  echo "$1/$2" >> "$TMP/donechecks"
  if [ -f "$TMP/donefail-$2" ]; then echo "no commits beyond base"; return 1; fi
  echo "done: job finished"; return 0
}
cmd_land() { echo "$1" >> "$TMP/landed"; echo "$*" >> "$TMP/landargs"; [ -f "$TMP/landfail-$1" ] && { echo "merge breaks check"; return 1; }; _task_update "$3" "$1" '.landed = true' >/dev/null; echo "landed $1"; return 0; }

REPO="$TMP/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q; git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
REPO="$(cd "$REPO" && pwd -P)"
mkplan() {   # <plan> then lines "tid|deps-csv|shape|retries"
  local plan="$1" line tid deps shape retries
  mkdir -p "$OSRC_HOME/plans/$plan/tasks"
  jq -n --arg n "$plan" --arg r "$REPO" --arg b "$(git -C "$REPO" symbolic-ref --short HEAD)" '{schema:1,name:$n,goal:"g",repo:$r,base_branch:$b,created:"x",updated:"x"}' > "$OSRC_HOME/plans/$plan/plan.json"
  shift
  for line in "$@"; do
    IFS='|' read -r tid deps shape retries <<EOF
$line
EOF
    jq -n --arg id "$tid" --arg plan "$plan" --arg deps "$deps" --arg shape "${shape:-scout}" --argjson r "${retries:-1}" \
      '{schema:1,id:$id,plan:$plan,title:("task " + $id),shape:$shape,state:"todo",deps:($deps | split(",") | map(select(. != ""))),
        prompt:("do " + $id),spec:(if $shape == "ship" then "change a.txt" else "" end),check:"",verb:"run",model:"",provider:"",deliver:"local",retries:$r,attempts:0,
        job:"",jobs:[],worktree:"",branch:"",base_sha:"",head_sha:"",hold:{reason:"",until:"",answer:""},result:"",evidence:"",
        flow:{name:"",stage:""},created:"x",updated:"x"}' > "$OSRC_HOME/plans/$plan/tasks/$tid.json"
  done
}
st() { _task_get "$1" "$2" | jq -r .state; }
wakes() { cat "$OSRC_WAKE_QUEUE" 2>/dev/null | grep -c "$1" | tr -d ' '; }
twakes() { cat "$OSRC_WAKE_QUEUE" 2>/dev/null | grep '"kind":"factory-task"' | grep "\"plan\":\"$1\"" | grep "\"task\":\"$2\"" | grep -c "\"task_state\":\"$3\"" | tr -d ' '; }
mkdir -p "$TMP/outcomes"

# Round-three regressions. These seams inject cancellation/crashes without launching models.
_FF_DEADLINE=0; _FF_AUTO_LAND=0
for text in '```text
VERDICT: PASS
```' '~~~
VERDICT: PASS' 'VERDICT: FAIL - PASS is also possible'; do
  printf '%s\n' "$text" > "$OSRC_JOBS/verdict-regression/last.txt"
  _ff_verdict verdict-regression
  [ "$_FF_VERDICT" != pass ] && [ "$_FF_VERDICT" != fail ] && ok 'S22/C1: fenced or contradictory verdict is ambiguous' || bad 'S22/C1: unsafe verdict accepted'
done
mkplan sharedverdict 't1||scout|0'
_task_update sharedverdict t1 '.job = "verdict-regression"' >/dev/null
for verdict in PASS FAIL; do
  printf 'VERDICT: %s\nOSRC::DONE#abc complete\n' "$verdict" > "$OSRC_JOBS/verdict-regression/last.txt"
  out="$(_factory_review_verdict sharedverdict t1)"; rc=$?
  [ "$out" = "$verdict" ] && { [ "$verdict:$rc" = PASS:0 ] || [ "$verdict:$rc" = FAIL:1 ]; } && ok "D1/C1: shared verdict $verdict" || bad "shared verdict: $out/$rc"
done

for opt in --max-parallel --interval --max-minutes --plan; do
  ( cmd_plan_run "$opt" > "$TMP/option.log" 2>&1 ) & cp=$!
  ( sleep 2; kill -TERM "$cp" 2>/dev/null ) & watch=$!
  wait "$cp"; rc=$?; kill "$watch" 2>/dev/null; wait "$watch" 2>/dev/null
  [ "$rc" = 1 ] && ok "S20/D5: missing $opt returns promptly" || bad "missing $opt rc=$rc"
done
for opt in --plan --repo; do
  ( cmd_flow run spec-build "$opt" > "$TMP/option.log" 2>&1 ) & cp=$!
  ( sleep 2; kill -TERM "$cp" 2>/dev/null ) & watch=$!
  wait "$cp"; rc=$?; kill "$watch" 2>/dev/null; wait "$watch" 2>/dev/null
  [ "$rc" = 1 ] && ok "S20/D5: flow missing $opt returns promptly" || bad "flow missing $opt rc=$rc"
done
mkplan decimal
( cmd_plan_run decimal --once --max-minutes 08 --interval 01 --max-parallel 02 >/dev/null 2>&1 ); rc=$?
[ "$rc" = 0 ] && ok 'D5: leading-zero limits use decimal arithmetic' || bad "decimal rc=$rc"

out="$( jq() { command jq "$@" | awk '{printf "%s\r\n", $0}'; }; _ff_flow_load spec-build )"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | command jq -e '.name == "spec-build"' >/dev/null && ok 'D4: native jq CRLF does not reject a valid flow' || bad "CRLF flow rc=$rc"
out="$( jq() { command jq "$@" | awk '{printf "%s\r\n", $0}'; }; _ff_next_model '{"model":"sol","fallback":["sol","opus"]}' dispatch )"
[ "$out" = sol ] && ok 'D4: model comparisons strip native jq CR' || bad "CRLF model: [$out]"
mkdir -p "$TMP/unknown.lock"; printf '99999999 unknown\n' > "$TMP/unknown.lock/owner"
( _pid_start_identity() { return 1; }; kill() { return 1; }; _ff_lock_acquire "$TMP/unknown.lock" ); rc=$?
[ "$rc" = 1 ] && [ -f "$TMP/unknown.lock/owner" ] && ok 'D11: denied process inspection never proves death' || bad 'D11: unknown owner lock stolen'
( unset BASHPID; _ff_lock_acquire "$TMP/subshell.lock"; sh -c 'echo $PPID' > "$TMP/real-pid"; cut -d ' ' -f1 "$TMP/subshell.lock/owner" > "$TMP/lock-pid"; _ff_lock_release )
[ "$(cat "$TMP/real-pid")" = "$(cat "$TMP/lock-pid")" ] && [ ! -d "$TMP/subshell.lock" ] && ok 'D12: lock records and releases the actual subshell PID' || bad 'D12: lock owner is parent PID'

mkplan retrylaunch 't1||scout|1'
_task_update retrylaunch t1 '.state="failed" | .launch_failed=true | .attempts=1 | .attempt_token="attempt-one"' >/dev/null
_ff_reconcile retrylaunch >/dev/null
[ "$(st retrylaunch t1)" = todo ] && ok 'S16: persisted failed launch consumes remaining retry' || bad 'S16: failed launch stranded'
mkplan pendingland 't1||ship|1'
_task_update pendingland t1 '.state="done" | .auto_land_pending=true' >/dev/null
rm -f "$TMP/landed"; _ff_reconcile pendingland >/dev/null
[ "$(cat "$TMP/landed")" = t1 ] && _task_get pendingland t1 | jq -e '.auto_land_complete == true and ((.auto_land_pending // false) | not)' >/dev/null && ok 'S11: restart reconciles durable auto-land intent' || bad 'S11: pending land skipped'
_ff_reconcile pendingland >/dev/null
[ "$(wc -l < "$TMP/landed" | tr -d ' ')" = 1 ] && ok 'S11: recovered auto-land runs once' || bad 'S11: duplicate recovered land'
mkplan boundaryland 't1||ship|1'; _task_update boundaryland t1 '.state="done"' >/dev/null
( _FF_AUTO_LAND=1; _ff_reconcile boundaryland >/dev/null )
_task_get boundaryland t1 | jq -e '.auto_land_complete == true' >/dev/null && ok 'S11: legacy done-before-land boundary is reconciled' || bad 'S11: boundary state skipped'

mkplan revision 't1||ship|1' 't2|t1|scout|1'
_task_update revision t1 '.state="done" | .head_sha="new"' >/dev/null
_task_update revision t2 '.state="done" | .require_verdict=true | .reviewed_head="old" | .attempts=1' >/dev/null
_ff_reconcile revision >/dev/null
[ "$(st revision t2)" = todo ] && ok 'S3: changed build invalidates completed review' || bad 'S3: old approval retained'
_ff_dispatch revision 1 >/dev/null
_task_get revision t2 | jq -e '.reviewed_head == "new" and .review_target == "t1"' >/dev/null && ok 'S3: reviewer launch records the build revision' || bad 'S3: review revision absent'

mkdir -p "$OSRC_JOBS/ownership-check"
printf 'done\n' > "$OSRC_JOBS/ownership-check/status"
printf 'VERDICT: FAIL - bug\nOSRC::DONE#abc complete\n' > "$OSRC_JOBS/ownership-check/last.txt"
mkplan cancelreview 't1||ship|1' 't2|t1|scout|1'
_task_update cancelreview t1 '.state="done"' >/dev/null
_task_update cancelreview t2 '.state="verifying" | .require_verdict=true | .job="ownership-check" | .attempt_token="old"' >/dev/null
( _factory_done_check() { _task_update "$1" "$2" '.state="canceled"' >/dev/null; echo checked; }; _ff_verify cancelreview t2 "$(_task_list cancelreview)" ) >/dev/null
[ "$(st cancelreview t2)" = canceled ] && [ "$(st cancelreview t1)" = done ] && ok 'S6: cancellation during check never resurrects reviewer or build' || bad 'S6: cancellation overwritten'
_task_update cancelreview t2 '.state="verifying" | .verifying_token="original"' >/dev/null
( _factory_done_check() { _task_update "$1" "$2" '.verifying_token="replacement"' >/dev/null; echo checked; }; _ff_verify cancelreview t2 "$(_task_list cancelreview)" ) >/dev/null
_task_get cancelreview t2 | jq -e '.state == "verifying" and .verifying_token == "replacement"' >/dev/null && ok 'C2/C3: displaced checker cannot complete a replacement claim' || bad 'C3: replacement checker overwritten'

# Simulate a crash after only the build reset landed, then recover the paired transaction.
mkplan paircrash 't1||ship|1' 't2|t1|scout|1'
_task_update paircrash t1 '.state="done"' >/dev/null
_task_update paircrash t2 '.state="verifying" | .require_verdict=true | .job="ownership-check"' >/dev/null
eval "_saved_write_json() $(declare -f _factory_write_json | tail -n +2)"
( _factory_write_json() { case "$1" in */paircrash/tasks/t2.json) return 1 ;; esac; _saved_write_json "$@"; }
  _FF_VERDICT_LINE='VERDICT: FAIL - bug'; _ff_review_failed paircrash t2 "$(_task_list paircrash)" ) >/dev/null
[ -f "$OSRC_HOME/plans/paircrash/review-transaction.json" ] && [ "$(st paircrash t1)" = todo ] && ok 'S6: interrupted paired reset retains recovery journal' || bad 'S6: reset journal missing'
_ff_reconcile paircrash >/dev/null
[ "$(st paircrash t1)" = todo ] && [ "$(st paircrash t2)" = todo ] && [ ! -f "$OSRC_HOME/plans/paircrash/review-transaction.json" ] && ok 'S6: paired reset completes before redispatch' || bad 'S6: incomplete paired reset'

mkplan staleverify 't1||scout|0'
_task_update staleverify t1 '.state="verifying" | .job="ownership-check" | .verifying_pid=$p | .verifying_at=1 | .verifying_start=$start' --arg p "$$" --arg start "$(_pid_start_identity "$$")" >/dev/null
: > "$TMP/donechecks"; _ff_reconcile staleverify >/dev/null
[ "$(st staleverify t1)" = done ] && [ "$(cat "$TMP/donechecks")" = staleverify/t1 ] && ok 'D17: stale verification can be taken over despite a live PID' || bad 'D17: live stale checker blocks forever'
_task_get staleverify t1 | jq -e 'has("verifying_pid") == false and has("verifying_start") == false and has("verifying_at") == false' >/dev/null && ok 'C3: completion clears all checker ownership fields' || bad 'C3: stale checker fields remain'
_task_update staleverify t1 '.state="verifying" | .verifying_pid=$p | .verifying_at=$now | .verifying_start="reused-pid"' --arg p "$$" --argjson now "$(date +%s)" >/dev/null
_ff_reconcile staleverify >/dev/null
[ "$(st staleverify t1)" = done ] && ok 'D17: PID identity mismatch permits immediate takeover' || bad 'D17: reused PID blocks takeover'

mkplan adoptspace 't1||ship|0'
_task_update adoptspace t1 '.state="running" | .claimed_at=1 | .attempt_token="current"' >/dev/null
SPACE_JOBS="$TMP/state with spaces/jobs"; mkdir -p "$SPACE_JOBS/parent" "$SPACE_JOBS/nested"
printf 'adoptspace/t1\n' > "$SPACE_JOBS/parent/task_ref"; printf 'current\n' > "$SPACE_JOBS/parent/task_attempt_token"
printf 'adoptspace/t1\n' > "$SPACE_JOBS/nested/task_ref"; printf 'obsolete\n' > "$SPACE_JOBS/nested/task_attempt_token"
printf 'running\n' > "$SPACE_JOBS/parent/status"; printf '%s\n' "$$" > "$SPACE_JOBS/parent/pid"
printf '{"path":"/work tree","branch":"feature","base_sha":"base"}\n' > "$SPACE_JOBS/parent/worktree.json"
( OSRC_JOBS="$SPACE_JOBS"; _ff_reconcile adoptspace ) >/dev/null
_task_get adoptspace t1 | jq -e '.job == "parent" and .worktree == "/work tree" and .branch == "feature" and .base_sha == "base"' >/dev/null && ok 'S18/D10: adoption restores receipt and matches attempt in paths with spaces' || bad 'S18: incomplete or incorrect adoption'
_task_update adoptspace t1 '.job="" | .jobs=[]' >/dev/null
( OSRC_JOBS="$SPACE_JOBS"; _ff_find_job_by_ref() { _task_update "$1" "$2" '.attempt_token="replacement"' >/dev/null; echo parent; }; _ff_reconcile adoptspace ) >/dev/null
_task_get adoptspace t1 | jq -e '.attempt_token == "replacement" and .job == ""' >/dev/null && ok 'C2/S18: old recovery cannot attach to replacement attempt' || bad 'C2: orphan attached to replacement'
printf 'current\n' > "$SPACE_JOBS/nested/task_attempt_token"
out="$( OSRC_JOBS="$SPACE_JOBS"; _ff_find_job_by_ref adoptspace t1 '{"attempt_token":"current"}' )"
[ -z "$out" ] && ok 'S18: multiple matching receipts are never guessed' || bad 'S18: ambiguous orphan selected'

# The engine and factory-tasks.sh name the link file task_attempt; adoption must read that name.
mkdir -p "$SPACE_JOBS/engine"; printf 'adoptspace/t1\n' > "$SPACE_JOBS/engine/task_ref"; printf 'enginetok\n' > "$SPACE_JOBS/engine/task_attempt"
eout="$( OSRC_JOBS="$SPACE_JOBS"; _ff_find_job_by_ref adoptspace t1 '{"attempt_token":"enginetok"}' )"
case "$eout" in *engine*) ok "adoption reads the engine's task_attempt link file" ;; *) bad "adoption ignored task_attempt (got '$eout')" ;; esac

mkplan incompleteflow 't1||scout|0' 't2||scout|0'
_task_update incompleteflow t1 '.state="held" | .flow_expansion="interrupted"' >/dev/null
printf '{"token":"interrupted","flow":"spec-build"}\n' > "$OSRC_HOME/plans/incompleteflow/flow-expansion.json"
( cmd_plan_run incompleteflow --once > "$TMP/incomplete.log" 2>&1 ); rc=$?
[ "$rc" = 3 ] && [ "$(st incompleteflow t2)" = todo ] && ok 'S23/D3: incomplete expansion blocks scheduling' || bad 'S23: partial flow scheduled'
( _plan_lock incompleteflow; _ff_flow_rollback incompleteflow; _plan_unlock incompleteflow )
[ "$(_task_list incompleteflow | jq -c '[.[].id]')" = '["t2"]' ] && [ -f "$OSRC_HOME/plans/incompleteflow/plan.json" ] && ok 'D3: rollback preserves concurrent unrelated tasks and plan' || bad 'D3: rollback deleted unrelated work'

mkplan conflictstage 't1||ship|0' 't2|t1|scout|0'
_task_update conflictstage t1 '.state="done"' >/dev/null
( _ff_run_land() { _task_update "$1" "$2" '.state="held"' >/dev/null; echo conflict; return 1; }; _ff_land_stage conflictstage t2 t1 ) >/dev/null
_task_get conflictstage t2 | jq -e '.hold.reason | test("task release t1.*--plan conflictstage.*plan run conflictstage.*task release t2.*--plan conflictstage")' >/dev/null && ok 'S14: conflict hints resolve build before releasing land stage, with explicit plan' || bad 'S14: invalid conflict recovery order'
mkplan landerror 't1||ship|0'; _task_update landerror t1 '.state="done"' >/dev/null
( _ff_run_land() { echo 'integration check failed'; return 1; }; _ff_auto_land landerror t1 ) >/dev/null
_task_get landerror t1 | jq -e '.state == "done" and .land_error_at > 0 and (.land_error | test("integration check failed")) and .auto_land_pending == false' >/dev/null && ok 'S13: integration error is separate from done state and stops automatic retry' || bad 'S13: landing outcome contract violated'

# Cancel after observing job completion but before acquiring the verifying claim.
mkplan outcome_cancel 't1||scout|0'
_task_update outcome_cancel t1 '.state="running" | .job="ownership-check" | .attempt_token="same"' >/dev/null
( _ff_job_outcome() { _task_update outcome_cancel t1 '.state="canceled"' >/dev/null; _FF_OUT=ok; }; _ff_reconcile outcome_cancel ) >/dev/null
[ "$(st outcome_cancel t1)" = canceled ] && ok 'S6/C2: cancellation between outcome read and verifying claim wins' || bad 'S6: canceled task reclaimed as verifying'

# The reviewer must also be reset when the build moves while its checker runs.
mkplan duringreview 't1||ship|1' 't2|t1|scout|1'
_task_update duringreview t1 '.state="done" | .head_sha="before"' >/dev/null
_task_update duringreview t2 '.state="verifying" | .require_verdict=true | .reviewed_head="before" | .job="ownership-check"' >/dev/null
printf 'VERDICT: PASS\nOSRC::DONE#abc complete\n' > "$OSRC_JOBS/ownership-check/last.txt"
( _factory_done_check() { _task_update duringreview t1 '.head_sha="after"' >/dev/null; echo checked; }; _ff_verify duringreview t2 "$(_task_list duringreview)" ) >/dev/null
[ "$(st duringreview t2)" = todo ] && ok 'S3: build changing during review cannot acquire approval' || bad 'S3: in-flight stale review approved'

( jq() { return 7; }; _ff_jq -r . >/dev/null ); rc=$?
[ "$rc" = 7 ] && ok 'D4: CRLF normalization preserves jq failure status' || bad 'D4: jq error hidden'

# Kill the expansion owner after a task is written, before its caller records the returned tid.
# Both tasks are still held, and the durable marker survives the exact SIGKILL boundary.
eval "_crash_task_new() $(declare -f _task_new | tail -n +2)"
( _task_new() {
    local result owner
    result="$(_crash_task_new "$@")" || return 1
    if [ "$result" = t2 ]; then
      read -r owner _ < "$(_plan_dir "$1")/.lock/owner"
      kill -KILL "$owner"
    fi
    printf '%s\n' "$result"
  }
  cmd_flow run council-build --plan killedflow --repo "$REPO" --var goal=g >/dev/null 2>&1
) 2>/dev/null
[ -f "$OSRC_HOME/plans/killedflow/flow-expansion.json" ] && _task_list killedflow | jq -e 'length == 2 and all(.[]; .state == "held")' >/dev/null && ok 'S23: SIGKILL leaves an incomplete marker and only held tasks' || bad 'S23: killed expansion exposed runnable tasks'
( cmd_plan_run killedflow --once >/dev/null 2>&1 ); rc=$?
[ "$rc" = 3 ] && ok 'S23: scheduler refuses a physically interrupted expansion' || bad "S23: killed expansion scheduler rc=$rc"
( cmd_flow run council-build --plan killedflow --repo "$REPO" --var goal=g >/dev/null 2>&1 ); rc=$?
[ "$rc" = 0 ] && [ ! -f "$OSRC_HOME/plans/killedflow/flow-expansion.json" ] && _task_list killedflow | jq -e 'length == 6 and all(.[]; .state == "todo")' >/dev/null && ok 'D3/S23: rerun replaces only the interrupted expansion' || bad 'S23: interrupted expansion could not recover'

rm -f "$TMP/landed" "$TMP/landargs" "$TMP/donechecks"
if [ "${OSRC_FLOW_REGRESSION_ONLY:-0}" = 1 ]; then
  echo "test_factory_flow regressions: $pass passed, $fail failed"
  [ "$fail" = 0 ]; exit $?
fi

# ================================================================== scheduler
# 1. success chain, deps respected, exit 0, finished wake
mkplan p1 't1||scout|1' 't2|t1|scout|1'
out="$( cmd_plan_run p1 --interval 1 2>&1 )"; rc=$?
[ "$rc" = 0 ] && [ "$(st p1 t1)" = done ] && [ "$(st p1 t2)" = done ] && ok "all tasks done -> exit 0" || bad "success chain rc=$rc t1=$(st p1 t1) t2=$(st p1 t2): $out"
[ "$(sed -n 1p "$OSRC_HOME/plans/p1/events.jsonl" | jq -r .task)" = t1 ] && ! grep -q '"task":"t2","event":"state","from":"todo","to":"running"' <<<"$(sed -n 1,2p "$OSRC_HOME/plans/p1/events.jsonl")" \
  && ok "t2 started only after t1 finished" || bad "dependency order not respected"
printf '%s' "$out" | grep -q "Captain's Call: 0 | Landed/Done: 2 | Underway: 0 | Next: 0 ready" && ok "four-bucket summary printed each tick" || bad "summary missing: $out"
printf '%s' "$out" | grep -q "stopped: p1 is finished (2 done)" && ok "plain stop reason on finish" || bad "finish reason: $out"
[ "$(wakes 'factory-finished')" = 1 ] && ok "plan finished -> one wake event" || bad "finished wake count $(wakes factory-finished)"
( cmd_plan_run p1 --once >/dev/null 2>&1 ); [ "$(wakes 'factory-finished')" = 1 ] && ok "re-running a finished plan does not re-wake" || bad "finished wake repeated"

# 2. failure -> retry -> success, reason lands in the next brief
mkplan p2 't1||scout|1'; printf 'failed\ndone\n' > "$TMP/outcomes/t1"
out="$( cmd_plan_run p2 --interval 1 2>&1 )"; rc=$?
[ "$rc" = 0 ] && [ "$(st p2 t1)" = done ] && ok "failure then retry then success -> done" || bad "retry path rc=$rc state=$(st p2 t1): $out"
grep -q "previous attempt failed because job [0-9A-Za-z-]* ended failed (exit-nonzero:rc=1)" "$TMP/brief-p2-t1-2" \
  && ok "retry brief says why the previous attempt failed" || bad "retry brief: $(cat "$TMP/brief-p2-t1-2" 2>/dev/null)"
[ "$(grep -c 'previous attempt failed' "$TMP/brief-p2-t1-2")" = 1 ] && ! grep -q 'previous attempt failed' "$TMP/brief-p2-t1-1" \
  && ok "failure note appears once, only on the retry" || bad "failure note duplicated or early"
_task_get p2 t1 | jq -e '.result | startswith("previous attempt") | not' >/dev/null && ok "a passed retry replaces the failure note in .result" || bad "stale failure result: $(_task_get p2 t1 | jq -r .result)"

# 3. failure exhausted -> failed + hold reason + wake, exit 3
mkplan p3 't1||scout|1' 't2|t1|scout|1'; printf 'failed\nfailed\n' > "$TMP/outcomes/t1"
out="$( cmd_plan_run p3 --interval 1 2>&1 )"; rc=$?
[ "$rc" = 3 ] && [ "$(st p3 t1)" = failed ] && [ "$(st p3 t2)" = todo ] && ok "retries exhausted -> failed, exit 3" || bad "exhausted rc=$rc: $out"
_task_get p3 t1 | jq -e '.hold.reason | test("failed after 2 attempt")' >/dev/null && ok "captain hold reason recorded" || bad "no hold reason"
[ "$(twakes p3 t1 failed)" = 1 ] && ok "terminal failure -> exactly one wake (the task store's)" || bad "failure wakes: $(twakes p3 t1 failed)"
printf '%s' "$out" | grep -q "needs the captain.*failed: t1.*blocked: t2 waits on t1 (failed)" && ok "stop reason names failed and blocked work" || bad "stuck reason: $out"

# 4. blocked worker -> held + wake ; done check failure goes through retry
mkplan p4 't1||scout|0' 't2||ship|0'; printf 'blocked\n' > "$TMP/outcomes/t1"; touch "$TMP/donefail-t2"
out="$( cmd_plan_run p4 --interval 1 2>&1 )"; rc=$?
[ "$rc" = 3 ] && [ "$(st p4 t1)" = held ] && ok "blocked worker -> held for captain" || bad "blocked rc=$rc t1=$(st p4 t1)"
_task_get p4 t2 | jq -e '.state == "failed" and (.result | test("done check said no: no commits"))' >/dev/null && ok "done-check failure is a failure with its reason" || bad "donecheck: $(_task_get p4 t2)"
[ "$(twakes p4 t1 held)" = 1 ] && ok "held -> exactly one wake" || bad "held wakes: $(twakes p4 t1 held)"
rm -f "$TMP/donefail-t2"

# 5. max-parallel respected + --once exit 124
rm -f "$TMP"/outcomes/*
mkplan p5 't1||scout|1' 't2||scout|1' 't3||scout|1' 't4||scout|1'
for t in t1 t2 t3 t4; do echo running > "$TMP/outcomes/$t"; done
out="$( cmd_plan_run p5 --once --max-parallel 2 2>&1 )"; rc=$?
n_running="$(_task_list p5 | jq '[.[] | select(.state == "running")] | length')"
[ "$rc" = 124 ] && [ "$n_running" = 2 ] && ok "--max-parallel 2 starts two; --once exits 124 while work is underway" || bad "parallel rc=$rc running=$n_running: $out"
( cmd_plan_run p5 --once --max-parallel 2 >/dev/null 2>&1 )
[ "$(_task_list p5 | jq '[.[] | select(.state == "running")] | length')" = 2 ] && ok "a second tick does not exceed the cap" || bad "cap exceeded"
# finish the running jobs -> the next tick reconciles them and starts the rest
for j in $(_task_list p5 | jq -r '.[] | .job | select(. != "")'); do echo done > "$OSRC_JOBS/$j/status"; done
( cmd_plan_run p5 --once --max-parallel 2 >/dev/null 2>&1 )
[ "$(_task_list p5 | jq -r '[.[] | .state] | join(",")')" = "done,done,running,running" ] && ok "finished jobs reconcile and free slots" || bad "reconcile: $(_task_list p5 | jq -c '[.[]|.state]')"

# 6. run lock: a live driver blocks a second loop; a dead one is reclaimed
sleep 60 & SLP=$!; SLEEPERS="$SLEEPERS $SLP"
mkdir -p "$OSRC_HOME/plans/p5/run.lock"; printf '%s %s\n' "$SLP" "$(_pid_start_identity "$SLP")" > "$OSRC_HOME/plans/p5/run.lock/owner"
out="$( cmd_plan_run p5 --once 2>&1 )"; rc=$?
[ "$rc" = 4 ] && printf '%s' "$out" | grep -q "already driving p5 (pid $SLP)" && ok "run lock refuses a second driver with its own exit code (4)" || bad "lock rc=$rc: $out"
kill "$SLP" 2>/dev/null; wait "$SLP" 2>/dev/null
out="$( cmd_plan_run p5 --once 2>&1 )"; rc=$?
[ "$rc" != 1 ] && [ ! -d "$OSRC_HOME/plans/p5/run.lock" ] && ok "stale lock from a dead driver is reclaimed and released" || bad "stale lock rc=$rc: $out"

# 7. time cap -> exit 2 ; dispatch refusal -> failed + wake
mkplan p7b 't1||scout|1'; echo running > "$TMP/outcomes/t1"
# Fake clock: every `date +%s` advances two minutes (a file counter: calls run in subshells).
echo 0 > "$TMP/clock"
out="$( date() { if [ "${1:-}" = +%s ]; then local c; c=$(( $(cat "$TMP/clock") + 1 )); echo "$c" > "$TMP/clock"; echo $(( 1000000 + c * 120 )); else command date "$@"; fi; }
        cmd_plan_run p7b --interval 1 --max-minutes 1 2>&1 )"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q "time cap of 1 minutes reached" && ok "runaway guard: time cap exits 2 with a plain reason" || bad "time cap rc=$rc: $out"
mkplan p8 't1||scout|1'; touch "$TMP/dispatch-refuse-t1"
out="$( cmd_plan_run p8 --interval 1 2>&1 )"; rc=$?
[ "$rc" = 3 ] && [ "$(st p8 t1)" = failed ] && printf '%s' "$out" | grep -q "retrying (attempt 1 failed, model or lane problem: the worker did not launch" \
  && printf '%s' "$out" | grep -q "failed for good after 2 attempt" && ok "launch failure is retried within the budget, then fails closed" || bad "dispatch refusal rc=$rc: $out"
rm -f "$TMP/dispatch-refuse-t1"
mkplan p9
out="$( cmd_plan_run p9 --once 2>&1 )"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "has no tasks yet" && ok "empty plan stops with a plain reason" || bad "empty plan rc=$rc: $out"
( cmd_plan_run p9 --max-parallel 0 >/dev/null 2>&1 ); [ $? = 1 ] && ok "bad --max-parallel is refused" || bad "max-parallel 0 accepted"

# 8. auto-land lands done ship tasks once
rm -f "$TMP"/outcomes/* "$TMP/landed"
mkplan pl 't1||ship|1' 't2||scout|1'
( cmd_plan_run pl --interval 1 --auto-land >/dev/null 2>&1 ); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$TMP/landed" 2>/dev/null)" = t1 ] && ok "--auto-land lands the ship task only" || bad "auto-land rc=$rc landed=$(cat "$TMP/landed" 2>/dev/null)"

# ================================================================== flows
FLOWS_DIR="$HERE/../../references/flows"
out="$(cmd_flow ls)"
for f in council-build spec-build best-of-n; do printf '%s' "$out" | grep -q "^$f " || bad "flow ls missing $f"; done
printf '%s' "$out" | grep -q '^council-build *built-in' && ok "flow ls lists the shipped flows" || bad "flow ls: $out"
for f in council-build spec-build best-of-n; do ( _ff_flow_load "$f" >/dev/null 2>&1 ) || bad "shipped flow $f fails validation"; done
ok "shipped flows validate"
out="$(cmd_flow show council-build)"; printf '%s' "$out" | grep -q 'land  lands build' && ok "flow show renders stages" || bad "flow show: $(cmd_flow show council-build)"

# missing required var
out="$( cmd_flow run spec-build --plan fx0 2>&1 )"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "needs --var goal=" && [ ! -d "$OSRC_HOME/plans/fx0" ] && ok "missing required var refused before any plan is made" || bad "missing var rc=$rc: $out"
out="$( cmd_flow run spec-build --plan fx0 --var goal=x --var chek=y 2>&1 )"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "has no variable chek" && ok "unknown var (typo) refused" || bad "unknown var rc=$rc: $out"

# real expansion needs a repo for ship stages
mkdir -p "$TMP/norepo"
out="$( cd "$TMP/norepo" && GIT_CEILING_DIRECTORIES="$TMP" cmd_flow run spec-build --plan fx1 --var goal=add-x 2>&1 )"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "needs a git repo" && ok "code-building flow outside a repo is refused" || bad "no-repo rc=$rc: $out"

out="$( cmd_flow run council-build --plan fx2 --repo "$REPO" --var goal="Add a login page" --var check="make test" 2>&1 )"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "next: .* plan run fx2" && ok "flow run creates tasks and prints the next command" || bad "council run rc=$rc: $out"
L="$(_task_list fx2)"
[ "$(printf '%s' "$L" | jq length)" = 6 ] && ok "council-build expands to 6 tasks" || bad "council count $(printf '%s' "$L" | jq length)"
printf '%s' "$L" | jq -e '.[] | select(.flow.stage == "synthesize") | .deps == ["t1","t2"]' >/dev/null && ok "stage deps translate to tids" || bad "deps map: $(printf '%s' "$L" | jq -c '[.[]|{id,deps}]')"
printf '%s' "$L" | jq -e '.[] | select(.flow.stage == "build") | .check == "make test" and .shape == "ship" and (.prompt | test("Add a login page"))' >/dev/null && ok "vars substituted into prompt and check" || bad "subst: $(printf '%s' "$L" | jq -c '.[3]')"
printf '%s' "$L" | jq -e '.[] | select(.flow.stage == "land") | .land_target == "t4" and (.deps | index("t5")) != null and .gate == false' >/dev/null && ok "land stage targets the build tid after review" || bad "land stage: $(printf '%s' "$L" | jq -c '.[5]')"
printf '%s' "$L" | jq -e '.[] | select(.flow.stage == "review") | .require_verdict == true and .model == "sol"' >/dev/null && ok "review stage requires a verdict on another family" || bad "review: $(printf '%s' "$L" | jq -c '.[4]')"
jq -e '.repo != "" and .goal == "Add a login page"' "$OSRC_HOME/plans/fx2/plan.json" >/dev/null && ok "plan created with repo and goal" || bad "plan.json: $(cat "$OSRC_HOME/plans/fx2/plan.json")"

# exclude list honored when _model_excluded exists
_model_excluded() { case "$1" in sol|opus) return 0 ;; esac; return 1; }
( cmd_flow run council-build --plan fx3 --repo "$REPO" --var goal=g >/dev/null 2>&1 )
L="$(_task_list fx3)"
[ "$(printf '%s' "$L" | jq -r '[.[] | .model] | join(",")')" = "terra,gemini-pro,gemini-pro,glm-5-2,gemini-pro," ] && ok "excluded models skipped, next allowed fallback used" || bad "exclude: $(printf '%s' "$L" | jq -r '[.[]|.model]|join(",")')"
unset -f _model_excluded

# best-of-n with n=3: three candidates on different models, compare depends on all, pick is a hold gate
( cmd_flow run best-of-n --plan fx4 --repo "$REPO" --var goal=g --var n=3 >/dev/null 2>&1 )
L="$(_task_list fx4)"
[ "$(printf '%s' "$L" | jq '[.[] | select(.flow.stage | startswith("candidate-"))] | length')" = 3 ] && ok "best-of-n expands n=3 candidates" || bad "bon count: $(printf '%s' "$L" | jq -c '[.[]|.flow.stage]')"
[ "$(printf '%s' "$L" | jq -r '[.[0:3][] | .model] | join(",")')" = "glm-5-2,swe-1-7,kimi-k3" ] && ok "candidates rotate across models" || bad "bon models"
printf '%s' "$L" | jq -e '.[3].deps == ["t1","t2","t3"] and .[0].title == "Candidate 1 of 3: g"' >/dev/null && ok "compare depends on every candidate; {{i}}/{{n}} substituted" || bad "bon deps: $(printf '%s' "$L" | jq -c '.[3]')"
printf '%s' "$L" | jq -e '.[4].hold_after_deps == true and .[4].state == "todo" and .[4].deps == ["t4"]' >/dev/null && ok "hold stage is a todo with hold_after_deps" || bad "hold stage: $(printf '%s' "$L" | jq -c '.[4]')"
( cmd_flow run best-of-n --plan fx5 --repo "$REPO" --var goal=g --var n=abc >/dev/null 2>&1 ) && bad "non-numeric n accepted" || ok "non-numeric repeat count refused"

# hold stage at run time: after deps -> held + wake; after release -> done with the captain's answer
rm -f "$TMP"/outcomes/*
for t in t1 t2 t3 t4; do _task_update fx4 "$t" '.state = "done"'; done
out="$( cmd_plan_run fx4 --once 2>&1 )"; rc=$?
[ "$rc" = 3 ] && [ "$(st fx4 t5)" = held ] && _task_get fx4 t5 | jq -e '.hold_after_deps == false and .gate == true and (.hold.reason | test("captain"))' >/dev/null \
  && ok "decision gate becomes held once its deps are done" || bad "gate rc=$rc: $out $(_task_get fx4 t5)"
[ "$(twakes fx4 t5 held)" = 1 ] && ok "decision gate -> exactly one wake" || bad "gate wakes: $(twakes fx4 t5 held)"
_task_update fx4 t5 '.state = "todo" | .hold.answer = "t2"'
( cmd_plan_run fx4 --once >/dev/null 2>&1 ); rc=$?
[ "$rc" = 0 ] && _task_get fx4 t5 | jq -e '.state == "done" and .result == "t2"' >/dev/null && ok "released gate completes with the captain's answer" || bad "release rc=$rc $(_task_get fx4 t5)"

# verdict gate: FAIL -> held; PASS -> done ; land stage lands its target
rm -f "$TMP/landed"
for t in t1 t2 t3 t4; do _task_update fx2 "$t" '.state = "done"'; done
echo "VERDICT: FAIL - skipped the tests" > "$TMP/lasttxt-t5"
( cmd_plan_run fx2 --interval 1 >/dev/null 2>&1 ); rc=$?
[ "$rc" = 3 ] && [ "$(st fx2 t5)" = held ] && [ "$(st fx2 t6)" = todo ] && ok "reviewer FAIL holds the review and blocks landing" || bad "verdict fail rc=$rc t5=$(st fx2 t5)"
_task_update fx2 t5 '.state = "todo" | .jobs = []'
echo "VERDICT: PASS" > "$TMP/lasttxt-t5"
( cmd_plan_run fx2 --interval 1 >/dev/null 2>&1 ); rc=$?
[ "$rc" = 0 ] && [ "$(st fx2 t6)" = done ] && [ "$(cat "$TMP/landed" 2>/dev/null)" = t4 ] && ok "reviewer PASS -> land stage lands the build" || bad "verdict pass rc=$rc t6=$(st fx2 t6) landed=$(cat "$TMP/landed" 2>/dev/null)"

# user flow overrides built-in by name
mkdir -p "$OSRC_HOME/flows"
cat > "$OSRC_HOME/flows/spec-build.json" <<'EOF'
{"name":"spec-build","description":"my override","vars":{"goal":"required"},
 "stages":[{"id":"only","title":"just {{goal}}","shape":"scout","verb":"research","model":"opus","prompt":"think about {{goal}}"}]}
EOF
out="$(cmd_flow ls)"; printf '%s\n' "$out" | grep -q '^spec-build *yours *my override' && ok "user flow overrides built-in in ls" || bad "override ls: $(cmd_flow ls)"
( cmd_flow run spec-build --plan fx6 --var goal=z >/dev/null 2>&1 )
[ "$(_task_list fx6 | jq length)" = 1 ] && ok "user flow overrides built-in in run (no repo needed for scouts)" || bad "override run"

# injection-safe substitution: quotes, $( ), backticks, {{other}} in values stay literal text
EVIL='he said "hi" '"'"'q'"'"' $(touch '"$TMP"'/pwned1) `touch '"$TMP"'/pwned2` {{goal}} \(.x)'
( cmd_flow run spec-build --plan fx7 --var goal="$EVIL" >/dev/null 2>&1 )
got="$(_task_get fx7 t1 | jq -r .prompt)"
[ "$got" = "think about $EVIL" ] && [ ! -e "$TMP/pwned1" ] && [ ! -e "$TMP/pwned2" ] && ok "var values are inserted literally, never executed or re-expanded" || bad "injection: got [$got]"
cat > "$OSRC_HOME/flows/badref.json" <<'EOF'
{"name":"badref","vars":{"goal":"required"},"stages":[{"id":"a","prompt":"{{goal}} {{nope}}"}]}
EOF
out="$( cmd_flow run badref --plan fx8 --var goal=x 2>&1 )"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "uses {{nope}} but does not declare it" && ok "undeclared placeholder refused" || bad "badref rc=$rc: $out"
cat > "$OSRC_HOME/flows/cyc.json" <<'EOF'
{"name":"cyc","stages":[{"id":"a","prompt":"x","deps":["b"]},{"id":"b","prompt":"y"}]}
EOF
out="$( cmd_flow run cyc 2>&1 )"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "depends on b, which is not an earlier stage" && ok "forward/cyclic deps refused" || bad "cyc rc=$rc: $out"
( cmd_flow run '../etc/passwd' >/dev/null 2>&1 ) && bad "path-like flow name accepted" || ok "path-like flow names refused"
out="$( cmd_flow run council-build --plan fx9 --var goal=g --dry-run 2>&1 )"; rc=$?
[ "$rc" = 0 ] && [ ! -d "$OSRC_HOME/plans/fx9" ] && printf '%s' "$out" | grep -q "land  lands build" && ok "--dry-run previews without writing" || bad "dry-run rc=$rc: $out"

# bearings hook: one line per active plan
out="$(_factory_plans_digest)"
printf '%s' "$out" | grep -q '^plan p3: 1 need you' && ! printf '%s' "$out" | grep -q '^plan p1:' && ok "digest shows active plans, skips finished ones" || bad "digest: $out"


# ================================================================== review-3 hardening (one block per finding)
rm -f "$TMP"/outcomes/* "$TMP/landed" "$TMP/launches"
launches() { grep -c "^$1\$" "$TMP/launches" 2>/dev/null | tr -d ' '; }
setlt() { printf '%s\n' "$3" > "$TMP/lasttxt-$1-$2-${4:-1}"; }   # <plan> <tid> <text> [attempt]

# --- 1. claim window: running + no job yet is a launch in flight, never a second dispatch
mkplan c1 't1||scout|1'
echo 3 > "$TMP/slow-c1-t1"
( _task_dispatch c1 t1 >/dev/null 2>&1 ) & DPID=$!
sleep 1
out="$( cmd_plan_run c1 --once 2>&1 )"
wait "$DPID"
rm -f "$TMP/slow-c1-t1"
[ "$(launches c1/t1)" = 1 ] && printf '%s' "$out" | grep -q "t1: still launching" && ok "reconcile leaves a task mid-launch alone (no double dispatch)" || bad "double dispatch: launches=$(launches c1/t1) $out"
( cmd_plan_run c1 --interval 1 >/dev/null 2>&1 )
[ "$(st c1 t1)" = done ] && [ "$(_task_get c1 t1 | jq '.jobs | length')" = 1 ] && ok "the in-flight launch is the one that finishes" || bad "claim window: $(_task_get c1 t1)"
# launcher died after launching (job carries task_ref, task never recorded it): the job is adopted
mkplan c2 't1||scout|1'
_task_update c2 t1 '.state = "running" | .attempts = 1 | .claimed_at = "2000-01-01T00:00:00Z"' >/dev/null
J2="20000101-000000-orphan$RANDOM"; mkdir -p "$OSRC_JOBS/$J2"; echo done > "$OSRC_JOBS/$J2/status"; echo "c1 adopted" > "$OSRC_JOBS/$J2/last.txt"
echo "c2/t1" > "$OSRC_JOBS/$J2/task_ref"
out="$( cmd_plan_run c2 --once 2>&1 )"
[ "$(st c2 t1)" = done ] && [ "$(_task_get c2 t1 | jq -r .job)" = "$J2" ] && [ "$(launches c2/t1)" = 0 ] && ok "an orphaned launch is recovered from its task_ref, not relaunched" || bad "orphan recovery: $out $(_task_get c2 t1)"
# claimed long ago, no job anywhere: a failed attempt (retried), never stuck forever
mkplan c3 't1||scout|1'
_task_update c3 t1 '.state = "running" | .attempts = 1 | .claimed_at = "2000-01-01T00:00:00Z"' >/dev/null
out="$( cmd_plan_run c3 --interval 1 2>&1 )"; rc=$?
[ "$rc" = 0 ] && [ "$(st c3 t1)" = done ] && printf '%s' "$out" | grep -q "never launched" && ok "a claim with no job after the grace window is retried" || bad "stale claim rc=$rc: $out"

# --- 2 + 14. run lock: steal guard, unwritable owner, distinct busy code
mkplan l1 't1||scout|1'; echo running > "$TMP/outcomes/t1"
mkdir -p "$OSRC_HOME/plans/l1/run.lock"; echo "99999 Mon Jan  1 00:00:00 2001" > "$OSRC_HOME/plans/l1/run.lock/owner"
eval "_saved_pid_identity() $(declare -f _pid_start_identity | tail -n +2)"
( _pid_start_identity() { if [ "${1:-}" = 99999 ] && [ ! -f "$TMP/b-slept" ]; then touch "$TMP/b-slept"; sleep 2; fi; _saved_pid_identity "$@"; }
  cmd_plan_run l1 --interval 1 --max-minutes 1 > "$TMP/B.out" 2>&1 ) & BPID=$!
sleep 0.5
( cmd_plan_run l1 --interval 30 --max-minutes 1 > "$TMP/A.out" 2>&1 ) & APID=$!
sleep 4
na="$(grep -c 'tick' "$TMP/A.out")"; nb="$(grep -c 'tick' "$TMP/B.out")"
wait "$BPID" 2>/dev/null; echo $? > "$TMP/B.rc"
[ "$(cat "$TMP/B.rc" 2>/dev/null)" = 4 ] && [ "$na" -ge 1 ] && [ "$nb" = 0 ] && ok "a slow stale-lock stealer never deletes a fresh lock (one driver only)" || bad "two drivers: A ticks=$na B ticks=$nb B rc=$(cat "$TMP/B.rc" 2>/dev/null)"
# --- 15. SIGTERM interrupts the sleep at once and releases the lock
t_term=$(date +%s); kill -TERM "$APID" 2>/dev/null; wait "$APID" 2>/dev/null; echo $? > "$TMP/A.rc"; t_term=$(( $(date +%s) - t_term ))
[ "$(cat "$TMP/A.rc" 2>/dev/null)" = 143 ] && [ "$t_term" -le 2 ] && [ ! -d "$OSRC_HOME/plans/l1/run.lock" ] && ok "SIGTERM stops plan run within a second and frees the lock" || bad "TERM rc=$(cat "$TMP/A.rc" 2>/dev/null) took ${t_term}s lock=$(ls -d "$OSRC_HOME/plans/l1/run.lock" 2>/dev/null)"
out="$( mv() { return 1; }; cmd_plan_run l1 --once 2>&1 )"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "could not record this run as the lock owner" && [ ! -d "$OSRC_HOME/plans/l1/run.lock" ] && ok "a lock whose owner cannot be written is not kept" || bad "owner write failure rc=$rc: $out"
out="$( trap 'echo caller-int' INT; trap 'echo caller-term' TERM; cmd_plan_run l1 --once >/dev/null 2>&1; trap -p INT; trap -p TERM )"
printf '%s' "$out" | grep -q "caller-int" && printf '%s' "$out" | grep -q "caller-term" && ok "the caller's INT/TERM traps are put back" || bad "caller traps lost: $out"
for j in $(_task_list l1 | jq -r '.[] | .job | select(. != "")'); do echo done > "$OSRC_JOBS/$j/status"; done; rm -f "$TMP/outcomes/t1"

# --- 3. a worker started by hand on a decision gate or land step never completes it
( cmd_flow run best-of-n --plan g1 --repo "$REPO" --var goal=g --var n=2 >/dev/null 2>&1 )
for t in t1 t2 t3; do _task_update g1 "$t" '.state = "done"' >/dev/null; done
if ( _task_dispatch g1 t4 >/dev/null 2>&1 ); then
  out="$( cmd_plan_run g1 --once 2>&1 )"
  [ "$(st g1 t4)" = held ] && ok "a gate started by hand is held, not marked done by its worker" || bad "manual gate start: $(_task_get g1 t4 | jq -c '{state,result}')"
else
  [ "$(st g1 t4)" = todo ] && ok "the task store refuses to start a captain's decision by hand" || bad "gate refusal left $(st g1 t4)"
fi
# whatever the store allows, a gate found running with a worker job is held by the scheduler
mkplan g2 't1||scout|1'
_task_update g2 t1 '.state = "running" | .gate = true | .job = "fakejob" | .jobs = ["fakejob"]' >/dev/null
mkdir -p "$OSRC_JOBS/fakejob"; echo done > "$OSRC_JOBS/fakejob/status"; echo "VERDICT: PASS" > "$OSRC_JOBS/fakejob/last.txt"
( cmd_plan_run g2 --once >/dev/null 2>&1 )
_task_get g2 t1 | jq -e '.state == "held" and (.hold.reason | test("started by hand")) and (.hold.reason | test("task release t1 --answer"))' >/dev/null \
  && ok "a gate running a worker is held for the captain (worker output ignored)" || bad "gate worker: $(_task_get g2 t1 | jq -c '{state,hold}')"
_task_update g2 t1 '.state = "running" | .gate = false | .land_target = "t9"' >/dev/null
( cmd_plan_run g2 --once >/dev/null 2>&1 )
[ "$(st g2 t1)" = held ] && ok "a land step running a worker is held too" || bad "land worker: $(st g2 t1)"

# --- 4. --auto-land never lands a flow's builds before their review / compare / pick
rm -f "$TMP/landed"
( cmd_flow run best-of-n --plan a1 --repo "$REPO" --var goal=g --var n=3 >/dev/null 2>&1 )
out="$( cmd_plan_run a1 --interval 1 --auto-land 2>&1 )"; rc=$?
[ ! -s "$TMP/landed" ] && [ "$rc" = 3 ] && [ "$(st a1 t5)" = held ] && ok "--auto-land leaves best-of-n candidates for the captain's pick" || bad "auto-land flow: rc=$rc landed=$(cat "$TMP/landed" 2>/dev/null) $out"
_task_get a1 t5 | jq -e '.hold.reason | test("land the winner: outsourcerer land <tid> --plan a1")' >/dev/null && ok "the pick names how to land the winner" || bad "pick hint: $(_task_get a1 t5 | jq -r .hold.reason)"
rm -f "$TMP/landed"
( cmd_flow run council-build --plan a2 --repo "$REPO" --var goal=g >/dev/null 2>&1 )
setlt a2 t5 "VERDICT: PASS"
out="$( cmd_plan_run a2 --interval 1 --auto-land 2>&1 )"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$TMP/landed" 2>/dev/null)" = t4 ] \
  && ok "with a flow land stage the build lands once, after its review" || bad "council auto-land rc=$rc landed=$(cat "$TMP/landed" 2>/dev/null): $out"

# --- 5. reviewer FAIL: automatic redo of the reviewed build, then a fresh review
rm -f "$TMP/landed"
( cmd_flow run council-build --plan v1 --repo "$REPO" --var goal=g >/dev/null 2>&1 )
for t in t1 t2 t3; do _task_update v1 "$t" '.state = "done"' >/dev/null; done
setlt v1 t5 "VERDICT: FAIL - the tests were skipped" 1; setlt v1 t5 "VERDICT: PASS" 2
out="$( cmd_plan_run v1 --interval 1 2>&1 )"; rc=$?
[ "$rc" = 0 ] && [ "$(st v1 t6)" = done ] && [ "$(cat "$TMP/landed" 2>/dev/null)" = t4 ] && [ "$(cat "$TMP/count-v1-t4")" = 2 ] \
  && ok "reviewer FAIL sends the build back once, the re-review passes, then it lands" || bad "redo path rc=$rc: $out"
grep -q "Review of your previous attempt" "$TMP/brief-v1-t4-2" && grep -q "the tests were skipped" "$TMP/brief-v1-t4-2" \
  && ok "the redo brief carries the reviewer's reason" || bad "redo brief: $(cat "$TMP/brief-v1-t4-2" 2>/dev/null)"
grep -q "Earlier review" "$TMP/brief-v1-t5-2" && ! grep -q "did not finish" "$TMP/brief-v1-t5-2" \
  && ok "the re-review brief says why it runs again (no 'did not finish')" || bad "re-review brief: $(cat "$TMP/brief-v1-t5-2" 2>/dev/null)"
[ "$(grep -c 'Review of your previous attempt' <<<"$(_task_get v1 t4 | jq -r .prompt)")" = 1 ] && ok "review notes replace, never pile up" || bad "notes piled"
# budget used up -> held with exact commands; captain's extra round works
rm -f "$TMP/landed"
( cmd_flow run council-build --plan v2 --repo "$REPO" --var goal=g >/dev/null 2>&1 )
for t in t1 t2 t3; do _task_update v2 "$t" '.state = "done"' >/dev/null; done
echo "VERDICT: FAIL - still broken" > "$TMP/lasttxt-t5"; setlt v2 t5 "VERDICT: FAIL - second reason" 2
out="$( cmd_plan_run v2 --interval 1 2>&1 )"; rc=$?
_task_get v2 t5 | jq -e '(.hold.reason | test("second reason")) and (.hold.reason | test("still broken") | not)' >/dev/null && ok "the hold quotes the latest FAIL reason" || bad "stale reason: $(_task_get v2 t5 | jq -r .hold.reason)"
_task_get v2 t5 | jq -e '.state == "held" and (.hold.reason | test("task done t5 --force --plan v2")) and (.hold.reason | test("task release t5 --answer"))' >/dev/null \
  && [ "$rc" = 3 ] && [ "$(cat "$TMP/count-v2-t4")" = 2 ] && ok "redo budget used up -> reviewer held with the exact commands" || bad "budget hold rc=$rc t4 runs=$(cat "$TMP/count-v2-t4") $(_task_get v2 t5 | jq -c '{state,hold}')"
rm -f "$TMP/lasttxt-t5"; setlt v2 t5 "VERDICT: PASS" 3
( cmd_task release t5 --plan v2 --answer "use the real fixtures" >/dev/null 2>&1 )
out="$( cmd_plan_run v2 --interval 1 2>&1 )"; rc=$?
[ "$rc" = 0 ] && grep -q "use the real fixtures" "$TMP/brief-v2-t4-3" && [ "$(cat "$TMP/landed" 2>/dev/null)" = t4 ] \
  && ok "releasing a failed review with an answer redoes the build with the captain's note" || bad "captain redo rc=$rc: $out"
# accepting a failed review by hand unblocks the land stage
( cmd_flow run council-build --plan v3 --repo "$REPO" --var goal=g >/dev/null 2>&1 )
for t in t1 t2 t3; do _task_update v3 "$t" '.state = "done"' >/dev/null; done
_task_update v3 t4 '.retries = 0' >/dev/null; setlt v3 t5 "VERDICT: FAIL - nit"
( cmd_plan_run v3 --interval 1 >/dev/null 2>&1 )
( cmd_task done t5 --force --plan v3 >/dev/null 2>&1 ); rm -f "$TMP/landed"
( cmd_plan_run v3 --interval 1 >/dev/null 2>&1 ); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$TMP/landed" 2>/dev/null)" = t4 ] && ok "'task done --force' on the held review accepts the build and it lands" || bad "accept path rc=$rc t5=$(st v3 t5)"

# --- 6. strict verdicts: anything but an exact last line is held, never passed
vcase() {   # <plan> <expect done|held> <label> <text...>
  local p="$1" want="$2" label="$3"; shift 3
  mkplan "$p" 't1||scout|0'; _task_update "$p" t1 '.require_verdict = true' >/dev/null
  printf '%s\n' "$@" > "$TMP/lasttxt-$p-t1-1"
  ( cmd_plan_run "$p" --interval 1 >/dev/null 2>&1 )
  [ "$(st "$p" t1)" = "$want" ] && ok "verdict: $label -> $want" || bad "verdict: $label -> $(st "$p" t1) (want $want)"
}
vcase vd1 done "exact PASS" "looks good" "VERDICT: PASS"
vcase vd2 done "PASS with a reason" "VERDICT: PASS - all acceptance tests pass"
vcase vd3 held "fenced PASS after FAIL" "VERDICT: FAIL - broken" '```' "VERDICT: PASS" '```'
vcase vd4 held "blockquoted PASS" "> VERDICT: PASS"
vcase vd5 held "template echo" "VERDICT: PASS or VERDICT: FAIL"
vcase vd6 held "PASSED? no" "VERDICT: PASSED? no"
vcase vd7 held "bold PASS" "**VERDICT: PASS**"
vcase vd8 held "PASS after an earlier FAIL" "VERDICT: FAIL - x" "VERDICT: PASS"
vcase vd9 held "PASS not on the last line" "VERDICT: PASS" "thanks!"
vcase vd10 held "PASS that mentions FAIL" "VERDICT: PASS - but FAIL on windows"
mkplan vd11 't1||scout|0'; _task_update vd11 t1 '.require_verdict = true' >/dev/null
touch "$TMP/nolast-t1"; printf 'VERDICT: PASS\n' > "$TMP/lasttxt-vd11-t1-1"
( cmd_plan_run vd11 --interval 1 >/dev/null 2>&1 ); rm -f "$TMP/nolast-t1"
[ "$(st vd11 t1)" != done ] && ok "verdict: a PASS only in out.log is never trusted" || bad "verdict from out.log accepted"
_task_get vd3 t1 | jq -e '.hold.reason | test("exactly .VERDICT: PASS.")' >/dev/null && ok "a held reviewer is told the exact verdict form" || bad "verdict hint: $(_task_get vd3 t1 | jq -r .hold.reason)"

# --- 7. malformed flows fail closed (nothing written)
mflow() {   # <name> <expected-error-regex> <json>
  printf '%s\n' "$3" > "$OSRC_HOME/flows/$1.json"
  local o r; o="$( cmd_flow run "$1" --plan "mf-$1" --repo "$REPO" 2>&1 )"; r=$?
  [ "$r" != 0 ] && printf '%s' "$o" | grep -qE "$2" && [ ! -d "$OSRC_HOME/plans/mf-$1" ] && ok "malformed flow refused: $1" || bad "malformed flow $1 rc=$r: $o"
}
mflow num 'stage 1 is not an object' '{"name":"num","stages":[1]}'
mflow depstr 'deps must be a list' '{"name":"depstr","stages":[{"id":"a","prompt":"x"},{"id":"b","prompt":"y","deps":"a"}]}'
mflow varsarr 'vars must be an object' '{"name":"varsarr","vars":[],"stages":[{"id":"a","prompt":"x"}]}'
mflow promptnum 'prompt must be text' '{"name":"promptnum","stages":[{"id":"a","prompt":5}]}'
mflow landrep 'which repeats' '{"name":"landrep","stages":[{"id":"c","shape":"ship","prompt":"x","repeat":"2"},{"id":"l","land":"c","deps":["c"]}]}'
mflow landscout 'not a build' '{"name":"landscout","stages":[{"id":"c","prompt":"x"},{"id":"l","land":"c"}]}'
mflow gateverdict 'no output to review' '{"name":"gateverdict","stages":[{"id":"a","prompt":"x"},{"id":"g","hold":true,"verdict":true,"deps":["a"]}]}'
mflow landtwice 'landed by more than one stage' '{"name":"landtwice","stages":[{"id":"c","shape":"ship","prompt":"x"},{"id":"l","land":"c"},{"id":"m","land":"c"}]}'
mflow notobj 'one JSON object' '[1,2]'

# --- 8. flow run is all or nothing
eval "_real_task_new() $(declare -f _task_new | tail -n +2)"
( _task_new() { if [ "$(ls "$OSRC_HOME/plans/$1/tasks" 2>/dev/null | grep -c '\.json$')" -ge 2 ]; then return 1; fi; _real_task_new "$@"; }
  cmd_flow run council-build --plan at1 --repo "$REPO" --var goal=g >/dev/null 2>&1 ); rc=$?
[ "$rc" != 0 ] && [ "$(_task_list at1 | jq length)" = 0 ] && ok "a flow run that fails mid-way removes its tasks and preserves the plan" || bad "partial new plan left: rc=$rc $(ls "$OSRC_HOME/plans/at1/tasks" 2>/dev/null)"
mkplan at2 't1||scout|1'
( _task_new() { if [ "$(ls "$OSRC_HOME/plans/$1/tasks" 2>/dev/null | grep -c '\.json$')" -ge 3 ]; then return 1; fi; _real_task_new "$@"; }
  cmd_flow run council-build --plan at2 --repo "$REPO" --var goal=g >/dev/null 2>&1 ); rc=$?
[ "$rc" != 0 ] && [ "$(_task_list at2 | jq length)" = 1 ] && ok "a flow run that fails mid-way on an existing plan removes only what it added" || bad "partial existing plan: $(_task_list at2 | jq -c '[.[].id]')"

# --- 9. fallbacks are stored and re-picked at dispatch and retry
cat > "$OSRC_HOME/flows/fb.json" <<'EOF'
{"name":"fb","stages":[{"id":"a","prompt":"x","model":"aaa","fallback":["bbb","ccc"],"retries":2}]}
EOF
( cmd_flow run fb --plan fb1 >/dev/null 2>&1 )
_task_get fb1 t1 | jq -e '.model == "aaa" and .fallback == ["aaa","bbb","ccc"]' >/dev/null && ok "flow tasks keep their fallback models" || bad "fallback stored: $(_task_get fb1 t1 | jq -c '{model,fallback}')"
_model_excluded() { [ "$1" = aaa ]; }
printf 'failed\ndone\n' > "$TMP/outcomes/t1"; : > "$TMP/models"
( cmd_plan_run fb1 --interval 1 >/dev/null 2>&1 )
[ "$(grep '^fb1/t1 ' "$TMP/models" | awk '{print $2}' | tr '\n' ',')" = "bbb,ccc," ] && ok "a model excluded after flow run is skipped; a retry moves to the next fallback" || bad "repick: $(cat "$TMP/models")"
_model_excluded() { [ "$1" = glm-5-2 ]; }
( cmd_flow run best-of-n --plan fb2 --repo "$REPO" --var goal=g --var n=3 >/dev/null 2>&1 )
[ "$(_task_list fb2 | jq -r '[.[0:3][] | .model] | unique | length')" = 3 ] && ok "excluding one model never collapses candidates onto one model" || bad "collapse: $(_task_list fb2 | jq -c '[.[0:3][]|.model]')"
rm -f "$TMP/outcomes/t1"
mkplan fb3 't1||scout|1'; _task_update fb3 t1 '.model = "zzz"' >/dev/null
_model_excluded() { [ "$1" = zzz ]; }; : > "$TMP/models"
( cmd_plan_run fb3 --interval 1 >/dev/null 2>&1 )
[ "$(cat "$TMP/models")" = "fb3/t1 none" ] && ok "an excluded model with no fallbacks is left to the router" || bad "no-fallback exclude: $(cat "$TMP/models")"
unset -f _model_excluded; rm -f "$TMP/outcomes/t1"

# --- 10. a failed auto-land keeps the build done and calls the captain
mkplan al1 't1||ship|1'; touch "$TMP/landfail-t1"
out="$( cmd_plan_run al1 --interval 1 --auto-land 2>&1 )"; rc=$?
rm -f "$TMP/landfail-t1"
_task_get al1 t1 | jq -e '.state == "done" and (.land_error | test("merge breaks check"))' >/dev/null && [ "$rc" = 3 ] \
  && printf '%s' "$out" | grep -q "landing failed: t1 (outsourcerer land t1 --plan al1)" && [ "$(wakes 'factory-land-failed')" -ge 1 ] \
  && ok "failed auto-land: build stays done, captain gets the land command" || bad "auto-land failure rc=$rc: $out $(_task_get al1 t1 | jq -c '{state,land_error}')"

# --- 11. land stage: crash recovery is counted; a failed land is held, and release lands again
( cmd_flow run council-build --plan ls1 --repo "$REPO" --var goal=g >/dev/null 2>&1 )
for t in t1 t2 t3 t4 t5; do _task_update ls1 "$t" '.state = "done"' >/dev/null; done
_task_update ls1 t6 '.state = "running" | .land_attempts = 1' >/dev/null; rm -f "$TMP/landed"
( cmd_plan_run ls1 --once >/dev/null 2>&1 )
[ "$(st ls1 t6)" = done ] && [ "$(cat "$TMP/landed")" = t4 ] && ok "an interrupted land is tried again" || bad "land recovery: $(st ls1 t6)"
( cmd_flow run council-build --plan ls2 --repo "$REPO" --var goal=g >/dev/null 2>&1 )
for t in t1 t2 t3 t4 t5; do _task_update ls2 "$t" '.state = "done"' >/dev/null; done
_task_update ls2 t6 '.state = "running" | .land_attempts = 2' >/dev/null
( cmd_plan_run ls2 --once >/dev/null 2>&1 )
[ "$(st ls2 t6)" = held ] && ok "a land interrupted too often is held, not relaunched forever" || bad "land loop: $(st ls2 t6)"
( cmd_flow run council-build --plan ls3 --repo "$REPO" --var goal=g >/dev/null 2>&1 )
for t in t1 t2 t3 t4 t5; do _task_update ls3 "$t" '.state = "done"' >/dev/null; done
touch "$TMP/landfail-t4"; rm -f "$TMP/landed"
( cmd_plan_run ls3 --once >/dev/null 2>&1 )
_task_get ls3 t6 | jq -e '.state == "held" and (.hold.reason | test("task release t6 --answer"))' >/dev/null && [ "$(st ls3 t4)" = done ] \
  && ok "a failed land stage is held with the exact commands; the build stays done" || bad "land fail: $(_task_get ls3 t6 | jq -c '{state,hold}') t4=$(st ls3 t4)"
rm -f "$TMP/landfail-t4"; ( cmd_task release t6 --plan ls3 --answer "land again" >/dev/null 2>&1 )
( cmd_plan_run ls3 --once >/dev/null 2>&1 ); rc=$?
[ "$rc" = 0 ] && [ "$(st ls3 t6)" = done ] && ok "releasing the land stage lands again" || bad "land release rc=$rc t6=$(st ls3 t6)"

# --- 12. a job that never got a worker cannot wait forever
mkplan sj 't1||scout|0'
J3="20000101-000000-nostatus$RANDOM"; mkdir -p "$OSRC_JOBS/$J3"; echo $(( $(date +%s) - 100 )) > "$OSRC_JOBS/$J3/started_at"
_task_update sj t1 '.state = "running" | .attempts = 1 | .job = $j | .jobs = [$j]' --arg j "$J3" >/dev/null
out="$( OSRC_FACTORY_JOB_STALE_SECS=5 cmd_plan_run sj --once 2>&1 )"; rc=$?
[ "$(st sj t1)" = failed ] && _task_get sj t1 | jq -e '.result | test("never got a worker")' >/dev/null && ok "a job with no status and no process fails after the stale window" || bad "stale job: $out"

# --- 16. the time cap is checked before starting more work
mkplan tc 't1||scout|1'; rm -f "$TMP/count-tc-t1"
echo 0 > "$TMP/clock"
out="$( date() { if [ "${1:-}" = +%s ]; then local c; c=$(( $(cat "$TMP/clock") + 1 )); echo "$c" > "$TMP/clock"; echo $(( 1000000 + c * 120 )); else command date "$@"; fi; }
        cmd_plan_run tc --interval 1 --max-minutes 1 2>&1 )"; rc=$?
[ "$rc" = 2 ] && [ ! -f "$TMP/count-tc-t1" ] && ok "past the time cap, no new work starts" || bad "time cap overshoot rc=$rc launched=$(cat "$TMP/count-tc-t1" 2>/dev/null)"

# --- 18. flow runs without --plan never share a plan; --repo must match an existing plan
fixdate() { if [ "${1:-}" = "+%Y%m%d-%H%M%S" ]; then echo 20990101-000000; else command date "$@"; fi; }
o1="$( date() { fixdate "$@"; }; cd "$REPO" && cmd_flow run council-build --var goal=one 2>&1 )"; o2="$( date() { fixdate "$@"; }; cd "$REPO" && cmd_flow run council-build --var goal=two 2>&1 )"
p1="$(printf '%s' "$o1" | sed -n 's/^flow council-build added .* to plan \(.*\):$/\1/p')"; p2="$(printf '%s' "$o2" | sed -n 's/^flow council-build added .* to plan \(.*\):$/\1/p')"
[ -n "$p1" ] && [ -n "$p2" ] && [ "$p1" != "$p2" ] && [ "$(_task_list "$p2" | jq length)" = 6 ] && ok "two quick flow runs get two plans ($p1, $p2)" || bad "plan collision: [$p1] [$p2]"
mkdir -p "$TMP/repo2"; git -C "$TMP/repo2" init -q; git -C "$TMP/repo2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
out="$( cmd_flow run council-build --plan fx2 --repo "$TMP/repo2" --var goal=g 2>&1 )"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "plan fx2 works in" && ok "a --repo that is not the plan's repo is refused" || bad "repo mismatch rc=$rc: $out"

# --- 19. messages name the exact next command
mkplan mg 't1||scout|0'; echo blocked > "$TMP/outcomes/t1"
out="$( cmd_plan_run mg --interval 1 2>&1 )"; rm -f "$TMP/outcomes/t1"
_task_get mg t1 | jq -e '.hold.reason | test("outsourcerer task release t1 --answer .* --plan mg")' >/dev/null \
  && printf '%s' "$out" | grep -q 'held: t1 (outsourcerer task release t1 --answer "..." --plan mg)' && ok "blocked worker hold and stop line name the release command" || bad "messages: $out"

# --- 20. the fleet digest reads all plans in one pass
n_before="$(ls -d "$OSRC_HOME"/plans/*/ | wc -l | tr -d ' ')"
: > "$TMP/jqcalls"
out="$( jq() { echo x >> "$TMP/jqcalls"; command jq "$@"; }; _factory_plans_digest )"
[ "$(wc -l < "$TMP/jqcalls" | tr -d ' ')" -le 2 ] && printf '%s' "$out" | grep -q '^plan p3: 1 need you' && ok "digest: one jq pass for $n_before plans" || bad "digest jq calls: $(wc -l < "$TMP/jqcalls") $out"

# --- 21. a released gate's dependents start in the same pass
cat > "$OSRC_HOME/flows/gt.json" <<'EOF'
{"name":"gt","stages":[{"id":"a","prompt":"x"},{"id":"g","hold":true,"deps":["a"]},{"id":"b","prompt":"after the gate","deps":["g"]}]}
EOF
( cmd_flow run gt --plan gt1 >/dev/null 2>&1 ); _task_update gt1 t1 '.state = "done"' >/dev/null
( cmd_plan_run gt1 --once >/dev/null 2>&1 )
( cmd_task release t2 --plan gt1 --answer "go" >/dev/null 2>&1 ); echo running > "$TMP/outcomes/t3"
( cmd_plan_run gt1 --once >/dev/null 2>&1 )
[ "$(st gt1 t2)" = done ] && [ "$(st gt1 t3)" = running ] && ok "after a gate is decided its dependents start in the same pass" || bad "gate dependents waited: t2=$(st gt1 t2) t3=$(st gt1 t3)"
for j in $(_task_list gt1 | jq -r '.[] | .job | select(. != "")'); do echo done > "$OSRC_JOBS/$j/status"; done; rm -f "$TMP/outcomes/t3"
mkplan gt2 't1||scout|1'; _task_update gt2 t1 '.gate = true | .state = "todo"' >/dev/null
( cmd_plan_run gt2 --once >/dev/null 2>&1 )
[ "$(st gt2 t1)" = held ] && ok "a gate with no answer is never marked done" || bad "unanswered gate: $(st gt2 t1)"

# --- 22. a task someone else is checking is not checked (or landed) twice
mkplan cc 't1||ship|1'
sleep 60 & CHK=$!; SLEEPERS="$SLEEPERS $CHK"
J4="20000101-000000-chk$RANDOM"; mkdir -p "$OSRC_JOBS/$J4"; echo done > "$OSRC_JOBS/$J4/status"; echo ok > "$OSRC_JOBS/$J4/last.txt"
_task_update cc t1 '.state = "verifying" | .job = $j | .jobs = [$j] | .verifying_pid = $p | .verifying_at = $now' --argjson now "$(date +%s)" --arg j "$J4" --arg p "$CHK" >/dev/null
: > "$TMP/donechecks"; rm -f "$TMP/landed"
( cmd_plan_run cc --once --auto-land >/dev/null 2>&1 )
[ ! -s "$TMP/donechecks" ] && [ ! -s "$TMP/landed" ] && [ "$(st cc t1)" = verifying ] && ok "a live checker's task is left alone" || bad "double check: $(cat "$TMP/donechecks") $(st cc t1)"
kill "$CHK" 2>/dev/null; wait "$CHK" 2>/dev/null
( cmd_plan_run cc --once --auto-land >/dev/null 2>&1 )
[ "$(grep -c . "$TMP/donechecks")" = 1 ] && [ "$(st cc t1)" = done ] && [ "$(cat "$TMP/landed")" = t1 ] && ok "a dead checker's task is taken over once and landed once" || bad "takeover: checks=$(grep -c . "$TMP/donechecks") $(st cc t1)"

# --- 23. huge --var values never hit the argument size limit
# 2 x SZ in one argument breaks the old code: over macOS's 1MB total at 600KB, over Linux's 128KB
# per-argument cap at 100KB (each single value still has to fit the task store's own arguments).
SZ=100000; [ "$(uname -s)" = Darwin ] && SZ=600000
BIG1="$(head -c "$SZ" /dev/zero | tr '\0' 'a')"; BIG2="$(head -c "$SZ" /dev/zero | tr '\0' 'b')"
cat > "$OSRC_HOME/flows/big.json" <<'EOF'
{"name":"big","vars":{"x":"required","y":"required"},"stages":[{"id":"a","prompt":"{{x}}"},{"id":"b","prompt":"{{y}}","deps":["a"]}]}
EOF
out="$( cmd_flow run big --plan big1 --var "x=$BIG1" --var "y=$BIG2" 2>&1 )"; rc=$?
[ "$rc" = 0 ] && [ "$(_task_get big1 t1 | jq -r '.prompt | length')" = "$SZ" ] && [ "$(_task_get big1 t2 | jq -r '.prompt | length')" = "$SZ" ] \
  && ok "two ${SZ}-byte vars expand without hitting the argument limit" || bad "big vars rc=$rc: $(printf '%s' "$out" | tail -2 | cut -c1-200)"


# --- land --setup (H's land): a flow var / task field / plan run default reaches land
_land_usage() { echo "usage: land ... [--setup CMD]"; }
rm -f "$TMP/landargs"
( cmd_flow run council-build --plan su1 --repo "$REPO" --var goal=g --var setup="npm ci" >/dev/null 2>&1 )
for t in t1 t2 t3 t4 t5; do _task_update su1 "$t" '.state = "done"' >/dev/null; done
( cmd_plan_run su1 --once >/dev/null 2>&1 )
grep -q -- "^t4 --plan su1 --setup npm ci$" "$TMP/landargs" && ok "a flow's setup var reaches land --setup" || bad "setup var: $(cat "$TMP/landargs" 2>/dev/null)"
rm -f "$TMP/landargs"; mkplan su2 't1||ship|1'
( cmd_plan_run su2 --interval 1 --auto-land --setup "make deps" >/dev/null 2>&1 )
grep -q -- "^t1 --plan su2 --setup make deps$" "$TMP/landargs" && ok "plan run --setup is the default for auto-land" || bad "setup default: $(cat "$TMP/landargs" 2>/dev/null)"
unset -f _land_usage; rm -f "$TMP/landargs"; mkplan su3 't1||ship|1'
( cmd_plan_run su3 --interval 1 --auto-land --setup "make deps" >/dev/null 2>&1 )
grep -q -- "^t1 --plan su3$" "$TMP/landargs" && ok "an older land without --setup is called without it" || bad "setup feature-detect: $(cat "$TMP/landargs" 2>/dev/null)"
# a land that holds its target (merge conflict) never has that state overwritten
_hold_land() { _task_update "$3" "$1" '.state = "held" | .hold.reason = "merge conflict with main: a.txt"' >/dev/null; echo "merge conflict"; return 1; }
mkplan su4 't1||ship|1'
( cmd_land() { _hold_land "$1" x "$3"; }; cmd_plan_run su4 --interval 1 --auto-land >/dev/null 2>&1 )
_task_get su4 t1 | jq -e '.state == "held" and (.hold.reason | test("merge conflict")) and (.land_error | test("merge conflict"))' >/dev/null \
  && ok "a merge-conflict hold from land is kept; the failure is recorded beside it" || bad "conflict hold: $(_task_get su4 t1 | jq -c '{state,hold,land_error}')"

# N1: a land step is done only when its target really merged.
mkplan falseland 't1||ship|0' 't2|t1|scout|0'
_task_update falseland t1 '.state="done"' >/dev/null
( cmd_land() { echo "verified branch only"; return 0; }; _ff_land_stage falseland t2 t1 ) >/dev/null
[ "$(st falseland t2)" = held ] && ok 'N1: land step that did not merge is held, not done' || bad "N1: land step became $(st falseland t2) without a merge"
mkplan branchland 't1||ship|0' 't2|t1|scout|0'
_task_update branchland t1 '.state="done" | .deliver="branch"' >/dev/null
( cmd_land() { echo "verified branch"; return 0; }; _ff_land_stage branchland t2 t1 ) >/dev/null
[ "$(st branchland t2)" = done ] && ok 'N1: an explicit branch delivery still completes its land step' || bad "N1: branch delivery stage is $(st branchland t2)"
grep -q 'deliver: ($s.deliver // "local")' "$FLOW" && ok 'N1: flow ship stages default to merging' || bad 'N1: flow ship stages still default to branch'

# S18: adopting an orphan job early never erases saved branch fields.
mkplan keepbase 't1||ship|0'
_task_update keepbase t1 '.state="running" | .job="" | .attempt_token="kb" | .claimed_at="2000-01-01T00:00:00Z" | .updated="2000-01-01T00:00:00Z" | .base_sha="cafe" | .branch="b1" | .worktree="/w"' >/dev/null
mkdir -p "$OSRC_JOBS/kbjob"; echo running > "$OSRC_JOBS/kbjob/status"; printf 'keepbase/t1\n' > "$OSRC_JOBS/kbjob/task_ref"; printf 'kb\n' > "$OSRC_JOBS/kbjob/task_attempt"
( OSRC_FACTORY_LAUNCH_GRACE=0 _ff_reconcile keepbase ) >/dev/null 2>&1
_task_get keepbase t1 | jq -e '.job=="kbjob" and .base_sha=="cafe" and .branch=="b1" and .worktree=="/w"' >/dev/null \
  && ok 'S18: early adoption keeps base, branch and worktree' || bad "S18: adoption result $(_task_get keepbase t1 | jq -c '{job,base_sha,branch,worktree}')"

echo "---"
echo "test_factory_flow: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
