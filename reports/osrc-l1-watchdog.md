# osrc-l1-watchdog: a watcher nobody can forget

## Round 1 (base branch)

Round 1 left one `WIP:` commit (75670ca) and no report: a 739-line `lib/watchsvc.sh`, a test
suite that had never run to completion, and edits to `stopguard.sh`, `supervise.sh`,
`outsourcerer.sh` and `conformance.sh`.

## Round 2

### Verdict on the round 1 work

I ran its suite first: 31 passed and 7 failed (limit resume, `watcher status`, the daemon loop).
Reading the code turned up these problems:

- **Limit auto-continue could miss the reset.** It scanned `limit` rows from a cursor, then moved
  the cursor past them. A row seen before the reset was never looked at again, so the `continue`
  only happened if a later reminder row arrived after the reset.
- **The service could not run under launchd or systemd.** Both start with a bare `PATH`, so
  `jq`, `tmux` and `claude` were not found. User settings were also lost.
- **It called `claude agents --json` to decide whether a session was open.** That command is not
  proven to exist. The repo already reads `~/.claude/sessions/*.json`.
- **It started a background daemon without consent.** Every `supervise` arm and every stop-guard
  run did this.
- **The stop guard allowed the stop whenever the watcher was alive,** even when the watcher had no
  way to wake that session.
- **Its own wake ledger duplicated supervise's delivered ledger,** so the session could be told
  the same thing twice.
- **It grew `outsourcerer.sh` by one line.**

I replaced `watchsvc.sh` (739 → 373 lines) and the test suite (242 → 171 lines). I reverted the
`supervise.sh` arm hook and rewrote the `stopguard.sh` changes.

### Incidents

**1. Supervise armed, two lanes finished, no event logged for that owner for 7 h. Root cause: not
proven; made detectable.**

`supervise` covered a session as long as its pid was alive (`_sv_armed_cover`). Its poll loop runs
`_sv_tick`, which calls `cmd_hub_export` (probes the real agent CLIs), in the foreground with no
deadline, before it observes anything. The beacon's tick likewise builds a full fleet snapshot
before `_sv_observe_all`.

So one probe that never returns (a CLI waiting on a login, the keychain or the network) leaves the
session in this state:
- a live, armed `supervise` that the stop guard accepts;
- nothing observed and nothing logged;
- with the beacon also stuck or gone, this lasts indefinitely.

This matches incident 1, but I have no logs to prove it was the cause.

Fixes:
- `_sv_tick` now runs under `_sv_bounded`, default `OSRC_SUPERVISE_TICK_TIMEOUT=120`. On timeout it
  logs one line to stderr and keeps watching.
- A supervise counts as a waiter only if it polled or armed within `OSRC_SUPERVISE_HUNG` seconds
  (default 600). The poll time comes from the `supervise/<sid>/alive` stamp, which every poll
  already writes.
- A hung supervise now leaves the stop guard blocking, and the watcher treats that owner as
  unwatched. Any hang that stops polling becomes visible, wherever it happens.
- The watcher runs `_sv_observe_all` directly, without the fleet snapshot, and each tick has its
  own deadline (`OSRC_WATCH_TICK_TIMEOUT=300`).

**2. A `done` row in the log, orchestrator not woken for 37 min.** The same mechanism fits: the
beacon logged the row while the armed supervise sat in its refresh. Test: with `cmd_hub_export`
hanging, `supervise` still prints `EVENT done L9` within the bound. Before the fix it printed
nothing until the alarm and then `EVENT failed supervise ... refresh failed`.

**3. A watcher died at 02:36; nine finished lanes waited 4–6 h.** The per-user watcher observes
every owner, finds rows that no supervise has delivered, and wakes the owner itself:
- Each wake is checked by the channel: exit code, or screen proof for tmux.
- Failed wakes retry after 1 min, then 5 min, then every 15 min, with no limit.
- After `OSRC_WATCH_WAKE_MAX` (3) failures it writes `owners/<sid>/.wakefail`. Every outsourcerer
  call prints that file, `watcher status` shows the failure, and the user gets an OS notification.
- A row is never delivered twice: delivered rows go into supervise's own ledger.
- After delivery it removes finished lanes from the owner registry, as `supervise` does.
  Otherwise they would remind every 20 min.
- "still unresolved" reminders wake again at most once per `OSRC_WATCH_REWAKE` (3600 s).

**4. Plan limit reset at 23:00; nothing resumed for 12 h.**
- Each `limit` row is recorded per lane with its reset time. The time comes from `(epoch N)` or
  the existing `_lane_limit_reset_secs` parser.
- After the reset, a lane that still shows that limit and is still owned gets one
  `session send continue`. `limits/<id>.done` records the reset time, so each reset is answered
  once.
- A lane that moved on is forgotten. A new limit later gets its own `continue`.
- An orchestrator that was itself limited is reached by the normal wake retries, which never stop,
  once its reset has passed.

### The service (`lib/watchsvc.sh`)

`outsourcerer.sh watcher install | uninstall | status | run [--transient] | tick`

- **Backends:**
  - launchd plist on macOS (`KeepAlive`);
  - systemd user unit on Linux, when a user bus is available (`Restart=always`);
  - otherwise a detached loop (Windows Git Bash, containers). While installed, the stop guard
    restarts it if it has died.
- **Install** is explicit and idempotent: the unit is rewritten and restarted. It saves `PATH` and
  any `OSRC_WATCH_*` settings to `watchsvc/env`.
- **`uninstall`** removes the unit and all watcher state in one command.
- **Channels, tried in order:**
  1. `OSRC_WATCH_DELIVER_CMD`. It follows the heartbeat wake contract: the summary is `$1` and the
     EVENT/NEXT lines go on stdin.
  2. The session's own tmux pane. The stop guard records it from the hook's environment. A wake is
     typed only when:
     - the pane still runs that Claude Code session (`_fleet_cc_session_for_pane`);
     - the session is idle with an empty composer;
     - `_osrc_send_verify_screen` confirms the submission.
  3. `claude -p --resume`, opt-in with `OSRC_WATCH_RESUME=1`, and only for a session that is
     provably closed.
