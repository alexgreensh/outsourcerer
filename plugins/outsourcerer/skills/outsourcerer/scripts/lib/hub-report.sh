#!/usr/bin/env bash
# lib/hub-report.sh -- Mission Control that is never empty. Sourced by outsourcerer.sh; defines
# functions only. Bash 3.2 and Git Bash safe: no python, mkfifo, flock or /dev/fd on any path here.
#
# Three things live here:
#  1. Heartbeat + lane memory. $OSRC_HOME/hub/seen/<claude-sid>/ exists once a Claude session has used
#     Outsourcerer (started a lane, ran supervise/session/bg/lane..., or reported). `.beat` is touched by
#     the commands an orchestrator already runs and by the per-turn stop-guard hook, so an orchestrator
#     between lanes stays on the page. seen/<sid>/<target> remembers every lane it owned; a lane that left
#     owners/<sid>/ (finished, reaped by stop-guard or supervise) stays listed as finished for a while.
#     A session that never touched Outsourcerer has no seen/ dir and never appears.
#  2. `hub report`: an orchestrator's own words (status, %, ETA, next step, name, questions for the user),
#     merged atomically into hub/projects/<sid>.json and hub/decisions/<sid>.json.
#  3. Renewal text for the limits table and the page: "in 4 days · Thu 19 Nov", "today · 18:40",
#     "tomorrow · 09:10". Local time, 24h clock, never a count of hours.

# ---- 1. heartbeat + lane memory -----------------------------------------------------------------

_osrc_hub_seen() { printf '%s/hub/seen/%s' "$OSRC_HOME" "$1"; }

# _osrc_hub_sid [sid] -> the sanitized Claude session id, or nothing (no session, a delegate run).
_osrc_hub_sid() {
  local s=""
  if type _owner_sid >/dev/null 2>&1; then s="$(_owner_sid "${1:-}")"; else s="${1:-${CLAUDE_CODE_SESSION_ID:-}}"; fi
  case "$s" in ''|.*|*[!A-Za-z0-9._-]*) return 0 ;; esac
  [ "${#s}" -le 128 ] && printf '%s' "$s"
  return 0
}

# osrc_hub_beat [sid]: this session is an orchestrator and is active now. Never fails the caller.
osrc_hub_beat() {
  local s d; s="$(_osrc_hub_sid "${1:-}")"; [ -n "$s" ] || return 0
  d="$(_osrc_hub_seen "$s")"
  [ -L "$OSRC_HOME/hub" ] || [ -L "$OSRC_HOME/hub/seen" ] || [ -L "$d" ] && return 0
  mkdir -p "$d" 2>/dev/null && touch "$d/.beat" 2>/dev/null
  return 0
}

# _osrc_hub_is_orch <sid> -> rc0 when the session has used Outsourcerer: a seen/ dir, an owners/ dir holding
# at least one real lane (an empty owners dir is not evidence), or its own card.
_osrc_hub_is_orch() {
  local f
  [ -d "$(_osrc_hub_seen "$1")" ] || [ -f "$OSRC_HOME/hub/projects/$1.json" ] && return 0
  for f in "$OSRC_HOME/owners/$1"/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in .*|watch.*) continue ;; esac
    return 0
  done
  return 1
}

# osrc_hub_beat_if_known [sid]: the per-turn path (stop-guard). Refreshes only a session that is already
# an orchestrator, so a Claude session that never used Outsourcerer is never registered by the hook.
osrc_hub_beat_if_known() {
  local s; s="$(_osrc_hub_sid "${1:-}")"; [ -n "$s" ] || return 0
  _osrc_hub_is_orch "$s" || return 0
  osrc_hub_beat "$s"
}

