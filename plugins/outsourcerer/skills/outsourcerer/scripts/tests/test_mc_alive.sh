#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_mc_alive.sh: Mission Control never looks dead (S4 G/H/I; lib/mc_alive.sh, lib/hub_server.py,
# lib/hub-assets/hub-alive.js).
#   G  an old key gets a clear line and a token-less /reopen that only redirects same-origin navigation;
#   H  live line, failure reason + age of the last good data, slow calls (tests/hub_alive_dom.js, fake clock);
#   I  work starting opens the page once per hub process when no tab fetched data in 2 min; never in CI,
#      never with OSRC_MC_AUTO_OPEN=0. The opener is a recorder: no real browser (test_no_real_browser).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-mc-alive.XXXXXX")" || { echo "FAIL: no scratch dir" >&2; exit 1; }
SRV=""; HUBPID=""
cleanup() { [ -z "$SRV" ] || { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }; [ -z "$HUBPID" ] || kill "$HUBPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/home" "$TMP/bin"
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc" OSRC_HEARTBEAT_DISABLED=1 OSRC_HUB_NO_OPEN=1
unset CLAUDE_CODE_SESSION_ID OUTSOURCERER_DEPTH CI OSRC_MC_AUTO_OPEN
mkdir -p "$OSRC_HOME/hub"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
lib() { ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; "$@" ); }
cat > "$TMP/bin/open-rec" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "$OSRC_HOME/opened.log"
EOF
chmod +x "$TMP/bin/open-rec"
opens() { grep -c . "$OSRC_HOME/opened.log" 2>/dev/null || echo 0; }

echo "=== I: work starting opens Mission Control once per hub process ==="
# A live "hub": this test's own shell stands in for its pid; serve.json is what hub_server.py writes.
sleep 300 & HUBPID=$!
printf '{"pid":%s,"port":8799,"started":1}\n' "$HUBPID" > "$OSRC_HOME/hub/serve.json"
printf '0123456789abcdef0123456789abcdef\n' > "$OSRC_HOME/hub/token"
desk() { OSRC_HUB_NO_OPEN=0 OSRC_MC_OPEN_CMD="$TMP/bin/open-rec" OSRC_MC_ASSUME_DESKTOP=1 "$@"; }
desk lib osrc_mc_cmd_hook session start 2>/dev/null
[ "$(opens)" = 1 ] && grep -qx 'http://127.0.0.1:8799/?t=0123456789abcdef0123456789abcdef' "$OSRC_HOME/opened.log" \
  && ok "session start with no tab watching: the page opens at the live hub's URL" || no "open: $(cat "$OSRC_HOME/opened.log" 2>/dev/null)"
desk lib osrc_mc_cmd_hook run "a task" 2>/dev/null; desk lib osrc_mc_cmd_hook fleet ls 2>/dev/null
[ "$(opens)" = 1 ] && ok "a delegation and fleet right after: not again (once per hub process)" || no "opened $(opens) times"
desk lib osrc_mc_cmd_hook session read 2>/dev/null
[ "$(opens)" = 1 ] && ok "session read is not work starting: no open" || no "session read opened"
kill "$HUBPID" 2>/dev/null; wait "$HUBPID" 2>/dev/null
sleep 300 & HUBPID=$!; printf '{"pid":%s,"port":8799,"started":2}\n' "$HUBPID" > "$OSRC_HOME/hub/serve.json"
date +%s > "$OSRC_HOME/hub/tab.seen"
desk lib osrc_mc_cmd_hook session start 2>/dev/null
[ "$(opens)" = 1 ] && ok "a new hub process, but a tab fetched data within 2 min: no open" || no "opened with a fresh tab"
echo $(( $(date +%s) - 200 )) > "$OSRC_HOME/hub/tab.seen"
OSRC_MC_AUTO_OPEN=0 desk lib osrc_mc_cmd_hook session start 2>/dev/null
[ "$(opens)" = 1 ] && ok "OSRC_MC_AUTO_OPEN=0: never" || no "opened with AUTO_OPEN=0"
CI=true desk lib osrc_mc_cmd_hook session start 2>/dev/null
[ "$(opens)" = 1 ] && ok "CI: never" || no "opened in CI"
OUTSOURCERER_DEPTH=1 desk lib osrc_mc_cmd_hook session start 2>/dev/null
[ "$(opens)" = 1 ] && ok "a delegate running outsourcerer (depth 1): never" || no "opened from a delegate"
OSRC_HUB_NO_OPEN=0 OSRC_MC_OPEN_CMD="$TMP/bin/open-rec" lib osrc_mc_cmd_hook session start 2>/dev/null
[ "$(opens)" = 1 ] && ok "a scratch HOME (every test suite) is never the account's own: no open" || no "opened under a test HOME"
desk lib osrc_mc_cmd_hook session start 2>/dev/null
[ "$(opens)" = 2 ] && ok "the new hub process, tab stale 200 s: opens once" || no "second hub: opens=$(opens)"
kill "$HUBPID" 2>/dev/null; wait "$HUBPID" 2>/dev/null
# No hub at all: a detached `mc` would start one; the guard holds it to one start per 2 minutes.
rm -f "$OSRC_HOME/hub/serve.json"; : > "$OSRC_HOME/hub/autostart"
err="$(desk lib osrc_mc_auto_open 2>&1)"
[ -z "$err" ] && ok "no hub, but one was started under 2 min ago: nothing new is started" || no "autostart repeat: $err"

