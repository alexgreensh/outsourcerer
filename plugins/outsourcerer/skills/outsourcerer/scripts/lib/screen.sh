# shellcheck shell=bash
# lib/screen.sh: the ONE screen reader for delegate panes.
#
# Every orchestrator used to hand-roll its own prompt regex, and each one broke a different way:
# Claude Code's composer + status bar read as a menu, a reply ending in a numbered list blocked
# `session send`, Gemini's trailing blank lines hid its prompt, agy's file menu was never seen, the
# orchestrator's own typed text matched as "DONE", and a C-locale shell never matched a box glyph.
# This module is the single owner of that job. Callers ask `osrc_screen_state <pane> [engine]`.
#
#   osrc_screen_state <pane> [engine]   -> line 1: approval|question|working|idle|composer|unknown|limit|dead
#                                          line 2: evidence (one line)
#   osrc_screen_report <pane> [engine]  -> KEY=value lines (state, engine, pending command, ...)
#   _osrc_screen_analyze_text [engine]  -> same analysis on text read from STDIN (fixtures, logs)
#
# States:
#   approval  a permission / trust / consent menu is open (the delegate is blocked on it)
#   question  the delegate asked something: an AskUserQuestion-style picker, or its last turn
#             ended with a question in prose
#   working   the engine shows a live busy signal (spinner line, "esc to interrupt", busy composer)
#   idle      the composer is ready and a turn has finished since the last prompt
#   composer  the composer is ready and no turn has finished (fresh boot), OR it holds text that
#             was typed and never submitted (evidence says which)
#   limit     a rate-limit / quota banner is the newest signal: the provider is parked until a
#             stated reset, whatever the composer shows
#   dead      pane-level only (never from analyze_text): tmux proves the pane's process exited
#             but its last frame is still held (remain-on-exit), so the capture is a corpse
#   unknown   none of the above could be proven
#
# Design rules (each one is a failure that happened):
# - Read the LIVE region per engine (composer box, modal footer), never "anything in the last N
#   lines". The status rows under Claude Code's composer are ignored entirely.
# - The composer's own content is masked from every match: what the orchestrator typed is never
#   evidence of anything.
# - Blank lines are dropped before anything else (Gemini/agy pad the pane with them).
# - Every function that reads a pane pins a UTF-8 locale; glyph tests use literal byte strings,
#   never bracket classes, so the result is identical under LC_ALL=C.

# ---- locale --------------------------------------------------------------------------------------
_OSRC_UTF8_LOCALE=""
_osrc_utf8_locale() { # -> prints a usable UTF-8 locale name (cached)
  if [ -z "$_OSRC_UTF8_LOCALE" ]; then
    local cand avail
    avail="
$(locale -a 2>/dev/null)
"
    for cand in en_US.UTF-8 en_US.utf8 C.UTF-8 C.utf8; do
      case "$avail" in *"
$cand
"*) _OSRC_UTF8_LOCALE="$cand"; break ;; esac
    done
    [ -n "$_OSRC_UTF8_LOCALE" ] || _OSRC_UTF8_LOCALE="C.UTF-8"
  fi
  printf '%s' "$_OSRC_UTF8_LOCALE"
}

# ---- ANSI handling -------------------------------------------------------------------------------
_managed_strip_ansi() {
  # CSI (ESC [ ... letter) and OSC (ESC ] ... BEL | ESC \) sequences; Claude Code's header links are
  # OSC 8, which the old CSI-only strip left in as "]8;id=...".
  LC_ALL=C awk '{ gsub(/\033\][^\007\033]*(\007|\033\\)/, ""); gsub(/\033\[[0-9;?<=>]*[ -\/]*[@-~]/, ""); gsub(/\033[()][0-9A-Za-z]/, ""); gsub(/\r/, ""); gsub(/\302\240/, " "); print }'
}

_managed_line_selected() {
  local line="$1" esc
  case "$line" in *❯*) return 0 ;; esac
  esc="$(printf '\033')"
  printf '%s' "$line" | LC_ALL=C grep -Eq "$esc\\[([0-9]+;)*7(;[0-9]+)*m" && return 0
  printf '%s' "$line" | LC_ALL=C grep -Eq "$esc\\[([0-9]+;)*(4[0-9]|48)(;[0-9]+)*m"
}

_managed_label_contains_literal() {
  local label="$1" selector="$2"
  [ -n "$selector" ] || return 1
  printf '%s\n' "$label" | grep -F -q -- "$selector"
}

# Read raw (ANSI) text on stdin into the parallel arrays _SCR_L (stripped, right-trimmed) and
# _SCR_D (1 when the line carries a dim/placeholder colour). Blank lines are dropped here, once.
_SCR_L=(); _SCR_D=(); _SCR_N=0
_osrc_scr_load() {
  local line flag
  _SCR_L=(); _SCR_D=(); _SCR_N=0
  while IFS= read -r line; do
    flag="${line%%|*}"; line="${line#*|}"
    _SCR_L[$_SCR_N]="$line"; _SCR_D[$_SCR_N]="$flag"; _SCR_N=$((_SCR_N + 1))
  done < <(LC_ALL=C awk '
    { raw=$0; s=$0
      gsub(/\033\][^\007\033]*(\007|\033\\)/, "", s); gsub(/\033\[[0-9;?<=>]*[ -\/]*[@-~]/, "", s)
      gsub(/\033[()][0-9A-Za-z]/, "", s); gsub(/\r/, "", s); gsub(/\302\240/, " ", s); sub(/[ \t]+$/, "", s)
      if (s ~ /^[ \t]*$/) next
      dim = (raw ~ /\033\[2m/ || raw ~ /\033\[38;2;124;124;124m/ || raw ~ /\033\[90m/) ? 1 : 0
      print dim "|" s }')
}

# Last index in [lo, hi] whose line matches the glob pattern; -1 when none. Patterns are case globs
# with literal glyphs only (byte-exact in every locale).
_osrc_scr_last() { # <glob> [lo] [hi]
  local pat="$1" lo="${2:-0}" hi="${3:-$((_SCR_N - 1))}" i
  i="$hi"
  while [ "$i" -ge "$lo" ] && [ "$i" -ge 0 ]; do
    # shellcheck disable=SC2254
    case "${_SCR_L[$i]}" in $pat) printf '%s' "$i"; return 0 ;; esac
    i=$((i - 1))
  done
  printf '%s' -1
}
_osrc_scr_any() { # <glob> [lo] [hi] -> 0 when some line in range matches
  [ "$(_osrc_scr_last "$@")" -ge 0 ]
}
_osrc_scr_trim() { local s="$1"; s="${s#"${s%%[! ]*}"}"; printf '%s' "${s%"${s##*[! ]}"}"; }
# Claude Code's mode status line under the composer ("⏵⏵ auto mode on (shift+tab to cycle)",
# "⏸ plan mode on", "⏵⏵ bypass permissions on", "⏵⏵ accept edits on", "⏸ manual mode on"). It is
# drawn only beside a live composer: no Claude modal (permission, picker, trust) shows it, and each
# of those ends in its own footer. Seen live 2026-11-13: read as a choice menu, send refused to type.
_osrc_scr_cc_status_row() { # <row>: the WHOLE row must be one of Claude's real mode lines
  printf '%s\n' "$(_osrc_scr_trim "$1")" | LC_ALL="$(_osrc_utf8_locale)" grep -Eq \
    '^(⏵⏵ (accept edits|auto mode|bypass permissions) on|⏸ (plan|manual) mode on)( \(shift\+tab to cycle\))?( · ← [0-9]+ agents?)?$'
}

_osrc_scr_is_rule() { # a horizontal rule (Claude/Devin/agy composer box), possibly with a title
  case "$(_osrc_scr_trim "$1")" in "──"*) return 0 ;; esac
  return 1
}

# ---- engine detection ----------------------------------------------------------------------------
_osrc_scr_engine_guess() {
  local i l
  i=$((_SCR_N - 1))
  while [ "$i" -ge 0 ]; do
    l="${_SCR_L[$i]}"
    case "$l" in
      *"Claude Code v"*|*"Claude Code'll be able to"*|*"⏵⏵ "*|*"manual mode on"*|*"shift+tab to cycle"*|*"Esc to cancel · Tab to amend"*|*"Enter to select · ↑/↓ to navigate"*|*"⤸ resumable"*|*"accept edits on"*|*"plan mode on"*) printf cc; return ;;
      *"Devin CLI"*|*"opt+m to switch"*|*"Ask Devin to"*|*"Guide Devin while"*|*"esc twice to interrupt"*|*"↵ confirm · esc cancel"*) printf devin; return ;;
      *"OpenAI Codex"*|*"Ask Codex to"*|*"Press enter to confirm or esc to cancel"*|*"enter continue · esc back"*|*"for agents · ? for shortcuts"*) printf codex; return ;;
      *"Antigravity CLI"*|*"ctrl+g edit/expand command"*|*"↑/↓ Navigate · enter Confirm"*|*"Gemini 4 "*" · "*) printf agy; return ;;
      *"Gemini CLI"*|*"Type your message or @path"*|*"gemini-"*"context left"*) printf gemini; return ;;
    esac
    i=$((i - 1))
  done
  printf generic
}

