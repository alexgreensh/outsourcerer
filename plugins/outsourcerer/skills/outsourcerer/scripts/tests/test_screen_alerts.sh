#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_screen_alerts.sh -- alerts people can trust (lane osrc-l3). The incident: 962 of 1,024
# "stalled" events were a healthy agent whose screen format the reader did not know; dead panes
# re-reported `failed` for hours; real rate-limit screens hid inside the noise.
#   1. provider refusals classify `limit` with the stated reset, exactly (cc, codex, devin, agy, generic)
#   2. text that merely mentions limits (errors, prose, tool output, older turns) never does
#   3. a busy row and a refusal: the newer one wins; a live approval keeps precedence
#   4. one busy matcher at every pane height
#   5. pane liveness: report survives `set -e`; a corpse reads dead
#   6. osrc_screen_alert: unknown vs stalled windows, a real stall still fires, every state change
#      reported once across fresh watchers (restart) and past the 20-minute reminder interval
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"
FX="$SCRIPT_DIR/fixtures/screen"; SFX="$SCRIPT_DIR/fixtures/supervise"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-screen-alerts.XXXXXX")" || { echo "FAIL: no scratch dir" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/panes" "$TMP/home"
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc" OSRC_HEARTBEAT_DISABLED=1 OSRC_SOURCED=1
unset TMUX TMUX_PANE OSRC_NOW OSRC_SCREEN_UNKNOWN_SECS OSRC_SCREEN_STALL_SECS OSRC_SCREEN_UNKNOWN_CPU
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
set --; . "$SRC" >/dev/null 2>&1
type osrc_screen_alert >/dev/null 2>&1 || { echo "FAIL: lib/screen.sh not loaded"; exit 1; }
scr() { _osrc_screen_analyze_text "$2" < "$1"; printf '%s|%s' "$OSRC_SCR_STATE" "$OSRC_SCR_EVIDENCE"; }
want() { # <file> <engine> <glob for "state|evidence"> <label>
  local row; row="$(scr "$1" "$2")"
  # shellcheck disable=SC2254
  case "$row" in $3) ok "$4 -> $row" ;; *) no "$4 -> got: $row" ;; esac
}

echo "=== 1. refusals -> limit, with the reset when one is shown ==="
want "$FX/cc-limit-usage.ansi" cc 'limit|*reset: reset at 3pm (epoch *' "claude usage-limit banner"
want "$FX/cc-limit-429.txt" cc 'limit|*API Error: 429*' "claude API Error 429 banner"
want "$FX/cx-limit-usage.ansi" codex 'limit|*reset: Try again at 22:28 (epoch *' "codex usage-limit banner"
want "$FX/dv-limit-plan.ansi" devin 'limit|*reset: resets in 1h 5m' "devin plan-limit banner"
want "$SFX/agy-quota-reached.txt" agy 'limit|*reset: Resets in 1h13m1s' "antigravity individual-quota banner"
want "$SFX/agy-retry-backoff.txt" agy 'limit|*reset: Retrying in 42s' "antigravity retry-backoff banner"
want "$FX/generic-limit.txt" "" 'limit|*reset: try again in 30s' "generic rate-limit banner"
for spec in cc-limit-usage.ansi cx-limit-usage.ansi dv-limit-plan.ansi cc-limit-429.txt; do
  want "$FX/$spec" "" 'limit|*' "engine guessed: $spec"
done
want "$FX/generic-limit-clock.txt" "" 'limit|*reset: Resets 22:28 (epoch *' "bare clock reset keeps all four digits"
# A zone in the banner is kept and honoured, on a machine that is not on UTC.
row="$(TZ=XYZ5 scr "$FX/generic-limit-utc.txt" "")"
n="$(date +%s)"; exp=$(( n - n % 86400 + 9 * 3600 )); [ "$exp" -le "$n" ] && exp=$((exp + 86400))
ep="${row##*(epoch }"; ep="${ep%)}"
case "$row" in
  "limit|"*"reset: Resets at 09:00 UTC (epoch "*")")
    # the reader and this test each read the clock once; allow that one-second tick, nothing more
    if [ "$ep" = "$exp" ] || [ "$ep" = "$((exp + 1))" ]; then ok "UTC reset under TZ=XYZ5 -> epoch $ep (next 09:00 UTC)"
    else no "UTC reset epoch $ep, want $exp"; fi ;;
  *) no "UTC reset phrase lost: $row" ;;
