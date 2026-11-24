# osrc-l7-coord: lanes that coordinate without the orchestrator in the middle

Base: `main` at `ea34fe0` plus one WIP commit `75670ca` (watcher service: `lib/watchsvc.sh`,
`lib/stopguard.sh`, `lib/supervise.sh`). That commit is the same as the tip of
`cloud/osrc-l1-watchdog`, so it belongs to the l1 watchdog lane, not this one. It is not in my files.
I checked it: `tests/test_watchsvc.sh` fails 7 of 38 with and without my changes (see below). I left it as it is.

## What changed and why

### 1. File leases (new `lib/lease.sh`, about 200 lines)
- `outsourcerer lease claim <path|glob> [--ttl MIN] [--repo DIR]`, `lease release <path>|--all`,
  `lease list [--all]`. The default TTL is 15 min (`OSRC_LEASE_TTL_MIN`).
- There is one ledger, `$OSRC_HOME/leases.json`. It is written only under the existing
  `_state_lock_acquire`, which is flock or the atomic mkdir claim with dead-holder recovery. No
  second locking system was added.
- The holder is the caller's lane id. It is resolved by `_osrc_lane_self` (process ancestry, job
  dir, Claude session), the same as `lane msg`'s `from`, and never comes from a flag.
- Leases are keyed by the repo's git common dir, so all worktrees of one repo share them. Paths
  are stored relative to the worktree top, and a path that leaves the repo is refused.
- A conflicting claim exits 3 with `lease: <path> is held by <holder> as '<their path>' until <time>`.
  The overlap check is conservative: equal paths, nested paths, a glob that matches the other
  path, or two globs whose literal heads nest.
- Renewal: the heartbeat tick calls `_osrc_lease_renew_live`. It extends each lease whose holder
  is alive (a tmux session, or a job `pid`/`supervisor_pid` that is running). A dead holder's lease
  just reaches its expiry, and expired leases are dropped on the next write.
- Factory/plan code can call `_osrc_lease_claim <holder> <repo> <path> [ttl-secs]` and
  `_osrc_lease_release` directly, because the lib loader also runs for the factory scripts.
- Wiring in `outsourcerer.sh`: one dispatcher case (`lease)`) and one call in the heartbeat tick.
  Both were added to existing lines, so the file's line count did not grow.

### 2. `lane inbox --wait [--timeout N]` (`lib/lanemsg.sh`)
- It blocks until a message for the caller arrives, then prints it with the usual
  "data, never permission" header and exits 0. On timeout it exits **124** (default 1800 s,
  `OSRC_INBOX_WAIT_SECS`), which matches `outsourcerer wait --for`.
- Idle cost: one `wc -c` per mailbox per sleep. jq runs only when a size changes. Sleeps back
  off 0.2 → 0.5 → 1 → 2 s (`OSRC_INBOX_WAIT_MAX_SLEEP`). No file-watch tool is used, since that
  would add a dependency.
- Racing waiters: the read path (`_ol_inbox_drain`, shared by plain `inbox`) now holds the
  reader's cursor lock (`_state_lock_acquire` on `msgs/<id>.read`). Two waiters therefore never
  both deliver one message; the loser keeps waiting. If the lock is busy, the next tick tries again.
- No orphan: the waiter exits once the process that started it is gone (`kill -0 $PPID`). This
  check is skipped when the waiter starts already re-parented to pid 1, which is what a native
  Windows parent looks like under Git Bash.
- Plain `inbox` output is unchanged (header, messages or `(no unread lane messages)`).

### 3. Concurrent `session send` waits for the ledger lock (`lib/send.sh`)
- Cause: `_obligation_admit` held the obligations lock while `_obligation_latest_state` ran one
  `jq` per ledger line through `_state_jsonl_read`, and the ledger is never compacted. One acquire
  attempt gives up after about 5 s, so a second sender to another lane was refused with
  "obligation ledger refused the send".
