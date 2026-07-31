#!/usr/bin/env bash
# Tests the truthful lane-accounting: _effective_lane mapping + cmd_tab three-way FREE/PLAN/CASH
# bucket. Sources the main script with the `main "$@"` dispatcher stripped (side-effect-free).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN="$HERE/../outsourcerer.sh"
[ -f "$MAIN" ] || { echo "FAIL: main script not found at $MAIN" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

# BSD/macOS mktemp: template must END in X's (no trailing suffix).
TMP="$(mktemp "${TMPDIR:-/tmp}/osrc_acct.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
sed '/^[[:space:]]*main "\$@"[[:space:]]*$/d' "$MAIN" > "$TMP"
# shellcheck disable=SC1090
set +e; source "$TMP"; set -e

fail=0
ck() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "PASS: $1 -> '$2'"; else echo "FAIL: $1 -> '$2' (expected '$3')"; fail=1; fi
}

# --- A. _effective_lane: native lanes fixed; open-weight follows the transport provider ---
ck "_effective_lane gm devin"    "$(_effective_lane gm devin)"    gm
ck "_effective_lane cx codex"    "$(_effective_lane cx codex)"    cx
ck "_effective_lane cc devin"    "$(_effective_lane cc devin)"    cc
ck "_effective_lane local devin" "$(_effective_lane local devin)" local
ck "_effective_lane or devin"    "$(_effective_lane or devin)"    dv
ck "_effective_lane or cc"       "$(_effective_lane or cc)"       or
ck "_effective_lane or codex"    "$(_effective_lane or codex)"    or
ck "_effective_lane '' devin"    "$(_effective_lane '' devin)"    dv
# Regression cases: the helper must MIRROR actual dispatch routing, not a provider-only guess.
ck "dv-pinned under cc (glm-5.2)"   "$(_effective_lane dv cc glm-5.2)"       dv     # Devin-pinned stays dv (regression guard)
ck "dv-pinned under codex"          "$(_effective_lane dv codex glm-5.2)"    dv
ck "--provider local beats native"  "$(_effective_lane cx local sol)"        local  # local wins over table cx
ck "ollama: prefix -> local"        "$(_effective_lane '' devin ollama:qwen)" local
ck "local: prefix -> local"         "$(_effective_lane '' cc local:foo)"     local
ck "open-weight glm via cc -> or"   "$(_effective_lane or cc glm)"           or
ck "open-weight glm via devin -> dv" "$(_effective_lane or devin glm)"       dv
# Additional case: implicit model (no -m, arg4=0) follows the PROVIDER default, not glm-5.2's dv;
# and the lms: prefix is local.
ck "implicit default + cc -> or"    "$(_effective_lane dv cc glm-5.2 0)"     or     # bare --provider cc run
ck "implicit default + codex -> or" "$(_effective_lane dv codex glm-5.2 0)"  or
ck "implicit default + devin -> dv" "$(_effective_lane dv devin glm-5.2 0)"  dv
ck "explicit glm-5.2 + cc stays dv" "$(_effective_lane dv cc glm-5.2 1)"     dv     # explicit Devin-pinned unchanged
ck "lms: prefix -> local"           "$(_effective_lane '' cc lms:qwen)"      local

# --- B. cmd_tab three-way bucket. Extract the live `def bucket:` from the script so the test
#        can never drift from the real code (addresses the earlier "hand-copied classifier" finding). ---
# Extract from `def cashnum:` (bucket depends on it) through bucket's closing `else "cash" end;`.
BUCKET_DEF="$(awk '/def cashnum:/{f=1} f{print} /else "cash" end;/{if(f)exit}' "$MAIN")"
[ -n "$BUCKET_DEF" ] || { echo "FAIL: could not extract 'def bucket' from script" >&2; exit 1; }
bkt() { printf '%s' "$1" | jq -r "$BUCKET_DEF (bucket)"; }
ck "bucket {lane:local}"             "$(bkt '{"lane":"local"}')"            free
ck "bucket {lane:gm}"                "$(bkt '{"lane":"gm"}')"               plan
ck "bucket {lane:cx}"                "$(bkt '{"lane":"cx"}')"               plan
ck "bucket {provider:codex-native}"  "$(bkt '{"provider":"codex-native"}')" plan
ck "bucket {provider:local}"         "$(bkt '{"provider":"local"}')"        free
ck "bucket {lane:or,cost:0.01}"      "$(bkt '{"lane":"or","cost_usd":"0.01"}')" cash
ck "bucket {lane:cursor}"            "$(bkt '{"lane":"cursor"}')"          plan
ck "bucket {lane:droid}"             "$(bkt '{"lane":"droid"}')"           cash
ck "bucket {lane:hermes}"            "$(bkt '{"lane":"hermes"}')"          cash
ck "bucket {lane:warp}"              "$(bkt '{"lane":"warp"}')"            cash
# plan-bucket: devin (dv) is a SUBSCRIPTION/plan lane (Devin Pro): $0 cash but spends plan capacity.
# It must bucket as PLAN, not cash.
ck "bucket {lane:dv} -> plan (plan-lane)" "$(bkt '{"lane":"dv"}')"               plan
ck "bucket {lane:dv,cost:0.000000}"  "$(bkt '{"lane":"dv","cost_usd":"0.000000"}')" plan
# a NONZERO cost on a dv row = pay-per-use devin = CASH, not plan (cost-axis guard).
ck "bucket {lane:dv,cost:0.05} -> cash" "$(bkt '{"lane":"dv","cost_usd":"0.050000"}')" cash
ck "bucket {lane:dv,cost:~0.05} -> cash" "$(bkt '{"lane":"dv","cost_usd":"~0.050000"}')" cash
ck "bucket {provider:openrouter}"    "$(bkt '{"provider":"openrouter"}')"   cash

