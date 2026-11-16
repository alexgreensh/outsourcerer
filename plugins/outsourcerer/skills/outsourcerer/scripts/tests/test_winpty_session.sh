#!/usr/bin/env bash
# test_winpty_session.sh — the Windows (Git Bash) winpty session path: screen reading + broker keys.
#
# Runs on every platform. The screen helpers (lib/winpty.sh) are pure text functions fed with real
# Codex 0.169 output captured under winpty on Windows 11. The broker runs against a fake `winpty`
# that records the bytes it receives, so the keystroke contract is checked without Windows:
#   - send presses Enter ONCE (a blind second Enter picked "Update now" on Codex's update screen),
#   - answer moves the cursor with arrows then Enter,
#   - clear sends ESC, a pause, then ^U (back to back they read as one Alt-^U key),
#   - an npm shim (`codex` next to `codex.cmd`) is resolved to the .cmd winpty can start.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
BROKER="$SCRIPT_DIR/../outsourcerer-winpty-broker.sh"
[ -f "$SRC" ] && [ -f "$BROKER" ] || { echo "FAIL: cannot find engine/broker"; exit 1; }

TMP="$(mktemp -d)"
export HOME="$TMP/home" OSRC_HOME="$TMP/state"
mkdir -p "$HOME" "$TMP/bin" "$TMP/fx"
cleanup() { [ -n "${BPID:-}" ] && kill "$BPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2', want '$3'"; }

set --
. "$SRC" >/dev/null 2>&1
trap cleanup EXIT

# ---- fixtures (CRLF lines + in-band OSC titles, as winpty -Xplain writes them) ---------------------
fx() { local f="$TMP/fx/$1"; shift; : > "$f"; for l in "$@"; do printf '%s\r\n' "$l" >> "$f"; done; }
title() { printf '\033]0;%s\007' "$2" >> "$TMP/fx/$1"; }

fx trust '  decision will be saved.' '› 1. Trust and continue' '  2. Back to Agent Command Center' '  enter continue · esc back'
fx daemon '› Ask Codex to do anything' '  ? for shortcuts' '  These settings persist.' \
  '  1. Run without daemon this time' '  2. Restart with these settings' '› 3. Cancel'
fx closed '› 1. Trust and continue' '  2. Back to Agent Command Center' '  enter continue · esc back' \
  '› Ask Codex to do anything' '  ? for shortcuts'; title closed 'proj'
fx model '› Ask Codex to do anything' '  Select Model and Effort' \
  '  1. GPT-6.1-Sol              Latest workhorse model for coding and everyday' '                              work.' \
  '  5. GPT-6-Luna               Fast and affordable model.' '› 7. GPT-5.6-Terra (current)  Older balanced model.' \
  '  8. GPT-5.6-Luna             Older fast model.' '  enter select · esc back'
fx working '› first task' '  Worked for 27s • 11:00 PM' '› second task' '• Working (12s • esc to interrupt)'; title working 'proj'
fx idle '› first task' '• Working (3s • esc to interrupt)' '• DONE' '  Worked for 18s • 11:03 PM' \
  '› Ask Codex to do anything' '  ← for agents · ? for shortcuts'
fx booting '› Ask Codex to do anything'; title booting $'\xe2\xa0\xa7 proj'
fx typed '› Create a file named hello.txt containing' '  the single line WINPTY_OK' '  ? for shortcuts'

# ---- menu detection --------------------------------------------------------------------------------
_winpty_menu "$TMP/fx/trust" >/dev/null && ok "trust prompt reads as an open menu" || bad "trust prompt not seen as a menu"
_winpty_menu "$TMP/fx/daemon" >/dev/null && ok "a menu drawn after the composer row is open" || bad "daemon menu after composer not seen"
_winpty_menu "$TMP/fx/closed" >/dev/null && bad "an answered menu (composer redrawn after it) still reads as open" || ok "an answered menu is history once the composer is redrawn"
_winpty_menu "$TMP/fx/idle" >/dev/null && bad "idle composer read as a menu" || ok "idle composer is not a menu"
grep -q 'Trust and continue' <<<"$(_winpty_menu "$TMP/fx/trust")" && ok "the menu report lists the options" || bad "menu report lacks options"

# ---- answer: signed cursor move from the cursor row -------------------------------------------------
expect "answer on the cursor row moves 0"          "$(_winpty_answer_move "$TMP/fx/trust" 1)" "+0"
expect "answer below the cursor moves down"        "$(_winpty_answer_move "$TMP/fx/trust" 2)" "+1"
expect "answer above the cursor moves up (by row, not number)" "$(_winpty_answer_move "$TMP/fx/model" 5)" "-1"
expect "answer counts rows, skipping wrapped description lines" "$(_winpty_answer_move "$TMP/fx/model" 1)" "-2"
_winpty_answer_move "$TMP/fx/trust" 9 >/dev/null 2>&1 && bad "a missing option was accepted" || ok "a missing option is refused"
_winpty_answer_move "$TMP/fx/idle" 1 >/dev/null 2>&1 && bad "answer with no menu was accepted" || ok "answer with no open menu is refused"
_winpty_answer_move "$TMP/fx/trust" 'x' >/dev/null 2>&1 && bad "a non-number answer was accepted" || ok "a non-number answer is refused"

