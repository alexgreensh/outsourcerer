# The software factory (plans, tasks, flows, landing)

For the user and for the orchestrating agent. A plan is a task graph kept on disk, outside anyone's
head. Workers pick up ready tasks, each one gets a bounded brief, finished work is
checked against a done contract, and `land` delivers it through a serialized merge gate.

Contents: when to use a plan · a first plan in six commands · lifecycle · how context flows · the done
contract · held decisions · the merge gate · flows · crash recovery · the exclude list · where the flags live

Every command below is `outsourcerer.sh <subcommand>`. Flag details live in the CLI references,
`references/factory-*-cli.md`.

Worktrees isolate files, **not security permissions**. A worker on a lane without an OS sandbox
runs with your user's rights, including access outside its worktree and to shared Git state.
For untrusted work, use sandboxed verbs and lanes; a worktree alone is not a security sandbox.

## When to use a plan, and when not to

- **One job, no follow-up:** delegate it the usual way (`session`, `bg`, `edit`). A plan adds nothing.
- **Several steps where later steps need earlier results:** use a plan. It survives the session, it
  hands each worker the results it depends on, and it can be resumed by anyone, including a new
  orchestrator session that has never seen this conversation.
- **A human has to decide something mid-way:** use a plan with a held task. The decision becomes an
  item in the graph, so it cannot get lost in chat scrollback.
- **Several parallel edits to one repo:** use a plan. Each ship task works in its own worktree, and
  the merge gate lands them one at a time with the check re-run on the merged result.

## A first plan in six commands

```
outsourcerer.sh plan new auth-retry --goal "Retry failed auth calls with backoff" --repo .
outsourcerer.sh task add "Map every auth call site" --shape scout --verb research
outsourcerer.sh task add "Add backoff to the auth client" --shape ship --verb edit \
    --deps t1 --check "npm test -- auth"
outsourcerer.sh task add "Review the diff for missed call sites" --shape scout --deps t2
outsourcerer.sh plan run --max-parallel 2
outsourcerer.sh land t2
```

`plan run` starts t1, waits for it, hands its findings to t2, runs the test command on t2's branch,
then starts t3. When everything is done it stops and prints a summary. `land t2` merges the change.

## Lifecycle

1. **`plan new <name>`** creates the plan and makes it current, so later commands can skip `--plan`.
   `plan ls`, `plan show`, `plan use <name>` and `plan rm <name>` manage plans.
2. **`task add`** adds a step. Give each one:
   - a **shape**: `ship` (it changes code and must commit) or `scout` (it reports, never commits);
   - **deps**: the task ids it waits for (`t1,t2`);
   - a **spec** file when there is a written spec or plan to follow;
   - a **check** command that proves the work is done (tests, build, linter);
   - optionally a verb, a model, a provider, and how many retries it gets.
