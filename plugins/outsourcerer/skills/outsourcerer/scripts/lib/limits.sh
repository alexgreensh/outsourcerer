# =============================================================================
# limits.sh — session-limit meters, conservation advice, and the L7 limit gate.
# Sourced by outsourcerer.sh via the lib/*.sh loader near the top of that file; every
# function here resolves its dependencies (lane descriptors, _session_limits callers,
# route_delegate locals) at CALL time, so definition order does not matter.
#
# L7 LIMIT GATE — never route work onto a lane whose plan meter is spent. The failure it
# kills: `brief` reads the meters (claude5h/claude7d/codex5h/codexwk) and prints a
# conservation line, but a launch still resolved onto a lane at 98% weekly and the
# delegate sat on a limit banner doing nothing. The gate is the hard edge:
#
#   * advise: a lane whose FRESH meter reading is >= OSRC_LANE_LIMIT_PCT (default 90) is
#     excluded from the candidate pool outright — not merely score-haircut.
#   * direct launch (route_delegate -> _osrc_limit_gate): the same threshold prints ONE
#     warning line naming the meter and the suggested fallback lane, then
#       - proceeds when --force-lane is given or the user pinned the lane with
#         --provider (an explicit choice is consent; a hop-injected provider is NOT —
#         OSRC_FALLBACK_PINNED marks those),
#       - takes a zero-cost fallback hop when the run is unpinned auto-tier,
#       - refuses loudly otherwise (mutating tier, pinned -m, exhausted fallbacks).
#   * stale readings are UNKNOWN, not exhausted: codex meters older than
#     OSRC_LIMITS_STALE_SECS (default 6h, carried as codexage=<secs> in the limits
#     line) warn and proceed; they never gate. Claude readings are already
#     freshness-gated upstream (dropped at OSRC_LIMITS_MAX_AGE=2h), so an absent
#     claude meter is simply "no reading", never "exhausted".
#
# Fallback suggestion order is the SKILL.md conservation order — local -> Devin ->
# Gemini -> Codex -> OpenRouter — filtered to lanes READY right now and not themselves
# over the line. OSRC_LANE_LIMIT_GATE=0 disables advise exclusion and the launch gate.
# =============================================================================

# _mtime <path> -> file modification time as a unix epoch, on both GNU and BSD.
# ORDER MATTERS AND IS NOT INTERCHANGEABLE. `stat -f` means "modification time" on BSD/macOS but
# "filesystem status" on GNU/Linux, where it SUCCEEDS and prints filesystem info — so a
# `stat -f ... || stat -c ...` fallback is unreachable on Linux and yields garbage that silently fails
# every later numeric comparison. GNU's `-c` is simply invalid on BSD and exits non-zero, so trying
# GNU FIRST is the only ordering where the fallback actually happens on both.
_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf ''; }

