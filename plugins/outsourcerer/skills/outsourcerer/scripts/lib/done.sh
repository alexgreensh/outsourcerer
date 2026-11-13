# lib/done.sh — the "done" contract for session lanes.
#
# An idle delegate can be finished OR stuck halfway; the screen cannot tell them apart, so a lane
# needs a machine-checkable definition of done. `session start --done-when <spec>` records the
# contract at $OSRC_HOME/done/<session>.json ({"spec","cwd"}) and `osrc_done_state` answers one of:
#   done | not-done | no-contract | error <reason>
# Specs:
#   file:<path>           the file exists (absolute, or relative to the contract cwd)
#   branch:<b>@<marker>   the tip commit of local branch <b> contains <marker> (e.g. @READY)
#   check:<shell-command> exits 0 within 300 s, run from the contract cwd; result cached 60 s
#
# This file also hosts session helpers moved out of outsourcerer.sh so that legacy file does not
# grow (scripts/check_file_size.py ratchet): _session_current_generation, _session_record,
# _validate_session_name. They are unchanged and resolve at call time like everything else here.

_osrc_done_dir() { printf '%s/done' "${OSRC_HOME:-$HOME/.outsourcerer}"; }

# Session names become filenames under $OSRC_HOME/done: same charset rule as _validate_session_name
# (non-empty, not '.'/'..', [A-Za-z0-9._-] only) but as a predicate so state queries can answer
# `error bad-name` instead of dying.
_osrc_done_name_ok() {
  case "${1:-}" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# osrc_done_validate <spec> -> rc 0 when the spec is well-formed; rc 1 + stderr reason otherwise.
osrc_done_validate() {
  local spec="${1:-}" rest branch marker cmd
  case "$spec" in
    file:*)
      [ -n "${spec#file:}" ] || { echo "file: needs a path" >&2; return 1; } ;;
    branch:*)
      rest="${spec#branch:}"
      case "$rest" in *@?*) ;; *) echo "branch: needs <branch>@<marker>" >&2; return 1 ;; esac
      branch="${rest%@*}"; marker="${rest##*@}"
      { [ -n "$branch" ] && [ -n "$marker" ]; } || { echo "branch: needs <branch>@<marker>" >&2; return 1; }
      case "$branch" in *[[:space:]]*|-*) echo "branch: bad branch name '$branch'" >&2; return 1 ;; esac ;;
    check:*)
      cmd="${spec#check:}"
      [ -n "${cmd//[[:space:]]/}" ] || { echo "check: needs a shell command" >&2; return 1; } ;;
    *)
      echo "spec must start with file: | branch: | check:" >&2; return 1 ;;
  esac
  return 0
}

# osrc_done_set <name> <spec> <cwd> -> write $OSRC_HOME/done/<name>.json atomically.
osrc_done_set() {
  local name="${1:-}" spec="${2:-}" cwd="${3:-}" dir f tmp
  _osrc_done_name_ok "$name" || { echo "osrc_done_set: invalid session name '$name'" >&2; return 1; }
  osrc_done_validate "$spec" || return 1
  [ -n "$cwd" ] || { echo "osrc_done_set: cwd required" >&2; return 1; }
  dir="$(_osrc_done_dir)"
  mkdir -p "$dir" 2>/dev/null || { echo "osrc_done_set: cannot create $dir" >&2; return 1; }
  f="$dir/$name.json"; tmp="$f.tmp.$$"
  if jq -n --arg spec "$spec" --arg cwd "$cwd" '{spec:$spec,cwd:$cwd}' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; echo "osrc_done_set: cannot write $f" >&2; return 1; }
  else
    rm -f "$tmp"; echo "osrc_done_set: jq failed" >&2; return 1
  fi
  return 0
}

# osrc_done_get <name> -> print the stored contract JSON; rc 1 when there is none.
osrc_done_get() {
  local name="${1:-}" f
  _osrc_done_name_ok "$name" || return 1
  f="$(_osrc_done_dir)/$name.json"
  [ -f "$f" ] || return 1
  cat "$f"
}

# osrc_done_clear <name> -> drop the contract and its check cache (session stop / clean restart).
osrc_done_clear() {
  local name="${1:-}" dir
  _osrc_done_name_ok "$name" || return 0
  dir="$(_osrc_done_dir)"
  rm -f "$dir/$name.json" "$dir/$name.checkcache" "$dir/$name.json.tmp."* 2>/dev/null
  return 0
}

# branch:<branch>@<marker> evaluator. Prints one state word.
_osrc_done_branch() { # <cwd> <branch>@<marker>
  local cwd="$1" rest="$2" branch marker msg
  case "$rest" in *@?*) ;; *) echo "error bad-spec"; return 0 ;; esac
  branch="${rest%@*}"; marker="${rest##*@}"
  { [ -n "$branch" ] && [ -n "$marker" ]; } || { echo "error bad-spec"; return 0; }
  case "$branch" in *[[:space:]]*|-*) echo "error bad-spec"; return 0 ;; esac
  [ -d "$cwd" ] || { echo "error cwd-missing"; return 0; }
  git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || { echo "error not-a-repo"; return 0; }
  # A branch that does not exist is simply not-done, not an error.
  git -C "$cwd" rev-parse --verify --quiet "refs/heads/$branch^{commit}" >/dev/null 2>&1 \
    || { echo not-done; return 0; }
  msg="$(git -C "$cwd" log -1 --format=%B "refs/heads/$branch" 2>/dev/null)" \
    || { echo "error git-log"; return 0; }
  printf '%s\n' "$msg" | grep -qF -- "$marker" && echo done || echo not-done
}

