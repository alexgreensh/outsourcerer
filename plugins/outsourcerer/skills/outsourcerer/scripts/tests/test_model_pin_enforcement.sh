#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "$PWD/.test-model-pin.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
set --; . "$SRC" >/dev/null 2>&1
mkdir -p "$OSRC_SESSIONS"
KEYS="$TMP/keys"
_pid_start_identity() { printf '%s\n' 'Mon Jan 1 00:00:00 2024'; }
tmux() { case "$1" in display-message) printf '42\n' ;; send-keys) printf '%s\n' "$*" >> "$KEYS" ;; *) return 0 ;; esac; }
_external_composer_state() { printf '%s\n' "${COMPOSER:-unknown}"; }
_external_receipt_verify() { [ "${RECEIPT:-unknown}" = unknown ] && { printf '%s\n' unknown; return; }; jq -cn --arg obligation "$2" --arg endpoint "tmux:$1" --arg generation "1" '{obligation_id:$obligation,endpoint:$endpoint,generation:$generation,target_transition:true}'; }

SESSION_NAME=pin-record
_session_registry_append start devin fable high started launch
record="$(tail -1 "$OSRC_SESSION_REGISTRY")"
printf '%s' "$record" | jq -e '.requested_model == "fable" and .resolved_model == "fable" and .model_generation == 1' >/dev/null \
  && ok "session start records requested, resolved, and generation" \
  || bad "session start model pin fields are missing"

_session_model_matches fable claude-fable-5 fable && ok "requested model is a positive match" || bad "requested model did not match"
_session_model_matches fable claude-fable-5 claude-fable-5 && ok "resolved model is a positive match" || bad "resolved model did not match"
_session_model_matches fable claude-fable-5 unknown && bad "unknown observation matched" || ok "unknown observation never matches"

item='{"session_id":"pin-one","owner":"managed","state":"working","lane":"devin","endpoint":"tmux:pin-one","requested_model":"fable","resolved_model":"fable","observed_model":"opus","model_generation":7,"task_summary":"work"}'
SESSION_NAME=pin-one; _session_registry_append start devin fable high started launch
COMPOSER=empty RECEIPT=receipt-1
out="$(_model_pin_enforce_item "$item" generation-a)"
printf '%s' "$out" | jq -e '.model_pin.result == "restored"' >/dev/null && ok "drift with both proofs restores through the bounded path" || bad "eligible drift did not restore: $out"
[ "$(wc -l < "$KEYS" | tr -d ' ')" = 3 ] && ok "restore uses only the model adapter inputs" || bad "restore key sequence was unexpected"
grep -q 'model-drift.pin-one.generation-a' "$OSRC_WAKE_QUEUE" && ok "drift wake is durable before restore" || bad "drift wake missing"

before="$(wc -l < "$KEYS" | tr -d ' ')"
_model_pin_enforce_item "$item" generation-a >/dev/null
after="$(wc -l < "$KEYS" | tr -d ' ')"
[ "$before" = "$after" ] && ok "generation restore budget prevents repeated input" || bad "same generation restored twice"

busy_item='{"session_id":"pin-busy","owner":"managed","state":"working","lane":"devin","endpoint":"tmux:pin-busy","requested_model":"fable","resolved_model":"fable","observed_model":"opus","model_generation":1}'
SESSION_NAME=pin-busy; _session_registry_append start devin fable high started launch
COMPOSER=nonempty
before="$(wc -l < "$KEYS" | tr -d ' ')"
out="$(_model_pin_enforce_item "$busy_item" generation-b)"
after="$(wc -l < "$KEYS" | tr -d ' ')"
[ "$before" = "$after" ] && printf '%s' "$out" | jq -e '.model_pin.result == "reported" or .model_pin.result == "restore-failed"' >/dev/null \
  && ok "busy composer reports drift without input" || bad "busy composer allowed a restore"

unknown_item='{"session_id":"pin-unknown","owner":"managed","state":"working","lane":"devin","endpoint":"tmux:pin-unknown","requested_model":"fable","resolved_model":"fable","observed_model":"unknown","model_generation":1}'
before="$(wc -l < "$KEYS" | tr -d ' ')"; _model_pin_enforce_item "$unknown_item" generation-c >/dev/null; after="$(wc -l < "$KEYS" | tr -d ' ')"
[ "$before" = "$after" ] && ok "unknown live model sends zero keys" || bad "unknown live model triggered input"

external_item='{"session_id":"pin-external","owner":"external","state":"working","lane":"devin","endpoint":"tmux:pin-external","requested_model":"fable","resolved_model":"fable","observed_model":"opus","model_generation":1}'
COMPOSER=empty; before="$(wc -l < "$KEYS" | tr -d ' ')"; _model_pin_enforce_item "$external_item" generation-d >/dev/null; after="$(wc -l < "$KEYS" | tr -d ' ')"
[ "$before" = "$after" ] && ok "unclaimed external drift sends zero keys" || bad "external session was changed"

line="$(_heartbeat_line "{\"items\":[$out]}")"
case "$line" in *"pinned fable->opus [reported]"*|*"pinned fable->opus [restore-failed]"*) ok "heartbeat line reports the observed flip" ;; *) bad "heartbeat flip missing: $line" ;; esac

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
