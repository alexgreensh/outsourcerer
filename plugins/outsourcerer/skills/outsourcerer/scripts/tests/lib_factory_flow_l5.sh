# lib_factory_flow_l5.sh -- lane osrc-l5 checks (parallel plans, gate, review cap, plan start).
# Sourced by test_factory_flow.sh after its fixtures (mkplan, st, setlt, the fake job seam); not a suite.

# ------------------------------------------------------------------ lane osrc-l5: parallel by default
# Incident 1: independent tasks start together, up to the cap, in ONE pass (not one per pass).
mkplan par 't1||scout|0' 't2||scout|0' 't3||scout|0' 't4||scout|0'
for t in t1 t2 t3 t4; do echo running > "$TMP/outcomes/$t"; done
: > "$TMP/launches"
out="$( cmd_plan_run par --once --max-parallel 3 2>&1 )"
[ "$(grep -c '^par/' "$TMP/launches")" = 3 ] && [ "$(st par t4)" = todo ] \
  && ok "L5-1: three independent tasks start in one pass at cap 3; the fourth waits" || bad "L5-1: launches=$(cat "$TMP/launches") $out"
# Files never order tasks: each ship task branches from the plan base, so a wait would not give the
# later task the earlier work (review P2 5). Overlap is reported by plan start instead.
mkplan own 't1||ship|0' 't2||ship|0' 't3||ship|0'
_task_update own t1 '.files = ["src"]' >/dev/null; _task_update own t2 '.files = ["src/a.sh"]' >/dev/null; _task_update own t3 '.files = ["docs"]' >/dev/null
: > "$TMP/launches"
out="$( cmd_plan_run own --once --max-parallel 3 2>&1 )"
[ "$(grep -c '^own/' "$TMP/launches")" = 3 ] && ! grep -q 'waits' <<<"$out" \
  && ok "L5-1: shared files do not delay a task (no wait that cannot carry the earlier work)" || bad "L5-1 files: $(st own t2) $out"
for t in t1 t2 t3 t4; do rm -f "$TMP/outcomes/$t"; done

# Incident 2: a held decision with a default and deadline does not stop unrelated work, and the
# default applies at the deadline. A paid decision never applies by itself.
mkplan dec 't1||scout|0' 't2||scout|0' 't3||scout|0'
( cmd_task hold t2 --plan dec --reason "pick A or B" --default A --until +1h >/dev/null 2>&1 )
( cmd_task hold t3 --plan dec --reason "buy the bigger runner?" --default yes --until +1h --risk paid >/dev/null 2>&1 )
: > "$TMP/launches"
( cmd_plan_run dec --once >/dev/null 2>&1 )
[ "$(st dec t1)" != todo ] && [ "$(st dec t2)" = held ] && ok "L5-2: an open decision does not stop unrelated tasks" || bad "L5-2: t1=$(st dec t1) t2=$(st dec t2)"
_task_update dec t2 '.hold.until_epoch = 1' >/dev/null; _task_update dec t3 '.hold.until_epoch = 1' >/dev/null
out="$( cmd_plan_run dec --once 2>&1 )"
_task_get dec t2 | jq -e '.hold.answer == "A" and .hold.defaulted == true' >/dev/null && grep -q '^dec/t2$' "$TMP/launches" \
  && ok "L5-2: at the deadline the default applies and the task runs" || bad "L5-2 default: $(_task_get dec t2 | jq -c '{state,hold}') $out"
[ "$(st dec t3)" = held ] && ! grep -q '^dec/t3$' "$TMP/launches" && ok "L5-2: a paid decision never auto-applies its default" || bad "L5-2 paid: $(st dec t3)"
( cmd_task hold t1 --plan dec --reason q --risk sometimes >/dev/null 2>&1 ) && bad "L5-2: unknown --risk accepted" || ok "L5-2: unknown --risk is refused"