- **Cost:** shell only. Zero model tokens while nothing has happened. A session the watcher can
  wake needs no background `supervise`.

### Stop guard

- A watcher that is alive and can reach this session counts as a waiter. A watcher with no channel
  to the session does not.
- Loop safety stays: `OSRC_STOP_GUARD_MAX` blocks, then the turn may end. The yield is no longer
  silent:
  - it starts a watcher loop if none runs (transient unless installed);
  - it writes `.unguarded` saying what still watches and how to get a real waiter;
  - it shows an OS notification.
- Opt-outs: `OSRC_WATCH_FALLBACK=0`, `OSRC_FLEET_SUPERVISION=0`, or `OSRC_HEARTBEAT_DISABLED=1` for
  the transient loop.
- Every new call is wrapped, so a hook error still allows the stop.

### Files

| File | Change |
| --- | --- |
| `lib/watchsvc.sh` | rewritten, 373 lines |
| `lib/supervise.sh` | `_sv_bounded`; hang-aware `_sv_armed_cover`; bounded tick; round 1's spawn-on-arm removed |
| `lib/stopguard.sh` | watcher coverage, session notes, the yield that is no longer silent |
| `outsourcerer.sh` | same line count as `ea34fe0`: `watcher)` joined the `supervise)` dispatch line; `watcher` added to two existing case lists |
| `tests/test_watchsvc.sh` | rewritten: 46 checks covering incidents 1–4, the guard, the loop, install |
| `tests/test_supervise_signal.py` | its mutant now also restores the foreground refresh (see below) |
| `tests/conformance.sh` | already registers `test_watchsvc` (round 1); unchanged |

`test_supervise_signal.py` checks that its regression test catches the old signal handler. That
only holds while the refresh blocks the worker in the foreground. The mutant now also undoes the
bounding, so it still models the old code. The real test passes unchanged.

### Tests

All commands run from `plugins/outsourcerer/skills/outsourcerer/scripts`, niced:

| Command | Result |
| --- | --- |
| `bash tests/test_watchsvc.sh` | rc 0, 46 passed |
| `bash tests/test_watchsvc.sh`, with base `lib/supervise.sh` restored | incident 1/2 checks FAIL (3), as intended |
| `bash tests/test_stop_guard.sh` | rc 0, 19 passed |
| `bash tests/test_supervise.sh` | rc 0, 99 passed |
| `bash tests/test_supervise_dedupe.sh` | rc 0, 47 passed |
| `bash tests/test_supervise_lifecycle.sh` | rc 0, 43 passed |
| `python3 tests/test_supervise_tick.py` | rc 0 |
| `python3 tests/test_supervise_signal.py` | rc 0 (rc 1 before the mutant update) |
| `bash tests/test_no_pipe_grep_q.sh` | rc 0 (after rewriting three test lines) |
| `test_tests_set_home`, `test_windows_portability`, `test_noglob_splitting`, `test_no_dead_pid_scan` | rc 0 |
| `bash tests/test_vocab_hygiene.sh` | rc 1, also rc 1 on the untouched base: a pre-existing environment failure (write-failure simulation while running as root) |

### Conformance

`OSRC_CONFORMANCE_JOBS=2 bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh`
finished with rc 1: 242 passed, 6 failed, 1 skipped (live lanes).

