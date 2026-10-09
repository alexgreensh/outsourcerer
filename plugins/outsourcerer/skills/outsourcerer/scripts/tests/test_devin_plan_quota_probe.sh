#!/usr/bin/env bash
# test_devin_plan_quota_probe.sh — PROBE-THEN-DECIDE for a Devin plan-quota refusal (fixes the 0.12.3
# over-block). A daily/weekly-quota refusal from ONE model must not, on its own, take the whole dv lane
# down or forbid retrying the free models: _devin_plan_quota_block now sends ONE bounded request to a
# sibling free model (_lane_free_probe) and decides from the answer. Pins: (a) the probe primitive's
# three verdicts (answered / limit-refused / unreachable), its wall-clock bound, and the no-recipe rc;
# (b) a fake devin that refuses model X but ANSWERS the free probe -> lane NOT down, the free model is
# named as usable, a stale down marker is cleared; (c) the probe never re-asks the model that was just
# refused; (d) a fake devin that refuses the probe too -> lane DOWN for Devin's stated window with the
# recorded reason; (e) an unreachable probe -> only the short transport window, never the quota window;
# (f) the "do NOT retry them" wording is gone from every user-facing line.
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

_quota_note_refusal() { :; }   # declared-cap reconcile is a no-op here; keep this test about the lane

# --- fake devin on PATH -------------------------------------------------------------------------
# Refuses every model listed (one per line) in $FAKE_DEVIN_REFUSE with Devin's real daily-quota wording
# (exit 1); answers "pong" (exit 0) otherwise; sleeps $FAKE_DEVIN_SLEEP first when set. Every call is
# appended to $FAKE_DEVIN_LOG as the --model it was asked for, so the test can see WHAT was probed.
FB="$TMP/fakebin"; mkdir -p "$FB"
export FAKE_DEVIN_REFUSE="$TMP/refuse" FAKE_DEVIN_LOG="$TMP/devin-calls.log" FAKE_DEVIN_SLEEP=""
cat > "$FB/devin" <<'FAKE'
#!/usr/bin/env bash
m=""; while [ $# -gt 0 ]; do case "$1" in --model) m="$2"; shift ;; esac; shift; done
printf '%s\n' "$m" >> "$FAKE_DEVIN_LOG"
[ -n "${FAKE_DEVIN_SLEEP:-}" ] && sleep "$FAKE_DEVIN_SLEEP"
if [ -f "$FAKE_DEVIN_REFUSE" ] && grep -qx -- "$m" "$FAKE_DEVIN_REFUSE"; then
  printf 'Error: Your daily usage quota has been exhausted. It resets in 11h26m. See https://app.devin.ai/settings/usage\n' >&2
  exit 1
fi
printf 'pong\n'; exit 0
FAKE
chmod +x "$FB/devin"
export PATH="$FB:$PATH"
[ "$(command -v devin)" = "$FB/devin" ] && ok "fixture: fake devin is first on PATH" || bad "fixture: PATH resolves devin to $(command -v devin)"
refuse() { : > "$FAKE_DEVIN_REFUSE"; for m in "$@"; do printf '%s\n' "$m" >> "$FAKE_DEVIN_REFUSE"; done; : > "$FAKE_DEVIN_LOG"; }
calls() { cat "$FAKE_DEVIN_LOG" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
# The plan-quota-probe default alt is now discovered from the live catalog (a network refresh that
# would call the fake devin and pollute `calls`). This suite tests the plan-quota logic with the known
# swe-2 sibling, so pin the alt deterministically; the catalog-driven alt is covered by
# test_devin_catalog_free_tier.sh.
export OSRC_DEVIN_PROBE_MODEL_ALT=swe-2

FX="$TMP/fx"; mkdir -p "$FX"
printf 'Error: Your daily usage quota has been exhausted. It resets in 11h26m. See https://app.devin.ai/settings/usage\n' > "$FX/daily"

# === (a) _lane_free_probe primitive ===============================================================
refuse
[ "$(_lane_free_probe dv)" = "answered" ] && ok "probe: free model answers -> 'answered'" || bad "probe: answering fake devin -> '$(_lane_free_probe dv)'"
[ "$(calls)" = "glm-5-2" ] && ok "probe: default probe model is glm-5-2 (one call)" || bad "probe: calls were '$(calls)'"
refuse glm-5-2
[ "$(_lane_free_probe dv)" = "limit-refused" ] && ok "probe: daily-quota refusal -> 'limit-refused'" || bad "probe: refused fake devin -> '$(_lane_free_probe dv)'"
grep -q 'daily usage quota' "$(_lane_probe_file dv)" 2>/dev/null && ok "probe: captured output kept for quoting (PID-scoped file)" || bad "probe: $(_lane_probe_file dv) missing Devin's wording"
case "$(_lane_probe_file dv)" in *".lane-probe.dv.$$.out") ok "probe: capture file is PID-scoped (concurrent probes on one lane cannot clobber each other)" ;; *) bad "probe: capture path not PID-scoped: $(_lane_probe_file dv)" ;; esac
refuse
[ "$(_lane_free_probe dv swe-1-7)" = "answered" ] && ok "probe: explicit model argument honored" || bad "probe: explicit model verdict wrong"
[ "$(calls)" = "swe-1-7" ] && ok "probe: explicit model is what devin was asked for" || bad "probe: calls were '$(calls)'"
# Bounded: a devin that hangs longer than the cap must come back 'unreachable' within a few seconds.
refuse; _t0=$(date +%s)
_v="$(FAKE_DEVIN_SLEEP=20 OSRC_LANE_PROBE_SECS=1 _lane_free_probe dv)"; _dt=$(( $(date +%s) - _t0 ))
[ "$_v" = "unreachable" ] && ok "probe: hung devin -> 'unreachable'" || bad "probe: hung devin -> '$_v'"
[ "$_dt" -le 8 ] && ok "probe: bounded by OSRC_LANE_PROBE_SECS (returned in ${_dt}s)" || bad "probe: took ${_dt}s, not bounded"
# A non-limit failure is not a refusal.
_v="$(PATH="$TMP/nowhere" _lane_free_probe dv)"
[ "$_v" = "unreachable" ] && ok "probe: devin missing from PATH -> 'unreachable'" || bad "probe: missing devin -> '$_v'"
_v="$(_lane_free_probe or)"; _rc=$?
[ "$_v" = "unreachable" ] && [ "$_rc" -eq 2 ] && ok "probe: lane without a recipe -> 'unreachable' rc=2" || bad "probe: no-recipe lane -> '$_v' rc=$_rc"
_v="$(_lane_free_probe devin)"; [ "$_v" = "answered" ] && ok "probe: 'devin' folds to the dv lane" || bad "probe: 'devin' token -> '$_v'"

