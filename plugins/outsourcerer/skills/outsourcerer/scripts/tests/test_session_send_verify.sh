#!/usr/bin/env bash
# Bug A — `session send` must SUBMIT what it typed and VERIFY it left the composer, then report
# honestly. It must NEVER print "sent" when nothing was submitted, and on failure it must say what
# state the pane is actually in. Also: when the pane is showing an interactive choice menu, `send`
# refuses helpfully (options + the `session answer` command) instead of typing into the menu, and
# `session answer` selects an option by index/label and verifies the menu closed.
#
# Self-contained: sources the script with OSRC_SOURCED=1 (main() does not run) and fakes `tmux` as
# a function that logs send-keys calls and returns canned capture-pane content, matching the
# test_managed_send.sh pattern.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "$PWD/.test-send-verify.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"; mkdir -p "$OSRC_HOME"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
OSRC_SOURCED=1; export OSRC_SOURCED; set --; . "$SRC" >/dev/null 2>&1

PANE="sess-sv"
SEND_LOG=""
CAPTURE_STATE=""

# Fake tmux: routes capture-pane to a canned file ($CAPTURE_FILE), logs send-keys to $SEND_LOG,
# and toggles a post-submit capture via $CLOSED. Each test redefines tmux() as needed.
tmux() {
  case "$1" in
    capture-pane) if [ "${CLOSED:-0}" = 1 ]; then printf '❯\n'; else cat "$CAPTURE_FILE"; fi ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG" ;;
    *) return 0 ;;
  esac
}

# ---- _managed_send_submitted: pane changes away from the text-in-composer snapshot -> submitted --
CAPTURE_FILE="$TMP/typed"; printf '❯ echo hello\n' > "$CAPTURE_FILE"
CLOSED=0
tmux() {
  case "$1" in
    capture-pane) if [ "${CLOSED:-0}" = 1 ]; then printf 'echo hello\nresult\n❯\n'; else cat "$CAPTURE_FILE"; fi ;;
    send-keys) case " $* " in *" Enter "*) CLOSED=1 ;; esac ;;
    *) return 0 ;;
  esac
}
typed="$(_managed_pane_tail "$PANE")"
tmux send-keys -t "$PANE" Enter
_managed_send_submitted "$PANE" "$typed"; rc=$?
[ "$rc" = 0 ] && ok "submission verified when the pane changed away from the typed text" || bad "submission not detected (rc=$rc)"

# ---- _managed_send_submitted: pane never changes (Enter eaten) -> NOT submitted (rc 1) ---------
CAPTURE_FILE="$TMP/stuck"; printf '❯ echo hello\n' > "$CAPTURE_FILE"
CLOSED=0
tmux() {
  case "$1" in
    capture-pane) cat "$CAPTURE_FILE" ;;   # Enter eaten -> pane never changes
    send-keys) : ;;
    *) return 0 ;;
  esac
}
typed="$(_managed_pane_tail "$PANE")"
tmux send-keys -t "$PANE" Enter
OSRC_SEND_VERIFY_POLLS=3 _managed_send_submitted "$PANE" "$typed"; rc=$?
[ "$rc" = 1 ] && ok "Enter eaten -> NOT submitted (rc 1), never falsely 'sent'" || bad "stuck composer reported submitted (rc=$rc)"

# ---- _managed_send_submitted: blanked pane -> submitted (rc 0) --------------------------------
CLOSED=0
tmux() {
  case "$1" in
    capture-pane) printf '\n\n' ;;   # blank pane after submit
    send-keys) : ;;
    *) return 0 ;;
  esac
}
_managed_send_submitted "$PANE" "anything"; rc=$?
[ "$rc" = 0 ] && ok "blanked pane after submit -> submitted (rc 0)" || bad "blanked pane misclassified (rc=$rc)"

