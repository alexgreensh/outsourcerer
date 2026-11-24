#!/usr/bin/env bash
# test_limits_staleness.sh — the newest limit reading wins, an old one says so, a failed probe keeps
# the old value marked stale, and a window under the low line is announced once.
#
# Incident: Mission Control showed ChatGPT at 28% left "updated 21:54" (a three-hour-old live probe) while
# the session log, read by `brief`, said 4% left. The page never took the newer reading and never
# said the number was old. Work was routed to a plan that had no room.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
TMP="$(mktemp -d)"; export HOME="$TMP/home" OSRC_HOME="$TMP/osrc"; mkdir -p "$HOME" "$OSRC_HOME"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
. "$SRC" >/dev/null 2>&1
export OSRC_PROBE=0   # no live probes: only the cached answers placed below
NOW="$(date +%s)"; RESET=$(( NOW + 86400 ))

row() { # <used> <age_s> -> one codex summary row as the base produces it
  local st=ok; [ "$1" -ge 90 ] && st=out
  printf '[{"id":"codex","name":"Codex","state":"%s","left":"%s%% left","used":%s,"window":"codexwk","windows":{"codexwk":{"used":%s,"renews_at":%s,"age_s":%s}}}]' "$st" $(( 100 - $1 )) "$1" "$1" "$RESET" "$2"
}
probe() { # <used> <age_s>
  mkdir -p "$OSRC_HOME/hub/probes"
  printf '{"ok":true,"windows":{"codexwk":{"used":%s,"renews_at":%s}},"checked":%s}\n' "$1" "$RESET" $(( NOW - $2 )) > "$OSRC_HOME/hub/probes/codex.json"
}
ov() { _osrc_plan_overlay; }

# 1. the incident: probe 3 h old at 72% used; the session log is 2 min old at 96% used.
probe 72 10800
o="$(row 96 120 | ov)"
case "$(jq -r '.[0].left' <<<"$o")" in *"4% left"*) ok "the newer session-log reading beats the 3 h old probe" ;; *) bad "old probe won: $(jq -r '.[0].left' <<<"$o")" ;; esac
[ "$(jq -r '.[0].low' <<<"$o")" = true ] && ok "4% left is flagged low on the page row" || bad "low flag missing"

# 2. the other way round: a probe newer than the log wins.
probe 72 60
o="$(row 96 5000 | ov)"
case "$(jq -r '.[0].left' <<<"$o")" in "28% left"*) ok "a newer probe beats an older log" ;; *) bad "newer probe lost: $(jq -r '.[0].left' <<<"$o")" ;; esac

# 3. a 3 h old reading is stale: shown with its age, and unknown (not headroom) for routing.
rm -f "$OSRC_HOME/hub/probes/codex.json"
o="$(row 40 10800 | ov)"
case "$(jq -r '.[0].left' <<<"$o")" in *"60% left · checked 3 h ago"*) ok "stale reading shows its age" ;; *) bad "no age: $(jq -r '.[0].left' <<<"$o")" ;; esac
[ "$(jq -r '.[0].state' <<<"$o")" = unknown ] && [ "$(jq -r '.[0].stale' <<<"$o")" = true ] && ok "stale reading is unknown, not ok" || bad "stale reading kept state $(jq -r '.[0].state' <<<"$o")"
o="$(row 40 600 | ov)"
[ "$(jq -r '.[0].state' <<<"$o")" = ok ] && [ "$(jq -r '.[0].stale // false' <<<"$o")" = false ] && ok "a fresh reading stays ok" || bad "fresh reading wrongly stale"
o="$(row 100 10800 | ov)"
[ "$(jq -r '.[0].state' <<<"$o")" = out ] && ok "a stale exhausted reading stays out" || bad "stale 100% became headroom"

# 4. a failed probe keeps the last good value, with its original time.
probe 72 100
_osrc_probe_fetch() { printf '{"ok":false,"why":"codex app-server timed out","checked":%s}\n' "$NOW"; }
_osrc_probe_store codex
c="$(cat "$OSRC_HOME/hub/probes/codex.json")"
[ "$(jq -r '.ok' <<<"$c")" = true ] && [ "$(jq -r '.windows.codexwk.used' <<<"$c")" = 72 ] && [ "$(jq -r '.checked' <<<"$c")" = $(( NOW - 100 )) ] \
  && [ -n "$(jq -r '.refresh_failed // empty' <<<"$c")" ] && ok "failed probe keeps the old value and says the refresh failed" || bad "failed probe lost the old value: $c"

# 5. low line: loud every time, one supervise event per crossing.
EV="$TMP/events"; : > "$EV"
_osrc_lane_event() { echo "$1 $2" >> "$EV"; }
a="$(_osrc_limits_low_scan "codexwk=96 claude5h=20")"; b="$(_osrc_limits_low_scan "codexwk=96 claude5h=20")"
case "$a" in *"ChatGPT weekly has 4% left"*) ok "brief line names the window and the percent" ;; *) bad "no low line: $a" ;; esac
[ "$(wc -l < "$EV" | tr -d ' ')" = 1 ] && [ "$(grep -c '^limit-low codexwk' "$EV")" = 1 ] && [ -n "$b" ] && ok "one event for two scans" || bad "event count: $(cat "$EV")"
_osrc_limits_low_scan "codexwk=50" >/dev/null; _osrc_limits_low_scan "codexwk=97" >/dev/null
[ "$(wc -l < "$EV" | tr -d ' ')" = 2 ] && ok "a new crossing fires again" || bad "no second event"
a="$(_osrc_limits_low_scan "codexwk=99 codexage=20000")"
[ -z "$a" ] && ok "a stale codex reading never raises the alarm" || bad "stale alarm: $a"

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
