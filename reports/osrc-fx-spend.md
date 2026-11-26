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

Base: round-1 head 06b90b1 (kept). Branch `cloud/osrc-fx-spend-r2`. These are the live-test findings
from the 0.18.0 sandbox run, plus three orchestrator findings. `outsourcerer.sh` stays at 18835 lines:
every edit is on an existing line, or is paired with a trimmed comment line. New code is in `lib/`
(spend.sh 987 lines, spend-paths.sh 151 lines).

| Finding | Fix | Regression test (fails on 06b90b1) |
|---------|-----|------------------------------------|
| orch: the second lib loader undoes the fail-closed stubs (Mac `/var` symlink, PATH launcher symlink) | The fail-closed decision is now a function, `_osrc_spend_failclosed`, still on line 303. The second (realpath) loader clears the four lib sentinels, re-sources the libs and re-runs the decision. A damaged lib is therefore judged after the LAST load. When the second loader legitimately rescues a wrong `SCRIPT_DIR`, the launch still passes. | `test_spend_lib_failclosed`: each damaged variant is also probed through a symlinked copy (`ln -s`), plus an intact-through-symlink row. On 06b90b1, `syntax` and `nocaps` via symlink give `gate-rc=0 session-rc=1`, the exact Mac signature. |
| orch: r3.4 e2e is not hermetic | `$PACAT/osrc` and `$MCAT/osrc` (test_spend_consent) and the `$sandbox` homes (test_no_phantom_jobs) write `disk-policy/settings` with both floors set to 0. | New `test_hermetic_disk_home`, registered in conformance. It is a static scan: every OSRC_HOME a test launches the engine from (run, bg, fanout, loop, session start) must write its disk settings. Bg preflight dry runs are exempt because they skip the disk gate. The suite has a self-test. On 06b90b1 it flags these 4 homes. |
| F3: `session send "/model X"` is ungated | `_osrc_session_send_model_gate` (lib/spend-paths.sh) runs on the same line as the cap check in tmux `session send`, and before the winpty send. It matches a first token of `/model` in any case, after leading blanks. With one plain id after it, it runs `_osrc_session_model_gate` on the session's recorded provider, and NEXT is `--spend-ok session model <id>`. `/model` alone, or with more text after the id, is refused with a pointer to `session model <name>`. | `test_spend_attack` send-model rows (4). All 4 fail on base: the pane receives `/model swe-2-1-high`. |
| F5: loop counts spend refusals as check failures, and has no consent path | After each attempt, `_osrc_loop_needs_approval` looks for the child's `EVENT approval` line or the fail-closed refusal. The loop then stops as `needs-approval` (rc 3) with one EVENT + NEXT. It grades no check, counts no attempt (resume re-runs it), does not escalate and writes no receipt. `--spend-ok` is accepted anywhere before `--` in `loop verify`, `loop escalate` and `loop resume`. It reaches each attempt's child as argv `--spend-ok`, and each child binds that consent to its own rung's lane/model pair. NEXT is `--spend-ok loop resume <id>` for verify, because `needs-approval` is resumable. Escalate is not resumable, so its NEXT is the original command with `--spend-ok`. | `test_spend_r2` F5 rows (5) |
| F6: fanout says "all N launched", then N jobs exit nonzero | `_osrc_fanout_preflight` runs bg's route preflight once per distinct provider/model pair, before any job is minted. Pairs use the members' own precedence: -m > --route > frontmatter > default. One refusal refuses the whole fanout ("Nothing was started") with the preflight's EVENT/NEXT, and NEXT is the fanout command with `--spend-ok`. A pair approved at an interactive prompt consents its own members. The preflight always runs the engine, even when the engine was sourced. | `test_spend_r2` F6 rows (2). test_p56_r2's marker-writer fixture now stubs the preflight, like its other launch stubs. |
| F7: supervise never replays spend events | `_osrc_event` adds `job`, taken from a valid `OSRC_JOB_DIR`. It also adds `owner`: the owner marker of that job, else `_owner_sid`. Supervise keeps rows whose `.owner` is the orchestrator, so a refusal by a fanout member or bg child now wakes it. `target` stays the lane, so no EVENT line changes. | `test_spend_r2` F7 rows: the row carries owner and job, and `supervise --session S7 --once` prints the approval. |
| F8: the gate says "bills metered", then the run says "$0 cash" and `[free-tier]` | The gate records its verdict in `_OSRC_GATE_BILL`. When the gate judged the lane metered or unknown, `_osrc_gate_paid` suppresses Devin's free-tier banner. The receipt then reads "billed as paid (metered; approved with --spend-ok)" (`_osrc_receipt_disclosure`). The gate is the single source of truth. | `test_spend_r2` F8 rows (2) |
| F16: model aliases are case-sensitive | `resolve_model_row` prefers the exact row, then falls back to a case-folded one. Folding is for routing only: the launched id is the table's exact id. `-m SOL` now takes the codex row, and `-m SWE-2-HIGH` launches the Free `swe-2-high`. A refused Devin id that case-folds to a proven-Free id now gets `EVENT failed … did you mean <id> (free)?`. Its NEXT uses the lowercase id and has no `--spend-ok`. | `test_spend_r2` F16 rows (3) |
| F18: a forged `jobs/<x>/.spend-ok` plus two env vars consents | Marker-only consent (no forwarded flag) also requires `_osrc_job_marker_bound`. That check needs a `meta.json` naming this job id, and needs the recorded `supervisor_pid` to be a live ancestor of this process. The ancestor walk reads `/proc/<pid>/ppid` or `ps -o ppid=`. When `ps` can report it, the supervisor's start time must match too. | `test_lane_billing` (forged dir without meta.json; supervisor not an ancestor) and `test_spend_attack` (a forged dir with the right token is refused). The fixtures that model a real job now write meta.json and an ancestor pid. |
| orch: factory consent binds to the first task | `task add --spend-ok -m X` records `spend_ok: X` on the task, and the confirmation names X. `spend_ok` is a protected field, so a tasks file or plan JSON cannot set it. `_task_dispatch` forwards `--spend-ok` only while the task still dispatches on exactly X, so a retry or escalation onto another model asks again. A task with its own consent skips the command-level first-task bind. `--spend-ok` without `-m` is refused. | `test_spend_r2` F5' rows (5) |

