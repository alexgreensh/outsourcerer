# supervise fixtures

Real `tmux capture-pane -p` captures from a live `session start -m haiku` (Claude Code 2.1.323,
2026-11-13), used by test_supervise.sh through a file-backed fake tmux:

- cc-idle-boot.txt        fresh session, empty composer (`❯` + NO-BREAK SPACE + `Try "..."`)
- cc-working-hooks.txt    busy: `✻ Smooshing… (running SessionStart hooks… 6/7 · 3s)`, no "esc to interrupt"
- cc-working-turn.txt     busy mid-turn: `✢ Smooshing… (running UserPromptSubmit hooks… 1/4 · 12s)`
- cc-question-live.txt    turn ended on a yes/no question
- cc-idle-after-work.txt  turn ended with a plain answer (`⏺ ok`)

From a live `claude --model haiku` on a private tmux server (Claude Code 2.1.325, 2026-11-15), used by
test_supervise_lifecycle.sh (SUP):

- cc-idle-bg-shell.txt / .ansi       turn ended while its background `sleep 240` runs:
                                     `✻ Crunched for 44s · done 11:45 PM · 1 shell still running`, footer `⏵⏵ auto mode on · 1 shell`
- cc-bg-shell-finished-working.txt   the same pane after the shell exited: summary line lost its shell
                                     count, `⏺ Background command ... completed`, a new turn running

codex-approval.ansi is the Codex approval menu already used (verified live) by
test_session_send_verify.sh. codex-busy/idle frames in the test are synthetic (no live Codex run:
ChatGPT weekly quota near its cap).

Scrubbed before commit: the project path is replaced with ~/code/demo-app, branch and task names are
generic, and the OSC 8 hyperlink carrying the claude.ai session URL is stripped. Layout and glyphs are untouched.
