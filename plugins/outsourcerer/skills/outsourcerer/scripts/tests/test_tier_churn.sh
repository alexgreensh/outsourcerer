#!/usr/bin/env bash
# test_tier_churn.sh — tier_from_name must survive model churn without a table edit.
# Newer families (GPT-6/Astra, hy4/hy5) route by capability the day they ship, and a
# size suffix (mini/lite/...) OUTRANKS family so a small variant of a new frontier model
# is never mis-promoted. All OFFLINE. Run: bash test_tier_churn.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
export OSRC_SOURCED=1
. "$SRC" >/dev/null 2>&1

pass=0; fail=0
eq() { # eq <model-id> <expected-tier>
  local got; got="$(tier_from_name "$1" 2>/dev/null)"
  if [ "$got" = "$2" ]; then echo "PASS: $1 -> $2"; pass=$((pass+1));
  else echo "FAIL: $1 -> expected '$2' got '${got:-<none>}'"; fail=$((fail+1)); fi
}

# --- Churn: new frontier families tier right with no table entry ---
eq astra                    frontier
eq gpt-6                    frontier
eq gpt-6-terra              frontier   # future codex codename
eq claude-fable-5-1         frontier   # Fable 5.1

# --- Churn: new capable open-weight releases (version-agnostic hy[0-9]) ---
eq tencent/hy4              capable
eq tencent/hy5:free         capable
eq hy3                      capable    # still works

# --- Size suffix OUTRANKS family (the reorder guarantee) ---
eq gpt-6-mini               budget     # would be frontier under the old order
eq astra-nano               budget
eq z-ai/glm-5.2-flash-lite  budget     # capable family + lite -> budget

# --- Regressions: existing mappings unchanged ---
eq opus                     frontier
eq fable                    frontier
eq gpt-5.6-sol              frontier
eq z-ai/glm-5.2             capable
eq deepseek/deepseek-v4-pro capable
eq haiku                    budget
eq gemini-flash-lite        budget

# --- Astra/GPT-6 effort floor: none|minimal -> low, keyed on model family, Claude untouched ---
floor() { # floor <model> <effort-in> <expected-effort-out>
  MODEL="$1"; EFFORT="$2"; _floor_effort_for_model 2>/dev/null
  if [ "$EFFORT" = "$3" ]; then echo "PASS: floor $1/$2 -> $3"; pass=$((pass+1));
  else echo "FAIL: floor $1/$2 -> expected '$3' got '$EFFORT'"; fail=$((fail+1)); fi
}
floor gpt-6            minimal low       # would hard-error on codex otherwise
floor astra            none    low
floor gpt-6-terra      minimal low
floor gpt-6            high    high      # non-floor efforts pass through
floor astra            medium  medium
floor claude-fable-5-1 minimal minimal  # Claude family NOT touched (MAX_THINKING_TOKENS handles minimal)
floor gpt-5.6-sol      minimal minimal  # older codex family still accepts minimal
unset MODEL EFFORT

# --- Genuinely unknown -> nonzero rc (caller falls through to price/default) ---
if tier_from_name "some-brand-new-2027-model" >/dev/null 2>&1; then
  echo "FAIL: unknown id should return nonzero"; fail=$((fail+1))
else echo "PASS: unknown id returns nonzero (falls through to price/default)"; pass=$((pass+1)); fi

# --- Conserve: Claude WEEKLY binds, a fresh 5h window must not mask a nearly-gone week ---
export OSRC_CONSERVE_THRESHOLD=50
ct() { # ct <desc> <limits-line> <expect-substr>
  local out; out="$(_conserve_reco "$2" "" 2>/dev/null)"
  case "$out" in *"$3"*) echo "PASS: conserve $1"; pass=$((pass+1));;
    *) echo "FAIL: conserve $1 -> expected '*$3*' got: $out"; fail=$((fail+1));; esac
}
ct "weekly 82% + 5h 20% -> CONSERVE (weekly binds)" "claude5h=20 claude7d=82" "CONSERVE"
ct "weekly names the binding window"               "claude5h=20 claude7d=82" "binding: weekly 82%"
ct "5h 90% + weekly 10% -> CONSERVE (5h binds)"    "claude5h=90 claude7d=10" "binding: 5h 90%"
ct "both low -> HEADROOM"                          "claude5h=20 claude7d=30" "HEADROOM"

# _lane_conserve_mult: cc penalized by weekly even when 5h is fresh
lcm() { # lcm <desc> <limits> <cmp> <bound>  (awk numeric compare of result)
  local m; m="$(_lane_conserve_mult cc "$2" 2>/dev/null)"
  if awk -v m="$m" -v b="$4" "BEGIN{exit !(m $3 b)}" 2>/dev/null; then echo "PASS: mult $1 ($m)"; pass=$((pass+1));
  else echo "FAIL: mult $1 -> got $m (wanted $3 $4)"; fail=$((fail+1)); fi
}
lcm "weekly 90% / 5h 10% -> haircut < 1.00" "claude5h=10 claude7d=90" "<" "1.00"
lcm "both below line -> no haircut (==1.00)" "claude5h=10 claude7d=20" "==" "1.00"
unset OSRC_CONSERVE_THRESHOLD

echo "---"; echo "tier churn: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
