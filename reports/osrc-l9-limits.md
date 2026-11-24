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
