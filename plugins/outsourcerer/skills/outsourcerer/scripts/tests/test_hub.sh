#!/usr/bin/env bash
# test_hub.sh -- Mission Control: `hub export` SCHEMA output from seeded OSRC_HOME,
# `hub serve` local server (token gate, answers round-trip, refresh, loopback only),
# and the LOADER.md symlink fallback (lib functions load when invoked via a symlink).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

# Scratch under the worktree (never live ~/.outsourcerer, never left in /tmp).
TMP="$(mktemp -d "$HERE/.hub-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc" XDG_CONFIG_HOME="$TMP/xdg"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1 OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0
mkdir -p "$HOME" "$OSRC_HOME" "$XDG_CONFIG_HOME"
printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

OSRC="$SRC"
run() { OSRC_HOME="$OSRC_HOME" bash "$OSRC" "$@"; }

echo "=== seed state ==="
mkdir -p "$OSRC_HOME/owners/sess-1" "$OSRC_HOME/jobs/job-1" "$OSRC_HOME/remote" \
         "$OSRC_HOME/hub/decisions" "$OSRC_HOME/hub/projects"
echo done > "$OSRC_HOME/jobs/job-1/status"
jq -cn '{provider:"devin",model:"swe-2",lane:"devin",verb:"run"}' > "$OSRC_HOME/jobs/job-1/meta.json"
echo 'report only' > "$OSRC_HOME/jobs/job-1/task_ref" 2>/dev/null || true
touch "$OSRC_HOME/owners/sess-1/job-1"
# A remote lane owned by the same session.
jq -cn '{id:"lane-9",branch:"outsourcerer/lane-9",repo:"alexgreensh/demo",transport:"git",
         url:"https://github.com/alexgreensh/demo",head:"0123456789abcdef0123456789abcdef01234567",
         head_msg:"wip: lane nine",head_ready:false,last_poll_ts:1,last_push_ts:1}' \
  > "$OSRC_HOME/remote/lane-9.json"
touch "$OSRC_HOME/owners/sess-1/lane-9"
# Decisions + card for sess-1.
cat > "$OSRC_HOME/hub/decisions/sess-1.json" <<'EOF'
[{"id":"D1","q":"Ship the hub?","short":"Ship hub?","options":["yes","not yet"],"weight":"High","affects":["page"]}]
EOF
cat > "$OSRC_HOME/hub/projects/sess-1.json" <<'EOF'
{"name":"Mission Control","tagline":"one page for every lane","order":1,"repo":"alexgreensh/outsourcerer","status":"building","pct":40}
EOF
# Fresh L7 rate-limits artifact: 5h nearly out, weekly fine, both resetting later.
NOW="$(date +%s)"
jq -cn --argjson t "${NOW}000" --argjson r5 "$((NOW+7200))" --argjson r7 "$((NOW+400000))" \
  '{five_hour:{used_percentage:95,resets_at:$r5},seven_day:{used_percentage:40,resets_at:$r7},timestamp:$t,source:"statusline"}' \
  > "$OSRC_HOME/rate-limits.json"
# Detection is per-user (installed AND logged in): fake binaries + ~/.env so the
# limits rows are deterministic regardless of what this machine really has.
mkdir -p "$TMP/bin"
for b in claude devin agy ollama; do printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$b"; chmod +x "$TMP/bin/$b"; done
export PATH="$TMP/bin:$PATH"
echo 'OPENROUTER_API_KEY=test-only' > "$HOME/.env"

echo "=== hub export ==="
out="$(run hub export 2>"$TMP/export.err")" || { bad "hub export exited nonzero: $(cat "$TMP/export.err")"; echo "RESULTS: $pass pass $fail fail"; exit 1; }
echo "$out" | jq -e '.generated_at | type == "number"' >/dev/null && ok "generated_at is a unix ts" || bad "generated_at missing/not number"
echo "$out" | jq -e '.projects | type == "array" and length >= 1' >/dev/null && ok "projects array non-empty" || bad "no projects in export"

