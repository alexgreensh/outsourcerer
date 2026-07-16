---
name: outsourcerer
description: 'Interactive copilot that offloads grunt work to a cheaper engine while Claude orchestrates. Greets each session with your live token limits and a driving mode (auto-pilot / you-drive / hybrid), auto-conserves when your Claude window runs hot, and picks models by live benchmarks. Triggers: outsource, offload, delegate, conserve tokens, use GLM/Devin/Codex, or get a second opinion.'
---

# Outsourcerer

**Created by**: [Alex Greenshpun](https://linkedin.com/in/alexgreensh)

Delegate the work Claude would hand its own subagents to a cheaper or different engine instead. Model-agnostic; default `glm-5.2` (a free Devin lane). One entrypoint:

```
${CLAUDE_PLUGIN_ROOT}/skills/outsourcerer/scripts/outsourcerer.sh <subcommand> [args]
```

Global flags (`--provider`, `--cloud-ack`) work anywhere, before or after the subcommand.

You drive this script in natural language; the user should never learn a flag. If you're explaining a command instead of running it, you're doing it wrong.

## Session start: the handshake (this is the default, not raw CLI)

**Every session begins by silently running `brief`** — it returns the ready lanes, the user's live limits (e.g. `claude5h=95`), and a conservation call in one shot. Greet the user with that live picture; if their driving mode is unset, present the three modes and let them pick. The choice is remembered (`~/.outsourcerer/mode`) — never ask twice.

- **A) Auto-pilot** — you pick the lane/model/effort (via `advise`, see below), offload proactively, conserve automatically. Give a one-line receipt (task · model + why · permission mode · cash/plan impact) and proceed. Still stop for: cloud consent, a mutating/dangerous escalation, an ambiguous goal, or real cash spend.
- **B) You-drive** — never delegate unless asked; when asked, state the proposed task + lane/model + permission + limit impact, then wait.
- **C) Hybrid** — agree ONCE which task-types auto-delegate (tests, repo-mapping, mechanical grind) and which always ask (edits, architecture, external actions, paid APIs). Uncertain type → ask, never stretch a category.

Set it with `mode auto|manual|hybrid` (A/B/C accepted). The user re-steers anytime in plain language ("take the wheel", "ask me first"). No mode weakens safety, consent, or permission mode.

**Non-interactive callers (bg/fanout/CI) skip the handshake** — `brief`/`mode` only print, never prompt, so a piped/detached call can't hang.

## Conserve on your own (watch the fuel gauge)

`brief` reads the real Claude 5h/7d window and the ChatGPT/Codex plan. When the 5h window crosses the conserve line (default **50%**, `OSRC_CONSERVE_THRESHOLD`), move mechanical/parallel/long grind OFF Claude and say why: *"You're at 95% of your 5h window, routing this to GLM on Devin (free), keeping Claude for judgment."* Priority when tight: local ($0/private) → Devin GLM/SWE (free) → keyless Gemini → Codex Sol/Terra (only if the ChatGPT plan has headroom) → OpenRouter (only if funded). Adapt to what the user has — a Codex-only user never gets a Devin tour. Auto/Hybrid do this automatically; You-drive recommends and waits. **Conservation changes ROUTING only**, never quality/safety/consent.

## Pick the model with data, not vibes

When the user hasn't named a model, **always run `advise`** — it classifies the task, pulls live benchmark scores, and returns the best value that clears the bar. This is the model-selection brain in **every** mode; the mode only decides whether you ask first (auto-pilot: take the winner + proceed; you-drive/hybrid: present it and wait). Cheap ≠ dumb: `glm`/`hy3`/`deepseek` are `capable` tier (frontier capability, budget price) and get flagship-grade prompting. Details: `references/model-advisory.md`, `references/effort-and-tiers.md`.

## The verbs (verb = permission mode)

`run`/`explore` (read-only) · `research` (sandboxed exec, devin/codex) · `edit` (auto-accept edits) · `yolo` (all tools, no sandbox — sparingly). Wrap any verb in `bg` for supervised background work (poll `status`), or `fanout` for N parallel jobs.

