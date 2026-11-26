#!/usr/bin/env bash
# lib/hub-fast.sh -- Fast-path caching, memoization and batching for Mission Control `hub export`.
# Sourced by outsourcerer.sh (lib loader); defines functions only. All callers guard with `type`
# so sourcing hub.sh or hub-perf.sh alone keeps working in unit tests.

# _osrc_hub_fast_memo_init <memo-dir>: pre-compute export-wide indexes once instead of per-project.
_osrc_hub_fast_memo_init() {
  local d="$1" rv_dir="$OSRC_HOME/review/items"
  mkdir -p "$d/lname" "$d/jstate" "$d/rstate" "$d/rlabel" "$d/drepo" "$d/rneeds" 2>/dev/null
  # Pre-compute review map + needs-you + queued items in ONE jq over review/items/*.json.
  if [ -d "$rv_dir" ] && have jq; then
    local -a rfiles=()
    local rf
    for rf in "$rv_dir"/*.json; do [ -f "$rf" ] && rfiles+=("$rf"); done
    if [ "${#rfiles[@]}" -gt 0 ]; then
      # Sweep merged queued items at most once per export (throttled to 5 min under FAST).
      if type _osrc_review_sweep_merged >/dev/null 2>&1 && grep -ql '"queued"' "${rfiles[@]}" 2>/dev/null; then
        local do_sweep=1 sw_f="$OSRC_HOME/hub/.review-sweep.ts" gap="${OSRC_REVIEW_MERGED_SECS:-300}"
        if [ "${OSRC_HUB_FAST:-0}" = 1 ] && [ -f "$sw_f" ]; then
          local sw_age=$(( $(date +%s) - $(_osrc_hub_mt "$sw_f") ))
          [ "$sw_age" -ge 0 ] && [ "$sw_age" -lt "$gap" ] && do_sweep=0
        fi
        if [ "$do_sweep" = 1 ]; then
          _osrc_review_sweep_merged >/dev/null 2>&1 || true
          mkdir -p "$OSRC_HOME/hub" 2>/dev/null && : > "$sw_f" 2>/dev/null || true
        fi
      fi
      jq -cs '[.[] | select(.state=="verdict" and (.stale|not))]
              | group_by(.lane) | map(max_by(.verdict_ts // 0))
              | map({key:(.lane|tostring), value:(.verdict|tostring)}) | from_entries' \
        "${rfiles[@]}" > "$d/review_map.json" 2>/dev/null || printf '{}' > "$d/review_map.json"
      jq -rs '[.[] | select(.state == "needs-you" and (.lane | type) == "string")]
              | group_by(.lane) | .[] | .[0]
              | "\(.lane)\t\({item:.id, why:("unusable verdict twice: " + (.invalid_why // .invalid_first_line // ""))} | tojson)"' \
        "${rfiles[@]}" 2>/dev/null | while IFS="$(printf '\t')" read -r rl rj; do
          _osrc_hub_slug_ok "$rl" && printf '%s\n' "$rj" > "$d/rneeds/$rl.json"
        done
      jq -rs '.[] | select(.state == "queued" and .acked != true and (.lane | type) == "string") | "\(.lane)\t\(.enq_ts // 0)"' \
        "${rfiles[@]}" > "$d/review_queued.tsv" 2>/dev/null || : > "$d/review_queued.tsv"
    else
      printf '{}' > "$d/review_map.json"
      : > "$d/review_queued.tsv"
    fi
  else
    printf '{}' > "$d/review_map.json"
    : > "$d/review_queued.tsv"
  fi
  : > "$d/rneeds/.indexed"
  : > "$d/review_queued.indexed"
  : > "$d/.review_swept"
}

_osrc_hub_review_map_fast() {
  if [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -f "$_OSRC_HUB_MEMO/review_map.json" ]; then
    cat "$_OSRC_HUB_MEMO/review_map.json"
    return 0
  fi
  _osrc_hub_review_map
}

_osrc_hub_job_state_fast() {
  local id="$1"
  if [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -d "$_OSRC_HUB_MEMO/jstate" ] && _osrc_hub_slug_ok "$id"; then
    local f="$_OSRC_HUB_MEMO/jstate/$id"
    [ -f "$f" ] || _osrc_hub_job_state "$id" > "$f"
    cat "$f"
    return 0
  fi
  _osrc_hub_job_state "$id"
}

_osrc_hub_hash_key() { printf '%s' "$1" | cksum | awk '{print $1 "_" $2}'; }

_osrc_hub_repo_label_fast() {
  local dir="$1"
  [ -n "$dir" ] || return 0
  if [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -d "$_OSRC_HUB_MEMO/rlabel" ]; then
    local f="$_OSRC_HUB_MEMO/rlabel/$(_osrc_hub_hash_key "$dir")"
    [ -f "$f" ] || _osrc_hub_repo_label "$dir" > "$f"
    cat "$f"
    return 0
  fi
  _osrc_hub_repo_label "$dir"
}

_osrc_hub_dir_repo_fast() {
  local dir="$1"
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  if [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -d "$_OSRC_HUB_MEMO/drepo" ]; then
    local f="$_OSRC_HUB_MEMO/drepo/$(_osrc_hub_hash_key "$dir")"
    [ -f "$f" ] || _osrc_hub_dir_repo "$dir" > "$f"
    cat "$f"
    return 0
  fi
  _osrc_hub_dir_repo "$dir"
}

# ---- persistent TTL cache for lane names -------------------------------------------------------
_osrc_hub_lane_name_cache_get() { # <id> -> prints name, rc 0 on hit
  local id="$1" f cf cmt imt age ttl="${OSRC_HUB_LANENAME_TTL:-3600}"
  _osrc_hub_slug_ok "$id" || return 1
  if [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -f "$_OSRC_HUB_MEMO/lname/$id" ]; then
    cat "$_OSRC_HUB_MEMO/lname/$id"; return 0
  fi
  [ "${OSRC_HUB_FAST:-0}" = 1 ] || return 1
  case "$ttl" in ''|*[!0-9]*) ttl=3600 ;; esac
  cf="$OSRC_HOME/hub/lanenames/$id"
  [ -f "$cf" ] && [ ! -L "$cf" ] || return 1
  cmt="$(_osrc_hub_mt "$cf")"
  age=$(( $(date +%s) - cmt ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ] || return 1
  imt="$(_osrc_hub_mt "$OSRC_JOBS/$id/meta.json" "$OSRC_JOBS/$id/task_ref" "$OSRC_HOME/remote/$id.json")"
  [ "$imt" -le "$cmt" ] 2>/dev/null || return 1
  local val; IFS= read -r val 2>/dev/null < "$cf" || true
  [ -n "$val" ] || return 1
  if [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -d "$_OSRC_HUB_MEMO/lname" ]; then
    printf '%s' "$val" > "$_OSRC_HUB_MEMO/lname/$id"
  fi
  printf '%s' "$val"
  return 0
}

_osrc_hub_lane_name_cache_put() { # <id> <name>
  local id="$1" val="$2" d cf
  _osrc_hub_slug_ok "$id" && [ -n "$val" ] || return 0
  if [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -d "$_OSRC_HUB_MEMO/lname" ]; then
    printf '%s' "$val" > "$_OSRC_HUB_MEMO/lname/$id"
  fi
  [ "${OSRC_HUB_FAST:-0}" = 1 ] || return 0
  d="$OSRC_HOME/hub/lanenames"
  mkdir -p "$d" 2>/dev/null && [ ! -L "$d" ] || return 0
  cf="$d/$id"; [ ! -L "$cf" ] || return 0
  printf '%s\n' "$val" > "$cf.$$" 2>/dev/null && mv -f "$cf.$$" "$cf" 2>/dev/null
  rm -f "$cf.$$" 2>/dev/null
}

# ---- persistent cache for ended lanes (lane JSON + activity epoch) -----------------------------
# Sets _OSRC_ENDED_LANE and _OSRC_ENDED_ACT. Returns 0 when populated.
_osrc_hub_ended_lane_fast() { # <id> <rmap>
  local id="$1" rmap="$2" d="$OSRC_HOME/hub/cache/ended" lf af cmt imt age ttl="${OSRC_HUB_ENDED_CACHE_TTL:-3600}"
  _OSRC_ENDED_LANE=""; _OSRC_ENDED_ACT=0
  if [ "${OSRC_HUB_FAST:-0}" = 1 ] && _osrc_hub_slug_ok "$id"; then
    case "$ttl" in ''|*[!0-9]*) ttl=3600 ;; esac
    lf="$d/$id.lane"; af="$d/$id.act"
    if [ -f "$lf" ] && [ -f "$af" ] && [ ! -L "$lf" ] && [ ! -L "$af" ]; then
      cmt="$(_osrc_hub_mt "$lf")"
      age=$(( $(date +%s) - cmt ))
      if [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; then
        imt="$(_osrc_hub_mt "$OSRC_JOBS/$id/status" "$OSRC_JOBS/$id/exit" "$OSRC_JOBS/$id/meta.json" \
          "$OSRC_JOBS/$id/task_ref" "$OSRC_JOBS/$id/reason" "$OSRC_HOME/remote/$id.json" \
          "$OSRC_HOME/proof/$id/proof.json" "$OSRC_HOME/proof/$id/rounds.json" "$OSRC_HOME/done/$id.json" \
          "$OSRC_HOME/review/items/$id"-*.json)"
        if [ "$imt" -le "$cmt" ] 2>/dev/null; then
          IFS= read -r _OSRC_ENDED_LANE 2>/dev/null < "$lf" || _OSRC_ENDED_LANE=""
          IFS= read -r _OSRC_ENDED_ACT 2>/dev/null < "$af" || _OSRC_ENDED_ACT=0
          [ -n "$_OSRC_ENDED_LANE" ] && return 0
        fi
      fi
    fi
  fi
  local lane act
  lane="$(_osrc_hub_ended_lane "$id" "$rmap")"
  [ -n "$lane" ] && type osrc_proof_hub_lane >/dev/null 2>&1 && lane="$(osrc_proof_hub_lane "$lane" "$id")"
  act="$(_osrc_hub_lane_activity "$id")"
  _OSRC_ENDED_LANE="$lane"
  _OSRC_ENDED_ACT="${act%% *}"
  if [ "${OSRC_HUB_FAST:-0}" = 1 ] && [ -n "$lane" ] && _osrc_hub_slug_ok "$id"; then
    if mkdir -p "$d" 2>/dev/null && [ ! -L "$d" ]; then
      printf '%s\n' "$lane" > "$d/$id.lane.$$" 2>/dev/null && mv -f "$d/$id.lane.$$" "$d/$id.lane" 2>/dev/null
      printf '%s\n' "${_OSRC_ENDED_ACT:-0}" > "$d/$id.act.$$" 2>/dev/null && mv -f "$d/$id.act.$$" "$d/$id.act" 2>/dev/null
      rm -f "$d/$id.lane.$$" "$d/$id.act.$$" 2>/dev/null
    fi
  fi
  return 0
}

# ---- pre-built history candidates (ONE jq over registry + ONE jq over jobs per export) ---------
_osrc_hub_history_cands_fast() {
  if [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -f "$_OSRC_HUB_MEMO/history_cands.tsv" ]; then
    cat "$_OSRC_HUB_MEMO/history_cands.tsv"
    return 0
  fi
  local reg='[]' jobs='[]' rsrc="${OSRC_SESSION_REGISTRY:-}"
  [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -f "$_OSRC_HUB_MEMO/registry" ] && rsrc="$_OSRC_HUB_MEMO/registry"
  if [ -n "$rsrc" ] && [ -f "$rsrc" ]; then
    reg="$(jq -sc '
      map(select(type == "object" and (.session_id | type) == "string")) | group_by(.session_id) | map(. as $ev | {
        id: $ev[0].session_id, src: "registry",
        start: ([$ev[] | select(.event == "start") | .ts | sub("\\.[0-9]+"; "") | fromdateiso8601? // empty] | min),
        end: (if ($ev | last | .event) == "end" then ($ev | last | .ts | sub("\\.[0-9]+"; "") | fromdateiso8601? // null) else null end),
        receipt: (if ($ev | last | .event) == "end" then ($ev | last | .receipt // "") else "" end),
        model: ([$ev[] | .resolved_model // .model // empty] | last // ""),
        cwd: ([$ev[] | .cwd // empty] | last // "")})' "$rsrc" 2>/dev/null)" || reg='[]'
  fi
  jq -e 'arrays' >/dev/null 2>&1 <<<"$reg" || reg='[]'
  # Batch all job metas in ONE jq pass; attach status and exit mtime via a single TSV join.
  local -a mfiles=()
  local jd id st exmt st_lines=""
  for jd in "$OSRC_JOBS"/*/; do
    [ -f "$jd/meta.json" ] || continue
    mfiles+=("$jd/meta.json")
    id="${jd%/}"; id="${id##*/}"
    st=""; [ -f "$jd/status" ] && IFS= read -r st 2>/dev/null < "$jd/status" || true
    exmt=""; [ -f "$jd/exit" ] && exmt="$(_osrc_hub_mt "$jd/exit")"
    st_lines="${st_lines}${id}	${st}	${exmt}
"
  done
  if [ "${#mfiles[@]}" -gt 0 ]; then
    local st_map
    st_map="$(printf '%s' "$st_lines" | jq -Rsc 'split("\n") | map(select(length>0) | split("\t") | {key:.[0], value:{st:(.[1]//""), end:(.[2]//"")}}) | from_entries' 2>/dev/null)" || st_map='{}'
    jobs="$(jq -sc --argjson sm "$st_map" '[.[] | select(type=="object") | (.id // "") as $id | ($sm[$id] // {}) as $s | {
      id: $id, src: "job",
      start: ((.started // "0") | tostring | if test("^[0-9]+$") then tonumber else 0 end),
      end: (($s.end // "") | if test("^[0-9]+$") then tonumber else null end),
      status: ($s.st // ""), model: (.model // ""), cwd: (.worktree // .cwd // "")}]' "${mfiles[@]}" 2>/dev/null)" || jobs='[]'
  fi
  jq -e 'arrays' >/dev/null 2>&1 <<<"$jobs" || jobs='[]'
  local tsv
  tsv="$(jq -rn --argjson r "$reg" --argjson j "$jobs" '($r + $j) | map(select(.id != "")) | .[]
    | [.id, .src, (.start // 0 | tostring), (.end // "" | tostring), (.receipt // ""), (.status // ""), (.model // ""), (.cwd // "")]
    | map(gsub("[|\t\n]"; " ")) | join("|")' 2>/dev/null)"
  if [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -d "$_OSRC_HUB_MEMO" ]; then
    printf '%s\n' "$tsv" > "$_OSRC_HUB_MEMO/history_cands.tsv"
  fi
  printf '%s\n' "$tsv"
}

# ---- fast pure-jq limits renew text (replaces N date + jq forks in _osrc_hub_limits_fresh) -----
_osrc_hub_limits_fresh_fast() {
  local in now
  in="$(cat)"
  jq -e 'arrays' >/dev/null 2>&1 <<<"$in" || { printf '[]'; return 0; }
  now="$(date +%s)"
  LC_ALL=C jq -c --argjson now "$now" '
    def norm($e): ($e | if . > 100000000000 then . / 1000 else . end | floor);
    def tzoff($t): ($t | localtime | mktime) - $t;
    def lday($t): (($t + tzoff($t)) / 86400 | floor);
    def renew($e):
      norm($e) as $t
      | if $t <= $now then null
        else (lday($t) - lday($now)) as $d
        | if $d == 0 then "today · " + ($t | strflocaltime("%H:%M"))
          elif $d == 1 then "tomorrow · " + ($t | strflocaltime("%H:%M"))
          else "in \($d) days · " + ($t | strflocaltime("%a %e %b") | gsub("  +"; " ")) end end;
    def fix:
      if type != "object" then .
      elif (.renews_at | type) == "number" then .renews = renew(.renews_at)
      elif has("renews") then .renews = null
      else . end;
    map(fix | if (.windows | type) == "object" then .windows |= map_values(fix) else . end)' <<<"$in" 2>/dev/null || printf '[]'
}

# ---- persistent screen-state cache (per live tmux lane) -----------------------------------------
# _sv_target_screen reads the pane, the transcript tail, the done contract and the watch folders —
# a few seconds per live lane per export. Its result cannot change unless the pane printed (tmux
# window_activity), the done contract or watch/hand-in files moved, or the transcript appended, so
# hub/cache/scr/<id> stores "activity dep_epoch cached_epoch" + output and is reused while all three
# still match. OSRC_HUB_SCR_TTL (default 20s) bounds the staleness either way; a forced
# OSRC_HUB_REFRESH export always reads the pane again.
_osrc_hub_scr_deps() { # <id> -> the existing paths a lane's screen reading depends on, one per line;
  # "x" when one input cannot be watched by mtime (a branch: done contract reads a git ref)
  local id="$1" pair tp w p
  local -a deps=("$OSRC_HOME/done/$id.json" "$OSRC_HOME/done/$id.checkcache" "$OSRC_HOME/remote/$id.json" "$OSRC_HOME/lanes/state/$id" \
    "$OSRC_HOME/lanes/state/$id.handin" "$OSRC_HOME/lanes/state/$id.cc" "$OSRC_HOME/autodetach/$id".* "$OSRC_JOBS/$id/"* "$OSRC_SESSION_REGISTRY")
  # done-contract file: targets live outside OSRC_HOME.
  if [ -f "$OSRC_HOME/done/$id.json" ]; then
    pair="$(jq -r '[(.spec // ""), (.cwd // ".")] | @tsv' "$OSRC_HOME/done/$id.json" 2>/dev/null)"
    case "${pair%%	*}" in
      file:*) p="${pair%%	*}"; p="${p#file:}"; case "$p" in /*) ;; *) p="${pair#*	}/$p" ;; esac
        deps+=("$p") ;;
      branch:*) printf 'x\n'; return 0 ;;
    esac
  fi
  # Transcript tail feed (question check): resolve cc id via the same cache _sv_cc_transcript uses.
  if type _sv_cc_transcript >/dev/null 2>&1 && type _fleet_transcript_path >/dev/null 2>&1; then
    pair="$(_sv_cc_transcript "$id" 2>/dev/null)"
    [ -z "$pair" ] || { tp="$(_fleet_transcript_path "${pair%%	*}" "${pair#*	}" 2>/dev/null)"; [ -z "$tp" ] || deps+=("$tp"); }
  fi
  # Watched hand-in DONE files: a new file bumps its parent dir's mtime.
  for w in "$OSRC_HOME"/watch/*.path; do
    [ -f "$w" ] || continue
    deps+=("$w"); IFS= read -r p 2>/dev/null < "$w" || p=""
    [ -n "$p" ] && deps+=("$p" "$p/out")
  done
  for p in "${deps[@]}"; do [ -e "$p" ] && printf '%s\n' "$p"; done
  return 0
}
_osrc_hub_scr_dep_epoch() { # <id> -> newest mtime among the lane's screen inputs (0 = unknown)
  local p; local -a deps=()
  while IFS= read -r p; do [ -n "$p" ] && [ "$p" != x ] && deps+=("$p"); done <<EOF
$(_osrc_hub_scr_deps "$1")
EOF
  _osrc_hub_mt ${deps[@]+"${deps[@]}"}
}

_osrc_hub_scr_get() { # <id> -> prints cached "state\nevidence"; rc1 = caller must compute
  local id="$1" pf="$OSRC_HOME/hub/cache/scr/$1" act act0 row ep dep now floor ttl
  [ "${OSRC_HUB_FAST:-0}" = 1 ] && [ "${OSRC_HUB_REFRESH:-0}" != 1 ] \
    && [ -f "$pf" ] && [ ! -L "$pf" ] || return 1
  row="$(_osrc_hub_tmux_row "$id" 2>/dev/null)" || return 1
  act="${row##* }"; case "$act" in ''|*[!0-9]*) return 1 ;; esac
  read -r act0 dep ep 2>/dev/null < "$pf" || return 1
  case "$ep" in ''|*[!0-9]*) return 1 ;; esac
  now="${OSRC_NOW:-$(date +%s)}"
  floor="${OSRC_HUB_SCR_FLOOR:-4}"; ttl="${OSRC_HUB_SCR_TTL:-60}"
  # A read younger than the floor is current enough even while the pane is moving: exports
  # triggered back-to-back by churn must not re-read every active pane each time.
  if [ $(( now - ep )) -lt "$floor" ]; then
    type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "scr.$id.hit-floor"
    tail -n +2 "$pf" 2>/dev/null; return 0
  fi
  if [ "$act0" = "$act" ] && [ $(( now - ep )) -lt "$ttl" ]; then
    dep="$(_osrc_hub_scr_dep_epoch "$id")"
    case "$dep" in ''|*[!0-9]*) dep=0 ;; esac
    if [ "$dep" -le "$ep" ]; then
      type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "scr.$id.hit"
      tail -n +2 "$pf" 2>/dev/null; return 0
    fi
  fi
  # Past OSRC_HUB_SCR_MAX seconds (default 600) a cached screen is never served: a refresh that keeps
  # failing (or a lock left by a killed worker) must not freeze a lane's state on Mission Control.
  [ $(( now - ep )) -le "$(_sv_num "${OSRC_HUB_SCR_MAX:-}" 600)" ] || return 1
  # Stale by age, activity, or a moved input: serve it anyway (stale-while-revalidate). The fresh
  # read is queued for ONE deferred worker (_osrc_hub_scr_flush_wanted, run at export end) rather
  # than forked here: live pane reads hammering the tmux server mid-export stall the export's own
  # tmux calls. Screen state is a display input; supervise confirms quiet lanes on its own cadence.
  printf '%s %s\n' "$id" "$act" >> "$OSRC_HOME/hub/cache/scr/.wanted.$$" 2>/dev/null
  type _osrc_hub_prof >/dev/null 2>&1 && _osrc_hub_prof "scr.$id.swr"
  tail -n +2 "$pf" 2>/dev/null
}

# _osrc_hub_close_fds: first call of a detached worker. Bash keeps a saved copy of a redirected fd
# (`fn > file`, single-flight's `"$@" > out`) on a high fd; a worker forked inside inherits it and holds
# the caller's `$(...)` or the server's pipe open until it exits, so the export waited for the worker.
_osrc_hub_close_fds() {
  local f n
  for f in /dev/fd/*; do
    n="${f##*/}"; case "$n" in ''|*[!0-9]*|0|1|2|255) continue ;; esac
    eval "exec $n>&-" 2>/dev/null
  done
  return 0
}

# _osrc_hub_scr_flush_wanted: run once at export end (still inside the memo, so the raw reader is
# defined). Re-reads every queued lane in ONE detached worker: the export never pays the pane reads
# and the next export serves fresh screens.
_osrc_hub_scr_flush_wanted() {
  local wf="$OSRC_HOME/hub/cache/scr/.wanted.$$" dwf="$OSRC_HOME/hub/cache/scr/.dwant.$$"
  [ -s "$wf" ] || [ -s "$dwf" ] || return 0
  ( _osrc_hub_close_fds
    local id act pf out dep
    while read -r id act; do
      [ -n "$id" ] || continue
      _osrc_hub_slug_ok "$id" || continue
      pf="$OSRC_HOME/hub/cache/scr/$id"
      # A lock older than any bounded screen read (OSRC_HUB_SCR_LOCK_MAX, 120 s) is a killed worker's: break
      # it. Two workers racing the break can both read this one screen, which is harmless (atomic write).
      [ -d "$pf.lock" ] && [ $(( $(date +%s) - $(_osrc_hub_mt "$pf.lock") )) -gt "$(_sv_num "${OSRC_HUB_SCR_LOCK_MAX:-}" 120)" ] && rmdir "$pf.lock" 2>/dev/null
      mkdir "$pf.lock" 2>/dev/null || continue
      out="$(_osrc_hub_raw_sv_target_screen "$id" 2>/dev/null)" || out=""
      if [ -n "$out" ]; then
        dep="$(_osrc_hub_scr_dep_epoch "$id")"; case "$dep" in ''|*[!0-9]*) dep=0 ;; esac
        { printf '%s %s %s\n' "$act" "$dep" "$(date +%s)"; printf '%s\n' "$out"; } > "$pf.$$" 2>/dev/null \
          && mv -f "$pf.$$" "$pf" 2>/dev/null
        rm -f "$pf.$$" 2>/dev/null
      fi
      rmdir "$pf.lock" 2>/dev/null
    done < "$wf" 2>/dev/null
    # Queued done-contract probes (lib/hub-perf.sh): the real reader spawns/refreshes each verdict cache.
    while read -r id; do
      [ -n "$id" ] && _osrc_hub_rawosrc_done_state "$id" >/dev/null 2>&1
    done < "$dwf" 2>/dev/null
    rm -f "$wf" "$dwf" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  return 0
}

_osrc_hub_scr_put() { # <id> <output-file>: persist a screen read for later exports
  local id="$1" of="$2" pf="$OSRC_HOME/hub/cache/scr/$1" act row dep now
  [ "${OSRC_HUB_FAST:-0}" = 1 ] && _osrc_hub_slug_ok "$id" && [ -s "$of" ] || return 0
  row="$(_osrc_hub_tmux_row "$id" 2>/dev/null)" || return 0
  act="${row##* }"; case "$act" in ''|*[!0-9]*) return 0 ;; esac
  mkdir -p "$OSRC_HOME/hub/cache/scr" 2>/dev/null && [ ! -L "$OSRC_HOME/hub/cache/scr" ] || return 0
  dep="$(_osrc_hub_scr_dep_epoch "$id")"; case "$dep" in ''|*[!0-9]*) dep=0 ;; esac
  now="${OSRC_NOW:-$(date +%s)}"
  { printf '%s %s %s\n' "$act" "$dep" "$now"; cat "$of"; } > "$pf.$$" 2>/dev/null || { rm -f "$pf.$$"; return 0; }
  [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -f "$_OSRC_HUB_MEMO/start" ] && touch -r "$_OSRC_HUB_MEMO/start" "$pf.$$" 2>/dev/null
  mv -f "$pf.$$" "$pf" 2>/dev/null; rm -f "$pf.$$" 2>/dev/null
  return 0
}

# ---- export phase profiling (OSRC_HUB_PROF=/path file -> "epoch_ns tag" rows) -------------------
# The export asks _osrc_hub_prof at phase boundaries; when unset the calls are free.
# Nanoseconds, portably: bash 5's EPOCHREALTIME; else GNU date's %N; else (macOS date prints a literal
# N, bash 3.2 has no EPOCHREALTIME) whole seconds, still a valid number for the reader.
_osrc_hub_prof() { # <tag>
  [ -n "${OSRC_HUB_PROF:-}" ] || return 0
  local t="${EPOCHREALTIME:-}" u
  case "$t" in
    *[.,]*) u="${t#*[.,]}000000"; t="${t%%[.,]*}${u:0:6}000" ;;
    *) t="$(date +%s%N 2>/dev/null)"; case "$t" in ''|*[!0-9]*) t="$(date +%s)000000000" ;; esac ;;
  esac
  printf '%s %s\n' "$t" "$1" >> "$OSRC_HUB_PROF" 2>/dev/null
}