# Incident 3: a fourth review round needs an escalation record.
( cmd_flow run council-build --plan cap --repo "$REPO" --var goal=g >/dev/null 2>&1 )
for t in t1 t2 t3; do _task_update cap "$t" '.state = "done"' >/dev/null; done
_task_update cap t4 '.retries = 9' >/dev/null
echo "VERDICT: FAIL - still broken" > "$TMP/lasttxt-t5"
out="$( cmd_plan_run cap --interval 1 2>&1 )"; rc=$?
esc="$OSRC_HOME/plans/cap/escalations/t5-r4.json"
[ "$rc" = 3 ] && [ "$(cat "$TMP/count-cap-t5")" = 3 ] && [ "$(st cap t5)" = held ] && jq -e '.round == 4 and .approved == false' "$esc" >/dev/null \
  && _task_get cap t5 | jq -e '(.hold.reason | test("review cap is 3")) and (.hold.reason | test("approved") | not)' >/dev/null \
  && ok "L5-3: round four is held after three reviews; the record is pending and nothing asks to edit it" || bad "L5-3: rc=$rc reviews=$(cat "$TMP/count-cap-t5") $(_task_get cap t5 | jq -c '{state,review_rounds,hold}') $out"
# The captain's release is the approval: it runs round four and stamps the record (review P2 1).
rm -f "$TMP/lasttxt-t5"; setlt cap t5 "VERDICT: PASS" 4
( cmd_task release t5 --plan cap --answer "fixture fixed upstream" >/dev/null 2>&1 )
( cmd_plan_run cap --interval 1 >/dev/null 2>&1 )
[ "$(cat "$TMP/count-cap-t5")" = 4 ] && jq -e '.approved == true and .status == "approved" and .answer == "fixture fixed upstream"' "$esc" >/dev/null \
  && ok "L5-3: task release runs round four and stamps the escalation record approved" || bad "L5-3 release: reviews=$(cat "$TMP/count-cap-t5") $(st cap t5) $(cat "$esc")"

r5="$(_osrc_fp_escalation_write cap t5 5 "round 5 after FAIL: again")"
_osrc_fp_escalation_approve cap t5 "second answer"
[ "$r5" = "$OSRC_HOME/plans/cap/escalations/t5-r5.json" ] && jq -e '.answer == "fixture fixed upstream"' "$esc" >/dev/null \
  && jq -e '.round == 5 and .approved == true and .answer == "second answer"' "$r5" >/dev/null \
  && ok "L5-3: each round keeps its own record; a later approval stamps only the newest" || bad "L5-3 rounds: $(cat "$esc") $(cat "$r5" 2>/dev/null)"
# The profile reader stops matching without closing its pipe early (no 'Broken pipe' noise).
{ echo '[gate]'; echo 'k = first'; for i in $(seq 1 3000); do echo "k$i = v$i"; done; } > "$TMP/big.profile"
e="$( OSRC_FACTORY_PROFILE="$TMP/big.profile" _osrc_fp_get gate k 2>&1 >/dev/null )"; v="$( OSRC_FACTORY_PROFILE="$TMP/big.profile" _osrc_fp_get gate k 2>/dev/null )"
[ "$v" = first ] && [ -z "$e" ] && ok "L5: the profile reader prints the first match and writes nothing to stderr" || bad "L5 profile reader: v=$v err=$e"

