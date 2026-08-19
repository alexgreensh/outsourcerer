#!/usr/bin/env bash
# test_quota.sh — per-model daily quota: counter-from-ledger, caps config, the gate, and routing.
#
# The feature: outsourcerer knows each free model's DAILY request cap, counts usage from ledger.jsonl
# (no separate counter file), and skips an at-cap model BEFORE dispatch so work spreads across free
# tiers and only falls through to paid when the frees are spent. Absent config = unlimited = today's
# behavior byte-for-byte. Design: PROJECTS/outsourcerer-quota/PLAN.md.
#
# Layers: UNIT (helpers, sourced, fixtured ledger — fast/deterministic) + INTEGRATION (real preflight
# proving the route gate refuses a pinned at-cap model and passes an under-cap one). SKIPs without jq.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
have jq || { echo "SKIP: jq required"; echo "RESULT: 0 passed, 0 failed"; exit 0; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-quota.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home"; export OSRC_SOURCED=1; mkdir -p "$OSRC_HOME"
SRC_ONLY="$TMP/src.sh"; sed '/^[[:space:]]*main "\$@"[[:space:]]*$/d' "$SRC" > "$SRC_ONLY"
# shellcheck disable=SC1090
. "$SRC_ONLY" >/dev/null 2>&1
type -t _quota_gate >/dev/null || { echo "FAIL: _quota_gate not defined (feature missing?)"; exit 1; }

# ---------------------------------------------------------------------------------------------------
# UNIT: countable-verb predicate + the taxonomy-rot canary
# ---------------------------------------------------------------------------------------------------
_quota_countable run      && ok "_quota_countable: run counts"      || bad "run should count"
_quota_countable edit     && ok "_quota_countable: edit counts"     || bad "edit should count"
_quota_countable fallback && bad "fallback must NOT count"          || ok "_quota_countable: fallback excluded"
# Canary: the deny-list is the ONE source of truth. If someone adds/removes a non-counting verb, this
# trips so the change is deliberate and the counting jq (which reads the same var) is reconsidered.
[ "$OSRC_QUOTA_NONCOUNT_VERBS" = "fallback" ] \
  && ok "non-count verb list is exactly {fallback} (taxonomy canary)" \
  || bad "non-count verb taxonomy changed to '{$OSRC_QUOTA_NONCOUNT_VERBS}' — update the counting jq + this canary deliberately"

# ---------------------------------------------------------------------------------------------------
# UNIT: caps config lookup (lane:model, bare model, none)
# ---------------------------------------------------------------------------------------------------
cat > "$OSRC_HOME/quota.json" <<JSON
{"models":{"droid:kimi-k3":{"per_day":3,"reset":"utc"},"or:deepseek/deepseek-v4-pro":{"per_day":5,"reset":"utc"},"qwen-max":{"per_day":7,"reset":"utc"}}}
JSON
[ "$(_quota_cap droid kimi-k3)" = "3 utc" ]                 && ok "cap: lane:model key resolves" || bad "lane:model cap wrong: $(_quota_cap droid kimi-k3)"
[ "$(_quota_cap or 'deepseek/deepseek-v4-pro')" = "5 utc" ] && ok "cap: key with / and : resolves" || bad "slashed key cap wrong"
[ "$(_quota_cap warp qwen-max)" = "7 utc" ]                 && ok "cap: bare-model key applies on any lane" || bad "bare-model cap wrong"
_quota_cap droid never-declared && bad "undeclared model should have no cap" || ok "cap: undeclared model -> rc1 (unlimited)"

# ---------------------------------------------------------------------------------------------------
# UNIT: used-today counting from the ledger (fixture)
# ---------------------------------------------------------------------------------------------------
export OSRC_LEDGER_FORCE=1
add_row() { record_ledger "$1" "$2" capable "$3" "$4" "0.0" "$1"; }   # <lane> <model> <verb> <task>
add_row droid kimi-k3 run "a"; add_row droid kimi-k3 edit "b"; add_row droid kimi-k3 run "c"
add_row droid kimi-k3 fallback "x"                       # must NOT count
add_row warp  kimi-k3 run "d"                            # different lane -> separate pool
[ "$(_quota_used_today droid kimi-k3 utc)" = "3" ] && ok "used_today counts 3 countable droid runs" || bad "used_today=$(_quota_used_today droid kimi-k3 utc) (want 3)"
[ "$(_quota_used_today warp  kimi-k3 utc)" = "1" ] && ok "used_today: warp pool separate from droid" || bad "warp pool count wrong"

# A row dated YESTERDAY (epoch before today's UTC start) must not count.
yday=$(( $(date +%s) - 90000 ))
printf '{"ts":"2000-01-01T00:00:00","epoch":%s,"provider":"droid","model":"kimi-k3","verb":"run","in_tokens":1,"cost_usd":"0","task_hash":"1","run_id":"y","task_class":"code","repo_key":"0","lane":"droid"}\n' "$yday" >> "$OSRC_HOME/ledger.jsonl"
[ "$(_quota_used_today droid kimi-k3 utc)" = "3" ] && ok "yesterday's row excluded by epoch>=day-start" || bad "yesterday counted: $(_quota_used_today droid kimi-k3 utc)"

# A legacy row (NO epoch) whose ts-date is today must still count (the <=24h upgrade window).
today="$(date +%Y-%m-%d)"
printf '{"ts":"%sT12:00:00","provider":"droid","model":"kimi-k3","verb":"run","in_tokens":1,"cost_usd":"0","task_hash":"2","run_id":"L","task_class":"code","repo_key":"0","lane":"droid"}\n' "$today" >> "$OSRC_HOME/ledger.jsonl"
[ "$(_quota_used_today droid kimi-k3 utc)" = "4" ] && ok "legacy row (no epoch) with today's ts counts" || bad "legacy row not counted: $(_quota_used_today droid kimi-k3 utc)"

# ---------------------------------------------------------------------------------------------------
# UNIT: the gate (no cap / under / at / marker override / marker-on-uncapped ignored)
# ---------------------------------------------------------------------------------------------------
_quota_gate droid never-declared && ok "gate: undeclared model -> rc0 (unlimited default)" || bad "undeclared model gated"
# droid:kimi-k3 cap=3 but used=4 -> at cap
_quota_gate droid kimi-k3 && bad "gate: 4/3 should be at cap (rc1)" || ok "gate: over cap -> rc1"
# warp:kimi-k3 uses bare... no, warp:kimi-k3 has no key and no bare kimi-k3 -> unlimited
_quota_gate warp kimi-k3 && ok "gate: warp kimi-k3 (no cap) -> rc0" || bad "warp kimi-k3 wrongly gated"
# qwen-max bare cap 7, used 0 -> under
_quota_gate warp qwen-max && ok "gate: qwen-max 0/7 -> rc0 (under)" || bad "qwen-max under cap gated"

# Marker forces at-cap on a CAPPED model even with headroom; expires -> purged -> rc0.
_quota_note_refusal warp qwen-max utc
_quota_gate warp qwen-max && bad "gate: active marker should force rc1" || ok "gate: exhausted marker overrides under-cap count"
# Marker on an UNCAPPED model is ignored (cap-first): write a stale posture file, gate must still rc0.
_posture_set droid "quota-never-declared" "$(( $(date +%s) + 100000 ))"
_quota_gate droid never-declared && ok "gate: marker on uncapped model ignored (rc0)" || bad "marker wrongly blocked an uncapped model"
# Expired marker self-purges.
_posture_set warp "quota-qwen-max" "$(( $(date +%s) - 10 ))"
_quota_gate warp qwen-max && ok "gate: expired marker purged -> rc0" || bad "expired marker still blocking"

# ---------------------------------------------------------------------------------------------------
# UNIT: day-boundary helper (utc vs local) and record_ledger epoch field
# ---------------------------------------------------------------------------------------------------
now="$(date +%s)"; us="$(_quota_day_start utc)"; ls="$(_quota_day_start local)"
{ [ "$us" -le "$now" ] && [ $(( now - us )) -lt 86400 ]; } && ok "day_start utc within today" || bad "utc day_start out of range"
{ [ "$ls" -le "$now" ] && [ $(( now - ls )) -lt 86400 ]; } && ok "day_start local within today" || bad "local day_start out of range"
# Check a row WRITTEN by record_ledger (the first fixture row), not the hand-appended legacy rows.
first="$(head -n1 "$OSRC_HOME/ledger.jsonl")"; echo "$first" | jq -e 'has("epoch") and (.epoch|type=="number")' >/dev/null 2>&1 \
  && ok "record_ledger emits a numeric epoch field" || bad "record_ledger missing epoch"

# ---------------------------------------------------------------------------------------------------
# UNIT: limits subcommand (set / status / clear) round-trips quota.json
# ---------------------------------------------------------------------------------------------------
# OSRC_SOURCED must be UNSET for these child runs (we exported it =1 to source functions; a child with
# it set skips main() and never runs the subcommand).
H2="$TMP/h2"; mkdir -p "$H2"
OSRC_HOME="$H2" OSRC_SOURCED= bash "$SRC" limits set droid kimi-k3 50/day >/dev/null 2>&1
OSRC_HOME="$H2" OSRC_SOURCED= bash "$SRC" limits set any deepseek-v4-pro 100 --reset local >/dev/null 2>&1
[ "$(jq -r '.models["droid:kimi-k3"].per_day' "$H2/quota.json")" = "50" ] && ok "limits set: lane:model written" || bad "limits set lane:model failed"
[ "$(jq -r '.models["deepseek-v4-pro"].reset' "$H2/quota.json")" = "local" ] && ok "limits set: bare-model + --reset local" || bad "limits set bare/reset failed"
# Capture-then-grep (never `| grep -q`): under `set -o pipefail`, grep -q closing the pipe early can
# SIGPIPE the upstream and flip the pipeline status — the same idiom the main script uses.
_st_out="$(OSRC_HOME="$H2" OSRC_SOURCED= bash "$SRC" limits status 2>&1)"
case "$_st_out" in *droid:kimi-k3*) ok "limits status lists caps" ;; *) bad "limits status missing entry: $_st_out" ;; esac
OSRC_HOME="$H2" OSRC_SOURCED= bash "$SRC" limits clear droid kimi-k3 >/dev/null 2>&1
jq -e '.models["droid:kimi-k3"]' "$H2/quota.json" >/dev/null 2>&1 && bad "limits clear left the entry" || ok "limits clear removes the entry"
_bad_out="$(OSRC_HOME="$H2" OSRC_SOURCED= bash "$SRC" limits set droid x abc 2>&1)"
case "$_bad_out" in *"must be a number"*) ok "limits set rejects non-numeric cap" ;; *) bad "bad cap not rejected: $_bad_out" ;; esac

