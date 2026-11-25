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
| `bash scripts/tests/conformance.sh` (239 passed, 8 failed, 1 skipped) | 1 |

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

`nice bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh`: rc=1, 239 passed, 8 failed, 1 skipped.
I ran each failing suite alone against this head and against main (ea34fe0, a worktree):

| suite | main | this head | cause |
|---|---|---|---|
| test_harness_isolation | 1 | 1 | container runs as root: the "uncreatable" `/nonexistent-root-cannot-create` gets created |
| test_vocab_hygiene | 1 | 1 | root ignores read-only files ("failed rewrite reported success") |
| test_parity_insource_refresh | 1 | 1 | same, read-only target written as root |
| test_supervise_pgroup_kill | 1 | 1 | fails on main too (not investigated, outside this lane) |
| test_conformance_suite_timeout | 1 | 1 | fails on main too |
| test_sealed_fixes | 1 | 1 | fails on main too |
| test_release_0175 | 0 | 0 | passes alone on both; failed only under the full suite's load |
| test_no_pipe_grep_q | 0 | 1 -> 0 | **mine**: new L5 checks piped `printf | grep -q`. Fixed with here-strings; suite now rc=0, test_factory_flow 196/196 |

After that fix I did not rerun the full conformance suite; the remaining failures are identical on main.
`/nonexistent-root-cannot-create` (created by test_harness_isolation as root) was left in place: removing a
root-level path needed an approval nobody could give.

## Round 4 (lane osrc-l5-r4)

Base `cloud/osrc-l5-r3` @ b55651c (confirmed with `git log --oneline -3`). Work branch `cloud/osrc-l5-r4`.
All five P2s and every P3 from the review are fixed. Where I could, I deleted a mechanism instead of patching it.

### P2 fixes

1. **Escalation record is now an audit trail, not a second approval path.** I deleted `_osrc_fp_escalation_ok` and
   the "set `approved: true`" wording. After the cap, the reviewer is held. The pending record is written at
   `$OSRC_HOME/plans/<plan>/escalations/<tid>.json`, and the hold lists the usual commands. `task release --answer`
   runs the next round, and the scheduler's captain path then stamps the record `approved` with the answer
   (`_osrc_fp_escalation_approve`). Test: the cap hold no longer asks anyone to edit the record. Release with no
   record edit runs round four, and the record reads `approved` with that answer.
2. **Gate tests never read the machine.** `calm()` stubs every reading the gate uses: `_osrc_free_kb` (read by
   `_osrc_disk_gate`), `_osrc_cleanup_items`, `_osrc_fp_load1`, `_osrc_fp_ncpu`, and `uname` plus `osrc_mac_load` for
   macOS swap. Each check then overrides one reading. The base fails the macOS-at-85%-swap check; that is the
   reviewer's Mac.
3. **The disk gate is the launch gate.** The built-in free-KB check is deleted. The pass runs `_osrc_disk_gate`
   itself in a subshell (it `die`s when it refuses), so the ASK-list hash and ack file are the same code. The reason
   is that gate's own message plus `Override: OSRC_DISK_MIN_GB=0`. Test: at 8 GB free with one ASK item the pass
   pauses; after the real `_osrc_cleanup_ack` it goes. `OSRC_DISK_MIN_GB=0` lifts the pause.
4. **macOS has its own swap rule for plan launches.** `_osrc_mac_overloaded` (the heavy-command rule, 80%) is no
   longer called. Load per core uses the same reading on every OS (`OSRC_FACTORY_LOAD_MAX`, 2). Swap on macOS
   (`_osrc_fp_swap_pct` from `osrc_mac_load`) uses `OSRC_FACTORY_SWAP_MAX_PCT`, default 95, because macOS grows swap
   on demand. Each reason names the reading and the variable ("swap is 97% used, over 95% (OSRC_FACTORY_SWAP_MAX_PCT;
   0 turns it off)"). All four variables, including the heavy-command `OSRC_MAC_LOAD_MAX_PC` and
   `OSRC_MAC_SWAP_MAX_PCT`, are documented in `references/factory-flow-cli.md`. SKILL.md names the plan ones.
5. **Ordering by files is dropped, and the overlap is reported.** I deleted the scheduler's file-ownership wait. In
   its place, `plan start` prints `note: b and a both touch x -> y ...` for every overlap.
   - Why not the other design: making the later task start from the earlier one's landed work needs one of two
     things. (a) `plan start` auto-lands into the user's base branch, a merge with nobody approving it. (b) Ship
     worktrees are cut from a dependency's branch, a new base mechanism that would also change what `land`
     merges.
   - Both are larger and touch the merge path. Dropping the wait is the smaller correct change. The wait only
     delayed work; it never gave the later task the earlier task's commits. The merge gate still reports a real
     conflict at land.
   - Test: three ship tasks with overlapping `files` all start in one pass.

### P3 fixes

- **Dotted keys:** dep lookup is an exact `case` match (`_osrc_fs_lookup`), not a `sed` regex. Test: `after=a.b`
  with keys `a.b` and `axb` gives exactly `t1`.
