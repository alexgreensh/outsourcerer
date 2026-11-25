# shellcheck shell=bash
# lib/mc_alive.sh: the per-command hook that warns about unwatched lanes and opens Mission Control.
# Sourced by outsourcerer.sh (lib loader); function definitions only.
#
#  Watcher warning: every `session` / `review` / `hub` / `mc` call by an orchestrator whose lanes have
#  had no supervise armed for over 2 minutes prints one line (osrc_watcher_warn, lib/stall.sh). The hub
#  export carries the same gap (osrc_mc_alerts), so Mission Control shows "no watcher for N min".
#  Auto-open: `session start`, a delegation (run/explore/research/edit/yolo/bg/fanout) or `fleet` opens
#  Mission Control once per hub process when no tab fetched data in the last 2 minutes.
#  OSRC_MC_AUTO_OPEN=0 disables. Never in CI or over SSH, never without a desktop (Linux without DISPLAY
#  or WAYLAND_DISPLAY; macOS when the console user is someone else), never from a delegate, and never
#  under a HOME that is not the account's own (every test suite sets HOME to a scratch dir).
#
# The hub (lib/hub_server.py) writes $OSRC_HOME/hub/serve.json {pid, port, started, engine, ver}
# when it starts and $OSRC_HOME/hub/tab.seen (epoch) whenever a tab fetches data with the
# current token. engine/ver let `mc` spot a hub still running an older install's code.

_osrc_mc_dir() { printf '%s/hub' "$OSRC_HOME"; }

# The dispatcher's per-command hook (called from osrc_hub_beat_cmd with the command and its args).
osrc_mc_cmd_hook() { # <cmd> [args...]
  local cmd="${1:-}" sub="${2:-}"
  case "${OUTSOURCERER_DEPTH:-0}" in ''|0) ;; *) return 0 ;; esac
  case "$cmd" in
    session|review|hub|mc|mission-control)
      [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && type osrc_watcher_warn >/dev/null 2>&1 && osrc_watcher_warn ;;
  esac
  case "$cmd:$sub" in
    session:start|run:*|explore:*|research:*|edit:*|yolo:*|bg:*|fanout:*|fleet:*) osrc_mc_auto_open ;;
  esac
  return 0
}

# Tests: OSRC_MC_ASSUME_DESKTOP=1 skips the desktop and own-HOME checks, and ONLY together with a
# recording OSRC_MC_OPEN_CMD, so it can never pop a real browser. CI still blocks.
_osrc_mc_test_desktop() { [ "${OSRC_MC_ASSUME_DESKTOP:-0}" = 1 ] && [ -n "${OSRC_MC_OPEN_CMD:-}" ]; }
_osrc_mc_headless() { # 0 when no person could see a browser window here
  [ -n "${CI:-}" ] && return 0
  _osrc_mc_test_desktop && return 1
  [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] && return 0
  case "$(uname -s 2>/dev/null)" in
    # The person logged in at the screen is this user. Not launchctl's manager name: inside tmux it
    # reads "Background" even on a desktop session.
    Darwin) [ "$(stat -f %Su /dev/console 2>/dev/null)" = "$(id -un 2>/dev/null)" ] || return 0 ;;
    *) [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || return 0 ;;
  esac
  return 1
}
_osrc_mc_real_home() { # 0 when HOME is the account's own home (a test's scratch HOME is not)
  _osrc_mc_test_desktop && return 0
  local h; h="$(python3 -I -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null)"
  [ -n "$h" ] && [ "$(cd "$HOME" 2>/dev/null && pwd -P)" = "$(cd "$h" 2>/dev/null && pwd -P)" ]
}

# _osrc_mc_open_url <url>: the one opener. OSRC_MC_OPEN_CMD (tests) receives the URL as $1.
_osrc_mc_open_url() {
  if [ -n "${OSRC_MC_OPEN_CMD:-}" ]; then "$OSRC_MC_OPEN_CMD" "$1" >/dev/null 2>&1; return; fi
  case "$(uname -s 2>/dev/null)" in
    Darwin) command -v open >/dev/null 2>&1 && { open "$1" >/dev/null 2>&1; return; } ;;
    *) command -v xdg-open >/dev/null 2>&1 && { ( xdg-open "$1" >/dev/null 2>&1 & ); return 0; } ;;
  esac
  python3 -I -c 'import sys, webbrowser; webbrowser.open(sys.argv[1])' "$1" >/dev/null 2>&1
}