# ---- state ------------------------------------------------------------------------------------------
st() { _winpty_state_json "$TMP/fx/$1" codex | sed 's/.*"state":"\([^"]*\)".*/\1/'; }
expect "open menu -> waiting-approval"                        "$(st trust)"   "waiting-approval"
expect "busy row newer than the last turn end -> working (title not refreshed)" "$(st working)" "working"
expect "turn ended, composer back -> idle"                    "$(st idle)"    "idle"
expect "spinner title before any turn end -> working"         "$(st booting)" "working"
expect "answered menu + idle title -> idle"                   "$(st closed)"  "idle"

# ---- send verification + read cleaning --------------------------------------------------------------
_winpty_composer_holds "$TMP/fx/typed" "Create a file named hello.txt containing the single line WINPTY_OK" \
  && ok "unsent text in the composer is detected" || bad "unsent composer text missed"
_winpty_composer_holds "$TMP/fx/idle" "Create a file named hello.txt" \
  && bad "an empty composer read as holding the text" || ok "an empty composer does not hold the text"
out="$(_winpty_clean "$TMP/fx/working")"
case "$out" in *$'\033'*|*$'\r'*) bad "read output still carries OSC/CR noise" ;; *) ok "read output is stripped of OSC titles and CRs" ;; esac

# ---- broker keystrokes against a fake winpty ---------------------------------------------------------
cat > "$TMP/bin/winpty" <<'EOF'
#!/usr/bin/env bash
# fake winpty: record argv, then copy every input byte to keys.bin until killed.
printf '%s\n' "$@" > "$FAKE_DIR/argv"
exec cat > "$FAKE_DIR/keys.bin"
EOF
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/fakecli"
printf '@echo off\r\n' > "$TMP/bin/fakecli.cmd"
chmod +x "$TMP/bin/winpty" "$TMP/bin/fakecli"
SD="$TMP/sess"; mkdir -p "$SD"
LAUNCH=("fakecli" "--flag"); declare -p LAUNCH > "$SD/launch.bash"
export FAKE_DIR="$TMP"
PATH="$TMP/bin:$PATH" bash "$BROKER" "$SD" > "$TMP/broker.log" 2>&1 &
BPID=$!
for _ in $(seq 1 50); do [ -f "$TMP/argv" ] && break; sleep 0.1; done

grep -qx -- '-Xallow-non-tty' "$TMP/argv" && grep -qx -- '-Xplain' "$TMP/argv" \
  && ok "winpty is launched with its non-tty flags" || bad "winpty argv lacks -X flags: $(tr '\n' ' ' < "$TMP/argv" 2>/dev/null)"
grep -qx "$TMP/bin/fakecli.cmd" "$TMP/argv" && ok "an npm-style shim resolves to its .cmd sibling" \
  || bad "LAUNCH[0] not resolved to .cmd: $(tr '\n' ' ' < "$TMP/argv" 2>/dev/null)"

mailbox() { local f="$SD/cmd/$1"; KOFF=$(wc -c < "$TMP/keys.bin" 2>/dev/null || echo 0); printf '%s' "$2" > "$f.tmp"; mv "$f.tmp" "$f"; for _ in $(seq 1 60); do [ -e "$f" ] || break; sleep 0.1; done; sleep 0.3; }
keys() { tail -c +$((KOFF + 1)) "$TMP/keys.bin" | od -An -c | tr -s ' \n' ' ' | sed 's/^ //;s/ $//'; }

mailbox "send-1-1-1.txt" "hi"
expect "send types the text and ONE Enter" "$(keys)" 'h i \r'
mailbox "answer-2-1-1.txt" "-2"
expect "answer -2 sends Up twice then Enter" "$(keys)" '033 [ A 033 [ A \r'
mailbox "answer-3-1-1.txt" "+1"
expect "answer +1 sends Down once then Enter" "$(keys)" '033 [ B \r'
mailbox "answer-4-1-1.txt" "+0"
expect "answer +0 confirms the cursor row" "$(keys)" '\r'
mailbox "clear-5-1-1" ""
expect "clear sends ESC then ^U (separately)" "$(keys)" '033 025'
mailbox "enter-6-1-1" ""
expect "enter sends one Enter" "$(keys)" '\r'

: > "$SD/cmd/stop"
for _ in $(seq 1 50); do kill -0 "$BPID" 2>/dev/null || break; sleep 0.1; done
kill -0 "$BPID" 2>/dev/null && bad "broker did not exit on stop" || ok "broker exits on stop"
[ -e "$SD/broker.pid" ] || [ -e "$SD/stdin" ] && bad "broker left pid/fifo behind" || ok "broker cleans its pid file and fifo"
BPID=""

# ---- gate: verified subcommands open, the Devin model picker stays gated -----------------------------
body="$(awk '/^_winpty_session\(\) \{/{on=1} on{print} on&&/^}/{exit}' "$SRC")"
grep -q 'model) echo "unverified Windows mutation support"' <<<"$body" && ok "session model stays gated on Windows" || bad "model gate missing"
grep -q 'if \[ "\$sub" != "read" \]' <<<"$body" && bad "the read-only gate is still blocking start/send" || ok "start/send/answer/clear/stop are no longer gated"

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
