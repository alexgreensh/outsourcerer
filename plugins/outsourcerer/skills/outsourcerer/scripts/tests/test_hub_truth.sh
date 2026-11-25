#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_hub_truth.sh -- Mission Control tells the truth for every orchestrator (lib/hub-truth.sh).
# Fixtures rebuild what a user saw with four orchestrators at once:
#   stale    a card read "building, 90%" from a 4-day-old report while 19 lanes ran under a second
#            session of the same project: one card now, status/percent/summary from the lanes, the old
#            words shown with their age;
#   silent   an orchestrator that supervises but never ran `hub report` still gets status, % and summary;
#   alerts   "lanes running, orchestrator idle N min" and "lane finished N min ago, nobody picked it up";
#   report   a report newer than every lane still wins; --project KEY merges sessions in different folders;
#   tick     a supervisor's tick is not orchestrator life: the loud alerts survive it;
#   macos    the registry reader under macOS awk (no multi-line -v) and bash 3.2 (a bare `local` is set);
#   pct      a percent comes from a board or a fresh report, never from lane counts;
#   speed    an export with 150 observed sessions stays bounded; two exports at once run one export;
#            a stale lock (dead or reused pid) never freezes the export.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
command -v jq >/dev/null || { echo "SKIP: jq required"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 required"; exit 0; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-hub-truth.XXXXXX")" || { echo "FAIL: no scratch dir" >&2; exit 1; }
SLEEPER=""
trap '[ -z "$SLEEPER" ] || kill "$SLEEPER" 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
NOW="$(date +%s)"
ago() { python3 -c 'import os,sys,time; t=time.time()-int(sys.argv[1])*60; [os.utime(f,(t,t)) for f in sys.argv[2:]]' "$@"; }   # <min> <paths...>
_mt() { python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$1"; }
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }

home() { # <name>: a fresh HOME + OSRC_HOME
  export HOME="$TMP/$1/home" OSRC_HOME="$TMP/$1/osrc"
  export OSRC_JOBS="$OSRC_HOME/jobs" OSRC_CLAUDE_SESSIONS_DIR="$HOME/.claude/sessions" OSRC_CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
  mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects" "$OSRC_HOME/hub/projects" "$OSRC_HOME/jobs"
}
lane() { # <sid> <id> <status> [short]: a job lane owned by <sid>
  mkdir -p "$OSRC_HOME/owners/$1" "$OSRC_JOBS/$2"; : > "$OSRC_HOME/owners/$1/$2"
  printf '%s\n' "$3" > "$OSRC_JOBS/$2/status"; printf '%s\n' "${4:-task $2}" > "$OSRC_JOBS/$2/task_ref"
  printf '{"provider":"codex","lane":"codex","verb":"run"}\n' > "$OSRC_JOBS/$2/meta.json"
}
beat() { mkdir -p "$OSRC_HOME/hub/seen/$1"; touch "$OSRC_HOME/hub/seen/$1/.beat"; [ -z "${2:-}" ] || ago "$2" "$OSRC_HOME/hub/seen/$1/.beat"; }
# The engine as a library; job state comes straight from the status file (no live pids in a fixture).
lib() { ( unset CLAUDE_CODE_SESSION_ID OUTSOURCERER_DEPTH; OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
  _reconcile_status() { cat "$OSRC_JOBS/$1/status" 2>/dev/null; }
  "$@" ); }
export OSRC_HEARTBEAT_DISABLED=1 OSRC_HUB_NO_OPEN=1 OSRC_CATALOG_VALIDATE=0 GIT_CONFIG_NOSYSTEM=1