# ---------------------------------------------------------------------------------------------------
# INTEGRATION: the route gate via a real preflight (fake droid so nothing dispatches)
# ---------------------------------------------------------------------------------------------------
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"; printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/droid"; chmod +x "$FAKEBIN/droid"
run_pf() { PATH="$FAKEBIN:$PATH" OSRC_HOME="$1" OSRC_SOURCED= OSRC_PREFLIGHT=1 OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 bash "$SRC" run --provider droid -m kimi-k3 "hi" 2>&1; }

# no quota.json -> normal routing (regression: default path untouched)
H3="$TMP/h3"; mkdir -p "$H3"
run_pf "$H3" | grep -q 'RESOLVED lane=droid' && ok "integration: no quota.json -> droid routes normally" || bad "no-config routing regressed"

# pinned model at cap -> refuse with the reset info (never a silent switch)
H4="$TMP/h4"; mkdir -p "$H4"; printf '{"models":{"droid:kimi-k3":{"per_day":1,"reset":"utc"}}}\n' > "$H4/quota.json"
OSRC_HOME="$H4" OSRC_LEDGER_FORCE=1 OSRC_SOURCED=1 bash -c ". \"$SRC\" >/dev/null 2>&1; record_ledger droid kimi-k3 capable run t 0.0 droid"
out="$(run_pf "$H4")"
case "$out" in *"pinned choice"*|*"at 1/1"*) ok "integration: pinned at-cap model refused with reset info" ;; *) bad "pinned at-cap not refused: $out" ;; esac

