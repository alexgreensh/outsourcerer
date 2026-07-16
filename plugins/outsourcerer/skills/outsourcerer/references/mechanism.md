# Mechanism reference (how the magic contract runs under the hood)

Everything in this file is the operating manual **for you** (Claude, the orchestrator), the
exhaustive subcommand table, provider flags, model aliases, and tier system that the
natural-language contract in `SKILL.md` drives. Power users who want to type raw commands can read
it too, but it is documented Claude-first.

## Prerequisites & first-time setup

The skill is self-contained bash, but it drives external tools. Before first use, make sure these exist. **`doctor` reports the status of all of them** (see Step 0 below), so run that first and only install what it flags as missing.

| Dependency | Required for | Install |
|---|---|---|
| **bash** | everything | preinstalled on macOS/Linux (works on macOS's bash 3.2) |
| **Devin CLI + login** | `--provider devin` | `curl -fsSL https://cli.devin.ai/install.sh -o devin-install.sh` then inspect and `bash devin-install.sh`, then `! devin auth login` (interactive browser flow, run it yourself) |
| **`OPENROUTER_API_KEY`** | `--provider cc` / `codex` | add `OPENROUTER_API_KEY=<your-key>` to `~/.env` (sourced at call time; never written into the skill) |
| **claude CLI** | `--provider cc` | Claude Code (`claude` on PATH) |
| **codex CLI + login** | `--provider codex`; also the **PREFERRED, keyless `image` backend** (`gpt-image`) | OpenAI Codex CLI (`codex` on PATH), then `codex login` (interactive, run it yourself) |
| **`agy` (Antigravity CLI)**, PRIMARY, keyless | `gemini-pro` / `gemini-flash` / `gemini-flash-lite` text lane | `curl -fsSL https://antigravity.google/cli/install.sh -o agy-install.sh` then inspect and `bash agy-install.sh`, then open Antigravity / sign in once so `agy` inherits your Google login (no API key) |
| **`gemini` CLI + `GEMINI_API_KEY`**, FALLBACK | same aliases when you'd rather use an API key (`OSRC_GEMINI_VEHICLE=gemini`), and needed for `image`/nano-banana **only when the codex backend isn't ready** | `npm install -g @google/gemini-cli` + add `GEMINI_API_KEY` (or `GOOGLE_API_KEY`) to `~/.env` (same single-key sourcing as `OPENROUTER_API_KEY`; never written into the skill). Key: [aistudio.google.com/apikey](https://aistudio.google.com/apikey) |
| **jq** | `parity`, `image` (gemini/OpenRouter backends) | `brew install jq` (macOS) / `apt install jq` (Linux) |
| **tmux** | `session` + interactive OR launchers | `brew install tmux` / `apt install tmux` |

`doctor` reports the status of all of these per provider, so run it first and install only what it flags. Each provider needs only its own row plus bash; the script degrades gracefully and names any missing dependency.

To install the skill itself: drop the `outsourcerer/` folder into `~/.claude/skills/` (Claude Code) and/or run `parity` to symlink it into Devin too.

The helper is self-contained bash; no external deps beyond `devin`, and `jq`/`tmux` only for `parity`/`session`.

## Step 0, Preflight (run once per session)

```
~/.claude/skills/outsourcerer/scripts/outsourcerer.sh doctor
```

If it reports **NOT logged in**, tell the user to run it themselves (browser auth):

```
! devin auth login
```

Do not try to complete the login yourself, it is an interactive browser flow.

## How it works (architecture)

Claude stays the **orchestrator**. When you would otherwise spawn Task/subagents, delegate instead.
Two shapes of parallelism, both first-class:

1. **Intra-session fan-out**, hand one well-scoped task to a single invocation and tell it to *use
   parallel subagents*. Devin fans out its own subagents (`run_subagent`); a `cc`/`codex` session can
   drive its Task tool. One bootstrap, N internal workers, one synthesized result.
2. **Inter-session fan-out (`fanout`)**, YOU launch N parallel delegations, one per agent/task, each a
   supervised headless job, then collect. True OS parallelism across ANY provider, full repo access,
   one fast bootstrap each. This is how you run a multi-agent skill (e.g. `<your-review-skill>`, a
   review gauntlet) on a cheaper engine, NOT N interactive tmux sessions. See `parallel-and-fanout.md`.

- One-shot delegation uses `devin -p` / `codex exec` / `claude -p` (clean stdout, exit codes, no blocking trust prompt).
- Multi-turn uses `devin -c` (continue), no tmux needed for follow-ups.
- A persistent interactive TUI is available via tmux (opt-in), for genuinely back-and-forth *steering*,
  not for parallelism or tool access (headless already has both, see the mode note in `SKILL.md`).

## Providers (offload backend), `--provider devin | cc | codex | droid | cursor | local`

The offload backend is selectable. Pass `--provider NAME` anywhere (before or after the
subcommand), or set `OUTSOURCERER_PROVIDER`. Default is `devin` (unchanged).

| Provider | Engine | Protocol | Inherits | Sandbox | Best for |
|---|---|---|---|---|---|
| `devin` (default) | Devin CLI |, | Devin skills/MCP (via `parity`) | OS sandbox (`research`) | delegated fan-out with Devin's own subagents |
| `cc` | `claude -p` → OpenRouter | Anthropic-compat (1 hop) | **your Claude skills/MCP/Task subagents, free** | none (CC permission modes only) | offload that must use your exact Claude capabilities |
| `codex` | `codex exec` → OpenRouter | native OpenAI Responses API (0 hops) | Codex's AGENTS.md + its MCP | OS sandbox (`--sandbox`) | cleanest tool-calling on cheap OpenAI-native models |
| `droid` | Factory `droid exec` | droid's own | droid's AGENTS.md + the user's `~/.factory/settings.json` (incl. **BYOK customModels**) | `--auto low/medium/high` autonomy levels | users who already live in droid with their own free/cheap API lanes configured |
| `cursor` | `cursor-agent -p` | cursor's own | the user's Cursor rules/AGENTS.md + account models | `--sandbox enabled` (research verb) | users on a Cursor subscription (CLI shares its credit pool) |
| `claudex` | `claude -p` → user's local CLIProxyAPI | Anthropic-compat `/v1/messages` | Claude Code harness UX (strict MCP isolation) | none (CC permission modes) | GPT-5.6 Sol/Terra inside the Claude harness; DETECT-ONLY, see `lanes-and-models.md` |

**Engine lanes (`droid`/`cursor`) pass `-m` through VERBATIM** — the engine's own catalog (incl.
user-configured BYOK models) decides what a name means; the alias table never rewrites it. No `-m`
= the engine's configured default. Verb mapping: `run` = read-only default, `edit` = `--auto medium`
/ `--force`, `yolo` = `--auto high` / `--force --sandbox disabled`. `--effort` maps natively to
droid's `-r`; advisory on cursor.

**OpenRouter lanes (`cc`/`codex`):** no proxy, no install, OpenRouter natively serves both the
Anthropic Messages API and the OpenAI Responses API. They read `OPENROUTER_API_KEY` from `~/.env`.
When you do **not** pass `-m`, they **escalate through a model chain** on hard failure
(`OR_OFFLOAD_CHAIN`, default `tencent/hy3:free → z-ai/glm-5.2 → deepseek/deepseek-v4-pro`, all
support tool-calling). Pass `-m <openrouter-id>` to pin one model and skip escalation.

```
.../outsourcerer.sh --provider cc    run  "Using subagents, map how auth works across this repo."
.../outsourcerer.sh --provider codex edit "Rename foo() to bar() across src/ and fix call sites."
.../outsourcerer.sh --provider cc    yolo -m z-ai/glm-5.2 "Run the full test suite and summarize failures."
```

**Which to pick:** `codex` when you want the most faithful tool-calling on a cheap OpenAI-native
model (hy3/GLM/DeepSeek are tuned for OpenAI function-calling); `cc` when the delegated work needs
*your* Claude skills/MCP/subagents; `devin` when you want Devin's managed fan-out or its sandbox
without touching OpenRouter. `continue`/`session`/`parity` are **Devin-only**, for interactive
OpenRouter sessions use this skill's own `scripts/run-or-model.sh` (cc) or
`scripts/run-or-codex.sh` (codex).

## Tier-aware prompt wrapping (frontier / mid / budget / raw)

Every cc/codex/native dispatch classifies the model into a **tier** and wraps the task in a
tier-appropriate scaffold (a **banner prints the verdict** on every dispatch). Strong models get a
thin wrapper (they bring their own plan); cheap models get a strict work order with a printed plan,
a scope fence, an output contract, and anti-hallucination rules.

- Classification (first hit wins): `--tier` flag / `OUTSOURCERER_TIER` env → alias table →
  cached OpenRouter pricing (`~/.outsourcerer/models.json`, refresh via `models --refresh`) →
  name regex → default `mid`.
- Override per call: `--tier frontier|mid|budget|raw` before the task. `raw` = your prompt
  verbatim (plus the progress-protocol block only). Move price cutoffs with
  `OSRC_TIER_BUDGET_MAX_USD_M` / `OSRC_TIER_MID_MAX_USD_M`.

```
outsourcerer.sh --provider cc run --tier budget -m z-ai/glm-5.2 "grep the repo for TODOs and list them"
outsourcerer.sh run -m opus "design the retry policy"            # frontier wrapper, claude-native
outsourcerer.sh --provider codex run --tier raw -m hy3 "reply PONG"
```

Every delegated prompt also carries the **OSRC:: progress protocol** (the delegate prints
`OSRC::PROGRESS <n>/<total> …` between steps and ends with `OSRC::DONE <summary>` or
`OSRC::BLOCKED <reason>`). This is how the watchdog and job status know alive/progressing/done/wedged.

## Capability injection (--with), least privilege, per task

Instead of inheriting your whole rig, inject exactly what a task needs:

```
outsourcerer.sh --provider cc run --with skills=recall,repo-forensics "…"   # SKILL.md CONTENTS injected
outsourcerer.sh --provider cc run --with "skills=recall mcp=whatsapp" "…"    # + only that MCP server
```
`skills=` concatenates each named `SKILL.md` into the prompt (works on any provider, it is just
markdown). `mcp=` (cc lane) generates a filtered `--mcp-config` exposing ONLY the named servers
(`--strict-mcp-config`). Pass repeated `--with` or one quoted `--with "skills=… mcp=…"`.

## Core usage

Read-only fan-out (exploration, code reading), permission `auto`:
```
.../outsourcerer.sh run "Using parallel subagents, map how auth works across this repo and report each module's role."
```

Research that must **RUN tools** (the recall/`brain` binary, scripts, CLIs), `research`:
```
.../outsourcerer.sh research "Using parallel subagents AND the recall binary, find how we added the codex provider before; cite session IDs."
```
**Why a separate command:** Devin's `auto` mode auto-approves only *read-only* tools and **blocks executing an external binary**, so under `run`, a delegated agent silently can't run recall/scripts (you get "non-interactive shell rejected exec"). The CLI has **no read-only-exec mode**, `--help` lists `smart`, but the binary rejects it. So `research` runs **`autonomous --sandbox`**: it can exec tools, but inside an OS-level sandbox (macOS seatbelt / Linux bwrap+seccomp) that enforces the granted Read/Write scopes, far tighter blast radius than blanket auto-approve. `--sandbox` is a Research Preview; if a run dies on a scope denial, fall back to `yolo` (`dangerous`, no sandbox). Use for trusted recall/code research where the agent needs to actually invoke tools.

Tasks that modify files (bulk edits, refactors), permission `accept-edits`:
```
.../outsourcerer.sh edit "Using subagents, rename foo() to bar() across src/ and update all call sites and tests."
```

Continue the same Devin conversation (follow-up turn):
```
.../outsourcerer.sh continue "Now also update the docs to match."
```

Pick a different model for a single call (flexible, overrides the default):
```
.../outsourcerer.sh run -m deepseek-v4-pro "..."
.../outsourcerer.sh edit -m claude-sonnet-4.6 "..."   # premium: see cost note below
```

**Switch models mid-conversation.** `continue -m MODEL` swaps the model on an in-flight conversation **with full context preserved**, the new model sees everything the prior one did. Start a probe on a free model, then escalate one hard turn to a premium model without losing state:
```
.../outsourcerer.sh run "Map the failure across these modules using subagents."
.../outsourcerer.sh continue -m claude-opus-4.8 "Now write the fix for the trickiest module."   # premium turn
.../outsourcerer.sh continue -m glm-5.2 "Apply the same pattern to the rest."                    # back to free
```
(For the interactive TUI, switch live with `session model`, see below.)

`yolo` (permission `dangerous`, auto-approves ALL tools) exists for trusted autonomous runs, use sparingly and only when the user asks.

**Always cd into the target project first** so Devin has the right repo context; the script runs in `$PWD`.

## Live supervision mode (`session`, tmux)

**This is the orchestrator's feedback loop, not a human-spectator mode.** `session` lets YOU (Claude, the orchestrator) watch a delegate's actual work as it happens and steer it mid-flight: `session read` captures what the model is doing right now, `session send` course-corrects or answers its question, `session model` swaps its model, `session stop` ends it. Headless `run`/`bg`/`fanout` fire-and-forget, so they only ever surface progress markers or a final result, you never get to catch a wrong turn early or unblock a stuck delegate in the moment. That read→steer→read loop is precisely what headless delegations miss.

**When to prefer it over headless:** long, complex, exploratory, or high-stakes delegations where an early correction saves a whole wasted run, or where the delegate is likely to need a clarifying answer. For short, well-scoped, obviously-correct work, headless is cheaper and fine.

**tmux is used by the `session` subcommand ONLY** (`run`/`research`/`edit`/`continue` are plain `devin -p`/`-c`, no tmux), so `session` is Mac/Linux; on Windows fall back to `bg` + `status` polling. Provider-aware: `--provider devin|codex|cc session start`.

**Separate tasks get separate sessions.** The tmux session name is derived from the working directory, so a `session start` in one repo can never clobber a concurrent live session in another (each `start` kills only its own name). `read`/`send`/`model`/`stop` run from the same `$PWD` and resolve the same session automatically. To run two isolated sessions in ONE directory, set `OUTSOURCERER_TMUX=<name>` explicitly for each. (`-p` modes were always isolated, each call is its own process.)
```
.../outsourcerer.sh session start [-m MODEL]   # launches devin TUI in $PWD (trust gate skipped)
.../outsourcerer.sh session read               # capture current pane (wait ~8s after start)
.../outsourcerer.sh session send "your prompt"
.../outsourcerer.sh session read               # read the response
.../outsourcerer.sh session model [NAME]       # switch model live (drives the TUI's opt+m picker)
.../outsourcerer.sh session stop               # tear down
```
`session model deepseek` filters the picker and confirms; `session read` then shows the new model in the footer (e.g. `✓ Model set to DeepSeek V4 Pro`). With no NAME it just opens the picker for manual select.

**Why tmux and not ACP?** Devin also ships `devin acp` (an Agent Client Protocol server over stdio, with `--agent-type review|summarizer`), a robust machine protocol, but using it means *building an ACP client* (handshake, sessions, permission callbacks). tmux needs zero protocol code and can drive TUI-only affordances like `opt+m`. For anything fire-and-forget, the non-interactive `-p`/`-c` path beats both. Use ACP only if this graduates into a real hosted integration.
