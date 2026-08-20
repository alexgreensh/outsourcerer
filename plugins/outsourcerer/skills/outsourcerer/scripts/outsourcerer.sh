#!/usr/bin/env bash
# outsourcerer.sh, delegate subagent-style work to Devin CLI models (default GLM-5.2).
# Self-contained helper for the `outsourcerer` Claude Code skill.
#
# Subcommands:
#   doctor                         Preflight: devin installed? logged in? default model live?
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
#   session start|send|read|model|stop  Persistent interactive Devin TUI via tmux (opt-in).
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
# PROVIDER (offload backend), prepend `--provider NAME` before the subcommand, or set
# OUTSOURCERER_PROVIDER. Backends:
#   devin  (default)  Devin CLI, sandboxed exec + Devin's own subagent fan-out.
#   cc                Claude Code -> OpenRouter via ANTHROPIC_BASE_URL (Anthropic-compat, 1 hop).
#                     Inherits YOUR Claude skills / MCP / Task subagents for free.
#   codex             Codex `exec` -> OpenRouter (native OpenAI Responses API, 0 hops; best tool
#                     fidelity). Runs in Codex's own AGENTS.md + MCP ecosystem, not Claude's.
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
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

DEFAULT_MODEL="${OUTSOURCERER_MODEL:-glm-5.2}"

# Offload backend: devin (default) | cc (Claude Code->OpenRouter) | codex (Codex->OpenRouter).
PROVIDER="${OUTSOURCERER_PROVIDER:-devin}"
# OpenRouter escalation chain for cc/codex when no explicit -m is given (all support tool-calling).
OR_CHAIN_DEFAULT="tencent/hy3:free,z-ai/glm-5.2,deepseek/deepseek-v4-pro"

# Absolute path to THIS script (for the reverse bridge / parity-codex AGENTS.md snippet).
SCRIPT_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"

# ---- durable state home (jobs, model cache, ledger). NEVER /tmp. ----
OSRC_HOME="${OSRC_HOME:-$HOME/.outsourcerer}"
OSRC_JOBS="$OSRC_HOME/jobs"
OSRC_MODELS_JSON="$OSRC_HOME/models.json"
OSRC_LEDGER="$OSRC_HOME/ledger.jsonl"
# Any per-run MCP config temp is removed at script exit (only in the main shell, not in
# command-substitution subshells where the file may still be needed by a later claude invocation).
trap 'if [ "${BASH_SUBSHELL:-0}" -eq 0 ]; then rm -f "$OSRC_HOME/with-mcp-$$.json" 2>/dev/null; fi' EXIT
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

_OSRC_VERBS="run explore research edit yolo"
_is_verb() { case " $_OSRC_VERBS " in *" ${1:-} "*) return 0 ;; *) return 1 ;; esac; }

need_devin() {
  have devin || die "devin CLI not on PATH (~/.local/bin). Install: curl -fsSL https://cli.devin.ai/install.sh -o devin-install.sh (inspect it, then run: bash devin-install.sh)"
}

logged_in() { devin auth status 2>/dev/null | grep -qi "Logged in"; }

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
      --)                   shift; REST+=("$@"); break ;;
      *)                    REST+=("$1"); shift ;;
    esac
  done
}

# Which Devin model serves an OpenRouter-lane alias (cross-lane sibling), empty if none.
# Only GLM is dual-lane today (glm/z-ai/glm-5.2 on OpenRouter <-> glm-5.2 on Devin).
_devin_model_for() {
  case "$1" in
    glm|z-ai/glm-5.2|glm-5.2) printf 'glm-5.2' ;;
    *) printf '' ;;
  esac
}

# LIVE model list via an intentionally invalid model probe (cheap: errors before running a task).
# The probe model is invalid ON PURPOSE, so devin exits nonzero, `|| true` keeps pipefail from
# leaking that expected failure to the caller (otherwise `doctor` exits 1 on a clean run).
live_models() {
  { devin --model "__list__" -p "x" </dev/null 2>&1 | grep -i "^Available:" | sed 's/^Available:[[:space:]]*//'; } || true
}

