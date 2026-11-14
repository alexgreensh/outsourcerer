#!/usr/bin/env bash
# test_factory_land.sh -- done contract (_factory_done_check) + merge gate (`land`), Track C of 0.14.
# Real temp git repos, no network, no model calls. A fake `gh` stands in for --pr.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
LAND="$HERE/../factory-land.sh"
[ -f "$SRC" ] && [ -f "$LAND" ] || { echo "FAIL: cannot find $SRC or $LAND"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

# Outside this checkout (mktemp -d), and git may not climb out of it, so no worktree, branch or
# hook of the real repo can ever be touched by these temp repos.
TEST_ROOT="${OSRC_TEST_ROOT:-${TMPDIR:-/tmp}}"
mkdir -p "$TEST_ROOT"
TMP="$(mktemp -d "$TEST_ROOT/run.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
HOME="$TMP/home"; export HOME; mkdir -p "$HOME"
export GIT_CEILING_DIRECTORIES="$TMP"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# Driver: source the main script as a library, then factory-land.sh, then (only if Track B's task
# store isn't present) a minimal TEST-ONLY shim of its contract functions. Never shipped.
cat > "$TMP/driver.sh" <<EOF
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
[ -f "$HERE/../factory-tasks.sh" ] && . "$HERE/../factory-tasks.sh"
. "$LAND"
if ! type _task_get >/dev/null 2>&1; then
  _plan_dir() { printf '%s/plans/%s' "\$OSRC_HOME" "\$1"; }
  _plan_resolve() { local p="\${1:-}"; [ -n "\$p" ] || p="\$(cat "\$OSRC_HOME/plans/current" 2>/dev/null)"; [ -n "\$p" ] || die "no plan"; printf '%s' "\$p"; }
  _task_get() { cat "\$(_plan_dir "\$1")/tasks/\$2.json" 2>/dev/null; }
  _task_update() { local f flt; f="\$(_plan_dir "\$1")/tasks/\$2.json"; flt="\$3"; shift 3
    jq "\$@" "\$flt | .updated=\"now\"" "\$f" > "\$f.tmp" && mv "\$f.tmp" "\$f"; }
  _task_event() { jq -cn --arg t "\$2" --arg e "\$3" --arg n "\${4:-}" '{task:\$t,event:\$e,note:\$n}' >> "\$(_plan_dir "\$1")/events.jsonl"; }
fi
"\$@"
EOF
ST="$TMP/state"; mkdir -p "$ST/jobs"
drv() { OSRC_HOME="$ST" bash "$TMP/driver.sh" "$@"; }

REPO="$TMP/repo"
mkdir -p "$REPO"; git -C "$REPO" init -q -b main 2>/dev/null || { git -C "$REPO" init -q; git -C "$REPO" checkout -q -b main; }
git -C "$REPO" config user.email t@example.com; git -C "$REPO" config user.name t
printf 'line1\nline2\n' > "$REPO/a.txt"; git -C "$REPO" add a.txt; git -C "$REPO" commit -qm init
PLAN=p; PD="$ST/plans/$PLAN"; mkdir -p "$PD/tasks"; echo "$PLAN" > "$ST/plans/current"
jq -cn --arg r "$REPO" '{schema:1,name:"p",goal:"g",repo:$r,base_branch:"main",created:"x",updated:"x"}' > "$PD/plan.json"

# mk_task <tid> <shape> <check> [title] -> job "j-<tid>" with a worker worktree on branch outsourcerer/j-<tid>
mk_task() {
  local tid="$1" shape="$2" check="$3" title="${4:-task $1}" jid="j-$1" wt="" br="" base
  base="$(git -C "$REPO" rev-parse main)"
  mkdir -p "$ST/jobs/$jid"; echo done > "$ST/jobs/$jid/status"
  if [ "$shape" = ship ]; then
    wt="$REPO/.outsourcerer/worktrees/$jid"; br="outsourcerer/$jid"
    git -C "$REPO" worktree add -q -b "$br" "$wt" "$base" >/dev/null 2>&1
    jq -cn --arg p "$wt" --arg b "$br" --arg s "$base" '{path:$p,branch:$b,base_sha:$s,head_sha:$s,dirty:false,ahead:0}' > "$ST/jobs/$jid/worktree.json"
  fi
  jq -cn --arg id "$tid" --arg sh "$shape" --arg c "$check" --arg t "$title" --arg j "$jid" --arg w "$wt" --arg b "$br" --arg s "$base" \
    '{schema:1,id:$id,plan:"p",title:$t,shape:$sh,state:"running",deps:[],prompt:"x",spec:"",check:$c,verb:"edit",model:"",provider:"",
      deliver:"local",retries:1,attempts:1,job:$j,jobs:[$j],worktree:$w,branch:$b,base_sha:$s,head_sha:"",
      hold:{reason:"",until:"",answer:""},result:"",evidence:"",flow:{name:"",stage:""},created:"x",updated:"x"}' > "$PD/tasks/$tid.json"
}
wt_of() { echo "$REPO/.outsourcerer/worktrees/j-$1"; }
commit_in() { # <tid> <file> <content>
  local w; w="$(wt_of "$1")"; printf '%s\n' "$3" > "$w/$2"; git -C "$w" add "$2"; git -C "$w" commit -qm "work $1 $2"
}
tfield() { jq -r "$2" "$PD/tasks/$1.json"; }
efield() { jq -r "$2" "$PD/tasks/$1/evidence.json" 2>/dev/null; }
no_land_wt() { ! { _t3b_pipe="$(git -C "$REPO" worktree list)" && grep -q '/land-' <<<"$_t3b_pipe"; }; }

# ---------------- done contract: scout ----------------
mk_task t1 scout ""
printf 'the answer is 42\n' > "$ST/jobs/j-t1/last.txt"
out="$(drv _factory_done_check p t1)"; rc=$?
[ "$rc" = 0 ] && [ -f "$PD/tasks/t1/report.md" ] && grep -q 42 "$PD/tasks/t1/report.md" && [ "$(efield t1 .verdict)" = done ] \
  && ok "scout: finished job with a result passes and the report is saved" || bad "scout pass (rc=$rc out=$out)"
[ "$(tfield t1 .evidence)" = "$PD/tasks/t1/evidence.json" ] && ok "scout: evidence path recorded on the task" || bad "scout evidence path not recorded"
mk_task t2 scout ""
: > "$ST/jobs/j-t2/last.txt"
out="$(drv _factory_done_check p t2)"; rc=$?
[ "$rc" = 1 ] && grep -q 'no result' <<<"$out" && [ "$(efield t2 .verdict)" = not_done ] \
  && ok "scout: empty result is not done" || bad "scout empty result (rc=$rc out=$out)"
