# osrc-fx-disk-r3: the intermittent "protected files deleted!" in merged-lane reclaim

Base: `cloud/osrc-fx-disk-r2` at the pinned commit `5769ef9` (round 2; I kept all of it). Branch:
`cloud/osrc-fx-disk-r3`.

## The mechanism

The test deleted nothing. **The operating system's temp-directory cleaner did.** The test set the
timestamps of its fixture files to 2020, inside `$TMPDIR`.

`test_disk_policy.sh` makes the lane worktrees look old enough to reclaim (cleanup's "older than 1h"
rule) with `find … -exec touch -t 202001010000`. That sets the atime and mtime of every file under
`$R/.outsourcerer/worktrees` (and `$RH/jobs`) to 1 January 2020. These are ordinary files under
`$TMPDIR`. On macOS that is `/var/folders/…/T`, which `dirhelper` cleans of files not accessed for 3
days. It runs at launch and then daily (03:35, or when the Mac wakes if that time was missed). Linux
hosts run tmpreaper and systemd-tmpfiles over `/tmp` in the same way. Once a fixture file's
timestamps say 2020, the cleaner may delete it at any moment.

If the cleaner runs in the ~1 s between the test's aging step (`age …`, the line before the report)
and the checks, it explains each line of the Mac failure:

| Failing line | Why |
|---|---|
| `protected files deleted!` | `deps/node_modules/pkg/.env` was a 2020 file, so the cleaner deleted it. Outsourcerer did not. |
| `merged worktree kept` | The cleaner also deleted `gone`'s tracked files and its `.git` file. Its status was no longer clean, so the verdict was ASK and reclaim kept it, which is correct. |
| `merged branch kept` | A lane with an ASK worktree keeps its branch too (`_osrc_disk_reclaim_lane`). |
| `cleanup.log: No such file` | Nothing was deleted, so nothing was logged. |
| `detached kept`, `unmerged kept`, `usb admin record` all PASS | These checks test that a directory exists or that a git object or admin record exists. Directories, `.git/objects` and `.git/worktrees` were not aged, so the cleaner left them. |

Only this block ages files that the checks read back. That is why only incident 3 ever failed, why
the failure was rare and depended on when the test ran, and why round 1 passed 6 of 6: a cleaner run
did not happen to fall inside one of those runs. The failure is not linked to the round-2 changes.

### Reproduction on Linux

I wrote `scratchpad/sweeper.sh`, a stand-in for dirhelper:
`find <scratch tmp root> -type f -atime +3 -delete` every 0.5 s.

Every loop used the same conditions:
- a symlinked TMPDIR (`/tmp/r3l -> /tmp/r3real`);
- a fake `df` first on PATH, reporting 5 GB free on a 500 GB volume, which is below every default floor;
- 4 busy-loop CPU hogs on 4 cores;
- 4 runs in parallel;
- `nice`.

| Run | Code | Result |
|---|---|---|
| Brief's recipe, no cleaner, 40 runs | base `5769ef9` | 0 incident-3 failures. 1 run timed out in the foreground-lane block (see below). |
| Same, plus the simulated cleaner, 8 runs | base `5769ef9` | 7 of 7 completed runs fail with the Mac's exact four lines. Two more lines also fail: the report check (gone's files were already deleted before the report) and the empty-lock-owner check (that test also aged a file with `touch -t 2020`). The 8th run timed out in the foreground-lane block. |
| Same, plus the cleaner, 8 runs | this branch (final) | 8 of 8 green (98/98). |
| Brief's recipe, no cleaner, 40 runs | this branch (final) | **40 of 40 green (98/98), no hang.** |

So the reproduction rate goes from 7 of 7 completed runs (base, with the cleaner) to 0 of 8 (fixed). An
earlier version of this branch, before the pause-record fix below, passed incident 3 in all 37 of its
40 runs that completed and hung in 3 (so 8 hangs in 48 base and early runs, 0 in 48 final runs).
Without a cleaner, the base did not fail incident 3 in 40 runs. That matches the Mac's rate of 1 in
11, which depended on when the test ran.

### Suspects ruled out (with evidence)

- **(a) A background monitor reclaiming concurrently.** I used a probe copy of the test that lists
  every live `monitor.lock` owner before incident 3 and dumps `$RH/disk-policy` after it. No monitor
  ever held `$RH`'s lock. The only live "owners" were the two `sleep 300` processes that the lock-race
  tests plant as fake owners. A PATH shim around `git` logged every `worktree remove`,
  `update-ref -d` and `branch -D`, with the caller's command line, across all 48 base runs. Every
  removal came from the test's own `_osrc_disk_reclaim` call, and none was ever for `deps`. A monitor
  forked from the test's `osrc` shell also inherits the overridden `_osrc_free_kb`, which reads
  `$FREEF`. The real disk reaches it only through the volume size, which sets the default floors. The
  test is now hermetic anyway (below).
