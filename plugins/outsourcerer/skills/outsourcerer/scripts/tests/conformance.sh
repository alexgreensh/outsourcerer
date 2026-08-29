#!/usr/bin/env bash
# conformance.sh — U5: per-lane conformance harness (the don't-ship-blind gate).
#
# TWO layers:
#   STATIC  (always): every Phase-0 security/routing invariant is wired (aggregates the unit tests +
#           cross-checks the source). Fast, deterministic, CI-safe, no cost.
#   LIVE    (opt-in, OSRC_CONFORMANCE_LIVE=1): drives each AVAILABLE lane under the effort x tools x
#           real-repo matrix that exposed every "passed the smoke test, failed the real run" bug —
#           asserts the lane actually runs a tool and honors the exit contract. Skips absent lanes.
#
# Run:  bash conformance.sh            # static gate only
#       OSRC_CONFORMANCE_LIVE=1 bash conformance.sh   # + live lane probes (uses quota/tokens)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Sweep stale scratch dirs from crashed runs so they don't accumulate across runs (only inside our tests dir).
if [ -d "$SCRIPT_DIR" ] && [ "$(cd "$SCRIPT_DIR" && pwd)" = "$SCRIPT_DIR" ]; then
  find "$SCRIPT_DIR" -maxdepth 1 -type d \( -name '.test-*' -o -name '.conformance-run-*' \) -exec rm -rf {} + 2>/dev/null
fi

pass=0; fail=0; skip=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }
note() { echo "SKIP: $1"; skip=$((skip+1)); }

echo "=== STATIC gate: Phase-0 invariants wired ==="

# 1. Every unit test suite is green (aggregate).
_ALL_SUITES="test_cloud_gate test_no_silent_escalation test_hardening test_escalation_classify \
         test_devin_tls_diagnostics test_devin_printmode_hang test_lane_fallback test_interactive_default test_session_capabilities \
         test_harness_isolation test_autodetach test_advise test_claudex test_copilot \
         test_loops test_job_lifecycle test_output_truncation test_lane_accounting \
         test_selfcontained_hardening test_trusted_lanes test_parity_links test_parity_hermes test_watch_digest \
         test_cc_devin_selfheal test_cloud_gate_coverage test_cost_disclosure \
         test_parser_parity test_resolved_lane test_limits_freshness test_gemini_lane test_watcher \
         test_marker_forgery test_loop_resume test_lane_liveness \
         test_with_injection test_no_phantom_jobs test_model_drift test_model_pin_enforcement test_perm_denial_precision test_devin_liveness test_windows_portability \
         test_devin_alias_resolution test_build_target test_mutation_state_durability test_wake_queue \
         test_heartbeat_ownership test_bearings test_external_sessions test_external_send_opt_in test_session_claims test_session_reply_safety test_obligations"
