#!/usr/bin/env bash
# 0.6.2 tool bugs: (1) free-tier Devin models must not read as blocked by the paid "0%" display,
# (3) droid explore/run (read-only) tier must be permissioned to actually read (--auto low).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "$PWD/.test-062.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
set --; . "$SRC" >/dev/null 2>&1

# ---- bug 1: free-tier detection ----------------------------------------------------------------
for m in glm glm-5.2 swe swe-1.7 swe-1.7-lightning deepseek deepseek-v4-pro kimi kimi-k3; do
  _devin_is_free_model "$m" && ok "free-tier: $m recognized" || bad "free-tier: $m NOT recognized"
done
for m in opus fable claude-opus-4-8 gpt-5.6 sonnet; do
  _devin_is_free_model "$m" && bad "free-tier: $m wrongly flagged free" || ok "free-tier: $m correctly not-free"
done

# ---- bug 1: the clarification is anchored in the source (dispatch surfaces it) -------------------
grep -q 'runs on Devin.*plan-included tier' "$SRC" && ok "free-tier clarification present in dispatch" || bad "free-tier clarification missing"
grep -q 'does NOT gate it' "$SRC" && ok "clarification states the paid figure does not gate free models" || bad "clarification wording missing"

# ---- bug 3: droid read-only (auto) tier grants --auto low, not a bare (blocked) default ----------
# The bare droid-exec default requires interactive approval and errors "insufficient permission,
# re-run with --auto medium"; --auto low is read-only + safe commands, which is what explore needs.
grep -qE 'auto\)[[:space:]]*aflag=\(--auto low\)' "$SRC" && ok "droid auto tier -> --auto low (read-only, permissioned)" || bad "droid auto tier is not --auto low"
# scope the negative to delegate_droid's body (the gemini/agy lane legitimately has an empty auto flag)
droid_body="$(awk '/^delegate_droid\(\)/{p=1} p{print} p&&/^}/{exit}' "$SRC")"
printf '%s' "$droid_body" | grep -qE 'auto\)[[:space:]]*aflag=\(\)' && bad "droid auto tier still empty-flagged (under-permissioned)" || ok "droid auto tier no longer empty-flagged"

# ---- bug 1 (precise): _devin_quota_refusal detects a paid-balance/ACU refusal, ignores unrelated ----
# The 0.6.2 hint was hedged ("if that was a quota refusal"). Now Devin's stderr is captured and matched,
# so a real quota/ACU/billing refusal of a FREE model is stated definitively and the actual line surfaced.
qf="$(mktemp)"
printf 'Error: 0%% remaining on your ACU balance. Upgrade your plan.\n' > "$qf"
_devin_quota_refusal "$qf" && ok "quota refusal detected (0%%/ACU/upgrade)" || bad "quota refusal missed"
[ -n "$(_devin_quota_refusal_line "$qf")" ] && ok "actual refusal line is surfaced (self-resolving telemetry)" || bad "refusal line not surfaced"
# canonical payment/quota wordings must ALL match (focused-torture F1: the bare list missed these)
_qmatch=1
for _s in "insufficient credits remaining" "rate limit exceeded (429)" "Monthly credit limit reached" \
          "Payment required" "402 Payment Required" "subscription expired" "usage cap exceeded"; do
  printf '%s\n' "$_s" > "$qf"; _devin_quota_refusal "$qf" || { _qmatch=0; echo "  (missed: $_s)"; }
done
[ "$_qmatch" = 1 ] && ok "all canonical payment/quota refusals match (402/payment/subscription/credit limit/usage cap)" || bad "a canonical quota refusal is missed"
# benign/unrelated stderr must NOT match (focused-torture F2: context-anchoring killed the bare-term FPs)
_qfp=0
for _s in "connection reset by peer" "TypeError: Cannot read property quota of undefined" \
          "billing address updated successfully" "exhausted all retry attempts" "ACU is not a recognized flag"; do
  printf '%s\n' "$_s" > "$qf"; _devin_quota_refusal "$qf" && { _qfp=1; echo "  (false-positive: $_s)"; }
done
[ "$_qfp" = 0 ] && ok "no false-positive on benign stderr (incl. 'exhausted all retry attempts')" || bad "a benign line was mislabeled a quota refusal"
: > "$qf"; _devin_quota_refusal "$qf" && bad "empty stderr matched" || ok "empty stderr -> no match (nothing to claim)"
# F3: the surfaced telemetry line must be ANSI-stripped so it is clean to paste into the regex
printf '\033[31mError: billing limit reached\033[0m\n' > "$qf"
[ "$(_devin_quota_refusal_line "$qf")" = "Error: billing limit reached" ] && ok "surfaced refusal line is ANSI-stripped" || bad "ANSI codes leak into the surfaced line"
rm -f "$qf"
# stderr capture must be hoisted so BOTH the sandbox and non-sandbox devin runs feed the quota detector
# (the non-sandbox path used to discard stderr, hiding the quota signal). The `: > "$_dverr"` init + a
# single teed devin invocation is the unified-capture marker.
grep -qF ': > "$_dverr"' "$SRC" && grep -qF 'tee "$_dverr"' "$SRC" && ok "devin stderr capture unified (quota signal visible on both paths)" || bad "devin stderr capture not unified"

echo "----"
echo "tool-bugs-062: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
