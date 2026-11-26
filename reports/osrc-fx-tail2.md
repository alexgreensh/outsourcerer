# osrc-fx-tail2: cross-lane leftovers for 0.18.0

Base: `cloud/osrc-int` @ `f2eb2267ab2eda9491fc55e9d19908cd429abfbb`. One item per commit, pushed as it lands.
Items 2 and 3 (`lib/disk_policy.sh`) are out of scope: another lane owns that file.

Paths below are relative to `plugins/outsourcerer/skills/outsourcerer/scripts/`.

## Item 1: cloud tracks show their model
- `lib/cloudrun.sh`: `_cloudrun_register` takes the model as a 12th argument and writes `model` into
  `remote/<id>.json` on both paths (the `lane add` path through `_cloudrun_json_extras`, and the
  direct-write fallback). No `--model` records `<vehicle> default`, so the card never goes blank.
- Mission Control already read `.model` from `remote/<id>.json` (`_osrc_hub_lane_remote`), so the hover
  card names it once the field exists. No hub change was needed.
- Test: `tests/test_cloudrun.sh` (3 new checks: model recorded, hover card JSON names it, default recorded).
  Before (lib reverted): `135 passed, 3 failed`. After: `138 passed, 0 failed`, exit 0.

## Item 7: `review ack` ends the unreviewed nag
- `lib/review.sh` (`osrc_review_events`): a queued item with `acked=true` no longer emits
  `EVENT unreviewed ... queued Nm with no review started`. It stays queued for the reviewer; requeue
  and re-review already reset `acked=false`, so a new head nags again.
- `lib/mc_alive.sh` and `lib/hub-fast.sh` (the memo index `review_queued.tsv`): the same rule, so Mission
  Control's `unreviewed` alert goes away for an acked item too.
- Tests: `tests/test_remote_review.sh` (ack, then 1300 s later no nag for that item; the item stays queued).
  Before (lib reverted): `110 passed, 2 failed` (the new check plus a knock-on in a later section, which
  the test now isolates by un-acking). After: `112 passed, 0 failed`.
  `tests/test_mc_alive.sh` (an acked queued item raises no alert). Before: `58 passed, 1 failed`. After: `59 passed, 0 failed`.

## Item 4: the `bg` launch line names the real lane
- On this base the line already printed the preflight's pinned provider (`PROVIDER=$_OSRC_PIN_PROVIDER`),
  so `--provider droid` printed `default lane: droid`. It still called that a *default* and said "a model
  alias can route it elsewhere", which is false: the child refuses (`_osrc_pinned_assert`) any route
  other than the pinned one. The line now reads
  `job <id> launched on lane <provider>, model <pinned model> ('… status <id>' shows what it ran)`.
  `outsourcerer.sh` shrank by 3 lines (comment block replaced).
- Tests: `tests/test_bg_provider_after_verb.sh` e2e now checks stderr for droid and warp. Before:
  `27 passed, 2 failed` (`launched (default lane: droid; a model alias can route it elsewhere …`).
  After: `29 passed, 0 failed`. `tests/test_lane_liveness.sh` static check follows the new wording: `14 passed, 0 failed`.

## Item 5: the heartbeat beacon ends with its jobs
- `outsourcerer.sh` `_heartbeat_beacon`: it checked for work only before a whole `sleep $cadence`
  (300 s), so it outlived the last job by up to the full cadence. It now waits the cadence in slices of
  `OSRC_HEARTBEAT_IDLE_CHECK` seconds (default 30, capped at the cadence) and stops waiting once no work
  is left; the next pass ticks once more, so the finish is still reported, and then the beacon exits.
  The slice is 30 s, not 1 s, because `_heartbeat_active_work` reconciles every job dir. Net
  `outsourcerer.sh` is still smaller than the base (18832 -> 18830 lines after items 4 and 5).
- Test: `tests/test_heartbeat_immortal_beacon.sh` case 5 (300 s cadence, last job ends at 1 s: beacon
  must exit within 8 s after a final tick). Before: `passed=4 failed=1`. After: `passed=5 failed=0`.
  Also green: `test_heartbeat_single_instance` (7/0), `test_heartbeat_autoarm` (6/0), `test_heartbeat_ownership` (12/0).

## Item 8: the gate started with SIGINT ignored
- New `tests/lib_sigint.sh`: `_osrc_sigint_ignored` (pure bash: a trap set in a subshell reads back as
  `trap -- '' SIGINT` only when SIGINT was ignored at entry) and `_osrc_sigint_restore`, which re-execs
  the caller once with SIGINT at default through a python3 or perl shim (sigaction + exec, nothing else;
  `OSRC_SIGINT_REEXEC` stops a loop). `tests/conformance.sh` calls it on line 2, before any trap or
  scratch dir. When no shim exists, `test_p56_r2`, `test_conformance_suite_timeout` and `test_factory_flow`
  SKIP with the reason; never a silent FAIL or PASS.
- New suite `tests/test_sigint_ignored_start.sh` (registered): background start re-execs with SIGINT
  restored and argv intact; no-shim reports still-ignored; foreground is untouched; the gate is wired.
  Before (gate not wired): `4 passed, 2 failed`. After: `6 passed, 0 failed`.
- Real gate, one-suite shards started as `bash -c 'bash conformance.sh & wait'` (SIGINT ignored):

  | suite | base | this branch |
  |---|---|---|
  | test_conformance_suite_timeout | FAIL `suite INT trap did not fire` | green, gate rc 0 |
  | test_factory_flow | FAIL `caller traps lost: trap -- '' SIGINT` | green, gate rc 0 |
  | test_p56_r2 | FAIL incl. `test 1 = 0` | `test 1 = 0` gone; 3 opencode failures remain |
  | test_p56_r2, no python3/perl on PATH | n/a | SKIP with the reason, gate rc 0 |

  The 3 remaining `test_p56_r2` failures (`test  = opencode`, `test  = credits`, `_probe_opencode`) also
  happen in a plain foreground shell on the base commit in this container. They are not SIGINT-related
  and are not in this lane's scope.
