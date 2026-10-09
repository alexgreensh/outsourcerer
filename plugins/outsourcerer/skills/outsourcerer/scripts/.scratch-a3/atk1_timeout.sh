#!/usr/bin/env bash
# atk1_timeout.sh - _timeout hostile inputs. Each case prints CASE/expected/observed/verdict.
set -uo pipefail
S="/Users/alexgreenshpun/CascadeProjects/Prompts/PERSONAL_OS/PROJECTS/outsourcerer/sessions/2026-10-09-pr-sweep/wt-a-ttl/plugins/outsourcerer/skills/outsourcerer/scripts/outsourcerer.sh"
export OSRC_HOME; OSRC_HOME="$(mktemp -d)"; export HOME; HOME="$(mktemp -d)"
set --; OSRC_SOURCED=1 . "$S" >/dev/null 2>&1
say(){ printf '%-58s | exp=%-14s | got=%-18s | %s\n' "$1" "$2" "$3" "$4"; }

# --- bound edge values ---
SECONDS=0; _timeout 0 sleep 5 >/dev/null 2>&1; rc=$?; e=$SECONDS
say "bound 0, child 5s" "124 fast" "$rc in ${e}s" "$([ "$rc" = 124 ] && echo PASS || echo CHECK)"
SECONDS=0; _timeout -1 sleep 5 >/dev/null 2>&1; rc=$?; e=$SECONDS
say "bound -1, child 5s" "124 fast" "$rc in ${e}s" "$([ "$rc" = 124 ] && echo PASS || echo CHECK)"
SECONDS=0; _timeout abc sleep 5 >/dev/null 2>&1; rc=$?; e=$SECONDS
say "bound abc, child 5s" "124 fast" "$rc in ${e}s" "$([ "$rc" = 124 ] && echo PASS || echo CHECK)"
SECONDS=0; _timeout 0.5 sleep 5 >/dev/null 2>&1; rc=$?; e=$SECONDS
say "bound 0.5, child 5s" "124 ~0-1s" "$rc in ${e}s" "$([ "$rc" = 124 ] && echo PASS || echo CHECK)"
SECONDS=0; out="$(_timeout 999999999 echo ok)"; rc=$?
say "bound huge, fast child" "0, ok" "$rc, $out" "$([ "$rc" = 0 ] && [ "$out" = ok ] && echo PASS || echo CHECK)"
SECONDS=0; out="$(_timeout "" echo ok)"; rc=$?
say "bound empty, fast child" "0 or 124" "$rc, $out" "CHECK"

# --- child that ignores TERM ---
SECONDS=0
_timeout 2 bash -c 'trap "" TERM; sleep 60' >/dev/null 2>&1; rc=$?; e=$SECONDS
say "child ignores TERM" "124 <7s (KILL pass)" "$rc in ${e}s" "$([ "$rc" = 124 ] && [ "$e" -lt 8 ] && echo PASS || echo CHECK)"

# --- grandchildren outliving child, holding stdout ---
mkfifo_probe() { :; }
rm -f "$OSRC_HOME/gc.out"
_timeout 2 bash -c 'sleep 60 </dev/null >"'"$OSRC_HOME"'/gc.out" 2>&1 &' >/dev/null 2>&1; rc=$?
sleep 0.3
gc_live=$(pgrep -f "sleep 60" | head -3 | tr '\n' ' ')
say "grandchild outlives child" "kill_tree gets it" "rc=$rc live=[$gc_live]" "$([ -z "$gc_live" ] && echo PASS || echo CHECK)"
pkill -f "^sleep 60$" 2>/dev/null; true

# --- >1MB output captured + piped ---
SECONDS=0; out="$(_timeout 10 bash -c 'yes ABCDEFGH | head -c 2000000')"; rc=$?; e=$SECONDS
say "2MB captured output" "0, 2MB back" "$rc, ${#out}b in ${e}s" "$([ "$rc" = 0 ] && [ "${#out}" -ge 1999000 ] && echo PASS || echo CHECK)"
SECONDS=0; n="$(_timeout 10 bash -c 'yes ABCDEFGH | head -c 2000000' | wc -c)"; rc=$?
say "2MB piped output" "2000000" "$n in ${SECONDS}s" "$([ "$n" = 2000000 ] && echo PASS || echo CHECK)"

# --- nested _timeout ---
out="$(_timeout 8 bash -c '. "$1" >/dev/null 2>&1; _timeout 3 echo inner' _ "$S")"; rc=$?
say "nested _timeout" "0, inner" "$rc, $out" "$([ "$rc" = 0 ] && [ "$out" = inner ] && echo PASS || echo CHECK)"
out="$(_timeout 3 bash -c '. "$1" >/dev/null 2>&1; _timeout 30 sleep 60' _ "$S")"; rc=$?
say "outer bound < inner bound" "124 ~3-5s" "$rc" "$([ "$rc" = 124 ] && echo PASS || echo CHECK)"

# --- 50 concurrent captured calls: cross-kill? leftover sleeps? ---
SECONDS=0
pids=""
for i in $(seq 1 50); do x="$(_timeout 55.5 sleep 0.2)" & pids="$pids $!"; done
wait $pids 2>/dev/null
e=$SECONDS
sleep 2
left="$(ps -ef | grep -c "[s]leep 55.5")"
wd_left="$(ps -ef | grep -v grep | grep -c "osrc.*watchdog" || true)"
say "50 concurrent captured calls" "0 leftover" "${e}s, left=$left" "$([ "$left" = 0 ] && echo PASS || echo CHECK)"

# --- rc fidelity ---
for want in 0 1 5 42; do _timeout 5 bash -c "exit $want" >/dev/null 2>&1; rc=$?
  say "rc fidelity child=$want" "$want" "$rc" "$([ "$rc" = "$want" ] && echo PASS || echo CHECK)"; done
_timeout 5 bash -c 'kill -TERM $$' >/dev/null 2>&1; rc=$?
say "rc fidelity TERM(143)" "143" "$rc" "$([ "$rc" = 143 ] && echo PASS || echo CHECK)"
_timeout 5 bash -c 'kill -KILL $$' >/dev/null 2>&1; rc=$?
say "rc fidelity KILL(137)" "137" "$rc" "$([ "$rc" = 137 ] && echo PASS || echo CHECK)"
_timeout 5 bash -c 'sleep 30' >/dev/null 2>&1 & big=$!
sleep 1; kill -TERM "$big" 2>/dev/null 2>/dev/null || true
wait "$big" 2>/dev/null; rc=$?
sleep 1
say "TERM caller mid-call (bound30)" "no 30s sleep left" "rc=$rc left=$(ps -ef|grep -c '[s]leep 30')" "CHECK"

echo DONE
