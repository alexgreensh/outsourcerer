#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# L3: osrc_approver_tick against REAL prompt captures (fixtures/screen) behind a fake tmux.
# policy off -> never acts; safe -> approves a safe command once (Enter, verified closed, logged,
# EVENT approved); holds rm outside the worktree (EVENT approval, logged), stays quiet on the next
# tick (rc 3), re-emits "still held" after OSRC_HOLD_MIN; never approves when the cursor is not on
# the approve-once row; folder-trust prompts always hold.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"; FX="$HERE/fixtures/screen"
TMP="$(mktemp -d "${TMPDIR%/}/.test-aptick.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
# One line per case: ok prints its label, or the test line that called it (file:line + source).
ok(){ pass=$((pass+1)); if [ -n "${1:-}" ]; then echo "PASS: $1"; else
  echo "PASS: line ${BASH_LINENO[0]}: $(sed -n "${BASH_LINENO[0]}{s/^[[:space:]]*//;p;}" "${BASH_SOURCE[1]}" | cut -c1-90)"; fi; }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
export HOME="$TMP/fakehome" OSRC_HOME="$TMP/state"; mkdir -p "$HOME" "$OSRC_HOME"
OSRC_SOURCED=1; export OSRC_SOURCED; set --; . "$SRC" >/dev/null 2>&1
export OSRC_APPROVER_VERIFY_POLLS=3
ROOT="$TMP/wt"; mkdir -p "$ROOT"; git -C "$ROOT" init -q
_endpoint_mutation_lock() { return 0; }; _endpoint_mutation_unlock() { return 0; }
CAP=""; AFTER=""; KEYS="$TMP/keys"; : > "$KEYS"; PROV=cc
_managed_provider() { printf '%s' "$PROV"; }
tmux() {
  case "$1" in
    capture-pane) if [ -n "$AFTER" ] && grep -q Enter "$KEYS"; then cat "$AFTER"; else cat "$CAP"; fi ;;
    display-message) printf '%s\n' "$ROOT" ;;
    send-keys) printf '%s\n' "$*" >> "$KEYS" ;;
    *) return 0 ;;
  esac
}
LOG="$OSRC_HOME/approvals.log"

# policy off (default): never acts
CAP="$FX/cc-permission-bash.ansi"; out="$(osrc_approver_tick sess sess)"; rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && [ ! -s "$KEYS" ] && ok || bad "policy off acted (rc=$rc out=$out)"

# set policy through the CLI function, read back
SESSION_NAME=sess _osrc_cmd_approve_policy safe >/dev/null && [ "$(_osrc_approver_policy_get sess)" = safe ] && ok || bad "approve-policy safe did not persist"
[ "$(_osrc_approver_policy_get other)" = off ] && ok || bad "per-session policy leaked to another session"

# safe command (touch inside the worktree + ls): Enter once, verified closed, logged, EVENT approved
: > "$KEYS"; CAP="$FX/cc-permission-bash.ansi"; AFTER="$FX/cc-idle-after-work.ansi"
out="$(osrc_approver_tick sess sess)"; rc=$?
[ "$rc" = 0 ] && ok || bad "safe command not approved (rc=$rc out=$out)"
[ "$(grep -c 'send-keys -t sess Enter' "$KEYS")" = 1 ] && ok || bad "approve should press Enter exactly once: $(cat "$KEYS")"
grep -q '^EVENT approved sess [0-9]* ' <<<"$out" && grep -q '^NEXT ' <<<"$out" && ok || bad "no EVENT approved/NEXT: $out"
tail -1 "$LOG" | jq -e '.decision=="approve" and .session=="sess" and .engine=="cc" and (.command|contains("touch made-by-test.txt")) and (.rule|length>0)' >/dev/null && ok || bad "approve not logged: $(tail -1 "$LOG")"

