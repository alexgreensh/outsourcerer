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
# Source the REAL script (OSRC_SOURCED=1 skips main). $0 is this test, so SCRIPT_DIR resolves to
# the tests dir and loader 1 finds nothing — loader 2 (_OSRC_FACTORY_DIR, symlinks followed)
# must find lib/; that is exactly the path the symlink cases below also prove.
# shellcheck disable=SC1090
. "$SRC" >/dev/null 2>&1
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
# Hermetic billing for the picker tests below: fake HOME (no real auth files) and stubs so
# no real `devin models list` / `codex login status` ever executes.
FH0="$TMP/fh0"; mkdir -p "$FH0"
# Nothing ready -> rc1 (caller renders "none ready").
( HOME="$FH0"; _fallback_lane_ready() { return 1; }; _lane_ready_probe() { return 1; }
  _devin_catalog_free_ids() { return 1; }; _timeout() { return 1; }
  _osrc_limit_fallback "codexwk=98" ) \
  && bad "unit: fallback suggested with zero ready lanes" \
  || ok "unit: no ready lanes -> rc1"
# cx is exhausted; local ready -> local wins (first in conservation order).
fb="$( _fallback_lane_ready() { if [ "$1" = local ]; then return 0; fi; return 1; }
        _lane_ready_probe() { return 1; }
        _osrc_limit_fallback "codexwk=98" )"
[ "$fb" = "local" ] && ok "unit: fallback picks local first when ready" || bad "unit: fallback picked '$fb' not local"
# local unready, dv ready -> dv. cx itself is skipped (exhausted) even when "ready".
# (_osrc_lane_spendable is stubbed: r3.1 billing makes dv's default model metered, and the
# spend filter has its own dedicated tests below — this case is about limit ordering.)
fb="$( _fallback_lane_ready() { if [ "$1" = dv ] || [ "$1" = cx ]; then return 0; fi; return 1; }
        _lane_ready_probe() { return 1; }
        _osrc_lane_spendable() { return 0; }
        _osrc_limit_fallback "codexwk=98" )"
[ "$fb" = "dv" ] && ok "unit: exhausted cx skipped; dv picked over cx" || bad "unit: fallback picked '$fb' not dv"
# r3.2: with REAL billing (catalog stubbed unreachable), dv's implicit default is the
# runtime Free pick -> offline swe-2-high -> subscription, so dv IS suggested without
# consent. An explicitly metered dv model is still not suggested (covered by billing tests).
fb="$( HOME="$FH0"; _fallback_lane_ready() { if [ "$1" = dv ] || [ "$1" = cx ]; then return 0; fi; return 1; }
        _lane_ready_probe() { return 1; }
        _devin_catalog_free_ids() { return 1; }; _timeout() { return 1; }
        _osrc_limit_fallback "codexwk=98" )"; frc=$?
{ [ "$fb" = "dv" ] && [ $frc -eq 0 ]; } && ok "r3.2 spend: dv suggested — its runtime default is provably Free" \
  || bad "r3.2 spend: fallback picked '$fb' (rc=$frc); expected dv on the free default"
# Or is the last resort — but ONLY with spend consent (L7 add-on: metered lanes are never
# suggested or picked quietly). Without consent the picker returns nothing rather than naming
# a lane the spend gate would refuse; with OSRC_SPEND_OK=1 the same list picks or.
fb="$( HOME="$FH0"; _fallback_lane_ready() { [ "$1" = or ] && return 0; return 1; }
        _lane_ready_probe() { return 1; }
        _devin_catalog_free_ids() { return 1; }; _timeout() { return 1; }
        _osrc_limit_fallback "codexwk=98" )"; frc=$?
{ [ -z "$fb" ] && [ $frc -ne 0 ]; } && ok "r3 spend: paid-only fallback suggests nothing without consent" \
  || bad "unit: paid-only fallback picked '$fb' without consent"

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

# User --provider pin consents (explicit lane choice) — but ONLY when it came from argv:
# OSRC_PROVIDER_ARG=1 marks a typed --provider; PROVIDER_EXPLICIT alone (env-selected provider)
# is ambient config and must NOT consent. A hop-injected provider (FALLBACK_PINNED=1) does NOT.
out="$( PROVIDER_EXPLICIT=1 OSRC_PROVIDER_ARG=1 _fb_user_pinned=0 PROVIDER=devin tier=auto
        _osrc_limit_gate cxnative 2>&1 )"; rc=$?
[ $rc -eq 0 ] && case "$out" in *"[limit]"*) ok "unit: argv --provider pin consents" ;; *) bad "unit: provider-pin consent wrong (rc=$rc): $out" ;; esac
out="$( PROVIDER_EXPLICIT=1 _fb_user_pinned=1 MODEL=m RESOLVED_ID=m PROVIDER=devin tier=edit
        _fallback_enabled() { return 1; }
        _osrc_limit_gate cxnative 2>&1 )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"limit gate"*) ok "unit: env-selected provider (PROVIDER_EXPLICIT, no OSRC_PROVIDER_ARG) is NOT consent" ;; 
  *) bad "unit: env provider leaked consent (rc=$rc): $out" ;;
esac
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
# UNIT: _osrc_session_limit_gate — the interactive session-start form. Sessions have NO fallback
# hop: consent proceeds, everything else refuses loudly naming the fallback (rc10 is impossible).
# Session PROVIDER tokens resolve to NATIVE lanes (codex->cx, claude->cc), not the or transport.
# ---------------------------------------------------------------------------------------------------
_session_limits() { printf 'codexwk=98 claude5h=40 claude7d=20\n'; }

# `session start -m terra`: PROVIDER inferred codex (native cx), MODEL_EXPLICIT=1 plays the pinned
# role -> loud refusal naming the meter + fallback; rc must be a refusal, never a hop (10).
out="$( PROVIDER=codex MODEL=terra MODEL_EXPLICIT=1 PROVIDER_EXPLICIT=0 OSRC_PROVIDER_ARG=0 \
        _osrc_session_limit_gate 2>&1 )"; rc=$?
[ $rc -ne 0 ] && [ $rc -ne 10 ] && case "$out" in
  *"limit gate"*"codexwk=98"*"fallback"*) ok "unit: session start -m on exhausted cx refuses, names fallback, no hop" ;; 
  *) bad "unit: session gate refusal wrong (rc=$rc): $out" ;;
esac

# Same lane, unpinned provider but NO consent of any kind -> still refuses (nohop), never hops.
# The fallback stubs prove the hop path is unreachable even when fully armed.
out="$( _fallback_enabled() { return 0; }; _gate_hop() { return 0; }
        PROVIDER=codex MODEL= PROVIDER_EXPLICIT=0 OSRC_PROVIDER_ARG=0 OSRC_FORCE_LANE=0 tier=auto \
        _osrc_session_limit_gate 2>&1 )"; rc=$?
[ $rc -ne 0 ] && [ $rc -ne 10 ] && case "$out" in
  *"limit gate"*) ok "unit: unpinned session on exhausted lane refuses (hop path unreachable)" ;;
  *) bad "unit: unpinned session should refuse not hop (rc=$rc): $out" ;;
esac

# argv --provider consent: PROVIDER_EXPLICIT=1 + OSRC_PROVIDER_ARG=1 -> warn once, rc0.
out="$( PROVIDER=codex MODEL= PROVIDER_EXPLICIT=1 OSRC_PROVIDER_ARG=1 OSRC_FORCE_LANE=0 \
        _osrc_session_limit_gate 2>&1 )"; rc=$?
[ $rc -eq 0 ] && case "$out" in
  *"[limit]"*"codexwk=98"*) ok "unit: session --provider pin warns once and proceeds" ;;
  *) bad "unit: session provider consent wrong (rc=$rc): $out" ;;
esac

# --force-lane consent on a session.
out="$( PROVIDER=codex MODEL=terra MODEL_EXPLICIT=1 PROVIDER_EXPLICIT=0 OSRC_FORCE_LANE=1 \
        _osrc_session_limit_gate 2>&1 )"; rc=$?
[ $rc -eq 0 ] && case "$out" in *"[limit]"*) ok "unit: session --force-lane warns and proceeds" ;; *) bad "unit: session force-lane wrong (rc=$rc): $out" ;; esac

# claude-native session: PROVIDER=claude resolves to lane cc -> claude5h=98 gates it.
out="$( _session_limits() { printf 'claude5h=98 claude7d=20 codexwk=10\n'; }
        PROVIDER=claude MODEL=opus MODEL_EXPLICIT=1 PROVIDER_EXPLICIT=0 OSRC_PROVIDER_ARG=0 \
        _osrc_session_limit_gate 2>&1 )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"limit gate"*"claude5h=98"*) ok "unit: session start on exhausted cc refuses (native resolution)" ;;
  *) bad "unit: cc session gate wrong (rc=$rc): $out" ;;
esac

# env-selected provider is NOT consent for sessions either (same rule as headless).
out="$( PROVIDER=codex MODEL= PROVIDER_EXPLICIT=1 OSRC_PROVIDER_ARG=0 OSRC_FORCE_LANE=0 \
        _osrc_session_limit_gate 2>&1 )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"limit gate"*) ok "unit: session env-provider does not consent" ;;
  *) bad "unit: session env provider leaked consent (rc=$rc): $out" ;;
esac

# Unmetered session lane (devin) -> silent rc0, no meter read.
out="$( _session_limits() { printf 'codexwk=100\n'; }
        PROVIDER=devin MODEL=swe PROVIDER_EXPLICIT=0 OSRC_PROVIDER_ARG=0 \
        _osrc_session_limit_gate 2>&1 )"; rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && ok "unit: devin session never gated" || bad "unit: devin session gated (rc=$rc): $out"

# ---------------------------------------------------------------------------------------------------
# INTEGRATION: real --osrc-preflight-internal route against a fake codex rollout. The meter is
# faked the way brief's tests fake it: a rollout JSONL under $HOME/.codex/sessions whose
# rate_limits block carries window_minutes + used_percent; file mtime carries the age.
# ---------------------------------------------------------------------------------------------------
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
# claude is stubbed too: a consented bg child must never reach a real CLI (real spend).
for cli in codex devin claude; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/$cli"; chmod +x "$FAKEBIN/$cli"; done

