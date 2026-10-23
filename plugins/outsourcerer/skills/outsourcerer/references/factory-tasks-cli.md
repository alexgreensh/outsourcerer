# Factory: plans and tasks (CLI reference)

A plan is a durable task graph that lives outside the orchestrator's head, under
`$OSRC_HOME/plans/<plan>/`. Each task is a JSON file; workers get everything they need from a
generated brief, so the orchestrator never relays context by hand. Needs `jq`.

## Contents

- Plans
- Tasks (`task add` options)
- States
- What `task start` does
- The brief (context handoff)
- Files
- Example

## Plans

| Command | What it does |
|---|---|
| `plan new <name> [--goal "..."] [--repo <path> \| --no-repo] [--base <branch>] [--no-use]` | Create a plan. Repo defaults to the git repo you are in (absolute toplevel); base defaults to its current branch. Becomes the current plan unless `--no-use`. Without a repo, ship tasks can be recorded but are refused at dispatch. |
| `plan ls` | All plans, `*` on the current one, task counts by state. |
| `plan show [name] [--json]` | Four buckets: **Captain's Call** (held + failed, with the release/retry command), **Done** (done, landed, canceled), **Underway** (running, verifying, with job id), **Next** (ready, and blocked with the blocking task and its state named). Then a `Dependencies` list (`t3 <- t1, t2`). |
| `plan use <name>` | Set the current plan (`$OSRC_HOME/plans/current`). |
| `plan rm <name> [--force]` | Delete a plan's records. Refuses while a task is running or verifying unless `--force`. Never touches git worktrees or branches. |
| `plan run ...` | The scheduler, provided by `factory-flow.sh`. If that script is missing, it stops with "plan run needs factory-flow.sh next to outsourcerer.sh". |

Plan names: letters, digits, `.`, `-`, `_`, up to 64 characters, not `current`, and no leading dot.

## Tasks

Every task command takes `--plan <name>`; without it the current plan is used.
`--provider <lane>` on `task add` is stored on the task. A leading `--provider` (before `task`)
works too and is stored when the task names no lane itself. `--cloud-ack` and `--provider` are
accepted before or after the `plan`, `task`, `land` and `flow` subcommands.

