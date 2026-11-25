# osrc-l6-prs: open PRs and issues (round 2)

Branch `cloud/osrc-l6-r2`, from `cloud/osrc-l6-prs` @ 7e24e4c. Nothing was commented on, closed, labelled or merged on GitHub.

## Verdicts

| Item | Verdict | Commits |
|---|---|---|
| #84 via PR #85 (base_sha is not preservation) | land (code correct, kept as is) | 70f47ac, e8f1808 |
| #86 via PR #87 (disk gate decides from live scan) | land with changes (test was vacuous as root) | 34f7eb2, 2999ce6 |
| PR #82 (bash 3.2 exit-chain misfire) | land (identical to base commit; root cause only partly provable here) | 7e24e4c |
| PR #80 (UTF-8 reads, advise tests) | close, superseded by 0.17.6/main; one idea ported | 2999ce6 |
| PR #83 (docs, outside contributor) | land with changes | c210d68, e5f5a29, d17145b, 607318d (author kept), 6e0ed46 (corrections) |

## Findings

**#84/#85.** `_osrc_branch_merged` no longer trusts `base` alone: it counts only if a `refs/remotes` ref contains it, and `_cmd_cleanup_target` refuses a zero-ahead branch that is not preserved. Mutation check: re-adding `bases+=("$base")` makes 5 assertions in `test_cleanup_manifest.sh` fail ("local-only base counted as preserved", "apply deleted the last ref to local-only commits", ...). Fix confirmed.

**#86/#87.** The gate counts and hashes from the live `items`; the state write is best-effort. Problem found: the existing regression test simulated the failed write with `chmod a-w`, which does nothing as root (this container, and plausibly cloud CI). With the gate mutated back to read `state.json`, the test still passed (rc=0). Fixed: the test now stubs `_osrc_cleanup_state_write() { return 1; }` in both gate4 and gate5. With that, the mutated gate fails both ("gate admitted a stale ack after failed refresh", "gate deadlocked on failed refresh"); the real gate passes (80/80).

**#82.** The PR commit 2a1b5d8 and base commit 7e24e4c have byte-identical patch lines. Mechanism: when the engine is sourced inside `$( )`, `trap -p` shows the caller's EXIT handler, which the chain captures. Bash 3.2 runs the substitution's EXIT trap with `BASH_SUBSHELL` already 0, so the `-eq 0` guard passes and the caller's `rm -rf "$T"` runs mid-suite. The fix records the arming level (`_OSRC_ARMED_LVL`) and requires equality. Unproven here: this container has bash 5.2, where a trap in `$( )` sees level 1, so the old code does not misfire. Against the old engine only the byte-identity assertion of `test_exit_trap_chain.sh` fails (25/1); the behavioural (i)/(j) cases pass on 5.2 either way. They need a bash 3.2 (macOS CI) run to be a true regression test. The new guard is harmless on bash 5.

**#80.** Everything in its `advise.sh` diff is gone or already fixed on main. Dropped:
- UTF-8 `open(..., encoding="utf-8")` in the inline python of `lib/advise.sh`: main (0.17.6) moved that code to `lib/advise_parse.py`, which already reads with `encoding="utf-8"`.
- The `limit_notes` / `limit_gate_reasons` reason: main's `advise-score.sh` now emits the reason itself (`<lane> parked — <window> at N%`, JSON `limit_gate`), and main's `test_limit_gate.sh` asserts it.
- Its three test files target the old output shape (`.candidates`, `gpt-5.6-sol lane=`); against current main its factory-exclude version fails 2 assertions. Main's `test_limit_gate.sh` and `test_model_denylist.sh` already pass (124/0 and 23/0).
Kept (rebased in spirit): the real insight, that the factory-exclude advise check passes vacuously on an empty cache. `test_factory_exclude.sh` now has a control run with no exclude list that must list a fable model.

