# Remote lanes and the single-reviewer queue

For work that runs somewhere outsourcerer cannot attach to: Claude cloud sessions, Devin `--cloud`,
any CI or worker that pushes a branch. Code: `scripts/lib/remote.sh` (lanes) and `scripts/lib/review.sh`
(queue). State lives under `$OSRC_HOME/remote/` and `$OSRC_HOME/review/`.

## Remote lanes

```
lane add <id> --branch <remote-branch> [--repo owner/name|path|url] [--ready MARKER] [--base BR]
         [--brief FILE] [--done-when check:"CMD"]
lane ls | show <id> | poll [id] | rm <id> | events
```

- **READY** (one rule, the same as the done contract's `branch:<b>@<marker>`): the marker word is at the
  START or END of the tip commit's SUBJECT line and is not negated by "not" (`READY: done`,
  `fix tests READY` count; `docs: explain the READY marker`, `wip: not READY` and a body-only READY do
  not). Or the tip commit ADDED or CHANGED a root file `READY` / `<id>.READY`; a file committed
  earlier does not count, so WIP pushes after a review are not READY. `--ready SHIPPED` swaps the
  word. A push that is not READY is progress: no event, but it resets the stall clock.
- **Polling** is one network call per lane per poll (`git ls-remote`, or one
  `gh api repos/o/n/commits/<branch>` for `owner/name`), at most every `OSRC_REMOTE_POLL_SECS` (60).
  A moved head costs a branch fetch into `remote/<id>.git` (git transport only). Every network call is
  killed after `OSRC_NET_TIMEOUT` (20 s), so a hung connection cannot stall `osrc_remote_events`.
- `lane add` registers the lane in the shared owner registry (`_owner_record`), so the stop-guard can
  see it. `osrc_remote_state <id>` prints `live|ready|done|failed|gone` from cache, no network.
- **Done contract**: `--done-when check:"<cmd>"` runs on the READY sha in a throwaway worktree
  (`OSRC_CHECK_TIMEOUT`, 900s) **in the background**: events never wait for it. While it runs the lane
  reads `live` (`lane show` has `check.state=running`); the next poll collects the result. Pass
  enqueues; fail, or a runner that died without a result, means `EVENT failed` and no review is spent.
  **The command executes code pushed by the remote lane, on this machine, with your own rights and no
  sandbox.** Only set it on lanes whose branch you would run locally.
- **Failure is loud**: `gh` auth failure or rate limit emits `EVENT failed` with the reason on the first
  poll; other poll errors after `OSRC_REMOTE_ERR_MAX` (5) in a row; a deleted branch the lane once had.
- `stalled`: no push for `OSRC_REMOTE_STALL` minutes (90) while the lane is live.

## Review queue (one reviewer, one item in flight)

For a design review, start a fresh reviewer with the browser tools and required design skills available at launch, or provide screenshots captured beforehand. Keep the same design checks and evidence in either case.

```
review reviewer <tmux-session> [--replace]   set THE reviewer (refuses a second live one)
review queue add <lane-or-branch> [--brief F] | queue ls
review next [--force] [--final]    send the oldest queued item as ONE line pointing at a generated brief
review show|ack|requeue|drop|sendback <item> | rotate | events
```

- READY lanes auto-enqueue, deduped by lane + head sha. Item id is `<lane>-<sha7>`.
- `review requeue <item>` on an in-flight item is refused while the reviewer is working or inside the
  send grace (it would be sent twice); `--force` overrides.
- `review next` sends only to an idle reviewer (`osrc_screen_state` when L3 lands, otherwise a
  conservative pane reader that needs an empty composer and no spinner; L3's `composer` counts as idle only
  when its evidence says "no turn yet", never when the composer holds unsent text), never with another item in
  flight. The brief is `review/<item>.md`; the reviewer writes `review/<item>.VERDICT`, first line
  `MERGE`, `CHANGES` or `BLOCK`, findings below.
- **Verdict contract**: each item records `sha_at_ready`, `sha_reviewed`, `verdict`, `findings` (path).
  A push after READY supersedes a queued review of the old sha and marks an in-flight or finished one
  `stale`; the new READY head is enqueued as a re-review. A stale MERGE never makes the lane `done`.
- Re-review briefs compare against the last reviewed commit and turn its findings into a checklist.
  Lane reports should add a `## Round <number>` section for each round; when available, only the
  latest round is included. Use `review next --final` for the final merge review, which requests the
  full base-to-head diff as well as the checklist. An incremental MERGE automatically queues a
  full-diff round on that same head. Only a MERGE from a recorded full-diff round can finish the lane.
  After CHANGES the lane reads `live` again and its stall clock starts at the verdict, so a lane that
  was sent findings and went silent raises `stalled`.
