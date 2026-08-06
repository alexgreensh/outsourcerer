#!/usr/bin/env bash
# test_cline_lane.sh — the Cline engine lane must be wired into every provider list, expose a
# delegate that sends flags the CLI actually accepts, map effort to cline's --thinking knob,
# version-gate the --plan read-only guarantee, and dispatch correctly through a behavioral test.
#
# Cline (https://github.com/cline/cline) is an engine lane like droid/cursor/hermes/warp:
# -m passes through VERBATIM (cline owns its provider/model catalog), and the FREE `cline` OAuth
# provider serves deepseek-v4-flash + glm-5.2 at $0 cash. Posture is binary (--plan = read-only,
# act mode = --auto-approve true); there is no OS sandbox and no graded approval rung.
#
# This test has TWO layers:
#   1. STATIC checks (grep-based): fast verification that flags, provider lists, and wiring exist.
#   2. BEHAVIORAL checks (dispatch via fake-bin/cline): actually invoke delegate_cline with a fake
#      cline stub on PATH and assert the flags it received match the tier's contract. This catches
#      regressions a static grep cannot (e.g. a flag renamed in the dispatch line but not in a comment).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

# mktemp check: if mktemp fails, the test used to continue with an empty TMP and report passes
# on a broken setup. Under set -e this aborts immediately — the failure is visible, not silent.
TMP="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; exit 1; }
export OSRC_HOME="$TMP"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

. "$SRC" >/dev/null 2>&1

# ============================================================================
# LAYER 1: STATIC CHECKS (grep-based — fast, catches missing wiring)
# ============================================================================

# --- effort maps to cline's --thinking knob (none|low|medium|high|xhigh) ---
[ "$(_cline_effort minimal 2>/dev/null)" = "none" ]   && ok "minimal -> none (cline's lowest)"   || bad "minimal not mapped to none"
[ "$(_cline_effort low 2>/dev/null)" = "low" ]        && ok "low passes through"                  || bad "low altered"
[ "$(_cline_effort medium 2>/dev/null)" = "medium" ]  && ok "medium passes through"               || bad "medium altered"
[ "$(_cline_effort high 2>/dev/null)" = "high" ]      && ok "high passes through"                 || bad "high altered"
[ "$(_cline_effort xhigh 2>/dev/null)" = "xhigh" ]    && ok "xhigh passes through"                || bad "xhigh altered"
[ "$(_cline_effort max 2>/dev/null)" = "xhigh" ]      && ok "max -> xhigh (cline's highest)"      || bad "max not mapped to xhigh"
v="$(_cline_effort garbage 2>/dev/null)"
[ -z "$v" ] && ok "unknown effort yields empty (no --thinking flag emitted)" || bad "unknown effort produced '$v'"

# --- version helpers ---
# _cline_version calls `cline --version`, so fake-bin must be on PATH for the parse test.
_cv_test="$(PATH="$SCRIPT_DIR/fake-bin:$PATH" _cline_version 2>/dev/null || echo ERR)"
[ "$_cv_test" = "3.0.48" ] && ok "_cline_version parses 'cline 3.0.48' -> 3.0.48" \
  || bad "_cline_version did not parse 3.0.48 (got '$_cv_test')"
if _ver_ge 3.0.48 3.0.36 2>/dev/null; then ok "_ver_ge: 3.0.48 >= 3.0.36 (pass)"; else bad "_ver_ge: 3.0.48 should be >= 3.0.36"; fi
if _ver_ge 3.0.35 3.0.36 2>/dev/null; then bad "_ver_ge: 3.0.35 should be < 3.0.36 (fail)"; else ok "_ver_ge: 3.0.35 < 3.0.36 (fail closed)"; fi
if _ver_ge 3.0.36 3.0.36 2>/dev/null; then ok "_ver_ge: 3.0.36 >= 3.0.36 (boundary: equal passes)"; else bad "_ver_ge: 3.0.36 should be >= 3.0.36"; fi
if _ver_ge "" 3.0.36 2>/dev/null; then bad "_ver_ge: empty version should fail closed"; else ok "_ver_ge: empty version fails closed"; fi

