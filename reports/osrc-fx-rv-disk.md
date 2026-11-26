# osrc-fx-rv-disk: release-review fixes, disk safety and cleanup

Base: `cloud/osrc-int` @ `80575c4ce439b7b8317f92751f9602cee49210b6`. Branch: `cloud/osrc-fx-rv-disk`.
There was no `reports/` directory on the base, so this is the first report for this lane.
One finding per commit, each pushed when made:

| Finding | Commit | Files |
|---|---|---|
| F3  | `39b7f85` | lib/cleanup.sh, tests/test_rv_disk.sh (new), tests/conformance.sh (register) |
| F11 | `f135026` | lib/cleanup.sh, tests/test_rv_disk.sh |
| F12 | `f3d0401` | lib/disk_policy.sh, tests/test_rv_disk.sh |
| F13 | `a94b191` | lib/cleanup.sh, tests/test_rv_disk.sh |
| F14 | `1940d41` | lib/cleanup.sh, tests/test_rv_disk.sh |
| F15 | `2a40ae0` | lib/cleanup.sh, tests/test_rv_disk.sh |
| F16 | `65d4a08` | lib/disk_policy.sh, tests/test_rv_disk.sh, tests/test_disk_policy.sh (one pin moved) |
| F20 | `7204832` | lib/disk_policy.sh, lib/supervise.sh (one line), tests/test_rv_disk.sh |

Every regression test is in `tests/test_rv_disk.sh`, which is registered in `conformance.sh`. "Fails before"
was checked by `git stash push <lib file>`, running the suite against the previous code, then restoring the stash.

## Per finding

### F3 (P1): `cleanup <id>` without `--force` deleted worktrees holding ignored or hidden-untracked files
- **Mechanism:** the dirty check was plain `git status --porcelain`, which hides ignored files and, under
  `status.showUntrackedFiles=no`, untracked ones too. Removal then ran `git worktree remove --force`
  (or `rm -rf`), bypassing `_osrc_wt_remove`.
- **Fix:** the dirty check now uses `--untracked-files=all`. Without `--force`, removal goes through
  `_osrc_wt_remove` (no caches mode). Its rc 2 becomes a REFUSING message that names the inspect command.
  `--force` still uses `git worktree remove --force`. If the repository is gone, the worktree cannot be
  inspected, so it is now refused without `--force` (before, it was `rm -rf`).
- **Test:** a gitignored `.env` is refused and kept; a file hidden by `showUntrackedFiles=no` is refused
  and kept; `--force` still removes; a clean, pushed worktree is removed and logged in `cleanup.log`.
  Before: 3 of 4 FAIL (all three non-force cases removed the worktree). After: PASS.
- **Release note:** `cleanup <id>` now refuses a worktree that holds untracked, ignored or hidden files (a `.env`, a local DB), and names them so you can check; `--force` still removes it.

### F11 (P2): secret-shape list in `_osrc_wt_remove`
- **Mechanism:** the match was case-sensitive (`.ENV` passed on macOS) and missed `.envrc`, `*.env`,
  `.pypirc`, `*.pfx`, `*.jks` and `id_dsa`. Tracked files marked skip-worktree or assume-unchanged hide
  their edits from `status`.
- **Fix:** names are lowercased (`tr`) before matching, and the list is widened. `git ls-files -v` entries
  tagged `S` or lowercase (assume-unchanged) keep the worktree in two cases: the file is on disk and its
  `hash-object` differs from the index blob, or its name came back quoted and cannot be checked. A sparse
  checkout's absent `S` files do not block removal.
- **Test:** each of `.ENV .envrc prod.env .pypirc cert.PFX keystore.jks id_dsa` under `node_modules/` in
  caches mode returns rc 2 and is kept. An edited skip-worktree file is kept, an edited assume-unchanged
  file is kept, and an unchanged assume-unchanged file does not block removal.
  Before: 10 FAIL. After: all PASS.

### F12 (P2, latent): `_osrc_disk_lane_sha` passed the base sha into the `--any-ref` slot
- **Fix:** it now calls `_osrc_branch_merged "$1" "$2"`. The now-unused `base` read in `_osrc_disk_reclaim_lane`
  is removed.
- **Test:** a stubbed `_osrc_branch_merged` records its argument count. Before: `argc=3 <sha>` (FAIL).
  After: `argc=2` (PASS).

