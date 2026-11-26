# osrc-fx-spend — release-gate fixes, paid-model consent (0.18.0)

Base `cloud/osrc-int` @ 1e0064b. Branch `cloud/osrc-fx-spend`. Scope: the spend / Devin-free /
launch-gate findings from the torture-room review. Disk and Mission Control were left to their own lanes.

## What changed and why

| # | Finding | Fix | Regression test (fails on 1e0064b) |
|---|---------|-----|------------------------------------|
| 1 | security F1, pattern F1: the no-consent Devin probe pinged paid ids (`swe-2-flash-*-lightning`, `glm-5-3-*`, `kimi-k3`, `swe`, `swe-1.7-lightning`) | `_devin_probe_pick` accepts a candidate only on `_osrc_devin_free_for_spend` (exact id, fresh catalog Free; offline only swe-2-high / swe-2-flash-high) or the exact literals `glm-5-2` / `swe-1-7`. The built-in fallbacks are `glm-5-2 swe-2-high` (kimi-k3 dropped: the catalog prices it). `_devin_is_free_model` lost every glob and bare alias (`swe`, `glm`, `kimi`, `deepseek`, `swe-2`, `swe-2-flash*`, `glm-5.3*`, `swe-2-max`, `swe-1.7-lightning`, `kimi-k3`); its static list is exact plan-included ids plus the two offline-Free ids. | `test_devin_probe_strict` (new: 25 of 30 cases fail on base, including `doctor` with `OSRC_DEVIN_PROBE_MODEL=swe-2-flash-high-lightning` against a stub devin) |
| 1b | callers of `_devin_is_free_model` | Checked the banner (`delegate_devin`, judges the resolved id), the failure classifier (`_devin_free_own_quota`, job model), the plan meter (`_devin_plan_jobs_today`) and the probe. All of them now label only exact ids, so a paid id is never called free. A bare-alias ledger row is no longer counted as plan usage, so the meter under-warns rather than over-labels. | `test_tool_bugs_062`, `test_advise_task_shape` updated to the strict rule |
| 2 | spec F1: PR #88 shipped only 94eef9d | Cherry-picked 698a600, 90a472a, 371339c (author kept; conflicts resolved onto the resolve-once code). Resolver hunks moved into `lib/devin-free.sh`. `route_delegate` keeps `_osrc_dv_launch_prepare`. The cloud disclosure now takes `_gate_model` (= `${_OSRC_DV_LAUNCH_ID:-$RESOLVED_ID}`). The PR's comment blocks were dropped from outsourcerer.sh (shrink-only). | PR tests kept: test_devin_catalog_free_tier 34/34, test_spend_consent r3.4 e2e |
| 3 | arch F1: no forcing function for launch paths | `tests/test_launch_sites.sh`: every `tmux new-session` / `respawn-pane`, `delegate` / `delegate_*`, `"$_df"`, `_cloudrun_launch`, the session wrappers (`_session_create_pane`, `_session_launch_adapter`, `_session_control_relaunch`) and the winpty broker must sit in an allowlisted function. Each row names the gate and the function that holds it, and the test checks that function really calls the gate (from `declare -f`) and that gate-before-launch order holds. Stale rows fail too. A self-test proves that a new `session fork` / lane restart is caught. Registered in conformance. | new suite (on base the `delegate_codex -> delegate_cc` row fails: no per-member gate) |
| 4a | arch F4: `_OSRC_DV_LAUNCH_ID` global | Keyed with `_OSRC_DV_LAUNCH_FOR` (the `-m` token it was resolved for). `delegate()` honours it only for that token and consumes it, so one gated id covers one launch. | test_devin_launch_gate F4 rows |
| 4b | arch F5: one factory `--spend-ok` covered every task | `_osrc_spend_task_bind` (lib/spend.sh), called from the bg marker writer: inside a factory task (`OSRC_TASK_REF`), the first task's `lane|model` pairs bind the command's consent (file keyed by the shared `$$`, pruned when that pid exits). A task on another paid pair gets no marker, so its job asks with its own EVENT + NEXT. | test_spend_consent F5 rows |
| 4c | arch F6: OpenRouter consent covered chain escalation | The `or` gate lists the escalation chain in its prompt and refusal ("on transport failure escalates to: ...") and binds consent to exactly that set (`_OSRC_SPEND_BOUND_SET`). `delegate_cc` / `delegate_codex` gate every chain member (`_osrc_or_member_gate`) before it runs, so a model outside the shown set asks. | test_escalation_classify F6 rows |
| 5a | arch F2 (spend): missing/truncated lib skipped the gate | caps, devin-free, spend-paths and spend end with a sentinel. `_osrc_spend_libs_ok` checks the sentinels plus every gate entry point. On failure the lib loader (same single line in outsourcerer.sh) replaces each gate entry point with a refusal that exits 70. `cloudrun.sh` calls the gate unguarded; the "gate not loaded, launching anyway" branch is gone. | `test_spend_lib_failclosed` (new): spend.sh missing, truncated, unreadable, syntax error mid-devin-free, caps.sh missing; end-to-end `run` launches nothing |
| 5b | error-handling F9: unread/malformed cap let auto launches through | `_osrc_cap_invalid` reports specs that fail validation. An unread or malformed cap on an auto launch hops when a free hop exists, else refuses. `--force-lane` still overrides; an unbound-only spec stays a warning on auto (unchanged). | test_limit_gate F9 + rewritten unread rows |
| 6 | perf F2/F3, pattern F5: two Free-set builders, memo lost in `$( )` | `_devin_catalog_free_set` is now built from `_devin_catalog_free_ids` (the stricter fresh-only rule, one parse per catalog mtime via the existing disk cache) and memoizes in the caller's shell. `_devin_free_ids_get` shares one lookup (an unprovable answer included) between billing, label and default-model. Freshness is checked before any refresh. Fail-closed when the catalog is missing. Measured on a 98 KB fixture: 10 label checks 2749 ms → 268 ms; a spend check after them 308 ms → 3 ms. | test_devin_probe_strict §4–5 (stale catalog proves nothing; one raw parse per mtime; memo in parent) |
| 7 | spec F16: test_spend_attack red on Mac (2 session-start cases, rc 4) | Reproduced on Linux by running with a 90-char TMPDIR: exactly the same two cases, rc 4. rc 4 is `_session_create_pane` failing, because tmux cannot bind a socket under `TMUX_TMPDIR=$TMP` past the unix-socket path limit (104 bytes on macOS, 108 on Linux; a Mac scratchpad TMPDIR is long). The suite now puts the tmux socket in a short `mktemp -d /tmp/osrc-sa.XXXXXX`. Its fixtures were reshaped so `-m swe` still resolves to a paid id under PR #88's cost-before-effort. | base + long TMPDIR: 53/55 (the 2 Mac failures); fixed + long TMPDIR: 59/59 |