**`session` = YOU supervise a delegate live (not a spectator mode).** It's a persistent tmux TUI you drive programmatically: `session read` shows the delegate's actual work as it happens, `session send "…"` steers it mid-flight, `session model <name>` switches its model, `session stop` ends it. This is the one mode with a real feedback loop — headless `run`/`bg`/`fanout` fire-and-forget (you get progress markers or a final result, never the chance to course-correct mid-run). **Prefer `session` for long, complex, exploratory, or high-stakes delegations** where catching a wrong turn early, answering the delegate's clarifying question in the moment, or iterating with it beats one blind shot. The read→steer→read loop is exactly what watched sessions get and headless ones miss. (tmux-based → Mac/Linux; on Windows fall back to `bg`+`status`.) Full semantics + tiers: `references/mechanism.md`, `references/jobs-and-safety.md`.

## Model alias → lane (the alias picks the lane; no `--provider` needed)

| Alias(es) | Lane |
|---|---|
| `sol` / `terra` / `luna` / `gpt-5.5` | codex-native (ChatGPT sub); add `--provider claudex` to run it inside the Claude Code harness via the user's own CLIProxyAPI (offer only when `doctor` says claudex READY; unofficial bridge, detect-only) |
| `fable` / `opus` / `sonnet` / `haiku` | claude-native (Claude sub) |
| `gemini-pro` / `gemini-flash` / `gemini-flash-lite` | gemini (agy keyless) |
| `glm` / `hy3` / `deepseek` / any OpenRouter id | OpenRouter (`--provider cc`/`codex`); `capable` tier |
| `swe` / `swe-1.7` / `kimi` / any Devin id | devin (default); glm/deepseek self-heal here when OpenRouter is out of credits |
| `ollama:<m>` / `local:<m>` | local (keyless, PRIVATE, $0) |
| `gpt-image` / `nano-banana` | image only (`image` subcommand) |
| any model the USER configured | **droid** / **cursor** (`--provider droid|cursor`) — their CLI, their models (incl. BYOK); `-m` passes through verbatim |

Full table + image backend order: `references/lanes-and-models.md`.

## Operating rules

- **Cloud consent, once ever.** The first cloud delegation needs consent (repo content leaves the machine; a secret-scan hard-block runs on EVERY delegation regardless). Tell the user in one line, then `consent grant` (or `--cloud-ack`) — remembered in `~/.outsourcerer/cloud-consent`. Never retry a gate refusal blindly; the error names the fix.
- **Cost honesty.** Split cash from plan limits. A subscription/keyless run is $0 cash but spends finite plan limits — say both. Only the local lane is truly free. Details: `references/tab.md`.
- **"state home NOT WRITABLE"** = the sandbox denies `~/.outsourcerer`. The error spells out the two fixes (allowWrite, or `OSRC_HOME=`). Don't rerun unchanged.
- **Missing CLI?** Say what's missing in one line, suggest the fastest ready lane, keep going.
- **Windows: no WSL.** Runs under Git Bash; `outsourcerer.cmd`/`.ps1` launch it. Only tmux `session` is unavailable (bg/fanout cover it).

## Subcommands

Core: `brief` · `mode` · `consent` · `run`/`explore`/`research`/`edit`/`yolo` · `bg`/`fanout` (+ `status`/`watch`/`result`/`cancel`) · `advise` · `doctor` · `models`. More: `suggest`/`deals` (cheap now) · `estimate` (cost quote) · `tab` (the ledger) · `second-opinion` · `image` · `continue` · `tap` (capture live limits without token-optimizer) · `parity`/`parity-codex`/`parity-droid`/`parity-cursor` (two-way bridges) · `cleanup`/`gc`. Failure states map to one-line user messages (`done`/`done?`/`blocked`/`timeout`/`wedged`): `references/jobs-and-safety.md`.

## References

- `mechanism.md` — setup, provider flags, verb/tier semantics, `session` mode
- `lanes-and-models.md` — full alias/lane table, native lanes, image backends
- `jobs-and-safety.md` — background jobs, watchdog, exit codes, failure messages
- `parallel-and-fanout.md` — `fanout`, gauntlet recipe, self-heal
- `effort-and-tiers.md` — `--effort` per lane, capability-vs-price tiers
- `tab.md` — cash vs plan-limit accounting, estimates
- `model-advisory.md` — `advise`: classification, scoring, thresholds, fallback
- `second-opinion-and-parity.md` — `second-opinion`, `parity`, install paths, env vars