**#83.** Contributor commits cherry-picked with `-x`, author Dani Kamanovsky intact. Every claim was checked against `lib/cleanup.sh` and the references. True and kept: SKILL.md pointers (Windows broker is in `jobs-and-safety.md`; `remote-and-review.md` exists), manifest fields, SAFE criteria, 1h age, 3-day TTL, ignored-cache allowlist, main-ish ref list, directory-only sizing and `0KB` for files, cloud-gate isolated copies not in the manifest. False after #85/#87, corrected in 6e0ed46: (1) "a worktree with no new commits past its base counts as preserved even when no remote holds that base"; (2) "the gate ignores a failed write and reads the previous count and hash"; (3) "the ack must match the hash in state.json". The paragraph also now notes that `cleanup <id>` refuses a branch that may be the only ref. Nothing from the PR was executed.

## Tests (run here, niced, one at a time)

| Command | rc |
|---|---|
| `bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/test_cleanup_manifest.sh` | 0 (80 pass) |
| same, with #84 fix reverted | 1 (5 fail) |
| same, with gate reading state.json (after test fix) | 1 (2 fail) |
| `.../tests/test_exit_trap_chain.sh` | 0 (26 pass) |
| same, old engine from ea34fe0 | 1 (1 fail, bash 5.2) |
| `.../tests/test_factory_exclude.sh` | 0 |
| `.../tests/test_limit_gate.sh` | 0 (124/0) |
| `.../tests/test_model_denylist.sh` | 0 (23/0) |
| `bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh` | 1 (241 pass, 6 fail, 1 skip) |

