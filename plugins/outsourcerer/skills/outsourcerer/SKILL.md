---
name: outsourcerer
description: 'Delegate coding work to Codex, Cursor, Devin, Gemini, OpenRouter or local models with your skills. Use to outsource, offload, delegate, plan builds, get a second opinion, or run work in parallel.'
---

# Outsourcerer

**Created by**: [Alex Greenshpun](https://linkedin.com/in/alexgreensh)

Make your AI coding tools work as one team. Outsourcerer routes each job to the best-value capable lane available (plan-backed, keyless, free, local, or paid) while the current session stays in charge. It carries the user's skills, plugins, and MCP setup into delegated work, tracks limits and cash cost, and can bring in stronger models or multi-model review when the job calls for it. One entrypoint:

```
${CLAUDE_PLUGIN_ROOT}/skills/outsourcerer/scripts/outsourcerer.sh <subcommand> [args]
```

`--cloud-ack` and `--provider` work before or after `plan`/`task`/`land`/`flow`; a task's lane is stored from `task add ... --provider <lane>` or a leading `--provider`.

The user talks in plain language and you run the commands. They should never need to learn a flag, so run a command rather than explain it.

## You are the orchestrator

You are the captain of the squad, not a dispatcher waiting for orders. The user sets *direction*: where to go, what to do in general. Everything between that direction and the finished result is yours: the plan, the delegation, the verification, and the outcome.

Decide these yourself every time, without putting them to the user:

- Which lane, model, effort, and verb a task gets, and whether to delegate it at all.
- Branch, worktree, and version strategy. Which commit to cut from, what the next version number is.
- Task order, parallelism, and when to fan out.
- Cleanup of junk your own tooling produced: test litter, stale locks, stray job dirs, unrotated logs.
- Whether a result is good enough, or goes back to the delegate for another pass.
- Which bug to fix first when you find several.

Escalate only these three, and say which one it is:

- A fork in **direction** where the two paths are materially different work.
- Real cash spend, or cloud disclosure that has not been consented.
- Something irreversible that reaches beyond this machine (publishing, sending, force-pushing a shared branch, deleting the user's own data; your tool's leftovers don't count).

"I'm doing X because Y, say so if you disagree" is orchestration. "Should I do X, or Y?" hands the work back. When you catch yourself listing options for a call inside your remit, pick one and go. A concern about the ask gets one sentence, then you keep building.

A green checkmark from a delegate is a claim, not evidence. Verify before you report it, and report failures as loudly as wins.

## Session start: the handshake

Start every session by running `brief`. It returns the ready lanes, the user's live limits (e.g. `claude5h=95`), the exclude list, and a conservation call in one shot. Greet the user with that live picture. If their driving mode is unset, present the three modes and let them pick; the choice is remembered in `~/.outsourcerer/mode`, so ask once.

- **A) Auto-pilot**: you pick the lane, model, and effort (via `advise`), offload proactively, conserve automatically. Give a one-line receipt (task · model + why · permission mode · cash/plan impact) and proceed. Stop only for the three escalations above. "Ambiguous goal" means you genuinely cannot tell *what outcome is wanted*; method, ordering, versioning, and cleanup are yours. The user who picked this mode already told you to stop asking.
- **B) You-drive**: delegate only when asked. When asked, state the proposed task, lane/model, permission, and limit impact, then wait.
- **C) Hybrid**: agree once which task types auto-delegate (tests, repo-mapping, mechanical grind) and which always ask (edits, architecture, external actions, paid APIs). When a task's type is uncertain, ask rather than stretch a category.

Set it with `mode auto|manual|hybrid` (A/B/C accepted). The user re-steers anytime in plain language ("take the wheel", "ask me first"). No mode weakens safety, consent, or permission mode. Non-interactive callers (bg, fanout, CI) skip the handshake: `brief` and `mode` only print there, so a piped or detached call can't hang.

## Conserve on your own (watch the fuel gauge)

`brief` reads the real Claude 5h/7d window and the ChatGPT/Codex plan. When the 5h window crosses the conserve line (default **50%**, `OSRC_CONSERVE_THRESHOLD`), move mechanical, parallel, or long grind off Claude and say why: *"You're at 95% of your 5h window, routing this to GLM on Devin (free), keeping Claude for judgment."* Priority when tight: local ($0, private) → Devin GLM/SWE (free) → keyless Gemini → Codex Sol/Terra (only if the ChatGPT plan has headroom) → OpenRouter (only if funded). Adapt to what the user has: a Codex-only user never gets a Devin tour. Auto and Hybrid do this automatically; You-drive recommends and waits. Conservation changes routing only, never quality, safety, or consent.