_osrc_scr_engine_norm() { # <provider/engine alias> -> cc|codex|devin|agy|gemini|generic|""
  case "$1" in
    cc|claude|claude-code) printf cc ;;
    codex|cx) printf codex ;;
    devin|dv) printf devin ;;
    agy|antigravity) printf agy ;;
    gemini|gm) printf gemini ;;
    "") printf '' ;;
    *) printf generic ;;
  esac
}

# ---- analysis results (globals, reset per call) --------------------------------------------------
_osrc_scr_reset() {
  OSRC_SCR_STATE=unknown; OSRC_SCR_EVIDENCE="no recognized signal"; OSRC_SCR_ENGINE=""
  OSRC_SCR_KIND=""; OSRC_SCR_CMD=""; OSRC_SCR_PATH=""; OSRC_SCR_SEL=""; OSRC_SCR_SCOPE=""
  OSRC_SCR_COMPOSER=""; OSRC_SCR_COMPOSER_FOUND=0; OSRC_SCR_HIST_END=-1; OSRC_SCR_GENERIC=0
  OSRC_SCR_LIMIT_DETAIL=""; OSRC_SCR_LIMIT_AT=-1; OSRC_SCR_LIMIT_SECS=""; OSRC_SCR_PANE_DEAD=""; OSRC_SCR_AT=-1
}
# <state> <evidence> [row]: row = index of the line that proved the state (-1 = not one line)
_osrc_scr_set() { OSRC_SCR_STATE="$1"; OSRC_SCR_EVIDENCE="$(_osrc_scr_trim "$2")"; OSRC_SCR_AT="${3:--1}"; }

# Composer box: the last pair of rules with only status rows (<= max_after lines) below it. Sets
# OSRC_SCR_COMPOSER (typed text, placeholder removed), OSRC_SCR_COMPOSER_FOUND, OSRC_SCR_HIST_END
# (last history line index, above the box). <glyph> is the prompt glyph ("❯", "❭", ">").
_osrc_scr_composer_box() { # <glyph> <max-status-rows-below>
  local glyph="$1" maxbelow="$2" b a i text dimflag
  b=$((_SCR_N - 1))
  while [ "$b" -ge 0 ] && [ $((_SCR_N - 1 - b)) -le "$maxbelow" ]; do
    _osrc_scr_is_rule "${_SCR_L[$b]}" && break
    b=$((b - 1))
  done
  [ "$b" -ge 1 ] && [ $((_SCR_N - 1 - b)) -le "$maxbelow" ] || return 1
  a=$((b - 1))
  while [ "$a" -ge 0 ] && [ $((b - a)) -le 12 ]; do
    _osrc_scr_is_rule "${_SCR_L[$a]}" && break
    a=$((a - 1))
  done
  [ "$a" -ge 0 ] && [ "$a" -lt $((b - 1)) ] || return 1
  case "${_SCR_L[$((a + 1))]}" in "$glyph"|"$glyph "*) ;; *) return 1 ;; esac
  text=""; dimflag="${_SCR_D[$((a + 1))]}"
  i=$((a + 1))
  while [ "$i" -lt "$b" ]; do
    case "${_SCR_L[$i]}" in
      # agy draws its mode hint ("Auto mode: ... (shift+tab to cycle)", rendered in a muted
      # 38;5;1xx colour the dim probe misses) inside the composer box. It is a placeholder, not
      # a draft; drop the row so an empty composer is not read as unsent text.
      *[Mm]ode:*'(shift+tab to cycle)') ;;
      *) if [ "$i" -eq $((a + 1)) ]; then text="${_SCR_L[$i]#"$glyph"}"; else text="$text ${_SCR_L[$i]}"; fi ;;
    esac
    i=$((i + 1))
  done
  text="$(_osrc_scr_trim "$text")"
  [ "$dimflag" = 1 ] && [ "$b" -eq $((a + 2)) ] && text=""
  # The joined-text catch covers the hint when it wraps onto a second composer row (the
  # fragment rows individually lack the full pattern, but the rejoined text matches).
  case "$text" in 'Try "'*'"'|"Ask Devin to build features, fix bugs, or work on your code"|"Guide Devin while it works"|*[Mm]ode:*'(shift+tab to cycle)') text="" ;; esac
  OSRC_SCR_COMPOSER="$text"; OSRC_SCR_COMPOSER_FOUND=1; OSRC_SCR_HIST_END=$((a - 1))
  return 0
}

# Prose question: the last assistant block (between the last user line and the end of history)
# contains a sentence ending in "?". <assistant-glyph-glob> marks the block start.
_osrc_scr_prose_question() { # <user-line-glob> <hist-end>
  local ugl="$1" end="$2" u i l q="" re='[?]( [A-Z]|[)]?$)'
  u="$(_osrc_scr_last "$ugl" 0 "$end")"
  # Only the tail of the final reply counts (a question ends a turn); a "?" in code, a URL query or
  # a ternary mid-reply is not a question to the orchestrator.
  i=$((u + 1)); [ "$i" -ge $((end - 3)) ] || i=$((end - 3))
  while [ "$i" -le "$end" ]; do
    l="${_SCR_L[$i]}"
    case "$l" in *" for "[0-9]*" · done"*|"⎿"*|*"Tip:"*) i=$((i + 1)); continue ;; esac
    [[ $l =~ $re ]] && q="$l"
    i=$((i + 1))
  done
  [ -n "$q" ] || return 1
  printf '%s' "$q"
}