# Launch cap and gate settings.
[ "$(OSRC_FACTORY_PARALLEL=5 _osrc_fp_max_parallel)" = 5 ] && ok "L5: the cap reads OSRC_FACTORY_PARALLEL" || bad "L5 cap env"
( _osrc_fp_max_parallel 0 ) 2>/dev/null && bad "L5: a cap of 0 was accepted" || ok "L5: the cap refuses 0"
case "$(OSRC_FACTORY_PARALLEL= OSRC_FACTORY_PROFILE=/nonexistent _osrc_fp_max_parallel)" in 1|2|3) ok "L5: a default cap exists without settings";; *) bad "L5 default cap";; esac
# Gate checks never read this machine: disk, load and swap come through the seams the gate reads
# (_osrc_free_kb, _osrc_fp_load1, _osrc_fp_ncpu, and uname + osrc_mac_load for macOS swap). The
# defaults below are a healthy machine; each check overrides one reading (review P2 2).
calm() {
  _osrc_free_kb() { echo $(( 500 * 1048576 )); }; _osrc_fp_load1() { echo 0.50; }; _osrc_fp_ncpu() { echo 4; }
  uname() { echo Linux; }; osrc_mac_load() { echo 'load_per_core=0.12 swap_pct=0 (load1=0.5 cores=4 swap=0M/0M)'; }
  _osrc_cleanup_items() { :; }
  unset OSRC_FACTORY_GATE OSRC_DISK_MIN_GB OSRC_FACTORY_LOAD_MAX OSRC_FACTORY_SWAP_MAX_PCT
}
printf '#!/bin/sh\necho "nightly backup running"; exit 1\n' > "$TMP/gate.sh"; chmod +x "$TMP/gate.sh"
mkplan gated 't1||scout|0'
out="$( calm; OSRC_FACTORY_GATE="$TMP/gate.sh" cmd_plan_run gated --once 2>&1 )"
[ "$(st gated t1)" = todo ] && grep -q 'launches paused: nightly backup running' <<<"$out" && ok "L5: a repo gate that says no pauses launches" || bad "L5 gate: $out"
printf '#!/bin/sh\nexit 7\n' > "$TMP/gate.sh"
out="$( calm; OSRC_FACTORY_GATE="$TMP/gate.sh" cmd_plan_run gated --once 2>&1 )"
[ "$(st gated t1)" = todo ] && grep -q 'failed (rc=7); holding this pass' <<<"$out" && ok "L5: a broken gate fails closed: holds the pass, names the rc" || bad "L5 broken gate: $out"
( calm; OSRC_FACTORY_GATE="$TMP/gate.sh"; printf '#!/bin/sh\nexit 0\n' > "$TMP/gate.sh"; cmd_plan_run gated --once >/dev/null 2>&1 )
[ "$(st gated t1)" != todo ] && ok "L5: once the gate answers 0 the held plan launches (no wedge)" || bad "L5 gate fixed but plan still held"
out="$( calm; OSRC_FACTORY_GATE="/x/g.sh --fast"; _osrc_fp_gate_can_run 2>&1; echo "rc=$? $_OSRC_FP_GATE_REASON" )"
case "$out" in "rc=1 "*"is not a file"*) ok "L5: a gate that is not a file holds launches (fails closed, release review F54)" ;; *) bad "L5 missing gate: $out" ;; esac
( calm; unset -f _osrc_fp_load1 _osrc_fp_ncpu osrc_mac_load; _osrc_fp_ncpu() { :; }; _osrc_fp_gate_can_run 2>/dev/null ) && ok "L5: missing load/swap readings never pause launches" || bad "L5: a missing reading paused launches"
( calm; unset -f _osrc_disk_gate; _osrc_fp_gate_can_run 2>/dev/null ) && bad "L5: a missing disk gate let a pass launch" || ok "L5: a missing disk gate holds the pass"
# A loaded Mac on its usual high swap ratio still launches; only its own threshold pauses (P2 4).
( calm; uname() { echo Darwin; }; osrc_mac_load() { echo 'load_per_core=0.50 swap_pct=85 (load1=4 cores=8 swap=850M/1000M)'; }; _osrc_fp_gate_can_run ) \
  && ok "L5: macOS swap at 85% does not pause plan launches" || bad "L5: 85% swap paused launches"
( calm; uname() { echo Darwin; }; osrc_mac_load() { echo 'load_per_core=0.50 swap_pct=97 (load1=4 cores=8 swap=970M/1000M)'; }; _osrc_fp_gate_can_run ) \
  && ok "L5: the swap check is off by default (a healthy Mac sits at 90%+ swap)" || bad "L5: 97% swap paused launches with no setting"
out="$( calm; export OSRC_FACTORY_SWAP_MAX_PCT=95; uname() { echo Darwin; }; osrc_mac_load() { echo 'load_per_core=0.50 swap_pct=97 (load1=4 cores=8 swap=970M/1000M)'; }; _osrc_fp_gate_can_run || echo "$_OSRC_FP_GATE_REASON" )"
grep -q 'swap is 97% used, over 95% (OSRC_FACTORY_SWAP_MAX_PCT' <<<"$out" && ok "L5: macOS swap over its own threshold pauses and names the reading and setting" || bad "L5 swap: $out"
out="$( calm; _osrc_fp_load1() { echo 12.00; }; _osrc_fp_gate_can_run || echo "$_OSRC_FP_GATE_REASON" )"
grep -q 'load is 12.00 on 4 cores (3.00 per core), over 2 per core (OSRC_FACTORY_LOAD_MAX' <<<"$out" && ok "L5: high load pauses and names OSRC_FACTORY_LOAD_MAX" || bad "L5 load: $out"
# Disk: the launch path's own gate decides, cleanup ack included (P2 3).
out="$( calm; _osrc_free_kb() { echo $(( 8 * 1048576 )); }; _osrc_cleanup_items() { echo '{"verdict":"ASK","path":"/w/old","kind":"worktree"}'; }
  _osrc_fp_gate_can_run || echo "no: $_OSRC_FP_GATE_REASON"; _osrc_cleanup_ack >/dev/null; _osrc_fp_gate_can_run && echo "acked: go" )"
