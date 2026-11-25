started

# osrc-spend-attack: map every free-or-paid decision, attack the spend gate

Model id this lane ran as: `claude-opus-5-5`.
Base: `cloud/osrc-int` @ `2f7d58b` (confirmed: `git log --oneline -1` -> `2f7d58b Drop osrc-pr88 hand-in files`).
Work branch: `cloud/osrc-spend-attack`. Tests ran as the normal user `lane` (the shell was root).

Earlier work on the base (`ea34fe0..2f7d58b`, 122 commits; the osrc-pr88 lane's report is in
`git show 26428d6`) was read and re-checked by attacking it, not trusted: its 5 fixes hold under
this lane's cases (the `-m swe` P1, the cc -> Devin self-heal, `continue -m <paid>`, the
`vendor/` prefix and the probe fallback). This lane found 7 more holes, listed below.

## Step 1: the map

Billing classes: `subscription | free | metered | unknown`; unknown counts as metered.
Only Devin (dv) bills per model. Every other lane bills per lane (auth/env evidence), so a
different model id on the same lane cannot turn paid into free.

| file:line (at 2f7d58b) | function | decides | trusts | verdict |
|---|---|---|---|---|
| lib/spend.sh:77 | `_osrc_devin_free_for_spend` | is this Devin id Free | catalog Free-id set; offline the exact ids swe-2-high, swe-2-flash-high | **RISK (H1)** folded case and dots: `SWE-2-HIGH` / `swe.2.high` judged as `swe-2-high` while the launch passed the spelling verbatim. Offline `run -m SWE-2-HIGH` launched `--model SWE-2-HIGH` with no consent. A bg pin does the same online. |
| lib/spend.sh:109 | `_devin_catalog_free_ids` | the catalog's Free ids | structured `cost_tier` only (`strings`, then compared to "free"); `v2|mtime` cache key | OK: string/array/object/null/number/missing `cost_tier` and Free-sounding `cost_summary` all come out paid. v1, 2-field, `mtime=0` and stale-mtime cache rows are ignored (tested). |
| lib/spend.sh:218 | `_devin_default_free_model` | bare-run default | catalog Free set, offline swe-2-high | OK (picks only exact Free ids). |
| lib/spend.sh:294 | `osrc_lane_billing` | lane billing | env keys, auth CLIs, config files; dv: the model id | OK for all lanes except dv with an empty model (see H3). `*cloud*`/`*hosted*` disp is always metered. |
| lib/spend.sh:445 | `_osrc_spend_ok` | is consent present | `--spend-ok` parsed this command (env value unset at line 280), bound lane/model pair; bg marker = job dir under `$OSRC_HOME/jobs` + per-job token + exact pair, deleted on use | OK: env `OSRC_SPEND_OK`, `OSRC_SPEND_GATE`, `_OSRC_SPEND_BOUND_*`, `OSRC_FAILOVER_CASH_OK`, `_OSRC_PREFLIGHT_PAIR`, a marker with the wrong token or outside jobs/: refused (tested). The job's own marker consents once (tested). |
| lib/spend.sh:495 | `_osrc_lane_spendable` | may an auto picker choose this lane | billing + consent | OK: paid dv model not spendable (tested). Callers: outsourcerer.sh:14768, 15044 (failover pickers), lib/limits.sh:462 (limit fallback). |
| lib/spend.sh:638 | `_osrc_spend_gate` | ask / refuse / proceed | billing + consent | **RISK (H3)** `dv` with an empty model was judged as the Free default although the caller did not know what would launch. |
| lib/spend.sh:700 | `_osrc_session_spend_gate` | session start | PROVIDER + MODEL after resolution | OK when MODEL is set; with no `-m` see H2. |
| lib/spend.sh:535 | `_osrc_spend_marker_pairs` / `_write` | bg child consent pairs | preflight pair, else exact pairs | OK (never `*`, never empty). |
| outsourcerer.sh:15356 | route_delegate local lane | local | always free | OK. |
| outsourcerer.sh:15566-15569 | route_delegate gate | every run/bg/fanout/factory dispatch | `_osrc_dv_launch_prepare` (dv), RESOLVED_ID (others) | OK: run/bg/fanout `-m swe` refuse the paid `swe-2-1-high` (tested); factory plan/task launches go through `cmd_bg` (factory-tasks.sh:568); loop/escalate attempts run `$SCRIPT_PATH <verb>` subprocesses and never forward consent. |
| outsourcerer.sh:14929, 15174 | `_fb_rebuild_argv`, `_failover_rebuild_argv` | fallback / failover hops | re-enter route_delegate; keep `--spend-ok` | OK: consent is bound to the first gated pair, so a hop to another paid pair asks again (tested in-process). |
| lib/devin-free.sh:38 | `_osrc_dv_launch_id` | un-routed Devin launch (cc -> Devin self-heal) | resolve now, gate that id | OK: consent bound to the OpenRouter pair does not cover the Devin hop (tested). |
| outsourcerer.sh:2717 | `continue_turn` | `continue` | resolved MODEL | **RISK (H2)** no `-m`: gate judged the Free default, launch ran `devin -c --model ""` (Devin picks). |
| outsourcerer.sh:16777, 16990 | session start (winpty, tmux) Devin | `session start` | resolved MODEL | **RISK (H2)** no `-m`: `devin --model ''` launched with no consent. |
| outsourcerer.sh:15881 / 17108 | `_session_control_relaunch` (`session control relaunch`) | relaunch | none | **RISK (H4)** relaunch of a session started with `--spend-ok` on a paid model starts a new process on it with no consent. |
| outsourcerer.sh:16737 | `_session_relaunch_effort` (`session effort` on codex/cc/droid) | relaunch | none | **RISK (H5)** same as H4, through `session effort high`. |
| outsourcerer.sh:17129 / 15938 | `session model [NAME]` / `_managed_session_model` | live model switch | none (exclude check only) | **RISK (H6)** `session model swe-2-1-high` types the paid id into Devin's picker with no consent. **RISK (H7)** bare `session model` presses Enter in the picker (the choice is unknown) with no consent. |
| lib/cloudrun.sh:684-690 | `cloud start` | hosted session | `_osrc_spend_gate` with the vehicle; devin cloud also needs `--spend-ok` | OK (devin cloud always needs `--spend-ok`; other vehicles bill by the lane's proven login, as documented). |
| lib/heavy.sh:530 | heavy-check offer | builds a NEXT with `--spend-ok` | nothing is launched; the NEXT is an approval line | OK. |
| outsourcerer.sh:10476 | bg `_OSRC_PIN_AUTH` | bg parent | the preflight's own consent | OK (only set when this command's preflight consented). |
| lib/devin-free.sh:183 | `_devin_is_free_model` | "free-tier" banner, plan meter | static plan-included list + catalog | OK: display and plan-meter only, never a spend decision. |
| lib/devin-free.sh:127 | `_devin_resolve_dynamic` | which variant an alias resolves to | `cost_tier` exact Free for ranking | OK: the gate judges its output. |
| outsourcerer.sh:925-992 | `_devin_probe_pick`, `_devin_free_probe`, `_lane_free_probe` | doctor / plan-quota probe | `OSRC_DEVIN_PROBE_MODEL` or glm-5-2, then swe-2-high, swe-1-7, kimi-k3 | Accepted, not fixed: a one-word PONG to plan-included models (the documented health probe; no paid ACU). Listed under Unproven. |
| lib/plan_probe.py `devin_parse` | plan overlay | text table | display only | OK (never reaches a gate). |
| lib/advise*.sh | `advise` | recommends a model | does not launch | OK: the launch it recommends is gated by route_delegate. |
| lib/disk_policy.sh:521 | disk pause/resume | SIGSTOP/SIGCONT | not a launch | OK. |

