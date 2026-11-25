# osrc-l5-r3: parallel by default

Base: `cloud/osrc-l5-parallel` @ 0da2dd0 (one `WIP:` commit over main ea34fe0). Work branch: `cloud/osrc-l5-r3`.

## Audit of the inherited WIP

- The WIP moved `_ff_next_default`, `_ff_apply_defaults`, `_ff_dispatch`, `_ff_review_failed` (from
  factory-flow.sh) and `_task_worker_prompt` (from factory-tasks.sh) into `lib/factory-parallel.sh`. I diffed
  each moved function against main: every old line is still there; the additions are the file-ownership
  wait, the gate check, the `.hold.risk` filter and the review-round cap. Nothing the old flow did was lost.
  `--max-parallel` validation moved into `_osrc_fp_max_parallel` (still rejects 0 and non-numbers).
- Bugs fixed in the WIP module:
  - The profile parser dropped every quoted key (`"npm test" = ...`), so `[factory.heavy]` never worked;
    `_osrc_fp_profile_file` had an invalid nested default. Replaced by one line-by-line parser (`_osrc_fp_profile`).
  - `_osrc_fp_check`, `_osrc_fp_heavy_for`, `_osrc_fp_bench_for` were never called (the profile was decorative).
    The check now defaults `plan start` tasks' `--check`; heavy commands and bench paths go into every worker's
    brief (`_osrc_fp_brief_rules`). Dead `_osrc_fp_overlap`, `_osrc_fp_defaultable`, `_osrc_fp_risky_hold` removed.
  - The profile was read from the current folder, not the plan's repo. `plan run` now reads the plan's repo profile.
  - "Resource-aware" was only a user hook. Added a built-in gate (free disk under `OSRC_DISK_MIN_GB`, load per core
    over `OSRC_FACTORY_LOAD_MAX`, macOS via the engine's `_osrc_mac_overloaded`) that tolerates any missing
    function or reading, and a CPU-based default cap (3; 2 on <=4 cores; 1 on <=2).
- Already on main (honest note): `plan run` already launched up to 3 ready tasks per pass, and held decisions with
  `--default --until` already applied at the deadline. The gap was that orchestrators never reached that flow
  (7 `task add` vs 413 `session start`). Incident tests 1 and 2's base behaviour therefore passes on main; the new
  guards (file ownership, paid/irreversible/publish never auto-apply, review cap, gate, profile, `plan start`) fail there.

## What changed

1. `plan start <plan> <tasks-file|->` (`scripts/lib/factory-start.sh`): one list to a running plan. Lines are
   `key | what to do | after=.. | files=.. | ...`. Prints the order and the reason for each wait (declared or shared
   files), refuses forward `after=` and duplicate keys before creating anything, adds tasks through `task add`,
   then runs one `plan run --once` pass so the first wave launches in parallel (`--run` drives to the end,
   `--dry-run` creates nothing).
2. Launch cap: `--max-parallel`, `OSRC_FACTORY_PARALLEL`, profile `parallel`, CPU default. Gate per launch pass; a
   gate only delays launches and never fails a task; `OSRC_FACTORY_GATE=off` disables it.
3. Non-blocking decisions: `task hold --default --until` (only that task waits); `--risk irreversible|paid|publish`
   never auto-applies; unknown risk labels are refused at the CLI and treated as risky by the scheduler.
4. Optional `<repo>/.outsourcerer.toml` (`check`, `gate`, `parallel`, `[factory.heavy]`, `[factory.bench]`), read
   line by line, never sourced.
5. Review cap `OSRC_FACTORY_REVIEW_ROUNDS` (default 3): a fourth round is held and a pending escalation record is
   written; it runs once the record is approved for that round (or the captain releases the reviewer).
6. SKILL.md rewritten around `plan start` (164 -> 138 lines). Long rule text moved verbatim to
   `references/factory-operating-rules.md`; every safety rule keeps a line in SKILL.md. Also removed a personal
   name from the hub paragraph ("when you need the user"). `references/factory*.md` document `plan start`, the cap,
   gate, file ownership, review cap, profile, `--risk` and `--files`.
7. Lean lane launch (`scripts/lib/leanlaunch.sh`): interactive Claude lanes now launch with
   `--strict-mcp-config --mcp-config` by default, carrying only servers declared with `--with mcp=a,b` (copied to a
   private per-session file that outlives `session start`) or `OSRC_LEAN_MCP_CONFIG`, else none.
   `OSRC_SESSION_MCP=full` opts back in; `OSRC_LEAN_LAUNCH=1` forces lean.
   - Claude headless lanes and Codex headless (`--ignore-user-config`) were already isolated; unchanged.
   - **Devin: no supported way to limit MCP servers per launch.** Devin CLI docs list MCP servers only in persistent
     `mcp_config.json` files and the `devin mcp` subcommands; no per-run flag. I did not hack it (e.g. swapping its
     config dir), so Devin lanes still start the servers in its config. This was the lane measured at 0.85 GB.
   - **Codex interactive sessions** (`_session_launch_cx` in outsourcerer.sh): not changed. I could not verify a
     supported top-level flag that limits MCP servers for the interactive CLI here, and outsourcerer.sh may only shrink.

## Tests (all run in this container, niced)

| command | rc |
|---|---|
| `bash scripts/tests/test_factory_flow.sh` (196 passed; 15 new L5 checks) | 0 |
| same suite against main's code (ea34fe0 worktree): 10 of the new checks FAIL | 1 (expected) |
| `bash scripts/tests/test_factory_tasks.sh` (175 passed) | 0 |
| `bash scripts/tests/test_factory_e2e.sh` (10 passed) | 0 |
| `bash scripts/tests/test_factory_land.sh` (116 passed) | 0 |
| `python3 scripts/tests/test_lean_launch.py` (6 tests) | 0 |
| same, with the old leanlaunch.sh: 1 failure + 1 error | 1 (expected) |
| `bash scripts/tests/test_perm_profiles.sh` (expectation updated for the lean flags) | 0 |
| accounts, codex_code_mode_host, droid_session, gemini_lane, interactive_default, session_capabilities, session_effort_guard, session_exit_liveness, session_model_pin_guard, session_probe_sigpipe | 0 each |
| `python3 scripts/check_file_size.py --base ea34fe0` | 0 |
| `bash scripts/tests/conformance.sh` | see below |

New checks (test_factory_flow.sh, `L5` prefix): 3 independent tasks start in one pass at cap 3; overlapping files
wait with the reason; an open decision does not stop other tasks; the default applies at the deadline; a paid
decision never auto-applies; unknown `--risk` refused; round four held with a pending escalation record after three
reviews; approved record lets round four run; cap settings; repo gate pauses; broken gate fails open; built-in disk
gate pauses and tolerates its own absence; profile parsing feeds check/cap/heavy/bench; no profile adds nothing;
`plan start --dry-run` ordering; `plan start` launches the independent tasks together; bad lists create nothing.

## Not proven

- The load gate and CPU default on macOS and Git Bash were not run here (Linux only). They use `getconf`, `sysctl`,
  `/proc/loadavg` or `uptime` with fallbacks, and any missing reading means "go".
- Real engines were never launched; the scheduler tests use the suite's fake job seam.
- The lean Claude launch was checked by argv, not by counting processes on a live machine.

## Needs from other lanes

- Codex interactive sessions (`_session_launch_cx`, outsourcerer.sh): add a lean MCP option if Codex's interactive
  CLI supports one (owner of the launch builders).
- Devin: limiting MCP servers needs a Devin CLI feature (per-run MCP config); nothing to do in this repo until then.

## Open questions (decided by the lane)

- Report file name: the lane rules ask for `reports/<lane id>.md`, so the plan pushed as `reports/osrc-l5-parallel.md` was renamed to `reports/osrc-l5-r3.md`.
- `plan start` default: one scheduler pass (`plan run --once`) that launches the first wave in parallel and returns, so an orchestrator is never blocked for hours; `--run` drives to the end. Safer for a session that must keep supervising.
- Default launch cap: 3, lowered to 2 on 4 cores or fewer and 1 on 2 or fewer. This suits a stranger's laptop; users raise it with `OSRC_FACTORY_PARALLEL` or the profile.
- Unknown `--risk` labels: refused at the CLI. Any non-`reversible`/`safe` label stored by other means counts as risky and never auto-applies.
- Lean MCP: on by default for interactive Claude lanes; opting out takes an explicit `OSRC_SESSION_MCP=full`. Devin and Codex interactive lanes are not changed (see above).
- Profile name `.outsourcerer.toml` at the repo root, kept from the WIP because `.outsourcerer/config.toml` already holds shared budget defaults.
- Pull request: none opened, following the lane rules.

## Conformance

`test_harness_isolation` fails in this container for a reason unrelated to this lane: the container runs as root, so its "uncreatable" path `/nonexistent-root-cannot-create` gets created and the fail-closed check sees rc 0. That code (`build_mcp_flags_cc`) is untouched here. I left the directory in place (removing a root-level path needed an approval nobody could give).