esac
want "$FX/generic-limit-relative.txt" "" 'limit|*reset: Try again in 2h' "relative reset alone carries no invented epoch"

echo "=== 2. mentions that are not refusals never classify limit ==="
nolim() { local row; row="$(scr "$1" "$2")"; case "$row" in limit\|*) no "$3 -> false limit: $row" ;; *) ok "$3 -> ${row%%|*}" ;; esac; }
nolim "$FX/generic-error-not-limit.txt" "" "Error: permission denied opening config"
nolim "$FX/cx-prose-quota.txt" codex "codex assistant reply that says 'quota exceeded'"
nolim "$FX/unknown-prose-limit.txt" "" "claude-style prose about 429"
nolim "$FX/unknown-toolresult-429.txt" "" "tool output 'HTTP 429' under a Bash( header"
nolim "$FX/cc-tool-multiline-429.txt" cc "claude multiline tool output with an indented rate-limit error"
nolim "$FX/cx-tool-quota.txt" codex "codex multiline tool output with an indented quota error"
nolim "$FX/cx-limit-recovered.txt" codex "refusal followed by a finished turn (Worked for 3s)"
want "$FX/cx-composer-empty-history.txt" codex 'composer|*no turn yet*' "recognized composer, empty history: footer is not history"
nolim "$FX/cx-idle.ansi" codex "codex low-weekly-limit warning"
nolim "$FX/dv-idle.ansi" devin "devin '0% remaining (resets in 43m)' status"

echo "=== 3. busy row vs refusal: the newer one wins ==="
want "$FX/generic-spinner-then-limit.txt" "" 'limit|*Rate limit exceeded*' "spinner, then refusal"
want "$FX/generic-limit-then-spinner.txt" "" 'working|*Syncing*' "refusal, then a newer spinner"
want "$FX/generic-limit-under-approval.txt" "" 'approval|*' "live approval prompt under a refusal"

echo "=== 4. one busy matcher at every height ==="
want "$FX/generic-busy-low.txt" "" 'working|*Weaving the graph*' "braille spinner in the last three rows"
want "$FX/unknown-busy-spinner.txt" "" 'working|*' "spinner row higher up"
want "$FX/unknown-busy-esc.txt" "" 'working|*' "interrupt hint higher up"
row="$(scr "$FX/generic-prose-ellipsis.txt" "")"
case "$row" in working\|*) no "prose 'See documentation… (appendix A)' read as busy: $row" ;; *) ok "ellipsis prose is not busy -> ${row%%|*}" ;; esac
want "$FX/unknown-busy-stale.txt" "" 'unknown|*' "spinner above a done summary is scrollback"
want "$FX/unknown-busy-prompt.txt" "" 'idle|*' "bare prompt below an old busy row"

echo "=== 5. pane liveness ==="
# fake tmux: panes are files; <pane>.dead holds #{pane_dead}; pane_pid is always 100
cat > "$TMP/bin/tmux" <<'EOF'
#!/bin/bash
t=""; for a in "$@"; do [ "$prev" = -t ] && t="$a"; prev="$a"; done
case "$1" in
  capture-pane) [ -f "$FAKE_PANES/$t.screen" ] || exit 1; cat "$FAKE_PANES/$t.screen" ;;
  display-message)
    [ -f "$FAKE_PANES/$t.screen" ] || exit 1
    case "$*" in *pane_dead*) cat "$FAKE_PANES/$t.dead" 2>/dev/null || echo 0 ;; *pane_pid*) echo 100 ;; esac ;;
  *) exit 0 ;;
