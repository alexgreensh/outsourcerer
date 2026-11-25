# osrc-l2-disk — a disk policy that actually holds

Branch: `cloud/osrc-l2-disk`. Code root: `plugins/outsourcerer/skills/outsourcerer/scripts/`.

## What changed and why

The old gate was one flat 10 GB check at launch time, and once the current ASK list was
acknowledged it returned success at *any* free space. Jobs already running were never
checked, so a build launched above the floor could drain the disk while running, and a
merged lane's worktree stayed behind forever. Three incidents from the brief are now
covered:

1. **Acknowledged ASK / override cannot launch near-empty disk.** `_osrc_disk_gate`
   (lib/cleanup.sh) now computes floors via `lib/disk_policy.sh` and refuses below the
   critical floor unconditionally — before the ASK/SAFE logic, before `OSRC_DISK_OK`,
   and before any ack is read.
2. **Running jobs drain the disk.** A detached monitor
   (`$OSRC_HOME/disk-policy/`) is armed on every launch path via
   `_osrc_disk_monitor_ensure` (self-deduping, respawns after idle exit). Under the
   pause floor it `SIGSTOP`s only supervised jobs recorded in `$OSRC_JOBS` whose
   pid+start-time identity verifies, freezes their supervisors too (so no watchdog
   arm fires), writes a `disk-paused` marker, appends a keepalive to `out.log`, and
   wakes the owner once per episode (`disk.pause`/`disk.resume` wake events,
   throttled by `OSRC_DISK_WAKE_SECS`). At the resume floor (pause floor + hysteresis)
   it `SIGCONT`s everything it paused. Nothing is ever killed; foreign or unverifiable
   processes are never signalled. Each pressure episode writes one report (free/total,
   floors, swap, biggest dirs under `OSRC_HOME`, reclaimable counts) to
   `disk-policy/monitor.log`.
3. **Merged-lane leftovers.** Under pressure the monitor auto-reclaims only manifest
   items that are verdict-SAFE *and* kind `worktree`/`branch` — artifacts of a lane
   proven merged — worktrees before branches, branches re-verified after worktree
   removal, capped by `OSRC_DISK_RECLAIM_MAX` (default 10, 0 disables), each deletion
   logged to `cleanup.log`. Jobs, loops, autodetach logs, tmp dirs, every ASK item,
   and all user data stay manual.

### Files

- `scripts/lib/disk_policy.sh` (new, 595 lines): floor math, disk report, override
  log, pause/resume engine, auto-reclaim, monitor loop/ensure.
