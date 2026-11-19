#!/usr/bin/env bash
# test_nowrite_watchdog.sh — the ZERO-WRITE (no-progress) watchdog in _supervise. Every older timer
# measures SILENCE (byte growth / idle), so a model that streams reasoning while writing nothing never
# tripped anything (incident: two ~17-min zero-write burns on an edit task). Pins: a write-expecting
# verb (edit/yolo) alive and writeless past OSRC_NOPROGRESS_SECS enters the DISTINCT state
# `no-progress-writes` (not stalled?, not wedged) and is NOT killed by default; read-only verbs
# (run/explore) and text-delegation lanes are NEVER flagged; the hard bound fires only with an explicit
# OSRC_NOPROGRESS_KILL_SECS; a qualifying write clears the state; and the state reconciles like the
# other running states when the process dies.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"; export HOME="$TMP"
cleanup() { rm -rf "$TMP"; }; trap cleanup EXIT
export OSRC_POLL=1 OSRC_NOINIT_SECS=60 OSRC_FS_PROGRESS=1 OSRC_HEARTBEAT_DISABLED=1
. "$SRC" >/dev/null 2>&1
mkdir -p "$OSRC_JOBS"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

mk() { # <name> <verb> <lane> -> job dir (meta.json + private cwd)
  local jd="$OSRC_JOBS/$1" w="$TMP/w-$1"; mkdir -p "$jd" "$w"
  printf '{"verb":"%s","lane":"%s","cwd":"%s","model":"kimi","started":%s}' "$2" "$3" "$w" "$(date +%s)" > "$jd/meta.json"
  printf '%s' "$jd"
}
# A STREAMING delegate: one line per second for N seconds (so idle never grows); writes a file into its
# cwd at second W (0 = never); snapshots its own status file EVERY second into $jd/witness.<i> so a test
# can prove a flag was raised and later cleared (the growth-branch clear is silent by design).
STREAM='n=$1; w=$2; s=$3; jd=$4; cwd=$5; i=0; echo "hello from the model"; while [ $i -lt $n ]; do i=$((i+1)); sleep 1; if [ "$i" -gt "${QUIET_UNTIL:-0}" ]; then echo "reasoning step $i ..."; fi; cat "$jd/status" > "$jd/witness.$i" 2>/dev/null; if [ "$i" = "$w" ] || { [ "${WRITE_ON_STALL:-0}" = 1 ] && grep -qx no-progress-writes "$jd/witness.$i"; }; then date > "$cwd/out.txt"; fi; done; echo "OSRC::DONE"'
wit() { cat "$1/witness.$2" 2>/dev/null; }
sup() { # <jd> <verb> <n> <w> <s> [env...]  -> runs _supervise with wide silence windows so only the new arm can act
  local jd="$1" verb="$2" n="$3" w="$4" s="$5"; shift 5
  env "$@" OSRC_JOB_VERB="$verb" bash -c '
    set -uo pipefail; export OSRC_SOURCED=1; . "$0" >/dev/null 2>&1
    _supervise "$1" 30 60 120 -- sh -c "$2" _ "$3" "$4" "$5" "$1" "$6"' "$SRC" "$jd" "$STREAM" "$n" "$w" "$s" "$TMP/w-$(basename "$jd")" >/dev/null 2>"$jd/sup.err"
}

# 1. edit verb, streams 8s, never writes, OSRC_NOPROGRESS_SECS=3, no kill knob -> flagged mid-flight, survives.
jd=$(mk c1 edit dv); sup "$jd" edit 10 0 6 OSRC_NOPROGRESS_SECS=3 QUIET_UNTIL=6
[ "$(wit "$jd" 6)" = "no-progress-writes" ] && ok "edit+writeless past OSRC_NOPROGRESS_SECS -> state no-progress-writes while alive and streaming" \
  || bad "edit+writeless: witness@6='$(wit "$jd" 6)' (want no-progress-writes)"
[ "$(wit "$jd" 10)" = running ] && ok "resumed output clears no-progress-writes" || bad "resumed output did not clear the stall"
[ "$(wit "$jd" 2)" = "running" ] && ok "edit+writeless: still running BEFORE the threshold" || bad "edit+writeless: witness@2='$(wit "$jd" 2)'"
grep -q 'Not killing it' "$jd/sup.err" && ok "default is SURFACE-ONLY: the WARN says it is not killing" || bad "surface-only WARN missing"
case "$(cat "$jd/status")" in wedged|timeout) bad "job was KILLED without OSRC_NOPROGRESS_KILL_SECS (status=$(cat "$jd/status"))" ;; *) ok "job not killed by default (final status: $(cat "$jd/status"))" ;; esac
[ -s "$jd/nowrite_age" ] && ok "no-write age recorded for status rendering ($(cat "$jd/nowrite_age")s)" || bad "nowrite_age not recorded"
[ -s "$jd/reason" ] && bad "flag wrote a reason file (would mask the reconciler's interrupted reason)" || ok "flag does not write a reason file"

