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

# _osrc_hub_done_state <id> -> "done" | "" (uses osrc_done_state when defined). Inside an export the
# memo answers check:/pr: contracts from their last verdict (lib/hub-perf.sh): no probe on the clock.
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
    MERGE) st="Approved" ;; LANDED) st="Merged" ;;   # a verdict approves; only evidence of a merge says Merged
    BLOCK) st="Blocked" ;;
    CHANGES) st="Building"; extra="${extra:+$extra; }changes requested by review" ;;
  esac
  case "$st" in
    live|working|running|launching|stalled\?|exploring\?|no-progress-writes|ready)
      [ "$rv" = "" ] && [ "$st" = "ready" ] && st="Review" || st="Building" ;;
    idle) st="Idle" ;; paused) st="Paused"; extra="${extra:+$extra; }paused: free disk is under the floor" ;;
    waiting) st="Blocked"; extra="${extra:+$extra; }waiting on the orchestrator (approval, question or limit)" ;;
    done) st="Done" ;; 'done?') st="Unverified"; extra="${extra:+$extra; }finished without its done marker: check the result" ;;
    blocked|permission-blocked) st="Blocked" ;;
    failed|wedged|timeout) st="Failed" ;;
    canceled|interrupted) st="Canceled" ;;
    gone) st="" ;;
    Merged|Approved|Blocked|Done|Building|Review|Shipped|Idle|Failed|Canceled|Unverified|Paused|Closed) : ;;
    *) st="Building" ;;
  esac
  local pct=""
  case "$st" in Done|Merged|Shipped) pct="100" ;; esac
  printf '%s|%s|%s' "$st" "$pct" "$extra"
}

_osrc_hub_lane_job() { # <id> -> lane json or nothing
  local id="$1" jd="$OSRC_JOBS/$1"
  [ -d "$jd" ] || return 1
  have jq || return 1
  local st meta verb prov model lane cwd wt br task_ref reason note ds
  st="$(_osrc_hub_job_state "$id")"
  meta="$jd/meta.json"
  prov="$(jq -r '.provider // ""' "$meta" 2>/dev/null)"
  model="$(jq -r '.model // ""' "$meta" 2>/dev/null)"
  lane="$(jq -r '.lane // .provider // ""' "$meta" 2>/dev/null)"; _OSRC_LL=""; type _osrc_hub_lane_label >/dev/null 2>&1 && _osrc_hub_lane_label "$lane"
  verb="$(jq -r '.verb // ""' "$meta" 2>/dev/null)"
  wt="$(jq -r '.worktree // ""' "$meta" 2>/dev/null)"
  br="$(jq -r '.branch // ""' "$meta" 2>/dev/null)"
  task_ref="$(cat "$jd/task_ref" 2>/dev/null | head -1)"
  [ -f "$jd/worktree.json" ] && { wt="${wt:-$(jq -r '.path // ""' "$jd/worktree.json" 2>/dev/null)}"; br="${br:-$(jq -r '.branch // ""' "$jd/worktree.json" 2>/dev/null)}"; }
  reason="$(head -1 "$jd/reason" 2>/dev/null)"
  ds="$(_osrc_hub_done_state "$id")"
  if [ "$ds" = done ]; then st=done; else case "$st:$reason" in done:exited-0-without-OSRC-DONE*) st='done?' ;; esac; fi   # a verified contract wins; exit 0 alone is no proof
  _osrc_hub_paused "$id" "$st" && st=paused
  local mapped; mapped="$(_osrc_hub_lane_status "$st" "" "${reason:-$st}")"
  local mstat="${mapped%%|*}"; mapped="${mapped#*|}"; local mpct="${mapped%%|*}"; note="${mapped#*|}"
  note="$(_osrc_hub_note "$note")"
  [ "$mstat" = Building ] && local pn && pn="$(_osrc_disk_paused_note "$id" 2>/dev/null)" && { mstat=Blocked; note="$pn"; }
  local short="${task_ref:-}"
  [ -n "$short" ] || short="${lane:-$prov} ${verb:-run} ${id##*-}"
  jq -cn --arg id "$id" --arg short "$short" --arg status "$mstat" --arg pct "$mpct" \
    --arg note "$note" --arg model "$model" --arg br "$br" --arg wt "$wt" --arg ll "${_OSRC_LL:-}" \
    '{id:$id, short:$short, status:$status}
     + (if $pct=="" then {} else {pct:($pct|tonumber)} end)
     + (if $note=="" then {} else {note:$note} end)
     + ({model:$model, lane:$ll} | with_entries(select(.value != "")))
     + (if $br=="" then {} else {branch:$br} end)
     + (if $wt=="" then {} else {worktree:$wt} end)'
}

_osrc_hub_lane_session() { # <id> -> lane json or nothing (tmux/autodetach target)
  local id="$1" st model state
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "ls.$id.pre"
  # The export's memoised tmux list is the answer when it exists: a miss used to fall through to a
  # tmux has-session per candidate id (532 on a real state copy, ~30 s of a 58 s export).
  _osrc_ols_tmux_live "$id" || return 1
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "ls.$id.has"
  st="$(_owned_live_state "$id" 2>/dev/null)"
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "ls.$id.ols"
  ds=""; ds="$(_osrc_hub_done_state "$id")"; [ "$ds" = "done" ] && st="done"
  _osrc_hub_ad_failed "$id" && st=failed; _osrc_hub_paused "$id" "$st" && st=paused   # lib/hub-lanemeta.sh
  case "$st" in gone) return 1 ;; esac
  model="$(type _session_registry_last_event >/dev/null 2>&1 && _session_registry_last_event "$id" 2>/dev/null | jq -r '"\(.provider // "")\u001f\(.resolved_model // .model // "")"' 2>/dev/null)"
  _OSRC_LL=""; [ -z "${model%%$'\037'*}" ] || ! type _osrc_hub_lane_label >/dev/null 2>&1 || _osrc_hub_lane_label "${model%%$'\037'*}"; model="${model#*$'\037'}"
  local note=""
  if [ -s "$OSRC_HOME/autodetach/$id.rc" ]; then note="auto-detached run finished (rc $(cat "$OSRC_HOME/autodetach/$id.rc" 2>/dev/null | tr -dc '0-9'))"
  elif [ -f "$OSRC_HOME/autodetach/$id.log" ]; then note="auto-detached run"
  else note="interactive session"; fi
  local mapped; mapped="$(_osrc_hub_lane_status "$st" "" "$note")"
  local mstat="${mapped%%|*}"; mapped="${mapped#*|}"; local mpct="${mapped%%|*}"; note="${mapped#*|}"
  note="$(_osrc_hub_note "$note")"
  [ "$mstat" = Building ] && local pn && pn="$(_osrc_disk_paused_note "$id" 2>/dev/null)" && { mstat=Blocked; note="$pn"; }
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "ls.$id.jq0"
  jq -cn --arg id "$id" --arg short "$id" --arg status "$mstat" --arg pct "$mpct" \
    --arg note "$note" --arg model "$model" --arg sess "$id" --arg ll "${_OSRC_LL:-}" \
    '{id:$id, short:$short, status:$status, session:$sess}
     + (if $pct=="" then {} else {pct:($pct|tonumber)} end)
     + (if $note=="" then {} else {note:$note} end)
     + ({model:$model, lane:$ll} | with_entries(select(.value != "")))'
}