# === (b) refuses model X, free probe ANSWERS -> lane NOT down ====================================
refuse claude-opus-5
_lane_down_mark dv 3600 "plan quota exhausted"     # stale marker from an earlier blanket verdict
_out="$(_devin_plan_quota_block "$FX/daily" claude-opus-5 'including the free-tier ones you would otherwise fall back to (the probe was refused as well)' 'Switch lanes OFF Devin: --provider cc -m glm (OpenRouter) or a native lane.' 2>&1)"
_lane_down_active dv && bad "answered: dv lane marked DOWN although the free probe answered" || ok "answered: dv lane NOT down (free model still answers)"
[ -e "$OSRC_POSTURE_DIR/dv.down" ] && bad "answered: stale down marker survived an answering probe" || ok "answered: stale down marker cleared"
[ "$(calls)" = "glm-5-2" ] && ok "answered: exactly one bounded probe (glm-5-2) was sent" || bad "answered: devin calls were '$(calls)'"
printf '%s' "$_out" | grep -q 'Devin refused "claude-opus-5"' && ok "answered: names the refused model" || bad "answered: refused model not named"
printf '%s' "$_out" | grep -q 'NOT confirmed' && ok "answered: says the blanket claim was NOT confirmed" || bad "answered: missing NOT-confirmed verdict"
printf '%s' "$_out" | grep -q '"glm-5-2" answered' && ok "answered: names the free model that answered" || bad "answered: probe model not named as answering"
printf '%s' "$_out" | grep -q '"claude-opus-5" was refused on this run' && ok "answered: says only what happened to the refused model (refused on this run)" || bad "answered: refused-model wording missing"
printf '%s' "$_out" | grep -q 'treated as spent' && bad "answered: claims the refused model is 'treated as spent' (nothing enforces that)" || ok "answered: no unenforced 'treated as spent' claim"
[ -e "$(_lane_probe_file dv)" ] && bad "answered: probe capture left behind after the block" || ok "answered: probe capture consumed by the block"
printf '%s' "$_out" | grep -q 'dv lane stays UP' && ok "answered: says the lane stays UP" || bad "answered: lane verdict missing"
printf '%s' "$_out" | grep -q -- '-m glm-5-2' && ok "answered: tells the user how to keep using the free model" || bad "answered: no usable-model hint"
printf '%s' "$_out" | grep -q 'blocks ALL plan-included models' && bad "answered: still claims ALL plan-included models are blocked" || ok "answered: no all-models-blocked claim"
printf '%s' "$_out" | grep -q 'marked DOWN' && bad "answered: prints a marked-DOWN line" || ok "answered: no marked-DOWN line"
printf '%s' "$_out" | grep -qi 'do NOT retry' && bad "answered: 'do NOT retry' wording printed" || ok "answered: no 'do NOT retry' wording"
printf '%s' "$_out" | grep -q 'Devin says it resets in 11h26m' && ok "answered: still quotes Devin's reset for the refused model" || bad "answered: reset not quoted"

