---
name: outsourcerer
description: 'Interactive copilot that delegates grunt work to a cheaper or different engine while Claude orchestrates. Greets you each session with your live token limits and a driving mode (auto-pilot / you-drive / hybrid), and auto-conserves by routing work off your Claude window when it runs hot. Lanes: Devin (GLM/SWE-1.7), OpenRouter (GLM/hy3/DeepSeek), Codex, Claude, Droid, Cursor, keyless Gemini/Antigravity, plus image gen and a cost Tab. Works on Windows via Git Bash (no WSL). Triggers: outsource, offload, delegate, conserve tokens, use GLM/Devin/Codex/Droid/Cursor, or get a second opinion.'
---

# Outsourcerer

**Created by**: [Alex Greenshpun](https://linkedin.com/in/alexgreensh)

Delegate the work Claude would normally hand to its own subagents to a **Devin CLI model** instead. Default model is **`glm-5.2`** (currently a free lane on Devin), but the skill is fully model-agnostic, the user can pick any model, and you recommend free ones from the **live** list.

The single entrypoint is the helper script:

```
${CLAUDE_PLUGIN_ROOT}/skills/outsourcerer/scripts/outsourcerer.sh <subcommand> [args]
```

Global flags (`--provider`, `--cloud-ack`) are accepted anywhere — before or after the subcommand. Both orders work: `outsourcerer --provider cc run "task"` and `outsourcerer run --provider cc "task"`.

**Cloud consent, handled ONCE (never make the user relearn this).** The first cloud delegation needs a one-time consent (repo content leaves the machine; a secret-scan hard-block still runs on every single delegation regardless). The flow you drive: on the FIRST cloud delegation for a user, tell them in one line what leaves the machine and ask to proceed; on yes, run `consent grant` (or pass `--cloud-ack`, same effect) — it is remembered in `~/.outsourcerer/cloud-consent` and never asked again. `consent status|revoke` manages it. Never retry a gate refusal blindly: the error itself names the exact fix.

**If a run dies with "state home ... NOT WRITABLE":** the shell sandbox is denying `~/.outsourcerer`. Re-run the command with the sandbox disabled for this script, or add `~/.outsourcerer` to the sandbox allowWrite config — the error message spells out both. Don't relaunch the same command unchanged; nothing will run until the state home is writable.

## Interactive-by-default: establish the driving contract FIRST

**Every session where this skill activates starts with a short handshake — this is the default, not raw CLI.** Before recommending or dispatching anything, silently run `brief`. It returns three things in one shot: the lanes that are actually ready, the user's live session limits (e.g. `claude5h=95`), and a conservation recommendation. Read it, then greet the user with that live picture and, if their driving mode is unset, the three-mode menu below. Persisted choice is remembered (`~/.outsourcerer/mode`) — never make them pick twice.

**The three driving modes (present them in plain language, adapted to what `brief` found):**

- **A) Auto-pilot** — you pick the ready lane/model/effort for each task, proactively offload suitable work, and conserve tight windows automatically. Give a one-line dispatch receipt (task, lane/model, permission mode, cash/plan impact) and proceed. Still stop for: a new cloud-consent decision, a mutating/dangerous permission escalation, an ambiguous goal, or material unapproved cash spend.
- **B) You-drive** — never delegate unless the user asks. When they do, restate the proposed task + lane/model + permission mode + limit impact, then wait for the go-ahead. Don't turn routine work into background delegation just because it looks offloadable.
- **C) Hybrid** — agree ONCE on which task-types you may auto-delegate (e.g. tests, repo-mapping, mechanical refactors, parallel reviews) plus exclusions (edits, architecture, external actions, paid APIs). Auto-pilot only for clear matches; ask for everything else. If a task's type is uncertain, ask — never stretch an auto category.

Set the choice with `mode auto|manual|hybrid` (accepts A/B/C too). The user changes it anytime in natural language ("switch to you-drive", "auto-delegate my tests", "take the wheel") — confirm the change in one sentence. When no mode is set, the DEFAULT behavior is to present this menu and interact, never to silently run CLI (people get stuck when the tool assumes CLI-only).

