# shellcheck shell=bash
# lib/menu.sh: interactive menu detection + answering for `session send` / `session answer`.
# Moved out of outsourcerer.sh by L3 (2026-11-13). The detector is now GATED by lib/screen.sh: when
# the engine reader recognises its own layout (Claude Code, Codex, Devin, agy, Gemini), only an open
# approval/question counts as a menu. That kills the two false positives that blocked `session send`
# (FINDINGS class 6, Fable E8): Claude Code's composer + status bar read as a cursor list, and a reply
# that ends in a numbered list read as a numbered menu. Unknown engines keep the legacy heuristics.

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
  local _eng _settle=0 _i
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
  fi
  # Legacy path guard: a prompt-glyph row that sits directly between two horizontal rules is a
  # composer box, and a `❯ Try "…"` row is Claude Code's composer placeholder. Neither is a menu.
  local _j=1
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
  local pane="$1" sel="$2" kind report line lab target_pos sel_pos n delta i key
  _endpoint_mutation_lock "$pane" || return 1
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
      case "$sel" in
        *[!0-9]*)
          # Label substring: resolve to the matching option's index, then type it.
          local _nidx=""
          while IFS= read -r line; do
            case "$line" in
              OPT*) lab="${line#OPT }"; lab="${lab#* }"; if _managed_label_contains_literal "$lab" "$sel"; then _nidx="${line#OPT }"; _nidx="${_nidx%% *}"; fi ;;
            esac
          done < <(printf '%s\n' "$report")
          [ -n "$_nidx" ] || { echo "no numbered option matches '$sel'" >&2; _endpoint_mutation_unlock "$key"; return 1; }
          sel="$_nidx"
          ;;
      esac
      printf '%s\n' "$report" | grep -qE "^OPT $sel " || { echo "index $sel is not one of the offered options" >&2; _endpoint_mutation_unlock "$key"; return 1; }
      tmux send-keys -t "$pane" -l -- "$sel" 2>/dev/null || { _endpoint_mutation_unlock "$key"; return 1; }
      tmux send-keys -t "$pane" Enter 2>/dev/null || { _endpoint_mutation_unlock "$key"; return 1; }
      ;;
    codex)
      # Codex approval menu: cursor-like, but the default highlight is option 1 and plain
      # Enter selects it. Match the label, navigate from position 1 to the target with
      # Up/Down, then Enter (Enter alone if the target IS option 1). Navigation uses
      # standard TUI arrow keys; the default-option-1 + Enter path is the verified one.
      target_pos=0; sel_pos=0
      while IFS= read -r line; do
        case "$line" in
          SEL*) sel_pos="${line#SEL }"; sel_pos="${sel_pos%% *}"; lab="${line#SEL }"; lab="${lab#* }"; if _managed_label_contains_literal "$lab" "$sel"; then target_pos="$sel_pos"; fi ;;
          OPT*) lab="${line#OPT }"; lab="${lab#* }"; if _managed_label_contains_literal "$lab" "$sel"; then target_pos="${line#OPT }"; target_pos="${target_pos%% *}"; fi ;;
        esac
      done < <(printf '%s\n' "$report")
      [ "${target_pos:-0}" -gt 0 ] 2>/dev/null || { echo "no codex option matches '$sel'" >&2; _endpoint_mutation_unlock "$key"; return 1; }
      [ "${sel_pos:-0}" -gt 0 ] 2>/dev/null || { echo "no currently selected codex row found" >&2; _endpoint_mutation_unlock "$key"; return 1; }
      delta=$((target_pos - sel_pos))
      if [ "$delta" -gt 0 ]; then i=0; while [ "$i" -lt "$delta" ]; do tmux send-keys -t "$pane" Down 2>/dev/null || { _endpoint_mutation_unlock "$key"; return 1; }; i=$((i+1)); done
      elif [ "$delta" -lt 0 ]; then i=0; n=$((0 - delta)); while [ "$i" -lt "$n" ]; do tmux send-keys -t "$pane" Up 2>/dev/null || { _endpoint_mutation_unlock "$key"; return 1; }; i=$((i+1)); done; fi
      tmux send-keys -t "$pane" Enter 2>/dev/null || { _endpoint_mutation_unlock "$key"; return 1; }
      ;;
    cursor)
      target_pos=0; sel_pos=0
      while IFS= read -r line; do
        case "$line" in
          SEL*) sel_pos="${line#SEL }"; sel_pos="${sel_pos%% *}"; lab="${line#SEL }"; lab="${lab#* }"; if _managed_label_contains_literal "$lab" "$sel"; then target_pos="$sel_pos"; fi ;;
          OPT*) lab="${line#OPT }"; lab="${lab#* }"; if _managed_label_contains_literal "$lab" "$sel"; then target_pos="${line#OPT }"; target_pos="${target_pos%% *}"; fi ;;
        esac
      done < <(printf '%s\n' "$report")
      [ "${target_pos:-0}" -gt 0 ] 2>/dev/null || { echo "no cursor-list option matches '$sel'" >&2; _endpoint_mutation_unlock "$key"; return 1; }
      [ "${sel_pos:-0}" -gt 0 ] 2>/dev/null || { echo "no currently selected (❯) row found" >&2; _endpoint_mutation_unlock "$key"; return 1; }
      delta=$((target_pos - sel_pos))
      if [ "$delta" -gt 0 ]; then i=0; while [ "$i" -lt "$delta" ]; do tmux send-keys -t "$pane" Down 2>/dev/null || { _endpoint_mutation_unlock "$key"; return 1; }; i=$((i+1)); done
      elif [ "$delta" -lt 0 ]; then i=0; n=$((0 - delta)); while [ "$i" -lt "$n" ]; do tmux send-keys -t "$pane" Up 2>/dev/null || { _endpoint_mutation_unlock "$key"; return 1; }; i=$((i+1)); done; fi
      tmux send-keys -t "$pane" Enter 2>/dev/null || { _endpoint_mutation_unlock "$key"; return 1; }
      ;;
    *) echo "unrecognized menu kind '$kind'" >&2; _endpoint_mutation_unlock "$key"; return 1 ;;
  esac
  _endpoint_mutation_unlock "$key"
  # Verify the menu closed: bounded poll until the follow-up detect returns "none". Read-only — the
  # lock is no longer held (the mutation is complete).
  i=0
  while [ "$i" -lt "${OSRC_MENU_CLOSE_POLLS:-15}" ]; do
    [ "$(_managed_menu_detect "$pane" | head -1 | awk '{print $2}')" = "none" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  echo "answer sent but the menu did not close (still detected). Re-check with: $0 session read" >&2
  return 1
}