# _osrc_mc_hub_live -> "<pid> <port>" of the hub serving this OSRC_HOME, rc 1 when none.
_osrc_mc_hub_live() {
  local f pid port; f="$(_osrc_mc_dir)/serve.json"
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  pid="$(jq -r '.pid // empty' "$f" 2>/dev/null)"; port="$(jq -r '.port // empty' "$f" 2>/dev/null)"
  case "$pid:$port" in *[!0-9:]*|:*|*:) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s %s\n' "$pid" "$port"
}
# _osrc_mc_etime_to_epoch <etime> -> epoch the process started, rc 1 on unparseable input.
# `ps -o etime` prints [[dd-]hh:]mm:ss.
_osrc_mc_etime_to_epoch() {
  local e="${1// /}" d=0 hh=0 mm="" ss=""
  case "$e" in ''|*[!0-9:-]*) return 1 ;; esac
  case "$e" in *-*) d="${e%%-*}"; e="${e#*-}" ;; esac
  case "$e" in
    *:*:*) IFS=: read -r hh mm ss <<<"$e" ;;
    *:*)   IFS=: read -r mm ss <<<"$e" ;;
    *) return 1 ;;
  esac
  printf '%s' $(( $(date +%s) - 10#${d:-0}*86400 - 10#${hh:-0}*3600 - 10#${mm:-0}*60 - 10#${ss:-0} ))
}

# _osrc_mc_stale_hub <port> -> 0 when the hub answering on <port> runs code that is not this
# engine's (an older install, or another checkout's script path) AND that hub was stopped so
# the caller can spawn a fresh `hub serve`. Verification before any kill: the candidate pid's
# argv must be hub_server.py with --osrc-home = this OSRC_HOME. A pid that cannot be verified
# as OUR hub is never touched; a hub that cannot be proven stale is left serving (rc 1).
_osrc_mc_stale_hub() {
  local p="${1:-}" f sp spid pid cand cmd eng eng_rp cur_rp sver mt start stale="" i oh lpid
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  f="$(_osrc_mc_dir)/serve.json"; sp=""; spid=""
  if [ -f "$f" ] && [ ! -L "$f" ]; then
    sp="$(jq -r '.port // empty' "$f" 2>/dev/null)"
    spid="$(jq -r '.pid // empty' "$f" 2>/dev/null)"
  fi
  # Candidates: the recorded pid for this port, then whoever listens on it.
  local cands=""
  [ "$sp" = "$p" ] && case "$spid" in ''|*[!0-9]*) ;; *) cands="$spid" ;; esac
  if command -v lsof >/dev/null 2>&1; then
    for lpid in $(lsof -nP -iTCP:"$p" -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p'); do
      case " $cands " in *" $lpid "*) ;; *) cands="$cands $lpid" ;; esac
    done
  fi
  pid=""
  for cand in $cands; do
    kill -0 "$cand" 2>/dev/null || continue
    cmd="$(ps -p "$cand" -ww -o command= 2>/dev/null)"
    case "$cmd" in *hub_server.py*) ;; *) continue ;; esac
    oh=""
    case "$cmd" in
      *--osrc-home=*) oh="${cmd#*--osrc-home=}" ;;
      *--osrc-home\ *) oh="${cmd#*--osrc-home }" ;;
    esac
    oh="${oh%% --*}"
    [ "$oh" = "$OSRC_HOME" ] || continue
    pid="$cand"; break
  done
  [ -n "$pid" ] || return 1
  # Which engine it runs (argv is the truth; serve.json could name a different server).
  eng=""
  case "$cmd" in
    *--engine=*) eng="${cmd#*--engine=}" ;;
    *--engine\ *) eng="${cmd#*--engine }" ;;
  esac
  eng="${eng%% --*}"
  [ -n "$eng" ] || return 1
  eng_rp=""
  [ -f "$eng" ] && eng_rp="$(cd "$(dirname "$eng")" 2>/dev/null && pwd -P)/$(basename "$eng")"
  cur_rp="$(cd "$(dirname "${_OSRC_FACTORY_DIR:-$SCRIPT_DIR}/outsourcerer.sh")" 2>/dev/null && pwd -P)/outsourcerer.sh"
  [ -n "$eng_rp" ] && [ "$eng_rp" = "$cur_rp" ] || stale=1     # engine path differs or is gone
  # The self-reported version (0.17.4+ serve.json) settles same-path comparisons; older
  # records fall back to "was the engine file rewritten after this server started".
  sver=""
  [ "$sp" = "$p" ] && [ "$spid" = "$pid" ] && sver="$(jq -r '.ver // empty' "$f" 2>/dev/null)"
  if [ -z "$stale" ] && [ -n "$sver" ]; then
    [ "$sver" != "${OSRC_VERSION:-0}" ] && stale=1
  elif [ -z "$stale" ] && [ -z "$sver" ] && [ -n "$eng_rp" ]; then
    mt="$(stat -c %Y "$eng_rp" 2>/dev/null || stat -f %m "$eng_rp" 2>/dev/null || echo 0)"
    case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
    start="$(_osrc_mc_etime_to_epoch "$(ps -p "$pid" -o etime= 2>/dev/null)")"
    case "$start" in ''|*[!0-9]*) start=0 ;; esac
    [ "$mt" -gt 0 ] && [ "$start" -gt 0 ] && [ "$mt" -gt "$start" ] && stale=1
  fi
  [ -n "$stale" ] || return 1
  # Verified stale OUR hub: stop it and drop the stale record so a fresh server (same
  # 8788-8798 scan) can take its place; it usually reclaims the same bookmarked port.
  kill "$pid" 2>/dev/null || return 1
  for i in 1 2 3 4 5 6 7 8; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  # After SIGKILL, wait (bounded) until it is gone: the fresh hub binds the same port, and a dying
  # process still holding it makes a strict --port bind fail.
  kill -0 "$pid" 2>/dev/null && { kill -9 "$pid" 2>/dev/null; for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done; }
  [ -n "$f" ] && [ -f "$f" ] && [ "$sp" = "$p" ] && [ "$spid" = "$pid" ] && rm -f "$f" 2>/dev/null
  printf '[outsourcerer] restarted Mission Control: the running hub was built from older code\n' >&2
  return 0
}

