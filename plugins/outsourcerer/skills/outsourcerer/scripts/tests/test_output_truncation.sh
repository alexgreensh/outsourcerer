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

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