# === (c) refused model IS the default probe model -> probe a SIBLING, not the same model ==========
refuse glm-5-2
_out="$(_devin_plan_quota_block "$FX/daily" glm-5-2 'scope' 'advice' 2>&1)"
[ "$(calls)" = "swe-2" ] && ok "sibling: glm-5-2 refused -> probe went to swe-2 (separate Free tier), not back to glm-5-2" || bad "sibling: devin calls were '$(calls)'"
_lane_down_active dv && bad "sibling: lane down although swe-2 answered" || ok "sibling: lane stays up on the sibling's answer"
[ "$(_devin_plan_probe_model glm-5.2)" = "swe-2" ] && ok "sibling: dotted alias glm-5.2 folds to the probe alt swe-2" || bad "sibling: got '$(_devin_plan_probe_model glm-5.2)'"
[ "$(_devin_plan_probe_model kimi-k3)" = "glm-5-2" ] && ok "sibling: any other refused model probes the default glm-5-2" || bad "sibling: got '$(_devin_plan_probe_model kimi-k3)'"
[ "$(OSRC_DEVIN_PROBE_MODEL=swe-1-7 OSRC_DEVIN_PROBE_MODEL_ALT=kimi-k3 _devin_plan_probe_model swe-1-7)" = "kimi-k3" ] && ok "sibling: probe/alt overridable via env" || bad "sibling: env override ignored"

