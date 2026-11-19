# shellcheck shell=bash
# lib/menu.sh: interactive menu detection + answering for `session send` / `session answer`.
# Moved out of outsourcerer.sh by L3 (2026-11-13). The detector is now GATED by lib/screen.sh: when
# the engine reader recognises its own layout (Claude Code, Codex, Devin, agy, Gemini), only an open
# approval/question counts as a menu. That kills the two false positives that blocked `session send`
# (FINDINGS class 6, Fable E8): Claude Code's composer + status bar read as a cursor list, and a reply
# that ends in a numbered list read as a numbered menu. Unknown engines keep the legacy heuristics.

# ---- options straight from the engine reader (L3 round 2, review finding 7) ---------------------
# On a recognised engine the option rows are read from the live screen rows (_SCR_L): the cursor row
# (❯ › > ● ❭) fixes the label column, and the menu is every row at that column, numbered or not.
# Row 1 is listed even when the cursor sits on it (the old numbered regex needed a leading digit).
_osrc_menu_row() { # <row>: sets _MR_SEL (1 = cursor row) _MR_COL (label column) _MR_NUM _MR_LAB
  local r="$1" pre p2
  case "$r" in *"│"*) case "${r%%│*}" in *[!\ ]*) ;; *) r="${r#*│}" ;; esac ;; esac
  pre="${r%%[! ]*}"; r="${r#"$pre"}"; _MR_SEL=0
  case "$r" in "❯ "*|"› "*|"> "*|"● "*|"❭ "*)
    _MR_SEL=1; pre="$pre${r%% *} "; r="${r#* }"; p2="${r%%[! ]*}"; pre="$pre$p2"; r="${r#"$p2"}" ;;
  esac
  _MR_COL=${#pre}; _MR_NUM=""
  case "$r" in [0-9]". "*|[0-9][0-9]". "*|[0-9]") "*|[0-9][0-9]") "*) _MR_NUM="${r%%[.)]*}"; r="${r#*[.)] }" ;; esac
  r="$(_osrc_scr_trim "$r")"; r="${r%│}"
  _MR_LAB="$(printf '%s' "$(_osrc_scr_trim "$r")" | tr -s ' ')"
}

_osrc_menu_from_screen() { # uses _SCR_L from the last analyse; prints MENU select + SEL/OPT rows, rc 1 if none
  local n=$_SCR_N lo s i col numd dir pos=0 rows="" out=""
  lo=$((n - 30)); [ "$lo" -ge 0 ] || lo=0
  s=-1; i=$((n - 1))
  while [ "$i" -ge "$lo" ]; do
    _osrc_menu_row "${_SCR_L[$i]}"
    [ "$_MR_SEL" = 1 ] && [ -n "$_MR_LAB" ] && { s=$i; break; }
    i=$((i - 1))
  done
  [ "$s" -ge 0 ] || return 1
  col=$_MR_COL; numd=0; [ -n "$_MR_NUM" ] && numd=1
  rows="$s"
  for dir in -1 1; do
    i=$((s + dir))
    while [ "$i" -ge "$lo" ] && [ "$i" -lt "$n" ]; do
      if _osrc_scr_is_rule "${_SCR_L[$i]}"; then [ "$numd" = 1 ] || break; i=$((i + dir)); continue; fi
      _osrc_menu_row "${_SCR_L[$i]}"
      local isnum=0; [ -n "$_MR_NUM" ] && isnum=1
      if [ "$_MR_COL" = "$col" ] && [ -n "$_MR_LAB" ] && [ "$isnum" = "$numd" ]; then
        if [ "$dir" = -1 ]; then rows="$i $rows"; else rows="$rows $i"; fi
      elif [ "$numd" = 1 ] && [ -z "$_MR_NUM" ] && [ "$_MR_COL" -gt "$col" ]; then :   # wrapped label / description
      else break
      fi
      i=$((i + dir))
    done
  done
  for i in $rows; do
    _osrc_menu_row "${_SCR_L[$i]}"; pos=$((pos + 1))
    out="$out$([ "$_MR_SEL" = 1 ] && printf SEL || printf OPT) ${_MR_NUM:-$pos} $_MR_LAB
"
  done
  printf 'MENU select\n%s' "$out"
}

