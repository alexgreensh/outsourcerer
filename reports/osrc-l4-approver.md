# osrc-l4-approver — stop holding safe commands

Branch: `cloud/osrc-l4-approver`. Scope stayed inside the owned approver classifier/tables/tests.

## What changed

- `lib/approver_lines.py` (new, 86 lines): physical command-line splitting for the safe approver.
  - `command_lines()` proves every `\n` is a real command boundary: it holds newlines inside
    single/double quotes and after a trailing backslash, skips comment-only lines, and returns
    stripped non-empty lines.
  - `logical_lines()` then joins only the continuations the shell itself treats as whitespace:
    a line ending in ` &&`, ` ||`, ` |&` or ` |` (space required before the operator) is joined to
    the next physical line. Backslash continuations, quotes, heredocs, redirects and glued
    operators (`cmd&&`) still hold.
- `lib/approver_classify.py` (876 -> 887 lines, still < 1000):
  - `is_safe()` no longer rejects every multi-line command. It runs the existing global
    `pre_checks()` once, splits with `logical_lines()`, then applies `pre_checks()` +
    `split_segments()` + `classify_segment()` per logical line, carrying `cwd` across lines so
    `cd src\nls` judges `ls` inside `src`.
  - `pre_checks()` gained `multiline=`; write/read paths still reject `\n`/`\r`.
  - `split_segments()` now holds an operator with no command before it (`&& ls`, `| ls`,
    `ls && ; cat`, `ls | | cat`, leading `;`/`&&`/`|` on a later line). Trailing real operators
    are still held by `pre_checks()`; quoted operator tokens keep the previous behaviour.
- Tests:
  - `tests/fixtures/approver-table.tsv`: +30 rows. Safe multi-line commands approve
    (`ls⏎cat README.md`, `git status⏎git diff --stat`, `cd src⏎ls`,
    `touch made-by-multiline.txt⏎ls -la`, comment-only line, `ls &&⏎cat README.md`,
    `ls |⏎cat README.md`). Unsafe/ambiguous multi-line commands hold: second-line `rm -rf /`,
    network, `sudo`, interpreter, secret path, `$HOME`, `git push`, `eval`, `env`, env-prefix,
    `$(...)`, backticks, pipe-to-`xargs`, `find -delete`, write outside, redirect to `~/.zshrc`,
    `rm -rf` split across lines, fullwidth `ｒｍ`, trailing `&&`/`|`/`>`/backslash, heredoc,
    `$(⏎...)`, quotes spanning newlines, unterminated quote, leading `&&`/`|`/`;`, consecutive
    operators, unsafe command after `&&`/`|`/`||`.
  - `tests/fixtures/screen/dv-approval-modal-safe-wrapped.ansi` (new): Devin approval modal whose
    command is display-wrapped after `&&`; end-to-end it must approve.
  - `tests/test_approver_tick.sh`: added `devin|dv-approval-modal-safe-wrapped|0` to the
    real-capture engine loop.

## Why

The 355 "multi-line command" holds came from `pre_checks()` rejecting any `\n`. Devin's screen
reader already joins wrapped command rows with `\n`, so safe wrapped commands were held even when
every shell line was safe. The classifier now judges each real command boundary and only joins the
`&&`/`||`/`|`/`|&` continuations the shell itself ignores, so `ls -la src &&\nrm -rf ~/Documents`
still holds while `touch made-by-devin.txt &&\nls -la` approves. Deny-by-default is unchanged:
any line that is unsafe or cannot be parsed confidently holds the whole command.

## Tests run (exact commands, exit codes)

- `nice -n 19 bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/test_approver_table.sh`
  - Before the fix (new rows only): exit 1 — `RESULT: 373 passed, 9 failed` (safe multi-line
    approves held; leading/consecutive operators approved).
  - After fix: exit 0 — `RESULT: 392 passed, 0 failed` (`rows=383 approve=71 hold=312`).
- `nice -n 19 bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/test_approver_tick.sh`
  - After adding the Devin safe-wrapped fixture: exit 0 — `RESULT: 32 passed, 0 failed`.