proj="$(echo "$out" | jq -c '.projects[] | select(.id=="sess-1")')"
[ -n "$proj" ] || { bad "sess-1 project missing"; echo "RESULTS: $pass pass $fail fail"; exit 1; }
echo "$proj" | jq -e '.name == "Mission Control" and .tagline == "one page for every lane" and .repo == "alexgreensh/outsourcerer" and .status == "building" and .pct == 40' >/dev/null \
  && ok "card fields applied from projects file" || bad "card fields wrong: $proj"
echo "$proj" | jq -e '.lanes | map(.id) | sort == ["job-1","lane-9"]' >/dev/null \
  && ok "lanes: job + remote lane both present" || bad "lanes wrong: $(echo "$proj" | jq -c .lanes)"
echo "$proj" | jq -e '.lanes[] | select(.id=="job-1") | .status == "Done" and .pct == 100' >/dev/null \
  && ok "done job lane maps to Done/100" || bad "job lane status wrong"
echo "$proj" | jq -e '.decisions[0].id == "D1" and .decisions[0].status == "wait" and .decisions[0].weight == "High"' >/dev/null \
  && ok "decision normalized (id/status/weight)" || bad "decision shape wrong"
echo "$proj" | jq -e '.exported_at | type == "number"' >/dev/null && ok "project exported_at present" || bad "exported_at missing"
# Item 14 stale alarm needs a machine-readable updatedAt (ISO, from input mtimes).
echo "$proj" | jq -e '.updatedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' >/dev/null \
  && ok "project updatedAt is an ISO timestamp" || bad "updatedAt missing/not ISO: $(echo "$proj" | jq -c '.updatedAt')"
# A card whose inputs are all old must export an old updatedAt (not export time).
cat > "$OSRC_HOME/hub/projects/stale-1.json" <<'EOF'
{"name":"Stale Board","tagline":"has not moved in two hours","order":9}
EOF
touch -t "$(date -u -v-2H '+%Y%m%d%H%M.%S' 2>/dev/null || date -u -d '2 hours ago' '+%Y%m%d%H%M.%S')" "$OSRC_HOME/hub/projects/stale-1.json"
outs="$(run hub export 2>/dev/null)"
sproj="$(echo "$outs" | jq -c '.projects[] | select(.id=="stale-1")')"
sage="$(echo "$sproj" | jq -r '(.updatedAt | sub("Z$";"+00:00")) + " epoch"' 2>/dev/null)"
sepoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%S%z' "$(echo "$sproj" | jq -r '.updatedAt | sub("Z$";"+0000")')" '+%s' 2>/dev/null \
  || date -u -d "$(echo "$sproj" | jq -r '.updatedAt')" '+%s' 2>/dev/null)"
{ [ -n "$sepoch" ] && [ $(( $(date +%s) - sepoch )) -gt 2700 ]; } \
  && ok "stale-1 updatedAt is >45min old (not export time)" || bad "stale-1 updatedAt not old enough: $sage"
# Item 15: shipped status flows through so the rail can file it under "Shipped".
cat > "$OSRC_HOME/hub/projects/shipped-1.json" <<'EOF'
{"name":"Done Board","tagline":"went live last week","order":8,"status":"shipped","pct":100}
EOF
outs="$(run hub export 2>/dev/null)"
echo "$outs" | jq -e '.projects[] | select(.id=="shipped-1") | .status == "shipped"' >/dev/null \
  && ok "shipped status flows through the export" || bad "shipped-1 status wrong"

echo "=== hub export: limits ==="
lim="$(echo "$out" | jq -c '.limits')"
echo "$lim" | jq -e 'type == "array" and length >= 4' >/dev/null && ok "limits array present" || bad "limits missing: $lim"
echo "$lim" | jq -e 'all(.[]; (.name | type == "string") and (.state | IN("ok","low","out","wait","unknown")) and (.order | type == "number"))' >/dev/null \
  && ok "every limit row has name/state ok|low|out|wait|unknown/order" || bad "limit row shape wrong: $lim"
