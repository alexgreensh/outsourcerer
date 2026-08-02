# Lanes and models

Full detail behind the compact alias→lane table in `SKILL.md`: native lanes (codex-native /
claude-native), the Gemini/Antigravity (`agy`) lane, image backends, and model-recommendation
heuristics.

## The model chooses the lane (aliases + native premium lanes)

You no longer type `--provider` for premium models: the **model alias selects the lane**. `-m sol`
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
| `gemini-pro` | `gemini-3.1-pro-preview` (agy: `gemini-3.1-pro`) | gemini | frontier | PRIMARY = agy keyless (Antigravity login); fallback = gemini-cli + key |
| `gemini-flash` | `gemini-3.5-flash` | gemini | mid | strong agentic/coding default; keyless via agy |
| `gemini-flash-lite` | `gemini-3.1-flash-lite` (agy: flash) | gemini | budget | cheapest Gemini text tier |
| `gpt-image` / `codex-image` | `gpt-image-2` | codex-image | budget | **PREFERRED** image backend, **NOT** a text lane, use `image`; KEYLESS (Codex/ChatGPT sub) |
| `nano-banana` | `gemini-2.5-flash-image` | gemini-image | budget | image FALLBACK #2, **NOT** a text lane, use `image`; needs `GEMINI_API_KEY` |
| `glm` | `z-ai/glm-5.2` | OpenRouter | **capable** | frontier CAPABILITY, budget PRICE (~Opus-4.8 class); default cheap lane (`--provider cc`/`codex`) |
| `hy3` | `tencent/hy3:free` | OpenRouter | **capable** | ~Opus-4.8 class; `:free` = provider may train on inputs |
| `deepseek` | `deepseek/deepseek-v4-pro` | OpenRouter | **capable** | strongest cheap lane, pro reasoning flagship |
| any other OpenRouter id | itself | OpenRouter | by cached price, then name | see tiers below |
| `glm-5.2` under `--provider devin` | Devin's id | devin | table/name | Devin path unchanged |
| `swe` / `swe-1.7` | `swe-1.7` | devin | **capable** | Devin's own SWE agent model (open-weight/free-lane class) |
| `swe-1.7-lightning` | itself | devin | mid | faster/cheaper SWE variant |
| `kimi` | `kimi-k2.7` | devin | **capable** | open-weight lane on Devin |

**Dual-lane self-heal:** `glm` and `deepseek` exist on BOTH OpenRouter and Devin. With the default
provider, they route to Devin (which has quota) instead of hard-failing when the OpenRouter key is
out of credits; force OpenRouter with `--provider cc|codex`. `hy3` is OpenRouter-only.

## Claudex lane: GPT-5.6 Sol/Terra INSIDE the Claude Code harness (`--provider claudex`)

The community "claudex" pattern (Theo's recipe): more and more users treat the **model and the
harness as separate choices** — Claude Code's harness UX driving a ChatGPT-subscription model.
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
  `research` refused — no OS sandbox); the run VERIFIES the actual model via `modelUsage`.
- **codex CLI keeps its jobs**: gpt-image generation and the codex-native/OpenRouter lanes are
  unchanged; claudex is an additional road, not a replacement.

## Engine lanes: droid (Factory) + cursor — the user's OWN tools

`--provider droid` / `--provider cursor` delegate through the agent CLI the user already runs, with
the models THEY configured there. This is the "work with MY tools" lane: someone with free/cheap
BYOK API lanes set up in droid (`~/.factory/settings.json` → `customModels`) or a Cursor
subscription gets full outsourcerer supervision (bg/fanout/watchdog/ledger/cloud-gate) over their
existing setup — zero new keys, zero migration.

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

## Cline lane: the FREE `cline` OAuth provider (`--provider cline`)

