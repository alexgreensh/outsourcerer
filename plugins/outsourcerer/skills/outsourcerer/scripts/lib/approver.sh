# shellcheck shell=bash
# lib/approver.sh: logged, conservative auto-approver for delegate permission prompts (L3).
#
# Orchestrators spent dozens of turns approving read-only listings, and every hand-rolled approver
# had its own regex bug (a filename containing "approve", `test_antigravity_install`, inverted
# danger logic). This is the one approver. Policy `safe` approves ONCE (never "always allow") only
# when lib/approver_classify.py's single is_safe() gate says so; everything else is HELD and
# surfaced as `EVENT approval`. Policy `off` (the default) never touches a pane.
#
#   session approve-policy safe|off [--session <name> | --all]   set policy (default: this session)
#   session approve-policy                                         show policy
#   osrc_approver_tick <pane> [session-id]                         one pass; called by L1 supervise
#       rc 0  approved (printed EVENT approved + NEXT)
#       rc 2  held and reported now (printed EVENT approval + NEXT): new hold, or a hold older than
#             OSRC_HOLD_MIN minutes (default 5) re-emitted as "still held, waiting Nm"; a press that
#             left the prompt open is EVENT approval-not-landed, once per prompt per OSRC_HOLD_MIN
#       rc 3  held, already reported within OSRC_HOLD_MIN (prints nothing; do not re-wake)
#       rc 1  nothing to do (policy off, no approval prompt open, or pane unreadable)
# Every decision appends one JSON line to $OSRC_HOME/approvals.log.

_OSRC_LIB_DIR="${_OSRC_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"

_osrc_approver_dir() { printf '%s/approver' "$OSRC_HOME"; }

_osrc_approver_policy_get() { # <session> -> safe|off
  local d f v
  d="$(_osrc_approver_dir)/policy"
  for f in "$d/$1" "$d/_default"; do
    [ -f "$f" ] || continue
    v="$(head -1 "$f" 2>/dev/null)"
    case "$v" in safe|off) printf '%s' "$v"; return 0 ;; esac
  done
  printf off
}

_osrc_approver_policy_set() { # <session|_default> <safe|off>
  local d
  d="$(_osrc_approver_dir)/policy"
  mkdir -p "$d" 2>/dev/null && chmod 700 "$(_osrc_approver_dir)" "$d" 2>/dev/null
  printf '%s\n' "$2" > "$d/$1.tmp.$$" && mv "$d/$1.tmp.$$" "$d/$1"
}

_osrc_cmd_approve_policy() { # [safe|off] [--session <name> | --all]
  local pol="" target="${SESSION_NAME:-}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      safe|off) pol="$1"; shift ;;
      --session) [ -n "${2:-}" ] || { echo "--session needs a name" >&2; return 2; }; target="$2"; shift 2 ;;
      --session=*) target="${1#--session=}"; shift ;;
      --all) target="_default"; shift ;;
      *) echo "session approve-policy safe|off [--session <name> | --all]" >&2; return 2 ;;
    esac
  done
  case "$target" in ''|.|..|*[!A-Za-z0-9._-]*) echo "invalid session name '$target'" >&2; return 2 ;; esac
  if [ -z "$pol" ]; then
    printf 'approve-policy for %s: %s\n' "$target" "$(_osrc_approver_policy_get "$target")"
    return 0
  fi
  _osrc_approver_policy_set "$target" "$pol" || { echo "could not write approver policy" >&2; return 1; }
  [ "$(_osrc_approver_policy_get "$target")" = "$pol" ] || { echo "approver policy did not persist" >&2; return 1; }
  if [ "$target" = _default ]; then
    printf 'approve-policy %s for every session without its own policy (read back from %s/policy/_default)\n' "$pol" "$(_osrc_approver_dir)"
  else
    printf 'approve-policy %s for session %s (read back). safe = approve once only read-only, test/build/lint, or writes inside the delegate worktree; everything else is held as EVENT approval. Log: %s/approvals.log\n' "$pol" "$target" "$OSRC_HOME"
  fi
}

