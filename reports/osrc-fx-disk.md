# osrc-fx-disk: release-gate fixes, disk safety (0.18.0)

Base: `cloud/osrc-int` at the pinned commit `1e0064b`. Branch: `cloud/osrc-fx-disk`.

I read the earlier work in my area (`lib/cleanup.sh`, `lib/disk_policy.sh`, the factory gate and
their suites) while fixing it. I kept the existing design (floors, pause records, identity checks,
the one-use code, the audit log) and changed only what the findings showed to be wrong. I did not
re-verify the other 70 commits since `ea34fe0`; they are outside this lane.

## What changed and why

| Finding | Fix | Where |
|---|---|---|
| EH F1 | When free space cannot be read, the launch is refused with its own message ("cannot read free disk for $OSRC_HOME ... Check: df -kP"). The one-use override code is offered and admits, so a machine where df never parses is not wedged. The factory probe refuses too. | `_osrc_disk_gate` |
| EH F3 | A tick whose reading cannot be read, with pauses on record, resumes everything and wakes once (`disk-unreadable`). | `_osrc_disk_monitor_tick`, `_osrc_disk_readings` |
| EH F2 | `_osrc_lsof_busy` reports clear only when a sentinel line (`__osrc_lsof_rc=0/1`), printed after lsof inside the wrapped command, ends the capture. A `_timeout` setup failure, a crash, or a write lost on a full disk now gives 2 (ASK). | `lib/cleanup.sh` |
| CC F1 | The monitor starts through a double fork with job control on: it is re-parented to init and leads its own process group, so cancelling or timing out its launcher's group or tree cannot reach it. It waits for its forking subshell to exit before the first tick, so no lane's tree holds that subshell. Git Bash keeps the plain background child. On exit it resumes only when free space is at or above the pause floor, pausing is off, a `disk resume` hold exists, or the reading cannot be read. Otherwise it keeps the records. `_osrc_disk_heartbeat` (and `disk status`) start a monitor whenever records exist or free space is under the pause floor. | `lib/disk_policy.sh` |
| LR F1 | The loop sleeps with `sleep & wait`, so a TERM runs the trap at once. The exit handler kills the sleep. | `_osrc_disk_monitor_loop` |
| CC F5 | `disk resume` writes its hold before resuming. The sweep checks the hold before each lane and again after each SIGSTOP: a lane stopped after the hold was written is resumed by the sweep itself. | `_osrc_disk_cmd`, `_osrc_disk_held` |
| EH F4 | When the floor computation breaks, the gate falls back to a 10 GB launch floor and a 1 GB critical floor (it used to fall back to 0). | `_osrc_disk_gate` |
| EH F5 | In the SAFE classifier, `git status` (both scans) is captured with its rc; a failure gives ASK with "git status failed in the worktree". | `_osrc_cleanup_verdict` |
| EH F6 | `gh pr list` runs under `_timeout ${OSRC_CLEANUP_GH_TIMEOUT:-15}`; a timeout means not preserved (ASK). The gate's `du` runs under `_timeout 20`. | `lib/cleanup.sh` |
| EH F7 | The factory resource gate fails closed. Exit 0 goes. Exit 1 holds with the gate's own reason. Any other rc holds and names the rc. No answer within `OSRC_FACTORY_GATE_TIMEOUT` (30 s) holds. The next pass asks again, so a fixed gate releases the plan. | `lib/factory-parallel.sh` |
| EH F8 / AR F2 (disk part) | The gate refuses unless the last function of each disk lib is defined (`cmd_gc`, `_osrc_disk_cmd`); a truncated or failed source drops these. The three call sites now call `_osrc_disk_gate <kind> \|\| die`, and the factory treats a missing gate as "hold". | `lib/cleanup.sh`, `outsourcerer.sh`, `lib/factory-parallel.sh` |
| CC F4 / PR F3 | A refusal reuses the current code while it is unclaimed with more than 2 minutes left. A claim is an exclusive create of `override.taken.<code>`, never a rewrite. Replacing an expired or claimed code renames it aside first and creates the new one exclusively. The factory calls the gate in `probe` mode: it never takes or mints a code and never registers. | `lib/disk_policy.sh`, `lib/cleanup.sh` |
| AR F3 / CC F6 (coverage) | `_osrc_disk_gate` takes an explicit kind (`fg`, `job`, `tmux`, `tmux-respawn`, `probe`) in place of `FUNCNAME`. `session start` and `session model` are gated as `tmux`; `session control relaunch` and `session effort <level>` as `tmux-respawn`. A respawn re-registers the session as pending and remembers the current pane: the new pane binds, and a respawn that never happened binds back to the old pane instead of dropping the lane. Registration happens only once a launch is admitted, so a refused launch leaves no record and the monitor never pauses the gate's own scan. | `_osrc_disk_session_gate`, `_osrc_disk_register_caller`, `_osrc_disk_reg_root` |
| CC F6 (locks) | The sweep does not stop, for that tick, a lane where any process owns an Outsourcerer mkdir lock (`*.lock/owner` under `$OSRC_HOME`, depth 4) or is a git command under 2 minutes old. It retries on the next tick. Documented: a stopped holder passes `kill -0`, so lock breakers already treat it as alive (paused) and never break its lock. No new locking. | `_osrc_disk_busy_pids`, `_osrc_disk_rec_busy` |
| CC F7 | `_sv_observe` short-circuits a disk-paused job or tmux lane: owed a waiter, no event, stall clock restarted, no nudge or `continue` typed into it. The watcher uses the same function. | `lib/supervise.sh` (7 lines), `_osrc_disk_target_paused` |
| spec F5 | One SAFE rule in code and docs: a branch or worktree is SAFE only when a remote-tracking ref holds its tip, or a merged PR's head is exactly that tip. A local branch or tag no longer counts. The user-typed `cleanup <id>` keeps its looser "no other ref at all" refusal (`--any-ref`), so local-only repos are not forced to `--force`. | `_osrc_branch_merged`, `references/hub.md` |
| spec F4 | Documented exactly when lanes clean up: nothing is deleted when a lane finishes. Under the pause floor the monitor reclaims up to 10 merged, clean lanes per episode. `cleanup --apply` removes SAFE items, and `cleanup <id>` removes one lane. Remote branches are only offered as a `git push --delete` command. I did not widen auto-delete to normal free space: that would delete user worktrees on a schedule, and the brief allowed either option. | `references/hub.md`, `references/jobs-and-safety.md` |
| spec F9 | The disk docs now describe the scaled floor (max(10 GB, 5% of the disk), capped at a quarter of a small volume), the critical floor that nothing passes, the one-use override, the unreadable-df refusal, and the gated session verbs. | `SKILL.md:56`, `references/hub.md`, `references/factory-flow-cli.md`, `references/jobs-and-safety.md` |