_ALL_SUITES="$_ALL_SUITES test_reverdict_residuals"
_ALL_SUITES="$_ALL_SUITES test_session_effort"
_ALL_SUITES="$_ALL_SUITES test_model_selection_parity"
_ALL_SUITES="$_ALL_SUITES test_heartbeat_human"
_ALL_SUITES="$_ALL_SUITES test_heartbeat_reclaim"
_ALL_SUITES="$_ALL_SUITES test_devin_org_policy_posture"
_ALL_SUITES="$_ALL_SUITES test_heartbeat_wake_push"
_ALL_SUITES="$_ALL_SUITES test_cc_model_restore"
_ALL_SUITES="$_ALL_SUITES test_vocab_hygiene"
_ALL_SUITES="$_ALL_SUITES test_tool_bugs_062"
_ALL_SUITES="$_ALL_SUITES test_managed_send"
_ALL_SUITES="$_ALL_SUITES test_parity_autoheal"
_ALL_SUITES="$_ALL_SUITES test_pr10_falsestall_before_quota"
_ALL_SUITES="$_ALL_SUITES test_cline_lane"
_ALL_SUITES="$_ALL_SUITES test_fleet_cc_peers"
_ALL_SUITES="$_ALL_SUITES test_fleet_states"
_ALL_SUITES="$_ALL_SUITES test_fleet_names"
_ALL_SUITES="$_ALL_SUITES test_devin_free_guard"
_ALL_SUITES="$_ALL_SUITES test_fg_guard_forgery test_fanout_json test_version_gate test_explain"
_ALL_SUITES="$_ALL_SUITES test_detection test_pane_state test_wait test_feature_fixes test_droid_session"
_ALL_SUITES="$_ALL_SUITES test_loop_escalate test_second_opinion_agree test_catalog_validation"
_ALL_SUITES="$_ALL_SUITES test_value_router"
_ALL_SUITES="$_ALL_SUITES test_advise_dynamic_pool"
_ALL_SUITES="$_ALL_SUITES test_bg_provider_after_verb"
_ALL_SUITES="$_ALL_SUITES test_require_interactive"
_ALL_SUITES="$_ALL_SUITES test_session_send_verify"
_ALL_SUITES="$_ALL_SUITES test_session_control"
_ALL_SUITES="$_ALL_SUITES test_codex_code_mode_host"
_ALL_SUITES="$_ALL_SUITES test_quota"
for t in $_ALL_SUITES; do
  if [ -f "$SCRIPT_DIR/$t.sh" ]; then
    # Capture rather than discard: a failing suite whose output went to /dev/null makes a CI log say
    # "test_x FAILED" and nothing else, which is the difference between a fixable report and a mystery.
    # Static suites must not inherit a live status beacon.  It can outlive a
    # focused test and perturb unrelated supervisor-label assertions.
    _out="$(OSRC_HEARTBEAT_DISABLED=1 bash "$SCRIPT_DIR/$t.sh" 2>&1)"
    if [ $? -eq 0 ]; then ok "unit suite $t green"
    else
      bad "unit suite $t FAILED"
      printf '%s\n' "$_out" | grep -E '^(FAIL|SKIP)' | sed 's/^/      /'
    fi
  else note "unit suite $t absent"; fi
done

# 2. Security choke points present in source (defense-in-depth cross-check).
grep -q '_cloud_disclose "$disp"'                 "$SRC" && ok "U1 cloud gate wired at route_delegate choke point" || bad "U1 gate missing"
grep -q 'protected path needs --allow-downgrade'  "$SRC" && ok "U2 no-silent-escalation default present"          || bad "U2 default missing"
grep -q 'SECURITY DOWNGRADE'                      "$SRC" && ok "U2 downgrade is labeled, not silent"               || bad "U2 label missing"
grep -q '_validate_model_token'                   "$SRC" && ok "U3 model-token injection guard present"            || bad "U3 guard missing"
grep -q '_is_transport_failure'                   "$SRC" && ok "U4 transport-vs-task classifier present"           || bad "U4 classifier missing"
grep -q '_devin_model_for'                        "$SRC" && ok "availability-aware routing present"             || bad "availability-aware routing missing"
grep -q 'Read Edit Write Bash Grep Glob'          "$SRC" && ok "U7 mutating coding toolset granted (no bash wedge)" || bad "U7 toolset missing"
grep -q '_autodetach_should'                       "$SRC" && ok "D3 auto-detach trigger present"                       || bad "D3 trigger missing"
grep -q '_lane_trusted_for_pwd'                    "$SRC" && ok "per-repo lane trust resolver present"                  || bad "trust resolver missing"
grep -qE 'export[[:space:]]+OSRC_TRUST_LANE_ONCE'  "$SRC" && bad "per-invocation trust grant is exported (child jobs would inherit it)" || ok "trust grant is never exported (no inheritance)"
grep -q '_autodetach_run.*_bg_launch\|_bg_launch'  "$SRC" && ok "D3 auto-detach reuses bg machinery"                    || bad "D3 reuse missing"

