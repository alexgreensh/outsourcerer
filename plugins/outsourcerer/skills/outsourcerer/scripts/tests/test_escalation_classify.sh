#!/usr/bin/env bash
# test_escalation_classify.sh — escalation only on transport/infra failures, never task failures.
# Run: bash test_escalation_classify.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
if [ ! -f "$SRC" ]; then echo FAIL: cannot find "$SRC"; exit 1; fi
bash -n "$SRC" || { echo FAIL: bash -n failed for "$SRC"; exit 1; }

TMP="$(mktemp -d)"
export OSRC_HOME="$TMP"
export HOME="$TMP"
export OR_OFFLOAD_CHAIN="m1 m2"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Source the main script. main runs with no args and prints help (suppressed); functions stay defined.
. "$SRC" >/dev/null 2>&1

pass=0; fail=0
ok()  { echo PASS: $1; pass=$((pass+1)); }
bad() { echo FAIL: $1; fail=$((fail+1)); }

# --- Fake claude / codex CLIs that use per-call env vars to simulate failures. ---
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/claude" <<'EOF'
#!/usr/bin/env bash
f="$HOME/.claude_call_count"
n=$(cat "$f" 2>/dev/null || echo 0)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n+1))
echo "$n" > "$f"
eval "err=\${CLAU_ERR_${n}:-}"
eval "rc=\${CLAU_RC_${n}:-0}"
[ -n "$err" ] && printf '%s' "$err" >&2
exit "$rc"
EOF
chmod +x "$HOME/.local/bin/claude"
cat > "$HOME/.local/bin/codex" <<'EOF'
#!/usr/bin/env bash
f="$HOME/.codex_call_count"
n=$(cat "$f" 2>/dev/null || echo 0)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n+1))
echo "$n" > "$f"
eval "err=\${CODEX_ERR_${n}:-}"
eval "rc=\${CODEX_RC_${n}:-0}"
[ -n "$err" ] && printf '%s' "$err"
exit "$rc"
EOF
chmod +x "$HOME/.local/bin/codex"

# OpenRouter key so the lanes don't die before calling the fake CLIs.
cat > "$HOME/.env" <<'EOF'
OPENROUTER_API_KEY=sk-test
EOF

# --- Scenario 1: _is_transport_failure unit classifications. ---
transport_cases=(
  'HTTP 429: rate limit hit'
  'HTTP 502 Bad Gateway'
  'connection refused'
  '401 Unauthorized'
  '403 Forbidden'
  'model_not_found'
  'context length exceeded'
  'connection timed out'
  'error sending request for url (https://openrouter.ai/api/v1/responses)'
  'stream disconnected before completion'
  'deadline has elapsed'
  'Provider returned error (code 429)'
)
tc_rcs=(1 1 1 1 1 1 1 1 1 1 1 1)
for i in "${!transport_cases[@]}"; do
  if _is_transport_failure "${transport_cases[$i]}" "${tc_rcs[$i]}"; then ok "transport case: '${transport_cases[$i]}'"; else bad "transport case missed: '${transport_cases[$i]}'"; fi
done

# Bare ambiguous tokens must NOT be read as transport (they appear in ordinary task output).
bare_ambiguous=(
  'npm test failed'
  'Tests failed'
  'max-turns reached'
  'some normal task error'
  'timeout'                 # bare word: could be "test timeout", not an infra timeout
  '429'                     # bare number with no HTTP/status context
  'increased retry to 503ms'
  'the auth module needs refactoring'
  'the API error needs a regression test'   # "api error" in prose must NOT be transport
  'respect the rate limit in this parser'   # bare "rate limit" in prose must NOT be transport
)
for i in "${!bare_ambiguous[@]}"; do
  if _is_transport_failure "${bare_ambiguous[$i]}" 1; then bad "non-transport case escalated: '${bare_ambiguous[$i]}'"; else ok "non-transport case: '${bare_ambiguous[$i]}'"; fi
done

