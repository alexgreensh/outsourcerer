#!/bin/bash
# L3: lib/screen.sh is the one screen reader. Every fixture under fixtures/screen/ is a REAL pane
# capture (tmux capture-pane -e -p) taken 2026-11-13 from throwaway sessions: Claude Code 2.1.323
# (Haiku), Codex 0.167 (gpt-5.6-luna), Devin CLI 3000.12 (SWE-2), Antigravity CLI 1.5.5, gemini-cli.
# Personal data scrubbed (home path, email, session URL). Also covers: LC_ALL=C (box glyphs must still
# match), Gemini/agy trailing blank lines, text the orchestrator typed (never evidence), the menu gate
# (false-menu composer, a reply ending in a numbered list), E6 duplicate sends, E7 status-bar redraw,
# and the `session effort` lane resolution.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"; FX="$HERE/fixtures/screen"
TMP="$(mktemp -d "$HERE/.test-screen.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; ok(){ pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
export OSRC_HOME="$TMP/state"; mkdir -p "$OSRC_HOME"
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
agy-idle|agy|composer||
agy-working|agy|working||
agy-idle-after-work|agy|idle||
agy-approval|agy|approval|shell|touch made-by-agy.txt && ls
agy-file-approval|agy|approval|write|/Users/dev/CascadeProjects/Prompts/PERSONAL_OS/PROJECTS/outsourcerer/outputs/build/wt-auto-L3/.osrc-test-L3/work-agy/notes.txt
agy-trust-folder-menu|agy|approval|trust|
gm-trust-folder-menu|gemini|approval|trust|'

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
  printf '%s\n' "$TABLE" | grep -q "^$b|" && ok || bad "fixture $b has no expected state in the table"
done

# ---- LC_ALL=C: the orchestrator's background shell had no UTF-8 locale and every glyph test missed.
out="$(LC_ALL=C LANG=C bash -c '
  OSRC_HOME="'"$TMP"'/state-c" OSRC_SOURCED=1; export OSRC_HOME OSRC_SOURCED; set --; . "'"$SRC"'" >/dev/null 2>&1
  for f in dv-approval cc-permission-bash agy-approval cc-fable-composer-false-menu cx-approval; do
    _osrc_screen_analyze_text "" < "'"$FX"'/$f.ansi"; printf "%s=%s:%s\n" "$f" "$OSRC_SCR_STATE" "$OSRC_SCR_ENGINE"
  done')"
for want in dv-approval=approval:devin cc-permission-bash=approval:cc agy-approval=approval:agy cc-fable-composer-false-menu=composer:cc cx-approval=approval:codex; do
  printf '%s\n' "$out" | grep -qx "$want" && ok || bad "LC_ALL=C: want $want, got: $(printf '%s' "$out" | tr '\n' ' ')"
done

# ---- trailing blank lines (Gemini/agy pad the pane): 40 extra blank rows change nothing.
{ cat "$FX/agy-approval.ansi"; for i in $(seq 1 40); do printf '\n'; done; } > "$TMP/agy-pad.ansi"
_osrc_screen_analyze_text agy < "$TMP/agy-pad.ansi"
[ "$OSRC_SCR_STATE" = approval ] && [ "$OSRC_SCR_CMD" = "touch made-by-agy.txt && ls" ] && ok || bad "trailing blanks hid the agy prompt ($OSRC_SCR_STATE)"

# ---- typed text is never evidence: the composer holds "ROUND4 DONE ... Do you want to proceed? [y/N]"
_osrc_screen_analyze_text cc < "$FX/cc-composer-typed-unsent.ansi"
case "$OSRC_SCR_COMPOSER" in "When you finish, reply with exactly: ROUND4 DONE."*) ok ;; *) bad "typed composer text not extracted: $OSRC_SCR_COMPOSER" ;; esac
[ "$OSRC_SCR_STATE" = composer ] && ok || bad "typed [y/N] text in the composer read as $OSRC_SCR_STATE"

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
CAP="$FX/cc-reply-numbered-list.ansi"; [ "$(_managed_menu_detect p 2>/dev/null | head -1)" = "MENU none" ] && ok || bad "a reply ending in a numbered list blocked send (E8)"
CAP="$FX/cc-idle-after-work.ansi"; [ "$(_managed_menu_detect p 2>/dev/null | head -1)" = "MENU none" ] && ok || bad "idle cc pane read as a menu"
CAP="$FX/cc-permission-bash.ansi"; [ "$(_managed_menu_detect p 2>/dev/null | head -1)" != "MENU none" ] && ok || bad "real cc permission prompt not detected as a menu"
CAP="$FX/cc-askuserquestion.ansi"; [ "$(_managed_menu_detect p 2>/dev/null | head -1)" != "MENU none" ] && ok || bad "cc question picker not detected as a menu"
# Unknown lane, unrecognised layout: the legacy path must still not call a composer box a menu.
_managed_provider() { printf droid; }
printf '%s\n' '────────────────────' '❯ hello there' '────────────────────' '  model x | ctx 3%' '  shift+p to plan' > "$TMP/generic-composer.txt"
CAP="$TMP/generic-composer.txt"; [ "$(_managed_menu_detect p 2>/dev/null | head -1)" = "MENU none" ] && ok || bad "legacy path read a composer box as a menu"
_managed_provider() { printf devin; }
CAP="$FX/dv-approval.ansi"; [ "$(_managed_menu_detect p 2>/dev/null | head -1)" != "MENU none" ] && ok || bad "devin approval not detected as a menu"

# ---- E6: two identical sends to one session are both admitted (each is its own obligation) ---------
_obligation_append "send.x.1.a" e6sess typing_started "" >/dev/null 2>&1
o1="send.e6sess.123.$(date +%s).1"; o2="send.e6sess.123.$(date +%s).2"
_obligation_admit "$o1" e6sess && _obligation_append "$o1" e6sess delivery_unknown "" && ok || bad "first send not admitted"
_obligation_admit "$o2" e6sess && ok || bad "an identical second send was refused (E6)"
grep -q 'cksum | awk .{print $1}.).$(date +%s).$$$RANDOM' "$HERE/../lib/send.sh" && ok || bad "send obligation id has no per-send nonce"

# ---- E7: Claude Code status bar redraws while the text sits in the composer -> NOT submitted -------
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
OSRC_SEND_VERIFY_SECS=2 _osrc_send_verify_screen p cc "please run the suite"; rc=$?
[ "$rc" = 0 ] && ok || bad "cleared composer + spinner not accepted as submitted (rc=$rc $OSRC_SEND_EVIDENCE)"

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
  grep -v '^[[:space:]]*#' "$t" | grep -q "tmux $KS" || continue
  grep -qE 'unset TMUX( |$)' "$t" && ok || bad "$(basename "$t") kills a tmux server without unsetting TMUX (hits the real server from inside a pane)"
done

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
