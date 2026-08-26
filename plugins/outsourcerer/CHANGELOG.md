# Changelog

All notable changes to the Outsourcerer plugin are documented here.

## 0.9.2

- **Hardening (protected paths): the config-dir guard now resolves symlinks.** A working directory that is a symlink into `~/.claude` / `~/.codex` / `~/.config` used to slip past the guard because only the logical `$PWD` was matched; the resolved path is now checked too, so a headless `acceptEdits` run can't reach a harness-protected dir through a symlink.
- **Fix (session claims): a crashed controller no longer blocks a session forever.** A controller that died without releasing left a claim directory that made every future claim to that session id fail. A stale claim is now evicted, but only when its recorded PID is provably gone, so a live controller's claim is never stolen.

## 0.9.1

- **Fix (parallel sessions): two Claude Code sessions in the same directory no longer collide on one interactive session.** The tmux session name is now scoped by the owning Claude Code session, so `session read`/`send`/`stop` from one session can never drive another session's agent. Set `OUTSOURCERER_TMUX` to deliberately share or isolate a session by hand.
- **Fix (session start): a lost start race is caught, not injected.** When two `session start` calls raced for the same name, the loser's `tmux new-session` failed silently and its launch command was typed into the winner's pane. `session start` now checks that exit code and returns cleanly on a lost race.
- **Fix (interactivity): a run you watch through a pipe stays in the foreground.** Auto-detach now treats an interactive stdin as watching too, not just stdout, so `outsourcerer run … | tee log` no longer detaches to the background and strands your pipe.
- **Fix (permissions): a trusted read lane can shell out without a false "no permission".** Inside your own Claude Code with driving mode `auto`, the read-only Claude lane also grants Bash, so a headless read/audit task that runs a command no longer dies with a confusing permission refusal. Every other context stays strict Read/Grep/Glob; opt out with `OSRC_LANE_READ_TRUST=0`.

## 0.9.0

- **New: per-model daily quota — spread work across free tiers, skip an at-cap model _before_ it fails.** Many strong models sit behind a free daily request cap (hy3, DeepSeek v4 Pro, Qwen, Gemini's free tier, Devin's plan-included GLM/SWE…). Outsourcerer now knows each cap, tracks usage, and routes around an exhausted one proactively instead of only reacting to a 429.
  - **Declare a cap:** `outsourcerer limits set <lane> <model> 50/day [--reset utc|local]`, inspect with `limits status`, remove with `limits clear`. Lane names are normalized (`devin`→`dv`, `gemini`→`gm`, `cc`/`codex`→`or`) so the cap you set is the cap that fires; `any` sets a bare-model cap on every lane. Introduce a new provider by adding its key to `~/.env` and declaring its cap — no failure needed to learn the limit.
  - **How it counts:** usage is derived from the existing `ledger.jsonl` (every run is already recorded there), so there is no separate counter file to corrupt or reset. A new `epoch` field on ledger rows makes the daily window exact. **No `quota.json` = unlimited = unchanged behavior**, byte-for-byte.
  - **How it routes:** at dispatch, an at-cap model is skipped for the next free candidate (free-before-paid), falling through to a paid lane only when the frees are spent. A model you pinned with `-m` refuses loudly with the reset time rather than silently switching (opt into auto-hop with `OSRC_FALLBACK_PINNED=1`); a mutating run never silently switches models. A real provider quota refusal writes an "exhausted-until" marker that reconciles the count with reality.
  - **Hardened** through two independent code reviews, a multi-agent torture pass, and a final cross-model review: fail-open modes on malformed config / torn ledger lines / float caps are closed, the counter is resilient to interleaved writes, and the Gemini free tier counts correctly across both CLI vehicles.
- **Fix (lane routing): an explicit `--provider` is now authoritative in the `bg` lane, wherever it sits.** `bg run --provider droid -m kimi-k3` (provider after the verb, or the `--provider=droid` equals form) silently fell back to the Devin default — recording the wrong lane, applying the wrong stall-floor, and resolving open-weight aliases to a Devin id. The provider is now captured from anywhere in the argv (foreground, `bg`, and `fanout`), so the lane you name is the lane that runs.

## 0.7.1