# --- Scenario 1b: real transport signatures the tightened classifier must still catch. ---
real_transport=(
  'curl: (6) Could not resolve host: openrouter.ai'
  'curl: (28) Operation timed out after 30001 milliseconds'
  'Error: socket hang up'
  'requests.exceptions.HTTPError: 503 Server Error: Service Unavailable for url'
  'API error: 429 Too Many Requests'
  'Could not resolve host: api.example.com'
  'Error: connection reset by peer'
  'could not connect to server: Connection refused'
  'curl: (7) Failed to connect to localhost port 8080: Connection refused'
  'Error: connect ECONNREFUSED 127.0.0.1:443'
)
for c in "${real_transport[@]}"; do
  if _is_transport_failure "$c" 1; then ok "transport caught: '$c'"; else bad "transport missed: '$c'"; fi
done

# --- Scenario 1c: task/test prose that must stay non-transport (no auto-retry of mutating work). ---
# Real CLI diagnostics lead their line; prose embeds them mid-sentence. The line-anchored classifier
# keeps all of these classified as TASK failures.
task_prose=(
  'API error: add a regression test for this task failure'   # bare 'api error:' prefix, no status code
  'unit test expected application error code: 500'           # bare 'code: 500' in prose
  'AssertionError: rate-limiting behavior failed'            # bare 'rate-limiting' in prose
  'rate limiting regression test failed'
  'code 503 must remain an application-level response'
  'operation timed out regression test failed'               # not 'operation timed out after' / no curl
  'socket hang up test failed'                               # not line-anchored 'socket hang up$'
  'could not resolve host test case must remain unchanged'   # no colon after 'host'
  'HTTPError: 503 must remain an application error'          # no space in 'httperror', 503 not + status word
  'unit test fixture is curl: (6) Could not resolve host: example.invalid'  # curl/host not at line start
  'expected 503 Server Error to be rendered in the application response'    # no 'for url', bare 'server error' dropped
  'assertion failed: expected HTTP error 500 for invalid user input'        # 'http error' not at line start
  'assertion expected: socket hang up'                                      # not '^(error: )?socket hang up$'
  'AssertionError: connection refused should be rendered to the user'       # connection phrase mid-traceback
  'test expected connection reset handling to work'                         # 'connection reset' in prose
  'the ssl error path must be covered by a test'                            # 'ssl error' in prose
  'this error sending request wrapper needs a docstring'                    # 'error sending request' in prose
)
for c in "${task_prose[@]}"; do
  if _is_transport_failure "$c" 1; then bad "prose FALSE-POSITIVE (would retry a mutating task): '$c'"; else ok "prose stays non-transport: '$c'"; fi
done

# Empty stderr on a non-zero exit is a TASK failure by default (never blind-retry a mutating task).
if _is_transport_failure "" 1; then bad "empty stderr classified transport by default"; else ok "empty stderr NOT transport by default"; fi
if OSRC_EMPTY_STDERR_IS_TRANSPORT=1 _is_transport_failure "" 1; then ok "empty stderr IS transport with explicit opt-in"; else bad "opt-in empty-stderr did not classify transport"; fi

# --- Scenario 2: 429 stderr in delegate_cc escalates. ---
rm -f "$HOME/.claude_call_count"; export CLAU_ERR_1='HTTP 429 rate limit' CLAU_RC_1=1
export CLAU_ERR_2='' CLAU_RC_2=0
out="$TMP/cc_429.out"; delegate_cc auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.claude_call_count" 2>/dev/null || echo 0)
if [ "$rc" -eq 0 ]; then ok "cc: 429 escalates to a successful model" ; else bad "cc: 429 did not escalate (rc=$rc)"; fi
if [ "$calls" -eq 2 ]; then ok "cc: 429 used 2 models in chain" ; else bad "cc: 429 calls=$calls"; fi

# --- Scenario 3: normal 'npm test' exit 1 in delegate_cc does NOT escalate. ---
rm -f "$HOME/.claude_call_count"; export CLAU_ERR_1='npm test failed' CLAU_RC_1=1
out="$TMP/cc_npm.out"; delegate_cc auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.claude_call_count" 2>/dev/null || echo 0)
if [ "$rc" -ne 0 ]; then ok "cc: npm test failure is surfaced (rc=$rc)" ; else bad "cc: npm test failure was swallowed (rc=$rc)"; fi
if [ "$calls" -eq 1 ]; then ok "cc: npm test failure did not escalate" ; else bad "cc: npm test calls=$calls"; fi
if grep -q 'npm test failed' "$out"; then ok "cc: npm test stderr surfaced" ; else bad "cc: npm test stderr missing"; fi

