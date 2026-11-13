#!/usr/bin/env bash
# test_limit_gate.sh — L7: a lane whose plan meter is at/over OSRC_LANE_LIMIT_PCT (default 90)
# on a FRESH reading is never routed to. The failure this kills: ChatGPT weekly at 98%, `brief`
# showed it, and a launch still resolved onto the lane where the delegate sat on a limit banner.
#
# Contract under test (lib/limits.sh + the route_delegate LIMIT GATE + the cmd_advise exclusion):
#   * advise never picks an exhausted lane (hard exclude, not a score haircut),
#   * a direct launch warns ONCE naming the meter + suggested fallback, then proceeds only with
#     --force-lane or a user --provider pin; unpinned auto takes a zero-cost hop; pins refuse,
#   * stale readings (> OSRC_LIMITS_STALE_SECS = 6h, carried as codexage=) are UNKNOWN, not
#     exhausted: warn only, never gate,
#   * fallback suggestion follows the SKILL.md conservation order (local -> Devin -> Gemini ->
#     Codex -> OpenRouter) filtered to ready, non-exhausted lanes.
#
# Layers: UNIT (helpers, sourced, _session_limits stubbed) + INTEGRATION (real
# --osrc-preflight-internal route against a fake codex rollout under a fake $HOME; nothing
# dispatches). No tmux anywhere.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
LIB="$SCRIPT_DIR/../lib/limits.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
[ -f "$LIB" ] || { echo "FAIL: cannot find $LIB (limit gate module missing)"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }
bash -n "$LIB" || { echo "FAIL: bash -n failed for $LIB"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-limitgate.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home"; export OSRC_SOURCED=1; mkdir -p "$OSRC_HOME"
SRC_ONLY="$TMP/src.sh"; sed '/^[[:space:]]*main "\$@"[[:space:]]*$/d' "$SRC" > "$SRC_ONLY"
# The sourced copy resolves SCRIPT_DIR to $TMP; give it a lib/ sibling so the module loader finds
# the real limits.sh (same trick the other copy-sourcing suites need for moved functions).
ln -s "$SCRIPT_DIR/../lib" "$TMP/lib"
# shellcheck disable=SC1090
. "$SRC_ONLY" >/dev/null 2>&1
type -t _osrc_limit_gate >/dev/null || { echo "FAIL: _osrc_limit_gate not defined (lib not loaded?)"; exit 1; }
type -t _session_limits >/dev/null || { echo "FAIL: _session_limits not defined (lib not loaded?)"; exit 1; }
# The gate reads meters through a 60s snapshot cache; every stub change below must drop it.
_reset_snap() { _OSRC_LIMITS_SNAP=""; _OSRC_LIMITS_SNAP_TS=0; }

# ---------------------------------------------------------------------------------------------------
# UNIT: meter extraction — the lane's MOST-SPENT declared window wins.
# ---------------------------------------------------------------------------------------------------
_session_limits() { printf 'codex5h=40 codexwk=98\n'; }
got="$(_osrc_lane_limit cx "codex5h=40 codexwk=98")"
[ "$got" = "codexwk=98" ] && ok "unit: cx binding window is the max (codexwk=98)" || bad "unit: cx limit read '$got'"
got="$(_osrc_lane_limit cc "claude5h=95 claude7d=38")"
[ "$got" = "claude5h=95" ] && ok "unit: cc binding window is the max (claude5h=95)" || bad "unit: cc limit read '$got'"
got="$(_osrc_lane_limit cx "claude5h=99 claude7d=88")"
[ -z "$got" ] && ok "unit: cx ignores claude-only windows (no codex reading -> rc1)" || bad "unit: cx read '$got' from foreign windows"
_osrc_lane_limit dv "codexwk=99" 2>/dev/null \
  && bad "unit: meterless lane dv produced a reading" \
  || ok "unit: meterless lane dv -> rc1 (never gated)"
_osrc_lane_limit or "codexwk=99" 2>/dev/null \
  && bad "unit: meterless lane or produced a reading" \
  || ok "unit: meterless lane or -> rc1"

# ---------------------------------------------------------------------------------------------------
# UNIT: threshold + exceeded semantics — fresh gates, under-line clears, stale is unknown.
# ---------------------------------------------------------------------------------------------------
[ "$(_osrc_limit_threshold)" = "90" ] && ok "unit: default threshold is 90" || bad "unit: default threshold wrong"
( OSRC_LANE_LIMIT_PCT=80; [ "$(_osrc_limit_threshold)" = "80" ] ) \
  && ok "unit: OSRC_LANE_LIMIT_PCT overrides" || bad "unit: env override ignored"
( OSRC_LANE_LIMIT_PCT=banana; [ "$(_osrc_limit_threshold)" = "90" ] ) \
  && ok "unit: non-numeric threshold falls back to 90" || bad "unit: garbage threshold not sanitized"

_session_limits() { printf 'codexwk=98\n'; }
_osrc_limit_exceeded cx "codexwk=98" && ok "unit: fresh codexwk=98 exceeds" || bad "unit: fresh 98 not exceeded"
_osrc_limit_exceeded cx "codexwk=89" && bad "unit: codexwk=89 exceeded" || ok "unit: codexwk=89 under line clears"
_osrc_limit_exceeded cx "codexwk=90" && ok "unit: exactly-at-threshold counts (>=)" || bad "unit: 90 did not count as exhausted"
# Stale: codexage older than 6h -> unknown, NOT exhausted, even at 100%.
_osrc_limit_exceeded cx "codexwk=100 codexage=99999" \
  && bad "unit: STALE codexwk=100 treated as exhausted" \
  || ok "unit: stale codexwk=100 is unknown, not exhausted"
# codexage between OSRC_LIMITS_MAX_AGE (2h) and 6h -> still a live reading, still gates.
_osrc_limit_exceeded cx "codexwk=98 codexage=10000" \
  && ok "unit: 2-6h-old reading still gates (fresh per the 6h rule)" \
  || bad "unit: codexage=10000 wrongly treated as stale"
# Missing meter -> never gated.
_osrc_limit_exceeded cx "claude5h=99" \
  && bad "unit: lane with no codex reading gated" \
  || ok "unit: no reading -> not exceeded"

# ---------------------------------------------------------------------------------------------------
# UNIT: fallback order — SKILL.md conservation order, ready + non-exhausted only.
# ---------------------------------------------------------------------------------------------------
_session_limits() { printf 'codexwk=98\n'; }
# Nothing ready -> rc1 (caller renders "none ready").
( _fallback_lane_ready() { return 1; }; _lane_ready_probe() { return 1; }
  _osrc_limit_fallback "codexwk=98" ) \
  && bad "unit: fallback suggested with zero ready lanes" \
  || ok "unit: no ready lanes -> rc1"
# cx is exhausted; local ready -> local wins (first in conservation order).
fb="$( _fallback_lane_ready() { if [ "$1" = local ]; then return 0; fi; return 1; }
        _lane_ready_probe() { return 1; }
        _osrc_limit_fallback "codexwk=98" )"