fake_codex_rollout() {  # <home> <weekly_pct> [old]
  local h="$1" wk="$2" old="${3:-0}" d f now reset
  d="$h/.codex/sessions/2026/11/13"; mkdir -p "$d"; f="$d/rollout-fake.jsonl"
  now="$(date +%s)"; reset=$((now + 259200))
  printf '%s\n' "{\"type\":\"turn_context\",\"payload\":{\"rate_limits\":{\"primary\":{\"window_minutes\":10080,\"used_percent\":$wk,\"resets_at\":$reset},\"secondary\":{\"window_minutes\":300,\"used_percent\":10,\"resets_at\":$reset}}}}" > "$f"
  [ "$old" = "1" ] && touch -t 202001010000 "$f"
  # r3.1: the spend gate needs PROOF of a plan login or cx classifies unknown and refuses.
  # These fixtures test the LIMIT gate, so give every fake home a ChatGPT-OAuth auth.json
  # (tokens, no API key) -> cx billing subscription -> the spend gate passes silently.
  mkdir -p "$h/.codex"; printf '{"tokens":{"access_token":"x","refresh_token":"y"}}' > "$h/.codex/auth.json"
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

# ---------------------------------------------------------------------------------------------------
# INTEGRATION: `bg run` with the provider coming from the ENVIRONMENT must still be gated. Env
# selection (OUTSOURCERER_PROVIDER) sets PROVIDER_EXPLICIT but NOT OSRC_PROVIDER_ARG — ambient
# config is not a --provider pin — and the preflight/job-child re-dispatch injects --provider
# under OSRC_PROVIDER_INJECTED so it cannot counterfeit one either. Assert refusal BEFORE a job
# id is minted; the --provider control proves consent still flows when the user actually typed it.
# ---------------------------------------------------------------------------------------------------
H7="$TMP/ih7"; HH7="$TMP/hh7"; BGCWD="$TMP/bgcwd"; mkdir -p "$H7" "$HH7" "$BGCWD"
fake_codex_rollout "$HH7" 98
out="$( cd "$BGCWD" && PATH="$FAKEBIN:$PATH" HOME="$HH7" OSRC_HOME="$H7" OSRC_SOURCED= \
    OUTSOURCERER_PROVIDER=codex OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 \
    bash "$SRC" bg run -m sol "hi" 2>&1 )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"limit gate"*|*"refusing to launch"*)
    if [ ! -d "$H7/jobs" ] || [ -z "$(ls -A "$H7/jobs" 2>/dev/null)" ]; then
      ok "integration: bg run + env provider on exhausted lane refused before minting a job"
    else
      bad "integration: env-provider bg run minted a job anyway: $(ls "$H7/jobs")"
    fi ;;
  *) bad "integration: env-provider bg run neither refused nor gated (rc=$rc): $(printf '%s' "$out" | head -5)" ;;
esac
# Control: the same launch with --provider typed on the command line consents -> job id minted.
out="$( cd "$BGCWD" && PATH="$FAKEBIN:$PATH" HOME="$HH7" OSRC_HOME="$H7" OSRC_SOURCED= \
    OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 \
    bash "$SRC" bg run --provider codex -m sol "hi" 2>&1 )"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -qE '^[A-Za-z0-9_-]+$' \
  && ok "integration: bg run --provider (argv pin) consents and mints a job" \
  || bad "integration: argv --provider bg run did not mint (rc=$rc): $(printf '%s' "$out" | head -5)"

# ---------------------------------------------------------------------------------------------------
# INTEGRATION: `session start` on an exhausted lane creates NO tmux session — this is the path that
# used to park a Terra lane on a plan-limit banner. A tmux spy proves the gate fires after lane
# resolution and before `tmux new-session`; the --force-lane control proves consent reaches it.
# ---------------------------------------------------------------------------------------------------
SFBIN="$TMP/sfbin"; mkdir -p "$SFBIN"
cat > "$SFBIN/tmux" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "${TMUX_SPY:?}"
case "${1:-}" in has-session) exit 1 ;; esac   # report "no session" so new-session is reachable
exit 0
EOF
chmod +x "$SFBIN/tmux"
cat > "$SFBIN/codex" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in --help|-h|help) printf 'Usage: codex [options]\n  -m, --model <id>   model override\n';; esac
exit 0
EOF
chmod +x "$SFBIN/codex"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SFBIN/devin"; chmod +x "$SFBIN/devin"
SPY="$TMP/tmux.spy"; : > "$SPY"

H8="$TMP/ih8"; HH8="$TMP/hh8"; SFCWD="$TMP/sfcwd"; mkdir -p "$H8" "$HH8" "$SFCWD"
fake_codex_rollout "$HH8" 98
out="$( cd "$SFCWD" && TMUX_SPY="$SPY" PATH="$SFBIN:$FAKEBIN:$PATH" HOME="$HH8" OSRC_HOME="$H8" \
    OSRC_SOURCED= OUTSOURCERER_TMUX=l7sess OSRC_NO_ADVISE=1 \
    bash "$SRC" session start -m terra 2>&1 )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"limit gate"*"codexwk=98"*) ok "integration: session start -m on exhausted cx refuses loudly" ;; 
  *) bad "integration: session start refusal wrong (rc=$rc): $(printf '%s' "$out" | head -5)" ;;
esac
if grep -q 'new-session' "$SPY" 2>/dev/null; then
  bad "integration: refused session start still created a tmux session: $(cat "$SPY")"
else
  ok "integration: refused session start created no tmux session"
fi
# Consent control: --force-lane lets the launch reach tmux new-session (the gate warns, proceeds;
# what tmux does after is the spy's problem, not the gate's).
: > "$SPY"
out="$( cd "$SFCWD" && TMUX_SPY="$SPY" PATH="$SFBIN:$FAKEBIN:$PATH" HOME="$HH8" OSRC_HOME="$H8" \
    OSRC_SOURCED= OUTSOURCERER_TMUX=l7sess OSRC_NO_ADVISE=1 \
    bash "$SRC" session start --force-lane -m terra 2>&1 )"
grep -q 'new-session' "$SPY" 2>/dev/null \
  && ok "integration: --force-lane session start reaches tmux new-session (gate consented)" \
  || bad "integration: --force-lane session start blocked before new-session: $(printf '%s' "$out" | head -5)"

# ---------------------------------------------------------------------------------------------------
# SYMLINK (LOADER.md): $0-based SCRIPT_DIR points at the LINK's directory, so loader 1 finds
# nothing; the second loader resolves _OSRC_FACTORY_DIR from BASH_SOURCE (symlinks followed)
# and must still find lib/. Prove it both executed (brief calls _session_limits/_conserve_reco,
# both lib functions) and sourced (type -t on the gate itself).
# ---------------------------------------------------------------------------------------------------
LINKDIR="$TMP/linkdir"; mkdir -p "$LINKDIR"
ln -s "$SRC" "$LINKDIR/outsourcerer.sh"
H6="$TMP/ih6"; HH6="$TMP/hh6"; mkdir -p "$H6" "$HH6"
out="$( PATH="$FAKEBIN:$PATH" HOME="$HH6" OSRC_HOME="$H6" OSRC_SOURCED= OUTSOURCERER_DEPTH=0 \
    bash "$LINKDIR/outsourcerer.sh" brief 2>&1 )"; rc=$?
