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

## Round 2 (lane osrc-l8-r2)

Base `cloud/osrc-l8-mc` at `54581a0`. Branch `cloud/osrc-l8-r2`. Paths below are relative to
`plugins/outsourcerer/skills/outsourcerer/scripts/`.

### Review findings

| # | Finding | Fix | Regression test (fails on base, passes here) |
|---|---|---|---|
| P1-1 | macOS awk rejects the multi-line `-v m=` in `_osrc_hub_cc_rows` | mtimes go in on stdin ahead of the rows (marker line `@rows`), no `-v` | `test_hub_truth.sh` "macos": a stand-in awk that refuses a newline in a `-v` value (as macOS awk 20200816 does), and the real One True AWK (`original-awk`, the source of macOS awk) when installed. Both fail on base with `newline in string` |
| P1-2 | bash 3.2's bare `local _OSRC_HUB_CC_ROWS` is set+empty, so the cache guard returned "" | cache counts only with `_OSRC_HUB_CC_ROWS_SET=1`, set after the rows are computed | `_OSRC_HUB_CC_ROWS="" _osrc_hub_cc_rows` (bash 3.2's state) must still read the registry; fails on base |
| P1-3 | supervisor tick beat for the orchestrator and wrote `hub/auto`, hiding the loud alerts | `osrc_hub_tick_touch` and the auto-report are deleted; `hub/auto` is no longer a liveness input. The beat stays in the session's own commands and the stop guard | alerts fixture now runs supervise's real `_sv_tick` with a reported card: the `.beat` mtime is unchanged, no `hub/auto`, and both flags survive. Fails on base (idleMin 0, no alerts) |
| P2-4 | stale export lock with a reused pid froze the export | a lock older than `OSRC_HUB_EXPORT_STALE` (60 s) is taken over whatever its pid; a taken-over leader's temp file is removed; a leader only removes a lock that still holds its pid | lock with a live pid (`$$`) aged 2 min: taken over at once and cleared (base: waits, runs without the lock, leaves it); dead leader's `*.json.<pid>` removed |
| P2-5 | duplicate DOM ids on merged cards | decision ids carry the owning session: `dec-/opt-/note-/send-<owner>-<id>`, home `ptd-`, and every `go(pid, did)` caller passes `<owner>-<id>` | `hub_attn_dom.js`: two sessions' D1 on one card get distinct ids (base: `dec-D1, dec-D1`) |
| P2-6 | percent from lane counts (2 of 20 steps read 100%) | no percent is derived from lanes. A board's percent is kept; otherwise the reported percent stays only while the report is fresh (card-stale window), else it is omitted. The "Average across N work tracks" label is back for board cards | "pct": 2 of 3 lanes done shows no percent; a fresh `--pct 15` stays; a board's 10% with 20 tracks is kept while lanes run. All fail on base (66%) |
| P2-7 | nobody read `hub/auto/*.json` | deleted `osrc_hub_auto_report`, `_osrc_hub_auto_write`, `OSRC_HUB_AUTO_SYNC` and the `auto` entries in `hub_server.py`. The stop guard already beats through `osrc_hub_beat_if_known`, so no replacement call was kept | covered by the tick test (`hub/auto` never appears) |

P3 items taken: the live registry row wins over a dead leftover (test: resumed session reads `working`;
base: `gone`); a follower no longer waits through back-to-back leaders (it takes a result that changed
since it arrived; test fails on base); killed leaders' temp files are cleaned on takeover; the speed
test limit is now 5 s (measured well under 1 s here); `cmd_hub_export` moved into `hub-truth.sh`, so
`lib/hub.sh` is 987 lines. Not taken: the flight key still includes FAST, because a plain `hub export`
must never get a fast-path (cached) result. Grouping of two never-named sessions on one repo is unchanged
(the MC2 r3 test requires unrelated work in one repo to stay apart).

Not done: running on a real Mac. This container has no bash 3.2 (the GNU mirrors are blocked by the proxy),
so P1-2 is tested by putting the variable in the exact state bash 3.2 leaves it in. On a Mac,
`/bin/bash tests/test_hub_truth.sh` is the direct check.

### Mission Control ideas

1. **Attention** (`lib/hub-truth.sh`, in `_osrc_hub_truth`): every lane gets one `attention` from signals
   the export already has (screen state, proof stop, `reviewNeedsYou`, needs-you stall alerts, status);
   the project gets its highest, and an open decision counts as `question`. The order is written once in
   `references/hub.md` ("Attention"), and `test_hub_attn.sh` checks that the doc and `attn_order` agree.
2. **Bands** (`lib/hub-assets/hub-attn.js`): waiting on you / back from work / working (one line). The
   page tracks each lane's band and moves it only when the new band shows in two exports in a row (keyed
   on `exported_at`). With a board that has its own themes, the board's themes stay. A project with no
   board shows band counts, not lane names, following the page's existing rule.
3. **Title, favicon, notification**: `(N) Mission Control` (N = lanes waiting on you + open questions);
   the dot is drawn on a canvas over the existing emoji icon, then restored at 0. The notification is
   off until a click in the `?` panel grants permission (stored per browser in localStorage). It fires
   only on a new waiting item, only while the tab is hidden, never on first load, as one notification
   (fixed tag) with project names and a fixed headline.
