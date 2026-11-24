# osrc-l8-mc: Mission Control that tells the truth for every orchestrator

Base: `main` at `ea34fe0` plus the WIP commit `75670ca` (another lane's watcher service: `lib/watchsvc.sh`,
`stopguard.sh`, `supervise.sh`, `outsourcerer.sh`, `conformance.sh`, `test_watchsvc.sh`). None of that
is in this lane's files, so I left it untouched and did not re-verify it beyond running the suites below.

## What changed and why

New `lib/hub-truth.sh` (294 lines) holds the new logic. The other edits are small hooks.

1. **Derived cards** (`_osrc_hub_derive`, `_osrc_hub_truth`). Each build sorts the real lanes into
   working / waiting for approval / idle / ready for review (READY, no verdict) / done / merged / failed /
   canceled, and derives status, percent (finished ÷ non-canceled), summary ("19 lanes: 19 working") and
   next step ("Review X", "Unblock X", "Pick up the result of X"). The orchestrator's `hub report`
   fields now ride along as `.reported` with `ageMin`. Live values win when lanes are running or when
   lane evidence is newer than the report. A report newer than every settled lane still wins
   (`source: "report"`). While a report is younger than the card-stale window (30 min), its next step and
   ETA are kept. Status, percent and summary always come from the lanes. A user's Mark done, and a
   reported "shipped" with nothing running, are never overridden. A derived card is never flagged
   "card stale" (`hub-home.js`).
