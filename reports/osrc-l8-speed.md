# osrc-l8-speed: Mission Control export speed and two honesty bugs

Base: `cloud/osrc-int` at `09a7803` (confirmed with `git log --oneline -3`). I read `git log ea34fe0..HEAD`
and `reports/osrc-l8-mc.md`. The earlier export work holds up on its own fixtures. I found two real
defects in it while profiling. Both are fixed below: the Linux dependency stamp for screens was always 0,
and a single malformed session file made every file take its own jq.

## 1. Export speed

### What the time was really spent on

I rebuilt the reported shape as a fixture: 6 projects, 4 live tmux panes with big transcripts, 6 cloud
lanes whose `check:` done contract is the generated clone script (stubbed with `sleep 4`), and 300 files
under `cloud/`. The base branch took **30-34 s** for a plain `hub export` and made 1,756 process launches
(552 of them `jq`), which matches the reported 1,700.

- **Cloud lanes (rst -> dsf, 3-6 s each)**: no network call is made in the dsf phase itself. The export
  calls `osrc_done_state` inside a function whose stdout is redirected (`_osrc_hub_done_state "$id" > "$f"`).
  Bash keeps a saved copy of the outer `$(...)` pipe on a high fd while that redirect is active. The
  `check:` runner that `_osrc_done_check` forks inherits that copy, so the export's `$(...)` waited
  for the whole clone. I proved it with `/proc/<pid>/fd`: the orphaned runner held the write end of
  the pipe the export was reading. The same leak hit every detached worker (screen refresh, limits
  refresh, history, gh fetch, "also"). Under single-flight's `"$@" > out` those workers held the
  caller's own stdout, so `x=$(outsourcerer hub export)` waited for them too.
- **Live tmux lanes (has -> ols)**: each full screen read runs the transcript question check, the
  registry scans (`_managed_provider`, `_sv_cc_transcript`), the hand-in scan and the done contract.
  With a big registry this cost 0.5-0.7 s per lane in my fixture. I could not reproduce the 7.4 s
  measured on the user's machine. The fix removes the work instead of tuning it.
- **stat**: `_osrc_hub_mt` forked one `stat` per path (478 in the user's run).
- **gh history**: when its cache was more than 10 minutes old, a plain export ran three `gh` network
  calls per project, inline.

### Changes (all in `scripts/lib/`)

- `hub-perf.sh` (memo): `osrc_done_state` is routed through the per-export memo. A `check:` or `pr:`
  contract answers from its last verdict (`_osrc_done_cache_peek`; the plain path already returned
  exactly this verdict before it spawned the probe). The probe goes on a queue for the export's one
  detached worker. Each answer is computed once per lane per export. `osrc_remote_state` is also
  computed once per lane per export (it was called 4 times, 5 jq each).
- `hub-perf.sh` `_osrc_hub_scr_read`: a pane reading is reused across exports while its key matches.
  The key is the checksum of the raw capture, plus the list of the lane's inputs that exist (done
  contract and verdict, supervise state, `.cc`, transcript, registry, autodetach, job files, watch
  files), plus their newest mtime. Any change, new file or deleted file reads the pane again. A
  `branch:` contract reads a git ref and is never reused. This works for plain exports too: a
  long-lived pane costs one capture and one stat.
- `hub-fast.sh` `_osrc_hub_close_fds`: every detached worker closes inherited fds above 2 first
  (`/dev/fd`, bash 3.2 safe). The flush worker runs the real (raw) done probe.
- `hub-fast.sh` `_osrc_hub_scr_deps`/`_osrc_hub_scr_dep_epoch`: the old code used
  `xargs stat -f '%m'`. On Linux that is filesystem status, so the stamp was always 0. It now uses
  `_osrc_hub_mt`.
- `hub.sh` `_osrc_hub_mt`: one `stat` for the whole list (GNU first, then BSD). The perl branch is gone.
- `hub.sh`: a cloud lane row reads its 5 fields with one jq (was 5). The session row has one jq instead
  of two (`prov` was unused). The card fields go into the project's final jq (was 8 jq calls). Lanes
  are collected and joined with one jq per project (was one per lane). The dead `FAST`-only branch of
  `_osrc_hub_done_state` and the `_osrc_hub_*_state_fast` wrappers are deleted.
- `hub-history.sh`: a stale gh cache is served and refreshed in the background in every mode. Only a
  repo with no cache at all is still fetched inline, once.
- `hub-truth.sh` `_osrc_hub_cc_rows`: one malformed session file no longer sends all 150 files through
  their own jq. Files are read line by line in one jq, and only a file whose lines do not parse alone
  is read whole.
- Profiler: `_osrc_hub_prof` uses `EPOCHREALTIME`, then GNU `date +%s%N`, then whole seconds. It never
  writes a literal `N`.

Tried and reverted: reusing the limits rail in a plain export while its input files were unchanged.
`test_hub` showed that the rail also depends on deleted files and on which harnesses are on PATH, so
reuse would have shown stale rows. Plain exports compute it as before.

### Measured (this Linux container, unloaded, same fixture, same inputs)

| | base `09a7803` | this branch |
|---|---|---|
| fixture export, first | 33.6 s | 7.3 s |
| fixture export, nothing changed | 8.7 s (probes cached 60 s) | 5.7 s |
| process launches | 1,756 (552 jq) | ~1,260 (417 jq) |
| `test_hub_truth` 150-session export | 255 jq | 105 jq |

