#!/usr/bin/env bash
# =============================================================================
# plan-probe.sh — every plan on the Mission Control plans card is checked on its own (PL, 0.16.3).
#
# Alex: "there IS NO EXCUSE to write 'not checked yet'." The card used to read only passive meters
# (the Claude statusline artifact, the newest Codex session log), so any harness without one, or with
# a stale one, said "not checked yet" or "Waiting for reset" with no time. Each detected harness now
# has an ACTIVE, read-only probe, cached under $OSRC_HOME/hub/probes/<id>.json:
#
#   codex   `codex app-server` JSON-RPC account/rateLimits/read (no model call, no cost). Runs when the
#           session-log reading is missing or older than OSRC_PROBE_CODEX_AFTER (600 s).
#   agy     Antigravity's own `/usage` screen, read in a private tmux server (-L, -f /dev/null) and
#           closed again. Weekly and 5-hour quota per model group, with refresh times.
#   devin   `devin models` (which models are Free) + the Plan line of `devin auth status`.
#   droid   `droid doctor --json --checks auth` (sign-in proof; Factory publishes no balance).
#   claude  the statusline artifact at ANY age, labelled with its age (usage only rises, so an older
#           reading is a floor), never "not checked yet".
#
# Probes are bounded (OSRC_PROBE_SECS, default 15; agy OSRC_PROBE_AGY_SECS, default 25), read no
# credential file and never block the page twice: a fresh cache is served; a stale cache is served
# while a detached refresh rewrites it (one per id, lock-guarded); only a MISSING cache is fetched
# inline, all missing ids in parallel. OSRC_PROBE_SYNC=1 refreshes stale caches inline (tests).
# OSRC_PROBE=0 turns active probes off (rows still say what is known, with a reason).
# =============================================================================

_osrc_probe_dir() { printf '%s/hub/probes' "$OSRC_HOME"; }
_osrc_probe_py() { printf '%s/plan_probe.py' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; }
_osrc_probe_has() { command -v "$1" >/dev/null 2>&1; }
_osrc_probe_mt() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf '0'; }

# _osrc_probe_ttl <id> -> seconds a cached answer stays fresh.
_osrc_probe_ttl() {
  local t
  case "$1" in
    codex) t="${OSRC_PROBE_TTL_CODEX:-300}" ;;
    agy)   t="${OSRC_PROBE_TTL_AGY:-600}" ;;
    *)     t="${OSRC_PROBE_TTL:-1800}" ;;
  esac
  case "$t" in ''|*[!0-9]*) t=300 ;; esac
  printf '%s' "$t"
}

# _osrc_probe_wanted <id> -> rc0 when this harness should be actively probed now.
_osrc_probe_wanted() {
  [ "${OSRC_PROBE:-1}" != 0 ] || return 1
  case "$1" in
    codex)
      _osrc_probe_has codex || return 1
      # Active only when the passive session-log reading is missing or stale.
      local sdir="$HOME/.codex/sessions" newest age
      newest="$(ls -t "$sdir"/*/*/*/*.jsonl 2>/dev/null | head -1)"
      [ -n "$newest" ] || return 0
      grep -q '"rate_limits"' "$newest" 2>/dev/null || return 0
      age=$(( $(date +%s) - $(_osrc_probe_mt "$newest") ))
      [ "$age" -gt "${OSRC_PROBE_CODEX_AFTER:-600}" ] ;;
    agy)   _osrc_probe_has agy && _osrc_probe_has tmux ;;
    devin) _osrc_probe_has devin ;;
    droid) _osrc_probe_has droid ;;
    *) return 1 ;;
  esac
}

# _osrc_probe_fetch <id> -> one normalized JSON object (always prints one; {"ok":false,...} on failure).
_osrc_probe_fetch() {
  local id="$1" py secs out
  py="$(_osrc_probe_py)"; secs="${OSRC_PROBE_SECS:-15}"
  _osrc_probe_has python3 && [ -r "$py" ] || { printf '{"ok":false,"why":"python3 is needed for the plan probes"}\n'; return 0; }
  case "$id" in
    codex) out="$(python3 -I "$py" codex "$secs" 2>/dev/null)" ;;
    agy)   out="$(_osrc_probe_agy_screen | python3 -I "$py" agy-parse 2>/dev/null)" ;;
    devin)
      local d m a; d="$(mktemp -d "$(_osrc_probe_dir)/.devin.XXXXXX" 2>/dev/null)" || d=""
      if [ -n "$d" ]; then
        m="$d/models"; a="$d/auth"
        python3 -I "$py" run "$secs" devin models > "$m" 2>/dev/null
        # Only the plan and login lines leave the probe; names, emails and ids never do.
        python3 -I "$py" run "$secs" devin auth status 2>/dev/null | grep -E '^[[:space:]]*(Plan|Tier):|[Ll]ogged in' > "$a"
        out="$(python3 -I "$py" devin-parse "$m" "$a" 2>/dev/null)"
        rm -rf "$d"
      fi ;;
    droid) out="$(python3 -I "$py" run "$secs" droid doctor --json --checks auth 2>/dev/null | python3 -I "$py" droid-parse 2>/dev/null)" ;;
    *) out='{"ok":false,"why":"no probe"}' ;;
  esac
  case "$out" in '{'*) ;; *) out="{\"ok\":false,\"why\":\"$id probe gave no answer\"}" ;; esac
  if _osrc_probe_has jq; then jq -c --argjson t "$(date +%s)" '. + {checked:$t}' <<<"$out" 2>/dev/null || printf '%s\n' "$out"
  else printf '%s\n' "$out"; fi
}