# under cap -> routes normally
H5="$TMP/h5"; mkdir -p "$H5"; printf '{"models":{"droid:kimi-k3":{"per_day":9,"reset":"utc"}}}\n' > "$H5/quota.json"
run_pf "$H5" | grep -q 'RESOLVED lane=droid' && ok "integration: under-cap model routes normally" || bad "under-cap routing broke"

# Pin-scanner parity: a `-m` after --no-advise or --provider= must still count as PINNED, so an at-cap
# pinned model REFUSES ("pinned choice") instead of silently hopping (torture HIGH: scanner divergence).
run_pf_flags() { local h="$1"; shift; PATH="$FAKEBIN:$PATH" OSRC_HOME="$h" OSRC_SOURCED= OSRC_PREFLIGHT=1 OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 bash "$SRC" run "$@" 2>&1; }
H10="$TMP/h10"; mkdir -p "$H10"; printf '{"models":{"droid:kimi-k3":{"per_day":1,"reset":"utc"}}}\n' > "$H10/quota.json"
OSRC_HOME="$H10" OSRC_LEDGER_FORCE=1 OSRC_SOURCED=1 bash -c ". \"$SRC\" >/dev/null 2>&1; record_ledger droid kimi-k3 capable run t 0.0 droid"
out="$(run_pf_flags "$H10" --no-advise --provider droid -m kimi-k3 "hi")"
case "$out" in *"pinned choice"*) ok "pin-scanner: -m after --no-advise still refuses at cap (pinned)" ;; *) bad "pin-scanner --no-advise divergence (silent hop): $out" ;; esac
out="$(run_pf_flags "$H10" --provider=droid -m kimi-k3 "hi")"
case "$out" in *"pinned choice"*) ok "pin-scanner: -m after --provider= still refuses at cap (pinned)" ;; *) bad "pin-scanner --provider= divergence (silent hop): $out" ;; esac

