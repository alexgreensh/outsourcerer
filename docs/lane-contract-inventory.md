# Lane-Contract Inventory — outsourcerer.sh

> Read-only audit of `plugins/outsourcerer/skills/outsourcerer/scripts/outsourcerer.sh`
> (16,642 lines, v0.11.1 @ 0ad7182). This is the map the Slice-2 lane-contract refactor
> follows. No file in this doc is proposed for edit here — it is a survey of every place
> lane resolution or lane-specific special-casing currently lives.

## Lane vocabulary (as the code uses it)

Two parallel naming layers exist today, which is itself part of the problem:

- **Provider** (`--provider`): `devin | cc | codex | gemini | droid | cursor | hermes | warp | cline | claudex | local | tokenrouter`
- **Lane code** (internal, resolved): `dv | or | cc | cx | gm | local | droid | cursor | hermes | warp | cline | claudex | tokenrouter`
- **Dispatch vehicle** (`disp`): `devin | ccor | codexor | ccnative | cxnative | gmnative | claudex | droid | cursor | hermes | warp | cline | tokenrouter | local`

A single conceptual lane is therefore referred to by up to three different strings in up
to three different `case` statements (e.g. Claude-subscription = provider `cc` / lane `cc`
/ disp `ccnative`, or via OpenRouter = disp `ccor`). Every table below names the layer the
site keys on.

## A. Lane-resolution functions (the routing core)

| file:line | function | keys on | lanes special-cased | what it special-cases |
|---|---|---|---|---|
| `outsourcerer.sh:1949` | `_effective_lane` | provider + table-lane + model | local; `droid\|cursor\|hermes\|warp\|cline\|claudex\|tokenrouter`; `cc\|codex`; `cx\|cc\|gm\|gi\|ci\|local\|dv`; `devin` | Computes the effective lane mirroring `route_delegate`: local short-circuit; engine lanes where provider IS the lane; implicit-model provider default (`cc\|codex`->`or`, else `dv`); explicit-model fixed lanes ignore `--provider`; provider-routed open-weights follow transport (`cc\|codex`->`or`, `devin`->`dv`). |
| `outsourcerer.sh:10256` | `_so_resolve` | elane + PROVIDER | `local`; `cx`; `cc`; `gm`; `dv`; `or` (split by `cc`/`codex`); `droid\|cursor\|hermes\|warp\|cline\|claudex\|tokenrouter` | Second-opinion route: elane->disp, with the `or` lane split into `ccor`/`codexor` by provider, and a Devin dual-lane model-id reroute via `_devin_model_for`. |
| `outsourcerer.sh:12762` | `route_delegate` | PROVIDER + RESOLVED_LANE + disp | every lane (see §C for the sub-sites) | THE dispatch choke point. Resolves alias->id, picks `disp`, runs the quota/denylist/cloud gates, auto-detaches, then dispatches. Contains ~6 separate per-lane `case` blocks (itemized in §C). |
| `outsourcerer.sh:12566` | `_fallback_disp_lane` | disp | `devin`; `cxnative`; `ccnative`; `gmnative`; `ccor\|codexor` | Maps a dispatch vehicle back to the lane code it actually ran on, for fallback dedupe. |
| `outsourcerer.sh:12577` | `_fallback_provider_for_lane` | lane | `dv`; `cc\|or`; `cx`; `gm`; `droid\|cursor\|hermes\|warp\|cline\|tokenrouter` | Reverse map lane->provider, used to rebuild argv on a fallback hop. Returns nonzero for unknown. |
| `outsourcerer.sh:12587` | `_fallback_effective` | lane + PROVIDER | `or` under `devin` | Under the devin provider, reroutes an OpenRouter alias with a Devin sibling onto the Devin lane so dedupe compares the real `model@dv`, not a no-op `@or` hop. |

## B. Per-lane attribute tables (the scattered case statements)

