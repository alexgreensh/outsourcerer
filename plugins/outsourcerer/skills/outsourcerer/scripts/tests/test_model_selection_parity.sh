#!/usr/bin/env bash
# Model selection and effort propagation stay consistent across dispatch lanes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TEST_ROOT="$(mktemp -d)"
export OSRC_HOME="$TEST_ROOT"
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

. "$SRC" >/dev/null 2>&1

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
ck()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2', want '$3'"; fi; }

ck "Kimi alias resolves on Devin" "$(_lane_model_for devin kimi)" "kimi-k3"
ck "Kimi alias resolves on Droid" "$(_lane_model_for droid kimi)" "kimi-k3"
ck "Kimi alias resolves on Warp" "$(_lane_model_for warp kimi)" "kimi-k3"
ck "Kimi id remains stable on Devin" "$(_lane_model_for devin kimi-k3)" "kimi-k3"
ck "Kimi id remains stable on Droid" "$(_lane_model_for droid kimi-k3)" "kimi-k3"
ck "Kimi id remains stable on Warp" "$(_lane_model_for warp kimi-k3)" "kimi-k3"
ck "Kimi has a Devin sibling" "$(_devin_model_for kimi)" "kimi-k3"

hard_kimi="$(_score 50 capable code high hard kimi-k3)"
hard_frontier="$(_score 55 frontier code high hard gpt-5.6-sol)"
if awk -v k="$hard_kimi" -v f="$hard_frontier" 'BEGIN { exit !(k > f) }'; then
  ok "high-effort hard work favors near-frontier value"
else
  bad "high-effort hard work scored Kimi $hard_kimi and frontier $hard_frontier"
fi

max_kimi="$(_score 50 capable code max hard kimi-k3)"
max_frontier="$(_score 55 frontier code max hard gpt-5.6-sol)"
if awk -v k="$max_kimi" -v f="$max_frontier" 'BEGIN { exit !(f > k) }'; then
  ok "max effort can require a frontier model"
else
  bad "max effort scored Kimi $max_kimi and frontier $max_frontier"
fi

refresh_benchmarks() { return 1; }
high_json="$(cmd_advise --json --effort high "implement a multi-step authentication refactor with tests and debug failures" 2>&1)"
ck "advise records selection effort" "$(printf '%s' "$high_json" | jq -r '.effort')" "high"
ck "advise picks Kimi for hard work" "$(printf '%s' "$high_json" | jq -r '.recommendation.alias')" "kimi"
ck "advise returns a valid Devin model" "$(printf '%s' "$high_json" | jq -r '.recommendation.model')" "kimi-k3"
ck "advise marks Kimi capable" "$(printf '%s' "$high_json" | jq -r '.recommendation.tier')" "capable"

max_json="$(cmd_advise --json --effort max "implement a multi-step authentication refactor with tests and debug failures" 2>&1)"
ck "max-effort advise picks frontier tier" "$(printf '%s' "$max_json" | jq -r '.recommendation.tier')" "frontier"

EFFORT=high
prompt="$(_build_prompt kimi-k3 "inspect the module" capable)"
case "$prompt" in
  *"Reasoning effort: high."*) ok "shared prompt carries effort into dispatch" ;;
  *) bad "shared prompt omitted effort" ;;
esac

for lane_fn in delegate_cxnative delegate_ccnative delegate_gmnative delegate_claudex \
               delegate_droid delegate_cursor delegate_hermes delegate_warp delegate_cc \
               delegate_local delegate_codex; do
  body="$(sed -n "/^${lane_fn}() {/,/^}/p" "$SRC")"
  if printf '%s' "$body" | grep -q '_build_prompt'; then
    ok "$lane_fn uses the shared effort-aware prompt"
  else
    bad "$lane_fn bypasses the shared effort-aware prompt"
  fi
done

devin_body="$(sed -n '/^delegate() {/,/^}/p' "$SRC")"
if printf '%s' "$devin_body" | grep -q '_effort_prompt'; then
  ok "Devin receives effort as an advisory prompt input"
else
  bad "Devin dispatch omits effort from its prompt"
fi

droid_body="$(sed -n '/^delegate_droid() {/,/^}/p' "$SRC")"
warp_body="$(sed -n '/^delegate_warp() {/,/^}/p' "$SRC")"
printf '%s' "$droid_body" | grep -q '_lane_model_for droid' \
  && ok "Droid resolves lane-specific model ids" || bad "Droid skips lane-specific model resolution"
printf '%s' "$warp_body" | grep -q '_lane_model_for warp' \
  && ok "Warp resolves lane-specific model ids" || bad "Warp skips lane-specific model resolution"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
