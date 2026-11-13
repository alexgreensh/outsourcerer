#!/usr/bin/env bash
# lib/hub.sh -- Mission Control: `hub export` builds SCHEMA project docs from
# outsourcerer state; `hub serve` runs the local page server (lib/hub_server.py).
# Sourced by outsourcerer.sh; defines functions only, runs nothing at load time.
#
# Projects group by owner session ($OSRC_HOME/owners/<sid>/<target>): one orchestrator
# session = one hub project. Lane state comes from the real registries: job dirs +
# meta.json, the session registry, tmux liveness via _owned_live_state, remote lanes
# via osrc_remote_state/osrc_done_state/review items when those modules are loaded.
# Card fields (name/tagline/themes/order/repo/status/pct/eta/flow/extraLinks) and
# per-lane overrides come from $OSRC_HOME/hub/projects/<slug>.json; decisions come
# from $OSRC_HOME/hub/decisions/<slug>.json. Nothing is invented: a field with no real
# source is omitted and the page shows its own default.

_osrc_hub_dir() { printf '%s/hub' "$OSRC_HOME"; }

# _owned_live_state <id> -> prints live|done|gone. done/gone mean the owner record can go.
# Moved here from outsourcerer.sh for the file-size ratchet: hub lanes consume it for
# liveness and main's stop-guard calls it after the lib load.
_owned_live_state() {
  local id="$1" st
  if [ -d "$OSRC_JOBS/$id" ]; then
    st="$(_reconcile_status "$id" 2>/dev/null || printf '?')"
    case "$st" in
      done|'done?'|blocked|permission-blocked|failed|wedged|timeout|interrupted|canceled) printf 'done' ;;
      *) printf 'live' ;;
    esac
    return 0
  fi
  if [ -e "$OSRC_HOME/autodetach/$id.log" ] || [ -e "$OSRC_HOME/autodetach/$id.rc" ]; then
    if [ -s "$OSRC_HOME/autodetach/$id.rc" ]; then printf 'done'
    elif have tmux && tmux has-session -t "=$id" 2>/dev/null; then printf 'live'
    else printf 'gone'; fi
    return 0
  fi
  if have tmux && tmux has-session -t "=$id" 2>/dev/null; then
    # An interactive session counts only while it is working a turn; an idle REPL is not owed a wait.
    st="$(_fleet_snapshot_read 2>/dev/null | jq -r --arg id "$id" '[.items[]? | select(.session_id==$id) | .state][0] // empty' 2>/dev/null)"
    case "$st" in working|unresponsive\?) printf 'live' ;; *) printf 'idle' ;; esac
    return 0
  fi
  printf 'gone'
}

_osrc_hub_slug_ok() { case "${1:-}" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac; [ "${#1}" -le 128 ]; }

# _osrc_hub_sanitize_note <text> -> one line, $HOME -> ~, capped.
_osrc_hub_note() {
  printf '%s' "${1:-}" | tr '\n\t' '  ' | sed "s|$HOME|~|g" | cut -c1-160
}

