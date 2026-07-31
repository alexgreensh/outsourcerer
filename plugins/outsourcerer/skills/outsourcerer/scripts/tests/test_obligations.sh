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
echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