echo "$lim" | jq -e '.[] | select(.id=="claude-5h") | .state == "wait" and (.left | test("left")) and (.renews | type == "string") and (.updated | type == "string")' >/dev/null \
  && ok "claude-5h: 95% used with reset -> wait with left/renews/updated" || bad "claude-5h row wrong: $(echo "$lim" | jq -c '.[]|select(.id=="claude-5h")')"
echo "$lim" | jq -e '.[] | select(.id=="claude-weekly") | .state == "ok"' >/dev/null \
  && ok "claude-weekly: 40% used -> ok" || bad "claude-weekly row wrong"
# Item 15: metered rows carry updatedAt (ISO) so the rail stamp can go stale.
echo "$lim" | jq -e '.[] | select(.id=="claude-5h") | .updatedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' >/dev/null \
  && ok "claude-5h carries updatedAt (ISO)" || bad "claude-5h updatedAt missing: $(echo "$lim" | jq -c '.[]|select(.id=="claude-5h")|{updated,updatedAt}')"
echo "$lim" | jq -e '.[] | select(.id=="openrouter") | .paid == true' >/dev/null \
  && ok "openrouter row carries the paid tag" || bad "openrouter paid flag missing"
echo "$lim" | jq -e '[.[] | select(.paid == true)] | length == 1' >/dev/null \
  && ok "exactly one paid lane" || bad "paid lane count wrong"
echo "$lim" | jq -e '.[] | select(.id=="openrouter") | (.models | type == "string") and (.note | type == "string")' >/dev/null \
  && ok "limit rows carry models+note" || bad "models/note missing"
echo "$lim" | jq -e '[.[] | select(.id=="gemini" or .id=="gemini-cli")] | length == 0' >/dev/null \
  && ok "Gemini CLI never listed (retired)" || bad "gemini row present — retired lane must not be listed"
echo "$lim" | jq -e '.[] | select(.id=="devin") | .state == "unknown"' >/dev/null \
  && ok "detected unmetered lane (devin) -> unknown row" || bad "devin row missing/wrong"
echo "$lim" | jq -e '.[] | select(.id=="local") | .state == "ok"' >/dev/null \
  && ok "detected local lane -> ok row" || bad "local row missing/wrong"
# A stale artifact (>10min old) must degrade to unknown, never fake a reading.
jq -cn --argjson t "$(( (${NOW} - 1200) * 1000 ))" --argjson r5 "$((NOW+7200))" --argjson r7 "$((NOW+400000))" \
  '{five_hour:{used_percentage:95,resets_at:$r5},seven_day:{used_percentage:40,resets_at:$r7},timestamp:$t,source:"statusline"}' \
  > "$OSRC_HOME/rate-limits.json"
out2="$(run hub export 2>/dev/null)"
echo "$out2" | jq -e '[.limits[] | select(.id | startswith("claude")) | .state] | all(. == "unknown")' >/dev/null \
  && ok "stale artifact -> claude rows unknown" || bad "stale artifact not unknown: $(echo "$out2" | jq -c '.limits[]|select(.id|startswith("claude"))')"
# No artifact but claude installed -> still an unknown row (detected, unchecked).
rm -f "$OSRC_HOME/rate-limits.json"
out3="$(run hub export 2>/dev/null)"
echo "$out3" | jq -e '(.limits | type == "array") and (.limits[] | select(.id=="claude") | .state == "unknown")' >/dev/null \
  && ok "missing artifact -> claude unknown row, array still valid" || bad "missing-artifact limits wrong"
echo "$out3" | jq -e '.limits[] | select(.id=="openrouter") | .paid == true' >/dev/null \
  && ok "paid lane present without meters" || bad "unmetered rows missing"
# Undetected lanes are omitted: without the fake binaries, no devin/agy/local row.
JQDIR="$(dirname "$(command -v jq)")"
out4="$(PATH="/usr/bin:/bin:$JQDIR" run hub export 2>/dev/null)"
echo "$out4" | jq -e '[.limits[] | select(.id=="devin" or .id=="agy" or .id=="local")] | length == 0' >/dev/null \
  && ok "undetected lanes omitted from limits" || bad "undetected lanes listed"