# _utf8_guard <string> -> prints <string> on stdout, lossy-decoded to valid UTF-8 if it
# contained invalid bytes. The devin CLI (a Rust+clap binary) rejects any arg whose OsString
# is not valid UTF-8 with "error: invalid UTF-8 was detected in one or more arguments" (rc=2)
# — an opaque crash that does not name the prompt as the cause. The usual source is
# byte-truncation upstream of outsourcerer: `awk substr` / `cut -c` slicing a multibyte
# character mid-sequence leaves a lone start/continuation byte (e.g. em-dash E2 80 94 cut at
# byte 7 yields a lone E2), which is invalid UTF-8. We catch it at the dispatch boundary so
# the run proceeds with a visible warning instead of dying on an unattributed clap error.
# Note: devin's --prompt-file does NOT avoid this — its file-read also rejects invalid UTF-8
# ("stream did not contain valid UTF-8"), so the guard is needed regardless of channel.
#
# Happy path (valid UTF-8) returns the input UNTOUCHED via `printf '%s'` — no command-
# substitution newline stripping, no warning. Callers that want zero happy-path change should
# gate the call (see delegate/continue_turn): only route through `$(_utf8_guard ...)` when a
# strict iconv check fails, so valid prompts never pass through a `$(...)`.
#
# Opt out: OSRC_UTF8_GUARD=0. No iconv, or a libiconv without the //IGNORE extension (musl,
# some BSDs) -> best-effort passthrough (the strict check is portable; the lossy decode
# degrades to passthrough rather than corrupting).
_utf8_guard() {
  [ "${OSRC_UTF8_GUARD:-1}" = "0" ] && { printf '%s' "$1"; return 0; }
  command -v iconv >/dev/null 2>&1 || { printf '%s' "$1"; return 0; }
  # Happy path: strict UTF-8->UTF-8 round-trip exits 0 only on valid input. Portable
  # everywhere iconv exists (no //IGNORE needed). Returns input verbatim, no $() stripping.
  printf '%s' "$1" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && { printf '%s' "$1"; return 0; }
  # Invalid UTF-8: lossy-decode so dispatch proceeds instead of dying on clap's opaque rc=2.
  local clean
  clean="$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-8//IGNORE 2>/dev/null)"
  # //IGNORE unsupported (musl/some BSDs) -> iconv errors, clean is empty -> passthrough the
  # original so the real clap error surfaces (no silent corruption, just no guard here).
  # All-invalid input also lands here -> same honest passthrough.
  [ -z "$clean" ] && { printf '%s' "$1"; return 0; }
  printf '>>> [utf8] prompt contained invalid UTF-8 bytes — lossy-decoded so dispatch proceeds. Common cause: byte-truncation upstream (awk substr / cut -c slicing a multibyte character mid-sequence, leaving a lone continuation byte that the devin CLI rejects with "invalid UTF-8 was detected in one or more arguments"). Fix the upstream truncation (truncate by codepoint, not byte) to avoid garbled content. Suppress: OSRC_UTF8_GUARD=0.\n' >&2
  printf '%s' "$clean"
  return 0
}

# _utf8_guard_prompt <varname> : guard IN PLACE — reassign the named var only when its value
# is not valid UTF-8, so the happy path (valid prompt) is never touched by command
# substitution (no trailing-newline stripping, no subshell). The invalid path routes through
# _utf8_guard for the lossy decode + warning. Bash 3.2-safe (no nameref); uses eval with a
# controlled var name only.
_utf8_guard_prompt() {
  [ "${OSRC_UTF8_GUARD:-1}" = "0" ] && return 0
  command -v iconv >/dev/null 2>&1 || return 0
  local _v _val
  _v="$1"; eval "_val=\"\${$_v}\""
  [ -n "$_val" ] || return 0
  printf '%s' "$_val" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && return 0
  eval "$_v=\"\$(_utf8_guard \"\$_val\")\""
}

# delegate <perm> <sandbox-flag-or-empty> [-m MODEL] "<task>"
delegate() {
  local perm="$1"; shift
  local sandbox="${1:-}"; shift || true
  parse_model "$@"
  [ "${#REST[@]}" -gt 0 ] || die "no task prompt given"
  local prompt="${REST[*]}"
  _utf8_guard_prompt prompt
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
  return "$rc"
}

continue_turn() {
  parse_model "$@"
  [ "${#REST[@]}" -gt 0 ] || die "no follow-up prompt given"
  local prompt="${REST[*]}"
  _utf8_guard_prompt prompt
  need_devin
  logged_in || die "Not logged in. Run:  ! devin auth login"
  echo ">>> devin -c --model $MODEL -p (continue)" >&2
  # `continue` must NOT silently escalate a read-only conversation to accept-edits.
  # Devin -c inherits the existing conversation's permission mode; forcing accept-edits here
  # was a silent privilege escalation. Remove it.
  devin -c --model "$MODEL" -p "$prompt" </dev/null
}

# ---- OpenRouter backends (no proxy, no install), cc = Claude Code, codex = Codex ----
# OpenRouter natively serves BOTH the Anthropic Messages API (for cc) and the OpenAI Responses
# API (for codex), so each CLI talks to it without a translation server.
_or_load_key() {
  # Extract ONLY the OpenRouter key. NEVER `set -a; . ~/.env`, allexport would push every
  # other secret in ~/.env into the delegate's environment, exposing them to a third-party model.
  local _l
  _l="$(grep -E '^[[:space:]]*(export[[:space:]]+)?OPENROUTER_API_KEY=' "$HOME/.env" 2>/dev/null | tail -n1)"
  OPENROUTER_API_KEY="${_l#*OPENROUTER_API_KEY=}"
  OPENROUTER_API_KEY="${OPENROUTER_API_KEY%\"}"; OPENROUTER_API_KEY="${OPENROUTER_API_KEY#\"}"
  OPENROUTER_API_KEY="${OPENROUTER_API_KEY%\'}"; OPENROUTER_API_KEY="${OPENROUTER_API_KEY#\'}"
  [ -n "$OPENROUTER_API_KEY" ] || die "OPENROUTER_API_KEY not found in ~/.env (needed for --provider cc/codex)"
  export OPENROUTER_API_KEY
}