`outsourcerer.sh` shrank by 161 bytes: three gate lines were rewritten and two comment lines removed. No code file is over 1,000 lines (`lib/cleanup.sh` 867, `lib/disk_policy.sh` 816).

## Tests (commands run, exit codes)

New suite `tests/test_disk_gate_failsafe.sh` (52 checks), registered in `tests/conformance.sh`. It covers every finding above.

- `nice bash tests/test_disk_gate_failsafe.sh` on my branch: rc 0, 52 passed.
- The same file copied into a checkout of the pinned base commit `1e0064b`: rc 1, 34 failed, 18 passed. Every finding has at least one check that fails before the fix.
- `nice bash tests/test_disk_policy.sh`: rc 0, 94 passed. I moved its calls to the explicit kinds (`fg`, `tmux`). The TERM case now raises free space above the pause floor before checking for a resume (the new rule). The reclaim repo gets a pushed `main` (the SAFE rule).
- `nice bash tests/test_cleanup_manifest.sh`: rc 0, 85 passed. The fixture repo has a pushed `main`. The trunk case now asserts "not SAFE, but `cleanup <id>` accepts it".
- `nice bash tests/test_factory_flow.sh` (sources `lib_factory_flow_l5.sh`): rc 0, 216 passed. "A broken gate fails open" became "fails closed, names the rc", plus a check that a fixed gate releases the plan and that a missing disk gate holds.
- rc 0, no failures: `test_session_effort`, `test_relaunch_bookkeeping`, `test_session_effort_guard`, `test_spend_attack`, `test_supervise`, `test_stall`, `test_lifecycle_fix`, `test_supervise_dedupe`, `test_watcher`.
- `nice bash tests/conformance.sh`: see "Conformance" below.

