#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# lib/screen.sh is the one screen reader. Every fixture under fixtures/screen/ is a REAL pane
# capture (tmux capture-pane -e -p) taken 2026-11-13 from throwaway sessions: Claude Code 2.1.323
# (Haiku), Codex 0.167 (gpt-5.6-luna), Devin CLI 3000.12 (SWE-2), Antigravity CLI 1.5.5, gemini-cli.
# Personal data scrubbed (home path, email, session URL). Also covers: LC_ALL=C (box glyphs must still
# match), Gemini/agy trailing blank lines, text the orchestrator typed (never evidence), the menu gate
# (false-menu composer, a reply ending in a numbered list), duplicate sends, status-bar redraw,
# and the `session effort` lane resolution.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"; FX="$HERE/fixtures/screen"
TMP="$(mktemp -d "${TMPDIR%/}/.test-screen.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
# One line per case: ok prints its label, or the test line that called it (file:line + source).
ok(){ pass=$((pass+1)); if [ -n "${1:-}" ]; then echo "PASS: $1"; else
  echo "PASS: line ${BASH_LINENO[0]}: $(sed -n "${BASH_LINENO[0]}{s/^[[:space:]]*//;p;}" "${BASH_SOURCE[1]}" | cut -c1-90)"; fi; }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
export HOME="$TMP/fakehome" OSRC_HOME="$TMP/state"; mkdir -p "$HOME" "$OSRC_HOME"
bash -n "$SRC" || { echo "FAIL: bash -n"; exit 1; }
OSRC_SOURCED=1; export OSRC_SOURCED; set --; . "$SRC" >/dev/null 2>&1
type osrc_screen_state >/dev/null 2>&1 && ok || { echo "FAIL: lib/screen.sh not loaded when sourced"; exit 1; }

# fixture  engine  state  [kind]  [command-or-path]
TABLE='cc-fable-composer-false-menu|cc|composer||
cc-composer-idle|cc|composer||
cc-composer-manual-resumable|cc|composer||
cc-composer-typed-unsent|cc|composer||
cc-idle-after-work|cc|idle||
cc-reply-numbered-list|cc|idle||
cc-prose-question|cc|question||
cc-askuserquestion|cc|question||
cc-working-queued|cc|working||
cc-working-hooks|cc|working||
cc-working-hooks2|cc|working||
cc-permission-bash|cc|approval|shell|touch made-by-test.txt && ls -la .
cc-permission-bash-1|cc|approval|shell|ls -la /tmp/x-osrc-test-L3
cc-permission-bash-rm|cc|approval|shell|rm -rf /tmp/x-osrc-test-L3 && echo "exit=$?"
cc-permission-write|cc|approval|write|notes.txt
cc-trust-folder-menu|cc|approval|trust|
cx-idle|codex|composer||
cx-working|codex|working||
cx-idle-after-work|codex|idle||
cx-approval|codex|approval|shell|touch made-by-codex.txt
cx-trust-folder-menu|codex|approval|trust|
dv-idle|devin|composer||
dv-working|devin|working||
dv-idle-after-work|devin|idle||
dv-approval|devin|approval|shell|touch made-by-devin.txt && ls
dv-approval-wrapped|devin|approval|shell|
dv-approval-modal|devin|approval|shell|SCRATCH=/tmp/osrc-scratch && jq -r .name /tmp/osrc-scratch/report.json; echo done
dv-approval-modal-box|devin|approval|shell|jq -r .name out/report.json
dv-approval-modal-rm|devin|approval|shell|rm -rf ~/Documents
dv-approval-modal-safe-wrapped|devin|approval|shell|
dv-approval-modal-status-line|devin|approval|shell|
dv-approval-modal-wide-wrap|devin|approval|shell|
cc-idle-status-auto|cc|idle||
cc-idle-status-bypass|cc|idle||
cc-idle-status-plan|cc|idle||
cc-idle-status-accept-edits|cc|idle||
agy-idle|agy|composer||
agy-mode-hint|agy|composer||
agy-working|agy|working||
agy-idle-after-work|agy|idle||
agy-approval|agy|approval|shell|touch made-by-agy.txt && ls
agy-file-approval|agy|approval|write|/Users/dev/work/demo-projects/example-workspace/project/outsourcerer/outputs/build/wt-auto-L3/.osrc-test-L3/work-agy/notes.txt
agy-trust-folder-menu|agy|approval|trust|
gm-trust-folder-menu|gemini|approval|trust|
gm-approval-shell|gemini|approval|other|
'

check_table() { # <label> [hint-mode: hint|guess]
  local mode="$1" f eng want kind what hint n=0
  while IFS='|' read -r f eng want kind what; do
    [ -n "$f" ] || continue
    n=$((n+1))
    hint="$eng"; [ "$mode" = guess ] && hint=""
    _osrc_screen_analyze_text "$hint" < "$FX/$f.ansi"
    if [ "$OSRC_SCR_STATE" != "$want" ]; then bad "[$mode] $f: want $want got $OSRC_SCR_STATE ($OSRC_SCR_EVIDENCE)"; continue; fi
    [ "$mode" = guess ] && [ "$OSRC_SCR_ENGINE" != "$eng" ] && { bad "[guess] $f: engine guessed $OSRC_SCR_ENGINE, want $eng"; continue; }
    if [ -n "$kind" ] && [ "$OSRC_SCR_KIND" != "$kind" ]; then bad "[$mode] $f: kind $OSRC_SCR_KIND, want $kind"; continue; fi
    if [ -n "$what" ] && [ "${OSRC_SCR_CMD:-$OSRC_SCR_PATH}" != "$what" ]; then bad "[$mode] $f: command '${OSRC_SCR_CMD:-$OSRC_SCR_PATH}', want '$what'"; continue; fi
    ok
  done <<<"$TABLE"
  [ "$n" -ge 30 ] || bad "fixture table shrank to $n rows"
}
check_table hint
check_table guess

# Every captured fixture must be in the table (an unlisted capture is an untested state).
for f in "$FX"/*.ansi; do
  b="$(basename "$f" .ansi)"; [ "$b" = gm-auth-failed ] && continue
  grep -q "^$b|" <<<"$TABLE" && ok || bad "fixture $b has no expected state in the table"
done

# ---- LC_ALL=C: the orchestrator's background shell had no UTF-8 locale and every glyph test missed.
out="$(LC_ALL=C LANG=C bash -c '
  OSRC_HOME="'"$TMP"'/state-c" OSRC_SOURCED=1; export OSRC_HOME OSRC_SOURCED; set --; . "'"$SRC"'" >/dev/null 2>&1
  for f in dv-approval cc-permission-bash agy-approval cc-fable-composer-false-menu cx-approval; do
    _osrc_screen_analyze_text "" < "'"$FX"'/$f.ansi"; printf "%s=%s:%s\n" "$f" "$OSRC_SCR_STATE" "$OSRC_SCR_ENGINE"
  done')"
for want in dv-approval=approval:devin cc-permission-bash=approval:cc agy-approval=approval:agy cc-fable-composer-false-menu=composer:cc cx-approval=approval:codex; do
  grep -qx "$want" <<<"$out" && ok || bad "LC_ALL=C: want $want, got: $(printf '%s' "$out" | tr '\n' ' ')"
done

# ---- trailing blank lines (Gemini/agy pad the pane): 40 extra blank rows change nothing.
{ cat "$FX/agy-approval.ansi"; for i in $(seq 1 40); do printf '\n'; done; } > "$TMP/agy-pad.ansi"
_osrc_screen_analyze_text agy < "$TMP/agy-pad.ansi"
[ "$OSRC_SCR_STATE" = approval ] && [ "$OSRC_SCR_CMD" = "touch made-by-agy.txt && ls" ] && ok || bad "trailing blanks hid the agy prompt ($OSRC_SCR_STATE)"

# ---- typed text is never evidence: the composer holds "ROUND4 DONE ... Do you want to proceed? [y/N]"
_osrc_screen_analyze_text cc < "$FX/cc-composer-typed-unsent.ansi"
case "$OSRC_SCR_COMPOSER" in "When you finish, reply with exactly: ROUND4 DONE."*) ok ;; *) bad "typed composer text not extracted: $OSRC_SCR_COMPOSER" ;; esac
[ "$OSRC_SCR_STATE" = composer ] && ok || bad "typed [y/N] text in the composer read as $OSRC_SCR_STATE"

# ---- a Devin command wrapped onto two rows is read whole (both rows, multi-line) -------
_osrc_screen_analyze_text devin < "$FX/dv-approval-wrapped.ansi"
want_cmd="ls -la src &&
rm -rf ~/Documents"
[ "$OSRC_SCR_STATE" = approval ] && [ "$OSRC_SCR_CMD" = "$want_cmd" ] && ok || bad "devin wrapped command read as [$OSRC_SCR_CMD]"
[ "$OSRC_SCR_SEL" = Allow ] && [ "$OSRC_SCR_SCOPE" = once ] && ok || bad "devin wrapped: sel=$OSRC_SCR_SEL scope=$OSRC_SCR_SCOPE"
_osrc_screen_analyze_text devin < "$FX/dv-approval.ansi"
[ "$OSRC_SCR_CMD" = "touch made-by-devin.txt && ls" ] && ok || bad "devin single-row command now reads [$OSRC_SCR_CMD]"

# ---- osrc_screen_state through a fake tmux (contract: 2 lines) -------------------------------------
CAP=""; tmux() { case "$1" in capture-pane) cat "$CAP" ;; display-message) printf '%s\n' "$TMP" ;; send-keys) printf '%s\n' "$*" >> "$TMP/keys" ;; *) return 0 ;; esac; }
CAP="$FX/dv-approval.ansi"; out="$(osrc_screen_state fake-pane devin)"
[ "$(printf '%s\n' "$out" | sed -n 1p)" = approval ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ] && ok || bad "osrc_screen_state contract: $out"
tmux() { return 1; }; out="$(osrc_screen_state fake-pane cc)"
[ "$(printf '%s\n' "$out" | sed -n 1p)" = unknown ] && ok || bad "capture failure must be unknown: $out"

# ---- menu gate: the false-menu composer and a numbered reply are NOT menus; a real prompt is ------
_managed_provider() { printf cc; }
tmux() { case "$1" in capture-pane) cat "$CAP" ;; *) return 0 ;; esac; }
CAP="$FX/cc-fable-composer-false-menu.ansi"; [ "$(_managed_menu_detect p 2>/dev/null | head -1)" = "MENU none" ] && ok || bad "false-menu fixture still detected as a menu: $(_managed_menu_detect p | head -3 | tr '\n' ' ')"
CAP="$FX/cc-reply-numbered-list.ansi"; [ "$(_managed_menu_detect p 2>/dev/null | head -1)" = "MENU none" ] && ok || bad "a reply ending in a numbered list blocked send"
CAP="$FX/cc-idle-after-work.ansi"; [ "$(_managed_menu_detect p 2>/dev/null | head -1)" = "MENU none" ] && ok || bad "idle cc pane read as a menu"
CAP="$FX/cc-permission-bash.ansi"; [ "$(_managed_menu_detect p 2>/dev/null | head -1)" != "MENU none" ] && ok || bad "real cc permission prompt not detected as a menu"
CAP="$FX/cc-askuserquestion.ansi"; [ "$(_managed_menu_detect p 2>/dev/null | head -1)" != "MENU none" ] && ok || bad "cc question picker not detected as a menu"
# Unknown lane, unrecognised layout: the legacy path must still not call a composer box a menu.
_managed_provider() { printf droid; }
printf '%s\n' '────────────────────' '❯ hello there' '────────────────────' '  model x | ctx 3%' '  shift+p to plan' > "$TMP/generic-composer.txt"
CAP="$TMP/generic-composer.txt"; [ "$(_managed_menu_detect p 2>/dev/null | head -1)" = "MENU none" ] && ok || bad "legacy path read a composer box as a menu"
_managed_provider() { printf devin; }
CAP="$FX/dv-approval.ansi"; [ "$(_managed_menu_detect p 2>/dev/null | head -1)" != "MENU none" ] && ok || bad "devin approval not detected as a menu"

# ---- the menu report comes from the engine reader; answers resolve safely ---------------
_endpoint_mutation_lock() { return 0; }; _endpoint_mutation_unlock() { return 0; }
menu_of() { _managed_provider() { printf '%s' "$1"; }; CAP="$FX/$2.ansi"; _managed_menu_detect p 2>/dev/null; }
r="$(menu_of cc cc-permission-bash-rm)"
[ "$(printf '%s\n' "$r" | head -1)" = "MENU select" ] && grep -qx 'SEL 1 Yes' <<<"$r" \
  && [ "$(printf '%s\n' "$r" | grep -c '^\(SEL\|OPT\) ')" = 4 ] && ok || bad "cc rm prompt: row 1 not listed / wrong rows: $(printf '%s' "$r" | tr '\n' '|')"
grep -q '^OPT 3 Yes, and switch to auto mode' <<<"$r" && ok || bad "cc rm prompt: option 3 missing"
r="$(menu_of codex cx-approval)"; grep -q '^SEL 1 Yes, proceed' <<<"$r" && [ "$(printf '%s\n' "$r" | grep -c '^\(SEL\|OPT\) ')" = 3 ] && ok || bad "codex: $(printf '%s' "$r" | tr '\n' '|')"
r="$(menu_of agy agy-approval)"; grep -q '^SEL 1 Yes, run command' <<<"$r" && [ "$(printf '%s\n' "$r" | grep -c '^\(SEL\|OPT\) ')" = 4 ] && ok || bad "agy: $(printf '%s' "$r" | tr '\n' '|')"
r="$(menu_of devin dv-approval)"; [ "$(printf '%s\n' "$r" | grep -c '^SEL ')" = 1 ] && grep -q '^SEL 1 Allow' <<<"$r" \
  && grep -qx 'OPT 3 Deny' <<<"$r" && [ "$(printf '%s\n' "$r" | grep -c '^\(SEL\|OPT\) ')" = 3 ] && ok || bad "devin report noisy: $(printf '%s' "$r" | tr '\n' '|')"
r="$(menu_of devin dv-approval-wrapped)"; [ "$(printf '%s\n' "$r" | grep -c '^\(SEL\|OPT\) ')" = 3 ] && ok || bad "devin wrapped: command row listed as an option: $(printf '%s' "$r" | tr '\n' '|')"
r="$(menu_of cc cc-prose-question)"; [ "$(printf '%s\n' "$r" | head -1)" = "MENU none" ] && ok || bad "a prose question (composer live) read as a menu, send would be refused: $(printf '%s' "$r" | tr '\n' '|')"
r="$(menu_of cc cc-askuserquestion)"; grep -q '^SEL 1 Red' <<<"$r" && grep -q '^OPT 4 Chat about this' <<<"$r" && ok || bad "cc question: $(printf '%s' "$r" | tr '\n' '|')"
r="$(menu_of cc cc-trust-folder-menu)"; grep -qx 'SEL 1 No, exit' <<<"$r" && grep -qx 'OPT 2 Yes, I trust this folder' <<<"$r" && ok || bad "cc trust: $(printf '%s' "$r" | tr '\n' '|')"
r="$(menu_of gemini gm-trust-folder-menu)"; grep -q '^SEL 1 Trust folder' <<<"$r" && grep -q "^OPT 3 Don't trust" <<<"$r" && ok || bad "gemini trust: $(printf '%s' "$r" | tr '\n' '|')"
# answers on the held cc rm prompt: 1 selects row 1 (Enter alone), Yes is ambiguous, auto mode by label refused
_managed_provider() { printf cc; }; CAP="$FX/cc-permission-bash-rm.ansi"
tmux() { case "$1" in capture-pane) cat "$CAP" ;; send-keys) printf '%s\n' "$*" >> "$TMP/akeys"; case " $* " in *" Enter "*) CAP="$FX/cc-idle-after-work.ansi" ;; esac ;; *) return 0 ;; esac; }
: > "$TMP/akeys"; _managed_menu_answer p 1 2>/dev/null && [ "$(cat "$TMP/akeys")" = "send-keys -t p Enter" ] && ok || bad "answer 1 on cc rm prompt: $(cat "$TMP/akeys" | tr '\n' '|')"
CAP="$FX/cc-permission-bash-rm.ansi"; : > "$TMP/akeys"
err="$(_managed_menu_answer p Yes 2>&1)"; rc=$?
[ "$rc" = 1 ] && [ ! -s "$TMP/akeys" ] && case "$err" in *ambiguous*) true ;; *) false ;; esac && ok || bad "answer Yes not refused as ambiguous (rc=$rc keys=$(cat "$TMP/akeys") err=$err)"
CAP="$FX/cc-permission-bash-rm.ansi"; : > "$TMP/akeys"; _managed_menu_answer p y >/dev/null 2>&1; [ ! -s "$TMP/akeys" ] && ok || bad "answer y typed keys: $(cat "$TMP/akeys")"
CAP="$FX/cc-permission-bash-rm.ansi"; : > "$TMP/akeys"; err="$(_managed_menu_answer p "auto mode" 2>&1)"
[ ! -s "$TMP/akeys" ] && case "$err" in *"refusing to pick"*) true ;; *) false ;; esac && ok || bad "auto-mode row picked by label: $(cat "$TMP/akeys") $err"
CAP="$FX/cc-permission-bash-rm.ansi"; : > "$TMP/akeys"; _managed_menu_answer p No 2>/dev/null && [ "$(tr '\n' '|' < "$TMP/akeys")" = "send-keys -t p Down|send-keys -t p Down|send-keys -t p Down|send-keys -t p Enter|" ] && ok || bad "answer No: $(tr '\n' '|' < "$TMP/akeys")"
CAP="$FX/cc-permission-bash-rm.ansi"; : > "$TMP/akeys"; _managed_menu_answer p 3 2>/dev/null && [ "$(tr '\n' '|' < "$TMP/akeys")" = "send-keys -t p Down|send-keys -t p Down|send-keys -t p Enter|" ] && ok || bad "answer 3 by index: $(tr '\n' '|' < "$TMP/akeys")"
unset -f menu_of

# ---- 0.17.2 G2: yes/no pick the row STARTING with Yes/No, skipping risky rows ---------------------
# Claude's folder-trust menu lists "No, exit" first, so `session answer 1` exited instead of
# trusting. y/yes and n/no resolve by the Yes/No prefix wherever the row sits, and never land on an
# always/don't-ask-again/bypass row.
yesno_rep='MENU select
SEL 1 No, exit
OPT 2 Yes, I trust this folder'
[ "$(_osrc_menu_resolve "$yesno_rep" yes)" = 2 ] && [ "$(_osrc_menu_resolve "$yesno_rep" y)" = 2 ] \
  && [ "$(_osrc_menu_resolve "$yesno_rep" no)" = 1 ] && [ "$(_osrc_menu_resolve "$yesno_rep" n)" = 1 ] \
  && ok || bad "yes/no on trust report: yes='$(_osrc_menu_resolve "$yesno_rep" yes)' no='$(_osrc_menu_resolve "$yesno_rep" no)'"
if _osrc_menu_resolve $'OPT 1 Yes, always allow\nOPT 2 No, exit' yes >/dev/null 2>&1; then
  bad "a sole risky Yes row was accepted"
else ok; fi
num_rep="MENU numbered
SEL 1 Yes
OPT 2 Yes, and don't ask again for this command
OPT 3 No, and tell Claude what to do differently"
# Two Yes rows: "yes" stays ambiguous so an approval always names its row; "no" is still one row.
err="$(_osrc_menu_resolve "$num_rep" yes 2>&1)"; rc=$?
[ "$rc" = 1 ] && case "$err" in *ambiguous*) true ;; *) false ;; esac && [ "$(_osrc_menu_resolve "$num_rep" no)" = 3 ] \
  && ok || bad "yes/no on numbered report: yes rc=$rc err=$err no='$(_osrc_menu_resolve "$num_rep" no)'"
no_yes_rep='MENU select
SEL 1 Deny
OPT 2 Approve once'
err="$(_osrc_menu_resolve "$no_yes_rep" yes 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok || bad "yes on a menu with no Yes row was not refused (rc=$rc err=$err)"
# end-to-end on the real capture: answer yes -> Down + Enter onto "Yes, I trust this folder";
# answer no -> Enter alone on the highlighted "No, exit"
CAP="$FX/cc-trust-folder-menu.ansi"; : > "$TMP/akeys"
_managed_menu_answer p yes 2>/dev/null && [ "$(tr '\n' '|' < "$TMP/akeys")" = "send-keys -t p Down|send-keys -t p Enter|" ] \
  && ok || bad "answer yes on cc trust menu: $(tr '\n' '|' < "$TMP/akeys")"
CAP="$FX/cc-trust-folder-menu.ansi"; : > "$TMP/akeys"
_managed_menu_answer p no 2>/dev/null && [ "$(tr '\n' '|' < "$TMP/akeys")" = "send-keys -t p Enter|" ] \
  && ok || bad "answer no on cc trust menu: $(tr '\n' '|' < "$TMP/akeys")"

# ---- two identical sends to one session are both admitted (each is its own obligation) ---------
_obligation_append "send.x.1.a" e6sess typing_started "" >/dev/null 2>&1
o1="send.e6sess.123.$(date +%s).1"; o2="send.e6sess.123.$(date +%s).2"
_obligation_admit "$o1" e6sess && _obligation_append "$o1" e6sess delivery_unknown "" && ok || bad "first send not admitted"
_obligation_admit "$o2" e6sess && ok || bad "an identical second send was refused"
grep -q 'cksum | awk .{print $1}.).$(date +%s).$$$RANDOM' "$HERE/../lib/send.sh" && ok || bad "send obligation id has no per-send nonce"

# ---- Claude Code status bar redraws while the text sits in the composer -> NOT submitted -------
# Build a pane where the composer holds the typed text and only the status row changes each capture.
mk_cc() { # <composer-text> <status>
  printf '\033[38;5;244m%s\033[39m\n\342\235\257\302\240%s\n\033[38;5;244m%s\033[39m\n  \342\217\270 manual mode on \302\267 \342\206\220 15 agents\n  Haiku 5.5 | xhi | work | %s\n' \
    "────────────────────────────────" "$1" "────────────────────────────────" "$2"
}
CNT="$TMP/cnt"; echo 0 > "$CNT"; : > "$TMP/keys"
tmux() {
  case "$1" in
    capture-pane) n=$(cat "$CNT"); echo $((n+1)) > "$CNT"; mk_cc "please run the suite" "Quality $n" ;;
    send-keys) printf '%s\n' "$*" >> "$TMP/keys" ;;
    *) return 0 ;;
  esac
}
OSRC_SEND_VERIFY_SECS=5 _osrc_send_verify_screen p cc "please run the suite"; rc=$?
[ "$rc" = 1 ] && ok || bad "status-bar redraw passed as submitted (rc=$rc, $OSRC_SEND_EVIDENCE)"
[ "$(grep -c 'Enter' "$TMP/keys")" = 1 ] && ok || bad "stuck composer should get exactly one extra Enter (got $(grep -c Enter "$TMP/keys"))"
# The old bottom-line check is fooled by the same screen: prove the regression is real.
echo 0 > "$CNT"; typed="$(_managed_pane_tail p)"
OSRC_SEND_VERIFY_POLLS=3 _managed_send_submitted p "$typed"; [ "$?" = 0 ] && ok || bad "(control) legacy check was expected to be fooled by a status redraw"
# A real submit: composer clears and a spinner line appears above it.
tmux() {
  case "$1" in
    capture-pane) printf '\342\235\257 please run the suite\n\342\234\242 Schlepping\342\200\246 (2s)\n'; mk_cc "" "Quality 1" ;;
    *) return 0 ;;
  esac
}
OSRC_SEND_VERIFY_SECS=2 _osrc_send_verify_screen p cc "please run the suite" composer 0 0; rc=$?
[ "$rc" = 0 ] && ok || bad "cleared composer + spinner not accepted as submitted (rc=$rc $OSRC_SEND_EVIDENCE)"

# ---- a static pane is never a receipt; proof must be about THIS send --------------------
# Baseline exactly as _managed_session_send takes it, then a pane that never changes.
static_verify() { # <fixture> <snippet> -> rc of the verifier with a same-screen baseline, text never seen
  CAP="$FX/$1.ansi"
  tmux() { case "$1" in capture-pane) cat "$CAP" ;; *) return 0 ;; esac; }
  _osrc_screen_analyze_text cc < "$CAP"; local b="$OSRC_SCR_STATE" h; h="$(_osrc_scr_history_count "$2")"
  OSRC_SEND_VERIFY_SECS=2 _osrc_send_verify_screen p cc "$2" "$b" "$h" 0
}
static_verify cc-prose-question "src/main.py please"; rc=$?
[ "$rc" != 0 ] && ok || bad "old prose question verified a send that never appeared ($OSRC_SEND_EVIDENCE)"
static_verify cc-idle-after-work "Use the Bash tool to run"; rc=$?
[ "$rc" != 0 ] && ok || bad "an old identical history line verified a resend ($OSRC_SEND_EVIDENCE)"
static_verify cc-permission-bash-rm "1 please continue"; rc=$?
[ "$rc" != 0 ] && ok || bad "an approval on screen verified a send ($OSRC_SEND_EVIDENCE)"
# positive controls: a NEW identical history row counts; text seen in the composer then cleared counts
_osrc_screen_analyze_text cc < "$FX/cc-idle-after-work.ansi"; h="$(_osrc_scr_history_count "Use the Bash tool to run")"
[ "$h" = 1 ] && ok || bad "history count of the old line is $h, want 1"
tmux() { case "$1" in capture-pane) printf '\342\235\257 Use the Bash tool to run exactly this\n\342\235\257 Use the Bash tool to run again\n'; mk_cc "" "Quality 1" ;; *) return 0 ;; esac; }
OSRC_SEND_VERIFY_SECS=2 _osrc_send_verify_screen p cc "Use the Bash tool to run" idle 1 0; rc=$?
[ "$rc" = 0 ] && ok || bad "a second identical history row was not accepted (rc=$rc $OSRC_SEND_EVIDENCE)"
CAP="$FX/cc-idle-after-work.ansi"; tmux() { case "$1" in capture-pane) cat "$CAP" ;; *) return 0 ;; esac; }
OSRC_SEND_VERIFY_SECS=2 _osrc_send_verify_screen p cc "brand new words here" idle 0 1; rc=$?
[ "$rc" = 0 ] && ok || bad "text seen in the composer, then cleared, not accepted (rc=$rc $OSRC_SEND_EVIDENCE)"
# full send: a prompt that opens while typing takes the keys -> rc 1 and Enter is NEVER pressed
(
  _managed_endpoint_live() { return 0; }; _obligation_admit() { return 0; }; _obligation_append() { return 0; }
  _obligation_guard_begin() { :; }; _obligation_guard_end() { :; }; _obligation_delivery_unknown() { :; }
  _endpoint_mutation_lock() { return 0; }; _endpoint_mutation_unlock() { return 0; }; _tmux_reset_input() { :; }
  _managed_composer_state() { printf empty; }; _osrc_screen_engine_of() { printf cc; }
  CAP="$FX/cc-idle-after-work.ansi"; : > "$TMP/fkeys"
  tmux() { case "$1" in capture-pane) cat "$CAP" ;; send-keys) printf '%s\n' "$*" >> "$TMP/fkeys"; CAP="$FX/cc-permission-bash-rm.ansi" ;; *) return 0 ;; esac; }
  _managed_session_send p "1 yes go ahead"; rc=$?
  [ "$rc" = 1 ] && [ "$OSRC_SEND_MODAL" = 1 ] && ! grep -q ' Enter$' "$TMP/fkeys" && case "$OSRC_SEND_EVIDENCE" in *"Enter NOT pressed"*) true ;; *) false ;; esac
) && ok || bad "send into a prompt that opened while typing pressed Enter or reported success: $(tr '\n' '|' < "$TMP/fkeys")"
# an open modal gets ZERO keys (not even C-u), refused inside the lock
for spec in devin:dv-approval codex:cx-approval agy:agy-approval cc:cc-permission-bash-rm cc:cc-askuserquestion devin:dv-approval-wrapped; do
  (
    _managed_endpoint_live() { return 0; }; _obligation_admit() { return 0; }; _obligation_append() { return 0; }
    _obligation_guard_begin() { :; }; _obligation_guard_end() { :; }; _obligation_delivery_unknown() { :; }
    LOCKED=0; _endpoint_mutation_lock() { LOCKED=1; return 0; }; _endpoint_mutation_unlock() { LOCKED=0; return 0; }
    _managed_composer_state() { printf empty; }; _osrc_screen_engine_of() { printf '%s' "${spec%%:*}"; }
    CAP="$FX/${spec#*:}.ansi"; : > "$TMP/mkeys"
    tmux() { case "$1" in capture-pane) [ "$LOCKED" = 1 ] || echo "unlocked-read" >> "$TMP/mkeys"; cat "$CAP" ;; send-keys) printf '%s\n' "$*" >> "$TMP/mkeys" ;; *) return 0 ;; esac; }
    _managed_session_send p "e please also run rm -rf ~"; rc=$?
    [ "$rc" = 1 ] && [ ! -s "$TMP/mkeys" ] && [ "$OSRC_SEND_MODAL" = 1 ] && [ "$LOCKED" = 0 ] && case "$OSRC_SEND_EVIDENCE" in "modal open"*) true ;; *) false ;; esac
  ) && ok || bad "send into open modal ${spec}: keys/reads=[$(tr '\n' '|' < "$TMP/mkeys")]"
done
# with no composer and a prompt open, the composer state is never "empty"
for spec in devin:dv-approval codex:cx-approval agy:agy-approval; do
  ( _managed_provider() { printf '%s' "${spec%%:*}"; }; unset OSRC_EXTERNAL_COMPOSER_PROBE
    tmux() { case "$1" in capture-pane) cat "$FX/${spec#*:}.ansi" ;; *) return 0 ;; esac; }
    [ "$(_managed_composer_state s p)" = unreadable ] ) && ok || bad "composer state on an open ${spec} prompt is not 'unreadable'"
done
grep -q 'send refused: modal open' "$HERE/../outsourcerer.sh" && grep -q 'OSRC_SEND_MODAL:-0}" = 1 ] && echo answer' "$HERE/../outsourcerer.sh" && ok || bad "session send does not print EVENT failed ... modal open + NEXT answer"

# ---- Claude's mode status line is never a modal (TR orchestrator report): idle, no menu, send types
menu_head() { # <provider> <capture-file>: first line of the menu report (bash 3.2: no case inside $( ))
  _managed_provider() { printf '%s' "$MH_PROV"; }; OSRC_MENU_SETTLE_POLLS=0
  tmux() { case "$1" in capture-pane) cat "$MH_FILE" ;; *) return 0 ;; esac; }
  _managed_menu_detect p 2>/dev/null | head -1
}
for m in auto bypass plan accept-edits; do
  f="$FX/cc-idle-status-$m.ansi"
  python3 -c 'import re,sys
s=open(sys.argv[1]).read().split("\n")
open(sys.argv[2],"w").write("\n".join(l for l in s if not re.sub(r"\x1b\[[0-9;?]*[A-Za-z]","",l).strip().startswith("──")))' "$f" "$TMP/norule-$m.ansi"
  for c in "$f" "$TMP/norule-$m.ansi"; do
    r="$(MH_PROV=cc MH_FILE="$c" menu_head)"
    [ "$r" = "MENU none" ] && ok || bad "cc status line ($m, $(basename "$c")) read as a menu: $r"
  done
  (
    _managed_endpoint_live() { return 0; }; _obligation_admit() { return 0; }; _obligation_append() { return 0; }
    _obligation_guard_begin() { :; }; _obligation_guard_end() { :; }; _obligation_delivery_unknown() { :; }
    _endpoint_mutation_lock() { return 0; }; _endpoint_mutation_unlock() { return 0; }
    _managed_provider() { printf cc; }; _osrc_screen_engine_of() { printf cc; }; _state_jsonl_read() { :; }
    unset OSRC_EXTERNAL_RECEIPT_PROBE OSRC_EXTERNAL_COMPOSER_PROBE
    : > "$TMP/skeys"; tmux() { case "$1" in capture-pane) cat "$f" ;; send-keys) printf '%s\n' "$*" >> "$TMP/skeys" ;; *) return 0 ;; esac; }
    OSRC_SEND_VERIFY_SECS=1 _managed_session_send p "status line test"
    grep -q -- '-l -- status line test' "$TMP/skeys" && grep -q ' Enter$' "$TMP/skeys" && [ "${OSRC_SEND_MODAL:-0}" = 0 ]
  ) && ok || bad "send did not type into an idle cc pane with the $m status line: $(tr '\n' '|' < "$TMP/skeys")"
done
# a status-LOOKING row under a tool's own menu never disables the menu guard.
# Whole `session send` command, fake tmux, keys recorded: refused with 0 keys on every engine.
printf '%s\n' '$ ./deploy.sh' 'Select environment (use arrow keys)' '❯ production' '  staging' '⏵ deploy on' > "$TMP/deploy-menu.txt"
printf '%s\n' '$ ./deploy.sh' 'Select environment (use arrow keys)' '❯ production' '  staging' '⏵⏵ auto mode on (shift+tab to cycle)' '  ⏸ manual mode on extra' > "$TMP/deploy-menu-cc-notlast.txt"
for eng in codex devin gemini cc; do
  : > "$TMP/dkeys"
  ( SESSION_NAME="osrc-test-L3-dm"; _managed_provider() { printf '%s' "$eng"; }; OSRC_MENU_SETTLE_POLLS=0
    # every send gate but the menu guard is open, so a miss shows up as typed keys
    _managed_endpoint_live() { return 0; }; _obligation_admit() { return 0; }; _obligation_append() { return 0; }
    _obligation_guard_begin() { :; }; _obligation_guard_end() { :; }; _obligation_delivery_unknown() { :; }
    _endpoint_mutation_lock() { return 0; }; _endpoint_mutation_unlock() { return 0; }
    _managed_composer_state() { printf empty; }; _state_jsonl_read() { :; }; OSRC_SEND_VERIFY_SECS=1
    tmux() { case "$1" in has-session) return 0 ;; capture-pane) cat "$TMP/deploy-menu.txt" ;; send-keys) printf '%s\n' "$*" >> "$TMP/dkeys" ;; *) return 0 ;; esac; }
    session send "please continue" ) >/dev/null 2>&1; rc=$?
  [ "$rc" != 0 ] && [ ! -s "$TMP/dkeys" ] && ok || bad "session send typed into a tool menu with a status-looking row on $eng (rc=$rc keys=$(tr '\n' '|' < "$TMP/dkeys"))"
done
# r5 follow-up: on Claude, an unknown cursor menu with the exact mode line as the LAST row is still
# a menu: send refuses with "menu open ... session answer" (not "composer not empty"), 0 keys.
printf '%s\n' '$ ./deploy.sh' 'Select environment (use arrow keys)' '❯ production' '  staging' '  ⏵⏵ auto mode on (shift+tab to cycle)' > "$TMP/deploy-menu-cc-mode.txt"
r="$(MH_PROV=cc MH_FILE="$TMP/deploy-menu-cc-mode.txt" menu_head)"
[ "$r" != "MENU none" ] && ok "cc: cursor menu above the exact mode line reads as a menu ($r)" || bad "cc: the exact mode line as last row hid a cursor menu"
cc_mode_send() {
  ( SESSION_NAME="osrc-test-L3-dm"; _managed_provider() { printf cc; }; OSRC_MENU_SETTLE_POLLS=0
    _managed_endpoint_live() { return 0; }; _obligation_admit() { return 0; }; _obligation_append() { return 0; }
    _obligation_guard_begin() { :; }; _obligation_guard_end() { :; }; _obligation_delivery_unknown() { :; }
    _endpoint_mutation_lock() { return 0; }; _endpoint_mutation_unlock() { return 0; }
    _managed_composer_state() { printf unreadable; }; _state_jsonl_read() { :; }; OSRC_SEND_VERIFY_SECS=1
    tmux() { case "$1" in has-session) return 0 ;; capture-pane) cat "$TMP/deploy-menu-cc-mode.txt" ;; send-keys) printf '%s\n' "$*" >> "$TMP/dkeys" ;; *) return 0 ;; esac; }
    session send "please continue" ) > "$TMP/dout" 2>&1
}
: > "$TMP/dkeys"; cc_mode_send
if grep -q 'modal open' "$TMP/dout" && grep -q 'session answer' "$TMP/dout" && ! grep -q 'composer not empty' "$TMP/dout" && [ ! -s "$TMP/dkeys" ]; then
  ok "cc: send on a menu above the mode line says menu open / session answer, 0 keys"
else bad "cc: send on a menu above the mode line: keys=$(tr '\n' '|' < "$TMP/dkeys") out=$(tail -3 "$TMP/dout" | tr '\n' '|')"; fi
r="$(MH_PROV=cc MH_FILE="$TMP/deploy-menu-cc-notlast.txt" menu_head)"
[ "$r" != "MENU none" ] && ok || bad "cc: a real-looking status row that is not the whole last line hid a menu"
for bad_row in '⏵ x on' '⏵⏵ auto mode on (shift+tab to cycle) and more' 'xx ⏸ plan mode on'; do
  _osrc_scr_cc_status_row "$bad_row" && bad "status-row matcher accepted [$bad_row]" || ok
done
for good_row in '⏵⏵ auto mode on (shift+tab to cycle)' '  ⏸ manual mode on · ← 15 agents' '⏵⏵ bypass permissions on (shift+tab to cycle)' '⏸ plan mode on (shift+tab to cycle)' '⏵⏵ accept edits on (shift+tab to cycle) · ← 2 agents'; do
  _osrc_scr_cc_status_row "$good_row" && ok || bad "status-row matcher rejected the real line [$good_row]"
done

# every real approval/question capture is still a modal with the guard in place
for spec in cc:cc-permission-bash cc:cc-permission-bash-1 cc:cc-permission-bash-rm cc:cc-permission-write cc:cc-askuserquestion cc:cc-trust-folder-menu codex:cx-approval codex:cx-trust-folder-menu devin:dv-approval devin:dv-approval-wrapped agy:agy-approval agy:agy-file-approval agy:agy-trust-folder-menu gemini:gm-trust-folder-menu; do
  r="$(MH_PROV="${spec%%:*}" MH_FILE="$FX/${spec#*:}.ansi" menu_head)"
  [ "$r" != "MENU none" ] && ok || bad "real prompt ${spec} no longer detected as a menu"
done

# spill after admit: a refused send leaves no spill file behind
(
  _managed_endpoint_live() { return 0; }; _obligation_admit() { return 0; }
  _endpoint_mutation_lock() { return 1; }
  tmux() { case "$1" in display-message) printf '%s\n' "$TMP/wt2" ;; *) return 0 ;; esac; }
  mkdir -p "$TMP/wt2"
  OSRC_SEND_MAX_CHARS=10 _managed_session_send p "a message longer than ten chars"
  [ -z "$(ls "$TMP/wt2/.osrc-msgs" 2>/dev/null)" ]
) && ok || bad "a refused send left its spill file: $(ls "$TMP/wt2/.osrc-msgs" 2>/dev/null)"
(
  _obligation_admit() { return 1; }; _managed_endpoint_live() { return 0; }
  tmux() { case "$1" in display-message) printf '%s\n' "$TMP/wt3" ;; *) return 0 ;; esac; }
  mkdir -p "$TMP/wt3"
  OSRC_SEND_MAX_CHARS=10 _managed_session_send p "a message longer than ten chars"
  [ ! -d "$TMP/wt3/.osrc-msgs" ]
) && ok || bad "a send the ledger refused still spilled a file"

# ---- long message spill ----------------------------------------------------------------------------
mkdir -p "$TMP/wt"; git -C "$TMP/wt" init -q
tmux() { case "$1" in display-message) printf '%s\n' "$TMP/wt" ;; *) return 0 ;; esac; }
long="$(printf 'x%.0s' $(seq 1 1600))"
line="$(_osrc_send_spill p "$long")"
f="$(printf '%s' "$line" | sed 's/^Read the file \([^ ]*\) .*/\1/')"
[ -f "$f" ] && [ "$(cat "$f")" = "$long" ] && ok || bad "long message not spilled to a file: $line"
grep -qx '.osrc-msgs/' "$TMP/wt/.git/info/exclude" && ok || bad "spill dir not git-excluded"

# ---- session effort/model resolve the session's own lane (not the global devin default) -----------
_session_record() { printf 'cc\tclaude-fable-5-2\tmedium\t1\n'; }
SESSION_NAME=s; PROVIDER=devin; PROVIDER_EXPLICIT=0; MODEL=glm; MODEL_EXPLICIT=0
_osrc_session_adopt_record
[ "$PROVIDER" = cc ] && [ "$MODEL" = claude-fable-5-2 ] && ok || bad "effort lane resolution: PROVIDER=$PROVIDER MODEL=$MODEL"
PROVIDER=codex; PROVIDER_EXPLICIT=1; _osrc_session_adopt_record
[ "$PROVIDER" = codex ] && ok || bad "an explicit --provider was overridden"

# ---- tmux isolation guard (2026-11-13 incident: a bare server kill run from inside a pane took down
# the user's REAL tmux server, because $TMUX wins over TMUX_TMPDIR). Any test that kills a tmux
# server without -L/-S must unset TMUX first.
KS="kill""-server"
for t in "$HERE"/test_*.sh "$HERE"/conformance.sh; do
  { _t3b_pipe="$(grep -v '^[[:space:]]*#' "$t")" && grep -q "tmux $KS" <<<"$_t3b_pipe"; } || continue
  grep -qE 'unset TMUX( |$)' "$t" && ok || bad "$(basename "$t") kills a tmux server without unsetting TMUX (hits the real server from inside a pane)"
done

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