# A press that leaves the same prompt open: EVENT approval-not-landed once, the hold file written first, and
# the approver's re-presses (every OSRC_APPROVER_REPRESS_SECS) stay quiet for OSRC_HOLD_MIN (round 2: a stuck
# prompt logged 7 approval-not-landed in 2 minutes).
rm -rf "$OSRC_HOME/approver/held" "$OSRC_HOME/approver/pressed"; : > "$KEYS"; CAP="$FX/cc-permission-bash.ansi"; AFTER=""
outs=""; for i in 1 2 3 4 5 6 7; do outs="$outs$(OSRC_APPROVER_REPRESS_SECS=0 osrc_approver_tick sess sess)
"; done
[ "$(grep -c '^EVENT approval-not-landed sess ' <<<"$outs")" = 1 ] && ok "pressed 7 times, prompt still open: one approval-not-landed" || bad "not-landed events: $(grep -c '^EVENT approval-not-landed' <<<"$outs") [$outs]"
[ "$(grep -c 'send-keys -t sess Enter' "$KEYS")" = 7 ] && ok "the approver keeps retrying the press meanwhile" || bad "presses: $(grep -c Enter "$KEYS")"
[ -n "$(ls "$OSRC_HOME/approver/held"/sess.* 2>/dev/null)" ] && ok "the hold file records the report" || bad "no hold file after not-landed"
f="$(ls "$OSRC_HOME/approver/held"/sess.* | head -1)"; read -r a1 a2 < "$f"; echo "$a1 $((a2 - 301))" > "$f"
out="$(OSRC_APPROVER_REPRESS_SECS=0 osrc_approver_tick sess sess)"
grep -q '^EVENT approval-not-landed sess ' <<<"$out" && ok "5 min later, still not landed: reported again" || bad "no repeat after 5 min: [$out]"

rm -rf "$OSRC_HOME/approver/held" "$OSRC_HOME/approver/pressed"

# rm -rf outside the worktree: HOLD, no keys, EVENT approval + NEXT, logged
: > "$KEYS"; CAP="$FX/cc-permission-bash-rm.ansi"; AFTER=""
out="$(osrc_approver_tick sess sess)"; rc=$?
[ "$rc" = 2 ] && [ ! -s "$KEYS" ] && ok || bad "rm outside worktree not held (rc=$rc keys=$(cat "$KEYS"))"
grep -q '^EVENT approval sess [0-9]* held by policy safe' <<<"$out" && grep -q 'session answer' <<<"$out" && ok || bad "hold not reported: $out"
tail -1 "$LOG" | jq -e '.decision=="hold" and (.rule|test("outside|[(][$][)]"))' >/dev/null && ok || bad "hold not logged: $(tail -1 "$LOG")"
# second tick within OSRC_HOLD_MIN: quiet
out="$(osrc_approver_tick sess sess)"; rc=$?
[ "$rc" = 3 ] && [ -z "$out" ] && ok || bad "repeat hold was not quiet (rc=$rc out=$out)"
# hold deadline: OSRC_HOLD_MIN=0 re-emits "still held"
out="$(OSRC_HOLD_MIN=0 osrc_approver_tick sess sess)"; rc=$?
[ "$rc" = 2 ] && grep -q 'still held, waiting' <<<"$out" && ok || bad "hold deadline did not re-emit (rc=$rc out=$out)"
# prompt gone -> held record cleared, rc 1
CAP="$FX/cc-idle-after-work.ansi"; out="$(osrc_approver_tick sess sess)"; rc=$?
[ "$rc" = 1 ] && [ -z "$(ls "$OSRC_HOME/approver/held/" 2>/dev/null)" ] && ok || bad "held record not cleared after the prompt closed"

# other engines' real prompts
for spec in "devin|dv-approval|0" "devin|dv-approval-wrapped|2" "devin|dv-approval-modal-safe-wrapped|0" "devin|dv-approval-modal-status-line|0" "devin|dv-approval-modal-wide-wrap|2" "codex|cx-approval|0" "codex|cx-edit-approval|0" "codex|cx-edit-approval-multi|2" "gemini|gm-approval-shell|0" "gemini|gm-approval-edit|2" "gemini|gm-approval-other|2" "gemini|gm-trust-folder-menu|2" "agy|agy-approval|0" "agy|agy-trust-folder-menu|2" "cc|cc-trust-folder-menu|2"; do
  PROV="${spec%%|*}"; rest="${spec#*|}"; f="${rest%%|*}"; want="${rest#*|}"
  rm -rf "$OSRC_HOME/approver/held" "$OSRC_HOME/approver/pressed"; : > "$KEYS"; CAP="$FX/$f.ansi"; AFTER="$FX/cc-idle-after-work.ansi"
  [ "$PROV" = cc ] || AFTER="$FX/dv-idle-after-work.ansi"
  out="$(osrc_approver_tick sess sess)"; rc=$?
  [ "$rc" = "$want" ] && ok || bad "$f: want rc $want got $rc ($out)"