# --- the delegate exists and sends flags cline accepts ---
grep -q 'delegate_cline()' "$SRC" && ok "delegate_cline defined" || bad "delegate_cline missing"
# --plan for read-only (tools still auto-approved so they run headless; plan mode prevents edits),
# --auto-approve true for mutating (cline's actual flags, not invented ones)
grep -q -- '--plan)' "$SRC" && ok "run tier uses --plan alone (read-only, tools still work headless)" || bad "run tier not --plan"
grep -q -- '--auto-approve true' "$SRC" && ok "mutating tiers use --auto-approve true" || bad "mutating tiers not --auto-approve"
# CRITICAL: --auto-approve false must NOT appear in a pflag= assignment — it blocks ALL tools in
# non-interactive mode (read_files, run_commands, search_codebase all need approval), paralyzing
# the delegate headlessly. --plan alone provides the read-only guarantee. (Check code lines only,
# not comments — the comment explaining the trap legitimately mentions the flag.)
if grep -E 'pflag=\([^)]*--auto-approve false' "$SRC" >/dev/null 2>&1; then
  bad "run tier uses --auto-approve false in a pflag assignment (paralyzes cline in non-interactive mode)"
else
  ok "no pflag assignment uses --auto-approve false (tools can run headless)"
fi
grep -q -- '--thinking' "$SRC" && ok "effort reaches cline as --thinking" || bad "effort not passed as --thinking"

# --- version gate is present in the delegate ---
grep -q '_CLINE_MIN_PLAN_VER' "$SRC" && ok "version gate constant defined" || bad "version gate constant missing"
grep -q 'OSRC_CLINE_SKIP_VER_GATE' "$SRC" && ok "version gate bypass escape hatch exists" || bad "version gate bypass missing"

# --- the fake-bin stub must echo, not execute (fork bomb trap) ---
# A stub that runs `cline 3.0.48` instead of `echo "cline 3.0.48"` would recurse infinitely if ever
# executed with fake-bin on PATH. The --version output must come from echo, not from executing cline.
grep -q 'echo "cline' "$SCRIPT_DIR/fake-bin/cline" && ok "fake-bin/cline uses echo for --version (no fork bomb)" \
  || bad "fake-bin/cline does NOT use echo for --version (latent fork bomb)"

# --- install instructions must point at the real npm package (cline, not @anthropic-ai/cline-cli) ---
# @anthropic-ai/cline-cli does not exist on npm (404); the real package is `cline`.
if grep -q '@anthropic-ai/cline-cli' "$SRC"; then
  bad "install instruction references nonexistent @anthropic-ai/cline-cli package"
else
  ok "install instruction does not reference the nonexistent @anthropic-ai/cline-cli"
fi
grep -q 'npm i -g cline' "$SRC" && ok "install instruction uses the real package (npm i -g cline)" \
  || bad "install instruction missing the correct npm package"

# --- cline is an engine lane: alias resolution must NOT rewrite a pinned -m ---
# The route_delegate guard skips alias resolution for engine lanes; cline must be in that list.
grep -q '\[ "$PROVIDER" != "cline" \]' "$SRC" && ok "cline skips alias resolution (-m passes verbatim)" || bad "cline not in the alias-skip guard"

# --- cline is wired into every provider list (the contract: the alias picks the lane) ---
_n=$(grep -c -- "devin|cc|codex|droid|cursor|hermes|warp|cline|gemini|gm|claudex|local" "$SRC")
[ "$_n" -ge 4 ] && ok "cline appears in $_n provider-list sites" || bad "cline missing from provider lists (found $_n)"
# the unknown-provider die must name cline so a typo is self-explanatory
grep -q "unknown provider.*cline" "$SRC" && ok "unknown-provider error names cline" || bad "cline not in unknown-provider message"

# --- _effective_lane treats cline as an engine lane (provider IS the lane) ---
[ "$(_effective_lane cline cline 2>/dev/null)" = "cline" ] && ok "_effective_lane: cline is its own lane" || bad "_effective_lane wrong for cline"

# --- cloud gate covers cline (it is a cloud lane: cline's backend + the model API) ---
grep -q 'cline|claudex) return 0' "$SRC" && ok "cline is in the _is_cloud_lane set" || bad "cline not gated as a cloud lane"

# --- brief advertises cline when the CLI is present (auto-detection, no config) ---
# Stub PATH so `have cline` is true, then run the lane probe.
PATH="$SCRIPT_DIR/fake-bin:$PATH" _lanes="$(PATH="$SCRIPT_DIR/fake-bin:$PATH" _ready_lanes 2>/dev/null)"
case "$_lanes" in *cline=*) ok "brief lists cline when the CLI is on PATH" ;; *) bad "brief does not advertise cline: $_lanes" ;; esac