echo failed > "$ST/jobs/j-t2/status"; echo "x" > "$ST/jobs/j-t2/last.txt"
out="$(drv _factory_done_check p t2)"; rc=$?
[ "$rc" = 1 ] && grep -q 'status: failed' <<<"$out" && ok "scout: failed job is not done" || bad "scout failed job (rc=$rc out=$out)"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] && ok "done check prints exactly one line" || bad "done check printed more than one line"

# ---------------- done contract: ship refusals ----------------
mk_task t3 ship ""
out="$(drv _factory_done_check p t3)"; rc=$?
[ "$rc" = 1 ] && grep -q 'no commits' <<<"$out" && ok "ship: no commits -> refused" || bad "ship no commits (rc=$rc out=$out)"

mk_task t4 ship ""
commit_in t4 b.txt b; echo dirty >> "$(wt_of t4)/a.txt"
out="$(drv _factory_done_check p t4)"; rc=$?
[ "$rc" = 1 ] && grep -q 'uncommitted' <<<"$out" && ok "ship: dirty worktree -> refused" || bad "ship dirty (rc=$rc out=$out)"

mk_task t5 ship ""
git -C "$(wt_of t5)" checkout -q --detach; commit_in t5 c.txt c
out="$(drv _factory_done_check p t5)"; rc=$?
[ "$rc" = 1 ] && grep -q 'not on any branch' <<<"$out" && ok "ship: detached-only head -> refused" || bad "ship detached (rc=$rc out=$out)"

mk_task t6 ship "false"
commit_in t6 d.txt d
out="$(drv _factory_done_check p t6)"; rc=$?
[ "$rc" = 1 ] && grep -q 'check failed' <<<"$out" && [ "$(efield t6 .check.rc)" = 1 ] \
  && ok "ship: failing check -> refused, rc in evidence" || bad "ship check fail (rc=$rc out=$out)"
echo "running" > "$ST/jobs/j-t6/status"
out="$(drv _factory_done_check p t6)"; rc=$?
[ "$rc" = 1 ] && grep -q 'still running' <<<"$out" && ok "ship: unfinished job -> refused" || bad "ship unfinished job (rc=$rc out=$out)"

mk_task t7 ship "true"
commit_in t7 cfg.txt "token=gh""p_$(printf 'A%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30)"
out="$(drv _factory_done_check p t7)"; rc=$?
[ "$rc" = 1 ] && grep -q 'secret' <<<"$out" && [ "$(efield t7 .secret_scan)" = blocked ] \
  && ok "ship: secret in base..head diff -> refused" || bad "ship secret (rc=$rc out=$out)"
out="$(drv cmd_land t7 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'not landing' <<<"$out" && ok "land refuses when the done contract fails" || bad "land with failing contract (rc=$rc)"

# ---------------- happy path ----------------
mk_task t8 ship "test -f e.txt" "add e"
commit_in t8 e.txt e
before="$(git -C "$REPO" rev-parse main)"; head8="$(git -C "$(wt_of t8)" rev-parse HEAD)"
out="$(drv _factory_done_check p t8)"; rc=$?
[ "$rc" = 0 ] && [ "$(efield t8 .verdict)" = done ] && [ "$(efield t8 .head_sha)" = "$head8" ] && [ "$(efield t8 .check.rc)" = 0 ] \
  && [ "$(tfield t8 .head_sha)" = "$head8" ] && ok "ship: committed, clean, on a branch, check green -> done (+evidence)" || bad "ship done (rc=$rc out=$out)"
for k in task shape job base_sha head_sha check secret_scan verdict reason ts; do
  jq -e --arg k "$k" 'has($k)' "$PD/tasks/t8/evidence.json" >/dev/null || { bad "evidence missing key $k"; break; }
done && ok "evidence.json carries every contract key"
out="$(drv cmd_land t8 2>&1)"; rc=$?
after="$(git -C "$REPO" rev-parse main)"
[ "$rc" = 0 ] && [ "$after" != "$before" ] && [ "$(git -C "$REPO" log -1 --format=%s main)" = "land(p/t8): add e" ] \
  && [ "$(git -C "$REPO" rev-parse main^1)" = "$before" ] && [ "$(git -C "$REPO" rev-parse main^2)" = "$head8" ] \
  && ok "land: no-ff merge with the contract message, target fast-forwarded" || bad "land happy path (rc=$rc out=$out)"
[ -f "$REPO/e.txt" ] && [ -z "$(git -C "$REPO" status --porcelain -uno)" ] && ok "land: the checked-out target tree was updated cleanly" || bad "checkout not updated"
[ "$(tfield t8 .landed)" = true ] && [ "$(tfield t8 .state)" = done ] && [ "$(tfield t8 .landed_sha)" = "$after" ] \
  && [ "$(efield t8 .land.verdict)" = landed ] && [ "$(efield t8 .land.merged_sha)" = "$after" ] \
  && ok "land: task marked landed with evidence" || bad "landed bookkeeping"
no_land_wt && ok "land: integration worktree removed" || bad "integration worktree left behind"
[ -d "$(wt_of t8)" ] && ok "land: worker worktree left for cleanup" || bad "worker worktree removed by land"
out="$(drv cmd_land t8 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'already landed' <<<"$out" && ok "land: second land of a landed task is a no-op" || bad "re-land (rc=$rc)"

# land into a branch that is NOT checked out anywhere (update-ref path)
git -C "$REPO" branch rel main
mk_task t9 ship "" "rel work"
commit_in t9 r.txt r
out="$(drv cmd_land t9 --into rel 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$REPO" log -1 --format=%s rel)" = "land(p/t9): rel work" ] && [ "$(git -C "$REPO" rev-parse main)" = "$after" ] \
  && ok "land --into: moves a branch that is not checked out, main untouched" || bad "land --into (rc=$rc out=$out)"

# ---------------- conflict ----------------
mk_task t10 ship ""
drv _task_update p t10 '.state="done"' >/dev/null
commit_in t10 a.txt "worker line"
printf 'main line\n' > "$REPO/a.txt"; git -C "$REPO" commit -qam "main edits a"
m="$(git -C "$REPO" rev-parse main)"
out="$(drv cmd_land t10 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'conflicts with main in: a.txt' <<<"$out" && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && [ -z "$(git -C "$REPO" status --porcelain -uno)" ] && [ "$(efield t10 .land.verdict)" = conflict ] \
  && ok "land: merge conflict aborts cleanly, target untouched" || bad "conflict (rc=$rc out=$out)"