esac
EOF
# fake ps: the pane's process tree (pid 100 + a child) with CPU time from <FAKE_PANES>/cpu ("-" = ps fails)
cat > "$TMP/bin/ps" <<'EOF'
#!/bin/bash
c="$(cat "$FAKE_PANES/cpu" 2>/dev/null || echo 0)"; [ "$c" = - ] && exit 1
printf '  100     1 00:00:%02d\n  101   100 00:00:01\n  900     1 00:09:00\n' "$c"
EOF
chmod +x "$TMP/bin/tmux" "$TMP/bin/ps"
export PATH="$TMP/bin:$PATH" FAKE_PANES="$TMP/panes"
cp "$FX/cx-working.ansi" "$TMP/panes/p1.screen"; echo 0 > "$TMP/panes/p1.dead"
out="$( set -e; osrc_screen_report p1 codex; echo REACHED )"
case "$out" in *"STATE=working"*"PANE_DEAD=0"*REACHED) ok "osrc_screen_report on a live pane completes under set -e" ;;
  *) no "report under set -e: $(printf '%s' "$out" | tr '\n' ' ')" ;; esac
echo 1 > "$TMP/panes/p1.dead"
out="$(osrc_screen_report p1 codex)"
case "$out" in *"STATE=dead"*"PANE_DEAD=1"*) ok "remain-on-exit corpse with a working frame -> STATE=dead" ;; *) no "corpse report: $out" ;; esac

