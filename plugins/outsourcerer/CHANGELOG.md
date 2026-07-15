# Changelog

All notable changes to the Outsourcerer plugin are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versioning is [SemVer](https://semver.org/).

## [0.4.7] - 2026-07-15

Torture-room hardening: 16-agent security/reliability gauntlet findings applied. No breaking changes. All 21 conformance tests + 62 advise tests pass.

### Security
- **API keys no longer appear in process arguments.** All curl calls to OpenRouter/Gemini now write bearer tokens to a `chmod 600` temp header file referenced via `@header-file`, not `-H "Authorization: Bearer ..."` on the command line (visible to `ps`/other users).
- **SSRF blocked on local-lane URLs.** `OSRC_LOCAL_URL` / `OLLAMA_HOST` pointing to a non-loopback address is refused; only `127.0.0.1`, `::1`, and `localhost` are accepted.
- **SSRF blocked on image-gen response URLs.** The OpenRouter image lane validates the returned URL scheme/host before fetching.
- **`rm -rf` on JSON-sourced paths is containment-checked.** `cmd_cleanup` refuses to delete a path that does not contain `.outsourcerer/worktrees/`, preventing a poisoned JSON payload from targeting arbitrary directories.
- **`OSRC_PROTECTED_PATHS` word-splitting fixed.** Unquoted expansion that could break on paths with spaces now uses `IFS=:` safe splitting.

### Reliability
- **Portable version sort.** `sort -V` is wrapped in a `vsort` helper that falls back to numeric sort on platforms without it.
- **Atomic `models.json` refresh.** `refresh_models` now writes to a `mktemp` temp file and `mv`s into place, matching the benchmark cache pattern. Prevents partial-write corruption on concurrent refresh or crash.
- **PID reuse protection.** Background supervisor PID files now record a start-time; `status`/`gc` verify the PID is still the same process before trusting it, preventing PID-recycling from reaping an unrelated process.
- **Stale-job reaping in `gc`.** A `running` job whose PID is dead is auto-healed to `interrupted` and becomes eligible for GC.
- **EXIT trap cleans header temp files.** Bearer-token temp files (`.hdr.*`) are now cleaned on exit alongside `with-mcp-$$.json`.
- **`second_opinion` detects upstream failures.** Empty model output (network/key failure) is no longer treated as "consensus on empty string"; both-empty dies, one-empty uses the other, premium-empty dies.
- **`fanout wait`/`collect` return nonzero on failure.** A batch with any failed/blocked/timed-out member now exits nonzero so orchestrators can detect partial failure.
- **Fanout mutating-verb warning.** `fanout --verb edit|research|yolo` without `--worktree` prints a collision warning.
- **tmux session collision check.** `session start` refuses to kill an existing session; it reports the collision and tells the user to stop or reattach.
- **`continue_turn` captures exit code.** A failed continue now propagates nonzero instead of always exiting 0.
- **Test fake CLI `eval` hardened.** The call-counter in test fakes validates `n` is numeric before the indirect `eval`, preventing injection via a poisoned count file.

### Added
- **`--version` / `-V` flag.** Prints `outsourcerer <version>` and exits.
- **Version in `doctor` output.** The doctor banner now includes the version number.
- **`OSRC_VERSION` variable** in the script as the single source of truth for the version.

## [0.4.3] - 2026-07-14

Security + accounting: the cloud gate now covers every off-machine path, and cost accounting stops both double-counting and undercounting. No breaking changes.

### Security
- **`image` and `second-opinion` now run the cloud gate.** Both shipped prompts to a cloud API without the secret-scan hard-block + disclosure that `run`/`bg`/`fanout` enforce; they now gate before any dispatch, so a repo containing a real credential file is refused and every cloud send is disclosed. The `:free` "may train on your data" disclosure now fires for a `:free` model in any position (including a comma-joined `second-opinion` model pair).

### Fixed
- **Cash is no longer double-counted under concurrent `fanout`.** The account-usage delta fallback (which attributed every concurrent job the sum of all in-flight spend) is removed; per-generation cost stays authoritative and, when a lookup is incomplete, the receipt falls to a clearly-labeled `~` estimate instead of a wrong "measured" number.
- **Per-generation cost no longer undercounts on a partial lookup.** A run whose generations only partially resolve now reports the labeled estimate rather than a partial sum masquerading as the exact cost.

## [0.4.2] - 2026-07-14

Truthful cost accounting: the Tab now reports what a run actually cost, on the lane it actually ran. No breaking changes.

### Changed
- **The Tab splits three ways: cash, plan, and free.** A delegation is now bucketed by its *resolved* lane, not the raw provider string. Local/on-your-hardware runs (Ollama, LM Studio, llama.cpp) and keyless work are no longer miscounted as cash spend — they get their own "on your hardware (local): $0 cash AND $0 plan, fully private" line. Subscription lanes (ChatGPT/Claude/Antigravity) stay in the plan bucket; only genuinely cash-billed lanes (OpenRouter, paid APIs) count toward cash.
- **The recorded lane mirrors where a run actually dispatched.** A background run records the effective lane (e.g. `-m glm --provider devin` records the Devin lane, not the OpenRouter default), so `bg`/`fanout` receipts and the Tab stop mislabeling a plan run as cash. Local-prefix models (`ollama:`/`lmstudio:`/`lms:`/`local:`) and `--provider local` always record local; an implicit (no `-m`) run records the provider's default lane.

### Fixed
- **`bg`/`fanout` reject a non-verb in the verb position up front.** `bg -m glm "..."` (a flag where the verb should be) previously ran the full window on the wrong default model before failing; it now fails fast with the correct usage. The verb allowlist is centralized, so `fanout --verb explore` is accepted (it was wrongly rejected).

## [0.4.1] - 2026-07-13

Security transparency: a plain-language "what leaves your machine" page, and the audit numbers refreshed to the current scanner with every finding triaged by name (no suppressions). No behavior changes.

### Docs
- **SECURITY.md — new "Your repo & what leaves the machine" section.** Spells out that local lanes send nothing, cloud lanes are gated by a credential hard-block (root + nested, fails closed), every cloud dispatch is disclosed, and secret values are counted-not-printed. README security section links to it.
- **Audit numbers refreshed, in full.** The "Latest scan" table now reflects the current repo-forensics run with every finding triaged by name and **no `.forensicsignore` suppressions** — the "critical" flags are the localhost inference shim forwarding to your own model (and its test); the rest are background-job supervision, one scoped key read, test fixtures, and localhost references.

### Changed
- Reworded an internal image-generation prompt and one documentation sentence to drop confirmation-bypass / silent-execution phrasings a static scanner flags (no behavior change). Made a secret-scan test fixture obviously fake. Removed transient local `.pyc` bytecode from the working tree (git-ignored, never shipped).

## [0.4.0] - 2026-07-13

Security and reliability hardening for the cloud gate, the transport-vs-task retry classifier, and the parallel job machinery. No breaking changes.

### Security
- **The credential hard-block now runs on every cloud delegation.** The scan that refuses to send a repo containing a real `.env` / `id_rsa` / `credentials` file to a cloud lane now runs *before* any acknowledgement short-circuit, so an inherited `OSRC_CLOUD_ACK`/`ACKED` (e.g. in a detached `bg`/`fanout` child, or a nested invocation) can no longer skip it. The scan also sweeps **nested** credential files (bounded depth, capped, vendored dirs pruned), not just the repo root, and **fails closed** if it cannot complete.
- **`bg`/`fanout` cloud gate is now per-job.** The disclosure/ack is resolved from each job's *effective* lane, so a cloud-routed agent inside an otherwise-local batch is gated correctly (and an all-local batch stays exempt). `--cloud-ack` is honored only as a leading flag — a task string that merely equals `--cloud-ack` (after `--`) can no longer self-ack.
- **Directory-name shell-injection fixed** in `session start`: the working directory is no longer interpolated into a tmux shell command (tmux already opens the pane there). Detected secret values are never printed to stderr/logs — only a redacted count is surfaced.

### Fixed
- **Transport-vs-task retry classification rewritten (two-pass, line-anchored).** The fallback chain now retries only genuine transport/infra failures (connection / HTTP status / rate-limit / auth / timeout), never a failed *task* whose output merely quotes such phrases — so a red test or an assertion string can't trigger an auto-retry of mutating work. Real curl/HTTP/socket diagnostics are still caught, and previously-missed signatures (`could not resolve host`, `operation timed out`, `socket hang up`, `HTTPError: 5xx`) now escalate correctly.
- **Parallel job machinery hardened.** Job directories are claimed **atomically** with more entropy (no silent collision under high-parallel fanout); a launch that can't start (unwritable filesystem, non-executable supervisor) now **fails loudly** instead of emitting a phantom job id, and `fanout` returns nonzero if any job fails to launch.
- **Temp-file and accounting hygiene.** Capture/result temp files are created private (`umask 077` + restrictive perms) with the directory verified writable before use; the cost ledger appends under a bounded-wait lock with a best-effort fallback and a one-time warning instead of silently dropping a record under lock contention.

## [0.3.1] - 2026-07-11

Run any agent library as a routed crew, isolate parallel editors in git worktrees, and a class-wide fix for the headless permission wall. No breaking changes.

### Added
- **Run any agent library as a crew, no file edits required.** `fanout --agents ./crew` runs a folder of role definitions (your own, or a library like [agency-agents](https://github.com/msitarzewski/agency-agents)) as one supervised job each. Route each specialist to its own engine three ways, editing files last: nothing (the whole crew runs on the default lane), a one-line name map `--route 'security-*=glm-5.2, *architect*=sol, *=haiku'`, or per-agent `model:`/`effort:`/`lane:` frontmatter. Precedence is unambiguous: global `-m` > `--route` > frontmatter > default. `--task "..."` drops your task into every role so a pure library of personalities runs against your repo unmodified.
- **Opt-in git-worktree isolation.** `--worktree` (on `bg` or `fanout`) runs each job in its own disposable worktree (`.outsourcerer/worktrees/<job-id>` on branch `outsourcerer/<job-id>`) so parallel **editing** crews never collide. Worktrees are preserved after the run (never auto-deleted); `cleanup <job-id|fanout-gid> [--force]` removes them but **refuses** to bin one with uncommitted or unmerged work unless forced. No auto-merge, you own integration.
- **"Working with orchestrators"** README section: Outsourcerer is the crew engine, your orchestrator (or a framework like firstmate) is the captain.

### Fixed
- **Headless permission wall removed, as a class, and self-healing.** A delegated `edit` to a file under a harness-protected config dir (`~/.claude`, `~/.codex`) wedged forever, because headless `claude -p --permission-mode acceptEdits` can't answer the interactive permission prompt those "sensitive files" require. Now every `claude -p` lane (OpenRouter, native, local-agentic) **escalates that one run** to `bypassPermissions` on a protected path (with an `OSRC_NO_BYPASS=1` fail-loud switch), and `_supervise` **aborts any lane** (claude/codex/devin/local) that hits repeated permission/sandbox denials with a clear next-step instead of spiraling. `permission-blocked` is now a first-class terminal job state.
- **Agentic-local tool-result ordering.** The shim emitted a tool result *after* companion user text, which OpenAI-compatible servers reject (a `tool` message must immediately follow the assistant `tool_calls`); tool results now precede text, so multi-turn agentic-local stops 400-ing. Also: the shim emits a valid empty text block on a content-less stream.
- **Worktree safety.** A failed `cd` into a worktree no longer runs the job in the wrong directory while pretending to be isolated; `cleanup` re-reads **live** git state (not a stale snapshot) before deleting, so it can't `--force`-wipe edits made after the job.

## [0.3.0] - 2026-07-11

A local inference lane (run on your own machine), a foreground watchdog so nothing hangs unattended, and live tool-call observability. No breaking changes.

### Added
- **Local inference lane, run delegations on your own machine.** Point a delegation at a local model on Ollama or LM Studio (`-m ollama:<model>` / `-m local`, or `--provider local`): keyless, `$0` cash, `$0` plan, nothing leaves the building. `doctor` auto-detects a running local server and offers the private lane; plain `run` streams text with zero setup. An **agentic-local** path (a local model with tool use inside the harness) is included but **experimental**, pending certification against a real Ollama / LM Studio.
- **Foreground watchdog.** `run`/`research`/`edit`/`yolo` are now supervised like `bg`, instead of running unguarded. A marker-aware **teardown deadline** (kicks in once the task emits its `OSRC::DONE`/`BLOCKED` marker) plus the tier **hard cap** kill a wedged delegate and report it, catching the case where a model finishes the work but the process never exits (e.g. codex completes, then an MCP-auth worker dies and a Stop hook loops forever). Recursive tree-kill reaps grandchildren (MCP workers) on macOS, and `INT`/`TERM` traps make Ctrl-C terminate the whole tree. Tunable via `OSRC_FG_TIMEOUT` / `OSRC_FG_TEARDOWN` / `OSRC_FG_GUARD`.
- **Live tool-call observability.** `status` / `fanout status` show an `R# W# B#` (reads / writes / bash) tally so you can see what a job is actually doing, plus an `!exploring(0-writes)` flag for a mutating job that has read for a while without writing a single file. A BUILD DISCIPLINE preamble is auto-injected for mutating verbs (write early, don't spiral on exploration).
- **Machine-readable job state for orchestrators.** `status --json` (a single job or the whole board) and `fanout status --json` emit a versioned (`schema_version:"1"`) envelope, job id, label, terminal state, exit code, provider/model/tier, the read/write/bash tally, last `OSRC::` marker, and result/log paths, so an orchestrator skill (or a framework like [firstmate](https://github.com/kunchenguid/firstmate)) can run its crew on Outsourcerer and parse structured state instead of scraping text. See the "Working with orchestrators" section in the README.

### Changed
- **Routing steer toward supervised runs.** The skill now tells the orchestrator to prefer `bg` (watchdog + receipt + measured cost) for anything substantial, unattended, on a frontier/reasoning model, or on the codex-native lane (which can wedge on teardown), and to reserve bare foreground for quick, watched one-shots. Live steering still routes to `session`.

### Fixed
- **Recursive process-tree kill.** The watchdog's terminator walked only one level (`pkill -P`), so a hung codex's MCP grandchildren survived a kill. It now discovers the full descendant tree and signals deepest-first (TERM, grace, KILL). Hardens the `bg`/`fanout` supervisor and `cancel` too.

[0.3.0]: https://github.com/alexgreensh/outsourcerer/releases/tag/v0.3.0

## [0.2.0] - 2026-07-11

Parallel multi-agent fan-out, first-class reasoning-effort control, and a capability-vs-price tier model. No breaking changes.

### Added
- **`fanout`, parallel multi-subagent across any provider.** Run N delegations at once (one job per agent-prompt file with `--agents DIR`, one per line with `--tasks FILE`, or inline with `-- "t1" "t2"`), concurrency-capped with `--max`, then `fanout status|wait|collect|list <gid>`. Builds on the supervised background-job machinery (watchdog, tier windows, cost ledger). This is the supported way to run a multi-agent gauntlet (e.g. a multi-agent review skill) through the Outsourcerer, N fast headless jobs, not 16 interactive sessions.
- **`--effort minimal|low|medium|high|xhigh|max`** (alias `--reasoning`), universal reasoning-effort control. Native on codex lanes (`model_reasoning_effort`) and Claude lanes (`MAX_THINKING_TOKENS`); advisory prompt-directive on Gemini. The dispatch banner always states native vs advisory, effort is never silently dropped. Forwards through `bg` and `fanout`.

### Changed
- **Capability tiers decoupled from price.** New `capable` tier for frontier-capability, budget-priced open-weight models (GLM-5.2, Hy3, DeepSeek-v4-pro, ~Opus-4.8 class): they now get the thin, high-autonomy prompt scaffold and generous stall windows of a frontier model instead of the strict budget "worker-drone" work order and tight windows that could stall-kill a reasoning model mid-think. Capability signal (model family) is consulted before price.

### Fixed
- **OpenRouter alias resolution on the `cc`/`codex` lanes.** `-m glm` now resolves to `z-ai/glm-5.2` instead of sending the bare alias (which OpenRouter rejected with `400 glm is not a valid model ID`).
- **Cross-lane tool self-heal.** When a codex→OpenRouter run's upstream provider rejects Codex's native tool types (a `namespace`/custom tool-type 400 in Codex 0.144+), the skill automatically re-runs the same model on the `cc` lane, whose standard tool format every OpenRouter model serves. Tool-using fan-outs stay green regardless of provider.
- **Job classification honors the LAST `OSRC::` marker**, so an agent that ends with `OSRC::DONE` is no longer mislabeled `blocked` just because the protocol text (which contains "OSRC::BLOCKED") appeared earlier in its output.
- **Portable `run-or-model.sh` PATH**, no longer pins a specific Node version; resolves the newest nvm node bin dynamically and preserves the caller's PATH.

[0.2.0]: https://github.com/alexgreensh/outsourcerer/releases/tag/v0.2.0

## [0.1.0] - 2026-07-11

First public release. Converts the Outsourcerer skill into a distributable, cross-harness plugin.

### Added
- **Plugin packaging**: `.claude-plugin/plugin.json` manifest + marketplace entry so users install and receive versioned updates via `/plugin`.
- **Delegation lanes**: OpenRouter via Claude Code (`cc`) and Codex (`codex`); native premium lanes selected by model alias (Sol/Terra/Luna on the Codex/ChatGPT sub; Fable/Opus/Sonnet/Haiku on the Claude sub); Devin.
- **Gemini / Antigravity lane**: `gemini-pro`, `gemini-flash`, `gemini-flash-lite` (text/agentic via the `gemini` CLI headless mode) and `nano-banana` (`gemini-2.5-flash-image`) for image generation via the `image` subcommand. Documented as the recommended lane for visual / UI-UX review.
- **Tier-aware prompt wrapping** (frontier / mid / budget) per backend.
- **Liveness watchdog** with background jobs: `bg`, `status`, `watch`, `result`, `logs`, `cancel`.
- **Cost ledger**: `tab` (real per-generation OpenRouter cost captured on `bg` runs), `estimate`.
- **Live model discovery**: `suggest` lists cheap and free models available per platform right now (OpenRouter free/cheapest via the live catalog, Devin plan models via the CLI), so it tracks the ecosystem as it changes. Ranks by price/availability; pair a cheap pick with `second-opinion`.
- **Consensus-gated second opinion**; per-task capability injection via `--with skills=` / `mcp=`.
- **Interactive sessions** (`session start|send|read|model|stop`) via tmux for ALL providers (Devin, codex sol/terra/luna, claude fable/opus/...), the mode that brings the full workshop (tool exec + skills + MCP) and is watchable; headless `run`/`bg` stays for small tasks.
- **Verified claude-native lane**: reads the model actually used from `modelUsage` and prints a `[verified]`/`[WARNING]` receipt, so it can never mislabel (e.g. an Opus run as Fable). Works from inside Claude Code (strips nested env, OAuth-aware).
- **Self-healing**: codex `code_mode_host` auto-disabled when its host binary is missing (no more file-read hangs); doctor preflights per lane.
- **Real cost Tab**: per-generation OpenRouter cost read back from the provider (the harness's own number ran ~28x high); honest cash vs plan-limit columns.
- **Live model discovery** (`suggest`): cheap and free models available per platform right now, read from each live catalog.
- **Security posture**: single-key extraction from `~/.env` (never `set -a`), recursion-depth guard, escalation gating. repo-forensics audited (0 critical / 18 high / 1 medium, all triaged).

[0.1.0]: https://github.com/alexgreensh/outsourcerer/releases/tag/v0.1.0
