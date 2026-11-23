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
