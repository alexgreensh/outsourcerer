#!/usr/bin/env bash
# test_watchsvc.sh — L1 watchdog: the per-user watcher service (`watcher install|status|run|tick`)
# observes every owner's lanes with no orchestrator session alive, wakes sessions on undelivered
# events exactly once, covers the four incidents: (1) session death leaves lanes unwatched, (2) a
# finished/idle/question lane never wakes its owner, (3) a yielded stop-guard is silent, (4) a
# provider-limit park never resumes. All fakes live under $TMP; nothing touches real home state.
# Run: bash test_watchsvc.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"; FX="$SCRIPT_DIR/fixtures/supervise"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-watchsvc.XXXXXX")" || exit 1
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
PIDS=""
mkdir -p "$TMP/bin" "$TMP/panes" "$TMP/home"
export HOME="$TMP/home" PATH="$TMP/bin:$PATH"
export FAKE_TMUX_DIR="$TMP/panes" OSRC_HEARTBEAT_DISABLED=1 OSRC_BLIND_TURN_GUARD=0 OSRC_STREAM=1
export OSRC_CLAUDE_PROJECTS_DIR="$TMP/projects" OSRC_CLAUDE_SESSIONS_DIR="$TMP/ccsessions"
export OSRC_SUPERVISE_TICK_SECS=86400 OSRC_SEND_VERIFY_SECS=1 OSRC_SEND_VERIFY_POLLS=2
export OSRC_SUPERVISE_CONFIRM=0 OSRC_SUPERVISE_SETTLE=0 OSRC_SUPERVISE_POLL=1
export OSRC_WATCH_NOTIFY=0 OSRC_WATCH_REWAKE=1 OSRC_WATCH_WAKE_MAX=2
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID OSRC_NOW OSRC_WATCH_BACKEND OSRC_WATCH_DELIVER_CMD OSRC_WATCH_INJECT
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

# --- fakes -----------------------------------------------------------------------------------------
# tmux: pane = $FAKE_TMUX_DIR/<target>.screen; send-keys appends its args to keys.log AND the
# screen (so session send's proof-poll sees the text land). display-message answers pane liveness.
cat > "$TMP/bin/tmux" <<'EOF'
#!/bin/bash
D="${FAKE_TMUX_DIR:?}"; cmd="$1"; shift; all="$*"; t=""
while [ "$#" -gt 0 ]; do case "$1" in -t) t="$2"; shift 2 ;; *) shift ;; esac; done
t="${t#=}"; t="${t%%:*}"
case "$cmd" in
  has-session) [ -f "$D/$t.screen" ] ;;
  capture-pane) [ -f "$D/$t.screen" ] && cat "$D/$t.screen" ;;
  display-message) [ -f "$D/$t.screen" ] && { echo "%$t"; exit 0; } || exit 1 ;;
  send-keys) echo "send-keys $t :: $all" >> "$D/keys.log"; printf '%s\n' "$all" >> "$D/$t.screen" 2>/dev/null; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/tmux"
# claude: `agents --json` answers FAKE_CLAUDE_AGENTS; anything else is logged and exits FAKE_CLAUDE_RC.
cat > "$TMP/bin/claude" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "agents" ]; then printf '%s' "${FAKE_CLAUDE_AGENTS:-[]}"; exit 0; fi
echo "claude $*" >> "${FAKE_CLAUDE_LOG:-/dev/null}"; exit "${FAKE_CLAUDE_RC:-0}"
EOF
chmod +x "$TMP/bin/claude"
# wake notifier: the OSRC_WATCH_DELIVER_CMD contract (summary $1, event JSON on stdin).
cat > "$TMP/bin/osrc-wake" <<'EOF'
#!/bin/bash
echo "wake|$1|$(cat)" >> "${FAKE_WAKE_LOG:?}"
EOF
chmod +x "$TMP/bin/osrc-wake"
# launchctl / systemctl fakes: record argv, behave just enough for install/uninstall.
cat > "$TMP/bin/launchctl" <<'EOF'
#!/bin/bash
echo "launchctl $*" >> "${FAKE_SVC_LOG:?}"
case "$1" in bootout|unload) exit 0 ;; bootstrap|load|print) exit 0 ;; *) exit 0 ;; esac
EOF
cat > "$TMP/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "${FAKE_SVC_LOG:?}"
case "$*" in *show-environment*) exit 0 ;; *) exit 0 ;; esac
EOF
chmod +x "$TMP/bin/launchctl" "$TMP/bin/systemctl"
# osascript / notify-send: record instead of notifying.
cat > "$TMP/bin/osascript" <<'EOF'
#!/bin/bash
echo "osascript $*" >> "${FAKE_NOTIF_LOG:-/dev/null}"; exit 0
EOF
cat > "$TMP/bin/notify-send" <<'EOF'
#!/bin/bash
echo "notify-send $*" >> "${FAKE_NOTIF_LOG:-/dev/null}"; exit 0
EOF
chmod +x "$TMP/bin/osascript" "$TMP/bin/notify-send"
export FAKE_SVC_LOG="$TMP/svc.log" FAKE_NOTIF_LOG="$TMP/notif.log" FAKE_WAKE_LOG="$TMP/wakes.log" FAKE_CLAUDE_LOG="$TMP/claude.log"

