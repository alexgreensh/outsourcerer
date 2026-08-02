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

# ---- regression: for a DEVIN session the text MUST actually land (send-keys -l + Enter), not abort
# before typing with "delivery unknown". The 0.6.1 composer guard failed closed for devin and never typed;
# 0.6.2 makes devin's composer state 'empty' so the send proceeds. This asserts the keys really go out.
( TLOG="$TMP/tmux.calls"; : > "$TLOG"
  tmux() { printf '%s\n' "$*" >> "$TLOG"; case "$1 $2" in "display -p"*) printf '0\n' ;; "capture-pane"*) printf '\n' ;; *) return 0 ;; esac; }
  _managed_endpoint_live() { return 0; }; _endpoint_mutation_lock() { return 0; }; _endpoint_mutation_unlock() { return 0; }
  _obligation_latest_state() { printf ''; }; _obligation_admit() { return 0; }; _obligation_append() { return 0; }
  _obligation_guard_begin() { return 0; }; _obligation_guard_end() { return 0; }; _obligation_delivery_unknown() { return 0; }
  _managed_provider() { printf 'devin'; }; _state_jsonl_read() { printf ''; }
  unset OSRC_EXTERNAL_RECEIPT_PROBE OSRC_EXTERNAL_COMPOSER_PROBE
  _managed_session_send "sess-dv" "analyze this" ; rc=$?
  grep -q 'send-keys -t sess-dv -l -- analyze this' "$TLOG" && grep -q 'send-keys -t sess-dv Enter' "$TLOG" && [ "$rc" = 2 ]
) && ok "devin session send actually types the text + Enter (bug 1: text lands, rc2 honest)" || bad "devin session send did not deliver the keys (bug 1 regressed)"

echo "----"
echo "managed-send: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