- **(b) `git worktree remove` deleting ignored files.** This is real. Without `--force`, git refuses
  only untracked or modified files and deletes ignored ones. I verified this with git 2.43 and a
  `node_modules/p/.env`. Reclaim's check (`status --ignored --untracked-files=all`) did hold.
  However, typed `cleanup --apply` relied on the verdict, which sees only the collapsed
  `!! node_modules/` line and treats it as a disposable cache. So **`cleanup --apply` deleted a `.env`
  inside an ignored `node_modules/`**. That is a product bug, now fixed. It does not explain the test
  failure, because that test never runs apply.
- **(c) Any `rm -rf` reachable.** I checked each one:
  - `cmd_gc --auto` runs only on a `bg` launch, and the only `bg` launch is in `$BH`.
  - The verify-clone sweep stays inside `$OSRC_HOME/cloud`.
  - The lock removal stays inside `disk-policy/`.
  - `_cmd_cleanup_target` is the typed `cleanup <id>`.
  - The test traps remove `$TMP` only at EXIT.
  - The `rm` shim saw no `rm` touching `repo/` in any run.
- **(d) A symlinked TMPDIR fooling a containment check.** `tests/lib_scratch.sh` resolves `TMPDIR`
  with `pwd -P` before `mktemp`, so every fixture path is already physical. The shim logs show
  `/tmp/r3real/…`, never the link. `_osrc_cleanup_verdict` uses realpath on both sides.

## What changed

| Change | Where |
|---|---|
| `_osrc_wt_remove <repo> <wt> <who> [caches]` is now the one way cleanup and reclaim delete a worktree. It works in three steps. **(1)** Just before the removal, it re-reads `git status --porcelain --ignored --untracked-files=all` in the worktree; any entry, or a status that fails, keeps the worktree. With `caches` (only typed `cleanup --apply`), files inside a top-level `node_modules/`, `.venv/` or `__pycache__/` are allowed, unless they are secret-shaped (`.env*`, `.npmrc`, `.netrc`, `credentials`, `id_*`, `*.pem`, `*.key`, `*.p12`). **(2)** It logs `removing-worktree` **before** the removal; if that line cannot be written, nothing is removed. **(3)** It runs `git worktree remove` without `--force`, then logs `removed-worktree` or `FAILED-worktree`. | lib/cleanup.sh |
| Reclaim calls the helper instead of its own check, log and remove (net 1 line shorter). | `_osrc_disk_reclaim_lane` (lib/disk_policy.sh) |
| `cleanup --apply` calls the helper for worktrees. | `_osrc_cleanup_apply` |
| Test is hermetic. `age` now sets timestamps 3 hours back, not to 2020: that passes the 1h rule and is far younger than any OS cleaner's limit. The lock test's `touch -t 2020` uses `age` too. A `block` helper stops every block's monitor: it sends TERM to each lock owner and polls until the owner is gone, because monitors are detached and cannot be `wait`ed. A new check asserts that no monitor is alive before incident 3 and none ran during it. `$GH` gets floors before its first CLI call. `rm -f "$RH/disk-policy/settings"` is replaced by `settings "$RH"`. Incident 3 also checks that the removal was logged before it ran and that `deps` never reached the removal step. | tests/test_disk_policy.sh |
| New suite (7 checks): (1) `cleanup --apply` keeps a worktree whose ignored `node_modules/pkg/.env` exists, still removes a cache-only one, and logs the removal before it runs; (2) reclaim removes nothing when the log cannot be written; (3) a `.env` written after the scan but before the removal is kept. | tests/test_disk_r3.sh |
| New static check, registered in conformance. It flags any test line that removes `disk-policy/settings` unless that line or the next one writes floors again (`> …/disk-policy/settings` or `settings <home>`), or the line ends its subshell (`…; exit $r )`, which restores the state the subshell started from, as in `lib_factory_flow_l5.sh`). It proves itself on a bad and a good fixture. On the base it flags `test_disk_policy.sh:403`. | tests/test_disk_settings_lint.sh |

`outsourcerer.sh` is untouched. Line counts: lib/cleanup.sh 907, lib/disk_policy.sh 837.

## Tests (commands, exit codes)

Every suite below except conformance was run alone with `nice bash tests/<suite>.sh`, from
`plugins/outsourcerer/skills/outsourcerer/scripts`, on the final code:

