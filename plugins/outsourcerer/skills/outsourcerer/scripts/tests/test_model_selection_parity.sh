#!/usr/bin/env bash
# Model selection and effort propagation stay consistent across dispatch lanes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TEST_ROOT="$(mktemp -d)"
export HOME="$TEST_ROOT/fakehome" OSRC_HOME="$TEST_ROOT"
mkdir -p "$HOME"
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

printf '%s\n' '{"data":[{"model_permaslug":"openai/gpt-5.6-sol","coding_index":77,"intelligence_index":59,"agentic_index":54}]}' > "$OSRC_BENCH_JSON"
for effort in high max; do
  json="$(cmd_advise --json --effort "$effort" "refactor a module")"
  ck "advise records selection effort" "$(jq -r '.effort' <<<"$json")" "$effort"
  ck "benchmark winner at $effort effort" "$(jq -r '.recommendation.model' <<<"$json")" gpt-5.6-sol
done

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
  if grep -q '_build_prompt' <<<"$body"; then
    ok "$lane_fn uses the shared effort-aware prompt"
  else
    bad "$lane_fn bypasses the shared effort-aware prompt"
  fi
done

devin_body="$(sed -n '/^delegate() {/,/^}/p' "$SRC")"
if grep -q '_effort_prompt' <<<"$devin_body"; then
  ok "Devin receives effort as an advisory prompt input"
else
  bad "Devin dispatch omits effort from its prompt"
fi

droid_body="$(sed -n '/^delegate_droid() {/,/^}/p' "$SRC")"
warp_body="$(sed -n '/^delegate_warp() {/,/^}/p' "$SRC")"
grep -q '_lane_model_for droid' <<<"$droid_body" \
  && ok "Droid resolves lane-specific model ids" || bad "Droid skips lane-specific model resolution"
grep -q '_lane_model_for warp' <<<"$warp_body" \
  && ok "Warp resolves lane-specific model ids" || bad "Warp skips lane-specific model resolution"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