# --- C. cash-accounting: an UNMEASURED cash OpenRouter run (empty cost_usd) is still a CASH run and must be
#        counted as est-only, NOT dropped and NOT reported as "$0 measured". Prove via the real
#        cmd_tab summary output over a crafted ledger. ---
LED="$(mktemp "${TMPDIR:-/tmp}/osrc_led.XXXXXX")"; trap 'rm -f "$TMP" "$LED"' EXIT
{
  printf '%s\n' '{"ts":"t","provider":"codex","model":"glm","tier":"capable","verb":"run","in_tokens":10,"cost_usd":"","task_hash":"1","lane":"or"}'
  printf '%s\n' '{"ts":"t","provider":"codex","model":"glm","tier":"capable","verb":"run","in_tokens":10,"cost_usd":"0.002000","task_hash":"2","lane":"or"}'
  printf '%s\n' '{"ts":"t","provider":"devin","model":"glm-5.2","tier":"capable","verb":"run","in_tokens":10,"cost_usd":"0.000000","task_hash":"3","lane":"dv"}'
} > "$LED"
TAB_OUT="$(OSRC_LEDGER="$LED" cmd_tab 2>/dev/null)"
# unmeasured cash run counted (1 run), NOT folded into a false "$0 measured"
echo "$TAB_OUT" | grep -qE 'cash lanes, cost not captured[[:space:]]*:[[:space:]]*1 run' \
  && echo "PASS: cash-accounting unmeasured cash run counted as cost-not-captured (1)" \
  || { echo "FAIL: cash-accounting unmeasured cash run not counted"; echo "$TAB_OUT"; fail=1; }
# measured cash is the real $0.002, not inflated by the unmeasured or the devin $0
echo "$TAB_OUT" | grep -qE 'cash billed \(measured\)[[:space:]]*:[[:space:]]*\$0.002' \
  && echo "PASS: cash-accounting measured cash = \$0.002 (devin \$0 not counted as cash)" \
  || { echo "FAIL: cash-accounting measured-cash line wrong"; echo "$TAB_OUT"; fail=1; }
# Devin gets its named plan-limit disclosure, not a generic free/cash label.
echo "$TAB_OUT" | grep -qF 'Devin: 1 run(s), $0 cash, spends your Devin plan limits' \
  && echo "PASS: plan-bucket Devin run has named plan-limit disclosure" \
  || { echo "FAIL: plan-bucket Devin disclosure missing"; echo "$TAB_OUT"; fail=1; }

# --- D. a PAY-PER-USE devin row (nonzero cost on lane=dv) must count as CASH, not plan. ---
LED2="$(mktemp "${TMPDIR:-/tmp}/osrc_led2.XXXXXX")"
printf '%s\n' '{"ts":"t","provider":"devin","model":"glm-5.2","verb":"run","cost_usd":"0.050000","lane":"dv"}' > "$LED2"
TAB2="$(OSRC_LEDGER="$LED2" cmd_tab 2>/dev/null)"
echo "$TAB2" | grep -qE 'cash billed \(measured\)[[:space:]]*:[[:space:]]*\$0.05' \
  && echo "PASS: pay-per-use devin (\$0.05) counted as CASH, not hidden in plan" \
  || { echo "FAIL: paid devin not counted as cash"; echo "$TAB2"; fail=1; }
rm -f "$LED2"

# --- E. a single malformed/interleaved ledger line must NOT blank the whole Tab;
#        the valid rows still tally and a parse-error message must NOT appear. ---
LED3="$(mktemp "${TMPDIR:-/tmp}/osrc_led3.XXXXXX")"
{ printf '%s\n' '{"ts":"t","provider":"codex","model":"glm","verb":"run","cost_usd":"0.002000","lane":"or"}'
  printf '%s\n' 'THIS IS NOT JSON — interleaved garbage from a concurrent append'
  printf '%s\n' '{"ts":"t","provider":"devin","model":"glm-5.2","verb":"run","cost_usd":"0.000000","lane":"dv"}'; } > "$LED3"
TAB3="$(OSRC_LEDGER="$LED3" cmd_tab 2>/dev/null)"
echo "$TAB3" | grep -q '(ledger parse error)' \
  && { echo "FAIL: one bad line blanked the whole Tab"; echo "$TAB3"; fail=1; } \
  || echo "PASS: malformed line did not blank the Tab"
echo "$TAB3" | grep -qE 'cash billed \(measured\)[[:space:]]*:[[:space:]]*\$0.002' \
  && echo "PASS: valid rows still tallied around the bad line" \
  || { echo "FAIL: valid rows lost"; echo "$TAB3"; fail=1; }
rm -f "$LED3"

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL" >&2; exit 1; fi
echo "RESULT: PASS (all lane-accounting checks passed)"