# Item 15: when L7's osrc_limits_summary --json is available it feeds the rail
# (recomputed on every export). A PATH stub stands in for lib/spend.sh here.
cat > "$TMP/bin/osrc_limits_summary" <<'EOF'
#!/bin/sh
[ "$1" = "--json" ] && printf '[{"id":"fake","name":"Fake Lane","state":"ok","left":"half left","renews_at":0,"cap":null,"cap_tripped":false,"paid":false,"billing":"subscription","window":null,"used":null,"updated":"2026-11-13T19:05:00Z","source":"outsourcerer","windows":{}}]\n' || printf 'FAKE\n'
EOF
chmod +x "$TMP/bin/osrc_limits_summary"
out5="$(run hub export 2>/dev/null)"
echo "$out5" | jq -e '.limits | length == 1 and .[0].id == "fake"' >/dev/null \
  && ok "osrc_limits_summary --json feeds the rail when present" || bad "limits summary feed ignored: $(echo "$out5" | jq -c .limits)"
echo "$out5" | jq -e '.limits[0].updatedAt == "2026-11-13T19:05:00Z" and .limits[0].updated == "19:05"' >/dev/null \
  && ok "summary rows normalized (updatedAt ISO, updated HH:MM)" || bad "summary normalization wrong: $(echo "$out5" | jq -c .limits)"
rm -f "$TMP/bin/osrc_limits_summary"
# Restore the fresh fixture for the serve checks below.
jq -cn --argjson t "${NOW}000" --argjson r5 "$((NOW+7200))" --argjson r7 "$((NOW+400000))" \
  '{five_hour:{used_percentage:95,resets_at:$r5},seven_day:{used_percentage:40,resets_at:$r7},timestamp:$t,source:"statusline"}' \
  > "$OSRC_HOME/rate-limits.json"

echo "=== page structure (design port contract) ==="
PAGE="$HERE/../lib/hub.html"
grep -q 'lucide@0\.469\.0' "$PAGE" && ok "lucide pinned at 0.469.0" || bad "lucide pin missing"
grep -q 'aria-expanded' "$PAGE" && grep -q 'id="lfold"' "$PAGE" && ok "limits rail is a disclosure (lfold aria-expanded)" || bad "limits disclosure missing"
grep -q 'mc-limits-open' "$PAGE" && ok "limits fold persists via localStorage" || bad "fold persistence missing"
grep -q "ok', 'low'" "$PAGE" && ok "folded panel filters to ok|low" || bad "fold predicate missing"
grep -q "Show ' + rest" "$PAGE" && ok "folded panel has 'Show N more' button" || bad "show-more button missing"
grep -q 'LSTATE = {' "$PAGE" && grep -q "unknown:" "$PAGE" && ok "limit states incl. unknown" || bad "LSTATE/unknown missing"
grep -q 'HICONS' "$PAGE" && grep -q 'HALIAS' "$PAGE" && grep -q 'function hlogo' "$PAGE" && ok "harness icons via HICONS/HALIAS/hlogo" || bad "harness icon system missing"
grep -q 'wiz-bob' "$PAGE" && grep -q 'prefers-reduced-motion' "$PAGE" && ok "animated wizard logo + reduced-motion gate" || bad "wizard animation missing"
grep -q '#16171a' "$PAGE" && grep -q '#1f2024' "$PAGE" && grep -q '#34363d' "$PAGE" && ok "dark v2 tokens present" || bad "dark v2 tokens missing"
grep -cq '#18191c' "$PAGE" && bad "old dark tokens still present" || ok "old dark tokens fully replaced"
grep -q "el('div', 'tcol')" "$PAGE" && grep -q '^\.tcol ' "$PAGE" && ok "balanced .tcol theme packing" || bad ".tcol packing missing"
grep -q 'hgt\[0\] <= hgt\[1\]' "$PAGE" && ok "theme cards join the shorter column" || bad "column balance check missing"
grep -q '100dvh' "$PAGE" && grep -q 'rail-top' "$PAGE" && grep -q 'rail-mid' "$PAGE" && ok "rail layout (rail-top/rail-mid/100dvh)" || bad "rail layout missing"
grep -q 'mask' "$PAGE" && grep -q 'data:image/png;base64' "$PAGE" && ok "wordmark css mask (inlined asset)" || bad "wordmark mask missing"
# Item 14: stale alarm + no dialogs (past dashboard bugs).
grep -q 'function staleCheck' "$PAGE" && grep -q 'setInterval(staleCheck' "$PAGE" \
  && grep -q 'stamp-top.stale' "$PAGE" && grep -q 'dataset.at' "$PAGE" \
  && grep -q 'dataset.live' "$PAGE" && grep -q 'not updated for' "$PAGE" \
  && ok "stale alarm wired (staleCheck, data-at/live, .stamp-top.stale)" || bad "stale alarm missing from page"