# A row that widens the delegate's permissions is never picked by a label match, only by its index.
_osrc_menu_risky() { # <label>
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *"don't ask again"*|*"dont ask again"*|*always*|*"auto mode"*|*bypass*|*"accept edits"*|*auto-approve*|*persist*|*"trust parent"*) return 0 ;;
  esac
  return 1
}

# Resolve a selector against a report's SEL/OPT rows. Prints the option index. A number must be an
# offered index. A label must match exactly one row (case-insensitive substring); two or more is
# refused as ambiguous, and a risky row is refused by label.
_osrc_menu_resolve() { # <report> <selector>
  local rep="$1" sel="$2" line idx lab hits=0 hit="" hitlab="" names=""
  [ -n "$sel" ] || { echo "empty selector" >&2; return 1; }
  # y/yes and n/no pick the row that STARTS with Yes/No, wherever it sits: Claude's folder-trust menu
  # lists "No, exit" first, so "answer 1" meant to trust the folder and exited instead.
  case "$sel" in y|Y|yes|Yes|YES) sel="__yes__" ;; n|N|no|No|NO) sel="__no__" ;; esac
  if [ "$sel" = "__yes__" ] || [ "$sel" = "__no__" ]; then
    local want; [ "$sel" = "__yes__" ] && want="yes" || want="no"
    while IFS= read -r line; do
      case "$line" in "SEL "*|"OPT "*) ;; *) continue ;; esac
      idx="${line#* }"; lab="${idx#* }"; idx="${idx%% *}"
      case "$(printf '%s' "$lab" | tr '[:upper:]' '[:lower:]')" in "$want"*) ;; *) continue ;; esac
      _osrc_menu_risky "$lab" && continue   # "yes" never means "yes, and don't ask again"
      hits=$((hits + 1)); hit="$idx"
    done <<<"$rep"
    [ "$hits" -eq 1 ] || { echo "no single option starts with '$want'; answer with the option index instead" >&2; return 1; }
    printf '%s' "$hit"; return 0
  fi
  case "$sel" in *[!0-9]*) ;; *)
    printf '%s\n' "$rep" | grep -qE "^(SEL|OPT) $sel " || { echo "index $sel is not one of the offered options" >&2; return 1; }
    printf '%s' "$sel"; return 0 ;;
  esac
  while IFS= read -r line; do
    case "$line" in "SEL "*|"OPT "*) ;; *) continue ;; esac
    idx="${line#* }"; lab="${idx#* }"; idx="${idx%% *}"
    if printf '%s\n' "$lab" | grep -F -i -q -- "$sel"; then
      hits=$((hits + 1)); hit="$idx"; hitlab="$lab"; names="$names [$idx] $lab;"
    fi
  done <<<"$rep"
  [ "$hits" -ge 1 ] || { echo "no option matches '$sel'" >&2; return 1; }
  [ "$hits" -eq 1 ] || { echo "'$sel' is ambiguous, it matches:$names answer with the option index instead" >&2; return 1; }
  if _osrc_menu_risky "$hitlab"; then
    echo "refusing to pick '$hitlab' by label: it widens the delegate's permissions. If that is really meant, answer with its index: $hit" >&2; return 1
  fi
  printf '%s' "$hit"
}

_osrc_menu_how() { # <kind>: the answer hint printed under a menu report
  case "$1" in
    consent) echo "answer with:  $0 session answer y   |   $0 session answer n" ;;
    *) echo "answer with:  $0 session answer yes|no   or   $0 session answer <index>   (yes/no pick the row starting with Yes/No; an index is the OPT/SEL number above; a label works only when it matches exactly one row, and never picks an always/don't-ask-again/auto-mode/bypass row)" ;;
  esac
}