# ---- per-engine readers --------------------------------------------------------------------------
_osrc_scr_cc() {
  local n=$_SCR_N last3_lo i l tl r1 r2 hdr
  last3_lo=$((n - 3)); [ "$last3_lo" -ge 0 ] || last3_lo=0
  # Modal open (permission / question / trust): its footer is the last line(s); no composer box.
  if _osrc_scr_any "*Esc to cancel*" "$last3_lo" || _osrc_scr_any "*Enter to confirm*" "$last3_lo"; then
    i="$(_osrc_scr_last "*Do you want to *" $((n - 40 > 0 ? n - 40 : 0)))"
    if [ "$i" -ge 0 ] || _osrc_scr_any "*This command requires approval*" $((n - 40 > 0 ? n - 40 : 0)); then
      [ "$i" -ge 0 ] || i="$(_osrc_scr_last "*This command requires approval*")"
      OSRC_SCR_KIND=other
      # The tool header sits right under the rule that opens the dialog.
      hdr="$(_osrc_scr_last "──*" $((n - 40 > 0 ? n - 40 : 0)) "$i")"
      if [ "$hdr" -ge 0 ]; then
        tl="$(_osrc_scr_trim "${_SCR_L[$((hdr + 1))]}")"
        case "$tl" in
          "Bash command") OSRC_SCR_KIND=shell ;;
          "Create file"|"Edit file"|"Write file"|"Overwrite file") OSRC_SCR_KIND=write; OSRC_SCR_PATH="$(_osrc_scr_trim "${_SCR_L[$((hdr + 2))]}")" ;;
          "Read file") OSRC_SCR_KIND=read; OSRC_SCR_PATH="$(_osrc_scr_trim "${_SCR_L[$((hdr + 2))]}")" ;;
        esac
        if [ "$OSRC_SCR_KIND" = shell ]; then
          r1="$(_osrc_scr_last "*╌╌╌╌*" "$hdr" "$i")"; r2=-1
          [ "$r1" -ge 0 ] && r2="$(_osrc_scr_last "*╌╌╌╌*" "$hdr" $((r1 - 1)))"
          if [ "$r2" -ge 0 ]; then
            l=$((r2 + 1)); OSRC_SCR_CMD=""
            while [ "$l" -lt "$r1" ]; do OSRC_SCR_CMD="${OSRC_SCR_CMD:+$OSRC_SCR_CMD
}$(_osrc_scr_trim "${_SCR_L[$l]}")"; l=$((l + 1)); done
          fi
        fi
      fi
      i="$(_osrc_scr_last "*❯ *" "$i")"; [ "$i" -ge 0 ] && OSRC_SCR_SEL="$(_osrc_scr_trim "${_SCR_L[$i]#*❯}")"
      _osrc_scr_set approval "$(_osrc_scr_trim "${_SCR_L[$(_osrc_scr_last "*Do you want to *")]:-permission prompt}") [${OSRC_SCR_KIND}] ${OSRC_SCR_CMD:-$OSRC_SCR_PATH}"
      return 0
    fi
    if _osrc_scr_any "*trust this folder*" $((n - 12 > 0 ? n - 12 : 0)); then
      OSRC_SCR_KIND=trust; _osrc_scr_set approval "folder trust prompt"; return 0
    fi
    if _osrc_scr_any "*Enter to select*" "$last3_lo" || _osrc_scr_any " ☐ *" $((n - 25 > 0 ? n - 25 : 0)); then
      i="$(_osrc_scr_last "*?" $((n - 25 > 0 ? n - 25 : 0)))"
      _osrc_scr_set question "picker: ${_SCR_L[$i]:-question menu}"; return 0
    fi
    OSRC_SCR_KIND=other; _osrc_scr_set approval "modal dialog: ${_SCR_L[$((n - 1))]}"; return 0
  fi
  _osrc_scr_composer_box "❯" 6 || { _osrc_scr_generic; return 0; }
  _osrc_scr_after_composer "❯ *" "⏺ *"
}

# Shared tail for engines with a composer box: decide working / idle / question / composer.
_osrc_scr_after_composer() { # <user-line-glob> <assistant-glob>
  local ugl="$1" end="$OSRC_SCR_HIST_END" lo i l u d q
  lo=$((end - 6)); [ "$lo" -ge 0 ] || lo=0
  i="$end"
  while [ "$i" -ge "$lo" ]; do
    l="${_SCR_L[$i]}"
    case "$l" in
      *"esc to interrupt"*|*"esc twice to interrupt"*) _osrc_scr_set working "$l" "$i"; return 0 ;;
      *" for "[0-9]*"s · done"*|*" for "[0-9]*"m · done"*|*" for "[0-9]*"h "*"done"*) break ;;
      *"… ("*|*"…") case "$l" in "⎿"*|" "*) ;; *) _osrc_scr_set working "$l" "$i"; return 0 ;; esac ;;
    esac
    i=$((i - 1))
  done
  if [ -n "$OSRC_SCR_COMPOSER" ]; then
    _osrc_scr_set composer "composer holds unsent text: $(printf '%s' "$OSRC_SCR_COMPOSER" | cut -c1-80)"; return 0
  fi
  u="$(_osrc_scr_last "$ugl" 0 "$end")"
  d="$(_osrc_scr_last "* for [0-9]*s · done*" 0 "$end")"
  [ "$d" -ge 0 ] || d="$(_osrc_scr_last "* for [0-9]*m · done*" 0 "$end")"
  if [ "$u" -lt 0 ] && [ "$d" -lt 0 ]; then _osrc_scr_set composer "composer ready, no turn yet"; return 0; fi
  if q="$(_osrc_scr_prose_question "$ugl" "$end")"; then _osrc_scr_set question "$q"; return 0; fi
  if [ "$d" -gt "$u" ]; then _osrc_scr_set idle "${_SCR_L[$d]}"; return 0; fi
  _osrc_scr_set idle "composer ready after: $(printf '%s' "${_SCR_L[$u]}" | cut -c1-80)"
}

_osrc_scr_codex() {
  local n=$_SCR_N lo i j l c
  lo=$((n - 30)); [ "$lo" -ge 0 ] || lo=0
  if _osrc_scr_any "*Press enter to confirm or esc to cancel*" $((n - 3 > 0 ? n - 3 : 0)); then
    OSRC_SCR_KIND=other
    i="$(_osrc_scr_last "*Would you like to run the following command?*" "$lo")"
    if [ "$i" -ge 0 ]; then
      OSRC_SCR_KIND=shell; j=$((i + 1)); c=""
      while [ "$j" -lt "$n" ]; do
        l="$(_osrc_scr_trim "${_SCR_L[$j]}")"
        case "$l" in "\$ "*) c="${l#\$ }" ;; "› 1."*|"1. "*) break ;; *) [ -n "$c" ] && c="$c
$l" ;; esac
        j=$((j + 1))
      done
      OSRC_SCR_CMD="$c"
    elif _osrc_scr_any "*Would you like to make the following edits?*" "$lo"; then
      OSRC_SCR_KIND=write
    fi
    i="$(_osrc_scr_last "› *" "$lo")"; [ "$i" -ge 0 ] && OSRC_SCR_SEL="$(_osrc_scr_trim "${_SCR_L[$i]#› }")"
    _osrc_scr_set approval "codex approval [${OSRC_SCR_KIND}] ${OSRC_SCR_CMD}"; return 0
  fi
  if _osrc_scr_any "*enter continue · esc back*" $((n - 3 > 0 ? n - 3 : 0)); then
    OSRC_SCR_KIND=trust; _osrc_scr_set approval "codex folder trust prompt"; return 0
  fi
  # Composer: the last "› " line with only footer rows below it.
  i="$(_osrc_scr_last "› *" $((n - 5 > 0 ? n - 5 : 0)))"
  [ "$i" -ge 0 ] || i="$(_osrc_scr_last "›" $((n - 5 > 0 ? n - 5 : 0)))"
  [ "$i" -ge 0 ] || { _osrc_scr_generic; return 0; }
  c="$(_osrc_scr_trim "${_SCR_L[$i]#›}")"
  [ "${_SCR_D[$i]}" = 1 ] && c=""
  case "$c" in "Ask Codex to do anything"|"Find and fix a bug in @filename"|"Explain this codebase"|"Summarize recent commits"|"Write tests for @filename"|"Improve documentation in @filename"|"Run /review on my current changes"|"Implement {feature}"|"Use /skills to list available skills") c="" ;; esac
  OSRC_SCR_COMPOSER="$c"; OSRC_SCR_COMPOSER_FOUND=1; OSRC_SCR_HIST_END=$((i - 1))
  if [ -n "$c" ]; then _osrc_scr_set composer "composer holds unsent text: $(printf '%s' "$c" | cut -c1-80)"; return 0; fi
  j=$((i - 1))
  while [ "$j" -ge $((i - 6)) ] && [ "$j" -ge 0 ]; do
    case "${_SCR_L[$j]}" in *"esc to interrupt"*|"• Working ("*) _osrc_scr_set working "${_SCR_L[$j]}" "$j"; return 0 ;; esac
    j=$((j - 1))
  done
  local u d q
  u="$(_osrc_scr_last "› *" 0 $((i - 1)))"; d="$(_osrc_scr_last "*Worked for *" 0 $((i - 1)))"
  if [ "$u" -lt 0 ]; then _osrc_scr_set composer "composer ready, no turn yet"; return 0; fi
  if q="$(_osrc_scr_prose_question "› *" $((i - 1)))"; then _osrc_scr_set question "$q"; return 0; fi
  if [ "$d" -gt "$u" ]; then _osrc_scr_set idle "${_SCR_L[$d]}"; return 0; fi
  _osrc_scr_set idle "composer ready after: $(printf '%s' "${_SCR_L[$u]}" | cut -c1-80)"
}