grep -q "status === 'shipped' ? '' : '1'" "$PAGE" && grep -q 'min > 45' "$PAGE" \
  && ok "stale alarm: shipped exempt, 45min threshold" || bad "stale alarm semantics missing"
if grep -qE '\b(alert|confirm|prompt) *\(' "$PAGE"; then bad "alert/confirm/prompt dialog found in page"; else ok "no alert/confirm/prompt dialogs"; fi
# Item 15: Shipped rail section + red limits stamp.
grep -q 'id="sfold"' "$PAGE" && grep -q 'id="slist"' "$PAGE" && grep -q 'id="shipwrap"' "$PAGE" \
  && grep -q 'mc-shipped-open' "$PAGE" && grep -q "status === 'shipped' ? slist : list" "$PAGE" \
  && ok "Shipped rail section (sfold/slist/shipwrap/mc-shipped-open)" || bad "shipped rail section missing"
grep -q 'done.some((p) => p.id === current)' "$PAGE" \
  && ok "shipped section auto-opens for the current project" || bad "shipped auto-open missing"
grep -q 'lst.stale' "$PAGE" && grep -q "stamp-top, .lst" "$PAGE" \
  && grep -q 'l.updatedAt' "$PAGE" && grep -q "ls.dataset.live = '1'" "$PAGE" \
  && ok "limits stamp joins staleCheck (.lst.stale, updatedAt feed)" || bad "limits stale stamp missing"

one="$(run hub export --project sess-1 2>/dev/null)"
echo "$one" | jq -e '(.projects | length) == 1 and (.projects[0].id == "sess-1")' >/dev/null \
  && ok "--project filters to one slug" || bad "--project filter wrong"
none="$(run hub export --project no-such-slug 2>/dev/null)"
echo "$none" | jq -e '.projects | length == 0' >/dev/null \
  && ok "--project unknown slug -> empty projects" || bad "--project unknown slug wrong"

echo "=== symlink loader (LOADER.md fallback) ==="
ln -s "$SRC" "$TMP/outsourcerer-link"
sym="$(OSRC_HOME="$OSRC_HOME" bash "$TMP/outsourcerer-link" hub export 2>"$TMP/sym.err")" \
  && echo "$sym" | jq -e '.projects | length >= 1' >/dev/null \
  && ok "hub export works through a symlink (lib fallback loader)" \
  || bad "symlink invocation failed: $(cat "$TMP/sym.err")"

echo "=== hub serve (local mode) ==="
command -v curl >/dev/null 2>&1 || { echo "SKIP: curl not installed (serve tests)"; echo "RESULTS: $pass pass $fail fail"; exit $([ $fail -eq 0 ] && echo 0 || echo 1); }
# Pick a free port, then let the OS reuse-check it (small race is fine for a test).
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
OSRC_HOME="$OSRC_HOME" bash "$SRC" hub serve --port "$PORT" --no-open >"$TMP/serve.log" 2>&1 &
SRV=$!
cleanup_srv() { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }
trap 'cleanup_srv; rm -rf "$TMP"' EXIT
URL=""
for _ in $(seq 1 50); do
  URL="$(grep -o 'http://127\.0\.0\.1:[0-9]*/?t=[A-Za-z0-9]*' "$TMP/serve.log" 2>/dev/null | head -1)"
  [ -n "$URL" ] && break
  sleep 0.2