echo "=== 6. osrc_screen_alert: one report per change, restart-safe ==="
T0=1900000000
al() { ( OSRC_NOW="$2"; osrc_screen_alert "$1" "${3:-}" ) | cut -f1,2 | tr '\t' ' '; }   # fresh watcher each call
seq_is() { # <label> <want> <got...>
  local label="$1" w="$2"; shift 2
  [ "$*" = "$w" ] && ok "$label: $*" || no "$label: want '$w' got '$*'"
}
# Incident 1: a healthy busy agent in an unrecognized format, quiet screen, CPU moving.
cp "$FX/generic-unrecognized.txt" "$TMP/panes/u1.screen"; echo 5 > "$TMP/panes/cpu"
a="$(al u1 $T0)"; b="$(al u1 $((T0 + 25)))"; echo 30 > "$TMP/panes/cpu"; c="$(al u1 $((T0 + 700)))"
seq_is "healthy unrecognized agent at 0s / 25s / 700s (CPU moving)" "unknown new | unknown seen | unknown seen" "$a |" "$b |" "$c"
# Both sides of the unknown window with CPU flat (independent evidence that work stopped).
cp "$FX/generic-unrecognized.txt" "$TMP/panes/u2.screen"; echo 5 > "$TMP/panes/cpu"
a="$(al u2 $T0)"; b="$(al u2 $((T0 + 599)))"; c="$(al u2 $((T0 + 600)))"; d="$(al u2 $((T0 + 601)))"; e="$(al u2 $((T0 + 600 + 1300)))"
seq_is "unknown, CPU flat: 0 / 599 / 600 / 601 / +20min" "unknown new | unknown seen | stalled new | stalled seen | stalled seen" "$a |" "$b |" "$c |" "$d |" "$e"
cp "$FX/generic-unrecognized.txt" "$TMP/panes/u2b.screen"
a="$( export OSRC_SCREEN_UNKNOWN_SECS=60; al u2b $T0; al u2b $((T0 + 59)); al u2b $((T0 + 60)) )"
seq_is "the unknown window is configurable (60s)" "unknown new unknown seen stalled new" $a
# CPU unreadable: twice the window stands in for the missing evidence.
cp "$FX/generic-unrecognized.txt" "$TMP/panes/u3.screen"; echo - > "$TMP/panes/cpu"
a="$(al u3 $T0)"; b="$(al u3 $((T0 + 1199)))"; c="$(al u3 $((T0 + 1200)))"
seq_is "unknown, CPU unreadable: 0 / 1199 / 1200" "unknown new | unknown seen | stalled new" "$a |" "$b |" "$c"
echo 5 > "$TMP/panes/cpu"
# A screen change resets the quiet clock.
cp "$FX/generic-unrecognized.txt" "$TMP/panes/u4.screen"
al u4 $T0 >/dev/null; printf 'tick\n' >> "$TMP/panes/u4.screen"
seq_is "a changed unrecognized screen restarts its window" "unknown seen" "$(al u4 $((T0 + 650)))"
# Deliverable 4: a recognized working frame that freezes is still a stall.
cp "$FX/cx-working.ansi" "$TMP/panes/w1.screen"
a="$(al w1 $T0 codex)"; b="$(al w1 $((T0 + 899)) codex)"; c="$(al w1 $((T0 + 900)) codex)"; d="$(al w1 $((T0 + 900 + 1300)) codex)"
seq_is "frozen working frame: 0 / 899 / 900 / +20min" "working new | working seen | stalled new | stalled seen" "$a |" "$b |" "$c |" "$d"
# Incident 2: a dead pane whose working frame is still readable reports failed once.
cp "$FX/cx-working.ansi" "$TMP/panes/d1.screen"; echo 0 > "$TMP/panes/d1.dead"
a="$(al d1 $T0 codex)"; echo 1 > "$TMP/panes/d1.dead"
b="$(al d1 $((T0 + 10)) codex)"; c="$(al d1 $((T0 + 20)) codex)"; d="$(al d1 $((T0 + 10 + 1300)) codex)"; e="$(al d1 $((T0 + 7200)) codex)"
seq_is "dead pane, working frame readable: live / dead / again / +20min / +2h" "working new | failed new | failed seen | failed seen | failed seen" "$a |" "$b |" "$c |" "$d |" "$e"
ev="$( OSRC_NOW=$((T0 + 30)); osrc_screen_alert d1 codex | cut -f3 )"
case "$ev" in "pane process exited; last frame read: working"*) ok "dead evidence names the frozen frame: $ev" ;; *) no "dead evidence: $ev" ;; esac
# A pane that vanished entirely.
cp "$FX/cx-working.ansi" "$TMP/panes/g1.screen"
a="$(al g1 $T0 codex)"; rm -f "$TMP/panes/g1.screen"
b="$(al g1 $((T0 + 10)))"; c="$(al g1 $((T0 + 10 + 1300)))"
seq_is "vanished pane: live / gone / +20min" "working new | failed new | failed seen" "$a |" "$b |" "$c"
# Incident 3 at the alert layer: limit once for the whole parked stretch, again only after recovery.
cp "$FX/cx-working.ansi" "$TMP/panes/l1.screen"
a="$(al l1 $T0 codex)"; cp "$FX/cx-limit-usage.ansi" "$TMP/panes/l1.screen"
b="$(al l1 $((T0 + 10)) codex)"; c="$(al l1 $((T0 + 10 + 1300)) codex)"; d="$(al l1 $((T0 + 7200)) codex)"
cp "$FX/cx-working.ansi" "$TMP/panes/l1.screen"; e="$(al l1 $((T0 + 7300)) codex)"
cp "$FX/cx-limit-usage.ansi" "$TMP/panes/l1.screen"; f="$(al l1 $((T0 + 7400)) codex)"
seq_is "limit: working / limit / +20min / +2h / recovered / new incident" "working new | limit new | limit seen | limit seen | working new | limit new" "$a |" "$b |" "$c |" "$d |" "$e |" "$f"
cp "$FX/cc-limit-429.txt" "$TMP/panes/l2.screen"
seq_is "claude 429 banner alerts as limit, never failed" "limit new" "$(al l2 $T0 cc)"
# A frozen relative countdown keeps one deadline.
cp "$FX/generic-limit-relative.txt" "$TMP/panes/r1.screen"
e1="$( OSRC_NOW=$T0; osrc_screen_alert r1 | cut -f3 )"; e2="$( OSRC_NOW=$((T0 + 3600)); osrc_screen_alert r1 | cut -f3 )"
case "$e1|$e2" in *"(epoch $((T0 + 7200)),"*"|"*"(epoch $((T0 + 7200)),"*) ok "frozen 'Try again in 2h' -> epoch T0+7200 at T0 and at T0+1h" ;;
  *) no "frozen countdown moved: '$e1' then '$e2'" ;; esac
# A ticking countdown re-anchors to now.
printf '%s\n' 'sync stage 2 of 4' '⚠ Rate limited. Try again in 1h' 'status: parked' > "$TMP/panes/r1.screen"
e3="$( OSRC_NOW=$((T0 + 3600)); osrc_screen_alert r1 | cut -f3 )"
case "$e3" in *"(epoch $((T0 + 7200)),"*) ok "ticking countdown (2h -> 1h an hour later) keeps the same deadline" ;; *) no "ticking countdown: $e3" ;; esac

echo "=== done: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
