#!/usr/bin/env bash
# lib/hub-lanename.sh -- Mission Control prints names a person would use, never an id, and never a
# stored display string for a time that moves (renews). Sourced by outsourcerer.sh (lib loader).
#
# Real-machine evidence (0.16.2): lane rows read "outsourcerer-video--1285105…"
# (the tmux session name), a project card read "Widget Core · total-recall-85" (a /rename slug), and
# the plans rail read "Renews in 92h 32m" from a limits cache an older build wrote.

# idlike: true for text that reads like an identifier rather than a name. Shared by the lane namer, the
# title picker and the guard test (tests/test_hub_mc4.sh), so all three agree on what an id looks like.
#   * an Outsourcerer session/test prefix: "outsourcerer-…", "osrc-…"
#   * a "--<digits>" hash join (outsourcerer-<folder>--<hash>-<sid8>)
#   * a hex run of 6+ that holds a digit (sid8, uuid parts, job ids, git shas)
#   * a whole value that is a lowercase slug ending in a number ("total-recall-85", "orch-2")
_OSRC_HUB_IDLIKE_JQ='def idlike: (type == "string") and (
    test("(^|[^A-Za-z0-9])(osrc|outsourcerer)-"; "i")
    or test("--[0-9]")
    or test("(?<![A-Za-z0-9])(?=[0-9a-fA-F]*[0-9])[0-9a-fA-F]{6,}(?![A-Za-z0-9])")
    or test("^[a-z0-9]+([-_][a-z0-9]+)*[-_][0-9]+[a-z]?$"));'

# _osrc_hub_idlike <text> -> rc 0 when the text reads like an id.
_osrc_hub_idlike() {
  [ -n "${1:-}" ] || return 1
  jq -en --arg s "$1" "$_OSRC_HUB_IDLIKE_JQ"' $s | idlike' >/dev/null 2>&1
}

# _osrc_hub_folder_label <path> -> "Video" for …/proposals/video, "V185 redo" for …/v185-redo: the folder in
# sentence case, with hash and id tokens dropped; "" when nothing human is left.
_osrc_hub_folder_label() {
  local b="${1%/}"; b="${b##*/}"
  [ -n "$b" ] || return 0
  b="${b%%--*}"                       # outsourcerer-<folder>--<hash>-<sid8> -> outsourcerer-<folder>
  case "$b" in outsourcerer-*) b="${b#outsourcerer-}" ;; osrc-*) b="${b#osrc-}" ;; esac
  b="${b#wt-}"; b="${b#worktree-}"; b="${b#auto-}"   # wt-auto-demo / osrc-auto-demo -> demo
  jq -rn --arg s "$b" "$_OSRC_HUB_IDLIKE_JQ"'
    $s | gsub("[-_.]+"; " ") | split(" ") | map(select(length > 0 and (idlike | not)))
    | join(" ") | if . == "" then "" else (.[0:1] | ascii_upcase) + .[1:] end' 2>/dev/null
}