### F13 (P2): `cleanup <id>` killed the live job before refusing; fanout always said "cleaned"
- **Fix:** the refusal checks move, unchanged, into `_osrc_cleanup_target_refuses`. It reads the caller's
  variables, plus an up-front ignored/untracked check. It runs before the kill, so a refusal never stops a
  lane. It runs again after the kill, because the lane may have written in between. The kill only runs for a
  pid that `kill -0` reports alive. Fanout cleanup runs each member in a subshell with `</dev/null`, so one
  member's `die` cannot skip the rest. Then it prints `cleaned fanout <gid> (N member(s))`, or
  `NOT cleaned: <ids>` with rc 1.
- **Test:** a running lane with a dirty worktree (a real `sleep` pid) is refused and still alive; `--force`
  stops and removes it; a fanout with one clean and one dirty member removes the clean one, names the dirty
  one and fails. Before: 2 FAIL (lane killed; "cleaned fanout" with rc 0). After: PASS.
- **Release note:** `cleanup <id>` no longer stops a running lane it then refuses to clean, and `cleanup <fanout-id>` now lists the members it kept and exits non-zero.

### F14 (P2): `cleanup --apply` deleted a SAFE job dir while its worktree was still ASK
- **Fix:** in `_osrc_cleanup_verdict`, a job, loop or isolated dir whose `worktree.json` names a path that
  still exists is ASK (`its worktree <path> is still there (this dir holds its receipt)`). An unreadable
  receipt is also ASK. `--apply` already removes worktrees first, so a SAFE pair still goes in one run.
- **Test:** a worktree that is ASK (ignored `.env`) and its done, aged job dir. After `--apply` both and
  the receipt survive, and the dry run names the reason. After the `.env` goes, one `--apply` removes both.
  Before: 3 FAIL. On the base the worktree then stays ASK forever. After: PASS.

### F15 (P2, PLAUSIBLE, confirmed): early `grep -q` plus writer SIGPIPE read as "no match"
- **Confirmation:** `outsourcerer.sh:176` runs `set -uo pipefail`. In a reproduction with a 300,000-line
  listing whose first line matches, `_osrc_job_collected` returned 0 ("collected") and
  `_osrc_branch_checked_out` returned 141 ("not checked out"). Both are the unsafe direction.
- **Fix:** both functions capture the output first, then match with `grep -qxF -- … <<<"$var"`. A worktree
  list that git cannot produce counts as checked out (the caller keeps the branch).
- **Test:** those two reproductions. Before: FAIL (`rc=0`, `rc=141`). After: PASS.
  `test_no_pipe_grep_q`: PASS.

### F16 (P2): stopped lanes after a SIGKILLed monitor; "paused" after a lost bank
- **Lost bank:** `_osrc_disk_resume_rec` kept the whole record when `disk-paused-secs` could not be written,
  so a running job read as paused and its pause clock kept growing. Now the record is renamed to
  `disk-paused.unbanked.<pid>.<epoch>`. A rename needs no new data blocks, so it works on a full disk.
  `_osrc_disk_paused_secs` adds each such span (resume epoch minus `since`), so the watchdog's clocks still
  shift. The next successful bank includes the span and removes the files. Only if the rename also fails
  does the old record stay.
- **SIGKILLed monitor:** no OS-level guarantee is possible: a SIGKILLed process cannot SIGCONT anything. The
  existing recovery is any command or heartbeat that runs `_osrc_disk_heartbeat`. F20 adds one more: when
  supervise confirms a lane really is stopped, it calls `_osrc_disk_heartbeat`, which starts a monitor if
  none holds the lock. The monitor loop itself is not touched, because another lane owns it.
- **Test:** a real `sleep` delegate is paused, its `since` is backdated by 100s, and `disk-paused-secs` is
  replaced by a directory so the bank write fails. After resume the process runs, `_osrc_disk_target_paused`
  is false, the record is gone and `_osrc_disk_paused_secs` ≥ 100. A later pause and resume with banking
  restored includes the span once (100 to 200s) and leaves no `unbanked` file.
  Before: FAIL (record kept, reads "paused"). After: PASS.
- **Pin moved:** `test_disk_policy.sh` P2 asserted the old behaviour ("failed bank keeps the pause record and its since line").
  It now asserts the record is gone and the span is still counted (≥30s).
- **Release note:** after a disk pause that could not save its pause time (full disk), the resumed lane now shows as running, not "paused"; its time limits still allow for the pause.