# _codex_rate_limits -> "5h%|wk%|5h_reset_epoch|wk_reset_epoch" from the newest Codex session
# rollout. Codex records the ChatGPT-plan rate-limit windows the API returns into every rollout, so
# this is the REAL cost of a "no cash" ChatGPT-sub run: it spends your finite 5-hour and weekly
# limits. Best-effort; empty when codex/jq/rollout unavailable.
_codex_rate_limits() {
  have jq || return 1
  local sdir="$HOME/.codex/sessions"; [ -d "$sdir" ] || return 1
  local newest; newest="$(ls -t "$sdir"/*/*/*/*.jsonl 2>/dev/null | head -1)"
  [ -n "$newest" ] || return 1
  # How OLD this reading is matters more than the number. Codex only records rate limits while it is
  # RUNNING, so with no recent codex session the newest rollout can be days old. Usage only ever rises
  # within a window, so a stale reading is a FLOOR, never a current value — and reporting it as current
  # overstates headroom in the one direction that hurts: work gets routed to an exhausted lane.
  # The age travels in the RETURN STRING. This function is read through a command substitution, so an
  # exported variable would die with the subshell and the caller would silently see nothing — the same
  # defect that left the 0-writes flag dead for its entire life.
  local _mt; _mt="$(_mtime "$newest")"; case "$_mt" in ''|*[!0-9]*) _mt="$(date +%s)" ;; esac
  local _age; _age=$(( $(date +%s) - _mt ))
  local line; line="$(grep '"rate_limits"' "$newest" 2>/dev/null | tail -1)"
  [ -n "$line" ] || return 1
  # Bucket by window_minutes, NOT slot position: Codex rollouts do NOT reliably put the 5h window in
  # .primary (observed: primary.window_minutes=10080 = weekly, secondary=null). Classify each present
  # slot by its window (<=360min -> 5h/short, else weekly/long) so codex5h/codexwk are never swapped.
  printf '%s' "$line" | jq -r '
    ([.. | objects | select(has("rate_limits")) | .rate_limits] | last) as $r
    | select($r != null)
    | [ $r.primary, $r.secondary ] | map(select(. != null)) as $slots
    | ( [ $slots[] | select((.window_minutes // 100000) <= 360) ] | first ) as $sh
    | ( [ $slots[] | select((.window_minutes // 0)      >  360) ] | first ) as $wk
    | "\($sh.used_percent // "")|\($wk.used_percent // "")|\($sh.resets_at // "")|\($wk.resets_at // "")"
  ' 2>/dev/null | head -1 | sed "s/\$/|$_age/"
}

# _human_eta <epoch> -> "3h 12m" remaining until epoch, or "" if past/unknown.
_human_eta() {
  local target="$1" now
  case "$target" in ''|*[!0-9]*) return 0 ;; esac
  now="$(date +%s 2>/dev/null)" || return 0
  local d=$(( target - now )); [ "$d" -gt 0 ] || return 0
  printf '%dh %dm' $(( d / 3600 )) $(( (d % 3600) / 60 ))
}

# _codex_quota_line -> honest one-liner on ChatGPT-plan headroom after a codex-native run.
_codex_quota_line() {
  local raw; raw="$(_codex_rate_limits)" || return 1
  [ -n "$raw" ] || return 1
  local p s pr sr; IFS='|' read -r p s pr sr <<< "$raw"
  [ -n "$p$s" ] || return 1
  local pe se; pe="$(_human_eta "$pr")"; se="$(_human_eta "$sr")"
  local msg="ChatGPT plan usage, 5h window: ${p:-?}%"
  [ -n "$pe" ] && msg="$msg (resets in $pe)"
  msg="$msg · weekly: ${s:-?}%"
  [ -n "$se" ] && msg="$msg (resets in $se)"
  printf '%s' "$msg"
}

# ---- SESSION LIMIT AWARENESS (copilot conserve engine). Best-effort, degrade gracefully:
# NEVER die, NEVER block a delegation — a wrong/absent limit signal must only soften a RECOMMENDATION.
_pct_normalize() {   # echo a 0..100 number, else nothing
  awk -v v="${1:-}" 'BEGIN { if (v ~ /^([0-9]+([.][0-9]+)?|[.][0-9]+)$/ && v>=0 && v<=100) printf "%g", v }' 2>/dev/null
}
_window_pct() {   # <pct> <resets_at-epoch> -> pct if the window is still live, else nothing (drop expired)
  local pct reset="${2:-}" now
  pct="$(_pct_normalize "${1:-}")"; [ -n "$pct" ] || return 1
  case "$reset" in ''|null) ;; *[!0-9]*) return 1 ;;
    *) now="$(date +%s 2>/dev/null)" || return 1; [ "$reset" -gt "$now" ] || return 1 ;; esac
  printf '%s' "$pct"
}
# _session_limits -> normalized one-liner "claude5h=95 claude7d=38 codex5h=.. codexwk=.." (omits unknown).
# Claude source = the token-optimizer statusline artifact (the only readable 5h/7d signal Claude Code
# exposes; ADVISORY — it's derived + only fresh while a statusline renders). We drop stale (>10min) and
# expired-window values rather than trust them, and honor OSRC_CC_PRESSURE as an explicit override.
_session_limits() {
  # Claude 5h/7d source precedence: explicit override > outsourcerer's own statusline tap
  # (universal, `tap install`) > the token-optimizer statusline artifact (if that plugin is present).
  local cand raw c5="" c7="" c5r="" c7r="" ts="" nowms line=""
  if [ -n "${OSRC_CC_PRESSURE:-}" ]; then
    c5="$(_pct_normalize "$OSRC_CC_PRESSURE")"       # explicit orchestrator override wins
  else
    # Try each candidate in precedence order; a STALE/expired/invalid one is SKIPPED so we fall
    # through to the next fresh source (fixes: a frozen $OSRC_HOME artifact shadowing token-optimizer's
    # fresh file forever). tap file first (universal), then token-optimizer's.
    for cand in "$OSRC_HOME/rate-limits.json" "$HOME/.claude/token-optimizer/rate-limits.json"; do
      [ -f "$cand" ] && have jq && jq -e . "$cand" >/dev/null 2>&1 || continue
      raw="$(jq -r '"\(.five_hour.used_percentage // "")|\(.five_hour.resets_at // "")|\(.seven_day.used_percentage // "")|\(.seven_day.resets_at // "")|\(.timestamp // "")"' "$cand" 2>/dev/null)"
      IFS='|' read -r c5 c5r c7 c7r ts <<EOF
$raw
EOF
      # Freshness gate: fail CLOSED. A statusline artifact older than 10min — OR one whose timestamp is
      # missing/non-integer (can't prove freshness) — is treated as stale and skipped.
      nowms="$(date +%s 2>/dev/null)"; [ -n "$nowms" ] && nowms=$((nowms*1000))
      case "$ts" in
        ''|*[!0-9]*) c5=""; c7="" ;;                                             # unprovable -> stale
        *) [ -n "$nowms" ] && [ $((nowms - ts)) -gt 600000 ] && { c5=""; c7=""; } ;;
      esac
      c5="$(_window_pct "$c5" "$c5r" 2>/dev/null)" || c5=""
      c7="$(_window_pct "$c7" "$c7r" 2>/dev/null)" || c7=""
      [ -n "$c5$c7" ] && break                                                   # got fresh data -> stop
    done
  fi
  raw="$(_codex_rate_limits 2>/dev/null)" || raw=""
  local x5="" xw="" x5r="" xwr="" xage=""
  if [ -n "$raw" ]; then
    IFS='|' read -r x5 xw x5r xwr xage <<EOF
$raw
EOF
    x5="$(_window_pct "$x5" "$x5r" 2>/dev/null)" || x5=""
    xw="$(_window_pct "$xw" "$xwr" 2>/dev/null)" || xw=""
  fi
  [ -n "$c5" ] && line="$line claude5h=$c5"
  [ -n "$c7" ] && line="$line claude7d=$c7"
  [ -n "$x5" ] && line="$line codex5h=$x5"
  [ -n "$xw" ] && line="$line codexwk=$xw"
  # Mark the codex figures stale rather than dropping them: a floor with its age attached is useful,
  # a confident wrong number is not.
  case "$xage" in ''|*[!0-9]*) xage=0 ;; esac
  { [ -n "$x5" ] || [ -n "$xw" ]; } && [ "$xage" -gt "${OSRC_LIMITS_MAX_AGE:-7200}" ] \
    && line="$line codexage=${xage}"
  printf '%s\n' "${line# }"
}


# _conserve_reco <limits-line> <lanes-line> -> ONE actionable conservation line. Threshold is
# OSRC_CONSERVE_THRESHOLD (default 50%). Priority when the Claude 5h window is tight:
# local (no cash or plan use) > Devin GLM/SWE (Devin plan) > keyless Gemini > Codex Sol/Terra (only if ChatGPT plan has
# headroom) > OpenRouter(only if funded). "All lanes tight" is handled first.
_conserve_reco() {
  local limits="${1:-}" lanes="${2:-}" tok c5="" c7="" x5="" xw="" xstale="" posture lane="" why="" tight=0
  for tok in $limits; do case "$tok" in
    claude5h=*) c5="${tok#*=}" ;; claude7d=*) c7="${tok#*=}" ;; codex5h=*) x5="${tok#*=}" ;; codexwk=*) xw="${tok#*=}" ;;
    codexage=*) xstale="${tok#*=}" ;;
  esac; done
  # Claude has TWO windows and the WEEKLY (7d) cap is the binding one in practice — a freshly-reset 5h
  # window must NEVER mask a nearly-exhausted week. Bind to the MORE-spent of the two (closest to the
  # cap), conserve if EITHER crosses the line, and report both so the 5h number can't hide the weekly.
  if [ -n "$c5" ] || [ -n "$c7" ]; then
    local bind="" bindpct=""
    [ -n "$c7" ] && { bind="weekly"; bindpct="$c7"; }
    [ -n "$c5" ] && awk -v a="$c5" -v b="${bindpct:-0}" 'BEGIN{exit !(a>b)}' 2>/dev/null && { bind="5h"; bindpct="$c5"; }
    posture="Claude weekly ${c7:-?}% / 5h ${c5:-?}% (binding: ${bind} ${bindpct}%)"
    awk -v n="${bindpct:-0}" -v t="$OSRC_CONSERVE_THRESHOLD" 'BEGIN { exit !(n >= t) }' 2>/dev/null && tight=1
  else posture="Claude limits unknown"; fi
  if [ "$tight" = "0" ]; then
    printf 'HEADROOM: %s (< %s%% conserve line) — route by best-fit; no forced conservation.\n' "$posture" "$OSRC_CONSERVE_THRESHOLD"
    return 0
  fi
  # Descriptor-first: conserve_match holds the lane's _ready_lanes token (leading-space
  # prefix match), conserve_name the display label, conserve_why/conserve_why_fn the reason.
  # The case below is the unported tail — the priority order itself is routing policy.
  local _cl _cm
  for _cl in local dv gm; do
    _cm="$(_lane_field "$_cl" conserve_match 2>/dev/null)"
    if [ -n "$_cm" ] && case " $lanes " in *"$_cm"*) true ;; *) false ;; esac; then
      lane="$(_lane_field "$_cl" conserve_name 2>/dev/null)"
      local _cwf; _cwf="$(_lane_field "$_cl" conserve_why_fn 2>/dev/null)"
      if [ -n "$_cwf" ]; then why="$("$_cwf")"; else why="$(_lane_field "$_cl" conserve_why 2>/dev/null)"; fi
      break
    fi
  done
  [ -n "$lane" ] || case " $lanes " in
    *" devin=glm/swe "*)  lane="Devin GLM/SWE";   why="$(_lane_cost_disclosure dv), preserves your Claude quota" ;;
  esac
  if [ -z "$lane" ]; then
    local codex_ok=0 seen=0 blocked=0 v
    case " $lanes " in *" codex=sol/terra "*)
      # A stale reading is a FLOOR, not a measurement: usage only rises within a window, so an old
      # low number is exactly how work gets routed to a lane that is already exhausted. Fail closed,
      # the same way the Claude freshness gate does.
      [ -n "$xstale" ] && blocked=1 && seen=1
      for v in "$x5" "$xw"; do [ -n "$v" ] || continue; seen=1
        awk -v n="$v" -v t="$OSRC_CONSERVE_THRESHOLD" 'BEGIN { exit !(n < t) }' 2>/dev/null || blocked=1; done
      [ "$seen" = "1" ] && [ "$blocked" = "0" ] && codex_ok=1 ;;
    esac
    if [ "$codex_ok" = "1" ]; then lane="Codex Sol/Terra"; why="your ChatGPT plan is below the conserve line in every known window"
    elif [ -n "$xstale" ]; then : # codex deliberately skipped: its usage reading is too old to trust
    else
      _cm="$(_lane_field or conserve_match 2>/dev/null)"
      if [ -n "$_cm" ] && case " $lanes " in *"$_cm"*) true ;; *) false ;; esac; then
        lane="$(_lane_field or conserve_name 2>/dev/null)"
        why="$(_lane_field or conserve_why 2>/dev/null)"
      fi
    fi
  fi
  if [ -n "$lane" ]; then printf 'CONSERVE: %s (>= %s%%) — route grind to %s (%s); keep Claude for judgment.\n' "$posture" "$OSRC_CONSERVE_THRESHOLD" "$lane" "$why"
  else printf 'CONSERVE: %s (>= %s%%) — but no lower-cost lane is ready. Start local inference (ollama) or log into Devin; meanwhile throttle and keep judgment on Claude.\n' "$posture" "$OSRC_CONSERVE_THRESHOLD"; fi
}


