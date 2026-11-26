# osrc-fx-rv-hub: release review pass 2 (F32-F58), Mission Control and factory flows

Base: `cloud/osrc-int` at the pinned commit `80575c4`. Branch `cloud/osrc-fx-rv-hub`. One commit per
finding (a few findings have a follow-up commit, named with the same id). Code root below is
`plugins/outsourcerer/skills/outsourcerer/scripts/`.

Two new suites, both registered in `tests/conformance.sh`:

- `tests/test_rv_hub.sh` (F32-F51), with the page checks in `tests/hub_rv_dom.js` (node, DOM stub, no browser);
- `tests/test_rv_factory.sh` (F52-F58).

Each takes finding ids as arguments (`bash tests/test_rv_hub.sh F36`) and runs every section without one.
For each finding the section was run on the base code first (it failed, output quoted below) and again
after the fix (it passed). Bash 3.2 rules kept: no `${x,,}`, no `declare -A`, no `|&`, no `;;&`,
here-strings instead of piping into `grep -q`.

## Findings

### Mission Control shows something untrue

**F32. Band tracker never saw the second export.** Mechanism: `applyProjects` (hub.html) returned before
`A.refresh` whenever the signature, which ignores `exported_at`, was unchanged; the tracker
(hub-attn.js) promotes a lane only when the candidate band held for one more export generation, so on a
quiet fleet an `approval` lane stayed in "working", out of the title count, the favicon dot and the
notification. Fix: on an unchanged signature the page still copies the fresh `exported_at` into its
projects and calls `A.refresh`; `Tracker.update` returns `moved`, and the page re-renders when a band
moved. hub.html stays at 998 lines. Test: `test_rv_hub.sh F32` (hub_rv_dom.js runs the real
`applyProjects` slice with the real hub-attn.js). Before: `FAIL ... (band work)`, title "Mission Control",
no re-render. After: 3 pass.

**F33. Export failures never reached the page.** Mechanism: the server answered 200 with the stale cache
and `export_error`; nothing read it, so the strip said "Live". Also the startup export's failure was
never recorded. Fix: the server records `export_error_at` the first time exports fail (initial export
included, cleared on success) and sends `export_error_since`; hub-alive.js shows
`Not live: export failing since HH:MM · lane data from N ago` as a warning. Test: `F33` (page in node and
a real hub_server.py with a failing fake engine). Before: strip `Live · updated 3s ago · lane data from 11
min ago`; payload had no `export_error_since`. After: 4 pass.

**F34. Warm start served the previous run's lanes as current.** Mechanism: `self.warming` was set by
`load_saved` and never sent. Fix: `/api/projects` carries `warming: true` while the saved export is
served; the strip reads `Starting: showing the last saved state from N ago until the first export
finishes`. Test: `F34`. Before: payload without `warming`, strip "Live". After: 3 pass.

**F35. A one-project refresh reset the doc's age.** Mechanism: `_merge_project_export` set the doc's
`generated_at` to now. Fix: the doc keeps its `generated_at`; only the rebuilt project gets its own
`generated_at`. Test: `F35` (Hub object, fake engine). Before: `1795702295 A2 False False`. After: pass.

**F36. Verified contract downgraded to Unverified.** Mechanism: `st=done` from the contract, then the
`done:exited-0-without-OSRC-DONE` case turned it into `done?`. Fix: the downgrade runs only when the
contract is not done (one line, hub.sh shrank). Test: `F36`. Before: `verified contract shows
Unverified`. After: 2 pass.

**F37 (PLAUSIBLE, confirmed). Done shown before reconcile.** Confirmed with a test: status `running` plus
`exit` 0 mapped to `done` (Done, 100%). Fix: `_osrc_hub_job_state` maps exit 0 to `done?` (Unverified)
until reconcile has seen the marker; a verified done contract still makes it Done. The existing check in
`test_hub_project_state.sh` that asserted the old mapping now asserts `done?`. Test: `F37`. Before:
`state done, status Done`. After: 2 pass.

