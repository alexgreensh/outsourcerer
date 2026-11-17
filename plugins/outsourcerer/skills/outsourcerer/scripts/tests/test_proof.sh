#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_proof.sh -- lib/proof.sh (proof.json, READY gate, three-rounds cap, stamps) and lib/review_sev.sh
# (severity routing, re-review delta). Local git repos only, no network, no tmux, no model.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "${TMPDIR%/}/.test-proof.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

export OSRC_HOME="$TMP/state" HOME="$TMP/home" CLAUDE_CODE_SESSION_ID="sess-test-s2"
mkdir -p "$OSRC_HOME" "$HOME"
export OSRC_SELF=osrc OSRC_TIME_UNIT=1 OSRC_REMOTE_POLL_SECS=0 OSRC_PROOF_NO_SEND=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
OSRC_SOURCED=1; export OSRC_SOURCED; set --; . "$SRC" >/dev/null 2>&1
for fn in cmd_guards cmd_proof osrc_proof_gate osrc_proof_handin _osrc_sev_verdict _osrc_review_write_brief _sv_observe_watch; do
  type -t "$fn" >/dev/null || { echo "FAIL: $fn not loaded"; exit 1; }
done
ok "lib/proof.sh and lib/review_sev.sh load with the engine"
P() { ( cmd_proof "$@" ); }   # die exits the subshell, never the test

# ---- a lane worktree: main with a verify script, branch lane1 ----------------------------------
R="$TMP/repo"; mkdir -p "$R/.outsourcerer"
( cd "$R" && git init -q -b main && printf '#!/bin/sh\necho "verify: 5 passed, 0 failed"\n' > .outsourcerer/verify \
  && chmod +x .outsourcerer/verify && echo a > a.txt && git add -A && git commit -q -m base && git checkout -q -b lane1 \
  && echo b > b.txt && git add -A && git commit -q -m work )
H1="$(git -C "$R" rev-parse HEAD)"

echo "=== proof run writes proof.json for the head sha ==="
out="$(P run --lane lane1 --dir "$R" --cmd 'echo "test summary: 139 passed, 0 failed"')"; rc=$?
PF="$OSRC_HOME/proof/lane1/proof.json"
[ "$rc" = 0 ] && [ -f "$PF" ] && ok "proof run exits 0 and writes the lane folder's proof.json" || bad "proof run rc=$rc out=[$out]"
[ "$(jq -r .head "$PF")" = "$H1" ] && ok "proof.json records the head sha" || bad "head: $(jq -r .head "$PF")"
[ "$(jq -r '.method + "|" + .stamp' "$PF")" = "verify-run|proved: 144 pass, 0 fail" ] && ok "--cmd adds to the base verify (139 + 5): stamp 'proved: 144 pass, 0 fail'" || bad "stamp: $(jq -c '{method,stamp}' "$PF")"
[ "$(jq -r '.commands[0].exit, (.commands[0].tail|length), .guards.passed, .guards.base_sha == .base_sha, .base_sha == $m' --arg m "$(git -C "$R" rev-parse main)" "$PF" | tr '\n' ' ')" = "0 1 true true true " ] \
  && ok "command exit, output tail, and the REAL guards verdict run against base_sha (main's sha)" || bad "record: $(jq -c . "$PF")"
grep -q 'proved: 144 pass' <<<"$out" && ok "proof run prints the stamp" || bad "out: $out"

echo "=== a proof for an older sha does not count ==="
gate="$(osrc_proof_gate lane1)"; [ $? = 0 ] && ok "gate accepts the proof for the current head ($gate)" || bad "gate: $gate"
( cd "$R" && echo c > c.txt && git add -A && git commit -q -m more )
gate="$(osrc_proof_gate lane1)"; rc=$?
[ "$rc" = 1 ] && grep -q "proof is for ${H1:0:7} but the head is" <<<"$gate" && ok "stale-sha proof rejected with the reason" || bad "stale gate rc=$rc [$gate]"
gate="$(P check lane1 "$H1")"; [ $? = 0 ] && ok "proof check <lane> <sha> accepts the exact sha it proved" || bad "check old sha: $gate"

