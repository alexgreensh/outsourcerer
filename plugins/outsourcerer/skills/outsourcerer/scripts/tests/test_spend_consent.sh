#!/usr/bin/env bash
# test_spend_consent.sh — L7 round 3.2 (r3.1 verdict findings 1-3): runtime Free Devin
# default, NEXT = refused command + --spend-ok, token-bound exact .spend-ok markers.
# Split from test_limit_gate.sh to keep every file under the 1,000-line rule.
#
# Layers: UNIT (helpers, sourced) + INTEGRATION (real dispatch/preflight against stub CLIs
# under fake $HOME/$OSRC_HOME; nothing dispatches for real, no tmux).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
LIB="$SCRIPT_DIR/../lib/spend.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
[ -f "$LIB" ] || { echo "FAIL: cannot find $LIB (spend gate module missing)"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }
bash -n "$LIB" || { echo "FAIL: bash -n failed for $LIB"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-spendconsent.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home"; export OSRC_SOURCED=1; mkdir -p "$OSRC_HOME"
# Source the REAL script (OSRC_SOURCED=1 skips main); lib/* load via the symlink-safe
# fallback loader exactly like test_limit_gate.sh.
# shellcheck disable=SC1090
. "$SRC" >/dev/null 2>&1
type -t osrc_lane_billing >/dev/null || { echo "FAIL: osrc_lane_billing not defined (lib/spend.sh not loaded?)"; exit 1; }
type -t _devin_default_free_model >/dev/null || { echo "FAIL: _devin_default_free_model not defined"; exit 1; }
type -t _osrc_spend_next_build >/dev/null || { echo "FAIL: _osrc_spend_next_build not defined"; exit 1; }

# Stub CLIs so a consented child can never reach a real paid CLI.
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
for cli in codex devin claude; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/$cli"; chmod +x "$FAKEBIN/$cli"; done
HB="$TMP/hb"; mkdir -p "$HB"

# ---------------------------------------------------------------------------------------------------
# ROUND 3.2 (r3.1 verdict findings 1-3): runtime Free default, NEXT=refused command+--spend-ok,
# token-bound exact .spend-ok markers.
# ---------------------------------------------------------------------------------------------------

# F1 unit: _devin_default_free_model picks from the live catalog's Free set, prefers
# swe-2-high, falls back to swe-2-high offline — never a metered id.
b="$( _devin_catalog_free_ids() { printf 'swe-2-max swe-2-high '; return 0; }; _devin_default_free_model )"
[ "$b" = "swe-2-high" ] && ok "r3.2 default: catalog Free set -> swe-2-high preferred" || bad "r3.2 default: catalog pick -> '$b'"
b="$( _devin_catalog_free_ids() { printf 'glm-5.2 swe-2-max '; return 0; }; _devin_default_free_model )"
[ "$b" = "glm-5.2" ] && ok "r3.2 default: no preferred id -> first catalog Free id" || bad "r3.2 default: first-free pick -> '$b'"
b="$( _devin_catalog_free_ids() { return 1; }; _devin_default_free_model )"
[ "$b" = "swe-2-high" ] && ok "r3.2 default: catalog unreachable -> swe-2-high fallback" || bad "r3.2 default: offline -> '$b'"
b="$( _devin_catalog_free_ids() { printf ' '; return 0; }; _devin_default_free_model )"
[ "$b" = "swe-2-high" ] && ok "r3.2 default: reachable-but-empty Free set -> swe-2-high" || bad "r3.2 default: empty free set -> '$b'"
b="$( _devin_catalog_free_ids() { printf 'glm-5.2 '; return 0; }; _devin_default_free_model )"
[ "$b" = "glm-5.2" ] && ok "r3.2 default: catalog Free id wins even when not a preferred name" || bad "r3.2 default: free-id pick -> '$b'"
# billing dv with NO model now classifies by the runtime default, not DEFAULT_MODEL.
b="$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = devin ] && return 0; command -v "$1" >/dev/null 2>&1; }; _devin_catalog_free_ids() { return 1; }; osrc_lane_billing dv' )"
[ "$b" = "subscription" ] && ok "r3.2 billing: dv no-model -> runtime Free default -> subscription" || bad "r3.2 billing: dv no-model -> '$b'"
b="$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = devin ] && return 0; command -v "$1" >/dev/null 2>&1; }; _devin_catalog_free_ids() { printf "glm-5.2 "; return 0; }; osrc_lane_billing dv' )"
[ "$b" = "subscription" ] && ok "r3.2 billing: dv no-model follows catalog Free pick (glm-5.2 free here)" || bad "r3.2 billing: dv catalog-default -> '$b'"
b="$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = devin ] && return 0; command -v "$1" >/dev/null 2>&1; }; _devin_catalog_free_ids() { printf " "; return 0; }; osrc_lane_billing dv' )"
[ "$b" = "metered" ] && ok "r3.2 billing: dv no-model metered when live catalog has no Free id" || bad "r3.2 billing: dv catalog-empty-free -> '$b'"

# F2 unit: _osrc_spend_next_build reproduces the refused command + --spend-ok after the verb.
_OSRC_USER_ARGV=(bg --cloud-ack --provider cc "say hi")
_osrc_spend_next_build bg
case "$OSRC_SPEND_NEXT" in
  *" bg --spend-ok --cloud-ack --provider cc say\\ hi") ok "r3.2 next: bg NEXT = command + --spend-ok after verb" ;;
  *) bad "r3.2 next: bg NEXT wrong: $OSRC_SPEND_NEXT" ;;
