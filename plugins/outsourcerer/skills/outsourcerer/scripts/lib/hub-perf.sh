# Mission Control export speed (MC2 r2 #4) and live-lane detail (MC2 r2 #5).
#
# Profile on Alex's Mac (10 projects, 4 live tmux lanes, load avg ~150): `hub export` took 38-96 s.
#   - each tmux lane read its pane twice (_owned_live_state from the lane row AND from the activity
#     scan) and parsed the whole session registry three times (~1 s per read under load): ~8 s a lane;
#   - names derived from first prompts parsed 30-140 MB transcripts with jq: up to 5 s a project;
#   - idle projects rebuilt every lane row on every export although nothing under them changed;
#   - the limits rail re-probed every harness on every export: 3-10 s.
# Fixes: a per-export memo (registry read once, one pane read per lane), cached prompt names
# (hub-names.sh), and, when OSRC_HUB_FAST=1 (hub serve sets it), a fingerprinted cache for settled
# projects plus a stale-while-revalidate limits rail. A plain `hub export` keeps uncached semantics
# for those two, so every caller and suite that changes state between exports sees it at once.

# _osrc_hub_memo_begin: open the per-export memo and route the costly readers through it. No-op when
# already open. Memo files live in $OSRC_HOME/hub/memo.<pid> and go away in _osrc_hub_memo_end.
_osrc_hub_memo_begin() {
  [ -z "${_OSRC_HUB_MEMO:-}" ] || return 0
  local d="$OSRC_HOME/hub/memo.$$" fn old op
  mkdir -p "$OSRC_HOME/hub" 2>/dev/null || return 0
  # A killed export (the server's 90 s timeout, a Ctrl-C) never reaches memo_end: sweep memos whose
  # exporting process is gone.
  for old in "$OSRC_HOME"/hub/memo.*; do
    [ -d "$old" ] && [ ! -L "$old" ] || continue
    op="${old##*/memo.}"; case "$op" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$op" 2>/dev/null || rm -rf "$old" 2>/dev/null
  done
  rm -rf "$d" 2>/dev/null; mkdir -m 700 "$d" 2>/dev/null || return 0
  mkdir -p "$d/reg" "$d/scr" "$d/own" 2>/dev/null
  # Export start, backdated 1 s so an input written in the same second (1 s mtime filesystems) still
  # counts as newer. Cached docs carry this mtime (see _osrc_hub_cache_put).
  local s1; s1=$(( $(date +%s) - 1 ))
  touch -t "$(date -r "$s1" '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$s1" '+%Y%m%d%H%M.%S' 2>/dev/null)" "$d/start" 2>/dev/null || : > "$d/start"
  _OSRC_HUB_MEMO="$d"; _OSRC_HUB_MEMO_SAVED=""
  # The registry, validated once with ONE jq (the stock reader spawns a jq per line, ~1-3 s a read under
  # load, and every lane read it 3+ times). Same rules: an unparsable line stops the read; it is an error
  # (rc 1) unless it is an unterminated final line (a write in flight), which is dropped.
  if [ -f "${OSRC_SESSION_REGISTRY:-}" ] && [ ! -L "$OSRC_SESSION_REGISTRY" ] && have jq; then
    jq -cR 'fromjson? // "\u0001BAD"' "$OSRC_SESSION_REGISTRY" 2>/dev/null | awk -v last="$(wc -l < "$OSRC_SESSION_REGISTRY" | tr -d ' ')" '
      $0 == "\"\\u0001BAD\"" { exit (NR > last ? 0 : 1) } { print }' > "$d/registry" 2>/dev/null
    printf '%s' "$?" > "$d/registry.rc"
    jq -rs '[.[] | select(type == "object" and (.session_id | type) == "string" and (.session_id | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")))]
          | group_by(.session_id)[]
          | "\(.[0].session_id)\t\([.[] | .ts // empty | if type == "number" then floor else (try fromdateiso8601 catch empty) end] | max // 0)\t\(sort_by(.ts // "") | last | tojson)"' "$d/registry" 2>/dev/null \
      | while IFS="$(printf '\t')" read -r sid ts ev; do printf '%s\n' "$ev" > "$d/reg/$sid.json"; printf '%s\n' "$ts" > "$d/reg/$sid.ts"; done
    : > "$d/reg/.indexed"
  fi
  tmux list-sessions -F '#{session_name} #{session_created} #{window_activity}' > "$d/tmux" 2>/dev/null || : > "$d/tmux"
  for fn in _state_jsonl_read _sv_target_screen _owned_live_state _session_registry_last_event; do
    type "$fn" >/dev/null 2>&1 || continue
    _OSRC_HUB_MEMO_SAVED="$_OSRC_HUB_MEMO_SAVED $fn"
    eval "$(declare -f "$fn" | sed "1s/^$fn /_osrc_hub_raw$fn /")"
  done
  case " $_OSRC_HUB_MEMO_SAVED " in *" _state_jsonl_read "*)
    _state_jsonl_read() {
      if [ "$1" = "${OSRC_SESSION_REGISTRY:-}" ] && [ -f "$_OSRC_HUB_MEMO/registry.rc" ]; then
        cat "$_OSRC_HUB_MEMO/registry"; return "$(cat "$_OSRC_HUB_MEMO/registry.rc")"
      fi
      _osrc_hub_raw_state_jsonl_read "$@"
    } ;; esac
  case " $_OSRC_HUB_MEMO_SAVED " in *" _sv_target_screen "*)
    _sv_target_screen() {
      [ -z "${2:-}" ] && _osrc_hub_slug_ok "$1" || { _osrc_hub_raw_sv_target_screen "$@"; return; }
      local f="$_OSRC_HUB_MEMO/scr/$1"
      [ -f "$f" ] || _osrc_hub_raw_sv_target_screen "$1" > "$f" 2>/dev/null
      cat "$f"
    } ;; esac
  case " $_OSRC_HUB_MEMO_SAVED " in *" _owned_live_state "*)
    _owned_live_state() {
      _osrc_hub_slug_ok "$1" || { _osrc_hub_raw_owned_live_state "$@"; return; }
      local f="$_OSRC_HUB_MEMO/own/$1"
      [ -f "$f" ] || _osrc_hub_raw_owned_live_state "$1" > "$f" 2>/dev/null
      cat "$f"
    } ;; esac
  case " $_OSRC_HUB_MEMO_SAVED " in *" _session_registry_last_event "*)
    _session_registry_last_event() {
      [ -f "$_OSRC_HUB_MEMO/reg/.indexed" ] && _osrc_hub_slug_ok "$1" || { _osrc_hub_raw_session_registry_last_event "$@"; return; }
      [ -f "$_OSRC_HUB_MEMO/reg/$1.json" ] && cat "$_OSRC_HUB_MEMO/reg/$1.json"
      return 0
    } ;; esac
  return 0
}

