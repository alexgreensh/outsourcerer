# osrc-int-fix-d: tests must not depend on the host's free disk

Base: `cloud/osrc-int` @ `7cd93e3` (confirmed with `git log --oneline -1`). Work branch: `cloud/osrc-int-fix-d`.
Fix commit: `75fe943`. Everything ran as the non-root user `runner` (the shell was root, so the checkout was copied to `/home/runner`).

## Audit of the base
I read `git log ea34fe0..HEAD` (173 commits) and `reports/osrc-l5-r3.md`. I verified the part this lane touches.
`lib/disk_policy.sh` reads floors only from `$OSRC_HOME/disk-policy/settings`, never from an exported variable. `test_disk_policy` and `lib_factory_flow_l5` assert that.
The two suites already fixed on the base (`test_perm_profiles`, `test_factory_tasks`) passed on the full disk. I left them unchanged.

## Disk (`df -k`, one filesystem `/dev/vda` holds `$TMPDIR=/tmp` and the checkout)
| state | line |
|---|---|
| before | `/dev/vda 264212084 9347896 62735208 13% /` |
| filled (`fallocate -l 59589456K`) | `/dev/vda 264212084 68937384 3145720 96% /` |
| after deleting the placeholder | `/dev/vda 264212084 11805100 60278004 17% /` |

Launch floor on this volume: max(10 GB, 5% of 252 GB) = 12 GB (the engine prints "12GB launch floor"). 3 GB free is under it.
About 2.4 GB did not come back. That is `/root/.total-recall` (a session tool outside this repo) and the test copies, not test leftovers: `/tmp` was 3.5 MB.
During the first full run, that outside growth briefly pushed free space to 0.5 GB, under the 1 GB critical floor. I shrank the placeholder back to exactly 3 GB free, and every rerun below logged free space between 3.28 and 3.37 GB.

## Suites the full disk broke (baseline run: `RESULT: 232 passed, 28 failed, 14 skipped`, rc=1)
26 of the 28 failures were the disk gate. Each failing suite was rerun alone to get its reason. A typical line:
`ERROR: outsourcerer: free disk is 2GB (< 12GB launch floor) and nothing Outsourcerer-created is pending cleanup …`

Suites that failed on the launch floor: test_hardening, test_autodetach, test_claudex (blocked launch, then `TIMED OUT after 600s`), test_opencode_lane,
test_p56_billing, test_p56_r2, test_p56_factory_child, test_cline_lane, test_bg_provider_after_verb, test_tmux_headless_fallback,
test_require_interactive, test_cloud_autoisolate, test_pi_lane, test_grokbot_lane, test_preflight_env_isolation, test_heartbeat_arm_liveness,
test_heartbeat_autoarm, test_delegate_attribution, test_factory_exclude, test_factory_e2e (`FAIL: plan run exit 2 … Next: 1 ready`, the factory gate),
test_job_meta_lane (`FAIL: meta lane is ''`), test_done_contract, test_accounts (`stopped at line 108 … run -m fable`), test_limit_gate,
test_spend_consent, and test_lean_launch.py (`'lean launch: invalid MCP config' not found in '… free disk is 3GB (< 12GB launch floor) …'`).

Two baseline failures were not caused by the gate:
- `test_disk_policy` failed only in the window where free space hit 0.5 GB. It passes alone at 3 GB (rc=0). Its disk logic is unchanged.
- `test_tests_set_home`: `FAIL: engine or lib without HOME assignment: test_redirect_order.sh`. This happens on any disk and is already on the base.
  `test_redirect_order.sh` only greps the engine source. Fix: it now creates a private `HOME` with `mktemp -d` and reuses that directory.
  The guard itself is untouched.

No suite printed a `SKIP:` line because of the disk.

### Fix
Right after each test sets a fake home, it writes `$HOME_VAR/disk-policy/settings` with a one-line comment saying why:
```
OSRC_DISK_MIN_GB=0
OSRC_DISK_PAUSE_GB=0
```
Suites with several homes set the file in each one that launches: autodetach REENTRY/SAB, bg_provider e2e, tmux_headless H1/H2,
require_interactive A–D, delegate_attribution main/H1/H2/H3, limit_gate main/H7/H8/BH, spend_consent main/DOH/DOH2/E2, and factory_exclude's `xh()` helper.