- `python3 -m py_compile lib/approver_classify.py lib/approver_lines.py lib/approver_tables.py`
  - exit 0 (`OK`); generated `__pycache__` was removed before commit.

## What remains unproven / deliberately still held

- Per the LOCAL RUN OVERRIDES, the conformance suite, full suites, builds, installs, Docker and
  benchmarks were NOT run. `test_screen_state.sh`, `test_sealed_runner.py`,
  `test_sandbox_final.py` and `test_release_0175.sh` were not run (unchanged/not owned); inspected
  for conflicts — `test_release_0175.sh` §14 still holds the unsafe wrapped command, and the
  Python classifier tests exercise single-line/sealed-runner paths only.
- Still held by design (ambiguous or continuation the classifier will not reconstruct):
  backslash-newline, quotes spanning lines, here-docs/here-strings, redirects and other unfinished
  operators (`>`, `<`, trailing `;`, trailing `&`), glued operators without a preceding space
  (`cmd&&`), inline comments containing quotes, and any unsafe/unknown line.
- The "unknown command: The" and "unrecognised prompt kind" holds are prompt-extraction issues in
  `screen.sh`/`approver.sh`, not the classifier; they still hold safely here but are not fixed by
  this lane (see below).

## Needs from other lanes

- `lib/screen.sh` (`_osrc_scr_devin`, and the equivalent approval paths for other engines):
  - Exclude status/prose rows that sit between the approval header and the command/menu (the
    "The ..." status line behind the 57 `unknown command: The` holds) from `OSRC_SCR_CMD`.
  - Ensure every approval action sets `OSRC_SCR_KIND` to `shell`/`write`/`read`; approvals that
    stay `other` produce `unrecognised prompt kind` (55 holds). Devin `Exec/Write/Edit/Create/
    Overwrite/Read` already map; audit the remaining engines/actions.
  - For display-wrapped commands, prefer joining wrap rows with a space (or passing wrap
    metadata) when the break is a display wrap, so safe wrapped commands do not depend on the
    classifier's `&&`/`||`/`|` continuation join. Add a fixture like
    `dv-approval-status-line.ansi` reproducing the status row.
- `references/screen-and-approver.md`: update the "multi-line commands held" wording to describe
  line-by-line judgment and the remaining hold cases above.
- No change needed in `lib/approver.sh`; it already forwards `OSRC_SCR_KIND`/`OSRC_SCR_CMD`.

## Round 2

Branch `cloud/osrc-l4-r2` (from `cloud/osrc-l4-approver` @ bcdcc75). Fixes Astra's P1–P3 findings.

### What changed

- **Wrap vs newline (P1-1)**: `lib/screen.sh` `_osrc_scr_breaks` sets `OSRC_SCR_BREAKS`, one letter per break
  between command rows: `n` newline for sure (row + next word fit in the widest captured row, capped at 60
  columns), `s` newline-or-wrap, `h` also a mid-word wrap (row is full width, row not found, non-ASCII).
  `approver.sh` forwards it as `--breaks`. `lib/approver_lines.py:interpretations()` expands every ambiguous break
  into each possible text; the command approves only if **all** readings are safe. No breaks given = all `h`.
- **Failed `cd` (P1-2)**: new `lib/approver_flow.py` judges each segment in every directory it may run in; only a
  segment chained by `&&` after `cd` uses the new directory alone. `cd` inside a pipeline holds.
- **Earlier step changes path resolution (P1-3)**: after `git switch`, `mv`, `rm`, `ln`, `cp`, `rmdir`, `chmod`, `git mv/rm`
  any later write, redirect or `cd` holds (touch, mkdir, tee, sed -i, git add/commit are exempt).
- **Unicode whitespace (P1-4)**: comment detection strips only space/tab; `check_characters()` holds any other
  whitespace, control, format or invisible character before parsing.
- **Devin status line (P2-5)**: modal reader drops leading prose rows, and keeps the command only if its first row
  contains the menu's `Exec(prog)` word; otherwise nothing is extracted (hold).
- **Layouts (P2-6)**: Codex edit prompts set `PATH` from the single `<file> (+N -M)` row (none/several = empty = hold).
  Gemini `Allow execution of: 'cmd'?` -> shell + command, `Apply this change?` -> write (no path = hold); other
  numbered menus stay `other`. `gemini:"1. Allow once"` is now an approve-once row.