# ---- _managed_session_send: end-to-end, text + Enter, pane clears -> rc 2 (submitted, unverified)
SEND_LOG="$TMP/send-e2e"; : > "$SEND_LOG"
CAPTURE_FILE="$TMP/e2e-typed"; printf '❯ analyze this\n' > "$CAPTURE_FILE"
CLOSED=0
tmux() {
  case "$1" in
    capture-pane) if [ "${CLOSED:-0}" = 1 ]; then printf 'analyze this\nworking...\n❯\n'; else cat "$CAPTURE_FILE"; fi ;;
    display) printf '0\n' ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG"; case " $* " in *" Enter "*) CLOSED=1 ;; esac ;;
    *) return 0 ;;
  esac
}
_managed_endpoint_live() { return 0; }
_endpoint_mutation_lock() { return 0; }
_endpoint_mutation_unlock() { return 0; }
_obligation_latest_state() { printf ''; }
_obligation_admit() { return 0; }
_obligation_append() { return 0; }
_obligation_guard_begin() { return 0; }
_obligation_guard_end() { return 0; }
_obligation_delivery_unknown() { return 0; }
_managed_provider() { printf 'devin'; }
_state_jsonl_read() { printf ''; }
unset OSRC_EXTERNAL_RECEIPT_PROBE OSRC_EXTERNAL_COMPOSER_PROBE
_managed_session_send "$PANE" "analyze this"; rc=$?
if [ "$rc" = 2 ] \
   && grep -q 'send-keys -t sess-sv -l -- analyze this' "$SEND_LOG" \
   && grep -q 'send-keys -t sess-sv Enter' "$SEND_LOG"; then
  ok "managed send types text + Enter and returns rc 2 (submitted, model delivery unverified)"
else
  bad "managed send did not complete the submitted path (rc=$rc)"
fi

# ---- _managed_session_send: Enter eaten -> rc 1 (genuine failure, NEVER 'sent') ---------------
SEND_LOG="$TMP/send-stuck"; : > "$SEND_LOG"
CAPTURE_FILE="$TMP/stuck2"; printf '❯ analyze this\n' > "$CAPTURE_FILE"
CLOSED=0
tmux() {
  case "$1" in
    capture-pane) cat "$CAPTURE_FILE" ;;   # Enter eaten -> pane frozen on the typed text
    display) printf '0\n' ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG" ;;   # never flips CLOSED
    *) return 0 ;;
  esac
}
OSRC_SEND_VERIFY_POLLS=3 _managed_session_send "$PANE" "analyze this"; rc=$?
if [ "$rc" = 1 ]; then
  ok "managed send with Enter eaten -> rc 1 (genuine failure, never 'sent')"
else
  bad "managed send reported success on a stuck composer (rc=$rc)"
fi

# ---- _managed_menu_detect: consent / numbered / cursor / none ----------------------------------
CAPTURE_FILE="$TMP/m-consent"; printf 'Working.\nProceed? [y/N]\n' > "$CAPTURE_FILE"; CLOSED=0
tmux() { case "$1" in capture-pane) cat "$CAPTURE_FILE" ;; *) return 0 ;; esac; }
out="$(_managed_menu_detect "$PANE")"
[ "$(printf '%s\n' "$out" | head -1 | awk '{print $2}')" = consent ] && ok "detect consent menu" || bad "consent not detected"
printf '%s\n' "$out" | grep -q '^PROMPT .*\[y/N\]' && ok "consent report carries the prompt line" || bad "consent report missing prompt"

CAPTURE_FILE="$TMP/m-num"; printf '1. Run tests\n2. Commit\n3. Cancel\n' > "$CAPTURE_FILE"
out="$(_managed_menu_detect "$PANE")"
k="$(printf '%s\n' "$out" | head -1 | awk '{print $2}')"
[ "$k" = numbered ] && ok "detect numbered menu" || bad "numbered not detected ($k)"
printf '%s\n' "$out" | grep -q '^OPT 1 Run tests' && printf '%s\n' "$out" | grep -q '^OPT 3 Cancel' && ok "numbered report lists options by index" || bad "numbered report missing options"