## Holes found and fixed (each test fails on 2f7d58b, passes now)

| # | Input on 2f7d58b | Fix | Test (`tests/test_spend_attack.sh`) |
|---|---|---|---|
| H1 | catalog unreachable, `run -m SWE-2-HIGH` (also `swe.2.high`, `Swe-2-High`) -> `devin --model SWE-2-HIGH -p`, rc 0, no consent | `_osrc_devin_free_for_spend` compares the exact launched id (no folding). Routed runs still resolve any spelling to the catalog's exact uid first, so `-m SWE-1.7-HIGH` online still runs Free as `swe-1-7-high`. | `spell:offline …` (3 fail before), `spell:billing SWE-1.7-HIGH` (fails before) |
| H2 | `session start` (no `-m`) -> `devin --model ''`; `continue` (no `-m`) -> `devin -c --model ""`; the gate had judged the Free default | `_osrc_dv_model_or_default` (lib/spend-paths.sh): no `-m` launches exactly the Free default the gate judges (live-catalog pick, offline swe-2-high) | `default:bare continue`, `default:bare session start` (fail before) |
| H3 | `_osrc_spend_gate dv "" …` passed silently | the gate counts an empty Devin model as unknown (asks) | `default:gate asks …` (fails before) |
| H4 | `--spend-ok session start -m swe-1-7-max`, then `session control relaunch` -> second `devin --model swe-1-7-max` with no consent | `_osrc_session_relaunch_gated` gates the relaunch like a session start (lib/spend-paths.sh) | `relaunch:control relaunch …` (fails before), `relaunch:--spend-ok relaunches exactly swe-1-7-max` |
| H5 | `session effort high` on a codex/cc session relaunched with no gate | `_session_relaunch_effort` moved to lib/spend-paths.sh and goes through the gated relaunch | `relaunch:session effort …` (fails before) |
| H6 | `session model swe-2-1-high` -> the picker received `swe-2-1-high`, no consent | `_osrc_session_model_gate` spend-gates the exact NAME (plus the existing exclude check) | `model:session model swe-2-1-high asks first` (fails before), Free switch still works |
| H7 | bare `session model` pressed Enter in the picker (unknown choice) | same gate with an empty model -> unknown -> asks | `model:bare session model …` (fails before) |