done
[ -n "$URL" ] || { bad "hub serve did not print a token URL"; cat "$TMP/serve.log"; echo "RESULTS: $pass pass $fail fail"; exit 1; }
BASE="${URL%%\?*}"; TOK="${URL##*t=}"
ok "serve printed loopback token URL"
# Item 14: the token persists in $OSRC_HOME/hub/token (0600) so the URL is bookmarkable.
[ -f "$OSRC_HOME/hub/token" ] && ok "token persisted to hub/token" || bad "hub/token missing"
PERM="$(stat -f %Lp "$OSRC_HOME/hub/token" 2>/dev/null || stat -c %a "$OSRC_HOME/hub/token" 2>/dev/null)"
[ "$PERM" = "600" ] && ok "hub/token is mode 0600" || bad "hub/token mode $PERM"
[ "$(cat "$OSRC_HOME/hub/token")" = "$TOK" ] && ok "served token is the persisted token" || bad "served token != persisted token"

code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/projects")"
[ "$code" = "403" ] && ok "api refuses requests without token" || bad "no-token request got $code"
code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/projects?t=wrong")"
[ "$code" = "403" ] && ok "api refuses wrong token" || bad "wrong-token request got $code"

pj="$(curl -s "$BASE/api/projects?t=$TOK")"
echo "$pj" | jq -e '.projects | length >= 1' >/dev/null && ok "GET /api/projects returns export" || bad "api/projects empty"
echo "$pj" | jq -e '(.limits | type == "array") and (.limits[] | select(.id=="openrouter") | .paid == true)' >/dev/null \
  && ok "GET /api/projects carries the limits array" || bad "api/projects missing limits"

pg="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/?t=$TOK")"
[ "$pg" = "200" ] && ok "GET / serves the page" || bad "page GET got $pg"

an0="$(curl -s "$BASE/api/answers?t=$TOK")"
echo "$an0" | jq -e 'type == "object"' >/dev/null && ok "GET /api/answers returns object" || bad "answers GET bad"

post="$(curl -s -X POST "$BASE/api/answers?t=$TOK" -H 'Content-Type: application/json' \
  -d '{"id":"sess-1--D1","project":"sess-1","decision":"D1","question":"Ship the hub?","choice":"yes","note":"lgtm"}')"
echo "$post" | jq -e '.ok == true' >/dev/null && ok "POST /api/answers accepted" || bad "answer POST failed: $post"
[ -f "$OSRC_HOME/hub/answers/sess-1--D1.json" ] && ok "answer written to hub/answers/<id>.json" || bad "answer file missing"
an1="$(curl -s "$BASE/api/answers?t=$TOK")"
echo "$an1" | jq -e '."sess-1--D1".choice == "yes" and ."sess-1--D1".note == "lgtm"' >/dev/null \
  && ok "GET /api/answers round-trips the write" || bad "answers round-trip wrong: $an1"

badpost="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/answers?t=$TOK" \
  -H 'Content-Type: application/json' -d '{"id":"bad id!!","choice":"x"}')"
[ "$badpost" = "400" ] && ok "POST rejects malformed answer id" || bad "bad id got $badpost"
dotpost="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/answers?t=$TOK" \
  -H 'Content-Type: application/json' -d '{"id":"..--x","choice":"x"}')"
[ "$dotpost" = "400" ] && ok "POST rejects id not starting alphanumeric" || bad "dot id got $dotpost"
badhost="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example.com' "$BASE/api/projects?t=$TOK")"
[ "$badhost" = "403" ] && ok "foreign Host header refused" || bad "foreign Host got $badhost"