**F38. Lanes that just left the registry read "Done".** Mechanism: `_osrc_hub_ended_lane` gave a lane
with nothing left, or last seen Building/Idle, status Done. Fix: status `Closed` (note "session closed")
unless the lane builder found done evidence. Closed is an ended status on the page (hub-home.js
`ENDED`), in the settled-project cache, in the export's live-lane check and `sessionsNow`, and counts
with canceled lanes in the derived card (`lib/hub-truth.sh` dcat, one word). A follow-up commit added
`closed` to the `sessionsNow` regex after `test_release_0175` caught it. Test: `F38`. Before:
`Done|session closed|true`, `Building ended reads Done`, Closed counted as working, page lacked Closed.
After: 5 pass.

**F39. "Merged" without a merge.** Mechanism: a remote lane in state done with no verdict got
`rv=MERGE`; a job with a MERGE verdict became Merged 100%. Fix: a MERGE verdict maps to `Approved` (no
percent). Merged needs evidence: `_osrc_hub_landed` (remote record `landed: true`, or a review item of
that lane and head closed as merged), or an Approved lane whose PR in the repo's GitHub cache merged
(`_osrc_hub_lanes_prs`). A done cloud lane with no verdict reads Done. Approved counts as ready on the
derived card (`hub-truth.sh` dcat, one word). Found on the way: the job verdict line
`.status = (...) + {pct:...}` was a jq precedence error, so any job with a review verdict was dropped
from the export entirely; rewritten. Test: `F39`. Before: `Merged|100` for both cloud cases, the job case
produced no row (jq error), merged PR stayed Approved, Approved attention `working`. After: 6 pass.

**F40. Stalled lanes kept the project "updated now".** Fix: `stalled?` and `no-progress-writes` no longer
set the activity `live` flag in `_osrc_hub_lane_activity`; the lane still shows as working, only the
activity clock stops. Test: `F40`. Before: `stalled? reads live=1`, `no-progress-writes reads live=1`.
After: 3 pass.

**F41. Another repo's PR on a common branch name.** Fix: `_osrc_hub_lanes_prs` does no lookup without the
card's repo slug. `test_fx_mc2.sh`'s PR check now passes its repo. Test: `F41`. Before: `borrowed #9 from
another repo`. After: 2 pass.

**F42. One-shot export read finished check:/pr: lanes as not done.** Mechanism: the memoised
`osrc_done_state` answered from `_osrc_done_cache_peek` (default not-done) in every export. A first fix
(inline raw reader) was not enough: the raw `check:` reader is itself asynchronous, so it still answered
not-done and its spawned probe held the caller's pipe (test_hub_speed went from 0 to 3 failures, so this
was caught before release). Final fix: in a one-shot export (`OSRC_HUB_FAST` not 1) a `pr:` contract asks
gh now (TTL-cached by the raw reader) and a `check:` with no fresh verdict runs in the foreground
(`_osrc_done_check_run`, bounded by `OSRC_DONE_CHECK_SECS`); the serve loop keeps the cached, queued
path. The three `test_hub_speed` checks that state "a 20 s probe never holds the export" and the `pr:`
lag check describe the serve loop and now run with `OSRC_HUB_FAST=1`. Test: `F42` (pr: and check:).
Before: `one-shot reads not-done`. After: 3 pass; test_hub_speed 27/0.

**F43 (PLAUSIBLE, confirmed). Probe workers piled up.** Confirmed: three exports in a row gave
`start d43 start d43 start d43 end d43 end d43 end d43`. Fix: the detached worker takes
`hub/cache/scr/.dlock` (mkdir, records its pid); a busy worker skips the probes (the next export queues
them again); a lock whose pid is dead is broken. Only a successful mkdir claims the lock (a first draft
let a second worker claim an empty pid file; fixed before commit). Test: `F43`. After:
`start d43 end d43`, lock released, 2 pass.