# _lane_conserve_mult <lane> <limits-line> -> a score multiplier in [0.90,1.00] that GENTLY deprioritizes
# a lane whose live plan window is past the conserve line, so "limits-left" actually steers the pick and
# not just the separate conserve-routing layer. Only lanes we can MEASURE are penalized (cc=Claude
# 5h/weekly, cx=Codex 5h/weekly, whichever is more spent); unmeasurable lanes (dv/gm/or) return 1.00 so we never
# invent a limit we cannot read. At/below the conserve line -> 1.00 (headroom); scales linearly to 0.90
# at 100% used. Deliberately small: it breaks ties and loses close races to a fresher lane, but a ~10%
# max haircut won't drop a genuinely-capable model below its capability threshold on its own.
_lane_conserve_mult() {
  local lane="$1" limits="${2:-}" t="${OSRC_CONSERVE_THRESHOLD:-50}" u="" c5="" c7="" x5="" xw="" tok
  for tok in $limits; do
    case "$tok" in
      claude5h=*) c5="${tok#*=}" ;;
      claude7d=*) c7="${tok#*=}" ;;
      codex5h=*)  x5="${tok#*=}" ;;
      codexwk=*)  xw="${tok#*=}" ;;
    esac
  done
  # Descriptor-first: conserve_windows names the limit tokens a lane is measured by
  # (cc: claude5h claude7d — the MORE-spent binds; cx: codex5h codexwk). The case below
  # is the unported-lane fallback.
  local _cl _cw="" _w _wv
  _cl="$(_lane_by_token "$lane" 2>/dev/null)" && _cw="$(_lane_field "$_cl" conserve_windows 2>/dev/null)"
  if [ -n "$_cw" ]; then
    u=""
    for tok in $limits; do
      for _w in $_cw; do
        case "$tok" in
          "$_w="*) _wv="${tok#*=}"
            case "$_wv" in ''|*[!0-9.]*) ;; *)
              { [ -z "$u" ] || awk -v a="$_wv" -v b="$u" 'BEGIN{exit !(a+0>b+0)}'; } && u="$_wv" ;;
            esac ;;
        esac
      done
    done
  else
    u=""
  fi
  case "$u" in ''|*[!0-9.]*) printf '1.00'; return ;; esac
  awk -v u="$u" -v t="$t" 'BEGIN{
    if (t+0 >= 100 || u+0 < t+0) { printf "1.00"; exit }
    m = 1 - 0.10*(u - t)/(100 - t)
    if (m < 0.90) m = 0.90; if (m > 1.00) m = 1.00
    printf "%.4f", m
  }'
}


