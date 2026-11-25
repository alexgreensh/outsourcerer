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
for spec in "devin|dv-approval|2" "devin|dv-approval-wrapped|2" "devin|dv-approval-modal-safe-wrapped|2" "devin|dv-approval-modal-status-line|2" "devin|dv-approval-modal-box|2" "devin|dv-approval-modal-rm|2" "devin|dv-approval-modal-wide-wrap|2" "codex|cx-approval|0" "gemini|gm-approval-shell|2" "gemini|gm-trust-folder-menu|2" "agy|agy-approval|0" "agy|agy-trust-folder-menu|2" "cc|cc-trust-folder-menu|2"; do
  PROV="${spec%%|*}"; rest="${spec#*|}"; f="${rest%%|*}"; want="${rest#*|}"
  rm -rf "$OSRC_HOME/approver/held" "$OSRC_HOME/approver/pressed"; : > "$KEYS"; CAP="$FX/$f.ansi"; AFTER="$FX/cc-idle-after-work.ansi"
  [ "$PROV" = cc ] || AFTER="$FX/dv-idle-after-work.ansi"
  out="$(osrc_approver_tick sess sess)"; rc=$?
  [ "$rc" = "$want" ] && ok || bad "$f: want rc $want got $rc ($out)"
done

# The reader returns a command only for header row, one command row, menu; anything else is empty.
_extract() { # <engine> <fixture> -> sets OSRC_SCR_* from the capture
  _osrc_screen_analyze_text "$1" < "$FX/$2.ansi"
}
NLX="$(printf '\nx')"; NLX="${NLX%x}"
_extract devin dv-approval-modal; [ "$OSRC_SCR_CMD" = "SCRATCH=/tmp/osrc-scratch && jq -r .name /tmp/osrc-scratch/report.json; echo done" ] && ok || bad "devin modal command: [$OSRC_SCR_CMD]"
for f in dv-approval dv-approval-modal-status-line dv-approval-modal-safe-wrapped dv-approval-modal-box; do
  _extract devin $f; [ -z "$OSRC_SCR_CMD" ] && [ "$OSRC_SCR_KIND" = shell ] && ok "devin $f: no command" || bad "devin $f: read [$OSRC_SCR_CMD]"
done

# ---- round 3 (Astra round-2 review): one case per screen/approver finding, each must HOLD -------
# _variant <src fixture> <out name> <python bytes.replace pairs...>: a capture built from a real one.
_variant() {
  python3 - "$FX/$1.ansi" "$TMP/$2.ansi" "${@:3}" <<'PY'
import sys
b = open(sys.argv[1], "rb").read()
for i in range(3, len(sys.argv), 2):
    old, new = (x.encode().decode("unicode_escape").encode("latin-1") for x in sys.argv[i:i + 2])
    assert old in b, old; b = b.replace(old, new, 1)
open(sys.argv[2], "wb").write(b)
PY
}
_tick_fx() { # <engine> <capture file> -> rc of one tick, no keys may be sent for a hold
  PROV="$1"; rm -rf "$OSRC_HOME/approver/held" "$OSRC_HOME/approver/pressed"; : > "$KEYS"; CAP="$2"; AFTER="$FX/dv-idle-after-work.ansi"
  osrc_approver_tick sess sess >/dev/null; echo $?
}
# 1: a narrow box can wrap `git branch ls` after "branch"; the break is not after &&/||/|, so it holds.
_variant dv-approval-modal-safe-wrapped f1 ' touch made-by-devin.txt &&\n ls -la' ' git branch\n ls' 'Exec(touch)' 'Exec(git)'
[ "$(_tick_fx devin "$TMP/f1.ansi")" = 2 ] && [ ! -s "$KEYS" ] && ok "finding 1: a row break that may be a wrap holds" || bad "finding 1: git branch / ls not held"
# Round 5: every multi-row or decoy Devin modal holds; only header, one row, menu is read.
i=0
for body in ' ls -la\n  \xc2\xa0# touch ../x' ' ls -la\n rm -rf ../x # Deny' ' ls -la\n echo requires your approval' \
            ' ls -la\n Exec(x) ; rm -rf ../x # )' ' touch ../x\n $ ls' 'The agent is waiting for your approval; touch ../x\n ls'; do
  i=$((i+1)); _variant dv-approval-modal-safe-wrapped r5a$i ' touch made-by-devin.txt &&\n ls -la' "$body" 'Exec(touch)' 'Exec(ls)'
  [ "$(_tick_fx devin "$TMP/r5a$i.ansi")" = 2 ] && [ ! -s "$KEYS" ] && ok "r5: two-row modal holds [$body]" || bad "r5: approved [$body]"
