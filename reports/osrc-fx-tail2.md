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