_osrc_scr_devin() {
  local n=$_SCR_N lo i l
  lo=$((n - 25)); [ "$lo" -ge 0 ] || lo=0
  if _osrc_scr_any "*confirm · esc cancel*" $((n - 2 > 0 ? n - 2 : 0)); then
    OSRC_SCR_KIND=other
    # Menu row first, then the command: every row from the `$ ` row up to the menu is joined,
    # so a command Devin wraps onto a second row reaches the classifier whole (multi-line holds).
    local m hdr; m="$(_osrc_scr_last "❭ *" "$lo")"; [ "$m" -ge 0 ] || m=$n
    i="$(_osrc_scr_last "*\$ *" "$lo" $((m - 1)))"
    case "${_SCR_L[$i]:-}" in *"└ \$ "*|"\$ "*|" \$ "*)
      OSRC_SCR_KIND=shell; OSRC_SCR_CMD="$(_osrc_scr_trim "${_SCR_L[$i]#*\$ }")"; i=$((i + 1))
      while [ "$i" -lt "$m" ]; do
        OSRC_SCR_CMD="$OSRC_SCR_CMD
$(_osrc_scr_trim "${_SCR_L[$i]}")"; i=$((i + 1))
      done ;;
    esac
    # Newer Devin modal: '▲ Approval required / This action requires your approval.' then the
    # command (plain or inside a drawn box), then '❭ Allow ← ◼◼◼◼ → Once   Exec(prog)'. The
    # Kind(target) tag on the menu row names the action; the command sits between the header
    # and the menu. Lines are joined with a newline: the classifier holds multi-line commands
    # rather than risk merging two real lines into a safe-looking single line.
    if [ -z "$OSRC_SCR_CMD" ] && [ "$OSRC_SCR_KIND" = other ] && [ "$m" -lt "$n" ]; then
      case "${_SCR_L[$m]}" in
        *"Exec("*) OSRC_SCR_KIND=shell ;;
        *"Write("*|*"Edit("*|*"Create("*|*"Overwrite("*) OSRC_SCR_KIND=write ;;
        *"Read("*) OSRC_SCR_KIND=read ;;
      esac
      if [ "$OSRC_SCR_KIND" != other ]; then
        OSRC_SCR_PATH="$(printf '%s' "${_SCR_L[$m]}" | sed -nE 's/.*[A-Za-z]+\(([^()]*)\).*/\1/p')"
        hdr="$(_osrc_scr_last "*requires your approval*" "$lo" $((m - 1)))"
        [ "$hdr" -ge 0 ] || hdr="$(_osrc_scr_last "*Approval required*" "$lo" $((m - 1)))"
        i=$((hdr + 1))
        while [ "$i" -ge 1 ] && [ "$i" -lt "$m" ]; do
          l="$(printf '%s' "${_SCR_L[$i]}" | sed -E 's/^[[:space:]│┃║|]+//; s/[[:space:]│┃║|]+$//')"
          l="$(_osrc_scr_trim "$l")"
          case "$l" in
            ""|"❭ "*|*"requires your approval"*|*"Bypass mode"*|*"Deny"*) ;;
            "Exec("*")"|"Write("*")"|"Edit("*")"|"Create("*")"|"Read("*")"|"Overwrite("*")") ;;
            ─*|═*|━*|─*|┄*|┈*|"╭"─*|"╰"─*|"┌"─*|"└"─*) ;;
            *) OSRC_SCR_CMD="${OSRC_SCR_CMD:+$OSRC_SCR_CMD
}$l" ;;
          esac
          i=$((i + 1))
        done
      fi
    fi
    i=$m; [ "$i" -lt "$n" ] || i=-1
    if [ "$i" -ge 0 ]; then
      l="$(_osrc_scr_trim "${_SCR_L[$i]#❭}")"; OSRC_SCR_SEL="${l%% *}"
      case "$l" in *"→ Once"*) OSRC_SCR_SCOPE=once ;; *"→ "*) OSRC_SCR_SCOPE="$(printf '%s' "${l#*→ }" | awk '{print $1}')" ;; esac
    fi
    _osrc_scr_set approval "devin approval [${OSRC_SCR_KIND}] ${OSRC_SCR_CMD:-$OSRC_SCR_PATH}"; return 0
  fi
  _osrc_scr_composer_box "❭" 3 || { _osrc_scr_generic; return 0; }
  case "$OSRC_SCR_COMPOSER" in "") ;; esac
  i=$((OSRC_SCR_HIST_END + 2))
  case "${_SCR_L[$i]}" in *"Guide Devin while it works"*) [ -z "$OSRC_SCR_COMPOSER" ] && { _osrc_scr_set working "${_SCR_L[$i]}" "$i"; return 0; } ;; esac
  i="$(_osrc_scr_last "*esc twice to interrupt*" $((OSRC_SCR_HIST_END - 4 > 0 ? OSRC_SCR_HIST_END - 4 : 0)) "$OSRC_SCR_HIST_END")"
  [ "$i" -ge 0 ] && [ -z "$OSRC_SCR_COMPOSER" ] && { _osrc_scr_set working "${_SCR_L[$i]}" "$i"; return 0; }
  _osrc_scr_after_composer "❭ *" " ⏺ *"
}

_osrc_scr_agy() {
  local n=$_SCR_N lo i j l c
  lo=$((n - 30)); [ "$lo" -ge 0 ] || lo=0
  i="$(_osrc_scr_last "> 1. *" "$lo")"; [ "$i" -ge 0 ] || i="$(_osrc_scr_last "> Yes*" "$lo")"
  if [ "$i" -ge 0 ]; then
    OSRC_SCR_SEL="$(_osrc_scr_trim "${_SCR_L[$i]#>}")"; OSRC_SCR_KIND=other
    j="$(_osrc_scr_last "Requesting permission for:*" "$lo" "$i")"
    if [ "$j" -ge 0 ]; then
      OSRC_SCR_KIND=shell; c=""; j=$((j + 1))
      while [ "$j" -lt "$i" ]; do
        l="${_SCR_L[$j]}"
        case "$l" in "Run this command?"*|"Allow "*"?") break ;; esac
        c="${c:+$c
}$(_osrc_scr_trim "$l")"; j=$((j + 1))
      done
      OSRC_SCR_CMD="$c"
    elif _osrc_scr_any "Allow creation of this file?*" "$lo" "$i" || _osrc_scr_any "Allow edit*" "$lo" "$i" || _osrc_scr_any "Allow edits*" "$lo" "$i"; then
      OSRC_SCR_KIND=write
      j="$(_osrc_scr_last "Create file*" "$lo" "$i")"; [ "$j" -ge 0 ] || j="$(_osrc_scr_last "Edit file*" "$lo" "$i")"
      if [ "$j" -ge 0 ]; then
        j=$((j + 1)); _osrc_scr_is_rule "${_SCR_L[$j]}" && j=$((j + 1))
        l="$(_osrc_scr_trim "${_SCR_L[$j]}")"; OSRC_SCR_PATH="${l%%  *}"
      fi
    elif _osrc_scr_any "Do you trust the contents of this project?*" "$lo" "$i"; then
      OSRC_SCR_KIND=trust
    fi
    _osrc_scr_set approval "agy approval [${OSRC_SCR_KIND}] ${OSRC_SCR_CMD:-$OSRC_SCR_PATH}"; return 0
  fi
  _osrc_scr_composer_box ">" 3 || { _osrc_scr_generic; return 0; }
  if [ -z "$OSRC_SCR_COMPOSER" ] && _osrc_scr_any "esc to cancel*" $((n - 1)); then
    _osrc_scr_set working "agy footer: esc to cancel (turn in progress)" $((n - 1)); return 0
  fi
  _osrc_scr_after_composer "> *" "  *"
}