- **Printed order:** with no file wait, the order is `starts now` or `after X (declared)`, which matches the
  scheduler. Test: the reviewer's `z`/`a`/`b` case.
- **`after=` globbing:** `after` is checked against the key pattern before the loop. Test: `after=*` is refused.
- **Review rounds:** `review_rounds` now counts failed rounds. It goes up in the redo commit (`_ff_review_failed`),
  not before dispatch, so a lost claim or failed launch no longer burns a round. The cap test still holds round
  four after three reviews.
- **Cap test:** split into two checks.
- **MCP config copy:** `_session_registry_end`, which runs on tmux stop, winpty stop, control exit and failed
  launch, now removes `sessions/mcp-<name>.json`. The path comes from `_session_mcp_copy` in `lib/leanlaunch.sh`.
  outsourcerer.sh changed one line in place (no growth). Test: in `test_lean_launch.py`, the copy is gone after
  `_session_registry_end stop`.
  - Not covered: a user who quits claude inside the pane with no stop or control command. The copy stays until
    the next start with that session name overwrites it.
- **`OSRC_CLAUDE_USER_CONFIG=1`:** interactive lanes now treat it like `OSRC_SESSION_MCP=full`, matching headless
  lanes. Combined with `OSRC_LEAN_LAUNCH=1` it still refuses, as headless does. Test added.
- **Gate with arguments:** a gate path that is not a file is ignored with one warning per value. Test added.
- **Repeated wait lines:** the pause reason prints when it changes, not every pass. Test: two passes, one line.
- **`plan start` decisions and reruns:**
  - `hold=` lines take `default=`, `until=` and `risk=`. The task is created held, then `task hold` adds those
    fields, so `task hold`'s rules apply: unknown risk refused, default needs until. If that step fails, the task
    stays held, which is the safe side.
  - A rerun reuses an existing plan and skips keys that are already task titles there.
  - Tests: default, deadline and `risk=paid` are stored; a rerun on a half-built plan adds only the missing task.
- **SKILL.md path:** now `$OSRC_HOME/plans/<plan>/escalations/<tid>.json`, worded around `task release`.
- **RESULT:** this round's RESULT carries this branch's own sha and the real conformance rc (see below).

### Size

- `scripts/lib` (factory-parallel + factory-start + leanlaunch): 712 lines on the base, 710 now.
- `outsourcerer.sh`: one line changed in place.
- The L5 checks moved to `scripts/tests/lib_factory_flow_l5.sh`, a part file sourced by `test_factory_flow.sh` with
  the same fixtures. It is not a suite, so there is no new registration. This keeps the test file under 1,000 lines.

### Tests (this container, niced)

| command | rc |
|---|---|
| `bash scripts/tests/test_factory_flow.sh` (209 passed) | 0 |
| same suite and `test_lean_launch.py` against the base code (b55651c worktree): 15 flow failures, including every P2 test, plus 2 lean failures | 1 (expected) |
| `python3 scripts/tests/test_lean_launch.py` (7 tests) | 0 |
| `bash scripts/tests/test_factory_tasks.sh` (175) / `test_factory_e2e.sh` (10) / `test_factory_land.sh` (116) | 0 / 0 / 0 |
| `bash scripts/tests/test_perm_profiles.sh` (94) / `test_heavy.sh` (123) / `test_no_pipe_grep_q.sh` | 0 / 0 / 0 |
| `python3 scripts/check_file_size.py --base b55651c` | 0 |

### Not proven

- macOS and Git Bash were not run. The macOS path is tested only through the `uname` and `osrc_mac_load` seams.
- On a real Mac, `_osrc_fp_load1` reads `uptime`. A locale that prints a comma decimal ("4,15") reads as 4, which
  is a little lenient, never a wedge.

### Open questions (decided by the lane)

- **P2 5 design:** drop the file ordering and report overlaps, rather than auto-landing or cutting from a
  dependency's branch (reasons above).
- **macOS plan-launch swap threshold:** 95% by default; 0 turns it off.
- **Approval stamp location:** written by the scheduler's captain-release path (`lib/factory-parallel.sh`), not in
  `_task_cli_release`. factory-tasks.sh is over the size ratchet and may not grow, and the stamp then happens only
  when the round really runs.
- **Branch:** pushed to `cloud/osrc-l5-r4` as the brief says. No pull request, per the lane rules.

### Needs from other lanes

- Removing the MCP config copy when a user quits claude inside the pane, with no stop or control command, needs a
  pane-exit hook in the session launch builder (outsourcerer.sh owner).

### Conformance

`nice bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh`: **rc=1**, 241 passed, 6 failed, 1 skipped.
The six failures are `test_harness_isolation`, `test_vocab_hygiene`, `test_supervise_pgroup_kill`,
`test_parity_insource_refresh`, `test_conformance_suite_timeout` and `test_sealed_fixes`. The round-3 table above
shows these same six failing on main. I did not rerun them against main this round. `test_no_pipe_grep_q` and
`test_release_0175` pass in this run. The RESULT says `rc=1`.