echo "=== verify script is read from the BASE ref; an edit in the lane is flagged ==="
( cd "$R" && printf '#!/bin/sh\necho "999 passed"\n' > .outsourcerer/verify && git commit -qam "edit verify" )
out="$(P run --lane lane1 --dir "$R" --base main)"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '.method + "|" + (.totals.pass|tostring) + "|" + (.checks_changed|tostring)' "$PF")" = "verify-run|5|true" ] \
  && ok "no --cmd: runs .outsourcerer/verify from base (5 passed, not the lane's 999), checks_changed true" || bad "verify: rc=$rc $(jq -c '{method,totals,checks_changed,commands}' "$PF")"

echo "=== a done contract check is a proof source ==="
mkdir -p "$TMP/r2" && ( cd "$TMP/r2" && git init -q -b main && echo x > x && git add -A && git commit -q -m x && git checkout -q -b work )
mkdir -p "$OSRC_HOME/done"; jq -n --arg c "$TMP/r2" '{spec:"check:echo ok 1; echo ok 2", cwd:$c}' > "$OSRC_HOME/done/dc1.json"
P run --lane dc1 --dir "$TMP/r2" >/dev/null
[ "$(jq -r '.method + "|" + .commands[0].cmd' "$OSRC_HOME/proof/dc1/proof.json")" = "tests|echo ok 1; echo ok 2" ] && ok "check: from the lane's done contract runs when no --cmd" || bad "dc: $(jq -c . "$OSRC_HOME/proof/dc1/proof.json")"
out="$(P run --lane nochecks --dir "$TMP/r2" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q -- '--method none --reason' <<<"$out" && ok "no checks anywhere: refuses and names the ways out" || bad "nochecks rc=$rc [$out]"

echo "=== method none needs a reason ==="
out="$(P run --lane docs1 --dir "$TMP/r2" --method none 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'needs --reason' <<<"$out" && ok "--method none without --reason is refused" || bad "none no reason: rc=$rc [$out]"
P run --lane docs1 --dir "$TMP/r2" --method none --reason "docs-only change" >/dev/null
[ "$(jq -r '.stamp + "|" + (.ok|tostring)' "$OSRC_HOME/proof/docs1/proof.json")" = "unverified: docs-only change|true" ] \
  && ok "method none + reason: stamp 'unverified: <reason>'" || bad "none: $(jq -c . "$OSRC_HOME/proof/docs1/proof.json")"

echo "=== uncommitted tracked changes never prove the head ==="
( cd "$TMP/r2" && echo dirty >> x )
P run --lane dirty1 --dir "$TMP/r2" --cmd true >/dev/null 2>&1
[ "$(jq -r '.ok|tostring' "$OSRC_HOME/proof/dirty1/proof.json")" = false ] && ok "dirty worktree: proof fails" || bad "dirty: $(jq -c . "$OSRC_HOME/proof/dirty1/proof.json")"
( cd "$TMP/r2" && git checkout -q -- x ); P reset dirty1 >/dev/null

echo "=== guards hook (lane S1 round-3 contract: lib/guards.sh header) ==="
# Stand-in for S1's cmd_guards: logs its argv, prints a human line then the JSON verdict, exits like S1.
REAL_GUARDS="$(declare -f cmd_guards)"
cmd_guards() { printf '%s\n' "$*" >> "$TMP/guards.args"; echo "guard lines"; ${GPRETTY:-echo} "$GJSON"; [ "$(jq -r .passed <<<"$GJSON")" = true ]; }
pretty() { jq . <<<"$1"; }
G() { P reset g1 >/dev/null; P run --lane g1 --dir "$TMP/r2" --cmd true >/dev/null 2>&1; jq -c . "$OSRC_HOME/proof/g1/proof.json"; }
GJSON='{"mode":"enforce","passed":false,"failed":[{"guard":"slop","mode":"enforce","what":["a.sh:3 # added X"],"fix":"delete the comment"}],"guards_changed":false,"allowed":null,"reviewer_required":false}'
out="$(P run --lane g0 --dir "$TMP/r2" --cmd true 2>&1)"
grep -q '^  WHAT: a.sh:3 # added X' <<<"$out" && grep -q '^  FIX: delete the comment' <<<"$out" && ok "a guards block prints each WHAT and FIX (the retry brief)" || bad "what/fix: $out"
g="$(G)"; [ "$(jq -r '[.ok, .guards.failed[0].guard] | join(" ")' <<<"$g")" = "false slop" ] && ok "passed:false fails the proof; the guards JSON is stored under .guards" || bad "guards: $g"
grep -q 'guards blocked the change: slop' <<<"$(jq -r .stamp <<<"$g")" && ok "the stamp names the blocking guard" || bad "stamp: $(jq -r .stamp <<<"$g")"
[ "$(tail -1 "$TMP/guards.args")" = "run --json --base $(git -C "$TMP/r2" rev-parse main) --lane g1" ] && ok "guards run is called with an explicit --base (the lane's base) and --lane" || bad "args: $(tail -1 "$TMP/guards.args")"
GJSON='{"mode":"observe","passed":false,"failed":[],"guards_changed":false,"allowed":null,"reviewer_required":false}'
g="$(G)"; [ "$(jq -r .ok <<<"$g")" = false ] && ok "passed:false fails even in observe mode with an empty failed list (passed is the verdict)" || bad "observe false: $g"
GJSON='{"mode":"observe","passed":true,"failed":[{"guard":"slop-inflation","mode":"observe","what":["x"],"fix":"y"}],"guards_changed":false,"allowed":null,"reviewer_required":false}'
g="$(G)"; [ "$(jq -r '[.ok, .reviewer_required] | join(" ")' <<<"$g")" = "true false" ] && ok "passed:true with a non-empty failed list (observe hits) passes" || bad "observe true: $g"
GJSON='{"mode":"enforce","passed":true,"failed":[{"guard":"slop","mode":"enforce","what":["b.sh:7 # hack"],"fix":"fix it"}],"guards_changed":false,"allowed":"allowed after 2 blocks","reviewer_required":true}'
g="$(GPRETTY=pretty G)"
[ "$(jq -r '[.ok, .reviewer_required] | join(" ")' <<<"$g")" = "true true" ] && ok "released-after-blocks pass: proof ok, reviewer_required carried (pretty-printed JSON read)" || bad "rr: $g"
grep -q 'reviewer must look (guards allowed: allowed after 2 blocks)' <<<"$(jq -r .stamp <<<"$g")" && ok "the stamp says the reviewer must look" || bad "rr stamp: $(jq -r .stamp <<<"$g")"
grep -q 'guard slop: b.sh:7 # hack' <<<"$(osrc_proof_review_note g1)" && ok "review note lists the allowed failures for the reviewer" || bad "note: $(osrc_proof_review_note g1)"
GJSON='{"mode":"enforce","passed":true,"failed":[],"guards_changed":true,"guards_changed_paths":[".outsourcerer/guards.conf"],"allowed":null,"reviewer_required":true}'
g="$(G)"; grep -q 'the diff edits the checks: .outsourcerer/guards.conf' <<<"$(osrc_proof_review_note g1)" && ok "guards_changed: reviewer told which check files changed" || bad "changed note: $(osrc_proof_review_note g1)"
cmd_guards() { echo "fatal: pin --base" >&2; return 2; }
P reset g1 >/dev/null; P run --lane g1 --dir "$TMP/r2" --cmd true >/dev/null 2>&1
[ "$(jq -r '[.ok, (.guards|tostring)] | join(" ")' "$OSRC_HOME/proof/g1/proof.json")" = "false error: guards run gave no JSON verdict" ] \
  && [ "$(jq -r .fails "$OSRC_HOME/proof/g1/rounds.json")" = 0 ] && ok "guards that cannot run fail the proof but do not charge the lane a round" || bad "guards error: $(cat "$OSRC_HOME/proof/g1/proof.json")"
eval "$REAL_GUARDS"; P reset g1 >/dev/null

echo "=== the base is a sha pinned once, at lane start ==="
P run --lane pin1 --dir "$TMP/r2" --cmd true >/dev/null
m0="$(git -C "$TMP/r2" rev-parse main)"
[ "$(jq -r '.base + " " + .base_sha' "$OSRC_HOME/proof/pin1/proof.json")" = "main $m0" ] && ok "proof.json records base and base_sha" || bad "pin: $(jq -c '{base,base_sha}' "$OSRC_HOME/proof/pin1/proof.json")"
( cd "$TMP/r2" && git checkout -q main && echo m >> m && git add m && git commit -qm "main moved" && git checkout -q work )
P run --lane pin1 --dir "$TMP/r2" --cmd true >/dev/null
[ "$(jq -r .base_sha "$OSRC_HOME/proof/pin1/proof.json")" = "$m0" ] && ok "main moving later does not change the lane's pinned base" || bad "repinned: $(jq -r .base_sha "$OSRC_HOME/proof/pin1/proof.json")"
[ "$(P base pin1)" = "main $m0" ] && ok "proof base <lane> shows the pin" || bad "base show: $(P base pin1)"
M="$TMP/mainonly"; mkdir -p "$M" && ( cd "$M" && git init -q -b main && echo 'x=1' > a.sh && git add -A && git commit -qm base )
s0="$(git -C "$M" rev-parse HEAD)"
osrc_done_set solo "check:true" "$M"   # session start --done-when: the lane starts here
( cd "$M" && printf 'x=1\n# added the retry loop as requested\n' > a.sh && git commit -qam work )
out="$(P run --lane solo --dir "$M" --cmd 'echo "1 passed"' 2>&1)"; rc=$?
[ "$(jq -r .base_sha "$OSRC_HOME/proof/solo/proof.json")" = "$s0" ] && ok "a checkout on main with no remote: base pinned to main's tip at lane start" || bad "solo base: $(jq -c . "$OSRC_HOME/proof/solo/proof.json")"
[ "$rc" = 1 ] && [ "$(jq -r '.guards.passed, .guards.failed[0].guard, .guards.base_sha' "$OSRC_HOME/proof/solo/proof.json" | tr '\n' ' ')" = "false slop $s0 " ] \
  && grep -q 'WHAT: narration a.sh:2' <<<"$out" && ok "REAL guards end to end: the narration comment blocks the proof, judged against the pinned sha" || bad "solo guards rc=$rc: $out"
( cd "$M" && printf 'x=1\n' > a.sh && git commit -qam clean )
P run --lane solo --dir "$M" --cmd 'echo "1 passed"' >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r '.stamp, .guards.passed' "$OSRC_HOME/proof/solo/proof.json" | tr '\n' ' ')" = "proved: 1 pass, 0 fail true " ] && ok "fixed and committed: the real guards pass and the proof is green" || bad "solo clean rc=$rc: $(jq -c . "$OSRC_HOME/proof/solo/proof.json")"
M2="$TMP/mainonly2"; mkdir -p "$M2" && ( cd "$M2" && git init -q -b main && echo y > y && git add -A && git commit -qm base )
out="$(P run --lane nopin --dir "$M2" --cmd true 2>&1)"
grep -q 'Pin it at lane start: osrc proof base nopin' <<<"$out" && [ "$(jq -r '.ok, (.guards|tostring)' "$OSRC_HOME/proof/nopin/proof.json" | tr '\n' ' ')" = "false error: no base ref to pin --base to " ] \
  && [ "$(_osrc_proof_rounds nopin | jq -r .fails)" = 0 ] && ok "on its own branch with no pin: says how to pin, never guesses, not charged" || bad "nopin: $out"

echo "=== three failed rounds, then a person ==="
for i in 1 2 3; do out="$(P run --lane r3 --dir "$TMP/r2" --cmd 'echo "boom line"; echo "2 passed, 1 failed"; exit 1' 2>&1)"; done
RF="$OSRC_HOME/proof/r3/rounds.json"
[ "$(jq -r '.fails, .stopped' "$RF" | tr '\n' ' ')" = "3 true " ] && ok "3 failed runs -> rounds.fails 3, stopped" || bad "rounds: $(cat "$RF")"
grep -q 'STOPPED' <<<"$out" && ok "the 3rd failing run says STOPPED, do not retry" || bad "3rd out: $out"
[ "$(jq -r '.lines | map(select(. == "boom line")) | length' "$OSRC_HOME/proof/r3/needs-you.json")" -ge 1 ] && ok "needs-you.json carries the last failing lines" || bad "needs-you: $(cat "$OSRC_HOME/proof/r3/needs-you.json" 2>&1)"
out="$(P run --lane r3 --dir "$TMP/r2" --cmd true 2>&1)"; rc=$?
[ "$rc" = 4 ] && grep -q 'a person must look' <<<"$out" && ok "4th run refused (rc 4): the lane cannot loop" || bad "4th run rc=$rc [$out]"
gate="$(osrc_proof_gate r3)"; [ $? = 2 ] && ok "gate reports stopped (rc 2)" || bad "gate stopped: $gate"
P run --lane r4 --dir "$TMP/r2" --cmd false >/dev/null 2>&1; P run --lane r4 --dir "$TMP/r2" --cmd true >/dev/null
[ "$(jq -r .fails "$OSRC_HOME/proof/r4/rounds.json")" = 0 ] && ok "a passing round resets the count" || bad "reset by pass: $(cat "$OSRC_HOME/proof/r4/rounds.json")"
[ "$(osrc_proof_remote_next r3)" = "osrc proof show r3" ] && ok "a stopped lane's NEXT is proof show, never another sendback" || bad "stopped next: $(osrc_proof_remote_next r3)"
P reset r3 >/dev/null; [ ! -f "$OSRC_HOME/proof/r3/needs-you.json" ] && ! osrc_proof_stopped r3 && ok "proof reset clears the stop (a person's call)" || bad "reset"