3. **`plan run`** is the scheduler. Each tick it reconciles running tasks against their jobs, then starts
   ready tasks up to `--max-parallel` (default 3). `--once` runs a single tick, which is the shape to use
   from a heartbeat or an orchestrator that takes turns. `--auto-land` lands plain ship tasks as they pass
   (a flow's builds land through its own land stage, after review). Exit 4 = another `plan run` already drives it.
4. **Held decisions** stop the line on purpose (see below). Release them with an answer and the plan
   moves on.
5. **`land <task>`** takes a finished ship task through the merge gate onto the target branch.

Task states: `todo`, `running`, `verifying`, `done`, `failed`, `held`, `canceled`. Two more are worked out
on the fly and never stored: **ready** (todo, every dep done) and **blocked** (todo, waiting on a dep that
is not done). A dep that failed or was canceled blocks everything after it, and `plan run` says which.

Manual control, when you need it: `task ls`, `task show <tid>`, `task ready`, `task start <tid>`,
`task hold <tid>`, `task release <tid>`, `task done <tid>`, `task fail <tid>`, `task cancel <tid>`,
`task retry <tid>`.

Each tick prints four buckets: **Captain's Call** (held or failed, needs you), **Landed / Done**,
**Underway** (running), **Next** (ready or blocked).

## How context flows

Every task gets a `brief.md`, written just before it starts and saved at
`$OSRC_HOME/plans/<plan>/tasks/<tid>/brief.md`. It carries the task handoff in addition to the
repo and the lane's normal instructions. Briefs up to 16,384 bytes are inlined by default
(`OSRC_BRIEF_INLINE_MAX`); larger briefs are passed by file path, which the worker must be able to read:

1. the plan goal, one line at the top;
2. the task prompt;
3. **Spec**: the spec file's contents (or its path, if it is over 64KB);
4. **Done when**: the check command and the rules for its shape;
5. **Inputs from finished work**: up to 12 direct deps by default (`OSRC_BRIEF_MAX_DEPS`), each with
   a result summary capped at 2,000 characters, output capped at 4,000 characters, its branch and
   head commit if it shipped code, a full-report path, and any answer on that dependency;
6. **Decision from the captain**: this task's own released-hold answer, if any.

The repo is the shared memory. Ship tasks leave commits on named branches, scout tasks leave reports
under the plan folder, and the next brief points at both. Nothing depends on the orchestrator
remembering what happened three tasks ago.

`spec-build` passes the spec scout's report to the plan scout, then both reports to the builder
through dependency briefs. Its scouts do not edit files; it neither creates `SPEC.md` nor sets
`--spec`. If you already have a spec file, attach it to a manually added task with `--spec`.

## The done contract

A worker saying "done" is a claim. The factory checks it and writes the verdict to
`tasks/<tid>/evidence.json`.

- **Scout:** the job finished cleanly and produced a non-empty result. The result is copied to
  `tasks/<tid>/report.md`. A scout never needs commits and does not run its shell `check`.
- **Ship:** all of these, or it is not done:
  - the job finished cleanly;
  - the task branch has at least one commit beyond where it started;
  - the worktree has no uncommitted tracked changes;
  - the head commit sits on a named branch in the main repo, not only on a detached worktree HEAD;
  - the check command, if set, passes in the worktree;
  - the diff carries no live secret (the same scan every delegation already runs).

The evidence file records the job, base and head commits, the check's exit code and output tail, the
secret scan result, and a one-line reason. A failed ship task with retries left goes back to `todo` with
the failure note added to its next brief. The retry depends on why it failed: a launch or network blip
retries the same model, a model or lane problem moves to the next model on the task's list, and a run that timed out or wedged is
asked for a smaller, verifiable piece. The same model or too-big failure twice in a row comes to Captain's
Call for a re-plan. Out of retries, it goes to Captain's Call.

Before any worker starts, the brief itself is checked. A ship task you add by hand needs a spec, a check,
a task it builds on, or a captain's answer (flow stages follow their template), so the worker knows when it is done. A brief that fails this is held with the
reason, and no attempt is spent.

## Held decisions

Some calls belong to a person: pick one of three candidates, approve a risky migration, choose an API
shape. Make that a task.

```
outsourcerer.sh task hold t4 --reason "Pick the winning candidate"
outsourcerer.sh task release t4 --answer "Use t2, it keeps the public API unchanged"
```

A hold can carry a default for when nobody answers in time, so an unattended plan does not stall overnight:

```
outsourcerer.sh task hold t4 --reason "Postgres or SQLite?" --default "SQLite" --until +2h
```

`--until` takes `+30m`, `+2h`, `+1d` or a UTC time like `2026-10-24T09:00Z`, and is required with `--default`.
If the deadline passes with no answer, `plan run` releases the task with the default, marks it as defaulted in
`task show`, and keeps going. While only that deadline is left, `plan run` waits for it, up to its
`--max-minutes` cap (240 by default); after that, the next `plan run` applies it. Answering first always wins.

A flow stage with `"hold": true` becomes a held task as soon as its deps finish. `plan run` raises a wake
event when a task is held or fails, so an async orchestrator gets pinged (`OSRC_HEARTBEAT_WAKE`). The
answer appears in the released task's own "Decision from the captain" section, and in its direct
dependents' "Inputs from finished work". It is not automatically copied to every later task.

For the orchestrating agent: a decision you are allowed to make is not a hold. Holds are for the three
escalations in SKILL.md (direction forks, real cash, irreversible outside actions) and for anything the
user asked to sign off.

## The merge gate (`land`)

```
outsourcerer.sh land t2                       # merge into the plan's base branch
outsourcerer.sh land t2 --dry-run             # do everything except move the branch
outsourcerer.sh land t2 --into release/1.4    # pick the target branch
outsourcerer.sh land t2 --pr                  # push the branch and open a PR instead
```

What it does, in order:

1. Refuses unless the done contract passes.
2. Takes the repo's merge lock, so lands into one repo happen one at a time. This lock is the queue.
3. Builds a fresh integration worktree at the target's tip and merges the task branch there (no
   fast-forward, message `land(<plan>/<tid>): <title>`).
4. Re-runs the check, when configured, on the merged result. Two branches can each pass alone and break together; this
   step catches that.
5. Green: moves the target forward and records the evidence. It only does that when your checkout of
   the target is clean or the target is not checked out at all. It never overwrites your work.