- **Fix (Linux): `fleet` and session tracking no longer crash under bash 5.** `_session_registry_append` referenced an uninitialized local (`physical_cwd`) that only bash 3.2 (macOS) tolerated; on Linux bash under `set -u` it aborted the session-effort path. Initialized it so the session registry records correctly on every platform.

## 0.7.0

- **New: `fleet` — one view of every session you're running.** `fleet ls` prints a single honest list of every AI coding session Outsourcerer can see on this machine: your live **Claude Code** sessions plus **every job you delegated** through Outsourcerer, across all lanes (Codex, Devin/GLM, Fable, droid, cursor, warp, cline). No more tab-hunting to find which session is waiting on you.
  - **Honest states, not "dead."** Each session is classified from its live process (`kill -0` truth, not a fragile timestamp compare) and its transcript tail into `Working` / `Waiting on you` / `Maybe stuck` / `Idle` / `Done` / `Stopped mid-task` / `Failed`. The "waiting on you" signal survives a long approval wait instead of being clobbered by a stale status.
  - **`fleet name` — real names from real work.** Reads each session's transcript and names it via the free GLM lane (cached at `fleet/names.jsonl`), so `alexgreenshpun-71` becomes `Update feedback skill for Gambit`. Naming is bounded per lane and falls back cleanly when a lane is slow.
  - **`fleet supervise` — a background heartbeat that catches the stuck ones.** Auto-armed with `OSRC_FLEET_SUPERVISION=1`. Bounds a delegate that never initializes or stalls, instead of letting it sit silent. Backed by the byte-growth stall watchdog and a hard-timeout so a hang is always eventually caught.
  - **Scope (honest):** Claude Code sessions + Outsourcerer's own delegated jobs. It does not yet enumerate sessions other tools started independently of Outsourcerer; unified cross-tool enumeration is planned for a later release.
- **Delegation-robustness hardening (the plumbing behind `fleet` and every long job).** A four-round adversarial gauntlet (independent judge + torture lanes) drove these to green: a **no-init watchdog** that bounds a delegate which never produces model output (positive-output detection, not a permissive catch-all); a **Devin free-lane guard** that reaps only provably-orphaned processes (never a healthy manual or reparented delegate) and never falsely reports the free `glm-5-2`/`swe-1-7` lanes as unavailable; **free-tier own-quota exhaustion retries the other free lane** instead of hard-failing; and a **bash-native `_timeout`** (no external `timeout`/`gtimeout` binary) with a zombie-vs-live discriminator and a busybox `ps` fallback.

## 0.6.4

