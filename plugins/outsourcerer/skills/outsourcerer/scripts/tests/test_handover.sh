#!/usr/bin/env bash
# test_handover.sh — session handover: `adopt` moves a previous orchestrator session's
# owned targets into the current session; `handover` writes the markdown brief the next
# session picks the fleet up with. Covers the owners/ registry move, refusals, the
# .stop-blocks carve-out, duplicate markers, kind/state/model/cwd resolution (job,
# autodetach tmux marker, remote/<id>.json), and the wait-command rules.
# Run: bash test_handover.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
bash -n "$SCRIPT_DIR/../lib/handover.sh" || { echo "FAIL: bash -n lib/handover.sh failed"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-ho.XXXXXX")"
PIDS=""
trap 'for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home"; mkdir -p "$OSRC_HOME/jobs" "$OSRC_HOME/owners"
unset CLAUDE_CODE_SESSION_ID

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

# A live job, same shape test_stop_guard uses: running status + live worker/supervisor pids.
mkjob() { # <id> [meta-json]
  local jd="$OSRC_HOME/jobs/$1"; mkdir -p "$jd"
  sleep 300 >/dev/null 2>&1 & local w=$!; sleep 300 >/dev/null 2>&1 & local s=$!; PIDS="$PIDS $w $s"
  echo running > "$jd/status"; echo "$w" > "$jd/pid"; echo "$s" > "$jd/supervisor_pid"; date +%s > "$jd/started"
  [ -n "${2:-}" ] && printf '%s' "$2" > "$jd/meta.json"
}

echo "=== adopt --list ==="
mkdir -p "$OSRC_HOME/owners/old-one" "$OSRC_HOME/owners/old-two"
: > "$OSRC_HOME/owners/old-one/job-a"; : > "$OSRC_HOME/owners/old-one/job-b"
: > "$OSRC_HOME/owners/old-two/sess-c"
: > "$OSRC_HOME/owners/old-one/.stop-blocks"
out="$(CLAUDE_CODE_SESSION_ID=who-ever "$SRC" adopt --list 2>/dev/null)"
grep -q $'^old-one\t2\t' <<<"$out" && ok "--list counts target files (dotfiles excluded)" \
  || no "--list row wrong: [$out]"
grep -q $'^old-two\t1\t' <<<"$out" && ok "--list covers every owners dir" \
  || no "--list missing old-two: [$out]"
grep -q '20[0-9][0-9]-' <<<"$out" && ok "--list prints a human newest-mtime" \
  || no "--list mtime column missing: [$out]"

echo "=== adopt moves targets into the current session ==="
out="$(CLAUDE_CODE_SESSION_ID=new-sess "$SRC" adopt old-one 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] && [ -f "$OSRC_HOME/owners/new-sess/job-a" ] && [ -f "$OSRC_HOME/owners/new-sess/job-b" ] \
  && ok "adopt moved every target file to owners/<current>/" || no "targets not moved (rc=$rc): [$out]"
[ -f "$OSRC_HOME/owners/old-one/.stop-blocks" ] && [ ! -e "$OSRC_HOME/owners/old-one/job-a" ] \
  && ok ".stop-blocks stayed with the old session (its dir remains for it)" \
  || no ".stop-blocks handling wrong: $(ls -a "$OSRC_HOME/owners/old-one" 2>/dev/null | tr '\n' ' ')"
grep -q 'job-a' <<<"$out" && grep -q 'job-b' <<<"$out" \
  && ok "adopt prints what moved" || no "moved ids not printed: [$out]"

echo "=== adopt edge cases ==="
out="$(CLAUDE_CODE_SESSION_ID=new-sess "$SRC" adopt new-sess 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qi 'already the current' <<<"$out" \
  && ok "adopt refuses old == current" || no "same-session adopt not refused (rc=$rc): [$out]"
out="$(CLAUDE_CODE_SESSION_ID=new-sess "$SRC" adopt no-such-sid 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qi 'no owners dir' <<<"$out" \
  && ok "adopt refuses a session with no owners dir" || no "missing dir not refused (rc=$rc): [$out]"
out="$(env -u CLAUDE_CODE_SESSION_ID "$SRC" adopt old-two 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qi 'no current session' <<<"$out" \
  && ok "adopt refuses with no current session id" || no "no-sid adopt not refused (rc=$rc): [$out]"
out="$(CLAUDE_CODE_SESSION_ID=new-sess "$SRC" adopt '../evil' 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$TMP/evil" ] \
  && ok "a hostile session id cannot escape owners/" || no "path escape via adopt (rc=$rc): [$out]"

# '.'/'..' survive tr but owners/.. IS the state home: adopt must refuse them and touch nothing.
printf 'sentinel\n' > "$OSRC_HOME/zz-sentinel"
for bad in '.' '..' '.hidden-sid'; do
  out="$(CLAUDE_CODE_SESSION_ID=new-sess "$SRC" adopt "$bad" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "adopt refuses '$bad'" || no "adopt '$bad' not refused (rc=$rc): [$out]"