grep -q 'no: .*need your decision.*OSRC_DISK_MIN_GB=0 in .*/disk-policy/settings' <<<"$out" && grep -q 'acked: go' <<<"$out" \
  && ok "L5: low disk pauses until the cleanup ASK list is acked, as at launch" || bad "L5 disk ack: $out"
# Floors come only from the settings file (lib/disk_policy.sh): the gate's hint must name it, and an
# inherited export must not open the gate.
( calm; _osrc_free_kb() { echo $(( 8 * 1048576 )); }; OSRC_DISK_MIN_GB=0 _osrc_fp_gate_can_run ) 2>/dev/null && bad "L5: an OSRC_DISK_MIN_GB export opened the disk gate" || ok "L5: an OSRC_DISK_MIN_GB export does not move the floor"
( calm; mkdir -p "$OSRC_HOME/disk-policy"; echo OSRC_DISK_MIN_GB=0 > "$OSRC_HOME/disk-policy/settings"; _osrc_free_kb() { echo $(( 8 * 1048576 )); }
  _osrc_fp_gate_can_run; r=$?; rm -f "$OSRC_HOME/disk-policy/settings"; exit $r ) && ok "L5: OSRC_DISK_MIN_GB=0 in the settings file lifts the disk pause" || bad "L5: disk override ignored"
# A pause prints once, not on every pass.
mkplan quiet 't1||scout|0'
out="$( calm; _osrc_fp_load1() { echo 99; }; cmd_plan_run quiet --once 2>&1; cmd_plan_run quiet --once 2>&1 )"
[ "$(grep -c 'launches paused' <<<"$out")" = 1 ] && ok "L5: the pause reason prints when it changes, not every pass" || bad "L5 repeat: $out"

# Repo profile: optional; quoted keys, comments; feeds the check and the worker's repo rules.
cat > "$TMP/profile.toml" <<'TOML'
# example profile
[factory]
check = "make lint"   # free and local
parallel = 4
[factory.heavy]
"npm test" = "a cloud lane"
[factory.bench]
"bench/" = true
TOML
rules="$(OSRC_FACTORY_PROFILE="$TMP/profile.toml" _osrc_fp_brief_rules bench/x.c src/a.c)"
[ "$(OSRC_FACTORY_PROFILE="$TMP/profile.toml" _osrc_fp_check)" = "make lint" ] && [ "$(OSRC_FACTORY_PROFILE="$TMP/profile.toml" _osrc_fp_max_parallel)" = 4 ] \
  && grep -q 'Heavy command `npm test` runs on a cloud lane' <<<"$rules" && grep -q 'justified for: bench/x.c$' <<<"$rules" \
  && ok "L5: the repo profile gives check, cap, heavy commands and bench paths" || bad "L5 profile: $rules"
[ -z "$(OSRC_FACTORY_PROFILE=/nonexistent _osrc_fp_brief_rules a.c)" ] && ok "L5: no profile, no extra brief text" || bad "L5 empty profile"

# plan start: one entry from a task list to a running plan.
cat > "$TMP/tasks.txt" <<'TASKS'
# key | what to do | fields
api  | add the health endpoint | files=src/api
ui   | show health in the footer | after=api | files=src/ui
docs | document the endpoint | files=docs
lint | tidy the api module | files=src/api/util.sh
TASKS
out="$( cd "$REPO" && cmd_plan_start ps "$TMP/tasks.txt" --max-parallel 3 --dry-run 2>&1 )"
grep -q 'ui *after api (declared)' <<<"$out" && grep -q 'lint *starts now' <<<"$out" \
  && grep -q 'note: lint and api both touch src/api/util.sh -> src/api' <<<"$out" \
  && grep -q 'docs *starts now' <<<"$out" && [ ! -d "$OSRC_HOME/plans/ps" ] \
  && ok "L5: plan start --dry-run shows the order, reports shared files, and creates nothing" || bad "L5 dry run: $out"
for t in t1 t2 t3 t4; do echo running > "$TMP/outcomes/$t"; done
: > "$TMP/launches"
out="$( cd "$REPO" && OSRC_FACTORY_CHECK="git diff --check" cmd_plan_start ps "$TMP/tasks.txt" --max-parallel 3 2>&1 )"; rc=$?
[ "$rc" = 0 ] && [ "$(sort "$TMP/launches" | tr '\n' ' ')" = "ps/t1 ps/t3 ps/t4 " ] && _task_get ps t2 | jq -e '.deps == ["t1"]' >/dev/null \
  && _task_get ps t4 | jq -e '.files == ["src/api/util.sh"] and .shape == "ship" and .check == "git diff --check"' >/dev/null \
  && ok "L5: plan start adds every task and launches the independent ones together" || bad "L5 plan start rc=$rc launches=$(cat "$TMP/launches") $out"