[ "$fb" = "local" ] && ok "unit: fallback picks local first when ready" || bad "unit: fallback picked '$fb' not local"
# local unready, dv ready -> dv. cx itself is skipped (exhausted) even when "ready".
fb="$( _fallback_lane_ready() { if [ "$1" = dv ] || [ "$1" = cx ]; then return 0; fi; return 1; }
        _lane_ready_probe() { return 1; }
        _osrc_limit_fallback "codexwk=98" )"
[ "$fb" = "dv" ] && ok "unit: exhausted cx skipped; dv picked over cx" || bad "unit: fallback picked '$fb' not dv"
# Or is the last resort: only or ready -> or.
fb="$( _fallback_lane_ready() { [ "$1" = or ] && return 0; return 1; }
        _lane_ready_probe() { return 1; }
        _osrc_limit_fallback "codexwk=98" )"
[ "$fb" = "or" ] && ok "unit: or is the last-resort fallback" || bad "unit: fallback picked '$fb' not or"

# ---------------------------------------------------------------------------------------------------
# UNIT: _osrc_limit_gate — warn once, then consent/hop/refuse. die() exits, so refusal cases run
# in subshells and are judged on rc + stderr text.
# ---------------------------------------------------------------------------------------------------
_session_limits() { printf 'codexwk=98\n'; }

# Fresh exceeded + pinned -m, no consent -> LOUD refusal naming meter + fallback + overrides.
out="$( _fb_user_pinned=1 MODEL=kimi-k3 RESOLVED_ID=kimi-k3 PROVIDER=devin tier=edit
        _fallback_enabled() { return 1; }
        _osrc_limit_gate cxnative 2>&1 )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"limit gate"*"codexwk=98"*"pinned"*) ok "unit: pinned -m on exhausted lane refuses loudly" ;;
  *) bad "unit: pinned refusal wrong (rc=$rc): $out" ;;
esac

# --force-lane consents: warning printed, rc0, proceeds.
out="$( OSRC_FORCE_LANE=1 _fb_user_pinned=1 MODEL=kimi-k3 RESOLVED_ID=kimi-k3 PROVIDER=devin tier=edit
        _osrc_limit_gate cxnative 2>&1 )"; rc=$?
[ $rc -eq 0 ] && case "$out" in
  *"[limit]"*"codexwk=98"*) ok "unit: --force-lane warns once and proceeds" ;;
  *) bad "unit: --force-lane path wrong (rc=$rc): $out" ;;