_osrc_scr_gemini() {
  # gemini-cli (keyed). Fixtures: trust menu only (the CLI refused OAuth on this machine on
  # 2026-11-13), so approval wording below is from the CLI's documented prompts and is unproven.
  local n=$_SCR_N lo i
  lo=$((n - 30)); [ "$lo" -ge 0 ] || lo=0
  i="$(_osrc_scr_last "*● 1. *" "$lo")"
  if [ "$i" -ge 0 ]; then
    OSRC_SCR_SEL="$(_osrc_scr_trim "${_SCR_L[$i]#*● }")"; OSRC_SCR_KIND=other
    _osrc_scr_any "*Do you trust the files in this folder?*" "$lo" && OSRC_SCR_KIND=trust
    _osrc_scr_set approval "gemini menu: $OSRC_SCR_SEL"; return 0
  fi
  _osrc_scr_generic
}

# Unknown engine: conservative, live-region-only rules.
_osrc_scr_generic() {
  local n=$_SCR_N lo i l last marker=-1 sib=0
  OSRC_SCR_GENERIC=1
  [ "$n" -gt 0 ] || { _osrc_scr_set unknown "empty pane capture"; return 0; }
  last="${_SCR_L[$((n - 1))]}"
  lo=$((n - 3)); [ "$lo" -ge 0 ] || lo=0
  i="$(_osrc_scr_last "*[[]y/N[]]*" "$lo")"; [ "$i" -ge 0 ] || i="$(_osrc_scr_last "*(y/n)*" "$lo")"
  [ "$i" -ge 0 ] || i="$(_osrc_scr_last "*[[]Y/n[]]*" "$lo")"; [ "$i" -ge 0 ] || i="$(_osrc_scr_last "*[[]y/n[]]*" "$lo")"
  if [ "$i" -ge 0 ]; then OSRC_SCR_KIND=consent; _osrc_scr_set approval "${_SCR_L[$i]}"; return 0; fi
  # A selection menu needs a marker row whose label looks like an answer, plus sibling option rows
  # right under it; a reply that merely ENDS in a numbered list has no marker and is not a menu.
  lo=$((n - 10)); [ "$lo" -ge 0 ] || lo=0
  i="$lo"
  while [ "$i" -lt "$n" ]; do
    l="$(_osrc_scr_trim "${_SCR_L[$i]}")"
    case "$l" in
      "❯ "*|"› "*|"❭ "*|"● "*|"> "*) case "${l#* }" in [0-9]". Yes"*|[0-9]". Allow"*|[0-9]". No"*|"Yes"*|"Allow"*|"Approve"*|"Proceed"*) marker=$i ;; esac ;;
    esac
    i=$((i + 1))
  done
  if [ "$marker" -ge 0 ]; then
    i=$((marker + 1)); while [ "$i" -lt "$n" ]; do case "${_SCR_L[$i]}" in " "*) sib=$((sib + 1)) ;; esac; i=$((i + 1)); done
    if [ "$sib" -ge 1 ] || _osrc_scr_any "*esc*" $((n - 2 > 0 ? n - 2 : 0)); then
      OSRC_SCR_KIND=other; OSRC_SCR_SEL="$(_osrc_scr_trim "${_SCR_L[$marker]#* }")"
      _osrc_scr_set approval "menu: ${_SCR_L[$marker]}"; return 0
    fi
  fi
  i="$(_osrc_scr_last "*Press enter to confirm or esc to cancel*" $((n - 2 > 0 ? n - 2 : 0)))"
  if [ "$i" -ge 0 ]; then OSRC_SCR_KIND=other; _osrc_scr_set approval "${_SCR_L[$i]}"; return 0; fi
  # Busy rows: ONE structural matcher over the live tail (interrupt hints, "Working (", a spinner-led
  # status row with a verb and "…"/"..."/"("), never bare prose words, and only BELOW the last
  # turn-completion summary (a `· done`/`Worked for` row makes everything above it scrollback). The
  # same row means the same thing at any height; only a bare prompt on the last row outranks a busy
  # row that sits above the last three rows. This is the stall-storm shape: a healthy agent in an
  # unrecognized layout read `unknown`, its hash froze, and the lane woke as stalled.
  local b=-1 t
  lo=$((n - 12)); [ "$lo" -ge 0 ] || lo=0
  i=$((n - 1))
  while [ "$i" -ge "$lo" ]; do
    t="$(_osrc_scr_trim "${_SCR_L[$i]}")"
    case "$t" in *"· done"*|*"Worked for"*) break ;; esac
    case "$t" in
      *"esc to interrupt"*|*"esc twice to interrupt"*|*"ctrl+c to interrupt"*|"Working ("*) b=$i ;;
      # a braille spinner never leads prose: glyph + a word is enough
      "⠋"*|"⠙"*|"⠹"*|"⠸"*|"⠼"*|"⠴"*|"⠦"*|"⠧"*|"⠇"*|"⠏"*|"⣻"*|"⣽"*|"⣟"*|"⡿"*|"⢿"*|"⣷"*|"⣯"*|"⠿"*|"⢰"*)
        case "$t" in *[A-Za-z]*) b=$i ;; esac ;;
      # these also lead bullets and done summaries: they need a "…"/"..."/"(" status shape too
      "✢"*|"✶"*|"✳"*|"✻"*|"✽"*|"●"*|"◐"*|"◓"*|"◑"*|"◒"*)
        case "$t" in *[A-Za-z]*) case "$t" in *…*|*"..."*|*"("*) b=$i ;; esac ;; esac ;;
    esac
    [ "$b" -ge 0 ] && break
    i=$((i - 1))
  done
  if [ "$b" -ge 0 ] && [ "$b" -ge $((n - 3)) ]; then _osrc_scr_set working "${_SCR_L[$b]}" "$b"; return 0; fi
  case "$last" in *'$'|*'$ '|*'%'|*'% '|*'>'|*'> '|*'❯'|*'❯ '|*'#') _osrc_scr_set idle "$last"; return 0 ;; esac
  if [ "$b" -ge 0 ]; then _osrc_scr_set working "${_SCR_L[$b]}" "$b"; return 0; fi
  _osrc_scr_set unknown "no recognized signal in tail"
}

