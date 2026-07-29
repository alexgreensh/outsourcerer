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

# -----------------------------------------------------------------------------
# Native-routing regression pack (2026-07-30): pinned Claude ids must NOT fall
# through to the devin default, `[1m]` context suffixes must validate, and the
# family-inference fallback must send unknown native ids to their own lane.
# -----------------------------------------------------------------------------

# 6-8. Pinned Claude 5-gen / 4.8 ids now have exact table rows on the cc lane
#      (the "-m claude-opus-4-8 silently ran on Devin" fix).
check_lane "claude-opus-4-8" "cc"
check_lane "claude-fable-5"   "cc"
check_lane "claude-sonnet-5"  "cc"

# 9-14. lane_from_name(): recognizable NATIVE families infer their own lane so an
#       un-tabled id (e.g. claude-opus-4-8[1m], a future gpt-5.*/gemini-* variant)
#       never routes to devin; open-weight/unknown ids return nonzero (fall through).
check_infer() {
  local id="$1" expected="$2" got
  got="$(lane_from_name "$id" 2>/dev/null || echo NONE)"
  if [ "$got" = "$expected" ]; then
    echo "PASS: lane_from_name $id -> '$got' (expected '$expected')"
  else
    echo "FAIL: lane_from_name $id -> '$got' (expected '$expected')"
    fail=1
  fi
}
check_infer "claude-opus-4-8[1m]" "cc"    # 1M-window Claude id, not in table
check_infer "claude-sonnet-6"     "cc"    # future Claude id
check_infer "gpt-5.7-experimental" "cx"   # future ChatGPT id
check_infer "gemini-4-pro"        "gm"    # future Gemini id
check_infer "glm-5.2"             "NONE"  # open-weight: dual-lane, follows provider default
check_infer "mistral-large-2"     "NONE"  # unknown: falls through to provider router

# 15-18. _validate_model_token: accept the bracketed context-window suffix, reject injection.
check_token() {
  local tok="$1" expect="$2"   # expect = ok|reject
  if ( _validate_model_token "$tok" ) >/dev/null 2>&1; then got=ok; else got=reject; fi
  if [ "$got" = "$expect" ]; then
    echo "PASS: _validate_model_token '$tok' -> $got"
  else
    echo "FAIL: _validate_model_token '$tok' -> $got (expected $expect)"
    fail=1
  fi
}
check_token "claude-opus-4-8[1m]" ok
check_token "claude-opus-4-8[200k]" ok
check_token 'foo[1m];rm -rf /' reject
check_token 'a$(id)' reject
# Torture-found regression (lane1 BUG 1.1): a NEWLINE must not slip past the line-oriented grep by
# making only the first line match ^…$. These are the injection vectors into the session launch string.
check_token "$(printf 'claude\n;id')" reject
check_token "$(printf 'opus\nrm -rf /')" reject
check_token "$(printf 'claude-opus-4-8[1m]\ntouch pwned')" reject

if [ "$fail" -ne 0 ]; then
  echo "RESULT: FAIL ($fail check(s) failed)" >&2
  exit 1
fi

echo "RESULT: PASS (all 21 checks passed)"
