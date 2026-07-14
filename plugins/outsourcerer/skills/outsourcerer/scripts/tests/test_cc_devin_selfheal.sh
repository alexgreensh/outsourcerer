#!/usr/bin/env bash
# test_cc_devin_selfheal.sh — cc-lane OpenRouter exhaustion (e.g. 402 insufficient credit) heals
# across to the Devin lane for dual-lane models (glm today), instead of dying on OpenRouter with
# a healthy Devin sibling sitting unused. Companion to the existing codex->cc self-heal
# (test_no_silent_escalation.sh) and the default-provider U6 reroute (test_lane_fallback.sh).
#
# Root cause this guards: `claude -p` reports an OpenRouter transport/affordability error (e.g.
# "API Error: 402 ... requires more credits") as a stream-json STDOUT message, not on stderr. A
# stderr-only capture (delegate_cc's original `2>"$cap"`) leaves _is_transport_failure permanently
# blind to it -- verified live against a real $0-credit OpenRouter key: stderr contained only an
# unrelated "Advisor disabled" warning, never the actual 402. That silently turned every OpenRouter
# credit exhaustion into an unretried, unescalated task failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Extract + eval only the pure functions (avoid running main), same technique as test_lane_fallback.sh.
eval "$(sed -n '/^_devin_model_for() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^_is_transport_failure() {/,/^}/p' "$SRC")"

# --- Scenario 1: the real 402 string (captured from a live run against a $0-credit OpenRouter
# key) IS classified as a transport failure -- this only matters once it can actually reach the
# classifier, which is Scenario 2 below. ---
real_402='API Error: 402 This request requires more credits, or fewer max_tokens. You requested up to 32000 tokens, but can only afford 9090. To increase, visit https://openrouter.ai/settings/credits and upgrade to a paid account'
_is_transport_failure "$real_402" 1 && ok "_is_transport_failure classifies the real OpenRouter 402 string" || bad "real 402 string not classified as transport failure"

# --- Scenario 2: delegate_cc captures COMBINED stdout+stderr (not stderr-only), so the 402 above
# (a stdout/stream-json message, verified live) actually reaches _is_transport_failure. ---
grep -q 'claude -p ${bare\[@\]+"${bare\[@\]}"} ${sfx\[@\]+"${sfx\[@\]}"} ${CC_MCP_FLAGS\[@\]+"${CC_MCP_FLAGS\[@\]}"} ${tools\[@\]+"${tools\[@\]}"} --permission-mode "$emode" "$wrapped" 2>&1 | tee "$cap"' "$SRC" \
  && ok "delegate_cc captures combined stdout+stderr via 2>&1 | tee (not stderr-only)" \
  || bad "delegate_cc still stderr-only captures (2>\"\$cap\"); OpenRouter 402s are stdout-only and invisible to _is_transport_failure"
grep -q 'rc=${PIPESTATUS\[0\]}' "$SRC" && ok "delegate_cc reads rc via PIPESTATUS[0] after the pipe (not \$? of tee)" || bad "delegate_cc rc capture wrong after piping to tee"

# --- Scenario 3: cross-lane self-heal is wired -- OpenRouter chain exhaustion for a dual-lane
# model retries on Devin, gated by a transport-failure flag and an opt-out. ---
grep -q 'last_transport=1' "$SRC" && ok "delegate_cc tracks a last_transport flag across the retry loop" || bad "last_transport flag missing"
[ "$(grep -c '_devin_model_for "\$MODEL"' "$SRC")" -ge 2 ] && ok "_devin_model_for is consulted in >=2 places (U6 default-provider reroute + cc self-heal)" || bad "cc self-heal does not consult _devin_model_for"
grep -q 'OSRC_NO_CROSS_LANE' "$SRC" && ok "cross-lane self-heal has an opt-out (OSRC_NO_CROSS_LANE)" || bad "no opt-out for cross-lane self-heal"
grep -q 'PROVIDER=devin delegate "\$tier" "" \${ORIGARGS\[@\]+"\${ORIGARGS\[@\]}"}' "$SRC" && ok "self-heal re-dispatches to the Devin lane via ORIGARGS (preserves --effort/--with/etc.)" || bad "self-heal dispatch to devin missing or does not preserve original flags"

# --- Scenario 4: ORIGARGS is captured before _consume_flags mutates state, and the model token
# gets rewritten to the Devin id before re-dispatch (mirrors route_delegate's U6 rewrite). ---
grep -q 'local ORIGARGS=("\$@")   # preserved verbatim for the cross-lane self-heal (-> devin)' "$SRC" && ok "delegate_cc preserves ORIGARGS before _consume_flags" || bad "ORIGARGS not preserved at top of delegate_cc"
grep -q 'case "\${ORIGARGS\[\$_i\]}" in -m|--model) \[ \$((_i+1)) -lt \${#ORIGARGS\[@\]} \] && ORIGARGS\[\$((_i+1))\]="\$_dvm" ;; esac' "$SRC" && ok "self-heal rewrites the -m token in ORIGARGS to the Devin id" || bad "model-token rewrite in ORIGARGS missing"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
