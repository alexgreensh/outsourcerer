#!/bin/bash
# Run Claude Code against ANY OpenRouter model, direct ANTHROPIC_BASE_URL routing.
# NO proxy, NO third-party install. OpenRouter natively serves Anthropic /v1/messages.
#
# Usage:  run-or-model.sh [model] [workdir]
#   model    OpenRouter model id (default: tencent/hy3:free)
#   workdir  cwd for the session (default: $HOME, loads full global skills + MCP servers)
#
# Key never appears here: it is sourced from ~/.env (OPENROUTER_API_KEY).

MODEL="${1:-tencent/hy3:free}"
WORKDIR="${2:-$HOME}"

# Ensure `claude` (usually an npm/nvm global) is findable, portably, without pinning a node version.
# Keep the caller's PATH, then prepend common install dirs + the NEWEST nvm-installed node bin (if any).
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH:/usr/bin:/bin:/usr/sbin:/sbin"
_nvm_bin="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)"
[ -n "$_nvm_bin" ] && export PATH="$_nvm_bin:$PATH"

# Extract ONLY the OpenRouter key, never allexport the whole ~/.env into Claude Code's env.
_l="$(grep -E '^[[:space:]]*(export[[:space:]]+)?OPENROUTER_API_KEY=' "$HOME/.env" 2>/dev/null | tail -n1)"
OPENROUTER_API_KEY="${_l#*OPENROUTER_API_KEY=}"; OPENROUTER_API_KEY="${OPENROUTER_API_KEY%\"}"; OPENROUTER_API_KEY="${OPENROUTER_API_KEY#\"}"; OPENROUTER_API_KEY="${OPENROUTER_API_KEY%\'}"; OPENROUTER_API_KEY="${OPENROUTER_API_KEY#\'}"; export OPENROUTER_API_KEY
if [ -z "$OPENROUTER_API_KEY" ]; then
  echo "ERROR: OPENROUTER_API_KEY not found in ~/.env" >&2
  exit 1
fi

export ANTHROPIC_BASE_URL="https://openrouter.ai/api"
export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
export ANTHROPIC_MODEL="$MODEL"
export ANTHROPIC_SMALL_FAST_MODEL="$MODEL"   # background tasks (titles etc.) use the same model
unset ANTHROPIC_API_KEY                        # avoid x-api-key conflicting with bearer auth

cd "$WORKDIR" || exit 1
echo "==> Claude Code on OpenRouter model: $MODEL"
echo "==> Endpoint: $ANTHROPIC_BASE_URL/v1/messages   cwd: $WORKDIR"
exec claude