_osrc_mc_tab_recent() { # 0 when a tab fetched data within OSRC_MC_TAB_FRESH seconds (default 120)
  local t; t="$(_sv_num "$(cat "$(_osrc_mc_dir)/tab.seen" 2>/dev/null)" 0)"
  [ $(( $(date +%s) - t )) -lt "$(_sv_num "${OSRC_MC_TAB_FRESH:-}" 120)" ]
}
# Mark this hub process as opened (by mc or by the auto-open); one auto-open per hub process.
_osrc_mc_mark_opened() { local l; l="$(_osrc_mc_hub_live)" && : > "$(_osrc_mc_dir)/opened.${l%% *}" 2>/dev/null; return 0; }

osrc_mc_auto_open() {
  [ "${OSRC_MC_AUTO_OPEN:-1}" != 0 ] || return 0
  [ "${OSRC_HUB_NO_OPEN:-0}" != 1 ] || return 0
  _osrc_mc_headless && return 0
  _osrc_mc_tab_recent && return 0
  _osrc_mc_real_home || return 0
  local live d m; d="$(_osrc_mc_dir)"
  if live="$(_osrc_mc_hub_live)"; then
    m="$d/opened.${live%% *}"
    ( set -C; : > "$m" ) 2>/dev/null || return 0   # once per hub process
    local tok; tok="$(tr -d ' \n' < "$d/token" 2>/dev/null)"
    case "$tok" in ''|*[!0-9a-fA-F]*) return 0 ;; esac
    _osrc_mc_open_url "http://127.0.0.1:${live##* }/?t=$tok"
    printf '[outsourcerer] opened Mission Control (no tab was watching)\n' >&2
    return 0
  fi
  # No hub yet: start one and open it, at most once per 2 minutes, detached so work never waits.
  m="$d/autostart"
  mkdir -p "$d" 2>/dev/null || return 0
  [ -n "$(find "$m" -mmin -2 2>/dev/null)" ] && return 0
  : > "$m" 2>/dev/null || return 0
  ( nohup bash "${_OSRC_FACTORY_DIR:-$SCRIPT_DIR}/outsourcerer.sh" mc >/dev/null 2>&1 & ) >/dev/null 2>&1
  printf '[outsourcerer] starting Mission Control in your browser (OSRC_MC_AUTO_OPEN=0 turns this off)\n' >&2
  return 0
}

