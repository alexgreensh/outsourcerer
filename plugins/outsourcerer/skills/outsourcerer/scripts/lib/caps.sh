# =============================================================================
# lib/caps.sh — per-lane usage caps (--cap / lane cap), split out of lib/spend.sh
# for the 1000-line file budget (r11 F3). Loaded by the engine's lib/*.sh glob.
# Depends on lib/limits.sh meter readers and OSRC_HOME; no spend-gate internals.
# =============================================================================

# =============================================================================
# Per-lane usage caps (--cap / lane cap)
# =============================================================================

# $OSRC_HOME/lane-caps: standing caps, one per line: "<lane> <meter><=<pct>".
_lane_caps_file() { printf '%s/lane-caps' "$OSRC_HOME"; }

# _osrc_cap_valid <spec> -> rc0 for meter<=pct where pct is a REAL number in [0,100]
# (digits with at most one dot — "<=.." or "<=1.2.3" or "<=abc" are not caps, they are
# typos that would otherwise trip on every reading or never trip at all).
_osrc_cap_valid() {
  case "$1" in
    *=*) local m="${1%%<=*}" p="${1##*<=}"
         [ "$m" = "$1" ] && return 1   # no <= separator
         case "$p" in ''|*.*.*|*[!0-9.]*) return 1 ;; esac
         case "$p" in *[0-9]*) ;; *) return 1 ;; esac
         case "$m" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
         awk -v p="$p" 'BEGIN{exit !(p+0>=0 && p+0<=100)}' || return 1
         return 0 ;;
    *) return 1 ;;
  esac
}

# _osrc_cap_window <lane> <meter> -> the lane's conserve_window this meter caps.
# Accepts a raw window name (claude7d, codexwk...) or a class: 5h | weekly|7d|week.
_osrc_cap_window() {
  local lane="${1:-}" meter="${2:-}" cw w
  cw="$(_lane_field "$lane" conserve_windows 2>/dev/null)" || return 1
  [ -n "$cw" ] || return 1
  for w in $cw; do [ "$w" = "$meter" ] && { printf '%s' "$w"; return 0; }; done
  case "$meter" in
    5h|5-hour|five-hour)
      for w in $cw; do case "$w" in *5h*) printf '%s' "$w"; return 0 ;; esac; done ;;
    weekly|7d|week|w)
      for w in $cw; do case "$w" in *7d*|*wk*|*week*) printf '%s' "$w"; return 0 ;; esac; done ;;
  esac
  return 1
}

# _osrc_cap_specs_for <lane> -> all cap specs applying to this lane: standing
# (lane-caps file rows for the lane) then per-launch OSRC_CAPS (space-separated).
_osrc_cap_specs_for() {
  local lane="${1:-}" cf spec
  cf="$(_lane_caps_file)"
  [ -f "$cf" ] && while IFS=' ' read -r _cl _cs; do
    [ "$_cl" = "$lane" ] && [ -n "$_cs" ] && printf '%s\n' "$_cs"
  done < "$cf"
  local _w
  for _w in ${OSRC_CAPS:-}; do printf '%s\n' "$_w"; done
}

# _osrc_cap_now <window> <limits-line> -> current pct for one window, rc1 unmeasured.
_osrc_cap_now() {
  local w="${1:-}" tok
  for tok in ${2:-}; do
    case "$tok" in "$w="*) printf '%s' "${tok#*=}"; return 0 ;; esac
  done
  return 1
}

# _osrc_cap_tripped <lane> [limits-line] -> rc0 + prints "spec now<pct>" for the
# FIRST cap at/past its line (standing caps first, then per-launch). rc1 = clear.
_osrc_cap_tripped() {
  local lane="${1:-}" limits="${2:-}" spec m p w now hit=""
  [ -n "$lane" ] || return 1
  [ -n "$limits" ] || limits="$(_osrc_limits_snapshot 2>/dev/null)"
  [ -n "$limits" ] || return 1
  while IFS= read -r spec; do
    _osrc_cap_valid "$spec" || continue
    m="${spec%%<=*}"; p="${spec##*<=}"
    w="$(_osrc_cap_window "$lane" "$m" 2>/dev/null)" || continue
    now="$(_osrc_cap_now "$w" "$limits" 2>/dev/null)" || continue
    case "$now" in ''|*[!0-9.]*) continue ;; esac
    if awk -v a="$now" -v b="$p" 'BEGIN{exit !(a+0>=b+0)}'; then
      hit="$spec now$now"; break
    fi
  done <<EOF
$(_osrc_cap_specs_for "$lane")
EOF
  [ -n "$hit" ] || return 1
  printf '%s\n' "$hit"; return 0
}

