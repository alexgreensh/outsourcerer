# shellcheck shell=bash
# lib/lease.sh — file leases: a lane claims a path in a shared repo for a while, so two lanes do not
# edit the same files at once. Sourced by outsourcerer.sh through the lib/*.sh loader; functions only.
#
#   outsourcerer lease claim <path|glob> [--ttl MIN] [--repo DIR]   claim for MIN minutes (default 15)
#   outsourcerer lease release <path|glob>|--all [--repo DIR]      drop your own lease(s)
#   outsourcerer lease list [--all] [--repo DIR]                   live leases in this repo (or every repo)
#
# One ledger, $OSRC_HOME/leases.json (a JSON array), written only under the existing state lock
# (_state_lock_acquire: flock, or the atomic mkdir claim with dead-holder recovery), so there is no
# second locking system. A lease is {repo, path, holder, ttl, until, ts}:
#   repo    the git common dir of the checkout (so every worktree of one repo shares its leases),
#           or the physical directory outside git;
#   path    relative to the worktree top; a shell glob is allowed (`*` also crosses `/`);
#   holder  the caller's lane id, resolved like `lane msg` does (process ancestry, job dir, Claude
#           session), never from a flag. Factory/plan code calls _osrc_lease_claim with a task id.
# A claim that overlaps a live lease of another holder is refused, naming the holder and the expiry.
# Overlap is conservative: equal paths, one inside the other's directory, a glob matching the other
# path, or two globs whose literal heads nest (src/*.ts and src/*.md count as overlapping).
# The heartbeat beacon renews every lease whose holder is still alive (tmux session or job pid); a
# dead holder's lease simply runs out. Leases are advisory coordination, not a permission system.

_osrc_lease_file() { printf '%s/leases.json' "$OSRC_HOME"; }

# _osrc_lease_repo [dir] -> the repo key for <dir> (default: the current directory).
_osrc_lease_repo() {
  local d="${1:-.}" c
  [ -d "$d" ] || return 1
  c="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || c=""
  if [ -n "$c" ]; then
    case "$c" in /*|?:/*) ;; *) c="$(cd "$d" && cd "$c" && pwd -P)" || return 1 ;; esac
    printf '%s\n' "$c"; return 0
  fi
  (cd "$d" && pwd -P)
}

# _osrc_lease_norm <path> [dir] -> path relative to the worktree top of <dir>; rc 1 for a path
# that leaves the worktree or is empty.
_osrc_lease_norm() {
  local p="$1" d="${2:-.}" top
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || top="$(cd "$d" && pwd -P)"
  case "$p" in
    /*) case "$p" in "$top"/*) p="${p#"$top"/}" ;; *) return 1 ;; esac ;;
    *) local pre; pre="$(git -C "$d" rev-parse --show-prefix 2>/dev/null)"; p="$pre$p" ;;
  esac
  while :; do case "$p" in ./*) p="${p#./}" ;; */) p="${p%/}" ;; *) break ;; esac; done
  case "/$p/" in *"/../"*|*"/./"*|//) return 1 ;; esac
  printf '%s\n' "$p"
}