# _osrc_probe_store <id> : fetch and write the cache atomically.
_osrc_probe_store() {
  local id="$1" dir f
  dir="$(_osrc_probe_dir)"; f="$dir/$id.json"
  mkdir -p "$dir" 2>/dev/null && [ ! -L "$dir" ] && [ ! -L "$f" ] || return 1
  _osrc_probe_fetch "$id" > "$f.$$" 2>/dev/null && [ -s "$f.$$" ] && mv -f "$f.$$" "$f" 2>/dev/null
  rm -f "$f.$$" 2>/dev/null
  return 0
}

# _osrc_probe_refresh_bg <id> : one detached refresher per id (a lock older than 2 min is a dead one).
_osrc_probe_refresh_bg() {
  local id="$1" lk
  lk="$(_osrc_probe_dir)/$id.lock"
  [ -d "$lk" ] && [ $(( $(date +%s) - $(_osrc_probe_mt "$lk") )) -gt 120 ] && rmdir "$lk" 2>/dev/null
  mkdir "$lk" 2>/dev/null || return 0
  ( _osrc_probe_store "$id"; rmdir "$lk" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
  return 0
}

# _osrc_probe_kick <id...> : make every wanted probe's cache current. Missing caches are fetched now,
# in parallel, and waited for (bounded by the probes' own timeouts); stale caches refresh detached.
_osrc_probe_kick() {
  local id f ttl age pids="" p dir
  dir="$(_osrc_probe_dir)"; mkdir -p "$dir" 2>/dev/null || return 0
  for id in "$@"; do
    _osrc_probe_wanted "$id" || continue
    f="$dir/$id.json"; ttl="$(_osrc_probe_ttl "$id")"
    if [ ! -s "$f" ]; then
      _osrc_probe_store "$id" & pids="$pids $!"
      continue
    fi
    age=$(( $(date +%s) - $(_osrc_probe_mt "$f") ))
    # A failed answer is retried sooner than a good one.
    grep -q '"ok":false' "$f" 2>/dev/null && [ "$ttl" -gt 120 ] && ttl=120
    [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ] && continue
    if [ "${OSRC_PROBE_SYNC:-0}" = 1 ]; then _osrc_probe_store "$id" & pids="$pids $!"
    else _osrc_probe_refresh_bg "$id"; fi
  done
  for p in $pids; do wait "$p" 2>/dev/null; done
  return 0
}

# _osrc_probe_cache <id> -> the cached JSON, or nothing.
_osrc_probe_cache() {
  local f; f="$(_osrc_probe_dir)/$1.json"
  [ -s "$f" ] && [ ! -L "$f" ] && cat "$f" 2>/dev/null
}

# _osrc_probe_codex_line -> "5h%|wk%|5h_reset|wk_reset|age" from a GOOD cached codex probe, else rc1.
# Same shape as _codex_rate_limits, which prefers it when it is newer than the session log.
_osrc_probe_codex_line() {
  local c; c="$(_osrc_probe_cache codex)" || return 1
  _osrc_probe_has jq || return 1
  jq -r --argjson now "$(date +%s)" 'select(.ok == true and (.windows | type) == "object")
    | "\(.windows.codex5h.used // "")|\(.windows.codexwk.used // "")|\(.windows.codex5h.renews_at // "")|\(.windows.codexwk.renews_at // "")|\([($now - (.checked // $now)), 0] | max)"' <<<"$c" 2>/dev/null | grep '|'
}

# _osrc_probe_agy_screen -> the text of Antigravity's `/usage` screen, read in a private tmux server.
# Read-only: it opens agy in a scratch folder under $OSRC_HOME, types `/usage`, captures, closes.
_osrc_probe_agy_screen() {
  local sock cwd secs end scr typed=0 trusted=0
  sock="${OSRC_PROBE_TMUX_PREFIX:-osrc-probe}-agy-$$"
  cwd="$(_osrc_probe_dir)/agy-cwd"; mkdir -p "$cwd" 2>/dev/null || return 1
  secs="${OSRC_PROBE_AGY_SECS:-25}"; case "$secs" in ''|*[!0-9]*) secs=25 ;; esac
  TMUX='' tmux -L "$sock" -f /dev/null new-session -d -s plans -x 120 -y 90 -c "$cwd" agy 2>/dev/null || return 1
  end=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$end" ]; do
    sleep 1
    scr="$(TMUX='' tmux -L "$sock" capture-pane -p -t plans 2>/dev/null)" || break
    if grep -q 'Models & Quota' <<<"$scr" && grep -Eq '[0-9]%|Refreshes in|Disabled' <<<"$scr"; then
      sleep 1; scr="$(TMUX='' tmux -L "$sock" capture-pane -p -t plans 2>/dev/null)"
      TMUX='' tmux -L "$sock" send-keys -t plans Escape 2>/dev/null
      TMUX='' tmux -L "$sock" kill-server 2>/dev/null
      printf '%s\n' "$scr"; return 0
    fi
    if [ "$trusted" = 0 ] && grep -q 'Do you trust the contents' <<<"$scr"; then
      TMUX='' tmux -L "$sock" send-keys -t plans Enter 2>/dev/null; trusted=1; continue
    fi
    # The composer is the ">" line right under a full-width rule (it may hold placeholder text).
    if [ "$typed" = 0 ] && awk -v r='─' 'index(prev, r) == 1 && /^>/ { f=1 } { prev=$0 } END { exit !f }' <<<"$scr"; then
      TMUX='' tmux -L "$sock" send-keys -t plans -l '/usage' 2>/dev/null; sleep 1
      TMUX='' tmux -L "$sock" send-keys -t plans Enter 2>/dev/null; typed=1
    fi
  done
  TMUX='' tmux -L "$sock" kill-server 2>/dev/null
  return 1
}