# _osrc_hub_repo_name <repo> <url> -> owner/name only, or nothing. Never emits a
# filesystem path or a full URL (the page links github.com/<repo>).
_osrc_hub_repo_name() {
  local v="${1:-}" u="${2:-}" x
  for x in "$v" "$u"; do
    case "$x" in
      ''|*/..*) continue ;;
    esac
    x="$(printf '%s' "$x" | sed -e 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||' -e 's|^[^@/]*@[^:]*/||' -e 's|\.git$||' -e 's|/$||')"
    x="${x#github.com/}"; x="${x#www.github.com/}"
    case "$x" in
      */*)
        local owner="${x%%/*}" name="${x#*/}"
        case "$owner/$name" in
          *[!A-Za-z0-9_.-]*|*//*) continue ;;
        esac
        # A path-like value (more than one slash, or a leading slash) is not owner/name.
        case "$x" in */*/*|/*|~*) continue ;; esac
        printf '%s' "$owner/$name"; return 0 ;;
    esac
  done
  return 0
}

# _osrc_hub_review_map -> jq program fragment: lane -> latest valid verdict.
# Prints a JSON object {"<lane>":"MERGE|CHANGES|BLOCK"} built once per export.
_osrc_hub_review_map() {
  local d="$OSRC_HOME/review/items"
  [ -d "$d" ] || { printf '{}'; return 0; }
  jq -cs '[.[] | select(.state=="verdict" and (.stale|not))]
          | group_by(.lane) | map(max_by(.verdict_ts // 0))
          | map({key:(.lane|tostring), value:(.verdict|tostring)}) | from_entries' \
    "$d"/*.json 2>/dev/null || printf '{}'
}

# _osrc_hub_review_verdict <lane> <map-json> -> verdict or empty
_osrc_hub_review_verdict() { jq -r --arg l "$1" '.[$l] // ""' <<<"$2" 2>/dev/null; }

# _osrc_hub_done_state <id> -> "done" | "" (uses osrc_done_state when defined)
_osrc_hub_done_state() {
  type osrc_done_state >/dev/null 2>&1 || return 0
  case "$(osrc_done_state "$1" 2>/dev/null)" in done*) printf 'done' ;; esac
  return 0
}

# _osrc_hub_lane_status <raw> <verdict> -> "STATUS|pct|note-extra"
# Maps internal states onto the SCHEMA lane vocabulary; unknown raw states pass through.
_osrc_hub_lane_status() {
  local raw="$1" rv="$2" extra="${3:-}"
  local st="$raw"
  case "$rv" in
    MERGE) st="Merged" ;;
    BLOCK) st="Blocked" ;;
    CHANGES) st="Building"; extra="${extra:+$extra; }changes requested by review" ;;
  esac
  case "$st" in
    live|working|running|launching|stalled\?|exploring\?|no-progress-writes|ready)
      [ "$rv" = "" ] && [ "$st" = "ready" ] && st="Review" || st="Building" ;;
    idle) st="Idle" ;;
    done|'done?') st="Done" ;;
    blocked|permission-blocked) st="Blocked" ;;
    failed|wedged|timeout) st="Failed" ;;
    canceled|interrupted) st="Canceled" ;;
    gone) st="" ;;
    Merged|Blocked|Done|Building|Review|Shipped|Idle|Failed|Canceled) : ;;
    *) st="Building" ;;
  esac
  local pct=""
  case "$st" in Done|Merged|Shipped) pct="100" ;; esac
  printf '%s|%s|%s' "$st" "$pct" "$extra"
}

# _osrc_hub_emit_lane <json-args...> -> prints one lane object (jq -cn).
# All fields optional-empty are dropped by the caller-side jq merge.

_osrc_hub_lane_job() { # <id> -> lane json or nothing
  local id="$1" jd="$OSRC_JOBS/$1"
  [ -d "$jd" ] || return 1
  have jq || return 1
  local st meta verb prov model lane cwd wt br task_ref reason note ds
  st="$(_reconcile_status "$id" 2>/dev/null || cat "$jd/status" 2>/dev/null || echo '?')"
  meta="$jd/meta.json"
  prov="$(jq -r '.provider // ""' "$meta" 2>/dev/null)"
  model="$(jq -r '.model // ""' "$meta" 2>/dev/null)"
  lane="$(jq -r '.lane // .provider // ""' "$meta" 2>/dev/null)"
  verb="$(jq -r '.verb // ""' "$meta" 2>/dev/null)"
  wt="$(jq -r '.worktree // ""' "$meta" 2>/dev/null)"
  br="$(jq -r '.branch // ""' "$meta" 2>/dev/null)"
  task_ref="$(cat "$jd/task_ref" 2>/dev/null | head -1)"
  [ -f "$jd/worktree.json" ] && { wt="${wt:-$(jq -r '.path // ""' "$jd/worktree.json" 2>/dev/null)}"; br="${br:-$(jq -r '.branch // ""' "$jd/worktree.json" 2>/dev/null)}"; }
  reason="$(head -1 "$jd/reason" 2>/dev/null)"
  ds="$(_osrc_hub_done_state "$id")"
  [ "$ds" = "done" ] && st="done"
  local mapped; mapped="$(_osrc_hub_lane_status "$st" "" "${reason:-$st}")"
  local mstat="${mapped%%|*}"; mapped="${mapped#*|}"; local mpct="${mapped%%|*}"; note="${mapped#*|}"
  note="$(_osrc_hub_note "$note")"
  local short="${task_ref:-}"
  [ -n "$short" ] || short="${lane:-$prov} ${verb:-run} ${id##*-}"
  jq -cn --arg id "$id" --arg short "$short" --arg status "$mstat" --arg pct "$mpct" \
    --arg note "$note" --arg model "$model" --arg br "$br" --arg wt "$wt" \
    '{id:$id, short:$short, status:$status}
     + (if $pct=="" then {} else {pct:($pct|tonumber)} end)
     + (if $note=="" then {} else {note:$note} end)
     + (if $model=="" then {} else {model:$model} end)
     + (if $br=="" then {} else {branch:$br} end)
     + (if $wt=="" then {} else {worktree:$wt} end)'
}

_osrc_hub_lane_session() { # <id> -> lane json or nothing (tmux/autodetach target)
  local id="$1" st prov model state
  have tmux 2>/dev/null && tmux has-session -t "=$id" 2>/dev/null || return 1
  st="$(_owned_live_state "$id" 2>/dev/null)"
  ds=""; ds="$(_osrc_hub_done_state "$id")"; [ "$ds" = "done" ] && st="done"
  case "$st" in gone) return 1 ;; esac
  prov="$(type _session_registry_last_event >/dev/null 2>&1 && _session_registry_last_event "$id" 2>/dev/null | jq -r '.provider // ""' 2>/dev/null)"
  model="$(type _session_registry_last_event >/dev/null 2>&1 && _session_registry_last_event "$id" 2>/dev/null | jq -r '.resolved_model // .model // ""' 2>/dev/null)"
  local note=""
  if [ -s "$OSRC_HOME/autodetach/$id.rc" ]; then note="auto-detached run finished (rc $(cat "$OSRC_HOME/autodetach/$id.rc" 2>/dev/null | tr -dc '0-9'))"
  elif [ -f "$OSRC_HOME/autodetach/$id.log" ]; then note="auto-detached run"
  else note="interactive session"; fi
  local mapped; mapped="$(_osrc_hub_lane_status "$st" "" "$note")"
  local mstat="${mapped%%|*}"; mapped="${mapped#*|}"; local mpct="${mapped%%|*}"; note="${mapped#*|}"
  note="$(_osrc_hub_note "$note")"
  jq -cn --arg id "$id" --arg short "$id" --arg status "$mstat" --arg pct "$mpct" \
    --arg note "$note" --arg model "$model" --arg sess "$id" \
    '{id:$id, short:$short, status:$status, session:$sess}
     + (if $pct=="" then {} else {pct:($pct|tonumber)} end)
     + (if $note=="" then {} else {note:$note} end)
     + (if $model=="" then {} else {model:$model} end)'
}

_osrc_hub_lane_remote() { # <id> -> lane json or nothing
  local id="$1" f="$OSRC_HOME/remote/$id.json"
  [ -f "$f" ] || return 1
  have jq || return 1
  local st branch head head7 msg repo rv mapped mstat mpct note short
  if type osrc_remote_state >/dev/null 2>&1; then st="$(osrc_remote_state "$id" 2>/dev/null)"; else
    st="live"
    [ "$(jq -r '.branch_deleted // false' "$f")" = "true" ] && st="failed"
    [ "$(jq -r '.check.head // ""' "$f")" = "$(jq -r '.head // ""' "$f")" ] && [ "$(jq -r '.check.rc // 0' "$f")" != "0" ] && st="failed"
    [ "$(jq -r '.head_ready // false' "$f")" = "true" ] && st="ready"
  fi
  case "$st" in gone) return 1 ;; esac
  branch="$(jq -r '.branch // ""' "$f")"
  head="$(jq -r '.head // ""' "$f")"; head7="${head:0:7}"
  msg="$(_osrc_hub_note "$(jq -r '.head_msg // ""' "$f")")"
  repo="$(_osrc_hub_repo_name "$(jq -r '.repo // ""' "$f")" "$(jq -r '.url // ""' "$f")")"
  # Verdict from the review queue (L2) when present; ready+verdict refines the state.
  rv=""
  if type _osrc_review_verdict_for >/dev/null 2>&1 && [ -n "$head" ]; then
    rv="$(_osrc_review_verdict_for "$id" "$head" 2>/dev/null)"
  fi
  local raw="$st"
  [ "$st" = "ready" ] && [ -n "$rv" ] && raw="verdict-$rv"
  [ "$st" = "done" ] && [ -z "$rv" ] && rv="MERGE"
  mapped="$(_osrc_hub_lane_status "$raw" "$rv" "${msg:+$msg}${head7:+ @${head7}}")"
  mstat="${mapped%%|*}"; mapped="${mapped#*|}"; mpct="${mapped%%|*}"; note="${mapped#*|}"
  note="$(_osrc_hub_note "$note")"
  jq -cn --arg id "$id" --arg short "$id" --arg status "$mstat" --arg pct "$mpct" \
    --arg note "$note" --arg br "$branch" --arg repo "$repo" \
    '{id:$id, short:$short, status:$status}
     + (if $pct=="" then {} else {pct:($pct|tonumber)} end)
     + (if $note=="" then {} else {note:$note} end)
     + (if $br=="" then {} else {branch:$br} end)
     + (if $repo=="" then {} else {repo:$repo} end)'
}

_osrc_hub_lane_fallback() { # <id> -> lane json or nothing
  local id="$1" st
  st="$(_owned_live_state "$id" 2>/dev/null)"
  case "$st" in gone|"") return 1 ;; esac
  ds="$(_osrc_hub_done_state "$id")"; [ "$ds" = "done" ] && st="done"
  local mapped; mapped="$(_osrc_hub_lane_status "$st" "" "$st")"
  local mstat="${mapped%%|*}"; mapped="${mapped#*|}"; local mpct="${mapped%%|*}"; local note="${mapped#*|}"
  note="$(_osrc_hub_note "$note")"
  jq -cn --arg id "$id" --arg short "$id" --arg status "$mstat" --arg pct "$mpct" --arg note "$note" \
    '{id:$id, short:$short, status:$status}
     + (if $pct=="" then {} else {pct:($pct|tonumber)} end)
     + (if $note=="" then {} else {note:$note} end)'
}

# _osrc_hub_lane_for <id> <rmap> -> lane json: remote -> job -> session -> fallback.
_osrc_hub_lane_for() {
  local id="$1" rmap="$2"
  if [ -f "$OSRC_HOME/remote/$id.json" ]; then _osrc_hub_lane_remote "$id" && return 0; fi
  if [ -d "$OSRC_JOBS/$id" ]; then
    local lj; lj="$(_osrc_hub_lane_job "$id")" && { local rv; rv="$(_osrc_hub_review_verdict "$id" "$rmap")"; if [ -n "$rv" ]; then lj="$(jq -c --arg rv "$rv" '.status = (if $rv=="MERGE" then "Merged" elif $rv=="BLOCK" then "Blocked" else .status end) + {pct:(if $rv=="MERGE" then 100 else .pct end)}' <<<"$lj")"; fi; printf '%s' "$lj"; return 0; }
  fi
  _osrc_hub_lane_session "$id" && return 0
  _osrc_hub_lane_fallback "$id"
}

# ---- decisions + project card ---------------------------------------------------

# _osrc_hub_decisions <slug> -> normalized decisions JSON array.
_osrc_hub_decisions() {
  local f="$OSRC_HOME/hub/decisions/$1.json"
  [ -f "$f" ] || { printf '[]'; return 0; }
  jq -c 'if type=="array" then . elif (.decisions|type)=="array" then .decisions else [] end
    | map(. + {id:(.id // ""), status:(.status // "wait"), weight:(.weight // "Medium"),
               options:(.options // []), affects:(.affects // []), q:(.q // .short // ""),
               short:(.short // .q // "")})
    | to_entries | map(.value + {id:(.value.id // ("D" + ((.key+1)|tostring)))}) | map(del(.key))' \
    "$f" 2>/dev/null || printf '[]'
}

# _osrc_hub_card <slug> <decisions-file-json> -> project card fields JSON object.
_osrc_hub_card() {
  local slug="$1" decfile="$OSRC_HOME/hub/decisions/$1.json" pf="$OSRC_HOME/hub/projects/$1.json"
  local base='{}'
  # decisions file may carry name/tagline as a fallback when no projects file exists.
  if [ -f "$decfile" ]; then
    base="$(jq -c '{name:(.name // empty), tagline:(.tagline // empty)} | with_entries(select(.value != null and .value != ""))' "$decfile" 2>/dev/null || printf '{}')"
  fi
  if [ -f "$pf" ]; then
    base="$(jq -cn --argjson a "$base" --argjson b "$(jq -c '{name,tagline,order,repo,themes,flow,extraLinks,status,pct,eta,etaNote,lanes}
      | .extraLinks |= (if .==null then null else [.[]? | select(.url | type == "string" and startswith("https://"))] end)
      | with_entries(select(.value != null))' "$pf" 2>/dev/null || printf '{}')" '$a + $b')"
  fi
  printf '%s' "$base"
}

# _osrc_hub_apply_lane_overrides <lanes-json> <card-json> -> lanes with card.lanes overrides
# merged (only short/note/issues/theme may be overridden; status/pct/session stay computed).
_osrc_hub_apply_lane_overrides() {
  jq -c --argjson card "$2" '
    ($card.lanes // {}) as $ov |
    map(. as $l | ($ov[$l.id] // {}) as $o |
      $l + ($o | with_entries(select(.key as $k | ["short","note","issues","theme"] | index($k) != null))))' \
    <<<"$1" 2>/dev/null || printf '%s' "$1"
}

# _osrc_hub_build_project <slug> <now> <updated-str> -> one SCHEMA project doc.
_osrc_hub_build_project() {
  local slug="$1" now="$2" upd="$3"
  _osrc_hub_slug_ok "$slug" || return 1
  have jq || return 1
  local sid_dir="$OSRC_HOME/owners/$slug" lanes='[]' t lane
  local rmap; rmap="$(_osrc_hub_review_map)"
  if [ -d "$sid_dir" ]; then
    for t in "$sid_dir"/*; do
      [ -f "$t" ] || continue
      case "${t##*/}" in .*) continue ;; esac
      lane="$(_osrc_hub_lane_for "${t##*/}" "$rmap")"
      [ -n "$lane" ] && lanes="$(jq -cn --argjson a "$lanes" --argjson b "$lane" '$a + [$b]')"
    done
  fi
  local decs card out
  decs="$(_osrc_hub_decisions "$slug")"
  card="$(_osrc_hub_card "$slug")"
  lanes="$(_osrc_hub_apply_lane_overrides "$lanes" "$card")"
  # name: card > decisions-file already folded into card; fallback slug.
  local name order status pct eta etanote tagline repo themes flow extralinks
  name="$(jq -r '.name // ""' <<<"$card")"; [ -n "$name" ] || name="$slug"
  order="$(jq -r '.order // 99' <<<"$card")"
  status="$(jq -r '.status // ""' <<<"$card")"
  pct="$(jq -r '.pct // ""' <<<"$card")"
  eta="$(jq -r '.eta // ""' <<<"$card")"
  etanote="$(jq -r '.etaNote // ""' <<<"$card")"
  tagline="$(jq -r '.tagline // ""' <<<"$card")"
  repo="$(jq -r '.repo // ""' <<<"$card")"
  out="$(jq -cn \
    --arg id "$slug" --arg name "$name" --argjson order "$order" --arg upd "$upd" \
    --argjson now "$now" --argjson lanes "$lanes" --argjson decs "$decs" \
    --arg status "$status" --arg pct "$pct" --arg eta "$eta" --arg etanote "$etanote" \
    --arg tagline "$tagline" --arg repo "$repo" --argjson card "$card" '
    {id:$id, name:$name, order:$order, updated:$upd, exported_at:$now, lanes:$lanes, decisions:$decs}
    + (if $status=="" then {} else {status:$status} end)
    + (if $pct=="" then {} else {pct:($pct|tonumber)} end)
    + (if $eta=="" then {} else {eta:$eta} end)
    + (if $etanote=="" then {} else {etaNote:$etanote} end)
    + (if $tagline=="" then {} else {tagline:$tagline} end)
    + (if $repo=="" then {} else {repo:$repo} end)
    + (if ($card.themes|type)=="array" and ($card.themes|length)>0 then {themes:$card.themes} else {} end)
    + (if ($card.flow|type)=="array" and ($card.flow|length)>0 then {flow:$card.flow} else {} end)
    + (if ($card.extraLinks|type)=="array" and ($card.extraLinks|length)>0 then {extraLinks:$card.extraLinks} else {} end)
  ')"
  printf '%s' "$out"
}