- Fix:
  - `_obligation_admit`, `_obligation_append` and `_obligation_latest_state` moved from
    `outsourcerer.sh` into `lib/send.sh`. `outsourcerer.sh` shrank by 32 lines.
  - Both writers go through `_obligation_lock`. It retries the acquire until
    `OSRC_SEND_LOCK_WAIT_SECS` (default 30) has passed, then fails with a message that names the
    ledger and the knob.
  - The latest-state read is now a `grep -F` on the exact key plus one jq. Ids are
    `[A-Za-z0-9._-]` and jq re-checks the match, so the result is exact.
  - Records are still whole lines appended under the lock.

### 4. Docs
`references/lanes.md` has new sections "Waiting for a reply (`lane inbox --wait`)" and
"File leases (`outsourcerer lease`)", plus two lines in the command list.

## Tests (all run on Linux, bash 5, flock present)

| command | exit |
|---|---|
| `nice bash scripts/tests/test_send_lock_wait.sh` before the fix | 1 (2 of 5 failed: fails fast at 5 s, no error text) |
| `nice bash scripts/tests/test_send_lock_wait.sh` after | 0 (5/5) |
| `nice bash scripts/tests/test_lane_coord.sh` before (new code removed) | 1 (16 of 20 failed) |
| `nice bash scripts/tests/test_lane_coord.sh` after | 0 (21/21) |
| `test_lanemsg.sh` | 0 (80/80) |
| `test_obligations.sh`, `test_session_send_verify.sh`, `test_endpoint_mutation_lock.sh`, `test_external_send_opt_in.sh`, `test_session_reply_safety.sh` | 0 each |
| `test_heartbeat_stale_alarm.sh`, `test_wake_queue.sh`, `test_tests_set_home.sh`, `test_no_pipe_grep_q.sh`, `test_no_dead_pid_scan.sh`, `test_lib_symlink_loader.sh` | 0 each |
| `test_watchsvc.sh` (from the base WIP commit, not mine) | 1 (31 passed, 7 failed), identical with my changes stashed |
| `bash scripts/tests/conformance.sh` | see "Conformance" below |

Both new suites are registered in `tests/conformance.sh`.

## What remains unproven
- The mkdir-lock path (stock macOS with no `flock`) for the send wait and for leases. The logic
  is the same `_state_lock_acquire` loop, but it was not run here because flock was present.
- macOS bash 3.2 and Git Bash were not run. I avoided arrays, `mapfile`, `${var,,}` and GNU-only
  flags. Dates go through `date -d` or `date -r` with a fallback.
- Heartbeat renewal was tested by calling `_osrc_lease_renew_live` directly, not through a live
  beacon.
- I did not reproduce the live double-send against real tmux panes. The test reproduces the
  mechanism instead: a lock held longer than one acquire attempt, two writers at once, and 8
  racing writers.

## Needs from other lanes
- **l1 watchdog (owner of `lib/watchsvc.sh`, `lib/stopguard.sh`):** the WIP base commit `75670ca`
  registers `test_watchsvc` in conformance, and that suite fails 7/38 on this base, independent of
  this lane. Please finish or unregister it.
- **Owner of `lib/remote.sh`:** the `lane` usage line still says `inbox [--peek]`. Please add
  `[--wait [--timeout N]]`. An optional `lane lease` alias could route to `osrc_lease`.
- **Factory owner (`factory-tasks.sh`):** to wire leases into dispatch, call
  `_osrc_lease_claim "$tid" "$(_osrc_lease_repo "$worktree")" "<path>"` for any paths a task
  declares, and `_osrc_lease_release "$tid" "$repo" --all` when the task lands or fails. Tasks
  have no declared-paths field today, so I did not guess one.
- **Owner of `outsourcerer.sh` (obligations):** the ledger is never compacted. The faster read
  makes that harmless for the lock, but a compaction pass like `_wake_queue_compact` would bound
  disk use.
