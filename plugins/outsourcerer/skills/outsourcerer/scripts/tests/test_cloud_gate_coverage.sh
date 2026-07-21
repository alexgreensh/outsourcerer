#!/usr/bin/env bash
set -euo pipefail

SK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../outsourcerer.sh"

# ISOLATE persistent state (v0.4.8 remembered consent): never read/pollute the user's
# real ~/.outsourcerer — a stored grant there would make every refusal assertion fail.
export OSRC_HOME="${TMPDIR:-/tmp}/osrc-covtest-home-$$"
mkdir -p "$OSRC_HOME"
trap 'rm -rf "$OSRC_HOME"' EXIT

PASS=0
FAIL=0

check() {
  local name="$1"
  local ok="$2"
  if [ "$ok" = "0" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# A. FUNCTIONAL — the cloud gate must fire (real CLI dies at the gate, so no
#    cloud call is made) when OSRC_CLOUD_ACK is unset and stdin is /dev/null.
# ---------------------------------------------------------------------------

# A1: `second-opinion` subcommand runs the cloud gate.
out=$(OSRC_CLOUD_ACK= bash "$SK" second-opinion "hello" </dev/null 2>&1 || true)
if printf '%s' "$out" | grep -q "CLOUD GATE"; then
  check "A1 second-opinion runs cloud gate" 0
else
  check "A1 second-opinion runs cloud gate" 1
fi

# A2: `image` subcommand runs the cloud gate.
out=$(OSRC_CLOUD_ACK= bash "$SK" image "a red panda" /tmp/gatetest.png </dev/null 2>&1 || true)
if printf '%s' "$out" | grep -q "CLOUD GATE"; then
  check "A2 image runs cloud gate" 0
elif printf '%s' "$out" | grep -qiE 'no image backend|GEMINI_API_KEY|OPENROUTER_API_KEY|not on PATH|install'; then
  # No image backend is configured on this machine, so the run dies before the gate would matter.
  # The property under test is "the gate runs BEFORE anything leaves the machine"; with no backend
  # there is no egress to gate, so this is untestable here rather than broken. Failing instead would
  # make the suite red on any machine without image credentials and train people to ignore it.
  echo "SKIP: A2 image gate — no image backend configured (nothing can leave the machine to gate)"
else
  check "A2 image runs cloud gate" 1
fi

# ---------------------------------------------------------------------------
# B. STATIC — S4: run_job no longer uses the account-usage delta
#    (_or_cost_delta) that double-counts under fanout.
# ---------------------------------------------------------------------------

# B3: `_or_cost_delta` must appear ONLY as a function definition
#     (`_or_cost_delta()`), never as a call inside run_job. Count call sites
#     (lines matching "_or_cost_delta " but NOT "_or_cost_delta()" and NOT a comment line).
calls=$( { grep -nE '_or_cost_delta ' "$SK" || true; } | grep -vE '_or_cost_delta\(\)' | grep -vE '^[0-9]+:[[:space:]]*#' | wc -l | tr -d ' ' || true)
if [ "$calls" -eq 0 ]; then
  check "B3 no _or_cost_delta call sites" 0
else
  check "B3 no _or_cost_delta call sites" 1
fi

# B4: the unused snapshot variable `or_before` must be gone.
obc=$(grep -c 'or_before' "$SK" || true)
if [ "$obc" -eq 0 ]; then
  check "B4 or_before removed" 0
else
  check "B4 or_before removed" 1
fi

# ---------------------------------------------------------------------------
echo "----"
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