# --- Scenario 4: 401 auth in delegate_cc escalates once. ---
rm -f "$HOME/.claude_call_count"; export CLAU_ERR_1='Authentication required: 401' CLAU_RC_1=1
export CLAU_ERR_2='' CLAU_RC_2=0
out="$TMP/cc_401.out"; delegate_cc auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.claude_call_count" 2>/dev/null || echo 0)
if [ "$rc" -eq 0 ]; then ok "cc: 401 escalates to success" ; else bad "cc: 401 did not escalate (rc=$rc)"; fi
if [ "$calls" -eq 2 ]; then ok "cc: 401 used 2 models in chain" ; else bad "cc: 401 calls=$calls"; fi

# --- Scenario 5: model_not_found in delegate_cc escalates. ---
rm -f "$HOME/.claude_call_count"; export CLAU_ERR_1='model_not_found: unknown model' CLAU_RC_1=1
export CLAU_ERR_2='' CLAU_RC_2=0
out="$TMP/cc_model.out"; delegate_cc auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.claude_call_count" 2>/dev/null || echo 0)
if [ "$rc" -eq 0 ]; then ok "cc: model_not_found escalates to success" ; else bad "cc: model_not_found did not escalate (rc=$rc)"; fi
if [ "$calls" -eq 2 ]; then ok "cc: model_not_found used 2 models in chain" ; else bad "cc: model_not_found calls=$calls"; fi

# --- Scenario 6: empty stderr in delegate_cc does NOT escalate by default (no blind retry of a
#     possibly-mutating task); it surfaces as a task failure. With the explicit opt-in it escalates. ---
rm -f "$HOME/.claude_call_count"; export CLAU_ERR_1='' CLAU_RC_1=1
export CLAU_ERR_2='' CLAU_RC_2=0
unset OSRC_EMPTY_STDERR_IS_TRANSPORT
out="$TMP/cc_empty.out"; delegate_cc auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.claude_call_count" 2>/dev/null || echo 0)
if [ "$rc" -ne 0 ]; then ok "cc: empty stderr surfaced, not blind-retried (rc=$rc)" ; else bad "cc: empty stderr blind-retried to success (rc=$rc)"; fi
if [ "$calls" -eq 1 ]; then ok "cc: empty stderr did NOT escalate by default" ; else bad "cc: empty stderr calls=$calls (expected 1)"; fi
# opt-in restores the old escalate-on-empty behavior
rm -f "$HOME/.claude_call_count"; export CLAU_ERR_1='' CLAU_RC_1=1
export CLAU_ERR_2='' CLAU_RC_2=0
export OSRC_EMPTY_STDERR_IS_TRANSPORT=1
delegate_cc auto "do a thing" > "$TMP/cc_empty_optin.out" 2>&1
rc=$?; calls=$(cat "$HOME/.claude_call_count" 2>/dev/null || echo 0)
unset OSRC_EMPTY_STDERR_IS_TRANSPORT
if [ "$rc" -eq 0 ] && [ "$calls" -eq 2 ]; then ok "cc: empty stderr escalates with OSRC_EMPTY_STDERR_IS_TRANSPORT=1" ; else bad "cc: empty-stderr opt-in did not escalate (rc=$rc calls=$calls)"; fi

# --- Scenario 7: 429 in delegate_codex escalates. ---
rm -f "$HOME/.codex_call_count"; export CODEX_ERR_1='HTTP 429 rate limit' CODEX_RC_1=1
export CODEX_ERR_2='' CODEX_RC_2=0
out="$TMP/cx_429.out"; delegate_codex auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.codex_call_count" 2>/dev/null || echo 0)
if [ "$rc" -eq 0 ]; then ok "codex: 429 escalates to success" ; else bad "codex: 429 did not escalate (rc=$rc)"; fi
if [ "$calls" -eq 2 ]; then ok "codex: 429 used 2 models in chain" ; else bad "codex: 429 calls=$calls"; fi

