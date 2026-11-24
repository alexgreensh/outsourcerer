# osrc-l7-remote: honest cloud and remote-lane status

Base held no earlier work in my files (the WIP commit touched stopguard/supervise/watchsvc only).

## What changed
- `lib/remote.sh`
  1. gh answers HTTP 422 ("No commit found") for a branch not pushed yet; it was classified `net`, so five polls raised `EVENT failed`. 404/422 now mean "missing" = starting. A lane that never pushes within `OSRC_REMOTE_NEVER_START` minutes (default 45) emits one `EVENT failed ... never started`, with the vehicle name, session ref and last launch-log line. Real network errors still count and surface.
  4. `lane ls` now takes its state from `_osrc_lane_status` (evidence: head, last push, lane age, branch deletion): `starting`, `live`, `stale` (no push for `OSRC_REMOTE_STALL`, or never pushed past the never-start timeout), plus a NOTE column. `osrc_remote_state` (the cache contract) is unchanged. `cloud ls` uses the same status.
- `lib/cloudrun.sh`
  2. Launch is "started" only with a printed session URL/id. No link (even if the launcher is still alive) means the launcher is torn down, the vehicle output is shown, nothing is registered.
  3. `_cloudrun_classify_failure`: out_of_quota / quota, billing (402), rate limit are named as such with the next step (other vehicle, or local), not as a refusal.
  5. The claude pane log is checked for the folder-trust screen; the launch fails fast with "trust the folder once or launch from a trusted checkout". Trust is never accepted for the user and the pane is killed.
- Docs line in `references/remote-and-review.md`; suite `tests/test_lane_status.sh` registered in `conformance.sh`; cases added to `tests/test_cloudrun.sh`.

## Tests
- `bash tests/test_cloudrun.sh`: 121 passed, rc=0 (7 new cases fail on the old code, verified by stashing).
- `bash tests/test_lane_status.sh`: 10 passed, rc=0 (6 fail on the old remote.sh).
- `bash tests/test_remote_review.sh`: 106 passed, rc=0.
- `bash tests/conformance.sh`: rc=1, `238 passed, 11 failed`. My `test_no_pipe_grep_q` failure (4 piped `grep -q` in my new tests) was fixed and re-run green (rc=0). The other 10 failures are in suites for files I do not own or touch: test_harness_isolation, test_vocab_hygiene, test_supervise, test_watchsvc, test_supervise_lifecycle, test_supervise_pgroup_kill, test_stop_guard, test_parity_insource_refresh, test_conformance_suite_timeout, test_sealed_fixes. Not investigated, not verified against a clean base; most are supervise/watchsvc/stopguard (the WIP commit on this base). I did not re-run the full conformance after the grep fix.

## Unproven
- The literal string "Agent refused the request" is not in this repo; it comes from outside my files (likely the delegate path). The cloud launch path is fixed; local-delegate paths need the same classifier.
- Trust-screen text matched from a stub, not a live Claude Code capture; "session ended" evidence is inferred (no vehicle status API is polled).

## Needs from other lanes
- supervise/outsourcerer.sh owner: reuse `_cloudrun_classify_failure` (or the regex) where "Agent refused the request" is produced so quota/billing/rate-limit are not labelled refusals.
- Branch note: work is on `claude/osrc-l7-remote-bugs-basei3` (the environment's pushable branch), not `cloud/osrc-l7-remote`.
