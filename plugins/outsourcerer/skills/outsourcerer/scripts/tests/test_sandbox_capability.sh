#!/usr/bin/env bash
# test_sandbox_capability.sh — sandboxed jobs must have the capabilities users need:
#   codex: the workspace-write sandbox disables network by default (verified live: curl HTTP:000),
#        which blocks the browser. delegate_cxnative must enable network on workspace-write (so a
#        sandboxed research/edit job can browse), with OSRC_NO_NET=1 to opt back into isolation.
#   devin: --sandbox always forces the autonomous permission mode and gates headless file writes
#        (verified live), so sandbox and writes are mutually exclusive. Secure default keeps the sandbox
#        (read/exec) and warns; OSRC_DEVIN_RESEARCH_WRITE=1 drops --sandbox and uses accept-edits so
#        writes work (unsandboxed); codex research is the sandboxed-write lane.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

# codex can enable sandbox network for the browser, but ONLY via explicit opt-in (network stays
# OFF by default — default-on would be an exfiltration regression on every job).
grep -q "sandbox_workspace_write.network_access=true" "$SRC" \
  && ok "codex sandbox CAN enable network (the flag exists for browser tasks)" \
  || bad "codex sandbox has no network path — browser/web fetch impossible"
grep -qE 'OSRC_BROWSER' "$SRC" && grep -qE 'OSRC_NET' "$SRC" \
  && ok "network is opt-in via OSRC_BROWSER / OSRC_NET (secure default: isolated)" \
  || bad "no OSRC_BROWSER/OSRC_NET opt-in — network cannot be turned on for the browser"
# network must be GATED on the opt-in (not applied unconditionally). Prove the guard exists.
grep -q 'if \[ "\$_net" = "1" \]' "$SRC" \
  && ok "the network flag is gated behind the _net opt-in, not default-on" \
  || bad "network flag is not gated on the opt-in — default-on exfiltration regression"
# SECURITY: OSRC_BROWSER must NOT auto-load the user config — that would pull in EVERY MCP server
# (credential-backed ones included) and ship them to the cloud delegate. The full-config load stays a
# separate deliberate opt-in (OSRC_CODEX_USER_CONFIG=1).
grep -q 'local iso=(); \[ "\${OSRC_CODEX_USER_CONFIG:-0}" = "1" \] || iso=(--ignore-user-config)' "$SRC" \
  && ok "OSRC_BROWSER does NOT drop --ignore-user-config (no MCP-credential exposure to the cloud)" \
  || bad "OSRC_BROWSER still auto-loads the full user config — MCP credentials leak to the cloud delegate"

# devin --sandbox and headless writes are mutually exclusive (verified live), so writes are an
# explicit opt-in that DROPS the sandbox; the secure default keeps the sandbox (read/exec) and warns.
grep -q 'OSRC_DEVIN_RESEARCH_WRITE' "$SRC" \
  && ok "devin research WRITE is an explicit opt-in (OSRC_DEVIN_RESEARCH_WRITE)" \
  || bad "no OSRC_DEVIN_RESEARCH_WRITE opt-in — write-needing research still dies silently on devin"
# write mode drops --sandbox and uses accept-edits (the only headless-write combo on devin).
grep -q 'delegate "accept-edits" "" ' "$SRC" \
  && ok "devin research WRITE mode uses accept-edits WITHOUT --sandbox (the combo that actually writes)" \
  || bad "devin write mode does not use accept-edits-no-sandbox — writes will not work"
# secure default keeps the OS sandbox (autonomous).
grep -q 'delegate "autonomous" "--sandbox"' "$SRC" \
  && ok "devin research default keeps the OS sandbox (autonomous, read/exec)" \
  || bad "devin research default lost its --sandbox (secure default broken)"
# the misleading 'smart --sandbox' no-op must be gone (it printed 'ignoring --permission-mode smart').
grep -q 'delegate "$_drm" "--sandbox"' "$SRC" \
  && bad "the broken 'smart --sandbox' devin research call is still present (it does not write)" \
  || ok "the broken 'smart --sandbox' no-op is removed"
# the default path must WARN that writes are blocked + name the two ways to write.
grep -q 'sandboxed research is READ/EXEC only' "$SRC" \
  && ok "devin sandboxed research warns writes are blocked and points to codex / the write opt-in" \
  || bad "no upfront warning — a write-needing devin research job dies silently at its first write"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