4. **Keys**: `n`/`p`, `1`-`9`, `Enter`, `?`; ignored in text fields and with modifiers. A card takes keys
   only after about one second on screen and unmoved (sampled every 200 ms). `Enter` acts only when the
   card itself has focus, so the browser keeps Enter on buttons.

No new dependency, no network call, no chat box or diff viewer. `hub.html` is 999 lines; the new logic is
in `hub-attn.js` and five rules in `hub-mc3.css`.

### Tests (Linux, bash 5, as root; each `nice bash <suite>` from `tests/`)

| suite | rc | result |
|---|---|---|
| `test_hub_truth.sh` | 0 | 29 pass. With this round's lib changes stashed (base code, new test): 16 pass, 13 fail, which are exactly the new regression checks |
| `test_hub_attn.sh` (new, registered in `conformance.sh`) | 0 | 42 pass (34 of them from `hub_attn_dom.js` in node). With the base `hub-decide.js`, the merged-card id check fails (`dec-D1, dec-D1`) |
| `test_hub.sh` | 0 | 138 pass |
| `test_hub_home.sh` | 0 | 90 pass |
| `test_hub_mc2.sh` | 0 | |
| `test_hub_mc3.sh` | 0 | 70 pass |
| `test_hub_mc4.sh` | 0 | 47 pass |
| `test_hub_csp.sh` | 0 | 3 pass |
| `test_mc_alive.sh` | 0 | 58 pass |
| `test_release_0175.sh` | 0 | 83 pass. It first failed with "hub.html grew to 999 (> 998)"; I folded one line and the page is now 998 |
| `test_hub_project_state.sh`, `test_hub_plan_refresh.sh` | 0 | |
| `test_proof.sh` | 0 | 160 pass |
| `test_no_pipe_grep_q.sh` | 0 | It flagged one `| grep -q` in the new truth test (found by conformance); fixed and re-run |

`nice bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh`, run once: **rc 1, 242 passed,
7 failed, 1 skipped (live probes)**. One of the 7 was mine (`test_no_pipe_grep_q`, fixed above and re-run
alone, rc 0). The other six (`test_harness_isolation`, `test_vocab_hygiene`, `test_supervise_pgroup_kill`,
`test_parity_insource_refresh`, `test_conformance_suite_timeout`, `test_sealed_fixes`) are all on round 1's
list of failures that were already on the base branch. I did not re-run them on the base this round.

### Needs from other lanes

- **`lib/supervise.sh` (osrc-l1-r2)**: `_sv_tick` still loops over owners calling `osrc_hub_tick_touch`
  behind a `type` check. The function no longer exists, so the loop is dead; delete it.
- **Round 1's asks are withdrawn**: do not switch `stopguard.sh` to `osrc_hub_auto_report` (it is gone;
  `osrc_hub_beat_if_known` is right), and `card_fresh.sh` should not read `hub/auto`.

## Round 3

Closing edits only. Base `cloud/osrc-l8-r2` at `50af717`.

**P2 fixes**
- **1. Option ids**: `hub-decide.js` callback parameter renamed `(opt, i)`, so ids are `opt-<owner>-<decision>-<i>` again. The page test now gives both merged decisions the same options (Keep/Drop); it fails on base.
- **2. First load**: `Tracker.update` in `hub-attn.js` returns `{count:0, fresh:[]}` while nothing has been seen and `projects` is empty, so `refresh([])` no longer arms `prev`.
- **3. Test**: the swallowed statements in `hub_attn_dom.js` are on their own lines now (the opt-in is really on). Added a case that calls `refresh([])` before the first data. On base both this case and the option-id case fail (run: `node tests/hub_attn_dom.js lib/hub-assets` against the old `lib/`, 2 FAIL; with the fix, 0 FAIL).
- **4. Project `attention`**: deleted the export (`hub-truth.sh`) and the doc sentence in `references/hub.md`; nothing read it. `test_hub_attn.sh` now asserts the project carries none.

**P3 fixes**: leader's temp file removed on takeover only if the leader is dead (`kill -0`); `stat` flavour probed once instead of chained on exit code; `summaryAt` ignored in the page's same-data check; stale test wording; removed the r2 READY/RESULT files.

**Not changed (smallest-change rule, no new features)**: takeover check-then-remove gap (no corruption, only a duplicate export); band hysteresis keyed on all projects; bands only on boards with no themes.

**Tests** (each run alone, niced): `hub_attn_dom.js` 0 FAIL; `test_hub_attn.sh` rc 0, 41 pass; `test_hub_mc3.sh` 70 pass; `test_hub_truth.sh` 28 pass. Conformance: see RESULT file.

**Unproven**: the six conformance failures from round 2 were not re-run on base; the stale-lock `kill -0` change has no dedicated test; the `stat` probe was only run on GNU.

### Needs from other lanes
- Unchanged from Round 2 (`lib/supervise.sh` dead `osrc_hub_tick_touch` loop).
- The lane artifacts (`reports/osrc-l8-mc.md`, READY/RESULT) should not be merged to `main`.