# _osrc_hub_unowned_project -> project doc for targets no owner session claims
# (jobs launched without CLAUDE_CODE_SESSION_ID, remote lanes added the same way).
_osrc_hub_unowned_project() {
  local now="$1" upd="$2" rmap lanes='[]' id lane claimed
  rmap="$(_osrc_hub_review_map)"
  claimed="$(for d in "$OSRC_HOME"/owners/*/; do [ -d "$d" ] && for f in "$d"/*; do [ -f "$f" ] && basename "$f"; done; done 2>/dev/null)"
  # Unowned remote lanes.
  local rf
  for rf in "$OSRC_HOME"/remote/*.json; do
    [ -f "$rf" ] || continue
    id="$(basename "$rf" .json)"
    printf '%s\n' "$claimed" | grep -qxF "$id" && continue
    lane="$(_osrc_hub_lane_remote "$id")" && [ -n "$lane" ] && lanes="$(jq -cn --argjson a "$lanes" --argjson b "$lane" '$a+[$b]')"
  done
  # Unowned job dirs (recent or live only — ancient done dirs are gc's job, not the hub's).
  local jd st mt now_s
  now_s="$(date +%s)"
  for jd in "$OSRC_JOBS"/*/; do
    [ -d "$jd" ] || continue
    id="$(basename "$jd")"
    printf '%s\n' "$claimed" | grep -qxF "$id" && continue
    st="$(cat "$jd/status" 2>/dev/null || echo '?')"
    mt="$(stat -f %m "$jd" 2>/dev/null || stat -c %Y "$jd" 2>/dev/null || echo 0)"
    case "$st" in done|'done?'|failed|blocked|timeout|wedged|canceled|permission-blocked|interrupted)
      [ $(( now_s - ${mt:-0} )) -lt 86400 ] || continue ;; esac
    lane="$(_osrc_hub_lane_job "$id")" && [ -n "$lane" ] && lanes="$(jq -cn --argjson a "$lanes" --argjson b "$lane" '$a+[$b]')"
  done
  [ "$lanes" != "[]" ] || return 0
  local card; card="$(_osrc_hub_card unowned)"
  jq -cn --arg id unowned --arg name "Unowned runs" --argjson order 999 --arg upd "$upd" \
    --argjson now "$now" --argjson lanes "$lanes" --argjson decs '[]' --argjson card "$card" '
    {id:$id, name:$name, order:$order, updated:$upd, exported_at:$now, lanes:$lanes, decisions:$decs,
     tagline:"Runs launched without an owning orchestrator session."}'
}

