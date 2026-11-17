# lib/done.sh — the "done" contract for session lanes.
#
# An idle delegate can be finished OR stuck halfway; the screen cannot tell them apart, so a lane
# needs a machine-checkable definition of done. `session start --done-when <spec>` records the
# contract at $OSRC_HOME/done/<session>.json ({"spec","cwd"}) and `osrc_done_state` answers one of:
#   done | not-done | no-contract | error <reason>
# Specs:
#   file:<path>              the file exists (absolute, or relative to the contract cwd)
#   branch:<b>@<marker>      tip commit SUBJECT of local branch <b> has <marker> as a whole word
#                            at the start or end ("NOT <marker>" never counts); cached n/a
#   check:<shell-command>    exits 0 within 300 s from the contract cwd, run ONCE per lane in the
#                            background behind a lock; callers never block — they get the last
#                            cached verdict or not-done; settled verdicts cached 60 s
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
    # Lane start: pin its base sha now (lib/proof.sh), before the lane commits on top of it.
    # A lane start is a new session: any older pin under this name is ended first (kept only when this
    # checkout continues that lane), so a reused name never inherits a stale pin.
    ! type osrc_proof_lane_ended >/dev/null 2>&1 || osrc_proof_lane_ended "$name"
    ! type osrc_proof_pin_base >/dev/null 2>&1 || osrc_proof_pin_base "$name" "$cwd" HEAD start >/dev/null 2>&1 || true
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

# osrc_done_clear <name> -> drop the contract, its check cache and any check lock (session stop /
# clean restart). A running background probe is left to finish; its spec-guard keeps its verdict
# out of a replacement contract's cache.
osrc_done_clear() {
  local name="${1:-}" dir lock
  _osrc_done_name_ok "$name" || return 0
  dir="$(_osrc_done_dir)"
  lock="$dir/$name.checklock"
  if [ -d "$dir" ]; then
    _osrc_guarded_mutex_acquire "$lock" || return 1
    rm -rf "$lock" "$lock.stale."* 2>/dev/null
    _osrc_guarded_mutex_release "$lock" || return 1
  fi
  rm -f "$dir/$name.json" "$dir/$name.checkcache" "$dir/$name.json.tmp."* 2>/dev/null
  ! type osrc_proof_lane_ended >/dev/null 2>&1 || osrc_proof_lane_ended "$name"   # lib/proof.sh: this session's pin is no longer live
  return 0
}

# Marker hit rule for branch:<b>@<marker>: the marker must be a WHOLE WORD at the start or end of
# the commit SUBJECT line (%s), and a marker negated by "not" ("NOT READY", "still not READY")
# never counts — a false done is the one thing a done contract must not produce. Whole-word means
# bounded by non-[A-Za-z0-9_] (so ALREADY does not contain READY); start/end means mid-subject
# mentions ("wip: NOT READY, tests red") do not count either.
_osrc_done_marker_hit() { # <subject> <marker> -> rc0 on a qualifying hit
  local subj="$1" marker="$2" rest pre pt
  [ -n "$subj" ] && [ -n "$marker" ] || return 1
  # start-anchored: marker at position 0 followed by a boundary char or EOL
  case "$subj" in
    "$marker"*)
      rest="${subj#"$marker"}"
      case "$rest" in ''|[!A-Za-z0-9_]*) return 0 ;; esac ;;
  esac
  # end-anchored: marker at EOL preceded by a boundary char or BOL, and not negated by "not"
  case "$subj" in
    *"$marker")
      pre="${subj%"$marker"}"
      case "$pre" in ''|*[!A-Za-z0-9_]) ;; *) return 1 ;; esac
      pt="${pre%"${pre##*[![:space:]]}"}"   # rstrip whitespace
      printf '%s' "$pt" | grep -qiE '(^|[^a-z0-9_])not$' && return 1
      return 0 ;;
  esac
  return 1
}

