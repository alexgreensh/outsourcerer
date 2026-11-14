# Hub export: the `team` field

`outsourcerer hub export` (L9's Mission Control surface) embeds the team score in each project
document under the key `team`. The schema is the project document in
`sessions/2026-11-13-autonomy/hub/SCHEMA.md` — project objects are extensible, `team` is an
optional object, absent when the scope has no lanes.

## Shape

`_osrc_team_export_json <scope>` (lib/lanemsg.sh) produces exactly the object `team score --json`
emits per scope:

```json
{
  "scope": "fleet:<sid> | plan:<name> | lane:<id>",
  "lanes": [{"id": "…", "kind": "task|job|remote|session", "state": "…",
             "handed_in": true, "run_id": "…",
             "sha": "…", "tests_passed": 12, "tests_total": 12,
             "tokens_spent": 4200}],
  "tests":  {"passed": 34, "unknown": 0, "pending": 1},
  "tokens": {"spent": 41200, "unknown": 0, "budgeted": 80000},
  "lambda": 0.25,
  "penalty": 0.1287,          // null when budgeted is null/0 or any lane's spend unknown
  "score": 33.87,             // null whenever any input is missing — never fabricated
  "missing": ["budget:fleet:x not declared", "tokens:t2", "tests:t3"]
}
```

Contract: `score`/`penalty` are `null` (and `missing` names the gap) whenever a part is unknown —
an absent budget or an unmeasured lane is reported, never zeroed.

## Integration (one line in `_osrc_hub_build_project`)

```bash
# L12: embed the team score when the lane-messages lib is loaded and the scope has lanes.
local _team; _team="$(type _osrc_team_export_json >/dev/null 2>&1 && _osrc_team_export_json "fleet:${owner:-$sid}" 2>/dev/null || _osrc_team_export_json "plan:${plan:-}" 2>/dev/null)"
… + (if "${_team:-}" == "" then {} else {team: ($_team | fromjson)} end)
```

`type` guard keeps hub working when lanemsg.sh is absent; the `|| plan:` fallthrough covers
fleet-less plan runs. Hub layout/visuals are L9's — this doc specifies only the data field.
