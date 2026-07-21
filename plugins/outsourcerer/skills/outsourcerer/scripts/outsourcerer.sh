#!/usr/bin/env bash
# outsourcerer.sh, delegate subagent-style work to Devin CLI models (default GLM-5.2).
# Self-contained helper for the `outsourcerer` Claude Code skill.
#
# Subcommands:
#   doctor                         Preflight: platform, state-home writability, lanes, auth, consent.
#   brief                          Session-start handshake: ready lanes, live limits, conserve rec, mode.
#   mode [status|auto|manual|hybrid|reset]   The copilot driving mode (persisted, remembered once).
#   consent status|grant|revoke    Cloud-disclosure consent, remembered ONCE in ~/.outsourcerer
#                                  (the secret-scan still runs on every delegation regardless).
#   models                         Print the LIVE list of selectable Devin models (+ free-lane heuristic)
#   run     [-m MODEL] "<task>"    One-shot delegation (permission: auto / read-only auto-approve)
#   explore [-m MODEL] "<task>"    Alias for run, read-only fan-out (NOTE: 'auto' blocks tool EXEC)
#   research[-m MODEL] "<task>"    Delegation that must RUN tools (recall binary, scripts), uses
#                                  'autonomous --sandbox': execs tools inside an OS sandbox (macOS
#                                  seatbelt / Linux bwrap+seccomp) that enforces Read/Write scopes,
#                                  instead of blanket auto-approve. ('auto' BLOCKS binary exec; the
#                                  CLI rejects a read-only-exec 'smart' mode despite --help listing
#                                  it.) On a sandbox scope denial, fall back to 'yolo' (no sandbox).
#   edit    [-m MODEL] "<task>"    One-shot delegation that may modify the workspace (accept-edits)
#   yolo    [-m MODEL] "<task>"    One-shot, auto-approve ALL tools (dangerous), use sparingly
#   fanout  [flags] <source>       PARALLEL N-way multi-subagent across any provider (builds on bg).
#                                  source: --agents DIR [--sub K=V] [--preamble FILE] | --tasks FILE |
#                                  -- "t1" "t2" ...  · knobs: -m --effort --tier --with --verb --max.
#                                  Then: fanout status|wait|collect|list <gid>. See parallel-and-fanout.md.
#   continue|cont [-m MODEL] "<task>"   Continue the most recent Devin conversation; '-m' SWITCHES
#                                  the model mid-conversation with full context preserved.
#   session start|send|read|model|stop  Live supervision: the ORCHESTRATOR watches a delegate
#                                  (session read) and steers it mid-flight (session send), switches
#                                  its model, or stops it. A real feedback loop headless lacks. tmux.
#                                  'model [NAME]' switches the live model mid-session (drives opt+m).
#   parity                         Sync Claude skills + local MCP servers into Devin (skip cloud)
#   image   [-m MODEL] "<prompt>" [out.png]   Text-to-image, backend AUTO-RESOLVED (never hardcode
#                                  which is "installed", detect it): codex gpt-image-2 (KEYLESS,
#                                  your Codex/ChatGPT subscription) > nano-banana / gemini-2.5-flash-
#                                  image (needs GEMINI_API_KEY) > an OpenRouter image model (needs
#                                  OPENROUTER_API_KEY). Prints the written file path. `doctor` reports
#                                  which one resolves right now; force one with -m gpt-image / -m
#                                  nano-banana / -m <openrouter-image-id>.
#
# GEMINI / ANTIGRAVITY LANE (model-alias-selected, like sol/terra/fable, no --provider needed):
#   gemini-pro / gemini-flash / gemini-flash-lite  -> Gemini text/agentic lane. Gemini models are
#   a genuine strength for VISUAL REVIEW (UI/UX critique, screenshot/design feedback) when paired
#   with the right skills, route those tasks here.
#     PRIMARY vehicle = ANTIGRAVITY CLI `agy`, KEYLESS: it rides your existing Antigravity/Google
#     app login (no API key needed, that is the whole point). `agy -p` headless print mode works
#     in non-TTY pipes/subprocesses on current builds (v1.0.2+; the old non-TTY stdout bug is fixed
#     per its changelog and verified live). Auto-selected when `agy` is on PATH.
#     FALLBACK vehicle = `gemini` CLI (gemini-cli) + GEMINI_API_KEY/GOOGLE_API_KEY in ~/.env (same
#     single-key extraction as OPENROUTER_API_KEY). Used when agy is absent, or forced with
#     OSRC_GEMINI_VEHICLE=gemini (for users who prefer an API key).
#   nano-banana -> Gemini 2.5 Flash Image, dispatched via the `image` subcommand ONLY (it is NOT a
#   text lane; `run -m nano-banana` dies with a pointer to `image`). Image-to-FILE needs the REST
#   API + GEMINI_API_KEY: agy's keyless headless model list has no image model, so image gen is the
#   one Gemini feature that requires the API-key path. It is the FALLBACK image backend, behind
#   codex gpt-image-2 (KEYLESS, preferred whenever `codex` is installed + logged in). See SKILL.md
#   / references/ for rationale and the full resolution order.
#
# LOCAL LANE (KEYLESS, PRIVATE, $0 cash + $0 plan; model-alias-selected, no --provider needed):
#   ollama:<model> / lmstudio:<model> / local:<model> / local  -> a direct streaming call to a local
#   OpenAI-compatible /v1/chat/completions (Ollama :11434, LM Studio :1234, llama.cpp :8080; override
#   with OSRC_LOCAL_URL). Runs on YOUR hardware, nothing leaves the machine -> the privacy lane for
#   sensitive IP. TEXT delegation (no autonomous tool exec; see references/lanes-and-models.md).
#
# PROVIDER (offload backend): `--provider NAME` anywhere (before OR after the subcommand), or set
# OUTSOURCERER_PROVIDER. Backends:
#   devin  (default)  Devin CLI, sandboxed exec + Devin's own subagent fan-out.
#   cc                Claude Code -> OpenRouter via ANTHROPIC_BASE_URL (Anthropic-compat, 1 hop).
#                     Inherits YOUR Claude skills / MCP / Task subagents for free.
#   codex             Codex `exec` -> OpenRouter (native OpenAI Responses API, 0 hops; best tool
#                     fidelity). Runs in Codex's own AGENTS.md + MCP ecosystem, not Claude's.
#   droid             Factory Droid CLI (`droid exec`). YOUR configured models pass through
#                     verbatim, incl. free/cheap BYOK customModels in ~/.factory/settings.json.
#   cursor            Cursor CLI (`cursor-agent -p`). Bills your Cursor subscription credits.
#   claudex           GPT-5.6 Sol/Terra/Luna INSIDE the Claude Code harness via YOUR local
#                     CLIProxyAPI (detect-only; unofficial bridge; Claude-sub models refused).
#   local             Ollama / LM Studio / llama.cpp (also selectable via -m ollama:<m> etc).
# Reverse bridges (work FROM the other tool): parity-codex | parity-droid | parity-cursor teach
# that host agent to drive outsourcerer, so its users reach Devin/OpenRouter/Claude/local too.
#
# WINDOWS: NO WSL REQUIRED. Runs under Git Bash (ships with Git for Windows); use the
# outsourcerer.cmd / outsourcerer.ps1 launchers next to this script from cmd/PowerShell.
# Everything works except tmux `session` mode (bg/fanout cover the same ground, supervised).
# The cc/codex backends read OPENROUTER_API_KEY from ~/.env and, when no -m is given, ESCALATE
# through a model chain (OR_OFFLOAD_CHAIN, default tencent/hy3:free -> z-ai/glm-5.2 ->
# deepseek/deepseek-v4-pro) on hard failure. run/research/edit/yolo work on all three providers.
# INTERACTIVE sessions: `outsourcerer --provider devin|codex|cc session start -m <model>` is the one
# turnkey path and is provider-aware. NOTE --provider must come BEFORE the `session` subcommand (global
# flags are parsed before subcommands). --provider codex launches NATIVE codex (sol/terra/luna run on
# YOUR ChatGPT auth); --provider cc launches native claude (fable/opus/...); devin is the default.
# continue/parity are Devin-only. The sibling scripts/run-or-{model,codex}.sh are ONLY for running
# arbitrary OpenRouter model ids interactively -- they force provider=openrouter, so bare ChatGPT-sub
# aliases (sol/terra/luna/gpt-5.x) 400 there; use `--provider codex session start` for those instead.
#
# REASONING EFFORT is a parameter everywhere: --effort minimal|low|medium|high|xhigh|max (alias
# --reasoning), or OUTSOURCERER_EFFORT. Native on codex lanes (model_reasoning_effort) and Claude
# lanes (MAX_THINKING_TOKENS); advisory on gemini. The dispatch banner states which. See effort-and-tiers.md.
# CAPABILITY TIER != price: glm-5.2/hy3/deepseek are `capable` (frontier capability, budget price,
# ~Opus-4.8 class) and get the thin frontier wrapper, not the budget worker-drone scaffold.
# Model is a parameter everywhere. Default is overridable via OUTSOURCERER_MODEL.
# Free-model status on Devin CHANGES over time, this script never hardcodes it; use `models`.
#
# MODEL ADVISORY (which model should I use?):
#   advise [--refresh] [--json] "<task>"   Classifies your task (code/reasoning/agentic/creative/
#   simple), scores every known model against live benchmark data (OpenRouter benchmarks API:
#   intelligence/coding/agentic indices + pricing), and recommends the best value model that meets
#   the capability threshold for the task type. Explains WHY it picked that model. Use --refresh to
#   pull fresh benchmark data (needs OPENROUTER_API_KEY in ~/.env). Without benchmarks, falls back to
#   tier-based proxy scores. Pair with `suggest` for price-only discovery, `estimate` for cost quotes.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
# Version identifier. Single source of truth; bump the rightmost
# number for patch releases. `doctor` and `--version` both read this.
OSRC_VERSION="0.4.13"
DEFAULT_MODEL="${OUTSOURCERER_MODEL:-glm-5.2}"

# ---- platform detection (mac | linux | windows-gitbash). Windows = Git Bash / MSYS2, NO WSL
# required: everything except tmux `session` mode works there. See doctor's platform section.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) OSRC_PLATFORM="windows" ;;
  Darwin)               OSRC_PLATFORM="mac" ;;
  *)                    OSRC_PLATFORM="linux" ;;
esac

# Offload backend: devin (default) | cc (Claude Code->OpenRouter) | codex (Codex->OpenRouter).
PROVIDER="${OUTSOURCERER_PROVIDER:-devin}"
# OpenRouter escalation chain for cc/codex when no explicit -m is given (all support tool-calling).
OR_CHAIN_DEFAULT="tencent/hy3:free,z-ai/glm-5.2,deepseek/deepseek-v4-pro"

# Absolute path to THIS script (for the reverse bridge / parity-codex AGENTS.md snippet).
# Resolve via command -v first to handle PATH-invoked usage (bare `outsourcerer bg run ...`).
SCRIPT_PATH="$(command -v -- "$0" 2>/dev/null || printf '%s' "$0")"
case "$SCRIPT_PATH" in
  /*) ;;  # already absolute
  *)  SCRIPT_PATH="$PWD/$SCRIPT_PATH" ;;
esac

# ---- durable state home (jobs, model cache, ledger). NEVER /tmp. ----
OSRC_HOME="${OSRC_HOME:-$HOME/.outsourcerer}"
OSRC_JOBS="$OSRC_HOME/jobs"
OSRC_MODELS_JSON="$OSRC_HOME/models.json"
OSRC_LEDGER="$OSRC_HOME/ledger.jsonl"
# Any per-run MCP config temp is removed at script exit (only in the main shell, not in
# command-substitution subshells where the file may still be needed by a later claude invocation).
trap 'if [ "${BASH_SUBSHELL:-0}" -eq 0 ]; then rm -f "$OSRC_HOME/with-mcp-$$.json" "$OSRC_HOME/.hdr."* 2>/dev/null; fi' EXIT
# ---- state-home writability preflight (FAIL FAST, self-explaining). A sandboxed harness shell
# (e.g. Claude Code sandbox whose allowWrite covers ~/.local/share/devin but NOT ~/.outsourcerer)
# lets jobs launch with nowhere to write: terminal status, truncated out.log, sessions lost. One
# denied write must be an INSTANT actionable error, never a silent half-run.
_state_home_preflight() {
  mkdir -p "$OSRC_HOME" 2>/dev/null
  # Lock down to 0700: cloud-consent / mode / ledger / rate-limits live here and must not be
  # world-readable on a shared host (a permissive default umask would leave them 0755).
  chmod 700 "$OSRC_HOME" 2>/dev/null || true
  if ( : > "$OSRC_HOME/.wtest" ) 2>/dev/null; then rm -f "$OSRC_HOME/.wtest" 2>/dev/null; return 0; fi
  die "state home $OSRC_HOME is NOT WRITABLE (sandboxed shell?). Jobs/ledger/model-cache live there, so nothing can run.
  Fix ONE of:
    1) allow writes to ~/.outsourcerer in your harness sandbox (Claude Code: settings.json -> sandbox allowWrite; or run this one command with the sandbox disabled),
    2) point OSRC_HOME at a writable dir:  OSRC_HOME=\$PWD/.outsourcerer $0 ...
  Then re-run the same command."
}

# ---- persistent cloud consent. The cloud-disclosure gate used to demand --cloud-ack / OSRC_CLOUD_ACK=1
# on EVERY non-interactive run: audits showed 1-2 wasted attempts per session on a gate the user had
# already accepted before. Consent is now remembered ONCE (any explicit ack persists it) in
# $OSRC_HOME/cloud-consent. SECURITY: the per-run secret-scan hard-block is NEVER skipped -- persisted
# consent only replaces the ack prompt/refusal, exactly like OSRC_CLOUD_ACK=1 does. Revoke anytime:
# `consent revoke`, or force a one-run refusal with OSRC_CLOUD_ACK=0.
OSRC_CONSENT_FILE="$OSRC_HOME/cloud-consent"
_cloud_consent_ok() {
  [ "${OSRC_CLOUD_ACK:-}" = "0" ] && return 1   # explicit per-run opt-out beats the stored grant
  [ -L "$OSRC_CONSENT_FILE" ] && return 1        # refuse a symlinked consent file (defense-in-depth)
  [ -f "$OSRC_CONSENT_FILE" ]
}
_cloud_consent_persist() {
  mkdir -p -m 700 "$OSRC_HOME" 2>/dev/null; chmod 700 "$OSRC_HOME" 2>/dev/null || true
  [ -L "$OSRC_CONSENT_FILE" ] && rm -f "$OSRC_CONSENT_FILE" 2>/dev/null   # never write through a planted symlink
  # Atomic write: tmp-then-mv, mirroring _mode_persist. A plain `printf > file` on a
  # shared host lets a concurrent reader see a half-written consent file (TOCTOU); the rename is atomic.
  local tmp="$OSRC_HOME/.consent.$$"
  { umask 077; printf 'granted-at: %s\nby: %s\nscope: cloud-disclosure ack (secret-scan still runs per delegation)\nrevoke: %s consent revoke\n' \
      "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)" "${USER:-unknown}" "$0" > "$tmp"; } 2>/dev/null \
    && mv -f "$tmp" "$OSRC_CONSENT_FILE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; true; }
}
cmd_consent() {
  case "${1:-status}" in
    status) if [ -f "$OSRC_CONSENT_FILE" ]; then echo "cloud consent: GRANTED (remembered)"; sed 's/^/  /' "$OSRC_CONSENT_FILE" 2>/dev/null
            else echo "cloud consent: not granted. First cloud delegation will ask once (or pass --cloud-ack) and be remembered."; fi ;;
    grant)  _cloud_consent_persist; echo "cloud consent: granted + remembered in $OSRC_CONSENT_FILE (secret-scan still runs on every delegation). Revoke: $0 consent revoke" ;;
    revoke) rm -f "$OSRC_CONSENT_FILE" 2>/dev/null; echo "cloud consent: revoked. The next cloud delegation will ask again (interactive) or need --cloud-ack (non-interactive)." ;;
    *)      die "consent: unknown action '${1:-}' (use: status|grant|revoke)" ;;
  esac
}

# ---- COPILOT DRIVING MODE (auto|manual|hybrid), persisted per-user in $OSRC_HOME/mode.
# The session-start handshake: the skill greets the user, shows live limits + ready lanes, and
# offers three ways to drive. Chosen ONCE, remembered forever (ask-once-then-remember). The BASH
# side only persists + reports; the conversational menu is presented by the orchestrator (SKILL.md
# contract). SECURITY/ROBUSTNESS (GLM review): brief/mode are READ-ONLY prints — they NEVER prompt
# (a prompt would hang bg/CI), always print to stderr-safe channels, and validate the stored value.
OSRC_MODE_FILE="$OSRC_HOME/mode"
# Conserve trigger: route grind OFF the Claude session once the 5-hour window crosses this %.
# Default 50% (conserve once the window is half-spent). Tunable per-user/CI.
OSRC_CONSERVE_THRESHOLD="${OSRC_CONSERVE_THRESHOLD:-50}"

_mode_meaning() {
  case "$1" in
    auto)   printf '%s' 'auto-pilot — I pick the best ready lane/model and conserve tight windows, asking only for safety/consent/ambiguity/new spend' ;;
    manual) printf '%s' 'you-drive — I never delegate unless you tell me to, and I show the lane + limit impact before each run' ;;
    hybrid) printf '%s' 'hybrid — we agree once which task-types I auto-delegate (tests, repo-mapping, mechanical grind); I ask about everything else' ;;
    *)      return 1 ;;
  esac
}

_mode_read() {
  [ -f "$OSRC_MODE_FILE" ] || return 1
  [ -L "$OSRC_MODE_FILE" ] && { printf '>>> [notice] refusing symlinked mode file %s\n' "$OSRC_MODE_FILE" >&2; return 1; }
  local mode; mode="$(tr -d '[:space:]' < "$OSRC_MODE_FILE" 2>/dev/null)" || return 1
  case "$mode" in auto|manual|hybrid) printf '%s' "$mode" ;; *) return 1 ;; esac
}

_mode_menu() {
  printf 'driving mode: NOT SET — pick once (remembered after):\n'
  printf '  A) auto   — %s\n' "$(_mode_meaning auto)"
  printf '  B) manual — %s\n' "$(_mode_meaning manual)"
  printf '  C) hybrid — %s\n' "$(_mode_meaning hybrid)"
  printf 'set with: %s mode auto|manual|hybrid  (change anytime)\n' "$0"
}

_mode_persist() {
  local mode="$1" cur tmp="$OSRC_HOME/.mode.$$"
  cur="$(_mode_read 2>/dev/null)" && [ "$cur" = "$mode" ] && return 0   # skip write if unchanged
  mkdir -p -m 700 "$OSRC_HOME" 2>/dev/null || die "mode: cannot create state home $OSRC_HOME"
  { umask 077; printf '%s\n' "$mode" > "$tmp"; } 2>/dev/null \
    || { rm -f "$tmp" 2>/dev/null; die "mode: cannot write $OSRC_MODE_FILE (state home not writable?)"; }
  mv -f "$tmp" "$OSRC_MODE_FILE" 2>/dev/null \
    || { rm -f "$tmp" 2>/dev/null; die "mode: cannot replace $OSRC_MODE_FILE"; }
}

cmd_mode() {
  local action="${1:-status}"
  [ "$#" -le 1 ] || die "mode: '$action' takes no extra arguments (got: $*)"
  case "$action" in
    status)
      local mode; if mode="$(_mode_read)"; then printf 'driving mode: %s\n  %s\n' "$mode" "$(_mode_meaning "$mode")"
      else [ -f "$OSRC_MODE_FILE" ] && printf '>>> [notice] ignoring invalid driving mode in %s (expected auto|manual|hybrid)\n' "$OSRC_MODE_FILE" >&2; _mode_menu; fi ;;
    auto|manual|hybrid|a|A|b|B|c|C)
      case "$action" in a|A) action=auto ;; b|B) action=manual ;; c|C) action=hybrid ;; esac
      _mode_persist "$action"; printf 'driving mode set: %s\n  %s\n' "$action" "$(_mode_meaning "$action")" ;;
    reset) rm -f "$OSRC_MODE_FILE" 2>/dev/null; printf 'driving mode: reset (the session-start menu shows again next time).\n' ;;
    *) die "mode: unknown action '$action' (use: status|auto|manual|hybrid|reset)" ;;
  esac
}

# Tier override: --tier flag (parsed later) or OUTSOURCERER_TIER env. "raw" = no wrapper.
OSRC_TIER_OVERRIDE="${OUTSOURCERER_TIER:-}"
# Reasoning effort: --effort/--reasoning flag (parsed in _consume_flags) or OUTSOURCERER_EFFORT env.
# Empty = each lane's own default. Honored natively on codex lanes (model_reasoning_effort) and
# Claude lanes (MAX_THINKING_TOKENS); advisory (prompt hint) on gemini. NEVER silently dropped.
EFFORT="${OUTSOURCERER_EFFORT:-}"

# ---- Layer-2 model table (A1/A2): "alias|resolved-id|lane|tier".
# lane: or=OpenRouter (transport picked by --provider), cx=codex-native (ChatGPT sub, no OR),
#       cc=claude-native (Claude sub, no base-url), dv=devin. Native premium models NEVER
#       join the auto-escalation chain and are reachable only via their native lane.
# tier = CAPABILITY class (drives prompt scaffold + stall windows), NOT price:
#   frontier = premium flagship (Opus/GPT-5.6/Gemini-pro)      -> thin wrapper, generous windows
#   capable  = frontier-CAPABILITY, budget PRICE (GLM-5.2/Hy3/DeepSeek, ~Opus-4.8 class)
#              -> SAME thin wrapper + generous windows as frontier; just cheap per token. This row
#                 is the fix for "cheap == dumb": a budget-priced strong model is NOT hand-held.
#   mid      = solid mid (Sonnet/Luna/gemini-flash)            -> planned wrapper
#   budget   = genuinely small (Haiku/flash-lite/mini/nano)    -> strict work-order scaffold
OSRC_MODEL_TABLE="
sol|gpt-5.6-sol|cx|frontier
terra|gpt-5.6-terra|cx|frontier
luna|gpt-5.6-luna|cx|mid
gpt-5.5|gpt-5.5|cx|frontier
gpt-5.6-sol|gpt-5.6-sol|cx|frontier
gpt-5.6-terra|gpt-5.6-terra|cx|frontier
gpt-5.6-luna|gpt-5.6-luna|cx|mid
fable|fable|cc|frontier
opus|opus|cc|frontier
sonnet|sonnet|cc|mid
haiku|haiku|cc|budget
glm|z-ai/glm-5.2|or|capable
z-ai/glm-5.2|z-ai/glm-5.2|or|capable
hy3|tencent/hy3:free|or|capable
tencent/hy3:free|tencent/hy3:free|or|capable
deepseek|deepseek/deepseek-v4-pro|or|capable
deepseek/deepseek-v4-pro|deepseek/deepseek-v4-pro|or|capable
glm-5.2|glm-5.2|dv|capable
swe|swe-1.7|dv|capable
swe-1.7|swe-1.7|dv|capable
swe-1.7-lightning|swe-1.7-lightning|dv|mid
kimi|kimi-k2.7|dv|capable
kimi-k2.7|kimi-k2.7|dv|capable
gemini-pro|gemini-3.1-pro-preview|gm|frontier
gemini-3.1-pro-preview|gemini-3.1-pro-preview|gm|frontier
gemini-flash|gemini-3.5-flash|gm|mid
gemini-3.5-flash|gemini-3.5-flash|gm|mid
gemini-flash-lite|gemini-3.1-flash-lite|gm|budget
gemini-3.1-flash-lite|gemini-3.1-flash-lite|gm|budget
nano-banana|gemini-2.5-flash-image|gi|budget
gemini-2.5-flash-image|gemini-2.5-flash-image|gi|budget
gpt-image|gpt-image-2|ci|budget
codex-image|gpt-image-2|ci|budget
gpt-image-2|gpt-image-2|ci|budget
"

# Interactive tmux session name. SEPARATE TASKS GET SEPARATE SESSIONS: the name
# is derived from the working directory, so a GLM session started in repo A can
# never `session start` (which kills its own name first) clobber a concurrent
# session in repo B. `read`/`send`/`model`/`stop` run from the same $PWD, so they
# resolve the same session automatically. Override explicitly with
# OUTSOURCERER_TMUX (e.g. to run two isolated sessions in ONE directory).
_sess_slug() {
  local base hash
  base=$(basename "$PWD" | tr -c 'A-Za-z0-9' '-' | cut -c1-24)
  hash=$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)
  printf 'outsourcerer-%s-%s' "$base" "$hash"
}
SESSION_NAME="${OUTSOURCERER_TMUX:-$(_sess_slug)}"

die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Portable version sort: use GNU sort -V if available, else fall back to numeric field sort.
if printf '1.10\n1.2\n' | sort -V >/dev/null 2>&1; then
  _vsort() { sort -V; }
else
  _vsort() { sort -t. -k1,1n -k2,2n -k3,3n -k4,4n; }
fi

_OSRC_VERBS="run explore research edit yolo"
_is_verb() { case " $_OSRC_VERBS " in *" ${1:-} "*) return 0 ;; *) return 1 ;; esac; }

need_devin() {
  have devin || die "devin CLI not on PATH (~/.local/bin). Install: curl -fsSL https://cli.devin.ai/install.sh -o devin-install.sh (inspect it, then run: bash devin-install.sh)"
}

logged_in() { devin auth status 2>/dev/null | grep -qi "Logged in"; }

# _timeout <secs> <cmd...> -> run with a wall-clock cap. Uses coreutils timeout/gtimeout when present
# (Linux, or macOS with coreutils), else a portable watchdog (works on stock macOS + Git Bash, which
# ship NO `timeout`). Keeps the interactive `brief` handshake from stalling on a slow Devin backend.
_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs" 2>/dev/null; kill -TERM "$cmd_pid" 2>/dev/null ) &
  local wd_pid=$!
  local rc=0; wait "$cmd_pid" 2>/dev/null || rc=$?
  kill "$wd_pid" 2>/dev/null; wait "$wd_pid" 2>/dev/null
  return "$rc"
}

# Extract an optional leading "-m MODEL" / "--model MODEL"; echoes MODEL, sets REST via global.
MODEL="$DEFAULT_MODEL"
MODEL_EXPLICIT=0

# Validate a model token before it reaches a shell command (tmux send-keys, etc).
# Reject anything outside the safe set [A-Za-z0-9._:/-] to prevent shell injection.
_validate_model_token() {
  local token="${1:-}"
  [ -n "$token" ] || die "model token is empty"
  if printf '%s' "$token" | grep -qE '[^A-Za-z0-9._:/-]'; then
    die "invalid model token (shell-injection risk): '$token' — only [A-Za-z0-9._:/-] allowed"
  fi
}

parse_model() {
  # Strip ALL outsourcerer flags (not just leading -m) so none leak into the Devin CLI.
  # The `--effort high` leak crashed `devin -p` ("unexpected argument '--effort high...'").
  # parse_model sets the SAME flag state as _consume_flags (TIER_FLAG/OSRC_TIER_OVERRIDE,
  # WITH_SPEC) and validates --effort identically, so the two parsers no longer diverge. The Devin lane
  # still ignores tier/with (advisory only); non-Devin callers of parse_model (session, continue) get
  # the correct tier/effort state instead of silently dropping it.
  MODEL="$DEFAULT_MODEL"; MODEL_EXPLICIT=0; EFFORT="${OUTSOURCERER_EFFORT:-}"; TIER_FLAG=""; WITH_SPEC=""; REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -m|--model)           [ -n "${2:-}" ] || die "-m requires a model name"; MODEL="$2"; MODEL_EXPLICIT=1; shift 2 ;;
      --tier)               [ -n "${2:-}" ] || die "--tier requires: frontier|capable|mid|budget|raw"; TIER_FLAG="$2"; OSRC_TIER_OVERRIDE="$2"; shift 2 ;;
      --with)               [ -n "${2:-}" ] || die "--with requires e.g. skills=a,b or mcp=x"; WITH_SPEC="$WITH_SPEC $2"; shift 2 ;;
      --effort|--reasoning) [ -n "${2:-}" ] || die "--effort requires: minimal|low|medium|high|xhigh|max"
                            case "$2" in minimal|low|medium|high|xhigh|max|none) EFFORT="$2" ;;
                              *) die "--effort '$2' invalid (use: minimal|low|medium|high|xhigh|max)" ;; esac
                            shift 2 ;;
      --allow-downgrade)    OSRC_ALLOW_DOWNGRADE=1; shift ;;
      --cloud-ack)          OSRC_CLOUD_ACK=1; shift ;;
      --trust-lane)         [ -n "${2:-}" ] || die "--trust-lane needs a lane name (e.g. devin)"; OSRC_TRUST_LANE_ONCE="${OSRC_TRUST_LANE_ONCE:-} $2"; shift 2 ;;
      --provider)           [ -n "${2:-}" ] || die "--provider requires a name (devin|cc|codex|droid|cursor|claudex|local)"; PROVIDER="$2"; shift 2 ;;
      --)                   shift; REST+=("$@"); break ;;
      *)                    REST+=("$1"); shift ;;
    esac
  done
}

# Which Devin model serves an OpenRouter-lane alias (cross-lane sibling), empty if none.
# GLM and DeepSeek are dual-lane today (OpenRouter id <-> Devin id). hy3 is OpenRouter-only.
_devin_model_for() {
  case "$1" in
    glm|z-ai/glm-5.2|glm-5.2) printf 'glm-5.2' ;;
    deepseek|deepseek/deepseek-v4-pro) printf 'deepseek-v4-pro' ;;
    *) printf '' ;;
  esac
}

# LIVE model list via an intentionally invalid model probe (cheap: errors before running a task).
# The probe model is invalid ON PURPOSE, so devin exits nonzero, `|| true` keeps pipefail from
# leaking that expected failure to the caller (otherwise `doctor` exits 1 on a clean run).
live_models() {
  { devin --model "__list__" -p "x" </dev/null 2>&1 | grep -i "^Available:" | sed 's/^Available:[[:space:]]*//'; } || true
}

# delegate <perm> <sandbox-flag-or-empty> [-m MODEL] "<task>"
delegate() {
  local perm="$1"; shift
  local sandbox="${1:-}"; shift || true
  parse_model "$@"
  [ "${#REST[@]}" -gt 0 ] || die "no task prompt given"
  local prompt="${REST[*]}"
  # Devin has no native reasoning-effort knob. If --effort was given, surface it as advisory
  # ONLY (it is consumed by parse_model, never passed to the devin CLI, which would 'unexpected argument').
  [ -n "${EFFORT:-}" ] && printf '>>> [effort] reasoning=%s (advisory only: Devin lane has no native effort knob; not sent to the CLI)\n' "$EFFORT" >&2
  need_devin
  logged_in || die "Not logged in to Devin. Run interactively:  ! devin auth login"
  local sbx=(); [ -n "$sandbox" ] && sbx=(--sandbox)
  echo ">>> devin --model $MODEL --permission-mode $perm ${sbx[*]:-} -p (offload)" >&2
  local rc=0
  devin --model "$MODEL" --permission-mode "$perm" ${sbx[@]+"${sbx[@]}"} -p "$prompt" </dev/null || rc=$?
  if [ -n "$sandbox" ] && [ "$rc" -ne 0 ]; then
    echo "HINT: sandboxed run exited $rc. If a Read/Write scope was denied, retry with 'yolo' (dangerous, no sandbox)." >&2
  fi
  # Diagnostics-only: devin prints a bare "Connection error" when its Rust TLS stack rejects a
  # local/sandboxed proxy's cert (rustls OSStatus cert-verify, visible only in devin's own CLI log).
  # Surface a specific, recognizable hint so the failure is diagnosable from outsourcerer's side.
  # No retry/routing change -- the hint just names the cause and the fix (disable the sandbox/proxy).
  # `|| true` keeps the diagnostic line from leaking a non-zero status into delegate()'s return
  # (rc is already captured above; the helper is best-effort and silent on no match).
  [ "$rc" -ne 0 ] && _devin_sandboxed_proxy_tls_hint || true
  return "$rc"
}

continue_turn() {
  parse_model "$@"
  [ "${#REST[@]}" -gt 0 ] || die "no follow-up prompt given"
  local prompt="${REST[*]}"
  need_devin
  logged_in || die "Not logged in. Run:  ! devin auth login"
  echo ">>> devin -c --model $MODEL -p (continue)" >&2
  # `continue` must NOT silently escalate a read-only conversation to accept-edits.
  # Devin -c inherits the existing conversation's permission mode; forcing accept-edits here
  # was a silent privilege escalation. Remove it.
  # Capture exit code so callers can detect failure.
  local rc=0
  devin -c --model "$MODEL" -p "$prompt" </dev/null || rc=$?
  return "$rc"
}

# ---- OpenRouter backends (no proxy, no install), cc = Claude Code, codex = Codex ----
# OpenRouter natively serves BOTH the Anthropic Messages API (for cc) and the OpenAI Responses
# API (for codex), so each CLI talks to it without a translation server.
# ---- Shared key extraction from ~/.env (strips export, quotes, comments, whitespace) ----
_extract_kv_value() {
  # $1 = env var name (e.g. OPENROUTER_API_KEY). Echoes the value or empty if not found.
  local _key="$1" _l _v
  _l="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${_key}=" "$HOME/.env" 2>/dev/null | tail -n1)"
  _v="${_l#*${_key}=}"
  _v="${_v%%#*}"              # strip inline comments
  _v="${_v%"${_v##*[![:space:]]}"}"  # strip trailing whitespace
  _v="${_v%\"}"; _v="${_v#\"}"  # strip double quotes
  _v="${_v%\'}"; _v="${_v#\'}"  # strip single quotes
  printf '%s' "$_v"
}

_or_load_key() {
  # Extract ONLY the OpenRouter key. NEVER `set -a; . ~/.env`, allexport would push every
  # other secret in ~/.env into the delegate's environment, exposing them to a third-party model.
  OPENROUTER_API_KEY="$(_extract_kv_value OPENROUTER_API_KEY)"
  [ -n "$OPENROUTER_API_KEY" ] || die "OPENROUTER_API_KEY not found in ~/.env (needed for --provider cc/codex)"
  export OPENROUTER_API_KEY
}

# ---- Gemini / Antigravity lane key ----
_gm_load_key() {
  # Extract ONLY the Gemini key. NEVER `set -a; . ~/.env`, same single-key-only rule as
  # _or_load_key above. Tries GEMINI_API_KEY first, then GOOGLE_API_KEY (gemini-cli's own
  # precedence is GOOGLE_API_KEY > GEMINI_API_KEY when both are set; here either satisfies us).
  GEMINI_API_KEY="$(_extract_kv_value GEMINI_API_KEY)"
  if [ -z "$GEMINI_API_KEY" ]; then
    GEMINI_API_KEY="$(_extract_kv_value GOOGLE_API_KEY)"
  fi
  [ -n "$GEMINI_API_KEY" ] || die "GEMINI_API_KEY (or GOOGLE_API_KEY) not found in ~/.env (needed for gemini-pro/gemini-flash/nano-banana). Get a key: https://aistudio.google.com/apikey"
  export GEMINI_API_KEY
}

# ---- Secure curl header helper: pass API keys via temp file, not process args (ps table) ----
# Usage: _curl_with_key <header_value> <curl args...>
# Writes the header to a 0600 temp file and uses curl -H @file to avoid exposing the key in ps.
_curl_hdr_tmp=""
_curl_with_auth() {
  local _hdr_val="$1"; shift
  _curl_hdr_tmp="$(mktemp "$OSRC_HOME/.hdr.XXXXXX" 2>/dev/null || mktemp)"
  chmod 600 "$_curl_hdr_tmp" 2>/dev/null || true
  printf 'Authorization: Bearer %s\n' "$_hdr_val" > "$_curl_hdr_tmp"
  curl -H @"$_curl_hdr_tmp" "$@"
  local rc=$?
  rm -f "$_curl_hdr_tmp" 2>/dev/null; _curl_hdr_tmp=""
  return $rc
}
_curl_with_gemini_key() {
  local _hdr_val="$1"; shift
  _curl_hdr_tmp="$(mktemp "$OSRC_HOME/.hdr.XXXXXX" 2>/dev/null || mktemp)"
  chmod 600 "$_curl_hdr_tmp" 2>/dev/null || true
  printf 'x-goog-api-key: %s\n' "$_hdr_val" > "$_curl_hdr_tmp"
  curl -H @"$_curl_hdr_tmp" "$@"
  local rc=$?
  rm -f "$_curl_hdr_tmp" 2>/dev/null; _curl_hdr_tmp=""
  return $rc
}

# ---- Codex image backend detection (gpt-image-2, KEYLESS via the user's Codex/ChatGPT subscription) ----
# Mirrors ~/.claude/skills/illo/scripts/illo.py's codex_available() detection exactly (read straight
# from illo's source, not re-derived): `codex` must be on PATH, `codex login status` must report
# "logged in", and `codex features list` must list both the built-in image_generation tool and the
# exec image-artifact extension ("artifact" on Codex CLI >=0.144; illo's current source checks only
# that string, so this mirrors it 1:1). Soft-fails to "not available" on any missing binary, non-zero
# exit, or missing feature line, never assumed. Cached per process (two codex subprocess calls are
# enough for a whole `doctor`/`image` invocation).
_OSRC_CODEX_IMG=""
_codex_image_available() {
  if [ -n "$_OSRC_CODEX_IMG" ]; then [ "$_OSRC_CODEX_IMG" = "1" ]; return; fi
  _OSRC_CODEX_IMG=0
  have codex || return 1
  local out
  out="$(codex login status 2>&1)" || return 1
  printf '%s' "$out" | grep -qi "logged in" || return 1
  out="$(codex features list 2>&1)" || return 1
  printf '%s' "$out" | grep -qi "image_generation" || return 1
  printf '%s' "$out" | grep -qi "artifact" || return 1
  _OSRC_CODEX_IMG=1
  return 0
}

# ---- Codex "code mode" host preflight ----
# Codex routes file-reading / tool calls through a helper binary, codex-code-mode-host. When it is
# missing, a delegated codex-native task that tries to READ FILES fails mid-run (every fs read errors)
# and the model correctly refuses rather than fake a result, burning a dispatch. Passing task content
# INLINE (no file reads) sidesteps it. We can't fix the install, but a hardened lane WARNS up front
# instead of letting the delegate discover it. Checks PATH + the conventional ~/.local/bin location.
# Returns 0 if found. Cached per process.
_OSRC_CODEMODE=""
_codex_code_mode_host() {
  if [ -n "$_OSRC_CODEMODE" ]; then [ "$_OSRC_CODEMODE" = "1" ]; return; fi
  _OSRC_CODEMODE=0
  if command -v codex-code-mode-host >/dev/null 2>&1 || [ -x "$HOME/.local/bin/codex-code-mode-host" ]; then
    _OSRC_CODEMODE=1; return 0
  fi
  return 1
}
# Models to try. Explicit -m -> that model only. Otherwise the escalation chain, BUT only for
# read-only work ('auto'). Mutating tiers must NEVER re-run against an already-mutated tree, so
# they get the chain HEAD only (one model, no blind re-apply). _or_chain <tier>.
_or_chain() {
  local tier="${1:-auto}"
  if [ "$MODEL_EXPLICIT" = "1" ]; then
    # Resolve an alias to its real OpenRouter id (glm -> z-ai/glm-5.2). Without this the cc/codex
    # lanes send the bare alias and OpenRouter 400s ("glm is not a valid model ID").
    local row rid; row="$(resolve_model_row "$MODEL")"; rid="${row%%|*}"
    printf '%s' "${rid:-$MODEL}"; return
  fi
  local chain; chain="$(printf '%s' "${OR_OFFLOAD_CHAIN:-$OR_CHAIN_DEFAULT}" | tr ',' ' ')"
  if [ "$tier" = "auto" ]; then printf '%s' "$chain"; else printf '%s' "${chain%% *}"; fi
}

# =============================================================================
# TIER CLASSIFICATION + PROMPT WRAPPING, additive, cc/codex/native lanes.
# =============================================================================

# resolve_model_row <user-model> -> echoes "id|lane|tier" from the table, or "" if unknown.
resolve_model_row() {
  printf '%s\n' "$OSRC_MODEL_TABLE" | awk -F'|' -v m="$1" '$1==m {print $2"|"$3"|"$4; exit}'
}

tier_from_price() {   # <openrouter-id> -> budget|mid|frontier from cached pricing, or nonzero
  local f="$OSRC_MODELS_JSON" p
  [ -f "$f" ] || return 1
  case "$1" in *:free) echo budget; return 0 ;; esac
  have jq || return 1
  p="$(jq -r --arg id "$1" '.data[]|select(.id==$id)|.pricing.completion' "$f" 2>/dev/null)"
  [ -n "$p" ] && [ "$p" != "null" ] || return 1
  awk -v p="$p" -v b="${OSRC_TIER_BUDGET_MAX_USD_M:-2}" -v m="${OSRC_TIER_MID_MAX_USD_M:-12}" \
    'BEGIN{pm=p*1000000; print (pm<b?"budget":(pm<m?"mid":"frontier"))}'
}

tier_from_name() {    # <model-id> -> capable|frontier|budget by name regex, or nonzero if unrecognized.
  # CAPABILITY signal, checked BEFORE price: strong open-weight families are budget-PRICED but
  # frontier-CAPABILITY, so name (which knows the family) must beat price (which only knows cost).
  case "$1" in
    *glm*|*deepseek*|*kimi*|*qwen*|*minimax*|*hy3*|*hunyuan*|*llama-4*|*mistral-large*) echo capable ;;
    *opus*|*fable*|*gpt-5.6*|*sol*|*terra*|*o1-pro*|*o3-pro*) echo frontier ;;
    *mini*|*lite*|*nano*|*tiny*|*micro*|*flash-lite*|*swe-*|*haiku*) echo budget ;;
    *) return 1 ;;   # unrecognized -> caller falls through to price, then default mid
  esac
}

# resolve_tier <model-id> [table-tier] -> frontier|capable|mid|budget|raw (first-hit-wins, A1).
resolve_tier() {
  if [ -n "${OSRC_TIER_OVERRIDE:-}" ]; then echo "$OSRC_TIER_OVERRIDE"; return; fi   # --tier / env
  local tt="${2:-}" row n
  if [ -z "$tt" ]; then row="$(resolve_model_row "$1")"; [ -n "$row" ] && tt="${row##*|}"; fi
  if [ -n "$tt" ]; then echo "$tt"; return; fi                                       # table tier (authoritative)
  n="$(tier_from_name "$1")" && [ -n "$n" ] && { echo "$n"; return; }                # capability signal by family
  tier_from_price "$1" 2>/dev/null && return                                         # cached price (cheap unknowns)
  echo mid                                                                           # last-resort default
}

# _effective_lane <table_lane> <provider> [model] [model_explicit] -> effective lane code, MIRRORING
# actual dispatch routing (not a provider-only guess). Precedence matches route_delegate:
#   1. local short-circuit: an ollama:/lmstudio:/lms:/local: model or `--provider local` ALWAYS runs
#      local, whatever the alias table says (so `--provider local -m sol` records local, not cx).
#   2. IMPLICIT model (no -m): the lane is the PROVIDER's default, NOT the default model's table lane
#      (devin->dv, cc/codex->the OpenRouter chain=or) — so a bare `--provider cc run` records or, not
#      the DEFAULT_MODEL glm-5.2's dv.
#   3. EXPLICIT model: fixed lanes (native cx/cc/gm, image gi/ci, devin-pinned dv, local) ignore
#      --provider (a Devin-pinned glm-5.2 stays dv under --provider cc); a provider-routed open-weight
#      model follows the transport provider (glm+devin->dv, glm+cc->or).
_effective_lane() {
  case "${3:-}" in local|ollama:*|lmstudio:*|lms:*|local:*) printf 'local'; return ;; esac
  [ "$2" = "local" ] && { printf 'local'; return; }
  case "$2" in droid|cursor|claudex) printf '%s' "$2"; return ;; esac   # engine lanes: provider IS the lane
  if [ "${4:-1}" != "1" ]; then                    # implicit model -> provider's default lane
    case "$2" in cc|codex) printf 'or' ;; *) printf 'dv' ;; esac; return
  fi
  case "$1" in cx|cc|gm|gi|ci|local|dv) printf '%s' "$1"; return ;; esac
  case "$2" in
    cc|codex) printf 'or' ;;
    devin)    printf 'dv' ;;
    *)        printf '%s' "${1:-$2}" ;;
  esac
}

# _last_marker <file> -> the final terminal marker, preferring one SIGNED with this run's id.
# A signed marker cannot be produced by echoing the instructions, quoting an example, or diffing this
# repo, because the id is minted per run. Unsigned markers are still honoured (older prompts, raw
# passthrough, a delegate that drops the id) but only when no signed marker exists, so a real signed
# status always wins over anything the delegate merely repeated.
_last_marker() {
  local f="$1" m=""
  if [ -n "${OSRC_MARK:-}" ]; then
    m="$(grep -aoE "^[[:space:]]*OSRC::(DONE|BLOCKED|NEED_INPUT)#${OSRC_MARK}" "$f" 2>/dev/null | tail -1)"
    [ -n "$m" ] && { printf 'OSRC::%s' "$(printf '%s' "${m##*OSRC::}" | cut -d'#' -f1)"; return 0; }
  fi
  m="$(grep -aoE '^[[:space:]]*OSRC::(DONE|BLOCKED|NEED_INPUT)([^#]|$)' "$f" 2>/dev/null | tail -1)"
  [ -n "$m" ] && printf 'OSRC::%s' "$(printf '%s' "${m##*OSRC::}" | tr -cd 'A-Z_')"
}

# ---- per-run marker signature -------------------------------------------------------------------
# Control decisions used to be made by grepping the delegate's stdout for bare OSRC:: markers. That
# makes the delegate's output the control plane, and the delegate can trip it by ACCIDENT: quoting the
# protocol it was handed, echoing a log, reviewing this repo, or diffing this very file. It happened
# three separate times (a print-mode phrase, a truncation phrase, and the terminal markers), each fixed
# by anchoring the pattern a little harder — which treats the symptom.
# The fix is a value the delegate cannot reproduce by echoing anything it was given: a random token
# minted per run. Instructions carry it, so a genuine marker is signed and echoed text never is.
_new_mark() { od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%04x%04x' $$ "${RANDOM:-0}"; }

# ---- the canonical OSRC:: progress protocol block, injected into raw/continue/tmux ----
osrc_protocol_block() {
  if [ -n "${OSRC_MARK:-}" ]; then
    printf -- '--- PROGRESS PROTOCOL (required; machine-monitored) ---\n'
    printf 'Your run is supervised. A watchdog kills silent processes, so signal liveness.\n\n'
    printf 'IMPORTANT: this run has the id %s. Every OSRC:: line you emit MUST carry it, like this:\n' "$OSRC_MARK"
    printf '  OSRC::PROGRESS#%s <step> <5-10 words on what you are doing now>\n' "$OSRC_MARK"
    printf '  OSRC::BLOCKED#%s <what is blocking you and what you tried>\n' "$OSRC_MARK"
    printf '  OSRC::NEED_INPUT#%s <the single question>\n' "$OSRC_MARK"
    printf '  OSRC::DONE#%s <one-line summary of what you did>\n\n' "$OSRC_MARK"
    printf 'Rules:\n'
    printf '1. Each line stands alone, at the START of a line, nothing before it.\n'
    printf '2. Print a PROGRESS line before each major step; never go ~1 minute silent.\n'
    printf '   Between long commands it is fine to emit it from your shell tool.\n'
    printf '3. If blocked (missing file, failing dependency, denied permission, repeated\n'
    printf '   error) do NOT retry endlessly. Print ONE BLOCKED line and stop.\n'
    printf '4. Finish with exactly one DONE line as the final line.\n'
    printf '5. If you need to QUOTE or discuss these markers, omit the id. Only real\n'
    printf '   status lines carry %s, so quoted examples are never mistaken for status.\n' "$OSRC_MARK"
    return
  fi
  cat <<'OSRCEOF'
--- PROGRESS PROTOCOL (required; machine-monitored) ---
Your run is supervised. A watchdog kills silent processes, so signal liveness:

1. Before each major step or tool phase, print one line, alone, exactly:
   OSRC::PROGRESS <step>/<total-if-known> <5-10 words on what you are doing now>
2. Never work more than ~1 minute without printing an OSRC::PROGRESS line.
   Between long-running commands, it is fine to emit it via your shell tool:
   echo "OSRC::PROGRESS 3/5 running test suite"
3. If you are blocked (missing file, failing dependency, denied permission,
   repeated error), do NOT retry endlessly. Print exactly one line and stop:
   OSRC::BLOCKED <what is blocking you and what you tried>
4. If you need information only the orchestrator can give, print and stop:
   OSRC::NEED_INPUT <the single question>
5. The VERY LAST line of your final message must be exactly one of:
   OSRC::DONE <one-line summary of the outcome>
   OSRC::BLOCKED <reason>
Rules: never print OSRC::DONE unless the task outcome is real and verified;
never print more than one OSRC:: line in a row without doing work in between.
--- END PROTOCOL ---
OSRCEOF
}

# two-line reminder form (follow-up turns / tmux sends), A6/B5
osrc_reminder() {
  cat <<'OSRCEOF'
(Protocol reminder: keep printing OSRC::PROGRESS lines while you work;
end with OSRC::DONE <summary> or OSRC::BLOCKED <reason> as the final line.)
OSRCEOF
}

_wrap_frontier() { cat <<'OSRCEOF'
Delegated task. You own it end to end; use your own judgment on approach,
depth, and tradeoffs. The orchestrator reads only your final message and
any lines starting with OSRC::.

<task>
{{TASK}}
</task>

Liveness protocol (monitoring, not hand-holding):
- When you start a distinct phase of work, print one line: OSRC::PROGRESS <short phase note>
- Final line of your final message: OSRC::DONE <one-line outcome>
  or, if genuinely blocked: OSRC::BLOCKED <what is missing and the best next step>
Note significant assumptions or tradeoffs briefly in the final message.
OSRCEOF
}

_wrap_mid() { cat <<'OSRCEOF'
You are a delegated engineer. Work autonomously; the orchestrator sees only
your progress lines and final message, so make both count.

<task>
{{TASK}}
</task>

Approach:
1. Plan briefly (3-6 bullets) and print the plan before acting.
2. Before each major step or tool phase, print: OSRC::PROGRESS <n>/<total> <current step>
3. Stay within the task's scope. List anything adjacent you deliberately did NOT do.
4. Verify your own work before finishing (run it, re-read the diff, or cross-check
   the claim against the source) and say what you checked.
5. If blocked after reasonable attempts, print OSRC::BLOCKED <reason> and stop cleanly.

Final message format:
### RESULT
<the deliverable, or a precise summary of changes with file paths>
### VERIFICATION
<what you ran or checked, and what it showed>
### OPEN ITEMS
<anything unfinished or worth flagging; "none" if clean>
End with OSRC::DONE <one-line summary> as the very last line.
OSRCEOF
}

_wrap_budget() { cat <<'OSRCEOF'
You are a delegated worker agent. Follow this work order EXACTLY. Do not
expand scope. Do not improvise.

<task>
{{TASK}}
</task>

Work procedure, in order:
1. Restate the task in one line: OSRC::PLAN <restatement>
2. List at most 5 concrete steps to complete it, one line each: OSRC::PLAN <step>
3. Execute the steps in order. Before EACH step print: OSRC::PROGRESS <n>/<total> <doing what>
4. If the same step fails twice, STOP retrying. Print OSRC::BLOCKED <exact error> and stop.
5. Write your final answer in the OUTPUT FORMAT below.
6. Very last line: OSRC::DONE <one-line summary>

Hard rules:
- Do ONLY what the task says. No refactors, no renames, no extra files, no
  "improvements", no new dependencies.
- NEVER invent file paths, function names, commands, or results. Anything you
  did not directly read or run is unverified: write NOT FOUND instead of guessing.
- Do not ask questions. If something is ambiguous, take the most conservative
  reading and record it under ASSUMPTIONS.
- Touch nothing outside the current working directory.
- Prefer reading files and running commands over answering from memory.

OUTPUT FORMAT (exact headings, exact order):
### RESULT
<the deliverable>
### ASSUMPTIONS
<bullet list, or "none">
### NOT DONE
<anything skipped or failed, or "none">
OSRCEOF
}

# _sign_markers -> stamp this run's id onto the marker tokens in a wrapped prompt (stdin -> stdout).
# The tier scaffolds are quoted heredocs, so the id cannot be interpolated where the text is written.
# Signing here instead means EVERY lane gets signed markers from one place, and a scaffold added later
# is covered without anyone remembering to. Only the marker token is touched, never the surrounding
# instructions. With no id set this is a pass-through, so nothing changes for callers that never set one.
_sign_markers() {
  [ -n "${OSRC_MARK:-}" ] || { cat; return; }
  sed -E "s/OSRC::(PROGRESS|PLAN|DONE|BLOCKED|NEED_INPUT)([^#A-Z_]|\$)/OSRC::\\1#${OSRC_MARK}\\2/g"
}

# wrap_prompt <tier> <task> -> tier-appropriate wrapped prompt ({{TASK}} substituted literally).
wrap_prompt() {
  local tier="$1" task="$2" tmpl
  case "$tier" in
    raw)             printf '%s\n\n%s\n' "$task" "$(osrc_protocol_block)"; return ;;
    frontier|capable) tmpl="$(_wrap_frontier)" ;;   # capable = strong open-weight: trust it, thin wrapper
    budget)          tmpl="$(_wrap_budget)" ;;
    mid|*)           tmpl="$(_wrap_mid)" ;;
  esac
  # Sign the SCAFFOLD, THEN substitute the task. Order matters: the task is the user's text and may
  # legitimately discuss these markers (a prompt about this very repo does). Signing after substitution
  # would stamp a live id onto the user's words and hand the delegate a ready-made forgery.
  tmpl="$(printf '%s' "$tmpl" | _sign_markers)"
  printf '%s\n' "${tmpl//\{\{TASK\}\}/$task}"
}

# ---- capability injection (--with): skills contents + named MCP servers ----
# build_with_preamble -> echoes injected SKILL.md contents block (uses WITH_SPEC global), or nothing.
build_with_preamble() {
  [ -n "${WITH_SPEC:-}" ] || return 0
  local tok val name f out=""
  for tok in $WITH_SPEC; do
    case "$tok" in
      skills=*) val="${tok#skills=}"
        for name in $(printf '%s' "$val" | tr ',' ' '); do
          f="$HOME/.claude/skills/$name/SKILL.md"
          if [ -f "$f" ]; then
            out="$out
=== INJECTED SKILL: $name ===
$(cat "$f")
=== END SKILL: $name ==="
          else
            out="$out
(injected skill '$name' NOT FOUND at $f)"
          fi
        done ;;
    esac
  done
  [ -n "$out" ] && printf 'You have been granted the following capability docs; use them as needed.\n%s\n' "$out"
}

# build_mcp_flags_cc -> populates the global array CC_MCP_FLAGS with claude --strict-mcp-config /
# --mcp-config <path> args so a headless `claude -p` delegate does NOT inherit the user's live
# ~/.claude.json MCP surface (project-scoped servers, which can wedge a sandboxed, non-interactive
# run by demanding interactive OAuth — the I1 parity gap with the codex lanes).
#
# CONTRACT (fail-closed + whitespace-safe):
#   - Returns 0 and sets CC_MCP_FLAGS on success. Callers use "${CC_MCP_FLAGS[@]+"${CC_MCP_FLAGS[@]}"}"
#     (quoted array expansion) so paths with spaces are safe. On failure returns nonzero; the caller
#     MUST die (never run the delegate without isolation — that would inherit live MCP, the exact
#     invariant this function enforces). die is called in the CALLER, not here, because die inside
#     a $(...) subshell only exits the subshell.
#
# ISOLATION MODEL (mirrors the codex `--ignore-user-config` / OSRC_CODEX_USER_CONFIG gate):
#   - DEFAULT: CC_MCP_FLAGS=(--strict-mcp-config --mcp-config <empty.json>) so NO user MCP servers load.
#     Auth survives (verified live: haiku answers PONG with the empty strict config on the OAuth
#     path, no --bare needed). This is the I1 PARITY STANDARD for the claude harness.
#   - --with mcp=a,b: extract ONLY the named servers from ~/.claude.json into a temp config and
#     strict-load just those (the original opt-in behavior, unchanged). jq failure = die (the user
#     asked for specific servers; silent empty-config would be a misleading no-op).
#   - OSRC_CLAUDE_USER_CONFIG=1: escape hatch — CC_MCP_FLAGS=() so claude loads its full default
#     MCP surface (interactive-style; use only when you deliberately want the live config).
# The temp config is secret-bearing: created with umask 077 + chmod 600 and removed on script exit
# (the EXIT trap at line ~104 already targets the with-mcp-$$.json name).
CC_MCP_FLAGS=()
build_mcp_flags_cc() {
  CC_MCP_FLAGS=()
  # Escape hatch: opt out of isolation, ride the full live MCP surface (interactive-style).
  [ "${OSRC_CLAUDE_USER_CONFIG:-0}" = "1" ] && return 0
  mkdir -p -m 700 "$OSRC_HOME" 2>/dev/null || { echo "ERROR: isolation setup: cannot mkdir OSRC_HOME ($OSRC_HOME)" >&2; return 1; }
  chmod 700 "$OSRC_HOME" 2>/dev/null || true
  local cfg="$OSRC_HOME/with-mcp-$$.json"
  # --with mcp=a,b -> extract ONLY the named servers (original opt-in path, unchanged).
  if [ -n "${WITH_SPEC:-}" ] && printf '%s' "$WITH_SPEC" | grep -q 'mcp=' && have jq; then
    local tok mspec=""
    for tok in $WITH_SPEC; do case "$tok" in mcp=*) mspec="${tok#mcp=}" ;; esac; done
    if [ -n "$mspec" ]; then
      local cj="$HOME/.claude.json"
      if [ -f "$cj" ]; then
        local old_umask; old_umask="$(umask)"; umask 077
        if jq -c --arg names "$mspec" '
          ((.mcpServers // {}) + (reduce ((.projects//{})|to_entries[]) as $p ({}; . + (($p.value.mcpServers)//{})))) as $all
          | {mcpServers: ($all | with_entries(select(.key as $k | ($names|split(",")|index($k)) != null)))}
        ' "$cj" > "$cfg" 2>/dev/null; then
          chmod 600 "$cfg" 2>/dev/null || true
          umask "$old_umask"
          CC_MCP_FLAGS=(--strict-mcp-config --mcp-config "$cfg")
          return 0
        fi
        umask "$old_umask"
        echo "ERROR: isolation setup: jq filter of ~/.claude.json failed (--with mcp=$mspec); aborting to avoid silent no-isolation" >&2
        return 1
      fi
    fi
  fi
  # DEFAULT (and fallback when --with mcp= has no match / no ~/.claude.json): empty strict MCP config.
  _emit_empty_mcp_cfg "$cfg" || return 1
  CC_MCP_FLAGS=(--strict-mcp-config --mcp-config "$cfg")
  return 0
}

# _emit_empty_mcp_cfg <path> -> write {"mcpServers":{}} (umask 077, chmod 600). Returns nonzero on
# write failure so the caller can die fail-closed (never silently emit no flags -> live MCP inherits).
# This is the isolation primitive: --strict-mcp-config with an empty server set means claude loads
# ZERO user MCP servers, so no interactive-auth MCP server can wedge a headless run. Verified live:
# `claude -p --strict-mcp-config --mcp-config <this> --model haiku "reply PONG"` -> PONG (OAuth ok).
_emit_empty_mcp_cfg() {
  local cfg="$1" old_umask
  old_umask="$(umask)"; umask 077
  if ! printf '{"mcpServers":{}}' > "$cfg" 2>/dev/null; then
    umask "$old_umask"
    echo "ERROR: isolation setup: cannot write empty MCP config to $cfg" >&2
    return 1
  fi
  chmod 600 "$cfg" 2>/dev/null || true
  umask "$old_umask"
  return 0
}

# _build_prompt <model-id> <raw-task> [table-tier] -> final prompt (preamble + tier wrapper).
# BUILD DISCIPLINE: injected for mutating verbs (edit/research/yolo) so a delegate PRODUCES early
# instead of spiralling into repo exploration. Counters model exploration-spiral behavior at the
# prompt level.
_build_discipline() {
  [ "${OSRC_BUILD_DISCIPLINE:-0}" = "1" ] || return 0
  cat <<'OSRCEOF'
BUILD DISCIPLINE (you have file-write tools): produce the requested artifact(s) EARLY. Read only the
minimum needed to start, then WRITE the file(s) with the Write/Edit tool within your first few steps.
Do NOT explore the whole repo or read unrelated files. If you already have the spec, start writing NOW
and refine after. A run that only reads/greps and never writes a file has FAILED — writing is the job.

OSRCEOF
}

_build_prompt() {
  local id="$1" task="$2" ttier="${3:-}" tier pre disc
  tier="$(resolve_tier "$id" "$ttier")"
  pre="$(build_with_preamble)"; disc="$(_build_discipline)"
  { [ -n "$pre" ] && printf '%s\n\n' "$pre"; [ -n "$disc" ] && printf '%s\n' "$disc"; wrap_prompt "$tier" "$task"; }
}

# _tier_banner <lane-label> <model> <tier> <posture-note>, printed on every cc/codex/native dispatch.
_tier_banner() {
  echo ">>> [$1] $2  tier=$3  wrapper=$3  | $4" >&2
  case "$3" in
    frontier) echo "    tier=frontier, premium flagship; scaffolding stripped (model brings its own plan)" >&2 ;;
    capable)  echo "    tier=capable, frontier-CAPABILITY at budget PRICE (~Opus-4.8 class); full autonomy, no hand-holding wrapper" >&2 ;;
  esac
  # Effort is honored per lane (native or advisory); each lane prints its own effort line. Nothing silent.
}

# _consume_flags: strip leading -m/--model, --tier, --with, --allow-downgrade (any order); set
# MODEL/MODEL_EXPLICIT/TIER_FLAG/WITH_SPEC/REST and OSRC_ALLOW_DOWNGRADE. --tier also sets
# OSRC_TIER_OVERRIDE so classification honors it.
_consume_flags() {
  MODEL="$DEFAULT_MODEL"; MODEL_EXPLICIT=0; TIER_FLAG=""; WITH_SPEC=""; EFFORT="${OUTSOURCERER_EFFORT:-}"; OSRC_ALLOW_DOWNGRADE="${OSRC_ALLOW_DOWNGRADE:-0}"
  while [ $# -gt 0 ]; do
    case "$1" in
      -m|--model) [ -n "${2:-}" ] || die "-m requires a model name"; MODEL="$2"; MODEL_EXPLICIT=1; shift 2 ;;
      --tier)     [ -n "${2:-}" ] || die "--tier requires: frontier|capable|mid|budget|raw"; TIER_FLAG="$2"; OSRC_TIER_OVERRIDE="$2"; shift 2 ;;
      --with)     [ -n "${2:-}" ] || die "--with requires e.g. skills=a,b or mcp=x"; WITH_SPEC="$WITH_SPEC $2"; shift 2 ;;
      --allow-downgrade) OSRC_ALLOW_DOWNGRADE=1; shift ;;
      --cloud-ack) OSRC_CLOUD_ACK=1; shift ;;   # consume as a LEADING flag: sets the cloud-gate ack and never leaks into REST/prompt
      # Per-invocation trust grant. Assigned WITHOUT export on purpose: it must not be inherited by a
      # bg/fanout child, which re-evaluates trust from config for whatever repo it actually runs in.
      --trust-lane) [ -n "${2:-}" ] || die "--trust-lane needs a lane name (e.g. devin)"; OSRC_TRUST_LANE_ONCE="${OSRC_TRUST_LANE_ONCE:-} $2"; shift 2 ;;
      --provider) [ -n "${2:-}" ] || die "--provider requires a name (devin|cc|codex|droid|cursor|claudex|local)"; PROVIDER="$2"; shift 2 ;;  # accepted AFTER the subcommand too (flag-placement tolerance)
      --wait|--foreground) OSRC_NO_AUTODETACH=1; shift ;;  # D3: force foreground even for slow lanes (escape hatch)
      --effort|--reasoning)
                  [ -n "${2:-}" ] || die "--effort requires: minimal|low|medium|high|xhigh|max"
                  case "$2" in minimal|low|medium|high|xhigh|max|none) EFFORT="$2" ;;
                    *) die "--effort '$2' invalid (use: minimal|low|medium|high|xhigh|max)" ;; esac
                  shift 2 ;;
      *) break ;;
    esac
  done
  REST=("$@")
}

# _effort_thinking_tokens <effort> -> MAX_THINKING_TOKENS budget for the Claude (cc/native) lanes.
_effort_thinking_tokens() {
  case "$1" in
    minimal|none) echo 0 ;;
    low)          echo 4096 ;;
    medium)       echo 10000 ;;
    high)         echo 24000 ;;
    xhigh)        echo 32000 ;;
    max)          echo 48000 ;;
    *)            echo "" ;;
  esac
}

# =============================================================================
# THE TAB: per-run ledger, tab, estimate, credits.
# =============================================================================
# record_ledger <provider> <model> <tier> <verb> <task> [cost] [lane]
record_ledger() {
  # bg jobs record the accurate (stream-json) entry from __runjob; skip the child's estimate then.
  [ "${OSRC_STREAM:-0}" = "1" ] && [ "${OSRC_LEDGER_FORCE:-0}" != "1" ] && return 0
  have jq || return 0
  mkdir -p -m 700 "$OSRC_HOME"; chmod 700 "$OSRC_HOME" 2>/dev/null || true
  # Restrict the ledger itself: the $OSRC_HOME dir is 700, but if OSRC_HOME is ever
  # pointed at a shared location the ledger (task hashes, costs, model names) should still be 600.
  [ -e "$OSRC_LEDGER" ] || : > "$OSRC_LEDGER" 2>/dev/null || true
  chmod 600 "$OSRC_LEDGER" 2>/dev/null || true
  local prov="$1" model="$2" tier="$3" verb="$4" task="$5" cost="${6:-}" lane="${7:-}"
  local intok; intok="$(_est_tokens "$task")"
  local ts; ts="$(date +%Y-%m-%dT%H:%M:%S)"
  local hash; hash="$(printf '%s' "$task" | cksum | cut -d' ' -f1)"
  # lane (resolved lane code: cx/cc/gm/or/dv/local) drives the Tab's plan-vs-cash split. The bg path
  # (run_job) records the RAW provider (e.g. devin) which mislabels a plan lane as cash, so it passes
  # the resolved lane here; cmd_tab's is_sub prefers .lane and falls back to the provider string.
  local _line; _line="$(jq -cn --arg ts "$ts" --arg p "$prov" --arg m "$model" --arg t "$tier" --arg v "$verb" \
     --arg c "$cost" --argjson it "$intok" --arg h "$hash" --arg lane "$lane" \
     '{ts:$ts,provider:$p,model:$m,tier:$t,verb:$v,in_tokens:$it,cost_usd:$c,task_hash:$h}
      + (if $lane=="" then {} else {lane:$lane} end)')" || return 0
  [ -n "$_line" ] || return 0
  if command -v flock >/dev/null 2>&1; then
    # Wait briefly for the lock; if it genuinely can't be acquired, do NOT silently drop the
    # accounting record -- fall back to a best-effort append (one small line, atomic under PIPE_BUF) and
    # warn once. A possibly-interleaved line beats losing spend/activity data with no signal.
    # The lock-failure flag is raised INSIDE the fd-9 group but the warning is emitted
    # OUTSIDE it -- the group's `2>/dev/null` (needed to hush flock/open noise) must not eat the warning.
    local _lockfail=0
    { if flock -w 5 9 2>/dev/null; then
        printf '%s\n' "$_line" >> "$OSRC_LEDGER"
      else
        printf '%s\n' "$_line" >> "$OSRC_LEDGER" 2>/dev/null || true
        _lockfail=1
      fi
    } 9>>"$OSRC_LEDGER" 2>/dev/null || true
    if [ "$_lockfail" = "1" ] && [ "${OSRC_LEDGER_LOCK_WARNED:-0}" != "1" ]; then
      echo "outsourcerer: ledger lock unavailable — appended without lock (accounting may interleave under heavy parallelism)" >&2
      export OSRC_LEDGER_LOCK_WARNED=1
    fi
  else
    printf '%s\n' "$_line" >> "$OSRC_LEDGER" 2>/dev/null || true
  fi
}

refresh_models() {
  mkdir -p -m 700 "$OSRC_HOME"; chmod 700 "$OSRC_HOME" 2>/dev/null || true
  have curl || { echo "curl needed to refresh the model catalog" >&2; return 1; }
  local _tmp; _tmp="$(mktemp "$OSRC_HOME/.models.XXXXXX" 2>/dev/null || mktemp)"
  if curl -fsS -m "${OSRC_CURL_TIMEOUT:-30}" "https://openrouter.ai/api/v1/models" -o "$_tmp" 2>/dev/null; then
    jq -e '.data' "$_tmp" >/dev/null 2>&1 && mv -f "$_tmp" "$OSRC_MODELS_JSON" && echo "refreshed $OSRC_MODELS_JSON" || { rm -f "$_tmp"; echo "refresh failed: invalid JSON" >&2; return 1; }
  else
    rm -f "$OSRC_MODELS_JSON.tmp"; echo "model refresh failed (offline?)" >&2; return 1
  fi
}

or_credits() {   # best-effort OpenRouter credit line; never fatal
  have curl && have jq || return 0
  _or_load_key 2>/dev/null || return 0
  _curl_with_auth "$OPENROUTER_API_KEY" -fsS -m "${OSRC_CURL_TIMEOUT:-30}" "https://openrouter.ai/api/v1/key" 2>/dev/null \
    | jq -r '.data | "limit=\(.limit // "n/a") usage=\(.usage // 0) remaining=\(.limit_remaining // "n/a")"' 2>/dev/null
}

# _or_gen_cost <generation-id> -> authoritative real dollar cost of ONE OpenRouter generation, or
# empty. Queries /generation?id=... which returns the exact settled cost for that call, no account-
# level lag/noise (the /key usage endpoint is async + eventually-consistent, so before/after deltas
# undercount right after completion). Retries a few times because the record posts a beat after the
# stream ends.
_or_gen_cost() {
  local gid="$1"; [ -n "$gid" ] || return 0
  have curl && have jq || return 0
  _or_load_key 2>/dev/null || return 0
  local i c
  for i in 1 2 3 4 5; do
    c="$(_curl_with_auth "$OPENROUTER_API_KEY" -fsS -m "${OSRC_CURL_TIMEOUT:-30}" \
         "https://openrouter.ai/api/v1/generation?id=$gid" 2>/dev/null \
         | jq -r '.data.total_cost // empty' 2>/dev/null)"
    case "$c" in ''|*[!0-9.]*) ;; *) printf '%s' "$c"; return 0 ;; esac
    sleep 2
  done
  return 0
}

# _or_run_cost <out.log> -> total REAL cost of all OpenRouter generations in a bg run's stream, at
# 6dp, or empty if none/unavailable. Sums every distinct gen-... id via the generation endpoint.
_or_run_cost() {
  local log="$1"; [ -s "$log" ] || return 0
  have grep || return 0
  local ids id sum="" got=0
  ids="$(grep -oE 'gen-[0-9]+-[a-zA-Z0-9]+' "$log" 2>/dev/null | sort -u)"
  [ -n "$ids" ] || return 0
  sum=0; local miss=0
  for id in $ids; do
    local c; c="$(_or_gen_cost "$id")"
    case "$c" in ''|*[!0-9.]*) miss=1; continue ;; esac
    sum="$(awk -v s="$sum" -v c="$c" 'BEGIN{printf "%.6f", s+c}')"; got=1
  done
  # Return the exact per-gen sum ONLY when EVERY generation resolved. A partial sum (some lookups
  # failed) would masquerade as authoritative and suppress the caller's '~' estimate -> undercount.
  # On any miss, return empty so the caller falls to the clearly-labeled estimate.
  [ "$got" = "1" ] && [ "$miss" = "0" ] && printf '%s' "$sum"
}

# _est_tokens <text> -> calibrated token estimate (~3.3 chars/token, the Token Optimizer constant;
# char/4 undercounts real code/BPE by ~15-20%). Integer math: len*10/33. An ESTIMATE only, labeled
# as such everywhere, provider-reported usage (bg stream cost, codex rate-limits) is preferred.
_est_tokens() { local n=${#1}; echo $(( n * 10 / 33 )); }

# _mtime <path> -> file modification time as a unix epoch, on both GNU and BSD.
# ORDER MATTERS AND IS NOT INTERCHANGEABLE. `stat -f` means "modification time" on BSD/macOS but
# "filesystem status" on GNU/Linux, where it SUCCEEDS and prints filesystem info — so a
# `stat -f ... || stat -c ...` fallback is unreachable on Linux and yields garbage that silently fails
# every later numeric comparison. GNU's `-c` is simply invalid on BSD and exits non-zero, so trying
# GNU FIRST is the only ordering where the fallback actually happens on both.
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf ''; }

# _codex_rate_limits -> "5h%|wk%|5h_reset_epoch|wk_reset_epoch" from the newest Codex session
# rollout. Codex records the ChatGPT-plan rate-limit windows the API returns into every rollout, so
# this is the REAL cost of a "no cash" ChatGPT-sub run: it spends your finite 5-hour and weekly
# limits. Best-effort; empty when codex/jq/rollout unavailable.
_codex_rate_limits() {
  have jq || return 1
  local sdir="$HOME/.codex/sessions"; [ -d "$sdir" ] || return 1
  local newest; newest="$(ls -t "$sdir"/*/*/*/*.jsonl 2>/dev/null | head -1)"
  [ -n "$newest" ] || return 1
  # How OLD this reading is matters more than the number. Codex only records rate limits while it is
  # RUNNING, so with no recent codex session the newest rollout can be days old. Usage only ever rises
  # within a window, so a stale reading is a FLOOR, never a current value — and reporting it as current
  # overstates headroom in the one direction that hurts: work gets routed to an exhausted lane.
  # The age travels in the RETURN STRING. This function is read through a command substitution, so an
  # exported variable would die with the subshell and the caller would silently see nothing — the same
  # defect that left the 0-writes flag dead for its entire life.
  local _mt; _mt="$(_mtime "$newest")"; case "$_mt" in ''|*[!0-9]*) _mt="$(date +%s)" ;; esac
  local _age; _age=$(( $(date +%s) - _mt ))
  local line; line="$(grep '"rate_limits"' "$newest" 2>/dev/null | tail -1)"
  [ -n "$line" ] || return 1
  # Bucket by window_minutes, NOT slot position: Codex rollouts do NOT reliably put the 5h window in
  # .primary (observed: primary.window_minutes=10080 = weekly, secondary=null). Classify each present
  # slot by its window (<=360min -> 5h/short, else weekly/long) so codex5h/codexwk are never swapped.
  printf '%s' "$line" | jq -r '
    ([.. | objects | select(has("rate_limits")) | .rate_limits] | last) as $r
    | select($r != null)
    | [ $r.primary, $r.secondary ] | map(select(. != null)) as $slots
    | ( [ $slots[] | select((.window_minutes // 100000) <= 360) ] | first ) as $sh
    | ( [ $slots[] | select((.window_minutes // 0)      >  360) ] | first ) as $wk
    | "\($sh.used_percent // "")|\($wk.used_percent // "")|\($sh.resets_at // "")|\($wk.resets_at // "")"
  ' 2>/dev/null | head -1 | sed "s/\$/|$_age/"
}

# _human_eta <epoch> -> "3h 12m" remaining until epoch, or "" if past/unknown.
_human_eta() {
  local target="$1" now
  case "$target" in ''|*[!0-9]*) return 0 ;; esac
  now="$(date +%s 2>/dev/null)" || return 0
  local d=$(( target - now )); [ "$d" -gt 0 ] || return 0
  printf '%dh %dm' $(( d / 3600 )) $(( (d % 3600) / 60 ))
}

# _codex_quota_line -> honest one-liner on ChatGPT-plan headroom after a codex-native run.
_codex_quota_line() {
  local raw; raw="$(_codex_rate_limits)" || return 1
  [ -n "$raw" ] || return 1
  local p s pr sr; IFS='|' read -r p s pr sr <<< "$raw"
  [ -n "$p$s" ] || return 1
  local pe se; pe="$(_human_eta "$pr")"; se="$(_human_eta "$sr")"
  local msg="ChatGPT plan usage, 5h window: ${p:-?}%"
  [ -n "$pe" ] && msg="$msg (resets in $pe)"
  msg="$msg · weekly: ${s:-?}%"
  [ -n "$se" ] && msg="$msg (resets in $se)"
  printf '%s' "$msg"
}

# ---- SESSION LIMIT AWARENESS (copilot conserve engine). Best-effort, degrade gracefully (GLM review):
# NEVER die, NEVER block a delegation — a wrong/absent limit signal must only soften a RECOMMENDATION.
_pct_normalize() {   # echo a 0..100 number, else nothing
  awk -v v="${1:-}" 'BEGIN { if (v ~ /^([0-9]+([.][0-9]+)?|[.][0-9]+)$/ && v>=0 && v<=100) printf "%g", v }' 2>/dev/null
}
_window_pct() {   # <pct> <resets_at-epoch> -> pct if the window is still live, else nothing (drop expired)
  local pct reset="${2:-}" now
  pct="$(_pct_normalize "${1:-}")"; [ -n "$pct" ] || return 1
  case "$reset" in ''|null) ;; *[!0-9]*) return 1 ;;
    *) now="$(date +%s 2>/dev/null)" || return 1; [ "$reset" -gt "$now" ] || return 1 ;; esac
  printf '%s' "$pct"
}
# _session_limits -> normalized one-liner "claude5h=95 claude7d=38 codex5h=.. codexwk=.." (omits unknown).
# Claude source = the token-optimizer statusline artifact (the only readable 5h/7d signal Claude Code
# exposes; ADVISORY — it's derived + only fresh while a statusline renders). We drop stale (>10min) and
# expired-window values rather than trust them, and honor OSRC_CC_PRESSURE as an explicit override.
_session_limits() {
  # Claude 5h/7d source precedence: explicit override > outsourcerer's own statusline tap
  # (universal, `tap install`) > the token-optimizer statusline artifact (if that plugin is present).
  local cand raw c5="" c7="" c5r="" c7r="" ts="" nowms line=""
  if [ -n "${OSRC_CC_PRESSURE:-}" ]; then
    c5="$(_pct_normalize "$OSRC_CC_PRESSURE")"       # explicit orchestrator override wins
  else
    # Try each candidate in precedence order; a STALE/expired/invalid one is SKIPPED so we fall
    # through to the next fresh source (fixes: a frozen $OSRC_HOME artifact shadowing token-optimizer's
    # fresh file forever). tap file first (universal), then token-optimizer's.
    for cand in "$OSRC_HOME/rate-limits.json" "$HOME/.claude/token-optimizer/rate-limits.json"; do
      [ -f "$cand" ] && have jq && jq -e . "$cand" >/dev/null 2>&1 || continue
      raw="$(jq -r '"\(.five_hour.used_percentage // "")|\(.five_hour.resets_at // "")|\(.seven_day.used_percentage // "")|\(.seven_day.resets_at // "")|\(.timestamp // "")"' "$cand" 2>/dev/null)"
      IFS='|' read -r c5 c5r c7 c7r ts <<EOF
$raw
EOF
      # Freshness gate: fail CLOSED. A statusline artifact older than 10min — OR one whose timestamp is
      # missing/non-integer (can't prove freshness) — is treated as stale and skipped.
      nowms="$(date +%s 2>/dev/null)"; [ -n "$nowms" ] && nowms=$((nowms*1000))
      case "$ts" in
        ''|*[!0-9]*) c5=""; c7="" ;;                                             # unprovable -> stale
        *) [ -n "$nowms" ] && [ $((nowms - ts)) -gt 600000 ] && { c5=""; c7=""; } ;;
      esac
      c5="$(_window_pct "$c5" "$c5r" 2>/dev/null)" || c5=""
      c7="$(_window_pct "$c7" "$c7r" 2>/dev/null)" || c7=""
      [ -n "$c5$c7" ] && break                                                   # got fresh data -> stop
    done
  fi
  raw="$(_codex_rate_limits 2>/dev/null)" || raw=""
  local x5="" xw="" x5r="" xwr="" xage=""
  if [ -n "$raw" ]; then
    IFS='|' read -r x5 xw x5r xwr xage <<EOF
$raw
EOF
    x5="$(_window_pct "$x5" "$x5r" 2>/dev/null)" || x5=""
    xw="$(_window_pct "$xw" "$xwr" 2>/dev/null)" || xw=""
  fi
  [ -n "$c5" ] && line="$line claude5h=$c5"
  [ -n "$c7" ] && line="$line claude7d=$c7"
  [ -n "$x5" ] && line="$line codex5h=$x5"
  [ -n "$xw" ] && line="$line codexwk=$xw"
  # Mark the codex figures stale rather than dropping them: a floor with its age attached is useful,
  # a confident wrong number is not.
  case "$xage" in ''|*[!0-9]*) xage=0 ;; esac
  { [ -n "$x5" ] || [ -n "$xw" ]; } && [ "$xage" -gt "${OSRC_LIMITS_MAX_AGE:-7200}" ] \
    && line="$line codexage=${xage}"
  printf '%s\n' "${line# }"
}

cmd_tab() {
  [ -f "$OSRC_LEDGER" ] || { echo "The Tab is empty (no offloads recorded yet)."; return 0; }
  have jq || { echo "jq needed for tab (brew install jq)"; return 0; }
  echo "== The Tab (outsourcerer ledger: $OSRC_LEDGER) =="
  # RESILIENT PARSE: pre-filter with `fromjson? // empty` so ONE malformed/interleaved
  # ledger line (plausible under the flock-fallback append warned about in record_ledger) drops just
  # that row instead of failing the whole `jq -rs` slurp and blanking the entire Tab. Warn on stderr
  # if rows were dropped so a corrupted ledger is visible, not silent.
  local _tot _good _bad
  _tot="$(grep -cve '^[[:space:]]*$' "$OSRC_LEDGER" 2>/dev/null || echo 0)"
  _good="$(jq -Rc 'fromjson? | select(type=="object")' "$OSRC_LEDGER" 2>/dev/null | grep -c '^' 2>/dev/null || echo 0)"
  _bad=$(( _tot - _good )); [ "$_bad" -lt 0 ] && _bad=0
  jq -R 'fromjson? | select(type=="object")' "$OSRC_LEDGER" 2>/dev/null | jq -rs '
    # cashnum: numeric magnitude of the cost, treating "~est" as its number and blank/garbage as 0.
    def cashnum: (.cost_usd // "") as $c
      | if $c=="" then 0 elif ($c|startswith("~")) then ($c[1:]|tonumber? // 0) else ($c|tonumber? // 0) end;
    # Lane bucket (truthful accounting):
    #   FREE = local ($0 cash AND $0 plan). PLAN = native cx/cc/gm + keyless gpt-image + Devin-Pro ($0
    #   cash, spends a subscription/plan). CASH = cc/codex->OpenRouter, gemini API (real dollars).
    #   devin (dv): PLAN when $0 (Pro tier), but a NONZERO measured/estimated cost = pay-per-use = CASH
    #   (the bucket is decided on the cost axis, not the lane alone, so paid devin is never hidden).
    def bucket:
      (.lane // "") as $l | (.provider // "") as $p | (.verb // "") as $v
      | if ($l == "local") or ($p == "local") then "free"
        elif $l == "dv" then (if (cashnum > 0) then "cash" else "plan" end)
        elif ($l | test("^(cx|cc|gm)$")) or ($p | test("codex-native|claude-native|antigravity")) or ($v == "image" and $p == "codex") then "plan"
        else "cash" end;
    def realcost: (.cost_usd // "") as $c
      | if ($c == "") or ($c | startswith("~")) then null else ($c | tonumber? // null) end;
    def estcost:  (.cost_usd // "") as $c
      | if ($c | startswith("~")) then ($c[1:] | tonumber? // null) else null end;
    def malformed: (.cost_usd // "") as $c
      | ($c != "") and (($c|startswith("~"))|not) and (($c|tonumber?) == null);
    ([ .[] | select(bucket=="cash") ]) as $cashlanes
    | (([ $cashlanes[] | realcost | select(. != null) ] | add) // 0) as $cash
    | (([ .[]        | estcost  | select(. != null) ] | add) // 0) as $est
    | ([ $cashlanes[] | select((.cost_usd // "") == "") ] | length) as $unmeasured
    | ([ $cashlanes[] | select(malformed) ] | length) as $malformed
    | ([ .[] | select(bucket=="plan") ] | length) as $subs
    | ([ .[] | select(bucket=="free") ] | length) as $free
    | "runs recorded          : \(length)",
      "cash billed (measured)  : $\($cash)   (REAL per-generation OpenRouter cost, captured on bg runs)",
      (if $est > 0 then "cash (harness estimate) : ~$\($est)   (bg run offline, could not read OpenRouter; estimate only)" else empty end),
      "cash lanes, cost not captured: \($unmeasured) run(s)   (foreground run — re-run via bg to capture real $)",
      (if $malformed > 0 then "cash lanes, malformed $  : \($malformed) run(s)   (unparseable cost in ledger — inspect \($ARGS.named.led // "the ledger"))" else empty end),
      "on your subscription    : \($subs) run(s)  , $0 cash, but spent your ChatGPT / Claude / Antigravity / Devin Pro PLAN LIMITS",
      (if $free > 0 then "on your hardware (local): \($free) run(s)  , $0 cash AND $0 plan, fully private" else empty end),
      "by model:",
      (group_by(.model)[] | "  \(.[0].model // "(unknown)")  \(length) run(s)")
  ' --arg led "$OSRC_LEDGER" 2>/dev/null || echo "(ledger parse error)"
  [ "$_bad" -gt 0 ] && echo "  note: skipped $_bad unparseable ledger line(s) (corrupted/interleaved append) — Tab totals exclude them." >&2
  # Real ChatGPT-plan headroom (5h + weekly) when Codex has recorded it, the true cost of the
  # "no cash" sub lane. Best-effort; silent if unavailable.
  local ql; ql="$(_codex_quota_line 2>/dev/null)" && [ -n "$ql" ] && echo "  $ql"
  echo 'note: a $0 cash line is NOT "free", subscription lanes spend finite plan rate limits.'
}

cmd_estimate() {
  local task="$*"
  [ -n "$task" ] || die "estimate needs a task string to quote"
  local intok; intok="$(_est_tokens "$task")"
  echo "== estimate, prompt ~${intok} in-tokens; assuming ~2000 out-tokens =="
  if ! { have jq && [ -f "$OSRC_MODELS_JSON" ]; }; then
    echo "  (no cached pricing; run: $0 models --refresh)"
  else
    local m pp pc
    for m in $(printf '%s' "${OR_OFFLOAD_CHAIN:-$OR_CHAIN_DEFAULT}" | tr ',' ' '); do
      pp="$(jq -r --arg id "$m" '.data[]|select(.id==$id)|.pricing.prompt' "$OSRC_MODELS_JSON" 2>/dev/null)"
      pc="$(jq -r --arg id "$m" '.data[]|select(.id==$id)|.pricing.completion' "$OSRC_MODELS_JSON" 2>/dev/null)"
      if [ -n "$pp" ] && [ "$pp" != "null" ]; then
        awk -v i="$intok" -v pp="$pp" -v pc="$pc" -v m="$m" 'BEGIN{printf "  %-34s ~$%.5f\n", m, i*pp + 2000*pc}'
      else
        echo "  $m  (no cached pricing)"
      fi
    done
  fi
  awk -v i="$intok" 'BEGIN{printf "  %-34s ~$%.4f  (counterfactual @ $15/M in, $75/M out)\n", "OPUS (Claude)", i*0.000015 + 2000*0.000075}'
}

# cmd_suggest, live discovery of cheap + free models available to you RIGHT NOW, per platform.
# This reads each source's own live catalog (OpenRouter API, Devin CLI), so it tracks the ecosystem
# as it churns, no hardcoded "current best" list to rot. It surfaces candidates by PRICE/AVAILABILITY
# only; it does NOT score quality (that is a later feature). Pair a cheap pick with 'second-opinion'
# to sanity-check it. Junk/non-chat models (safety/guard/moderation/embedding) are filtered by name.
cmd_suggest() {
  have jq || die "jq needed for suggest (brew install jq)"
  [ -f "$OSRC_MODELS_JSON" ] || refresh_models >/dev/null 2>&1 || true
  echo "== outsourcerer suggest, cheap & free models you can use right now =="
  echo "   surfaced by price/availability (quality not scored yet). Try a cheap pick, then"
  echo "   run 'second-opinion' or an advisor panel to confirm it is good enough for the task."
  echo
  if [ -f "$OSRC_MODELS_JSON" ]; then
    local nfree
    nfree="$(jq -r '[.data[]|select((.pricing.prompt|tonumber)==0 and (.pricing.completion|tonumber)==0)]|length' "$OSRC_MODELS_JSON" 2>/dev/null)"
    echo "-- OpenRouter, FREE right now (\$0 cash), newest first --"
    jq -r '[.data[]
        | select((.pricing.prompt|tonumber)==0 and (.pricing.completion|tonumber)==0)
        | select((.id|test("safety|guard|moderation|embed|rerank|lyria|tts|whisper|image|video|audio|music|vision-ocr";"i"))|not)]
        | sort_by(-(.created//0)) | .[0:10][]
        | "   \(.id)   ctx \(((.context_length//0)/1000)|floor)k"' "$OSRC_MODELS_JSON" 2>/dev/null
    echo "   (${nfree:-?} free models live; showing newest 10, full list: $0 models)"
    echo
    echo "-- OpenRouter, cheapest paid, real \$/M input --"
    jq -r '[.data[]
        | select((.pricing.prompt|tonumber)>0)
        | select((.id|test("safety|guard|moderation|embed|rerank|lyria|tts|whisper|image|video|audio|music|vision-ocr";"i"))|not)]
        | sort_by(.pricing.prompt|tonumber) | .[0:6][]
        | "   \(.id)   $\(((.pricing.prompt|tonumber)*1000000*100|floor)/100)/M in"' "$OSRC_MODELS_JSON" 2>/dev/null
    echo
  else
    echo "-- OpenRouter: catalog not cached. Run: $0 models --refresh --"; echo
  fi
  if have devin; then
    local dlm; dlm="$(live_models 2>/dev/null)"
    if [ -n "$dlm" ]; then
      echo "-- Devin, live on your plan (ACU/plan-limit, no separate cash) --"
      printf '%s\n' "$dlm" | tr ',' '\n' | sed 's/^[[:space:]]*/   /' | grep -v '^[[:space:]]*$' | head -20
      echo
    fi
  fi
  echo "-- On your subscriptions (no cash, spends plan limits) --"
  echo "   Codex:  sol / terra / luna / gpt-5.x        Claude: fable / opus / sonnet / haiku"
  echo "   Antigravity (keyless): gemini-pro / gemini-flash / gemini-flash-lite"
  echo
  echo "Route one with:  $0 run -m <model> \"<task>\"   (add --provider cc|codex for OpenRouter lanes)"
}

# _ready_lanes -> space-joined "lane=detail" tokens for lanes that are ACTUALLY usable right now.
# Only ready lanes are ever offered to the user (Terra UX: never tour install paths for a lane they
# lack). Best-effort + fast; a slow probe (OpenRouter credits) is time-capped.
_ready_lanes() {
  local lanes="" ld dlm cred rem
  ld="$(_local_detect 2>/dev/null)" && lanes="$lanes local=${ld##*|}"
  # Devin probes (auth + live model list) hit the network; cap them so `brief` can't stall the
  # handshake for 10-30s on a slow backend. OSRC_BRIEF_TIMEOUT overrides (default 5s each).
  if have devin && _timeout "${OSRC_BRIEF_TIMEOUT:-5}" devin auth status 2>/dev/null | grep -qi "Logged in"; then
    dlm="$(_timeout "${OSRC_BRIEF_TIMEOUT:-5}" bash -c 'devin --model "__list__" -p "x" </dev/null 2>&1 | grep -i "^Available:"' 2>/dev/null)"
    printf '%s' "$dlm" | grep -qiE 'glm|swe' && lanes="$lanes devin=glm/swe"
  fi
  have agy && lanes="$lanes gemini=keyless"
  have codex && lanes="$lanes codex=sol/terra"
  if [ -n "$(_extract_kv_value OPENROUTER_API_KEY 2>/dev/null)" ]; then
    # or_credits already caps curl via OSRC_CURL_TIMEOUT; tighten it for the interactive brief probe.
    cred="$(OSRC_CURL_TIMEOUT="${OSRC_BRIEF_TIMEOUT:-5}" or_credits 2>/dev/null)"
    rem="${cred##*remaining=}"; rem="${rem%% *}"
    awk -v n="$rem" 'BEGIN { exit !(n ~ /^[0-9]+([.][0-9]+)?$/ && n>0) }' 2>/dev/null \
      && lanes="$lanes openrouter=funded" || lanes="$lanes openrouter=key-capped"
  fi
  have claude && lanes="$lanes claude=native"
  have droid && lanes="$lanes droid=byok"
  have cursor-agent && lanes="$lanes cursor=subscription"
  _claudex_up 2>/dev/null && lanes="$lanes claudex=proxy"
  printf '%s\n' "${lanes# }"
}

# _conserve_reco <limits-line> <lanes-line> -> ONE actionable conservation line. Threshold is
# OSRC_CONSERVE_THRESHOLD (default 50%). Priority when the Claude 5h window is tight:
# local($0/private) > Devin GLM/SWE(free) > keyless Gemini > Codex Sol/Terra(only if ChatGPT plan has
# headroom) > OpenRouter(only if funded). "All lanes tight" is handled first (GLM F6).
_conserve_reco() {
  local limits="${1:-}" lanes="${2:-}" tok c5="" x5="" xw="" xstale="" posture lane="" why="" tight=0
  for tok in $limits; do case "$tok" in
    claude5h=*) c5="${tok#*=}" ;; codex5h=*) x5="${tok#*=}" ;; codexwk=*) xw="${tok#*=}" ;;
    codexage=*) xstale="${tok#*=}" ;;
  esac; done
  if [ -n "$c5" ]; then
    posture="Claude 5h at ${c5}%"
    awk -v n="$c5" -v t="$OSRC_CONSERVE_THRESHOLD" 'BEGIN { exit !(n >= t) }' 2>/dev/null && tight=1
  else posture="Claude 5h unknown"; fi
  if [ "$tight" = "0" ]; then
    printf 'HEADROOM: %s (< %s%% conserve line) — route by best-fit; no forced conservation.\n' "$posture" "$OSRC_CONSERVE_THRESHOLD"
    return 0
  fi
  case " $lanes " in
    *" local="*)          lane="local";          why="private, \$0 cash + \$0 plan" ;;
    *" devin=glm/swe "*)  lane="Devin GLM/SWE";   why="free lane, preserves your Claude quota" ;;
    *" gemini=keyless "*) lane="keyless Gemini";  why="Antigravity login, no API key" ;;
  esac
  if [ -z "$lane" ]; then
    local codex_ok=0 seen=0 blocked=0 v
    case " $lanes " in *" codex=sol/terra "*)
      # A stale reading is a FLOOR, not a measurement: usage only rises within a window, so an old
      # low number is exactly how work gets routed to a lane that is already exhausted. Fail closed,
      # the same way the Claude freshness gate does.
      [ -n "$xstale" ] && blocked=1 && seen=1
      for v in "$x5" "$xw"; do [ -n "$v" ] || continue; seen=1
        awk -v n="$v" -v t="$OSRC_CONSERVE_THRESHOLD" 'BEGIN { exit !(n < t) }' 2>/dev/null || blocked=1; done
      [ "$seen" = "1" ] && [ "$blocked" = "0" ] && codex_ok=1 ;;
    esac
    if [ "$codex_ok" = "1" ]; then lane="Codex Sol/Terra"; why="your ChatGPT plan is below the conserve line in every known window"
    elif [ -n "$xstale" ]; then : # codex deliberately skipped: its usage reading is too old to trust
    else case " $lanes " in *" openrouter=funded "*) lane="OpenRouter"; why="funded cash lane, preserves subscription quotas" ;; esac; fi
  fi
  if [ -n "$lane" ]; then printf 'CONSERVE: %s (>= %s%%) — route grind to %s (%s); keep Claude for judgment.\n' "$posture" "$OSRC_CONSERVE_THRESHOLD" "$lane" "$why"
  else printf 'CONSERVE: %s (>= %s%%) — but no lower-cost lane is ready. Start local inference (ollama) or log into Devin; meanwhile throttle and keep judgment on Claude.\n' "$posture" "$OSRC_CONSERVE_THRESHOLD"; fi
}

# ---- LIMITS TAP: universal session-limit capture (works WITHOUT token-optimizer).
# Claude Code passes a status JSON (incl. rate-limit fields) to the configured statusLine command on
# every render. `tap run` is a PASSTHROUGH: it saves those fields to $OSRC_HOME/rate-limits.json and
# then execs the user's ORIGINAL statusline untouched (or prints a minimal line when none existed).
# `tap install` wires it into ~/.claude/settings.json (backup kept, idempotent); `tap uninstall`
# restores the original. Opt-in only — brief/doctor suggest it, never auto-install.
# The statusLine command Claude Code should invoke. On Windows the statusLine runs via cmd.exe, which
# cannot execute a bare .sh — route through the .cmd launcher sitting next to this script instead.
_tap_statusline_cmd() {
  if [ "$OSRC_PLATFORM" = "windows" ]; then
    local dir cmd; dir="$(dirname "$SCRIPT_PATH")"; cmd="$dir/outsourcerer.cmd"
    [ -f "$cmd" ] && { printf '%s tap run' "$cmd"; return; }
    printf 'bash "%s" tap run' "$SCRIPT_PATH"; return   # fallback: explicit bash
  fi
  printf '%s tap run' "$SCRIPT_PATH"
}
cmd_tap() {
  local settings="${OSRC_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
  local stash="$OSRC_HOME/tap-original-statusline.json"
  case "${1:-}" in
    run)
      local input; input="$(cat 2>/dev/null)"
      if have jq && [ -n "$input" ]; then
        mkdir -p "$OSRC_HOME" 2>/dev/null
        printf '%s' "$input" | jq -c '
          {five_hour: (.rate_limits.five_hour // .five_hour // null),
           seven_day: (.rate_limits.seven_day // .seven_day // null),
           timestamp: (now*1000|floor), source: "outsourcerer-tap"}
          | select(.five_hour != null)' > "$OSRC_HOME/.rl.tmp.$$" 2>/dev/null
        [ -s "$OSRC_HOME/.rl.tmp.$$" ] && mv -f "$OSRC_HOME/.rl.tmp.$$" "$OSRC_HOME/rate-limits.json" 2>/dev/null
        rm -f "$OSRC_HOME/.rl.tmp.$$" 2>/dev/null
      fi
      # passthrough: run the original statusline command with the same stdin, else a minimal line.
      local orig=""; [ -f "$stash" ] && have jq && orig="$(jq -r '.command // ""' "$stash" 2>/dev/null)"
      if [ -n "$orig" ]; then printf '%s' "$input" | sh -c "$orig"
      else printf '%s' "$input" | { have jq && jq -r '[(.model.display_name // "claude"), (.workspace.current_dir // "" | split("/") | last)] | map(select(. != "")) | join(" · ")' 2>/dev/null || echo "claude"; }; fi ;;
    install)
      have jq || die "tap install needs jq ($( [ "$OSRC_PLATFORM" = "windows" ] && echo 'winget install jqlang.jq' || echo 'brew/apt install jq'))"
      [ -f "$settings" ] || printf '{}\n' > "$settings" 2>/dev/null || die "tap: cannot create $settings"
      if jq -re '.statusLine.command // ""' "$settings" 2>/dev/null | grep -q "tap run"; then
        echo "tap: already installed (statusLine already routes through outsourcerer). Limits land in $OSRC_HOME/rate-limits.json"; return 0
      fi
      mkdir -p "$OSRC_HOME" 2>/dev/null
      # Stash the WHOLE original statusLine object (type/command/padding/…), not just .command.
      jq -c '.statusLine // {}' "$settings" > "$stash" 2>/dev/null
      local orig; orig="$(jq -r '.statusLine.command // ""' "$settings" 2>/dev/null)"
      cp "$settings" "$settings.bak-osrc-tap" 2>/dev/null
      jq --arg cmd "$(_tap_statusline_cmd)" '.statusLine = {type:"command", command:$cmd}' "$settings" > "$settings.tmp.$$" 2>/dev/null \
        && mv -f "$settings.tmp.$$" "$settings" || { rm -f "$settings.tmp.$$"; die "tap: could not update $settings"; }
      echo "tap: installed. Claude Code now feeds live 5h/7d limits to $OSRC_HOME/rate-limits.json on every statusline render."
      [ -n "$orig" ] && echo "tap: your original statusline still runs unchanged (passthrough): $orig"
      echo "tap: undo anytime with: $0 tap uninstall  (backup: $settings.bak-osrc-tap)" ;;
    uninstall)
      have jq || die "tap uninstall needs jq"
      [ -f "$settings" ] || { echo "tap: no settings file; nothing to uninstall."; return 0; }
      # Restore the WHOLE stashed statusLine object; if it was empty/absent, remove statusLine.
      if [ -f "$stash" ] && [ "$(jq -r '.command // "" | length' "$stash" 2>/dev/null)" != "0" ]; then
        jq --slurpfile s "$stash" '.statusLine = $s[0]' "$settings" > "$settings.tmp.$$" 2>/dev/null
      else jq 'del(.statusLine)' "$settings" > "$settings.tmp.$$" 2>/dev/null; fi
      [ -s "$settings.tmp.$$" ] && mv -f "$settings.tmp.$$" "$settings" || { rm -f "$settings.tmp.$$"; die "tap: could not update $settings"; }
      rm -f "$stash" "$OSRC_HOME/tap-original-statusline" "$OSRC_HOME/rate-limits.json" 2>/dev/null   # drop the frozen capture so it can't shadow a fresh source
      echo "tap: uninstalled (original statusline restored, captured limits cleared)." ;;
    status|"")
      if [ -f "$OSRC_HOME/rate-limits.json" ]; then echo "tap: capturing — $(cat "$OSRC_HOME/rate-limits.json" 2>/dev/null | head -c 200)"
      else echo "tap: not capturing yet. Install with: $0 tap install (one-time; makes limit-awareness automatic without token-optimizer)"; fi ;;
    *) die "tap: unknown action '${1:-}' (use: install|uninstall|status; 'run' is the internal statusline handler)" ;;
  esac
}

# cmd_brief -> the session-start handshake readout. READ-ONLY, never prompts (safe in bg/CI: prints
# and returns). The orchestrator runs this on skill activation, then presents the mode menu
# conversationally per the SKILL.md contract.
cmd_brief() {
  local lanes limits mode
  lanes="$(_ready_lanes 2>/dev/null)"
  limits="$(_session_limits 2>/dev/null)"
  printf '== outsourcerer session brief ==\n'
  printf 'ready lanes : %s\n' "${lanes:-none detected (run doctor)}"
  # Human-readable limits: turn "claude5h=95" into "Claude 5h window: 95%% used" so a non-technical
  # reader instantly knows high = nearly out. Keep the raw tokens too (agents/scripts parse them).
  if [ -n "$limits" ]; then
    local _pretty="" _t
    for _t in $limits; do case "$_t" in
      claude5h=*) _pretty="$_pretty · Claude 5h: ${_t#*=}% used" ;;
      claude7d=*) _pretty="$_pretty · Claude 7d: ${_t#*=}% used" ;;
      codex5h=*)  _pretty="$_pretty · ChatGPT 5h: ${_t#*=}% used" ;;
      codexwk=*)  _pretty="$_pretty · ChatGPT weekly: ${_t#*=}% used" ;;
      codexage=*) _codexstale="${_t#*=}" ;;
    esac; done
    if [ -n "${_codexstale:-}" ]; then
      _pretty="$_pretty  (ChatGPT figures are AT LEAST that used — last reading is $(( _codexstale / 3600 ))h old, from the newest codex session on disk. Usage only rises within a window, so the real number is higher and the lane may be exhausted. Run codex once to refresh.)"
    fi
    printf 'limits      :%s   [%s]\n' "${_pretty# · }" "$limits"
  else
    printf 'limits      : %s\n' "unavailable (no readable session meter — treat as unknown)"
  fi
  [ -z "$limits" ] && printf 'tip         : %s tap install  — one-time statusline tap; makes limit-awareness automatic (no token-optimizer needed)\n' "$0"
  _conserve_reco "$limits" "$lanes"
  if mode="$(_mode_read)"; then printf 'driving mode : %s — %s\n' "$mode" "$(_mode_meaning "$mode")"
  else printf -- '---\n'; _mode_menu; fi
}

# =============================================================================
# MODEL ADVISORY: task-aware model recommendation with benchmark data.
# Answers "which model should I use for this task?" with data, not guesses.
# Data source: OpenRouter benchmarks API (intelligence/coding/agentic indices + pricing).
# Graceful degradation: OR benchmarks -> cached models.json pricing -> tier proxy scores.
# =============================================================================

# Cache file for benchmark data from OpenRouter.
OSRC_BENCH_JSON="$OSRC_HOME/benchmarks.json"

# Native model -> OR benchmark permaslug prefix. Native subscription models (claude/codex/
# gemini lanes) need explicit mapping because their resolved ids don't appear in the OR catalog.
# Keyed by RESOLVED id (column 2 of OSRC_MODEL_TABLE), not the alias.
_NATIVE_BENCH_MAP="
fable|anthropic/claude-5-fable
opus|anthropic/claude-4.8-opus
sonnet|anthropic/claude-sonnet-5
haiku|anthropic/claude-4.5-haiku
gpt-5.6-sol|openai/gpt-5.6-sol
gpt-5.6-terra|openai/gpt-5.6-terra
gpt-5.6-luna|openai/gpt-5.6-luna
gpt-5.5|openai/gpt-5.5
glm-5.2|z-ai/glm-5.2
gemini-3.1-pro-preview|google/gemini-3.1-pro
gemini-3.5-flash|google/gemini-3.5-flash
"

# Task classification keywords, pipe-separated phrases. Category with most hits wins; default: simple.
_TASK_KW_CODE='function|class method|bug|fix|refactor|implement|compile|error|stack trace|debug|unit test|api endpoint|sql query|regex|algorithm|data structure|code review|pull request|merge conflict|lint|type error|import|module|package|deploy|ci/cd|docker|kubernetes'
_TASK_KW_REASONING='analyze|compare|evaluate|assess|critique|reason|prove|derive|tradeoff|trade-off|implication|consequence|strategy|architect|design system|decision|justify|deduce|infer|formal|mathematical|proof|logical'
_TASK_KW_AGENTIC='agent|tool use|tool call|multi-step|autonomous|execute command|run shell|file system|web search|browser|orchestrat|workflow|pipeline|subagent|delegate|parallel|fanout'
_TASK_KW_CREATIVE='write a story|write a blog|write an article|essay|creative|generate content|copywriting|headline|tagline|brand voice|narrative|storytelling|poem|screenplay|dialogue'

# Good-enough thresholds per category (benchmark index minimum).
_THRESH_CODE=60
_THRESH_REASONING=45
_THRESH_AGENTIC=35
_THRESH_CREATIVE=45

# refresh_benchmarks: fetch benchmark data from OpenRouter API, cache locally.
# Needs OPENROUTER_API_KEY. Graceful failure: returns 1, caller falls back to tier proxy.
refresh_benchmarks() {
  mkdir -p -m 700 "$OSRC_HOME"; chmod 700 "$OSRC_HOME" 2>/dev/null || true
  have curl || { echo "curl needed to refresh benchmarks" >&2; return 1; }
  have jq || { echo "jq needed to refresh benchmarks" >&2; return 1; }
  # Extract key WITHOUT _or_load_key (which dies on missing key, killing the script).
  local _k; _k="$(_extract_kv_value OPENROUTER_API_KEY)"
  [ -n "$_k" ] || { echo "OPENROUTER_API_KEY needed for benchmark data (put it in ~/.env)" >&2; return 1; }
  # Pass key via temp file to avoid exposure in process args (ps table).
  local _hdr; _hdr="$(mktemp "$OSRC_HOME/.hdr.XXXXXX" 2>/dev/null)" || { echo "cannot create temp file" >&2; return 1; }
  printf 'Authorization: Bearer %s\n' "$_k" > "$_hdr"; chmod 600 "$_hdr"
  local _tmp; _tmp="$(mktemp "$OSRC_HOME/.bench.XXXXXX" 2>/dev/null)" || { rm -f "$_hdr"; echo "cannot create temp file" >&2; return 1; }
  if curl -fsS -m "${OSRC_CURL_TIMEOUT:-30}" -H @"$_hdr" \
    "https://openrouter.ai/api/v1/benchmarks?source=artificial-analysis&task_type=intelligence&max_results=100" \
    -o "$_tmp" 2>/dev/null; then
    # Validate JSON before promoting to cache (prevents HTML error pages / truncated responses from poisoning the cache).
    if jq -e '.data | type == "array"' "$_tmp" >/dev/null 2>&1; then
      mv -f "$_tmp" "$OSRC_BENCH_JSON" || { rm -f "$_tmp" "$_hdr"; echo "failed to write benchmark cache" >&2; return 1; }
      echo "refreshed benchmark cache ($(jq -r '.meta.model_count // "?"' "$OSRC_BENCH_JSON" 2>/dev/null) models, as of $(jq -r '.meta.as_of // "?"' "$OSRC_BENCH_JSON" 2>/dev/null))"
    else
      rm -f "$_tmp"
      echo "benchmark refresh failed (response was not valid JSON with .data array)" >&2; rm -f "$_hdr"; return 1
    fi
  else
    rm -f "$_tmp"
    echo "benchmark refresh failed (offline? no OR key?)" >&2; rm -f "$_hdr"; return 1
  fi
  rm -f "$_hdr"
}

# _classify_task <prompt> -> echoes category: code|reasoning|agentic|creative|simple
# Keyword-based, most hits wins. Ties: code > reasoning > agentic > creative > simple.
# Uses grep -oE with pipe-separated phrases to count distinct keyword matches.
_classify_task() {
  local prompt="$*" lc
  lc="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')"
  local code reasoning agentic creative
  code="$(printf '%s' "$lc" | grep -oE "$_TASK_KW_CODE" 2>/dev/null | wc -l | tr -d ' ')"
  reasoning="$(printf '%s' "$lc" | grep -oE "$_TASK_KW_REASONING" 2>/dev/null | wc -l | tr -d ' ')"
  agentic="$(printf '%s' "$lc" | grep -oE "$_TASK_KW_AGENTIC" 2>/dev/null | wc -l | tr -d ' ')"
  creative="$(printf '%s' "$lc" | grep -oE "$_TASK_KW_CREATIVE" 2>/dev/null | wc -l | tr -d ' ')"
  code="${code:-0}"; reasoning="${reasoning:-0}"; agentic="${agentic:-0}"; creative="${creative:-0}"
  local best=simple best_n=0
  [ "$code" -gt "$best_n" ] && { best=code; best_n=$code; }
  [ "$reasoning" -gt "$best_n" ] && { best=reasoning; best_n=$reasoning; }
  [ "$agentic" -gt "$best_n" ] && { best=agentic; best_n=$agentic; }
  [ "$creative" -gt "$best_n" ] && { best=creative; best_n=$creative; }
  printf '%s' "$best"
}

# _bench_score_field <category> -> benchmark JSON field name for that category.
_bench_score_field() {
  case "$1" in
    code)      printf 'coding_index' ;;
    agentic)   printf 'agentic_index' ;;
    reasoning|creative|simple|*) printf 'intelligence_index' ;;
  esac
}

# _bench_threshold_for <category> -> numeric threshold (0 for simple = no floor).
_bench_threshold_for() {
  case "$1" in
    code)      printf '%s' "$_THRESH_CODE" ;;
    reasoning) printf '%s' "$_THRESH_REASONING" ;;
    agentic)   printf '%s' "$_THRESH_AGENTIC" ;;
    creative)  printf '%s' "$_THRESH_CREATIVE" ;;
    *)         printf '0' ;;
  esac
}

# _resolve_bench_slug <alias-or-resolved-id> -> OR benchmark permaslug prefix, or empty.
# Checks native map first, then strips :free and uses the id directly.
_resolve_bench_slug() {
  local mapped
  mapped="$(printf '%s\n' "$_NATIVE_BENCH_MAP" | awk -F'|' -v a="$1" '$1==a{print $2; exit}')"
  [ -n "$mapped" ] && { printf '%s' "$mapped"; return 0; }
  printf '%s' "${1%:free}"
}

# _bench_lookup <resolved-id> <field> -> "score\tprice_in\tprice_out" or empty.
# Queries the cached benchmark JSON. Prefers exact match, falls back to shortest prefix match.
_bench_lookup() {
  [ -f "$OSRC_BENCH_JSON" ] && have jq || return 0
  local slug; slug="$(_resolve_bench_slug "$1")"
  [ -n "$slug" ] || return 0
  # Try exact match first, then prefix match sorted by slug length (shortest = most canonical).
  local result
  result="$(jq -r --arg slug "$slug" --arg field "$2" '
    .data[] | select(.model_permaslug == $slug)
    | "\(.[$field] // 0)\t\(.pricing.prompt // "0")\t\(.pricing.completion // "0")"
  ' "$OSRC_BENCH_JSON" 2>/dev/null | head -1)"
  if [ -z "$result" ]; then
    # Prefix match: collect into array, sort by slug length, take shortest. Empty array -> no output.
    result="$(jq -r --arg slug "$slug" --arg field "$2" '
      [.data[] | select(.model_permaslug | startswith($slug))]
      | if length > 0 then sort_by(.model_permaslug | length) | .[0]
        | "\(.[$field] // 0)\t\(.pricing.prompt // "0")\t\(.pricing.completion // "0")"
        else empty end
    ' "$OSRC_BENCH_JSON" 2>/dev/null | head -1)"
  fi
  printf '%s' "$result"
}

# _tier_score_proxy <tier> -> rough capability score when no benchmark data exists.
_tier_score_proxy() {
  case "$1" in
    frontier) printf '55' ;;
    capable)  printf '50' ;;
    mid)      printf '40' ;;
    budget)   printf '30' ;;
    *)        printf '35' ;;
  esac
}

# cmd_advise: task-aware model recommendation with benchmark data.
# Usage: advise [--refresh] [--json] "<task prompt>"
# Classifies the task, scores all known models, recommends the best value model
# that meets the capability threshold. Explains WHY it picked that model.
cmd_advise() {
  local do_refresh=0 json_out=0 task=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --refresh) do_refresh=1; shift ;;
      --json)    json_out=1; shift ;;
      --)        shift; task="${*:-}"; break ;;
      --*)       task="${task:+$task }$1"; shift ;;   # unknown --flags treated as task text
      *)         task="${task:+$task }$1"; shift ;;
    esac
  done
  [ -n "$task" ] || die "advise needs a task description (try: $0 advise \"refactor auth module\")"
  # JSON output requires jq; fail explicitly rather than emitting empty output.
  if [ "$json_out" -eq 1 ] && ! have jq; then
    die "advise --json requires jq (install it or run without --json for text output)"
  fi

  if [ "$do_refresh" -eq 1 ] || [ ! -f "$OSRC_BENCH_JSON" ]; then
    # On explicit --refresh, show diagnostics (don't suppress stderr).
    if [ "$do_refresh" -eq 1 ]; then
      refresh_benchmarks || true
    else
      refresh_benchmarks 2>/dev/null || true
    fi
  fi

  local category field threshold
  category="$(_classify_task "$task")"
  field="$(_bench_score_field "$category")"
  threshold="$(_bench_threshold_for "$category")"

  # Score each candidate from the alias table.
  local results="" has_bench=0 bench_count=0 total_count=0
  local alias resolved lane tier bench_line score price_in price_out cost_per_m value_ratio meets
  while IFS='|' read -r alias resolved lane tier; do
    [ -n "$alias" ] || continue
    case "$lane" in gi|ci) continue ;; esac   # skip image lanes
    total_count=$((total_count + 1))
    bench_line="$(_bench_lookup "$resolved" "$field")"
    if [ -n "$bench_line" ]; then
      bench_count=$((bench_count + 1))
      score="$(printf '%s' "$bench_line" | cut -f1)"
      price_in="$(printf '%s' "$bench_line" | cut -f2)"
      price_out="$(printf '%s' "$bench_line" | cut -f3)"
    else
      score="$(_tier_score_proxy "$tier")"
      price_in="0"; price_out="0"
      if [ -f "$OSRC_MODELS_JSON" ] && have jq; then
        local p
        p="$(jq -r --arg id "$resolved" '.data[]|select(.id==$id)|.pricing.prompt // empty' "$OSRC_MODELS_JSON" 2>/dev/null | head -1)"
        [ -n "$p" ] && price_in="$p"
        p="$(jq -r --arg id "$resolved" '.data[]|select(.id==$id)|.pricing.completion // empty' "$OSRC_MODELS_JSON" 2>/dev/null | head -1)"
        [ -n "$p" ] && price_out="$p"
      fi
    fi
    # Subscription lanes (cx/cc/dv/gm): cost is plan-limited, not per-token.
    # Set price to 0 BEFORE value ratio so subscription models rank by capability, not OR price.
    case "$lane" in cx|cc|dv|gm) price_in="0"; price_out="0" ;; esac
    # Value ratio = score / max(cost_per_m_input, 0.01). Free models floored to 0.01.
    cost_per_m="$(awk -v p="$price_in" 'BEGIN{printf "%.6f", p*1000000}')"
    value_ratio="$(awk -v s="$score" -v c="$cost_per_m" 'BEGIN{if(c<0.01)c=0.01; printf "%.2f", s/c}')"
    meets=0
    awk -v s="$score" -v t="$threshold" 'BEGIN{exit (s+0 >= t+0) ? 0 : 1}' && meets=1
    # Display label for subscription lanes.
    case "$lane" in cx|cc|dv|gm) cost_per_m="0 (plan)" ;; esac
    results="$results$alias|$resolved|$lane|$tier|$score|$cost_per_m|$value_ratio|$meets
"
  done < <(printf '%s\n' "$OSRC_MODEL_TABLE")

  # Pick recommendation in two cohorts to avoid subscription lanes dominating value ratio.
  # Subscription lanes (cx/cc/dv/gm): ranked by score (cost is plan-limited, not comparable to per-token).
  # Paid lanes (or/codex): ranked by value ratio (score / cost_per_m).
  # Prefer subscription if it meets threshold; else best paid by value ratio; else highest score overall.
  local rec_alias="" rec_resolved="" rec_lane="" rec_reason=""
  local sub_best_alias="" sub_best_resolved="" sub_best_lane="" sub_best_score=-1
  local paid_best_alias="" paid_best_resolved="" paid_best_lane="" paid_best_vr=-1
  local any_best_alias="" any_best_resolved="" any_best_lane="" any_best_score=-1
  while IFS='|' read -r alias resolved lane tier score cost vr meets; do
    [ -n "$alias" ] || continue
    # Track highest score overall (fallback when nothing meets threshold).
    awk -v s="$score" -v b="$any_best_score" 'BEGIN{exit (s+0 > b+0) ? 0 : 1}' && {
      any_best_score="$score"; any_best_alias="$alias"; any_best_resolved="$resolved"; any_best_lane="$lane"
    }
    [ "$meets" = "1" ] || continue
    case "$lane" in
      cx|cc|dv|gm)
        awk -v s="$score" -v b="$sub_best_score" 'BEGIN{exit (s+0 > b+0) ? 0 : 1}' && {
          sub_best_score="$score"; sub_best_alias="$alias"; sub_best_resolved="$resolved"; sub_best_lane="$lane"
        } ;;
      *)
        awk -v v="$vr" -v b="$paid_best_vr" 'BEGIN{exit (v+0 > b+0) ? 0 : 1}' && {
          paid_best_vr="$vr"; paid_best_alias="$alias"; paid_best_resolved="$resolved"; paid_best_lane="$lane"
        } ;;
    esac
  done < <(printf '%s\n' "$results")

  # Prefer subscription (if it meets threshold), then paid by value ratio, then highest score fallback.
  if [ -n "$sub_best_alias" ]; then
    rec_alias="$sub_best_alias"; rec_resolved="$sub_best_resolved"; rec_lane="$sub_best_lane"
    rec_reason="best subscription model (score $sub_best_score, meets ${category} threshold $threshold, plan-limited cost)"
  elif [ -n "$paid_best_alias" ]; then
    rec_alias="$paid_best_alias"; rec_resolved="$paid_best_resolved"; rec_lane="$paid_best_lane"
    rec_reason="best value (ratio $paid_best_vr, meets ${category} threshold $threshold)"
  else
    rec_alias="$any_best_alias"; rec_resolved="$any_best_resolved"; rec_lane="$any_best_lane"
    rec_reason="highest score (score $any_best_score, no model met ${category} threshold $threshold, consider escalating)"
  fi

  # Determine benchmark data quality: live (majority), partial, or none.
  if [ "$bench_count" -gt 0 ] && [ "$total_count" -gt 0 ] && [ "$bench_count" -ge $((total_count / 2)) ]; then
    has_bench=1
  elif [ "$bench_count" -gt 0 ]; then
    has_bench=2  # partial
  else
    has_bench=0
  fi

  # Guard: if no candidates at all (empty model table), fail gracefully.
  [ -n "$rec_alias" ] || die "advise: no models found in the alias table to score"

  if [ "$json_out" -eq 1 ]; then
    jq -n \
      --arg task "$task" --arg category "$category" --arg field "$field" --arg threshold "$threshold" \
      --arg rec_alias "$rec_alias" --arg rec_resolved "$rec_resolved" --arg rec_lane "$rec_lane" \
      --arg rec_reason "$rec_reason" --arg has_bench "$has_bench" --argjson bench_count "$bench_count" --argjson total_count "$total_count" \
      '{task:$task, category:$category, score_field:$field, threshold:$threshold,
        recommendation:{alias:$rec_alias, model:$rec_resolved, lane:$rec_lane, reason:$rec_reason},
        benchmark_data_available:($has_bench=="1"),
        benchmark_coverage:((($bench_count|tostring) + "/" + ($total_count|tostring)))}'

  else
    echo "== outsourcerer advise =="
    echo "   task: $task"
    echo "   category: $category"
    echo "   scoring by: $field (threshold: $threshold)"
    if [ "$has_bench" = "1" ]; then
      echo "   benchmark data: live (OpenRouter, $(jq -r '.meta.as_of // "?"' "$OSRC_BENCH_JSON" 2>/dev/null), $bench_count/$total_count models)"
    elif [ "$has_bench" = "2" ]; then
      echo "   benchmark data: partial ($bench_count/$total_count models have live scores, rest use tier proxy, run: $0 advise --refresh \"$task\")"
    else
      echo "   benchmark data: none (tier proxy scores, run: $0 advise --refresh \"$task\")"
    fi
    echo
    echo "--- recommendation ---"
    echo "   model: $rec_alias ($rec_resolved)"
    echo "   lane:  $rec_lane"
    echo "   why:   $rec_reason"
    echo
    echo "--- all candidates (sorted by value ratio, >> = recommended) ---"
    printf '%s\n' "$results" | sort -t'|' -k7 -rn | while IFS='|' read -r alias resolved lane tier score cost vr meets; do
      [ -n "$alias" ] || continue
      local mark="  "
      [ "$alias" = "$rec_alias" ] && mark=">>"
      printf '%s %-16s %-28s lane=%-3s score=%-5s $/M=%-14s ratio=%-7s %s\n' \
        "$mark" "$alias" "$resolved" "$lane" "$score" "$cost" "$vr" \
        "$([ "$meets" = "1" ] && echo OK || echo 'below threshold')"
    done
    echo
    echo "Run with:  $0 run -m $rec_alias \"$task\""
    echo "Override:  $0 run -m <any-model> \"$task\"   (you know better, pick your own)"
  fi
}

# =============================================================================
# LIVENESS / SUPERVISOR + BACKGROUND JOBS.
# =============================================================================
_descendants() {   # echo ALL descendant pids of $1 (recursive, parent-before-child order)
  local p
  if have pgrep; then
    for p in $(pgrep -P "$1" 2>/dev/null); do echo "$p"; _descendants "$p"; done
  else
    # No pgrep (Git Bash / MSYS / minimal boxes): derive children from `ps`. Column layout DIFFERS:
    # System-V `ps -ef` is "UID PID PPID ..." (PID=$2, PPID=$3), but MSYS/Cygwin `ps` is
    # "PID PPID PGID ..." (PID=$1, PPID=$2). Locate the PID/PPID columns from the HEADER so we signal
    # real children on both, instead of only ever the root pid.
    ps -ef 2>/dev/null | awk -v pp="$1" '
      NR==1 { for(i=1;i<=NF;i++){ u=toupper($i); if(u=="PID")pc=i; else if(u=="PPID")ppc=i } next }
      (pc && ppc && $ppc==pp) { print $pc }
    ' | while IFS= read -r p; do [ -n "$p" ] && { echo "$p"; _descendants "$p"; }; done
  fi
}
_kill_tree() {   # TERM the whole subtree deepest-first, then KILL survivors.
  # macOS has no setsid/process-group-kill and `pkill -P` is only ONE level, so a hung codex's MCP
  # grandchildren survive it. Walk the full tree and signal deepest-first so parents
  # can't re-fork a reaped child. TERM, brief grace, then KILL anything still standing.
  local pid="$1" all rev p
  all="$pid $(_descendants "$pid")"
  rev=""; for p in $all; do rev="$p $rev"; done          # reverse -> deepest child first, root last
  for p in $rev; do kill -TERM "$p" 2>/dev/null; done
  sleep 2
  all="$pid $(_descendants "$pid")"; rev=""; for p in $all; do rev="$p $rev"; done
  for p in $rev; do kill -KILL "$p" 2>/dev/null; done
}

# _supervise <job-dir> <stall_warn> <stall_kill> <hard_timeout> -- <cmd...>
# Byte-growth watchdog + OSRC:: semantic layer + exit contract (0 done / 2 done? / 3 blocked /
# 124 timeout / 125 wedged / other = delegate rc).
_supervise() {
  local jd="$1" warn="$2" kill_after="$3" hard="$4"; shift 4
  [ "${1:-}" = "--" ] && shift
  # Job dir private, out.log restricted. The mkdir -m 700 may be a no-op if the dir exists;
  # chmod handles the existing case. 600 out.log because it can contain tool output.
  mkdir -p -m 700 "$jd"; chmod 700 "$jd"
  : > "$jd/out.log"; chmod 600 "$jd/out.log"
  echo running > "$jd/status"
  ( exec "$@" </dev/null >> "$jd/out.log" 2>&1 ) &
  local pid=$! t0 last_size=0 last_change now size idle age _jcwd=""
  t0=$(date +%s); last_change=$t0
  echo "$pid" > "$jd/pid"
  # Persist the SUPERVISOR's own pid + start-time too. If this watchdog process is killed
  # but the delegate it spawned is orphaned and keeps running, none of the stall/timeout/print-mode
  # guards below can fire — and _status_line's delegate-pid `kill -0` would still report "running".
  # Recording the supervisor pid lets _status_line detect a dead watchdog over a live orphan.
  echo "$$" > "$jd/supervisor_pid"
  ps -o lstart= -p "$$" 2>/dev/null | tr -s ' ' > "$jd/supervisor_pid_start" 2>/dev/null || true
  # Record start time for PID-reuse detection.
  local _stime; _stime="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' || printf '%s' "$t0")"
  printf '%s\n' "$_stime" > "$jd/pid_start"
  # Signal trap: kill the delegate tree if the supervisor is signaled.
  trap '_kill_tree "$pid"; echo interrupted > "$jd/status"; exit 130' TERM INT
  # Exploration-spiral guard: a mutating verb that reads/greps forever grows the log, so the
  # byte-growth timer never trips. Track WRITES too; a mutating job with 0 writes past the window is
  # flagged "exploring?" (visible in status/watch) so the orchestrator can steer instead of cancelling
  # blind. Not killed — late-writers exist; the hard timeout still backstops.
  local verb=""; [ -f "$jd/meta.json" ] && verb="$(jq -r '.verb // ""' "$jd/meta.json" 2>/dev/null)"
  [ -f "$jd/meta.json" ] && _jcwd="$(jq -r '.cwd // ""' "$jd/meta.json" 2>/dev/null)"
  [ -n "$_jcwd" ] || _jcwd="$PWD"
  : > "$jd/.fsmark" 2>/dev/null || true
  local mutating=0; case "$verb" in edit|research|yolo) mutating=1 ;; esac
  local nww="${OSRC_NOWRITE_WARN:-180}"
  while kill -0 "$pid" 2>/dev/null; do
    # PID-reuse guard: verify the process is still ours.
    local _live_stime; _live_stime="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' || printf '')"
    if [ -n "$_live_stime" ] && [ "$_live_stime" != "$_stime" ]; then
      echo "[outsourcerer] WARN: PID $pid reused by another process, treating job as dead" >&2
      echo interrupted > "$jd/status"; echo 130 > "$jd/exit"; return 130
    fi
    sleep "${OSRC_POLL:-10}"
    now=$(date +%s)
    size=$(wc -c < "$jd/out.log" 2>/dev/null || echo 0)
    if [ "$size" -gt "$last_size" ]; then
      last_size=$size; last_change=$now
      grep -a -E 'OSRC::(PROGRESS|PLAN|BLOCKED|NEED_INPUT|DONE)' "$jd/out.log" 2>/dev/null | tail -1 > "$jd/progress"
      case "$(cat "$jd/status" 2>/dev/null)" in
        stalled?) echo running > "$jd/status" ;;
        exploring?) grep -aq '"name":"\(Write\|Edit\|MultiEdit\)"' "$jd/out.log" 2>/dev/null && echo running > "$jd/status" ;;
      esac
    fi
    idle=$(( now - last_change )); age=$(( now - t0 ))
    if [ "$mutating" = "1" ] && [ "$age" -ge "$nww" ] && [ "$(cat "$jd/status" 2>/dev/null)" = "running" ]; then
      grep -aq '"name":"\(Write\|Edit\|MultiEdit\)"' "$jd/out.log" 2>/dev/null || {
        echo "exploring?" > "$jd/status"
        echo "[outsourcerer] WARN job $(basename "$jd"): ${age}s on a mutating verb ($verb) with ZERO file writes — likely exploring, not producing. Steer it or give a tighter 'write file X now' prompt." >&2; }
    fi
    # SELF-HEAL backstop (LANE-AGNOSTIC): a mutating job hitting repeated permission/sandbox denials is
    # walled off — headless delegates (claude/codex/devin/local) cannot answer an interactive prompt, so it
    # will spiral forever. Kill it fast with a clear next-step instead. Prevention (mode escalation) handles
    # the known ~/.claude case; this catches any OTHER lane/path that hits the same wall. OSRC_PERM_ABORT=0 disables.
    if [ "$mutating" = "1" ] && [ "${OSRC_PERM_ABORT:-3}" -gt 0 ] && [ "$(cat "$jd/status" 2>/dev/null)" != "permission-blocked" ]; then
      local _pd; _pd="$(grep -aciE 'requested permissions to|sandbox (denied|blocked|error)|operation not permitted|read-only file system|EACCES|permission denied' "$jd/out.log" 2>/dev/null)"; _pd="${_pd:-0}"
      if [ "$_pd" -ge "${OSRC_PERM_ABORT:-3}" ]; then
        echo "permission-blocked" > "$jd/status"
        echo "[outsourcerer] ABORT job $(basename "$jd"): $_pd permission/sandbox denials — the delegate is walled off (a protected path or sandbox that can't be auto-approved headless). Re-run with 'yolo' (bypassPermissions), from a different cwd, or with the right sandbox/--add-dir." >&2
        _kill_tree "$pid"; echo 3 > "$jd/exit"; return 3
      fi
    fi
    # DEVIN PRINT-MODE HANG (LANE-AGNOSTIC, immediate): a headless devin (`-p` / print mode) that
    # attempts a tool exec requiring confirmation cannot prompt, so it rejects the tool and then
    # HANGS — it does not exit, it does not retry, it goes silent. This is a hard wall (not a
    # retry spiral), so a single occurrence is a reliable death signal. Without this check the
    # only backstop is the byte-growth stall-kill (default 900s / 15min for capable tier), which
    # wastes a quarter-hour on a process that is already dead-in-the-water. Abort immediately.
    # Observed in the wild: devin finishes its file writes, hits this on a final validation/commit
    # command, hangs for hours until an external reaper kills the shell with an ambiguous status.
    # OSRC_NO_PRINTMODE_ABORT=1 disables (escape hatch for lanes that recover from print-mode rejects).
    #
    # Match devin's ACTUAL emission of the rejection, not the bare phrase: the phrase can appear in
    # ordinary delegate output (a delegate that reads/echoes source, greps a log, or summarizes an
    # error), and a bare-substring match there would wrongly abort a healthy job. Two anchors keep it
    # specific to a real hang:
    #   1. Require devin's log-module prefix `chisel::repl::handler:` — echoed prose/code never carries it.
    #   2. Scan only the recent TAIL: a genuine print-mode hang emits the line and then goes silent, so
    #      it sits at the end of the log; an incidental mid-run mention is pushed out of the tail.
    # If devin's log format ever changes, the check simply no-ops and the 15-min byte-growth stall-kill
    # (still in place) reaps the hang instead — slower, but correct.
    if [ "${OSRC_NO_PRINTMODE_ABORT:-0}" != "1" ] && [ "$(cat "$jd/status" 2>/dev/null)" != "permission-blocked" ]; then
      if tail -n "${OSRC_PRINTMODE_TAIL:-25}" "$jd/out.log" 2>/dev/null \
           | grep -aq 'chisel::repl::handler: Print mode: rejecting tool exec that requires confirmation'; then
        echo "permission-blocked" > "$jd/status"
        echo "[outsourcerer] ABORT job $(basename "$jd"): devin print-mode rejected a tool exec that requires confirmation — a headless delegate cannot prompt, so it will hang silently. Re-run with 'yolo' (bypassPermissions), or restructure the prompt so the delegate ends on a file write (move validation/commit/PR creation to the orchestrator)." >&2
        _kill_tree "$pid"; echo 3 > "$jd/exit"; return 3
      fi
    fi
    if [ "$age" -ge "$hard" ]; then
      echo timeout > "$jd/status"; _kill_tree "$pid"; echo 124 > "$jd/exit"; return 124
    fi
    # Before declaring a stall, look for progress the LOG cannot show. A delegate that prints nothing
    # while writing files is working, and killing it is the failure this watchdog causes rather than
    # prevents. The log cannot answer this — a silent delegate emits no tool-call markers either — so
    # ask the filesystem. Bounded and only consulted at the moment of judgement, so healthy jobs never
    # pay for it. OSRC_FS_PROGRESS=0 disables.
    if [ "$idle" -ge "$warn" ] && [ "${OSRC_FS_PROGRESS:-1}" = "1" ] && [ -n "${_jcwd:-}" ] && [ -d "$_jcwd" ]; then
      local _newest
      # `-newer <file>` is POSIX; `-newermt @epoch` is a GNU extension that BSD find silently fails to
      # parse, which would make this check quietly never fire on macOS. Compare against a marker file
      # we re-stamp on every confirmed sign of life instead.
      _newest="$(find "$_jcwd" -maxdepth "${OSRC_FS_PROGRESS_DEPTH:-3}" \
                   \( -name .git -o -name node_modules -o -name .venv -o -name target -o -name dist \) -prune -o \
                   -type f -newer "$jd/.fsmark" -print 2>/dev/null | head -1)"
      if [ -n "$_newest" ]; then
        last_change=$now; idle=0; : > "$jd/.fsmark"
        [ "$(cat "$jd/status" 2>/dev/null)" = "stalled?" ] && echo running > "$jd/status"
      fi
    fi
    if [ "$idle" -ge "$kill_after" ]; then
      # A job that never emitted ANYTHING past the launch banner is a different failure from one that
      # produced work and then went quiet, and it has a different fix. The usual cause is a prompt that
      # told the delegate to stay silent (write to a file, print only at the end) — advice this tool
      # itself gives for output-token exhaustion. Following that advice makes a long job look identical
      # to a hung one, so say which case this is instead of a bare "wedged".
      echo wedged > "$jd/status"
      # "Never spoke" is decided by CONTENT, not by a byte count taken before the child had even
      # written its banner. Our own launcher lines all start with '>>> '; if the log holds nothing
      # else, the delegate contributed nothing and this is the silent-by-instruction case.
      if ! grep -aqv '^>>> ' "$jd/out.log" 2>/dev/null; then
        printf 'silent-delegate\n' > "$jd/reason" 2>/dev/null || true
        echo "[outsourcerer] job $(basename "$jd") produced NO output for ${idle}s and was stopped. It never printed anything past the launch banner, so there was no way to tell work from a hang. If you told the delegate to write to a file and print only at the end, ask it to also emit a periodic 'OSRC::PROGRESS <what it is doing>' line — that is what keeps the watchdog fed. If the work is genuinely long and silent, raise the stall window: OSRC_STALL_KILL=<seconds>." >&2
      fi
      _kill_tree "$pid"; echo 125 > "$jd/exit"; return 125
    fi
    if [ "$idle" -ge "$warn" ] && [ "$(cat "$jd/status" 2>/dev/null)" = "running" ]; then
      echo "stalled?" > "$jd/status"
      echo "[outsourcerer] WARN job $(basename "$jd"): no output for ${idle}s (kill at ${kill_after}s)" >&2
    fi
  done
  wait "$pid"; local rc=$?; echo "$rc" > "$jd/exit"
  # Classify on the LAST OSRC:: terminal marker, not the FIRST appearance. A delegate that ends with
  # OSRC::DONE is done even if "OSRC::BLOCKED" appeared earlier (e.g. it echoed the protocol
  # instructions, or reconsidered mid-run). Only a final BLOCKED/NEED_INPUT means blocked.
  # ANCHORED to line start. A delegate emits its terminal marker as its own line; the protocol text it
  # was given ("end with OSRC::DONE <summary> or OSRC::BLOCKED <reason>") embeds BOTH markers in one
  # sentence, so a delegate that finishes and then echoes that reminder would be graded on the echo and
  # its completed work reported as blocked. Same class as the print-mode and truncation scans: a
  # signature matched anywhere in a log is one the delegate can forge just by quoting it.
  local last; last="$(_last_marker "$jd/out.log")"
  case "$last" in
    OSRC::BLOCKED|OSRC::NEED_INPUT) echo blocked > "$jd/status"; return 3 ;;
  esac
  # Output-token exhaustion is a distinct, recoverable failure, but engines report it as a generic
  # non-zero exit with the partial answer still sitting in the log. Left unnamed it reads as "the run
  # broke"; the operator keeps the truncated output and never learns the result was cut, not wrong.
  # Scanned in the TAIL only: a real cut-off is the LAST thing in the log, whereas prose that merely
  # mentions truncation (a delegate discussing an API response, or reading a log containing the phrase)
  # lands mid-run and gets pushed out. Same anchoring discipline as the print-mode detector.
  if [ "$rc" -ne 0 ] && tail -n 15 "$jd/out.log" 2>/dev/null | grep -aqiE 'response truncated|max output token limit|finish_reason.*length'; then
    echo failed > "$jd/status"
    printf 'output-token-limit\n' > "$jd/reason" 2>/dev/null || true
    echo "[outsourcerer] job $(basename "$jd") hit the model's OUTPUT-TOKEN limit — the answer in out.log is CUT SHORT, not complete. Do not treat it as the result. Re-run split into smaller batches, or tell the delegate to WRITE ITS FINDINGS TO A FILE and end with a short summary instead of printing everything — in that case also ask it to print a periodic 'OSRC::PROGRESS <step>' line, or a long silent run looks identical to a hang and gets stopped." >&2
    return "$rc"
  fi
  if [ "$rc" -ne 0 ]; then echo failed > "$jd/status"; return "$rc"
  elif [ "$last" = "OSRC::DONE" ]; then echo done > "$jd/status"; return 0
  else
    echo "done?" > "$jd/status"
    echo "[outsourcerer] WARN: delegate exited 0 without OSRC::DONE, verify before trusting" >&2
    return 2
  fi
}

_new_job_id() { printf '%s-%s' "$(date +%Y%m%d-%H%M%S)" "$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%06x%06x' $$ ${RANDOM:-0})"; }

_tier_windows() {   # <tier> -> "warn kill hard" seconds (env overrides win)
  case "$1" in
    budget)            echo "${OSRC_STALL_WARN:-90} ${OSRC_STALL_KILL:-240} ${OSRC_TIMEOUT:-900}" ;;
    frontier|capable)  echo "${OSRC_STALL_WARN:-300} ${OSRC_STALL_KILL:-900} ${OSRC_TIMEOUT:-3600}" ;;  # reasoning models need room to think
    *)                 echo "${OSRC_STALL_WARN:-150} ${OSRC_STALL_KILL:-420} ${OSRC_TIMEOUT:-1800}" ;;
  esac
}

# _fg_guard <dispatch-fn> <tier> -- run a FOREGROUND delegate attached to the terminal, but under a
# watchdog. `bg`/`fanout` are supervised by _supervise; foreground verbs (run/research/edit/yolo)
# had NO watchdog, so a delegate that finishes the work but wedges on teardown (proven: codex emits the
# answer, then an MCP-auth worker dies + a Stop hook loops, and the process never exits) hangs forever.
# Design: keep the terminal attached (stream stdout live via tee, leave stderr as-is);
# only STDOUT is watched for the OSRC:: terminal marker. Two deadlines: the tier HARD cap for work
# that never finishes, and a short TEARDOWN cap that starts the moment a DONE/BLOCKED marker appears
# (catches the wedge fast without killing a legit long think). Only the OUTERMOST foreground route
# guards: bg jobs (OSRC_STREAM=1) and self-heal re-invocations (OSRC_FG_GUARD_ACTIVE=1) run inline.
_fg_guard() {
  local fn="$1" tier="$2"
  if [ "${OSRC_STREAM:-0}" = "1" ] || [ "${OSRC_FG_GUARD:-1}" = "0" ] || [ "${OSRC_FG_GUARD_ACTIVE:-0}" = "1" ]; then
    "$fn"; return $?
  fi
  local w hard tdl; w="$(_tier_windows "$tier")"; hard="${OSRC_FG_TIMEOUT:-${w##* }}"; tdl="${OSRC_FG_TEARDOWN:-45}"
  local base cap fifo rcf hit; base="${TMPDIR:-/tmp}/osrc.fg.$$.${RANDOM}"; cap="$base.log"; fifo="$base.fifo"; rcf="$base.rc"; hit="$base.hit"
  if ! mkfifo "$fifo" 2>/dev/null; then "$fn"; return $?; fi     # no fifo -> never block the user, run inline
  export OSRC_FG_GUARD_ACTIVE=1
  tee "$cap" < "$fifo" & local tp=$!
  ( "$fn" </dev/null > "$fifo"; echo $? > "$rcf" ) & local prod=$!   # stdout->fifo (streamed+captured); stderr stays on terminal
  ( local t0 now mk=0; t0=$(date +%s)
    while kill -0 "$prod" 2>/dev/null; do
      sleep 2; now=$(date +%s)
      [ "$mk" = 0 ] && grep -qaE '^[[:space:]]*OSRC::(DONE|BLOCKED|NEED_INPUT)' "$cap" 2>/dev/null && mk=$now
      if [ "$mk" != 0 ] && [ $((now-mk)) -ge "$tdl" ]; then echo teardown > "$hit"; _kill_tree "$prod"; break; fi
      if [ $((now-t0)) -ge "$hard" ];               then echo hard     > "$hit"; _kill_tree "$prod"; break; fi
    done ) & local gd=$!
  trap 'echo interrupt > "'"$hit"'"; _kill_tree "'"$prod"'" 2>/dev/null; kill "'"$gd"'" "'"$tp"'" 2>/dev/null; rm -f "'"$base"'".* 2>/dev/null' INT TERM
  wait "$prod" 2>/dev/null
  kill "$gd" 2>/dev/null; wait "$gd" 2>/dev/null; wait "$tp" 2>/dev/null
  trap - INT TERM
  export OSRC_FG_GUARD_ACTIVE=0
  local rc hval lastmark; rc="$(cat "$rcf" 2>/dev/null || echo 124)"; hval="$(cat "$hit" 2>/dev/null || echo)"
  lastmark="$(_last_marker "$cap")"
  case "$hval" in
    teardown) printf '>>> [watchdog] work finished (%s) but the process kept running %ss past it — a teardown hang (e.g. codex MCP-auth / Stop-hook loop). Killed the tree. For unattended work use `bg` (auto watchdog + report).\n' "${lastmark:-marker}" "$tdl" >&2
              case "$lastmark" in OSRC::BLOCKED|OSRC::NEED_INPUT) rc=3 ;; *) rc=0 ;; esac ;;
    hard)     printf '>>> [watchdog] foreground hit the %ss hard cap and was killed. Raise OSRC_FG_TIMEOUT, or run via `bg` for long unattended work.\n' "$hard" >&2; rc=124 ;;
    interrupt) rc=130 ;;
  esac
  rm -f "$cap" "$fifo" "$rcf" "$hit" 2>/dev/null
  return "$rc"
}

# Cloud gate for DETACHED jobs. A bg/fanout job runs via `nohup __runjob` with no TTY, so the
# in-child cloud disclosure would hit the fail-closed non-interactive REFUSE and break the primary
# parallel path by default (Devin, the default provider, is a cloud lane). Acquire the ack ONCE here
# in the interactive PARENT and propagate it to children via OSRC_CLOUD_ACK -- the FLAG, not ACKED, so
# each child STILL runs its own secret-scan hard-block on real credential files. Local lanes are exempt
# (they never leave the machine). Idempotent across a fanout batch once OSRC_CLOUD_ACK is exported.
_bg_cloud_preack() {   # args: <verb> [flags] "task"
  [ "${OSRC_CLOUD_ACK:-0}" = "1" ] && return 0
  [ "${OSRC_CLOUD_ACKED:-0}" = "1" ] && return 0
  # remembered consent: same weight as OSRC_CLOUD_ACK=1 (children still run their own secret-scan).
  _cloud_consent_ok && { export OSRC_CLOUD_ACK=1; return 0; }
  # honor an explicit --cloud-ack on the bg/fanout CLI: the documented non-interactive escape hatch.
  # Scan leading flags only -- skip the verb ($1), skip each value-taking flag's argument,
  # and STOP at `--` or the first positional task. A task whose text is literally "--cloud-ack" (passed
  # after `--`) must NOT self-ack. Model token is captured in the same single pass.
  local _a _prev="verb" _m="" _first=1
  for _a in "$@"; do
    if [ "$_first" = "1" ]; then _first=0; continue; fi          # skip the verb
    case "$_prev" in
      -m|--model) _m="$_a"; _prev="$_a"; continue ;;             # flag value: capture model, don't treat as task
      -t|--tier|-e|--effort|--with|--label|--route|-p|--provider) _prev="$_a"; continue ;;
    esac
    case "$_a" in
      --) break ;;                                                # end of flags -> everything after is task
      --cloud-ack) _cloud_consent_persist; export OSRC_CLOUD_ACK=1; return 0 ;;
      -*) _prev="$_a" ;;                                          # some other leading flag, keep scanning
      *) break ;;                                                 # first positional task -> stop
    esac
  done
  # local lanes never touch the network -> no ack needed (mirrors route_delegate's local short-circuit).
  case "$PROVIDER:$_m" in local:*|*:ollama:*|*:lmstudio:*|*:lms:*|*:local|*:local:*) return 0 ;; esac
  if [ -t 0 ] && [ -t 2 ]; then
    printf '>>> [outsourcerer] CLOUD bg/fanout: jobs delegate to a cloud lane (provider=%s) -- repo content in %s LEAVES this machine.\n' "$PROVIDER" "${PWD/#$HOME/~}" >&2
    printf '>>>   Each job still runs a secret-scan hard-block on real credential files. Acknowledge for this batch? [y/N] ' >&2
    local ans=""; IFS= read -r ans </dev/tty 2>/dev/null || ans=""
    case "$ans" in y|Y|yes|YES) _cloud_consent_persist; export OSRC_CLOUD_ACK=1; return 0 ;; esac
    die "CLOUD GATE: bg/fanout cloud disclosure declined -- refusing. Re-run with --cloud-ack / OSRC_CLOUD_ACK=1, or use a local (ollama/lmstudio) lane."
  fi
  die "CLOUD GATE: bg/fanout to a cloud lane needs a ONE-TIME consent in a non-interactive context. Fix once, never see this again:
    $0 consent grant        # remember consent for all future runs
  or pass --cloud-ack on this command (also remembered). Local ollama/lmstudio lanes are exempt."
}

# _bg_launch <verb> [flags] "task" -> mint a job id, detach a supervised __runjob, echo ONLY the id.
# Shared by cmd_bg and cmd_fanout so a job is minted+detached the exact same way everywhere.
_bg_launch() {
  # NOTE: the cloud preack is intentionally NOT called here -- _bg_launch runs inside `id=$(_bg_launch ...)`
  # command substitution, where a `die` only kills the subshell (fake-success launch). Callers (cmd_bg /
  # cmd_fanout) MUST call _bg_cloud_preack in the parent shell BEFORE the substitution.
  mkdir -p -m 700 "$OSRC_JOBS" 2>/dev/null; chmod 700 "$OSRC_JOBS" 2>/dev/null
  local id jd tries=0
  # Claim the job dir ATOMICALLY -- `mkdir` (no -p) fails if the dir already exists, so two
  # concurrent launches that mint the same id can never share one directory; regenerate on collision.
  while :; do
    id="$(_new_job_id)"; jd="$OSRC_JOBS/$id"
    mkdir -m 700 "$jd" 2>/dev/null && break
    tries=$((tries+1))
    [ "$tries" -ge 8 ] && { echo "bg: could not allocate a unique job dir under $OSRC_JOBS" >&2; return 1; }
  done
  chmod 700 "$jd" 2>/dev/null
  # If we cannot even record the initial status, the job never really started -- clean up and
  # fail loudly rather than emitting an id for a phantom job (which makes fanout's waiter hang forever).
  # Verify the supervisor binary is actually runnable BEFORE we claim the job
  # and background it -- otherwise nohup of a missing/non-exec SCRIPT_PATH fails asynchronously while we
  # already printed an id and wrote status=running, leaving a phantom job the fanout waiter hangs on.
  if [ ! -x "$SCRIPT_PATH" ] && ! command -v "$SCRIPT_PATH" >/dev/null 2>&1; then
    rm -rf "$jd" 2>/dev/null; echo "bg: supervisor not executable: $SCRIPT_PATH (nothing started)" >&2; return 1
  fi
  # LAUNCHING sentinel (job liveness): record the start time and a NON-TERMINAL `launching` state
  # BEFORE detaching. The detached child writes meta.json/pid/out.log and _supervise flips the state to
  # `running` only once the real process is up. If the child dies in that window (a sandbox that reaps
  # detached jobs, an early crash), the job stays `launching` — and _status_line converts a `launching`
  # job with no process/log after a grace window into `failed` (stillborn), instead of leaving a job
  # stuck reporting `running` that no watchdog ever reaps. `date` first so `started_at` always exists.
  date +%s > "$jd/started_at" 2>/dev/null || true
  if ! echo launching > "$jd/status" 2>/dev/null; then
    rm -rf "$jd" 2>/dev/null; echo "bg: cannot write job status under $jd (filesystem full/unwritable?)" >&2; return 1
  fi
  nohup "$SCRIPT_PATH" __runjob "$id" "$PROVIDER" "$@" >/dev/null 2>&1 &
  printf '%s' "$id"
}

# bg [--provider X already parsed] [--worktree] <verb> [flags] "task" -> detach a supervised job, print id.
cmd_bg() {
  # flag-placement tolerance: global flags are legal between `bg` and the verb.
  while :; do case "${1:-}" in
    --worktree)  export OSRC_WORKTREE=1; shift ;;
    --cloud-ack) export OSRC_CLOUD_ACK=1; shift ;;
    --provider)  [ -n "${2:-}" ] || die "--provider requires a name (devin|cc|codex|droid|cursor|claudex|local)"; PROVIDER="$2"; shift 2 ;;
    *) break ;;
  esac; done
  [ $# -gt 0 ] || die "bg needs a task (e.g. bg \"map this repo\" or bg run -m hy3 \"...\")"
  # INTUITIVE DEFAULT (papercut fix): if no verb is given, assume `run`. `bg "task"`, `bg -m glm "task"`,
  # and `bg run "task"` all work now. Only a bare word that isn't a verb and isn't a flag triggers it.
  if ! _is_verb "${1:-}"; then
    case "${1:-}" in
      -*) set -- run "$@" ;;                          # starts with a flag -> insert default verb `run`
      *)  set -- run "$@" ;;                          # a task string     -> insert default verb `run`
    esac
    printf '>>> [bg] no verb given; defaulting to `run` (read-only). Use edit/yolo for mutating work.\n' >&2
  fi
  _bg_cloud_preack "$@"   # ack in the PARENT so a refusal `die`s the whole command (not just a subshell)
  local id; id="$(_bg_launch "$@")"
  [ -n "$id" ] || die "bg: launch failed -- no job id was minted (nothing was started)."
  echo "$id"
  echo "[outsourcerer] job $id launched (provider=$PROVIDER). Poll: $0 status $id  |  read: $0 result $id" >&2
}

# AUTO-DETACH: a non-interactive slow-lane foreground run blocks until the model finishes (3-5 min
# for frontier/reasoning). When invoked through a harness shell tool with a ~2-min timeout, the call is
# KILLED mid-run (observed twice on Sol gates). When non-interactive AND slow-lane, auto-promote the run
# to the existing bg path: launch detached under the bg watchdog, print the job id + poll command, return
# in <1s. The caller polls status/watch. This is ROUTING — it reuses _bg_launch (same watchdog, same
# status receipt, same result retrieval as `bg`), NOT new infra.
#
# Escape hatches (both directions):
#   OSRC_NO_AUTODETACH=1 / --wait / --foreground : forces foreground even for slow lanes.
#   OSRC_FORCE_AUTODETACH=1                       : forces detach even interactively (for testing).
#
# _autodetach_should <disp> <model-id> <model-tier> -> return 0 if the run should auto-detach, 1 if not.
# Trigger: non-interactive (stdout not a TTY) AND slow lane (any cloud lane OR frontier/reasoning tier).
# NOT triggered for: local lanes, budget/quick tiers, interactive (TTY) runs, or inside an existing bg job.
_autodetach_should() {
  local disp="$1" mid="$2" mtier="$3"
  # Escape hatch: explicit opt-out -> always foreground.
  [ "${OSRC_NO_AUTODETACH:-0}" = "1" ] && return 1
  # Already inside a bg job (OSRC_STREAM=1 or OSRC_JOB_DIR set) -> don't re-detach (would fork-bomb).
  [ "${OSRC_STREAM:-0}" = "1" ] && return 1
  [ -n "${OSRC_JOB_DIR:-}" ] && return 1
  # Escape hatch: explicit force -> always detach (even interactive, for testing).
  [ "${OSRC_FORCE_AUTODETACH:-0}" = "1" ] && return 0
  # Interactive (stdout is a TTY) -> stay foreground (a human wants to watch).
  [ -t 1 ] && return 1
  # Local lanes are fast (no network) -> stay foreground.
  case "$disp" in local) return 1 ;; esac
  # Budget tier (quick models) -> stay foreground even if cloud (they're fast).
  [ "$mtier" = "budget" ] && return 1
  # At this point: non-interactive, not local, not budget -> SLOW lane (cloud or frontier) -> auto-detach.
  return 0
}

# _autodetach_run <verb> [flags] "task" -> launch via the existing bg machinery, print receipt, return 0.
# Reuses _bg_launch (same watchdog, same status, same result retrieval as `bg`). The cloud preack is
# already satisfied: _cloud_disclose ran BEFORE this and set OSRC_CLOUD_ACKED=1, so _bg_cloud_preack
# returns early (the ack propagates to the detached child via OSRC_CLOUD_ACK).
_autodetach_run() {
  _bg_cloud_preack "$@"   # ack in the PARENT so a refusal `die`s the whole command (not just a subshell)
  local id; id="$(_bg_launch "$@")"
  [ -n "$id" ] || die "auto-detach: launch failed -- no job id was minted (nothing was started)."
  printf '>>> [auto-detach] non-interactive slow-lane run detached to bg to avoid a caller tool-timeout.\n' >&2
  printf '>>>   job id : %s\n' "$id" >&2
  printf '>>>   poll   : %s status %s  |  watch: %s watch %s  |  result: %s result %s\n' "$0" "$id" "$0" "$id" "$0" "$id" >&2
  echo "$id"
  return 0
}

# _worktree_setup <job-id> -> "path<TAB>branch<TAB>base_sha" + rc 0 when OSRC_WORKTREE=1 and we're in a
# git repo; rc 1 (no output) otherwise so the caller keeps the normal checkout. Opt-in only, never implicit.
_worktree_setup() {
  [ "${OSRC_WORKTREE:-0}" = "1" ] || return 1
  local id="$1" root wt br base
  root="$(git rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$root" ] || { echo "[outsourcerer] --worktree ignored: not inside a git repo (running in the normal checkout)." >&2; return 1; }
  wt="$root/.outsourcerer/worktrees/$id"; br="outsourcerer/$id"
  base="$(git -C "$root" rev-parse HEAD 2>/dev/null)"
  if ! git -C "$root" worktree add -q -b "$br" "$wt" HEAD 2>/dev/null; then
    echo "[outsourcerer] --worktree setup failed for $id (branch exists / detached?); running in the normal checkout." >&2
    return 1
  fi
  printf '%s\t%s\t%s' "$wt" "$br" "$base"
}

# __runjob <id> <provider> <verb> [flags] "task"  (internal; run detached by cmd_bg)
run_job() {
  local id="$1" prov="$2"; shift 2
  # This detached job process creates last.txt/out.log (incl. the Codex --output-last-message
  # path that writes last.txt DURING _supervise). Set a private umask up front so NONE of them are ever
  # briefly world-readable. No restore needed -- this is a dedicated short-lived process that exits after.
  umask 077
  local jd="$OSRC_JOBS/$id"; mkdir -p -m 700 "$jd"; chmod 700 "$jd"
  local verb="$1"; shift
  # OPT-IN worktree isolation: run this job in its own disposable git worktree so parallel EDITING jobs
  # never collide. cd into it BEFORE meta.json is written so cwd records the worktree.
  local wt="" wbr="" wbase="" _wl
  # Mark the slow pre-supervisor setup phase. `git worktree add` on a large repo can take minutes, and
  # until _supervise runs there is no pid and no out.log — exactly the signature of a job the
  # environment killed. Without this marker the stillborn check reports a perfectly healthy job as
  # dead the moment setup outlasts the launch grace.
  printf 'worktree\n' > "$jd/setup" 2>/dev/null || true
  if _wl="$(_worktree_setup "$id")"; then
    wt="${_wl%%$'\t'*}"; _wl="${_wl#*$'\t'}"; wbr="${_wl%%$'\t'*}"; wbase="${_wl##*$'\t'}"
    # If cd fails, DON'T run in the old cwd while pretending to be isolated — clear worktree state so the
    # job runs (unisolated) in the normal checkout and no bogus worktree.json/cleanup target is recorded.
    if ! cd "$wt" 2>/dev/null; then
      echo "[outsourcerer] worktree cd failed for $id; running in the normal checkout (not isolated)." >&2
      wt=""; wbr=""; wbase=""
    fi
  fi
  rm -f "$jd/setup" 2>/dev/null || true   # setup finished; normal launch-grace applies from here
  # peek model/tier for windows + meta (non-fatal)
  _consume_flags "$@" 2>/dev/null || true
  local row id2 ttier="" tier lane=""
  row="$(resolve_model_row "$MODEL")"; id2="$MODEL"
  # row is "resolved-id|lane|tier" (see resolve_model_row). Capture the LANE (middle field) too --
  # meta previously recorded only provider (the ORIGINAL provider, e.g. devin), which mislabels a
  # plan lane (gm/cx/cc) as a cash lane in the Tab. Persist the resolved lane so accounting is truthful.
  [ -n "$row" ] && { id2="${row%%|*}"; ttier="${row##*|}"; lane="$(printf '%s' "$row" | awk -F'|' '{print $2}')"; }
  # Engine lanes (droid/cursor) own their model catalog: -m passes through verbatim, and with no -m
  # the ENGINE's configured default runs -- never our alias table's, so don't record it as such.
  case "$prov" in
    droid|cursor) lane="$prov"; [ "$MODEL_EXPLICIT" = "1" ] || id2="($prov default)" ;;
    claudex)      lane="claudex"; [ "$MODEL_EXPLICIT" = "1" ] || id2="gpt-5.6-sol" ;;
  esac
  lane="$(_effective_lane "$lane" "$prov" "$MODEL" "$MODEL_EXPLICIT")"
  tier="$(resolve_tier "$id2" "$ttier")"
  local wins warn kill hard; wins="$(_tier_windows "$tier")"; warn="${wins%% *}"; hard="${wins##* }"; kill="$(echo "$wins" | awk '{print $2}')"
  # Prefer the start time _bg_launch recorded before detaching (job liveness), so `started` reflects
  # the real launch instant, not the later meta write; fall back to now for a direct (non-bg) call.
  local _started; _started="$(cat "$jd/started_at" 2>/dev/null)"; case "$_started" in ''|*[!0-9]*) _started="$(date +%s)" ;; esac
  if have jq; then
    jq -cn --arg id "$id" --arg p "$prov" --arg v "$verb" --arg m "$id2" --arg t "$tier" --arg lane "$lane" \
       --arg cwd "$PWD" --argjson st "$_started" --arg wt "$wt" --arg wbr "$wbr" --arg wbase "$wbase" \
       '{id:$id,provider:$p,verb:$v,model:$m,tier:$t,cwd:$cwd,started:$st}
        + (if $lane=="" then {} else {lane:$lane} end)
        + (if $wt=="" then {} else {worktree:$wt,branch:$wbr,base_sha:$wbase} end)' > "$jd/meta.json" 2>/dev/null || true
  fi
  # Run the real dispatch (foreground path) under the watchdog, in stream mode so we get last.txt+cost.
  OSRC_STREAM=1 OSRC_JOB_DIR="$jd" OUTSOURCERER_DEPTH=0 OUTSOURCERER_PROVIDER="$prov" \
    _supervise "$jd" "$warn" "$kill" "$hard" -- \
    "$SCRIPT_PATH" --provider "$prov" "$verb" "$@"
  local sc=$?
  # Worktree receipt: record base/head SHA + dirty/ahead so the orchestrator can inspect or integrate
  # deterministically. NEVER auto-remove — the worktree is preserved until an explicit `cleanup`.
  if [ -n "$wt" ]; then
    local hsha dirty=false ahead
    hsha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
    [ -n "$(git -C "$wt" status --porcelain 2>/dev/null | head -1)" ] && dirty=true
    ahead="$(git -C "$wt" rev-list --count "$wbase..HEAD" 2>/dev/null)"; ahead="${ahead:-0}"
    have jq && jq -cn --arg p "$wt" --arg b "$wbr" --arg bs "$wbase" --arg hs "$hsha" \
       --argjson d "$dirty" --argjson a "$ahead" \
       '{path:$p,branch:$b,base_sha:$bs,head_sha:$hs,dirty:$d,ahead:$a}' > "$jd/worktree.json" 2>/dev/null || true
    printf '[worktree] job %s: branch %s at %s (ahead %s, dirty %s) — inspect/merge, then: outsourcerer cleanup %s\n' \
      "$id" "$wbr" "$wt" "$ahead" "$dirty" "$id" >&2
  fi
  # Post-process: extract last.txt from cc stream-json; text fallback otherwise.
  # (umask 077 already set at run_job start -- covers this and the earlier Codex --output-last-message write.)
  if [ ! -s "$jd/last.txt" ] && grep -aq '"type":"result"' "$jd/out.log" 2>/dev/null && have jq; then
    jq -r 'select(.type=="result")|.result' "$jd/out.log" 2>/dev/null > "$jd/last.txt"
  fi
  [ -s "$jd/last.txt" ] || cp "$jd/out.log" "$jd/last.txt" 2>/dev/null || true
  # last.txt is the result payload; keep it private.
  [ -f "$jd/last.txt" ] && chmod 600 "$jd/last.txt" 2>/dev/null || true
  # REAL cash, in priority order:
  #  1. Per-generation cost from OpenRouter's /generation endpoint (authoritative, exact, per-job).
  #  2. If this WAS an OpenRouter run but the per-gen lookup failed: the harness estimate (labeled "~").
  #     (The account-usage DELTA was removed -- it double-counted under concurrent fanout.)
  #  3. No OpenRouter generation at all => native/keyless => $0 cash.
  local real_cost; real_cost="$(_or_run_cost "$jd/out.log" 2>/dev/null)"
  if [ -z "$real_cost" ]; then
    if grep -qE 'gen-[0-9]+-[a-zA-Z0-9]+' "$jd/out.log" 2>/dev/null; then
      # per-gen cost is authoritative and per-job; the account-usage delta double-counts under concurrent
      # fanout (overlapping before/after windows), so drop it -> use the clearly-labeled '~' estimate.
      local est; est="$(jq -r 'select(.type=="result")|.total_cost_usd // empty' "$jd/out.log" 2>/dev/null | tail -1)"
      [ -n "$est" ] && real_cost="~$est"
    else
      # No OpenRouter generation id in the stream. For a NATIVE/keyless/local/plan lane that genuinely
      # means no cash ($0). But for a CASH OpenRouter lane (or) it means we COULD NOT MEASURE this run
      # (the Responses stream never surfaced a gen- id and the /generation lookup was empty) -- recording
      # $0 there would UNDERSTATE real spend (cash-lane under-report guard). Leave it unmeasured so the Tab counts it under
      # "cash lanes, est-only" (honest) instead of "$0 measured" (false).
      case "$lane" in
        or) real_cost="" ;;                 # cash OpenRouter, unmeasurable -> unmeasured, NOT "free"
        *)  real_cost="0.000000" ;;         # native / keyless / local / plan -> genuinely no cash
      esac
    fi
  fi
  # Always record the run (even unmeasured): an empty cost is meaningful (cmd_tab counts it as
  # est-only), and the old `[ -n "$real_cost" ]` guard would DROP an unmeasured cash run entirely,
  # hiding a real offload from the Tab. record_ledger tolerates an empty cost arg.
  OSRC_LEDGER_FORCE=1 record_ledger "$prov" "$id2" "$tier" "$verb" "job:$id" "$real_cost" "$lane"
  return "$sc"
}

_job_field() { jq -r "$2 // \"?\"" "$OSRC_JOBS/$1/meta.json" 2>/dev/null || echo "?"; }

# _job_acts <job-dir> -> "R# W# B#" tool-call tally from a stream-json out.log (empty if none).
# This is the fix for the "is it PRODUCING or just exploring?" blind spot: a byte-growth watchdog
# can't tell reading from writing (reads emit bytes too), so surface the tool mix directly.
_job_acts() {
  local L="$1/out.log"; [ -s "$L" ] || return 1
  local r w b
  r=$(grep -aco '"name":"\(Read\|Grep\|Glob\)"' "$L" 2>/dev/null); r=${r:-0}
  w=$(grep -aco '"name":"\(Write\|Edit\|MultiEdit\|NotebookEdit\)"' "$L" 2>/dev/null); w=${w:-0}
  b=$(grep -aco '"name":"Bash"' "$L" 2>/dev/null); b=${b:-0}
  [ "$r$w$b" = "000" ] && return 1
  # A mutating job (edit/research/yolo) that has read/bashed for a while with ZERO writes is very
  # likely stuck exploring. The write count travels in this RETURN STRING, not in an exported variable:
  # callers read this function through a command substitution, so anything exported here dies with the
  # subshell and the caller silently sees a default forever.
  printf 'R%s W%s B%s' "$r" "$w" "$b"
}

# _reconcile_status <id> -> echo the job's status, first flipping a stale one to reflect reality.
# Extracted so EVERY read path shares it. A status file records what was true when it was written; a
# delegate killed after `running` was written leaves that word on disk forever. Any reader that trusts
# it without this reconciliation reports a corpse as a live job — which is how `status --json` showed
# phantom `running` jobs and how `fanout wait` could block forever on a member that had already died.
_reconcile_status() {
  local jd="$OSRC_JOBS/$1" st now
  [ -d "$jd" ] || return 1
  st="$(cat "$jd/status" 2>/dev/null || echo '?')"
  # A job is alive only if either
  #   (a) the DELEGATE pid is live AND still OUR process — a bare `kill -0` can match a recycled pid,
  #       so compare live `ps -o lstart=` against the saved pid_start exactly as _supervise does; or
  #   (b) the SUPERVISOR (watchdog) is still running AND is likewise still our process — it will
  #       reconcile the delegate itself.
  # Falls back to a bare kill -0 for legacy jobs that predate the pid_start/supervisor_pid files.
  # Also covers stalled?/exploring?: those are still-running states, and a job killed while flagged
  # would otherwise keep that flag forever because nothing writes a terminal status for it.
  case "$st" in
    running|stalled\?|exploring\?)
      local _jpid _spid _alive=0 _live_stime _saved_stime
      _jpid="$(cat "$jd/pid" 2>/dev/null)"
      if [ -n "$_jpid" ] && kill -0 "$_jpid" 2>/dev/null; then
        _live_stime="$(ps -o lstart= -p "$_jpid" 2>/dev/null | tr -s ' ')"
        _saved_stime="$(cat "$jd/pid_start" 2>/dev/null | tr -s ' ')"
        { [ -z "$_saved_stime" ] || [ "$_live_stime" = "$_saved_stime" ]; } && _alive=1
      fi
      if [ "$_alive" = "0" ]; then
        _spid="$(cat "$jd/supervisor_pid" 2>/dev/null)"
        if [ -n "$_spid" ] && kill -0 "$_spid" 2>/dev/null; then
          # Same pid-reuse discipline as the delegate: a recycled supervisor pid must not resurrect
          # a dead job just because some unrelated process now holds that number.
          _live_stime="$(ps -o lstart= -p "$_spid" 2>/dev/null | tr -s ' ')"
          _saved_stime="$(cat "$jd/supervisor_pid_start" 2>/dev/null | tr -s ' ')"
          { [ -z "$_saved_stime" ] || [ "$_live_stime" = "$_saved_stime" ]; } && _alive=1
        fi
      fi
      [ "$_alive" = "0" ] && { echo interrupted > "$jd/status" 2>/dev/null; st="interrupted"; }
      ;;
  esac
  printf '%s' "$st"
}

_status_line() {
  local id="$1" jd="$OSRC_JOBS/$1" st model started now age prog acts verb flag="" _w
  [ -d "$jd" ] || { echo "no such job: $1" >&2; return 1; }
  st="$(_reconcile_status "$id")"
  # STILLBORN detection (job liveness): a job stuck in `launching` with no process AND no log after
  # the grace window means the detached worker never came up (sandbox reaped it, early crash) — convert
  # it to `failed` with an actionable reason instead of leaving a permanent `launching`/phantom.
  now=$(date +%s)
  if [ "$st" = "launching" ]; then
    local _sa; _sa="$(cat "$jd/started_at" 2>/dev/null)"; case "$_sa" in ''|*[!0-9]*) _sa=$now ;; esac
    # A job still inside its setup phase gets a much longer bound: the work is real, just slow. It is
    # still BOUNDED — a setup that hangs forever must not become a permanent phantom.
    local _grace="${OSRC_LAUNCH_GRACE:-45}" _phase=""
    if [ -f "$jd/setup" ]; then _grace="${OSRC_SETUP_GRACE:-900}"; _phase="$(cat "$jd/setup" 2>/dev/null)"; fi
    if [ ! -s "$jd/out.log" ] && [ ! -f "$jd/pid" ] && [ $(( now - _sa )) -ge "$_grace" ]; then
      echo failed > "$jd/status"; st="failed"
      [ -n "$_phase" ] && printf 'stillborn: the job never got past its %s setup phase (no process or output within %ss). Setup itself is stuck — check for a hung git operation or a lock left behind by an interrupted run.\n' "$_phase" "$_grace" > "$jd/error" 2>/dev/null || \
      printf 'stillborn: the launcher detached but the worker never started (no process or output within %ss). The environment likely killed the background process — e.g. a sandbox that reaps detached jobs. Re-run in the foreground (--wait) or a shell that allows background processes.\n' "${OSRC_LAUNCH_GRACE:-45}" > "$jd/error" 2>/dev/null || true
    fi
  fi
  model="$(_job_field "$id" '.model')"
  # Start time: meta.started -> the started_at sentinel -> unknown. NEVER default to 0: an epoch-1970
  # fallback would render a meaningless multi-decade "age". Show `?` when genuinely unknown.
  started="$(_job_field "$id" '.started')"; case "$started" in ''|'?'|*[!0-9]*) started="$(cat "$jd/started_at" 2>/dev/null)" ;; esac
  local agetxt agenum=0
  case "$started" in ''|*[!0-9]*) agetxt="?" ;; *) agenum=$(( now - started )); agetxt="${agenum}s" ;; esac
  prog="$(tail -1 "$jd/progress" 2>/dev/null)"
  case "$prog" in *OSRC::*) prog="OSRC::$(printf '%s' "${prog##*OSRC::}" | tr -d '"\\' )" ;; esac
  acts="$(_job_acts "$jd" 2>/dev/null)"
  verb="$(_job_field "$id" '.verb')"
  case "$verb" in edit|research|yolo)
    _w="${acts#*W}"; _w="${_w%% *}"; case "$_w" in ''|*[!0-9]*) _w=1 ;; esac
    [ "$_w" = "0" ] && [ "$agenum" -gt "${OSRC_NOWRITE_WARN:-180}" ] && [ "$st" = "running" ] && flag=" !exploring(0-writes)" ;;
  esac
  prog="$(printf '%s' "$prog" | cut -c1-"${OSRC_PROG_WIDTH:-64}")"
  printf '%-22s %-8s %-6s %-16s %-12s %s\n' "$id" "$st" "$agetxt" "$model" "${acts:-—}$flag" "$prog"
}

# _job_json <id> [label] -> one job as a stable JSON object (orchestrator control plane, schema v1).
# Built from the metadata that already exists on disk; unknown fields are null (never omitted).
_job_json() {
  local id="$1" lbl="${2:-}" jd="$OSRC_JOBS/$1" L
  [ -d "$jd" ] && have jq || return 1
  # Do NOT silently drop a job that has no meta.json (job liveness): a launching/stillborn job the
  # orchestrator can't SEE is worse than one it can. Emit a minimal record so the control plane always
  # reflects reality — status + started_at from the sentinel, everything else null.
  if [ ! -f "$jd/meta.json" ]; then
    local _st _sa; _st="$(_reconcile_status "$id" 2>/dev/null || echo unknown)"
    _sa="$(cat "$jd/started_at" 2>/dev/null)"; case "$_sa" in ''|*[!0-9]*) _sa=null ;; esac
    jq -n --arg id "$id" --arg status "$_st" --arg label "$lbl" --argjson started "${_sa:-null}" \
      '{schema_version:"1", job_id:$id, label:(if $label=="" then null else $label end),
        provider:null, verb:null, shape:null, model:null, tier:null, effort:null,
        status:$status, exit:null, started:$started, cwd:null,
        progress:{last_marker:null, reads:0, writes:0, bash:0},
        result_path:null, log_path:null, note:"no meta.json — launching/stillborn or pre-dispatch death"}'
    return 0
  fi
  L="$jd/out.log"
  local st exitc last r=0 w=0 b=0 rp=""
  st="$(_reconcile_status "$id" 2>/dev/null || echo unknown)"
  exitc="$(cat "$jd/exit" 2>/dev/null || true)"; case "$exitc" in ''|*[!0-9-]*) exitc=null ;; esac
  if [ -s "$L" ]; then   # grep -c already prints a count (incl. 0); no `|| echo 0` (would double-print)
    r=$(grep -aco '"name":"\(Read\|Grep\|Glob\)"' "$L" 2>/dev/null); r=${r:-0}
    w=$(grep -aco '"name":"\(Write\|Edit\|MultiEdit\|NotebookEdit\)"' "$L" 2>/dev/null); w=${w:-0}
    b=$(grep -aco '"name":"Bash"' "$L" 2>/dev/null); b=${b:-0}
  fi
  last="$(grep -aoE 'OSRC::(PROGRESS|PLAN|BLOCKED|NEED_INPUT|DONE)' "$L" 2>/dev/null | tail -1)"
  [ -s "$jd/last.txt" ] && rp="$jd/last.txt"
  jq -n --slurpfile m "$jd/meta.json" \
    --arg status "$st" --argjson exit "${exitc:-null}" \
    --argjson reads "${r:-0}" --argjson writes "${w:-0}" --argjson bash "${b:-0}" \
    --arg last "$last" --arg label "$lbl" --arg result_path "$rp" --arg log_path "$L" \
    '($m[0] // {}) as $me | {
       schema_version:"1", job_id:($me.id // null),
       label:(if $label=="" then ($me.label // null) else $label end),
       provider:($me.provider // null), verb:($me.verb // null), shape:($me.shape // null),
       model:($me.model // null), tier:($me.tier // null), effort:($me.effort // null),
       status:$status, exit:$exit, started:($me.started // null), cwd:($me.cwd // null),
       progress:{last_marker:(if $last=="" then null else $last end), reads:$reads, writes:$writes, bash:$bash},
       result_path:(if $result_path=="" then null else $result_path end), log_path:$log_path
     }'
}

cmd_status() {
  local id="${1:-}"
  # `status --json [id]` / `status [id] --json` -> machine-readable control plane for orchestrators.
  if [ "$id" = "--json" ] || [ "${2:-}" = "--json" ]; then
    [ "$id" = "--json" ] && id="${2:-}"
    have jq || die "status --json needs jq"
    if [ -n "$id" ] && [ "$id" != "--json" ]; then _job_json "$id"; echo; return; fi
    { printf '{"schema_version":"1","jobs":['; local first=1 d out
      for d in "$OSRC_JOBS"/*/; do [ -d "$d" ] || continue
        out="$(_job_json "$(basename "$d")")" && [ -n "$out" ] || continue
        [ $first -eq 1 ] || printf ','; first=0; printf '%s' "$out"; done
      printf ']}\n'; }
    return
  fi
  if [ -n "$id" ]; then _status_line "$id"; return; fi
  [ -d "$OSRC_JOBS" ] || { echo "no jobs yet."; return 0; }
  printf '%-22s %-8s %-6s %-16s %-12s %s\n' JOB STATE AGE MODEL ACTS "LAST"
  local d; for d in "$OSRC_JOBS"/*/; do [ -d "$d" ] || continue; _status_line "$(basename "$d")"; done
}

cmd_watch() {
  local id="${1:-}"; [ -n "$id" ] || die "watch needs a job id"
  local jd="$OSRC_JOBS/$id"; [ -d "$jd" ] || die "no such job: $id"
  local forsec=0; [ "${2:-}" = "--for" ] && forsec="${3:-60}"
  local t0; t0=$(date +%s); local last="" lastprog=""
  while :; do
    local st; st="$(cat "$jd/status" 2>/dev/null || echo '?')"
    # HEARTBEAT: print on a status change OR when a NEW OSRC::PROGRESS marker lands.
    # Before this, watch was silent for the entire multi-minute 'running' phase even while the delegate
    # emitted progress — the native equivalent of "going dark" the whole time work is happening.
    local prog; prog="$(tail -1 "$jd/progress" 2>/dev/null)"
    if [ "$st" != "$last" ] || { [ -n "$prog" ] && [ "$prog" != "$lastprog" ]; }; then
      _status_line "$id"; last="$st"; lastprog="$prog"
    fi
    case "$st" in done|done?|failed|blocked|timeout|wedged|canceled|permission-blocked|interrupted) break ;; esac
    [ "$forsec" -gt 0 ] && [ $(( $(date +%s) - t0 )) -ge "$forsec" ] && break
    sleep "${OSRC_POLL:-10}"
  done
}

cmd_result() {
  local id="${1:-}"; [ -n "$id" ] || die "result needs a job id"
  local jd="$OSRC_JOBS/$id"; [ -d "$jd" ] || die "no such job: $id"
  local shown rc=0
  # Capture once and printf once (not cat+cat / tail+tail): a double read is a TOCTOU on a growing
  # out.log and wastes IO. rc reflects the capture's status so a vanished file still surfaces nonzero.
  if [ -s "$jd/last.txt" ]; then shown="$(cat "$jd/last.txt")" || rc=$?
  else shown="$(tail -n 40 "$jd/out.log" 2>/dev/null)" || rc=$?; fi
  printf '%s' "$shown"
  # Diagnostics-only: if this is a failed devin job and the recognizable TLS/proxy hint is not
  # already in the surfaced text, re-scan devin's own log and append it to STDERR (the cause lives
  # in ~/.local/share/devin/cli/logs/, not out.log; stderr keeps it out of the result payload).
  # No retry/routing change. `|| true` keeps the helper's no-match exit (1) from becoming this
  # function's return code -- result/logs must stay 0 on a successful print (regression guard).
  _devin_job_tls_hint "$id" "$shown" >/dev/null || true
  return "$rc"
}

cmd_logs() {
  local id="${1:-}"; [ -n "$id" ] || die "logs needs a job id"
  local n=60; [ "${2:-}" = "-n" ] && n="${3:-60}"
  # Capture once and printf once: a double tail is a TOCTOU on a growing log (the dedup check
  # would see a different snapshot than what is printed). die fires on the capture if the log is
  # missing; rc stays 0 on a successful print.
  local shown rc=0; shown="$(tail -n "$n" "$OSRC_JOBS/$id/out.log" 2>/dev/null)" || die "no log for $id"
  printf '%s' "$shown"
  # Diagnostics-only (see cmd_result): append the recognizable TLS/proxy hint for a failed devin
  # job to STDERR when it is not already in the tailed log. `|| true` preserves the original
  # return code (rc) -- the helper's no-match exit must not change result/logs' exit status.
  _devin_job_tls_hint "$id" "$shown" >/dev/null || true
  return "$rc"
}

cmd_cancel() {
  local id="${1:-}"; [ -n "$id" ] || die "cancel needs a job id"
  local jd="$OSRC_JOBS/$id"; [ -d "$jd" ] || die "no such job: $id"
  local pid; pid="$(cat "$jd/pid" 2>/dev/null)"
  [ -n "$pid" ] && _kill_tree "$pid"
  echo canceled > "$jd/status"; echo "canceled $id"
}

# cleanup <job-id|fanout-gid> [--force] -> remove a job's (or a whole fanout's) git worktree(s).
# CONSERVATIVE: refuses to delete a worktree with uncommitted (dirty) or unmerged (ahead>0) work unless
# --force. Isolation is automatic; destruction is deliberate.
cmd_cleanup() {
  local force=0 target="" a
  for a in "$@"; do case "$a" in --force) force=1 ;; *) target="$a" ;; esac; done
  [ -n "$target" ] || die "cleanup needs a job id or fanout group id (add --force to remove dirty/unmerged worktrees)"
  local gd; gd="$(_fanout_dir "$target")"
  if [ -f "$gd/members.tsv" ]; then       # a fanout gid -> clean each member
    local jid label; while IFS="$(printf '\t')" read -r jid label; do
      [ -n "$jid" ] || continue
      if [ "$force" = 1 ]; then cmd_cleanup "$jid" --force; else cmd_cleanup "$jid"; fi
    done < "$gd/members.tsv"
    echo "[outsourcerer] cleaned fanout $target"; return 0
  fi
  local wj="$OSRC_JOBS/$target/worktree.json"
  [ -f "$wj" ] || { echo "[outsourcerer] job $target has no worktree to clean."; return 0; }
  have jq || die "cleanup needs jq"
  local path branch dirty ahead base
  path="$(jq -r '.path' "$wj")"; branch="$(jq -r '.branch' "$wj")"; base="$(jq -r '.base_sha // ""' "$wj")"
  # Re-read LIVE git state, not the job-completion snapshot: anything edited after the job (user, hook,
  # another process) must be seen, or --force could destroy it. Fall back to the json only if the worktree
  # is already gone.
  if git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    [ -n "$(git -C "$path" status --porcelain 2>/dev/null | head -1)" ] && dirty=true || dirty=false
    ahead="$(git -C "$path" rev-list --count "${base:-HEAD}..HEAD" 2>/dev/null)"; ahead="${ahead:-0}"
  else
    dirty="$(jq -r '.dirty' "$wj")"; ahead="$(jq -r '.ahead // 0' "$wj")"
  fi
  if [ "$force" != 1 ] && { [ "$dirty" = "true" ] || [ "${ahead:-0}" -gt 0 ]; }; then
    echo "[outsourcerer] REFUSING to remove $target: branch '$branch' has unmerged work (dirty=$dirty ahead=$ahead)." >&2
    echo "  inspect: git -C \"$path\" log --oneline; git -C \"$path\" status" >&2
    echo "  integrate e.g.: git cherry-pick $branch   OR force-remove: outsourcerer cleanup $target --force" >&2
    return 1
  fi
  local maindir="${path%/.outsourcerer/worktrees/*}"
  [ -d "$maindir/.git" ] || maindir="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)"
  # Containment check: refuse to rm -rf anything outside the expected worktree root.
  case "$path" in
    */.outsourcerer/worktrees/*) ;;
    *) die "refusing to remove path outside worktree root: $path" ;;
  esac
  if [ -n "$maindir" ] && [ -d "$maindir/.git" ]; then
    git -C "$maindir" worktree remove --force "$path" 2>/dev/null || rm -rf "$path"
    git -C "$maindir" branch -D "$branch" 2>/dev/null || true
    git -C "$maindir" worktree prune 2>/dev/null || true
  else
    rm -rf "$path"
  fi
  rm -f "$wj"
  echo "[outsourcerer] removed worktree for $target (branch $branch)"
}

# gc --older-than DAYS. Delete completed job dirs whose mtime is older than N days.
# Only terminal states (done/done?/failed/blocked/timeout/wedged/canceled/permission-blocked)
# are removed; running/interrupted jobs are left alone.
cmd_gc() {
  local days=""
  if [ "${1:-}" = "--older-than" ]; then
    [ -n "${2:-}" ] || die "gc --older-than needs a positive integer number of days"
    days="$2"
  else
    die "gc: usage: gc --older-than DAYS"
  fi
  case "$days" in ''|*[!0-9]*|'0'* ) die "gc --older-than needs a positive integer, got '$days'" ;; esac
  [ -d "$OSRC_JOBS" ] || { echo "[outsourcerer] no jobs to gc."; return 0; }
  local removed=0 skipped=0 d st mtime now cutoff
  now=$(date +%s)
  cutoff=$(( now - days * 86400 ))
  for d in "$OSRC_JOBS"/*/; do
    [ -d "$d" ] || continue
    st="$(cat "$d/status" 2>/dev/null || echo running)"
    # Auto-heal: a running job whose PID is dead is reaped.
    if [ "$st" = "running" ]; then
      local _gpid; _gpid="$(cat "$d/pid" 2>/dev/null)"
      if [ -n "$_gpid" ] && ! kill -0 "$_gpid" 2>/dev/null; then
        echo interrupted > "$d/status"; st="interrupted"
      fi
    fi
    case "$st" in done|'done?'|failed|blocked|timeout|wedged|canceled|permission-blocked|interrupted) ;;
      *) skipped=$((skipped+1)); continue ;;
    esac
    mtime="$(_mtime "$d")"
    if [ -z "$mtime" ] || ! printf '%s\n' "$mtime" | grep -q '^[0-9][0-9]*$'; then
      skipped=$((skipped+1)); continue
    fi
    if [ "$mtime" -lt "$cutoff" ]; then
      rm -rf "$d"
      removed=$((removed+1))
    else
      skipped=$((skipped+1))
    fi
  done
  echo "[outsourcerer] gc: removed $removed job dirs older than $days days; skipped $skipped (non-terminal or younger)"
}

# =============================================================================
# FANOUT (parallel multi-subagent): run N delegations in parallel across ANY provider, each as a
# supervised bg job (reuses _bg_launch/_supervise/tier-windows/ledger), with a concurrency cap and
# result collection. This is how a multi-agent skill (a code-review suite, or a
# per-module sweep) runs THROUGH the outsourcerer: N headless jobs, one fast bootstrap each, true OS
# parallelism. NOT N interactive tmux sessions, each with its own bootstrap cost. codex/devin exec
# tools HEADLESS in a sandbox (research/edit/yolo verbs) — the "headless == read-only" limit is
# claude-native-default-tier ONLY.
# =============================================================================
_fanout_dir() { printf '%s/fanout/%s' "$OSRC_HOME" "$1"; }

# _fanout_running <gid> -> count of member jobs NOT in a terminal state.
_fanout_running() {
  local gd; gd="$(_fanout_dir "$1")"; local n=0 jid label st
  [ -f "$gd/members.tsv" ] || { printf 0; return; }
  while IFS="$(printf '\t')" read -r jid label; do
    [ -n "$jid" ] || continue
    st="$(_reconcile_status "$jid" 2>/dev/null || echo running)"
    case "$st" in done|done\?|failed|blocked|timeout|wedged|canceled|permission-blocked) ;; *) n=$((n+1)) ;; esac
  done < "$gd/members.tsv"
  printf '%s' "$n"
}

_fanout_status() {
  local gid="${1:-}"; local json=0
  [ "$gid" = "--json" ] && { json=1; gid="${2:-}"; }
  [ "${2:-}" = "--json" ] && json=1
  [ -n "$gid" ] || die "fanout status needs a group id"
  local gd; gd="$(_fanout_dir "$gid")"; [ -d "$gd" ] || die "no fanout group: $gid"
  # `fanout status <gid> --json` -> the crew envelope an orchestrator parses (schema v1).
  if [ "$json" = "1" ]; then
    have jq || die "fanout status --json needs jq"
    local jid label first=1 tot=0 run=0 done_=0 blk=0 fail=0 st jobs=""
    while IFS="$(printf '\t')" read -r jid label; do
      [ -n "$jid" ] || continue; tot=$((tot+1))
      st="$(cat "$OSRC_JOBS/$jid/status" 2>/dev/null || echo running)"
      case "$st" in done) done_=$((done_+1)) ;; blocked|permission-blocked) blk=$((blk+1)) ;;
        failed|timeout|wedged|canceled) fail=$((fail+1)) ;; *) run=$((run+1)) ;; esac
      local oj; oj="$(_job_json "$jid" "$label")" && [ -n "$oj" ] || continue
      [ $first -eq 1 ] || jobs="$jobs,"; first=0
      jobs="$jobs$oj"
    done < "$gd/members.tsv"
    printf '{"schema_version":"1","fanout_id":"%s","summary":{"total":%d,"running":%d,"done":%d,"blocked":%d,"failed":%d},"jobs":[%s]}\n' \
      "$gid" "$tot" "$run" "$done_" "$blk" "$fail" "$jobs"
    return
  fi
  printf '%-24s %-9s %-7s %-22s %s\n' JOB STATE AGE LABEL "LAST PROGRESS"
  local jid label jd st started now age prog
  while IFS="$(printf '\t')" read -r jid label; do
    [ -n "$jid" ] || continue
    jd="$OSRC_JOBS/$jid"; st="$(cat "$jd/status" 2>/dev/null || echo '?')"
    # start time: meta.started -> started_at sentinel -> unknown (never epoch 0 => no meaningless huge age from an epoch-0 fallback).
    started="$(_job_field "$jid" '.started')"; case "$started" in ''|'?'|*[!0-9]*) started="$(cat "$jd/started_at" 2>/dev/null)" ;; esac
    now=$(date +%s); local agetxt; case "$started" in ''|*[!0-9]*) age=0; agetxt="?" ;; *) age=$(( now - started )); agetxt="${age}s" ;; esac
    prog="$(tail -1 "$jd/progress" 2>/dev/null)"
    # stream-json out.log makes progress a raw JSON blob; surface the human OSRC:: line and truncate.
    case "$prog" in *OSRC::*) prog="OSRC::$(printf '%s' "${prog##*OSRC::}" | tr -d '"\\')" ;; esac
    prog="$(printf '%s' "$prog" | cut -c1-72)"
    printf '%-24s %-9s %-7s %-22s %s\n' "$jid" "$st" "$agetxt" "$label" "$prog"
  done < "$gd/members.tsv"
}

_fanout_wait() {
  local gid="${1:-}"; [ -n "$gid" ] || die "fanout wait needs a group id"
  local gd; gd="$(_fanout_dir "$gid")"; [ -d "$gd" ] || die "no fanout group: $gid"
  local forsec=0; [ "${2:-}" = "--for" ] && forsec="${3:-0}"
  local t0; t0=$(date +%s)
  while [ "$(_fanout_running "$gid")" -gt 0 ]; do
    [ "$forsec" -gt 0 ] && [ $(( $(date +%s) - t0 )) -ge "$forsec" ] && break
    sleep "${OSRC_POLL:-10}"
  done
  _fanout_status "$gid" >&2
  # Return nonzero if any member failed.
  local _fail=0 _jid _st
  while IFS="$(printf '\t')" read -r _jid _; do
    [ -n "$_jid" ] || continue
    _st="$(cat "$OSRC_JOBS/$_jid/status" 2>/dev/null || echo '?')"
    case "$_st" in failed|blocked|timeout|wedged|permission-blocked|interrupted) _fail=$((_fail+1)) ;; esac
  done < "$gd/members.tsv"
  echo "[outsourcerer] fanout $gid: $(_fanout_running "$gid") still running, $_fail failed." >&2
  [ "$_fail" -eq 0 ] || return 1
}

# _fanout_collect <gid> -> copy each member's final message into findings/NN-label.md, concat into
# COLLECTED.md, print that path. This is the single artifact the orchestrator reads.
_fanout_collect() {
  local gid="${1:-}"; [ -n "$gid" ] || die "fanout collect needs a group id"
  local gd; gd="$(_fanout_dir "$gid")"; [ -d "$gd" ] || die "no fanout group: $gid"
  local out="$gd/COLLECTED.md"; : > "$out"
  printf '# Fanout %s — collected findings\n\n' "$gid" >> "$out"
  local jid label jd st dst n=0
  while IFS="$(printf '\t')" read -r jid label; do
    [ -n "$jid" ] || continue
    n=$((n+1)); jd="$OSRC_JOBS/$jid"; st="$(cat "$jd/status" 2>/dev/null || echo '?')"
    dst="$gd/findings/$(printf '%02d' "$n")-$label.md"
    if [ -s "$jd/last.txt" ]; then cp "$jd/last.txt" "$dst" 2>/dev/null
    else tail -n 80 "$jd/out.log" 2>/dev/null > "$dst"; fi
    printf '\n\n===== %s  (%s)  [%s] =====\n\n' "$label" "$jid" "$st" >> "$out"
    cat "$dst" >> "$out" 2>/dev/null || true
  done < "$gd/members.tsv"
  echo "$out"
  # Return nonzero if any member failed.
  local _fail=0
  while IFS="$(printf '\t')" read -r jid label; do
    [ -n "$jid" ] || continue
    st="$(cat "$OSRC_JOBS/$jid/status" 2>/dev/null || echo '?')"
    case "$st" in failed|blocked|timeout|wedged|permission-blocked|interrupted) _fail=$((_fail+1)) ;; esac
  done < "$gd/members.tsv"
  echo "[outsourcerer] collected $n agent outputs -> $out  ($_fail failed)  (per-agent: $gd/findings/)" >&2
  [ "$_fail" -eq 0 ] || return 1
}

_fanout_list() {
  [ -d "$OSRC_HOME/fanout" ] || { echo "no fanout groups yet."; return 0; }
  local d gid
  for d in "$OSRC_HOME/fanout"/*/; do
    [ -d "$d" ] || continue; gid="$(basename "$d")"
    printf '%-40s %s\n' "$gid" "$(head -1 "$d/manifest.txt" 2>/dev/null)"
  done
}

# cmd_fanout [status|wait|collect|list <gid>] | [launch flags] <source>
#   launch sources: --agents DIR [--sub K=V ...] [--preamble FILE] | --tasks FILE | -- "t1" "t2" ...
#   per-job knobs (forwarded to every agent): -m MODEL, --effort E, --tier T, --with SPEC, --verb V
#   --max N (concurrency cap, default 6), --label-prefix P
# _agent_route <file> -> "model|effort|tier|provider" from an agent file's YAML frontmatter routing
# keys (ALL optional; empty when absent). Additive + opt-in: this only LIFTS recognized routing keys so
# a heterogeneous agent library (e.g. agency-agents role files) can send each agent to its own lane. The
# file's prompt body is unchanged (frontmatter stays in it), so a file with no routing keys behaves
# exactly as before. A global CLI knob always overrides these.
_agent_route() {
  local f="$1" fm
  [ "$(head -1 "$f" 2>/dev/null)" = "---" ] || { printf '|||'; return; }
  fm="$(awk 'NR==1&&/^---[[:space:]]*$/{f=1;next} f&&/^---[[:space:]]*$/{exit} f{print}' "$f")"
  local _g="s/^[^:]*:[[:space:]]*//; s/^[\"'\'']//; s/[\"'\'']$//; s/[[:space:]]*$//"
  printf '%s|%s|%s|%s' \
    "$(printf '%s\n' "$fm" | grep -iE '^model:'            | head -1 | sed -E "$_g")" \
    "$(printf '%s\n' "$fm" | grep -iE '^(effort|reasoning):' | head -1 | sed -E "$_g")" \
    "$(printf '%s\n' "$fm" | grep -iE '^tier:'             | head -1 | sed -E "$_g")" \
    "$(printf '%s\n' "$fm" | grep -iE '^(lane|provider):'  | head -1 | sed -E "$_g")"
}

# _route_match <label> <spec> -> first matching model for `pattern=model,...` (glob patterns, first wins).
# Lets you route a whole agent library BY NAME without editing any file.
_route_match() {
  local label="$1" spec="$2" pair pat val oldifs="$IFS"
  IFS=','
  for pair in $spec; do
    case "$pair" in *=*) ;; *) continue ;; esac   # skip a malformed pair with no '='
    pat="${pair%%=*}"; val="${pair#*=}"
    [ -n "$(printf '%s' "$pat" | tr -d '[:space:]')" ] || continue   # skip empty pattern (e.g. trailing comma)
    pat="$(printf '%s' "$pat" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    val="$(printf '%s' "$val" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    case "$label" in $pat) IFS="$oldifs"; printf '%s' "$val"; return 0 ;; esac
  done
  IFS="$oldifs"; return 1
}

cmd_fanout() {
  case "${1:-}" in
    status)  shift; _fanout_status "$@"; return ;;
    wait)    shift; _fanout_wait "$@"; return ;;
    collect) shift; _fanout_collect "$@"; return ;;
    list)    shift; _fanout_list "$@"; return ;;
  esac
  local verb=run maxpar="${OSRC_FANOUT_MAX:-6}" preamble="" tasksfile="" agentsdir="" label_prefix="task"
  local g_model="" g_effort="" g_tier="" g_prov="" taskstr="" route_spec=""   # global knobs OVERRIDE per-agent frontmatter
  local -a subs=() fwd=() inline=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --verb)         [ -n "${2:-}" ] || die "--verb needs run|research|edit|yolo"; verb="$2"; shift 2 ;;
      --max)          [ -n "${2:-}" ] || die "--max needs a number"; maxpar="$2"; shift 2 ;;
      -m|--model)     [ -n "${2:-}" ] || die "-m needs a model"; g_model="$2"; shift 2 ;;
      --effort|--reasoning) [ -n "${2:-}" ] || die "--effort needs a level"; g_effort="$2"; shift 2 ;;
      --tier)         [ -n "${2:-}" ] || die "--tier needs a value"; g_tier="$2"; shift 2 ;;
      --provider)     [ -n "${2:-}" ] || die "--provider needs a lane"; g_prov="$2"; shift 2 ;;
      --task)         [ -n "${2:-}" ] || die "--task needs a string"; taskstr="$2"; shift 2 ;;
      --route)        [ -n "${2:-}" ] || die "--route needs 'pattern=model,...'"; route_spec="$2"; shift 2 ;;
      --worktree)     export OSRC_WORKTREE=1; shift ;;
      --with)         [ -n "${2:-}" ] || die "--with needs a spec"; fwd+=(--with "$2"); shift 2 ;;
      --preamble)     [ -n "${2:-}" ] || die "--preamble needs a file"; preamble="$2"; shift 2 ;;
      --tasks)        [ -n "${2:-}" ] || die "--tasks needs a file"; tasksfile="$2"; shift 2 ;;
      --agents)       [ -n "${2:-}" ] || die "--agents needs a dir"; agentsdir="$2"; shift 2 ;;
      --sub)          [ -n "${2:-}" ] || die "--sub needs KEY=VALUE"; subs+=("$2"); shift 2 ;;
      --label-prefix) [ -n "${2:-}" ] || die "--label-prefix needs a value"; label_prefix="$2"; shift 2 ;;
      --cloud-ack)    export OSRC_CLOUD_ACK=1; shift ;;   # documented non-interactive cloud ack for fanout
      --)             shift; inline=("$@"); break ;;
      *) die "fanout: unknown flag '$1' (sources: --agents DIR | --tasks FILE | -- \"t1\" \"t2\"; knobs: -m --effort --tier --provider --with --verb --max --preamble --sub --task \"<t>\" --route 'pat=model,...' --worktree; routing precedence: -m > --route > agent frontmatter > default; --worktree isolates each job in its own git worktree, remove with 'cleanup <id|gid> [--force]')" ;;
    esac
  done
  _is_verb "$verb" || die "fanout --verb must be one of: $_OSRC_VERBS (got '$verb')"
  # Warn on mutating verbs without --worktree.
  case "$verb" in edit|research|yolo)
    [ "${OSRC_WORKTREE:-0}" != "1" ] && echo "[outsourcerer] WARNING: fanout with --verb $verb without --worktree — parallel mutating jobs share \$PWD and may collide. Use --worktree for isolation." >&2
  ;; esac

  local pre=""; [ -n "$preamble" ] && { [ -f "$preamble" ] || die "--preamble file not found: $preamble"; pre="$(cat "$preamble")"; }
  local -a labels=() prompts=() a_model=() a_effort=() a_tier=() a_prov=()
  local f base body kv t n=0 line route rm re rt rp
  if [ -n "$agentsdir" ]; then
    [ -d "$agentsdir" ] || die "--agents dir not found: $agentsdir"
    for f in "$agentsdir"/*.md; do
      [ -f "$f" ] || continue
      base="$(basename "$f" .md)"; case "$base" in _*) continue ;; esac
      body="$(cat "$f")"
      for kv in ${subs[@]+"${subs[@]}"}; do body="${body//\{${kv%%=*}\}/${kv#*=}}"; done
      [ -n "$taskstr" ] && body="$body

## Task
$taskstr"
      [ -n "$pre" ] && body="$pre

$body"
      route="$(_agent_route "$f")"; rm="${route%%|*}"; route="${route#*|}"; re="${route%%|*}"; route="${route#*|}"; rt="${route%%|*}"; rp="${route#*|}"
      labels+=("$base"); prompts+=("$body"); a_model+=("$rm"); a_effort+=("$re"); a_tier+=("$rt"); a_prov+=("$rp")
    done
  elif [ -n "$tasksfile" ]; then
    [ -f "$tasksfile" ] || die "--tasks file not found: $tasksfile"
    while IFS= read -r line; do
      case "$line" in ''|\#*) continue ;; esac
      n=$((n+1)); body="$line"
      [ -n "$taskstr" ] && body="$body

## Task
$taskstr"
      [ -n "$pre" ] && body="$pre

$body"
      labels+=("${label_prefix}-$(printf '%02d' "$n")"); prompts+=("$body"); a_model+=("") a_effort+=("") a_tier+=("") a_prov+=("")
    done < "$tasksfile"
  elif [ "${#inline[@]}" -gt 0 ]; then
    for t in "${inline[@]}"; do
      n=$((n+1)); body="$t"; [ -n "$pre" ] && body="$pre

$body"
      labels+=("${label_prefix}-$(printf '%02d' "$n")"); prompts+=("$body"); a_model+=("") a_effort+=("") a_tier+=("") a_prov+=("")
    done
  else
    die "fanout needs a source: --agents DIR | --tasks FILE | -- \"task1\" \"task2\" ..."
  fi
  [ "${#labels[@]}" -gt 0 ] || die "fanout: no tasks found in the given source."

  local gid gd; gid="fanout-$(_new_job_id)"; gd="$(_fanout_dir "$gid")"; mkdir -p "$gd/findings"; : > "$gd/members.tsv"
  printf 'provider=%s verb=%s max=%s model=%s effort=%s tier=%s with=[%s] count=%s cwd=%s\n' \
    "${g_prov:-$PROVIDER}" "$verb" "$maxpar" "${g_model:-<per-agent|default>}" "${g_effort:-<per-agent|lane>}" "${g_tier:-<auto>}" "${fwd[*]-}" "${#labels[@]}" "$PWD" > "$gd/manifest.txt"
  echo "[outsourcerer] fanout $gid: ${#labels[@]} agents, provider=${g_prov:-$PROVIDER} verb=$verb max-parallel=$maxpar" >&2

  # Acquire the cloud ack ONCE in the PARENT before the launch loop (each _bg_launch
  # below runs in a command substitution where a `die` cannot abort the batch). The gate must consider each
  # job's EFFECTIVE lane, not just the batch-global knob: per-agent frontmatter or --route can select a
  # cloud lane even when the global provider is local (and vice versa). Resolve every job's effective
  # provider/model with the SAME precedence the launch loop uses; if ANY routes to a cloud lane, preack once
  # in the parent (dies here if refused, before a single job dir is minted). All-local batches stay exempt.
  local _pi _pem _pep _pjprov _cloud_prov="" _cloud_model=""
  for _pi in "${!labels[@]}"; do
    _pem="$g_model"
    [ -z "$_pem" ] && [ -n "$route_spec" ] && _pem="$(_route_match "${labels[$_pi]}" "$route_spec")"
    [ -z "$_pem" ] && _pem="${a_model[$_pi]}"
    _pep="${g_prov:-${a_prov[$_pi]}}"; _pjprov="${_pep:-$PROVIDER}"
    # local lanes never touch the network (mirror _bg_cloud_preack's local short-circuit); skip them.
    case "$_pjprov:$_pem" in local:*|*:ollama:*|*:lmstudio:*|*:lms:*|*:local|*:local:*) continue ;; esac
    _cloud_prov="$_pjprov"; _cloud_model="$_pem"; break   # a representative cloud job -> gate the batch
  done
  if [ -n "$_cloud_prov" ]; then
    local -a _pk=("$verb"); [ -n "$_cloud_model" ] && _pk+=(-m "$_cloud_model")
    PROVIDER="$_cloud_prov" _bg_cloud_preack "${_pk[@]}"
  fi

  local i jid em ee et ep jprov rtag
  local -a jfwd=(); local _fail=0 _ok=0
  for i in "${!labels[@]}"; do
    while [ "$(_fanout_running "$gid")" -ge "$maxpar" ]; do sleep "${OSRC_POLL:-10}"; done
    # Routing precedence: global CLI knob > --route name-pattern map > agent-file frontmatter > lane default.
    em="$g_model"
    [ -z "$em" ] && [ -n "$route_spec" ] && em="$(_route_match "${labels[$i]}" "$route_spec")"
    [ -z "$em" ] && em="${a_model[$i]}"
    ee="${g_effort:-${a_effort[$i]}}"; et="${g_tier:-${a_tier[$i]}}"; ep="${g_prov:-${a_prov[$i]}}"
    jfwd=(); [ -n "$em" ] && jfwd+=(-m "$em"); [ -n "$ee" ] && jfwd+=(--effort "$ee"); [ -n "$et" ] && jfwd+=(--tier "$et")
    jprov="${ep:-$PROVIDER}"
    jid="$(PROVIDER="$jprov" _bg_launch "$verb" ${jfwd[@]+"${jfwd[@]}"} ${fwd[@]+"${fwd[@]}"} "${prompts[$i]}")"
    if [ -z "$jid" ]; then echo "  ! launch FAILED for ${labels[$i]} (no job id minted); skipping" >&2; _fail=$((_fail+1)); continue; fi
    printf '%s\t%s\n' "$jid" "${labels[$i]}" >> "$gd/members.tsv"; _ok=$((_ok+1))
    rtag=""; [ -z "$g_model" ] && [ -n "${a_model[$i]}" ] && rtag=" [${a_model[$i]}${a_prov[$i]:+ @${a_prov[$i]}}]"
    echo "  + launched ${labels[$i]} -> $jid${rtag}" >&2
  done
  echo "$gid"
  # Surface partial-launch failures and return nonzero if ANY job failed to
  # launch, so a caller/script can't mistake a half-launched batch for a clean fanout.
  if [ "$_fail" -gt 0 ]; then
    echo "[outsourcerer] fanout $gid: $_ok launched, $_fail FAILED to launch. Watch: $0 fanout wait $gid  |  status: $0 fanout status $gid" >&2
    return 1
  fi
  echo "[outsourcerer] all ${#labels[@]} launched. Watch: $0 fanout wait $gid  |  status: $0 fanout status $gid  |  collect: $0 fanout collect $gid" >&2
}

# =============================================================================
# SECOND-OPINION: two cheap models from different families; agree->return,
# disagree->escalate to a premium model with both answers attached.
# =============================================================================
_so_norm() { tr 'A-Z' 'a-z' | tr -cd 'a-z0-9'; }
_so_run() {   # <model> <prompt> -> stdout text via the cc/OpenRouter lane (read-only)
  _or_load_key
  ANTHROPIC_BASE_URL="https://openrouter.ai/api" ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY" \
    ANTHROPIC_API_KEY= ANTHROPIC_MODEL="$1" ANTHROPIC_SMALL_FAST_MODEL="$1" \
    claude -p --bare --permission-mode default "$2" 2>/dev/null
}
second_opinion() {
  local _so_orig=("$@")
  _consume_flags "$@"
  local q="${REST[*]:-}"
  [ -n "$q" ] || die "second-opinion needs a question"
  local pair="${OSRC_SECOND_OPINION_MODELS:-z-ai/glm-5.2,deepseek/deepseek-v4-pro}"
  [ "$MODEL_EXPLICIT" = "1" ] && pair="$MODEL"
  local premium="${OSRC_SECOND_OPINION_PREMIUM:-deepseek/deepseek-v4-pro}"
  local m1 m2; m1="${pair%%,*}"; m2="${pair#*,}"
  [ "$m1" != "$m2" ] || die "second-opinion needs two different models, got '$pair' (use -m a,b)"
  echo ">>> second-opinion: $m1  vs  $m2" >&2
  _cloud_disclose ccor "$m1,$m2" "$q"
  # AUTO-DETACH: second-opinion runs 2-3 sequential cloud API calls (can take 2-5 min).
  # If non-interactive AND slow-lane, auto-promote to bg so a harness tool-timeout can't kill it.
  local _so_tier; _so_tier="$(resolve_tier "$m1" "")"
  if _autodetach_should ccor "$m1" "$_so_tier"; then
    _autodetach_run second-opinion ${_so_orig[@]+"${_so_orig[@]}"}
    return $?
  fi
  local a1 a2 n1 n2
  a1="$(_so_run "$m1" "$q")"; a2="$(_so_run "$m2" "$q")"
  n1="$(printf '%s' "$a1" | _so_norm)"; n2="$(printf '%s' "$a2" | _so_norm)"
  record_ledger cc "$m1,$m2" mixed second-opinion "$q"
  # Detect upstream failures: empty output means the call failed.
  if [ -z "$n1" ] && [ -z "$n2" ]; then
    die "second-opinion: both cheap models ($m1, $m2) returned empty — upstream failure (check OPENROUTER_API_KEY / network)"
  fi
  if [ -z "$n1" ] || [ -z "$n2" ]; then
    local _fail_model="$m2"; [ -z "$n1" ] && _fail_model="$m1"
    echo ">>> [WARNING] $_fail_model returned empty (upstream failure), using the other model's answer" >&2
  fi
  if [ -n "$n1" ] && [ -n "$n2" ] && [ "$n1" = "$n2" ]; then
    echo "== CONSENSUS ($m1 == $m2), no escalation =="
    printf '%s\n' "$a1"; return 0
  fi
  # If one model failed, use the other's answer directly (no point adjudicating against empty).
  if [ -z "$n1" ]; then echo "== $m1 failed, using $m2 ==" >&2; printf '%s\n' "$a2"; return 0; fi
  if [ -z "$n2" ]; then echo "== $m2 failed, using $m1 ==" >&2; printf '%s\n' "$a1"; return 0; fi
  echo "== DISAGREEMENT, escalating to premium ($premium) with both answers ==" >&2
  local esc
  esc="$(_so_run "$premium" "Two cheaper models disagree. Adjudicate and give the single correct answer.

QUESTION:
$q

ANSWER FROM $m1:
$a1

ANSWER FROM $m2:
$a2")"
  record_ledger cc "$premium" mid second-opinion-escalate "$q"
  [ -n "$esc" ] || die "second-opinion: premium adjudication ($premium) also returned empty — total upstream failure"
  echo "== ADJUDICATED ($premium) =="
  printf '%s\n' "$esc"
}

# =============================================================================
# NATIVE LANES: codex-native (cx) + claude-native (cc). No OpenRouter overrides.
# These ride the user's ChatGPT / Claude subscription auth. Uses RESOLVED_ID + REST (set by
# route_delegate). Premium: never auto-escalated to.
# =============================================================================
delegate_cxnative() {
  local tier="$1"
  [ "${#REST[@]}" -gt 0 ] || die "no task prompt given"
  local task="${REST[*]}" id="$RESOLVED_ID"
  have codex || die "codex CLI not on PATH (needed for the codex-native lane)"
  local sflag posture
  case "$tier" in
    auto)                    sflag=(--sandbox read-only);       posture="READ-ONLY sandbox" ;;
    accept-edits|autonomous) sflag=(--sandbox workspace-write); posture="WORKSPACE-WRITE sandbox" ;;
    dangerous)               sflag=(--dangerously-bypass-approvals-and-sandbox); posture="DANGER (no sandbox/approvals)" ;;
    *) die "bad tier: $tier" ;;
  esac
  local ttier wrapped; ttier="$(resolve_tier "$id" "${TTIER:-}")"; wrapped="$(_build_prompt "$id" "$task" "${TTIER:-}")"
  _tier_banner "codex-native" "$id" "$ttier" "$posture, draws your ChatGPT subscription limits"
  # SELF-HEAL: codex ships the `code_mode_host` feature ON, but if its host binary is not installed,
  # every file-reading tool call routes through a missing helper and HANGS. Force the feature off for
  # this run so codex falls back to normal tool execution. No effect when the binary IS present.
  local cmh=()
  _codex_code_mode_host || { cmh=(-c features.code_mode_host=false); printf '>>> [self-heal] codex-code-mode-host binary missing; running with code_mode_host disabled so file reads do not hang.\n' >&2; }
  local eff=(); if [ -n "$EFFORT" ]; then eff=(-c "model_reasoning_effort=$EFFORT"); printf '>>> [effort] reasoning=%s (native: -c model_reasoning_effort)\n' "$EFFORT" >&2; fi
  local sfx=(); [ "${OSRC_STREAM:-0}" = "1" ] && sfx=(--json --output-last-message "${OSRC_JOB_DIR:-$OSRC_HOME}/last.txt")
  # ISOLATION (I1): a delegated headless run must NOT inherit your live, interactive ~/.codex config
  # -- above all its `mcp_servers`, which can demand OAuth mid-run and WEDGE a sandboxed job with no
  # human to answer (the exact failure that sandbox-blocked Sol). `--ignore-user-config` drops that
  # surface; per `codex exec --help` auth still uses CODEX_HOME, so your ChatGPT-sub login (Sol/Terra/
  # Luna) keeps working. Verified live: luna answers PONG with the flag on. Escape hatch: set
  # OSRC_CODEX_USER_CONFIG=1 to deliberately ride your full live config (e.g. to reuse an MCP server).
  local iso=(); [ "${OSRC_CODEX_USER_CONFIG:-0}" = "1" ] || iso=(--ignore-user-config)
  local rc=0
  codex exec --skip-git-repo-check ${iso[@]+"${iso[@]}"} ${cmh[@]+"${cmh[@]}"} ${eff[@]+"${eff[@]}"} "${sflag[@]}" ${sfx[@]+"${sfx[@]}"} -m "$id" "$wrapped" || rc=$?
  record_ledger codex-native "$id" "$ttier" "$tier" "$task"
  # Honest receipt: no cash, but this DID spend your ChatGPT plan limits, quote the real numbers.
  if [ "${OSRC_STREAM:-0}" != "1" ]; then
    local ql; ql="$(_codex_quota_line 2>/dev/null)" && [ -n "$ql" ] && \
      printf '>>> [receipt] no cash charged, ran on your ChatGPT plan. %s\n' "$ql" >&2
  fi
  return "$rc"
}

# _cc_verify_model <requested-alias> <modelUsage-json-or-log> -> prints a verified/WARNING receipt to
# stderr from the REAL model in the run's `modelUsage`. This is the anti-lying guarantee: a native
# subagent's model can silently fall back to your default (Opus) with NO signal, but the claude CLI
# reports the model it actually used, so we can prove it and refuse to mislabel.
_cc_verify_model() {
  local want="$1" src="$2" actual
  actual="$(grep -oE '"modelUsage":[[:space:]]*\{[[:space:]]*"[^"]*"' "$src" 2>/dev/null | head -1 | sed -E 's/.*"([^"]*)"$/\1/')"
  [ -n "$actual" ] || { printf '%s' "$src" | grep -q "modelUsage" && actual="$(printf '%s' "$src" | grep -oE '"modelUsage":[[:space:]]*\{[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/')"; }
  [ -n "$actual" ] || return 0
  if printf '%s' "$actual" | grep -qiF "$want"; then
    printf '>>> [verified] this run actually executed on %s (requested %s).\n' "$actual" "$want" >&2
  else
    printf '>>> [WARNING] you requested %s but the run ACTUALLY executed on %s. Do NOT label the output as %s (that would be a fabricated model identity). Likely a silent model fallback, check that %s is available on your plan/region.\n' "$want" "$actual" "$want" "$want" >&2
  fi
}

delegate_ccnative() {
  local tier="$1"
  [ "${#REST[@]}" -gt 0 ] || die "no task prompt given"
  local task="${REST[*]}" id="$RESOLVED_ID"
  have claude || die "claude CLI not on PATH (needed for the claude-native lane)"
  local mode posture
  case "$tier" in
    auto)         mode="default";           posture="READ-ONLY (headless denies tool exec)" ;;
    accept-edits) mode="acceptEdits";        posture="MUTATING (auto-accepts file edits)" ;;
    autonomous)   die "claude-native lane has NO OS sandbox; 'research' is unsafe here. Use --provider codex/devin for sandboxed exec, or 'yolo'." ;;
    dangerous)    mode="bypassPermissions";  posture="DANGER (bypasses ALL permission checks, no sandbox)" ;;
    *) die "bad tier: $tier" ;;
  esac
  # `--bare` gives a clean minimal run BUT forces ANTHROPIC_API_KEY / apiKeyHelper auth and disables
  # OAuth. Subscription (OAuth) users have no API key, so --bare there fails with "Not logged in". Use
  # --bare only when a key is present; otherwise drop it so the OAuth login works (context then loads).
  # ISOLATION (I1, claude harness parity): the OAuth path used to load the user's FULL live MCP surface
  # (project-scoped servers in ~/.claude.json), which can wedge a headless run on interactive OAuth.
  # build_mcp_flags_cc now emits --strict-mcp-config --mcp-config <empty> by DEFAULT so NO user MCP
  # servers load (auth survives; verified live). --with mcp=a,b opts specific servers in;
  # OSRC_CLAUDE_USER_CONFIG=1 is the escape hatch back to the full live surface. OUTSOURCERER_LOADED=1
  # keeps the strict-MCP isolation (it loads CLAUDE.md/skills, NOT MCP — MCP still needs --with mcp=).
  local bare=() load_note="OAuth login, MCP ISOLATED (strict-empty; --with mcp= / OSRC_CLAUDE_USER_CONFIG=1 to load)"
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then bare=(--bare); load_note="clean (--bare, API key auth, no MCP surface)";
  elif [ "${OUTSOURCERER_LOADED:-0}" = "1" ]; then load_note="LOADED, full CLAUDE.md + skills (MCP still isolated; --with mcp= / OSRC_CLAUDE_USER_CONFIG=1 to load)"; fi
  local ttier wrapped; ttier="$(resolve_tier "$id" "${TTIER:-}")"; wrapped="$(_build_prompt "$id" "$task" "${TTIER:-}")"
  # Inside Claude Code a native subagent (Agent tool) can also run a Claude model IN-session, BUT its
  # per-invocation model can SILENTLY fall back to your default (usually Opus) with NO way to verify.
  # This lane instead runs a fresh, ENV-CLEANED `claude -p --model $id` and VERIFIES the model actually
  # used, so it can never mislabel an Opus run as $id. Prefer it when you need a proven, independent run.
  [ -n "${CLAUDECODE:-}" ] && printf '>>> [note] running a VERIFIED, independent %s via the CLI. (An in-session Agent subagent with model=%s is the alternative, but it cannot prove which model ran.)\n' "$id" "$id" >&2
  _tier_banner "claude-native" "$id" "$ttier" "$posture, draws your Claude subscription limits | env: $load_note"
  build_mcp_flags_cc || die "isolation setup failed (cannot create strict-empty MCP config; aborting to avoid inheriting live MCP — set OSRC_CLAUDE_USER_CONFIG=1 to override)"
  # SELF-HEAL: strip the nested Claude Code session env so a `claude -p` launched from INSIDE Claude
  # Code authenticates cleanly (inherited CLAUDE_CODE_* vars make the child think it is "not logged
  # in", which is the failure users hit). Verified: with these unset, headless claude runs normally.
  local clean=(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_EXECPATH)
  if [ -n "$EFFORT" ]; then local think; think="$(_effort_thinking_tokens "$EFFORT")"; [ -n "$think" ] && { clean+=("MAX_THINKING_TOKENS=$think"); printf '>>> [effort] reasoning=%s (native: MAX_THINKING_TOKENS=%s)\n' "$EFFORT" "$think" >&2; }; fi
  local rc=0
  # Same coding-toolset grant as the cc lane so a headless mutating native run does not wedge on a
  # Bash permission prompt. auto stays read-only; mutating verbs get Bash. Terminated by --permission-mode.
  local tools=()
  if [ -n "${OSRC_ALLOWED_TOOLS:-}" ]; then read -ra _at <<< "$OSRC_ALLOWED_TOOLS"; tools=(--allowedTools "${_at[@]}")
  else case "$tier" in
    auto)                   tools=(--allowedTools Read Grep Glob) ;;
    accept-edits|dangerous) tools=(--allowedTools Read Edit Write Bash Grep Glob) ;;
  esac; fi
  local emode; emode="$(_perm_escalate "$mode" "$wrapped")"; [ "$emode" = REFUSE ] && die "$_perm_refuse_msg"
  if [ "${OSRC_STREAM:-0}" = "1" ]; then
    # bg/stream path: stream-json carries modelUsage (verify from the captured out.log downstream).
    "${clean[@]}" claude -p ${bare[@]+"${bare[@]}"} --verbose --output-format stream-json ${CC_MCP_FLAGS[@]+"${CC_MCP_FLAGS[@]}"} --model "$id" ${tools[@]+"${tools[@]}"} --permission-mode "$emode" "$wrapped" || rc=$?
    record_ledger claude-native "$id" "$ttier" "$tier" "$task"
  else
    # foreground: capture JSON, print the result text, then VERIFY the real model from modelUsage.
    mkdir -p "$OSRC_HOME"; local tmpj="$OSRC_HOME/.ccnative.$$.json"
    local old_umask; old_umask="$(umask)"; umask 077
    "${clean[@]}" claude -p ${bare[@]+"${bare[@]}"} --output-format json ${CC_MCP_FLAGS[@]+"${CC_MCP_FLAGS[@]}"} --model "$id" ${tools[@]+"${tools[@]}"} --permission-mode "$emode" "$wrapped" > "$tmpj" 2>/dev/null || rc=$?
    record_ledger claude-native "$id" "$ttier" "$tier" "$task"
    if [ "$rc" -eq 0 ] && have jq && [ -s "$tmpj" ]; then jq -r '.result // empty' "$tmpj" 2>/dev/null; else cat "$tmpj" 2>/dev/null; fi
    _cc_verify_model "$id" "$tmpj"
    chmod 600 "$tmpj" 2>/dev/null || true
    rm -f "$tmpj"
    umask "$old_umask"
  fi
  if [ "$rc" -ne 0 ]; then
    printf '>>> [hint] claude-native exited %s. If it still reports "Not logged in", run `claude` once and /login (headless auth is separate from interactive Claude Code).\n' "$rc" >&2
  fi
  return "$rc"
}

# _agy_model_token <gemini-cli/api id> -> the token the Antigravity `agy` CLI accepts. agy exposes
# its own curated (keyless) model set (see `agy models`); it has no flash-lite and uses non-preview
# ids. agy is lenient (falls back to its default on an unknown token), so this is best-effort.
_agy_model_token() {
  case "$1" in
    *pro*)   echo "gemini-3.1-pro" ;;
    *flash*) echo "gemini-3.5-flash" ;;   # covers flash + flash-lite (agy has no lite tier)
    *)       echo "$1" ;;
  esac
}

# _agy_effort <agy-model-token> <requested-effort> -> an effort level that model actually accepts.
# agy REQUIRES --effort for these models and rejects the run outright without it
# ("invalid model selection (--model X --effort \"\"): requires --effort"), and the accepted set is
# per-model: pro offers low|high with NO medium, flash offers low|medium|high. An unsupported level is
# rounded UP rather than down, because silently giving less thinking than asked for is the failure the
# caller cannot see; the clamp is announced.
_agy_effort() {
  local tok="$1" want="${2:-medium}" out
  case "$want" in low|medium|high) ;; *) want=medium ;; esac
  case "$tok" in
    *pro*)   case "$want" in medium) out=high ;; *) out="$want" ;; esac ;;
    *flash*) out="$want" ;;
    *)       out="$want" ;;
  esac
  [ "$out" != "$want" ] && printf '>>> [effort] %s has no "%s" level (accepts low|high) — using "%s" rather than quietly giving you less thinking.\n' "$tok" "$want" "$out" >&2
  printf '%s' "$out"
}

# delegate_gmnative <tier>, Gemini text/agentic lane. TWO vehicles:
#   PRIMARY  agy (Antigravity CLI), KEYLESS, rides the user's Antigravity/Google app login.
#   FALLBACK gemini CLI (gemini-cli) + GEMINI_API_KEY (single-key extraction, _gm_load_key).
# Vehicle picked by OSRC_GEMINI_VEHICLE (agy|gemini) if set, else agy-if-present, else gemini.
delegate_gmnative() {
  local tier="$1"
  [ "${#REST[@]}" -gt 0 ] || die "no task prompt given"
  local task="${REST[*]}" id="$RESOLVED_ID"
  local vehicle="${OSRC_GEMINI_VEHICLE:-}"
  if [ -z "$vehicle" ]; then
    if have agy; then vehicle=agy; elif have gemini; then vehicle=gemini; else
      die "Gemini lane needs a CLI. PRIMARY (keyless): install Antigravity CLI -> curl -fsSL https://antigravity.google/cli/install.sh -o agy-install.sh (inspect it, then run: bash agy-install.sh)  (then open Antigravity / sign in once so 'agy' inherits your login). FALLBACK (API key): npm install -g @google/gemini-cli  + add GEMINI_API_KEY to ~/.env (https://aistudio.google.com/apikey)."
    fi
  fi
  local ttier wrapped; ttier="$(resolve_tier "$id" "${TTIER:-}")"; wrapped="$(_build_prompt "$id" "$task" "${TTIER:-}")"
  # Effort is NATIVE on agy (it takes --effort and refuses to run without one for these models) and
  # ADVISORY on gemini-cli, which still has no knob. Injecting the prompt directive on the agy path too
  # would double-signal, so it is only added for the gemini-cli vehicle.
  if [ -n "$EFFORT" ] && [ "$vehicle" != "agy" ]; then
    wrapped="Reasoning effort: $EFFORT. Match your depth of analysis and thinking to this level.

$wrapped"
    printf '>>> [effort] reasoning=%s (ADVISORY on the gemini lane: injected as a prompt directive; no native knob)\n' "$EFFORT" >&2
  fi
  local rc=0

  if [ "$vehicle" = "agy" ]; then
    have agy || die "OSRC_GEMINI_VEHICLE=agy but 'agy' not on PATH. Install: curl -fsSL https://antigravity.google/cli/install.sh -o agy-install.sh (inspect it, then run: bash agy-install.sh)"
    local atok aflag posture; atok="$(_agy_model_token "$id")"
    case "$tier" in
      auto)                    aflag=();                                          posture="READ-ONLY (headless -p; no auto-approve)" ;;
      accept-edits|autonomous) aflag=(--sandbox --dangerously-skip-permissions);  posture="SANDBOXED autonomy (--sandbox terminal restrictions + auto-approve)" ;;
      dangerous)               aflag=(--dangerously-skip-permissions);            posture="DANGER (auto-approves ALL tools, no sandbox)" ;;
      *) die "bad tier: $tier" ;;
    esac
    _tier_banner "antigravity-agy (keyless)" "$atok" "$ttier" "$posture, rides your Antigravity/Google login, NO API key"
    # agy has no --output-format json; the supervisor watches plain-stdout byte growth and the bg
    # path derives last.txt from out.log, so no stream flags are needed. --print-timeout caps waits.
    local aeff; aeff="$(_agy_effort "$atok" "${EFFORT:-medium}")"
    # Capture stderr so a "timeout waiting for response" can be TRANSLATED. agy reports a dead lane the
    # same way it reports a slow one, and at the default 5m print-timeout that costs five minutes per
    # attempt to learn nothing. The distinguishing fact is that agy's own auth/model resolution
    # succeeded and only the generation never returned, which points at the backend, not the request.
    local _aerr; _aerr="$(mktemp -t osrc-agy)"
    agy -p "$wrapped" ${aflag[@]+"${aflag[@]}"} --model "$atok" --effort "$aeff" \
        --print-timeout "${OSRC_AGY_PRINT_TIMEOUT:-5m}" 2> >(tee "$_aerr" >&2) || rc=$?
    if grep -qi 'timeout waiting for response' "$_aerr" 2>/dev/null; then
      printf '>>> [gemini] the keyless Antigravity lane accepted the request and never answered (model and login both resolved, so this is the Antigravity backend, not your prompt).\n' >&2
      printf '>>>   check      : %s doctor  — it probes this lane for real rather than assuming the installed CLI works.\n' "$0" >&2
      printf '>>>   fall back  : OSRC_GEMINI_VEHICLE=gemini (needs GEMINI_API_KEY in ~/.env), or use a different lane entirely (-m glm on Devin is free).\n' >&2
      printf '>>>   tune       : OSRC_AGY_PRINT_TIMEOUT=%s was the wait; lower it to fail faster while this lane is unhealthy.\n' "${OSRC_AGY_PRINT_TIMEOUT:-5m}" >&2
      rc="${rc:-124}"; [ "$rc" = "0" ] && rc=124
    fi
    rm -f "$_aerr" 2>/dev/null || true
    record_ledger antigravity-agy "$atok" "$ttier" "$tier" "$task"
    return "$rc"
  fi

  # FALLBACK: gemini CLI + API key.
  have gemini || die "OSRC_GEMINI_VEHICLE=gemini but 'gemini' CLI not on PATH. Install: npm install -g @google/gemini-cli  (https://geminicli.com/docs/get-started/installation/). Then set GEMINI_API_KEY in ~/.env."
  _gm_load_key
  local gflag posture
  case "$tier" in
    auto)         gflag=(--approval-mode default);            posture="READ-ONLY (headless denies tool-exec approval)" ;;
    accept-edits) gflag=(--sandbox --approval-mode auto_edit); posture="WORKSPACE-WRITE + OS sandbox (macOS Seatbelt / Docker), auto-approves edits" ;;
    autonomous)   gflag=(--sandbox --approval-mode auto_edit); posture="WORKSPACE-WRITE + OS sandbox (macOS Seatbelt / Docker), can exec tools" ;;
    dangerous)    gflag=(--approval-mode yolo);                posture="DANGER (auto-approves ALL tools; sandboxed only if GEMINI_SANDBOX is set)" ;;
    *) die "bad tier: $tier" ;;
  esac
  _tier_banner "gemini-cli (api key)" "$id" "$ttier" "$posture, draws your GEMINI_API_KEY quota"
  local ofmt=(--output-format text); [ "${OSRC_STREAM:-0}" = "1" ] && ofmt=(--output-format json)
  # ISOLATION (I1, gemini harness parity): gemini-cli loads ~/.gemini/settings.json mcpServers
  # unconditionally; a headless run can wedge on an interactive-auth MCP server. --allowed-mcp-server-names
  # is an allowlist (array); a sentinel matching NO configured server (__none__) means ZERO MCP servers
  # load. Escape hatch: OSRC_GEMINI_USER_MCP=1 drops the flag so the full live surface loads.
  local gmcp=()
  [ "${OSRC_GEMINI_USER_MCP:-0}" = "1" ] || gmcp=(--allowed-mcp-server-names __none__)
  gemini -p "$wrapped" "${gflag[@]}" "${gmcp[@]+"${gmcp[@]}"}" "${ofmt[@]}" --model "$id" || rc=$?
  record_ledger gemini "$id" "$ttier" "$tier" "$task"
  return "$rc"
}

# cmd_image_codex <prompt> <out> <tier>, drives `codex exec` against its built-in gpt-image-2 tool:
# KEYLESS, billed to the user's Codex/ChatGPT subscription, no GEMINI/OPENROUTER key. Invocation is
# mirrored verbatim from ~/.claude/skills/illo/scripts/illo.py's codex_exec_generate() (stdin prompt
# + save-to-path instruction, exec flags, freshest-file-in-generated_images/ fallback), read from
# illo's own source, not re-derived from docs. NOTE: this exact `codex exec ... --enable artifact -`
# invocation is verified against illo's source (which documents it as verified live on Codex CLI
# 0.141/0.144) but is NOT independently re-verified against a live `codex` binary; treat as
# unverified until confirmed.
# =============================================================================
# CLAUDEX LANE (--provider claudex): GPT-5.6 Sol/Terra/Luna INSIDE the Claude Code harness,
# via a locally-running CLIProxyAPI the USER already installed and logged into. The community
# "claudex" pattern (Theo's recipe): Claude Code's UX + subagents driving a ChatGPT-sub model.
# DETECT-ONLY by design: this lane never installs or launches the proxy — its reliance on internal,
# non-guaranteed upstream endpoints means installing it is the USER's informed call, not ours.
# Facts verified against the proxy docs: default port 8317, Anthropic-compatible /v1/messages,
# auth token must match the proxy's own api-keys list, model registry auto-routes gpt-5.6-* to
# the Codex OAuth session, health probe = authenticated GET /v1/models (no /health endpoint).
# =============================================================================
_claudex_url() { printf '%s' "${OSRC_CLAUDEX_URL:-http://127.0.0.1:8317}"; }
_claudex_token() {
  [ -n "${OSRC_CLAUDEX_TOKEN:-}" ] && { printf '%s' "$OSRC_CLAUDEX_TOKEN"; return 0; }
  # first api-key from the proxy's own config (yaml list under "api-keys:").
  local cfg="${OSRC_CLAUDEX_CONFIG:-$HOME/.cli-proxy-api/config.yaml}"
  [ -f "$cfg" ] && awk '/^api-keys:/{f=1;next} f&&/^[[:space:]]*-/{sub(/^[[:space:]]*-[[:space:]]*"?/,"");sub(/"?[[:space:]]*$/,"");print;exit} f&&/^[^[:space:]]/{exit}' "$cfg" 2>/dev/null
}
_claudex_up() {   # is a CLIProxyAPI answering with our token? (authenticated /v1/models probe)
  local url tok hdr; url="$(_claudex_url)"; tok="$(_claudex_token)"
  [ -n "$tok" ] || return 1
  mkdir -p "$OSRC_HOME" 2>/dev/null
  hdr="$OSRC_HOME/.hdr.claudex.$$"; { umask 077; printf 'Authorization: Bearer %s\n' "$tok" > "$hdr"; } 2>/dev/null || return 1
  curl -fsS -m 4 -H @"$hdr" "$url/v1/models" >/dev/null 2>&1; local rc=$?
  rm -f "$hdr" 2>/dev/null
  return "$rc"
}

delegate_claudex() {
  local tier="$1"
  [ "${#REST[@]}" -gt 0 ] || die "no task prompt given"
  local task="${REST[*]}" id="$RESOLVED_ID"
  have claude || die "claudex lane needs the claude CLI on PATH."
  _claudex_up || die "claudex lane: no CLIProxyAPI answering at $(_claudex_url) (or no api-key found). This lane rides a proxy YOU install and log into: https://github.com/router-for-me/CLIProxyAPI (then cli-proxy-api --codex-login). Set OSRC_CLAUDEX_URL / OSRC_CLAUDEX_TOKEN if yours is elsewhere. Meanwhile -m $id runs fine on the codex-native lane (drop --provider)."
  local mode posture
  case "$tier" in
    auto)         mode="default";          posture="READ-ONLY (headless denies tool exec)" ;;
    accept-edits) mode="acceptEdits";       posture="MUTATING (auto-accepts file edits)" ;;
    autonomous)   die "claudex lane has NO OS sandbox (claude harness); use --provider codex/devin for sandboxed exec, or 'yolo'." ;;
    dangerous)    mode="bypassPermissions"; posture="DANGER (bypasses ALL permission checks, no sandbox)" ;;
    *) die "bad tier: $tier" ;;
  esac
  local ttier wrapped; ttier="$(resolve_tier "$id" "${TTIER:-}")"; wrapped="$(_build_prompt "$id" "$task" "${TTIER:-}")"
  _tier_banner "claudex (Claude harness -> CLIProxyAPI)" "$id" "$ttier" "$posture, bills your ChatGPT plan through YOUR local proxy"
  # Honest one-time-per-run caveat: unofficial bridge, upstream endpoints are internal/unstable,
  # heavy use without rate limiting has triggered upstream account limits for some users.
  printf '>>> [claudex] UNOFFICIAL community bridge: Claude Code harness + your ChatGPT-sub model via local CLIProxyAPI. Upstream endpoint is internal/not guaranteed; heavy unthrottled use risks provider-side limits. Official alternative for Codex-in-Claude: the openai/codex-plugin-cc plugin.\n' >&2
  build_mcp_flags_cc || die "isolation setup failed (cannot create strict-empty MCP config)"
  local clean=(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_EXECPATH -u ANTHROPIC_API_KEY
               "ANTHROPIC_BASE_URL=$(_claudex_url)" "ANTHROPIC_AUTH_TOKEN=$(_claudex_token)")
  # Effort: the model behind the proxy is a GPT reasoning model; Claude Code's effort plumbing is
  # enabled and the level is ALSO injected as a prompt directive (never silently dropped).
  if [ -n "$EFFORT" ]; then
    clean+=("CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1")
    wrapped="Reasoning effort: $EFFORT. Match your depth of analysis and thinking to this level.

$wrapped"
    printf '>>> [effort] reasoning=%s (claudex: CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1 + prompt directive)\n' "$EFFORT" >&2
  fi
  local tools=()
  if [ -n "${OSRC_ALLOWED_TOOLS:-}" ]; then read -ra _at <<< "$OSRC_ALLOWED_TOOLS"; tools=(--allowedTools "${_at[@]}")
  else case "$tier" in
    auto)                   tools=(--allowedTools Read Grep Glob) ;;
    accept-edits|dangerous) tools=(--allowedTools Read Edit Write Bash Grep Glob) ;;
  esac; fi
  local emode; emode="$(_perm_escalate "$mode" "$wrapped")"; [ "$emode" = REFUSE ] && die "$_perm_refuse_msg"
  local rc=0
  if [ "${OSRC_STREAM:-0}" = "1" ]; then
    "${clean[@]}" claude -p --verbose --output-format stream-json ${CC_MCP_FLAGS[@]+"${CC_MCP_FLAGS[@]}"} --model "$id" ${tools[@]+"${tools[@]}"} --permission-mode "$emode" "$wrapped" || rc=$?
    record_ledger claudex "$id" "$ttier" "$tier" "$task"
  else
    mkdir -p "$OSRC_HOME"; local tmpj="$OSRC_HOME/.claudex.$$.json"
    local old_umask; old_umask="$(umask)"; umask 077
    "${clean[@]}" claude -p --output-format json ${CC_MCP_FLAGS[@]+"${CC_MCP_FLAGS[@]}"} --model "$id" ${tools[@]+"${tools[@]}"} --permission-mode "$emode" "$wrapped" > "$tmpj" 2>/dev/null || rc=$?
    record_ledger claudex "$id" "$ttier" "$tier" "$task"
    if [ "$rc" -eq 0 ] && have jq && [ -s "$tmpj" ]; then jq -r '.result // empty' "$tmpj" 2>/dev/null; else cat "$tmpj" 2>/dev/null; fi
    _cc_verify_model "$id" "$tmpj"
    rm -f "$tmpj"; umask "$old_umask"
  fi
  [ "$rc" -ne 0 ] && printf '>>> [hint] claudex exited %s. Check the proxy is up (curl %s/v1/models with your api-key) and that cli-proxy-api --codex-login succeeded.\n' "$rc" "$(_claudex_url)" >&2
  printf '>>> [receipt] no cash charged, ran on your ChatGPT plan via your local CLIProxyAPI (Claude harness UX, zero Claude-sub spend).\n' >&2
  return "$rc"
}

# =============================================================================
# DROID / CURSOR ENGINE LANES (provider-selected: --provider droid | cursor).
# "The skill works with YOUR tools, you don't adapt to its": these lanes drive the user's own
# agent CLI, with whatever models THEY configured there (incl. BYOK/custom models -- droid:
# ~/.factory/settings.json customModels; cursor: the user's Cursor account models). A -m value is
# passed VERBATIM to the engine (never re-routed by our alias table); no -m = the engine's default.
# Both are cloud lanes (the engine calls its vendor + the model API) -> full cloud gate applies.
# Billing: droid = your Factory plan/BYOK keys; cursor = your Cursor subscription credits.
# =============================================================================

# _droid_effort <ours> -> droid exec -r value (off|none|low|medium|high). Ours: minimal..max.
_droid_effort() {
  case "$1" in minimal) echo "none" ;; low) echo "low" ;; medium) echo "medium" ;;
    high|xhigh|max) echo "high" ;; *) echo "" ;; esac
}

delegate_droid() {
  local tier="$1"
  [ "${#REST[@]}" -gt 0 ] || die "no task prompt given"
  local task="${REST[*]}" id="${MODEL:-}"
  have droid || die "droid CLI not on PATH (Factory Droid lane). Install: https://docs.factory.ai/cli  (macOS/Linux: curl -fsSL https://app.factory.ai/cli -o droid-install.sh, inspect, run; Windows: native PowerShell installer). Then run 'droid' once to log in."
  # droid exec autonomy: default = read-only; --auto low (read-only + safe cmds) / medium (edits +
  # safe cmds) / high (full auto). --skip-permissions-unsafe is sandbox-only and never used here.
  local aflag=() posture
  case "$tier" in
    auto)         aflag=();              posture="READ-ONLY (droid exec default: no edits, no unsafe cmds)" ;;
    accept-edits) aflag=(--auto medium); posture="MUTATING (--auto medium: edits + safe commands)" ;;
    autonomous)   aflag=(--auto medium); posture="MUTATING (--auto medium; droid has no separate OS-sandbox exec mode)" ;;
    dangerous)    aflag=(--auto high);   posture="DANGER (--auto high: full autonomy incl. riskier commands)" ;;
    *) die "bad tier: $tier" ;;
  esac
  local mflag=()
  if [ "${MODEL_EXPLICIT:-0}" = "1" ] && [ -n "$id" ]; then _validate_model_token "$id"; mflag=(-m "$id"); else id="(droid default/configured)"; fi
  local eff=()
  if [ -n "$EFFORT" ]; then local de; de="$(_droid_effort "$EFFORT")"
    [ -n "$de" ] && { eff=(-r "$de"); printf '>>> [effort] reasoning=%s (native: droid exec -r %s)\n' "$EFFORT" "$de" >&2; }; fi
  local ttier; ttier="$(resolve_tier "${MODEL:-}" "${TTIER:-}")" || ttier="capable"
  local wrapped; wrapped="$(_build_prompt "${MODEL:-droid}" "$task" "$ttier")"
  _tier_banner "droid (Factory)" "$id" "$ttier" "$posture, bills your Factory plan / your own BYOK keys"
  local rc=0
  droid exec ${mflag[@]+"${mflag[@]}"} ${aflag[@]+"${aflag[@]}"} ${eff[@]+"${eff[@]}"} -o text "$wrapped" || rc=$?
  record_ledger droid "${MODEL:-droid-default}" "$ttier" "$tier" "$task"
  printf '>>> [receipt] ran on YOUR droid setup (Factory plan or the BYOK keys configured in ~/.factory/settings.json), no Claude tokens spent.\n' >&2
  return "$rc"
}

delegate_cursor() {
  local tier="$1"
  [ "${#REST[@]}" -gt 0 ] || die "no task prompt given"
  local task="${REST[*]}" id="${MODEL:-}"
  local cur=""
  if have cursor-agent; then cur="cursor-agent"; elif have agent && agent --help 2>/dev/null | grep -qi cursor; then cur="agent"; fi
  [ -n "$cur" ] || die "cursor-agent CLI not on PATH (Cursor lane). Install: macOS/Linux: curl https://cursor.com/install -fsS | bash after inspecting; Windows (native, no WSL): irm 'https://cursor.com/install?win32=true' | iex. Then 'cursor-agent login' once (or set CURSOR_API_KEY)."
  # cursor-agent autonomy: default headless = propose-only; -f/--force = apply edits/commands.
  # --trust skips the workspace-trust prompt that would wedge a headless run.
  local fflag=() posture
  case "$tier" in
    auto)         fflag=();                            posture="READ-ONLY-ish (no --force: edits are not auto-applied)" ;;
    accept-edits) fflag=(--force);                     posture="MUTATING (--force: applies edits/commands without per-step prompts)" ;;
    autonomous)   fflag=(--force --sandbox enabled);   posture="MUTATING inside Cursor's sandbox (--force --sandbox enabled)" ;;
    dangerous)    fflag=(--force --sandbox disabled);  posture="DANGER (--force, sandbox disabled)" ;;
    *) die "bad tier: $tier" ;;
  esac
  local mflag=()
  if [ "${MODEL_EXPLICIT:-0}" = "1" ] && [ -n "$id" ]; then _validate_model_token "$id"; mflag=(--model "$id"); else id="(cursor default/configured)"; fi
  [ -n "$EFFORT" ] && printf '>>> [effort] reasoning=%s (advisory only: cursor-agent has no effort flag; folded into the prompt)\n' "$EFFORT" >&2
  local ttier; ttier="$(resolve_tier "${MODEL:-}" "${TTIER:-}")" || ttier="capable"
  local wrapped; wrapped="$(_build_prompt "${MODEL:-cursor}" "$task" "$ttier")"
  _tier_banner "cursor-agent" "$id" "$ttier" "$posture, bills your Cursor subscription credits"
  local rc=0
  "$cur" -p "$wrapped" ${mflag[@]+"${mflag[@]}"} ${fflag[@]+"${fflag[@]}"} --trust --output-format text || rc=$?
  record_ledger cursor "${MODEL:-cursor-default}" "$ttier" "$tier" "$task"
  printf '>>> [receipt] no cash charged here, ran on your Cursor subscription credits, no Claude tokens spent.\n' >&2
  return "$rc"
}

cmd_image_codex() {
  local prompt="$1" out="$2" ttier="$3"
  have codex || die "codex CLI not on PATH (needed for the codex/gpt-image backend)"
  local rundir; rundir="$(dirname "$out")"
  mkdir -p "$rundir"
  echo ">>> [codex-image] gpt-image-2 (KEYLESS, your Codex/ChatGPT subscription)  tier=$ttier  -> $out" >&2
  rm -f "$out"
  local marker="$rundir/.osrc_image_marker.$$"
  : > "$marker"
  local stdin_prompt
  stdin_prompt="$(printf '%s\n\nUse your built-in image generation tool to create the image and write it to %s, overwriting any existing file.' "$prompt" "$out")"
  # SELF-HEAL: disable code_mode_host when its binary is missing (else tool calls can hang, see delegate_cxnative).
  local _cmh=(); _codex_code_mode_host || _cmh=(-c features.code_mode_host=false)
  # ISOLATION (I1): don't inherit the user's live ~/.codex MCP surface for a headless image job
  # (auth survives --ignore-user-config; escape hatch OSRC_CODEX_USER_CONFIG=1).
  local _iso=(); [ "${OSRC_CODEX_USER_CONFIG:-0}" = "1" ] || _iso=(--ignore-user-config)
  local codex_cmd=(codex exec --cd "$rundir" --sandbox workspace-write --skip-git-repo-check ${_iso[@]+"${_iso[@]}"} ${_cmh[@]+"${_cmh[@]}"} --enable artifact -)
  local out_log rc=0
  if have timeout; then
    out_log="$(printf '%s' "$stdin_prompt" | timeout 600 "${codex_cmd[@]}" 2>&1)" || rc=$?
  else
    out_log="$(printf '%s' "$stdin_prompt" | "${codex_cmd[@]}" 2>&1)" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$marker"
    die "codex exec exited $rc: $(printf '%s' "$out_log" | head -c 300)"
  fi
  if [ ! -s "$out" ]; then
    local codex_home="${CODEX_HOME:-$HOME/.codex}" gen latest=""
    gen="$codex_home/generated_images"
    if [ -d "$gen" ]; then
      latest="$(ls -t "$gen" 2>/dev/null | while IFS= read -r f; do
        [ "$gen/$f" -nt "$marker" ] && { printf '%s\n' "$gen/$f"; break; }
      done)"
    fi
    rm -f "$marker"
    { [ -n "$latest" ] && [ -f "$latest" ]; } || die "codex exec produced no retrievable image (check 'codex login' + the image_generation/artifact features via '$0 doctor'; raw tail: $(printf '%s' "$out_log" | tail -c 300))"
    cp "$latest" "$out" || die "failed to copy generated image from $latest to $out"
  else
    rm -f "$marker"
  fi
  record_ledger codex gpt-image-2 "$ttier" image "$prompt"
  echo "$out"
}

# cmd_image_gemini <id> <prompt> <out> <tier>, text-to-image via the Gemini generateContent REST
# API directly (nano-banana / gemini-2.5-flash-image by default). REQUIRES GEMINI_API_KEY: unlike
# the keyless agy text lane, image-to-file has no keyless path, agy's headless model list has no
# image model, and neither agy nor gemini-cli exposes a documented "write a PNG to disk" headless
# mode. So this Gemini feature needs the API key; hitting the REST endpoint directly (curl+jq, base64
# PNG out) is the verifiable path.
cmd_image_gemini() {
  local id="$1" prompt="$2" out="$3" ttier="$4"
  have curl || die "curl needed for the image lane"
  have jq   || die "jq needed for the image lane (brew install jq)"
  _gm_load_key
  echo ">>> [gemini-image] $id  tier=$ttier  -> $out" >&2
  local resp; resp="$(_curl_with_gemini_key "$GEMINI_API_KEY" -fsS -m "${OSRC_IMAGE_TIMEOUT:-180}" -X POST \
    "https://generativelanguage.googleapis.com/v1beta/models/$id:generateContent" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg p "$prompt" '{contents:[{parts:[{text:$p}]}]}')" 2>/dev/null)" \
    || die "gemini image API call failed (network / auth / model id?)"
  local b64; b64="$(printf '%s' "$resp" | jq -r '.candidates[0].content.parts[]? | select(.inlineData) | .inlineData.data' 2>/dev/null | head -1)"
  if [ -z "$b64" ] || [ "$b64" = "null" ]; then
    die "no image returned (check GEMINI_API_KEY / model id / prompt safety filters). Raw response (truncated): $(printf '%s' "$resp" | head -c 300)"
  fi
  printf '%s' "$b64" | base64 -d > "$out" 2>/dev/null || die "failed to decode/write image to $out"
  record_ledger gemini "$id" "$ttier" image "$prompt"
  echo "$out"
}

# cmd_image_openrouter <id> <prompt> <out> <tier>, OpenRouter image models (needs
# OPENROUTER_API_KEY). Response schema mirrored from illo.py's extract_image(): OpenRouter returns
# generated images on message.images[] as [{"type":"image_url","image_url":{"url":"data:image/...;
# base64,..."}}]. Falls back to downloading a plain http(s) URL if a model returns one instead.
cmd_image_openrouter() {
  local id="$1" prompt="$2" out="$3" ttier="$4"
  have curl || die "curl needed for the image lane"
  have jq   || die "jq needed for the image lane (brew install jq)"
  _or_load_key
  echo ">>> [openrouter-image] $id  tier=$ttier  -> $out" >&2
  local resp; resp="$(_curl_with_auth "$OPENROUTER_API_KEY" -fsS -m "${OSRC_IMAGE_TIMEOUT:-180}" -X POST "https://openrouter.ai/api/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg m "$id" --arg p "$prompt" '{model:$m,messages:[{role:"user",content:$p}],modalities:["image","text"]}')" 2>/dev/null)" \
    || die "OpenRouter image API call failed (network / auth / model id?)"
  local url; url="$(printf '%s' "$resp" | jq -r '.choices[0].message.images[0].image_url.url // empty' 2>/dev/null)"
  [ -n "$url" ] || die "no image returned from OpenRouter (check OPENROUTER_API_KEY / model id). Raw response (truncated): $(printf '%s' "$resp" | head -c 300)"
  case "$url" in
    data:*base64,*) printf '%s' "${url#*base64,}" | base64 -d > "$out" 2>/dev/null || die "failed to decode/write image to $out" ;;
    https://*)      curl -fsS -m "${OSRC_IMAGE_TIMEOUT:-180}" "$url" -o "$out" 2>/dev/null || die "failed to download image from $url" ;;
    http://*)       die "refusing to fetch non-HTTPS image URL from API response (SSRF risk): $(printf '%s' "$url" | head -c 100)" ;;
    *)               die "unrecognized image URL format from OpenRouter: $(printf '%s' "$url" | head -c 100)" ;;
  esac
  record_ledger openrouter "$id" "$ttier" image "$prompt"
  echo "$out"
}

# cmd_image [-m MODEL] "<prompt>" [out.png], text-to-image, backend AUTO-RESOLVED unless -m pins
# one explicitly. Preference order (never hardcode which is "installed", detect it):
#   1. codex gpt-image-2  , KEYLESS, rides the user's Codex/ChatGPT subscription. Preferred whenever
#      `codex` is installed + logged in + has the image_generation/artifact features.
#   2. nano-banana (gemini-2.5-flash-image), needs GEMINI_API_KEY/GOOGLE_API_KEY in ~/.env.
#   3. an OpenRouter image model, needs OPENROUTER_API_KEY in ~/.env.
# `doctor` reports which one resolves right now. `-m gpt-image`/`-m codex-image` forces codex; `-m
# nano-banana` (or any *flash-image* id) forces gemini; any other id forces OpenRouter.
cmd_image() {
  _consume_flags "$@"
  [ "${#REST[@]}" -gt 0 ] || die "image needs a prompt (e.g. image \"a red panda skateboarding, watercolor\" out.png)"
  local n="${#REST[@]}"
  local last="${REST[$((n-1))]}" out="" args=("${REST[@]}")
  case "$last" in
    *.png|*.jpg|*.jpeg|*.webp) out="$last"; args=("${REST[@]:0:$((n-1))}") ;;
  esac
  local prompt="${args[*]}"
  [ -n "$prompt" ] || die "image needs a text prompt (only an output path was given)"
  mkdir -p "$OSRC_HOME/images"
  [ -n "$out" ] || out="$OSRC_HOME/images/$(_new_job_id).png"

  local backend="" id=""
  if [ "$MODEL_EXPLICIT" = "1" ]; then
    local row; row="$(resolve_model_row "$MODEL")"
    if [ -n "$row" ]; then
      id="${row%%|*}"
      local lane; lane="${row#*|}"; lane="${lane%%|*}"
      case "$lane" in
        ci) backend="codex" ;;
        gi) backend="gemini" ;;
        *) die "'$MODEL' ($id) is not an image-generation model. Try: gpt-image (codex, keyless), nano-banana (gemini), or pass a raw OpenRouter image id." ;;
      esac
    else
      case "$MODEL" in
        gpt-image*|codex-image) backend="codex"; id="gpt-image-2" ;;
        *flash-image*|*nano-banana*) backend="gemini"; id="$MODEL" ;;
        *) backend="openrouter"; id="$MODEL" ;;
      esac
    fi
  else
    if _codex_image_available; then
      backend="codex"; id="gpt-image-2"
    elif [ -f "$HOME/.env" ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?(GEMINI_API_KEY|GOOGLE_API_KEY)=' "$HOME/.env" 2>/dev/null; then
      backend="gemini"; id="gemini-2.5-flash-image"
    elif [ -f "$HOME/.env" ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?OPENROUTER_API_KEY=' "$HOME/.env" 2>/dev/null; then
      backend="openrouter"; id="x-ai/grok-imagine-image-quality"
    else
      die "no image backend ready. Preferred: install codex + 'codex login' (keyless, uses your ChatGPT/Codex subscription). Or add GEMINI_API_KEY, or OPENROUTER_API_KEY, to ~/.env. Run '$0 doctor' to see what's missing."
    fi
  fi

  local ttier; ttier="$(resolve_tier "$id" "")"
  local _idisp; case "$backend" in codex) _idisp=cxnative ;; gemini) _idisp=gmnative ;; *) _idisp=codexor ;; esac
  _cloud_disclose "$_idisp" "$id" "$prompt"
  case "$backend" in
    codex)      cmd_image_codex "$prompt" "$out" "$ttier" ;;
    gemini)     cmd_image_gemini "$id" "$prompt" "$out" "$ttier" ;;
    openrouter) cmd_image_openrouter "$id" "$prompt" "$out" "$ttier" ;;
  esac
}

# =============================================================================
# reverse bridge (insourcerer): let a Codex session delegate INTO claude.
# =============================================================================
# Reverse bridge INTO droid / cursor: teach the HOST agent (Factory droid, Cursor CLI) to drive
# outsourcerer from ITS side — someone living in droid/cursor gets Devin/OpenRouter/Claude/Codex/
# local lanes + bg/fanout supervision without leaving their tool. Blocks are idempotent
# (marker-guarded, same OUTSOURCERER:INSOURCE marker as parity-codex).
_insource_block() {   # <host-label>
  cat <<EOF

<!-- OUTSOURCERER:INSOURCE (managed by outsourcerer parity, host: $1) -->
## Outsourcerer: delegate grunt work to cheaper/different engines
This machine has outsourcerer installed. From this $1 session you can delegate to Devin
(glm-5.2/swe-1.7, free-lane class), OpenRouter (glm/hy3/deepseek via --provider cc|codex),
a VERIFIED Claude model (run -m fable|opus|sonnet|haiku, Claude subscription), ChatGPT-sub
models (run -m sol|terra|luna), keyless Gemini (run -m gemini-flash), or local Ollama (\$0, private).
  $SCRIPT_PATH doctor                          # what's available right now (run this first)
  $SCRIPT_PATH run -m glm "<read-only task>"   # one-shot; edit/yolo for mutating work
  $SCRIPT_PATH bg run -m hy3 "<long task>"     # supervised background job -> status/result <id>
  $SCRIPT_PATH fanout --max 6 -m glm --verb run -- "t1" "t2"   # parallel multi-agent
First cloud delegation needs a one-time consent: $SCRIPT_PATH consent grant (remembered after).
Read only the final message; delegates end with OSRC::DONE <summary> (or OSRC::BLOCKED <reason>).
<!-- /OUTSOURCERER:INSOURCE -->
EOF
}

parity_droid() {
  have droid || printf '>>> note: droid CLI not on PATH yet; writing the bridge anyway so it works the moment droid is installed.\n' >&2
  local fhome="${FACTORY_HOME:-$HOME/.factory}" agents; agents="$fhome/AGENTS.md"
  mkdir -p "$fhome"
  if [ -f "$agents" ] && grep -q 'OUTSOURCERER:INSOURCE' "$agents" 2>/dev/null; then
    echo "parity-droid: insource block already present in $agents"; return 0
  fi
  _insource_block "Factory droid" >> "$agents" || die "parity-droid: cannot write $agents"
  echo "parity-droid: appended insource block to $agents (droid loads ~/.factory/AGENTS.md globally)"
}

parity_cursor() {
  local agents="$PWD/AGENTS.md"
  if [ -f "$agents" ] && grep -q 'OUTSOURCERER:INSOURCE' "$agents" 2>/dev/null; then
    echo "parity-cursor: insource block already present in $agents"; return 0
  fi
  _insource_block "Cursor" >> "$agents" || die "parity-cursor: cannot write $agents"
  echo "parity-cursor: appended insource block to $agents (cursor-agent auto-loads repo-root AGENTS.md; repo-level by design — commit or gitignore as you prefer)"
}

parity_codex() {
  local codex_home="${CODEX_HOME:-$HOME/.codex}" agents
  agents="$codex_home/AGENTS.md"
  mkdir -p "$codex_home"
  if [ -f "$agents" ] && grep -q 'OUTSOURCERER:INSOURCE' "$agents" 2>/dev/null; then
    echo "parity-codex: insource block already present in $agents"; return 0
  fi
  cat >> "$agents" <<EOF

<!-- OUTSOURCERER:INSOURCE (managed by outsourcerer parity-codex) -->
## Insourcing to Claude (outsourcerer reverse bridge)
For turns needing Claude-grade judgment, delegate INTO Claude from this Codex session:
  $SCRIPT_PATH run -m fable "<task>"     # Claude-native (uses your Claude subscription)
  $SCRIPT_PATH --provider cc run "<task>"  # OpenRouter cc lane (a cheap Claude-compatible model)
Read only the final message; the delegate signals liveness with OSRC::PROGRESS lines and ends
with OSRC::DONE <summary> (or OSRC::BLOCKED <reason>) as its final line.
<!-- /OUTSOURCERER:INSOURCE -->
EOF
  echo "parity-codex: appended insource block to $agents"
}

# delegate_cc <perm-tier> [-m MODEL] "<task>" , Claude Code -> OpenRouter (inherits your CC skills/MCP)
# _protected_scope <prompt> -> 0 if the job's CWD or an explicit path in the prompt is a harness-guarded
# config dir. Headless `claude -p` cannot auto-approve edits to these (Claude Code treats its config dir as
# a "sensitive file" needing an interactive prompt), so acceptEdits silently wedges. Extend via OSRC_PROTECTED_PATHS.
_protected_scope() {
  local prompt="${1:-}" d _ifs_save="$IFS"
  # Colon-separated like PATH, so paths with spaces work correctly.
  IFS=':'
  for d in ${OSRC_PROTECTED_PATHS:-"$HOME/.claude:$HOME/.codex:$HOME/.config"}; do
    case "$PWD/" in "$d"/*) IFS="$_ifs_save"; return 0 ;; esac
    case "$prompt" in *"$d"*) IFS="$_ifs_save"; return 0 ;; esac
  done
  IFS="$_ifs_save"
  case "$prompt" in *'~/.claude'*|*'~/.codex'*) return 0 ;; esac
  return 1
}

# _perm_escalate <mode> <prompt> -> echoes the effective claude -p permission mode. On a mutating
# (acceptEdits) run whose target is a harness-protected path, the DEFAULT is to keep the caller's
# mode (acceptEdits) so the run hits the permission wall honestly, not via a silent bypass.
# Escalation to bypassPermissions ONLY happens with an explicit per-run ack: --allow-downgrade or
# OSRC_ALLOW_DOWNGRADE=1. OSRC_NO_BYPASS=1 refuses instead (fail-loud). Shared by ALL claude -p
# lanes (cc / claude-native / local-agentic shim) so the bug is fixed as a CLASS, not per-lane.
# Non-mutating / non-protected runs are unchanged.
_perm_escalate() {
  local mode="$1" prompt="${2:-}"
  if [ "$mode" = "acceptEdits" ] && _protected_scope "$prompt"; then
    [ "${OSRC_NO_BYPASS:-0}" = "1" ] && { printf 'REFUSE'; return; }   # caller die()s (so it propagates out of $())
    if [ "${OSRC_ALLOW_DOWNGRADE:-0}" = "1" ]; then
      printf '>>> [outsourcerer] SECURITY DOWNGRADE: protected path, escalating acceptEdits -> bypassPermissions because --allow-downgrade/OSRC_ALLOW_DOWNGRADE=1.\n' >&2
      printf 'bypassPermissions'; return
    fi
    printf '>>> [outsourcerer] protected path needs --allow-downgrade; running unescalated (acceptEdits).\n' >&2
  fi
  printf '%s' "$mode"
}
_perm_refuse_msg="edit target is under a harness-protected config dir (~/.claude, ~/.codex, ...); headless acceptEdits cannot auto-approve it. Re-run with 'yolo' (bypassPermissions), edit a copy, or unset OSRC_NO_BYPASS."

# =============================================================================
# CLOUD DISCLOSURE + SECRET-SCAN GATE (security hardening).
# Mirrors the _perm_escalate/_protected_scope shapes: a small pure classifier plus a
# gate that dies on REFUSE. Local/ollama/lmstudio lanes are short-circuited in
# route_delegate BEFORE this runs, so this only guards CLOUD lanes (cc/codex/OpenRouter,
# devin, gemini, codex-native) where repo content actually leaves the machine.
# Fail-closed: non-interactive without an explicit ack (OSRC_CLOUD_ACK=1 or --cloud-ack)
# REFUSEs; a REAL .env/credential file in scope hard-dies regardless of ack (KTD1/KTD2).
# =============================================================================

# _is_cloud_lane <disp> -> 0 if the resolved dispatch lane ships data off-machine, else 1.
_is_cloud_lane() {
  case "$1" in
    ccor|codexor|ccnative|cxnative|gmnative|devin|droid|cursor|claudex) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- per-lane / per-repo trust for the credential-FILE hard-block (issue #2).
# Default EMPTY, so every install stays fail-closed exactly as before. A lane is trusted only for
# repos explicitly listed for it, so trusting a lane in one repo grants nothing anywhere else.
# Deliberately NOT an environment variable: an exported grant is inherited by every child process
# (bg/fanout jobs, nested invocations) and would silently widen the trusted set far past the repo the
# operator was thinking about. The config file and a per-invocation flag are the only two grants, and
# neither survives into a child.
# Config: $XDG_CONFIG_HOME/outsourcerer/trusted-lanes.json (default ~/.config/...), shape:
#   { "devin": ["/abs/path/to/repo", ...], "cc": [...] }
_trust_config_file() { printf '%s/outsourcerer/trusted-lanes.json' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# _lane_trusted_for_pwd <lane> -> 0 when this lane is trusted for the current repo. Fails CLOSED on
# every uncertainty: no file, unreadable, bad JSON, no jq, unresolvable path.
_lane_trusted_for_pwd() {
  local lane="$1" cf here p rp
  [ -n "$lane" ] || return 1
  # Per-invocation grant (--trust-lane). Not exported, so a bg/fanout child re-evaluates from config.
  case " ${OSRC_TRUST_LANE_ONCE:-} " in *" $lane "*) return 0 ;; esac
  cf="$(_trust_config_file)"
  [ -f "$cf" ] && [ -r "$cf" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # Resolve $PWD through symlinks so a symlinked path cannot masquerade as a trusted repo.
  here="$(cd "$PWD" 2>/dev/null && pwd -P)" || return 1
  [ -n "$here" ] || return 1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in "~"/*) p="$HOME/${p#\~/}" ;; esac
    rp="$(cd "$p" 2>/dev/null && pwd -P)" || continue
    # Exact repo, or anywhere inside it. Never a prefix-string match (/repo must not match /repo-two).
    [ "$here" = "$rp" ] && return 0
    case "$here" in "$rp"/*) return 0 ;; esac
  done < <(jq -r --arg l "$lane" '.[$l] // [] | .[]? | select(type=="string")' "$cf" 2>/dev/null)
  return 1
}

# _secret_scan <prompt> -> best-effort, gitignore-aware (KTD2). Hard-dies if a REAL credential
# file sits inside the delegated scope (cwd top-level + .aws). Reports (via OSRC_SECRET_HIT_COUNT) any
# high-signal pattern found in the prompt or a --with file, but does NOT hard-block on a regex
# hit alone (avoid crying wolf); only an actual credential FILE hard-blocks.
_secret_scan() {
  local prompt="${1:-}" f scan="$1" lane="${2:-}" trusted=0
  if _lane_trusted_for_pwd "$lane"; then trusted=1; fi
  # (1) hard block: an actual credential file in scope. Skipped ONLY for a lane explicitly trusted for
  # THIS repo. The pattern scan (2) and the pasted-VALUE block (3) below still run either way: trusting
  # a lane with the credentials a repo already contains is a different decision from letting a live
  # secret VALUE be pasted into a prompt, and the second is never implied by the first.
  if [ "$trusted" = "0" ]; then
  for f in "$PWD/.env" "$PWD/.env.local" "$PWD/credentials" "$PWD/id_rsa" "$PWD/id_ed25519" "$PWD/.aws/credentials"; do
    [ -f "$f" ] && die "CLOUD GATE: real credential file in delegated scope: $f — refusing cloud route. Remove it, or delegate to a local (ollama/lmstudio) lane which never leaves the machine."
  done
  # dotenv variants (.env.*), excluding obvious templates (.example/.sample/.template/.dist).
  while IFS= read -r f; do
    case "$f" in *.example|*.sample|*.template|*.dist) continue ;; esac
    [ -f "$f" ] && die "CLOUD GATE: real credential file in delegated scope: $f — refusing cloud route. Remove it, or delegate to a local (ollama/lmstudio) lane."
  done < <(compgen -G "$PWD/.env.*" 2>/dev/null)
  # (1b) A cloud delegate can read the WHOLE workspace, not just its root, so a nested
  # credential file (services/prod/.env, deploy/.env.production, config/id_rsa) is just as exfiltrable.
  # Bounded recursive sweep: depth-limited, prunes heavy/vendored dirs, excludes obvious templates.
  # Opt out with OSRC_SECRET_SCAN_DEEP=0 (e.g. a giant monorepo where the walk is too slow).
  if [ "${OSRC_SECRET_SCAN_DEEP:-1}" = "1" ] && command -v find >/dev/null 2>&1; then
    # Validate depth to an integer -- a bogus OSRC_SECRET_SCAN_DEPTH made `find`
    # error out, the read loop saw nothing, and the scan FAILED OPEN (no die). Never fail open on a scan
    # we cannot run: sanitize to the default, and if find itself errors, refuse the cloud route.
    local _depth="${OSRC_SECRET_SCAN_DEPTH:-4}"
    case "$_depth" in ''|*[!0-9]*) _depth=4 ;; esac
    [ "$_depth" -gt 12 ] 2>/dev/null && _depth=12   # cap: an unbounded walk is a DoS/hang, not security
    # Process substitution DISCARDS find's exit status, so a find that fails
    # to run scans nothing and the gate fails OPEN. Run find into a private temp file, CHECK its status,
    # and hard-die (fail CLOSED) if the scan could not complete. A cloud delegate runs with our own repo
    # privileges, so paths find can read are exactly the paths the delegate can read.
    local _sf _ef
    _sf="$(mktemp "${TMPDIR:-/tmp}/osrc.scan.XXXXXX" 2>/dev/null)" || die "CLOUD GATE: cannot create scan tempfile — refusing cloud route (fail closed)."
    _ef="$(mktemp "${TMPDIR:-/tmp}/osrc.scanerr.XXXXXX" 2>/dev/null)" || { rm -f "$_sf"; die "CLOUD GATE: cannot create scan tempfile — refusing cloud route (fail closed)."; }
    find "$PWD" -maxdepth "$_depth" \
               \( -name .git -o -name node_modules -o -name vendor -o -name .venv -o -name venv \
                  -o -name target -o -name dist -o -name build -o -name .terraform \) -prune -o \
               -type f \( -name '.env' -o -name '.env.*' -o -name 'credentials' -o -name 'id_rsa' \
                  -o -name 'id_ed25519' \) -print > "$_sf" 2>"$_ef"
    local _fs=$?
    # A nonzero find rc is USUALLY routine traversal noise (a mode-000 or
    # root-owned subdir). Same-privilege: a path find can't read, the cloud delegate can't read either, so
    # that's NOT an exfil gap -- process the readable results and proceed. Fail CLOSED only on a REAL scan
    # failure (bad invocation/syntax/tool error): i.e. stderr has a line that is NOT a permission diagnostic.
    if [ "$_fs" -ne 0 ] && [ -s "$_ef" ] && grep -qvE 'Permission denied|Operation not permitted|Not a directory|No such file' "$_ef"; then
      rm -f "$_sf" "$_ef"; die "CLOUD GATE: workspace credential scan could not complete (find rc=$_fs) — refusing cloud route (fail closed). Fix the scan or set OSRC_SECRET_SCAN_DEEP=0 to skip it (NOT recommended for cloud lanes)."
    fi
    local _hit=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in *.example|*.sample|*.template|*.dist) continue ;; esac
      _hit="$f"; break
    done < "$_sf"
    rm -f "$_sf" "$_ef"
    [ -n "$_hit" ] && die "CLOUD GATE: real credential file in delegated scope: $_hit — refusing cloud route. Remove it, or delegate to a local (ollama/lmstudio) lane which never leaves the machine."
  fi
  fi
  # (2) best-effort pattern scan over prompt + --with files (report only, never hard-blocks).
  if [ -n "${WITH_SPEC:-}" ]; then
    local tok; local -a _ws; IFS=' ' read -ra _ws <<< "$WITH_SPEC"
    for tok in "${_ws[@]}"; do
      case "$tok" in *=*) continue ;; esac          # skills=a,b / mcp=x are not file paths
      [ -f "$tok" ] && scan="$scan
$(cat "$tok" 2>/dev/null)"
    done
  fi
  # Count distinct high-signal matches; do NOT retain the matched secret text (only a count is
  # surfaced downstream, so the raw credential fragments never live in a variable or reach stderr/logs).
  OSRC_SECRET_HIT_COUNT="$(printf '%s\n' "$scan" | grep -Eoi 'OPENROUTER_API_KEY|sk-[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{20,}|AWS_SECRET[_A-Z]*|-----BEGIN [A-Z ]*PRIVATE KEY-----' 2>/dev/null | sort -u | grep -c . )"
  OSRC_SECRET_HIT_COUNT="${OSRC_SECRET_HIT_COUNT:-0}"
  # (3) VALUE hard-block: a real high-entropy secret VALUE pasted into the prompt / --with
  # files (not merely a keyword like the bare name OPENROUTER_API_KEY, which appears in normal code
  # discussion) ships a LIVE credential to a cloud lane. These patterns are token values and are almost
  # never legitimately pasted, so — unlike the count-only keyword scan above — they HARD-BLOCK by
  # default. Opt out with OSRC_SECRET_ALLOW_VALUE=1 for the rare deliberate case. The value itself is
  # never printed (only the refusal). Reference secrets by NAME, not value, when delegating.
  if [ "${OSRC_SECRET_ALLOW_VALUE:-0}" != "1" ] \
     && printf '%s\n' "$scan" | grep -Eq 'sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'; then
    die "CLOUD GATE: a live secret VALUE (API key / token / private key) is in the prompt or a --with file — refusing the cloud route so it doesn't leave your machine. Reference the secret by NAME instead of pasting its value, or set OSRC_SECRET_ALLOW_VALUE=1 if you truly intend to send it."
  fi
}

# _cloud_disclose <lane> <model> <prompt> -> the cloud gate. Idempotent per process via
# OSRC_CLOUD_ACKED (set on any successful ack so fanout does not re-prompt N times).
_cloud_disclose() {
  local lane="$1" model="${2:-}" prompt="${3:-}"
  _is_cloud_lane "$lane" || return 0                 # local/ollama/lmstudio: skip entirely
  # SECURITY (CRITICAL): the credential hard-block MUST run for every cloud delegation,
  # BEFORE any acknowledgement short-circuit. OSRC_CLOUD_ACKED is exported and therefore inherited by
  # child processes (bg/fanout __runjob, nested invocations); if the ACKED early-return preceded the
  # scan, `OSRC_CLOUD_ACKED=1` in the environment would ship a repo with a live .env to a third-party
  # API with the hard-block silently skipped. An ack only suppresses the human-facing notice/prompt --
  # never the scan.
  _secret_scan "$prompt" "$lane"                     # dies here if a real cred file is in scope
  [ "${OSRC_CLOUD_ACKED:-0}" = "1" ] && return 0     # already disclosed in-process -> skip the notice only
  local cwd="${PWD/#$HOME/~}"
  local train="paid/non-training route (no training on your data)"
  # match :free ANYWHERE — the model arg may be a comma-joined pair (second-opinion), so a leading
  # `hy3:free,deepseek/...` must still disclose may-train (an ends-with test missed the joined case).
  case "$model" in *:free*) train="':free' route — PROVIDER MAY TRAIN on your data" ;; esac
  printf '>>> [outsourcerer] CLOUD DISCLOSURE (U1): delegating to a CLOUD lane (%s / %s).\n' "$lane" "$model" >&2
  printf '>>>   destination : a third-party API over the network — repo content LEAVES this machine.\n' >&2
  printf '>>>   readable    : this working dir (%s) + any --with files you passed.\n' "$cwd" >&2
  printf '>>>   training    : %s\n' "$train" >&2
  # Report the COUNT of high-signal matches, never the matched secret text itself (printing the
  # values would leak the very credentials we are warning about to the terminal / any log capturing stderr).
  [ "${OSRC_SECRET_HIT_COUNT:-0}" -gt 0 ] 2>/dev/null && printf '>>>   secret scan : %s high-signal credential pattern(s) detected in prompt/--with (values redacted)\n' "$OSRC_SECRET_HIT_COUNT" >&2
  # A skipped credential scan is never silent: the one case where the gate stood down is the case the
  # operator most needs to see named, every single time.
  _lane_trusted_for_pwd "$lane" && printf '>>>   trust       : credential-file scan SKIPPED — lane '"'"'%s'"'"' is trusted for %s (trusted-lanes.json / --trust-lane). Pasted-secret and pattern scans still ran.\n' "$lane" "$cwd" >&2
  # acknowledge: env/flag ack (persisted for next time), else remembered consent, else interactive
  # prompt (persisted on yes), else fail-closed refuse with the one-time-fix spelled out.
  if [ "${OSRC_CLOUD_ACK:-0}" = "1" ]; then
    _cloud_consent_persist; export OSRC_CLOUD_ACKED=1; return 0
  fi
  if _cloud_consent_ok; then
    printf '>>>   consent     : remembered grant in %s (revoke: %s consent revoke)\n' "${OSRC_CONSENT_FILE/#$HOME/~}" "$0" >&2
    export OSRC_CLOUD_ACKED=1; return 0
  fi
  if [ -t 0 ] && [ -t 2 ]; then
    printf '>>>   Acknowledge cloud disclosure? (remembered for future runs) [y/N] ' >&2
    local ans=""; IFS= read -r ans || ans=""
    case "$ans" in y|Y|yes|YES) _cloud_consent_persist; export OSRC_CLOUD_ACKED=1; return 0 ;; esac
    die "CLOUD GATE: disclosure declined interactively — refusing cloud route. Re-run with OSRC_CLOUD_ACK=1 or --cloud-ack."
  fi
  die "CLOUD GATE: cloud delegation needs a ONE-TIME consent (this run sends repo content to a third-party API). Fix once, never see this again:
    $0 consent grant        # remember consent for all future runs
  or pass --cloud-ack on this command (also remembered). Local ollama/lmstudio lanes never need this."
}

delegate_cc() {
  local tier="$1"; shift
  local ORIGARGS=("$@")   # preserved verbatim for the cross-lane self-heal (-> devin), same technique delegate_codex uses for -> cc
  _consume_flags "$@"
  [ "${#REST[@]}" -gt 0 ] || die "no task prompt given"
  local prompt="${REST[*]}"
  have claude || die "claude CLI not on PATH"
  _or_load_key
  local mode posture
  case "$tier" in
    auto)         mode="default";        posture="READ-ONLY (headless denies tool exec)" ;;
    accept-edits) mode="acceptEdits";    posture="MUTATING (auto-accepts file edits)" ;;
    autonomous)   die "cc lane has NO sandbox, so 'research' is unsafe here. Use --provider devin or codex for sandboxed tool-exec, or 'yolo' if you accept no sandbox." ;;
    dangerous)    mode="bypassPermissions"; posture="DANGER (bypasses ALL permission checks, no sandbox)" ;;
    *) die "bad tier: $tier" ;;
  esac
  # --bare by default: the delegate does NOT inherit your CLAUDE.md / ~90 skills / MCP schemas
  # (keeps tokens low, avoids leaking your config to a 3rd-party model, and prevents it seeing
  # THIS skill and re-delegating). OUTSOURCERER_LOADED=1 opts into a full inherited session.
  # ISOLATION (I1, claude harness parity): even on the LOADED path, build_mcp_flags_cc now emits
  # --strict-mcp-config --mcp-config <empty> by DEFAULT so the delegate does NOT inherit the user's
  # live project-scoped MCP servers (which can wedge a headless run on interactive OAuth). LOADED
  # brings in CLAUDE.md + skills, NOT MCP — MCP still needs --with mcp=a,b or OSRC_CLAUDE_USER_CONFIG=1.
  local bare=(--bare) load_note="clean (--bare, no MCP surface)"
  if [ "${OUTSOURCERER_LOADED:-0}" = "1" ]; then
    bare=(); load_note="LOADED, inherits your full CLAUDE.md + skills (MCP isolated; --with mcp= / OSRC_CLAUDE_USER_CONFIG=1 to load)"
  fi
  local sfx=(); [ "${OSRC_STREAM:-0}" = "1" ] && sfx=(--verbose --output-format stream-json)
  build_mcp_flags_cc || die "isolation setup failed (cannot create strict-empty MCP config; aborting to avoid inheriting live MCP — set OSRC_CLAUDE_USER_CONFIG=1 to override)"
  # Grant the coding toolset so a headless mutating job does NOT wedge on an unanswerable Bash
  # permission prompt (acceptEdits auto-approves edits but NOT bash -> the top headless failure mode).
  # `run` (auto) stays read-only; mutating verbs (edit/yolo) get Bash. --allowedTools is VARIADIC, so it
  # must be terminated by --permission-mode before the prompt. Override the set with OSRC_ALLOWED_TOOLS.
  local tools=()
  if [ -n "${OSRC_ALLOWED_TOOLS:-}" ]; then read -ra _at <<< "$OSRC_ALLOWED_TOOLS"; tools=(--allowedTools "${_at[@]}")
  else case "$tier" in
    auto)                   tools=(--allowedTools Read Grep Glob) ;;
    accept-edits|dangerous) tools=(--allowedTools Read Edit Write Bash Grep Glob) ;;
  esac; fi
  local think=""; if [ -n "$EFFORT" ]; then think="$(_effort_thinking_tokens "$EFFORT")"; [ -n "$think" ] && printf '>>> [effort] reasoning=%s (native: MAX_THINKING_TOKENS=%s)\n' "$EFFORT" "$think" >&2; fi
  local m rc=1 ttier wrapped cap
  local old_umask; old_umask="$(umask)"; umask 077
  cap="$OSRC_HOME/.ccerr-$$"
  local last_transport=0
  for m in $(_or_chain "$tier"); do
    ttier="$(resolve_tier "$m" "")"
    wrapped="$(_build_prompt "$m" "$prompt" "")"
    _tier_banner "cc-openrouter" "$m" "$ttier" "$posture | env: $load_note"
    # Use an explicit `env` array so MAX_THINKING_TOKENS can be appended CONDITIONALLY. A
    # ${think:+VAR=val} prefix does NOT work: bash only treats literal WORD=WORD tokens as
    # assignments, so an expanded one becomes a bogus command ("MAX_THINKING_TOKENS=… not found").
    local envp=(env
      "ANTHROPIC_BASE_URL=https://openrouter.ai/api"
      "ANTHROPIC_AUTH_TOKEN=$OPENROUTER_API_KEY"
      ANTHROPIC_API_KEY=
      "ANTHROPIC_MODEL=$m"
      "ANTHROPIC_SMALL_FAST_MODEL=$m")
    [ -n "$think" ] && envp+=("MAX_THINKING_TOKENS=$think")
    local emode; emode="$(_perm_escalate "$mode" "$wrapped")"; [ "$emode" = REFUSE ] && die "$_perm_refuse_msg"
    # Capture COMBINED stdout+stderr, like delegate_codex does (2>&1 | tee), not stderr-only.
    # An OpenRouter transport/affordability error (e.g. "API Error: 402 ... requires more
    # credits") is reported by `claude -p` as a stream-json/stdout message, NOT on stderr -- a
    # stderr-only capture leaves _is_transport_failure permanently blind to it (verified live: a
    # real 402 here produced empty/unrelated stderr -- just an "Advisor disabled" warning -- while
    # the actual error only ever appeared in stdout). PIPESTATUS[0], not $?, after the pipe.
    "${envp[@]}" claude -p ${bare[@]+"${bare[@]}"} ${sfx[@]+"${sfx[@]}"} ${CC_MCP_FLAGS[@]+"${CC_MCP_FLAGS[@]}"} ${tools[@]+"${tools[@]}"} --permission-mode "$emode" "$wrapped" 2>&1 | tee "$cap"
    rc=${PIPESTATUS[0]}
    chmod 600 "$cap" 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then record_ledger cc "$m" "$ttier" "$tier" "$prompt"; last_transport=0; break; fi
    # Only escalate on transport/infra failures; task failures (red tests, max-turns, etc.) stop here.
    if _is_transport_failure "$(cat "$cap" 2>/dev/null)" "$rc"; then
      last_transport=1
      echo "HINT: model '$m' failed (rc=$rc) on a transport/infra error; escalating to next in chain..." >&2
      continue
    fi
    last_transport=0
    # Surface the task result to the orchestrator and stop retrying.
    cat "$cap" >&2
    break
  done
  rm -f "$cap" 2>/dev/null
  umask "$old_umask"
  # Cross-lane self-heal: every model in the OpenRouter chain was exhausted on transport/
  # availability grounds (e.g. 402 insufficient credit), and the ORIGINALLY requested model also
  # has a Devin-lane sibling (glm today, see _devin_model_for). This is not a security downgrade
  # (Devin has its own sandbox), so it heals by default -- opt out with OSRC_NO_CROSS_LANE=1 if
  # you specifically want a hard OpenRouter-only failure (e.g. to test OpenRouter itself).
  if [ "$rc" -ne 0 ] && [ "$last_transport" = "1" ] && [ "${OSRC_NO_CROSS_LANE:-0}" != "1" ]; then
    local _dvm; _dvm="$(_devin_model_for "$MODEL")"
    if [ -n "$_dvm" ]; then
      printf '>>> [self-heal] OpenRouter exhausted for "%s" (transport/availability failure on every model tried); "%s" also runs on Devin -- retrying there instead. Set OSRC_NO_CROSS_LANE=1 to disable and fail on OpenRouter instead.\n' "$MODEL" "$_dvm" >&2
      # Rewrite the model token in ORIGARGS so the Devin lane runs the Devin id, not the OR alias
      # (same rewrite technique route_delegate's availability-aware reroute uses for the default-provider case).
      local _i; for _i in "${!ORIGARGS[@]}"; do
        case "${ORIGARGS[$_i]}" in -m|--model) [ $((_i+1)) -lt ${#ORIGARGS[@]} ] && ORIGARGS[$((_i+1))]="$_dvm" ;; esac
      done
      PROVIDER=devin delegate "$tier" "" ${ORIGARGS[@]+"${ORIGARGS[@]}"}; return $?
    fi
  fi
  return "$rc"
}

# =============================================================================
# LOCAL LANE (Ollama / LM Studio / llama.cpp / any OpenAI-compatible localhost server).
# KEYLESS, PRIVATE ($0 cash, $0 plan limits, nothing leaves the machine). Driven by `codex exec`
# against the local /v1 endpoint (wire_api=chat) so it keeps FULL agentic tool use, that is what
# makes "run a review skill on freshly-hardened code, privately" work: the delegate reads the repo
# locally and no code is ever shipped to a cloud model that might train on it.
# =============================================================================
_local_probe() {   # <base_url> -> echo first model id if it's a real OpenAI-compatible server, else nonzero
  local base="$1" body mid
  body="$(curl -s -m "${OSRC_LOCAL_TIMEOUT:-2}" "$base/models" 2>/dev/null)" || return 1
  case "$body" in ''|*'404'*'not found'*|*'<html'*) return 1 ;; esac
  if have jq; then mid="$(printf '%s' "$body" | jq -r '(.data[0].id // .models[0].id // .models[0].name // empty)' 2>/dev/null)"
  else mid="$(printf '%s' "$body" | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"; fi
  [ -n "$mid" ] || return 1
  printf '%s' "$mid"
}

# _local_detect -> echo "base_url|model|label" for the first live local server, else nonzero.
# Validate that a URL points to a loopback address (127.0.0.1, localhost, ::1).
# Prevents SSRF via OSRC_LOCAL_URL / OLLAMA_HOST pointing to internal/external hosts.
_is_loopback_url() {
  local url="$1" host
  case "$url" in
    http://localhost[:/]*|http://localhost|https://localhost[:/]*|https://localhost) return 0 ;;
    http://127.0.0.1[:/]*|http://127.0.0.1|https://127.0.0.1[:/]*|https://127.0.0.1) return 0 ;;
    http://[::1][:/]*|http://[::1]|https://[::1][:/]*|https://[::1]) return 0 ;;
  esac
  # Extract host from URL for further checking
  host="${url#*://}"; host="${host%%/*}"; host="${host%%:*}"
  case "$host" in
    localhost|127.0.0.1|\[::1\]) return 0 ;;
  esac
  # Allow non-loopback only with explicit opt-in
  [ "${OSRC_LOCAL_ALLOW_REMOTE:-0}" = "1" ] && return 0
  return 1
}

_local_detect() {
  local c base label mid
  local cands=()
  if [ -n "${OSRC_LOCAL_URL:-}" ]; then
    _is_loopback_url "${OSRC_LOCAL_URL%/}" || die "OSRC_LOCAL_URL must point to localhost/127.0.0.1 (got: ${OSRC_LOCAL_URL}). Set OSRC_LOCAL_ALLOW_REMOTE=1 to override."
    cands+=("${OSRC_LOCAL_URL%/}|custom")
  fi
  if [ -n "${OLLAMA_HOST:-}" ]; then
    _is_loopback_url "${OLLAMA_HOST%/}" || die "OLLAMA_HOST must point to localhost/127.0.0.1 (got: ${OLLAMA_HOST}). Set OSRC_LOCAL_ALLOW_REMOTE=1 to override."
    cands+=("${OLLAMA_HOST%/}/v1|ollama")
  fi
  cands+=("http://localhost:11434/v1|ollama" "http://localhost:1234/v1|lmstudio" "http://localhost:8080/v1|llama.cpp")
  for c in "${cands[@]}"; do
    base="${c%|*}"; label="${c#*|}"
    mid="$(_local_probe "$base")" && { printf '%s|%s|%s' "$base" "$mid" "$label"; return 0; }
  done
  return 1
}

# _local_resolve <model-arg> -> echo "base_url|model" (auto-detecting whatever is unspecified), else nonzero.
_local_resolve() {
  local arg="${1:-}" base="" model=""
  case "$arg" in
    ollama:*)   base="${OSRC_LOCAL_URL:-http://localhost:11434/v1}"; model="${arg#ollama:}" ;;
    lmstudio:*) base="${OSRC_LOCAL_URL:-http://localhost:1234/v1}";  model="${arg#lmstudio:}" ;;
    lms:*)      base="${OSRC_LOCAL_URL:-http://localhost:1234/v1}";  model="${arg#lms:}" ;;
    local:*)    model="${arg#local:}" ;;
    local|"")   : ;;
    *)          model="$arg" ;;   # --provider local with a raw model id
  esac
  if [ -z "$base" ] || [ -z "$model" ]; then
    local det dm; det="$(_local_detect)" || return 1
    base="${base:-${det%%|*}}"; dm="${det#*|}"; model="${model:-${dm%%|*}}"
  fi
  printf '%s|%s' "$base" "$model"
}

# delegate_local <perm-tier>, direct streaming call to a local OpenAI-compatible /v1/chat/completions.
# Universal (Ollama / LM Studio / llama.cpp / any), keyless, no harness dependency. This is TEXT
# delegation: the local model reasons over the prompt you hand it (inject files with --with or inline).
# It does NOT autonomously read your repo or run tools, agentic local tool-use needs a Responses-API
# server (Codex 0.144 dropped chat wire_api, so it can't drive Ollama), see references/lanes-and-models.
delegate_local() {
  local tier="$1"
  [ "${#REST[@]}" -gt 0 ] || die "no task prompt given"
  local task="${REST[*]}"
  have curl || die "curl not on PATH (the local lane needs it)"
  have jq   || die "jq not on PATH (the local lane needs it; brew install jq)"
  local res; res="$(_local_resolve "$MODEL")" || die "no local inference server detected (probed Ollama :11434, LM Studio :1234, llama.cpp :8080). Start one (e.g. 'ollama serve' + 'ollama pull qwen2.5-coder'), or set OSRC_LOCAL_URL=http://host:port/v1. Run 'doctor' for status."
  local base="${res%%|*}" model="${res#*|}"
  # AGENTIC branch: tool-requiring verbs (research/edit/yolo) or OSRC_LOCAL_AGENTIC=1 -> the local model
  # runs INSIDE a harness with tool use. LM Studio (Responses API) via codex, no install; a chat-only
  # server (Ollama) via the on-demand vendored Anthropic<->OpenAI shim + the cc (Claude Code) lane.
  if [ "$tier" != "auto" ] || [ "${OSRC_LOCAL_AGENTIC:-0}" = "1" ]; then
    _local_agentic "$tier" "$base" "$model"; return $?
  fi
  local ttier wrapped; ttier="$(resolve_tier "$model" "${TTIER:-}")"; wrapped="$(_build_prompt "$model" "$task" "${TTIER:-}")"
  _tier_banner "local ($base)" "$model" "$ttier" "TEXT delegation | PRIVATE: on YOUR hardware, \$0 cash, \$0 plan limits, nothing leaves your machine"
  local jd="${OSRC_JOB_DIR:-$OSRC_HOME}"; mkdir -p "$jd"
  local capf="$jd/.local.$$.txt"; : > "$capf"
  local payload; payload="$(jq -cn --arg m "$model" --arg c "$wrapped" '{model:$m,stream:true,messages:[{role:"user",content:$c}]}')"
  # Stream so the liveness watchdog (bg/fanout) sees byte growth, and the user sees tokens live.
  local line data tok rc=0
  curl -sN --fail-with-body -m "${OSRC_LOCAL_GEN_TIMEOUT:-900}" "$base/chat/completions" \
       -H 'Content-Type: application/json' -H "Authorization: Bearer ${OSRC_LOCAL_KEY:-local}" \
       -d "$payload" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      data:*) data="${line#data:}"; data="${data# }"
        [ "$data" = "[DONE]" ] && continue
        tok="$(printf '%s' "$data" | jq -r '(.choices[0].delta.content // .choices[0].message.content // .message.content // empty)' 2>/dev/null)"
        [ -n "$tok" ] && { printf '%s' "$tok"; printf '%s' "$tok" >> "$capf"; } ;;
    esac
  done
  rc=${PIPESTATUS[0]}
  printf '\n'
  if [ ! -s "$capf" ]; then
    rm -f "$capf"
    die "local server at $base returned no completion (curl rc=$rc). Check it is up, the model id '$model' exists (see 'doctor'), and it supports SSE streaming on /v1/chat/completions."
  fi
  [ "${OSRC_STREAM:-0}" = "1" ] && cp "$capf" "$jd/last.txt" 2>/dev/null
  rm -f "$capf"
  record_ledger local "$model" "$ttier" "$tier" "$task" "0.000000"
  return 0
}

# _local_supports_responses <base> -> 0 if the server exposes an OpenAI Responses endpoint (LM Studio),
# nonzero for chat-only servers (Ollama/llama.cpp). Probe: POST {}; a missing endpoint 404s.
_local_supports_responses() {
  case "${OSRC_LOCAL_API:-}" in responses) return 0 ;; chat) return 1 ;; esac
  local code; code="$(curl -s -o /dev/null -w '%{http_code}' -m 3 -X POST "$1/responses" -H 'Content-Type: application/json' -d '{}' 2>/dev/null)"
  case "$code" in 404|000|501|405) return 1 ;; *) return 0 ;; esac
}

# _local_agentic <tier> <base> <model> -> pick the agentic vehicle.
# the shim + Claude Code is the RELIABLE single vehicle for BOTH Ollama and LM Studio
# (it's certified end-to-end, see scripts/tests/test_agentic_local_cert.py). The codex-Responses path
# is high-risk (LM Studio advertising /v1/responses does NOT mean it satisfies Codex's Responses
# dialect), so it is OPT-IN only via OSRC_LOCAL_API=responses and stays experimental.
_local_agentic() {
  local tier="$1" base="$2" model="$3"
  if [ "${OSRC_LOCAL_API:-}" = "responses" ]; then _local_agentic_codex "$tier" "$base" "$model"
  else _local_agentic_shim "$tier" "$base" "$model"; fi
}

# Agentic local via codex Responses (LM Studio / any Responses-API server), keyless, NO install.
_local_agentic_codex() {
  local tier="$1" base="$2" model="$3"
  have codex || die "agentic-local on a Responses-API server needs the codex CLI (npm i -g @openai/codex), or use a chat-only server for the shim path."
  local sflag posture
  case "$tier" in
    accept-edits|autonomous) sflag=(--sandbox workspace-write); posture="WORKSPACE-WRITE sandbox" ;;
    dangerous)               sflag=(--dangerously-bypass-approvals-and-sandbox); posture="DANGER (no sandbox)" ;;
    *)                       sflag=(--sandbox read-only); posture="READ-ONLY sandbox" ;;
  esac
  local ttier wrapped; ttier="$(resolve_tier "$model" "${TTIER:-}")"; wrapped="$(_build_prompt "$model" "${REST[*]}" "${TTIER:-}")"
  local cmh=(); _codex_code_mode_host || cmh=(-c features.code_mode_host=false)
  local eff=(); [ -n "$EFFORT" ] && { eff=(-c "model_reasoning_effort=$EFFORT"); printf '>>> [effort] reasoning=%s (native)\n' "$EFFORT" >&2; }
  local sfx=(); [ "${OSRC_STREAM:-0}" = "1" ] && sfx=(--json --output-last-message "${OSRC_JOB_DIR:-$OSRC_HOME}/last.txt")
  # ISOLATION (I1): the local lane's whole promise is "nothing leaves your machine" -- inheriting the
  # user's live ~/.codex mcp_servers would both break that (a cloud MCP server could load) and wedge
  # on interactive MCP auth. Drop the live config; the inline oslocal provider fully defines the lane.
  local _iso=(); [ "${OSRC_CODEX_USER_CONFIG:-0}" = "1" ] || _iso=(--ignore-user-config)
  _tier_banner "local-agentic/codex ($base)" "$model" "$ttier" "$posture | AGENTIC tool use | PRIVATE: on YOUR hardware, \$0 cash, \$0 plan, nothing leaves your machine"
  local rc=0
  OSRC_LOCAL_KEY="${OSRC_LOCAL_KEY:-local}" \
  codex exec --skip-git-repo-check ${_iso[@]+"${_iso[@]}"} ${cmh[@]+"${cmh[@]}"} ${eff[@]+"${eff[@]}"} "${sflag[@]}" ${sfx[@]+"${sfx[@]}"} \
    -c model_provider=oslocal -c 'model_providers.oslocal.name="Local"' \
    -c "model_providers.oslocal.base_url=\"$base\"" \
    -c 'model_providers.oslocal.env_key="OSRC_LOCAL_KEY"' \
    -c 'model_providers.oslocal.wire_api="responses"' \
    -m "$model" "$wrapped" || rc=$?
  record_ledger local "$model" "$ttier" "$tier" "${REST[*]}" "0.000000"
  [ "$rc" -ne 0 ] && printf '>>> [hint] agentic-local/codex exited %s. Confirm the server exposes /v1/responses and the model supports tool-calling.\n' "$rc" >&2
  return "$rc"
}

# Agentic local on a chat-only server (Ollama) via the on-demand vendored shim + the cc lane.
# LAZY: reuse an existing proxy (OSRC_LOCAL_ANTHROPIC_URL) if present; else launch the shim ONLY here,
# where the user has explicitly asked for agentic-local; tear it down after. Never eager, never installs.
_local_agentic_shim() {
  local tier="$1" base="$2" model="$3"
  have claude || die "agentic-local via the shim drives 'claude -p' (Claude Code); claude not on PATH."
  local aurl="${OSRC_LOCAL_ANTHROPIC_URL:-}" shim_pid=""
  if [ -z "$aurl" ]; then
    [ "${OSRC_SHIM_NO_LAUNCH:-0}" = "1" ] && die "agentic-local on chat-only server $base needs an Anthropic-compatible proxy. Set OSRC_LOCAL_ANTHROPIC_URL, or unset OSRC_SHIM_NO_LAUNCH to let me launch the vendored shim."
    have python3 || die "the vendored translation shim needs python3."
    local shimf; shimf="$(dirname "$SCRIPT_PATH")/anthropic-openai-shim.py"
    [ -f "$shimf" ] || die "vendored shim not found at $shimf (build it first, plan U2)."
    local port="${OSRC_SHIM_PORT:-8788}"
    printf '>>> [shim] launching on-demand Anthropic<->OpenAI shim 127.0.0.1:%s -> %s so Claude Code can drive this LOCAL model agentically (torn down after; nothing leaves your machine).\n' "$port" "$base" >&2
    OSRC_SHIM_UPSTREAM="$base" OSRC_SHIM_PORT="$port" OSRC_SHIM_KEY="${OSRC_LOCAL_KEY:-local}" \
      OSRC_SHIM_MODEL="$model" nohup python3 "$shimf" >/dev/null 2>&1 &   # force the local model upstream (claude sends its own id)
    shim_pid=$!; aurl="http://127.0.0.1:$port"
    local i; for i in $(seq 1 20); do curl -s -m 1 "$aurl/health" >/dev/null 2>&1 && break; sleep 0.5; done
    curl -s -m 1 "$aurl/health" >/dev/null 2>&1 || { [ -n "$shim_pid" ] && kill "$shim_pid" 2>/dev/null; die "shim did not become healthy at $aurl (upstream $base). Check python3 + the server."; }
  fi
  local ttier mode wrapped; ttier="$(resolve_tier "$model" "${TTIER:-}")"; wrapped="$(_build_prompt "$model" "${REST[*]}" "${TTIER:-}")"
  case "$tier" in accept-edits|autonomous) mode=acceptEdits ;; dangerous) mode=bypassPermissions ;; *) mode=default ;; esac
  _tier_banner "local-agentic/shim ($aurl -> $base)" "$model" "$ttier" "AGENTIC via Claude Code | PRIVATE: on YOUR hardware, \$0, nothing leaves your machine"
  local rc=0 sfx=(); [ "${OSRC_STREAM:-0}" = "1" ] && sfx=(--verbose --output-format stream-json)
  # Small-model reliability: expose only essential tools by default so a 7-13B local model
  # isn't drowned in Claude Code's full tool schema. Override/disable with OSRC_LOCAL_TOOLS.
  local tools="${OSRC_LOCAL_TOOLS:-}"
  if [ -z "$tools" ]; then
    case "$mode" in acceptEdits|bypassPermissions) tools="Read Grep Glob Bash Write Edit" ;; *) tools="Read Grep Glob Bash" ;; esac
  fi
  # --bare is REQUIRED: without it Claude's advisor/catalog ranks the model and rejects an unknown id
  # (this is what made agentic-local silently fail). The shim forces the real model upstream, so the
  # ANTHROPIC_MODEL id here just has to pass claude's bare acceptance. --allowedTools is variadic, so
  # it must be terminated by --permission-mode before the trailing prompt (not swallow it).
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_EXECPATH \
    ANTHROPIC_BASE_URL="$aurl" ANTHROPIC_AUTH_TOKEN="${OSRC_LOCAL_KEY:-local}" ANTHROPIC_API_KEY= \
    ANTHROPIC_MODEL="$model" ANTHROPIC_SMALL_FAST_MODEL="$model" \
    claude -p --bare ${sfx[@]+"${sfx[@]}"} --allowedTools $tools --permission-mode "$(_perm_escalate "$mode" "$wrapped")" "$wrapped" || rc=$?
  record_ledger local "$model" "$ttier" "$tier" "${REST[*]}" "0.000000"
  [ -n "$shim_pid" ] && kill "$shim_pid" 2>/dev/null
  [ "$rc" -ne 0 ] && printf '>>> [hint] agentic-local/shim exited %s. The local model must support tool-calling (qwen2.5-coder / llama3.1); small models often do not.\n' "$rc" >&2
  return "$rc"
}

# _is_tooltype_400 <capture-file> -> true if the run died because the OpenRouter model's upstream
# provider rejected one of Codex's native tool types (the `namespace`/custom tool grouping Codex
# 0.144 emits; provider-routing dependent, NOT a toggleable feature). This is the signal to self-heal
# by re-running the SAME model on the cc lane, whose standard Anthropic tool format every OR model serves.
_is_tooltype_400() {
  grep -qiE 'native .?namespace.? tool type|does not support the native .* tool type|support the native `?[a-z_]+`? tool type' "$1" 2>/dev/null
}

# Classify a delegate failure as a transport/infra issue (safe to escalate) vs a task failure
# (must be surfaced, not retried). Returns 0 for connection, HTTP-5xx, 429, 401/403 auth, context
# length, model_not_found, timeout, or empty-stderr failures. Returns 1 for task failures (e.g., a
# red test suite, max-turns, or any non-zero exit with normal diagnostic output).
_is_transport_failure() {
  local stderr="$1" rc="${2:-0}"
  # Success is never a transport failure.
  [ "$rc" -eq 0 ] && return 1
  # Empty diagnostic output on a non-zero exit is AMBIGUOUS -- it can be a silently-failed TASK
  # (red tests, an assertion, a killed step) just as easily as an infra hiccup. Auto-classifying it as
  # transport would blind-RETRY a mutating task with no rollback (the exact failure this guard exists to stop).
  # Default: NOT transport (surface it as a task failure). Opt back in via OSRC_EMPTY_STDERR_IS_TRANSPORT=1.
  if [ -z "$stderr" ]; then
    [ "${OSRC_EMPTY_STDERR_IS_TRANSPORT:-0}" = "1" ] && return 0 || return 1
  fi
  # Kubernetes speaks the same sentence we use as an infra signal: `no endpoints found for service/foo`
  # is routine kubectl output from a DELEGATED TASK, while `no endpoints found for vendor/model` is the
  # router telling us the lane is gone. Same words, opposite meaning, and no regex separates them —
  # so name the resource kinds that make it task output and take them off the table first.
  local _scan="$stderr"
  if printf '%s' "$_scan" | grep -qiE 'no endpoints found for (service|svc|endpoints|ep|pod|po|deployment|deploy|statefulset|daemonset|ds|ingress|node|job|cronjob)/'; then
    _scan="$(printf '%s' "$_scan" | grep -viE 'no endpoints found for (service|svc|endpoints|ep|pod|po|deployment|deploy|statefulset|daemonset|ds|ingress|node|job|cronjob)/')"
  fi

  # Transport classification is a TWO-PASS match, because substring signatures fall into
  # two classes with different false-positive risk:
  #  PASS 1 -- MACHINE tokens + context-DISCRIMINATED signatures. These never occur in ordinary task/test
  #  prose (snake_case error codes, errno constants) or carry their own non-positional discriminator (a URL,
  #  the literal "after", an HTTP/version prefix, a status-code delimiter). Safe to match ANYWHERE in stderr.
  #  Two disciplines apply here. (1) Only RETRYABLE statuses count: a 400/404/422 is a malformed request,
  #  so escalating it through every model produces the same error N times, burns the budget, and buries
  #  the real cause. (2) Phrases made of ordinary English ("no endpoints found", "key limit exceeded")
  #  are things a DELEGATED TASK legitimately prints — kubectl output, a KV-store test — so they are
  #  either line-anchored or shaped tightly enough that task prose cannot satisfy them.
  if printf '%s' "$_scan" | grep -qiE \
'econnrefused|etimedout|econnreset|enetunreach|ehostunreach|(name or service not known|temporary failure in name resolution)|authentication_error|overloaded_error|model_not_found|context_length_exceeded|no endpoints found for [a-z0-9._-]+/[a-z0-9._:-]+$|http/[0-9.]+ [45][0-9][0-9]|\(code [45][0-9][0-9]\)|[45][0-9][0-9] server error.{0,40}for url|operation timed out after|429 .{0,20}rate.?limit|^[[:space:]]*(error: )?(key|credit) limit exceeded|insufficient credits|requires more credits|api error:? *\(?(408|409|425|429|5[0-9][0-9])'; then
    return 0
  fi
  #  PASS 2 -- HUMAN-READABLE phrases. A real CLI emits these as their OWN diagnostic line (leading the line,
  #  optionally behind a bare "error: " wrapper); ordinary failed-task stderr only ever EMBEDS them mid-sentence
  #  ("AssertionError: connection refused should be rendered..."). So every one is LINE-ANCHORED. This is what
  #  stops the prose-false-positive class wholesale (a false positive here would blind-RETRY a mutating task).
  if printf '%s' "$_scan" | grep -qiE \
'^[[:space:]]*(error: )?(connection (refused|reset|error|failed|closed|timed ?out)|could(n.t| not) connect|network (error|is unreachable|is down)|no route to host|(ssh: )?could not resolve host:|curl: \([0-9]+\)|(tls|ssl) (handshake|error|certificate|routines|alert)|error sending request|http (error |status )?[45][0-9][0-9]|[45][0-9][0-9] (too many requests|unauthorized|forbidden|bad gateway|service unavailable|gateway time-?out|internal server error)|api error:? *\(?(408|409|425|429|5[0-9][0-9])|authentication[ _]?(required|failed|error)|status[ _]?code[:= ]+[45][0-9][0-9]|(invalid|expired|missing|no valid).{0,15}(api.?key|auth token|bearer token|credential|authorization header)|rate.?limit(ed)?[ :]+(error|exceeded|reached|hit)|quota (exceeded|exhausted)|provider returned error|context.?length (exceeded|too long)|maximum context length|token limit exceeded|(request|read|connect) timed out|socket hang up$|gateway time-?out|deadline (has )?(elapsed|exceeded)|upstream (error|timed out|connect error)|stream disconnected|stream reset by peer|stream (closed|interrupted|ended) (before|unexpectedly|prematurely|during)|empty response from (the )?(server|upstream|api)|no response from (the )?(server|model|upstream)|model not found|model (is )?(unavailable|not available|does not exist|overloaded))'; then
    return 0
  fi
  return 1
}

# _is_sandboxed_proxy_tls_failure <text> -> 0 if <text> carries the specific signature of devin's
# Rust TLS stack (rustls_platform_verifier) rejecting a local/sandboxed proxy's peer certificate
# (an Apple Security OSStatus cert-verify code), typically alongside chisel_cloud_bridge handoff
# retries. This is the failure that surfaces from devin as a bare, generic "Connection error" with
# no hint of the real cause; the signature only appears in devin's OWN CLI log
# (~/.local/share/devin/cli/logs/), not in the captured out.log. DIAGNOSTICS-ONLY: this never
# drives retry/routing/fallback -- it only names a recognizable failure so the caller can act.
# Narrowness follows the same discipline as _is_transport_failure's PASS 1: the matched tokens are
# MACHINE identifiers (a Rust crate name + an Apple Security error code) that never occur in
# ordinary task/test prose, so an anywhere-in-text match is false-positive-safe.
_is_sandboxed_proxy_tls_failure() {
  local text="$1"
  # PASS 1 (machine tokens, anywhere in text): rustls_platform_verifier + an OSStatus cert-verify
  # code on the same log scan. Both tokens are emitted only by devin's TLS verify path against an
  # untrusted peer cert and never appear in task/test output.
  if printf '%s' "$text" | grep -qiE 'rustls_platform_verifier' && \
     printf '%s' "$text" | grep -qiE 'OSStatus -[0-9]+'; then
    return 0
  fi
  # PASS 2 (corroborated): chisel_cloud_bridge handoff retries + an OSStatus cert-verify code.
  # The chisel tunnel is devin's cloud ACP transport; an OSStatus cert failure there is the same
  # root cause surfaced through a different log line. Require BOTH tokens to stay narrow.
  if printf '%s' "$text" | grep -qiE 'chisel_cloud_bridge' && \
     printf '%s' "$text" | grep -qiE 'OSStatus -[0-9]+'; then
    return 0
  fi
  return 1
}

# _devin_sandboxed_proxy_tls_hint -> 0 and prints a one-line diagnostics hint to stderr when
# devin's own CLI log (~/.local/share/devin/cli/logs/devin_*.log) carries the sandboxed-proxy TLS
# signature. Called from delegate() after a non-zero devin exit (covers foreground + bg: for bg the
# supervisor captures stderr into out.log, so the hint reaches result/logs too). Purely diagnostic --
# does not change retry/routing. Silent on no match. The scan reads only the tail of the NEWEST
# devin log: the rustls/chisel retry storm lands at the end of the log right before devin gives up,
# so a tail scan avoids stale matches from an earlier session (override tail size via
# OSRC_DEVIN_LOG_SCAN, default 300 lines).
_devin_sandboxed_proxy_tls_hint() {
  local dlog_dir="${HOME}/.local/share/devin/cli/logs"
  [ -d "$dlog_dir" ] || return 1
  local newest; newest="$(ls -t "$dlog_dir"/devin_*.log 2>/dev/null | head -1)"
  [ -n "$newest" ] || return 1
  # Symlink discipline: match _cloud_consent_ok/_mode_read — never read through a
  # planted symlink, even though this path only ever emits a numeric OSStatus code (low blast radius).
  [ -L "$newest" ] && return 1
  local tail_text; tail_text="$(tail -n "${OSRC_DEVIN_LOG_SCAN:-300}" "$newest" 2>/dev/null)"
  [ -n "$tail_text" ] || return 1
  _is_sandboxed_proxy_tls_failure "$tail_text" || return 1
  local osstatus; osstatus="$(printf '%s' "$tail_text" | grep -oE 'OSStatus -[0-9]+' | head -1)"
  [ -n "$osstatus" ] || osstatus="OSStatus cert-verify error"
  printf 'devin TLS handshake failed against a local proxy in your shell (rustls cert verify: %s). This usually means a sandboxed/corporate proxy that devin'\''s Rust TLS client won'\''t trust. If you'\''re inside Claude Code'\''s sandboxed Bash tool, re-run this call with the sandbox disabled for devin-backed verbs.\n' "$osstatus" >&2
  return 0
}

# _devin_job_tls_hint <job-id> <already-shown-text> -> emits the sandboxed-proxy TLS hint to stderr
# for a terminal-failed devin job whose surfaced text does NOT already carry it (avoids
# double-printing when delegate() already wrote the hint into out.log). Used by cmd_result/cmd_logs
# so a caller inspecting a failed devin job later still sees the recognizable cause. Diagnostics-only.
_devin_job_tls_hint() {
  local id="$1" jd="$OSRC_JOBS/$1" shown="$2"
  [ -d "$jd" ] || return 1
  local prov; prov="$(_job_field "$id" '.provider' 2>/dev/null)"
  [ "$prov" = "devin" ] || return 1
  local st; st="$(cat "$jd/status" 2>/dev/null || echo '?')"
  case "$st" in
    failed|wedged|timeout|interrupted|permission-blocked) ;;
    *) return 1 ;;
  esac
  case "$shown" in
    *rustls*proxy*|*"devin TLS handshake failed"*) return 0 ;;   # already surfaced in out.log
  esac
  _devin_sandboxed_proxy_tls_hint
}

# delegate_codex <perm-tier> [-m MODEL] "<task>" , Codex exec -> OpenRouter (native Responses API)
delegate_codex() {
  local tier="$1"; shift
  local ORIGARGS=("$@")   # preserved verbatim for the cross-lane self-heal (-> delegate_cc)
  _consume_flags "$@"
  [ "${#REST[@]}" -gt 0 ] || die "no task prompt given"
  local prompt="${REST[*]}"
  have codex || die "codex CLI not on PATH (check ~/.local/bin/codex symlink)"
  _or_load_key
  local sflag posture
  case "$tier" in
    auto)                    sflag=(--sandbox read-only);      posture="READ-ONLY sandbox" ;;
    accept-edits|autonomous) sflag=(--sandbox workspace-write); posture="WORKSPACE-WRITE sandbox (Codex OS sandbox)" ;;
    dangerous)               sflag=(--dangerously-bypass-approvals-and-sandbox); posture="DANGER (no sandbox, no approvals)" ;;
    *) die "bad tier: $tier" ;;
  esac
  local sfx=(); [ "${OSRC_STREAM:-0}" = "1" ] && sfx=(--json --output-last-message "${OSRC_JOB_DIR:-$OSRC_HOME}/last.txt")
  # code_mode_host self-heal: disable when the host binary is absent (else file reads can hang).
  local cmh=(); _codex_code_mode_host || cmh=(-c features.code_mode_host=false)
  local eff=(); if [ -n "$EFFORT" ]; then eff=(-c "model_reasoning_effort=$EFFORT"); printf '>>> [effort] reasoning=%s (native: -c model_reasoning_effort)\n' "$EFFORT" >&2; fi
  # Guarantee the capture's parent dir exists and is private BEFORE the tee, else on a fresh
  # $OSRC_HOME the very first delegation's `tee "$cap"` fails, the capture is empty, and a real transport
  # failure (e.g. 429) is misclassified as a task failure with no escalation.
  local capdir="${OSRC_JOB_DIR:-$OSRC_HOME}"; mkdir -p -m 700 "$capdir" 2>/dev/null; chmod 700 "$capdir" 2>/dev/null || true
  # Refuse to invoke Codex unless the capture dir is verified writable. A silent
  # mkdir failure meant `tee "$cap"` produced an empty capture and a real transport failure (429) got
  # misclassified as a task failure with no escalation. Fail loud instead of running blind.
  { [ -d "$capdir" ] && [ -w "$capdir" ]; } || die "delegate_codex: capture dir not writable: $capdir — refusing (cannot capture output / classify transport failures reliably). Set OSRC_JOB_DIR/OSRC_HOME to a writable path."
  local cap="$capdir/.cxcap.$$"
  local m rc=1 ttier wrapped healed=0
  local _or_iso=(); [ "${OSRC_CODEX_USER_CONFIG:-0}" = "1" ] || _or_iso=(--ignore-user-config)
  for m in $(_or_chain "$tier"); do
    ttier="$(resolve_tier "$m" "")"
    wrapped="$(_build_prompt "$m" "$prompt" "")"
    _tier_banner "codex-openrouter" "$m" "$ttier" "$posture"
    # wire_api MUST be "responses" (Codex 0.144+ dropped chat completions); OpenRouter serves it.
    # Capture combined output (still shown via tee) so we can detect the tool-type 400 and self-heal.
    # ISOLATION (I1): the inline -c openrouter provider fully defines the lane, so don't load the
    # user's live ~/.codex config/MCP surface (avoids the interactive-MCP-auth wedge on a delegated
    # run). OPENROUTER_API_KEY comes from env, not config. Escape hatch: OSRC_CODEX_USER_CONFIG=1.
    codex exec --skip-git-repo-check ${_or_iso[@]+"${_or_iso[@]}"} ${cmh[@]+"${cmh[@]}"} ${eff[@]+"${eff[@]}"} "${sflag[@]}" ${sfx[@]+"${sfx[@]}"} \
         -c model_provider=openrouter \
         -c 'model_providers.openrouter.name="OpenRouter"' \
         -c 'model_providers.openrouter.base_url="https://openrouter.ai/api/v1"' \
         -c 'model_providers.openrouter.env_key="OPENROUTER_API_KEY"' \
         -c 'model_providers.openrouter.wire_api="responses"' \
         -m "$m" "$wrapped" 2>&1 | tee "$cap"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -eq 0 ]; then record_ledger codex "$m" "$ttier" "$tier" "$prompt"; break; fi
    if _is_tooltype_400 "$cap"; then
      # codex->cc drops the Codex OS sandbox (cc has none). Gate this downgrade exactly like
      # acceptEdits->bypassPermissions: explicit --allow-downgrade / OSRC_ALLOW_DOWNGRADE=1.
      if [ "${OSRC_ALLOW_DOWNGRADE:-0}" = "1" ]; then
        printf '>>> [SECURITY DOWNGRADE] codex+OpenRouter (%s): dropping the Codex sandbox and re-running the SAME model on the cc lane (Claude Code -> OpenRouter, standard tools) because --allow-downgrade/OSRC_ALLOW_DOWNGRADE=1.\n' "$m" >&2
        healed=1; break
      fi
      printf '>>> [outsourcerer] SECURITY DOWNGRADE: codex->cc self-heal would drop the sandbox; that requires --allow-downgrade. Re-run with --allow-downgrade to enable, or use a different lane/model.\n' >&2
      break
    fi
    # Only escalate on transport/infra failures; task failures (red tests, max-turns, etc.) stop here.
    if _is_transport_failure "$(cat "$cap" 2>/dev/null)" "$rc"; then
      echo "HINT: model '$m' failed (rc=$rc) on a transport/infra error; escalating to next in chain..." >&2
      continue
    fi
    # Mirror delegate_cc -- surface the task-failure output to STDERR so a caller that captured
    # stdout as the RESULT still sees the failure. Foreground stdout already showed it via `tee`, so
    # only re-emit when stdout is being captured (not a tty) to avoid double-printing interactively.
    [ -t 1 ] || cat "$cap" >&2
    break
  done
  rm -f "$cap" 2>/dev/null
  if [ "$healed" = "1" ]; then
    # Map the codex tier to a cc tier (cc has no OS sandbox; research/autonomous -> accept-edits).
    local cctier="$tier"; [ "$tier" = "autonomous" ] && cctier="accept-edits"
    PROVIDER=cc delegate_cc "$cctier" "${ORIGARGS[@]}"; return $?
  fi
  return "$rc"
}

# Route a one-shot delegation. THE MODEL CHOOSES THE LANE: an alias/id in the table
# routes to its native lane regardless of --provider; unknown ids / no -m route by --provider.
# Tiers: auto|accept-edits|autonomous|dangerous
route_delegate() {
  local tier="$1" verb="$2"; shift 2
  # Mutating verbs get the BUILD DISCIPLINE preamble (write early, don't over-explore). See _build_discipline.
  [ "$tier" = "auto" ] && export OSRC_BUILD_DISCIPLINE=0 || export OSRC_BUILD_DISCIPLINE=1
  # Recursion guard: a delegated model must NOT re-delegate (Sorcerer's-Apprentice fork bomb).
  # The child inherits OUTSOURCERER_DEPTH; if it re-enters this script the guard trips.
  : "${OUTSOURCERER_DEPTH:=0}"
  if [ "$OUTSOURCERER_DEPTH" -ge "${OUTSOURCERER_MAX_DEPTH:-1}" ]; then
    die "recursion guard: already delegating (OUTSOURCERER_DEPTH=$OUTSOURCERER_DEPTH). A delegate must not re-delegate. Override with OUTSOURCERER_MAX_DEPTH=N."
  fi
  export OUTSOURCERER_DEPTH=$((OUTSOURCERER_DEPTH + 1))

  # Preserve original argv for the devin lane (kept byte-identical: it re-parses via parse_model).
  local ORIG=("$@")
  _consume_flags "$@"   # sets MODEL / MODEL_EXPLICIT / TIER_FLAG / WITH_SPEC / REST (+ OSRC_TIER_OVERRIDE)

  # LOCAL lane short-circuit: a model prefixed ollama:/lmstudio:/lms:/local[:...], or --provider local.
  # Local models aren't in the alias table (they're whatever the user has pulled), so route them here.
  case "$PROVIDER:$MODEL" in
    local:*|*:ollama:*|*:lmstudio:*|*:lms:*|*:local|*:local:*) delegate_local "$tier"; return $? ;;
  esac

  RESOLVED_ID="$MODEL"; RESOLVED_LANE=""; TTIER=""
  # DROID/CURSOR engine lanes skip alias resolution entirely: the engine owns its model catalog
  # (incl. user-configured/BYOK models), so `-m glm` under --provider droid means DROID's "glm",
  # never our alias table's z-ai/glm-5.2. The skill adapts to the user's tools, not the reverse.
  if [ "$MODEL_EXPLICIT" = "1" ] && [ "$PROVIDER" != "droid" ] && [ "$PROVIDER" != "cursor" ]; then
    local row rest2
    row="$(resolve_model_row "$MODEL")"
    if [ -n "$row" ]; then
      RESOLVED_ID="${row%%|*}"; rest2="${row#*|}"; RESOLVED_LANE="${rest2%%|*}"; TTIER="${rest2#*|}"
    fi
  fi

  local disp=""
  if [ "$PROVIDER" = "droid" ] || [ "$PROVIDER" = "cursor" ]; then
    disp="$PROVIDER"
    # Fail FAST on a missing engine CLI -- before the cloud gate and before auto-detach would
    # otherwise bury this error inside a background job the user has to go dig out.
    case "$disp" in
      droid)  have droid || die "droid CLI not on PATH (Factory Droid lane). Install: https://docs.factory.ai/cli  (macOS/Linux: curl -fsSL https://app.factory.ai/cli -o droid-install.sh, inspect, run; Windows: native PowerShell installer). Then run 'droid' once to log in." ;;
      cursor) have cursor-agent || have agent || die "cursor-agent CLI not on PATH (Cursor lane). Install: macOS/Linux: curl https://cursor.com/install -fsS | bash after inspecting; Windows (native, no WSL): irm 'https://cursor.com/install?win32=true' | iex. Then 'cursor-agent login' once (or set CURSOR_API_KEY)." ;;
    esac
  elif [ "$PROVIDER" = "claudex" ]; then
    # CLAUDEX: a ChatGPT-sub model (sol/terra/luna/gpt-5.5) inside the Claude Code HARNESS via the
    # user's local CLIProxyAPI. Alias resolution DID run above (sol -> gpt-5.6-sol). Guardrails:
    #  - Claude-subscription models are REFUSED here: routing Claude OAuth through a third-party
    #    proxy breaks Anthropic's usage policy; the claude-native lane already serves them first-class.
    #  - no -m defaults to gpt-5.6-sol (the model this lane exists for).
    case "$RESOLVED_LANE" in
      cc) die "-m $MODEL is a Claude-subscription model; routing it through a third-party proxy breaks Anthropic's usage policy. Drop --provider claudex and run -m $MODEL on the claude-native lane (same harness, fully legit)." ;;
    esac
    [ "$MODEL_EXPLICIT" = "1" ] || RESOLVED_ID="gpt-5.6-sol"
    # Fail FAST (pre-cloud-gate, pre-auto-detach): a missing claude CLI or dead proxy must be an
    # instant pointer, not an error buried inside a detached background job.
    have claude || die "claudex lane needs the claude CLI on PATH."
    [ -n "${OSRC_JOB_DIR:-}" ] || _claudex_up || die "claudex lane: no CLIProxyAPI answering at $(_claudex_url) (or no api-key found). This lane rides a proxy YOU install and log into: https://github.com/router-for-me/CLIProxyAPI (then cli-proxy-api --codex-login). Set OSRC_CLAUDEX_URL / OSRC_CLAUDEX_TOKEN if yours is elsewhere. Meanwhile -m ${RESOLVED_ID} runs fine on the codex-native lane (drop --provider)."
    disp=claudex
  elif [ "$MODEL_EXPLICIT" = "1" ] && [ -n "$RESOLVED_LANE" ]; then
    case "$RESOLVED_LANE" in
      cx)  [ "$PROVIDER" = "cc" ] && die "gpt-5.6-* (Sol/Terra/Luna) is ChatGPT-backend-only; dispatching it via OpenRouter/cc 400s. Drop --provider and let '-m $MODEL' use the codex native lane (needs no OpenRouter key)."
           disp=cxnative ;;
      cc)  [ "$PROVIDER" = "codex" ] && die "$RESOLVED_ID is Claude-backend-only; it cannot run through Codex/OpenRouter. Drop --provider and let '-m $MODEL' use the claude native lane (uses your Claude subscription)."
           disp=ccnative ;;
      gm)  disp=gmnative ;;
      gi)  die "'$MODEL' ($RESOLVED_ID) is an image-generation model, not a text-delegation lane. Use the image subcommand instead: $0 image -m $MODEL \"<prompt>\" [out.png]" ;;
      ci)  die "'$MODEL' ($RESOLVED_ID) is an image-generation model, not a text-delegation lane. Use the image subcommand instead: $0 image -m $MODEL \"<prompt>\" [out.png]" ;;
      dv)  disp=devin ;;
      or)  case "$PROVIDER" in
             cc)    disp=ccor ;;
             codex) disp=codexor ;;
             *)     # availability-aware routing: default provider (devin) + an OpenRouter model that
                    # Devin ALSO serves -> use the Devin lane (has quota) instead of dying/forcing OpenRouter.
                    # This fixes `-m glm` hard-failing when the OpenRouter key is out of monthly quota.
                    local _dvm; _dvm="$(_devin_model_for "$MODEL")"
                    if [ -n "$_dvm" ]; then
                      printf '>>> [route] -m %s is served by BOTH OpenRouter and Devin; using the Devin lane (%s) on the default provider (Devin has quota). Force OpenRouter with --provider cc|codex.\n' "$MODEL" "$_dvm" >&2
                      # Rewrite the model token in ORIG so the Devin lane runs the Devin id, not the OR alias.
                      local _i; for _i in "${!ORIG[@]}"; do
                        case "${ORIG[$_i]}" in -m|--model) [ $((_i+1)) -lt ${#ORIG[@]} ] && ORIG[$((_i+1))]="$_dvm" ;; esac
                      done
                      RESOLVED_ID="$_dvm"; disp=devin
                    else
                      # AUTO-ROUTE: an OpenRouter-only model the active provider
                      # cannot serve should FOLLOW its lane automatically — the SKILL promise is "the
                      # alias picks the lane; no --provider needed." Don't die and make the user recall
                      # `--provider cc`; route to the cc transport (Claude Code -> OpenRouter) and say so.
                      printf '>>> [route] -m %s is an OpenRouter-only model; active provider (%s) cannot serve it — auto-routing to the OpenRouter lane (--provider cc). Force codex with --provider codex.\n' "$MODEL" "$PROVIDER" >&2
                      PROVIDER=cc; disp=ccor
                    fi ;;
           esac ;;
    esac
  else
    # no explicit -m (use provider default / chain) OR unknown id: route by --provider.
    case "$PROVIDER" in
      devin) disp=devin ;;
      cc)    disp=ccor ;;
      codex) disp=codexor ;;
      *)     die "unknown provider '$PROVIDER' (use: devin|cc|codex|droid|cursor|claudex|local)" ;;
    esac
  fi

  # Cloud gate wire-in: cloud disclosure + secret-scan gate. Local lanes were short-circuited above;
  # this is the SINGLE choke point after lane resolution, before delegate_* dispatch (no per-lane
  # bypass). The --cloud-ack flag is consumed by _consume_flags (leading flag only) which sets
  # OSRC_CLOUD_ACK -- NO string match on ORIG here: matching " --cloud-ack " anywhere would let a task
  # PROMPT containing that text silently bypass the gate (and left the flag in REST, leaking it).
  # SECURITY (CRITICAL): ALWAYS call _cloud_disclose -- the ACKED short-circuit lives
  # INSIDE it, AFTER _secret_scan. Guarding the CALL with `[ ACKED != 1 ]` let an inherited/exported
  # OSRC_CLOUD_ACKED=1 skip the credential hard-block entirely (a .env would ship to the cloud lane).
  # The disclosure notice is still suppressed for an already-acked process by the in-function return.
  # Guard the no-task case: on bash 3.2 (macOS default) "${REST[*]}" on an empty array trips `set -u`.
  # Fail with the clean contract message instead of a raw unbound-variable crash.
  [ "${#REST[@]}" -gt 0 ] || die "no task given (e.g. $0 $verb -m <model> \"<task>\")"
  _cloud_disclose "$disp" "$RESOLVED_ID" "${REST[*]:-}"

  # AUTO-DETACH: if non-interactive AND slow-lane, auto-promote to the bg path so a harness
  # tool-timeout can't kill the call mid-run. Reuses _bg_launch (same watchdog/status/result as `bg`).
  # The model tier (frontier/capable/mid/budget) drives the "slow" decision, NOT the verb tier.
  # Escape hatches: OSRC_NO_AUTODETACH=1 / --wait / --foreground forces foreground; OSRC_FORCE_AUTODETACH=1
  # forces detach (for testing). See _autodetach_should for the full trigger logic.
  local _ad_model_tier; _ad_model_tier="$(resolve_tier "$RESOLVED_ID" "${TTIER:-}")"
  if _autodetach_should "$disp" "$RESOLVED_ID" "$_ad_model_tier"; then
    _autodetach_run "$verb" ${ORIG[@]+"${ORIG[@]}"}
    return $?
  fi

  # The actual dispatch, wrapped so the FOREGROUND path is watchdog-guarded. Defined as a nested
  # fn so it still sees $disp/$tier/$ORIG (bash dynamic scope) when _fg_guard calls it.
  __osrc_fg_dispatch() {
    case "$disp" in
      devin)
        if [ "$tier" = "autonomous" ]; then delegate "autonomous" "--sandbox" ${ORIG[@]+"${ORIG[@]}"}   # OS sandbox, see header
        else delegate "$tier" "" ${ORIG[@]+"${ORIG[@]}"}; fi ;;
      ccor)     delegate_cc     "$tier" ${ORIG[@]+"${ORIG[@]}"} ;;
      codexor)  delegate_codex  "$tier" ${ORIG[@]+"${ORIG[@]}"} ;;
      cxnative) delegate_cxnative "$tier" ;;
      ccnative) delegate_ccnative "$tier" ;;
      gmnative) delegate_gmnative "$tier" ;;
      droid)    delegate_droid    "$tier" ;;
      cursor)   delegate_cursor   "$tier" ;;
      claudex)  delegate_claudex  "$tier" ;;
    esac
  }
  _fg_guard __osrc_fg_dispatch "$tier"
}

# Reset a TUI pane's input BEFORE typing into it. Two real failure modes this guards:
#  1) copy-mode: if the pane is in tmux copy-mode (any scroll/mouse event triggers it), send-keys
#     are consumed by copy-mode navigation and NEVER reach the program -- keystrokes silently vanish.
#  2) residual draft: send-keys -l appends to whatever text is already in the input line, so a stale
#     draft (e.g. an unsubmitted "commit this") corrupts the next prompt by concatenation.
# Safe to call when idle; harmless on an empty line. Call it before every programmatic send.
_tmux_reset_input() {
  local s="$1" aggressive="${2:-}"
  # Always safe: leave copy-mode (else keystrokes are eaten) and kill-line to wipe a stale input draft.
  # C-u only edits the input LINE; it does not cancel an in-progress model turn.
  [ "$(tmux display -p -t "$s" '#{pane_in_mode}' 2>/dev/null)" = "1" ] && tmux send-keys -t "$s" -X cancel 2>/dev/null || true
  tmux send-keys -t "$s" C-u 2>/dev/null || true       # kill-line: wipe any leftover input
  # Escape is DESTRUCTIVE in these TUIs -- while a turn is generating it interrupts/cancels it.
  # Only send it for an explicit `session clear` (aggressive), never on a routine `session send`.
  [ "$aggressive" = "aggressive" ] && tmux send-keys -t "$s" Escape 2>/dev/null || true
}

# ---- interactive tmux session (opt-in) ----
session() {
  if ! have tmux; then
    [ "$OSRC_PLATFORM" = "windows" ] && die "interactive 'session' mode needs tmux, which Git Bash doesn't ship. EVERYTHING ELSE works on Windows without WSL: use run/edit/yolo for one-shots and bg/fanout + status/watch for long or parallel work (same capability, supervised). If you really want session mode, install tmux via MSYS2 (pacman -S tmux) or use WSL."
    die "tmux not installed ($( [ "$OSRC_PLATFORM" = "mac" ] && echo 'brew install tmux' || echo 'apt/dnf install tmux')). Only 'session' needs it — bg/fanout cover the same ground supervised."
  fi
  local sub="${1:-}"; shift || true
  case "$sub" in
    start)
      parse_model "$@"
      # Validate the model token before it is interpolated into a tmux shell command.
      _validate_model_token "$MODEL"
      # Provider-aware interactive session: works for devin, codex (sol/terra/luna), and claude
      # (fable/opus/...), not just Devin. Each launches its own interactive TUI inside tmux; the generic
      # send/read/stop below drive any of them. Switch lane with --provider devin|codex|cc.
      local launch
      case "$PROVIDER" in
        devin|dv)
          need_devin; logged_in || die "Not logged in. Run:  ! devin auth login"
          launch="devin --model $MODEL --respect-workspace-trust false" ;;   # trust flag skips the blocking gate
        codex|cx)
          have codex || die "codex not on PATH (needed for a codex session)"
          local crow cid; crow="$(resolve_model_row "$MODEL")"; cid="${crow%%|*}"; [ -n "$cid" ] || cid="$MODEL"
          # The resolved codex model id is what enters the tmux command.
          _validate_model_token "$cid"
          local ccmh=""; _codex_code_mode_host || ccmh=" -c features.code_mode_host=false"  # self-heal in the TUI too
          # No `--cd "$PWD"` -- tmux new-session already starts the pane in $PWD (-c "$PWD").
          # Interpolating $PWD into this shell-command string was a directory-name injection vector
          # (a dir named `x"; touch /tmp/pwn; #` would break out when send-keys hands it to the shell).
          launch="codex -m $cid -s workspace-write$ccmh" ;;
        cc|claude)
          have claude || die "claude not on PATH (needed for a claude session)"
          # strip nested Claude Code env so a nested interactive claude authenticates via OAuth (same fix as the -p lane)
          launch="env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_EXECPATH claude --model $MODEL" ;;
        *) die "session start: provider '$PROVIDER' not supported for interactive sessions (use --provider devin|codex|cc)" ;;
      esac
      # Use has-session to avoid killing a concurrent session.
      if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo "Session '$SESSION_NAME' already exists. Use '$0 session stop' first, or reattach with 'tmux attach -t $SESSION_NAME'."
        return 0
      fi
      tmux new-session -d -s "$SESSION_NAME" -x 200 -y 50 -c "$PWD"
      tmux send-keys -t "$SESSION_NAME" "export PATH=\"\$HOME/.local/bin:\$PATH\"; clear; $launch" Enter
      echo "Started tmux session '$SESSION_NAME' running $PROVIDER (model: $MODEL) in $PWD."
      echo "Give it ~8s to boot, then:  $0 session read   |   $0 session send \"…\"   |   $0 session clear   |   $0 session model [name]   |   $0 session stop"
      ;;
    send)
      [ -n "${1:-}" ] || die "session send needs text"
      tmux has-session -t "$SESSION_NAME" 2>/dev/null || die "no session '$SESSION_NAME' (run: $0 session start)"
      _tmux_reset_input "$SESSION_NAME"          # cancel copy-mode + wipe residual draft, else keys vanish or concatenate
      tmux send-keys -t "$SESSION_NAME" -l "$*"
      sleep 0.5                                  # let the TUI debounce the pasted text before submitting
      tmux send-keys -t "$SESSION_NAME" Enter
      sleep 0.3; tmux send-keys -t "$SESSION_NAME" Enter 2>/dev/null || true   # second Enter: some TUIs need it to submit
      echo "sent. Read progress with: $0 session read"
      ;;
    read)
      tmux capture-pane -t "$SESSION_NAME" -p | grep -v '^[[:space:]]*$'
      ;;
    clear)
      tmux has-session -t "$SESSION_NAME" 2>/dev/null || die "no session '$SESSION_NAME' (run: $0 session start)"
      _tmux_reset_input "$SESSION_NAME" aggressive   # explicit reset: also sends Escape (may interrupt an active turn)
      echo "cleared input for '$SESSION_NAME' (copy-mode canceled + Escape + draft wiped). NOTE: Escape can interrupt an in-progress turn. Re-check with: $0 session read"
      ;;
    model)
      # Mid-session model switch is TUI-specific. Devin uses the opt+m (Meta-m) picker, wired here.
      # codex/claude have their own in-TUI switchers; for those, restart the session with a new -m.
      case "$PROVIDER" in
        devin|dv) : ;;
        *) die "mid-session model switch is wired for Devin only. For a $PROVIDER session, stop and restart with a new model:  $0 session stop && $0 --provider $PROVIDER session start -m <model>" ;;
      esac
      # Optional NAME filters the picker (it shows a "Type to search" box); Enter confirms.
      tmux has-session -t "$SESSION_NAME" 2>/dev/null || die "no session '$SESSION_NAME' (run: $0 session start)"
      tmux send-keys -t "$SESSION_NAME" Escape; sleep 1     # clear any pending input line
      tmux send-keys -t "$SESSION_NAME" M-m;   sleep 1      # opt+m -> open model picker
      if [ -n "${1:-}" ]; then tmux send-keys -t "$SESSION_NAME" -l "$1"; sleep 1; fi
      tmux send-keys -t "$SESSION_NAME" Enter
      echo "model switch sent${1:+ (filter: $1)}. Confirm with: $0 session read   (active model shows in the footer)."
      ;;
    stop)
      tmux kill-session -t "$SESSION_NAME" 2>/dev/null && echo "stopped '$SESSION_NAME'." || echo "no session '$SESSION_NAME'."
      ;;
    *)
      die "session subcommand: start | send \"text\" | read | clear | model [NAME] | stop"
      ;;
  esac
}

# ---- parity: sync Claude skills + local MCPs into Devin ----
parity() {
  need_devin
  echo "== Skills =="
  local src="$HOME/.claude/skills" dst="$HOME/.config/devin/skills" linked=0
  mkdir -p "$dst"
  if [ -d "$src" ]; then
    for d in "$src"/*/; do
      [ -d "$d" ] || continue
      [ -f "${d}SKILL.md" ] || continue
      ln -sfn "${d%/}" "$dst/$(basename "$d")" && linked=$((linked+1))
    done
  fi
  echo "  linked $linked Claude skill(s) -> $dst (symlinks, stay live)"

  # Plugin skills (compound-engineering/CE, token-optimizer, etc.) live in the plugin
  # cache, NOT ~/.claude/skills, so they were previously invisible to Devin. Sync the
  # LATEST version of each plugin's skills too. Top-level skills win on name collision.
  local pcache="$HOME/.claude/plugins/cache" plinked=0
  if [ -d "$pcache" ]; then
    local plug ver vdir sk name
    for plug in "$pcache"/*/*/; do            # <marketplace>/<plugin>/
      [ -d "$plug" ] || continue
      ver="$(ls -1 "$plug" 2>/dev/null | _vsort | tail -1)"   # latest semver dir
      [ -n "$ver" ] || continue
      vdir="${plug}${ver}/skills"
      [ -d "$vdir" ] || continue
      for sk in "$vdir"/*/; do
        [ -f "${sk}SKILL.md" ] || continue
        name="$(basename "$sk")"
        # A DANGLING symlink must NOT count as already-linked. Plugin caches are versioned, so every
        # plugin upgrade deletes the version directory an earlier parity run pointed at. Treating any
        # symlink as present made parity structurally unable to repair itself: the skills silently
        # disappeared from the delegate while this directory still looked fully populated, so the
        # delegate ran without the skills the host believes it has. Only a link that RESOLVES wins.
        [ -e "$dst/$name" ] && continue                          # live entry: first wins
        [ -L "$dst/$name" ] && rm -f "$dst/$name"                # dangling: replace, don't preserve
        ln -sfn "${sk%/}" "$dst/$name" && plinked=$((plinked+1))
      done
    done
  fi
  echo "  linked $plinked plugin skill(s) [latest version each] -> $dst"
  # Sweep anything still dangling (a skill deleted upstream, or a cache layout that moved). A stale
  # entry here is worse than a missing one: it makes the delegate look equipped when it is not.
  local _stale=0 _l
  for _l in "$dst"/*; do
    [ -L "$_l" ] || continue
    [ -e "$_l" ] && continue
    rm -f "$_l" && _stale=$((_stale+1))
  done
  [ "$_stale" -gt 0 ] && echo "  pruned $_stale dead link(s) whose source no longer exists"
  # The delegate should also be able to see THIS skill.
  [ -f "$HOME/.claude/skills/outsourcerer/SKILL.md" ] && ln -sfn "$HOME/.claude/skills/outsourcerer" "$dst/outsourcerer" 2>/dev/null || true

  # Antigravity host (bonus): Antigravity CLI (agy) loads SKILL.md-format skills from its own
  # skills dir (~/.gemini/antigravity/skills -> ~/.gemini/config/skills). If that dir exists,
  # mirror this ONE skill in too, so `agy` sees outsourcerer without a separate import step. Same
  # symlink mechanism as Devin. (Native alternative documented in SKILL.md: `agy plugin import
  # claude-code`.) Non-fatal, additive.
  local agdst="" self="$HOME/.claude/skills/outsourcerer"
  for c in "$HOME/.gemini/antigravity/skills" "$HOME/.gemini/config/skills"; do
    if [ -d "$c" ] && [ -w "$c" ]; then agdst="$c"; break; fi
  done
  if [ -n "$agdst" ] && [ -f "$self/SKILL.md" ]; then
    if ln -sfn "$self" "$agdst/outsourcerer" 2>/dev/null; then
      echo "  linked outsourcerer -> $agdst (Antigravity/agy will discover it)"
    else
      echo "  (could not link into Antigravity skills dir $agdst; use: agy plugin import claude-code)"
    fi
  else
    echo "  (Antigravity skills dir not found; if you use agy, run: agy plugin import claude-code)"
  fi

  echo "== MCP servers =="
  have jq || { echo "  jq not found; skipping MCP port (brew install jq)"; return 0; }
  local cj="$HOME/.claude.json"
  [ -f "$cj" ] || { echo "  no ~/.claude.json; nothing to port"; return 0; }
  local existing merged names
  existing="$(devin mcp list 2>/dev/null | awk '/•/{print $2}')"
  # Merge MCP servers across EVERY scope, global top-level + all project dirs, so this
  # works for any user regardless of where their MCPs are registered (nothing hardcoded).
  merged="$(jq -c '
    (.mcpServers // {}) as $top
    | reduce ((.projects // {}) | to_entries[]) as $p ($top; . + (($p.value.mcpServers) // {}))
  ' "$cj" 2>/dev/null)"
  names="$(printf '%s' "$merged" | jq -r 'keys[]?' 2>/dev/null)"
  [ -n "$names" ] || { echo "  no local MCP servers found in ~/.claude.json (any scope)"; return 0; }
  local s def type url cmd
  for s in $names; do
    if printf '%s\n' "$existing" | grep -qx "$s"; then echo "  = $s (already in Devin)"; continue; fi
    def="$(printf '%s' "$merged" | jq -c --arg s "$s" '.[$s]')"
    type="$(printf '%s' "$def" | jq -r 'if .type then .type elif .url then "http" else "stdio" end')"
    if [ "$type" = "http" ] || [ "$type" = "sse" ]; then
      url="$(printf '%s' "$def" | jq -r '.url // empty')"
      [ -n "$url" ] || { echo "  ! $s (http, no url) skipped"; continue; }
      if devin mcp add "$s" --transport "$type" --url "$url" --scope user >/dev/null 2>&1; then
        echo "  + $s ($type) -> $url"
      else
        echo "  ! $s ($type) FAILED, may need OAuth/headers; add manually"
      fi
    else
      cmd="$(printf '%s' "$def" | jq -r '.command // empty')"
      [ -n "$cmd" ] || { echo "  ! $s (stdio, no command) skipped"; continue; }
      # collect env (-e KEY=VALUE) and args
      local envargs=() aargs=() line
      while IFS= read -r line; do [ -n "$line" ] && envargs+=( -e "$line" ); done \
        < <(printf '%s' "$def" | jq -r '(.env // {}) | to_entries[]? | "\(.key)=\(.value)"')
      while IFS= read -r line; do aargs+=( "$line" ); done \
        < <(printf '%s' "$def" | jq -r '.args[]? // empty')
      if devin mcp add "$s" --scope user ${envargs[@]+"${envargs[@]}"} -- "$cmd" ${aargs[@]+"${aargs[@]}"} >/dev/null 2>&1; then
        echo "  + $s (stdio) -> $cmd ${aargs[*]+${aargs[*]}}"
      else
        echo "  ! $s (stdio) FAILED, add manually"
      fi
    fi
  done
  echo "  (host-locked claude.ai / chrome connectors are not in ~/.claude.json and are skipped automatically)"
}

doctor() {
  echo "== outsourcerer doctor (v$OSRC_VERSION) =="
  echo "  platform: $OSRC_PLATFORM$( [ "$OSRC_PLATFORM" = "windows" ] && echo ' (Git Bash — NO WSL needed. Works: run/edit/yolo/bg/fanout/status/doctor/advise. Not available: tmux session mode.)')"
  # VERSION-DRIFT check: the manifest, THIS running script, and any OTHER installed copy
  # (a stale standalone skill dir) can silently disagree — a user then runs old code missing every
  # recent fix. Flag any mismatch loudly. Best-effort; silent when nothing to compare.
  { local _dver _mf _sd _drift=""
    _mf="$(dirname "$SCRIPT_PATH")/../../../.claude-plugin/plugin.json"
    [ -f "$_mf" ] && have jq && _dver="$(jq -r '.version // empty' "$_mf" 2>/dev/null)"
    [ -n "$_dver" ] && [ "$_dver" != "$OSRC_VERSION" ] && _drift="  version DRIFT: running script v$OSRC_VERSION but plugin.json says v$_dver — bump one to match."
    # A second installed copy under ~/.claude/skills that isn't the one running now.
    _sd="$HOME/.claude/skills/outsourcerer/scripts/outsourcerer.sh"
    if [ -f "$_sd" ] && [ "$_sd" != "$SCRIPT_PATH" ]; then
      local _sv; _sv="$(grep -m1 '^OSRC_VERSION=' "$_sd" 2>/dev/null | cut -d'"' -f2)"
      [ -n "$_sv" ] && [ "$_sv" != "$OSRC_VERSION" ] && _drift="${_drift}
  version DRIFT: a SECOND copy at $_sd is v$_sv (this run is v$OSRC_VERSION) — /outsourcerer may load the stale one. Sync or remove it."
    fi
    # Version strings matching is NOT the same as the code matching. Two copies at the same version
    # with different content is the worse case: nothing looks wrong, and half your fixes are running
    # only in the copy you are not executing. Compare the bytes, not the label.
    if [ -f "$_sd" ] && [ "$_sd" != "$SCRIPT_PATH" ] && ! cmp -s "$_sd" "$SCRIPT_PATH"; then
      _drift="${_drift}
  install DRIFT: a second copy at $_sd differs from the running script. Same version, different code — one of them is missing fixes. Re-sync before trusting either."
    fi
    [ -n "$_drift" ] && printf '%s\n' "$_drift"
  }
  # State-home writability: THE silent killer under sandboxed harness shells. Report, don't die —
  # doctor's job is to diagnose.
  mkdir -p "$OSRC_HOME" 2>/dev/null
  if ( : > "$OSRC_HOME/.wtest" ) 2>/dev/null; then rm -f "$OSRC_HOME/.wtest" 2>/dev/null
    echo "  state home: $OSRC_HOME (writable — jobs/ledger/cache OK)"
  else
    echo "  state home: $OSRC_HOME NOT WRITABLE — every job will fail. Sandboxed shell? Allow writes to ~/.outsourcerer (Claude Code: settings.json sandbox allowWrite) or set OSRC_HOME to a writable dir."
  fi
  # Parity link health. Plugin caches are versioned, so an upgrade can leave every linked skill
  # pointing at a directory that no longer exists. The skills dir stays FULL and looks healthy while
  # the delegate silently runs without the toolkit you believe it has — invisible unless something
  # counts the dead links.
  { local _pd="$HOME/.config/devin/skills" _dead=0 _tot=0 _l
    if [ -d "$_pd" ]; then
      for _l in "$_pd"/*; do
        [ -e "$_l" ] || [ -L "$_l" ] || continue
        _tot=$((_tot+1)); [ -e "$_l" ] || _dead=$((_dead+1))
      done
      if [ "$_dead" -gt 0 ]; then
        echo "  parity: $_dead of $_tot linked skill(s) are DEAD links — the delegate cannot see them. Re-run: $0 parity"
      else
        echo "  parity: $_tot skill(s) linked into the devin lane, all resolving"
      fi
    fi
  } 2>/dev/null
  if [ -f "$OSRC_CONSENT_FILE" ]; then echo "  cloud consent: granted + remembered ($0 consent revoke to undo)"
  else echo "  cloud consent: not yet granted — first cloud delegation asks ONCE and remembers ($0 consent grant to pre-grant)"; fi
  local _dm; if _dm="$(_mode_read 2>/dev/null)"; then echo "  driving mode: $_dm ($0 mode status)"; else echo "  driving mode: NOT SET — the session-start menu will show (set: $0 mode auto|manual|hybrid)"; fi
  local _lim; _lim="$(_session_limits 2>/dev/null)"; echo "  session limits: ${_lim:-unavailable (no readable meter)}  · conserve line: ${OSRC_CONSERVE_THRESHOLD}% of the 5h window"
  echo "  active provider: $PROVIDER  (switch with --provider devin|cc|codex|droid|cursor|claudex|local or OUTSOURCERER_PROVIDER)"
  echo "  -- OpenRouter lanes (cc / codex) --"
  if [ -f "$HOME/.env" ] && grep -q "OPENROUTER_API_KEY" "$HOME/.env" 2>/dev/null; then echo "    openrouter key: present in ~/.env"; else echo "    openrouter key: MISSING from ~/.env"; fi
  have claude && echo "    claude (cc lane):    $(claude --version 2>/dev/null | head -1)" || echo "    claude (cc lane):    NOT on PATH"
  have codex  && echo "    codex  (codex lane): $(codex --version 2>/dev/null | head -1)"  || echo "    codex  (codex lane): NOT on PATH"
  echo "    model chain: ${OR_OFFLOAD_CHAIN:-$OR_CHAIN_DEFAULT}"
  local cred; cred="$(or_credits)"; [ -n "$cred" ] && echo "    openrouter credits: $cred"
  echo "  -- Native premium lanes (model-selected; ride your own subscription) --"
  echo "    codex-native (sol/terra/luna/gpt-5.5): $(have codex && echo 'codex present, auth = your ChatGPT login' || echo 'codex NOT on PATH')"
  if have codex; then _codex_code_mode_host \
    && echo "      code-mode-host: present (codex file-reading tool calls work)" \
    || echo "      code-mode-host: MISSING, self-healed (Outsourcerer runs codex with code_mode_host disabled so file reads do not hang; install codex-code-mode-host to ~/.local/bin to use the feature)"; fi
  echo "    claude-native (fable/opus/sonnet/haiku): $(have claude && echo 'claude present, auth = your Claude login' || echo 'claude NOT on PATH')"
  [ -n "${CLAUDECODE:-}" ] && echo "      note: inside Claude Code, this lane still runs a VERIFIED specific Claude model (env-cleaned, model checked against modelUsage). Safer than a native subagent, which can silently fall back to your default with no way to verify."
  if [ "${OSRC_DOCTOR_PING:-0}" = "1" ]; then
    echo "    (pinging native lanes, costs ~1 token each)"
    # --ignore-user-config: the diagnostic itself must not wedge on a user's interactive-auth MCP
    # server (auth survives the flag; this is exactly the isolation the delegate paths now use).
    have codex  && { codex exec --ignore-user-config --skip-git-repo-check --sandbox read-only -m gpt-5.6-luna "reply PONG" >/dev/null 2>&1 && echo "      codex-native luna: PONG (authenticated)" || echo "      codex-native luna: no reply (not authed / model unavailable)"; }
    have claude && { env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_EXECPATH claude -p --strict-mcp-config --mcp-config <(printf '{"mcpServers":{}}') --model haiku "reply PONG" >/dev/null 2>&1 && echo "      claude-native haiku: PONG (authenticated)" || echo "      claude-native haiku: no reply (not authed / model unavailable)"; }
    if have agy; then agy -p "reply PONG" --model "gemini-3.5-flash" --print-timeout 60s >/dev/null 2>&1 && echo "      antigravity-agy (keyless): PONG (Antigravity login active)" || echo "      antigravity-agy: no reply (open Antigravity / sign in once so agy inherits your login)"; fi
    have gemini && { gemini -p "reply PONG" --allowed-mcp-server-names __none__ --approval-mode default --model gemini-3.1-flash-lite >/dev/null 2>&1 && echo "      gemini-cli (api key): PONG (authenticated)" || echo "      gemini-cli: no reply (not authed / model unavailable)"; }
  else
    echo "    (set OSRC_DOCTOR_PING=1 to probe native lane auth with a 1-token ping)"
  fi
  echo "  -- Engine lanes (YOUR agent CLI + YOUR configured models, incl. BYOK) --"
  if have droid; then echo "    droid (Factory): $(droid --version 2>/dev/null | head -1 || echo present) — route: --provider droid [-m <your-model-name>] run \"task\". Uses your Factory plan / customModels in ~/.factory/settings.json (free/cheap BYOK lanes work as-is)."
  else echo "    droid (Factory): NOT on PATH — install: https://docs.factory.ai/cli (macOS/Linux/Windows-native)"; fi
  if have cursor-agent; then echo "    cursor-agent: $(cursor-agent --version 2>/dev/null | head -1 || echo present) — route: --provider cursor [-m <model>] run \"task\". Bills your Cursor subscription credits."
  else echo "    cursor-agent: NOT on PATH — install: curl https://cursor.com/install -fsS | bash (Windows native: irm 'https://cursor.com/install?win32=true' | iex), then cursor-agent login"; fi
  echo "  -- Claudex lane (GPT-5.6 Sol/Terra INSIDE the Claude Code harness, via YOUR local CLIProxyAPI) --"
  if have cliproxyapi || have cli-proxy-api || [ -f "${OSRC_CLAUDEX_CONFIG:-$HOME/.cli-proxy-api/config.yaml}" ]; then
    if _claudex_up 2>/dev/null; then
      echo "    claudex: READY — proxy answering at $(_claudex_url). Route: --provider claudex run [-m sol|terra|luna] \"task\" (Claude harness UX, bills your ChatGPT plan)."
      echo "      note: UNOFFICIAL community bridge (internal upstream endpoints, no rate limiting — heavy use risks provider-side limits). Claude-sub models are refused here by policy; codex CLI is still the lane for gpt-image."
    else
      echo "    claudex: proxy installed but NOT answering at $(_claudex_url) (start it, check api-keys in ~/.cli-proxy-api/config.yaml, or set OSRC_CLAUDEX_URL/OSRC_CLAUDEX_TOKEN)"
    fi
  else
    echo "    claudex: not set up (optional). It runs sol/terra/luna INSIDE Claude Code via a self-hosted proxy the USER installs + audits: https://github.com/router-for-me/CLIProxyAPI (then: cli-proxy-api --codex-login). Detect-only: outsourcerer never installs it. Official alternative: openai/codex-plugin-cc."
  fi
  echo "  -- Local inference lane (Ollama / LM Studio / llama.cpp, KEYLESS, PRIVATE, \$0 cash + \$0 plan) --"
  local _ld; if _ld="$(_local_detect 2>/dev/null)"; then
    local _lb="${_ld%%|*}" _lr="${_ld#*|}"; echo "    detected: ${_lr##*|} at $_lb (e.g. model '${_lr%%|*}'). Private, \$0. Route: -m ollama:<model> | -m local | --provider local \"<task>\""
    if _local_supports_responses "$_lb" 2>/dev/null; then echo "      agentic (tool use): YES via codex Responses, no install (run: research/edit -m local \"<task>\")"
    else echo "      agentic (tool use): via on-demand Anthropic<->OpenAI shim + Claude Code (lazy-launched only when you use research/edit -m local; needs python3 + a tool-capable model)"; fi
  else
    echo "    none detected (probed Ollama :11434, LM Studio :1234, llama.cpp :8080). Start one (e.g. 'ollama serve' + 'ollama pull qwen2.5-coder') or set OSRC_LOCAL_URL=http://host:port/v1. Driver: curl+jq (built in), TEXT delegation, no extra install."
  fi
  echo "  -- Gemini / Antigravity lane (gemini-pro/gemini-flash/gemini-flash-lite text, nano-banana image) --"
  # PRIMARY vehicle: agy (keyless). Detect + guide setup per this skill's revision.
  local gm_default; if [ -n "${OSRC_GEMINI_VEHICLE:-}" ]; then gm_default="$OSRC_GEMINI_VEHICLE (forced via OSRC_GEMINI_VEHICLE)"; elif have agy; then gm_default="agy (keyless)"; elif have gemini; then gm_default="gemini-cli (api key)"; else gm_default="NONE, install one below"; fi
  echo "    text vehicle in use: $gm_default"
  if have agy; then
    echo "    agy (Antigravity CLI, PRIMARY/keyless): v$(agy --version 2>/dev/null | head -1), auth = your Antigravity/Google app login (no API key)"
    # INSTALLED IS NOT READY. Reporting a lane as available because its binary prints a version is how
    # work gets routed to something that cannot answer: agy stays installed and authenticated-looking
    # while every request times out (expired app login, service trouble). A bounded real request is the
    # only thing that distinguishes the two. OSRC_DOCTOR_PROBE=0 skips it.
    if [ "${OSRC_DOCTOR_PROBE:-1}" = "1" ]; then
      local _pt _prc=0
      _pt="$(agy -p "reply with the single word: ok" --model gemini-3.5-flash --effort low \
              --print-timeout "${OSRC_DOCTOR_PROBE_TIMEOUT:-25s}" 2>&1)" || _prc=$?
      case "$_pt" in
        *[Oo][Kk]*) echo "    agy liveness: RESPONDS (probed just now with a real request)" ;;
        *timeout*)  echo "    agy liveness: INSTALLED BUT NOT ANSWERING — a real request timed out. Treat this lane as DOWN, not ready: sign in to the Antigravity app again, or force the API-key vehicle with OSRC_GEMINI_VEHICLE=gemini (needs GEMINI_API_KEY)." ;;
        *)          echo "    agy liveness: UNCLEAR (rc=$_prc) — $(printf '%s' "$_pt" | tr -d '\n' | cut -c1-120)" ;;
      esac
    fi
  else
    echo "    agy (Antigravity CLI, PRIMARY/keyless): NOT on PATH"
    echo "      install: curl -fsSL https://antigravity.google/cli/install.sh -o agy-install.sh (inspect it, then run: bash agy-install.sh)   (then open Antigravity once to sign in)"
  fi
  if have gemini; then
    echo "    gemini CLI (FALLBACK/api key): v$(gemini --version 2>/dev/null | head -1)"
  else
    echo "    gemini CLI (FALLBACK/api key): NOT on PATH -> npm install -g @google/gemini-cli"
  fi
  if [ -f "$HOME/.env" ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?(GEMINI_API_KEY|GOOGLE_API_KEY)=' "$HOME/.env" 2>/dev/null; then
    echo "    GEMINI_API_KEY: present in ~/.env (enables the gemini-cli fallback + image lane)"
  else
    echo "    GEMINI_API_KEY: MISSING from ~/.env, only needed for the fallback text vehicle and for 'image'/nano-banana (get one: https://aistudio.google.com/apikey)"
  fi
  echo "  -- Image generation (backend AUTO-RESOLVED: codex gpt-image-2 > nano-banana > OpenRouter) --"
  if _codex_image_available; then
    echo "    resolved image backend: codex gpt-image-2 (KEYLESS, your Codex/ChatGPT subscription)"
  elif have codex; then
    echo "    codex cli present but NOT ready for images -> run 'codex login', check 'codex features list' has image_generation + artifact"
  else
    echo "    codex cli (preferred image backend): NOT on PATH -> install OpenAI's Codex CLI (see its docs / npm install -g @openai/codex), then 'codex login'"
  fi
  if ! _codex_image_available; then
    if [ -f "$HOME/.env" ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?(GEMINI_API_KEY|GOOGLE_API_KEY)=' "$HOME/.env" 2>/dev/null; then
      echo "    resolved image backend: nano-banana / gemini-2.5-flash-image (GEMINI_API_KEY present)"
    elif [ -f "$HOME/.env" ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?OPENROUTER_API_KEY=' "$HOME/.env" 2>/dev/null; then
      echo "    resolved image backend: OpenRouter image model (OPENROUTER_API_KEY present, no Gemini key) -> x-ai/grok-imagine-image-quality"
    else
      echo "    resolved image backend: NONE, install+login codex (preferred, keyless), or add GEMINI_API_KEY / OPENROUTER_API_KEY to ~/.env"
    fi
  fi
  echo "    force a backend: $0 image -m gpt-image \"...\" out.png   |   -m nano-banana   |   -m <openrouter-image-id>"
  echo "    image lane (nano-banana): REST + GEMINI_API_KEY (no keyless path) -> $0 image -m nano-banana \"...\" out.png"
  echo "    tier cache: $( [ -f "$OSRC_MODELS_JSON" ] && echo "$OSRC_MODELS_JSON (refresh: $0 models --refresh)" || echo 'none, run: $0 models --refresh (name-regex fallback in use)')"
  echo "  -- Devin lane --"
  if have devin; then echo "  devin: $(devin --version 2>/dev/null)"; else echo "  devin: NOT INSTALLED"; echo "    install: curl -fsSL https://cli.devin.ai/install.sh -o devin-install.sh (inspect it, then run: bash devin-install.sh)"; [ "$PROVIDER" = "devin" ] && return 1 || return 0; fi
  if logged_in; then
    echo "  auth:  $(devin auth status 2>/dev/null | awk -F: '/Tier/{gsub(/^[ \t]+/,"",$2);print "logged in ("$2" tier)"}')"
  else
    echo "  auth:  NOT logged in -> run:  ! devin auth login"
  fi
  # Proactive diagnostics: a *_PROXY env var in this shell + devin present means devin's Rust TLS
  # client may reject the proxy cert (rustls OSStatus cert-verify), surfacing as a bare "Connection
  # error" ~100-160s in. Name it now so the failure is recognizable when it happens. Detect-only.
  if [ -n "${HTTPS_PROXY:-}${HTTP_PROXY:-}${ALL_PROXY:-}${https_proxy:-}${http_proxy:-}${all_proxy:-}" ]; then
    echo "  proxy: a *_PROXY env var is set in this shell — devin's Rust TLS client may reject the proxy cert (rustls OSStatus cert-verify error, surfaces as a bare 'Connection error' after ~100-160s). If devin-backed verbs fail that way, re-run with the sandbox/proxy disabled for that call."
  fi
  echo "  default model: $DEFAULT_MODEL"
  have jq   && echo "  jq:   $(jq --version 2>/dev/null) (needed for: jobs/status/advise/parity)" || echo "  jq:   not installed -> $( [ "$OSRC_PLATFORM" = "windows" ] && echo 'winget install jqlang.jq' || { [ "$OSRC_PLATFORM" = "mac" ] && echo 'brew install jq' || echo 'apt/dnf install jq'; }) (jobs/status/advise need it)"
  have tmux && echo "  tmux: $(tmux -V) (needed for: interactive session mode)"     || echo "  tmux: not installed ($( [ "$OSRC_PLATFORM" = "windows" ] && echo "no tmux on Git Bash — 'session' unavailable; bg/fanout cover it" || echo "brew/apt install tmux — only needed for 'session'"))"
  local lm; lm="$(live_models)"
  if [ -n "$lm" ]; then echo "  live models:"; printf '%s\n' "$lm" | tr ',' '\n' | sed 's/^/    /'
  else echo "  live models: (probe returned nothing, devin may be offline or changed its 'Available:' output)"; fi
  return 0
}

models() {
  if [ "${1:-}" = "--refresh" ]; then
    refresh_models
    echo
    echo "Alias table (model chooses the lane):"
    printf '%s\n' "$OSRC_MODEL_TABLE" | awk -F'|' 'NF==4{printf "  %-20s -> %-26s lane=%-3s tier=%s\n",$1,$2,$3,$4}'
    return 0
  fi
  need_devin
  echo "Live Devin models (selectable now):"
  local lm; lm="$(live_models)"
  [ -n "$lm" ] && printf '%s\n' "$lm" | tr ',' '\n' | sed 's/^[[:space:]]*/  /' \
    || echo "  (probe returned nothing, devin may be offline or changed its 'Available:' output)"
  cat <<'EOF'

Free-lane note (CHANGES OFTEN, verify, never assume):
  Open-weight models (glm*, deepseek*, kimi*, swe*) are usually the free / low-limit lane.
  Premium models (claude*, gpt*, gemini*) typically draw your Devin usage/ACUs faster.
  Pricing shifts frequently, confirm current cost at your Devin usage dashboard before
  routing heavy work to a premium model. Default here is glm-5.2 (currently a free lane).
EOF
}

# cmd_loop -- bounded loops. The ONE built-in shape is `verify`: delegate -> run an EXTERNAL check ->
# retry-with-feedback, on the cheapest model, until the check passes or a cap fires. Richer shapes
# (sweep / best-of-N / eval-optimize / council-build) are orchestrator recipes in references/loops.md,
# composed from the existing verbs — not a workflow engine here. Terminates into exactly one state:
# success (0) | blocked (3) | max_turns (2). State (each attempt + check output) lives on disk.
cmd_loop() {
  local shape="${1:-}"; [ $# -gt 0 ] && shift
  case "$shape" in
    verify) ;;
    ''|-h|--help|help) die "loop: the built-in shape is 'verify'. Usage: loop verify -m <model> --check \"<cmd>\" [--max N] [--verb edit|yolo] \"<task>\". Other shapes (sweep / best-of-N / council-build) are orchestrator recipes — see references/loops.md." ;;
    *) die "loop: unknown shape '$shape' (only 'verify' is built in; sweep/best-of-N/council-build are recipes in references/loops.md)." ;;
  esac
  local model="" check="" max="${OSRC_LOOP_MAX:-3}" verb=edit task=""
  while [ $# -gt 0 ]; do case "$1" in
    -m|--model) [ -n "${2:-}" ] || die "loop verify: -m needs a model"; model="$2"; shift 2 ;;
    --check)    [ -n "${2:-}" ] || die "loop verify: --check needs a command"; check="$2"; shift 2 ;;
    --max)      [ -n "${2:-}" ] || die "loop verify: --max needs a number"; max="$2"; shift 2 ;;
    --verb)     [ -n "${2:-}" ] || die "loop verify: --verb needs edit|yolo"; verb="$2"; shift 2 ;;
    --worktree) die "loop verify: --worktree is not supported yet. Isolation would have to be established by the loop itself (the delegate runs in the foreground here, and the acceptance check must run inside the same tree), so a half-wired flag would verify the wrong files. Run the loop inside a worktree you created, or use 'bg --worktree' for one-shot isolated work." ;;
    --)         shift; task="$*"; break ;;
    -*)         die "loop verify: unknown flag '$1'" ;;
    *)          task="$1"; shift ;;
  esac; done
  [ -n "$task" ]  || die "loop verify needs a task, e.g.: loop verify -m glm --check \"npm test\" \"make the auth tests pass\""
  [ -n "$check" ] || die "loop verify needs a --check command. External verification is MANDATORY — a loop that trusts the model's own 'done' is not a loop, it's a hope."
  case "$max" in ''|*[!0-9]*) die "loop verify: --max must be a positive integer" ;; esac
  [ "$max" -ge 1 ] 2>/dev/null || die "loop verify: --max must be >= 1"
  case "$verb" in edit|yolo) ;; *) die "loop verify: --verb must be edit or yolo (the loop mutates files to fix them)" ;; esac

  local lid ldir; lid="$(_new_job_id)"; ldir="$OSRC_HOME/loops/$lid"
  mkdir -p -m 700 "$ldir" 2>/dev/null || die "loop: cannot create loop dir under $OSRC_HOME/loops"
  { umask 077; printf 'task: %s\ncheck: %s\nmodel: %s\nmax: %s\nverb: %s\nstarted: %s\n' \
      "$task" "$check" "${model:-<default>}" "$max" "$verb" "$(date +%s)" > "$ldir/meta"; } 2>/dev/null || true
  echo "[loop verify] $lid — up to $max attempts on ${model:-default lane}; acceptance check: $check" >&2

  local attempt feedback="" prev_fail="" have_prev=0 state="max_turns" mflag=""
  [ -n "$model" ] && mflag="-m"
  for attempt in $(seq 1 "$max"); do
    echo "OSRC::PROGRESS $attempt/$max delegate+verify" >&2
    local aprompt="$task"
    [ -n "$feedback" ] && aprompt="$task

The previous attempt did NOT pass the acceptance check. Fix ONLY what the check reports; do not restyle unrelated code. Acceptance check output:
$feedback"
    # Delegate this attempt via the script itself (reuses all routing/consent/watchdog machinery).
    # OSRC_NO_AUTODETACH=1 is MANDATORY here, not a preference: a detached delegate returns a job id
    # immediately, so the acceptance check would run against files the delegate has not touched yet.
    # Every attempt would then see the same pre-edit failure, the stall guard would fire, and the loop
    # would report `blocked` while the real work landed in the background, unwatched. The loop is its
    # own supervisor and is the thing meant to be long-running, so it always waits in the foreground.
    OSRC_NO_AUTODETACH=1 "$SCRIPT_PATH" "$verb" ${mflag:+$mflag "$model"} "$aprompt" > "$ldir/attempt-$attempt.out" 2>&1 || true
    # Defense in depth: if a delegate ever detaches anyway, the check below would silently grade stale
    # files. Refuse to grade rather than emit a confident wrong verdict.
    if grep -aq '\[auto-detach\]' "$ldir/attempt-$attempt.out" 2>/dev/null; then
      state="blocked"
      echo "[loop verify] $lid: attempt $attempt detached to the background, so the acceptance check would grade work that has not happened yet. Refusing to grade. Inspect $ldir/attempt-$attempt.out." >&2
      break
    fi
    # Distinct BLOCKED terminal state: the delegate asked for a human / hit a wall — surface, don't grind.
    if [ "$(_last_marker "$ldir/attempt-$attempt.out")" = "OSRC::BLOCKED" ] || \
       [ "$(_last_marker "$ldir/attempt-$attempt.out")" = "OSRC::NEED_INPUT" ]; then
      state="blocked"; echo "[loop verify] $lid: delegate reported BLOCKED on attempt $attempt — stopping for a human." >&2; break
    fi
    # EXTERNAL verification (the model never judges itself).
    local cout crc; cout="$(bash -c "$check" 2>&1)"; crc=$?
    printf '%s' "$cout" > "$ldir/check-$attempt.out" 2>/dev/null || true
    if [ "$crc" -eq 0 ]; then state="success"; echo "[loop verify] $lid: acceptance check PASSED on attempt $attempt." >&2; break; fi
    # Stall guard: byte-identical check output on two consecutive attempts means the feedback is
    # not moving the delegate -> stop rather than burn the remaining budget on a spin. Keyed on a
    # seen-prior flag, NOT on prev_fail being non-empty — an empty check output (e.g. a bare
    # `false`) is still a repeatable failure that should trip the guard.
    if [ "$have_prev" = "1" ] && [ "$cout" = "$prev_fail" ]; then
      state="blocked"; echo "[loop verify] $lid: identical check failure two attempts running (no progress) — stopping to avoid a spin. Inspect $ldir, then steer or escalate a tier." >&2; break
    fi
    prev_fail="$cout"; have_prev=1; feedback="$cout"
  done
  printf '%s\n' "$state" > "$ldir/state" 2>/dev/null || true
  echo "[loop verify] $lid final: $state  ·  attempts + check output in $ldir" >&2
  echo "$state"
  case "$state" in success) return 0 ;; blocked) return 3 ;; *) return 2 ;; esac
}

main() {
  # Mint this run's marker id once, and export it so the prompt the delegate receives and every
  # supervisor that grades its output agree on the same value. A detached bg job re-enters this
  # script as a fresh process and inherits it; if it ever arrives unset, one is minted there and the
  # prompt/reader in THAT process still match each other.
  [ -n "${OSRC_MARK:-}" ] || OSRC_MARK="$(_new_mark)"
  export OSRC_MARK
  # GLOBAL flags are accepted in ANY order before the subcommand (and --provider/--cloud-ack are
  # ALSO accepted after it, via _consume_flags/parse_model). Audits showed a misplaced --cloud-ack
  # being read as an "unknown subcommand" and costing whole retry round-trips -- never again.
  while :; do
    case "${1:-}" in
      --provider) [ -n "${2:-}" ] || die "--provider requires a name (devin|cc|codex|droid|cursor|claudex|local)"
                  PROVIDER="$2"; shift 2 ;;
      --cloud-ack) export OSRC_CLOUD_ACK=1; shift ;;
      *) break ;;
    esac
  done
  local cmd="${1:-}"; shift || true
  # Fail fast + self-explaining if the state home is unwritable (sandboxed shell). Skipped for
  # help/version/doctor: those must still run so they can DIAGNOSE the problem.
  # Read-only handshake/status commands must still run in a sandbox (they only READ); mode setters
  # enforce their own write inside _mode_persist.
  # tap is exempt too: `tap run` fires on EVERY statusline render and MUST reach its guaranteed
  # passthrough even when OSRC_HOME is unwritable (a preflight die would silently kill the user's
  # real statusline). Its write paths self-guard. brief/mode are read-only/self-guarding likewise.
  case "$cmd" in ""|-h|--help|help|--version|-V|doctor|brief|mode|tap) ;; *) _state_home_preflight ;; esac
  case "$cmd" in
    --version|-V) echo "outsourcerer $OSRC_VERSION"; exit 0 ;;
    __runjob) run_job "$@" ;;                             # internal: detached supervised job (cmd_bg)
    __gencost) _or_gen_cost "$1"; echo ;;                 # internal test: real cost of one generation id
    __runcost) _or_run_cost "$1"; echo ;;                 # internal test: real cost of a bg out.log
    doctor)   doctor ;;
    brief)    cmd_brief ;;                                 # session-start handshake: lanes + limits + conserve + mode
    mode)     cmd_mode "$@" ;;                             # persisted copilot mode: status|auto|manual|hybrid|reset
    tap)      cmd_tap "$@" ;;                              # statusline limits tap: install|uninstall|status (universal limit-awareness)
    consent)  cmd_consent "$@" ;;                          # cloud-consent: status|grant|revoke (remembered ack)
    models)   models "$@" ;;
    run|explore) route_delegate "auto" "$cmd" "$@" ;;
    research)    route_delegate "autonomous" "$cmd" "$@" ;;      # exec tools inside a sandbox (devin/codex), see header
    edit)        route_delegate "accept-edits" "$cmd" "$@" ;;
    yolo)        route_delegate "dangerous" "$cmd" "$@" ;;
    bg)          cmd_bg "$@" ;;                            # background: detach a supervised job, print id
    fanout)      cmd_fanout "$@" ;;                        # parallel N-way multi-subagent (+ status|wait|collect|list)
    loop)        cmd_loop "$@" ;;                          # bounded delegate->check->retry loop (loop verify); recipes in references/loops.md
    status)      cmd_status "$@" ;;                        # job table / one job's state
    watch)       cmd_watch "$@" ;;                         # poll a job until terminal (or --for N)
    result)      cmd_result "$@" ;;                        # print a job's final message (last.txt)
    logs)        cmd_logs "$@" ;;                          # tail a job's raw log (forensics only)
    cancel)      cmd_cancel "$@" ;;                        # kill a job + mark canceled
    cleanup)     cmd_cleanup "$@" ;;                       # remove a job/fanout git worktree (conservative)
    gc)          cmd_gc "$@" ;;                            # remove old completed job dirs (gc --older-than DAYS)
    tab)         cmd_tab "$@" ;;                           # the Tab: ledger / savings summary
    estimate)    cmd_estimate "$@" ;;                      # quote table across the chain + Opus
    suggest|deals) cmd_suggest "$@" ;;                     # live cheap/free models per platform right now
    advise)      cmd_advise "$@" ;;                        # task-aware model recommendation with benchmark data
    second-opinion|second) second_opinion "$@" ;;         # 2 cheap models; disagree -> escalate
    image)       cmd_image "$@" ;;                         # Gemini text-to-image (nano-banana default); prints file path
    parity-codex)  parity_codex ;;                         # reverse bridge: Codex -> outsourcerer insource
    parity-droid)  parity_droid ;;                         # reverse bridge: Factory droid -> outsourcerer (global ~/.factory/AGENTS.md)
    parity-cursor) parity_cursor ;;                        # reverse bridge: Cursor -> outsourcerer (repo-root AGENTS.md)
    continue|cont)
      [ "$PROVIDER" = "devin" ] || die "continue is Devin-only for now (provider=$PROVIDER). For OR interactive follow-ups use the sibling tmux harness: scripts/run-or-{model,codex}.sh"
      continue_turn "$@" ;;
    session)
      session "$@" ;;   # provider-aware: devin | codex | cc (see session start)
    parity)
      [ "$PROVIDER" = "devin" ] || die "parity syncs into Devin only. cc inherits your Claude skills/MCP natively; codex uses its own AGENTS.md + MCP."
      parity ;;
    ""|-h|--help|help)
      sed -n '2,109p' "$0" | sed 's/^# \{0,1\}//'
      ;;
    *) case "$cmd" in
         -*) die "'$cmd' looks like a flag, not a subcommand. Global flags (--provider X, --cloud-ack) are accepted before OR after the subcommand, but a subcommand is required. Example: $0 run --provider cc --cloud-ack \"task\"" ;;
       esac
       die "unknown subcommand '$cmd' (try: doctor|brief|mode|consent|models|run|research|edit|yolo|bg|fanout|status|watch|result|logs|cancel|cleanup|tab|estimate|suggest|advise|second-opinion|image|continue|session|parity|parity-codex|parity-droid|parity-cursor; providers: devin|cc|codex|droid|cursor|claudex|local)" ;;
  esac
}
main "$@"
