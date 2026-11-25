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
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"
FX="$SCRIPT_DIR/fixtures/screen"; SFX="$SCRIPT_DIR/fixtures/supervise"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-screen-alerts.XXXXXX")" || { echo "FAIL: no scratch dir" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/panes" "$TMP/home"
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc" OSRC_HEARTBEAT_DISABLED=1 OSRC_SOURCED=1
unset TMUX TMUX_PANE
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
set --; . "$SRC" >/dev/null 2>&1
type _osrc_scr_limit >/dev/null 2>&1 || { echo "FAIL: lib/screen.sh not loaded"; exit 1; }
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
want "$FX/cc-limit-5hour.ansi" cc 'limit|*5-hour limit reached*reset: resets 3pm (epoch *' "claude '5-hour limit reached' banner"

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
nolim "$FX/dv-limit-then-continue.ansi" devin "devin refusal, then '❭ continue please' and a good reply"
# A refusal must be the newest row of the turn: wrapped reply lines and an older retried error
# never park a finished lane on `limit` (supervise would never check its done contract).
CC_FOOT=('────────' '❯ ' '────────' '  ⏸ manual mode on'); CX_FOOT=('› Ask Codex to do anything' '  ← for agents · ? for shortcuts')
txt() { printf '%s\n' "$@" > "$TMP/s.txt"; }
txt '❯ make the client back off' '⏺ Done. The client now handles throttling:' '  Rate limit exceeded errors now back off for 30s.' "${CC_FOOT[@]}"
nolim "$TMP/s.txt" cc "claude reply, wrapped line 'Rate limit exceeded errors now back off'"
txt '❯ make the client back off' '⏺ Done. Throttled calls are handled now:' '  Error 429 responses are retried with jitter.' "${CC_FOOT[@]}"
nolim "$TMP/s.txt" cc "claude reply, wrapped line 'Error 429 responses are retried'"
txt '› type the errors' '• Done. Each failure maps to a variant now:' '  Quota exceeded responses become a typed error.' "${CX_FOOT[@]}"
nolim "$TMP/s.txt" codex "codex reply continuation 'Quota exceeded responses become a typed error'"
txt '› run the tests' '⚠ stream error: 429 Too Many Requests; retrying 1/5 in 187ms…' '• All 12 tests pass.' "${CX_FOOT[@]}"
nolim "$TMP/s.txt" codex "codex retried stream error, then a finished reply"
txt '$ ./sync' 'error: upstream returned 429 for /v1/items' 'user@host:~/work$'
nolim "$TMP/s.txt" "" "shell log line with 429 above a shell prompt"
txt '$ worker --sync' '⚠ Rate limit exceeded. Try again in 30s' 'retry 1 ok' 'fetched 40 items' 'wrote cache' 'checks pass' 'sync complete' '$'
nolim "$TMP/s.txt" "" "expired refusal, five rows of output, then a prompt"

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
txt 'release notes' '● Fixed the parser (see commit abc)' 'status: ready'
row="$(scr "$TMP/s.txt" "")"; case "$row" in working\|*) no "bullet with parentheses read as busy: $row" ;; *) ok "bullet with parentheses is not busy -> ${row%%|*}" ;; esac
txt 'cargo build' '[⠋] Compiling crate 12/40' 'target: debug'
want "$TMP/s.txt" "" 'working|*Compiling crate*' "bracketed spinner '[⠋] Compiling crate 12/40'"

echo "=== 5. pane liveness ==="
# fake tmux: panes are files; <pane>.dead holds #{pane_dead}
cat > "$TMP/bin/tmux" <<'EOF'
#!/bin/bash
t=""; for a in "$@"; do [ "$prev" = -t ] && t="$a"; prev="$a"; done
case "$1" in
  capture-pane) [ -f "$FAKE_PANES/$t.screen" ] || exit 1; cat "$FAKE_PANES/$t.screen" ;;
  display-message)
    [ -f "$FAKE_PANES/$t.screen" ] || exit 1
    case "$*" in *pane_dead*) cat "$FAKE_PANES/$t.dead" 2>/dev/null || echo 0 ;; esac ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/tmux"
export PATH="$TMP/bin:$PATH" FAKE_PANES="$TMP/panes"
cp "$FX/cx-working.ansi" "$TMP/panes/p1.screen"; echo 0 > "$TMP/panes/p1.dead"
out="$( set -e; osrc_screen_report p1 codex; echo REACHED )"
case "$out" in *"STATE=working"*"PANE_DEAD=0"*REACHED) ok "osrc_screen_report on a live pane completes under set -e" ;;
  *) no "report under set -e: $(printf '%s' "$out" | tr '\n' ' ')" ;; esac
echo 1 > "$TMP/panes/p1.dead"
out="$(osrc_screen_report p1 codex)"
case "$out" in *"STATE=dead"*"PANE_DEAD=1"*) ok "remain-on-exit corpse with a working frame -> STATE=dead" ;; *) no "corpse report: $out" ;; esac

echo "=== done: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
