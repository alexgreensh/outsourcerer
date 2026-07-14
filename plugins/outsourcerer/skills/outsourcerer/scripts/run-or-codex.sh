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

# Guard: this script routes through OpenRouter ONLY. The BARE ChatGPT-subscription aliases/ids
# (sol/terra/luna and bare gpt-5.x) are NOT served by OpenRouter and 400 here. Match only bare tokens
# -- NOT provider-qualified slugs like `openai/gpt-5.6-sol`, which ARE valid OpenRouter models (no
# leading-`*` glob, so a slug containing a `/` is never matched). Point the caller at the native path.
case "$MODEL" in
  */*) : ;;   # provider-qualified slug (e.g. openai/gpt-5.6-sol) -> a real OpenRouter id, allow it through
  sol|terra|luna|gpt-5|gpt-5.*)
    echo "ERROR: '$MODEL' is a bare ChatGPT-subscription model; it 400s on OpenRouter." >&2
    echo "  For an interactive NATIVE-codex session (your ChatGPT auth) use:" >&2
    echo "    outsourcerer --provider codex session start -m $MODEL" >&2
    echo "  (--provider must precede the subcommand. This script is only for OpenRouter model ids.)" >&2
    exit 2 ;;
esac
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
# ISOLATION: --ignore-user-config so this OpenRouter run does not LOAD your live ~/.codex config
# (above all its mcp_servers, which can wedge a headless run demanding interactive OAuth). The OR
# provider below fully defines the lane; auth is the env key, not config. Opt out: OSRC_CODEX_USER_CONFIG=1.
IUC=(); [ "${OSRC_CODEX_USER_CONFIG:-0}" = "1" ] || IUC=(--ignore-user-config)
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
    ${IUC[@]+"${IUC[@]}"} "${OR[@]}" -m "$MODEL" "$@"
else
  # NOTE: --ignore-user-config is an `exec`-only flag; the interactive TUI is human-driven (a human
  # can answer an MCP OAuth prompt), so the headless-only wedge doesn't apply here. Don't pass IUC.
  echo "==> Codex (interactive TUI) on OpenRouter model: $MODEL"
  exec codex "${OR[@]}" -m "$MODEL"
fi
