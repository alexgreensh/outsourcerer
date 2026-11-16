# shellcheck shell=bash
# lib/winpty.sh: screen reading for the Windows (Git Bash) winpty session broker.
#
# Under tmux, `session read --state` / the send menu-guard read a RENDERED pane (capture-pane), so a
# redraw replaces the old frame. The winpty broker has no screen: `winpty -Xplain` writes a plain
# LINE STREAM to out.log, and every TUI redraw APPENDS lines. Two consequences (verified live on
# Windows 11 + Git for Windows winpty 0.4.3 + codex 0.169, 2026-11-16):
#   - A menu that was answered long ago is still in the log; a menu that is open now is simply the
#     last thing drawn. "Open" therefore means: a menu row/footer appears AFTER the last composer row.
#   - The footer under Codex's composer is re-printed on every redraw, so the composer row is rarely
#     within the last few lines the tmux reader expects.
# Window titles arrive in-band as OSC 0 (ESC ] 0 ; title BEL). Codex puts a braille spinner in the
# title while a turn runs and the bare folder name when idle, which is a cleaner busy signal than
# the text stream. The helpers below keep that signal and strip the rest.

# _winpty_clean <out.log> [tail-lines] -> printable, non-blank lines (OSC/CSI/CR stripped).
_winpty_clean() {
  local f="$1" n="${2:-200}"
  [ -f "$f" ] || return 0
  LC_ALL=C sed -e 's/\x1b\][^\x07]*\x07//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$f" 2>/dev/null \
    | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n "$n"
}

# _winpty_last_title <out.log> -> the most recent OSC 0 window title (empty when none).
_winpty_last_title() {
  [ -f "$1" ] || return 0
  LC_ALL=C grep -ao $'\x1b\\]0;[^\x07]*\x07' "$1" 2>/dev/null | tail -n 1 \
    | LC_ALL=C sed -e 's/^\x1b\]0;//' -e 's/\x07$//'
}

# _winpty_title_busy <title> -> rc 0 when the title starts with a braille spinner (U+2800-U+28FF).
_winpty_title_busy() {
  case "$1" in $'\xe2\xa0'*|$'\xe2\xa1'*|$'\xe2\xa2'*|$'\xe2\xa3'*) return 0 ;; esac
  return 1
}

# Row classifiers (on cleaned lines).
_winpty_is_menu_row() { # "› 2. Skip", "❯ 1. Yes", "  3. Cancel" (a numbered option row)
  local re='^[[:space:]]*((›|❯|>)[[:space:]]+)?[0-9]+\.[[:space:]]+[^[:space:]]'
  [[ $1 =~ $re ]]
}
_winpty_is_menu_footer() {
  case "$1" in
    *"enter continue · esc"*|*"enter select · esc"*|*"enter default · "*|*"Press enter to confirm or esc to cancel"*|*"Enter to confirm"*|*"Esc to cancel"*|*"enter to select"*|*"Enter to select"*|*"esc skip"*) return 0 ;;
  esac
  return 1
}
_winpty_is_composer_row() { # a prompt row that is NOT a menu option row
  case "$1" in "› "*|"❯ "*|"›"|"❯") ;; *) return 1 ;; esac
  _winpty_is_menu_row "$1" && return 1
  return 0
}

# _winpty_menu <out.log> -> rc 0 and prints the open menu (option rows, then footer) when a menu was
# drawn after the last composer row; rc 1 when no menu is open.
_winpty_menu() {
  local f="$1" lines=() i last_comp=-1 last_menu=-1 first_menu=-1 l
  while IFS= read -r l; do lines+=("$l"); done < <(_winpty_clean "$f" "${OSRC_WINPTY_MENU_TAIL:-60}")
  for i in "${!lines[@]}"; do
    l="${lines[$i]}"
    if _winpty_is_composer_row "$l"; then last_comp="$i"
    elif _winpty_is_menu_row "$l" || _winpty_is_menu_footer "$l"; then last_menu="$i"
    fi
  done
  [ "$last_menu" -gt "$last_comp" ] || return 1
  # The menu block: contiguous-ish rows after the last composer row, from the first option row.
  for ((i = last_comp + 1; i <= last_menu; i++)); do
    _winpty_is_menu_row "${lines[$i]}" && { first_menu="$i"; break; }
  done
  [ "$first_menu" -ge 0 ] || first_menu="$last_menu"
  # One row of context above the options (the question/title line), when there is one.
  [ "$first_menu" -gt $((last_comp + 1)) ] && first_menu=$((first_menu - 1))
  for ((i = first_menu; i <= last_menu; i++)); do printf '%s\n' "${lines[$i]}"; done
  return 0
}