- `lane rm` deletes the lane's event stamps, review items and scratch files, so re-adding the same id
  announces and queues a still-READY head again. Backstop: a READY lane with no queued, in-flight or
  finished item for its head raises `EVENT unreviewed` with the fix as NEXT.
  Set `OSRC_REVIEW_REREVIEW_ANY=1` to re-review on any push, not only READY ones.
- **Send-back** for lanes that cannot receive `session send`: `review sendback <item>` writes
  `review/REVIEW-<lane>-<sha7>.md` and prints a relay message. Chosen over pushing a `review/<lane>` ref
  because a push is outward-facing and needs write access to a branch the lane may own or protect.
- **Rotation**: after `OSRC_REVIEW_ROTATE_K` reviews (2) or a footer context bar over
  `OSRC_REVIEW_CTX_MAX` percent (35), `review next` refuses and `review rotate` prints the steps for a
  fresh reviewer. A managed reviewer idle with an empty queue for `OSRC_REVIEW_IDLE_MIN` minutes (50)
  is stopped and retired. `review reviewer <new> --replace` resets the counters.
- Start a fresh Claude reviewer with `OSRC_LEAN_LAUNCH=1`: it retains `CLAUDE.md`, skips `--bare`,
  and loads no MCP servers unless `OSRC_LEAN_MCP_CONFIG` names a config with the required servers.
  Installed plugins and skills are still inherited.
- Nothing merges automatically.

## Repo guards (`guards run`, lib/guards.sh)

Run inside a lane worktree before READY: `outsourcerer guards run --base <branch the lane merges into> [--mode off|observe|enforce] [--json] [--allow "<reason>"]`. Always pin `--base`: a base naming HEAD or the checked-out branch is refused (exit 2), since its guards would come from the lane. Every guard sees one diff (merge-base of the base and HEAD against the working tree, plus untracked files), taken with `--text --no-textconv --no-renames` so `.gitattributes` cannot hide a file and a rename shows both paths. Guards and their config come from the BASE ref, never the lane: a diff touching `.outsourcerer/guards/`, `.outsourcerer/guards.conf`, any `.gitattributes`, `.file-size-allow` or `scripts/check_file_size.py` is reported as `guards_changed` for the reviewer and the lane's copy never runs.

- Built-ins: `slop` (narration and excuse comments, new `*.md` outside the allowlist; regex only, zero model calls; default **enforce**), `slop-inflation` (comment-heavy hunks; default **observe**) and `file-size` (the base copy of `scripts/check_file_size.py` with the base `.file-size-allow`, over committed and uncommitted files; default observe). A repo adds guards in `.outsourcerer/guards/` as `*.sh`, `*.py` or a `#!` file; each exits non-zero with `WHAT:` and `FIX:` lines. Anything else there (`slop.allow`) is data.
- Modes: `--mode` > `<guard> = off|observe|enforce` in `.outsourcerer/guards.conf` > the built-in's default > `default = ...` > observe. Slop keys: `slop.md_allow` (`dir/` = at the repo root, other entries are globs), `slop.comment_min`, `slop.skip`; per-path exceptions in `.outsourcerer/guards/slop.allow`, one `<glob> [class]  # reason` per line. Observe failures go to `$OSRC_HOME/guard-state/observe.log` and the run passes. Enforce exits 1.
- Never strands work: `--allow "<reason>"` passes a block. Blocks are counted per distinct diff (rerunning an unchanged diff stays blocked and is not counted); after 2 counted blocks the next new diff passes as "allowed after 2 blocks". Both land in `$OSRC_HOME/guard-state/allowed.log` and set `allowed` and `reviewer_required` in the JSON.
- `--json` prints one object: `{mode, passed, failed:[{guard, mode, what:[...], fix}], guards_changed, guards_changed_paths, allowed, reviewer_required, ran, skipped, base, base_sha, lane, elapsed_s}`. `passed` is the gate verdict (exit 0); `reviewer_required` means a person must look even though it passed. Feed `what` and `fix` straight into the retry brief.
- Committing guards: Outsourcerer's `.git/info/exclude` block ignores `.outsourcerer/*` (worktrees, lane state) but carves out `guards/`, `guards.conf` and `verify`, so these commit with a plain `git add`; it migrates the old single `/.outsourcerer/` line on first use. A tracked `.gitignore` entry `.outsourcerer/` (directory form) defeats the carve-out; use `.outsourcerer/*` there.

