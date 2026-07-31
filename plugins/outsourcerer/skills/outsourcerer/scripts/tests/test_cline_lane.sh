#!/usr/bin/env bash
# test_cline_lane.sh — the Cline engine lane must be wired into every provider list, expose a
# delegate that sends flags the CLI actually accepts, and map effort to cline's --thinking knob.
#
# Cline (https://github.com/cline/cline) is an engine lane like droid/cursor/hermes/warp:
# -m passes through VERBATIM (cline owns its provider/model catalog), and the FREE `cline` OAuth
# provider serves deepseek-v4-flash + glm-5.2 at $0 cash. Posture is binary (--plan = read-only,
# act mode = --auto-approve true); there is no OS sandbox and no graded approval rung.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

. "$SRC" >/dev/null 2>&1

# --- effort maps to cline's --thinking knob (none|low|medium|high|xhigh) ---
[ "$(_cline_effort minimal 2>/dev/null)" = "none" ]   && ok "minimal -> none (cline's lowest)"   || bad "minimal not mapped to none"
[ "$(_cline_effort low 2>/dev/null)" = "low" ]        && ok "low passes through"                  || bad "low altered"
[ "$(_cline_effort medium 2>/dev/null)" = "medium" ]  && ok "medium passes through"               || bad "medium altered"
[ "$(_cline_effort high 2>/dev/null)" = "high" ]      && ok "high passes through"                 || bad "high altered"
[ "$(_cline_effort xhigh 2>/dev/null)" = "xhigh" ]    && ok "xhigh passes through"                || bad "xhigh altered"
[ "$(_cline_effort max 2>/dev/null)" = "xhigh" ]      && ok "max -> xhigh (cline's highest)"      || bad "max not mapped to xhigh"
v="$(_cline_effort garbage 2>/dev/null)"
[ -z "$v" ] && ok "unknown effort yields empty (no --thinking flag emitted)" || bad "unknown effort produced '$v'"

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

# --- the fake-bin stub must echo, not execute (fork bomb trap) ---
# A stub that runs `cline 3.0.48` instead of `echo "cline 3.0.48"` would recurse infinitely if ever
# executed with fake-bin on PATH. Nothing executes it today, but a future test could.
grep -q '^echo "cline' "$SCRIPT_DIR/fake-bin/cline" && ok "fake-bin/cline uses echo (no fork bomb)" \
  || bad "fake-bin/cline does NOT use echo (latent fork bomb)"

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
_lists='devin|cc|codex|droid|cursor|hermes|warp|cline|gemini|gm|claudex|local'
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

echo
if [ "$fail" -gt 0 ]; then echo "RESULT: $fail FAIL(S), $pass pass"; exit 1; fi
echo "RESULT: $pass pass, 0 fail"
