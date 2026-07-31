#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"; TMP="$(mktemp -d "$PWD/.test-reply.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
OSRC_HOME="$TMP/state"; export OSRC_HOME; set --; . "$SRC" >/dev/null 2>&1; LOG="$TMP/keys"
_pid_start_identity(){ printf 'Mon Jan 1 00:00:00 2024\n'; }
tmux(){ case "$1" in display-message) echo 42;; send-keys) printf '%s\n' "$*" >> "$LOG";; *) return 1;; esac; }
_external_composer_state(){ echo "${COMPOSER:-unknown}"; }; _external_receipt_verify(){ echo "${RECEIPT:-unknown}"; }
token="$(_external_session_claim external-2 pane:0.0)"; SESSION_CLAIM_TOKEN="$token"; COMPOSER=unknown; RECEIPT=receipt-1
_external_reply external-2 hello >/dev/null 2>&1 && bad "unverified composer accepted input" || ok "unknown composer blocks terminal input"
[ ! -e "$LOG" ] && ok "blocked composer writes no keys" || bad "blocked composer wrote keys"
COMPOSER=empty; _external_reply external-2 hello >/dev/null && grep -q 'send-keys' "$LOG" && ok "verified composer plus receipt submits once" || bad "verified reply failed"
before="$(wc -l < "$LOG" | tr -d ' ')"; _external_reply external-2 hello >/dev/null 2>&1 && bad "completed obligation replayed" || { after="$(wc -l < "$LOG" | tr -d ' ')"; [ "$before" = "$after" ] && ok "receipt prevents replay" || bad "replay wrote keys"; }
echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