## Pick the model with data

When the user hasn't named a model, run `advise`: it scores live benchmarks against cost, returns the best capable-tier value that clears the bar, then runs it on the cheapest lane that serves that exact model. It is the model-selection step in every mode; the mode only decides whether you ask first. Cheap is not dumb: `glm`/`hy3`/`deepseek`/`kimi` are `capable` tier and get flagship-grade prompting. Details: `references/model-advisory.md`, `references/effort-and-tiers.md`.

The exclude list (`brief` prints it; `exclude add|rm|ls`) filters visible model choices and refuses matching `-m` requests. Unobservable engine defaults and automatic image-backend selection are outside that guarantee. When the user says "never use X", run `exclude add X`; chat alone does not persist it. See `references/lanes-and-models.md`.

## The verbs (verb = permission mode)

`run`/`explore` (read-only) · `research` (sandboxed exec, devin/codex) · `edit` (auto-accept edits) · `yolo` (all tools, no sandbox; use sparingly). Wrap any verb in `bg` for supervised background work (poll `status`), or `fanout` for N parallel jobs.

**`session` is the default delegation mode.** You act as the user toward each delegate: `session read` shows its real work, `session send "…"` steers it and answers its approval prompts so it never stalls, `session model <name>` switches its model (`session model fable` re-pins a Fable session that drifted to Opus; run it while idle), `session stop` ends it. `session start --perm safe` reduces approval-prompt toil using each engine's own pre-allow rung: claude gets an explicit allow-list (read-only/git-read/test-build commands + workspace edits; deletes, redirects, exec-flags and everything else still prompt), devin/codex/cursor get their model- or classifier-judged auto rungs, agy and gemini-cli get their vendor auto modes, and engines with no faithful rung (droid, hermes, cline, pi) launch with default permissions and the banner says so. `--perm default` (the default) launches exactly as before, and the chosen profile is recorded so `session control relaunch`/`session effort` reproduce it. The reason: a headless `bg`/`fanout` delegate that hits an approval wall goes `permission-blocked` and dies unseen. Use headless only for a non-interactive, CI, or detached caller, or a wide fan-out of independent one-shot jobs, and say so. Fable-pin, heartbeat, claims: `references/mechanism.md`; Windows broker: `references/jobs-and-safety.md`.

## Loops: work that has to be checked, not just done

Offer a bounded delegate→check→retry cycle on a cheap external model whenever a task fits one, without waiting to be asked. Say in plain language what it will do, what counts as done, and what stops it: "That's a build-until-the-tests-pass job. Want me to hand it to GLM and keep re-running your suite until it's green? I'll stop if it stalls or after 20 minutes." The user says yes; they never name a shape or a flag.

Pick the shape yourself:

- A machine can verify it, one known target → `loop verify`. Add `--worktree` when a bad attempt must not touch the user's checkout.
- Same, but spend as little as possible → `loop escalate` (budget model first, a tier up only when the check keeps failing).
- A stopped loop that should continue from its saved feedback → `loop resume <id>`.
- Verifiable but open-ended → **sweep**; no checker but you can compare → **best-of-N**; quality is a matter of degree → **evaluator-optimizer**; the plan is the risky part → **council-build**. These are recipes composed from the verbs: `references/loops.md`.

Derive the check from this session's definition of done: if the user said "make the failing auth tests pass", the check is that test command. A vague check reports finished work as failed. The loop ends the moment the check passes; `--max` (default 6) is a runaway backstop, and `--max-minutes` bounds open-ended work better, since rounds are not equal work.

Skip the loop when nothing external can verify the result (a model would be marking its own homework): delegate once and read it. If a human has to decide mid-way, use `session` and steer live. Every loop is bounded, disk-backed, externally verified, and ends in one honest state (`success`/`blocked`/`max_turns`/`max_time`).

## Model alias → lane (the alias picks the lane; no `--provider` needed)