# ---- L7 LIMIT GATE ---------------------------------------------------------------------

# _osrc_limit_threshold -> the gate percentage, sanitized: a non-numeric
# OSRC_LANE_LIMIT_PCT falls back to 90 rather than comparing against garbage.
_osrc_limit_threshold() {
  local t="${OSRC_LANE_LIMIT_PCT:-90}"
  case "$t" in ''|*[!0-9.]*) t=90 ;; esac
  printf '%s' "$t"
}

# _osrc_lane_limit <lane> [limits-line] -> "window=pct" for the lane's most-spent declared
# meter window. Windows come from the lane descriptor's conserve_windows field (cx =
# codex5h codexwk, cc = claude5h claude7d); the limits line is _session_limits' normalized
# token output. rc1 when the lane declares no windows or no window has a reading — an
# unmeasurable lane is never gated.
_osrc_lane_limit() {
  local lane="${1:-}" limits="${2:-}" cw w tok v best="" bestw=""
  cw="$(_lane_field "$lane" conserve_windows 2>/dev/null)" || return 1
  [ -n "$cw" ] || return 1
  for w in $cw; do
    for tok in $limits; do
      case "$tok" in "$w="*) v="${tok#*=}" ;; *) continue ;; esac
      case "$v" in ''|*[!0-9.]*) continue ;; esac
      if [ -z "$best" ] || awk -v a="$v" -v b="$best" 'BEGIN{exit !(a+0>b+0)}'; then
        best="$v"; bestw="$w"
      fi
    done
  done
  [ -n "$best" ] || return 1
  printf '%s=%s' "$bestw" "$best"
}

