#!/usr/bin/env bash
# test_tokenrouter_lane.sh — the TokenRouter gateway lane must be wired into every provider list,
# expose a delegate that streams from the gateway's /v1/chat/completions with the key out of the ps
# table, pass -m through VERBATIM, fail fast on a missing key, and dispatch correctly through the
# router seam (the dead-on-dispatch defect that bit the Cline lane must not recur here).
#
# TokenRouter (https://www.tokenrouter.com) is an OpenAI-compatible model gateway. The lane is a CLOUD
# lane (the prompt leaves the machine), so it flows through the same _cloud_disclose choke point +
# secret-scan as every other cloud lane. -m is REQUIRED and passes through verbatim to the gateway's
# own catalog (their models, not a hardcoded list, and NO hardcoded default model).
#
# COST HONESTY (locked by this test): the roster and pricing are TokenRouter's and change; some
# models are a $0 promo RIGHT NOW. The lane must NEVER claim "$0 cash" or "free" as a static fact —
# cost is confirmed at RUNTIME by billing/quota errors (402/429), never by a hardcoded date.
#
# This test has TWO layers:
#   1. STATIC checks (grep-based): fast verification that wiring, key handling, and honesty guards exist.
#   2. BEHAVIORAL checks (dispatch against a fake local gateway): actually invoke delegate_tokenrouter
#      with OSRC_TOKENROUTER_URL pointed at a stub server and assert the request it received matches
#      the contract (model verbatim, Bearer auth, streaming parse). This catches regressions a static
#      grep cannot (e.g. a renamed endpoint or a key leaked into process args).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TMP="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; exit 1; }
export OSRC_HOME="$TMP"
trap 'rm -rf "$TMP"; [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null || true' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

. "$SRC" >/dev/null 2>&1

# ============================================================================
# LAYER 1: STATIC CHECKS (grep-based — fast, catches missing wiring)
# ============================================================================

# --- the delegate exists and streams from the gateway's chat/completions endpoint ---
grep -q 'delegate_tokenrouter()' "$SRC" && ok "delegate_tokenrouter defined" || bad "delegate_tokenrouter missing"
grep -q '/chat/completions' "$SRC" && ok "delegate targets /chat/completions" || bad "chat/completions endpoint missing"

# --- key handling: single-key extraction, never set -a, key out of the ps table ---
grep -q '_tr_load_key()' "$SRC" && ok "_tr_load_key defined" || bad "_tr_load_key missing"
grep -q '_extract_kv_value TOKENROUTER_API_KEY' "$SRC" && ok "key loaded via single-key extraction from ~/.env" || bad "key not loaded via _extract_kv_value"
grep -q '_curl_with_auth "\$TOKENROUTER_API_KEY"' "$SRC" && ok "key rides _curl_with_auth (0600 temp-file header, not a process arg)" || bad "key not passed via _curl_with_auth"
# The delegate must NOT inline the key as a curl -H argument (that lands it in the ps table).
if grep -E "curl .*-H ['\"]Authorization: Bearer \\\$\{?TOKENROUTER_API_KEY" "$SRC" >/dev/null 2>&1; then
  bad "delegate inlines TOKENROUTER_API_KEY in a curl -H argument (visible in the ps table)"
else
  ok "delegate never inlines the key in a curl -H argument"
fi

# --- tokenrouter is an engine-style lane: alias resolution must NOT rewrite a pinned -m ---
grep -q '\[ "$PROVIDER" != "tokenrouter" \]' "$SRC" && ok "tokenrouter skips alias resolution (-m passes verbatim)" || bad "tokenrouter not in the alias-skip guard"

# --- tokenrouter is wired into every provider list (the contract: --provider tokenrouter works) ---
_n=$(grep -c -- "devin|cc|codex|droid|cursor|hermes|warp|cline|gemini|gm|claudex|local|tokenrouter" "$SRC")
[ "$_n" -ge 4 ] && ok "tokenrouter appears in $_n provider-list sites" || bad "tokenrouter missing from provider lists (found $_n)"
grep -q "unknown provider.*tokenrouter" "$SRC" && ok "unknown-provider error names tokenrouter" || bad "tokenrouter not in unknown-provider message"

