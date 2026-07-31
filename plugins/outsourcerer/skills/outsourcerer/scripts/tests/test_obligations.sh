#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"; TMP="$(mktemp -d "$PWD/.test-obligations.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
OSRC_HOME="$TMP/state"; export OSRC_HOME; set --; . "$SRC" >/dev/null 2>&1; LOG="$TMP/keys"
_pid_start_identity(){ printf 'Mon Jan 1 00:00:00 2024\n'; }
tmux(){ case "$1" in display-message) echo 42;; send-keys) printf '%s\n' "$*" >> "$LOG";; *) return 1;; esac; }
_external_composer_state(){ echo empty; }; _external_receipt_verify(){ echo unknown; }
token="$(_external_session_claim external-3 pane:0.0)"; SESSION_CLAIM_TOKEN="$token"
_external_reply external-3 payload >/dev/null 2>&1 && bad "missing receipt was reported sent" || ok "missing receipt fails closed"
state="$(_obligation_latest_state reply.external-3.$(printf payload | cksum | awk '{print $1}'))"; [ "$state" = delivery_unknown ] && ok "post-submit ambiguity is durable" || bad "ambiguous delivery was not recorded"
grep -q 'delivery unknown' "$OSRC_WAKE_QUEUE" && ok "ambiguous delivery is escalated" || bad "ambiguous delivery was not escalated"
before="$(wc -l < "$LOG" | tr -d ' ')"; _external_reply external-3 payload >/dev/null 2>&1 || true; after="$(wc -l < "$LOG" | tr -d ' ')"
[ "$before" = "$after" ] && ok "delivery_unknown never auto-replays" || bad "delivery_unknown replayed"
( _obligation_admit concurrent-1 external-3 ) & p1=$!
( _obligation_admit concurrent-1 external-3 ) & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
rows="$(_state_jsonl_read "$OSRC_OBLIGATIONS" | jq -r 'select(.obligation_id=="concurrent-1" and .state=="pending") | 1' | wc -l | tr -d ' ')"
[ "$rows" = 1 ] && { [ "$r1" -eq 0 ] || [ "$r2" -eq 0 ]; } && ok "concurrent admission creates one durable obligation" || bad "concurrent admission was not atomic (rows=$rows rc=$r1/$r2)"
crash_oid="reply.external-3.$(printf crash-point | cksum | awk '{print $1}')"
_obligation_append "$crash_oid" external-3 typing_started ""
before="$(wc -l < "$LOG" | tr -d ' ')"; _external_reply external-3 crash-point >/dev/null 2>&1 || true; after="$(wc -l < "$LOG" | tr -d ' ')"
[ "$(_obligation_latest_state "$crash_oid")" = delivery_unknown ] && [ "$before" = "$after" ] && ok "post-typing crash recovers as delivery_unknown without replay" || bad "post-typing crash recovery replayed or stayed pending"
echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
