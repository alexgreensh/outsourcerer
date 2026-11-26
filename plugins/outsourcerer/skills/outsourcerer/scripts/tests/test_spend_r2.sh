#!/usr/bin/env bash
# test_spend_r2.sh — live-test round 2 (0.18.0) spend findings, end to end against stub CLIs.
#   F5  loop verify/escalate: a spend refusal stops as needs-approval (no attempt, no escalation, no
#       receipt); --spend-ok on the loop is accepted and reaches each attempt.
#   F6  fanout with a paid model refuses up front ("Nothing was started"), mints no job.
#   F7  a spend refusal inside a job carries owner/job, so supervise replays it.
#   F8  after consent the receipt says billed as paid, and no "[free-tier]" banner.
#   F16 model aliases route case-insensitively; a case-variant of a Free Devin id says "did you mean".
#   F5' factory: `task add --spend-ok -m X` consents exactly X for that task's dispatch.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
for _v in OSRC_SPEND_OK OSRC_JOB_DIR OSRC_JOB_TOKEN CLAUDE_CODE_SESSION_ID TMUX; do unset "$_v"; done
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home" "$T/w" "$T/osrc/disk-policy"
printf 'OSRC_DISK_MIN_GB=0\nOSRC_DISK_PAUSE_GB=0\n' > "$T/osrc/disk-policy/settings"
cat > "$T/bin/devin" <<EOF
#!/usr/bin/env bash
echo "devin \$*" >> "$T/devin.log"
case "\${1:-}" in auth) echo "Logged in as stub@example.com" ;; models) exit 1 ;; *) echo "ok done" ;; esac
exit 0
EOF
chmod +x "$T/bin/devin"
# offline (the stub has no catalog): glm-5.2 bills unknown -> metered; swe-2-high is the proven Free id
E() { ( cd "$T/w" && HOME="$T/home" OSRC_HOME="$T/osrc" PATH="$T/bin:$PATH" OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 \
        OSRC_NO_ADVISE=1 OSRC_NO_AUTODETACH=1 OSRC_HEARTBEAT_DISABLED=1 OSRC_ESCALATE_PER_TIER=1 bash "$SRC" "$@" 2>&1 </dev/null ); }
launched() { grep -- " -p" "$T/devin.log" 2>/dev/null | grep -c -- "--model $1 "; }

# ---- F5 loop verify ----
: > "$T/devin.log"
out="$(E --provider devin loop verify -m glm-5.2 --check true --max 3 "fix it")"; rc=$?
lid="$(ls "$T/osrc/loops" | head -1)"
if [ "$rc" = 3 ] && grep -q '^needs-approval$' <<<"$out" && [ "$(launched glm-5.2)" = 0 ] \
   && [ "$(cat "$T/osrc/loops/$lid/attempt")" = 0 ] && grep -q "^NEXT .*--spend-ok loop resume $lid" <<<"$out"; then
  ok "F5 verify: a spend refusal stops as needs-approval, no attempt counted, NEXT resumes with --spend-ok"
else bad "F5 verify: rc=$rc attempt=$(cat "$T/osrc/loops/$lid/attempt" 2>/dev/null) out=$(tail -4 <<<"$out")"; fi
grep -q 'the check reported\|escalating' <<<"$out" && bad "F5 verify: refusal graded as a check failure" || ok "F5 verify: refusal is not graded as a check failure"
out="$(E loop resume "$lid" --spend-ok)"; rc=$?
[ "$rc" = 0 ] && [ "$(launched glm-5.2)" = 1 ] && ok "F5 verify: 'loop resume --spend-ok' reaches the attempt (glm-5.2 launched once)" \
  || bad "F5 verify: consented resume rc=$rc launched=$(launched glm-5.2): $(tail -3 <<<"$out")"

# ---- F5 loop escalate ----
: > "$T/devin.log"; rm -rf "$T/osrc/loops"
out="$(E --provider devin loop escalate --ladder swe-2-high,glm-5.2 --check false --max 4 "fix it")"; rc=$?
lid="$(ls "$T/osrc/loops" | head -1)"
if [ "$rc" = 3 ] && grep -q '^needs-approval$' <<<"$out" && [ "$(launched glm-5.2)" = 0 ] \
   && ! grep -q 'glm-5.2' "$T/osrc/loops/$lid/receipts.tsv" && grep -q '^NEXT .*loop escalate --spend-ok ' <<<"$out"; then
  ok "F5 escalate: the refused paid rung stops as needs-approval with no receipt for it"