`OSRC_DISK_MIN_GB=0` alone is not enough. With launch at 0, the pause floor keeps its default, max(4 GB, 2% of the volume) = 5.3 GB here, because it is capped at 3/4 of launch only when launch > 0.
With only MIN_GB=0, `test_opencode_lane` hung: the disk monitor had SIGSTOPped its own lane (`ps` state `T`).
So the tests also set `OSRC_DISK_PAUSE_GB=0`, which comes from the same settings file.
No product code changed. The gate still reads no environment variable. The critical floor stays in force, because nothing lifts it.
Suites that test the disk gate itself were not touched: test_disk_policy, lib_factory_flow_l5, test_cleanup_manifest.

## Reruns on the full disk (3 GB free, each suite alone, niced)
- All 27 edited suites plus test_redirect_order: rc=0 each. test_factory_exclude needed one more round (the `xh()` homes); it then passed with rc=0.
- test_disk_policy rc=0, test_tests_set_home rc=0.
- Full `conformance.sh` on the full disk with the fixes: **`RESULT: 260 passed, 0 failed, 15 skipped`, rc=0** (minimum free 3.34 GB).
  None of the 15 skips mentions the disk. The one new skip is test_claudex's "claude CLI absent", which it now reaches instead of timing out.

## Normal disk (60 GB free)
- `bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh`: **`RESULT: 259 passed, 1 failed, 15 skipped`, rc=1**.
  `FAIL: unit suite test_cleanup_manifest FAILED`. It passes alone (`RESULTS: 85 pass 0 fail`) and twice more next to three heavy suites.
- One more run with `OSRC_CONFORMANCE_VERBOSE=1`: **`RESULT: 259 passed, 1 failed, 15 skipped`, rc=1**. This time test_cleanup_manifest passed, and the failure was
  `FAIL: unit suite test_release_0175 FAILED` (`FAIL: path-stale hub survived: pid3=8383 pid4= …`, `jq: error: Could not open file …/hub/serve.json`).
  It passes alone twice (rc=0).
- These are two different suites, neither edited by this lane. Each fails only under conformance's parallel load, and they look like timing flakes, not the disk.
  Since no normal-disk full run was green, `osrc-int-fix-d.RESULT` says `rc=1`.

## File size
`python3 scripts/check_file_size.py` → `file-size: OK (169 changed file(s) checked, limit 1000).` rc=0
`python3 scripts/check_file_size.py --base 7cd93e3` → `file-size: OK (28 changed file(s) checked, limit 1000).` rc=0

## Unproven
- I did not run the base on the normal disk, so I can't say whether the two load flakes predate this lane. The edited suites use only their own temp homes.
- Only Linux was tested: no macOS bash 3.2, no Git Bash. The added lines are `mkdir -p` and `printf`.
- Suites that skip here (codex, agy, droid, cursor-agent, claude CLI, bwrap, live probes) were not exercised on a full disk.
- No regression test was added: the edits are themselves tests, and the full-disk conformance run proves them (it failed before, and passes after).

## Open questions (decided by the lane)
- RESULT line 1: the Finish section says `sha=<your final head>`, but the Contract and lane rules say the pinned commit, which the product validates. I used the pinned commit and named my head below it.
- PAUSE_GB=0 as well as MIN_GB=0: this is required for the test to be independent of the host (see above). It lifts only the floor of the test's own fake home.

## Needs from other lanes
- Product (disk-policy owner): the factory gate's hint "To lift the floor: OSRC_DISK_MIN_GB=0 in …/disk-policy/settings" lifts only the launch floor.
  The lane can still be SIGSTOPped at the default pause floor right after launch. Either say so in the hint, or cap pause when launch is 0. I left this unchanged because it is not my file.
- Hub owner: `test_release_0175` (path-stale hub / serve.json) is flaky under conformance's parallel load.
- Cleanup owner: `test_cleanup_manifest` failed once under the same load and passed alone three times.
