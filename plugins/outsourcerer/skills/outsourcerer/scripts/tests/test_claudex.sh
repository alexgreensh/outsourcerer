#!/usr/bin/env bash
# test_claudex.sh — claudex lane (Claude Code harness -> local CLIProxyAPI) conformance, OFFLINE.
# Style mirrors test_cloud_gate.sh: source the script, exercise routing/guardrails, no live calls.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

export OSRC_HOME="${TMPDIR:-/tmp}/osrc-claudex-test-$$"
mkdir -p "$OSRC_HOME"
trap 'rm -rf "$OSRC_HOME"' EXIT

. "$SRC" >/dev/null 2>&1

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# 1. claudex is a CLOUD lane (full gate applies).
_is_cloud_lane "claudex" && ok "claudex classified as a cloud lane" || bad "claudex NOT classified cloud"

# 2. lane accounting: provider claudex IS the lane, regardless of alias resolution.
[ "$(_effective_lane cx claudex gpt-5.6-sol 1)" = "claudex" ] && ok "_effective_lane records claudex" || bad "_effective_lane wrong: $(_effective_lane cx claudex gpt-5.6-sol 1)"

# 3. ToS guardrail: a Claude-subscription model via claudex must REFUSE with the policy pointer.
out="$( (cd "$OSRC_HOME"; PROVIDER=claudex; route_delegate auto run -m fable "say hi" </dev/null) 2>&1 )"; rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -q "usage policy"; } && ok "claudex refuses Claude-sub models (policy)" || bad "claudex policy guardrail missing (rc=$rc)"

# 4/5. These two assert what the claudex path says AFTER it gets past the CLI check, so they need the
# claude CLI present. Without it the lane dies earlier with a different (also correct) message. On a
# machine that has no claude CLI these are UNTESTABLE, not failing — a test that goes red because an
# optional dependency is absent teaches nothing and trains people to ignore a red build.
if command -v claude >/dev/null 2>&1; then
  # fail-fast on missing proxy: instant die naming CLIProxyAPI, never a detached job.
  out="$( (cd "$OSRC_HOME"; PROVIDER=claudex OSRC_CLAUDEX_URL="http://127.0.0.1:1" OSRC_CLAUDEX_TOKEN="x"; route_delegate auto run "say hi" </dev/null) 2>&1 )"; rc=$?
  { [ $rc -ne 0 ] && echo "$out" | grep -q "CLIProxyAPI"; } && ok "claudex fails fast with setup pointer when proxy is down" || bad "claudex missing-proxy path wrong (rc=$rc): $(echo "$out" | tail -1)"
  echo "$out" | grep -q "job id" && bad "claudex missing-proxy leaked into a background job" || ok "claudex missing-proxy never detaches a job"
  # default model: no -m under claudex resolves to gpt-5.6-sol (visible in the die message).
  echo "$out" | grep -q "gpt-5.6-sol" && ok "claudex defaults to gpt-5.6-sol" || bad "claudex default model wrong"
else
  echo "SKIP: claudex proxy/default-model assertions need the claude CLI (absent here)"
  # The lane must still refuse cleanly rather than hang or detach when the CLI is missing.
  out="$( (cd "$OSRC_HOME"; PROVIDER=claudex OSRC_CLAUDEX_URL="http://127.0.0.1:1" OSRC_CLAUDEX_TOKEN="x"; route_delegate auto run "say hi" </dev/null) 2>&1 )"; rc=$?
  { [ $rc -ne 0 ] && echo "$out" | grep -qi "claude CLI"; } && ok "without the claude CLI, claudex fails fast and names what is missing" || bad "claudex missing-CLI path unclear (rc=$rc)"
  echo "$out" | grep -q "job id" && bad "claudex leaked into a background job with no CLI" || ok "claudex never detaches a job when the CLI is missing"
fi

# 6. token extraction: first api-key parsed from a CLIProxyAPI-style config.yaml.
cfg="$OSRC_HOME/config.yaml"
printf 'port: 8317\napi-keys:\n  - "sk-test-first"\n  - "sk-test-second"\nother: x\n' > "$cfg"
tok="$(OSRC_CLAUDEX_TOKEN= OSRC_CLAUDEX_CONFIG="$cfg" _claudex_token)"
[ "$tok" = "sk-test-first" ] && ok "_claudex_token parses first api-key from config.yaml" || bad "_claudex_token got '$tok'"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
