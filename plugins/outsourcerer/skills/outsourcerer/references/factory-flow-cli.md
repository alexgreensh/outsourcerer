# Factory: `plan run` and `flow` (scheduler + flows)

Source: `scripts/factory-flow.sh`. Tests: `scripts/tests/test_factory_flow.sh`.

## `plan run [plan | --plan name] [--max-parallel N] [--once] [--interval S] [--auto-land] [--max-minutes M] [--setup CMD]`

Drives a plan until it is finished or needs you. Each pass ("tick") does two things:

1. **Check running work.** For each running task, read its job the same way `wait` does.
   - Claimed but no job recorded yet: a launch is in flight, so it is left alone (never started twice) for
     `OSRC_FACTORY_LAUNCH_GRACE` seconds (default 300). After that, a job whose `task_ref` names the task is adopted
     (its launcher stopped before recording it); with none, it counts as a failed attempt ("never launched").
   - A job that never got a worker (no status, or launching/running with no process) for `OSRC_FACTORY_JOB_STALE_SECS`
     (default 900) counts as failed, so nothing waits forever.
   - Job finished well: the pass that moves the task running -> verifying runs the done check (`land`'s done
     contract); a task someone else is checking (a `task done`, another driver) is left to them unless that checker
     is provably dead (including a process-identity mismatch) OR its `verifying_at` timestamp (epoch seconds) is older
     than `OSRC_FACTORY_VERIFY_STALE_SECS` (default 900). Ownership is recorded as `verifying_pid`,
     `verifying_start` and `verifying_at`, and cleared when verification ends. Pass = done. Fail = counts as a failed attempt.
   - Job failed (or its worker died): if attempts remain (`retries`, default 1), the task is reset the way
     `task retry` does it and `.result` becomes "previous attempt failed because ...", which the next brief shows
     under "Earlier attempt". Otherwise the task is failed with the reason (the task store wakes the heartbeat).
   - How it retries depends on why it failed (`.last_fail_class`):
     - **work** (the done check said no, or nothing more specific): next model, with the reason. "Next model" here
       and below means the next one in the task's `fallback` list; a task without one keeps its model.
     - **transient** (a claimed worker that never appeared, network, rate limit, 429/5xx): same model, told it was not the work. A second
       transient failure in a row moves to the next model.
     - **model** (unknown model, empty answer, quota, auth, a launch the lane refused): next model.
     - **too_big** (timeout, wedged, stalled, context or output limit): same model, told to finish and verify the
       smallest piece it can and list the rest under OPEN ITEMS.
     - **too_big** twice in a row is held for you to re-plan (split the task, or answer to try once more), even on the
       last attempt. **model** twice in a row is held the same way while retries remain; out of retries it fails.
   - Held decisions with a default (`task hold --default ... --until ...`) whose deadline has passed are released
     with that default at the start of each pass, exactly as if you had answered. While such a deadline is still
     ahead and nothing else can move, `plan run` waits for it instead of stopping (within `--max-minutes`); `--once` stops (exit 3) and
     names when the default applies.
   - Job blocked (worker needs input): the task is held for you, with a wake event and the exact command
     (`task release tX --answer "..." --plan p`; a new worker starts with your answer).
   - A captain's decision or a land step found running a worker (someone ran `task start` on it) is held: a
     worker's output never completes a decision or a land.
2. **Start ready work**, up to `--max-parallel` (default 3) at once, counting what is already running.
   - A launch failure counts as a failed attempt and is retried within the task's `retries`.
   - A brief too thin to act on is held before any worker starts, without using an attempt: a task with no prompt
     or title, or a hand-added ship task (not a flow stage) with no spec, no check, no dependency and no captain's
     answer. Release it with the missing detail as the answer.
   - Model: a flow task keeps its stage's model list (`fallback`). At dispatch a model now on the exclude list is
     skipped for the next allowed one; each retry moves to the next allowed model.
   - A decision or land that finishes in a pass frees its dependents in the same pass.
   - Past `--max-minutes`, no new check, land or launch starts.

After each pass it prints one line with the four buckets:
`[plan tick 3] Captain's Call: 1 (t4) | Landed/Done: 2 | Underway: 1 (t3) | Next: 1 ready (t5), 2 waiting`

It stops with one plain line saying why:

| exit | meaning |
|---|---|
| 0 | all tasks are done or canceled, with no unresolved landing error; also an empty plan |
| 3 | nothing else can move: held or failed tasks, blocked dependencies, or landing errors need attention |
| 2 | time cap (`--max-minutes`, default 240) reached; running jobs keep going, run `plan run` again to resume |
| 124 | `--once` finished its single pass with work remaining, including ready tasks even if no job is running |
| 4 | another `plan run` is already driving this plan (nothing was done) |
| 1 | error |

- `--once`: one pass, for the heartbeat or an orchestrator turn.
- `--interval`: seconds between passes, default 30. `--max-parallel`, `--interval` and
  `--max-minutes` require positive whole numbers.
- `--auto-land`: land each plain build (ship) task through the merge gate as soon as it is done. Builds made by a
  flow are never auto-landed: the flow's own land stage lands them after their review (council-build), or the
  captain lands the winner after the pick (best-of-n). A failed or conflicted auto-land preserves
  the build's state: a done build stays done. The reason goes in `land_error` with `land_error_at`,
  a wake is sent, and the stop line lists `land tX --plan p`. Cancellation or a separate hold still wins.
- `--setup CMD`: the default command `land` runs in the clean merged checkout before the check (for example
  `npm ci`). A land stage's own `setup`, then the build task's `setup`, win over it. Passed only to a `land` that
  supports `--setup`. A failed land records a separate landing error; a flow's land stage may be held
  while the build stays done.
- Only one `plan run` can drive a plan at a time (lock at `plans/<plan>/run.lock`). A lock left by a crashed run is
  taken over automatically, under a second guard lock and only if its owner record is unchanged, so a slow taker
  never removes a fresh lock. A run that cannot record itself as the owner (disk full) refuses to start.
- Ctrl-C / SIGTERM stop at once (the wait between passes is interruptible), release the lock and put back the
  caller's own INT/TERM traps. Running jobs keep going.
- Wake events: task held and task failed come from the task store on the state change (one each, never doubled);
  `plan run` adds "plan finished" (once per finished state, not every pass).

## `flow ls | show <name> | run <name> [--plan p] [--var k=v ...] [--repo path] [--dry-run]`

A flow is a reusable recipe of tasks. `flow run` turns it into tasks in a plan, then you run `plan run <plan>`.

- `--plan`: plan to add to; created if missing. Default: a new plan named `<flow>-<date>-<time>`
  (it becomes the current plan if there is none).
- With no `--plan`, the generated name is always a new plan (`-2`, `-3`... if two runs share a second).
- `--repo`: git repo for build tasks (default: the repo you are in). A flow that builds code refuses to run without one.
  Adding to an existing plan with a different `--repo` is refused.
- All or nothing: the flow is validated and expanded in full first; if adding a task fails part way, the tasks this
  run added are removed. A plan the run created stays, empty; remove it with `plan rm` if unwanted.