These are the "if you add a lane, edit N places" tables. Each is a `case` keyed on a lane
string with hardcoded per-lane behavior. Today there are **nine** such tables; the contract
collapses them into one descriptor.

| file:line | function | keys on | what each branch assigns |
|---|---|---|---|
| `outsourcerer.sh:2461` | `_lane_cost_disclosure` | lane/disp | User-visible cost-class string per lane (local/cx/cc/gm/dv/cursor/or/gemini/hermes/droid/warp/cline/tokenrouter). 13 branches + fallback. |
| `outsourcerer.sh:2571` | `_quota_lane_key` | disp/provider/code | Quota-pool key per lane (`dv`/`or`/`cc`/`cx`/`gm`/`local`/engine-name). Folds `ccor`+`codexor`+`or` into one `or` pool; folds `gi` into `gm`. |
| `outsourcerer.sh:11618` | `_is_cloud_lane` | disp | Boolean: ships data off-machine? `ccor\|codexor\|ccnative\|cxnative\|gmnative\|devin\|droid\|cursor\|hermes\|warp\|cline\|claudex\|tokenrouter` -> cloud; else local. |
| `outsourcerer.sh:12670` | `_route_resolution` | disp | `ROUTE_COST_CLASS`: `local`/`limited`/`credits`. `ccnative\|cxnative\|gmnative\|devin\|droid\|cursor\|hermes\|warp\|cline` -> limited; `ccor\|codexor\|claudex\|tokenrouter` -> credits. |
| `outsourcerer.sh:12726` | `_route_provider_default_model` | provider | Default model when no `-m`: `devin`->DEFAULT_MODEL, `gemini\|gm`->gemini-flash-lite, `local`->local, `cc\|codex`->z-ai/glm-5.2, `claudex`->gpt-5.6-sol, `droid\|cursor\|hermes\|warp\|cline`->`<lane>-default`. |
| `outsourcerer.sh:1099` | `_catalog_path` | lane | Catalog whitelist: only `dv\|warp\|gm\|gi` have a live catalog file. Literal set (path-traversal guard). |
| `outsourcerer.sh:12700` | `_route_confirm` | ROUTE_COST_CLASS | Confirmation copy per cost class (local/credits/limited). Derived class, not raw lane, but the class itself is lane-derived from §B `_route_resolution`. |
| `outsourcerer.sh:7040` | (inline, `cmd_advise`) | lane | Advise scoring labels + price zeroing: `cc`->"cc/Claude 5h", `cx`->"cx/Codex"; `cx\|cc\|dv\|gm` price set to 0 (plan-limited) and `cost_per_m`->"plan limits". |
| `outsourcerer.sh:6063` | (inline, `cmd_brief`) | lane | Hardcoded `echo` lines naming Codex/Claude/Antigravity with `_lane_cost_disclosure` per lane. |

## C. The `route_delegate` choke point — per-lane sub-sites

`route_delegate` (`outsourcerer.sh:12762-13126`) is the single function that turns a
resolved model+provider into a dispatch. It contains six distinct per-lane `case` blocks
that the contract must consolidate:

