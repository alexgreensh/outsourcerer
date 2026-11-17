# shellcheck shell=bash
# lib/supervise_dedupe.sh: one event per change, delivered once, to the newest waiter.
#
# Two supervise processes armed for the same orchestrator (a re-arm while an older background one
# still runs) used to both log the same idle (two rows, same second) and both deliver it, because
# each keeps its own in-memory cursor (2026-11-17 live log: osrc-auto-S2 at 1794879921, S2b at
# 1794888272). A missed wake is worse than a duplicate, so every guard here fails toward delivery.
#   1. Per-target lock around observe+emit: one process reads and logs a target at a time. A process
#      that finds it held skips the target for that poll (it stays pending). A lock older than
#      OSRC_SUPERVISE_LOCK_STALE seconds (default 120) is from a killed run and is broken.
#   2. Delivered ledger per orchestrator key ($OSRC_HOME/supervise/<sid or ids-hash>/delivered),
#      keyed on each row's own id: a row printed by one supervise is never printed by another.
#      Delivery is a claim under the ledger's lock. If that lock cannot be had, _sv_deliver says so
#      (rc 2) and the caller keeps its cursor and batch for the next poll: nothing is dropped. A
#      ledger lock older than OSRC_SUPERVISE_LEDGER_STALE seconds (default 30) is broken.
#   3. Newest waiter wins: each armed supervise takes an arm sequence number. A supervise that sees a
#      LIVE supervise armed after it for the same key prints one "superseded" line and exits without
#      delivering, so an event never goes to an older, unread waiter.
# Every lock this run holds is listed in _SV_HELD and released by the EXIT trap (TERM/INT/HUP exit
# through it), so a killed supervise leaves no lock behind for the next one to wait out.

_sv_held_add() { _SV_HELD="${_SV_HELD:-}$1
"; }
_sv_held_del() { _SV_HELD="$(printf '%s' "${_SV_HELD:-}" | grep -vxF -- "$1")
"; }
_sv_main_exit() {
  local l
  [ -z "${_SV_MAIN_DIR:-}" ] || rm -f -- "$_SV_MAIN_DIR/armed.$$" "$_SV_MAIN_DIR/armseq.$$" 2>/dev/null
  while IFS= read -r l; do [ -n "$l" ] && rmdir -- "$l" 2>/dev/null; done <<< "${_SV_HELD:-}"
  return 0
}

_sv_lock_dir() { printf '%s/state/%s.lock' "$(_sv_lanes)" "$1"; }

_sv_lock_try() { # <lock-dir> <stale-seconds> -> 0 when this process now holds it
  local l="$1" m
  mkdir "$l" 2>/dev/null && { _sv_held_add "$l"; return 0; }
  m="$(stat -c %Y "$l" 2>/dev/null || stat -f %m "$l" 2>/dev/null)"
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( $(_sv_now) - m )) -ge "$2" ] || return 1
  rmdir "$l" 2>/dev/null; mkdir "$l" 2>/dev/null && { _sv_held_add "$l"; return 0; }
  return 1
}
_sv_lock_rel() { rmdir "$1" 2>/dev/null; _sv_held_del "$1"; return 0; }

_sv_target_lock() { # <id>
  mkdir -p "$(_sv_lanes)/state" 2>/dev/null
  _sv_lock_try "$(_sv_lock_dir "$1")" "$(_sv_num "${OSRC_SUPERVISE_LOCK_STALE:-}" 120)"
}
_sv_target_unlock() { _sv_lock_rel "$(_sv_lock_dir "$1")"; }

# Observe and log one target under its lock. A held lock = another process is on it right now:
# report nothing for it this poll, but keep it pending and owed a waiter.
_sv_observe_emit() { # <id> <now> <src> [owner]
  local rc=0
  if _sv_target_lock "$1"; then
    _sv_observe "$1" "$2" "$3" "${4:-}"
    _sv_emit "$1" "$2" "$3" "${4:-}" || rc=$?
    _sv_target_unlock "$1"
    return "$rc"
  fi
  SV_K=""; SV_D=""; SV_OUT=1; SV_PEND=1; SV_DROP=0; SV_STOPPED=0; SV_WT=""
  return 0
}

# ---- newest waiter wins ------------------------------------------------------------------------
_sv_arm_seq() { # <dir>: give this supervise the next arm number for its key ($dir/armseq.<pid>)
  local d="$1" n i=0
  until _sv_lock_try "$d/armseq.lock" 30; do i=$((i + 1)); [ "$i" -lt 100 ] || return 1; sleep 0.1; done
  n=$(( $(_sv_num "$(cat "$d/armseq" 2>/dev/null)" 0) + 1 ))
  printf '%s\n' "$n" > "$d/armseq"; printf '%s\n' "$n" > "$d/armseq.$$"
  _sv_lock_rel "$d/armseq.lock"
}