# _osrc_hub_memo_end: restore the original readers and drop the memo.
_osrc_hub_memo_end() {
  [ -n "${_OSRC_HUB_MEMO:-}" ] || return 0
  local fn
  for fn in $_OSRC_HUB_MEMO_SAVED; do
    eval "$(declare -f "_osrc_hub_raw$fn" | sed "1s/^_osrc_hub_raw$fn /$fn /")"
    unset -f "_osrc_hub_raw$fn"
  done
  rm -rf "$_OSRC_HUB_MEMO" 2>/dev/null
  _OSRC_HUB_MEMO=""; _OSRC_HUB_MEMO_SAVED=""
}

# _osrc_hub_lane_state <id> -> "<state> <startedAt> <activeAt>": what one owned lane is doing right now,
# in Alex's words (working|approval|question|idle|limit|failed|done|unknown), when it started and when it
# last moved (epochs, 0 = unknown). The card turns these into "waiting for approval, 12 min" (MC2 r2 #5).
_osrc_hub_lane_state() {
  local id="$1" st='' row c=0 a=0 out
  if row="$(_osrc_hub_tmux_row "$id")" && [ -n "$row" ]; then
    c="${row%% *}"; a="${row##* }"
    out="$(_sv_target_screen "$id" 2>/dev/null)"; st="${out%%$'\n'*}"
    case "$st" in composer) st=idle ;; approval|question|working|idle|limit|failed|done) ;; *)
      case "$(_owned_live_state "$id" 2>/dev/null)" in live|working|running) st=working ;; waiting) st=approval ;; idle) st=idle ;; done) st=done ;; *) st=unknown ;; esac ;; esac
  elif [ -d "$OSRC_JOBS/$id" ]; then
    st="$(_reconcile_status "$id" 2>/dev/null || cat "$OSRC_JOBS/$id/status" 2>/dev/null)"
    c="$(_osrc_hub_mt "$OSRC_JOBS/$id/meta.json")"; a="$(_osrc_hub_mt "$OSRC_JOBS/$id"/*)"
    case "$st" in running|live|working|launching|stalled\?|exploring\?|no-progress-writes) st=working ;; waiting) st=approval ;;
      done|'done?') st=done ;; failed|wedged|timeout|blocked|permission-blocked) st=failed ;; canceled|interrupted) st=done ;; *) st=unknown ;; esac
  elif [ -f "$OSRC_HOME/remote/$id.json" ]; then
    c="$(jq -r '.created // .started // 0 | if type == "number" then floor else (try fromdateiso8601 catch 0) end' "$OSRC_HOME/remote/$id.json" 2>/dev/null)"
    a="$(_osrc_hub_mt "$OSRC_HOME/remote/$id.json")"
    case "$(type osrc_remote_state >/dev/null 2>&1 && osrc_remote_state "$id" 2>/dev/null)" in live) st=working ;; ready|done) st=done ;; failed) st=failed ;; *) st=unknown ;; esac
  else
    return 1
  fi
  [ "$(_osrc_hub_done_state "$id")" = done ] && st=done
  case "$c" in ''|*[!0-9]*) c=0 ;; esac; case "$a" in ''|*[!0-9]*) a=0 ;; esac
  printf '%s %s %s' "${st:-unknown}" "$c" "$a"
}