# branch:<branch>@<marker> evaluator. Prints one state word.
_osrc_done_branch() { # <cwd> <branch>@<marker>
  local cwd="$1" rest="$2" branch marker subj
  case "$rest" in *@?*) ;; *) echo "error bad-spec"; return 0 ;; esac
  branch="${rest%@*}"; marker="${rest##*@}"
  { [ -n "$branch" ] && [ -n "$marker" ]; } || { echo "error bad-spec"; return 0; }
  case "$branch" in *[[:space:]]*|-*) echo "error bad-spec"; return 0 ;; esac
  [ -d "$cwd" ] || { echo "error cwd-missing"; return 0; }
  git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || { echo "error not-a-repo"; return 0; }
  # A branch that does not exist is simply not-done, not an error.
  git -C "$cwd" rev-parse --verify --quiet "refs/heads/$branch^{commit}" >/dev/null 2>&1 \
    || { echo not-done; return 0; }
  subj="$(git -C "$cwd" log -1 --format=%s "refs/heads/$branch" 2>/dev/null)" \
    || { echo "error git-log"; return 0; }
  _osrc_done_marker_hit "$subj" "$marker" && echo done || echo not-done
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

# Last cached verdict at ANY age ("" + rc1 when none). Used while a check: run is in flight:
# the caller answers from the last known verdict instead of blocking on the probe.
_osrc_done_cache_peek() { # <name>
  local name="$1" cts cstate cache
  cache="$(_osrc_done_dir)/$name.checkcache"
  [ -f "$cache" ] || return 1
  cts=""; cstate=""
  read -r cts cstate < "$cache" 2>/dev/null || return 1
  case "$cts" in ''|*[!0-9]*) return 1 ;; esac
  case "$cstate" in done|not-done) ;; *) return 1 ;; esac
  printf '%s\n' "$cstate"
}

# check:<cmd> runs ONCE per lane at a time, in the background, behind a mkdir lock — a poll
# loop must never block on a 300 s probe (one slow `npm test` would stall observation of every
# other lane). Whoever wins the lock spawns the runner and returns immediately; every caller,
# winner included, answers with the last cached verdict or not-done. done requires exit 0 inside
# the bound (default 300 s, OSRC_DONE_CHECK_SECS); a timeout or any nonzero exit is not-done.
_osrc_done_check_run() { # <name> <cwd> <cmd> <spec> — background body: run, cache, release
  local name="$1" cwd="$2" cmd="$3" spec="$4" rc state cur f
  f="$(_osrc_done_dir)/$name.json"
  if type _timeout >/dev/null 2>&1; then
    _timeout "${OSRC_DONE_CHECK_SECS:-300}" bash -c 'cd "$1" && eval "$2"' _ "$cwd" "$cmd" </dev/null >/dev/null 2>&1
  else
    ( cd "$cwd" && eval "$cmd" ) </dev/null >/dev/null 2>&1
  fi
  rc=$?
  [ "$rc" -eq 0 ] && state=done || state=not-done
  # A contract replaced while the probe ran must not inherit this verdict.
  cur="$(jq -r '.spec // empty' "$f" 2>/dev/null)"
  [ "$cur" = "$spec" ] && _osrc_done_cache_write "$name" "$state"
}

