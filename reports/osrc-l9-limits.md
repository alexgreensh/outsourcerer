# osrc-l9-limits: limit readings that are never silently stale

Base branch had no earlier work past `ea34fe0` (no commits, no reports), so this is a first pass.

## Root cause
`plan-overlay.jq` took the cached `codex app-server` probe whenever it said `ok`, whatever its age, and never compared it
with the newer session-log reading. The probe is only refreshed when the log is old, so a fresh log kept the stale probe on top.
A failed probe also overwrote the last good value with `{"ok":false}`.

## Changes (scripts/lib)
- `plan-overlay.jq`: newest reading wins (probe replaces the log row only if not older). Every measured row gets
  `checked_at`, `age_s`; past `OSRC_LIMITS_STALE_SECS` (now default 2 h) it gets `stale:true`, `left` reads
  "4% left · checked 3 h ago", and ok/low become `unknown` (an exhausted reading stays `out`). At or under
  `OSRC_LIMIT_LOW_PCT` (default 10) left it gets `low:true` and "LOW: stop routing here".
- `limits.sh`: per-window `age_s` in the summary JSON; `_osrc_limits_low_scan` (called from `_conserve_reco`, so `brief`
  prints `LIMIT LOW: ...` every time) emits one `limit-low` supervise event per crossing, state in `$OSRC_HOME/limits-low-seen`.
  Routing staleness default lowered 6 h -> 2 h (`_osrc_lane_limit_stale`, brief summary), matching the display.