# --- doctor has a dedicated cline section (install + free-provider guidance) ---
grep -q 'Cline lane' "$SRC" && ok "doctor has a Cline lane section" || bad "doctor has no Cline section"
grep -q 'cline auth cline' "$SRC" && ok "doctor points at the free-provider auth step" || bad "doctor missing the auth guidance"
grep -q 'BEST-EFFORT schema read' "$SRC" && ok "doctor marks the ~/.cline jq schema as best-effort" || bad "doctor does not mark the schema as best-effort"

# --- fanout preflight: engine-lane CLI availability is checked before minting jobs ---
grep -q 'DISPATCHABILITY PREFLIGHT' "$SRC" && ok "fanout has a dispatchability preflight for engine lanes" || bad "fanout missing dispatchability preflight"
# CRITICAL: the preflight must map provider→CLI name correctly, not assume provider==CLI.
# route_delegate uses: cursor→cursor-agent, warp→oz. The preflight must match.
grep -q 'cursor) _dp_cli="cursor-agent"' "$SRC" && ok "fanout preflight maps cursor→cursor-agent (not cursor)" || bad "fanout preflight does not map cursor→cursor-agent"
grep -q 'warp)   _dp_cli="oz"' "$SRC" && ok "fanout preflight maps warp→oz (not warp)" || bad "fanout preflight does not map warp→oz"
grep -q 'droid)  _dp_cli="droid"' "$SRC" && ok "fanout preflight maps droid→droid" || bad "fanout preflight does not map droid→droid"
grep -q 'hermes) _dp_cli="hermes"' "$SRC" && ok "fanout preflight maps hermes→hermes" || bad "fanout preflight does not map hermes→hermes"
grep -q 'cline)  _dp_cli="cline"' "$SRC" && ok "fanout preflight maps cline→cline" || bad "fanout preflight does not map cline→cline"

# --- fg ledger carries the lane (fixes the fg misbucketing nit) ---
grep -q 'record_ledger cline.*"cline"' "$SRC" && ok "fg record_ledger passes the resolved lane (cline)" || bad "fg record_ledger does not pass the lane"

# --- supervision limitation is documented in the code ---
grep -q 'SUPERVISION LIMITATION' "$SRC" && ok "supervision limitation is documented in the delegate header" || bad "supervision limitation not documented"

# ============================================================================
# LAYER 2: BEHAVIORAL CHECKS (actually invoke delegate_cline via fake-bin/cline)
# These catch regressions a static grep cannot — e.g. a flag renamed in the dispatch line
# but not in a comment, or a version gate that doesn't fire.
# ============================================================================
echo ""
echo "=== Layer 2: Behavioral dispatch (fake-bin/cline on PATH) ==="

# Set up the capture file and PATH for all behavioral tests.
CAPTURE="$TMP/cline_capture.txt"
export OSRC_CLINE_FAKE_CAPTURE="$CAPTURE"
FAKE_PATH="$SCRIPT_DIR/fake-bin"

# Helper: reset globals to a clean state, set REST, and call delegate_cline.
# delegate_cline reads: REST (task args), MODEL, MODEL_EXPLICIT, EFFORT, TIER_FLAG, WITH_SPEC.
# We source the script's init block to get the defaults, then override REST.
# CRITICAL: delegate_cline may call `die` which calls `exit 1`. Since the script is sourced,
# `exit 1` would kill the whole test. We run delegate_cline in a SUBSHELL `( ... )` so `die`'s
# `exit` only terminates the subshell, not the test. The `|| true` catches the non-zero exit.
_reset_and_dispatch() {
  local tier="$1"; shift
  REST=("$@")
  MODEL=""; MODEL_EXPLICIT=0; EFFORT=""; TIER_FLAG=""; WITH_SPEC=""
  rm -f "$CAPTURE"
  ( PATH="$FAKE_PATH:$PATH" delegate_cline "$tier" ) >/dev/null 2>&1 || true
}

# (B1) auto tier dispatches with --plan (read-only) and passes the version gate (fake cline is 3.0.48).
_reset_and_dispatch auto "test task for plan mode"
if [ -f "$CAPTURE" ] && grep -q -- '--plan' "$CAPTURE"; then
  ok "behavioral: auto tier dispatches with --plan (read-only)"
else
  bad "behavioral: auto tier did not dispatch with --plan (capture: $(cat "$CAPTURE" 2>/dev/null || echo NONE))"