_osrc_menu_pos() { # <report> <index>: 1-based position of that option among the SEL/OPT rows
  printf '%s\n' "$1" | grep -E '^(SEL|OPT) ' | awk -v k="$2" '$2==k {print NR; exit}'
}

# ---- interactive menu / choice-prompt detection (Bug A) -----------------------------------------
# When a delegate is showing an interactive choice menu, `session send` refused with "nothing was
# typed", leaving NO way to answer the menu through the session API. `session answer` and the helpful
# send-refusal below need a detector that reads the pane tail and reports the visible options. Prints
# a small line-based report:
#   MENU none
#   MENU consent
#   PROMPT <the consent prompt line>
#   MENU numbered
#   OPT <idx> <label>
#   ...
#   MENU select            <- recognised engine: rows read by lib/screen.sh, SEL/OPT by option index
#   MENU cursor
#   SEL <pos> <label>      <- the row currently marked with ❯
#   OPT <pos> <label>
#   ...
# Consent ([y/N], (y/n)) is checked first (single-key answer). Numbered options ("N. label" / "N)
# label") and ❯-marked cursor lists are matched on the tail region only, so a menu buried in
# scrollback history is not mistaken for a current prompt. Conservative: when in doubt, "none" (a
# false "menu" would block a legitimate send).
_managed_menu_detect() { # <pane>
  local pane="$1" cap tail_region raw_cap raw_tail_region menu_tail
  menu_tail="${OSRC_MENU_TAIL:-20}"
  cap="$(tmux capture-pane -e -t "$pane" -p 2>/dev/null)" || { printf 'MENU none\n'; return 0; }
  raw_cap="$cap"
  cap="$(printf '%s\n' "$cap" | _managed_strip_ansi)"
  raw_tail_region="$(printf '%s\n' "$raw_cap" | grep -v '^[[:space:]]*$' | tail -n "$menu_tail")"
  tail_region="$(printf '%s\n' "$cap" | grep -v '^[[:space:]]*$' | tail -n "${OSRC_MENU_TAIL:-20}")"
  [ -n "$tail_region" ] || { printf 'MENU none\n'; return 0; }
  local LC_ALL; LC_ALL="$(_osrc_utf8_locale)"; export LC_ALL
  # Gate (L3): a recognised engine layout decides. Composer, idle, working = no menu, whatever rows
  # happen to sit in the tail.
  local _eng _settle=0 _i _j
  _eng="$(_osrc_screen_engine_of "$pane")"
  _osrc_screen_analyze_text "$_eng" <<<"$raw_cap"
  # A known engine mid-redraw (e.g. Claude Code restarting after the trust prompt) can show a
  # partial frame. Give it a moment to settle before falling back to the legacy heuristics, which
  # misread a half-drawn composer as a cursor menu (seen live 2026-11-13).
  case "$(_osrc_scr_engine_norm "$_eng")" in cc|codex|devin|agy|gemini) _settle=1 ;; esac
  while [ "$_settle" = 1 ] && [ "${OSRC_SCR_GENERIC:-1}" = 1 ] && [ "${_i:-0}" -lt "${OSRC_MENU_SETTLE_POLLS:-4}" ]; do
    sleep 0.5; _i=$(( ${_i:-0} + 1 ))
    cap="$(tmux capture-pane -e -t "$pane" -p 2>/dev/null)" || break
    raw_cap="$cap"; cap="$(printf '%s\n' "$cap" | _managed_strip_ansi)"
    raw_tail_region="$(printf '%s\n' "$raw_cap" | grep -v '^[[:space:]]*$' | tail -n "$menu_tail")"
    tail_region="$(printf '%s\n' "$cap" | grep -v '^[[:space:]]*$' | tail -n "$menu_tail")"
    _osrc_screen_analyze_text "$_eng" <<<"$raw_cap"
  done
  if [ "${OSRC_SCR_GENERIC:-1}" != 1 ]; then
    case "$OSRC_SCR_STATE" in approval|question) ;; *) printf 'MENU none\n'; return 0 ;; esac
    # A prose question ends a reply above a live composer: that is answered with `session send`.
    # Only a picker or prompt that has replaced the composer is a menu (seen live: history rows of a
    # prose "What should Claude do instead?" were read as cursor rows).
    [ "${OSRC_SCR_COMPOSER_FOUND:-0}" = 1 ] && { printf 'MENU none\n'; return 0; }
    # The reader knows this layout: list the options from its rows (row 1 included, no history).
    _osrc_menu_from_screen && return 0
  fi
  # Claude only: its mode status line as the LAST row is footer, never a menu row. Drop it and read
  # what is above: an idle composer box still reads MENU none (guard below), an unknown cursor menu
  # above the line still reads as a menu, so send says "menu open, use session answer". Whole-line
  # match, so a tool's "⏵ deploy on" under its own menu (or any other engine's pane) changes nothing.
  if [ "$(_osrc_scr_engine_norm "$_eng")" = cc ] && [ "$_SCR_N" -gt 0 ] && _osrc_scr_cc_status_row "${_SCR_L[$((_SCR_N - 1))]}"; then
    _SCR_N=$((_SCR_N - 1))
    # An empty "❯" row is Claude's idle composer drawn without its rules (half-drawn frame): a menu's
    # selected row always carries a label.
    _j=0
    while [ "$_j" -lt "$_SCR_N" ]; do
      [ "$(_osrc_scr_trim "${_SCR_L[$_j]}")" = "❯" ] && { printf 'MENU none\n'; return 0; }
      _j=$((_j + 1))
    done
    tail_region="$(printf '%s\n' "$tail_region" | sed '$d')"
    raw_tail_region="$(printf '%s\n' "$raw_tail_region" | sed '$d')"
  fi
  # Legacy path guard: a prompt-glyph row that sits directly between two horizontal rules is a
  # composer box, and a `❯ Try "…"` row is Claude Code's composer placeholder. Neither is a menu.
  _j=1
  while [ "$_j" -lt $((_SCR_N - 1)) ]; do
    case "${_SCR_L[$_j]}" in
      '❯ Try "'*) printf 'MENU none\n'; return 0 ;;
      '❯'*|'❭'*|'>'*|'›'*) _osrc_scr_is_rule "${_SCR_L[$((_j - 1))]}" && _osrc_scr_is_rule "${_SCR_L[$((_j + 1))]}" && { printf 'MENU none\n'; return 0; } ;;
    esac
    _j=$((_j + 1))
  done

  local consent_re='(\[y/N\]|\(y/n\)|\[Y/n\]|\[y/n\])'
  if printf '%s\n' "$tail_region" | grep -Eq "$consent_re"; then
    printf 'MENU consent\n'
    printf 'PROMPT %s\n' "$(printf '%s\n' "$tail_region" | grep -E "$consent_re" | tail -1)"
    return 0
  fi

  # Codex approval menu: numbered option rows plus the signature footer. The selected row must be
  # visible in the retained ANSI capture, so a plain option list cannot silently default to row 1.
  # Detected BEFORE the generic numbered branch because a Codex approval menu can have one row.
  local codex_footer_re='Press enter to confirm or esc to cancel'
  if printf '%s\n' "$tail_region" | grep -Eq "$codex_footer_re"; then
    local cnums ccount=0 cidx clab csel_count=0 csel_idx=0 clean_ln
    cnums="$(printf '%s\n' "$tail_region" | grep -E '^[[:space:]]*[0-9]+[.)][[:space:]]+')"
    if [ -n "$cnums" ]; then
      while IFS= read -r ln; do
        [ -n "$ln" ] || continue
        cidx="$(printf '%s' "$ln" | sed -E 's/^[[:space:]]*([0-9]+)[.)][[:space:]]+.*/\1/')"
        clab="$(printf '%s' "$ln" | sed -E 's/^[[:space:]]*[0-9]+[.)][[:space:]]+//')"
        [ -n "$cidx" ] && [ -n "$clab" ] && ccount=$((ccount + 1))
      done < <(printf '%s\n' "$cnums")
      if [ "$ccount" -ge 1 ]; then
        while IFS= read -r ln; do
          clean_ln="$(printf '%s\n' "$ln" | _managed_strip_ansi)"
          cidx="$(printf '%s' "$clean_ln" | sed -E 's/^[[:space:]]*([0-9]+)[.)][[:space:]]+.*/\1/')"
          clab="$(printf '%s' "$clean_ln" | sed -E 's/^[[:space:]]*[0-9]+[.)][[:space:]]+//')"
          if [ -n "$cidx" ] && [ -n "$clab" ] && _managed_line_selected "$ln"; then
            csel_count=$((csel_count + 1))
            csel_idx="$cidx"
          fi
        done < <(printf '%s\n' "$raw_tail_region")
      fi
      if [ "$ccount" -ge 1 ] && [ "$csel_count" -eq 1 ]; then
        printf 'MENU codex\n'
        while IFS= read -r ln; do
          [ -n "$ln" ] || continue
          cidx="$(printf '%s' "$ln" | sed -E 's/^[[:space:]]*([0-9]+)[.)][[:space:]]+.*/\1/')"
          clab="$(printf '%s' "$ln" | sed -E 's/^[[:space:]]*[0-9]+[.)][[:space:]]+//')"
          if [ -n "$cidx" ] && [ -n "$clab" ]; then
            if [ "$cidx" = "$csel_idx" ]; then printf 'SEL %s %s\n' "$cidx" "$clab"; else printf 'OPT %s %s\n' "$cidx" "$clab"; fi
          fi
        done < <(printf '%s\n' "$cnums")
        return 0
      fi
    fi
  fi

  # Numbered options. Require >=2 numbered rows so a single numbered prose line is not mistaken for
  # a menu.
  local nums count=0 idx lab
  nums="$(printf '%s\n' "$tail_region" | grep -E '^[[:space:]]*[0-9]+[.)][[:space:]]+')"
  if [ -n "$nums" ]; then
    while IFS= read -r ln; do
      [ -n "$ln" ] || continue
      idx="$(printf '%s' "$ln" | sed -E 's/^[[:space:]]*([0-9]+)[.)][[:space:]]+.*/\1/')"
      lab="$(printf '%s' "$ln" | sed -E 's/^[[:space:]]*[0-9]+[.)][[:space:]]+//')"
      [ -n "$idx" ] && [ -n "$lab" ] && count=$((count + 1))
    done < <(printf '%s\n' "$nums")
    if [ "$count" -ge 2 ]; then
      printf 'MENU numbered\n'
      while IFS= read -r ln; do
        [ -n "$ln" ] || continue
        idx="$(printf '%s' "$ln" | sed -E 's/^[[:space:]]*([0-9]+)[.)][[:space:]]+.*/\1/')"
        lab="$(printf '%s' "$ln" | sed -E 's/^[[:space:]]*[0-9]+[.)][[:space:]]+//')"
        [ -n "$idx" ] && [ -n "$lab" ] && printf 'OPT %s %s\n' "$idx" "$lab"
      done < <(printf '%s\n' "$nums")
      return 0
    fi
  fi

  # Cursor list: a ❯-marked selected row among sibling indented rows. Candidate rows are indented
  # (with or without a ❯ marker); a column-0 prose header is not an option. Require >=2 candidate
  # rows and >=1 marked row, so a single ❯ prompt glyph is not mistaken for a list.
  if printf '%s\n' "$tail_region" | grep -qE '^[[:space:]]*(❯|❭)?[[:space:]]+'; then
    local pos=0 sel=0 is_sel cand
    cand="$(printf '%s\n' "$tail_region" | grep -E '^[[:space:]]*(❯|❭)?[[:space:]]+')"
    # First pass: count candidates and locate the ❯-marked row.
    while IFS= read -r ln; do
      [ -n "$ln" ] || continue
      pos=$((pos + 1))
      if printf '%s' "$ln" | grep -qE '^[[:space:]]*(❯|❭)[[:space:]]+'; then sel=$pos; fi
    done < <(printf '%s\n' "$cand")
    if [ "$pos" -ge 2 ] && [ "$sel" -ge 1 ]; then
      printf 'MENU cursor\n'
      pos=0
      while IFS= read -r ln; do
        [ -n "$ln" ] || continue
        pos=$((pos + 1))
        if printf '%s' "$ln" | grep -qE '^[[:space:]]*(❯|❭)[[:space:]]+'; then is_sel=1; else is_sel=0; fi
        lab="$(printf '%s' "$ln" | sed -E 's/^[[:space:]]*(❯|❭)?[[:space:]]+//')"
        [ -n "$lab" ] || continue
        if [ "$is_sel" = 1 ]; then printf 'SEL %d %s\n' "$pos" "$lab"; else printf 'OPT %d %s\n' "$pos" "$lab"; fi
      done < <(printf '%s\n' "$cand")
      return 0
    fi
  fi

  printf 'MENU none\n'
}