# osrc_hub_seen_lane <sid> <target>: remember a lane (at start, and again when it leaves the registry:
# the mtime then is when it ended). watch.* targets are supervise watches, not lanes.
osrc_hub_seen_lane() {
  local s d; s="$(_osrc_hub_sid "${1:-}")"
  [ -n "$s" ] && [ -n "${2:-}" ] || return 0
  case "$2" in */*|.*|watch.*) return 0 ;; esac
  d="$(_osrc_hub_seen "$s")"; [ -L "$d" ] && return 0
  mkdir -p "$d" 2>/dev/null && touch "$d/.beat" "$d/$2" 2>/dev/null
  return 0
}

# osrc_hub_beat_cmd <cmd> [args]: the dispatcher's one hook. Orchestration verbs beat; read-only and
# statusline paths (tap, brief, help, hub export/serve, limits) never register anyone. Delegates that
# run Outsourcerer inside a delegated run (OUTSOURCERER_DEPTH > 0) are lanes, not orchestrators.
osrc_hub_beat_cmd() {
  type osrc_mc_cmd_hook >/dev/null 2>&1 && osrc_mc_cmd_hook "$@"   # no-watcher warning, Mission Control auto-open (lib/mc_alive.sh)
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || return 0
  case "${OUTSOURCERER_DEPTH:-0}" in ''|0) ;; *) return 0 ;; esac
  case "${1:-}" in
    bg|run|explore|research|edit|yolo|fanout|supervise|wait|lane|review|session|cloud|plan|task|flow|land|status|result|reply|send|adopt|team)
      osrc_hub_beat ;;
  esac
  return 0
}

# _osrc_hub_ended_ids <sid> -> lanes this session owned that are no longer in owners/<sid>/, newest first,
# ended within OSRC_HUB_ENDED_HOURS (default 12). One id per line.
_osrc_hub_ended_ids() {
  local d f id h="${OSRC_HUB_ENDED_HOURS:-12}" cutoff now
  case "$h" in ''|*[!0-9]*) h=12 ;; esac
  d="$(_osrc_hub_seen "$1")"; [ -d "$d" ] && [ ! -L "$d" ] || return 0
  now="$(date +%s)"; cutoff=$(( now - h * 3600 ))
  local -a files=()
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    id="${f##*/}"
    case "$id" in .*|watch.*) continue ;; esac
    [ -e "$OSRC_HOME/owners/$1/$id" ] && continue
    files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  { stat -c '%Y %n' "${files[@]}" 2>/dev/null || stat -f '%m %N' "${files[@]}" 2>/dev/null; } \
    | awk -v cut="$cutoff" '$1 + 0 >= cut { t=$1; sub(/^[^ ]+ /, ""); sub(/^.*\//, ""); print t "\t" $0 }' \
    | sort -rn | cut -f2
}

# _osrc_hub_ended_lane <id> <rmap> -> lane JSON for a lane that left the registry. Uses the real record
# when one is left (job dir, remote lane file). Without done evidence (nothing left, a killed session, a
# last status of Building or Idle) it reads "Closed": the session ended, nobody proved the work done.
_osrc_hub_ended_lane() {
  local id="$1" lane=""
  # A lane with nothing left gets the fixed row below either way; skipping the builders saves 3-4
  # subshells per id (hundreds of ended lanes on a real state home).
  if type _osrc_hub_lane_absent >/dev/null 2>&1 && _osrc_hub_lane_absent "$id"; then
    # The same row the jq below builds, without two jq forks, for an id that needs no JSON escaping.
    case "$id" in *[!A-Za-z0-9._-]*|'') ;; *) printf '{"id":"%s","short":"%s","status":"Closed","note":"session closed","ended":true}\n' "$id" "$id"; return 0 ;; esac
  else
    type _osrc_hub_lane_for >/dev/null 2>&1 && lane="$(_osrc_hub_lane_for "$id" "$2" 2>/dev/null)"
  fi
  [ -n "$lane" ] || lane="$(jq -cn --arg id "$id" '{id:$id, short:$id, status:"Closed", note:"session closed"}')"
  jq -c '. + {ended:true} | if (.status // "") == "" or .status == "Building" or .status == "Idle" then .status = "Closed" else . end' <<<"$lane"
}