# ---- Mission Control fields (hub export) -------------------------------------------------------------
# osrc_mc_alerts <slug> <project-json> -> the project plus
#   watcher: {missingMin, liveLanes}           when this orchestrator's lanes have nobody watching
#   alerts: [{kind, lane, since, text}]        needs-you rows: an escalated stall (lanes/needs/<id>),
#                                              a READY lane queued for review 15+ min (with its age)
osrc_mc_alerts() {
  local slug="$1" p="$2" g w='null' a='[]' f id k since txt now un
  [ -d "$OSRC_HOME/owners/$slug" ] || { printf '%s' "$p"; return 0; }
  now="${OSRC_NOW:-$(date +%s)}"
  if type osrc_watcher_gap >/dev/null 2>&1 && g="$(osrc_watcher_gap "$slug" "$now")"; then
    w="$(jq -cn --argjson m "${g%% *}" --argjson l "${g##* }" '{missingMin:$m, liveLanes:$l}')"
  fi
  for f in "$OSRC_HOME/owners/$slug"/*; do
    [ -f "$f" ] || continue; id="${f##*/}"
    [ -f "$OSRC_HOME/lanes/needs/$id" ] || continue
    IFS="$(printf '\t')" read -r k since txt 2>/dev/null < "$OSRC_HOME/lanes/needs/$id"
    a="$(jq -c --arg k "${k:-stalled}" --arg l "$id" --argjson s "$(_sv_num "$since" "$now")" --arg t "$txt" '. + [{kind:$k, lane:$l, since:$s, text:$t}]' <<<"$a")"
  done
  un=$(( $(_sv_num "${OSRC_UNREVIEWED_MIN:-}" 15) * 60 ))
  if [ -z "${_OSRC_HUB_MEMO:-}" ] || [ ! -f "$_OSRC_HUB_MEMO/.review_swept" ]; then
    type _osrc_review_sweep_merged >/dev/null 2>&1 && _osrc_review_sweep_merged "$slug"   # landed heads close as merged before they can alert
  fi
  if [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -f "$_OSRC_HUB_MEMO/review_queued.indexed" ]; then
    if [ -s "$_OSRC_HUB_MEMO/review_queued.tsv" ]; then
      while IFS="$(printf '\t')" read -r id since; do
        [ -n "$id" ] && [ -e "$OSRC_HOME/owners/$slug/$id" ] || continue
        since="$(_sv_num "$since" 0)"
        [ "$since" -gt 0 ] && [ $(( now - since )) -ge "$un" ] || continue
        a="$(jq -c --arg l "$id" --argjson s "$since" '. + [{kind:"unreviewed", lane:$l, since:$s, text:"READY, no review started"}]' <<<"$a")"
      done < "$_OSRC_HUB_MEMO/review_queued.tsv"
    fi
  else
    for f in "$OSRC_HOME"/review/items/*.json; do
      [ -f "$f" ] || continue
      id="$(jq -r 'select(.state == "queued") | .lane // empty' "$f" 2>/dev/null)"; [ -n "$id" ] || continue
      [ -e "$OSRC_HOME/owners/$slug/$id" ] || continue
      since="$(_sv_num "$(jq -r '.enq_ts // 0' "$f" 2>/dev/null)" 0)"
      [ "$since" -gt 0 ] && [ $(( now - since )) -ge "$un" ] || continue
      a="$(jq -c --arg l "$id" --argjson s "$since" '. + [{kind:"unreviewed", lane:$l, since:$s, text:"READY, no review started"}]' <<<"$a")"
    done
  fi
  [ "$w" = "null" ] && [ "$a" = "[]" ] && { printf '%s' "$p"; return 0; }
  jq -c --argjson w "$w" --argjson a "$a" '. + (if $w == null then {} else {watcher:$w} end) + (if ($a|length) > 0 then {alerts:$a} else {} end)' <<<"$p" 2>/dev/null || printf '%s' "$p"
}
