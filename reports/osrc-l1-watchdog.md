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
