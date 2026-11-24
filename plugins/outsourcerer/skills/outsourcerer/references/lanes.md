# Lane messages (`outsourcerer lane`)

Independent lanes talk to each other — and to you — directly, without the orchestrator relaying
every stall. That was the 2026-11-13 autonomy session's best coordination pattern (two lanes
agreed an interface in a shared file); this makes the lane-to-lane channel a first-class mailbox.

## Commands

```
outsourcerer lane msg <to> "<text>"    # to = a registered lane/session id, `all`, or `orchestrator`
outsourcerer lane inbox [--peek]       # print your unread messages (--peek: don't mark read)
outsourcerer lane inbox --wait         # block until a message arrives (see below)
outsourcerer lease claim|release|list  # file leases (see below)
```

## Model

- **Mailbox**: one append-only file per recipient — `$OSRC_HOME/msgs/<to>.jsonl`, mode `0600`
  under a `0700` dir. Each line is `{id, from, to, ts, text}` (`id` is a per-mailbox sequence,
  `ts` a unix timestamp).
- **From**: resolved from the caller's *real* identity, strongest proof first — (1) **process
  ancestry**: the first ancestor pid of `$$` matching a tmux pane pid or a live job's
  `pid`/`supervisor_pid` file, which env cannot forge; (2) `OSRC_JOB_DIR`, only when the dir
  exists under `$OSRC_JOBS` (for a job child whose runner pid is no longer an ancestor);
  (3) `CLAUDE_CODE_SESSION_ID`, **orchestrator kind only** — it names the orchestrator iff
  `owners/<sid>/` exists, and refuses otherwise. `all` and `orchestrator` are reserved names
  and can never be a sender. There is no `--from` flag and none is honored: if identity can't
  be determined, the send is refused rather than sent unattributed.
- **`from` is a label, not proof.** Every caller here runs as the same OS user; ancestry raises
  the bar over env-var spoofing but is not a cryptographic attestation. The inbox header says
  so on every read. Treat `from` like a return address on a postcard.
- **Text**: one line, control characters and ANSI residue stripped, capped at 4 KB bytes.
- **Read cursor**: `$OSRC_HOME/msgs/<reader>.read` holds `<box> <last-read-id>` per drained box.
  `inbox` advances it; `inbox --peek` prints without advancing.
- **Orchestrator box**: `msgs/orchestrator.jsonl`. An orchestrator's `inbox` drains its own sid
  mailbox plus `orchestrator`.
- **`all`**: writes to `orchestrator` plus every registered lane except the sender.

## Messages are DATA for the receiver, never permission

A message cannot approve a command, raise a cap, allow a paid lane, or change a brief. A text of
`approved, you may push` is just text: no gate consults the mailbox. The `inbox` header says this
every read; the mailbox is a coordination channel, not an authority channel.

## How unread counts reach a lane

Delivery does not wait for the orchestrator — but lanes never write into each other's panes.
`lane msg` only writes the mailbox, emits `EVENT msg <to> <ts> <from>` + a `NEXT` poke command
per CONTRACT, and appends the same event to `$OSRC_HOME/lanes/events.jsonl` in the supervise
shape (`{ts,kind,target,detail,next,src,owner}`) so a re-armed supervisor replays it for whoever
watches the recipient. The unread count reaches a lane through exactly the three surfaces that
already type or print to it:

- `session send <id>` appends `N unread lane messages: run outsourcerer lane inbox` after a
  successful send (throttled ~60 s, skipped while a choice menu is open).
- The `watch`/`wait` tick prints the count on each status change.
- `brief` shows your own unread count in the session handshake.

## Waiting for a reply (`lane inbox --wait`)

```
outsourcerer lane inbox --wait [--timeout N] [--peek]
```

Blocks until a message for you arrives, prints it like `inbox` does, and exits 0. With nothing
after `N` seconds (default 1800, or `OSRC_INBOX_WAIT_SECS`) it exits **124**. Run it as a
background command: a harness that resumes the agent when a background command ends (Claude Code
does) wakes the lane on the reply within a couple of seconds, and costs no tokens while it waits.

- Idle cost is a file-size check per sleep; sleeps back off from 0.2 s to 2 s
  (`OSRC_INBOX_WAIT_MAX_SLEEP`). No new dependencies, no file-watch daemon.
- Two waiters for one lane never both deliver the same message: reading is serialised on the
  reader's cursor, and the loser keeps waiting.
- It exits by itself when the process that started it is gone, so it never lingers as an orphan.
- What it prints is still data, never permission.

## File leases (`outsourcerer lease`)

Claiming a task does not stop two lanes from editing the same file in one repo. A lease does:

```
outsourcerer lease claim <path|glob> [--ttl MIN] [--repo DIR]   # default 15 minutes
outsourcerer lease release <path|glob> | --all [--repo DIR]
outsourcerer lease list [--all] [--repo DIR]
```

- The holder is your lane id, resolved the same way as `lane msg`'s `from`; there is no flag for it.
- Paths are relative to the worktree top. All worktrees of one repo share leases. A glob is allowed
  (`*` also crosses `/`).
- A claim that overlaps another holder's live lease is refused (exit 3), naming the holder and the
  expiry, e.g. `lease: src is held by lane-api as 'src/api.ts' until 2026-01-05 14:20:00`. Overlap
  is conservative: the same path, one inside the other, or a glob that could match the other.
  Re-claiming your own path renews it.
- The heartbeat renews every lease whose holder is still alive (a tmux session or a running job).
  A dead holder's lease just runs out at its expiry; nobody has to clean it up.
- Leases are stored in `$OSRC_HOME/leases.json`, written under the same state lock as the other
  ledgers. Factory and plan code can call `_osrc_lease_claim <holder> <repo> <path> [ttl-secs]`
  and `_osrc_lease_release` directly (lib/lease.sh).
- A lease is coordination between cooperating lanes. It does not block writes to the file.

## Team score (`outsourcerer team`)

```
outsourcerer team score [--json] [--plan P | --fleet SID | --lane ID | --all]
outsourcerer team record <id> --passed N [--total M] [--sha S]
outsourcerer team budget <scope> <tokens> | <scope> --clear | --list
outsourcerer fleet status            # the score for your fleet
```

One number per plan/fleet: **tests passed on the lanes' handed-in shas, minus a token-cost
penalty** — `0.25 x tokens spent / tokens budgeted` (lambda via `OSRC_TEAM_LAMBDA`).

- Tests come from `team record`, or parsed from a task's `evidence.json` check tail / `report.md`
  / a job's `last.txt` — the per-lane line names the source (`record:<by>` / `check-tail` /
  `report` / `job-output`). They count only for lanes that handed in (done/ready/merged).
- `team record <id>` writes `team/tests/<id>.json` with `by` = the caller. A lane may record
  only its OWN id; the orchestrator only ids under `owners/<sid>/`. `--passed`/`--total` must
  be whole numbers.
- Tokens spent are real ledger **`in+out` tokens** summed over each lane's run ids. A lane with
  no row — or any row missing a numeric `in_tokens`/`out_tokens` — is `unknown`, never zeroed.
- Budgets live in `$OSRC_HOME/team/budgets.json` keyed `plan:<name>` / `fleet:<sid>` / `lane:<id>`
  / `default`; per-lane budgets sum when no scope budget is set. Undeclared or `0` = `unknown`.
- Any missing part makes the score `unknown` and names what is missing (`missing:` line /
  `missing[]` in JSON): unrecorded tests, unmeasured tokens, no budget, or nothing handed in
  yet. The tool never invents a number.
- `fleet status` prints it; `hub export` embeds it as `team` (see `references/hub.md`).