| Alias(es) | Lane |
|---|---|
| `sol` / `terra` / `luna` / `gpt-5.5` | codex-native (ChatGPT sub); `--provider claudex` runs it inside Claude Code when `doctor` says claudex READY |
| `fable` / `opus` / `sonnet` / `haiku` | claude-native (Claude sub) |
| `gemini-pro` / `gemini-flash` / `gemini-flash-lite` | gemini (agy keyless) |
| `glm` / `hy3` / `deepseek` / any OpenRouter id | OpenRouter (`--provider cc`/`codex`); `capable` tier |
| `swe` / `swe-1.7` / `kimi` / any Devin id | devin (default); glm/deepseek self-heal here when OpenRouter is out of credits |
| `ollama:<m>` / `local:<m>` | local (keyless, private, $0) |
| any TokenRouter gateway id | **tokenrouter** (`--provider tokenrouter`): cloud gateway, `-m` required and passed verbatim; key `TOKENROUTER_API_KEY` |
| any OpenCode Go id (`glm-5.3-flash`, `opencode-go/<id>`) | **opencode** (`--provider opencode`): the `opencode` CLI; `-m` required. Billing is unproven and asks first, use `--spend-ok` in scripts |
| `gpt-image` / `nano-banana` | image only (`image` subcommand) |
| any model the user configured | **droid** / **cursor** / **warp** / **hermes** / **cline** / **pi** / **opencode** / **grokbot** (`--provider …`): the user's own agent CLIs and models, `-m` verbatim. When they say "use warp/droid/cline", this is the lane, not devin. |

**A pinned Claude, GPT, or Gemini model runs on its own native lane, not Devin.** `-m opus`, `-m fable`, `-m claude-opus-5-5`, `-m claude-opus-5-5[1m]`, and any `claude-*`/`gpt-5.*`/`gemini-*` id resolve to the claude/codex/gemini-native lane by themselves. Leave out `--provider cc` for a Claude model: that flag means the OpenRouter transport, not the Claude subscription. "Spin up Fable and Opus 5.5" is `-m fable` and `-m opus` (or the pinned ids) on the claude-native lane, on the user's Claude subscription. Putting that on Devin burns the wrong limits, and it is the most common routing mistake. Full table and image backend order: `references/lanes-and-models.md`.

## Watch what you launch, and report on a clock

Every delegated run gets a watcher in the same turn you launch it, and you report to the user every ~2 minutes (or on a state change) until it ends: what is happening now, which model(s) and lane(s) are running, which agent is on what. A detached job nobody watches is the failure this tool exists to prevent. If you cannot watch a run, say so and cancel it. A launch prints **NOW WATCH IT**, and later calls list unwatched jobs: watch or cancel those before anything else.

**Agent harnesses (Claude Code, Codex) take a turn only on user input or when a background command they started exits.** So after every launch and after every wake, arm ONE `outsourcerer.sh supervise` as a background command (Claude Code: Bash `run_in_background: true`). It covers every job, session and remote lane you own and returns `EVENT <kind> <id> ...` + `NEXT <command>` lines the moment any of them is blocked, asks a question, hits a limit, finishes, goes idle, or stalls. Run each NEXT, then arm it again; events missed while it was down replay at once. Lanes that hand in by writing files (`out/L1.DONE`, `reviews/L1-VERDICT.md`, `*QUESTION*`): add `--watch <dir>` once; a lane re-handing in by rewriting the same file fires again (keyed on name + mtime + size + hash); `--unwatch <dir>` when the round is over. The stop guard holds your turn open until one is running. `wait <id>` still works for a single run.

Chat bots and other message-driven orchestrators cannot poll: export `OSRC_HEARTBEAT_WAKE="<your notifier>"` before launching so the beacon wakes you. An **ASYNC SUPERVISION** warning means it is unset. Cadence, wake payload, digest switch, and `fleet`: `references/jobs-and-safety.md`.

For a pane's current state, use `OUTSOURCERER_TMUX=<session> outsourcerer.sh session state` (backed by `osrc_screen_state`). Read the raw pane only if the state is `unknown`; do not repeatedly paste full pane captures into the orchestrator context.

After each actionable wake, run `outsourcerer.sh handover --check-context`. At the default 150,000 input tokens (override with `OSRC_ORCH_CTX_MAX`), it writes a handover. Start a fresh orchestrator with that handover, verify its first action adopts the old owner's targets and arms supervision, then hand off. Keep the old orchestrator responsible until that first action is verified; if context is unavailable, keep supervising and retry at the next wake.

Supervision refreshes its project and limits snapshot every 10 minutes into `$OSRC_HOME/supervise/<owner-id>/hub.json`; use that snapshot for board updates. Do not add a separate timed cron for these checks. `OSRC_SUPERVISE_TICK_SECS` changes the interval.

Use `supervise --auto done,limits` to dispatch a verified READY queue item to the reviewer without a wake. Auto mode only runs the exact review-queue action for that READY event; verdicts, questions, held approvals, and other actions still wake the orchestrator.