echo "=== READY/DONE hand-in without proof for the head is sent back ==="
( cd "$R" && echo d > d.txt && git add -A && git commit -q -m "after the proof" )   # proof now stale
W="$TMP/w"; mkdir -p "$W/out"; id="$(_sv_watch_add "$W/out")"
: > "$W/out/lane1.DONE"; _sv_observe_watch "$id" supervise "$CLAUDE_CODE_SESSION_ID"
EV="$OSRC_HOME/lanes/events.jsonl"
ev="$(tail -1 "$EV")"
[ "$(jq -r .kind <<<"$ev")" = failed ] && grep -q 'not accepted (proof is for' <<<"$(jq -r .detail <<<"$ev")" && ok "lane1.DONE with a stale proof -> EVENT failed with the reason, not done" || bad "handin event: $ev"
[ "$(jq -r .next <<<"$ev")" = "osrc proof sendback lane1" ] && ok "NEXT relays the sendback (no live session to type into)" || bad "next: $(jq -r .next <<<"$ev")"
grep -q 'round 1 of 3' "$OSRC_HOME/proof/lane1/SENDBACK.md" && ok "SENDBACK.md written with the round" || bad "sendback file"
_sv_observe_watch "$id" supervise "$CLAUDE_CODE_SESSION_ID"
[ "$(jq -r .fails "$OSRC_HOME/proof/lane1/rounds.json")" = 1 ] && ok "the same hand-in seen again is not a second round" || bad "dedupe: $(cat "$OSRC_HOME/proof/lane1/rounds.json")"
P run --lane lane1 --dir "$R" --cmd 'echo 4 passed' >/dev/null; touch -m -t 202601010101 "$W/out/lane1.DONE"
_sv_observe_watch "$id" supervise "$CLAUDE_CODE_SESSION_ID"; ev="$(tail -1 "$EV")"
[ "$(jq -r .kind <<<"$ev")" = done ] && ok "with a fresh proof the re-hand-in is a plain EVENT done" || bad "proved handin: $ev"
: > "$W/out/legacy.DONE"; _sv_observe_watch "$id" supervise "$CLAUDE_CODE_SESSION_ID"; ev="$(tail -1 "$EV")"
[ "$(jq -r .kind <<<"$ev")" = done ] && ok "a lane that never ran proof is not gated by default (proof require off)" || bad "legacy: $ev"
P require on >/dev/null; : > "$W/out/strict.DONE"; _sv_observe_watch "$id" supervise "$CLAUDE_CODE_SESSION_ID"; ev="$(tail -1 "$EV")"
[ "$(jq -r .kind <<<"$ev")" = failed ] && grep -q 'no proof.json for strict' <<<"$ev" && ok "proof require on: every DONE needs proof" || bad "strict: $ev"
P require off >/dev/null
mkdir -p "$OSRC_HOME/proof/osrc-auto-L9"; echo '{"fails":0}' > "$OSRC_HOME/proof/osrc-auto-L9/rounds.json"; : > "$W/out/L9.DONE"; _sv_observe_watch "$id" supervise "$CLAUDE_CODE_SESSION_ID"; ev="$(tail -1 "$EV")"
grep -q 'osrc-auto-L9 hand-in not accepted' <<<"$ev" && ok "L9.DONE maps to the session lane osrc-auto-L9" || bad "stem map: $ev"
cmd_guards() { echo '{"mode":"enforce","passed":true,"failed":[],"guards_changed":false,"allowed":"regex misfire on a string","reviewer_required":true}'; }
P run --lane lane1 --dir "$R" --base main --cmd true >/dev/null; eval "$REAL_GUARDS"
touch -m -t 202601010202 "$W/out/lane1.DONE"; _sv_observe_watch "$id" supervise "$CLAUDE_CODE_SESSION_ID"; ev="$(tail -1 "$EV")"
[ "$(jq -r .kind <<<"$ev")" = done ] && grep -q 'guards require a reviewer: guards were allowed through: regex misfire' <<<"$ev" \
  && grep -q '^osrc review queue add lane1 --repo ' <<<"$(jq -r .next <<<"$ev")" && ok "a hand-in that passed via --allow goes to the reviewer (NEXT review queue add)" || bad "rr handin: $ev"

echo "=== remote READY: proved on this machine, or stamped unverified, never stranded ==="
REMOTE="$TMP/remote.git"; WORK="$TMP/work"
git init -q --bare "$REMOTE"; git clone -q "$REMOTE" "$WORK" 2>/dev/null
( cd "$WORK" && git checkout -q -b main && echo base > f && git add f && git commit -q -m base && git push -q origin main )
pushr() { ( cd "$WORK" && { git checkout -q "$1" 2>/dev/null || git checkout -q -b "$1" main; } && echo "$RANDOM" > "c.$RANDOM" && git add -A && git commit -q -m "$2" && git push -q origin "$1" 2>/dev/null && git rev-parse HEAD ); }
cmd_lane add cl1 --branch cloud/one --repo "$REMOTE" >/dev/null
h="$(pushr cloud/one "feature READY")"; cmd_lane poll cl1 >/dev/null
[ "$(jq -r '.method + "|" + .head' "$OSRC_HOME/proof/cl1/proof.json")" = "none|$h" ] && ok "no check configured: READY records an honest method-none proof" || bad "cl1 proof: $(cat "$OSRC_HOME/proof/cl1/proof.json" 2>&1)"
it="$OSRC_HOME/review/items/cl1-${h:0:7}.json"
[ -f "$it" ] && grep -q '^unverified: no check configured' <<<"$(jq -r .proof "$it")" && ok "and it is queued for review with the stamp 'unverified: ...'" || bad "cl1 item: $(cat "$it" 2>&1)"
( cd "$WORK" && git checkout -q main && mkdir -p .outsourcerer && printf '#!/bin/sh\necho "7 passed, 0 failed"\n' > .outsourcerer/verify && chmod +x .outsourcerer/verify && git add -A && git commit -q -m verify && git push -q origin main )
cmd_lane add cl2 --branch cloud/two --repo "$REMOTE" >/dev/null
h="$(pushr cloud/two "READY: two")"; cmd_lane poll cl2 >/dev/null
for i in $(seq 1 50); do [ -s "$OSRC_HOME/remote/cl2-${h:0:7}.rc" ] && break; sleep 0.2; done
cmd_lane poll cl2 >/dev/null
[ "$(jq -r '.method + "|" + .stamp' "$OSRC_HOME/proof/cl2/proof.json" 2>/dev/null)" = "verify-run|proved: 7 pass, 0 fail" ] && ok "verify on base: READY runs it on the READY sha (proved: 7 pass)" || bad "cl2: $(cat "$OSRC_HOME/proof/cl2/proof.json" 2>&1)"
[ -f "$OSRC_HOME/review/items/cl2-${h:0:7}.json" ] && ok "a proved READY is queued" || bad "cl2 not queued"
cmd_lane add cl3 --branch cloud/three --repo "$REMOTE" --done-when 'check:echo "1 passed, 1 failed"; exit 1' >/dev/null
h="$(pushr cloud/three "READY")"; cmd_lane poll cl3 >/dev/null
for i in $(seq 1 50); do [ -s "$OSRC_HOME/remote/cl3-${h:0:7}.rc" ] && break; sleep 0.2; done
ev="$(cmd_lane events 2>/dev/null)"
grep -q '^EVENT failed cl3 .*proof round 1 of 3' <<<"$ev" && grep -q '^NEXT osrc proof sendback cl3$' <<<"$ev" && ok "failing proof on READY: EVENT failed with the round, NEXT relays the sendback" || bad "cl3 events: $ev"
[ ! -f "$OSRC_HOME/review/items/cl3-${h:0:7}.json" ] && ok "no review spent on it" || bad "cl3 queued"

echo "=== routing reads only the stated VERDICT line ==="
mkitem() { # <lane> <sha> <verdict-body> -> item id, ingested
  local id="$1-${2:0:7}"
  _OSRC_RV_BRANCH="$1" _OSRC_RV_URL=x _OSRC_RV_TRANSPORT=git _osrc_review_enqueue "$1" "$2" "" manual >/dev/null
  _osrc_jq_set "$OSRC_HOME/review/items/$id.json" '.state="inflight" | .review_scope="full" | .review_scope_head=.head'
  printf '%s\n' "$3" > "$OSRC_HOME/review/$id.VERDICT"; _osrc_review_ingest; printf '%s' "$id"
}
S1=1111111111111111111111111111111111111111; S2=2222222222222222222222222222222222222222
i="$(mkitem sv1 "$S1" "$(printf 'VERDICT: CHANGES must-fix=0 nit=1 pre-existing=1\n## Nits\n- a.sh:3 rename x\n## Pre-existing\n- b.sh:9 old race')")"
[ "$(jq -r '.verdict + "|" + .verdict_raw + "|" + .notes + "|" + (.counts|tostring)' "$OSRC_HOME/review/items/$i.json")" = "MERGE|CHANGES|$OSRC_HOME/review/$i.VERDICT|{\"must_fix\":0,\"nit\":1,\"pre_existing\":1}" ] \
  && ok "CHANGES must-fix=0 -> MERGE with notes (raw CHANGES, counts, notes on the item)" || bad "mf0: $(jq -c . "$OSRC_HOME/review/items/$i.json")"
i="$(mkitem sv2 "$S1" "$(printf 'VERDICT: MERGE\n- [must-fix] c.sh:1 deletes the wrong dir')")"
[ "$(jq -r .verdict "$OSRC_HOME/review/items/$i.json")" = MERGE ] && ok "VERDICT: MERGE merges whatever the text below says (no inference)" || bad "merge text"
i="$(mkitem sv3 "$S1" "$(printf 'VERDICT: CHANGES must-fix=1 nit=0 pre-existing=0\nc.sh:1 untagged problem')")"
[ "$(jq -r .verdict "$OSRC_HOME/review/items/$i.json")" = CHANGES ] && ok "CHANGES must-fix=1 sends back" || bad "mf1"
i="$(mkitem sv4 "$S1" "$(printf 'VERDICT: CHANGES must-fix=1 nit=1 pre-existing=1\n## Must-fix\n- d.sh:2 unchecked rc\n## Nits\n- d.sh:5 typo\n## Pre-existing\n- e.sh old')")"
sb="$(_osrc_review_sendback "$i")"
grep -q 'unchecked rc' <<<"$sb" && grep -q 'Nits (optional)' <<<"$sb" && ! grep -q 'e.sh old' <<<"$sb" && ok "sendback carries the Must-fix section, nits as optional, no pre-existing" || bad "sendback: $sb"

