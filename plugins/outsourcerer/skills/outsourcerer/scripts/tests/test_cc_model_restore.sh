#!/usr/bin/env bash
# Track C — claude-native (cc) live model observe + restore (the Fable->Opus flip-back).
# Parser/navigation logic is tested against fixtures captured from a real Claude Code TUI; the live
# end-to-end path was validated by hand against a running session during development.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "$PWD/.test-cc-model.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
export OSRC_CC_PICKER_WAIT=0 OSRC_CC_PICKER_NAV_WAIT=0
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
set --; . "$SRC" >/dev/null 2>&1

# ---- fixtures (verbatim shapes from a real Claude Code v2.1 TUI) ---------------------------------
PICKER_CURSOR_OPUS="$(cat <<'EOF'
   Select model
   Switch between Claude models. Your pick becomes the default for new sessions.
     1. Default (recommended)  Opus 5 with 1M context · Best for everyday, complex tasks
     2. Opus (1M context)      Opus 5 with 1M context · Best for everyday, complex tasks
     3. Fable                  Fable 5 · Most capable for your hardest and longest-running tasks
     4. Sonnet                 Sonnet 5 · Efficient for routine tasks
     5. Haiku                  Haiku 4.5 · Fastest for quick answers
   ❯ 6. Opus ✔                 Opus 5 · Best for everyday, complex tasks
   Enter to set as default · s to use this session only · Esc to cancel
EOF
)"
FOOTER_FABLE="  Fable 5 | hi | tmp | ContextQ:--"
FOOTER_OPUS="  Opus 5 | hi | tmp | ContextQ:--"
COMPOSER_EMPTY_PLACEHOLDER='❯ Try "create a util logging.py that..."'
COMPOSER_EMPTY_GLYPH='❯ '
COMPOSER_BUSY='❯ /model sonnet'

# ---- _cc_model_family ---------------------------------------------------------------------------
for pair in "fable:fable" "claude-fable-5:fable" "Fable 5:fable" "opus:opus" "claude-opus-4-8:opus" \
            "Opus 5:opus" "sonnet:sonnet" "haiku:haiku"; do
  in="${pair%:*}"; want="${pair#*:}"
  [ "$(_cc_model_family "$in")" = "$want" ] && ok "family($in)=$want" || bad "family($in) wrong"
done
_cc_model_family "gpt-5.6" && bad "family(gpt) should be nonzero" || ok "family(non-claude) declines"

# ---- observer: footer read ----------------------------------------------------------------------
tmux() { case "$1 $2" in "capture-pane"*) printf '%s\n' "$FIXTURE" ;; *) return 0 ;; esac; }
FIXTURE="$FOOTER_FABLE";  [ "$(_session_model_observe_cc_builtin p)" = fable ] && ok "observe reads fable footer" || bad "observe fable"
FIXTURE="$FOOTER_OPUS";   [ "$(_session_model_observe_cc_builtin p)" = opus ]  && ok "observe reads opus footer"  || bad "observe opus"
FIXTURE="no footer here"; [ "$(_session_model_observe_cc_builtin p)" = unknown ] && ok "observe unknown when no footer" || bad "observe should be unknown"
# task text mentioning a model must NOT be mistaken for the live model (no ContextQ marker)
FIXTURE='> please switch to opus and fable in your plan'; [ "$(_session_model_observe_cc_builtin p)" = unknown ] && ok "observe ignores model names in body text" || bad "observe false-positive on body text"

# ---- composer-empty gate ------------------------------------------------------------------------
FIXTURE="$COMPOSER_EMPTY_PLACEHOLDER"; _cc_composer_empty p && ok "composer empty (placeholder)" || bad "placeholder should be empty"
FIXTURE="$COMPOSER_EMPTY_GLYPH";       _cc_composer_empty p && ok "composer empty (bare glyph)"  || bad "bare glyph should be empty"
FIXTURE="$COMPOSER_BUSY";              _cc_composer_empty p && bad "busy composer wrongly empty" || ok "composer busy detected (pending text)"

