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
