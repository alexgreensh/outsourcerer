# Agentic local (a local model with tool use, inside the harness)

The text local lane (`-m ollama:<m>` / `-m local`, plain `run`) hands a prompt to a local model and
streams text back. **Agentic local** goes further: the local model runs *inside a harness with tool
use* (reads the repo, runs tools) during a session, so sensitive IP is analyzed on your own hardware,
never shipped to a cloud model. Same PRIVATE, `$0` cash + `$0` plan story.

## Trigger

A tool-requiring verb on the local lane, or `OSRC_LOCAL_AGENTIC=1`:

```
outsourcerer.sh --provider local research -m local "read auth.py and list its risks"   # read+tools
outsourcerer.sh --provider local edit    -m ollama:qwen2.5-coder "..."                  # +writes
```

Plain `run` stays the zero-dependency text path. The model must support tool-calling (qwen2.5-coder,
llama3.1, etc.); small models often don't.

## Two vehicles, picked by the server (no user flag)

- **Responses-API server (LM Studio), NO install.** If the server answers `/v1/responses`, the lane
  drives it through `codex exec` (wire_api=responses), full agentic tool use, keyless.
- **Chat-only server (Ollama / llama.cpp), on-demand shim.** Codex 0.144 dropped `wire_api="chat"` and
  Claude Code speaks the Anthropic API, so a chat-only server needs a translator. The lane uses
  `scripts/anthropic-openai-shim.py` (vendored, stdlib-only, we control it, NOT a LiteLLM tree): a
  localhost-only server that translates the Anthropic Messages API ↔ OpenAI Chat Completions
  (streaming SSE + tool_use/tool_result mapping). Claude Code (`claude -p`) points
  `ANTHROPIC_BASE_URL` at it, so a local model drives the full Claude Code harness.

Force the vehicle with `OSRC_LOCAL_API=responses|chat`.

## Lazy, never eager (owner rule)

The shim is **only** launched when you actually run an agentic-local verb against a chat-only server,
and it is **torn down** after the run. It reuses an already-running proxy if you point
`OSRC_LOCAL_ANTHROPIC_URL` at one. Nothing is installed (python3 is the only need, already present),
and `OSRC_SHIM_NO_LAUNCH=1` disables auto-launch entirely.

## Env

| Var | Meaning |
|---|---|
| `OSRC_LOCAL_URL` | override the detected local `/v1` base |
| `OSRC_LOCAL_API` | `responses` or `chat` to skip capability probing |
| `OSRC_LOCAL_ANTHROPIC_URL` | an existing Anthropic-compatible proxy to reuse (skips the shim launch) |
| `OSRC_SHIM_PORT` | shim listen port on 127.0.0.1 (default 8788) |
| `OSRC_SHIM_NO_LAUNCH` | `1` = never auto-launch the shim |
| `OSRC_LOCAL_AGENTIC` | `1` = treat even plain `run` as agentic |

## Verification status

The shim's translation is covered by `scripts/tests/test_shim.py` (mock upstream: non-stream,
streaming text, tool_use, garbage-tolerance, localhost bind). **The live agentic loop (a real local
model reading the repo through the shim) must be certified against a real Ollama and LM Studio before
the v0.3.0 tag** — not yet certified against a live Ollama/LM Studio instance, so mocks prove shape,
not the full loop.
