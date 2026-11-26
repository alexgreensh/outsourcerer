#!/usr/bin/env bash
# lib/hub-history.sh -- Mission Control History: one timeline per project, newest first.
#   * Lanes: every lane that ran for the orchestrator (registry start/end, jobs meta, remote lanes), with a
#     human name (lib/hub-lanename.sh, never an id) and an outcome: running | finished | stopped | failed.
#   * Releases, merged/closed PRs and closed issues of the project's GitHub repo, READ-ONLY through `gh`
#     list commands only, cached in $OSRC_HOME/hub/cache for OSRC_HUB_GH_TTL (600 s) so the page never
#     hammers the API. No gh / offline: local `git tag` and one neutral "GitHub not reachable" flag.
# Which lanes belong to an orchestrator: owners/<sid>/ and hub/seen/<sid>/ (copied into a durable ledger,
# hub/history/<sid>.lanes, because the stop guard reaps owners/ entries), a tmux name ending in -<sid8>, or a
# lane in the project's repo that started inside the orchestrator's window and no other orchestrator owns.
# Sourced by outsourcerer.sh (lib loader).

# _osrc_hub_gh_slug <url|owner/name> -> "owner/name" (lowercase) for a GitHub remote, else "".
_osrc_hub_gh_slug() {
  local u="${1:-}"
  case "$u" in
    *github.com[:/]*) u="${u##*github.com[:/]}" ;;
    *://*|*@*|'') return 0 ;;
  esac
  u="${u%.git}"; u="${u%/}"
  case "$u" in */*/*|/*|*' '*) return 0 ;; */*) printf '%s' "$u" | tr 'A-Z' 'a-z' ;; esac
}

# _osrc_hub_dir_repo <dir> -> the dir's GitHub origin as owner/name, else "".
_osrc_hub_dir_repo() {
  [ -n "${1:-}" ] && [ -d "$1" ] || return 0
  _osrc_hub_gh_slug "$(git -C "$1" config --get remote.origin.url 2>/dev/null)"
}

# _osrc_hub_iso_epoch <iso> -> epoch seconds ("" when unparseable). Drops fractional seconds first.
_osrc_hub_iso_epoch() {
  jq -rn --arg t "${1:-}" '$t | sub("\\.[0-9]+"; "") | (fromdateiso8601? // empty) | floor' 2>/dev/null
}