# ---- Gemini / Antigravity lane key ----
_gm_load_key() {
  # Extract ONLY the Gemini key. NEVER `set -a; . ~/.env`, same single-key-only rule as
  # _or_load_key above. Tries GEMINI_API_KEY first, then GOOGLE_API_KEY (gemini-cli's own
  # precedence is GOOGLE_API_KEY > GEMINI_API_KEY when both are set; here either satisfies us).
  local _l
  _l="$(grep -E '^[[:space:]]*(export[[:space:]]+)?GEMINI_API_KEY=' "$HOME/.env" 2>/dev/null | tail -n1)"
  GEMINI_API_KEY="${_l#*GEMINI_API_KEY=}"
  GEMINI_API_KEY="${GEMINI_API_KEY%\"}"; GEMINI_API_KEY="${GEMINI_API_KEY#\"}"
  GEMINI_API_KEY="${GEMINI_API_KEY%\'}"; GEMINI_API_KEY="${GEMINI_API_KEY#\'}"
  if [ -z "$GEMINI_API_KEY" ]; then
    _l="$(grep -E '^[[:space:]]*(export[[:space:]]+)?GOOGLE_API_KEY=' "$HOME/.env" 2>/dev/null | tail -n1)"
    GEMINI_API_KEY="${_l#*GOOGLE_API_KEY=}"
    GEMINI_API_KEY="${GEMINI_API_KEY%\"}"; GEMINI_API_KEY="${GEMINI_API_KEY#\"}"
    GEMINI_API_KEY="${GEMINI_API_KEY%\'}"; GEMINI_API_KEY="${GEMINI_API_KEY#\'}"
  fi
  [ -n "$GEMINI_API_KEY" ] || die "GEMINI_API_KEY (or GOOGLE_API_KEY) not found in ~/.env (needed for gemini-pro/gemini-flash/nano-banana). Get a key: https://aistudio.google.com/apikey"
  export GEMINI_API_KEY
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

# ---- the canonical OSRC:: progress protocol block, injected into raw/continue/tmux ----
osrc_protocol_block() {
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

# wrap_prompt <tier> <task> -> tier-appropriate wrapped prompt ({{TASK}} substituted literally).
wrap_prompt() {
  local tier="$1" task="$2" tmpl
  case "$tier" in
    raw)             printf '%s\n\n%s\n' "$task" "$(osrc_protocol_block)"; return ;;
    frontier|capable) tmpl="$(_wrap_frontier)" ;;   # capable = strong open-weight: trust it, thin wrapper
    budget)          tmpl="$(_wrap_budget)" ;;
    mid|*)           tmpl="$(_wrap_mid)" ;;
  esac
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
  if curl -fsS "https://openrouter.ai/api/v1/models" -o "$OSRC_MODELS_JSON.tmp" 2>/dev/null; then
    mv "$OSRC_MODELS_JSON.tmp" "$OSRC_MODELS_JSON"; echo "refreshed $OSRC_MODELS_JSON"
  else
    rm -f "$OSRC_MODELS_JSON.tmp"; echo "model refresh failed (offline?)" >&2; return 1
  fi
}

