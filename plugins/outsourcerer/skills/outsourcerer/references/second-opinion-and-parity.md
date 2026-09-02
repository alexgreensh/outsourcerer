# Second opinion, parity, and installation

Consensus-gated escalation, the reverse bridge back into Claude, porting the skill's capabilities
onto Devin/Antigravity, per-host install paths, and an index of the env vars used across the skill.

## second-opinion (consensus-gated escalation)

Run the same question on **two cheap models from different families**; if they agree, return the
answer for pennies; if they disagree, escalate to a premium model **with both answers attached**.

```
outsourcerer.sh second-opinion "Is this regex vulnerable to catastrophic backtracking? <regex>"
outsourcerer.sh second-opinion -m z-ai/glm-5.2,deepseek/deepseek-v4-pro "…"   # pick the pair
```
Tune with `OSRC_SECOND_OPINION_MODELS` (the two-model pair) and `OSRC_SECOND_OPINION_PREMIUM` (the
adjudicator). Consensus is decided by a normalized (lowercase-alphanumeric) comparison, so it is
strongest on short factual answers; for essay-length answers treat disagreement as "worth escalating."

## Running a specific Claude model (fable/opus/...) as an advisor, verified (read this)

Native Agent/Task subagents in Claude Code have a dangerous failure: when you pass `model: fable` but
Fable resolves to something unavailable (allowlist/plan/region), Claude Code **falls back to your
default model (usually Opus) with no error and no notice**, and there is **no authoritative way to verify** which
model a subagent actually used. That is exactly how an Opus run gets mislabeled as "Fable".

**So prefer the claude-native lane for a proven run:** `outsourcerer.sh run -m fable "…"`.

- **It VERIFIES the model.** The `claude -p` CLI reports the model it truly used (`modelUsage`), so the
  lane prints `[verified] ran on claude-fable-5` (or a loud `[WARNING]` on a mismatch). It cannot lie.
- **It works from inside Claude Code.** The lane strips the nested `CLAUDE_CODE_*` env (which otherwise
  makes the child `claude -p` report "Not logged in") and skips `--bare` for OAuth users (`--bare`
  forces API-key auth and breaks subscription login). Both fixes are automatic.
- **Honesty rules that still bind you (the orchestrator):** never claim a run used a model you cannot
  verify; never inject "you are Fable" into a prompt (a model does not become Fable because you say so);
  never punt to `/advisor` or any UI command (you cannot invoke those). If you do use a native subagent
  instead, treat its model as unverified and say so.
- A native subagent is still fine when you want the model to share your live in-session context; just do
  not assert which model ran. For an independent, provable advisor pass, the claude-native lane wins.

## Reverse bridge (insourcing): parity-codex

So a Codex session can delegate the hard turns back INTO Claude:
```
outsourcerer.sh parity-codex     # appends a managed insource block to $CODEX_HOME/AGENTS.md (idempotent)
```
It documents `outsourcerer.sh run -m fable "…"` (claude-native) and `--provider cc run "…"` for
Codex to discover. The script itself runs cleanly from a Codex shell.

`parity-droid` and `parity-cursor` do the same for Factory droid (`~/.factory/AGENTS.md`) and Cursor
(repo-root `AGENTS.md`) — those hosts read AGENTS.md, so the bridge is a managed block appended there.

## Reverse bridge (insourcing): parity-hermes

So a Hermes session can delegate the hard turns back into Claude/Codex/GLM. Hermes (NousResearch)
discovers **SKILL.md-format** skills from `$HERMES_HOME/skills/*/SKILL.md` (the same format
Claude/Devin/Antigravity use), NOT an AGENTS.md file — so the bridge is a **skill symlink**, not a
text block:
```
outsourcerer.sh parity-hermes    # symlinks outsourcerer into $HERMES_HOME/skills (idempotent, self-healing)
```
Once linked, a Hermes session sees the whole outsourcerer skill and can run
`outsourcerer.sh run -m fable "…"` (verified Claude), `--provider codex run "…"`, or
`run -m glm "…"` — the full lane set, from inside Hermes. This is the reverse of the Hermes
**delegation** lane (`--provider hermes` / `run -m hermes`), so Hermes now works **both ways**.
`HERMES_HOME` overrides the default `~/.hermes`. `parity` (the Devin sync) also mirrors this one
skill into `$HERMES_HOME/skills` as a bonus when that dir exists, alongside the Antigravity mirror.

## Parity (skills + MCPs: Claude → Devin)

So delegated work has the same capabilities as Claude:
```
.../outsourcerer.sh parity
```
This symlinks both your top-level `~/.claude/skills/*` **and your plugin skills** (compound-engineering/CE, token-optimizer, etc., the latest version of each, from the plugin cache) into Devin's global skill dir (Devin uses the same `SKILL.md` format), and ports your **local/stdio MCP servers** (with their env vars, across every project scope in `~/.claude.json`) into Devin via `devin mcp add`. Host-locked **claude.ai connectors and the Chrome MCP cannot port** and are skipped automatically. Run it once, and again whenever you add skills or local MCPs. `parity` now ALSO mirrors outsourcerer into the Antigravity skills dir when present (see below).

