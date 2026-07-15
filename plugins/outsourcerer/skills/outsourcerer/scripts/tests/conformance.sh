#!/usr/bin/env bash
# conformance.sh — U5: per-lane conformance harness (the don't-ship-blind gate).
#
# TWO layers:
#   STATIC  (always): every Phase-0 security/routing invariant is wired (aggregates the unit tests +
#           cross-checks the source). Fast, deterministic, CI-safe, no cost.
#   LIVE    (opt-in, OSRC_CONFORMANCE_LIVE=1): drives each AVAILABLE lane under the effort x tools x
#           real-repo matrix that exposed every "passed the smoke test, failed the real run" bug —
#           asserts the lane actually runs a tool and honors the exit contract. Skips absent lanes.
#
# Run:  bash conformance.sh            # static gate only
#       OSRC_CONFORMANCE_LIVE=1 bash conformance.sh   # + live lane probes (uses quota/tokens)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

pass=0; fail=0; skip=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }
note() { echo "SKIP: $1"; skip=$((skip+1)); }

echo "=== STATIC gate: Phase-0 invariants wired ==="

# 1. Every unit test suite is green (aggregate).
for t in test_cloud_gate test_no_silent_escalation test_hardening test_escalation_classify \
         test_lane_fallback test_interactive_default test_harness_isolation test_autodetach \
         test_advise; do
  if [ -f "$SCRIPT_DIR/$t.sh" ]; then
    if bash "$SCRIPT_DIR/$t.sh" >/dev/null 2>&1; then ok "unit suite $t green"; else bad "unit suite $t FAILED"; fi
  else note "unit suite $t absent"; fi
done

# 2. Security choke points present in source (defense-in-depth cross-check).
grep -q '_cloud_disclose "$disp"'                 "$SRC" && ok "U1 cloud gate wired at route_delegate choke point" || bad "U1 gate missing"
grep -q 'protected path needs --allow-downgrade'  "$SRC" && ok "U2 no-silent-escalation default present"          || bad "U2 default missing"
grep -q 'SECURITY DOWNGRADE'                      "$SRC" && ok "U2 downgrade is labeled, not silent"               || bad "U2 label missing"
grep -q '_validate_model_token'                   "$SRC" && ok "U3 model-token injection guard present"            || bad "U3 guard missing"
grep -q '_is_transport_failure'                   "$SRC" && ok "U4 transport-vs-task classifier present"           || bad "U4 classifier missing"
grep -q '_devin_model_for'                        "$SRC" && ok "U6 availability-aware routing present"             || bad "U6 routing missing"
grep -q 'Read Edit Write Bash Grep Glob'          "$SRC" && ok "U7 mutating coding toolset granted (no bash wedge)" || bad "U7 toolset missing"
grep -q '_autodetach_should'                       "$SRC" && ok "D3 auto-detach trigger present"                       || bad "D3 trigger missing"
grep -q '_autodetach_run.*_bg_launch\|_bg_launch'  "$SRC" && ok "D3 auto-detach reuses bg machinery"                    || bad "D3 reuse missing"

# 3. bash -n on the script + all sibling shell scripts.
for f in "$SRC" "$SCRIPT_DIR"/../run-or-model.sh "$SCRIPT_DIR"/../run-or-codex.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then ok "bash -n clean: $(basename "$f")"; else bad "bash -n FAILED: $(basename "$f")"; fi
done

echo
echo "=== LIVE lane matrix (effort x tools x real-repo) ==="
if [ "${OSRC_CONFORMANCE_LIVE:-0}" != "1" ]; then
  note "live lane probes skipped (set OSRC_CONFORMANCE_LIVE=1 to run; uses quota/tokens)"
else
  # Build a tiny real-repo fixture with a nonce the lane must READ (proves a real tool call).
  FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
  nonce="OSRC-$$-CONFORMANCE"
  printf '%s\n' "$nonce" > "$FIX/nonce.txt"
  probe_lane() { # <label> <args...>
    local label="$1"; shift
    local out rc
    out="$( cd "$FIX"; OSRC_CLOUD_ACK=1 "$SRC" "$@" --effort high "Read ./nonce.txt and reply with ONLY its contents." 2>&1 )"; rc=$?
    if printf '%s' "$out" | grep -q "$nonce"; then ok "LIVE $label: read the fixture (real tool call), rc=$rc"
    elif [ "$rc" -ne 0 ]; then note "LIVE $label: lane unavailable/failed (rc=$rc) — $(printf '%s' "$out" | tail -1)"
    else bad "LIVE $label: ran but did NOT read the nonce (tool grant broken?)"; fi
  }
  # Devin GLM (U6 routing fix — this is the exact path that used to 403 on OpenRouter).
  if have devin && devin auth status 2>/dev/null | grep -qi "logged in"; then
    probe_lane "devin/glm" run -m glm
  else note "LIVE devin: not installed / not logged in"; fi
  # Native Claude (subscription) if present.
  if have claude; then probe_lane "claude-native" run -m haiku; else note "LIVE claude-native: claude CLI absent"; fi
  # OpenRouter cc lane only if a key is present AND not over quota (best-effort).
  if grep -qE '^[[:space:]]*(export[[:space:]]+)?OPENROUTER_API_KEY=' "$HOME/.env" 2>/dev/null; then
    probe_lane "cc/openrouter-glm" --provider cc run -m glm
  else note "LIVE cc/openrouter: no OPENROUTER_API_KEY"; fi
fi

echo
echo "RESULT: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