# _osrc_lane_limit_stale <lane> [limits-line] -> rc0 when the lane's meter reading is older
# than OSRC_LIMITS_STALE_SECS (default 21600 = 6h). Only codex-windowed lanes carry an age
# token (_session_limits emits codexage=<secs> once the rollout is older than
# OSRC_LIMITS_MAX_AGE); claude readings are freshness-gated upstream, so cc can never be
# "stale" here — absent is unknown. No codexage token -> rc1 (fresh or unmeasurable).
_osrc_lane_limit_stale() {
  local lane="${1:-}" limits="${2:-}" cw w age="" codex_only=1
  cw="$(_lane_field "$lane" conserve_windows 2>/dev/null)" || return 1
  [ -n "$cw" ] || return 1
  for w in $cw; do case "$w" in codex*) ;; *) codex_only=0 ;; esac; done
  [ "$codex_only" = "1" ] || return 1
  for w in $limits; do case "$w" in codexage=*) age="${w#*=}" ;; esac; done
  case "$age" in ''|*[!0-9]*) return 1 ;; esac
  [ "$age" -gt "${OSRC_LIMITS_STALE_SECS:-21600}" ]
}

# _osrc_limit_exceeded <lane> [limits-line] -> rc0 when the lane has a FRESH meter reading at
# or over OSRC_LANE_LIMIT_PCT. rc1 when under the line, when the lane has no meter, or when
# the only reading is stale — stale counts as unknown, never as exhausted. Shared by the
# advise exclusion and the launch gate so the two can never disagree on what "exhausted" is.
_osrc_limit_exceeded() {
  local lane="${1:-}" limits="${2:-}" rd pct thr
  rd="$(_osrc_lane_limit "$lane" "$limits")" || return 1
  _osrc_lane_limit_stale "$lane" "$limits" && return 1
  pct="${rd#*=}"
  thr="$(_osrc_limit_threshold)"
  awk -v p="$pct" -v t="$thr" 'BEGIN{exit !(p+0 >= t+0)}'
}