# _osrc_hub_text_name <text> -> one line, chat noise and ids cleaned, cut to ~48 chars; "" when it is an id.
_osrc_hub_text_name() {
  local out
  out="$(printf '%s' "${1:-}" | head -c 4000 | jq -Rrs "$_OSRC_HUB_NAME_JQ $_OSRC_HUB_IDLIKE_JQ"'
    split("\n") | map(select(test("\\S"))) | (.[0] // "") | clean | short(48)
    | if idlike then "" else . end' 2>/dev/null)"
  printf '%s' "$out"
}

# _osrc_hub_lane_name <lane-id> -> what a person calls this lane. First that exists and is not an id:
# the job's own title/task (meta.json, task_ref), the lane's Claude transcript title (registry
# cc_session_id -> custom-title > ai-title > agent-name > first prompt), the lane's folder in sentence case,
# a remote lane's branch; else "<Provider> lane". Never the session name, a hash or a sid.
_osrc_hub_lane_name() {
  local id="$1" jd="$OSRC_JOBS/$1" t="" ev="" cc="" cwd="" prov="" br="" raw_t=""
  case "$id" in ''|*/*) printf 'Lane'; return 0 ;; esac
  if type _osrc_hub_lane_name_cache_get >/dev/null 2>&1 && t="$(_osrc_hub_lane_name_cache_get "$id")"; then
    printf '%s' "$t"; return 0
  fi
  if [ -f "$jd/meta.json" ]; then
    IFS=$'\x1f' read -r raw_t cwd prov <<EOF
$(jq -r '[(.title // .task // .brief_title // ""), (.worktree // .cwd // ""), (.provider // .lane // "")] | map(tostring | gsub("[\n\r\u001f]"; " ")) | join("\u001f")' "$jd/meta.json" 2>/dev/null)
EOF
    [ -n "$raw_t" ] && t="$(_osrc_hub_text_name "$raw_t")"
    [ -n "$t" ] || [ ! -s "$jd/task_ref" ] || t="$(_osrc_hub_text_name "$(head -1 "$jd/task_ref" 2>/dev/null)")"
  fi
  if [ -z "$t" ] && [ -f "$OSRC_HOME/remote/$id.json" ]; then
    local rcwd="" rprov=""
    IFS=$'\x1f' read -r raw_t rcwd br rprov <<EOF
$(jq -r '[(.title // .task // ""), (.cwd // .worktree // ""), (.branch // ""), (.vehicle // .provider // "")] | map(tostring | gsub("[\n\r\u001f]"; " ")) | join("\u001f")' "$OSRC_HOME/remote/$id.json" 2>/dev/null)
EOF
    [ -n "$raw_t" ] && t="$(_osrc_hub_text_name "$raw_t")"
    [ -n "$cwd" ] || cwd="$rcwd"
    [ -n "$prov" ] || prov="$rprov"
  fi
  if [ -z "$t" ]; then
    if type _session_registry_last_event >/dev/null 2>&1; then
      ev="$(_session_registry_last_event "$id" 2>/dev/null)"
    elif [ -f "${OSRC_SESSION_REGISTRY:-}" ]; then
      ev="$(jq -c --arg id "$id" 'select(.session_id == $id)' "$OSRC_SESSION_REGISTRY" 2>/dev/null | tail -1)"
    fi
    if [ -n "$ev" ]; then
      local ecwd="" eprov=""
      IFS=$'\x1f' read -r cc ecwd eprov <<EOF
$(jq -r '[(.cc_session_id // ""), (.cwd // ""), (.provider // "")] | map(tostring | gsub("[\n\r\u001f]"; " ")) | join("\u001f")' <<<"$ev" 2>/dev/null)
EOF
      [ -n "$cwd" ] || cwd="$ecwd"
      [ -n "$prov" ] || prov="$eprov"
      case "$cc" in ''|null|*/*) ;; *) type _osrc_hub_session_detail >/dev/null 2>&1 && t="$(_osrc_hub_session_detail "$cc" 2>/dev/null)" ;; esac
      [ -z "$t" ] || { _osrc_hub_idlike "$t" && t=""; }
    fi
  fi
  [ -n "$t" ] || [ -d "$OSRC_JOBS/$id" ] || t="$(_osrc_hub_folder_label "$id")"   # osrc-auto-P56W -> P56W, even in a shared worktree
  [ -n "$t" ] || [ -z "$cwd" ] || t="$(_osrc_hub_folder_label "$cwd")"
  [ -n "$t" ] || [ -z "$br" ] || t="$(_osrc_hub_folder_label "$br")"
  if [ -z "$t" ]; then
    case "$prov" in
      cc|claude) t="Claude lane" ;; devin|dv) t="Devin lane" ;; codex|cx) t="Codex lane" ;;
      gemini|agy|gm) t="Gemini lane" ;; cursor) t="Cursor lane" ;; or|openrouter) t="OpenRouter lane" ;;
      *) t="Lane" ;;
    esac
  fi
  type _osrc_hub_lane_name_cache_put >/dev/null 2>&1 && _osrc_hub_lane_name_cache_put "$id" "$t"
  printf '%s' "$t"
}

# _osrc_hub_lane_for <id> <rmap> -> the lane json from the builders in lib/hub.sh with a human `short`.
# A builder's short survives only when it is not an id (a job's task_ref, a card override applied later).
_osrc_hub_lane_for() {
  local lj short
  lj="$(_osrc_hub_lane_for_raw "$@")" || return 1
  [ -n "$lj" ] || return 1
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "lf.$1.raw"
  short="$(jq -r '.short // ""' <<<"$lj" 2>/dev/null)"
  if [ -z "$short" ] || [ "$short" = "$1" ] || _osrc_hub_idlike "$short"; then
    lj="$(jq -c --arg s "$(_osrc_hub_lane_name "$1")" '.short = $s' <<<"$lj" 2>/dev/null)" || return 1
  fi
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "lf.$1.name"
  printf '%s' "$lj"
}

# _osrc_hub_limits_fresh: stdin limits JSON array -> the same rows with every `renews` rebuilt from its
# `renews_at` epoch NOW, in local time ("in 4 days · Thu 19 Nov"). A stored renews string is never trusted
# (it was rendered by whichever build wrote the cache, at whatever time); a row with no epoch, or one already
# past, has no renews at all. Window details (`windows.<w>`) get the same treatment.
_osrc_hub_limits_fresh() {
  if type _osrc_hub_limits_fresh_fast >/dev/null 2>&1; then _osrc_hub_limits_fresh_fast; return; fi
  local in now ep map='{}' t
  in="$(cat)"
  jq -e 'arrays' >/dev/null 2>&1 <<<"$in" || { printf '[]'; return 0; }
  now="$(date +%s)"
  for ep in $(jq -r '[.[] | objects | .renews_at, ((.windows // {}) | if type == "object" then .[] | objects | .renews_at else empty end)]
                     | .[] | numbers | (if . > 100000000000 then . / 1000 else . end) | floor' <<<"$in" 2>/dev/null | sort -u); do
    t=""; type _osrc_renew_text >/dev/null 2>&1 && t="$(_osrc_renew_text "$ep" "$now" 2>/dev/null)"
    [ -n "$t" ] && map="$(jq -c --arg k "$ep" --arg v "$t" '. + {($k): $v}' <<<"$map")"
  done
  jq -c --argjson m "$map" '
    def fix: if type != "object" then .
      elif (.renews_at | type) == "number"
        then .renews = ($m[(.renews_at | if . > 100000000000 then . / 1000 else . end | floor | tostring)] // null)
      elif has("renews") then .renews = null else . end;
    map(fix | if (.windows | type) == "object" then .windows |= map_values(fix) else . end)' <<<"$in" 2>/dev/null || printf '[]'
}