`test_watchsvc`, `test_supervise` and `test_stop_guard` are green. The six failing suites all fail
the same way on the untouched base commit 75670ca, each run alone in this container (uid 0):
- `test_harness_isolation`
- `test_vocab_hygiene`
- `test_supervise_pgroup_kill` (the job watchdog in `lib/watchdog.sh`, not this lane's `supervise.sh`)
- `test_parity_insource_refresh`
- `test_conformance_suite_timeout`
- `test_sealed_fixes`

They are environment failures from running as root in this container, not regressions from this
lane.

### Unproven

- **Incident 1's exact root cause.** The hang is a code-level hypothesis; the fix makes any hang
  that stops polling detectable.
- **The tmux channel, positive path.** It is not exercised by tests: the fake tmux cannot render a
  live Claude Code pane. Only the negative path is tested: a recorded pane that does not run the
  session means no channel.
- **The launchd backend.** Only systemd is driven, with a fake `systemctl`. The plist is written
  but never loaded on macOS here.
- **Windows.** The fallback loop's survival after Git Bash closes is untested.
- **`claude -p --resume`.** It is opt-in. A headless turn runs with the user's default permissions
  and may stop on tool approval.
- **An orchestrator in no tmux pane, without a delivery command, still open.** Nothing outside
  Claude Code can type into it. The watcher can only notify, keep the event pending, and make the
  stop guard keep asking for `supervise`. This is a platform limit, and the report says so rather
  than claiming a wake.
- **Absolute-clock limit phrases ("resets 11pm") on rows older than a day.** These are skipped,
  because the read window is 24 h.

### Needs from other lanes

- `lib/stall.sh` (owner unknown): `osrc_watcher_gap` still treats any live armed pid as watched.
  It should use the same freshness rule as `_sv_armed_cover`
  (`supervise/<sid>/alive` within `OSRC_SUPERVISE_HUNG`).
- `outsourcerer.sh` beacon (`_heartbeat_tick`): `_sv_observe_all` runs after the full fleet
  snapshot, with no deadline. Moving it first, or bounding the snapshot, closes the beacon side of
  incident 1. The watcher already avoids the problem.
- `references/jobs-and-safety.md` and `SKILL.md` (docs owner): document `watcher install`, the
  channels, and the `OSRC_WATCH_*` settings.

## Round 3

Fix round for the Fable review of round 2 (`VERDICT: FIX`) and the earlier round-1 review. Base
`cloud/osrc-l1-r2` at `beacb4b`. Paths below are relative to
`plugins/outsourcerer/skills/outsourcerer/scripts/`.

### Orchestrator decisions, as implemented

- **Finding 7: the stop guard never installs or starts a daemon.** The yield path no longer calls
  anything that spawns. `--transient` mode, `_ws_ensure`, `OSRC_WATCH_FALLBACK` and
  `OSRC_WATCH_IDLE_EXIT` are deleted. The guard's block reason and `.unguarded` now say "ask the
  user to run ... `watcher install`". Typing into a tmux pane and the limit `continue` also require
  `watchsvc/installed`, so a hand-started `watcher run` only observes and wakes through a delivery
  command the user configured.
  The one thing that still starts a loop without an `install` in the same call: once the user has
  installed the **fallback** backend (no launchd/systemd), an ordinary outsourcerer call
  (`_warn_unwatched` → `_ws_refresh`) restarts that loop if it died. That is the consented service
  being kept alive, like launchd `KeepAlive`; the stop guard does not do it.
- **Finding 8: waking needs tmux or a delivery command.** This is now stated in the `watcher help`
  text and the `lib/watchsvc.sh` header: a Claude Code session in a plain terminal, an IDE or the
  desktop app cannot be typed into from outside. For such a session `_ws_channel` finds nothing, so
  `_ws_covers` is false and the stop guard keeps blocking with the `supervise` instruction instead
  of trusting the watcher (test: "watcher alive but no channel to this session: still blocks").
  The loop-safety yield after `OSRC_STOP_GUARD_MAX` blocks stays: a guard must never wedge a session.
  The tmux path now has an end-to-end test (below). The user-facing docs are owned elsewhere; see
  Needs.

### Fable round-2 findings

| # | Fix | Regression test (`tests/test_watchsvc.sh`) |
| --- | --- | --- |
| 1 P1 | `_ws_limits` ignores `still unresolved, waiting ` rows, so only a banner's first row sets the reset | "a reminder of a relative banner does not push the reset later" |
| 2 | `_sv_bounded` kills the whole tree with the existing `_kill_tree` (pgrep, or `ps -ef` on Git Bash) | "a timed-out probe dies with its grandchildren"; incident 2's fake refresh is now `x="$(sleep 120)"` |
| 3 | the empty-rows branch also removes `try`, `wakefail` and `owners/<sid>/.wakefail` | "once a supervise delivered the rows, the failure notice and retry state are gone" (also checks the owner dir can be removed) |
| 4 | `_ws_pid_ok` falls back to `kill -0` when `ps -o` prints nothing; the loop exits once `run.lock/pid` is not its own; a lock with no pid yet is not stolen for 10 s | "without ps -o (Git Bash) a live loop still holds its lock", "a loop whose lock was taken over exits" |
| 5 | the unit runs `watchsvc/launch`, which every call repoints at the current `SCRIPT_PATH` (`_ws_refresh`) | "the unit runs a launcher under $BASH, never the versioned plugin path", "a call from a new plugin copy repoints the launcher" |
| 6 | `uninstall` removes both backends' units whatever `installed` says; a failed systemd/launchd start removes the unit and uses the fallback loop; `bootstrap` is retried once after 1 s | "a failed systemd start removes the unit and falls back", "and one uninstall removes it", "uninstall removes a unit even with no install record" |
| 7 | see above | "the yield starts no daemon; it names the install command", "the block reason asks the user to install", "a watcher nobody installed never types a continue / into the pane" |
| 8 | see above; fake-pane tmux test | "tmux: the wake is typed into the session's empty composer and verified on screen" |
| 9 | the `|| [ -f "$s/pane" ]` exception is gone | "a session with a recorded pane but nothing owned is reclaimed" |
| 10 | `osrc-l1-r2.READY` / `.RESULT` deleted; new `osrc-l1-r3.*` written from the real results | n/a |

P3s:

| Item | Fix | Test |
| --- | --- | --- |
| settle race | re-read `rc` after `kill -0` fails | "a delivery that finishes between the two checks counts as delivered" |
| ledger lock | no lock after 50 tries: leave `inflight`, retry next tick | "ledger lock held by a supervise: settle waits", "and records it once the lock is free" |
| coverage env | `_ws_covers` judges the channel after `_ws_env` (install-time `OSRC_WATCH_*` only), and needs a live loop pid, not only a fresh stamp | "coverage is judged by the watcher's settings", "a fresh stamp without a live watcher process is not a waiter" |
| owner twice per tick | one `sort -u` list | "an owner in both lists is processed once per tick" |
| unit vs running loop | `install` stops a running loop first | "install stops a loop that was already running" |
| unverified continue | `.done` and `limit-resumed` only on `session send` rc 0, or rc 2 (submitted, unverified: marked so in the row, never resent, since a resend would be a second `continue`); other rc retried next tick | "a failed continue is not logged as sent; it is retried", "the retry sends it once" |
| `/bin/bash` in the unit | `$BASH` (systemd and launchd) | the launcher test checks `ExecStart="$BASH"` |
| limit cursor vs rotation | cursor stores `size gen`; after a rotation the rest of `events.jsonl.1` is read first | "a limit row logged just before log rotation is still seen" |
| hub not told | `osrc_hub_seen_lane` when a delivered finished lane leaves the registry | "the finished lane is marked seen on the hub" |
| notification per turn end / hourly | the guard notifies only when `.unguarded` first appears; `_ws_failed` only at the attempt that reaches the max | "one notification per yield", "a failing wake notifies once" |
| unbounded `service.log` | trimmed to its last 64 KiB once above 256 KiB, checked each tick | "service.log stays bounded" |
| bloat | deleted: the `resume` channel and `_ws_session_running`, `watcher tick`, `OSRC_WATCH_TMUX`, `--transient` | removed tests with them |

### Round-1 reviewer findings, rechecked against the current code

- **Wakes bypass the spend gate**: no longer applies. The only channel that launched `claude` (`resume`) is deleted.
- **Stale tmux mapping**: no longer applies. A pane is used only if its process tree runs this very
  session id (`_fleet_cc_session_for_pane`), its composer is empty and the screen state is idle,
  and the send is verified with `_osrc_send_verify_screen`. Now also only when installed.
- **Guard accepts a watcher that cannot wake**: fixed in round 2 (channel required), tightened here
  (live loop pid required, the daemon's own settings). `watcher tick` is gone.
- **Failed and deferred wakes lost**: no longer applies; the cursor moves only when nothing is owed.
- **Distinct messages suppress each other**: no longer applies; the ledger is keyed by row id.
- **Concurrent passes deliver twice**: `watcher tick` deleted; lock not stolen before its pid is
  published (10 s grace); a loop that lost its lock exits on its next pass.
- **Resets consumed before due / success recorded on failure**: the first no longer applies
  (per-lane reset files); the second is fixed (unverified-continue row above).
- **Receipt path with spaces**: no longer applies; `inflight` holds `pid t0 channel` only.
- **Timed-out delivery keeps running**: fixed; `_ws_settle` kills the delivery tree with
  `_kill_tree`. The `claude agents` probe no longer exists.
- **Custom notifiers get invalid JSON**: not changed. The watcher's contract is its own and
  documented in the `lib/watchsvc.sh` header: summary in `$1`, EVENT/NEXT lines on stdin and in
  `OSRC_WAKE_EVENT`. The round-2 report's line "it follows the heartbeat wake contract" was wrong:
  the heartbeat passes JSON. Nothing parses the watcher's text as JSON.
- **Failures visible after recovery, invisible in status**: fixed (finding 3; status reads both paths).
- **Conformance leaves detached watchers**: no longer applies; nothing but `install` and an
  installed fallback's refresh starts a loop.
- **Reset tests' negative cases**: no longer applies; every lane is registered with `own`.

### Files (round 3)

| File | Change |
| --- | --- |
| `lib/watchsvc.sh` | all fixes above; 374 → 410 lines (header, launcher and uninstall code added; resume, tick and transient code removed) |
| `lib/supervise.sh` | `_sv_bounded` kills the whole process tree |
| `lib/stopguard.sh` | the guard starts nothing; "ask the user to run"; one notification per yield; `_warn_unwatched` calls `_ws_refresh` |
| `tests/test_watchsvc.sh` | 46 → 74 checks |
| `osrc-l1-r2.READY`, `osrc-l1-r2.RESULT` | deleted |
| `osrc-l1-r3.READY`, `osrc-l1-r3.RESULT` | new |

### Tests (round 3)

Run from `plugins/outsourcerer/skills/outsourcerer/scripts`, one at a time, under `nice`:

| Command | Result |
| --- | --- |
| `bash tests/test_watchsvc.sh` | rc 0, 74 passed |
| the same file against the round-2 code (`git archive beacb4b`) | rc 1, 48 passed, 26 failed. Every new regression check fails there, except the tmux positive path, a coverage test the brief asked for and not a fix. |
| grandchild-probe check alone, both versions | round 2: the `sleep` leaks; round 3: clean. My first version of this check used `$(sleep N)`, which bash runs as a direct child, so it passed on round 2 too. It now uses `$(sleep N; :)`. |
| `bash tests/test_stop_guard.sh` | rc 0, 19 passed |
| `bash tests/test_supervise.sh` | rc 0, 99 passed |
| `bash tests/test_supervise_lifecycle.sh` | rc 0, 43 passed |
| `bash tests/test_supervise_dedupe.sh` | rc 0, 47 passed |
| `test_no_pipe_grep_q`, `test_windows_portability`, `test_noglob_splitting`, `test_tests_set_home`, `test_no_dead_pid_scan` | each rc 0 |
| `python3 tests/test_supervise_tick.py`, `python3 tests/test_supervise_signal.py` | each rc 0 |

### Conformance (round 3)

`OSRC_CONFORMANCE_JOBS=2 nice bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh`
from the repo root: **rc 1**, 241 passed, 7 failed, 1 skipped (live lanes).

- `test_watchsvc` and `test_stop_guard` are green inside the gate.
- Six failing suites are the ones round 2 recorded as failing the same way on the untouched base
  in this container (uid 0): `test_harness_isolation`, `test_vocab_hygiene`,
  `test_supervise_pgroup_kill`, `test_parity_insource_refresh`, `test_conformance_suite_timeout`,
  `test_sealed_fixes`. I did not rerun them on the base this round; that comparison is round 2's.
- `test_release_0175` failed inside the gate (three Mission Control hub restart checks; no file of
  this lane touches the hub). Run alone it passes: rc 0 on round 3 and rc 0 on round 2. I count it
  as a failure under parallel load, not a regression, but it is unproven which.

### Unproven (round 3)

- **launchd.** Its code changed (launcher, `$BASH`, retried bootstrap, fallback on failure) and
  still never runs here: no macOS. Only systemd is driven, with a fake `systemctl`.
- **Git Bash.** The `ps -o` fallback is tested with a fake `ps` on Linux, not on Windows.
  `_kill_tree`'s `ps -ef` path on MSYS is existing code, not exercised here.
- **The real tmux and Claude Code screen.** The tmux test uses a fake `tmux` with the repo's
  recorded Claude Code screens (`cc-composer-idle`, then `cc-working-hooks` after Enter). A live
  pane can differ.
- **Absolute limit phrases ("resets 11pm") on a row the watcher first reads long after it was
  logged.** For example, the watcher was installed after the row, or the machine slept before the
  first tick. The phrase is parsed against the current clock and can land a day late. Reminder rows
  no longer cause this; only a late first read can.
- **Plain terminal, IDE or desktop app, without a delivery command.** No wake is possible. The
  watcher notifies and keeps the events pending, and the stop guard keeps asking for `supervise`.
  After `OSRC_STOP_GUARD_MAX` blocks the guard still yields (loop safety), leaving `.unguarded`.
- **Two plugin copies in use at once.** Each call repoints the launcher, so the copy used last wins.

### Needs from other lanes (round 3, in addition to round 2's)

- Docs owner (`SKILL.md`, `references/jobs-and-safety.md`): say that waking needs tmux, or
  `OSRC_WATCH_DELIVER_CMD` (summary as `$1`, EVENT/NEXT lines on stdin). Say that `watcher install`
  is a user decision. Drop `OSRC_WATCH_RESUME`, `OSRC_WATCH_TMUX`, `OSRC_WATCH_FALLBACK`,
  `OSRC_WATCH_IDLE_EXIT` and `watcher tick` if any doc mentions them (none in this branch does).
- Release/merge owner: keep every `osrc-l1-r*.READY` and `osrc-l1-r*.RESULT` file out of anything
  merged to main.

## Round 4

Closing round for the Fable review of round 3 (`VERDICT: FIX`). Base `cloud/osrc-l1-r3` at
`86957d6` (confirmed with `git log --oneline -3`). Paths are relative to
`plugins/outsourcerer/skills/outsourcerer/scripts/`.

### P2 findings

| # | Fix | Regression test (`tests/test_watchsvc.sh`), fails on the base |
| --- | --- | --- |
| 5 | `_ws_settle` signals a delivery only if the `inflight` record names THIS loop (`$$`, new 4th field) and the pid still has the loop's own command line (`_ws_ours`). A record from an earlier loop (reboot, restart) is treated as a finished, failed delivery: retried, nothing signalled. Past the timeout, a pid that cannot be proven ours (pid reuse, or no `ps -o`) is given up on, not killed. | "a delivery recorded before a restart is over: its pid (now a stranger's) is never signalled", "a timed-out pid that is not this loop's fork is given up on, not killed" |
| 1 | `_ws_limits` starts at byte 0 when `limits/.cursor` is absent, so a lane parked on a limit before `install` (or after `uninstall` + `install`) is continued after its reset. The test no longer seeds `.cursor`. | "reset passed + still limit-parked -> one continue, also for a banner older than the install" |
| 2 | The hook records the session's tmux socket (`watchsvc/<sid>/sock`, from `$TMUX`, directory resolved like tmux does, so macOS `/tmp` → `/private/tmp` matches). `install` captures the caller's tmux server (`TMUX` socket only, and `TMUX_TMPDIR`) into `watchsvc/env`, so the daemon's tmux calls and lane observation use that server. `_ws_env` (daemon) and `_ws_covers` (guard) drop the caller's `TMUX`/`TMUX_PANE`/`TMUX_TMPDIR` first, and the tmux channel exists only when the session's socket equals the daemon's. | "a session on another tmux server (tmux -L/-S) is not covered", plus "a session on the watcher's (default) tmux server is covered", "a watcher installed from that tmux server covers it", "install captures the tmux server" |
| 3 | `_ws_covers` also requires no `owners/<sid>/.wakefail`. | "a channel that keeps failing (.wakefail) is not a waiter" |
| 4 | The loop condition also checks that `watchsvc/launch` (when present) still names its own `SCRIPT_PATH`; when a call from another plugin copy repoints the launcher, the loop exits. launchd `KeepAlive`, systemd `Restart=always`, or the next call's `_ws_refresh` (fallback) restarts it on the new copy. | "a loop whose launcher now names another plugin copy exits" |

### P3 findings

| Item | Fix | Test (all fail on the base) |
| --- | --- | --- |
| orphaned tick after stop | `_sv_bounded` records its child; `_sv_bounded_kill` tree-kills it, only if this shell still lists it as a running job (`jobs -pr`), so a reused pid is never hit. The watcher loop's EXIT trap calls it. `_ws_stop_loop` itself still sends a plain TERM to the loop, so no tree is signalled on a pid it cannot prove. | "stopping the loop takes its in-flight tick with it" |
| hung probe orphaned on signal | the same `_sv_bounded_kill`, in `_sv_main`'s EXIT trap | "a supervise signalled mid-refresh takes the hung probe with it" |
| empty owner dirs | `rmdir owners/<sid>` in the nothing-owed branch | "an owner dir with nothing owned or owed leaves the loop" |
| failed `continue` retries every tick | `limits/<id>.try` with the same 1/5/15 min backoff (`_ws_backoff`/`_ws_due`, now shared with `_ws_failed`) | "a failed continue backs off" |
| no ownership recheck at send time | the ownership check moved from row recording to the per-lane send loop (one check, not two) | "ownership is checked again when the continue is due" |
| empty `ps` output | `_ws_pid_ok` with no `ps -o` output accepts a live pid only while the `alive` stamp is fresh | "without ps -o a live pid with no fresh tick is not the watcher" |
| state on machines without a watcher | `_ws_note_session` returns unless `installed` or `run.lock` exists | "no watcher on this machine: the hook leaves no watcher state" |
| `osrc-l1-r3.RESULT` | `osrc-l1-r3.READY`/`.RESULT` deleted; `osrc-l1-r4.*` written | n/a |
| bloat | deleted `OSRC_WATCH_FALLBACK=0` (5 uses) and `OSRC_HEARTBEAT_DISABLED=0` from the test; `_ws_launcher`'s `/*` relative-path case (SCRIPT_PATH is always absolute, and that case mangled `C:/` paths on Git Bash); the per-owner `att`/`next` parsing (now `_ws_due`). The two-commands-on-one-line dispatch is split back into `supervise)` and `watcher)` lines; to pay for the line, the 4-line comment above the `_warn_unwatched` case is now 2 lines. `outsourcerer.sh`: 19005 → 19004 lines (below `ea34fe0`'s 19005). | n/a |

