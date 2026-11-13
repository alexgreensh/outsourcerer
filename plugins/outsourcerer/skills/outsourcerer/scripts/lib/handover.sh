# lib/handover.sh -- session handover: `adopt` moves a previous orchestrator session's
# owned targets into the current session, `handover` renders the markdown brief a fresh
# session picks the fleet up with. Sourced by outsourcerer.sh through the lib/*.sh loader;
# defines functions only, no side effects at source time. bash 3.2 safe, set -u safe.
#
# Also hosts the owner-registry helpers moved out of outsourcerer.sh so the file does
# not grow: _owner_sid/_owner_record (the write half adopt moves and handover reads),
# _waited_ids (which ids already have a waiter — the same coverage handover prescribes).
# _owned_live_state and cmd_stop_guard stay in outsourcerer.sh with the stop guard.

_owner_sid() { # [session-id] -> sanitized session id, or nothing
  printf '%s' "${1:-${CLAUDE_CODE_SESSION_ID:-}}" | tr -cd 'A-Za-z0-9._-' | cut -c1-128
}

_owner_record() { # <job-or-session-id>
  local s; s="$(_owner_sid)"
  [ -n "$s" ] && [ -n "${1:-}" ] || return 0
  case "$1" in */*|.|..) return 0 ;; esac
  mkdir -p "$OSRC_HOME/owners/$s" 2>/dev/null && : > "$OSRC_HOME/owners/$s/$1" 2>/dev/null
  return 0
}

# _waited_ids -> ids that a running `wait` / `fanout wait` already covers, one per line.
_waited_ids() {
  local line rest gid
  ps -axo command= 2>/dev/null | grep -E 'outsourcerer(\.sh)?[^ ]* (.* )?wait( |$)' | grep -v 'stop-guard' | while IFS= read -r line; do
    rest="${line##* wait }"
    case "$line" in
      *" fanout wait "*)
        gid="${line##* fanout wait }"; gid="${gid%% *}"
        [ -f "$(_fanout_dir "$gid" 2>/dev/null)/members.tsv" ] && cut -f1 "$(_fanout_dir "$gid")/members.tsv" 2>/dev/null
        ;;
      *) printf '%s\n' "${rest%% *}" ;;
    esac
  done
}

# ---------------------------------------------------------------- adopt ----

# _handover_owner_files <dir> -> every regular-file path in <dir>, one per line.
# Dotfiles are included EXCEPT .stop-blocks, which is the old session's stop-guard
# loop-safety state, not an owned target, and stays with the session that earned it.
_handover_owner_files() {
  local f base
  for f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    [ "$base" = ".stop-blocks" ] && continue
    printf '%s\n' "$f"
  done
}

# _handover_adopt_list -> one row per owners/<sid>/: sid, target count, newest mtime.
_handover_adopt_list() {
  local d sid n newest mt human f
  for d in "$OSRC_HOME"/owners/*/; do
    [ -d "$d" ] || continue
    sid="${d%/}"; sid="${sid##*/}"
    n=0; newest=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      n=$((n + 1))
      mt="$(_mtime "$f" 2>/dev/null)"
      case "$mt" in ''|*[!0-9]*) ;; *) [ "$mt" -gt "$newest" ] 2>/dev/null && newest="$mt" ;; esac
    done <<EOF
$(_handover_owner_files "$d")
EOF
    human="-"
    [ "$newest" != "0" ] && human="$(_epoch_local "$newest" 2>/dev/null)"
    printf '%s\t%s\t%s\t%s\n' "$sid" "$n" "$newest" "$human"
  done
}

cmd_adopt() {
  local old new odir ndir f base moved=0 dup=0
  case "${1:-}" in
    --list|-l)
      [ "$#" -eq 1 ] || die "adopt --list takes no other arguments"
      _handover_adopt_list
      return 0 ;;
    -h|--help)
      echo "usage: $0 adopt --list | adopt <old-session-id>"
      echo "  adopt --list            every owners/ session dir: sid, target count, newest mtime"
      echo "  adopt <old-session-id>  move that session's owned targets into THIS session"
      return 0 ;;
  esac
  [ "$#" -eq 1 ] || die "adopt takes exactly one session id (or --list)"
  new="$(_owner_sid)"
  [ -n "$new" ] || die "adopt: no current session id (CLAUDE_CODE_SESSION_ID is unset); nothing to adopt into"
  old="$(_owner_sid "$1")"
  [ -n "$old" ] || die "adopt: could not sanitize session id '$1'"
  [ "$old" != "$new" ] || die "adopt: '$old' is already the current session"
  odir="$OSRC_HOME/owners/$old"
  [ -d "$odir" ] || die "adopt: no owners dir for session '$old' ($odir)"
  ndir="$OSRC_HOME/owners/$new"
  mkdir -p "$ndir" 2>/dev/null || die "adopt: cannot create $ndir"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="${f##*/}"
    if [ -e "$ndir/$base" ]; then
      rm -f "$f" 2>/dev/null && dup=$((dup + 1))
    elif mv "$f" "$ndir/$base" 2>/dev/null; then
      moved=$((moved + 1))
      printf '%s\n' "$base"
    else
      echo "adopt: could not move $f" >&2
    fi
  done <<EOF