# ---------------------------------------------------------------------------------------------------
# REGRESSION: P2-1 natural provider name normalizes to the ledger code (cap actually fires)
# ---------------------------------------------------------------------------------------------------
H6="$TMP/h6"; mkdir -p "$H6"
OSRC_HOME="$H6" OSRC_SOURCED= bash "$SRC" limits set devin glm-5-2 1/day >/dev/null 2>&1
jq -e '.models["dv:glm-5-2"]' "$H6/quota.json" >/dev/null 2>&1 \
  && ok "P2-1: 'limits set devin ...' stores the normalized code key dv:glm-5-2" \
  || bad "P2-1: devin not normalized to dv (cap would silently never fire): $(jq -c .models "$H6/quota.json")"
# and the gate (disp=devin) now sees that cap
( export OSRC_HOME="$H6"; . "$SRC_ONLY" >/dev/null 2>&1
  OSRC_LEDGER_FORCE=1 record_ledger dv glm-5-2 capable run t 0.0 dv
  _quota_gate devin glm-5-2 ) && bad "P2-1: gate should see 1/1 dv:glm-5-2 as at-cap" || ok "P2-1: gate enforces the natural-name cap (rc1)"

# ---------------------------------------------------------------------------------------------------
# REGRESSION: P2-2 a torn ledger line is SKIPPED, not fail-open-to-zero
# ---------------------------------------------------------------------------------------------------
H7="$TMP/h7"; mkdir -p "$H7"
( export OSRC_HOME="$H7"; . "$SRC_ONLY" >/dev/null 2>&1
  OSRC_LEDGER_FORCE=1 record_ledger droid kimi-k3 capable run a 0.0 droid
  OSRC_LEDGER_FORCE=1 record_ledger droid kimi-k3 capable run b 0.0 droid )