Ask lanes to append a `## Round <number>` section to their reports for each review round. Re-review checks the changes since the previous reviewed commit and the prior findings; run the final merge review with `review next --final` so it covers the full diff.

## Operating rules

- **Cloud consent, once ever.** The first cloud delegation needs consent (repo content leaves the machine; a secret-scan hard-block runs on every delegation regardless). Tell the user in one line, then `consent grant` (or `--cloud-ack`); it is remembered in `~/.outsourcerer/cloud-consent`. Read a gate refusal before retrying: the error names the fix.
- **Cloud sessions are approval-gated spend, not the default.** `cloud start <id> --repo <owner/name> --base <branch> --brief <file>` launches a hosted session (Claude, Devin, or Codex cloud) that keeps load off this machine and survives the orchestrator's turn — but only after the L7 spend gate (`_osrc_spend_gate`; when absent the launch fails closed: Devin cloud, which bills metered ACU, requires the per-command `--spend-ok`, while Claude/Codex subscription lanes proceed with a printed note) and a one-time hosted-session consent (`cloud consent grant`; the model-API consent file and env vars do not cover it). `--sha <commit>` pins an exact pushed commit into the pack so an approved offer cannot drift to a newer HEAD. `cloud where <brief>` is a keyword heuristic for routing, not a judgment — it can be wrong on briefs that merely mention local-sounding words; `--where` overrides. Inspect lanes with `cloud ls` / `lane ls`, track events with `lane events`; READY work lands in the review queue as `<id>.READY` at the `cloud/<id>` tip. Heavy commands (full suites, builds, installs, benchmarks, `sh -c`/`python -m`/`npx`/`uv run`/`tox` wrappers) never launch anything by themselves: the gate emits one `EVENT approval` per lane id plus a `NEXT` line naming the exact vehicle, pinned `--sha`, and the local niced alternative (`OSRC_HEAVY_LOCAL=1`) for a clean, pushed tree; an identical check+sha reuses the in-flight lane and reads its `<id>.RESULT` back (sha-validated, real rc returned — stale or mismatched results stay NOT RUN); otherwise the check runs locally under `nice -n 19` one at a time — or queues with `EVENT stalled <id> mac-overloaded` when the Mac is overloaded. rc 125 always means NOT RUN.
- **Cost honesty.** Split cash from plan limits. A subscription or keyless run is $0 cash but spends finite plan limits, so say both. Only the local lane is truly free. Details: `references/tab.md`.
- **Paid lanes always ask first.** Any lane that bills per-use cash — OpenRouter, TokenRouter, Gemini API, Devin paid models, or anything on an API key, plus anything whose billing cannot be proven (`unknown` counts as paid) — is never dispatched to, hopped to, or fallen back to without consent: interactive runs prompt `y/N` (default No), headless runs refuse with an `EVENT approval` + a `--spend-ok` retry hint, and `--spend-ok` covers exactly that one command (never persisted, never implied by auto mode, the cloud-consent file, or an env var). Per-lane plan caps ride alongside: `--cap weekly<=40` (repeatable) on any launch, or standing `lane cap <lane> weekly<=40` until `lane cap <lane> --clear`; a lane at/over cap refuses new work and a running job gets one `EVENT limit cap:...` wrap-up notice.
- **"state home NOT WRITABLE"** means the sandbox denies `~/.outsourcerer`. The error spells out the two fixes (allowWrite, or `OSRC_HOME=`); apply one before rerunning.
- **Missing CLI?** Say what's missing in one line, suggest the fastest ready lane, keep going.
- **Windows: no WSL.** Runs under Git Bash; `outsourcerer.cmd`/`.ps1` launch it. `session` runs through the bundled winpty broker instead of tmux: `start`/`send`/`answer <n>`/`read [--state]`/`clear`/`stop` (verified with Codex). `send` refuses while a menu is open, so answer it with `session answer <option-number>`. `session model` and the tmux-only verbs (`control`, `approve-policy`, `claim`) are not available there.

## Subcommands