$(_handover_owner_files "$odir")
EOF
  rmdir "$odir" 2>/dev/null || true   # only succeeds when nothing (e.g. .stop-blocks) remains
  echo "adopt: moved $moved target(s) from '$old' to '$new'" >&2
  [ "$dup" -gt 0 ] && echo "adopt: $dup target(s) were already owned by '$new' (duplicate markers dropped)" >&2
  return 0
}

# ------------------------------------------------------------- handover ----

# _handover_kind <id> -> job | remote | tmux | unknown
_handover_kind() {
  local id="$1"
  [ -f "$OSRC_HOME/remote/$id.json" ] && { printf 'remote'; return 0; }
  [ -d "$OSRC_JOBS/$id" ] && { printf 'job'; return 0; }
  if [ -e "$OSRC_HOME/autodetach/$id.log" ] || [ -e "$OSRC_HOME/autodetach/$id.rc" ]; then
    printf 'tmux'; return 0
  fi
  if have tmux && tmux has-session -t "=$id" 2>/dev/null; then printf 'tmux'; return 0; fi
  printf 'unknown'
}

# _handover_state <id> -> live state. Remote lanes prefer osrc_remote_state (owned by the
# remote-lane module) when it is defined, then the remote/<id>.json state field, and only
# then fall back to _owned_live_state, which knows jobs and tmux sessions.
_handover_state() {
  local id="$1" st
  if [ -f "$OSRC_HOME/remote/$id.json" ]; then
    if type osrc_remote_state >/dev/null 2>&1; then
      st="$(osrc_remote_state "$id" 2>/dev/null)"
      [ -n "$st" ] && { printf '%s' "$st"; return 0; }
    fi
    if have jq; then
      st="$(jq -r '.state // .status // empty' "$OSRC_HOME/remote/$id.json" 2>/dev/null | head -1)"
      [ -n "$st" ] && { printf '%s' "$st"; return 0; }
    fi
    printf 'unknown'; return 0
  fi
  _owned_live_state "$id" 2>/dev/null || printf 'unknown'
}

# _handover_session_meta <tmux-session-id> -> "provider\tmodel\tresolved_model\tcwd"
# from the session's LAST start event in the registry (relaunches append new starts).
_handover_session_meta() {
  have jq || return 1
  _state_jsonl_read "$OSRC_SESSION_REGISTRY" 2>/dev/null | jq -r --arg id "$1" \
    'select(.event=="start" and .session_id==$id) | [(.provider//""),(.model//""),(.resolved_model//""),(.cwd//"")] | @tsv' 2>/dev/null | tail -1
}

# _handover_pane_cwd <tmux-session-id> -> the pane's current directory, or nothing.
_handover_pane_cwd() {
  have tmux || return 0
  tmux has-session -t "=$1" 2>/dev/null || return 0
  tmux display-message -p -t "=$1" '#{pane_current_path}' 2>/dev/null
}

# _handover_field <kind> <id> <cwd|model> -> prints the value or nothing.
_handover_field() {
  local kind="$1" id="$2" what="$3" v="" meta
  case "$kind" in
    job)
      have jq || return 0
      case "$what" in
        cwd)   v="$(jq -r '.cwd // empty' "$OSRC_JOBS/$id/meta.json" 2>/dev/null)" ;;
        model) v="$(jq -r '[(.provider//""),(.model//""),(.lane//""),(.tier//"")] | map(select(. != "")) | join(" ")' "$OSRC_JOBS/$id/meta.json" 2>/dev/null)" ;;
      esac ;;
    tmux)
      meta="$(_handover_session_meta "$id")"
      case "$what" in
        cwd)
          v="$(printf '%s' "$meta" | cut -f4)"
          [ -z "$v" ] && v="$(_handover_pane_cwd "$id")" ;;
        model)
          v="$(printf '%s' "$meta" | awk -F'\t' '{out=""; for(i=1;i<=3;i++) if($i!="") out=out (out?" ":"") $i; print out}')" ;;
      esac ;;
    remote)
      have jq || return 0
      case "$what" in
        cwd)   v="$(jq -r '.cwd // .workdir // .working_dir // empty' "$OSRC_HOME/remote/$id.json" 2>/dev/null | head -1)" ;;
        model) v="$(jq -r '[(.provider//""),(.model//""),(.lane//""),(.requested_model//"")] | map(select(. != "")) | join(" ")' "$OSRC_HOME/remote/$id.json" 2>/dev/null | head -1)" ;;
      esac ;;
  esac
  [ -n "$v" ] && printf '%s' "$v"
}