# _osrc_cap_unbound <lane> -> prints cap specs for this lane whose meter does NOT bind to
# any of the lane's conserve windows (silently inert — the cap can never trip). rc1 when
# every spec binds or none exist.
_osrc_cap_unbound() {
  local lane="${1:-}" spec m out=""
  [ -n "$lane" ] || return 1
  while IFS= read -r spec; do
    _osrc_cap_valid "$spec" || continue
    m="${spec%%<=*}"
    _osrc_cap_window "$lane" "$m" >/dev/null 2>&1 || out="$out $spec"
  done <<EOF
$(_osrc_cap_specs_for "$lane")
EOF
  out="${out# }"
  [ -n "$out" ] || return 1
  printf '%s' "$out"; return 0
}

# _osrc_cap_unread <lane> [limits-line] -> prints bound cap specs whose window has NO
# fresh reading (the cap exists but cannot be evaluated — a silent hole). rc1 when every
# bound spec has a reading or none exist.
_osrc_cap_unread() {
  local lane="${1:-}" limits="${2:-}" spec m w now out=""
  [ -n "$lane" ] || return 1
  [ -n "$limits" ] || limits="$(_osrc_limits_snapshot 2>/dev/null)"
  while IFS= read -r spec; do
    _osrc_cap_valid "$spec" || continue
    m="${spec%%<=*}"
    w="$(_osrc_cap_window "$lane" "$m" 2>/dev/null)" || continue   # unbound handled elsewhere
    now="$(_osrc_cap_now "$w" "$limits" 2>/dev/null)" || { out="$out $spec"; continue; }
    case "$now" in ''|*[!0-9.]*) out="$out $spec" ;; esac
  done <<EOF
$(_osrc_cap_specs_for "$lane")
EOF
  out="${out# }"
  [ -n "$out" ] || return 1
  printf '%s' "$out"; return 0
}

# _osrc_cap_gate <lane> <model> <disp> [nohop] -> pre-launch cap check, placed next
# to _osrc_limit_gate in route_delegate and the session paths. rc0 clear/consented;
# dies on refusal; rc10 = a zero-cost hop was armed (caller `continue`s).
_osrc_cap_gate() {
  local lane="${1:-}" model="${2:-}" disp="${3:-}" nohop="${4:-}"
  [ -n "$lane" ] || return 0
  local hit; hit="$(_osrc_cap_tripped "$lane" 2>/dev/null)" || {
    # Clear of a TRIPPED cap — but a cap that cannot be evaluated is not "clear":
    # unbound specs warn (they can never trip), bound specs with no fresh reading warn
    # too, and under an explicit pin both refuse loudly instead of silently proceeding.
    local unb unr lname0
    lname0="$(_lane_plan_display "$lane" 2>/dev/null)"; [ -n "$lname0" ] || lname0="$lane"
    unb="$(_osrc_cap_unbound "$lane" 2>/dev/null)"
    unr="$(_osrc_cap_unread "$lane" 2>/dev/null)"
    if [ -n "$unb$unr" ]; then
      [ -n "$unb" ] && printf '>>> [cap] %s: cap spec(s) %s do not bind to any %s window — they can never trip.\n' "$lname0" "$unb" "$lane" >&2
      [ -n "$unr" ] && printf '>>> [cap] %s: capped meter has no fresh reading for %s — cap cannot be verified.\n' "$lname0" "$unr" >&2
      if [ "${_fb_user_pinned:-0}" = "1" ] && [ "${OSRC_FALLBACK_PINNED:-0}" != "1" ]; then
        die "cap gate: ${lname0} has unverifiable cap(s) (${unb:+unbound:$unb }${unr:+unread:$unr}) and this run pinned ${model:-?} — refusing rather than launching with a cap that cannot be checked. Fix the cap (lane cap ${lane} ...) or re-run unpinned."
      fi
    fi
    return 0
  }
  local spec nowpct m p w
  spec="${hit%% now*}"; nowpct="${hit##* now}"
  m="${spec%%<=*}"; p="${spec##*<=}"
  w="$(_osrc_cap_window "$lane" "$m" 2>/dev/null)"
  local lname; lname="$(_lane_plan_display "$lane" 2>/dev/null)"; [ -n "$lname" ] || lname="$lane"
  printf '>>> [cap] %s lane %s is at %s%% — at/over its cap %s (window %s).\n' \
    "$lname" "${w:-$m}" "$nowpct" "$spec" "${w:-?}" >&2
  # A cap is a user-set guardrail: consent paths are --force-lane or raising the cap.
  [ "${OSRC_FORCE_LANE:-0}" = "1" ] && return 0
  if [ "${_fb_user_pinned:-0}" = "1" ] && [ "${OSRC_FALLBACK_PINNED:-0}" != "1" ]; then
    die "cap gate: ${lname} lane meter ${w:-$m} is at ${nowpct}% — at/over cap ${spec}. This run pinned -m ${model:-?}; raise the cap (lane cap ${lane} ${m}<=<pct> or --cap ${m}<=<pct>), clear it (lane cap ${lane} --clear), or re-run with --force-lane."
  fi
  if [ "$nohop" != "nohop" ] && _fallback_enabled && [ "${tier:-auto}" = "auto" ]; then
    if _gate_hop "$disp"; then
      printf '>>> [cap] %s at cap %s — skipping to %s (lane %s); no dispatch, so this skip is free of the attempt budget.\n' \
        "$lname" "$spec" "${_fb_alias:-?}" "${_fb_lane:-?}" >&2
      return 10
    fi
  fi
  die "cap gate: ${lname} lane meter ${w:-$m} is at ${nowpct}% — at/over cap ${spec}. Raise the cap, clear it (lane cap ${lane} --clear), switch lane, or re-run with --force-lane."
}

