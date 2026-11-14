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
  On Claude, its exact mode line (`⏵⏵ auto mode on (shift+tab to cycle)`, …) as the last row is
  footer, not a menu row: an idle composer above it reads as no menu, and an unknown cursor menu
  above it still reads as a menu, so `session send` refuses with "modal open … session answer".

## Sends that land

`session send "…"` reports exactly one of these:
- `sent (verified: …)`: there is proof about THIS send. The screen is read before typing, and
  only one of these counts: the text was seen in the composer and the composer then emptied; a
  history row with the text appeared that was not there before; or the engine moved into
  `working` from a state that was not working. An old question, an old identical line or an
  approval on screen proves nothing.
- `sent (submitted, …; model delivery NOT independently verified: …)`: the composer is empty but
  none of those proofs showed up within `OSRC_SEND_VERIFY_SECS` (default 8). Check with
  `session state`.
- If a prompt opens while the text is being typed, the keys went into the prompt. Enter is not
  pressed and the send fails.
- If an approval or question box is already open, the send is refused before ANY key (not even
  `C-u`), under the endpoint lock: `EVENT failed <session> <ts> send refused: modal open …` then
  `NEXT … session answer`. On Devin a typed `e` would open edit mode on the pending command.
- On failure it prints `EVENT failed <session> <ts> send did not land: …` plus a NEXT line and
  exits non-zero. If the text was still in the composer after Enter, it pressed Enter once more
  before failing.

Messages longer than `OSRC_SEND_MAX_CHARS` (default 1500) are written to
`<delegate cwd>/.osrc-msgs/msg-*.md`. That folder is added to the repo's `.git/info/exclude`
(the shared one, from `git rev-parse --git-common-dir`), so it never shows in `git status`. The file
is written only after the send is admitted and is removed if the send is refused before typing.
Files older than 7 days are pruned on the next spill. The delegate gets a
one-line "Read the file …" instead. Sending the same message twice ("continue", "y") works: each
send is its own obligation.

`session effort` and `session model` use the session's recorded lane and model unless you pass
`--provider` / `-m`.

## The safe approver