echo "=== stale: one project, two orchestrators, a 4-day-old report ==="
home stale
cat > "$OSRC_HOME/hub/projects/s-old.json" <<EOF
{"name":"Garden app","repo":"example/garden","status":"building","pct":90,"eta":"Friday","next":"Polish the planner","reportedAt":"$(iso $((NOW - 4*86400)))"}
EOF
mkdir -p "$OSRC_HOME/owners/s-old"; beat s-old 20
printf '{"repo":"example/garden","summary":"Three lanes left.","reportedAt":"%s"}\n' "$(iso $((NOW - 3*86400)))" > "$OSRC_HOME/hub/projects/s-new.json"
ago 4320 "$OSRC_HOME/hub/projects/s-new.json"; ago 5760 "$OSRC_HOME/hub/projects/s-old.json"
for i in $(seq 1 19); do lane s-new "job-$i" running "Garden part $i"; done
beat s-new
out="$(lib cmd_hub_export 2>"$TMP/stale.err")"
cards="$(jq '[.projects[] | select(.repo == "example/garden")] | length' <<<"$out" 2>/dev/null)"
[ "$cards" = 1 ] && ok "two orchestrator sessions on one project make one card" || no "garden cards: $cards $(head -3 "$TMP/stale.err")"
c="$(jq -c '.projects[] | select(.repo == "example/garden")' <<<"$out" 2>/dev/null)"
jq -e '.name == "Garden app" and (.lanes | length) == 19 and (.members | sort) == ["s-new","s-old"]' >/dev/null <<<"$c" \
  && ok "the merged card keeps the reported name and all 19 lanes" || no "merged card: $(jq -c '{name, members, n:(.lanes|length)}' <<<"$c")"
jq -e '.source == "live" and .status == "building" and (has("pct") | not) and .summary == "19 lanes: 19 working" and (has("eta") | not)' >/dev/null <<<"$c" \
  && ok "status and summary come from the running lanes; the 4-day-old 90% is dropped, not replaced by a lane count" || no "derived: $(jq -c '{source,status,pct,summary,eta}' <<<"$c")"
jq -e '.reported.summary == "Three lanes left." and .reported.ageMin >= 4320 and .cardStale == false and ([.. | numbers] | index(90) | not)' >/dev/null <<<"$c" \
  && ok "the newest report rides along with its age, the older 90% is gone, and the live card is not called stale" || no "reported: $(jq -c '{reported,cardStale}' <<<"$c")"
jq -e '[.orchestrators[] | {id, state}] | sort_by(.id) == [{"id":"s-new","state":"working"},{"id":"s-old","state":"idle"}]' >/dev/null <<<"$c" \
  && ok "each orchestrator session is listed with its own state" || no "orchestrators: $(jq -c .orchestrators <<<"$c")"

echo "=== silent: supervising, never reported ==="
home silent
lane s-sup a1 running "Build the importer"; lane s-sup a2 ready "Write the exporter"; beat s-sup
c="$(lib cmd_hub_export 2>/dev/null | jq -c '.projects[] | select(.id == "s-sup")')"
jq -e '.status == "building" and (has("pct") | not) and .summary == "2 lanes: 1 working, 1 ready for review" and .next == "Review Write the exporter" and .source == "live" and (has("reported") | not)' >/dev/null <<<"$c" \
  && ok "an orchestrator that never reported gets status, summary and next step (no percent from 1 of 2 lanes)" || no "silent card: $(jq -c '{status,pct,summary,next,source}' <<<"$c")"