esac
_OSRC_USER_ARGV=(--cloud-ack run --provider or -m hy3 "say hi")
_osrc_spend_next_build run
case "$OSRC_SPEND_NEXT" in
  *" --cloud-ack run --spend-ok --provider or -m hy3 say\\ hi") ok "r3.2 next: run NEXT keeps leading global flags + verb position" ;;
  *) bad "r3.2 next: run NEXT wrong: $OSRC_SPEND_NEXT" ;;
esac
_OSRC_USER_ARGV=(session start --provider cc -m glm "do it")
_osrc_spend_next_build start
case "$OSRC_SPEND_NEXT" in
  *" session start --spend-ok --provider cc -m glm do\\ it") ok "r3.2 next: session NEXT inserts after start" ;;
  *) bad "r3.2 next: session NEXT wrong: $OSRC_SPEND_NEXT" ;;
esac
# An existing --spend-ok is never doubled.
_OSRC_USER_ARGV=(run --spend-ok --provider or -m hy3 "say hi")
_osrc_spend_next_build run
case "$OSRC_SPEND_NEXT" in
  *" run --spend-ok --provider or -m hy3 say\\ hi") ok "r3.2 next: existing --spend-ok not duplicated" ;;
  *) bad "r3.2 next: duplicated/misplaced consent: $OSRC_SPEND_NEXT" ;;
esac
unset _OSRC_USER_ARGV

# F1+F2 integration: a default `run` on a logged-in Devin stub with a live Free-tagged
# catalog does NOT ask for spend consent and dispatches the catalog's Free pick.
DBIN="$TMP/dbin"; DHOME="$TMP/dhome"; DOH="$TMP/dohome"
mkdir -p "$DBIN" "$DHOME" "$DOH/catalogs"
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
cat > "$DOH/catalogs/dv.raw.json" <<'EOF'
{"families":[
 {"family_uid":"swe-2","aliases":["swe"],"variants":[
   {"model_uid":"swe-2-high","cost_tier":"Free","cost_summary":null},
   {"model_uid":"swe-2-max","cost_tier":"Paid","cost_summary":"$5/MTok"}]},
 {"family_uid":"glm-5.2","aliases":["glm"],"variants":[
   {"model_uid":"glm-5-2","cost_tier":"Plan","cost_summary":"plan-included"}]}]}
EOF
printf '["swe-2","swe","swe-2-high","swe-2-max","glm-5.2","glm","glm-5-2"]\n' > "$DOH/catalogs/dv.json"
: > "$TMP/devin-stub.log"
out="$( cd "$TMP" && DEVIN_STUB_LOG="$TMP/devin-stub.log" DEVIN_STUB_CATALOG="$DOH/catalogs/dv.raw.json" \
    PATH="$DBIN:$FAKEBIN:$PATH" HOME="$DHOME" OSRC_HOME="$DOH" OSRC_SOURCED= \
    OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 OSRC_PROVIDER=devin OSRC_CLOUD_ACK=1 \
    bash "$SRC" run "say hi" 2>&1 )"; rc=$?
case "$out" in
  *"spend gate"*|*"PAID LANE"*) bad "r3.2 default-run: bare run on Free-catalog Devin asked for spend (rc=$rc)" ;;
  *) [ $rc -eq 0 ] && ok "r3.2 default-run: bare run on logged-in Devin does not ask" \
       || bad "r3.2 default-run: bare run rc=$rc: $(printf '%s' "$out" | head -6)" ;;
esac
grep -q -- '--model swe-2-high' "$TMP/devin-stub.log" \
  && ok "r3.2 default-run: dispatched the catalog Free pick swe-2-high" \
  || bad "r3.2 default-run: stub log lacks --model swe-2-high: $(cat "$TMP/devin-stub.log" 2>/dev/null | head -5)"
# Offline catalog -> swe-2-high fallback still does not ask.
DOH2="$TMP/dohome2"; mkdir -p "$DOH2"
out="$( cd "$TMP" && DEVIN_STUB_LOG="$TMP/devin-stub.log" \
    PATH="$DBIN:$FAKEBIN:$PATH" HOME="$DHOME" OSRC_HOME="$DOH2" OSRC_SOURCED= \
    OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 OSRC_PROVIDER=devin OSRC_CLOUD_ACK=1 \
    bash "$SRC" run "say hi again" 2>&1 )"; rc=$?
case "$out" in
  *"spend gate"*|*"PAID LANE"*) bad "r3.2 default-run: offline bare run asked for spend" ;;
  *) [ $rc -eq 0 ] && ok "r3.2 default-run: offline catalog -> swe-2-high, still no ask" \
       || bad "r3.2 default-run: offline rc=$rc: $(printf '%s' "$out" | head -6)" ;;