| Command | What it does |
|---|---|
| `task add "<title>" [options]` | Add a task; prints its id (`t1`, `t2`, ... allocated under the plan lock). |
| `task ls [--state s] [--json]` | Table: ID, STATE (derived: `ready`/`blocked` for waiting tasks), SHAPE, AFTER, JOB, TITLE. `--state` matches stored or derived state. |
| `task show <tid> [--json]` | Every field, the task's file folder, the last events. `--json` prints the raw task. |
| `task ready` | Ready tasks (`tid<TAB>title`), shallowest in the dependency graph first, then by id. |
| `task start <tid>` | Claim and launch one ready task as a background job; prints the job id. Refuses if the task is held, blocked (names the blocker), or already underway. A brief too thin to act on (no prompt or title; a hand-added ship task with no spec, check, dependency or captain's answer) is held instead, without using an attempt. |
| `task brief <tid>` | Build and print the brief a worker would get (also saved to `tasks/<tid>/brief.md`). |
| `task hold <tid> --reason "question" [--until "when"] [--default "answer"]` | Park a task for a human decision. Allowed from todo, verifying, failed (or re-hold). Raises a heartbeat wake event. `--until` takes `+30m`, `+2h`, `+1d` or `2026-10-24T09:00Z`. With `--default` (which needs `--until`), `plan run` releases the task with that answer once the deadline passes; `task show` marks it as defaulted. |
| `task release <tid> --answer "decision" [--done]` | Answer a held task. It returns to todo and the answer goes into its own brief and its dependents' briefs. `--done` closes it instead, with the answer as its result (for pure decision items like "pick the winning candidate"). |
| `task done <tid> [--result "..."] [--force]` | Run the done check (the done contract in `factory-land-cli.md` when `factory-land.sh` is present; otherwise a basic check: the job ended `done`/`done?` with a non-empty result). Passes through `verifying`; on failure the previous state is restored and the reason printed. On success a scout's output is copied to `report.md` and an empty result is filled with a short summary. `--force` marks done by hand without a check (also for tasks with no job). |
| `task fail <tid> [--reason "..."]` | Mark failed (stops a live job). Dependents stay blocked. Raises a wake event. |
| `task cancel <tid>` | Mark canceled (stops a live job). Dependents stay blocked. |
| `task retry <tid>` | Failed or canceled back to todo; clears job, worktree, branch, base/head, evidence; keeps history (`jobs`, `attempts`, last `result`). The next brief carries an "Earlier attempt" section with that result. |

For a flow reviewer with `require_verdict: true`, ordinary `task done` also requires a PASS
under the verdict rules in `factory-flow-cli.md`. FAIL or ambiguous output requires a new review
or an explicit `--force` override.

### `task add` options

| Option | Meaning | Default |
|---|---|---|
| `--prompt "..."` / `--prompt-file f` | What the worker should do. | the title |
| `--shape ship\|scout` | ship = changes code in its own git worktree and commits; scout = investigates and writes up, changes nothing. | ship if `--verb edit\|yolo`, else scout |
| `--deps t1,t2` (alias `--after`) | Must be done first. Only existing tasks, so the graph cannot loop. | none |
| `--spec <file>` | Spec handed to the worker (stored as an absolute path). | none |
| `--check "cmd"` | Optional command that must pass (exit 0) at the ship worktree root. Scouts skip shell checks even if this is set. | none |
| `--verb run\|research\|edit\|yolo` | How the worker is launched. | ship: edit, scout: run |
| `-m <model>` / `--provider <lane>` | Model and lane for the worker. | the normal routing |
| `--deliver local\|branch\|pr` | `land` merges locally, verifies and records the branch without merging, or pushes and opens a PR, respectively. | local |
| `--retries N` | Automatic retries the scheduler may spend. | 1 |
| `--hold "question"` | Create the task already held for a decision. | not held |
| `--flow <name> --stage <id>` | Provenance when a flow made the task. | empty |

## States

Stored: `todo`, `running`, `verifying`, `done`, `failed`, `held`, `canceled`.
Derived (never stored): **ready** = todo and every dependency done; **blocked** = todo with a
dependency not done. A failed or canceled dependency keeps its dependents blocked, and
`plan show` says it "needs the captain".

## What `task start` does

1. Atomically claims the task (todo to running, attempts + 1) under the plan lock. Two
   concurrent starts: exactly one wins.
2. Writes the brief.
3. Launches it through the normal `bg` path with the task's verb, model and provider, from the
   plan's repo. Ship tasks get `--worktree` pinned to the plan's base branch commit, so the task
   records `worktree = <repo>/.outsourcerer/worktrees/<job>`, `branch = outsourcerer/<job>`,
   `base_sha` before the job starts. A ship task in a plan without a repo is refused (fails
   closed rather than editing your checkout).
4. Records the job id on the task and writes `task_ref` (`plan/tid`) into the job folder.
   A launch that fails marks the task failed with the reason (details in `tasks/<tid>/launch.log`).

## The brief (context handoff)

`tasks/<tid>/brief.md` is the generated task handoff. It is inlined into the launch prompt up to
16,384 bytes by default (`OSRC_BRIEF_INLINE_MAX`); larger briefs are referenced by path, which
the worker must be able to read. The lane also supplies its normal instructions.

1. Title, plan goal, repo and base branch, task type.
2. `## Your task`: the prompt.
3. `## Spec`: the spec file pasted in (or its path when over 64KB, or a "missing" note).
4. `## Done when`: shape rules (ship: commit on your worktree branch, nothing uncommitted, no
   push/merge/PR, no secrets; scout: change nothing, final message is the deliverable), the
   check command, and "end with a short summary".
5. `## Inputs from finished work`: up to 12 direct dependencies by default (`OSRC_BRIEF_MAX_DEPS`),
   each with its title, shape and state, result summary capped at 2,000 characters,
   output (report.md, else the job's last.txt, trimmed to 4,000 characters
   with a visible marker), branch and head commit for ship dependencies, the path to the full
   report, and any captain decision made on that dependency.
6. `## Decision from the captain`: this task's own held question and answer.
7. `## Earlier attempt`: on a retry, what went wrong last time.

Decisions are included from this task and its direct dependencies, not every ancestor.
Dependencies beyond the cap are listed with paths for reading their full reports.

## Files

```
$OSRC_HOME/plans/current
$OSRC_HOME/plans/<plan>/plan.json
$OSRC_HOME/plans/<plan>/events.jsonl        {"ts","plan","task","event","from","to","note"}
$OSRC_HOME/plans/<plan>/tasks/<tid>.json
$OSRC_HOME/plans/<plan>/tasks/<tid>/brief.md | report.md | evidence.json | launch.log
```

A damaged task file is skipped with a warning (the rest of the plan still works); a damaged
plan.json still shows the tasks.

## Example

```bash
outsourcerer plan new login --goal "ship passwordless login"
outsourcerer task add "map the current auth flow" --shape scout -m glm          # t1
outsourcerer task add "build magic-link login" --shape ship --deps t1 \
    --spec docs/login-spec.md --check "npm test"                                # t2
outsourcerer task add "pick email provider" --hold "Postmark or SES?"           # t3
outsourcerer task release t3 --answer "Postmark" --done
outsourcerer task start t1          # prints the job id
outsourcerer task done t1           # after the job finishes
outsourcerer task start t2          # t2's brief now carries t1's findings + the spec
outsourcerer plan show
```