# --- _effective_lane treats tokenrouter as an engine lane (provider IS the lane) ---
[ "$(_effective_lane tokenrouter tokenrouter 2>/dev/null)" = "tokenrouter" ] && ok "_effective_lane: tokenrouter is its own lane" || bad "_effective_lane wrong for tokenrouter"

# --- cloud gate covers tokenrouter (it is a cloud lane: the prompt leaves the machine) ---
grep -q 'tokenrouter) return 0 ;;   # cloud gateway' "$SRC" && ok "tokenrouter is gated as a cloud lane" || bad "tokenrouter not gated as a cloud lane"

# --- route resolution has a cost class for tokenrouter (no 'route resolution is ambiguous' death) ---
grep -q 'ccor|codexor|claudex|tokenrouter) ROUTE_COST_CLASS=credits' "$SRC" && ok "route cost class wired for tokenrouter" || bad "tokenrouter missing from route cost class"

# --- the lane has NO hardcoded default model: -m is REQUIRED (the roster is the gateway's) ---
if awk '/^_route_provider_default_model\(\)/,/^}/' "$SRC" | grep -q 'tokenrouter'; then
  bad "_route_provider_default_model still has a tokenrouter arm (hardcoded default model)"
else
  ok "no hardcoded default model for tokenrouter (-m is required)"
fi
grep -q '\[ "\$PROVIDER" != "tokenrouter" \] || die "the tokenrouter lane needs -m' "$SRC" \
  && ok "route_delegate fails fast when tokenrouter runs without -m" \
  || bad "route_delegate missing the tokenrouter -m-required guard"

# --- dispatch table reaches the delegate (the dead-on-dispatch guard) ---
grep -q 'tokenrouter) delegate_tokenrouter "\$tier"' "$SRC" && ok "dispatch table routes tokenrouter to delegate_tokenrouter" || bad "dispatch table missing the tokenrouter arm"

# --- fanout preflight checks the key before minting jobs (no phantom jobs on a missing key) ---
grep -q "fanout: lane 'tokenrouter' requires TOKENROUTER_API_KEY" "$SRC" && ok "fanout preflight gates tokenrouter on the key" || bad "fanout preflight missing the tokenrouter key gate"
grep -q "fanout: lane 'tokenrouter' needs a model for every job" "$SRC" && ok "fanout preflight gates tokenrouter on a per-job model (no default)" || bad "fanout preflight missing the tokenrouter model gate"

# --- fallback machinery knows the lane (lane-ready probe + provider-for-lane) ---
grep -q 'tokenrouter) k="\${TOKENROUTER_API_KEY:-}"' "$SRC" && ok "_fallback_lane_ready probes the tokenrouter key" || bad "_fallback_lane_ready missing tokenrouter"
grep -q 'droid|cursor|hermes|warp|cline|tokenrouter) printf' "$SRC" && ok "_fallback_provider_for_lane maps tokenrouter" || bad "_fallback_provider_for_lane missing tokenrouter"

# --- bg/fanout job peek (run_job) records the lane (the lane has no default model; -m is required,
#     so a bg job on this lane always carries an explicit model) ---
grep -q 'tokenrouter)  lane="tokenrouter" ;;' "$SRC" \
  && ok "run_job records the tokenrouter lane (bg jobs never record a blank lane)" \
  || bad "run_job engine-lane case missing the tokenrouter arm"

# --- second-opinion routing (_so_resolve) dispatches tokenrouter, never misroutes to the alias lane ---
grep -q 'droid|cursor|hermes|warp|cline|claudex|tokenrouter) disp="\$elane"' "$SRC" \
  && ok "_so_resolve dispatches tokenrouter (no misroute to the alias-table lane)" \
  || bad "_so_resolve missing the tokenrouter arm (a second-opinion judge could misroute off the lane)"

# --- doctor has a dedicated tokenrouter section (key + liveness guidance) ---
grep -q 'TokenRouter lane' "$SRC" && ok "doctor has a TokenRouter lane section" || bad "doctor has no TokenRouter section"
grep -q 'https://www.tokenrouter.com' "$SRC" && ok "doctor points at the TokenRouter console for a key" || bad "doctor missing the key-source pointer"