# _osrc_limit_lane_ready <lane> -> cheap readiness for the fallback suggestion: the fallback
# probes first (key/CLI/login presence, no network for most lanes), then the lane's full
# ready_fn as a second chance — that is the only probe `local` has.
_osrc_limit_lane_ready() {
  _fallback_lane_ready "$1" 2>/dev/null && return 0
  _lane_ready_probe "$1" >/dev/null 2>&1 && return 0
  return 1
}

# _osrc_limit_fallback [limits-line] -> the suggested fallback lane: SKILL.md conservation
# order (local -> Devin -> Gemini -> Codex -> OpenRouter) filtered to lanes that are READY
# right now and not themselves over the limit line. Prints the lane code; rc1 when nothing
# qualifies (caller renders "none ready").
# Devin's daily plan bucket has no proactive meter (Devin exposes no reading; exhaustion is only
# learned from an API refusal), so dv is gated here only indirectly: a CONFIRMED quota refusal
# marks the lane DOWN (_lane_down_mark, self-healing TTL) and _fallback_lane_ready refuses DOWN
# lanes — the same net that covers every other plan lane's post-dispatch limit signal.
_osrc_limit_fallback() {
  local limits="${1:-}" l
  [ -n "$limits" ] || limits="$(_session_limits 2>/dev/null)"
  for l in local dv gm cx or; do
    _osrc_limit_exceeded "$l" "$limits" && continue
    _osrc_limit_lane_ready "$l" && { printf '%s' "$l"; return 0; }
  done
  return 1
}