# ---- fast pre-check: does unowned have ANY live lane? (avoids 6s work when none live) ----------
# rc0 = at least one unclaimed lane is (or may be) live; rc1 = none. Conservative: anything that
# cannot be proven settled counts as live, so the caller's full build never loses a lane.
# Remote lanes are triaged in ONE jq pass over remote/*.json that mirrors osrc_remote_state minus
# the review-verdict refinement (verdicts only settle "ready" lanes, so a head_ready lane still
# needs the real call — those are rare and checked one by one).
_osrc_hub_unowned_has_live() {
  local _nl='
'
  local claimed="" d f id jd st rc
  for d in "$OSRC_HOME"/owners/*/; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do [ -f "$f" ] && claimed="${claimed}${f##*/}${_nl}"; done
  done
  local -a rfs=()
  for f in "$OSRC_HOME"/remote/*.json; do [ -f "$f" ] && rfs+=("$f"); done
  if [ "${#rfs[@]}" -gt 0 ]; then
    type osrc_remote_state >/dev/null 2>&1 || return 0   # no state fn -> cannot prove settled
    local rtsv
    rtsv="$(jq -r '
      (input_filename | sub(".*/";"") | sub("\\.json$";"")) as $id
      | . as $r | ($r.head // "") as $head | ($r.check // {}) as $ch
      | if ($r.branch_deleted == true) then empty
        elif ($head != "" and ($ch.head // "") == $head and ($ch.state // "") == "done"
              and ((($ch.rc // 0) | tostring) != "0")) then empty
        elif ($head == "" or ($r.proof_back // "") == $head) then "L\t" + $id
        elif ($r.head_ready == true) then
          (if ($ch.head // "") == $head and ($ch.state // "") == "running" then "L\t" + $id else "R\t" + $id end)
        else "L\t" + $id
      end' "${rfs[@]}" 2>/dev/null)" || return 0   # unparseable lane files -> build (conservative)
    local bucket
    while IFS="$(printf '\t')" read -r bucket id; do
      [ -n "$id" ] || continue
      case "$_nl$claimed" in *"$_nl$id$_nl"*) continue ;; esac
      if [ "$bucket" = L ]; then return 0; fi
      [ "$(osrc_remote_state "$id" 2>/dev/null)" = live ] && return 0
    done <<EOF
$rtsv
EOF
  fi
  for jd in "$OSRC_JOBS"/*/; do
    [ -d "$jd" ] || continue
    id="${jd%/}"; id="${id##*/}"
    case "$_nl$claimed" in *"$_nl$id$_nl"*) continue ;; esac
    st=""; [ -f "$jd/status" ] && IFS= read -r st 2>/dev/null < "$jd/status" || true
    case "$st" in done|'done?'|failed|blocked|timeout|wedged|canceled|permission-blocked|interrupted) continue ;; esac
    if [ -s "$jd/exit" ]; then
      IFS= read -r rc 2>/dev/null < "$jd/exit" || rc=""
      case "$rc" in ''|*[!0-9]*) ;; *) continue ;; esac
    fi
    st="$(_osrc_hub_job_state_fast "$id")"
    case "$st" in running|live|working|launching|stalled\?|exploring\?|no-progress-writes)
      [ "$(_osrc_hub_done_state "$id")" = done ] && continue
      return 0 ;;
    esac
  done
  return 1
}

# ---- batched ended-lane assembly (per-lane persistent caches, ONE stat pass per export) ---------
# A project keeps its ended lanes (seen/<slug>/) listed for OSRC_HUB_ENDED_HOURS; on a fleet
# project that is 50-150 lane rebuilds per export (~0.3 s each). Ended lanes only move through
# files (job dir, remote lane, proof, done contract, review items, autodetach) or their registry
# ts — both checkable without rebuilding — so each lane caches its JSON + activity epoch under
# hub/cache/ended/ and a single stat batch validates every cached lane at once. A lane whose pid
# is still live, whose tmux session exists, or whose registry moved is rebuilt like before.
_osrc_hub_ended_pid_live() { # <id> -> rc0 when a recorded job pid is still running
  local jd="$OSRC_JOBS/$1" p v
  [ -d "$jd" ] || return 1
  for p in pid supervisor_pid; do
    v=""; [ -f "$jd/$p" ] && IFS= read -r v 2>/dev/null < "$jd/$p"
    case "$v" in ''|*[!0-9]*) ;; *) kill -0 "$v" 2>/dev/null && return 0 ;; esac
  done
  return 1
}