done
# A `$ ` row as the only row holds too (review finding 1: modal row "$ ls" below "touch ../x").
_variant dv-approval-modal-rm r5b ' rm -rf ~/Documents' ' $ ls' 'Exec(rm)' 'Exec(ls)'
[ "$(_tick_fx devin "$TMP/r5b.ansi")" = 2 ] && [ ! -s "$KEYS" ] && ok "r5: lone \$ row holds" || bad "r5: lone \$ row approved"
# Old layout with a decoy `$` row (review finding 4).
_variant dv-approval r5c ' $ \x1b[38;2;220;220;170mtouch\x1b[39m made-by-devin.txt \x1b[38;2;255;255;255m&&\x1b[39m \x1b[38;2;220;220;170mls\x1b[39m' ' $ touch ../y\necho \xe2\x94\x94 $ ls' 'Exec(touch)' 'Exec(ls)'
[ "$(_tick_fx devin "$TMP/r5c.ansi")" = 2 ] && [ ! -s "$KEYS" ] && ok "r5: old-layout decoy holds" || bad "r5: old-layout decoy approved"
# A tall command whose real header is pushed above the window, with a decoy header row (review finding 3).
tall=" touch ../x ||"; for k in $(seq 24); do tall="$tall\n ls ||"; done
_variant dv-approval-modal-rm r5d ' rm -rf ~/Documents' "$tall\nThis action requires your approval.\n ls" 'Exec(rm)' 'Exec(ls)'
[ "$(_tick_fx devin "$TMP/r5d.ansi")" = 2 ] && [ ! -s "$KEYS" ] && ok "r5: tall command with decoy header holds" || bad "r5: tall decoy approved"
# Integration fixup (l4-r5 finding 1/2): the same tall decoy at column 0 once the real title and header
# have scrolled off the visible capture holds, and so does a header on capture row 0.
_variant dv-approval-modal-rm r5e '\xe2\x96\xb2 Approval required\nThis action requires your approval.\n rm -rf ~/Documents' "$tall\nThis action requires your approval.\n ls" 'Exec(rm)' 'Exec(ls)'
[ "$(_tick_fx devin "$TMP/r5e.ansi")" = 2 ] && [ ! -s "$KEYS" ] && ok "fixup: tall decoy at column 0, real header off screen, holds" || bad "fixup: tall decoy approved"
_variant dv-approval-modal-rm r5row0s ' rm -rf ~/Documents' ' ls -la' 'Exec(rm)' 'Exec(ls)'
python3 - "$TMP/r5row0s.ansi" "$TMP/r5row0.ansi" <<'PY2'
import sys
b = open(sys.argv[1], "rb").read(); k = b.index(b"This action requires")
open(sys.argv[2], "wb").write(b[b.rindex(b"\n", 0, k) + 1:])
PY2
_osrc_screen_analyze_text devin < "$TMP/r5row0.ansi"
[ -z "$OSRC_SCR_CMD" ] && [ "$(_tick_fx devin "$TMP/r5row0.ansi")" = 2 ] && [ ! -s "$KEYS" ] && ok "fixup: header on row 0 holds" || bad "fixup: header on row 0 read [$OSRC_SCR_CMD]"
# l4-r5 finding 6: Devin write/read tags are not read (no captured write modal); two-row and headerless bodies hold.
_variant dv-approval-modal-rm w2 ' rm -rf ~/Documents' ' notes.txt\n ../../elsewhere/notes.txt' 'Exec(rm)' 'Write(notes.txt)'
_variant dv-approval-modal-rm w0 'This action requires your approval.\n rm -rf ~/Documents' ' notes.txt' 'Exec(rm)' 'Write(notes.txt)'
for w in w2 w0; do
  _osrc_screen_analyze_text devin < "$TMP/$w.ansi"
  [ "$OSRC_SCR_KIND" = other ] && [ "$(_tick_fx devin "$TMP/$w.ansi")" = 2 ] && [ ! -s "$KEYS" ] && ok "fixup: devin write body $w holds" || bad "fixup: devin write $w kind=$OSRC_SCR_KIND"