fi
# The fake result should appear in stdout (the delegate ran the fake cline).
# (B2) auto tier does NOT pass --auto-approve (read-only tier uses --plan alone).
if [ -f "$CAPTURE" ] && ! grep -q -- '--auto-approve' "$CAPTURE"; then
  ok "behavioral: auto tier does not pass --auto-approve (read-only, not mutating)"
else
  bad "behavioral: auto tier passed --auto-approve (should be read-only only)"
fi

# (B3) edit tier dispatches with --auto-approve true (mutating).
_reset_and_dispatch accept-edits "test task for edit mode"
if [ -f "$CAPTURE" ] && grep -q -- '--auto-approve true' "$CAPTURE"; then
  ok "behavioral: edit tier dispatches with --auto-approve true (mutating)"
else
  bad "behavioral: edit tier did not dispatch with --auto-approve true (capture: $(cat "$CAPTURE" 2>/dev/null || echo NONE))"
fi
# (B4) edit tier does NOT pass --plan (mutating tier uses act mode, not plan mode).
if [ -f "$CAPTURE" ] && ! grep -q -- '--plan' "$CAPTURE"; then
  ok "behavioral: edit tier does not pass --plan (mutating, not read-only)"
else
  bad "behavioral: edit tier passed --plan (should be mutating only)"
fi

# (B5) autonomous tier dispatches with --auto-approve true.
_reset_and_dispatch autonomous "test task for yolo mode"
if [ -f "$CAPTURE" ] && grep -q -- '--auto-approve true' "$CAPTURE"; then
  ok "behavioral: autonomous tier dispatches with --auto-approve true"
else
  bad "behavioral: autonomous tier did not dispatch with --auto-approve true"
fi

# (B6) -m passes through verbatim to cline (engine lane contract).
REST=("test task"); MODEL="deepseek/deepseek-v4-flash"; MODEL_EXPLICIT=1; EFFORT=""; TIER_FLAG=""; WITH_SPEC=""
rm -f "$CAPTURE"
( PATH="$FAKE_PATH:$PATH" delegate_cline accept-edits ) >/dev/null 2>&1 || true
if [ -f "$CAPTURE" ] && grep -q -- '-m deepseek/deepseek-v4-flash' "$CAPTURE"; then
  ok "behavioral: -m deepseek/deepseek-v4-flash passes through verbatim to cline"
else
  bad "behavioral: -m did not pass through verbatim (capture: $(cat "$CAPTURE" 2>/dev/null || echo NONE))"
fi

# (B7) --effort maps to --thinking on the cline CLI.
REST=("test task"); MODEL=""; MODEL_EXPLICIT=0; EFFORT="high"; TIER_FLAG=""; WITH_SPEC=""
rm -f "$CAPTURE"
( PATH="$FAKE_PATH:$PATH" delegate_cline accept-edits ) >/dev/null 2>&1 || true
if [ -f "$CAPTURE" ] && grep -q -- '--thinking high' "$CAPTURE"; then
  ok "behavioral: --effort high reaches cline as --thinking high"
else
  bad "behavioral: --effort high did not reach cline as --thinking high (capture: $(cat "$CAPTURE" 2>/dev/null || echo NONE))"
fi

# (B8) VERSION GATE: an old cline (pre-3.0.36) is refused on the auto (read-only) tier.
# Create a second fake cline that reports an old version (3.0.35).
OLD_FAKE="$TMP/old-fake-bin"
mkdir -p "$OLD_FAKE"
cat > "$OLD_FAKE/cline" <<'OLD_CLINE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "cline 3.0.35"; exit 0; fi
if [ -n "${OSRC_CLINE_FAKE_CAPTURE:-}" ]; then printf '%s\n' "$*" >> "$OSRC_CLINE_FAKE_CAPTURE"; fi
echo "FAKE OLD CLINE"; exit 0
OLD_CLINE
chmod +x "$OLD_FAKE/cline"
REST=("test task"); MODEL=""; MODEL_EXPLICIT=0; EFFORT=""; TIER_FLAG=""; WITH_SPEC=""
rm -f "$CAPTURE"
_GATE_OUT="$( ( PATH="$OLD_FAKE:$PATH" delegate_cline auto ) 2>&1 >/dev/null || true )"
if printf '%s' "$_GATE_OUT" | grep -q 'requires cline >= 3.0.36'; then
  ok "behavioral: version gate refuses old cline (3.0.35) on the read-only tier with a clear message"