r0="$(curl -s "$BASE/api/projects?t=$TOK" | jq -r '.generated_at')"
sleep 1
rf="$(curl -s -X POST "$BASE/api/refresh?t=$TOK")"
echo "$rf" | jq -e '(.generated_at | type) == "number" and (.projects | length) >= 1' >/dev/null \
  && ok "POST /api/refresh re-exports" || bad "refresh failed: $(echo "$rf" | head -c 200)"
r1="$(curl -s "$BASE/api/projects?t=$TOK" | jq -r '.generated_at')"
[ "$r1" -ge "$r0" ] && ok "refresh updates generated_at ($r0 -> $r1)" || bad "generated_at did not advance"

# Loopback only: the listening socket must be 127.0.0.1, nothing else.
lsof_out="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null)"
echo "$lsof_out" | grep -q '127\.0\.0\.1:' && ok "server bound to 127.0.0.1 only" || bad "listen addr not loopback: $lsof_out"
echo "$lsof_out" | grep -vqE '127\.0\.0\.1:|\*:' || true
if echo "$lsof_out" | grep -qE '(\*|0\.0\.0\.0|\[::\]):'; then bad "server exposed on a non-loopback address"; fi

# The token must never reach the request log (it is in the printed URL line by design,
# so only the server's own "[hub]" request lines are checked).
if grep '^\[hub\]' "$TMP/serve.log" | grep -q 't='; then bad "token leaked into server log"; else ok "token stripped from request logs"; fi

cleanup_srv

echo "=== item 14: bookmarkable URL, idle refresh ==="
# Helper: launch serve in the background, wait for its printed URL.
wait_url() {  # <logfile> -> URL on stdout
  local u="" i
  for i in $(seq 1 60); do
    u="$(grep -o 'http://127\.0\.0\.1:[0-9]*/?t=[A-Za-z0-9]*' "$1" 2>/dev/null | head -1)"
    [ -n "$u" ] && break; sleep 0.2
  done; printf '%s' "$u"
}

# Restart without --new-token: the persisted token must be reused (bookmark still valid).
PORT2="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
OSRC_HOME="$OSRC_HOME" bash "$SRC" hub serve --port "$PORT2" --no-open >"$TMP/serve2.log" 2>&1 &
SRV=$!
URL2="$(wait_url "$TMP/serve2.log")"
TOK2="${URL2##*t=}"
[ -n "$URL2" ] && [ "$TOK2" = "$TOK" ] \
  && ok "restart reuses the persisted token (bookmarkable URL)" \
  || bad "restart minted a new token"
cleanup_srv

# --new-token rotates: file content changes, mode stays 0600.
OSRC_HOME="$OSRC_HOME" bash "$SRC" hub serve --port "$PORT2" --no-open --new-token >"$TMP/serve3.log" 2>&1 &
SRV=$!
URL3="$(wait_url "$TMP/serve3.log")"
TOK3="${URL3##*t=}"
[ -n "$URL3" ] && [ "$TOK3" != "$TOK" ] && [ "$(cat "$OSRC_HOME/hub/token")" = "$TOK3" ] \
  && ok "--new-token rotates the persisted token" || bad "--new-token did not rotate"
PERM3="$(stat -f %Lp "$OSRC_HOME/hub/token" 2>/dev/null || stat -c %a "$OSRC_HOME/hub/token" 2>/dev/null)"
[ "$PERM3" = "600" ] && ok "rotated hub/token still mode 0600" || bad "rotated token mode $PERM3"
cleanup_srv

# Fixed default port: no --port -> 8788, or the next free one WITH the notice.
OSRC_HOME="$OSRC_HOME" bash "$SRC" hub serve --no-open >"$TMP/serve4.log" 2>&1 &
SRV=$!
URL4="$(wait_url "$TMP/serve4.log")"
P4="$(printf '%s' "$URL4" | sed -E 's|.*127\.0\.0\.1:([0-9]+).*|\1|')"
if [ "$P4" = "8788" ]; then
  ok "default serve bound to the fixed port 8788"
