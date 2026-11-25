# osrc-l5-r3: parallel by default

Base: `cloud/osrc-l5-parallel` @ 0da2dd0 (one WIP commit over main ea34fe0).

## Plan
1. Audit the WIP diff (factory-flow.sh, factory-tasks.sh, new lib/factory-parallel.sh) against ea34fe0 for lost behaviour.
2. Entry flow: task list -> dependency/file-ownership waves -> parallel launch up to a resource-aware limit.
3. Non-blocking held decisions with default + deadline; irreversible/paid/publish never auto-apply.
4. Optional per-repo profile; review-round cap (default 3) with escalation record.
5. Lean MCP launch for local lanes per engine.
6. SKILL.md <= 150 lines; detail to references.
7. Regression tests for the three incidents + lean launch; conformance run.