# 2. read-only verbs are never flagged.
jd=$(mk c2 run dv); sup "$jd" run 6 0 5 OSRC_NOPROGRESS_SECS=2
[ "$(wit "$jd" 5)" = "running" ] && ok "run (read-only) verb never flagged" || bad "run verb flagged: '$(wit "$jd" 5)'"
jd=$(mk c3 explore dv); sup "$jd" explore 6 0 5 OSRC_NOPROGRESS_SECS=2
[ "$(wit "$jd" 5)" = "running" ] && ok "explore (read-only) verb never flagged" || bad "explore verb flagged: '$(wit "$jd" 5)'"

# 3. text-delegation lane (local) never flagged even on a mutating verb.
jd=$(mk c4 edit local); sup "$jd" edit 6 0 5 OSRC_NOPROGRESS_SECS=2
[ "$(wit "$jd" 5)" = "running" ] && ok "text-delegation lane (local) never flagged" || bad "local lane flagged: '$(wit "$jd" 5)'"
_lane_text_only tokenrouter && ok "tokenrouter is a text-only lane" || bad "tokenrouter not text-only"
_lane_text_only dv && bad "dv wrongly text-only" || ok "dv is an agentic lane (eligible)"
OSRC_TEXT_LANES="mylane" _lane_text_only mylane && ok "OSRC_TEXT_LANES extends the exemption" || bad "OSRC_TEXT_LANES ignored"

# 4. a write before the threshold -> never flagged; a write AFTER being flagged -> clears to running.
jd=$(mk c5 edit dv); sup "$jd" edit 6 1 5 OSRC_NOPROGRESS_SECS=2
[ "$(wit "$jd" 5)" = "running" ] && ok "an early write keeps the job running (never flagged)" || bad "early writer flagged: '$(wit "$jd" 5)'"
jd=$(mk c6 yolo dv); sup "$jd" yolo 10 0 9 OSRC_NOPROGRESS_SECS=2 QUIET_UNTIL=10 WRITE_ON_STALL=1
grep -qx no-progress-writes "$jd"/witness.* && [ "$(wit "$jd" 10)" = running ] \
  && ok "a late write clears no-progress-writes back to running (flag observed before write)" || bad "late write: final witness=$(wit "$jd" 10)"

# 5. opt-in hard bound: OSRC_NOPROGRESS_KILL_SECS=5 on a 30s writeless streamer -> wedged, reason, exit 125, fast.
jd=$(mk c7 yolo dv); t0=$(date +%s); sup "$jd" yolo 30 0 99 OSRC_NOPROGRESS_SECS=2 OSRC_NOPROGRESS_KILL_SECS=5; el=$(( $(date +%s) - t0 ))
[ "$(cat "$jd/status")" = "wedged" ] && ok "opt-in kill -> wedged" || bad "opt-in kill: status '$(cat "$jd/status")'"
grep -q '^no-progress-writes-timeout:' "$jd/reason" 2>/dev/null && ok "opt-in kill: reason '$(cat "$jd/reason")'" || bad "opt-in kill: reason '$(cat "$jd/reason" 2>/dev/null)'"
[ "$(cat "$jd/exit" 2>/dev/null)" = "125" ] && ok "opt-in kill: exit 125 (stall-class)" || bad "opt-in kill: exit '$(cat "$jd/exit" 2>/dev/null)'"
[ "$el" -lt 20 ] && ok "opt-in kill bounded the 30s burn in ${el}s" || bad "opt-in kill took ${el}s"

# 6. the state is a RUNNING state to every reader: a dead job left in it reconciles to interrupted.
jd="$OSRC_JOBS/c8"; mkdir -p "$jd"; echo no-progress-writes > "$jd/status"; echo 999999 > "$jd/pid"
[ "$(_reconcile_status c8)" = "interrupted" ] && ok "dead job in no-progress-writes reconciles to interrupted" || bad "reconcile: '$(_reconcile_status c8)'"
[ "$(_fleet_classify no-progress-writes 100 0 true 2>/dev/null)" = "unresponsive?" ] && ok "fleet class surfaces it as unresponsive? (MAYBE STUCK), not 'working'" || bad "fleet class: '$(_fleet_classify no-progress-writes 100 0 true 2>/dev/null)'"
# status line renders the age beside the state
jd="$OSRC_JOBS/c9"; mkdir -p "$jd"; sleep 20 & LP=$!
echo no-progress-writes > "$jd/status"; echo "$LP" > "$jd/pid"; ps -o lstart= -p "$LP" | tr -s ' ' > "$jd/pid_start"
echo 700 > "$jd/nowrite_age"; printf '{"verb":"edit","model":"kimi","started":%s}' "$(( $(date +%s) - 800 ))" > "$jd/meta.json"; echo $(( $(date +%s) - 800 )) > "$jd/started_at"
{ _t3b_pipe="$(_status_line c9 2>/dev/null)" && grep -q 'no-progress-writes.*!no-writes(700s,alive)' <<<"$_t3b_pipe"; } && ok "status line shows '!no-writes(<age>s,alive)'" || bad "status line: $(_status_line c9 2>/dev/null)"
kill "$LP" 2>/dev/null

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