Test-only changes: tests that used an empty `owners/sess1` as a stand-in owner now put a dotfile in
it (`.keep`, as `.unguarded` does in real use), since an empty owner dir now leaves the loop.

### Looping supervise callers (seen live)

`supervise --session SID --loop`: after each delivered batch it prints the next one instead of
exiting, and stops once the session owns nothing. The worker copies its `armed` file to
`supervise/<sid>/loop.<parent-pid>`, which only the parent removes when it exits, so the session
stays covered between batches. `_sv_armed_cover` reads `loop.*` with the same liveness, `supervise`
command-line and poll-freshness checks as `armed.*`; the stop guard and the watcher both use it.
`armed.*` and the dedupe/supersede logic are unchanged, so `loop.*` never supersedes anyone.
`--loop` requires a session. In loop mode the "re-arm" hint is not printed. Documented in the
`supervise --help` header. Test: "supervise --loop delivers batch after batch and covers the
session in between" (40 samples over 4 s across several batches, zero gaps), "and stops covering
once it exits". A plain wrapper `while :; do supervise; done` is still uncovered between rounds; the
answer for it is `--loop`. Note that Claude Code wakes an agent only when a background command
exits, so `--loop` is for wrapper scripts and output-streaming monitors, not a Claude Bash
background task.