# _osrc_limits_snapshot -> _session_limits behind a 60s TTL cache. The meter read is a
# filesystem scan (claude statusline artifacts + the newest codex rollout under a possibly huge
# sessions tree — seconds on a real install), and route_delegate consults the gate on EVERY
# loop iteration plus each fallback hop, so an uncached read would add that cost per hop. 60s is
# far below the 6h staleness horizon the gate reasons about, so a cached line is never wrong in
# the direction that matters. Tests that stub _session_limits must reset _OSRC_LIMITS_SNAP.
_OSRC_LIMITS_SNAP=""
_OSRC_LIMITS_SNAP_TS=0
_osrc_limits_snapshot() {
  local now; now="$(date +%s 2>/dev/null || printf 0)"
  if [ -z "$_OSRC_LIMITS_SNAP" ] || [ $(( now - _OSRC_LIMITS_SNAP_TS )) -gt 60 ]; then
    _OSRC_LIMITS_SNAP="$(_session_limits 2>/dev/null)"
    _OSRC_LIMITS_SNAP_TS="$now"
  fi
  printf '%s' "$_OSRC_LIMITS_SNAP"
}

# _osrc_limit_gate <disp> [nohop] -> the pre-dispatch plan-meter gate. Called from route_delegate
# AFTER the lane-down gate and before _route_resolution, in dynamic scope: it reads
# tier/PROVIDER_EXPLICIT/_fb_user_pinned/OSRC_FORCE_LANE and, on the hop path, shares
# route_delegate's _fb_* locals exactly like _gate_hop does. `nohop` (interactive sessions, which
# have no fallback argv to rebuild) skips the hop branch so every non-consented refusal dies.
#   rc0  -> proceed (clear, consented, stale-warn-only, or OSRC_LANE_LIMIT_GATE=0)
#   rc10 -> a zero-cost hop was armed; the caller MUST `continue` the route loop
#   dies -> refused (pinned -m, non-auto tier, nohop, or no fallback left)
_osrc_limit_gate() {
  local _ol_disp="${1:-}" _ol_nohop="${2:-}" _ol_lane _ol_limits _ol_rd _ol_pct _ol_thr _ol_fb _ol_name _ol_stale=0
  local _fb_alias _fb_mid _fb_lane
  [ "${OSRC_LANE_LIMIT_GATE:-1}" = "0" ] && return 0
  _ol_lane="$(_quota_lane_key "$_ol_disp" 2>/dev/null)"; [ -n "$_ol_lane" ] || return 0
  case "$_ol_lane" in '?'|*[!A-Za-z_-]*) return 0 ;; esac
  # Cheap reject BEFORE the meter read: a lane with no declared meter windows can never gate,
  # and _session_limits is a filesystem scan — don't pay it for dv/or/gm/local/engine lanes.
  [ -n "$(_lane_field "$_ol_lane" conserve_windows 2>/dev/null)" ] || return 0
  _ol_limits="$(_osrc_limits_snapshot)"
  _ol_rd="$(_osrc_lane_limit "$_ol_lane" "$_ol_limits")" || return 0
  _osrc_lane_limit_stale "$_ol_lane" "$_ol_limits" && _ol_stale=1
  _ol_pct="${_ol_rd#*=}"
  _ol_thr="$(_osrc_limit_threshold)"
  awk -v p="$_ol_pct" -v t="$_ol_thr" 'BEGIN{exit !(p+0 >= t+0)}' || return 0
  _ol_fb="$(_osrc_limit_fallback "$_ol_limits" 2>/dev/null)"; _ol_fb="${_ol_fb:-none ready}"
  _ol_name="$(_lane_plan_display "$_ol_lane" 2>/dev/null)"; _ol_name="${_ol_name:-$_ol_lane}"
  if [ "$_ol_stale" = "1" ]; then
    printf '>>> [limit] %s lane meter %s is at/over OSRC_LANE_LIMIT_PCT=%s but the reading is stale (> %sh old) — unknown, not exhausted; proceeding. Fallback if needed: %s.\n' \
      "$_ol_name" "$_ol_rd" "$_ol_thr" "$(( ${OSRC_LIMITS_STALE_SECS:-21600} / 3600 ))" "$_ol_fb" >&2
    return 0
  fi
  printf '>>> [limit] %s lane meter %s is at/over OSRC_LANE_LIMIT_PCT=%s — suggested fallback: %s.\n' \
    "$_ol_name" "$_ol_rd" "$_ol_thr" "$_ol_fb" >&2
  # Consent: --force-lane, or a --provider typed on THIS command line. PROVIDER_EXPLICIT alone is
  # NOT enough: env-selected providers (OSRC_PROVIDER / OUTSOURCERER_PROVIDER / OSRC_PROVIDER_EXPLICIT)
  # are ambient config that propagates silently into detached jobs — an orchestrator's exported
  # variable must not read as per-launch consent. OSRC_PROVIDER_ARG is set only by argv --provider
  # parses (outsourcerer.sh) and propagated explicitly through internal re-dispatch; internal
  # --provider injection is suppressed via OSRC_PROVIDER_INJECTED. A hop-injected provider is not
  # consent either — _gate_hop exports OSRC_FALLBACK_PINNED=1 when it rewrites ARGV.
  [ "${OSRC_FORCE_LANE:-0}" = "1" ] && return 0
  [ "${PROVIDER_EXPLICIT:-0}" = "1" ] && [ "${OSRC_PROVIDER_ARG:-0}" = "1" ] && [ "${OSRC_FALLBACK_PINNED:-0}" != "1" ] && return 0
  # Pinned -m is a deliberate model choice: refuse loudly, never silently switch it.
  if [ "${_fb_user_pinned:-0}" = "1" ] && [ "${OSRC_FALLBACK_PINNED:-0}" != "1" ]; then
    die "limit gate: ${_ol_name} lane meter ${_ol_rd} is at/over OSRC_LANE_LIMIT_PCT=${_ol_thr} — the plan window is nearly spent and the delegate would sit on a limit banner. Suggested fallback: ${_ol_fb}. This run pinned -m ${MODEL:-?}; re-run with --force-lane to proceed anyway, --provider <lane> to pin a lane explicitly, or pick another -m."
  fi
  if [ "$_ol_nohop" != "nohop" ] && _fallback_enabled && [ "${tier:-auto}" = "auto" ]; then
    if _gate_hop "$_ol_disp"; then
      printf '>>> [limit] %s lane meter %s at/over OSRC_LANE_LIMIT_PCT=%s — skipping to %s (lane %s); no dispatch, so this skip is free of the attempt budget.\n' \
        "$_ol_name" "$_ol_rd" "$_ol_thr" "${_fb_alias:-?}" "${_fb_lane:-?}" >&2
      return 10
    fi
  fi
  die "limit gate: ${_ol_name} lane meter ${_ol_rd} is at/over OSRC_LANE_LIMIT_PCT=${_ol_thr} — the plan window is nearly spent and the delegate would sit on a limit banner. Suggested fallback: ${_ol_fb}. Wait for the window to reset, re-run with --force-lane, or pin another lane with --provider."
}

