# osrc-int-fix-c — release candidate green on Linux (non-root)

started

Base `cloud/osrc-int` at `6d98b31` (confirmed with `git log --oneline -1`). Branch `cloud/osrc-int-fix-c`.
Code head tested by the final conformance run: `bf7c032`.

Host: Linux VM, 4 CPUs, Ubuntu userland, procps-ng 4.0.4, tmux present, no bwrap. All tests ran as the
non-root user `tester` (uid 30033), created with the defaults (login shell `/bin/sh` → dash 0.5.12).
Two host facts explain four rows:
- **tmux runs a pane command through `$SHELL -c`, and dash forks instead of exec'ing it.** So in a test
  pane created with a command, `pane_pid` is dash, and the shell the test meant sits one level lower.
  The product's own panes are created with no command (`outsourcerer.sh` `tmux new-session -d -s … -c`),
  so there `pane_pid` is the login shell itself.
- **PID 1 (the VM agent `process_api`) reaps orphaned zombies seconds late.** Seen directly:
  `ps -eo stat,pid,ppid` showed `ZN … 1 … sleep` rows that were gone a few seconds later.

## Rows

| Suite | Cause | Kind | Fix | Fails on base? |
|---|---|---|---|---|
| test_factory_flow `L5: disk override ignored` | Since 61faa18, disk floors come only from `$OSRC_HOME/disk-policy/settings`; an export never moves them (a deliberate safety rule). cab5c23 made the factory gate reuse the launch disk gate, but its pause hint still said `Override: OSRC_DISK_MIN_GB=0` (an env var that does nothing), and the test asserted the env override. | Product bug (wrong advice) + wrong test | `lib/factory-parallel.sh`: the hint now names the settings file. Test: an `OSRC_DISK_MIN_GB=0` export must **not** open the gate; `OSRC_DISK_MIN_GB=0` in the settings file must; the disk-ack check greps the new hint. The env-only floor rule is **not** weakened. | Yes (`213 passed, 1 failed`, base run) |
| test_wrapper_liveness (#47 pair) | Test pane `"bash --norc --noprofile"` ran as `dash -c …`; the wrapper was a grandchild of `pane_pid`, and `_session_engine_pid` looks only at direct children (correct for product panes). Proven: `ps --ppid <pane_pid>` showed `bash --norc --noprofile`, then `bash …/outsourcerer.sh` below it. | Wrong test (host-shell dependent) | Pane command is `exec bash --norc --noprofile` (same shape as a product pane on any login shell). | Yes (`20 passed, 2 failed`) |
| test_disk_policy (TUI pause/resume) | Same pane shape: the pause walks the tree under `pane_pid`, so with dash at the root it also stopped the interactive bash, and nothing was left to take job control. | Wrong test | `exec env PS1=… bash -i` for the two job-control panes. The waits were already bounded wait-untils (25 s). | Yes (reported row; red alone on base) |
| test_supervise_pgroup_kill `SIGKILL did not take` | `_proc_gone` correctly counts a zombie as gone, but the identity re-check then read the zombie's start/pgid and called it a live survivor. On this host the killed, re-parented grandchild stays a zombie for seconds. | Wrong test | A zombie (`stat Z*`) counts as reaped; a non-zombie with the same identity is still a REGRESSION. | Yes (`13 passed, 1 failed`) |
| test_conformance_suite_timeout `timer survived … TERM path` | `sleep 1; kill -0` — the killed timer was a zombie (proven with an instrumented copy, 6/6 runs: `stat=ZN ppid=1`). | Wrong test (timing + zombie) | A bounded wait-until (≤2 s) that counts gone-or-zombie as dead. The 60 s bound it guards against is unchanged. | Yes (6/6 red with the probe) |
| test_hub_mc4 `offline: {"github":"ok"…}` | A failed GitHub fetch keeps the good cache (`ok:true`) and marks it `stale:true`; `_osrc_hub_history_build` read only `.ok`, so an offline machine showed GitHub as reachable and never added local tags. | Product bug | `lib/hub-history.sh`: reachable only when `.ok == true and (.stale | not)`. Kept history is still shown. | Yes (`45 passed, 2 failed`) |
| test_hub_mc4 `plans tile still shows one plan` | A source grep for `plans: lims`; 31728cc refactored it to `planReadings()` / `plans: pr.lims`, and the behaviour is rendered and asserted in `test_hub_home.sh` (`ids=codex,claude`). | Stale test | The grep follows the current wiring. | Yes |
| test_release_0175 (3 hub lines) | **Not reproduced.** 83/0 alone; 83/0 ×2 under 8 busy loops; 83/0 ×2 beside 5 heavy suites in parallel; green inside the diagnostic conformance run. The three FAIL lines are consistent with one failed `mc` call cascading (pid4 empty). The one timing dependency found is the `kill; sleep 0.5` before a strict-port re-bind. Ruled out: the `mc` respawn bound (respawn takes 0.7 s idle vs a 15 s bound), the `/api/answers` lock, and a parallel suite touching the engine file (none do). | Timing in test (partly proven) | The sleep is replaced with the suite's bounded `wait_dead`. | Not shown red here (see unproven) |
| test_sealed_fixes `MATRIX_DENIED` | No OS guard on this host: `ls /usr/bin/bwrap` → `No such file or directory`; `command -v bwrap` → (nothing); `dpkg -l bubblewrap` → `no packages found matching bubblewrap`; not macOS. | Missing precondition | Without a guard the test now **asserts the matrix refuses** (`MATRIX_DENIED: OS guard unavailable`), prints `SKIP: no OS guard here (/usr/bin/bwrap is missing)…`, and skips. `conformance.sh` now counts each `SKIP:` line of a green suite as a gate skip (they were folded into the suite's pass). New check in test_conformance_suite_timeout. | Yes (`FAILED (errors=1)`; the gate check: `33 passed, 1 failed` against base conformance.sh) |

## Three-times results (alone, `nice`, as `tester`)

```
test_factory_flow             214/0  214/0  214/0
test_disk_policy               94/0   94/0   94/0
test_conformance_suite_timeout 34/0   34/0   34/0
test_wrapper_liveness          22/0   22/0   22/0
test_supervise_pgroup_kill     14/0   14/0   14/0
test_hub_mc4                   47/0   47/0   47/0
test_release_0175              83/0   83/0   83/0   (again 83/0 ×3 after the wait_dead change)
test_sealed_fixes              OK (skipped=2) ×3, with the SKIP line
test_hub_speed (neighbour of the hub fix) 27/0 once
```

## Full conformance

`su tester -c 'bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh'` on `bf7c032`:
**rc=0**, `RESULT: 259 passed, 0 failed, 16 skipped`.

An earlier diagnostic run ended with rc=2 (`syntax error near unexpected token 'fi'` at line 464). I caused
that by editing `conformance.sh` while it ran (bash reads the script as it goes). `bash -n` on the file
passes. That run is not counted.

## Unproven

- **test_release_0175:** the race was never reproduced, so I cannot show the fix removes the reported
  failure. If it comes back, run with `OSRC_CONFORMANCE_VERBOSE=1` to capture `pid3/pid4/out`. My leading
  untested theory: `HUBPORT` is drawn from the ephemeral range (bind to port 0), so a busy machine's
  outgoing connection can take it between the kill and the strict re-bind.
- Now that inner SKIPs reach the gate, one looks suspicious and belongs to another lane:
  `test_perm_profiles: symlink exec did not reach tmux for a non-perm reason (rc=1)`.
- The suites were not run on macOS or Git Bash. The test changes use only POSIX `ps -o stat=` and
  bash 3.2 syntax.

## Open questions (decided by the lane)

- `OSRC_DISK_MIN_GB` as an env var: I kept the settings-only rule (the safer default) and fixed the
  advice and the test, rather than letting an export lift the floor.
- RESULT line 1 carries the pinned commit as the contract asks; my head is named below it.

## Needs from other lanes

- test_perm_profiles owner: look at the skip above.
- `test_hub_mc4` / `test_release_0175` fixtures use a real-looking owner/repo name
  (`alexgreensh/total-recall-core`); the rules ask for invented examples. I did not change it (not my row).