echo "=== alerts: lanes running with the orchestrator idle; a finished lane nobody picked up ==="
home alerts
lane s-idle r1 running "Port the scheduler"; lane s-idle d1 done "Fix the login form"
ago 20 "$OSRC_JOBS/d1"/*; beat s-idle 25
sleep 300 & SLEEPER=$!
printf '{"pid":%s,"sessionId":"s-idle","cwd":"/nowhere","status":"idle","statusUpdatedAt":%s}\n' "$SLEEPER" "$(( (NOW - 1500) * 1000 ))" > "$OSRC_CLAUDE_SESSIONS_DIR/1.json"
c="$(lib cmd_hub_export 2>/dev/null | jq -c '.projects[] | select(.id == "s-idle")')"
jq -e '.orchestrators[0].state == "idle" and .orchestrators[0].idleMin >= 24' >/dev/null <<<"$c" \
  && ok "the orchestrator reads idle for its minutes since the last sign of life" || no "orch: $(jq -c .orchestrators <<<"$c")"
jq -e 'any(.alerts[]?; .kind == "orch-idle" and (.text | test("^lanes running, orchestrator idle 2[4-6] min$")))' >/dev/null <<<"$c" \
  && ok "flag: lanes running, orchestrator idle N min" || no "orch-idle alert: $(jq -c .alerts <<<"$c")"
jq -e 'any(.alerts[]?; .kind == "unpicked" and .lane == "d1" and (.text | test("^lane Fix the login form finished (19|20|21) min ago, nobody picked it up$")))' >/dev/null <<<"$c" \
  && ok "flag: lane finished N min ago, nobody picked it up" || no "unpicked alert: $(jq -c .alerts <<<"$c")"
# The orchestrator reported once (so its supervisor ticks its card); a tick is not the orchestrator's life.
printf '{"name":"Scheduler port","reportedAt":"%s"}\n' "$(iso $((NOW - 7200)))" > "$OSRC_HOME/hub/projects/s-idle.json"; ago 120 "$OSRC_HOME/hub/projects/s-idle.json"
mkdir -p "$TMP/alerts/sv"; b0="$(_mt "$OSRC_HOME/hub/seen/s-idle/.beat")"
lib _sv_tick "$TMP/alerts/sv" "$NOW" >/dev/null 2>&1
[ -s "$TMP/alerts/sv/hub.json" ] || no "the supervisor tick did not run its export"
c="$(lib cmd_hub_export 2>/dev/null | jq -c '.projects[] | select(.id == "s-idle")')"
[ "$(_mt "$OSRC_HOME/hub/seen/s-idle/.beat")" = "$b0" ] && [ ! -e "$OSRC_HOME/hub/auto" ] \
  && jq -e '([.alerts[]? | select(.kind == "orch-idle" or .kind == "unpicked")] | length) == 2 and .orchestrators[0].idleMin >= 24' >/dev/null <<<"$c" \
  && ok "a supervisor's tick does not beat for the orchestrator: both flags survive it" || no "tick hid the alerts: $(jq -c '{o:.orchestrators, a:.alerts}' <<<"$c")"
beat s-idle; touch "$OSRC_CLAUDE_SESSIONS_DIR/1.json"
printf '{"pid":%s,"sessionId":"s-idle","cwd":"/nowhere","status":"busy","statusUpdatedAt":%s}\n' "$SLEEPER" "${NOW}000" > "$OSRC_CLAUDE_SESSIONS_DIR/1.json"
c="$(lib cmd_hub_export 2>/dev/null | jq -c '.projects[] | select(.id == "s-idle")')"
jq -e '.orchestrators[0].state == "working" and ([.alerts[]? | select(.kind == "orch-idle" or .kind == "unpicked")] | length) == 0' >/dev/null <<<"$c" \
  && ok "once the orchestrator works again (after the lane finished) both flags clear" || no "after beat: $(jq -c '{o:.orchestrators, a:.alerts}' <<<"$c")"
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null; SLEEPER=""
c="$(lib cmd_hub_export 2>/dev/null | jq -c '.projects[] | select(.id == "s-idle")')"
jq -e '.orchestrators[0].state == "gone" and any(.alerts[]?; .text == "lanes running, orchestrator gone")' >/dev/null <<<"$c" \
  && ok "a dead orchestrator process reads gone, with lanes still running" || no "gone: $(jq -c '{o:.orchestrators, a:.alerts}' <<<"$c")"

echo "=== report: newer words win; --project joins sessions ==="
home report
lane s-rep q1 done "Ship the docs"; ago 120 "$OSRC_JOBS/q1"/* "$OSRC_JOBS/q1" "$OSRC_HOME/owners/s-rep/q1" "$OSRC_HOME/owners/s-rep"; beat s-rep
( export CLAUDE_CODE_SESSION_ID=s-rep; OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; cmd_hub_report --status review --pct 80 --next "Tag the release" >/dev/null )
c="$(lib cmd_hub_export 2>/dev/null | jq -c '.projects[] | select(.id == "s-rep")')"
jq -e '.source == "report" and .status == "review" and .pct == 80 and .next == "Tag the release" and .reported.ageMin == 0 and .summary == "1 lane: 1 done"' >/dev/null <<<"$c" \
  && ok "a report newer than every lane wins, and the summary still comes from the lanes" || no "report: $(jq -c '{source,status,pct,next,reported,summary}' <<<"$c")"
mkdir -p "$TMP/report/a" "$TMP/report/b"
for s in k-one k-two; do
  ( export CLAUDE_CODE_SESSION_ID=$s; OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
    cmd_hub_report --project garden-v2 --ask "Keep the old planner screen?" --why "The new planner replaces it; keeping both doubles the testing work." --rec "Drop it" --option Keep --option Drop >/dev/null )
done
c="$(lib cmd_hub_export 2>/dev/null | jq -c '[.projects[] | select(.projectKey == "garden-v2")]')"
jq -e 'length == 1 and (.[0].decisions | map(.owner) | sort) == ["k-one","k-two"] and (.[0].decisions | map(.id)) == ["D1","D1"]' >/dev/null <<<"$c" \
  && ok "--project KEY joins sessions into one card; each question keeps its owning session" || no "project key: $(jq -c 'map({id, members, d:[.decisions[]|{id,owner}]})' <<<"$c")"
( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; CLAUDE_CODE_SESSION_ID=k-one cmd_hub_report --project 'bad key' 2>/dev/null ) && no "a bad --project key was accepted" || ok "a bad --project key is refused"

echo "=== macos: BSD awk and bash 3.2 semantics in the registry reader ==="
home macos
mkdir -p "$TMP/macos/w1" "$TMP/macos/bin"
for n in 1 2; do sid="bbbbbbbb-0000-4000-8000-00000000000$n"
  td="$OSRC_CLAUDE_PROJECTS_DIR/$(printf '%s' "$TMP/macos/w1" | tr -c 'A-Za-z0-9' '-')"; mkdir -p "$td"; : > "$td/$sid.jsonl"; ago 3 "$td/$sid.jsonl"
  printf '{"pid":%s,"sessionId":"%s","cwd":"%s","status":"idle","statusUpdatedAt":0}\n' "$$" "$sid" "$TMP/macos/w1" > "$OSRC_CLAUDE_SESSIONS_DIR/$n.json"
done
# A stand-in for macOS awk (20200816): a -v value with a newline is "newline in string", rc 2.
printf '#!/bin/sh\nv=0; for a in "$@"; do case "$v$a" in 1*"\n"*|0-v*"\n"*) echo "awk: newline in string" >&2; exit 2 ;; esac; v=0; [ "$a" = -v ] && v=1; done\nexec %s "$@"\n' "$(command -v awk)" > "$TMP/macos/bin/awk"
chmod 755 "$TMP/macos/bin/awk"
rows_ok() { awk -F'|' -v t="$(( $(date +%s) - 180 ))" 'NF == 9 && $9 >= t - 30 && $9 <= t + 5 { n++ } END { exit !(n == 2) }'; }
PATH="$TMP/macos/bin:$PATH" lib _osrc_hub_cc_rows | rows_ok && ok "the registry reader works where awk rejects a multi-line -v (macOS awk)" || no "rows under BSD-style awk: $(PATH="$TMP/macos/bin:$PATH" lib _osrc_hub_cc_rows 2>&1)"
if command -v original-awk >/dev/null 2>&1; then
  ln -sf "$(command -v original-awk)" "$TMP/macos/bin/awk"
  PATH="$TMP/macos/bin:$PATH" lib _osrc_hub_cc_rows | rows_ok && ok "the registry reader works under the One True AWK (macOS awk's source)" || no "rows under original-awk: $(PATH="$TMP/macos/bin:$PATH" lib _osrc_hub_cc_rows 2>&1)"
fi
# bash 3.2: the export's bare `local _OSRC_HUB_CC_ROWS` leaves it set and empty; that is not a cache.
_OSRC_HUB_CC_ROWS="" lib _osrc_hub_cc_rows | rows_ok && ok "an empty, set _OSRC_HUB_CC_ROWS (bash 3.2 local) is not taken as the cache" || no "bash 3.2 cache: empty rows"
[ "$(_OSRC_HUB_CC_ROWS="x|y" _OSRC_HUB_CC_ROWS_SET=1 lib _osrc_hub_cc_rows)" = 'x|y' ] && ok "the export's computed rows are reused" || no "cache not reused"
# A crashed-then-resumed session leaves its old file behind: the live row wins.
( exit 0 ) & dead=$!; wait "$dead"
printf '{"pid":%s,"sessionId":"s-res","cwd":"/nowhere","status":"busy","statusUpdatedAt":%s}\n' "$dead" "${NOW}000" > "$OSRC_CLAUDE_SESSIONS_DIR/0.json"
printf '{"pid":%s,"sessionId":"s-res","cwd":"/nowhere","status":"busy","statusUpdatedAt":%s}\n' "$$" "${NOW}000" > "$OSRC_CLAUDE_SESSIONS_DIR/9.json"
lib _osrc_hub_orch_state s-res "$NOW" | jq -e '.state == "working"' >/dev/null && ok "a resumed session reads from its live registry row, not a dead leftover" || no "resumed: $(lib _osrc_hub_orch_state s-res "$NOW")"

echo "=== pct: board or fresh report only ==="
home pct
lane s-pct p1 done "Step one"; lane s-pct p2 done "Step two"; lane s-pct p3 running "Step three"; beat s-pct
c="$(lib cmd_hub_export 2>/dev/null | jq -c '.projects[] | select(.id == "s-pct")')"
jq -e 'has("pct") | not' >/dev/null <<<"$c" && ok "2 of 3 lanes done invents no percent" || no "pct from lane counts: $(jq -c '{pct}' <<<"$c")"
( export CLAUDE_CODE_SESSION_ID=s-pct; OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; cmd_hub_report --pct 15 >/dev/null )
c="$(lib cmd_hub_export 2>/dev/null | jq -c '.projects[] | select(.id == "s-pct")')"
jq -e '.pct == 15 and .source == "live"' >/dev/null <<<"$c" && ok "a fresh reported percent stays while lanes run" || no "fresh pct: $(jq -c '{pct,source}' <<<"$c")"
c="$(lib _osrc_hub_truth '{"liveLanes":1,"boardTracks":20,"pct":10,"reportedAt":"2020-01-01T00:00:00Z","reported":{"pct":10},"derived":{"n":3,"working":1,"blocked":0,"idle":0,"ready":0,"done":2,"merged":0,"failed":0,"canceled":0,"pick":{"blocked":[],"ready":[],"done":["a","b"],"failed":[]},"finished":[],"evidenceAt":0}}' "$NOW")"
jq -e '.pct == 10 and .source == "live"' >/dev/null <<<"$c" && ok "a board's percent (20 tracks) is kept while lanes run" || no "board pct: $c"

echo "=== speed: 150 observed sessions; single-flight ==="
home speed
lane s-fast f1 running "Tune the cache"; beat s-fast
for i in $(seq 1 150); do
  sid="aaaaaaaa-0000-4000-8000-$(printf '%012d' "$i")"; cwd="$TMP/speed/work/p$((i % 20))"; mkdir -p "$cwd"
  td="$OSRC_CLAUDE_PROJECTS_DIR/$(printf '%s' "$cwd" | tr -c 'A-Za-z0-9' '-')"; mkdir -p "$td"
  printf '{"type":"user","message":{"content":"fix the thing %s"}}\n' "$i" > "$td/$sid.jsonl"
  printf '{"pid":%s,"sessionId":"%s","cwd":"%s","status":"%s","statusUpdatedAt":%s}\n' "$$" "$sid" "$cwd" \
    "$([ $((i % 3)) = 0 ] && echo busy || echo idle)" "${NOW}000" > "$OSRC_CLAUDE_SESSIONS_DIR/$i.json"
done
printf '{"pid":%s,"sessionId":"broken"' "$$" > "$OSRC_CLAUDE_SESSIONS_DIR/zz.json"   # one malformed file
# Speed is measured by work, not by the clock: a loaded machine stretches seconds, never jq launches.
# The slow export ran ~20 jq per observed session (3000+ here); the bound is per export, not per session.
mkdir -p "$TMP/jqcount"; real_jq="$(command -v jq)"
printf '#!/bin/sh\necho x >> "%s/jqcount/n"\nexec "%s" "$@"\n' "$TMP" "$real_jq" > "$TMP/jqcount/jq"; chmod +x "$TMP/jqcount/jq"
t0="$(python3 -c 'import time; print(time.time())')"
out="$(PATH="$TMP/jqcount:$PATH" lib cmd_hub_export 2>/dev/null)"
dt="$(python3 -c "import time; print(round(time.time() - $t0, 1))")"
njq="$(wc -l < "$TMP/jqcount/n" | tr -d ' ')"; maxjq="${OSRC_TEST_EXPORT_MAX_JQ:-150}"; max="${OSRC_TEST_EXPORT_MAX:-60}"
[ "$njq" -lt "$maxjq" ] && python3 -c "import sys; sys.exit(0 if $dt < $max else 1)" \
  && ok "export with 150 observed sessions: $njq jq launches (limit $maxjq; was 3000+), ${dt}s" || no "export: $njq jq launches (limit $maxjq), ${dt}s (limit ${max}s)"
jq -e '(.also | length) == 12 and (.also[0].state == "working") and any(.projects[]; .id == "s-fast")' >/dev/null <<<"$out" \
  && ok "Also running lists 12 sessions, busy first, despite a malformed session file" || no "also: $(jq -c '[.also[]?.state]' <<<"$out")"
sf() { ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
  _osrc_hub_export_run() { echo x >> "$OSRC_HOME/runs"; sleep 2; printf '{"run":%s}\n' "$(grep -c x "$OSRC_HOME/runs")"; }
  cmd_hub_export ) > "$TMP/sf.$1"; }
rm -f "$OSRC_HOME/runs"; sf 1 & p1=$!; sleep 0.5; sf 2 & p2=$!; wait "$p1" "$p2"
[ "$(grep -c x "$OSRC_HOME/runs")" = 1 ] && [ "$(cat "$TMP/sf.1")" = '{"run":1}' ] && [ "$(cat "$TMP/sf.2")" = '{"run":1}' ] \
  && ok "two exports at once run one export; the second caller reuses its result" || no "single-flight: runs=$(grep -c x "$OSRC_HOME/runs") out1=$(cat "$TMP/sf.1") out2=$(cat "$TMP/sf.2")"
lk="$OSRC_HOME/hub/flight/all.f00.lock"; mkdir -p "$lk"; ( exit 0 ) & dead=$!; wait "$dead"; echo "$dead" > "$lk/pid"
echo junk > "$OSRC_HOME/hub/flight/all.f00.json.$dead"
rm -f "$OSRC_HOME/runs"; sf 3
[ "$(cat "$TMP/sf.3")" = '{"run":1}' ] && [ ! -d "$lk" ] && [ ! -e "$OSRC_HOME/hub/flight/all.f00.json.$dead" ] \
  && ok "a lock left by a dead export is taken over, with its temp file" || no "dead leader: $(cat "$TMP/sf.3")"
echo junk > "$OSRC_HOME/hub/flight/all.f00.json.99999"; ago 120 "$OSRC_HOME/hub/flight/all.f00.json.99999"
# A SIGKILLed leader whose pid now belongs to a long-lived process ($$): the lock is old, so it is taken over.
mkdir -p "$lk"; echo "$$" > "$lk/pid"; ago 2 "$lk"
rm -f "$OSRC_HOME/runs"; t0="$(date +%s)"; OSRC_HUB_EXPORT_WAIT=8 sf 4
[ ! -e "$OSRC_HOME/hub/flight/all.f00.json.99999" ] && ok "an hour-old temp file of a reused pid is swept" || no "temp file of a reused pid leaked"
[ "$(cat "$TMP/sf.4")" = '{"run":1}' ] && [ ! -d "$lk" ] && [ $(( $(date +%s) - t0 )) -lt 6 ] \
  && ok "a stale lock with a reused live pid is taken over at once and cleared" || no "reused pid: $(cat "$TMP/sf.4") lock=$([ -d "$lk" ] && echo left) took $(( $(date +%s) - t0 ))s"
rm -rf "$lk"
# Back-to-back leaders: a follower takes the first result written after it arrived.
mkdir -p "$lk"; echo "$$" > "$lk/pid"
( sleep 1; printf '{"run":"other"}\n' > "$OSRC_HOME/hub/flight/w"; mv -f "$OSRC_HOME/hub/flight/w" "$OSRC_HOME/hub/flight/all.f00.json" ) &
OSRC_HUB_EXPORT_WAIT=6 sf 5; wait
[ "$(cat "$TMP/sf.5")" = '{"run":"other"}' ] && ok "a follower does not wait through the next leader once a fresh result exists" || no "follower starved: $(cat "$TMP/sf.5")"
rm -rf "$lk"

echo "RESULTS: $pass pass $fail fail"
[ "$fail" -eq 0 ]
