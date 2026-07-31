#!/usr/bin/env bash
# test_output_truncation.sh — a delegate that exhausts its OUTPUT-token budget must be named as
# such, not filed as a generic failure.
#
# The failure mode this guards: an engine that runs out of output tokens exits non-zero and leaves
# a PARTIAL answer in out.log. The partial answer looks like a real answer. Classified as a plain
# "failed" the operator sees an error, keeps the text that is sitting right there, and never learns
# the result was cut off rather than wrong — so a half-finished audit gets treated as a whole one.
# The remedy (smaller batches, or have the delegate write findings to a file and print a summary)
# has to travel with the diagnosis or it does not get applied.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"
export OSRC_HOME="$TMP"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

. "$SRC" >/dev/null 2>&1

wait_for_status() { # <job-dir> <expected-status> <timeout-seconds>
  local jd="$1" expected="$2" timeout="$3" started now status
  started="$(date +%s)"
  while :; do
    status="$(cat "$jd/status" 2>/dev/null || true)"
    [ "$status" = "$expected" ] && return 0
    now="$(date +%s)"
    [ $((now - started)) -lt "$timeout" ] || return 1
    sleep 0.1
  done
}

run_case() {  # <name> <log-body> <exit-code>  — the delegate emits the body, _supervise classifies it
  local jd="$TMP/job-$1"
  local err; err="$(_supervise "$jd" 60 120 300 -- sh -c "printf '%s\n' \"\$1\"; exit $3" _ "$2" 2>&1 >/dev/null)"
  printf '%s\n---\n%s\n---\n%s' "$(cat "$jd/status" 2>/dev/null)" "$(cat "$jd/reason" 2>/dev/null)" "$err"
}

# 1. Truncation signature + non-zero exit -> named, with the remedy attached.
r="$(run_case trunc 'partial findings here
warning: response truncated (model hit max output token limit)
Error: Response truncated: model hit max output token limit.' 1)"
case "$r" in *output-token-limit*) ok "output-token exhaustion is recorded as a distinct reason" ;;
  *) bad "no output-token-limit reason recorded (got: $(printf '%s' "$r" | head -3 | tr '\n' ' '))" ;; esac
printf '%s' "$r" | grep -qi 'CUT SHORT' \
  && ok "operator is told the logged answer is incomplete, not merely that the run failed" \
  || bad "diagnostic does not say the output is incomplete"
printf '%s' "$r" | grep -qiE 'smaller batches|write .*findings.* to a file' \
  && ok "diagnostic carries the remedy (split the batch / write to a file)" \
  || bad "diagnostic states the problem but not the remedy"

# 2. A finish_reason=length payload is the same condition in JSON clothing.
r="$(run_case jsonlen '{"choices":[{"finish_reason":"length"}]}' 1)"
case "$r" in *output-token-limit*) ok "finish_reason=length is recognised as the same condition" ;;
  *) bad "JSON finish_reason=length not recognised" ;; esac

# 3. NEGATIVE — an ordinary failure must NOT be relabelled as truncation.
r="$(run_case plain 'connection refused talking to the API' 1)"
case "$r" in *output-token-limit*) bad "ordinary failure mislabelled as output-token exhaustion" ;;
  *) ok "ordinary failures are not mislabelled as truncation" ;; esac

# 4. NEGATIVE — a SUCCESSFUL run that merely mentions the phrase (e.g. a delegate reviewing this
#    very code, or a diff of it) must not be hijacked. Echoed text is not a death signal.
r="$(run_case echo 'I reviewed the handler for "max output token limit" and it looks correct.
OSRC::DONE reviewed' 0)"
case "$r" in *output-token-limit*) bad "echoed phrase on a clean exit poisoned the classification" ;;
  *) ok "echoed phrase on a zero exit does not trigger the truncation path" ;; esac

# 5. NEGATIVE — incidental prose about truncation EARLY in a run that later fails for an unrelated
#    reason must not be rediagnosed as output-token exhaustion. The remedy would be wrong advice.
body="the upstream API sent a response truncated mid-body, retrying
$(for i in $(seq 1 30); do echo "step $i: continuing normally"; done)
fatal: connection refused talking to the API"
r="$(run_case midrun "$body" 1)"
case "$r" in *output-token-limit*) bad "mid-run mention of truncation mislabelled the real failure" ;;
  *) ok "truncation phrase away from the log tail does not hijack an unrelated failure" ;; esac