**Capacity-aware conservation (be the co-pilot who watches the fuel gauge).** `brief` reads the user's real 5-hour/7-day Claude window and the ChatGPT/Codex plan. When the Claude 5-hour window crosses the conserve line (default **50%**, `OSRC_CONSERVE_THRESHOLD`), proactively move mechanical/parallel/long grind OFF the Claude session and say so plainly: *"You're at 95% of your 5-hour window, so I'm routing this grind to GLM on Devin (free) and keeping Claude for the judgment."* Priority order when tight: local ($0/private) → Devin GLM/SWE (free) → keyless Gemini → Codex Sol/Terra (only if the ChatGPT plan has headroom) → OpenRouter (only if funded). Different users have different lanes — a Codex-only user gets routed to Codex/local, never a Devin tour. In Auto/Hybrid this happens automatically; in You-drive, recommend it and let them decide. **Conservation changes ROUTING only — never quality, safety, consent, or permission mode.** The secret-scan hard-block and cloud consent still apply in every mode.

Say "no cash" not "free" for subscription lanes: *"Sol: $0 cash, spends your ChatGPT window."* State the permission verb in human terms at dispatch ("read-only inspection", "may edit files", "full autonomy"). When conservation swaps a model, always give the one-line reason — silent swaps feel arbitrary.

**Non-interactive callers (bg/fanout/CI) skip the handshake entirely** — `brief`/`mode` only ever PRINT, they never prompt, so a piped or detached call can't hang. The conversation is yours (the orchestrator's) to have; the script just supplies the state.

## How to behave (the mechanism you drive)

The user should never have to learn a command, remember a model name, or ask "is Devin installed?", **you already know.** You talk to this skill in natural language and it does the rest. If you catch yourself explaining a flag to the user instead of just running it, you're doing it wrong.

**Trigger.** Act the moment any of these are true:
- The user says "use outsourcerer", "outsource this", "delegate this", or names a specific lane/model ("use GLM", "spin up Devin", "offload to Codex").
- **You** notice offloadable work without being asked: repo mapping, a big/parallel search, a mechanical refactor, running a test suite, generating an image, or wanting a second opinion before committing to a plan. If you'd reach for your own subagents, reach for this skill first and weigh the trade.
  - **Running a specific Claude model (fable/opus/...) as an advisor?** Prefer the claude-native lane (`run -m fable`): it reports and VERIFIES the model that actually ran. A native Agent subagent can SILENTLY fall back to your default (usually Opus) with no way to verify, so NEVER claim a subagent ran on Fable unless you can prove it. See `references/second-opinion-and-parity.md`.

**The loop, every time:**

0. **Handshake first (see above).** Run `brief`, greet with the live capacity picture, settle the driving mode if unset. Then proceed per that mode.
1. **Detect the environment, silently.** `brief` already ran `doctor`-grade detection; run `doctor`/`models` only when you need the deeper lane/auth detail. The user never runs these themselves.
2. **When the user hasn't named a model, run `advise` and present the recommendation conversationally.** Don't make them pick. Run `advise "their task description"`, read the output, and say something like: *"For this task I'd recommend **sol**, it scores 77 on coding and you already have it on your Claude plan (zero extra cost). Want me to run it?"* Then wait for the go-ahead. Details: `references/model-advisory.md`.
3. **Proactively OFFER the smart move, in plain language, with the token-savings angle.** Don't wait to be asked "should I offload this?"; say what you'd do and why it's cheaper, then let the user green-light it. Adapt the offer to what `doctor` found:
   - *"I see Devin's set up with GLM-5.2, want me to offload this repo-mapping there and keep your Claude tokens for the thinking?"*
   - *"This refactor is mechanical, a cheap lane (GLM) can grind through it while you keep going. Delegate it?"*
   - *"This is a UI/design review, Gemini's strong at that and it's keyless on your Antigravity login. Send it there?"*
   - *"This code is sensitive IP and I see Ollama running. Want me to run this on your own machine, $0 and fully private?"*
   - *"This is a multi-agent gauntlet. Want me to `fanout` all N agents in parallel on GLM and collect the findings?"*
   - *"You've got droid set up with your own cheap API lanes, want me to send this grind through YOUR droid config (`--provider droid`) instead of spending anything new?"* (Same for Cursor: `--provider cursor` rides their subscription. `doctor` shows which engines the user actually has; meet them where they are.)
   - *"You run a CLIProxyAPI, want Sol INSIDE the Claude Code harness (`--provider claudex`) instead of the codex CLI? Same ChatGPT plan, better harness."* Offer ONLY when `doctor` says claudex is READY; it's an unofficial community bridge (disclose that), detect-only (never install the proxy for them), and Claude-sub models are refused on it by policy.
