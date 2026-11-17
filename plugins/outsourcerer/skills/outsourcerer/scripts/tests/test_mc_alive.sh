#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_mc_alive.sh: Mission Control never looks dead (lib/mc_alive.sh, lib/hub_server.py,
# lib/hub-assets/hub-alive.js).
#   old key  a tab whose key an earlier hub retired gets the current URL from POST /reopen, nothing else
#            does; the page explains it in the main pane (tests/hub_alive_dom.js);
#   live     live line, failure reason + age of the last good data, slow calls (hub_alive_dom.js, fake clock);
#   open     work starting opens the page once per hub process when no tab fetched data in 2 min; never in
#            CI, never with OSRC_MC_AUTO_OPEN=0; a desktop is "the console user is this user", so tmux
#            (launchctl says Background) still counts. The opener is a recorder: no real browser.
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

echo "=== a desktop is the console user, not launchctl's manager name ==="
mkdir -p "$TMP/fake-mac"
printf '#!/bin/sh\necho Darwin\n' > "$TMP/fake-mac/uname"
printf '#!/bin/sh\necho Background\n' > "$TMP/fake-mac/launchctl"
printf '#!/bin/sh\necho alex\n' > "$TMP/fake-mac/id"
printf '#!/bin/sh\necho "${CONSOLE_USER:-alex}"\n' > "$TMP/fake-mac/stat"
chmod +x "$TMP/fake-mac"/*
hl() { ( PATH="$TMP/fake-mac:$PATH"; unset SSH_CONNECTION SSH_TTY CI; "$@"; lib _osrc_mc_headless ); }
hl true; [ "$?" = 1 ] && ok "inside tmux on a desktop (launchctl: Background, console user = this user): a desktop" || no "tmux desktop read as headless"
CONSOLE_USER=someone hl true; [ "$?" = 0 ] && ok "someone else at the console: headless" || no "other console user read as desktop"
( PATH="$TMP/fake-mac:$PATH"; SSH_CONNECTION="1 2 3 4" lib _osrc_mc_headless ); [ "$?" = 0 ] && ok "over SSH: headless" || no "ssh read as desktop"

echo "=== work starting opens Mission Control once per hub process ==="
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

echo "=== an old key, and /reopen ==="
command -v curl >/dev/null 2>&1 || { echo "SKIP: curl not installed"; echo "RESULT: $pass passed, $fail failed"; [ "$fail" = 0 ]; exit; }
PORT="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null)"
if [ -z "$PORT" ]; then ok "loopback denied by the sandbox: HTTP checks need a direct host run"; else
rm -f "$OSRC_HOME/hub/token" "$OSRC_HOME/hub/tab.seen"   # left by the I section
start_hub() { # [hub serve args]: start on $PORT, set URL/TOK
  OSRC_HOME="$OSRC_HOME" bash "$SRC" hub serve --port "$PORT" --no-open "$@" >"$TMP/serve.log" 2>&1 & SRV=$!
  URL=""; for _ in $(seq 1 150); do
    URL="$(grep -o 'http://127\.0\.0\.1:[0-9]*/?t=[A-Za-z0-9]*' "$TMP/serve.log" 2>/dev/null | head -1)"; [ -n "$URL" ] && break
    kill -0 "$SRV" 2>/dev/null || break; sleep 0.2; done
  [ -n "$URL" ] || { no "hub serve did not start: $(cat "$TMP/serve.log")"; echo "RESULT: $pass passed, $fail failed"; exit 1; }
  TOK="${URL##*t=}"
}
stop_hub() { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""; }
start_hub; OLD="$TOK"; stop_hub
rm -f "$OSRC_HOME/hub/token"; start_hub   # the token file is gone: the hub issues a new key and retires the old one
BASE="http://127.0.0.1:$PORT"
[ "$TOK" != "$OLD" ] && ok "a restart without the token file serves a new key (the old tab's key is now retired)" || no "token did not rotate"
jq -e --argjson p "$PORT" '.port == $p and (.pid | type) == "number"' "$OSRC_HOME/hub/serve.json" >/dev/null && ok "the hub records who serves this OSRC_HOME (serve.json pid + port)" || no "serve.json: $(cat "$OSRC_HOME/hub/serve.json" 2>/dev/null)"
code="$(curl -s -o /dev/null -w '%{http_code}' -H "X-Hub-Token: $OLD" "$BASE/api/answers")"
[ "$code" = 403 ] && ok "a tab holding the older key gets 403 from the data API" || no "old key: $code"
[ ! -f "$OSRC_HOME/hub/tab.seen" ] && ok "an old key's request does not count as a watching tab" || no "tab.seen written for a bad key"
code="$(curl -s -o /dev/null -w '%{http_code}' -H "X-Hub-Token: $TOK" "$BASE/api/answers")"
[ "$code" = 200 ] && [ "$(( $(date +%s) - $(cat "$OSRC_HOME/hub/tab.seen" 2>/dev/null || echo 0) ))" -le 5 ] && ok "a data call with the current key stamps hub/tab.seen" || no "tab.seen: $code $(cat "$OSRC_HOME/hub/tab.seen" 2>/dev/null)"
# /reopen: only a tab holding a key this hub's predecessors issued gets the current URL.
ro() { curl -s -w '\n%{http_code}' -X POST "$@" "$BASE/reopen"; }
b="$(curl -s -w '\n%{http_code}' -H 'Sec-Fetch-Site: none' "$BASE/reopen")"
[ "${b##*$'\n'}" = 403 ] && ! grep -q "$TOK" <<<"$b" && ok "GET /reopen typed or scripted (Sec-Fetch-Site: none): 403, no key" || no "GET none: $b"
b="$(ro -H 'Sec-Fetch-Site: none')"
[ "${b##*$'\n'}" = 403 ] && ! grep -q "$TOK" <<<"$b" && grep -q 'outsourcerer mc' <<<"$b" && ok "POST with no old key: 403 with the 'run outsourcerer mc' text, no key" || no "no old key: $b"
b="$(ro -H 'X-Hub-Old-Token: 0123456789abcdef0123456789abcdef')"
[ "${b##*$'\n'}" = 403 ] && ! grep -q "$TOK" <<<"$b" && ok "an unknown old key: 403, no key" || no "unknown key: $b"
b="$(ro -H "X-Hub-Old-Token: $TOK")"
[ "${b##*$'\n'}" = 403 ] && ok "the current key is not a retired one: 403 (that tab needs no reopen)" || no "current as old: $b"
b="$(ro -H "X-Hub-Old-Token: $OLD" -H 'Sec-Fetch-Site: same-origin' -H "Origin: http://127.0.0.1:$PORT")"
[ "${b##*$'\n'}" = 200 ] && [ "$(sed '$d' <<<"$b" | jq -r .url)" = "/?t=$TOK" ] && ok "the tab's retired key: 200 with the current page URL" || no "retired key: $b"
b="$(ro -H "X-Hub-Old-Token: $OLD" -H 'Origin: http://evil.example')"; [ "${b##*$'\n'}" = 403 ] && ok "a foreign Origin with the old key: 403" || no "origin: $b"
b="$(ro -H "X-Hub-Old-Token: $OLD" -H 'Sec-Fetch-Site: cross-site')"; [ "${b##*$'\n'}" = 403 ] && ok "a cross-site POST with the old key: 403" || no "cross-site: $b"
b="$(ro -H "X-Hub-Old-Token: $OLD" -H "Host: evil.example:$PORT")"; [ "${b##*$'\n'}" = 403 ] && ok "a non-loopback Host (DNS rebinding) with the old key: 403" || no "host: $b"
K="$OSRC_HOME/hub/keys.json"
PERM="$(stat -c %a "$K" 2>/dev/null || stat -f %Lp "$K" 2>/dev/null)"
[ "$PERM" = 600 ] && ! grep -q "$OLD" "$K" && ! grep -q "$TOK" "$K" && [ "$(jq length "$K")" = 2 ] && ok "keys.json is 0600 and holds salted hashes only (2 keys)" || no "keys.json: mode $PERM $(cat "$K")"
jq '[.[] | if .current then . else .retired_at = (now - 8 * 86400 | floor) end]' "$K" > "$K.t" && mv "$K.t" "$K"
b="$(ro -H "X-Hub-Old-Token: $OLD")"; [ "${b##*$'\n'}" = 403 ] && ok "a key retired over 7 days ago: 403" || no "expired key: $b"
grep -q "$TOK" "$TMP/serve.log" && [ "$(grep -c "$TOK" "$TMP/serve.log")" -gt 1 ] && no "the key was logged by a request line" || ok "the current key never reaches the hub log through /reopen"
pg="$(curl -s "$BASE/")"; grep -q 'assets/hub-alive.js' <<<"$pg" && ok "the page loads hub-alive.js" || no "page does not load hub-alive.js"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/assets/hub-alive.js")" = 200 ] && ok "hub-alive.js is served (CSP script-src 'self')" || no "asset not served"
stop_hub
# --new-token revokes: no retired key redeems the new one.
start_hub; R1="$TOK"; stop_hub; rm -f "$OSRC_HOME/hub/token"; start_hub; stop_hub
start_hub --new-token
b="$(ro -H "X-Hub-Old-Token: $R1")"; [ "${b##*$'\n'}" = 403 ] && ! grep -q "$TOK" <<<"$b" && [ "$(jq length "$K")" = 1 ] && ok "after --new-token a retired key gets 403 and keys.json holds only the new key" || no "rotation did not revoke: $b $(cat "$K")"
stop_hub
# Only the newest 5 keys are kept.
for i in 1 2 3 4 5; do rm -f "$OSRC_HOME/hub/token"; start_hub; stop_hub; done
[ "$(jq length "$K")" = 5 ] && ok "keys.json keeps the newest 5 keys" || no "kept $(jq length "$K")"
fi

echo "=== the liveness strip and the old-key page, fake clock ==="
if command -v node >/dev/null 2>&1; then
  out="$(node "$HERE/hub_alive_dom.js" "$HERE/../lib/hub-assets/hub-alive.js" 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^(PASS|FAIL)'
  pass=$(( pass + $(printf '%s\n' "$out" | grep -c '^PASS') )); fail=$(( fail + $(printf '%s\n' "$out" | grep -c '^FAIL') ))
  [ "$rc" = 0 ] || [ "$(printf '%s\n' "$out" | grep -c '^FAIL')" -gt 0 ] || no "hub_alive_dom.js exited $rc: $out"
else echo "SKIP: node not installed (liveness strip unit)"; fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
