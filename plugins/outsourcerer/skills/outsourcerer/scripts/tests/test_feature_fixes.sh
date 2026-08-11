#!/usr/bin/env bash
# test_feature_fixes.sh — regression for the QA-gauntlet fixes:
#   F4  _pane_state_json escapes evidence so output is ALWAYS valid JSON (quotes/backslash/tab).
#   F5  _explain_redact catches uppercase API_KEY, hyphenated api-key, HTTP Basic-Auth URLs,
#       sk-* and password=; and cmd_explain runs the DELEGATE-controlled reason/error through it.
# Self-contained. Run: bash test_feature_fixes.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-fixes.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home"; export OSRC_SOURCED=1
mkdir -p "$OSRC_HOME/jobs"
. "$SRC" >/dev/null 2>&1
type -t _pane_state_json >/dev/null || { echo "FAIL: _pane_state_json not loaded"; exit 1; }
type -t _explain_redact  >/dev/null || { echo "FAIL: _explain_redact not loaded"; exit 1; }
type -t cmd_explain      >/dev/null || { echo "FAIL: cmd_explain not loaded"; exit 1; }
OSRC_JOBS="$OSRC_HOME/jobs"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

# ---------- F4: pane-state JSON stays valid with hostile evidence ----------
if have jq; then
  ev="$(printf 'he said "yes" \\ backslash\ttab-here')"
  out="$(_pane_state_json waiting-approval "$ev")"
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then ok "F4: _pane_state_json emits valid JSON for quotes/backslash/tab"
  else bad "F4: invalid JSON: $out"; fi
  st="$(printf '%s' "$out" | jq -r '.state' 2>/dev/null)"
  [ "$st" = "waiting-approval" ] && ok "F4: state field survives escaping" || bad "F4: state='$st'"
  # full classifier on an approval pane whose text contains a double-quote
  cout="$(printf 'foo\nDo you want to proceed? "really" [y/N]\n' | _pane_state_classify)"
  if printf '%s' "$cout" | jq -e '.state=="waiting-approval"' >/dev/null 2>&1; then ok "F4: classifier output valid JSON + waiting-approval on quoted approval line"
  else bad "F4: classifier bad JSON/state: $cout"; fi
else
  echo "SKIP: jq not installed (F4 JSON-validity checks skipped)"
fi

# ---------- F5a: redactor covers the gauntlet cases ----------
redact_hits() { printf '%s' "$1" | _explain_redact; }
check_redacted() { # <label> <input> <raw-secret-that-must-be-gone>
  local o; o="$(redact_hits "$2")"
  case "$o" in *"$3"*) bad "F5: $1 leaked ('$o')" ;; *) ok "F5: $1 redacted" ;; esac
}
check_redacted "uppercase API_KEY"      "API_KEY = SUPERSECRET1234"                 "SUPERSECRET1234"
check_redacted "hyphenated api-key"     "x-api-key: HYPHENSECRET999"                "HYPHENSECRET999"
check_redacted "HTTP Basic-Auth URL"    "db at https://admin:hunter2pw@h.example/x" "admin:hunter2pw"
check_redacted "sk- key"                "using sk-live-ABCDEFGH12345 now"           "sk-live-ABCDEFGH12345"
check_redacted "password="              "password=topSecretPw1"                     "topSecretPw1"

# ---------- F5b: cmd_explain runs delegate reason/error THROUGH the redactor ----------
jid="j-secretreason"; jd="$OSRC_JOBS/$jid"; mkdir -p "$jd"
printf 'permission-blocked\n' > "$jd/status"
printf '{"id":"%s","model":"glm-5-2","verb":"edit","provider":"devin","started":1700000000}\n' "$jid" > "$jd/meta.json"
: > "$jd/out.log"
# a delegate-authored reason carrying secrets
printf 'blocked: auth to https://u:p@host failed, API_KEY=sk-live-LEAKME1234567\n' > "$jd/reason"
xout="$(cmd_explain "$jid" 2>/dev/null)"
case "$xout" in
  *"sk-live-LEAKME1234567"*) bad "F5b: explain leaked the sk- key from reason" ;;
  *) ok "F5b: explain redacted the sk- key in delegate reason" ;;
esac
case "$xout" in
  *"u:p@host"*) bad "F5b: explain leaked basic-auth from reason" ;;
  *) ok "F5b: explain redacted basic-auth in delegate reason" ;;
esac

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