**F44. Id-less decisions got id "".** Fix: `(.value.id // "") as $i | if $i == "" then "D\(n)"`. Test:
`F44`. Before: `["","","keep",""]`. After: `["D1","D2","keep","D4"]`.

**F45. One row saying "error" blanked the rail.** Fix: `jq -e 'type == "array"'` instead of the substring
test. Test: `F45`. Before: `rail []`. After: 2 pass (an array with such a note stays; non-array output
still empties the rail).

**F46 (PLAUSIBLE, confirmed). Projects dropped silently.** Confirmed: a card with `"order":"first"` made
its project vanish, a failed build dropped the project, and one bad `_osrc_hub_truth` output emptied the
whole export (no output at all). Fix: a non-numeric order reads 99; a failed or empty build becomes a stub
project with `exportError` (`_osrc_hub_stub_project`, new `lib/hub-safe.sh`), shown on its Home tile; a
failed truth pass keeps the project as built, marked (`_osrc_hub_truth_safe`). Test: `F46`. Before:
`projects ["s46b","s46c"]`, s46b missing, truth case empty. After: 3 pass.

**F47. Stale screen state shown as current.** Fix: when `_osrc_hub_scr_get` serves a cached screen a
minute or more old, it records the age in the export memo; `_osrc_hub_lane_live_fields` adds
`stateAgeMin` and "state from N min ago" to the lane note. Test: `F47`. Before: `stateAgeMin null`, note
without age. After: 2 pass.

**F48. Duplicate Home button ids.** Fix: `gn-` and `tp-` ids use `(d.owner || p.id) + '-' + d.id`. Test:
`F48` (source check; cosmetic). Before: 2 fail. After: 2 pass.

**F49. Docs keyed answers by project slug.** Fix: references/hub.md documents
`answers/<owner-session>--<id>` with `project: <owner-session>`. Test: `F49` (doc check plus a check that
the page still writes that key). Before: 2 fail. After: 3 pass. (Also documented the F33/F34 strip states
there, separate commit.)

### Token and page security

**F50. `mc` handed the token to whatever listened on a probed port.** Reproduced: a test listener on
`OSRC_HUB_PORT` received `X-Hub-Token: <token>` and was reused as Mission Control. Fix: the hub answers
`GET /hello?n=<nonce>` (no token needed) with `HMAC-SHA256(token, "osrc-hub-hello:" + nonce)`;
`_osrc_hub_mc_find` (lib/hub-safe.sh) sends a fresh nonce to each candidate port and checks the proof with
the token given to python on stdin. The token is never sent and never in argv. hub.sh lost the old probe
loop (991 to 978 lines). Test: `F50` (stranger listener plus a real hub). Before: 2 fail. After: 3 pass.

**F51. Old URLs stayed valid for a week.** Fix: `KEY_TTL` 7 days to 12 hours, and `/reopen` requires a
same-origin browser request (Origin, checked as before, or `Sec-Fetch-Site: same-origin`); a scripted
request gets the same 403 "run outsourcerer mc" text as an unknown key (follow-up commit after
`test_mc_alive` caught a bare "forbidden"). Doc updated. Test: `F51`. Before: `TTL: True True False`,
headerless /reopen 200. After: 3 pass.

### Factory: landing and gates

**F52. Verdict contradiction check read "none" on SIGPIPE.** Reproduced on Linux with 3,000 quoted
verdict lines (about 200 KB; Linux pipes hold 64 KB, the review's 34 KB case needs macOS's 16 KB): FAIL,
quotes, final PASS gave `pass` 10 of 10. Fix: the verdict-shaped lines are captured once
(`vl="$(tr | grep -E)"`) and tested with `case`. factory-flow.sh shrank by 4 lines. Test:
`test_rv_factory.sh F52`. Before: `ambiguous only 0 of 10 (last: pass)`, reversed case `fail`. After: 3
pass.