`test_spend_r2` is new and registered: 19 rows. Against the 06b90b1 engine it gives 5 passed and
14 failed. The 5 that pass are guard rows (a Free model still launches, `spend_ok` is set only by
the flag, and so on).

### Tests run (Linux, bash 5, uid 0, niced, one at a time)

All runs below are at the final head unless noted. Each result is the suite's exit code and its RESULT line.

- New and registered: `test_spend_r2` 19/19 rc 0, `test_hermetic_disk_home` rc 0.
- Updated: `test_spend_lib_failclosed` 12/12, `test_spend_attack` 62/62, `test_spend_consent` 57/57,
  `test_lane_billing` 145/145, `test_p56_r2` 66/66, `test_loops` 29/29, `test_loop_escalate` 31/31,
  `test_no_phantom_jobs` 18/18, `test_tests_set_home` 5/5. All rc 0.
- Unchanged and rc 0 (run one at a time, niced): test_factory_tasks, test_loop_resume,
  test_fanout_json, test_supervise, test_p56_factory_child, test_factory_exclude, test_launch_sites,
  test_devin_launch_gate, test_devin_probe_strict, test_session_control, test_marker_forgery,
  test_limit_gate, test_cloud_gate, test_devin_alias_resolution, test_model_selection_parity,
  test_cost_disclosure, test_escalation_classify, test_session_send_verify, test_managed_send,
  test_p56_billing, test_devin_free_guard, test_devin_catalog_free_tier, test_opencode_lane,
  test_heartbeat_autoarm, test_accounts, test_cleanup_manifest.
- Before/after proofs:
  - `test_spend_r2` against the 06b90b1 engine: 5 passed, 14 failed.
  - test_spend_attack send-model rows with the gate call removed: 4/4 fail.
  - test_spend_lib_failclosed symlink rows on 06b90b1: `syntax` and `nocaps` fail with the Mac signature.
  - F8 receipt on 06b90b1: `[free-tier]` banner plus "$0 cash".

`bash tests/conformance.sh`:
- First run: rc 1, 262 passed, 7 failed. Two of the failures were mine. The fanout preflight ran
  before fanout's own lane checks and also preflighted the local lane, which broke
  test_opencode_lane and test_heartbeat_autoarm; both were fixed in 1139bd8. Two were transient
  disk-pressure hits (6 GB free at that moment): test_accounts and test_cleanup_manifest. Both pass
  alone and in the final run.
- Final run, at 1139bd8: **rc 1, 266 passed, 3 failed, 14 skipped.** The 3 failures are
  test_harness_isolation, test_vocab_hygiene and test_parity_insource_refresh, the same uid-0
  failures documented in round 1, which also fail on base.

### What remains unproven (round 2)

- Not run on macOS or Git Bash. The symlinked-path rows reproduce the Mac loader failure on Linux.
  The `unread` row still skips as root here, because chmod 000 stays readable.
- F18: the ancestor walk uses `/proc/<pid>/ppid` (Git Bash/MSYS) or `ps -o ppid=` (macOS/Linux).
  If neither works, marker-only consent fails closed and the job asks with its own EVENT/NEXT. The
  forwarded-flag path is unaffected. A process that fakes a supervisor (writes its own pid and a
  meta.json, then runs the engine as its child) can still self-consent. That is no stronger than
  passing `--spend-ok`. The token is not stored as a hash.
- F3 maps only `/model`. No lane in the engine drives another typed model-switch command; Devin's
  picker is Meta-m, which `session send` cannot type.
- The factory's command-level `--spend-ok` keeps round 1's first-task bind for tasks that carry no
  consent of their own.

### Open questions (decided by the lane, round 2)

- Loop consent goes to each attempt as argv `--spend-ok`, not as a bg-style marker. Attempts are
  foreground children of the loop, and argv is the channel the engine already treats as explicit.
  Each child binds the consent to the first pair it gates, which is that rung's lane/model.
- `needs-approval` returns rc 3, the same as `blocked`, because a human must act. `loop verify` can resume it.
- F7 keeps `target` as the lane and adds `owner` and `job`. Re-targeting to the job id would change
  every EVENT line, and consumers grep those.
- The F16 hint uses kind `failed`, not `approval`: it is a typo, not a spend question.
- The brief says `task new`; this repo's command is `task add`, so the flag lives there.

### Needs from other lanes (round 2)

- Supervise owners: `_sv_read_range` could also match `.job` against the owned target set. The
  owner stamp already covers the reported case.