- `plan-probe.sh`: a failed probe keeps the old value and original `checked` time and adds `refresh_failed`; retry after the
  failed-answer interval. `OSRC_HUB_CHECK_PLANS=1` (the page's refresh) forces a re-probe even when the cache is fresh.
  Probes remain model-free and bounded by existing TTLs (codex 300 s).
- `hub-perf.sh`: unchanged; the existing 60 s limits-cache refresh already reruns the overlay.

## Tests
- New `tests/test_limits_staleness.sh` (12 checks, registered in `conformance.sh`): incident (3 h old probe 28% vs fresh log 4%),
  newer probe wins, stale age text and unknown state, stale exhausted stays out, failed probe keeps value, low alert once per crossing.
  Fails before the fix (8 failures), passes after.
- `test_limit_gate.sh` adjusted: the "still gates" case moved from codexage 10000 to 5000 (stale line now 2 h).
- `test_plan_probe.sh` 38/38, `test_hub_plan_refresh.sh` 2/2, `test_limits_freshness.sh` 10/10, `test_limit_gate.sh` 124/124.
- `conformance.sh` (full run, killed before its final summary after ~170 suites; no rc): all suites touching limits passed
  (test_limits_staleness, test_limits_freshness, test_limit_gate, test_copilot, test_plan_probe). Failures seen:
  test_harness_isolation, test_vocab_hygiene, test_parity_insource_refresh (fail identically on the untouched base; running as
  root makes read-only-file checks pass wrongly), test_supervise_pgroup_kill and test_conformance_suite_timeout (not checked
  against base; unrelated to limits files). Also `_conserve_reco` was split so the LIMIT LOW line prints after the reco line.

## Unproven
- Real `codex app-server` and a live page were not exercised; probes are tested with cached files and stubs.
- The page shows the new `left` text, but a dedicated stale/low badge needs the page JS.

## Needs from other lanes
- `lib/advise-score.sh:451` still defaults `OSRC_LIMITS_STALE_SECS` to 21600; change it to 7200 so advise agrees.
- `lib/hub-assets/hub-plans.js`: optionally style rows with `stale` / `low` and show `age_s`.
- `lib/lanemsg.sh` brief: nothing required (the low line arrives through `_conserve_reco`); supervise may want to list the `limit-low` kind.

## Round 2

Fixes for the three P1 and every P2/P3 finding of the round-1 review. Paths under `plugins/outsourcerer/skills/outsourcerer/scripts/`.

- **P1-1** `lib/limits.sh`: `_osrc_summary_json` now writes `age_s` into each window (`wa3` was read and dropped), so the overlay can compare the probe's age with the session log's.
- **P1-2** `tests/test_limits_staleness.sh` now builds rows with the real `_osrc_lane_summary_base --json | _osrc_plan_overlay` path. Only `_osrc_meter_windows` and harness detection are stubbed. 10 checks fail on the base `17d5752` and all 19 pass now.
- **P1-3** `lib/plan-overlay.jq`: the codex session-log fallback is stamped with the log's own age (`row_age`), not the probe's failure time, so the stale block applies.
- **P2-4** The launch gate default is back to 6 h (`_osrc_lane_limit_stale`), which matches advise and the warning text. The 2 h default is for page display only. Comments updated.
- **P2-5** keep-last-good now applies to `codex` and `agy` only. A kept reading whose refresh failed is shown stale, with the reason and state `unknown`, in the overlay. Devin and droid report a failure again.
- **P2-6** the `low` flag depends only on `.used`, not on `checked_at`.
- **P2-7** the low-scan seen-file keeps windows that have no token in this call. Only a present reading back over the line clears one.
- **P3-8** the low scan compares `codexage` against `OSRC_LIMITS_STALE_SECS`. **P3-9** removed the redundant `OSRC_HUB_CHECK_PLANS` edits in `plan-probe.sh` (the `_osrc_probe_wanted` one stays). **P3-10** the overlay uses `$stale` and `$ll` directly.
- **P3-11** see Tests below.

### Tests
- `nice bash tests/test_limits_staleness.sh`: rc=0, 19 passed. On base lib files (stash of `lib/`): 10 FAIL.
- `nice timeout 590 bash tests/conformance.sh`: rc=124 (my timeout cut it before its summary; 157 PASS lines). Three suites FAILED: `test_vocab_hygiene` and `test_harness_isolation` fail identically with my `lib/` and `tests/` changes stashed, so they are not caused by this round (likely running as root here). `test_supervise_pgroup_kill` was not compared against base. Conformance therefore did not finish green and I make no claim it did.

### Unproven
- Live codex/agy probes were not run against real CLIs here.
- The two suites that failed in round 1 were not compared against base.

## Needs from other lanes
None.

## Round 3

Closing edits for the round-2 review. Paths under `plugins/outsourcerer/skills/outsourcerer/scripts/`. Base confirmed: `cab325f`.

- **P2-1** `lib/plan-overlay.jq` `codex_fix`: the kept probe is used only when `probe_newer`. A stale log row now falls to the log branch, so a 3 h old 100% log beats a 2-day-old kept 20% probe and stays `out`. Test 11.
- **P2-2** `tests/test_limit_gate.sh` restored to its pre-lane state (no diff; the `codexage=10000` check again proves the 6 h gate). `test_limits_staleness.sh` check 10 now calls `_osrc_lane_limit_stale cx`. Checked by hand: with `OSRC_LIMITS_STALE_SECS=7200` the `cx codexage=10000` call returns stale (the guard would fail), with the default it does not. I started a full-suite run of `test_limit_gate.sh` with the gate set to 2 h, but its output was lost; I did not see that suite fail under the mutation.
- **P3-3** `lib/plan-overlay.jq` `refresh_flag`: a kept reading after a failed refresh is marked `stale` and downgraded only when older than its probe TTL (`lib/plan-probe.sh` adds `ttl` to the cached object). The note still says the refresh failed. Test 12; test 8 now uses a 1000 s old probe.
- **P3-4** Documented, not changed: a seen mark can outlive a window reset (comment in `lib/limits.sh`). The limits line carries no `renews_at`, so a fix would need a wider change.
- **P3-5** RESULT `rc` comes only from a real run: conformance again ended `rc=124` (900 s timeout), so RESULT says `rc=124`.
- **P3-6** Removed `ov()` and every `| ov`; the `_conserve_reco` comment now says it also appends `LIMIT LOW` lines; `references/jobs-and-safety.md` documents `OSRC_LIMIT_LOW_PCT`, the 2 h page default and that `OSRC_LIMITS_STALE_SECS` moves both.
- Also fixed: two `test_plan_probe.sh` overlay unit calls lacked `--argjson stale/ll` since round 2 (failed on base too); 38/38 now.

### Tests
- `nice bash tests/test_limits_staleness.sh`: 21 passed, 0 failed (rc=0). On base lib code: 2 failed (checks 11 and 12).
- `nice bash tests/test_limit_gate.sh`: 124 passed, 0 failed.
- `nice bash tests/test_plan_probe.sh`: 38 passed (36 + 2 fixed).
- `nice timeout 900 bash tests/conformance.sh`: rc=124 (timeout). Failing suites seen before the cutoff: test_harness_isolation, test_vocab_hygiene, test_supervise_pgroup_kill, test_parity_insource_refresh, test_conformance_suite_timeout. I did not compare these with base (this sandbox is root/slow); none touch limits files.

### Unproven
Conformance never completed. The five failures above are unattributed.

## Needs from other lanes
- Unchanged from round 1/2.

## Round 4

Closing round for the round-3 review. Paths are under `plugins/outsourcerer/skills/outsourcerer/scripts/`. Base confirmed with `git log --oneline -3`: `50b5c16`. Code commit: `67e4c87`.

What the user now sees: the ChatGPT row on Mission Control reads `60% left, checked 3 h ago` with state "No reading" for a 3 h old reading, and `4% left, LOW: stop routing here` at 4% left. Before this round the page cut both to `60% left` and `4% left`.

- **P1-1** `tests/test_hub_plan_refresh.sh` passes `--argjson stale 7200 --argjson ll 10` to the overlay. On base it failed with rc=4 (jq compile errors). Now 2/2.
- **P2-2** `lib/limits.sh`: the `limit-low` event carries `$(_owner_sid)` as its owner. New check 13 uses the real `_osrc_lane_event` and `_sv_read_range` with `CLAUDE_CODE_SESSION_ID` set, and confirms that owner's waiter gets the row.
- **P2-3** `lib/plan-overlay.jq` `refresh_flag`: a kept probe whose refresh failed is stale only after a fixed 15 min (900 s). The `ttl` plumbing in `lib/plan-probe.sh` is deleted. Check 12 now goes through `_osrc_probe_kick` on the page-refresh path (`OSRC_HUB_CHECK_PLANS=1 OSRC_PROBE_SYNC=1 OSRC_PROBE_TTL_CODEX=0`): a 400 s old reading stays usable and a 1000 s old one is stale.
- **P2-4** `lib/plan-overlay.jq`: a session-log reading uses `checked($now - row_age)`, so `updated` (the page's "Checked" stamp) is the reading's own time. Check 3 asserts it.
- **P2-5** The age and LOW suffixes are joined with `, ` so the page row (`hub.html` keeps the text before the first ` · `) shows them. New check 14 exports rows with the real `_osrc_hub_limits` from a fixture meter state and renders them with `hub.html`'s own `renderLimits` in `tests/hub_limits_row.js` (node vm, minimal fake DOM). It skips if node is missing.
- **P3-6** Check 10b sets `OSRC_LIMITS_STALE_SECS=7200` and expects no LOW line for a 3 h old reading.
- **P3-7** `_osrc_summary_text_json` prints LEFT as the part before `, ` plus ` LOW` or ` (old)`. New check 15 checks the column positions.
- **P3-8** RESULT: the contract asks for `sha=<pinned base>` on line 1, and this brief asks for my own head. Line 1 keeps the contract format and line 3 is `head=<my code commit>`. The READY/RESULT commit cannot name itself.

### Tests (all run in this sandbox, niced)
- `bash tests/test_limits_staleness.sh`: rc=0, 28 passed, 0 failed. With `lib/` stashed (base code, new tests): rc=1, 7 failed (age text, updated stamp, young kept probe, limit-low owner, both page-row checks, summary column).
- `bash tests/test_hub_plan_refresh.sh`: rc=0. The base version of the test on base code: rc=4.
- `test_plan_probe` 38/38, `test_limits_freshness` 10/10, `test_limit_gate` 124/124, `test_hub` 139/139, `test_hub_home` 90/90. All rc=0.
- `OSRC_CONFORMANCE_VERBOSE=1 bash tests/conformance.sh`, with no timeout, ran to completion this time.
  - **Head:** rc=1, 242 passed, 6 failed, 1 skipped. The failing suites were test_harness_isolation, test_parity_insource_refresh, test_release_0175, test_sealed_fixes, test_supervise_pgroup_kill and test_vocab_hygiene.
  - **Base** (`50b5c16` worktree): rc=1, 239 passed, 9 failed. The same six suites failed, plus test_hub_plan_refresh (P1, now fixed), test_conformance_suite_timeout and test_sandbox_final.
  - **Attribution:** all six head failures are pre-existing. I compared the failure lines for release_0175, vocab_hygiene, sealed_fixes and harness_isolation, and they are identical on base and head. They involve hub process handling, read-only write checks as root, and MCP isolation, and none touch limits files. None of the failures are mine.

### Unproven
- I did not probe the live codex or agy CLIs.
- The page-row test runs `renderLimits` against a fake DOM, not a browser.

## Needs from other lanes
- The six pre-existing conformance failures above belong to their owning lanes. They look like artifacts of running as root in this sandbox, but I did not prove that.