_osrc_hub_ended_lane_put() { # <id> <lane-json> <act-epoch>: store, stamped with the export's start
  local id="$1" lane="$2" act="${3:-0}" d="$OSRC_HOME/hub/cache/ended" ts=""
  _osrc_hub_slug_ok "$id" && [ -n "$lane" ] && [ -n "${_OSRC_HUB_MEMO:-}" ] || return 0
  mkdir -p "$d" 2>/dev/null && [ ! -L "$d" ] || return 0
  ts="$(_osrc_hub_reg_ts "$id" 2>/dev/null)"
  printf '%s\n' "$lane" > "$d/$id.lane.$$" 2>/dev/null && printf '%s\n' "$act" > "$d/$id.act.$$" 2>/dev/null \
    && printf '%s\n' "$ts" > "$d/$id.regts.$$" 2>/dev/null || { rm -f "$d/$id.lane.$$" "$d/$id.act.$$" "$d/$id.regts.$$"; return 0; }
  local t
  for t in lane act regts; do
    [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -f "$_OSRC_HUB_MEMO/start" ] && touch -r "$_OSRC_HUB_MEMO/start" "$d/$id.$t.$$" 2>/dev/null
    mv -f "$d/$id.$t.$$" "$d/$id.$t" 2>/dev/null; rm -f "$d/$id.$t.$$" 2>/dev/null
  done
  return 0
}