else
  bad "behavioral: version gate did not refuse old cline (output: $_GATE_OUT)"
fi
# The old fake should NOT have been dispatched (no capture file written by the delegate).
if [ ! -f "$CAPTURE" ] || [ "$(cat "$CAPTURE" 2>/dev/null)" = "" ]; then
  ok "behavioral: version gate prevented dispatch on old cline (no task sent to the CLI)"
else
  bad "behavioral: version gate let old cline through (capture: $(cat "$CAPTURE" 2>/dev/null))"
fi

# (B9) VERSION GATE BYPASS: OSRC_CLINE_SKIP_VER_GATE=1 allows dispatch even when version is unparseable.
# Create a fake cline that returns a non-version string for --version.
WEIRD_FAKE="$TMP/weird-fake-bin"
mkdir -p "$WEIRD_FAKE"
cat > "$WEIRD_FAKE/cline" <<'WEIRD_CLINE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "some-unknown-format"; exit 0; fi
if [ -n "${OSRC_CLINE_FAKE_CAPTURE:-}" ]; then printf '%s\n' "$*" >> "$OSRC_CLINE_FAKE_CAPTURE"; fi
echo "FAKE WEIRD CLINE"; exit 0
WEIRD_CLINE
chmod +x "$WEIRD_FAKE/cline"
REST=("test task"); MODEL=""; MODEL_EXPLICIT=0; EFFORT=""; TIER_FLAG=""; WITH_SPEC=""
rm -f "$CAPTURE"
( PATH="$WEIRD_FAKE:$PATH" OSRC_CLINE_SKIP_VER_GATE=1 delegate_cline auto ) >/dev/null 2>&1 || true
if [ -f "$CAPTURE" ] && grep -q -- '--plan' "$CAPTURE"; then
  ok "behavioral: OSRC_CLINE_SKIP_VER_GATE=1 bypasses the unparseable-version gate and dispatches with --plan"
else
  bad "behavioral: OSRC_CLINE_SKIP_VER_GATE=1 did not bypass the gate (capture: $(cat "$CAPTURE" 2>/dev/null || echo NONE))"
fi

# (B10) VERSION GATE FAIL-CLOSED on unparseable version WITHOUT the bypass.
REST=("test task"); MODEL=""; MODEL_EXPLICIT=0; EFFORT=""; TIER_FLAG=""; WITH_SPEC=""
rm -f "$CAPTURE"
_FAILCLOSED_OUT="$( ( PATH="$WEIRD_FAKE:$PATH" delegate_cline auto ) 2>&1 >/dev/null || true )"
if printf '%s' "$_FAILCLOSED_OUT" | grep -q 'cannot parse cline version'; then
  ok "behavioral: unparseable version fails closed (refuses read-only tier without the bypass)"
else
  bad "behavioral: unparseable version did not fail closed (output: $_FAILCLOSED_OUT)"
fi

# (B11) Mutating tiers are NOT version-gated (the gate is read-only-specific).
REST=("test task"); MODEL=""; MODEL_EXPLICIT=0; EFFORT=""; TIER_FLAG=""; WITH_SPEC=""
rm -f "$CAPTURE"
( PATH="$OLD_FAKE:$PATH" delegate_cline accept-edits ) >/dev/null 2>&1 || true
if [ -f "$CAPTURE" ] && grep -q -- '--auto-approve true' "$CAPTURE"; then
  ok "behavioral: mutating tier (edit) dispatches on old cline (version gate is read-only-specific)"
else
  bad "behavioral: mutating tier was blocked by the version gate (should not be): $(cat "$CAPTURE" 2>/dev/null || echo NONE)"
fi

# (B12) VERSION GATE BYPASS on below-min version: OSRC_CLINE_SKIP_VER_GATE=1 allows dispatch
# even when cline is parseable but below 3.0.36. The bypass applies to BOTH failure modes
# (below-min AND unparseable), per the external review finding that the bypass was too narrow.
REST=("test task"); MODEL=""; MODEL_EXPLICIT=0; EFFORT=""; TIER_FLAG=""; WITH_SPEC=""
rm -f "$CAPTURE"
( PATH="$OLD_FAKE:$PATH" OSRC_CLINE_SKIP_VER_GATE=1 delegate_cline auto ) >/dev/null 2>&1 || true
if [ -f "$CAPTURE" ] && grep -q -- '--plan' "$CAPTURE"; then
  ok "behavioral: OSRC_CLINE_SKIP_VER_GATE=1 bypasses the below-min version gate and dispatches with --plan"