**F53. Time cap left a landing pending.** Fix: the time-cap branch also sets
`auto_land_pending = false`; `land_error` then keeps a later `--auto-land` run from landing it too. The
crash-recovery replay of a real pending landing (test_factory_flow S11) is unchanged. Test: `F53`. Before:
`auto_land_pending: true`, reconcile without `--auto-land` landed t1. After: 3 pass.

**F54. A missing named gate failed open.** Fix: a configured gate that is not a file, or a relative gate
with no repo root, holds the pass with a reason naming the setting. The L5 check that expected "ignored
with one warning" now expects the hold. Test: `F54`. Before: `rc=0` for both, the current folder's
`gate.sh` ran. After: 2 pass.

**F55 (PLAUSIBLE, confirmed). Changed profile ran on the host.** Confirmed: a gate script changed after
the plan's first pass ran on the next pass. Fix: `_osrc_fp_profile_pin` records a checksum of the profile
and the gate script in `<plan>/profile.pin` on the plan's first pass; a change holds launches with a
reason that prints the `rm <pin>` to accept it; `_ff_dispatch` passes the plan. Test: `F55`. Before: both
changes ran (`ran=x changed`), rc 0. After: 3 pass.

**F56. "Rerun the same list" could not work.** Fix: an existing plan with zero tasks is reused. Test:
`F56`. Before: `already exists and none of its tasks are in ...`. After: pass.

**F57 (not reproducible as written; fixed anyway).** The engine's `die` exits, so `--goal` or
`--max-parallel` as the last argument already prints the usage error and `$2` is never read: the test's
first check passes on the base. With a `die` that returns (a caller or harness that redefines it) the
loop does read `$2` and `set -u` aborts with "unbound variable": the test's second check failed on the base
(2 fail). Both options now `|| return 1`. After: 4 pass.

**F58. Edited lines silently ignored.** Fix: plan start records a checksum of each parsed line on its
task (`start_line`); a rerun first compares every existing task's line and refuses, naming the changed
keys, before it adds anything. Tasks from before this change have no checksum and are not compared. Test:
`F58`. Before: edited rerun rc 0, old prompt kept silently. After: 2 pass.


## Suites run (once each, after the last fix)

Command, from `plugins/outsourcerer/skills/outsourcerer/scripts`: `nice bash tests/conformance.sh`
(one run, 21 min 34 s): **rc=1, RESULT: 270 passed, 7 failed, 14 skipped.**

Inside that run every hub and factory suite was green except two that were mine and are now fixed:

| Suite | In the conformance run | After the follow-up commit (run alone) |
|---|---|---|
| test_rv_hub (new, F32-F51) | green | rc 0, 55 pass 0 fail |
| test_rv_factory (new, F52-F58) | green | rc 0, 18 pass 0 fail |
| test_hub, test_hub_truth, test_hub_attn, test_hub_mc2, test_hub_mc3, test_hub_mc4, test_hub_csp, test_hub_plan_refresh, test_hub_project_state, test_hub_speed, test_fx_mc2, test_mc_stale_log, test_plan_probe, test_limits_staleness, test_limits_freshness, test_lanemsg, test_proof | green | (not rerun) |
| test_factory_flow, test_factory_tasks, test_factory_land, test_factory_exclude, test_factory_e2e, test_factory_pstack | green | (not rerun) |
| test_hub_home | **FAIL**: its source check grepped the old `applyProjects` line F32 changed | updated to the new line: rc 0 |
| test_python_utf8 | **FAIL**: the F50 python read stdin in the locale codec | reads `sys.stdin.buffer`: rc 0 |
| test_mc_alive | **FAIL** once: "rotation did not revoke" | rc 0, 59 pass 0 fail (alone, twice). Not reproduced; see below |