# _osrc_lease_overlap <a> <b> -> 0 when the two paths/globs can name the same file.
_osrc_lease_overlap() {
  local a="$1" b="$2" ha hb
  [ "$a" = "$b" ] && return 0
  # shellcheck disable=SC2254  # unquoted on purpose: each side is matched as a pattern
  case "$b" in $a|$a/*) return 0 ;; esac
  # shellcheck disable=SC2254
  case "$a" in $b|$b/*) return 0 ;; esac
  case "$a" in *[\*\?\[]*) ;; *) return 1 ;; esac
  case "$b" in *[\*\?\[]*) ;; *) return 1 ;; esac
  ha="${a%%[\*\?\[]*}"; hb="${b%%[\*\?\[]*}"
  case "$ha" in "$hb"*) return 0 ;; esac
  case "$hb" in "$ha"*) return 0 ;; esac
  return 1
}

# Read the ledger with expired leases dropped (an unreadable ledger reads as empty: fail open on
# coordination, never wedge a lane).
_osrc_lease_live() { # <now>
  local f; f="$(_osrc_lease_file)"
  [ -f "$f" ] && [ ! -L "$f" ] || { printf '[]'; return 0; }
  jq -c --argjson now "$1" '[ .[]? | select((.until // 0) > $now) ]' "$f" 2>/dev/null || printf '[]'
}

_osrc_lease_write() { # <json-array>; caller holds the lock
  local f tmp; f="$(_osrc_lease_file)"; tmp="$f.tmp.$$"
  [ ! -L "$f" ] || return 1
  ( umask 077; printf '%s\n' "$1" > "$tmp" ) 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null; return 1
}

_osrc_lease_lock() {
  _mkdir_private "$OSRC_HOME" || return 1
  _state_lock_acquire "$(_osrc_lease_file)" && return 0
  printf 'lease: the lease ledger %s is busy; try again\n' "$(_osrc_lease_file)" >&2
  return 1
}

# _osrc_lease_claim <holder> <repo> <path> [ttl-secs] -> rc 0 claimed (or renewed: same holder,
# same path), rc 3 refused (a line per conflicting lease on stderr), rc 1 ledger trouble.
_osrc_lease_claim() {
  local holder="$1" repo="$2" path="$3" ttl="${4:-}" now leases conflicts rc=0 p h u
  case "$ttl" in ''|*[!0-9]*|0) ttl=$(( ${OSRC_LEASE_TTL_MIN:-15} * 60 )) ;; esac
  [ -n "$holder" ] && [ -n "$repo" ] && [ -n "$path" ] || return 1
  _osrc_lease_lock || return 1
  now="$(date +%s)"; leases="$(_osrc_lease_live "$now")"
  conflicts=""
  while IFS="$(printf '\t')" read -r p h u; do
    [ -n "$p" ] || continue
    _osrc_lease_overlap "$path" "$p" || continue
    conflicts="${conflicts}lease: $path is held by $h as '$p' until $(_osrc_lease_when "$u")
"
  done <<EOF
$(printf '%s' "$leases" | jq -r --arg r "$repo" --arg h "$holder" '.[] | select(.repo==$r and .holder!=$h) | [.path,.holder,(.until|tostring)] | @tsv')
EOF
  if [ -n "$conflicts" ]; then
    printf '%s' "$conflicts" >&2; rc=3
  else
    leases="$(printf '%s' "$leases" | jq -c --arg r "$repo" --arg p "$path" --arg h "$holder" --argjson ttl "$ttl" --argjson now "$now" \
      '[ .[] | select(.repo!=$r or .path!=$p or .holder!=$h) ] + [{repo:$r,path:$p,holder:$h,ttl:$ttl,until:($now+$ttl),ts:$now}]')" \
      && _osrc_lease_write "$leases" || rc=1
  fi
  _state_lock_release "$(_osrc_lease_file)"
  return "$rc"
}

# _osrc_lease_release <holder> <repo> <path|--all> -> rc 0 when something was released.
_osrc_lease_release() {
  local holder="$1" repo="$2" path="$3" now leases before after rc=0
  _osrc_lease_lock || return 1
  now="$(date +%s)"; leases="$(_osrc_lease_live "$now")"
  before="$(printf '%s' "$leases" | jq 'length')"
  leases="$(printf '%s' "$leases" | jq -c --arg r "$repo" --arg p "$path" --arg h "$holder" \
    '[ .[] | select((.holder==$h and .repo==$r and ($p=="--all" or .path==$p)) | not) ]')" || leases=""
  after="$(printf '%s' "$leases" | jq 'length' 2>/dev/null)"
  if [ -z "$leases" ] || ! _osrc_lease_write "$leases"; then rc=1
  elif [ "$before" = "$after" ]; then rc=1; fi
  _state_lock_release "$(_osrc_lease_file)"
  return "$rc"
}

# _osrc_lease_holder_alive <holder> -> 0 for a live tmux session or a job whose pid runs.
_osrc_lease_holder_alive() {
  local id="$1" pf pid
  have tmux 2>/dev/null && tmux has-session -t "=$id" 2>/dev/null && return 0
  for pf in "$OSRC_JOBS/$id/pid" "$OSRC_JOBS/$id/supervisor_pid"; do
    [ -f "$pf" ] || continue
    pid="$(tr -d '[:space:]' < "$pf" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null && return 0
  done
  return 1
}

# _osrc_lease_renew_live -> the heartbeat hook: push out the expiry of every lease whose holder is
# alive, and drop the expired ones. Best-effort; never fails the beat.
_osrc_lease_renew_live() {
  local f now leases alive="" h
  f="$(_osrc_lease_file)"; [ -f "$f" ] || return 0
  now="$(date +%s)"; leases="$(_osrc_lease_live "$now")"
  for h in $(printf '%s' "$leases" | jq -r '.[].holder' | sort -u); do
    _osrc_lease_holder_alive "$h" && alive="$alive$h
"
  done
  _state_lock_acquire "$f" || return 0
  leases="$(_osrc_lease_live "$now" | jq -c --arg alive "$alive" --argjson now "$now" \
    '($alive | split("\n")) as $a | [ .[] | if (.holder as $h | any($a[]; . == $h)) then .until = ($now + .ttl) else . end ]')" \
    && _osrc_lease_write "$leases"
  _state_lock_release "$f"
  return 0
}

_osrc_lease_when() { # <epoch> -> local time, portable (GNU date -d, BSD date -r)
  date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'epoch %s' "$1"
}

osrc_lease() { # claim|release|list ...
  local sub="${1:-}" path="" ttl="" repo_dir="." all=0 repo holder rc
  [ "$#" -gt 0 ] && shift
  have jq || die "lease needs jq"
  while [ "$#" -gt 0 ]; do case "$1" in
    --ttl) ttl="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --repo) repo_dir="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --all) all=1; shift ;;
    -*) die "lease: unknown flag '$1'" ;;
    *) [ -z "$path" ] || die "lease: one path per call"; path="$1"; shift ;;
  esac; done
  repo="$(_osrc_lease_repo "$repo_dir")" || die "lease: no such directory '$repo_dir'"
  case "$sub" in
    list|ls)
      _osrc_lease_live "$(date +%s)" | jq -r --arg r "$repo" --argjson all "$all" \
        '.[] | select($all==1 or .repo==$r) | [.holder, .path, (.until|tostring), .repo] | @tsv' \
        | while IFS="$(printf '\t')" read -r h p u r; do
            printf '%-24s %-40s until %s%s\n' "$h" "$p" "$(_osrc_lease_when "$u")" "$([ "$all" = 1 ] && printf '  (%s)' "$r")"
          done
      return 0 ;;
    claim|release) ;;
    *) die "usage: lease claim <path|glob> [--ttl MIN] [--repo DIR] | lease release <path|glob>|--all [--repo DIR] | lease list [--all] [--repo DIR]" ;;
  esac
  _osrc_lane_self || die "lease: cannot determine your lane id (no registered tmux session, job dir, or Claude session)"
  holder="$_OL_SELF"
  if [ "$sub" = release ] && [ "$all" = 1 ]; then path="--all"
  else
    [ -n "$path" ] || die "lease $sub needs a path"
    path="$(_osrc_lease_norm "$path" "$repo_dir")" || die "lease: the path must stay inside the repo"
  fi
  case "$ttl" in '') ;; *[!0-9]*|0) die "lease: --ttl takes whole minutes" ;; *) ttl=$((ttl * 60)) ;; esac
  if [ "$sub" = claim ]; then
    _osrc_lease_claim "$holder" "$repo" "$path" "$ttl"; rc=$?
    [ "$rc" -eq 0 ] && printf 'lease: %s holds %s\n' "$holder" "$path"
    return "$rc"
  fi
  _osrc_lease_release "$holder" "$repo" "$path" && { printf 'lease: %s released %s\n' "$holder" "$path"; return 0; }
  printf 'lease: %s holds no lease on %s here\n' "$holder" "$path" >&2; return 1
}