| file:line | sub-site | lanes | what it special-cases |
|---|---|---|---|
| `outsourcerer.sh:12839` | local short-circuit | local | `local:*\|*:ollama:*\|*:lmstudio:*\|*:lms:*\|*:local` -> `delegate_local` before alias resolution. |
| `outsourcerer.sh:12852` | engine-lane alias skip | `droid\|cursor\|hermes\|warp\|cline\|tokenrouter` | These skip `resolve_model_row` entirely: the engine owns its catalog, so `-m glm` under `--provider droid` is droid's glm, not the alias table's. |
| `outsourcerer.sh:12878` | engine-lane CLI gate | `droid\|cursor\|hermes\|warp\|cline\|tokenrouter` | Fail-fast `have <cli>` / `_tr_load_key` per lane, with per-lane install hints, before the cloud gate and before auto-detach. |
| `outsourcerer.sh:12894` | claudex branch | claudex | Refuses Claude-sub models (`RESOLVED_LANE==cc`), defaults to `gpt-5.6-sol`, probes `_claudex_up`. |
| `outsourcerer.sh:12909` | explicit-model dispatch | `cx\|cc\|gm\|gi\|ci\|dv\|or` | `cx`+provider cc -> die; `cc`+provider codex -> die; `gm`->gmnative; `gi`/`ci`->die (image); `dv`->devin; `or` split by provider with Devin dual-lane reroute (`_devin_model_for`) and auto-route-to-cc fallback. |
| `outsourcerer.sh:12975` | implicit-model dispatch | `devin\|cc\|codex\|gemini\|gm` | No `-m`: `devin`->devin, `cc`->ccor, `codex`->codexor, `gemini\|gm`->gmnative. |
| `outsourcerer.sh:13035` | OpenRouter zero-credit gate | `ccor\|codexor` | `or_credits` -> die on numeric zero balance before dispatch. |
| `outsourcerer.sh:13049` | Devin swe-1.7 write warning | devin | Warns that swe-1.7 is unreliable for `edit\|yolo\|research` verbs. |
| `outsourcerer.sh:13103` | final dispatch `case` | every disp | `devin` (with autonomous/sandbox special-case), then `ccor\|codexor\|cxnative\|ccnative\|gmnative\|droid\|cursor\|hermes\|warp\|cline\|tokenrouter\|claudex` -> `delegate_<lane>`. |

## D. `delegate_<lane>()` functions — per-lane dispatch implementations

Each delegate carries its own copy of: CLI presence check, tier->autonomy-flag mapping,
model-id resolution, effort handling, tier banner, cost disclosure, and ledger recording.
This is the bulk of the duplication the contract targets.

| file:line | function | lane | per-lane logic it owns |
|---|---|---|---|
| `outsourcerer.sh:1602` | `delegate` | devin (dv) | `need_devin`; `_devin_resolve_model`; `_catalog_validate dv`; free-tier detection; `--sandbox` for autonomous; quota-refusal classification; ledger `dv`. |
| `outsourcerer.sh:10417` | `delegate_cxnative` | codex-native (cx) | codex CLI; tier->`-c` flags; model-id; ledger `cx`. |
| `outsourcerer.sh:10526` | `delegate_ccnative` | claude-native (cc) | claude CLI; tier->permission-mode; model-id; ledger `cc`. |
| `outsourcerer.sh:10734` | `delegate_gmnative` | gemini-native (gm) | `agy` CLI; two vehicles (text/image); `_agy_effort`; `_gemini_api_id`; ledger `gm`/`gi`. |
| `outsourcerer.sh:10874` | `delegate_claudex` | claudex | claude CLI + `_claudex_up`; tier->mode; `gpt-5.6-sol` default; ledger `claudex`. |
| `outsourcerer.sh:10943` | `delegate_droid` | droid | `have droid`; tier->`--auto low/medium/high`; `_lane_model_for droid`; `_droid_effort`; ledger `droid`. |
| `outsourcerer.sh:10976` | `delegate_cursor` | cursor | `cursor-agent`/`agent` detect; tier->`--force`/`--sandbox`; ledger `cursor`. |
| `outsourcerer.sh:11012` | `delegate_hermes` | hermes | `have hermes`; tier->`--yolo`; `hermes -z`; worktree flag; ledger `hermes`. |
| `outsourcerer.sh:11064` | `delegate_warp` | warp | `have oz`; profile (`OSRC_WARP_PROFILE`); harness (`OSRC_WARP_HARNESS`); `_lane_model_for warp`; `_catalog_validate warp`; ledger `warp`. |
| `outsourcerer.sh:11178` | `delegate_cline` | cline | `have cline`; tier->`--auto-approve`; ledger `cline`. |
| `outsourcerer.sh:11810` | `delegate_cc` | cc->OpenRouter (ccor) | OpenRouter transport via Claude Code; cross-lane self-heal -> devin; ledger `or`. |
| `outsourcerer.sh:11997` | `delegate_local` | local | `_local_resolve`; direct `/v1/chat/completions`; no cloud gate; ledger `local`. |
| `outsourcerer.sh:12161` | `delegate_tokenrouter` | tokenrouter | `_tr_load_key`; `_tr_base_url`; direct streaming; ledger `tokenrouter`. |
| `outsourcerer.sh:12356` | `delegate_codex` | codex->OpenRouter (codexor) | OpenRouter transport via Codex Responses API; cross-lane self-heal -> cc; ledger `or`. |

