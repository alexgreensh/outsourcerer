#!/usr/bin/env bash
# test_devin_plan_quota.sh — Devin's PLAN-INCLUDED daily/weekly quota is a real, shared, exhaustible
# bucket (glm/swe/kimi/deepseek draw on ONE pool on Pro), distinct from the paid ACU balance that
# _DEVIN_QUOTA_RE models. Pins: (a) the plan-quota matcher fires on daily/weekly plan wording and NOT
# on a bare ACU 402 / rate-limit / unrelated prose; (b) the reset-phrase parser returns Devin's stated
# reset in seconds for the shapes Devin prints and stays SILENT (empty) on garbage, never a wrong
# number; (c) a plan exhaustion takes the whole dv lane down for Devin's stated window with a recorded
# reason, and every fallback the code prints points OFF Devin (OpenRouter / native), never at another
# Devin plan model — the 2026-09-15 incident was exactly that dead-end advice.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"; export HOME="$TMP"
cleanup() { rm -rf "$TMP"; }; trap cleanup EXIT
. "$SRC" >/dev/null 2>&1

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

FX="$TMP/fx"; mkdir -p "$FX"
printf 'Error: Your daily usage quota has been exhausted. It resets in 11h26m. See https://app.devin.ai/settings/usage\n' > "$FX/daily"
printf '\033[31mError:\033[0m weekly usage quota exhausted, resets at 2026-12-01 00:00 UTC.\n' > "$FX/weekly"
printf 'Daily quota reached\n' > "$FX/daily-short"
printf 'Error: 402 Payment Required — 0%% remaining ACU balance\n' > "$FX/acu-402"
printf 'Error: rate limit exceeded, retry later\n' > "$FX/rate-limit"
printf 'Error: Connection error\nexhausted all retry attempts\n' > "$FX/unrelated"
# false-match guard: "daily quota" and "exhausted" in the SAME sentence but ~22 chars apart,
# describing something else. The tight {0,16} gap in _DEVIN_PLAN_QUOTA_RE must NOT read this as a refusal.
printf 'Note: your daily quota is fine, but the disk exhausted its space.\n' > "$FX/false-gap"
: > "$FX/empty"

# === (a) matcher: plan wording yes, ACU / unrelated no ===========================================
for f in daily weekly daily-short; do
  _devin_plan_quota_exhausted "$FX/$f" && ok "plan matcher: '$f' fixture is a plan-quota exhaustion" \
    || bad "plan matcher: '$f' fixture NOT recognized as plan-quota exhaustion"
done
for f in acu-402 rate-limit unrelated false-gap empty; do
  _devin_plan_quota_exhausted "$FX/$f" && bad "plan matcher: '$f' fixture wrongly read as plan-quota exhaustion" \
    || ok "plan matcher: '$f' fixture is NOT plan-quota"
done
# The two families are distinct: the ACU matcher still owns 402/rate-limit, and the daily wording
# ALSO trips the ACU family — which is why the plan check must run first (asserted structurally below).
_devin_quota_refusal "$FX/acu-402"   && ok "ACU matcher: 402 fixture is an ACU refusal"        || bad "ACU matcher: lost the 402 fixture"
_devin_quota_refusal "$FX/rate-limit" && ok "ACU matcher: rate-limit fixture is an ACU refusal" || bad "ACU matcher: lost the rate-limit fixture"
_devin_quota_refusal "$FX/unrelated" && bad "ACU matcher: unrelated prose read as ACU refusal" || ok "ACU matcher: unrelated prose is not a refusal"
_l="$(_devin_plan_quota_line "$FX/weekly")"
case "$_l" in *$'\033'*) bad "plan line: ANSI not stripped" ;; "Error: weekly usage quota"*) ok "plan line: Devin's wording surfaced, ANSI stripped" ;; *) bad "plan line: unexpected '$_l'" ;; esac
[ "$(_devin_plan_quota_reset_phrase "$FX/daily")" = "resets in 11h26m" ] \
  && ok "reset phrase: extracted 'resets in 11h26m'" || bad "reset phrase: got '$(_devin_plan_quota_reset_phrase "$FX/daily")'"
[ -z "$(_devin_plan_quota_reset_phrase "$FX/acu-402")" ] && ok "reset phrase: empty when Devin gave none" || bad "reset phrase: invented one for the 402 fixture"

