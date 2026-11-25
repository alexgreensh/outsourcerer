# osrc-int-fix-b: integration fixup (approver, alerts, coordination, remote, PR lane)

Base: `cloud/osrc-int` at `a492df7` (confirmed with `git log --oneline -3`). Work branch `cloud/osrc-int-fix-b`.
Paths below are relative to `plugins/outsourcerer/skills/outsourcerer/scripts/` unless they start with `references/` or `reports/`.

Net diff: 13 files, +96 / -72. Code (`lib/` + `outsourcerer.sh` + docs): +40 / -53. `outsourcerer.sh` keeps its line count (3 changed, 3 removed). `lib/screen.sh` 693 -> 692 lines, `lib/lease.sh` 251 -> 240. No file over 1,000 lines.

## Approver (review osrc-l4-r5), commit 68e732a

| Finding | Status |
|---|---|
| P2 1: header scrolled off, column-0 decoy approves | **Fixed.** A command is read only when the header row has the modal's own title `▲ Approval required` directly above it. A header on capture row 0 therefore holds, and so does a column-0 decoy header once the real title/header have scrolled off. Every real Devin capture in `tests/fixtures/screen/` has the title on the row above the header, so this only removes approvals, never adds one. |
| P2 6: Devin `Write(`/`Edit(`/`Read(` skip the one-row rule | **Fixed by deletion.** The write/read (and Create/Overwrite) arms are gone. Only `Exec(` sets a kind, so those approvals stay `other` and hold until a real write/read capture exists. |
| P3 2: tall-command test does not prove its claim | **Fixed.** New variant `r5e` removes the real title and header rows, keeping the tall body and a column-0 decoy header. |
| P3 3: `[ "$hdr" -ge "$lo" ]` dead | **Deleted.** |
| P3 4: bracket class breaks the locale rule | **Deleted.** `""` and `"$ "*` stay. |
| P3 5: stale text holds every Devin approval | No change needed (it errs toward holding). Listed under Unproven. |
| P3 7: l4-r5 RESULT/report numbers | `osrc-l4-r5.RESULT` is no longer in the tree on this base, so nothing to fix. |

New tests in `tests/test_approver_tick.sh`: tall decoy with the real header off screen holds; header on row 0 holds (and reads no command); Devin write with a two-row body holds as `other`; headerless write body holds as `other`. **All 4 fail on the base** (`59 passed, 4 failed` with the base `screen.sh`) and pass after the fix (63/63).

## Alerts (review osrc-l3-r5), commit fd591a4

The P1 (`/upgrade` trailer) and P2 (shell prompt reads working) were **already fixed on the base in 301f8f7**, and both have tests there. Skipped.

| P3 | Status |
|---|---|
| False `limit` under a rule reached 11 rows | **Fixed.** `_osrc_scr_bottom [window]` takes a window: 12 for busy (unchanged), 6 for limit. |
| "Guard keeps tool errors out" only true for "exceeded" | `⎿ Error:` rows were already excluded in 301f8f7 (test present). A `⎿ Usage limit reached. Try again in 5m` tool row with no `Error:` prefix still reads `limit`. It cannot be told apart from Claude's own banner text without a live capture, so it is listed under Unproven, and the old report sentence should be read with that caveat. |
| Busy hint with text after it reads `unknown` | **Fixed.** `(… esc to interrupt) · <status>` and `• Working (` read busy. |
| "Hint must end the row" was partial | **Fixed.** Only an `esc` hint counts: `(press ctrl+c to interrupt)` is no longer busy. Every engine fixture uses `esc` (`esc to interrupt`, `esc twice to interrupt`). |
| Dead code `screen.sh:529` | The skip loop was already gone on the base (301f8f7). I deleted the leftover `''` in `CC_FOOT` and in the tool-block case in `tests/test_screen_alerts.sh`. The comment wording was already gone. |

New tests in `tests/test_screen_alerts.sh`: ctrl+c hint is not busy; a busy hint with a status tail is `working`; a limit row above a rule and ten output rows is not `limit`. **All 3 fail on the base** (73 passed, 3 failed) and pass after the fix (76/76).

## Coordination (review osrc-l7-coord-r4), commit 59cc952