# _osrc_session_limit_gate -> the interactive-session form of the plan-meter gate, called from
# session() start and _winpty_session() start AFTER the lane is resolved and BEFORE the tmux /
# winpty session is created. A session has no fallback hop and no route loop, so the gate runs in
# `nohop` mode: consent (--force-lane or argv --provider, i.e. OSRC_PROVIDER_ARG=1) proceeds with
# the warning already printed; anything else refuses loudly naming the fallback lane.
#
# Session PROVIDER tokens mean the NATIVE lane here (codex->cx, claude->cc, gemini->gm), NOT the
# dispatch transport — _quota_lane_key would fold `codex`/`cc` to `or`. Resolve via _lane_by_native
# first (the same resolution _session_launch_adapter uses), then _lane_by_token, and hand the gate
# the lane's `disp` token so _quota_lane_key lands on the right lane code.
# MODEL_EXPLICIT plays the pinned-role route_delegate gives _fb_user_pinned: an interactive
# `session start -m <model>` is a deliberate model choice and refuses loudly rather than hinting
# at a switch it cannot perform.
_osrc_session_limit_gate() {
  local _sl_p="${PROVIDER:-}" _sl_lane="" _sl_disp=""
  _sl_lane="$(_lane_by_native "$_sl_p" 2>/dev/null)" || _sl_lane="$(_lane_by_token "$_sl_p" 2>/dev/null)" || _sl_lane=""
  [ -n "$_sl_lane" ] && _sl_disp="$(_lane_field "$_sl_lane" disp 2>/dev/null)"
  [ -n "$_sl_disp" ] || _sl_disp="$_sl_p"
  local _fb_user_pinned="${MODEL_EXPLICIT:-0}"
  _osrc_limit_gate "$_sl_disp" nohop
}
