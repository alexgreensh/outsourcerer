#!/usr/bin/env bash
# lib/hub-truth.sh -- Mission Control cards that tell the truth for every orchestrator. Sourced by
# outsourcerer.sh (and by hub.sh for suites that source it alone); defines functions only.
# Bash 3.2 and Git Bash safe: no associative arrays, no mapfile, no GNU-only flags without a fallback.
#
#  1. Derived cards. Each export derives a card's status, percent, summary and next step from the
#     lanes themselves (states, READY markers, review verdicts, merges, last activity). An
#     orchestrator's `hub report` words ride along as .reported with their age; they win only while
#     they are newer than the newest live evidence.
#  2. Orchestrator liveness: working, idle N min or gone, from the Claude session registry, the
#     heartbeat and the transcript. Loud alerts for "lanes running, orchestrator idle" and "lane
#     finished, nobody picked it up".
#  3. One card per project: sessions on the same project (explicit key, or same repo + name) merge.
#  4. One registry pass per export (_osrc_hub_cc_rows) and a single-flight export (cmd_hub_export).
#  5. attention: one value per lane and per project, in the order references/hub.md writes down.

# ---- 1. derive ----------------------------------------------------------------------------------
# dcount: lanes -> counts and the lanes worth naming. A lane's category comes from its status
# (review verdicts and done contracts are already folded in) and its live state.
_OSRC_HUB_DERIVE_JQ='
def dcat: if (.status // "") | IN("Merged", "Shipped") then "merged"
  elif .status == "Failed" or .state == "failed" then "failed"
  elif .status == "Canceled" then "canceled"
  elif .status == "Review" then "ready"
  elif .status == "Done" or .state == "done" then "done"
  elif .status == "Blocked" or ((.state // "") | IN("approval", "question", "limit")) then "blocked"
  elif .status == "Idle" or .state == "idle" then "idle"
  else "working" end;
def dcount: (. // []) | map(. + {_c: dcat}) as $l
  | reduce ("working","blocked","idle","ready","done","merged","failed","canceled") as $k
      ({n: ($l | length)}; .[$k] = ([$l[] | select(._c == $k)] | length))
  | . + {pick: (reduce ("blocked","ready","done","failed") as $k ({};
           .[$k] = ([$l[] | select(._c == $k) | (.short // .id)] | .[0:3]))),
         finished: [$l[] | select((._c | IN("ready","done")) and ((.ended // false) | not) and (.activeAt // 0) > 0)
                   | {id, short: (.short // .id), at: .activeAt}]};
def dplural($n; $w): "\($n) \($w)\(if $n == 1 then "" else "s" end)";
def dnames($a; $n): ($a | join(", ")) + (if $n > ($a | length) then " and \($n - ($a | length)) more" else "" end);
def dtext: . as $c
  | (if .n == 0 then null
     elif .working + .blocked > 0 then "building"
     elif .ready > 0 then "review"
     else "idle" end) as $st
  | (if .n == 0 then null else
      dplural(.n; "lane") + ": " + ([["working","working"],["blocked","waiting for approval"],["idle","idle"],
        ["ready","ready for review"],["done","done"],["merged","merged"],["failed","failed"],["canceled","canceled"]]
        | map(select($c[.[0]] > 0) | "\($c[.[0]]) \(.[1])") | join(", ")) end) as $sum
  | (if .blocked > 0 then "Unblock " + dnames(.pick.blocked; .blocked) + ": waiting for approval"
     elif .ready > 0 then "Review " + dnames(.pick.ready; .ready)
     elif .done > 0 then "Pick up the result of " + dnames(.pick.done; .done)
     elif .failed > 0 and .working == 0 then "Look at the failed " + dnames(.pick.failed; .failed)
     elif .working > 0 then "Wait for " + dplural(.working; "working lane")
     else null end) as $next
  | {status: $st, summary: $sum, next: $next};
def dmerge: reduce .[] as $c ({n:0,working:0,blocked:0,idle:0,ready:0,done:0,merged:0,failed:0,canceled:0,
    pick:{blocked:[],ready:[],done:[],failed:[]}, finished:[], evidenceAt:0};
  reduce ("n","working","blocked","idle","ready","done","merged","failed","canceled") as $k (.; .[$k] += ($c[$k] // 0))
  | reduce ("blocked","ready","done","failed") as $k (.; .pick[$k] = ((.pick[$k] + ($c.pick[$k] // []))[0:3]))
  | .finished += ($c.finished // []) | .evidenceAt = ([.evidenceAt, ($c.evidenceAt // 0)] | max));
# attention: what a lane asks of you, most urgent first (references/hub.md, "Attention"). Stalled lanes
# are the ones whose nudge did not help (lib/mc_alive.sh needs-you alerts).
def attn_order: ["approval","question","proof","review","stalled","limit","ready","failed","working","finished"];
def lattn($stalled): if .state == "approval" then "approval" elif .state == "question" then "question"
  elif (.proof.stopped? // false) == true then "proof" elif .reviewNeedsYou != null then "review"
  elif ((.id // "") | IN($stalled[])) then "stalled" elif .state == "limit" then "limit"
  else (dcat | if . == "ready" then "ready" elif . == "failed" then "failed"
               elif IN("done","merged","canceled") then "finished" else "working" end) end;
def iso_ep: if type == "string" and length > 0 then (sub("\\.[0-9]+"; "") | fromdateiso8601? // null) else null end;'

# _osrc_hub_derive <lanes-json> <evidence-epoch> -> derived JSON {counts..., evidenceAt, status, summary, next}.
# No percent: finished lanes over lanes says nothing about a plan (2 of a 20-step plan's first 2 lanes
# done is not 100%), so a percent comes only from a board or the orchestrator's own report.
_osrc_hub_derive() {
  jq -c --argjson ev "${2:-0}" "$_OSRC_HUB_DERIVE_JQ"' dcount + {evidenceAt: $ev} | . + dtext' <<<"$1" 2>/dev/null
}

# ---- 2. one registry pass + orchestrator liveness -------------------------------------------------
# _osrc_hub_cc_rows -> one line per Claude Code session file:
#   sid|cwd|status|status-updated-ms|pid|job|waiting-for|alive(0/1)|transcript-mtime
# ONE jq over every file (per-file only if one is malformed), kill -0 per pid and one stat pass for
# the transcripts. The export computes it once (_OSRC_HUB_CC_ROWS) and every reader reuses it. The cache
# counts only once _OSRC_HUB_CC_ROWS_SET=1: bash 3.2's bare `local X` leaves X set and empty.
_osrc_hub_cc_rows() {
  if [ "${_OSRC_HUB_CC_ROWS_SET:-}" = 1 ]; then printf '%s' "${_OSRC_HUB_CC_ROWS:-}"; return 0; fi
  local d="${OSRC_CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}" pd="${OSRC_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
  local f raw flt sid cwd st su pid job wf alive tp
  [ -d "$d" ] && have jq || return 0
  local -a fs=() tps=()
  for f in "$d"/*.json; do [ -f "$f" ] && [ ! -L "$f" ] && fs+=("$f"); done
  [ "${#fs[@]}" -gt 0 ] || return 0
  flt='objects | [(.sessionId // ""), (.cwd // ""), (.status // ""), (.statusUpdatedAt // .updatedAt // 0), (.pid // ""), (.jobId // ""), (.waitingFor // "")]
       | map(tostring | gsub("[|\t\n\r]"; " ")) | join("|")'
  raw="$(jq -r "$flt" "${fs[@]}" 2>/dev/null)" || raw="$(for f in "${fs[@]}"; do jq -r "$flt" "$f" 2>/dev/null; done)"
  local rows=""
  while IFS='|' read -r sid cwd st su pid job wf; do
    case "$sid" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case "$su" in ''|*[!0-9]*) su=0 ;; esac
    alive=0; kill -0 "$pid" 2>/dev/null && alive=1
    tp="$pd/${cwd//[!A-Za-z0-9]/-}/$sid.jsonl"
    [ -f "$tp" ] && tps+=("$tp")
    rows="$rows$sid|$cwd|$st|$su|$pid|$job|$wf|$alive|$tp
"
  done <<EOF
$raw
EOF
  # One stat for every transcript (GNU first: GNU `stat -f` is filesystem status), joined by path.
  local mt=""
  if [ "${#tps[@]}" -gt 0 ]; then
    mt="$(stat -c '%Y|%n' "${tps[@]}" 2>/dev/null)" || mt="$(stat -f '%m|%N' "${tps[@]}" 2>/dev/null)"
  fi
  # The mtimes go in on stdin ahead of the rows: macOS awk rejects a multi-line -v ("newline in string").
  { [ -z "$mt" ] || printf '%s\n' "$mt"; printf '@rows\n%s' "$rows"; } | awk -F'|' -v OFS='|' '
    !r { if ($0 == "@rows") r = 1; else { p = index($0, "|"); if (p) t[substr($0, p + 1)] = substr($0, 1, p - 1) }; next }
    NF >= 9 { tp = $9; $9 = (tp in t) ? t[tp] : 0; print }'
}

# _osrc_hub_orch_state <sid> <now> -> {id, state: working|idle|gone, idleMin, lastAt}.
# Evidence: the session registry (process alive, busy/idle), the heartbeat (lib/hub-report.sh: the
# session's own commands and stop guard; a supervisor's tick never beats) and the transcript. A live process that is not busy is idle since its last sign of life;
# no live process and no sign of life for OSRC_MC_ORCH_GONE_MIN (240) min is gone.
_osrc_hub_orch_state() {
  local sid="$1" now="$2" last row st su alive tm gone="${OSRC_MC_ORCH_GONE_MIN:-240}" state idle
  case "$gone" in ''|*[!0-9]*) gone=240 ;; esac
  last="$(_osrc_hub_mt "$OSRC_HOME/hub/seen/$sid/.beat" \
    "${OSRC_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"/*/"$sid".jsonl)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  # A resumed session can leave an older file behind: the live row wins.
  row="$(_osrc_hub_cc_rows | awk -F'|' -v s="$sid" '$1 == s { if ($8 == 1) { print; f = 1; exit } if (r == "") r = $0 } END { if (!f && r != "") print r }')"
  if [ -n "$row" ]; then
    IFS='|' read -r _ _ st su _ _ _ alive tm <<EOF
$row
EOF
    case "$tm" in ''|*[!0-9]*) tm=0 ;; esac; [ "$tm" -gt "$last" ] && last="$tm"
    su=$(( ${su:-0} / 1000 )); [ "$su" -gt "$last" ] && [ "$su" -le "$now" ] && last="$su"
    if [ "$alive" != 1 ]; then state=gone
    else case "$st" in working|busy|running) state=working ;; *) state=idle ;; esac; fi
  elif [ "$last" -gt 0 ] && [ $(( now - last )) -lt 120 ]; then state=working
  elif [ "$last" -eq 0 ] || [ $(( now - last )) -ge $(( gone * 60 )) ]; then state=gone
  else state=idle; fi
  idle=0; [ "$last" -gt 0 ] && [ "$now" -gt "$last" ] && idle=$(( (now - last) / 60 ))
  jq -cn --arg id "$sid" --arg s "$state" --argjson i "$idle" --argjson l "$last" \
    '{id:$id, state:$s, lastAt:$l} + (if $s == "working" then {} else {idleMin:$i} end)'
}

# ---- 3. truth: live evidence vs the orchestrator's words, plus the loud alerts -------------------
# _osrc_hub_truth <project-json> <now>: the doc carries .derived (lib/hub.sh build) and .orchestrators.
# Running lanes and evidence newer than the report win; a report newer than every settled lane stays, with its
# age. A user's Mark done and a reported "shipped" with nothing running are never overridden.
_osrc_hub_truth() {
  local im="${OSRC_MC_ORCH_IDLE_MIN:-15}" pm="${OSRC_MC_PICKUP_MIN:-10}"
  case "$im" in ''|*[!0-9]*) im=15 ;; esac; case "$pm" in ''|*[!0-9]*) pm=10 ;; esac
  jq -c --argjson now "$2" --argjson im "$im" --argjson pm "$pm" "$_OSRC_HUB_DERIVE_JQ"'
    def mins($t): (($now - $t) / 60 | floor);
    (.derived // null) as $d
    | (if $d == null then null else $d + ($d | dtext) end) as $d
    | (.reportedAt | iso_ep) as $rep
    | (if (.liveLanes // 0) > 0 then $now else ($d.evidenceAt // 0) end) as $ev
    | (if .reported then .reported + {ageMin: (if $rep then mins($rep) else null end)} else null end) as $r
    | ($d != null and $d.n > 0 and ($rep == null or $ev > $rep or (.liveLanes // 0) > 0)
       and (.shippedBy // "") != "user" and ((.status == "shipped" and (.liveLanes // 0) == 0) | not)) as $live
    | (if $r then .reported = $r else del(.reported) end)
    | if $live then
        . + {source:"live", status:$d.status, summary:$d.summary, summaryAt:($now | todate), cardStale:false}
        | del(.cardAgeMin)
        # Words stay while the report is younger than the card-stale window. Percent: the board one, else the
        # report percent while fresh; never one made from lane counts.
        | ($rep != null and ($now - $rep) < ((.cardStaleMin // 30) * 60)) as $fresh
        | (if (.boardTracks // 0) > 0 or $fresh then . else del(.pct) end)
        | (if $fresh and ($r.next // "") != "" then .next = $r.next elif $d.next == null then del(.next) else .next = $d.next end)
        | (if ($fresh | not) and $r and $r.eta == .eta then del(.eta, .etaNote) else . end)
      else
        . + {source:(if $r then "report" else "live" end)}
        | (if $d == null then . else
            (if (.status // "") == "" and $d.status then .status = $d.status else . end)
            | (if ((.summary // "") == "" or ($r != null and ($r.summary // null) == null)) and $d.summary then
                 .summary = $d.summary | .summaryAt = ($now | todate) else . end)
            | (if (.next // "") == "" and (.cardStale // false | not) and $d.next then .next = $d.next else . end)
          end)
        | (if (.status // "") == "" then .status = "idle" else . end)
      end
    | (.orchestrators // []) as $o
    | ([$o[] | select((.running // 0) > 0 and .state != "working" and (.state == "gone" or (.idleMin // 0) >= $im))
        | {kind:"orch-idle", orch:.id, since:(if (.lastAt // 0) > 0 then .lastAt else null end),
           text:("lanes running, orchestrator " + (if .state == "gone" then "gone" else "idle \(.idleMin) min" end))}]
       + [($d.finished // [])[] | . as $f | ($o | map(select(.id == ($f.orch // .id))) | .[0] // {lastAt:0}) as $or
          | select(mins($f.at) >= $pm and ($or.lastAt // 0) < $f.at)
          | {kind:"unpicked", lane:$f.id, since:$f.at, text:("lane \($f.short) finished \(mins($f.at)) min ago, nobody picked it up")}]) as $al
    | (if ($al | length) > 0 then .alerts = ((.alerts // []) + $al) else . end)
    # One attention per lane; the project shows its highest (an open question counts too).
    | ([.alerts[]? | select(.lane != null and ((.kind // "") | IN("unreviewed", "unpicked") | not)) | .lane]) as $st
    | (if has("lanes") then .lanes |= map(. + {attention: lattn($st)}) else . end)
    | ([.lanes[]?.attention] + (if any(.decisions[]?; (.status // "wait") != "done") then ["question"] else [] end)) as $as
    | (attn_order | map(select(IN($as[]))) | .[0]) as $pa
    | (if $pa then .attention = $pa else del(.attention) end)
    | del(.derived)
  ' <<<"$1" 2>/dev/null || printf '%s' "$1"
}

# _osrc_hub_with_orch <project-json> <slug> <now> -> doc with .orchestrators [{...liveness, running}]
# and its finished lanes tagged with that orchestrator, ready for grouping and _osrc_hub_truth.
_osrc_hub_with_orch() {
  local o; o="$(_osrc_hub_orch_state "$2" "$3")" || o=""
  [ -n "$o" ] || { printf '%s' "$1"; return 0; }
  jq -c --argjson o "$o" '(.derived // {}) as $d
    | .orchestrators = [$o + {running: (($d.working // 0) + ($d.blocked // 0)), lanes: ($d.n // 0)}]
    | (if .derived then .derived.finished = [(.derived.finished // [])[] | . + {orch: $o.id}] else . end)' <<<"$1" 2>/dev/null || printf '%s' "$1"
}

# ---- 4. one card per project ----------------------------------------------------------------------
# _osrc_hub_group <projects-json-array> -> the array with sessions of one project merged into one card.
# Key: an explicit `hub report --project KEY`; else the repo/folder plus the reported name. A session
# that never named the project joins the one name reported in its folder; with none reported, its
# derived name and title ("Demo · ship 0.16.1") key it, so unrelated work in one repo stays apart. The card keeps the id of
# its primary session (one with a Mark done record, else a reported name, else the most recently
# active), lists every orchestrator, tags each lane and decision with its session (decisions keep
# their owner so answers reach the right session), and takes the newest report among them.
_osrc_hub_group() {
  jq -c "$_OSRC_HUB_DERIVE_JQ"'
    def loc: ((.repo // .folder // "") | ascii_downcase);
    def rname: (if has("_base") then "" else (.name // "") | ascii_downcase end);
    (map(select(.projectKey == null and loc != "" and rname != "")) | group_by(loc)
      | map({key: (.[0] | loc), value: (map(rname) | unique)}) | from_entries) as $names
    | map(. + {_gk: (if (.projectKey // "") != "" then "k:" + .projectKey
                     elif loc == "" then "id:" + .id
                     else (rname as $n | ($names[loc] // []) as $ns
                       | "f:" + loc + "|" + (if $n != "" then $n elif ($ns | length) == 1 then $ns[0]
                                            else "~" + ((._base // "") + " · " + (._detail // "") | ascii_downcase) end)) end)})
    | group_by(._gk)
    | map(if length == 1 then .[0] else
        (sort_by([(if (.shippedBy // "") == "user" or (._hasStatus // false) then 0 else 1 end),
                  (if has("_base") then 1 else 0 end), -([.orchestrators[]?.lastAt] | max // 0)]) ) as $m
        | ($m | max_by(.reportedAt // "")) as $rep
        | ($m[0].shippedBy // "") as $user
        | ($m[0] | del(.reported, .reportedAt, .pct, .eta, .etaNote, .next, .summary, .summaryAt, .cardStale, .cardAgeMin)
                 | if $user == "user" then . else del(.status) end)
        + ($rep | {reported, reportedAt, pct, eta, etaNote, next, summary, summaryAt, cardStale, cardAgeMin}
                + (if $user == "user" then {} else {status} end) | with_entries(select(.value != null)))
        + {members: [$m[].id],
           lanes: [$m[] | .id as $o | .lanes[]? | . + {orch: $o}],
           decisions: [$m[] | .id as $o | .decisions[]? | . + {owner: $o}],
           alerts: [$m[].alerts[]?],
           orchestrators: [$m[].orchestrators[]?],
           liveLanes: ([$m[].liveLanes // 0] | max),
           sessionsNow: ([$m[].sessionsNow // 0] | add), sessionsRun: ([$m[].sessionsRun // 0] | add),
           sessionsTotal: ([$m[].sessionsTotal // 0] | add),
           updatedAt: ([$m[].updatedAt // empty] | max), quiet: all($m[]; .quiet // false),
           derived: ([$m[].derived // empty] | if length == 0 then null else dmerge end)}
        | with_entries(select(.value != null))
      end)
    | map(del(._gk, ._hasStatus))' <<<"$1" 2>/dev/null || printf '%s' "$1"
}

# ---- 5. single-flight export ----------------------------------------------------------------------
# cmd_hub_export [--project <slug>] -> SCHEMA docs JSON on stdout (_osrc_hub_export_run, lib/hub.sh).
# Single-flight per argument set: a second caller reuses the export already running.
cmd_hub_export() {
  local k="all" a
  for a in "$@"; do _osrc_hub_slug_ok "$a" && k="p-$a"; done
  _osrc_hub_single_flight "$k.f${OSRC_HUB_FAST:-0}${OSRC_HUB_REFRESH:-0}" _osrc_hub_export_run "$@"
}

# _osrc_hub_single_flight <key> <cmd...>: one export per key at a time. A caller that finds one in
# flight waits for it and prints its result (written after the caller arrived) instead of starting
# a second one. A lock whose leader died, or one older than OSRC_HUB_EXPORT_STALE (60) s whatever pid
# it records (a SIGKILLed leader's pid can be reused), is taken over along with the leader's temp file;
# after OSRC_HUB_EXPORT_WAIT (180) s the caller runs its own export, so a lock never blocks for good.
_osrc_hub_single_flight() {
  local key="$1" d="$OSRC_HOME/hub/flight" lk out start pid rc age me m m0 seen=0
  local wait="${OSRC_HUB_EXPORT_WAIT:-180}" stale="${OSRC_HUB_EXPORT_STALE:-60}"; shift
  case "$wait" in ''|*[!0-9]*) wait=180 ;; esac; case "$stale" in ''|*[!0-9]*) stale=60 ;; esac
  lk="$d/$key.lock"; out="$d/$key.json"; start="$(date +%s)"
  { [ ! -L "$OSRC_HOME/hub" ] && [ ! -L "$d" ] && mkdir -p "$d" 2>/dev/null; } || { "$@"; return; }
  me="$(exec sh -c 'echo $PPID')"   # this (sub)shell's pid; bash 3.2 has no BASHPID
  m0="$(_osrc_hub_mt "$out")"
  while :; do
    # A follower reuses the result written after it arrived: one that changed since then, even while the
    # next leader runs, or one from this second once the lock is gone.
    if [ "$seen" = 1 ] && [ -f "$out" ]; then m="$(_osrc_hub_mt "$out")"
      if [ "$m" != "$m0" ] || { [ ! -d "$lk" ] && [ "$m" -ge "$start" ]; }; then cat "$out"; return 0; fi
    fi
    if mkdir "$lk" 2>/dev/null; then
      printf '%s\n' "$me" > "$lk/pid" 2>/dev/null
      "$@" > "$out.$me"; rc=$?
      [ "$rc" = 0 ] && [ -s "$out.$me" ] && mv -f "$out.$me" "$out" 2>/dev/null
      [ "$(cat "$lk/pid" 2>/dev/null)" = "$me" ] && rm -rf "$lk" 2>/dev/null   # a lock taken over is not ours
      if [ -f "$out.$me" ]; then cat "$out.$me"; rm -f "$out.$me"; else cat "$out"; fi
      return "$rc"
    fi
    pid="$(cat "$lk/pid" 2>/dev/null)"; age=$(( $(date +%s) - $(_osrc_hub_mt "$lk") ))
    if [ "$age" -gt "$stale" ] || { [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; } || { [ -z "$pid" ] && [ "$age" -gt 10 ]; }; then
      rm -rf "$lk" 2>/dev/null; [ -z "$pid" ] || rm -f "$out.$pid" 2>/dev/null; continue
    fi
    seen=1; sleep 0.2 2>/dev/null || sleep 1
    [ $(( $(date +%s) - start )) -lt "$wait" ] || { "$@"; return; }
  done
}