# ---- restore navigation: cursor on Opus(row6) -> target Fable(row3) => 3 Ups then 's' ------------
KEYS="$TMP/keys"; : > "$KEYS"
CAPCOUNT="$TMP/capn"; echo 0 > "$CAPCOUNT"
# stateful capture-pane: 1st call returns the picker, later calls return the post-switch fable footer
tmux() {
  case "$1 $2" in
    "capture-pane"*)
      local n; n="$(cat "$CAPCOUNT")"; echo $((n+1)) > "$CAPCOUNT"
      if [ "$n" -eq 0 ]; then printf '%s\n' "$PICKER_CURSOR_OPUS"; else printf '%s\n' "$FOOTER_FABLE"; fi ;;
    "send-keys"*) shift; printf '%s\n' "$*" >> "$KEYS" ;;
    *) return 0 ;;
  esac
}
if _session_model_restore_cc pane fable; then ok "restore returns success when footer confirms fable"; else bad "restore should verify fable"; fi
ups="$(grep -c -- '-t pane Up' "$KEYS" 2>/dev/null || echo 0)"
[ "$ups" = 3 ] && ok "navigated 3 rows up (Opus row6 -> Fable row3)" || bad "expected 3 Up keys, got $ups"
grep -q -- '-l -- s' "$KEYS" && ok "confirmed with 's' (session-only, no global default change)" || bad "did not press 's'"
grep -q -- '-t pane Down' "$KEYS" && bad "should not have sent Down for an upward move" || ok "no stray Down keys"

# ---- restore declines a model absent from the picker, without leaving it open --------------------
KEYS2="$TMP/keys2"; : > "$KEYS2"; echo 0 > "$CAPCOUNT"
tmux() {
  case "$1 $2" in
    "capture-pane"*) printf '%s\n' "$PICKER_CURSOR_OPUS" ;;   # no 'gemini' row present
    "send-keys"*) shift; printf '%s\n' "$*" >> "$KEYS2" ;;
    *) return 0 ;;
  esac
}
# a valid family word not offered by this account's picker -> use haiku fixture-absent scenario:
# force absence by asking for a family the fixture lacks. The fixture HAS haiku; craft one without.
PICKER_NO_HAIKU="$(printf '%s\n' "$PICKER_CURSOR_OPUS" | grep -v 'Haiku')"
tmux() {
  case "$1 $2" in
    "capture-pane"*) printf '%s\n' "$PICKER_NO_HAIKU" ;;
    "send-keys"*) shift; printf '%s\n' "$*" >> "$KEYS2" ;;
    *) return 0 ;;
  esac
}
if _session_model_restore_cc pane haiku; then bad "restore should decline a model not in the picker"; else ok "restore declines a model absent from the picker"; fi
grep -q 'Escape' "$KEYS2" && ok "closed the picker (Escape) on decline" || bad "left picker open on decline"

# ---- regression (gauntlet MAJOR): an ambiguous footer must NOT fabricate a family -----------------
# "Opus Fable" in the model field means the parser is not confident -> must return unknown, not the
# first substring match. Valid single-family and ANSI-wrapped footers must still resolve.
tmux() { case "$1 $2" in "capture-pane"*) printf '%s\n' "Opus Fable | high | /x | ContextQ: 1" ;; *) return 0 ;; esac; }
[ "$(_session_model_observe_cc_builtin pane)" = "unknown" ] && ok "ambiguous two-family footer -> unknown (no fabrication)" || bad "ambiguous footer fabricated a family"
tmux() { case "$1 $2" in "capture-pane"*) printf '%s\n' "Opus | high | /x | ContextQ: 1" ;; *) return 0 ;; esac; }
[ "$(_session_model_observe_cc_builtin pane)" = "opus" ] && ok "valid single-family footer still resolves" || bad "valid footer broke after ambiguity guard"
tmux() { case "$1 $2" in "capture-pane"*) printf '%b\n' "\033[31mFable\033[0m | high | /x | ContextQ: 1" ;; *) return 0 ;; esac; }
[ "$(_session_model_observe_cc_builtin pane)" = "fable" ] && ok "ANSI-wrapped single-family footer still resolves" || bad "ANSI footer broke after ambiguity guard"

echo "----"
echo "cc-model-restore: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
