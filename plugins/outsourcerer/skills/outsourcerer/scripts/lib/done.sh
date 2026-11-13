# lib/done.sh — the "done" contract for session lanes.
#
# An idle delegate can be finished OR stuck halfway; the screen cannot tell them apart, so a lane
# needs a machine-checkable definition of done. `session start --done-when <spec>` records the
# contract at $OSRC_HOME/done/<session>.json ({"spec","cwd"}) and `osrc_done_state` answers one of:
#   done | not-done | no-contract | error <reason>
# Specs:
#   file:<path>              the file exists (absolute, or relative to the contract cwd)
#   branch:<b>@<marker>      the tip commit of local branch <b> contains <marker> (e.g. @READY)
#   check:<shell-command>    exits 0 within 300 s, run from the contract cwd; result cached 60 s
#   pr:<owner/repo>#<n>      `gh pr view <n> -R <repo> --json state` reports MERGED; a missing gh
#                            or a failed call is `error`, never silently not-done; cached 60 s
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

# pr:<owner/repo>#<n> well-formedness, shared by osrc_done_validate and the state evaluator (a
# hand-edited contract bypasses osrc_done_set). Exactly one '#', owner/repo non-empty around a
# single '/', <n> all digits.
_osrc_done_pr_spec_ok() { # <owner/repo>#<n>
  local rest="$1" repo num
  repo="${rest%%#*}"; num="${rest##*#}"
  [ "$rest" = "$repo#$num" ] || return 1
  case "$repo" in
    */*) ;;
    *) return 1 ;;
  esac
  case "$repo" in
    ''|*/*/*|'/'*|*/|*[[:space:]]*) return 1 ;;
  esac
  case "$num" in
    ''|*[!0-9]*) return 1 ;;
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
    pr:*)
      _osrc_done_pr_spec_ok "${spec#pr:}" || { echo "pr: needs <owner/repo>#<n>" >&2; return 1; } ;;
    *)
      echo "spec must start with file: | branch: | check: | pr:" >&2; return 1 ;;
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
    # A new spec must not inherit the previous contract's cached verdict.
    rm -f "$dir/$name.checkcache" 2>/dev/null
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

# 60 s per-session result cache shared by the check: and pr: evaluators, so a poll loop does not
# rerun the probe every tick. Only settled verdicts (done|not-done) are cached; errors always
# re-evaluate so a broken contract or missing tool surfaces on the next poll, not 60 s later.
_osrc_done_cache_read() { # <name> -> fresh cached verdict on stdout, rc 1 when absent/stale
  local name="$1" now cts cstate cache
  cache="$(_osrc_done_dir)/$name.checkcache"
  [ -f "$cache" ] || return 1
  now="$(date +%s)"
  cts=""; cstate=""
  read -r cts cstate < "$cache" 2>/dev/null || return 1
  case "$cts" in ''|*[!0-9]*) return 1 ;; esac
  case "$cstate" in done|not-done) ;; *) return 1 ;; esac
  [ $((now - cts)) -lt "${OSRC_DONE_CACHE_SECS:-60}" ] || return 1
  printf '%s\n' "$cstate"
}

_osrc_done_cache_write() { # <name> <done|not-done>
  local name="$1" state="$2" cache
  cache="$(_osrc_done_dir)/$name.checkcache"
  printf '%s %s\n' "$(date +%s)" "$state" > "$cache.tmp.$$" 2>/dev/null \
    && mv "$cache.tmp.$$" "$cache" 2>/dev/null
  rm -f "$cache.tmp.$$" 2>/dev/null
}

# check:<cmd> evaluator. done requires exit 0 inside the bound (default 300 s,
# OSRC_DONE_CHECK_SECS); a timeout or any nonzero exit is not-done — the contract is "exits 0",
# nothing softer.
_osrc_done_check() { # <name> <cwd> <cmd>
  local name="$1" cwd="$2" cmd="$3" rc state cached
  [ -n "${cmd//[[:space:]]/}" ] || { echo "error bad-spec"; return 0; }
  [ -d "$cwd" ] || { echo "error cwd-missing"; return 0; }
  cached="$(_osrc_done_cache_read "$name")" && { echo "$cached"; return 0; }
  if type _timeout >/dev/null 2>&1; then
    _timeout "${OSRC_DONE_CHECK_SECS:-300}" bash -c 'cd "$1" && eval "$2"' _ "$cwd" "$cmd" >/dev/null 2>&1
  else
    ( cd "$cwd" && eval "$cmd" ) >/dev/null 2>&1
  fi
  rc=$?
  [ "$rc" -eq 0 ] && state=done || state=not-done
  _osrc_done_cache_write "$name" "$state"
  echo "$state"
}

# pr:<owner/repo>#<n> evaluator: done when `gh pr view` reports state MERGED (a merged PR is a
# finished lane even when the pane still looks blocked). gh missing or the call failing is an
# error, not not-done — "we could not check" must never read as "still working".
_osrc_done_pr() { # <name> <owner/repo>#<n>
  local name="$1" rest="$2" repo num cached out state rc
  _osrc_done_pr_spec_ok "$rest" || { echo "error bad-spec"; return 0; }
  repo="${rest%%#*}"; num="${rest##*#}"
  command -v gh >/dev/null 2>&1 || { echo "error gh-missing"; return 0; }
  cached="$(_osrc_done_cache_read "$name")" && { echo "$cached"; return 0; }
  # _timeout captures the child's stderr into the same file as stdout, so the gh call runs under
  # bash -c with its own 2>/dev/null — otherwise a gh warning would corrupt the JSON parse.
  if type _timeout >/dev/null 2>&1; then
    out="$(_timeout "${OSRC_DONE_CHECK_SECS:-300}" bash -c 'gh pr view "$1" -R "$2" --json state 2>/dev/null' _ "$num" "$repo")"; rc=$?
  else
    out="$(gh pr view "$num" -R "$repo" --json state 2>/dev/null)"; rc=$?
  fi
  [ "$rc" -eq 0 ] || { echo "error gh-failed"; return 0; }
  state="$(printf '%s' "$out" | jq -r '.state // empty' 2>/dev/null)"
  case "$state" in
    MERGED)      _osrc_done_cache_write "$name" done;      echo done ;;
    OPEN|CLOSED) _osrc_done_cache_write "$name" not-done; echo not-done ;;
    *)           echo "error gh-failed" ;;
  esac
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
    file:*|branch:*|check:*|pr:*) ;;
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
    pr:*)     _osrc_done_pr "$name" "${spec#pr:}" ;;
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