4. **Pick the right model AND effort for the task, don't ask the user to.** Say which one you picked and why, let the user override. Cheap ≠ dumb: `glm-5.2`/`hy3`/`deepseek` are `capable` tier (frontier capability, budget price). Only route AWAY from genuinely small models (`haiku`/`*-mini`). Use `--effort` when depth matters. Details: `references/effort-and-tiers.md`.
   - **Pick the run MODE too.** Headless one-shots (`run`/`research`/`edit`/`yolo`/`bg`/`fanout`) DO execute tools. Only claude-native `auto` is genuinely read-only-ish. Don't use N interactive tmux sessions for tool access, use headless `fanout`. Reserve `session` for live steering. Details: `references/mechanism.md`.
   - **Foreground vs supervised.** For anything substantial or unattended, prefer `bg` and poll `status`. Foreground is for quick watched one-shots. Details: `references/jobs-and-safety.md`.

   **Verb = permission mode.** Three axes: read-only / mutating / sandboxed-exec. Pick the verb that matches the trust level:

   | Verb | Mode | Tier | What it does |
   |---|---|---|---|
   | `run` | read-only (Read/Grep/Glob, no Bash exec) | auto | Observe, map, search. No side effects. |
   | `explore` | alias for `run` | auto | Same as run. |
   | `research` | sandboxed tool exec (devin/codex only) | autonomous | Run commands inside the delegate's sandbox. |
   | `edit` | auto-accept file edits | accept-edits | Modify files, no human prompt per edit. |
   | `yolo` | auto-approve ALL tools, no sandbox | dangerous (HIGH RISK) | Full autonomy. Use sparingly, never default. |
   | `bg` | any verb detached + supervised | (inherits verb) | Long/unattended work. Poll `status`. |
   | `fanout` | N parallel jobs | (inherits verb) | Multi-agent gauntlet. |
   | `session` | interactive tmux session | interactive | Live steering, you watch and intervene. |

5. **Drive the commands yourself.** The subcommand table, provider flags, model aliases, tier system, all in `references/*.md`, is the **mechanism you operate**, not a manual for the user. The user's experience should stay "I said outsource this, it happened."
6. **Report cost honestly, never call a subscription lane "free."** Split **cash** from **plan limits**. A ChatGPT-sub/Claude-sub/keyless run charges $0 cash but spends finite plan limits, say both. The local lane is the one genuinely free tier ($0 cash, $0 plan, private). Details: `references/tab.md`.

If `doctor` reports a CLI missing or not logged in, don't stall on it, say what's missing in one line, suggest the fastest lane that *is* ready, and offer to keep going.

## Parallel multi-agent (fanout)

`fanout` runs N delegations in parallel across ANY provider, each as a supervised background job, then collects results. Full mechanics, self-heal behavior, and the gauntlet recipe: `references/parallel-and-fanout.md`.

```
outsourcerer.sh --provider cc fanout --agents ~/.claude/skills/<skill>/agents \
  --preamble <skill>/agents/_universal-override.md \
  --sub TARGET_PATH=$PWD --sub LANG=bash -m glm --effort high --verb run --max 6
outsourcerer.sh fanout status|wait|collect <gid>
```

## Prerequisites

Self-contained bash but drives external CLIs (Devin/Codex/Claude/agy/droid/cursor-agent, jq, tmux). Run `doctor` first. Full dependency table: `references/mechanism.md`.

**Windows: NO WSL required.** The script runs under Git Bash (ships with Git for Windows, `winget install Git.Git`); `scripts/outsourcerer.cmd` and `scripts/outsourcerer.ps1` launch it from cmd/PowerShell. Everything works except tmux `session` mode — `bg`/`fanout` cover the same ground, supervised. If a Windows user hesitates about installing anything: they almost certainly already have Git for Windows; nothing else is needed.

## Model aliases → lane (compact routing table)

The **model alias selects the lane**, no `--provider` needed for these. Full table: `references/lanes-and-models.md`.

