# osrc-int-fix-a: Mission Control and limits fixup

Base `a492df7` (`cloud/osrc-int`). Branch `cloud/osrc-int-fix-a`.

## Fixed (each regression test fails on the base, passes now)
- **l9 P2-1** `hub-home.js`: both `isFinite(x.n)` filters add `&& !x.l.stale`. Test: `test_hub_home.sh` (page-contract grep, 2 matches).
- **l9 P3-2**: check 14 now asserts the state (`out|4% left, LOW...`) instead of a wildcard. It proves the expanded panel only; a hidden row is not headroom. No code change.
- **l9 P3-3** `plan-probe.sh`: stale suffix is ` old`, not ` (old)`. Check 15 gets a stale row (`test_limits_staleness.sh`).
- **l9 P3-4** `limits.sh`: with no owner session, a newly low window prints the LIMIT LOW line but sends no event and keeps no mark. Check 16.
- **l9 P3-5** `plan-overlay.jq`: "Live check failed" only when the probe is not ok; otherwise "The Codex session log is newer than the live check". Check 17.
- **l8 P3-1** `hub.html` gates `A.refresh` on `!firstPull`; the Tracker's empty-board guard in `hub-attn.js` is deleted. `hub_attn_dom.js` A3/A4 cases.
- **l8 P3-2** `summaryAt` grep added in `test_hub_home.sh`.
- **l8 P3-3** `attn_order` and its test deleted.
- **l8 P3-4** wording trimmed in `hub-truth.sh` and `references/hub.md`.
- **l8 P3-6** `hub-truth.sh`: takeover also sweeps `flight/<key>.json.*` older than 60 min (a reused-pid leader's temp file). Test in `test_hub_truth.sh`.

## Skipped
- l9 P3-6 (attribution against `ea34fe0`): not in my files; needs a run of six suites on `ea34fe0` (see below).
- l8 P3-5 (RESULT naming base) is an old-round artifact. l8 P3-7: see conformance.
- Already fixed elsewhere per the brief: board percent rule, verify-clone sweep.

## Tests (niced, one at a time)
- test_hub_home 92/0, test_hub_attn 41/0, test_hub_truth 29/0, test_limits_staleness 31/0, `node tests/hub_attn_dom.js lib/hub-assets` 36/0, all exit 0.
- With `lib/` reverted to base, the new assertions fail (7 FAILs seen).
- `tests/conformance.sh`: timed out at my 580 s cap (exit 124) before finishing; 3 suites failed before that: test_harness_isolation, test_vocab_hygiene, test_supervise_pgroup_kill. The first two fail identically with my changes stashed (base). The third was not re-run on base. RESULT is therefore `rc=1`.

## Unproven
- Full conformance never completed here.

## Needs from other lanes
- Someone with time should run conformance in a dedicated lane, and the six red suites on `ea34fe0` (l9 P3-6).
- test_vocab_hygiene, test_harness_isolation, test_supervise_pgroup_kill are outside my files.