Two bugs found by the suites while building, both fixed before the commit:
1. `local k n ...` in the tmux registration was unbound under `set -u` when there was no record yet, which would have aborted `session start`.
2. Kind-less gate calls registered the caller as a foreground lane, and the monitor then paused the gate's own scan. Registration now needs an explicit kind and happens only on admission.

## Conformance

`cd plugins/outsourcerer/skills/outsourcerer/scripts && nice bash tests/conformance.sh` on commit
`b78ba3a`: **rc=1**, `RESULT: 262 passed, 3 failed, 14 skipped`. Both disk suites (`test_disk_policy`, `test_disk_gate_failsafe`) and `test_cleanup_manifest` are green inside it.

All three failures predate this lane. Each one assumes it runs as a non-root user, and this container runs as root (uid 0):
- `test_harness_isolation`: "fail-closed failed (rc=0, count=3)". It expects `/nonexistent-root-cannot-create/...` to be uncreatable, and root creates it.
- `test_vocab_hygiene`: "original was damaged on failed write" and "failed rewrite reported success". It uses `chmod 500` on a directory, which root ignores.
- `test_parity_insource_refresh`: "read-only target: rc=0". Same `chmod` assumption.

I ran the same three suites on a checkout of the pinned base `1e0064b`: all three fail there too (rc 1, same FAIL lines). None of my files touch them. The run is still red, so RESULT says `rc=1`.

## What remains unproven

- The detached start (`set -m` double fork, `BASHPID` or `sh -c 'echo $PPID'`) ran only on Linux bash 5. I did not run it on macOS bash 3.2. If the fallback pid read fails, the start is still detached; only the wait for the forking subshell to exit is skipped.
- Git Bash keeps the old background child (no detach), as the brief asked.
- I did not test the `disk resume` vs tick race with real concurrency. Its two parts are tested deterministically: the hold is written before the resume, and a hold present at sweep time pauses nothing.
- The lock-owner scan reads only the leading pid of `*.lock/owner` files up to depth 4 under `$OSRC_HOME`. A lock elsewhere (git's own `index.lock`) is covered only through the "git process under 2 minutes" rule.
- `session effort` is gated even for advisory-only providers (Devin, Gemini), where nothing respawns. Under the launch floor that refuses a bookkeeping change; the one-use code admits it.

## Open questions (decided by the lane)

1. SAFE rule: I followed the brief's wording (a remote or a tip-matched merged PR), which is stricter than the shipped "any other ref". A lane merged only into a local `main` is now ASK until `main` is pushed.
2. `cleanup <id>` (typed by the user for one lane) keeps the "any other ref" test, so repos with no remote are not forced to `--force`.
3. "Finished lanes clean up after themselves": I made the docs precise rather than adding automatic deletion at normal free space.
4. A monitor that dies under the pause floor keeps the records. The heartbeat, the next launch or `disk status` starts a successor. If none of these ever happens, lanes stay paused (`disk resume` brings them back); the brief chose this over resuming into a full disk.
5. A disk-paused lane produces no supervise event: the disk policy already wakes once per episode, and a row every reminder period would be noise.
6. The git deferral is limited to git processes under 2 minutes old, so a long clone or fetch cannot dodge the pause indefinitely.
7. The factory resource gate now fails closed (no per-repo opt-in to the old fail-open). A broken gate holds launches but the plan is not wedged: each pass asks again.

## Needs from other lanes

- **osrc-fx-mc**: Mission Control / hub export should show a disk-paused lane as paused (CC F7, "surface the same state in the hub export"). Use `_osrc_disk_target_paused <id>` (lib/disk_policy.sh): true for a job with a live `disk-paused` record or a tmux lane with `disk-policy/paused/tmux-<id>`. I changed `lib/supervise.sh` only by a 7-line short-circuit at the top of `_sv_observe`; please keep it when merging.
- **osrc-fx-spend** (or the owner of the loader / cloudrun): EH F8 / AR F2 outside the disk gate are not done here: the lib loader at `outsourcerer.sh:303` still skips an unreadable lib, and `lib/cloudrun.sh:684-691` still launches when `_osrc_spend_gate` is missing. The disk gate itself now fails closed without the loader change.
- **Release notes**: replies #83/#84 should say "SAFE only when a remote or a merged PR at the exact tip holds its commits", and "finished lanes clean up" should read "when space runs low, merged lanes are reclaimed first; `cleanup --apply` removes what is SAFE".