- **`|&` (P2-7)**: held (bash 3.2 rejects it); removed from continuation joining.
- **Quoted punctuation (P3-8)**: `split_segments` compares a quote-preserving lex with the posix one, so `echo "|" ";"` approves again.
- **Docs (P3-9)**: `references/screen-and-approver.md` held-command list rewritten.
- Housekeeping: `test_screen_state.sh` table gained the fixtures the base branch added without rows (it failed on the base).
  `approver_classify.py` 905 lines; no file over 1000.

### Tests (exact commands, exit codes)

- `nice -n 19 bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/test_approver_table.sh` — exit 0, `432 passed, 0 failed`
  (40 new rows; table now marks `⏎` = reader-established newline, `↩` = ambiguous row break).
  Before the fix the new rows for wrap, failed cd, tree change, U+2003, `|&` and quoted punctuation approved/held wrongly
  (probed against bcdcc75's lib: `git branch⏎ls`, `cd src⏎touch ../x`, `git switch dev⏎touch f`, ` #`, `pwd |& cat` all approved; `echo "|" ";"` held).
- `nice -n 19 bash .../tests/test_approver_tick.sh` — exit 0, `48 passed, 0 failed` (exact-extraction asserts, status-line fixture, Codex/Gemini layouts).
- `nice -n 19 bash .../tests/test_screen_state.sh` — exit 0, `261 passed, 0 failed`.
- `nice -n 19 bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh` — exit 1, `241 passed, 6 failed, 1 skipped`.
  The 6 failures are `test_harness_isolation`, `test_vocab_hygiene`, `test_supervise_pgroup_kill`, `test_parity_insource_refresh`,
  `test_conformance_suite_timeout`, `test_sealed_fixes`. I re-ran each on an untouched checkout of bcdcc75 in this container
  (running as root, no OS guard for the sealed matrix) and they fail the same way there, so they are environmental, not from this change.
  `test_approver_table`, `test_approver_tick`, `test_screen_state`, `test_sealed_runner` and `test_release_0175` pass inside conformance.

### Unproven

- The Gemini and Codex-edit fixtures are **constructed** from documented wording, not captured from a real session.
- `n` classification assumes apps wrap no narrower than 60 columns; a TUI wrapping narrower than that inside a wider pane could
  be read as a real newline. Rows over 60 columns are always ambiguous.
- Git Bash / Linux execution of the full suites was not run here (only Linux, bash 5).

## Needs from other lanes

- None. (`lib/approver.sh` got a 2-line change to forward `--breaks` and the Gemini once-row; `lib/screen.sh` and `test_screen_state.sh` were edited because the findings point there.)

## Round 3

Branch `cloud/osrc-l4-r3` (from `cloud/osrc-l4-r2` @ cde0015). Per the orchestrator's binding decision the
line-by-line approval was not patched again: the approver now **fails closed** on anything ambiguous, and
the clever code from rounds 1-2 is deleted. Net change vs cde0015: `lib/` +132 / -339 (all files +275 / -384).
`lib/approver_lines.py` and `lib/approver_flow.py` are gone; `_osrc_scr_breaks` and `OSRC_SCR_BREAKS` are gone.

### The new rules (classifier `lib/approver_classify.py`)

- **Rows** (`join_rows`): the reader cannot prove a box's width, so every row break may be a display wrap.
  A multi-row command approves only if every row but the last ends in ` &&`, ` ||` or ` |`, the next row
  starts a plain word (`[A-Za-z0-9_./]`), the break is outside quotes (the rows lex the same joined with a
  space and with nothing), and the whole text is ASCII. Then it is judged as one line. Everything else holds.
- **Chains**: with two or more parts, any `cd` holds, and any write except in-place ones (touch, mkdir, tee,
  sed -i, git add, git commit) holds unless it is the last part. So a branch switch, `git checkout -b`, mv,
  rm, ln, cp ... followed by anything (read, redirect, write) holds. No directory tracking is left.
- **Wrappers**: `nice` returns the wrapped command's own rule (no `nice:` label), and `nice cd` holds.
  `env` was already judged by the inner command; every other wrapper (`command`, `time`, `nohup`, `xargs`,
  `sudo`, `watch`) is on the not-safe list.
- **Tokens**: one shlex pass on the command plus the same pass on a copy whose quoted or backslash-escaped
  `;&|()<>` are masked; an operator is real only where both agree. Unequal token counts hold.
- **Characters**: any whitespace other than space/tab/newline, control or invisible character holds (as in r2).

### Reader / tick (`lib/screen.sh`, `lib/approver.sh`)

- U+00A0 is rewritten to a space only directly after a glyph (CC draws `⏺\u00a0`); anywhere else it reaches
  the classifier as drawn and holds.
- Devin: only the exact status message `The agent is waiting for your approval…` is skipped, and only above
  the command. Any other row (`Make all`) stays in the command, which then holds. The `Exec(prog)` word check
  is deleted (real captures name `jq` for a command that starts `SCRATCH=…`, and it no longer guards anything).
- Codex: the selected `›` row bounds both scans. Shell: the command is the first `$ ` row and every row after
  it up to the selected row (a wrapped row starting `1. ` or `$ ` no longer ends or restarts it). Edit: every
  `<path> (+N -M)` row up to the selected row counts; exactly one is required.
- Gemini: back to main's reader. Every approval menu is `other` and holds (the matcher was built from a
  constructed fixture; the real 0.58 layout puts the command in a separate box). `gemini:"1. Allow once"` removed.
