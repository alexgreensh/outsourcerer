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

- **READY** = the branch tip's commit message has the word `READY` (not `not READY`), or the tip tree
  has a root file `READY` / `<id>.READY`. `--ready SHIPPED` swaps the word. A push that is not READY
  is progress: no event, but it resets the stall clock.
- **Polling** is one network call per lane per poll (`git ls-remote`, or one
  `gh api repos/o/n/commits/<branch>` for `owner/name`), at most every `OSRC_REMOTE_POLL_SECS` (60).
  A moved head costs a branch fetch into `remote/<id>.git` (git) or up to two `contents` calls (gh).
- `lane add` registers the lane in the shared owner registry (`_owner_record`), so the stop-guard can
  see it. `osrc_remote_state <id>` prints `live|ready|done|failed|gone` from cache, no network.
- **Done contract**: `--done-when check:"<cmd>"` runs on the READY sha in a throwaway worktree
  (`OSRC_CHECK_TIMEOUT`, 900s). Fail means `EVENT failed`, no review enqueued, no reviewer tokens spent.
- **Failure is loud**: `gh` auth failure or rate limit emits `EVENT failed` with the reason on the first
  poll; other poll errors after `OSRC_REMOTE_ERR_MAX` (5) in a row; a deleted branch the lane once had.
- `stalled`: no push for `OSRC_REMOTE_STALL` minutes (90) while the lane is live.

## Review queue (one reviewer, one item in flight)

```
review reviewer <tmux-session> [--replace]   set THE reviewer (refuses a second live one)
review queue add <lane-or-branch> [--brief F] | queue ls
review next [--force]    send the oldest queued item as ONE line pointing at a generated brief
review show|ack|requeue|drop|sendback <item> | rotate | events
```

- READY lanes auto-enqueue, deduped by lane + head sha. Item id is `<lane>-<sha7>`.
- `review next` sends only to an idle reviewer (`osrc_screen_state` when L3 lands, otherwise a
  conservative pane reader that needs an empty composer and no spinner), never with another item in
  flight. The brief is `review/<item>.md`; the reviewer writes `review/<item>.VERDICT`, first line
  `MERGE`, `CHANGES` or `BLOCK`, findings below.
- **Verdict contract**: each item records `sha_at_ready`, `sha_reviewed`, `verdict`, `findings` (path).
  A push after READY supersedes a queued review of the old sha and marks an in-flight or finished one
  `stale`; the new READY head is enqueued as a re-review. A stale MERGE never makes the lane `done`.
  Set `OSRC_REVIEW_REREVIEW_ANY=1` to re-review on any push, not only READY ones.
- **Send-back** for lanes that cannot receive `session send`: `review sendback <item>` writes
  `review/REVIEW-<sha7>.md` and prints a relay message. Chosen over pushing a `review/<lane>` ref
  because a push is outward-facing and needs write access to a branch the lane may own or protect.
- **Rotation**: after `OSRC_REVIEW_ROTATE_K` reviews (6) or a footer context bar over
  `OSRC_REVIEW_CTX_MAX` percent (60), `review next` refuses and `review rotate` prints the steps for a
  fresh reviewer. `review reviewer <new> --replace` resets the counters.
- Nothing merges automatically.

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