outsourcerer.sh: +6 / −8 lines, all on spend-gate lines (loader check, the two OpenRouter loops, the route gate rc line, the disclosure arg, the env-unset line).

## Tests run (Linux, bash 5, niced, one at a time)

All exit 0 at 182061e unless noted: test_devin_catalog_free_tier, test_devin_probe_strict,
test_devin_free_guard, test_devin_launch_gate, test_spend_consent, test_lane_billing,
test_limit_gate, test_tool_bugs_062, test_advise_task_shape, test_escalation_classify,
test_no_silent_escalation, test_cc_devin_selfheal, test_launch_sites, test_spend_lib_failclosed,
test_cloud_gate, test_cloud_gate_coverage, test_factory_exclude, test_devin_plan_quota,
test_devin_plan_quota_probe (rc 1 until the suite's alt pin was fixed, then 0), test_p56_factory_child, test_p56_r2,
test_factory_tasks, test_session_control, test_lifecycle_fix, test_tests_set_home,
test_sed_extract_targets, test_devin_alias_resolution, test_catalog_validation,
test_delegate_attribution, test_cloud_autoisolate, test_cloudrun, test_no_pipe_grep_q,
test_shell_scratch.py. `test_spend_attack.sh`: 59/59, rc 0 (also 59/59 under a 90-char TMPDIR).

`bash tests/conformance.sh` (final, at 182061e): **rc=1, 264 passed, 3 failed, 14 skipped**. The
3 failures are test_harness_isolation, test_vocab_hygiene and test_parity_insource_refresh. Each
fails the same way on the base 1e0064b in this container, which runs as uid 0. They inject
failure through read-only files or permissions, and root ignores those. They are not caused by
this lane, but conformance is red, so RESULT says rc=1. The first conformance run also caught
4 failures of mine (test_cloud_autoisolate and test_cloudrun asserted the old disclosure
argument and the removed fail-open cloud path; a `| grep -q` in test_launch_sites; an unquoted
mktemp template in test_spend_attack). All 4 are fixed in 182061e.

## What remains unproven

- No Mac receipt: I reproduced the rc 4 on Linux and fixed it, but did not run on macOS or Git Bash.
- Whether `glm-5-2`, `swe-1-7` and `deepseek-v4-pro` are still plan-included today is an operator
  check. They are exact literals now, and the spend gate still treats them as metered.
- F5 binds per factory command through `$$`. A plan whose tasks run as separate top-level
  processes (not subshells of one command) gets no cross-task binding. Each of those commands then
  needs its own `--spend-ok` anyway.
- `_session_launch_adapter` / `_session_control_relaunch` keep the gate at their callers. Moving
  it inside would break five suites owned elsewhere that drive the relaunch primitive directly.
  The allowlist plus the order check carry it instead.

## Open questions (decided by the lane)

- caps.sh is outside the listed files, but item 5 assigns the cap fail-open fix to this lane, so I
  edited it (`_osrc_cap_invalid`, cap gate's unverifiable branch, end sentinel).
- Missing spend lib: refuse every launch (exit 70) rather than kill the whole CLI at load time.
  doctor/status/help keep working, so a broken install cannot wedge a session or a hook.
- OpenRouter F6: chose "show the chain, bind consent to that set" over "re-ask per member", so a
  consented auto run still escalates on a 429 to the models it listed.
- Probe literal allowlist: `glm-5-2` and `swe-1-7` (the repo's documented plan-included ids). `kimi-k3` was
  dropped because the catalog prices the kimi-k3 family.

## Needs from other lanes

- osrc-fx-disk: arch F2's disk half (`type _osrc_disk_gate && _osrc_disk_gate` guards in
  outsourcerer.sh; cleanup.sh / disk_policy.sh are not in the sentinel check). The same sentinel
  pattern (`_OSRC_LIBEND_*` + `_osrc_spend_libs_ok`) can be extended to them.
- Factory owners: per-task `spend_ok` fields written at `task new` time would make F5 exact rather than
  first-task-binds.

## Round 2

In progress (live-test findings 3, 5, 6, 7, 8, 16, 18; fail-closed second loader; hermetic r3.4; factory per-task consent).
