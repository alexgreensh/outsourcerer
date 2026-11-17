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
  # Real ESC/BEL bytes ($'...'), not \x escapes: BSD sed (macOS) reads "[^\x07]" as literal characters.
  # OSC ends in BEL or ST (ESC \), DCS in ST; CSI may carry < = > and intermediates. Any control byte
  # left after that (a lone ESC, OSC 52 remnants) is dropped, so `read` never drives the caller's terminal.
  LC_ALL=C sed -e $'s|\x1b][^\x07\x1b]*\x07||g' -e $'s|\x1b][^\x07\x1b]*\x1b\\\\||g' \
      -e $'s|\x1bP[^\x1b]*\x1b\\\\||g' -e $'s|\x1b\\[[0-9;?<=>]*[ -/]*[@-~]||g' "$f" 2>/dev/null \
    | LC_ALL=C tr -d '\000-\010\013-\037\177' | grep -v '^[[:space:]]*$' | tail -n "$n"
}

# _winpty_last_title <out.log> -> the most recent OSC 0 window title (empty when none).
_winpty_last_title() {
  [ -f "$1" ] || return 0
  LC_ALL=C grep -ao $'\x1b\\]0;[^\x07]*\x07' "$1" 2>/dev/null | tail -n 1 \
    | LC_ALL=C sed -e $'s|^\x1b]0;||' -e $'s|\x07$||'
}

# _winpty_title_busy <title> -> rc 0 when the title starts with a braille spinner (U+2800-U+28FF).
_winpty_title_busy() {
  case "$1" in $'\xe2\xa0'*|$'\xe2\xa1'*|$'\xe2\xa2'*|$'\xe2\xa3'*) return 0 ;; esac
  return 1
}

# Turn-edge row classifiers (on cleaned lines), shared by the state reader and the send
# verification so the two can never disagree about what proves a turn started or ended.
_winpty_is_busy_row() { # "• Working (12s • esc to interrupt)"
  case "$1" in *"esc to interrupt"*|*"esc twice to interrupt"*) return 0 ;; esac
  return 1
}
_winpty_is_done_row() { # "Worked for 27s", Claude's "· done"
  case "$1" in *"Worked for "*|*" for "[0-9]*"s · done"*|*" for "[0-9]*"m · done"*) return 0 ;; esac
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
  local f="$1" lines=() i last_comp=-1 last_menu=-1 last_sure=-1 first_menu=-1 l
  local cur='^[[:space:]]*(›|❯|>)[[:space:]]+[0-9]+\.'
  while IFS= read -r l; do lines+=("$l"); done < <(_winpty_clean "$f" "${OSRC_WINPTY_MENU_TAIL:-60}")
  for i in "${!lines[@]}"; do
    l="${lines[$i]}"
    if _winpty_is_composer_row "$l"; then last_comp="$i"
    elif _winpty_is_menu_footer "$l" || [[ $l =~ $cur ]]; then last_menu="$i"; last_sure="$i"
    elif _winpty_is_menu_row "$l"; then last_menu="$i"
    fi
  done
  # Open only with a footer or a cursor-marked option row after the last composer row: a plain
  # numbered list ("1. Read the file") in the agent's own output is not a menu (0.16.4 review).
  [ "$last_sure" -gt "$last_comp" ] || return 1
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
# <text> AND nothing after it proves the engine took it (the send was typed but not submitted). The
# winpty log is append-only, so a SUBMITTED line's echo is never erased: an echo typed into an IDLE
# engine with a busy or turn-end row after it is the engine already working on that send, and a retry
# Enter would be a duplicate (the 0.16.4 double-Enter bug on real Codex output, #77).
# Typed MID-TURN (the last edge before the echo is a busy row), an edge after the echo proves nothing:
# the running turn keeps re-printing its "Working (Ns" timer and then its turn-end row whether or not
# our Enter landed. There only a turn end followed by a NEW busy row (our queued message started)
# proves the send; otherwise the text still counts as held and keeps its retries (S5 review of #77).
_winpty_composer_holds() {
  local f="$1" want l last="" edge="" pre="" post=""
  want="$(printf '%s' "$2" | tr -s '[:space:]' ' ' | cut -c1-24)"
  [ -n "$want" ] || return 1
  while IFS= read -r l; do
    if _winpty_is_composer_row "$l"; then last="$l"; pre="$edge"; post=""
    elif _winpty_is_busy_row "$l"; then edge=b; post="${post}b"
    elif _winpty_is_done_row "$l"; then edge=d; post="${post}d"
    fi
  done < <(_winpty_clean "$f" 40)
  case "$last" in *"$want"*) ;; *) return 1 ;; esac
  [ -n "$post" ] || return 0
  [ "$pre" = b ] || return 1
  case "$post" in *d*b*) return 1 ;; esac
  return 0
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
    if _winpty_is_busy_row "$l"; then busy_at="$i"; busy_line="$l"
    elif _winpty_is_done_row "$l"; then done_at="$i"
    fi
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