[ "$(tfield t10 .state)" = done ] && [ "$(tfield t10 .land_error)" = "merge conflict with main: a.txt; rebase the task branch or retry" ] \
  && [ "$(tfield t10 .land_error_at)" != null ] && grep -q 'land t10 --plan p' <<<"$out" \
  && ok "land (S13/S14/S15): conflict preserves done, records land_error and gives a runnable plan-specific retry" || bad "conflict state/error (state=$(tfield t10 .state) error=$(tfield t10 .land_error))"
no_land_wt && ok "land: no integration worktree left after a conflict" || bad "worktree left after conflict"
grep -q '"land_conflict"' "$PD/events.jsonl" 2>/dev/null && ok "land: conflict recorded as a task event" || bad "conflict event missing"

# ---------------- merged result breaks the check ----------------
CHK='! { [ -f x.txt ] && [ -f y.txt ]; }'
mk_task t11 ship "$CHK"
drv _task_update p t11 '.state="done"' >/dev/null
commit_in t11 x.txt x
printf 'y\n' > "$REPO/y.txt"; git -C "$REPO" add y.txt; git -C "$REPO" commit -qm "main adds y"
m="$(git -C "$REPO" rev-parse main)"
out="$(drv cmd_land t11 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'check fails' <<<"$out" && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && [ "$(tfield t11 .state)" = done ] && [ "$(tfield t11 .land_error)" = "merge breaks check" ] && [ "$(tfield t11 .land_error_at)" != null ] && [ "$(tfield t11 .landed)" != true ] \
  && [ "$(efield t11 .land.verdict)" = check_failed ] \
  && ok "land (S13): merged check failure preserves done with separate landing error" || bad "merge breaks check (rc=$rc out=$out)"
no_land_wt && ok "land: no integration worktree left after a red check" || bad "worktree left after red check"
{ _t3b_pipe="$(grep 'merge breaks check' "$ST/wake-queue.jsonl" 2>/dev/null)" && grep -q 'p/t11' <<<"$_t3b_pipe"; } && ok "land: red check queued a wake event" || bad "wake event missing"
grep -q 'clean checkout' <<<"$out" && grep -q -- '--setup' <<<"$out" \
  && ok "land (#9): a red merged check says it ran in a clean checkout and points at --setup" || bad "clean-checkout hint missing: $out"

# ---------------- target checked out dirty ----------------
mk_task t12 ship "" "dirty target"
commit_in t12 z.txt z
echo "local edit" >> "$REPO/a.txt"
m="$(git -C "$REPO" rev-parse main)"
out="$(drv cmd_land t12 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'uncommitted changes' <<<"$out" && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && grep -q 'local edit' "$REPO/a.txt" && [ "$(tfield t12 .landed)" != true ] \
  && ok "land: refuses to fast-forward a dirty checkout, nothing clobbered" || bad "dirty target (rc=$rc out=$out)"
git -C "$REPO" checkout -q -- a.txt

# ---------------- dry run ----------------
m="$(git -C "$REPO" rev-parse main)"
tsum="$(cksum < "$PD/tasks/t12.json")"; esum="$(cksum < "$PD/tasks/t12/evidence.json" 2>/dev/null)"
out="$(drv cmd_land t12 --dry-run 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'dry run' <<<"$out" && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && [ "$(tfield t12 .landed)" != true ] && no_land_wt \
  && [ "$(jq -r .land.mode "$ST/land/dry-run/p_t12/evidence.json")" = dry-run ] \
  && ok "land --dry-run: merges + checks in scratch, moves nothing" || bad "dry run (rc=$rc out=$out)"
[ "$(cksum < "$PD/tasks/t12.json")" = "$tsum" ] && [ "$(cksum < "$PD/tasks/t12/evidence.json" 2>/dev/null)" = "$esum" ] \
  && ok "land --dry-run (#16): the task file and its evidence are byte-for-byte untouched" || bad "dry run mutated the task or its evidence"

# ---------------- serialized (two concurrent lands) ----------------
# Deterministic, not timing-based: the first land to reach its merged check HOLDS the queue until
# the other lander has printed its "waiting in the merge queue" line (bounded at 60s so a bug fails
# the assertions instead of hanging). The second land's check then finds the line already there.
cat > "$TMP/slowcheck.sh" <<EOF
case "\$PWD" in */land-*)
  echo S >> "$TMP/seq"
  n=0; until cat "$TMP/o13" "$TMP/o14" 2>/dev/null | grep -q 'waiting in the merge queue'; do n=\$((n+1)); [ \$n -ge 600 ] && break; sleep 0.1; done
  echo E >> "$TMP/seq" ;;
esac
exit 0
EOF
: > "$TMP/seq"; : > "$TMP/o13"; : > "$TMP/o14"
mk_task t13 ship "bash $TMP/slowcheck.sh" "c13"; commit_in t13 f13.txt a
mk_task t14 ship "bash $TMP/slowcheck.sh" "c14"; commit_in t14 f14.txt b
( drv cmd_land t13 > "$TMP/o13" 2>&1; echo $? > "$TMP/r13" ) &
( drv cmd_land t14 > "$TMP/o14" 2>&1; echo $? > "$TMP/r14" ) &
wait
[ "$(cat "$TMP/r13")" = 0 ] && [ "$(cat "$TMP/r14")" = 0 ] && [ "$(tr -d '\n' < "$TMP/seq")" = SESE ] \
  && git -C "$REPO" merge-base --is-ancestor "$(git -C "$(wt_of t13)" rev-parse HEAD)" main \
  && git -C "$REPO" merge-base --is-ancestor "$(git -C "$(wt_of t14)" rev-parse HEAD)" main \
  && ok "land: two concurrent lands serialize and both land" || bad "concurrent lands (r13=$(cat "$TMP/r13") r14=$(cat "$TMP/r14") seq=$(tr -d '\n' < "$TMP/seq"))"

# ---------------- lock: live holder times out; dead holder is reclaimed ----------------
LK="$(OSRC_HOME="$ST" bash "$TMP/driver.sh" _land_lock_dir "$(cd "$REPO" && pwd -P)")"
mk_task t15 ship "" "lock"; commit_in t15 g.txt g
sleep 60 & live=$!
mkdir -p "$LK"; printf '%s %s\n' "$live" "$(OSRC_HOME="$ST" bash "$TMP/driver.sh" _pid_start_identity "$live")" > "$LK/owner"; echo "land other" > "$LK/holder"
out="$(OSRC_LAND_LOCK_WAIT=2 drv cmd_land t15 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'gave up after 2s' <<<"$out" && [ "$(tfield t15 .landed)" != true ] \
  && ok "land: bounded wait on a live holder, clear timeout" || bad "lock timeout (rc=$rc out=$out)"