done
[ -f "$OSRC_HOME/zz-sentinel" ] && [ ! -e "$OSRC_HOME/owners/new-sess/zz-sentinel" ] \
  && ok "a refused dot-id adopt moved no state-home files" \
  || no "state home was touched by a dot-id adopt"

# duplicate target already owned by the current session
: > "$OSRC_HOME/owners/new-sess/sess-c"
out="$(CLAUDE_CODE_SESSION_ID=new-sess "$SRC" adopt old-two 2>/dev/null)"
[ -f "$OSRC_HOME/owners/new-sess/sess-c" ] && [ ! -d "$OSRC_HOME/owners/old-two" ] \
  && ok "a target both sessions owned ends up owned once" || no "duplicate handling wrong: [$out]"

echo "=== moved helpers still work when the script is sourced ==="
( export OSRC_SOURCED=1 CLAUDE_CODE_SESSION_ID="src-sess"; . "$SRC" >/dev/null 2>&1; _owner_record job-z )
[ -f "$OSRC_HOME/owners/src-sess/job-z" ] && ok "_owner_record works from lib/ when sourced" \
  || no "_owner_record missing after source (lib loader or BASH_SOURCE path broken)"

echo "=== handover writes the pickup brief ==="
mkjob job-live '{"id":"job-live","provider":"devin","model":"glm-5.2","lane":"dv","tier":"standard","cwd":"/tmp/fake-work","started":1}'
mkdir -p "$OSRC_HOME/owners/new-sess"
: > "$OSRC_HOME/owners/new-sess/job-live"
mkdir -p "$OSRC_HOME/autodetach" "$OSRC_HOME/remote"
echo x > "$OSRC_HOME/autodetach/sess-old.log"; echo 0 > "$OSRC_HOME/autodetach/sess-old.rc"
: > "$OSRC_HOME/owners/new-sess/sess-old"
printf '{"state":"running","cwd":"/tmp/remote-wt","model":"claude-opus"}' > "$OSRC_HOME/remote/lane-r1.json"
: > "$OSRC_HOME/owners/new-sess/lane-r1"
OUT="$TMP/brief.md"
out="$(CLAUDE_CODE_SESSION_ID=new-sess "$SRC" handover --out "$OUT" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$OUT" ] && ok "handover --out writes the file" || no "handover failed (rc=$rc): [$out]"
grep -q "adopt new-sess" "$OUT" && ok "the brief names the adopt command for this session" \
  || no "adopt command missing: $(cat "$OUT" 2>/dev/null | head -20)"
grep -q '`job-live` -- job, live' "$OUT" && ok "the brief lists the live job with kind+state" \
  || no "job row wrong: $(grep -A3 'job-live' "$OUT" 2>/dev/null)"
# With L1 loaded a live job is covered by the one supervise; without it, by its own wait.
grep -q 'covered by: `.*supervise`' <<<"$(grep -A6 'job-live' "$OUT")" && ok "with supervise loaded, a live job is covered by it" || no "supervise cover missing: $(grep -A6 'job-live' "$OUT")"
( export OSRC_SOURCED=1 CLAUDE_CODE_SESSION_ID=new-sess; . "$SRC" >/dev/null 2>&1; unset -f cmd_supervise; cmd_handover --out "$TMP/brief-nosup.md" >/dev/null 2>&1 )
grep -q 'wait job-live' "$TMP/brief-nosup.md" && ok "without supervise, a live job gets its wait command" || no "wait command missing"
grep -q 'glm-5.2' "$OUT" && grep -q '/tmp/fake-work' "$OUT" \
  && ok "job model and cwd come from meta.json" || no "model/cwd missing"
grep -q '`sess-old` -- tmux, done' "$OUT" && ok "an autodetach marker reads as a done tmux target" \
  || no "tmux row wrong: $(grep -A3 'sess-old' "$OUT" 2>/dev/null)"
grep -q '`lane-r1` -- remote' "$OUT" && ok "remote/<id>.json reads as a remote lane" \
  || no "remote row wrong: $(grep -A3 'lane-r1' "$OUT" 2>/dev/null)"
grep -q 'wait lane-r1' "$OUT" && no "a remote lane got a local wait command" \
  || ok "remote lanes get no bogus wait command"
grep -q 'wait sess-old' "$OUT" && no "a done target got a wait command" \
  || ok "done targets get no wait command"
grep -q 'adopt --list' "$OUT" && ok "the brief points at adopt --list for other sessions" \
  || no "other-sessions section missing"

echo "=== handover default path ==="
out="$(CLAUDE_CODE_SESSION_ID=new-sess "$SRC" handover 2>/dev/null)"; rc=$?
case "$out" in *"$OSRC_HOME/handover/new-sess-"*.md*) ok "default path is \$OSRC_HOME/handover/<sid>-<ts>.md" ;;
  *) no "unexpected default output: [$out]" ;; esac
ls "$OSRC_HOME"/handover/new-sess-*.md >/dev/null 2>&1 && ok "default file was written" || no "default file missing"