| Suite | rc | Result |
|---|---|---|
| test_disk_r3 | 0 | 10 passed. On base `5769ef9`: rc 1, 7 failed (cases 1, 2 and 4). |
| test_disk_settings_lint | 0 | 3 passed. On base: rc 1, flags `test_disk_policy.sh:403`. |
| test_disk_policy | 0 | 98 passed, in each of the 48 final loop runs. |
| test_disk_r2 | 0 | 22 passed. |
| test_disk_gate_failsafe | 0 | 52 passed. |
| test_cleanup_manifest | 0 | 85 passed. |
| test_no_pipe_grep_q | 0 | |
| test_shell_scratch (python) | 0 | 11 OK. Run after the fix below. |

The loops ran `scratchpad/loop.sh <n> <tag> 4` under the conditions listed in the reproduction
section. They are described there.

Conformance (`nice bash tests/conformance.sh`), run once, on `23ea828`: **rc=1**, `264 passed, 4 failed, 14 skipped`.
- `test_shell_scratch` failed because of my new lint suite: it did not source `lib_scratch.sh`.
  I fixed that in the last commit, and the suite (11 OK) and the lint (3/3) now pass alone. I did not
  rerun the full conformance.
- `test_harness_isolation`, `test_vocab_hygiene` and `test_parity_insource_refresh` fail because the
  container runs as uid 0. I ran each on the base `5769ef9`, and each fails there too (rc 1). Round 2 reported the same.

## Pre-existing, not fixed: the foreground-lane block can hang

**Fixed. This was the second real product bug.** The base hung in 1 of 40 runs (and 1 of 8 with the
cleaner) in the second foreground case ("paused foreground lane survives its guard's hard cap"). I
added a process dump on timeout to the loop. It showed the lane's children SIGSTOPped
(`T`) after the "resume", while the block's monitor was alive. The cause is in
`_osrc_disk_pause_reg` and `_osrc_disk_pause_job`. Each checks that no record exists, then reads
the pids already recorded, then writes its record with `mv -f`. Two overlapping sweeps (here the
test's direct tick and the block's monitor tick, both reading `$FREEF`) can therefore interleave:
the second sweep lists only the pids the first sweep had not listed and overwrites the first sweep's
record with that list. The first sweep's processes are then stopped with no record naming them, so
nothing resumes them. In production only one monitor ticks (the lock), but overlap is possible
during a stale-lock takeover, and the result is a lane frozen for good.

`_osrc_disk_rec_write` now creates the record exclusively: it writes the complete temp file and then
hard-links it (`ln`). Where links are unsupported, it falls back to a noclobber claim followed by a
rename. A record that already exists returns 2, and the sweep treats that as "already paused". I
added a regression check to `test_disk_r3.sh` (case 4); it fails on the base. The existing
"no record -> job left running" check now stubs `ln` as well as `mv`. After this fix: 0 hangs in 48 runs.

## What remains unproven

- I did not run anything on macOS. The cleaner explanation fits every line of the failure and
  reproduces it exactly on Linux, but I cannot replay the Mac's 03:35 dirhelper run. I could not
  read Apple's `dirhelper.c` here to confirm whether it compares atime or mtime; `touch -t` sets both.
- The helper still has a gap of a few milliseconds between its status read and `git worktree remove`.
  A file written inside that gap is lost. Git offers no "remove only if still clean of ignored
  files" operation; the alternative, renaming the worktree aside first, would need a much larger
  change.

## Open questions (decided by the lane)

1. Typed `cleanup --apply` still deletes pure dependency caches (`node_modules/`, `.venv/`,
   `__pycache__/`) inside a merged worktree, but not secret-shaped files inside them. Automatic
   reclaim allows no ignored file at all, as before.
2. A worktree removal whose log line cannot be written is refused, not run anyway.
3. The lint accepts a removal that ends its own subshell, because the parent's state is then
   unchanged.

## Needs from other lanes

- **Release notes**: "`cleanup --apply` no longer deletes `.env` or key files inside an ignored
  `node_modules/`; every worktree removal is logged before it runs (`removing-worktree` in
  cleanup.log)."
- **Anyone writing tests**: never set fixture timestamps days into the past under `$TMPDIR`; the OS
  cleaner may delete them mid-run. Hours are enough for cleanup's 1h rule.

## Reproduction harness (not committed; outside the repo)

- `df` stub on PATH: prints `fake 524288000 519045120 5242880 99% /`.
- `git` and `rm` shims log every `worktree remove`, `branch -D`, `update-ref -d` and `worktree prune`,
  and every `rm` of `repo/` or `reclaim/`, with the caller's command line. Then they exec the real tool.
- CPU stress: 4 × `while :; do :; done`.
- Cleaner stand-in: `while :; do find /tmp/r3real -type f -atime +3 -delete; sleep 0.5; done`.
- Loop: 4 runs in parallel, with `TMPDIR=/tmp/r3l` (a symlink to `/tmp/r3real`), `setsid nice bash
  test_disk_policy.sh`. A 900 s watchdog dumps `ps --forest` before it kills a hung run.