CAPTURE_FILE="$TMP/m-cur"; printf 'Select model\n❯ fable\n  opus\n  sonnet\n' > "$CAPTURE_FILE"
out="$(_managed_menu_detect "$PANE")"
k="$(printf '%s\n' "$out" | head -1 | awk '{print $2}')"
[ "$k" = cursor ] && ok "detect cursor list (prose header excluded)" || bad "cursor not detected ($k)"
printf '%s\n' "$out" | grep -q '^SEL 1 fable' && printf '%s\n' "$out" | grep -q '^OPT 2 opus' && ok "cursor report marks the ❯ row and lists siblings" || bad "cursor report wrong: $out"

# A bare ❯ prompt is NOT a cursor list (only one candidate row).
CAPTURE_FILE="$TMP/m-bare"; printf '❯\n' > "$CAPTURE_FILE"
out="$(_managed_menu_detect "$PANE")"
[ "$(printf '%s\n' "$out" | head -1 | awk '{print $2}')" = none ] && ok "bare ❯ prompt -> none (not a menu)" || bad "bare prompt mistaken for a menu"

# A single numbered prose line is NOT a menu (requires >=2 numbered rows).
CAPTURE_FILE="$TMP/m-one"; printf 'See step 1. Run tests then commit.\n❯\n' > "$CAPTURE_FILE"
out="$(_managed_menu_detect "$PANE")"
[ "$(printf '%s\n' "$out" | head -1 | awk '{print $2}')" = none ] && ok "single numbered prose line -> none" || bad "single numbered line mistaken for a menu"

# ---- _managed_menu_answer: consent y, numbered 2, cursor by label ------------------------------
CAPTURE_FILE="$TMP/a-consent"; printf 'Proceed? [y/N]\n' > "$CAPTURE_FILE"; CLOSED=0
SEND_LOG="$TMP/sl-consent"; : > "$SEND_LOG"
tmux() {
  case "$1" in
    capture-pane) if [ "${CLOSED:-0}" = 1 ]; then printf '❯\n'; else cat "$CAPTURE_FILE"; fi ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG"; case " $* " in *" Enter "*) CLOSED=1 ;; esac ;;
    *) return 0 ;;
  esac
}
_managed_menu_answer "$PANE" y; rc=$?
[ "$rc" = 0 ] && grep -q 'send-keys -t sess-sv -l -- y' "$SEND_LOG" && grep -q 'send-keys -t sess-sv Enter' "$SEND_LOG" \
  && ok "answer consent y -> sends y + Enter, menu closes" || bad "answer consent y failed (rc=$rc)"

CAPTURE_FILE="$TMP/a-num"; printf '1. Run tests\n2. Commit\n3. Cancel\n' > "$CAPTURE_FILE"; CLOSED=0
SEND_LOG="$TMP/sl-num"; : > "$SEND_LOG"
tmux() {
  case "$1" in
    capture-pane) if [ "${CLOSED:-0}" = 1 ]; then printf '❯\n'; else cat "$CAPTURE_FILE"; fi ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG"; case " $* " in *" Enter "*) CLOSED=1 ;; esac ;;
    *) return 0 ;;
  esac
}
_managed_menu_answer "$PANE" 2; rc=$?
[ "$rc" = 0 ] && grep -q 'send-keys -t sess-sv -l -- 2' "$SEND_LOG" \
  && ok "answer numbered 2 -> sends index 2, menu closes" || bad "answer numbered 2 failed (rc=$rc)"

# out-of-range index is refused, nothing typed
CAPTURE_FILE="$TMP/a-num"; printf '1. Run tests\n2. Commit\n3. Cancel\n' > "$CAPTURE_FILE"; CLOSED=0
SEND_LOG="$TMP/sl-num-bad"; : > "$SEND_LOG"
tmux() {
  case "$1" in
    capture-pane) cat "$CAPTURE_FILE" ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG" ;;
    *) return 0 ;;
  esac
}
_managed_menu_answer "$PANE" 9; rc=$?
[ "$rc" = 1 ] && [ ! -s "$SEND_LOG" ] && ok "answer out-of-range index -> refused, nothing typed" || bad "out-of-range index was sent (rc=$rc)"

