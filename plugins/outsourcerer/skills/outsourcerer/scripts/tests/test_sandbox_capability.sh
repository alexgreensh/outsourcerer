#!/usr/bin/env bash
# test_sandbox_capability.sh — sandboxed jobs must have the capabilities users need:
#   P2-1 codex: the workspace-write sandbox disables network by default (verified live: curl HTTP:000),
#        which blocks the browser. delegate_cxnative must enable network on workspace-write (so a
#        sandboxed research/edit job can browse), with OSRC_NO_NET=1 to opt back into isolation.
#   P2-2 devin: research must map to a WRITE-capable sandboxed mode. `autonomous` auto-approves exec but
#        gates file WRITES; devin `smart` inherits accept-edits (writes) + safe exec. Default research to
#        smart (OSRC_DEVIN_RESEARCH_MODE), still --sandbox.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

# P2-1: codex can enable sandbox network for the browser, but ONLY via explicit opt-in (network stays
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
# browser mode must load the user config (else the browser MCP stays stripped by --ignore-user-config).
grep -q '\[ "\$_browser" = "1" \]; } || iso=(--ignore-user-config)' "$SRC" \
  && ok "OSRC_BROWSER loads the user config so the browser MCP is available" \
  || bad "OSRC_BROWSER does not restore the browser MCP (still stripped by --ignore-user-config)"

# P2-2: devin research no longer maps to the write-gating 'autonomous'; defaults to a write-capable mode.
grep -q 'OSRC_DEVIN_RESEARCH_MODE:-smart' "$SRC" \
  && ok "devin research defaults to a write-capable sandboxed mode (smart), overridable" \
  || bad "devin research still uses the write-gating mode — files cannot be saved headless"
# the old hardcoded write-gating call must be gone.
grep -q 'delegate "autonomous" "--sandbox"' "$SRC" \
  && bad "devin research still hardcodes 'autonomous' (writes gated)" \
  || ok "the hardcoded write-gating 'autonomous' devin research call is removed"
# still sandboxed (research != yolo).
grep -q 'delegate "$_drm" "--sandbox"' "$SRC" \
  && ok "devin research stays OS-sandboxed (--sandbox preserved)" \
  || bad "devin research lost its --sandbox (would be indistinguishable from yolo)"
# the override must be VALIDATED (a typo / the invalid 'autonomous' must not reach the CLI).
grep -qE 'OSRC_DEVIN_RESEARCH_MODE must be one of' "$SRC" \
  && ok "OSRC_DEVIN_RESEARCH_MODE is validated against auto|accept-edits|smart|dangerous" \
  || bad "the research-mode override is unvalidated (a typo reaches the devin CLI and fails late)"
# the posture preflight must key on the EFFECTIVE mode, not a hardcoded 'autonomous' (else a cached
# autonomous restriction defeats the smart fix).
grep -q '_posture_get devin "$_drm"' "$SRC" \
  && ok "the devin posture preflight keys on the effective research mode, not hardcoded autonomous" \
  || bad "posture preflight still hardcodes autonomous — a cached restriction blocks the smart fix"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