_sv_superseded() { # <dir> -> pid of a live supervise armed after this one (rc 0), else rc 1
  local d="$1" mine f p n
  mine="$(_sv_num "$(cat "$d/armseq.$$" 2>/dev/null)" 0)"
  for f in "$d"/armseq.*; do
    p="${f##*.}"
    case "$p" in ''|*[!0-9]*|"$$") continue ;; esac
    n="$(_sv_num "$(cat "$f" 2>/dev/null)" 0)"
    [ "$n" -gt "$mine" ] || continue
    if kill -0 "$p" 2>/dev/null && ps -o command= -p "$p" 2>/dev/null | grep -q supervise; then printf '%s' "$p"; return 0; fi
    rm -f "$f" 2>/dev/null   # its supervise is gone
  done
  return 1
}

_sv_superseded_exit() { # <newer-pid>
  printf '[outsourcerer] supervise: superseded by a newer supervise for this session (pid %s); this one exits without delivering, the newer one reports.\n' "${1:-?}"
  exit 0
}

# ---- delivered ledger ("<ts>\t<row id>" lines) -------------------------------------------------
_sv_ledger_filter() { # <ledger> <rows>: drop rows (prio ts kind target detail next id) already delivered
  [ -n "$2" ] || return 0
  if [ -s "$1" ]; then
    printf '%s\n' "$2" | awk -F '\t' 'NR == FNR { seen[$2] = 1; next } NF && !($7 in seen)' "$1" -
  else printf '%s\n' "$2" | grep .; fi
}

_sv_ledger_add() { # <ledger> <rows>: record row ids, prune entries older than 24 h
  local f="$1" since; [ -n "$2" ] || return 0
  mkdir -p "${f%/*}" 2>/dev/null || return 1
  since=$(( $(_sv_now) - 86400 ))
  { [ -f "$f" ] && awk -F '\t' -v s="$since" '$1 >= s' "$f"
    printf '%s\n' "$2" | awk -F '\t' 'NF { print $2 FS $7 }'
  } | awk '!seen[$0]++' > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

# Deliver <rows> once: under the ledger's lock, drop what another supervise already printed, print
# $_SV_HEAD (if set) and the rest (batch = one EVENT/NEXT pair per target, highest priority then
# newest; all = every row), record them, release. With $_SV_DIR set, a newer live supervise for that
# key takes the delivery instead.
#   rc 0 printed | 1 nothing left to print (delivered elsewhere) | 2 ledger lock busy: printed
#   nothing, the caller must keep its cursor | 3 superseded: printed nothing
_sv_deliver() { # <ledger> <rows> <batch|all>
  local l="$1.lock" rows i=0 tab; tab="$(printf '\t')"
  mkdir -p "${1%/*}" 2>/dev/null
  until _sv_lock_try "$l" "$(_sv_num "${OSRC_SUPERVISE_LEDGER_STALE:-}" 30)"; do i=$((i + 1)); [ "$i" -lt 50 ] || return 2; sleep 0.1; done
  if [ -n "${_SV_DIR:-}" ] && _sv_superseded "$_SV_DIR" >/dev/null; then _sv_lock_rel "$l"; return 3; fi
  rows="$(_sv_ledger_filter "$1" "$2")"
  # batch: only a real (non-informational) row is worth a wake; `approved` rows ride along with one
  if [ -z "$rows" ] || { [ "$3" = batch ] && [ -z "$(printf '%s\n' "$rows" | awk -F '\t' 'NF && $3 != "approved"')" ]; }; then
    _sv_lock_rel "$l"; return 1
  fi
  if [ "$3" = batch ]; then rows="$(printf '%s\n' "$rows" | sort -t "$tab" -k1,1n -k2,2nr | awk -F '\t' '!seen[$4]++')"; fi
  [ -z "${_SV_HEAD:-}" ] || printf '%s\n' "$_SV_HEAD"
  printf '%s\n' "$rows" | while IFS="$tab" read -r _p ts kind tgt detail next _id; do
    printf 'EVENT %s %s %s %s\nNEXT %s\n' "$kind" "$tgt" "$ts" "$detail" "$next"
  done
  _sv_ledger_add "$1" "$2"
  _sv_lock_rel "$l"
  return 0
}