else bad "F5 escalate: rc=$rc receipts=$(cat "$T/osrc/loops/$lid/receipts.tsv" 2>/dev/null | tr '\n' ';') out=$(tail -3 <<<"$out")"; fi
: > "$T/devin.log"
out="$(E --provider devin loop escalate --spend-ok --ladder swe-2-high,glm-5.2 --check false --max 2 "fix it")"; rc=$?
[ "$(launched glm-5.2)" = 1 ] && ok "F5 escalate: 'loop escalate --spend-ok' runs the paid rung" || bad "F5 escalate: consented rung not launched: $(tail -3 <<<"$out")"

# ---- F6 fanout ----
rm -rf "$T/osrc/jobs"
out="$(E --provider devin fanout --cloud-ack -m glm-5.2 -- "t1" "t2")"; rc=$?
njobs="$(ls "$T/osrc/jobs" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$rc" -ne 0 ] && [ "$njobs" = 0 ] && grep -q 'Nothing was started' <<<"$out" && grep -q '^EVENT approval dv .*paid-lane:dv/glm-5.2' <<<"$out" \
   && grep -q '^NEXT .*fanout --spend-ok' <<<"$out" && ! grep -q 'launched' <<<"$out"; then
  ok "F6 fanout: a paid model refuses the whole fanout up front, no job minted"
else bad "F6 fanout: rc=$rc jobs=$njobs out=$(tail -3 <<<"$out")"; fi
out="$(E --provider devin fanout --cloud-ack -m swe-2-high -- "t1")"; rc=$?
[ "$rc" = 0 ] && grep -q 'all 1 launched' <<<"$out" && ok "F6 fanout: a Free model still launches" || bad "F6 fanout free: rc=$rc $(tail -2 <<<"$out")"

# ---- F7 supervise replays a job's spend refusal ----
J="$T/osrc/jobs/20261126-000000-f7job"; mkdir -p "$J" "$T/osrc/owners/S7" "$T/osrc/supervise/S7"
: > "$T/osrc/owners/S7/${J##*/}"; date +%s > "$T/osrc/supervise/S7/tick.time"; : > "$T/osrc/lanes/events.jsonl" 2>/dev/null
( cd "$T/w" && OSRC_HOME="$T/osrc" OSRC_SOURCED=1 OSRC_JOB_DIR="$J" PATH="$T/bin:$PATH" \
  bash -c '. "$1" >/dev/null 2>&1; ( OSRC_SPEND_NEXT=next-x _osrc_spend_gate dv glm-5.2 devin "job dispatch" ) >/dev/null 2>&1' _ "$SRC" )
row="$(tail -1 "$T/osrc/lanes/events.jsonl" 2>/dev/null)"
[ "$(jq -r '.owner + "|" + .job' <<<"$row" 2>/dev/null)" = "S7|${J##*/}" ] && ok "F7: a job's spend event names its owner and job" || bad "F7: event row lacks owner/job: $row"
out="$( cd "$T/w" && HOME="$T/home" OSRC_HOME="$T/osrc" OSRC_HEARTBEAT_DISABLED=1 OSRC_SUPERVISE_POLL=1 OSRC_SUPERVISE_SETTLE=0 \
        OSRC_SUPERVISE_TICK_SECS=86400 perl -e 'alarm 20; exec @ARGV' bash "$SRC" supervise --session S7 --once 2>/dev/null )"
grep -q '^EVENT approval dv .*paid-lane:dv/glm-5.2' <<<"$out" && ok "F7: supervise --once replays the job's approval event" || bad "F7: supervise did not replay: [$out]"

# ---- F8 receipt follows the gate verdict ----
: > "$T/devin.log"
out="$(E --provider devin run --spend-ok -m glm-5.2 "x")"
if grep -q 'receipt\] billed as paid' <<<"$out" && ! grep -q 'free-tier\]' <<<"$out" && ! grep -q 'receipt\] \$0 cash' <<<"$out"; then
  ok "F8: a consented metered launch prints 'billed as paid' and no free-tier banner"