# 2a. TEST REGISTRATION: a suite that exists but is not in the list above never runs. Four suites sat
# unregistered in this directory for a full release cycle, green locally and never executed by the
# gate. An unrun test is indistinguishable from no test, except that it looks like coverage.
_unreg=""
for _f in "$SCRIPT_DIR"/test_*.sh; do
  _n="$(basename "$_f" .sh)"
  case " $_ALL_SUITES " in *" $_n "*) ;; *) _unreg="$_unreg $_n" ;; esac
done
[ -z "$_unreg" ] && ok "every test_*.sh in this directory is registered with the runner" \
  || bad "test suite(s) present but never run by the gate:$_unreg"

# 2b. INSTALL DRIFT: a second installed copy running different code than this one is the failure that
# makes every other gate here meaningless — the suite passes against a tree the user never executes.
# It has bitten twice: a stale standalone copy running old code, and edits made in one copy silently
# overwritten by a sync from the other.
_alt="$HOME/.claude/skills/outsourcerer/scripts/outsourcerer.sh"
if [ -f "$_alt" ] && [ "$(cd "$(dirname "$_alt")" && pwd -P)" != "$(cd "$(dirname "$SRC")" && pwd -P)" ]; then
  if cmp -s "$SRC" "$_alt"; then ok "second installed copy is byte-identical to this one"
  else bad "INSTALL DRIFT: $_alt differs from the tree under test — one of them is running stale code"; fi
fi

# 3. bash -n on the script + all sibling shell scripts.
for f in "$SRC" "$SCRIPT_DIR"/../run-or-model.sh "$SCRIPT_DIR"/../run-or-codex.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then ok "bash -n clean: $(basename "$f")"; else bad "bash -n FAILED: $(basename "$f")"; fi
done

echo
echo "=== LIVE lane matrix (effort x tools x real-repo) ==="
if [ "${OSRC_CONFORMANCE_LIVE:-0}" != "1" ]; then
  note "live lane probes skipped (set OSRC_CONFORMANCE_LIVE=1 to run; uses quota/tokens)"
else
  # Build a tiny real-repo fixture with a nonce the lane must READ (proves a real tool call).
  FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
  nonce="OSRC-$$-CONFORMANCE"
  printf '%s\n' "$nonce" > "$FIX/nonce.txt"
  probe_lane() { # <label> <args...>
    local label="$1"; shift
    local out rc
    # OSRC_NO_AUTODETACH=1: the probe captures stdout (non-TTY), which would trigger D3 auto-detach
    # on capable/frontier tiers and return a job-id receipt instead of the answer — a false FAIL.
    out="$( cd "$FIX"; OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" "$@" --effort high "Read ./nonce.txt and reply with ONLY its contents." 2>&1 )"; rc=$?
    if printf '%s' "$out" | grep -q "$nonce"; then ok "LIVE $label: read the fixture (real tool call), rc=$rc"
    elif [ "$rc" -ne 0 ]; then note "LIVE $label: lane unavailable/failed (rc=$rc) — $(printf '%s' "$out" | tail -1)"
    else bad "LIVE $label: ran but did NOT read the nonce (tool grant broken?)"; fi
  }
  # Devin GLM (availability-aware routing fix — this is the exact path that used to 403 on OpenRouter).
  if have devin && devin auth status 2>/dev/null | grep -qi "logged in"; then
    probe_lane "devin/glm" run -m glm
  else note "LIVE devin: not installed / not logged in"; fi
  # Native Claude (subscription) if present.
  if have claude; then probe_lane "claude-native" run -m haiku; else note "LIVE claude-native: claude CLI absent"; fi
  # OpenRouter cc lane only if a key is present AND not over quota (best-effort).
  if grep -qE '^[[:space:]]*(export[[:space:]]+)?OPENROUTER_API_KEY=' "$HOME/.env" 2>/dev/null; then
    probe_lane "cc/openrouter-glm" --provider cc run -m glm
  else note "LIVE cc/openrouter: no OPENROUTER_API_KEY"; fi
fi

echo
echo "RESULT: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
