#!/usr/bin/env bash
# atk1b: nested _timeout, unique-duration leak scans scoped to descendants of THIS shell.
set -uo pipefail
S="/Users/alexgreenshpun/CascadeProjects/Prompts/PERSONAL_OS/PROJECTS/outsourcerer/sessions/2026-10-09-pr-sweep/wt-a-ttl/plugins/outsourcerer/skills/outsourcerer/scripts/outsourcerer.sh"
export OSRC_HOME; OSRC_HOME="$(mktemp -d)"; export HOME; HOME="$(mktemp -d)"
set --; OSRC_SOURCED=1 . "$S" >/dev/null 2>&1

# descendants of $$ matching a unique duration, via ppid walk (no name-kill, no -f match)
my_desc() {
  local arg="$1" d all="$$" n
  for n in $(seq 1 8); do
    local kids=""
    for p in $all; do kids="$kids $(pgrep -P "$p" 2>/dev/null)"; done
    kids="$(printf '%s' "$kids" | tr -d ' ')"; [ -z "$kids" ] && break
    all="$kids"
  done
  ps -o pid=,ppid=,command= -p $(printf '%s' "$all" | tr '\n' ' ') 2>/dev/null | grep -F "$arg"
}

echo "--- nested ok ---"
out="$(_timeout 8 bash -c 'OSRC_SOURCED=1 . "$0" >/dev/null 2>&1; _timeout 3 echo inner' "$S")"
echo "rc=$? out=[$out]"

echo "--- outer bound 3 < inner 30: outer must fire, inner tree dies with it ---"
SECONDS=0
out="$(_timeout 3 bash -c 'OSRC_SOURCED=1 . "$0" >/dev/null 2>&1; _timeout 30 sleep 61.37' "$S")"
echo "rc=$? e=${SECONDS}s out=[$out]"
sleep 1
echo "descendant sleep61.37: [$(my_desc 61.37)]"

echo "--- inner fires at 2 inside outer 8: rc from child propagates ---"
SECONDS=0
out="$(_timeout 8 bash -c 'OSRC_SOURCED=1 . "$0" >/dev/null 2>&1; _timeout 2 sleep 61.38; echo "inner_rc=$?"' "$S")"
echo "rc=$? e=${SECONDS}s out=[$out]"
sleep 1
echo "descendant sleep61.38: [$(my_desc 61.38)]"
echo DONE