# ---- rate limits / quota -------------------------------------------------------------------------
# A lane parked on a provider limit cannot take a turn until a clock fires; whatever the composer
# looks like the honest state is `limit` (the incident: hundreds of "screen unrecognised" stalls
# buried the lanes actually parked on quota). A row counts only when it is a provider REFUSAL:
#   - it starts like a banner (⚠ ⛔ ⎿ ■ ✖ ✗ × ⨯ !, Error/FATAL/WARN, or the refusal itself), never
#     like prose (•, ⏺, ✦ ...), AND
#   - it carries quota-refusal wording (limit reached/exceeded/hit, rate limited, quota exhausted,
#     429, too many requests, insufficient credits...). "Error: permission denied" has none.
# An indented row whose block opens with a tool call (⏺ Bash(, • Ran, ✓ cmd) is that tool's own
# output. The scan runs newest-first over the history region and stops at the latest turn boundary
# (a user prompt row or a `Worked for`/`· done` summary): a refusal above it is an older turn.
_OSRC_SCR_LIMIT_HEAD="^(⚠|⛔|⎿|■|✖|✗|×|⨯|!|error|fatal|warn|api error|you'?ve hit|you have hit|claude usage limit|usage limit|rate limit|quota|429|too many requests|insufficient|your credit balance|individual quota|plan usage limit)"
_OSRC_SCR_LIMIT_WORDS="(usage|rate|plan|weekly|daily|session|hourly|token|request) limit (reached|exceeded|hit)|hit (your|the) ([a-z-]+ )?limit|rate[- ]limited|quota (reached|exceeded|exhausted)|exceeded your (current )?(quota|usage|plan)|(^|[^0-9])429([^0-9]|$)|too many requests|insufficient (credits|funds|balance|quota)|credit balance is too low|out of credits|resource.exhausted"
_OSRC_SCR_TOOL_HDR='^(⏺ [A-Za-z_][A-Za-z0-9_.:-]*[(]|• (Ran|Running|Called|Calling|Explored) |✓ |✗ )'
_osrc_scr_limit() { # -> rc0 + OSRC_SCR_LIMIT_DETAIL/_AT/_SECS when the live region's newest turn is a refusal
  local end lo i j t tl bi="" phrase="" secs="" clk
  if [ "$OSRC_SCR_COMPOSER_FOUND" = 1 ]; then end="$OSRC_SCR_HIST_END"; else end=$((_SCR_N - 1)); fi
  [ "$end" -ge 0 ] || return 1   # a recognized composer with empty history has nothing to read
  lo=$((end - 13)); [ "$lo" -ge 0 ] || lo=0
  i="$end"
  while [ "$i" -ge "$lo" ]; do
    t="$(_osrc_scr_trim "${_SCR_L[$i]}")"
    case "$t" in
      "❯ "?*|"› "?*|"> "?*|*"Worked for "[0-9]*|*" for "[0-9]*"· done"*|*" for "[0-9]*" · done"*) return 1 ;;
    esac
    tl="$(printf '%s' "$t" | tr 'A-Z' 'a-z')"
    if [[ $tl =~ $_OSRC_SCR_LIMIT_HEAD ]] && [[ $tl =~ $_OSRC_SCR_LIMIT_WORDS ]]; then
      bi="$i"
      case "${_SCR_L[$i]}" in " "*|"⎿"*)   # indented: walk up to the row that opens its block
        j=$((i - 1))
        while [ "$j" -ge 0 ]; do
          t="$(_osrc_scr_trim "${_SCR_L[$j]}")"
          if [[ $t =~ $_OSRC_SCR_TOOL_HDR ]]; then bi=""; break; fi
          case "$t" in "⏺"*|"•"*|"✓"*|"✗"*|"❯"*|"›"*|"❭"*|">"*|"✻"*|"✦"*) break ;; esac
          case "${_SCR_L[$j]}" in " "*|"⎿"*|"└"*|"│"*) j=$((j - 1)) ;; *) break ;; esac
        done
        t="$(_osrc_scr_trim "${_SCR_L[$i]}")" ;;
      esac
      [ -n "$bi" ] && break
    fi
    i=$((i - 1))
  done
  [ -n "$bi" ] || return 1
  # The reset the banner states, kept whole ("Resets in 1h13m1s", "Try again at 22:28",
  # "resets at 09:00 UTC", "reset at 3pm"): zone included, only trailing punctuation dropped.
  clk='[0-9]{1,2}:[0-9]{2}([[:space:]]*[ap]m)?([[:space:]]*(utc|gmt))?|[0-9]{1,2}[[:space:]]*[ap]m([[:space:]]*(utc|gmt))?'
  phrase="$(printf '%s\n' "$t" "${_SCR_L[$((bi + 1))]:-}" | LC_ALL=C grep -oiE \
    "(resets?|refreshes|retry(ing)?|back ?off|try again)[[:space:]]+(in[[:space:]]+([0-9]+[[:space:]]*[a-z]+([[:space:]]*[0-9]+[[:space:]]*[a-z]+)*)|(at[[:space:]]+)?($clk))" | head -1)"
  phrase="$(printf '%s' "$phrase" | sed -E 's/[[:space:][:punct:]]+$//')"
  if [ -n "$phrase" ] && type _lane_limit_reset_secs >/dev/null 2>&1; then
    # normalize the verb only: "Try again at 22:28" -> "resets at 22:28", "Resets 22:28" -> "resets at 22:28"
    secs="$(_lane_limit_reset_secs "$(printf '%s' "$phrase" | tr 'A-Z' 'a-z' | sed -E 's/^(refreshes|retrying|retry|back ?off|try again|resets?)[[:space:]]+(in|at)?[[:space:]]*/resets \2 /; s/^resets  /resets at /')" 2>/dev/null)"
    case "$secs" in ''|*[!0-9]*) secs="" ;; esac
  fi
  OSRC_SCR_LIMIT_AT="$bi"
  case "$phrase" in
    *[Ii]n" "[0-9]*) OSRC_SCR_LIMIT_SECS="$secs" ;;   # relative: its start is unknown here, no epoch
    *) [ -n "$secs" ] && phrase="$phrase (epoch $(( $(date +%s) + secs )))" ;;
  esac
  OSRC_SCR_LIMIT_DETAIL="$(printf '%s' "$t" | cut -c1-100)${phrase:+ · reset: $phrase}"
  return 0
}

# 0 when <snippet> (whitespace-collapsed) appears in the history region above the composer.
_osrc_scr_history_has() { # <snippet>
  local want hist i
  want="$(printf '%s' "$1" | tr -s ' \t\n' '   ')"; want="$(_osrc_scr_trim "$want")"
  [ -n "$want" ] || return 1
  i=0; hist=""
  while [ "$i" -le "$OSRC_SCR_HIST_END" ] && [ "$i" -lt "$_SCR_N" ]; do hist="$hist ${_SCR_L[$i]}"; i=$((i + 1)); done
  hist="$(printf '%s' "$hist" | tr -s ' ' ' ')"
  case "$hist" in *"$want"*) return 0 ;; esac
  return 1
}

# How many times <snippet> appears in the history region (wrapped rows joined). Send verification
# compares this against a count taken before typing, so an old identical line is not a receipt.
_osrc_scr_history_count() { # <snippet>
  local want hist i n=0
  want="$(printf '%s' "$1" | tr -s ' \t\n' '   ')"; want="$(_osrc_scr_trim "$want")"
  [ -n "$want" ] || { printf 0; return 0; }
  i=0; hist=""
  while [ "$i" -le "$OSRC_SCR_HIST_END" ] && [ "$i" -lt "$_SCR_N" ]; do hist="$hist ${_SCR_L[$i]}"; i=$((i + 1)); done
  hist="$(printf '%s' "$hist" | tr -s ' ' ' ')"
  while :; do case "$hist" in *"$want"*) hist="${hist#*"$want"}"; n=$((n + 1)) ;; *) break ;; esac; done
  printf '%s' "$n"
}

