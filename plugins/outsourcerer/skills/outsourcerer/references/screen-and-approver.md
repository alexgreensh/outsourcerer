# Screen reading, verified sends, and the safe approver

Outsourcerer is the one place that reads a delegate's screen. Don't write your own prompt regex
or approval loop. Every hand-rolled one so far has broken: a status bar read as a menu, a
filename containing "approve" got approved, the orchestrator's own typed "DONE" was matched, and a
C-locale shell missed every box glyph.

## Read the screen

```
outsourcerer session state            # line 1: state, line 2: evidence
```

| state | meaning | what to do |
|---|---|---|
| `approval` | a permission, trust or consent menu is open | `session answer`, or let the approver handle it |
| `question` | a picker (AskUserQuestion) is open, or the last turn ended with a question | answer it with `session answer` / `session send` |
| `working` | a live busy signal (spinner line, "esc to interrupt", busy composer) | wait |
| `idle` | composer ready, a turn finished since the last prompt | read the result, send the next step |
| `composer` | composer ready and no turn yet, OR it holds unsent text (the evidence says which) | send, or `session clear` the stuck text |
| `unknown` | nothing could be proven | read the pane; if it persists, treat it as stalled |

In code, call `osrc_screen_state <pane> [engine]` (lib/screen.sh). `osrc_screen_report` gives
KEY=value lines (ENGINE, KIND shell|write|read|trust|other, CMD, PATH, SEL, SCOPE, COMPOSER).

**Engines with real fixtures** (tests/fixtures/screen, captured 2026-11-13): Claude Code 2.1.323,
Codex 0.167, Devin CLI 3000.12, Antigravity CLI (agy) 1.5.5, plus the gemini-cli trust menu.
Gemini-cli approval wording and Cursor are unproven: the gemini CLI refused OAuth on the capture
machine and cursor-agent was not logged in. Other lanes use the generic rules.

How the reader works:
- It reads only the live region for each engine: the composer box, or the footer of a modal
  dialog. The status rows under Claude Code's composer (`⏵⏵ auto mode`, `← N agents`,
  `⤸ resumable`) are ignored.
- The composer's contents are masked. Text you typed is never evidence of approval or "done".
- Blank lines are dropped first, so Gemini/agy padding cannot hide a prompt.
- Each reader pins a UTF-8 locale, and glyph tests are byte-literal, so the result is the same
  under `LC_ALL=C`.
- `_managed_menu_detect` (used by `session send` and `session answer`) is gated on this reader.
  When an engine's layout is recognised, only an open approval or question counts as a menu. A
  reply that ends in a numbered list no longer blocks `session send`.

## Sends that land

`session send "…"` reports exactly one of these:
- `sent (verified: …)`: the composer cleared, and the engine started working, opened a prompt,
  or shows the text in its history.
- `sent (submitted: …; no reaction seen yet)`: the composer cleared, but no reaction showed up
  within `OSRC_SEND_VERIFY_SECS` (default 8).
- On failure it prints `EVENT failed <session> <ts> send did not land: …` plus a NEXT line and
  exits non-zero. If the text was still in the composer after Enter, it pressed Enter once more
  before failing.

Messages longer than `OSRC_SEND_MAX_CHARS` (default 1500) are written to
`<delegate cwd>/.osrc-msgs/msg-*.md`, which is added to git's exclude list. The delegate gets a
one-line "Read the file …" instead. Sending the same message twice ("continue", "y") works: each
send is its own obligation.

`session effort` and `session model` use the session's recorded lane and model unless you pass
`--provider` / `-m`.

## The safe approver

```
outsourcerer session approve-policy safe            # this session (OUTSOURCERER_TMUX / $PWD name)
outsourcerer session approve-policy safe --session osrc-terra-1
outsourcerer session approve-policy off --all       # default for sessions without their own policy
outsourcerer session approve-policy                 # show
outsourcerer session approve-tick                   # one pass by hand (supervise calls osrc_approver_tick)
```

Policy `off` is the default and never touches a pane. Policy `safe` approves a prompt **once**
and never picks "always allow". It needs two things to act:
1. `lib/approver_classify.py` says `approve`. That file has a single `is_safe()` gate, and it is
   deny by default: a command is approved only when no danger rule matches AND every segment is
   in the safe set.
2. The cursor sits on that engine's approve-once row: Claude `1. Yes`, Codex
   `1. Yes, proceed`, Devin `Allow` with scope `Once`, agy `1. Yes, run command` /
   `1. Yes, allow creation`.

After pressing Enter it re-reads the screen to confirm the prompt closed.

**Approved:**
- Read-only commands: ls/cat/grep/rg/head/tail/find (no -exec/-delete), sed without -i,
  `git status|log|diff|show|…`, `gh pr|issue|run view|list`, `gh api` GET, `--help`/`--version`.
- Test, build and lint runs: npm/pnpm/yarn test|lint|build, pytest, cargo/go test|build,
  `make test`, `bash tests/…`, ruff check, tsc, eslint (no --fix).
- Writes (mkdir/touch/cp/mv/rm, redirects, `sed -i`, git add/commit, file-create prompts) only
  when every target is inside the delegate's worktree. The worktree is the git toplevel of the
  pane's cwd. Add more dirs with `OSRC_APPROVER_EXTRA_DIRS=dir1:dir2`.

**Held** (prints `EVENT approval` and `NEXT … session answer`):
- rm/delete or any write outside the worktree, or a write aimed at the worktree root itself.
- git push, reset --hard, any force/-D flag, checkout/restore that discards work, commit --amend.
- sudo, `curl|wget … | sh`, any network tool, package installs, `npm publish`,
  `gh pr create/merge`.
- Secrets (.env*, keys, tokens, ~/.ssh, keychain, printenv/env).
- ~/.outsourcerer, ~/.claude, $OSRC_HOME, or another git worktree.
- Command substitution, heredocs, subshells, background `&`, eval/source.
- tmux/kill/launchctl, interpreters (`python -c`), multi-line commands, folder-trust prompts,
  and anything it cannot parse. Unknown means hold.

Matching works on parsed shell tokens with quotes respected. A filename containing "approve" is
just an argument, and `grep -E 'a|b'` is one segment.

A held prompt is reported once. If it is still open after `OSRC_HOLD_MIN` minutes (default 30),
`EVENT approval … still held after Nm` is re-emitted so it cannot sleep overnight.

`osrc_approver_tick` return codes:

| rc | meaning |
|---|---|
| 0 | approved |
| 2 | held and reported now |
| 3 | held and already reported |
| 1 | nothing to do |

Every decision appends one JSON line to `$OSRC_HOME/approvals.log`:
`{ts, iso, session, engine, command, decision, rule, root, kind, path}`.
