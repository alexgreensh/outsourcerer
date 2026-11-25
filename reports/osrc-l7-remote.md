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

## Round 2 (osrc-l7-remote-r2)

Fixes for the review of `2235be9` plus three bugs seen live. Files: `lib/cloudrun.sh`, `lib/remote.sh`, `lib/cleanup.sh` (one function), tests in `test_cloudrun.sh` and `test_lane_status.sh`. Every new assertion fails on the old libs (verified by stashing the three lib files: 5 and 4 failures) and passes now.

- **P1** The nohup launch ran the vehicle inside a wrapper subshell, so `kill $pid` orphaned the CLI. The wrapper now records the vehicle's own pid (`cpid`) and a failed launch kills it too. Test: the stub's pid is gone after a no-link launch.
- **P2-2** The stall block no longer fires for a lane that never pushed (gated on a head, unless never-start is disabled). Test steps to +91.
- **P2-3** The failure message prints the session ref when one was seen, says a session may still exist (check the vehicle dashboard), and names `OSRC_CLOUD_LAUNCH_WAIT`.
- **P2-4** Removed the three leaked `.signal-test-*` / `.tick-cli-*` directories.
- **P3-5** One `_osrc_lane_last_move` (last push or last review verdict) is used by `lane ls` and `lane events`.
- **P3-6** The classifier and trust detection read only the last 20 non-empty log lines.
- **Live 1** When `cloud/<id>` is absent, the poll looks for `claude/<id>-*` (remote first, then the name in the launch log), follows it and records `poll_branch`; READY there counts. `cleanup` (dry run) now prints an OFFER line with the `git push --delete` command for `cloud/<id>` and the session branch. It never deletes remote branches itself.
- **Live 2** `cloud start` refuses when checkout HEAD is not the remote tip of `--base` (skipped when `--sha` pins a commit, which has its own checks).
- **Live 3** Private-path check: a `~/`, `$HOME/` or `/home|/Users/` path passes only if it is a template (a `<placeholder>` segment; for `/home`, `/Users` the user segment is one). `~/notes.md`, `/Users/bob/x` and `/home/bob/<x>/y` stay blocked.

### Tests
- `bash tests/test_cloudrun.sh`: 128 passed, rc=0.
- `bash tests/test_lane_status.sh`: 16 passed, rc=0.
- `bash tests/test_remote_review.sh`: 106 passed, rc=0. A first conformance run caught a real regression of mine (an extra `ls-remote` per poll while the lane branch was missing; test "poll rate limit"). Fixed: one `ls-remote` call now covers both the lane branch and `claude/<id>-*`.
- `bash tests/conformance.sh` (before that fix): rc=1, 240 passed, 8 failed. Six of the failures (test_harness_isolation, test_vocab_hygiene, test_supervise_pgroup_kill, test_parity_insource_refresh, test_conformance_suite_timeout, test_sealed_fixes) also fail on the unmodified base `2235be9` in this root-user container. test_release_0175 passed alone (rc=0) and failed only under load. test_remote_review is the regression above. Conformance was not re-run after the fix; the affected suites were re-run individually and pass.

### Unproven / choices
- P3-7 and P3-8 (session-state evidence, live trust screen text) are not addressed: they need a vehicle status API and a live capture.
- The HEAD guard compares against the remote tip, so a stale local base is also refused (fetch first).
- The `claude/<id>-*` lookup costs one extra network call per poll only while the lane branch is missing.
- Cleanup offers remote branches for every registered lane, not only finished ones.

## Needs from other lanes
- Some suite (watchsvc/signal/tick tests) writes `alive` files into the repo root with `'`, space and `$` in the path. It should use `mktemp` under `$TMPDIR`. Not fixed here.

## Round 3 (osrc-l7-remote-r3)

Base confirmed: `git log --oneline -3` showed `f0ab993` (r2 tip). Fixes for the Fable review of round 2. Files: `lib/remote.sh`, `lib/cloudrun.sh`, `lib/cleanup.sh`, one line in `lib/review.sh`, tests in `test_lane_status.sh` and `test_cloudrun.sh`. The r2 READY/RESULT files are removed.

