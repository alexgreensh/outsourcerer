#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TMP="$(mktemp "${TMPDIR:-/tmp}/osrc-cost.XXXXXX")"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/osrc-cost-fixture.XXXXXX")"
trap 'rm -f "$TMP"; rm -rf "$FIX"' EXIT
sed '/^[[:space:]]*main "\$@"[[:space:]]*$/d' "$SRC" > "$TMP"
set +e
# shellcheck disable=SC1090
. "$TMP"
set -e

pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }
expect_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then ok "$label"; else bad "$label (got '$got', want '$want')"; fi
}
expect_source() {
  local label="$1" pattern="$2"
  if grep -Eq "$pattern" "$SRC"; then ok "$label"; else bad "$label"; fi
}
reject_source() {
  local label="$1" pattern="$2"
  if grep -Eq "$pattern" "$SRC"; then bad "$label"; else ok "$label"; fi
}

expect_eq "local disclosure" "$(_lane_cost_disclosure local)" '$0 cash + $0 plan'
expect_eq "ChatGPT disclosure" "$(_lane_cost_disclosure cx)" '$0 cash, spends your ChatGPT plan limits'
expect_eq "Claude disclosure" "$(_lane_cost_disclosure cc)" '$0 cash, spends your Claude plan limits'
expect_eq "Antigravity disclosure" "$(_lane_cost_disclosure gm)" '$0 cash, spends your Antigravity plan limits'
expect_eq "Devin disclosure" "$(_lane_cost_disclosure dv)" '$0 cash, spends your Devin plan limits'
expect_eq "Cursor disclosure" "$(_lane_cost_disclosure cursor)" '$0 cash, spends your Cursor plan limits'
expect_eq "OpenRouter remains metered" "$(_lane_cost_disclosure or)" 'metered cash, measured per run when available, otherwise estimated'
expect_eq "Hermes BYOK remains metered" "$(_lane_cost_disclosure hermes)" 'metered cash from your configured provider, measured when available, otherwise estimated'

if command -v jq >/dev/null 2>&1; then
  OSRC_LEDGER="$FIX/ledger.jsonl"
  cat > "$OSRC_LEDGER" <<'EOF'
{"provider":"codex-native","model":"gpt-5.6-sol","verb":"run","lane":"cx","cost_usd":"0.000000"}
{"provider":"claude-native","model":"claude-sonnet","verb":"run","lane":"cc","cost_usd":"0.000000"}
{"provider":"devin","model":"glm-5.2","verb":"run","lane":"dv","cost_usd":"0.000000"}
{"provider":"local","model":"qwen","verb":"run","lane":"local","cost_usd":"0.000000"}
EOF
  tab_out="$(cmd_tab 2>&1)"
  for disclosure in \
    '$0 cash, spends your ChatGPT plan limits' \
    '$0 cash, spends your Claude plan limits' \
    '$0 cash, spends your Devin plan limits' \
    '$0 cash + $0 plan'; do
    if printf '%s\n' "$tab_out" | grep -Fq "$disclosure"; then
      ok "tab renders $disclosure"
    else
      bad "tab omitted $disclosure"
    fi
  done

  OSRC_MODELS_JSON="$FIX/missing-models.json"
  estimate_out="$(cmd_estimate 'small task' 2>&1)"
  if printf '%s\n' "$estimate_out" | grep -Fq '$0 cash, spends your ChatGPT plan limits' &&
     printf '%s\n' "$estimate_out" | grep -Fq '$0 cash + $0 plan'; then
    ok "estimate renders plan and local disclosures"
  else
    bad "estimate omitted plan or local disclosure"
  fi

  OSRC_MODELS_JSON="$FIX/models.json"
  printf '{"data":[]}\n' > "$OSRC_MODELS_JSON"
  have() { [ "$1" = jq ]; }
  suggest_out="$(cmd_suggest 2>&1)"
  if printf '%s\n' "$suggest_out" | grep -Fq '$0 cash, spends your ChatGPT plan limits' &&
     printf '%s\n' "$suggest_out" | grep -Fq '$0 cash, spends your Antigravity plan limits'; then
    ok "suggest renders named plan-limit disclosures"
  else
    bad "suggest omitted named plan-limit disclosure"
  fi
else
  echo "SKIP: rendered command checks require jq"
fi

helper_line="$(grep -n '^_lane_cost_disclosure()' "$SRC" | cut -d: -f1)"
ledger_line="$(grep -n '^record_ledger()' "$SRC" | cut -d: -f1)"
if [ -n "$helper_line" ] && [ -n "$ledger_line" ] && [ "$helper_line" -lt "$ledger_line" ]; then
  ok "cost helper is beside record_ledger"
else
  bad "cost helper is not beside record_ledger"
fi

expect_source "tab reports named plan-limit spend" '\$0 cash, spends your .* plan limits'
expect_source "estimate uses shared disclosures" 'cmd_estimate\(\)'
expect_source "suggest uses shared disclosures" '_lane_cost_disclosure (dv|cx|cc|gm)'
expect_source "delegate receipts use shared disclosures" '\[receipt\].*_lane_cost_disclosure'
expect_source "doctor uses shared disclosures" 'cost: \$\(_lane_cost_disclosure'
expect_source "loop report uses shared disclosure" '\[loop verify\].*_lane_cost_disclosure'

reject_source "Devin is not described as a free lane" 'Devin[^\n]*(free lane|free-lane)|free lane[^\n]*Devin'
reject_source "subscription receipts do not say no cash" '\[receipt\][^\n]*no cash'
reject_source "subscription receipts do not say zero spend" '\[receipt\][^\n]*zero (Claude|ChatGPT|subscription)[^\n]*spend'

# :free remains valid only as an explicit model-pricing token.
expect_source "model pricing still recognizes :free" '\*:free'

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