echo "=== handover refusals ==="
out="$(env -u CLAUDE_CODE_SESSION_ID "$SRC" handover 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qi 'no current session' <<<"$out" \
  && ok "handover refuses with no session id" || no "no-sid handover not refused (rc=$rc): [$out]"
out="$(CLAUDE_CODE_SESSION_ID=new-sess "$SRC" handover --bogus 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -qi 'unknown argument' <<<"$out" \
  && ok "handover rejects unknown args" || no "bad arg not refused (rc=$rc): [$out]"

echo "=== an idle-but-alive tmux target gets a read instruction, not 'no waiter' ==="
# sess-idle has only an owner marker: no job dir, no autodetach files. The fake tmux below
# answers has-session/display-message so _owned_live_state reads it as an existing session
# with no working state -> idle. The brief must send the new session to LOOK at it.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/tmux" <<'EOF'
#!/bin/sh
case " $* " in
  *" has-session "*) exit 0 ;;
  *" display-message "*) printf '/tmp/fake-pane-cwd\n'; exit 0 ;;
  *" capture-pane "*) [ -n "${FAKE_PANE:-}" ] && cat "$FAKE_PANE"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/tmux"
: > "$OSRC_HOME/owners/new-sess/sess-idle"
# L1 calls a pane idle only once supervise has confirmed it (a busy pane flickers through idle
# frames), so serve a real idle Claude Code pane and record that supervise already reported it.
export FAKE_PANE="$SCRIPT_DIR/fixtures/supervise/cc-idle-after-work.txt"
mkdir -p "$OSRC_HOME/lanes/state"; printf '%s\n' "- 0 - - 0 idle:1 $(date +%s)" > "$OSRC_HOME/lanes/state/sess-idle"
OUT2="$TMP/brief-idle.md"
out="$(PATH="$TMP/bin:$PATH" CLAUDE_CODE_SESSION_ID=new-sess "$SRC" handover --out "$OUT2" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && grep -q '`sess-idle` -- tmux, idle' "$OUT2" \
  && ok "idle session row shows kind=tmux state=idle" || no "idle row wrong (rc=$rc): $(grep -A3 'sess-idle' "$OUT2" 2>/dev/null)"
{ _t3b_pipe="$(grep -A6 'sess-idle' "$OUT2")" && grep -q 'OUTSOURCERER_TMUX=sess-idle' <<<"$_t3b_pipe"; } \
  && { _t3b_pipe="$(grep -A6 'sess-idle' "$OUT2")" && grep -q 'session read' <<<"$_t3b_pipe"; } \
  && ok "idle session gets the session read command" || no "no read command for idle session"
_idle_blk="$(awk '/^### `sess-idle`/{f=1;next} /^### `/{if(f)exit} f' "$OUT2")"
grep -q 'no waiter needed' <<<"$_idle_blk" \
  && no "an alive idle session was told it needs no waiter" \
  || ok "idle session is not dismissed as needing no waiter"
{ _t3b_pipe="$(grep -A6 'sess-idle' "$OUT2")" && grep -q '/tmp/fake-pane-cwd' <<<"$_t3b_pipe"; } \
  && ok "idle session cwd falls back to the pane path" || no "pane cwd fallback missing"

echo "=== handover prefers one supervise command when L1's multiplexer exists ==="
OUT3="$TMP/brief-supervise.md"
( export OSRC_SOURCED=1 CLAUDE_CODE_SESSION_ID=new-sess
  . "$SRC" >/dev/null 2>&1
  cmd_supervise() { :; }
  cmd_handover --out "$OUT3" >/dev/null 2>&1 )
grep -q 'supervise' "$OUT3" && grep -q 'covered by' "$OUT3" \
  && ok "with cmd_supervise defined the brief names the single supervisor" \
  || no "supervise path missing: $(grep -i 'supervise\|waiter' "$OUT3" 2>/dev/null | head -5)"
grep -q 'wait job-live' "$OUT3" \
  && no "per-target wait printed even though supervise exists" \
  || ok "no per-target wait lines when supervise covers them"

echo "=== a symlinked launcher still loads lib/ (stop-guard must not fail open) ==="
SRC_REAL="$(cd "$SCRIPT_DIR/.." && pwd)/outsourcerer.sh"
mkdir -p "$TMP/linkdir"
ln -sf "$SRC_REAL" "$TMP/linkdir/outsourcerer.sh"
out="$(CLAUDE_CODE_SESSION_ID=link-sess "$TMP/linkdir/outsourcerer.sh" adopt --list 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'new-sess' <<<"$out" \
  && ok "adopt --list works through a symlink (lib loaded from the real dir)" \
  || no "symlink adopt --list failed (rc=$rc): [$out]"
mkjob l8-link-job
mkdir -p "$OSRC_HOME/owners/link-sid"
: > "$OSRC_HOME/owners/link-sid/l8-link-job"
out="$(printf '{"session_id":"link-sid"}' | "$TMP/linkdir/outsourcerer.sh" stop-guard 2>/dev/null)"
grep -q '"decision":"block"' <<<"$out" \
  && ok "stop-guard through a symlink still blocks on owned live work" \
  || no "symlink stop-guard failed open (no block): [$out]"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