# _osrc_hub_lane_live_fields <lane-json> -> the lane with state/startedAt/activeAt added.
_osrc_hub_lane_live_fields() {
  local lane="$1" id ls
  id="$(jq -r '.id // ""' <<<"$lane" 2>/dev/null)"
  _osrc_hub_slug_ok "$id" && ls="$(_osrc_hub_lane_state "$id")" || { printf '%s' "$lane"; return 0; }
  jq -c --arg s "${ls%% *}" --arg r "${ls#* }" '. + {state:$s} + (($r | split(" ") | map(tonumber? // 0)) as $t
    | (if $t[0] > 0 then {startedAt:$t[0]} else {} end) + (if ($t[1] // 0) > 0 then {activeAt:$t[1]} else {} end))' <<<"$lane" 2>/dev/null || printf '%s' "$lane"
}

# ---- settled-project cache --------------------------------------------------------------------------
# $OSRC_HOME/hub/cache/<slug>.json holds the last doc of a project with nothing that can move on its own:
# no live lane, no tmux session, no remote lane, every lane terminal. It is reused while no input under
# the project is newer than the cache file and it is under an hour old. Anything live is rebuilt.
_OSRC_HUB_CACHE_V=3   # r3: names are finished in the export, not cached

_osrc_hub_cache_paths() { # <slug> -> every file or dir whose change invalidates the project
  local slug="$1" t id
  printf '%s\n' "$OSRC_HOME/owners/$slug" "$OSRC_HOME/hub/projects/$slug.json" "$OSRC_HOME/hub/decisions/$slug.json" "$OSRC_HOME/hub/status/$slug.json" \
    "$OSRC_HOME/review/items" "$HOME"/.claude/projects/*/"$slug".jsonl
  for t in "$OSRC_HOME/owners/$slug"/*; do
    [ -f "$t" ] || continue; id="${t##*/}"
    printf '%s\n' "$OSRC_JOBS/$id" "$OSRC_HOME/done/$id.json" "$OSRC_HOME/autodetach/$id.log" "$OSRC_HOME/autodetach/$id.rc"
  done
}

# _osrc_hub_cache_get <slug> <now> <upd> -> cached project doc (stamps refreshed); rc 1 on a miss.
_osrc_hub_cache_get() {
  [ "${OSRC_HUB_FAST:-0}" = 1 ] || return 1
  local slug="$1" f="$OSRC_HOME/hub/cache/$1.json" t id age p newer
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  age=$(( $(date +%s) - $(_osrc_hub_mt "$f") ))
  [ "$age" -ge 0 ] && [ "$age" -lt "${OSRC_HUB_CACHE_MAX:-3600}" ] || return 1
  for t in "$OSRC_HOME/owners/$slug"/*; do
    [ -f "$t" ] || continue; id="${t##*/}"
    [ -f "$OSRC_HOME/remote/$id.json" ] && return 1
    _osrc_hub_tmux_row "$id" >/dev/null 2>&1 && return 1
  done
  newer="$(_osrc_hub_cache_paths "$slug" | while IFS= read -r p; do [ -e "$p" ] && printf '%s\n' "$p"; done | tr '\n' '\0' | xargs -0 sh -c 'find "$@" -newer "$0" -print 2>/dev/null | head -1' "$f" 2>/dev/null)"
  [ -z "$newer" ] || return 1
  local sh="${OSRC_HUB_STALE_HOURS:-24}"; case "$sh" in ''|*[!0-9]*) sh=24 ;; esac
  jq -ce --argjson v "$_OSRC_HUB_CACHE_V" --argjson now "$2" --arg upd "$3" --argjson sh "$sh" \
    'select(._cacheV == $v) | del(._cacheV) + {exported_at:$now, updated:$upd, staleHours:$sh}' "$f" 2>/dev/null
}

