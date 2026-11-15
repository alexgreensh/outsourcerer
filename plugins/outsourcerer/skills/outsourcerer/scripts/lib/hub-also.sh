#!/usr/bin/env bash
# lib/hub-also.sh -- Mission Control "Also running" (MC3 item 5): the Claude Code sessions that are NOT
# Outsourcerer orchestrators or lanes but are working right now, or wrote their transcript within
# OSRC_HUB_ACTIVE_MIN (30) minutes. Read-only: it reuses the fleet's peer observation
# (_fleet_cc_peer_observations, which only reads ~/.claude/sessions + transcripts) and never attaches to,
# sends to or changes a session. No naming model is called: names come from the folder's project and
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
_osrc_hub_also_rows() {
  have jq || { printf '[]'; return 0; }
  type _fleet_cc_peer_observations >/dev/null 2>&1 || { printf '[]'; return 0; }
  local m="${OSRC_HUB_ACTIVE_MIN:-30}" now peers rows='[]' p sid cwd st alive tm job kind proj det model st2 age key name tf
  case "$m" in ''|*[!0-9]*) m=30 ;; esac
  now="$(date +%s)"
  peers="$(_fleet_cc_peer_observations 2>/dev/null)" || peers='[]'
  while IFS='|' read -r sid cwd st alive tm job kind; do   # "|", not a tab: whitespace IFS merges empty fields
    [ -n "$sid" ] || continue
    # Orchestrators and their lanes are projects above, not "also running".
    [ -z "$job" ] || continue
    [ -d "$OSRC_HOME/hub/seen/$sid" ] || [ -d "$OSRC_HOME/owners/$sid" ] || [ -f "$OSRC_HOME/hub/projects/$sid.json" ] && continue
    ls "$OSRC_HOME"/owners/*/"$sid" >/dev/null 2>&1 && continue
    case "$tm" in ''|*[!0-9]*) tm=0 ;; esac
    age=$(( now - tm )); [ "$age" -ge 0 ] || age=0
    case "$st" in
      working|unresponsive\?) st2=working ;;
      blocked|blocked\?) st2=waiting ;;
      *) st2=idle ;;
    esac
    [ "$alive" = true ] || continue
    [ "$st2" != idle ] || { [ "$tm" -gt 0 ] && [ "$age" -le $(( m * 60 )) ]; } || continue
    proj=""; [ -n "$cwd" ] && [ "$cwd" != "$HOME" ] && [ -d "$cwd" ] && proj="$(_osrc_hub_repo_label "$cwd")"
    [ -n "$proj" ] || { [ -n "$cwd" ] && [ "$cwd" != "$HOME" ] && [ "$cwd" != / ] && proj="$(_osrc_hub_humanize "$cwd")"; }
    det="$(_osrc_hub_session_detail "$sid" 2>/dev/null)"
    tf="$(_fleet_transcript_path "$sid" "$cwd" 2>/dev/null)"
    model="$(_osrc_hub_model_label "$(_osrc_hub_transcript_model "$tf")")"
    # "<Project> · <title>" (MC3 Titles); the parts ride along so the page can set the project in bold.
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
$(printf '%s' "$peers" | jq -r '.[] | select((.self // 0) != 1) | [.session_id, (.cwd // ""), (.state // ""), (.alive | tostring), (.transcript_mtime // 0), (.job_id // ""), (.kind // "")] | map(tostring | gsub("[|\t\n]"; " ")) | join("|")' 2>/dev/null)
EOF
  jq -c 'sort_by((if .state == "waiting" then 0 elif .state == "working" then 1 else 2 end), -(.activeAt // 0)) | .[0:12]' <<<"$rows"
}

# _osrc_hub_also -> the rows, cached for OSRC_HUB_ALSO_TTL (30) seconds under `hub serve` (OSRC_HUB_FAST=1)
# so a page poll never re-reads every peer. Plain `hub export` always computes.
_osrc_hub_also() {
  local f="$OSRC_HOME/hub/also-cache.json" ttl="${OSRC_HUB_ALSO_TTL:-30}" out
  case "$ttl" in ''|*[!0-9]*) ttl=30 ;; esac
  if [ "${OSRC_HUB_FAST:-0}" = 1 ] && [ -f "$f" ] && [ ! -L "$f" ] && type _osrc_hub_mt >/dev/null 2>&1 \
     && [ $(( $(date +%s) - $(_osrc_hub_mt "$f") )) -lt "$ttl" ] && jq -e 'arrays' "$f" >/dev/null 2>&1; then
    cat "$f"; return 0
  fi
  out="$(_osrc_hub_also_rows 2>/dev/null)"
  jq -e 'arrays' >/dev/null 2>&1 <<<"$out" || out='[]'
  if [ "${OSRC_HUB_FAST:-0}" = 1 ] && [ ! -L "$f" ] && mkdir -p "$OSRC_HOME/hub" 2>/dev/null; then
    printf '%s\n' "$out" > "$f.$$" 2>/dev/null && mv -f "$f.$$" "$f" 2>/dev/null; rm -f "$f.$$" 2>/dev/null
  fi
  printf '%s' "$out"
}
