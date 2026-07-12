#!/usr/bin/env bash
# test_escalation_classify.sh — U4 conformance: escalation only on transport/infra failures.
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

# Source the main script. main will run with no args and print help (suppressed); functions stay defined.
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
  'timeout'
  ''
)
tc_rcs=(1 1 1 1 1 1 1 1 1)
for i in "${!transport_cases[@]}"; do
  if _is_transport_failure "${transport_cases[$i]}" "${tc_rcs[$i]}"; then ok "transport case: '${transport_cases[$i]}'"; else bad "transport case missed: '${transport_cases[$i]}'"; fi
done

non_transport_cases=(
  'npm test failed'
  'Tests failed'
  'max-turns reached'
  'some normal task error'
)
ntc_rcs=(1 1 1 1)
for i in "${!non_transport_cases[@]}"; do
  if _is_transport_failure "${non_transport_cases[$i]}" "${ntc_rcs[$i]}"; then bad "non-transport case escalated: '${non_transport_cases[$i]}'"; else ok "non-transport case: '${non_transport_cases[$i]}'"; fi
done

# --- Scenario 2: 429 stderr in delegate_cc escalates. ---
rm -f "$HOME/.claude_call_count"
export CLAU_ERR_1='HTTP 429 rate limit' CLAU_RC_1=1
export CLAU_ERR_2=''                  CLAU_RC_2=0
out="$TMP/cc_429.out"
delegate_cc auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.claude_call_count" 2>/dev/null || echo 0)
if [ "$rc" -eq 0 ]; then ok "cc: 429 escalates to a successful model" ; else bad "cc: 429 did not escalate (rc=$rc)"; fi
if [ "$calls" -eq 2 ]; then ok "cc: 429 used 2 models in chain" ; else bad "cc: 429 calls=$calls"; fi

# --- Scenario 3: normal 'npm test' exit 1 in delegate_cc does NOT escalate. ---
rm -f "$HOME/.claude_call_count"
export CLAU_ERR_1='npm test failed' CLAU_RC_1=1
out="$TMP/cc_npm.out"
delegate_cc auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.claude_call_count" 2>/dev/null || echo 0)
if [ "$rc" -ne 0 ]; then ok "cc: npm test failure is surfaced (rc=$rc)" ; else bad "cc: npm test failure was swallowed (rc=$rc)"; fi
if [ "$calls" -eq 1 ]; then ok "cc: npm test failure did not escalate" ; else bad "cc: npm test calls=$calls"; fi
if grep -q 'npm test failed' "$out"; then ok "cc: npm test stderr surfaced" ; else bad "cc: npm test stderr missing"; fi

# --- Scenario 4: 401 auth in delegate_cc escalates once. ---
rm -f "$HOME/.claude_call_count"
export CLAU_ERR_1='Authentication required: 401' CLAU_RC_1=1
export CLAU_ERR_2=''                            CLAU_RC_2=0
out="$TMP/cc_401.out"
delegate_cc auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.claude_call_count" 2>/dev/null || echo 0)
if [ "$rc" -eq 0 ]; then ok "cc: 401 escalates to success" ; else bad "cc: 401 did not escalate (rc=$rc)"; fi
if [ "$calls" -eq 2 ]; then ok "cc: 401 used 2 models in chain" ; else bad "cc: 401 calls=$calls"; fi

# --- Scenario 5: model_not_found in delegate_cc escalates. ---
rm -f "$HOME/.claude_call_count"
export CLAU_ERR_1='model_not_found: unknown model' CLAU_RC_1=1
export CLAU_ERR_2=''                             CLAU_RC_2=0
out="$TMP/cc_model.out"
delegate_cc auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.claude_call_count" 2>/dev/null || echo 0)
if [ "$rc" -eq 0 ]; then ok "cc: model_not_found escalates to success" ; else bad "cc: model_not_found did not escalate (rc=$rc)"; fi
if [ "$calls" -eq 2 ]; then ok "cc: model_not_found used 2 models in chain" ; else bad "cc: model_not_found calls=$calls"; fi