# _osrc_session_cap_gate -> session-start form (nohop): both session paths call this
# next to _osrc_session_limit_gate. MODEL_EXPLICIT plays the pinned role.
_osrc_session_cap_gate() {
  local _sc_p="${PROVIDER:-}" _sc_lane="" _sc_disp=""
  _sc_lane="$(_lane_by_native "$_sc_p" 2>/dev/null)"; [ -n "$_sc_lane" ] || _sc_lane="$(_lane_by_token "$_sc_p" 2>/dev/null)"; [ -n "$_sc_lane" ] || _sc_lane=""
  [ -n "$_sc_lane" ] && _sc_disp="$(_lane_field "$_sc_lane" disp 2>/dev/null)"
  [ -n "$_sc_disp" ] || _sc_disp="$_sc_p"
  local _fb_user_pinned="${MODEL_EXPLICIT:-0}"
  _osrc_cap_gate "$_sc_lane" "${MODEL:-$DEFAULT_MODEL}" "$_sc_disp" nohop
}

# _osrc_cap_poll <id> <lane> <model> -> supervise-side check: emits EVENT limit once
# per (job,cap-spec) when a running lane crosses its cap. Never blocks the job —
# "told to wrap up" is the orchestrator's NEXT, not a kill.
_osrc_cap_poll() {
  local id="${1:-}" lane="${2:-}" model="${3:-}"
  [ -n "$lane" ] || return 0
  # meta.json .lane is normally the canonical code already; normalize defensively so a
  # disp/provider value still resolves before the caps file and window lookup.
  lane="$(_lane_by_disp "$lane" 2>/dev/null || _lane_by_token "$lane" 2>/dev/null || _quota_lane_key "$lane" 2>/dev/null || printf '%s' "$lane")"
  local hit; hit="$(_osrc_cap_tripped "$lane" 2>/dev/null)" || return 0
  local spec nowpct
  spec="${hit%% now*}"; nowpct="${hit##* now}"
  # Dedupe: one event per JOB per spec. The marker lives in the job dir when known
  # (already per-job); without one it is keyed by job/session id so two sessions on
  # the same lane+spec each get their own event instead of the first silencing the rest.
  local marker="${OSRC_JOB_DIR:-$OSRC_HOME}/.caplimit.${id:-session}.$(printf '%s' "$spec" | tr -c 'A-Za-z0-9' '_')"
  [ -f "$marker" ] && return 0
  ( umask 077; : > "$marker" ) 2>/dev/null || true
  local next
  next="$0 lane cap ${lane} --clear   # or: $0 lane cap ${lane} ${spec%<=*}<=<higher>   # or stop the lane"
  _osrc_event limit "${id:-$lane}" "cap:$spec now:$nowpct" "$next" cap >&2
  printf '>>> [cap] job %s: %s lane crossed cap %s (now %s%%) — wrapping up is advised; no new work should be sent.\n' \
    "${id:-?}" "$lane" "$spec" "$nowpct" >&2
  return 0
}