done

# round 2: the reader extracts exactly the command (or target) the screen names, and says how each row
# break was drawn. A status row above the command is dropped; the command keeps both of its rows.
_extract() { # <engine> <fixture> -> sets OSRC_SCR_* from the capture
  _osrc_screen_analyze_text "$1" < "$FX/$2.ansi"
}
NLX="$(printf '\nx')"; NLX="${NLX%x}"
_extract devin dv-approval-modal-status-line
[ "$OSRC_SCR_CMD" = "touch made-by-devin.txt &&${NLX}ls -la" ] && [ "$OSRC_SCR_KIND" = shell ] && ok "devin status row above the command is not part of it" || bad "devin status line leaked: kind=$OSRC_SCR_KIND cmd=[$OSRC_SCR_CMD]"
_extract devin dv-approval-modal-safe-wrapped
[ "$OSRC_SCR_CMD" = "touch made-by-devin.txt &&${NLX}ls -la" ] && [ "$OSRC_SCR_BREAKS" = n ] && ok "short rows are real newlines" || bad "safe-wrapped: breaks=$OSRC_SCR_BREAKS cmd=[$OSRC_SCR_CMD]"
_extract devin dv-approval-modal-wide-wrap
case "$OSRC_SCR_BREAKS" in h|s) ok "a full-width row could be a terminal wrap: breaks=$OSRC_SCR_BREAKS" ;; *) bad "full-width row read as a newline: breaks=[$OSRC_SCR_BREAKS]" ;; esac
_extract devin dv-approval-modal; [ "$OSRC_SCR_CMD" = "SCRATCH=/tmp/osrc-scratch && jq -r .name /tmp/osrc-scratch/report.json; echo done" ] && ok || bad "devin modal command: [$OSRC_SCR_CMD]"
_extract codex cx-edit-approval; [ "$OSRC_SCR_KIND" = write ] && [ "$OSRC_SCR_PATH" = notes.txt ] && ok "codex edit names its file" || bad "codex edit: kind=$OSRC_SCR_KIND path=[$OSRC_SCR_PATH]"
_extract codex cx-edit-approval-multi; [ "$OSRC_SCR_KIND" = write ] && [ -z "$OSRC_SCR_PATH" ] && ok "codex multi-file edit leaves the path empty" || bad "codex multi edit: path=[$OSRC_SCR_PATH]"
_extract gemini gm-approval-shell; [ "$OSRC_SCR_KIND" = shell ] && [ "$OSRC_SCR_CMD" = "touch made-by-gemini.txt" ] && ok "gemini allow-execution menu names its command" || bad "gemini shell: [$OSRC_SCR_KIND] [$OSRC_SCR_CMD]"
_extract gemini gm-approval-other; [ "$OSRC_SCR_KIND" = other ] && ok "gemini unknown numbered menu stays other" || bad "gemini other: $OSRC_SCR_KIND"

# cursor NOT on the approve-once row -> hold even for a safe command
PROV=cc; rm -rf "$OSRC_HOME/approver/held"; : > "$KEYS"; AFTER=""
python3 -c 'import sys
b=open(sys.argv[1],"rb").read()
b=b.replace(b" \x1b[38;5;153m\xe2\x9d\xaf\x1b[39m \x1b[38;5;246m1. ", b"   \x1b[38;5;246m1. ",1)
b=b.replace(b"   \x1b[38;5;246m2. \x1b[39mYes, and always", b" \xe2\x9d\xaf \x1b[38;5;246m2. \x1b[39mYes, and always",1)
open(sys.argv[2],"wb").write(b)' "$FX/cc-permission-bash.ansi" "$TMP/cursor2.ansi"
_osrc_screen_analyze_text cc < "$TMP/cursor2.ansi"; case "$OSRC_SCR_SEL" in "2. Yes, and always"*) ok ;; *) bad "cursor2 fixture not built (sel=$OSRC_SCR_SEL)" ;; esac
CAP="$TMP/cursor2.ansi"; out="$(osrc_approver_tick sess sess)"; rc=$?
[ "$rc" = 2 ] && [ ! -s "$KEYS" ] && grep -q 'not an approve-once' <<<"$out" && ok || bad "approved with the cursor on 'always allow' (rc=$rc out=$out)"