## E. Per-lane model-id resolution

| file:line | function | lanes | what it special-cases |
|---|---|---|---|
| `outsourcerer.sh:846` | `_devin_model_for` | devin/dv (+droid/warp for kimi) | Alias->Devin id: glm->glm-5.2, swe/swe-2/swe-1.7->swe-2-flash-high, deepseek->deepseek-v4-pro-<effort>, kimi->kimi-k3. |
| `outsourcerer.sh:1026` | `_devin_resolve_model` | devin | Full Devin resolution: live catalog -> sibling -> alias table -> passthrough. |
| `outsourcerer.sh:1051` | `_lane_model_for` | devin/dv/droid/warp | Cross-lane alias: kimi special-case for devin/dv/droid/warp; devin/dv -> `_devin_resolve_model`; else passthrough. |
| `outsourcerer.sh:10683` | `_gemini_api_id` | gm/gi | Gemini id by family (pro/flash/flash-lite/flash-image) with pin/env/live/lastknown fallback. |
| `outsourcerer.sh:10938` | `_droid_effort` | droid | Effort ladder -> droid `none/low/medium/high`. |
| `outsourcerer.sh:1903` | `lane_from_name` | cc/cx/gm | Infers native lane from model family name (claude->cc, gpt->cx, gemini->gm) for un-tabled explicit ids. |
| `outsourcerer.sh:1879` | `resolve_model_row` | (table) | Alias-table lookup: alias -> `id\|lane\|tier`. Lane-agnostic but the table's lane column feeds every resolver. |

## F. Per-lane liveness / readiness probes

| file:line | function | lanes | what it special-cases |
|---|---|---|---|
| `outsourcerer.sh:6074` | `_ready_lanes` | every lane | Bespoke readiness per lane: local=`_local_detect`, devin=`devin auth status`+live list, gemini=`have agy`, codex=`have codex`, openrouter=`OPENROUTER_API_KEY`+`or_credits`, claude=`have claude`, droid=`have droid`, cursor=`have cursor-agent`, cline=`have cline`, tokenrouter=`TOKENROUTER_API_KEY`, claudex=`_claudex_up`. |
| `outsourcerer.sh:11951` | `_local_detect` | local | Probes ollama/lmstudio/llama.cpp endpoints. |
| `outsourcerer.sh:10864` | `_claudex_up` | claudex | curl `/v1/models` with claudex token. |
| `outsourcerer.sh:10857` | `_claudex_url` / `_claudex_token` | claudex | Endpoint + creds resolution. |
| `outsourcerer.sh:1771` | `_tr_load_key` | tokenrouter | Key resolution (the dispatchability gate). |
| `outsourcerer.sh:12159` | `_tr_base_url` | tokenrouter | Endpoint resolution. |
| `outsourcerer.sh:1345` | `_catalog_validate` | dv/warp (+gm/gi) | Live-catalog pre-dispatch gate; only called for lanes with a `_catalog_path`. |

## G. Per-lane cloud-gate / trust / disclosure