# check:<cmd> evaluator with a 60 s per-session result cache so a poll loop does not rerun the
# command every tick. done requires exit 0 inside the bound (default 300 s, OSRC_DONE_CHECK_SECS);
# a timeout or any nonzero exit is not-done — the contract is "exits 0", nothing softer.
_osrc_done_check() { # <name> <cwd> <cmd>
  local name="$1" cwd="$2" cmd="$3" now cts cstate cache rc state
  [ -n "${cmd//[[:space:]]/}" ] || { echo "error bad-spec"; return 0; }
  [ -d "$cwd" ] || { echo "error cwd-missing"; return 0; }
  cache="$(_osrc_done_dir)/$name.checkcache"
  now="$(date +%s)"
  if [ -f "$cache" ]; then
    cts=""; cstate=""
    read -r cts cstate < "$cache" 2>/dev/null || :
    case "$cts" in ''|*[!0-9]*) cts=0 ;; esac
    case "$cstate" in
      done|not-done)
        [ $((now - cts)) -lt "${OSRC_DONE_CACHE_SECS:-60}" ] && { echo "$cstate"; return 0; } ;;
    esac
  fi
  if type _timeout >/dev/null 2>&1; then
    _timeout "${OSRC_DONE_CHECK_SECS:-300}" bash -c 'cd "$1" && eval "$2"' _ "$cwd" "$cmd" >/dev/null 2>&1
  else
    ( cd "$cwd" && eval "$cmd" ) >/dev/null 2>&1
  fi
  rc=$?
  [ "$rc" -eq 0 ] && state=done || state=not-done
  now="$(date +%s)"
  printf '%s %s\n' "$now" "$state" > "$cache.tmp.$$" 2>/dev/null \
    && mv "$cache.tmp.$$" "$cache" 2>/dev/null
  rm -f "$cache.tmp.$$" 2>/dev/null
  echo "$state"
}

# osrc_done_state <name> -> exactly one of: done | not-done | no-contract | error <reason>
osrc_done_state() {
  local name="${1:-}" f spec cwd
  _osrc_done_name_ok "$name" || { echo "error bad-name"; return 0; }
  f="$(_osrc_done_dir)/$name.json"
  [ -f "$f" ] || { echo "no-contract"; return 0; }
  spec="$(jq -r '.spec // empty' "$f" 2>/dev/null)" || { echo "error unreadable-contract"; return 0; }
  cwd="$(jq -r '.cwd // empty' "$f" 2>/dev/null)"
  case "$spec" in
    file:*|branch:*|check:*) ;;
    *) echo "error bad-spec"; return 0 ;;
  esac
  [ -n "$cwd" ] || { echo "error bad-contract"; return 0; }
  case "$spec" in
    file:*)
      local p="${spec#file:}" t
      case "$p" in /*) t="$p" ;; *) t="$cwd/$p" ;; esac
      [ -e "$t" ] && echo done || echo not-done ;;
    branch:*) _osrc_done_branch "$cwd" "${spec#branch:}" ;;
    check:*)  _osrc_done_check "$name" "$cwd" "${spec#check:}" ;;
  esac
}

# --- relocated from outsourcerer.sh (size ratchet; _session_record carries L5's perm_profile field) ---

# The current model generation of a managed session, from its latest start record (1 if none).
# Non-start events must carry this forward: _session_registry_append defaults generation to 1, and
# an `effort` record stamped with 1 over a generation-3 session rewinds the model-pin lock key.
_session_current_generation() { # <session-id>
  local gen
  gen="$(_session_record "$1" 2>/dev/null | cut -f4)"
  case "$gen" in ''|*[!0-9]*) gen=1 ;; esac
  printf '%s' "$gen"
}

# Read a session's latest start record: "provider<TAB>model<TAB>effort<TAB>generation<TAB>perm_profile".
# Field 5 (perm_profile) is "default" for records written before L5 or without --perm.
_session_record() { # <session-id>
  _state_jsonl_read "$OSRC_SESSION_REGISTRY" 2>/dev/null | jq -r --arg id "$1" \
    'select(.event=="start" and .session_id==$id) | [.provider, .model, .effort, (.model_generation|tostring), (.perm_profile // "default")] | @tsv' | tail -1
}

# Validate session name before any path construction, tmux, or rm use.
# Reject empty, '.', '..', and any name containing a character outside [A-Za-z0-9._-].
_validate_session_name() {
  case "$SESSION_NAME" in
    ''|.|..|*[!A-Za-z0-9._-]*)
      die "invalid session name '$SESSION_NAME' (OUTSOURCERER_TMUX must be non-empty, not '.' or '..', and match ^[A-Za-z0-9._-]+$)"
      ;;
  esac
}