# --- brief advertises tokenrouter when the key is present ---
grep -q 'tokenrouter=keyed' "$SRC" && ok "brief lists tokenrouter when the key is present" || bad "brief does not advertise tokenrouter"

# --- COST HONESTY: NEVER claim the tokenrouter lane is "$0 cash" or "free" as a static fact.
#     Some models are a $0 promo RIGHT NOW; that is confirmed at runtime by billing errors, never
#     hardcoded. (Check code lines only — the disclosure string legitimately explains the promo.) ---
_tr_ctx="$(grep -niE 'tokenrouter' "$SRC" | grep -iE '\$0 cash|is free|free lane|(^|[^.-])free([^a-z-]|$)' | grep -viE 'promo|runtime|billing|never by a hardcoded' || true)"
[ -z "$_tr_ctx" ] && ok "no static '\$0 cash'/'free' claim attached to the tokenrouter lane" \
  || bad "tokenrouter lane makes a static free/\$0 claim: $_tr_ctx"

# --- no hardcoded expiry date for the promo tier (the Inviolable Rule: tier by identity + runtime) ---
if grep -niE 'tokenrouter' "$SRC" | grep -qE '20[0-9]{2}-[0-9]{2}-[0-9]{2}'; then
  bad "a hardcoded date is attached to the tokenrouter lane (promo expiry must be runtime-detected)"
else
  ok "no hardcoded expiry date attached to the tokenrouter lane"
fi

# --- ledger records an UNMEASURED cost (empty), never a fabricated zero ---
grep -q 'record_ledger tokenrouter "\$model" "\$ttier" "\$tier" "\$task" "" "tokenrouter"' "$SRC" \
  && ok "ledger records an empty (unmeasured) cost, not a fabricated zero" \
  || bad "ledger cost recording wrong for tokenrouter"

# ============================================================================
# LAYER 2: BEHAVIORAL CHECKS (dispatch against a fake local gateway)
# These catch regressions a static grep cannot — e.g. a renamed endpoint, a broken SSE parse,
# or a key that leaks into process args.
# ============================================================================
echo ""
echo "=== Layer 2: Behavioral dispatch (fake TokenRouter gateway on 127.0.0.1) ==="

have jq || { echo "SKIP: layer 2 needs jq"; echo "RESULT: $pass pass, $fail fail"; exit $(( fail > 0 )); }

# Fake gateway: captures the request (method, path, auth header presence, body) and answers a
# minimal SSE stream. Listens on an ephemeral loopback port via python3 (stdlib http.server).
FAKE_DIR="$TMP/fakegw"; mkdir -p "$FAKE_DIR"
cat > "$FAKE_DIR/gw.py" <<'PYEOF'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(n).decode('utf-8', 'replace')
        with open(sys.argv[2], 'a') as f:
            f.write(json.dumps({
                'path': self.path,
                'auth': 'bearer' if (self.headers.get('Authorization') or '').startswith('Bearer ') else 'none',
                'body': body,
            }) + '\n')
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        self.wfile.write(b'data: {"choices":[{"delta":{"content":"TOKENROUTER-FAKE-OK"}}]}\n\n')
        self.wfile.write(b'data: [DONE]\n\n')
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"data":[{"id":"vendor-a/model-x"}]}')
srv = http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H)
srv.serve_forever()
PYEOF
GW_PORT="$(( 20000 + RANDOM % 20000 ))"
CAPTURE="$TMP/gw_requests.jsonl"
python3 "$FAKE_DIR/gw.py" "$GW_PORT" "$CAPTURE" >/dev/null 2>&1 &
FAKE_PID=$!
sleep 1
if ! kill -0 "$FAKE_PID" 2>/dev/null; then echo "SKIP: could not start fake gateway"; echo "RESULT: $pass pass, $fail fail"; exit $(( fail > 0 )); fi

export OSRC_TOKENROUTER_URL="http://127.0.0.1:$GW_PORT/v1"
export TOKENROUTER_API_KEY="***"

