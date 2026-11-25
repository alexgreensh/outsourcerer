#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_screen_alerts.sh -- alerts people can trust (lane osrc-l3). The incident: 962 of 1,024
# "stalled" events were a healthy agent whose screen format the reader did not know; dead panes
# re-reported `failed` for hours; real rate-limit screens hid inside the noise.
#   1. provider refusals classify `limit` with the stated reset, exactly (cc, codex, devin, agy, generic)
#   2. text outside the bottom status region (tool output, todos, prose, older turns) never does
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

nolim() { local row; row="$(scr "$1" "$2")"; case "$row" in limit\|*) no "$3 -> false limit: $row" ;; *) ok "$3 -> ${row%%|*}" ;; esac; }

echo "=== 1. refusals -> limit, with the reset when one is shown ==="
want "$FX/cc-limit-usage.ansi" cc 'limit|*reset: reset at 3pm (epoch *' "claude usage-limit banner"
want "$FX/cx-limit-usage.ansi" codex 'limit|*reset: Try again at 22:28 (epoch *' "codex usage-limit banner"
want "$FX/dv-limit-plan.ansi" devin 'limit|*reset: resets in 1h 5m' "devin plan-limit banner"
want "$SFX/agy-quota-reached.txt" agy 'limit|*reset: Resets in 1h13m1s' "antigravity individual-quota banner"
want "$SFX/agy-retry-backoff.txt" agy 'limit|*reset: Retrying in 42s' "antigravity retry-backoff banner"
want "$FX/generic-limit.txt" "" 'limit|*reset: try again in 30s' "generic rate-limit banner"
for spec in cc-limit-usage.ansi cx-limit-usage.ansi dv-limit-plan.ansi; do
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
# Claude: a `⎿` limit-reached row is a limit when it is the LAST content row above the composer,
# whatever sits above it (round-4 review P1, P2 3). Hand-built frames, not live captures.
CC_FOOT=('' '────────' '❯ ' '────────' '  ⏸ manual mode on'); CX_FOOT=('› Ask Codex to do anything' '  ← for agents · ? for shortcuts')
txt() { printf '%s\n' "$@" > "$TMP/s.txt"; }
for b in '5-hour limit reached ∙ resets 3pm' 'Weekly limit reached ∙ resets Oct 9, 10am' 'Opus weekly limit reached ∙ resets Oct 9, 10am' \
         'Session limit reached ∙ resets 3pm' "You've hit your limit · resets 3pm (Europe/Paris)" 'Claude usage limit reached. Your limit will reset at 3pm.'; do
  txt '❯ continue the refactor' "  ⎿  $b" "${CC_FOOT[@]}"
  want "$TMP/s.txt" cc "limit|*" "claude banner under the prompt: $b"
done
B='  ⎿  5-hour limit reached ∙ resets 3pm'
txt '❯ refactor the client so that every call' '  backs off and retries with jitter' "$B" "${CC_FOOT[@]}"
want "$TMP/s.txt" cc 'limit|*5-hour*' "claude banner under a wrapped prompt"
txt '❯ run it' '⏺ Running the suite now.' '  ⎿  Weekly limit reached ∙ resets Oct 9, 10am' "${CC_FOOT[@]}"
want "$TMP/s.txt" cc 'limit|*Weekly*' "claude banner mid-turn after a ⏺ reply"
txt '❯ run it' '⏺ Bash(make test)' '  ⎿  12 passed, 0 failed' '' "$B" "${CC_FOOT[@]}"
want "$TMP/s.txt" cc 'limit|*5-hour*' "claude banner after a tool block"
txt '❯ why does it say "5-hour limit reached ∙ resets 3pm"?' '⏺ That is the plan banner; it clears at the reset.' "${CC_FOOT[@]}"
nolim "$TMP/s.txt" cc "quoted banner in the prompt, turn continues below"
txt '❯ continue' "$B" '⏺ Resumed after the reset. All 12 tests pass.' "${CC_FOOT[@]}"
nolim "$TMP/s.txt" cc "old banner with a later reply below it"

echo "=== 2. mentions that are not refusals never classify limit ==="
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
for tail in 'sync complete|$' 'checks pass'; do   # an expired refusal: output (and a prompt) under it
  txt '$ worker --sync' '⚠ Rate limit exceeded. Try again in 30s' 'retry 1 ok' 'fetched 40 items' 'wrote cache' "${tail%%|*}" "${tail#*|}"
  nolim "$TMP/s.txt" "" "expired refusal, then output ending '${tail#*|}'"
