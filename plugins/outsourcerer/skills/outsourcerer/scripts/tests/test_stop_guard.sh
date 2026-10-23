#!/usr/bin/env bash
# test_stop_guard.sh — issue #48: Claude Code may not end its turn while runs it launched are still
# going with nothing waiting on them. Covers ownership, the block payload, waiter detection, other
# sessions, loop safety, cleanup, the off switch, and the plugin hook wiring.
# Run: bash test_stop_guard.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"
HOOKS="$SCRIPT_DIR/../../../../hooks/hooks.json"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq is required (the guard and these checks read JSON)"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-sg.XXXXXX")"
PIDS=""
trap 'for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home"; mkdir -p "$OSRC_HOME/jobs"
unset CLAUDE_CODE_SESSION_ID

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
guard() { printf '{"session_id":"%s","stop_hook_active":true}' "$1" | OSRC_STOP_GUARD_MAX="${MAX:-2}" "$SRC" stop-guard 2>"$TMP/err"; }

# A live job: a running worker and supervisor, status running.
mkjob() { # <id>
  local jd="$OSRC_HOME/jobs/$1"; mkdir -p "$jd"
  sleep 300 >/dev/null 2>&1 & local w=$!; sleep 300 >/dev/null 2>&1 & local s=$!; PIDS="$PIDS $w $s"
  echo running > "$jd/status"; echo "$w" > "$jd/pid"; echo "$s" > "$jd/supervisor_pid"; date +%s > "$jd/started"
}

echo "=== launches record their owner ==="
( export OSRC_SOURCED=1 CLAUDE_CODE_SESSION_ID="sess-A"; source "$SRC" >/dev/null 2>&1; _owner_record job-1 )
[ -f "$OSRC_HOME/owners/sess-A/job-1" ] && ok "a launch from a Claude session records the session as owner" || no "no owner record"
( export OSRC_SOURCED=1; source "$SRC" >/dev/null 2>&1; _owner_record job-x )
[ ! -e "$OSRC_HOME/owners/job-x" ] && ok "no session id means no owner record" || no "recorded without a session"
( export OSRC_SOURCED=1 CLAUDE_CODE_SESSION_ID="../evil"; source "$SRC" >/dev/null 2>&1; _owner_record job-2 )
[ ! -e "$TMP/evil" ] && [ -f "$OSRC_HOME/owners/..evil/job-2" ] && ok "a hostile session id cannot escape the owners folder" || no "session id path escape"
rm -rf "$OSRC_HOME/owners"
grep -q '_owner_record "$id"' "$SRC" && grep -q '_owner_record "$_ad_sess"' "$SRC" && grep -q '_owner_record "$SESSION_NAME"' "$SRC" \
  && ok "bg jobs, tmux runs and sessions all record their owner" || no "a launch path does not record its owner"

echo "=== a live run with no waiter blocks the stop ==="
mkjob job-live
mkdir -p "$OSRC_HOME/owners/sess-A"; : > "$OSRC_HOME/owners/sess-A/job-live"
out="$(guard sess-A)"
printf '%s' "$out" | jq -e '.decision=="block"' >/dev/null 2>&1 && ok "the stop is blocked" || no "not blocked: [$out]"
printf '%s' "$out" | jq -r .reason 2>/dev/null | grep -q "wait job-live" && ok "the reason names the exact wait command" || no "reason lacks the wait command"
printf '%s' "$out" | jq -r .reason 2>/dev/null | grep -q "run_in_background" && ok "the reason says to run it in the background" || no "reason lacks run_in_background"

echo "=== other sessions are not blocked ==="
out="$(guard sess-B)"; [ -z "$out" ] && ok "a session that launched nothing ends its turn freely" || no "another session was blocked"

echo "=== loop safety ==="
out="$(guard sess-A)"; printf '%s' "$out" | jq -e '.decision=="block"' >/dev/null 2>&1 && ok "the second stop is still blocked" || no "second stop not blocked"
out="$(guard sess-A)"; [ -z "$out" ] && grep -q "letting the turn end" "$TMP/err" && ok "the same unwaited set is blocked twice, then allowed" || no "third stop still blocked: [$out]"
mkjob job-live2; : > "$OSRC_HOME/owners/sess-A/job-live2"
out="$(guard sess-A)"; printf '%s' "$out" | jq -e '.decision=="block"' >/dev/null 2>&1 && ok "a new run blocks again" || no "a new run did not block"

echo "=== a running wait covers its run ==="
mkdir -p "$TMP/w"; printf '#!/usr/bin/env bash\nsleep 300\n' > "$TMP/w/outsourcerer.sh"; chmod +x "$TMP/w/outsourcerer.sh"
"$TMP/w/outsourcerer.sh" wait job-live >/dev/null 2>&1 & PIDS="$PIDS $!"
"$TMP/w/outsourcerer.sh" wait job-live2 >/dev/null 2>&1 & PIDS="$PIDS $!"
sleep 1
out="$(MAX=9 guard sess-A)"; [ -z "$out" ] && ok "runs with a waiter do not block" || no "blocked despite waiters: [$out]"

echo "=== finished runs are cleaned up ==="
echo done > "$OSRC_HOME/jobs/job-live/status"; echo 0 > "$OSRC_HOME/jobs/job-live/exit"
echo failed > "$OSRC_HOME/jobs/job-live2/status"; echo 1 > "$OSRC_HOME/jobs/job-live2/exit"
out="$(guard sess-A)"
[ -z "$out" ] && [ ! -d "$OSRC_HOME/owners/sess-A" ] && ok "finished runs drop their owner record and the folder goes" || no "owner records left: $(ls -a "$OSRC_HOME/owners/sess-A" 2>/dev/null | tr '\n' ' ')"

echo "=== off switch and bad input ==="
mkjob job-off; mkdir -p "$OSRC_HOME/owners/sess-C"; : > "$OSRC_HOME/owners/sess-C/job-off"
out="$(printf '{"session_id":"sess-C"}' | OSRC_STOP_GUARD=0 "$SRC" stop-guard 2>/dev/null)"
[ -z "$out" ] && ok "OSRC_STOP_GUARD=0 turns the guard off" || no "off switch ignored"
out="$(printf 'not json' | "$SRC" stop-guard 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "unreadable hook input allows the stop" || no "bad input rc=$rc out=[$out]"

echo "=== plugin hook wiring ==="
if [ -f "$HOOKS" ] && jq -e '.hooks.Stop[0].hooks[0].command | test("stop-guard")' "$HOOKS" >/dev/null 2>&1; then
  ok "the plugin registers a Stop hook that runs stop-guard"
else no "no Stop hook in $HOOKS"; fi
jq -r '.hooks.Stop[0].hooks[0].command' "$HOOKS" 2>/dev/null | grep -q 'exit 0' && ok "the hook fails open if the script is missing or errors" || no "hook can fail closed"
out="$(CLAUDE_PLUGIN_ROOT="$TMP/nope" sh -c "$(jq -r '.hooks.Stop[0].hooks[0].command' "$HOOKS")" </dev/null 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "a missing plugin path exits 0" || no "missing plugin path rc=$rc"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