1. **P2 docs:** `references/lanes.md` now says only your own calls renew, that a lease not renewed within its TTL is gone (re-claim, or keep `lane inbox --wait` running), and that `[` is a plain character. The heartbeat-renewal and minimum-TTL sentences are gone.
2. **P2 send-lock flake: reproduced and fixed.** I simulated stock macOS on Linux: a PATH with no `flock`, and `BASH_ENV` running `unset BASHPID`. That gave `6 passed, 2 failed` in 70 s, exactly the review's failure. Cause: test 3 killed the lock holder mid-hold, and without `BASHPID` the mkdir lock names the live test shell, so it is never reclaimed. Fix: the holder now holds 4 s and releases by itself (`wait`, no `kill`). The 1 s bound is still asserted (`took <= 3`). Result: 8/8 under the no-flock/no-BASHPID simulation, and 8/8 normally. This is a simulation on bash 5, not a real bash 3.2 run, so the orchestrator's Mac run is still the proof.
3. **P3 exit-125 test:** it now runs `osrc_lane_inbox` in-process under an `sh` parent that exits, and asserts the recorded return code is `125`.
4. **P3 beacon test and stale comments:** deleted the `type _osrc_lease_renew_live` line, the "heartbeat renewal" and "never lapses between beats" comments, and the orphan comment.
5. **P3 vestigial minimum TTL: deleted.** Removed `_osrc_lease_min_ttl`, the clamp, the warning and the header sentence. The test now asserts `--ttl 1` stays 60 s even with `OSRC_HEARTBEAT_CADENCE=3600`. **It fails on the base** (7260 s).
6. **P3 repo-key regression test:** a subshell stubs `git rev-parse --git-common-dir` to print an absolute path through the `$TMP/link` symlink, and asserts the key is the physical path. **It fails on the round-3 code** (it returns `…/link/.git`); I checked by restoring the round-3 `case "$c" in /*|?:/*)` line.
7. **P3 read-only state dir:** the busy message now ends `or read without marking: lane inbox --peek`, and the busy test asserts that.
8. **P3 help:** the `outsourcerer.sh` header now has `lane msg|inbox` and `lease claim|release|list` on separate lines, and the `references/lanes.md` pointer is back. Removed the stray `;` after `|| true`. Same line count.
9. **P3 report accuracy:** noted here. The l7-coord round-4 report's "RESULT names the real head sha" is wrong: `sha=` is the pinned base, which is correct. Its "8/8" for `test_send_lock_wait` held on Linux only, until item 2 above.

## Remote (review osrc-l7-remote-r4), commit eed7f84

- P2 1 and P2 2 were **already fixed on the base in ad5eba8** (case-folded route grep; the launch-log name is only accepted from the remote list, with test "absent launch-log name falls back"). Skipped.
- **P3 3 fixed:** the offer is now `names="$(jq -r '.poll_branch // .branch' "$f")"`, so the offered delete only names the branch the lane actually pushed (a missing target fails the whole `git push --delete`). This also removes a variable and a line. The updated test asserts `--delete claude/alt1-Xk3Q` alone and **fails on the base**.
- **P3 4 tests added:** a lane whose review item closed as merged is offered. A lane whose done-when check failed is not offered, even with a MERGE verdict stubbed.
- **P3 5 (net lines):** the remote/cleanup code is net -1 in this commit.
- **P3 6:** the scratch-registry `sed` in `tests/test_cloudrun.sh` is now a literal awk swap of the `%q`-quoted path, so a path with a space matches. Unproven: `test_cloudrun.sh` under a TMPDIR with a space fails 77 checks elsewhere (preflight/gate helpers), so I could not prove this line in such a run. It passes in the normal run (134/134).

## PR lane (review osrc-l6-r5), commit c317c75

| P3 | Status |
|---|---|
| 1: `osrc-l6-r5.RESULT` sha/rc | Not touched: the brief forbids editing other lanes' READY/RESULT files, and the orchestrator strips them. |
| 2: detached-HEAD test fails without `lsof` | **Fixed.** It expects `^ASK.*not on branch` with `lsof`, and any `^ASK` without it, the same as the `:241` guard. |
| 3: conformance not re-run, bash 3.2 | I ran conformance once (below). There is no bash 3.2 here. |
| 4: leftover `""` argument | **Deleted.** |
| 5: `cleanup.sh` header states the old rule | **Reworded** to: tip preserved by another ref, or PR merged. |
| 6: lane artifacts tracked | Left for the orchestrator's strip (brief rule). |