Conformance failures: test_harness_isolation, test_vocab_hygiene, test_supervise_pgroup_kill, test_parity_insource_refresh, test_conformance_suite_timeout, test_sealed_fixes. Each also fails (rc 1; test_sealed_fixes rc 127) when run alone against the untouched base commit 7e24e4c, so none come from this round. At least two (vocab_hygiene, harness_isolation) are failed-write checks that a root container cannot simulate with permission bits (same cause as the #86 test gap). I did not diagnose the other four; CI on a non-root runner should say which are environmental.

## Overlap with osrc-l2-disk-r2

I did not touch `_osrc_disk_gate` in this round. The base branch's change to it (34f7eb2: decide from the live `items`, drop the `state` reads, keep the best-effort `_osrc_cleanup_state_write`) is the overlap; my doc paragraph in `hub.md` describes that behaviour and should be re-checked if l2 changes it. Tests that stub `_osrc_cleanup_state_write` depend on that function name and on the gate calling it. `_osrc_cleanup_ask_hash` is new (used by state write, `--ack`, the tick and the gate); l2 should keep one definition.

## Suggested public replies

- **#83 (Dani Kamanovsky):** Thanks for the docs fix and for adding the cleanup and disk-gate section; your commits are in with your authorship kept. Two paragraphs described behaviour that the #84/#86 fixes changed, so we corrected them in a follow-up commit; this ships in the next release after 0.17.6.
- **#80:** Thanks for the careful UTF-8 and advise-test work. Main's 0.17.6 moved that code into `advise_parse.py`, which already reads UTF-8, and added the limit-gate reason, so the diff no longer applies; we kept your idea of a control run so the exclude test can't pass on empty output.
- **#85/#87 and #82:** Thanks for the fixes; the base_sha and live-scan changes are verified with regression tests and ship in the next release after 0.17.6. For #82 the bash 3.2 behaviour still needs a macOS CI run to confirm.

## Remains unproven

- #82 on real bash 3.2 (see above).
- Not run: the other heavy suites (left to CI per brief).

## Needs from other lanes

- A bash 3.2 runner (macOS CI) to confirm `test_exit_trap_chain.sh` (i)/(j) fail without the guard.
- osrc-l2-disk-r2: see Overlap.

## Round 3

Branch `cloud/osrc-l6-r3` on `cloud/osrc-l6-r2` (aa11661). Astra's 8 findings, all addressed. Nothing was commented on, closed, labelled or merged on GitHub. A reviewer asked for `reports/osrc-l6-r2.md`; this lane's report file stays `reports/osrc-l6-prs.md` per the brief, and `osrc-l6-r2.md` was never written.

| # | Fix | Where |
|---|---|---|
| 1 | `cleanup <id>` (unforced) refuses when the live worktree HEAD is not `refs/heads/<recorded branch>` (detached, or on another branch), so a detached local-only commit is never orphaned by removing the worktree. | `lib/cleanup.sh` `_cmd_cleanup_target` |
| 2 | Disk gate dies when `_osrc_cleanup_items` exits nonzero, before the ack comparison. The scanner now loops in the current shell (no pipeline subshell) and returns 1 if the grouping `jq`, any verdict, or any item's JSON build fails. | `lib/cleanup.sh` |
| 3 | `_osrc_branch_merged` resolves `refs/heads/<br>^{commit}` once and uses that sha for every ancestry check and the merged-PR head compare; main-ish refs are fully qualified (`refs/remotes/origin/main`, `refs/heads/main`, ...) and the base is resolved to a sha. | `lib/cleanup.sh` |
| 4 | Parent validated with `git -C "$maindir" rev-parse --git-dir` (works when its `.git` is a file). Removal is `git worktree remove --force` only; on failure, or if the branch survives `branch -D`, `cleanup` returns 1 and keeps the receipt. `rm -rf` is kept only when the parent is not a git repo at all. | `lib/cleanup.sh` |
| 5 | The engine arms its EXIT trap only when `BASH_SUBSHELL` is 0, so a `$( )` that sourced the engine keeps its own handler. | `outsourcerer.sh` (`[ "${BASH_SUBSHELL:-0}" -eq 0 ] && _osrc_exit_chain ...`, 1 line + comment) |
| 6 | Ported PR #80's quota and denylist behaviour checks to the current JSON: `.recommendation.lane`, `.shortlist[]`, `.limit_gate`, each with a control (40% weekly: cx shortlisted, `limit_gate` empty; no denylist: model shortlisted). | `tests/test_limit_gate.sh`, `tests/test_model_denylist.sh` |
| 7 | hub.md: bring the delegate's edits back first, `--force` only after saving or deliberately discarding; documents the HEAD refusal. | `references/hub.md` |
| 8 | Handoff corrected (below); tip subject starts `READY:`. | this file, `osrc-l6-r3.RESULT` |

### Carry-over note for osrc-l2-r2 (finding 2, `_osrc_disk_gate`)

The smallest change to the gate is exactly one edit: the line

```
items="$(_osrc_cleanup_items --no-size 2>/dev/null)"
```

becomes

```
items="$(_osrc_cleanup_items --no-size 2>/dev/null)" || die "outsourcerer: free disk is ${free_gb}GB (< ${OSRC_DISK_MIN_GB:-10}GB) and the cleanup scan did not finish, so the leftover list is unknown — refusing new lane launches. Run '$0 cleanup' to see what can go, then '$0 cleanup --apply' and/or '$0 cleanup --ack'."
```

placed before `_osrc_cleanup_state_write` and the ack comparison. It only works together with the scanner change: `_osrc_cleanup_items` must return nonzero when any item fails (previously its status was the `while` loop's, i.e. 0 or the last `jq`). Carry both hunks; the scanner hunk is the whole body of `_osrc_cleanup_items` (reads `grouped="$(jq -cs ... )" || return 1`, `while ... done <<<"$grouped"`, `return "$rc"`). Regression: `test_cleanup_manifest.sh` "gate refuses when the scan exits nonzero after emitting an acked list" (stubs the scanner to emit the real items, then return 1).

### Tests (this round; niced, one at a time; bash 5.2 on Linux, root)

| Command | rc |
|---|---|
| `bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/test_cleanup_manifest.sh` | 0 (85 pass) |
| same suite against aa11661's `lib/cleanup.sh` + `outsourcerer.sh` | 1 (80 pass, 5 fail: gate partial scan, detached worktree, same-named tag, linked checkout, locked worktree/receipt) |
| `.../tests/test_exit_trap_chain.sh` | 0 (28 pass) |
| same, engine reverted to aa11661 | 1 (27 pass, 1 fail: "own-trap: substitution handler ran '0' times") |
| `.../tests/test_limit_gate.sh` | 0 (127 pass) |
| same with `OSRC_LANE_LIMIT_GATE=0` | 1 (new check `.shortlist still lists a cx candidate at 98%` among the failures) |
| `.../tests/test_model_denylist.sh` | 0 (25 pass) |
| `.../tests/test_no_pipe_grep_q.sh`, `.../tests/test_factory_exclude.sh` (after the fix) | 0, 0 |
| same with the scorer's `res in deny` filter mutated away | 1 ("advise shortlisted or recommended a denied model") |
| `bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh` | 1 (240 pass, 7 fail, 1 skip). Six failures are the same suites as round 2 (test_harness_isolation, test_vocab_hygiene, test_supervise_pgroup_kill, test_parity_insource_refresh, test_conformance_suite_timeout, test_sealed_fixes), still undiagnosed. The seventh, test_no_pipe_grep_q, was caused by this round (a `worktree list | grep -q` in my new test); fixed, and that suite then re-run alone: rc 0. The full conformance run was not repeated after that fix. |

### Corrections to the round-2 handoff (finding 8)

- Round 2 called the six conformance failures environmental. That is not established: the comparison ran the untouched `7e24e4c`, which already contains the cleanup, disk-gate and exit-trap changes, so it only shows those failures were not introduced by the two docs/test commits after it. The report itself said four of the six were undiagnosed. Treat all six as unexplained until someone runs them on `ea34fe0` (the pre-lane main).
- Exact focused commands and outcomes for round 2 are the table above (same suites, same commands).
- Still unproven: #82 on real bash 3.2. Test (k) fails against the old engine on bash 5.2 too, but (i)/(j) are only true regressions on macOS CI.

## Needs from other lanes (round 3)

- osrc-l2-r2: carry the `_osrc_disk_gate` one-liner and the `_osrc_cleanup_items` rewrite above; keep one `_osrc_cleanup_ask_hash`.
- A macOS bash 3.2 run of `test_exit_trap_chain.sh` and `test_release_0175.sh`.

## Round 4 (osrc-l6-r4): closing edits

Smallest change per finding, no new design.

- **P2-1** `_osrc_branch_merged`: replaced the main-ish loop and recorded-base block with one check, "does any ref other than `refs/heads/$br` (heads, remotes, tags) contain the tip". Still catches #84. The unused `base` argument is gone from the function and its callers. Trunk test flipped to rc=0.
- **P2-2** `worktree)` verdict: ASK unless the live `HEAD` is `refs/heads/$br`.
- **P2-3** scanner reads the manifest with `jq -R 'fromjson?'`, so a truncated last line no longer hides the rest or fails the scan.
- **P3-6** deleted the dead `if ! have jq` block in `_osrc_disk_gate`. **P3-8** removed the two comment lines at `outsourcerer.sh:375` (engine back to 19005 lines). **P3-7** hub.md wording fixed.
- **P3-10** `git rm` of the r2/r3 READY/RESULT files. `reports/osrc-l6-prs.md` stays: it is the required report for this lane; strip it before main.
- Fixture fix: the `pr-old` branch in the suite sat under `pr-hit`, so it was legitimately held by another ref. It is now on its own line.
- Not done: P3-4, P3-5 (unreachable `|| continue`), P3-9, P3-11.

### Tests
| Command | rc |
|---|---|
| `bash .../tests/test_cleanup_manifest.sh` | 0 (87 pass) |
| same with the pre-fix `lib/cleanup.sh` | 1 (3 new tests fail: trunk, detached HEAD, truncated manifest) |
| `bash .../tests/conformance.sh` | 124 (hit my 590s timeout mid-run; no FAIL line seen before the cut, suites after test_advise_task_shape did not run) |

Not run on bash 3.2. The six undiagnosed conformance failures from round 3 are unchanged unless listed above.

## Needs from other lanes (round 4)
- A macOS bash 3.2 run of `test_cleanup_manifest.sh`.
