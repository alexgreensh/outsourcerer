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

# The real dashboard path: _osrc_lane_summary_base --json (rows, windows, age_s) into _osrc_plan_overlay.
# Only the meter read and harness detection are stubbed; the log reading is "<used> percent, <age_s> old".
_osrc_harness_detected() { [ "$1" = codex ]; }
row() { # <used> <age_s>
  eval "_osrc_meter_windows() { printf 'codexwk\\t$1\\t$RESET\\t$2\\n'; }"
  _osrc_lane_summary_base --json
}
probe() { # <used> <age_s>
  mkdir -p "$OSRC_HOME/hub/probes"
  printf '{"ok":true,"windows":{"codexwk":{"used":%s,"renews_at":%s}},"checked":%s}\n' "$1" "$RESET" $(( NOW - $2 )) > "$OSRC_HOME/hub/probes/codex.json"
}

# 1. the incident: probe 3 h old at 72% used; the session log is 2 min old at 96% used.
probe 72 10800
o="$(row 96 120)"
case "$(jq -r '.[0].left' <<<"$o")" in *"4% left"*) ok "the newer session-log reading beats the 3 h old probe" ;; *) bad "old probe won: $(jq -r '.[0].left' <<<"$o")" ;; esac
[ "$(jq -r '.[0].low' <<<"$o")" = true ] && ok "4% left is flagged low on the page row" || bad "low flag missing"

# 2. the other way round: a probe newer than the log wins.
probe 72 60
o="$(row 96 5000)"
case "$(jq -r '.[0].left' <<<"$o")" in "28% left"*) ok "a newer probe beats an older log" ;; *) bad "newer probe lost: $(jq -r '.[0].left' <<<"$o")" ;; esac

# 3. a 3 h old reading is stale: shown with its age, and unknown (not headroom) for routing.
rm -f "$OSRC_HOME/hub/probes/codex.json"
o="$(row 40 10800)"
case "$(jq -r '.[0].left' <<<"$o")" in *"60% left · checked 3 h ago"*) ok "stale reading shows its age" ;; *) bad "no age: $(jq -r '.[0].left' <<<"$o")" ;; esac
[ "$(jq -r '.[0].state' <<<"$o")" = unknown ] && [ "$(jq -r '.[0].stale' <<<"$o")" = true ] && ok "stale reading is unknown, not ok" || bad "stale reading kept state $(jq -r '.[0].state' <<<"$o")"
o="$(row 40 600)"
[ "$(jq -r '.[0].state' <<<"$o")" = ok ] && [ "$(jq -r '.[0].stale // false' <<<"$o")" = false ] && ok "a fresh reading stays ok" || bad "fresh reading wrongly stale"
o="$(row 100 10800)"
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
a="$(_osrc_limits_low_scan "codexwk=99 codexage=30000")"
[ -z "$a" ] && ok "a stale codex reading never raises the alarm" || bad "stale alarm: $a"

# 6. a 25 h old log reading plus a probe that failed 30 s ago is stale, never fresh headroom.
printf '{"ok":false,"why":"codex app-server timed out","checked":%s}\n' $(( NOW - 30 )) > "$OSRC_HOME/hub/probes/codex.json"
o="$(row 40 90000)"
[ "$(jq -r '.[0].state' <<<"$o")" = unknown ] && [ "$(jq -r '.[0].stale' <<<"$o")" = true ] && [ "$(jq -r '.[0].age_s' <<<"$o")" -gt 80000 ] \
  && ok "stale log + failed probe: unknown, flagged stale, age is the log's" || bad "stale log shown as headroom: $(jq -c '.[0]|{state,left,stale,age_s}' <<<"$o")"

# 7. low flag on a row with no probe at all.
rm -f "$OSRC_HOME/hub/probes/codex.json"
o="$(row 96 120)"
[ "$(jq -r '.[0].low' <<<"$o")" = true ] && ok "low flag without a probe" || bad "low missing without a probe"

# 8. a kept good Devin probe does not hide a sign-out; a kept codex probe is marked stale.
cat > "$OSRC_HOME/hub/probes/devin.json" <<J
{"ok":true,"free":["a","b"],"plan":"Pro","checked":$(( NOW - 864000 ))}
J
_osrc_probe_fetch() { printf '{"ok":false,"why":"not signed in","checked":%s}\n' "$NOW"; }
_osrc_probe_store devin
[ "$(jq -r '.ok' "$OSRC_HOME/hub/probes/devin.json")" = false ] && ok "a failed Devin probe replaces the old good one" || bad "devin sign-out hidden"
probe 72 1000; _osrc_probe_store codex
_osrc_harness_detected() { [ "$1" = codex ]; }
o="$(row 10 5000)"
[ "$(jq -r '.[0].stale' <<<"$o")" = true ] && [ "$(jq -r '.[0].state' <<<"$o")" != ok ] && ok "kept codex probe after failed refresh is stale" || bad "refresh_failed ignored: $(jq -c '.[0]|{state,stale}' <<<"$o")"

# 9. the low alert survives a window going missing for a call; only a present reading over the line clears it.
EV="$TMP/events2"; : > "$EV"; rm -f "$OSRC_HOME/limits-low-seen"
_osrc_limits_low_scan "claude5h=95" >/dev/null; _osrc_limits_low_scan "codexwk=10" >/dev/null; _osrc_limits_low_scan "claude5h=96" >/dev/null
[ "$(grep -c '^limit-low claude5h' "$EV")" = 1 ] && ok "a missing window is not forgotten" || bad "re-alerted: $(cat "$EV")"

# 10. the launch gate keeps its 6 h horizon: a 2.5 h old codex reading at the limit still gates.
_osrc_lane_limit_stale cx "codexwk=100 codexage=9000" && bad "2.5 h old reading no longer gates" || ok "2.5 h old reading still gates the launch"
a="$(OSRC_LIMITS_STALE_SECS=21600 _osrc_limits_low_scan "codexwk=99 codexage=10800")"
case "$a" in *"ChatGPT weekly"*) ok "low scan honours OSRC_LIMITS_STALE_SECS" ;; *) bad "low scan ignored the setting" ;; esac

# 11. a stale log row is not overridden by an older kept probe: the exhausted log stays out.
printf '{"ok":true,"windows":{"codexwk":{"used":20,"renews_at":%s}},"checked":%s,"refresh_failed":"timed out"}\n' "$RESET" $(( NOW - 172800 )) > "$OSRC_HOME/hub/probes/codex.json"
o="$(row 100 10800)"
[ "$(jq -r '.[0].state' <<<"$o")" = out ] && [ "$(jq -r '.[0].used' <<<"$o")" = 100 ] && ok "newer stale log beats an older kept probe" || bad "old probe won: $(jq -c '.[0]|{state,left,used}' <<<"$o")"

# 12. one failed refresh does not blank a reading younger than the probe TTL; an older one is stale.
probe 72 100; _osrc_probe_store codex
o="$(row 10 5000)"
[ "$(jq -r ".[0].state" <<<"$o")" != unknown ] && [ "$(jq -r ".[0].stale // false" <<<"$o")" = false ] && ok "young kept probe stays usable after one failed refresh" || bad "young probe blanked: $(jq -c '.[0]|{state,stale}' <<<"$o")"

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
