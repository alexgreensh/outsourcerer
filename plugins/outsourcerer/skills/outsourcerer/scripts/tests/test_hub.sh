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

echo "=== hub export: limits ==="
lim="$(echo "$out" | jq -c '.limits')"
echo "$lim" | jq -e 'type == "array" and length >= 4' >/dev/null && ok "limits array present" || bad "limits missing: $lim"
echo "$lim" | jq -e 'all(.[]; (.name | type == "string") and (.state | IN("ok","low","out","wait")) and (.order | type == "number"))' >/dev/null \
  && ok "every limit row has name/state ok|low|out|wait/order" || bad "limit row shape wrong: $lim"
echo "$lim" | jq -e '.[] | select(.id=="claude-5h") | .state == "out" and (.left | test("left")) and (.renews | type == "string") and (.updated | type == "string")' >/dev/null \
  && ok "claude-5h: 95% used -> out with left/renews/updated" || bad "claude-5h row wrong: $(echo "$lim" | jq -c '.[]|select(.id=="claude-5h")')"
echo "$lim" | jq -e '.[] | select(.id=="claude-weekly") | .state == "ok"' >/dev/null \
  && ok "claude-weekly: 40% used -> ok" || bad "claude-weekly row wrong"
echo "$lim" | jq -e '.[] | select(.id=="openrouter") | .paid == true' >/dev/null \
  && ok "openrouter row carries the paid tag" || bad "openrouter paid flag missing"
echo "$lim" | jq -e '[.[] | select(.paid == true)] | length == 1' >/dev/null \
  && ok "exactly one paid lane" || bad "paid lane count wrong"
echo "$lim" | jq -e '.[] | select(.id=="openrouter") | (.models | type == "string") and (.note | type == "string")' >/dev/null \
  && ok "limit rows carry models+note" || bad "models/note missing"
# A stale artifact (>10min old) must degrade to wait, never fake a reading.
jq -cn --argjson t "$(( (${NOW} - 1200) * 1000 ))" --argjson r5 "$((NOW+7200))" --argjson r7 "$((NOW+400000))" \
  '{five_hour:{used_percentage:95,resets_at:$r5},seven_day:{used_percentage:40,resets_at:$r7},timestamp:$t,source:"statusline"}' \
  > "$OSRC_HOME/rate-limits.json"
out2="$(run hub export 2>/dev/null)"
echo "$out2" | jq -e '[.limits[] | select(.id | startswith("claude")) | .state] | all(. == "wait")' >/dev/null \
  && ok "stale artifact -> claude rows wait" || bad "stale artifact not wait: $(echo "$out2" | jq -c '.limits[]|select(.id|startswith("claude"))')"
# No artifact at all -> still a valid array with a wait row and the unmetered lanes.
rm -f "$OSRC_HOME/rate-limits.json"
out3="$(run hub export 2>/dev/null)"
echo "$out3" | jq -e '(.limits | type == "array") and (.limits[] | select(.id=="claude") | .state == "wait")' >/dev/null \
  && ok "missing artifact -> claude wait row, array still valid" || bad "missing-artifact limits wrong"
echo "$out3" | jq -e '.limits[] | select(.id=="openrouter") | .paid == true' >/dev/null \
  && ok "paid lane present without meters" || bad "unmetered rows missing"
# Restore the fresh fixture for the serve checks below.
jq -cn --argjson t "${NOW}000" --argjson r5 "$((NOW+7200))" --argjson r7 "$((NOW+400000))" \
  '{five_hour:{used_percentage:95,resets_at:$r5},seven_day:{used_percentage:40,resets_at:$r7},timestamp:$t,source:"statusline"}' \
  > "$OSRC_HOME/rate-limits.json"

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

echo "RESULTS: $pass pass $fail fail"
[ "$fail" -eq 0 ]