or_credits() {   # best-effort OpenRouter credit line; never fatal
  have curl && have jq || return 0
  _or_load_key 2>/dev/null || return 0
  curl -fsS -H "Authorization: Bearer $OPENROUTER_API_KEY" "https://openrouter.ai/api/v1/key" 2>/dev/null \
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
    c="$(curl -fsS -H "Authorization: Bearer $OPENROUTER_API_KEY" \
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

# _codex_rate_limits -> "5h%|wk%|5h_reset_epoch|wk_reset_epoch" from the newest Codex session
# rollout. Codex records the ChatGPT-plan rate-limit windows the API returns into every rollout, so
# this is the REAL cost of a "no cash" ChatGPT-sub run: it spends your finite 5-hour and weekly
# limits. Best-effort; empty when codex/jq/rollout unavailable.
_codex_rate_limits() {
  have jq || return 1
  local sdir="$HOME/.codex/sessions"; [ -d "$sdir" ] || return 1
  local newest; newest="$(ls -t "$sdir"/*/*/*/*.jsonl 2>/dev/null | head -1)"
  [ -n "$newest" ] || return 1
  local line; line="$(grep '"rate_limits"' "$newest" 2>/dev/null | tail -1)"
  [ -n "$line" ] || return 1
  printf '%s' "$line" | jq -r '
    ([.. | objects | select(has("rate_limits")) | .rate_limits] | last) as $r
    | select($r != null)
    | "\($r.primary.used_percent // "")|\($r.secondary.used_percent // "")|\($r.primary.resets_at // "")|\($r.secondary.resets_at // "")"
  ' 2>/dev/null | head -1
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

cmd_tab() {
  [ -f "$OSRC_LEDGER" ] || { echo "The Tab is empty (no offloads recorded yet)."; return 0; }
  have jq || { echo "jq needed for tab (brew install jq)"; return 0; }
  echo "== The Tab (outsourcerer ledger: $OSRC_LEDGER) =="
  jq -rs '
    # Three-way lane bucket (truthful accounting):
    #   FREE = local (your hardware): $0 cash AND $0 plan.  PLAN = native cx/cc/gm + keyless gpt-image.
    #   CASH = everything else (cc/codex->OpenRouter, gemini API, devin-paid).
    def bucket:
      (.lane // "") as $l | (.provider // "") as $p | (.verb // "") as $v
      | if ($l == "local") or ($p == "local") then "free"
        elif ($l | test("^(cx|cc|gm)$")) or ($p | test("codex-native|claude-native|antigravity")) or ($v == "image" and $p == "codex") then "plan"
        else "cash" end;
    def realcost: (.cost_usd // "") as $c
      | if ($c == "") or ($c | startswith("~")) then null else ($c | tonumber? // null) end;
    def estcost:  (.cost_usd // "") as $c
      | if ($c | startswith("~")) then ($c[1:] | tonumber? // null) else null end;
    ([ .[] | select(bucket=="cash") ]) as $cashlanes
    | (([ $cashlanes[] | realcost | select(. != null) ] | add) // 0) as $cash
    | (([ $cashlanes[] | estcost  | select(. != null) ] | add) // 0) as $est
    | ([ $cashlanes[] | select((.cost_usd // "") == "") ] | length) as $unmeasured
    | ([ .[] | select(bucket=="plan") ] | length) as $subs
    | ([ .[] | select(bucket=="free") ] | length) as $free
    | "runs recorded          : \(length)",
      "cash billed (measured)  : $\($cash)   (REAL per-generation OpenRouter cost, captured on bg runs)",
      (if $est > 0 then "cash (harness estimate) : ~$\($est)   (bg run offline, could not read OpenRouter; estimate only)" else empty end),
      "cash lanes, est-only    : \($unmeasured) run(s)   (foreground; run via bg to capture real $)",
      "on your subscription    : \($subs) run(s)  , $0 cash, but spent your ChatGPT / Claude / Antigravity PLAN LIMITS",
      (if $free > 0 then "on your hardware (local): \($free) run(s)  , $0 cash AND $0 plan, fully private" else empty end),
      "by model:",
      (group_by(.model)[] | "  \(.[0].model)  \(length) run(s)")
  ' "$OSRC_LEDGER" 2>/dev/null || echo "(ledger parse error)"
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

# =============================================================================
# LIVENESS / SUPERVISOR + BACKGROUND JOBS.
# =============================================================================
_descendants() {   # echo ALL descendant pids of $1 (recursive, parent-before-child order)
  local p
  for p in $(pgrep -P "$1" 2>/dev/null); do echo "$p"; _descendants "$p"; done
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
  local pid=$! t0 last_size=0 last_change now size idle age
  t0=$(date +%s); last_change=$t0
  echo "$pid" > "$jd/pid"
  # Exploration-spiral guard: a mutating verb that reads/greps forever grows the log, so the
  # byte-growth timer never trips. Track WRITES too; a mutating job with 0 writes past the window is
  # flagged "exploring?" (visible in status/watch) so the orchestrator can steer instead of cancelling
  # blind. Not killed — late-writers exist; the hard timeout still backstops.
  local verb=""; [ -f "$jd/meta.json" ] && verb="$(jq -r '.verb // ""' "$jd/meta.json" 2>/dev/null)"
  local mutating=0; case "$verb" in edit|research|yolo) mutating=1 ;; esac
  local nww="${OSRC_NOWRITE_WARN:-180}"
  while kill -0 "$pid" 2>/dev/null; do
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
    if [ "$age" -ge "$hard" ]; then
      echo timeout > "$jd/status"; _kill_tree "$pid"; echo 124 > "$jd/exit"; return 124
    fi
    if [ "$idle" -ge "$kill_after" ]; then
      echo wedged > "$jd/status"; _kill_tree "$pid"; echo 125 > "$jd/exit"; return 125
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
  local last; last="$(grep -aoE 'OSRC::(DONE|BLOCKED|NEED_INPUT)' "$jd/out.log" 2>/dev/null | tail -1)"
  case "$last" in
    OSRC::BLOCKED|OSRC::NEED_INPUT) echo blocked > "$jd/status"; return 3 ;;
  esac
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
      [ "$mk" = 0 ] && grep -qaE 'OSRC::(DONE|BLOCKED|NEED_INPUT)' "$cap" 2>/dev/null && mk=$now
      if [ "$mk" != 0 ] && [ $((now-mk)) -ge "$tdl" ]; then echo teardown > "$hit"; _kill_tree "$prod"; break; fi
      if [ $((now-t0)) -ge "$hard" ];               then echo hard     > "$hit"; _kill_tree "$prod"; break; fi
    done ) & local gd=$!
  trap 'echo interrupt > "'"$hit"'"; _kill_tree "'"$prod"'" 2>/dev/null; kill "'"$gd"'" "'"$tp"'" 2>/dev/null; rm -f "'"$base"'".* 2>/dev/null' INT TERM
  wait "$prod" 2>/dev/null
  kill "$gd" 2>/dev/null; wait "$gd" 2>/dev/null; wait "$tp" 2>/dev/null
  trap - INT TERM
  export OSRC_FG_GUARD_ACTIVE=0
  local rc hval lastmark; rc="$(cat "$rcf" 2>/dev/null || echo 124)"; hval="$(cat "$hit" 2>/dev/null || echo)"
  lastmark="$(grep -aoE 'OSRC::(DONE|BLOCKED|NEED_INPUT)' "$cap" 2>/dev/null | tail -1)"
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
      --cloud-ack) export OSRC_CLOUD_ACK=1; return 0 ;;
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
    case "$ans" in y|Y|yes|YES) export OSRC_CLOUD_ACK=1; return 0 ;; esac
    die "CLOUD GATE: bg/fanout cloud disclosure declined -- refusing. Re-run with --cloud-ack / OSRC_CLOUD_ACK=1, or use a local (ollama/lmstudio) lane."
  fi
  die "CLOUD GATE: bg/fanout to a cloud lane needs an explicit ack in a non-interactive context. Pass --cloud-ack or set OSRC_CLOUD_ACK=1 (local ollama/lmstudio lanes are exempt)."
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
  if ! echo running > "$jd/status" 2>/dev/null; then
    rm -rf "$jd" 2>/dev/null; echo "bg: cannot write job status under $jd (filesystem full/unwritable?)" >&2; return 1
  fi
  nohup "$SCRIPT_PATH" __runjob "$id" "$PROVIDER" "$@" >/dev/null 2>&1 &
  printf '%s' "$id"
}

# bg [--provider X already parsed] [--worktree] <verb> [flags] "task" -> detach a supervised job, print id.
cmd_bg() {
  [ "${1:-}" = "--worktree" ] && { export OSRC_WORKTREE=1; shift; }   # opt-in git-worktree isolation
  [ $# -gt 0 ] || die "bg needs a verb + task (e.g. bg run -m hy3 \"...\")"
  _is_verb "${1:-}" || die "bg needs a verb first ($_OSRC_VERBS), e.g. bg run -m <model> \"task\" — got '${1:-}'"
  _bg_cloud_preack "$@"   # T3/#1: ack in the PARENT so a refusal `die`s the whole command (not just a subshell)
  local id; id="$(_bg_launch "$@")"
  [ -n "$id" ] || die "bg: launch failed -- no job id was minted (nothing was started)."
  echo "$id"
  echo "[outsourcerer] job $id launched (provider=$PROVIDER). Poll: $0 status $id  |  read: $0 result $id" >&2
}

# AUTO-DETACH (D3): a non-interactive slow-lane foreground run blocks until the model finishes (3-5 min
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
  if _wl="$(_worktree_setup "$id")"; then
    wt="${_wl%%$'\t'*}"; _wl="${_wl#*$'\t'}"; wbr="${_wl%%$'\t'*}"; wbase="${_wl##*$'\t'}"
    # If cd fails, DON'T run in the old cwd while pretending to be isolated — clear worktree state so the
    # job runs (unisolated) in the normal checkout and no bogus worktree.json/cleanup target is recorded.
    if ! cd "$wt" 2>/dev/null; then
      echo "[outsourcerer] worktree cd failed for $id; running in the normal checkout (not isolated)." >&2
      wt=""; wbr=""; wbase=""
    fi
  fi
  # peek model/tier for windows + meta (non-fatal)
  _consume_flags "$@" 2>/dev/null || true
  local row id2 ttier="" tier lane=""
  row="$(resolve_model_row "$MODEL")"; id2="$MODEL"
  # row is "resolved-id|lane|tier" (see resolve_model_row). Capture the LANE (middle field) too --
  # meta previously recorded only provider (the ORIGINAL provider, e.g. devin), which mislabels a
  # plan lane (gm/cx/cc) as a cash lane in the Tab. Persist the resolved lane so accounting is truthful.
  [ -n "$row" ] && { id2="${row%%|*}"; ttier="${row##*|}"; lane="$(printf '%s' "$row" | awk -F'|' '{print $2}')"; }
  lane="$(_effective_lane "$lane" "$prov" "$MODEL" "$MODEL_EXPLICIT")"
  tier="$(resolve_tier "$id2" "$ttier")"
  local wins warn kill hard; wins="$(_tier_windows "$tier")"; warn="${wins%% *}"; hard="${wins##* }"; kill="$(echo "$wins" | awk '{print $2}')"
  if have jq; then
    jq -cn --arg id "$id" --arg p "$prov" --arg v "$verb" --arg m "$id2" --arg t "$tier" --arg lane "$lane" \
       --arg cwd "$PWD" --argjson st "$(date +%s)" --arg wt "$wt" --arg wbr "$wbr" --arg wbase "$wbase" \
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
      real_cost="0.000000"   # no OpenRouter generation in the stream => no-cash (native/keyless) lane
    fi
  fi
  [ -n "$real_cost" ] && OSRC_LEDGER_FORCE=1 record_ledger "$prov" "$id2" "$tier" "$verb" "job:$id" "$real_cost" "$lane"
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
  printf 'R%s W%s B%s' "$r" "$w" "$b"
  # A mutating job (edit/research/yolo) that has read/bashed for a while with ZERO writes is very
  # likely stuck exploring — flag it so the orchestrator can steer instead of cancelling blind.
  export _OSRC_LASTW="$w"
}

_status_line() {
  local id="$1" jd="$OSRC_JOBS/$1" st model started now age prog acts verb flag=""
  [ -d "$jd" ] || { echo "no such job: $1" >&2; return 1; }
  st="$(cat "$jd/status" 2>/dev/null || echo '?')"
  model="$(_job_field "$id" '.model')"
  started="$(_job_field "$id" '.started')"; [ "$started" = "?" ] && started=0
  now=$(date +%s); age=$(( now - started ))
  prog="$(tail -1 "$jd/progress" 2>/dev/null)"
  case "$prog" in *OSRC::*) prog="OSRC::$(printf '%s' "${prog##*OSRC::}" | tr -d '"\\' )" ;; esac
  acts="$(_job_acts "$jd" 2>/dev/null)"
  verb="$(_job_field "$id" '.verb')"
  case "$verb" in edit|research|yolo)
    [ "${_OSRC_LASTW:-1}" = "0" ] && [ "$age" -gt "${OSRC_NOWRITE_WARN:-180}" ] && [ "$st" = "running" ] && flag=" !exploring(0-writes)" ;;
  esac
  prog="$(printf '%s' "$prog" | cut -c1-46)"
  printf '%-22s %-8s %-6s %-16s %-12s %s\n' "$id" "$st" "${age}s" "$model" "${acts:-—}$flag" "$prog"
}

# _job_json <id> [label] -> one job as a stable JSON object (orchestrator control plane, schema v1).
# Built from the metadata that already exists on disk; unknown fields are null (never omitted).
_job_json() {
  local id="$1" lbl="${2:-}" jd="$OSRC_JOBS/$1" L
  [ -d "$jd" ] && have jq || return 1
  [ -f "$jd/meta.json" ] || return 1
  L="$jd/out.log"
  local st exitc last r=0 w=0 b=0 rp=""
  st="$(cat "$jd/status" 2>/dev/null || echo unknown)"
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
  local t0; t0=$(date +%s); local last=""
  while :; do
    local st; st="$(cat "$jd/status" 2>/dev/null || echo '?')"
    [ "$st" != "$last" ] && { _status_line "$id"; last="$st"; }
    case "$st" in done|done?|failed|blocked|timeout|wedged|canceled|permission-blocked) break ;; esac
    [ "$forsec" -gt 0 ] && [ $(( $(date +%s) - t0 )) -ge "$forsec" ] && break
    sleep "${OSRC_POLL:-10}"
  done
}

cmd_result() {
  local id="${1:-}"; [ -n "$id" ] || die "result needs a job id"
  local jd="$OSRC_JOBS/$id"; [ -d "$jd" ] || die "no such job: $id"
  if [ -s "$jd/last.txt" ]; then cat "$jd/last.txt"; else tail -n 40 "$jd/out.log" 2>/dev/null; fi
}

cmd_logs() {
  local id="${1:-}"; [ -n "$id" ] || die "logs needs a job id"
  local n=60; [ "${2:-}" = "-n" ] && n="${3:-60}"
  tail -n "$n" "$OSRC_JOBS/$id/out.log" 2>/dev/null || die "no log for $id"
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
    case "$st" in done|'done?'|failed|blocked|timeout|wedged|canceled|permission-blocked) ;;
      *) skipped=$((skipped+1)); continue ;;
    esac
    mtime=$(stat -f %m "$d" 2>/dev/null || stat -c %Y "$d" 2>/dev/null || echo "")
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
    st="$(cat "$OSRC_JOBS/$jid/status" 2>/dev/null || echo running)"
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
    started="$(_job_field "$jid" '.started')"; [ "$started" = "?" ] && started=0
    now=$(date +%s); age=$(( now - started ))
    prog="$(tail -1 "$jd/progress" 2>/dev/null)"
    # stream-json out.log makes progress a raw JSON blob; surface the human OSRC:: line and truncate.
    case "$prog" in *OSRC::*) prog="OSRC::$(printf '%s' "${prog##*OSRC::}" | tr -d '"\\')" ;; esac
    prog="$(printf '%s' "$prog" | cut -c1-72)"
    printf '%-24s %-9s %-7s %-22s %s\n' "$jid" "$st" "${age}s" "$label" "$prog"
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
  echo "[outsourcerer] fanout $gid: $(_fanout_running "$gid") still running." >&2
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
  echo "[outsourcerer] collected $n agent outputs -> $out  (per-agent: $gd/findings/)" >&2
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
      --cloud-ack)    export OSRC_CLOUD_ACK=1; shift ;;   # T3/#2: documented non-interactive cloud ack for fanout
      --)             shift; inline=("$@"); break ;;
      *) die "fanout: unknown flag '$1' (sources: --agents DIR | --tasks FILE | -- \"t1\" \"t2\"; knobs: -m --effort --tier --provider --with --verb --max --preamble --sub --task \"<t>\" --route 'pat=model,...' --worktree; routing precedence: -m > --route > agent frontmatter > default; --worktree isolates each job in its own git worktree, remove with 'cleanup <id|gid> [--force]')" ;;
    esac
  done
  _is_verb "$verb" || die "fanout --verb must be one of: $_OSRC_VERBS (got '$verb')"

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
  # AUTO-DETACH (D3): second-opinion runs 2-3 sequential cloud API calls (can take 2-5 min).
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
  if [ -n "$n1" ] && [ "$n1" = "$n2" ]; then
    echo "== CONSENSUS ($m1 == $m2), no escalation =="
    printf '%s\n' "$a1"; return 0
  fi
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
  # Effort on the Gemini lane is ADVISORY: neither agy nor gemini-cli exposes a reasoning-effort knob
  # today, so we inject it as a prompt directive and say so (never silently dropped).
  if [ -n "$EFFORT" ]; then
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
    agy -p "$wrapped" ${aflag[@]+"${aflag[@]}"} --model "$atok" --print-timeout "${OSRC_AGY_PRINT_TIMEOUT:-5m}" || rc=$?
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
  local resp; resp="$(curl -fsS -X POST \
    "https://generativelanguage.googleapis.com/v1beta/models/$id:generateContent" \
    -H "x-goog-api-key: $GEMINI_API_KEY" -H 'Content-Type: application/json' \
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
  local resp; resp="$(curl -fsS -X POST "https://openrouter.ai/api/v1/chat/completions" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg m "$id" --arg p "$prompt" '{model:$m,messages:[{role:"user",content:$p}],modalities:["image","text"]}')" 2>/dev/null)" \
    || die "OpenRouter image API call failed (network / auth / model id?)"
  local url; url="$(printf '%s' "$resp" | jq -r '.choices[0].message.images[0].image_url.url // empty' 2>/dev/null)"
  [ -n "$url" ] || die "no image returned from OpenRouter (check OPENROUTER_API_KEY / model id). Raw response (truncated): $(printf '%s' "$resp" | head -c 300)"
  case "$url" in
    data:*base64,*) printf '%s' "${url#*base64,}" | base64 -d > "$out" 2>/dev/null || die "failed to decode/write image to $out" ;;
    http*)          curl -fsS "$url" -o "$out" 2>/dev/null || die "failed to download image from $url" ;;
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
  local prompt="${1:-}" d
  for d in ${OSRC_PROTECTED_PATHS:-"$HOME/.claude" "$HOME/.codex" "$HOME/.config"}; do
    case "$PWD/" in "$d"/*) return 0 ;; esac
    case "$prompt" in *"$d"*) return 0 ;; esac
  done
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
    ccor|codexor|ccnative|cxnative|gmnative|devin) return 0 ;;
    *) return 1 ;;
  esac
}

# _secret_scan <prompt> -> best-effort, gitignore-aware (KTD2). Hard-dies if a REAL credential
# file sits inside the delegated scope (cwd top-level + .aws). Reports (via OSRC_SECRET_HIT_COUNT) any
# high-signal pattern found in the prompt or a --with file, but does NOT hard-block on a regex
# hit alone (avoid crying wolf); only an actual credential FILE hard-blocks.
_secret_scan() {
  local prompt="${1:-}" f scan="$1"
  # (1) hard block: an actual credential file in scope.
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
  _secret_scan "$prompt"                             # dies here if a real cred file is in scope
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
  # acknowledge: env/flag ack, else interactive prompt, else fail-closed refuse.
  if [ "${OSRC_CLOUD_ACK:-0}" = "1" ]; then
    export OSRC_CLOUD_ACKED=1; return 0
  fi
  if [ -t 0 ] && [ -t 2 ]; then
    printf '>>>   Acknowledge cloud disclosure? [y/N] ' >&2
    local ans=""; IFS= read -r ans || ans=""
    case "$ans" in y|Y|yes|YES) export OSRC_CLOUD_ACKED=1; return 0 ;; esac
    die "CLOUD GATE: disclosure declined interactively — refusing cloud route. Re-run with OSRC_CLOUD_ACK=1 or --cloud-ack."
  fi
  die "CLOUD GATE: cloud disclosure requires explicit ack in non-interactive mode — refusing. Set OSRC_CLOUD_ACK=1 or pass --cloud-ack. (Local ollama/lmstudio lanes skip this gate entirely.)"
}

delegate_cc() {
  local tier="$1"; shift
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
    "${envp[@]}" claude -p ${bare[@]+"${bare[@]}"} ${sfx[@]+"${sfx[@]}"} ${CC_MCP_FLAGS[@]+"${CC_MCP_FLAGS[@]}"} ${tools[@]+"${tools[@]}"} --permission-mode "$emode" "$wrapped" 2>"$cap"
    rc=$?
    chmod 600 "$cap" 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then record_ledger cc "$m" "$ttier" "$tier" "$prompt"; break; fi
    # Only escalate on transport/infra failures; task failures (red tests, max-turns, etc.) stop here.
    if _is_transport_failure "$(cat "$cap" 2>/dev/null)" "$rc"; then
      echo "HINT: model '$m' failed (rc=$rc) on a transport/infra error; escalating to next in chain..." >&2
      continue
    fi
    # Surface the task result to the orchestrator and stop retrying.
    cat "$cap" >&2
    break
  done
  rm -f "$cap" 2>/dev/null
  umask "$old_umask"
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
_local_detect() {
  local c base label mid
  local cands=()
  [ -n "${OSRC_LOCAL_URL:-}" ] && cands+=("${OSRC_LOCAL_URL%/}|custom")
  [ -n "${OLLAMA_HOST:-}" ] && cands+=("${OLLAMA_HOST%/}/v1|ollama")
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
  # Transport classification is a TWO-PASS match, because substring signatures fall into
  # two classes with different false-positive risk:
  #  PASS 1 -- MACHINE tokens + context-DISCRIMINATED signatures. These never occur in ordinary task/test
  #  prose (snake_case error codes, errno constants) or carry their own non-positional discriminator (a URL,
  #  the literal "after", an HTTP/version prefix, a status-code delimiter). Safe to match ANYWHERE in stderr.
  if printf '%s' "$stderr" | grep -qiE \
'econnrefused|etimedout|econnreset|enetunreach|ehostunreach|(name or service not known|temporary failure in name resolution)|authentication_error|overloaded_error|model_not_found|context_length_exceeded|no endpoints found|http/[0-9.]+ [45][0-9][0-9]|status[ _]?code[:= ]+[45][0-9][0-9]|\(code [45][0-9][0-9]\)|[45][0-9][0-9] server error.{0,40}for url|operation timed out after|429 .{0,20}rate.?limit|rate.?limit(ed)?[ :]+(error|exceeded|reached|hit)|(invalid|expired|missing|no valid).{0,15}(api.?key|auth token|bearer token|credential|authorization header)'; then
    return 0
  fi
  #  PASS 2 -- HUMAN-READABLE phrases. A real CLI emits these as their OWN diagnostic line (leading the line,
  #  optionally behind a bare "error: " wrapper); ordinary failed-task stderr only ever EMBEDS them mid-sentence
  #  ("AssertionError: connection refused should be rendered..."). So every one is LINE-ANCHORED. This is what
  #  stops the prose-false-positive class wholesale (a false positive here would blind-RETRY a mutating task).
  if printf '%s' "$stderr" | grep -qiE \
'^[[:space:]]*(error: )?(connection (refused|reset|error|failed|closed|timed ?out)|could(n.t| not) connect|network (error|is unreachable|is down)|no route to host|(ssh: )?could not resolve host:|curl: \([0-9]+\)|(tls|ssl) (handshake|error|certificate|routines|alert)|error sending request|http (error |status )?[45][0-9][0-9]|[45][0-9][0-9] (too many requests|unauthorized|forbidden|bad gateway|service unavailable|gateway time-?out|internal server error)|api error:? *\(?[45][0-9][0-9]|authentication[ _]?(required|failed|error)|rate.?limit(ed)?[ :]+(error|exceeded|reached|hit)|quota (exceeded|exhausted)|provider returned error|context.?length (exceeded|too long)|maximum context length|token limit exceeded|(request|read|connect) timed out|socket hang up$|gateway time-?out|deadline (has )?(elapsed|exceeded)|upstream (error|timed out|connect error)|stream disconnected|stream reset by peer|stream (closed|interrupted|ended) (before|unexpectedly|prematurely|during)|empty response from (the )?(server|upstream|api)|no response from (the )?(server|model|upstream)|model not found|model (is )?(unavailable|not available|does not exist|overloaded))'; then
    return 0
  fi
  return 1
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
  if [ "$MODEL_EXPLICIT" = "1" ]; then
    local row rest2
    row="$(resolve_model_row "$MODEL")"
    if [ -n "$row" ]; then
      RESOLVED_ID="${row%%|*}"; rest2="${row#*|}"; RESOLVED_LANE="${rest2%%|*}"; TTIER="${rest2#*|}"
    fi
  fi

  local disp=""
  if [ "$MODEL_EXPLICIT" = "1" ] && [ -n "$RESOLVED_LANE" ]; then
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
             *)     # U6 availability-aware routing: default provider (devin) + an OpenRouter model that
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
                      die "'$RESOLVED_ID' is an OpenRouter model; use --provider cc or codex (devin cannot serve it)."
                    fi ;;
           esac ;;
    esac
  else
    # no explicit -m (use provider default / chain) OR unknown id: route by --provider.
    case "$PROVIDER" in
      devin) disp=devin ;;
      cc)    disp=ccor ;;
      codex) disp=codexor ;;
      *)     die "unknown provider '$PROVIDER' (use: devin|cc|codex)" ;;
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
  _cloud_disclose "$disp" "$RESOLVED_ID" "${REST[*]}"

  # AUTO-DETACH (D3): if non-interactive AND slow-lane, auto-promote to the bg path so a harness
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
  have tmux || die "tmux not installed (brew install tmux)"
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
      tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
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
      ver="$(ls -1 "$plug" 2>/dev/null | sort -V | tail -1)"   # latest semver dir
      [ -n "$ver" ] || continue
      vdir="${plug}${ver}/skills"
      [ -d "$vdir" ] || continue
      for sk in "$vdir"/*/; do
        [ -f "${sk}SKILL.md" ] || continue
        name="$(basename "$sk")"
        [ -e "$dst/$name" ] || [ -L "$dst/$name" ] && continue   # first wins (top-level/earlier plugin)
        ln -sfn "${sk%/}" "$dst/$name" && plinked=$((plinked+1))
      done
    done
  fi
  echo "  linked $plinked plugin skill(s) [latest version each] -> $dst"

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
  echo "== outsourcerer doctor =="
  echo "  active provider: $PROVIDER  (switch with --provider devin|cc|codex or OUTSOURCERER_PROVIDER)"
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
  echo "  default model: $DEFAULT_MODEL"
  have jq   && echo "  jq:   $(jq --version 2>/dev/null) (needed for: parity MCP port)" || echo "  jq:   not installed -> brew install jq   (only needed for 'parity')"
  have tmux && echo "  tmux: $(tmux -V) (needed for: interactive session mode)"     || echo "  tmux: not installed -> brew install tmux (only needed for 'session')"
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

main() {
  # optional leading `--provider NAME` overrides the env/default backend
  if [ "${1:-}" = "--provider" ]; then
    [ -n "${2:-}" ] || die "--provider requires a name (devin|cc|codex)"
    PROVIDER="$2"; shift 2
  fi
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    __runjob) run_job "$@" ;;                             # internal: detached supervised job (cmd_bg)
    __gencost) _or_gen_cost "$1"; echo ;;                 # internal test: real cost of one generation id
    __runcost) _or_run_cost "$1"; echo ;;                 # internal test: real cost of a bg out.log
    doctor)   doctor ;;
    models)   models "$@" ;;
    run|explore) route_delegate "auto" "$cmd" "$@" ;;
    research)    route_delegate "autonomous" "$cmd" "$@" ;;      # exec tools inside a sandbox (devin/codex), see header
    edit)        route_delegate "accept-edits" "$cmd" "$@" ;;
    yolo)        route_delegate "dangerous" "$cmd" "$@" ;;
    bg)          cmd_bg "$@" ;;                            # background: detach a supervised job, print id
    fanout)      cmd_fanout "$@" ;;                        # parallel N-way multi-subagent (+ status|wait|collect|list)
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
    second-opinion|second) second_opinion "$@" ;;         # 2 cheap models; disagree -> escalate
    image)       cmd_image "$@" ;;                         # Gemini text-to-image (nano-banana default); prints file path
    parity-codex) parity_codex ;;                          # reverse bridge: Codex -> claude insource
    continue|cont)
      [ "$PROVIDER" = "devin" ] || die "continue is Devin-only for now (provider=$PROVIDER). For OR interactive follow-ups use the sibling tmux harness: scripts/run-or-{model,codex}.sh"
      continue_turn "$@" ;;
    session)
      session "$@" ;;   # provider-aware: devin | codex | cc (see session start)
    parity)
      [ "$PROVIDER" = "devin" ] || die "parity syncs into Devin only. cc inherits your Claude skills/MCP natively; codex uses its own AGENTS.md + MCP."
      parity ;;
    ""|-h|--help|help)
      sed -n '2,78p' "$0" | sed 's/^# \{0,1\}//'
      ;;
    *) die "unknown subcommand '$cmd' (try: doctor|models|run|research|edit|yolo|bg|fanout|status|watch|result|logs|cancel|cleanup|tab|estimate|second-opinion|image|continue|session|parity|parity-codex; prepend --provider devin|cc|codex)" ;;
  esac
}
main "$@"
