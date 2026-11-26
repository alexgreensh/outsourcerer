#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_rv_factory.sh -- release review, second pass (F52-F58): the factory's verdicts, landing, gates and
# `plan start`. One section per finding; each failed on the reviewed commit. The done contract and land
# are shimmed (no model, no network); the task store is the real factory-tasks.sh.
# Usage: test_rv_factory.sh [F52 F53 ...]   (no argument: every section)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"; FLOW="$HERE/../factory-flow.sh"
[ -f "$SRC" ] && [ -f "$FLOW" ] && [ -f "$HERE/../factory-tasks.sh" ] || { echo "FAIL: cannot find the engine, factory-flow.sh or factory-tasks.sh"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-rv-factory.XXXXXX")" || { echo "FAIL: no scratch dir"; exit 1; }
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CEILING_DIRECTORIES="$TMP" HOME="$TMP/home" OSRC_HOME="$TMP/state" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
mkdir -p "$HOME" "$OSRC_HOME/jobs"; printf '[user]\n\tname = t\n\temail = t@example.com\n' > "$GIT_CONFIG_GLOBAL"
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
SEL="$*"
on() { [ -z "$SEL" ] && return 0; case " $SEL " in *" $1 "*) return 0 ;; esac; return 1; }

OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
. "$FLOW"; . "$HERE/../factory-tasks.sh"
export OSRC_HEARTBEAT_DISABLED=1 OSRC_FACTORY_GATE=off
_factory_done_check() { echo "done: job finished"; return 0; }
cmd_land() { echo "$1" >> "$TMP/landed"; _task_update "$3" "$1" '.landed = true' >/dev/null; echo "landed $1"; return 0; }

REPO="$TMP/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q; git -C "$REPO" commit -q --allow-empty -m init
mkplan() {   # <plan> then lines "tid|deps-csv|shape|retries"
  local plan="$1" line tid deps shape retries
  mkdir -p "$OSRC_HOME/plans/$plan/tasks"
  jq -n --arg n "$plan" --arg r "$REPO" --arg b "$(git -C "$REPO" symbolic-ref --short HEAD)" '{schema:1,name:$n,goal:"g",repo:$r,base_branch:$b,created:"x",updated:"x"}' > "$OSRC_HOME/plans/$plan/plan.json"
  shift
  for line in "$@"; do
    IFS='|' read -r tid deps shape retries <<EOF
$line
$line
EOF
    jq -n --arg id "$tid" --arg plan "$plan" --arg deps "$deps" --arg shape "${shape:-scout}" --argjson r "${retries:-1}" \
      '{schema:1,id:$id,plan:$plan,title:("task " + $id),shape:$shape,state:"todo",deps:($deps | split(",") | map(select(. != ""))),
        prompt:("do " + $id),spec:"",check:"",verb:"run",model:"",provider:"",deliver:"local",retries:$r,attempts:0,
        job:"",jobs:[],worktree:"",branch:"",base_sha:"",head_sha:"",hold:{reason:"",until:"",answer:""},result:"",evidence:"",
        flow:{name:"",stage:""},created:"x",updated:"x"}' > "$OSRC_HOME/plans/$plan/tasks/$tid.json"
  done
}

if on F52; then
  # A reviewer that says FAIL, quotes a lot of verdict-shaped lines and ends on PASS is ambiguous, not a
  # pass: under pipefail `grep | grep -q` could exit on the first match and SIGPIPE the middle grep once the
  # quoted lines outgrow the pipe buffer (16 KB on macOS, 64 KB on Linux).
  mkdir -p "$OSRC_JOBS/v52"
  { echo 'VERDICT: FAIL - broken'; i=0; while [ "$i" -lt 3000 ]; do echo "> VERDICT: the earlier note on line $i reads fine to me"; i=$((i + 1)); done; echo 'VERDICT: PASS'; } > "$OSRC_JOBS/v52/last.txt"
  n=0; i=0; while [ "$i" -lt 10 ]; do _ff_verdict v52; [ "$_FF_VERDICT" = ambiguous ] && n=$((n + 1)); i=$((i + 1)); done
  [ "$n" = 10 ] && ok "F52: FAIL, 3000 quoted verdict lines (about 200 KB, past any pipe buffer), then PASS: ambiguous 10 of 10" || bad "F52: ambiguous only $n of 10 (last: $_FF_VERDICT)"
  { echo 'VERDICT: PASS - fine'; i=0; while [ "$i" -lt 3000 ]; do echo "> VERDICT: the earlier note on line $i reads fine to me"; i=$((i + 1)); done; echo 'VERDICT: FAIL - one bug'; } > "$OSRC_JOBS/v52/last.txt"
  _ff_verdict v52; [ "$_FF_VERDICT" = ambiguous ] && ok "F52: PASS, quotes, then FAIL is ambiguous" || bad "F52: reversed case reads $_FF_VERDICT"
  printf 'notes\nVERDICT: PASS\n' > "$OSRC_JOBS/v52/last.txt"; _ff_verdict v52
  [ "$_FF_VERDICT" = pass ] && ok "F52: a plain PASS still passes" || bad "F52: plain PASS reads $_FF_VERDICT"