`--provider cline` delegates through the Cline CLI (https://github.com/cline/cline) the user
already runs, with the models THEY configured in `~/.cline`. This is the "work with MY tools" lane
for Cline users, and it is the **free-tier standout**: the `cline` OAuth provider (enabled by
`cline auth cline`) currently serves **`deepseek/deepseek-v4-flash`** and **`z-ai/glm-5.2`** at
**$0 cash** — no API key, no OpenRouter credits, no plan-limit spend on Claude/ChatGPT. Full
outsourcerer supervision (bg/fanout/watchdog/ledger/cloud-gate) applies.

- `-m <name>` passes through **verbatim** to cline; the alias table never rewrites it. No `-m` =
  cline's configured default (read from `~/.cline/data/settings/providers.json`).
- **Free models:** `-m deepseek/deepseek-v4-flash` and `-m z-ai/glm-5.2` on the `cline` provider.
  Both are `capable` tier (frontier capability, budget price — here $0).
- **Posture is BINARY, not graded:** `run`/`explore` → `--plan` (read-only, no edits/commands
  applied — **version-gated**: requires cline >= 3.0.36, where Plan mode stopped falling back to
  shell edits; on an older CLI the read-only tier is refused, not silently trusted); `edit`/`research`/`yolo` → default act mode with `--auto-approve true` (all tools
  auto-approved). Cline has **no OS sandbox and no middle approval rung** — the trade is disclosed
  in the posture banner, never silent. Treat `research`/`yolo` on cline as fully autonomous with no
  sandbox boundary; prefer `run` (plan mode) for read-only inspection.
- `--effort` is **native** on cline (`--thinking none|low|medium|high|xhigh`).
- Billing: your Cline plan / the provider keys in `~/.cline`. The `cline` OAuth provider is $0
  cash. Cloud lane → full cloud gate + secret-scan apply.
- Auth: `cline auth cline` once (OAuth, enables the free provider). `doctor` shows install/auth
  state and **best-effort** reads the configured provider + default model from
  `~/.cline/data/settings/providers.json` (the schema is based on observed Cline 3.0.x layouts and
  may change in future versions; both reads degrade to "not detected" on an unparseable file).
- **Supervision limitation (disclosed):** Cline's hub/spoke lifecycle can spawn detached spokes
  that survive a `cancel`/watchdog kill (same class as codex MCP grandchildren on macOS, which has
  no `setsid`/process-group-kill). `_kill_tree` does best-effort reaping of the direct process tree;
  if a cline bg job is cancelled, verify with `ps aux | grep cline` that no spokes linger. This is
  a known limitation, not a silent gap.

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

**Model IDs (verified against Google's docs + live `agy models` at write time, re-verify
periodically, IDs shift):** text/agentic aliases resolve to `gemini-3.1-pro-preview` (frontier),
`gemini-3.5-flash` (mid, GA), `gemini-3.1-flash-lite` (budget, GA) for the gemini-cli/API path;
the agy vehicle maps these to its own curated keyless set (`gemini-3.1-pro`, `gemini-3.5-flash` , 
agy has no flash-lite tier, so flash-lite falls to flash there; agy is lenient and falls back to
its default on an unknown token).

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
- Default to **`glm-5.2`** unless the user asks otherwise (it currently does not draw the user's Devin usage limits).
- **Cheap ≠ dumb.** `glm-5.2`/`hy3`/`deepseek-v4-pro` are the **`capable`** tier: frontier capability
  at budget price (~Opus-4.8 class). They are valid for high-stakes reasoning, security review, and
  deep judgment, not just grunt work. See `effort-and-tiers.md`. Pair them with `--effort high`/`max`
  when the task is hard. Only route AWAY from genuinely *small* models (`haiku`/`gemini-flash-lite`/`*-mini`).
- The **open-weight** families (`glm*`, `deepseek*`, `kimi*`, `swe*`) are usually the free / low-cost lane, recommend these when the user wants "a free model."
- **Premium** families (`claude*`, `gpt*`, `gemini*`) typically consume Devin usage/ACUs faster. Flag this before routing heavy work to them, and confirm with the user.
- Treat all of the above as a heuristic, not gospel. If the user needs certainty on current cost, point them to their Devin usage dashboard.
- **Task-type routing (manual heuristic, no automated `suggest` command exists):** this skill has
  no stubbed model-recommendation/`suggest` surface to wire into, these are rules for *you* (the
  orchestrator) to apply by hand when picking `-m`. Visual-review / image-understanding tasks
  (screenshot critique, UI/UX review, "does this match the mockup") → route to `gemini-flash` or
  `gemini-pro` (see the Gemini/Antigravity section above). Image-*generation* tasks → the `image`
  subcommand, backend auto-resolved (GPT-image/Codex preferred, nano-banana and OpenRouter as
  fallback, see "Image generation" above). If an automated suggest/routing command gets built
  later, wire these same two mappings into it rather than re-deriving them.

## Notes

- GLM and other open-weight models currently do **not** noticeably draw the user's Devin hourly limits; this is the reason GLM is the default. This can change, see the model cost note.