## Tests run (Linux, bash 5, each one at a time with `nice`)

| Command (from `scripts/`) | Result |
|---|---|
| `bash tests/test_approver_tick.sh` | rc 0, 63/63 |
| `bash tests/test_approver_table.sh` | rc 0, 459/459 |
| `bash tests/test_screen_state.sh` | rc 0, 264/264 |
| `bash tests/test_screen_alerts.sh` | rc 0, 76/76 |
| `bash tests/test_lane_coord.sh` | rc 0, 48/48 |
| `bash tests/test_lanemsg.sh` | rc 0, 80/80 |
| `bash tests/test_send_lock_wait.sh` | rc 0, 8/8; also 8/8 with no `flock` on PATH and `BASHPID` unset (was 6/8) |
| `bash tests/test_lane_status.sh` | rc 0, 31/31 |
| `bash tests/test_cloudrun.sh` | rc 0, 134/134 |
| `bash tests/test_cleanup_manifest.sh` | rc 0, 85/85 (with `lsof`) |
| `bash tests/conformance.sh` (from the repo root) | see Conformance below |

## Conformance

`nice bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh` at c317c75 (all code changes in) gave **rc=1: 250 passed, 7 failed, 1 skipped** (live probes skipped).

Failed suites: `test_harness_isolation`, `test_vocab_hygiene`, `test_supervise_pgroup_kill`, `test_parity_insource_refresh`, `test_conformance_suite_timeout`, `test_hub_mc4`, `test_sealed_fixes`. I re-ran each one alone on a clean worktree of the base `a492df7`, and **all 7 fail there too**: rc 1 each, and `test_sealed_fixes` rc 127. `test_vocab_hygiene` shows the same two failures on both ("original was damaged on failed write"), which looks like a write-permission test running as root in this container. None of these suites covers files this lane changed. The gate is still red, so RESULT says `rc=1`.

## Unproven

- **Devin, real captures:** a Devin modal taller or wider than the pane has not been captured. A decoy that puts *both* `▲ Approval required` and `This action requires your approval` at column 0 as two command rows would still be read. Only a real capture (or `capture-pane -S` scrollback) settles that.
- **Devin, stale text:** any earlier visible row containing `requires your approval` (a prompt, grep output) makes every Devin approval hold until it scrolls off. This fails safe, but expect held prompts.
- **Claude limit, tool rows:** a `⎿ Usage limit reached …` tool-output row with no `Error:` prefix, as the last row, still reads `limit`.
- **Platforms:** nothing ran on real macOS bash 3.2 or Git Bash. The send-lock fix is proven only under a Linux simulation.
- **Space in TMPDIR:** the `test_cloudrun.sh` space-path fix (see Remote).

## Open questions (decided by the lane)

- **Approver P2 1:** the brief says "header on row 0 holds". I implemented the stricter form, "the modal's title row must be directly above the header", which implies it. This also holds the review's probe, where the decoy header is not on row 0. Chosen because it is fail-closed and every real capture satisfies it.
- **Busy hints:** only `esc` interrupt hints count. A future engine that says `ctrl+c to interrupt` would read `unknown` (the stall path), not `working`. That is the safer error.
- **RESULT sha:** the hosted-session contract says line 1 is the pinned base `sha=a492df7…`, and `lib/cloudrun.sh` checks it against that. The lane rules say "own head". I followed the contract and give the work head in the RESULT summary.
- **Branch:** pushed to `cloud/osrc-int-fix-b` as the brief requires. No PR was opened, because the lane rules forbid it.

## Needs from other lanes

- **Orchestrator:** run `tests/test_send_lock_wait.sh` on stock macOS (bash 3.2, no `flock`) to confirm 8/8. Strip `osrc-l6-r5.*`, `reports/osrc-l6-prs.md` and the other lane markers at release.