| file:line | function | lanes | what it special-cases |
|---|---|---|---|
| `outsourcerer.sh:11754` | `_cloud_disclose` | every cloud lane | Single cloud-gate choke point; calls `_is_cloud_lane`, `_secret_scan`, `_lane_trusted_for_pwd`. |
| `outsourcerer.sh:11639` | `_lane_trusted_for_pwd` | per-lane config | Per-lane/repo trust for the credential-file hard-block (`trusted-lanes.json`). |
| `outsourcerer.sh:11618` | `_is_cloud_lane` | (see §B) | Cloud classification. |

## H. Per-lane session observation (interactive `session` verb)

| file:line | function | lanes | what it special-cases |
|---|---|---|---|
| `outsourcerer.sh:14432` | `_session_model_observe` | `devin\|dv`, `codex\|cx`, `cc\|claude`, `droid`, `cursor`, `hermes`, `gemini\|gm` | Dispatches to per-lane `_session_model_observe_<lane>` to read the live model off the session. |
| `outsourcerer.sh:14443` | `_session_model_receipt` | `devin\|dv` only | Per-lane receipt verification (only Devin wired today). |

## I. Per-lane image backend dispatch

| file:line | function | lanes | what it special-cases |
|---|---|---|---|
| `outsourcerer.sh:11380` | (inline, `cmd_image`) | codex/gemini/openrouter | Backend selection by model family -> `_idisp` (`cxnative`/`gmnative`/`codexor`) -> `cmd_image_<backend>`. |
| `outsourcerer.sh:11399` | (inline) | codex/gemini/openrouter | `case "$backend"` -> disp code for `_cloud_disclose`. |

## J. Per-lane conservation / advise

| file:line | function | lanes | what it special-cases |
|---|---|---|---|
| `outsourcerer.sh:6107` | `_conserve_reco` | (limits + lanes) | Priority ordering local > Devin > keyless Gemini > Codex > OpenRouter; per-lane conserve-line scoring. |
| `outsourcerer.sh:7040` | (inline, `cmd_advise`) | `cc\|cx\|dv\|gm` | Subscription-lane price zeroing + label overrides in advise scoring. |

## Summary count

- **Lane-resolution functions:** 6 (§A)
- **Per-lane attribute tables (scattered `case`):** 9 (§B)
- **`route_delegate` per-lane sub-sites:** 9 (§C)
- **`delegate_<lane>` implementations:** 14 (§D)
- **Per-lane model-id resolvers:** 7 (§E)
- **Per-lane liveness/readiness probes:** 7 (§F)
- **Per-lane cloud/trust/disclosure:** 3 (§G)
- **Per-lane session observers:** 2 (§H)
- **Per-lane image dispatch:** 2 (§I)
- **Per-lane conserve/advise:** 2 (§J)

**Total distinct sites carrying lane-specific special-casing: ~61**, spread across the
single 16,642-line file. Adding a lane today means editing at minimum: `_effective_lane`,
`_so_resolve`, `_lane_cost_disclosure`, `_quota_lane_key`, `_is_cloud_lane`,
`_route_resolution`, `_route_provider_default_model`, `_fallback_disp_lane`,
`_fallback_provider_for_lane`, `_ready_lanes`, the `route_delegate` dispatch `case`, and a
new `delegate_<lane>` function, plus the image/session/advise tables if the lane
participates in those verbs. That is the duplication the lane-contract descriptor (see
`docs/lane-contract-design.md`) is designed to collapse into one place per lane.

### Note on `_lane_disp`

The task brief references a `_lane_disp` symbol (~line 12578) and `_lane_down_mark` /
`_lane_down_active` markers. As of this base (`0ad7182`, v0.11.1), **`_lane_disp` does not
exist in the file** (grep returns no matches). The down-markers are Slice-1 work landing
in parallel. The contract design doc therefore reserves a `lane_health` slot so the
Slice-1 lane-down state and a future `_lane_disp` helper have a single home when both
slices converge.