A side-by-side script (not committed) ran base and new on one freshly built fixture. The lane states and statuses were
identical. Only clock-derived stamps differed (`updatedAt`, `summaryAt`, "N min ago").

## 2. A board no longer zeroes the percent (`lib/hub_board.sh`, `hub-truth.sh`, `hub-report.sh`, `hub.html`)

- A task's pct counts only when it is a number, or a `"40"` / `"40%"` string. The project percent is
  the average of the tasks that have one. When no task has one, the card's reported pct stays
  (`pctSource: "report"`). When at least one does, the board pct is used (`pctSource: "board"`).
  Tasks without a pct no longer show 0.
- `.state` is read as an alias of `.status`.
- `_osrc_hub_truth` keeps a board percent regardless of age, as before. A reported percent shown
  behind a board ages out like any other report. The page shows "Average across N work tracks" only
  for a board percent.
- `hub report --board` prints the percent the page will show, for example
  `page shows 80%: your reported --pct (no board task has a pct)`.

## 3. Verify clones (`lib/remote.sh`, `lib/cleanup.sh`)

- `lane rm <id>` deletes `$OSRC_HOME/cloud/<id>.verify.git`.
- `cleanup` (dry run) lists verify clones whose lane is no longer tracked (`remote/<id>.json` gone).
  `cleanup --apply` deletes them and logs each one to `cleanup.log`. The sweep only ever matches
  `*.verify.git` directories that are not symlinks. Nothing else under `$OSRC_HOME/cloud` is touched.

## Tests (Linux, bash 5, run here)

New suite `tests/test_hub_speed.sh` (registered in `conformance.sh`): 17 checks, `rc=0`. Run against
the base code (copied into a base worktree), it fails 11 of 17 checks with `rc=1`:
- the 9 lane states from a first and a repeated export equal the uncached readers' (fake tmux panes
  from real captures, 4 cloud lanes, 2 jobs);
- `$(outsourcerer hub export)` returns in 3 s while two 20 s probes run (base: 25 s), and the probe
  still runs, detached;
- screen reuse: same pane reuses the reading; new text, a new input or a deleted input reads again;
- `_osrc_hub_mt` answers; profiler stamps are numbers under a `date` that prints `N`;
- board: no task pct keeps 80%, `.state` is read, averaging covers only tasks with a pct, a stale
  report percent behind a board ages out, `hub report --board` message, exported card;
- `lane rm` removes only its own clone; the cleanup dry run lists the orphan clone and deletes nothing;
  `--apply` removes it and keeps tracked clones, `notes.git`, `*.done.sh` and logs.

`tests/test_hub_truth.sh`: the speed check now counts jq launches (limit 150, measured 105, the slow
export made 3,000+) plus a 60 s wall bound. Machine load can't make it flaky, and it still fails if the
per-session jq cost comes back. `rc=0` (28/28).

Each suite was run on its own with `timeout 900 nice bash tests/<suite>.sh`. All exited 0:
`test_hub_speed`, `test_hub_truth`, `test_hub`, `test_hub_mc2`, `test_hub_mc3`, `test_hub_mc4`,
`test_hub_home`, `test_hub_attn`, `test_hub_plan_refresh`, `test_hub_project_state`, `test_hub_csp`,
`test_cleanup_manifest`, `test_cloudrun`, `test_remote_review`, `test_portable_mtime`,
`test_no_pipe_grep_q`, `test_tests_set_home`, `test_no_dead_pid_scan`.

Conformance: see the end of this file.

## Not proven

- The user's own machine: under 10 s for their shape and under 3 s when unchanged. Here the fixture
  takes 7.3 s first and 5.7 s unchanged in an unloaded container. The user's machine ran about 3x
  slower per process. Both waits that machine measured (23 s tmux, 18 s cloud) are removed, but the
  remaining ~1,260 launches will likely still take more than 3 s there. What remains is spread over
  the per-project jq chain (history, truth, alerts: ~0.8 s per project here) and the limits rail
  (1.2 s here, 4.3 s there).
- I could not reproduce 7.4 s per pane. I removed the read, I did not explain its size. If that machine
  has a large session registry, the memo's registry index (`_osrc_hub_memo_begin`, two jq passes over
  the whole file) is the next cost: 5.7 s for a 13 MB registry in my fixture.
- macOS bash 3.2 and Git Bash were not run. The new code uses only bash 3.2 constructs: no associative
  arrays, `${x:0:6}`, `eval "exec N>&-"`, `/dev/fd` glob, process substitution, and `stat -c` with a
  `stat -f` fallback.

## Needs from other lanes

- **done contracts (`lib/done.sh`)**: `_osrc_done_check_spawn`'s runner subshell inherits saved fds,
  so any `$(osrc_done_state ...)` taken under a redirected function waits for the whole probe. That
  includes supervise and the stop guard. The export no longer triggers it. The runner should close
  inherited fds first (the same three lines as `_osrc_hub_close_fds`).
- **limits (`lib/limits.sh`)**: `_osrc_hub_limits` is the largest fixed cost left in a plain export
  (`_osrc_lane_summary_base` / `_osrc_harness_detected` launch ~120 processes). It needs its own
  per-export memo or a cache keyed on everything it reads, PATH-detected harnesses included.
- **remote lanes (`lib/remote.sh`)**: `osrc_remote_state` makes 5-8 jq calls; one jq would do.
