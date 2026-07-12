#!/usr/bin/env bash
# test_hardening.sh — U3 conformance: shell-injection prevention, no full ~/.env sourcing,
# secret-bearing temp file cleanup, and private job dirs. Run: bash test_hardening.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
RUN_OR_MODEL="$SCRIPT_DIR/../run-or-model.sh"
RUN_OR_CODEX="$SCRIPT_DIR/../run-or-codex.sh"
for f in "$SRC" "$RUN_OR_MODEL" "$RUN_OR_CODEX"; do
  if [ ! -f "$f" ]; then echo FAIL: cannot find "$f"; exit 1; fi
  bash -n "$f" || { echo FAIL: bash -n failed for "$f"; exit 1; }
done

TMP="$(mktemp -d)"
export OSRC_HOME="$TMP"
export HOME="$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { echo PASS: $1; pass=$((pass+1)); }
bad() { echo FAIL: $1; fail=$((fail+1)); }

# Source the main script for function access.
. "$SRC" >/dev/null 2>&1

# --- Scenario 1: model token injection rejected before tmux command. ---
# tmux is not available; we define it as a function so 'have tmux' passes, but the model
# validator should die before any tmux invocation.
tmux() { echo "TMUX CALLED"; }
PWNED="$TMP/PWNED"
rm -f "$PWNED"
out=$(session start -m "x;touch $PWNED" 2>&1) || rc=$?
[ -f "$PWNED" ] && bad "injection payload created PWNED file" || ok "injection payload did not create PWNED file"
printf '%s' "$out" | grep -q 'invalid model token' && ok "session start rejects malicious model token" || bad "no invalid-token rejection: $out"

# --- Scenario 2: run-or-model.sh exports only OPENROUTER_API_KEY, not other ~/.env keys. ---
mkdir -p "$TMP/.local/bin"
cat > "$TMP/.local/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}"
echo "OTHER_KEY=${OTHER_KEY:-}"
EOF
chmod +x "$TMP/.local/bin/claude"
cat > "$TMP/.env" <<'EOF'
OPENROUTER_API_KEY=sk-or-test-key
OTHER_KEY=should-not-appear
EOF
out=$(bash "$RUN_OR_MODEL" "tencent/hy3:free" 2>&1) || rc=$?
if printf '%s' "$out" | grep -q 'OPENROUTER_API_KEY=sk-or-test-key'; then ok "run-or-model.sh exports OPENROUTER_API_KEY"; else bad "run-or-model.sh missing OPENROUTER_API_KEY: $out"; fi
if printf '%s' "$out" | grep -q 'OTHER_KEY=should-not-appear'; then bad "run-or-model.sh leaked OTHER_KEY"; else ok "run-or-model.sh does NOT export OTHER_KEY"; fi
if grep -qE 'set -a|source .*~/.env|\..*~/.env' "$RUN_OR_MODEL"; then bad "run-or-model.sh still sources full ~/.env"; else ok "run-or-model.sh uses single-key extraction"; fi

# --- Scenario 3: run-or-codex.sh exports only OPENROUTER_API_KEY, not other ~/.env keys. ---
cat > "$TMP/.local/bin/codex" <<'EOF'
#!/usr/bin/env bash
echo "OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}"
echo "OTHER_KEY=${OTHER_KEY:-}"
EOF
chmod +x "$TMP/.local/bin/codex"
out=$(bash "$RUN_OR_CODEX" "tencent/hy3:free" tui 2>&1) || rc=$?
if printf '%s' "$out" | grep -q 'OPENROUTER_API_KEY=sk-or-test-key'; then ok "run-or-codex.sh exports OPENROUTER_API_KEY"; else bad "run-or-codex.sh missing OPENROUTER_API_KEY: $out"; fi
if printf '%s' "$out" | grep -q 'OTHER_KEY=should-not-appear'; then bad "run-or-codex.sh leaked OTHER_KEY"; else ok "run-or-codex.sh does NOT export OTHER_KEY"; fi
if grep -qE 'set -a|source .*~/.env|\..*~/.env' "$RUN_OR_CODEX"; then bad "run-or-codex.sh still sources full ~/.env"; else ok "run-or-codex.sh uses single-key extraction"; fi

# --- Scenario 4: --with mcp temp file hardening (source assertions). ---
# build_mcp_flags_cc needs a real MCP config that isn't present in this test env, so it returns
# empty. Assert the hardening is present in source instead of a full runtime exercise.
if grep -qE 'umask 077|chmod 600' "$SRC" && grep -q 'build_mcp_flags_cc' "$SRC"; then ok "mcp temp file uses umask 077 or chmod 600"; else bad "mcp temp file missing umask 077 / chmod 600"; fi
if grep -q 'with-mcp-.*\$\$' "$SRC" && grep -qE "trap .*rm -f .*with-mcp|trap .*rm -f .*\$\$" "$SRC"; then ok "mcp temp file has an EXIT trap rm"; else bad "mcp temp file missing EXIT trap rm"; fi

# --- Scenario 5: new job dir is 700 and out.log is 600. ---
jd="$TMP/jobs/testjob"
_supervise "$jd" 10 20 30 -- true >/dev/null 2>&1 || true
dir_perms=$(stat -f '%Lp' "$jd" 2>/dev/null || stat -c '%a' "$jd" 2>/dev/null)
log_perms=$(stat -f '%Lp' "$jd/out.log" 2>/dev/null || stat -c '%a' "$jd/out.log" 2>/dev/null)
if [ "$dir_perms" = "700" ]; then ok "job dir permissions are 700" ; else bad "job dir permissions are '$dir_perms'"; fi
if [ "$log_perms" = "600" ]; then ok "out.log permissions are 600" ; else bad "out.log permissions are '$log_perms'"; fi

# --- Scenario 6: gc --older-than removes old completed job dirs, skips running dirs. ---
mkdir -p "$TMP/jobs"
old_done="$TMP/jobs/old-done"
old_running="$TMP/jobs/old-running"
recent_done="$TMP/jobs/recent-done"
mkdir -p "$old_done" "$old_running" "$recent_done"
echo done > "$old_done/status"
echo running > "$old_running/status"
echo done > "$recent_done/status"
touch -t 202001010000 "$old_done"
touch -t 202001010000 "$old_running"
out=$(cmd_gc --older-than 1 2>&1)
if [ ! -d "$old_done" ]; then ok "gc removed old completed dir" ; else bad "gc did not remove old completed dir"; fi
if [ -d "$old_running" ]; then ok "gc preserved running dir" ; else bad "gc removed running dir"; fi
if [ -d "$recent_done" ]; then ok "gc preserved recent done dir" ; else bad "gc removed recent done dir"; fi
printf '%s' "$out" | grep -q 'removed 1' && ok "gc reports 1 removed" || bad "gc did not report removal: $out"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
