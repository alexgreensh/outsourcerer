#!/usr/bin/env bash
# Test for the "resolved lane" accounting feature of outsourcerer.sh.
#
# Validates:
#   1-3. The middle field (lane) of `resolve_model_row <alias>` for three aliases.
#   4-5. The Tab's plan/subscription-lane classification rule: a job is a
#        plan/subscription lane iff its `.lane` matches ^(cx|cc|gm)$.
#
# Self-contained and side-effect-free: no background jobs, no network. The
# real `resolve_model_row` + `OSRC_MODEL_TABLE` are sourced from the main
# script with the trailing `main "$@"` dispatcher stripped so sourcing does
# not execute any orchestration logic.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="$HERE/../outsourcerer.sh"

if [ ! -f "$MAIN_SCRIPT" ]; then
  echo "FAIL: main script not found at $MAIN_SCRIPT" >&2
  exit 1
fi

# Source ONLY the table + functions (drop the `main "$@"` dispatcher line) from
# a temp copy so sourcing is side-effect-free (no bg jobs, no network). A temp
# FILE (not process substitution) is required: this bash does not define
# functions when `source`-ing from a <() pipe.
TMP_MAIN="$(mktemp "${TMPDIR:-/tmp}/outsourcerer_src.XXXXXX")"
trap 'rm -f "$TMP_MAIN"' EXIT
set +e
sed '/^[[:space:]]*main "\$@"[[:space:]]*$/d' "$MAIN_SCRIPT" > "$TMP_MAIN"
# shellcheck disable=SC1090
source "$TMP_MAIN"
set -e

have() { command -v "$1" >/dev/null 2>&1; }
if ! have jq; then
  echo "FAIL: jq is required for checks 4-5" >&2
  exit 1
fi

fail=0

# Extract the middle field (lane) from a "id|lane|tier" row.
lane_of() {
  local row="$1"
  printf '%s' "$row" | awk -F'|' '{print $2}'
}

check_lane() {
  local alias="$1" expected="$2" row lane
  row="$(resolve_model_row "$alias")"
  lane="$(lane_of "$row")"
  if [ "$lane" = "$expected" ]; then
    echo "PASS: resolve_model_row $alias -> lane '$lane' (expected '$expected')"
  else
    echo "FAIL: resolve_model_row $alias -> lane '$lane' (expected '$expected')"
    fail=1
  fi
}

# The Tab's plan/subscription-lane classification expression (verbatim from spec).
JQ_CLASSIFY='if (.lane//"")!="" then (.lane|test("^(cx|cc|gm)$")) else false end'

check_classify() {
  local lane="$1" expected="$2" actual
  actual="$(printf '%s' "{\"lane\":\"$lane\"}" | jq "$JQ_CLASSIFY")"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: lane '$lane' classified as $actual (expected $expected)"
  else
    echo "FAIL: lane '$lane' classified as $actual (expected $expected)"
    fail=1
  fi
}

# 1. middle field of `resolve_model_row gemini-flash` == gm
check_lane "gemini-flash" "gm"
# 2. middle field of `resolve_model_row glm` == or
check_lane "glm" "or"
# 3. middle field of `resolve_model_row sol` == cx
check_lane "sol" "cx"
# 4. {"lane":"gm"} classifies as plan/subscription lane (true)
check_classify "gm" "true"
# 5. {"lane":"or"} does NOT classify as plan/subscription lane (false)
check_classify "or" "false"

if [ "$fail" -ne 0 ]; then
  echo "RESULT: FAIL ($fail check(s) failed)" >&2
  exit 1
fi

echo "RESULT: PASS (all 5 checks passed)"
