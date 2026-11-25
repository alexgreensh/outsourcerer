#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_devin_launch_gate.sh — the Devin id the spend gate checks is the id that launches.
#
# P1 (PR #88 review): `-m swe` gated RESOLVED_ID (alias table: swe-1.7, Free) while delegate()
# resolved the raw token `swe` through the live catalog to a NEWER family's paid -high variant.
# Also: a Devin launch that never passed route_delegate's gate (cc -> Devin self-heal, a direct
# delegate() call) and `continue -m <paid>` launched with no consent at all; the probe fallback
# list named the bare `swe-2` family, whose default variant is not proven Free.
# All launches hit a stub devin CLI under a fake HOME/OSRC_HOME; nothing real is dispatched.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR%/}/osrc-dvlaunch.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
DOH="$TMP/osrc"; DBIN="$TMP/bin"; LOG="$TMP/devin.log"
mkdir -p "$DOH/catalogs" "$DBIN"
mkdir -p "$DOH/disk-policy" && printf 'OSRC_DISK_MIN_GB=0\nOSRC_DISK_PAUSE_GB=0\n' > "$DOH/disk-policy/settings"
cat > "$DBIN/devin" <<'EOF'
#!/usr/bin/env bash
echo "devin $*" >> "${DEVIN_STUB_LOG:-/dev/null}"
case "${1:-}" in
  auth)   echo "Logged in as stub@example.com"; exit 0 ;;
  models) cat "${DEVIN_STUB_CATALOG:-/dev/null}"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$DBIN/devin"
for cli in codex claude; do printf '#!/usr/bin/env bash\nexit 0\n' > "$DBIN/$cli"; chmod +x "$DBIN/$cli"; done
# The Codex review's catalog: the older swe-1.7 family has a Free -high; the newer swe-2-1
# family has a PAID -high and a Free -max (so it still "has a Free variant").
cat > "$DOH/catalogs/dv.raw.json" <<'EOF'
{"families":[
 {"family_uid":"swe-1.7","aliases":[],"variants":[
   {"model_uid":"swe-1-7-high","cost_tier":"Free"},
   {"model_uid":"swe-1-7-max","cost_tier":"High cost"}]},
 {"family_uid":"swe-2-1","aliases":[],"variants":[
   {"model_uid":"swe-2-1-high","cost_tier":"High cost","cost_summary":"$8/MTok · Sidekick: Free"},
   {"model_uid":"swe-2-1-max","cost_tier":"Free"}]},
 {"family_uid":"glm-5.2","aliases":["glm"],"variants":[
   {"model_uid":"glm-5-2","cost_tier":"Plan"}]}]}
EOF
printf '["swe-1.7","swe-1-7-high","swe-1-7-max","swe-2-1","swe-2-1-high","swe-2-1-max","glm-5.2","glm","glm-5-2"]\n' > "$DOH/catalogs/dv.json"

engine() {  # run the real engine against the stubs, non-interactive
  ( cd "$TMP" && DEVIN_STUB_LOG="$LOG" DEVIN_STUB_CATALOG="$DOH/catalogs/dv.raw.json" \
      PATH="$DBIN:$PATH" HOME="$HOME" OSRC_HOME="$DOH" OSRC_SOURCED= OSRC_CATALOG_TTL=999999 \
      OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 OSRC_PROVIDER=devin OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 \
      bash "$SRC" "$@" 2>&1 </dev/null )
}
launched() { grep -- "--model $1" "$LOG" 2>/dev/null | grep -q -- ' -p '; }

# --- P1: -m swe must gate the id it launches --------------------------------------------------
: > "$LOG"
out="$(engine run -m swe "say hi")"; rc=$?
if launched swe-2-1-high; then
  bad "P1: -m swe launched paid swe-2-1-high with no consent (rc=$rc)"
else
  ok "P1: -m swe did not launch the paid variant without consent"
fi
case "$out" in
  *"EVENT approval"*"paid-lane:dv/swe-2-1-high"*) [ "$rc" -ne 0 ] && ok "P1: refusal names the exact launch id swe-2-1-high" \
                                                   || bad "P1: refusal printed but rc=0" ;;
  *) bad "P1: no spend refusal for swe-2-1-high (rc=$rc): $(printf '%s' "$out" | grep -E 'spend|model|route' | head -4)" ;;