done
# A plain one-row read-only command still approves.
_variant dv-approval-modal-rm r5ok ' rm -rf ~/Documents' ' ls -la' 'Exec(rm)' 'Exec(ls)'
_osrc_screen_analyze_text devin < "$TMP/r5ok.ansi"
[ "$OSRC_SCR_CMD" = "ls -la" ] && [ "$(_tick_fx devin "$TMP/r5ok.ansi")" = 0 ] && grep -q Enter "$KEYS" && ok "r5: one-row ls -la approves" || bad "r5: one-row ls -la not approved [$OSRC_SCR_CMD]"
# 8b (same flaw in the shell scan): a wrapped command row starting "1. " no longer ends the command.
_variant cx-approval f8b '  $ \x1b[38;2;137;180;250mtouch\x1b[38;2;205;214;244m made-by-codex.txt\x1b[39m' '  $ touch made-by-codex.txt\n  1. ; rm -rf ../x'
_osrc_screen_analyze_text codex < "$TMP/f8b.ansi"
[ "$OSRC_SCR_CMD" = "touch made-by-codex.txt${NLX}1. ; rm -rf ../x" ] && ok "finding 8b: codex command runs up to the selected row" || bad "finding 8b: codex command cut short: [$OSRC_SCR_CMD]"
[ "$(_tick_fx codex "$TMP/f8b.ansi")" = 2 ] && [ ! -s "$KEYS" ] && ok || bad "finding 8b: truncated codex command approved"
# 9: Gemini approval menus hold: a shell question left above an edit modal, and the 0.58 layout
# ("Allow execution of [Shell]?" with the command in its own box).
_variant gm-approval-shell f9b "Allow execution of: 'touch made-by-gemini.txt'?" 'Allow execution of [Shell]?                    '
[ "$(_tick_fx gemini "$TMP/f9b.ansi")" = 2 ] && [ ! -s "$KEYS" ] && ok "finding 9: gemini f9b holds" || bad "finding 9: gemini f9b approved"
# 2: the locked recapture changes a decision input but not the command text (kind shell -> write,
# then the pane's worktree): no Enter.
_variant dv-approval-modal f2 'Exec(jq)' 'Write(jq)'
for change in kind root; do
  rm -rf "$OSRC_HOME/approver/held" "$OSRC_HOME/approver/pressed"; : > "$KEYS"; PROV=devin; echo 0 > "$TMP/ncap"
  tmux() {
    case "$1" in
      capture-pane) k=$(( $(cat "$TMP/ncap") + 1 )); echo "$k" > "$TMP/ncap"
        if [ "$k" -gt 1 ] && [ "$change" = kind ]; then cat "$TMP/f2.ansi"; else cat "$FX/dv-approval-modal.ansi"; fi ;;
      display-message) if [ "$change" = root ] && [ "$(cat "$TMP/ncap")" -gt 1 ]; then printf '%s\n' "$TMP/wt2"; else printf '%s\n' "$ROOT"; fi ;;
      send-keys) printf '%s\n' "$*" >> "$KEYS" ;;
      *) return 0 ;;
    esac
  }
  mkdir -p "$TMP/wt2"; git -C "$TMP/wt2" init -q; osrc_approver_tick sess sess >/dev/null
  ! grep -q Enter "$KEYS" && ok "finding 2: recapture with a changed $change does not press" || bad "finding 2: pressed after the $change changed"
done
tmux() {
  case "$1" in
    capture-pane) if [ -n "$AFTER" ] && grep -q Enter "$KEYS"; then cat "$AFTER"; else cat "$CAP"; fi ;;
    display-message) printf '%s\n' "$ROOT" ;;
    send-keys) printf '%s\n' "$*" >> "$KEYS" ;;
    *) return 0 ;;
  esac
}

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