# The waiting line is checked here, against a holder that is provably live for the whole wait, so
# it can't depend on how two real lands happen to interleave on a loaded machine.
grep -q 'waiting in the merge queue: land other is merging' <<<"$out" \
  && ok "land: the waiter says who holds the queue" || bad "no waiting message (out=$out)"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
out="$(OSRC_LAND_LOCK_WAIT=5 drv cmd_land t15 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(tfield t15 .landed)" = true ] && [ ! -d "$LK" ] && ok "land: a dead holder's lock is reclaimed" || bad "stale lock reclaim (rc=$rc out=$out)"

# ---------------- --pr via fake gh + local bare origin ----------------
git init -q --bare "$TMP/origin.git"; git -C "$REPO" remote add origin "$TMP/origin.git"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$TMP/gh.args"
echo "https://github.com/example/repo/pull/7"
EOF
chmod +x "$TMP/bin/gh"
mk_task t16 ship "test -f h.txt" "pr work"; commit_in t16 h.txt h
m="$(git -C "$REPO" rev-parse main)"; h16="$(git -C "$(wt_of t16)" rev-parse HEAD)"
out="$(PATH="$TMP/bin:$PATH" drv cmd_land t16 --pr 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$TMP/origin.git" rev-parse refs/heads/outsourcerer/j-t16 2>/dev/null)" = "$h16" ] \
  && grep -q -- '--base main' "$TMP/gh.args" && grep -q -- '--head outsourcerer/j-t16' "$TMP/gh.args" \
  && [ "$(tfield t16 .pr)" = "https://github.com/example/repo/pull/7" ] && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && [ "$(efield t16 .land.verdict)" = pr_opened ] && ok "land --pr: pushes the branch, opens the PR, target not moved" || bad "land --pr (rc=$rc out=$out)"

# ---------------- bare job id (ad-hoc fanout/bg worktree job) ----------------
mk_task t17 ship "" "adhoc"; commit_in t17 k.txt k
out="$(drv cmd_land j-t17 --check 'test -f k.txt' 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$REPO" log -1 --format=%s main)" = "land(j-t17): outsourcerer/j-t17" ] \
  && [ "$(jq -r .land.verdict "$ST/jobs/j-t17/evidence.json")" = landed ] && [ "$(jq -r .check.rc "$ST/jobs/j-t17/evidence.json")" = 0 ] \
  && ok "land <job-id> --check: lands an ad-hoc worktree job, evidence in the job dir" || bad "bare job land (rc=$rc out=$out)"
out="$(drv cmd_land nope-123 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'no task or job' <<<"$out" && ok "land: unknown id says what to do" || bad "unknown id (rc=$rc)"

# ================= review-1 fixes =================
setst() { jq "$2" "$PD/tasks/$1.json" > "$PD/tasks/$1.json.x" && mv "$PD/tasks/$1.json.x" "$PD/tasks/$1.json"; }