elif [ "$P4" -ge 8789 ] && [ "$P4" -le 8798 ] && grep -q 'busy — serving on' "$TMP/serve4.log"; then
  ok "default port busy -> next free $P4 with notice"
else
  bad "default port check failed (P4=$P4): $(cat "$TMP/serve4.log" | head -5)"
fi
cleanup_srv

# Idle-CPU: REFRESH=1s ticks, IDLE=30s. No state change -> no re-export;
# a file change under OSRC_HOME -> next tick re-exports.
EXPORT_JSON="$OSRC_HOME/hub/export.json"
OSRC_HUB_REFRESH_SECS=1 OSRC_HUB_IDLE_SECS=30 OSRC_HOME="$OSRC_HOME" \
  bash "$SRC" hub serve --port "$PORT2" --no-open >"$TMP/serve5.log" 2>&1 &
SRV=$!
URL5="$(wait_url "$TMP/serve5.log")"
[ -n "$URL5" ] || { bad "idle-test serve did not start"; echo "RESULTS: $pass pass $fail fail"; exit 1; }
curl -s -o /dev/null "${URL5%%\?*}/api/projects?t=${URL5##*t=}"   # a page poll -> refresh stays live
m0="$(stat -f %m "$EXPORT_JSON" 2>/dev/null || stat -c %Y "$EXPORT_JSON")"
sleep 3
m1="$(stat -f %m "$EXPORT_JSON" 2>/dev/null || stat -c %Y "$EXPORT_JSON")"
[ "$m0" = "$m1" ] && ok "no state change -> refresh loop skips the export" \
  || bad "refresh re-exported unchanged state ($m0 -> $m1)"
# Wait for the mtime to move (the export subprocess can take a couple seconds
# under nice); a loop that never fires still fails.
wait_mtime() {  # <file> <baseline> -> 0 when mtime != baseline within ~10s
  local i b="$2"
  for i in $(seq 1 40); do
    [ "$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null)" != "$b" ] && return 0
    sleep 0.25
  done; return 1
}
mkdir -p "$OSRC_HOME/jobs/job-x" && echo running > "$OSRC_HOME/jobs/job-x/status"
wait_mtime "$EXPORT_JSON" "$m1" \
  && ok "state change under OSRC_HOME -> next tick re-exports" \
  || bad "state change did not trigger a re-export"
cleanup_srv

# Idle-stop: REFRESH=1s ticks, IDLE=2s. With no page polling, the loop stops
# even when state changes; a poll wakes it again.
OSRC_HUB_REFRESH_SECS=1 OSRC_HUB_IDLE_SECS=2 OSRC_HOME="$OSRC_HOME" \
  bash "$SRC" hub serve --port "$PORT2" --no-open >"$TMP/serve6.log" 2>&1 &
SRV=$!
URL6="$(wait_url "$TMP/serve6.log")"
[ -n "$URL6" ] || { bad "idle-stop serve did not start"; echo "RESULTS: $pass pass $fail fail"; exit 1; }
sleep 3                                  # now past the 2s idle window, nothing polled
echo still-running > "$OSRC_HOME/jobs/job-x/status"   # state changes while idle
m3="$(stat -f %m "$EXPORT_JSON" 2>/dev/null || stat -c %Y "$EXPORT_JSON")"
sleep 2.5
m4="$(stat -f %m "$EXPORT_JSON" 2>/dev/null || stat -c %Y "$EXPORT_JSON")"
[ "$m3" = "$m4" ] && ok "no page poll for the idle window -> refresh loop stops" \
  || bad "loop kept exporting while idle ($m3 -> $m4)"
curl -s -o /dev/null "${URL6%%\?*}/api/projects?t=${URL6##*t=}"   # a poll wakes it
echo again > "$OSRC_HOME/jobs/job-x/status"
wait_mtime "$EXPORT_JSON" "$m4" \
  && ok "a page poll resumes the refresh loop" \
  || bad "loop did not resume after a poll"
cleanup_srv

echo "RESULTS: $pass pass $fail fail"
[ "$fail" -eq 0 ]
