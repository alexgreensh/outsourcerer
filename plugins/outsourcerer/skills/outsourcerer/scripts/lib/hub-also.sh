#!/usr/bin/env bash
# lib/hub-also.sh -- Mission Control "Also running": the Claude Code sessions that are NOT
# Outsourcerer orchestrators or lanes but are working right now, or wrote their transcript within
# OSRC_HUB_ACTIVE_MIN (30) minutes. Read-only: it reads ~/.claude/sessions and transcripts in one pass
# (_osrc_hub_cc_rows) and never attaches to, sends to or changes a session. No naming model is called: names come from the folder's project and
# the session's own title or first prompt (_osrc_hub_session_detail). Sourced by outsourcerer.sh.

# _osrc_hub_model_label <model-id> -> "Opus 5.5" for claude-opus-5-5, the id otherwise, "" when empty.
_osrc_hub_model_label() {
  printf '%s' "${1:-}" | sed -E 's/^claude-//; s/-[0-9]{8}$//; s/\[.*\]$//' | awk -F- '
    NF >= 2 && $1 ~ /^(opus|sonnet|haiku|fable)$/ {
      n = toupper(substr($1, 1, 1)) substr($1, 2); v = $2; for (i = 3; i <= NF; i++) v = v "." $i; print n " " v; next }
    { print }'
}

# _osrc_hub_transcript_model <transcript> -> the model of the newest assistant turn (tail only).
_osrc_hub_transcript_model() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  tail -c 262144 "$1" 2>/dev/null | grep -o '"model": *"[^"]*"' | tail -1 | sed -E 's/.*"([^"]*)"$/\1/'
}

# _osrc_hub_also_rows -> JSON array: {key, name ("<Project> · <title>"), project, title, model, state: working|waiting|idle, idleMin, since}.
# Bounded: the registry is read in one pass (_osrc_hub_cc_rows, lib/hub-truth.sh); only the 12 rows that
# are shown get names and models (title reads are cached by transcript size in hub/titles-v4).
_osrc_hub_also_rows() {
  have jq || { printf '[]'; return 0; }
  type _osrc_hub_cc_rows >/dev/null 2>&1 || { printf '[]'; return 0; }
  local m="${OSRC_HUB_ACTIVE_MIN:-30}" now rows='[]' sid cwd st su pid job wf alive tm st2 age key name proj det model claimed rk f pick=""
  local _nl='
'
  case "$m" in ''|*[!0-9]*) m=30 ;; esac
  now="$(date +%s)"
  claimed="$(for f in "$OSRC_HOME"/owners/*/*; do [ -f "$f" ] && printf '%s\n' "${f##*/}"; done 2>/dev/null)"
  while IFS='|' read -r sid cwd st su pid job wf alive tm; do
    [ -n "$sid" ] && [ "$alive" = 1 ] && [ -z "$job" ] || continue
    [ "$sid" = "${CLAUDE_CODE_SESSION_ID:-}" ] && continue
    # Orchestrators and their lanes are projects above, not "also running".
    [ -d "$OSRC_HOME/hub/seen/$sid" ] || [ -d "$OSRC_HOME/owners/$sid" ] || [ -f "$OSRC_HOME/hub/projects/$sid.json" ] && continue
    case "$_nl$claimed$_nl" in *"$_nl$sid$_nl"*) continue ;; esac
    case "$tm" in ''|*[!0-9]*) tm=0 ;; esac
    if [ -n "$wf" ]; then st2=waiting; else case "$st" in
      working|busy|running) st2=working ;;
      waiting|permission-waiting|needs-input|needs_you|blocked|permission-blocked) st2=waiting ;;
      *) st2=idle ;; esac; fi
    age=$(( now - tm )); [ "$age" -ge 0 ] || age=0
    [ "$st2" != idle ] || { [ "$tm" -gt 0 ] && [ "$age" -le $(( m * 60 )) ]; } || continue
    case "$st2" in waiting) rk=0 ;; working) rk=1 ;; *) rk=2 ;; esac
    pick="$pick$rk|$tm|$sid|$cwd|$st2$_nl"
  done <<EOF