CAPTURE_FILE="$TMP/a-cur"; printf 'Select model\n❯ fable\n  opus\n  sonnet\n' > "$CAPTURE_FILE"; CLOSED=0
SEND_LOG="$TMP/sl-cur"; : > "$SEND_LOG"
tmux() {
  case "$1" in
    capture-pane) if [ "${CLOSED:-0}" = 1 ]; then printf '❯\n'; else cat "$CAPTURE_FILE"; fi ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG"; case " $* " in *" Enter "*) CLOSED=1 ;; esac ;;
    *) return 0 ;;
  esac
}
_managed_menu_answer "$PANE" opus; rc=$?
# sel at pos1 (fable), target pos2 (opus) -> 1 Down + Enter
if [ "$rc" = 0 ] && grep -q 'send-keys -t sess-sv Down' "$SEND_LOG" && grep -q 'send-keys -t sess-sv Enter' "$SEND_LOG"; then
  ok "answer cursor 'opus' -> 1 Down + Enter, menu closes"
else
  bad "answer cursor failed (rc=$rc): $(cat "$SEND_LOG" 2>/dev/null)"
fi

# ---- infra F3 / static F2: capture FAILURE must never be read as submission success ------------
# _managed_pane_tail pipes capture-pane through grep|tail, which masks the capture exit status. A
# capture failure (rc 1 from tmux) produced an empty string that _managed_send_submitted treated as
# "composer cleared = submitted". The fix preserves capture failure as rc 2 and fails closed.
CAPTURE_FILE="$TMP/fail"; printf '❯ analyze this\n' > "$CAPTURE_FILE"
CLOSED=0
tmux() {
  case "$1" in
    capture-pane) return 1 ;;   # capture ALWAYS fails — the pane is unreadable
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG" ;;
    *) return 0 ;;
  esac
}
: > "$SEND_LOG"
typed="$(_managed_pane_tail "$PANE" 2>/dev/null)"; _trc=$?
# A capture failure must surface as rc 2 from _managed_pane_tail (not rc 0 with empty output).
[ "$_trc" = 2 ] && ok "capture failure -> _managed_pane_tail rc 2 (distinct from blank pane)" || bad "capture failure masked (rc=$_trc)"
OSRC_SEND_VERIFY_POLLS=3 _managed_send_submitted "$PANE" "anything"; rc=$?
[ "$rc" = 2 ] && ok "capture failure during poll -> _managed_send_submitted rc 2 (fail closed, never submitted)" || bad "capture failure forged submission (rc=$rc)"

# End-to-end: _managed_session_send on a pane whose post-Enter capture fails -> rc 1, never "sent".
CAPTURE_FILE="$TMP/fail-e2e"; printf '❯ analyze this\n' > "$CAPTURE_FILE"
CLOSED=0
tmux() {
  case "$1" in
    # Pre-Enter snapshot succeeds (CLOSED=0); post-Enter capture fails (CLOSED=1 -> return 1).
    capture-pane) if [ "${CLOSED:-0}" = 1 ]; then return 1; else cat "$CAPTURE_FILE"; fi ;;
    display) printf '0\n' ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG"; case " $* " in *" Enter "*) CLOSED=1 ;; esac ;;
    *) return 0 ;;
  esac
}
: > "$SEND_LOG"
OSRC_SEND_VERIFY_POLLS=3 _managed_session_send "$PANE" "analyze this"; rc=$?
if [ "$rc" = 1 ]; then
  ok "managed send with post-Enter capture failure -> rc 1 (genuine failure, never 'sent')"
else
  bad "managed send forged success on capture failure (rc=$rc)"
fi

# Pre-Enter capture failure -> rc 1 (no valid baseline to prove submission against).
CAPTURE_FILE="$TMP/fail-pre"; printf '❯ analyze this\n' > "$CAPTURE_FILE"
CLOSED=0
tmux() {
  case "$1" in
    capture-pane) return 1 ;;   # even the pre-Enter snapshot cannot be read
    display) printf '0\n' ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG" ;;
    *) return 0 ;;
  esac
}
: > "$SEND_LOG"
OSRC_SEND_VERIFY_POLLS=3 _managed_session_send "$PANE" "analyze this"; rc=$?
[ "$rc" = 1 ] && ok "managed send with pre-Enter capture failure -> rc 1 (no baseline, fail closed)" || bad "pre-Enter capture failure not handled (rc=$rc)"

