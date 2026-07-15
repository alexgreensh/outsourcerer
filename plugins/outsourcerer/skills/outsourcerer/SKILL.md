---
name: outsourcerer
description: '''Delegate grunt work to a cheaper or different engine while Claude orchestrates, across OpenRouter (GLM/hy3/DeepSeek), Codex, Claude, and keyless Gemini/Antigravity lanes, plus image gen and a cost Tab. Triggers: outsource, offload, delegate, use GLM/Devin/Codex, or get a second opinion.'''
---

# Outsourcerer

**Created by**: [Alex Greenshpun](https://linkedin.com/in/alexgreensh)

Delegate the work Claude would normally hand to its own subagents to a **Devin CLI model** instead. Default model is **`glm-5.2`** (currently a free lane on Devin), but the skill is fully model-agnostic, the user can pick any model, and you recommend free ones from the **live** list.

The single entrypoint is the helper script:

```
${CLAUDE_PLUGIN_ROOT}/skills/outsourcerer/scripts/outsourcerer.sh <subcommand> [args]
```

## How to behave (the magic contract)

The user should never have to learn a command, remember a model name, or ask "is Devin installed?", **you already know.** You talk to this skill in natural language and it does the rest. If you catch yourself explaining a flag to the user instead of just running it, you're doing it wrong.

**Trigger.** Act the moment any of these are true:
- The user says "use outsourcerer", "outsource this", "delegate this", or names a specific lane/model ("use GLM", "spin up Devin", "offload to Codex").
- **You** notice offloadable work without being asked: repo mapping, a big/parallel search, a mechanical refactor, running a test suite, generating an image, or wanting a second opinion before committing to a plan. If you'd reach for your own subagents, reach for this skill first and weigh the trade.
  - **Running a specific Claude model (fable/opus/...) as an advisor?** Prefer the claude-native lane (`run -m fable`): it reports and VERIFIES the model that actually ran. A native Agent subagent can SILENTLY fall back to your default (usually Opus) with no way to verify, so NEVER claim a subagent ran on Fable unless you can prove it. See `references/second-opinion-and-parity.md`.

**The loop, every time:**

1. **Detect the environment first, silently.** Run `doctor` (and `models` when the choice of model matters) before saying anything about what's available. The user never runs `doctor` themselves, you run it, read it, and act on it.
2. **When the user hasn't named a model, run `advise` and present the recommendation conversationally.** Don't make them pick. Run `advise "their task description"`, read the output, and say something like: *"For this task I'd recommend **sol**, it scores 77 on coding and you already have it on your Claude plan (zero extra cost). Want me to run it?"* Then wait for the go-ahead. Details: `references/model-advisory.md`.
3. **Proactively OFFER the smart move, in plain language, with the token-savings angle.** Don't wait to be asked "should I offload this?"; say what you'd do and why it's cheaper, then let the user green-light it. Adapt the offer to what `doctor` found:
   - *"I see Devin's set up with GLM-5.2, want me to offload this repo-mapping there and keep your Claude tokens for the thinking?"*
   - *"This refactor is mechanical, a cheap lane (GLM) can grind through it while you keep going. Delegate it?"*
   - *"This is a UI/design review, Gemini's strong at that and it's keyless on your Antigravity login. Send it there?"*
   - *"This code is sensitive IP and I see Ollama running. Want me to run this on your own machine, $0 and fully private?"*
   - *"This is a multi-agent gauntlet. Want me to `fanout` all N agents in parallel on GLM and collect the findings?"*
4. **Pick the right model AND effort for the task, don't ask the user to.** Say which one you picked and why, let the user override. Cheap ≠ dumb: `glm-5.2`/`hy3`/`deepseek` are `capable` tier (frontier capability, budget price). Only route AWAY from genuinely small models (`haiku`/`*-mini`). Use `--effort` when depth matters. Details: `references/effort-and-tiers.md`.
   - **Pick the run MODE too.** Headless one-shots (`run`/`research`/`edit`/`yolo`/`bg`/`fanout`) DO execute tools. Only claude-native `auto` is genuinely read-only-ish. Don't use N interactive tmux sessions for tool access, use headless `fanout`. Reserve `session` for live steering. Details: `references/mechanism.md`.
   - **Foreground vs supervised.** For anything substantial or unattended, prefer `bg` and poll `status`. Foreground is for quick watched one-shots. Details: `references/jobs-and-safety.md`.
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

Self-contained bash but drives external CLIs (Devin/Codex/Claude/agy, jq, tmux). Run `doctor` first. Full dependency table: `references/mechanism.md`.

## Model aliases → lane (compact routing table)

The **model alias selects the lane**, no `--provider` needed for these. Full table: `references/lanes-and-models.md`.

| Alias(es) | Lane |
|---|---|
| `sol` / `terra` / `luna` / `gpt-5.5` | codex-native (ChatGPT sub) |
| `fable` / `opus` / `sonnet` / `haiku` | claude-native (Claude sub) |
| `gemini-pro` / `gemini-flash` / `gemini-flash-lite` | gemini (agy keyless) |
| `gpt-image` / `codex-image` | codex-image (image only, keyless) |
| `nano-banana` | gemini-image (image only, needs `GEMINI_API_KEY`) |
| `glm` / `hy3` / `deepseek` / any OpenRouter id | OpenRouter (needs `--provider cc`/`codex`); `capable` tier |
| `ollama:<m>` / `lmstudio:<m>` / `local:<m>` | **local** (keyless, PRIVATE, $0) |
| any Devin model id | devin (`--provider devin`, default) |

## Model advisory: data-backed "which model should I use?"

**Proactive rule**: When the user says "let's use Outsourcerer for this", "delegate this", or describes a task without naming a model, **run `advise` first** and show them the recommendation before dispatching. Don't make them ask.

```
outsourcerer.sh advise "refactor the authentication module to use JWT tokens"
outsourcerer.sh advise --refresh "analyze tradeoffs of microservices vs monolith"
outsourcerer.sh advise --json "execute a multi-step agent workflow" | jq .recommendation
```

Present the output conversationally: "I'd recommend **sol** for this, it scores 77.4 on coding and you have it on your Claude plan. Want me to run it?" Then wait for the go-ahead. Don't dump the table, translate it into a recommendation a human can act on.

How it picks: classifies the task (code/reasoning/agentic/creative/simple), pulls live benchmark scores from OpenRouter API, scores every model (subscription by capability, paid by value ratio), recommends the best model meeting the threshold. Falls back to tier-based proxy scores offline. Full details: `references/model-advisory.md`.

## References

- `references/mechanism.md` — prerequisites, setup, provider flags, tier-aware prompting, subcommands, interactive `session` mode
- `references/lanes-and-models.md` — full model-alias table, native premium lanes, Gemini/Antigravity lane, image backend order
- `references/jobs-and-safety.md` — background jobs, watchdog, exit codes, stall/kill/timeout windows
- `references/parallel-and-fanout.md` — `fanout` subcommand, parallel multi-subagent, gauntlet recipe, self-heal behavior
- `references/effort-and-tiers.md` — `--effort` reasoning knob per lane, capability-vs-price tier model
- `references/tab.md` — cost reporting, cash vs plan-limit accounting, calibrated estimates
- `references/second-opinion-and-parity.md` — `second-opinion`, `parity` (skills+MCP porting), per-host install paths, env-var index
- `references/model-advisory.md` — `advise` subcommand, task classification, scoring formula, thresholds, fallback chain