# === (d) refuses the probe too -> lane DOWN for Devin's window ====================================
refuse claude-opus-5 glm-5-2
_lane_down_clear dv; _before=$(date +%s)
_out="$(_devin_plan_quota_block "$FX/daily" claude-opus-5 'including the free-tier ones you would otherwise fall back to (the probe was refused as well)' 'Switch lanes OFF Devin: --provider cc -m glm (OpenRouter) or a native lane.' 2>&1)"
_after=$(date +%s)
_lane_down_active dv && ok "confirmed: dv lane marked DOWN after the probe was refused too" || bad "confirmed: dv lane NOT down"
[ "$(_lane_down_reason dv)" = "plan quota exhausted" ] && ok "confirmed: down-reason recorded" || bad "confirmed: reason '$(_lane_down_reason dv)'"
# The mark lands inside the call, so until-before = reset+slack + (mark-before): the ceiling adds the
# MEASURED elapsed, never a magic headroom a legitimate bounded probe could overflow.
_until="$(_posture_get dv down 2>/dev/null)"; _ttl=$(( ${_until:-0} - _before ))
[ "$_ttl" -ge 41220 ] && [ "$_ttl" -le $(( 41220 + _after - _before )) ] && ok "confirmed: lane-down window = Devin's 11h26m (+slack), got ${_ttl}s" || bad "confirmed: TTL ${_ttl}s is not Devin's stated reset"
[ "$(calls)" = "glm-5-2" ] && ok "confirmed: exactly one bounded probe was sent" || bad "confirmed: devin calls were '$(calls)'"
printf '%s' "$_out" | grep -q 'CONFIRMED' && ok "confirmed: says the probe CONFIRMED the block" || bad "confirmed: verdict missing"
printf '%s' "$_out" | grep -q 'shared DAILY plan quota is exhausted' && ok "confirmed: says the SHARED DAILY bucket is exhausted" || bad "confirmed: honest daily wording missing"
printf '%s' "$_out" | grep -q 'blocks ALL plan-included models' && ok "confirmed: says it blocks ALL plan-included models" || bad "confirmed: all-models wording missing"
printf '%s' "$_out" | grep -q 'the probe was refused as well' && ok "confirmed: caller's scope clause carries the probe result" || bad "confirmed: scope clause missing"
printf '%s' "$_out" | grep -q 'Switch lanes OFF Devin' && ok "confirmed: OFF-Devin advice printed" || bad "confirmed: advice missing"
printf '%s' "$_out" | grep -q 'exact wording on the probe' && ok "confirmed: quotes Devin's wording from the probe" || bad "confirmed: probe wording not quoted"
printf '%s' "$_out" | grep -qi 'do NOT retry' && bad "confirmed: 'do NOT retry' wording printed" || ok "confirmed: no 'do NOT retry' wording"
_lane_down_clear dv

# === (e) probe unreachable -> short transport window only, never the quota window ================
refuse claude-opus-5; _before=$(date +%s)
_out="$(FAKE_DEVIN_SLEEP=20 OSRC_LANE_PROBE_SECS=1 _devin_plan_quota_block "$FX/daily" claude-opus-5 'scope' 'advice' 2>&1)"
_after=$(date +%s)
_lane_down_active dv && ok "unreachable: lane gets a down marker (it is not answering)" || bad "unreachable: no down marker"
_until="$(_posture_get dv down 2>/dev/null)"; _ttl=$(( ${_until:-0} - _before ))
[ "$_ttl" -ge 300 ] && [ "$_ttl" -le $(( 300 + _after - _before )) ] && ok "unreachable: short transport TTL (${_ttl}s; 300s + probe bound), not the 11h quota window" || bad "unreachable: TTL ${_ttl}s"
case "$(_lane_down_reason dv)" in *"probe unreachable"*) ok "unreachable: reason says the probe was unreachable" ;; *) bad "unreachable: reason '$(_lane_down_reason dv)'" ;; esac
printf '%s' "$_out" | grep -q 'INCONCLUSIVE' && ok "unreachable: says INCONCLUSIVE" || bad "unreachable: verdict missing"
printf '%s' "$_out" | grep -q 'blocks ALL plan-included models' && bad "unreachable: claims ALL plan-included models blocked without proof" || ok "unreachable: no unproven all-models claim"
_lane_down_clear dv

# === (f) structural ==============================================================================
grep -v '^[[:space:]]*#' "$SRC" | grep -q 'do NOT retry them' && bad "structure: 'do NOT retry them' still in a user-facing line" || ok "structure: 'do NOT retry them' gone from user-facing lines"
grep -q '_pq_verdict="$(_lane_free_probe dv "$_pq_probe")"' "$SRC" && ok "structure: the block probes before deciding" || bad "structure: block does not call _lane_free_probe"
_pre="$(awk '/^_devin_plan_quota_block\(\)/{f=1} f&&/_lane_down_mark dv/{print NR; exit}' "$SRC")"
_prb="$(awk '/^_devin_plan_quota_block\(\)/{f=1} f&&/_lane_free_probe dv/{print NR; exit}' "$SRC")"
[ -n "$_pre" ] && [ -n "$_prb" ] && [ "$_prb" -lt "$_pre" ] && ok "structure: probe (line $_prb) runs BEFORE any _lane_down_mark (line $_pre)" || bad "structure: probe/mark order wrong (probe=$_prb mark=$_pre)"
grep -q '_timeout "$secs" devin' "$SRC" && ok "structure: probe is wall-clock bounded via _timeout" || bad "structure: probe not bounded via _timeout"

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