# --- A delegate that never speaks is diagnosed, not just executed. -------------------------------
# The stall watchdog reads log growth. A delegate told to write findings to a file and print only at
# the end produces nothing for the whole run, so a healthy long job is indistinguishable from a hang
# and gets stopped at the wedge window. That advice comes from THIS tool (the output-token remedy), so
# the failure it causes has to name itself and hand back the fix.
jd="$TMP/silent"
# The delegate emits ONLY our own launcher banner (every such line starts with '>>> '), then nothing.
OSRC_POLL=1 _supervise "$jd" 2 3 30 -- sh -c 'printf "%s\n" ">>> [outsourcerer] launch banner"; exec tail -f /dev/null' >/dev/null 2>&1 & silent_supervisor=$!
wait_for_status "$jd" wedged 10 || true
wait "$silent_supervisor" 2>/dev/null || true
st="$(cat "$jd/status" 2>/dev/null)"
[ "$st" = "wedged" ] && ok "a silent delegate is still stopped (the watchdog still works)" \
  || bad "silent delegate was not stopped (got '$st')"
[ "$(cat "$jd/reason" 2>/dev/null)" = "silent-delegate" ] \
  && ok "the never-spoke case is recorded distinctly from a work-then-hang stall" \
  || bad "no silent-delegate reason recorded"

# The discriminator must be CONTENT, not a byte count. A delegate that DID produce work and then hung
# is a different failure with a different fix, and must not be handed the silent-delegate advice.
jd2="$TMP/spoke"
OSRC_POLL=1 _supervise "$jd2" 2 3 30 -- sh -c 'printf "%s\n" ">>> banner" "real work output"; exec tail -f /dev/null' >/dev/null 2>&1 & spoke_supervisor=$!
wait_for_status "$jd2" wedged 10 || true
wait "$spoke_supervisor" 2>/dev/null || true
[ "$(cat "$jd2/status" 2>/dev/null)" = "wedged" ] && [ -z "$(cat "$jd2/reason" 2>/dev/null)" ] \
  && ok "a delegate that produced output then hung is NOT labelled silent" \
  || bad "work-then-hang was mislabelled as a silent delegate"

# The remedy this tool prints for output-token exhaustion must not tell users to do the thing that
# gets their job killed without also telling them how to stay alive.
grep -a 'OUTPUT-TOKEN limit' "$SRC" | grep -q 'OSRC::PROGRESS' \
  && ok "the write-to-a-file remedy also asks for a progress heartbeat" \
  || bad "remedy advises silence with no heartbeat (contradicts the stall watchdog)"


# --- Every env var a user-facing message tells you to set must actually exist. --------------------
# Advice that names a knob the code never reads is worse than no advice: the user sets it, nothing
# changes, and they conclude the tool is broken rather than that the message was.
# Only vars named in messages the USER is told to act on. Vars merely exported for a sibling script
# (the shim) are read elsewhere by design, so scanning the whole shipped tree is the right scope.
missing=""
for v in $(grep -ahoE 'OSRC_[A-Z_]+=<|set OSRC_[A-Z_]+|raise the stall window: OSRC_[A-Z_]+' "$SRC" \
           | grep -oE 'OSRC_[A-Z_]+' | sort -u); do
  grep -rqa "\${$v:-" "$(dirname "$SRC")" || missing="$missing $v"
done
[ -z "$missing" ] && ok "every knob a user-facing message tells you to set is actually read" \
  || bad "message names a knob the code never reads:$missing"


# --- Terminal markers must lead their own line, everywhere they are read. ------------------------
# The delegate is TOLD to "end with OSRC::DONE <summary> or OSRC::BLOCKED <reason>". A delegate that
# finishes and then echoes that reminder puts both markers in one line. Matched anywhere, the last one
# wins and completed work is graded as blocked, so the operator re-runs work that was already done.
# Third instance of this class after the print-mode detector and the truncation scan.
mkcase() { local n="$1"; shift; local jd="$TMP/mk-$n"
  _supervise "$jd" 60 120 300 -- sh -c 'printf "%s\n" "$@"' _ "$@" >/dev/null 2>&1
  cat "$jd/status" 2>/dev/null; }
