#!/usr/bin/env bash
# atk1c: TERM delivered to the caller subshell mid-call; does the detached watchdog self-heal?
set -uo pipefail
S="/Users/alexgreenshpun/CascadeProjects/Prompts/PERSONAL_OS/PROJECTS/outsourcerer/sessions/2026-10-09-pr-sweep/wt-a-ttl/plugins/outsourcerer/skills/outsourcerer/scripts/outsourcerer.sh"
export OSRC_HOME; OSRC_HOME="$(mktemp -d)"; export HOME; HOME="$(mktemp -d)"
set --; OSRC_SOURCED=1 . "$S" >/dev/null 2>&1

# unique duration so any table scan is unambiguous; cleanup only by recorded pids
DUR=4.13
( _timeout "$DUR" sleep 61.39 >/dev/null 2>&1; echo "inner_done rc=$?" > "$OSRC_HOME/midrc" ) &
call_pid=$!
sleep 1
# find the child sleep and the watchdog, both are descendants of call_pid today
kids="$(pgrep -P "$call_pid" 2>/dev/null)"
echo "call_pid=$call_pid kids=[$kids]"
sleep_pid=""; for k in $kids; do
  c="$(ps -o command= -p "$k" 2>/dev/null)"; case "$c" in *61.39*) sleep_pid=$k ;; esac
done
echo "sleep_pid=$sleep_pid"
kill -TERM "$call_pid" 2>/dev/null
sleep 0.3
echo "after TERM: call alive=$(kill -0 "$call_pid" 2>/dev/null && echo Y || echo N) child alive=$(kill -0 "$sleep_pid" 2>/dev/null && echo Y || echo N)"
# child and watchdog are now orphaned; the watchdog's timer must still fire at ~4s and kill the child
t0=$SECONDS
while [ $((SECONDS - t0)) -lt 7 ]; do
  kill -0 "$sleep_pid" 2>/dev/null || break; sleep 0.5
done
echo "child alive after bound+2s: $(kill -0 "$sleep_pid" 2>/dev/null && echo Y || echo N) (self-heal via orphaned watchdog)"
wait "$call_pid" 2>/dev/null
# any stragglers matching our unique duration under init?
left="$(ps -eo pid=,ppid=,command= | awk '$2==1 && /61.39/ {print $1}')"
echo "orphaned 61.39 under init after bound: [${left}]"
[ -n "$left" ] && kill -KILL $left 2>/dev/null
echo "midrc file: $(cat "$OSRC_HOME/midrc" 2>/dev/null)"
echo DONE
