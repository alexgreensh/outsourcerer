#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"; TMP="$(mktemp -d "$PWD/.test-claims.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
mkdir -p "$TMP/bin"
cat > "$TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  display-message) printf '42\n' ;;
  send-keys) printf '%s\n' "$*" >> "$OSRC_TEST_KEYS" ;;
  *) exit 1 ;;
esac
EOF
cat > "$TMP/bin/ps" <<'EOF'
#!/usr/bin/env bash
printf 'Mon Jan 1 00:00:00 2024\n'
EOF
cat > "$TMP/composer" <<'EOF'
#!/usr/bin/env bash
printf 'empty\n'
EOF
cat > "$TMP/receipt" <<'EOF'
#!/usr/bin/env bash
generation="$(jq -r '.generation' "$OSRC_HOME/sessions/claims/external-reply/owner.json")"
jq -cn --arg obligation "$2" --arg endpoint "tmux:$1" --arg generation "$generation" '{obligation_id:$obligation,endpoint:$endpoint,generation:$generation,target_transition:true}'
EOF
chmod +x "$TMP/bin/tmux" "$TMP/bin/ps" "$TMP/composer" "$TMP/receipt"
run_cli(){ PATH="$TMP/bin:$PATH" OSRC_HOME="$TMP/state" OSRC_EXTERNAL_SEND=1 OSRC_CONTROLLER_ID=controller-A OSRC_TEST_KEYS="$TMP/keys" "$SRC" "$@"; }

claim_out="$(run_cli session claim external-release pane:0.0)" && token="$(printf '%s\n' "$claim_out" | sed -n 's/^claim token: //p')" || token=""
[ -n "$token" ] && [ -f "$TMP/state/sessions/claims/external-release/owner.json" ] && ok "claim records a durable controller identity" || bad "claim was not durable"
PATH="$TMP/bin:$PATH" OSRC_HOME="$TMP/state" OSRC_EXTERNAL_SEND=1 OSRC_CONTROLLER_ID=controller-A OSRC_SESSION_CLAIM_TOKEN=wrong "$SRC" session release external-release >/dev/null 2>&1 && bad "wrong token released claim" || ok "release requires controller id and token"
PATH="$TMP/bin:$PATH" OSRC_HOME="$TMP/state" OSRC_EXTERNAL_SEND=1 OSRC_CONTROLLER_ID=controller-A OSRC_SESSION_CLAIM_TOKEN="$token" "$SRC" session release external-release >/dev/null 2>&1 && [ ! -d "$TMP/state/sessions/claims/external-release" ] && ok "separate CLI invocation releases claim" || bad "cross-invocation release failed"

claim_out="$(run_cli session claim external-reply pane:0.0)" && token="$(printf '%s\n' "$claim_out" | sed -n 's/^claim token: //p')" || token=""
PATH="$TMP/bin:$PATH" OSRC_HOME="$TMP/state" OSRC_EXTERNAL_SEND=1 OSRC_CONTROLLER_ID=controller-A OSRC_SESSION_CLAIM_TOKEN="$token" OSRC_EXTERNAL_COMPOSER_PROBE="$TMP/composer" OSRC_EXTERNAL_RECEIPT_PROBE="$TMP/receipt" OSRC_TEST_KEYS="$TMP/keys" "$SRC" session reply external-reply hello >/dev/null && grep -q 'send-keys' "$TMP/keys" && ok "separate CLI invocation replies with matching controller id and token" || bad "cross-invocation reply failed"
before="$(wc -l < "$TMP/keys" | tr -d ' ')"; PATH="$TMP/bin:$PATH" OSRC_HOME="$TMP/state" OSRC_EXTERNAL_SEND=1 OSRC_CONTROLLER_ID=controller-B OSRC_SESSION_CLAIM_TOKEN="$token" OSRC_EXTERNAL_COMPOSER_PROBE="$TMP/composer" OSRC_EXTERNAL_RECEIPT_PROBE="$TMP/receipt" OSRC_TEST_KEYS="$TMP/keys" "$SRC" session reply external-reply denied >/dev/null 2>&1 || true; after="$(wc -l < "$TMP/keys" | tr -d ' ')"
[ "$before" = "$after" ] && ok "mismatched durable controller cannot reply" || bad "mismatched controller wrote keys"
echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