- **Parity self-heal: dead skill links repair themselves.** Plugin caches are version-pinned (`.../<plugin>/<version>/skills/...`), so every plugin upgrade deletes the directory an earlier `parity` symlinked to — the Devin skills mirror stayed full while the delegate silently ran without skills the host believed it had (one user hit 59 of 83 dead). `brief` now re-pins dead links to their source's current location on every session, on every host — dependency-free (no devin/jq/network/prompt), silent when healthy, capped on the hot path (`OSRC_BRIEF_HEAL_MAX`, default 25) with the overflow deferred to `doctor --fix`, opt out with `OSRC_BRIEF_NO_HEAL=1`. `doctor --fix` repairs in place and prunes truly-gone links, instead of only advising "Re-run: parity". Re-pin follows the dead link's own plugin lineage (a same-named skill from another plugin can't hijack it) and picks the newest version that actually **contains** the skill (real caches carry non-semver `unknown`/hash siblings that a naive `tail -1` would wrongly pick — `parity`'s net-new linker was fixed for the same class, so plugins like compound-engineering now link at all).
- **New lane: Cline (`--provider cline`).** Cline CLI is a first-class engine lane alongside droid/cursor/hermes/warp. `-m` passes through **verbatim** to cline's own catalog. It runs on the user's own Cline setup: a ClinePass subscription (~$9.99/mo, discounted open-weight models like GLM, DeepSeek, and Kimi) or their own keys in `~/.cline` — full supervision (bg/fanout/watchdog/ledger/cloud-gate). The roster and pricing are cline's, not ours; the Tab tracks the spend. `run`/`explore` → `--plan` (read-only, **version-gated** ≥ 3.0.36); `edit`/`research`/`yolo` → act mode with `--auto-approve true` (cline has no OS sandbox). `--effort` maps to `--thinking`. Wired into every provider list, the router cost-class + default-model + lane-map seams (so dispatch actually reaches the lane on both the `-m` and no-`-m` paths), the cloud gate, session start, and ledger bucketing; `cline --version` gate is timeout-bounded. **Supervision limitation (disclosed):** cline's hub/spoke can spawn detached spokes that survive a cancel/watchdog kill (same class as codex MCP grandchildren on macOS); `_kill_tree` reaps best-effort and warns.
- **`classify` subcommand — post-hoc false-stall detector for terminated jobs.** `classify <job-id>` reads the job dir and prints a routing label + reason: `REUSE-OUTPUT` (did real work despite being killed — don't rerun), `RETRY-DIFFERENT-LANE` (lane blocked — quota/credit/permission), or `REAL-FAIL` (escalate). `--json` for a small object. Deterministic, zero-LLM, zero-cost. Classification order: done → **usable work wins (commits / writes / non-refusal deliverable) → quota → permission-blocked → real-fail** — a job that produced a real deliverable is REUSE-OUTPUT even if its log narrates "429 Too Many Requests", so genuine work is never discarded as credit-exhausted (quota is read from `out.log`, the deliverable from `last.txt`; when `meta.json` records no cwd the scan is skipped rather than run against the orchestrator's own repo). The false-stall window is bounded to the job's own runtime (`.startmark` → `$jd/exit` mtime). Hardened against a `grep -q`/pipefail SIGPIPE that dropped the commit signal and an `OSRC_PREAMBLE_MAX` awk-program injection.
- **Fixed a RED CI on `main`:** `test_devin_org_policy_posture` read the file mode with BSD `stat -f` first, which on Linux is a filesystem query that exits 0 with junk — swapped to GNU `-c` first, BSD fallback.
- **Torture-room hardening pass.** A full 13-agent multi-phase gauntlet on this release caught and closed 2 CRITICAL (cline dead-on-dispatch; parity net-new skipping non-semver plugins) + several HIGH before ship; conformance suite 81 passed / 0 failed. PR #9 (Cline lane) and PR #10 (classify) by @danikdanik.

## 0.6.3

- **`session start -m <alias>` now starts the model's NATIVE lane — the alias picks the lane.** A logged
  bug: `session start -m terra` launched the **Devin** CLI with model "terra" instead of
  codex-native, because the provider defaulted to devin and the session-start paths never applied the
  alias→lane map (the exact "sol/terra on Devin" mistake the skill warns about). `delegate()` already
  honored it; `session start` was the one path that skipped it. Now, when `--provider` is not given
  explicitly, a native-family alias remaps the harness: sol/terra/luna/gpt-5.x → codex, opus/fable/sonnet/
  haiku → claude, gemini-* → gemini. Open-weight/dual-lane ids (glm/deepseek/kimi) stay on Devin (the free
  default), and an explicit `--provider` always wins. The docs promised this guarantee; now it holds for
  `session start` too.
- **`session send` to a Devin session: confirmed the text actually lands (regression-locked).** A logged
  bug reported `session send` returning "delivery unknown" with the text never appearing (raw
  `tmux send-keys` worked). Root cause was the 0.6.1 composer guard failing closed for Devin and aborting
  before typing; the 0.6.2 honest-send rewrite already fixed the delivery (Devin's composer state resolves
  to `empty`, so the send proceeds to `send-keys` + Enter and reports "sent — unverified"). This release
  adds a regression test that mocks tmux and asserts the keys are actually delivered, so the "text never
  lands" class cannot come back silently.

## 0.6.2