# ---- public API ----------------------------------------------------------------------------------
# Analyze text (ANSI allowed) on stdin. Sets the OSRC_SCR_* globals. [engine] is a provider name or
# alias; empty = guess from the screen.
_osrc_screen_analyze_text() { # [engine]
  local LC_ALL; LC_ALL="$(_osrc_utf8_locale)"; export LC_ALL
  _osrc_scr_reset
  _osrc_scr_load
  [ "$_SCR_N" -gt 0 ] || { _osrc_scr_set unknown "empty pane capture"; return 0; }
  OSRC_SCR_ENGINE="$(_osrc_scr_engine_norm "${1:-}")"
  [ -n "$OSRC_SCR_ENGINE" ] && [ "$OSRC_SCR_ENGINE" != generic ] || OSRC_SCR_ENGINE="$(_osrc_scr_engine_guess)"
  case "$OSRC_SCR_ENGINE" in
    cc) _osrc_scr_cc ;;
    codex) _osrc_scr_codex ;;
    devin) _osrc_scr_devin ;;
    agy) _osrc_scr_agy ;;
    gemini) _osrc_scr_gemini ;;
    *) _osrc_scr_generic ;;
  esac
  # A refusal outranks every quiet state (the composer can look ready while the provider is parked)
  # and an OLDER busy row (a spinner printed before the refusal is not proof of life). A live
  # approval/question keeps precedence, and so does a busy row newer than the refusal.
  case "$OSRC_SCR_STATE" in
    idle|composer|unknown)
      if _osrc_scr_limit; then _osrc_scr_set limit "$OSRC_SCR_LIMIT_DETAIL" "$OSRC_SCR_LIMIT_AT"; fi ;;
    working)
      if _osrc_scr_limit && [ "$OSRC_SCR_LIMIT_AT" -gt "$OSRC_SCR_AT" ]; then
        _osrc_scr_set limit "$OSRC_SCR_LIMIT_DETAIL" "$OSRC_SCR_LIMIT_AT"
      fi ;;
  esac
  return 0
}

# Engine for a managed pane: the session registry's provider (gemini lane -> agy when that is the
# vehicle the launch used), else a guess from the screen.
_osrc_screen_engine_of() { # <pane>
  local prov="" sid="${1%%:*}"
  if type _managed_provider >/dev/null 2>&1; then prov="$(_managed_provider "$sid" 2>/dev/null)"; fi
  case "$prov" in gemini|gm) prov="${OSRC_GEMINI_VEHICLE:-}"; [ -n "$prov" ] || { command -v agy >/dev/null 2>&1 && prov=agy || prov=gemini; } ;; esac
  printf '%s' "$prov"
}

_osrc_screen_capture() { # <pane> -> raw ANSI capture; rc 2 when the pane cannot be read
  local cap
  cap="$(tmux capture-pane -e -p -t "$1" 2>/dev/null)" || return 2
  printf '%s\n' "$cap"
}

# Pane liveness: tmux keeps a dead pane's last frame on screen (remain-on-exit), so a successful
# capture can still describe a corpse that will never change again. -> rc 0 proven dead | rc 1
# proven alive | rc 2 cannot tell (no tmux, an old tmux without pane_dead, an odd answer). Only a
# positive "1" counts as dead; everything else falls through to the normal screen verdict.
_osrc_screen_pane_dead() { # <pane>
  local d
  d="$(tmux display-message -p -t "$1" '#{pane_dead}' 2>/dev/null)" || return 2
  case "$(_osrc_scr_trim "$d")" in 1) return 0 ;; 0) return 1 ;; *) return 2 ;; esac
}

osrc_screen_state() { # <pane> [engine]
  local LC_ALL; LC_ALL="$(_osrc_utf8_locale)"; export LC_ALL
  local pane="$1" eng="${2:-}" cap
  [ -n "$eng" ] || eng="$(_osrc_screen_engine_of "$pane")"
  if ! cap="$(_osrc_screen_capture "$pane")"; then printf 'unknown\npane capture failed: %s\n' "$pane"; return 0; fi
  _osrc_screen_analyze_text "$eng" <<<"$cap"
  if _osrc_screen_pane_dead "$pane"; then
    printf 'dead\npane process dead; last frame before exit: %s\n' "$OSRC_SCR_EVIDENCE"
  else
    printf '%s\n%s\n' "$OSRC_SCR_STATE" "$OSRC_SCR_EVIDENCE"
  fi
}

# ---- alert states (one report per change, restart-safe) ------------------------------------------
# osrc_screen_alert <pane> [engine] -> one line: <state> TAB <new|seen> TAB <evidence>
# The screen states above, re-read for alerting, with the pane checked for life FIRST:
#   failed   the pane is gone, or its process exited (a remain-on-exit corpse whose last frame may
#            still read `working`). Terminal: reported once until the pane comes back.
#   stalled  known-stalled: a recognized busy frame unchanged for OSRC_SCREEN_STALL_SECS (900), or an
#            unknown frame quiet for OSRC_SCREEN_UNKNOWN_SECS (600) AND the pane's process tree used
#            under OSRC_SCREEN_UNKNOWN_CPU (2) CPU seconds over that window. When CPU cannot be read
#            (no ps -o), twice the quiet window stands in for that evidence.
#   unknown  unrecognized and not proven stopped: never an alert on its own.
#   limit    a provider refusal; a relative reset ("try again in 2h") is anchored to the first time
#            that exact banner was seen, so a frozen countdown keeps one deadline.
#   anything else is the screen state (working, idle, approval, ...).
# <new> means this state differs from the last one recorded for the pane. The record lives in
# $OSRC_HOME/screen-alerts/<pane>, so a restarted watcher does not report the same state again, and
# no state is re-announced on a timer: a reminder is the caller's choice, not a new event.
_osrc_scr_cpu() { # <pane> -> integer CPU seconds of the pane's process tree; empty when unknown
  local pid; pid="$(tmux display-message -p -t "$1" '#{pane_pid}' 2>/dev/null)"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  ps -A -o pid= -o ppid= -o time= 2>/dev/null | awk -v root="$pid" '
    { t = $3; d = 0; if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
      n = split(t, p, ":"); s = 0; for (k = 1; k <= n; k++) s = s * 60 + p[k]
      sec[$1] = s + d * 86400; par[$1] = $2 }
    END { if (!(root in sec)) exit
      tree[root] = 1; grew = 1
      while (grew) { grew = 0; for (q in par) if (!(q in tree) && (par[q] in tree)) { tree[q] = 1; grew = 1 } }
      for (q in tree) tot += sec[q]; printf "%d", tot }'
}
_osrc_scr_num() { case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
osrc_screen_alert() { # <pane> [engine]
  local LC_ALL; LC_ALL="$(_osrc_utf8_locale)"; export LC_ALL
  local pane="$1" eng="${2:-}" now dir f cap st ev h q pd=0 cpu new win
  local last=- hash=- chg=0 cpu0=- cpu0t=0 lh=- lt=0
  now="$(_osrc_scr_num "${OSRC_NOW:-}" "$(date +%s)")"
  dir="${OSRC_HOME:-$HOME/.outsourcerer}/screen-alerts"; mkdir -p "$dir" 2>/dev/null
  f="$dir/$(printf '%s' "$pane" | tr -c 'A-Za-z0-9._-' '_')"
  [ -f "$f" ] && read -r last hash chg cpu0 cpu0t lh lt < "$f" 2>/dev/null
  chg="$(_osrc_scr_num "$chg" "$now")"; cpu0t="$(_osrc_scr_num "$cpu0t" "$now")"; lt="$(_osrc_scr_num "$lt" "$now")"
  if ! cap="$(_osrc_screen_capture "$pane")"; then
    st=failed; ev="pane gone: tmux cannot read $pane"
  elif _osrc_screen_pane_dead "$pane" || pd=$?; [ "$pd" = 0 ]; then
    [ -n "$eng" ] || eng="$(_osrc_screen_engine_of "$pane")"
    _osrc_screen_analyze_text "$eng" <<<"$cap"
    st=failed; ev="pane process exited; last frame read: $OSRC_SCR_STATE: $OSRC_SCR_EVIDENCE"
  else
    [ -n "$eng" ] || eng="$(_osrc_screen_engine_of "$pane")"
    _osrc_screen_analyze_text "$eng" <<<"$cap"
    st="$OSRC_SCR_STATE"; ev="$OSRC_SCR_EVIDENCE"
    h="$(printf '%s' "$cap" | cksum | awk '{print $1}')"
    [ "$h" = "$hash" ] || { hash="$h"; chg="$now"; cpu0=-; }
    q=$((now - chg))
    case "$st" in
      working)
        [ "$q" -ge "$(_osrc_scr_num "${OSRC_SCREEN_STALL_SECS:-}" 900)" ] && { st=stalled; ev="busy screen unchanged for ${q}s: $ev"; } ;;
      unknown)
        win="$(_osrc_scr_num "${OSRC_SCREEN_UNKNOWN_SECS:-}" 600)"
        [ "$cpu0" != - ] || { cpu0="$(_osrc_scr_cpu "$pane")"; cpu0="${cpu0:-?}"; cpu0t="$now"; }
        cpu=""; [ "$cpu0" = "?" ] || cpu="$(_osrc_scr_cpu "$pane")"
        if [ -n "$cpu" ] && [ "$q" -ge "$win" ] && [ $((now - cpu0t)) -ge "$win" ] \
           && [ $((cpu - cpu0)) -lt "$(_osrc_scr_num "${OSRC_SCREEN_UNKNOWN_CPU:-}" 2)" ]; then
          st=stalled; ev="unrecognized screen unchanged for ${q}s and its processes used $((cpu - cpu0))s CPU: $ev"
        elif [ -z "$cpu" ] && [ "$q" -ge $((win * 2)) ]; then
          st=stalled; ev="unrecognized screen unchanged for ${q}s (process CPU unreadable): $ev"
        else ev="unrecognized, quiet ${q}s, not proven stopped: $ev"; fi ;;
      limit)
        h="$(printf '%s' "$OSRC_SCR_LIMIT_DETAIL" | cksum | awk '{print $1}')"
        [ "$h" = "$lh" ] || { lh="$h"; lt="$now"; }
        [ -n "$OSRC_SCR_LIMIT_SECS" ] && ev="$ev (epoch $((lt + OSRC_SCR_LIMIT_SECS)), counted from first sight)" ;;
    esac
  fi
  [ "$st" = limit ] || lh=-
  if [ "$st" = "$last" ]; then new=seen; else new=new; fi
  printf '%s %s %s %s %s %s %s\n' "$st" "$hash" "$chg" "$cpu0" "$cpu0t" "$lh" "$lt" > "$f.$$" 2>/dev/null && mv -f "$f.$$" "$f" 2>/dev/null
  printf '%s\t%s\t%s\n' "$st" "$new" "$(printf '%s' "$ev" | tr '\t\n' '  ')"
}