esac
# With consent the SAME id launches: consent is bound to the id the gate showed.
: > "$LOG"
out="$(engine run --spend-ok -m swe "say hi")"; rc=$?
launched swe-2-1-high && [ "$rc" -eq 0 ] && ok "P1: --spend-ok launches exactly the gated id" \
  || bad "P1: consented run did not launch swe-2-1-high (rc=$rc): $(head -3 "$LOG")"

# --- an un-routed Devin launch (the cc -> Devin self-heal path) is gated too -----------------
: > "$LOG"
out="$( cd "$TMP" && DEVIN_STUB_LOG="$LOG" DEVIN_STUB_CATALOG="$DOH/catalogs/dv.raw.json" \
    PATH="$DBIN:$PATH" HOME="$HOME" OSRC_HOME="$DOH" OSRC_SOURCED=1 OSRC_CATALOG_TTL=999999 \
    OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 SRC="$SRC" \
    bash -c '. "$SRC" >/dev/null 2>&1; tier=auto; PROVIDER=devin delegate auto "" -m glm-5.2 "heal"' 2>&1 </dev/null )"; rc=$?
if launched glm-5-2 || launched glm-5.2; then
  bad "self-heal: delegate() launched metered glm-5.2 with no consent (rc=$rc)"
else
  case "$out" in *"spend gate"*) ok "self-heal: direct delegate() launch is spend-gated" ;;
    *) bad "self-heal: no launch but no spend refusal either (rc=$rc): $(printf '%s' "$out" | tail -3)" ;; esac
fi

# --- continue -m <metered> asks like every other launch -----------------------------------
: > "$LOG"
out="$(engine continue -m glm-5.2 "follow up")"; rc=$?
if grep -q -- '-c --model' "$LOG" 2>/dev/null; then
  bad "continue: launched devin -c on metered glm-5.2 with no consent (rc=$rc)"
else
  case "$out" in *"spend gate"*) ok "continue: metered model refused without --spend-ok" ;;
    *) bad "continue: no launch but no spend refusal (rc=$rc): $(printf '%s' "$out" | tail -3)" ;; esac
fi
: > "$LOG"
out="$(engine continue -m swe-1-7-high "follow up")"; rc=$?
grep -q -- '-c --model swe-1-7-high' "$LOG" && ok "continue: Free model still continues without asking" \
  || bad "continue: Free model blocked (rc=$rc): $(printf '%s' "$out" | tail -3)"

# --- probe fallback names an exact Free variant, never the bare swe-2 family ----------------
pick="$( HOME="$HOME" OSRC_HOME="$DOH" OSRC_SOURCED=1 SRC="$SRC" \
    bash -c '. "$SRC" >/dev/null 2>&1; _model_excluded() { [ "$1" = glm-5-2 ]; }; _devin_probe_pick' 2>/dev/null )"
[ "$pick" = "swe-2-high" ] && ok "probe: fallback after glm-5-2 is the exact Free swe-2-high" \
  || bad "probe: fallback pick '$pick' (want swe-2-high)"

# --- the Free proof compares exact ids: a vendor/ prefix is not stripped into a Free id -------
bill() { PATH="$DBIN:$PATH" HOME="$HOME" OSRC_HOME="$DOH" OSRC_SOURCED=1 OSRC_CATALOG_TTL=999999 \
    DEVIN_STUB_CATALOG="$DOH/catalogs/dv.raw.json" SRC="$SRC" M="$1" OSRC_FREE_CATALOG_CHECK="$2" \
    bash -c '. "$SRC" >/dev/null 2>&1; osrc_lane_billing dv "$M" devin' 2>/dev/null; }
[ "$(bill vendor/swe-2-high 0)" = metered ] && ok "exact: offline vendor/swe-2-high is not the Free swe-2-high" \
  || bad "exact: offline vendor/swe-2-high billed '$(bill vendor/swe-2-high 0)'"
[ "$(bill swe-2-high 0)" = subscription ] && ok "exact: offline swe-2-high still Free" \
  || bad "exact: offline swe-2-high billed '$(bill swe-2-high 0)'"
[ "$(bill vendor/swe-1-7-high 1)" = metered ] && ok "exact: catalog vendor/swe-1-7-high is not the Free swe-1-7-high" \
  || bad "exact: catalog vendor/swe-1-7-high billed '$(bill vendor/swe-1-7-high 1)'"
[ "$(bill SWE-1.7-HIGH 1)" = subscription ] && ok "exact: case/dot folding still matches the catalog id" \
  || bad "exact: SWE-1.7-HIGH billed '$(bill SWE-1.7-HIGH 1)'"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