## Install on each host (Codex · Antigravity · Claude Code · Devin)

The helper is pure host-agnostic bash (`$0`-self-locating), so "installing" outsourcerer on a host
means putting it where that host discovers skills/instructions. Repo for install URLs:
`github.com/alexgreensh/outsourcerer`.

| Host | Discovery mechanism | Install path | Status |
|---|---|---|---|
| **Claude Code** | `~/.claude/skills/*/SKILL.md` (or a packaged plugin) | Already the source of truth here; the plugin build is packaged separately. | Done |
| **Devin** | `~/.config/devin/skills/*` (same `SKILL.md` format) + `devin mcp add` | Run `outsourcerer.sh parity`, it symlinks every Claude skill (incl. outsourcerer) into Devin and ports your local MCPs. | Covered by `parity` |
| **Antigravity** (`agy`) | SKILL.md skills in `~/.gemini/antigravity/skills` (→ `~/.gemini/config/skills`); plugins via `agy plugin import`/`install` | **Native:** `agy plugin import claude-code` (pulls your Claude skills into Antigravity, this is how Antigravity already imports Claude/Gemini skills). **Or automatic:** `outsourcerer.sh parity` now symlinks outsourcerer into that skills dir when it exists. **Or manual:** `ln -s ~/.claude/skills/outsourcerer ~/.gemini/antigravity/skills/`. | Covered by `parity` + native import |
| **Codex** | `${CODEX_HOME:-~/.codex}/AGENTS.md` (Codex reads AGENTS.md, not SKILL.md) | Run `outsourcerer.sh parity-codex`, it appends a managed block to `AGENTS.md` documenting how to call `outsourcerer.sh` (both the reverse bridge back into Claude and `--provider cc`). The bash script itself runs unchanged from a Codex shell. | Covered by `parity-codex` |
| **Hermes** (NousResearch) | `${HERMES_HOME:-~/.hermes}/skills/*/SKILL.md` (Hermes reads SKILL.md, like Claude/Devin) | Run `outsourcerer.sh parity-hermes`, it symlinks the outsourcerer skill into `$HERMES_HOME/skills` (idempotent, self-healing). A Hermes session then drives every lane. Delegation the other way is `--provider hermes` / `run -m hermes`. | Covered by `parity-hermes` (+ `parity` bonus mirror) |

Notes: Antigravity's own skills are `SKILL.md`-format folders (its builtin `antigravity_guide/SKILL.md`
confirms the format), and `agy plugin list`/`import` manage Claude/Gemini-sourced skills, so no
format conversion is needed. Codex has no SKILL.md loader; `parity-codex` is the correct entrypoint
(it makes the `outsourcerer.sh` path discoverable inside a Codex session's AGENTS.md).

## Env-var index

Quick pointer to where each env var is documented in full:

| Var | Controls | Documented in |
|---|---|---|
| `OUTSOURCERER_PROVIDER` | default `--provider` | `references/mechanism.md` (Providers) |
| `OR_OFFLOAD_CHAIN` | OpenRouter escalation chain when no `-m` given | `references/mechanism.md` (Providers) |
| `OSRC_GEMINI_VEHICLE` | force `agy` vs `gemini` CLI vehicle | `references/lanes-and-models.md` (Gemini/Antigravity lane) |
| `OSRC_AGY_FLASH_DEFAULT` / `OSRC_AGY_PRO_DEFAULT` | pin the id `agy` runs for `gemini-flash` / `gemini-pro` instead of the newest served member of the family (live from `agy models`) |
| `OSRC_GEMINI_FLASH_API_ID` / `OSRC_GEMINI_PRO_API_ID` / `OSRC_GEMINI_FLASH_LITE_API_ID` | same pins for the gemini-cli (API key) vehicle, which otherwise reads the Gemini API model list |
| `~/.outsourcerer/models.local` | your own `alias\|id\|lane\|tier` rows; they win over the built-in model table on every lane and survive plugin updates |
| `OSRC_TIER_BUDGET_MAX_USD_M` / `OSRC_TIER_MID_MAX_USD_M` | tier price cutoffs | `references/mechanism.md` (Tier-aware prompt wrapping) |
| `OUTSOURCERER_TIER` | force `--tier` | `references/mechanism.md` (Tier-aware prompt wrapping) |
| `OSRC_STALL_WARN` / `OSRC_STALL_KILL` / `OSRC_TIMEOUT` | stall/kill/timeout windows | `references/jobs-and-safety.md` (Liveness + background jobs) |
| `OSRC_SECOND_OPINION_MODELS` / `OSRC_SECOND_OPINION_PREMIUM` | second-opinion pair + adjudicator | this file (second-opinion) |
| `OUTSOURCERER_TMUX` | name an isolated `session` in a shared directory | `references/mechanism.md` (Interactive mode) |
| `OUTSOURCERER_LOADED` | legacy capability-inheritance flag (prefer `--with skills=…` instead) | `references/jobs-and-safety.md` (Orchestration rules) |