case "$out" in
  *"command not found"*) bad "symlink: lib functions missing through symlinked launch" ;;
  *) [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'outsourcerer session brief' \
       && ok "symlink: brief through a symlinked script finds lib/limits.sh" \
       || bad "symlink: brief through link failed (rc=$rc): $(printf '%s' "$out" | head -3)" ;;
esac
out="$( OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1; type -t _osrc_limit_gate' _ "$LINKDIR/outsourcerer.sh" 2>/dev/null )"
[ "$out" = "function" ] && ok "symlink: sourced load through link defines _osrc_limit_gate" \
  || bad "symlink: sourced load through link did not define _osrc_limit_gate (got '$out')"

# ---------------------------------------------------------------------------------------------------
# ROUND 3 — ADD-ON 1: paid-lane spend gate (lib/spend.sh). osrc_lane_billing classes, unknown->metered,
# non-interactive EVENT approval refusal, --spend-ok one-command-only, env cannot imply consent,
# and fallback pickers never selecting a metered lane quietly.
# ---------------------------------------------------------------------------------------------------
type -t osrc_lane_billing >/dev/null || { echo "FAIL: osrc_lane_billing not defined (lib/spend.sh not loaded?)"; exit 1; }
type -t _osrc_spend_gate >/dev/null || { echo "FAIL: _osrc_spend_gate not defined"; exit 1; }
HB="$TMP/hb"; mkdir -p "$HB"

# Billing classes — each in a subshell with a controlled HOME (no ~/.env, no real auth files).
b=$( HOME="$HB" OSRC_SPEND_GATE=0 bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing local' )
[ "$b" = "free" ] && ok "r3 billing: local -> free" || bad "r3 billing: local -> '$b'"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing or' )
[ "$b" = "metered" ] && ok "r3 billing: or (OpenRouter) -> metered" || bad "r3 billing: or -> '$b'"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing tokenrouter; osrc_lane_billing gi' )
case "$b" in metered$'\n'metered) ok "r3 billing: tokenrouter + gi -> metered" ;; *) bad "r3 billing: tr/gi -> '$b'" ;; esac
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing ci; osrc_lane_billing claudex' )
case "$b" in unknown$'\n'unknown) ok "r9 billing: ci unproven + claudex upstream unverifiable -> unknown" ;; *) bad "r9 billing: ci/claudex -> '$b'" ;; esac
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing cursor; osrc_lane_billing grokbot' )
case "$b" in unknown$'\n'unknown) ok "r3 billing: cursor + grokbot unprovable -> unknown" ;; *) bad "r3 billing: cursor/grokbot -> '$b'" ;; esac
# Devin spend-free is PROOF-based: live catalog Free tag, else only SWE-2 High / SWE-2 Flash
# High offline. glm-5.2 (plan-included for quota) is NOT proven Free for spend -> metered.
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = devin ] && return 0; command -v "$1" >/dev/null 2>&1; }; _devin_catalog_free_ids() { return 1; }; osrc_lane_billing dv glm-5.2' )
[ "$b" = "metered" ] && ok "r3 billing: dv glm-5.2 not-proven-Free -> metered" || bad "r3 billing: dv glm-5.2 -> '$b'"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = devin ] && return 0; command -v "$1" >/dev/null 2>&1; }; _devin_catalog_free_ids() { return 1; }; osrc_lane_billing dv swe-2-high; osrc_lane_billing dv swe-2-flash-high' )
case "$b" in subscription$'\n'subscription) ok "r3 billing: dv offline fallback swe-2-high + swe-2-flash-high -> subscription" ;; *) bad "r3 billing: dv offline fallback -> '$b'" ;; esac
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = devin ] && return 0; command -v "$1" >/dev/null 2>&1; }; _devin_catalog_free_ids() { printf "swe-2-max glm-5.2 "; return 0; }; osrc_lane_billing dv glm-5.2; osrc_lane_billing dv swe-2-max' )
case "$b" in subscription$'\n'subscription) ok "r3 billing: dv live catalog Free ids -> subscription" ;; *) bad "r3 billing: dv catalog free -> '$b'" ;; esac
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; _devin_catalog_free_ids() { printf "swe-2-max "; return 0; }; have() { [ "$1" = devin ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing dv swe-2-high' )
[ "$b" = "metered" ] && ok "r3 billing: reachable catalog overrides static fallback (swe-2-high not Free -> metered)" || bad "r3 billing: catalog-vs-static -> '$b'"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { return 1; }; osrc_lane_billing dv swe-2-high' )
[ "$b" = "unknown" ] && ok "r3 billing: dv no CLI -> unknown" || bad "r3 billing: dv no cli -> '$b'"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing nosuchlane' )
[ "$b" = "unknown" ] && ok "r3 billing: unresolvable lane -> unknown" || bad "r3 billing: bogus -> '$b'"

# cc: API key -> metered; proven plan login -> subscription; CLI alone or redirect vars ->
# metered/unknown. Round 3.1: subscription requires PROOF (credentials/keychain/auth-dir),
# and every per-use redirect (token, base URL, BEDROCK/VERTEX, settings key helper) is metered.
b=$( HOME="$HB" ANTHROPIC_API_KEY=x bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing cc' )
[ "$b" = "metered" ] && ok "r3 billing: cc + ANTHROPIC_API_KEY -> metered" || bad "r3 billing: cc+key -> '$b'"
# r9 F1: cc subscription proof is `claude auth status` JSON ONLY — loggedIn==true,
# authMethod=="claude.ai", apiProvider=="firstParty", subscriptionType in
# pro|max|team|enterprise. A credentials file, keychain entry, Console/API-key login,
# missing fields, non-JSON, exit!=0 or no jq are all unknown. claude() is a shell
# function stub (it reaches _timeout's subshell); CLF carries the fixture JSON.
_ccbill() { local fx="$1"; shift; env HOME="$HB" CLF="$fx" "$@" bash -c '. "$1" >/dev/null 2>&1
  have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }
  claude() { printf "%s" "$CLF"; }
  osrc_lane_billing cc' _ "$SRC" 2>/dev/null; }
PLANJSON='{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}'
[ "$(_ccbill "$PLANJSON")" = "subscription" ] && ok "r9 billing: cc plan login max -> subscription" || bad "r9 billing: cc max -> '$(_ccbill "$PLANJSON")'"
for st in pro team enterprise; do
  j="{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\"subscriptionType\":\"$st\"}"
  b="$(_ccbill "$j")"
  [ "$b" = "subscription" ] && ok "r9 billing: cc plan login $st -> subscription" || bad "r9 billing: cc $st -> '$b'"
done
[ "$(_ccbill '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"console"}')" = "unknown" ] \
  && ok "r9 billing: cc non-plan subscriptionType -> unknown" || bad "r9 billing: cc console-type -> subscription?!"
[ "$(_ccbill '{"loggedIn":true,"authMethod":"console","apiProvider":"console","subscriptionType":null}')" = "unknown" ] \
  && ok "r9 billing: cc console login -> unknown" || bad "r9 billing: cc console -> subscription?!"
[ "$(_ccbill '{"loggedIn":true,"authMethod":"apiKey","apiProvider":"firstParty"}')" = "unknown" ] \
  && ok "r9 billing: cc api-key shape -> unknown" || bad "r9 billing: cc apikey -> subscription?!"
[ "$(_ccbill '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":null}')" = "unknown" ] \
  && ok "r9 billing: cc null subscriptionType -> unknown" || bad "r9 billing: cc null-type -> subscription?!"
[ "$(_ccbill '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}')" = "unknown" ] \
  && ok "r9 billing: cc missing subscriptionType -> unknown" || bad "r9 billing: cc missing-type -> subscription?!"
[ "$(_ccbill '{"loggedIn":false,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}')" = "unknown" ] \
  && ok "r9 billing: cc loggedIn false -> unknown" || bad "r9 billing: cc loggedIn-false -> subscription?!"
[ "$(_ccbill 'not json at all')" = "unknown" ] && ok "r9 billing: cc garbage auth status -> unknown" || bad "r9 billing: cc garbage -> subscription?!"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; claude() { return 1; }; osrc_lane_billing cc' )
[ "$b" = "unknown" ] && ok "r9 billing: cc auth status exit 1 -> unknown" || bad "r9 billing: cc exit1 -> '$b'"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; [ "$1" = jq ] && return 1; command -v "$1" >/dev/null 2>&1; }; claude() { printf "%s" "$PLANJSON"; }; PLANJSON="'"$PLANJSON"'" osrc_lane_billing cc' )
[ "$b" = "unknown" ] && ok "r9 billing: cc no jq -> unknown" || bad "r9 billing: cc no-jq -> '$b'"
# File/keychain existence is NOT proof: a real-shaped creds block plus garbage CLI
# output still yields unknown; a keychain entry without a plan yields unknown.
mkdir -p "$HB/.claude"; printf '{"claudeAiOauth":{"subscriptionType":"max","accessToken":"x"}}' > "$HB/.claude/.credentials.json"
[ "$(_ccbill 'garbage')" = "unknown" ] && ok "r9 billing: real-shaped creds file + garbage CLI -> unknown" || bad "r9 billing: creds-file proved subscription?!"
: > "$HB/.claude/.credentials.json"
[ "$(_ccbill '')" = "unknown" ] && ok "r9 billing: empty creds file -> unknown" || bad "r9 billing: empty creds -> subscription?!"
printf 'garbage' > "$HB/.claude/.credentials.json"
[ "$(_ccbill '')" = "unknown" ] && ok "r9 billing: garbage creds file -> unknown" || bad "r9 billing: garbage creds -> subscription?!"
b=$( HOME="$HB" OSRC_PLATFORM=darwin bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; security() { return 0; }; claude() { echo garbage; }; osrc_lane_billing cc' )
[ "$b" = "unknown" ] && ok "r9 billing: keychain entry without plan -> unknown" || bad "r9 billing: keychain -> '$b'"
rm -f "$HB/.claude/.credentials.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; ANTHROPIC_AUTH_TOKEN=t ANTHROPIC_BASE_URL=https://openrouter.ai/api osrc_lane_billing cc' )
[ "$b" = "metered" ] && ok "r3 billing: cc auth-token+base-url redirect -> metered" || bad "r3 billing: cc redirect -> '$b'"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; CLAUDE_CODE_USE_BEDROCK=1 osrc_lane_billing cc; CLAUDE_CODE_USE_VERTEX=1 osrc_lane_billing cc' )
case "$b" in metered$'\n'metered) ok "r3 billing: cc BEDROCK+VERTEX -> metered" ;; *) bad "r3 billing: cc bedrock/vertex -> '$b'" ;; esac
printf '{"apiKeyHelper":"/bin/echo sk-x"}' > "$HB/.claude/settings.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing cc' )
[ "$b" = "metered" ] && ok "r3 billing: cc settings apiKeyHelper -> metered" || bad "r3 billing: cc apikeyhelper -> '$b'"
printf '{"env":{"ANTHROPIC_API_KEY":"sk-x"}}' > "$HB/.claude/settings.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing cc' )
[ "$b" = "metered" ] && ok "r3 billing: cc settings env.ANTHROPIC_API_KEY -> metered" || bad "r3 billing: cc settings envkey -> '$b'"
rm -f "$HB/.claude/settings.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = claude ] && return 0; command -v "$1" >/dev/null 2>&1; }; claude() { :; }; rm -f "$HOME/.claude/.credentials.json"; osrc_lane_billing cc' )
[ "$b" = "unknown" ] && ok "r3 billing: cc CLI but no provable login -> unknown" || bad "r3 billing: cc cli-only -> '$b'"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { return 1; }; osrc_lane_billing cc' )
[ "$b" = "unknown" ] && ok "r3 billing: cc unprovable -> unknown" || bad "r3 billing: cc unknown -> '$b'"

# cx: ChatGPT auth.json -> subscription; OPENAI_API_KEY -> metered; nothing -> unknown.
mkdir -p "$HB/.codex"; printf '{"tokens":{"access_token":"x"}}' > "$HB/.codex/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in subscription$'\n'subscription) ok "r3 billing: cx + ci ChatGPT login -> subscription" ;; *) bad "r3 billing: cx/ci auth.json -> '$b'" ;; esac
printf '{"OPENAI_API_KEY":"sk-x"}' > "$HB/.codex/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in metered$'\n'metered) ok "r3 billing: cx + ci auth.json API key -> metered" ;; *) bad "r3 billing: cx/ci apikey -> '$b'" ;; esac
rm -rf "$HB/.codex"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { return 1; }; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in unknown$'\n'unknown) ok "r3 billing: cx + ci unprovable -> unknown" ;; *) bad "r3 billing: cx/ci unknown -> '$b'" ;; esac

# r9 class-check: `codex login status` distinguishes plan from per-use — "Logged in using
# ChatGPT" is subscription, "Logged in using an API key" bills per token -> metered,
# anything else -> unknown. (No auth.json present, so the CLI probe is what decides.)
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = codex ] && return 0; command -v "$1" >/dev/null 2>&1; }; codex() { echo "Logged in using ChatGPT"; }; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in subscription$'\n'subscription) ok "r9 billing: cx + ci login status ChatGPT -> subscription" ;; *) bad "r9 billing: cx/ci chatgpt-status -> '$b'" ;; esac
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = codex ] && return 0; command -v "$1" >/dev/null 2>&1; }; codex() { echo "Logged in using an API key - sk-***1234"; }; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in metered$'\n'metered) ok "r9 billing: cx + ci login status API key -> metered" ;; *) bad "r9 billing: cx/ci apikey-status -> '$b'" ;; esac
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = codex ] && return 0; command -v "$1" >/dev/null 2>&1; }; codex() { echo "Not logged in"; }; osrc_lane_billing cx' )
[ "$b" = "unknown" ] && ok "r9 billing: cx login status not-logged-in -> unknown" || bad "r9 billing: cx not-logged-in -> '$b'"