# Try to take $OSRC_HOME/done/<name>.checklock. rc0 = this caller holds it. A lock whose epoch is
# missing or older than the check bound + 60 s is dead (runner killed/rebooted) and is broken by
# atomic rename — only one breaker can win the mv, so two pollers cannot both retake it.
_osrc_done_check_lock_inner() { # <name>, caller owns recovery mutex
  local name="$1" dir lock now le stale_dir age
  dir="$(_osrc_done_dir)"; lock="$dir/$name.checklock"; now="$(date +%s)"
  if _osrc_atomic_mkdir "$lock"; then return 0; fi
  le=""; read -r le < "$lock/epoch" 2>/dev/null || le=""
  case "$le" in ''|*[!0-9]*)
    age="$(_mtime "$lock" 2>/dev/null || echo 0)"
    case "$age" in ''|*[!0-9]*) return 1 ;; esac
    [ "$age" -gt 0 ] && [ $((now - age)) -gt $(( ${OSRC_DONE_CHECK_SECS:-300} + 60 )) ] || return 1
    stale_dir=1 ;;
  *)
    [ $((now - le)) -gt $(( ${OSRC_DONE_CHECK_SECS:-300} + 60 )) ] && stale_dir=1 || stale_dir=0 ;;
  esac
  [ "$stale_dir" = 1 ] || return 1
  stale_dir="$lock.stale.$$.$RANDOM"
  mv "$lock" "$stale_dir" 2>/dev/null || return 1
  rm -rf "$stale_dir" 2>/dev/null
  _osrc_atomic_mkdir "$lock"
}

_osrc_done_check_lock() {
  local name="$1" lock rc=0 token
  _OSRC_DONE_CLAIM_TOKEN=""
  lock="$(_osrc_done_dir)/$name.checklock"
  _osrc_guarded_mutex_acquire "$lock" || return 1
  _osrc_done_check_lock_inner "$name" || rc=$?
  if [ "$rc" = 0 ]; then
    token="${BASHPID:-$$}.$RANDOM.$RANDOM"
    if ! { printf '%s\n' "$token" > "$lock/owner" && date +%s > "$lock/epoch"; } 2>/dev/null; then
      rm -f "$lock/owner" "$lock/epoch" 2>/dev/null
      rmdir "$lock" 2>/dev/null || true
      rc=1
    else
      _OSRC_DONE_CLAIM_TOKEN="$token"
    fi
  fi
  _osrc_guarded_mutex_release "$lock" || return 1
  return "$rc"
}

_osrc_done_check_spawn() { # <name> <cwd> <cmd> <spec> — caller holds <name>.checklock
  local name="$1" cwd="$2" cmd="$3" spec="$4" lock token current
  lock="$(_osrc_done_dir)/$name.checklock"
  token="${_OSRC_DONE_CLAIM_TOKEN:-}"; [ -n "$token" ] || return 1
  _osrc_guarded_mutex_acquire "$lock" || return 1
  current="$(cat "$lock/owner" 2>/dev/null)"
  if [ "$current" != "$token" ]; then _osrc_guarded_mutex_release "$lock"; return 1; fi
  ( _osrc_done_check_run "$name" "$cwd" "$cmd" "$spec"
    if _osrc_guarded_mutex_acquire "$lock"; then
      current="$(cat "$lock/owner" 2>/dev/null)"
      if [ "$current" = "$token" ]; then
        rm -f "$lock/epoch" "$lock/owner" 2>/dev/null
        rmdir "$lock" 2>/dev/null || true
      fi
      _osrc_guarded_mutex_release "$lock" || true
    fi ) >/dev/null 2>&1 </dev/null &
  _osrc_guarded_mutex_release "$lock"
}

_osrc_done_check() { # <name> <cwd> <cmd> <spec>
  local name="$1" cwd="$2" cmd="$3" spec="$4" cached last _OSRC_DONE_CLAIM_TOKEN=""
  [ -n "${cmd//[[:space:]]/}" ] || { echo "error bad-spec"; return 0; }
  [ -d "$cwd" ] || { echo "error cwd-missing"; return 0; }
  cached="$(_osrc_done_cache_read "$name")" && { echo "$cached"; return 0; }
  last="$(_osrc_done_cache_peek "$name")"
  _osrc_done_check_lock "$name" && _osrc_done_check_spawn "$name" "$cwd" "$cmd" "$spec"
  echo "${last:-not-done}"
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
    check:*)  _osrc_done_check "$name" "$cwd" "${spec#check:}" "$spec" ;;
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
