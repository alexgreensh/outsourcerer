# shellcheck shell=bash
# lib/supervise_watch.sh: hand-in files for supervise (done / question / verdict).
#
#   outsourcerer.sh supervise --watch <dir|file> [...]    register, then block as usual
#   outsourcerer.sh supervise --unwatch <dir|file>         stop watching
#
# Lanes hand work in by writing files: out/L1.DONE, reviews/L1-VERDICT.md, out/L1.QUESTION. A lane
# that re-hands in REWRITES the same file, so detection that diffs file names never sees it (three
# hand-ins sat unseen 1.5-2.5 h on 2026-11-13). Every hand-in event is therefore keyed on the file's
# fingerprint, name + mtime + size + content hash: touching an empty DONE again fires, a rewrite
# with a new sha fires, an untouched file never fires twice.
#
# A watch is an ordinary owned target (id `watch.<cksum of the path>`, path in
# $OSRC_HOME/watch/<id>.path) in the owner registry, so the beacon logs its events while no
# supervise runs and the stop guard treats it as live work owed a waiter until --unwatch.
# Registering baselines the files already there (the orchestrator has seen them); re-registering
# never re-baselines, or a rewrite between two supervise runs would be swallowed.
# Each file is its own event target (its basename), so two hand-ins in one batch are two pairs.
#
# Names are lane-written input (review r4: `x';touch${IFS}PWNED;'.DONE` became a shell command in
# NEXT). A hand-in file's basename must match ^[A-Za-z0-9][A-Za-z0-9._-]*$; anything else is skipped
# with ONE notice per name. A symlink in a watched folder is skipped the same way (r5: a lane could
# point LINK.DONE at any file the orchestrator can read). A --watch path is the orchestrator's own
# input and may hold spaces (~/Library/Mobile Documents/...); only control characters are refused.
# NEXT lines quote every path with printf %q, so a NEXT is always one plain `cat <file>`.

# name:mtime:size:cksum of a file, or empty when it is missing.
_sv_fp() { # <path>
  [ -f "$1" ] || return 0
  local m s c
  m="$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null)"
  read -r c s _ < <(cksum < "$1" 2>/dev/null)
  printf '%s:%s:%s:%s' "$(basename "$1")" "${m:-0}" "${s:-0}" "${c:-0}"
}

# Hand-in kind of a file name: done | question | verdict | empty (not a hand-in).
_sv_handin_kind() { # <basename>
  local u; u="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  case "$u" in
    *QUESTION*) printf question ;;
    *VERDICT*) printf verdict ;;
    *.DONE|*-DONE|DONE) printf done ;;
  esac
}

_sv_handin_name_ok() { # <basename>
  case "${1:-}" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}