`outsourcerer.sh` shrank 18856 -> 18849 (one function moved out, call sites replaced in place).
`python3 scripts/check_file_size.py --base 2f7d58b` -> `file-size: OK (7 changed file(s) checked, limit 1000)`.

Changed test of the previous lane: `test_devin_launch_gate.sh` asserted `osrc_lane_billing dv SWE-1.7-HIGH`
= subscription (folding). It now asserts metered for the folded spelling and subscription for the exact
uid. This makes the assertion stricter, not weaker.

## Attack cases (brief items 1-9), all asserting on the stub's recorded argv

1. `cost_summary` "Free" / "Sidekick: Free" / "promo: free" with a non-Free `cost_tier`: refused, nothing launched.
2. Spellings: online `SWE-1.7-HIGH`, `swe-1.7-high`, `Swe-1-7-High` launch exactly `swe-1-7-high`; offline spellings refuse and, with consent, launch exactly the spelling judged.
3. `-m swe` (resolves to the paid `swe-2-1-high`) on run, bg, fanout, continue, session start: all refuse; with consent exactly `swe-2-1-high` launches.
4. `swe-1-7-max`, `swe-1-7-xhigh` beside a Free `swe-1-7-high`: paid.
5. `cost_tier` array, object, null, number, missing: paid, no jq/bash error.
6. Cache rows `v1|mt|…`, `mt|…`, `v2|0|…`, `v2|mt+1|…` naming paid ids Free: ignored.
7. No catalog, non-interactive, no `--spend-ok`: glm-5.2, swe-2-max, swe-2, swe-2-1-high refuse; claude with no provable login refuses; offline session start swe-2-max refuses. Nothing launched.
8. `--spend-ok` once: the next command refuses; env vars and forged markers grant nothing; the job's own marker consents once and is consumed.
9. Hops: bound consent does not cover a hop; pickers skip paid Devin; cc -> Devin self-heal refuses; relaunch, effort relaunch and model switch ask.