_osrc_approver_log() { # <session> <engine> <command> <decision> <rule> <root> <kind> <path>
  local line
  line="$(jq -cn --arg ts "$(date +%s)" --arg iso "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg s "$1" --arg e "$2" \
    --arg c "$3" --arg d "$4" --arg r "$5" --arg root "$6" --arg k "$7" --arg p "$8" \
    '{ts:($ts|tonumber),iso:$iso,session:$s,engine:$e,command:$c,decision:$d,rule:$r,root:$root,kind:$k,path:$p}' 2>/dev/null)" || return 1
  mkdir -p "$OSRC_HOME" 2>/dev/null
  printf '%s\n' "$line" >> "$OSRC_HOME/approvals.log"
}

_osrc_approver_root() { # <pane> -> the delegate's worktree (git toplevel of the pane cwd, else the cwd)
  local cwd top
  cwd="$(tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null)" || return 1
  [ -n "$cwd" ] && [ -d "$cwd" ] || return 1
  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ] && { printf '%s' "$top"; return 0; }
  printf '%s' "$cwd"
}

_osrc_approver_classify() { # <root> <kind> <path> <cmd> -> "approve <rule>" | "hold <rule>"
  local args=(--root "$1" --kind "$2" --path "$3") d old_ifs
  if [ -n "${OSRC_APPROVER_EXTRA_DIRS:-}" ]; then
    old_ifs="$IFS"; IFS=:
    for d in $OSRC_APPROVER_EXTRA_DIRS; do [ -n "$d" ] && args+=(--extra "$d"); done
    IFS="$old_ifs"
  fi
  [ -r "$_OSRC_LIB_DIR/approver_classify.py" ] || { printf 'hold classifier missing\n'; return 0; }
  printf '%s' "$4" | (cd "$1" 2>/dev/null && OSRC_HOME="${OSRC_HOME:-$HOME/.outsourcerer}" python3 -I "$_OSRC_LIB_DIR/approver_classify.py" "${args[@]}") 2>/dev/null \
    || printf 'hold classifier failed\n'
}

# The menu row that approves exactly ONCE, per engine. Anything else (a cursor on "always allow",
# a Devin scope other than Once, an unknown layout) means the approver cannot act safely.
_osrc_approver_once_row() { # uses OSRC_SCR_ENGINE / OSRC_SCR_SEL / OSRC_SCR_SCOPE
  case "$OSRC_SCR_ENGINE:$OSRC_SCR_SEL" in
    cc:"1. Yes") return 0 ;;
    codex:"1. Yes, proceed"*) return 0 ;;
    devin:Allow) [ "$OSRC_SCR_SCOPE" = once ] && return 0 ;;
    agy:"1. Yes, run command"|agy:"1. Yes, allow creation"|agy:"1. Yes, allow edit"*) return 0 ;;
  esac
  return 1
}

_osrc_approver_next() { # <session> -> the NEXT command for a held prompt
  printf 'NEXT OUTSOURCERER_TMUX=%s %s session answer\n' "$1" "${SCRIPT_PATH:-outsourcerer.sh}"
}