# _osrc_cap_send_ok <text> -> rc0 when a session-send text is a wrap-up/stop message
# (allowed through the cap gate); rc1 = new work (refused while capped).
_osrc_cap_send_ok() {
  # Wrap-up intent = the message STARTS with a wrap/stop keyword (optionally after "please").
  # Prefix match, not full-line: "finish the refactor" is wrap-up; "mark done and add X" is not
  # (it does not start with the keyword). Best-effort — the pre-launch gate is the hard bound.
  printf '%s' "${1:-}" | grep -qiE '^[[:space:]]*(please[[:space:]]+)?(wrap[ -]?up|wrap|finish|wind[ -]?down|stop|halt|conclude|complete|done|shut[ -]?down)([[:space:].!,]|$)'
}

# _osrc_session_cap_send <session-id> <text> -> the "no new work at cap" enforcement for
# interactive sessions: resolves the session's lane from its start record and refuses NEW
# work when that lane sits at/over a cap. Wrap-up/stop messages always pass (they are how the
# lane gets told to finish). rc0 = send allowed; dies on refusal.
_osrc_session_cap_send() {
  local sess="${1:-}" text="${2:-}" rec prov model lane
  [ -n "$sess" ] || return 0
  rec="$(_session_record "$sess" 2>/dev/null)" || rec=""
  prov="$(printf '%s' "$rec" | cut -f1)"; model="$(printf '%s' "$rec" | cut -f2)"
  [ -n "$prov" ] || return 0    # no record -> cannot prove a lane -> do not block the send
  lane="$(_lane_by_native "$prov" 2>/dev/null)" || lane="$(_lane_by_token "$prov" 2>/dev/null)" || lane=""
  [ -n "$lane" ] || return 0
  local hit; hit="$(_osrc_cap_tripped "$lane" 2>/dev/null)" || return 0
  _osrc_cap_send_ok "$text" && return 0
  local spec nowpct
  spec="${hit%% now*}"; nowpct="${hit##* now}"
  # Dedupe the EVENT per session (keyed by session id + spec, not the spec alone) so
  # repeated refused sends do not spam lanes/events.jsonl — the refusal itself always fires.
  local marker="${OSRC_JOB_DIR:-$OSRC_HOME}/.caplimit.${sess}.$(printf '%s' "$spec" | tr -c 'A-Za-z0-9' '_')"
  if [ ! -f "$marker" ]; then
    ( umask 077; : > "$marker" ) 2>/dev/null || true
    _osrc_event limit "$sess" "cap:$spec now:$nowpct" \
      "$0 lane cap $lane --clear   # or raise the cap / stop the session" cap >&2
  fi
  die "session send refused: $lane lane is at ${nowpct}% — at/over cap $spec. Wrap-up messages (wrap up / finish / stop) still go through; new work does not. Raise the cap ('$0 lane cap $lane ${spec%%<=*}<=<pct>'), clear it ('$0 lane cap $lane --clear'), or stop the session."
}

# ---- lane verb handlers (dispatched from cmd_lane in lib/remote.sh) -----------------
#
# L2 owns the `lane` command: cmd_lane lives in lib/remote.sh (remote lanes + review
# queue) and carries these L7 cases alongside its own add|ls|show|poll|rm|events:
#   lane cap <lane> <meter><=pct> | lane cap <lane> --clear  -> osrc_lane_cap
#   lane billing <lane> [model]                             -> osrc_lane_billing
#   lane summary [--json]                                   -> osrc_lane_summary
#   lane limits                                            -> osrc_lane_limits
# (the old `lane ls` billing+caps table; `lane ls` itself is L2's remote-lane list.
#  `lane summary|limits` used to share the feed alias — `limits` now means the table.)
# `lane billing` dispatches to the osrc_lane_billing classifier itself — its
# <lane|disp|provider|alias> [model] [disp] signature is a superset of the verb's args.