### Tests (round 4)

Run from the scripts directory, one at a time, under `nice`:

| Command | Result |
| --- | --- |
| `bash tests/test_watchsvc.sh` | rc 0, 91 passed, 0 failed |
| the same test file against the base code (`git archive 86957d6`) | rc 1, 71 passed, 20 failed: every new check fails, plus five existing limit checks that fail with it because the base never reads the pre-install banner |
| `bash tests/test_stop_guard.sh` | rc 0, 19 passed |
| `bash tests/test_supervise.sh` | rc 0, 99 passed |
| `bash tests/test_supervise_dedupe.sh` | rc 0, 47 passed |
| `bash tests/test_supervise_lifecycle.sh` | rc 0, 43 passed |
| `python3 tests/test_supervise_signal.py`, `python3 tests/test_supervise_tick.py` | each rc 0 |
| `test_no_pipe_grep_q` | rc 1 on my first draft (two `| grep -q` in the new loop test), fixed, now rc 0 |
| `test_windows_portability`, `test_noglob_splitting`, `test_tests_set_home`, `test_no_dead_pid_scan` | each rc 0 |
| the same, inside the gate's environment (per-suite `TMUX_TMPDIR`, tmux shim on PATH) | rc 0, 91 passed. My first head gate run failed `test_watchsvc` here; see below. |