# === (b) reset parser: Devin's stated time or nothing ============================================
rs() { # <phrase> <expected-secs|EMPTY> <label> [tolerance]
  local got; got="$(_devin_plan_quota_reset_secs "$1")"
  if [ "$2" = "EMPTY" ]; then
    [ -z "$got" ] && ok "reset secs: $3 -> empty (no wrong number)" || bad "reset secs: $3 -> '$got' (must be empty)"
  else
    case "$got" in ''|*[!0-9]*) bad "reset secs: $3 -> '$got' (want ~$2)"; return ;; esac
    local d=$(( got - $2 )); [ "$d" -lt 0 ] && d=$(( -d ))
    [ "$d" -le "${4:-0}" ] && ok "reset secs: $3 -> $got" || bad "reset secs: $3 -> $got (want $2 ±${4:-0})"
  fi
}
rs "resets in 11h26m"           41160 "11h26m"
rs "resets in 11h 26m"          41160 "11h 26m (spaced)"
rs "resets in 45 min"           2700  "45 min"
rs "resets in 2 hours 5 minutes" 7500 "2 hours 5 minutes"
rs "resets in 3 days"           259200 "3 days"
rs "resets in 11:26:00"         41160 "11:26:00 clock-style duration"
# "at 09:00 UTC" = next 09:00 UTC from now: compute the expectation the same way a human would.
_now=$(date +%s); _ds=$(( _now - _now % 86400 )); _t=$(( _ds + 9*3600 )); [ "$_t" -le "$_now" ] && _t=$(( _t + 86400 ))
rs "resets at 09:00 UTC"        $(( _t - _now )) "at 09:00 UTC (next occurrence)" 5
rs "resets at soon"             EMPTY "unparseable clock"
rs "resets in a while"          EMPTY "unparseable duration"
rs "resets in 40 days"          EMPTY "out-of-range duration (>8d) rejected"
rs "garbage"                    EMPTY "garbage"
rs ""                           EMPTY "empty"