- **P1-1 exact branch ownership.** `_osrc_lane_alt_branch` now looks at every `claude/<id>-*` candidate (gh `matching-refs`, the ls-remote output, then the launch log) and keeps one only if `_osrc_lane_owns_branch` agrees: it must be `claude/<id>-<suffix>` and no longer registered lane id may also name it (`claude/alt-r2-x` belongs to `alt-r2`, never to `alt`). Tests: `alt` vs `alt-r2` on the git transport, `g1` vs `g1-r2` on the gh transport.
- **P2-2 review and done point at the branch the READY commit is on.** `_osrc_review_enqueue` uses `.poll_branch // .branch` (`lib/review.sh:98`, one line outside my files: the brief requires that review never points at a missing branch, and this is the smallest change that does it). The `done` event names the same branch. The generated done-contract script reads `.poll_branch` from the lane json at run time and falls back to `cloud/<id>`. Tests: review item branch, done event text, and the generated script passing against READY on `claude/<id>-*`.
- **P2-3 no silent swap after delete.** Once `cloud/<id>` has been seen, the session branch is followed only if it is already the `poll_branch`. Test: push, delete `cloud/alt3`, push `claude/alt3-k2` -> `branch_deleted=true`, `poll_branch` unchanged.
- **P2-4 HEAD guard with `--sha`.** With `--sha` the checkout HEAD must be the pinned commit; without, the base tip. The message no longer suggests `--sha`. Test: `--sha <main>` from a side branch is refused.
- **P2-5 gh path tested** with a stub that answers `matching-refs` and the session branch's `commits/` call.
- **P3-6** "never started" requires `err_count == 0`. Test: failing polls past 45m do not claim it.
- **P3-7 + Windows paths.** Rule: every user-specific segment is a `<placeholder>`: the user name (for `/Users`, `/home`, `X:\Users`) and the first folder under home unless it is an app folder (a dot-folder, `AppData`, `Library`); at least one placeholder overall. Windows drive paths (`C:\Users\…`, `C:/Users/…`) are now checked the same way: `C:\Users\<user>\<project>\README.md` passes, `C:\Users\bob\proj\x` and `C:\Users\<user>\clients\acme\<f>` are blocked. `~/clients/acme-corp/<file>` is blocked. The dead `$HOME/` and `${HOME}/` arms are deleted, as the review suggested. Choice: literal `$HOME/…` text is not inspected (as on the base; it names no user) and other drive paths such as `D:\work\x` are not home paths and are not checked.
- **P3-8 cleanup** offers only lanes whose state is `done` or `failed`, and only `.branch` and `.poll_branch`; the launch-log grep is gone. Tests: a READY lane is not offered, a failed and a done lane are, and a prose name ending in `.` from the log is not added.
- **P3-9** dead `die` and `[ -n "$ref" ] &&` removed. **P3-10** preflight keeps the base tip it fetched (`_CLOUDRUN_BASE_TIP`); the guard makes no second `ls-remote`.
- **P3-11 cost, stated honestly:** while `cloud/<id>` is missing, the gh transport makes up to three API calls per poll (`commits/cloud/<id>`, `matching-refs`, `commits/<session branch>`); the git transport stays at one `ls-remote`. Fine at the default 60s poll.
- **P3-12** the vehicle-gone test falls back to `kill -0` when `ps -o stat=` gives nothing (Git Bash). It cannot fail on this Linux base, so it has no before/after proof.

### Tests (all run here, `nice bash …` from `scripts/`)
- `tests/test_lane_status.sh`: 25 passed, rc=0. With the four lib files reverted to the base: 9 of the new assertions fail.
- `tests/test_cloudrun.sh`: 133 passed, rc=0. With the libs reverted: 4 new assertions fail (HEAD guard with --sha, literal home folder, real Windows path, done check on the session branch).