# _winpty_cmd_send <sdir> <text...>: `session send` on the winpty broker (moved out of the engine, 0.16.4).
_winpty_cmd_send() {
  local sdir="$1"; shift
  [ -n "${1:-}" ] || die "session send needs text"
  [ -d "$sdir" ] || die "no session '$SESSION_NAME' (run: $0 session start)"
  _osrc_session_cap_send "$SESSION_NAME" "$*"   # L7 add-on: no new work to a capped lane
  # Menu guard (tmux parity, Bug A): text typed into an open menu is lost, and its Enter picks
  # whatever row the cursor is on. Refuse and point at `session answer`.
  local _wmenu
  if _wmenu="$(_winpty_menu "$sdir/out.log")"; then
    printf '%s\n' "$_wmenu"
    printf 'EVENT failed %s %s send refused: menu open; nothing typed\nNEXT %s session answer <option-number>\n' "$SESSION_NAME" "$(date +%s)" "$0"
    die "session send refused: the session is showing a menu, not a text composer. Nothing was typed. Answer it with: $0 session answer <option-number>"
  fi
  mkdir -p "$sdir/cmd"
  local tmp; tmp="$(mktemp "$sdir/cmd/.send.XXXXXX" 2>/dev/null || echo "$sdir/cmd/send.$$")"
  printf '%s' "$*" > "$tmp"
  mv "$tmp" "$sdir/cmd/send-$(date +%s)-$$-$RANDOM.txt"
  # The broker presses Enter once. Some TUIs swallow the first Enter of a fast paste; press it
  # again only when the text is verifiably still in the composer (no turn edge proves the engine
  # took it) and no menu has opened.
  local _wtry=0
  while [ "$_wtry" -lt 2 ]; do
    sleep 1.5
    [ -d "$sdir/cmd" ] || break
    _winpty_menu "$sdir/out.log" >/dev/null && break
    _winpty_composer_holds "$sdir/out.log" "$*" || break
    : > "$sdir/cmd/enter-$(date +%s)-$$-$RANDOM"
    _wtry=$((_wtry + 1))
  done
  echo "sent. Read progress with: $0 session read"
}

# _winpty_cmd_answer <sdir> [<option-number>]: `session answer` on the winpty broker.
_winpty_cmd_answer() {
  local sdir="$1"; shift
  [ -d "$sdir" ] || die "no session '$SESSION_NAME' (run: $0 session start)"
  local _wm _wmv
  _wm="$(_winpty_menu "$sdir/out.log")" || die "no interactive menu detected in '$SESSION_NAME'. Re-check with: $0 session read"
  if [ "$#" -eq 0 ]; then
    printf '%s\n' "$_wm"
    echo "answer with:  $0 session answer <option-number>"
    return 0
  fi
  _wmv="$(_winpty_answer_move "$sdir/out.log" "$1")" || die "session answer: nothing selected (reason above). Re-check with: $0 session read"
  mkdir -p "$sdir/cmd"
  local tmp; tmp="$(mktemp "$sdir/cmd/.answer.XXXXXX" 2>/dev/null || echo "$sdir/cmd/answer.$$")"
  printf '%s' "$_wmv" > "$tmp"
  mv "$tmp" "$sdir/cmd/answer-$(date +%s)-$$-$RANDOM.txt"
  sleep 1.5
  echo "answered option $1. Re-check with: $0 session read --state"
}

# _winpty_cmd_read <sdir> <read|state> [--state]: `session read` on the winpty broker.
_winpty_cmd_read() {
  local sdir="$1" sub="$2"; shift 2
  local _want_state=0
  [ "$sub" = state ] && _want_state=1
  while [ "$#" -gt 0 ]; do case "$1" in --state) _want_state=1; shift;; *) shift;; esac; done
  [ -d "$sdir" ] || { echo "no session '$SESSION_NAME' (run: $0 session start)"; return 0; }
  if [ "$_want_state" = "1" ]; then
    # WITH --state: menu (after the last composer row) > title spinner > engine reader on the tail.
    _winpty_state_json "$sdir/out.log" "$(_session_record "$SESSION_NAME" 2>/dev/null | cut -f1)"
  else
    # In-band window titles (OSC 0, one per spinner frame) and CRs are terminal noise, not output.
    if [ -f "$sdir/out.log" ]; then
      _winpty_clean "$sdir/out.log" 200
    else
      echo "(no output yet)"
    fi
  fi
}