osrc_approver_tick() { # <pane> [session-id]
  local LC_ALL; LC_ALL="$(_osrc_utf8_locale)"; export LC_ALL
  local pane="$1" sid="${2:-${1%%:*}}" pol cap eng root verdict decision rule cmd1 key hdir hf now first last age holdmin i lockkey=""
  # The session id names files in the held dir; an empty, dotted or path-like id would match others.
  case "$sid" in ""|.*|*/*) return 1 ;; esac
  pol="$(_osrc_approver_policy_get "$sid")"
  [ "$pol" = safe ] || return 1
  eng="$(_osrc_screen_engine_of "$pane")"
  cap="$(_osrc_screen_capture "$pane")" || return 1
  _osrc_screen_analyze_text "$eng" <<<"$cap"
  hdir="$(_osrc_approver_dir)/held"
  if [ "$OSRC_SCR_STATE" != approval ]; then
    [ -n "$sid" ] && rm -f "$hdir/$sid".* 2>/dev/null
    return 1
  fi
  cmd1="$(printf '%s' "$OSRC_SCR_CMD" | awk 'NR>1{printf " ⏎ "} {printf "%s", $0}')"
  root="$(_osrc_approver_root "$pane")" || root=""
  if [ -z "$root" ]; then
    verdict="hold delegate worktree unknown (pane cwd unreadable)"
  else
    verdict="$(_osrc_approver_classify "$root" "$OSRC_SCR_KIND" "$OSRC_SCR_PATH" "$OSRC_SCR_CMD")"
  fi
  decision="${verdict%% *}"; rule="${verdict#* }"
  if [ "$decision" = approve ] && ! _osrc_approver_once_row; then
    decision=hold; rule="safe command, but the selected row is not an approve-once option (sel='$OSRC_SCR_SEL' scope='$OSRC_SCR_SCOPE')"
  fi
  now="$(date +%s)"
  if [ "$decision" = approve ]; then
    # Revalidate under the endpoint mutation lock: the prompt must still be the same one.
    if type _endpoint_mutation_lock >/dev/null 2>&1; then
      _endpoint_mutation_lock "$pane" || return 1
      lockkey="$(printf '%s' "$pane" | cksum | awk '{print $1}')"
    fi
    local want_cmd="$OSRC_SCR_CMD" want_path="$OSRC_SCR_PATH"
    cap="$(_osrc_screen_capture "$pane")"; _osrc_screen_analyze_text "$eng" <<<"$cap"
    if [ "$OSRC_SCR_STATE" != approval ] || [ "$OSRC_SCR_CMD" != "$want_cmd" ] || [ "$OSRC_SCR_PATH" != "$want_path" ] || ! _osrc_approver_once_row; then
      [ -n "$lockkey" ] && _endpoint_mutation_unlock "$lockkey"
      return 1
    fi
    # One press per prompt (L1 review finding 2): supervise and the beacon both tick every poll. The
    # lock is now held through the close-verify below, and a press is stamped per pane + prompt key,
    # so a second caller that re-reads the same not-yet-redrawn prompt never presses again.
    local pkey pdir pf pts; pkey="$(printf '%s|%s|%s' "$OSRC_SCR_KIND" "$want_path" "$want_cmd" | cksum | awk '{print $1}')"
    pdir="$(_osrc_approver_dir)/pressed"; pf="$pdir/$(printf '%s' "$pane" | cksum | awk '{print $1}').$pkey"
    mkdir -p "$pdir" 2>/dev/null
    find "$pdir" -type f -mmin +60 -exec rm -f {} + 2>/dev/null
    # Atomic claim (noclobber = O_EXCL): of two callers, exactly one creates the stamp and presses.
    if ! ( set -C; printf '%s\n' "$now" > "$pf" ) 2>/dev/null; then
      read -r pts < "$pf" 2>/dev/null; case "$pts" in ''|*[!0-9]*) pts=0 ;; esac
      if [ $((now - pts)) -lt "${OSRC_APPROVER_REPRESS_SECS:-15}" ] || ! { rm -f "$pf"; ( set -C; printf '%s\n' "$now" > "$pf" ) 2>/dev/null; }; then
        [ -n "$lockkey" ] && _endpoint_mutation_unlock "$lockkey"
        return 3
      fi
    fi
    # A durable attempt record must exist before a key is sent; otherwise a full or unwritable
    # log could let an automatic approval happen with no audit trail at all.
    if ! _osrc_approver_log "$sid" "$eng" "${cmd1:-$want_path}" attempt "$rule" "$root" "$OSRC_SCR_KIND" "$want_path"; then
      rm -f "$pf"
      [ -n "$lockkey" ] && _endpoint_mutation_unlock "$lockkey"
      decision=hold; rule="approval log is not writable"
    else
    tmux send-keys -t "$pane" Enter 2>/dev/null; i=$?
    if [ "$i" -eq 0 ]; then
      i=0
      while [ "$i" -lt "${OSRC_APPROVER_VERIFY_POLLS:-25}" ]; do
        sleep 0.2
        cap="$(_osrc_screen_capture "$pane")" || break
        _osrc_screen_analyze_text "$eng" <<<"$cap"
        if [ "$OSRC_SCR_STATE" != approval ] || [ "$OSRC_SCR_CMD" != "$want_cmd" ] || [ "$OSRC_SCR_PATH" != "$want_path" ]; then
          [ -n "$lockkey" ] && _endpoint_mutation_unlock "$lockkey"
          _osrc_approver_log "$sid" "$eng" "${cmd1:-$want_path}" approve "$rule" "$root" "$OSRC_SCR_KIND" "$want_path"
          printf 'EVENT approved %s %s approved once by policy safe (%s): %s\n' "$sid" "$now" "$rule" "${cmd1:-$want_path}"
          printf 'NEXT OUTSOURCERER_TMUX=%s %s session read\n' "$sid" "${SCRIPT_PATH:-outsourcerer.sh}"
          return 0
        fi
        i=$((i + 1))
      done
    fi
    [ -n "$lockkey" ] && _endpoint_mutation_unlock "$lockkey"
    # The keystroke did not land: reported as its own kind, once per prompt per OSRC_HOLD_MIN (the
    # approver keeps re-pressing every OSRC_APPROVER_REPRESS_SECS meanwhile). The hold file is written
    # before anything is printed, so the next tick knows it was already reported.
    holdmin="${OSRC_HOLD_MIN:-5}"; case "$holdmin" in ''|*[!0-9]*) holdmin=5 ;; esac
    key="$(printf '%s|%s|%s' "$OSRC_SCR_KIND" "$want_path" "$want_cmd" | cksum | awk '{print $1}')"
    mkdir -p "$hdir" 2>/dev/null; hf="$hdir/$sid.$key"
    first="$now"; last=0
    [ -f "$hf" ] && read -r first last 2>/dev/null < "$hf"
    case "$first" in ''|*[!0-9]*) first="$now" ;; esac; case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $((now - last)) -lt $((holdmin * 60)) ] && return 3
    printf '%s %s\n' "$first" "$now" > "$hf" || return 3
    _osrc_approver_log "$sid" "$eng" "${cmd1:-$want_path}" hold "pressed Enter, prompt still open" "$root" "$OSRC_SCR_KIND" "$want_path"
    printf 'EVENT approval-not-landed %s %s the approver pressed Enter but the prompt is still open (%s): %s\n' "$sid" "$now" "$rule" "${cmd1:-$want_path}"
    _osrc_approver_next "$sid"
    return 2
    fi
  fi
  # Held: report once, then again only after OSRC_HOLD_MIN minutes so a hold cannot sleep overnight.
  holdmin="${OSRC_HOLD_MIN:-5}"; case "$holdmin" in ''|*[!0-9]*) holdmin=5 ;; esac
  key="$(printf '%s|%s|%s' "$OSRC_SCR_KIND" "$OSRC_SCR_PATH" "$OSRC_SCR_CMD" | cksum | awk '{print $1}')"
  mkdir -p "$hdir" 2>/dev/null
  hf="$hdir/$sid.$key"
  if [ -f "$hf" ]; then
    read -r first last < "$hf" 2>/dev/null
    case "$first" in ''|*[!0-9]*) first="$now" ;; esac
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -lt $((holdmin * 60)) ]; then return 3; fi
    age=$(( (now - first) / 60 ))
    printf '%s %s\n' "$first" "$now" > "$hf"
    _osrc_approver_log "$sid" "$eng" "${cmd1:-$OSRC_SCR_PATH}" hold "still held, waiting ${age}m: $rule" "$root" "$OSRC_SCR_KIND" "$OSRC_SCR_PATH"
    printf 'EVENT approval %s %s still held, waiting %sm (%s): %s\n' "$sid" "$now" "$age" "$rule" "${cmd1:-${OSRC_SCR_PATH:-$OSRC_SCR_EVIDENCE}}"
    _osrc_approver_next "$sid"
    return 2
  fi
  [ -n "$sid" ] && rm -f "$hdir/$sid".* 2>/dev/null
  printf '%s %s\n' "$now" "$now" > "$hf"
  _osrc_approver_log "$sid" "$eng" "${cmd1:-$OSRC_SCR_PATH}" hold "$rule" "$root" "$OSRC_SCR_KIND" "$OSRC_SCR_PATH"
  printf 'EVENT approval %s %s held by policy safe (%s): %s\n' "$sid" "$now" "$rule" "${cmd1:-${OSRC_SCR_PATH:-$OSRC_SCR_EVIDENCE}}"
  _osrc_approver_next "$sid"
  return 2
}