# r9 class-check: auth.json must prove a billing class POSITIVELY — {} / garbage /
# tokenless shapes are evidence of NEITHER (same class as the claude {} fix) -> unknown,
# never guessed subscription. have() claims jq only, so the real jq classification runs
# while codex is absent (no CLI fallback can rescue these rows).
mkdir -p "$HB/.codex"; printf '{}' > "$HB/.codex/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = jq ] && return 0; return 1; }; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in unknown$'\n'unknown) ok "r9 billing: cx/ci empty auth.json -> unknown" ;; *) bad "r9 billing: cx/ci {} auth.json -> '$b'" ;; esac
printf 'not json{{{' > "$HB/.codex/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = jq ] && return 0; return 1; }; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in unknown$'\n'unknown) ok "r9 billing: cx/ci garbage auth.json -> unknown" ;; *) bad "r9 billing: cx/ci garbage auth.json -> '$b'" ;; esac
printf '{"tokens":{}}' > "$HB/.codex/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = jq ] && return 0; return 1; }; osrc_lane_billing cx; osrc_lane_billing ci' )
case "$b" in unknown$'\n'unknown) ok "r9 billing: cx/ci tokenless auth.json -> unknown" ;; *) bad "r9 billing: cx/ci tokenless auth.json -> '$b'" ;; esac
rm -rf "$HB/.codex"

# r9 class-check: dir-auth subscription proof must not pass a BYOK login — api-key
# material inside the lane's auth dir -> metered; a plain auth file still -> subscription.
mkdir -p "$HB/.cursor"; printf '{"auth":"session-token"}' > "$HB/.cursor/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { case "$1" in cursor-agent|agent) return 0 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }; osrc_lane_billing cursor' )
[ "$b" = "subscription" ] && ok "r9 billing: cursor auth dir, no key material -> subscription" || bad "r9 billing: cursor plain-auth -> '$b'"
printf '{"apiKey":"cursor-key-abcdef123456"}' > "$HB/.cursor/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { case "$1" in cursor-agent|agent) return 0 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }; osrc_lane_billing cursor' )
[ "$b" = "metered" ] && ok "r9 billing: cursor auth dir apiKey -> metered" || bad "r9 billing: cursor dir-key -> '$b'"
rm -rf "$HB/.cursor"

mkdir -p "$HB/.factory"; printf '{"auth":"session"}' > "$HB/.factory/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = droid ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing droid' )
[ "$b" = "subscription" ] && ok "r9 billing: droid auth dir, no key material -> subscription" || bad "r9 billing: droid plain-auth -> '$b'"
printf '{"api_key":"factory-key-abcdef123456"}' > "$HB/.factory/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = droid ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing droid' )
[ "$b" = "metered" ] && ok "r9 billing: droid auth dir api_key -> metered" || bad "r9 billing: droid dir-key -> '$b'"
rm -rf "$HB/.factory"

mkdir -p "$HB/.warp"; printf '{"auth":"session"}' > "$HB/.warp/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = oz ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing warp' )
[ "$b" = "subscription" ] && ok "r9 billing: warp auth dir, no key material -> subscription" || bad "r9 billing: warp plain-auth -> '$b'"
printf '{"api-key":"warp-key-abcdef123456"}' > "$HB/.warp/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = oz ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing warp' )
[ "$b" = "metered" ] && ok "r9 billing: warp auth dir api-key -> metered" || bad "r9 billing: warp dir-key -> '$b'"
rm -rf "$HB/.warp"

# r9 class-check FUNCTIONAL: the spend gate itself, non-interactive with no consent.
# Every lane whose billing rule changed must REFUSE on unproven/metered and PROCEED
# only on positive plan/free proof — same call shape route_delegate uses.
# claudex: upstream billing is not externally provable -> unknown -> refuse.
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate claudex gpt-5.6-sol claudex "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills unknown"*) ok "r9 spend: claudex unknown -> non-interactive refuse" ;;
  *) bad "r9 spend: claudex gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
# cx/ci auth.json: unproven shapes -> unknown -> refuse; api-key field -> metered -> refuse;
# OAuth access_token -> subscription -> proceed. Real jq on PATH classifies; the codex
# stub exits 99 so no CLI probe can rescue the unproven rows.
mkdir -p "$HB/.codex"; printf '{}' > "$HB/.codex/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate cx "" cxnative "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills unknown"*) ok "r9 spend: cx empty auth.json -> refuse" ;;
  *) bad "r9 spend: cx {} gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate ci "" cxnative "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills unknown"*) ok "r9 spend: ci empty auth.json -> refuse" ;;
  *) bad "r9 spend: ci {} gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
printf '{"OPENAI_API_KEY":"sk-x"}' > "$HB/.codex/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate cx "" cxnative "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills metered"*) ok "r9 spend: cx api-key auth.json -> refuse" ;;
  *) bad "r9 spend: cx apikey gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
printf '{"tokens":{"access_token":"x"}}' > "$HB/.codex/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate cx "" cxnative "r9 probe" 2>&1 </dev/null; _osrc_spend_gate ci "" cxnative "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -eq 0 ] && ok "r9 spend: cx + ci ChatGPT auth.json -> proceed" || bad "r9 spend: cx/ci plan gate refused (rc=$rc): $(printf '%s' "$out" | head -4)"
rm -rf "$HB/.codex"
# gm: api-key material in the login dir or a Gemini/Google key env -> metered -> refuse;
# plain dir + agy -> subscription -> proceed.
mkdir -p "$HB/.antigravity"; printf '{"apiKey":"gemini-key-abcdef123456"}' > "$HB/.antigravity/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate gm "" gmnative "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills metered"*) ok "r9 spend: gm dir apiKey -> refuse" ;;
  *) bad "r9 spend: gm dir-key gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
printf '{"auth":"session"}' > "$HB/.antigravity/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" GEMINI_API_KEY=x bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate gm "" gmnative "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills metered"*) ok "r9 spend: gm GEMINI_API_KEY -> refuse" ;;
  *) bad "r9 spend: gm env-key gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  have() { [ "$1" = agy ] && return 0; command -v "$1" >/dev/null 2>&1; }
  _osrc_spend_gate gm "" gmnative "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -eq 0 ] && ok "r9 spend: gm plain auth dir -> proceed" || bad "r9 spend: gm plan gate refused (rc=$rc): $(printf '%s' "$out" | head -4)"
rm -rf "$HB/.antigravity"
# cursor/droid/warp: api-key material -> metered -> refuse; plain auth dir + CLI -> proceed.
mkdir -p "$HB/.cursor"; printf '{"apiKey":"cursor-key-abcdef123456"}' > "$HB/.cursor/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate cursor "" cursor "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills metered"*) ok "r9 spend: cursor dir apiKey -> refuse" ;;
  *) bad "r9 spend: cursor dir-key gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
printf '{"auth":"session-token"}' > "$HB/.cursor/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  have() { case "$1" in cursor-agent|agent) return 0 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  _osrc_spend_gate cursor "" cursor "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -eq 0 ] && ok "r9 spend: cursor plain auth dir -> proceed" || bad "r9 spend: cursor plan gate refused (rc=$rc): $(printf '%s' "$out" | head -4)"
rm -rf "$HB/.cursor"
mkdir -p "$HB/.factory"; printf '{"api_key":"factory-key-abcdef123456"}' > "$HB/.factory/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate droid "" droid "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills metered"*) ok "r9 spend: droid dir api_key -> refuse" ;;
  *) bad "r9 spend: droid dir-key gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
printf '{"auth":"session"}' > "$HB/.factory/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  have() { [ "$1" = droid ] && return 0; command -v "$1" >/dev/null 2>&1; }
  _osrc_spend_gate droid "" droid "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -eq 0 ] && ok "r9 spend: droid plain auth dir -> proceed" || bad "r9 spend: droid plan gate refused (rc=$rc): $(printf '%s' "$out" | head -4)"
rm -rf "$HB/.factory"
mkdir -p "$HB/.warp"; printf '{"api-key":"warp-key-abcdef123456"}' > "$HB/.warp/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  _osrc_spend_gate warp "" warp "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"bills metered"*) ok "r9 spend: warp dir api-key -> refuse" ;;
  *) bad "r9 spend: warp dir-key gate (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
printf '{"auth":"session"}' > "$HB/.warp/auth.json"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
  have() { [ "$1" = oz ] && return 0; command -v "$1" >/dev/null 2>&1; }
  _osrc_spend_gate warp "" warp "r9 probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -eq 0 ] && ok "r9 spend: warp plain auth dir -> proceed" || bad "r9 spend: warp plan gate refused (rc=$rc): $(printf '%s' "$out" | head -4)"
rm -rf "$HB/.warp"

# unknown is treated as METERED by the gate: non-interactive refusal + EVENT approval + NEXT.
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
        _osrc_spend_gate or some-model or "test" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"EVENT approval"*"paid-lane:or/"* ) ok "r3 spend: non-interactive metered lane refuses with EVENT approval" ;;
  *) bad "r3 spend: refusal missing EVENT approval (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
case "$out" in
  *"--spend-ok"*) ok "r3 spend: refusal NEXT names --spend-ok" ;;
  *) bad "r3 spend: refusal missing --spend-ok hint: $(printf '%s' "$out" | head -4)" ;;
esac
grep -q '"kind":"approval"' "$OSRC_HOME/lanes/events.jsonl" 2>/dev/null \
  && ok "r3 spend: EVENT approval persisted to lanes/events.jsonl" \
  || bad "r3 spend: events.jsonl missing approval event"

# --spend-ok consents THIS command only: OSRC_SPEND_OK set AFTER sourcing (what flag parsing
# does) lets the gate proceed; a fresh command without it refuses again. (Env-inherited
# OSRC_SPEND_OK is sanitized by the env block — proven by the dedicated test below.)
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
        OSRC_SPEND_OK=1; _osrc_spend_gate or some-model or "test" 2>&1 </dev/null' )"; rc=$?