# Answer a detected menu. <pane> <selector>: y|n|yes|no (consent), a numeric index OR a label
# substring (numbered — the two provider families order options differently, so match the label),
# a label substring (codex — navigate from the option-1 default to the match, then Enter), or a
# label substring (cursor — navigate Up/Down from the ❯ row to the match, then Enter). Verifies the
# menu closed (a follow-up detect returns "none"). 0 = answered + verified closed; 1 = could not
# answer or the menu did not close. Sends ONLY the answer keys, never chat.
#
# Holds the endpoint mutation lock across menu detection + revalidation + all navigation + Enter, so
# a concurrent `session send`/`clear`/`control` on the same pane cannot interleave keystrokes with
# the multi-key menu selection (static F10). The menu is re-detected UNDER the lock: a concurrent op
# may have closed it between the caller's detect and this answer, and answering a gone menu would
# type into a composer. The lock is released after Enter, before the read-only close-verification
# poll (holding it across a 1.5s poll would block sibling mutations for no safety benefit).
_managed_menu_answer() { # <pane> <selector>
  local pane="$1" sel="$2" kind report line lab target_pos sel_pos n delta i key pre=""
  _endpoint_mutation_lock "$pane" || return 1
  type _sv_screen_hash >/dev/null 2>&1 && pre="$(_sv_screen_hash "$pane")"   # the prompt as it was before the keys
  key="$(printf '%s' "$pane" | cksum | awk '{print $1}')"
  # Revalidate the menu UNDER the lock — a concurrent send/control may have closed it since the
  # caller's detect. Detecting again here is the revalidation: "none" means the menu is gone and
  # answering would type into a composer, so refuse without sending any keys.
  report="$(_managed_menu_detect "$pane")"
  kind="$(printf '%s\n' "$report" | head -1 | awk '{print $2}')"
  case "$kind" in
    none) echo "no interactive menu detected in the pane. Re-check with: $0 session read" >&2; _endpoint_mutation_unlock "$key"; return 1 ;;
    consent)
      case "$sel" in
        y|yes|Y) tmux send-keys -t "$pane" -l -- "y" 2>/dev/null || { _endpoint_mutation_unlock "$key"; return 1; } ;;
        n|no|N)  tmux send-keys -t "$pane" -l -- "n" 2>/dev/null || { _endpoint_mutation_unlock "$key"; return 1; } ;;
        *) echo "consent prompt needs y|yes or n|no" >&2; _endpoint_mutation_unlock "$key"; return 1 ;;
      esac
      tmux send-keys -t "$pane" Enter 2>/dev/null || { _endpoint_mutation_unlock "$key"; return 1; }
      ;;
    numbered)
      # Format-agnostic: accept EITHER a numeric index (backward compat) OR a label
      # substring. The two provider families order options differently, so a hardcoded
      # row index picks the wrong option across families; matching the label is safe.
      sel="$(_osrc_menu_resolve "$report" "$sel")" || { _endpoint_mutation_unlock "$key"; return 1; }
      tmux send-keys -t "$pane" -l -- "$sel" 2>/dev/null || { _endpoint_mutation_unlock "$key"; return 1; }
      tmux send-keys -t "$pane" Enter 2>/dev/null || { _endpoint_mutation_unlock "$key"; return 1; }
      ;;
    codex|cursor|select)
      # Navigate from the highlighted row to the target by list position, then Enter. Enter alone
      # when the target is already highlighted.
      target_pos="$(_osrc_menu_resolve "$report" "$sel")" || { _endpoint_mutation_unlock "$key"; return 1; }
      target_pos="$(_osrc_menu_pos "$report" "$target_pos")"
      sel_pos="$(printf '%s\n' "$report" | grep -E '^(SEL|OPT) ' | awk '$1=="SEL" {print NR}')"
      [ "$(printf '%s\n' "$sel_pos" | grep -c .)" = 1 ] || { echo "the menu has no single highlighted row; nothing sent" >&2; _endpoint_mutation_unlock "$key"; return 1; }
      [ "${target_pos:-0}" -gt 0 ] 2>/dev/null || { echo "option not found in the menu; nothing sent" >&2; _endpoint_mutation_unlock "$key"; return 1; }
      delta=$((target_pos - sel_pos))
      if [ "$delta" -gt 0 ]; then i=0; while [ "$i" -lt "$delta" ]; do tmux send-keys -t "$pane" Down 2>/dev/null || { _endpoint_mutation_unlock "$key"; return 1; }; i=$((i+1)); done
      elif [ "$delta" -lt 0 ]; then i=0; n=$((0 - delta)); while [ "$i" -lt "$n" ]; do tmux send-keys -t "$pane" Up 2>/dev/null || { _endpoint_mutation_unlock "$key"; return 1; }; i=$((i+1)); done; fi
      tmux send-keys -t "$pane" Enter 2>/dev/null || { _endpoint_mutation_unlock "$key"; return 1; }
      ;;
    *) echo "unrecognized menu kind '$kind'" >&2; _endpoint_mutation_unlock "$key"; return 1 ;;
  esac
  _endpoint_mutation_unlock "$key"
  [ -z "$pre" ] || osrc_keys_sent "$pane" "session answer" "$pre"   # supervise re-checks it landed
  # Verify the menu closed: bounded poll until the follow-up detect returns "none". Read-only — the
  # lock is no longer held (the mutation is complete).
  i=0
  while [ "$i" -lt "${OSRC_MENU_CLOSE_POLLS:-15}" ]; do
    [ "$(_managed_menu_detect "$pane" | head -1 | awk '{print $2}')" = "none" ] && { [ -z "$pre" ] || osrc_keys_landed "$pane"; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  # Still the SAME prompt (screen hash as before the keys): the keystroke did not land, so log and print
  # approval-not-landed for a retry. A different menu means the answer landed and a new prompt opened.
  if [ -n "$pre" ] && [ "$(_sv_screen_hash "$pane")" = "$pre" ]; then
    echo "answer sent but the same prompt is still open. Re-check with: $0 session read" >&2
    osrc_not_landed_emit "$pane" "session answer"
  else
    [ -z "$pre" ] || osrc_keys_landed "$pane"
    echo "answer sent; a menu is still showing (a new prompt?). Re-check with: $0 session read" >&2
  fi
  return 1
}
