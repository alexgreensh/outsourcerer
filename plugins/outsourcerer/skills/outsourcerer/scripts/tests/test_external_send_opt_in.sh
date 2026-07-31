#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "$PWD/.test-external-opt-in.XXXXXX")"; TEST_TMP="$TMP"; trap 'rm -rf "$TEST_TMP"' EXIT
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
generation="$(jq -r '.generation' "$OSRC_HOME/sessions/claims/opt-in/owner.json")"
jq -cn --arg obligation "$2" --arg endpoint "tmux:$1" --arg generation "$generation" '{obligation_id:$obligation,endpoint:$endpoint,generation:$generation,target_transition:true}'
EOF
chmod +x "$TMP/bin/tmux" "$TMP/bin/ps" "$TMP/composer" "$TMP/receipt"
run_cli(){ PATH="$TMP/bin:$PATH" OSRC_HOME="$TMP/state" OSRC_CONTROLLER_ID=controller-A OSRC_TEST_KEYS="$TMP/keys" "$SRC" "$@"; }

out="$(run_cli session claim opt-in pane:0.0 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$TMP/state/sessions/claims/opt-in/owner.json" ] && printf '%s' "$out" | grep -q 'experimental.*OSRC_EXTERNAL_SEND=1' \
  && ok "external claim is refused by default with an experimental opt-in" || bad "default external claim was not safely refused: $out"

out="$(OSRC_EXTERNAL_SEND=1 run_cli session claim opt-in pane:0.0 2>&1)"; rc=$?
token="$(printf '%s\n' "$out" | sed -n 's/^claim token: //p')"
[ "$rc" -eq 0 ] && [ -n "$token" ] && [ -f "$TMP/state/sessions/claims/opt-in/owner.json" ] \
  && ok "external claim is allowed only after explicit opt-in" || bad "opt-in claim failed: $out"

out="$(OSRC_SESSION_CLAIM_TOKEN="$token" OSRC_EXTERNAL_COMPOSER_PROBE="$TMP/composer" OSRC_EXTERNAL_RECEIPT_PROBE="$TMP/receipt" run_cli session reply opt-in hello 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$TMP/keys" ] && printf '%s' "$out" | grep -q 'experimental.*OSRC_EXTERNAL_SEND=1' \
  && ok "external reply is refused by default before terminal input" || bad "default external reply was not safely refused: $out"

OSRC_EXTERNAL_SEND=1 OSRC_SESSION_CLAIM_TOKEN="$token" OSRC_EXTERNAL_COMPOSER_PROBE="$TMP/composer" OSRC_EXTERNAL_RECEIPT_PROBE="$TMP/receipt" run_cli session reply opt-in hello >/dev/null 2>&1 \
  && [ -s "$TMP/keys" ] && ok "opt-in external reply is allowed" || bad "opt-in external reply failed"

out="$(OSRC_SESSION_CLAIM_TOKEN="$token" run_cli session release opt-in 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && [ -f "$TMP/state/sessions/claims/opt-in/owner.json" ] && printf '%s' "$out" | grep -q 'experimental.*OSRC_EXTERNAL_SEND=1' \
  && ok "external release is refused by default" || bad "default external release was not safely refused: $out"

OSRC_EXTERNAL_SEND=1 OSRC_SESSION_CLAIM_TOKEN="$token" run_cli session release opt-in >/dev/null 2>&1 \
  && [ ! -d "$TMP/state/sessions/claims/opt-in" ] && ok "opt-in external release is allowed" || bad "opt-in external release failed"
echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