# === (c) exhaustion -> dv lane down for Devin's window, reason recorded, advice OFF Devin ============
_quota_note_refusal() { :; }   # ledger reconcile is a declared-cap no-op; keep this test about the lane
# The block now PROBES a sibling free model before deciding (probe-then-decide, see
# test_devin_plan_quota_probe.sh). This section pins the CONFIRMED path, so the fake devin on PATH
# refuses every model with the daily wording; it also keeps the real devin CLI out of the test.
FB="$TMP/fakebin"; mkdir -p "$FB"
printf '#!/usr/bin/env bash\nprintf "Error: Your daily usage quota has been exhausted. It resets in 11h26m.\\n" >&2; exit 1\n' > "$FB/devin"
chmod +x "$FB/devin"; export PATH="$FB:$PATH"
_lane_down_clear dv
_before=$(date +%s)
_out="$(_devin_plan_quota_block "$FX/daily" glm-5.2 'not just "glm-5.2"' 'Switch lanes OFF Devin: --provider cc -m glm (OpenRouter) or a native lane.' 2>&1)"
_after=$(date +%s)
_lane_down_active dv && ok "block: dv lane marked DOWN after a daily exhaustion" || bad "block: dv lane NOT down"
[ "$(_lane_down_reason dv)" = "plan quota exhausted" ] && ok "block: down-reason recorded" || bad "block: reason '$(_lane_down_reason dv)'"
_ev="$(_posture_get dv down-evidence 2>/dev/null)"
printf '%s' "$_ev" | grep -q 'daily usage quota has been exhausted' && ok "block: down-evidence keeps the refusal wording" || bad "block: down-evidence '$_ev'"
printf '%s' "$_ev" | grep -q ' | probe: ' && ok "block: down-evidence keeps the probe wording too" || bad "block: down-evidence missing probe half '$_ev'"
# The mark lands somewhere inside the call, so until-before = reset+slack + (mark-before): the floor
# is Devin's stated reset plus the product's 60s slack, and the ceiling adds only the elapsed time the
# call measurably took, never a magic headroom a legitimate probe could overflow.
_until="$(_posture_get dv down 2>/dev/null)"; _ttl=$(( ${_until:-0} - _before ))
[ "$_ttl" -ge 41220 ] && [ "$_ttl" -le $(( 41220 + _after - _before )) ] && ok "block: lane-down window = Devin's 11h26m (+slack), got ${_ttl}s" || bad "block: TTL ${_ttl}s is not Devin's stated reset"
printf '%s' "$_out" | grep -q 'shared DAILY plan quota is exhausted' && ok "block: says the SHARED DAILY bucket is exhausted" || bad "block: missing honest daily wording"
printf '%s' "$_out" | grep -q 'blocks ALL plan-included models' && ok "block: says it blocks ALL plan-included models" || bad "block: missing all-models wording"
printf '%s' "$_out" | grep -q 'Devin says it resets in 11h26m' && ok "block: quotes Devin's reset" || bad "block: reset not quoted"
printf '%s' "$_out" | grep -qi 'estimate' && bad "block: labeled an estimate although Devin's reset parsed" || ok "block: no estimate language when the reset parsed"
printf '%s' "$_out" | grep -q 'mis-gate' && bad "block: still prints the ACU mis-gate wording" || ok "block: ACU mis-gate wording absent"
printf '%s' "$_out" | grep -q 'Switch lanes OFF Devin' && ok "block: caller's OFF-Devin advice printed" || bad "block: advice missing"
# The probe lines legitimately NAME the sibling model they asked (that is the verification, not a
# recommendation); every other line must still steer clear of Devin plan models.
printf '%s' "$_out" | grep -v '\] probe:' | grep -qE 'swe-1-7|glm-5-2\)|Retry on one of those plan-included' && bad "block: recommends another Devin plan model" || ok "block: no Devin plan model recommended"
# Weekly + unparseable reset -> lane still down, but the window is a LABELED estimate.
_lane_down_clear dv
printf 'Error: weekly usage quota exhausted, resets at soon.\n' > "$FX/weekly-vague"
_before=$(date +%s)
_out="$(OSRC_DEVIN_PLAN_DOWN_TTL=1234 _devin_plan_quota_block "$FX/weekly-vague" swe-1.7 'scope' 'advice' 2>&1)"
_after=$(date +%s)
printf '%s' "$_out" | grep -q 'shared WEEKLY plan quota' && ok "block: WEEKLY period read from Devin's line" || bad "block: weekly not detected"
printf '%s' "$_out" | grep -q 'ESTIMATE' && ok "block: unparseable reset -> window labeled an ESTIMATE" || bad "block: estimate label missing"
printf '%s' "$_out" | grep -q 'app.devin.ai/settings/usage' && ok "block: points at the dashboard when no reset parsed" || bad "block: dashboard URL missing"
_until="$(_posture_get dv down 2>/dev/null)"; _ttl=$(( ${_until:-0} - _before ))
[ "$_ttl" -ge 1234 ] && [ "$_ttl" -le $(( 1234 + _after - _before )) ] && ok "block: fallback TTL honors OSRC_DEVIN_PLAN_DOWN_TTL (${_ttl}s)" || bad "block: fallback TTL ${_ttl}s"
_lane_down_clear dv
[ -e "$OSRC_POSTURE_DIR/dv.down-reason" ] && bad "clear: reason file survived _lane_down_clear" || ok "clear: reason file removed with the marker"
[ -e "$OSRC_POSTURE_DIR/dv.down-evidence" ] && bad "clear: evidence file survived _lane_down_clear" || ok "clear: evidence file removed with the marker"

# Structural: the delegate failure branches check the PLAN matcher before the ACU matcher (the daily
# wording also trips the ACU family), and the plan-branch advice never names a Devin plan model.
_free_branch="$(awk '/if \[ -n "\$_dverr" \] && _devin_plan_quota_exhausted "\$_dverr"; then/{f=1} f{print} /_devin_quota_refusal "\$_dverr"; then/{if(f){exit}}' "$SRC")"
[ -n "$_free_branch" ] && ok "structure: free-tier branch checks plan quota BEFORE the ACU mis-gate wording" || bad "structure: plan check not ahead of the ACU check in the free-tier branch"
grep -q 'if _devin_plan_quota_exhausted "$_dverr"; then' "$SRC" && ok "structure: paid branch gates on which signature matched" || bad "structure: paid branch does not gate on the plan matcher"
_adv="$(grep -E '_pq_off=|"Switch lanes OFF Devin: OpenRouter' "$SRC")"
printf '%s' "$_adv" | grep -q -- '--provider cc' && ok "structure: plan-quota advice routes to OpenRouter via --provider cc" || bad "structure: advice lacks the OpenRouter hop"
printf '%s' "$_adv" | grep -qE 'swe-1-7|kimi-k3|-m swe|-m kimi' && bad "structure: plan-quota advice names a Devin plan model" || ok "structure: plan-quota advice names no Devin plan model"
grep -q 'Check Devin.*own plan with: devin usage' "$SRC" && bad "hint: dead 'devin usage' command still advertised" || ok "hint: no dead 'devin usage' advice remains"
grep -q 'https://app.devin.ai/settings/usage' "$SRC" && ok "hint: dashboard URL is the pointer" || bad "hint: dashboard URL missing"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