cmd_handover() {
  local out="" sid dir id kind state cwd model n=0 f
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out)    out="${2:-}"; [ -n "$out" ] || die "handover --out needs a file"; shift 2 ;;
      --out=*)  out="${1#--out=}"; [ -n "$out" ] || die "handover --out needs a file"; shift ;;
      -h|--help)
        echo "usage: $0 handover [--out FILE]"
        echo "  writes a markdown brief for the NEXT orchestrator session: every target this"
        echo "  session owns (kind, live state, model, cwd) plus the adopt + wait commands to run."
        echo "  default: \$OSRC_HOME/handover/<session-id>-<timestamp>.md"
        return 0 ;;
      *) die "handover: unknown argument '$1' (try --out FILE)" ;;
    esac
  done
  sid="$(_owner_sid)"
  [ -n "$sid" ] || die "handover: no current session id (CLAUDE_CODE_SESSION_ID is unset)"
  dir="$OSRC_HOME/owners/$sid"
  if [ -z "$out" ]; then
    mkdir -p "$OSRC_HOME/handover" 2>/dev/null || die "handover: cannot create $OSRC_HOME/handover"
    out="$OSRC_HOME/handover/$sid-$(date +%Y%m%d-%H%M%S).md"
  fi
  mkdir -p "$(dirname "$out")" 2>/dev/null || die "handover: cannot create $(dirname "$out")"
  {
    printf '# Outsourcerer handover -- orchestrator session `%s`\n\n' "$sid"
    printf -- '- generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null)"
    printf -- '- state home: `%s`\n\n' "$OSRC_HOME"
    printf '## Take ownership\n\n'
    printf 'First command for the incoming session -- it moves every target below into your\n'
    printf 'owners/ dir so the stop-guard and `wait` cover them:\n\n'
    printf '    %s adopt %s\n\n' "$SCRIPT_PATH" "$sid"
    if [ -d "$dir" ]; then
      printf '## Owned targets\n\n'
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        id="${f##*/}"
        kind="$(_handover_kind "$id")"; state="$(_handover_state "$id")"
        cwd="$(_handover_field "$kind" "$id" cwd)"; model="$(_handover_field "$kind" "$id" model)"
        n=$((n + 1))
        printf '### `%s` -- %s, %s\n\n' "$id" "$kind" "$state"
        [ -n "$model" ] && printf -- '- model: %s\n' "$model"
        [ -n "$cwd" ] && printf -- '- cwd: `%s`\n' "$cwd"
        case "$kind:$state" in
          remote:*) printf -- '- remote lane: tracked in `%s`; no local `wait` target\n' "$OSRC_HOME/remote/$id.json" ;;
          *:live)  printf -- '- waiter: `%s wait %s` (run as a background command)\n' "$SCRIPT_PATH" "$id" ;;
          *)       printf -- '- no waiter needed (%s)\n' "$state" ;;
        esac
        printf '\n'
      done <<EOF
$(_handover_owner_files "$dir")
EOF
      [ "$n" -eq 0 ] && printf '(no target markers in `%s`)\n\n' "$dir"
    else
      printf '## Owned targets\n\n(this session owns nothing yet -- `%s` does not exist)\n\n' "$dir"
    fi
    printf '## Other owner sessions on this state home\n\n'
    printf '```\n%s adopt --list\n```\n\n' "$SCRIPT_PATH"
    _handover_adopt_list | while IFS="$(printf '\t')" read -r osid cnt mt hum; do
      [ "$osid" = "$sid" ] && continue
      printf -- '- `%s`: %s target(s), newest %s\n' "$osid" "$cnt" "$hum"
    done
    printf '\nSee also: `%s status` for the job table, `%s fleet ls` for the live fleet view.\n' "$SCRIPT_PATH" "$SCRIPT_PATH"
  } > "$out" || die "handover: cannot write $out"
  echo "handover: wrote $out ($n target(s) for session '$sid')"
  return 0
}
