Real `tmux capture-pane -p` tails from live Claude Code sessions (2026-11-13), trimmed to the last
4-6 non-empty lines. Used by test_remote_review.sh to prove the reviewer idle/working/context-bar
readers against real screens, not invented ones.
- cc-idle-composer-ctx37.txt: empty composer, context bar 37%
- cc-idle-composer-ctx56.txt: empty composer, context bar 56%
- cc-working-spinner.txt: mid-turn spinner line `✻ <Verb>… (Ns · ↓ N tokens)` above an EMPTY composer; no "esc to interrupt"