else
  bad "behavioral: OSRC_CLINE_SKIP_VER_GATE=1 did not bypass the below-min gate (capture: $(cat "$CAPTURE" 2>/dev/null || echo NONE))"
fi

# (B13) _cline_version anchors on the 'cline' token, not any dotted number.
# A fake cline that prints a build date before the version should still extract the version
# that follows 'cline', not the date. This catches the SWE-1.7 HIGH finding.
ANCHOR_FAKE="$TMP/anchor-fake-bin"
mkdir -p "$ANCHOR_FAKE"
cat > "$ANCHOR_FAKE/cline" <<'ANCHOR_CLINE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "build 2026.01.15 — cline 3.0.48"; exit 0; fi
echo "FAKE ANCHOR CLINE"; exit 0
ANCHOR_CLINE
chmod +x "$ANCHOR_FAKE/cline"
_av="$(PATH="$ANCHOR_FAKE:$PATH" _cline_version 2>/dev/null || echo ERR)"
if [ "$_av" = "3.0.48" ]; then
  ok "behavioral: _cline_version anchors on 'cline' token (extracts 3.0.48, not 2026.01.15)"
else
  bad "behavioral: _cline_version did not anchor on 'cline' token (got '$_av', expected 3.0.48)"
fi

# ============================================================================
# LAYER 3: ROUTER-SEAM DISPATCH (regression guard for the dead-on-dispatch defect)
# ============================================================================
# Every behavioral check above calls delegate_cline DIRECTLY, so 53/53 passed even while dispatch
# was DEAD: cline was missing from the route cost-class, provider-default-model, and lane-abbrev case
# arms, so `run --provider cline` died with "unknown provider" / "route resolution ambiguous" long
# before reaching the lane. Drive the REAL dispatch path via the CLI so any future drop-out of a case
# arm fails HERE. cline must NOT be on PATH (a clean PATH, no fake stubs) so a router that DOES reach
# the lane lands on the lane's own "cline CLI not on PATH" error — that error is the proof of dispatch.
# An earlier no-command `PATH=... _lanes=...` line leaked fake-bin into this shell's PATH globally, so
# strip it for the seam run (otherwise the fake cline answers and we never see the lane error).
_SEAM_PATH="${PATH//$SCRIPT_DIR\/fake-bin:/}"; _SEAM_PATH="${_SEAM_PATH//:$SCRIPT_DIR\/fake-bin/}"; _SEAM_PATH="${_SEAM_PATH//$SCRIPT_DIR\/fake-bin/}"
# --cloud-ack clears the one-time cloud-consent gate (the fresh test $OSRC_HOME has no stored consent)
# and --wait forces foreground (a non-interactive slow-lane run would otherwise auto-detach to bg and
# print a job receipt instead of the lane error). Routing (where the dead-lane defect died) runs BEFORE
# both, so a regressed cline still fails with "unknown provider"/"ambiguous" here regardless.
_seam_no_m="$( PATH="$_SEAM_PATH" bash "$SRC" run --provider cline --cloud-ack --wait "x" </dev/null 2>&1 || true )"
case "$_seam_no_m" in
  *"unknown provider"*|*"route resolution is ambiguous"*|*"route resolution ambiguous"*)
    bad "router seam (no -m): dispatch died before the lane -> [$_seam_no_m]" ;;
  *"cline CLI not on PATH"*)
    ok "router seam: run --provider cline (no -m) reaches the cline lane" ;;
  *) bad "router seam (no -m): unexpected output -> [$_seam_no_m]" ;;
esac
_seam_m="$( PATH="$_SEAM_PATH" bash "$SRC" run --provider cline -m glm --cloud-ack --wait "x" </dev/null 2>&1 || true )"
case "$_seam_m" in
  *"unknown provider"*|*"route resolution is ambiguous"*|*"route resolution ambiguous"*)
    bad "router seam (-m glm): dispatch died before the lane -> [$_seam_m]" ;;
  *"cline CLI not on PATH"*)
    ok "router seam: run --provider cline -m glm reaches the cline lane" ;;
  *) bad "router seam (-m glm): unexpected output -> [$_seam_m]" ;;
esac

echo
if [ "$fail" -gt 0 ]; then echo "RESULT: $fail FAIL(S), $pass pass"; exit 1; fi
echo "RESULT: $pass pass, 0 fail"