# --- Scenario 8: npm test failure in delegate_codex does NOT escalate; stderr surfaced. ---
rm -f "$HOME/.codex_call_count"; export CODEX_ERR_1='npm test failed' CODEX_RC_1=1
out="$TMP/cx_npm.out"; cxerr="$TMP/cx_npm.err"
delegate_codex auto "do a thing" > "$out" 2>"$cxerr"   # stdout captured (not a tty) -> task output re-emitted to stderr
rc=$?
calls=$(cat "$HOME/.codex_call_count" 2>/dev/null || echo 0)
if [ "$rc" -ne 0 ]; then ok "codex: npm test failure is surfaced (rc=$rc)" ; else bad "codex: npm test failure swallowed (rc=$rc)"; fi
if [ "$calls" -eq 1 ]; then ok "codex: npm test failure did not escalate" ; else bad "codex: npm test calls=$calls"; fi
if grep -q 'npm test failed' "$cxerr"; then ok "codex: task-failure output surfaced to STDERR for result-capturing callers" ; else bad "codex: task-failure stderr NOT surfaced"; fi

# --- Scenario 9: 401/403 in delegate_codex escalates. ---
rm -f "$HOME/.codex_call_count"; export CODEX_ERR_1='HTTP 403 Forbidden' CODEX_RC_1=1
export CODEX_ERR_2='' CODEX_RC_2=0
out="$TMP/cx_403.out"; delegate_codex auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.codex_call_count" 2>/dev/null || echo 0)
if [ "$rc" -eq 0 ]; then ok "codex: 403 escalates to success" ; else bad "codex: 403 did not escalate (rc=$rc)"; fi
if [ "$calls" -eq 2 ]; then ok "codex: 403 used 2 models in chain" ; else bad "codex: 403 calls=$calls"; fi

# --- Scenario 10: model_not_found in delegate_codex escalates. ---
rm -f "$HOME/.codex_call_count"; export CODEX_ERR_1='model_not_found: no such model' CODEX_RC_1=1
export CODEX_ERR_2='' CODEX_RC_2=0
out="$TMP/cx_model.out"; delegate_codex auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.codex_call_count" 2>/dev/null || echo 0)
if [ "$rc" -eq 0 ]; then ok "codex: model_not_found escalates to success" ; else bad "codex: model_not_found did not escalate (rc=$rc)"; fi
if [ "$calls" -eq 2 ]; then ok "codex: model_not_found used 2 models in chain" ; else bad "codex: model_not_found calls=$calls"; fi

# --- Scenario 11: empty stderr in delegate_codex does NOT escalate by default; surfaces instead. ---
rm -f "$HOME/.codex_call_count"; export CODEX_ERR_1='' CODEX_RC_1=1
export CODEX_ERR_2='' CODEX_RC_2=0
unset OSRC_EMPTY_STDERR_IS_TRANSPORT
out="$TMP/cx_empty.out"; delegate_codex auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.codex_call_count" 2>/dev/null || echo 0)
if [ "$rc" -ne 0 ]; then ok "codex: empty stderr surfaced, not blind-retried (rc=$rc)" ; else bad "codex: empty stderr blind-retried (rc=$rc)"; fi
if [ "$calls" -eq 1 ]; then ok "codex: empty stderr did NOT escalate by default" ; else bad "codex: empty stderr calls=$calls (expected 1)"; fi


# --- Prose vs diagnostic: test output that merely TALKS about infra must not be retried blindly. ---
# A delegate testing an API client prints "rate limit exceeded" / "statusCode: 404" / "invalid_api_key"
# as assertion text. Classified as transport, the runner silently retries the whole task on another
# model — re-running a possibly-mutating task whose real failure was a red test.
for probe in \
  "AssertionError: expected rate limit exceeded, got noop" \
  "test_invalid_api_key_rejected FAILED" \
  "AssertionError: got statusCode: 404" \
  "  assert resp.statusCode: 500"; do
  if _is_transport_failure "$probe" 1; then bad "prose misread as transport (would blind-retry): $probe"
  else ok "prose stays a task failure: $probe"; fi
done
# ...while the same words as a real CLI's own diagnostic line must STILL escalate.
for probe in "rate limit exceeded" "invalid api key" "statusCode: 503" "ECONNREFUSED" "curl: (7) failed to connect"; do
  if _is_transport_failure "$probe" 1; then ok "real diagnostic still classified transport: $probe"
  else bad "lost transport coverage for: $probe"; fi
done

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