## Proof (lib/proof.sh): READY needs a proof for its head sha

```
proof run [--lane ID] [--dir DIR] [--base REF] [--cmd "<check>"]... [--method none|review --reason R] [--json]
proof show <lane> [--json] | stamp <lane> | check <lane> [sha] | sendback <lane> | reset <lane> | require [on|off]
```

- `proof run` runs the checks itself and writes `$OSRC_HOME/proof/<lane>/proof.json`: head sha, each
  command with exit code, seconds, pass/fail counts when the output shows them, last 30 lines, the
  `guards` JSON (lane S1's `guards run --json --base <lane base> --lane <id>`, always with an explicit
  base; `"unavailable"` when guards are not installed). `passed: false` fails the proof (WHAT/FIX lines
  are printed as the retry brief); guards that cannot run fail it without charging a round;
  `reviewer_required: true` (an `--allow` or released-after-blocks pass, or edited checks) keeps the
  proof but routes the lane to the reviewer: the stamp says so, the review brief lists what was let
  through, and a `.DONE` hand-in's NEXT is `review queue add`. Then `method`: `verify-run`
  (`.outsourcerer/verify` read from the BASE ref), `tests` (`--cmd` or the done contract's `check:`),
  `review` or `none` (both need `--reason`). Never write proof.json by hand. Uncommitted tracked
  changes fail the proof (the run did not test the head). A diff touching `.outsourcerer/` is
  recorded as `checks_changed` for the reviewer.
- Stamp, shown on review items, in the review brief and on Mission Control: `proved: 139 pass, 0 fail`,
  `unverified: <reason>`, `review only: <reason>`, or `failed: <cmd> exit N`.
- Remote READY: a cloud lane cannot write this machine's proof folder, so READY is proved here, on the
  READY sha (`--done-when`, and/or `.outsourcerer/verify` from base). With no check at all the READY is
  queued with an honest `method: none` proof (stamped unverified), never stranded. A failing proof
  spends no review and NEXT is `proof sendback <lane>`.
- `.DONE` hand-ins (`supervise --watch`): a lane that has run proof (or every lane after
  `proof require on`) needs a passing proof for its current head; otherwise the hand-in is sent back
  (`session send` to a live managed session, else NEXT `proof sendback <lane>`), no user ping.
- Three rounds, then a person: every failed proof run or sent-back hand-in is a round; a pass resets.
  After `OSRC_PROOF_MAX_ROUNDS` (3) the lane is stopped (`proof run` exits 4, no more sendbacks) and
  Mission Control lists it under "needs you" with the last failing lines. `proof reset <lane>` is the
  person's call. Project cards count lanes that landed unverified.
- Findings carry a severity tag, `[must-fix]`, `[nit]` or `[pre-existing]` (lib/review_sev.sh). Only
  must-fix sends a lane back: CHANGES with only nits/pre-existing routes to MERGE (`verdict_raw` keeps
  what the reviewer wrote), MERGE listing a must-fix routes to CHANGES, untagged findings keep the
  first line. Pre-existing findings go to `review/notes/<lane>.md`, never a block. A re-review brief
  carries the diff since the last reviewed sha and only the prior must-fix findings; the lane brief is a
  pointer, not pasted again.

## Events (see CONTRACT: `EVENT <kind> <target> <ts> <detail>` then `NEXT <command>`)

| kind | when |
|---|---|
| `done` | lane READY (queued); verdict file arrived (detail carries MERGE/CHANGES/BLOCK, `STALE` if the lane moved) |
| `unreviewed` | READY queued `OSRC_UNREVIEWED_MIN` (20) minutes with no review started |
| `idle` | reviewer idle with queue non-empty (NEXT `review next` or `review rotate`); reviewer idle with no verdict past the send grace |
| `stalled` | live lane, no push for `OSRC_REMOTE_STALL` minutes |
| `failed` | done-when check failed; poll auth/rate/network failure; branch deleted; reviewer session gone |
| `question` | verdict file whose first line is not MERGE/CHANGES/BLOCK |
| `approval` | reviewer sitting at a prompt mid-review |

Events dedupe by key and re-fire every `OSRC_RENOTIFY_MIN` (15) while the condition holds; READY is
announced once per head. `osrc_remote_events` (poll + print, never blocks) is what `supervise` calls.
Test overrides: `OSRC_TIME_UNIT=1` (seconds per "minute"), `OSRC_NOW` (clock).
