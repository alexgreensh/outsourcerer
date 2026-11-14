#!/usr/bin/env bash
# test_lane_down_gate.sh — the dispatch side of the doctor->dispatch loop (Slice 1c). The marker
# primitives live in test_lane_down_marker.sh; THIS suite pins what the marker is FOR:
#   * _fallback_lane_ready refuses a marked-down lane (hops never retarget a dead lane),
#   * _gate_hop arms a zero-cost shortlist hop off a gated lane (shared with the quota gate),
#   * the route_delegate LANE-DOWN GATE: a pinned -m is refused LOUDLY ("pinned choice", never a
#     silent switch), an unpinned run on a down lane dies naming the lane + the self-heal path, an
#     expired marker is inert, and a refused dispatch records a durable blocked/lane_down outcome.
# Layers: UNIT (helpers, sourced) + INTEGRATION (real --osrc-preflight-internal route, fake CLIs so
# nothing ever dispatches). SKIPs the outcome-row check without jq.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-lanedown.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home"; OSRC_SOURCED=1; export -n OSRC_SOURCED; mkdir -p "$OSRC_HOME"
# shellcheck disable=SC1090
. "$SRC" >/dev/null 2>&1
type -t _gate_hop >/dev/null || { echo "FAIL: _gate_hop not defined (gate wiring missing?)"; exit 1; }

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
for cli in droid codex; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/$cli"; chmod +x "$FAKEBIN/$cli"; done

# ---------------------------------------------------------------------------------------------------
# UNIT: _lane_down_clear drops a live marker early (doctor's `up` verdict uses it)
# ---------------------------------------------------------------------------------------------------
_lane_down_mark dv 300
_lane_down_active dv || bad "setup: dv marker not active"
_lane_down_clear dv
_lane_down_active dv && bad "clear: dv still down after _lane_down_clear" || ok "clear: _lane_down_clear drops a live marker"
_lane_down_clear "nonexistent-lane" && ok "clear: unknown lane is a silent no-op" || bad "clear: unknown lane errored"

# ---------------------------------------------------------------------------------------------------
# UNIT: _fallback_lane_ready consults the marker — a down lane is NOT a retry target even with its
# CLI on PATH (fake codex makes cx otherwise-ready).
# ---------------------------------------------------------------------------------------------------
( PATH="$FAKEBIN:$PATH"; _fallback_lane_ready cx ) \
  && ok "ready: cx lane ready with codex on PATH (no marker)" \
  || bad "ready: cx not ready despite fake codex — fixture broken"
_lane_down_mark cx 300
( PATH="$FAKEBIN:$PATH"; _fallback_lane_ready cx ) \
  && bad "ready: cx reported ready while marked DOWN" \
  || ok "ready: marked-down cx excluded from retry targets"
_lane_down_clear cx

# ---------------------------------------------------------------------------------------------------
# UNIT: _gate_hop arms a zero-cost hop — rewrites ARGV to the next READY candidate and marks hop-mode
# (OSRC_FALLBACK_PINNED=1) so an auto-detached child keeps hopping instead of dying "pinned choice".
# Runs in a subshell: it mutates route_delegate's locals by dynamic scope (the _fb_rebuild_argv
# contract), so we simulate exactly the locals it reads.
# ---------------------------------------------------------------------------------------------------
( PATH="$FAKEBIN:$PATH"
  MODEL=devin-default; RESOLVED_ID=devin-default; PROVIDER=devin; OSRC_SPEND_OK=1
  _fb_tried=""; _fb_loaded=1; _fb_cands="kimi|kimi-k3|cx"   # cx is the only READY lane (fake codex)
  REST=("do the thing"); TIER_FLAG=""; EFFORT=""; WITH_SPEC=""; OSRC_ALLOW_DOWNGRADE=0
  ARGV=(run "do the thing")
  _gate_hop devin \
    && [ "${ARGV[*]}" = "--provider codex -m kimi --spend-ok do the thing" ] \
    && [ "${OSRC_FALLBACK_PINNED:-0}" = "1" ] \
    && [ "$_fb_alias" = "kimi" ] && [ "$_fb_lane" = "cx" ] ) \
  && ok "hop: _gate_hop rewrites argv to --provider codex -m kimi + marks hop-mode + exposes _fb_alias/_fb_lane for the notice" \
  || bad "hop: _gate_hop did not arm the expected hop"
( PATH="$FAKEBIN:$PATH"
  MODEL=devin-default; RESOLVED_ID=devin-default; PROVIDER=devin; unset OSRC_SPEND_OK
  _fb_tried=""; _fb_loaded=1; _fb_cands="kimi|kimi-k3|cx"
  REST=("do the thing"); TIER_FLAG=""; EFFORT=""; WITH_SPEC=""; OSRC_ALLOW_DOWNGRADE=0
  ARGV=(run "do the thing")
  _gate_hop devin; rc=$?
  [ "$rc" -eq 1 ] && [ "${ARGV[*]}" = "run do the thing" ] ) \
  && ok "hop: unknown billing without consent refuses and leaves argv unchanged" \
  || bad "hop: unknown billing without consent was selected or changed argv"
# Exhausted shortlist -> rc1 so the caller dies with its own gate-specific message.
( PATH="$FAKEBIN:$PATH"
  MODEL=devin-default; RESOLVED_ID=devin-default; PROVIDER=devin
  _fb_tried=" kimi kimi-k3 kimi-k3@cx"; _fb_loaded=1; _fb_cands="kimi|kimi-k3|cx"
  REST=("t"); TIER_FLAG=""; EFFORT=""; WITH_SPEC=""; ARGV=(run t)
  _gate_hop devin ) \
  && bad "hop: all-tried shortlist still armed a hop" \
  || ok "hop: exhausted shortlist -> rc1 (caller dies with gate message)"