2. **One card per project** (`_osrc_hub_group`, full export only). The key is the explicit
   `hub report --project KEY` (new flag). Otherwise it is repo/folder plus the reported name. A session
   that never named the project joins the one name reported in its folder. Sessions with no reported
   name are keyed by derived name plus title, so unrelated work in one repo stays apart; the existing
   MC2 r3 test requires this. The merged card keeps the primary session's id: the one with a Mark-done
   record, else a reported name, else the most recently active. It concatenates lanes (tagged `orch`)
   and decisions (tagged `owner`, so the page answers to the owning session's id), and takes report
   fields only from the newest report. `hub_server.py` no longer splices a single-session export over
   a merged card.
3. **Orchestrator liveness** (`_osrc_hub_orch_state`). For each session: `working`, `idle` + `idleMin`,
   or `gone`. Evidence comes from the Claude session registry (process alive, busy/idle), the heartbeat,
   the auto-report and the transcript mtime. Loud alerts:
   `lanes running, orchestrator idle N min` (≥ `OSRC_MC_ORCH_IDLE_MIN`, 15) or `... orchestrator gone`;
   `lane X finished N min ago, nobody picked it up` (≥ `OSRC_MC_PICKUP_MIN`, 10, and the orchestrator
   showed no sign of life since). The tile shows them, plus "Sessions: working · idle 23 min" when a
   card has more than one session, plus "Its session last said N ago: ..." when live values replaced a
   report. These alerts are excluded from the "stalled lanes" chore count.
4. **Auto-report** `osrc_hub_auto_report [sid]`. It does nothing for non-orchestrators. Otherwise it
   beats the heartbeat, and at most every `OSRC_HUB_AUTO_SECS` (60) a detached worker writes
   `hub/auto/<sid>.json` (derived status, percent, summary, next, counts, at). It never writes the
   orchestrator's own card, never blocks and never fails the caller. `hub serve` watches `hub/auto`, so
   each write re-exports that card. `osrc_hub_tick_touch` (supervise's existing call) now delegates to
   it. It used to overwrite `summary` inside the orchestrator's card file.
5. **Export speed**. Measured first, with a fixture of 150 observed sessions: 41.4 s (25.9 s in
   `_fleet_cc_peer_observations`, about 20 jq forks per session; the rest was naming every peer).
   - `_osrc_hub_cc_rows` reads all session files with one jq (per file only if one is malformed),
     one `kill -0` per pid and one `stat` for every transcript. The export computes it once and reuses
     it for liveness and "Also running".
   - "Also running" sorts first and names only the 12 rows it shows. Titles are still cached by size.
   - Result: 2.8 s for a full engine `hub export` (4.2 s inside the test harness) on the same fixture.
     The base branch takes 45.5 s in the same test.
   - Single-flight: `cmd_hub_export` wraps `_osrc_hub_export_run` in `_osrc_hub_single_flight`, a
     `mkdir` lock per argument set. A second caller waits and reuses the leader's result. A dead
     leader's lock is taken over. After `OSRC_HUB_EXPORT_WAIT` (180 s) the caller runs its own export,
     so a stuck lock can never block exports.
   - Settled-cache version bumped to 6.

Dropped behaviour: "Also running" no longer tails each peer's transcript looking for an unanswered
permission prompt. Its waiting state now comes from the registry's `waitingFor`/status only. That
tail was part of the per-peer cost.

## Files

- new: `lib/hub-truth.sh`, `tests/test_hub_truth.sh`, `reports/osrc-l8-mc.md`
- `lib/hub.sh`: derived block and `.reported`/`.projectKey` in the build; no idle fallback before
  truth; export: one registry pass, liveness, grouping, truth, single-flight; `tick_touch` →
  auto-report.
- `lib/hub-also.sh`: one-pass reader, bounded naming.
- `lib/hub-report.sh`: `--project KEY`.
- `lib/hub-perf.sh`: cache version 6.
- `lib/hub_server.py`: watch `hub/auto`; full re-export for merged cards.
- `lib/hub-assets/hub-home.js`, `hub-decide.js`, `lib/hub.html`: truth lines on the tile, no stale flag
  on derived cards, answers keyed by the decision's owning session, board label only for board
  percent.
- tests updated for the new semantics: `test_hub.sh` (live percent beats the older report; tick writes
  the auto-report), `test_hub_mc2.sh` (a percent derived from lanes is not "invented"),
  `test_hub_mc3.sh` (report fields in `.reported`), `test_hub_home.sh` (draft key grep).
- `tests/conformance.sh`: registered `test_hub_truth`.

## Tests (run here, Linux, bash 5, as root)

From `plugins/outsourcerer/skills/outsourcerer/scripts/tests`, each with `nice bash <suite>.sh`:

| suite | result |
|---|---|
| `test_hub_truth.sh` (new) | rc 0, 23 pass. On the base branch: 4 pass, 19 fail (export 45.5 s); the 4 that pass are "nothing happens" checks |
| `test_hub.sh` | rc 0, 139 pass |
| `test_hub_home.sh` | rc 0, 90 pass |
| `test_hub_mc2.sh` | rc 0 |
| `test_hub_mc3.sh` | rc 0, 70 pass |
| `test_hub_mc4.sh` | rc 0, 47 pass |
| `test_hub_csp.sh` | rc 0, 3 pass |
| `test_hub_project_state.sh` | rc 0 |
| `test_hub_plan_refresh.sh` | rc 0 |
| `test_mc_alive.sh` | rc 0, 58 pass |

`bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh` (run once, niced):
**rc 1, 238 passed, 11 failed, 1 skipped (live probes)**. I re-ran every failing suite on the base
branch (a worktree of `75670ca`) and on this branch. None of the failures come from this lane:

- Same failure lines on base and here (only paths and pids differ): `test_harness_isolation` (1),
  `test_supervise` (9), `test_watchsvc` (7), `test_supervise_lifecycle` (2),
  `test_supervise_pgroup_kill` (1), `test_stop_guard` (3), `test_parity_insource_refresh` (1),
  `test_conformance_suite_timeout` (1).
- `test_vocab_hygiene`: fails 2 on base too. It runs as root here, so its `chmod 500` write-failure
  check cannot fail.
- `test_sealed_fixes`: rc 127 on both (a missing tool in this container).
- `test_release_0175`: rc 0 on both when run alone. It failed only under conformance's parallel run.

Most of these touch the watcher/supervise/stop-guard WIP already on the base branch (lane osrc-l1-r2).

## Unproven

- Not run on macOS bash 3.2 or Git Bash. The code avoids associative arrays, `mapfile`, `${x,,}` and
  BASHPID (it uses `sh -c 'echo $PPID'`); `${cwd//[!A-Za-z0-9]/-}` and `local -a` are bash 3.2 features.
  `stat -c` falls back to `stat -f`.
- The page changes are checked by `node --check` and the existing page-contract suites, not in a browser.
- The 5 s target is met on this container (2.8 s); a slower laptop with real tmux lanes was not measured.

## Needs from other lanes

- **osrc-l1-r2 (`lib/stopguard.sh`)**: in `cmd_stop_guard`, replace
  `type osrc_hub_beat_if_known >/dev/null 2>&1 && osrc_hub_beat_if_known "$sid"` with
  `type osrc_hub_auto_report >/dev/null 2>&1 && osrc_hub_auto_report "$sid"`. It already checks
  orchestrator status and beats; the report work is rate-limited and detached.
- **osrc-l1-r2 (`lib/supervise.sh`)**: in `_sv_tick`, call `osrc_hub_auto_report "$slug"` for every
  owner slug on each wake, without the `[ -f hub/projects/$slug.json ]` condition. That condition
  skips exactly the orchestrators that never ran `hub report`. Until then, `osrc_hub_tick_touch` keeps
  working through the old call.
- **`lib/card_fresh.sh` (owner unclear)**: the stop-guard card nag still blocks a stop when `reportedAt`
  is over 30 min old. Status, percent and summary are now derived, so the nag could accept a fresh
  `hub/auto/<sid>.json` and ask only about open questions.
