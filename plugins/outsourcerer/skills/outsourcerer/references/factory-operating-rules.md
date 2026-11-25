# Operating rules in full

SKILL.md keeps one line per rule; this page holds the full text moved out of it (lane osrc-l5) so
nothing was lost when SKILL.md was cut to 150 lines.

## Session mode in full

**`session` is the interactive delegation mode.** You act as the user toward each delegate: `session read` shows its real work, `session send "…"` steers it and answers its approval prompts so it never stalls, `session model <name>` switches its model (`session model fable` re-pins a Fable session that drifted to Opus; run it while idle), `session stop` ends it. `session start --perm safe` reduces approval-prompt toil using each engine's own pre-allow rung: claude gets an explicit allow-list (read-only/git-read/test-build commands + workspace edits; deletes, redirects, exec-flags and everything else still prompt), devin/codex/cursor get their model- or classifier-judged auto rungs, agy and gemini-cli get their vendor auto modes, and engines with no faithful rung (droid, hermes, cline, pi) launch with default permissions and the banner says so. `--perm default` (the default) launches exactly as before, and the chosen profile is recorded so `session control relaunch`/`session effort` reproduce it. The reason: a headless `bg`/`fanout` delegate that hits an approval wall goes `permission-blocked` and dies unseen. Use headless only for a non-interactive, CI, or detached caller, or a wide fan-out of independent one-shot jobs, and say so. Fable-pin, heartbeat, Windows broker, claims: `references/mechanism.md`.

**Lean lanes.** An interactive Claude lane loads only the MCP servers the brief or task declares (`--with mcp=a,b`, or `OSRC_LEAN_MCP_CONFIG=<file>`), else none, through Claude's own `--strict-mcp-config --mcp-config`. A full MCP set cost about 17 helper processes and 0.85 GB per lane. `OSRC_SESSION_MCP=full` opts back in to the whole set; `OSRC_LEAN_LAUNCH=1` forces lean. Headless Claude and Codex lanes were already isolated (`build_mcp_flags_cc`, `--ignore-user-config`). The Devin CLI has no per-run flag to limit MCP servers (only its persistent `mcp_config.json` and `devin mcp` commands), so Devin lanes still start the servers in that config.

## Supervision in full

**Agent harnesses (Claude Code, Codex) take a turn only on user input or when a background command they started exits.** So after every launch and after every wake, arm ONE `outsourcerer.sh supervise` as a background command (Claude Code: Bash `run_in_background: true`). It covers every job, session and remote lane you own and returns `EVENT <kind> <id> ...` + `NEXT <command>` lines the moment any of them is blocked, asks a question, hits a limit, finishes, goes idle, or stalls. Run each NEXT, then arm it again; events missed while it was down replay at once. Lanes that hand in by writing files (`out/L1.DONE`, `reviews/L1-VERDICT.md`, `*QUESTION*`): add `--watch <dir>` once; a lane re-handing in by rewriting the same file fires again (keyed on name + mtime + size + hash); `--unwatch <dir>` when the round is over. The stop guard holds your turn open until one is running. `wait <id>` still works for a single run.

Chat bots and other message-driven orchestrators cannot poll: export `OSRC_HEARTBEAT_WAKE="<your notifier>"` before launching so the beacon wakes you. An **ASYNC SUPERVISION** warning means it is unset. Cadence, wake payload, digest switch, and `fleet`: `references/jobs-and-safety.md`.

For a pane's current state, use `OUTSOURCERER_TMUX=<session> outsourcerer.sh session state` (backed by `osrc_screen_state`). Read the raw pane only if the state is `unknown`; do not repeatedly paste full pane captures into the orchestrator context.

After each actionable wake, run `outsourcerer.sh handover --check-context`. At the default 150,000 input tokens (override with `OSRC_ORCH_CTX_MAX`), it writes a handover. Start a fresh orchestrator with that handover, verify its first action adopts the old owner's targets and arms supervision, then hand off. Keep the old orchestrator responsible until that first action is verified; if context is unavailable, keep supervising and retry at the next wake.

Supervision refreshes its project and limits snapshot every 10 minutes into `$OSRC_HOME/supervise/<owner-id>/hub.json`; use that snapshot for board updates. Do not add a separate timed cron for these checks. `OSRC_SUPERVISE_TICK_SECS` changes the interval.

Use `supervise --auto done,limits` to dispatch a verified READY queue item to the reviewer without a wake. Auto mode only runs the exact review-queue action for that READY event; verdicts, questions, held approvals, and other actions still wake the orchestrator.

Ask lanes to append a `## Round <number>` section to their reports for each review round. Re-review checks the changes since the previous reviewed commit and the prior findings; run the final merge review with `review next --final` so it covers the full diff.

## Cloud sessions in full

