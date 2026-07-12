#!/usr/bin/env bash
# test_cloud_gate.sh — U1 conformance: cloud-disclosure + secret-scan gate.
# Loads the gate primitives from outsourcerer.sh and exercises them OFFLINE (no real
# delegation). Mirrors the scripts/tests/ shim-test style. Run: bash test_cloud_gate.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
if [ ! -f "$SRC" ]; then echo FAIL: cannot find $SRC; exit 1; fi

# Load the script's functions. main "$@" runs with no args (prints help, returns 0);
# all gate functions are then defined in this shell. set -u is inherited from the
# sourced file, so keep every expansion default-safe.
. "$SRC" >/dev/null 2>&1

pass=0; fail=0
ok()  { echo PASS: $1; pass=$((pass+1)); }
bad() { echo FAIL: $1; fail=$((fail+1)); }
cleanup() { rm -rf $TMP; }
trap cleanup EXIT

TMP="$(mktemp -d)"

# --- Scenario 1: local lanes classified non-cloud; skip the gate entirely. ---
if ! _is_cloud_lane "local" >/dev/null 2>&1; then ok "local lane classified non-cloud"; else bad "local lane mis-classified as cloud"; fi
if ! _is_cloud_lane "ollama" >/dev/null 2>&1 && ! _is_cloud_lane "lmstudio" >/dev/null 2>&1; then ok "ollama/lmstudio classified non-cloud"; else bad "ollama/lmstudio mis-classified as cloud"; fi
out="$( ( cd "$TMP"; unset OSRC_CLOUD_ACK OSRC_CLOUD_ACKED; _cloud_disclose "local" "llama3" "do thing" ) 2>&1 )"
[ $? -eq 0 ] && ok "non-cloud _cloud_disclose returns 0" || bad "non-cloud _cloud_disclose nonzero"
echo "$out" | grep -qi 'CLOUD' && bad "non-cloud lane printed a cloud disclosure" || ok "non-cloud lane prints no disclosure"

# --- Scenario 2: cloud lane, non-interactive, no ack => fail-closed REFUSE. ---
out="$( ( cd "$TMP"; unset OSRC_CLOUD_ACK OSRC_CLOUD_ACKED; _cloud_disclose "ccor" "gpt-4o" "summarize repo" ) </dev/null 2>&1 )"; rc=$?
[ $rc -ne 0 ] && ok "cloud no-ack non-interactive REFUSES (rc=$rc)" || bad "cloud no-ack non-interactive proceeded (rc=$rc)"
echo "$out" | grep -qi 'CLOUD GATE' && ok "refusal names CLOUD GATE" || bad "refusal missing CLOUD GATE marker"

# --- Scenario 3: cloud lane with OSRC_CLOUD_ACK=1 => proceeds + disclosure printed. ---
out="$( ( cd "$TMP"; unset OSRC_CLOUD_ACKED; OSRC_CLOUD_ACK=1; _cloud_disclose "ccor" "gpt-4o" "summarize repo" ) 2>&1 )"; rc=$?
[ $rc -eq 0 ] && ok "cloud with OSRC_CLOUD_ACK=1 proceeds (rc=0)" || bad "cloud ack path failed (rc=$rc)"
echo "$out" | grep -q 'CLOUD DISCLOSURE' && ok "disclosure block printed" || bad "disclosure block missing"
echo "$out" | grep -q 'repo content LEAVES' && ok "disclosure states data leaves machine" || bad "disclosure omits data-leaves note"

# --- Scenario 4: a real .env in cwd scope => hard die with the path, ack or not. ---
mkdir -p "$TMP/envscope"
printf 'OPENROUTER_API_KEY=sk-XXXX\n' > "$TMP/envscope/.env"
out="$( ( cd "$TMP/envscope"; unset OSRC_CLOUD_ACK OSRC_CLOUD_ACKED; OSRC_CLOUD_ACK=1; _cloud_disclose "ccor" "gpt-4o" "task" ) 2>&1 )"; rc=$?
[ $rc -ne 0 ] && ok "real .env in scope hard-dies (rc=$rc)" || bad "real .env in scope did NOT die"
echo "$out" | grep -q "$TMP/envscope/.env" && ok "die names the credential path" || bad "die omitted credential path"

# --- Scenario 5: ':free' route disclosure states may-train. ---
out="$( ( cd "$TMP"; unset OSRC_CLOUD_ACKED; OSRC_CLOUD_ACK=1; _cloud_disclose "ccor" "google/gemini-flash-1.5:free" "task" ) 2>&1 )"; rc=$?
[ $rc -eq 0 ] && ok "':free' route with ack proceeds" || bad "':free' route ack failed"
echo "$out" | grep -qi 'MAY TRAIN' && ok "':free' disclosure states may-train" || bad "':free' disclosure missing may-train note"

# --- Scenario 6: idempotency — acking once sets OSRC_CLOUD_ACKED for the process. ---
out="$( ( cd "$TMP"; unset OSRC_CLOUD_ACKED; OSRC_CLOUD_ACK=1
          _cloud_disclose "ccor" "gpt-4o" "t1"
          [ "${OSRC_CLOUD_ACKED:-0}" = "1" ] && echo ACKED_SET
          _cloud_disclose "ccor" "gpt-4o" "t2"
        ) 2>&1 )"; rc=$?
[ $rc -eq 0 ] && ok "second cloud call in-process passes after ack" || bad "second call re-prompted/failed"
echo "$out" | grep -q 'ACKED_SET' && ok "OSRC_CLOUD_ACKED set after first ack" || bad "OSRC_CLOUD_ACKED not set"

# --- Scenario 7: wire-in point present in route_delegate. ---
if grep -q '_cloud_disclose "$disp"' "$SRC"; then ok "route_delegate wires the gate after lane resolution"; else bad "gate not wired into route_delegate"; fi
if grep -q 'OSRC_CLOUD_ACKED' "$SRC"; then ok "OSRC_CLOUD_ACKED guard present"; else bad "OSRC_CLOUD_ACKED guard missing"; fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