# _osrc_hub_ended_lanes_fast <slug> <rmap> -> rc0 with _OSRC_EL_LANES (json array, ended_ids order)
# and _OSRC_EL_LACT (newest activity epoch). rc1 = let the caller run its per-lane loop.
_osrc_hub_ended_lanes_fast() {
  local slug="$1" rmap="$2" ids id
  _OSRC_EL_LANES='[]'; _OSRC_EL_LACT=0
  [ "${OSRC_HUB_FAST:-0}" = 1 ] && [ -n "${_OSRC_HUB_MEMO:-}" ] || return 1
  type _osrc_hub_ended_ids >/dev/null 2>&1 || return 1
  ids="$(_osrc_hub_ended_ids "$slug" 2>/dev/null)"
  [ -n "$ids" ] || return 0
  local d="$OSRC_HOME/hub/cache/ended" cand="" depf mtf
  depf="$_OSRC_HUB_MEMO/eldep.$slug"; mtf="$_OSRC_HUB_MEMO/elmt.$slug"
  : > "$depf" 2>/dev/null || return 1
  local _nl='
' tmux_tab="" rts
  [ -f "$_OSRC_HUB_MEMO/tmux" ] && tmux_tab="$(cat "$_OSRC_HUB_MEMO/tmux" 2>/dev/null)"
  # Phase 1: cache candidates — all three records present, no live tmux session, no live job pid,
  # and the lane's registry ts unchanged since the lane was cached.
  for id in $ids; do
    _osrc_hub_slug_ok "$id" || continue
    [ -f "$d/$id.lane" ] && [ -f "$d/$id.act" ] && [ -f "$d/$id.regts" ] \
      && [ ! -L "$d/$id.lane" ] && [ ! -L "$d/$id.act" ] && [ ! -L "$d/$id.regts" ] || continue
    case "$_nl$tmux_tab$_nl" in *"$_nl$id "*) continue ;; esac
    _osrc_hub_ended_pid_live "$id" && continue
    rts=""; [ -f "$_OSRC_HUB_MEMO/reg/$id.ts" ] && IFS= read -r rts 2>/dev/null < "$_OSRC_HUB_MEMO/reg/$id.ts"
    local stored=""; IFS= read -r stored 2>/dev/null < "$d/$id.regts" || stored=""
    [ "$rts" = "$stored" ] || continue
    cand="$cand $id"
  done
  # Phase 2: ONE stat pass over every dependency of every candidate. D = dep path, C = cache file.
  local p valid="" stale
  if [ -n "$cand" ]; then
    for id in $cand; do
      printf '%s\tC\t%s\n' "$id" "$d/$id.lane" >> "$depf"
      for p in "$OSRC_HOME/remote/$id.json" "$OSRC_JOBS/$id/"* "$OSRC_HOME/done/$id.json" \
               "$OSRC_HOME/proof/$id/"* "$OSRC_HOME/review/items/$id"-*.json \
               "$OSRC_HOME/autodetach/$id".* "$OSRC_HOME/hub/seen/$slug/$id" \
               "$OSRC_HOME/hub/lanenames/$id"; do
        [ -e "$p" ] && printf '%s\tD\t%s\n' "$id" "$p" >> "$depf"
      done
    done
    # A done contract's handed-in file lives outside OSRC_HOME: resolve file: specs in ONE jq.
    local dlist=""
    for id in $cand; do [ -f "$OSRC_HOME/done/$id.json" ] && dlist="$dlist $OSRC_HOME/done/$id.json"; done
    if [ -n "$dlist" ]; then
      local row did spec cwd hf
      while IFS="$(printf '\t')" read -r did spec cwd; do
        [ -n "$did" ] || continue
        hf="${spec#file:}"; case "$hf" in /*) ;; *) hf="${cwd:-.}/$hf" ;; esac
        [ -e "$hf" ] && printf '%s\tD\t%s\n' "$did" "$hf" >> "$depf"
      done <<EOF
$(jq -r '[(input_filename | sub(".*/";"") | sub("\\.json$";"")), (.spec // ""), (.cwd // "")] | @tsv' $dlist 2>/dev/null | awk -F'\t' '$2 ~ /^file:/')
EOF
    fi
    # GNU first: GNU `stat -f` is filesystem status, so the lane cache only ever expired by TTL.
    local sfl=-c sfm='%Y %n'; stat -c %Y "$depf" >/dev/null 2>&1 || { sfl=-f; sfm='%m %N'; }
    cut -f3 "$depf" | tr '\n' '\0' | xargs -0 stat "$sfl" "$sfm" > "$mtf" 2>/dev/null
    stale="$(awk -F'\t' 'NR==FNR { m=$0; sub(/ .*/,"",m); p=$0; sub(/^[^ ]+ /,"",p); mt[p]=m+0; next }
      { if ($2=="C") cmt[$1]=mt[$3]+0; else if ((mt[$3]+0) > dm[$1]) dm[$1]=mt[$3]+0 }
      END { for (i in cmt) if (dm[i] > cmt[i]) print i }' "$mtf" "$depf" 2>/dev/null)"
    for id in $cand; do case "$_nl$stale$_nl" in *"$_nl$id$_nl"*) ;; *) valid="$valid $id" ;; esac; done
  fi
  # Phase 3: assemble in ended_ids order — cached lanes read their records, the rest rebuild
  # through the original path and re-cache.
  local lane act rows="" lact=0
  for id in $ids; do
    _osrc_hub_slug_ok "$id" || continue
    lane=""; act=0
    case " $valid " in
      *" $id "*)
        IFS= read -r lane 2>/dev/null < "$d/$id.lane" || lane=""
        IFS= read -r act 2>/dev/null < "$d/$id.act" || act=0 ;;
    esac
    if [ -z "$lane" ]; then
      lane="$(_osrc_hub_ended_lane "$id" "$rmap")"
      [ -n "$lane" ] && type osrc_proof_hub_lane >/dev/null 2>&1 && lane="$(osrc_proof_hub_lane "$lane" "$id")"
      act="$(_osrc_hub_lane_activity "$id")"; act="${act%% *}"
      [ -n "$lane" ] && _osrc_hub_ended_lane_put "$id" "$lane" "${act:-0}"
    fi
    [ -n "$lane" ] || continue
    rows="${rows}${lane}