# ---- static F3: an unrelated pane redraw must NOT forge submission ------------------------------
# The typed composer line stays unchanged (Enter eaten) while a progress line higher in the tail
# changes. The old whole-tail diff (cur != typed) saw the redraw as submission. The fix compares
# only the composer (bottom) line, so the redraw cannot forge success while the text sits unsent.
CAPTURE_FILE="$TMP/redraw"; printf 'Working...\n❯ analyze this\n' > "$CAPTURE_FILE"
CLOSED=0
REDRAWN=0
tmux() {
  case "$1" in
    # Enter is eaten (composer line unchanged), but a progress redraw changes the line above it.
    capture-pane)
      if [ "${REDRAWN:-0}" = 1 ]; then printf 'Working..\n❯ analyze this\n'; else cat "$CAPTURE_FILE"; fi
      ;;
    send-keys) case " $* " in *" Enter "*) REDRAWN=1 ;; esac ;;
    *) return 0 ;;
  esac
}
typed="$(_managed_pane_tail "$PANE")"
tmux send-keys -t "$PANE" Enter
OSRC_SEND_VERIFY_POLLS=3 _managed_send_submitted "$PANE" "$typed"; rc=$?
if [ "$rc" = 1 ]; then
  ok "unrelated redraw with composer unchanged -> NOT submitted (rc 1), redraw no longer forges success"
else
  bad "unrelated redraw forged submission (rc=$rc)"
fi

# Contrast: a real submit (composer line changes) IS detected even when a redraw also happens.
CAPTURE_FILE="$TMP/redraw-real"; printf 'Working...\n❯ analyze this\n' > "$CAPTURE_FILE"
CLOSED=0
REDRAWN=0
tmux() {
  case "$1" in
    capture-pane)
      if [ "${CLOSED:-0}" = 1 ]; then printf 'Working..\nanalyze this\n❯\n'; else cat "$CAPTURE_FILE"; fi
      ;;
    send-keys) case " $* " in *" Enter "*) CLOSED=1 ;; esac ;;
    *) return 0 ;;
  esac
}
typed="$(_managed_pane_tail "$PANE")"
tmux send-keys -t "$PANE" Enter
OSRC_SEND_VERIFY_POLLS=3 _managed_send_submitted "$PANE" "$typed"; rc=$?
[ "$rc" = 0 ] && ok "real submit (composer line changed) detected despite a concurrent redraw" || bad "real submit missed with redraw (rc=$rc)"

# ---- static F10: menu answers must hold the endpoint mutation lock -----------------------------
# _managed_menu_answer navigates + presses Enter without the lock, so it can race a concurrent
# send/clear/control on the same pane. The fix acquires the lock before detection, revalidates under
# it, and holds it through all keystrokes. Three cases: lock-acquire-gated, under-lock revalidation,
# and the happy path still works under the real lock stubs.

# (a) If the lock cannot be acquired, NO keystrokes are sent (the answer does not mutate without it).
CAPTURE_FILE="$TMP/lock-fail"; printf 'Proceed? [y/N]\n' > "$CAPTURE_FILE"; CLOSED=0
: > "$SEND_LOG"
tmux() {
  case "$1" in
    capture-pane) if [ "${CLOSED:-0}" = 1 ]; then printf '❯\n'; else cat "$CAPTURE_FILE"; fi ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG"; case " $* " in *" Enter "*) CLOSED=1 ;; esac ;;
    *) return 0 ;;
  esac
}
_endpoint_mutation_lock() { return 1; }   # lock contention -> refuse
_endpoint_mutation_unlock() { return 0; }
_managed_menu_answer "$PANE" y; rc=$?
if [ "$rc" = 1 ] && [ ! -s "$SEND_LOG" ]; then
  ok "menu answer refused when the endpoint lock is unavailable (no keystrokes sent)"
else
  bad "menu answer mutated without the lock (rc=$rc, sent=$(cat "$SEND_LOG" 2>/dev/null))"
