#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_screen_alerts.sh -- osrc-l3-alerts lane regressions for the stall/limit incident:
#   962 of 1,024 "stalled" events were a healthy busy agent whose screen format the reader did
#   not know (state `unknown`, hash frozen 20s, woke as stalled), while dead panes re-emitted
#   `failed` for hours and real rate-limit screens hid inside the noise.
#
#   1. limit/quota banners classify `limit` with the stated reset (cc, codex, devin, agy, generic)
#   2. an unrecognized-but-busy screen classifies `working`, never `unknown` -> cannot stall
#   3. prose and tool output that merely MENTION limits never classify `limit`
#   4. a proven-dead pane reports `dead`/`PANE_DEAD=1`, never the frozen frame's state
#   5. supervise e2e: busy-unknown emits nothing, a real stall still fires, limit emits once and
#      dedupes across re-observation (file-backed state = survives watcher restart), a vanished
#      pane reports `failed` exactly once inside the dedupe window
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"
FX="$SCRIPT_DIR/fixtures/screen"; SFX="$SCRIPT_DIR/fixtures/supervise"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-screen-alerts.XXXXXX")" || { echo "FAIL: no scratch dir" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/panes" "$TMP/home"
ln -s "$SCRIPT_DIR/fake-bin/tmux-files-next" "$TMP/bin/tmux"; export FAKE_TMUX_FILES="$SCRIPT_DIR/fake-bin/tmux-files"
export HOME="$TMP/home" PATH="$TMP/bin:$PATH" FAKE_TMUX_DIR="$TMP/panes" OSRC_HEARTBEAT_DISABLED=1 OSRC_BLIND_TURN_GUARD=0 OSRC_STREAM=1
export OSRC_CLAUDE_PROJECTS_DIR="$TMP/projects" OSRC_CLAUDE_SESSIONS_DIR="$TMP/ccsessions" OSRC_MC_AUTO_OPEN=0
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID OSRC_SUPERVISE_REMIND OSRC_STALL_MIN OSRC_AUTONUDGE OSRC_HOLD_MIN OSRC_SUPERVISE_STALL
export OSRC_SUPERVISE_POLL=1 OSRC_SUPERVISE_CONFIRM=0 OSRC_SUPERVISE_SETTLE=0 OSRC_SUPERVISE_TICK_SECS=86400
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
fresh() { export OSRC_HOME="$TMP/h$1"; mkdir -p "$OSRC_HOME/jobs" "$OSRC_HOME/sessions" "$OSRC_HOME/supervise/S" "$OSRC_HOME/lanes"
  date +%s > "$OSRC_HOME/supervise/S/tick.time"; rm -f "$TMP/panes"/*.screen "$TMP/panes"/*.next "$TMP/panes"/*.log; }
own() { mkdir -p "$OSRC_HOME/owners/$1"; : > "$OSRC_HOME/owners/$1/$2"; }
pane() { cp "$1" "$TMP/panes/$2.screen"; }
lib() { ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; "$@" ); }
obs() { ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _sv_observe_emit "$1" "$2" supervise S; printf '%s|%s|%s\n' "${SV_K:-none}" "$SV_D" "$SV_NX" ); }
kinds() { jq -r --arg t "$1" 'select(.target==$t) | .kind' "$OSRC_HOME/lanes/events.jsonl" 2>/dev/null | tr '\n' ' '; }
scr_state() { _osrc_screen_analyze_text "$2" < "$1"; printf '%s|%s' "$OSRC_SCR_STATE" "$OSRC_SCR_EVIDENCE"; }

echo "=== 1. limit/quota banners -> state limit, reset carried in evidence ==="
OSRC_SOURCED=1; export OSRC_SOURCED; set --; . "$SRC" >/dev/null 2>&1
lim() { # <file> <engine> <label>
  local row; row="$(scr_state "$1" "$2")"
  case "$row" in
    limit\|*reset*) ok "$3 -> limit with reset: ${row#*|}" ;;
    *) no "$3 -> want limit+reset, got: $row" ;;
  esac
}
lim "$FX/cc-limit-usage.ansi" cc "cc usage-limit banner"
lim "$FX/cx-limit-usage.ansi" codex "codex usage-limit banner"
lim "$FX/dv-limit-plan.ansi" devin "devin plan-limit banner"
lim "$FX/generic-limit.txt" "" "generic-engine rate-limit banner"
lim "$SFX/agy-quota-reached.txt" agy "agy individual-quota banner (real capture)"
lim "$SFX/agy-retry-backoff.txt" agy "agy retry-backoff banner (real capture)"
# Engine guess must land on the same verdict (no hint).
for spec in "cc-limit-usage.ansi|cc" "cx-limit-usage.ansi|codex" "dv-limit-plan.ansi|devin"; do
  IFS='|' read -r f e <<<"$spec"
  row="$(scr_state "$FX/$f" "")"
  case "$row" in limit\|*) ok "guess-engine $f -> limit" ;; *) no "guess-engine $f -> $row" ;; esac
done
# A numeric epoch rides along when the reset phrase parses.
row="$(scr_state "$FX/cx-limit-usage.ansi" codex)"
case "$row" in *"epoch "[0-9]*) ok "codex limit evidence carries a reset epoch" ;; *) no "no epoch in: $row" ;; esac

echo "=== 2. unrecognized-but-busy screens -> working, never unknown ==="
busy() { # <file> <label>
  local row; row="$(scr_state "$FX/$1" "")"
  case "$row" in
    working\|*) ok "$2 -> working: ${row#*|}" ;;
    *) no "$2 -> want working, got: $row" ;;
  esac
}
busy unknown-busy-esc.txt "interrupt-hint busy line 7 rows above the tail"
busy unknown-busy-spinner.txt "spinner-led status line above the tail"
row="$(scr_state "$FX/unknown-busy-stale.txt" "")"
case "$row" in
  unknown\|*) ok "busy marker above a done summary stays unrecognized (scrollback, not life): ${row#*|}" ;;
  *) no "stale busy marker misread as live: $row" ;;
esac
row="$(scr_state "$FX/unknown-busy-prompt.txt" "")"
case "$row" in
  idle\|*) ok "busy marker above a bare shell prompt stays idle: ${row#*|}" ;;
  *) no "prompt-precedence broke: $row" ;;
esac

echo "=== 3. limit mentions that are NOT banners never classify limit ==="
neg() { # <file> <engine> <label>
  local row; row="$(scr_state "$1" "$2")"
  case "$row" in
    limit\|*) no "$3 -> false limit: $row" ;;
    *) ok "$3 -> ${row%%|*} (not limit)" ;;
  esac
}
neg "$FX/unknown-prose-limit.txt" "" "prose reply mentioning '429 Too Many Requests'"
neg "$FX/unknown-toolresult-429.txt" "" "tool output 'HTTP 429' under a Bash( call header"
neg "$FX/cx-idle.ansi" codex "codex low-weekly-limit WARNING line (not a block)"
neg "$FX/dv-idle.ansi" devin "devin 'Pro · 0% remaining (resets in 43m)' status (not a block)"
neg "$FX/cc-idle-after-work.ansi" cc "plain finished turn (control)"

echo "=== 4. pane_dead: a corpse never reports its frozen frame ==="
CAPF="$FX/cc-idle-after-work.ansi"
mkdir -p "$TMP/bin-pd"
cat > "$TMP/bin-pd/tmux" <<'EOF'
#!/bin/bash
case "$1" in
  capture-pane) cat "$CAPF" ;;
  display-message) [ "$PD_ANS" = FAIL ] && exit 1; printf '%s\n' "$PD_ANS" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin-pd/tmux"
pd() { # <pane_dead-answer|FAIL> -> "STATE|PANE_DEAD" from osrc_screen_report
  ( export CAPF="$CAPF" PD_ANS="$1" PATH="$TMP/bin-pd:$PATH"
    OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
    osrc_screen_report p1 cc | awk -F= '/^STATE=/{s=$2}/^PANE_DEAD=/{d=$2}END{print s"|"d}' )
}
row="$(pd 1)"; [ "$row" = "dead|1" ] && ok "pane_dead=1 -> STATE=dead PANE_DEAD=1" || no "pane_dead=1 -> $row"
out="$( ( export CAPF="$CAPF" PD_ANS=1 PATH="$TMP/bin-pd:$PATH"
  OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; osrc_screen_state p1 cc ) | head -1 )"
[ "$out" = dead ] && ok "osrc_screen_state prints 'dead' for a corpse" || no "osrc_screen_state corpse -> $out"
row="$(pd 0)"; case "$row" in idle\|0) ok "pane_dead=0 -> STATE=idle PANE_DEAD=0" ;; *) no "pane_dead=0 -> $row" ;; esac
row="$(pd FAIL)"; case "$row" in idle\|?*) ok "pane_dead unreadable -> normal state, PANE_DEAD=$row" ;; *) no "pane_dead FAIL -> $row" ;; esac

echo "=== 5. supervise e2e: the incident shapes ==="
fresh 1; own S n1
pane "$FX/unknown-busy-esc.txt" n1
now="$(date +%s)"
scr="$(lib _sv_target_screen n1)"
[ "$(printf '%s\n' "$scr" | head -1)" = working ] \
  && ok "supervise sees the unrecognized busy pane as working (was: unknown -> stalled)" \
  || no "_sv_target_screen busy-unknown -> '$(printf '%s\n' "$scr" | head -1)'"
o="$(obs n1 "$now")"; o2="$(obs n1 "$((now + 30))")"
case "$o$o2" in *stalled*|*failed*) no "busy-unknown pane emitted: $o / $o2" ;;
  *) ok "two polls of the busy-unknown pane emit no stalled/failed event" ;; esac
[ -z "$(kinds n1)" ] && ok "events.jsonl has no rows for the busy-unknown lane" || no "events for n1: $(kinds n1)"

fresh 2; own S n2
pane "$FX/unknown-busy-stale.txt" n2
now="$(date +%s)"
obs n2 "$now" >/dev/null; o="$(obs n2 "$((now + 1))")"
case "$o" in stalled\|*) ok "a genuinely unrecognized frozen screen still stalls: ${o#*|}" ;;
  *) no "real stall hidden by the noise fix: $o" ;; esac
k2="$(kinds n2)"; case "$k2" in *stalled*) ok "stalled row logged for the frozen pane" ;; *) no "no stalled row: '$k2'" ;; esac

# A working screen that stops changing is the other real stall: freeze cx-working, STALL=0.
fresh 3; own S n3
pane "$FX/cx-working.ansi" n3
now="$(date +%s)"
OSRC_SUPERVISE_STALL=0 o="$(obs n3 "$now")"
case "$o" in stalled\|*) ok "frozen working screen still reports stalled (noise fix did not blunt it)" ;;
  *) no "frozen working pane: $o" ;; esac
unset OSRC_SUPERVISE_STALL

fresh 4; own S n4
pane "$FX/cx-working.ansi" n4
now="$(date +%s)"
obs n4 "$now" >/dev/null                                   # alive once: hash recorded
cp "$FX/cx-limit-usage.ansi" "$TMP/panes/n4.screen"        # state change: working -> limit
o="$(obs n4 "$((now + 1))")"
case "$o" in limit\|*) ok "working -> limit transition emits EVENT limit" ;; *) no "transition: $o" ;; esac
o="$(obs n4 "$((now + 2))")"; o="$(obs n4 "$((now + 3))")"
[ "$(kinds n4 | tr -d ' ')" = "limit" ] \
  && ok "limit reported exactly once; re-observation dedupes (state file = restart-safe)" \
  || no "limit rows: '$(kinds n4)' (obs: $o)"
jq -e 'select(.target=="n4" and .kind=="limit") | .detail | test("usage limit")' "$OSRC_HOME/lanes/events.jsonl" >/dev/null 2>&1 \
  && ok "limit event detail carries the banner" || no "limit detail missing banner"

fresh 5; own S n5
pane "$FX/cx-working.ansi" n5
now="$(date +%s)"
obs n5 "$now" >/dev/null                                   # alive once
rm -f "$TMP/panes/n5.screen"                               # pane dies: has-session fails
o="$(obs n5 "$((now + 1))")"
case "$o" in failed\|*) ok "vanished pane reports failed once: ${o#*|}" ;; *) no "gone pane: $o" ;; esac
o="$(obs n5 "$((now + 2))")"; o="$(obs n5 "$((now + 3))")"
[ "$(kinds n5 | tr -d ' ')" = "failed" ] \
  && ok "failed reported exactly once inside the dedupe window" \
  || no "failed rows: '$(kinds n5)'"

echo "=== done: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