# ---------------------------------------------------------------------------------------------------
# INTEGRATION: the gate via a real preflight route (fake droid; nothing dispatches)
# ---------------------------------------------------------------------------------------------------
run_pf() { PATH="$FAKEBIN:$PATH" OSRC_HOME="$1" OSRC_SOURCED= OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 bash "$SRC" --osrc-preflight-internal run --provider droid -m kimi-k3 --spend-ok "hi" 2>&1; }
mark_down() { mkdir -p "$1/lane-posture"; printf '%s\n' "$(( $(date +%s) + ${2:-300} ))" > "$1/lane-posture/$3.down"; }

# Clean: no marker -> normal routing (regression: default path untouched).
H1="$TMP/h1"; mkdir -p "$H1"
{ _t3b_pipe="$(run_pf "$H1")" && grep -q 'RESOLVED lane=droid' <<<"$_t3b_pipe"; } && ok "integration: no marker -> droid routes normally" || bad "no-marker routing regressed"

# Pinned -m on a down lane -> LOUD refusal that names the lane AND the pin. The order guarantee:
# a known-down lane must never quietly absorb an explicit user choice.
H2="$TMP/h2"; mkdir -p "$H2"; mark_down "$H2" 300 droid
out="$(run_pf "$H2")"
case "$out" in
  *"marked DOWN"*"pinned choice"*|*"pinned choice"*"marked DOWN"*)
    ok "integration: pinned -m on down lane refuses loudly (pin not masked)" ;;
  *) bad "pinned down-lane refusal missing/unclear: $out" ;;
esac
# The refusal is durable telemetry: a blocked/lane_down outcome row lands in the ledger fold input
# (blocked is non-learnable, so it can never poison model-quality history).
if have jq; then
  of="$(ls "$H2"/outcomes-*.jsonl 2>/dev/null | head -1)"
  if [ -n "$of" ] && grep -q '"reason":"lane_down"' "$of" && grep -q '"outcome":"blocked"' "$of"; then
    ok "integration: refused dispatch records blocked/lane_down outcome"
  else
    bad "integration: no lane_down outcome row recorded"
  fi
else
  echo "SKIP: lane_down outcome row (jq absent)"
fi

# Unpinned on a down lane (droid has no fallback walk) -> dies naming the lane + the self-heal/reset path.
H3="$TMP/h3"; mkdir -p "$H3"; mark_down "$H3" 300 droid
out="$(PATH="$FAKEBIN:$PATH" OSRC_HOME="$H3" OSRC_SOURCED= OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 bash "$SRC" --osrc-preflight-internal run --provider droid "hi" 2>&1)"
case "$out" in *"marked DOWN"*"posture reset"*) ok "integration: unpinned down-lane run dies naming lane + reset" ;; *) bad "unpinned down-lane run not refused clearly: $out" ;; esac

# Expired marker -> inert, routes normally (self-heal).
H4="$TMP/h4"; mkdir -p "$H4"; mark_down "$H4" -50 droid
{ _t3b_pipe="$(run_pf "$H4")" && grep -q 'RESOLVED lane=droid' <<<"$_t3b_pipe"; } && ok "integration: expired marker self-heals -> routes normally" || bad "expired marker still blocking"

# A mark on a DIFFERENT lane does not gate this route (isolation).
H5="$TMP/h5"; mkdir -p "$H5"; mark_down "$H5" 300 dv
{ _t3b_pipe="$(run_pf "$H5")" && grep -q 'RESOLVED lane=droid' <<<"$_t3b_pipe"; } && ok "integration: dv marker does not gate the droid route" || bad "cross-lane isolation broken"

# ---------------------------------------------------------------------------------------------------
# SOURCE cross-checks: the gate's placement + pin order are the reviewed contract.
# ---------------------------------------------------------------------------------------------------
grep -qF 'missing_tool|lane_down)' "$SRC" \
  && ok "source: reason enum whitelists lane_down" \
  || bad "source: lane_down missing from reason enum"
# The LANE-DOWN gate sits AFTER the quota gate and BEFORE the denylist gate.
_q="$(grep -n 'QUOTA GATE' "$SRC" | head -1 | cut -d: -f1)"
_l="$(grep -n 'LANE-DOWN GATE' "$SRC" | head -1 | cut -d: -f1)"
_d="$(grep -n 'DENYLIST GATE' "$SRC" | head -1 | cut -d: -f1)"
{ [ -n "$_q" ] && [ -n "$_l" ] && [ -n "$_d" ] && [ "$_q" -lt "$_l" ] && [ "$_l" -lt "$_d" ]; } \
  && ok "source: gate order is quota -> lane-down -> denylist" \
  || bad "source: gate order wrong (quota=$_q lane-down=$_l denylist=$_d)"
# Inside the gate, the pin check fires BEFORE the hop arm (a down lane never silently eats a pin).
_gate_block="$(sed -n '/LANE-DOWN GATE/,/DENYLIST GATE/p' "$SRC")"
_p="$(printf '%s\n' "$_gate_block" | grep -n '_fb_user_pinned' | head -1 | cut -d: -f1)"
_h="$(printf '%s\n' "$_gate_block" | grep -n '_gate_hop' | head -1 | cut -d: -f1)"
{ [ -n "$_p" ] && [ -n "$_h" ] && [ "$_p" -lt "$_h" ]; } \
  && ok "source: pin check precedes the hop arm inside the gate" \
  || bad "source: hop arm precedes pin check — a pin could be silently switched"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
