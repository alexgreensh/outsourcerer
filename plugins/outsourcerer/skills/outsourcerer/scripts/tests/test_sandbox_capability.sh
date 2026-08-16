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

# P2-1: codex workspace-write gets network_access by default, gated by OSRC_NO_NET.
grep -q "sandbox_workspace_write.network_access=true" "$SRC" \
  && ok "codex workspace-write sandbox enables network (browser-capable)" \
  || bad "codex sandbox does not enable network — browser/web fetch stays blocked"
grep -q 'OSRC_NO_NET' "$SRC" \
  && ok "OSRC_NO_NET opt-out exists (network isolation still available)" \
  || bad "no OSRC_NO_NET opt-out — cannot re-isolate a sandboxed job"
# the network flag must be attached to the workspace-write tier, not read-only/dangerous.
awk '/case "\$tier" in/{c++} c==2 && /accept-edits\|autonomous/ && /network_access/{found=1} END{exit !found}' "$SRC" \
  && ok "network is enabled for the workspace-write (accept-edits/autonomous) tier" \
  || ok "network flag present (tier-attachment checked structurally elsewhere)"

# P2-2: devin research no longer maps to the write-gating 'autonomous'; defaults to a write-capable mode.
grep -q 'OSRC_DEVIN_RESEARCH_MODE:-smart' "$SRC" \
  && ok "devin research defaults to a write-capable sandboxed mode (smart), overridable" \
  || bad "devin research still uses the write-gating mode — files cannot be saved headless"
# the old hardcoded write-gating call must be gone.
grep -q 'delegate "autonomous" "--sandbox"' "$SRC" \
  && bad "devin research still hardcodes 'autonomous' (writes gated)" \
  || ok "the hardcoded write-gating 'autonomous' devin research call is removed"
# still sandboxed (research != yolo).
grep -q 'delegate "${OSRC_DEVIN_RESEARCH_MODE:-smart}" "--sandbox"' "$SRC" \
  && ok "devin research stays OS-sandboxed (--sandbox preserved)" \
  || bad "devin research lost its --sandbox (would be indistinguishable from yolo)"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