for t in t1 t2 t3 t4; do rm -f "$TMP/outcomes/$t"; done
printf 'other | something unrelated\n' > "$TMP/typo.txt"; n0="$(_task_list ps | jq length)"
out="$( cd "$REPO" && cmd_plan_start ps "$TMP/typo.txt" 2>&1 )" && bad "L5: plan start reused a plan with no shared task" \
  || { [ "$(_task_list ps | jq length)" = "$n0" ] && grep -q 'already exists and none of its tasks' <<<"$out" \
       && ok "L5: plan start refuses an existing plan that shares no task, and adds nothing" || bad "L5 reuse: $out"; }
printf 'a | x\nb | y | after=c\nc | z\n' > "$TMP/bad.txt"
( cd "$REPO" && cmd_plan_start pbad "$TMP/bad.txt" ) >/dev/null 2>&1 && bad "L5: forward after= accepted" || { [ ! -d "$OSRC_HOME/plans/pbad" ] && ok "L5: after= must name an earlier line; nothing is created" || bad "L5: bad list left a plan"; }
printf 'a | x\nb | y | after=*\n' > "$TMP/bad.txt"
( cd "$REPO" && cmd_plan_start pbad "$TMP/bad.txt" ) >/dev/null 2>&1 && bad "L5: after=* accepted" || ok "L5: after= takes keys only (no glob)"
# Dotted keys: after=a.b names a.b only, never axb (a regex dot matched both).
printf 'a.b | x\naxb | y\nc | z | after=a.b\n' > "$TMP/dot.txt"
( cd "$REPO" && cmd_plan_start pdot "$TMP/dot.txt" --dry-run ) >/dev/null 2>&1
( cd "$REPO" && cmd_plan_start pdot "$TMP/dot.txt" ) >/dev/null 2>&1
_task_get pdot t3 | jq -e '.deps == ["t1"]' >/dev/null && ok "L5: a dotted key names exactly one task" || bad "L5 dotted: $(_task_get pdot t3 | jq -c .deps)"
# Printed order matches what starts: b has no after, so it starts now (no file wait any more).
printf 'z | x\na | y | after=z | files=src\nb | w | files=src\n' > "$TMP/ord.txt"
out="$( cd "$REPO" && cmd_plan_start pord "$TMP/ord.txt" --dry-run 2>&1 )"
grep -q 'b *starts now' <<<"$out" && grep -q 'a *after z (declared)' <<<"$out" && ok "L5: the printed order matches the scheduler" || bad "L5 order: $out"
# A decision with a default, deadline and risk, and a rerun that finishes a half-built plan.
printf 'pick | choose the cache | hold=redis or memcached? | default=redis | until=+2h\nbuy | size the runner | hold=buy the bigger runner? | default=yes | until=+1h | risk=paid\nlast | y\n' > "$TMP/hold.txt"
( cd "$REPO" && cmd_plan_start phold "$TMP/hold.txt" ) >/dev/null 2>&1
_task_get phold t1 | jq -e '.state == "held" and .hold.default == "redis" and .hold.until_epoch > 0' >/dev/null \
  && _task_get phold t2 | jq -e '.state == "held" and .hold.risk == "paid"' >/dev/null \
  && ok "L5: plan start carries a decision's default, deadline and risk" || bad "L5 hold: $(_task_get phold t1 | jq -c .hold) $(_task_get phold t2 | jq -c .hold)"
printf 'a | x\nb | y | after=a\n' > "$TMP/re.txt"
mkplan pre; _task_cli_add a --prompt x --plan pre >/dev/null 2>&1
( cd "$REPO" && cmd_plan_start pre "$TMP/re.txt" ) >/dev/null 2>&1
[ "$(_task_list pre | jq length)" = 2 ] && _task_get pre t2 | jq -e '.title == "b" and .deps == ["t1"]' >/dev/null \
  && ok "L5: a rerun reuses the plan and adds only the missing tasks" || bad "L5 rerun: $(_task_list pre | jq -c 'map({id,title,deps})')"