esac

# User --provider pin consents (explicit lane choice); a hop-injected provider (FALLBACK_PINNED=1)
# does NOT.
out="$( PROVIDER_EXPLICIT=1 _fb_user_pinned=0 PROVIDER=devin tier=auto
        _osrc_limit_gate cxnative 2>&1 )"; rc=$?
[ $rc -eq 0 ] && case "$out" in *"[limit]"*) ok "unit: --provider pin consents" ;; *) bad "unit: provider-pin consent wrong (rc=$rc): $out" ;; esac
out="$( PROVIDER_EXPLICIT=1 OSRC_FALLBACK_PINNED=1 _fb_user_pinned=1 MODEL=m RESOLVED_ID=m PROVIDER=devin tier=auto
        _fallback_enabled() { return 1; }
        _osrc_limit_gate cxnative 2>&1 )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"limit gate"*) ok "unit: hop-injected provider is NOT consent (still refuses pinned)" ;;
  *) bad "unit: FALLBACK_PINNED consent leak (rc=$rc): $out" ;;
esac

# Unpinned auto + fallback armed -> rc10 hop, not a dispatch on the dead lane.
out="$( _fb_user_pinned=0 PROVIDER=devin tier=auto _fb_tried="" _fb_loaded=1 _fb_cands="kimi|kimi-k3|dv"
        _fallback_enabled() { return 0; }
        _gate_hop() { _fb_alias=kimi; _fb_lane=dv; return 0; }
        _osrc_limit_gate cxnative 2>&1 )"; rc=$?
[ $rc -eq 10 ] && case "$out" in
  *"[limit]"*"codexwk=98"*"kimi"*) ok "unit: unpinned auto hops off the exhausted lane (rc10)" ;;
  *) bad "unit: hop path wrong (rc=$rc): $out" ;;
esac

# Stale reading -> warn-only proceed even pinned, no consent needed.
out="$( _session_limits() { printf 'codexwk=100 codexage=99999\n'; }
        _fb_user_pinned=1 MODEL=m RESOLVED_ID=m PROVIDER=devin tier=edit
        _osrc_limit_gate cxnative 2>&1 )"; rc=$?
[ $rc -eq 0 ] && case "$out" in
  *"[limit]"*"stale"*) ok "unit: stale reading warns 'unknown, not exhausted' and proceeds" ;;
  *) bad "unit: stale path wrong (rc=$rc): $out" ;;
esac

# Under the line / gate disabled / unmetered lane -> silent rc0.
out="$( _session_limits() { printf 'codexwk=40\n'; }
        _osrc_limit_gate cxnative 2>&1 )"; rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && ok "unit: under-line lane routes silently" || bad "unit: under-line produced output/rc=$rc: $out"
out="$( _session_limits() { printf 'codexwk=100\n'; }
        OSRC_LANE_LIMIT_GATE=0 _fb_user_pinned=1 MODEL=m RESOLVED_ID=m PROVIDER=devin tier=edit
        _osrc_limit_gate cxnative 2>&1 )"; rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && ok "unit: OSRC_LANE_LIMIT_GATE=0 disables" || bad "unit: gate-disable wrong (rc=$rc): $out"
out="$( _session_limits() { printf 'codexwk=100\n'; }
        _osrc_limit_gate devin 2>&1 )"; rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && ok "unit: unmetered lane never gated" || bad "unit: unmetered lane gated (rc=$rc): $out"

# ---------------------------------------------------------------------------------------------------
# INTEGRATION: real --osrc-preflight-internal route against a fake codex rollout. The meter is
# faked the way brief's tests fake it: a rollout JSONL under $HOME/.codex/sessions whose
# rate_limits block carries window_minutes + used_percent; file mtime carries the age.
# ---------------------------------------------------------------------------------------------------
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
for cli in codex devin; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/$cli"; chmod +x "$FAKEBIN/$cli"; done

fake_codex_rollout() {  # <home> <weekly_pct> [old]
  local h="$1" wk="$2" old="${3:-0}" d f now reset
  d="$h/.codex/sessions/2026/11/13"; mkdir -p "$d"; f="$d/rollout-fake.jsonl"
  now="$(date +%s)"; reset=$((now + 259200))
  printf '%s\n' "{\"type\":\"turn_context\",\"payload\":{\"rate_limits\":{\"primary\":{\"window_minutes\":10080,\"used_percent\":$wk,\"resets_at\":$reset},\"secondary\":{\"window_minutes\":300,\"used_percent\":10,\"resets_at\":$reset}}}}" > "$f"
  [ "$old" = "1" ] && touch -t 202001010000 "$f"
}

