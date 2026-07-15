---
name: outsourcerer
description: 'Delegate grunt work to a cheaper or different engine while Claude orchestrates, across OpenRouter (GLM/hy3/DeepSeek), Codex, Claude, and keyless Gemini/Antigravity lanes, plus image gen and a cost Tab. Triggers: outsource, offload, delegate, use GLM/Devin/Codex, or get a second opinion.'
---

# Outsourcerer

**Created by**: [Alex Greenshpun](https://linkedin.com/in/alexgreensh)

Delegate the work Claude would normally hand to its own subagents to a **Devin CLI model** instead. Default model is **`glm-5.2`** (currently a free lane on Devin), but the skill is fully model-agnostic, the user can pick any model, and you recommend free ones from the **live** list.

The single entrypoint is the helper script:

```
${CLAUDE_PLUGIN_ROOT}/skills/outsourcerer/scripts/outsourcerer.sh <subcommand> [args]
```

## How to behave (the magic contract)

This is the part that makes the skill feel like magic. The user should never have to learn a
command, remember a model name, or ask "is Devin installed?", **you already know.** You talk to
this skill in natural language and it does the rest. If you catch yourself explaining a flag to the
user instead of just running it, you're doing it wrong.

**Trigger.** Act the moment any of these are true:
- The user says "use outsourcerer", "outsource this", "delegate this", or names a specific
  lane/model ("use GLM", "spin up Devin", "offload to Codex").
- **You** notice offloadable work without being asked, repo mapping, a big/parallel search, a
  mechanical refactor, running a test suite, generating an image, or wanting a second opinion
  before committing to a plan. Offloadable work is Task-subagent-shaped work; if you'd reach for
  your own subagents, reach for this skill first and weigh the trade.
  - **Running a specific Claude model (fable/opus/...) as an advisor, even from Claude Code?** Prefer
    the claude-native lane (`run -m fable "…"`): it reports and VERIFIES the model that actually ran, so
    it can never mislabel. A native Agent subagent is the in-session alternative, but its per-invocation
    model can SILENTLY fall back to your default (usually Opus) with no way to verify, so NEVER claim a
    subagent ran on Fable unless you can prove it, and NEVER inject "you are Fable" into an Opus run, and
    NEVER punt to `/advisor` (a UI command you can't fire). See `references/second-opinion-and-parity.md`.

**The loop, every time:**

1. **Detect the environment first, silently.** Run `doctor` (and `models` when the choice of model
   matters) before saying anything about what's available. This tells you which CLIs are installed
   *and logged in* (devin / codex / claude / agy) and which models each one currently offers live.
   The user never runs `doctor` themselves, you run it, read it, and act on it. Never ask "do you
   have Devin set up?", check, then either use it or explain what's missing.
2. **Proactively OFFER the smart move, in plain language, every time, always with the token-savings
   angle.** Don't wait to be asked "should I offload this?"; say what you'd do and why it's cheaper,
   then let the user green-light it. Adapt these canonical offers to what `doctor` actually found:
   - *"I see Devin's set up with GLM-5.2, want me to offload this repo-mapping there and keep your
     Claude tokens for the thinking?"*
   - *"You're about to generate an image and Codex is logged in, want me to render it with
     GPT-image on your ChatGPT plan (no API credits, it draws your ChatGPT plan quota) instead of
     paying per image?"*
   - *"Want me to sanity-check this plan with Codex GPT-5.6 before we build it?"*
   - *"This refactor is mechanical, a cheap lane (GLM) can grind through it while you keep going.
     Delegate it?"*
   - *"This is a UI/design review, Gemini's strong at that and it's keyless on your Antigravity
     login. Send it there?"*
   - *"This code is sensitive / freshly-hardened IP and I see Ollama running with qwen2.5-coder.
     Want me to run this on your own machine, $0 and fully private, so nothing ever leaves your
     laptop (no free cloud model gets to train on it)?"* (only offer when `doctor` finds a local
     server; this is the privacy lane.)
   - *"This is a big fan-out search across the repo, want that on a free lane instead of spending
     Claude tokens on grunt work?"*
   - *"This is a multi-agent gauntlet (a review skill / a per-module sweep / N parallel reviewers).
     Want me to `fanout` all N agents in parallel on GLM and collect the findings, instead of
     spending Claude subagent tokens?"*
3. **Pick the right model AND effort for the task, don't ask the user to.** Visual/UI/design review →
   Gemini (`gemini-flash`/`gemini-pro`, keyless via `agy`). Mechanical/bulk/grunt work → a cheap lane
   (`glm`/`hy3`). Image generation → GPT-image first (see the image backend order below). These are
   defaults, not rules, say which one you picked and why, and let the user override.
   - **Cheap ≠ dumb. `glm-5.2` / `hy3` / `deepseek-v4-pro` are `capable` tier: frontier CAPABILITY at
     budget PRICE (~Opus-4.8 class).** They are valid for high-stakes reasoning, security review, and
     deep judgment despite costing pennies. The old rule "high-stakes → not a budget model" was wrong
     and is gone: route high-stakes work to a **frontier-capability** model, which INCLUDES these
     open-weight lanes, a native premium lane (`opus`/`fable`/`sol`/`terra`), or Claude itself. Only
     route AWAY from genuinely *small* models (`haiku`/`gemini-flash-lite`/`*-mini`), which are the
     real `budget` tier. The skill wraps `capable` models with the same thin, high-autonomy scaffold
     it gives `frontier` (no "worker-drone" work order) and gives them generous stall windows.
   - **Reasoning effort is a first-class knob: `--effort minimal|low|medium|high|xhigh|max`** (alias
     `--reasoning`). Pass it whenever depth matters (a security gauntlet is `high`/`max`; a grep is
     `low`). It is honored NATIVELY on codex lanes (`model_reasoning_effort`) and Claude lanes
     (`MAX_THINKING_TOKENS`), and injected as an advisory prompt directive on Gemini, the dispatch
     banner always states which. Never silently drop a requested effort. Default: the lane's own
     default unless you have a reason to raise it.
   - **Pick the run MODE too, and know that HEADLESS can use tools.** Headless one-shots
     (`run`/`research`/`edit`/`yolo`/`bg`/`fanout`) DO execute tools and read the repo, the capability
     depends on the LANE + tier, not on "headless": `codex run` reads files in a read-only sandbox;
     `codex research`/`edit` exec+write in a sandbox; `cc run` reads files (Read/Grep) and `cc yolo`
     runs anything; `devin` execs tools and fans out its own subagents. Only **claude-native `auto`**
     is genuinely read-only-ish (it denies *Bash* exec headless, still reads). So do NOT reach for N
     interactive tmux sessions to get tool access: N interactive tmux sessions each cost ~47s
     bootstrap, which doesn't scale; use headless `fanout` instead (see below). Reserve an
     **interactive session** (`session start`) for genuinely live back-and-forth steering, not for
     parallelism or tool access. See `references/mechanism.md` and `references/parallel-and-fanout.md`.
   - **Foreground vs supervised, and WHEN to pick which.** `run`/`research`/`edit`/`yolo` run in the
     foreground; `bg`/`fanout` run supervised (a watchdog + a `status`/`watch` receipt + measured cost).
     Foreground now has a watchdog too (it kills a teardown hang and tells you to use `bg`), but it is
     still attached to your turn. So for **anything substantial, unattended, a frontier/reasoning model,
     or the codex-native lane** (which can wedge on teardown after finishing — an MCP-auth worker dies
     and a Stop hook loops), prefer **`bg`** and poll `status`, don't fire a bare foreground `run` and
     wait on it. Reach for foreground only for a quick, watched one-shot. Live steering → `session`.
4. **Drive the commands yourself.** The subcommand table, the provider flags, the model aliases,
   the tier system, all documented in `references/*.md` (see the References index below), is the
   **mechanism you operate**, not a manual for the user to read. Treat it as reference material for
   you, the orchestrator: look things up there when you need the exact flag, but the user's
   experience should stay "I said outsource this, it happened."
5. **Report cost honestly, never call a subscription lane "free."** When you tell the user what a
   delegation cost (the receipt), split **cash** from **plan limits**:
   - Cash-free is not cost-free. A ChatGPT-sub (`codex-native`/`sol`/`terra`/`luna`), Claude-sub
     (`claude-native`/`fable`/`opus`), keyless Antigravity (`agy`/`gemini-*`), or keyless GPT-image
     run charges **$0 cash** but spends your **finite plan limits** (the 5-hour and weekly windows).
     Say both. Never write "$0, free" for these lanes.
   - For codex-native runs you have the **real number**: the skill prints a `no cash charged, ran
     on your ChatGPT plan. ChatGPT plan usage, 5h window: X% · weekly: Y%` receipt line, and `tab`
     shows current headroom. Quote it rather than inventing "$0."
   - Cash *is* charged on OpenRouter/API lanes (`cc`, `--provider codex`, `gemini` API key, paid
     OpenRouter models). Real per-run cash is captured on **background (`bg`) runs** (from stream
     usage); foreground runs show a calibrated **estimate**, labeled as such, never present an
     estimate as a measured charge.
   - The **local lane** is the one genuinely free tier: **$0 cash AND $0 plan limits, plus PRIVATE**
     (inference runs on the user's own hardware; no code or data leaves the machine). Say all three.
     This is the lane to reach for when the work is sensitive IP you must not hand to a cloud model.
   - So the receipt reads like: *"Done, Terra ran on your ChatGPT sub. No cash charged; it used ~1%
     of your 5-hour window (resets in ~4h) and 0% of your weekly."* Not *"$0 tracked, free."*

If `doctor` reports a CLI missing or not logged in, don't stall on it, say what's missing in one
line, suggest the fastest lane that *is* ready, and offer to keep going with that instead (auth
flows like `devin auth login` and `codex login` are interactive browser flows only the user can
complete; everything else is yours to drive).

---

## Parallel multi-agent (fanout), the baseline expectation

Users expect to run **many subagents in parallel** through the Outsourcerer, the same way native
Claude subagents fan out. This is the `fanout` subcommand: it runs N delegations in parallel across
ANY provider, each as a supervised background job, then collects the results. It builds on the same
job machinery as `bg` (watchdog, tier stall-windows, cost ledger).

```
# One job per agent-prompt file (the multi-agent skill / gauntlet bridge):
outsourcerer.sh --provider cc fanout --agents ~/.claude/skills/<your-review-skill>/agents \
  --preamble ~/.claude/skills/<your-review-skill>/agents/_universal-override.md \
  --sub TARGET_PATH=$PWD --sub LANG=bash --sub CHANGED_FILES="$(git diff --name-only)" \
  -m glm --effort high --verb run --max 6
# One job per task line, or inline tasks:
outsourcerer.sh --provider cc fanout --tasks tasks.txt -m glm --effort high
outsourcerer.sh --provider cc fanout -m glm -- "audit auth.py" "audit db.py" "audit api.py"

outsourcerer.sh fanout status  <gid>     # live table of every agent
outsourcerer.sh fanout wait    <gid>     # block until all terminal
outsourcerer.sh fanout collect <gid>     # gather every agent's final message -> one COLLECTED.md
```

**How to run a multi-agent SKILL (a review gauntlet, e.g. `<your-review-skill>`) through the
Outsourcerer:** do NOT bolt the outsourcerer under each native subagent (that gives you N interactive
tmux sessions, each with a nontrivial bootstrap cost, which doesn't scale). Instead, `fanout --agents <the
skill's agents dir>` runs each agent prompt as one HEADLESS job, one fast bootstrap each, true OS
parallelism, full repo access. Pick the lane by tool needs: **`cc`** (Claude Code → OpenRouter) is the
reliable tool-using lane for GLM/open-weight models; **`devin`** fans out its own managed subagents;
**`codex`** is best for codex-native models (`sol`/`terra`/`gpt-5.5`). If you pick `codex` with an
OpenRouter model and its upstream provider rejects Codex's native tool types, the skill **self-heals**
by re-running that model on the `cc` lane automatically, fanout stays green no matter the provider.
The same applies in reverse for dual-lane models (`glm` today): if `--provider cc`'s whole OpenRouter
chain is exhausted on transport/availability grounds (out of credits, rate-limited, etc.), the skill
self-heals across to that model's Devin sibling instead of dying, since it's the same model on a lane
that isn't rationed by your OpenRouter balance. You don't need to pick `devin` up front to get that
safety net, but if OpenRouter credits are already known to be tight, going straight to the default
provider (`devin`, no `--provider` flag) skips the OpenRouter round-trip entirely.
Full mechanics + the generic multi-agent recipe: `references/parallel-and-fanout.md`.

## Prerequisites

The skill is self-contained bash but drives external tools (Devin/Codex/Claude/agy CLIs, jq, tmux).
Run `doctor` first, it reports what's installed, logged in, and live, and only install what it
flags as missing. Full dependency table, install commands, and Step 0 preflight:
`references/mechanism.md`.

## Model aliases → lane (compact routing table)

The **model alias selects the lane**, no `--provider` needed for these. Full table (resolved IDs,
tiers, per-row notes), guardrails, and OpenRouter/devin lanes: `references/lanes-and-models.md`.

| Alias(es) | Lane |
|---|---|
| `sol` / `terra` / `luna` / `gpt-5.5` | codex-native (ChatGPT sub) |
| `fable` / `opus` / `sonnet` / `haiku` | claude-native (Claude sub) |
| `gemini-pro` / `gemini-flash` / `gemini-flash-lite` | gemini (agy keyless, primary; gemini-cli+key, fallback) |
| `gpt-image` / `codex-image` | codex-image (image only, keyless) |
| `nano-banana` | gemini-image (image only, needs `GEMINI_API_KEY`) |
| `glm` / `hy3` / `deepseek` / any OpenRouter id | OpenRouter (needs `--provider cc`/`codex`); `glm`/`hy3`/`deepseek` are **`capable` tier** (frontier capability, budget price) |
| `ollama:<m>` / `lmstudio:<m>` / `local:<m>` / `local` | **local** (keyless, PRIVATE, $0; auto-detects Ollama/LM Studio/llama.cpp; also `--provider local`) |
| any Devin model id | devin (`--provider devin`, default) |

## References

Reference paths below are relative to the skill directory (the folder containing this file).

- `references/mechanism.md`, full prerequisites/setup table, Step 0 preflight, architecture,
  provider flags (`--provider devin|cc|codex`), tier-aware prompt wrapping, capability injection
  (`--with`), core usage examples (run/research/edit/continue), and interactive tmux `session` mode.
  Read when you need an exact flag, subcommand, or code example.
- `references/lanes-and-models.md`, the full model-alias table, native premium lanes, the
  Gemini/Antigravity (`agy`) lane, image-generation backend order (gpt-image → nano-banana →
  OpenRouter), and model-recommendation heuristics. Read when picking or explaining a model.
- `references/jobs-and-safety.md`, background jobs (`bg`/`status`/`watch`/`result`/`logs`/`cancel`),
  the liveness watchdog, exit codes, stall/kill/timeout windows, and the orchestration rules for
  running the plumbing once the user has said yes. Read before/while any long-running delegation.
- `references/parallel-and-fanout.md`, the `fanout` subcommand (parallel N-way multi-subagent across
  any provider, built on `bg`): sources (`--agents`/`--tasks`/inline), per-job knobs (`-m`/`--effort`/
  `--tier`/`--verb`/`--max`), `status`/`wait`/`collect`, the codex→cc tool-type self-heal, and the
  step-by-step recipe for running a review gauntlet (or any multi-agent skill) through the Outsourcerer.
  Read when the user wants parallel subagents or to run a gauntlet skill on a cheaper engine.
- `references/effort-and-tiers.md`, the `--effort` reasoning knob per lane (native vs advisory) and
  the capability-vs-price tier model (`frontier`/`capable`/`mid`/`budget`). Read when picking effort
  or explaining why a cheap model is not hand-held.
- `references/tab.md`, the full cost-reporting mechanics (`tab`/`estimate`), cash vs. plan-limit
  accounting, calibrated token estimates, and codex rate-limit reading. Read before writing any
  cost receipt to the user.
- `references/second-opinion-and-parity.md`, consensus-gated `second-opinion`, the `parity-codex`
  reverse bridge, `parity` (skills+MCP porting to Devin/Antigravity), per-host install paths, and an
  env-var index. Read when setting up parity/insourcing or tracing an env var to its full doc.
