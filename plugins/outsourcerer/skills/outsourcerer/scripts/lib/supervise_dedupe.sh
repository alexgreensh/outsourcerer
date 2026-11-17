# shellcheck shell=bash
# lib/supervise_dedupe.sh: one event per change, delivered once per orchestrator.
#
# Two supervise processes armed for the same orchestrator (a re-arm while an older background one
# still runs) used to both log the same idle (two rows, same second) and both deliver it, because
# each keeps its own in-memory cursor (2026-11-17 live log: osrc-auto-S2 at 1794879921, S2b at
# 1794888272). Two guards close that:
#   1. Per-target lock around observe+emit: only one process reads and logs a target at a time. A
#      process that finds the lock held skips the target for that poll (it stays pending). A lock
#      older than OSRC_SUPERVISE_LOCK_STALE seconds (default 120) is from a killed run and is broken.
#   2. Delivered ledger per orchestrator ($OSRC_HOME/supervise/<sid>/delivered, or supervise/_ids/
#      for sid-less explicit-id runs): a row (ts kind target detail) printed by any supervise for
#      that orchestrator is never printed again, whatever cursor the next supervise starts from.
#      Rows older than 24 h are pruned (the replay window is 24 h too).

_sv_lock_dir() { printf '%s/state/%s.lock' "$(_sv_lanes)" "$1"; }

_sv_target_lock() { # <id> -> 0 when this process now holds the lock
  local l m stale; l="$(_sv_lock_dir "$1")"
  mkdir -p "$(_sv_lanes)/state" 2>/dev/null
  mkdir "$l" 2>/dev/null && return 0
  stale="$(_sv_num "${OSRC_SUPERVISE_LOCK_STALE:-}" 120)"
  m="$(stat -c %Y "$l" 2>/dev/null || stat -f %m "$l" 2>/dev/null)"
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  [ $(( $(_sv_now) - m )) -ge "$stale" ] || return 1
  rmdir "$l" 2>/dev/null; mkdir "$l" 2>/dev/null
}
_sv_target_unlock() { rmdir "$(_sv_lock_dir "$1")" 2>/dev/null; return 0; }

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

_sv_ledger() { # <sid> -> ledger file path
  printf '%s/supervise/%s/delivered' "$OSRC_HOME" "${1:-_ids}"
}

# Drop rows (supervise TSV: prio ts kind target detail next) this orchestrator already received.
_sv_ledger_filter() { # <ledger> <rows>
  [ -n "$2" ] || return 0
  if [ -s "$1" ]; then
    printf '%s\n' "$2" | awk -F '\t' 'NR == FNR { seen[$0] = 1; next } NF && !(($2 FS $3 FS $4 FS $5) in seen)' "$1" -
  else printf '%s\n' "$2" | grep .; fi
}

# Record delivered rows and prune entries older than 24 h.
_sv_ledger_add() { # <ledger> <rows>
  local f="$1" since; [ -n "$2" ] || return 0
  mkdir -p "${f%/*}" 2>/dev/null || return 1
  since=$(( $(_sv_now) - 86400 ))
  { [ -f "$f" ] && awk -F '\t' -v s="$since" '$1 >= s' "$f"
    printf '%s\n' "$2" | awk -F '\t' 'NF { print $2 FS $3 FS $4 FS $5 }'
  } | awk '!seen[$0]++' > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

# Deliver <rows> exactly once per orchestrator: under the ledger's lock, drop what another supervise
# already printed, print the rest (batch = one EVENT/NEXT pair per target, highest priority then
# newest; all = every row), record them, release. rc 1 = nothing left to print (someone else did).
_sv_deliver() { # <ledger> <rows> <batch|all>
  local l="$1.lock" rows i=0 m tab; tab="$(printf '\t')"
  mkdir -p "${1%/*}" 2>/dev/null
  until mkdir "$l" 2>/dev/null; do
    m="$(stat -c %Y "$l" 2>/dev/null || stat -f %m "$l" 2>/dev/null)"
    case "$m" in ''|*[!0-9]*) ;; *) [ $(( $(_sv_now) - m )) -lt 30 ] || { rmdir "$l" 2>/dev/null; continue; } ;; esac
    i=$((i + 1)); [ "$i" -lt 100 ] || return 1
    sleep 0.1
  done
  rows="$(_sv_ledger_filter "$1" "$2")"
  # batch: only a real (non-informational) row is worth a wake; `approved` rows ride along with one
  if [ -z "$rows" ] || { [ "$3" = batch ] && [ -z "$(printf '%s\n' "$rows" | awk -F '\t' 'NF && $3 != "approved"')" ]; }; then
    rmdir "$l" 2>/dev/null; return 1
  fi
  if [ "$3" = batch ]; then rows="$(printf '%s\n' "$rows" | sort -t "$tab" -k1,1n -k2,2nr | awk -F '\t' '!seen[$4]++')"; fi
  printf '%s\n' "$rows" | while IFS="$tab" read -r _p ts kind tgt detail next; do
    printf 'EVENT %s %s %s %s\nNEXT %s\n' "$kind" "$tgt" "$ts" "$detail" "$next"
  done
  _sv_ledger_add "$1" "$2"
  rmdir "$l" 2>/dev/null
  return 0
}