### Conformance (round 4), base and head

`OSRC_CONFORMANCE_JOBS=2 nice bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh`
from the repo root of each tree:

| Tree | Result |
| --- | --- |
| base `86957d6` (separate worktree) | rc 1, 241 passed, 7 failed, 1 skipped |
| head `e89208e` (first try) | rc 1, 241 passed, 7 failed, 1 skipped |
| head `d39f68c` (final code; this commit adds only the report and READY/RESULT) | **rc 1, 242 passed, 6 failed, 1 skipped** |

| Failing suite | Base | Head (final) | Whose |
| --- | --- | --- | --- |
| `test_harness_isolation` | FAIL | FAIL | pre-existing |
| `test_vocab_hygiene` | FAIL | FAIL | pre-existing |
| `test_supervise_pgroup_kill` | FAIL | FAIL | pre-existing |
| `test_parity_insource_refresh` | FAIL | FAIL | pre-existing |
| `test_conformance_suite_timeout` | FAIL | FAIL | pre-existing |
| `test_sealed_fixes` | FAIL | FAIL | pre-existing |
| `test_sandbox_final` | FAIL | pass (both head runs) | pre-existing, intermittent; no file of this lane touches it |
| `test_watchsvc` | pass | FAIL on `e89208e`, pass on `d39f68c` | **mine, fixed**: the gate exports a per-suite `TMUX_TMPDIR`, and my new "default tmux server is covered" check computed the expected socket with it while the guard (correctly) judges by the watcher's captured settings, where it is absent. Test-only fix in `d39f68c`; the product behaviour was right. |

None of the six remaining failures is in a file this lane owns. They match round 2's list of suites
that fail on the untouched base in this root container.

### launchd: what to run on a real Mac (integration)

From a checkout of this branch, in Terminal (not inside tmux, unless you want to prove the tmux
capture too), with macOS's own `/bin/bash` 3.2. This replaces any real
`com.outsourcerer.watcher` agent for the duration; the last step removes it.

```bash
S="$PWD/plugins/outsourcerer/skills/outsourcerer/scripts/outsourcerer.sh"
export OSRC_HOME="$(mktemp -d)/osrc" OSRC_WATCH_LAUNCHD_DIR="$(mktemp -d)" OSRC_WATCH_INTERVAL=5
mkdir -p "$OSRC_HOME"
/bin/bash "$S" watcher install; echo "install rc=$?"         # expect: watcher installed (launchd, .../com.outsourcerer.watcher.plist), rc 0
plutil -lint "$OSRC_WATCH_LAUNCHD_DIR/com.outsourcerer.watcher.plist"   # expect: OK
launchctl print "gui/$(id -u)/com.outsourcerer.watcher" | grep -E 'state|pid ='   # expect: state = running, a pid
sleep 15; /bin/bash "$S" watcher status; echo "status rc=$?" # expect: installed=launchd daemon=<pid> last_tick=<10s ago, rc 0
p="$(cat "$OSRC_HOME/watchsvc/run.lock/pid")"; ps -o command= -p "$p"   # expect: .../outsourcerer.sh watcher run
kill "$p"; sleep 20; /bin/bash "$S" watcher status            # KeepAlive: a NEW daemon pid, rc 0
cp -R "$(dirname "$S")" /tmp/osrc-v2 && /bin/bash /tmp/osrc-v2/outsourcerer.sh status >/dev/null 2>&1
sleep 25; ps -o command= -p "$(cat "$OSRC_HOME/watchsvc/run.lock/pid")"   # expect: /tmp/osrc-v2/outsourcerer.sh watcher run (P2-4)
/bin/bash "$S" watcher uninstall; echo "uninstall rc=$?"     # expect: rc 0
launchctl print "gui/$(id -u)/com.outsourcerer.watcher" >/dev/null 2>&1; echo "print rc=$?"   # expect: non-zero (unloaded)
ls "$OSRC_WATCH_LAUNCHD_DIR" "$OSRC_HOME/watchsvc" 2>&1; pgrep -fl 'watcher run'   # expect: empty dir, no watchsvc, no process
rm -rf /tmp/osrc-v2
```

