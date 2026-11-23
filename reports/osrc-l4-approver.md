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