fi

# gate <dir> [plan]: _osrc_fp_gate_can_run from <dir> with the built-in readings quiet -> "rc=N reason"
gate() { ( cd "$1" && unset OSRC_FACTORY_GATE && _osrc_disk_gate() { return 0; } && _osrc_fp_load1() { :; } && _osrc_fp_swap_pct() { :; }
  _osrc_fp_gate_can_run ${2:+"$2"} 2>/dev/null; echo "rc=$? $_OSRC_FP_GATE_REASON" ); }

# start <plan> <file> [args...]: `plan start` with the scheduler stubbed (no launch) -> output, rc in $?
start() { ( cd "$REPO" && cmd_plan_run() { :; } && cmd_plan_start "$@" ) 2>&1; }

if on F53; then
  # The time cap stops an --auto-land run after a build is done: the captain is told to land it by hand,
  # so a later `plan run` (without --auto-land) must not land it on its own.
  mkplan cap53 't1||ship|0'; _task_update cap53 t1 '.state = "verifying"' >/dev/null; rm -f "$TMP/landed"
  ( _FF_AUTO_LAND=1; _FF_DEADLINE=1; _ff_verify cap53 t1 "$(_task_list cap53)" ) > "$TMP/f53.out" 2>&1
  t="$(_task_get cap53 t1)"
  grep -q 'not landed: time cap reached' "$TMP/f53.out" && jq -e '.state == "done" and ((.auto_land_pending // false) | not) and (.land_error | test("time cap"))' >/dev/null <<<"$t" \
    && ok "F53: at the time cap the build is done, not landed, and no landing is left pending" || bad "F53: after the cap: $(jq -c '{state, auto_land_pending, land_error}' <<<"$t")"
  ( _FF_AUTO_LAND=0; _FF_DEADLINE=0; _ff_reconcile cap53 ) >/dev/null 2>&1
  [ ! -s "$TMP/landed" ] && ok "F53: the next plan run without --auto-land does not land it" || bad "F53: reconcile landed $(cat "$TMP/landed")"
  ( _FF_AUTO_LAND=1; _FF_DEADLINE=0; _ff_reconcile cap53 ) >/dev/null 2>&1
  [ ! -s "$TMP/landed" ] && ok "F53: nor does a later --auto-land run (land_error stands until the captain lands it)" || bad "F53: --auto-land replay landed $(cat "$TMP/landed")"
fi

if on F54; then
  # A gate the repo profile names but that is not there holds launches (a typo must not remove the gate).
  printf '[factory]\ngate = "scripts/gate-typo.sh"\n' > "$REPO/.outsourcerer.toml"
  r="$(OSRC_FACTORY_ROOT="$REPO" gate "$REPO")"
  case "$r" in "rc=1 "*"not a file"*) ok "F54: a named gate that is not a file holds launches" ;; *) bad "F54: missing gate: $r" ;; esac
  # A relative gate with no git root to resolve against holds too, never the current folder's script.
  mkdir -p "$TMP/nogit"; printf 'echo ran > "%s/f54.ran"; exit 0\n' "$TMP" > "$TMP/nogit/gate.sh"
  printf '[factory]\ngate = "gate.sh"\n' > "$TMP/p54.toml"
  r="$(OSRC_FACTORY_ROOT="$TMP/nogit" OSRC_FACTORY_PROFILE="$TMP/p54.toml" gate "$TMP/nogit")"
  case "$r" in "rc=1 "*) [ ! -e "$TMP/f54.ran" ] && ok "F54: a relative gate with no repo root holds and runs nothing" || bad "F54: ran the cwd's gate.sh ($r)" ;;
    *) bad "F54: relative gate, no root: $r (ran: $([ -e "$TMP/f54.ran" ] && echo yes || echo no))" ;; esac
  rm -f "$REPO/.outsourcerer.toml"
fi

echo "RESULTS: $pass pass $fail fail"
[ "$fail" -eq 0 ]