# ---- #2: land only from running|verifying|done; failed needs --force; held/canceled/todo never ----
mk_task t20 ship "" "held work"; commit_in t20 h20.txt a
setst t20 '.state="held" | .hold.reason="pick A or B"'
m="$(git -C "$REPO" rev-parse main)"
out="$(drv cmd_land t20 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'on hold (pick A or B)' <<<"$out" && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] && [ "$(tfield t20 .state)" = held ] \
  && ok "land (#2): a held task is refused and stays held" || bad "held land (rc=$rc out=$out)"
out="$(drv cmd_land t20 --force 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ "$(tfield t20 .state)" = held ] && ok "land (#2): --force never lands a held task" || bad "held --force landed (rc=$rc)"
mk_task t21 ship "" "failed work"; commit_in t21 h21.txt a
setst t21 '.state="failed" | .result="boom"'
out="$(drv cmd_land t21 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'failed (boom)' <<<"$out" && grep -q -- '--force' <<<"$out" && [ "$(tfield t21 .state)" = failed ] \
  && ok "land (#2): a failed task is refused and the line names --force" || bad "failed land (rc=$rc out=$out)"
out="$(drv cmd_land t21 --force 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(tfield t21 .landed)" = true ] && [ "$(tfield t21 .state)" = done ] \
  && ok "land (#2): --force lands a failed task after the full gate" || bad "failed --force (rc=$rc out=$out)"
mk_task t23 ship "" "todo work"; commit_in t23 h23.txt a; setst t23 '.state="todo"'
out="$(drv cmd_land t23 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'has not run yet' <<<"$out" && ok "land (#2): a todo task is refused" || bad "todo land (rc=$rc out=$out)"
# A cancel that arrives WHILE landing (here: during the merged-result check) must win.
cat > "$TMP/cancel_mid.sh" <<EOT
case "\$PWD" in */land-*) jq '.state="canceled"' "$PD/tasks/t22.json" > "$PD/tasks/t22.json.x" && mv "$PD/tasks/t22.json.x" "$PD/tasks/t22.json" ;; esac
exit 0
EOT
mk_task t22 ship "bash $TMP/cancel_mid.sh" "cancel mid land"; commit_in t22 h22.txt a
m="$(git -C "$REPO" rev-parse main)"
out="$(drv cmd_land t22 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'canceled' <<<"$out" && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && [ "$(tfield t22 .state)" = canceled ] && [ "$(tfield t22 .landed)" != true ] && no_land_wt \
  && ok "land (#2): a cancel during the land stops it before the target moves; state stays canceled" || bad "cancel mid-land (rc=$rc state=$(tfield t22 .state) out=$out)"

# ---- #3: never overwrite ignored/untracked files in the checked-out target ----
printf 'local.cfg\n' > "$REPO/.gitignore"; git -C "$REPO" add .gitignore; git -C "$REPO" commit -qm "ignore local.cfg"
printf 'MY LOCAL SETTINGS\n' > "$REPO/local.cfg"
mk_task t24 ship "" "force-add ignored"
printf 'worker version\n' > "$(wt_of t24)/local.cfg"; git -C "$(wt_of t24)" add -f local.cfg; git -C "$(wt_of t24)" commit -qm "add local.cfg"
m="$(git -C "$REPO" rev-parse main)"
out="$(drv cmd_land t24 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'local.cfg' <<<"$out" && grep -q 'would overwrite' <<<"$out" \
  && [ "$(cat "$REPO/local.cfg")" = "MY LOCAL SETTINGS" ] && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && ok "land (#3): a git-ignored local file in the target checkout is never overwritten (refused, path listed)" || bad "ignored overwrite (rc=$rc file=$(cat "$REPO/local.cfg") out=$out)"
mkdir -p "$REPO/notes"; printf 'my notes\n' > "$REPO/notes/todo.md"
mk_task t25 ship "" "adds notes"; mkdir -p "$(wt_of t25)/notes"; commit_in t25 notes/todo.md "worker notes"
out="$(drv cmd_land t25 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'notes/todo.md' <<<"$out" && [ "$(cat "$REPO/notes/todo.md")" = "my notes" ] \
  && ok "land (#3): an untracked file in the way is listed, not clobbered" || bad "untracked collision (rc=$rc out=$out)"
rm -rf "$REPO/local.cfg" "$REPO/notes"
setst t24 '.state="canceled"'; setst t25 '.state="canceled"'

# ---- #4: the verified head is private; a concurrent evidence rewrite can't change what lands ----
cat > "$TMP/driver_race.sh" <<EOT
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
. "$HERE/../factory-tasks.sh"
. "$LAND"
eval "_orig_record() \$(declare -f _factory_done_record | tail -n +2)"
_factory_done_record() { _orig_record "\$@"; local r=\$?
  jq --arg h "\$BOGUS" '.head_sha=\$h' "\$_FDC_TDIR/evidence.json" > "\$_FDC_TDIR/evidence.json.x" && mv "\$_FDC_TDIR/evidence.json.x" "\$_FDC_TDIR/evidence.json"
  return \$r; }
"\$@"
EOT
mk_task t26 ship "" "race"; commit_in t26 r26.txt a
h26="$(git -C "$(wt_of t26)" rev-parse HEAD)"; bogus="$(git -C "$REPO" rev-parse main~1)"
out="$(BOGUS="$bogus" OSRC_HOME="$ST" bash "$TMP/driver_race.sh" cmd_land t26 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$REPO" rev-parse main^2)" = "$h26" ] && [ "$(tfield t26 .landed)" = true ] \
  && ok "land (#4): lands the head it verified even if evidence.json is rewritten underneath" || bad "evidence race (rc=$rc out=$out)"

# ---- #9: --setup prepares the clean checkout; recorded in evidence ----
mk_task t27 ship "test -f deps/ok" "needs deps"; commit_in t27 r27.txt a
mkdir -p "$(wt_of t27)/deps"; : > "$(wt_of t27)/deps/ok"
out="$(drv cmd_land t27 --dry-run 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'clean checkout' <<<"$out" && [ "$(tfield t27 .state)" = running ] \
  && ok "land (#9): a check needing untracked deps fails on the merged result with the clean-checkout hint" || bad "deps dry run (rc=$rc out=$out)"
out="$(drv cmd_land t27 --dry-run --setup 'exit 3' 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'setup command failed (exit 3)' <<<"$out" && ok "land (#9): a failing --setup refuses with its exit code" || bad "setup fail (rc=$rc out=$out)"
out="$(drv cmd_land t27 --setup 'mkdir -p deps && touch deps/ok' 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(tfield t27 .landed)" = true ] && [ "$(efield t27 .land.setup.cmd)" = "mkdir -p deps && touch deps/ok" ] \
  && [ "$(efield t27 .land.setup.rc)" = 0 ] && ok "land (#9): --setup runs before the merged check and is recorded in evidence" || bad "setup land (rc=$rc out=$out)"

# ---- #10: secret scan = added lines, key values only ----
mk_task t28 ship "" "names only"
commit_in t28 cfg.py 'key = os.environ["OPENROUTER_API_KEY"]; aws = os.environ["AWS_SECRET_ACCESS_KEY"]; risk-assessment-framework-document-v2'
out="$(drv _factory_done_check p t28)"; rc=$?
[ "$rc" = 0 ] && [ "$(efield t28 .secret_scan)" = clean ] && ok "secret scan (#10): variable NAMES alone do not block" || bad "names blocked (rc=$rc out=$out)"
GHK="gh""p_$(printf 'B%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24)"
printf 'old=%s\n' "$GHK" > "$REPO/leak.txt"; git -C "$REPO" add leak.txt; git -C "$REPO" commit -qm "old leak on main"
mk_task t29 ship "" "remove leak"; git -C "$(wt_of t29)" rm -q leak.txt; git -C "$(wt_of t29)" commit -qm "remove leaked key"
out="$(drv _factory_done_check p t29)"; rc=$?
[ "$rc" = 0 ] && ok "secret scan (#10): REMOVING a leaked key does not block" || bad "removal blocked (rc=$rc out=$out)"
SR="$TMP/secrets"; mkdir -p "$SR"; git -C "$SR" init -q; printf 'x\n' > "$SR/f"; git -C "$SR" add f; git -C "$SR" commit -qm b
sb="$(git -C "$SR" rev-parse HEAD)"
A20="$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24)"
for v in "sk_""live_$A20" "rk_""live_$A20" "AI""za$A20$A20" "xa""pp-1-A0$A20" "-----BEGIN ""RSA PRIVATE KEY-----" "sk-""proj-$A20" "AK""IAABCDEFGHIJKLMNOP" "xox""b-1234-$A20"; do
  printf 'v = "%s"\n' "$v" > "$SR/f"; git -C "$SR" commit -qam "add"
  if drv _factory_scan_range "$SR" "$sb" HEAD; then ok "secret scan (#10): blocks ${v:0:8}..."; else bad "secret scan missed ${v:0:8}..."; fi
  git -C "$SR" reset -q --hard "$sb"
done
# crew shares the patterns: planted keys still block, removals and names don't.
CR="$TMP/crewscan"; mkdir -p "$CR"; git -C "$CR" init -q; printf 'base\n' > "$CR/f"; git -C "$CR" add f; git -C "$CR" commit -qm b
printf 'token=%s\n' "$GHK" > "$CR/f"; git -C "$CR" add f
drv _crew_scan_staged "$CR" && ok "crew (#10): a staged planted key still blocks" || bad "crew missed a planted key"
git -C "$CR" commit -qm leak; git -C "$CR" rm -q f
drv _crew_scan_staged "$CR" && bad "crew blocked a staged key REMOVAL" || ok "crew (#10): staging a key removal does not block"
git -C "$CR" commit -qm rm; printf 'k = env("OPENROUTER_API_KEY")\n' > "$CR/g"; git -C "$CR" add g
drv _crew_scan_staged "$CR" && bad "crew blocked a variable name" || ok "crew (#10): a variable name alone does not block"

# ---- #11: bare job needs --check or explicit --no-check ----
mk_task t30 ship "" "adhoc2"; commit_in t30 r30.txt a; setst t30 '.state="canceled"'
out="$(drv cmd_land j-t30 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q -- '--no-check' <<<"$out" && ok "land (#11): a bare job without --check is refused" || bad "bare job no check (rc=$rc out=$out)"
out="$(drv cmd_land j-t30 --no-check 2>&1)"; rc=$?
[ "$rc" = 0 ] && git -C "$REPO" merge-base --is-ancestor "$(git -C "$(wt_of t30)" rev-parse HEAD)" main \
  && ok "land (#11): --no-check lands a bare job on purpose" || bad "bare job --no-check (rc=$rc out=$out)"

# ---- #12: "already contained" only counts when an earlier land put it there ----
mk_task t31 ship "" "merged by hand"; commit_in t31 r31.txt a
git -C "$REPO" merge -q --no-edit outsourcerer/j-t31 >/dev/null 2>&1
out="$(drv cmd_land t31 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'did not get there through land' <<<"$out" && [ "$(tfield t31 .landed)" != true ] \
  && ok "land (#12): head already in the target WITHOUT a land is refused" || bad "contained w/o land (rc=$rc out=$out)"
setst t8 '.landed=false'
out="$(drv cmd_land t8 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'by an earlier land' <<<"$out" && [ "$(tfield t8 .landed)" = true ] \
  && ok "land (#12): head put there by an earlier land is accepted (bookkeeping repaired)" || bad "contained via land (rc=$rc out=$out)"

# ---- #13: target mid-rebase / mid-bisect in another worktree ----
git -C "$REPO" branch reb main; git -C "$REPO" branch onto main
RW="$TMP/rebwt"; git -C "$REPO" worktree add -q "$RW" reb >/dev/null 2>&1
printf 'reb side\n' > "$RW/conf.txt"; git -C "$RW" add conf.txt; git -C "$RW" commit -qm reb
OW="$TMP/ontowt"; git -C "$REPO" worktree add -q "$OW" onto >/dev/null 2>&1
printf 'onto side\n' > "$OW/conf.txt"; git -C "$OW" add conf.txt; git -C "$OW" commit -qm onto
git -C "$RW" rebase onto >/dev/null 2>&1
mk_task t32 ship "" "into reb"; commit_in t32 r32.txt a
rb="$(git -C "$REPO" rev-parse refs/heads/reb)"
out="$(drv cmd_land t32 --into reb 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'middle of a rebase' <<<"$out" && [ "$(git -C "$REPO" rev-parse refs/heads/reb)" = "$rb" ] \
  && ok "land (#13): refuses a target that is mid-rebase in another worktree" || bad "mid-rebase (rc=$rc out=$out)"
git -C "$RW" rebase --abort >/dev/null 2>&1
git -C "$RW" bisect start >/dev/null 2>&1
out="$(drv cmd_land t32 --into reb 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'middle of a bisect' <<<"$out" && ok "land (#13): refuses a target that is mid-bisect" || bad "mid-bisect (rc=$rc out=$out)"
git -C "$RW" bisect reset >/dev/null 2>&1

# ---- #14: land never replaces the task store's private, validating JSON writer ----
fwj="$(drv declare -f _factory_write_json)"; grep -q 'jq -e' <<<"$fwj" && grep -q 'umask 077' <<<"$fwj" && ok "land (#14): factory-tasks' _factory_write_json survives sourcing factory-land.sh" || bad "_factory_write_json clobbered"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo "SKIP: file modes on Windows" ;;
  *) pm="$(stat -c %a "$PD/tasks/t8.json" 2>/dev/null || stat -f %Lp "$PD/tasks/t8.json")"
     [ "$pm" = 600 ] && ok "land (#14): task files written by land stay private (0600)" || bad "task file mode $pm after land" ;;
esac

# ---- #15 + #17: no repo hooks in the scratch worktree; stale land-* worktrees pruned ----
HK="$(git -C "$REPO" rev-parse --git-common-dir)"; case "$HK" in /*) ;; *) HK="$REPO/$HK" ;; esac; HK="$HK/hooks"; mkdir -p "$HK"
printf '#!/bin/sh\necho "$PWD" >> "%s/hook.log"\n' "$TMP" > "$HK/post-checkout"; chmod +x "$HK/post-checkout"
WD="$REPO/.outsourcerer/worktrees"
git -C "$REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$WD/land-stale1" main >/dev/null 2>&1
git -C "$REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$WD/land-stale2" main >/dev/null 2>&1
git -C "$REPO" -c core.hooksPath=/dev/null worktree add -q --detach "$WD/land-live" main >/dev/null 2>&1
mkdir -p "$ST/land/active"
sh -c 'exit 0' & deadpid=$!; wait "$deadpid" 2>/dev/null
echo "$deadpid Thu Jan  1 00:00:00 1970" > "$ST/land/active/land-stale1"
sleep 60 & livepid=$!
printf '%s %s\n' "$livepid" "$(drv _pid_start_identity "$livepid")" > "$ST/land/active/land-live"
mk_task t33 ship "" "prune"; commit_in t33 r33.txt a
out="$(drv cmd_land t33 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -d "$WD/land-stale1" ] && [ ! -d "$WD/land-stale2" ] && [ -d "$WD/land-live" ] \
  && ! { _t3b_pipe="$(git -C "$REPO" worktree list)" && grep -q 'land-stale' <<<"$_t3b_pipe"; } \
  && ok "land (#17): leftover land-* worktrees of dead lands are pruned; a live one is kept" || bad "prune (rc=$rc out=$out)"
grep -q 'j-t33' "$TMP/hook.log" 2>/dev/null && ! grep -q '/land-' "$TMP/hook.log" && ok "land (#15): repo hooks never run for the scratch worktree" || bad "post-checkout hook ran in a land worktree"
kill "$livepid" 2>/dev/null; wait "$livepid" 2>/dev/null
git -C "$REPO" worktree remove --force "$WD/land-live" >/dev/null 2>&1; rm -f "$ST/land/active/land-live" "$HK/post-checkout"

# ---- #24: the unknown-subcommand hint lists the factory commands ----
out="$(OSRC_HOME="$ST" bash "$SRC" no-such-subcommand 2>&1)"
grep -q 'plan|task|land|flow' <<<"$out" && grep -q 'exclude' <<<"$out" \
  && ok "main (#24): unknown subcommand hint lists plan, task, land, flow, exclude" || bad "hint missing factory commands: $(printf '%s' "$out" | tail -1 | cut -c1-200)"

# ---------------- round 3: exact tree, history, delivery and recovery ----------------
mk_task t40 ship 'printf good > mutation.txt; test "$(cat mutation.txt)" = good'
commit_in t40 mutation.txt bad
m="$(git -C "$REPO" rev-parse main)"
out="$(drv cmd_land t40 --plan p 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'changed HEAD or tracked files' <<<"$out" && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && ok "S2: worker check cannot repair the tree it claims to verify" || bad "mutating worker check ($rc $out)"

mk_task t41 ship 'case "$PWD" in */land-*) printf changed > mutation.txt ;; esac'
commit_in t41 mutation.txt original
out="$(drv cmd_land t41 --plan p 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ "$(efield t41 .land.verdict)" = tree_changed ] && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && ok "S2: merged check cannot change tracked contents" || bad "mutating integration check ($rc $out)"
out="$(drv cmd_land t41 --plan p --no-check --setup 'printf changed > mutation.txt; git add mutation.txt; git commit -qm changed' 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ "$(efield t41 .land.verdict)" = tree_changed ] && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && ok "S2: setup cannot replace the verified HEAD" || bad "mutating setup ($rc $out)"
out="$(drv cmd_land t41 --plan p --setup 'printf changed > mutation.txt' --check 'case "$PWD" in */land-*) git checkout -- mutation.txt ;; esac' 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ "$(efield t41 .land.verdict)" = tree_changed ] && [ "$(tfield t41 .state)" = running ] \
  && ok "S2/S13: setup mutations are caught before a check can undo them; running state survives" || bad "setup restored by check ($rc $out)"

mk_task t42 ship true
commit_in t42 transient.txt "token=$GHK"
git -C "$(wt_of t42)" rm -q transient.txt; git -C "$(wt_of t42)" commit -qm 'remove transient secret'
out="$(drv _factory_done_check p t42 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ "$(efield t42 .secret_scan)" = blocked ] \
  && ok "S5: secret committed then removed still blocks landing history" || bad "intermediate secret ($rc $out)"

# A review approved an earlier commit; direct land must refuse the replacement revision.
mk_task t43 ship true; commit_in t43 revision.txt old
h43="$(git -C "$(wt_of t43)" rev-parse HEAD)"
mk_task t44 scout ""; setst t44 '.state="done" | .require_verdict=true | .deps=["t43"]'
drv _task_update p t44 '.reviewed_head=$h' --arg h "$h43" >/dev/null
commit_in t43 revision.txt new
out="$(drv cmd_land t43 --plan p 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'does not approve revision' <<<"$out" && [ "$(tfield t43 .landed)" != true ] \
  && ok "C5: stale reviewed_head refuses a rebuilt task" || bad "stale review ($rc $out)"
drv _task_update p t44 '.reviewed_head=$h' --arg h "$(git -C "$(wt_of t43)" rev-parse HEAD)" >/dev/null
out="$(drv cmd_land t43 --plan p 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(tfield t43 .landed)" = true ] && ok "C5: matching review permits landing" || bad "current review ($rc $out)"

mk_task t45 ship true; commit_in t45 branch-only.txt branch
setst t45 '.deliver="branch"'
m="$(git -C "$REPO" rev-parse main)"
out="$(drv cmd_land t45 --plan p 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(tfield t45 .delivered)" = branch ] && [ "$(tfield t45 .delivered_head)" = "$(git -C "$(wt_of t45)" rev-parse HEAD)" ] \
  && [ "$(tfield t45 .landed)" != true ] && [ "$(tfield t45 .state)" = done ] && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && ok "D8: branch delivery verifies and records the branch without a merge" || bad "branch delivery ($rc $out)"
mk_task t46 ship true; commit_in t46 implicit-pr.txt pr; setst t46 '.deliver="pr"'
out="$(PATH="$TMP/bin:$PATH" drv cmd_land t46 --plan p 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(tfield t46 .pr)" = https://github.com/example/repo/pull/7 ] && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && ok "D8: PR delivery acts as --pr without the explicit flag" || bad "implicit PR ($rc $out)"

cat > "$TMP/cancel_pr.sh" <<EOT
case "\$PWD" in */land-*) jq '.state="canceled"' "$PD/tasks/t47.json" > "$PD/tasks/t47.json.x" && mv "$PD/tasks/t47.json.x" "$PD/tasks/t47.json" ;; esac
EOT
mk_task t47 ship "bash $TMP/cancel_pr.sh"; commit_in t47 canceled-pr.txt x
rm -f "$TMP/gh.args"
out="$(PATH="$TMP/bin:$PATH" drv cmd_land t47 --plan p --pr 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -f "$TMP/gh.args" ] && ! git -C "$TMP/origin.git" rev-parse --verify refs/heads/outsourcerer/j-t47 >/dev/null 2>&1 \
  && [ "$(tfield t47 .state)" = canceled ] && ok "S9: cancellation during check prevents both push and PR creation" || bad "canceled PR ($rc $out)"

cat > "$TMP/replace_attempt.sh" <<EOT
case "\$PWD" in */land-*) jq '.attempt_token="replacement"' "$PD/tasks/t48.json" > "$PD/tasks/t48.json.x" && mv "$PD/tasks/t48.json.x" "$PD/tasks/t48.json" ;; esac
EOT
mk_task t48 ship "bash $TMP/replace_attempt.sh"; commit_in t48 replacement.txt x
out="$(PATH="$TMP/bin:$PATH" drv cmd_land t48 --plan p --pr 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'changed attempts' <<<"$out" && [ ! -f "$TMP/gh.args" ] \
  && ! git -C "$TMP/origin.git" rev-parse --verify refs/heads/outsourcerer/j-t48 >/dev/null 2>&1 \
  && ok "S9: replacement attempt also prevents PR publication" || bad "replacement PR ($rc $out)"

cat > "$TMP/crash_land.sh" <<EOT
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
. "$LAND"
eval "_original_land_record() \$(declare -f _land_record | tail -n +2)"
_land_record() {
  if [ "\$(printf '%s' "\$2" | jq -r .verdict)" = landed ]; then kill -KILL "\$_FL_PID"; fi
  _original_land_record "\$@"
}
"\$@"
EOT
mk_task t49 ship true; commit_in t49 recover.txt x
out="$(OSRC_HOME="$ST" bash "$TMP/crash_land.sh" cmd_land t49 --plan p 2>&1)"; rc=$?
m="$(git -C "$REPO" rev-parse main)"
[ "$rc" != 0 ] && [ "$(tfield t49 .land_intent.merged_sha)" = "$m" ] && [ "$(tfield t49 .landed)" != true ] \
  && ok "S10: SIGKILL after ref movement leaves a durable verified receipt" || bad "crash receipt ($rc $out)"
setst t49 '.state="canceled" | .check="false"'
out="$(OSRC_LAND_LOCK_WAIT=5 drv cmd_land t49 --plan p 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(tfield t49 .landed_sha)" = "$m" ] && [ "$(tfield t49 .landed)" = true ] \
  && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] && [ "$(efield t49 .land.reconciled)" = true ] && [ "$(tfield t49 .state)" = canceled ] && no_land_wt \
  && ok "S10: recovery records the completed merge before checks, preserves cancellation and prunes crash scratch" || bad "receipt recovery ($rc $out)"

mk_task t50 ship true; commit_in t50 bare-recovery.txt x
out="$(OSRC_HOME="$ST" bash "$TMP/crash_land.sh" cmd_land j-t50 --check true 2>&1)"; rc=$?
m="$(git -C "$REPO" rev-parse main)"
[ "$rc" != 0 ] && [ "$(jq -r .land_intent.merged_sha "$ST/jobs/j-t50/evidence.json")" = "$m" ] \
  && ok "S10: bare-job landing also persists a receipt before the ref move" || bad "bare crash ($rc $out)"
out="$(OSRC_LAND_LOCK_WAIT=5 drv cmd_land j-t50 --check false 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r .land.reconciled "$ST/jobs/j-t50/evidence.json")" = true ] && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && ok "S10: bare-job receipt recovers without repeating checks or merges" || bad "bare recovery ($rc $out)"

cat > "$TMP/receipt_failure.sh" <<EOT
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
. "$LAND"
eval "_original_task_update() \$(declare -f _task_update | tail -n +2)"
_task_update() { case "\$3" in *land_intent*) return 1 ;; esac; _original_task_update "\$@"; }
"\$@"
EOT
mk_task t51 ship true; commit_in t51 no-receipt.txt x
out="$(OSRC_HOME="$ST" bash "$TMP/receipt_failure.sh" cmd_land t51 --plan p 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'could not persist landing receipt' <<<"$out" && [ "$(git -C "$REPO" rev-parse main)" = "$m" ] \
  && [ "$(tfield t51 .land_intent)" = null ] && ok "S10: receipt write failure refuses the ref move" || bad "receipt write failure ($rc $out)"

# Lock helpers are exercised with deterministic ownership interleavings.
cat > "$TMP/lock_probes.sh" <<'EOT'
case "$PROBE" in
  replacement)
    mkdir -p "$LOCK"; printf '123 stale\n' > "$LOCK/owner"
    mv() {
      if [ "$1" = "$LOCK" ]; then printf '456 replacement\n' > "$LOCK/owner"; fi
      command mv "$@"
    }
    _land_lock_break "$LOCK" '123 stale' 123 && exit 1
    [ "$(cat "$LOCK/owner")" = '456 replacement' ] ;;
  release)
    mkdir -p "$LOCK"; printf '456 replacement\n' > "$LOCK/owner"
    _LAND_LOCK="$LOCK"; _LAND_LOCK_OWNER='123 stale'
    _land_lock_release
    [ "$(cat "$LOCK/owner")" = '456 replacement' ] ;;
  publish)
    mv() { local a; for a in "$@"; do case "$a" in */owner.tmp) return 1 ;; esac; done; command mv "$@"; }
    _land_lock_acquire "$REPO" test && exit 1
    [ ! -d "$(_land_lock_dir "$REPO")" ] && [ -z "${_LAND_LOCK:-}" ] ;;
  permission)
    _pid_start_identity() { return 1; }
    kill() { echo 'kill: Operation not permitted' >&2; return 1; }
    ! _land_owner_dead 123 old ;;
  absent)
    _pid_start_identity() { return 1; }
    kill() { echo 'kill: No such process' >&2; return 1; }
    _land_owner_dead 123 old ;;
  guard)
    _fl_self_pid
    mkdir -p "$LOCK" "$LOCK.steal"; printf '123 stale\n' > "$LOCK/owner"
    printf '99999999 stale\n' > "$LOCK.steal/owner"
    _land_lock_break "$LOCK" '123 stale' "$_FL_PID" && [ ! -d "$LOCK" ] && [ ! -d "$LOCK.steal" ] ;;
  live_guard)
    _fl_self_pid
    mkdir -p "$LOCK" "$LOCK.steal"; printf '123 stale\n' > "$LOCK/owner"
    printf '%s %s\n' "$_FL_PID" "$(_pid_start_identity "$_FL_PID")" > "$LOCK.steal/owner"
    _land_lock_break "$LOCK" '123 stale' "$_FL_PID" && exit 1
    [ "$(cat "$LOCK/owner")" = '123 stale' ] && [ -d "$LOCK.steal" ] ;;
  orphan_guard)
    lk="$(_land_lock_dir "$REPO")"
    mkdir -p "$lk.steal"; printf '99999999 stale\n' > "$lk.steal/owner"
    OSRC_LAND_LOCK_WAIT=2 _land_lock_acquire "$REPO" probe || exit 1
    _land_lock_release
    [ ! -d "$lk" ] && [ ! -d "$lk.steal" ] ;;
  busy_guard)
    _fl_self_pid; lk="$(_land_lock_dir "$REPO")"
    mkdir -p "$lk.steal"
    printf '%s %s\n' "$_FL_PID" "$(_pid_start_identity "$_FL_PID")" > "$lk.steal/owner"
    OSRC_LAND_LOCK_WAIT=0 _land_lock_acquire "$REPO" probe && exit 1
    [ ! -d "$lk" ] && [ -d "$lk.steal" ] ;;