_osrc_hub_lane_remote() { # <id> -> lane json or nothing
  local id="$1" f; f="$OSRC_HOME/remote/$1.json"
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
  # One jq for the five fields (was five). \037 separates; tabs/newlines become spaces as the note does.
  local url veh model
  IFS=$'\037' read -r branch head msg repo url veh model < <(jq -r 'def c: (if type == "string" then . else tojson end) | sub("\n+$"; "") | gsub("[\t\n\u001f]"; " ");
    [(.branch // "" | c), (.head // "" | c), (.head_msg // "" | c), (.repo // "" | c), (.url // "" | c), (.vehicle // "" | c), (.model // "" | c)] | join("\u001f")' "$f" 2>/dev/null)
  _OSRC_LL=""; type _osrc_hub_lane_label >/dev/null 2>&1 && _osrc_hub_lane_label remote "$veh"
  head7="${head:0:7}"; msg="$(_osrc_hub_note "$msg")"
  repo="$(_osrc_hub_repo_name "$repo" "$url")"
  # Verdict from the review queue when present; ready+verdict refines the state.
  rv=""
  if type _osrc_review_verdict_for >/dev/null 2>&1 && [ -n "$head" ]; then
    rv="$(_osrc_review_verdict_for "$id" "$head" 2>/dev/null)"
  fi
  local raw="$st"
  [ "$st" = "ready" ] && [ -n "$rv" ] && raw="verdict-$rv"
  ! type _osrc_hub_landed >/dev/null 2>&1 || ! _osrc_hub_landed "$id" "$head" || rv=LANDED   # never inferred from done
  mapped="$(_osrc_hub_lane_status "$raw" "$rv" "${msg:+$msg}${head7:+ @${head7}}")"
  mstat="${mapped%%|*}"; mapped="${mapped#*|}"; mpct="${mapped%%|*}"; note="${mapped#*|}"
  note="$(_osrc_hub_note "$note")"
  jq -cn --arg id "$id" --arg short "$id" --arg status "$mstat" --arg pct "$mpct" \
    --arg note "$note" --arg br "$branch" --arg repo "$repo" --arg ll "${_OSRC_LL:-}" --arg model "$model" \
    '{id:$id, short:$short, status:$status}
     + (if $pct=="" then {} else {pct:($pct|tonumber)} end)
     + (if $note=="" then {} else {note:$note} end)
     + ({model:$model, lane:$ll} | with_entries(select(.value != "")))
     + (if $br=="" then {} else {branch:$br} end)
     + (if $repo=="" then {} else {repo:$repo} end)'
}

_osrc_hub_lane_fallback() { # <id> -> lane json or nothing
  local id="$1" st
  st="$(_owned_live_state "$id" 2>/dev/null)"
  case "$st" in gone|"") return 1 ;; esac
  ds="$(_osrc_hub_done_state "$id")"; [ "$ds" = "done" ] && st="done"
  _osrc_hub_ad_failed "$id" && st=failed; _osrc_hub_paused "$id" "$st" && st=paused
  local mapped; mapped="$(_osrc_hub_lane_status "$st" "" "$st")"
  local mstat="${mapped%%|*}"; mapped="${mapped#*|}"; local mpct="${mapped%%|*}"; local note="${mapped#*|}"
  note="$(_osrc_hub_note "$note")"
  jq -cn --arg id "$id" --arg short "$id" --arg status "$mstat" --arg pct "$mpct" --arg note "$note" \
    '{id:$id, short:$short, status:$status}
     + (if $pct=="" then {} else {pct:($pct|tonumber)} end)
     + (if $note=="" then {} else {note:$note} end)'
}

# _osrc_hub_lane_absent <id> -> rc 0 when an owner record names a lane with nothing left: no remote
# file, job dir, autodetach log/rc, review item or live tmux session. Every builder below then returns
# no row and _osrc_hub_lane_activity finds no file, so the caller can skip it. Fork-free on purpose: a
# real state copy held 532 such records, and the 3-4 subshells each cost ~37 s of a 71 s export.
_osrc_hub_lane_absent() {
  local id="$1" f
  [ -e "$OSRC_HOME/remote/$id.json" ] || [ -d "$OSRC_JOBS/$id" ] && return 1
  [ -e "$OSRC_HOME/autodetach/$id.log" ] || [ -e "$OSRC_HOME/autodetach/$id.rc" ] && return 1
  for f in "$OSRC_HOME/review/items/$id"-*.json; do [ -e "$f" ] && return 1; done
  # Only the export's memoised tmux list answers without a fork; without it, never claim absent.
  [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -f "$_OSRC_HUB_MEMO/tmux" ] || return 1
  _osrc_hub_tmux_row "$id" >/dev/null 2>&1 && return 1
  return 0
}

# _osrc_hub_lane_for_raw <id> <rmap> -> lane json: remote -> job -> session -> fallback (named by lib/hub-lanename.sh).
_osrc_hub_lane_for_raw() {
  local id="$1" rmap="$2"
  if [ -f "$OSRC_HOME/remote/$id.json" ]; then _osrc_hub_lane_remote "$id" && return 0; fi
  if [ -d "$OSRC_JOBS/$id" ]; then
    local lj; lj="$(_osrc_hub_lane_job "$id")" && { local rv; rv="$(_osrc_hub_review_verdict "$id" "$rmap")"; if [ -n "$rv" ]; then [ "$rv" != MERGE ] || ! type _osrc_hub_landed >/dev/null 2>&1 || ! _osrc_hub_landed "$id" || rv=LANDED; lj="$(jq -c --arg rv "$rv" 'if $rv == "LANDED" then . + {status: "Merged", pct: 100} elif $rv == "MERGE" then .status = "Approved" | del(.pct) elif $rv == "BLOCK" then .status = "Blocked" | del(.pct) else . end' <<<"$lj")"; fi; printf '%s' "$lj"; return 0; }
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
               options:(.options // []), affects:(if (.affects | type) == "array" then .affects elif (.affects | type) == "string" then [.affects] else [] end), q:(.q // .short // ""),
               short:(.short // .q // "")})
    | to_entries | map((.value.id // "") as $i | .value + {id:(if $i == "" then "D\(.key + 1)" else $i end)})' \
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
    base="$(jq -cn --argjson a "$base" --argjson b "$(jq -c '{name,tagline,order,repo,themes,flow,extraLinks,status,pct,eta,etaNote,next,reportedAt,shippedAt,summary,summaryAt,lanes,board,project}
      | .extraLinks |= (if .==null then null else [.[]? | select(.url | type == "string" and startswith("https://"))] end)
      | with_entries(select(.value != null))' "$pf" 2>/dev/null || printf '{}')" '$a + $b')"
  fi
  printf '%s' "$base"
}

# _osrc_hub_apply_lane_overrides <lanes-json> <card-json> -> lanes with card.lanes overrides
# merged (only short/note/issues/prs/theme may be overridden; status/pct/session stay computed).
_osrc_hub_apply_lane_overrides() {
  jq -c --argjson card "$2" '
    ($card.lanes // {}) as $ov |
    map(. as $l | ($ov[$l.id] // {}) as $o |
      $l + ($o | with_entries(select(.key as $k | ["short","note","issues","prs","theme"] | index($k) != null))))' \
    <<<"$1" 2>/dev/null || printf '%s' "$1"
}

# _osrc_hub_build_project <slug> <now> <updated-str> -> one SCHEMA project doc.
_osrc_hub_build_project() {
  local slug="$1" now="$2" upd="$3"
  _osrc_hub_slug_ok "$slug" || return 1
  have jq || return 1
  local sid_dir="$OSRC_HOME/owners/$slug" lanes='[]' olanes='' t lane act lact=0 llive=0
  type _osrc_hub_cache_get >/dev/null 2>&1 && _osrc_hub_cache_get "$slug" "$now" "$upd" && return 0   # settled project
  local rmap; rmap="$(_osrc_hub_review_map)"
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "proj.$slug.rmap"
  if [ -d "$sid_dir" ]; then
    for t in "$sid_dir"/*; do
      [ -f "$t" ] || continue
      case "${t##*/}" in .*|watch.*) continue ;; esac   # watch.*: a supervise --watch, not a lane
      _osrc_hub_lane_absent "${t##*/}" && continue   # nothing left of it: no row, no activity
      lane="$(_osrc_hub_lane_for "${t##*/}" "$rmap")"
      type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "lane.${t##*/}.for"
      [ -n "$lane" ] && type _osrc_hub_lane_live_fields >/dev/null 2>&1 && lane="$(_osrc_hub_lane_live_fields "$lane")"   # state + times
      type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "lane.${t##*/}.livef"
      [ -n "$lane" ] && type osrc_proof_hub_lane >/dev/null 2>&1 && lane="$(osrc_proof_hub_lane "$lane")"   # proof stamp (lib/proof.sh)
      type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "lane.${t##*/}.proof"
      [ -n "$lane" ] && olanes="$olanes$lane
"
      act="$(_osrc_hub_lane_activity "${t##*/}")"
      type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "lane.${t##*/}.done"
      [ "${act%% *}" -gt "$lact" ] 2>/dev/null && lact="${act%% *}"
      if [ "${act##* }" = 1 ] && ! jq -e '.state == "idle" or .state == "done" or .state == "failed" or
          (.status | IN("Done", "Merged", "Failed", "Canceled", "Shipped", "Unverified", "Closed"))' >/dev/null 2>&1 <<<"$lane"; then llive=1; fi
    done
  fi
  [ -z "$olanes" ] || lanes="$(printf '%s' "$olanes" | jq -cs . 2>/dev/null)" || lanes='[]'   # one jq, not one per lane
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "proj.$slug.owned"
  # Lanes that left the registry stay listed as finished for a while (lib/hub-report.sh).
  if type _osrc_hub_ended_ids >/dev/null 2>&1; then
    if type _osrc_hub_ended_lanes_fast >/dev/null 2>&1 && _osrc_hub_ended_lanes_fast "$slug" "$rmap"; then
      # Batched per-lane cache (lib/hub-fast.sh): same lanes, validated by one stat pass.
      lanes="$(jq -cn --argjson a "$lanes" --argjson b "${_OSRC_EL_LANES:-[]}" '$a + $b')"
      [ "${_OSRC_EL_LACT:-0}" -gt "$lact" ] 2>/dev/null && lact="$_OSRC_EL_LACT"
    else
      for t in $(_osrc_hub_ended_ids "$slug"); do
        lane="$(_osrc_hub_ended_lane "$t" "$rmap")"
        [ -n "$lane" ] && type osrc_proof_hub_lane >/dev/null 2>&1 && lane="$(osrc_proof_hub_lane "$lane")"
        [ -n "$lane" ] && lanes="$(jq -cn --argjson a "$lanes" --argjson b "$lane" '$a + [$b]')"
        act="$(_osrc_hub_lane_activity "$t")"; [ "${act%% *}" -gt "$lact" ] 2>/dev/null && lact="${act%% *}"
      done
    fi
  fi
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "proj.$slug.ended"
  local decs card out
  decs="$(_osrc_hub_decisions "$slug")"
  card="$(_osrc_hub_card "$slug")"
  lanes="$(_osrc_hub_apply_lane_overrides "$lanes" "$card")"
  ! type _osrc_hub_lanes_prs >/dev/null 2>&1 || lanes="$(_osrc_hub_lanes_prs "$lanes" "$(_osrc_hub_gh_slug "$(jq -r '.repo // ""' <<<"$card" 2>/dev/null)" 2>/dev/null)")"   # lib/hub-lanemeta.sh
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "proj.$slug.card"
  # name: card > decisions-file already folded into card; fallback slug.
  local name
  name="$(jq -r '.name // ""' "$OSRC_HOME/hub/projects/$slug.json" 2>/dev/null)"; [ -n "$name" ] || name="$(_osrc_hub_derived_name "$slug")"
  local upda stale_hours="${OSRC_HUB_STALE_HOURS:-24}" card_stale_min="${OSRC_CARD_STALE_MIN:-30}" dec_stale_h="${OSRC_DECISION_STALE_H:-2}"
  case "$stale_hours" in ''|*[!0-9]*) stale_hours=24 ;; esac
  case "$card_stale_min" in ''|*[!0-9]*) card_stale_min=30 ;; esac
  case "$dec_stale_h" in ''|*[!0-9]*) dec_stale_h=2 ;; esac
  upda="$(_osrc_hub_project_mtime "$slug" "$lact" "$llive")"
  local folder="" pf="$OSRC_HOME/hub/projects/$slug.json" derived
  derived="$(type _osrc_hub_derive >/dev/null 2>&1 && _osrc_hub_derive "$lanes" "$lact")"; [ -n "$derived" ] || derived=null
  local pmt=0   # a card without reportedAt reports at its file's mtime (formatted in the jq below)
  [ -f "$pf" ] && [ ! -L "$pf" ] && pmt="$(_osrc_hub_mt "$pf")"
  case "$pmt" in ''|*[!0-9]*) pmt=0 ;; esac
  type _osrc_hub_project_folder >/dev/null 2>&1 && folder="$(_osrc_hub_project_folder "$slug")"
  local stot=0
  type _osrc_hub_sessions_total >/dev/null 2>&1 && stot="$(_osrc_hub_sessions_total "$slug")"
  case "$stot" in ''|*[!0-9]*) stot=0 ;; esac
  # Card fields are read inside this one jq (they were eight jq calls): `s` is what `jq -r '.x // ""'`
  # printed, so values keep their old text form; an order that is not a number reads 99.
  out="$(jq -cn \
    --arg id "$slug" --arg name "$name" --arg upd "$upd" \
    --arg upda "$upda" --argjson live "$llive" --argjson staleHours "$stale_hours" \
    --argjson cardStaleMin "$card_stale_min" --argjson decisionStaleH "$dec_stale_h" \
    --argjson pmt "$pmt" --arg folder "$folder" --argjson stot "$stot" \
    --argjson now "$now" --argjson lanes "$lanes" --argjson decs "$decs" \
    --argjson card "$card" --argjson derived "$derived" '
    def s: (. // "") | if type == "string" then sub("\n+$"; "") else tojson end;
    ($card.order // 99 | if type == "number" then . elif type == "string" then (tonumber? // 99) else 99 end) as $order
    | ($card.status | s) as $status | ($card.pct | s) as $pct | ($card.eta | s) as $eta | ($card.etaNote | s) as $etanote
    | ($card.tagline | s) as $tagline | ($card.repo | s) as $repo
    | ($card.reportedAt | s | if . == "" and $pmt > 0 then ($pmt | todate) else . end) as $rep_at
    | {id:$id, name:$name, order:$order, updated:$upd, exported_at:$now, lanes:$lanes, decisions:$decs,
     liveLanes:$live, staleHours:$staleHours, cardStaleMin:$cardStaleMin, decisionStaleH:$decisionStaleH, sessionsTotal:$stot,
     sessionsRun:$stot, sessionsNow:([$lanes[]? | select(((.status // "") | test("^(done|merged|approved|shipped|canceled|cancelled|failed|stopped|idle|closed)$"; "i") | not) and ((.state // "") != "idle"))] | length)}
    + (if $upda=="" then {} else {updatedAt:$upda} end)
    + (if $rep_at=="" then {} else {reportedAt:$rep_at} end)
    + (if $folder=="" then {} else {folder:$folder} end)
    + (if $status=="" then {} else {status:$status} end)
    + (if $pct=="" then {} else {pct:($pct|tonumber)} end)
    + (if $eta=="" then {} else {eta:$eta} end)
    + (if $etanote=="" then {} else {etaNote:$etanote} end)
    + (if $tagline=="" then {} else {tagline:$tagline} end)
    + (if $repo=="" then {} else {repo:$repo} end)
    + (if ($card.themes|type)=="array" and ($card.themes|length)>0 then {themes:$card.themes} else {} end)
    + (if ($card.flow|type)=="array" and ($card.flow|length)>0 then {flow:$card.flow} else {} end)
    + (if ($card.extraLinks|type)=="array" and ($card.extraLinks|length)>0 then {extraLinks:$card.extraLinks} else {} end)
    + (if ($card.next|type)=="string" and $card.next!="" then {next:$card.next} else {} end)
    + (if ($card.shippedAt|type)=="string" then {shippedAt:$card.shippedAt} else {} end)
    + (if ($card.summary|type)=="string" and $card.summary!="" then {summary:$card.summary} + (if ($card.summaryAt|type)=="string" then {summaryAt:$card.summaryAt} else {} end) else {} end)
    + (if $derived == null then {} else {derived:$derived} end)
    + ($card | {status, pct, eta, next, summary} | with_entries(select(.value != null and .value != "")) | if length > 0 then {reported:.} else {} end)
    + (if ($card.project|type)=="string" and $card.project!="" then {projectKey:$card.project} else {} end)
  ')"
  # No live lane and no status of its own -> idle. A status the card or a Mark done / Move back set is kept
  # exactly (relabelling an explicit "building" undid Move back).
  ! type osrc_proof_hub_counts >/dev/null 2>&1 || out="$(jq -c --argjson c "$(osrc_proof_hub_counts "$lanes")" '. + $c' <<<"$out")"
  ! type _osrc_hub_apply_board >/dev/null 2>&1 || out="$(_osrc_hub_apply_board "$out" "$card")"   # the orchestrator's board drives the page (lib/hub_board.sh)
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "proj.$slug.board"
  out="$(_osrc_hub_status_override "$slug" "$out")"   # status left empty here is derived later (_osrc_hub_truth)
  out="$(_osrc_hub_annotate_freshness "$out" "$now" "$card_stale_min" "$dec_stale_h")"
  ! type osrc_mc_alerts >/dev/null 2>&1 || out="$(osrc_mc_alerts "$slug" "$out")"   # needs-you alerts + watcher gap (lib/mc_alive.sh)
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "proj.$slug.alerts"
  printf '%s\n' "$out"
  type _osrc_hub_cache_put >/dev/null 2>&1 && _osrc_hub_cache_put "$slug" "$out"
  return 0
}

# _osrc_hub_annotate_freshness <project-json> <now-epoch> <card-stale-min> <decision-stale-h>:
# Marks stale cards (hiding stale Next text), marks stale open decisions without ever closing them,
# and tags quiet projects (no live lane, no open decision, no card update in 24 h). Never edits disk.
_osrc_hub_annotate_freshness() {
  local pj="$1" now="$2" cmin="${3:-30}" dh="${4:-2}"
  case "$cmin" in ''|*[!0-9]*) cmin=30 ;; esac
  case "$dh" in ''|*[!0-9]*) dh=2 ;; esac
  jq -c --argjson now "$now" --argjson cmin "$cmin" --argjson dh "$dh" '
    def iso_ep: if type == "string" and length > 0 then (sub("\\.[0-9]+"; "") | fromdateiso8601? // null) else null end;
    (.reportedAt | iso_ep) as $rep
    | ((has("next") or has("eta") or has("pct") or has("boardTracks") or (.cardStale // false))
       and (.status != "shipped") and ($rep != null) and (($now - $rep) >= ($cmin * 60))) as $cst
    | (.reportedAt // null) as $prep
    | . + {cardStaleMin:$cmin, decisionStaleH:$dh, cardStale:$cst}
    | (if $cst then . + {cardAgeMin:((($now - $rep) / 60) | floor)} | del(.next) else del(.cardAgeMin) end)
    | .decisions |= (if type == "array" then map(
        if (.status // "wait") == "done" then .
        else
          ((.confirmedAt // .askedAt // $prep // "") | iso_ep) as $dep
          | (if (.askedAt // "") == "" and (.confirmedAt // "") == "" and ($prep | type) == "string" then . + {askedAt:$prep} else . end)
          | if $dep != null and (($now - $dep) >= ($dh * 3600)) then
              . + {stale:true, staleHours:((($now - $dep) / 3600) | floor)}
            else
              . + {stale:false} | del(.staleHours)
            end
        end) else [] end)
    | (((.liveLanes // 0) > 0)
       or ([.decisions[]? | select((.status // "wait") != "done")] | length > 0)
       or ($rep != null and (($now - $rep) < ((.staleHours // 24) * 3600)))) as $active
    | . + {quiet: ((.status != "shipped") and ($active | not))}
  ' <<<"$pj" 2>/dev/null || printf '%s' "$pj"
}

# _osrc_hub_status_override <slug> <project-json> -> project with the user's Mark done
# override from $OSRC_HOME/hub/status/<slug>.json (written by hub_server.py) merged LAST,
# so no card/orchestrator write can change a status whose shippedBy is "user".
# A Move back ("restore") record carries what the card said about shipping at click time
# (cardStatus, cardShippedAt). It holds through any number of card rewrites and yields only
# when the card says something new about shipping. Symlinks (the status folder or
# the file) are never followed.
_osrc_hub_status_override() {
  local d="$OSRC_HOME/hub/status" pf="$OSRC_HOME/hub/projects/$1.json" card='{}'
  local f="$d/$1.json"
  { [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$f" ] && [ ! -L "$f" ]; } || { printf '%s' "$2"; return 0; }
  { [ -f "$pf" ] && [ ! -L "$pf" ]; } && card="$(jq -c 'if type == "object" then {status, shippedAt} else {} end' "$pf" 2>/dev/null || printf '{}')"
  jq -c --slurpfile o "$f" --argjson card "$card" '
    ($o[0] // {}) as $o
    | (if ($o.prevStatus // "") == "" or $o.prevStatus == "shipped" then "building" else $o.prevStatus end) as $prev
    | if ($o | type) != "object" then .
      elif $o.shippedBy == "user" then
        . + {status:"shipped", shippedBy:"user", shippedAt:($o.shippedAt // null), prevStatus:$prev}
      elif $o.restoredBy == "user" and ($o | has("cardStatus")) and .status == "shipped"
           and ($card.status // null) == ($o.cardStatus // null)
           and ($card.shippedAt // null) == ($o.cardShippedAt // null) then
        .status = $prev
      else . end' <<<"$2" 2>/dev/null || printf '%s' "$2"
}

# _osrc_hub_mt <path...> -> newest mtime (epoch) of the paths that exist, 0 when none. Stat only.
_osrc_hub_mt() {
  local b=0 f m out
  local -a ex=()
  for f in "$@"; do [ -e "$f" ] && ex+=("$f"); done
  [ "${#ex[@]}" -gt 0 ] || { printf '0'; return 0; }
  # ONE stat for the whole list (a fork per path was ~480 forks per export). GNU first: GNU `stat -f`
  # is filesystem status. A path that vanished since the -e test only drops its own line.
  out="$(stat -c %Y "${ex[@]}" 2>/dev/null)"; [ -n "$out" ] || out="$(stat -f %m "${ex[@]}" 2>/dev/null)"
  for m in $out; do [ "$m" -gt "$b" ] 2>/dev/null && b="$m"; done
  printf '%s' "$b"
}

# (here, not in hub-perf.sh, because suites source hub.sh alone.)
# _osrc_hub_reg_ts <id> -> newest registry ts (epoch) for the id, "" when unknown. Uses the memo index
# when open; returns 1 when no index exists so the caller can fall back to its own scan.
_osrc_hub_reg_ts() {
  [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -f "$_OSRC_HUB_MEMO/reg/.indexed" ] || return 1
  cat "$_OSRC_HUB_MEMO/reg/$1.ts" 2>/dev/null
  return 0
}

# _osrc_hub_tmux_row <id> -> "<created> <activity>" for a live tmux session (memo list, else tmux).
_osrc_hub_tmux_row() {
  if [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -f "$_OSRC_HUB_MEMO/tmux" ]; then
    # Fork-free: runs once per candidate id (hundreds per export). read -d '' loads the list with no
    # subshell; a miss is the common case and returns before any parsing.
    local tab="" l _n=$'\n'; IFS= read -r -d '' tab < "$_OSRC_HUB_MEMO/tmux"
    case "$_n$tab" in *"$_n$1 "*) ;; *) return 1 ;; esac
    while IFS= read -r l; do
      case "$l" in "$1 "*) set -- $l; printf '%s %s\n' "$2" "$3"; return 0 ;; esac
    done <<< "$tab"
    return 1
  else
    tmux has-session -t "=$1" 2>/dev/null && tmux display-message -p -t "=$1" '#{session_created} #{window_activity}' 2>/dev/null
  fi
}

# _osrc_hub_lane_activity <id> -> "<epoch> <live>": newest real activity of one owned lane (job dir files:
# meta.json, log, rc, status..., remote lane file, its review items, autodetach log/rc, tmux session_activity)
# and live=1 when the lane is working right now (a reconciled running job, a live remote lane, a working
# tmux session). A busy project must never look stale because its card was not rewritten.
_osrc_hub_lane_activity() {
  local id="$1" b live=0 st ta
  b="$(_osrc_hub_mt "$OSRC_JOBS/$id"/* "$OSRC_HOME/remote/$id.json" "$OSRC_HOME/review/items/$id"-*.json "$OSRC_HOME/autodetach/$id.log" "$OSRC_HOME/autodetach/$id.rc")"
  if [ -d "$OSRC_JOBS/$id" ]; then
    st="$(_osrc_hub_job_state "$id")"
    case "$st" in running|live|working|launching|exploring\?) live=1 ;; esac   # stalled?, no-progress-writes: not activity
  elif [ -f "$OSRC_HOME/remote/$id.json" ]; then
    type osrc_remote_state >/dev/null 2>&1 && [ "$(osrc_remote_state "$id" 2>/dev/null)" = live ] && live=1
  elif have tmux 2>/dev/null && ta="$(_osrc_hub_tmux_row "$id")" && [ -n "$ta" ]; then
    ta="${ta##* }"
    case "$ta" in ''|*[!0-9]*) ;; *) [ "$ta" -gt "$b" ] && b="$ta" ;; esac
    case "$(_owned_live_state "$id" 2>/dev/null)" in working|live|running) live=1 ;; esac
  fi
  # Session registry events and the done contract + its file hand-in are activity too.
  local dc="$OSRC_HOME/done/$id.json" spec cwd hf r
  r="$(_osrc_hub_mt "$dc")"; [ "$r" -gt "$b" ] && b="$r"
  if [ -f "$dc" ] && have jq; then
    spec="$(jq -r '.spec // ""' "$dc" 2>/dev/null)"; cwd="$(jq -r '.cwd // ""' "$dc" 2>/dev/null)"
    case "$spec" in file:*) hf="${spec#file:}"; case "$hf" in /*) ;; *) hf="${cwd:-.}/$hf" ;; esac
      r="$(_osrc_hub_mt "$hf")"; [ "$r" -gt "$b" ] && b="$r" ;; esac
  fi
  if r="$(_osrc_hub_reg_ts "$id")"; then
    case "$r" in ''|*[!0-9]*) ;; *) [ "$r" -gt "$b" ] && b="$r" ;; esac
  elif [ -f "${OSRC_SESSION_REGISTRY:-}" ] && have jq; then
    r="$(jq -r --arg id "$id" 'select(.session_id==$id) | .ts // empty | if type=="number" then floor else (try fromdateiso8601 catch empty) end' "$OSRC_SESSION_REGISTRY" 2>/dev/null | sort -n | tail -1)"
    case "$r" in ''|*[!0-9]*) ;; *) [ "$r" -gt "$b" ] && b="$r" ;; esac
  fi
  # A satisfied done contract ends "working" for every lane kind, not only jobs.
  [ "$live" = 1 ] && [ "$(_osrc_hub_done_state "$id")" = done ] && live=0
  printf '%s %s' "$b" "$live"
}

# _osrc_hub_project_mtime <slug> [lane-activity-epoch] [live] -> ISO-8601 of the project's newest real
# activity: its inputs (owner links, card, decisions) and its owned lanes' activity. A live
# working lane makes it "now": stale means nothing moved. "" when nothing exists. Feeds the page's alarm.
_osrc_hub_project_mtime() {
  local slug="$1" best=0 la="${2:-0}"
  _osrc_hub_slug_ok "$slug" || { printf ''; return 0; }
  best="$(_osrc_hub_mt "$OSRC_HOME/owners/$slug"/* "$OSRC_HOME/hub/seen/$slug/.beat" "$OSRC_HOME/hub/projects/$slug.json" "$OSRC_HOME/hub/decisions/$slug.json" "$HOME"/.claude/projects/*/"$slug".jsonl)"
  [ "$la" -gt "$best" ] 2>/dev/null && best="$la"
  [ "${3:-0}" = 1 ] && best="$(date +%s)"
  [ "$best" -gt 0 ] || { printf ''; return 0; }
  date -u -r "$best" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$best" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf ''
}

# _osrc_hub_unowned_project -> project doc for targets no owner session claims
# (jobs launched without CLAUDE_CODE_SESSION_ID, remote lanes added the same way).
_osrc_hub_unowned_project() {
  local now="$1" upd="$2" rmap lanes='[]' id lane claimed
  # Under hub serve, skip the whole scan when no unclaimed lane can be live: the caller drops a doc
  # whose liveLanes is 0 anyway, so building every unclaimed remote/job lane is work thrown away.
  if [ "${OSRC_HUB_FAST:-0}" = 1 ] && type _osrc_hub_unowned_has_live >/dev/null 2>&1 \
      && ! _osrc_hub_unowned_has_live; then
    return 0
  fi
  rmap="$(_osrc_hub_review_map)"
  local _nl='
'
  claimed="$(for d in "$OSRC_HOME"/owners/*/; do [ -d "$d" ] && for f in "$d"/*; do [ -f "$f" ] && printf '%s\n' "${f##*/}"; done; done 2>/dev/null)"
  # Unowned remote lanes.
  local rf
  for rf in "$OSRC_HOME"/remote/*.json; do
    [ -f "$rf" ] || continue
    id="$(basename "$rf" .json)"
    case "$_nl$claimed$_nl" in *"$_nl$id$_nl"*) continue ;; esac   # no grep per dir
    lane="$(_osrc_hub_lane_remote "$id")" && [ -n "$lane" ] && lanes="$(jq -cn --argjson a "$lanes" --argjson b "$lane" '$a+[$b]')"
  done
  # Unowned job dirs (recent or live only — ancient done dirs are gc's job, not the hub's).
  local jd st mt now_s
  now_s="$(date +%s)"
  for jd in "$OSRC_JOBS"/*/; do
    [ -d "$jd" ] || continue
    id="$(basename "$jd")"
    case "$_nl$claimed$_nl" in *"$_nl$id$_nl"*) continue ;; esac   # no grep per dir
    st="$(cat "$jd/status" 2>/dev/null || echo '?')"
    mt="$(stat -c %Y "$jd" 2>/dev/null || stat -f %m "$jd" 2>/dev/null || echo 0)"
    case "$st" in done|'done?'|failed|blocked|timeout|wedged|canceled|permission-blocked|interrupted)
      [ $(( now_s - ${mt:-0} )) -lt 86400 ] || continue ;; esac
    lane="$(_osrc_hub_lane_job "$id")" && [ -n "$lane" ] && lanes="$(jq -cn --argjson a "$lanes" --argjson b "$lane" '$a+[$b]')"
  done
  [ "$lanes" != "[]" ] || return 0
  local card upda live=0 act; card="$(_osrc_hub_card unowned)"
  for id in $(jq -r '.[].id' <<<"$lanes"); do act="$(_osrc_hub_lane_activity "$id")"; [ "${act##* }" = 1 ] && live=1; done
  upda="$(_osrc_hub_project_mtime unowned 0 "$live")"
  jq -cn --arg id unowned --arg name "Unowned runs" --argjson order 999 --arg upd "$upd" \
    --arg upda "$upda" --argjson live "$live" \
    --argjson now "$now" --argjson lanes "$lanes" --argjson decs '[]' --argjson card "$card" '
    {id:$id, name:$name, order:$order, updated:$upd, exported_at:$now, lanes:$lanes, decisions:$decs,
     tagline:"Runs launched without an owning orchestrator session.", liveLanes:$live, status:(if $live == 1 then "building" else "idle" end)}
    + (if $upda=="" then {} else {updatedAt:$upda} end)'
}

# ---- limits (the Lanes and limits rail) ------------------------------------------

# _osrc_hh_mm <epoch-seconds> -> "HH:MM" within 36h, else "Fri HH:MM"; empty input -> "".
_osrc_hh_mm() {
  case "${1:-}" in ''|*[!0-9]*) printf ''; return 0 ;; esac
  local now=$(( $(date +%s) ))
  # One clock across the page: the viewer's local time (was UTC).
  if [ $(( $1 - now )) -le 129600 ]; then
    date -r "$1" '+%H:%M' 2>/dev/null || date -d "@$1" '+%H:%M' 2>/dev/null
  else
    date -r "$1" '+%a %H:%M' 2>/dev/null || date -d "@$1" '+%a %H:%M' 2>/dev/null
  fi
}

# _osrc_hub_now_stamp -> the export's display stamp, local ("23:00"; lib/hub-report.sh), else local %a %d %b, %H:%M.
_osrc_hub_now_stamp() { if type _osrc_hub_stamp >/dev/null 2>&1; then _osrc_hub_stamp; else date '+%a %d %b, %H:%M'; fi; }

# _osrc_hub_renews <epoch> -> "in 4 days · Thu 19 Nov" / "today · 18:40" (lib/hub-report.sh), else HH:MM.
_osrc_hub_renews() { if type _osrc_renew_text >/dev/null 2>&1; then _osrc_renew_text "$1"; else _osrc_hh_mm "$1"; fi; }

# _osrc_limit_state <pct-used> [resets_at-epoch] -> ok|low|out|wait|unknown.
# Boundaries mirror the limits meter: <50 working, 50-89 running low, >=90 spent — `wait`
# (waiting for reset) when the window publishes a reset time, else `out`.
# Anything unreadable is `unknown`, never invented.
_osrc_limit_state() {
  case "${1:-}" in ''|*[!0-9.]*) printf 'unknown'; return 0 ;; esac
  if awk -v p="$1" 'BEGIN{ exit !(p>=90) }'; then
    case "${2:-}" in ''|*[!0-9]*) printf 'out' ;; *) printf 'wait' ;; esac
  elif awk -v p="$1" 'BEGIN{ exit !(p>=50) }'; then printf 'low'; else printf 'ok'; fi
}

# _osrc_limit_row <id> <name> <state> <left> <renews|renews_at-epoch> <models> <note> <paid> <order> <updated> [source] [updatedAt-ISO]
_osrc_limit_row() {
  local bill=unknown token=''
  case "$1" in claude*) token=cc ;; chatgpt*) token=cx ;; devin) token=dv ;; agy) token=gm ;; openrouter) token=or ;; local) token=local ;; esac
  if [ -n "$token" ] && type osrc_lane_billing >/dev/null 2>&1; then bill="$(osrc_lane_billing "$token" 2>/dev/null)"; fi
  [ "$1" != openrouter ] || bill=metered
  [ "$1" != local ] || bill=free
  local rat=""; case "${5:-}" in *[!0-9]*|'') ;; *) rat="$5" ;; esac   # an epoch travels as renews_at
  jq -cn --arg billing "${bill:-unknown}" --arg id "$1" --arg name "$2" --arg state "$3" --arg left "$4" --arg renews "$([ -n "$rat" ] && _osrc_hub_renews "$rat" || printf '%s' "${5:-}")" --arg rat "$rat" \
        --arg models "$6" --arg note "$7" --argjson paid "${8:-false}" --argjson order "${9:-99}" --arg updated "${10}" --arg source "${11:-}" \
        --arg upda "${12:-}" \
    '{id:$id,name:$name,state:$state,order:$order,billing:$billing}
     + (if $left=="" then {} else {left:$left} end)
     + (if $renews=="" then {} else {renews:$renews} end) + (if $rat=="" then {} else {renews_at:($rat|tonumber)} end)
     + (if $models=="" then {} else {models:$models} end)
     + (if $note=="" then {} else {note:$note} end)
     + (if $updated=="" then {} else {updated:$updated} end)
     + (if $source=="" then {} else {source:$source} end)
     + (if $upda=="" then {} else {updatedAt:$upda} end)
     + (if $paid then {paid:true} else {} end)'
}

# _osrc_hub_limits -> JSON array for the rail's "Lanes and limits" panel.
# Preferred feed: `osrc_limits_summary --json` (lib/spend.sh) — one live
# record per detected harness, recomputed on every export/poll. Its `updated`
# is an ISO checked-at; we mirror it into `updatedAt` (what the page's stale
# stamp parses) and trim the display field to HH:MM. When spend.sh is not
# loaded, rows are built below from the same meter sources.
_osrc_hub_limits() {
  have jq 2>/dev/null || { printf '[]'; return 0; }
  if type osrc_limits_summary >/dev/null 2>&1; then
    local lsum; lsum="$(osrc_limits_summary --json 2>/dev/null)"
    # An EMPTY feed is not authoritative: it lists only provably-logged-in harnesses,
    # while the local builder below also covers artifact-evidenced rows (rate-limits
    # files, paid keys, installed-but-unmetered lanes). Fall back on [] too.
    if [ -n "$lsum" ] && jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"$lsum"; then
      jq -c '[.[] | . + {updatedAt: (.updatedAt // .updated // "")}
               | (if (.updated | type == "string") and (.updated | test("T")) then .updated = ((.updated | fromdateiso8601? // null) as $e | if $e then ($e | strflocaltime("%H:%M")) else .updated[11:16] end) else . end)]' <<<"$lsum"   # local
      return 0
    fi
  fi
  _osrc_hub_limits_local
}

# _osrc_hub_limits_local -> rows built from the raw meter sources (fallback when
# lib/spend.sh is not loaded). Rows exist only for lanes detected for this user
# (installed AND logged in — the meter artifacts are themselves login
# evidence). Metered rows read the meter sources: the claude rate-limits artifact
# ($OSRC_HOME/rate-limits.json, then the token-optimizer copy — same
# precedence, 10-min freshness gate), and the _session_limits/
# _codex_rate_limits when lib/limits.sh is loaded for the ChatGPT windows. A
# stale or missing reading is `unknown`, never invented; Gemini CLI is retired
# and never listed. OpenRouter carries the paid tag.
_osrc_hub_limits_local() {
  have jq 2>/dev/null || { printf '[]'; return 0; }
  local now ts_ms stale c5='' c5r='' c7='' c7r='' cand raw arr='[]' upd='' upda='' src='statusline'
  now="$(date +%s)"
  # Claude windows: first fresh artifact wins.
  for cand in "$OSRC_HOME/rate-limits.json" "$HOME/.claude/token-optimizer/rate-limits.json"; do
    [ -f "$cand" ] && jq -e . "$cand" >/dev/null 2>&1 || continue
    raw="$(jq -r '"\(.five_hour.used_percentage // "")|\(.five_hour.resets_at // "")|\(.seven_day.used_percentage // "")|\(.seven_day.resets_at // "")|\(.timestamp // "")|\(.source // "statusline")"' "$cand" 2>/dev/null)"
    IFS='|' read -r c5 c5r c7 c7r ts_ms src <<EOF
$raw
EOF
    # Expired windows reset the reading rather than report an old percentage.
    case "$c5r" in ''|*[!0-9]*) : ;; *) [ "$c5r" -lt "$now" ] && c5="" ;; esac
    case "$c7r" in ''|*[!0-9]*) : ;; *) [ "$c7r" -lt "$now" ] && c7="" ;; esac
    case "$ts_ms" in ''|*[!0-9]*) stale=1; upd=""; upda="" ;;
      *) [ $(( now - ts_ms / 1000 )) -gt 600 ] && stale=1 || stale=0
         upd="$(date -r $(( ts_ms / 1000 )) '+%H:%M' 2>/dev/null || date -d "@$(( ts_ms / 1000 ))" '+%H:%M' 2>/dev/null)"   # local
         upda="$(date -u -r $(( ts_ms / 1000 )) '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$(( ts_ms / 1000 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" ;;
    esac
    [ -n "$c5$c7" ] || stale=1
    [ "$stale" = 0 ] && break
  done
  local st leftr
  if [ -n "$c5$c7" ]; then
    local note5 note7
    note5="Session window, resets every 5 hours."
    note7="Weekly window — the binding cap in practice."
    [ "${stale:-1}" = 1 ] && { note5="$note5 Last reading is stale — treated as not checked, not exhausted."; note7="$note7 Last reading is stale — treated as not checked, not exhausted."; }
    if [ -n "$c5" ]; then
      st="$(_osrc_limit_state "$c5" "$c5r")"; [ "$stale" = 1 ] && st=unknown
      leftr="$(( 100 - ${c5%.*} ))% left"; [ "${c5%.*}" -ge 100 ] 2>/dev/null && leftr="0% left"
      arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row claude-5h 'Claude Code — 5 hour' "$st" "$leftr" "$c5r" 'claude-* on your Claude subscription' "$note5" false 1 "$upd" "$src" "$upda")" '$a+[$b]')"
    fi
    if [ -n "$c7" ]; then
      st="$(_osrc_limit_state "$c7" "$c7r")"; [ "$stale" = 1 ] && st=unknown
      leftr="$(( 100 - ${c7%.*} ))% left"; [ "${c7%.*}" -ge 100 ] 2>/dev/null && leftr="0% left"
      arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row claude-weekly 'Claude Code — weekly' "$st" "$leftr" "$c7r" 'claude-* on your Claude subscription' "$note7" false 2 "$upd" "$src" "$upda")" '$a+[$b]')"
    fi
  elif command -v claude >/dev/null 2>&1 || [ -d "$HOME/.claude" ]; then
    arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row claude 'Claude Code' unknown '' '' 'claude-* on your Claude subscription' 'Installed but no fresh limit reading — the statusline artifact is missing or over 10 minutes old.' false 1 '' '')" '$a+[$b]')"
  fi
  # ChatGPT windows via the normalized reader when it is loaded; codexage marks
  # a stale reading (a floor, never a measurement).
  local lim tok x5='' xw='' xage='' xraw x5r='' xwr=''
  if type _session_limits >/dev/null 2>&1; then
    lim="$(_session_limits 2>/dev/null)"
    for tok in $lim; do case "$tok" in codex5h=*) x5="${tok#*=}" ;; codexwk=*) xw="${tok#*=}" ;; codexage=*) xage="${tok#*=}" ;; esac; done
    if type _codex_rate_limits >/dev/null 2>&1; then
      xraw="$(_codex_rate_limits 2>/dev/null)" || xraw=''
      case "$xraw" in *\|*) x5r="$(printf '%s' "$xraw" | cut -d'|' -f3)"; xwr="$(printf '%s' "$xraw" | cut -d'|' -f4)" ;; esac
    fi
  fi
  if [ -n "$x5$xw" ]; then
    local updx=''
    case "$xage" in ''|*[!0-9]*) ;; *) updx="$(date -u -r $(( now - xage )) '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$(( now - xage ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" ;; esac
    if [ -n "$x5" ]; then
      st="$(_osrc_limit_state "$x5" "$x5r")"; [ -n "$xage" ] && st=unknown
      leftr="$(( 100 - ${x5%.*} ))% left"; [ "${x5%.*}" -ge 100 ] 2>/dev/null && leftr="0% left"
      arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row chatgpt-5h 'ChatGPT — 5 hour' "$st" "$leftr" "$x5r" 'sol, terra, gpt-5.* on your ChatGPT plan' "$([ -n "$xage" ] && printf 'Reading is %ss old — a floor, not a measurement.' "$xage" || printf 'Session window, resets every 5 hours.')" false 3 "$upd" 'codex rollout' "$updx")" '$a+[$b]')"
    fi
    if [ -n "$xw" ]; then
      st="$(_osrc_limit_state "$xw" "$xwr")"; [ -n "$xage" ] && st=unknown
      leftr="$(( 100 - ${xw%.*} ))% left"; [ "${xw%.*}" -ge 100 ] 2>/dev/null && leftr="0% left"
      arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row chatgpt-weekly 'ChatGPT — weekly' "$st" "$leftr" "$xwr" 'sol, terra, gpt-5.* on your ChatGPT plan' "$([ -n "$xage" ] && printf 'Reading is %ss old — a floor, not a measurement.' "$xage" || printf 'Weekly window — the binding cap in practice.')" false 4 "$upd" 'codex rollout' "$updx")" '$a+[$b]')"
    fi
  elif command -v codex >/dev/null 2>&1 || [ -d "$HOME/.codex" ]; then
    arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row chatgpt 'ChatGPT (Codex)' unknown '' '' 'sol, terra, gpt-5.* on your ChatGPT plan' 'Codex installed but no limit reading yet.' false 3 '' '')" '$a+[$b]')"
  fi
  # Unmetered lanes, only when detected installed: nothing invented about their
  # quota, so they read unknown (Devin/Antigravity) or trivially ok (paid/local).
  if command -v devin >/dev/null 2>&1; then
    arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row devin 'Devin' unknown 'plan quota, no meter' '' 'glm, swe, devin-* on your Devin plan' 'A plan refusal is only detectable when a run hits it.' false 5 '' '')" '$a+[$b]')"
  fi
  if command -v agy >/dev/null 2>&1; then
    arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row agy 'Antigravity' unknown 'no meter' '' 'gemini-*, nano-banana' 'No published meter.' false 6 '' '')" '$a+[$b]')"
  fi
  if [ -n "${OPENROUTER_API_KEY:-}" ] || grep -qs '^OPENROUTER_API_KEY=' "$HOME/.env" 2>/dev/null; then
    arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row openrouter 'OpenRouter' ok 'pay per use' '' 'OpenRouter model ids' 'Billed from your balance — outsourcerer asks before every run.' true 7 '' '')" '$a+[$b]')"
  fi
  if command -v ollama >/dev/null 2>&1 || [ -d "$HOME/.lmstudio" ]; then
    arr="$(jq -cn --argjson a "$arr" --argjson b "$(_osrc_limit_row local 'Local' ok 'free, your hardware' '' 'ollama:*, lmstudio:*, local:*' 'No meter, no bill.' false 8 '' '')" '$a+[$b]')"
  fi
  # Gemini CLI is retired — never listed.
  printf '%s' "$arr"
}

# ---- commands --------------------------------------------------------------------

# _osrc_hub_need <tool...> -> die naming every missing tool. hub export used to
# degrade to an empty projects/limits doc when a tool it calls was absent from
# PATH — the failure mode was indistinguishable from "nothing running".
_osrc_hub_need() {
  local t miss=""
  for t in "$@"; do have "$t" || miss="$miss $t"; done
  [ -z "$miss" ] || die "hub: required tool(s) not on PATH:$miss"
}

# _osrc_hub_export_run: the export itself; cmd_hub_export (lib/hub-truth.sh) runs it single-flight.
_osrc_hub_export_run() {
  # The fast path is the export under `hub serve` (hub_server.py exports with OSRC_HUB_FAST=1):
  # settled-project caches, memoised tmux/registry reads, stale-while-revalidate screens and queued
  # done-probes. A plain `hub export` stays synchronous so a one-shot caller never reads a cached
  # doc as current; OSRC_HUB_FAST=1 opts in, OSRC_HUB_REFRESH=1 still forces a rebuild.
  : "${OSRC_HUB_FAST:=0}"; export OSRC_HUB_FAST
  _osrc_hub_need jq date stat sort tr sed cut basename awk grep cat head
  local proj="" a
  while [ "$#" -gt 0 ]; do case "$1" in --project) proj="${2:-}"; shift 2 ;; *) shift ;; esac; done
  [ -z "$proj" ] || _osrc_hub_slug_ok "$proj" || die "hub export: bad project slug '$proj'"
  local now upd projects='[]' slug found=0
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "export.start"
  now="$(date +%s)"; upd="$(_osrc_hub_now_stamp)"
  type _osrc_hub_memo_begin >/dev/null 2>&1 && _osrc_hub_memo_begin   # one pane read per lane per export
  # One pass over the Claude session registry for the whole export (liveness + "Also running").
  local _OSRC_HUB_CC_ROWS="" _OSRC_HUB_CC_ROWS_SET=""
  type _osrc_hub_cc_rows >/dev/null 2>&1 && _OSRC_HUB_CC_ROWS="$(_osrc_hub_cc_rows)" && _OSRC_HUB_CC_ROWS_SET=1
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "memo.begin.done"
  # Slugs: every owner session + every decisions/projects file + unowned.
  local slugs=""
  local d f
  for d in "$OSRC_HOME"/owners/*/ "$OSRC_HOME"/hub/seen/*/; do [ -d "$d" ] && slugs="$slugs $(basename "$d")"; done
  for f in "$OSRC_HOME"/hub/decisions/*.json "$OSRC_HOME"/hub/projects/*.json; do
    [ -f "$f" ] && slugs="$slugs $(basename "$f" .json)"
  done
  # de-dup
  slugs="$(printf '%s\n' $slugs | sort -u | tr '\n' ' ')"
  for slug in $slugs; do
    [ -n "$slug" ] || continue
    [ -n "$proj" ] && [ "$slug" != "$proj" ] && continue
    type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "proj.$slug.start"
    _osrc_hub_slug_ok "$slug" || continue
    local pj; pj="$(_osrc_hub_build_project "$slug" "$now" "$upd")"   # a failed build is listed, never dropped (lib/hub-safe.sh)
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$pj" || pj="$(_osrc_hub_stub_project "$slug" "$now" "$upd" "this project could not be read in this export; its lanes are not shown")"
    # Full listing: working orchestrator sessions only. --project still answers for any slug.
    [ -n "$proj" ] || _osrc_hub_visible "$slug" "$pj" || continue
    if [ -z "$(jq -r '.name // ""' "$OSRC_HOME/hub/projects/$slug.json" 2>/dev/null)" ]; then
      pj="$(jq -c --arg d "$(_osrc_hub_session_detail "$slug")" '. + {_base: (.name // ""), _detail: $d}' <<<"$pj")"
    fi
    type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "proj.$slug.detail"
    ! type _osrc_hub_history >/dev/null 2>&1 || pj="$(jq -c --argjson h "$(_osrc_hub_history "$slug" "$pj" 2>/dev/null || echo null)" '. + {history:$h}' <<<"$pj" 2>/dev/null || printf '%s' "$pj")"   # project history
    type _osrc_hub_with_orch >/dev/null 2>&1 && pj="$(_osrc_hub_with_orch "$pj" "$slug" "$now")"   # orchestrator liveness
    [ -f "$OSRC_HOME/hub/status/$slug.json" ] && pj="$(jq -c '. + {_hasStatus:true}' <<<"$pj")"
    type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "proj.$slug.end"
    [ -n "$pj" ] && { projects="$(jq -cn --argjson a "$projects" --argjson b "$pj" '$a+[$b]')"; [ "$slug" = "$proj" ] && found=1; }
  done
  # One card per project, then live evidence vs reports (lib/hub-truth.sh).
  [ -n "$proj" ] || ! type _osrc_hub_group >/dev/null 2>&1 || projects="$(_osrc_hub_group "$projects")"
  if type _osrc_hub_truth >/dev/null 2>&1; then
    projects="$(jq -c '.[]' <<<"$projects" | while IFS= read -r pj; do _osrc_hub_truth_safe "$pj" "$now"; done | jq -cs 'map(del(._hasStatus))')"
  fi
  if [ -z "$proj" ]; then
    local uj; uj="$(_osrc_hub_unowned_project "$now" "$upd")"
    [ -z "$uj" ] || uj="$(_osrc_hub_status_override unowned "$uj")"
    [ -n "$uj" ] && jq -e '.liveLanes > 0' >/dev/null 2>&1 <<<"$uj" && projects="$(jq -cn --argjson a "$projects" --argjson b "$uj" '$a+[$b]')"
  elif [ "$found" = 0 ]; then
    echo "hub export: no project '$proj' (slugs: owners/*, hub/decisions/*.json, hub/projects/*.json)" >&2
  fi
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "projects.done"
  local limits; if type _osrc_hub_limits_cached >/dev/null 2>&1; then limits="$(_osrc_hub_limits_cached)"; else limits="$(_osrc_hub_limits 2>/dev/null)"; fi
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$limits" || limits='[]'; ! type _osrc_hub_limits_fresh >/dev/null 2>&1 || limits="$(_osrc_hub_limits_fresh <<<"$limits")"   # renews from renews_at, now
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "limits.done"
  # Re-read the queued stale screens in ONE detached worker: off the export's clock and off its
  # tmux queue. Fork now, while the memoised raw reader still exists.
  type _osrc_hub_scr_flush_wanted >/dev/null 2>&1 && _osrc_hub_scr_flush_wanted
  type _osrc_hub_memo_end >/dev/null 2>&1 && _osrc_hub_memo_end
  local also='[]'; [ -n "$proj" ] || ! type _osrc_hub_also >/dev/null 2>&1 || also="$(_osrc_hub_also)"   # other sessions
  jq -e 'arrays' >/dev/null 2>&1 <<<"$also" || also='[]'
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "also.done"
  jq -cn --argjson now "$now" --argjson ps "$projects" --argjson ls "$limits" --argjson also "$also" '{generated_at:$now, projects:$ps, limits:$ls, also:$also}' | _osrc_hub_name_finish
}

# _osrc_hub_visible <slug> <project-json>: is this a working orchestrator session? Shown when ANY:
# a live owned lane (a tmux session, a running or waiting job, a live remote lane) or an open decision; a
# shipped card, for OSRC_HUB_SHIPPED_DAYS (7) in the Shipped list; any card for OSRC_HUB_STALE_HOURS (24); or an ACTIVE orchestrator: one that used
# Outsourcerer (lib/hub-report.sh seen/ dir, an owners/ dir or its own card) and beat, reported or wrote its
# transcript in the last OSRC_HUB_ACTIVE_MIN (30) minutes, between lanes included. A Claude session that
# never touched Outsourcerer has none of these and never shows. Data stays on disk either way.
_osrc_hub_visible() {
  local slug="$1" pj="$2" m="${OSRC_HUB_ACTIVE_MIN:-30}" days="${OSRC_HUB_SHIPPED_DAYS:-7}" t f lanes=0
  case "$m" in ''|*[!0-9]*) m=30 ;; esac
  case "$days" in ''|*[!0-9]*) days=7 ;; esac
  jq -e '(.liveLanes // 0) > 0 or ([.lanes[]? | select((.ended // false) | not) | select(.session != null or ((.state // "") | IN("working", "approval", "question", "limit")))] | length > 0)
         or ([.decisions[]? | select((.status // "wait") != "done")] | length > 0)' >/dev/null 2>&1 <<<"$pj" && return 0
  if jq -e '.status == "shipped"' >/dev/null 2>&1 <<<"$pj"; then
    for f in "$OSRC_HOME/hub/projects/$slug.json" "$OSRC_HOME/hub/status/$slug.json"; do
      [ -f "$f" ] && [ -n "$(find "$f" -mmin "-$((days * 1440))" 2>/dev/null)" ] && return 0
    done
  fi
  # A card (an orchestrator's own report) shows for OSRC_HUB_STALE_HOURS (24): long enough for the page's
  # "no update for X h" alarm to flag a quiet project instead of it vanishing.
  local sh="${OSRC_HUB_STALE_HOURS:-24}"; case "$sh" in ''|*[!0-9]*) sh=24 ;; esac
  [ -f "$OSRC_HOME/hub/projects/$slug.json" ] && [ -n "$(find "$OSRC_HOME/hub/projects/$slug.json" -mmin "-$((sh * 60))" 2>/dev/null)" ] && return 0
  if type _osrc_hub_active >/dev/null 2>&1; then _osrc_hub_active "$slug" && return 0; return 1; fi
  for t in "$OSRC_HOME/owners/$slug"/*; do
    [ -f "$t" ] || continue
    case "${t##*/}" in .*|watch.*) continue ;; esac
    lanes=1; break
  done
  [ "$lanes" = 1 ] || return 1
  for f in "$HOME"/.claude/projects/*/"$slug".jsonl; do
    [ -f "$f" ] && [ -n "$(find "$f" -mmin "-$m" 2>/dev/null)" ] && return 0
  done
  return 1
}

# cmd_hub_serve [--port N] [--no-open] [--new-token] -> local Mission Control
# on 127.0.0.1. Token persists in $OSRC_HOME/hub/token (0600) so the printed
# URL stays bookmarkable across restarts; --new-token rotates it. Default
# port is fixed; the server slides to the next free port and says so.
cmd_hub_serve() {
  local port="${OSRC_HUB_PORT:-}" noopen="${OSRC_HUB_NO_OPEN:-0}" newtok=0 scan=0
  while [ "$#" -gt 0 ]; do case "$1" in
    --port) port="${2:-}"; scan=0; shift 2 ;;
    --no-open) noopen=1; shift ;;
    --new-token) newtok=1; shift ;;
    *) die "hub serve: unknown option '$1' (usage: hub serve [--port N] [--no-open] [--new-token])" ;;
  esac; done
  if [ -z "$port" ]; then port=8788; scan=10; fi   # fixed default, slide up to 8798
  case "$port" in *[!0-9]*) die "hub serve: --port must be a number" ;; esac
  _osrc_hub_need python3 od cat tr mkdir chmod
  local dir="${_OSRC_FACTORY_DIR:-$SCRIPT_DIR}"
  local server="$dir/lib/hub_server.py" page="$dir/lib/hub.html" engine="$dir/outsourcerer.sh"
  [ -f "$server" ] && [ -f "$page" ] && [ -f "$engine" ] \
    || die "hub files missing under $dir/lib (hub_server.py, hub.html) or $engine"
  local tokf="$OSRC_HOME/hub/token" tok=""
  mkdir -p "$OSRC_HOME/hub"
  chmod 700 "$OSRC_HOME/hub" 2>/dev/null || die "hub serve: cannot chmod 700 $OSRC_HOME/hub"
  [ -L "$tokf" ] && die "hub serve: $tokf is a symlink — refusing a planted token file"
  if [ "$newtok" != 1 ] && [ -f "$tokf" ]; then
    tok="$(cat "$tokf" 2>/dev/null | tr -d ' \n')"
    case "$tok" in *[!0-9a-fA-F]*|'') tok="" ;; esac   # corrupt file -> mint below
    [ "${#tok}" -eq 32 ] || tok=""                   # exactly 16 bytes of hex
  fi
  if [ -z "$tok" ]; then
    tok="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [ -n "$tok" ] || die "hub serve: cannot read /dev/urandom for the access token — refusing to run with a guessable one"
    ( umask 077 && printf '%s\n' "$tok" > "$tokf" ) || die "hub serve: cannot write $tokf"
    # A rotation revokes: no retired key may redeem the new one through /reopen.
    [ "$newtok" = 1 ] && rm -f "$OSRC_HOME/hub/keys.json"
    [ "$newtok" = 1 ] && echo "hub serve: rotated the access token — old bookmarks are dead" >&2
  fi
  chmod 600 "$tokf" 2>/dev/null || die "hub serve: cannot chmod 600 $tokf"
  export OSRC_HUB_TOKEN="$tok"
  local -a args=(--bind 127.0.0.1 --port "$port" --page "$page" --engine "$engine" --osrc-home "$OSRC_HOME" --scan "$scan")
  [ "$noopen" = 1 ] && args+=(--no-open)
  exec python3 -I "$server" "${args[@]}"
}

# cmd_hub_mc: `mc` / `mission-control`, the open-the-page command. It reuses a hub that already serves this
# OSRC_HOME (its token answers /api/answers on 8788-8798), else starts one detached, opens the page and
# returns. Before 0.16.4 `mc` ran `hub serve` in the foreground: it never returned, and with 8788 taken it
# quietly started a second server. `mc serve ...` (or any serve flag) still runs the server in front.
cmd_hub_mc() {
  case "${1:-}" in serve) shift; cmd_hub_serve "$@"; return ;; --port|--no-open|--new-token) cmd_hub_serve "$@"; return ;; esac
  [ "$#" -eq 0 ] || die "mc: unknown option '$1' (usage: mc | mc serve [--port N] [--no-open] [--new-token])"
  local tokf="$OSRC_HOME/hub/token" tok="" p url="" log="$OSRC_HOME/hub/serve.log" i
  local dir="${_OSRC_FACTORY_DIR:-$SCRIPT_DIR}"
  [ -f "$tokf" ] && [ ! -L "$tokf" ] && tok="$(tr -d ' \n' <"$tokf" 2>/dev/null)"
  case "$tok" in *[!0-9a-fA-F]*) tok="" ;; esac
  if [ "${#tok}" -eq 32 ] && command -v curl >/dev/null 2>&1; then
    # The port this OSRC_HOME's hub last recorded, then an explicit OSRC_HUB_PORT, then the fixed
    # 8788-8798 scan: a `hub serve --port N` / OSRC_HUB_PORT hub lives outside the scan but is still
    # ours. The token gates every probe, so a stale record or a foreign server just misses.
    local plist="" sp p2
    sp="$(jq -r '.port // empty' "$OSRC_HOME/hub/serve.json" 2>/dev/null)"
    case "$sp" in ''|*[!0-9]*) ;; *) plist="$sp" ;; esac
    case "${OSRC_HUB_PORT:-}" in ''|*[!0-9]*) ;; *) plist="${plist:+$plist }${OSRC_HUB_PORT}" ;; esac
    for p2 in 8788 8789 8790 8791 8792 8793 8794 8795 8796 8797 8798; do
      case " $plist " in *" $p2 "*) ;; *) plist="$plist $p2" ;; esac
    done
    for p in $plist; do
      [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' -H "X-Hub-Token: $tok" "http://127.0.0.1:$p/api/answers" 2>/dev/null)" = 200 ] \
        && { url="http://127.0.0.1:$p/?t=$tok"; break; }
    done
  fi
  # A live hub is reused only when it runs THIS engine: an older install's server (or another
  # checkout's) answers the token probe and keeps serving old code and old bugs (0.17.5).
  # _osrc_mc_stale_hub kills only a process verified as this OSRC_HOME's hub server.
  type _osrc_mc_hub_reuse >/dev/null 2>&1 && { _osrc_mc_hub_reuse "${url:+$p}" || url=""; }   # also stops a wedged hub of ours (lib/mc_alive.sh)
  if [ -z "$url" ]; then
    mkdir -p "$OSRC_HOME/hub" && chmod 700 "$OSRC_HOME/hub" 2>/dev/null
    [ -L "$log" ] && die "mc: $log is a symlink, refusing to write it"
    : >"$log" 2>/dev/null || die "mc: cannot write $log"   # empty first: never read a dead hub's URL
    ( OSRC_HUB_NO_OPEN=1 nohup bash "$dir/outsourcerer.sh" hub serve --no-open >"$log" 2>&1 & ) >/dev/null 2>&1
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
      url="$(grep -oE 'http://127\.0\.0\.1:[0-9]+/\?t=[0-9a-fA-F]+' "$log" 2>/dev/null | tail -1)"
      [ -n "$url" ] && { ! type _osrc_mc_url_live >/dev/null 2>&1 || _osrc_mc_url_live "$url"; } && break; url=""; sleep 0.5
    done
    [ -n "$url" ] || die "mc: Mission Control did not start within 15 s; see $log"
  fi
  echo "[outsourcerer] Mission Control: $url"
  # mc always opens the page, a reused hub included; one opener for mc and the auto-open.
  [ "${OSRC_HUB_NO_OPEN:-0}" = 1 ] && return 0
  if type _osrc_mc_open_url >/dev/null 2>&1; then _osrc_mc_open_url "$url"; _osrc_mc_mark_opened
  else python3 -I -c 'import sys, webbrowser; webbrowser.open(sys.argv[1])' "$url" >/dev/null 2>&1 || true; fi
}

cmd_hub() {
  local sub="${1:-}"
  case "$sub" in
    export) shift; cmd_hub_export "$@" ;;
    serve) shift; cmd_hub_serve "$@" ;;
    report) shift; type cmd_hub_report >/dev/null 2>&1 || die "hub report: lib/hub-report.sh is missing"; cmd_hub_report "$@" ;;
    *) die "hub: export [--project SLUG] | serve [--port N] [--no-open] [--new-token] | report --status/--pct/--eta/--next/--name/--ask/--done-ask" ;;
  esac
}

# Lane naming lives in lib/hub-lanename.sh. The engine's lib loader sources it first; suites and
# helpers that source hub.sh alone would otherwise get no lanes at all, so pull it in here when missing.
type _osrc_hub_truth >/dev/null 2>&1 || { _osrc_hub_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; [ -r "$_osrc_hub_d/hub-truth.sh" ] && . "$_osrc_hub_d/hub-truth.sh"; unset _osrc_hub_d; }
type _osrc_hub_lane_for >/dev/null 2>&1 || { _osrc_hub_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; [ -r "$_osrc_hub_d/hub-lanename.sh" ] && . "$_osrc_hub_d/hub-lanename.sh"; unset _osrc_hub_d; }
type _osrc_hub_stub_project >/dev/null 2>&1 || { _osrc_hub_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; [ -r "$_osrc_hub_d/hub-safe.sh" ] && . "$_osrc_hub_d/hub-safe.sh"; unset _osrc_hub_d; }
type _osrc_hub_job_state >/dev/null 2>&1 || { _osrc_hub_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; [ -r "$_osrc_hub_d/hub-lanemeta.sh" ] && . "$_osrc_hub_d/hub-lanemeta.sh"; unset _osrc_hub_d; }