$(_osrc_hub_cc_rows)
EOF
  while IFS='|' read -r rk tm sid cwd st2; do
    [ -n "$sid" ] || continue
    age=$(( now - tm )); [ "$age" -ge 0 ] || age=0
    proj=""; [ -n "$cwd" ] && [ "$cwd" != "$HOME" ] && [ -d "$cwd" ] && proj="$(_osrc_hub_repo_label "$cwd")"
    [ -n "$proj" ] || { [ -n "$cwd" ] && [ "$cwd" != "$HOME" ] && [ "$cwd" != / ] && proj="$(_osrc_hub_humanize "$cwd")"; }
    det="$(_osrc_hub_session_detail "$sid" 2>/dev/null)"
    model="$(_osrc_hub_model_label "$(_osrc_hub_transcript_model "${OSRC_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}/${cwd//[!A-Za-z0-9]/-}/$sid.jsonl")")"
    # "<Project> · <title>"; the parts ride along so the page can set the project in bold.
    name="$(_osrc_hub_join_title "$proj" "$det")"; [ -n "$name" ] || name="Claude Code session"
    key="$(printf '%s' "$sid" | cksum | awk '{print $1}')"
    rows="$(jq -cn --argjson a "$rows" --arg key "$key" --arg name "$name" --arg proj "$proj" --arg doing "$det" --arg model "$model" \
      --arg st "$st2" --argjson idle "$(( age / 60 ))" --argjson tm "$tm" '
      $a + [{key:$key, name:$name, state:$st}
        + (if $proj == "" then {} else {project:$proj} end)
        + (if $doing == "" then {} else {title:$doing} end)
        + (if $model == "" then {} else {model:$model} end)
        + (if $st == "idle" then {idleMin:$idle} else {} end)
        + (if $tm > 0 then {activeAt:$tm} else {} end)]')"
  done <<EOF
$(printf '%s' "$pick" | sort -t'|' -k1,1n -k2,2nr | head -12)
EOF
  printf '%s' "$rows"
}

# _osrc_hub_also -> the rows, cached for OSRC_HUB_ALSO_TTL (30) seconds under `hub serve` (OSRC_HUB_FAST=1)
# so a page poll never re-reads every peer. Plain `hub export` always computes.
_osrc_hub_also_write() {
  local f="$1" out
  out="$(_osrc_hub_also_rows 2>/dev/null)"
  jq -e 'arrays' >/dev/null 2>&1 <<<"$out" || out='[]'
  if [ ! -L "$f" ] && mkdir -p "$OSRC_HOME/hub" 2>/dev/null; then
    printf '%s\n' "$out" > "$f.$$" 2>/dev/null && mv -f "$f.$$" "$f" 2>/dev/null; rm -f "$f.$$" 2>/dev/null
  fi
  printf '%s' "$out"
}
_osrc_hub_also() {
  local f="$OSRC_HOME/hub/also-cache.json" ttl="${OSRC_HUB_ALSO_TTL:-30}" age lk
  case "$ttl" in ''|*[!0-9]*) ttl=30 ;; esac
  if [ "${OSRC_HUB_FAST:-0}" = 1 ] && [ -f "$f" ] && [ ! -L "$f" ] && jq -e 'arrays' "$f" >/dev/null 2>&1; then
    if type _osrc_hub_mt >/dev/null 2>&1; then
      age=$(( $(date +%s) - $(_osrc_hub_mt "$f") ))
      if [ "$age" -ge "$ttl" ] || [ "$age" -lt 0 ]; then
        lk="$OSRC_HOME/hub/also-refresh.lock"
        [ -d "$lk" ] && [ $(( $(date +%s) - $(_osrc_hub_mt "$lk") )) -gt 300 ] && rmdir "$lk" 2>/dev/null
        if mkdir "$lk" 2>/dev/null; then
          ( type _osrc_hub_close_fds >/dev/null 2>&1 && _osrc_hub_close_fds; _osrc_hub_also_write "$f" >/dev/null 2>&1; rmdir "$lk" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
        fi
      fi
    fi
    cat "$f"; return 0
  fi
  if [ "${OSRC_HUB_FAST:-0}" = 1 ]; then
    _osrc_hub_also_write "$f"
    return 0
  fi
  local out; out="$(_osrc_hub_also_rows 2>/dev/null)"
  jq -e 'arrays' >/dev/null 2>&1 <<<"$out" || out='[]'
  printf '%s' "$out"
}