_sv_watch_path_ok() { # <absolute path>: no control characters (a newline would split the .path file)
  case "${1:-}" in /*) ;; *) return 1 ;; esac
  case "$1" in *[[:cntrl:]]*) return 1 ;; esac
  return 0
}

# One stderr notice per unusual name per watch; the name is shown with its unusual characters removed.
_sv_handin_ignored() { # <watch-id> <path> [what]
  local f k; f="$(_sv_lanes)/state/$1.ignored"; k="$(printf '%s' "$2" | cksum | awk '{print $1}')"
  grep -qx "$k" "$f" 2>/dev/null && return 0
  mkdir -p "$(_sv_lanes)/state" 2>/dev/null; printf '%s\n' "$k" >> "$f"
  if [ "${3:-}" = symlink ]; then
    printf '[outsourcerer] supervise: ignored hand-in symlink in %s: %s (a hand-in must be a regular file)\n' \
      "$(dirname "$2")" "$(basename "$2" | tr -cd 'A-Za-z0-9._-')" >&2
  else
    printf '[outsourcerer] supervise: ignored hand-in file with an unusual name in %s: %s (allowed: letters, digits, . _ -, starting with a letter or digit)\n' \
      "$(dirname "$2")" "$(basename "$2" | tr -cd 'A-Za-z0-9._-')" >&2
  fi
}

_sv_watch_id() { printf 'watch.%s' "$(printf '%s' "$1" | cksum | awk '{print $1}')"; }
_sv_watch_path() { cat "$OSRC_HOME/watch/$1.path" 2>/dev/null; }

# Files a watch covers: a watched file itself, or the hand-in files directly inside a watched dir.
# A name failing the rule is reported once (with [watch-id]) and never becomes an event.
_sv_watch_files() { # <path> [watch-id]
  local f
  if [ -f "$1" ]; then _sv_watch_one "$1" "${2:-}" any; return 0; fi
  [ -d "$1" ] || return 0
  for f in "$1"/*; do [ -f "$f" ] && _sv_watch_one "$f" "${2:-}"; done
  return 0
}
_sv_watch_one() { # <file> <watch-id> [any: a watched file needs no hand-in name]
  local b; b="$(basename "$1")"
  [ -n "${3:-}" ] || [ -n "$(_sv_handin_kind "$b")" ] || return 0
  if [ -z "${3:-}" ] && [ -L "$1" ]; then [ -z "$2" ] || _sv_handin_ignored "$2" "$1" symlink; return 0; fi
  if _sv_handin_name_ok "$b"; then printf '%s\n' "$1"
  elif [ -n "$2" ]; then _sv_handin_ignored "$2" "$1"; fi
  return 0
}

_sv_wstate() { printf '%s/state/%s.%s' "$(_sv_lanes)" "$1" "$(basename "$2" | tr -cd 'A-Za-z0-9._-')"; }

# Register <path> (absolute), baseline it once; prints the watch id.
_sv_watch_add() { # <path>
  local p id f d
  p="$(cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$1")")" || return 1
  [ -e "$p" ] || return 1
  _sv_watch_path_ok "$p" || return 2
  id="$(_sv_watch_id "$p")"
  mkdir -p "$OSRC_HOME/watch" "$(_sv_lanes)/state" 2>/dev/null || return 1
  if [ ! -f "$OSRC_HOME/watch/$id.path" ]; then
    printf '%s\n' "$p" > "$OSRC_HOME/watch/$id.path"
    _sv_watch_files "$p" | while IFS= read -r f; do
      d="$(_sv_wstate "$id" "$f")"; _sv_fp "$f" > "$d"
    done
  fi
  printf '%s' "$id"
}

_sv_watch_rm() { # <path> [sid]
  local p id
  p="$(cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$1")")" || p="$1"
  id="$(_sv_watch_id "$p")"
  rm -f "$OSRC_HOME/watch/$id.path" "$(_sv_lanes)/state/$id".* 2>/dev/null
  [ -n "${2:-}" ] && rm -f "$OSRC_HOME/owners/$2/$id" 2>/dev/null
  printf '%s' "$id"
}

# Observe one watch: log an event per hand-in file whose fingerprint changed. Sets SV_OUT=1 (a
# watch is owed a waiter) and SV_WT (the file targets, for supervise's replay filter).
_sv_observe_watch() { # <id> <src> <owner>
  local id="$1" p f fp st kind k d nx rep
  SV_OUT=1; SV_WT=""
  p="$(_sv_watch_path "$id")"
  [ -n "$p" ] || { SV_DROP=1; return 0; }   # unwatched: the owner record goes
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    SV_WT="$SV_WT $(basename "$f")"
    fp="$(_sv_fp "$f")"; st="$(_sv_wstate "$id" "$f")"
    [ "$fp" = "$(cat "$st" 2>/dev/null)" ] && continue
    kind="$(_sv_handin_kind "$(basename "$f")")"
    case "$kind" in
      question) k=question; d="hand-in question $(basename "$f")"; nx="cat $(printf '%q' "$f")" ;;
      verdict) k=done; d="review verdict $(basename "$f")"; nx="cat $(printf '%q' "$f")" ;;
      *) k=done; d="hand-in $(basename "$f")"; rep="$(dirname "$f")/$(basename "$f" | sed -E 's/\.?DONE$//')-REPORT.md"
         if [ -f "$rep" ]; then nx="cat $(printf '%q' "$rep")"; else nx="cat $(printf '%q' "$f")"; fi ;;
    esac
    [ -s "$st" ] && d="$d rewritten (re-hand-in)" || d="$d written"
    d="$d; fp ${fp#*:}"
    _sv_append "$k" "$(basename "$f")" "$d" "$nx" "$2" "$3" && printf '%s\n' "$fp" > "$st"
  done < <(_sv_watch_files "$p" "$id")
  return 0
}

# A lane's done contract fingerprint (L6: $OSRC_HOME/done/<id>.json), so a re-hand-in is a new
# `done` even when the screen did not change: file: -> the file's fingerprint, branch: -> the tip
# sha. Empty for check:/pr: or no contract (the screen hash keys the event then).
_sv_done_fp() { # <id>
  local j spec cwd p
  j="$OSRC_HOME/done/$1.json"; [ -f "$j" ] || return 0
  spec="$(jq -r '.spec // ""' "$j" 2>/dev/null)"; cwd="$(jq -r '.cwd // ""' "$j" 2>/dev/null)"
  case "$spec" in
    file:*) p="${spec#file:}"; case "$p" in /*) ;; *) p="${cwd:-.}/$p" ;; esac; _sv_fp "$p" ;;
    branch:*) p="${spec#branch:}"; git -C "${cwd:-.}" rev-parse -q --verify "${p%@*}^{commit}" 2>/dev/null ;;
  esac
}