[ $rc -eq 0 ] && ok "r3 spend: --spend-ok (OSRC_SPEND_OK=1) consents this command" || bad "r3 spend: consented gate rc=$rc: $out"
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1
        _osrc_spend_gate or some-model or "test" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && ok "r3 spend: consent does NOT persist to the next command" || bad "r3 spend: consent leaked into next command"

# Env-inherited OSRC_SPEND_OK must be sanitized by the engine env block BEFORE parsing.
b=$( OSRC_SPEND_OK=1 OSRC_SOURCED=1 bash -c '. "'"$SRC"'" >/dev/null 2>&1; printf "%s" "${OSRC_SPEND_OK:-unset}"' )
[ "$b" = "unset" ] && ok "r3 spend: env OSRC_SPEND_OK is unset by the env block (cannot imply consent)" \
  || bad "r3 spend: env OSRC_SPEND_OK survived sourcing ('$b')"
# .spend-ok job marker consents (the bg one-command channel) — r3.2: accepted ONLY for a
# real job child: dir directly under $OSRC_JOBS, OSRC_JOB_TOKEN matching the marker's
# header, and an EXACT lane|model pair (never "*", never empty). Runs in the
# already-sourced shell with env-prefixes exactly as the detached child's gate reads them.
JD="$OSRC_HOME/jobs/r3job"; mkdir -p "$JD"
_mkmark() {  # <dir> <token> <pairs...>
  local d="$1" t="$2"; shift 2
  { printf '#osrc-spend-ok token=%s\n' "$t"; printf '%s\n' "$@"; } > "$d/.spend-ok"
}
# Wildcard and empty-model fields authorize NOTHING anymore.
_mkmark "$JD" tokA 'or|*'
out="$( OSRC_JOB_DIR="$JD" OSRC_JOB_TOKEN=tokA _osrc_spend_gate or some-model or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && ok "r3.2 spend: wildcard lane|* marker consents nothing" || bad "r3.2 spend: wildcard marker leaked consent (rc=$rc)"
_mkmark "$JD" tokA 'or|'
out="$( OSRC_JOB_DIR="$JD" OSRC_JOB_TOKEN=tokA _osrc_spend_gate or some-model or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && ok "r3.2 spend: empty-model marker consents nothing" || bad "r3.2 spend: empty-model marker leaked (rc=$rc)"
# Exact pair + matching token -> consent, and the gate consumes (deletes) the marker.
_mkmark "$JD" tokA 'or|some-model'
out="$( OSRC_JOB_DIR="$JD" OSRC_JOB_TOKEN=tokA _osrc_spend_gate or some-model or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -eq 0 ] && ok "r3.2 spend: exact lane|model marker + job token consents" || bad "r3.2 spend: exact marker rc=$rc: $out"
[ ! -f "$JD/.spend-ok" ] && ok "r3.2 spend: marker consumed after dispatch" || bad "r3.2 spend: marker survived dispatch"
# Wrong token (a sibling job's secret, or a forged env) consents nothing.
_mkmark "$JD" tokB 'or|some-model'
out="$( OSRC_JOB_DIR="$JD" OSRC_JOB_TOKEN=tokA _osrc_spend_gate or some-model or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && ok "r3.2 spend: token mismatch consents nothing" || bad "r3.2 spend: wrong-token consent leaked (rc=$rc)"
# No token at all -> nothing (an arbitrary OSRC_JOB_DIR alone is not a job child).
out="$( OSRC_JOB_DIR="$JD" _osrc_spend_gate or some-model or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && ok "r3.2 spend: OSRC_JOB_DIR without OSRC_JOB_TOKEN consents nothing" || bad "r3.2 spend: tokenless dir consented (rc=$rc)"
# A marker dir OUTSIDE $OSRC_JOBS is never honored, even with a valid-looking header.
OUTJ="$TMP/notjobs"; mkdir -p "$OUTJ"; _mkmark "$OUTJ" tokA 'or|some-model'
out="$( OSRC_JOB_DIR="$OUTJ" OSRC_JOB_TOKEN=tokA _osrc_spend_gate or some-model or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && ok "r3.2 spend: marker outside \$OSRC_JOBS consents nothing" || bad "r3.2 spend: out-of-tree marker consented (rc=$rc)"
# Nested/traversal job dirs are not "this job" either.
NEST="$OSRC_HOME/jobs/a/b"; mkdir -p "$NEST"; _mkmark "$NEST" tokA 'or|some-model'
out="$( OSRC_JOB_DIR="$NEST" OSRC_JOB_TOKEN=tokA _osrc_spend_gate or some-model or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && ok "r3.2 spend: nested job dir consents nothing" || bad "r3.2 spend: nested dir consented (rc=$rc)"
# Binding still holds inside the trusted context: lane `or` marker does NOT authorize `dv`,
# and a model-bound marker does not cover a different model on the same lane.
_mkmark "$JD" tokA 'or|some-model'
out="$( OSRC_JOB_DIR="$JD" OSRC_JOB_TOKEN=tokA bash -c '. "'"$SRC"'" >/dev/null 2>&1; _devin_catalog_free_ids() { return 1; }; _osrc_spend_gate dv glm-5.2 dv "test"' 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && ok "r3.2 spend: or-marker does not authorize the dv lane" || bad "r3.2 spend: cross-lane consent leaked (rc=$rc)"
out="$( OSRC_JOB_DIR="$JD" OSRC_JOB_TOKEN=tokA _osrc_spend_gate or hy3 or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && ok "r3.2 spend: model-bound marker does not cover a different model" || bad "r3.2 spend: cross-model consent leaked (rc=$rc)"
_mkmark "$JD" tokA 'or|hy3'
out="$( OSRC_JOB_DIR="$JD" OSRC_JOB_TOKEN=tokA _osrc_spend_gate or hy3 or "test" 2>&1 </dev/null )"; rc=$?
[ $rc -eq 0 ] && ok "r3.2 spend: exact lane|model marker consents (second pair)" || bad "r3.2 spend: exact marker rc=$rc: $out"
rm -f "$JD/.spend-ok"

# Fallback pickers never select a metered lane quietly: only `or` ready -> no pick;
# with spend consent the same list picks it.
fb="$( _fallback_lane_ready() { [ "$1" = or ] && return 0; return 1; }
        _osrc_lane_spendable or m || true
        _fallback_pick "" "alias|model|or" )"
[ -z "$fb" ] && ok "r3 spend: fallback refuses to pick metered or without consent" || bad "r3 spend: fallback picked '$fb'"
fb="$( _fallback_lane_ready() { [ "$1" = or ] && return 0; return 1; }
        OSRC_SPEND_OK=1 _fallback_pick "" "alias|model|or" )"
[ "$fb" = "alias|model|or" ] && ok "r3 spend: --spend-ok lets fallback reach the paid lane" || bad "r3 spend: consented fallback -> '$fb'"
# Same for the limit-gate's own suggestion helper: paid-only -> nothing without consent, or with it.
fb="$( HOME="$FH0"; _fallback_lane_ready() { [ "$1" = or ] && return 0; return 1; }
        _lane_ready_probe() { return 1; }
        _devin_catalog_free_ids() { return 1; }; _timeout() { return 1; }
        OSRC_SPEND_OK=1 _osrc_limit_fallback "codexwk=98" )"
[ "$fb" = "or" ] && ok "r3 spend: consented limit-fallback may name the paid lane" || bad "r3 spend: consented limit-fallback -> '$fb'"
# Subscription lane still picked without consent (control).
fb="$( _fallback_lane_ready() { [ "$1" = local ] && return 0; return 1; }
        _fallback_pick "" "a1|m1|local
a2|m2|or" )"
[ "$fb" = "a1|m1|local" ] && ok "r3 spend: free lane still picked first without consent" || bad "r3 spend: free pick -> '$fb'"

# ---------------------------------------------------------------------------------------------------
# ROUND 3 — ADD-ON 2: per-lane usage caps. --cap parsing shape, standing lane cap persistence,
# pre-launch gate, supervise-poll EVENT limit (once), session-send wrap-up pass.
# ---------------------------------------------------------------------------------------------------
type -t _osrc_cap_gate >/dev/null || { echo "FAIL: _osrc_cap_gate not defined"; exit 1; }
type -t _osrc_cap_poll >/dev/null || { echo "FAIL: _osrc_cap_poll not defined"; exit 1; }
type -t cmd_lane >/dev/null || { echo "FAIL: cmd_lane not defined"; exit 1; }
# L7 lane verb handlers carry osrc_lane_<verb> names; cmd_lane itself is owned by L2
# (lib/remote.sh) and dispatches cap|billing|summary|limits to them. CLI words pinned here.
for _vf in osrc_lane_cap osrc_lane_limits osrc_lane_billing osrc_lane_summary; do
  type -t "$_vf" >/dev/null || { echo "FAIL: $_vf not defined (osrc_lane_* verb surface)"; exit 1; }
done
unset _vf

# Spec validation + window mapping.
_osrc_cap_valid 'weekly<=40' && ok "r3 cap: weekly<=40 valid" || bad "r3 cap: weekly<=40 rejected"
_osrc_cap_valid 'bogus' && bad "r3 cap: bogus spec accepted" || ok "r3 cap: bogus spec rejected"
_osrc_cap_valid 'weekly<40' && bad "r3 cap: < (not <=) accepted" || ok "r3 cap: < rejected"
[ "$(_osrc_cap_window cx weekly)" = "codexwk" ] && ok "r3 cap: cx weekly -> codexwk" || bad "r3 cap: cx weekly window wrong"
[ "$(_osrc_cap_window cc 5h)" = "claude5h" ] && ok "r3 cap: cc 5h -> claude5h" || bad "r3 cap: cc 5h window wrong"
[ "$(_osrc_cap_window cx codex5h)" = "codex5h" ] && ok "r3 cap: raw window name passes through" || bad "r3 cap: raw window failed"

# _osrc_cap_tripped: under-cap clear, at-cap trips with now value.
_session_limits() { printf 'codexwk=31 codex5h=12\n'; }; _reset_snap
_osrc_cap_tripped cx "codexwk=31 codex5h=12" >/dev/null 2>&1 \
  && bad "r3 cap: un capped cx tripped" || ok "r3 cap: no caps -> clear"