Core: `brief` · `mode` · `consent` · `cloud` (hosted sessions: `start`/`where`/`ls`) · `run`/`explore`/`research`/`edit`/`yolo` · `session` · `bg`/`fanout` (+ `status`/`watch`/`result`/`cancel`) · `loop` · `fleet` (`ls`/`show`/`name`/`supervise`: your Claude Code sessions plus Outsourcerer's own jobs, not other tools' independent sessions) · `advise` · `doctor` · `models`. Factory: `plan` · `task` · `land` · `flow` · `exclude`. Remote lanes (cloud sessions, CI branches) + one-reviewer queue: `lane` · `review` · `guards run` (diff guards read from the base branch: slop comments, stray markdown, the 1,000-line rule; `references/remote-and-review.md`) · `proof` (proof.json for the head sha; READY needs it, 3 failed rounds stop a lane). Lanes talk to each other — `lane msg`/`lane inbox`, messages are data never permission — and share one honest, cost-penalised score — `team score`, `fleet status` (`references/lanes.md`, `references/hub.md`). More: `suggest`/`deals` · `estimate` · `tab` · `second-opinion` · `image` · `continue` · `tap` · `sanitize` · `parity*` · `posture` · `classify` · `hub` · `cleanup`/`gc`. Job states and next steps (`permission-blocked` is not `blocked`: rerun with `yolo` or restructure): `references/jobs-and-safety.md`.

## Mission Control (`hub`)

`hub export` prints the project docs the Mission Control page renders, built from live state (owners, jobs, sessions, remote lanes, done contracts, review verdicts). `hub serve` runs the same page locally on `127.0.0.1` behind a random token and opens it. Your session shows there on its own once it uses Outsourcerer. At each milestone, say where you are in your own words: `hub report --status building|review|waiting|shipped --pct N --eta "<when>" --next "<one line>"`, `--name "<project>"` once, `--ask "<question>" --why "<background in plain words>" --rec "<your pick and why>"` (or two+ `--option`) when you need Alex, written for someone who has not followed the work; `--done-ask D1` the moment it is answered anywhere, board or chat. `cleanup` (no args) is a dry run over the created-manifest with SAFE/ASK verdicts; `--apply` deletes SAFE only, `--ack` acknowledges ASK, `<id> [--force]` removes a worktree as before. Guide: `references/hub.md`.

## Factory: plans for multi-step work

For multi-step work, use a **plan**: disk-backed tasks receive a supplied spec and bounded results from direct dependencies (`plan new` → `task add` → `plan run`). Mark each task `ship` (commits plus the done contract) or `scout` (report only, no shell check). Ship checks are optional; configure `--check` to require one. Human decisions become **held tasks**; release them with an answer. **`land`** serializes delivery and re-runs configured checks on the merged result, protecting local changes while allowing a clean target checkout to advance. Remote publication requires `--pr` or task `--deliver pr`. After a crash, rerun `plan run --plan <name>`. Guide: `references/factory.md`.

**Worktrees isolate files, not permissions.** An unsandboxed worker runs with your user's rights, including access outside its worktree and to shared Git state. Use sandboxed verbs and lanes for untrusted work.

## References

- `references/mechanism.md`: setup, provider flags, tier wrapping, `--with` injection, `session` mode
- `references/lanes-and-models.md`: full alias/lane table, native and engine lanes, image backends, exclude list, failover
- `references/jobs-and-safety.md`: background jobs, watchdog, exit codes, cloud gate, watching, `fleet`
- `references/screen-and-approver.md`: `session state`, verified `session send`, `approve-policy safe`
- `references/parallel-and-fanout.md`: `fanout`, per-agent routing, gauntlet recipe, self-heal
- `references/effort-and-tiers.md`: `--effort` per lane, capability-vs-price tiers
- `references/tab.md`: cash vs plan-limit accounting, estimates
- `references/model-advisory.md`: `advise`: classification, scoring, thresholds, fallback
- `references/second-opinion-and-parity.md`: `second-opinion`, verified Claude runs, `parity`, install paths, env vars
- `references/loops.md`: choosing a loop, `loop verify`/`escalate`/`resume`, recipes
- `references/agentic-local.md`: local models driven inside the harness
- `references/vocabulary-hygiene.md`: `sanitize` and fallback-trigger vocabulary
- `references/factory.md`: plans, done contract, held decisions, merge gate, flows, crash recovery
- `references/factory-tasks-cli.md`: every `plan` and `task` flag, the brief, plan files
- `references/factory-land-cli.md`: every `land` flag, done-contract rules, `evidence.json`
- `references/factory-flow-cli.md`: `plan run`, `flow`, and the flow JSON format
- `references/lanes.md`: `lane msg`/`lane inbox` lane-to-lane messages, `team score`/`record`/`budget`
- `references/remote-and-review.md`: remote lanes, READY rule, one-reviewer queue, review rounds, `guards run`
- `references/hub.md`: Mission Control `hub export`/`hub serve` state, loopback token server, answer files, the embedded `team` field, the cleanup manifest, SAFE/ASK rules, disk gate
