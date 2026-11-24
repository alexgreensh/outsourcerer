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
