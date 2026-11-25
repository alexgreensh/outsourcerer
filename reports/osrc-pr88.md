started

# osrc-pr88: vet and integrate PR #88 (Devin free-model routing, Fusion cost safety)

Model id this lane ran as: `claude-opus-5-5`.
Base: `cloud/osrc-int` @ `45d3e25` (confirmed with `git log --oneline -1`). Work branch: `cloud/osrc-pr88`.
PR head fetched as `pr88` = `94eef9d` (matches the brief's `94eef9de`); its merge base is main `ea34fe0`.

## Step 1: vet (read the whole diff `git diff 45d3e25...pr88` before running anything)

5 files: `references/jobs-and-safety.md`, `lib/spend.sh`, `outsourcerer.sh`,
`tests/test_devin_catalog_free_tier.sh`, `tests/test_spend_consent.sh`.

| Checked for | Found |
|---|---|
| Network calls | None new. Catalog data still comes only through the existing `_catalog_load dv` / `devin models list` path. |
| Writes outside repo / temp homes | Only `$OSRC_HOME/.devin-free-ids` (existing cache, now written atomically via `$cf.tmp.$$` + `mv`, umask 077). Tests write under `mktemp -d`. |
| Hooks, `eval`, `curl \| sh`, encoded strings | None. |
| Consent / approval / safety changes | Only what the PR describes: Free = exact `cost_tier == "Free"` (no `cost_summary` text), no tier-suffix stripping in `_devin_is_free_model`, versioned (`v2`) Free-id cache, and route_delegate gating a Devin-resolved id. All of them make the gates stricter, not weaker. |
| Data sent off the machine | None. |

Verdict: nothing malicious or unexplained. Merged.

## Step 2: integrate

`git merge pr88` had one conflict: `lib/spend.sh` `_devin_catalog_free_ids` cache read. The base side had
only moved a redirect (`IFS='|' read -r cmt cids 2>/dev/null < "$cf"`); the PR side replaced the block
with the v2-keyed cache read (GNU-first `stat`, extractor-version key, mtime 0 never cached). I kept the
PR side, which already covers the base's intent. Everything else auto-merged; the base's spend-gate
rework is intact.

Size ratchet: the merge grew `outsourcerer.sh` 18963 -> 19016 (FAIL). I moved the Devin Free-proof
functions (`_devin_catalog_free_set`, `_devin_first_catalog_free_model`, `_devin_resolve_dynamic`,
`_devin_is_free_model`) unchanged into the new `lib/devin-free.sh`, together with the new launch-id
code. `outsourcerer.sh` is now 18856 lines (-107 against base). `python3 scripts/check_file_size.py --base 45d3e25`
-> `file-size: OK (13 changed file(s) checked, limit 1000)`.

## Step 3: P1 from the Codex review (fixed)

Input: catalog where the older family `swe-1.7` has a Free `swe-1-7-high`, and the newer `swe-2-1` has a
PAID `swe-2-1-high` and a Free `swe-2-1-max`. `outsourcerer run -m swe "..."`, non-interactive, no `--spend-ok`.
On `pr88` the gate resolved `RESOLVED_ID` (alias table: `swe-1.7` -> `swe-1-7-high`, Free) and passed;
`delegate()` re-parsed ORIG and resolved the raw token `swe` -> `swe-2-1-high`, then launched it.
Observed on `pr88` and on the unfixed merge: `devin --model swe-2-1-high ... -p`, rc=0, no consent.

Fix (`lib/devin-free.sh`, 3 lines in `route_delegate`, 2 in `delegate()`):
- `_osrc_dv_launch_prepare` computes the launch id ONCE: the token comes from running the same
  `parse_model` over ORIG in a subshell (so it cannot drift from what `delegate()` reads), resolved by
  `_devin_resolve_model` (a bg pin launches verbatim). It is stored in `_OSRC_DV_LAUNCH_ID`.
- `route_delegate` spend-gates exactly that id; `delegate()` launches it without re-resolving; the
  route receipt (`_osrc_route_launched_model`) prints it. The bg preflight already records the gate's
  `lane|model` pair, so the child's marker and pin match the launched id.
- `route_delegate` clears `_OSRC_DV_LAUNCH_ID` on every pass, so a stale id never rides into another lane.

Test: `tests/test_devin_launch_gate.sh` (new, registered in `conformance.sh`). The P1 cases fail on `pr88`
(launched `swe-2-1-high`, rc=0) and pass now: the run refuses with `EVENT approval ... paid-lane:dv/swe-2-1-high`,
and with `--spend-ok` it launches exactly `swe-2-1-high`.

## Step 4: other holes found (each with input, fix, test that fails before)

1. **Un-routed Devin launch skips the spend gate (cc -> Devin self-heal).** Input: `-m glm --provider cc`
   with every OpenRouter model failing on transport; `delegate_cc` calls `PROVIDER=devin delegate ...`
   directly, so `glm-5.2` (metered on Devin) launched with no consent (the only consent given was for the
   OR lane). Fix: `_osrc_dv_launch_id` in `delegate()`: when route_delegate did not prepare an id, resolve
   now, run the exclude check, then `_osrc_spend_gate dv <that id>`. Test: `self-heal` case (direct
   `delegate auto "" -m glm-5.2`): before = launched, after = spend refusal and no launch.
2. **`continue -m <paid>` had no spend gate.** Input: `outsourcerer continue -m glm-5.2 "..."` </dev/null
   -> `devin -c --model glm-5-2` ran. Fix: `_osrc_spend_gate dv "$MODEL" devin continue` in
   `continue_turn` after resolution and the exclude check. Tests: `continue` cases (metered refused,
   Free `swe-1-7-high` still continues).
3. **Free proof stripped a `vendor/` prefix.** Input: offline catalog (or `OSRC_CATALOG_VALIDATE=0`),
   `-m vendor/swe-2-high`: `_osrc_devin_free_for_spend` judged it as `swe-2-high` (Free) while the
   launcher passes `vendor/swe-2-high` through verbatim. Same with a live catalog for any prefixed id
   (online, catalog validation happens to block the launch). Fix: compare exact ids, folding only case
   and `.`->`-` (the resolver's `keyify`); empty id is never Free. Tests: `exact:` cases (2 fail before).
4. **Probe fallback used the bare `swe-2` family.** Input: glm excluded -> `_devin_probe_pick` returns
   `swe-2`, whose default variant is not proven Free (the catalog fixture has a paid `swe-2-max`).
   Fix: the fallback list names `swe-2-high`. Tests: `probe:` case; `test_factory_exclude.sh` F11
   expectation updated from `swe-2` to `swe-2-high`.

Lanes checked with no hole found:
- cc/OpenRouter, tokenrouter, opencode, gi: billing is lane-level `metered`, so a different model id on
  the same lane cannot turn paid into free; every hop re-enters `route_delegate` and is gated again.
  codex -> cc self-heal stays on the same metered `or` lane.
- codex (cx), claude (cc), gemini (gm): billing comes from login/env evidence, not from the model id.
- Devin `session start` (tmux and winpty): `MODEL` is resolved before `_osrc_session_spend_gate`, so the
  gate already sees the launched id.
- Text deciding "free": after the PR, the only text-based Free reading left is `lib/plan_probe.py`
  `devin_parse` (regex over `devin models` table output). It only feeds the plan overlay's display text
  ("N models come with no per-use charge") and never reaches a launch or a gate. The `*:free` match at
  `resolve_tier` is OpenRouter's structured id suffix and only sets a tier label; that lane always asks.

## Why `test_lane_billing.sh` / `test_limit_gate.sh` were environment-dependent

Billing reads API keys, base URLs, `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, Bedrock/Vertex flags and so on from the
environment. The suites did not clear them, so a developer shell carrying any of them flipped expected
`subscription`/`unknown` to `metered`. Reproduced: with `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, base URLs and
`CODEX_HOME` set, `test_lane_billing` had 59 FAIL and `test_limit_gate` had 3 FAIL. Fix (test-side): both suites
`unset` every billing env var right after `set -uo pipefail`. With the same polluted env both now pass
(143/0 and 127/0).

## Suite results (each run alone, `nice bash <suite>`, after the final code)

| Suite | rc | Result |
|---|---|---|
| test_devin_catalog_free_tier.sh | 0 | 25 passed, 0 failed |
| test_spend_consent.sh | 0 | 46 passed, 0 failed |
| test_lane_billing.sh | 0 | 143 passed, 0 failed (also 0 failed with polluted env) |
| test_limit_gate.sh | 0 | 127 passed, 0 failed (also 0 failed with polluted env) |
| test_advise_dynamic_pool.sh | 0 | 42 passed, 0 failed |
| test_value_router.sh | 0 | 15 passed, 0 failed |
| test_catalog_validation.sh | 0 | 19 passed, 0 failed |
| test_devin_plan_quota_probe.sh | 0 | 53 passed, 0 failed |
| test_devin_launch_gate.sh (new) | 0 | 11 passed, 0 failed (on `pr88` head: 5 failed) |
| test_factory_exclude.sh | 0 | 74 passed, 0 failed |
| test_p56_billing.sh | 0 | 16 passed, 0 failed |
| test_bg_provider_after_verb.sh | 0 | 27 passed, 0 failed |
| test_tests_set_home.sh | 0 | 5 passed, 0 failed |

Full conformance: see `## Conformance` below.

## Open questions (decided by the lane)

- Which token decides the Devin model when `-m` is an alias: the PR's live-catalog resolution of the raw
  token (`swe` -> newest family) or the alias table (`swe` -> `swe-1.7`)? Kept the launch behaviour
  `delegate()` already had (raw token through the catalog) and made the gate follow it. Safety does not
  depend on this choice: whichever id launches is the one gated.
- The doctor / plan-quota probe still sends one `PONG` to `glm-5-2` (plan-included, which the spend gate
  calls metered) without asking. This is the documented health probe and draws the plan bucket, not
  paid ACU. Left as is and listed under unproven.

## Unproven

- Real Devin catalog shapes for Fusion rows and vendor-prefixed ids: tested only with fixtures.
- What the real Devin CLI does with a `vendor/`-prefixed `--model`: the fix makes the gate ask either way.
- The cc -> Devin self-heal was tested by calling `delegate()` directly (the same call the self-heal makes),
  not by forcing a real OpenRouter transport failure.
- The glm health probe above.

## Needs from other lanes

- None required. Suites owned by L7 that I changed, because the brief asked for these fixes:
  `test_lane_billing.sh`, `test_limit_gate.sh` (env scrub) and `test_factory_exclude.sh` (F11 expectation).