else bad "F8: $(grep -E 'free-tier|receipt' <<<"$out")"; fi
out="$(E --provider devin run -m swe-2-high "x")"
grep -q 'receipt\] \$0 cash' <<<"$out" && ok "F8: a Free launch keeps the \$0 receipt" || bad "F8 free receipt: $(grep receipt <<<"$out")"

# ---- F16 case folding ----
r="$(OSRC_HOME="$T/osrc" OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1; printf "%s=%s" "$(resolve_model_row SOL)" "$(resolve_model_row sol)"' _ "$SRC")"
[ "${r%%=*}" = "${r#*=}" ] && [ -n "${r%%=*}" ] && ok "F16: -m SOL resolves to the same row as -m sol ($r)" || bad "F16: SOL/sol rows differ: $r"
: > "$T/devin.log"; out="$(E --provider devin run -m SWE-2-HIGH "x")"; rc=$?
[ "$rc" = 0 ] && [ "$(launched swe-2-high)" = 1 ] && ok "F16: -m SWE-2-HIGH launches the Free swe-2-high, no consent asked" || bad "F16: rc=$rc $(tail -2 <<<"$out")"
out="$( cd "$T/w" && OSRC_HOME="$T/osrc" OSRC_SOURCED=1 PATH="$T/bin:$PATH" bash -c '. "$1" >/dev/null 2>&1; OSRC_SPEND_NEXT="x run --spend-ok -m Swe-2-Flash-High hi" _osrc_spend_gate dv Swe-2-Flash-High devin probe' _ "$SRC" 2>&1 </dev/null )"
if grep -q 'did you mean swe-2-flash-high (free)' <<<"$out" && grep -q '^NEXT x run -m swe-2-flash-high hi$' <<<"$out" && ! grep -q 'Re-run with --spend-ok' <<<"$out"; then
  ok "F16: a case-variant of a Free id is refused with 'did you mean', not a --spend-ok offer"
else bad "F16 hint: $out"; fi

# ---- F5' factory per-task consent ----
R="$T/repo"; mkdir -p "$R"; git -C "$R" init -q 2>/dev/null; git -C "$R" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init 2>/dev/null
FO() { ( cd "$R" && HOME="$T/home" OSRC_HOME="$T/osrc" bash "$SRC" "$@" 2>&1 </dev/null ); }
FO plan new fx --goal g >/dev/null
out="$(FO task add 'paid one' -m glm-5.2 --spend-ok)"; ta="$(grep -E '^t[0-9]+$' <<<"$out")"
grep -q 'consent recorded for glm-5.2' <<<"$out" && ok "F5': task add --spend-ok names the one id it consents" || bad "F5': no consent line: $out"
tb="$(FO task add 'no consent' -m glm-5.2 | grep -E '^t[0-9]+$')"
out="$(FO task add 'no model' --spend-ok)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'needs -m' <<<"$out" && ok "F5': task add --spend-ok without -m is refused" || bad "F5': consent without model: rc=$rc $out"
( cd "$R" && HOME="$T/home" OSRC_HOME="$T/osrc" OSRC_SOURCED=1 DL="$T/disp.log" bash -c '. "$1" >/dev/null 2>&1
  _task_bg_launch() { shift; echo "ARGV $(printf "%s " "$@" | tr "\n" " " | cut -c1-40) OWN=${_OSRC_TASK_OWN_CONSENT:-0}" >> "$DL"; echo 20261126-000001-abcdef; }
  _task_dispatch fx "$2"; _task_dispatch fx "$3"' _ "$SRC" "$ta" "$tb" >/dev/null 2>&1 )
d="$(cat "$T/disp.log" 2>/dev/null)"
a1="$(sed -n 1p <<<"$d")"; a2="$(sed -n 2p <<<"$d")"
case "$a1" in *"--spend-ok -m glm-5.2"*OWN=1) ok "F5': the consented task dispatches with --spend-ok bound to it" ;; *) bad "F5': consented dispatch: $a1" ;; esac
case "$a2" in *--spend-ok*|*OWN=1) bad "F5': consent leaked to another task: $a2" ;; *ARGV*) ok "F5': a task without its own consent gets none" ;; *) bad "F5': second dispatch: $a2" ;; esac
grep -q '"spend_ok"' "$T/osrc/plans/fx/tasks/$tb.json" 2>/dev/null && bad "F5': unconsented task carries spend_ok" || ok "F5': spend_ok is set only by the flag"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