# _osrc_hub_orch_transcript <sid> -> the orchestrator's own transcript path, or "".
_osrc_hub_orch_transcript() {
  local f
  for f in "${OSRC_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"/*/"$1".jsonl; do
    [ -f "$f" ] && [ ! -L "$f" ] && { printf '%s' "$f"; return 0; }
  done
}

# _osrc_hub_lane_owned_elsewhere <lane-id> <sid> -> rc 0 when another orchestrator claims the lane.
_osrc_hub_lane_owned_elsewhere() {
  local f
  for f in "$OSRC_HOME"/owners/*/"$1" "$OSRC_HOME"/hub/seen/*/"$1"; do
    [ -e "$f" ] || continue
    case "$f" in */"$2"/"$1") ;; *) return 0 ;; esac
  done
  grep -lxF "$1" "$OSRC_HOME"/hub/history/*.lanes 2>/dev/null | grep -vF "/$2.lanes" | grep -q . && return 0
  case "$1" in *--[0-9]*-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
    [ "${1##*-}" = "$(printf '%s' "$2" | cut -c1-8)" ] || return 0 ;; esac
  return 1
}

# _osrc_hub_gh_data <owner/name> -> cached {fetchedAt, ok, releases, prs, issues}. Fresh for OSRC_HUB_GH_TTL
# seconds; a failed fetch is cached too (ok:false), so an offline machine does not retry every poll. Under
# `hub serve` (OSRC_HUB_FAST=1) a stale cache is served while one detached refresher rewrites it.
_osrc_hub_gh_fetch() { # <repo> <file>
  local repo="$1" f="$2" rel prs iss ok=true
  # Bounded: an inline fetch sits on the export's clock, so a hung network must not hold it.
  _osrc_hub_gh() { if type _osrc_net >/dev/null 2>&1; then OSRC_NET_TIMEOUT="${OSRC_HUB_GH_TIMEOUT:-10}" _osrc_net gh "$@"; else gh "$@"; fi; }
  if have gh 2>/dev/null; then
    rel="$(_osrc_hub_gh release list -R "$repo" --limit 40 --json tagName,name,publishedAt,isDraft 2>/dev/null)" || ok=false
    [ "$ok" = true ] && { prs="$(_osrc_hub_gh pr list -R "$repo" --state all --limit 100 --json number,title,closedAt,mergedAt,url,headRefName 2>/dev/null)" || ok=false; }
    [ "$ok" = true ] && { iss="$(_osrc_hub_gh issue list -R "$repo" --state closed --limit 100 --json number,title,closedAt,url,stateReason 2>/dev/null)" || ok=false; }
  else ok=false; fi
  jq -e 'arrays' >/dev/null 2>&1 <<<"${rel:-}" || { rel='[]'; ok=false; }
  jq -e 'arrays' >/dev/null 2>&1 <<<"${prs:-}" || { prs='[]'; ok=false; }
  jq -e 'arrays' >/dev/null 2>&1 <<<"${iss:-}" || { iss='[]'; ok=false; }
  mkdir -p "${f%/*}" 2>/dev/null || return 0
  # A failed fetch never wipes good history: keep it, marked stale, and note when it failed so the
  # next export serves it instead of retrying inline.
  if [ "$ok" = false ] && jq -e '.ok == true' "$f" >/dev/null 2>&1; then
    jq -c --argjson at "$(date +%s)" '. + {stale:true, failedAt:$at}' "$f" > "$f.$$" 2>/dev/null && mv -f "$f.$$" "$f" 2>/dev/null
    rm -f "$f.$$" 2>/dev/null; return 0
  fi
  jq -cn --argjson at "$(date +%s)" --argjson ok "$ok" --argjson r "$rel" --argjson p "$prs" --argjson i "$iss" \
    '{fetchedAt:$at, ok:$ok, releases:$r, prs:$p, issues:$i}' > "$f.$$" 2>/dev/null && mv -f "$f.$$" "$f" 2>/dev/null
  rm -f "$f.$$" 2>/dev/null
}
_osrc_hub_gh_data() {
  local repo="$1" ttl="${OSRC_HUB_GH_TTL:-600}" f age lk failed
  case "$ttl" in ''|*[!0-9]*) ttl=600 ;; esac
  f="$OSRC_HOME/hub/cache/gh-$(printf '%s' "$repo" | tr '/' '_').json"
  [ -L "$f" ] && return 0
  [ "$ttl" = 0 ] && { _osrc_hub_gh_fetch "$repo" "$f"; cat "$f" 2>/dev/null; return 0; }   # TTL 0 = no cache: fetch now
  if [ -f "$f" ] && jq -e 'objects' "$f" >/dev/null 2>&1; then
    age=$(( $(date +%s) - $(jq -r '.fetchedAt // 0' "$f" 2>/dev/null) ))
    # Stale: serve it and refresh detached, in every mode. Three gh calls per project used to sit on
    # a plain export's clock every 10 minutes. A repo with no cache, or one older than a day
    # (OSRC_HUB_GH_MAX), is fetched inline: week-old history must not show as current.
    failed=$(( $(date +%s) - $(jq -r '.failedAt // 0' "$f" 2>/dev/null) ))
    if [ "$age" -ge "${OSRC_HUB_GH_MAX:-86400}" ] 2>/dev/null && [ "$failed" -ge "$ttl" ]; then
      _osrc_hub_gh_fetch "$repo" "$f"
    elif [ "$age" -ge "$ttl" ] || [ "$age" -lt 0 ]; then
      lk="$f.lock"
      [ -d "$lk" ] && type _osrc_hub_mt >/dev/null 2>&1 && [ $(( $(date +%s) - $(_osrc_hub_mt "$lk") )) -gt 300 ] && rmdir "$lk" 2>/dev/null
      mkdir "$lk" 2>/dev/null && ( type _osrc_hub_close_fds >/dev/null 2>&1 && _osrc_hub_close_fds
        _osrc_hub_gh_fetch "$repo" "$f"; rmdir "$lk" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
    fi
  else
    _osrc_hub_gh_fetch "$repo" "$f"
  fi
  cat "$f" 2>/dev/null
}

# _osrc_hub_local_tags <dir> -> [{tag, at}] from the local clone (the offline fallback).
_osrc_hub_local_tags() {
  [ -d "${1:-}" ] || { printf '[]'; return 0; }
  git -C "$1" for-each-ref --sort=-creatordate --format='%(refname:short)%09%(creatordate:unix)' refs/tags 2>/dev/null | head -40 \
    | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {tag: .[0], at: ((.[1] // "0") | if test("^[0-9]+$") then tonumber else 0 end)})' 2>/dev/null || printf '[]'
}

# _osrc_hub_history_lanes <sid> <repo> <since> -> JSON array of lane items for this orchestrator.
_osrc_hub_history_lanes() {
  local sid="$1" repo="$2" since="$3" sid8 led cands id rows='[]' f
  sid8="$(printf '%s' "$sid" | cut -c1-8)"
  led="$OSRC_HOME/hub/history/$sid.lanes"
  # durable ledger: what owners/ and seen/ say right now, kept after the stop guard reaps them
  if mkdir -p "$OSRC_HOME/hub/history" 2>/dev/null && [ ! -L "$led" ]; then
    { cat "$led" 2>/dev/null
      for f in "$OSRC_HOME/owners/$sid"/* "$OSRC_HOME/hub/seen/$sid"/*; do [ -f "$f" ] && printf '%s\n' "${f##*/}"; done
    } | grep -v '^\.' | grep . | sort -u > "$led.$$" 2>/dev/null && mv -f "$led.$$" "$led" 2>/dev/null
    rm -f "$led.$$" 2>/dev/null
  fi
  # Pre-built candidates across registry + jobs (ONE jq per export when hub-fast.sh is loaded).
  local cands_tsv="" row_lines=""
  if type _osrc_hub_history_cands_fast >/dev/null 2>&1; then
    cands_tsv="$(_osrc_hub_history_cands_fast)"
  else
    local reg='[]' jobs='[]' jd st cands
    [ -f "${OSRC_SESSION_REGISTRY:-}" ] && reg="$(jq -sc '
      map(select(type == "object" and (.session_id | type) == "string")) | group_by(.session_id) | map(. as $ev | {
        id: $ev[0].session_id, src: "registry",
        start: ([$ev[] | select(.event == "start") | .ts | sub("\\.[0-9]+"; "") | fromdateiso8601? // empty] | min),
        end: (if ($ev | last | .event) == "end" then ($ev | last | .ts | sub("\\.[0-9]+"; "") | fromdateiso8601? // null) else null end),
        receipt: (if ($ev | last | .event) == "end" then ($ev | last | .receipt // "") else "" end),
        model: ([$ev[] | .resolved_model // .model // empty] | last // ""),
        cwd: ([$ev[] | .cwd // empty] | last // "")})' "$OSRC_SESSION_REGISTRY" 2>/dev/null)" || reg='[]'
    jq -e 'arrays' >/dev/null 2>&1 <<<"$reg" || reg='[]'
    for jd in "$OSRC_JOBS"/*/; do
      [ -f "$jd/meta.json" ] || continue
      st="$(head -1 "$jd/status" 2>/dev/null)"
      jobs="$(jq -c --argjson a "$jobs" --arg st "$st" --arg end "$(cat "$jd/exit" >/dev/null 2>&1 && _osrc_hub_mt "$jd/exit" 2>/dev/null)" '
        $a + [{id: (.id // ""), src: "job", start: ((.started // "0") | tostring | if test("^[0-9]+$") then tonumber else 0 end), end: ($end | if test("^[0-9]+$") then tonumber else null end),
               status: $st, model: (.model // ""), cwd: (.worktree // .cwd // "")}]' "$jd/meta.json" 2>/dev/null)" || true
    done
    jq -e 'arrays' >/dev/null 2>&1 <<<"$jobs" || jobs='[]'
    cands="$(jq -c -n --argjson r "$reg" --argjson j "$jobs" '$r + $j | map(select(.id != ""))')"
    cands_tsv="$(jq -r '.[] | [.id, .src, (.start // 0 | tostring), (.end // "" | tostring), (.receipt // ""), (.status // ""), (.model // ""), (.cwd // "")] | map(gsub("[|\t\n]"; " ")) | join("|")' <<<"$cands" 2>/dev/null)"
  fi
  local dr=""
  while IFS='|' read -r id src start end receipt status model cwd; do   # "|": a tab IFS merges empty fields
    [ -n "$id" ] || continue
    local mine=0
    grep -qxF "$id" "$led" 2>/dev/null && mine=1
    [ "$mine" = 1 ] || case "$id" in *-"$sid8") mine=1 ;; esac
    if [ "$mine" = 0 ] && [ -n "$repo" ] && [ -n "$cwd" ] && [ "${start:-0}" -ge "${since:-0}" ] 2>/dev/null; then
      if type _osrc_hub_dir_repo_fast >/dev/null 2>&1; then dr="$(_osrc_hub_dir_repo_fast "$cwd")"; else dr="$(_osrc_hub_dir_repo "$cwd")"; fi
      [ "$dr" = "$repo" ] && ! _osrc_hub_lane_owned_elsewhere "$id" "$sid" && mine=1
    fi
    [ "$mine" = 1 ] || continue
    local out=""
    if [ "$src" = job ]; then
      case "$status" in done|succeeded|success) out=finished ;; failed|error|timeout|killed) out=failed ;;
        canceled|cancelled|stopped) out=stopped ;; running|starting|queued|waiting|'') out=running ;; *) out=stopped ;; esac
    else
      if [ -z "$end" ]; then
        if type _osrc_hub_tmux_row >/dev/null 2>&1 && _osrc_hub_tmux_row "$id" >/dev/null 2>&1; then out=running
        elif have tmux 2>/dev/null && tmux has-session -t "=$id" 2>/dev/null; then out=running; else out=stopped; fi
      else
        case "$receipt" in stop|exit|done|finished) out=finished ;; *fail*|*error*) out=failed ;; *) out=stopped ;; esac
      fi
    fi
    local ds=""
    type _osrc_hub_done_state >/dev/null 2>&1 && ds="$(_osrc_hub_done_state "$id" 2>/dev/null)"
    [ "$ds" = done ] && [ "$out" != running ] && out=finished
    local nm ml
    nm="$(_osrc_hub_lane_name "$id" 2>/dev/null)"; [ -n "$nm" ] || nm="Lane"
    ml="$model"; type _osrc_hub_model_label >/dev/null 2>&1 && ml="$(_osrc_hub_model_label "$model")"
    row_lines="${row_lines}$(jq -cn --arg nm "$nm" --arg ml "$ml" --arg out "$out" --arg s "$start" --arg e "$end" --arg k "$(printf '%s' "$id" | cksum | awk '{print $1}')" '
      {kind: "lane", key: $k, title: $nm, outcome: $out, start: ($s | if test("^[0-9]+$") then tonumber else null end), end: ($e | if test("^[0-9]+$") then tonumber else null end)}
      + (if $ml == "" then {} else {model: $ml} end) | .at = (.end // .start // 0)')
"
  done <<EOF
$cands_tsv
EOF
  if [ -n "$row_lines" ]; then jq -cs . <<<"$row_lines" 2>/dev/null || printf '[]'; else printf '[]'; fi
}

# _osrc_hub_history_build <sid> <project-json> <cache-file> -> prints history JSON and writes cache under FAST.
_osrc_hub_history_build() {
  local sid="$1" pj="${2:-}" c="${3:-}" now repo="" tf since="" f dir="" d gh='' lanes out ghs=none tags='[]' ev=""
  now="$(date +%s)"
  repo="$(_osrc_hub_gh_slug "$(jq -r '.repo // ""' <<<"$pj" 2>/dev/null)")"
  [ -n "$repo" ] || repo="$(_osrc_hub_gh_slug "$(jq -r '.repo // ""' "$OSRC_HOME/hub/projects/$sid.json" 2>/dev/null)")"
  # the repo the orchestrator's own lanes work in, else the folder it runs in
  for f in "$OSRC_HOME/owners/$sid"/* "$OSRC_HOME/hub/seen/$sid"/*; do
    [ -f "$f" ] || continue
    d=""
    if type _session_registry_last_event >/dev/null 2>&1; then
      ev="$(_session_registry_last_event "${f##*/}" 2>/dev/null)"
      [ -n "$ev" ] && d="$(jq -r '.cwd // ""' <<<"$ev" 2>/dev/null)"
    elif [ -f "${OSRC_SESSION_REGISTRY:-}" ]; then
      d="$(jq -r --arg id "${f##*/}" 'select(.session_id == $id) | .cwd // empty' "$OSRC_SESSION_REGISTRY" 2>/dev/null | tail -1)"
    fi
    [ -n "$d" ] || { [ -f "$OSRC_JOBS/${f##*/}/meta.json" ] && d="$(jq -r '.worktree // .cwd // ""' "$OSRC_JOBS/${f##*/}/meta.json" 2>/dev/null)"; }
    [ -d "$d" ] || continue
    [ -n "$dir" ] || dir="$d"
    if [ -z "$repo" ]; then
      if type _osrc_hub_dir_repo_fast >/dev/null 2>&1; then repo="$(_osrc_hub_dir_repo_fast "$d")"; else repo="$(_osrc_hub_dir_repo "$d")"; fi
    fi
    [ -n "$repo" ] && break
  done
  tf="$(_osrc_hub_orch_transcript "$sid")"
  if [ -n "$tf" ]; then
    since="$(_osrc_hub_iso_epoch "$(head -c 262144 "$tf" 2>/dev/null | grep -m1 -o '"timestamp": *"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/')")"
    if [ -z "$repo" ] || [ -z "$dir" ]; then
      d="$(head -c 262144 "$tf" 2>/dev/null | grep -m1 -o '"cwd": *"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/')"
      if [ -d "$d" ]; then
        [ -n "$dir" ] || dir="$d"
        if [ -z "$repo" ]; then
          if type _osrc_hub_dir_repo_fast >/dev/null 2>&1; then repo="$(_osrc_hub_dir_repo_fast "$d")"; else repo="$(_osrc_hub_dir_repo "$d")"; fi
        fi
      fi
    fi
  fi
  case "$since" in ''|*[!0-9]*) since=$(( now - 7 * 86400 )) ;; esac
  lanes="$(_osrc_hub_history_lanes "$sid" "$repo" "$since")"
  jq -e 'arrays' >/dev/null 2>&1 <<<"$lanes" || lanes='[]'
  # The window opens at the orchestrator's first lane or its first turn, whichever came first.
  since="$(jq -r --argjson s "$since" '[$s] + [.[] | .start // empty] | min' <<<"$lanes" 2>/dev/null)"
  if [ -n "$repo" ]; then
    gh="$(_osrc_hub_gh_data "$repo")"
    # A stale cache is good history kept after the latest fetch failed: show it, but GitHub is unreachable.
    if jq -e '.ok == true and (.stale | not)' >/dev/null 2>&1 <<<"$gh"; then ghs=ok; else ghs=unreachable; tags="$(_osrc_hub_local_tags "$dir")"; fi
  fi
  jq -e 'objects' >/dev/null 2>&1 <<<"$gh" || gh='{"releases":[],"prs":[],"issues":[]}'
  out="$(jq -c -n --argjson lanes "$lanes" --argjson gh "$gh" --argjson tags "$tags" --arg repo "$repo" --arg ghs "$ghs" \
      --argjson since "$since" --argjson now "$now" '
    def ep: if type == "string" then (sub("\\.[0-9]+"; "") | fromdateiso8601? // null) else null end;
    def gurl: if type == "string" and startswith("https://github.com/") then . else null end;
    ($since - 86400) as $from |
    ( $lanes
    + [ $gh.releases[]? | select((.isDraft // false) | not) | {kind: "release", title: (if (.name // "") != "" then .name else .tagName end), tag: .tagName,
          at: (.publishedAt | ep), url: (if $repo != "" then "https://github.com/\($repo)/releases/tag/\(.tagName | @uri)" else null end)} ]
    + [ $tags[]? | {kind: "release", title: .tag, tag: .tag, at: .at, local: true} ]
    + [ $gh.prs[]? | select(.closedAt or .mergedAt) | {kind: "pr", number, title, url: (.url | gurl), outcome: (if .mergedAt then "merged" else "closed" end),
          at: ((.mergedAt // .closedAt) | ep)} ]
    + [ $gh.issues[]? | {kind: "issue", number, title, url: (.url | gurl), outcome: (if .stateReason == "NOT_PLANNED" then "not planned" else "closed" end),
          at: (.closedAt | ep)} ] )
    | map(select(.at != null and (.kind == "lane" or .at >= $from)) | with_entries(select(.value != null)))
    | sort_by(-(.at // 0)) | .[0:200] as $items
    | def counts($xs): {releases: ([$xs[] | select(.kind == "release")] | length),
        prsMerged: ([$xs[] | select(.kind == "pr" and .outcome == "merged")] | length),
        prsClosed: ([$xs[] | select(.kind == "pr" and .outcome != "merged")] | length),
        issuesClosed: ([$xs[] | select(.kind == "issue")] | length),
        lanesFinished: ([$xs[] | select(.kind == "lane" and .outcome == "finished")] | length),
        lanesRunning: ([$xs[] | select(.kind == "lane" and .outcome == "running")] | length),
        lanesFailed: ([$xs[] | select(.kind == "lane" and .outcome == "failed")] | length),
        lanes: ([$xs[] | select(.kind == "lane")] | length)};
    {github: $ghs, since: $since, items: $items, summary: counts($items), week: counts([$items[] | select(.at >= $now - 604800)])}
    + (if $repo == "" then {} else {repo: $repo} end)' 2>/dev/null)"
  jq -e 'objects' >/dev/null 2>&1 <<<"$out" || { printf 'null'; return 0; }
  if [ "${OSRC_HUB_FAST:-0}" = 1 ] && [ -n "$c" ] && mkdir -p "$OSRC_HOME/hub/cache" 2>/dev/null && [ ! -L "$c" ]; then
    printf '%s\n' "$out" > "$c.$$" 2>/dev/null && mv -f "$c.$$" "$c" 2>/dev/null; rm -f "$c.$$" 2>/dev/null
  fi
  printf '%s' "$out"
}

# _osrc_hub_history <sid> <project-json> -> {repo, github: ok|unreachable|none, since, items[], summary{}, week{}}.
# Stale-while-revalidate under `hub serve` (OSRC_HUB_FAST=1); plain `hub export` always computes.
_osrc_hub_history() {
  local sid="$1" pj="${2:-}" c ttl="${OSRC_HUB_HISTORY_TTL:-60}" age lk grepo gat
  case "$sid" in ''|.*|*/*) printf 'null'; return 0 ;; esac
  case "$ttl" in ''|*[!0-9]*) ttl=60 ;; esac
  c="$OSRC_HOME/hub/cache/history-$sid.json"
  if [ "${OSRC_HUB_FAST:-0}" = 1 ] && [ -f "$c" ] && [ ! -L "$c" ] && jq -e 'objects' "$c" >/dev/null 2>&1; then
    # GitHub data refreshed after this history was built makes the cached reachability a lie:
    # ask gh_data (its own TTL/SWR rules apply) and rebuild now when its answer is newer.
    grepo="$(jq -r '.repo // ""' "$c" 2>/dev/null)"
    if [ -n "$grepo" ] && type _osrc_hub_mt >/dev/null 2>&1; then
      gat="$(_osrc_hub_gh_data "$grepo" 2>/dev/null | jq -r '.fetchedAt // 0' 2>/dev/null)"
      case "$gat" in ''|*[!0-9]*) gat=0 ;; esac
      [ "$gat" -gt "$(_osrc_hub_mt "$c")" ] && { _osrc_hub_history_build "$sid" "$pj" "$c"; return 0; }
    fi
    if type _osrc_hub_mt >/dev/null 2>&1; then
      age=$(( $(date +%s) - $(_osrc_hub_mt "$c") ))
      if [ "$age" -ge "$ttl" ] || [ "$age" -lt 0 ]; then
        lk="$c.lock"
        [ -d "$lk" ] && [ $(( $(date +%s) - $(_osrc_hub_mt "$lk") )) -gt 300 ] && rmdir "$lk" 2>/dev/null
        if mkdir "$lk" 2>/dev/null; then
          ( type _osrc_hub_close_fds >/dev/null 2>&1 && _osrc_hub_close_fds
            _OSRC_HUB_MEMO="" _osrc_hub_history_build "$sid" "$pj" "$c" >/dev/null 2>&1; rmdir "$lk" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
        fi
      fi
    fi
    cat "$c"; return 0
  fi
  _osrc_hub_history_build "$sid" "$pj" "$c"
}