The other four failures predate this lane: each fails the same way on the pinned base `80575c4` (checked
in a separate worktree of the base). This container runs as root (uid 0), so read-only-file and
write-failure cases cannot be simulated:

- test_vocab_hygiene: "original was damaged on failed write", "failed rewrite reported success" (base: same).
- test_harness_isolation: "fail-closed failed (rc=0, count=3)" (base: same).
- test_parity_insource_refresh: "read-only target: rc=0" (base: same).
- test_disk_r2: "hub lane ... status Paused" (base: same; the disk lane's area).

Conformance was not run a second time (the brief says once), so the red result stands.

## Files over the size rule

- `lib/hub.sh` went from 991 to 978 lines (the `mc` probe moved to the new `lib/hub-safe.sh`).
- `lib/hub.html` stays at 998 lines.
- `factory-flow.sh` was 1,503 lines on the base, over the 1,000-line rule before this lane. It is now
  1,500 (F52 removed 4 lines, F53 added 1). Splitting it is outside this brief; it is listed below.

## Open questions (decided by the lane)

- **F38: what an ended lane with no evidence is called.** "Closed", counted with canceled lanes on the
  derived card ("1 canceled"), with attention "finished" (Back from work). It is never counted as working.
- **F39: a done cloud lane with no verdict and no merge evidence** reads "Done" (100%), not "Merged" and
  not "Approved": the remote state machine says done, nothing says merged.
- **F42: one-shot export cost.** A plain `hub export` now runs a `check:` contract with no fresh verdict in
  the foreground, bounded by `OSRC_DONE_CHECK_SECS` (300 s). That is what "synchronous" means; the serve loop
  (`OSRC_HUB_FAST=1`) keeps the deferred path. Three `test_hub_speed` checks that describe the serve loop now
  set `OSRC_HUB_FAST=1`.
- **F43: a busy probe worker means skip,** not wait: the next export queues the ids again.
- **F50: an older hub without `/hello`** is not reused; `mc` treats it as silent, and `lib/mc_alive.sh`
  stops it (it verifies the pid is this OSRC_HOME's hub first) and starts a fresh one. One-time on upgrade.
- **F51: the retired-key TTL is 12 hours** (the finding allowed "hours"), and `/reopen` also requires a
  same-origin browser request. Both, because a script can fake headers but cannot fake the clock.
- **F55: how the captain accepts a changed profile:** delete `<plan>/profile.pin` (the hold message prints
  the exact `rm` command). No new CLI flag.
- **F57 is not reproducible as written** (see F57). The `|| return 1` was added anyway, with a test.
- **F58: an edited line is refused,** not applied: the plan keeps one spec per task and the rerun says which
  key changed. Tasks added before this change carry no line hash and are not compared.

## What remains unproven

- test_mc_alive failed once inside the parallel conformance run ("rotation did not revoke") and passed
  alone twice (59/0) on the same head. F51 touched key retirement; the failing check is the `--new-token`
  rotation, which F51 did not change (it still deletes keys.json). It looks like a load-timing flake, but
  that is not proven.

- macOS bash 3.2 and Git Bash were not available here; everything ran on Linux bash 5 with the 3.2 rules
  followed by hand. F52 was reproduced on Linux by making the quoted block 200 KB (Linux pipes buffer 64 KB;
  the review's 34 KB case reproduces only on macOS's 16 KB pipes).
- The page changes (F32, F33, F34, F46 tile note, F48) were checked in node against a DOM stub, not in a
  real browser.

## Needs from other lanes

- `lib/hub-truth.sh` (hub-truth lane): this lane made two one-word changes to `dcat` so the derived card
  understands the new lane statuses: `Approved` counts as ready (F39), `Closed` counts with canceled (F38).
  Please keep them when merging your own changes there.
- `factory-flow.sh` is over 1,000 lines (1,503 on the base). It needs a split by whoever owns it.