# _osrc_hub_cache_put <slug> <project-json>: store the doc when nothing in it can move on its own.
_osrc_hub_cache_put() {
  [ "${OSRC_HUB_FAST:-0}" = 1 ] || return 0
  local slug="$1" pj="$2" d="$OSRC_HOME/hub/cache" t id
  # Only inside an export, whose start stamp the cache file takes: an input written while this export
  # ran is then newer than the cache and invalidates it, instead of hiding behind a later write time.
  [ -n "${_OSRC_HUB_MEMO:-}" ] && [ -f "$_OSRC_HUB_MEMO/start" ] || return 0
  jq -e '(.liveLanes // 0) == 0 and all(.lanes[]?; (.status // "") as $s | ["Done","Merged","Failed","Canceled","Shipped"] | index($s) != null)' >/dev/null 2>&1 <<<"$pj" || { rm -f "$d/$slug.json" 2>/dev/null; return 0; }
  for t in "$OSRC_HOME/owners/$slug"/*; do
    [ -f "$t" ] || continue; id="${t##*/}"
    [ -f "$OSRC_HOME/remote/$id.json" ] && return 0
    _osrc_hub_tmux_row "$id" >/dev/null 2>&1 && return 0
  done
  mkdir -p "$d" 2>/dev/null && [ ! -L "$d" ] || return 0
  jq -c --argjson v "$_OSRC_HUB_CACHE_V" '. + {_cacheV:$v}' <<<"$pj" > "$d/$slug.json.$$" 2>/dev/null \
    && touch -r "$_OSRC_HUB_MEMO/start" "$d/$slug.json.$$" 2>/dev/null && mv -f "$d/$slug.json.$$" "$d/$slug.json" 2>/dev/null
  rm -f "$d/$slug.json.$$" 2>/dev/null
  return 0
}