done
# Claude's `API Error: 429` under a bullet is not a limit banner (supervise's api-error banner owns it)
txt '❯ run the suite' '⏺ Starting the run.' '  ⎿  API Error: 429 Too Many Requests · rate_limit_error' "${CC_FOOT[@]}"
nolim "$TMP/s.txt" cc "claude API Error 429 under a bullet"
# round-3 review P2 2/3: a `⎿` row under any tool call is that tool's output; a count is not a 429
for c in '● Bash(make probe)|Error: rate limit exceeded for key demo' '● Bash(make probe)|Error: rate limit exceeded' \
         '⏺ github - list_issues (MCP)(owner: "acme")|Error: API rate limit exceeded for installation'; do
  txt '❯ probe it' "${c%%|*}" "  ⎿  ${c#*|}" "${CC_FOOT[@]}"; nolim "$TMP/s.txt" cc "tool output: $c"
done
for c in 'error[E0308]: mismatched types at src/main.rs:429:13' 'warning: 429 packages are looking for funding'; do
  txt 'make' "$c"; nolim "$TMP/s.txt" "" "not a 429: $c"
done

echo "=== 3. busy row vs refusal: the newer one wins ==="
# round-3 review P1: a todo row under Claude's spinner is the turn's plan, not a banner
for todo in '☐ Handle rate limit exceeded errors' '☒ Retry on 429' 'Next: Return 429 too many requests from the stub'; do
  txt '❯ fix the client' '✻ Fixing the client… (esc to interrupt · ctrl+t to hide todos)' "  ⎿  $todo" "${CC_FOOT[@]}"
  want "$TMP/s.txt" cc 'working|*Fixing the client*' "todo row under the spinner: $todo"
done
want "$FX/generic-spinner-then-limit.txt" "" 'limit|*Rate limit exceeded*' "spinner, then refusal"
want "$FX/generic-limit-then-spinner.txt" "" 'working|*Syncing*' "refusal, then a newer spinner"
want "$FX/generic-limit-under-approval.txt" "" 'approval|*' "live approval prompt under a refusal"

echo "=== 4. busy only from the engine's indicator in the bottom region ==="
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
# round-3 review P2 4: a bullet ending in an ellipsis is prose, above a shell prompt the lane is idle
txt '● Done. See the notes...' 'user@host:~$'
want "$TMP/s.txt" "" 'idle|*' "'● Done. See the notes...' above a shell prompt"
# round-3 review P3: an interrupt hint in prose is not the engine's busy indicator
txt 'README: press esc to interrupt a run' 'row one' 'row two' 'row three' 'row four' 'row five'
row="$(scr "$TMP/s.txt" "")"; case "$row" in working\|*) no "prose interrupt hint read as busy: $row" ;; *) ok "prose interrupt hint is not busy -> ${row%%|*}" ;; esac
# round-4 review P2 2: a tall footer (no rule, or a rule above seven rows) keeps the spinner in view
SPIN='⠋ Pondering the next move… (esc to interrupt · 14s)'
txt 'claiming shard 12' "$SPIN" 'model: fast-lane | ctx 44%' 'uptime 03:12 | load 0.42' 'jobs 3 running · 1 queued'
want "$TMP/s.txt" "" 'working|*Pondering*' "spinner above three status rows, no rule"
txt 'claiming shard 12' "$SPIN" '────────' 'f1' 'f2' 'f3' 'f4' 'f5' 'f6' 'f7'
want "$TMP/s.txt" "" 'working|*Pondering*' "spinner above a rule and seven footer rows"
# round-4 review P3: the hint must end the row, as the engine's own indicator does
for c in 'make all|Tip (press ctrl+c to interrupt a run)' 'keys · esc to interrupt · q to quit|user@host:~$'; do
  txt 'log' "${c%%|*}" "${c#*|}"
  row="$(scr "$TMP/s.txt" "")"; case "$row" in working\|*) no "hint inside prose read as busy: $c -> $row" ;; *) ok "hint inside prose is not busy: $c -> ${row%%|*}" ;; esac
done

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
