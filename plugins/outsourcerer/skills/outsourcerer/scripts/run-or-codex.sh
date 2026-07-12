#!/bin/bash
# Run Codex CLI against ANY OpenRouter model, NATIVE OpenAI Responses API, no shim.
# Inline -c overrides only: your normal Codex (ChatGPT-sub) sessions are untouched;
# config.toml is never modified.
#
# Usage:
#   run-or-codex.sh [model] tui                 # interactive TUI (attach in tmux)
#   run-or-codex.sh [model] exec "the task"     # headless one-shot, clean stdout (offload)
#
#   model  OpenRouter model id (default: tencent/hy3:free)
#
# Key is sourced from ~/.env (OPENROUTER_API_KEY), never inline.

MODEL="${1:-tencent/hy3:free}"
MODE="${2:-tui}"

export PATH="$HOME/.local/bin:$PATH"
# Extract ONLY the OpenRouter key, never allexport the whole ~/.env into Codex's env.
_l="$(grep -E '^[[:space:]]*(export[[:space:]]+)?OPENROUTER_API_KEY=' "$HOME/.env" 2>/dev/null | tail -n1)"
OPENROUTER_API_KEY="${_l#*OPENROUTER_API_KEY=}"; OPENROUTER_API_KEY="${OPENROUTER_API_KEY%\"}"; OPENROUTER_API_KEY="${OPENROUTER_API_KEY#\"}"; OPENROUTER_API_KEY="${OPENROUTER_API_KEY%\'}"; OPENROUTER_API_KEY="${OPENROUTER_API_KEY#\'}"; export OPENROUTER_API_KEY
if [ -z "$OPENROUTER_API_KEY" ]; then
  echo "ERROR: OPENROUTER_API_KEY not found in ~/.env" >&2
  exit 1
fi

# OpenRouter provider, passed per-invocation (NOT persisted to config.toml).
# wire_api MUST be "responses", Codex 0.144+ dropped Chat Completions;
# OpenRouter serves a Responses-compatible endpoint at /api/v1/responses.
OR=(
  -c model_provider=openrouter
  -c 'model_providers.openrouter.name="OpenRouter"'
  -c 'model_providers.openrouter.base_url="https://openrouter.ai/api/v1"'
  -c 'model_providers.openrouter.env_key="OPENROUTER_API_KEY"'
  -c 'model_providers.openrouter.wire_api="responses"'
)

if [ "$MODE" = "exec" ]; then
  shift 2 2>/dev/null
  echo "==> Codex (headless) on OpenRouter model: $MODEL" >&2
  exec codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \
    "${OR[@]}" -m "$MODEL" "$@"
else
  echo "==> Codex (interactive TUI) on OpenRouter model: $MODEL"
  exec codex "${OR[@]}" -m "$MODEL"
fi
