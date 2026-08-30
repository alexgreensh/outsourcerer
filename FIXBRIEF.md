# Fix cycle 2 — the 2 findings the retorture left OPEN (release 0.10.1)
Full verification: ~/CascadeProjects/Prompts/PERSONAL_OS/PROJECTS/outsourcerer/retorture-0.10.1/verify.md
File: plugins/outsourcerer/skills/outsourcerer/scripts/outsourcerer.sh (bash 3.2, set -u).

Fix these two. Read verify.md's F4 and F6 entries for exact lines + live-probe evidence first.

F6 (P0 — a REGRESSION the last fix introduced; most important):
  _session_relaunch_effort (~13746-13751) respawns the pane with NO liveness check and writes NO
  new start record. Worse: respawn-pane -k kills the old pane pid, so the next
  _session_registry_reap_dead appends `end crash-reap` OVER THE LIVE NEW ENGINE — a deterministic
  supervision-kill of a healthy session, introduced by the new identity coalescing.
  FIX: route the effort-relaunch through the SAME _session_launch_finalize path control-relaunch now
  uses (liveness → new start record → heartbeat → endpoint re-proof), so the reaper sees the new
  generation and never ends a live session. Add a regression test proving an effort-relaunch leaves a
  steerable session that the reaper does NOT kill.

F4 (HIGH — two residual paths from arch F2):
  (a) harness_pid is the tmux pane-SHELL pid, so an engine that exits while its shell stays alive is
      never reaped (looks live forever).
  (b) a verified `session control exit` appends NO end event — dead delegate stays "live" in the
      registry + heartbeat, and the fleet emits a state:unknown wake for it.
  FIX: record/verify the actual engine liveness, not just the pane shell (a completion sentinel or an
  engine-pid check); and make `session control exit` append a terminal end event. Regression tests for
  both: engine-child-exit-with-live-shell gets reaped; control-exit writes end and stops the wake.

ALSO fold in (cheap, same files, from the GLM pass — all LOW):
  - _heartbeat_start spawn check fails OPEN on unreadable pid_start → fail closed.
  - _managed_menu_answer label match treats glob chars in the selector literally (quote/escape it).
  - Codex menu detection: verify which option is highlighted rather than assuming default=option 1.

RULES: each fix ships its regression test in scripts/tests/, registered in conformance.sh, kept green
(cd scripts/tests && OSRC_HEARTBEAT_DISABLED=1 bash conformance.sh). Verify against real code/real
--help. Focused commits, same style as the branch history. Do not regress F1-F3,F5,F7-F13 (all closed).