esac
# But an EXPLICIT metered model still asks — the default fix never exempts a named paid id.
out="$( cd "$TMP" && DEVIN_STUB_LOG="$TMP/devin-stub.log" DEVIN_STUB_CATALOG="$DOH/catalogs/dv.raw.json" \
    PATH="$DBIN:$FAKEBIN:$PATH" HOME="$DHOME" OSRC_HOME="$DOH" OSRC_SOURCED= \
    OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 \
    bash "$SRC" run -m glm-5.2 "paid on purpose" 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"EVENT approval"*"paid-lane"* ) ok "r3.2 default-run: explicit metered -m glm-5.2 still refuses" ;;
  *) bad "r3.2 default-run: explicit metered model did not refuse (rc=$rc): $(printf '%s' "$out" | head -5)" ;;
esac

# F2 integration + round-trip: a refused `run` prints NEXT = the exact command + --spend-ok
# after the verb; running NEXT through the dispatch preflight reaches the SAME lane/model
# the EVENT named. devin/glm-5.2 is metered under the stub catalog (not Free-tagged).
out="$( cd "$TMP" && DEVIN_STUB_LOG="$TMP/devin-stub.log" DEVIN_STUB_CATALOG="$DOH/catalogs/dv.raw.json" \
    PATH="$DBIN:$FAKEBIN:$PATH" HOME="$DHOME" OSRC_HOME="$DOH" OSRC_SOURCED= \
    OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 \
    bash "$SRC" run --provider devin -m glm-5.2 "say hi" 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"EVENT approval"*"paid-lane:dv/"* ) ok "r3.2 next: refusal EVENT names dv lane" ;;
  *) bad "r3.2 next: refusal missing EVENT (rc=$rc): $(printf '%s' "$out" | head -5)" ;;
esac
nxt="$( printf '%s\n' "$out" | sed -n 's/^NEXT //p' | head -1 )"
case "$nxt" in
  *" run --spend-ok --provider devin -m glm-5.2 say\\ hi"* ) ok "r3.2 next: NEXT = refused command + --spend-ok after verb" ;;
  *) bad "r3.2 next: NEXT wrong shape: $nxt" ;;
esac
# Round-trip: strip the script path, feed the rest through the dispatch preflight —
# rc0 proves the printed command consents AND resolves the same lane/model.
rest="${nxt#"$SRC"}"
pfout="$( cd "$TMP" && DEVIN_STUB_LOG="$TMP/devin-stub.log" DEVIN_STUB_CATALOG="$DOH/catalogs/dv.raw.json" \
    PATH="$DBIN:$FAKEBIN:$PATH" HOME="$DHOME" OSRC_HOME="$DOH" OSRC_SOURCED= \
    OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 \
    eval "bash \"$SRC\" --osrc-preflight-internal${rest}" 2>&1 )"; pfrc=$?
[ $pfrc -eq 0 ] && ok "r3.2 next: round-trip NEXT reaches the same lane/model with consent" \
  || bad "r3.2 next: round-trip preflight rc=$pfrc: $(printf '%s' "$pfout" | head -6)"

# Same for bg: NEXT must keep bg + every flag (--cloud-ack, --provider, -m) verbatim.
out="$( cd "$TMP" && DEVIN_STUB_LOG="$TMP/devin-stub.log" DEVIN_STUB_CATALOG="$DOH/catalogs/dv.raw.json" \
    PATH="$DBIN:$FAKEBIN:$PATH" HOME="$DHOME" OSRC_HOME="$DOH" OSRC_SOURCED= \
    OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 OSRC_CLOUD_ACK=1 \
    bash "$SRC" bg run --cloud-ack --provider devin -m glm-5.2 "say hi" 2>&1 </dev/null )"; rc=$?
nxt="$( printf '%s\n' "$out" | sed -n 's/^NEXT //p' | head -1 )"
case "$nxt" in
  *" bg --spend-ok run --cloud-ack --provider devin -m glm-5.2 say\\ hi"* ) ok "r3.2 next: bg NEXT preserves verb + all flags" ;;
  *) bad "r3.2 next: bg NEXT wrong shape: $nxt" ;;
esac
# Round-trip the bg NEXT's inner command through preflight (strip 'bg', sentinel first).
bgrest="${nxt#"$SRC bg"}"
pfout="$( cd "$TMP" && DEVIN_STUB_LOG="$TMP/devin-stub.log" DEVIN_STUB_CATALOG="$DOH/catalogs/dv.raw.json" \
    PATH="$DBIN:$FAKEBIN:$PATH" HOME="$DHOME" OSRC_HOME="$DOH" OSRC_SOURCED= \
    OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 \
    eval "bash \"$SRC\" --osrc-preflight-internal${bgrest}" 2>&1 )"; pfrc=$?
[ $pfrc -eq 0 ] && ok "r3.2 next: bg NEXT round-trips to the same lane/model" \
  || bad "r3.2 next: bg round-trip rc=$pfrc: $(printf '%s' "$pfout" | head -6)"


echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
