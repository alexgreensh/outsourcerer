#!/usr/bin/env bash
# test_grokbot_lane.sh — the Grok Bot lane posts the task to a routine webhook (Bearer key, JSON),
# then waits for the bot to push a branch to origin and prints OUTSOURCERER_RESULT.md from it.
# A local HTTP server plays the bot: it checks the key, records the payload, and pushes the branch
# to a local bare "origin". Nothing leaves this machine.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
command -v python3 >/dev/null || { echo "SKIP: python3 missing"; exit 0; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-gb.XXXXXX")"; SRV=""
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home"; mkdir -p "$OSRC_HOME"
export HOME="$TMP/fakehome"; mkdir -p "$HOME"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

# origin + working clone
git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
( cd "$TMP/work" && git config user.email t@t && git config user.name t && echo hi > a.txt && git add a.txt && git commit -qm init && git push -q origin HEAD:main 2>/dev/null && git branch -q -u origin/main 2>/dev/null )
git -C "$TMP/work" checkout -q -B main origin/main 2>/dev/null

# the fake bot
cat > "$TMP/bot.py" <<'PY'
import http.server, json, os, subprocess, sys, threading, tempfile
TMP, KEY, MODE = sys.argv[1], sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0)); body = self.rfile.read(n)
        if self.headers.get('Authorization') != 'Bearer ' + KEY:
            self.send_response(401); self.end_headers(); self.wfile.write(b'bad key'); return
        open(os.path.join(TMP, 'payload.json'), 'wb').write(body)
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":true}')
        if MODE == 'push':
            p = json.loads(body)
            def work():
                d = tempfile.mkdtemp(dir=TMP)
                subprocess.run(['git', 'clone', '-q', p['repo'], d], check=True)
                g = lambda *a: subprocess.run(['git', '-C', d] + list(a), check=True, capture_output=True)
                g('config', 'user.email', 'bot@x'); g('config', 'user.name', 'bot')
                g('checkout', '-q', p['base']); g('checkout', '-q', '-b', p['branch'])
                open(os.path.join(d, 'OUTSOURCERER_RESULT.md'), 'w').write('BOT_RESULT_OK\n')
                g('add', '.'); g('commit', '-qm', 'grok bot result'); g('push', '-q', 'origin', p['branch'])
            threading.Timer(1.0, work).start()
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open(os.path.join(TMP, 'port'), 'w').write(str(s.server_port))
s.serve_forever()
PY
start_bot() { rm -f "$TMP/port"; python3 "$TMP/bot.py" "$TMP" "$1" "$2" & SRV=$!; for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done; }
stop_bot() { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""; }
gb() { ( cd "$TMP/work" && OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 OSRC_GROKBOT_POLL=1 OSRC_GROKBOT_TIMEOUT="${TO:-30}" \
         GROKBOT_WEBHOOK_URL="http://127.0.0.1:$(cat "$TMP/port")/hook" GROKBOT_WEBHOOK_KEY="${KEYUSE:-crsr_test}" \
         "$SRC" --provider grokbot "$@" 2>"$TMP/err" ); }

echo "=== registration ==="
( export OSRC_SOURCED=1; source "$SRC" >/dev/null 2>&1; [ "$(_lane_field grokbot dispatch)" = "delegate_grokbot" ] ) \
  && ok "grokbot is a registered lane" || no "grokbot lane not registered"

echo "=== delivery round trip ==="
start_bot crsr_test push
out="$(gb run "summarize the repo")"; rc=$?
[ "$rc" -eq 0 ] && ok "the run succeeds once the bot pushes" || no "rc=$rc err=$(tail -3 "$TMP/err")"
case "$out" in *BOT_RESULT_OK*) ok "the bot's result file is printed" ;; *) no "result missing: [$out]" ;; esac
jq -e '.source=="outsourcerer" and .mode=="read-only" and (.branch|startswith("osrc/grokbot-")) and (.instructions|contains("summarize the repo"))' "$TMP/payload.json" >/dev/null 2>&1 \
  && ok "the payload carries the task, a fresh branch and read-only mode" || no "payload wrong: $(head -c 300 "$TMP/payload.json")"
jq -r .instructions "$TMP/payload.json" | grep -q "push osrc/grokbot-" && ok "the instructions tell the bot how to deliver" || no "delivery instructions missing"
grep -q "delivered on branch osrc/grokbot-" "$TMP/err" && ok "it names the delivered branch" || no "branch not reported"
stop_bot

echo "=== edit mode ==="
start_bot crsr_test push
gb edit "fix the typo" >/dev/null
jq -e '.mode=="edit"' "$TMP/payload.json" >/dev/null 2>&1 && ok "edit posts mode=edit" || no "edit mode not posted"
git -C "$TMP/work" rev-parse -q --verify main >/dev/null && [ "$(git -C "$TMP/work" rev-parse --abbrev-ref HEAD)" = "main" ] \
  && ok "nothing is merged into the local branch" || no "local branch changed"
stop_bot

echo "=== failures are loud ==="
start_bot crsr_right none
out="$(KEYUSE=crsr_wrong gb run "x")"; rc=$?
[ "$rc" -ne 0 ] && grep -q "HTTP 401" "$TMP/err" && ok "a rejected key fails with the HTTP code" || no "bad key rc=$rc err=$(tail -2 "$TMP/err")"
stop_bot
start_bot crsr_test none
out="$(TO=3 gb run "x")"; rc=$?
[ "$rc" -eq 124 ] && grep -q "no branch after" "$TMP/err" && ok "no branch by the deadline returns 124 with a pointer" || no "timeout rc=$rc"
stop_bot
out="$( cd "$TMP/work" && OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 GROKBOT_WEBHOOK_URL= GROKBOT_WEBHOOK_KEY= "$SRC" --provider grokbot run "x" 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "GROKBOT_WEBHOOK_URL" && ok "missing setup names the two settings" || no "missing setup rc=$rc"
out="$( cd "$TMP/work" && OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 GROKBOT_WEBHOOK_URL=http://example.com/h GROKBOT_WEBHOOK_KEY=k "$SRC" --provider grokbot run "x" 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "https://" && ok "a plain-http webhook is refused (the key would travel in the clear)" || no "http URL accepted"
grep -q 'printf .Authorization: Bearer' "$SRC" && ! grep -n 'delegate_grokbot' -A80 "$SRC" | grep -q -- '-H "Authorization' \
  && ok "the key goes through the header file, never the process list" || no "key may appear in argv"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