esac
EOT
for probe in replacement release publish permission absent guard live_guard orphan_guard busy_guard; do
  lock="$ST/locks/probe-$probe"
  if PROBE="$probe" LOCK="$lock" REPO="$REPO" drv source "$TMP/lock_probes.sh"; then
    ok "S8/S21/D2/D11: lock $probe probe"
  else bad "lock $probe probe"; fi
done
[ "$(drv _land_lock_dir "$REPO")" = "$(drv _land_lock_dir "$(wt_of t49)")" ] \
  && ok "D13: linked checkouts share one merge-queue lock" || bad "per-checkout lock keys"

printf 'done\r\n' > "$ST/jobs/j-t1/status"
drv _factory_job_ok j-t1 && ok "D14: CRLF terminal status is accepted" || bad "CRLF job status"
cat > "$TMP/crlf_probe.sh" <<'EOT'
jq() { (set -o pipefail; command jq "$@" | sed 's/$/\r/'); }
_factory_done_check p t1
EOT
out="$(drv source "$TMP/crlf_probe.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 't1 done' <<<"$out" && ok "D4: native jq CRLF output survives done-contract comparisons" || bad "CRLF jq ($rc $out)"
drv _fl_jq -e '.missing' <<< '{}' >/dev/null 2>&1 && bad "jq helper lost failing exit status" || ok "D4: normalized jq preserves failures"

for state in held failed canceled todo; do
  json="$(jq -cn --arg s "$state" '{state:$s}')"
  out="$(drv _land_state_refusal t99 "$json" 0 other-plan)"
  grep -q -- '--plan other-plan' <<<"$out" && ok "S15: $state hint names the exact plan" || bad "$state hint omits plan ($out)"
done

echo
echo "factory land: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