# (B1) dispatch streams the fake completion and hits /chat/completions with a Bearer key.
REST=("test task for tokenrouter"); MODEL="vendor-a/model-x"; MODEL_EXPLICIT=1; EFFORT=""; TIER_FLAG=""; WITH_SPEC=""
_b1_out="$( ( delegate_tokenrouter auto ) 2>/dev/null || true )"
if printf '%s' "$_b1_out" | grep -q 'TOKENROUTER-FAKE-OK'; then
  ok "behavioral: delegate streams the gateway's SSE completion to stdout"
else
  bad "behavioral: delegate did not stream the fake completion (got: $_b1_out)"
fi
if [ -f "$CAPTURE" ] && grep -q 'chat/completions' "$CAPTURE"; then
  ok "behavioral: request hit /chat/completions"
else
  bad "behavioral: request did not hit /chat/completions (capture: $(cat "$CAPTURE" 2>/dev/null || echo NONE))"
fi
if [ -f "$CAPTURE" ] && grep -q '"auth": "bearer"' "$CAPTURE"; then
  ok "behavioral: request carried a Bearer Authorization header"
else
  bad "behavioral: request missing the Bearer Authorization header"
fi

# (B2) -m passes through verbatim in the request body (the gateway's own catalog, never rewritten).
# The capture stores the body as a JSON string, so inner quotes are escaped (\"model\":\"...\").
if [ -f "$CAPTURE" ] && grep -q 'model\\":\\"vendor-a/model-x' "$CAPTURE"; then
  ok "behavioral: -m vendor-a/model-x passed through verbatim in the request body"
else
  bad "behavioral: model not passed verbatim (capture: $(cat "$CAPTURE" 2>/dev/null || echo NONE))"
fi

# (B3) a custom -m (any gateway id) also passes through verbatim.
: > "$CAPTURE"
REST=("test task"); MODEL="some-vendor/other-model"; MODEL_EXPLICIT=1; EFFORT=""; TIER_FLAG=""; WITH_SPEC=""
( delegate_tokenrouter auto ) >/dev/null 2>&1 || true
if [ -f "$CAPTURE" ] && grep -q 'model\\":\\"some-vendor/other-model' "$CAPTURE"; then
  ok "behavioral: an arbitrary gateway model id passes through verbatim"
else
  bad "behavioral: arbitrary model id not passed verbatim (capture: $(cat "$CAPTURE" 2>/dev/null || echo NONE))"
fi

# (B4) missing key fails fast with a pointer to ~/.env (never a silent empty dispatch).
: > "$CAPTURE"
REST=("test task"); MODEL=""; MODEL_EXPLICIT=0; EFFORT=""; TIER_FLAG=""; WITH_SPEC=""
_b4_out="$( ( TOKENROUTER_API_KEY="" HOME="$TMP/nohome" delegate_tokenrouter auto ) 2>&1 >/dev/null || true )"
if printf '%s' "$_b4_out" | grep -q 'TOKENROUTER_API_KEY not found'; then
  ok "behavioral: missing key fails fast with a ~/.env pointer"
else
  bad "behavioral: missing key did not fail fast (output: $_b4_out)"
fi

# (B5) no -m fails fast (the lane has NO hardcoded default model) and sends nothing.
: > "$CAPTURE"
REST=("test task"); MODEL=""; MODEL_EXPLICIT=0; EFFORT=""; TIER_FLAG=""; WITH_SPEC=""
_b5_out="$( ( delegate_tokenrouter auto ) 2>&1 >/dev/null || true )"
if printf '%s' "$_b5_out" | grep -q 'needs -m <gateway-model-id>'; then
  ok "behavioral: no -m fails fast (no hardcoded default model)"
else
  bad "behavioral: no -m did not fail fast (output: $_b5_out)"
fi
if [ ! -s "$CAPTURE" ]; then
  ok "behavioral: no -m prevented any request to the gateway"
else
  bad "behavioral: a request reached the gateway despite the missing -m"
fi
if [ ! -s "$CAPTURE" ]; then
  ok "behavioral: missing key prevented any request to the gateway"
else
  bad "behavioral: a request reached the gateway despite the missing key"
fi

kill "$FAKE_PID" 2>/dev/null || true; FAKE_PID=""

echo
if [ "$fail" -gt 0 ]; then echo "RESULT: $fail FAIL(S), $pass pass"; exit 1; fi
echo "RESULT: $pass pass, 0 fail"