# unreadable cwd -> hold, never approve
tmux() { case "$1" in capture-pane) cat "$CAP" ;; display-message) return 1 ;; send-keys) printf '%s\n' "$*" >> "$KEYS" ;; esac; }
rm -rf "$OSRC_HOME/approver/held"; : > "$KEYS"; CAP="$FX/cc-permission-bash.ansi"
out="$(osrc_approver_tick sess sess)"; rc=$?
[ "$rc" = 2 ] && [ ! -s "$KEYS" ] && ok || bad "unknown worktree did not hold (rc=$rc)"

# round-2 review finding 4: a custom OSRC_HOME reaches the classifier and is protected
v="$(export -n OSRC_HOME; _osrc_approver_classify "$ROOT" shell "" "cat $OSRC_HOME/approvals.log")"   # set, NOT exported (as in outsourcerer.sh)
case "$v" in "hold protected location"*) ok ;; *) bad "custom OSRC_HOME not passed to the classifier: $v" ;; esac

# ---- L1 review finding 2: two callers (supervise + beacon) on one prompt press Enter ONCE ---------
# Two real processes, the real endpoint lock, and a slow redraw: after Enter the pane keeps showing
# the same prompt for 2s. Run 3 ways so each layer is proven on its own.
cat > "$TMP/caller.sh" <<'CALLER'
#!/bin/bash
# caller.sh <src> <fx> <state-dir> <root> <stub-lock 0|1>
SRC="$1"; FX="$2"; D="$3"; ROOT="$4"; STUB="$5"
OSRC_SOURCED=1; export OSRC_SOURCED; set --; . "$SRC" >/dev/null 2>&1
[ "$STUB" = 1 ] && { _endpoint_mutation_lock() { return 0; }; _endpoint_mutation_unlock() { return 0; }; }
_managed_provider() { printf cc; }
tmux() {
  case "$1" in
    capture-pane) t="$(cat "$D/pressed-at" 2>/dev/null)"
      if [ -n "$t" ] && [ $(( $(date +%s) - t )) -ge 2 ]; then cat "$FX/cc-idle-after-work.ansi"; else cat "$FX/cc-permission-bash.ansi"; fi ;;
    display-message) printf '%s\n' "$ROOT" ;;
    send-keys) printf '%s\n' "$*" >> "$D/keys"; [ -f "$D/pressed-at" ] || date +%s > "$D/pressed-at" ;;
    *) return 0 ;;
  esac
}
osrc_approver_tick sess sess >/dev/null 2>&1; echo "$?" >> "$D/rcs"
CALLER
two_callers() { # <label> <stub-lock> [env...]
  local d="$TMP/dbl-$1" lbl="$1" stub="$2"; shift 2
  rm -rf "$d"; mkdir -p "$d/home"; : > "$d/keys"
  SESSION_NAME=sess OSRC_HOME="$d/home" _osrc_cmd_approve_policy safe >/dev/null
  env OSRC_HOME="$d/home" OSRC_APPROVER_VERIFY_POLLS=25 "$@" bash "$TMP/caller.sh" "$SRC" "$FX" "$d" "$ROOT" "$stub" &
  env OSRC_HOME="$d/home" OSRC_APPROVER_VERIFY_POLLS=25 "$@" bash "$TMP/caller.sh" "$SRC" "$FX" "$d" "$ROOT" "$stub" &
  wait
  n="$(grep -c 'Enter' "$d/keys")"
  [ "$n" = 1 ] && ok || bad "two callers [$lbl]: Enter pressed $n times (rcs: $(tr '\n' ' ' < "$d/rcs"))"
}
two_callers both 0
two_callers lock-only 0 OSRC_APPROVER_REPRESS_SECS=0
two_callers stamp-only 1

# empty / dotted session id never acts and never deletes another session's held record (finding 13)
mkdir -p "$OSRC_HOME/approver/held"; : > "$OSRC_HOME/approver/held/.keep"; : > "$OSRC_HOME/approver/held/other.cmd"; : > "$KEYS"
osrc_approver_tick "" "" >/dev/null 2>&1; rc1=$?; osrc_approver_tick sess ".." >/dev/null 2>&1; rc2=$?
[ "$rc1" = 1 ] && [ "$rc2" = 1 ] && [ ! -s "$KEYS" ] && [ -e "$OSRC_HOME/approver/held/.keep" ] && [ -e "$OSRC_HOME/approver/held/other.cmd" ] && ok || bad "bad session id acted or deleted held files (rc=$rc1/$rc2)"

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