# _osrc_probe_claude_reading -> the newest statusline artifact as JSON (any age), or nothing.
_osrc_probe_claude_reading() {
  local cand best="" bts=0 ts
  _osrc_probe_has jq || return 1
  for cand in "$OSRC_HOME/rate-limits.json" "$HOME/.claude/token-optimizer/rate-limits.json"; do
    [ -f "$cand" ] && jq -e 'type == "object"' "$cand" >/dev/null 2>&1 || continue
    ts="$(jq -r '.timestamp // 0 | floor' "$cand" 2>/dev/null)"; case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
    [ "$ts" -gt 0 ] || ts=$(( $(_osrc_probe_mt "$cand") * 1000 ))
    [ "$ts" -gt "$bts" ] && { bts="$ts"; best="$cand"; }
  done
  [ -n "$best" ] || return 1
  jq -c --argjson ts "$bts" '{five_hour, seven_day, ts: ($ts / 1000 | floor)}' "$best" 2>/dev/null
}

# _osrc_plan_overlay : stdin = the lane-summary JSON array -> the same rows, each with a checked state.
# Rows already measured (ok/low/out from a fresh meter) keep their numbers; every row whose meter was
# missing (unknown) or stale (wait) gets what the active probe or the honest fallback knows, plus a
# `note` saying where it came from and an `updated` checked-at time. Never "not checked yet".
_osrc_plan_overlay() {
  local in ids pj='{}' id c now lt ct
  in="$(cat)"
  _osrc_probe_has jq && jq -e 'arrays' >/dev/null 2>&1 <<<"$in" || { printf '%s\n' "$in"; return 0; }
  ids="$(jq -r '.[].id' <<<"$in" 2>/dev/null | tr '\n' ' ')"
  # shellcheck disable=SC2086
  _osrc_probe_kick $ids
  for id in codex agy devin droid; do
    case " $ids " in *" $id "*) ;; *) continue ;; esac
    c="$(_osrc_probe_cache "$id")"; jq -e 'objects' >/dev/null 2>&1 <<<"$c" || continue
    pj="$(jq -c --arg k "$id" --argjson v "$c" '. + {($k): $v}' <<<"$pj")"
  done
  case " $ids " in *" claude "*) c="$(_osrc_probe_claude_reading)" && jq -e 'objects' >/dev/null 2>&1 <<<"$c" && pj="$(jq -c --argjson v "$c" '. + {claude: $v}' <<<"$pj")" ;; esac
  now="$(date +%s)"
  lt="$(_osrc_limit_threshold 2>/dev/null)"; case "$lt" in ''|*[!0-9.]*) lt=90 ;; esac
  ct="${OSRC_CONSERVE_THRESHOLD:-50}"; case "$ct" in ''|*[!0-9.]*) ct=50 ;; esac
  jq -c --argjson p "$pj" --argjson now "$now" --argjson lt "$lt" --argjson ct "$ct" -f "$(dirname "$(_osrc_probe_py)")/plan-overlay.jq" <<<"$in" 2>/dev/null \
    || printf '%s\n' "$in"
}

# _osrc_summary_text_json : stdin JSON rows -> the `lane summary` table (same columns as before).
_osrc_summary_text_json() {
  printf '%-9s %-18s %-8s %-12s %-24s %-6s %s\n' ID NAME STATE LEFT RENEWS CAP BILLING
  jq -r '.[] | [.id, .name, .state, (.left // "-"), (.renews // "-"), (.cap // "-"),
          (if .billing == "metered" then "pay per use" elif .billing == "unknown" then "plan not confirmed" else "-" end)
          + (if .cap_tripped == true then " [cap tripped]" else "" end)] | @tsv' 2>/dev/null \
  | while IFS='	' read -r a b s l r c bl; do
      printf '%-9s %-18s %-8s %-12s %-24s %-6s %s\n' "$a" "$b" "$s" "$l" "$r" "$c" "$bl"
    done
}