osrc_screen_report() { # <pane> [engine] -> KEY=value lines (values are single-line; CMD newlines -> ' ; ')
  local LC_ALL; LC_ALL="$(_osrc_utf8_locale)"; export LC_ALL
  local pane="$1" eng="${2:-}" cap
  [ -n "$eng" ] || eng="$(_osrc_screen_engine_of "$pane")"
  if ! cap="$(_osrc_screen_capture "$pane")"; then printf 'STATE=unknown\nEVIDENCE=pane capture failed\n'; return 0; fi
  _osrc_screen_analyze_text "$eng" <<<"$cap"
  OSRC_SCR_PANE_DEAD=0; _osrc_screen_pane_dead "$pane" || OSRC_SCR_PANE_DEAD=$?   # set -e safe
  case "$OSRC_SCR_PANE_DEAD" in 0) OSRC_SCR_PANE_DEAD=1; OSRC_SCR_STATE=dead
    OSRC_SCR_EVIDENCE="pane process dead; last frame before exit: $OSRC_SCR_EVIDENCE" ;;
    1) OSRC_SCR_PANE_DEAD=0 ;; *) OSRC_SCR_PANE_DEAD=? ;;
  esac
  _osrc_screen_report_print
}
_osrc_screen_report_print() {
  printf 'STATE=%s\nENGINE=%s\nEVIDENCE=%s\nKIND=%s\nCMD=%s\nPATH=%s\nSEL=%s\nSCOPE=%s\nCOMPOSER=%s\nPANE_DEAD=%s\n' \
    "$OSRC_SCR_STATE" "$OSRC_SCR_ENGINE" "$OSRC_SCR_EVIDENCE" "$OSRC_SCR_KIND" \
    "$(printf '%s' "$OSRC_SCR_CMD" | awk 'NR>1{printf " ; "} {printf "%s", $0}')" "$OSRC_SCR_PATH" "$OSRC_SCR_SEL" "$OSRC_SCR_SCOPE" "$OSRC_SCR_COMPOSER" "${OSRC_SCR_PANE_DEAD:-?}"
}

# ---- legacy JSON classifier (session read --state, control receipts) -----------------------------
# Kept as the JSON face of the same reader so there is ONE set of rules. Mapping:
#   approval|question -> waiting-approval, working -> working, idle|composer -> idle, else unknown.
#   `limit` deliberately lands on unknown here: the legacy vocabulary has no "blocked on quota"
#   value, and reporting `idle` would invite a send into a lane that cannot take a turn.
_pane_state_json() { # <state> <evidence>  -> {"state","evidence"}
  local state="$1" evidence="$2"
  if have jq; then
    jq -cn --arg s "$state" --arg e "$evidence" '{state:$s,evidence:$e}'
    return 0
  fi
  evidence="$(printf '%s' "$evidence" | LC_ALL=C awk '
    BEGIN { for (i=1; i<32; i++) ctrl[sprintf("%c", i)]=sprintf("\\u%04X", i); ctrl["\t"]="\\t"; ctrl["\r"]="\\r" }
    { if (NR>1) printf "\\n"; for (i=1; i<=length($0); i++) { c=substr($0,i,1); if (c=="\\") printf "\\\\"; else if (c=="\"") printf "\\\""; else if (c in ctrl) printf "%s", ctrl[c]; else printf "%s", c } }
  ')"
  state="$(printf '%s' "$state" | LC_ALL=C awk '
    BEGIN { for (i=1; i<32; i++) ctrl[sprintf("%c", i)]=sprintf("\\u%04X", i); ctrl["\t"]="\\t"; ctrl["\r"]="\\r" }
    { if (NR>1) printf "\\n"; for (i=1; i<=length($0); i++) { c=substr($0,i,1); if (c=="\\") printf "\\\\"; else if (c=="\"") printf "\\\""; else if (c in ctrl) printf "%s", ctrl[c]; else printf "%s", c } }
  ')"
  printf '{"state":"%s","evidence":"%s"}' "$state" "$evidence"
}

_pane_state_classify() { # stdin text [engine] -> {"state","evidence"}
  local text tail_region st
  text="$(cat)"
  # Only the latest interaction region counts: a prompt deep in scrollback is history.
  tail_region="$(printf '%s\n' "$text" | grep -v '^[[:space:]]*$' | tail -n "${OSRC_PANE_STATE_TAIL:-30}")"
  [ -n "$tail_region" ] || { _pane_state_json unknown "empty pane capture"; return 0; }
  _osrc_screen_analyze_text "${1:-}" <<<"$tail_region"
  case "$OSRC_SCR_STATE" in
    approval|question) st=waiting-approval ;;
    working) st=working ;;
    idle|composer) st=idle ;;
    *) st=unknown ;;
  esac
  _pane_state_json "$st" "$OSRC_SCR_EVIDENCE"
}
