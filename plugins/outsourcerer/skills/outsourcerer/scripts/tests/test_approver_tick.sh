#!/bin/bash
# L3: osrc_approver_tick against REAL prompt captures (fixtures/screen) behind a fake tmux.
# policy off -> never acts; safe -> approves a safe command once (Enter, verified closed, logged,
# EVENT approved); holds rm outside the worktree (EVENT approval, logged), stays quiet on the next
# tick (rc 3), re-emits "still held" after OSRC_HOLD_MIN; never approves when the cursor is not on
# the approve-once row; folder-trust prompts always hold.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"; FX="$HERE/fixtures/screen"
TMP="$(mktemp -d "$HERE/.test-aptick.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; ok(){ pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
export OSRC_HOME="$TMP/state"; mkdir -p "$OSRC_HOME"
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
printf '%s\n' "$out" | grep -q '^EVENT approved sess [0-9]* ' && printf '%s\n' "$out" | grep -q '^NEXT ' && ok || bad "no EVENT approved/NEXT: $out"
tail -1 "$LOG" | jq -e '.decision=="approve" and .session=="sess" and .engine=="cc" and (.command|contains("touch made-by-test.txt")) and (.rule|length>0)' >/dev/null && ok || bad "approve not logged: $(tail -1 "$LOG")"

# rm -rf outside the worktree: HOLD, no keys, EVENT approval + NEXT, logged
: > "$KEYS"; CAP="$FX/cc-permission-bash-rm.ansi"; AFTER=""
out="$(osrc_approver_tick sess sess)"; rc=$?
[ "$rc" = 2 ] && [ ! -s "$KEYS" ] && ok || bad "rm outside worktree not held (rc=$rc keys=$(cat "$KEYS"))"
printf '%s\n' "$out" | grep -q '^EVENT approval sess [0-9]* held by policy safe' && printf '%s\n' "$out" | grep -q 'session answer' && ok || bad "hold not reported: $out"
tail -1 "$LOG" | jq -e '.decision=="hold" and (.rule|test("outside"))' >/dev/null && ok || bad "hold not logged: $(tail -1 "$LOG")"
# second tick within OSRC_HOLD_MIN: quiet
out="$(osrc_approver_tick sess sess)"; rc=$?
[ "$rc" = 3 ] && [ -z "$out" ] && ok || bad "repeat hold was not quiet (rc=$rc out=$out)"
# hold deadline: OSRC_HOLD_MIN=0 re-emits "still held"
out="$(OSRC_HOLD_MIN=0 osrc_approver_tick sess sess)"; rc=$?
[ "$rc" = 2 ] && printf '%s\n' "$out" | grep -q 'still held after' && ok || bad "hold deadline did not re-emit (rc=$rc out=$out)"
# prompt gone -> held record cleared, rc 1
CAP="$FX/cc-idle-after-work.ansi"; out="$(osrc_approver_tick sess sess)"; rc=$?
[ "$rc" = 1 ] && [ -z "$(ls "$OSRC_HOME/approver/held/" 2>/dev/null)" ] && ok || bad "held record not cleared after the prompt closed"

# other engines' real prompts
for spec in "devin|dv-approval|0" "codex|cx-approval|0" "agy|agy-approval|0" "agy|agy-trust-folder-menu|2" "cc|cc-trust-folder-menu|2"; do
  PROV="${spec%%|*}"; rest="${spec#*|}"; f="${rest%%|*}"; want="${rest#*|}"
  rm -rf "$OSRC_HOME/approver/held"; : > "$KEYS"; CAP="$FX/$f.ansi"; AFTER="$FX/cc-idle-after-work.ansi"
  [ "$PROV" = cc ] || AFTER="$FX/dv-idle-after-work.ansi"
  out="$(osrc_approver_tick sess sess)"; rc=$?
  [ "$rc" = "$want" ] && ok || bad "$f: want rc $want got $rc ($out)"
done

# cursor NOT on the approve-once row -> hold even for a safe command
PROV=cc; rm -rf "$OSRC_HOME/approver/held"; : > "$KEYS"; AFTER=""
python3 -c 'import sys
b=open(sys.argv[1],"rb").read()
b=b.replace(b" \x1b[38;5;153m\xe2\x9d\xaf\x1b[39m \x1b[38;5;246m1. ", b"   \x1b[38;5;246m1. ",1)
b=b.replace(b"   \x1b[38;5;246m2. \x1b[39mYes, and always", b" \xe2\x9d\xaf \x1b[38;5;246m2. \x1b[39mYes, and always",1)
open(sys.argv[2],"wb").write(b)' "$FX/cc-permission-bash.ansi" "$TMP/cursor2.ansi"
_osrc_screen_analyze_text cc < "$TMP/cursor2.ansi"; case "$OSRC_SCR_SEL" in "2. Yes, and always"*) ok ;; *) bad "cursor2 fixture not built (sel=$OSRC_SCR_SEL)" ;; esac
CAP="$TMP/cursor2.ansi"; out="$(osrc_approver_tick sess sess)"; rc=$?
[ "$rc" = 2 ] && [ ! -s "$KEYS" ] && printf '%s' "$out" | grep -q 'not an approve-once' && ok || bad "approved with the cursor on 'always allow' (rc=$rc out=$out)"

# unreadable cwd -> hold, never approve
tmux() { case "$1" in capture-pane) cat "$CAP" ;; display-message) return 1 ;; send-keys) printf '%s\n' "$*" >> "$KEYS" ;; esac; }
rm -rf "$OSRC_HOME/approver/held"; : > "$KEYS"; CAP="$FX/cc-permission-bash.ansi"
out="$(osrc_approver_tick sess sess)"; rc=$?
[ "$rc" = 2 ] && [ ! -s "$KEYS" ] && ok || bad "unknown worktree did not hold (rc=$rc)"

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
