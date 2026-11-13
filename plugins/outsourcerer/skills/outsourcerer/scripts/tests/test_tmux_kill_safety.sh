#!/bin/bash
# Guard: no test may kill a tmux server that could be the developer's real one.
# Inside a tmux pane $TMUX names the real socket and overrides TMUX_TMPDIR, so a bare
# `tmux kill-server` in a test killed every live delegate session on 2026-11-13.
# Rule: every file that runs `tmux ... kill-server` must either pass -L/-S on that call,
# run it through `env -u TMUX`, or `unset TMUX` somewhere in the file.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
fail=0
for f in "$DIR"/*.sh "$DIR"/../outsourcerer.sh "$DIR"/../lib/*.sh; do
  [ -f "$f" ] || continue
  case "$f" in */test_tmux_kill_safety.sh) continue ;; esac
  grep -n 'tmux[^|;&]*kill-server' "$f" 2>/dev/null | while IFS= read -r line; do
    case "$line" in *' -L '*|*' -S '*|*'env -u TMUX'*) continue ;; esac
    grep -q 'unset TMUX' "$f" && continue
    echo "FAIL: $f:${line%%:*} kills a tmux server without -L/-S or clearing TMUX"
    echo x >> "${TMPDIR:-/tmp}/.osrc-kill-safety.$$"
  done
done
if [ -f "${TMPDIR:-/tmp}/.osrc-kill-safety.$$" ]; then rm -f "${TMPDIR:-/tmp}/.osrc-kill-safety.$$"; echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