# --- Scenario 6: empty/timeout in delegate_cc escalates. ---
rm -f "$HOME/.claude_call_count"
export CLAU_ERR_1='' CLAU_RC_1=1
export CLAU_ERR_2='' CLAU_RC_2=0
out="$TMP/cc_empty.out"
delegate_cc auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.claude_call_count" 2>/dev/null || echo 0)
if [ "$rc" -eq 0 ]; then ok "cc: empty/timeout escalates to success" ; else bad "cc: empty/timeout did not escalate (rc=$rc)"; fi
if [ "$calls" -eq 2 ]; then ok "cc: empty/timeout used 2 models in chain" ; else bad "cc: empty/timeout calls=$calls"; fi

# --- Scenario 7: 429 in delegate_codex escalates. ---
rm -f "$HOME/.codex_call_count"
export CODEX_ERR_1='HTTP 429 rate limit' CODEX_RC_1=1
export CODEX_ERR_2=''                  CODEX_RC_2=0
out="$TMP/cx_429.out"
delegate_codex auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.codex_call_count" 2>/dev/null || echo 0)
if [ "$rc" -eq 0 ]; then ok "codex: 429 escalates to success" ; else bad "codex: 429 did not escalate (rc=$rc)"; fi
if [ "$calls" -eq 2 ]; then ok "codex: 429 used 2 models in chain" ; else bad "codex: 429 calls=$calls"; fi

# --- Scenario 8: npm test failure in delegate_codex does NOT escalate. ---
rm -f "$HOME/.codex_call_count"
export CODEX_ERR_1='npm test failed' CODEX_RC_1=1
out="$TMP/cx_npm.out"
delegate_codex auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.codex_call_count" 2>/dev/null || echo 0)
if [ "$rc" -ne 0 ]; then ok "codex: npm test failure is surfaced (rc=$rc)" ; else bad "codex: npm test failure swallowed (rc=$rc)"; fi
if [ "$calls" -eq 1 ]; then ok "codex: npm test failure did not escalate" ; else bad "codex: npm test calls=$calls"; fi

# --- Scenario 9: 401/403 in delegate_codex escalates. ---
rm -f "$HOME/.codex_call_count"
export CODEX_ERR_1='HTTP 403 Forbidden' CODEX_RC_1=1
export CODEX_ERR_2=''                 CODEX_RC_2=0
out="$TMP/cx_403.out"
delegate_codex auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.codex_call_count" 2>/dev/null || echo 0)
if [ "$rc" -eq 0 ]; then ok "codex: 403 escalates to success" ; else bad "codex: 403 did not escalate (rc=$rc)"; fi
if [ "$calls" -eq 2 ]; then ok "codex: 403 used 2 models in chain" ; else bad "codex: 403 calls=$calls"; fi

# --- Scenario 10: model_not_found in delegate_codex escalates. ---
rm -f "$HOME/.codex_call_count"
export CODEX_ERR_1='model_not_found: no such model' CODEX_RC_1=1
export CODEX_ERR_2=''                          CODEX_RC_2=0
out="$TMP/cx_model.out"
delegate_codex auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.codex_call_count" 2>/dev/null || echo 0)
if [ "$rc" -eq 0 ]; then ok "codex: model_not_found escalates to success" ; else bad "codex: model_not_found did not escalate (rc=$rc)"; fi
if [ "$calls" -eq 2 ]; then ok "codex: model_not_found used 2 models in chain" ; else bad "codex: model_not_found calls=$calls"; fi

# --- Scenario 11: empty/timeout in delegate_codex escalates. ---
rm -f "$HOME/.codex_call_count"
export CODEX_ERR_1='' CODEX_RC_1=1
export CODEX_ERR_2='' CODEX_RC_2=0
out="$TMP/cx_empty.out"
delegate_codex auto "do a thing" > "$out" 2>&1
rc=$?
calls=$(cat "$HOME/.codex_call_count" 2>/dev/null || echo 0)
if [ "$rc" -eq 0 ]; then ok "codex: empty/timeout escalates to success" ; else bad "codex: empty/timeout did not escalate (rc=$rc)"; fi
if [ "$calls" -eq 2 ]; then ok "codex: empty/timeout used 2 models in chain" ; else bad "codex: empty/timeout calls=$calls"; fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