echo "=== re-review gets only the delta and the prior must-fix findings ==="
printf '# Brief\nBRIEF-BODY-MARKER %s\n' "$(head -c 3000 /dev/zero | tr '\0' 'x')" > "$TMP/brief.md"
_osrc_jq_set "$OSRC_HOME/review/items/$i.json" --arg b "$TMP/brief.md" '.brief=$b'
_OSRC_RV_BRANCH=sv4 _OSRC_RV_URL=x _OSRC_RV_TRANSPORT=git _osrc_review_enqueue sv4 "$S2" "$TMP/brief.md" manual >/dev/null
b2="$(_osrc_review_write_brief "sv4-${S2:0:7}")"; inc="$(cat "$b2")"
grep -q "git diff $S1 FETCH_HEAD" <<<"$inc" && ok "re-review diffs from the last reviewed sha" || bad "delta diff: $inc"
grep -q 'unchecked rc' <<<"$inc" && ! grep -q 'd.sh:5 typo' <<<"$inc" && ! grep -q 'e.sh old' <<<"$inc" && ok "prior round: must-fix only (no nits, no pre-existing)" || bad "prior: $inc"
! grep -q BRIEF-BODY-MARKER <<<"$inc" && grep -q "$TMP/brief.md" <<<"$inc" && ok "the lane brief is a pointer, not pasted again" || bad "brief pasted: $inc"
b3="$(_osrc_review_write_brief "sv4-${S2:0:7}" final)"; full="$(cat "$b3")"
[ "${#inc}" -lt "${#full}" ] && ok "incremental brief is smaller than the full one (${#inc} < ${#full} bytes)" || bad "sizes ${#inc} vs ${#full}"
grep -q '^- Proof: ' <<<"$full" && grep -qxF 'VERDICT: CHANGES must-fix=<n> nit=<n> pre-existing=<n>' <<<"$full" && ok "brief shows the proof stamp and the exact VERDICT line formats" || bad "brief lines"

_OSRC_RV_BRANCH=lane1 _OSRC_RV_URL=x _OSRC_RV_TRANSPORT=git _osrc_review_enqueue lane1 "$(git -C "$R" rev-parse HEAD)" "" manual >/dev/null
b4="$(_osrc_review_write_brief "lane1-$(git -C "$R" rev-parse --short=7 HEAD)")"
grep -q '^- Reviewer must check: guards were allowed through: regex misfire' "$b4" && ok "the review brief tells the reviewer what the guards let through" || bad "brief rr: $(head -12 "$b4")"