- `scripts/lib/cleanup.sh`: `_osrc_disk_gate` rewritten (~70 lines changed, away from
  the preservation logic PR #85 touches). The gate now decides from the **live
  in-memory scan** (issue #86): if `_osrc_cleanup_state_write "$items"` fails it dies
  with "state unknown" — it never reads the old `state.json` and never honors an old
  ack. ASK/SAFE counts and the ack hash are computed from `$items` directly.
- `scripts/tests/test_disk_policy.sh` (new, 303 lines): 50 assertions.
- `scripts/tests/test_cleanup_manifest.sh`: four gate stubs moved from 50 MB to 6 GB
  free (above the ≤4 GB critical floor, below the ≥10 GB launch floor on any volume)
  and fast monitor env (`OSRC_DISK_POLICY_POLL=1`, `OSRC_DISK_MONITOR_IDLE_TICKS=1`).
- `scripts/tests/conformance.sh`: `test_disk_policy` registered in `_ALL_SUITES`.
- `references/jobs-and-safety.md`: new "Disk pressure policy" section documenting
  floors, pause/resume semantics, and every `OSRC_DISK_*` override.

### Floor defaults (any machine)

All derived from the volume holding `$OSRC_HOME` via `df -kP`:

- launch = max(10 GB, 5% of volume) — no new lane launches under it
- pause = max(4 GB, 2% of volume) — running jobs get SIGSTOP under it
- critical = ~0.5% clamped to 1–4 GB — nothing launches under it, period
- resume = pause floor + hysteresis into the pause→launch gap (no flapping)

Explicit overrides: `OSRC_DISK_MIN_GB` / `OSRC_DISK_PAUSE_GB` /
`OSRC_DISK_CRITICAL_GB`. `OSRC_DISK_MIN_GB=0` disables launch+critical blocking while
keeping pause behavior (documented "never block" escape). `OSRC_DISK_POLICY_OFF=1`
restores the legacy flat 10 GB gate and disables pause/reclaim. `OSRC_DISK_OK=1` is a
one-command launch override in the band above critical — logged to
`disk-policy/override.log`, never persisted, never inherited.

## Tests run (exact commands, exit codes)

Per the LOCAL RUN OVERRIDES, only own/changed tests were run, one at a time, each
under `nice -n 19`. The conformance suite, full suites, builds, installs, Docker and
benchmarks were **not run** — the orchestrator runs those at integration.

| Command | Result |
|---|---|
| `nice -n 19 bash tests/test_disk_policy.sh` | `RESULTS: 50 passed, 0 failed`, exit 0 |
| `nice -n 19 bash tests/test_cleanup_manifest.sh` | `RESULTS: 66 pass 0 fail`, exit 0 |
| `bash -n lib/disk_policy.sh lib/cleanup.sh tests/test_disk_policy.sh tests/test_cleanup_manifest.sh tests/conformance.sh` | all OK, exit 0 |

`test_disk_policy.sh` reproduces all three incidents plus: floor defaults/explicit
overrides/policy-off/zero-floor/invalid values; critical floor vs ack and vs
`OSRC_DISK_OK`; band ack/override behavior + override log; the issue-#86 regression
(stale `state.json` + matching `ask-ack` seeded, `_osrc_cleanup_state_write` stubbed
to fail → gate refuses "state unknown", stale data unread); pause/resume with
hysteresis, foreign + unverifiable-pid jobs untouched; auto-reclaim scope (merged
worktree+branch only, unmerged + SAFE evidence preserved, `cleanup.log` entries);
monitor ensure/dedupe/idle-exit/respawn; and disk report contents (swap via
`sysctl`/`vm.swapusage` or `/proc/meminfo`, top dirs, SAFE/ASK counts).

## What remains unproven

- Windows Git Bash paths (swap detection, `stat`/`df` edge cases) are written
  portably but only exercised on macOS here.
- The monitor's SIGSTOP/SIGCONT against real agent CLIs is verified against `sleep`
  fixtures with recorded pid/start-time identity, not a live Claude/Codex pane.
- Swap reporting is best-effort: macOS `sysctl vm.swapusage`, Linux
  `/proc/meminfo`; anything else prints "unavailable" rather than guessing.
- Conformance suite not run locally (see overrides); `test_disk_policy` is
  registered in `_ALL_SUITES` for the integration run.

## Needs from other lanes

- `scripts/outsourcerer.sh` call sites: the gate is already invoked from `_bg_launch`,
  `route_delegate` and session start, so no change needed there — but if another lane
  adds a new launch path, it must call `_osrc_disk_gate` (and thereby arms the
  monitor). No edits were made to `outsourcerer.sh`.
- If PR #85 changes `_osrc_cleanup_state_write`'s contract or the manifest item
  schema (`verdict`/`kind`/`path` fields the gate and reclaim consume), the gate's
  live-scan jq and the reclaim filter need a matching update.

## Round 2 (branch `cloud/osrc-l2-r2`, base `1849ad0`)

The independent review of round 1 found P1/P2 defects in automatic cleanup, pause/resume and the
launch gate. Round 1's `disk_policy.sh` was rewritten around four ideas: a pause **record is written
and read back before any SIGSTOP**; the monitor **owns a lock for its whole life**; reclaim is
**per lane, pinned to a proven commit**; the override is a **one-use code**.

### Fixes by finding

| Finding | Fix |
|---|---|
| P1 protected files deleted with a merged worktree | Auto-removal needs `git status --porcelain --ignored --untracked-files=all` empty AND no `.env*`, `.venv`, `venv`, `node_modules`, `*backup*`, `*.bak`, `.git`, `store`, `state` inside. Otherwise the worktree is kept and shown in `cleanup`. |
| P1 wrong commit verified | The live worktree must be on the receipt branch (`symbolic-ref`) and its HEAD must equal the proven tip; detached or repurposed worktrees are kept with the whole lane. |
| P1 branch moves before deletion | `git update-ref -d refs/heads/<b> <proven-sha>` (fails if the tip moved), after the checked-out guard. |
| P1 repo-wide prune | Removed from auto-reclaim. (`_osrc_cleanup_apply`, the manual path, still prunes: not mine, see Needs.) |
| P1 pgid field splitting | Records use `|` fields read with `IFS='|'`; group signal only when recorded pgid == pid == live pgid and not our group; otherwise pid + its descendants by pid. |
| P1 marker written after SIGSTOP | `_osrc_disk_rec_write` writes tmp, renames, reads back; on failure nothing is stopped and the owner wake says how many lanes keep running. |
| P1 monitor exits with jobs frozen | One EXIT handler (TERM/INT route through it) resumes all records and releases the lock; no exit on a failed liveness write (that file is gone). `_osrc_disk_heartbeat` restarts a monitor when records exist and no owner lives; hooked in `_osrc_cleanup_tick` (one line). |
| P1 cancel while paused | The sweep resumes every surviving verified process of a terminal or delegate-less record before retiring it; a failed SIGCONT keeps the record. |
| P1 paused time vs watchdog deadlines | **Partly.** Each job accumulates `disk-paused-secs`; `_osrc_disk_paused_secs <jd>` returns total incl. an ongoing pause. Using it in `watchdog.sh` is another lane's file: see Needs. |
| P1 report/reclaim before pause | Tick order under pressure: pause → wakes → (once per episode) report scan → reclaim → remeasure → maybe resume. |
| P1 monitor election | `disk-policy/monitor.lock/owner` = pid + start identity, verified every tick (a demoted monitor exits). Launch posts a demand token before checking the owner; an idle monitor releases the lock before its last demand check, so a racing launch never ends unwatched. |
| P1 fd 5 held open | Monitor child closes fds 3–9. |
| P1 foreground / tmux lanes | The gate registers its caller (via `FUNCNAME`): `route_delegate` outside a bg job registers the launcher process; `session start` registers the tmux session, bound on first sight only if the pane started after registration. Their descendants (never the monitor) are paused, count as fleet liveness, and a paused TUI is restored: SIGCONT, `fg` into the pane shell if job control took it, saved `stty -g` reapplied, SIGWINCH. |
| P1 Windows | **Partly.** The gate now runs at the top of `session()` for `start`, before the `_winpty_session` branch. Pausing on Git Bash is not implemented: MSYS `ps` gives no start identity, so no Windows process is ever signalled; the owner wake reports them as "could not be verified, keep running". |
| P2 pipefail | Direct `_osrc_disk_any_paused` glob check; no `| grep -q`. |
| P2 episode wakes | Each pressure episode gets an id; events are `disk.<episode>.<paused|critical|resumed>`, once each. |
| P1 state write returns 0 | `_osrc_cleanup_state_write` returns 1 after cleaning up its temp file (one line). |
| P1 slow ack check | Free space re-read after the scan; below critical refuses. |
| P1 inherited override | `OSRC_DISK_OK` must hold the one-use code a refusal printed (15 min), binds to the first process ($$ + start identity) — subshells of that command share it — is unset before any delegate runs, and needs a successful append to `override.log`. `OSRC_DISK_OK=1` no longer works. |
| P2 first launcher's settings | Settings file `$OSRC_HOME/disk-policy/settings`; the monitor scrubs `OSRC_DISK_*` env and reads only the file. Env applies to one command's gate. |
| P2 small volumes | Default launch floor capped at 25% of the volume (8 GiB → 2 GiB). |
| P2 scratch uncovered | Manifest `tmp` items of a proven-merged lane (same session) are removed if SAFE and free of protected content. |
| P2 report has no names | Report lists up to 10 SAFE items as `auto|manual  kind  path`. |
| P3 lifecycle test | Tests read the verified lock-owner pid and watch that pid exit. |
| Owner: one-command resume | `outsourcerer disk resume` (new dispatch line) resumes everything and holds new pauses until recovery or the critical floor; `disk status` prints the report. |

`outsourcerer.sh` shrank by one line (gate moved, `disk` dispatch added). Docs:
`references/jobs-and-safety.md` "Disk pressure policy" rewritten.

### Tests (Linux, bash 5.2, tmux and lsof installed, run as root)

| Command | Result |
|---|---|
| `nice -n 19 bash tests/test_disk_policy.sh` | `RESULTS: 80 passed, 0 failed`, exit 0 (~75 s) |
| same suite against base `1849ad0` code | 24 FAIL in floors/gate/pause/fg/tmux sections, then hangs in the monitor section on the fd-5 case (caller blocked until killed by `timeout 400`, exit 124); reclaim section not reached there |
| `nice -n 19 bash tests/test_cleanup_manifest.sh` | `RESULTS: 66 pass 0 fail`, exit 0 |
| `nice -n 19 bash tests/test_session_capabilities.sh` | `RESULT: 12 passed, 0 failed` (failed in the first conformance run: a monitor probed tmux for a still-launching session; fixed with pending registrations + test) |
| `bash tests/conformance.sh` (once, before that fix; overlapped with other test runs) | exit 1, `239 passed, 9 failed, 1 skipped` |

Conformance failures, each re-run alone on this branch and on the unmodified base:
`test_session_capabilities` (mine, fixed, now green); `test_cleanup_manifest`, `test_release_0175`
pass alone on both (the conformance failures came from concurrent runs); `test_vocab_hygiene`,
`test_harness_isolation`, `test_supervise_pgroup_kill`, `test_parity_insource_refresh`,
`test_conformance_suite_timeout`, `test_sealed_fixes` (exit 127) fail identically on base — this
container runs as root (permission-based fixtures do not fail) and lacks some tools. Conformance
was not re-run after the session fix.

### Unproven

- macOS bash 3.2: only syntax-level care (no 4.x features; `BASHPID` fallback via `sh -c 'echo $PPID'`); not executed on a Mac here.
- Windows Git Bash: no pause at all (fail-safe), not exercised.
- TUI restore tested with `bash -i` + `stty raw; sleep`, not a real agent TUI; zsh/fish job control untested.
- Watchdog deadlines still count paused time until the watchdog lane wires the helper in.
- Auto-detached (`OSRC_REQUIRE_INTERACTIVE`) tmux runs are not registered (their session is created outside `session start`).

## Needs from other lanes

- **watchdog lane (`lib/watchdog.sh`)**: subtract `$(_osrc_disk_paused_secs "$jd")` from the
  wall-clock ages in the no-init (`now - ni0`), hard-timeout (`now - t0`) and stall/no-write checks,
  and test a real `_supervise` across a pause longer than its init timeout.
- **PR #85 owner (`lib/cleanup.sh`)**: `_osrc_cleanup_apply` still runs repo-wide `git worktree prune`
  and `branch -D` by name; the manual path deserves the same lane-pinned deletion.
- **auto-detach path (`outsourcerer.sh` ~10784)**: call `_osrc_disk_register_caller session` with
  `SESSION_NAME="$_ad_sess"` before `tmux new-session` so those panes are paused too.

## Round 3 (branch `cloud/osrc-l2-r3`, base `789c6c1`)

Fixes for the round 2 review: three P1s, P2 4, 5, 7, 8. For P2 6 and 9 the reclaim code was cut
back, not extended. Paths are under `scripts/`.

### Fixes by finding

| Finding | Fix |
|---|---|
| P1-1 env bypasses every floor | `_osrc_disk_conf` reads only `disk-policy/settings`; no environment variable moves a floor (`OSRC_DISK_MIN_GB`, `_CRITICAL_GB`, `_POLICY_OFF`, `_RECLAIM_MAX` from env are ignored). The critical floor stays when launch blocking is off (`MIN_GB=0` or `POLICY_OFF=1`). The only per-command override is still the one-use `OSRC_DISK_OK` code, never below critical, logged on every use. |
| P1-2 override dead for `bg`/`fanout` | (a) The bg route preflight child (`OSRC_PREFLIGHT=1`) no longer runs the gate: it consumed and bound the code in a throwaway process. `_bg_launch` gates right after it. (b) When a code admits a `_bg_launch`, the taker writes `disk-policy/admit.<random>` (15 min) and exports `_OSRC_DISK_ADMIT`. The detached job's own gate consumes it with `rm` (one taker), logs `job-admit` and unsets it. The gate scrubs both variables above the floor too, so no delegate inherits them. |
| P1-3 watchdog kills a paused job on resume | `lib/watchdog.sh` (4 lines): each poll reads `_osrc_disk_paused_secs` and shifts `t0`, `qt0`, `ni0`, `ni_start` and `last_change` by any growth, so the no-init, stall and hard-timeout clocks count only active time. Resume banks the pause into `disk-paused-secs` and drops the record's `since` line before any SIGCONT, so a poll never counts a pause twice or misses it. |
| P2-4 second `session start` unregisters a live session | `session)` registration returns early when the existing record is bound to a pane that is still the same process. (The suggested `tmux has-session` broke `test_session_capabilities`, which forbids any tmux call before the capability probe; this check makes no tmux call.) |
| Found while fixing P1-2: monitor held a caller's pipe | With the preflight no longer spawning the monitor, the first monitor came from inside `id=$(_bg_launch ...)` and inherited bash's saved copies of the capture pipe at fd 10/11, so `plan run` never saw EOF (`test_factory_e2e` hung). The monitor child now closes every fd 3-31, not just 3-9. The fd test also holds fd 12. |
| P2-5 `fg` typed into a live agent | Shell-name list dropped. `fg` is typed only when `ps -o tpgid=` of the pane process equals its own pgid and no paused pid shares that group: a job-control prompt. A lane still in the foreground gets `stty` and SIGWINCH only. Anything else is never typed into, stays parked, and raises one `disk-parked-<session>` event. |
| P2-6 scratch reclaim dead | Deleted: the scratch loop, `tmp` in the report, the doc sentence, the test cases. |
| P2-7 group-led jobs skip descendants | The descendant walk always runs. |
| P2-8 stale-lock takeover race | A taker never moves or removes the lock directory. It claims a stale owner by renaming `owner`; a loser of that rename returns. Of two late claimants, the last writer owns the lock and the other exits at its next ownership check. |
| P2-9 reclaim never fires | `_osrc_disk_protected_inside` deleted. An empty `git status --porcelain --ignored --untracked-files=all` at the proven commit already shows every file is tracked and preserved; ignored `.env`/`node_modules` still keep the worktree. |
| P3 stale hold | `disk resume` writes `hold` only when it resumed something. |
| P3 stranded group | Resume SIGCONTs the group of a dead group leader. |
| P3 registration litter | `_osrc_disk_register_caller` returns under `POLICY_OFF=1`. |
| P3 weak tests | The report assertion needs both lines; paused seconds must be at least 1, and banked seconds too. `/dev/full` still skips on macOS. |
| P3 lane markers | `osrc-l2-r2.READY`/`.RESULT` deleted. |
| P3 docs ahead of code | `references/jobs-and-safety.md` rewritten to match (settings-only floors, job admit, watchdog shift, pane rules, reclaim scope). |
| P3 inert trap | `INT` dropped from the monitor trap. |

Also trimmed: the tick no longer re-measures and resumes right after a reclaim (the next tick does);
small helpers compacted. `test_lifecycle_fix.sh` and `test_cleanup_manifest.sh` set floors through the
settings file instead of the env bypass they relied on. `outsourcerer.sh` shrank by 2 comment lines.

**Line counts vs round 2** (`git diff --numstat 789c6c1`): code (`lib/` + `outsourcerer.sh`)
+123 / -138, net **-15**. Docs +1. Tests +67 (new regressions). Lane markers -6 / +6. Report: this section.
So code went down; the whole diff did not, because of the required regression tests and this report.

### Tests (Linux, bash 5.2, tmux, root)

| Command | Result |
|---|---|
| `nice -n 19 bash tests/test_disk_policy.sh` | `RESULTS: 89 passed, 0 failed`, exit 0 |
| same suite file run against the base `789c6c1` code (temporary worktree) | `RESULTS: 75 passed, 14 failed`. Failing: env floors (3 floor cases, 2 gate cases), real `bg` override (2), own-group descendant, real `_supervise` killed on resume (`wedged no-init ... after 15s`), repeat session start, `fg` typed into a foreground lane, reclaim on a repo tracking `.env.example`/`state/` (3). The P2-8 lock case passes on base too (the race is not deterministic). |
| `nice -n 19 bash tests/test_cleanup_manifest.sh` | `RESULTS: 66 pass 0 fail`, exit 0 |
| `nice -n 19 bash tests/test_lifecycle_fix.sh` | `RESULT: 16 passed, 0 failed`, exit 0 |
| `nice -n 19 bash tests/test_noinit_cap.sh` | `passed=6 failed=0`, exit 0 |
| `nice -n 19 bash tests/test_supervise.sh` | `RESULT: 99 passed, 0 failed`, exit 0 |
| `nice -n 19 bash tests/test_nowrite_watchdog.sh` | `22 passed, 0 failed`, exit 0 |
| `nice -n 19 bash tests/test_session_capabilities.sh` | `RESULT: 12 passed, 0 failed`, exit 0 |
| `nice -n 19 bash tests/test_factory_e2e.sh` | `10 passed, 0 failed`, exit 0 (hung before the fd fix; base passes) |
| `bash tests/test_no_pipe_grep_q.sh` | pass (it caught a `| grep -q` I had added to the test; fixed) |
| `nice -n 19 bash tests/conformance.sh` (first run, before the last three fixes) | exit 1, `239 passed, 9 failed, 1 skipped`: `test_session_capabilities`, `test_no_pipe_grep_q`, `test_factory_e2e` were mine and are fixed above |
| `nice -n 19 bash tests/conformance.sh` (final code, HEAD before this report) | exit 1, `241 passed, 7 failed, 1 skipped` |

The 7 failures in the final conformance run: `test_harness_isolation`, `test_vocab_hygiene`,
`test_supervise_pgroup_kill`, `test_parity_insource_refresh`, `test_conformance_suite_timeout` and
`test_sealed_fixes` are the six round 2 recorded as failing identically on base in this container
(it runs as root, so permission fixtures do not fail, and some tools are missing). `test_vocab_hygiene`'s two
failures are its root-permission write cases. `test_release_0175` passes alone
(`RESULT: 83 passed, 0 failed`, exit 0); it failed only under the conformance run's load, as round 2 also saw.

New regression tests, one per P1: env zero floors cannot pass the gate or move a floor (P1-1); a
real `outsourcerer bg` with a fake `codex` on PATH is refused, then run with the printed code, and the
detached job must finish `done` with a `job-admit` log line and no token left (P1-2); a real
`_supervise` (no-init 6 s, hard 12 s) is paused for 14 s, resumed, and must still be `running` 3 s
later, then still end `wedged`/`timeout` on active time (P1-3).

### Unproven

- macOS bash 3.2 and Git Bash not executed here. The fd close loop uses `eval "exec $i>&-"`. New code uses `ps -o tpgid=` (BSD and procps both
  have it) and `od`; no bash 4 features. The P2-5 test's child wait uses GNU `ps --ppid` with a
  `pgrep -P` fallback.
- Pane rules checked with a `bash -i` job-control pane and a non-exec `bash -c` wrapper pane, not real
  agent TUIs or zsh/fish.
- The P2-8 race is reasoned, not reproduced: the test only shows a late claimant leaves one owner.
- `fanout` admission rides the same `_bg_launch` path as `bg` but has no test of its own.

### Needs from other lanes

- Watchdog lane: `lib/watchdog.sh` now has a 4-line clock shift in the `_supervise` poll loop
  (after `now=$(date +%s)`). Keep it if you rewrite that loop.
- The round 2 asks stand: `_osrc_cleanup_apply` repo-wide prune (PR #85 owner) and registering
  auto-detached tmux sessions (`outsourcerer.sh` auto-detach path).

## Round 4 (branch `cloud/osrc-l2-r4`, base `75eb289`)

Closing round: the three review P2s and every P3, each with the smallest change. No new design.
Lines (code + tests vs base): `lib/disk_policy.sh` +30/-36, `outsourcerer.sh` +10/-16 (comment trims
in `_fg_guard` pay for the one-line fix), `tests/test_disk_policy.sh` +29/-18. Net -1.

### P2 fixes

1. **Failed record rewrite on resume** (`_osrc_disk_resume_rec`). The `since`-stripping rewrite is now
   `grep > tmp && mv tmp rec || rm tmp`, so a failed write (disk full, TERM) keeps the old record and
   the loop still SIGCONTs everything in it. Test: pause a real job, resume with `grep` failing; on the
   base the delegate and supervisor stay `T` (`FAIL: frozen with no record: TN TN`).
2. **Paused foreground lane killed on resume** (`_fg_guard`, `outsourcerer.sh`). The guard keeps its
   previous poll time; a gap over 10 s (the guard itself was frozen with the lane) shifts both `t0`
   and the teardown clock `mk`. Test: a real `_fg_guard` (hard cap 10 s) under a registered
   foreground launcher, paused by the real monitor tick for 14 s, must return 0; base returns 124.
3. **Two monitors after a stale-lock takeover** (`_osrc_disk_lock_take`). The only claim is now an
   exclusive create of `owner` (`set -C`), so exactly one claimant wins. A stale owner is first renamed
   aside; a rename that grabbed a live owner (checked with `_osrc_disk_lock_alive <file>`) puts it back
   and loses. Record temp files are per process (`<record>.<monitor pid>`). Test: two claimants that
   both judged an owner-less lock stale; base prints `wonwon`, now exactly one wins, no debris.

### P3 fixes

- Fork per job dir: `read -r` replaces `$(cat status)`/`$(cat pid)` in `_osrc_disk_pause_job` and
  `_osrc_disk_fleet_live`.
- Environment knobs only tighten: `OSRC_DISK_POLICY_POLL` is clamped to at most 30 s (default), and
  `OSRC_DISK_MONITOR_IDLE_TICKS=0` falls back to 40 (0 made a live monitor exit after one tick).
- Repeat `session start` before first bind keeps a pending record whose launcher is dead.
- Expired `admit.<hex>` tokens are swept every tick.
- `disk-parked-<session>` now has a tmux test: a paused lane with another program in the pane's
  foreground at resume gets the event and nothing typed.
- The #86 state-write test no longer needs `/dev/full` (a directory at the temp path makes the write
  fail), so it runs on macOS.
- Reclaim treats a failing `git status` as dirty (worktree kept).
- Pausing off (pause floor 0, e.g. `OSRC_DISK_POLICY_OFF=1` mid-episode) resumes every paused lane
  on the next tick.
- `osrc-l2-r3.READY/RESULT` removed; `osrc-l2-r4.*` written and RESULT names this round's base pin.
- `_osrc_disk_heartbeat` collapsed to one line.

### Tests run

- `nice bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/test_disk_policy.sh` on this
  branch: `RESULTS: 92 passed, 0 failed`, exit 0.
- The same new test file against the base tree (worktree at `75eb289`): `RESULTS: 89 passed,
  3 failed`. The three failures are exactly the three new P2 tests. (That run exited 143: on the base
  the losing lock claimant writes the test shell's pid as owner, and the test cleanup kills it.)
- `nice bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh`: `RESULT: 242 passed,
  6 failed, 1 skipped`, exit 1. The 6 are exactly round 3's known container/base failures
  (`test_harness_isolation`, `test_vocab_hygiene`, `test_supervise_pgroup_kill`,
  `test_parity_insource_refresh`, `test_conformance_suite_timeout`, `test_sealed_fixes`); none touch
  the disk policy. `test_disk_policy` is green inside it.

### Unproven

- macOS bash 3.2 and Git Bash not executed. New code uses `set -C` (POSIX noclobber, `O_EXCL`),
  `read -r` from files and arithmetic only. Exclusive create on Git Bash NTFS is assumed atomic.
- The restore after renaming a live owner can race a third claimant that judged the lock stale
  before both; the lock directory's fresh mtime makes any newer claimant back off, but this residue
  is reasoned, not reproduced.
- The repeat-start and admit-sweep P3s have no dedicated test (line budget); both are one-line
  conditions exercised by existing paths.

### Needs from other lanes

- None new. Round 3's asks stand.