### F20 (P2, PLAUSIBLE, confirmed): supervise trusted a stale pause record
- **Confirmation:** with a job's record in place but its process resumed (SIGCONT), or naming only a dead
  pid, `_sv_observe` still set `SV_K=disk-paused`, for 2 cases on the base.
- **Fix:** new `_osrc_disk_paused_live <id>` in `lib/disk_policy.sh`. It returns 0 (trust the record) in
  three cases: the record is under 60s old (a pause can be mid-write, and dropping its record then would
  leave processes stopped with no record), `ps -o stat=` cannot read stat (Git Bash; same as before), or a
  recorded identity-verified process shows `T`. In that last case it also runs `_osrc_disk_heartbeat`.
  Otherwise it logs, retires the record through `_osrc_disk_resume_rec` (which SIGCONTs anything still
  recorded and banks the time) and returns 1. `_sv_observe` then reads the lane's real state. The
  `lib/supervise.sh` change is one condition on the existing `if`.
- **Test:** a really stopped lane → `disk-paused`; the same lane after SIGCONT → not disk-paused, record
  gone; a fresh (<60s) record → still trusted; a record naming only a dead pid → dropped.
  Before: 2 FAIL. After: PASS.

## Suites run (each once on the final code unless noted, from the scripts dir, `nice bash tests/<suite>.sh`)

| Suite | Result |
|---|---|
| test_rv_disk (new) | 30 pass 0 fail, rc 0 |
| test_cleanup_manifest | 85 pass 0 fail, rc 0. One run during F13 failed once ("gate still refused after ack") while test_disk_policy ran at the same time. It passed alone right after and twice later. I believe it is load-dependent (aging and open-file checks), not caused by this lane, but I could not prove it. |
| test_heartbeat_reclaim | 2 passed 0 failed, rc 0 |
| test_no_pipe_grep_q | PASS |
| test_disk_policy | 98 passed 0 failed, rc 0 |
| test_disk_r3 | 10 passed 0 failed, rc 0 (run at F16) |
| test_disk_r2 | 21 passed **1 failed**, rc 1. `hub lane is Blocked with the pause note` gets `status:"Paused"`. **It fails the same way on the pinned base commit** (run in a separate worktree), so it is pre-existing hub-side drift, outside this lane's files. |
| test_supervise | 101 passed 0 failed, rc 0 |
| test_supervise_lifecycle | 43 passed 0 failed, rc 0 |
| test_supervise_dedupe | 47 passed 0 failed, rc 0 |
| test_fx_mc2 | 55 passed 0 failed, rc 0 |
| conformance.sh | see `## Conformance` below |

## Open questions (decided by the lane)
- **`cleanup <id>` when the repository is gone:** now refused without `--force`, because its content cannot
  be checked. It used to be `rm -rf`.
- **`cleanup <id>` on a job with no `worktree.json`:** it no longer kills the job. It prints "no worktree to
  clean" and leaves the job running. Killing a lane is not what a worktree cleanup with nothing to clean
  should do.
- **Unchanged skip-worktree or assume-unchanged files:** compared by `git hash-object` against the index
  blob, so they do not block removal forever.
- **Grace for a fresh pause record:** 60s. A pause writes its record and SIGSTOPs within milliseconds, so 60s
  leaves plenty of margin and still drops a stale record on supervise's next pass.

## Needs from other lanes
- **Hub lane (owns `lib/hub*.sh`):** `test_disk_r2` "hub lane is Blocked with the pause note" fails on the
  base. `_osrc_hub_lane_job` now returns `status:"Paused"` and `note:"paused; paused: free disk is under the floor"`,
  but the test expects `Blocked` and `Paused: disk below …`. Either the test or the hub row needs
  updating. `test_fx_mc2` (which expects `Paused`) passes.
- **Monitor or supervise-polling lane:** the F20 guard sits inside `_sv_observe`'s disk-paused `if` (one
  condition added). If that lane rewrites the block, keep the `_osrc_disk_paused_live` call.

## What remains unproven
- F15 beyond the reproduced pipe sizes; F11 on a real case-insensitive volume (tested by name only, on Linux).
- No macOS or Git Bash run was possible here. The code avoids bash 4 features; on Git Bash, `ps -o stat`
  returns nothing, and the F20 guard then keeps the old behaviour.
