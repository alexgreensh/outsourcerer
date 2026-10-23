# Lanes and models

Full detail behind the compact alias→lane table in `SKILL.md`: native lanes (codex-native /
claude-native), the Gemini/Antigravity (`agy`) lane, image backends, and model-recommendation
heuristics.

## Contents

- The model chooses the lane (aliases + native premium lanes)
- Claudex lane: GPT-5.6 Sol/Terra inside the Claude Code harness
- Engine lanes: droid (Factory) + cursor
- Cline lane
- Pi lane
- Grok Bot lane
- Gemini / Antigravity lane
- Local lane (Ollama / LM Studio / llama.cpp)
- TokenRouter lane
- Image generation
- Choosing / recommending models
- Never use a model: the exclude list
- Plan limits and cross-harness failover
- Notes (Devin's two pools)
- Alias quick table, full rows

## The model chooses the lane (aliases + native premium lanes)

You don't type `--provider` for premium models: the **model alias selects the lane**. `-m sol`
just works (codex-native). Native lanes use NO OpenRouter overrides, they ride *your own*
ChatGPT / Claude subscription auth, so they are premium and are **never** auto-escalated to.

| You type | Resolves to | Lane | Tier | Notes |
|---|---|---|---|---|
| `sol` | `gpt-5.6-sol` | codex-native | frontier | flagship; ChatGPT sub; never auto-escalated |
| `terra` | `gpt-5.6-terra` | codex-native | frontier | balanced everyday-strong |
| `luna` | `gpt-5.6-luna` | codex-native | mid | fast/affordable, still native |
| `gpt-5.5` | `gpt-5.5` | codex-native | frontier | ChatGPT sub |
| `fable` / `opus` | same | claude-native | frontier | Claude sub |
| `sonnet` / `haiku` | same | claude-native | mid / budget | Claude sub |
| `gemini-pro` | newest `gemini-*-pro` the vehicle serves (live) | gemini | frontier | PRIMARY = agy keyless (Antigravity login); fallback = gemini-cli + key |
| `gemini-flash` | newest `gemini-*-flash` the vehicle serves (live) | gemini | mid | strong agentic/coding default; keyless via agy |
| `gemini-flash-lite` | newest `gemini-*-flash-lite` (live; agy has no lite tier, so flash there) | gemini | budget | cheapest Gemini text tier |
| `gpt-image` / `codex-image` | `gpt-image-2` | codex-image | budget | **PREFERRED** image backend, **NOT** a text lane, use `image`; KEYLESS (Codex/ChatGPT sub) |
| `nano-banana` | newest `gemini-*-flash-image` the API serves (live) | gemini-image | budget | image FALLBACK #2, **NOT** a text lane, use `image`; needs `GEMINI_API_KEY` |
| `glm` | `z-ai/glm-5.2` | OpenRouter | **capable** | frontier CAPABILITY, budget PRICE (near-frontier); default cheap lane (`--provider cc`/`codex`) |
| `hy3` | `tencent/hy3:free` | OpenRouter | **capable** | near-frontier; `:free` = provider may train on inputs |
| `deepseek` | `deepseek/deepseek-v4-pro` | OpenRouter | **capable** | strongest cheap lane, pro reasoning flagship |
| any other OpenRouter id | itself | OpenRouter | by cached price, then name | see tiers below |
| `glm-5.2` under `--provider devin` | Devin's id | devin | table/name | Devin path unchanged |
| `glm-5.3` / `glm-5-3` | `glm-5-3` (Devin family; effort rungs `-low/-high/-max`) | devin | **capable** | GLM-5.3 full-size; plan-included |
| `glm-5.3-high` | `glm-5-3-high` | devin | **capable** | GLM-5.3 at the high rung |
| `glm-5.3-flash` | `glm-5-3-flash` (Devin family; rungs `-low/-high/-max`) | devin | **capable** | lighter GLM-5.3; `advise` prefers this family over full-size 5.3 below `--effort max` |
| `glm-5.3-flash-high` | `glm-5-3-flash-high` | devin | **capable** | the cheaper capable variant `advise` recommends for agentic/edit work at `--effort high` |
| `swe` / `swe-1.7` | `swe-1.7` | devin | **capable** | Devin's own SWE agent model (open-weight/free-lane class) |
| `swe-1.7-lightning` | itself | devin | mid | faster/cheaper SWE variant |
| `kimi` | `kimi-k3` | devin / droid / warp | **capable** | near-frontier hard-work lane; provider-specific dispatch resolves the accepted K3 id |

**Dual-lane self-heal:** `glm` and `deepseek` exist on BOTH OpenRouter and Devin. With the default
provider, they route to Devin (which has quota) instead of hard-failing when the OpenRouter key is
out of credits; force OpenRouter with `--provider cc|codex`. `hy3` is OpenRouter-only.

## Claudex lane: GPT-5.6 Sol/Terra INSIDE the Claude Code harness (`--provider claudex`)

The community "claudex" pattern (Theo's recipe): more and more users treat the **model and the
harness as separate choices**: Claude Code's harness UX driving a ChatGPT-subscription model.
This lane does it supervised: `--provider claudex run [-m sol|terra|luna] "task"` runs
`claude -p --model gpt-5.6-*` with `ANTHROPIC_BASE_URL` pointed at the user's **locally-running
CLIProxyAPI** (default `http://127.0.0.1:8317`, token = the proxy's own `api-keys` entry,
auto-parsed from `~/.cli-proxy-api/config.yaml`; override with `OSRC_CLAUDEX_URL`/`OSRC_CLAUDEX_TOKEN`).

- **Detect-only, by policy.** Outsourcerer never installs or launches the proxy. The user installs
  and audits it themselves (https://github.com/router-for-me/CLIProxyAPI, then
  `cli-proxy-api --codex-login`). Our own supply-chain audit of that repo is in the project
  findings; treat release binaries with the usual skepticism and prefer building from source.
- **Disclosures the lane prints every run:** unofficial community bridge; the upstream Codex
  endpoint is internal/not guaranteed; the proxy has no rate limiting, so heavy unthrottled use
  risks provider-side account limits. The official, ToS-clean alternative for Codex-in-Claude is
  OpenAI's `codex-plugin-cc` plugin.
- **Claude-sub models are refused here** (`-m fable --provider claudex` dies): routing Claude OAuth
  through a third-party proxy breaks Anthropic's usage policy; the claude-native lane already
  serves those models first-class.
- Verbs map like claude-native (`run` read-only, `edit` acceptEdits, `yolo` bypassPermissions,
  `research` refused, no OS sandbox); the run VERIFIES the actual model via `modelUsage`.
- **codex CLI keeps its jobs**: gpt-image generation and the codex-native/OpenRouter lanes are
  unchanged; claudex is an additional road, not a replacement.

## Engine lanes: droid (Factory) + cursor, the user's OWN tools

`--provider droid` / `--provider cursor` delegate through the agent CLI the user already runs, with
the models THEY configured there. This is the "work with MY tools" lane: someone with free/cheap
BYOK API lanes set up in droid (`~/.factory/settings.json` → `customModels`) or a Cursor
subscription gets full outsourcerer supervision (bg/fanout/watchdog/ledger/cloud-gate) over their
existing setup, zero new keys, zero migration.

- `-m <name>` passes through **verbatim** to the engine; the alias table never rewrites it. No
  `-m` = the engine's configured default.
- Verbs map to the engine's own autonomy: droid `run`=read-only, `edit`/`research`=`--auto medium`,
  `yolo`=`--auto high`; cursor `run`=propose-only, `edit`=`--force`,
  `research`=`--force --sandbox enabled`, `yolo`=`--force --sandbox disabled`.
- `--effort` is native on droid (`droid exec -r`), advisory on cursor.
- Billing: droid = the user's Factory plan or their BYOK keys; cursor = their Cursor subscription
  credits. Both are cloud lanes → full cloud gate + secret-scan apply.
- Auth: `droid` login once interactively (or `FACTORY_API_KEY`); `cursor-agent login` once (or
  `CURSOR_API_KEY`). `doctor` shows install/auth state for both.

**Guardrails:** `gpt-5.6-*` (Sol/Terra/Luna) are ChatGPT-backend-only and 400 through OpenRouter,
so `-m sol --provider cc` **hard-dies** with the reason (drop `--provider`; the codex-native lane
needs no key). Symmetrically `-m fable --provider codex` dies (Claude-backend-only). `run -m opus
"…"` and `run -m sol "…"` need no `--provider` at all. See the full alias/lane/tier map:
`outsourcerer.sh models --refresh`.

## Cline lane (`--provider cline`)

`--provider cline` delegates through the Cline CLI (https://github.com/cline/cline) the user
already runs, with the provider and models THEY configured in `~/.cline`. This is the "work with MY
tools" lane for Cline users. Billing is theirs: a **ClinePass subscription** (~$9.99/mo, discounted
access to open-weight models like GLM, DeepSeek, and Kimi) or their own API keys; the roster and
pricing are cline's, not ours, so do NOT hardcode or promise a specific model or price. Full
outsourcerer supervision (bg/fanout/watchdog/ledger/cloud-gate) applies.

- `-m <name>` passes through **verbatim** to cline; the alias table never rewrites it. No `-m` =
  cline's configured default (read from `~/.cline/data/settings/providers.json`).
- **Models are cline's, discovered live, not ours:** pass whatever cline is set up with via
  `-m provider/model` (e.g. `-m z-ai/glm-5.2`). To see what is genuinely cheap or free RIGHT NOW
  across all lanes, use `suggest`/`deals` (they read each catalog live) rather than trusting a
  hardcoded list.
- **Posture is BINARY, not graded:** `run`/`explore` → `--plan` (read-only, no edits/commands
  applied, **version-gated**: requires cline >= 3.0.36, where Plan mode stopped falling back to
  shell edits; on an older CLI the read-only tier is refused, not silently trusted); `edit`/`research`/`yolo` → default act mode with `--auto-approve true` (all tools
  auto-approved). Cline has **no OS sandbox and no middle approval rung**; the trade is disclosed
  in the posture banner, never silent. Treat `research`/`yolo` on cline as fully autonomous with no
  sandbox boundary; prefer `run` (plan mode) for read-only inspection.
- `--effort` is **native** on cline (`--thinking none|low|medium|high|xhigh`).
- Billing: your ClinePass subscription or the provider keys in `~/.cline`. Cloud lane → full cloud
  gate + secret-scan apply.
- Auth: `cline auth cline` to sign in to ClinePass, or configure your own keys. `doctor` shows install/auth
  state and **best-effort** reads the configured provider + default model from
  `~/.cline/data/settings/providers.json` (the schema is based on observed Cline 3.0.x layouts and
  may change in future versions; both reads degrade to "not detected" on an unparseable file).
- **Supervision limitation (disclosed):** Cline's hub/spoke lifecycle can spawn detached spokes
  that survive a `cancel`/watchdog kill (same class as codex MCP grandchildren on macOS, which has
  no `setsid`/process-group-kill). `_kill_tree` does best-effort reaping of the direct process tree;
  if a cline bg job is cancelled, verify with `ps aux | grep cline` that no spokes linger. This is
  a known limitation, not a silent gap.

## Pi lane (`--provider pi`)

`--provider pi` delegates through Pi (https://github.com/earendil-works/pi), the open-source coding
agent, with whatever the user signed it in to. Pi's `/login` covers Claude Pro/Max, ChatGPT, GitHub
Copilot, OpenRouter, Kimi, xAI and others, or it uses provider API keys. Billing is theirs; the roster
is Pi's, so do NOT promise a model or price.

- `-m <name>` passes through **verbatim** to `pi --model` (`provider/id`, a fuzzy name like `sonnet`,
  or a `:thinking` suffix). No `-m` = Pi's configured default.
- `--effort` is **native**: `--thinking minimal|low|medium|high|xhigh|max`.
- Runs headless as `pi -p --no-session`, so delegated runs stay out of Pi's session history.
- **Posture:** Pi never asks before a tool runs and has **no sandbox**. `run`/`explore` are read-only
  by tool list (`--tools read,grep,find,ls`). `edit`, `research` and `yolo` get Pi's default tools
  (read, bash, edit, write) and are fully autonomous. The banner says so.
- **Context:** Pi reads `AGENTS.md` and `CLAUDE.md`, and skills from `~/.pi/agent/skills` and
  `~/.agents/skills`, but not `~/.claude/skills`. `--with` grants travel in the prompt, as on Cursor.
  Pi has its own MCP config (`pi mcp add`).
- Install: `npm i -g @earendil-works/pi-coding-agent` (or the installer on https://pi.dev), then run
  `pi` and `/login` once. `doctor` shows whether it is on PATH. `session start --provider pi` opens
  Pi's TUI in tmux.

## Grok Bot lane (`--provider grokbot`)

Grok Bot (xAI's always-on agents, each with its own cloud computer) has **no chat API**. A bot
**routine** can be started by a webhook, so this lane posts the task to the user's routine and the
bot delivers by **pushing a git branch** to the repo's origin. The lane waits for that branch, prints
`OUTSOURCERER_RESULT.md` from it, and names the branch. Nothing is merged: review it, or `land` it.

- Setup, once: in Grok Bot create a routine with a **Webhook** trigger and the instruction "Follow
  the instructions in the webhook payload exactly". Put its URL and key in `~/.env` as
  `GROKBOT_WEBHOOK_URL` and `GROKBOT_WEBHOOK_KEY`. The URL must be https. The bot needs push access to
  the repo (its GitHub connection).
- Run it inside a git repo with an `origin`. The bot clones origin, so uncommitted or unpushed work
  is invisible to it (the lane warns).
- `run`/`explore` ask the bot to change nothing but its result file. This is an **instruction, not
  an enforced mode**: Grok Bot has no read-only switch. `edit`/`research`/`yolo` let it edit, on its
  own branch only.
- `-m` and `--effort` have no effect: the bot picks its own model.
- Waiting: polls origin every `OSRC_GROKBOT_POLL` seconds (default 20) for up to
  `OSRC_GROKBOT_TIMEOUT` (default 3600). Past the deadline it exits 124; the routine may still finish
  later, so check Grok Bot. Each poll prints a progress line, so the watchdog never reads it as hung.
- Billing: the bot's weekly allowance. Cloud lane: the full cloud gate applies.
- **Beta.** Built to the documented webhook, not yet run against a live bot. Community reports say
  webhook payloads sometimes arrive empty; if no branch ever appears, open the routine's run in Grok
  Bot and check what it received.

**Running Outsourcerer ON a Grok Bot.** The repo ships a Cursor plugin manifest (`.cursor-plugin/`),
so a bot can install the skill from the plugin marketplace (a team admin can import the repo). The
bot's computer is Linux and usually has no tmux, so slow runs fall back to the headless `bg` path.
Two cautions: a computer reset wipes installed CLIs (keep keys as Grok Bot secrets, never in shell
profiles), and idle computers can pause, so prefer short jobs or a routine that checks back.

## Gemini / Antigravity lane, text delegation + visual review + image gen

`gemini-pro` / `gemini-flash` / `gemini-flash-lite` are model-alias-selected exactly like
`sol`/`fable`, no `--provider` needed. Two vehicles, auto-selected:

**PRIMARY, Antigravity CLI `agy`, KEYLESS (the whole point).** When `agy` is on PATH the lane
dispatches through it in headless print mode (`agy -p`), riding **your existing Antigravity/Google
app login, no API key needed**. Verified live on `agy` v1.0.2: `-p` returns clean output through
pipes/redirects/subprocesses (the way this skill captures it), keyless. The old non-TTY
stdout-drop bug is fixed per agy's own changelog ("print mode / non-TUI outputs silently discarded
in non-TTY environments", fixed), as are print-mode error/exit-code handling and `--sandbox`
propagation in `-p`. Tiers map to agy flags: `run`→plain `-p` (read-only), `edit`/`research`→
`--sandbox --dangerously-skip-permissions` (sandboxed autonomy), `yolo`→`--dangerously-skip-permissions`.

**FALLBACK, `gemini` CLI (gemini-cli) + `GEMINI_API_KEY`.** For users who prefer an API key (or
have no Antigravity login): install gemini-cli and add `GEMINI_API_KEY`/`GOOGLE_API_KEY` to
`~/.env` (single-key extraction, same rule as `OPENROUTER_API_KEY`, never `set -a`). Used
automatically when `agy` is absent, or force it with `OSRC_GEMINI_VEHICLE=gemini`. Force agy with
`OSRC_GEMINI_VEHICLE=agy`.

`doctor` reports which vehicle is in use and prints the exact install + one-step auth for whichever
you're missing.

**Recommendation, route visual-review work to Gemini:** Gemini-series models are a genuine
strength for **visual analysis and review** (UI/UX critique, screenshot review, design feedback,
"does this mockup match the spec") **when paired with the right skills** (e.g. this repo's
`impeccable`/`frontend-design`/`lazyweb` skills for design vocabulary, or `--with skills=…` to
inject a specific one). When a delegated task is fundamentally "look at this image/screenshot and
judge it," prefer `-m gemini-flash` or `-m gemini-pro` over the OpenRouter/Devin budget lanes.

```
outsourcerer.sh run -m gemini-flash --with skills=impeccable "Review screenshot.png against our design system; list violations."
outsourcerer.sh run -m gemini-pro "Critique this onboarding flow for cognitive load and hierarchy: <screenshot path/description>"
```

**Model IDs are resolved LIVE, never from a table.** Google retires dated Gemini ids every few
weeks and `agy` hard-errors on a retired one, so the three family aliases are symbolic and each
vehicle picks the newest family member it actually serves at dispatch time: `agy` from `agy models`,
gemini-cli from the Gemini API model list (both cached for `OSRC_CATALOG_TTL` seconds, default 300).
An explicit `-m gemini-3.7-flash` is sent as-is while the catalog serves it; once the catalog says
it is retired, the run moves to the newest member of that family and says so on stderr, naming the
retired id. If `agy` refuses a model anyway, the cached catalog is dropped so the next run re-reads
it. Precedence, highest first:

1. an env pin: `OSRC_AGY_FLASH_DEFAULT` / `OSRC_AGY_PRO_DEFAULT` (agy) and
   `OSRC_GEMINI_FLASH_API_ID` / `OSRC_GEMINI_PRO_API_ID` / `OSRC_GEMINI_FLASH_LITE_API_ID` (gemini-cli);
2. a row in `~/.outsourcerer/models.local` (see below) that maps the alias to a concrete id;
3. the newest matching id in the live catalog;
4. a last-known id, used only when the catalog cannot be read at all.

**`~/.outsourcerer/models.local`** holds your own `alias|id|lane|tier` rows (same shape as the
built-in table, `#` comments allowed). Its rows win over the built-in table on every lane, so a
retired or renamed id anywhere is a one-line fix that survives plugin updates. Example:

```
# pin the keyless flash lane to a specific release
gemini-flash|gemini-3.7-flash|gm|mid
```

## Local lane, Ollama / LM Studio / llama.cpp (KEYLESS, PRIVATE, $0)

Run inference on the user's **own hardware**: `$0` cash, `$0` plan limits, and nothing leaves the
machine, the privacy lane for sensitive or freshly-hardened IP you must not hand to a cloud model
that might train on it. Model aliases select it, no `--provider` needed (though `--provider local`
also works):

```
outsourcerer.sh run -m ollama:qwen2.5-coder "summarize these release notes"   # Ollama :11434
outsourcerer.sh run -m lmstudio:<model> "..."                                  # LM Studio :1234
outsourcerer.sh run -m local "..."      # auto-detect the server AND auto-pick a loaded model
outsourcerer.sh --provider local run -m <model> "..."
```

- **Vehicle: a direct streaming call to the server's `/v1/chat/completions`** (curl + jq, no extra
  install, no harness). Universal: works with Ollama, LM Studio, llama.cpp, or any OpenAI-compatible
  server. `doctor` probes Ollama `:11434`, LM Studio `:1234`, llama.cpp `:8080` and reports what's
  live; override the endpoint with `OSRC_LOCAL_URL=http://host:port/v1` (also honors `OLLAMA_HOST`).
- **Streaming** feeds the liveness watchdog, so local works under `bg` and `fanout` (parallel private
  agents) too.
- **It is TEXT delegation**, the local model reasons over the prompt you give it (inject files with
  `--with skills=…` or inline). It does **not** autonomously read the repo or run tools. Why: the
  agentic harnesses can't drive a local Chat-Completions server, Codex 0.144 dropped `wire_api="chat"`
  (so it can't talk to Ollama at all), and Claude Code's lane speaks the Anthropic Messages API, which
  local servers don't serve. **Agentic local tool-use** (e.g. a review skill reading the repo locally)
  needs a Responses-API-capable local server (LM Studio) driven via the codex provider, or an
  Anthropic↔OpenAI proxy for the `cc` lane, treat that as an advanced/follow-up path, not the default.
- **Tier**: classified by model name (a local `qwen2.5-coder`/`llama-4` reads as `capable`; a small
  `*-mini`/`*-lite` as `budget`). Local model quality varies wildly, so pass `--tier` to correct it.

## TokenRouter lane (`--provider tokenrouter`): OpenAI-compatible gateway

`--provider tokenrouter` delegates through [TokenRouter](https://www.tokenrouter.com), an
OpenAI-compatible model gateway, using the key in `TOKENROUTER_API_KEY` (`~/.env`, single-key
extraction, never `set -a`). This is the "any OpenAI-compatible cloud gateway" lane: a direct
streaming call to the gateway's `/v1/chat/completions` (curl + jq, no extra install, no harness).

```
outsourcerer.sh run --provider tokenrouter -m <gateway-model-id> "summarize these release notes"
```

- **`-m` is REQUIRED and passes through VERBATIM** to the gateway's own catalog; the alias table
  never rewrites it. There is NO hardcoded default model; the roster is TokenRouter's, discovered
  live, not ours. List it with
  `curl -s -H "Authorization: Bearer ***" https://api.tokenrouter.com/v1/models`.
- **It is a CLOUD lane**: the prompt LEAVES the machine, so it flows through the same cloud-consent
  gate + secret-scan hard-block as every other cloud lane. Override the endpoint with
  `OSRC_TOKENROUTER_URL` (default `https://api.tokenrouter.com/v1`).
- **It is TEXT delegation** (same contract as the local lane's text path): the model reasons over the
  prompt you hand it (inject skills with `--with skills=…` or inline). It does NOT autonomously read the repo
  or run tools. Reasoning models consume tokens on reasoning before visible content, so the timeout
  is generous (`OSRC_TOKENROUTER_TIMEOUT`, default 900s).
- **Streaming** feeds the liveness watchdog, so tokenrouter works under `bg` and `fanout` too.
- **COST HONESTY (do not hardcode):** the roster and pricing are TokenRouter's and change. Some
  models are a **$0 promo RIGHT NOW**; that is confirmed at RUNTIME by
  billing/quota errors (402/429), never by a hardcoded date or a static "free" claim. The Tab records
  the run as unmeasured cash (per-run gateway cost is not captured here); treat a $0 promo as a
  runtime fact, not a promise.
- **Auth:** add `TOKENROUTER_API_KEY=*** to `~/.env` (get a key: https://www.tokenrouter.com).
  `doctor` reports key presence and runs a bounded liveness probe against the gateway's `/models`.

## Image generation, GPT-image preferred, backend AUTO-RESOLVED

`image` is a **dedicated subcommand**, not a text-delegation lane, routing an image model through
`run`/`edit`/`yolo` hard-dies with a pointer back here. It resolves the backend itself; you never
have to ask the user which one to use. **Preference order (never hardcode which is "installed" , 
`doctor` detects it live):**

1. **`gpt-image` / `gpt-image-2` via Codex, PREFERRED, KEYLESS.** When `codex` is on PATH, logged
   in, and its `image_generation` + `artifact` features are available (`codex features list`),
   this is used automatically. It drives `codex exec` against Codex's built-in image tool, billed
   to the user's **Codex/ChatGPT subscription**, no API key, no per-image charge. The invocation
   (stdin prompt + save-to-path instruction, `--sandbox workspace-write --enable artifact`, with a
   freshest-file-in-`$CODEX_HOME/generated_images/` fallback) mirrors this repo's `illo` skill's
   verified Codex image mechanism (`~/.claude/skills/illo/scripts/illo.py`), read directly from
   its source, not re-derived.
2. **`nano-banana` / `gemini-2.5-flash-image`, FALLBACK #2.** Used when Codex isn't ready. Needs
   `GEMINI_API_KEY`/`GOOGLE_API_KEY` in `~/.env`: it calls the Gemini `generateContent` REST API
   directly (curl + jq). This is the one Gemini feature that needs the API key even when your text
   lane is keyless-via-agy, agy's keyless headless model list has no image model, and neither CLI
   documents a "write a PNG to disk" headless mode.
3. **An OpenRouter image model, FALLBACK #3.** Used when neither of the above is ready and
   `OPENROUTER_API_KEY` is in `~/.env` (default `x-ai/grok-imagine-image-quality`; pass any other
   OpenRouter image id via `-m`).

`doctor` prints which backend resolves **right now** under "Image generation." Force one explicitly
with `-m gpt-image` (codex), `-m nano-banana` (gemini), or `-m <openrouter-image-id>`:

```
outsourcerer.sh image "a red panda skateboarding through neon rain, synthwave poster style"   # auto-resolved
outsourcerer.sh image -m gpt-image "isometric SaaS dashboard icon set, flat pastel" icons.png  # force Codex
outsourcerer.sh image -m nano-banana "..." icons.png                                           # force Gemini
```

Newer Gemini image tiers exist (`gemini-3.1-flash-image` / "Nano Banana 2" and `gemini-3-pro-image`
/ "Nano Banana Pro") but are not wired as aliases yet, pass the raw id via `-m` for one of those.

## Choosing / recommending models (never hardcode, it changes)

The free/cheap lane on Devin **shifts frequently**. To see what is selectable *right now*:
```
.../outsourcerer.sh models
```

Recommendation rules:
- Default to **`glm-5.2`** unless the user asks otherwise. It is **plan-included** on Devin: it does
  not spend the paid ACU balance, but on Pro it DOES draw on the shared **daily plan quota** (see the
  note below). For agentic/edit work `advise` now prefers **`glm-5.3-flash-high`** (lighter, same
  capability class) when it is available.
- **Cheap ≠ dumb.** `glm-5.2`/`hy3`/`deepseek-v4-pro` are the **`capable`** tier: frontier capability
  at budget price (near-frontier). They are valid for high-stakes reasoning, security review, and
  deep judgment, not just grunt work. See `effort-and-tiers.md`. Pair them with `--effort high`/`max`
  when the task is hard. Only route AWAY from genuinely *small* models (`haiku`/`gemini-flash-lite`/`*-mini`).
- The **open-weight** families (`glm*`, `deepseek*`, `kimi*`, `swe*`) are usually the free / low-cost lane, recommend these when the user wants "a free model."
- **Premium** families (`claude*`, `gpt*`, `gemini*`) typically consume Devin usage/ACUs faster. Flag this before routing heavy work to them, and confirm with the user.
- Treat all of the above as a heuristic, not gospel. If the user needs certainty on current cost, point them to their Devin usage dashboard.
- **Task-type routing (apply by hand when picking `-m`):** `advise` scores models by benchmark and
  `suggest` lists what is cheap right now, but neither knows these two task-type rules. Visual-review / image-understanding tasks
  (screenshot critique, UI/UX review, "does this match the mockup") → route to `gemini-flash` or
  `gemini-pro` (see the Gemini/Antigravity section above). Image-*generation* tasks → the `image`
  subcommand, backend auto-resolved (GPT-image/Codex preferred, nano-banana and OpenRouter as
  fallback, see "Image generation" above).

## Never use a model: the exclude list (`exclude`)

For a model the user cannot or will not use (no Fable subscription, a model their company forbids),
put it on the exclude list once. It persists across sessions; telling the orchestrator "never use
Fable" in chat does not.

```
outsourcerer.sh exclude add fable          # saved in $OSRC_HOME/exclude
outsourcerer.sh exclude ls                 # what is excluded (saved + env)
outsourcerer.sh exclude check claude-fable-5-1   # rc0 = excluded, says which entry matched
outsourcerer.sh exclude rm fable           # allow it again
outsourcerer.sh exclude clear              # drop the saved list
```

`OSRC_EXCLUDE_MODELS="fable,gpt-5.6-*"` adds entries for one shell or CI, on top of the saved list.

**What an entry matches** (case-insensitive). Every name is compared in its canonical form, so the
same model matches however it is spelled: alias, exact id, provider-prefixed id (`anthropic/`, `z-ai/`,
`openai/`), dotted or dashed version (`glm-5.2` = `glm-5-2`), a `[1m]` suffix, an effort suffix
(`-high`, `-max`, `-preview`) or a date stamp (`-20251001`).
- a **family word** covers every model of that family: `fable` matches `fable`, `claude-fable-5`,
  `claude-fable-5-1`, `anthropic/claude-5-fable`, `claude-fable-5-1[1m]`; `claude` covers every
  Claude family (fable, opus, sonnet, haiku);
- an **alias** also matches what it resolves to (`sol` matches `gpt-5.6-sol`, `glm` matches `z-ai/glm-5.2`);
- an **exact id** covers that model in every spelling (`claude-fable-5` matches
  `anthropic/claude-5-fable` and Devin's `claude-fable-5-high`), but **not** a different release or
  size: `claude-sonnet-5` leaves `claude-sonnet-5-5` allowed, `gpt-5.5` leaves `gpt-5.5-mini` allowed,
  `gemini-flash` leaves `gemini-flash-lite` allowed. To cover point releases use a glob
  (`claude-fable-5*`) or the family word;
- a **bare family alias** is refused when the family word itself is excluded, or when an entry
  covers the model that alias runs **today**: `sol`/`terra`/`luna`/`glm`/`swe` use the alias table,
  and `fable`/`opus`/`sonnet`/`haiku` use the current Claude ids (`claude-fable-5-1`,
  `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`). An entry also covers the current id
  when that id is a listed point release of it (today only `claude-fable-5-1` of `claude-fable-5`),
  so `exclude add claude-fable-5` refuses `-m fable` and `claude-opus-5-5` refuses `-m opus`, while
  excluding a different, older model (`claude-sonnet-5`, `claude-opus-5`, `claude-opus-4-8`) leaves
  `-m sonnet` / `-m opus` usable. `gemini-pro`,
  `gemini-flash` and `gemini-flash-lite` pick their id live, so any excluded version of that family
  refuses them (fail closed, and the refusal says why); name an exact id with `-m` instead;
- a **glob** (`gpt-5.6-*`; only `*` and `?` are wildcards) is matched against the name, its resolved
  id and its canonical form;
- short family words reach further than they look: `pro` also matches `deepseek-v4-pro`, `flash`
  matches `glm-5.3-flash`. `exclude add` prints every known model the entry covers, so check that line;
- an entry with no letters (`5`) is refused, so a typo can never exclude half the catalog;
- an entry that is not a valid model name (only a hand-edited file or `OSRC_EXCLUDE_MODELS` can hold
  one, `exclude add` rejects it) **fails closed**: every model counts as excluded, with a warning
  naming the entry, until you fix or remove it. A matcher failure fails closed the same way.

**Where it is enforced.** An explicit `-m` naming an excluded model is refused with one line naming
the fix, on every verb (`run`/`explore`/`research`/`edit`/`yolo`/`bg`/`fanout` incl. `--route` and
agent frontmatter/`crew`/`loop verify`/`loop escalate` incl. `--ladder`/`second-opinion -m a,b`/
`continue`/`session start`/`session model`/`task add -m`). The id an alias **resolves to** is checked
again just before launch: Devin's live catalog (`-m claude` resolving to a Fable id is refused), the
Gemini family pick (`-m gemini-pro` resolving to an excluded dated id), and the droid/warp alias maps.
Automatic choices skip it: `advise` (text and `--json` recommendation + shortlist), the transport
fallback shortlist, cross-harness failover, the OpenRouter chain (`OR_OFFLOAD_CHAIN`), the
`second-opinion` default pair (a swap never picks a model that resolves to the other one) and premium
judge (an excluded judge falls back to the next allowed one: opus, terra, gemini-pro, sol, and says
so), the `loop escalate` default ladder (the rung is dropped out loud; when that leaves one rung the
error says the exclude list did it), `suggest`/`deals` listings, fleet session naming, the `doctor`
ping probes (codex, claude, agy, gemini-cli) and Devin health/plan probes (the next allowed probe model
is used, or the probe is skipped). A provider whose built-in default is excluded (e.g. `--provider
devin` with `glm` excluded) is refused with the fix rather than run, and `fanout` refuses it up front,
before any member starts. When everything a request could use is excluded, it stops with a clear
message; it never quietly runs an excluded model.

**Models outsourcerer cannot see.** While a list is active:
- `continue` without `-m` is refused (the conversation keeps its original model, which may be excluded); pass `-m`;
- `session start` without `-m` on Claude Code or Codex checks the CLI's configured default
  (`ANTHROPIC_MODEL` / `~/.claude/settings.json`, `~/.codex/config.toml`) and refuses when it is
  excluded, or when none is configured and the list covers a model of that family; pass `-m`;
- a session is never relaunched (`session control relaunch`, `session effort`) or drift-restored onto a
  model you have since excluded;
- engine lanes run without `-m` (droid, cursor, hermes, cline, pi, a Devin session) use the model the
  engine is configured with, which outsourcerer cannot see; they print one line saying so. Pass `-m`
  to be sure;
- a background job whose `-m` was excluded after it was queued fails with reason `excluded-model`.

**Why it sticks.** `brief` (the session-start handshake) and `doctor` print the active list, so every
new orchestrator session sees it before it picks a model.

**Cost.** With no list, the checks cost nothing (no extra processes). With a list, entries are read
once per process and each distinct model name is matched once.

Not covered: the `image` subcommand's automatic backend pick (image-only models; `image -m X` is
refused like any -m), and `OSRC_MODEL_DENYLIST` (the older exact-id org denylist, still honored alongside).

## Plan limits and cross-harness failover

Every subscription harness eventually refuses work because *its own* plan window is spent: Devin's
daily/weekly bucket, the ChatGPT 5-hour/weekly windows behind Codex, the Claude windows behind
Claude Code, Cursor's monthly usage, Warp's credit quota, Droid's rolling rate limits, Cline's daily
free cap. Outsourcerer treats all of them the same way, in three steps.

**1. Detect it, per harness, from the CLI's own words.** After a failed run (or a headless
`claude -p` result flagged `is_error`), the captured output goes through one dispatcher,
`_lane_plan_limit_refusal <lane> <errfile>`, which routes to a per-lane matcher grounded in that
CLI's real refusal wording ("You've hit your usage limit. Try again in 2h 15m", "Claude usage limit
reached. Your limit will reset at 3pm", "Request failed with error: QuotaLimit", "Daily free limit
reached … Try again in 9h 41m", and so on). Matchers are context-anchored: a limit noun only counts
beside a spent verb or a reset phrase, so a context-window error, a transient per-minute 429, or a
task's own output that happens to say "limit" is never read as a plan refusal. A lane with no
matcher is a non-match, never a guess. Nothing hardcodes a plan number or a model roster.

**2. Probe, then decide. Never assume.** A refusal from ONE model does not prove a whole harness is
dead. Before any lane is marked down, `_lane_free_probe <lane>` runs one bounded, cheap check:
Devin gets a real request to a *sibling* free model (not the one just refused); Codex and Claude
Code are confirmed from their own live meters; the other lanes have no cheap probe yet. The result
decides:

| Probe says | What happens |
|---|---|
| `limit-refused` | **Confirmed.** The lane is marked down until the reset the harness itself stated (+60 s slack), or a labeled estimate (`OSRC_LANE_PLAN_DOWN_TTL`, default 1h) when it stated none. |
| `answered` | **Not confirmed.** The lane stays up and nothing is marked; you are told which model was refused on that run and which one answered, so you can use the one that works. |
| `unreachable` / no probe | **Unverified.** Only the short self-healing transport window (`OSRC_LANE_DOWN_TTL`, default 300 s). A five-minute skip of a lane that just refused is cheap; a day-long block on a guess is not. |

`brief` and `status` show a per-lane meter ("N <lane> plan jobs today") plus any live lane-down
notice with its reason and time left.

**3. Fail over to a harness you actually have.** When the harness a job is running on is confirmed
(or plausibly) spent, the job moves. `_failover_pick` chooses from lanes that are ready *right now*
(their CLI/key/login present, no lane-down marker), in this order:

- the **same model** on another harness, when the alias table, a cached catalog, or a shared
  family alias says that harness serves it (kimi-k3 on Droid or Warp, glm on OpenRouter, …);
- else the **nearest-tier equivalent** from the tier table (frontier / capable / mid / budget):
  smallest tier distance first, cheaper tier on a tie, then lane preference order (plan lanes
  before cash lanes). Engine lanes contribute their default model.

Cash lanes (OpenRouter, TokenRouter, Claudex) are **never used silently**: they join the candidate
list only when `OSRC_FAILOVER_CASH_OK=1` is set; otherwise the stop message names them and the
switch. A pinned `-m` is moved only to the *same* model on another harness; a different-model pick
is refused loudly unless `OSRC_FALLBACK_PINNED=1`. Hops are bounded per job (`OSRC_FAILOVER_MAX`,
default 2) so two spent lanes cannot ping-pong. The `local` lane is not a failover target: no
equivalence claim can be made for whatever you pulled locally.

How the job continues depends on what it was doing:

- a **read-only** job (`run`/`explore`) simply re-dispatches the same task on the picked harness;
- a **mutating** job (`edit`/`yolo`/`research`) is re-dispatched **fresh** on the picked harness
  with a handoff note: continue from the *current* repo state, inspect the tree first, keep what
  is already done, finish only the rest. Nothing from the interrupted turn is replayed and there is
  no byte-level resume; the new agent reads the half-done files. This is the only automatic retry a
  mutating verb ever gets, and only for a verified plan-limit refusal.

Every hop prints one human line, and when nothing is ready the run stops instead of inventing
capacity; both are described in `jobs-and-safety.md`.

## Notes

- **Devin has TWO pools, and the plan-included models are NOT free of limits.** The paid **ACU
  balance** (what "0% remaining / 402 / payment required" refers to) does not gate a plan-included
  model (`glm*`, `swe*`, `kimi*`, `deepseek*` on Devin): a paid-balance refusal against one of them
  is a Devin-side mis-gate. But the **plan-included daily/weekly quota** is real, shared, and
  exhaustible: on Pro, every plan-included model draws on ONE daily bucket, and when Devin says
  "Your daily usage quota has been exhausted … resets in 11h26m" ALL of them are blocked at once
  until that reset. Outsourcerer reads that refusal (`_devin_plan_quota_exhausted`) and then
  **verifies it before taking anything down**: one bounded request to a sibling free model (see
  "Plan limits and cross-harness failover" below). Only if that probe is refused too does the whole
  `dv` lane go down for Devin's stated window (a labeled estimate, default 1h via
  `OSRC_DEVIN_PLAN_DOWN_TTL`, when Devin gives no parseable reset) and the advice points OFF Devin
  (OpenRouter via `--provider cc -m glm|deepseek`, or a native lane). If the sibling still answers,
  the lane stays up and you are told which free model to keep using. The current devin CLI exposes
  no quota read; the live figure is at https://app.devin.ai/settings/usage.
  `brief`/`status` show a proactive meter, "N Devin plan jobs today", with a WARN past
  `OSRC_DEVIN_PLAN_JOBS_WARN` (default 8): routing advice only, never a block. The older claim that
  GLM does not draw Devin limits described the ACU pool only; do not read it as "unlimited".

## Alias quick table, full rows

| Alias(es) | Lane |
|---|---|
| `sol` / `terra` / `luna` / `gpt-5.5` | codex-native (ChatGPT sub); add `--provider claudex` to run it inside the Claude Code harness via the user's own CLIProxyAPI (offer only when `doctor` says claudex READY; unofficial bridge, detect-only) |
| `fable` / `opus` / `sonnet` / `haiku` | claude-native (Claude sub) |
| `gemini-pro` / `gemini-flash` / `gemini-flash-lite` | gemini (agy keyless) |
| `glm` / `hy3` / `deepseek` / any OpenRouter id | OpenRouter (`--provider cc`/`codex`); `capable` tier |
| `swe` / `swe-1.7` / `kimi` / any Devin id | devin (default); glm/deepseek self-heal here when OpenRouter is out of credits |
| `ollama:<m>` / `local:<m>` | local (keyless, PRIVATE, $0) |
| any TokenRouter gateway id | **tokenrouter** (`--provider tokenrouter`): OpenAI-compatible cloud gateway, key `TOKENROUTER_API_KEY` in `~/.env`; `-m` is REQUIRED and passes through verbatim to the gateway's own catalog (no hardcoded default; the roster is the gateway's, discovered live; some models are a $0 promo RIGHT NOW, confirmed at runtime by billing errors, never a hardcoded date). TEXT delegation, cloud-gated. |
| `gpt-image` / `nano-banana` | image only (`image` subcommand) |
| any model the USER configured | **droid** / **cursor** / **warp** / **hermes** / **cline** / **pi** / **grokbot** (`--provider droid\|cursor\|warp\|hermes\|cline\|pi\|grokbot`): the user's OWN agent CLIs, THEIR models (incl. BYOK); `-m` passes through verbatim. Warp drives `oz agent run` (models via `oz model list`) and can even host the Claude/Codex harness (`OSRC_WARP_HARNESS=claude\|codex`). **Cline** runs on the user's own Cline setup: a ClinePass subscription (discounted open-weight models) or their own keys in `~/.cline`; `-m` passes through verbatim (the roster + pricing are cline's, not ours). **These are easy to forget; the user has warp AND droid AND cline installed; when they say "use warp/droid/cline," this is the lane, don't reach for devin.** |

**A pinned Claude/GPT/Gemini model runs on ITS OWN native lane, never Devin.** `-m opus`, `-m fable`, `-m claude-opus-5-5`, `-m claude-opus-5-5[1m]`, any `claude-*`/`gpt-5.*`/`gemini-*` id resolves to the claude/codex/gemini-native lane automatically (the alias picks the lane; no `--provider` needed, and you should NOT add `--provider cc` for a Claude model; that means the OpenRouter transport, not the Claude subscription). If the user says "spin up Fable and Opus 5.5," that is `-m fable` and `-m opus` (or the pinned ids) on the claude-native lane, on their Claude subscription, putting that on Devin burns the wrong limits and is the #1 mistake to avoid.