osrc_lane_cap() {
  local lane="${1:-}" act="${2:-}"
  [ -n "$lane" ] || die "usage: lane cap <lane> <meter><=pct> | lane cap <lane> --clear"
  # Lane context, NOT quota/provider context: `cc` must stay the native-claude LANE
  # (quota_key would fold the provider token cc->or and silently cap the wrong pool).
  # Keep the ORIGINAL token through the fallback chain — a lookup that prints nothing
  # must not empty $lane and skip the remaining resolutions (the `lane cap codex` bug).
  local _tok="$lane"
  lane="$(_lane_by_token "$_tok" 2>/dev/null)"; [ -n "$lane" ] || lane="$(_lane_by_native "$_tok" 2>/dev/null)"
  [ -n "$lane" ] || lane="$(_lane_by_provider "$_tok" 2>/dev/null)"
  [ -n "$lane" ] || die "lane cap: unknown lane '$_tok' (use a lane code like cx/cc/dv/gm or a provider name like codex/claude)"
  [ "$lane" != gi ] || lane=gm   # "gemini": the image lane shares the Antigravity pool; the text lane is metered
  local cf; cf="$(_lane_caps_file)"
  if [ "$act" = "--clear" ] || [ "$act" = "clear" ]; then
    # Cap-event dedupe markers are per (job|session,spec): clearing the caps must also
    # clear them, or a re-added identical cap would never re-notify. Done unconditionally —
    # per-launch --cap markers exist even when no standing caps file does.
    rm -f "$OSRC_HOME"/.caplimit.* "$OSRC_HOME"/jobs/*/.caplimit.* 2>/dev/null || true
    [ -f "$cf" ] || { echo "lane cap: no standing caps declared for $lane (cap-event markers cleared)."; return 0; }
    local tmp="$cf.tmp.$$"
    grep -v "^$lane " "$cf" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$cf" 2>/dev/null || { rm -f "$tmp"; die "lane cap: could not update $cf"; }
    echo "lane cap: cleared standing caps for $lane (and their cap-event markers)"
    return 0
  fi
  _osrc_cap_valid "$act" || die "usage: lane cap <lane> <meter><=pct>  (e.g. lane cap cx weekly<=40, lane cap cc 5h<=80)"
  # Refuse a cap whose meter cannot bind to this lane's windows — a stored cap that can
  # never trip is a lie, not a guardrail.
  _osrc_cap_window "$lane" "${act%%<=*}" >/dev/null 2>&1 \
    || die "lane cap: meter '${act%%<=*}' does not bind to lane '$lane' (no matching conserve window — the cap could never trip). Use a window this lane meters (e.g. $( _lane_field "$lane" conserve_windows 2>/dev/null | tr ' ' ',' ))."
  _mkdir_private "$OSRC_HOME" >/dev/null 2>&1 || die "cannot write state home $OSRC_HOME"
  # Replace an existing spec for the same meter on this lane; append otherwise.
  local m="${act%%<=*}" tmp="$cf.tmp.$$" found=0
  if [ -f "$cf" ]; then
    while IFS=' ' read -r l s; do
      [ "$l" = "$lane" ] && [ "${s%%<=*}" = "$m" ] && { found=1; continue; }
      [ -n "$l" ] && printf '%s %s\n' "$l" "$s"
    done < "$cf" > "$tmp"
  fi
  printf '%s %s\n' "$lane" "$act" >> "$tmp"
  mv -f "$tmp" "$cf" 2>/dev/null || { rm -f "$tmp"; die "lane cap: could not update $cf"; }
  echo "lane cap: $lane $act$( [ "$found" = 1 ] && echo ' (replaced)' )"
}

# _osrc_brief_caps <limits-line> -> one "caps" line for cmd_brief / handover briefs:
# every standing cap rendered as "<lane> cap <pct>% <window-class>, now <pct>%".
# Silent (rc1) when no standing caps exist.
_osrc_brief_caps() {
  local cf limits="${1:-}" l spec m p w now out=""
  cf="$(_lane_caps_file)"
  [ -f "$cf" ] || return 1
  [ -n "$limits" ] || limits="$(_osrc_limits_snapshot 2>/dev/null)"
  while IFS=' ' read -r l spec; do
    [ -n "$l" ] && [ -n "$spec" ] || continue
    _osrc_cap_valid "$spec" || continue
    m="${spec%%<=*}"; p="${spec##*<=}"
    w="$(_osrc_cap_window "$l" "$m" 2>/dev/null)" || w="$m"
    now=""; [ -n "$limits" ] && now="$(_osrc_cap_now "$w" "$limits" 2>/dev/null)"
    out="$out · $l cap ${p}% ${m}, now ${now:-?}%"
  done < "$cf"
  [ -n "$out" ] || return 1
  printf 'caps        :%s\n' "${out# · }"
  return 0
}

osrc_lane_limits() {
  local cf; cf="$(_lane_caps_file)"
  printf '%-10s %-12s %s\n' LANE BILLING CAPS "$([ -f "$cf" ] && echo '(standing)')"
  local l b caps now
  for l in $OSRC_LANE_REGISTRY; do
    b="$(osrc_lane_billing "$l" 2>/dev/null)"
    caps=""
    [ -f "$cf" ] && caps="$(awk -v l="$l" '$1==l{printf "%s%s ",$2,$3}' "$cf" 2>/dev/null)"
    [ -n "${OSRC_CAPS:-}" ] && caps="$caps(per-launch: $OSRC_CAPS)"
    [ -n "$caps" ] || caps="-"
    printf '%-10s %-12s %s\n' "$l" "$b" "$caps"
  done
}
