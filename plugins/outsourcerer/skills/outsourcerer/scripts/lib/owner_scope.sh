# owner_scope.sh -- which delegates belong to another orchestrator.
#
# Every orchestrator records the runs it launched as $OSRC_HOME/owners/<its session id>/<run id>.
# The turn-end guard reads the machine-wide fleet view, so without this it told one orchestrator
# that another orchestrator's parked sessions "need you", which invites answering prompts in panes
# it does not own. Only a run recorded under a DIFFERENT session, and not also under the caller,
# is hidden: a run with no owner record still shows, so a gap in the records never silences a
# real wait.

# _osrc_owned_by_others -> " id1 id2 ... " (space-padded) or nothing when the caller is unknown.
_osrc_owned_by_others() {
  local self="${CLAUDE_CODE_SESSION_ID:-}" root="${OSRC_HOME:-$HOME/.outsourcerer}/owners" d f id mine=" " out=" "
  [ -n "$self" ] && [ -d "$root" ] || return 0
  if [ -d "$root/$self" ]; then
    for f in "$root/$self"/*; do [ -e "$f" ] && mine="$mine${f##*/} "; done
  fi
  for d in "$root"/*/; do
    d="${d%/}"; [ "${d##*/}" = "$self" ] && continue
    for f in "$d"/*; do
      [ -e "$f" ] || continue; id="${f##*/}"
      case "$mine$out" in *" $id "*) continue ;; esac
      out="$out$id "
    done
  done
  [ "$out" = " " ] || printf '%s' "$out"
}