- **Fable-pin: a claude-native session that falls back to Opus can now be flipped back to Fable, live.**
  A Claude Code session launched on Fable can drift to Opus (the Fable 5 → Opus 5 → Opus 4.8 tier
  ladder). The model-drift framework already DETECTED this, but observation needed an external hook and
  restore was wired for Devin only, so a real Fable session was never seen and never corrected. Now the
  claude-native lane has a **built-in model observer** (reads Claude Code's status footer; disable with
  `OSRC_CC_MODEL_OBSERVE=0`) and a **restore adapter**: `session model fable` navigates Claude Code's
  `/model` picker and re-pins Fable **session-only** (it never changes your global default), then
  confirms the switch against the footer before reporting success — handling the "this conversation is
  cached, switch anyway?" confirmation a session with history shows. The picker only opens between turns,
  so the flip works on an idle session (which is when you notice drift — after output lands) and declines
  cleanly mid-turn. For cc the heartbeat is **report-only**: it detects drift and wakes the orchestrator
  rather than typing into the session, so it can never interrupt an in-flight turn (pane-scraping can't
  prove a turn isn't running); the actual flip is the orchestrator-initiated `session model fable`.
- **Vocabulary hygiene — keep model-facing text out of the fallback cascade.** Some generations fall
  back to a heavier tier when the text they READ pairs jargon with a violent-sounding word ("kill
  switch", "hijack", "orphaned", "blast radius"). New **`sanitize`** subcommand scrubs that vocabulary
  from any prose/state/todo/memory/commit file (`sanitize <path>` reports; `--write` applies;
  `--aggressive`/`OSRC_VOCAB_AGGRESSIVE=1` also softens common tech words). It is prose-oriented and
  refuses source files, so a real `kill "$pid"` syscall is never touched. Outsourcerer also scrubs its
  OWN async-push summaries at the source (the text that re-invokes an orchestrator; opt out with
  `OSRC_VOCAB_GUARD=0`) and softened its own watchdog wording. Map + rationale:
  `references/vocabulary-hygiene.md`.
- **`session send` to a managed session no longer reports "delivery unknown" when it did deliver.**
  The composer/receipt check was adapter-only, so without an external probe every managed `session send`
  failed with "delivery unknown" even though `tmux send-keys` delivered. It now reports HONESTLY instead
  of failing: delivery is confirmed only by a real external receipt adapter; without one it says "sent —
  keys delivered, delivery not independently verified" (rc 2) and records `delivery_unknown`. No receipt
  is ever forged from `send-keys` success (which only proves tmux queued the keys, not that the app
  consumed them). A broken/misconfigured probe fails closed, and `OSRC_MANAGED_SEND_BUILTIN=0` restores
  the strict regime where a send without a usable adapter is a hard failure.
- **droid `explore`/`run` (read-only) is now actually permissioned.** The read-only tier passed no
  autonomy flag, so `droid exec` refused with "insufficient permission, re-run with --auto medium". It
  now passes `--auto low` (reads + safe read-only commands, no edits), which is what exploration needs.
- **Free-tier Devin models are no longer misread as blocked by the paid "0%" display — now with a precise
  detector.** glm/swe (and the other plan-included ids) run on Devin's free tier; a paid-ACU "0% remaining"
  figure is a separate balance and does not gate them. Dispatch says so up front, and Devin's stderr is now
  **captured on both dispatch paths** (the non-sandbox path used to discard it). On a free-model failure the
  hint is no longer hedged: if the captured output shows a real quota/ACU/billing refusal it says so
  definitively **and prints Devin's actual wording** (self-resolving telemetry — the exact string surfaces
  the next time it happens); if the failure was unrelated it stays silent instead of waving the free-tier
  flag at the wrong error. Cross-lane fallback is named, never auto-routed (a free→cash switch is your call).
  The matcher is context-anchored (a money/quota noun only counts beside a refusal verb), so it covers the
  canonical wordings (402, payment required, subscription expired, credit limit, usage cap) while a stray
  "billing"/"quota" or a transport "exhausted all retry attempts" is not mislabeled a quota gate.
- **`advise` now folds live limits-left into the recommendation, not just conserve-routing.** A subscription
  lane past the conserve line (cc = Claude 5h, cx = Codex 5h/weekly, whichever is more spent) takes a gentle
  score haircut (linear, ≤10% at fully spent), so a nearly-exhausted lane loses close races to a fresher one
  and the reasoning shows it (`conservation: cc/Claude 5h past conserve line → score x0.91`). Only lanes we
  can actually measure are touched — Devin/Gemini/OpenRouter stay neutral (we never invent a limit we can't
  read). Opt out with `OSRC_ADVISE_CONSERVE=0`; exposed in `--json` as `conservation`.
- **Torture-gauntlet hardening (two MAJOR fixes).** An adversarial fuzz pass found two edge-case
  defects, both now fixed and regression-tested: (1) `sanitize` on a directory silently skipped a file
  whose name contains a newline — directory traversal now walks NUL-delimited (`find -print0` /
  `read -d ''`) so any valid POSIX filename is one path, not two; (2) the Claude footer observer
  fabricated a model family from an ambiguous footer ("Opus Fable" returned `fable`) — it now requires
  exactly one family token in the model field and returns `unknown` otherwise, honoring the never-invent
  guarantee. Valid single-family and ANSI-wrapped footers are unaffected.

## 0.6.1

- **The heartbeat can finally reach an async orchestrator.** The background beacon used to only WRITE a
  status pulse (to a tty or a sink file). A message-driven caller that only takes a turn when input
  arrives (a chat/Slack/Telegram bot, idle between messages) has no polling loop and never reads that
  tty, so a delegated run went silent until the user pinged. New **`OSRC_HEARTBEAT_WAKE`**: export a notifier command and the beacon TRIGGERS it on
  every state change (blocked/dead) and on the periodic digest (still-cooking / landed), passing the
  compact summary as `$1` and the full event JSON on stdin (and `$OSRC_WAKE_EVENT`). The plugin never
  sends anything itself — it only triggers the caller's own sanctioned notifier. Untrusted event text is
  passed as an arg / stdin / env only, never interpolated into the command, so a task summary with shell
  metacharacters cannot inject. Best-effort and time-bounded (`OSRC_HEARTBEAT_WAKE_TIMEOUT`, default 20s):
  a slow or failing notifier never wedges the beacon or gates a wake ack. Suppress just the periodic push
  with `OSRC_HEARTBEAT_WAKE_DIGEST=0`. New suite `test_heartbeat_wake_push`.
- **Async-supervision guard.** A headless `bg`/`fanout` launch (no tty) with no wake and no sink armed now
  prints an **ASYNC SUPERVISION** warning at launch, naming the exact fix, so an async orchestrator can't
  launch work and discover the silence an hour later.
- **Stop re-nagging a remembered org-policy refusal.** When Devin's org policy blocks the sandboxed
  `autonomous` mode that `research` needs, the tool used to re-attempt it and re-print the scary error on
  every run, then suggest `yolo` (which is LESS safe and not the fix). It now DETECTS the refusal once,
  REMEMBERS it (`~/.outsourcerer/lane-posture/devin.autonomous`, 0600, symlink-safe), and preflight-skips
  the doomed attempt with one clean, routable notice (use Codex for sandboxed exec, or run read-only on
  Devin) — never silently downgrading to no-sandbox. New `posture` subcommand (`status`/`reset`) and suite
  `test_devin_org_policy_posture`.

## 0.6.0

- **Human-readable status pulse.** The fleet heartbeat now emits a readable one-line pulse
  (`♥ working=N blocked=N unknown=N landed=N`) instead of a raw dump, so a running fleet is legible at a glance.
- **Status beacon auto-arms by default** (`OSRC_FLEET_SUPERVISION=1`; opt out with `=0`), so supervised work
  is watched from the moment it starts without an explicit arm step.
- **Harden the fleet:** reclaim dead-owner beacon leaders (fix elapsed/caps), and sanitize free-text fields
  in the status pulse so a task summary can't corrupt or inject into the digest. Dropped tracked test scratch.

## 0.5.0

- **Auto-armed heartbeat + `bearings`/`rundown`.** A background fleet heartbeat, plus `bearings` (read the
  last snapshot) and `rundown` (refresh + render), so the orchestrator always has a cheap fleet status read.
- **External-session discovery + safe claimed replies.** Discover Claude/agent sessions outside the tool and
  steer them via a claim-token boundary (`session claim`/`reply`/`release`), with the send gated off by
  default (`OSRC_EXTERNAL_SEND`). Shared session-state, snapshot, and wake-queue primitives underpin it.
- **Active model-pin enforcement** — detect and correct model drift in a managed session.
- **Effort-aware model selection** (`advise`) with Kimi K3 across lanes; **change reasoning effort
  mid-session** (`session effort`); **capability-probed interactive launch** for droid/cursor/hermes.
- **Honest subscription-limit cost disclosure** in receipts (cash vs plan split); **provider provenance +
  a pre-dispatch confirmation gate** (internal continuations skip it).
- **Hardening:** mutation crash-safety, claim identity, election cleanup, gated external send, and a batch
  of adversarial-audit fixes in the mutation and routing paths.
## 0.4.23

- **Watcher now reports on a cadence.** `cmd_watch` emits a periodic `OSRC::PROGRESS` status digest
  (state · last marker · elapsed · next) even when nothing changes, so a long silent-but-healthy run
  no longer looks like a hang and the orchestrator can surface it into the running session without
  being asked. Tunable via `OSRC_WATCH_DIGEST_SECS` (default 420s); a final digest fires on terminal
  state. No new process or state file.
- **Fix a real liveness bug:** `_devin_live_mtime` used a BSD-first `stat -f %m || stat -c %Y` probe
  that returns garbage and exits 0 on GNU/Linux, so a LIVE devin job's heartbeat was ignored and the
  watchdog killed it as `wedged`. Now reuses the hardened, portable `_mtime` helper.
- **Green CI:** fix three failing conformance suites — `test_devin_liveness` (the bug above),
  `test_windows_portability` (same BSD-first `stat` defect in its mode probes), and `test_cloud_gate`
  (the cmd_bg preflight self-exec targeted the test harness under `source`; the test now points
  `SCRIPT_PATH` at the real binary). New `test_watch_digest` locks the digest behavior.

## 0.4.22

- **Hermes now works both ways.** The delegation lane (OUT) is wired for real: `delegate_hermes`
  invokes `hermes -z "<prompt>"` (scripted one-shot: prompt in, final text out), maps the tier to
  Hermes' binary approval model (`--yolo` for mutating verbs, disclosed in the posture banner),
  passes `-m` through to `--model` verbatim, and honors `-w` for an isolated worktree. The 0.4.21
  lane shipped as a stub that died "not yet wired" despite the changelog implying otherwise; this
  entry makes the code match the claim.
- **New reverse bridge: `parity-hermes` (IN).** Hermes discovers SKILL.md-format skills from
  `$HERMES_HOME/skills`, so the bridge is a skill symlink (not an AGENTS.md append like
  codex/droid/cursor). It is idempotent and self-healing (a dangling link from a moved/upgraded
  skill is repointed at the live install, the same guard the Devin parity uses). Once linked, a
  Hermes session can delegate INTO Claude (`run -m fable`, verified), Codex, or GLM. `parity` (the
  Devin sync) also mirrors this one skill into `$HERMES_HOME/skills` as a bonus, alongside the
  Antigravity mirror.
- Harden the recursion-depth *maximum* guard too: `OUTSOURCERER_MAX_DEPTH` is now normalized and
  fails closed on a malformed value, closing a fail-open path where a delegate could poison the
  maximum to escape the recursion limit (the depth was already hardened; the ceiling was not).

## 0.4.21

- Add the Hermes engine delegation lane: `-m` model pass-through, dispatchability preflight that
  fails before minting a job on the foreground, background, and auto-detached paths, and cost
  receipts read read-only from `~/.hermes/state.db` with an honest empty-else-labeled-estimate
  fallback (a partial or non-authoritative receipt never masquerades as a measured cost).
- Harden the recursion-depth guard: depths are normalized as base-10 (leading zeros no longer
  misparse as octal) and any malformed value is refused rather than failing open.
- Add the OpenRouter withdrawn free-model translator: a `:free` model that OpenRouter has stopped
  serving now yields a clear, actionable message naming the paid replacement slug instead of an
  opaque 404 or a silent retry loop.
- Internal comment/label cleanup.
Format follows [Keep a Changelog](https://keepachangelog.com/); versioning is [SemVer](https://semver.org/).

## 0.4.20

- Devin/GLM lane: add a lane-aware stall-kill floor (default 1800s, override `OSRC_DEVIN_STALL_KILL`)
  so the background watchdog no longer reaps a healthy delegate mid-inference during a long
  non-streaming completion, where both liveness signals legitimately go quiet at once. The hard
  timeout remains the backstop for a genuinely wedged run.

## [0.4.19] - 2026-07-22

Windows gets working background delegation.

### Added
- **Background delegation on Windows and Git Bash (#5).** Job directories are now created in a way
  that works on filesystems with no Unix permission bits, so `bg`, `fanout`, and auto-detached runs
  work on Windows the way they do everywhere else. Creation and permission-hardening are separate
  steps with different failure semantics: creation must succeed, hardening is applied wherever the
  filesystem can express it. On Mac and Linux the resulting modes are unchanged. The job directory
  is still claimed atomically, so concurrent fanout workers can never share one.
- **`doctor` reports a missing jq instead of exiting on it (#5).** The version-drift check no longer
  depends on a variable that only exists when jq is installed, so the command that exists to tell you
  what is missing now runs on a machine that is missing it.
- **State and job directories are private from the moment they are created.** Creation runs under a
  restrictive umask, so there is no interval between a directory existing and its permissions being
  applied. Previously the mode was set in the same call that created it; splitting those steps for
  portability would otherwise have opened that interval on shared machines.
- **A permission-hardening failure is reported rather than assumed benign.** Where the filesystem
  cannot express the mode the degradation is expected and silent; anywhere else the tool now says so
  once, because it is about to write consent state, the ledger, and job output into that directory.

### Testing
- New portability suite in the conformance gate. It simulates the no-permission-bits filesystem
  rather than describing it, asserts the atomic claim still admits exactly one of ten concurrent
  racers, and asserts directories are born private under a hostile umask. Each assertion carries a
  control proving it can fail: the race harness is checked against a deliberately non-atomic claim,
  and the jq probe against the reintroduced defect. 53 checks green.

## [0.4.18] - 2026-07-22

Long-running delegation now runs to the finish.

### Added
- **Lane-aware liveness.** The supervisor tracks real delegate activity on lanes that report progress
  out of band rather than streaming it, so long and quiet jobs keep running to completion. Liveness is
  credited only up to the delegate's last confirmed activity, so a genuinely stalled job is still
  reaped on schedule. Tunable with `OSRC_DEVIN_LIVENESS`.
- **Precision denial detection.** Permission and sandbox walls are matched on genuine rejection
  events, anchored to real error results and bounded to the recent tail, so mutating runs stay alive
  through large reads and refactors. Both directions are tested: the suite asserts the guards still
  fire on real devin and Claude rejections.
- **Accurate completion states.** Every job is classified on its real exit.

### Testing
- Two new suites in the conformance gate, both negative-tested. 52 checks green.

## [0.4.17] - 2026-07-22

Two guarantees that were not being kept: which model actually ran, and what actually leaves the machine.

### Fixed
- **A mid-run model fallback was reported as verified.** The native Claude lane proves which model ran
  by reading the run's `modelUsage`, but it only read the FIRST entry. A run that started on the
  requested model and switched part-way through — a silent fallback to the account default — still
  printed a clean `[verified]` receipt naming the requested model. Since that receipt is what gets used
  to label the output, the one case most worth catching was the one it could not see. Every model billed
  by the run is now examined, and a run that drifted reports `[MODEL DRIFT]`, names what it fell back to,
  and returns non-zero. Attribution covers the whole run rather than its opening turn.
- **The cloud disclosure understated its own scope.** The banner listed the delegated working directory
  and any `--with` files as what leaves the machine. Some agent CLIs additionally load "always-on" rule
  files from `$HOME` and prepend them to every session, which is outside that scope, so the banner was
  describing a smaller blast radius than the one that applied. Those files are now named, along with the
  point that matters more than their contents: they are instructions, so a delegate briefed for one
  narrow task also inherits whatever global direction they carry. The banner points at the CLI's own
  command for listing them; Outsourcerer does not perform the injection and does not claim it can
  disable it.

## [0.4.16] - 2026-07-22

Delegations that fail before they start, and completions that cannot be proven, cost more than any
model error. This release targets both.

### Fixed
- **A granted capability silently never arrived.** `--with skills=<name>` resolved only
  `~/.claude/skills/<name>/SKILL.md`, so every skill that ships inside a PLUGIN resolved to "NOT FOUND",
  and the note went into the prompt where only the delegate could read it. Whole sessions of delegations
  ran without the capability the caller believed it had granted. Resolution now covers the user's skills
  dir, the plugin caches (newest version wins, so an upgrade is not shadowed), and the parity dir, and a
  missing skill is reported to the CALLER on stderr, stating the delegate is running without it.
- **Skill injection is now bounded.** A `SKILL.md` can approach 100KB; pasting it verbatim into every
  delegation buys latency and spend, and on a lane that prints nothing until it finishes, a bloated
  prompt is indistinguishable from a hang. Capped at `OSRC_WITH_MAX_BYTES` (default 20000), truncated
  visibly, with the full path so the delegate can read the rest itself.
- **An invalid invocation minted a real job.** `bg` treated anything it did not recognise as a task,
  created the job directory, detached, and printed an id — so the caller received an id, believed work
  had started, and moved on, while the command died later inside the detached child. A caller whose
  quoting is wrong can produce a run of these from a literal, unexpanded variable. An unexpanded shell
  variable, or an invocation with no task text, is now refused in the parent: no job directory, no id,
  non-zero exit, and an error naming the actual mistake.
- **`-m` before the verb is accepted instead of rejected.** It was the second most common caller mistake
  and cost a whole round trip to a usage error. It is unambiguous, so it is now hoisted into place.
- **`done?` was reported for work that finished and said so.** codex-native and claude-native write
  their log as a JSON event stream, so a perfectly good terminal marker sits inside a string field and
  never begins a line. The line-anchored reader missed it, so work that had finished and said so was
  still reported as unverified. A signed marker is now recognised at a line start, a JSON escaped newline, or a
  string boundary. Mid-sentence prose is still refused, and the anti-forgery property is unchanged.
- **A dead model led the default OpenRouter chain.** `tencent/hy3:free` returns HTTP 404
  `model_not_found`, so every OpenRouter delegation opened by calling a model that no longer exists and
  paid a wasted round trip for it. Removed from `OR_CHAIN_DEFAULT`.

## [0.4.15] - 2026-07-22

A loop that stops is no longer a dead end, a check that hangs no longer defeats the bound, and
"installed" stops being reported as "will answer".

### Added
- **Loops resume.** A loop that stopped without converging (`blocked`, `max_turns`, `max_time`) keeps
  its task, its check and the exact failure it ended on, so `loop resume <id>` continues from that
  attempt instead of restarting at one and paying twice for ground already covered. The stall guard is
  restored across the restart, so a loop that was stuck repeating one failure cannot quietly spend a
  second budget repeating it. The task, check, model and verb are fixed by the original run and refused
  on the command line; only the attempt ceiling may be raised, and a loop that already succeeded is
  never re-run. The final line of a stopped loop now names the resume command.
- **Real liveness probes for the native lanes** (`OSRC_DOCTOR_PING=1`). A lane stays installed and
  authenticated while its plan window is exhausted, its token has expired, or its backend has stopped
  answering, and a binary that prints a version proves none of that. codex-native, claude-native and
  devin now send a bounded one-token request and report `READY` or `INSTALLED BUT NOT ANSWERING` with
  the reason (auth rejected, rate-limited, or no answer) and the remedy for that lane. The devin lane
  previously had no real request at all: its readiness came from a login-file check. Without the flag,
  those lanes now say they are installed and authed-looking rather than implying they are ready.
  Bounded by `OSRC_DOCTOR_PING_TIMEOUT` (bare seconds; distinct from agy's suffixed probe timeout).

### Fixed
- **A hung acceptance check could run forever.** The loop's time bound is only consulted between
  attempts, so a `--check` that never returned meant `--max-minutes` never fired and a bounded loop
  ran unbounded. Worse, a check that eventually exited zero after blowing through its entire budget was
  graded a success. The check now runs under a wall-clock cap (`OSRC_CHECK_TIMEOUT`, default 300s and
  further clamped to the time left in `--max-minutes`); a timeout is recorded in the check artifact and
  counted as a failed attempt, never as a pass.
- **Echoing the progress protocol could forge a terminal marker.** Status markers are signed with a
  per-run id so quoted examples are not mistaken for real status, but the injected protocol block
  printed its own example lines carrying the live id. A delegate that quoted the block back emitted a
  valid signed terminal by accident, and the supervisor believed it. The examples now use a literal
  placeholder and the live id is disclosed once as prose, so no copyable line in the prompt is a valid
  marker.
- **`_timeout` killed only the direct child, not its descendants.** A surviving grandchild still
  holding the inherited stdout kept a captured call blocked long after the bound fired, so the timeout
  appeared to work while the caller hung: a bounded call could still block far past its limit. It
  now signals the whole tree, which matters most on macOS, where no `timeout` binary exists and this
  fallback is the only path.
- **A background launch reported the wrong lane.** The launch line printed the default provider as
  though it were the resolved one, so a job dispatched to codex-native by a model alias announced
  itself as devin. Routing is decided after that line prints, so it now names the default as a default
  and points at the record showing the model the job really ran.

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