fi

# (b) Under-lock revalidation: a concurrent op closed the menu before the answer acquired the lock.
# The re-detect returns "none" -> the answer refuses without typing into the now-empty composer.
CAPTURE_FILE="$TMP/lock-reval"; printf 'Proceed? [y/N]\n' > "$CAPTURE_FILE"; CLOSED=1
: > "$SEND_LOG"
tmux() {
  case "$1" in
    # CLOSED=1 from the start: the menu was already closed by a concurrent op.
    capture-pane) printf '❯\n' ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG" ;;
    *) return 0 ;;
  esac
}
_endpoint_mutation_lock() { return 0; }
_endpoint_mutation_unlock() { return 0; }
_managed_menu_answer "$PANE" y; rc=$?
if [ "$rc" = 1 ] && [ ! -s "$SEND_LOG" ]; then
  ok "menu answer revalidates under the lock: gone menu -> refuse, no keystrokes into the composer"
else
  bad "menu answer typed into a gone menu (rc=$rc, sent=$(cat "$SEND_LOG" 2>/dev/null))"
fi

# (c) Happy path: the lock is acquired, the answer is sent, the menu closes. Verifies the lock
# acquisition did not break the normal flow, and that the lock is RELEASED after Enter (the
# close-verification poll runs without holding it).
CAPTURE_FILE="$TMP/lock-ok"; printf 'Proceed? [y/N]\n' > "$CAPTURE_FILE"; CLOSED=0
: > "$SEND_LOG"
LOCK_ACQUIRED=0; LOCK_RELEASED=0
tmux() {
  case "$1" in
    capture-pane) if [ "${CLOSED:-0}" = 1 ]; then printf '❯\n'; else cat "$CAPTURE_FILE"; fi ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG"; case " $* " in *" Enter "*) CLOSED=1 ;; esac ;;
    *) return 0 ;;
  esac
}
_endpoint_mutation_lock() { LOCK_ACQUIRED=1; return 0; }
_endpoint_mutation_unlock() { LOCK_RELEASED=1; return 0; }
_managed_menu_answer "$PANE" y; rc=$?
if [ "$rc" = 0 ] && [ "$LOCK_ACQUIRED" = 1 ] && [ "$LOCK_RELEASED" = 1 ] \
   && grep -q 'send-keys -t sess-sv -l -- y' "$SEND_LOG" && grep -q 'send-keys -t sess-sv Enter' "$SEND_LOG"; then
  ok "menu answer happy path: lock acquired + released, y + Enter sent, menu closed"
else
  bad "menu answer happy path broken (rc=$rc, lock=$LOCK_ACQUIRED/$LOCK_RELEASED)"
fi

# ---- static: the dispatch wires menu refusal + the new rc messages + control/answer subcommands -
grep -q 'session send refused: the pane is showing an interactive choice menu' "$SRC" && ok "send refuses helpfully on a menu pane" || bad "no helpful menu refusal in send"
grep -q 'Use '"'"'session answer'"'"' to select an option' "$SRC" && ok "send refusal names session answer" || bad "send refusal does not name session answer"
grep -q 'session send failed: nothing was submitted' "$SRC" && ok "send failure message says 'nothing was submitted'" || bad "send failure message wrong"
grep -q 'Pane state:' "$SRC" && ok "send failure carries the real pane state" || bad "send failure omits pane state"
grep -q 'submitted, text left the composer' "$SRC" && ok "rc 2 message states submission verified" || bad "rc 2 message wrong"
grep -q 'session control <interrupt|exit|relaunch>' "$SRC" && ok "control subcommand advertised in usage" || bad "control not in usage"
grep -q 'answer \[y|n|<index>|<label>\]' "$SRC" && ok "answer subcommand advertised in usage" || bad "answer not in usage"
# The control plane must be strictly separate from send: lifecycle text must never be delivered as chat.
grep -q 'session control' "$SRC" && grep -q 'strictly separate from .session send.' "$SRC" && ok "control plane is documented as separate from send" || bad "control/send separation not documented"

echo "----"
echo "session-send-verify: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