hit="$( OSRC_CAPS='weekly<=40' _osrc_cap_tripped cx 'codexwk=31 codex5h=12' 2>/dev/null )"
[ -z "$hit" ] && ok "r3 cap: under-cap (31 < 40) does not trip" || bad "r3 cap: under-cap tripped: $hit"
hit="$( OSRC_CAPS='weekly<=40' _osrc_cap_tripped cx 'codexwk=41 codex5h=12' 2>/dev/null )"
case "$hit" in *"weekly<=40 now41"*) ok "r3 cap: at/over-cap trips with now value" ;; *) bad "r3 cap: over-cap hit='$hit'" ;; esac
hit="$( OSRC_CAPS='5h<=10' _osrc_cap_tripped cc 'claude5h=11 claude7d=5' 2>/dev/null )"
case "$hit" in *"5h<=10 now11"*) ok "r3 cap: cc 5h cap binds claude5h" ;; *) bad "r3 cap: cc 5h hit='$hit'" ;; esac

# lane cap persistence: set writes lane-caps, clear removes the lane's rows.
CF="$OSRC_HOME/lane-caps"; rm -f "$CF"
( OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 bash -c '. "'"$SRC"'" >/dev/null 2>&1; cmd_lane cap cx "weekly<=40"; cmd_lane cap cc "5h<=80"' ) >/dev/null 2>&1
grep -q '^cx weekly<=40$' "$CF" && grep -q '^cc 5h<=80$' "$CF" \
  && ok "r3 cap: lane cap persists standing caps" || bad "r3 cap: lane-caps file wrong: $(cat "$CF" 2>/dev/null)"
# Standing cap now trips the gate for cx even without --cap.
hit="$( _osrc_cap_tripped cx 'codexwk=45 codex5h=10' 2>/dev/null )"
case "$hit" in *"weekly<=40 now45"*) ok "r3 cap: standing cap enforced" ;; *) bad "r3 cap: standing cap not enforced: '$hit'" ;; esac
( OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 bash -c '. "'"$SRC"'" >/dev/null 2>&1; cmd_lane cap cx --clear' ) >/dev/null 2>&1
grep -q '^cx ' "$CF" && bad "r3 cap: --clear left cx rows" || ok "r3 cap: lane cap --clear removes the lane"
grep -q '^cc 5h<=80$' "$CF" && ok "r3 cap: --clear is per-lane (cc cap survives)" || bad "r3 cap: --clear removed other lanes"

# Pre-launch cap gate: pinned refuses loudly naming cap + raise/clear; unpinned auto hops.
_session_limits() { printf 'codexwk=45\n'; }; _reset_snap
out="$( _fallback_enabled() { return 1; }
        OSRC_CAPS='weekly<=40' _fb_user_pinned=1 MODEL_EXPLICIT=1 RESOLVED_ID=x PROVIDER=devin tier=edit \
        _osrc_cap_gate cx x cxnative 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"cap gate"*"weekly<=40"*"lane cap"*) ok "r3 cap: pinned at-cap refuses naming cap + commands" ;;
  *) bad "r3 cap: pinned refusal wrong (rc=$rc): $(printf '%s' "$out" | head -4)" ;;
esac
# Under-cap pinned proceeds rc0.
_session_limits() { printf 'codexwk=20\n'; }; _reset_snap
( OSRC_CAPS='weekly<=40' _fb_user_pinned=1 _osrc_cap_gate cx x cxnative >/dev/null 2>&1 ) \
  && ok "r3 cap: under-cap launch proceeds" || bad "r3 cap: under-cap blocked"

# Supervise poll: one EVENT limit per job+spec; second poll silent.
rm -f "$OSRC_HOME/lanes/events.jsonl"
JD2="$OSRC_HOME/jobs/r3poll"; mkdir -p "$JD2"; OSRC_JOB_DIR="$JD2"
_session_limits() { printf 'codexwk=45\n'; }; _reset_snap
OSRC_CAPS='weekly<=40' _osrc_cap_poll r3poll cx "" >/dev/null 2>&1
OSRC_CAPS='weekly<=40' _osrc_cap_poll r3poll cx "" >/dev/null 2>&1   # dedupe: same spec -> silent
unset OSRC_CAPS
grep -c '"kind":"limit"' "$OSRC_HOME/lanes/events.jsonl" 2>/dev/null | grep -q '^1$' \
  && ok "r3 cap: supervise poll emits exactly ONE EVENT limit per job+cap" \
  || bad "r3 cap: poll events=$(grep -c '"kind":"limit"' "$OSRC_HOME/lanes/events.jsonl" 2>/dev/null)"
grep -q 'cap:weekly<=40 now:45' "$OSRC_HOME/lanes/events.jsonl" 2>/dev/null \
  && ok "r3 cap: EVENT limit carries cap:<spec> now:<pct>" || bad "r3 cap: event detail wrong"
unset OSRC_JOB_DIR
unset OSRC_CAPS

# session send: wrap-up passes, new work refused at cap.
_osrc_cap_send_ok "wrap up now" && ok "r3 cap: wrap-up text passes send gate" || bad "r3 cap: wrap-up refused"
_osrc_cap_send_ok "please finish the refactor" && ok "r3 cap: finish text passes" || bad "r3 cap: finish refused"
_osrc_cap_send_ok "add a new endpoint for billing" && bad "r3 cap: new work passed send gate" || ok "r3 cap: new work refused"
_osrc_cap_send_ok "mark the task done and also write tests" && bad "r3 cap: mixed work passed" || ok "r3 cap: mixed new-work refused"

# ---------------------------------------------------------------------------------------------------
# ROUND 3b — limits summary feed (Mission Control "Lanes and limits" / L9 hub export):
# ONE record per DETECTED harness (CLI on PATH AND login/plan/key provable), id = provider id,
# unknown limits are honest (state unknown / left "not checked yet"), caps surface as `cap`,
# and gemini-cli is NEVER listed even when a `gemini` binary sits on PATH.
# ---------------------------------------------------------------------------------------------------
type -t osrc_lane_summary >/dev/null || { echo "FAIL: osrc_lane_summary not defined"; exit 1; }
type -t _osrc_harness_detected >/dev/null || { echo "FAIL: _osrc_harness_detected not defined"; exit 1; }
have python3 || { echo "FAIL: python3 needed for JSON assertions"; exit 1; }

SUM="$TMP/summary"; mkdir -p "$SUM/bin" "$SUM/home" "$SUM/home-empty"
# Stub CLIs: installed == stub on PATH. devin answers `auth status`; the rest exit 0 quietly.
for c in claude codex agy droid cursor-agent oz cline pi hermes gemini warp; do
  printf '#!/bin/sh\nexit 0\n' > "$SUM/bin/$c"; chmod +x "$SUM/bin/$c"
done
cat > "$SUM/bin/devin" <<'EOF'
#!/bin/sh
# Logged in iff THIS home's devin auth file exists — installed-but-logged-out must not detect.
case "$*" in *"auth status"*) [ -f "$HOME/.devin/auth.json" ] && echo "logged in";; esac
exit 0
EOF
chmod +x "$SUM/bin/devin"
cat > "$SUM/bin/claude" <<'EOF'
#!/bin/sh
# `auth status` answers a claude.ai plan login (fake values) ONLY when this home's
# credentials file exists — installed-but-logged-out must not detect. Billing proof
# for the feed's paid flag comes from this same JSON.
case "$*" in *"auth status"*) [ -f "$HOME/.claude/.credentials.json" ] && printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max","storedClaudeAiLogin":true}';; esac
exit 0
EOF
chmod +x "$SUM/bin/claude"
# Auth fixtures in $SUM/home: claude creds, codex auth.json, antigravity dir, factory auth file,
# devin auth file. $SUM/home-empty gets NONE of them.
mkdir -p "$SUM/home/.claude" "$SUM/home/.codex" "$SUM/home/.antigravity" "$SUM/home/.factory" "$SUM/home/.devin"
printf '{}' > "$SUM/home/.claude/.credentials.json"
printf '{"tokens":{"id_token":"x"}}' > "$SUM/home/.codex/auth.json"
printf '{}' > "$SUM/home/.factory/auth.json"
printf '{}' > "$SUM/home/.devin/auth.json"

# _sumjson <home> <bindir> [VAR=val ...] -> osrc_lane_summary --json under a fully
# hermetic env (env -i): fake HOME, stub-only PATH, OSRC_PLATFORM=linux (skips the real
# macOS keychain probe), local-inference probe stubbed off (no localhost flakiness).
_sumjson() {
  local fh="$1" fb="$2"; shift 2
  env -i HOME="$fh" PATH="$fb:/usr/bin:/bin" OSRC_PLATFORM=linux OSRC_HOME="$OSRC_HOME" \
      OSRC_SOURCED=1 TERM=dumb "$@" \
      bash -c '. "$1"; _ready_probe_local() { return 1; }; _OSRC_LIMITS_SNAP=""; _OSRC_LIMITS_SNAP_TS=0; osrc_lane_summary --json' _ "$SRC" 2>/dev/null
}
_sumtext() {
  local fh="$1" fb="$2"; shift 2
  env -i HOME="$fh" PATH="$fb:/usr/bin:/bin" OSRC_PLATFORM=linux OSRC_HOME="$OSRC_HOME" \
      OSRC_SOURCED=1 TERM=dumb "$@" \
      bash -c '. "$1"; _ready_probe_local() { return 1; }; _OSRC_LIMITS_SNAP=""; _OSRC_LIMITS_SNAP_TS=0; osrc_lane_summary' _ "$SRC" 2>/dev/null
}
# _jget <json> <python-expr-on-d> -> prints result (d = parsed list).
_jget() { python3 -c 'import json,sys
d=json.load(sys.stdin)
'"$2" <<< "$1"; }

# Empty home: every CLI installed but logged out -> ZERO records (never a fixed registry dump).
J="$(_sumjson "$SUM/home-empty" "$SUM/bin")"
[ "$J" = "[]" ] && ok "r3 feed: installed-but-logged-out -> empty list (no guesses)" \
  || bad "r3 feed: empty-home JSON='$J'"

# Authenticated home: detected harnesses only, provider-id keys, gemini-cli absent.
J="$(_sumjson "$SUM/home" "$SUM/bin")"
printf '%s' "$J" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d,list) and d' \
  && ok "r3 feed: --json emits a non-empty valid array" || bad "r3 feed: invalid JSON: $J"