Report each "expect" that did not hold. A `launchctl bootstrap` failure (for example over SSH with
no GUI login) must print "using the fallback loop instead" and still end with rc 0 and a running
fallback loop; that is the designed fallback, not a pass of launchd.

### Unproven (round 4)

- **launchd**: still never run (no macOS here); steps above.
- **Real tmux servers**: `-L`/`-S`/`TMUX_TMPDIR` handling is tested with a fake `tmux`, a
  recorded `$TMUX` and a fake socket path. That tmux honours an exported `TMUX=<socket>` without
  the `,pid,index` suffix is from tmux's client code (it cuts `$TMUX` at the first comma), not run
  here. A user who runs `watcher install` outside tmux and Claude Code inside `tmux -L work` is
  now *correctly* not covered (the guard asks for `supervise`); `watcher install` from inside that
  server fixes it. Lanes started on that server are still observed on the daemon's server, so they
  can look gone to a daemon installed elsewhere; that is the remaining half of finding 2. No
  test drives a real `tmux -L` server.
- **Two plugin copies in use at once**: each call repoints the launcher, and now the loop also
  restarts on each flip. Rare, but it costs a restart per flip.
- **The tmux channel after a `cd`**: not investigated this round (Fable's unproven item 3).
- **Git Bash**: the `ps -o` fallbacks are tested with a fake `ps` on Linux only. With no `ps -o`
  the watcher never tree-kills a timed-out delivery (it cannot prove it is its own); it gives up on
  it after `OSRC_WATCH_DELIVER_TIMEOUT` and moves on.
- **`jobs -pr` from an EXIT trap** is how `_sv_bounded_kill` proves the child is its own; tested on
  Linux bash 5. On bash 3.2 it is the same builtin; not run here.

### Needs from other lanes (round 4)

- Owner of `lib/stall.sh`: `osrc_watcher_gap` counts a waiter only through `supervise/<sid>/armed.*`.
  Make it also accept `loop.*` (same pid check), so a `supervise --loop` is not reported as a
  watcher gap between batches (it would need more than 120 s between batches to show today).
- Docs owner: document `supervise --session SID --loop` for wrapper scripts and streaming monitors,
  and that `watcher install` should be run from inside the tmux server Claude Code runs in when that
  server is not the default one (`tmux -L/-S`, `TMUX_TMPDIR`).
- Release/merge owner: keep `osrc-l1-r4.READY` / `.RESULT` (and every earlier `osrc-l1-r*` pair)
  out of main.

### Files changed (round 4)

| File | Change |
| --- | --- |
| `lib/watchsvc.sh` | P2 1-5, P3s above; 410 → 433 lines |
| `lib/supervise.sh` | `_sv_bounded_kill` (EXIT traps), `loop.*` in `_sv_armed_cover`, `supervise --loop`; 829 → 846 lines |
| `outsourcerer.sh` | dispatch split back to one command per line, comment shortened; 19005 → 19004 lines |
| `tests/test_watchsvc.sh` | 74 → 91 checks; removed dead knobs |
| `osrc-l1-r3.READY`, `osrc-l1-r3.RESULT` | deleted |
| `osrc-l1-r4.READY`, `osrc-l1-r4.RESULT` | new |

`lib/stopguard.sh` is unchanged: the guard picks up the `.wakefail`, tmux-server and `loop.*` rules
through `_ws_covers` and `_waited_ids`.

Note on `osrc-l1-r4.RESULT`: the contract fixes its first line as `sha=86957d6…` (the pinned base),
so it cannot carry this work's sha. The work is the branch head `cloud/osrc-l1-r4`; the last code
commit is `d39f68c`.

## Round 5

Final round, for the Fable review of round 4 (`VERDICT: FIX`). Base `cloud/osrc-l1-r4` at
`f85ee37` (confirmed with `git log --oneline -3`: `f85ee37`, `d39f68c`, `e89208e`). Paths are
relative to `plugins/outsourcerer/skills/outsourcerer/scripts/`. The brief preferred deleting a
mechanism to patching it, so the `--loop` cover rule was replaced rather than extended, and two dead
helpers went. Net lib lines: `lib/supervise.sh` 846 → 845, `lib/watchsvc.sh` 433 → 433, total
1279 → 1278. `outsourcerer.sh` is untouched (19004).

### P2 findings

| # | Fix | Regression test (`tests/test_watchsvc.sh`), fails on the base |
| --- | --- | --- |
| 1 | A `--loop` worker exits **20** after a delivered batch, and nowhere else. The parent re-arms on rc 20 alone and maps it to 0 on the way out. `EVENT done all`, a superseded exit (rc 0), the `MAX_SECS` exit and every error end the loop. The "owners dir not empty" check is gone: it is no longer needed. | "--loop ends on done all (no hot spin while a lane has no turn yet)": a session owning one lane that is never live and never dropped; base prints 19 `done all` lines in 8 s and is killed by the alarm. "two --loop arms and a plain supervise: each older one is superseded once and stays gone (no ping-pong)": loop A, then loop B, then plain C on one session; head: A and B each print `superseded` once and exit, C keeps running. Base: A and B both still alive, 5-6 `superseded` lines each, and C was superseded too. |
| 2 | After its `while`, a loop that left because the launcher names another plugin copy (still installed, still holding the lock) releases the lock and `exec`s `watchsvc/launch`. That is the same pid, so it works on all three backends, and launchd/systemd see no exit. If the new copy is missing, the exec fails once with rc 127; the next call's `_ws_refresh` starts it again. | "a fallback loop whose launcher now names another plugin copy re-runs itself there": the same pid ends up running `plugin-v2/outsourcerer.sh watcher run` and holds the lock. Base: the loop exits and nothing runs. |
| 3 | New `_ws_foreign <sid>`: the session's recorded tmux socket differs from the watcher's. Three places use it. (a) `_ws_channel` returns "no channel" first, whatever the channel, so `_ws_covers` (stop guard) and status follow. The tmux branch's own socket comparison is deleted. (b) `_ws_owner` skips the session, so it gets no wake, no `.wakefail` and no settle that drops markers. (c) `_sv_observe_all watcher` skips that owner's lanes, so no false gone/failed rows are logged for them. | "a session on another tmux server is skipped even with a delivery command (no rows, no wake, markers kept)", "and the stop guard does not count the watcher for it (it does once the session is on the watcher's server)". Base: delivered through `OSRC_WATCH_DELIVER_CMD`, and the guard trusted the watcher. |
| 4 | `_ws_run` writes `alive` right after publishing its pid, and `_ws_tick` writes it as each tick starts. The end-of-tick stamp is gone. | "without ps -o a loop in its first (slow) tick is still known as the watcher (no rival)". Base: the starting loop is not recognised. |
| 5 | `--loop` is a waiter only with a proven reader. The parent creates `supervise/<sid>/loop.<pid>` with an old mtime (`touch -t 200001010000`). The worker touches it after a batch was written while its stdout is a pipe or a terminal (`[ -p /dev/stdout ] \|\| [ -t 1 ]`). `_sv_armed_cover` ignores the loop worker's own `armed.<pid>` (the one beside `loop.<pid>`) and counts `loop.<pid>` only within `OSRC_SUPERVISE_HUNG` (600 s) of that touch. So output into a file (how an agent's background task is captured) never covers. A pipe whose reader died kills the worker with SIGPIPE, and a reader that stops reading blocks the write, so the stamp ages out. The `--help` header now says it is for wrapper scripts reading stdout, never an agent's background task. | "a --loop writing into a file (an agent's background task) never satisfies the stop guard", "a --loop into a pipe covers nothing before a batch went through it", "after a batch went into the pipe it covers the session", "and delivers batch after batch with no gap in between", "and stops covering once it exits". Base: the file-backed and the not-yet-read loops both covered. |

