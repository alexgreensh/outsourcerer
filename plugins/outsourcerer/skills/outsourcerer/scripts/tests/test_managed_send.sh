#!/usr/bin/env bash
# Bug 2 — managed `session send` must NEVER forge a delivery receipt. Without a usable external receipt
# adapter it reports "sent (unverified)" (rc 2) and records delivery_unknown; a broken adapter fails
# closed; only a real external receipt yields a verified `submitted`.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "$PWD/.test-msend.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
set --; . "$SRC" >/dev/null 2>&1

# ---- the forgery is GONE: no receipt is minted from send-keys success / pane-scraping ------------
grep -q '_managed_send_verify' "$SRC" && bad "pane-scraping verifier still present (forgeable)" || ok "no pane-scraping submission verifier"
grep -q '_managed_receipt' "$SRC" && bad "built-in receipt minter still present (forges target_transition)" || ok "no built-in receipt minter"

# ---- honest reporting contract in the dispatch (rc 0 verified / 2 unverified / else real failure) -
grep -q 'delivery NOT independently verified' "$SRC" && ok "dispatch reports 'sent (unverified)' honestly" || bad "no honest unverified message"
grep -q 'session send failed: nothing was typed' "$SRC" && ok "dispatch distinguishes a genuine send failure" || bad "no genuine-failure message"

# ---- _external_probe_configured: unset=1, usable=0, set-but-missing=2 (fail closed) ---------------
( _external_probe_configured ""; [ $? -eq 1 ] ) && ok "unset probe -> unset(1)" || bad "unset probe rc wrong"
( _external_probe_configured "sh"; [ $? -eq 0 ] ) && ok "usable probe -> configured(0)" || bad "usable probe rc wrong"
( _external_probe_configured "/no/such/osrc-probe-xyz"; [ $? -eq 2 ] ) && ok "set-but-missing probe -> unusable(2), fails closed" || bad "missing probe rc wrong"

# ---- _managed_composer_state: broken adapter must NOT silently downgrade to the built-in ----------
export OSRC_EXTERNAL_COMPOSER_PROBE="/no/such/osrc-probe-xyz"
[ "$(_managed_composer_state s p 2>/dev/null)" = "unknown" ] && ok "broken composer probe -> unknown (no fallthrough to built-in)" || bad "broken composer probe fell through to built-in"
unset OSRC_EXTERNAL_COMPOSER_PROBE

# ---- cc auto-restore is REPORT-ONLY (no mid-turn /model injection on the heartbeat path) ----------
grep -q 'REPORT-ONLY on the automatic path' "$SRC" && ok "cc heartbeat restore is report-only (no auto-typing)" || bad "cc auto-restore still types into the session"

echo "----"
echo "managed-send: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