# _osrc_hub_limits_cached -> the limits rail. Plain export: computed every time (as before). Under
# OSRC_HUB_FAST=1 (hub serve): only the first export computes it; later ones serve the cached rail.
# Once it is older than OSRC_HUB_LIMITS_TTL (60 s), or a meter input is newer, a detached refresh
# rewrites it. That write lands in $OSRC_HOME/hub, which wakes the server's re-export, so the page
# catches up within one cycle.
# The meters behind it refresh on a 10-minute gate; probing every harness cost 3-10 s per export.
_osrc_hub_limits_inputs() {
  printf '%s\n' "$OSRC_HOME/rate-limits.json" "$HOME/.claude/token-optimizer/rate-limits.json" "$OSRC_HOME/lanes/events.jsonl" \
    "$OSRC_HOME/.devin-free-ids" "$HOME/.claude/settings.json" "$HOME/.codex/auth.json" "$HOME/.claude/.credentials.json"
}
_osrc_hub_limits_write() { # <file> : compute and store atomically
  local out; out="$(_osrc_hub_limits 2>/dev/null)"
  case "$out" in ''|*'error'*) out='[]' ;; esac
  jq -e 'arrays' >/dev/null 2>&1 <<<"$out" || out='[]'
  printf '%s\n' "$out" > "$1.$$" 2>/dev/null && mv -f "$1.$$" "$1" 2>/dev/null; rm -f "$1.$$" 2>/dev/null
  printf '%s' "$out"
}
_osrc_hub_limits_cached() {
  local f="$OSRC_HOME/hub/limits-cache.json" ttl="${OSRC_HUB_LIMITS_TTL:-60}" age changed p lk
  if [ "${OSRC_HUB_FAST:-0}" != 1 ] || ! mkdir -p "$OSRC_HOME/hub" 2>/dev/null || [ -L "$f" ]; then
    local out; out="$(_osrc_hub_limits 2>/dev/null)"; case "$out" in ''|*'error'*) out='[]' ;; esac; printf '%s' "$out"; return 0
  fi
  case "$ttl" in ''|*[!0-9]*) ttl=60 ;; esac
  changed=""
  if [ -f "$f" ]; then
    changed="$(_osrc_hub_limits_inputs | while IFS= read -r p; do [ -e "$p" ] && [ -n "$(find "$p" -newer "$f" 2>/dev/null | head -1)" ] && { echo 1; break; }; done)"
  fi
  if [ ! -f "$f" ] || ! jq -e 'arrays' "$f" >/dev/null 2>&1; then _osrc_hub_limits_write "$f"; return 0; fi
  age=$(( $(date +%s) - $(_osrc_hub_mt "$f") ))
  # Changed meters do not block the export either: the statusline rewrites its rate-limits file every
  # turn, so "recompute when an input changed" meant recomputing (7 s) on nearly every export.
  if [ -n "$changed" ] || [ "$age" -ge "$ttl" ] || [ "$age" -lt 0 ]; then
    lk="$OSRC_HOME/hub/limits-refresh.lock"
    # one refresher at a time; a lock older than 5 min is a crashed refresher
    [ -d "$lk" ] && [ $(( $(date +%s) - $(_osrc_hub_mt "$lk") )) -gt 300 ] && rmdir "$lk" 2>/dev/null
    if mkdir "$lk" 2>/dev/null; then
      ( _osrc_hub_limits_write "$f" >/dev/null 2>&1; rmdir "$lk" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
    fi
  fi
  jq -c . "$f" 2>/dev/null || printf '[]'
  return 0
}