# _winpty_answer_move <out.log> <option-number> -> prints the signed cursor move (+N / -N / 0) from
# the cursor row to that numbered option of the OPEN menu; rc 1 (with a reason on stderr) when no
# menu is open, the cursor row is not visible, or the option does not exist.
_winpty_answer_move() {
  local f="$1" want="$2" menu l pos=0 cur=-1 tgt=-1 re='^[[:space:]]*((›|❯|>)[[:space:]]+)?([0-9]+)\.'
  case "$want" in ''|*[!0-9]*) echo "answer needs an option NUMBER (got '$want')" >&2; return 1 ;; esac
  menu="$(_winpty_menu "$f")" || { echo "no open menu in the session output" >&2; return 1; }
  while IFS= read -r l; do
    _winpty_is_menu_row "$l" || continue
    pos=$((pos + 1))
    [[ $l =~ $re ]] || continue
    [ -n "${BASH_REMATCH[2]}" ] && cur="$pos"
    [ "${BASH_REMATCH[3]}" = "$want" ] && tgt="$pos"
  done <<<"$menu"
  [ "$tgt" -ge 0 ] || { echo "option $want is not in the open menu" >&2; return 1; }
  [ "$cur" -ge 0 ] || { echo "cannot see the menu cursor row; nothing selected" >&2; return 1; }
  if [ "$tgt" -ge "$cur" ]; then printf '+%s\n' $((tgt - cur)); else printf -- '-%s\n' $((cur - tgt)); fi
}

# _winpty_composer_holds <out.log> <text> -> rc 0 when the LAST composer row still shows the start of
# <text> (the send was typed but not submitted).
_winpty_composer_holds() {
  local f="$1" want l last=""
  want="$(printf '%s' "$2" | tr -s '[:space:]' ' ' | cut -c1-24)"
  [ -n "$want" ] || return 1
  while IFS= read -r l; do _winpty_is_composer_row "$l" && last="$l"; done < <(_winpty_clean "$f" 40)
  case "$last" in *"$want"*) return 0 ;; esac
  return 1
}

# _winpty_state_json <out.log> [engine] -> {"state","evidence"} in the session read --state vocabulary.
_winpty_state_json() {
  local f="$1" eng="${2:-}" menu title
  [ -s "$f" ] || { _pane_state_json unknown "no output yet"; return 0; }
  if menu="$(_winpty_menu "$f")"; then
    _pane_state_json waiting-approval "menu open: $(printf '%s' "$menu" | tr '\n' '|' | cut -c1-200)"
    return 0
  fi
  # Turn edges in the stream: a busy row ("esc to interrupt") newer than the last turn-end row
  # ("Worked for 27s", Claude's "· done") means a turn is running. Verified live: Codex does NOT
  # always refresh the window title on a later turn, so the text decides and the title only adds.
  local busy_at=-1 done_at=-1 i=0 l busy_line=""
  while IFS= read -r l; do
    case "$l" in
      *"esc to interrupt"*|*"esc twice to interrupt"*) busy_at="$i"; busy_line="$l" ;;
      *"Worked for "*|*" for "[0-9]*"s · done"*|*" for "[0-9]*"m · done"*) done_at="$i" ;;
    esac
    i=$((i + 1))
  done < <(_winpty_clean "$f" 120)
  if [ "$busy_at" -gt "$done_at" ]; then
    _pane_state_json working "$(_osrc_scr_trim "$busy_line" 2>/dev/null || printf '%s' "$busy_line")"
    return 0
  fi
  title="$(_winpty_last_title "$f")"
  if [ "$done_at" -lt 0 ] && _winpty_title_busy "$title"; then
    _pane_state_json working "window title shows a busy spinner: $title"
    return 0
  fi
  case "$eng" in codex|cx)
    if [ "$done_at" -ge 0 ]; then _pane_state_json idle "turn ended; no turn running since"; return 0; fi
    [ -n "$title" ] && { _pane_state_json idle "window title is idle: $title"; return 0; } ;;
  esac
  _winpty_clean "$f" 30 | _pane_state_classify "$eng"
}