for id in claude codex agy devin droid; do
  printf '%s' "$J" | grep -q "\"id\":\"$id\"" \
    && ok "r3 feed: detected harness '$id' present" || bad "r3 feed: '$id' missing from $J"
done
for id in cursor gemini local warp cline pi hermes grokbot; do
  printf '%s' "$J" | grep -q "\"id\":\"$id\"" \
    && bad "r3 feed: '$id' listed without provable auth" || ok "r3 feed: '$id' correctly absent"
done
# Unknown meters are honest: no fake percentages anywhere.
printf '%s' "$J" | grep -q '"left":"not checked yet"' \
  && ok "r3 feed: unmetered harnesses report 'not checked yet'" || bad "r3 feed: no honest-unknown left field"
_jget "$J" 'print(sum(1 for r in d if r["state"]=="unknown"))' | grep -q '^5$' \
  && ok "r3 feed: no fresh meter -> all five detected harnesses state=unknown" \
  || bad "r3 feed: unexpected unknown-state count: $(_jget "$J" 'print([r["id"]+":"+r["state"] for r in d])')"

# Metered state: OSRC_CC_PRESSURE feeds claude5h -> low at 62, out at 95.
J62="$(_sumjson "$SUM/home" "$SUM/bin" OSRC_CC_PRESSURE=62)"
_row="$(_jget "$J62" 'import json; print(json.dumps(next(r for r in d if r["id"]=="claude")))')"
case "$_row" in
  *'"state": "low"'*) ;; *) bad "r3 feed: claude@62 state not low: $_row"; _row="" ;; esac
[ -n "$_row" ] && printf '%s' "$_row" | grep -q '38% left' \
  && ok "r3 feed: claude@62 -> low, '38% left'" || { [ -n "$_row" ] && bad "r3 feed: claude@62 left wrong: $_row"; }
J95="$(_sumjson "$SUM/home" "$SUM/bin" OSRC_CC_PRESSURE=95)"
_row="$(_jget "$J95" 'import json; print(json.dumps(next(r for r in d if r["id"]=="claude")))')"
printf '%s' "$_row" | grep -q '"state": "out"' \
  && ok "r3 feed: claude@95 -> out" || bad "r3 feed: claude@95 state wrong: $_row"

# Caps surface: standing lane cap + per-launch --cap spec both land in the `cap` field.
printf 'cc weekly<=40\n' > "$OSRC_HOME/lane-caps"
J="$(_sumjson "$SUM/home" "$SUM/bin" OSRC_CC_PRESSURE=62)"
_row="$(_jget "$J" 'import json; print(json.dumps(next(r for r in d if r["id"]=="claude")))')"
printf '%s' "$_row" | grep -q 'weekly<=40' \
  && ok "r3 feed: standing cap renders in cap field" || bad "r3 feed: standing cap missing: $_row"
J="$(_sumjson "$SUM/home" "$SUM/bin" OSRC_CC_PRESSURE=62 OSRC_CAPS='5h<=80')"
_row="$(_jget "$J" 'import json; print(json.dumps(next(r for r in d if r["id"]=="claude")))')"
printf '%s' "$_row" | grep -q '5h<=80' \
  && ok "r3 feed: per-launch --cap renders in cap field" || bad "r3 feed: per-launch cap missing: $_row"
rm -f "$OSRC_HOME/lane-caps"

# Tripped cap -> state out (dispatch would refuse). OSRC_CC_PRESSURE feeds claude5h only,
# so the caps must bind the 5h window — a weekly cap has no reading to evaluate and honestly
# cannot trip.
printf 'cc 5h<=70\n' > "$OSRC_HOME/lane-caps"
J="$(_sumjson "$SUM/home" "$SUM/bin" OSRC_CC_PRESSURE=62 OSRC_CAPS='5h<=50')"
_row="$(_jget "$J" 'import json; print(json.dumps(next(r for r in d if r["id"]=="claude")))')"
printf '%s' "$_row" | grep -q '"state": "out"' \
  && ok "r3 feed: tripped cap flips state to out" || bad "r3 feed: cap-tripped state wrong: $_row"
rm -f "$OSRC_HOME/lane-caps"

# paid tag: subscription billing -> paid false.
_row="$(_jget "$J62" 'import json; print(json.dumps(next(r for r in d if r["id"]=="claude")))')"
printf '%s' "$_row" | grep -q '"paid": false' \
  && ok "r3 feed: subscription lane paid=false" || bad "r3 feed: claude paid flag wrong: $_row"

# Text form prints the same table; cmd_lane summary dispatch works (L2 owns cmd_lane in
# lib/remote.sh; `lane limits` is the billing+caps table, `lane summary` is this feed).
T="$(_sumtext "$SUM/home" "$SUM/bin")"
printf '%s' "$T" | grep -q '^ID .*STATE' && printf '%s' "$T" | grep -q 'claude' \
  && ok "r3 feed: text table renders detected harnesses" || bad "r3 feed: text table wrong: $T"
CJ="$(env -i HOME="$SUM/home" PATH="$SUM/bin:/usr/bin:/bin" OSRC_PLATFORM=linux OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 TERM=dumb bash -c '. "$1"; _ready_probe_local() { return 1; }; cmd_lane summary --json' _ "$SRC" 2>/dev/null)"
printf '%s' "$CJ" | python3 -c 'import json,sys; json.load(sys.stdin)' \
  && ok "r3 feed: cmd_lane summary --json emits valid JSON" || bad "r3 feed: cmd_lane summary failed: $CJ"

# ---------------------------------------------------------------------------------------------------
# ROUND 3.1 — verdict L7-r3 remediation. One test per "To get to MERGE" item, command-level
# where the verdict demanded it (items 1,3,4,5) and function-level for the classifier rows,
# marker binding, cap guards and per-session dedupe.
# ---------------------------------------------------------------------------------------------------

# ITEM 1 (billing rows the verdict drove): cx OPENAI_BASE_URL / CODEX_API_KEY -> metered;
# codex CLI with no auth.json and no login proof -> unknown; agy CLI without ~/.antigravity
# -> unknown; cloud vehicle on ANY lane -> metered; empty lane -> unknown -> gate refuses.
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; OPENAI_BASE_URL=https://x.test osrc_lane_billing cx; CODEX_API_KEY=k osrc_lane_billing cx' )
case "$b" in metered$'\n'metered) ok "r3.1 billing: cx OPENAI_BASE_URL + CODEX_API_KEY -> metered" ;; *) bad "r3.1 billing: cx redirects -> '$b'" ;; esac
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = codex ] && return 0; command -v "$1" >/dev/null 2>&1; }; _timeout() { return 1; }; osrc_lane_billing cx' )
[ "$b" = "unknown" ] && ok "r3.1 billing: codex CLI, no auth.json/login proof -> unknown" || bad "r3.1 billing: cx cli-only -> '$b'"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = agy ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing gm' )
[ "$b" = "unknown" ] && ok "r3.1 billing: agy CLI without ~/.antigravity -> unknown" || bad "r3.1 billing: gm cli-only -> '$b'"
# r9 class-check: ~/.antigravity dir + per-use key evidence -> metered; dir alone -> subscription.
mkdir -p "$HB/.antigravity"; printf '{"auth":"session"}' > "$HB/.antigravity/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = agy ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing gm' )
[ "$b" = "subscription" ] && ok "r9 billing: agy auth dir, no key material -> subscription" || bad "r9 billing: agy plain-auth -> '$b'"
printf '{"apiKey":"gemini-key-abcdef123456"}' > "$HB/.antigravity/auth.json"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; have() { [ "$1" = agy ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing gm' )
[ "$b" = "metered" ] && ok "r9 billing: agy auth dir apiKey -> metered" || bad "r9 billing: agy dir-key -> '$b'"
rm -rf "$HB/.antigravity"
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; GEMINI_API_KEY=x osrc_lane_billing gm; GOOGLE_API_KEY=y osrc_lane_billing gm' )
case "$b" in metered$'\n'metered) ok "r9 billing: agy + GEMINI/GOOGLE_API_KEY -> metered" ;; *) bad "r9 billing: agy env keys -> '$b'" ;; esac
b=$( HOME="$HB" bash -c '. "'"$SRC"'" >/dev/null 2>&1; osrc_lane_billing or m cloud; osrc_lane_billing cc m cloud' )
case "$b" in metered$'\n'metered) ok "r3.1 billing: cloud vehicle -> metered on any lane" ;; *) bad "r3.1 billing: cloud disp -> '$b'" ;; esac
out="$( HOME="$HB" OSRC_HOME="$OSRC_HOME" bash -c '. "'"$SRC"'" >/dev/null 2>&1; _osrc_spend_gate "" "" "" "empty-lane probe" 2>&1 </dev/null' )"; rc=$?
[ $rc -ne 0 ] && ok "r3.1 spend: empty lane refuses (unconditional gate, billing=unknown)" || bad "r3.1 spend: empty lane dispatched (rc=$rc)"

# ITEM 3 (env kill-switches): exported OSRC_SPEND_GATE=0 / OSRC_CAP_GATE=0 must NOT reach the
# gates — the env block unsets them before parsing. Command-level: a metered route still refuses.
out="$( PATH="$FAKEBIN:$PATH" HOME="$HB" OSRC_HOME="$OSRC_HOME" OSRC_SOURCED= OSRC_CLOUD_ACK=1 \
    OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 ANTHROPIC_API_KEY=sk-test \
    OSRC_SPEND_GATE=0 OSRC_CAP_GATE=0 \
    bash "$SRC" --osrc-preflight-internal run --provider cc "hi" 2>&1 )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"spend gate"*|*"EVENT approval"*) ok "r3.1 env: OSRC_SPEND_GATE=0 exported still refuses metered route" ;;
  *) bad "r3.1 env: gate bypassed or wrong refusal (rc=$rc): $(printf '%s' "$out" | head -5)" ;;
esac

# ITEM 5a (bg forwards EVENT + runnable NEXT): the preflight refusal lines reach the caller.
# Dedicated OSRC_HOME: the shared test home already holds r3job/r3poll dirs, so "no job
# minted" is only provable against a clean jobs tree.
BH="$TMP/bhhome"; BGCWD2="$TMP/bgcwd2"; mkdir -p "$BH" "$BGCWD2"
out="$( cd "$BGCWD2" && PATH="$FAKEBIN:$PATH" HOME="$HB" OSRC_HOME="$BH" OSRC_SOURCED= \
    OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 ANTHROPIC_API_KEY=sk-test \
    bash "$SRC" bg run --provider cc "hi" 2>&1 )"; rc=$?