r="$(mkcase echo1 "OSRC::DONE finished the work" "reminder: end with OSRC::DONE <summary> or OSRC::BLOCKED <reason>")"
[ "$r" = "done" ] && ok "finishing, then echoing the protocol reminder, stays done" || bad "echoed protocol overrode a real DONE (got '$r')"
r="$(mkcase blk1 "OSRC::BLOCKED need a human decision")"
[ "$r" = "blocked" ] && ok "a real BLOCKED on its own line is still blocked" || bad "real BLOCKED lost (got '$r')"
r="$(mkcase order1 "OSRC::BLOCKED early doubt" "OSRC::DONE actually finished")"
[ "$r" = "done" ] && ok "the LAST anchored marker still wins" || bad "marker ordering broke (got '$r')"
r="$(mkcase quote1 "I will print OSRC::BLOCKED if I get stuck" "OSRC::DONE finished")"
[ "$r" = "done" ] && ok "a marker quoted mid-sentence cannot forge a terminal state" || bad "mid-sentence marker forged a state (got '$r')"

# The SAME rule must hold on every path that reads a marker, not just the supervisor: the foreground
# watchdog and the loop's blocked-detection read the identical strings from their own capture files.
unanchored=$(grep -c "aoE 'OSRC::(DONE|BLOCKED|NEED_INPUT)'\|aqE 'OSRC::(BLOCKED|NEED_INPUT)'" "$SRC")
[ "$unanchored" -eq 0 ] && ok "no marker read is left matching anywhere in a log" \
  || bad "$unanchored marker read(s) still match anywhere (forgeable by an echo)"


# --- The delegate's stdout is no longer a forgeable control plane. --------------------------------
# Control decisions were made by grepping the delegate's output for bare OSRC:: markers, so the
# delegate could trip them BY ACCIDENT: quoting the protocol it was handed, echoing a log, reviewing
# this repo, diffing this file. That happened three separate times and each fix anchored the pattern a
# little harder, which treats the symptom. A per-run id fixes the cause: instructions carry it, so a
# genuine status line is signed and anything merely repeated is not.
export OSRC_MARK=testmark01
printf '%s\n' "OSRC::DONE#testmark01 finished the work" \
               "reminder: end with OSRC::DONE <summary> or OSRC::BLOCKED <reason>" > "$TMP/m1"
[ "$(_last_marker "$TMP/m1")" = "OSRC::DONE" ] \
  && ok "a signed DONE survives the delegate echoing the protocol afterwards" \
  || bad "echoed protocol beat a signed marker"

printf '%s\n' "OSRC::BLOCKED#testmark01 genuinely stuck" "OSRC::DONE quoted from somewhere else" > "$TMP/m2"
[ "$(_last_marker "$TMP/m2")" = "OSRC::BLOCKED" ] \
  && ok "a signed marker outranks an unsigned one regardless of order" \
  || bad "an unsigned marker overrode the signed status"

printf '%s\n' "OSRC::DONE finished, from an older prompt with no id" > "$TMP/m3"
[ "$(_last_marker "$TMP/m3")" = "OSRC::DONE" ] \
  && ok "unsigned markers still work when nothing is signed (older prompts keep running)" \
  || bad "backward compatibility broken for unsigned markers"

printf '%s\n' "a log line mentioning OSRC::DONE#testmark01 mid-sentence" > "$TMP/m4"
[ -z "$(_last_marker "$TMP/m4")" ] \
  && ok "even a signed marker must lead its line to count" \
  || bad "a mid-sentence signed marker was accepted"

# The id has to actually reach the delegate, and must differ per run or it is just a constant to copy.
osrc_protocol_block | grep -q 'testmark01' \
  && ok "the protocol handed to the delegate carries this run's id" \
  || bad "protocol block does not include the run id"
m1="$(_new_mark)"; m2="$(_new_mark)"
{ [ -n "$m1" ] && [ "$m1" != "$m2" ]; } \
  && ok "each run mints a different id (not a fixed string a delegate could learn)" \
  || bad "run id is not unique per run (m1=$m1 m2=$m2)"
unset OSRC_MARK

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