echo "=== Mission Control fields ==="
l="$(osrc_proof_hub_lane '{"id":"docs1","status":"Merged"}')"
[ "$(jq -r '.proof.stamp' <<<"$l")" = "unverified: docs-only change" ] && ok "lane gets proof.stamp" || bad "hub lane: $l"
for k in 1 2 3; do P run --lane hubst --dir "$TMP/r2" --cmd 'echo hub-fail-line; exit 2' >/dev/null 2>&1; done
s="$(osrc_proof_hub_lane '{"id":"hubst","status":"Building"}')"
c="$(osrc_proof_hub_counts "[$l,$s,{\"id\":\"x\",\"status\":\"Merged\"}]")"
[ "$(jq -c . <<<"$c")" = '{"unverifiedLanes":1,"needsYouLanes":1}' ] && ok "project counts: 1 landed unverified, 1 needs you" || bad "counts: $c"
grep -q hub-fail-line <<<"$(jq -r '.proof.lines[]' <<<"$s")" && ok "a stopped lane carries its last failing lines to the page" || bad "lines: $s"
grep -q 'assets/hub-proof.js' "$HERE/../lib/hub.html" && ok "the page loads assets/hub-proof.js" || bad "script tag"

echo "=== the CLI resolves lib/proof.sh through a symlinked launcher ==="
ln -s "$SRC" "$TMP/outsourcerer"
out="$(env -u OSRC_SOURCED bash "$TMP/outsourcerer" proof stamp docs1 2>&1)"
[ "$out" = "unverified: docs-only change" ] && ok "outsourcerer proof stamp works via a symlink" || bad "symlink: [$out]"

echo "=== Round 2 regressions (S2-REVIEW-1 must-fix 1-9 + nits; each fails on d4df36f) ==="
# mk <dir> <verify-line>: main carries .outsourcerer/verify; branch lane is checked out at main's tip.
mk() { mkdir -p "$1/.outsourcerer" && ( cd "$1" && git init -q -b main && printf '#!/bin/sh\n%s\n' "$2" > .outsourcerer/verify \
  && chmod +x .outsourcerer/verify && echo a > a && git add -A && git commit -qm base && git checkout -qb lane ); }
work() { ( cd "$1" && echo "$RANDOM" > "w.$RANDOM" && git add -A && git commit -qm work ); }
FAILV='echo "0 passed, 1 failed"; exit 1'
# M1: a lane-facing --base cannot move the lane-start pin to its own commits.
D="$TMP/m1"; mk "$D" "$FAILV"; osrc_done_set m1 "check:true" "$D"; s0="$(git -C "$D" rev-parse HEAD)"
( cd "$D" && printf '#!/bin/sh\necho "9 passed"\n' > .outsourcerer/verify && git commit -qam "lane rewrites verify" )
for b in HEAD lane "$(git -C "$D" rev-parse HEAD)"; do
  P run --lane m1 --dir "$D" --base "$b" --cmd true >/dev/null 2>&1; r=$?
  [ "$r" != 0 ] && [ "$(jq -r .sha "$OSRC_HOME/proof/m1/base.json")" = "$s0" ] && [ "$(jq -r '.ok // false' "$OSRC_HOME/proof/m1/proof.json" 2>/dev/null)" != true ] \
    && ok "M1: proof run --base $( [ ${#b} -eq 40 ] && echo '<head sha>' || echo "$b") is refused; the lane-start pin stays" || bad "M1 --base $b: rc=$r pin=$(cat "$OSRC_HOME/proof/m1/base.json") proof=$(jq -c '{ok,base_sha}' "$OSRC_HOME/proof/m1/proof.json" 2>/dev/null)"
done
# M2: --cmd never replaces a failing base verify or the done contract's check.
D="$TMP/m2"; mk "$D" "$FAILV"; work "$D"
P run --lane m2 --dir "$D" --cmd true >/dev/null 2>&1
[ "$(jq -r '.ok, (.commands|length)' "$OSRC_HOME/proof/m2/proof.json" | tr '\n' ' ')" = "false 2 " ] && ok "M2: --cmd true still runs the failing base verify, and the proof fails" || bad "M2: $(jq -c '{ok,commands:[.commands[].cmd]}' "$OSRC_HOME/proof/m2/proof.json")"
mkdir -p "$TMP/m2b" && ( cd "$TMP/m2b" && git init -q -b main && echo a > a && git add -A && git commit -qm b && git checkout -qb lane && echo c > c && git add -A && git commit -qm w )
jq -n --arg c "$TMP/m2b" '{spec:"check:echo contract-ran; exit 3", cwd:$c}' > "$OSRC_HOME/done/m2b.json"
P run --lane m2b --dir "$TMP/m2b" --cmd true >/dev/null 2>&1
[ "$(jq -r '.ok' "$OSRC_HOME/proof/m2b/proof.json")" = false ] && ok "M2: --cmd true still runs the failing done-contract check" || bad "M2b: $(jq -c . "$OSRC_HOME/proof/m2b/proof.json")"
# M3: --method none is refused when checks exist; otherwise it still runs guards, needs review, keeps the round count.
D="$TMP/m3"; mk "$D" 'echo "1 passed"'; work "$D"
out="$(P run --lane m3 --dir "$D" --method none --reason "trust me" 2>&1)"; r=$?
[ "$r" != 0 ] && grep -q 'lane has checks to run' <<<"$out" && ok "M3: --method none refused when a base verify exists" || bad "M3 refuse: rc=$r $out"
D="$TMP/m3b"; mkdir -p "$D" && ( cd "$D" && git init -q -b main && echo 'x=1' > a.sh && git add -A && git commit -qm b && git checkout -qb lane && echo 'y=2' >> a.sh && git commit -qam w )
P run --lane m3b --dir "$D" --cmd false >/dev/null 2>&1
printf '#!/bin/sh\n' > "$TMP/gargs"; GCALLED=""
P run --lane m3b --dir "$D" --method none --reason "docs only" >/dev/null 2>&1
[ "$(jq -r '.ok, .reviewer_required, (.guards|type)' "$OSRC_HOME/proof/m3b/proof.json" | tr '\n' ' ')" = "true true object " ] \
  && [ "$(jq -r .fails "$OSRC_HOME/proof/m3b/rounds.json")" = 1 ] && ok "M3: method none still runs the real guards, needs a reviewer, and does not reset the failed round" || bad "M3b: $(jq -c '{ok,reviewer_required,guards}' "$OSRC_HOME/proof/m3b/proof.json") rounds=$(cat "$OSRC_HOME/proof/m3b/rounds.json")"
# M4: a lane that edits .outsourcerer/ needs a reviewer even when everything passes.
D="$TMP/m4"; mk "$D" 'echo "2 passed"'; ( cd "$D" && printf '#!/bin/sh\necho "2 passed"\nexit 0\n' > .outsourcerer/verify && git commit -qam "tweak verify" )
P run --lane m4 --dir "$D" >/dev/null 2>&1
[ "$(jq -r '.ok, .checks_changed, .reviewer_required' "$OSRC_HOME/proof/m4/proof.json" | tr '\n' ' ')" = "true true true " ] && ok "M4: checks_changed sets reviewer_required" || bad "M4: $(jq -c '{ok,checks_changed,reviewer_required}' "$OSRC_HOME/proof/m4/proof.json")"
grep -q 'reviewer must look (the diff edits .outsourcerer/)' <<<"$(jq -r .stamp "$OSRC_HOME/proof/m4/proof.json")" && ok "M4: and the stamp says why" || bad "M4 stamp: $(jq -r .stamp "$OSRC_HOME/proof/m4/proof.json")"
# M5: the lane-start pin is the lane's own start HEAD and does not opt the lane into the gate.
D="$TMP/m5"; mkdir -p "$D" && ( cd "$D" && git init -q -b main && echo a > a && git add -A && git commit -qm b && git checkout -qb rel && echo r > r && git add -A && git commit -qm rel )
osrc_done_set m5 "check:true" "$D"
[ "$(jq -r '.ref + " " + .sha' "$OSRC_HOME/proof/m5/base.json")" = "lane-start $(git -C "$D" rev-parse rel)" ] && ok "M5: session start pins the lane-start HEAD (release branch tip), not main" || bad "M5 pin: $(cat "$OSRC_HOME/proof/m5/base.json")"
! osrc_proof_required m5 && ok "M5: a fresh --done-when lane is not gated just because its base was pinned" || bad "M5: gated without using proof"
: > "$W/out/m5.DONE"; _sv_observe_watch "$id" supervise "$CLAUDE_CODE_SESSION_ID"; ev="$(tail -1 "$EV")"
[ "$(jq -r .kind <<<"$ev")" = done ] && [ ! -f "$OSRC_HOME/proof/m5/rounds.json" ] && ok "M5: its .DONE is a plain done, no round charged" || bad "M5 handin: $ev"
# M6 (round 4: severity is stated): the counts decide, whatever the findings' markup says.
i="$(mkitem m6 "$S1" "$(printf 'VERDICT: CHANGES must-fix=1 nit=1 pre-existing=0\n- [nit] a.sh:1 rename\n- c.sh:9 untagged bug')")"
[ "$(jq -r .verdict "$OSRC_HOME/review/items/$i.json")" = CHANGES ] && ok "M6: must-fix=1 stays CHANGES" || bad "M6"
i="$(mkitem m6ok "$S1" "$(printf 'VERDICT: CHANGES must-fix=0 nit=2 pre-existing=0\n- **[must-fix]** looks scary but the reviewer counted 0')")"
[ "$(jq -r .verdict "$OSRC_HOME/review/items/$i.json")" = MERGE ] && ok "M6: must-fix=0 merges, the text is not re-read" || bad "M6 ok"
# M7: sendback and the next round keep untagged findings and continuation lines.
i="$(mkitem m7 "$S1" "$(printf 'VERDICT: CHANGES must-fix=2 nit=1 pre-existing=0\n## Must-fix\n- a.sh:1 race\n  repro: run twice in parallel\n- b.sh:2 untagged leak\n## Nits\n- c.sh typo')")"
sb="$(_osrc_review_sendback "$i")"
grep -q 'repro: run twice in parallel' <<<"$sb" && grep -q 'b.sh:2 untagged leak' <<<"$sb" && ok "M7: sendback keeps the continuation line and the untagged finding" || bad "M7 sendback: $sb"
_OSRC_RV_BRANCH=m7 _OSRC_RV_URL=x _OSRC_RV_TRANSPORT=git _osrc_review_enqueue m7 "$S2" "" manual >/dev/null
b7="$(cat "$(_osrc_review_write_brief "m7-${S2:0:7}")")"
grep -q '^  repro: run twice in parallel' <<<"$b7" && grep -q '^- \[ \] b.sh:2 untagged leak' <<<"$b7" && ! grep -q 'c.sh typo' <<<"$b7" \
  && ok "M7: re-review checklist keeps them too (continuation stays indented, not a new item)" || bad "M7 brief: $b7"
# M8: the review item and brief show a stamp only for the exact head.
P run --lane m8 --dir "$TMP/r2" --cmd true >/dev/null 2>&1
_OSRC_RV_BRANCH=m8 _OSRC_RV_URL=x _OSRC_RV_TRANSPORT=git _osrc_review_enqueue m8 "$S2" "" manual >/dev/null
[ "$(jq -r .proof "$OSRC_HOME/review/items/m8-${S2:0:7}.json")" = "unproved at ${S2:0:7}" ] && ok "M8: a proof of another sha shows 'unproved at <sha7>'" || bad "M8: $(jq -r .proof "$OSRC_HOME/review/items/m8-${S2:0:7}.json")"
grep -q "^- Proof: unproved at ${S2:0:7}" "$(_osrc_review_write_brief "m8-${S2:0:7}")" && ok "M8: the brief says so too" || bad "M8 brief"
# M9: an untracked file means the head was not what ran.
D="$TMP/m9"; mk "$D" 'echo "1 passed"'; work "$D"; echo new > "$D/new.sh"
P run --lane m9 --dir "$D" >/dev/null 2>&1
[ "$(jq -r .ok "$OSRC_HOME/proof/m9/proof.json")" = false ] && grep -q 'untracked' <<<"$(jq -r .why "$OSRC_HOME/proof/m9/proof.json")" && ok "M9: an untracked file fails the proof" || bad "M9: $(jq -c '{ok,why}' "$OSRC_HOME/proof/m9/proof.json")"
# Nits
D="$TMP/n1"; mk "$D" 'echo "1 passed"'; work "$D"
P run --lane n1 --dir "$D" --cmd 'echo "10 passed, 3 failed"; exit 0' >/dev/null 2>&1
[ "$(jq -r .ok "$OSRC_HOME/proof/n1/proof.json")" = false ] && ok "nit: exit 0 with '3 failed' in the output fails" || bad "nit fail count: $(jq -c '{ok,stamp}' "$OSRC_HOME/proof/n1/proof.json")"
out="$(OSRC_LANE=n1 P reset n1 2>&1)"; [ $? != 0 ] && grep -q "a person's call" <<<"$out" && ok "nit: proof reset is refused inside a lane session" || bad "nit reset: $out"
out="$(OSRC_LANE=n1 P base n1 --dir "$D" lane 2>&1)"; [ $? != 0 ] && ok "nit: re-pinning the base is refused inside a lane session" || bad "nit base: $out"
D2="$TMP/n2other"; mk "$D2" 'echo "1 passed"'; work "$D2"; jq -n --arg c "$TMP/m9" '{spec:"check:true", cwd:$c}' > "$OSRC_HOME/done/n2.json"
P run --lane n2 --dir "$D2" >/dev/null 2>&1; g="$(osrc_proof_gate n2)"
[ $? = 1 ] && grep -q 'not in the lane worktree' <<<"$g" && ok "nit: a proof run in another repo does not pass the gate" || bad "nit dir: $g"
D="$TMP/n3"; mkdir -p "$D" && ( cd "$D" && git init -q -b main && echo a > a && git add -A && git commit -qm b )
out="$(P run --lane n3 --dir "$D" --cmd true 2>&1)"; grep -q '^not counted: guards could not run' <<<"$out" && ! grep -q 'round 0 of' <<<"$out" && ok "nit: guards that could not run say so (no 'round 0 of 3 failed')" || bad "nit msg: $out"
grep -q "slice(-4)" "$HERE/../lib/hub-assets/hub-proof.js" && ok "nit: the needs-you card shows the last failing lines (not hover-only)" || bad "nit card"

echo "=== Round 3 regressions (S2 review round 2: must-fix 1-4 + nits; each fails on 25b300d) ==="
# R3: only a summary line with BOTH counts counts failures.
D="$TMP/r3c"; mk "$D" 'echo "1 passed, 0 failed"'; work "$D"
P run --lane r3c --dir "$D" --cmd 'echo "test_retry: recovers after 2 failed attempts ... ok"; echo "RESULT: 10 passed, 0 failed"' >/dev/null 2>&1
[ "$(jq -r '.ok, .totals.fail' "$OSRC_HOME/proof/r3c/proof.json" | tr '\n' ' ')" = "true 0 " ] && ok "R3: a test title '2 failed attempts' is not a failure count" || bad "R3 title: $(jq -c '{ok,stamp}' "$OSRC_HOME/proof/r3c/proof.json")"
P run --lane r3c --dir "$D" --cmd 'echo "retried after 2 failed attempts"; echo all good' >/dev/null 2>&1
[ "$(jq -r .ok "$OSRC_HOME/proof/r3c/proof.json")" = true ] && ok "R3: a lone 'N failed' in free text does not fail a green run" || bad "R3 lone: $(jq -c '{ok,stamp}' "$OSRC_HOME/proof/r3c/proof.json")"
for c in 'echo "passed=10 failed=2"' 'echo "10 pass 2 fail"'; do
  P run --lane r3c --dir "$D" --cmd "$c" >/dev/null 2>&1
  [ "$(jq -r '.ok, .commands[-1].fail' "$OSRC_HOME/proof/r3c/proof.json" | tr '\n' ' ')" = "false 2 " ] && ok "R3: summary '$c' with exit 0 still fails" || bad "R3 summary $c: $(jq -c '{ok,stamp}' "$OSRC_HOME/proof/r3c/proof.json")"
done
P reset r3c >/dev/null 2>&1
# R4: a lane name reused after `session stop` is a new lane: new pin, rounds reset.
DA="$TMP/r4a"; mk "$DA" "$FAILV"; work "$DA"; osrc_done_set r4 "check:true" "$DA"
for _ in 1 2 3; do P run --lane r4 --dir "$DA" >/dev/null 2>&1; done
osrc_proof_stopped r4 && ok "R4 setup: the old lane r4 is stopped after 3 rounds" || bad "R4 setup: $(_osrc_proof_rounds r4)"
[ "$(jq -r '.dir == $d and .branch == "lane"' --arg d "$(cd "$DA" && pwd -P)" "$OSRC_HOME/proof/r4/base.json")" = true ] && ok "R4: base.json records the lane's worktree and branch" || bad "R4 ident: $(cat "$OSRC_HOME/proof/r4/base.json")"
osrc_done_clear r4   # session stop
DB="$TMP/r4b"; mk "$DB" 'echo "2 passed, 0 failed"'; ( cd "$DB" && git checkout -qb lane-two ); osrc_done_set r4 "check:true" "$DB"; work "$DB"
P run --lane r4 --dir "$DB" >/dev/null 2>&1; r=$?
[ "$r" = 0 ] && [ "$(_osrc_proof_rounds r4 | jq -r '.fails, .stopped' | tr '\n' ' ')" = "0 false " ] && ok "R4: the new lane's first run proves (no inherited stop, rounds reset)" || bad "R4 rc=$r $(_osrc_proof_rounds r4)"
[ "$(jq -r '.sha == $s and .dir == $d' --arg s "$(git -C "$DB" rev-parse main)" --arg d "$(cd "$DB" && pwd -P)" "$OSRC_HOME/proof/r4/base.json")" = true ] && ok "R4: re-pinned to the new lane's start, in its worktree" || bad "R4 pin: $(cat "$OSRC_HOME/proof/r4/base.json")"
# Without a lane start: a run from the orchestrator in another worktree also resets; a lane session with
# failed rounds cannot clear them by moving.
DC="$TMP/r4c"; mk "$DC" "$FAILV"; work "$DC"
P run --lane r4c --dir "$DC" --base main >/dev/null 2>&1; P run --lane r4c --dir "$DC" >/dev/null 2>&1
DD="$TMP/r4d"; mk "$DD" 'echo "3 passed, 0 failed"'; work "$DD"
out="$(OSRC_LANE=r4c P run --lane r4c --dir "$DD" --base main 2>&1)"; r=$?
[ "$r" = 4 ] && grep -q 'pin never moves' <<<"$out" && [ "$(_osrc_proof_rounds r4c | jq -r .fails)" = 2 ] && ok "R4: inside the lane, moving to another worktree does not clear 2 failed rounds" || bad "R4 in-lane rc=$r [$out]"
( cd "$DC" && git checkout -qb other ); out="$(OSRC_LANE=r4c P run --lane r4c --dir "$DC" 2>&1)"; r=$?
[ "$r" = 4 ] && [ "$(_osrc_proof_rounds r4c | jq -r .fails)" = 2 ] && ok "R4: nor does switching branch in the same worktree" || bad "R4 branch in-lane rc=$r [$out]"
P run --lane r4c --dir "$DD" --base main >/dev/null 2>&1; r=$?
[ "$r" = 0 ] && [ "$(_osrc_proof_rounds r4c | jq -r .fails)" = 0 ] && ok "R4: from the orchestrator, a new worktree for the name is a new lane" || bad "R4 orch rc=$r $(_osrc_proof_rounds r4c)"
# Nit: an unpinned lane's --base HEAD~1 (or <branch>~1, or a lane-only sha) is refused; the pin is the lane-start head.
for b in 'HEAD~1' 'lane^' 'SHA'; do
  D="$TMP/n4$RANDOM"; mk "$D" 'echo "1 passed, 0 failed"'; work "$D"; work "$D"; m="$(git -C "$D" rev-parse main)"
  [ "$b" != SHA ] || b="$(git -C "$D" rev-parse HEAD~1)"
  out="$(P run --lane n4 --dir "$D" --base "$b" --cmd true 2>&1)"
  [ "$(jq -r '.sha + " " + .ref' "$OSRC_HOME/proof/n4/base.json")" = "$m lane-start" ] && grep -q 'refused' <<<"$out" && [ "$(jq -r .base_sha "$OSRC_HOME/proof/n4/proof.json")" = "$m" ] \
    && ok "nit: unpinned --base ${b:0:10} is refused; pinned the lane-start head instead" || bad "nit base $b: $out $(cat "$OSRC_HOME/proof/n4/base.json" 2>/dev/null)"
  rm -rf "$OSRC_HOME/proof/n4"
done
D="$TMP/n4main"; mkdir -p "$D" && ( cd "$D" && git init -q -b main && echo a > a && git add -A && git commit -qm a && echo b > b && git add -A && git commit -qm b )
out="$(P run --lane n4m --dir "$D" --base HEAD~1 --cmd true 2>&1)"; r=$?
[ "$r" != 0 ] && [ ! -f "$OSRC_HOME/proof/n4m/base.json" ] && grep -q 'proof base n4m' <<<"$out" && ok "nit: no lane-start head to find: refused, names the pin command, pins nothing" || bad "nit base main rc=$r [$out]"
# Nit: a sibling worktree of the lane's repo is not the lane's worktree.
D="$TMP/n5"; mk "$D" 'echo "1 passed, 0 failed"'; work "$D"; osrc_done_set n5 "check:true" "$D"
git -C "$D" worktree add -q -b sib "$TMP/n5sib" >/dev/null 2>&1; work "$TMP/n5sib"
P run --lane n5 --dir "$TMP/n5sib" >/dev/null 2>&1; g="$(osrc_proof_gate n5 "$(git -C "$TMP/n5sib" rev-parse HEAD)")"
[ $? = 1 ] && grep -q 'not in the lane worktree' <<<"$g" && ok "nit: a proof from a sibling worktree does not pass the gate" || bad "nit sibling: $g"
P run --lane n5 --dir "$D" >/dev/null 2>&1; g="$(osrc_proof_gate n5)"; [ $? = 0 ] && ok "nit: the lane's own worktree passes" || bad "nit own wt: $g"

echo "=== Round 4 (redesign): stated verdicts, the pin never moves in a lane; each fails on 5622f81 ==="
IT() { printf '%s/review/items/%s.json' "$OSRC_HOME" "$1"; }
# Stated verdicts: the text below line 1 never routes.
i="$(mkitem v4a "$S1" "$(printf 'VERDICT: CHANGES must-fix=1 nit=0 pre-existing=0\n### [nit]\n- run.sh:4 the lock is dropped on retry')")"
[ "$(jq -r .verdict "$(IT "$i")")" = CHANGES ] && ok "V1: a '### [nit]' section over an untagged finding: the stated must-fix=1 routes CHANGES" || bad "V1: $(jq -c . "$(IT "$i")")"
i="$(mkitem v4b "$S1" "$(printf 'VERDICT: MERGE\n## Must-fix\n- [x] [must-fix] run.sh:4 lock dropped: fixed\nMust-fix: none')")"
[ "$(jq -r .verdict "$(IT "$i")")" = MERGE ] && ok "V2: '- [x] [must-fix] ... fixed' and 'Must-fix: none' under VERDICT: MERGE merge" || bad "V2: $(jq -c . "$(IT "$i")")"
printf 'VERDICT: CHANGES must-fix=1 nit=0 pre-existing=0\n## Must-fix\n- [x] old.sh:1 fixed\n  checked with a test\n- [ ] new.sh:2 still racy\n' > "$TMP/v4c"
pr="$(_osrc_sev_prior "$TMP/v4c")"; grep -q 'new.sh:2 still racy' <<<"$pr" && ! grep -q 'old.sh\|checked with' <<<"$pr" && ok "V3: checked '- [x] ... fixed' items (and their lines) never return as open must-fix" || bad "V3: $pr"
# Malformed: back to the reviewer once, then a person.
export OSRC_VERDICT_SETTLE_SECS=0
i="$(mkitem v4m "$S1" "$(printf 'MERGE\nlooks fine')")"
ev="$(osrc_review_events 2>/dev/null)"
[ "$(jq -r '.state + " " + (.bad_verdicts|tostring)' "$(IT "$i")")" = "inflight 1" ] && [ -f "$OSRC_HOME/review/$i.VERDICT.bad1" ] && [ ! -f "$OSRC_HOME/review/$i.VERDICT" ] \
  && grep -q '^EVENT question v4m .*back to the reviewer once' <<<"$ev" && grep -q '^NEXT .*session send .*VERDICT: CHANGES must-fix=<n>' <<<"$ev" \
  && ok "V4: a malformed first line goes back to the REVIEWER once (file set aside, NEXT tells it the exact format)" || bad "V4: $(jq -c . "$(IT "$i")") [$ev]"
printf '**VERDICT: MERGE**\n' > "$OSRC_HOME/review/$i.VERDICT"; _osrc_review_ingest; ev="$(osrc_review_events 2>/dev/null)"
[ "$(jq -r .state "$(IT "$i")")" = needs-you ] && grep -q '^EVENT failed v4m .*unusable verdict twice' <<<"$ev" && grep -q "^NEXT osrc review show $i" <<<"$ev" \
  && ok "V4: a second malformed verdict lands on needs-you (EVENT failed, never guessed, no loop)" || bad "V4b: $(jq -c . "$(IT "$i")") [$ev]"
h="$(osrc_proof_hub_lane '{"id":"v4m","status":"Building"}')"
[ "$(jq -r .reviewNeedsYou.item <<<"$h")" = "$i" ] && [ "$(osrc_proof_hub_counts "[$h]" | jq -r .needsYouLanes)" = 1 ] && grep -q reviewNeedsYou "$HERE/../lib/hub-assets/hub-proof.js" \
  && ok "V4: Mission Control counts it under needs you" || bad "V4 hub: $h"
cmd_review requeue "$i" --force >/dev/null 2>&1; [ "$(jq -r '.state + " " + (.bad_verdicts|tostring)' "$(IT "$i")")" = "queued 0" ] && ok "V4: review requeue (a person) clears the count" || bad "V4 requeue: $(jq -c . "$(IT "$i")")"
# Ten realistic reviewer outputs.
n=0; for case in \
  'MERGE|VERDICT: MERGE\n\nClean diff, tests cover the new branch.' \
  'MERGE|VERDICT: MERGE  \r\nNo findings.' \
  'CHANGES|VERDICT: CHANGES must-fix=2 nit=1 pre-existing=0\n## Must-fix\n1. lib/a.sh:40 unquoted $dir\n2. lib/b.sh:9 rc ignored\n## Nits\n- typo' \
  'MERGE|VERDICT: CHANGES must-fix=0 nit=3 pre-existing=1\n## Nits\n- a\n- b\n- c\n## Pre-existing\n- old leak in c.sh' \
  'BLOCK|VERDICT: BLOCK\nThis deletes the user state dir; do not land.' \
  'bounce|MERGE\nlgtm' \
  'bounce|Here is my review.\nVERDICT: MERGE' \
  'bounce|VERDICT: CHANGES must-fix=1\n- a.sh:1 bug' \
  'bounce|## Verdict: CHANGES\n- [must-fix] a.sh:1' \
  'bounce|VERDICT: CHANGES must-fix=one nit=0 pre-existing=0' ; do
  n=$((n + 1)); want="${case%%|*}"; body="${case#*|}"
  i="$(mkitem "real$n" "$S1" "$(printf "$body")")"
  got="$(jq -r 'if .state == "verdict" then .verdict elif (.bad_verdicts // 0) == 1 then "bounce" else .state end' "$(IT "$i")")"
  [ "$got" = "$want" ] && ok "V5.$n: realistic reviewer output -> $want" || bad "V5.$n: want $want got $got ($body)"
done
unset OSRC_VERDICT_SETTLE_SECS
# The pin never moves inside a lane.
D="$TMP/p4"; mk "$D" 'echo "1 passed, 0 failed"'; osrc_done_set p4 "check:true" "$D"; work "$D"
pin0="$(jq -r .sha "$OSRC_HOME/proof/p4/base.json")"
OSRC_LANE=p4 P run --lane p4 --dir "$D" >/dev/null 2>&1; [ $? = 0 ] && ok "P1: in-lane run on the pinned branch and worktree proves" || bad "P1"
( cd "$D" && git checkout -qb other ); old="$(git -C "$D" rev-parse main)"
out="$(OSRC_LANE=p4 P run --lane p4 --dir "$D" --base "$old" 2>&1)"; r=$?
[ "$r" = 4 ] && [ "$(jq -r .sha "$OSRC_HOME/proof/p4/base.json")" = "$pin0" ] && grep -q "proof base p4 --dir $(cd "$D" && pwd -P) $pin0" <<<"$out" \
  && ok "P2: in-lane branch switch + --base <old> exits 4 with the one fixing command; the pin is unchanged" || bad "P2 rc=$r [$out]"
out="$(OSRC_LANE=p4 P run --lane p4 --dir "$D" 2>&1)"; [ $? = 4 ] && ok "P2: a plain in-lane run on the switched branch exits 4 too" || bad "P2b [$out]"
( cd "$D" && git checkout -q lane ); ( cd "$D" && git commit -q --allow-empty -m m2 && git checkout -q main && git commit -q --allow-empty -m mainmoves && git checkout -q lane )
out="$(OSRC_LANE=p4 P run --lane p4 --dir "$D" --base main 2>&1)"; r=$?
[ "$r" = 0 ] && [ "$(jq -r .sha "$OSRC_HOME/proof/p4/base.json")" = "$pin0" ] && grep -q 'ignored inside the lane; using the pinned base' <<<"$out" && ok "P3 (round 5): in-lane --base <moved main> is ignored with a notice; the pin is unchanged" || bad "P3 rc=$r [$out]"
D2="$TMP/p4b"; mk "$D2" 'echo "1 passed, 0 failed"'; work "$D2"
out="$(OSRC_LANE=p4 P run --lane p4 --dir "$D2" 2>&1)"; r=$?
[ "$r" = 4 ] && [ "$(jq -r .sha "$OSRC_HOME/proof/p4/base.json")" = "$pin0" ] && [ "$(_osrc_proof_rounds p4 | jq -r .fails)" = 0 ] && ok "P4: in-lane run from another worktree (0 failed rounds) exits 4, nothing cleared" || bad "P4 rc=$r [$out]"
D3="$TMP/p5"; mk "$D3" 'echo "1 passed, 0 failed"'; work "$D3"
out="$(OSRC_LANE=p5 P run --lane p5 --dir "$D3" 2>&1)"; r=$?
[ "$r" = 4 ] && [ ! -f "$OSRC_HOME/proof/p5/base.json" ] && grep -q 'proof base p5' <<<"$out" && ok "P5: in-lane with no pin exits 4 and pins nothing" || bad "P5 rc=$r [$out]"
out="$(OSRC_LANE=p5 P base p5 --dir "$D3" main 2>&1)"; [ $? != 0 ] && P base p5 --dir "$D3" "$(git -C "$D3" rev-parse main)" >/dev/null 2>&1 && OSRC_LANE=p5 P run --lane p5 --dir "$D3" >/dev/null 2>&1 \
  && ok "P5: the fixing command is refused in-lane, works from the orchestrator, then the lane proves" || bad "P5 fix [$out]"
D4="$TMP/p6"; mkdir -p "$D4/.outsourcerer" && ( cd "$D4" && git init -q -b main && printf '#!/bin/sh\necho "1 passed, 0 failed"\n' > .outsourcerer/verify && chmod +x .outsourcerer/verify && git add -A && git commit -qm base )
osrc_done_set p6 "check:true" "$D4"; pin6="$(jq -r .sha "$OSRC_HOME/proof/p6/base.json")"
( cd "$D4" && git checkout -qb feat ); work "$D4"
OSRC_LANE=p6 P run --lane p6 --dir "$D4" >/dev/null 2>&1; r=$?
[ "$r" = 0 ] && [ "$(jq -r '.sha + " " + .branch + " " + (.branch_locked|tostring)' "$OSRC_HOME/proof/p6/base.json")" = "$pin6 feat true" ] && ok "P6: a lane that creates its branch after session start keeps its pin (branch adopted once)" || bad "P6 rc=$r $(cat "$OSRC_HOME/proof/p6/base.json")"
( cd "$D4" && git checkout -qb feat2 ); out="$(OSRC_LANE=p6 P run --lane p6 --dir "$D4" 2>&1)"; [ $? = 4 ] && ok "P6: a second branch after that is a switch: exits 4" || bad "P6b [$out]"
# Nits.
D="$TMP/c4"; mk "$D" 'echo "1 passed, 0 failed"'; work "$D"
P run --lane c4 --dir "$D" --cmd 'echo "test_retry: 5 passed after 2 failed attempts ... ok"' >/dev/null 2>&1
[ "$(jq -r .ok "$OSRC_HOME/proof/c4/proof.json")" = true ] && ok "N1: a test title carrying both counts, no later summary: the green exit code stands" || bad "N1: $(jq -c '{ok,stamp}' "$OSRC_HOME/proof/c4/proof.json")"
D="$TMP/t4"; mk "$D" 'echo "1 passed, 0 failed"'; work "$D"; work "$D"; ( cd "$D" && git tag x HEAD~1 ); m="$(git -C "$D" rev-parse main)"
out="$(P run --lane t4 --dir "$D" --base x --cmd true 2>&1)"
[ "$(jq -r '.sha + " " + .ref' "$OSRC_HOME/proof/t4/base.json")" = "$m lane-start" ] && grep -q refused <<<"$out" && ok "N2: a lane-made tag as --base is refused like HEAD~1 (lane-start pinned)" || bad "N2: [$out] $(cat "$OSRC_HOME/proof/t4/base.json" 2>/dev/null)"

echo "=== Round 5 (review of the redesign: must-fix + nits a-e; each fails on 767ea2d) ==="
# MUST-FIX: in-lane --base <ref> after <ref> moved: ignored with a notice, the pin stays, the rerun works.
D="$TMP/q1"; mk "$D" 'echo "1 passed, 0 failed"'; osrc_done_set q1 "check:true" "$D"; work "$D"; pq="$(jq -r .sha "$OSRC_HOME/proof/q1/base.json")"
( cd "$D" && git checkout -q main && git commit -q --allow-empty -m "main moves" && git checkout -q lane )
for k in 1 2; do
  out="$(OSRC_LANE=q1 P run --lane q1 --dir "$D" --base main 2>&1)"; r=$?
  [ "$r" = 0 ] && grep -q "ignored inside the lane; using the pinned base ${pq:0:7}" <<<"$out" && [ "$(jq -r .sha "$OSRC_HOME/proof/q1/base.json")" = "$pq" ] && [ "$(jq -r .base_sha "$OSRC_HOME/proof/q1/proof.json")" = "$pq" ] \
    && ok "MF.$k: in-lane --base <moved main> proves against the pinned base (notice, pin unchanged)" || bad "MF.$k rc=$r [$out]"
done
out="$(OSRC_LANE=q1 P run --lane q1 --dir "$D" --base HEAD 2>&1)"; [ $? = 0 ] && ok "MF: in-lane --base HEAD is ignored too (never an error)" || bad "MF HEAD [$out]"
# The printed fix for a real mismatch is not a no-op: run it, and the lane's rerun proves.
( cd "$D" && git checkout -qb q1other ); out="$(OSRC_LANE=q1 P run --lane q1 --dir "$D" 2>&1)"; r=$?
fixc="$(sed -n 's/.*Fix (the orchestrator, outside the lane): osrc proof //p' <<<"$out")"
[ "$r" = 4 ] && [ -n "$fixc" ] && P $fixc >/dev/null 2>&1 && OSRC_LANE=q1 P run --lane q1 --dir "$D" >/dev/null 2>&1 && ok "MF: the printed 'proof base ...' fixes it: the lane's rerun proves" || bad "MF fix rc=$r [$out] [$fixc]"
# (a) counts that contradict the body bounce to the reviewer like a malformed line.
export OSRC_VERDICT_SETTLE_SECS=0
n=0; for case in \
  'bounce|VERDICT: MERGE\n## Must-fix\n- a.sh:1 still open' \
  'bounce|VERDICT: CHANGES must-fix=0 nit=1 pre-existing=0\n## Must-fix\n1. b.sh:2 rc ignored\n## Nits\n- typo' \
  'bounce|VERDICT: CHANGES must-fix=2 nit=1 pre-existing=0\n## Nits\n- typo' \
  'bounce|VERDICT: CHANGES must-fix=1 nit=0 pre-existing=0\n## Must-fix\n- [x] old.sh:1 fixed' \
  'MERGE|VERDICT: MERGE\n## Must-fix\n- none\n## Nits\n- spacing' \
  'MERGE|VERDICT: MERGE\n## Must-fix\n- [x] [must-fix] run.sh:4 fixed\nMust-fix: none' \
  'CHANGES|VERDICT: CHANGES must-fix=1 nit=0 pre-existing=0\n## Must-fix\n- [x] old.sh:1 fixed\n- new.sh:2 open' ; do
  n=$((n + 1)); want="${case%%|*}"; i="$(mkitem "ca$n" "$S1" "$(printf "${case#*|}")")"
  got="$(jq -r 'if .state == "verdict" then .verdict elif (.bad_verdicts // 0) == 1 then "bounce" else .state end' "$(IT "$i")")"
  [ "$got" = "$want" ] && ok "a.$n: -> $want$( [ "$want" != bounce ] || printf ' (%s)' "$(jq -r .invalid_why "$(IT "$i")")")" || bad "a.$n: want $want got $got"
done
ev="$(osrc_review_events 2>/dev/null)"; grep -q '^EVENT question ca1 .*not usable: it says MERGE but its ## Must-fix section lists 1 open item' <<<"$ev" && grep -q '^NEXT .*with counts that match the findings' <<<"$ev" \
  && ok "a: the bounce tells the reviewer what contradicts what" || bad "a event: $ev"
# (b) a needs-you item is cleared when the lane pushes a new head.
i="$(mkitem nb "$S1" "$(printf 'MERGE')")"; printf 'nope\n' > "$OSRC_HOME/review/$i.VERDICT"; _osrc_review_ingest
[ "$(jq -r .state "$(IT "$i")")" = needs-you ] && _osrc_review_supersede nb "$S2" && [ "$(jq -r '.state + " " + .stale_by' "$(IT "$i")")" = "superseded $S2" ] \
  && [ "$(osrc_proof_hub_lane '{"id":"nb","status":"Building"}' | jq -r '.reviewNeedsYou // "none"')" = none ] && ok "b: needs-you is cleared (superseded) when the lane pushes a new head" || bad "b: $(jq -c . "$(IT "$i")")"
# (c) pre-existing findings on a CHANGES verdict are kept as notes.
i="$(mkitem nc "$S1" "$(printf 'VERDICT: CHANGES must-fix=1 nit=0 pre-existing=1\n## Must-fix\n- a.sh:1 race\n## Pre-existing\n- z.sh:9 old leak, not this change')")"
[ "$(jq -r '.verdict + " " + .notes' "$(IT "$i")")" = "CHANGES $OSRC_HOME/review/$i.VERDICT" ] && grep -q 'z.sh:9 old leak' "$OSRC_HOME/review/notes/nc.md" && ! grep -q 'z.sh:9' <<<"$(_osrc_review_sendback "$i")" \
  && ok "c: pre-existing on CHANGES: item .notes and review/notes/<lane>.md, never in the sendback" || bad "c: $(jq -c '{verdict,notes}' "$(IT "$i")")"
unset OSRC_VERDICT_SETTLE_SECS
# (d) an in-lane exit 4 raises an EVENT through the event chain supervise polls, and the fix clears it.
D="$TMP/qd"; mk "$D" 'echo "1 passed, 0 failed"'; osrc_done_set qd "check:true" "$D"; work "$D"; ( cd "$D" && git checkout -qb qdother )
OSRC_LANE=qd P run --lane qd --dir "$D" >/dev/null 2>&1; r=$?
ev="$(osrc_remote_events 2>/dev/null)"
[ "$r" = 4 ] && grep -q '^EVENT question qd .*proof run exited 4 inside the lane: qd is pinned on branch lane, this is qdother' <<<"$ev" && grep -q '^NEXT osrc proof base qd --dir ' <<<"$ev" \
  && ok "d: in-lane exit 4 -> EVENT question with the fixing command as NEXT (osrc_remote_events, which supervise polls)" || bad "d rc=$r [$ev]"
P base qd --dir "$D" "$(jq -r .sha "$OSRC_HOME/proof/qd/base.json")" >/dev/null 2>&1
[ ! -f "$OSRC_HOME/proof/qd/blocked.json" ] && ! grep -q '^EVENT question qd ' <<<"$(osrc_proof_events)" && ok "d: running the fix clears the event" || bad "d clear"
# (e) a reused lane name whose old lane never committed does not adopt the stale pin.
D="$TMP/qe"; mk "$D" 'echo "1 passed, 0 failed"'; osrc_done_set qe "check:true" "$D"; stale="$(jq -r .sha "$OSRC_HOME/proof/qe/base.json")"
osrc_done_clear qe   # session stop; the old lane never committed
( cd "$D" && git checkout -q main && git commit -q --allow-empty -m "other lanes merged" && git checkout -qb lane2 ); m="$(git -C "$D" rev-parse main)"; work "$D"
out="$(OSRC_LANE=qe P run --lane qe --dir "$D" 2>&1)"; r=$?
[ "$r" = 4 ] && [ "$(jq -r .sha "$OSRC_HOME/proof/qe/base.json")" = "$stale" ] && [ "$(jq -r '.branch_locked // false' "$OSRC_HOME/proof/qe/base.json")" = false ] && grep -q "proof base qe --dir .* $m" <<<"$out" \
  && ok "e: in-lane, the new lane does not adopt the ended pin; the fix names its own start ($m)" || bad "e in-lane rc=$r [$out] $(cat "$OSRC_HOME/proof/qe/base.json")"
D="$TMP/qf"; mk "$D" 'echo "1 passed, 0 failed"'; osrc_done_set qf "check:true" "$D"; stale="$(jq -r .sha "$OSRC_HOME/proof/qf/base.json")"; osrc_done_clear qf
( cd "$D" && git checkout -q main && git commit -q --allow-empty -m "other lanes merged" && git checkout -q lane && git reset -q --hard main ); m="$(git -C "$D" rev-parse main)"
osrc_done_set qf "check:true" "$D"
[ "$(jq -r .sha "$OSRC_HOME/proof/qf/base.json")" = "$m" ] && ok "e: a new session start under the reused name (same branch, old lane never committed) pins its own start, not the stale pin" || bad "e start: $(cat "$OSRC_HOME/proof/qf/base.json")"
D="$TMP/qg"; mk "$D" 'echo "1 passed, 0 failed"'; osrc_done_set qg "check:true" "$D"; keep="$(jq -r .sha "$OSRC_HOME/proof/qg/base.json")"; work "$D"; osrc_done_clear qg
osrc_done_set qg "check:true" "$D"
[ "$(jq -r '.sha + " " + (.ended // false | tostring)' "$OSRC_HOME/proof/qg/base.json")" = "$keep false" ] && OSRC_LANE=qg P run --lane qg --dir "$D" >/dev/null 2>&1 \
  && ok "e control: the same lane restarted (it committed on its branch) keeps its pin and proves" || bad "e control: $(cat "$OSRC_HOME/proof/qg/base.json")"

echo
echo "test_proof: $pass passed, $fail failed"
[ "$fail" = 0 ]