### P3 findings

| Item | Fix | Test (fails on the base) |
| --- | --- | --- |
| `--help` cut mid-sentence | `sed -n '2,/^$/p'`: prints the header up to its first blank line, so it cannot be cut again when the header grows | "supervise --help prints the whole header" |
| restart fails a running delivery | `_ws_settle`: a live delivery pid is pending until its `rc` or the timeout, whoever started it. Only a fork recorded by THIS loop and proven by `_ws_ours` is ever signalled. A dead pid with no `rc` is a failed delivery, as before. | "a delivery an earlier loop started is pending while it runs, not failed"; the two round-4 "never signalled" tests still pass |
| no test for how `--loop` ends | covered by the P2-1 tests above (ends on `done all`, on supersession, and on a signal) | as above |
| `rmdir owners/<sid>` race | comment only, as suggested | n/a |
| stale `limits/<id>.try` | `rm -f "$d/$t.try"` whenever a new banner's epoch is recorded | "a new limit banner does not inherit the old banner's backoff" |
| RESULT carries the base sha | the contract fixes line 1 as `sha=f85ee37…` (the pinned base). The brief asks RESULT to name this lane's own head, so its summary names the code commit and says the RESULT commit is its child (a file cannot hold the sha of the commit that adds it). `rc=` is the exit code of a run I actually made. `osrc-l1-r4.READY`/`.RESULT` are deleted. | n/a |
| glob `rm` of `loop.$$` on every supervise | `[ "$loop" = 0 ] \|\| rm -f "$OSRC_HOME/supervise/$sid/loop.$$"` | n/a |

Deleted as dead code: `_sv_informational` (defined, never called) and `_ws_mtime` (one caller,
inlined). The worker's `cp armed loop.$$` is gone; the parent now creates the loop file once.

### Tests (round 5)

All run from `plugins/outsourcerer/skills/outsourcerer/scripts/tests/`, one at a time, `nice`d:

| Command | Head | Base `f85ee37` (separate worktree, the new test file copied in) |
| --- | --- | --- |
| `bash test_watchsvc.sh` | **rc 0, 102 passed, 0 failed** | rc 1, 91 passed, **11 failed**: exactly the 11 new round-5 tests |
| `bash test_supervise.sh` | rc 0 | |
| `bash test_supervise_dedupe.sh` | rc 0 | |
| `bash test_supervise_lifecycle.sh` | rc 0 | |
| `bash test_stall.sh` | rc 0 | |
| `bash test_stop_guard.sh` | rc 0 | |
| `bash test_heartbeat_arm_liveness.sh` | rc 0 | |
| `bash test_supervise_pid_baseline.sh` | rc 0 | |
| `bash test_supervise_pgroup_kill.sh` | rc 1 ("wedge: … SIGKILL did not take") | rc 1, same assertion: pre-existing in this container |
| `python3 test_supervise_signal.py` / `test_supervise_auto.py` / `test_supervise_tick.py` | rc 0 / 0 / 0 | |

One self-inflicted false failure while building: I first ran the base and head copies of
`test_watchsvc.sh` at the same time. The suite uses machine-wide `pgrep`/`pkill -f` patterns, so the
two runs disturbed each other. Every number above comes from runs made one at a time. A test-race
in my first version of the P2-2 test (it read the lock before the re-run loop published its pid) is
fixed in the test.
