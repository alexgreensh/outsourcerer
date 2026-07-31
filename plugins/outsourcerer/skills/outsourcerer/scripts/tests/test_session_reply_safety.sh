#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"; TMP="$(mktemp -d "$PWD/.test-reply.XXXXXX")"; TEST_TMP="$TMP"; trap 'rm -rf "$TEST_TMP"' EXIT
pass=0; fail=0; ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
OSRC_HOME="$TMP/state"; OSRC_EXTERNAL_SEND=1; export OSRC_HOME OSRC_EXTERNAL_SEND; set --; . "$SRC" >/dev/null 2>&1; LOG="$TMP/keys"
_pid_start_identity(){ printf 'Mon Jan 1 00:00:00 2024\n'; }
PANE_PID=42
tmux(){ case "$1" in display-message) echo "$PANE_PID";; send-keys) printf '%s\n' "$*" >> "$LOG";; *) return 1;; esac; }
_external_composer_state(){ echo "${COMPOSER:-unknown}"; }; _external_receipt_verify(){ [ "${RECEIPT:-unknown}" = unknown ] && { echo unknown; return; }; jq -cn --arg obligation "$2" --arg endpoint "tmux:$1" --arg generation "$SESSION_CLAIM_GENERATION" '{obligation_id:$obligation,endpoint:$endpoint,generation:$generation,target_transition:true}'; }
_external_session_claim external-2 pane:0.0 >/dev/null; token="$(jq -r .token "$OSRC_SESSION_CLAIMS/external-2/owner.json")"; SESSION_CLAIM_TOKEN="$token"; SESSION_CLAIM_GENERATION="$(jq -r .generation "$OSRC_SESSION_CLAIMS/external-2/owner.json")"; COMPOSER=unknown; RECEIPT=ok
_external_reply external-2 hello >/dev/null 2>&1 && bad "unverified composer accepted input" || ok "unknown composer blocks terminal input"
[ ! -e "$LOG" ] && ok "blocked composer writes no keys" || bad "blocked composer wrote keys"
COMPOSER=empty; _external_reply external-2 hello >/dev/null && grep -q 'send-keys' "$LOG" && ok "verified composer plus receipt submits once" || bad "verified reply failed"
before="$(wc -l < "$LOG" | tr -d ' ')"; _external_reply external-2 hello >/dev/null 2>&1 && bad "completed obligation replayed" || { after="$(wc -l < "$LOG" | tr -d ' ')"; [ "$before" = "$after" ] && ok "receipt prevents replay" || bad "replay wrote keys"; }
_external_session_claim external-identity pane:0.0 >/dev/null; token="$(jq -r .token "$OSRC_SESSION_CLAIMS/external-identity/owner.json")"; SESSION_CLAIM_TOKEN="$token"; SESSION_CLAIM_GENERATION="$(jq -r .generation "$OSRC_SESSION_CLAIMS/external-identity/owner.json")"; COMPOSER=empty; PANE_PID=99
before="$(wc -l < "$LOG" | tr -d ' ')"; _external_reply external-identity wrong-pane >/dev/null 2>&1 || true; after="$(wc -l < "$LOG" | tr -d ' ')"
[ "$before" = "$after" ] && ok "replacement pane PID blocks terminal input" || bad "replacement pane accepted input"
echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
