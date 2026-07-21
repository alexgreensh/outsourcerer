# Loops — bounded delegation cycles

A loop = **act → verify (external) → repeat until done or a cap fires.** Every loop ends in exactly one
honest state: `success` · `blocked` · `max_turns` · `max_budget`. State lives on disk. No loop runs
unattended-infinite. Verification is external to the model that did the work — tests/lint/build ideal, a
second model is the fallback, the model's own "I'm done" is never enough alone.

## Which loop is this? (pick before you build anything)

Two questions decide it. Answer them in order.

**1. Can a MACHINE tell you it worked?** A test suite, a linter, a build, a schema check, an exit code.

**2. Do you know how much work there is?**

| Machine can verify? | Amount of work | Use | Why |
|---|---|---|---|
| Yes | Known, one target | **`loop verify`** (built in) | The check is the judge. Delegate, run it, feed failures back. |
| Yes | Unknown / open-ended | **sweep** (until-dry) | You cannot set a sensible `--max` when you do not know how many there are; stop when rounds stop finding anything. |
| No, but you can COMPARE | Small | **best-of-N** | No oracle, but you can look at five and know which is best. |
| No, and quality is a matter of degree | Any | **evaluator-optimizer** | "Correct" is not binary. Score against a rubric and iterate on the score. |
| Not yet — the PLAN is the risky part | Large | **council-build** | The expensive mistake is building the wrong thing well. Argue it out first, then use `loop verify` for the build step. |

Two rules that override the table:

- **If nothing can verify it, do not loop.** A loop with no external check is a model marking its own
  homework in a circle. Use a single delegation and read the result yourself.
- **If a human must decide mid-way, do not loop.** Loops are for work you would otherwise babysit.
  Anything needing a judgement call belongs in `session`, where you can steer it live.

Cheapest correct answer wins: most real work is `loop verify`, because most real work has tests.

## The one built-in: `loop verify`
The mechanical 90% case — delegate, run a real check, retry with the failure fed back, on the cheapest
model. You (the orchestrator) only re-enter on `blocked` or when the cap fires.

```
outsourcerer loop verify -m glm --check "npm test" [--max 3] [--verb edit|yolo] "make the auth tests pass"
```
- Runs up to `--max` attempts (default 3). Each attempt delegates the task (mutating verb) with the last
  check output appended as feedback, then runs `--check`. Exit 0 → `success`.
- **Stall guard**: the identical check failure twice → `blocked` (not converging — surfaces instead of
  burning the budget). A delegate emitting `OSRC::BLOCKED` → `blocked`.
- Exit codes: 0 success · 2 max_turns · 3 blocked. Attempts + check output saved under
  `~/.outsourcerer/loops/<id>/`. The loop edits the tree it is run in, so for build loops run it from a
  worktree you created yourself if a bad attempt must not touch main. (A loop-level `--worktree` is a
  named future add: the loop would have to create the tree AND run the acceptance check inside it, or
  the check grades the wrong files. It is refused with that explanation rather than half-wired.)
- **Bounds, in order of what actually stops the loop.** The GOAL is `--check` passing; everything else
  is a runaway guard that only fires when the work is not converging:
  1. `--check` exits 0 → `success`. This is the real terminating condition.
  2. Same check failure twice → `blocked`. Not converging; surfaces instead of burning the budget.
  3. `--max-minutes` → `max_time`. Checked between attempts, so a run in progress is never abandoned
     half-done. Prefer this for open-ended work: three attempts at a one-line fix and three at a
     refactor are not comparable amounts of work, so a round count is a poor bound on its own.
  4. `--max` attempts (default 6) → `max_turns`. A backstop, not a target.
  There is deliberately **no money cap**: the default lane is a subscription lane that reports $0, so a
  dollar bound would never fire on the path most people use, while time and attempts always bind. Each
  attempt is a normal delegation and shows up in the Tab.
- **Write the check as the session's definition of done**, not a generic one. "The auth tests pass" is a
  goal; "tests probably pass" is not checkable, and a vague check makes a finished job look failed.

## The rest are RECIPES you drive (no engine, just compose the verbs)

### sweep (until-dry) — bulk find/fix with an unknown amount of work
Keep delegating rounds until **K consecutive rounds add nothing new** (default K=2) OR a budget cap.
Dedup findings against a file on disk, not in context.
```
seen=findings.md; dry=0
while [ "$dry" -lt 2 ]; do
  new=$(outsourcerer run -m glm "find the next batch of <X>; skip anything already in $seen")
  [ -z "$new_unique" ] && dry=$((dry+1)) || { append to $seen; dry=0; }
done
```

### best-of-N / tournament — no cheap way to verify, but you can compare
Generate N candidates in parallel on the cheap engine (disposable), then YOU rank and pick. Inherently
bounded — the safest shape.
```
outsourcerer fanout --max 4 -m glm -- "impl approach A" "impl approach B" "impl approach C"
# then: read each result, judge, keep the best.
```

### evaluator-optimizer — quality matters, "correct" isn't binary (copy, design, refactor)
generate → an advisor scores against an explicit rubric → refine. Stop when the score clears the bar OR
a round yields no improvement (diminishing returns).
```
draft=$(outsourcerer run -m glm "write <thing>")
loop: score=$(outsourcerer second-opinion "score this 1-10 against: <rubric>. <draft>")
      [ score >= bar ] && stop; draft=$(outsourcerer run -m glm "improve per: <critique>")
```

### council-build — debate → decide → build → verify → test → launch (the flagship composed loop)
Model-typed roles: advisors = frontier (sol/fable/opus), builder = capable-cheap (glm/hy3), tester =
YOU (the orchestrator). Any stage can BLOCK and route back.
1. **debate** — two frontier advisors argue via interactive `session`, each critiquing the other's last
   turn, M rounds, until the plan converges:
   ```
   outsourcerer session start -m sol      # advisor A
   outsourcerer session start -m fable    # advisor B
   # loop M rounds: session read A -> session send B "rebut A's plan: <A>" -> session read B -> session send A "..."
   ```
2. **decide** — you synthesize the winning plan (or the advisors converge) → write it to a plan file.
3. **build** — hand the plan to the cheap engine as a bounded verify-loop:
   `outsourcerer loop verify -m glm --check "<the tests>" "build per plan.md"` (from an isolated
   worktree if the attempts must not touch main).
4. **verify** — an advisor checks fidelity: `outsourcerer run -m sol "does this diff match plan.md? list gaps"`.
5. **test** — YOU run the real suite / exercise it. The builder never judges its own work.
6. **launch gate** — ship only when verify AND test pass; a failure routes back to build (or debate if
   the plan itself was wrong).

## Safety checklist (every loop, built-in or recipe)
- Hard iteration cap, always — the ENFORCED bound today (`--max` on `loop verify`; the round/candidate
  count on the recipes). · Spend is bounded by iterations × per-attempt cost and is visible in the Tab; a
  dedicated $-ceiling that stops mid-loop is a planned add, not yet enforced — treat the iteration cap as
  your budget control for now. · Stall detection (N no-change rounds → stop + surface). · External
  verification, never self-report. · A distinct `blocked` state that surfaces to a human. · Worktree
  isolation for build/sweep. · Never unattended-infinite — scheduled runs wrap a bounded shape, they don't
  remove the caps.