- `--var k=v`: fill a flow variable. Missing required vars and unknown names (typos) are refused before anything is written.
  Values are inserted as plain text: quotes, `$( )` and backticks are never run. (The `check` var IS a shell
  command by design: the done check runs it in the task's worktree.)
- `--dry-run`: show the tasks it would add, write nothing.

Built-in flows (`references/flows/`); your own in `$OSRC_HOME/flows/<name>.json` override them by name:

| flow | stages |
|---|---|
| `council-build` (`--var setup=...` for land) | two advisors on different frontier families (sol, opus) -> synthesize (opus) -> build (glm-5-2, then swe-1-7, kimi-k3) with `check` -> fidelity review (sol, must say VERDICT: PASS) -> land |
| `spec-build` | spec (opus) -> plan (sol) -> build (glm-5-2...) -> verify against the spec (sol, VERDICT) |
| `best-of-n` | `--var n=3` candidates built in parallel on different models -> compare (sol) -> captain picks |

Models respect the exclude list: a stage tries its model, then its fallbacks, skipping excluded ones. If all are
excluded the task gets no model and the router picks (which also respects the list).

## Flow file schema

```json
{"name": "x", "description": "...",
 "vars": {"goal": "required", "check": "optional", "n": {"default": "3"}},
 "stages": [
   {"id": "build", "title": "Build {{goal}}", "shape": "ship", "verb": "edit", "deps": ["plan"],
    "model": "glm-5-2", "fallback": ["swe-1-7"], "check": "{{check}}", "setup": "npm ci", "prompt": "...", "retries": 1},
   {"id": "cand", "repeat": "{{n}}", "models": ["glm-5-2", "swe-1-7"], "prompt": "candidate {{i}} of {{n}}", "shape": "ship", "verb": "edit"},
   {"id": "review", "deps": ["build"], "verdict": true, "model": "sol", "prompt": "... end with VERDICT: PASS or VERDICT: FAIL - why"},
   {"id": "decide", "deps": ["review"], "hold": true, "title": "Captain decides"},
   {"id": "land", "land": "build", "deps": ["review"]}
 ]}
```

- `deps` name earlier stages only (no cycles). A dep on a repeated stage means every copy.
- `repeat` (1-10) makes copies `<id>-1..N`; `{{i}}` is the copy number, `{{n}}` the count; `models` rotates per copy.
- `hold: true`: a decision for the captain. Created as todo with `hold_after_deps: true`; once its deps are done the
  scheduler holds it and wakes you. Answer with `task release <tid> --plan p --answer "<decision>"`. With no prompt it is a pure gate
  (stored as `gate: true`): it completes with your answer as its result (`task release <tid> --plan p --answer "<decision>" --done` closes it at once). With a prompt, a worker runs with your answer in its brief.
- `verdict: true`: a reviewer. Trailing blank lines and `OSRC::DONE`, `OSRC::BLOCKED` or
  `OSRC::PROGRESS` marker lines are stripped from its job's `last.txt`. The last remaining line
  must match `^VERDICT: (PASS|FAIL)( - .*)?$`: bare PASS or FAIL, each optionally followed by
  ` - <reason>`. Put it outside code fences and before the required completion marker.
  `out.log` is never read. Missing, quoted, fenced (including an unclosed fence), or contradictory
  verdicts are ambiguous and hold the reviewer for you. A line containing both PASS and FAIL is ambiguous.
  - FAIL: the build it reviewed (its one ship dependency) goes back in line with the reviewer's reason in its brief
    (and its previous branch to start from), counted against that build's `retries`; then the review runs again.
  - A reviewer records the build revision in `reviewed_head`. Changing the build's `head_sha`
    resets that reviewer to todo; an approval of the old revision cannot authorize the new one.
  - Budget used up (or no single build to redo): the reviewer is held with the commands:
    accept anyway `task done tV --force --plan p`, one more redo `task release tV --answer "<what to fix>" --plan p`
    (your answer goes into the build's brief), or stop `task cancel tV --plan p`.
- `land: "<stage>"`: no worker runs; when its deps are done the scheduler lands that stage's task through `land`.
  The target must be one non-repeated build (ship) stage, landed by only this stage. Each try is counted
  (`land_attempts`); a failed land holds the stage. Resolve the build's landing error first, then
  `task release tL --plan p --answer "land again"`, or land by hand with `land tB --plan p` and
  `task done tL --plan p --force`. If the build itself is held, resolve and release it before the land
  stage. A land interrupted mid-way is tried again up to `retries + 1` times, then held.

Validation fails closed: a stage that is not an object, deps that are not a list, a non-text prompt/model/check, a
bad `retries` (0-10), a land stage that also holds/reviews/repeats, a hold+verdict stage with no prompt, or a flow
file the checker cannot read are all refused before anything is written.

## Fleet view

`bearings` and `rundown` add one line per active plan:
`plan p: 1 need you · 2 done · 1 underway · 3 next (1 ready)`. Finished plans are not shown (one jq pass over
all active plans; a plan whose finished marker is newer than its tasks is not even read).

## Extra task fields (written by flows, kept by the task store)

`hold_after_deps`, `gate`, `land_target`, `require_verdict`, `fallback`, plus the scheduler's own bookkeeping
(`verdict_failed`, `reviewed_head`, `prompt_orig`, `attempt_base`, `land_attempts`, `land_started_at`,
`land_error`, `land_error_at`, `verifying_at`, `verifying_pid`, `verifying_start`); it reads the task store's
`claimed_at`, `attempt_token` and `launch_failed` when present. Tasks are created through the task store's
`_task_new`, in stage order (deps always exist first). See the header of `factory-flow.sh`.