"
    [ "${act:-0}" -gt "$lact" ] 2>/dev/null && lact="$act"
  done
  if [ -n "$rows" ]; then
    _OSRC_EL_LANES="$(jq -cs '.' <<<"$rows" 2>/dev/null || printf '[]')"
  fi
  _OSRC_EL_LACT="$lact"
  return 0
}

# _osrc_hub_sessions_total <slug> -> every distinct lane the session ever owned: the current
# owners/ dir + the seen/ record (the same source _osrc_hub_ended_ids trusts) + any job whose
# meta still names it owner. Job metas are indexed ONCE per export into the memo; per project
# the count is two dir listings + a grep — no lane rebuild, no per-lane stat.
_osrc_hub_sessions_total() {
  local slug="$1" ids="" d f
  _osrc_hub_slug_ok "$slug" || { printf '0'; return 0; }
  for d in "$OSRC_HOME/owners/$slug" "$OSRC_HOME/hub/seen/$slug"; do
    for f in "$d"/*; do
      [ -f "$f" ] || continue
      f="${f##*/}"
      case "$f" in .*|watch.*) continue ;; esac
      ids="$ids $f"
    done
  done
  if [ -n "${_OSRC_HUB_MEMO:-}" ]; then
    local jm="$_OSRC_HUB_MEMO/jobown.tsv"
    if [ ! -f "$jm" ]; then
      jq -r '[(.owner // ""), (input_filename | sub("/meta.json$"; "") | sub(".*/"; ""))] | @tsv' \
        "$OSRC_JOBS"/*/meta.json 2>/dev/null > "$jm" 2>/dev/null || : > "$jm"
    fi
    ids="$ids $(awk -F'\t' -v s="$slug" '$1 == s { print $2 }' "$jm" 2>/dev/null)"
  else
    ids="$ids $(jq -r 'select((.owner // "") == "'"$slug"'") | input_filename | sub("/meta.json$"; "") | sub(".*/"; "")' \
      "$OSRC_JOBS"/*/meta.json 2>/dev/null)"
  fi
  printf '%s\n' $ids | sort -u | grep -c .
}
