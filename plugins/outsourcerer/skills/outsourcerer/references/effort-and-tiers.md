# Reasoning effort + capability tiers

Two knobs the orchestrator should set deliberately on every substantial delegation: **how hard the
model should think** (`--effort`) and **how much scaffolding it needs** (the capability tier).

## `--effort` (reasoning effort), universal, never silently dropped

`--effort minimal|low|medium|high|xhigh|max` (alias `--reasoning`), or the `OUTSOURCERER_EFFORT` env.
Set it whenever depth matters: a security gauntlet or a tricky design call is `high`/`max`; a grep or
a rename is `low`. It works on **every** text lane; the dispatch banner always prints a `>>> [effort]`
line stating whether it was applied natively or as advisory, so it is never silently ignored.

| Lane | How effort is honored |
|---|---|
| codex-native (`sol`/`terra`/`luna`/`gpt-5.5`) | NATIVE, `-c model_reasoning_effort=<effort>` |
| codex → OpenRouter (`--provider codex`) | NATIVE, `-c model_reasoning_effort=<effort>` (passes to the Responses API) |
| claude-native (`fable`/`opus`/`sonnet`/`haiku`) | NATIVE, `MAX_THINKING_TOKENS` (minimal 0 · low 4096 · medium 10000 · high 24000 · xhigh 32000 · max 48000) |
| cc → OpenRouter (`--provider cc`) | NATIVE, `MAX_THINKING_TOKENS` (same map) |
| gemini (agy / gemini-cli) | ADVISORY, injected as a prompt directive (no reasoning-effort knob exists on these CLIs today) |

Effort is forwarded through `bg` and `fanout` to every job. `--effort` on `fanout` applies to all N agents.

## Capability tiers: capability, NOT price

The tier drives the **prompt scaffold** and the **stall/timeout windows**, it is a statement about how
much hand-holding a model needs, NOT how much it costs. Cost is tracked separately (see `tab.md`).

| Tier | Models | Wrapper | Stall windows (warn/kill/hard) |
|---|---|---|---|
| `frontier` | Opus/Fable, GPT-5.6 (sol/terra), gemini-pro | thin, full autonomy | 300 / 900 / 3600 s |
| `capable` | **GLM-5.2, Hy3, DeepSeek-v4-pro** (frontier CAPABILITY, budget PRICE, ~Opus-4.8 class) | thin, full autonomy (SAME as frontier) | 300 / 900 / 3600 s |
| `mid` | Sonnet, Luna, gemini-flash | plans before acting | 150 / 420 / 1800 s |
| `budget` | Haiku, gemini-flash-lite, `*-mini`/`*-nano`/`*-lite` | strict work-order (do exactly this, don't improvise) | 90 / 240 / 900 s |

### Why `capable` exists (the "cheap == dumb" fix)

Classifying `glm-5.2`/`hy3`/`deepseek` as `budget` (because they are cheap) did three harmful things:
it wrapped an Opus-class model in a "you are a worker agent, do ONLY what the task says, do not
improvise" work order; it gave a reasoning model tight 90/240s stall windows that can stall-KILL it
mid-think; and it made the routing rule push high-stakes work AWAY from them. The `capable` tier fixes
all three: these models get the thin, high-autonomy `frontier` wrapper and generous windows, they are
just cheap per token. **Route high-stakes reasoning to a frontier-capability model, which includes
these open-weight lanes**, not only to premium native lanes.

### How a model gets its tier (first hit wins)

1. `--tier frontier|capable|mid|budget|raw` flag / `OUTSOURCERER_TIER` env (explicit override).
2. The alias table (`models --refresh` prints it), authoritative for known aliases/ids.
3. Name family (`tier_from_name`): `glm/deepseek/kimi/qwen/minimax/hy3/hunyuan/llama-4/mistral-large`
   → `capable`; `opus/fable/gpt-5.6/sol/terra` → `frontier`; `mini/lite/nano/flash-lite/haiku` → `budget`.
   This capability signal is checked BEFORE price, so a cheap-but-strong model is not mislabeled.
4. Cached OpenRouter price (`tier_from_price`), for unknown ids only.
5. Default `mid`.

`raw` = your prompt verbatim (plus the OSRC:: progress protocol only), no scaffold at all.