```
outsourcerer session approve-policy safe            # this session (OUTSOURCERER_TMUX / $PWD name)
outsourcerer session approve-policy safe --session osrc-terra-1
outsourcerer session approve-policy safe --all      # opt in for sandboxed worktree lanes
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
For sandboxed lane worktrees, opt in to `safe` for the relevant sessions. Supervision reports
the count of automatic approvals at the next actionable wake; details are in `$OSRC_HOME/approvals.log`.
The sealed test runner is approved only for exact worktree test paths when the OS isolation tool is
available. Without it, a person can choose `--allow-unisolated`; that form is held for approval.

**What `safe` is, and what it is not.** It stops accidents: a delegate that wanders outside its
worktree, deletes the wrong thing, reads a secret or pushes. It is **not a sandbox**, and it is
**no defence against a prompt-injected or hostile delegate**. A delegate that may write
`tests/x.sh` and then run `bash tests/x.sh`, or edit `package.json` and run `npm test`, can run
anything it likes, because running the worktree's own tests is in the safe class. If the delegate
reads untrusted input (issues, web pages, other people's code), keep the policy `off` and use the
engine's own sandbox.

**Approved** (every flag must be on that command's allowlist, else hold):
- Read-only commands: ls/cat/grep/rg/head/tail/wc/sort (no `-o`)/uniq and xxd (one file, a
  second is an output)/stat/cut/jq (no `env`, `$ENV`, `input`)/find (allowlisted
  predicates only, no -exec/-delete/-fprint), sed with only p/d/q/=/n/N/s///, awk inline programs (no `system`, `getline`, `ENVIRON`, pipes, `>`, `@`, `ARGV`/`ARGC`, `SYMTAB`/`FUNCTAB`/`PROCINFO`),
  `git status|log|diff|show|blame|grep|branch --list|stash list|stash show` (no `--output`,
  `--no-index`, `-O`), `--help`/`--version` on known
  commands.
- Test, build and lint runs, only as the exact script verb: `npm|pnpm|yarn test|lint|build`
  with no extra arguments, pytest/unittest, `cargo|go test|build` (no `-o`, `--manifest-path`),
  `make test`, `bash tests/…`, ruff check, tsc, eslint (no `--fix`, `-o`, `--outDir`). Every path
  argument must be inside the worktree.
- Writes (mkdir/touch/cp/mv/rm, redirects, `sed -i`, `chmod` with a plain 3-digit or symbolic
  mode, git add/commit (`git add .` included), `git switch <name>` / `-c <name>`, file-create prompts) only when every
  target is inside the delegate's worktree and not `.git` or anything under it. The worktree is
  the git toplevel of the pane's cwd. Add more dirs with `OSRC_APPROVER_EXTRA_DIRS=dir1:dir2`.
- `env -u TMUX -u TMUX_PANE …` (and CLAUDECODE, NO_COLOR) in front of an approved command.

**Held** (prints `EVENT approval` and `NEXT … session answer`):
- Recursive `rm`, rm/delete or any write outside the worktree, a write aimed at the worktree root itself, any
  write into `.git` (`rm -rf .git`, `.git/hooks/*`, `.git/config`).
- Anything that touches OSRC_HOME: `OSRC_HOME=…`, `env OSRC_HOME=…`, `env -u OSRC_HOME`,
  `unset OSRC_HOME`, `export OSRC_HOME=…`, or the word OSRC_HOME anywhere in the command.
- Any other environment prefix (`PATH=`, `HOME=`, `BASH_ENV=`, `GIT_*`, `*_OPTIONS`, …) unless it
  is on the short harmless list.
- Any `$` outside single quotes (variables, `$?`, `$HOME`; `awk '{print $1}'` is fine, the shell
  expands nothing inside '…'), `~user`/`~+`/`~-`, brace expansion `{a,b}`, `…`, a trailing
  `&&`/`||`/`|`/`;`, and multi-line commands (Devin's and Claude's wrapped rows are joined first).
- git push, reset --hard, any force/-D flag, checkout/restore that discards work, commit
  `--amend`/`--no-verify`, `git stash` other than list/show (the stash is shared by every
  worktree), `git switch -C`/`--discard-changes`, `git init`, any git global flag except
  `--no-pager` (`--git-dir`, `--work-tree`, `-C`, `-c`).
- `git config --list`/`--get-all`/`--get remote.*.url` and any key off a short harmless list
  (`user.name`, `user.email`, `core.*`, `branch.*.remote|merge|rebase`, …): config can hold an
  `http.extraheader` token or a token-bearing URL.
- `git remote -v`/`show`/`get-url` (they print the same URLs); only bare `git remote` approves.
- Every `gh` command, sudo, `curl|wget … | sh`, any network
  tool, package installs, `npm publish`, `npm run <anything but the exact verb>`.
- Secrets (.env*, keys, tokens, `.credentials*` in any case, ~/.ssh, ~/.netrc, keychain, `ps e`,
  printenv/env, shell rc files like `.zshrc`/`.bash_profile` and history files `*_history`),
  anything that prints environment VALUES (`env`, `printenv`, `export -p`, `set`, `declare -x`,
  `/proc/*/environ`, `env | grep …`: the screen goes to the delegate's model, and a value can be a
  login token). Names only: exactly `compgen -e` approves. `env | cut -d= -f1` holds, because a multi-line value
  (a PEM key, service-account JSON) prints its later lines whole,
  whatever reads them (cat, jq, cut, awk, column, xargs).
- Any read under the home folder outside the worktree (and the extra dirs), or one that covers
  the home folder (`find ~`, `find /`, `ls /Users`). System paths (`/usr`, `/opt`, `/etc`,
  `/tmp`) stay readable.
- ~/.outsourcerer, ~/.claude, $OSRC_HOME, or another git worktree.
- Command substitution, heredocs, subshells, background `&`, eval/source, xargs.
- tmux/kill/launchctl, interpreters (`python -c`), pagers and endless output (`less`, `more`,
  `yes`), setuid modes (`chmod 4755`), folder-trust prompts, and anything it cannot parse.
  Unknown means hold.

Matching works on parsed shell tokens with quotes respected. A filename containing "approve" is
just an argument, and `grep -E 'a|b'` is one segment. Attached short flags (`-osrc/x`, `-XDELETE`)
are split before the allowlist check.

**Relative paths are trusted relative to the pane.** The classifier resolves a relative path
against the git toplevel of the pane's current directory. Claude Code shows no working directory
in its prompt. Codex and Devin can run a command in a different directory from their own, and
their prompts do not always show it. When they do not, `rm -rf build` is judged as if it ran in
the worktree. Absolute and `~` paths are always checked exactly.

**One press per prompt.** supervise and the beacon may both tick the same pane. The tick holds
the endpoint lock from the re-read through the close check, and claims a per-pane, per-prompt
stamp atomically before pressing. A second caller never presses the same prompt again within
`OSRC_APPROVER_REPRESS_SECS` (default 15); it returns 3 (nothing to report). The other side of that: the same command asked twice in a row waits quietly up to 15 s
before the second prompt is pressed.

A held prompt is reported once. If it is still open after `OSRC_HOLD_MIN` minutes (default 30),
`EVENT approval … still held after Nm` is re-emitted so it cannot sleep overnight.

**Answering a held prompt.** `session answer` with no selector lists the prompt's rows, read
from the same engine reader (row 1 included, even under the cursor). Answer with the row's
index: `session answer 1` approves once on Claude, Codex and agy. A label works only when it
matches exactly one row: `session answer Yes` on Claude's prompt matches three rows and is
refused. A row that widens permissions ("always", "don't ask again", "auto mode", "Bypass",
"accept edits") is never picked by label, only by its index.

`osrc_approver_tick` return codes:

| rc | meaning |
|---|---|
| 0 | approved |
| 2 | held and reported now |
| 3 | held and already reported |
| 1 | nothing to do |

Every decision appends one JSON line to `$OSRC_HOME/approvals.log`:
`{ts, iso, session, engine, command, decision, rule, root, kind, path}`.