**Cloud sessions are approval-gated spend, not the default.** `cloud start <id> --repo <owner/name> --base <branch> --brief <file>` launches a hosted session (Claude, Devin, or Codex cloud) that keeps load off this machine and survives the orchestrator's turn — but only after the L7 spend gate (`_osrc_spend_gate`; when absent the launch fails closed: Devin cloud, which bills metered ACU, requires the per-command `--spend-ok`, while Claude/Codex subscription lanes proceed with a printed note) and a one-time hosted-session consent (`cloud consent grant`; the model-API consent file and env vars do not cover it). `--sha <commit>` pins an exact pushed commit into the pack so an approved offer cannot drift to a newer HEAD. `cloud where <brief>` is a keyword heuristic for routing, not a judgment — it can be wrong on briefs that merely mention local-sounding words; `--where` overrides. Inspect lanes with `cloud ls` / `lane ls`, track events with `lane events`; READY work lands in the review queue as `<id>.READY` at the `cloud/<id>` tip. Heavy commands (full suites, builds, installs, benchmarks, `sh -c`/`python -m`/`npx`/`uv run`/`tox` wrappers) never launch anything by themselves: the gate emits one `EVENT approval` per lane id plus a `NEXT` line naming the exact vehicle, pinned `--sha`, and the local niced alternative (`OSRC_HEAVY_LOCAL=1`) for a clean, pushed tree; an identical check+sha reuses the in-flight lane and reads its `<id>.RESULT` back (sha-validated, real rc returned — stale or mismatched results stay NOT RUN); otherwise the check runs locally under `nice -n 19` one at a time — or queues with `EVENT stalled <id> mac-overloaded` when the Mac is overloaded. rc 125 always means NOT RUN.

## Paid lanes in full

**Paid lanes always ask first.** Any lane that bills per-use cash — OpenRouter, TokenRouter, Gemini API, Devin paid models, or anything on an API key, plus anything whose billing cannot be proven (`unknown` counts as paid) — is never dispatched to, hopped to, or fallen back to without consent: interactive runs prompt `y/N` (default No), headless runs refuse with an `EVENT approval` + a `--spend-ok` retry hint, and `--spend-ok` covers exactly that one command (never persisted, never implied by auto mode, the cloud-consent file, or an env var). Per-lane plan caps ride alongside: `--cap weekly<=40` (repeatable) on any launch, or standing `lane cap <lane> weekly<=40` until `lane cap <lane> --clear`; a lane at/over cap refuses new work and a running job gets one `EVENT limit cap:...` wrap-up notice.

## Windows

**Windows: no WSL.** Runs under Git Bash; `outsourcerer.cmd`/`.ps1` launch it. `session` runs through the bundled winpty broker instead of tmux: `start`/`send`/`answer <n>`/`read [--state]`/`clear`/`stop` (verified with Codex). `send` refuses while a menu is open, so answer it with `session answer <option-number>`. `session model` and the tmux-only verbs (`control`, `approve-policy`, `claim`) are not available there.

## Loop shapes in full

- A machine can verify it, one known target → `loop verify`. Add `--worktree` when a bad attempt must not touch the user's checkout.
- Same, but spend as little as possible → `loop escalate` (budget model first, a tier up only when the check keeps failing).
- A stopped loop that should continue from its saved feedback → `loop resume <id>`.
- Verifiable but open-ended → **sweep**; no checker but you can compare → **best-of-N**; quality is a matter of degree → **evaluator-optimizer**; the plan is the risky part → **council-build**. These are recipes composed from the verbs: `references/loops.md`.

Derive the check from this session's definition of done: if the user said "make the failing auth tests pass", the check is that test command. A vague check reports finished work as failed. The loop ends the moment the check passes; `--max` (default 6) is a runaway backstop, and `--max-minutes` bounds open-ended work better, since rounds are not equal work.

## Mission Control in full

`hub export` prints the project docs the Mission Control page renders, built from live state (owners, jobs, sessions, remote lanes, done contracts, review verdicts). `hub serve` runs the same page locally on `127.0.0.1` behind a random token and opens it. Your session shows there on its own once it uses Outsourcerer. At each milestone, say where you are in your own words: `hub report --status building|review|waiting|shipped --pct N --eta "<when>" --next "<one line>"`, `--name "<project>"` once, `--ask "<question>" --why "<background in plain words>" --rec "<your pick and why>"` (or two+ `--option`) when you need the user, written for someone who has not followed the work; `--done-ask D1` the moment it is answered anywhere, board or chat. `cleanup` (no args) is a dry run over the created-manifest with SAFE/ASK verdicts; `--apply` deletes SAFE only, `--ack` acknowledges ASK, `<id> [--force]` removes a worktree as before. Guide: `references/hub.md`.
