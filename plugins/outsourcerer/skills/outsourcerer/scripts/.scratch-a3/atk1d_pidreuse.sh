#!/usr/bin/env bash
# atk1d: prove the reap kills whatever the child-enumeration reports, including a stale pid.
# _descendants is overridden to ALSO return the pid of a live innocent process. If the reap
# kills it, the window between enumeration and kill is exploitable by pid recycling.
set -uo pipefail
S="/Users/alexgreenshpun/CascadeProjects/Prompts/PERSONAL_OS/PROJECTS/outsourcerer/sessions/2026-10-09-pr-sweep/wt-a-ttl/plugins/outsourcerer/skills/outsourcerer/scripts/outsourcerer.sh"
export OSRC_HOME; OSRC_HOME="$(mktemp -d)"; export HOME; HOME="$(mktemp -d)"
set --; OSRC_SOURCED=1 . "$S" >/dev/null 2>&1

sleep 61.41 & sentinel=$!
sleep 61.42 & sentinel2=$!

# enumeration that appends innocent pids (stand-in for recycled-pid reports)
_descendants() { echo "$sentinel"; echo "$sentinel2"; }

x="$(_timeout 5 true)"
sleep 0.3
s1=$(kill -0 "$sentinel" 2>/dev/null && echo ALIVE || echo KILLED)
s2=$(kill -0 "$sentinel2" 2>/dev/null && echo ALIVE || echo KILLED)
echo "sentinel1=$s1 sentinel2=$s2"
[ "$s1" = KILLED ] || [ "$s2" = KILLED ] \
  && echo "DEFECT: reap killed processes named by the enumeration (recycled-pid kill window)" \
  || echo "PASS: reap never touched unrelated pids"
kill "$sentinel" "$sentinel2" 2>/dev/null; wait "$sentinel" "$sentinel2" 2>/dev/null
echo DONE