- Revalidation under the lock compares kind, path and command, re-checks the once-row, re-reads the worktree
  root, and re-runs the classifier; any difference = no Enter.

### Finding -> fix or "held by design", with its regression test

| # | Finding | Outcome | Test |
|---|---------|---------|------|
| 1 | Wrap read as newline (`git branch`/`ls`) | Held by design: non-operator row breaks hold | table `git branch⏎ls`; tick `finding 1` (Devin capture) |
| 2 | Recapture ignores changed decision | Fixed: kind/path/cmd/once-row/root compared, verdict recomputed | tick `finding 2` (kind shell->write; worktree changes) |
| 3 | Skipped `cd` in `check || cd x && write` | Held by design: `cd` in any chain | table `test -d src || cd src && touch ../x` |
| 4 | Read after branch switch | Held by design: switch followed by anything | table `git switch dev; cat README.md < x`, `git switch dev && cat README.md` |
| 5 | `nice:` label hides a switch | Fixed: nice returns the inner rule | table `nice git switch dev && touch …`, `nice -n 5 git switch dev && cat …`, `nice cd src` |
| 6 | Devin prose heuristic drops `Make all` | Fixed: exact status message only | tick `finding 6` (extraction keeps the row; tick holds) |
| 7 | NBSP erased before the check | Fixed: NBSP kept outside glyph prefixes; classifier holds it; `#` rows hold | tick `finding 7`; table rows with U+00A0 |
| 8 | Codex scan stops at `1. notes.txt` | Fixed: bounded by the selected row, both scans | tick `finding 8` (edit), `finding 8b` (shell, found in self-review) |
| 9 | Gemini question outside the modal; 0.58 layout | Held by design: all Gemini approvals hold | tick `finding 9` (shell question above an edit; 0.58 `[Shell]` layout); `test_screen_state` rows now `other` |
| 10 | 2,047 directory checks | Held by design: no directory tracking, `cd` in a chain holds | table `cd a && cd b && … && pwd` |
| 11 | `ls Meeting\ Notes.txt` held | Fixed: masked single-pass tokenizer | table `ls Meeting\ Notes.txt`, `cat Meeting\ Notes.txt README.md`, `echo a\|b`, `ls \|cat` |