6. Red or conflicted: leaves the target untouched, records `land_error` and `land_error_at`, and
   keeps the build's state (a done build stays done). Resolve the reported issue before retrying land.

Remote publication requires `--pr` or a task created with `--deliver pr`. Task `--deliver branch`
verifies and records branch delivery without merging; `local` uses the merge path above.
`land` also accepts a plain job id for work started outside a plan.

## Flows

A flow is a ready-made plan shape in `references/flows/<name>.json`. `flow run` turns its stages into
tasks in a plan, fills in the variables, and leaves the plan ready for `plan run`.

```
outsourcerer.sh flow ls
outsourcerer.sh flow show council-build
```

**council-build**: two advisors on different frontier models argue the approach, a third scout
synthesizes the plan, a build task ships it against your check, a fidelity review compares the result to
the plan, then the scheduler's land stage lands it automatically. Use it when the plan is the risky part.

```
outsourcerer.sh plan new rate-limit --repo .
outsourcerer.sh flow run council-build --plan rate-limit --var goal="Add per-user rate limiting to the API" \
    --var check="make test"
outsourcerer.sh plan run --plan rate-limit
```

**spec-build**: spec scout, then plan scout, then a ship task, then a verify scout. Use it when the work
starts from a vague ask and needs to be pinned down in writing first.

```
outsourcerer.sh flow run spec-build --plan export-csv \
    --var goal="Let users export any report as CSV" --var check="pytest tests/export"
outsourcerer.sh plan run export-csv
```

**best-of-n**: N ship candidates in parallel, a scout compares them, then a held task waits for you to
pick the winner. Use it when there is no single right answer and comparing is easier than specifying.

```
outsourcerer.sh flow run best-of-n --plan onboarding-copy \
    --var goal="Rewrite the onboarding screen copy" --var n=3
outsourcerer.sh plan run onboarding-copy
outsourcerer.sh task release t5 --plan onboarding-copy --answer "Candidate 2" --done
outsourcerer.sh land t2 --plan onboarding-copy
```
With `n=3` the plan gets t1 to t3 (candidates), t4 (compare) and t5 (your pick).

Flows are plain JSON (`name`, `description`, `vars`, and `stages` with `id`, `title`, `shape`, `verb`,
`model`, `deps`, `prompt`, `check`, `hold`). Copy one to make your own.

## Crash recovery

All plan state is on disk under `$OSRC_HOME/plans/<plan>/`: `plan.json`, one JSON file per task, each
task's brief, evidence and report, and an append-only `events.jsonl`. Task JSON updates are atomic
and serialized under the plan lock; briefs, reports and logs are separate artifacts.

If the orchestrator session dies, the laptop sleeps, or `plan run` gets killed: run `plan run` again. It
reconciles first. Tasks whose jobs finished while nobody was looking get checked against the done
contract, dead jobs get retried or sent to Captain's Call, and only then does it start new work. A new
session picks up a plan with `plan use <name>` and `plan show`.

## The exclude list (issue #45)

```
outsourcerer.sh exclude add fable
outsourcerer.sh exclude ls
outsourcerer.sh exclude rm fable
outsourcerer.sh exclude clear
```

A model you exclude stays excluded across sessions. The list lives at `$OSRC_HOME/exclude`, and the
`OSRC_EXCLUDE_MODELS` environment variable adds to it for one shell. Entries can be an alias, an exact id
or a family: `fable` covers `claude-fable-5`, `claude-fable-5-1` and `anthropic/claude-5-fable`.

It filters visible text-model choices: an explicit `-m` (refused, with a line saying how to undo it),
`advise`, failover, OpenRouter escalation, `second-opinion` (it falls back to the next allowed premium
model), loops, crews, fanout, sessions, and plan tasks. `brief` prints the list at every session start,
so a new orchestrator sees it before it routes anything.

Unobservable engine defaults without `-m` and automatic image-backend selection are outside this
guarantee. Excluding an old version does not necessarily exclude its bare family alias; exclude the
family itself to block all its versions. Exact matching rules: `references/lanes-and-models.md`.

## Where the flags live

`outsourcerer help` lists the factory commands. For their full syntax use these CLI references,
plus `plan run --help`, `flow --help` and `land --help`.

- `references/factory-tasks-cli.md`: `plan` and `task` subcommands and the data model.
- `references/factory-land-cli.md`: `land` and the done contract.
- `references/factory-flow-cli.md`: `plan run`, `flow`, and the flow JSON format.
- `exclude` is covered above and in `lanes-and-models.md`.
