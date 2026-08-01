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
#   models                         Print the LIVE list of selectable Devin models (+ plan-cost heuristic)
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
#                     Inherits YOUR Claude skills / MCP / Task subagents without separate setup.
#   codex             Codex `exec` -> OpenRouter (native OpenAI Responses API, 0 hops; best tool
#                     fidelity). Runs in Codex's own AGENTS.md + MCP ecosystem, not Claude's.
#   droid             Factory Droid CLI (`droid exec`). YOUR configured models pass through
#                     verbatim, incl. BYOK customModels in ~/.factory/settings.json.
#   cursor            Cursor CLI (`cursor-agent -p`). Bills your Cursor subscription credits.
#   hermes            Hermes agent CLI (NousResearch `hermes-agent`). Engine lane: -m passes
#                     through verbatim (Hermes owns its model catalog). Real per-run cost is read
#                     from ~/.hermes/state.db after each run; when unavailable, the labeled token
#                     estimate is used (never a partial masquerading as exact). doctor reports
#                     installed / data-dir-only / absent / never-run states honestly. v1 non-goals:
#                     no advise scoring, no session mode.
#   claudex           GPT-5.6 Sol/Terra/Luna INSIDE the Claude Code harness via YOUR local
#                     CLIProxyAPI (detect-only; unofficial bridge; Claude-sub models refused).
#   local             Ollama / LM Studio / llama.cpp (also selectable via -m ollama:<m> etc).
# Reverse bridges (work FROM the other tool): parity-codex | parity-droid | parity-cursor (AGENTS.md
# hosts) and parity-hermes (SKILL.md host, symlink into ~/.hermes/skills) teach that host agent to
# drive outsourcerer, so its users reach Devin/OpenRouter/Claude/local too. `parity` (Devin) also
# mirrors this skill into Antigravity and Hermes when their skills dirs exist.
#
# WINDOWS: NO WSL REQUIRED. Runs under Git Bash (ships with Git for Windows); use the
# outsourcerer.cmd / outsourcerer.ps1 launchers next to this script from cmd/PowerShell.
# `session` uses winpty instead of tmux on Windows; everything else works (bg/fanout cover
# the same ground for long or parallel work, supervised).
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
# lanes (MAX_THINKING_TOKENS); a prompt input on every lane, with an advisory receipt where no native
# knob exists. The dispatch banner states which. See effort-and-tiers.md.
# CAPABILITY TIER != price: glm-5.2/hy3/deepseek/kimi are `capable` (frontier capability, budget price,
# ~Opus-4.8 class) and get the thin frontier wrapper, not the budget worker-drone scaffold.
# Model is a parameter everywhere. Default is overridable via OUTSOURCERER_MODEL.
# Plan-limit status on Devin CHANGES over time, this script never hardcodes it; use `models`.
#
# MODEL ADVISORY (which model should I use?):
#   advise [--refresh] [--json] [--effort LEVEL] "<task>"   Classifies your task (code/reasoning/agentic/creative/
#   simple), scores every known model against live benchmark data (OpenRouter benchmarks API:
#   intelligence/coding/agentic indices + pricing), and recommends the best value model that meets
#   the capability threshold for the task type. Capable value leads unless effort/task requirements
#   call for a frontier. Explains WHY it picked that model. Use --refresh to
#   pull fresh benchmark data (needs OPENROUTER_API_KEY in ~/.env). Without benchmarks, falls back to
#   tier-based proxy scores. Pair with `suggest` for price-only discovery, `estimate` for cost quotes.
#   TRANSPORT FALLBACK (read-only): when run/explore dies on a transport-class failure (429/rate
#   limit, 5xx, connection error, watchdog timeout) it auto-retries the SAME task down this ranked
#   shortlist on the next lane, bounded by OSRC_FALLBACK_MAX total attempts (default 3). Content
#   failures never retrigger; mutating verbs (edit/research/yolo) never auto-retry. OSRC_FALLBACK=0 disables.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
# Version identifier. Single source of truth; bump the rightmost
# number for patch releases. `doctor` and `--version` both read this.
OSRC_VERSION="0.5.0"
DEFAULT_MODEL="${OUTSOURCERER_MODEL:-glm-5.2}"

# ---- platform detection (mac | linux | windows-gitbash). Windows = Git Bash / MSYS2, NO WSL
# required: `session` uses winpty there; everything else works. See doctor's platform section.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) OSRC_PLATFORM="windows" ;;
  Darwin)               OSRC_PLATFORM="mac" ;;
  *)                    OSRC_PLATFORM="linux" ;;
esac

# ---- private-directory creation (portable)
#
# `mkdir -m 700 DIR` asks for the directory AND the mode in one call. On filesystems without Unix
# permission bits (NTFS under Git Bash/MSYS) the directory is created but applying the mode fails, so
# mkdir CREATES the thing and still exits non-zero. Any caller that reads that exit status concludes
# the directory does not exist and takes a failure path, which is how a working system reports itself
# as broken.
#
# Splitting the call fixes it without weakening anything: creation and permission-hardening are
# separate concerns with different failure semantics. Creation must succeed or the caller has no
# state to write. Hardening is best-effort by nature, because a filesystem that cannot express 700
# cannot be made to. That degradation is deliberate and platform-imposed, not a relaxation of the
# POSIX posture: on Mac and Linux the final mode is exactly what it was before.
#
# The creation runs under `umask 077` because splitting the call would otherwise open a window that
# `-m` did not have. `mkdir -m 700` sets the mode in the same syscall that creates the directory;
# plain `mkdir` creates it at 0777 & ~umask and only narrows on the following chmod. Under a
# permissive umask on a shared machine (002 with a shared group) that window is group-writable, long
# enough for another member to plant a file or a symlink inside a state or job directory before it
# is hardened. Setting the umask in a subshell closes the window without reintroducing `-m`, and
# leaves the caller's umask untouched.

# _harden_dir <dir> -> always 0. Applies the private mode, and says so ONCE when it cannot.
# "Best-effort" must not mean "silent everywhere". On Windows the failure is expected and explained
# by the filesystem. On Mac or Linux the same failure means something real (a restrictive ACL, a
# network mount, a directory owned by someone else) and the tool is about to write consent state,
# the ledger, MCP config, and job output into a directory it could not restrict. The code cannot
# tell those apart from the chmod alone, so it uses the platform to decide whether silence is honest.
_harden_dir() {
  chmod 700 "$1" 2>/dev/null && return 0
  [ "${OSRC_PLATFORM:-}" = "windows" ] && return 0
  [ -n "${_OSRC_HARDEN_WARNED:-}" ] && return 0
  _OSRC_HARDEN_WARNED=1
  printf '[outsourcerer] WARN: could not restrict permissions on %s (chmod 700 failed). State written there may be readable by other users on this machine.\n' "$1" >&2
  return 0
}

# _mkdir_private <dir> -> 0 when <dir> exists and is as private as the filesystem allows.
# Use for state directories, where "already exists" is success.
_mkdir_private() {
  ( umask 077; mkdir -p "$1" ) 2>/dev/null
  _harden_dir "$1"
  [ -d "$1" ] || return 1
  local probe="$1/.osrc-wtest-$$"
  ( umask 077; : > "$probe" ) 2>/dev/null || return 1
  rm -f "$probe" 2>/dev/null || return 1
}

# _mkdir_claim <dir> -> 0 only if THIS call created <dir>; 1 if it already existed.
# Use where the directory doubles as a lock. Plain `mkdir` (no -p) is the atomic primitive: the
# kernel guarantees exactly one of two racing callers creates it, which is what stops concurrent
# launches from sharing one job directory. Do NOT relax this to a test-then-create, and do not fold
# it into _mkdir_private, whose -p makes an existing directory a success.
_mkdir_claim() {
  # The subshell carries the umask, not the atomicity: `mkdir` with no -p is still the single
  # syscall that either creates the directory or fails because someone else already did, and the
  # subshell's exit status is that mkdir's.
  ( umask 077; mkdir "$1" ) 2>/dev/null || return 1
  _harden_dir "$1"
  return 0
}

# Offload backend: devin (default) | cc (Claude Code->OpenRouter) | codex (Codex->OpenRouter).
# OSRC_PROVIDER is an explicit caller selection. OUTSOURCERER_PROVIDER is retained for detached jobs.
PROVIDER="${OSRC_PROVIDER:-${OUTSOURCERER_PROVIDER:-devin}}"
if [ -n "${OSRC_PROVIDER_EXPLICIT:-}" ]; then
  PROVIDER_EXPLICIT="$OSRC_PROVIDER_EXPLICIT"
elif [ -n "${OSRC_PROVIDER:-}" ] || [ -n "${OUTSOURCERER_PROVIDER:-}" ]; then
  PROVIDER_EXPLICIT=1
else
  PROVIDER_EXPLICIT=0
fi
# OpenRouter escalation chain for cc/codex when no explicit -m is given (all support tool-calling).
# Lead with a model that currently EXISTS. tencent/hy3:free was first here and returns HTTP 404
# model_not_found, so every OpenRouter delegation opened by calling a dead model and paid a wasted
# round trip for it. A chain is a fallback mechanism, not a place to keep retired ids.
OR_CHAIN_DEFAULT="z-ai/glm-5.2,deepseek/deepseek-v4-pro"

# Absolute path to THIS script (for the reverse bridge / parity-codex AGENTS.md snippet).
# Resolve via command -v first to handle PATH-invoked usage (bare `outsourcerer bg run ...`).
SCRIPT_PATH="$(command -v -- "$0" 2>/dev/null || printf '%s' "$0")"
case "$SCRIPT_PATH" in
  /*) ;;  # already absolute
  *)  SCRIPT_PATH="$PWD/$SCRIPT_PATH" ;;
esac
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# ---- durable state home (jobs, model cache, ledger). NEVER /tmp. ----
OSRC_HOME="${OSRC_HOME:-$HOME/.outsourcerer}"
OSRC_JOBS="$OSRC_HOME/jobs"
OSRC_MODELS_JSON="$OSRC_HOME/models.json"
OSRC_LEDGER="$OSRC_HOME/ledger.jsonl"
OSRC_SESSIONS="$OSRC_HOME/sessions"
OSRC_SESSION_REGISTRY="$OSRC_SESSIONS/registry.jsonl"
OSRC_SESSION_CLAIMS="$OSRC_SESSIONS/claims"
OSRC_MODEL_PIN_STATE="$OSRC_HOME/model-pin.jsonl"
OSRC_OBLIGATIONS="$OSRC_HOME/obligations.jsonl"
OSRC_WAKE_QUEUE="$OSRC_HOME/wake-queue.jsonl"
OSRC_WAKE_ACK="$OSRC_HOME/wake-acks.jsonl"
OSRC_FLEET_SNAPSHOT="$OSRC_HOME/fleet-snapshot.json"
OSRC_HEARTBEAT="$OSRC_HOME/heartbeat"
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
  _mkdir_private "$OSRC_HOME" || true
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
# contract). SECURITY/ROBUSTNESS: brief/mode are READ-ONLY prints, they NEVER prompt
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
  _mkdir_private "$OSRC_HOME" || die "mode: cannot create state home $OSRC_HOME"
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
# Claude lanes (MAX_THINKING_TOKENS), and included in every dispatched prompt. NEVER silently dropped.
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
claude-opus-4-8|claude-opus-4-8|cc|frontier
claude-opus-5|claude-opus-5|cc|frontier
claude-fable-5|claude-fable-5|cc|frontier
claude-sonnet-5|claude-sonnet-5|cc|mid
claude-haiku-4-5-20251001|claude-haiku-4-5-20251001|cc|budget
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
kimi|kimi-k3|dv|capable
kimi-k3|kimi-k3|dv|capable
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
  local secs="$1" out_file; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  # Do not let descendants inherit a command-substitution pipe.  Even after
  # the direct child is killed, one missed grandchild holding that pipe keeps
  # the caller blocked until it exits.  Capture through a private file instead
  # and emit it only after the direct child has been reaped.
  _mkdir_private "$OSRC_HOME" >/dev/null 2>&1 || true
  out_file="$(mktemp "$OSRC_HOME/.timeout.XXXXXX" 2>/dev/null || mktemp)" || return 1
  chmod 600 "$out_file" 2>/dev/null || true
  "$@" >"$out_file" 2>&1 &
  local cmd_pid=$!
  # Signal the whole TREE, not just the direct child. Killing only the child leaves grandchildren
  # running, and a survivor still holding the inherited stdout keeps a `$(_timeout ...)` capture
  # blocked long after the bound fired — so the timeout appears to work and the caller hangs anyway.
  # A bounded call could therefore block far past its limit. _kill_tree walks the tree deepest-first,
  # which is the same reason it exists for the job supervisor.
  ( sleep "$secs" 2>/dev/null; _kill_tree "$cmd_pid" 2>/dev/null ) &
  local wd_pid=$!
  local rc=0; wait "$cmd_pid" 2>/dev/null || rc=$?
  kill "$wd_pid" 2>/dev/null; wait "$wd_pid" 2>/dev/null
  cat "$out_file"
  rm -f "$out_file" 2>/dev/null || true
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
  # A leading dash is syntactically safe for a shell, but becomes an option when
  # passed to a provider CLI rather than a model id.
  case "$token" in -*) die "invalid model token (must not begin with '-'): '$token'" ;; esac
  # Reject ANY control character FIRST, with a whole-string bash test. The `grep -qE '^…$'` below is
  # LINE-ORIENTED: on a multi-line token it returns 0 as soon as the FIRST line matches, waving through
  # later lines that carry an injection (e.g. $'claude\n;id' passes because line 1 "claude" matches).
  # A model id never contains a newline/CR/tab, so reject them up front — this is what stops the token
  # from later reaching an unquoted "$MODEL" in a launch string as a second shell line.
  case "$token" in *[$'\n\r\t']*) die "invalid model token (contains a control character): $(printf '%q' "$token")" ;; esac
  # Allow an OPTIONAL trailing context-window selector in square brackets: [1m] / [1M] / [200k] etc.
  # This is real Claude Code model-id syntax for the extended-context variant (e.g. claude-opus-4-8[1m]),
  # and rejecting it as "shell-injection" blocked every 1M-window model from every lane. The pattern is
  # anchored end-to-end (^base(suffix)?$), so the brackets can enclose ONLY [0-9]+ + up to 2 letters —
  # nothing else, no metacharacters, no second bracket group — can smuggle through. Everything before
  # the suffix stays the strict [A-Za-z0-9._:/-] set. tmux/shell contexts always quote the token, so a
  # glob-only '[' ']' pair is inert.
  if ! printf '%s' "$token" | grep -qE '^[A-Za-z0-9._:/-]+(\[[0-9]+[A-Za-z]{0,2}\])?$'; then
    die "invalid model token (shell-injection risk): '$token' — only [A-Za-z0-9._:/-] allowed, plus an optional trailing context-window suffix like [1m]"
  fi
}

parse_model() {
  # Strip ALL outsourcerer flags (not just leading -m) so none leak into the Devin CLI.
  # The `--effort high` leak crashed `devin -p` ("unexpected argument '--effort high...'").
  # parse_model sets the SAME flag state as _consume_flags (TIER_FLAG/OSRC_TIER_OVERRIDE,
  # WITH_SPEC) and validates --effort identically, so the two parsers no longer diverge. The Devin lane
  # still ignores tier/with (advisory only); non-Devin callers of parse_model (session, continue) get
  # the correct tier/effort state instead of silently dropping it.
  MODEL=""; MODEL_EXPLICIT=0; EFFORT="${OUTSOURCERER_EFFORT:-}"; TIER_FLAG=""; WITH_SPEC=""; REST=()
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
      --provider)           [ -n "${2:-}" ] || die "--provider requires a name (devin|cc|codex|droid|cursor|hermes|warp|gemini|gm|claudex|local)"; PROVIDER="$2"; PROVIDER_EXPLICIT=1; shift 2 ;;
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
    kimi|kimi-k3) printf 'kimi-k3' ;;
    *) printf '' ;;
  esac
}

# Resolve a user-facing alias to an id the DEVIN CLI accepts. parse_model() stores -m verbatim, so
# without this a documented alias reaches `devin --model` raw and the job dies at launch with
# "Unknown model: 'glm'" -- instantly, before any work, which in a fanout kills every member at once.
# Order: cross-lane sibling first (glm/deepseek carry an OpenRouter id the table would hand back),
# then the alias table's target, then the token unchanged (already a literal Devin id, or unknown to
# us -- let the CLI be the authority on its own catalog rather than guessing).
_devin_resolve_model() {
  local m="${1:-}" row target sib
  [ -n "$m" ] || { printf ''; return; }
  sib="$(_devin_model_for "$m")"; [ -n "$sib" ] && { printf '%s' "$sib"; return; }
  row="$(resolve_model_row "$m")"; target="${row%%|*}"
  if [ -n "$target" ]; then
    # The table maps OpenRouter-lane aliases to OpenRouter ids (glm -> z-ai/glm-5.2), which Devin
    # also rejects; run the target back through the sibling map before accepting it.
    sib="$(_devin_model_for "$target")"; [ -n "$sib" ] && { printf '%s' "$sib"; return; }
    printf '%s' "$target"; return
  fi
  printf '%s' "$m"
}

# Resolve aliases whose accepted model id differs by engine lane. Unknown model ids remain under
# the engine's control because Droid and Warp also support user-configured catalogs.
_lane_model_for() {
  local lane="${1:-}" model="${2:-}"
  case "$lane:$model" in
    devin:kimi|devin:kimi-k3|dv:kimi|dv:kimi-k3|droid:kimi|droid:kimi-k3|warp:kimi|warp:kimi-k3)
      printf 'kimi-k3' ;;
    devin:*|dv:*) _devin_resolve_model "$model" ;;
    *) printf '%s' "$model" ;;
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
  local prompt; prompt="$(_effort_prompt "${REST[*]}")"
  # Devin has no native reasoning-effort knob. If --effort was given, surface it as advisory
  # ONLY (it is consumed by parse_model, never passed to the devin CLI, which would 'unexpected argument').
  [ -n "${EFFORT:-}" ] && printf '>>> [effort] reasoning=%s (advisory: prompt directive; Devin lane has no native effort knob)\n' "$EFFORT" >&2
  need_devin
  logged_in || die "Not logged in to Devin. Run interactively:  ! devin auth login"
  local sbx=(); [ -n "$sandbox" ] && sbx=(--sandbox)
  # Aliases must become real Devin ids here, at the last point before the CLI: parse_model kept the
  # token verbatim, and `devin --model glm` is a hard launch failure.
  local _dvmodel; _dvmodel="$(_devin_resolve_model "$MODEL")"
  [ "$_dvmodel" = "$MODEL" ] || printf '>>> [model] alias "%s" -> Devin id "%s"\n' "$MODEL" "$_dvmodel" >&2
  MODEL="$_dvmodel"
  # --respect-workspace-trust false: headless delegation must not die on Devin's untrusted-workspace
  # prompt (a blocking prompt no `-p` run can answer -> the job fails with "Refusing to run in an
  # untrusted workspace"). The interactive `session` lane already passes this for the same reason;
  # run/bg/fanout omitting it is why a delegate launched from a fresh repo silently failed. Safe here
  # because Outsourcerer already ran its OWN cloud-consent + secret-scan gate on this exact scope
  # before dispatch (a STRICTER guard than Devin's trust prompt — it blocks real credential files),
  # so Devin's redundant prompt only ever broke headless runs.
  echo ">>> devin --model $MODEL --permission-mode $perm ${sbx[*]:-} --respect-workspace-trust false -p (offload)" >&2
  local rc=0
  devin --model "$MODEL" --permission-mode "$perm" ${sbx[@]+"${sbx[@]}"} --respect-workspace-trust false -p "$prompt" </dev/null || rc=$?
  printf '>>> [receipt] %s.\n' "$(_lane_cost_disclosure dv)" >&2
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
  # Same alias-resolution requirement as delegate(): an unresolved alias fails the continue at launch.
  MODEL="$(_devin_resolve_model "$MODEL")"
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

# lane_from_name <model-id> -> cc|cx|gm  (NATIVE lane inferred from the model FAMILY), or nonzero if
# the family is unrecognized. Sibling of tier_from_name. Consulted ONLY when the alias table has no
# exact row for an EXPLICIT -m: a recognizable native id (a pinned Claude id like claude-opus-4-8[1m],
# a future claude-*/gpt-5.*/gemini-* variant we haven't tabled yet) MUST reach its own provider's
# native lane, never silently fall through to the default provider (devin) and burn the wrong engine's
# limits. This is the "-m claude-opus-4-8 quietly ran on Devin and ate my Claude-sub tokens" fix.
# Precision matters: only families that are UNAMBIGUOUSLY native (Claude sub / ChatGPT sub / Gemini)
# infer here. Open-weight ids (glm/deepseek/kimi/qwen…) are deliberately absent — they are dual-lane
# and correctly ride the provider default, so they must fall through to the provider router below.
lane_from_name() {
  case "$1" in
    claude-*|*-opus-*|*opus[0-9-]*|opus|fable|fable-*|claude*|*sonnet*|*haiku*) echo cc ;;
    gpt-[0-9]*|gpt-*|sol|sol-*|terra|terra-*|luna|luna-*|o[0-9]-*|*-codex) echo cx ;;
    gemini-*|gemini|*-gemini-*) echo gm ;;
    *) return 1 ;;
  esac
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
  case "$2" in droid|cursor|hermes|warp|claudex) printf '%s' "$2"; return ;; esac   # engine lanes: provider IS the lane
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
    # A SIGNED marker is matched anywhere in the file, deliberately NOT anchored to line start.
    # codex-native and claude-native write out.log as a JSON EVENT STREAM, so a perfectly good
    # terminal marker sits inside a JSON string field and never begins a line. Anchoring made every
    # such run report `done?` (exited clean, no marker seen) even when the delegate finished properly
    # and said so, so a finished run was routinely filed as unverified.
    # This is only safe because the injected prompt contains NO live-signed marker: the protocol block
    # shows the literal placeholder <run-id> and discloses the real id once as prose. If that ever
    # regresses, this un-anchored match becomes forgeable by echo — test_marker_forgery.sh guards it.
    # Anchored to a LINE start, a JSON escaped newline (\n inside a string field), or a quote that opens
    # one. Fully un-anchoring would accept a marker mid-sentence ("I will print OSRC::DONE#... when
    # finished"), which is prose, not status. This keeps the "must begin a line" rule while recognising
    # that in a JSON stream the line begins inside the string.
    m="$(grep -aoE "(^|\\\\n|\")[[:space:]]*OSRC::(DONE|BLOCKED|NEED_INPUT)#${OSRC_MARK}" "$f" 2>/dev/null | tail -1)"
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
# One hole remained and is now closed: the injected protocol block used to print its EXAMPLE marker
# lines carrying the LIVE id, so a delegate that echoed the block back emitted a perfectly valid
# signed terminal by accident. The examples now use the literal placeholder <run-id> and the live id
# is disclosed exactly once as prose, so no copyable line in the prompt is ever a valid marker.
_new_mark() { od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%04x%04x' $$ "${RANDOM:-0}"; }

# ---- the canonical OSRC:: progress protocol block, injected into raw/continue/tmux ----
osrc_protocol_block() {
  if [ -n "${OSRC_MARK:-}" ]; then
    printf -- '--- PROGRESS PROTOCOL (required; machine-monitored) ---\n'
    printf 'Your run is supervised. A watchdog kills silent processes, so signal liveness.\n\n'
    printf 'Your live run id is: %s\n' "$OSRC_MARK"
    printf 'Every real OSRC:: line MUST end its marker with #<that id>. The examples below show the\n'
    printf 'literal placeholder <run-id> and NEVER the live id, so echoing this block back cannot\n'
    printf 'produce a valid status line:\n'
    printf '  OSRC::PROGRESS#<run-id> <step> <5-10 words on what you are doing now>\n'
    printf '  OSRC::BLOCKED#<run-id> <what is blocking you and what you tried>\n'
    printf '  OSRC::NEED_INPUT#<run-id> <the single question>\n'
    printf '  OSRC::DONE#<run-id> <one-line summary of what you did>\n\n'
    printf 'Rules:\n'
    printf '1. Each line stands alone, at the START of a line, nothing before it.\n'
    printf '2. Print a PROGRESS line before each major step; never go ~1 minute silent.\n'
    printf '   Between long commands it is fine to emit it from your shell tool.\n'
    printf '3. If blocked (missing file, failing dependency, denied permission, repeated\n'
    printf '   error) do NOT retry endlessly. Print ONE BLOCKED line and stop.\n'
    printf '4. Finish with exactly one DONE line as the final line.\n'
    printf '5. If you quote or discuss these markers, keep <run-id> literally unchanged.\n'
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
# _resolve_skill_file <name> -> path to that skill's SKILL.md, searching every real home for one.
# A skill can live in the user's own dir, inside an installed PLUGIN's versioned cache, or in the
# parity dir we symlink for delegate lanes. Searching only the first silently drops every plugin skill.
# Plugin caches are version-scoped, so the newest version wins rather than whichever glob sorts first.
_resolve_skill_file() {
  local name="$1" p
  for p in "$HOME/.claude/skills/$name/SKILL.md" \
           "$HOME/.config/devin/skills/$name/SKILL.md"; do
    [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  done
  # Plugin caches: .../<plugin>/<version>/skills/<name>/SKILL.md — take the highest version present.
  p="$(ls -1d "$HOME"/.claude/plugins/cache/*/*/*/skills/"$name"/SKILL.md 2>/dev/null | sort -V | tail -1)"
  [ -n "$p" ] && [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  return 1
}

build_with_preamble() {
  [ -n "${WITH_SPEC:-}" ] || return 0
  local tok val name f out=""
  for tok in $WITH_SPEC; do
    case "$tok" in
      skills=*) val="${tok#skills=}"
        for name in $(printf '%s' "$val" | tr ',' ' '); do
          # Resolve across every place a skill really lives, not just the user's own skills dir.
          # Only ~/.claude/skills was searched before, so every PLUGIN skill (the whole ce-* family)
          # silently resolved to "NOT FOUND" and the delegate ran without the capability the caller
          # believed it had granted. A capability promise that fails quietly is worse than one that
          # was never offered, because nobody goes looking.
          f="$(_resolve_skill_file "$name")"
          if [ -n "$f" ] && [ -f "$f" ]; then
            # Bound the injection. A SKILL.md can be ~100KB; pasting several verbatim buys latency and
            # spend on every single delegation, and on a lane that emits nothing until it finishes, a
            # bloated prompt is indistinguishable from a hang. Truncate loudly and name the file so the
            # delegate can read the rest itself.
            local _sz _cap; _cap="${OSRC_WITH_MAX_BYTES:-20000}"
            _sz=$(wc -c < "$f" 2>/dev/null || echo 0)
            if [ "$_sz" -gt "$_cap" ]; then
              printf '>>> [with] skill %s is %sb; injecting the first %sb only (raise with OSRC_WITH_MAX_BYTES). Full file: %s\n' \
                "$name" "$_sz" "$_cap" "$f" >&2
              out="$out
=== INJECTED SKILL: $name (TRUNCATED to ${_cap}b of ${_sz}b; full file readable at $f) ===
$(head -c "$_cap" "$f")
=== END SKILL: $name ==="
            else
              out="$out
=== INJECTED SKILL: $name ===
$(cat "$f")
=== END SKILL: $name ==="
            fi
          else
            # Say it on stderr too. Buried inside the prompt, a NOT FOUND note is read by the delegate
            # and by nobody else, so the caller never learns the capability did not arrive.
            printf '>>> [with] skill %s NOT FOUND (looked in ~/.claude/skills, the plugin caches, and the parity dir). The delegate is running WITHOUT it.\n' "$name" >&2
            out="$out
(injected skill '$name' NOT FOUND)"
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
  _mkdir_private "$OSRC_HOME" || { echo "ERROR: isolation setup: cannot mkdir OSRC_HOME ($OSRC_HOME)" >&2; return 1; }
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

_effort_prompt() {
  local task="$1"
  if [ -n "${EFFORT:-}" ]; then
    printf 'Reasoning effort: %s. Match the depth of analysis and thinking to this level.\n\n%s' "$EFFORT" "$task"
  else
    printf '%s' "$task"
  fi
}

_build_prompt() {
  local id="$1" task="$2" ttier="${3:-}" tier pre disc
  task="$(_effort_prompt "$task")"
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
  MODEL=""; MODEL_EXPLICIT=0; TIER_FLAG=""; WITH_SPEC=""; EFFORT="${OUTSOURCERER_EFFORT:-}"; OSRC_ALLOW_DOWNGRADE="${OSRC_ALLOW_DOWNGRADE:-0}"
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
      --provider) [ -n "${2:-}" ] || die "--provider requires a name (devin|cc|codex|droid|cursor|hermes|warp|gemini|gm|claudex|local)"; PROVIDER="$2"; PROVIDER_EXPLICIT=1; shift 2 ;;  # accepted AFTER the subcommand too (flag-placement tolerance)
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
# _lane_cost_disclosure <lane> -> the user-visible cost class for a resolved lane.
_lane_cost_disclosure() {
  case "$1" in
    local)                         printf '$0 cash + $0 plan' ;;
    cx|codex-native|claudex|ci)    printf '$0 cash, spends your ChatGPT plan limits' ;;
    cc|claude-native)              printf '$0 cash, spends your Claude plan limits' ;;
    gm|antigravity-agy)            printf '$0 cash, spends your Antigravity plan limits' ;;
    dv|devin)                      printf '$0 cash, spends your Devin plan limits' ;;
    cursor)                        printf '$0 cash, spends your Cursor plan limits' ;;
    or|openrouter|ccor|codexor)    printf 'metered cash, measured per run when available, otherwise estimated' ;;
    gemini|gi)                     printf 'metered cash through your Gemini API key, estimated before the run' ;;
    hermes)                        printf 'metered cash from your configured provider, measured when available, otherwise estimated' ;;
    droid)                         printf 'cash depends on your Factory plan or BYOK model; BYOK usage is measured or estimated by its provider' ;;
    warp)                          printf 'cash depends on your Warp plan or configured keys; key usage is measured or estimated by its provider' ;;
    *)                             printf 'cash and plan impact unknown for your %s lane' "$1" ;;
  esac
}

# record_ledger <provider> <model> <tier> <verb> <task> [cost] [lane]
record_ledger() {
  # bg jobs record the accurate (stream-json) entry from __runjob; skip the child's estimate then.
  [ "${OSRC_STREAM:-0}" = "1" ] && [ "${OSRC_LEDGER_FORCE:-0}" != "1" ] && return 0
  [ "${OSRC_LEDGER_QUIET:-0}" = "1" ] && [ "${OSRC_LEDGER_FORCE:-0}" != "1" ] && return 0
  have jq || return 0
  _mkdir_private "$OSRC_HOME" || true
  # Restrict the ledger itself: the $OSRC_HOME dir is 700, but if OSRC_HOME is ever
  # pointed at a shared location the ledger (task hashes, costs, model names) should still be 600.
  # Create private from birth (umask subshell) so there is no world-readable window even on a first
  # foreground run with a lax umask (pre-existing gap; matters if OSRC_HOME is ever a shared path).
  [ -e "$OSRC_LEDGER" ] || ( umask 077; : > "$OSRC_LEDGER" ) 2>/dev/null || true
  chmod 600 "$OSRC_LEDGER" 2>/dev/null || true
  local prov="$1" model="$2" tier="$3" verb="$4" task="$5" cost="${6:-}" lane="${7:-}"
  local intok; intok="$(_est_tokens "$task")"
  local ts; ts="$(date +%Y-%m-%dT%H:%M:%S)"
  local hash; hash="$(printf '%s' "$task" | cksum | cut -d' ' -f1)"
  # Learning keys. run_id joins this cost row to its later outcome row; task_class + repo_key are
  # the advise-learning bucket. All additive JSON fields (existing readers ignore unknown keys).
  # Prefer pre-set env (a bg/loop child sets the real task_class before this fires) then derive.
  local run_id task_class repo_key
  run_id="${OSRC_RUN_ID:-$(_ensure_run_id)}"
  task_class="${OSRC_TASK_CLASS:-$(_classify_task "$task")}"
  # Validate the env overrides so a caller can't defeat the guarantees: repo_key MUST be a cksum
  # (numeric) or the PII promise breaks (a raw URL/path would be stored verbatim); task_class MUST be
  # a known bucket or it pollutes learning. Bad value -> derive the safe one.
  case "$task_class" in code|reasoning|agentic|creative|simple) ;; *) task_class="$(_classify_task "$task")" ;; esac
  repo_key="${OSRC_REPO_KEY:-}"
  case "$repo_key" in ''|*[!0-9]*) repo_key="$(_repo_key)" ;; esac
  # NB: record_ledger exports NOTHING per-call. Exporting per-task values (run_id/task_class/lane/model)
  # would let a future in-process loop (slice 3 loop-judges) stamp task B with task A's values via a
  # later record_outcome in the same process. Callers that record an outcome pass every field
  # EXPLICITLY (see run_job). Env inheritance for threading is done by the caller (run_job), on purpose.
  # lane (resolved lane code: cx/cc/gm/or/dv/local) drives the Tab's plan-vs-cash split. The bg path
  # (run_job) records the RAW provider (e.g. devin) which mislabels a plan lane as cash, so it passes
  # the resolved lane here; cmd_tab's is_sub prefers .lane and falls back to the provider string.
  local _line; _line="$(jq -cn --arg ts "$ts" --arg p "$prov" --arg m "$model" --arg t "$tier" --arg v "$verb" \
     --arg c "$cost" --argjson it "$intok" --arg h "$hash" --arg lane "$lane" \
     --arg rid "$run_id" --arg tc "$task_class" --arg rk "$repo_key" \
     '{ts:$ts,provider:$p,model:$m,tier:$t,verb:$v,in_tokens:$it,cost_usd:$c,task_hash:$h,run_id:$rid,task_class:$tc,repo_key:$rk}
      + (if $lane=="" then {} else {lane:$lane} end)')" || return 0
  [ -n "$_line" ] || return 0
  if [ "${OSRC_FORCE_MKDIR_ELECTION:-0}" != 1 ] && command -v flock >/dev/null 2>&1; then
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

_state_sync() {
  sync -f "$1" 2>/dev/null
}

_state_lock_acquire() {
  local file="$1" lock tries=0
  lock="$file.lock"
  _STATE_LOCK_KIND=""
  if command -v flock >/dev/null 2>&1; then
    exec 9>>"$file" 2>/dev/null || return 1
    flock -w 5 9 2>/dev/null || { exec 9>&-; return 1; }
    _STATE_LOCK_KIND="flock"
    return 0
  fi
  while [ "$tries" -lt 50 ]; do
    _mkdir_claim "$lock" && { _STATE_LOCK_KIND="mkdir"; return 0; }
    sleep 0.1
    tries=$((tries + 1))
  done
  return 1
}

_state_lock_release() {
  case "${_STATE_LOCK_KIND:-}" in
    flock) flock -u 9 2>/dev/null || true; exec 9>&- ;;
    mkdir) rmdir "$1.lock" 2>/dev/null || true ;;
  esac
  _STATE_LOCK_KIND=""
}

_state_append() {
  local file="$1" record="$2" size parent rc=0
  case "$file" in "$OSRC_HOME"/*.jsonl) ;; *) echo "ERROR: invalid state path" >&2; return 1 ;; esac
  [ ! -L "$file" ] && [ ! -L "$file.lock" ] || { echo "ERROR: unsafe state path" >&2; return 1; }
  have jq || { echo "ERROR: jq is required for state writes" >&2; return 1; }
  printf '%s' "$record" | jq -e . >/dev/null 2>&1 || { echo "ERROR: invalid state record" >&2; return 1; }
  size=$(printf '%s' "$record" | wc -c | tr -d ' ')
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$size" -le "${OSRC_STATE_RECORD_MAX:-8192}" ] || { echo "ERROR: state record exceeds limit" >&2; return 1; }
  parent="$(dirname "$file")"
  _mkdir_private "$parent" || { echo "ERROR: state directory unavailable" >&2; return 1; }
  ( umask 077; : >> "$file" ) 2>/dev/null || { echo "ERROR: state file unavailable" >&2; return 1; }
  chmod 600 "$file" 2>/dev/null || true
  _state_lock_acquire "$file" || { echo "ERROR: state lock unavailable" >&2; return 1; }
  printf '%s\n' "$record" >> "$file" 2>/dev/null || rc=1
  [ "$rc" -eq 0 ] && _state_sync "$file" || rc=1
  _state_lock_release "$file"
  [ "$rc" -eq 0 ] || { echo "ERROR: state append failed" >&2; return 1; }
}

_state_jsonl_read() {
  local file="$1" line complete rows=0
  [ -e "$file" ] || return 0
  [ ! -L "$file" ] || { echo "ERROR: unsafe state path" >&2; return 1; }
  have jq || return 1
  complete=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
  case "$complete" in ''|*[!0-9]*) return 1 ;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    rows=$((rows + 1))
    if printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
      printf '%s\n' "$line"
    elif [ "$rows" -gt "$complete" ]; then
      echo "outsourcerer: ignored truncated final state record" >&2
      return 0
    else
      echo "ERROR: invalid state record" >&2
      return 1
    fi
  done < "$file"
}

_external_session_id_valid() {
  case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac
}

# Newest-first, capped list of session-transcript files under a directory (searched recursively).
# `-mmin -N` keeps files modified in the last N minutes (default 48h); the survivors are ordered
# most-recently-modified first and capped, so the cost per snapshot stays bounded no matter how
# much history accumulates while the freshest sessions (the ones most likely to be live or waiting)
# are never dropped for an arbitrary one. Both bounds are env-tunable.
_fleet_recent_session_files() { # <dir>
  local dir="$1" win="${OSRC_FLEET_RECENT_MIN:-2880}" cap="${OSRC_FLEET_EXTERNAL_CAP:-40}" matches
  [ -d "$dir" ] || return 0
  case "$win" in ''|*[!0-9]*|0) win=2880 ;; esac
  case "$cap" in ''|*[!0-9]*|0) cap=40 ;; esac
  # Guard the empty case explicitly: with no matches, `xargs` on some platforms runs `ls` with
  # no operands and lists the working directory, which would fabricate observations from unrelated
  # files. Session transcript names carry no newlines, so a newline-delimited hand-off is safe.
  matches="$(find "$dir" -type f -name '*.jsonl' -mmin -"$win" 2>/dev/null)"
  [ -n "$matches" ] || return 0
  printf '%s\n' "$matches" | tr '\n' '\0' | xargs -0 ls -1t 2>/dev/null | head -n "$cap"
}

_external_session_observation() { # <items-json> <id> <source> <endpoint> [pid] [pid-start]
  local items="$1" id="$2" source="$3" endpoint="$4" pid="${5:-}" pid_start="${6:-}" item
  _external_session_id_valid "$id" || return 1
  item="$(jq -cn --arg id "$id" --arg source "$source" --arg endpoint "$endpoint" --arg pid "$pid" --arg pid_start "$pid_start" '
    {schema_version:"1",session_id:$id,owner:"external",harness:$source,lane:null,
     requested_model:null,observed_model:null,effort:null,endpoint:(if $endpoint=="" then null else $endpoint end),
     harness_pid:(if $pid=="" then null else $pid end),pid_start:(if $pid_start=="" then null else $pid_start end),
     started_at:null,state:"unknown",state_evidence:"read-only observation",composer_state:"unknown",claim:null,
     task_summary:"external session",last_receipt:null,source_generation:null}')" || return 1
  jq -cn --argjson items "$items" --argjson item "$item" '$items + [$item]'
}

_external_session_observations() { # <managed-job-items-json>
  have jq || return 1
  local items="$1" line id endpoint pid start source path name command lane requested resolved generation observed
  # Registry entries prove ownership, not a live terminal state. Preserve the managed record as
  # an observation only when it is not already represented by a managed job.
  while IFS= read -r line; do
    id="$(printf '%s' "$line" | jq -r '.session_id // empty')"
    _external_session_id_valid "$id" || continue
    endpoint="$(printf '%s' "$line" | jq -r --arg id "$id" '.endpoint // ("tmux:" + $id)')"
    lane="$(printf '%s' "$line" | jq -r '.provider // empty')"
    requested="$(printf '%s' "$line" | jq -r '.requested_model // .model // empty')"
    resolved="$(printf '%s' "$line" | jq -r '.resolved_model // .model // empty')"
    generation="$(printf '%s' "$line" | jq -r '.model_generation // 1')"
    observed="$(_session_model_observe "$lane" "$endpoint" "$id" 2>/dev/null)"; [ -n "$observed" ] || observed=unknown
    items="$(printf '%s' "$items" | jq --arg id "$id" --arg endpoint "$endpoint" --arg lane "$lane" --arg requested "$requested" --arg resolved "$resolved" --arg observed "$observed" --argjson model_generation "$generation" '
      . + [{schema_version:"1",session_id:$id,owner:"managed",harness:"registry",lane:(if $lane=="" then null else $lane end),
       requested_model:(if $requested=="" then null else $requested end),resolved_model:(if $resolved=="" then null else $resolved end),model_generation:$model_generation,observed_model:(if $observed=="" then "unknown" else $observed end),effort:null,endpoint:$endpoint,harness_pid:null,pid_start:null,
       started_at:null,state:"unknown",state_evidence:"managed registry",composer_state:"unknown",claim:null,
       task_summary:"managed session",last_receipt:null,source_generation:null}]')" || return 1
  done < <(_state_jsonl_read "$OSRC_SESSION_REGISTRY" 2>/dev/null)

  # These sources are intentionally evidence-only. Their files, pane titles, and process names do
  # not establish ownership, activity, or an input-safe composer. Discovery is bounded to files
  # touched recently and capped: a status line reports live sessions, and an unbounded per-tick
  # scan of a large transcript history would blow past the beacon's cadence on an active machine.
  while IFS= read -r path; do
    [ -f "$path" ] || continue
    name="$(basename "$path" .jsonl | tr -cd 'A-Za-z0-9._-')"
    [ -n "$name" ] || continue
    items="$(_external_session_observation "$items" "claude.$name" claude "file:$path")" || return 1
  done < <(_fleet_recent_session_files "${OSRC_CLAUDE_REGISTRY:-$HOME/.claude/sessions}")
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    name="$(printf '%s' "$path" | cksum | awk '{print $1}')"
    items="$(_external_session_observation "$items" "codex.$name" codex "file:$path")" || return 1
  done < <(_fleet_recent_session_files "$HOME/.codex/sessions")
  if have tmux; then
    while IFS=$'\t' read -r endpoint pid command; do
      [ -n "$endpoint" ] || continue
      id="tmux.$(printf '%s' "$endpoint" | tr -cd 'A-Za-z0-9._-' | tr ':' '.')"
      start="$(_pid_start_identity "$pid" 2>/dev/null)" || start=""
      items="$(_external_session_observation "$items" "$id" tmux "tmux:$endpoint" "$pid" "$start")" || return 1
    done < <(tmux list-panes -a -F '#S:#I.#P\t#{pane_pid}\t#{pane_current_command}' 2>/dev/null)
  fi
  # A process-table sighting is intentionally not an endpoint and therefore cannot be claimed.
  while IFS= read -r line; do
    pid="${line%% *}"; command="${line#* }"
    case "$command" in *codex*|*claude*)
      start="$(_pid_start_identity "$pid" 2>/dev/null)" || start=""
      id="proc.$pid"
      items="$(_external_session_observation "$items" "$id" process "" "$pid" "$start")" || return 1
      ;;
    esac
  done < <(ps -axo pid=,command= 2>/dev/null)
  printf '%s' "$items"
}

_session_claim_path() { printf '%s/%s' "$OSRC_SESSION_CLAIMS" "$1"; }

_external_claim_read() {
  local id="$1" file
  _external_session_id_valid "$id" || return 1
  file="$(_session_claim_path "$id")/owner.json"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  jq -e . "$file"
}

_external_send_enabled() {
  [ "${OSRC_EXTERNAL_SEND:-0}" = 1 ] && return 0
  echo "external session mutation is experimental and disabled; set OSRC_EXTERNAL_SEND=1 to opt in" >&2
  return 1
}

_external_controller_id() {
  # A CLI action is a short-lived process, so its PID cannot identify the
  # controller across `claim`, `reply`, and `release`.  Prefer an explicit,
  # durable caller identity.  In an interactive tmux controller, the tmux
  # session id is stable across those invocations.  Outside either context the
  # random claim token is the capability; that is safe only because claim
  # state is kept under OSRC_HOME (0700) and owner.json is written 0600.
  local id="${OSRC_CONTROLLER_ID:-}" session_id
  if [ -z "$id" ] && [ -n "${TMUX_PANE:-}" ] && have tmux; then
    session_id="$(tmux display-message -p -t "$TMUX_PANE" '#{session_id}' 2>/dev/null)" || session_id=""
    [ -n "$session_id" ] && id="tmux:$session_id"
  fi
  [ -n "$id" ] || id="capability"
  case "$id" in ''|*[!A-Za-z0-9._:@\$-]*) return 1 ;; esac
  printf '%s\n' "$id"
}

_external_claim_authorized() { # <claim-json>
  local claim="$1" token controller_id claimed_id generation
  token="$(printf '%s' "$claim" | jq -r '.token // empty')" || return 1
  claimed_id="$(printf '%s' "$claim" | jq -r '.controller_id // empty')" || return 1
  controller_id="$(_external_controller_id)" || return 1
  # OSRC_SESSION_CLAIM_TOKEN is the public cross-invocation capability name.
  # Keep the older name as an in-process compatibility alias.
  [ "$token" = "${OSRC_SESSION_CLAIM_TOKEN:-${SESSION_CLAIM_TOKEN:-}}" ] || return 1
  [ "$claimed_id" = "$controller_id" ] || return 1
  generation="$(printf '%s' "$claim" | jq -r '.generation // empty')" || return 1
  [ -n "$generation" ] || return 1
  SESSION_CLAIM_TOKEN="$token"
  SESSION_CLAIM_GENERATION="$generation"
  export SESSION_CLAIM_TOKEN SESSION_CLAIM_GENERATION
}

_external_session_claim() { # <session-id> <tmux-pane>
  local id="$1" pane="$2" dir owner pid start token controller_id generation record tmp rc=0
  _external_send_enabled || return 1
  [ "$OSRC_PLATFORM" != "windows" ] || { echo "unverified Windows mutation support" >&2; return 1; }
  _external_session_id_valid "$id" || return 1
  case "$pane" in ''|*[!A-Za-z0-9:._-]*) return 1 ;; esac
  have tmux && tmux display-message -p -t "$pane" '#{pane_pid}' >/dev/null 2>&1 || return 1
  pid="$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)"
  start="$(_pid_start_identity "$pid" 2>/dev/null)" || return 1
  token="$(_heartbeat_token)"; [ -n "$token" ] || return 1
  controller_id="$(_external_controller_id)" || return 1
  generation="$(_heartbeat_token)"; [ -n "$generation" ] || return 1
  _mkdir_private "$OSRC_SESSION_CLAIMS" || return 1
  dir="$(_session_claim_path "$id")"
  _mkdir_claim "$dir" || return 1
  record="$(jq -cn --arg id "$id" --arg endpoint "tmux:$pane" --argjson pid "$pid" --arg start "$start" --arg token "$token" --arg controller_id "$controller_id" --arg generation "$generation" \
    '{schema_version:"3",session_id:$id,endpoint:$endpoint,pid:$pid,pid_start:$start,token:$token,controller_id:$controller_id,generation:$generation}')" || rc=1
  tmp="$dir/.owner.$$.$RANDOM"
  [ "$rc" -ne 0 ] || ( umask 077; printf '%s\n' "$record" > "$tmp" ) || rc=1
  [ "$rc" -ne 0 ] || _state_sync "$tmp" || rc=1
  [ "$rc" -ne 0 ] || mv "$tmp" "$dir/owner.json" || rc=1
  [ "$rc" -ne 0 ] || _state_sync "$dir" || rc=1
  rm -f "$tmp" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then rmdir "$dir" 2>/dev/null || true; return 1; fi
  SESSION_CLAIM_TOKEN="$token"
  SESSION_CLAIM_GENERATION="$generation"
  export SESSION_CLAIM_TOKEN SESSION_CLAIM_GENERATION
  printf '%s\n' "$token"
}

_external_session_release() { # <session-id>
  local id="$1" claim pid start dir
  _external_send_enabled || return 1
  [ "$OSRC_PLATFORM" != "windows" ] || { echo "unverified Windows mutation support" >&2; return 1; }
  claim="$(_external_claim_read "$id")" || return 1
  pid="$(printf '%s' "$claim" | jq -r '.pid')"; start="$(printf '%s' "$claim" | jq -r '.pid_start')"
  _external_claim_authorized "$claim" || return 1
  [ "$(_pid_start_identity "$pid" 2>/dev/null)" = "$start" ] || return 1
  dir="$(_session_claim_path "$id")"
  rm -f "$dir/owner.json" 2>/dev/null || return 1
  rmdir "$dir" 2>/dev/null
}

_external_composer_state() { # <tmux-pane>
  # No generic terminal protocol can prove an arbitrary TUI composer is empty. An adapter must
  # return exactly "empty" after inspecting this endpoint immediately before input is written.
  local pane="$1"
  if [ -n "${OSRC_EXTERNAL_COMPOSER_PROBE:-}" ] && command -v "$OSRC_EXTERNAL_COMPOSER_PROBE" >/dev/null 2>&1; then
    "$OSRC_EXTERNAL_COMPOSER_PROBE" "$pane" 2>/dev/null
  else
    printf 'unknown\n'
  fi
}

_external_receipt_verify() { # <tmux-pane> <obligation-id>
  local pane="$1" obligation="$2"
  if [ -n "${OSRC_EXTERNAL_RECEIPT_PROBE:-}" ] && command -v "$OSRC_EXTERNAL_RECEIPT_PROBE" >/dev/null 2>&1; then
    "$OSRC_EXTERNAL_RECEIPT_PROBE" "$pane" "$obligation" 2>/dev/null
  else
    printf 'unknown\n'
  fi
}

_external_receipt_valid() { # <receipt> <pane> <obligation-id> <generation>
  printf '%s' "$1" | jq -e --arg endpoint "tmux:$2" --arg obligation "$3" --arg generation "$4" \
    '.obligation_id==$obligation and .endpoint==$endpoint and .generation==$generation and .target_transition==true' >/dev/null 2>&1
}

_obligation_append() { # <id> <session-id> <state> <receipt>
  local id="$1" session_id="$2" state="$3" receipt="$4" now record
  _external_session_id_valid "$session_id" || return 1
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  record="$(jq -cn --arg id "$id" --arg session "$session_id" --arg state "$state" --arg receipt "$receipt" --arg ts "$now" \
    '{schema_version:"1",obligation_id:$id,session_id:$session,state:$state,receipt:(if $receipt=="" then null else $receipt end),ts:$ts}')" || return 1
  _state_append "$OSRC_OBLIGATIONS" "$record"
}

# The decision to create an obligation is a mutation authority boundary.  A plain
# read followed by _state_append races under two reply processes, so hold the
# durable state lock through both the read and the pending record.
_obligation_admit() { # <id> <session-id>
  local id="$1" session_id="$2" latest now record rc=0
  _mkdir_private "$OSRC_HOME" || return 1
  ( umask 077; : >> "$OSRC_OBLIGATIONS" ) 2>/dev/null || return 1
  _state_lock_acquire "$OSRC_OBLIGATIONS" || return 1
  latest="$(_obligation_latest_state "$id")"
  case "$latest" in submitted|delivery_unknown|pending|typing_started) _state_lock_release "$OSRC_OBLIGATIONS"; return 2 ;; esac
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  record="$(jq -cn --arg id "$id" --arg session "$session_id" --arg ts "$now" '{schema_version:"1",obligation_id:$id,session_id:$session,state:"pending",receipt:null,ts:$ts}')" || rc=1
  [ "$rc" -ne 0 ] || printf '%s\n' "$record" >> "$OSRC_OBLIGATIONS" 2>/dev/null || rc=1
  [ "$rc" -ne 0 ] || _state_sync "$OSRC_OBLIGATIONS" || rc=1
  _state_lock_release "$OSRC_OBLIGATIONS"
  return "$rc"
}

_endpoint_mutation_lock() { # <pane>; held until _endpoint_mutation_unlock
  local pane="$1" key
  key="$(printf '%s' "$pane" | cksum | awk '{print $1}')" || return 1
  _mkdir_private "$OSRC_SESSIONS" || return 1
  _state_lock_acquire "$OSRC_SESSIONS/mutation-$key" || return 1
}
_endpoint_mutation_unlock() { _state_lock_release "$OSRC_SESSIONS/mutation-${1}"; }

_claimed_endpoint_live() { # <pane> <claimed-pid> <claimed-start>
  local pane="$1" pid="$2" start="$3" live
  live="$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)" || return 1
  [ "$live" = "$pid" ] || return 1
  [ "$(_pid_start_identity "$live" 2>/dev/null)" = "$start" ]
}

_obligation_delivery_unknown() { # <id> <session-id>
  local id="$1" session_id="$2"
  _obligation_append "$id" "$session_id" delivery_unknown "" >/dev/null 2>&1 || true
  _wake_append "$(jq -cn --arg event_id "obligation.$id" --arg id "$id" '{event_id:$event_id,kind:"delivery",state:"unknown",task_summary:("delivery unknown: " + $id)}')" >/dev/null 2>&1 || true
}

_obligation_recover_stranded() {
  local oid sid
  while IFS=$'\t' read -r oid sid; do
    [ -n "$oid" ] && [ -n "$sid" ] && _obligation_delivery_unknown "$oid" "$sid"
  done < <(_state_jsonl_read "$OSRC_OBLIGATIONS" 2>/dev/null | jq -r -s 'sort_by(.ts) | group_by(.obligation_id)[] | last | select(.state=="typing_started") | [.obligation_id,.session_id] | @tsv')
}
_obligation_guard_begin() { # <id> <session-id>
  _OBLIGATION_GUARD_EXIT="$(trap -p EXIT)"; _OBLIGATION_GUARD_INT="$(trap -p INT)"; _OBLIGATION_GUARD_TERM="$(trap -p TERM)"
  trap '_obligation_delivery_unknown "'$1'" "'$2'"; exit 1' EXIT INT TERM
}
_obligation_guard_end() {
  trap - EXIT INT TERM
  [ -n "${_OBLIGATION_GUARD_EXIT:-}" ] && eval "$_OBLIGATION_GUARD_EXIT"
  [ -n "${_OBLIGATION_GUARD_INT:-}" ] && eval "$_OBLIGATION_GUARD_INT"
  [ -n "${_OBLIGATION_GUARD_TERM:-}" ] && eval "$_OBLIGATION_GUARD_TERM"
  unset _OBLIGATION_GUARD_EXIT _OBLIGATION_GUARD_INT _OBLIGATION_GUARD_TERM
}

_obligation_latest_state() { # <id>
  _state_jsonl_read "$OSRC_OBLIGATIONS" 2>/dev/null | jq -r --arg id "$1" 'select(.obligation_id==$id) | .state' | tail -1
}

_external_reply() { # <session-id> <message>
  local id="$1" message="$2" claim pane pid start generation composer oid latest receipt key
  _external_send_enabled || return 1
  [ "$OSRC_PLATFORM" != "windows" ] || { echo "unverified Windows mutation support" >&2; return 1; }
  claim="$(_external_claim_read "$id")" || { echo "external reply requires a live claim" >&2; return 1; }
  pane="$(printf '%s' "$claim" | jq -r '.endpoint // empty' | sed 's/^tmux://')"; pid="$(printf '%s' "$claim" | jq -r '.pid')"; start="$(printf '%s' "$claim" | jq -r '.pid_start')"; generation="$(printf '%s' "$claim" | jq -r '.generation')"
  _external_claim_authorized "$claim" || { echo "external reply requires the matching durable controller id and claim token" >&2; return 1; }
  oid="reply.$id.$(printf '%s' "$message" | cksum | awk '{print $1}')"
  latest="$(_obligation_latest_state "$oid")"
  if [ "$latest" = typing_started ]; then _obligation_delivery_unknown "$oid" "$id"; echo "delivery unknown; no automatic replay" >&2; return 1; fi
  # A preliminary probe avoids creating a permanent no-replay obligation for an
  # obviously busy composer.  It grants no authority, the locked final probe below does.
  composer="$(_external_composer_state "$pane" 2>/dev/null)"
  [ "$composer" = "empty" ] || { echo "external composer is unverified; no terminal input was sent" >&2; return 1; }
  _obligation_admit "$oid" "$id" || { echo "obligation $oid is pending; automatic replay is disabled" >&2; return 1; }
  _endpoint_mutation_lock "$pane" || return 1
  key="$(printf '%s' "$pane" | cksum | awk '{print $1}')"
  # Resolve the pane PID and prove its start marker at the exact mutation endpoint,
  # then make the composer check the final operation before typing.
  _claimed_endpoint_live "$pane" "$pid" "$start" || { _endpoint_mutation_unlock "$key"; return 1; }
  _obligation_append "$oid" "$id" typing_started "" || { _endpoint_mutation_unlock "$key"; return 1; }
  _obligation_guard_begin "$oid" "$id"
  # The final composer proof is deliberately the operation immediately before
  # the first typed byte. Durable crash intent precedes it.
  composer="$(_external_composer_state "$pane" 2>/dev/null)"
  [ "$composer" = "empty" ] || { _obligation_delivery_unknown "$oid" "$id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; echo "external composer is unverified; no terminal input was sent" >&2; return 1; }
  tmux send-keys -t "$pane" -l -- "$message" || { _obligation_delivery_unknown "$oid" "$id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1; }
  tmux send-keys -t "$pane" Enter || { _obligation_delivery_unknown "$oid" "$id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1; }
  receipt="$(_external_receipt_verify "$pane" "$oid" 2>/dev/null)"
  if _external_receipt_valid "$receipt" "$pane" "$oid" "$generation"; then
    _obligation_append "$oid" "$id" submitted "$receipt" || { _obligation_delivery_unknown "$oid" "$id"; _endpoint_mutation_unlock "$key"; return 1; }
    _obligation_guard_end
    _endpoint_mutation_unlock "$key"
    printf 'receipt: %s\n' "$receipt"
  else
    _obligation_delivery_unknown "$oid" "$id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"
    echo "delivery unknown; no automatic replay" >&2
    return 1
  fi
}

_fleet_classify() {
  case "$1" in
    running|launching|stalled\?|exploring\?) printf 'working' ;;
    done|done?) printf 'completed' ;;
    blocked|permission-blocked) printf 'blocked' ;;
    failed|timeout|wedged|canceled|interrupted) printf 'dead' ;;
    idle) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

_fleet_snapshot_collect() {
  have jq || return 1
  local items='[]' d job state item now snapshot canonical generation
  if [ -d "$OSRC_JOBS" ]; then
    while IFS= read -r d; do
      job="$(OSRC_RECONCILE_READ_ONLY=1 _job_json "$(basename "$d")" 2>/dev/null)" || continue
      state="$(_fleet_classify "$(printf '%s' "$job" | jq -r '.status // "unknown"')")"
      item="$(printf '%s' "$job" | jq --arg fleet_state "$state" '
        {schema_version:"1",session_id:null,owner:"managed",harness:"job",lane:.provider,
         requested_model:.model,observed_model:.model,effort:.effort,endpoint:null,
         harness_pid:null,pid_start:null,started_at:.started,state:$fleet_state,
         state_evidence:(.status // "unknown"),composer_state:"unknown",claim:null,
         task_summary:(.label // .verb),last_receipt:null,source_generation:(.job_id // null),
         job_id:.job_id}')" || return 1
      items="$(jq -cn --argjson items "$items" --argjson item "$item" '$items + [$item]')" || return 1
    done < <(find "$OSRC_JOBS" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)
  fi
  items="$(_external_session_observations "$items")" || return 1
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  snapshot="$(jq -cn --arg captured_at "$now" --argjson items "$items" \
    '{schema_version:"1",generation:null,captured_at:$captured_at,items:$items}')" || return 1
  canonical="$(printf '%s' "$snapshot" | jq -cS '.items | sort_by(.job_id // .session_id // "unknown")')" || return 1
  generation="$(printf '%s' "$canonical" | cksum | awk '{print $1 "-" $2}')"
  [ -n "$generation" ] || return 1
  printf '%s' "$snapshot" | jq -c --arg generation "$generation" '.generation=$generation'
}

_fleet_snapshot_write() {
  local snapshot="$1" tmp
  have jq || return 1
  printf '%s' "$snapshot" | jq -e '(.schema_version == "1") and ((.items | type) == "array")' >/dev/null 2>&1 || return 1
  _mkdir_private "$OSRC_HOME" || return 1
  [ ! -L "$OSRC_FLEET_SNAPSHOT" ] || return 1
  tmp="$OSRC_HOME/.fleet-snapshot.$$.$RANDOM.tmp"
  ( umask 077; printf '%s\n' "$snapshot" > "$tmp" ) 2>/dev/null || return 1
  _state_sync "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$OSRC_FLEET_SNAPSHOT" || { rm -f "$tmp"; return 1; }
  chmod 600 "$OSRC_FLEET_SNAPSHOT" 2>/dev/null || true
  _state_sync "$OSRC_HOME" || return 1
}

_fleet_snapshot_read() {
  [ -f "$OSRC_FLEET_SNAPSHOT" ] || return 1
  [ ! -L "$OSRC_FLEET_SNAPSHOT" ] || return 1
  have jq || return 1
  jq -e '(.schema_version == "1") and ((.items | type) == "array")' "$OSRC_FLEET_SNAPSHOT" >/dev/null || return 1
  cat "$OSRC_FLEET_SNAPSHOT"
}

_fleet_digest() {
  local snapshot="${1:-}" section filter
  [ -n "$snapshot" ] || snapshot="$(_fleet_snapshot_read)" || return 1
  for section in "Captain's Call" "Recently Landed" Underway "Charted Next"; do
    case "$section" in
      "Captain's Call") filter='.state == "blocked" or .state == "unknown"' ;;
      "Recently Landed") filter='.state == "completed" or .state == "dead"' ;;
      Underway) filter='.state == "working"' ;;
      "Charted Next") filter='.state == "idle"' ;;
    esac
    printf '%s\n' "$section"
    printf '%s' "$snapshot" | jq -r ".items[] | select($filter) | \"- \(.job_id // .session_id // \"unknown\") [\(.state)] \(.task_summary // \"unknown\")\"" || return 1
  done
}

_heartbeat_line() {
  local snapshot="${1:-}"
  [ -n "$snapshot" ] || snapshot="$(_fleet_snapshot_read)" || return 1
  # The pulse summarizes the supervised fleet and enumerates only actionable work. Read-only
  # external observations are counted compactly as `ext=` and detailed on demand by the rundown,
  # so a machine with many idle terminals does not bury the one status line in noise.
  printf '%s' "$snapshot" | jq -r '
    (.items | map(select(.owner != "external"))) as $m
    | (.items | map(select(.owner == "external")) | length) as $ext
    | [
      "♥ working=\([$m[] | select(.state == "working")] | length) blocked=\([$m[] | select(.state == "blocked")] | length) unknown=\([$m[] | select(.state == "unknown")] | length) landed=\([$m[] | select(.state == "completed" or .state == "dead")] | length)\(if $ext > 0 then " ext=\($ext)" else "" end)",
      ([$m[] | select(.state == "working" or .state == "blocked" or .state == "unknown")
        | "\(if .state == "working" then "▶" elif .state == "blocked" then "!" else "?" end) \(.job_id // .session_id // "unknown"): \(.observed_model // "unknown")@\(.lane // "unknown") · \(.task_summary // "unknown")"]
       | if length == 0 then "" else " | " + join(" | ") end),
      ([.items[] | select(.model_pin? != null)
        | "flip \(.session_id // "unknown") \(.model_pin.requested)->\(.model_pin.observed) [\(.model_pin.result)]"]
       | if length == 0 then "" else " | " + join(" | ") end)
    ] | join("")'
}

_wake_append() {
  local event="$1" now
  have jq || return 1
  printf '%s' "$event" | jq -e '.event_id | type == "string" and test("^[A-Za-z0-9._-]+$")' >/dev/null 2>&1 || return 1
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  event="$(printf '%s' "$event" | jq -c --arg created_at "$now" '. + {schema_version:"1",created_at:$created_at}')" || return 1
  _state_append "$OSRC_WAKE_QUEUE" "$event"
}

_wake_ack() {
  local event_id="$1" now record
  case "$event_id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  record="$(jq -cn --arg id "$event_id" --arg acked_at "$now" '{schema_version:"1",event_id:$id,acked_at:$acked_at}')" || return 1
  _state_append "$OSRC_WAKE_ACK" "$record"
}

_wake_drain() {
  have jq || return 1
  local acks line id
  acks="$(_state_jsonl_read "$OSRC_WAKE_ACK" 2>/dev/null | jq -r '.event_id // empty' 2>/dev/null)"
  while IFS= read -r line; do
    id="$(printf '%s' "$line" | jq -r '.event_id // empty')"
    [ -n "$id" ] || continue
    case "
$acks
" in *"
$id
"*) ;; *) printf '%s\n' "$line" ;; esac
  done < <(_state_jsonl_read "$OSRC_WAKE_QUEUE")
}

_wake_consume() {
  # The durable log is the authority sink.  Attached output is best-effort but
  # unacknowledged on failure, so its next heartbeat retries the same wake.
  local event id line
  while IFS= read -r event; do
    [ -n "$event" ] || continue
    id="$(printf '%s' "$event" | jq -r '.event_id // empty')"; [ -n "$id" ] || continue
    line="wake[$id] $(printf '%s' "$event" | jq -r '.task_summary // .kind // "unknown"')"
    _heartbeat_log_append "$line" || return 1
    _heartbeat_emit_attached "$line" || continue
    _wake_ack "$id" || return 1
  done < <(_wake_drain)
}

_pid_start_valid() {
  local marker="$1" weekday month day clock year
  set -- $marker
  [ "$#" -eq 5 ] || return 1
  weekday="$1"; month="$2"; day="$3"; clock="$4"; year="$5"
  case "$weekday:$month" in
    [[:alpha:]][[:alpha:]][[:alpha:]]:[[:alpha:]][[:alpha:]][[:alpha:]]) ;;
    *) return 1 ;;
  esac
  case "$day" in [0-9]|[0-3][0-9]) ;; *) return 1 ;; esac
  case "$clock" in [01][0-9]:[0-5][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]:[0-5][0-9]) ;; *) return 1 ;; esac
  case "$year" in [0-9][0-9][0-9][0-9]) ;; *) return 1 ;; esac
}

_pid_start_identity() {
  local pid="$1" marker self_marker
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  marker="$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g')"
  if _pid_start_valid "$marker"; then
    printf '%s\n' "$marker"
    return 0
  fi
  self_marker="$(LC_ALL=C ps -o lstart= -p "$$" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g')"
  if _pid_start_valid "$self_marker"; then
    return 2
  fi
  return 1
}

_heartbeat_token() {
  local token
  token="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$token" ] || token="$(date +%s)-$$-$RANDOM-$RANDOM"
  printf '%s\n' "$token"
}

# Publish through a durable, identity-bearing sibling. A crash therefore leaves
# a reclaimable owner record, never an anonymous empty lock directory.
_heartbeat_pending_dir() { printf '%s.pending.%s.%s\n' "$1" "$2" "${3// /_}"; }
_heartbeat_remove_tree() { # <path>, constrained to a direct heartbeat child
  local tree="$1"
  case "$tree" in "$OSRC_HEARTBEAT"/*) ;; *) return 1 ;; esac
  [ ! -L "$tree" ] || return 1
  [ -e "$tree" ] || return 0
  rm -rf -- "$tree"
}
_heartbeat_pending_identity() { # <dir> -> pid<TAB>start
  local tail pid encoded
  tail="${1##*.pending.}"; pid="${tail%%.*}"; encoded="${tail#*.}"
  case "$pid:$encoded" in *[!A-Za-z0-9._:]*|*:) return 1 ;; esac
  printf '%s\t%s\n' "$pid" "${encoded//_/ }"
}
_heartbeat_reclaim_dead_pending() { # <canonical>
  local pending ident pid start live rc
  for pending in "$1".pending.*; do
    [ -d "$pending" ] || continue
    ident="$(_heartbeat_pending_identity "$pending")" || continue
    pid="${ident%%$'\t'*}"; start="${ident#*$'\t'}"
    _pid_start_valid "$start" || continue
    live="$(_pid_start_identity "$pid" 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] && [ "$live" != "$start" ] || continue
    _heartbeat_remove_tree "$pending" || return 1
  done
}
_heartbeat_publish_dir() { # <canonical> <pid> <pid-start> <record>
  local canonical="$1" pid="$2" start="$3" record="$4" pending tmp
  pending="$(_heartbeat_pending_dir "$canonical" "$pid" "$start")"
  _heartbeat_reclaim_dead_pending "$canonical" || return 1
  _mkdir_claim "$pending" || return 1
  tmp="$pending/.owner.$$.$RANDOM"
  ( umask 077; printf '%s\n' "$record" > "$tmp" ) 2>/dev/null || { rmdir "$pending" 2>/dev/null || true; return 1; }
  _state_sync "$tmp" || { rm -f "$tmp"; rmdir "$pending" 2>/dev/null || true; return 1; }
  mv "$tmp" "$pending/owner.json" || return 1
  _state_sync "$pending" || return 1
  # mkdir is the portable atomic directory claim. Do not use `mv pending
  # canonical`: when canonical appears between the check and mv, mv nests the
  # pending directory inside it on common hosts and leaves cleanup wedged.
  mkdir "$canonical" 2>/dev/null || return 1
  mv "$pending/owner.json" "$canonical/owner.json" || return 1
  _state_sync "$canonical" || return 1
  rmdir "$pending" 2>/dev/null || return 1
  _state_sync "$(dirname "$canonical")"
}

_heartbeat_election_acquire() { # <lock> <pid> <pid-start>
  local lock="$1" pid="$2" pid_start="$3" owner old_pid old_start live rc record
  if [ "${OSRC_FORCE_MKDIR_ELECTION:-0}" != 1 ] && command -v flock >/dev/null 2>&1; then
    exec 8>"$lock.flock" 2>/dev/null || return 1
    flock -w 5 8 2>/dev/null || { exec 8>&-; return 1; }
    _HEARTBEAT_ELECTION_KIND=flock
    return 0
  fi
  _heartbeat_reclaim_dead_pending "$lock" || return 1
  while [ -d "$lock" ]; do
    owner="$lock/owner.json"
    old_pid="$(jq -r '.pid // empty' "$owner" 2>/dev/null)" || return 1
    old_start="$(jq -r '.pid_start // empty' "$owner" 2>/dev/null)" || return 1
    _pid_start_valid "$old_start" || return 1
    live="$(_pid_start_identity "$old_pid" 2>/dev/null)"; rc=$?
    # Only a positive observation of PID reuse/death can recover a lease.
    if [ "$rc" -eq 0 ] && [ "$live" != "$old_start" ]; then
      rm -f "$owner" 2>/dev/null || return 1
      rmdir "$lock" 2>/dev/null || return 1
      continue
    fi
    return 1
  done
  record="$(jq -cn --argjson pid "$pid" --arg pid_start "$pid_start" '{pid:$pid,pid_start:$pid_start}')" || return 1
  _heartbeat_publish_dir "$lock" "$pid" "$pid_start" "$record" || return 1
  _HEARTBEAT_ELECTION_KIND=mkdir
}
_heartbeat_election_release() {
  local lock="$1"
  case "${_HEARTBEAT_ELECTION_KIND:-}" in flock) flock -u 8 2>/dev/null || true; exec 8>&- ;; mkdir) _heartbeat_remove_tree "$lock" || true ;; esac
  _HEARTBEAT_ELECTION_KIND=""
}

_heartbeat_claim() {
  local pid="$1" pid_start="$2" token="$3" sink="${4:-}" lock="$OSRC_HEARTBEAT/.election"
  local leader="$OSRC_HEARTBEAT/leader" owner="$OSRC_HEARTBEAT/leader/owner.json"
  local old_pid old_start live_start record rc=0
  [ "$OSRC_PLATFORM" != "windows" ] || return 1
  case "$pid:$token" in *[!A-Za-z0-9._:-]*) return 1 ;; esac
  [ -n "$pid_start" ] || return 1
  _mkdir_private "$OSRC_HEARTBEAT" || return 1
  [ ! -L "$OSRC_HEARTBEAT" ] && [ ! -L "$leader" ] || return 1
  _heartbeat_election_acquire "$lock" "$pid" "$pid_start" || return 1
  if [ -d "$leader" ]; then
    if [ ! -f "$owner" ] || ! old_pid="$(jq -er '.pid | tostring' "$owner" 2>/dev/null)" \
      || ! old_start="$(jq -er '.pid_start | strings | select(length > 0)' "$owner" 2>/dev/null)"; then
      # The canonical directory is created atomically before owner.json is
      # promoted. A crashed publisher can therefore leave an owner-less tree;
      # the election lock makes it safe for the next claimant to reclaim it.
      _heartbeat_remove_tree "$leader" || { _heartbeat_election_release "$lock"; return 1; }
    elif ! _pid_start_valid "$old_start"; then
      _heartbeat_election_release "$lock"
      return 3
    else
      live_start="$(_pid_start_identity "$old_pid" 2>/dev/null)"; rc=$?
      if [ "$rc" -eq 0 ] && [ "$live_start" = "$old_start" ]; then
        _heartbeat_election_release "$lock"
        return 2
      fi
      # Keep an incumbent unless we positively observed its PID with a different
      # start marker. Unsupported/failed identity adapters are never stale proof.
      if [ "$rc" -ne 0 ]; then
        _heartbeat_election_release "$lock"
        return 3
      fi
      _heartbeat_remove_tree "$leader" || { _heartbeat_election_release "$lock"; return 1; }
    fi
  fi
  record="$(jq -cn --argjson pid "$pid" --arg pid_start "$pid_start" --arg token "$token" --arg sink "$sink" \
    '{schema_version:"1",pid:$pid,pid_start:$pid_start,token:$token,sink:(if $sink=="" then null else $sink end)}')" || rc=1
  [ "$rc" -ne 0 ] || _heartbeat_publish_dir "$leader" "$pid" "$pid_start" "$record" || rc=1
  _heartbeat_election_release "$lock"
  [ "$rc" -eq 0 ]
}

_heartbeat_cursor_read() {
  local name="$1" file="$OSRC_HEARTBEAT/$1.cursor"
  case "$name" in wakes|render) ;; *) return 1 ;; esac
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  sed -n '1p' "$file"
}

_heartbeat_cursor_write() {
  local name="$1" generation="$2" file tmp
  case "$name" in wakes|render) ;; *) return 1 ;; esac
  file="$OSRC_HEARTBEAT/$name.cursor"
  [ ! -L "$file" ] || return 1
  tmp="$OSRC_HEARTBEAT/.$name.cursor.$$.$RANDOM"
  ( umask 077; printf '%s\n' "$generation" > "$tmp" ) 2>/dev/null || return 1
  _state_sync "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  _state_sync "$OSRC_HEARTBEAT"
}

_heartbeat_log_append() {
  local line="$1" log="$OSRC_HEARTBEAT/heartbeat.log" rc=0
  _mkdir_private "$OSRC_HEARTBEAT" || return 1
  [ ! -L "$log" ] || return 1
  ( umask 077; : >> "$log" ) 2>/dev/null || return 1
  _state_lock_acquire "$log" || return 1
  printf '%s\n' "$line" >> "$log" 2>/dev/null || rc=1
  [ "$rc" -ne 0 ] || _state_sync "$log" || rc=1
  _state_lock_release "$log"
  [ "$rc" -eq 0 ]
}

_heartbeat_unknown_snapshot() {
  local now generation
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  generation="unknown-$(date +%s)"
  jq -cn --arg captured_at "$now" --arg generation "$generation" \
    '{schema_version:"1",generation:$generation,captured_at:$captured_at,items:[{schema_version:"1",session_id:null,owner:null,harness:"heartbeat",lane:null,requested_model:null,observed_model:null,effort:null,endpoint:null,harness_pid:null,pid_start:null,started_at:null,state:"unknown",state_evidence:"snapshot unavailable",composer_state:"unknown",claim:null,task_summary:"fleet state unavailable",last_receipt:null,source_generation:$generation,job_id:null}]}'
}

_heartbeat_emit_attached() {
  local line="$1" sink="${OSRC_HEARTBEAT_SINK:-}"
  [ -n "$sink" ] || return 0
  if [ "$sink" = "-" ]; then
    printf '%s\n' "$line"
  elif [ -e "$sink" ] && [ -w "$sink" ]; then
    printf '%s\n' "$line" >> "$sink"
  else
    return 1
  fi
}

_model_pin_enforce_item() { # <fleet-item> <snapshot-generation>
  local item="$1" snapshot_generation="$2" session_id owner state lane endpoint requested resolved observed model_generation event_id lock restore_id result=reported
  session_id="$(printf '%s' "$item" | jq -r '.session_id // empty')"
  owner="$(printf '%s' "$item" | jq -r '.owner // empty')"
  state="$(printf '%s' "$item" | jq -r '.state // "unknown"')"
  lane="$(printf '%s' "$item" | jq -r '.lane // empty')"
  endpoint="$(printf '%s' "$item" | jq -r '.endpoint // empty')"
  requested="$(printf '%s' "$item" | jq -r '.requested_model // empty')"
  resolved="$(printf '%s' "$item" | jq -r '.resolved_model // .requested_model // empty')"
  observed="$(printf '%s' "$item" | jq -r '.observed_model // "unknown"')"
  model_generation="$(printf '%s' "$item" | jq -r '.model_generation // 1')"
  [ -n "$session_id" ] && [ -n "$requested" ] && [ "$observed" != unknown ] || { printf '%s' "$item"; return; }
  _session_model_matches "$requested" "$resolved" "$observed" && { printf '%s' "$item"; return; }
  event_id="model-drift.$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9._-').$snapshot_generation"
  _wake_append "$(jq -cn --arg event_id "$event_id" --arg generation "$snapshot_generation" --arg session_id "$session_id" --arg requested "$requested" --arg observed "$observed" '{event_id:$event_id,kind:"model-drift",generation:$generation,session_id:$session_id,state:"blocked",task_summary:("model drifted " + $requested + "->" + $observed)}')" >/dev/null 2>&1 || result=unknown
  # Automatic input is restricted to an actively working managed session with both proof adapters.
  # External, idle, terminal, and unknown sessions are reported only.
  if [ "$result" = reported ] && [ "$owner" = managed ] && [ "$state" = working ] && [ -n "$lane" ] && [ -n "$endpoint" ] \
     && _model_pin_restore_allowed "$session_id" "$model_generation"; then
    lock="$OSRC_SESSIONS/model-pin-${session_id}.${model_generation}.lock"
    if _mkdir_claim "$lock"; then
      restore_id="restore.${session_id}.${model_generation}"
      if _model_pin_append "$session_id" "$model_generation" restore-attempt "$requested->$observed"; then
        if _session_model_restore "$lane" "$endpoint" "$resolved" "$restore_id" "$session_id"; then
          _model_pin_append "$session_id" "$model_generation" restore-receipt "$restore_id" >/dev/null 2>&1 || result=unknown
          [ "$result" = unknown ] || result=restored
        else
          result=restore-failed
        fi
      else
        result=unknown
      fi
      rmdir "$lock" 2>/dev/null || true
    fi
  fi
  printf '%s' "$item" | jq -c --arg requested "$requested" --arg observed "$observed" --arg result "$result" '. + {task_summary:("model drifted " + $requested + "->" + $observed),model_pin:{requested:$requested,observed:$observed,result:$result}}'
}

_heartbeat_tick() {
  local snapshot generation wake_cursor render_cursor item event_id line wake_ok=1 pinned_items='[]' pinned
  _obligation_recover_stranded >/dev/null 2>&1 || true
  snapshot="$(_fleet_snapshot_collect 2>/dev/null)" || snapshot="$(_heartbeat_unknown_snapshot)" || return 1
  generation="$(printf '%s' "$snapshot" | jq -r '.generation // "unknown"')"
  if ! _fleet_snapshot_write "$snapshot"; then
    snapshot="$(_heartbeat_unknown_snapshot)" || return 1
    generation="$(printf '%s' "$snapshot" | jq -r '.generation')"
    _fleet_snapshot_write "$snapshot" >/dev/null 2>&1 || true
  fi
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    pinned="$(_model_pin_enforce_item "$item" "$generation")" || pinned="$item"
    pinned_items="$(jq -cn --argjson items "$pinned_items" --argjson item "$pinned" '$items + [$item]')" || return 1
  done < <(printf '%s' "$snapshot" | jq -c '.items[]')
  snapshot="$(printf '%s' "$snapshot" | jq -c --argjson items "$pinned_items" '.items=$items')" || return 1
  _fleet_snapshot_write "$snapshot" >/dev/null 2>&1 || true
  wake_cursor="$(_heartbeat_cursor_read wakes 2>/dev/null)"
  if [ "$wake_cursor" != "$generation" ]; then
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      event_id="heartbeat.$generation.$(printf '%s' "$item" | jq -r '(.job_id // .session_id // "fleet") | gsub("[^A-Za-z0-9._-]"; "_")').$(printf '%s' "$item" | jq -r '.state')"
      _wake_append "$(printf '%s' "$item" | jq -c --arg event_id "$event_id" --arg generation "$generation" \
        '{event_id:$event_id,kind:"fleet-state",generation:$generation,state:.state,job_id:.job_id,session_id:.session_id,task_summary:.task_summary}')" || wake_ok=0
    done < <(printf '%s' "$snapshot" | jq -c '.items[] | select((.owner != "external") and (.state == "blocked" or .state == "unknown" or .state == "dead"))')
    [ "$wake_ok" -eq 0 ] || _heartbeat_cursor_write wakes "$generation" || wake_ok=0
  fi
  render_cursor="$(_heartbeat_cursor_read render 2>/dev/null)"
  [ "$render_cursor" != "$generation" ] || return "$((wake_ok == 1 ? 0 : 1))"
  line="$(_heartbeat_line "$snapshot" 2>/dev/null)" || line='♥ working=0 blocked=0 unknown=1 landed=0'
  [ "$wake_ok" -eq 1 ] || line="$line state=unknown"
  _heartbeat_log_append "$line" || {
    _wake_append "$(jq -cn --arg event_id "heartbeat.$generation.log" --arg generation "$generation" \
      '{event_id:$event_id,kind:"heartbeat-sink",generation:$generation,state:"unknown",task_summary:"heartbeat log unavailable"}')" >/dev/null 2>&1 || true
    _heartbeat_emit_attached "$line state=unknown" >/dev/null 2>&1 || true
    return 1
  }
  _wake_consume || true
  if ! _heartbeat_emit_attached "$line"; then
    _wake_append "$(jq -cn --arg event_id "heartbeat.$generation.attached" --arg generation "$generation" \
      '{event_id:$event_id,kind:"heartbeat-sink",generation:$generation,state:"unknown",task_summary:"attached heartbeat sink unavailable"}')" >/dev/null 2>&1 || true
    return 1
  fi
  # render.cursor is a delivery acknowledgement, never an intent marker.
  _heartbeat_cursor_write render "$generation" || return 1
  [ "$wake_ok" -eq 1 ]
}

_heartbeat_stop() {
  local token="${1:-${OSRC_HEARTBEAT_TOKEN:-}}" owner="$OSRC_HEARTBEAT/leader/owner.json"
  local saved_token lock="$OSRC_HEARTBEAT/.election" pid_start rc=0
  [ -n "$token" ] && [ -f "$owner" ] || return 0
  pid_start="$(_pid_start_identity "$$" 2>/dev/null)" || return 1
  _heartbeat_election_acquire "$lock" "$$" "$pid_start" || return 1
  saved_token="$(jq -r '.token // empty' "$owner" 2>/dev/null)"
  if [ "$saved_token" != "$token" ]; then
    _heartbeat_election_release "$lock"
    return 1
  fi
  _heartbeat_remove_tree "$OSRC_HEARTBEAT/leader" || rc=1
  _heartbeat_election_release "$lock"
  [ "$rc" -eq 0 ]
}

_heartbeat_is_owner() {
  local token="$1" pid="$2" pid_start="$3" owner="$OSRC_HEARTBEAT/leader/owner.json"
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 1
  jq -e --arg token "$token" --argjson pid "$pid" --arg pid_start "$pid_start" \
    '.token==$token and .pid==$pid and .pid_start==$pid_start' "$owner" >/dev/null 2>&1
}

_heartbeat_active_work() {
  local jd status
  [ -d "$OSRC_JOBS" ] || return 1
  for jd in "$OSRC_JOBS"/*; do
    [ -d "$jd" ] || continue
    status="$(cat "$jd/status" 2>/dev/null || true)"
    case "$status" in launching|running|exploring?|stalled?) return 0 ;; esac
  done
  return 1
}

_heartbeat_beacon() {
  local token="${1:-${OSRC_HEARTBEAT_TOKEN:-}}" cadence="${OSRC_HEARTBEAT_CADENCE:-300}"
  local pid_start rc
  case "$cadence" in ''|*[!0-9]*|0) cadence=300 ;; esac
  [ -n "$token" ] || token="$(_heartbeat_token)"
  pid_start="$(_pid_start_identity "$$")" || {
    echo "outsourcerer: heartbeat ownership unknown; stable process identity unavailable" >&2
    return 1
  }
  _heartbeat_claim "$$" "$pid_start" "$token" "${OSRC_HEARTBEAT_SINK:-}"; rc=$?
  case "$rc" in
    0) ;;
    2) return 0 ;;
    *) echo "outsourcerer: heartbeat ownership unknown; preserving the existing leader" >&2; return 1 ;;
  esac
  trap '_heartbeat_stop "$token"' EXIT
  trap 'exit 0' INT TERM
  while :; do
    _heartbeat_is_owner "$token" "$$" "$pid_start" || return 0
    _heartbeat_tick || true
    [ "${OSRC_HEARTBEAT_ONCE:-0}" = "1" ] && break
    # A beacon exists only to watch supervised work.  Do not leave a sleeping
    # 300-second process after the final job finishes.
    _heartbeat_active_work || break
    sleep "$cadence"
  done
}

_heartbeat_start() {
  local token executable sink="${OSRC_HEARTBEAT_SINK:-}"
  [ "$OSRC_PLATFORM" != "windows" ] || return 1
  [ "${OSRC_HEARTBEAT_DISABLED:-0}" = "1" ] && return 0
  # The background status beacon auto-arms only when supervision is opted into.
  [ "${OSRC_FLEET_SUPERVISION:-0}" = "1" ] || return 0
  _mkdir_private "$OSRC_HEARTBEAT" || return 1
  if [ -z "$sink" ] && { [ -t 0 ] || [ -t 1 ] || [ -t 2 ]; }; then sink="/dev/tty"; fi
  token="$(_heartbeat_token)"
  executable="${OSRC_HEARTBEAT_EXECUTABLE:-$SCRIPT_PATH}"
  [ -x "$executable" ] || return 1
  OSRC_HEARTBEAT_TOKEN="$token" OSRC_HEARTBEAT_SINK="$sink" \
    nohup "$executable" __heartbeat-beacon "$token" >/dev/null 2>&1 &
  return 0
}

cmd_rundown() {
  local snapshot
  snapshot="$(_fleet_snapshot_collect 2>/dev/null)" || snapshot="$(_heartbeat_unknown_snapshot)" || return 1
  _fleet_digest "$snapshot"
}

cmd_bearings() {
  local snapshot
  snapshot="$(_fleet_snapshot_read 2>/dev/null)" || snapshot="$(_heartbeat_unknown_snapshot)" || return 1
  _fleet_digest "$snapshot"
}

# =============================================================================
# CREW / LEARNING LEDGER (slice 1+2). Additive: cost rows stay in ledger.jsonl
# (untouched by these readers); OUTCOME rows live in a SEPARATE outcomes-YYYYMM.jsonl
# so no existing cost/tab reader ever has to dedupe two shapes. run_id joins them.
# No flock: every line is short (<512B) and emitted with one printf (atomic under PIPE_BUF).
# =============================================================================

# _ensure_run_id -> echo a durable run id, minting+exporting one if unset.
_ensure_run_id() {
  [ -n "${OSRC_RUN_ID:-}" ] && { printf '%s' "$OSRC_RUN_ID"; return 0; }
  local rid; rid="$(date -u +%Y%m%dT%H%M%S)-$$-${RANDOM:-0}"
  export OSRC_RUN_ID="$rid"; printf '%s' "$rid"
}

# _repo_key -> a stable, NON-PII repository identity (cksum only; never the URL/path in plaintext).
# Prefers the normalized origin remote; falls back to a hash of the repo root, then cwd.
_repo_key() {
  local u root
  u="$(git config --get remote.origin.url 2>/dev/null)"
  if [ -n "$u" ]; then u="${u%.git}"; printf '%s' "$u" | cksum | cut -d' ' -f1; return 0; fi
  root="$(git rev-parse --show-toplevel 2>/dev/null)"; [ -n "$root" ] || root="$PWD"
  printf '%s' "$root" | cksum | cut -d' ' -f1
}

# Outcome files: current month is written; readers glob all monthly files + a legacy flat file.
_outcomes_current() { printf '%s/outcomes-%s.jsonl' "$OSRC_HOME" "$(date +%Y%m)"; }
_outcomes_files()   { ls "$OSRC_HOME"/outcomes.jsonl "$OSRC_HOME"/outcomes-*.jsonl 2>/dev/null; }

# record_outcome <outcome> [reason] [turns] [run_id] [lane] [model] [task_class] [repo_key]
# Writes ONE terminal outcome row. Denormalized (carries lane/model/task_class/repo_key) so the
# advise fold needs no join. Only passed/failed/reverted feed learning; everything else is excluded.
record_outcome() {
  have jq || return 0
  local outcome="$1" reason="${2:-}" turns="${3:-}"
  local rid="${4:-${OSRC_RUN_ID:-}}" lane="${5:-${OSRC_LANE:-}}" model="${6:-${OSRC_MODEL:-}}"
  local tc="${7:-${OSRC_TASK_CLASS:-}}" rk="${8:-${OSRC_REPO_KEY:-}}"
  [ -n "$outcome" ] || return 0
  # Validate the learning-bearing fields so a future caller (slice-3 loop judges) can't poison the fold
  # or leak task-derived text. Unknown outcome -> `unknown` (recorded, not learnable) + a stderr note.
  case "$outcome" in
    passed|failed|reverted|blocked|abandoned|completed_unverified|unknown) ;;
    *) echo "outsourcerer: record_outcome got non-enum outcome '$outcome' -> recording as 'unknown'" >&2; outcome=unknown ;;
  esac
  # reason MUST be a fixed enum (never task text) — an unknown reason is dropped, not stored verbatim.
  case "$reason" in
    ''|test_failure|compile_failure|invalid_output|empty-output|permission_denied|consent_denied|secret_scan|provider_error|timeout|watchdog|merge_conflict|user_cancelled|missing_tool) ;;
    *) reason="" ;;
  esac
  # repo_key MUST be a cksum (numeric) or the PII guarantee breaks; turns MUST be numeric or omitted.
  case "$rk" in ''|*[!0-9]*) rk="$(_repo_key)" ;; esac
  case "$turns" in *[!0-9]*) turns="" ;; esac
  [ -n "$rid" ] || rid="$(_ensure_run_id)"
  _mkdir_private "$OSRC_HOME" || true
  local f; f="$(_outcomes_current)"
  [ -e "$f" ] || ( umask 077; : > "$f" ) 2>/dev/null || true   # private from birth; never truncate an existing file
  chmod 600 "$f" 2>/dev/null || true
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line
  line="$(jq -cn --arg rid "$rid" --arg ts "$ts" --arg lane "$lane" --arg m "$model" \
     --arg tc "$tc" --arg rk "$rk" --arg o "$outcome" --arg r "$reason" --arg tu "$turns" \
     '{schema:2,event:"outcome",run_id:$rid,ts:$ts,lane:$lane,model:$m,task_class:$tc,repo_key:$rk,outcome:$o}
      + (if $r=="" then {} else {reason:$r} end)
      + (if $tu=="" then {} else {turns_used:($tu|tonumber)} end)')" || return 0
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" >> "$f" 2>/dev/null || true
}

# _status_to_outcome <job-status> <exit-code> -> "outcome<TAB>reason". THE anti-poisoning gate:
# infra/consent/permission/provider failures map to blocked/abandoned, NEVER a learnable `failed`,
# and a checkless success is completed_unverified (not `passed`). Only the free gate / future checks
# write passed/failed/reverted. Extracted so this safety property is unit-testable.
_status_to_outcome() {
  local st="$1" sc="${2:-0}" oc rsn=""
  case "$st" in
    done)               oc=completed_unverified ;;
    permission-blocked) oc=blocked;   rsn=permission_denied ;;
    blocked)            oc=blocked ;;
    timeout)            oc=abandoned; rsn=timeout ;;
    wedged)             oc=abandoned; rsn=watchdog ;;
    interrupted)        oc=abandoned; rsn=user_cancelled ;;
    failed)             oc=blocked;   rsn=provider_error ;;
    *)                  if [ "${sc:-0}" -eq 0 ] 2>/dev/null; then oc=completed_unverified; else oc=blocked; rsn=provider_error; fi ;;
  esac
  printf '%s\t%s' "$oc" "$rsn"
}

# _history_mult <lane> <model> <category> -> "mult|n_eff|passed_eff|scope"
# Bayesian shrinkage toward a fixed neutral prior (0.70), 60-day half-life decay, clamped +/-20%.
# Zero history -> mult 1.00 by construction (NO cold-start penalty, NO threshold cliff). Buckets:
# (lane,repo_key,category) when it has n_eff>=3, else (lane,category) global. Portable: jq does the
# ISO date math, awk does the exponent (^ is POSIX awk, unlike jq's unreliable pow).
_history_mult() {
  local lane="$1" model="$2" cat="$3" rk
  rk="$(_repo_key)"
  # Collect outcome files into a QUOTED array — an OSRC_HOME with spaces (Git Bash, custom paths)
  # would word-split an unquoted list and silently disable learning.
  local -a ofiles=(); local _f
  while IFS= read -r _f; do [ -n "$_f" ] && ofiles+=("$_f"); done < <(_outcomes_files)
  { [ "${#ofiles[@]}" -gt 0 ] && have jq; } || { printf '1.00|0.00|0.00|none'; return 0; }
  # Emit "isrepo<TAB>age_days<TAB>passed" for learning-eligible rows within 90 days.
  # RESILIENT PARSE (-R + fromjson?): one malformed/partial line can't kill the whole fold.
  local rows
  rows="$(jq -rR --arg lane "$lane" --arg cat "$cat" --arg rk "$rk" '
    fromjson? // empty
    | select(.event=="outcome" and .lane==$lane and .task_class==$cat
           and (.outcome=="passed" or .outcome=="failed" or .outcome=="reverted"))
    # A bad/missing/non-ISO ts must NOT crash jq mid-stream (that silently truncated the fold — the
    # try/catch is downstream of fromjson? so it needs its own guard). Bad ts -> null -> dropped.
    | (try (.ts|fromdateiso8601) catch null) as $t
    | select($t != null)
    | ((now - $t) / 86400) as $age
    | select($age <= 90)
    # Clamp a future ts (clock skew / manual edit) to age 0 so its weight can never exceed 1 (no
    # phantom amplification of n_eff / bucket selection).
    | [ (if .repo_key==$rk then 1 else 0 end), (if $age<0 then 0 else $age end), (if .outcome=="passed" then 1 else 0 end) ]
    | @tsv
  ' "${ofiles[@]}" 2>/dev/null)"
  [ -n "$rows" ] || { printf '1.00|0.00|0.00|none'; return 0; }
  printf '%s\n' "$rows" | awk -F'\t' '
    # Bucket SELECTION uses the raw observation count (>=3 real repo runs); the shrinkage MATH uses the
    # decayed sums. (Selecting on the decayed sum would miss "3 fresh runs" whose sum is ~2.9998.)
    NF<3 { next }   # skip any malformed TSV line (never miscount a partial row as weight-1/passed-0)
    { w=0.5^($2/60); tw+=w; tp+=w*$3; if($1==1){rw+=w; rp+=w*$3; rc++} }
    END{
      K=8; prior=0.70;
      # Repo bucket needs BOTH >=3 real observations AND >=2.5 effective weight, so 3 FRESH runs
      # select repo but 3 STALE ones (decayed <2.5) fall back to a rich fresh global set.
      if(rc>=3 && rw>=2.5){ n=rw; s=rp; scope="repo" } else { n=tw; s=tp; scope="global" }
      if(n<=0){ printf "1.00|0.00|0.00|none"; exit }
      mult=((K*prior)+s)/(prior*(K+n));
      if(mult<0.80)mult=0.80; if(mult>1.20)mult=1.20;
      printf "%.2f|%.2f|%.2f|%s", mult, n, s, scope;
    }'
}

# _free_gate <kind> <payload> -> returns 0 pass / 1 fail / 2 unknown (tri-state; never suppresses
# escalation on absence of evidence). Zero-LLM, zero-cost, no installs, no state mutation.
#   kind=json   valid JSON?           kind=nonempty  artifact present?
#   kind=patch  git apply --check     kind=shell     bash -n on a file path
# Any unknown kind or missing tool -> 2 (unknown), preserving the paid path.
_free_gate() {
  local kind="$1" payload="${2:-}"
  case "$kind" in
    nonempty) [ -n "$payload" ] && return 0 || return 1 ;;
    json)     have jq || return 2; [ -n "$payload" ] || return 1
              # `jq empty` = parse-only: valid JSON (incl. falsy `false`/`null`) passes. NOT `jq -e .`,
              # which exits 1 on false/null and would wrongly FAIL a correct falsy answer.
              printf '%s' "$payload" | jq empty >/dev/null 2>&1 && return 0 || return 1 ;;
    patch)    have git || return 2; [ -n "$payload" ] || return 1
              printf '%s' "$payload" | git apply --check - >/dev/null 2>&1 && return 0 || return 1 ;;
    shell)    have bash || return 2; [ -f "$payload" ] || return 2
              bash -n -- "$payload" >/dev/null 2>&1 && return 0 || return 1 ;;
    *)        return 2 ;;
  esac
}

# _confident_fail <answer> -> 0 (+ prints a short reason on stdout) when the answer is a DETERMINISTIC
# reject: a refusal, a truncated artifact, or a violation of a machine-declared output shape. Returns 1
# otherwise. HARD INVARIANT: this NEVER returns "this answer is good". Absence of a fail signal is
# "can't tell", not a pass — a clean-looking answer can still be wrong, so it must still escalate. Only
# a confident fail is allowed to short-circuit a paid judge. Precision over recall, always: every branch
# is anchored/high-signal so a correct short answer is never rejected for $0 (that failure is invisible).
# Optional caller knobs (only the caller may declare a contract; NEVER inferred from prompt text):
#   OSRC_CONTRACT_KEYS  comma-separated required top-level JSON keys (answer must be an object with all)
#   OSRC_CONTRACT_RE    POSIX ERE the answer must match somewhere
_confident_fail() {
  local a="${1:-}" n
  [ -n "$a" ] || return 1
  # -- contract (strongest): only fires on a caller-declared shape. A structural miss is a certain fail;
  #    matching the shape proves nothing about correctness, so there is no "pass" branch here.
  if [ -n "${OSRC_CONTRACT_KEYS:-}" ] && have jq; then
    if ! printf '%s' "$a" | jq empty >/dev/null 2>&1; then echo "contract:not-json"; return 0; fi
    local k _oifs="$IFS"; IFS=,
    for k in $OSRC_CONTRACT_KEYS; do
      IFS="$_oifs"; k="$(printf '%s' "$k" | tr -d '[:space:]')"; [ -n "$k" ] || { IFS=,; continue; }
      printf '%s' "$a" | jq -e --arg k "$k" 'type=="object" and has($k)' >/dev/null 2>&1 \
        || { echo "contract:missing-key:$k"; return 0; }
      IFS=,
    done
    IFS="$_oifs"
  fi
  if [ -n "${OSRC_CONTRACT_RE:-}" ]; then
    # grep exit: 0=match, 1=no-match (a real violation), >=2=REGEX ERROR (caller typo). Only a clean 1 is
    # a violation; an invalid ERE is our fault, not the model's — skip it, never fire a misleading
    # contract:no-match on every call. Probe validity once on empty input first.
    if printf '' | grep -Eq -- "$OSRC_CONTRACT_RE" 2>/dev/null; [ $? -le 1 ]; then
      printf '%s' "$a" | grep -Eq -- "$OSRC_CONTRACT_RE" 2>/dev/null
      case $? in 1) echo "contract:no-match"; return 0 ;; esac
    fi
  fi
  # -- truncation: an ODD number of LINE-ANCHORED ``` fences is an unterminated code block ≈ a certain
  #    mid-stream cut. Count only fences that OPEN a line (a real markdown delimiter), so prose or a string
  #    that merely mentions ``` inline never trips it. (Deliberately NOT general bracket/quote balancing
  #    across prose — that is a false-positive minefield. And NO trailing-backslash signal — UNC paths /
  #    LaTeX / regex legitimately end in `\`, far too noisy to treat as a cut.)
  n="$(printf '%s\n' "$a" | grep -cE '^[[:space:]]*```' 2>/dev/null || echo 0)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ $((n % 2)) -eq 1 ]; then echo "truncation:unterminated-fence"; return 0; fi
  # -- refusal (highest false-positive risk, so the tightest gate): fire ONLY when ALL hold — the answer
  #    is short, has no code fence, is not JSON, STARTS with a refusal opener, carries a refusal-COMPLETION
  #    token (help/assist/with that/…), and has NO pivot to content (", but", "however", "the fix", "here",
  #    "instead", "you can/could/should", "try", or a ":"-led answer). The opener ALONE is not enough:
  #    "I can't guarantee X, but the fix is Y" and "I can't wait to ship this" are correct answers, not
  #    refusals — the completion-token requirement plus the no-pivot veto reject them. No "as an AI" opener
  #    (it fires on "As an AI researcher…"). ERE covers curly-apostrophe (’) variants. "No." and "you
  #    cannot call X before init" never match (no first-person opener).
  if [ "${#a}" -lt 400 ] \
     && ! printf '%s' "$a" | grep -q '```' 2>/dev/null \
     && ! { have jq && printf '%s' "$a" | jq empty >/dev/null 2>&1; } \
     && printf '%s' "$a" | grep -iqE "^[[:space:]]*(i['’]?m[[:space:]]+(sorry|afraid|unable)|i[[:space:]]+am[[:space:]]+(sorry|afraid|unable)|i[[:space:]]+(cannot|can['’]?t|won['’]?t|will[[:space:]]+not)|(sorry|unfortunately),?[[:space:]]+i[[:space:]])" 2>/dev/null \
     && printf '%s' "$a" | grep -iqE "(help|assist|comply|with[[:space:]]+(that|this|your)|do[[:space:]]+(that|this)|provide[[:space:]]+(that|this)|answer[[:space:]]+(that|this)|complete[[:space:]]+(that|this|your)|fulfil)" 2>/dev/null \
     && ! printf '%s' "$a" | grep -iqE "(,[[:space:]]*but[[:space:]]|[[:space:]]however|the[[:space:]]+fix|fix:|instead|here('| i| is| are|,| you)|you[[:space:]]+(can|could|should)|try[[:space:]]|:[[:space:]]*[^[:space:]])" 2>/dev/null; then
    echo "refusal:template"; return 0
  fi
  return 1
}

# _gate_resolves <reason> -> 0 only for a reject class SAFE to resolve a second-opinion tie WITHOUT a
# paid judge. ONLY a caller-declared contract violation qualifies: the loser provably breaks the
# machine-declared shape and the winner provably matches it. A refusal (may be the correct answer to a
# harmful/impossible task) or a truncation heuristic (misfires on a legit fence) must ESCALATE instead
# — never silently hand the win to an unchecked answer.
_gate_resolves() {
  case "${1:-}" in contract:*) return 0 ;; *) return 1 ;; esac
}

refresh_models() {
  _mkdir_private "$OSRC_HOME" || true
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

# _or_credits_exhausted -> 0 only when the live OpenRouter balance is explicitly numeric and empty.
# A missing/unknown balance is a probe failure, not proof that a paid lane is usable.
_or_credits_exhausted() {
  local cred rem
  cred="$(or_credits 2>/dev/null)"
  rem="${cred##*remaining=}"; rem="${rem%% *}"
  awk -v n="$rem" 'BEGIN { exit !(n ~ /^[0-9]+([.][0-9]+)?$/ && n <= 0) }' 2>/dev/null
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

# ---- Hermes real-cost receipt from ~/.hermes/state.db ----
# Hermes pre-computes estimated_cost_usd + cost_status per session in its own SQLite DB. A guarded
# read-only query keyed on cwd + launch epoch gives real per-run receipts. Every failure path
# degrades to empty output (never errors), so the caller falls back to the labeled token estimate
# when the DB is absent, locked, schema-drifted, or the row has no usable cost -- identical honesty
# contract to _or_run_cost: a partial figure never masquerades as authoritative.

# _hermes_home -> the Hermes data directory. Honors HERMES_HOME when set, else ~/.hermes.
_hermes_home() {
  local raw="${HERMES_HOME:-}"
  if [ -n "$raw" ] && [ -d "$raw" ]; then printf '%s' "$raw"; else printf '%s/%s' "$HOME" ".hermes"; fi
}

# _hermes_db -> the path to Hermes's state.db.
_hermes_db() { printf '%s/state.db' "$(_hermes_home)"; }

# _hermes_run_cost <launch_epoch> -> real cost (6dp) from the single matching Hermes session row, or
# empty. Matches a sessions row whose cwd == $PWD AND started_at is within this run's window
# [launch, now + skew]. A row that predates this run's launch cannot authoritatively belong to it:
# the backward skew that used to be here let a session that started 1s BEFORE the launch epoch be
# blessed by the "exactly one row" check and its cost reported as this run's. The lower bound is now
# the launch epoch itself (no backward skew); the forward skew stays so a row recorded slightly after
# `now` (clock drift) is not excluded. Uses estimated_cost_usd only when the WHOLE value is a
# well-formed number AND cost_status (normalized case-insensitively, NULL/empty treated as unknown)
# is anything other than `unknown`; anything else (NULL cost, unknown/Unknown/NULL/empty status, or
# a malformed cost like `e` `+` `-` `.` `1e`) returns empty so the caller's labeled estimate is
# used. When two or more rows could plausibly match (a concurrent run in the same directory),
# returns EMPTY rather than guessing -- a wrong-but-exact cost is worse than no cost. sqlite3 is
# guarded; absent sqlite3 -> empty, never an error.
_hermes_run_cost() {
  local launch="$1"
  have sqlite3 || return 0
  local db; db="$(_hermes_db)"
  [ -f "$db" ] || return 0
  case "$launch" in ''|*[!0-9]*) return 0 ;; esac
  # Forward skew only: Hermes records started_at slightly after the launch epoch we captured (CLI
  # startup overhead), so the upper bound extends past `now`. The lower bound is the launch epoch
  # itself -- a row that started BEFORE this run's launch is from a PREVIOUS run, not this one, and
  # must not be admitted. The old backward skew (launch - 5) let a row at launch-1s match.
  local skew="${OSRC_HERMES_SKEW:-5}"
  case "$skew" in ''|*[!0-9]*) skew=5 ;; esac
  local cutoff="$launch"
  local now; now="$(date +%s)"
  local upper=$(( now + skew ))
  # Read-only open so no WAL/SHM side-effect files are created and a DB owned by a running Hermes
  # process is never locked out. Escape single quotes in PWD (doubling) so a path containing one
  # cannot break the query -- worst case the query fails and returns empty (correct degradation).
  local cwd_escaped; cwd_escaped="$(printf '%s' "$PWD" | sed "s/'/''/g")"
  # Fetch ALL matching rows (not just the newest). A single unambiguous row is the only case that
  # yields a cost; two or more means the match is ambiguous and a guess would attribute another
  # run's spend to this one.
  local rows
  rows="$(sqlite3 -readonly "$db" \
    ".timeout ${OSRC_SQLITE_BUSY_TIMEOUT:-3000}" \
    "SELECT estimated_cost_usd, cost_status FROM sessions WHERE cwd = '${cwd_escaped}' AND started_at >= ${cutoff} AND started_at <= ${upper};" 2>/dev/null)" || return 0
  [ -n "$rows" ] || return 0
  # Count matching rows. Two or more plausibly-matching rows -> ambiguous -> empty (estimate).
  local _nlines
  _nlines="$(printf '%s\n' "$rows" | grep -c . 2>/dev/null)" || _nlines=0
  [ "$_nlines" -eq 1 ] || return 0
  # The row is "cost|status" (pipe-separated by sqlite3's default). Split it.
  local cost status
  cost="${rows%%|*}"
  status="${rows#*|}"
  # A NULL cost is not authoritative -> empty.
  [ "$cost" = "" ] && return 0
  # Authority check: match the bundled reference (hermes_refs/hermes_session.py:402), which uses
  # the cost whenever `raw_cost is not None and cost_status != "unknown"`. Normalize exactly as
  # the reference does: `str(row.get("cost_status") or "unknown").lower()` -- NULL/empty becomes
  # "unknown", and the comparison is case-insensitive. The previous round invented an allowlist of
  # exactly `complete|final`, which discarded legitimate receipts (e.g. cost_status='calculated'
  # with a valid cost) and fell back to an estimate. "Not unknown" is the reference bar: a
  # non-NULL, well-formed cost whose status is anything other than unknown (after normalization)
  # is authoritative.
  local _norm_status
  case "$status" in
    '') _norm_status="unknown" ;;
    *)  _norm_status="$(printf '%s' "$status" | tr 'A-Z' 'a-z')" ;;
  esac
  [ "$_norm_status" != "unknown" ] || return 0
  # Validate the WHOLE value is a well-formed number before formatting. The old character-class
  # check (`*[!0-9.eE+-]**)` admitted `e`, `+`, `-`, `.`, and `1e` because they contain ONLY
  # characters from the allowed set -- then `printf '%.6f'` coerced each to 0.000000, recording a
  # fabricated measured cost. This regex requires a proper mantissa (digits with optional dot, or
  # dot+digits) and a proper exponent (e/E, optional sign, at least one digit) if present.
  printf '%s' "$cost" | awk '
    {
      if ($0 ~ /^([+-]?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][+-]?[0-9]+)?)$/) exit 0
      exit 1
    }
  ' || return 0
  # Format to 6 decimal places, mirroring _or_run_cost's %.6f so the two lanes
  # agree on precision. SQLite drops trailing zeros on a REAL (0.077700 -> 0.0777),
  # which would make the ledger figure disagree with the OpenRouter lane's format.
  # The empty-return paths above (NULL, non-final status, malformed cost) all `return 0` before
  # reaching here, so formatting never turns "no authoritative figure" into 0.000000.
  printf '%.6f' "$cost"
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

# ---- SESSION LIMIT AWARENESS (copilot conserve engine). Best-effort, degrade gracefully:
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
    #   LOCAL uses neither cash nor a plan. PLAN = native cx/cc/gm, keyless gpt-image, Devin Pro,
    #   and Cursor. CASH = cc/codex->OpenRouter, Gemini API, and engine lanes whose configured
    #   model may use BYOK billing.
    #   devin (dv): PLAN when $0 (Pro tier), but a NONZERO measured/estimated cost = pay-per-use = CASH
    #   (the bucket is decided on the cost axis, not the lane alone, so paid devin is never hidden).
    def bucket:
      (.lane // "") as $l | (.provider // "") as $p | (.verb // "") as $v
      | if ($l == "local") or ($p == "local") then "free"
        elif $l == "dv" then (if (cashnum > 0) then "cash" else "plan" end)
        elif ($l | test("^(cx|cc|gm|cursor)$"))
          or ($p | test("^(codex-native|claude-native|antigravity-agy|claudex|cursor)$"))
          or ($p == "devin" and cashnum == 0)
          or ($v == "image" and $p == "codex") then "plan"
        else "cash" end;
    def planname:
      (.lane // "") as $l | (.provider // "") as $p
      | if ($l == "cx") or ($p | test("^(codex-native|claudex)$")) then "ChatGPT"
        elif ($l == "cc") or ($p == "claude-native") then "Claude"
        elif ($l == "gm") or ($p == "antigravity-agy") then "Antigravity"
        elif ($l == "cursor") or ($p == "cursor") then "Cursor"
        elif ($l == "dv") or ($p == "devin") then "Devin"
        elif (.verb == "image" and $p == "codex") then "ChatGPT"
        else "unknown" end;
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
      "subscription / included : \($subs) run(s)",
      ([ .[] | select(bucket=="plan") ] | group_by(planname)[]
        | "  \(.[0] | planname): \(length) run(s), $0 cash, spends your \(.[0] | planname) plan limits"),
      (if $free > 0 then "on your hardware (local): \($free) run(s), $0 cash + $0 plan, fully private" else empty end),
      "by model:",
      (group_by(.model)[] | "  \(.[0].model // "(unknown)")  \(length) run(s)")
  ' --arg led "$OSRC_LEDGER" 2>/dev/null || echo "(ledger parse error)"
  [ "$_bad" -gt 0 ] && echo "  note: skipped $_bad unparseable ledger line(s) (corrupted/interleaved append) — Tab totals exclude them." >&2
  # Real ChatGPT-plan headroom (5h + weekly) when Codex has recorded it, the true cost of the
  # "no cash" sub lane. Best-effort; silent if unavailable.
  local ql; ql="$(_codex_quota_line 2>/dev/null)" && [ -n "$ql" ] && echo "  $ql"
  echo 'note: subscription and included-credit lanes have $0 cash cost but spend finite plan limits.'
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
  echo "  ChatGPT native                    $(_lane_cost_disclosure cx)"
  echo "  Claude native                     $(_lane_cost_disclosure cc)"
  echo "  Antigravity keyless               $(_lane_cost_disclosure gm)"
  echo "  Devin                              $(_lane_cost_disclosure dv)"
  echo "  local                              $(_lane_cost_disclosure local)"
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
  echo "== outsourcerer suggest, low-cash and plan-included models you can use right now =="
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
      echo "-- Devin, live on your plan ($(_lane_cost_disclosure dv)) --"
      printf '%s\n' "$dlm" | tr ',' '\n' | sed 's/^[[:space:]]*/   /' | grep -v '^[[:space:]]*$' | head -20
      echo
    fi
  fi
  echo "-- On your subscriptions and included allocations --"
  echo "   Codex: sol / terra / luna / gpt-5.x, $(_lane_cost_disclosure cx)"
  echo "   Claude: fable / opus / sonnet / haiku, $(_lane_cost_disclosure cc)"
  echo "   Antigravity: gemini-pro / gemini-flash / gemini-flash-lite, $(_lane_cost_disclosure gm)"
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
# local (no cash or plan use) > Devin GLM/SWE (Devin plan) > keyless Gemini > Codex Sol/Terra (only if ChatGPT plan has
# headroom) > OpenRouter(only if funded). "All lanes tight" is handled first.
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
    *" devin=glm/swe "*)  lane="Devin GLM/SWE";   why="$(_lane_cost_disclosure dv), preserves your Claude quota" ;;
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
  # "installed", not "ready". This list is built from which CLIs are present and logged in, which is
  # not the same as which can currently serve a request: a lane stays installed and authenticated while
  # its subscription window is exhausted or its backend has stopped answering. Calling that "ready" is
  # how work gets routed somewhere that cannot take it. `doctor` issues real requests and reports which
  # of these actually respond.
  printf 'lanes installed: %s\n' "${lanes:-none detected (run doctor)}"
  printf '  (installed + logged in — not proof any of them will answer right now; `%s doctor` probes for real)\n' "$0"
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
  _mkdir_private "$OSRC_HOME" || true
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

# _task_difficulty <prompt> -> normal|hard. Several independent work signals indicate that selection
# should favor a near-frontier capable model instead of treating the request as a single operation.
_task_difficulty() {
  local prompt="$*" lc hits
  lc="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')"
  hits="$(printf '%s' "$lc" | grep -oE "$_TASK_KW_CODE|$_TASK_KW_REASONING|$_TASK_KW_AGENTIC" 2>/dev/null | wc -l | tr -d ' ')"
  hits="${hits:-0}"
  if [ "$hits" -ge 4 ] || [ "${#prompt}" -ge 240 ]; then printf 'hard'; else printf 'normal'; fi
}

# _frontier_needed <task> <effort> -> true when the request explicitly calls for the frontier.
_frontier_needed() {
  local task="$1" effort="$2" lc
  [ "$effort" = "max" ] && return 0
  lc="$(printf '%s' "$task" | tr '[:upper:]' '[:lower:]')"
  printf '%s' "$lc" | grep -qE 'frontier[- ]required|safety[- ]critical|mission[- ]critical|formal proof'
}

# _score <base> <tier> <category> <effort> <difficulty> <model> -> selection score.
# Capable models get a value preference, Kimi K3 gets a hard-work near-frontier adjustment, and an
# explicit frontier requirement outweighs both. Benchmark and history remain the base evidence.
_score() {
  local base="$1" tier="$2" category="$3" effort="$4" difficulty="$5" model="$6"
  awk -v s="$base" -v t="$tier" -v c="$category" -v e="$effort" -v d="$difficulty" -v m="$model" '
    BEGIN {
      if (t == "capable") s += 8
      if (t == "capable" && (e == "high" || e == "xhigh")) s += 2
      if (m == "kimi-k3" && d == "hard" && c != "creative") s += 20
      if (e == "max" && t == "frontier") s += 30
      printf "%.4f", s
    }'
}

# cmd_advise: task-aware model recommendation with benchmark data.
# Usage: advise [--refresh] [--json] [--effort LEVEL] "<task prompt>"
# Classifies the task, scores all known models, recommends the best value model
# that meets the capability threshold. Explains WHY it picked that model.
cmd_advise() {
  local do_refresh=0 json_out=0 task="" selection_effort="${OUTSOURCERER_EFFORT:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --refresh) do_refresh=1; shift ;;
      --json)    json_out=1; shift ;;
      --effort|--reasoning)
                 [ -n "${2:-}" ] || die "advise: --effort needs minimal|low|medium|high|xhigh|max|none"
                 case "$2" in minimal|low|medium|high|xhigh|max|none) selection_effort="$2" ;;
                   *) die "advise: invalid effort '$2' (use minimal|low|medium|high|xhigh|max|none)" ;; esac
                 shift 2 ;;
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
    elif [ "$json_out" -eq 1 ]; then
      # --json must emit ONLY JSON: suppress the refresh success line (stdout) too, not just stderr.
      refresh_benchmarks >/dev/null 2>&1 || true
    else
      refresh_benchmarks 2>/dev/null || true
    fi
  fi

  local category field threshold difficulty frontier_needed=0
  category="$(_classify_task "$task")"
  field="$(_bench_score_field "$category")"
  threshold="$(_bench_threshold_for "$category")"
  difficulty="$(_task_difficulty "$task")"
  if [ -z "$selection_effort" ]; then
    case "$difficulty" in hard) selection_effort=high ;; *) selection_effort=medium ;; esac
  fi
  _frontier_needed "$task" "$selection_effort" && frontier_needed=1

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
    # Fold local outcome history into the score BEFORE threshold/value-ratio, so a lane that keeps
    # failing THIS repo's checks drops out and a proven one rises. Zero history -> mult 1.00 (neutral).
    local _hm _mult; _hm="$(_history_mult "$lane" "$resolved" "$category")"; _mult="${_hm%%|*}"
    case "$_mult" in ''|*[!0-9.]*) _mult="1.00" ;; esac
    score="$(awk -v s="$score" -v m="$_mult" 'BEGIN{printf "%.4f", s*m}')"
    score="$(_score "$score" "$tier" "$category" "$selection_effort" "$difficulty" "$resolved")"
    # Subscription lanes (cx/cc/dv/gm): cost is plan-limited, not per-token.
    # Set price to 0 BEFORE value ratio so subscription models rank by capability, not OR price.
    case "$lane" in cx|cc|dv|gm) price_in="0"; price_out="0" ;; esac
    # Value ratio = score / max(cost_per_m_input, 0.01). Zero-priced catalog models use a 0.01 floor.
    cost_per_m="$(awk -v p="$price_in" 'BEGIN{printf "%.6f", p*1000000}')"
    value_ratio="$(awk -v s="$score" -v c="$cost_per_m" 'BEGIN{if(c<0.01)c=0.01; printf "%.2f", s/c}')"
    meets=0
    awk -v s="$score" -v t="$threshold" 'BEGIN{exit (s+0 >= t+0) ? 0 : 1}' && meets=1
    # Display label for subscription lanes.
    case "$lane" in cx|cc|dv|gm) cost_per_m="plan limits" ;; esac
    results="$results$alias|$resolved|$lane|$tier|$score|$cost_per_m|$value_ratio|$meets
"
  done < <(printf '%s\n' "$OSRC_MODEL_TABLE")

  # Pick recommendation in two cohorts to avoid subscription lanes dominating value ratio.
  # Subscription lanes (cx/cc/dv/gm): ranked by score (cost is plan-limited, not comparable to per-token).
  # Paid lanes (or/codex): ranked by value ratio (score / cost_per_m).
  # Prefer subscription if it meets threshold; else best paid by value ratio; else highest score overall.
  local rec_alias="" rec_resolved="" rec_lane="" rec_tier="" rec_reason=""
  local capable_best_alias="" capable_best_resolved="" capable_best_lane="" capable_best_tier="" capable_best_vr=-1
  local frontier_best_alias="" frontier_best_resolved="" frontier_best_lane="" frontier_best_tier="" frontier_best_score=-1
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
    if [ "$tier" = "capable" ]; then
      awk -v v="$vr" -v b="$capable_best_vr" 'BEGIN{exit (v+0 > b+0) ? 0 : 1}' && {
        capable_best_vr="$vr"; capable_best_alias="$alias"; capable_best_resolved="$resolved"
        capable_best_lane="$lane"; capable_best_tier="$tier"
      }
    fi
    if [ "$tier" = "frontier" ]; then
      awk -v s="$score" -v b="$frontier_best_score" 'BEGIN{exit (s+0 > b+0) ? 0 : 1}' && {
        frontier_best_score="$score"; frontier_best_alias="$alias"; frontier_best_resolved="$resolved"
        frontier_best_lane="$lane"; frontier_best_tier="$tier"
      }
    fi
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

  # Prefer capable-tier value unless the task explicitly needs the frontier.
  if [ "$frontier_needed" = "1" ] && [ -n "$frontier_best_alias" ]; then
    rec_alias="$frontier_best_alias"; rec_resolved="$frontier_best_resolved"; rec_lane="$frontier_best_lane"; rec_tier="$frontier_best_tier"
    rec_reason="frontier required (score $frontier_best_score, ${category} threshold $threshold, effort $selection_effort)"
  elif [ -n "$capable_best_alias" ]; then
    rec_alias="$capable_best_alias"; rec_resolved="$capable_best_resolved"; rec_lane="$capable_best_lane"; rec_tier="$capable_best_tier"
    rec_reason="best capable-tier value (ratio $capable_best_vr, meets ${category} threshold $threshold, effort $selection_effort)"
  elif [ -n "$sub_best_alias" ]; then
    rec_alias="$sub_best_alias"; rec_resolved="$sub_best_resolved"; rec_lane="$sub_best_lane"
    rec_reason="best subscription model (score $sub_best_score, meets ${category} threshold $threshold, plan-limited cost)"
  elif [ -n "$paid_best_alias" ]; then
    rec_alias="$paid_best_alias"; rec_resolved="$paid_best_resolved"; rec_lane="$paid_best_lane"
    rec_reason="best value (ratio $paid_best_vr, meets ${category} threshold $threshold)"
  else
    rec_alias="$any_best_alias"; rec_resolved="$any_best_resolved"; rec_lane="$any_best_lane"
    rec_reason="highest score (score $any_best_score, no model met ${category} threshold $threshold, consider escalating)"
  fi
  if [ -z "$rec_tier" ]; then
    local _rec_row; _rec_row="$(resolve_model_row "$rec_alias")"; rec_tier="${_rec_row##*|}"
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

  # Recompute the recommended model's history for the human/json explanation (raw + effective).
  local _rh rec_mult rec_neff rec_peff rec_scope _rhrest
  _rh="$(_history_mult "$rec_lane" "$rec_resolved" "$category")"
  rec_mult="${_rh%%|*}"; _rhrest="${_rh#*|}"; rec_neff="${_rhrest%%|*}"; _rhrest="${_rhrest#*|}"; rec_peff="${_rhrest%%|*}"; rec_scope="${_rh##*|}"
  case "$rec_mult" in ''|*[!0-9.]*) rec_mult="1.00" ;; esac
  local rec_pct; rec_pct="$(awk -v m="$rec_mult" 'BEGIN{printf "%+.0f", (m-1)*100}')"

  # Ranked fallback shortlist: the SAME preference order the recommendation uses, as an ordered list so
  # a caller can retry the next candidate when the top pick hits a transport failure (rate limit / 5xx /
  # timeout). Rank groups mirror the picker exactly: capable value leads normally, frontier leads when
  # required, and everything below threshold follows by score, so shortlist[0] IS
  # the recommendation. Ordering only: this ranks candidates, it never asserts any of them will succeed.
  local _sl="" _slg _slp
  while IFS='|' read -r alias resolved lane tier score cost vr meets; do
    [ -n "$alias" ] || continue
    if [ "$frontier_needed" = "1" ]; then
      case "$meets:$tier" in 1:frontier) _slg=0; _slp="$score" ;; 1:capable) _slg=1; _slp="$vr" ;; *) _slg=2; _slp="$score" ;; esac
    else
      case "$meets:$tier" in 1:capable) _slg=0; _slp="$vr" ;; 1:*) _slg=1; _slp="$score" ;; *) _slg=2; _slp="$score" ;; esac
    fi
    _sl="$_sl$_slg|$_slp|$alias|$resolved|$lane|$meets|$score|$vr
"
  done < <(printf '%s\n' "$results")
  # group asc, then the group-appropriate primary desc. -s (stable) so ties keep input (table) order,
  # matching the picker's first-wins on equal score/ratio — this is what makes shortlist[0] == the pick.
  local _sl_sorted; _sl_sorted="$(printf '%s' "$_sl" | grep -v '^$' | sort -s -t'|' -k1,1n -k2,2rn)"
  local shortlist_json="[]"
  if have jq; then
    shortlist_json="$(printf '%s\n' "$_sl_sorted" \
      | jq -R 'select(length>0)|split("|")|{alias:.[2],model:.[3],lane:.[4],meets:(.[5]=="1"),score:(.[6]|tonumber?),value_ratio:(.[7]|tonumber?)}' 2>/dev/null \
      | jq -s '.' 2>/dev/null)"
    [ -n "$shortlist_json" ] || shortlist_json="[]"
  fi

  if [ "$json_out" -eq 1 ]; then
    jq -n \
      --arg task "$task" --arg category "$category" --arg field "$field" --arg threshold "$threshold" \
      --arg rec_alias "$rec_alias" --arg rec_resolved "$rec_resolved" --arg rec_lane "$rec_lane" \
      --arg rec_tier "$rec_tier" --arg effort "$selection_effort" --arg difficulty "$difficulty" \
      --arg rec_reason "$rec_reason" --arg has_bench "$has_bench" --argjson bench_count "$bench_count" --argjson total_count "$total_count" \
      --arg hmult "$rec_mult" --arg hneff "$rec_neff" --arg hpeff "$rec_peff" --arg hscope "$rec_scope" \
      --argjson shortlist "$shortlist_json" \
      '{task:$task, category:$category, difficulty:$difficulty, effort:$effort, score_field:$field, threshold:$threshold,
        recommendation:{alias:$rec_alias, model:$rec_resolved, lane:$rec_lane, tier:$rec_tier, reason:$rec_reason},
        shortlist:$shortlist,
        benchmark_data_available:($has_bench=="1"),
        benchmark_coverage:((($bench_count|tostring) + "/" + ($total_count|tostring))),
        history:{multiplier:($hmult|tonumber? // 1.0), effective_samples:($hneff|tonumber? // 0),
                 passed_effective:($hpeff|tonumber? // 0), scope:$hscope}}'

  else
    echo "== outsourcerer advise =="
    echo "   task: $task"
    echo "   category: $category"
    echo "   difficulty: $difficulty"
    echo "   effort: $selection_effort"
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
    # Show the local-history adjustment when there is any (else stay silent — pure benchmark pick).
    if [ "$rec_scope" != "none" ] && awk -v n="$rec_neff" 'BEGIN{exit (n+0>0)?0:1}'; then
      echo "   local: ${rec_pct}% from ${rec_neff} effective runs (${rec_scope}: this ${category})"
    fi
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
    echo "Run with:  $0 run -m $rec_alias --effort $selection_effort \"$task\""
    echo "Override:  $0 run -m <any-model> --effort $selection_effort \"$task\"   (you know better, pick your own)"
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

# _perm_denials <log> -> count of REAL permission/sandbox denials in the log's tail.
#
# The naive version of this — grep the whole log for 'permission denied|EACCES|...' — counts the
# delegate READING ABOUT permissions as the delegate BEING DENIED permissions, and kills the job.
# That is not hypothetical: mutating runs have been aborted deep into real work where every match
# was source the delegate had read — `except PermissionError:` handlers and a regex literal listing
# "permission denied" as an error word — with zero actual denials. Any delegate working on
# error-handling code, a log parser, or this tool itself trips it.
#
# So a generic OS-level phrase only counts when the line ALSO looks like a failed tool call
# (`"is_error":true`), which is how a real denial comes back through stream-json — file CONTENT is
# carried on non-error results. Harness-specific rejection text is distinctive enough to count on its
# own. Tail-scan for the same reason the print-mode check uses one (a real wall is at the end; an
# incidental mention scrolls out of it).
#
# Tradeoff, stated rather than hidden: a delegate reading a file that happens to contain BOTH an
# is_error marker and a permission word on ONE line can still contribute a false count. That is much
# rarer than reading ordinary error-handling code, and it still needs OSRC_PERM_ABORT (3) of them
# inside the tail window to abort.
# Trigger phrases are ASSEMBLED from fragments so this file never contains them verbatim.
# This is not paranoia, it is the top false-positive source in practice: the most common reason a
# healthy run matches a "denial" pattern is that the delegate read THIS SCRIPT and echoed the
# detector's own pattern line back into its log. A watchdog whose source is its own trip-wire kills
# whoever works on it.
_printmode_needle() { printf 'chisel::repl::handler: Print mode: %s tool %s that requires confirmation' 'rejecting' 'exec'; }
_perm_needles() {
  printf '(%s|%s|%s)' \
    "requested permis""sions to" \
    "Tool execu""tion was rejected" \
    "Print mode: $(printf '%s tool %s' 'rejecting' 'exec')"
}

_perm_denials() {
  local log="$1"
  [ -f "$log" ] || { printf '0'; return 0; }
  local gen='([Oo]peration not permitted|[Rr]ead-only file system|EACCES|[Pp]ermission denied|sandbox (denied|blocked|error))'
  local err='"is_error"[[:space:]]*:[[:space:]]*true'
  local n
  n="$(tail -n "${OSRC_PERM_TAIL:-400}" "$log" 2>/dev/null \
        | grep -acE "$(_perm_needles)|($err.*$gen)" 2>/dev/null)" || n=0
  printf '%s' "${n:-0}"
}

# _devin_live_mtime <root-pid> -> newest mtime (epoch) of a devin CLI log belonging to a LIVE
# descendant of <root-pid>; prints nothing when there is no such log.
#
# Why this exists: devin's `-p` (print) mode writes NOTHING to stdout until the process exits —
# it is documented as "print response and exit", and there is no streaming output format to opt
# into. Verified against the real CLI through both a pipe and a PTY: the entire answer lands in a
# single burst at exit. So out.log byte-growth, which is the watchdog's primary liveness signal,
# cannot see this lane AT ALL. devin does however write its own CLI log continuously while it
# works, and the filename carries the pid, so that log is the signal we actually have.
#
# Match on pid rather than "newest log in the dir": concurrent fanout jobs each get their own devin
# process, and picking the newest file would let a busy sibling vouch for a genuinely hung job.
_devin_live_mtime() {
  local dlog_dir="${HOME}/.local/share/devin/cli/logs"
  [ -d "$dlog_dir" ] || return 1
  local newest=""
  local p f m
  # The supervised pid ITSELF, then its descendants. Normally devin is a grandchild (the lane
  # wrapper execs it), but a lane that execs devin directly would make the root pid the log owner,
  # and scanning only descendants would silently see nothing — a liveness check that quietly finds
  # nothing is indistinguishable from not having one.
  for p in "$1" $(_descendants "$1"); do
    for f in "$dlog_dir"/devin_*_"$p".log; do
      [ -f "$f" ] || continue
      # Symlink discipline, matching _devin_sandboxed_proxy_tls_hint: never stat through a
      # planted link.
      [ -L "$f" ] && continue
      m="$(_mtime "$f")"; [ -n "$m" ] || continue
      if [ -z "$newest" ] || [ "$m" -gt "$newest" ]; then newest="$m"; fi
    done
  done
  [ -n "$newest" ] || return 1
  printf '%s' "$newest"
}

# _job_made_writes <job-dir> <job-cwd> -> 0 if the delegate has produced any file write.
#
# Two independent signals, because neither alone covers the lanes we run. The log grep only sees
# STRUCTURED tool calls ('"name":"Write"'), which the claude/codex streams emit -- the Devin stream
# does not: Devin performs writes through `command_execution` running `/bin/bash -lc`, so a Devin
# delegate that writes a dozen files still shows ZERO matches. Grepping alone therefore made the
# exploring? guard impossible to satisfy on the Devin lane, and every mutating Devin job that ran
# past the no-write window was killed as write-free no matter how much it had actually written.
# So fall back to asking the filesystem, against the never-moved .startmark.
#
# Same known limitation as the stall-path FS check above: this cannot tell the delegate's writes
# from a concurrent writer's under the same cwd. That trade is deliberate here -- a false "it is
# working" costs one hard-timeout window, a false "it wrote nothing" kills a healthy job outright.
_job_made_writes() {
  local jd="$1" jcwd="${2:-}"
  grep -aq '"name":"\(Write\|Edit\|MultiEdit\)"' "$jd/out.log" 2>/dev/null && return 0
  [ "${OSRC_FS_PROGRESS:-1}" = "1" ] && [ -n "$jcwd" ] && [ -d "$jcwd" ] || return 1
  [ -f "$jd/.startmark" ] || return 1
  local hit
  hit="$(find "$jcwd" -maxdepth "${OSRC_FS_PROGRESS_DEPTH:-3}" \
           \( -name .git -o -name node_modules -o -name .venv -o -name target -o -name dist \) -prune -o \
           -type f -newer "$jd/.startmark" -print 2>/dev/null | head -1)"
  [ -n "$hit" ]
}

# _supervise <job-dir> <stall_warn> <stall_kill> <hard_timeout> -- <cmd...>
# Byte-growth watchdog + OSRC:: semantic layer + exit contract (0 done / 2 done? / 3 blocked /
# 124 timeout / 125 wedged / other = delegate rc).
_supervise() {
  local jd="$1" warn="$2" kill_after="$3" hard="$4"; shift 4
  [ "${1:-}" = "--" ] && shift
  # Job dir private, out.log restricted. The job dir usually already exists (the launcher claimed
  # it); _mkdir_private treats that as success and re-applies the mode either way. 600 out.log
  # because it can contain tool output. The chmod is best-effort for the same reason as the
  # directory mode: a filesystem without permission bits cannot be made to express one.
  _mkdir_private "$jd"
  : > "$jd/out.log"; chmod 600 "$jd/out.log" 2>/dev/null || true
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
  # byte-growth timer never trips. Track WRITES too. First expose "exploring?" so it can be steered;
  # if it then remains both write-free AND output-silent for another bounded window, stop it as a
  # real stall. An observable warning without a terminal bound left jobs running forever.
  # Prefer the verb passed by run_job via env (always in scope at the call site); fall back to
  # meta.json only if it wasn't. Reading it ONLY from meta.json silently disabled the whole
  # exploring? guard for every mutating verb on a host without jq (or on a failed meta write): no
  # jq -> empty verb -> mutating=0 -> guard off. The env carry makes the watchdog jq-independent.
  local verb="${OSRC_JOB_VERB:-}"
  [ -n "$verb" ] || { [ -f "$jd/meta.json" ] && verb="$(jq -r '.verb // ""' "$jd/meta.json" 2>/dev/null)"; }
  [ -f "$jd/meta.json" ] && _jcwd="$(jq -r '.cwd // ""' "$jd/meta.json" 2>/dev/null)"
  [ -n "$_jcwd" ] || _jcwd="$PWD"
  : > "$jd/.fsmark" 2>/dev/null || true
  # Immutable "job started here" marker. .fsmark is RE-stamped on every sign of life, so it can only
  # answer "wrote something recently"; the exploring? guard needs "wrote anything at all, ever",
  # which requires a marker that is never moved.
  : > "$jd/.startmark" 2>/dev/null || true
  local mutating=0; case "$verb" in edit|research|yolo) mutating=1 ;; esac
  local nww="${OSRC_NOWRITE_WARN:-180}"
  local nww_kill="${OSRC_NOWRITE_KILL:-$nww}"
  while kill -0 "$pid" 2>/dev/null; do
    # PID-reuse guard: verify the process is still ours.
    local _live_stime; _live_stime="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' || printf '')"
    if [ -n "$_live_stime" ] && [ "$_live_stime" != "$_stime" ]; then
      echo "[outsourcerer] WARN: PID $pid reused by another process, treating job as dead" >&2
      echo interrupted > "$jd/status"; echo 130 > "$jd/exit"; return 130
    fi
    sleep "${OSRC_POLL:-10}"
    # The delegate can FINISH during that sleep. The loop condition is only re-tested at the top, so
    # without this the body goes on to judge a process that has already exited — using an `idle`
    # measured against a delegate that is no longer there. A job that went quiet and then completed
    # gets killed post-mortem and reported `wedged` instead of `done`. Break and let the normal
    # `wait` + OSRC:: classification below decide what actually happened.
    kill -0 "$pid" 2>/dev/null || break
    now=$(date +%s)
    size=$(wc -c < "$jd/out.log" 2>/dev/null || echo 0)
    if [ "$size" -gt "$last_size" ]; then
      last_size=$size; last_change=$now
      grep -a -E 'OSRC::(PROGRESS|PLAN|BLOCKED|NEED_INPUT|DONE)' "$jd/out.log" 2>/dev/null | tail -1 > "$jd/progress"
      case "$(cat "$jd/status" 2>/dev/null)" in
        stalled?) echo running > "$jd/status" ;;
        # A WRITE clears exploring? for edit/yolo (their deliverable IS a file write, so a write-free
        # spiral must stay flagged). But `research` is a read/tool-exec verb whose deliverable is its
        # OUTPUT, not a file — so for research, fresh output (we are inside the size>last_size branch)
        # is real progress and clears the flag, exactly as a write would. Without this a healthy
        # write-free research job stayed stuck on exploring? and was primed for the kill arm below.
        exploring?) { [ "$verb" = "research" ] || _job_made_writes "$jd" "$_jcwd"; } && echo running > "$jd/status" ;;
      esac
    fi
    idle=$(( now - last_change )); age=$(( now - t0 ))
    if [ "$mutating" = "1" ] && [ "$age" -ge "$nww" ] && [ "$(cat "$jd/status" 2>/dev/null)" = "running" ]; then
      _job_made_writes "$jd" "$_jcwd" || {
        echo "exploring?" > "$jd/status"
        echo "[outsourcerer] WARN job $(basename "$jd"): ${age}s on a mutating verb ($verb) with ZERO file writes — likely exploring, not producing. It will be stopped after ${nww_kill}s with no writes and no output growth. Only an actual FILE WRITE clears this (progress output alone does not) — give it a tighter 'write file X now' target, or re-run read-only work under 'run'/'explore', which is not subject to this guard." >&2; }
    fi
    # Once marked exploring, a fresh output line buys the delegate another exploration window, but
    # neither reading nor an old warning can keep it alive forever. The same content check used for
    # the warning proves it has still made no write before applying the real stall-kill.
    if [ "$mutating" = "1" ] && [ "$(cat "$jd/status" 2>/dev/null)" = "exploring?" ] \
       && [ "$idle" -ge "$nww_kill" ] \
       && ! _job_made_writes "$jd" "$_jcwd"; then
      echo wedged > "$jd/status"
      printf 'exploring-timeout\n' > "$jd/reason" 2>/dev/null || true
      echo "[outsourcerer] job $(basename "$jd") stayed in exploring? for ${nww_kill}s with ZERO file writes and no output growth; stopped as stalled. Re-run with a tighter write target if more exploration is genuinely needed." >&2
      _kill_tree "$pid"; echo 125 > "$jd/exit"; return 125
    fi
    # SELF-HEAL backstop (LANE-AGNOSTIC): a mutating job hitting repeated permission/sandbox denials is
    # walled off — headless delegates (claude/codex/devin/local) cannot answer an interactive prompt, so it
    # will spiral forever. Kill it fast with a clear next-step instead. Prevention (mode escalation) handles
    # the known ~/.claude case; this catches any OTHER lane/path that hits the same wall. OSRC_PERM_ABORT=0 disables.
    if [ "$mutating" = "1" ] && [ "${OSRC_PERM_ABORT:-3}" -gt 0 ] && [ "$(cat "$jd/status" 2>/dev/null)" != "permission-blocked" ]; then
      local _pd; _pd="$(_perm_denials "$jd/out.log")"; _pd="${_pd:-0}"
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
    #   3. ASSEMBLE the needle at runtime (_printmode_needle) so this file does not contain it. Both
    #      anchors above miss the one source that matters most: this script itself. The literal used
    #      to sit right here, and a delegate that greps or reads outsourcerer.sh in its final actions
    #      would land it in the tail and abort ITSELF instantly — one occurrence, no threshold, at the
    #      end of a run that had already done all its work.
    # If devin's log format ever changes, the check simply no-ops and the 15-min byte-growth stall-kill
    # (still in place) reaps the hang instead — slower, but correct.
    if [ "${OSRC_NO_PRINTMODE_ABORT:-0}" != "1" ] && [ "$(cat "$jd/status" 2>/dev/null)" != "permission-blocked" ]; then
      if tail -n "${OSRC_PRINTMODE_TAIL:-25}" "$jd/out.log" 2>/dev/null \
           | grep -aq "$(_printmode_needle)"; then
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
    #
    # KNOWN LIMITATION (not solved): this check cannot distinguish the delegate's own writes from
    # any other writer's under the same directory. The orchestrator, a concurrent job, an editor
    # autosave, or any process with write access to the cwd can touch a file newer than .fsmark and
    # extend the stall window as if the delegate were working. A previous round attempted to gate
    # this on the delegate's cumulative CPU (`ps -o time=`) to reject foreign writes, but that was
    # withdrawn: it killed healthy delegates on hosts where `ps` is denied (sandbox/container),
    # failed open on exactly those hosts (restoring unlimited foreign-writer liveness), and a
    # coarse whole-second cumulative CPU reading still killed legitimate low-CPU I/O writers. The
    # hard timeout remains the backstop for a truly wedged run that foreign writes keep propping
    # up. A correct fix needs a bounded renewal budget (cap how many times a foreign write can
    # extend the window) plus an activity counter finer than whole-second cumulative CPU. Until
    # then, this check accepts any filesystem change as liveness -- the same behavior it had before
    # the CPU gate was introduced.
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
    # DEVIN-LANE LIVENESS. The check above asks the filesystem "did the delegate write anything?",
    # which answers nothing for READ-ONLY verbs: `explore`/`research` produce no files by design, so
    # the fallback never fires for exactly the jobs most likely to run long and quiet. Combined with
    # devin's non-streaming print mode (see _devin_live_mtime) that left the watchdog with no signal
    # whatsoever on this lane, and it was reaping healthy delegates on a timer — every wedged job in
    # the local history is a devin one, killed within poll slop of the stall window while its own log
    # showed it still reading files. Ask devin's log directly instead. OSRC_DEVIN_LIVENESS=0 disables.
    if [ "$idle" -ge "$warn" ] && [ "${OSRC_DEVIN_LIVENESS:-1}" = "1" ]; then
      local _dmt
      if _dmt="$(_devin_live_mtime "$pid")" && [ -n "$_dmt" ] && [ "$_dmt" -gt "$last_change" ]; then
        last_change="$_dmt"; idle=$(( now - last_change ))
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
  # A clean process exit is not a successful delegation when it emitted only launcher/disclosure
  # lines. Use the identical content test as the stall path: those lines begin with `>>> ` and do
  # not constitute a delegate result. This must run before marker/exit-code classification so an
  # empty rc=0 cannot masquerade as done? and an empty nonzero cannot hide its actual cause.
  if ! grep -aqv '^>>> ' "$jd/out.log" 2>/dev/null; then
    echo failed > "$jd/status"
    printf 'empty-output\n' > "$jd/reason" 2>/dev/null || true
    echo "[outsourcerer] job $(basename "$jd") exited without any delegate output beyond launcher/disclosure lines; marking it failed (empty-output). Do not treat this as a result." >&2
    [ "$rc" -eq 0 ] && rc=1
    echo "$rc" > "$jd/exit"
    return "$rc"
  fi
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
  # The rc file is written from an EXIT trap, NOT a follow-up statement: when $fn exits internally
  # (die is `exit`), a `"$fn"; echo $? > rcf` sequence never reaches the echo, the rc file stays
  # missing, and the default below reported 124 — indistinguishable from a real hard timeout. Any
  # caller that treats 124 as retryable infra would then RETRY an internal abort like "not logged
  # in" instead of surfacing it. The trap fires on plain return AND on internal exit; only a
  # hard-killed subshell (watchdog SIGKILL) writes nothing, so 124-by-default now means exactly
  # "killed", and the hard/teardown/interrupt arms below still override rc for their cases.
  # (TERM/INT are mapped to their conventional codes first: on a bare TERM the EXIT trap would
  # otherwise record $?=0 — a killed run must never read as success.)
  ( trap 'exit 143' TERM; trap 'exit 130' INT; trap 'echo $? > "$rcf"' EXIT; "$fn" </dev/null > "$fifo" ) & local prod=$!   # stdout->fifo (streamed+captured); stderr stays on terminal
  ( local t0 now mk=0; t0=$(date +%s)
    while kill -0 "$prod" 2>/dev/null; do
      sleep 2; now=$(date +%s)
      [ "$mk" = 0 ] && grep -qaE '^[[:space:]]*OSRC::(DONE|BLOCKED|NEED_INPUT)' "$cap" 2>/dev/null && mk=$now
      if [ "$mk" != 0 ] && [ $((now-mk)) -ge "$tdl" ]; then echo teardown > "$hit"; _kill_tree "$prod"; break; fi
      if [ $((now-t0)) -ge "$hard" ];               then echo hard     > "$hit"; _kill_tree "$prod"; break; fi
    done ) & local gd=$!
  # NB: the trap must NOT delete the marker files here. It records `interrupt` into $hit and kills the
  # tree, then control resumes after `wait` and the rc/hval read below turns that into rc=130. Removing
  # $base.* inside the trap erased BOTH the interrupt marker and the rc file, so the read defaulted to
  # rc=124 (== hard-timeout) and a caller that retries transport would auto-retry a user Ctrl-C. The
  # end-of-function cleanup already removes these files on every return path.
  trap 'echo interrupt > "'"$hit"'"; _kill_tree "'"$prod"'" 2>/dev/null; kill "'"$gd"'" "'"$tp"'" 2>/dev/null' INT TERM
  wait "$prod" 2>/dev/null
  kill "$gd" 2>/dev/null; wait "$gd" 2>/dev/null; wait "$tp" 2>/dev/null
  trap - INT TERM
  export OSRC_FG_GUARD_ACTIVE=0
  # Missing OR non-numeric/empty rc file -> 124 (killed). `cat || echo` alone is not enough: an
  # existing-but-empty file cats successfully and would return an empty rc.
  local rc hval lastmark; rc="$(cat "$rcf" 2>/dev/null)"; case "$rc" in ''|*[!0-9]*) rc=124 ;; esac
  hval="$(cat "$hit" 2>/dev/null || echo)"
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
  _mkdir_private "$OSRC_JOBS" || true
  local id jd tries=0
  # Claim the job dir ATOMICALLY -- `mkdir` (no -p) fails if the dir already exists, so two
  # concurrent launches that mint the same id can never share one directory; regenerate on collision.
  while :; do
    id="$(_new_job_id)"; jd="$OSRC_JOBS/$id"
    _mkdir_claim "$jd" && break
    tries=$((tries+1))
    [ "$tries" -ge 8 ] && { echo "bg: could not allocate a unique job dir under $OSRC_JOBS" >&2; return 1; }
  done
  chmod 700 "$jd" 2>/dev/null
  # Keep job history bounded even when nobody remembers to run `gc`.  This is
  # intentionally best-effort and capped: launch latency must never depend on
  # sweeping a large historical directory.  STDERR preserves this function's
  # stdout-only job-id contract for command substitutions.
  cmd_gc --auto >&2 || true
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
  OSRC_PROVIDER_EXPLICIT="${PROVIDER_EXPLICIT:-0}" nohup "$SCRIPT_PATH" __runjob "$id" "$PROVIDER" "$@" >/dev/null 2>&1 &
  _heartbeat_start >/dev/null 2>&1 || echo "outsourcerer: heartbeat auto-arm unavailable; supervision state is unknown" >&2
  printf '%s' "$id"
}

# Normalize OUTSOURCERER_DEPTH for the recursion guard. The guard compares the depth
# with `[ "$OUTSOURCERER_DEPTH" -ge "$max" ]`. If the depth is a non-integer string
# ('bogus', '1x', '-1', ' '), that `[` test errors with "integer expression expected",
# returns false (exit 2), and the guard FAILS OPEN -- the launch goes through, rc=0, a
# job is minted. A delegate controls its own environment, so poisoning the depth is the
# easiest way to escape the guard. The fix: normalize before comparing.
#   unset / empty        -> 0 (the normal top-level case)
#   well-formed non-neg  -> decimal value (a single leading '+' is stripped, POSIX-legal;
#                           leading zeros are stripped so later $((...)) arithmetic reads
#                           the value as base-10, NOT octal -- bash reads a leading-zero
#                           literal as octal, so 08/09 crash with 'value too great for
#                           base' and 010 silently becomes 9 instead of 10)
#   a lone '+'           -> unparseable (a sign with no digits after it is NOT an integer)
#   ANY other value      -> unparseable, the depth cannot be trusted -> caller REFUSES
# Returns 0 when OUTSOURCERER_DEPTH is now a usable non-negative integer (set in place),
# returns 1 when the value is unparseable (caller must refuse without launching).
_osrc_normalize_depth() {
  local _v="${OUTSOURCERER_DEPTH:-}"
  # A genuinely unset or empty ORIGINAL value is the top-level case. This check comes
  # BEFORE sign-stripping so a lone '+' (which strips to '') is NOT mistaken for top-level.
  [ -z "$_v" ] && { OUTSOURCERER_DEPTH=0; return 0; }
  # Strip a single leading '+' (POSIX-legal non-negative sign), but only when digits
  # follow it. '+*[!0-9]*' catches '+x', '+-1', etc.; the empty-after-strip case ('+'
  # alone) is refused by the empty check below.
  case "$_v" in
    +*[!0-9]*) return 1 ;;   # '+' followed by a non-digit -> unparseable
    +*)        _v="${_v#+}" ;; # single leading '+', digits follow (checked next)
  esac
  # A sign with no digits after it (e.g. bare '+') is NOT a valid integer.
  [ -z "$_v" ] && return 1
  # Now _v must be all decimal digits.
  case "$_v" in
    *[!0-9]*) return 1 ;;   # unparseable -> caller refuses
  esac
  # Strip leading zeros so every later $((OUTSOURCERER_DEPTH + 1)) reads the value as
  # base-10. Keep a single '0' for the zero case. Without this, route_delegate's
  # $((OUTSOURCERER_DEPTH + 1)) interprets a leading-zero literal as octal: 08/09 crash
  # ('value too great for base') and 010 silently becomes 9 instead of 11.
  while [ "${#_v}" -gt 1 ] && [ "${_v#[0]}" != "$_v" ]; do
    _v="${_v#0}"
  done
  OUTSOURCERER_DEPTH="$_v"
  return 0
}

# _osrc_normalize_max_depth -> echo the normalized base-10 OUTSOURCERER_MAX_DEPTH, or return 1
# (malformed). The depth guard normalizes OUTSOURCERER_DEPTH but used to compare it against the
# RAW maximum: `[ 1 -ge bogus ]` errors ("integer expression expected"), returns false, and the
# guard falls OPEN -- a delegate could escape the recursion limit merely by poisoning the maximum
# (OUTSOURCERER_MAX_DEPTH=bogus), since it controls its own environment. Fail CLOSED instead: an
# unparseable maximum refuses the launch, exactly as an unparseable depth does. Unset/empty keeps
# the default of 1. Same base-10 leading-zero handling as the depth normalizer so '010' is decimal.
_osrc_normalize_max_depth() {
  local _v="${OUTSOURCERER_MAX_DEPTH:-}"
  [ -z "$_v" ] && { printf '1'; return 0; }
  case "$_v" in
    +*[!0-9]*) return 1 ;;
    +*)        _v="${_v#+}" ;;
  esac
  [ -z "$_v" ] && return 1
  case "$_v" in *[!0-9]*) return 1 ;; esac
  while [ "${#_v}" -gt 1 ] && [ "${_v#[0]}" != "$_v" ]; do
    _v="${_v#0}"
  done
  printf '%s' "$_v"
  return 0
}

# bg [--provider X already parsed] [--worktree] <verb> [flags] "task" -> detach a supervised job, print id.
cmd_bg() {
  # flag-placement tolerance: global flags are legal between `bg` and the verb.
  while :; do case "${1:-}" in
    --worktree)  export OSRC_WORKTREE=1; shift ;;
    --cloud-ack) export OSRC_CLOUD_ACK=1; shift ;;
    --provider)  [ -n "${2:-}" ] || die "--provider requires a name (devin|cc|codex|droid|cursor|hermes|warp|gemini|gm|claudex|local)"; PROVIDER="$2"; PROVIDER_EXPLICIT=1; shift 2 ;;
    *) break ;;
  esac; done
  [ $# -gt 0 ] || die "bg needs a task (e.g. bg \"map this repo\" or bg run -m glm \"...\")"
  # PARENT-SIDE VALIDATION. Everything below must fail HERE, before _bg_launch mints a job dir and
  # prints an id. An invalid invocation is costly precisely because the caller receives an id and
  # believes work has started; the command only dies later inside the detached child, so the caller
  # moves on from work that never ran.
  #
  # An unexpanded shell variable is a CALLER bug, never a task: a wrong quoting pattern can emit a
  # whole run of these, each one a phantom job with an id.
  case "${1:-}" in
    '$'*) die "bg: refusing to launch — the first argument is the literal string '$1', which is an unexpanded shell variable, not a task or a verb. Nothing was started. Check the quoting in the command that produced this (a single-quoted \"\$var\" never expands)." ;;
  esac
  # -m before the verb is the single most common caller mistake after the above. It used to die with
  # "unknown subcommand '-m'". It is unambiguous, so accept it by hoisting it after the verb instead of
  # spending a whole round trip teaching the caller our argument order.
  if [ "${1:-}" = "-m" ] || [ "${1:-}" = "--model" ]; then
    [ -n "${2:-}" ] || die "bg: $1 needs a model name"
    local _hm="$1" _hv="$2"; shift 2
    if _is_verb "${1:-}"; then local _hverb="$1"; shift; set -- "$_hverb" "$_hm" "$_hv" "$@"
    else set -- run "$_hm" "$_hv" "$@"; fi
  fi
  # INTUITIVE DEFAULT (papercut fix): if no verb is given, assume `run`. `bg "task"`, `bg -m glm "task"`,
  # and `bg run "task"` all work now. Only a bare word that isn't a verb and isn't a flag triggers it.
  if ! _is_verb "${1:-}"; then
    case "${1:-}" in
      -*) set -- run "$@" ;;                          # starts with a flag -> insert default verb `run`
      *)  set -- run "$@" ;;                          # a task string     -> insert default verb `run`
    esac
    printf '>>> [bg] no verb given; defaulting to `run` (read-only). Use edit/yolo for mutating work.\n' >&2
  fi
  # Last parent-side gate: there must be a real task. A flags-only invocation used to mint a job whose
  # detached child then died on a usage error, which is the phantom-job pattern this block exists to
  # stop. Skip the verb, skip flag/value pairs, and require something left over.
  local _sawtask=0 _skipnext=0 _first=1 _a
  for _a in "$@"; do
    [ "$_first" = "1" ] && { _first=0; continue; }          # position 1 is the verb
    [ "$_skipnext" = "1" ] && { _skipnext=0; continue; }    # this token is a flag's VALUE
    case "$_a" in
      -m|--model|--effort|--with|--provider) _skipnext=1 ;;
      -*) ;;                                                 # a bare flag, keep looking
      *) _sawtask=1; break ;;
    esac
  done
  [ "$_sawtask" = "1" ] || die "bg: refusing to launch -- no task text was given, only flags. Nothing was started. Add the task, e.g. bg run -m glm \"map the auth flow\"."
  # AUTHORIZATION (separate from the preflight VALIDATION below). The parent must refuse to
  # launch when the caller's inherited depth is already at the max. The preflight resets
  # OUTSOURCERER_DEPTH=0 so it can evaluate the dispatch gate without short-circuiting at the
  # recursion guard -- that is correct for VALIDATION (is the lane wired, is the model valid),
  # but it is NOT authorization. Without this check, an already-delegated agent (depth >= max)
  # mints a bg job whose detached child inherits the depth, re-enters route_delegate, and the
  # guard trips inside the child -- but a job dir was already minted and an id printed, so the
  # caller believes work started. Worse, the detached child no longer resets depth (see run_job),
  # so the guard DOES trip there; but the parent-side check fails FIRST, before any job dir is
  # claimed, so the refusal is clean and no phantom job is left behind. Validation and
  # authorization are not the same decision: the preflight answers "can this route dispatch?",
  # this check answers "is this caller allowed to delegate at all?".
  # Normalize the depth BEFORE comparing (see _osrc_normalize_depth). The old `: "${...:=0}"`
  # only filled unset/empty; a malformed value ('bogus', '1x', '-1', ' ') slipped through and
  # `[ "$bad" -ge 1 ]` errored with "integer expression expected", returning false -> fail-open.
  local _depth_raw="${OUTSOURCERER_DEPTH:-}"
  if ! _osrc_normalize_depth; then
    die "bg: refusing to launch -- OUTSOURCERER_DEPTH is unparseable ('$_depth_raw'). An unparseable depth cannot be trusted (a delegate controls its own environment), so the guard refuses rather than fail-open. Set OUTSOURCERER_DEPTH to a non-negative integer or unset it. Nothing was started."
  fi
  local _max_raw="${OUTSOURCERER_MAX_DEPTH:-}" _max
  if ! _max="$(_osrc_normalize_max_depth)"; then
    die "bg: refusing to launch -- OUTSOURCERER_MAX_DEPTH is unparseable ('$_max_raw'). A malformed maximum must not let a delegate slip past the recursion guard (a raw comparison would error and fall open), so the guard refuses. Set OUTSOURCERER_MAX_DEPTH to a non-negative integer or unset it. Nothing was started."
  fi
  if [ "$OUTSOURCERER_DEPTH" -ge "$_max" ]; then
    die "bg: refusing to launch -- recursion limit reached (OUTSOURCERER_DEPTH=$OUTSOURCERER_DEPTH >= OUTSOURCERER_MAX_DEPTH=$_max). A delegate must not re-delegate. Override with OUTSOURCERER_MAX_DEPTH=N. Nothing was started."
  fi
  # Route preflight: ask the real routing code whether this is even dispatchable, before minting a job.
  # An unroutable combination (a ChatGPT-only model forced through OpenRouter, an image model used as a
  # text lane) otherwise produced a job id, a "launched" line, and a failure only the job record ever
  # saw. Output is discarded on success so the disclosure banner is not printed twice.
  local _pfout _pfrc=0
  # --provider must be passed EXPLICITLY: cmd_bg already consumed the flag into a shell variable that a
  # child process does not inherit, so without this the preflight would silently check the DEFAULT lane
  # and bless a combination the real run rejects.
  # OUTSOURCERER_DEPTH=0: the preflight must evaluate the DISPATCH gate (is the lane wired, is the
  # model valid), NOT the recursion guard. Under nested delegation the parent's OUTSOURCERER_DEPTH is
  # already exported, and a child that inherits it exits at the recursion guard before ever reaching
  # the dispatch-gate checks -- so cmd_bg would see an unrecognized error and (under the old fail-open
  # logic) launch anyway, minting a phantom job. Resetting depth here lets the preflight reach the
  # real dispatch checks. The recursion guard is enforced SEPARATELY: the parent-side authorization
  # check above refuses before any job is minted, and the detached __runjob child inherits the
  # caller's depth (it no longer resets it) so route_delegate's guard trips there too as a backstop.
  local -a _pf_provider=()
  [ "${PROVIDER_EXPLICIT:-0}" = "1" ] && _pf_provider=(--provider "$PROVIDER")
  _pfout="$(OSRC_PREFLIGHT=1 OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 "$SCRIPT_PATH" ${_pf_provider[@]+"${_pf_provider[@]}"} "$@" 2>&1)" || _pfrc=$?
  # Fail CLOSED: a preflight whose result we cannot interpret must refuse to launch, never launch
  # anyway. The old code fail-opened on any error string it did not recognize (e.g. "recursion guard"
  # under nested delegation), which minted a phantom job for a lane that could not dispatch. The
  # preflight only exits non-zero via a `die` in the lane-resolution body (every gate is a die), so a
  # non-zero rc is always a real dispatch failure. The real run still enforces every gate as a
  # backstop, but the preflight's job is to fail BEFORE a job dir is minted.
  if [ "$_pfrc" -ne 0 ]; then
    printf '%s\n' "$_pfout" | grep -a 'ERROR:' | head -3 >&2
    die "bg: refusing to launch -- the route preflight returned non-zero (rc=$_pfrc). Nothing was started. See above for the dispatch error."
  fi
  _bg_cloud_preack "$@"   # ack in the PARENT so a refusal `die`s the whole command (not just a subshell)
  local id; id="$(_bg_launch "$@")"
  [ -n "$id" ] || die "bg: launch failed -- no job id was minted (nothing was started)."
  echo "$id"
  # PROVIDER is only the DEFAULT lane. A model alias routes per-model (`-m terra` goes to codex-native
  # even while the default provider is devin), and that decision is made in the detached child, after
  # this line prints. Stating "provider=devin" for a job that ran on codex-native is the tool lying
  # about its own routing, so name it as a default and point at the record that is actually true.
  echo "[outsourcerer] job $id launched (default lane: $PROVIDER; a model alias can route it elsewhere, and '$0 status $id' shows the model it really ran)." >&2
  echo "[outsourcerer] NOW WATCH IT: $0 watch $id     (it runs unobserved until you do; status/result: $0 status $id | $0 result $id)" >&2
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
  printf '>>>   NOW WATCH IT: %s watch %s   (unobserved until you do; status: %s status %s | result: %s result %s)\n' "$0" "$id" "$0" "$id" "$0" "$id" >&2
  echo "$id"
  return 0
}

# _resolve_run_cost <lane> <launch_epoch> <out.log> -> cost string for the ledger.
# Priority: OpenRouter per-gen cost (authoritative) > Hermes receipt from state.db > lane default.
# For the Hermes lane, when no receipt is available the labeled ESTIMATE ("~0") is used -- never a
# measured "0.000000". A fabricated measured cost is worse than no cost feature: it suppresses the
# honest "unmeasured" signal and understates real spend. Extracted from run_job so the hermes cost
# path is unit-testable without launching a full background job.
_resolve_run_cost() {
  local lane="$1" launch="$2" log="$3"
  local real_cost; real_cost="$(_or_run_cost "$log" 2>/dev/null)"
  if [ -z "$real_cost" ]; then
    if grep -qE 'gen-[0-9]+-[a-zA-Z0-9]+' "$log" 2>/dev/null; then
      # per-gen cost is authoritative and per-job; the account-usage delta double-counts under concurrent
      # fanout (overlapping before/after windows), so drop it -> use the clearly-labeled '~' estimate.
      local est; est="$(jq -r 'select(.type=="result")|.total_cost_usd // empty' "$log" 2>/dev/null | tail -1)"
      [ -n "$est" ] && real_cost="~$est"
    elif [ "$lane" = "hermes" ]; then
      # Hermes real cost from ~/.hermes/state.db, keyed on cwd + launch epoch. When the receipt is
      # unavailable (DB absent, locked, schema-drifted, no matching row, or ambiguous), the labeled
      # ESTIMATE is used -- never a measured 0. The '~' prefix marks it as an estimate so the Tab
      # never confuses it with a real receipt.
      local hcost; hcost="$(_hermes_run_cost "$launch" 2>/dev/null)"
      if [ -n "$hcost" ]; then
        real_cost="$hcost"
      else
        real_cost="~0"
      fi
    else
      # No OpenRouter generation id in the stream. For a NATIVE/keyless/local/plan lane that genuinely
      # means no cash ($0). But for a CASH OpenRouter lane (or) it means we COULD NOT MEASURE this run
      # (the Responses stream never surfaced a gen- id and the /generation lookup was empty) -- recording
      # $0 there would UNDERSTATE real spend (cash-lane under-report guard). Leave it unmeasured so the
      # Tab counts it under "cash lanes, est-only" (honest) instead of "$0 measured" (false).
      case "$lane" in
        or|gemini|gm|gmnative|droid|warp) real_cost="" ;; # API/BYOK-capable vehicle: no receipt is not measured zero
        *)  real_cost="0.000000" ;;         # local or verified subscription vehicle
      esac
    fi
  fi
  printf '%s' "$real_cost"
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
  # An explicit pinned base (set by crew) makes ALL workers branch from the SAME commit, avoiding the
  # base-SHA race where each job would otherwise snapshot repo HEAD at its own launch instant.
  # Unset/invalid -> HEAD (unchanged legacy behavior).
  if [ -n "${OSRC_WORKTREE_BASE:-}" ] && git -C "$root" rev-parse --verify "${OSRC_WORKTREE_BASE}^{commit}" >/dev/null 2>&1; then
    base="$(git -C "$root" rev-parse "${OSRC_WORKTREE_BASE}^{commit}")"
  fi
  if ! git -C "$root" worktree add -q -b "$br" "$wt" "$base" 2>/dev/null; then
    echo "[outsourcerer] --worktree setup failed for $id (branch exists / detached?); running in the normal checkout." >&2
    return 1
  fi
  printf '%s\t%s\t%s' "$wt" "$br" "$base"
}

# __runjob <id> <provider> <verb> [flags] "task"  (internal; run detached by cmd_bg)
run_job() {
  local id="$1" prov="$2"; shift 2
  # The job id IS this delegation's durable run_id; the outcome row will join on it.
  export OSRC_RUN_ID="$id"
  # This detached job process creates last.txt/out.log (incl. the Codex --output-last-message
  # path that writes last.txt DURING _supervise). Set a private umask up front so NONE of them are ever
  # briefly world-readable. No restore needed -- this is a dedicated short-lived process that exits after.
  umask 077
  local jd="$OSRC_JOBS/$id"; _mkdir_private "$jd"
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
  # Classify from the REAL task text (REST), not the "job:<id>" placeholder record_ledger sees.
  export OSRC_TASK_CLASS="$(_classify_task "${REST[*]:-}")"
  local row id2 ttier="" tier lane=""
  row="$(resolve_model_row "$MODEL")"; id2="$MODEL"
  # row is "resolved-id|lane|tier" (see resolve_model_row). Capture the LANE (middle field) too --
  # meta previously recorded only provider (the ORIGINAL provider, e.g. devin), which mislabels a
  # plan lane (gm/cx/cc) as a cash lane in the Tab. Persist the resolved lane so accounting is truthful.
  [ -n "$row" ] && { id2="${row%%|*}"; ttier="${row##*|}"; lane="$(printf '%s' "$row" | awk -F'|' '{print $2}')"; }
  # Engine lanes (droid/cursor) own their model catalog: -m passes through verbatim, and with no -m
  # the ENGINE's configured default runs -- never our alias table's, so don't record it as such.
  case "$prov" in
    droid|cursor|hermes|warp) lane="$prov"; [ "$MODEL_EXPLICIT" = "1" ] || id2="($prov default)" ;;
    claudex)      lane="claudex"; [ "$MODEL_EXPLICIT" = "1" ] || id2="gpt-5.6-sol" ;;
  esac
  lane="$(_effective_lane "$lane" "$prov" "$MODEL" "$MODEL_EXPLICIT")"
  tier="$(resolve_tier "$id2" "$ttier")"
  local wins warn kill hard; wins="$(_tier_windows "$tier")"; warn="${wins%% *}"; hard="${wins##* }"; kill="$(echo "$wins" | awk '{print $2}')"
  # LANE-AWARE STALL FLOOR (devin). devin's `-p` print mode is non-streaming: on a single long model
  # completion it writes NOTHING to stdout AND nothing to its own CLI log while parked on the model API.
  # A reasoning model generating a large answer has been observed silent for ~1450s on hard tasks --
  # longer than the tier stall window -- so both liveness signals (out.log byte-growth AND the CLI-log
  # mtime) freeze together and the watchdog reaps a job that is genuinely mid-inference. No finer signal
  # exists during that wait (no streaming to opt into, silent log, and a live-but-waiting process is
  # indistinguishable from a hung one), so the only correct fix is a window wide enough to outlast a
  # legitimate completion; the HARD cap stays the real backstop for a truly wedged run. The floor never
  # LOWERS a window a slower tier already set. Override: OSRC_DEVIN_STALL_KILL (0 disables the floor).
  if [ "$prov" = "devin" ] || [ "$lane" = "dv" ]; then
    local _dsk="${OSRC_DEVIN_STALL_KILL:-1800}"
    case "$_dsk" in ''|*[!0-9]*) _dsk=1800 ;; esac
    [ "$_dsk" -gt 0 ] && [ "$kill" -lt "$_dsk" ] 2>/dev/null && kill="$_dsk"
    [ "$hard" -lt "$kill" ] 2>/dev/null && hard="$kill"   # hard cap must never sit below the stall floor
  fi
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
  # OUTSOURCERER_DEPTH is NOT reset here: the detached child inherits the caller's depth so
  # route_delegate's recursion guard sees it and bounds the delegation chain. Resetting it to 0
  # (the previous behavior) let an already-delegated agent mint a bg job whose child restarted at
  # depth 0, defeating the guard entirely and allowing unbounded re-delegation. The parent-side
  # authorization check in cmd_bg refuses before minting when depth >= max; this guard is the
  # backstop inside the child.
  local -a _run_provider=()
  [ "${PROVIDER_EXPLICIT:-0}" = "1" ] && _run_provider=(--provider "$prov")
  OSRC_STREAM=1 OSRC_JOB_DIR="$jd" OUTSOURCERER_PROVIDER="$prov" OSRC_PROVIDER_EXPLICIT="${PROVIDER_EXPLICIT:-0}" OSRC_JOB_VERB="$verb" \
    _supervise "$jd" "$warn" "$kill" "$hard" -- \
    "$SCRIPT_PATH" ${_run_provider[@]+"${_run_provider[@]}"} "$verb" "$@"
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
  # REAL cash, resolved by _resolve_run_cost (see its doc comment for the priority order and the
  # Hermes receipt/estimate contract). Extracted so the hermes cost path is unit-testable.
  local real_cost; real_cost="$(_resolve_run_cost "$lane" "$_started" "$jd/out.log")"
  # Always record the run (even unmeasured): an empty cost is meaningful (cmd_tab counts it as
  # est-only), and the old `[ -n "$real_cost" ]` guard would DROP an unmeasured cash run entirely,
  # hiding a real offload from the Tab. record_ledger tolerates an empty cost arg.
  OSRC_LEDGER_FORCE=1 record_ledger "$prov" "$id2" "$tier" "$verb" "job:$id" "$real_cost" "$lane"
  # Record the delegation OUTCOME, correlated by run_id (= job id), for advise learning.
  # Infra/permission/provider failures map to blocked/abandoned so they NEVER teach model quality
  # (only passed/failed/reverted feed the fold). A checkless success is completed_unverified (excluded);
  # true check-backed passed/failed comes from the free gate / loop judges, not from a bare run.
  local _st _m _oc _rsn
  _st="$(_reconcile_status "$id" 2>/dev/null || cat "$jd/status" 2>/dev/null || echo '?')"
  _m="$(_status_to_outcome "$_st" "$sc")"; _oc="${_m%%$'\t'*}"; _rsn="${_m#*$'\t'}"
  # Preserve the supervised empty-result diagnosis in the durable outcome record. Without this,
  # `failed` was recorded only as generic provider_error and the actual empty-output failure
  # vanished as soon as the transient supervisor message scrolled away.
  [ "$(cat "$jd/reason" 2>/dev/null || true)" = "empty-output" ] && _rsn="empty-output"
  # Pass EVERY field explicitly — no reliance on exported env (which record_ledger no longer sets).
  record_outcome "$_oc" "$_rsn" "" "$id" "$lane" "$id2" "${OSRC_TASK_CLASS:-}" "$(_repo_key)"
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
      if [ "$_alive" = "0" ]; then
        [ "${OSRC_RECONCILE_READ_ONLY:-0}" = "1" ] || echo interrupted > "$jd/status" 2>/dev/null
        st="interrupted"
      fi
      ;;
    launching)
      # A launcher that detached and never produced a worker leaves `launching` on disk forever. The
      # text status path converted that to a failure, but every OTHER reader (the JSON control plane,
      # the fanout waiter) called this function and got back "launching" — so a stillborn job counted
      # as live work and a fanout could wait on it indefinitely. Reconciliation has to live here, with
      # the single owner, or each new reader silently reintroduces the phantom.
      local _sa _grace _now2; _now2=$(date +%s)
      _sa="$(cat "$jd/started_at" 2>/dev/null)"; case "$_sa" in ''|*[!0-9]*) _sa=$_now2 ;; esac
      _grace="${OSRC_LAUNCH_GRACE:-45}"; [ -f "$jd/setup" ] && _grace="${OSRC_SETUP_GRACE:-900}"
      if [ ! -s "$jd/out.log" ] && [ ! -f "$jd/pid" ] && [ $(( _now2 - _sa )) -ge "$_grace" ]; then
        [ "${OSRC_RECONCILE_READ_ONLY:-0}" = "1" ] || echo failed > "$jd/status" 2>/dev/null
        st="failed"
        # The REASON travels with the state change. Writing the status here and the explanation
        # somewhere else means whichever reader gets there first leaves the other empty.
        if [ "${OSRC_RECONCILE_READ_ONLY:-0}" != "1" ] && [ ! -s "$jd/error" ]; then
          local _ph; _ph="$(cat "$jd/setup" 2>/dev/null)"
          if [ -n "$_ph" ]; then
            printf 'stillborn: the job never got past its %s setup phase (no process or output within %ss). Setup itself is stuck — check for a hung git operation or a lock left behind by an interrupted run.\n' "$_ph" "$_grace" > "$jd/error" 2>/dev/null || true
          else
            printf 'stillborn: the launcher detached but the worker never started (no process or output within %ss). The environment likely killed the background process — e.g. a sandbox that reaps detached jobs. Re-run in the foreground (--wait) or a shell that allows background processes.\n' "$_grace" > "$jd/error" 2>/dev/null || true
          fi
        fi
      fi
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
  _mark_watched "${1:-}"
  local id="${1:-}"
  # A bare status used to call _status_line for every historical job.  Each line
  # reconciles state and may inspect logs/PIDs, so a large jobs directory turns a
  # harmless diagnostic command into a CPU-bound process.  Keep the control-plane
  # view deliberately small and recent; targeted status remains unrestricted.
  local max="${OSRC_STATUS_MAX:-40}" deadline="${OSRC_STATUS_DEADLINE:-15}"
  case "$max" in ''|*[!0-9]*|0) max=40 ;; esac
  case "$deadline" in ''|*[!0-9]*|0) deadline=15 ;; esac
  # `status --json [id]` / `status [id] --json` -> machine-readable control plane for orchestrators.
  if [ "$id" = "--json" ] || [ "${2:-}" = "--json" ]; then
    [ "$id" = "--json" ] && id="${2:-}"
    have jq || die "status --json needs jq"
    if [ -n "$id" ] && [ "$id" != "--json" ]; then _job_json "$id"; echo; return; fi
    [ -d "$OSRC_JOBS" ] || { printf '{"schema_version":"1","jobs":[]}\n'; return 0; }
    { printf '{"schema_version":"1","jobs":['; local first=1 d out t0 now shown=0 total
      t0=$(date +%s); total=$(find "$OSRC_JOBS" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | wc -l | tr -d ' ')
      while IFS= read -r d; do
        [ -d "$d" ] || continue
        now=$(date +%s); [ $(( now - t0 )) -lt "$deadline" ] || break
        out="$(_job_json "$(basename "$d")")" && [ -n "$out" ] || continue
        [ $first -eq 1 ] || printf ','; first=0; printf '%s' "$out"; shown=$((shown+1))
      done < <(ls -1td "$OSRC_JOBS"/*/ 2>/dev/null | head -n "$max")
      printf '],"omitted":%s}\n' "$(( total > shown ? total - shown : 0 ))"; }
    return
  fi
  if [ -n "$id" ]; then _status_line "$id"; return; fi
  [ -d "$OSRC_JOBS" ] || { echo "no jobs yet."; return 0; }
  printf '%-22s %-8s %-6s %-16s %-12s %s\n' JOB STATE AGE MODEL ACTS "LAST"
  local d t0 now shown=0 total
  t0=$(date +%s)
  total=$(find "$OSRC_JOBS" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | wc -l | tr -d ' ')
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    now=$(date +%s)
    if [ $(( now - t0 )) -ge "$deadline" ]; then
      printf '[outsourcerer] status deadline (%ss) reached after %s jobs; stopping.\n' "$deadline" "$shown" >&2
      break
    fi
    _status_line "$(basename "$d")"
    shown=$((shown+1))
  done < <(ls -1td "$OSRC_JOBS"/*/ 2>/dev/null | head -n "$max")
  if [ "$total" -gt "$shown" ]; then
    printf '[outsourcerer] omitted %s older jobs (OSRC_STATUS_MAX=%s); use status <id> for a specific job.\n' \
      "$(( total - shown ))" "$max"
  fi
}

# _watch_digest <id> <interval-secs> <next-label> -> emit a periodic status digest to stdout.
# No new state file, no background process: reads the same status/progress/started_at the watch
# loop already reads. Gives a watched job a heartbeat into the running session even when nothing
# has changed, so a long silent-but-healthy run does not look like a hang.
_watch_digest() {
  local id="$1" interval="$2" next="$3" st="$4"
  local jd="$OSRC_JOBS/$id"
  local prog started now elapsed
  prog="$(tail -1 "$jd/progress" 2>/dev/null)"
  case "$prog" in
    *OSRC::*) prog="OSRC::$(printf '%s' "${prog##*OSRC::}" | tr -d '"\\')" ;;
    *) prog="(none yet)" ;;
  esac
  started="$(cat "$jd/started_at" 2>/dev/null)"
  case "$started" in ''|*[!0-9]*) started="" ;; esac
  now=$(date +%s)
  if [ -n "$started" ]; then elapsed="$(( now - started ))s"; else elapsed="?"; fi
  printf 'OSRC::PROGRESS watch %s periodic digest\n- state: %s\n- last: %s\n- elapsed: %s\n- next: %s\n' \
    "$id" "$st" "$prog" "$elapsed" "$next"
}

cmd_watch() {
  _mark_watched "${1:-}"
  local id="${1:-}"; [ -n "$id" ] || die "watch needs a job id"
  local jd="$OSRC_JOBS/$id"; [ -d "$jd" ] || die "no such job: $id"
  local forsec=0; [ "${2:-}" = "--for" ] && forsec="${3:-60}"
  local t0; t0=$(date +%s); local last="" lastprog=""
  local deadline="${OSRC_STATUS_DEADLINE:-15}"
  case "$deadline" in ''|*[!0-9]*|0) deadline=15 ;; esac
  # Periodic digest cadence: even with no state change, report into the running session so a long
  # silent-but-healthy run does not look like a hang. OSRC_WATCH_DIGEST_SECS tunes it (default 420s).
  local digest_secs="${OSRC_WATCH_DIGEST_SECS:-420}"
  # Validate: a non-numeric value would error under set -u arithmetic; 0/negative would emit every
  # poll (spam). Require a positive integer, else fall back to the default. (Sol review, MEDIUM.)
  case "$digest_secs" in ''|*[!0-9]*|0) digest_secs=420 ;; esac
  [ "$digest_secs" -eq 0 ] 2>/dev/null && digest_secs=420
  local last_digest; last_digest=$t0
  while :; do
    local elapsed; elapsed=$(( $(date +%s) - t0 ))
    if [ "$elapsed" -ge "$deadline" ]; then
      printf '[outsourcerer] watch deadline (%ss) reached for %s; stopping.\n' "$deadline" "$id" >&2
      break
    fi
    local st; st="$(cat "$jd/status" 2>/dev/null || echo '?')"
    # HEARTBEAT: print on a status change OR when a NEW OSRC::PROGRESS marker lands.
    # Before this, watch was silent for the entire multi-minute 'running' phase even while the delegate
    # emitted progress — the native equivalent of "going dark" the whole time work is happening.
    local prog; prog="$(tail -1 "$jd/progress" 2>/dev/null)"
    if [ "$st" != "$last" ] || { [ -n "$prog" ] && [ "$prog" != "$lastprog" ]; }; then
      _status_line "$id"; last="$st"; lastprog="$prog"
    fi
    # Terminal state FIRST: emit the final digest and break before a periodic tick could double it,
    # and before --for could exit without it. (Sol review, both LOWs collapse to this ordering.)
    case "$st" in done|done?|failed|blocked|timeout|wedged|canceled|permission-blocked|interrupted)
      _watch_digest "$id" "$digest_secs" "fetch result" "$st"
      break ;; esac
    # Periodic digest: emit on the interval so the session sees the job is still alive even when
    # status and progress are unchanged. Only reached while non-terminal, so it never doubles.
    local _now; _now=$(date +%s)
    if [ $(( _now - last_digest )) -ge "$digest_secs" ]; then
      _watch_digest "$id" "$digest_secs" "continuing watch; next digest in ${digest_secs}s" "$st"
      last_digest=$_now
    fi
    [ "$forsec" -gt 0 ] && [ "$elapsed" -ge "$forsec" ] && break
    # A caller can configure a very large poll interval; never let that make
    # the deadline advisory.  Wake no later than the remaining wall-clock time.
    local poll="${OSRC_POLL:-10}" remain
    case "$poll" in ''|*[!0-9]*|0) poll=10 ;; esac
    remain=$(( deadline - elapsed ))
    [ "$poll" -gt "$remain" ] && poll=$remain
    sleep "$poll"
  done
}

cmd_result() {
  _mark_watched "${1:-}"
  local id="${1:-}"; [ -n "$id" ] || die "result needs a job id"
  local jd="$OSRC_JOBS/$id"; [ -d "$jd" ] || die "no such job: $id"
  local shown rc=0
  # Capture once and printf once (not cat+cat / tail+tail): a double read is a TOCTOU on a growing
  # out.log and wastes IO. rc reflects the capture's status so a vanished file still surfaces nonzero.
  if [ -s "$jd/last.txt" ]; then shown="$(cat "$jd/last.txt")" || rc=$?
  else shown="$(tail -n 40 "$jd/out.log" 2>/dev/null)" || rc=$?; fi
  printf '%s' "$shown"
  # An empty-output failure intentionally has no delegate payload to print. Surface its recorded
  # reason here rather than making `result` look like a successful empty response.
  if [ "$(cat "$jd/reason" 2>/dev/null || true)" = "empty-output" ]; then
    printf '\n>>> [outsourcerer] FAILED: empty-output — the delegate exited without output beyond launcher/disclosure lines; there is no result to trust.\n' >&2
    [ "$rc" -eq 0 ] && rc=1
  fi
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
  # "no log" has three very different causes and the status file, sitting right next to the missing
  # log, distinguishes them. Reporting them identically sends someone hunting for a broken job when the
  # answer is "wait two seconds", or hunting for a typo when the job id is genuinely wrong.
  local shown rc=0
  if [ ! -f "$OSRC_JOBS/$id/out.log" ]; then
    [ -d "$OSRC_JOBS/$id" ] || die "no such job: $id (check the id, or run '$0 status' to list jobs)"
    local _st; _st="$(_reconcile_status "$id" 2>/dev/null || printf '?')"
    case "$_st" in
      launching) die "job $id is still starting up — the delegate has not written any output yet. Give it a moment and retry, or watch it live: $0 watch $id" ;;
      *)         die "job $id has status '$_st' but never produced a log. If it stayed 'launching' the worker never started (see '$0 status $id' for the reason); otherwise the job directory is incomplete." ;;
    esac
  fi
  shown="$(tail -n "$n" "$OSRC_JOBS/$id/out.log" 2>/dev/null)" || die "cannot read the log for $id (permissions?): $OSRC_JOBS/$id/out.log"
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
  # Cleanup can race a live supervisor (or recover after one was killed).  Stop the delegate's
  # complete tree before removing its worktree so grandchildren cannot survive as poisoned orphans.
  local live_pid; live_pid="$(cat "$OSRC_JOBS/$target/pid" 2>/dev/null)"
  [ -n "$live_pid" ] && _kill_tree "$live_pid"
  local wj="$OSRC_JOBS/$target/worktree.json"
  [ -f "$wj" ] || wj="$OSRC_HOME/loops/$target/worktree.json"
  [ -f "$wj" ] || { echo "[outsourcerer] $target has no worktree to clean."; return 0; }
  have jq || die "cleanup needs jq"
  local path branch dirty ahead base rp worktree_root
  path="$(jq -r '.path' "$wj")"; branch="$(jq -r '.branch' "$wj")"; base="$(jq -r '.base_sha // ""' "$wj")"
  # Never trust the serialized path: a lexical glob can be bypassed with
  # worktrees/../../..., so canonicalize and require strict containment first.
  case "$path" in *'..'*) die "refusing to remove path containing '..': $path" ;; esac
  rp="$(cd "$path" 2>/dev/null && pwd -P)" || die "refusing to remove non-canonical worktree path: $path"
  worktree_root="$(cd "$OSRC_HOME/worktrees" 2>/dev/null && pwd -P)" || die "refusing to resolve worktree root: $OSRC_HOME/worktrees"
  case "$rp" in "$worktree_root"/*) path="$rp" ;; *) die "refusing to remove path outside worktree root: $path" ;; esac
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

# =============================================================================
# CREW — turn `fanout --worktree edit` into a SAFE TRANSACTION.
# Coordinator only: reuses cmd_fanout (launch/wait), _worktree_setup (isolation, pinned base),
# _loop_check + _check_signature (grading), cmd_cleanup (teardown), record_outcome (history).
# A merge conflict -> skip that worker, preserve it, record a NON-learnable outcome (no auto-merge).
# =============================================================================

# _crew_check <dir> <check> <outfile> -> run the frozen check with cwd=<dir>; echo its rc. Reuses the
# loop family's bounded runner so a hung check can't wedge the crew (stock macOS has no timeout(1)).
_crew_check() {
  local dir="$1" check="$2" out="$3" secs="${OSRC_CHECK_TIMEOUT:-${OSRC_CHECK_TIMEOUT_DEFAULT:-300}}"
  # </dev/null so a check that reads stdin cannot consume the caller's members-list loop.
  ( cd "$dir" 2>/dev/null && _loop_check "$secs" "$check" "$out" ) </dev/null; return $?
}

# _crew_worse <base_rc> <base_sig> <post_rc> <post_sig> -> rc 0 if POST is WORSE than baseline.
# Ladder (v1): post passes -> not worse; baseline passed & post fails -> worse; both fail & signatures
# differ -> conservative worse (revert ambiguous change); both fail & identical -> not worse (a
# non-regressing failing baseline). Signature via _check_signature strips volatile tokens.
_crew_worse() {
  local brc="$1" bsig="$2" prc="$3" psig="$4"
  [ "${prc:-1}" -eq 0 ] 2>/dev/null && return 1
  [ "${brc:-1}" -eq 0 ] 2>/dev/null && return 0
  diff -q "$bsig" "$psig" >/dev/null 2>&1 && return 1 || return 0
}

# _crew_worktree_clean <root> -> rc 0 if the caller tree has no TRACKED changes. Ignores our own
# untracked worktree dir (.outsourcerer/worktrees/ lives inside the repo and would otherwise read as
# dirty); ff-only promotion only cares about tracked divergence, and untracked files are never clobbered.
_crew_worktree_clean() {
  # -uno = ignore ALL untracked (ff-only never clobbers untracked); only tracked divergence matters.
  [ -z "$(git -C "$1" status --porcelain -uno 2>/dev/null | head -1)" ]
}

# _crew_scan_staged <dir> -> rc 0 if the STAGED delta contains a live-secret VALUE (block integration).
# Mirrors the value patterns in _secret_scan (second defense; workers already passed the cloud gate).
_crew_scan_staged() {
  # --text/--no-ext-diff/--no-textconv defeat a worker-planted .gitattributes that would hide or
  # execute during the diff. Patterns cover current key shapes (sk-proj-, github_pat_, xox*, AKIA).
  git -C "$1" diff --cached --text --no-ext-diff --no-textconv 2>/dev/null \
    | grep -Eq 'OPENROUTER_API_KEY|sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[bpoas]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AWS_SECRET[_A-Z]*|-----BEGIN [A-Z ]*PRIVATE KEY-----'
}

# crew --check '<cmd>' [fanout routing flags] -- "task1" "task2" ...
cmd_crew() {
  local check="" a; local -a passthru=() tasks=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) [ -n "${2:-}" ] || die "crew --check needs a command"; check="$2"; shift 2 ;;
      --)      shift; tasks=("$@"); break ;;
      *)       passthru+=("$1"); shift ;;
    esac
  done
  [ -n "$check" ] || die "crew requires --check '<command>' (run on the baseline and after each worker)"
  [ "${#tasks[@]}" -gt 0 ] || die "crew needs tasks after -- (e.g. crew --check 'make test' -- \"do X\" \"do Y\")"
  have git || die "crew needs git"; have jq || die "crew needs jq"

  # --- Preflight: fail closed (R7) ---
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$root" ] || die "crew needs a git repository (cwd is not one). Read-only fanout still works without git."
  git -C "$root" rev-parse HEAD >/dev/null 2>&1 || die "crew: repo has no HEAD commit — make an initial commit first."
  git -C "$root" worktree list >/dev/null 2>&1 || die "crew: this git build lacks 'git worktree'."
  _crew_worktree_clean "$root" || die "crew: caller tree has uncommitted tracked changes — commit or stash first (crew never auto-stashes)."
  local caller_branch base_sha
  caller_branch="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || echo '')"
  [ -n "$caller_branch" ] || die "crew: HEAD is detached — check out a branch to promote onto."
  base_sha="$(git -C "$root" rev-parse HEAD)"

  # --- Crew state + integration worktree at the PINNED base (baseline runs HERE, before launch) ---
  local crew_id cdir; crew_id="crew-$(_new_job_id)"; cdir="$OSRC_HOME/fanout/$crew_id"
  _mkdir_private "$cdir" || true; : > "$cdir/verdicts.jsonl"
  local iwt ibr; iwt="$root/.outsourcerer/worktrees/$crew_id-int"; ibr="outsourcerer/$crew_id-int"
  git -C "$root" worktree add -q -b "$ibr" "$iwt" "$base_sha" 2>/dev/null \
    || die "crew: could not create integration worktree at $iwt"
  echo "[crew] $crew_id: integration worktree at $base_sha (branch $ibr)" >&2

  # --- Baseline (frozen check) in the integration worktree ---
  local base_rc bsig="$cdir/baseline.sig" bout="$cdir/baseline.out"
  _crew_check "$iwt" "$check" "$bout"; base_rc=$?
  _check_signature < "$bout" > "$bsig" 2>/dev/null || : > "$bsig"
  local promote_ok=1
  if [ "$base_rc" = "124" ] || [ "$base_rc" = "125" ]; then
    echo "[crew] baseline check is UNMEASURABLE (rc=$base_rc) — integrating candidates but auto-promotion DISABLED. Fix the check or use a self-contained one." >&2
    promote_ok=0
  else
    echo "[crew] baseline check rc=$base_rc (this is the bar every worker must not worsen)" >&2
  fi

  # --- Launch workers isolated, all branched from the SAME pinned base ---
  jq -cn '$ARGS.positional' --args "${tasks[@]}" > "$cdir/tasks.json"   # newline-safe task list
  local gid
  gid="$(OSRC_WORKTREE_BASE="$base_sha" cmd_fanout --worktree --verb edit ${passthru[@]+"${passthru[@]}"} -- "${tasks[@]}")" || true
  gid="$(printf '%s' "$gid" | tail -1)"
  case "$gid" in fanout-*) ;; *) git -C "$root" worktree remove --force "$iwt" 2>/dev/null; git -C "$root" branch -D "$ibr" 2>/dev/null; die "crew: worker fanout failed to launch (gid='$gid')" ;; esac
  echo "$gid" > "$cdir/fanout_gid"
  _fanout_wait "$gid" || true

  _crew_integrate "$root" "$iwt" "$ibr" "$gid" "$crew_id" "$cdir" "$check" "$base_rc" "$bsig" "$base_sha" "$caller_branch" "$promote_ok"
}

# _crew_integrate <root> <iwt> <ibr> <gid> <crew_id> <cdir> <check> <base_rc> <bsig> <base_sha> <caller_branch> <promote_ok>
# The post-launch transaction: integrate each worker (squash -> scan -> grade -> keep/revert/skip),
# ff-only promote from the caller worktree, selective cleanup. Split from the launch so it can be
# exercised against a pre-built worker group without real delegations. Reads task list from cdir/tasks.json.
_crew_integrate() {
  local root="$1" iwt="$2" ibr="$3" gid="$4" crew_id="$5" cdir="$6" check="$7" base_rc="$8" bsig="$9" base_sha="${10}" caller_branch="${11}" promote_ok="${12}"
  local gd; gd="$(_fanout_dir "$gid")"
  local -a hooksoff=(-c "core.hooksPath=$cdir/nohooks" -c commit.gpgsign=false -c user.name=outsourcerer-crew -c user.email=crew@outsourcerer.local)
  mkdir -p "$cdir/nohooks"
  local jid label idx=0 accepted=0 reverted=0 skipped=0
  while IFS="$(printf '\t')" read -r jid label; do
    [ -n "$jid" ] || continue
    idx=$((idx+1))
    local wj="$OSRC_JOBS/$jid/worktree.json" wbr lane model tclass pre
    [ -f "$wj" ] || { echo "[crew] $label: no worktree receipt (worker fell back to shared checkout) — skipping, non-learnable." >&2; record_outcome blocked provider_error "" "$jid" "" ""; skipped=$((skipped+1)); continue; }
    wbr="$(jq -r '.branch' "$wj" 2>/dev/null)"
    lane="$(_job_field "$jid" '.lane')"; [ "$lane" = "?" ] && lane=""
    model="$(_job_field "$jid" '.model')"; [ "$model" = "?" ] && model=""
    # task_class by the ORIGINAL task index encoded in the label (task-NN); non-numeric label -> position.
    local _ti="${label##*-}"; case "$_ti" in ''|*[!0-9]*) _ti="$idx" ;; *) _ti="$((10#$_ti))" ;; esac
    tclass="$(_classify_task "$(jq -r --argjson i "$((_ti-1))" '.[$i] // ""' "$cdir/tasks.json" 2>/dev/null)")"
    pre="$(git -C "$iwt" rev-parse HEAD)"
    # squash-merge the worker branch into the integration worktree
    if ! git -C "$iwt" merge --squash "$wbr" >/dev/null 2>&1; then
      # CONFLICT (not auto-resolved) -> hard-reset to the pre-worker commit, skip + preserve, non-learnable.
      git -C "$iwt" reset --merge >/dev/null 2>&1 || true
      git -C "$iwt" checkout -f . >/dev/null 2>&1 || true
      git -C "$iwt" reset --hard "$pre" >/dev/null 2>&1 || true
      git -C "$iwt" clean -fdq >/dev/null 2>&1 || true
      echo "[crew] $label: MERGE CONFLICT — skipped + preserved (resolve manually), non-learnable." >&2
      record_outcome blocked merge_conflict "" "$jid" "$lane" "$model" "$tclass"
      printf '{"worker":"%s","verdict":"conflict"}\n' "$label" >> "$cdir/verdicts.jsonl"
      skipped=$((skipped+1)); continue
    fi
    git -C "$iwt" add -A >/dev/null 2>&1
    if git -C "$iwt" diff --cached --quiet 2>/dev/null; then
      git -C "$iwt" reset --hard "$pre" >/dev/null 2>&1 || true
      # An empty squash may mean the worker left UNCOMMITTED edits — preserve them, never force-delete.
      local _wp; _wp="$(jq -r '.path' "$wj" 2>/dev/null)"
      if [ -n "$_wp" ] && [ -n "$(git -C "$_wp" status --porcelain 2>/dev/null | head -1)" ]; then
        echo "[crew] $label: worker left uncommitted changes — preserved, non-learnable." >&2
        record_outcome blocked provider_error "" "$jid" "$lane" "$model" "$tclass"
        printf '{"worker":"%s","verdict":"dirty"}\n' "$label" >> "$cdir/verdicts.jsonl"
      else
        echo "[crew] $label: no changes — skipped (non-learnable)." >&2
        record_outcome completed_unverified "" "" "$jid" "$lane" "$model" "$tclass"
        printf '{"worker":"%s","verdict":"no_change"}\n' "$label" >> "$cdir/verdicts.jsonl"
      fi
      skipped=$((skipped+1)); continue
    fi
    if _crew_scan_staged "$iwt"; then
      git -C "$iwt" reset --hard "$pre" >/dev/null 2>&1 || true
      echo "[crew] $label: SECRET in staged delta — blocked + preserved, non-learnable." >&2
      record_outcome blocked secret_scan "" "$jid" "$lane" "$model" "$tclass"
      printf '{"worker":"%s","verdict":"secret"}\n' "$label" >> "$cdir/verdicts.jsonl"
      skipped=$((skipped+1)); continue
    fi
    # squash commit (hooks off + no gpgsign + explicit identity). A failed commit must NOT cascade:
    # reset and skip so the next worker's pre-commit baseline stays correct.
    if ! git -C "$iwt" "${hooksoff[@]}" commit -q -m "crew: $label" >/dev/null 2>&1; then
      git -C "$iwt" reset --hard "$pre" >/dev/null 2>&1 || true
      echo "[crew] $label: could not commit the integration squash — skipped, non-learnable." >&2
      record_outcome blocked provider_error "" "$jid" "$lane" "$model" "$tclass"
      printf '{"worker":"%s","verdict":"blocked"}\n' "$label" >> "$cdir/verdicts.jsonl"
      skipped=$((skipped+1)); continue
    fi
    # grade against the baseline bar
    local prc psig="$cdir/w-$idx.sig" pout="$cdir/w-$idx.out"
    _crew_check "$iwt" "$check" "$pout"; prc=$?
    _check_signature < "$pout" > "$psig" 2>/dev/null || : > "$psig"
    # A check that could not RUN (timeout/couldn't-start) is infra, never a learnable quality failure.
    case "$prc" in
      124|125) git -C "$iwt" reset --hard "$pre" >/dev/null 2>&1
               echo "[crew] $label: check could not run (rc=$prc) — reverted, non-learnable." >&2
               record_outcome blocked timeout "" "$jid" "$lane" "$model" "$tclass"
               printf '{"worker":"%s","verdict":"reverted"}\n' "$label" >> "$cdir/verdicts.jsonl"
               skipped=$((skipped+1)); continue ;;
    esac
    if _crew_worse "$base_rc" "$bsig" "$prc" "$psig"; then
      git -C "$iwt" reset --hard "$pre" >/dev/null 2>&1
      local now; now="$(git -C "$iwt" rev-parse HEAD)"
      [ "$now" = "$pre" ] || die "crew: revert restoration FAILED for $label (HEAD=$now expected=$pre) — aborting, integration preserved at $iwt."
      git -C "$iwt" clean -fdq >/dev/null 2>&1 || true
      echo "[crew] $label: regressed the check -> REVERTED (restored $pre)." >&2
      # Only a MEASURABLE baseline yields a learnable outcome; otherwise the comparison is meaningless.
      if [ "$promote_ok" = "1" ]; then record_outcome reverted test_failure "" "$jid" "$lane" "$model" "$tclass"
      else record_outcome completed_unverified "" "" "$jid" "$lane" "$model" "$tclass"; fi
      printf '{"worker":"%s","verdict":"reverted"}\n' "$label" >> "$cdir/verdicts.jsonl"
      reverted=$((reverted+1))
    else
      echo "[crew] $label: check holds -> KEPT." >&2
      if [ "$promote_ok" = "1" ]; then record_outcome passed "" "" "$jid" "$lane" "$model" "$tclass"
      else record_outcome completed_unverified "" "" "$jid" "$lane" "$model" "$tclass"; fi
      printf '{"worker":"%s","verdict":"accepted"}\n' "$label" >> "$cdir/verdicts.jsonl"
      accepted=$((accepted+1))
    fi
  done < "$gd/members.tsv"

  # --- Promotion: ff-only from the CALLER's own worktree, after re-verify (R5) ---
  local ahead; ahead="$(git -C "$iwt" rev-list --count "$base_sha..HEAD" 2>/dev/null || echo 0)"
  echo "[crew] $crew_id: accepted=$accepted reverted=$reverted skipped=$skipped (integration ahead $ahead)" >&2
  local promoted=0
  if [ "$promote_ok" = "1" ] && [ "${ahead:-0}" -gt 0 ]; then
    if [ "$(git -C "$root" rev-parse HEAD)" != "$base_sha" ] || [ "$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null)" != "$caller_branch" ]; then
      echo "[crew] caller branch moved/switched during the run — REFUSING to promote. Integration preserved at $iwt (branch $ibr). Inspect, then merge manually." >&2
    elif ! _crew_worktree_clean "$root"; then
      echo "[crew] caller tree has uncommitted tracked changes — REFUSING to promote. Integration preserved at $iwt." >&2
    else
      git -C "$root" merge --ff-only "$ibr" >/dev/null 2>&1; local _mrc=$?
      if [ "$_mrc" = "0" ] && [ "$(git -C "$root" rev-parse HEAD)" = "$(git -C "$iwt" rev-parse HEAD)" ]; then
        echo "[crew] promoted $accepted worker(s) onto $caller_branch (ff-only)." >&2; promoted=1
      elif [ "$_mrc" = "0" ]; then
        echo "[crew] promotion applied but caller advanced again in the gap — verify $caller_branch." >&2; promoted=1
      else
        echo "[crew] ff-only promotion refused (caller diverged) — integration preserved at $iwt." >&2
      fi
    fi
  elif [ "${ahead:-0}" -eq 0 ]; then
    echo "[crew] nothing to promote (no worker was accepted)." >&2
  else
    echo "[crew] promotion disabled (unmeasurable baseline) — integration preserved at $iwt (branch $ibr)." >&2
  fi

  # --- Selective cleanup: remove ONLY accepted/reverted/no_change workers; preserve the rest ---
  local preserved=""
  while IFS="$(printf '\t')" read -r jid label; do
    [ -n "$jid" ] || continue
    local v; v="$(grep -F "\"worker\":\"$label\"" "$cdir/verdicts.jsonl" 2>/dev/null | tail -1 | jq -r '.verdict' 2>/dev/null)"
    case "$v" in
      accepted|reverted|no_change) ( cmd_cleanup "$jid" --force ) >/dev/null 2>&1 || true ;;   # subshell: a die inside can't kill crew
      *) preserved="$preserved $label"; ;;   # conflict / secret / blocked -> keep evidence
    esac
  done < "$gd/members.tsv"
  if [ "$promoted" = "1" ]; then
    git -C "$root" worktree remove --force "$iwt" 2>/dev/null || true
    git -C "$root" branch -D "$ibr" 2>/dev/null || true
  fi
  [ -n "$preserved" ] && echo "[crew] preserved for inspection:$preserved  (remove with: $0 cleanup <job-id> --force; integration: $iwt)" >&2
  echo "$crew_id"
}

# gc [--older-than DAYS]. Delete completed job dirs whose mtime is older than N days.
# Only terminal states (done/done?/failed/blocked/timeout/wedged/canceled/permission-blocked)
# are removed; running/interrupted jobs are left alone.
cmd_gc() {
  local days="${OSRC_JOB_TTL_DAYS:-3}" auto=0 cap=0
  if [ "${1:-}" = "--auto" ]; then
    auto=1
    cap="${OSRC_AUTO_GC_MAX:-20}"
  elif [ "${1:-}" = "--older-than" ]; then
    [ -n "${2:-}" ] || die "gc --older-than needs a positive integer number of days"
    days="$2"
  elif [ -n "${1:-}" ]; then
    die "gc: usage: gc [--older-than DAYS]"
  fi
  case "$days" in ''|*[!0-9]*|'0'* ) die "gc --older-than needs a positive integer, got '$days'" ;; esac
  case "$cap" in 0) ;; *[!0-9]*|'') cap=20 ;; esac
  [ -d "$OSRC_JOBS" ] || { echo "[outsourcerer] no jobs to gc."; return 0; }
  local removed=0 skipped=0 checked=0 d st mtime now cutoff
  now=$(date +%s)
  cutoff=$(( now - days * 86400 ))
  for d in "$OSRC_JOBS"/*/; do
    [ -d "$d" ] || continue
    # Auto-GC examines only a small oldest-first sample.  Manual gc remains a
    # complete maintenance operation; launch-time housekeeping never becomes a
    # proportional shell walk as history grows.
    if [ "$auto" = 1 ] && [ "$checked" -ge "$cap" ]; then break; fi
    checked=$((checked+1))
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
  if [ "$auto" = 1 ]; then
    echo "[outsourcerer] auto-gc: removed $removed job dirs older than $days days; checked $checked (cap $cap)"
  else
    echo "[outsourcerer] gc: removed $removed job dirs older than $days days; skipped $skipped (non-terminal or younger)"
  fi
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
    # `interrupted` is terminal. Reconciliation flips dead jobs to it, so omitting it here means a
    # killed member is counted as live forever and `fanout wait` never returns.
    case "$st" in done|done\?|failed|blocked|timeout|wedged|canceled|permission-blocked|interrupted) ;; *) n=$((n+1)) ;; esac
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
  local maxpar_explicit=0
  local g_model="" g_effort="" g_tier="" g_prov="" taskstr="" route_spec=""   # global knobs OVERRIDE per-agent frontmatter
  local -a subs=() fwd=() inline=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --verb)         [ -n "${2:-}" ] || die "--verb needs run|research|edit|yolo"; verb="$2"; shift 2 ;;
      --max)          [ -n "${2:-}" ] || die "--max needs a number"; maxpar="$2"; maxpar_explicit=1; shift 2 ;;
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
  # DEVIN CONCURRENCY CEILING. Measured, not guessed: a 4-way fanout on this lane reliably loses
  # members to `exit=141` with an EMPTY log (SIGPIPE before the delegate emits a byte) — 2 of 4 died
  # in the reference run, and the surviving 2 completed normally. Trivial/instant prompts can slip
  # past it, which is why a casual 6-way smoke test looks clean and a real 4-way workload does not.
  # The generic default of 6 therefore silently burns a third to a half of any Devin crew. Cap the
  # lane at 2 unless the caller asked for a specific number; an explicit --max is still honoured so
  # this is a safer default, not a new hard limit. OSRC_FANOUT_MAX also still wins.
  if [ "$maxpar_explicit" = "0" ] && [ -z "${OSRC_FANOUT_MAX:-}" ]; then
    case "${g_prov:-${PROVIDER:-devin}}" in
      devin|dv)
        [ "$maxpar" -gt 2 ] 2>/dev/null && {
          maxpar=2
          echo "[outsourcerer] fanout: capping concurrency at 2 on the devin lane (measured ceiling; above it members die with exit=141/empty-output before producing anything). Override with --max N if you want more." >&2; }
      ;;
    esac
  fi
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
_so_resolve() {  # <model> -> "resolved_id|disp|tier" (mirrors run-verb routing)
  local model="$1" row id tlane tier disp elane
  row="$(resolve_model_row "$model")"
  if [ -n "$row" ]; then
    id="${row%%|*}"; row="${row#*|}"; tlane="${row%%|*}"; tier="${row##*|}"
  else
    id="$model"; tlane=""; tier=""
  fi
  elane="$(_effective_lane "$tlane" "$PROVIDER" "$model" "1")"
  case "$elane" in
    local) disp=local ;;
    cx) disp=cxnative ;;
    cc) disp=ccnative ;;
    gm) disp=gmnative ;;
    dv) disp=devin ;;
    or) case "$PROVIDER" in cc) disp=ccor ;; codex) disp=codexor ;; *) disp=ccor ;; esac ;;
    droid|cursor|hermes|warp|claudex) disp="$elane" ;;
    *) disp="${tlane:-$PROVIDER}" ;;
  esac
  if [ "$elane" = "dv" ] && [ "$PROVIDER" = "devin" ]; then
    local dvm; dvm="$(_devin_model_for "$model")"
    [ -n "$dvm" ] && id="$dvm" || disp=ccor
  fi
  [ -n "$tier" ] || tier="$(resolve_tier "$id" "")"
  printf '%s|%s|%s\n' "$id" "$disp" "$tier"
}
_so_run() {   # <model> <prompt> -> stdout text via the same read-only routing as `run`
  OSRC_NO_AUTODETACH=1 OSRC_STREAM=0 OSRC_LEDGER_QUIET=1 \
    route_delegate auto run -m "$1" -- "$2"
}
second_opinion() {
  # --judge-anyway forces the paid adjudication even when the free gate could decide for $0.
  # Capture _so_orig (the auto-detach replay uses it) WITH the flag preserved, so a forced judge
  # survives the detached rerun. We re-add it after stripping for local parsing.
  local _judge_anyway="${OSRC_JUDGE_ANYWAY:-0}" _so_args=()
  local _a; for _a in "$@"; do
    case "$_a" in --judge-anyway) _judge_anyway=1 ;; *) _so_args+=("$_a") ;; esac
  done
  set -- ${_so_args[@]+"${_so_args[@]}"}
  local _so_orig=("$@"); [ "$_judge_anyway" = "1" ] && _so_orig+=(--judge-anyway)
  _consume_flags "$@"
  local q="${REST[*]:-}"
  [ -n "$q" ] || die "second-opinion needs a question"
  local pair="${OSRC_SECOND_OPINION_MODELS:-z-ai/glm-5.2,sol}"
  [ "$MODEL_EXPLICIT" = "1" ] && pair="$MODEL"
  # Keep the adjudicator independent of both default candidates.
  local premium="${OSRC_SECOND_OPINION_PREMIUM:-fable}"
  case "$pair" in *,*,*|,*|*,'') die "second-opinion needs exactly two non-empty models (use -m a,b)" ;; esac
  local m1 m2; m1="${pair%%,*}"; m2="${pair#*,}"
  [ "$m1" != "$m2" ] || die "second-opinion needs two different models, got '$pair' (use -m a,b)"
  local _r1 _r2 _id1 _id2 _l1 _l2 _t1 _t2
  _r1="$(_so_resolve "$m1")"; _id1="${_r1%%|*}"; _r1="${_r1#*|}"; _l1="${_r1%%|*}"; _t1="${_r1##*|}"
  _r2="$(_so_resolve "$m2")"; _id2="${_r2%%|*}"; _r2="${_r2#*|}"; _l2="${_r2%%|*}"; _t2="${_r2##*|}"
  [ "$_id1" != "$_id2" ] || die "second-opinion models resolve to the same model: $_id1"
  echo ">>> second-opinion: $m1 ($_l1)  vs  $m2 ($_l2)" >&2
  # AUTO-DETACH: second-opinion runs 2-3 sequential cloud API calls (can take 2-5 min).
  # If non-interactive AND slow-lane, auto-promote to bg so a harness tool-timeout can't kill it.
  if _autodetach_should "$_l1" "$_id1" "$_t1" || _autodetach_should "$_l2" "$_id2" "$_t2"; then
    _autodetach_run second-opinion ${_so_orig[@]+"${_so_orig[@]}"}
    return $?
  fi
  local a1 a2 n1 n2
  a1="$(_so_run "$m1" "$q")"; a2="$(_so_run "$m2" "$q")"
  n1="$(printf '%s' "$a1" | _so_norm)"; n2="$(printf '%s' "$a2" | _so_norm)"
  record_ledger "$_l1" "$_id1" "$_t1" second-opinion "$q"
  record_ledger "$_l2" "$_id2" "$_t2" second-opinion "$q"
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
  # FREE GATE before the paid judge. Only when an objective contract is known (caller set
  # OSRC_EXPECT=json, or the question asks for JSON) do we try a $0 deterministic verdict: if exactly
  # ONE answer satisfies the required check and the other fails, that IS the answer — skip premium.
  # pass/pass, fail/fail, or unknown -> fall through to the paid judge (the gate NEVER suppresses
  # escalation on ambiguity). --judge-anyway forces the paid path regardless.
  if [ "$_judge_anyway" != "1" ]; then
    # Only arm on an EXPLICIT declared contract (OSRC_EXPECT=json). We deliberately do NOT sniff the
    # question for "json": form-validity is not content-correctness, so a valid-but-wrong answer must
    # never deterministically beat a correct one and suppress the judge on a guess.
    local _kind=""
    case "${OSRC_EXPECT:-}" in json) _kind=json ;; esac
    if [ -n "$_kind" ]; then
      _free_gate "$_kind" "$a1"; local _g1=$?
      _free_gate "$_kind" "$a2"; local _g2=$?
      if [ "$_g1" = "0" ] && [ "$_g2" = "1" ]; then
        record_ledger cc "$m1" cheap second-opinion-gate "$q"
        echo "== FREE GATE: $m1 passes the $_kind check, $m2 fails — resolved for \$0, no escalation ==" >&2
        printf '%s\n' "$a1"; return 0
      fi
      if [ "$_g2" = "0" ] && [ "$_g1" = "1" ]; then
        record_ledger cc "$m2" cheap second-opinion-gate "$q"
        echo "== FREE GATE: $m2 passes the $_kind check, $m1 fails — resolved for \$0, no escalation ==" >&2
        printf '%s\n' "$a2"; return 0
      fi
    fi
    # Confident-fail gate. A detector NEVER blesses an answer, and only ONE class of reject is safe to
    # RESOLVE on for $0: a violation of a caller-DECLARED contract (OSRC_CONTRACT_KEYS/RE). There, the
    # loser provably breaks the machine-declared shape AND the winner provably matches it, so picking the
    # winner is safe. A refusal or a truncation is a SOFT reject: it must NOT auto-resolve, because (a) a
    # refusal can be the CORRECT answer to the task (declining a harmful/impossible request), so silently
    # returning the other model's compliant-but-unchecked answer is a safety inversion, and (b) a
    # truncation heuristic (odd fence) misfires on a legitimately fence-containing answer. Both cases
    # ESCALATE to the paid judge instead — the one model equipped to tell a correct decline / real answer
    # from a wrong one. So: contract-violation single-fail -> resolve; anything else -> escalate.
    local _cf1 _cf2 _r1 _r2
    _r1="$(_confident_fail "$a1")"; _cf1=$?
    _r2="$(_confident_fail "$a2")"; _cf2=$?
    if [ "$_cf1" = "0" ] && [ "$_cf2" != "0" ] && _gate_resolves "$_r1"; then
      record_ledger cc "$m2" cheap "second-opinion-gate:$_r1" "$q"
      echo "== FREE GATE: $m1 violates the declared contract ($_r1), $m2 matches it — resolved for \$0, no escalation ==" >&2
      printf '%s\n' "$a2"; return 0
    fi
    if [ "$_cf2" = "0" ] && [ "$_cf1" != "0" ] && _gate_resolves "$_r2"; then
      record_ledger cc "$m1" cheap "second-opinion-gate:$_r2" "$q"
      echo "== FREE GATE: $m2 violates the declared contract ($_r2), $m1 matches it — resolved for \$0, no escalation ==" >&2
      printf '%s\n' "$a1"; return 0
    fi
    # A soft reject (refusal/truncation) on exactly one side does NOT resolve — note it and escalate.
    if { [ "$_cf1" = "0" ] && [ "$_cf2" != "0" ]; } || { [ "$_cf2" = "0" ] && [ "$_cf1" != "0" ]; }; then
      echo "== one answer looks like a soft reject (${_r1:-ok}/${_r2:-ok}) — NOT auto-resolving, escalating to the judge ==" >&2
    fi
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
  _tier_banner "codex-native" "$id" "$ttier" "$posture | $(_lane_cost_disclosure cx)"
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
  if [ "${OSRC_STREAM:-0}" != "1" ]; then
    local ql; ql="$(_codex_quota_line 2>/dev/null)"
    printf '>>> [receipt] %s.%s\n' "$(_lane_cost_disclosure cx)" "${ql:+ $ql}" >&2
  fi
  return "$rc"
}

# _cc_verify_model <requested-alias> <modelUsage-json-or-log> -> prints a verified/WARNING receipt to
# stderr from the REAL model in the run's `modelUsage`. This is the anti-lying guarantee: a native
# subagent's model can silently fall back to your default (Opus) with NO signal, but the claude CLI
# reports the model it actually used, so we can prove it and refuse to mislabel.
# _rule_files_note -> name the always-on rule files an agent CLI will inject beyond the working dir.
# Observed: the devin CLI marks ~/.claude/CLAUDE.md (and a Windsurf global_rules.md) as `always_on`
# and prepends them to every session. Two consequences, and the second is the one people miss:
#   1. those files leave the machine even though they sit outside the delegated scope, and
#   2. they are INSTRUCTIONS, so a delegate briefed for one narrow task also inherits a global
#      operating doctrine nobody chose for it.
# This is diagnostics only: it changes nothing about the run, it just stops the banner above from
# describing a smaller blast radius than the one that actually applies.
_rule_files_note() {
  local f found=""
  for f in "$HOME/.claude/CLAUDE.md" "$HOME/.codeium/windsurf/memories/global_rules.md" "$HOME/.config/AGENTS.md"; do
    [ -f "$f" ] && found="$found ${f#$HOME/}"
  done
  [ -n "$found" ] || return 0
  printf '>>>   also sent   : your agent CLI may inject always-on rule files from $HOME regardless of the scope above:%s\n' "$found"
  # Point at the CLI's own control rather than inventing a knob here. Outsourcerer does not perform this
  # injection and cannot switch it off from the outside; claiming otherwise would be a promise it cannot
  # keep. `devin rules list` shows exactly what is always-on for a given run.
  printf '>>>                 they are instructions, so they also steer the delegate. Inspect with: devin rules list\n'
}

_cc_verify_model() {
  local want="$1" src="$2" all actual foreign
  # Read EVERY model the run billed, not just the first. A run can START on the requested model and
  # SWITCH mid-flight (a fallback to the account default), which is invisible if you only look at the
  # opening entry: the receipt says "verified" while later turns executed on something else entirely.
  # modelUsage is keyed by model id, so a second key is a second model.
  # modelUsage is an object keyed by model id, and each value is itself an object. Matching `[^}]*`
  # stops at the FIRST inner closing brace, so only the opening model is ever seen — which is exactly
  # how a mid-run switch stayed invisible. Take the whole segment from modelUsage onward and pull every
  # key that opens an object; a model id always carries a version digit, which separates it from
  # sibling keys like "cache_creation" or "usage".
  local _seg
  _seg="$(grep -aoE '"modelUsage"[[:space:]]*:[[:space:]]*\{.*' "$src" 2>/dev/null | head -1)"
  [ -n "$_seg" ] || _seg="$(printf '%s' "$src" | grep -aoE '"modelUsage"[[:space:]]*:[[:space:]]*\{.*' | head -1)"
  all="$(printf '%s' "$_seg" \
        | grep -oE '"[^"]+"[[:space:]]*:[[:space:]]*\{' \
        | sed -E 's/^"([^"]*)".*/\1/' \
        | grep -E '[0-9]' | sort -u | tr '\n' ' ')"
  [ -n "$all" ] || return 0
  actual="${all% }"
  # Anything present that is NOT the requested model is drift, even if the requested one is there too.
  foreign=""
  local m
  for m in $all; do printf '%s' "$m" | grep -qiF "$want" || foreign="$foreign $m"; done
  if [ -z "$foreign" ]; then
    printf '>>> [verified] this run actually executed on %s (requested %s).\n' "$actual" "$want" >&2
    return 0
  fi
  if printf '%s' "$all" | grep -qiF "$want"; then
    # The dangerous case: it ran as asked, then drifted. A single-model check calls this "verified".
    printf '>>> [MODEL DRIFT] you requested %s and the run STARTED there but ALSO executed on:%s\n' "$want" "$foreign" >&2
    printf '>>>   A mid-run fallback is silent and billed to whatever it fell back to. Do NOT label this output as pure %s.\n' "$want" >&2
    # Be exact about WHEN this is known: usage is only reported once the run ends, so this is a
    # post-hoc receipt, not an interception. Promising an abort here would be a guarantee the tool
    # cannot keep. The only place drift can be corrected while it is happening is a live session.
    printf '>>>   Detected after the fact (usage is only reported at the end). To catch it live, run it as a `session` and correct with: session model %s\n' "$want" >&2
  else
    printf '>>> [WARNING] you requested %s but the run ACTUALLY executed on %s. Do NOT label the output as %s (that would be a fabricated model identity). Likely a silent model fallback, check that %s is available on your plan/region.\n' "$want" "$actual" "$want" "$want" >&2
  fi
  return 3
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
  _tier_banner "claude-native" "$id" "$ttier" "$posture | $(_lane_cost_disclosure cc) | env: $load_note"
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
  printf '>>> [receipt] %s.\n' "$(_lane_cost_disclosure cc)" >&2
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
  # ADVISORY on gemini-cli, which still has no knob. The shared prompt keeps effort visible to both.
  if [ -n "$EFFORT" ] && [ "$vehicle" != "agy" ]; then
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
    _tier_banner "antigravity-agy (keyless)" "$atok" "$ttier" "$posture | $(_lane_cost_disclosure gm)"
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
      printf '>>>   fall back  : OSRC_GEMINI_VEHICLE=gemini (needs GEMINI_API_KEY in ~/.env), or use a different lane entirely (-m glm spends Devin plan limits).\n' >&2
      printf '>>>   tune       : OSRC_AGY_PRINT_TIMEOUT=%s was the wait; lower it to fail faster while this lane is unhealthy.\n' "${OSRC_AGY_PRINT_TIMEOUT:-5m}" >&2
      rc="${rc:-124}"; [ "$rc" = "0" ] && rc=124
    fi
    rm -f "$_aerr" 2>/dev/null || true
    record_ledger antigravity-agy "$atok" "$ttier" "$tier" "$task"
    printf '>>> [receipt] %s.\n' "$(_lane_cost_disclosure gm)" >&2
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
  _tier_banner "gemini-cli (api key)" "$id" "$ttier" "$posture | $(_lane_cost_disclosure gemini)"
  local ofmt=(--output-format text); [ "${OSRC_STREAM:-0}" = "1" ] && ofmt=(--output-format json)
  # ISOLATION (I1, gemini harness parity): gemini-cli loads ~/.gemini/settings.json mcpServers
  # unconditionally; a headless run can wedge on an interactive-auth MCP server. --allowed-mcp-server-names
  # is an allowlist (array); a sentinel matching NO configured server (__none__) means ZERO MCP servers
  # load. Escape hatch: OSRC_GEMINI_USER_MCP=1 drops the flag so the full live surface loads.
  local gmcp=()
  [ "${OSRC_GEMINI_USER_MCP:-0}" = "1" ] || gmcp=(--allowed-mcp-server-names __none__)
  gemini -p "$wrapped" "${gflag[@]}" "${gmcp[@]+"${gmcp[@]}"}" "${ofmt[@]}" --model "$id" || rc=$?
  record_ledger gemini "$id" "$ttier" "$tier" "$task"
  printf '>>> [receipt] %s.\n' "$(_lane_cost_disclosure gemini)" >&2
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
  _tier_banner "claudex (Claude harness -> CLIProxyAPI)" "$id" "$ttier" "$posture | $(_lane_cost_disclosure claudex) through your local proxy"
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
  printf '>>> [receipt] %s, through your local CLIProxyAPI.\n' "$(_lane_cost_disclosure claudex)" >&2
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
  local task="${REST[*]}" id="${MODEL:-}" model_key="${MODEL:-droid}" ledger_model="droid-default"
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
  if [ "${MODEL_EXPLICIT:-0}" = "1" ] && [ -n "$id" ]; then
    id="$(_lane_model_for droid "$id")"; model_key="$id"; ledger_model="$id"
    _validate_model_token "$id"; mflag=(-m "$id")
  else id="(droid default/configured)"; fi
  local eff=()
  if [ -n "$EFFORT" ]; then local de; de="$(_droid_effort "$EFFORT")"
    [ -n "$de" ] && { eff=(-r "$de"); printf '>>> [effort] reasoning=%s (native: droid exec -r %s)\n' "$EFFORT" "$de" >&2; }; fi
  local ttier; ttier="$(resolve_tier "$model_key" "${TTIER:-}")" || ttier="capable"
  local wrapped; wrapped="$(_build_prompt "$model_key" "$task" "$ttier")"
  _tier_banner "droid (Factory)" "$id" "$ttier" "$posture | $(_lane_cost_disclosure droid)"
  local rc=0
  droid exec ${mflag[@]+"${mflag[@]}"} ${aflag[@]+"${aflag[@]}"} ${eff[@]+"${eff[@]}"} -o text "$wrapped" || rc=$?
  record_ledger droid "$ledger_model" "$ttier" "$tier" "$task"
  printf '>>> [receipt] %s.\n' "$(_lane_cost_disclosure droid)" >&2
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
  _tier_banner "cursor-agent" "$id" "$ttier" "$posture | $(_lane_cost_disclosure cursor)"
  local rc=0
  "$cur" -p "$wrapped" ${mflag[@]+"${mflag[@]}"} ${fflag[@]+"${fflag[@]}"} --trust --output-format text || rc=$?
  record_ledger cursor "${MODEL:-cursor-default}" "$ttier" "$tier" "$task"
  printf '>>> [receipt] %s.\n' "$(_lane_cost_disclosure cursor)" >&2
  return "$rc"
}

# =============================================================================
# HERMES LANE (NousResearch hermes-agent). Engine lane: -m passes through verbatim,
# Hermes owns its model catalog. Real per-run cost is read from ~/.hermes/state.db
# after the run via _hermes_run_cost; when unavailable, the labeled token estimate is used.
# =============================================================================

delegate_hermes() {
  local tier="$1"
  [ "${#REST[@]}" -gt 0 ] || die "no task prompt given"
  local task="${REST[*]}" id="${MODEL:-}"
  # Fail FAST on a missing CLI -- before the cloud gate and before auto-detach would bury this
  # error inside a background job the caller has to dig out.
  have hermes || die "hermes CLI not on PATH (Hermes agent lane). Install: https://github.com/NousResearch/hermes-agent  (then run 'hermes' once to configure). -m passes through verbatim; model catalog is yours to configure."

  # Scripted one-shot entry point: `hermes -z "<prompt>"` -- "single prompt in, final response text
  # out, nothing else on stdout or stderr" (Nous CLI reference). That is exactly the delegation
  # contract, so stdout is the answer and a non-zero exit is the failure signal.
  #
  # Approval posture. Hermes' one-shot mode exposes a BINARY approval model, not the graded levels
  # droid/cursor offer: the default non-interactive posture refuses a dangerous command (surfacing
  # an error rather than prompting), and `--yolo` bypasses all approval. There is no documented
  # middle rung, so a mutating verb maps to --yolo -- the same shape as the cursor lane, where
  # accept-edits already means --force (apply edits and commands without per-step prompts). This is
  # disclosed in the posture banner so the trade is visible, never silent.
  local yflag=() posture
  case "$tier" in
    auto)         yflag=();         posture="SAFE (hermes default non-interactive posture: dangerous commands are refused, not run)" ;;
    accept-edits) yflag=(--yolo);   posture="MUTATING (--yolo: hermes one-shot has no graded approval, so edits+commands are auto-approved, like cursor --force)" ;;
    autonomous)   yflag=(--yolo);   posture="MUTATING (--yolo: auto-approves edits+commands; hermes exposes no separate sandbox posture for one-shot)" ;;
    dangerous)    yflag=(--yolo);   posture="DANGER (--yolo: all approvals bypassed)" ;;
    *) die "bad tier: $tier" ;;
  esac
  # Engine lane: -m passes through verbatim (Hermes owns its model/provider catalog; a
  # "provider/model" string is accepted by --model directly, per the Nous docs).
  local mflag=()
  if [ "${MODEL_EXPLICIT:-0}" = "1" ] && [ -n "$id" ]; then _validate_model_token "$id"; mflag=(--model "$id"); else id="(hermes default/configured)"; fi
  [ -n "$EFFORT" ] && printf '>>> [effort] reasoning=%s (advisory only: hermes one-shot has no effort flag; folded into the prompt)\n' "$EFFORT" >&2
  # Isolated git worktree when the caller asked for one (`-w` is a hermes global flag).
  local wflag=(); [ "${OSRC_WORKTREE:-0}" = "1" ] && wflag=(-w)
  local ttier; ttier="$(resolve_tier "${MODEL:-}" "${TTIER:-}")" || ttier="capable"
  local wrapped; wrapped="$(_build_prompt "${MODEL:-hermes}" "$task" "$ttier")"
  _tier_banner "hermes (NousResearch)" "$id" "$ttier" "$posture | $(_lane_cost_disclosure hermes)"
  local rc=0
  hermes ${wflag[@]+"${wflag[@]}"} -z "$wrapped" ${mflag[@]+"${mflag[@]}"} ${yflag[@]+"${yflag[@]}"} || rc=$?
  record_ledger hermes "${MODEL:-hermes-default}" "$ttier" "$tier" "$task"
  printf '>>> [receipt] %s.\n' "$(_lane_cost_disclosure hermes)" >&2
  return "$rc"
}

# =============================================================================
# WARP LANE (Warp's Oz agent, `oz agent run`). Engine lane: -m passes through verbatim to Warp's
# own model catalog (`oz model list`), and Warp can even HOST the Claude or Codex harness via
# --harness (OSRC_WARP_HARNESS=claude|codex). Autonomy on `oz agent run` is NOT a graded per-run
# flag; it is governed by the agent PROFILE, so we disclose that honestly and let the user pin one
# with OSRC_WARP_PROFILE. Cloud lane (Warp's backend + the model API) -> full cloud gate applies.
# Billing: your Warp plan / the keys configured in your Warp account.
# =============================================================================
delegate_warp() {
  local tier="$1"
  [ "${#REST[@]}" -gt 0 ] || die "no task prompt given"
  local task="${REST[*]}" id="${MODEL:-}" model_key="${MODEL:-warp}" ledger_model="warp-default"
  have oz || die "oz CLI not on PATH (Warp lane). It ships INSIDE Warp.app at Contents/Resources/bin/oz — symlink it: ln -s '/Applications/Warp.app/Contents/Resources/bin/oz' ~/.local/bin/oz  (then 'oz login' once)."
  # Warp's autonomy is a PROFILE property, not a per-run flag (`oz agent run` exposes no
  # off/low/high graded permission switch). We surface that truthfully rather than pretend a
  # tier maps to a sandbox posture it doesn't have. Pin a profile with OSRC_WARP_PROFILE=<id>
  # (see `oz agent profile list`); a mutating tier without a pinned profile is disclosed loudly.
  local pflag=() posture
  [ -n "${OSRC_WARP_PROFILE:-}" ] && pflag=(--profile "$OSRC_WARP_PROFILE")
  case "$tier" in
    auto)         posture="runs under your Warp agent profile's permissions (Warp has no per-run read-only flag)" ;;
    accept-edits|autonomous)
                  posture="MUTATING under your Warp profile${OSRC_WARP_PROFILE:+ '$OSRC_WARP_PROFILE'} (Warp governs approvals by profile, not per-run; set OSRC_WARP_PROFILE to pin an auto-approving one)" ;;
    dangerous)    posture="DANGER: relies on your Warp profile allowing unattended commands; Warp exposes no separate 'bypass all' per-run flag" ;;
    *) die "bad tier: $tier" ;;
  esac
  # --harness lets Warp host the Claude or Codex harness with THAT harness's model ids; default is
  # Warp's own Oz harness. Opt in via OSRC_WARP_HARNESS=claude|codex.
  local hflag=()
  case "${OSRC_WARP_HARNESS:-}" in
    claude|codex) hflag=(--harness "$OSRC_WARP_HARNESS") ;;
    "") : ;;
    *) die "OSRC_WARP_HARNESS must be 'claude' or 'codex' (got '$OSRC_WARP_HARNESS')" ;;
  esac
  local mflag=()
  if [ "${MODEL_EXPLICIT:-0}" = "1" ] && [ -n "$id" ]; then
    id="$(_lane_model_for warp "$id")"; model_key="$id"; ledger_model="$id"
    _validate_model_token "$id"; mflag=(--model "$id")
  else id="(warp default/configured)"; fi
  [ -n "$EFFORT" ] && printf '>>> [effort] reasoning=%s (advisory only: oz agent run has no effort flag; folded into the prompt)\n' "$EFFORT" >&2
  local ttier; ttier="$(resolve_tier "$model_key" "${TTIER:-}")" || ttier="capable"
  local wrapped; wrapped="$(_build_prompt "$model_key" "$task" "$ttier")"
  _tier_banner "warp (Oz agent)" "$id" "$ttier" "$posture | $(_lane_cost_disclosure warp)"
  local rc=0
  oz agent run -p "$wrapped" ${mflag[@]+"${mflag[@]}"} ${hflag[@]+"${hflag[@]}"} ${pflag[@]+"${pflag[@]}"} -C "$PWD" --output-format text || rc=$?
  record_ledger warp "$ledger_model" "$ttier" "$tier" "$task"
  printf '>>> [receipt] %s.\n' "$(_lane_cost_disclosure warp)" >&2
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
(glm-5.2/swe-1.7, spends Devin plan limits), OpenRouter (glm/hy3/deepseek via --provider cc|codex),
a VERIFIED Claude model (run -m fable|opus|sonnet|haiku, Claude subscription), ChatGPT-sub
models (run -m sol|terra|luna), keyless Gemini (run -m gemini-flash), or local Ollama (\$0 cash + \$0 plan, private).
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

# _osrc_realpath <path> -> physical path with all symlinks resolved (portable: macOS ships neither
# `readlink -f` nor `realpath` by default, so follow the chain by hand). This matters because
# SCRIPT_PATH may be a PATH launcher symlink (e.g. ~/.local/bin/outsourcerer); walking `..` from the
# UNresolved path would miss the real skill dir and silently mislink.
_osrc_realpath() {
  local p="$1" t i=0
  [ -n "$p" ] || return 1
  while [ -L "$p" ] && [ "$i" -lt 40 ]; do
    t="$(readlink "$p" 2>/dev/null)" || break
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
    i=$((i+1))
  done
  local d b
  d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  b="$(basename "$p")"
  printf '%s/%s' "$d" "$b"
}

# _osrc_skill_root -> the outsourcerer skill dir that contains SKILL.md, or empty+rc1. Tries, in
# order: (1) THIS script's PHYSICAL location (<root>/scripts/outsourcerer.sh -> <root>), which is
# correct for both a packaged-plugin install AND a ~/.claude/skills install even when invoked through
# a launcher symlink; (2) the canonical Claude skills path; (3) the plugin marketplace/cache. Used by
# every SKILL.md-host mirror (Hermes, Antigravity) so none of them hardcode a single install layout.
_osrc_skill_root() {
  local real cand g
  real="$(_osrc_realpath "$SCRIPT_PATH" 2>/dev/null)"
  if [ -n "$real" ]; then
    cand="$(cd "$(dirname "$real")/.." 2>/dev/null && pwd -P)"
    [ -n "$cand" ] && [ -f "$cand/SKILL.md" ] && { printf '%s' "$cand"; return 0; }
  fi
  cand="$HOME/.claude/skills/outsourcerer"
  [ -f "$cand/SKILL.md" ] && { printf '%s' "$cand"; return 0; }
  for g in "$HOME"/.claude/plugins/marketplaces/*/plugins/outsourcerer/skills/outsourcerer \
           "$HOME"/.claude/plugins/cache/*/outsourcerer/*/skills/outsourcerer; do
    [ -f "$g/SKILL.md" ] && { printf '%s' "$g"; return 0; }
  done
  return 1
}

# _osrc_link_skill_into <dst_skills_dir> <skill_root> -> install outsourcerer as a SKILL.md skill via
# an idempotent, collision-safe symlink. Return codes: 0 linked; 2 could not create dir/link;
# 3 a directory (real or symlinked) already occupies the destination. rc3 is the important one:
# `ln -sfn TARGET dst` when `dst` is a real directory does NOT replace it -- it creates a nested link
# `dst/<basename TARGET>` INSIDE it and returns success, so the bridge would silently no-op while
# reporting "linked". We refuse that case loudly instead. Replacement of a symlink (incl. a dangling
# one, from a moved/upgraded skill) is atomic via a temp link + mv, so a crash can't leave a half-state.
_osrc_link_skill_into() {
  local dstdir="$1" src="$2" link="$1/outsourcerer"
  mkdir -p "$dstdir" 2>/dev/null || return 2
  if [ -e "$link" ] && [ ! -L "$link" ]; then return 3; fi   # real file/dir: never nest or clobber
  # A pre-existing SYMLINK (even one resolving to a directory) must be removed first: otherwise
  # `mv` follows it and nests the new link *inside* the target dir. Removing it keeps re-install
  # idempotent (a second run just refreshes the link) while still never clobbering a real dir/file
  # (guarded above by the `! -L` return 3).
  [ -L "$link" ] && rm -f "$link" 2>/dev/null
  local tmp="$dstdir/.outsourcerer.link.$$"
  # A crash can leave this temp name behind as a real directory.  Do not let
  # ln follow it and install a nested link as the final destination.
  [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || rm -rf "$tmp" 2>/dev/null || return 2
  ln -sfn "$src" "$tmp" 2>/dev/null || return 2
  mv -f "$tmp" "$link" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 2; }
  return 0
}

# reverse bridge INTO Hermes. Hermes (NousResearch) discovers SKILL.md-format skills from
# $HERMES_HOME/skills/*/SKILL.md -- the SAME format Claude/Devin/Antigravity use, NOT an AGENTS.md
# file. So the correct bridge is a SKILL SYMLINK (like the Devin/Antigravity mirror in parity()),
# not an AGENTS.md append (codex/droid/cursor). Once outsourcerer is a skill inside Hermes, a Hermes
# session can call outsourcerer.sh to delegate INTO Claude (run -m fable, verified), Codex, GLM, or
# any other lane -- closing the second direction so Hermes works BOTH ways.
parity_hermes() {
  have hermes || printf '>>> note: hermes CLI not on PATH yet; linking the skill anyway so it works the moment hermes is installed.\n' >&2
  # INSTALLER semantics, deliberately NOT _hermes_home(): honor $HERMES_HOME even when it does not
  # exist yet, because the whole point is to install into the user's CONFIGURED home before Hermes
  # has created it. _hermes_home() is a READER (it falls back to ~/.hermes for an absent dir so cost
  # lookups read where data actually is); using it here would install into the wrong place. They
  # converge the moment Hermes runs once. Do not "unify" these — the difference is intentional.
  local hhome="${HERMES_HOME:-$HOME/.hermes}"
  local hdst="$hhome/skills"
  local self; self="$(_osrc_skill_root)" || die "parity-hermes: cannot locate the outsourcerer skill (no SKILL.md found in the running install, ~/.claude/skills, or the plugin cache). Install outsourcerer first, then re-run."
  _osrc_link_skill_into "$hdst" "$self"; local rc=$?
  case "$rc" in
    0) echo "parity-hermes: linked outsourcerer -> $hdst/outsourcerer"
       echo "  Hermes discovers SKILL.md skills there; a Hermes session can now delegate INTO Claude (run -m fable), Codex, or GLM via outsourcerer.sh -- both directions now covered." ;;
    3) die "parity-hermes: $hdst/outsourcerer already exists as a real file/directory (not a symlink). Refusing to nest a link inside it or clobber it. Remove or rename it, then re-run:  rm -rf '$hdst/outsourcerer' && $SCRIPT_PATH parity-hermes" ;;
    *) die "parity-hermes: could not create the symlink in $hdst (permission?). Manual: ln -sfn '$self' '$hdst/outsourcerer'" ;;
  esac
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
    ccor|codexor|ccnative|cxnative|gmnative|devin|droid|cursor|hermes|warp|claudex) return 0 ;;
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
  printf '>>> [outsourcerer] CLOUD DISCLOSURE: delegating to a CLOUD lane (%s / %s).\n' "$lane" "$model" >&2
  printf '>>>   destination : a third-party API over the network — repo content LEAVES this machine.\n' >&2
  printf '>>>   readable    : this working dir (%s) + any --with files you passed.\n' "$cwd" >&2
  # Some agent CLIs additionally pull "always-on" rule files from $HOME and prepend them to every
  # session. That is outside the working dir, so the line above would otherwise be a promise this gate
  # cannot keep. Naming it matters twice over: those files leave the machine, and because they are
  # INSTRUCTIONS they also steer the delegate on a task that never asked for them.
  _rule_files_note >&2
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
    _or_model_withdrawn "$cap" "$m" || true
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
# KEYLESS, PRIVATE ($0 cash + $0 plan, nothing leaves the machine). Driven by `codex exec`
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
  _tier_banner "local ($base)" "$model" "$ttier" "TEXT delegation | PRIVATE: on YOUR hardware, $(_lane_cost_disclosure local), nothing leaves your machine"
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
  _tier_banner "local-agentic/codex ($base)" "$model" "$ttier" "$posture | AGENTIC tool use | PRIVATE: on YOUR hardware, $(_lane_cost_disclosure local), nothing leaves your machine"
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
    [ -f "$shimf" ] || die "vendored shim not found at $shimf (build it first; the local-bridge plan documents how)."
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
  _tier_banner "local-agentic/shim ($aurl -> $base)" "$model" "$ttier" "AGENTIC via Claude Code | PRIVATE: on YOUR hardware, $(_lane_cost_disclosure local), nothing leaves your machine"
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
_or_model_withdrawn() {
  local capf="$1" mid="${2:-}" line slug
  [ -f "$capf" ] || return 1
  line="$(grep -aoiE 'this model is unavailable for free.{0,200}' "$capf" 2>/dev/null | head -1)"
  [ -n "$line" ] || return 1
  slug="$(printf '%s' "$line" | grep -aoE 'use this slug instead:[[:space:]]*[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+' | head -1 | sed -E 's/.*:[[:space:]]*//')"
  [ -n "$slug" ] || slug="${mid%:free}"
  printf '>>> [openrouter] %s is not being served on the free tier right now (OpenRouter answers 404 and names the paid slug as its replacement).\n' "${mid:-the requested :free model}" >&2
  [ -n "$slug" ] && printf '>>>   use instead : -m %s   (PAID -- confirm the price first: https://openrouter.ai/%s)\n' "$slug" "$slug" >&2
  printf '>>>   NOT transient: a withdrawn free variant is a permanent 404, so retrying the same id can never succeed.\n' >&2
  return 0
}

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
  local capdir="${OSRC_JOB_DIR:-$OSRC_HOME}"; _mkdir_private "$capdir" || true
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
    _or_model_withdrawn "$cap" "$m" || true
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

# =============================================================================
# RANKED-SHORTLIST FALLBACK (READ-ONLY one-shots only). On a TRANSPORT-class failure of a
# read-only (`auto` tier: run/explore) delegation (429/rate-limit, 5xx, connection error, watchdog
# timeout) the SAME task is retried on the next candidate from `advise --json`'s ordered shortlist
# — a different lane/model — bounded by OSRC_FALLBACK_MAX total dispatch attempts (default 3).
# A CONTENT failure (the model produced a real answer that failed, or refused) NEVER falls
# through: re-asking N lanes a question that was already answered burns the whole shortlist for
# nothing. MUTATING tiers (edit/research/yolo) never auto-retry AT ALL — a failed mutating run may
# already have half-applied its changes, and replaying it on another lane has no rollback. When in
# doubt, classify as content and stop. Disable entirely with OSRC_FALLBACK=0. Degrades to today's
# single-attempt path when jq / advise / the shortlist is unavailable. Transport failures are already non-learnable
# (_status_to_outcome maps them to blocked/abandoned), so a hop here never poisons a lane's
# quality history; each hop IS made visible via a stderr line + a `fallback` ledger row.
# =============================================================================

# _fallback_enabled -> 0 when the shortlist retry may run for this invocation. Reads $PROVIDER
# (dynamic scope at the route_delegate call site). Engine lanes (droid/cursor) own their model
# catalogs and claudex/local are policy/hardware lanes — our shortlist aliases don't map onto
# them, so they keep the single-attempt path.
_fallback_enabled() {
  [ "${OSRC_FALLBACK:-1}" = "1" ] || return 1
  have jq || return 1
  case "${PROVIDER:-devin}" in devin|cc|codex) return 0 ;; esac
  return 1
}

# _fallback_max_attempts -> sanitized TOTAL dispatch bound (attempts that actually run a model).
# Non-numeric -> 3; <1 -> 1 (single attempt, i.e. no fallback); hard ceiling 20. Never infinite:
# on top of this bound, every scanned candidate lands in the tried-list and the shortlist itself
# is finite (bounded by the alias table).
_fallback_max_attempts() {
  local n="${OSRC_FALLBACK_MAX:-3}"
  case "$n" in ''|*[!0-9]*) n=3 ;; esac
  [ "$n" -lt 1 ] && n=1
  [ "$n" -gt 20 ] && n=20
  printf '%s' "$n"
}

# _fallback_is_transport <capture-file> <rc> <tier> -> 0 only for a transport-class failure that is
# safe to retry on another lane. Deliberately narrower than "any infra smell":
#  - ONLY the read-only tier (`auto`) is ever retryable. A mutating run (edit/research/yolo) that
#    failed may already have partially mutated the tree, and no text classifier can prove it
#    didn't: a task's OWN legitimate output can carry transport-shaped strings (an assertion
#    quoting `HTTP/1.1 503`, a test log printing `(code 500)`, ECONNREFUSED inside a stack trace
#    under test, `operation timed out after ...` as the tested message). Re-running such a task on
#    another lane replays a possibly-half-applied mutation with no rollback — worse than any saved
#    hop. So mutating tiers hard-stop on ANY failure; the error is surfaced, the human decides.
#  - rc 130 is a user interrupt: the user stopped it, never auto-respend on their behalf.
#  - rc 124 is the watchdog's hard kill (no error text of its own) -> transport on the read-only tier.
#  - everything else defers to _is_transport_failure on the combined stdout+stderr capture (its
#    empty-output-is-NOT-transport default and line-anchored phrase discipline are the
#    when-in-doubt-stop posture this feature requires, so it is reused, not re-derived).
_fallback_is_transport() {
  local cap="$1" rc="$2" tier="$3"
  [ "$rc" -eq 0 ] 2>/dev/null && return 1
  [ "$rc" -eq 130 ] 2>/dev/null && return 1
  [ "$rc" -eq 143 ] 2>/dev/null && return 1   # SIGTERM: a supervisor stopped it; never auto-respend
  [ "$tier" = "auto" ] || return 1
  [ "$rc" -eq 124 ] 2>/dev/null && return 0
  _is_transport_failure "$(cat "$cap" 2>/dev/null)" "$rc"
}

# _fallback_lane_ready <lane-code> -> 0 if the lane can plausibly take a retry right now (CLI on
# PATH / key present / logged in). A skipped-unready lane does NOT consume a dispatch attempt —
# an uninstalled CLI costs nothing, and charging it against the bound would make the bound mean
# "N minus however many lanes you don't have". Unknown lane codes (incl. image lanes) -> not ready.
_fallback_lane_ready() {
  local k=""
  case "$1" in
    dv) have devin || return 1
        # Bounded login probe: delegate() hard-fails on a logged-out devin, which would end the
        # whole retry walk; screen it here instead. 5s cap so a wedged CLI can't stall the walk.
        _timeout 5 devin auth status 2>/dev/null | grep -qi "logged in" || return 1 ;;
    cx) have codex || return 1 ;;
    cc) have claude || return 1 ;;
    gm) if have agy; then return 0; fi
        have gemini || return 1
        k="$(_extract_kv_value GEMINI_API_KEY)"; [ -n "$k" ] || k="$(_extract_kv_value GOOGLE_API_KEY)"
        [ -n "$k" ] || return 1 ;;
    or) k="$(_extract_kv_value OPENROUTER_API_KEY)"; [ -n "$k" ] || return 1
        have claude || have codex || return 1 ;;
    *)  return 1 ;;
  esac
  return 0
}

# _fallback_shortlist <task> -> ordered "alias|model|lane" lines from advise's ranked shortlist
# (best first; shortlist[0] is the recommendation). Empty output on ANY failure — the caller
# treats that as "no fallback available" and keeps the single-attempt behavior. The benchmark
# file is pinned to an empty placeholder when absent so this path NEVER triggers a network
# benchmark refresh in the middle of handling a failure (which may itself be network trouble).
_fallback_shortlist() {
  have jq || return 0
  local bj="$OSRC_BENCH_JSON"
  if [ ! -f "$bj" ]; then
    bj="$OSRC_HOME/.bench.none.json"
    ( umask 077; : > "$bj" ) 2>/dev/null || return 0
  fi
  ( OSRC_BENCH_JSON="$bj" cmd_advise --json "$1" 2>/dev/null ) \
    | jq -r '.shortlist[]? | [.alias, .model, .lane] | join("|")' 2>/dev/null
  return 0
}

# _fallback_disp_lane <disp> -> the lane code an attempt ACTUALLY ran on, from the dispatch vehicle.
# Used to record each attempt as a resolved "model@lane" pair so the dedupe below compares what
# really executed, not what an alias superficially looks like.
_fallback_disp_lane() {
  case "$1" in
    devin)         printf 'dv' ;;
    cxnative)      printf 'cx' ;;
    ccnative)      printf 'cc' ;;
    gmnative)      printf 'gm' ;;
    ccor|codexor)  printf 'or' ;;
    *)             printf '%s' "$1" ;;
  esac
}

_fallback_provider_for_lane() {
  case "$1" in dv) printf devin ;; cc|or) printf cc ;; cx) printf codex ;; gm) printf gemini ;; droid|cursor|hermes|warp) printf '%s' "$1" ;; *) return 1 ;; esac
}

# _fallback_effective <alias> <model> <lane> -> "model@lane" this candidate would ACTUALLY run as
# under the current provider. Mirrors route_delegate's availability-aware reroute: under the devin
# provider an OpenRouter alias with a Devin-lane sibling (glm, deepseek) is rerouted onto the
# Devin lane — so candidate `glm` is REALLY glm-5.2@dv, not z-ai/glm-5.2@or. Without this mapping
# the dedupe compares surface names and can re-dispatch the exact engine+model that just failed,
# burning a bounded attempt on a no-op hop.
_fallback_effective() {
  local alias="$1" model="$2" lane="$3" dvm
  if [ "$lane" = "or" ] && [ "${PROVIDER:-devin}" = "devin" ]; then
    dvm="$(_devin_model_for "$alias")"
    [ -n "$dvm" ] && { printf '%s@dv' "$dvm"; return 0; }
  fi
  printf '%s@%s' "$model" "$lane"
  return 0
}

# _fallback_pick <tried-list> <candidate-lines> -> echoes the first "alias|model|lane" whose alias,
# model id AND effective post-reroute model@lane pair are all untried and whose lane is ready;
# echoes nothing when the list is exhausted. The tried-list carries plain names AND "model@lane"
# pairs (pairs can't collide with names: model ids never contain '@').
_fallback_pick() {
  local tried=" $1 " alias model lane eff
  [ -n "${2:-}" ] || return 0
  while IFS='|' read -r alias model lane; do
    [ -n "$alias" ] || continue
    case "$tried" in *" $alias "*) continue ;; esac
    case "$tried" in *" $model "*) continue ;; esac
    eff="$(_fallback_effective "$alias" "$model" "$lane")"
    case "$tried" in *" $eff "*) continue ;; esac
    _fallback_lane_ready "$lane" || continue
    printf '%s|%s|%s' "$alias" "$model" "$lane"
    return 0
  done <<OSRC_FB_EOF
$2
OSRC_FB_EOF
  return 0
}

# _fallback_dispatch <tier> <capture-file> -> run the guarded dispatch while MIRRORING both output
# streams into <capture-file> for failure classification. stdout stays stdout, stderr stays stderr
# (live, streamed), so callers that capture stdout as the result see exactly what they see today.
# The exit code lands in $_OSRC_FB_RC via a file: a pipeline would eat it, and PIPESTATUS cannot
# cross the nested groups. No process substitution (no tee flush race), no flock; bash 3.2 safe.
# fd map: dispatch stderr -> inner tee -> real stderr; dispatch stdout -> fd3 -> outer tee -> real
# stdout; both tees append to the same capture (O_APPEND, grep-only consumer).
# SIGNALS: the pipeline is run as a BACKGROUND job under `wait` so this (main) shell can own an
# INT/TERM trap for the window. A foreground pipeline would leave the main shell trap-less: a TERM
# to the script pid (what `timeout` and supervisors send) killed the shell, ORPHANED the delegate
# subtree, and leaked the capture files; a pid-only INT was simply dropped. With the trap, wait
# returns on the signal, the trap kills the whole dispatch tree, the caps are removed, and the rc
# comes back as 130/143 — which the retry logic never treats as transport, so a signal always
# stops the walk. (The trap is restored to default after the window; the plain un-captured path
# is unchanged — its signal handling lives inside _fg_guard as before.)
_OSRC_FB_RC=0
_OSRC_FB_SIG=0
_fallback_dispatch() {
  local tier="$1" cap="$2" rcf="$2.rc"
  ( umask 077; : > "$cap"; : > "$rcf" ) 2>/dev/null || true
  _OSRC_FB_SIG=0; _OSRC_FB_JOB=""
  # Traps go in BEFORE the job is launched (no window where a signal can slip past), so they read
  # the job pid from a global at FIRE time rather than baking it in at set time.
  trap '_OSRC_FB_SIG=130; [ -n "${_OSRC_FB_JOB:-}" ] && _kill_tree "$_OSRC_FB_JOB" 2>/dev/null' INT
  trap '_OSRC_FB_SIG=143; [ -n "${_OSRC_FB_JOB:-}" ] && _kill_tree "$_OSRC_FB_JOB" 2>/dev/null' TERM
  { { { _fg_guard __osrc_fg_dispatch "$tier" 2>&1 1>&3
        printf '%s' "$?" > "$rcf"
      } | tee -a "$cap" >&2
    } 3>&1 | tee -a "$cap"
  } &
  _OSRC_FB_JOB=$!
  # A signal that landed between trap-set and pid-assignment couldn't kill anything yet: mop up.
  [ "${_OSRC_FB_SIG:-0}" != "0" ] && _kill_tree "$_OSRC_FB_JOB" 2>/dev/null
  wait "$_OSRC_FB_JOB" 2>/dev/null   # returns >128 immediately on a trapped signal, then the trap runs
  # If the trap interrupted the wait without managing a kill, kill now, then reap.
  [ "${_OSRC_FB_SIG:-0}" != "0" ] && _kill_tree "$_OSRC_FB_JOB" 2>/dev/null
  wait "$_OSRC_FB_JOB" 2>/dev/null   # reap after a signal (no-op on the normal path)
  trap - INT TERM
  _OSRC_FB_JOB=""
  if [ "${_OSRC_FB_SIG:-0}" != "0" ]; then
    rm -f "$cap" "$rcf" 2>/dev/null
    _OSRC_FB_RC="$_OSRC_FB_SIG"
    return 0
  fi
  _OSRC_FB_RC="$(cat "$rcf" 2>/dev/null)"
  case "$_OSRC_FB_RC" in ''|*[!0-9]*) _OSRC_FB_RC=1 ;; esac
  rm -f "$rcf" 2>/dev/null
  return 0
}

# Route facts are established once after provider/model resolution and before any side effect.
_route_resolution() {   # <dispatch-lane> <model>
  local lane="$1" model="$2"
  [ -n "$lane" ] && [ -n "$model" ] || die "route resolution is incomplete; refusing to choose a provider"
  ROUTE_LANE="$lane"; ROUTE_MODEL="$model"
  ROUTE_PROVIDER_EXPLICIT="${PROVIDER_EXPLICIT:-0}"
  ROUTE_MODEL_EXPLICIT="${MODEL_EXPLICIT:-0}"
  ROUTE_INTERACTION="cloud"
  ROUTE_EVIDENCE="provider=$PROVIDER model=$MODEL"
  ROUTE_FALLBACK_ORDER="$lane"
  case "$lane" in
    local) ROUTE_COST_CLASS=local; ROUTE_INTERACTION=local ;;
    ccnative|cxnative|gmnative|devin|droid|cursor|hermes|warp) ROUTE_COST_CLASS=limited ;;
    ccor|codexor|claudex) ROUTE_COST_CLASS=credits ;;
    *) die "route resolution is ambiguous for lane '$lane'; refusing to launch" ;;
  esac
}

_route_requires_confirmation() {
  # Internal continuations of an already-authorized dispatch never re-confirm: the preflight
  # dry-run, the detached job child, and any nested delegation inherit the top-level decision.
  [ "${OSRC_PREFLIGHT:-0}" = "1" ] && return 1
  [ "${OSRC_STREAM:-0}" = "1" ] && return 1
  [ "${_ROUTE_ENTRY_DEPTH:-${OUTSOURCERER_DEPTH:-0}}" != "0" ] && return 1
  # Naming a provider OR a model is itself an explicit lane choice — only a pure default confirms.
  [ "${ROUTE_PROVIDER_EXPLICIT:-0}" = "1" ] && return 1
  [ "${ROUTE_MODEL_EXPLICIT:-0}" = "1" ] && return 1
  case "${ROUTE_COST_CLASS:-}" in limited|credits) return 0 ;; esac
  return 1
}

_route_confirm() {
  local cash plan selection ans
  case "$ROUTE_COST_CLASS" in
    local) cash='$0 cash'; plan='$0 plan limits' ;;
    credits) cash='may spend credits or cash'; plan='may spend a limited allocation' ;;
    limited) cash='$0 cash unless your lane bills separately'; plan='may spend subscription or plan limits' ;;
    *) die "route confirmation cannot classify this route; refusing to launch" ;;
  esac
  selection='(none)'
  [ "${ROUTE_PROVIDER_EXPLICIT:-0}" = "1" ] && selection="--provider $PROVIDER"
  printf '>>> [route] CONFIRM lane=%s model=%s cash=%s plan=%s explicit=%s\n' \
    "$ROUTE_LANE" "$ROUTE_MODEL" "$cash" "$plan" "$selection" >&2
  if ! [ -t 0 ] || ! [ -t 1 ]; then
    die "route confirmation required for an implicit provider in a noninteractive call; pass --provider <lane> (or set OSRC_PROVIDER) to select it explicitly. Nothing was launched."
  fi
  printf '>>> [route] Continue with this lane? [y/N] ' >&2
  IFS= read -r ans || die "route confirmation was not received; nothing was launched"
  case "$ans" in y|Y|yes|YES) ;; *) die "route confirmation declined; nothing was launched" ;; esac
}

_route_receipt() {
  [ "${ROUTE_PROVIDER_EXPLICIT:-0}" = "1" ] || return 0
  printf '>>> [route] RESOLVED lane=%s model=%s explicit=--provider %s\n' \
    "$ROUTE_LANE" "$ROUTE_MODEL" "$PROVIDER" >&2
}

_route_provider_default_model() { # Provider-specific route identity, never parser state.
  case "$1" in
    devin) printf '%s' "$DEFAULT_MODEL" ;;
    gemini|gm) printf 'gemini-3.1-flash-lite' ;;
    local) printf 'local' ;;
    cc|codex) printf 'z-ai/glm-5.2' ;;
    claudex) printf 'gpt-5.6-sol' ;;
    droid|cursor|hermes|warp) printf '%s-default' "$1" ;;
    *) return 1 ;;
  esac
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
  # Normalize the depth BEFORE comparing (see _osrc_normalize_depth). The old `: "${...:=0}"`
  # only filled unset/empty; a malformed value ('bogus', '1x', '-1', ' ') slipped through and
  # `[ "$bad" -ge 1 ]` errored with "integer expression expected", returning false -> fail-open,
  # so a delegate could escape the guard by poisoning its own OUTSOURCERER_DEPTH. This is the
  # detached-child path: the same fail-open lived here too. An unparseable depth is treated as
  # AT the limit and refused, because an unparseable depth tells us only that it cannot be
  # trusted, and a delegate controls its own environment.
  local _depth_raw="${OUTSOURCERER_DEPTH:-}"
  if ! _osrc_normalize_depth; then
    die "recursion guard: OUTSOURCERER_DEPTH is unparseable ('$_depth_raw'). An unparseable depth cannot be trusted (a delegate controls its own environment), so the guard refuses rather than fail-open. Set OUTSOURCERER_DEPTH to a non-negative integer or unset it."
  fi
  # Confirmation authorizes this invocation, not the incremented child depth.
  local _ROUTE_ENTRY_DEPTH="$OUTSOURCERER_DEPTH"
  # Normalize the MAXIMUM too, and fail closed on a malformed one. Comparing against the raw
  # maximum let a delegate escape the guard by poisoning OUTSOURCERER_MAX_DEPTH (a non-integer
  # makes `[ n -ge bogus ]` error and return false -> fail-open). Same reasoning as the depth.
  local _max_raw="${OUTSOURCERER_MAX_DEPTH:-}" _max
  if ! _max="$(_osrc_normalize_max_depth)"; then
    die "recursion guard: OUTSOURCERER_MAX_DEPTH is unparseable ('$_max_raw'). A malformed maximum must not let a delegate slip past the guard, so it refuses rather than fail-open. Set OUTSOURCERER_MAX_DEPTH to a non-negative integer or unset it."
  fi
  if [ "$OUTSOURCERER_DEPTH" -ge "$_max" ]; then
    die "recursion guard: already delegating (OUTSOURCERER_DEPTH=$OUTSOURCERER_DEPTH >= OUTSOURCERER_MAX_DEPTH=$_max). A delegate must not re-delegate. Override with OUTSOURCERER_MAX_DEPTH=N."
  fi
  export OUTSOURCERER_DEPTH=$((OUTSOURCERER_DEPTH + 1))

  # Shortlist-fallback state. ARGV is the working argv: attempt 1 is the caller's argv verbatim;
  # a transport-failure retry rewrites it to pin the next shortlist candidate and loops back
  # through the FULL resolution body, so every compatibility rule / gate applies to retries too.
  local ARGV=("$@")
  # Did the CALLER pin an exact model with -m/--model? Captured ONCE on the original argv, before the
  # loop, because a fallback hop re-pins each candidate with -m (setting MODEL_EXPLICIT=1) — gating on
  # MODEL_EXPLICIT itself would kill multi-hop after the first. A pinned model is a deliberate choice
  # (quality/cost), so a transport failure surfaces and stops rather than silently running a DIFFERENT
  # model; opt into cross-model resilience for a pinned run with OSRC_FALLBACK_PINNED=1.
  # Scan LEADING flag positions only (mirroring _consume_flags): stop at the first token that is
  # neither a known flag nor a flag value, so a task whose TEXT contains a bare "-m" word can
  # never read as a pin and silently disable the fallback.
  local _fb_user_pinned=0 _fbp _fb_skipval=0
  for _fbp in ${ARGV[@]+"${ARGV[@]}"}; do
    if [ "$_fb_skipval" = "1" ]; then _fb_skipval=0; continue; fi
    case "$_fbp" in
      -m|--model) _fb_user_pinned=1; break ;;
      --tier|--with|--effort|--reasoning|--provider|--trust-lane) _fb_skipval=1 ;;
      --allow-downgrade|--cloud-ack|--wait|--foreground) : ;;
      *) break ;;
    esac
  done
  local _fb_tried="" _fb_used=1 _fb_cands="" _fb_loaded=0 _fb_max
  _fb_max="$(_fallback_max_attempts)"
  while :; do

  # Preserve original argv for the devin lane (kept byte-identical: it re-parses via parse_model).
  local ORIG=(${ARGV[@]+"${ARGV[@]}"})
  _consume_flags ${ARGV[@]+"${ARGV[@]}"}   # sets MODEL / MODEL_EXPLICIT / TIER_FLAG / WITH_SPEC / REST (+ OSRC_TIER_OVERRIDE)
  # Parsers preserve absence as empty. Resolve a route identity here, after the
  # provider is known, so a Devin default never leaks into Gemini or local.
  if [ "$MODEL_EXPLICIT" != "1" ]; then
    MODEL="$(_route_provider_default_model "$PROVIDER")" || die "unknown provider '$PROVIDER'"
  fi

  # LOCAL lane short-circuit: a model prefixed ollama:/lmstudio:/lms:/local[:...], or --provider local.
  # Local models aren't in the alias table (they're whatever the user has pulled), so route them here.
  case "$PROVIDER:$MODEL" in
    local:*|*:ollama:*|*:lmstudio:*|*:lms:*|*:local|*:local:*)
      _route_resolution local "$MODEL"
      _route_requires_confirmation && _route_confirm
      _route_receipt
      [ "${OSRC_PREFLIGHT:-0}" = "1" ] && return 0
      delegate_local "$tier"; return $? ;;
  esac

  RESOLVED_ID="$MODEL"; RESOLVED_LANE=""; TTIER=""
  # DROID/CURSOR/HERMES engine lanes skip alias resolution entirely: the engine owns its model catalog
  # (incl. user-configured/BYOK models), so `-m glm` under --provider droid means DROID's "glm",
  # never our alias table's z-ai/glm-5.2. The skill adapts to the user's tools, not the reverse.
  if [ "$MODEL_EXPLICIT" = "1" ] && [ "$PROVIDER" != "droid" ] && [ "$PROVIDER" != "cursor" ] && [ "$PROVIDER" != "hermes" ] && [ "$PROVIDER" != "warp" ]; then
    local row rest2
    row="$(resolve_model_row "$MODEL")"
    if [ -n "$row" ]; then
      RESOLVED_ID="${row%%|*}"; rest2="${row#*|}"; RESOLVED_LANE="${rest2%%|*}"; TTIER="${rest2#*|}"
    else
      # No exact table row, but the id may NAME a native family (a pinned Claude id like
      # claude-opus-4-8[1m], a not-yet-tabled gpt-5.*/gemini-* variant). Infer its OWN native lane so
      # it can't silently fall through to the default provider (devin) and burn the wrong engine's
      # limits — THE "-m claude-opus-4-8 ran on Devin" fix. Only NATIVE families (cc/cx/gm) infer;
      # everything else still routes by provider below.
      # NOTE: inference MUST run under --provider claudex too. The claudex branch's Claude-subscription
      # REFUSAL keys on RESOLVED_LANE==cc, which resolve_model_row only sets for TABLED ids; without
      # inference here an un-tabled Claude id (e.g. claude-opus-4-8[1m], claude-sonnet-6) would leave
      # RESOLVED_LANE empty, skip the refusal, and route a Claude-sub model through the third-party
      # CLIProxyAPI — exactly what the refusal exists to block. A GPT id infers cx and still proceeds
      # (the claudex branch only refuses cc), so claudex's intended GPT-via-proxy use is unaffected.
      local _infl
      if _infl="$(lane_from_name "$MODEL")"; then
        RESOLVED_LANE="$_infl"; RESOLVED_ID="$MODEL"
        printf '>>> [route] -m %s has no table alias; inferred its native lane (%s) from the model family, NOT the devin default. Force a lane with --provider if this is wrong.\n' "$MODEL" "$_infl" >&2
      fi
    fi
  fi

  local disp="" _or_autoroute_note="" _or_credit_state=""
  if [ "$PROVIDER" = "droid" ] || [ "$PROVIDER" = "cursor" ] || [ "$PROVIDER" = "hermes" ] || [ "$PROVIDER" = "warp" ]; then
    disp="$PROVIDER"
    # Fail FAST on a missing engine CLI -- before the cloud gate and before auto-detach would
    # otherwise bury this error inside a background job the user has to go dig out.
    case "$disp" in
      droid)  have droid || die "droid CLI not on PATH (Factory Droid lane). Install: https://docs.factory.ai/cli  (macOS/Linux: curl -fsSL https://app.factory.ai/cli -o droid-install.sh, inspect, run; Windows: native PowerShell installer). Then run 'droid' once to log in." ;;
      cursor) have cursor-agent || have agent || die "cursor-agent CLI not on PATH (Cursor lane). Install: macOS/Linux: curl https://cursor.com/install -fsS | bash after inspecting; Windows (native, no WSL): irm 'https://cursor.com/install?win32=true' | iex. Then 'cursor-agent login' once (or set CURSOR_API_KEY)." ;;
      hermes) have hermes || die "hermes CLI not on PATH (Hermes agent lane). Install: https://github.com/NousResearch/hermes-agent  (then run 'hermes' once to configure). -m passes through verbatim; model catalog is yours to configure." ;;
      warp)   have oz || die "oz CLI not on PATH (Warp lane). It ships INSIDE Warp.app at Contents/Resources/bin/oz — symlink it: ln -s '/Applications/Warp.app/Contents/Resources/bin/oz' ~/.local/bin/oz  (then 'oz login' once). -m passes through verbatim to 'oz model list'; use --harness via OSRC_WARP_HARNESS=claude|codex to host that harness instead of the default Oz one." ;;
    esac
    # The engine CLI presence is the dispatchability gate for these lanes: the check above fails
    # fast (before the cloud gate and before auto-detach would mint a job), so a missing CLI never
    # becomes a phantom job that surfaces the failure inside a detached child the caller never reads.
    # With the CLI present, hermes dispatches for real via `hermes -z` in delegate_hermes.
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
                    # Devin ALSO serves -> use the Devin lane instead of dying/forcing OpenRouter.
                    # This is deterministic (keyed on _devin_model_for, not a live guess) and matches
                    # the documented default: `glm`/`deepseek` are dual-lane and ride Devin by default.
                    # It fixes `-m glm` hard-failing when the OpenRouter key is out of monthly quota.
                    local _dvm; _dvm="$(_devin_model_for "$MODEL")"
                    if [ -n "$_dvm" ]; then
                      printf '>>> [route] -m %s is served by BOTH OpenRouter and Devin; using the Devin lane (%s) on the default provider. Force OpenRouter with --provider cc|codex.\n' "$MODEL" "$_dvm" >&2
                      # Rewrite the model token in ORIG so the Devin lane runs the Devin id, not the OR alias.
                      local _i; for _i in "${!ORIG[@]}"; do
                        case "${ORIG[$_i]}" in -m|--model) [ $((_i+1)) -lt ${#ORIG[@]} ] && ORIG[$((_i+1))]="$_dvm" ;; esac
                      done
                      RESOLVED_ID="$_dvm"; disp=devin
                    else
                      # AUTO-ROUTE: an OpenRouter-only model the active provider cannot serve should
                      # FOLLOW its lane automatically -- the SKILL promise is "the alias picks the lane;
                      # no --provider needed." Route to the cc transport (Claude Code -> OpenRouter) and say so.
                      _or_autoroute_note="-m $MODEL is an OpenRouter-only model; active provider ($PROVIDER) cannot serve it"
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
      gemini|gm) disp=gmnative ;;
      *)     die "unknown provider '$PROVIDER' (use: devin|cc|codex|droid|cursor|hermes|warp|claudex|local)" ;;
    esac
  fi

  _route_resolution "$disp" "$RESOLVED_ID"
  _route_requires_confirmation && _route_confirm
  _route_receipt

  # A live zero balance is conclusive: stop before preflight or dispatch rather than announcing a
  # route which can only fail with 402. Unknown balances remain best-effort and preserve existing
  # behavior, but a numeric zero never becomes a phantom detached job.
  case "$disp" in
    ccor|codexor)
      _or_credit_state="$(or_credits 2>/dev/null)"
      local _or_remaining="${_or_credit_state##*remaining=}"; _or_remaining="${_or_remaining%% *}"
      if awk -v n="$_or_remaining" 'BEGIN { exit !(n ~ /^[0-9]+([.][0-9]+)?$/ && n <= 0) }' 2>/dev/null; then
        die "OpenRouter reports zero remaining credits; refusing to route this run. Use a subscription/local lane or restore OpenRouter credit first."
      fi
      [ -n "$_or_autoroute_note" ] && printf '>>> [route] %s — auto-routing to the OpenRouter lane (--provider cc; credit state: %s). Force codex with --provider codex.\n' "$_or_autoroute_note" "${_or_credit_state:-unavailable}" >&2
      ;;
  esac

  # Devin's swe-1.7 is usable for read-only runs but has repeatedly failed write-enabled verbs.
  # Keep an explicit user choice intact, while making the limitation impossible to miss before a
  # mutating dispatch. A write-capable model/lane should be preferred for this work.
  if [ "$disp" = "devin" ] && [ "$RESOLVED_ID" = "swe-1.7" ]; then
    case "$verb" in
      edit|yolo|research)
        printf '>>> [route] WARNING: Devin swe-1.7 is not reliable for %s (write-enabled) jobs. Prefer a write-capable lane/model before dispatch; continuing only because this route was selected explicitly.\n' "$verb" >&2
        ;;
    esac
  fi

  # PREFLIGHT EXIT. Lane resolution is complete and every incompatibility above has either died or
  # auto-routed, but nothing has been dispatched yet. `bg` re-enters here with OSRC_PREFLIGHT=1 purely
  # to find out whether this invocation is routable, so an unroutable one dies in the PARENT instead of
  # minting a job dir, printing an id, and failing later inside a detached child that nobody reads.
  # Reusing this code path rather than re-implementing the rules is deliberate: a second copy of the
  # compatibility table would drift from this one, and then the preflight would bless what the real run
  # rejects.
  [ "${OSRC_PREFLIGHT:-0}" = "1" ] && return 0

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
    # route_delegate already incremented OUTSOURCERER_DEPTH above. The auto-detached __runjob
    # child re-enters route_delegate, which would see the already-incremented depth and trip the
    # recursion guard (the guard is a backstop, not a reason to block a legitimate auto-detach).
    # Decrement back to the pre-increment value: the bg job IS the delegation this route_delegate
    # was going to perform, so the child should start at the same depth the parent entered with,
    # and route_delegate in the child increments it again. Without this, every non-interactive
    # slow-lane run would die at the guard inside the detached child.
    export OUTSOURCERER_DEPTH=$((OUTSOURCERER_DEPTH - 1))
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
      hermes)   delegate_hermes   "$tier" ;;
      warp)     delegate_warp     "$tier" ;;
      claudex)  delegate_claudex  "$tier" ;;
    esac
  }

  # Fallback disabled/unavailable, or a MUTATING tier -> the original un-captured dispatch,
  # byte-identical to before. Mutating tiers (anything but `auto`) never auto-retry: a failed
  # mutating run may already have half-applied its changes, and replaying it on another lane has
  # no rollback (see _fallback_is_transport, which enforces the same invariant as a second layer).
  if ! _fallback_enabled || [ "$tier" != "auto" ] \
     || { [ "$_fb_user_pinned" = "1" ] && [ "${OSRC_FALLBACK_PINNED:-0}" != "1" ]; }; then
    _fg_guard __osrc_fg_dispatch "$tier"
    return $?
  fi

  local _fb_cap="$OSRC_HOME/.fbcap.$$" _fb_rc
  _fallback_dispatch "$tier" "$_fb_cap"
  _fb_rc="$_OSRC_FB_RC"
  if [ "$_fb_rc" -eq 0 ]; then rm -f "$_fb_cap" 2>/dev/null; return 0; fi
  if ! _fallback_is_transport "$_fb_cap" "$_fb_rc" "$tier"; then
    # CONTENT/task failure: the model gave a real (failing/refusing) answer. Surfacing it is the
    # job; retrying other lanes would re-ask an answered question N times. Stop here.
    rm -f "$_fb_cap" 2>/dev/null
    return "$_fb_rc"
  fi
  rm -f "$_fb_cap" 2>/dev/null

  # Transport-class failure: the task never got a real answer on this lane. Walk the shortlist.
  # Record the attempt three ways: alias-as-typed, resolved id, and the resolved model@lane pair —
  # the pair is what stops a later candidate from rerouting back onto this exact engine+model.
  _fb_tried="$_fb_tried $MODEL $RESOLVED_ID ${RESOLVED_ID}@$(_fallback_disp_lane "${disp:-?}")"
  if [ "$_fb_used" -ge "$_fb_max" ]; then
    printf '>>> [fallback] transport failure on %s (rc=%s) and the attempt budget (%s) is spent — stopping. Raise OSRC_FALLBACK_MAX to allow more candidates.\n' "$RESOLVED_ID" "$_fb_rc" "$_fb_max" >&2
    return "$_fb_rc"
  fi
  if [ "$_fb_loaded" -eq 0 ]; then
    _fb_loaded=1
    _fb_cands="$(_fallback_shortlist "${REST[*]}")"
  fi
  local _fb_next; _fb_next="$(_fallback_pick "$_fb_tried" "$_fb_cands")"
  if [ -z "$_fb_next" ]; then
    printf '>>> [fallback] transport failure on %s (rc=%s) and no untried READY candidate remains on the shortlist — stopping.\n' "$RESOLVED_ID" "$_fb_rc" >&2
    return "$_fb_rc"
  fi
  local _fb_alias="${_fb_next%%|*}" _fb_mid _fb_lane _fb_restpart
  _fb_restpart="${_fb_next#*|}"; _fb_mid="${_fb_restpart%%|*}"; _fb_lane="${_fb_restpart##*|}"
  _fb_used=$((_fb_used + 1))
  printf '>>> [fallback] transport failure on %s (lane %s, rc=%s) -> retrying the SAME task on %s (lane %s), attempt %s/%s. Transport failures never count against a model'\''s quality history.\n' \
    "$RESOLVED_ID" "${disp:-?}" "$_fb_rc" "$_fb_alias" "$_fb_lane" "$_fb_used" "$_fb_max" >&2
  # Visibility row in the Tab: verb=fallback, cost 0 (this row is bookkeeping, not a spend; the
  # retry's own run records its real cost). Ledger rows are usage events — learning reads only
  # outcome rows, so this cannot touch quality history. Forced so bg (stream-mode) children log it.
  OSRC_LEDGER_FORCE=1 record_ledger "${disp:-?}" "$RESOLVED_ID->$_fb_alias" "" "fallback" "${REST[*]}" "0.000000" "" 2>/dev/null || true
  # Rebuild argv: pin the candidate (a known alias routes to its native lane via the table), keep
  # the caller's tier/effort/with/downgrade flags, drop any original -m/--provider. One-shot env
  # flags already consumed into process state (--cloud-ack, --trust-lane, --wait) carry over as-is.
  local _fb_provider; _fb_provider="$(_fallback_provider_for_lane "$_fb_lane")" || return "$_fb_rc"
  # A fallback is a new resolved route. Rebuild provider and provenance together,
  # never carry an old explicit provider label onto another lane.
  local _fb_new=(--provider "$_fb_provider" -m "$_fb_alias") _fb_w
  [ -n "${TIER_FLAG:-}" ] && _fb_new+=(--tier "$TIER_FLAG")
  [ -n "${EFFORT:-}" ] && _fb_new+=(--effort "$EFFORT")
  [ "${OSRC_ALLOW_DOWNGRADE:-0}" = "1" ] && _fb_new+=(--allow-downgrade)
  for _fb_w in ${WITH_SPEC:-}; do _fb_new+=(--with "$_fb_w"); done
  _fb_new+=(${REST[@]+"${REST[@]}"})
  ARGV=("${_fb_new[@]}")

  done   # while :; (shortlist-fallback retry loop)
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

_managed_session_send() { # <session-id> <message>
  local session_id="$1" message="$2" pane="$1" oid key composer receipt generation latest
  _managed_endpoint_live "$session_id" "$pane" || return 1
  oid="send.$session_id.$(printf '%s' "$message" | cksum | awk '{print $1}')"
  latest="$(_obligation_latest_state "$oid")"
  [ "$latest" != typing_started ] || { _obligation_delivery_unknown "$oid" "$session_id"; return 1; }
  _obligation_admit "$oid" "$session_id" || return 1
  _endpoint_mutation_lock "$pane" || return 1
  key="$(printf '%s' "$pane" | cksum | awk '{print $1}')"
  _managed_endpoint_live "$session_id" "$pane" || { _endpoint_mutation_unlock "$key"; return 1; }
  _tmux_reset_input "$pane"
  _obligation_append "$oid" "$session_id" typing_started "" || { _endpoint_mutation_unlock "$key"; return 1; }
  _obligation_guard_begin "$oid" "$session_id"
  composer="$(_external_composer_state "$pane" 2>/dev/null)"
  [ "$composer" = empty ] || { _obligation_delivery_unknown "$oid" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1; }
  tmux send-keys -t "$pane" -l -- "$message" || { _obligation_delivery_unknown "$oid" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1; }
  tmux send-keys -t "$pane" Enter || { _obligation_delivery_unknown "$oid" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1; }
  generation="$(_state_jsonl_read "$OSRC_SESSION_REGISTRY" 2>/dev/null | jq -r --arg id "$session_id" 'select(.event=="start" and .session_id==$id) | .model_generation // empty' | tail -1)"
  receipt="$(_external_receipt_verify "$pane" "$oid" 2>/dev/null)"
  if _external_receipt_valid "$receipt" "$pane" "$oid" "$generation"; then
    _obligation_append "$oid" "$session_id" submitted "$receipt" || { _obligation_delivery_unknown "$oid" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1; }
    _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 0
  fi
  _obligation_delivery_unknown "$oid" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1
}

_managed_session_clear() { # <session-id>
  local session_id="$1" pane="$1" key
  _managed_endpoint_live "$session_id" "$pane" || return 1
  _endpoint_mutation_lock "$pane" || return 1
  key="$(printf '%s' "$pane" | cksum | awk '{print $1}')"
  _managed_endpoint_live "$session_id" "$pane" || { _endpoint_mutation_unlock "$key"; return 1; }
  _tmux_reset_input "$pane" aggressive
  _endpoint_mutation_unlock "$key"
}

_managed_session_model() { # <session-id> [filter]
  local session_id="$1" filter="${2:-}" pane="$1" key
  _managed_endpoint_live "$session_id" "$pane" || return 1
  _endpoint_mutation_lock "$pane" || return 1
  key="$(printf '%s' "$pane" | cksum | awk '{print $1}')"
  _managed_endpoint_live "$session_id" "$pane" || { _endpoint_mutation_unlock "$key"; return 1; }
  tmux send-keys -t "$pane" Escape || { _endpoint_mutation_unlock "$key"; return 1; }
  sleep 1
  tmux send-keys -t "$pane" M-m || { _endpoint_mutation_unlock "$key"; return 1; }
  sleep 1
  if [ -n "$filter" ]; then
    filter="$(printf '%s' "$filter" | tr -cd '[:alnum:][:space:]._:/-')"
    tmux send-keys -t "$pane" -l -- "$filter" || { _endpoint_mutation_unlock "$key"; return 1; }
    sleep 1
  fi
  tmux send-keys -t "$pane" Enter || { _endpoint_mutation_unlock "$key"; return 1; }
  _endpoint_mutation_unlock "$key"
}

# Validate session name before any path construction, tmux, or rm use.
# Reject empty, '.', '..', and any name containing a character outside [A-Za-z0-9._-].
_validate_session_name() {
  case "$SESSION_NAME" in
    ''|.|..|*[!A-Za-z0-9._-]*)
      die "invalid session name '$SESSION_NAME' (OUTSOURCERER_TMUX must be non-empty, not '.' or '..', and match ^[A-Za-z0-9._-]+$)"
      ;;
  esac
}

SESSION_LAUNCH=()

_session_launch_error() {
  local provider="$1" reason="$2"
  die "session start: $provider interactive launch unavailable ($reason). Use '$0 --provider $provider run \"task\"' for one-shot work or '$0 --provider $provider bg run \"task\"' for supervised background work."
}

_session_probe_help() {
  local probe_file rc=0
  probe_file="$(mktemp "${TMPDIR:-/tmp}/osrc-session-probe.XXXXXX" 2>/dev/null)" || return 1
  _timeout 3 "$@" > "$probe_file" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$probe_file" ]; then
    rm -f "$probe_file"
    [ "$rc" -ne 0 ] && return "$rc"
    return 1
  fi
  cat "$probe_file"
  rm -f "$probe_file"
}

_session_launch_adapter() {
  local provider="${1:-$PROVIDER}" help_text="" chat_help="" cli="" resolved_model="" de=""
  SESSION_LAUNCH=()

  case "$provider" in
    droid)
      have droid || _session_launch_error "$provider" "droid is not on PATH"
      help_text="$(_session_probe_help droid --help)" \
        || _session_launch_error "$provider" "the local help probe failed or timed out"
      printf '%s\n' "$help_text" | grep -Eqi 'interactive mode.*default|start.*interactive mode' \
        || _session_launch_error "$provider" "help does not advertise an interactive mode"
      printf '%s\n' "$help_text" | grep -Eqi 'exec.*non-interactive|exec.*noninteractively|exec.*scripts/automation' \
        || _session_launch_error "$provider" "help does not distinguish interactive mode from one-shot exec"
      printf '%s\n' "$help_text" | grep -Eqi -- '--auto.*low.*medium.*high' \
        || _session_launch_error "$provider" "help does not advertise bounded interactive autonomy"
      SESSION_LAUNCH=("droid" "--auto" "medium")
      if [ -n "$EFFORT" ]; then
        de="$(_droid_effort "$EFFORT")"; [ -n "$de" ] || _session_launch_error "$provider" "unsupported reasoning effort"
        SESSION_LAUNCH+=("-r" "$de")
      fi
      if [ "$MODEL_EXPLICIT" = "1" ]; then
        resolved_model="$(_lane_model_for droid "$MODEL")" || _session_launch_error "$provider" "cannot resolve model"
        if printf '%s\n' "$help_text" | grep -Eq -- '--model([ =]|$)'; then
          SESSION_LAUNCH+=("--model" "$resolved_model")
        elif printf '%s\n' "$help_text" | grep -Eq '(^|[[:space:],])-m([[:space:],]|$).*model'; then
          SESSION_LAUNCH+=("-m" "$resolved_model")
        else
          _session_launch_error "$provider" "help does not advertise an interactive model override"
        fi
      fi
      ;;
    cursor)
      if have cursor-agent; then
        cli="cursor-agent"
      elif have agent; then
        cli="agent"
      else
        _session_launch_error "$provider" "neither cursor-agent nor agent is on PATH"
      fi
      help_text="$(_session_probe_help "$cli" --help)" \
        || _session_launch_error "$provider" "the local help probe failed or timed out"
      if [ "$cli" = "agent" ]; then
        printf '%s\n' "$help_text" | grep -qi 'cursor' \
          || _session_launch_error "$provider" "the agent executable does not identify itself as Cursor"
      fi
      printf '%s\n' "$help_text" | grep -Eqi 'interactive (terminal|mode|session)|chat mode.*default|start.*chat mode' \
        || _session_launch_error "$provider" "help does not advertise an interactive chat mode"
      printf '%s\n' "$help_text" | grep -Eqi -- '--print.*non-interactive|-p.*non-interactive' \
        || _session_launch_error "$provider" "help does not distinguish interactive chat from one-shot print mode"
      SESSION_LAUNCH=("$cli")
      if [ "$MODEL_EXPLICIT" = "1" ]; then
        printf '%s\n' "$help_text" | grep -Eq -- '--model([ =]|$)' \
          || _session_launch_error "$provider" "help does not advertise an interactive model override"
        SESSION_LAUNCH+=("--model" "$MODEL")
      fi
      ;;
    hermes)
      have hermes || _session_launch_error "$provider" "hermes is not on PATH"
      help_text="$(_session_probe_help hermes --help)" \
        || _session_launch_error "$provider" "the local help probe failed or timed out"
      chat_help="$(_session_probe_help hermes chat --help)" \
        || _session_launch_error "$provider" "the local chat help probe failed or timed out"
      printf '%s\n%s\n' "$help_text" "$chat_help" | grep -Eqi 'REPL|interactive (chat|mode|session)|chat.*interactive' \
        || _session_launch_error "$provider" "help does not advertise an interactive REPL or chat"
      printf '%s\n%s\n' "$help_text" "$chat_help" | grep -Eqi 'one-shot|non-interactive' \
        || _session_launch_error "$provider" "help does not distinguish interactive chat from one-shot mode"
      printf '%s\n' "$help_text" | grep -Eqi '(^|[[:space:]])chat([[:space:]]|$)' \
        || _session_launch_error "$provider" "help does not advertise the chat command"
      SESSION_LAUNCH=("hermes" "chat")
      if [ "$MODEL_EXPLICIT" = "1" ]; then
        printf '%s\n' "$chat_help" | grep -Eq -- '--model([ =]|$)' \
          || _session_launch_error "$provider" "chat help does not advertise a model override"
        SESSION_LAUNCH+=("--model" "$MODEL")
      fi
      ;;
    *)
      _session_launch_error "$provider" "no capability adapter is defined"
      ;;
  esac
}

_session_shell_command() {
  local arg quoted out=""
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    [ -n "$out" ] && out="$out "
    out="$out$quoted"
  done
  printf '%s\n' "$out"
}

_session_effort_validate() {
  case "${1:-}" in
    minimal|low|medium|high|xhigh|max|none) return 0 ;;
    *) return 1 ;;
  esac
}

_session_resolved_model() { # <provider> <requested-model>
  local provider="$1" model="$2" row
  case "$provider" in
    codex|cx) row="$(resolve_model_row "$model")"; [ -n "$row" ] && { printf '%s\n' "${row%%|*}"; return; } ;;
  esac
  printf '%s\n' "$model"
}

_session_registry_append() { # <event> <provider> <model> <effort> <state> <receipt> [resolved-model] [generation]
  local event="$1" provider="$2" model="$3" effort="$4" state="$5" receipt="$6" resolved="${7:-}" generation="${8:-1}" now record pid="" pid_start=""
  have jq || return 1
  [ -n "$resolved" ] || resolved="$(_session_resolved_model "$provider" "$model")" || return 1
  case "$generation" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$event" = start ]; then
    pid="$(tmux display-message -p -t "$SESSION_NAME" '#{pane_pid}' 2>/dev/null)" || pid=""
    [ -n "$pid" ] && pid_start="$(_pid_start_identity "$pid" 2>/dev/null)" || pid_start=""
  fi
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  record="$(jq -cn --arg event "$event" --arg session_id "$SESSION_NAME" --arg provider "$provider" \
    --arg model "$model" --arg resolved_model "$resolved" --arg effort "$effort" --arg state "$state" --arg receipt "$receipt" --arg pid "$pid" --arg pid_start "$pid_start" --arg ts "$now" --argjson generation "$generation" \
    '{schema_version:"1",event:$event,session_id:$session_id,provider:$provider,model:$model,requested_model:$model,resolved_model:$resolved_model,model_generation:$generation,effort:$effort,state:$state,receipt:$receipt,endpoint:("tmux:" + $session_id),harness_pid:(if $pid=="" then null else $pid end),pid_start:(if $pid_start=="" then null else $pid_start end),owner:"managed",ts:$ts}')" || return 1
  _state_append "$OSRC_SESSION_REGISTRY" "$record"
}

# Live model observation is adapter-only. A missing, malformed, or unavailable adapter is not
# evidence of a match and must remain unknown.
_session_model_observer_run() { # <lane> <endpoint> <session-id>
  local lane="$1" endpoint="$2" session_id="$3" observed
  [ -n "${OSRC_SESSION_MODEL_OBSERVER:-}" ] && command -v "$OSRC_SESSION_MODEL_OBSERVER" >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  observed="$("$OSRC_SESSION_MODEL_OBSERVER" "$lane" "$endpoint" "$session_id" 2>/dev/null)" || { printf 'unknown\n'; return 0; }
  observed="$(printf '%s' "$observed" | head -1 | tr -d '[:space:]')"
  case "$observed" in ''|unknown|*[[:space:]]*|*'"'*|*"'"*|*'`'*|*'$'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*) printf 'unknown\n' ;; *) printf '%s\n' "$observed" ;; esac
}
_session_model_observe_devin() { _session_model_observer_run devin "$@"; }
_session_model_observe_codex() { _session_model_observer_run codex "$@"; }
_session_model_observe_cc() { _session_model_observer_run cc "$@"; }
_session_model_observe_droid() { _session_model_observer_run droid "$@"; }
_session_model_observe_cursor() { _session_model_observer_run cursor "$@"; }
_session_model_observe_hermes() { _session_model_observer_run hermes "$@"; }
_session_model_observe_gemini() { _session_model_observer_run gemini "$@"; }
_session_model_observe() { # <lane> <endpoint> <session-id>
  local lane="$1" endpoint="$2" session_id="$3"
  case "$lane" in devin|dv) _session_model_observe_devin "$endpoint" "$session_id" ;; codex|cx) _session_model_observe_codex "$endpoint" "$session_id" ;; cc|claude) _session_model_observe_cc "$endpoint" "$session_id" ;; droid) _session_model_observe_droid "$endpoint" "$session_id" ;; cursor) _session_model_observe_cursor "$endpoint" "$session_id" ;; hermes) _session_model_observe_hermes "$endpoint" "$session_id" ;; gemini|gm) _session_model_observe_gemini "$endpoint" "$session_id" ;; *) printf 'unknown\n' ;; esac
}
_session_model_matches() { # <requested> <resolved> <observed>
  local requested="$1" resolved="$2" observed="$3"
  [ -n "$observed" ] && [ "$observed" != unknown ] || return 1
  [ "$(printf '%s' "$observed" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$requested" | tr '[:upper:]' '[:lower:]')" ] && return 0
  [ "$(printf '%s' "$observed" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$resolved" | tr '[:upper:]' '[:lower:]')" ]
}
_session_model_receipt_devin() { _external_receipt_verify "$1" "$2"; }
_session_model_receipt() { # <lane> <pane> <restore-id>
  case "$1" in devin|dv) _session_model_receipt_devin "$2" "$3" ;; *) printf 'unknown\n' ;; esac
}
_session_model_restore_devin() { # <pane> <model>
  tmux send-keys -t "$1" M-m || return 1
  tmux send-keys -t "$1" -l -- "$2" || return 1
  tmux send-keys -t "$1" Enter
}
_managed_endpoint_live() { # <session-id> <pane>
  local session_id="$1" pane="$2" record pid start
  record="$(_state_jsonl_read "$OSRC_SESSION_REGISTRY" 2>/dev/null | jq -c --arg id "$session_id" 'select(.event=="start" and .session_id==$id and (.harness_pid|type)=="string" and (.pid_start|type)=="string")' | tail -1)" || return 1
  pid="$(printf '%s' "$record" | jq -r '.harness_pid // empty')"; start="$(printf '%s' "$record" | jq -r '.pid_start // empty')"
  [ -n "$pid" ] && [ -n "$start" ] && _claimed_endpoint_live "$pane" "$pid" "$start"
}

_session_model_restore() { # <lane> <endpoint> <requested> <restore-id> <session-id>
  local lane="$1" endpoint="$2" requested="$3" restore_id="$4" session_id="$5" pane composer receipt key latest generation
  [ "$OSRC_PLATFORM" != "windows" ] || return 1
  case "$endpoint" in tmux:*) pane="${endpoint#tmux:}" ;; *) return 1 ;; esac
  _managed_endpoint_live "$session_id" "$pane" || return 1
  latest="$(_obligation_latest_state "$restore_id")"; [ "$latest" != typing_started ] || { _obligation_delivery_unknown "$restore_id" "$session_id"; return 1; }
  _obligation_admit "$restore_id" "$session_id" || return 1
  _endpoint_mutation_lock "$pane" || return 1
  key="$(printf '%s' "$pane" | cksum | awk '{print $1}')"
  _managed_endpoint_live "$session_id" "$pane" || { _endpoint_mutation_unlock "$key"; return 1; }
  _obligation_append "$restore_id" "$session_id" typing_started "" || { _endpoint_mutation_unlock "$key"; return 1; }
  _obligation_guard_begin "$restore_id" "$session_id"
  composer="$(_external_composer_state "$pane" 2>/dev/null)"
  [ "$composer" = empty ] || { _obligation_delivery_unknown "$restore_id" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1; }
  case "$lane" in devin|dv) _session_model_restore_devin "$pane" "$requested" || { _obligation_delivery_unknown "$restore_id" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1; } ;; *) _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1 ;; esac
  receipt="$(_session_model_receipt "$lane" "$pane" "$restore_id" 2>/dev/null)"
  generation="$(_state_jsonl_read "$OSRC_SESSION_REGISTRY" 2>/dev/null | jq -r --arg id "$session_id" 'select(.event=="start" and .session_id==$id) | .model_generation // empty' | tail -1)"
  if _external_receipt_valid "$receipt" "$pane" "$restore_id" "$generation"; then
    _obligation_append "$restore_id" "$session_id" submitted "$receipt" || { _obligation_delivery_unknown "$restore_id" "$session_id"; _endpoint_mutation_unlock "$key"; return 1; }
    _obligation_guard_end
    _endpoint_mutation_unlock "$key"; return 0
  fi
  _obligation_delivery_unknown "$restore_id" "$session_id"; _obligation_guard_end; _endpoint_mutation_unlock "$key"; return 1
}

_model_pin_append() { # <session-id> <generation> <event> [detail]
  local session_id="$1" generation="$2" event="$3" detail="${4:-}" now epoch record
  case "$session_id:$generation:$event" in *[!A-Za-z0-9._:-]*) return 1 ;; esac
  epoch="$(date +%s)"; case "$epoch" in *[!0-9]*) return 1 ;; esac
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  record="$(jq -cn --arg session_id "$session_id" --arg generation "$generation" --arg event "$event" --arg detail "$detail" --arg ts "$now" --argjson epoch "$epoch" '{schema_version:"1",session_id:$session_id,generation:$generation,event:$event,detail:$detail,ts:$ts,epoch:$epoch}')" || return 1
  _state_append "$OSRC_MODEL_PIN_STATE" "$record"
}
_model_pin_restore_allowed() { # <session-id> <generation>
  local session_id="$1" generation="$2" max="${OSRC_MODEL_PIN_RESTORE_MAX:-1}" cooldown="${OSRC_MODEL_PIN_COOLDOWN:-300}" count last now
  case "$max:$cooldown" in *[!0-9:]*|'':*) return 1 ;; esac
  count="$(_state_jsonl_read "$OSRC_MODEL_PIN_STATE" 2>/dev/null | jq -r --arg id "$session_id" --arg gen "$generation" 'select(.session_id==$id and .generation==$gen and .event=="restore-attempt") | 1' | wc -l | tr -d ' ')"
  [ "${count:-0}" -lt "$max" ] || return 1
  last="$(_state_jsonl_read "$OSRC_MODEL_PIN_STATE" 2>/dev/null | jq -r --arg id "$session_id" 'select(.session_id==$id and .event=="restore-attempt") | .epoch // 0' | tail -1)"
  [ -n "$last" ] || last=0
  now="$(date +%s)"; case "$last:$now" in *[!0-9:]*|'':*) return 1 ;; esac
  [ "$last" -eq 0 ] || [ $((now - last)) -ge "$cooldown" ]
}

_session_relaunch_command() { # <provider> <model> <effort>
  local provider="$1" model="$2" effort="$3" cid tokens de
  case "$provider" in
    codex|cx)
      cid="$(resolve_model_row "$model")"; cid="${cid%%|*}"; [ -n "$cid" ] || cid="$model"
      _validate_model_token "$cid"
      printf 'codex -m %q -s workspace-write -c model_reasoning_effort=%q' "$cid" "$effort"
      ;;
    cc|claude)
      tokens="$(_effort_thinking_tokens "$effort")"
      [ -n "$tokens" ] || return 1
      printf 'env MAX_THINKING_TOKENS=%q -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_EXECPATH claude --model %q' "$tokens" "$model"
      ;;
    droid)
      de="$(_droid_effort "$effort")"; [ -n "$de" ] || return 1
      printf 'droid --auto medium --model %q -r %q' "$model" "$de"
      ;;
    *) return 1 ;;
  esac
}

_session_droid_effort_supported() {
  local help_text
  help_text="$(_session_probe_help droid --help)" || return 1
  printf '%s\n' "$help_text" | grep -Eqi '(^|[[:space:],])-r([[:space:],]|$).*reason|reason.*effort'
}

_session_relaunch_effort() { # <provider> <model> <effort>
  local provider="$1" model="$2" effort="$3" launch
  launch="$(_session_relaunch_command "$provider" "$model" "$effort")" || return 1
  tmux has-session -t "$SESSION_NAME" 2>/dev/null || return 1
  tmux respawn-pane -k -t "$SESSION_NAME" "$launch" || return 1
}

# ---- interactive winpty session broker for Windows ----
_winpty_session() {
  local sub="${1:-}"; shift || true
  _validate_session_name
  if [ "$sub" != "read" ]; then
    echo "unverified Windows mutation support" >&2
    return 1
  fi
  local sdir="$OSRC_HOME/sessions/$SESSION_NAME"
  local broker="$SCRIPT_DIR/outsourcerer-winpty-broker.sh"
  [ -f "$broker" ] || die "winpty broker missing: $broker (installation corruption?)"

  case "$sub" in
    start)
      parse_model "$@"
      _validate_model_token "$MODEL"

      local LAUNCH=()
      case "$PROVIDER" in
        devin|dv)
          need_devin; logged_in || die "Not logged in. Run:  ! devin auth login"
          LAUNCH=("devin" "--model" "$MODEL" "--respect-workspace-trust" "false") ;;
        codex|cx)
          have codex || die "codex not on PATH (needed for a codex session)"
          local crow cid; crow="$(resolve_model_row "$MODEL")"; cid="${crow%%|*}"; [ -n "$cid" ] || cid="$MODEL"
          _validate_model_token "$cid"
          local _ccmh=(); _codex_code_mode_host || _ccmh=("-c" "features.code_mode_host=false")
          LAUNCH=("codex" "-s" "workspace-write")
          [ "$MODEL_EXPLICIT" = "1" ] && LAUNCH+=("-m" "$cid")
          [ -n "$EFFORT" ] && LAUNCH+=("-c" "model_reasoning_effort=$EFFORT")
          LAUNCH+=(${_ccmh[@]+"${_ccmh[@]}"}) ;;
        cc|claude)
          have claude || die "claude not on PATH (needed for a claude session)"
          LAUNCH=("env" "-u" "CLAUDECODE" "-u" "CLAUDE_CODE_ENTRYPOINT" "-u" "CLAUDE_CODE_SESSION_ID" "-u" "CLAUDE_CODE_CHILD_SESSION" "-u" "CLAUDE_CODE_EXECPATH" "claude")
          [ -n "$EFFORT" ] && LAUNCH=("env" "MAX_THINKING_TOKENS=$(_effort_thinking_tokens "$EFFORT")" "-u" "CLAUDECODE" "-u" "CLAUDE_CODE_ENTRYPOINT" "-u" "CLAUDE_CODE_SESSION_ID" "-u" "CLAUDE_CODE_CHILD_SESSION" "-u" "CLAUDE_CODE_EXECPATH" "claude")
          [ "$MODEL_EXPLICIT" = "1" ] && LAUNCH+=("--model" "$MODEL") ;;
        droid|cursor|hermes)
          _session_launch_adapter "$PROVIDER"
          LAUNCH=("${SESSION_LAUNCH[@]}") ;;
        gemini|gm)
          local gveh="${OSRC_GEMINI_VEHICLE:-}"
          if [ -z "$gveh" ]; then if have agy; then gveh=agy; elif have gemini; then gveh=gemini; else die "gemini session needs a CLI (install Antigravity 'agy' keyless, or gemini-cli + GEMINI_API_KEY)"; fi; fi
          have "$gveh" || die "OSRC_GEMINI_VEHICLE=$gveh but '$gveh' not on PATH"
          [ "$gveh" != "gemini" ] || _gm_load_key
          if [ "$MODEL_EXPLICIT" = "1" ]; then LAUNCH=("$gveh" "--model" "$MODEL"); else LAUNCH=("$gveh"); fi ;;
        *) die "session start: provider '$PROVIDER' not supported for interactive sessions (use --provider devin|codex|cc|droid|cursor|hermes|gemini)" ;;
      esac

      have winpty || die "winpty not found (needed for session on Windows; Git for Windows ships it)"
      _mkdir_private "$OSRC_HOME" >/dev/null 2>&1 || die "OSRC_HOME not writable: $OSRC_HOME"

      if [ -d "$sdir" ] && [ -f "$sdir/broker.pid" ]; then
        local bpid; bpid="$(cat "$sdir/broker.pid" 2>/dev/null)"
        if [ -n "$bpid" ] && kill -0 "$bpid" 2>/dev/null; then
          echo "Session '$SESSION_NAME' already exists. Use '$0 session stop' first, or start from a different directory."
          return 0
        fi
      fi
      rm -rf "$sdir"
      _mkdir_private "$sdir" || die "cannot create session dir $sdir"

      declare -p LAUNCH > "$sdir/launch.bash"
      chmod 600 "$sdir/launch.bash" 2>/dev/null || true
      _cloud_disclose "$PROVIDER" "$MODEL" "interactive session in $PWD"
      nohup "$broker" "$sdir" > "$sdir/broker.log" 2>&1 &
      bpid=$!
      echo "$bpid" > "$sdir/broker.pid"

      local _w=0
      while [ "$_w" -lt 20 ]; do
        [ -p "$sdir/stdin" ] && [ -f "$sdir/winpty.pid" ] && break
        sleep 0.2
        _w=$((_w + 1))
      done

      if [ ! -f "$sdir/winpty.pid" ] || ! kill -0 "$(cat "$sdir/winpty.pid" 2>/dev/null)" 2>/dev/null; then
        echo "WARN: winpty did not start quickly; see $sdir/broker.log" >&2
      fi

      echo "Started winpty session '$SESSION_NAME' running $PROVIDER (model: $MODEL) in $PWD."
      _session_registry_append start "$PROVIDER" "$MODEL" "${EFFORT:-}" started launch || die "cannot record session start"
      echo "Give it ~8s to boot, then:  $0 session read   |   $0 session send \"…\"   |   $0 session clear   |   $0 session model [name]   |   $0 session stop"
      _heartbeat_start >/dev/null 2>&1 || echo "outsourcerer: heartbeat auto-arm unavailable; supervision state is unknown" >&2
      ;;
    send)
      [ -n "${1:-}" ] || die "session send needs text"
      [ -d "$sdir" ] || die "no session '$SESSION_NAME' (run: $0 session start)"
      mkdir -p "$sdir/cmd"
      local tmp; tmp="$(mktemp "$sdir/cmd/.send.XXXXXX" 2>/dev/null || echo "$sdir/cmd/send.$$")"
      printf '%s' "$*" > "$tmp"
      mv "$tmp" "$sdir/cmd/send-$(date +%s)-$$-$RANDOM.txt"
      sleep 0.4
      echo "sent. Read progress with: $0 session read"
      ;;
    read)
      [ -d "$sdir" ] || { echo "no session '$SESSION_NAME' (run: $0 session start)"; return 0; }
      if [ -f "$sdir/out.log" ]; then
        tail -n 200 "$sdir/out.log" | grep -v '^[[:space:]]*$'
      else
        echo "(no output yet)"
      fi
      ;;
    clear)
      [ -d "$sdir" ] || die "no session '$SESSION_NAME' (run: $0 session start)"
      mkdir -p "$sdir/cmd"
      : > "$sdir/cmd/clear-$(date +%s)-$$-$RANDOM"
      echo "cleared input for '$SESSION_NAME' (Escape + C-u sent). Re-check with: $0 session read"
      ;;
    model)
      case "$PROVIDER" in
        devin|dv) : ;;
        *) die "mid-session model switch is wired for Devin only. For a $PROVIDER session, stop and restart with a new model:  $0 session stop && $0 --provider $PROVIDER session start -m <model>" ;;
      esac
      [ -d "$sdir" ] || die "no session '$SESSION_NAME' (run: $0 session start)"
      mkdir -p "$sdir/cmd"
      local tmp; tmp="$(mktemp "$sdir/cmd/.model.XXXXXX" 2>/dev/null || echo "$sdir/cmd/model.$$")"
      printf '%s' "${1:-}" > "$tmp"
      mv "$tmp" "$sdir/cmd/model-$(date +%s)-$$-$RANDOM.txt"
      echo "model switch sent${1:+ (filter: $1)}. Confirm with: $0 session read   (active model shows in the footer)."
      ;;
    effort)
      local effort="${1:-}"
      _session_effort_validate "$effort" || die "session effort requires: minimal|low|medium|high|xhigh|max|none"
      [ -d "$sdir" ] || die "no session '$SESSION_NAME' (run: $0 session start)"
      case "$PROVIDER" in
        devin|dv|gemini|gm)
          _session_registry_append effort "$PROVIDER" "$MODEL" "$effort" advisory advisory || die "cannot record session effort"
          echo "effort recorded as advisory for $PROVIDER; the running session was not changed."
          ;;
        *) die "session effort is unavailable for $PROVIDER on Windows (unverified Windows mutation support)" ;;
      esac
      ;;
    stop)
      if [ -d "$sdir" ]; then
        mkdir -p "$sdir/cmd"
        : > "$sdir/cmd/stop"
        if [ -f "$sdir/broker.pid" ]; then
          local bpid; bpid="$(cat "$sdir/broker.pid" 2>/dev/null)"
          local _w=0
          while [ "$_w" -lt 15 ] && [ -n "$bpid" ] && kill -0 "$bpid" 2>/dev/null; do
            sleep 0.2
            _w=$((_w + 1))
          done
          [ -n "$bpid" ] && kill -0 "$bpid" 2>/dev/null && kill -9 "$bpid" 2>/dev/null || true
        fi
      fi
      rm -rf "$sdir"
      echo "stopped '$SESSION_NAME'."
      ;;
    *)
      die "session subcommand: start | send \"text\" | read | clear | model [NAME] | effort <level> | stop"
      ;;
  esac
}

# ---- interactive tmux session (opt-in) ----
session() {
  _validate_session_name
  if [ "$OSRC_PLATFORM" = "windows" ]; then
    _winpty_session "$@"
    return
  fi
  if ! have tmux; then
    die "tmux not installed ($( [ "$OSRC_PLATFORM" = "mac" ] && echo 'brew install tmux' || echo 'apt/dnf install tmux')). Only 'session' needs it — bg/fanout cover the same ground supervised."
  fi
  local sub="${1:-}"; shift || true
  case "$sub" in
    claim)
      [ "$#" -eq 2 ] || die "session claim needs <external-id> <tmux-pane>"
      local claim_token
      claim_token="$(_external_session_claim "$1" "$2")" || die "could not establish a verified external-session claim"
      echo "claim established for '$1'"
      echo "claim token: $claim_token"
      echo "for separate invocations: export OSRC_SESSION_CLAIM_TOKEN='$claim_token'"
      ;;
    release)
      [ "$#" -eq 1 ] || die "session release needs <external-id>"
      _external_session_release "$1" || die "could not release this external-session claim"
      echo "claim released for '$1'"
      ;;
    reply)
      [ "$#" -ge 2 ] || die "session reply needs <external-id> <text>"
      local external_id="$1"; shift
      _external_reply "$external_id" "$*" || return 1
      ;;
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
          launch="devin --model '$MODEL' --respect-workspace-trust false" ;;   # single-quoted: a validated [1m]-style token must not glob-expand when send-keys hands it to the shell
        codex|cx)
          have codex || die "codex not on PATH (needed for a codex session)"
          local crow cid; crow="$(resolve_model_row "$MODEL")"; cid="${crow%%|*}"; [ -n "$cid" ] || cid="$MODEL"
          # The resolved codex model id is what enters the tmux command.
          _validate_model_token "$cid"
          local ccmh=""; _codex_code_mode_host || ccmh=" -c features.code_mode_host=false"  # self-heal in the TUI too
          # No `--cd "$PWD"` -- tmux new-session already starts the pane in $PWD (-c "$PWD").
          # Interpolating $PWD into this shell-command string was a directory-name injection vector
          # (a dir named `x"; touch /tmp/pwn; #` would break out when send-keys hands it to the shell).
          if [ "$MODEL_EXPLICIT" = "1" ]; then launch="codex -m '$cid' -s workspace-write$ccmh"; else launch="codex -s workspace-write$ccmh"; fi
          [ -n "$EFFORT" ] && launch="$launch -c model_reasoning_effort=$EFFORT" ;;
        cc|claude)
          have claude || die "claude not on PATH (needed for a claude session)"
          # strip nested Claude Code env so a nested interactive claude authenticates via OAuth (same fix as the -p lane)
          if [ "$MODEL_EXPLICIT" = "1" ]; then launch="env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_EXECPATH claude --model '$MODEL'"; else launch="env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_EXECPATH claude"; fi
          [ -n "$EFFORT" ] && launch="env MAX_THINKING_TOKENS=$(_effort_thinking_tokens "$EFFORT") $launch" ;;
        droid|cursor|hermes)
          _session_launch_adapter "$PROVIDER"
          launch="$(_session_shell_command "${SESSION_LAUNCH[@]}")" ;;
        gemini|gm)
          local gveh="${OSRC_GEMINI_VEHICLE:-}"
          if [ -z "$gveh" ]; then if have agy; then gveh=agy; elif have gemini; then gveh=gemini; else die "gemini session needs a CLI (install Antigravity 'agy' keyless, or gemini-cli + GEMINI_API_KEY)"; fi; fi
          have "$gveh" || die "OSRC_GEMINI_VEHICLE=$gveh but '$gveh' not on PATH"
          [ "$gveh" != "gemini" ] || _gm_load_key
          if [ "$MODEL_EXPLICIT" = "1" ]; then launch="$gveh --model '$MODEL'"; else launch="$gveh"; fi ;;
        *) die "session start: provider '$PROVIDER' not supported for interactive sessions (use --provider devin|codex|cc|droid|cursor|hermes|gemini)" ;;
      esac
      # Use has-session to avoid killing a concurrent session.
      _validate_session_name
      _cloud_disclose "$PROVIDER" "$MODEL" "interactive session in $PWD"
      if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        # NONZERO on collision. The session name is derived from $PWD, so N concurrent `session start`
        # calls in one repo all resolve to this same name. Returning 0 here reported "started" to every
        # one of them: a caller fanning out 6 agents got 1 session and 5 silent successes, with no exit
        # code to distinguish "yours is running" from "someone else's is". Fail loudly instead; a caller
        # that wants a second session in the same directory must set OUTSOURCERER_TMUX explicitly.
        echo "Session '$SESSION_NAME' already exists (name derives from \$PWD, so one session per directory). Use '$0 session stop' first, reattach with 'tmux attach -t $SESSION_NAME', or set OUTSOURCERER_TMUX=<name> to run a second isolated session here." >&2
        return 4
      fi
      tmux new-session -d -s "$SESSION_NAME" -x 200 -y 50 -c "$PWD"
      tmux send-keys -t "$SESSION_NAME" "export PATH=\"\$HOME/.local/bin:\$PATH\"; clear; $launch" Enter
      _session_registry_append start "$PROVIDER" "$MODEL" "${EFFORT:-}" started launch || die "cannot record session start"
      echo "Started tmux session '$SESSION_NAME' running $PROVIDER (model: $MODEL) in $PWD."
      echo "Give it ~8s to boot, then:  $0 session read   |   $0 session send \"…\"   |   $0 session clear   |   $0 session model [name]   |   $0 session stop"
      _heartbeat_start >/dev/null 2>&1 || echo "outsourcerer: heartbeat auto-arm unavailable; supervision state is unknown" >&2
      ;;
    send)
      [ -n "${1:-}" ] || die "session send needs text"
      tmux has-session -t "$SESSION_NAME" 2>/dev/null || die "no session '$SESSION_NAME' (run: $0 session start)"
      _managed_session_send "$SESSION_NAME" "$*" || die "session send was not receipt-verified; delivery marked unknown"
      echo "sent. Read progress with: $0 session read"
      ;;
    read)
      tmux capture-pane -t "$SESSION_NAME" -p | grep -v '^[[:space:]]*$'
      ;;
    clear)
      tmux has-session -t "$SESSION_NAME" 2>/dev/null || die "no session '$SESSION_NAME' (run: $0 session start)"
      _managed_session_clear "$SESSION_NAME" || die "session clear refused: managed pane identity could not be proven"
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
      _managed_session_model "$SESSION_NAME" "${1:-}" || die "session model refused: managed pane identity could not be proven"
      echo "model switch sent${1:+ (filter: $1)}. Confirm with: $0 session read   (active model shows in the footer)."
      ;;
    effort)
      local effort="${1:-}"
      _session_effort_validate "$effort" || die "session effort requires: minimal|low|medium|high|xhigh|max|none"
      tmux has-session -t "$SESSION_NAME" 2>/dev/null || die "no session '$SESSION_NAME' (run: $0 session start)"
      case "$PROVIDER" in
        devin|dv|gemini|gm)
          _session_registry_append effort "$PROVIDER" "$MODEL" "$effort" advisory advisory || die "cannot record session effort"
          echo "effort recorded as advisory for $PROVIDER; the running session was not changed."
          ;;
        droid)
          _session_droid_effort_supported || die "session effort relaunch unavailable; droid does not advertise a reasoning-effort control"
          _session_relaunch_effort droid "$MODEL" "$effort" || die "session effort relaunch failed; the prior session remains active"
          _session_registry_append effort "$PROVIDER" "$MODEL" "$effort" running relaunch || die "cannot record session effort"
          echo "receipt: relaunch applied effort $effort to '$SESSION_NAME'."
          ;;
        codex|cx|cc|claude)
          _session_relaunch_effort "$PROVIDER" "$MODEL" "$effort" || die "session effort relaunch failed; the prior session remains active"
          _session_registry_append effort "$PROVIDER" "$MODEL" "$effort" running relaunch || die "cannot record session effort"
          echo "receipt: relaunch applied effort $effort to '$SESSION_NAME'."
          ;;
        *)
          _session_registry_append effort "$PROVIDER" "$MODEL" "$effort" advisory advisory || die "cannot record session effort"
          echo "effort recorded as advisory for $PROVIDER; the running session was not changed."
          ;;
      esac
      ;;
    stop)
      tmux kill-session -t "$SESSION_NAME" 2>/dev/null && echo "stopped '$SESSION_NAME'." || echo "no session '$SESSION_NAME'."
      ;;
    *)
      die "session subcommand: start | send \"text\" | read | clear | model [NAME] | effort <level> | claim <external-id> <tmux-pane> | release <external-id> | reply <external-id> <text> | stop"
      ;;
  esac
}

# ---- unwatched-job detection --------------------------------------------------------------------
# A detached job nobody is watching is the failure mode this tool exists to prevent: it accepts work,
# goes quiet, and the orchestrator finds out minutes or hours later. Telling the orchestrator to
# "remember to watch" does not survive a busy session, so the tool tracks attention itself and says so
# at the next opportunity, rather than relying on anyone's memory.
_mark_watched() { [ -n "${1:-}" ] && [ -d "$OSRC_JOBS/$1" ] && date +%s > "$OSRC_JOBS/$1/last_seen" 2>/dev/null || true; }

# _unwatched_jobs -> lines "<id> <seconds-since-anyone-looked>" for RUNNING jobs nobody is tracking.
_unwatched_jobs() {
  local jd id st seen now age; now=$(date +%s)
  [ -d "$OSRC_JOBS" ] || return 0
  for jd in "$OSRC_JOBS"/*/; do
    [ -d "$jd" ] || continue
    id="$(basename "$jd")"
    st="$(cat "$jd/status" 2>/dev/null || echo '?')"
    case "$st" in running|launching|"stalled?"|"exploring?") ;; *) continue ;; esac
    seen="$(cat "$jd/last_seen" 2>/dev/null)"
    case "$seen" in ''|*[!0-9]*) seen="$(cat "$jd/started_at" 2>/dev/null)" ;; esac
    case "$seen" in ''|*[!0-9]*) continue ;; esac
    age=$(( now - seen ))
    [ "$age" -ge "${OSRC_UNWATCHED_AFTER:-120}" ] && printf '%s %s\n' "$id" "$age"
  done
}

# _warn_unwatched -> loud, actionable notice on stderr when live jobs are going unobserved.
_warn_unwatched() {
  local out n; out="$(_unwatched_jobs)"; [ -n "$out" ] || return 0
  n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  printf '>>> [outsourcerer] %s job(s) are RUNNING and nobody has looked at them:\n' "$n" >&2
  printf '%s\n' "$out" | while read -r _i _a; do
    printf '>>>   %s  (unobserved %ss)   watch it: %s watch %s\n' "$_i" "$_a" "$0" "$_i" >&2
  done
  printf '>>>   An unwatched job is how a wedge becomes a lost hour. Watch it, or cancel it.\n' >&2
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
  # Resolve the running install robustly (plugin OR ~/.claude/skills, even via a launcher symlink)
  # instead of hardcoding one layout -- otherwise a plugin-only install silently skips these mirrors.
  local self; self="$(_osrc_skill_root || printf '%s' "$HOME/.claude/skills/outsourcerer")"
  local agdst="" c
  for c in "$HOME/.gemini/antigravity/skills" "$HOME/.gemini/config/skills"; do
    if [ -d "$c" ] && [ -w "$c" ]; then agdst="$c"; break; fi
  done
  if [ -n "$agdst" ] && [ -f "$self/SKILL.md" ]; then
    _osrc_link_skill_into "$agdst" "$self"
    case $? in
      0) echo "  linked outsourcerer -> $agdst (Antigravity/agy will discover it)" ;;
      3) echo "  (Antigravity: $agdst/outsourcerer is a real dir, not a link; left untouched — use: agy plugin import claude-code)" ;;
      *) echo "  (could not link into Antigravity skills dir $agdst; use: agy plugin import claude-code)" ;;
    esac
  else
    echo "  (Antigravity skills dir not found; if you use agy, run: agy plugin import claude-code)"
  fi

  # Hermes host (bonus): Hermes (NousResearch) also loads SKILL.md-format skills, from
  # $HERMES_HOME/skills. If that dir exists, mirror this ONE skill in too, so a Hermes session sees
  # outsourcerer without a separate step. Same symlink mechanism as Devin/Antigravity above; the
  # dedicated entrypoint is `parity-hermes`. Non-fatal, additive.
  local hdst="${HERMES_HOME:-$HOME/.hermes}/skills"
  if [ -d "$hdst" ] && [ -w "$hdst" ] && [ -f "$self/SKILL.md" ]; then
    _osrc_link_skill_into "$hdst" "$self"
    case $? in
      0) echo "  linked outsourcerer -> $hdst (Hermes will discover it)" ;;
      3) echo "  (Hermes: $hdst/outsourcerer is a real dir, not a link; left untouched — run: outsourcerer.sh parity-hermes after removing it)" ;;
      *) echo "  (could not link into Hermes skills dir $hdst; use: outsourcerer.sh parity-hermes)" ;;
    esac
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
  # OSRC_DOCTOR_OFFLINE=1 skips the LIVE probes (OpenRouter credits, session-limit meter, claudex
  # proxy ping) so `doctor` returns in well under a second. Without it, those network reads can each
  # take tens of seconds on a slow/dead backend, which is why the test suite (test_watcher calls
  # doctor repeatedly) appeared to hang. Everything else — installed-CLI detection, version-drift,
  # state-home writability, lane inventory — is local and always runs.
  local _doff="${OSRC_DOCTOR_OFFLINE:-0}"
  echo "  platform: $OSRC_PLATFORM$( [ "$OSRC_PLATFORM" = "windows" ] && echo ' (Git Bash — NO WSL needed. Works: run/edit/yolo/bg/fanout/status/doctor/advise. Not available: tmux session mode.)')"
  # VERSION-DRIFT check: the manifest, THIS running script, and any OTHER installed copy
  # (a stale standalone skill dir) can silently disagree — a user then runs old code missing every
  # recent fix. Flag any mismatch loudly. Best-effort; silent when nothing to compare.
  # _dver is INITIALISED, not merely declared: it is assigned only when jq is present, but read
  # unconditionally on the next line. Under `set -u` a bare `local _dver` leaves it unset, so on a
  # machine without jq the read aborts doctor entirely — the one command whose job is to tell the
  # user that jq is missing would die before it could say so.
  { local _dver="" _mf _sd _drift=""
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
  if [ "$_doff" = "1" ]; then echo "  session limits: skipped (OSRC_DOCTOR_OFFLINE)  · conserve line: ${OSRC_CONSERVE_THRESHOLD}% of the 5h window"
  else local _lim; _lim="$(_session_limits 2>/dev/null)"; echo "  session limits: ${_lim:-unavailable (no readable meter)}  · conserve line: ${OSRC_CONSERVE_THRESHOLD}% of the 5h window"; fi
  echo "  active provider: $PROVIDER  (switch with --provider devin|cc|codex|droid|cursor|hermes|warp|claudex|local or OUTSOURCERER_PROVIDER)"
  echo "  -- OpenRouter lanes (cc / codex) --"
  if [ -f "$HOME/.env" ] && grep -q "OPENROUTER_API_KEY" "$HOME/.env" 2>/dev/null; then echo "    openrouter key: present in ~/.env"; else echo "    openrouter key: MISSING from ~/.env"; fi
  have claude && echo "    claude (cc lane):    $(claude --version 2>/dev/null | head -1)" || echo "    claude (cc lane):    NOT on PATH"
  have codex  && echo "    codex  (codex lane): $(codex --version 2>/dev/null | head -1)"  || echo "    codex  (codex lane): NOT on PATH"
  echo "    model chain: ${OR_OFFLOAD_CHAIN:-$OR_CHAIN_DEFAULT}"
  if [ "$_doff" != "1" ]; then local cred; cred="$(or_credits)"; [ -n "$cred" ] && echo "    openrouter credits: $cred"; fi
  echo "  -- Native premium lanes (model-selected; ride your own subscription) --"
  echo "    codex-native (sol/terra/luna/gpt-5.5): $(have codex && echo 'codex present (installed + ChatGPT-authed-looking; NOT probed for liveness)' || echo 'codex NOT on PATH'); cost: $(_lane_cost_disclosure cx)"
  if have codex; then _codex_code_mode_host \
    && echo "      code-mode-host: present (codex file-reading tool calls work)" \
    || echo "      code-mode-host: MISSING, self-healed (Outsourcerer runs codex with code_mode_host disabled so file reads do not hang; install codex-code-mode-host to ~/.local/bin to use the feature)"; fi
  echo "    claude-native (fable/opus/sonnet/haiku): $(have claude && echo 'claude present (installed + Claude-authed-looking; NOT probed for liveness)' || echo 'claude NOT on PATH'); cost: $(_lane_cost_disclosure cc)"
  [ -n "${CLAUDECODE:-}" ] && echo "      note: inside Claude Code, this lane still runs a VERIFIED specific Claude model (env-cleaned, model checked against modelUsage). Safer than a native subagent, which can silently fall back to your default with no way to verify."
  if [ "${OSRC_DOCTOR_PING:-0}" = "1" ]; then
    echo "    (pinging native lanes, costs ~1 token each; bounded to ${OSRC_DOCTOR_PING_TIMEOUT:-30}s per lane)"
    # INSTALLED IS NOT READY. A lane stays installed and authenticated while its subscription window is
    # exhausted, its token has expired, or its backend has stopped answering — and a binary that prints
    # a version proves none of that. Only a real request separates the two, so the probe classifies WHY
    # it failed and names the remedy, instead of a bare "no reply" the user cannot act on.
    # Bounded via _timeout so a dead lane costs seconds, not minutes.
    # NOTE: OSRC_DOCTOR_PING_TIMEOUT is a bare number of seconds. It is deliberately NOT agy's
    # OSRC_DOCTOR_PROBE_TIMEOUT, which carries an 's' suffix for agy's own --print-timeout flag and
    # would be rejected by _timeout.
    local _ppt _prc
    # --ignore-user-config: the diagnostic itself must not wedge on a user's interactive-auth MCP
    # server (auth survives the flag; this is exactly the isolation the delegate paths now use).
    if have codex; then
      _ppt=""; _prc=0
      _ppt="$(_timeout "${OSRC_DOCTOR_PING_TIMEOUT:-30}" codex exec --ignore-user-config --skip-git-repo-check --sandbox read-only -m gpt-5.6-luna "reply PONG" 2>&1)" || _prc=$?
      if [ "$_prc" -eq 0 ] && printf '%s' "$_ppt" | grep -qi 'pong'; then
        echo "      codex-native luna: READY (probed just now, answered)"
      else
        case "$_ppt" in
          *[Aa]uth*|*401*|*403*|*[Uu]nauthor*)
            echo "      codex-native luna: INSTALLED BUT NOT ANSWERING — auth rejected. Fix: run 'codex login' to refresh your ChatGPT token." ;;
          *429*|*[Rr]ate*|*[Ll]imit*|*[Qq]uota*|*[Ee]xhaust*)
            echo "      codex-native luna: INSTALLED BUT NOT ANSWERING — plan window exhausted / rate-limited. Fix: wait for your ChatGPT plan window to reset, or switch lanes for now." ;;
          *)
            echo "      codex-native luna: INSTALLED BUT NOT ANSWERING (rc=$_prc) — a real request did not come back. Treat this lane as DOWN, not ready: check your network, then 'codex login', then whether your ChatGPT plan window is exhausted." ;;
        esac
      fi
    fi
    if have claude; then
      _ppt=""; _prc=0
      _ppt="$(_timeout "${OSRC_DOCTOR_PING_TIMEOUT:-30}" env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_EXECPATH claude -p --strict-mcp-config --mcp-config <(printf '{"mcpServers":{}}') --model haiku "reply PONG" 2>&1)" || _prc=$?
      if [ "$_prc" -eq 0 ] && printf '%s' "$_ppt" | grep -qi 'pong'; then
        echo "      claude-native haiku: READY (probed just now, answered)"
      else
        case "$_ppt" in
          *[Aa]uth*|*401*|*403*|*[Uu]nauthor*)
            echo "      claude-native haiku: INSTALLED BUT NOT ANSWERING — auth rejected. Fix: run 'claude' interactively to re-login." ;;
          *429*|*[Rr]ate*|*[Ll]imit*|*[Qq]uota*|*[Ee]xhaust*)
            echo "      claude-native haiku: INSTALLED BUT NOT ANSWERING — plan window exhausted / rate-limited. Fix: wait for your Claude plan window to reset, or switch lanes for now." ;;
          *)
            echo "      claude-native haiku: INSTALLED BUT NOT ANSWERING (rc=$_prc) — a real request did not come back. Treat this lane as DOWN, not ready: check your network, then re-run 'claude' to re-login, then whether your Claude plan window is exhausted." ;;
        esac
      fi
    fi
    if have agy; then agy -p "reply PONG" --model "gemini-3.5-flash" --print-timeout 60s >/dev/null 2>&1 && echo "      antigravity-agy (keyless): PONG (Antigravity login active)" || echo "      antigravity-agy: no reply (open Antigravity / sign in once so agy inherits your login)"; fi
    have gemini && { gemini -p "reply PONG" --allowed-mcp-server-names __none__ --approval-mode default --model gemini-3.1-flash-lite >/dev/null 2>&1 && echo "      gemini-cli (api key): PONG (authenticated)" || echo "      gemini-cli: no reply (not authed / model unavailable)"; }
  else
    echo "    (set OSRC_DOCTOR_PING=1 to probe native lane liveness with a bounded 1-token request; without it, 'present' above means installed + authed-looking, NOT proven to answer)"
  fi
  echo "  -- Engine lanes (YOUR agent CLI + YOUR configured models, incl. BYOK) --"
  if have droid; then echo "    droid (Factory): $(droid --version 2>/dev/null | head -1 || echo present) — route: --provider droid [-m <your-model-name>] run \"task\". Cost: $(_lane_cost_disclosure droid)."
  else echo "    droid (Factory): NOT on PATH — install: https://docs.factory.ai/cli (macOS/Linux/Windows-native)"; fi
  if have cursor-agent; then echo "    cursor-agent: $(cursor-agent --version 2>/dev/null | head -1 || echo present) — route: --provider cursor [-m <model>] run \"task\". Cost: $(_lane_cost_disclosure cursor)."
  else echo "    cursor-agent: NOT on PATH — install: curl https://cursor.com/install -fsS | bash (Windows native: irm 'https://cursor.com/install?win32=true' | iex), then cursor-agent login"; fi
  echo "  -- Hermes lane (NousResearch hermes-agent, engine lane: -m passes through verbatim) --"
  # Honest lane states: (a) CLI on PATH + version; (b) CLI absent but ~/.hermes exists (installed
  # data dir found, CLI not on PATH); (c) neither (lane not installed); (d) state.db present +
  # guarded session count vs absent (never run — cost receipts use estimates until first session).
  # NEVER falsely READY; NEVER exit non-zero solely because the lane is absent.
  if have hermes; then
    echo "    hermes: $(hermes --version 2>/dev/null | head -1 || echo present) — route: --provider hermes [-m <model>] run \"task\". Cost: $(_lane_cost_disclosure hermes)."
  else
    local _hhome; _hhome="$(_hermes_home)"
    if [ -d "$_hhome" ]; then
      echo "    hermes: installed data dir found ($_hhome), CLI not on PATH — install the CLI: https://github.com/NousResearch/hermes-agent"
    else
      echo "    hermes: lane not installed — install: https://github.com/NousResearch/hermes-agent  (then run 'hermes' once to configure)"
    fi
  fi
  # state.db session count (guarded, read-only). Absent -> never run; present -> count sessions.
  local _hdb; _hdb="$(_hermes_db)"
  if [ -f "$_hdb" ]; then
    if have sqlite3; then
      local _hsess; _hsess="$(sqlite3 -readonly "$_hdb" ".timeout ${OSRC_SQLITE_BUSY_TIMEOUT:-3000}" "SELECT COUNT(*) FROM sessions;" 2>/dev/null)" || _hsess=""
      case "$_hsess" in ''|*[!0-9]*) echo "    hermes state.db: present but unreadable (schema drift or locked) — cost receipts use estimates" ;;
        *) echo "    hermes state.db: present, $_hsess session(s), cost receipts available" ;; esac
    else
      echo "    hermes state.db: present but sqlite3 not on PATH — cost receipts use estimates"
    fi
  else
    echo "    hermes state.db: absent — never run, cost receipts use estimates until first session"
  fi
  echo "  -- Claudex lane (GPT-5.6 Sol/Terra INSIDE the Claude Code harness, via YOUR local CLIProxyAPI) --"
  if [ "$_doff" = "1" ]; then echo "    claudex: probe skipped (OSRC_DOCTOR_OFFLINE)"
  elif have cliproxyapi || have cli-proxy-api || [ -f "${OSRC_CLAUDEX_CONFIG:-$HOME/.cli-proxy-api/config.yaml}" ]; then
    if _claudex_up 2>/dev/null; then
      echo "    claudex: READY — proxy answering at $(_claudex_url). Route: --provider claudex run [-m sol|terra|luna] \"task\". Cost: $(_lane_cost_disclosure claudex)."
      echo "      note: UNOFFICIAL community bridge (internal upstream endpoints, no rate limiting — heavy use risks provider-side limits). Claude-sub models are refused here by policy; codex CLI is still the lane for gpt-image."
    else
      echo "    claudex: proxy installed but NOT answering at $(_claudex_url) (start it, check api-keys in ~/.cli-proxy-api/config.yaml, or set OSRC_CLAUDEX_URL/OSRC_CLAUDEX_TOKEN)"
    fi
  else
    echo "    claudex: not set up (optional). It runs sol/terra/luna INSIDE Claude Code via a self-hosted proxy the USER installs + audits: https://github.com/router-for-me/CLIProxyAPI (then: cli-proxy-api --codex-login). Detect-only: outsourcerer never installs it. Official alternative: openai/codex-plugin-cc."
  fi
  echo "  -- Local inference lane (Ollama / LM Studio / llama.cpp, KEYLESS, PRIVATE, $(_lane_cost_disclosure local)) --"
  local _ld; if _ld="$(_local_detect 2>/dev/null)"; then
    local _lb="${_ld%%|*}" _lr="${_ld#*|}"; echo "    detected: ${_lr##*|} at $_lb (e.g. model '${_lr%%|*}'). Private, $(_lane_cost_disclosure local). Route: -m ollama:<model> | -m local | --provider local \"<task>\""
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
    echo "    agy (Antigravity CLI, PRIMARY/keyless): v$(agy --version 2>/dev/null | head -1), auth = your Antigravity/Google app login; cost: $(_lane_cost_disclosure gm)"
    # INSTALLED IS NOT READY. Reporting a lane as available because its binary prints a version is how
    # work gets routed to something that cannot answer: agy stays installed and authenticated-looking
    # while every request times out (expired app login, service trouble). A bounded real request is the
    # only thing that distinguishes the two. OSRC_DOCTOR_PROBE=0 skips it.
    if [ "$_doff" = "1" ]; then echo "    agy liveness: probe skipped (OSRC_DOCTOR_OFFLINE)"
    elif [ "${OSRC_DOCTOR_PROBE:-1}" = "1" ]; then
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
    echo "    resolved image backend: codex gpt-image-2 (KEYLESS); cost: $(_lane_cost_disclosure ci)"
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
    echo "  auth:  $(devin auth status 2>/dev/null | awk -F: '/Tier/{gsub(/^[ \t]+/,"",$2);print "logged in ("$2" tier)"}')  [status check only — NOT probed for liveness; set OSRC_DOCTOR_PING=1 to verify it answers]"
  else
    echo "  auth:  NOT logged in -> run:  ! devin auth login"
  fi
  # Same lesson as the agy probe, applied to the default lane: `devin auth status` reads a login file,
  # which proves nothing about whether the backend answers. A bounded real request is the only thing
  # that catches an expired token, an exhausted plan/ACU window, or an outage. glm-5.2 is the lowest
  # plan-impact probe and `auto` only auto-approves READ-ONLY tools, so the probe cannot
  # edit anything. </dev/null keeps it non-interactive.
  if [ "${OSRC_DOCTOR_PING:-0}" = "1" ] && logged_in; then
    local _dpt _drc=0
    _dpt="$(_timeout "${OSRC_DOCTOR_PING_TIMEOUT_DEVIN:-45}" devin --model glm-5.2 --permission-mode auto -p "reply PONG" </dev/null 2>&1)" || _drc=$?
    if [ "$_drc" -eq 0 ] && printf '%s' "$_dpt" | grep -qi 'pong'; then
      echo "  devin liveness: READY (probed just now with glm-5.2, answered)"
    else
      case "$_dpt" in
        *[Aa]uth*|*401*|*403*|*[Uu]nauthor*|*"ot logged"*)
          echo "  devin liveness: INSTALLED BUT NOT ANSWERING — auth rejected / not logged in. Fix: run 'devin auth login'." ;;
        *429*|*[Rr]ate*|*[Ll]imit*|*[Qq]uota*|*[Ee]xhaust*|*ACU*)
          echo "  devin liveness: INSTALLED BUT NOT ANSWERING — Devin plan/ACU budget exhausted or rate-limited. Fix: wait for the window to reset, use local ($(_lane_cost_disclosure local)), or choose a priced OpenRouter model." ;;
        *)
          echo "  devin liveness: INSTALLED BUT NOT ANSWERING (rc=$_drc) — a real request did not come back. Treat this lane as DOWN, not ready: check your network and any *_PROXY env var (see the proxy note above), then 'devin auth login'." ;;
      esac
    fi
  fi
  echo "  devin cost: $(_lane_cost_disclosure dv)"
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

Plan-limit note (CHANGES OFTEN, verify, never assume):
  Open-weight models (glm*, deepseek*, kimi*, swe*) usually use less of the Devin allocation.
  Premium models (claude*, gpt*, gemini*) typically draw your Devin usage/ACUs faster.
  Pricing shifts frequently, confirm current cost at your Devin usage dashboard before
  routing heavy work to a premium model. The default is glm-5.2. Every run has
  $0 cash cost here and spends your Devin plan limits.
EOF
}

# _check_signature -> a check's output reduced to its MEANING, for comparing one attempt to the next.
# Byte-comparison is useless against real test output: a suite that prints a duration, a timestamp, a
# temp path or a run id produces different bytes every time while reporting the identical failure, so a
# byte-identical guard never fires on the tools people actually use. Only VOLATILE tokens are removed.
# Small integers are deliberately KEPT: "5 tests failed" -> "3 tests failed" is progress, and erasing
# that would stop a loop that is converging. Lines are sorted so ordering noise does not read as
# change, but duplicates are NOT collapsed: five identical failures and three are different states,
# and deduplicating them would hide exactly the progress this guard must not interrupt.
_check_signature() {
  sed -E \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.]+Z?//g' \
    -e 's/[0-9]{1,2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?//g' \
    -e 's/[0-9]+(\.[0-9]+)?(ms|s|m)([^a-zA-Z]|$)/\3/g' \
    -e 's/[0-9]{6,}//g' \
    -e 's/([^0-9a-zA-Z]|^)[0-9a-f]{8,}([^0-9a-zA-Z]|$)/\1\2/g' \
    -e 's/(tmp|temp)[A-Za-z0-9_.-]+//g' \
    -e 's/[[:space:]]+/ /g' 2>/dev/null | sort
}

# cmd_loop -- bounded loops. The ONE built-in shape is `verify`: delegate -> run an EXTERNAL check ->
# retry-with-feedback, on the cheapest model, until the check passes or a cap fires. Richer shapes
# (sweep / best-of-N / evaluator-optimizer / council-build) are orchestrator recipes in references/loops.md,
# composed from the existing verbs — not a workflow engine here. Terminates into exactly one state:
# success (0) | blocked (3) | max_turns (2). State (each attempt + check output) lives on disk.
# _loop_check <secs> <check> <outfile> -> run the acceptance check under a wall-clock cap.
# The check is EXTERNAL and arbitrary — someone else's test suite, build, or linter — so it can hang.
# An unbounded check is not merely slow: the loop's own time guard is only consulted BETWEEN attempts,
# so a hung check means --max-minutes never fires and the loop runs forever, which is the one thing a
# bounded loop promises not to do. Stock macOS ships no `timeout`, so this polls and then uses the
# existing recursive killer, ensuring the check's children die with it rather than leaking.
# Returns 124 on timeout, matching coreutils' convention, so it can never be mistaken for success.
_loop_check() {
  local secs="$1" check="$2" outfile="$3" pid started now rc=0
  : > "$outfile" || return 125
  bash -c "$check" > "$outfile" 2>&1 &
  pid=$!
  started=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    if [ $(( now - started )) -ge "$secs" ]; then
      _kill_tree "$pid"
      printf '\n[outsourcerer] acceptance check TIMED OUT after %ss.\n' "$secs" >> "$outfile"
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}

cmd_loop() {
  local shape="${1:-}"; [ $# -gt 0 ] && shift
  local resume=0 lid="" ldir=""
  case "$shape" in
    status)
      # What anyone needs mid-run: is it moving, how far in, and what is still wrong.
      local _l _st _at _mx _el _lf _now; _now=$(date +%s)
      [ -d "$OSRC_HOME/loops" ] || { echo "no loops yet"; return 0; }
      printf '%-26s %-9s %-8s %-7s %s\n' "LOOP" "STATE" "ATTEMPT" "ELAPSED" "LAST FAILURE"
      for _l in "$OSRC_HOME/loops"/*/; do
        [ -d "$_l" ] || continue
        _st="$(cat "$_l/state" 2>/dev/null || echo '?')"
        _at="$(cat "$_l/attempt" 2>/dev/null || echo '-')"
        _mx="$(sed -n 's/^max: //p' "$_l/meta" 2>/dev/null || echo '?')"
        _el="$(sed -n 's/^started: //p' "$_l/meta" 2>/dev/null)"
        case "$_el" in ''|*[!0-9]*) _el="?" ;; *) _el="$(( _now - _el ))s" ;; esac
        _lf="$(cut -c1-46 "$_l/last_fail" 2>/dev/null)"
        printf '%-26s %-9s %-8s %-7s %s\n' "$(basename "$_l")" "$_st" "$_at/$_mx" "$_el" "${_lf:-—}"
      done
      return 0 ;;
    verify) ;;
    resume)
      # A loop that stopped without converging still holds everything needed to continue: the task,
      # the check, and the accumulated failure feedback. Restarting from attempt 1 throws that away and
      # pays for the same ground twice, so a non-success terminal loop can be picked up where it left off.
      resume=1
      lid="${1:-}"
      [ -n "$lid" ] || die "loop resume needs a loop id (see: loop status)"
      shift
      case "$lid" in *[!A-Za-z0-9._-]*|'') die "loop resume: invalid loop id" ;; esac
      ldir="$OSRC_HOME/loops/$lid"
      [ -d "$ldir" ] || die "loop resume: no such loop '$lid' (see: loop status)"
      case "$(cat "$ldir/state" 2>/dev/null)" in
        success) die "loop resume: '$lid' already succeeded; refusing to rerun a successful loop" ;;
        blocked|max_turns|max_time) ;;
        *) die "loop resume: '$lid' is not a resumable terminal loop (state: $(cat "$ldir/state" 2>/dev/null || echo '?'))" ;;
      esac ;;
    ''|-h|--help|help) die "loop: the built-in shapes are 'verify' and 'resume'. Usage:
  loop verify -m <model> --check \"<cmd>\" [--max N] [--verb edit|yolo] \"<task>\"
  loop resume <loop-id> [--max N]

Which loop do you want?
  a machine can verify it (tests/lint/build), one known target  -> loop verify   (this one)
  continue a stopped loop using its saved feedback              -> loop resume
  a machine can verify it, but you do not know how much work    -> sweep         (recipe)
  no checker, but you can compare candidates                    -> best-of-N     (recipe)
  quality is a matter of degree, not pass/fail                  -> evaluator-optimizer (recipe)
  the PLAN is the risky part, not the code                      -> council-build (recipe)
If nothing can verify the result, do not loop at all — delegate once and read it yourself.
Recipes are composed from the existing verbs, not a workflow engine: see references/loops.md." ;;
    *) die "loop: unknown shape '$shape' (only 'verify' and 'resume' are built in; sweep/best-of-N/council-build are recipes in references/loops.md)." ;;
  esac
  # The CHECK is the goal; these are runaway guards, not targets. The loop ends the moment the check
  # passes, so a cap only ever fires when the work is NOT converging. A round count alone is a poor
  # guard because rounds are not equal work — three attempts at a one-line fix and three at a refactor
  # are wildly different — so a wall-clock bound sits alongside it. A money cap is deliberately absent:
  # subscription lanes consume plan limits rather than metered cash, while time and attempts bind on
  # every lane.
  local model="" check="" max="${OSRC_LOOP_MAX:-6}" maxmin="${OSRC_LOOP_MAX_MINUTES:-0}" verb=edit task="" use_worktree=0
  local original_max="" max_set=0 prior_attempt=0

  # On resume the shape of the work is FIXED by the original run. Re-specifying the task, check, model
  # or verb would silently grade new work against old feedback, so those are read back from meta and
  # refused on the command line; only the attempt ceiling may be raised.
  if [ "$resume" = "1" ]; then
    task="$(sed -n 's/^task: //p' "$ldir/meta" 2>/dev/null)"
    check="$(sed -n 's/^check: //p' "$ldir/meta" 2>/dev/null)"
    model="$(sed -n 's/^model: //p' "$ldir/meta" 2>/dev/null)"
    max="$(sed -n 's/^max: //p' "$ldir/meta" 2>/dev/null)"
    verb="$(sed -n 's/^verb: //p' "$ldir/meta" 2>/dev/null)"
    maxmin="$(sed -n 's/^max-minutes: //p' "$ldir/meta" 2>/dev/null)"
    [ "$model" = "<default>" ] && model=""
    [ -n "$maxmin" ] || maxmin=0       # loops created before resume existed saved no time cap
    original_max="$max"
    prior_attempt="$(cat "$ldir/attempt" 2>/dev/null || echo 0)"
    case "$prior_attempt" in ''|*[!0-9]*) die "loop resume: corrupt attempt state in '$lid'" ;; esac
    [ -n "$task" ] && [ -n "$check" ] && [ -n "$max" ] && [ -n "$verb" ] ||
      die "loop resume: '$lid' has incomplete metadata and cannot be resumed safely"
    # A resumed --worktree loop must run in the same worktree; the existing setup block below will
    # restore the saved path/cd when this flag is set.
    [ -f "$ldir/worktree.json" ] && use_worktree=1
    grep -qx 'worktree: 1' "$ldir/meta" 2>/dev/null && use_worktree=1
  fi

  while [ $# -gt 0 ]; do case "$1" in
    -m|--model) [ "$resume" != "1" ] || die "loop resume: the model is fixed by the original loop"
                [ -n "${2:-}" ] || die "loop verify: -m needs a model"; model="$2"; shift 2 ;;
    --check)    [ "$resume" != "1" ] || die "loop resume: the check is fixed by the original loop"
                [ -n "${2:-}" ] || die "loop verify: --check needs a command"; check="$2"; shift 2 ;;
    --max)      [ -n "${2:-}" ] || die "loop $shape: --max needs a number"; max="$2"; max_set=1; shift 2 ;;
    --max-minutes) [ "$resume" != "1" ] || die "loop resume: the time bound is fixed by the original loop"
                [ -n "${2:-}" ] || die "loop verify: --max-minutes needs a number"; maxmin="$2"; shift 2 ;;
    --verb)     [ "$resume" != "1" ] || die "loop resume: the verb is fixed by the original loop"
                [ -n "${2:-}" ] || die "loop verify: --verb needs edit|yolo"; verb="$2"; shift 2 ;;
    --worktree) [ "$resume" != "1" ] || die "loop resume: the worktree is fixed by the original loop"
                use_worktree=1; shift ;;
    --)         shift; task="$*"; break ;;
    -*)         die "loop verify: unknown flag '$1'" ;;
    *)          task="$1"; shift ;;
  esac; done
  [ -n "$task" ]  || die "loop verify needs a task, e.g.: loop verify -m glm --check \"npm test\" \"make the auth tests pass\""
  [ -n "$check" ] || die "loop verify needs a --check command. External verification is MANDATORY — a loop that trusts the model's own 'done' is not a loop, it's a hope."
  case "$max" in ''|*[!0-9]*) die "loop $shape: --max must be a positive integer" ;; esac
  [ "$max" -ge 1 ] 2>/dev/null || die "loop $shape: --max must be >= 1"
  # Fractional minutes are allowed (0.5 = 30s): short verification loops are real, and forcing whole
  # minutes would make the only usable time bound a full minute.
  case "$maxmin" in ''|*[!0-9.]*|*.*.*) die "loop $shape: --max-minutes must be a number of minutes, e.g. 10 or 0.5 (0 = no time bound)" ;; esac
  local _maxsec; _maxsec="$(awk -v m="$maxmin" 'BEGIN{printf "%d", m*60}')"
  case "$verb" in edit|yolo) ;; *) die "loop $shape: --verb must be edit or yolo (the loop mutates files to fix them)" ;; esac
  local _loop_table_lane="" _loop_row="" _loop_cost_lane="" _loop_explicit=0
  if [ -n "$model" ]; then
    _loop_explicit=1
    _loop_row="$(resolve_model_row "$model")"
    [ -n "$_loop_row" ] && { _loop_row="${_loop_row#*|}"; _loop_table_lane="${_loop_row%%|*}"; }
    [ -n "$_loop_table_lane" ] || _loop_table_lane="$(lane_from_name "$model" 2>/dev/null)"
  fi
  _loop_cost_lane="$(_effective_lane "$_loop_table_lane" "${PROVIDER:-devin}" "$model" "$_loop_explicit")"
  # Resuming with the SAME ceiling would start at prior+1 and exit immediately having done nothing,
  # which reads as a second failure rather than a no-op. Demand a strictly larger ceiling instead.
  [ "$resume" != "1" ] || [ "$max_set" != "1" ] || [ "$max" -gt "$original_max" ] 2>/dev/null ||
    die "loop resume: --max must be greater than the original maximum ($original_max)"

  if [ "$resume" = "1" ]; then
    if [ "$max_set" = "1" ]; then
      local _mtmp
      _mtmp="$(mktemp "$ldir/meta.XXXXXX" 2>/dev/null)" || die "loop resume: cannot update metadata"
      awk -v newmax="$max" '/^max: / { print "max: " newmax; next } { print }' "$ldir/meta" > "$_mtmp" &&
        mv "$_mtmp" "$ldir/meta" || { rm -f "$_mtmp"; die "loop resume: cannot update metadata"; }
    fi
    printf 'resumed: %s\n' "$(date +%s)" >> "$ldir/meta" 2>/dev/null || die "loop resume: cannot update metadata"
  else
    lid="$(_new_job_id)"; ldir="$OSRC_HOME/loops/$lid"
    _mkdir_private "$ldir" || die "loop: cannot create loop dir under $OSRC_HOME/loops"
    { umask 077; printf 'task: %s\ncheck: %s\nmodel: %s\nmax: %s\nmax-minutes: %s\nverb: %s\nworktree: %s\nstarted: %s\n' \
        "$task" "$check" "${model:-<default>}" "$max" "$maxmin" "$verb" "$use_worktree" "$(date +%s)" > "$ldir/meta"; } 2>/dev/null || die "loop: cannot write metadata"
  fi
  # --worktree: run the delegate AND the acceptance check inside an isolated git worktree, so the
  # loop verifies exactly the tree it mutated. Reuses _worktree_setup (same as bg/fanout).
  local wt="" wbr="" wbase=""
  if [ "$use_worktree" = "1" ]; then
    if [ -f "$ldir/worktree.json" ]; then
      if have jq; then
        wt="$(jq -r '.path' "$ldir/worktree.json")"; wbr="$(jq -r '.branch' "$ldir/worktree.json")"; wbase="$(jq -r '.base_sha // ""' "$ldir/worktree.json")"
      else
        wt="$(sed -n 's/.*"path":"\([^"]*\)".*/\1/p' "$ldir/worktree.json")"
        wbr="$(sed -n 's/.*"branch":"\([^"]*\)".*/\1/p' "$ldir/worktree.json")"
        wbase="$(sed -n 's/.*"base_sha":"\([^"]*\)".*/\1/p' "$ldir/worktree.json")"
      fi
      [ -n "$wt" ] && [ "$wt" != "null" ] || die "loop verify: existing worktree metadata has no path: $ldir/worktree.json"
    fi
    if [ -z "$wt" ]; then
      local _wl
      if _wl="$(OSRC_WORKTREE=1 _worktree_setup "$lid")"; then
        wt="${_wl%%$'\t'*}"; _wl="${_wl#*$'\t'}"; wbr="${_wl%%$'\t'*}"; wbase="${_wl##*$'\t'}"
        if have jq; then jq -cn --arg p "$wt" --arg b "$wbr" --arg bs "$wbase" '{path:$p,branch:$b,base_sha:$bs}' > "$ldir/worktree.json"; else printf '{"path":"%s","branch":"%s","base_sha":"%s"}\n' "$wt" "$wbr" "$wbase" > "$ldir/worktree.json"; fi || die "loop verify: cannot record worktree"
      else
        die "loop verify: --worktree setup failed (not in a git repo, or branch exists?)"
      fi
    fi
    if [ -n "$wt" ] && ! cd "$wt" 2>/dev/null; then
      _wl="$(OSRC_WORKTREE=1 _worktree_setup "$lid")" || die "loop verify: cannot recreate missing worktree"
      wt="${_wl%%$'\t'*}"; _wl="${_wl#*$'\t'}"; wbr="${_wl%%$'\t'*}"; wbase="${_wl##*$'\t'}"
      if have jq; then jq -cn --arg p "$wt" --arg b "$wbr" --arg bs "$wbase" '{path:$p,branch:$b,base_sha:$bs}' > "$ldir/worktree.json"; else printf '{"path":"%s","branch":"%s","base_sha":"%s"}\n' "$wt" "$wbr" "$wbase" > "$ldir/worktree.json"; fi || die "loop verify: cannot update worktree metadata"
      cd "$wt" || die "loop verify: cannot cd into recreated worktree $wt"
    fi
  fi
  local _t0; _t0=$(date +%s)
  echo "[loop $shape] $lid — goal: \`$check\` passes. Guards: up to $max attempts$( [ "$_maxsec" -gt 0 ] && printf ' or %s min' "$maxmin" ), on ${model:-default lane}." >&2

  # Live state on disk from the FIRST second. A loop that only records its verdict at the end is
  # unobservable exactly while it matters: you cannot tell a loop grinding usefully from one that is
  # stuck, so you cannot decide whether to steer it or kill it.
  printf 'running\n' > "$ldir/state" 2>/dev/null || die "loop verify: cannot write state"
  local attempt="$(( prior_attempt + 1 ))" last_attempt="$prior_attempt"
  local feedback="" prev_fail="" have_prev=0 state="max_turns" mflag=""
  [ -n "$model" ] && mflag="-m"

  # Carry the previous run's failure across the restart. Without this a resumed loop hands the delegate
  # a blank slate (paying again for ground already covered) and re-arms the stall guard from scratch, so
  # a loop that was stuck repeating one failure would happily repeat it for another full budget.
  if [ "$resume" = "1" ] && [ "$prior_attempt" -gt 0 ]; then
    feedback="$(cat "$ldir/feedback" 2>/dev/null)"
    [ -n "$feedback" ] || feedback="$(cat "$ldir/check-$prior_attempt.out" 2>/dev/null)"
    if [ -n "$feedback" ]; then
      prev_fail="$(printf '%s' "$feedback" | _check_signature)"; have_prev=1
    fi
  fi

  while [ "$attempt" -le "$max" ]; do
    last_attempt="$attempt"
    printf '%s\n' "$attempt" > "$ldir/attempt" 2>/dev/null || die "loop verify: cannot write attempt"
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
    # EXTERNAL verification (the model never judges itself), under a wall-clock cap. The cap defaults
    # to 300s and is further clamped to the time left in --max-minutes, so a hung check can never eat
    # the whole run: without it the between-attempt time guard below is simply never reached.
    local check_timeout remaining cout crc
    if [ -n "${OSRC_CHECK_TIMEOUT:-}" ]; then
      case "$OSRC_CHECK_TIMEOUT" in ''|*[!0-9]*) die "OSRC_CHECK_TIMEOUT must be a positive whole number of seconds" ;; esac
      [ "$OSRC_CHECK_TIMEOUT" -ge 1 ] 2>/dev/null || die "OSRC_CHECK_TIMEOUT must be >= 1"
      check_timeout="$OSRC_CHECK_TIMEOUT"
    else
      check_timeout="${OSRC_CHECK_TIMEOUT_DEFAULT:-300}"
      if [ "$_maxsec" -gt 0 ]; then
        remaining=$(( _maxsec - ( $(date +%s) - _t0 ) ))
        [ "$remaining" -ge 1 ] || remaining=1
        [ "$remaining" -lt "$check_timeout" ] && check_timeout="$remaining"
      fi
    fi
    _loop_check "$check_timeout" "$check" "$ldir/check-$attempt.out"; crc=$?
    cout="$(cat "$ldir/check-$attempt.out" 2>/dev/null)"
    if [ "$crc" -eq 124 ]; then
      printf 'acceptance check timed out after %ss\n' "$check_timeout" > "$ldir/last_fail" 2>/dev/null || die "loop verify: cannot write failure state"
      echo "[loop verify] $lid: acceptance check timed out after ${check_timeout}s — counting attempt $attempt as failed. A check that hangs is a broken check, not a passing one." >&2
    else
      # Compute the failure summary first: grep legitimately finds nothing when the check passed
      # (empty/clean output), and under `set -o pipefail` that no-match exit-1 would otherwise trip
      # the write's `|| die`. Only an actual write failure should be fatal.
      local _lastfail; _lastfail="$(printf '%s' "$cout" | grep -aiE 'fail|error|assert' | head -1)"
      printf '%s\n' "$_lastfail" > "$ldir/last_fail" 2>/dev/null || die "loop verify: cannot write failure state"
    fi
    # Persist the feedback so a later `loop resume` can pick up exactly where this one stopped.
    printf '%s' "$cout" > "$ldir/feedback" 2>/dev/null || die "loop verify: cannot write feedback"
    if [ "$crc" -eq 0 ]; then state="success"; echo "[loop verify] $lid: acceptance check PASSED on attempt $attempt." >&2; break; fi
    # Stall guard: byte-identical check output on two consecutive attempts means the feedback is
    # not moving the delegate -> stop rather than burn the remaining budget on a spin. Keyed on a
    # seen-prior flag, NOT on prev_fail being non-empty — an empty check output (e.g. a bare
    # `false`) is still a repeatable failure that should trip the guard.
    local csig; csig="$(printf '%s' "$cout" | _check_signature)"
    if [ "$have_prev" = "1" ] && [ "$csig" = "$prev_fail" ]; then
      state="blocked"; echo "[loop verify] $lid: the check reported the same failures two attempts running (timestamps and run ids ignored, so this is genuinely no new progress) — stopping to avoid a spin. Inspect $ldir, then steer or escalate a tier." >&2; break
    fi
    prev_fail="$csig"; have_prev=1; feedback="$cout"
    # Time guard: checked BETWEEN attempts so a run in progress is never abandoned half-done.
    if [ "$_maxsec" -gt 0 ] && [ $(( $(date +%s) - _t0 )) -ge "$_maxsec" ]; then
      state="max_time"
      echo "[loop verify] $lid: hit the ${maxmin}-minute time bound after $attempt attempt(s), still failing. Stopping. Inspect $ldir — the last check output shows how close it got." >&2
      break
    fi
    attempt=$(( attempt + 1 ))
  done
  printf '%s\n' "$state" > "$ldir/state" 2>/dev/null || die "loop verify: cannot write final state"
  # Report the selected lane's cost class with attempts and elapsed time. A fallback can change lanes,
  # and each delegate receipt records that hop separately.
  local _spent=$(( $(date +%s) - _t0 ))
  printf '>>> [loop verify] used %s attempt(s) over %sm%ss on %s. Initial route: %s.\n' "$last_attempt" "$(( _spent / 60 ))" "$(( _spent % 60 ))" "${model:-the default lane}" "$(_lane_cost_disclosure "$_loop_cost_lane")" >&2
  echo "[loop verify] $lid final: $state  ·  attempts + check output in $ldir" >&2
  # A loop that ran out of room is not a dead end: say so, with the exact command, while the state is fresh.
  case "$state" in
    blocked|max_turns|max_time)
      echo "[loop verify] $lid is resumable — it keeps its task, check and last failure: ./outsourcerer.sh loop resume $lid --max $(( max + 3 ))" >&2 ;;
  esac
  if [ -n "$wt" ]; then
    local hsha dirty=false ahead=0
    hsha="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
    [ -n "$(git -C "$wt" status --porcelain 2>/dev/null | head -1)" ] && dirty=true
    ahead="$(git -C "$wt" rev-list --count "${wbase:-HEAD}..HEAD" 2>/dev/null)"; ahead="${ahead:-0}"
    if have jq; then jq -cn --arg p "$wt" --arg b "$wbr" --arg bs "$wbase" --arg hs "$hsha" --argjson d "$dirty" --argjson a "$ahead" '{path:$p,branch:$b,base_sha:$bs,head_sha:$hs,dirty:$d,ahead:$a}' > "$ldir/worktree.json"; else printf '{"path":"%s","branch":"%s","base_sha":"%s","head_sha":"%s","dirty":%s,"ahead":%s}\n' "$wt" "$wbr" "$wbase" "$hsha" "$dirty" "$ahead" > "$ldir/worktree.json"; fi || die "loop verify: cannot update worktree metadata"
    printf '[worktree] loop %s: branch %s at %s (ahead %s, dirty %s) — inspect/merge, then: outsourcerer cleanup %s\n' "$lid" "$wbr" "$wt" "$ahead" "$dirty" "$lid" >&2
  fi
  echo "$state"
  case "$state" in success) return 0 ;; blocked) return 3 ;; *) return 2 ;; esac   # max_turns/max_time share 2: both mean "ran out of room, not converged"
}

main() {
  # Mint this run's marker id once, and export it so the prompt the delegate receives and every
  # supervisor that grades its output agree on the same value. A detached bg job re-enters this
  # script as a fresh process and inherits it; if it ever arrives unset, one is minted there and the
  # prompt/reader in THAT process still match each other.
  [ -n "${OSRC_MARK:-}" ] || OSRC_MARK="$(_new_mark)"
  export OSRC_MARK
  # Surface neglected jobs on EVERY invocation. The orchestrator forgetting to watch is the observed
  # failure, so the reminder has to come from the tool at the moment of next contact, not from a rule
  # someone has to remember mid-session. Suppressed inside a detached job (it IS the work) and for the
  # commands whose whole purpose is already to look.
  case "${1:-}" in
    __runjob|__heartbeat-beacon|watch|status|result|logs|cancel|gc|rundown|bearings|"") ;;
    *) [ "${OSRC_STREAM:-0}" = "1" ] || _warn_unwatched || true ;;
  esac
  # GLOBAL flags are accepted in ANY order before the subcommand (and --provider/--cloud-ack are
  # ALSO accepted after it, via _consume_flags/parse_model). Audits showed a misplaced --cloud-ack
  # being read as an "unknown subcommand" and costing whole retry round-trips -- never again.
  while :; do
    case "${1:-}" in
      --provider) [ -n "${2:-}" ] || die "--provider requires a name (devin|cc|codex|droid|cursor|hermes|warp|gemini|gm|claudex|local)"
                  PROVIDER="$2"; PROVIDER_EXPLICIT=1; shift 2 ;;
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
  case "$cmd" in ""|-h|--help|help|--version|-V|doctor|brief|mode|tap|parity|parity-*) ;; *) _state_home_preflight ;; esac
  case "$cmd" in
    --version|-V) echo "outsourcerer $OSRC_VERSION"; exit 0 ;;
    __runjob) run_job "$@" ;;                             # internal: detached supervised job (cmd_bg)
    __heartbeat-beacon) _heartbeat_beacon "$@" ;;          # internal: persistent fleet heartbeat leader
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
    crew)        cmd_crew "$@" ;;                          # transactional write-swarm: fanout --worktree edit -> grade -> revert-or-promote
    loop)        cmd_loop "$@" ;;                          # bounded delegate->check->retry loop (loop verify); recipes in references/loops.md
    status)      cmd_status "$@" ;;                        # job table / one job's state
    rundown)     cmd_rundown "$@" ;;                       # refresh discovery, then render the fleet digest
    bearings)    cmd_bearings "$@" ;;                      # render the last normalized fleet snapshot
    watch)       cmd_watch "$@" ;;                         # poll a job until terminal (or --for N)
    result)      cmd_result "$@" ;;                        # print a job's final message (last.txt)
    logs)        cmd_logs "$@" ;;                          # tail a job's raw log (forensics only)
    cancel)      cmd_cancel "$@" ;;                        # kill a job + mark canceled
    cleanup)     cmd_cleanup "$@" ;;                       # remove a job/fanout git worktree (conservative)
    gc)          cmd_gc "$@" ;;                            # remove old completed job dirs (gc --older-than DAYS)
    tab)         cmd_tab "$@" ;;                           # the Tab: ledger / savings summary
    estimate)    cmd_estimate "$@" ;;                      # quote table across the chain + Opus
    suggest|deals) cmd_suggest "$@" ;;                     # live low-cash and plan-included models
    advise)      cmd_advise "$@" ;;                        # task-aware model recommendation with benchmark data
    second-opinion|second) second_opinion "$@" ;;         # 2 cheap models; disagree -> escalate
    image)       cmd_image "$@" ;;                         # Gemini text-to-image (nano-banana default); prints file path
    parity-codex)  parity_codex ;;                         # reverse bridge: Codex -> outsourcerer insource
    parity-droid)  parity_droid ;;                         # reverse bridge: Factory droid -> outsourcerer (global ~/.factory/AGENTS.md)
    parity-cursor) parity_cursor ;;                        # reverse bridge: Cursor -> outsourcerer (repo-root AGENTS.md)
    parity-hermes) parity_hermes ;;                        # reverse bridge: Hermes -> outsourcerer (skill symlink into ~/.hermes/skills)
    continue|cont)
      [ "$PROVIDER" = "devin" ] || die "continue is Devin-only for now (provider=$PROVIDER). For OR interactive follow-ups use the sibling tmux harness: scripts/run-or-{model,codex}.sh"
      continue_turn "$@" ;;
    session)
      session "$@" ;;   # provider-aware: devin | codex | cc (see session start)
    parity)
      [ "$PROVIDER" = "devin" ] || die "parity syncs into Devin only. cc inherits your Claude skills/MCP natively; codex uses its own AGENTS.md + MCP."
      parity ;;
    ""|-h|--help|help)
      sed -n '2,113p' "$0" | sed 's/^# \{0,1\}//'
      ;;
    *) case "$cmd" in
         -*) die "'$cmd' looks like a flag, not a subcommand. Global flags (--provider X, --cloud-ack) are accepted before OR after the subcommand, but a subcommand is required. Example: $0 run --provider cc --cloud-ack \"task\"" ;;
       esac
       die "unknown subcommand '$cmd' (try: doctor|brief|mode|consent|models|run|research|edit|yolo|explore|deals|bg|fanout|status|rundown|bearings|watch|result|logs|cancel|cleanup|tab|estimate|suggest|advise|second-opinion|image|continue|session|parity|parity-codex|parity-droid|parity-cursor|parity-hermes; providers: devin|cc|codex|droid|cursor|hermes|warp|gemini|gm|claudex|local)" ;;
  esac
}
main "$@"