echo "=== G: an old key, and /reopen ==="
command -v curl >/dev/null 2>&1 || { echo "SKIP: curl not installed"; echo "RESULT: $pass passed, $fail failed"; [ "$fail" = 0 ]; exit; }
PORT="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null)"
if [ -z "$PORT" ]; then ok "loopback denied by the sandbox: HTTP checks need a direct host run"; else
rm -f "$OSRC_HOME/hub/token" "$OSRC_HOME/hub/tab.seen"   # left by the I section
OSRC_HOME="$OSRC_HOME" bash "$SRC" hub serve --port "$PORT" --no-open >"$TMP/serve.log" 2>&1 & SRV=$!
URL=""; for _ in $(seq 1 150); do
  URL="$(grep -o 'http://127\.0\.0\.1:[0-9]*/?t=[A-Za-z0-9]*' "$TMP/serve.log" 2>/dev/null | head -1)"; [ -n "$URL" ] && break
  kill -0 "$SRV" 2>/dev/null || break; sleep 0.2; done
[ -n "$URL" ] || { no "hub serve did not start: $(cat "$TMP/serve.log")"; echo "RESULT: $pass passed, $fail failed"; exit 1; }
BASE="http://127.0.0.1:$PORT"; TOK="${URL##*t=}"
jq -e --argjson p "$PORT" '.port == $p and (.pid | type) == "number"' "$OSRC_HOME/hub/serve.json" >/dev/null && ok "the hub records who serves this OSRC_HOME (serve.json pid + port)" || no "serve.json: $(cat "$OSRC_HOME/hub/serve.json" 2>/dev/null)"
code="$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Hub-Token: deadbeefdeadbeefdeadbeefdeadbeef' "$BASE/api/answers")"
[ "$code" = 403 ] && ok "a tab holding an older key gets 403 from the data API (the page shows the old-key line, hub_alive_dom.js)" || no "old key: $code"
[ ! -f "$OSRC_HOME/hub/tab.seen" ] && ok "an old key's request does not count as a watching tab" || no "tab.seen written for a bad key"
code="$(curl -s -o /dev/null -w '%{http_code}' -H "X-Hub-Token: $TOK" "$BASE/api/answers")"
[ "$code" = 200 ] && [ "$(( $(date +%s) - $(cat "$OSRC_HOME/hub/tab.seen" 2>/dev/null || echo 0) ))" -le 5 ] && ok "a data call with the current key stamps hub/tab.seen" || no "tab.seen: $code $(cat "$OSRC_HOME/hub/tab.seen" 2>/dev/null)"
hdr() { curl -s -D - -o /dev/null "$@" "$BASE/reopen" | tr -d '\r'; }
h="$(hdr -H 'Sec-Fetch-Site: same-origin' -H 'Sec-Fetch-Mode: navigate')"
grep -q '^HTTP/1.1 302' <<<"$h" && grep -qx "Location: /?t=$TOK" <<<"$h" && ok "Reopen (same-origin navigation): 302 to the current key" || no "reopen same-origin: $h"
h="$(hdr -H 'Sec-Fetch-Site: none')"; grep -q '^HTTP/1.1 302' <<<"$h" && ok "typed into the address bar (Sec-Fetch-Site: none): 302" || no "reopen none: $h"
for v in "cross-site" "same-site"; do
  h="$(hdr -H "Sec-Fetch-Site: $v")"; grep -q '^HTTP/1.1 403' <<<"$h" && ! grep -q "$TOK" <<<"$h" && ok "a $v request to /reopen: 403, no key" || no "reopen $v: $h"
done
h="$(hdr)"; grep -q '^HTTP/1.1 403' <<<"$h" && ok "no Sec-Fetch-Site (curl, scripts): 403, no key" || no "reopen bare: $h"
h="$(hdr -H 'Sec-Fetch-Site: same-origin' -H 'Origin: http://evil.example')"; grep -q '^HTTP/1.1 403' <<<"$h" && ok "a foreign Origin: 403" || no "reopen origin: $h"
h="$(hdr -H 'Sec-Fetch-Site: same-origin' -H "Host: evil.example:$PORT")"; grep -q '^HTTP/1.1 403' <<<"$h" && ok "a non-loopback Host (DNS rebinding): 403" || no "reopen host: $h"
grep -q "$TOK" "$TMP/serve.log" && [ "$(grep -c "$TOK" "$TMP/serve.log")" -gt 1 ] && no "the key was logged by a request line" || ok "the redirect's key never reaches the hub log"
pg="$(curl -s "$BASE/")"; grep -q 'assets/hub-alive.js' <<<"$pg" && ok "the page loads hub-alive.js" || no "page does not load hub-alive.js"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/assets/hub-alive.js")" = 200 ] && ok "hub-alive.js is served (CSP script-src 'self')" || no "asset not served"
fi

echo "=== H (and G page side): the liveness strip, fake clock ==="
if command -v node >/dev/null 2>&1; then
  out="$(node "$HERE/hub_alive_dom.js" "$HERE/../lib/hub-assets/hub-alive.js" 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^(PASS|FAIL)'
  pass=$(( pass + $(printf '%s\n' "$out" | grep -c '^PASS') )); fail=$(( fail + $(printf '%s\n' "$out" | grep -c '^FAIL') ))
  [ "$rc" = 0 ] || [ "$(printf '%s\n' "$out" | grep -c '^FAIL')" -gt 0 ] || no "hub_alive_dom.js exited $rc: $out"
else echo "SKIP: node not installed (liveness strip unit)"; fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