# _osrc_hub_active <sid> -> rc0 when the orchestrator reported, beat, or wrote its transcript within
# OSRC_HUB_ACTIVE_MIN (30) minutes. Only for sessions that are orchestrators (seen/ or owners/ dir).
_osrc_hub_active() {
  local s="$1" m="${OSRC_HUB_ACTIVE_MIN:-30}" f
  case "$m" in ''|*[!0-9]*) m=30 ;; esac
  _osrc_hub_is_orch "$s" || return 1
  for f in "$(_osrc_hub_seen "$s")/.beat" "$OSRC_HOME/hub/projects/$s.json" "$HOME"/.claude/projects/*/"$s".jsonl; do
    [ -f "$f" ] && [ -n "$(find "$f" -mmin "-$m" 2>/dev/null)" ] && return 0
  done
  return 1
}

# ---- 2. hub report ------------------------------------------------------------------------------

# _osrc_hub_text <max-chars> <text> -> one clean line: control chars out, whitespace collapsed, $HOME
# shortened, capped by characters (not bytes, so Hebrew never splits). Empty when nothing is left.
_osrc_hub_text() {
  printf '%s' "${2:-}" | jq -Rrs --argjson n "$1" --arg h "$HOME" '
    gsub("[\u0000-\u001f\u007f]"; " ") | (if ($h | length) > 1 then split($h) | join("~") else . end)
    | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")
    | if length > $n then .[0:$n - 1] + "…" else . end' 2>/dev/null
}

# _osrc_hub_write_json <file> <jq-filter> [jq args...]: read-modify-write through a temp file in the same
# folder, then one rename. Refuses symlinks. Never prints the path.
_osrc_hub_write_json() {
  local f="$1" flt="$2" tmp cur; shift 2
  [ -L "$f" ] && { echo "hub report: refusing a symlinked state file" >&2; return 1; }
  cur='null'; [ -f "$f" ] && cur="$(jq -c . "$f" 2>/dev/null)" && [ -n "$cur" ] || cur='null'
  tmp="$f.tmp.$$"
  jq "$@" "$flt" <<<"$cur" > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv -f "$tmp" "$f" && return 0
  rm -f "$tmp" 2>/dev/null
  echo "hub report: could not save the update" >&2
  return 1
}

_osrc_hub_report_usage() {
  cat <<'EOF'
usage: outsourcerer hub report [--status building|review|waiting|shipped] [--pct N] [--eta "<text>"]
                               [--next "<one line>"] [--name "<project name>"]
                               [--ask "<question for the user>" --why "<background>" --rec "<your pick and why>"
                                [--option "<choice>"]... [--when "<needed by>"] [--weight Critical|High|Medium|Low]]
                               [--done-ask <id>] [--board <board.json>] [--project <key>]
Run it from the orchestrator's own Claude Code session. Each flag updates one field of this
session's Mission Control card; fields you leave out keep their last value.
A question must stand on its own for someone who has not followed the work: --why says what this
is about and what changes with the answer, in plain words; --rec gives your pick and why; --option
(two or more) gives buttons. Use --done-ask the moment it is answered anywhere (chat, a board).
--project <key> joins every session that reports the same key into one Mission Control card.
Status, percent, summary and next step are also derived from your lanes; your words show with
their age and never hide newer lane activity.
EOF
}

cmd_hub_report() {
  local pkey="" st="" pct="" eta="" nxt="" name="" ask="" weight="High" done_ask="" board="" any=0 v why="" rec="" when="" opts='[]' nopt=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) _osrc_hub_report_usage; return 0 ;;
      --status|--pct|--eta|--next|--name|--ask|--weight|--done-ask|--why|--rec|--when|--option|--board|--project)
        [ "$#" -ge 2 ] || die "hub report: $1 needs a value"
        v="$2"
        case "$1" in
          --project) pkey="$v" ;; --status) st="$v" ;; --pct) pct="$v" ;; --eta) eta="$v" ;; --next) nxt="$v" ;;
          --name) name="$v" ;; --ask) ask="$v" ;; --weight) weight="$v" ;; --done-ask) done_ask="$v" ;;
          --why) why="$v" ;; --rec) rec="$v" ;; --when) when="$v" ;; --board) [ -n "$v" ] || die "hub report: --board takes a JSON file"; board="$v" ;;
          --option) v="$(_osrc_hub_text 80 "$v")"; [ -n "$v" ] || die "hub report: --option is empty"
                    nopt=$((nopt + 1)); [ "$nopt" -le 5 ] || die "hub report: at most 5 --option"
                    opts="$(jq -c --arg o "$v" '. + [$o]' <<<"$opts")" ;;
        esac
        case "$1" in --weight|--why|--rec|--when|--option) ;; *) any=1 ;; esac
        shift 2 ;;
      *) _osrc_hub_report_usage >&2; die "hub report: unknown option '$1'" ;;
    esac
  done
  [ "$any" = 1 ] || { _osrc_hub_report_usage >&2; die "hub report: nothing to report"; }
  have jq || die "hub report: jq is required"
  local sid; sid="$(_osrc_hub_sid)"
  [ -n "$sid" ] || die "hub report: run this from the orchestrator's Claude Code session (no CLAUDE_CODE_SESSION_ID here)"
  case "$st" in ''|building|review|waiting|shipped) ;; *) die "hub report: --status must be building, review, waiting or shipped" ;; esac
  case "$pct" in '') ;; *[!0-9]*) die "hub report: --pct must be a whole number 0-100" ;;
    *) [ "${#pct}" -le 3 ] && [ "$((10#$pct))" -le 100 ] || die "hub report: --pct must be a whole number 0-100"; pct="$((10#$pct))" ;; esac
  case "$weight" in Critical|High|Medium|Low) ;; *) die "hub report: --weight must be Critical, High, Medium or Low" ;; esac
  [ -z "$eta" ] || { eta="$(_osrc_hub_text 40 "$eta")"; [ -n "$eta" ] || die "hub report: --eta is empty"; }
  [ -z "$nxt" ] || { nxt="$(_osrc_hub_text 160 "$nxt")"; [ -n "$nxt" ] || die "hub report: --next is empty"; }
  [ -z "$ask" ] || { ask="$(_osrc_hub_text 240 "$ask")"; [ -n "$ask" ] || die "hub report: --ask is empty"; }
  # A bare one-line question reads as jargon to anyone outside the session: an ask
  # carries its background and either a recommendation or real choices.
  if [ -n "$ask" ]; then
    why="$(_osrc_hub_text 600 "$why")"; rec="$(_osrc_hub_text 400 "$rec")"; when="$(_osrc_hub_text 40 "$when")"
    [ -n "$why" ] || die "hub report: --ask needs --why \"<what this is about and what changes with the answer, in plain words>\""
    [ -n "$rec" ] || [ "$nopt" -ge 2 ] || die "hub report: --ask needs --rec \"<your pick and why>\" or two or more --option"
  elif [ -n "$why$rec$when" ] || [ "$nopt" -gt 0 ]; then die "hub report: --why, --rec, --option and --when go with --ask"; fi
  if [ -n "$name" ]; then
    name="$(_osrc_hub_text 60 "$name")"; [ -n "$name" ] || die "hub report: --name is empty"
    # A URL, a path, owner/repo (one token with a slash) or a long hex id is not a name.
    if case "$name" in *://*|/*|~*|*.git|*/*/*) true ;; *' '*) false ;; */*) true ;; *) false ;; esac \
       || printf '%s' "$name" | grep -Eq '[0-9a-fA-F]{12,}'; then
      die "hub report: --name is what a person calls the project (\"Total Recall 1.9\"), not a path, URL or id"
    fi
  fi
  case "$pkey" in '') ;; *[!A-Za-z0-9._-]*|.*) die "hub report: --project takes a short key like my-app (letters, digits, . _ -)" ;; esac
  [ "${#pkey}" -le 64 ] || die "hub report: --project key is too long"
  case "$done_ask" in '') ;; *[!A-Za-z0-9._-]*|.*) die "hub report: --done-ask takes a question id like D2" ;; esac
  if [ -n "$ask" ]; then   # a question with no background or no buttons is not a question the user can answer
    [ "${#why}" -ge 40 ] || die "hub report: --ask needs --why: 1-2 plain sentences (40+ chars) on what this is and what changes with the answer, for someone who has not followed the work"
    [ -n "$rec" ] || die "hub report: --ask needs --rec: your pick and why"
    [ "$(jq 'length' <<<"$opts")" -ge 2 ] || die "hub report: --ask needs two or more --option choices the user can click"
  fi
  local hub="$OSRC_HOME/hub"
  for v in "$hub" "$hub/projects" "$hub/decisions"; do
    [ -L "$v" ] && die "hub report: refusing a symlinked hub folder"
    mkdir -p "$v" 2>/dev/null || die "hub report: cannot create the hub folder"
  done
  chmod 700 "$hub" 2>/dev/null
  local now; now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local said=""
  if [ -n "$board" ]; then   # the board JSON drives the project page (lib/hub_board.sh)
    [ -f "$board" ] && [ ! -L "$board" ] || die "hub report: --board takes a JSON file"
    jq -e '(.tasks | type == "array" and length > 0) and all(.tasks[]; (.short | type == "string") and (.short | test(" ")))' "$board" >/dev/null 2>&1 \
      || die "hub report: --board needs .tasks[] each with a human .short name (words, not a code name)"
    _osrc_hub_write_json "$hub/projects/$sid.json" '(if type == "object" then . else {} end) + {board:$b[0], reportedAt:$now}' --slurpfile b "$board" --arg now "$now" || return 1
    said="board"
  fi
  if [ -n "$st$pct$eta$nxt$name$pkey" ]; then
    _osrc_hub_write_json "$hub/projects/$sid.json" '
      (if type == "object" then . else {} end)
      + (if $st == "" then {} else {status:$st} end)
      + (if $st == "shipped" then {shippedAt:$now} else {} end)
      + (if $pct == "" then {} else {pct:($pct | tonumber)} end)
      + (if $eta == "" then {} else {eta:$eta} end)
      + (if $nxt == "" then {} else {next:$nxt} end)
      + (if $name == "" then {} else {name:$name} end)
      + (if $pk == "" then {} else {project:$pk} end)
      + {reportedAt:$now}' \
      --arg pk "$pkey" --arg st "$st" --arg pct "$pct" --arg eta "$eta" --arg nxt "$nxt" --arg name "$name" --arg now "$now" || return 1
    [ -n "$st" ] && said="$st"
    [ -n "$pct" ] && said="${said:+$said, }$pct%"
  fi
  local dfile="$hub/decisions/$sid.json" newid=""
  if [ -n "$ask" ]; then
    newid="$(jq -r 'if type == "array" then . elif (.decisions | type) == "array" then .decisions else [] end
      | [.[] | .id // "" | select(test("^D[0-9]+$")) | .[1:] | tonumber] | "D\((max // 0) + 1)"' "$dfile" 2>/dev/null)"
    [ -n "$newid" ] || newid="D1"
    _osrc_hub_write_json "$dfile" '
      (if type == "array" then . elif type == "object" and (.decisions | type) == "array" then .decisions else [] end)
      + [{id:$id, q:$q, short:($q | if length > 70 then .[0:69] + "…" else . end), status:"wait", weight:$w, askedAt:$now,
          why:$why, options:$opts} + (if $rec == "" then {} else {rec:$rec} end) + (if $when == "" then {} else {when:$when} end)]' \
      --arg id "$newid" --arg q "$ask" --arg w "$weight" --arg now "$now" --arg why "$why" --arg rec "$rec" --arg when "$when" --argjson opts "$opts" || return 1
  fi
  if [ -n "$done_ask" ]; then
    jq -e --arg id "$done_ask" '(if type == "array" then . else (.decisions // []) end) | any(.[]; .id == $id)' "$dfile" >/dev/null 2>&1 \
      || die "hub report: no question '$done_ask' on this session's card"
    _osrc_hub_write_json "$dfile" '
      (if type == "array" then . else (.decisions // []) end)
      | map(if .id == $id then . + {status:"done", doneAt:$now} else . end)' --arg id "$done_ask" --arg now "$now" || return 1
  fi
  osrc_hub_beat "$sid"
  printf 'Mission Control updated%s%s%s.\n' "${said:+ ($said)}" "${newid:+; question $newid is waiting on you}" "${done_ask:+; $done_ask closed}"
  if [ -n "$board" ] && type _sg_board_unnamed >/dev/null 2>&1; then
    local _un; _un="$(jq '{board:.}' "$board" 2>/dev/null > "$board.osrc-chk.$$" && _sg_board_unnamed "$board.osrc-chk.$$")"; rm -f "$board.osrc-chk.$$"
    [ -z "$_un" ] || printf 'warning: these board tracks name no "model" or "lane", so their hover card cannot say who built them: %s\n' "$_un" >&2
  fi
  [ -z "$board" ] || ! type _osrc_hub_board_pct_says >/dev/null 2>&1 \
    || _osrc_hub_board_pct_says "$board" "$(jq -r '.pct // "" | tostring' "$hub/projects/$sid.json" 2>/dev/null)"
}

# ---- 3. time text (renewals; plus two helpers moved verbatim from outsourcerer.sh) -----------------

_fmt_secs_human() {  # <secs> -> 3d2h / 11h26m / 26m / 45s
  local s="${1:-0}"; case "$s" in ''|*[!0-9]*) s=0 ;; esac
  if   [ "$s" -ge 86400 ]; then printf '%sd%sh' $(( s/86400 )) $(( s%86400/3600 ))
  elif [ "$s" -ge 3600 ];  then printf '%sh%02dm' $(( s/3600 )) $(( s%3600/60 ))
  elif [ "$s" -ge 60 ];    then printf '%sm' $(( s/60 ))
  else printf '%ss' "$s"; fi
}
_epoch_local() {  # <epoch> -> local "YYYY-MM-DD HH:MM" (BSD `date -r`, then GNU `date -d @`)
  date -r "$1" +'%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$1" +'%Y-%m-%d %H:%M' 2>/dev/null || printf 'epoch %s' "$1"
}


# _osrc_local_fmt <epoch> <fmt> -> local time, English names (GNU date first, then BSD).
_osrc_local_fmt() { LC_ALL=C date -d "@$1" "+$2" 2>/dev/null || LC_ALL=C date -r "$1" "+$2" 2>/dev/null; }

# _osrc_local_day <epoch> -> whole local calendar days since the epoch (uses that instant's UTC offset).
_osrc_local_day() {
  local z s h m off
  z="$(_osrc_local_fmt "$1" '%z')"
  case "$z" in [+-][0-9][0-9][0-9][0-9]) ;; *) z="+0000" ;; esac
  s="${z%????}"; h="${z:1:2}"; m="${z:3:2}"
  off=$(( (10#$h * 3600 + 10#$m * 60) ))
  [ "$s" = "-" ] && off=$(( -off ))
  printf '%s' $(( ($1 + off) / 86400 ))
}

# _osrc_hub_stamp [epoch] -> "23:00" today, "yesterday 23:00", else "Mon 16 Nov, 09:10" (local, 24h:
# one clock across the page and the export, the viewer's own, never a UTC label).
_osrc_hub_stamp() {
  local t="${1:-}" now d; now="$(date +%s)"
  case "$t" in ''|*[!0-9]*) t="$now" ;; esac
  d=$(( $(_osrc_local_day "$now") - $(_osrc_local_day "$t") ))
  case "$d" in
    0) _osrc_local_fmt "$t" '%H:%M' ;;
    1) printf 'yesterday %s' "$(_osrc_local_fmt "$t" '%H:%M')" ;;
    *) _osrc_local_fmt "$t" '%a %e %b, %H:%M' | tr -s ' ' ;;
  esac
}

# _osrc_renew_text <epoch> [now] -> "today · 18:40" | "tomorrow · 09:10" | "in 4 days · Thu 19 Nov";
# "" when unknown or already past. Callers prefix "Renews ".
_osrc_renew_text() {
  case "${1:-}" in ''|*[!0-9]*) return 0 ;; esac
  local t="$1" now="${2:-}" d
  case "$now" in ''|*[!0-9]*) now="$(date +%s)" ;; esac
  [ "$t" -gt "$now" ] || return 0
  d=$(( $(_osrc_local_day "$t") - $(_osrc_local_day "$now") ))
  case "$d" in
    0) printf 'today · %s' "$(_osrc_local_fmt "$t" '%H:%M')" ;;
    1) printf 'tomorrow · %s' "$(_osrc_local_fmt "$t" '%H:%M')" ;;
    *) printf 'in %s days · %s' "$d" "$(_osrc_local_fmt "$t" '%a %e %b' | tr -s ' ')" ;;
  esac
}
