#!/usr/bin/env bash
# P2c: session/tmux state classification. Self-contained — sources the script with
# OSRC_SOURCED=1 so main() does not run, then pipes canned pane dumps into
# _pane_state_classify and asserts the JSON state. Also checks `session read`
# without --state stays byte-identical, and that --state emits the classifier JSON.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "$PWD/.test-pane-state.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

OSRC_HOME="$TMP/state"; HOME="$TMP/home"; export OSRC_HOME HOME; mkdir -p "$OSRC_HOME"
OSRC_SOURCED=1; export OSRC_SOURCED; set --; . "$SRC" >/dev/null 2>&1

# classify helper: pipe canned text in, read the .state field out.
state_of(){ printf '%s' "$1" | _pane_state_classify | jq -r '.state'; }

# 1. approval prompt at the tail -> waiting-approval
ap='Reading project structure
Analyzing dependencies
Do you want to proceed with the change? [y/N] '
[ "$(state_of "$ap")" = "waiting-approval" ] && ok "approval prompt -> waiting-approval" || bad "approval prompt misclassified"

# 1b. evidence is the matching prompt line, not empty
ev="$(printf '%s' "$ap" | _pane_state_classify | jq -r '.evidence')"
[ -n "$ev" ] && printf '%s' "$ev" | grep -qi 'proceed' && ok "approval evidence carries the prompt line" || bad "approval evidence empty or wrong: $ev"

# 2. spinner / "esc to interrupt" -> working
wp='Reading file src/foo.sh
⠹ Thinking…
(esc to interrupt)'
[ "$(state_of "$wp")" = "working" ] && ok "spinner/esc -> working" || bad "spinner misclassified"

# 2b. "Running" label -> working
rp='Compiling project
Running tests'
[ "$(state_of "$rp")" = "working" ] && ok "Running label -> working" || bad "Running label misclassified"

# 3. bare prompt -> idle
ip='Previous output line one
Previous output line two
❯'
[ "$(state_of "$ip")" = "idle" ] && ok "bare prompt -> idle" || bad "bare prompt misclassified"

# 4. approval text buried HIGH in scrollback + bare prompt at the bottom -> NOT waiting-approval.
#    40 filler lines before AND after the needle push it above the 30-line tail window, so the
#    only approval-looking text is history the agent already answered, not a current block.
pre=""; for i in $(seq 1 40); do pre="$pre
filler line $i"; done
post=""; for i in $(seq 1 40); do post="$post
trailing filler $i"; done
buried="${pre}
Do you want to proceed? [y/N]
more filler${post}
❯"
bs="$(state_of "$buried")"
[ "$bs" != "waiting-approval" ] && ok "buried approval + bare prompt -> not waiting-approval (got $bs)" || bad "buried approval cried wolf"

# 5. nonsense dump -> unknown
np='asdf qwer zxcv
random words without meaning
nothing to see here'
[ "$(state_of "$np")" = "unknown" ] && ok "nonsense -> unknown" || bad "nonsense misclassified"

# 6. `session read` WITHOUT --state is byte-identical to the raw dump minus blank lines.
SESSION_NAME="testsess"
PANE_CAN='line one

line two
Do you want to proceed? [y/N]

❯'
tmux(){ case "$1" in capture-pane) printf '%s\n' "$PANE_CAN";; *) return 1;; esac; }
expected="$(printf '%s\n' "$PANE_CAN" | grep -v '^[[:space:]]*$')"
actual="$(session read)"
[ "$actual" = "$expected" ] && ok "session read (no --state) is byte-identical" || bad "session read no-state diverged"

# 7. `session read --state` emits the classifier JSON over the same capture.
sj="$(session read --state)"
echo "$sj" | jq -e '.state == "waiting-approval" and (.evidence | type == "string")' >/dev/null \
  && ok "session read --state classifies the pane" || bad "session read --state failed: $sj"

# 8. No-jq fallback must JSON-escape raw ANSI ESC bytes from a real pane capture.
tmux(){ case "$1" in capture-pane) printf '\033[31mThinking\n';; *) return 1;; esac; }
have(){ [ "${1:-}" = tmux ]; } # force only jq absent; session still sees the stubbed tmux lane.
sj="$(session read --state)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$sj" | LC_ALL=C grep "$(printf '\033')" >/dev/null 2>&1 \
   && printf '%s' "$sj" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
  ok "session read --state no-jq output escapes ANSI ESC and is valid JSON"
else
  bad "session read --state no-jq output contains raw ESC, is invalid JSON, or returned rc=$rc"
fi

# 9. Capture failure is intentionally a successful, valid unknown-state observation.
tmux(){ return 1; }
sj="$(session read --state)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$sj" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["state"] == "unknown"' >/dev/null 2>&1; then
  ok "session read --state capture failure emits valid unknown JSON with rc 0"
else
  bad "session read --state capture failure returned rc=$rc or invalid/non-unknown JSON: $sj"
fi

# 10. Codex approval menu -> waiting-approval. Verified live: a Codex fix session sat blocked on
#     this menu and supervision was blind to it (the footer + label were not in the vocabulary),
#     stalling silently for 16 minutes. The numbered "1. Yes, proceed" rows have NO ❯ marker, so the
#     old ❯-keyed pattern missed them; the "Press enter to confirm or esc to cancel" footer is the
#     reliable Codex signature.
codex_ap='Applying patch to src/main.rs
1. Yes, proceed
2. Yes, and don'"'"'t ask again for this project
3. No, skip this command
Press enter to confirm or esc to cancel'
[ "$(state_of "$codex_ap")" = "waiting-approval" ] && ok "Codex approval menu -> waiting-approval" || bad "Codex approval menu misclassified (blind to the footer)"

# 10b. A single-option Codex approval (just "1. Yes, proceed" + footer) is still waiting-approval.
codex_one='Running: rm -rf target/
1. Yes, proceed
Press enter to confirm or esc to cancel'
[ "$(state_of "$codex_one")" = "waiting-approval" ] && ok "single-option Codex approval -> waiting-approval" || bad "single-option Codex approval misclassified"

# 11. Claude/Devin approval menu with a scoped-allow option -> waiting-approval (the scoped
#     "always allow ... in <proj>" label is the Claude/Devin approval signature; the ❯-marked row
#     is already covered by the existing pattern, this confirms the scoped-allow variant). Real
#     Claude/Devin menus use ARROW-MARKER rows (❯) WITHOUT numbers (unlike Codex's numbered rows).
claude_ap='Claude Code wants to run: bash test.sh
❯ Approve once
  always allow bash test.sh in /home/user/repo
  No, don'"'"'t run this command'
[ "$(state_of "$claude_ap")" = "waiting-approval" ] && ok "Claude/Devin scoped-allow approval -> waiting-approval" || bad "Claude/Devin scoped-allow approval misclassified"

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
