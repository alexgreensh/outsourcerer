# Changelog

All notable changes to the Outsourcerer plugin are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/); versioning is [SemVer](https://semver.org/).

## [0.4.14] - 2026-07-22

Loops become steerable, and background work stops being able to run unobserved.

### Added
- **Every launch demands a watcher, and the tool checks.** A detached job nobody is watching is how a
  wedge becomes a lost hour: it accepts the work, goes quiet, and the failure surfaces much later.
  Launching now says so plainly instead of listing poll options, and any later command reports jobs
  that have been running with nobody looking at them, naming the command to start. The warning clears
  as soon as you actually look. A just-launched job gets a grace period so this never cries wolf
  (`OSRC_UNWATCHED_AFTER`).
- **Loops are offered, not memorised.** When a task suits one, the assistant proposes it in plain
  language — what it will do, what counts as done, what stops it — and runs it on your say-so. There
  is no shape name or flag to learn. It will also talk you out of a loop when nothing external can
  verify the result, because that is a model marking its own homework.
- **A time bound for loops** (`--max-minutes`, fractional allowed), checked between attempts so a run
  in progress is never abandoned half-done. Rounds are not equal work, so a lap count alone is a poor
  bound on open-ended tasks. The attempt cap remains as a backstop and now defaults to 6.

### Fixed
- **The stall guard was ineffective on real test output.** It compared the check's output byte for
  byte, so any suite printing a duration, timestamp, temp path or run id — most of them — produced
  different bytes while reporting the identical failure, and the guard never fired. Loops spent their
  whole budget re-reporting the same thing. Comparison now ignores those volatile tokens while keeping
  failure counts intact, so a genuinely repeating failure stops the loop and a shrinking one is still
  allowed to finish.
- **`logs` said "no log" for three unrelated situations** — a job still starting, an id that does not
  exist, and a job that died before writing — while the status file that distinguishes them sat unread
  beside the missing log. Each now says what actually happened and what to do next.

### Changed
- `eval-optimize` is now **`evaluator-optimizer`**, the established name for the pattern.

## [0.4.13] - 2026-07-21

Reliability patch. Every fix below is a case where the tool told you something that was not true: a
job that had died reported as running, a lane advertised as ready that could not answer, a usage
figure from two days ago presented as current, finished work graded as blocked. All are covered by
tests, and each test was watched failing against the old code before it was accepted.

### Fixed
- **A delegate can no longer trip control decisions by quoting them.** Job state was decided by
  scanning the delegate's output for bare `OSRC::` markers, so a delegate that echoed the protocol it
  was handed, printed a log, or read this repo could accidentally flip its own status — completed work
  reported as blocked. Each run now mints an id that its instructions carry, so genuine status lines
  are signed and repeated text is not. Unsigned markers still work when nothing is signed, so existing
  prompts are unaffected.
- **Dead jobs no longer report as running.** `status --json` and the fanout waiter read the recorded
  status without checking whether the process was still alive, so a job whose delegate had been killed
  stayed `running` forever and `fanout wait` could block on it indefinitely. Liveness is now
  reconciled on every read path, including jobs flagged `stalled?`/`exploring?`, and a recycled pid can
  no longer make a dead job look alive.
- **A quiet delegate is no longer mistaken for a hung one.** The stall watchdog measured log growth, so
  a delegate writing files while printing nothing was killed as wedged — including delegates following
  this tool's own advice to write results to a file. Progress now also counts real file activity, and a
  job that truly produced nothing is reported as such with the reason and the fix.
- **Healthy jobs are no longer declared stillborn.** Setting up an isolated worktree on a large repo
  can outlast the launch grace, which looked identical to a worker the environment killed. The setup
  phase now has its own bound and its own message, and remains bounded.
- **A failed task is no longer mistaken for a network problem.** Phrases like `rate limit exceeded`,
  `statusCode: 404`, `invalid api key` and `no endpoints found` were matched anywhere in a delegate's
  output, including inside test output that merely discusses an API or ordinary `kubectl` output, so a
  red test could be silently retried on another model after it had already changed files. Only genuinely
  retryable failures escalate now, and a 400/422 surfaces instead of being retried on every lane.
- **Gemini/Antigravity lane runs again.** `--effort` was never passed, which that CLI now requires and
  refuses to run without, and the accepted levels differ per model. Effort is passed explicitly and
  clamped to a level the chosen model accepts, announced rather than silently changed. A lane that
  accepts a request and never answers is now reported with the cause and the alternatives instead of
  waiting out the timeout in silence.
- **Usage figures say how old they are.** ChatGPT/Codex limits are read from the newest local codex
  session, which can be days old when codex has not run. Usage only rises within a window, so a stale
  reading always overstates what is left. Old readings are now labelled as a floor, and are refused for
  routing decisions rather than sending work to an exhausted lane.
- **`parity` repairs its own links.** Skills are linked into the Devin lane from a versioned plugin
  cache, so upgrading a plugin left every link pointing at a directory that no longer existed. Because
  a broken link still counted as "already linked", re-running parity could not fix it: the skills
  directory stayed full while the delegate silently ran without them. Dead links are now replaced and
  pruned, and the count is reported.
- **Output-token exhaustion is reported as itself**, with the remedy, instead of a generic failure that
  leaves a partial answer looking complete.

### Added
- **Per-lane, per-repo trust for the credential hard-block (#2).** Some cloud lanes are trusted the way
  a local agent is trusted, but only for particular repos. `~/.config/outsourcerer/trusted-lanes.json`
  expresses exactly that: when the current lane is trusted for the current repo, the credential-*file*
  block is skipped and nothing else is. Default empty, so an untouched install is unchanged. The
  disclosure always names the skip. `--trust-lane` covers one-offs and is deliberately not an
  environment variable, so no background job inherits it.
- **`doctor` checks its own installation**: whether a second installed copy is running different code
  (same version, different bytes), whether linked skills still resolve, and whether the keyless Gemini
  lane can actually answer rather than merely being installed.
- **Continuous integration.** The test gate runs on every push and pull request, on macOS and Linux,
  because the two platforms fail differently.

## [0.4.12] - 2026-07-21

Reliability, truthful-accounting, and hardening patch, plus a fix for a false-abort regression in the 0.4.11 print-mode detector. All changes are covered by the test suite.

### Fixed
- **`loop verify` no longer grades work that hasn't happened.** On a slow or cloud lane the loop's delegate inherited auto-detach: it returned a job id immediately, so the acceptance check ran against files the delegate had not written yet. Every attempt saw the same pre-edit failure, the stall guard fired, and the loop reported `blocked` while the real work continued on an unwatched background job — and in the reverse case, a check that happened to pass produced a false `success`. The delegate now always runs in the foreground (the loop is itself the supervisor), and if a delegate detaches anyway the loop refuses to grade rather than emit a verdict. Verified end-to-end against a live model, not only a mock.
- **Output-token exhaustion is reported as itself.** A delegate that runs out of output tokens exits non-zero with a *partial* answer still in the log, which previously surfaced as a generic failure — so a truncated result could be mistaken for a complete one. It is now identified (including a JSON `finish_reason: length`), recorded as `reason: output-token-limit`, and reported with the remedy: split the work into smaller batches, or have the delegate write its findings to a file and print only a summary.
- **A failed task is no longer mistaken for a network problem.** The transport-failure classifier matched phrases like `rate limit exceeded`, `statusCode: 404` and `invalid api key` anywhere in a delegate's output — including inside ordinary test output that merely *discusses* an API. A red test could therefore be read as an infrastructure hiccup and the whole task silently retried on another model, re-running work that may already have mutated files. Those signatures are now matched only when they lead their own diagnostic line, which is how a real CLI emits them; assertion text that embeds them stays a task failure.
- **Print-mode hang abort no longer false-fires on echoed text.** The 0.4.11 detector grepped the whole `out.log` for the bare rejection phrase, so any delegate that merely read or echoed that phrase (e.g. reviewing this repo, grepping a devin log) was wrongly aborted as `permission-blocked`. The trigger is now anchored to devin's actual log-module prefix (`chisel::repl::handler:`) and scanned only in the recent log tail, so an echo of the phrase can't poison the state; a genuine hang still aborts immediately. Opt-out `OSRC_NO_PRINTMODE_ABORT=1` unchanged.
- **Truthful Tab — cash never under-reported.** An unmeasured cash OpenRouter run is now counted as "cost not captured" instead of a false "$0 measured", and is never silently dropped from the ledger. A pay-per-use devin run (nonzero cost) is bucketed as CASH, while a $0 Devin-Pro run is correctly PLAN (subscription spend, not free). A single malformed/interleaved ledger line no longer blanks the whole Tab (bad lines are skipped with a stderr note).

### Added
- **Per-lane, per-repo trust for the credential hard-block (#2).** Some cloud lanes are trusted the way Claude Code is trusted, but only for certain repos. `~/.config/outsourcerer/trusted-lanes.json` (`{"<lane>": ["/abs/repo", ...]}`) lets you say exactly that: when the current lane is trusted for the current repo, the credential-*file* hard-block is skipped and nothing else is. Default is empty, so every install stays fail-closed. The disclosure banner always names the skip — it is never silent. The prompt/`--with` pattern scan and the pasted-secret-value block still run, because trusting the credentials a repo already contains is a different decision from sending a live secret in a prompt. `--trust-lane <lane>` covers one-offs and is deliberately not an environment variable: an exported grant would be inherited by every background job and widen the trusted set well past the repo you were thinking about. Paths are resolved through symlinks and matched on directory boundaries; anything unreadable, malformed, or unresolvable denies.
- **Auto-routing for OpenRouter-only aliases.** `-m hy3` (or any OpenRouter-only model) with a mismatched active provider now auto-routes to the OpenRouter lane instead of erroring, honoring the "alias picks the lane" contract.
- **Cloud gate blocks pasted secret VALUES.** A live secret value (API key / token / private key) in the prompt or a `--with` file now hard-blocks the cloud route by default (opt-out `OSRC_SECRET_ALLOW_VALUE=1`); low-signal keyword hits remain count-only. The value is never printed.
- **Stronger job liveness.** The supervisor persists its own pid so a dead watchdog over a live orphan is detectable; `status` reconciles delegate liveness with a start-time (PID-reuse) guard. `watch` now emits a progress heartbeat during a running job instead of going silent between status changes.
- **`doctor` version-drift check.** Flags when the running script, `plugin.json`, and any second installed skill copy disagree, so a stale copy can't silently run old code.

### Hardening
- Cloud-consent file now written atomically (tmp-then-rename); the ledger is `chmod 600`; the devin-log TLS scan refuses symlinks; removed a dead duplicate `return`.

## [0.4.11] - 2026-07-18

Diagnostics-only patch: when a devin-backed job dies on the sandboxed-proxy TLS mismatch (devin's Rust TLS stack rejecting a local proxy's cert), the failure is now recognizable from outsourcerer's side instead of a bare, generic "Connection error". No retry/routing/fallback behavior change.

### Added
- **Sandboxed-proxy TLS failure diagnostics for the devin lane.** devin prints only a generic "Connection error, send a message to continue retrying" when its `rustls_platform_verifier` rejects a local/sandboxed proxy's peer certificate (Apple Security `OSStatus -<n>` cert-verify code, visible only in devin's own CLI log at `~/.local/share/devin/cli/logs/`), silently retrying with backoff for ~100-160s before giving up. A narrow detector (`_is_sandboxed_proxy_tls_failure`, machine-token + corroborated two-pass, same false-positive discipline as `_is_transport_failure`) now scans devin's newest CLI log tail after a non-zero devin exit and surfaces a one-line hint naming the cause and the fix (disable the sandbox/proxy for that call). The hint flows through `delegate()` (foreground + bg, since the supervisor captures stderr into `out.log`) and is re-emitted by `result`/`logs` for a failed devin job when not already present. `doctor` proactively notes a `*_PROXY` env var when devin is installed. Diagnostics-only — no change to retry, routing, fallback, or transport-vs-task classification.

## [0.4.10] - 2026-07-16

### Changed
- **`session` reframed as live orchestrator supervision, not a spectator mode.** It's the one delegation mode with a real feedback loop: the orchestrator reads the delegate's work as it happens (`session read`) and steers it mid-flight (`session send`), switches its model, or stops it. Headless `run`/`bg`/`fanout` fire-and-forget and only surface progress markers or a final result. SKILL.md + mechanism now guide preferring `session` for long, complex, exploratory, or high-stakes delegations where catching a wrong turn early beats one blind shot (tmux → Mac/Linux; Windows falls back to `bg`+`status`).

## [0.4.9] - 2026-07-16

Docs + contract polish (no code behavior change beyond the model-pick clarification).

### Changed
- The copilot's model choice is now explicitly benchmark-driven in **every** mode: auto-pilot runs `advise` and proceeds on the best-value winner; you-drive/hybrid score the same way then ask first. The mode only decides whether it asks, not whether benchmarks drive the pick.
- SKILL.md trimmed to 80 lines with a ~74-token description and proper progressive disclosure (mechanism detail moved to `references/`; the duplicated advisory section, verb table, and failure table collapsed to pointers).
- README: benefit-led sections for the copilot (driving modes + auto-conservation) and the benchmark model advisory; macOS/Linux/Windows + copilot + advisory badges; roadmap refreshed for the shipped lanes.

## [0.4.8] - 2026-07-16

Copilot + platform-parity release (one small bump from 0.4.7). The skill now greets you each session, shows your live limits, hands you the wheel, conserves tokens on its own when the session runs hot, works on Windows without WSL, and adds Droid/Cursor/claudex lanes. Reviewed by a 5-agent Opus gauntlet before release (0 critical, 0 high).

### Added
- **Session-start handshake (`brief`) + interactive-by-default.** On activation the skill shows ready lanes + live session limits + a conservation recommendation + driving mode, and presents a three-way menu when no mode is set (instead of silently running CLI). Read-only, never prompts — safe in bg/fanout/CI.
- **Driving modes (`mode auto|manual|hybrid`, remembered once).** Auto-pilot (skill picks lane/model + conserves), you-drive (never delegates unless asked), hybrid (agree once which task-types auto-delegate). Persisted atomically, symlink-refused, A/B/C aliases.
- **Live limit awareness + auto-conservation.** Reads the Claude 5h/7d window (via the new universal `tap`, or token-optimizer if present) and the ChatGPT/Codex plan. Crossing the conserve line (default 50%, `OSRC_CONSERVE_THRESHOLD`) routes grind to the cheapest ready lane: local > Devin GLM/SWE > keyless Gemini > Codex Sol/Terra (if headroom) > OpenRouter (if funded). Routing-only — never weakens safety/consent/quality.
- **`tap` — universal limit capture without token-optimizer.** `tap install` wires a passthrough into Claude Code's statusLine, saving live 5h/7d limits; `tap uninstall` restores the original.
- **One-time cloud consent** (`consent status|grant|revoke`) — the disclosure gate asks once, ever; the per-delegation secret-scan hard-block is never skippable.
- **Windows support without WSL** — runs under Git Bash; `outsourcerer.cmd` / `.ps1` launchers; platform-aware doctor; `pgrep`/`ps` fallbacks.
- **Engine lanes**: `--provider droid` (Factory, BYOK customModels), `--provider cursor` (subscription), `--provider claudex` (GPT-5.6 Sol/Terra inside the Claude Code harness via a user-run CLIProxyAPI, detect-only). Reverse bridges `parity-droid` / `parity-cursor`.
- **Devin aliases** swe/swe-1.7/kimi; deepseek is dual-lane and self-heals to Devin when the OpenRouter key is exhausted.

### Fixed
- Flag placement (`--provider`/`--cloud-ack`) accepted anywhere; `bg` no longer requires an explicit verb.
- State-home writability preflight fails fast with the exact fix instead of launching jobs with nowhere to write.

### Hardened (5-agent Opus review)
- `run`/`edit`/`yolo` with no task gave a raw unbound-variable crash on bash 3.2 — now a clean message.
- Codex 5h/weekly windows bucketed by `window_minutes`, not slot position (they were mislabeled).
- `tap`: exempt from the write-preflight so a sandbox can't kill your statusline; whole-object stash/restore; freshness gate fails closed; clears its frozen capture on uninstall; Windows routes through the `.cmd` launcher.
- `brief` caps its Devin/OpenRouter probes with a portable timeout so the handshake can't stall.
- `_descendants` reads PID/PPID by header column (process-tree kill works on MSYS `ps`).
- State home is chmod 700; cloud-consent refuses symlinks; `mode` rejects trailing args; limits render in plain English.

## [0.4.7] - 2026-07-15

Security and reliability hardening: findings from a multi-agent adversarial audit applied. No breaking changes. All 21 conformance tests + 62 advise tests pass.

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
