# supervise fixtures

Real `tmux capture-pane -p` captures from a live `session start -m haiku` (Claude Code 2.1.323,
2026-11-13), used by test_supervise.sh through a file-backed fake tmux:

- cc-idle-boot.txt        fresh session, empty composer (`❯` + NO-BREAK SPACE + `Try "..."`)
- cc-working-hooks.txt    busy: `✻ Smooshing… (running SessionStart hooks… 6/7 · 3s)`, no "esc to interrupt"
- cc-working-turn.txt     busy mid-turn: `✢ Smooshing… (running UserPromptSubmit hooks… 1/4 · 12s)`
- cc-question-live.txt    turn ended on a yes/no question
- cc-idle-after-work.txt  turn ended with a plain answer (`⏺ ok`)

codex-approval.ansi is the Codex approval menu already used (verified live) by
test_session_send_verify.sh. codex-busy/idle frames in the test are synthetic (no live Codex run:
ChatGPT weekly quota near its cap).

Scrubbed before commit: the project path is replaced with ~/code/demo-app, branch and task names are
generic, and the OSC 8 hyperlink carrying the claude.ai session URL is stripped. Layout and glyphs are untouched.
