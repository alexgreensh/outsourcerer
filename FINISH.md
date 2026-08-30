# FINISH the F4/F6 fix — a prior session ran out of context mid-work

A rescue commit (4820c18) captured incomplete work. It breaks 3 conformance suites:
test_model_pin_enforcement, test_session_effort, test_session_registry_end.
Your job: FINISH the fix so all three pass and the two open findings actually close.

START HERE:
1. Read docs/plans/2026-08-30-f4-f6-low-fixes.md — the prior session's own plan for F4/F6 + the 3 LOWs.
2. Read /Users/alexgreenshpun/CascadeProjects/Prompts/PERSONAL_OS/PROJECTS/outsourcerer/retorture-0.10.1/verify.md entries F4 and F6 — the exact open paths + live-probe evidence.
3. Run the 3 failing suites to see what's half-done:
   cd plugins/outsourcerer/skills/outsourcerer/scripts/tests
   for t in test_model_pin_enforcement test_session_effort test_session_registry_end; do
     OSRC_HEARTBEAT_DISABLED=1 bash $t.sh 2>&1 | tail -15; done

THE TWO FINDINGS TO CLOSE:
- F6 (P0 regression): _session_relaunch_effort must go through the SAME finalizer control-relaunch uses
  (liveness -> new start record -> heartbeat -> endpoint re-proof), so the reaper sees the new generation
  and never appends crash-reap over the LIVE new engine. The registry_end failure is likely this.
- F4: track real engine liveness not the pane-shell pid; make 'session control exit' append a terminal
  end event. The session_effort + registry_end failures are likely here.

RULES: get ALL of conformance green (cd scripts/tests && OSRC_HEARTBEAT_DISABLED=1 bash conformance.sh),
do not regress the 11 already-closed findings, commit when green. If a test's EXPECTATION is now wrong
because behaviour legitimately changed, fix the test to assert the new fail-closed contract - but say so.
Verify against real code. Commit with a clear message; you may amend/replace the WIP rescue commit.
