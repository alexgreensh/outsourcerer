#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"; TMP="$(mktemp -d "$PWD/.test-claims.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
OSRC_HOME="$TMP/state"; export OSRC_HOME; set --; . "$SRC" >/dev/null 2>&1
_pid_start_identity(){ printf 'Mon Jan 1 00:00:00 2024\n'; }
tmux(){ [ "$1" = display-message ] && { echo 42; return 0; }; return 1; }
token="$(_external_session_claim external-1 pane:0.0)"; [ -n "$token" ] && [ -f "$OSRC_SESSION_CLAIMS/external-1/owner.json" ] && ok "claim records endpoint and process identity" || bad "claim was not durable"
_external_session_claim external-1 pane:0.0 >/dev/null 2>&1 && bad "second controller acquired the claim" || ok "atomic claim excludes a second controller"
SESSION_CLAIM_TOKEN=wrong; _external_session_release external-1 >/dev/null 2>&1 && bad "wrong token released claim" || ok "release requires the controller token"
SESSION_CLAIM_TOKEN="$token"; _external_session_release external-1 && [ ! -d "$OSRC_SESSION_CLAIMS/external-1" ] && ok "verified controller releases claim" || bad "verified release failed"
echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