fresh() { # <name>: isolated OSRC_HOME + fresh supervise tick stamps + pane dir
  export OSRC_HOME="$TMP/h_$1"; mkdir -p "$OSRC_HOME/jobs" "$OSRC_HOME/sessions" "$OSRC_HOME/owners" "$OSRC_HOME/lanes/state"
  rm -f "$TMP/panes"/*.screen "$TMP/panes"/keys.log "$TMP/wakes.log" "$TMP/claude.log" "$TMP/notif.log"
  for s in S N; do mkdir -p "$OSRC_HOME/supervise/$s"; date +%s > "$OSRC_HOME/supervise/$s/tick.time"; done
}
own() { mkdir -p "$OSRC_HOME/owners/$1"; : > "$OSRC_HOME/owners/$1/$2"; }
pane() { cp "$FX/$2" "$TMP/panes/$1.screen"; }
tick() { nice -n 19 "$SRC" watcher tick >/dev/null 2>&1; }
settle() { local i; for i in $(seq 1 40); do [ ! -f "$OSRC_HOME/watchsvc/$1/wake.job" ] && return 0; sleep 0.25; done; return 1; }

echo "=== status / install / uninstall ==="
fresh svc
out="$(nice -n 19 "$SRC" watcher status 2>&1)"
grep -q 'coverage: NONE' <<<"$out" && ok "status on empty home reports no coverage" || no "status: $out"
OSRC_WATCH_BACKEND=fallback nice -n 19 "$SRC" watcher install >/dev/null 2>&1
for i in $(seq 1 40); do [ -f "$OSRC_HOME/watchsvc/alive" ] && break; sleep 0.25; done
[ -f "$OSRC_HOME/watchsvc/alive" ] && ok "fallback install arms a daemon that ticks (alive stamp)" || no "fallback install: no alive stamp"
grep -q '"backend":"fallback"' "$OSRC_HOME/watchsvc/install.json" && ok "install.json records backend=fallback" || no "install.json missing"
out="$(nice -n 19 "$SRC" watcher status 2>&1)"; grep -q 'coverage: live' <<<"$out" && ok "status reports live coverage" || no "status after install: $out"
# second `watcher run` must refuse (single instance)
nice -n 19 "$SRC" watcher run >"$TMP/run2.out" 2>&1 & R2=$!; PIDS="$PIDS $R2"; sleep 1.5
grep -q 'already running' "$TMP/run2.out" && ok "second watcher run refused by run.lock" || no "single-instance lock not honored: $(cat "$TMP/run2.out")"
kill "$R2" 2>/dev/null
OSRC_WATCH_BACKEND=fallback nice -n 19 "$SRC" watcher uninstall >/dev/null 2>&1
sleep 0.5; [ ! -f "$OSRC_HOME/watchsvc/install.json" ] && ok "uninstall removes install.json" || no "uninstall left install.json"

echo "=== launchd / systemd install shapes (fake service managers) ==="
fresh svc2
OSRC_WATCH_BACKEND=launchd OSRC_WATCH_LAUNCHD_DIR="$TMP/lagents" nice -n 19 "$SRC" watcher install >/dev/null 2>&1
[ -f "$TMP/lagents/com.outsourcerer.watchd.plist" ] && grep -q 'watcher' "$TMP/lagents/com.outsourcerer.watchd.plist" && ok "launchd plist written with watcher run" || no "launchd plist missing"
grep -q 'bootstrap' "$FAKE_SVC_LOG" && ok "launchctl bootstrap invoked" || no "launchctl bootstrap not invoked"
OSRC_WATCH_BACKEND=launchd OSRC_WATCH_LAUNCHD_DIR="$TMP/lagents" nice -n 19 "$SRC" watcher uninstall >/dev/null 2>&1
[ ! -f "$TMP/lagents/com.outsourcerer.watchd.plist" ] && ok "launchd uninstall removes plist" || no "plist survived uninstall"
: > "$FAKE_SVC_LOG"
fresh svc3
OSRC_WATCH_BACKEND=systemd OSRC_WATCH_SYSTEMD_DIR="$TMP/systemd" nice -n 19 "$SRC" watcher install >/dev/null 2>&1
[ -f "$TMP/systemd/outsourcerer-watch.service" ] && grep -q 'watcher run' "$TMP/systemd/outsourcerer-watch.service" && ok "systemd user unit written" || no "systemd unit missing"
grep -q 'enable --now' "$FAKE_SVC_LOG" && ok "systemctl enable --now invoked" || no "systemctl enable missing"
OSRC_WATCH_BACKEND=systemd OSRC_WATCH_SYSTEMD_DIR="$TMP/systemd" nice -n 19 "$SRC" watcher uninstall >/dev/null 2>&1
[ ! -f "$TMP/systemd/outsourcerer-watch.service" ] && ok "systemd uninstall removes unit" || no "unit survived uninstall"

echo "=== incident 1: watcher observes with NO session alive ==="
fresh obs; own S i1; pane i1 cc-working-turn.txt
tick; tick   # first baselines, second sees the working->question transition below
cp "$FX/cc-question-live.txt" "$TMP/panes/i1.screen"; tick
grep -q '"kind":"question"' "$OSRC_HOME/lanes/events.jsonl" && grep -q '"target":"i1"' "$OSRC_HOME/lanes/events.jsonl" \
  && ok "tick logs a question event for owned lane with zero sessions" || no "no question event in log"
[ -f "$OSRC_HOME/watchsvc/alive" ] && ok "tick stamps watcher liveness" || no "no alive stamp"
# zero tokens while nothing needs delivery: claude was never invoked for a wake
[ ! -s "$FAKE_CLAUDE_LOG" ] && ok "no agent CLI invoked while nothing is pending" || no "claude invoked: $(cat "$FAKE_CLAUDE_LOG")"

echo "=== incident 2: undelivered event wakes the owner exactly once ==="
fresh wake; own S w1; pane w1 cc-question-live.txt
export OSRC_WATCH_DELIVER_CMD=osrc-wake
tick; settle S
# the spawn happens inside the same tick that sees the row; give the deliverer a beat then settle
for i in $(seq 1 40); do [ -s "$FAKE_WAKE_LOG" ] && break; tick; settle S; sleep 0.2; i2=$i; [ "${i2:-0}" -ge 6 ] && break; done
[ "$(grep -c . "$FAKE_WAKE_LOG" 2>/dev/null || echo 0)" = 1 ] && grep -q 'question:w1' "$FAKE_WAKE_LOG" \
  && ok "pending question event delivered one wake" || no "wake log: $(cat "$FAKE_WAKE_LOG" 2>/dev/null)"
tick; settle S; tick; settle S
[ "$(grep -c . "$FAKE_WAKE_LOG" 2>/dev/null || echo 0)" = 1 ] && ok "no duplicate wake while event stays resolved-in-ledger" || no "duplicate wake: $(cat "$FAKE_WAKE_LOG")"
# an unresolved event re-wakes on its reminder row (OSRC_WATCH_REWAKE=1s)
det="$(jq -r 'select(.kind=="question" and .target=="w1") | .detail' "$OSRC_HOME/lanes/events.jsonl" | head -1)"
now="$(date +%s)"
jq -cn --argjson ts "$now" --arg d "still unresolved, waiting 20m: $det" \
  '{id:"rem1",ts:$ts,kind:"question",target:"w1",detail:$d,next:"-",src:"supervise",owner:"S"}' >> "$OSRC_HOME/lanes/events.jsonl"
tick; settle S
for i in $(seq 1 20); do [ "$(grep -c . "$FAKE_WAKE_LOG" 2>/dev/null || echo 0)" -ge 2 ] && break; sleep 0.25; done
[ "$(grep -c . "$FAKE_WAKE_LOG" 2>/dev/null || echo 0)" -ge 2 ] && ok "still-unresolved reminder re-wakes after REWAKE window" || no "no re-wake: $(cat "$FAKE_WAKE_LOG")"

echo "=== covered by a live waiter: no wake; waiter death re-arms delivery ==="
fresh cov; own S c1; pane c1 cc-question-live.txt
export OSRC_WATCH_DELIVER_CMD=osrc-wake
# fake a live supervise for S: armed.* file + a process whose cmdline contains 'supervise'
mkdir -p "$OSRC_HOME/supervise/S"; printf '#!/bin/bash\nsleep 30\n' > "$TMP/bin/osrc-supervise-fake"; chmod +x "$TMP/bin/osrc-supervise-fake"
"$TMP/bin/osrc-supervise-fake" & FP=$!; PIDS="$PIDS $FP"; sleep 0.3
printf '*\n' > "$OSRC_HOME/supervise/S/armed.$FP"
tick; settle S
[ ! -s "$FAKE_WAKE_LOG" ] && ok "live supervise coverage suppresses the service wake" || no "wake fired under coverage: $(cat "$FAKE_WAKE_LOG")"
kill "$FP" 2>/dev/null; sleep 0.3; rm -f "$OSRC_HOME/supervise/S"/armed.*
# next reminder row for the same event -> covered->pend -> wake
det="$(jq -r 'select(.kind=="question" and .target=="c1") | .detail' "$OSRC_HOME/lanes/events.jsonl" | head -1)"
jq -cn --argjson ts "$(date +%s)" --arg d "still unresolved, waiting 20m: $det" \
  '{id:"remc",ts:$ts,kind:"question",target:"c1",detail:$d,next:"-",src:"supervise",owner:"S"}' >> "$OSRC_HOME/lanes/events.jsonl"
tick; settle S
for i in $(seq 1 20); do [ -s "$FAKE_WAKE_LOG" ] && break; sleep 0.25; done
[ -s "$FAKE_WAKE_LOG" ] && ok "waiter death -> next reminder delivers the wake" || no "no wake after waiter died"

echo "=== claude channel: closed session injected, running session never is ==="
fresh inj; own S j1; pane j1 cc-question-live.txt
unset OSRC_WATCH_DELIVER_CMD
export FAKE_CLAUDE_AGENTS='[]'   # session provably not running -> claude --bg/--resume may inject
for i in $(seq 1 20); do tick; settle S; grep -q -- '--resume' "$FAKE_CLAUDE_LOG" 2>/dev/null && break; sleep 0.2; done
grep -q -- '--resume' "$FAKE_CLAUDE_LOG" 2>/dev/null && ok "closed session got a claude resume wake" || no "claude log: $(cat "$FAKE_CLAUDE_LOG" 2>/dev/null)"
SIDINJ="$(grep -o -- '--resume [^ ]*' "$FAKE_CLAUDE_LOG" 2>/dev/null | head -1)"
[ -n "$SIDINJ" ] && ok "resume targeted a session id ($SIDINJ)" || no "no resume line"
# now the same shape but the session is RUNNING per claude agents -> must defer, never inject
fresh run; own S j2; pane j2 cc-question-live.txt
export FAKE_CLAUDE_AGENTS="[{\"sessionId\":\"S\"}]"
for i in $(seq 1 10); do tick; settle S; sleep 0.2; done
sleep 0.5
grep -q -- '--resume' "$FAKE_CLAUDE_LOG" 2>/dev/null && no "running session was injected: $(cat "$FAKE_CLAUDE_LOG")" \
  || ok "running session never injected (deferred instead)"
grep -q 'deferred' "$OSRC_HOME/watchsvc/S/woken" 2>/dev/null && ok "deferred state recorded in wake ledger" || no "no deferred ledger entry"

echo "=== incident 4: provider-limit lanes auto-continue once per reset ==="
fresh lim; own S l1 l2 l3
now="$(date +%s)"
for l in l1 l2 l3; do cp "$FX/cc-working-turn.txt" "$TMP/panes/$l.screen"; done
# l1: limit event whose reset already passed; state says still limit-parked
jq -cn --argjson ts "$((now-120))" --arg d "plan limit hit: usage limit · resets in 1m" \
  '{id:"lim1",ts:$ts,kind:"limit",target:"l1",detail:$d,next:"-",src:"supervise",owner:"S"}' >> "$OSRC_HOME/lanes/events.jsonl"
printf -- '- 0 - - 0 limit:abc 1\n' > "$OSRC_HOME/lanes/state/l1"
# l2: limit event but state is NOT limit-parked -> must not be touched
jq -cn --argjson ts "$((now-120))" --arg d "plan limit hit: usage limit · resets in 1m" \
  '{id:"lim2",ts:$ts,kind:"limit",target:"l2",detail:$d,next:"-",src:"supervise",owner:"S"}' >> "$OSRC_HOME/lanes/events.jsonl"
printf -- '- 0 - - 0 working:abc 1\n' > "$OSRC_HOME/lanes/state/l2"
# l3: limit event whose reset is still in the future -> must wait
ep=$((now+7200))
jq -cn --argjson ts "$now" --arg d "Antigravity quota reached, resets 23:59 (epoch $ep)" \
  '{id:"lim3",ts:$ts,kind:"limit",target:"l3",detail:$d,next:"-",src:"supervise",owner:"S"}' >> "$OSRC_HOME/lanes/events.jsonl"
printf -- '- 0 - - 0 limit:xyz 1\n' > "$OSRC_HOME/lanes/state/l3"
unset OSRC_WATCH_DELIVER_CMD
export OSRC_WATCH_LIMIT_AUTO=1
tick
grep -q 'send-keys l1' "$TMP/panes/keys.log" && ok "past-reset limit lane got session send continue" || no "keys.log: $(cat "$TMP/panes/keys.log" 2>/dev/null)"
grep -q 'continue' "$TMP/panes/keys.log" && ok "continue text reached the lane" || no "no continue in keys.log"
! grep -q 'send-keys l2' "$TMP/panes/keys.log" && ok "non-limit-parked lane untouched" || no "l2 was sent input"
! grep -q 'send-keys l3' "$TMP/panes/keys.log" && ok "future-reset lane waits for its epoch" || no "l3 fired early"
tick   # second pass: l1's epoch already served -> no resend
n1="$(grep -c 'send-keys l1' "$TMP/panes/keys.log" 2>/dev/null || echo 0)"
[ "$n1" -le 2 ] && ok "limit resume is once per reset epoch (no resend loop)" || no "l1 resent ($n1 send-keys)"
[ -f "$OSRC_HOME/lanes/state/l1.limitresume" ] && ok "limitresume marker records the served epoch" || no "no limitresume marker"
grep -q '"kind":"limit-resumed"' "$OSRC_HOME/lanes/events.jsonl" && ok "limit-resumed logged to the durable event log" || no "no limit-resumed event"

echo "=== incident 3: delivery failure is loud, not silent ==="
fresh fail; own S f1; pane f1 cc-question-live.txt
export OSRC_WATCH_DELIVER_CMD=false OSRC_WATCH_WAKE_MAX=1
tick; settle S; tick; settle S   # spawn fails -> settle marks failed (max=1) -> .wakefail
for i in $(seq 1 20); do [ -f "$OSRC_HOME/owners/S/.wakefail" ] && break; tick; settle S; sleep 0.2; done
[ -s "$OSRC_HOME/owners/S/.wakefail" ] && ok ".wakefail written after delivery attempts exhausted" || no "no .wakefail"
out="$(OSRC_SOURCED=1 CLAUDE_CODE_SESSION_ID=S; . "$SRC" >/dev/null 2>&1; _sg_print_unguarded 2>&1)"
grep -q 'wake' <<<"$out" && ok "stop-guard print surfaces the delivery failure" || no "unguarded print empty: $out"
n="$(OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _osrc_watch_pending S 2>/dev/null)"
[ -n "$n" ] && [ "$n" -ge 1 ] && ok "pending wakes counted for status/guard ($n)" || no "pending count empty"
out="$(nice -n 19 "$SRC" watcher status 2>&1)"; grep -q 'failed_deliveries=1' <<<"$out" && ok "watcher status reports the failed delivery" || no "status: $out"

echo "=== watcher run loop: stamps, idles cheaply, stops cleanly ==="
fresh loop; own S z1; pane z1 cc-working-turn.txt
OSRC_WATCH_INTERVAL=5 nice -n 19 "$SRC" watcher run >/dev/null 2>&1 & RP=$!; PIDS="$PIDS $RP"
for i in $(seq 1 40); do [ -f "$OSRC_HOME/watchsvc/alive" ] && break; sleep 0.25; done
[ -f "$OSRC_HOME/watchsvc/alive" ] && ok "watcher run daemon ticks and stamps" || no "daemon never stamped"
cp "$FX/cc-question-live.txt" "$TMP/panes/z1.screen"; sleep 6
grep -q '"kind":"question"' "$OSRC_HOME/lanes/events.jsonl" && ok "daemon observes state changes between ticks" || no "daemon missed the transition"
kill "$RP" 2>/dev/null; sleep 0.5
a1="$(cat "$OSRC_HOME/watchsvc/alive" 2>/dev/null)"; sleep 6; a2="$(cat "$OSRC_HOME/watchsvc/alive" 2>/dev/null)"
[ "$a1" = "$a2" ] && ok "dead daemon stops stamping (coverage expires)" || no "stamp kept moving after kill"

echo ""
echo "watchsvc: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