[ $rc -ne 0 ] && case "$out" in
  *"EVENT approval"*"paid-lane"*) ok "r3.1 bg: refusal forwards EVENT approval" ;;
  *) bad "r3.1 bg: no EVENT approval forwarded (rc=$rc): $(printf '%s' "$out" | head -5)" ;;
esac
case "$out" in
  *"NEXT "*"--spend-ok"*) ok "r3.1 bg: refusal forwards runnable NEXT with --spend-ok" ;;
  *) bad "r3.1 bg: NEXT missing/not runnable: $(printf '%s' "$out" | grep -a 'NEXT' | head -2)" ;;
esac
if [ -d "$BH/jobs" ] && [ -n "$(ls -A "$BH/jobs" 2>/dev/null)" ]; then
  bad "r3.1 bg: refused launch still minted a job: $(ls "$BH/jobs")"
else
  ok "r3.1 bg: refused launch minted no job"
fi

# ITEM 5b+4 (consent reaches the detached child as argv; marker is lane|model-bound):
# bg --spend-ok consents THIS command, preflight re-injects it as argv, and _bg_launch drops
# the bound marker. Job id on stdout proves the whole chain; the child runs against stubs.
out="$( cd "$BGCWD2" && PATH="$FAKEBIN:$PATH" HOME="$HB" OSRC_HOME="$BH" OSRC_SOURCED= \
    OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 ANTHROPIC_API_KEY=sk-test \
    bash "$SRC" bg run --spend-ok --provider cc "hi" 2>&1 )"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -qE '^[A-Za-z0-9_-]+$' \
  && ok "r3.1 bg: --spend-ok consents through preflight and mints a job" \
  || bad "r3.1 bg: --spend-ok did not mint (rc=$rc): $(printf '%s' "$out" | head -5)"
# The marker writer emits the token header + bound EXACT lane|model pairs (never "*") for
# the consenting command's resolution; without OSRC_JOB_TOKEN it writes nothing.
MKD="$OSRC_HOME/jobs/markerjob"; mkdir -p "$MKD"
# OSRC_SPEND_OK/OSRC_JOB_TOKEN must be set AFTER sourcing — the env block unsets inherited
# consent by design.
( OSRC_SOURCED=1 bash -c '. "'"$SRC"'" >/dev/null 2>&1
    OSRC_SPEND_OK=1 OSRC_JOB_TOKEN=tokW; _osrc_spend_marker_write "'"$MKD"'" cc run --provider cc -m glm-5.2' >/dev/null 2>&1 )
[ -f "$MKD/.spend-ok" ] && head -1 "$MKD/.spend-ok" | grep -q 'token=tokW' \
  && ! grep -q '|\*' "$MKD/.spend-ok" && grep -q '|' "$MKD/.spend-ok" \
  && ok "r3.2 marker: .spend-ok carries token header + exact pairs ($(tail -1 "$MKD/.spend-ok" 2>/dev/null))" \
  || bad "r3.2 marker: .spend-ok missing token/exact pairs: $(cat "$MKD/.spend-ok" 2>/dev/null)"
rm -f "$MKD/.spend-ok"
( OSRC_SOURCED=1 bash -c '. "'"$SRC"'" >/dev/null 2>&1
    OSRC_SPEND_OK=1; _osrc_spend_marker_write "'"$MKD"'" cc run --provider cc -m glm-5.2' >/dev/null 2>&1 )
[ ! -e "$MKD/.spend-ok" ] \
  && ok "r3.2 marker: no OSRC_JOB_TOKEN -> no marker written" \
  || bad "r3.2 marker: tokenless write produced a marker"
rm -f "$MKD/.spend-ok"
# And OSRC_JOB_DIR + OSRC_JOB_TOKEN are scrubbed from delegate environments
# (_run_tee_stderr choke point + the per-lane env -u spawn lists).
leak="$( OSRC_JOB_DIR="$MKD" OSRC_JOB_TOKEN=tokW _run_tee_stderr /dev/null env 2>/dev/null | grep -cE '^(OSRC_JOB_DIR|OSRC_JOB_TOKEN)=' )"
[ "$leak" = "0" ] && ok "r3.2 env: delegates never inherit OSRC_JOB_DIR/OSRC_JOB_TOKEN" || bad "r3.2 env: job consent env leaked to delegate ($leak)"

# Interactive y/N consent (pty via script): 'y' approves THIS command and prints the
# OSRC_SPEND_CONSENT token bg's preflight greps for; 'n'/EOF refuses.
PTYBIN="$(command -v script 2>/dev/null || echo /usr/bin/script)"
out="$( { sleep 2; printf 'y\n'; sleep 0.5; } | HOME="$HB" OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 \
    "$PTYBIN" -q /dev/null bash -c '. "'"$SRC"'" >/dev/null 2>&1; _osrc_spend_gate or somemodel or "tty test"' 2>&1 )"
case "$out" in
  *OSRC_SPEND_CONSENT=1*"approved"*) ok "r3.1 spend: interactive y consents this command only" ;;
  *) bad "r3.1 spend: interactive y path broken: $(printf '%s' "$out" | tail -4)" ;;
esac
out="$( { sleep 2; printf 'n\n'; sleep 0.5; } | HOME="$HB" OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 \
    "$PTYBIN" -q /dev/null bash -c '. "'"$SRC"'" >/dev/null 2>&1; _osrc_spend_gate or somemodel or "tty test"' 2>&1 )"
case "$out" in
  *"EVENT approval"*|*"declined"*) ok "r3.1 spend: interactive n refuses with EVENT approval" ;;
  *) bad "r3.1 spend: interactive n did not refuse: $(printf '%s' "$out" | tail -4)" ;;
esac

# ITEM 6 (caps): unbound meters refuse at `lane cap` time; invalid specs refuse; the
# provider-name lookup (`lane cap codex`) resolves; unread meters warn (unpinned) / refuse (pinned);
# dedupe markers are per-session and --clear removes them.
( OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 bash -c '. "'"$SRC"'" >/dev/null 2>&1; cmd_lane cap dv "weekly<=40"' ) >/dev/null 2>&1 \
  && bad "r3.1 cap: lane cap dv weekly<=40 accepted an unbindable meter" \
  || ok "r3.1 cap: lane cap dv weekly<=40 refused (no dv window)"
( OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 bash -c '. "'"$SRC"'" >/dev/null 2>&1; cmd_lane cap cx "bogus<=10"' ) >/dev/null 2>&1 \
  && bad "r3.1 cap: lane cap cx bogus<=10 accepted" \
  || ok "r3.1 cap: lane cap cx bogus<=10 refused (unbound meter)"
( OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 bash -c '. "'"$SRC"'" >/dev/null 2>&1; cmd_lane cap cx "weekly<=.."' ) >/dev/null 2>&1 \
  && bad "r3.1 cap: weekly<=.. accepted" \
  || ok "r3.1 cap: weekly<=.. refused (not a real number)"
CF2="$OSRC_HOME/lane-caps"; rm -f "$CF2"
( OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 bash -c '. "'"$SRC"'" >/dev/null 2>&1; cmd_lane cap codex "5h<=80"' ) >/dev/null 2>&1
grep -q '^cx 5h<=80$' "$CF2" \
  && ok "r3.1 cap: lane cap codex resolves provider name -> cx row" \
  || bad "r3.1 cap: lane cap codex wrote wrong row: $(cat "$CF2" 2>/dev/null)"
rm -f "$CF2"
# Unread meter: standing cx cap + NO meter reading -> unpinned warns but proceeds; pinned refuses.
printf 'cx weekly<=40\n' > "$CF2"
_session_limits() { printf '\n'; }; _reset_snap
out="$( _fb_user_pinned=0 _osrc_cap_gate cx x cxnative 2>&1 </dev/null )"; rc=$?
[ $rc -eq 0 ] && case "$out" in *"no fresh reading"*) ok "r3.1 cap: unread capped meter warns, unpinned proceeds" ;; *) bad "r3.1 cap: unread unpinned wrong (rc=$rc): $out" ;; esac
out="$( _fb_user_pinned=1 MODEL_EXPLICIT=1 _osrc_cap_gate cx x cxnative 2>&1 </dev/null )"; rc=$?
[ $rc -ne 0 ] && case "$out" in *"unverifiable cap"*|*"cap gate"*) ok "r3.1 cap: unread capped meter refuses under a pin" ;; *) bad "r3.1 cap: unread pinned wrong (rc=$rc): $out" ;; esac
rm -f "$CF2"
# Per-session dedupe: two sessions on the same lane+spec each get their EVENT; --clear removes markers.
rm -f "$OSRC_HOME/lanes/events.jsonl"
JD3="$OSRC_HOME/jobs"; mkdir -p "$JD3"
_session_limits() { printf 'codexwk=45\n'; }; _reset_snap
OSRC_CAPS='weekly<=40' _osrc_cap_poll sessA cx "" >/dev/null 2>&1
OSRC_CAPS='weekly<=40' _osrc_cap_poll sessB cx "" >/dev/null 2>&1
OSRC_CAPS='weekly<=40' _osrc_cap_poll sessA cx "" >/dev/null 2>&1   # same session+spec -> silent
unset OSRC_CAPS
n="$(grep -c '"kind":"limit"' "$OSRC_HOME/lanes/events.jsonl" 2>/dev/null)"
[ "$n" = "2" ] && ok "r3.1 cap: cap events dedupe per session, not globally" || bad "r3.1 cap: expected 2 session events, got $n"
( OSRC_HOME="$OSRC_HOME" OSRC_SOURCED=1 bash -c '. "'"$SRC"'" >/dev/null 2>&1; cmd_lane cap cx --clear' ) >/dev/null 2>&1
ls "$OSRC_HOME"/.caplimit.* "$OSRC_HOME"/jobs/*/.caplimit.* >/dev/null 2>&1 \
  && bad "r3.1 cap: --clear left caplimit markers" || ok "r3.1 cap: --clear removes cap-event markers"
_session_limits() { printf 'codexwk=31 codex5h=12\n'; }; _reset_snap


echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