| Alias(es) | Lane |
|---|---|
| `sol` / `terra` / `luna` / `gpt-5.5` | codex-native (ChatGPT sub); **or add `--provider claudex`** to run the SAME model inside the Claude Code harness via the user's local CLIProxyAPI — offer this when `doctor` shows claudex READY (better harness UX; codex CLI still owns gpt-image) |
| `fable` / `opus` / `sonnet` / `haiku` | claude-native (Claude sub) |
| `gemini-pro` / `gemini-flash` / `gemini-flash-lite` | gemini (agy keyless) |
| `gpt-image` / `codex-image` | codex-image (image only, keyless) |
| `nano-banana` | gemini-image (image only, needs `GEMINI_API_KEY`) |
| `glm` / `hy3` / `deepseek` / any OpenRouter id | OpenRouter (needs `--provider cc`/`codex`); `capable` tier |
| `ollama:<m>` / `lmstudio:<m>` / `local:<m>` | **local** (keyless, PRIVATE, $0) |
| `swe` / `swe-1.7` / `kimi` / any Devin model id | devin (`--provider devin`, default); glm/deepseek self-heal to Devin when OpenRouter is out of credits |
| any model name the USER configured in their engine | **droid** / **cursor** (`--provider droid|cursor`): drives THEIR agent CLI with THEIR models (incl. free/cheap BYOK lanes in `~/.factory/settings.json` / their Cursor account). `-m` passes through verbatim — the skill adapts to the user's tools, never the reverse. |

## Model advisory: data-backed "which model should I use?"

**Proactive rule**: When the user says "let's use Outsourcerer for this", "delegate this", or describes a task without naming a model, **run `advise` first** and show them the recommendation before dispatching. Don't make them ask.

```
outsourcerer.sh advise "refactor the authentication module to use JWT tokens"
outsourcerer.sh advise --refresh "analyze tradeoffs of microservices vs monolith"
outsourcerer.sh advise --json "execute a multi-step agent workflow" | jq .recommendation
```

Present the output conversationally: "I'd recommend **sol** for this, it scores 77.4 on coding and you have it on your Claude plan. Want me to run it?" Then wait for the go-ahead. Don't dump the table, translate it into a recommendation a human can act on.

How it picks: classifies the task (code/reasoning/agentic/creative/simple), pulls live benchmark scores from OpenRouter API, scores every model (subscription by capability, paid by value ratio), recommends the best model meeting the threshold. Falls back to tier-based proxy scores offline. Full details: `references/model-advisory.md`.

## Other subcommands

| Subcommand | What it does |
|---|---|
| `brief` | Session-start handshake: ready lanes + live limits + conserve rec + driving mode. Run this FIRST every session. |
| `mode` | `status\|auto\|manual\|hybrid\|reset` — the copilot driving mode, remembered once. |
| `consent` | `status|grant|revoke` — one-time cloud consent, remembered. |
| `suggest` / `deals` | What's cheap/free right now. |
| `estimate` | Cost quote before a big offload. |
| `cleanup` | Remove old worktrees. |
| `gc` | Reclaim old job dirs (`--older-than DAYS`). |
| `continue` / `cont` | Resume a Devin conversation with a model switch. |
| `second-opinion` / `second` | Run cheap models, escalate on disagreement. |
| `parity` | Sync skills into Devin/Codex/Antigravity. |
| `parity-codex` | Reverse bridge: teach Codex to drive outsourcerer. |
| `parity-droid` / `parity-cursor` | Reverse bridge: teach droid (global `~/.factory/AGENTS.md`) / Cursor (repo `AGENTS.md`) to drive outsourcerer — full two-way parity: work FROM any tool, delegate TO any lane. |
| `image` | Generate an image (codex/gemini/openrouter backends). |

## How to report failures to the user

Map each terminal state to a one-line user message:

| Exit state | User message |
|---|---|
| `done` (exit 0) | "Done. <result summary>" |
| `done?` (exit 2) | "It says done but the progress marker was missing. Here's the output..." |
| `blocked` (exit 3) | "It needs input: <result>. Want me to answer and continue, or handle it here?" |
| `timeout` (exit 124) | "Hit the time cap. For long work I'll use `bg` next time." |
| `wedged` (exit 125) | "The delegate stalled after <last progress>. I'll re-run on a stronger model or do it myself." |

## References

- `references/mechanism.md` — prerequisites, setup, provider flags, tier-aware prompting, subcommands, interactive `session` mode
- `references/lanes-and-models.md` — full model-alias table, native premium lanes, Gemini/Antigravity lane, image backend order
- `references/jobs-and-safety.md` — background jobs, watchdog, exit codes, stall/kill/timeout windows
- `references/parallel-and-fanout.md` — `fanout` subcommand, parallel multi-subagent, gauntlet recipe, self-heal behavior
- `references/effort-and-tiers.md` — `--effort` reasoning knob per lane, capability-vs-price tier model
- `references/tab.md` — cost reporting, cash vs plan-limit accounting, calibrated estimates
- `references/second-opinion-and-parity.md` — `second-opinion`, `parity` (skills+MCP porting), per-host install paths, env-var index
- `references/model-advisory.md` — `advise` subcommand, task classification, scoring formula, thresholds, fallback chain