Every new row/case was run against cde0015's `lib/` (scratch `git worktree`, new tests copied in): table
`447 passed, 19 failed`, tick `47 passed, 12 failed` — each failure is one of the rows above. Against main's
own table (ea34fe0's `approver-table.tsv`) the new classifier differs on one row only: `cd src && ls`
(compound with `cd`, held by design). No single-line row approved on main is held.

Rows that changed from approve to hold on purpose: `ls⏎cat README.md`, `git status⏎git diff --stat`,
`cd src⏎ls`, `touch …⏎ls -la`, the comment-row case, `git branch⏎ls`, `ls -la⏎cat README.md`,
`cd src && ls`, `cd src && touch ../made-by-test.txt`, `git switch dev && ls -la`. Still approved:
`touch made-by-devin.txt &&⏎ls -la`, `ls |⏎cat README.md`, `cd src` alone, `nice -n 5 ls -la`,
`touch x && cat x`, `echo "|" ";"`. Tick fixtures now holding: `dv-approval-modal-wide-wrap`, `gm-approval-shell`.

### Tests (exact commands, exit codes; run from `plugins/outsourcerer/skills/outsourcerer/scripts`)

- `nice -n 19 bash tests/test_approver_table.sh` — exit 0, `466 passed, 0 failed`.
- `nice -n 19 bash tests/test_approver_tick.sh` — exit 0, `59 passed, 0 failed`.
- `nice -n 19 bash tests/test_screen_state.sh` — exit 0, `261 passed, 0 failed`.
- `nice -n 19 python3 tests/test_approval_audit.py` — exit 0. `nice -n 19 python3 tests/test_sandbox_final.py` — exit 0 (1 skipped).
- `OSRC_HOME=<scratch> nice -n 19 python3 tests/test_sealed_runner.py` — exit 0 (without `OSRC_HOME` it errors
  on `KeyError: 'OSRC_HOME'`; conformance sets it).
- `nice -n 19 bash plugins/outsourcerer/skills/outsourcerer/scripts/tests/conformance.sh` (from the repo root) — exit 1,
  `241 passed, 6 failed, 1 skipped`. The six are the same six round 2 recorded as failing on an untouched base in
  this container: `test_harness_isolation`, `test_vocab_hygiene` (running as root, a write that should fail
  succeeds), `test_supervise_pgroup_kill`, `test_parity_insource_refresh`, `test_conformance_suite_timeout`,
  `test_sealed_fixes` (`MATRIX_DENIED: OS guard unavailable`). `test_approver_table`, `test_approver_tick`,
  `test_screen_state`, `test_release_0175` and `test_sealed_runner` pass inside conformance.

### Unproven

- No real Gemini approval capture exists; Gemini approvals simply hold. Codex edit and the variant fixtures are
  constructed from real captures by byte replacement in the test.
- The NBSP-after-glyph rule is checked on mawk here; macOS awk handles `[\200-\377]` byte classes the same way
  by its documented octal escapes, but that was not run on a Mac or Git Bash.
- Devin's exact status message comes from the r2 fixture; if the real wording differs, those prompts hold.

## Needs from other lanes

- None.


## Round 4

Closing edits only, all in the fail-closed direction; no new parsing.

- **Finding 1 (Devin reader):** rows are skipped by position only: first `requires your approval` (else `Approval required`) row above the menu, start at `hdr+1`, stop at the `❭` row. Deleted the content-based `Deny`/`Bypass mode`/`requires your approval`/`Exec(…)` skip arms. The old-layout `$ ` branch now takes the first `$ ` row in the window instead of the last, so a later decoy row is joined into the command (which holds). Four hold cases added in `test_approver_tick.sh` (`# Deny`, `# Bypass mode`, `echo requires your approval`, `Exec(x) ; rm -rf ../x # )`).
- **Finding 2 (Codex edits):** deleted the edit-path extraction and the `cx-edit-approval*` fixtures and tests. Codex edits are `KIND=write` with an empty path and hold, as on main.
- **Finding 3 (pipe exemption):** when the last segment is joined by `|`, all rules are checked. Three rows added to `approver-table.tsv` as `hold`.
- **Finding 4 (NBSP rule):** narrowed to a 3-byte glyph followed by NBSP (`\342??\302\240`). The review's single-glyph `⏺` suggestion broke `❯`-style composer rows (12+ `test_screen_state` failures), so I kept the 3-byte class; accented letters (2-byte) no longer match.
- **Finding 6:** deleted 8 duplicate table rows, two of three constructed `gm-approval-*` fixtures (kept `gm-approval-shell`), and the round-2/3 READY/RESULT files.
- **Not done:** finding 5 (changing-worktree test) is more than a one-line fix; left as is.

Tests (niced, one at a time): `test_approver_table.sh` rc=0 (459 pass); `test_approver_tick.sh` rc=0 (57 pass); `test_screen_state.sh` rc=0 (249 pass). Conformance: see `osrc-l4-r4.RESULT`.

Unproven: how real Codex draws edit targets; the new tests were not run against the old code (the review's probes show those inputs approved before).

## Needs from other lanes
None.

Conformance: `bash .../tests/conformance.sh` was cut short; every suite that ran passed except `test_harness_isolation` ("fail-closed failed ... would inherit live MCP"), which this lane does not touch (checked against the base commit in the log of this round's run).


## Round 5

Stopped parsing harder. The Devin reader (`lib/screen.sh`, `_osrc_scr_devin`) now fails closed:

- It returns a command only when the first `requires your approval` row on screen (searched from row 0)
  starts at column 0 with `This action requires your approval`, lies inside the 25-row window, and sits
  exactly two rows above the `❭` menu row. The one row between is the whole command, unless it is blank,
  starts with `$ `, or starts with a box/rule glyph. Anything else gives an empty command; the classifier
  holds an empty shell command ("no command visible").
- Deleted: the old-layout `└ $` / `$ ` scan and its join loop, the `Approval required` header fallback,
  and every per-row skip arm (blank, `❭`, rule/box rows, the `The agent is waiting for your approval`
  status arm).
- Kind and path still come from the menu's `Kind(target)` tag; selection and scope parsing are unchanged.

Behaviour changes (all toward holding): the old `└ $` layout, wrapped commands, boxed commands, and the
status-line layout now hold for a person. A single-row modal (`dv-approval-modal`, and a variant with
`ls -la`) still approves.

Review findings:
- **1** (`$ ` row in the modal) — closed: a `$ ` row is never read. Probes `touch ../x⏎$ ls` and a lone `$ ls` hold.
- **2** (status-line arm) — closed: arm deleted; `dv-approval-modal-status-line` now holds (tick spec flipped).
  Probe `The agent is waiting for your approval; touch ../x⏎ls` holds.
- **3** (tall command, header outside window) — closed: header searched from row 0 and must be at `m-2`
  inside the window. Probe with 25 command rows and a decoy header row at column 0 holds.
- **4** (missing tests) — old-layout decoy `└ $ touch ../y⏎echo └ $ ls` added as a hold case. The Codex
  `cx-edit` coverage gap is outside this change and left as is.
- **5** — `osrc-l4-r4.READY/RESULT` deleted; table closing quote in `test_screen_state.sh` put back on the last row.

Tests changed: `test_approver_tick.sh` (spec flips, extraction asserts that multi-row fixtures give no
command, 11 round-5 hold probes, one approve probe; the recapture test now uses the one-row
`dv-approval-modal` so it still exercises a would-approve prompt), `test_screen_state.sh` (old-layout rows
expect no command), `test_release_0175.sh` (boxed and old-layout shapes expect no command and hold).
Removed tests for behaviour that no longer exists (status-row skipping, NBSP survival through the join,
`Make all` kept in a joined command); their inputs are now two-row modals and are in the hold probes.

Ran against the old `screen.sh` (new tests, base reader): `test_approver_tick.sh` 12 failed,
`test_screen_state.sh` 2 failed. With the fix:
- `nice bash tests/test_approver_tick.sh` rc=0 (59 passed)
- `nice bash tests/test_screen_state.sh` rc=0 (248 passed)
- `nice bash tests/test_release_0175.sh` rc=0 (83 passed)
- Conformance: see below.

Size: `git diff --shortstat caf8b00 -- plugins` is 50 insertions, 78 deletions (net −28).

Unproven: real Devin layouts other than the captured ones now always hold; if Devin wraps routine
commands often, users will see more held prompts. Not run on macOS bash 3.2 or Git Bash; the code uses
only `case`, `[ ]` and the existing helpers.

## Needs from other lanes
None.