run_pf() {  # <osrc_home> <home> [extra args...]
  local oh="$1" hh="$2"; shift 2
  PATH="$FAKEBIN:$PATH" HOME="$hh" OSRC_HOME="$oh" OSRC_SOURCED= OSRC_CLOUD_ACK=1 \
    OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 OSRC_LANE_LIMIT_PCT="${OSRC_LANE_LIMIT_PCT:-90}" \
    bash "$SRC" --osrc-preflight-internal "$@" 2>&1
}

# Fresh codexwk=98, pinned -m sol (alias-table lane cx) -> loud refusal, no dispatch.
H="$TMP/ih1"; HH="$TMP/hh1"; mkdir -p "$H" "$HH"
fake_codex_rollout "$HH" 98
out="$(run_pf "$H" "$HH" run -m sol "hi")"
case "$out" in
  *"limit gate"*"codexwk=98"*"pinned"*) ok "integration: pinned -m on fresh-exhausted cx refuses" ;;
  *) bad "integration: expected limit-gate refusal, got: $out" ;;
esac

# Same route + --force-lane -> the gate warns once and lets the route continue (preflight rc0).
out="$(run_pf "$H" "$HH" run --force-lane -m sol "hi")"; rc=$?
[ $rc -eq 0 ] && case "$out" in
  *"[limit]"*"codexwk=98"*) ok "integration: --force-lane warns once and the route proceeds" ;;
  *) bad "integration: --force-lane did not proceed (rc=$rc): $out" ;;
esac

# Stale rollout (mtime year 2000 -> codexage huge) -> warn-only, route proceeds even pinned.
H2="$TMP/ih2"; HH2="$TMP/hh2"; mkdir -p "$H2" "$HH2"
fake_codex_rollout "$HH2" 100 1
out="$(run_pf "$H2" "$HH2" run -m sol "hi")"; rc=$?
[ $rc -eq 0 ] && case "$out" in
  *"[limit]"*"stale"*) ok "integration: stale meter warns and proceeds (unknown, not exhausted)" ;;
  *) bad "integration: stale meter did not warn-and-proceed (rc=$rc): $out" ;;
esac

# Below the line -> normal route, zero [limit] noise.
H3="$TMP/ih3"; HH3="$TMP/hh3"; mkdir -p "$H3" "$HH3"
fake_codex_rollout "$HH3" 40
out="$(run_pf "$H3" "$HH3" run -m sol "hi")"; rc=$?
[ $rc -eq 0 ] && case "$out" in
  *"[limit]"*) bad "integration: under-line route printed a limit warning" ;;
  *) ok "integration: under-line cx routes normally, no warning" ;;
esac

# Gate disabled -> even 100% routes silently.
H4="$TMP/ih4"; HH4="$TMP/hh4"; mkdir -p "$H4" "$HH4"
fake_codex_rollout "$HH4" 100
out="$( PATH="$FAKEBIN:$PATH" HOME="$HH4" OSRC_HOME="$H4" OSRC_SOURCED= OSRC_CLOUD_ACK=1 \
    OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 OSRC_LANE_LIMIT_GATE=0 \
    bash "$SRC" --osrc-preflight-internal run -m sol "hi" 2>&1 )"; rc=$?
[ $rc -eq 0 ] && case "$out" in
  *"[limit]"*) bad "integration: OSRC_LANE_LIMIT_GATE=0 still warned" ;;
  *) ok "integration: OSRC_LANE_LIMIT_GATE=0 routes 100% silently" ;;
esac

# ---------------------------------------------------------------------------------------------------
# INTEGRATION: advise excludes the exhausted lane outright. cx candidates must not appear, and the
# conservation line must name the exclusion.
# ---------------------------------------------------------------------------------------------------
H5="$TMP/ih5"; HH5="$TMP/hh5"; mkdir -p "$H5" "$HH5"
fake_codex_rollout "$HH5" 98
out="$( PATH="$FAKEBIN:$PATH" HOME="$HH5" OSRC_HOME="$H5" OSRC_SOURCED= \
    bash "$SRC" advise "refactor the parser" 2>&1 )"
case "$out" in
  *"codexwk=98"*"excluded"*|*"excluded"*"codexwk=98"*)
    ok "integration: advise names the cx exclusion (codexwk=98 >= 90%)" ;;
  *) bad "integration: advise did not surface the limit exclusion: $(printf '%s' "$out" | head -5)" ;;
esac
# The recommended lane must not be cx while it is exhausted.
rec_lane="$(printf '%s\n' "$out" | grep -o 'lane=[a-z]*' | head -1)"
case "$rec_lane" in
  "lane=cx"|"lane=cxnative") bad "integration: advise still recommends exhausted cx ($rec_lane)" ;;
  *) ok "integration: advise recommendation is not the exhausted lane" ;;
esac

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