# ---- commands --------------------------------------------------------------------

# cmd_hub_export [--project <slug>] -> SCHEMA docs JSON on stdout.
cmd_hub_export() {
  have jq || die "hub export needs jq"
  local proj="" a
  while [ "$#" -gt 0 ]; do case "$1" in --project) proj="${2:-}"; shift 2 ;; *) shift ;; esac; done
  [ -z "$proj" ] || _osrc_hub_slug_ok "$proj" || die "hub export: bad project slug '$proj'"
  local now upd projects='[]' slug found=0
  now="$(date +%s)"; upd="$(date '+%a %d %b, %H:%M')"
  # Slugs: every owner session + every decisions/projects file + unowned.
  local slugs=""
  local d f
  for d in "$OSRC_HOME"/owners/*/; do [ -d "$d" ] && slugs="$slugs $(basename "$d")"; done
  for f in "$OSRC_HOME"/hub/decisions/*.json "$OSRC_HOME"/hub/projects/*.json; do
    [ -f "$f" ] && slugs="$slugs $(basename "$f" .json)"
  done
  # de-dup
  slugs="$(printf '%s\n' $slugs | sort -u | tr '\n' ' ')"
  for slug in $slugs; do
    [ -n "$slug" ] || continue
    [ -n "$proj" ] && [ "$slug" != "$proj" ] && continue
    local pj; pj="$(_osrc_hub_build_project "$slug" "$now" "$upd")" || continue
    [ -n "$pj" ] && { projects="$(jq -cn --argjson a "$projects" --argjson b "$pj" '$a+[$b]')"; [ "$slug" = "$proj" ] && found=1; }
  done
  if [ -z "$proj" ]; then
    local uj; uj="$(_osrc_hub_unowned_project "$now" "$upd")"
    [ -n "$uj" ] && projects="$(jq -cn --argjson a "$projects" --argjson b "$uj" '$a+[$b]')"
  elif [ "$found" = 0 ]; then
    echo "hub export: no project '$proj' (slugs: owners/*, hub/decisions/*.json, hub/projects/*.json)" >&2
  fi
  jq -cn --argjson now "$now" --argjson ps "$projects" '{generated_at:$now, projects:$ps}'
}

# cmd_hub_serve [--port N] [--no-open] -> local Mission Control on 127.0.0.1.
cmd_hub_serve() {
  local port="${OSRC_HUB_PORT:-0}" noopen="${OSRC_HUB_NO_OPEN:-0}"
  while [ "$#" -gt 0 ]; do case "$1" in
    --port) port="${2:-}"; shift 2 ;;
    --no-open) noopen=1; shift ;;
    *) die "hub serve: unknown option '$1' (usage: hub serve [--port N] [--no-open])" ;;
  esac; done
  case "$port" in ''|*[!0-9]*) die "hub serve: --port must be a number (0 = pick a free one)" ;; esac
  have python3 || die "hub serve needs python3"
  local dir="${_OSRC_FACTORY_DIR:-$SCRIPT_DIR}"
  local server="$dir/lib/hub_server.py" page="$dir/lib/hub.html" engine="$dir/outsourcerer.sh"
  [ -f "$server" ] && [ -f "$page" ] && [ -f "$engine" ] \
    || die "hub files missing under $dir/lib (hub_server.py, hub.html) or $engine"
  local tok; tok="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$tok" ] || die "hub serve: cannot read /dev/urandom for the access token — refusing to run with a guessable one"
  export OSRC_HUB_TOKEN="$tok"
  local -a args=(--bind 127.0.0.1 --port "$port" --page "$page" --engine "$engine" --osrc-home "$OSRC_HOME")
  [ "$noopen" = 1 ] && args+=(--no-open)
  exec python3 -I "$server" "${args[@]}"
}

cmd_hub() {
  local sub="${1:-}"
  case "$sub" in
    export) shift; cmd_hub_export "$@" ;;
    serve) shift; cmd_hub_serve "$@" ;;
    *) die "hub: export [--project SLUG] | serve [--port N] [--no-open]" ;;
  esac
}