printf '{"model":"kimi-k3","lane":"droid","ver\n' >> "$H7/ledger.jsonl"   # torn line
( export OSRC_HOME="$H7"; . "$SRC_ONLY" >/dev/null 2>&1
  u="$(_quota_used_today droid kimi-k3 utc)"; [ "$u" = "2" ] ) \
  && ok "P2-2: torn ledger line skipped; count stays 2 (not fail-open to 0)" \
  || bad "P2-2: torn line broke the count (fail-open)"

# ---------------------------------------------------------------------------------------------------
# REGRESSION: F1 float per_day must NOT fail open (floored to an integer, still enforces)
# ---------------------------------------------------------------------------------------------------
H8="$TMP/h8"; mkdir -p "$H8"
printf '{"models":{"droid:kimi-k3":{"per_day":1.5,"reset":"utc"}}}\n' > "$H8/quota.json"
( export OSRC_HOME="$H8"; . "$SRC_ONLY" >/dev/null 2>&1
  OSRC_LEDGER_FORCE=1 record_ledger droid kimi-k3 capable run a 0.0 droid
  OSRC_LEDGER_FORCE=1 record_ledger droid kimi-k3 capable run b 0.0 droid
  _quota_gate droid kimi-k3 ) && bad "F1: float cap 1.5 with 2 used should be at-cap (rc1)" || ok "F1: float per_day floored, gate still enforces (rc1)"

# ---------------------------------------------------------------------------------------------------
# REGRESSION: F2 a valid-JSON NON-OBJECT ledger line must be skipped, not abort the count to 0
# ---------------------------------------------------------------------------------------------------
H9="$TMP/h9"; mkdir -p "$H9"
( export OSRC_HOME="$H9"; . "$SRC_ONLY" >/dev/null 2>&1
  OSRC_LEDGER_FORCE=1 record_ledger droid kimi-k3 capable run a 0.0 droid
  OSRC_LEDGER_FORCE=1 record_ledger droid kimi-k3 capable run b 0.0 droid )
printf '[1,2,3]\n"a string"\n42\ntrue\n{"model":"kimi-k3","lane":"droid","ver\n' >> "$H9/ledger.jsonl"   # non-objects + torn line
( export OSRC_HOME="$H9"; . "$SRC_ONLY" >/dev/null 2>&1
  u="$(_quota_used_today droid kimi-k3 utc)"; [ "$u" = "2" ] ) \
  && ok "F2: non-object + torn ledger lines skipped; count stays 2 (not fail-open to 0)" \
  || bad "F2: non-object line aborted the count (fail-open)"

# ---------------------------------------------------------------------------------------------------
# REGRESSION: gemini gi/gm vehicle fold — a gemini cap (key gm:) must count gemini-cli rows (lane gi)
# ---------------------------------------------------------------------------------------------------
H11="$TMP/h11"; mkdir -p "$H11"
OSRC_HOME="$H11" OSRC_SOURCED= bash "$SRC" limits set gemini gemini-3-flash 1/day >/dev/null 2>&1
jq -e '.models["gm:gemini-3-flash"]' "$H11/quota.json" >/dev/null 2>&1 \
  && ok "gi/gm: 'limits set gemini' stores gm: key" || bad "gi/gm: gemini not normalized to gm"
( export OSRC_HOME="$H11"; . "$SRC_ONLY" >/dev/null 2>&1
  OSRC_LEDGER_FORCE=1 record_ledger gemini gemini-3-flash budget run t 0.0 gi   # gemini-cli vehicle -> lane gi
  [ "$(_quota_used_today gm gemini-3-flash utc)" = "1" ] ) \
  && ok "gi/gm: a lane=gi ledger row counts against the gm cap" || bad "gi/gm: gi row not counted under gm cap (cap silently never fires)"
( export OSRC_HOME="$H11"; . "$SRC_ONLY" >/dev/null 2>&1
  OSRC_LEDGER_FORCE=1 record_ledger gemini gemini-3-flash budget run t 0.0 gi
  _quota_gate gmnative gemini-3-flash ) && bad "gi/gm: gate should be at cap (1/1)" || ok "gi/gm: gate enforces the gemini cap across the gi vehicle (rc1)"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
