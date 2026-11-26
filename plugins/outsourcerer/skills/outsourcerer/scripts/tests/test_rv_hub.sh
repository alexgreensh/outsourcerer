#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_rv_hub.sh -- release review, second pass (F32-F51): Mission Control says only what is true, and
# its token stays with its own hub. One section per finding; each failed on the reviewed commit.
# Usage: test_rv_hub.sh [F32 F36 ...]   (no argument: every section). Sandboxed HOME + OSRC_HOME.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"; LIB="$HERE/../lib"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-rv-hub.XXXXXX")" || { echo "FAIL: no scratch dir" >&2; exit 1; }
PIDS=""
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
no() { echo "FAIL: $1"; fail=$((fail+1)); }
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc" OSRC_HEARTBEAT_DISABLED=1 OSRC_HUB_NO_OPEN=1 OSRC_CATALOG_VALIDATE=0 GIT_CONFIG_NOSYSTEM=1
export OSRC_JOBS="$OSRC_HOME/jobs" OSRC_CLAUDE_SESSIONS_DIR="$HOME/.claude/sessions" OSRC_CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
unset CLAUDE_CODE_SESSION_ID OSRC_HUB_FAST OSRC_HUB_PORT TMUX
mkdir -p "$OSRC_CLAUDE_SESSIONS_DIR" "$OSRC_CLAUDE_PROJECTS_DIR" "$OSRC_JOBS" "$OSRC_HOME/hub/projects"
lib() { ( unset OUTSOURCERER_DEPTH; OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
  _reconcile_status() { cat "$OSRC_JOBS/$1/status" 2>/dev/null; }
  "$@" ); }
SEL="$*"
on() { [ -z "$SEL" ] && return 0; case " $SEL " in *" $1 "*) return 0 ;; esac; return 1; }
NODE="$(command -v node 2>/dev/null || true)"
dom() {   # <section>: the page checks in hub_rv_dom.js
  [ -n "$NODE" ] || { echo "SKIP: node not installed ($1 page checks)"; return 0; }
  local r rc; r="$("$NODE" "$HERE/hub_rv_dom.js" "$LIB" "$1" 2>&1)"; rc=$?
  printf '%s\n' "$r" | grep -E '^(PASS|FAIL)'
  pass=$((pass + $(grep -c '^PASS' <<<"$r"))); fail=$((fail + $(grep -c '^FAIL' <<<"$r")))
  [ "$rc" = 0 ] || [ "$(grep -c '^FAIL' <<<"$r")" -gt 0 ] || no "hub_rv_dom.js $1 exited $rc: $r"
}

# srv_start <engine-script-body> -> a real hub_server.py on a free port with a fake engine; sets SRV_PORT,
# SRV_TOK, SRV_HOME. The engine is a shell script that stands in for `outsourcerer.sh hub export`.
SRV_N=0
srv_start() {   # SRV_TOK preset = use that token
  SRV_N=$((SRV_N + 1)); SRV_HOME="${SRV_REUSE:-$TMP/srv$SRV_N}"; mkdir -p "$SRV_HOME/hub"; chmod 700 "$SRV_HOME/hub"
  printf '#!/bin/sh\n%s\n' "$1" > "$SRV_HOME/engine"; chmod +x "$SRV_HOME/engine"
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "$SRV_HOME/hub/export.json"
  SRV_TOK="${SRV_TOK_SET:-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')}"
  OSRC_HUB_TOKEN="$SRV_TOK" python3 -I "$LIB/hub_server.py" --bind 127.0.0.1 --port 0 --page "$LIB/hub.html" \
    --engine "$SRV_HOME/engine" --osrc-home "$SRV_HOME" --no-open > "$SRV_HOME/out" 2> "$SRV_HOME/err" &
  PIDS="$PIDS $!"; SRV_PID=$!
  local i; SRV_PORT=""
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    SRV_PORT="$(sed -n 's|.*http://127\.0\.0\.1:\([0-9]*\)/.*|\1|p' "$SRV_HOME/out" 2>/dev/null | head -1)"
    [ -n "$SRV_PORT" ] && break; sleep 0.25
  done
  [ -n "$SRV_PORT" ]
}
srv_get() { curl -s -m 10 -H "X-Hub-Token: $SRV_TOK" "http://127.0.0.1:$SRV_PORT$1"; }
SAVED='{"generated_at":1700000000,"projects":[{"id":"p1","name":"P1","lanes":[{"id":"l1","status":"Building"}]}]}'

on F32 && dom F32

if on F33; then
  dom F33
  if srv_start 'sleep 1; echo "engine broke" >&2; exit 1' "$SAVED"; then
    sleep 2.5; j="$(srv_get /api/projects)"
    jq -e '(.export_error | test("engine broke")) and (.export_error_since | type == "number") and .export_error_since > 1700000000' >/dev/null 2>&1 <<<"$j" \
      && ok "F33: a failing export is sent to the page with export_error and since when" || no "F33: payload: $j"
  else no "F33: the hub did not start: $(cat "$SRV_HOME/err")"; fi
fi

if on F34; then
  dom F34
  if srv_start 'sleep 4; exit 1' "$SAVED"; then
    j="$(srv_get /api/projects)"
    jq -e '.warming == true and .projects[0].id == "p1"' >/dev/null 2>&1 <<<"$j" \
      && ok "F34: a warm start serves the saved export marked warming" || no "F34: payload: $j"
  else no "F34: the hub did not start: $(cat "$SRV_HOME/err")"; fi
fi

if on F35; then
  # One project rebuilt while full exports fail: the doc keeps its old generated_at (the page's
  # "lane data from N ago" hint stays honest for every other project); only that project is stamped now.
  mkdir -p "$TMP/f35/hub"; printf '#!/bin/sh\necho '"'"'{"generated_at":1,"projects":[{"id":"a","name":"A2"}]}'"'"'\n' > "$TMP/f35/engine"; chmod +x "$TMP/f35/engine"
  r="$(cd "$LIB" && T="$TMP/f35" python3 -I -c '
import os, sys, time; sys.path.insert(0, os.getcwd()); import hub_server as h
t = os.environ["T"]; hub = h.Hub(t, t + "/engine", "hub.html", "x")
hub.cache = {"generated_at": 1000, "projects": [{"id": "a", "name": "A"}, {"id": "b", "name": "B"}]}
d = hub._merge_project_export("a", 10); now = time.time()
pa = [p for p in d["projects"] if p["id"] == "a"][0]; pb = [p for p in d["projects"] if p["id"] == "b"][0]
print(d["generated_at"], pa["name"], abs(pa.get("generated_at", 0) - now) < 30, "generated_at" in pb)' 2>&1)"
  [ "$r" = "1000 A2 True False" ] && ok "F35: a one-project refresh keeps the doc's generated_at and stamps only that project" || no "F35: $r"
fi

# mkjob <id> <status> [reason] [exit] -> a job dir with a codex meta.json
mkjob() { mkdir -p "$OSRC_JOBS/$1"; echo "$2" > "$OSRC_JOBS/$1/status"; echo '{"provider":"codex","verb":"run"}' > "$OSRC_JOBS/$1/meta.json"
  [ -z "${3:-}" ] || echo "$3" > "$OSRC_JOBS/$1/reason"; [ -z "${4:-}" ] || echo "$4" > "$OSRC_JOBS/$1/exit"; }

if on F36; then
  mkjob f36 'done?' exited-0-without-OSRC-DONE 0
  s1="$(lib eval 'osrc_done_state() { echo done; }; _osrc_hub_lane_job f36' | jq -r .status)"
  s2="$(lib eval 'osrc_done_state() { echo not-done; }; _osrc_hub_lane_job f36' | jq -r .status)"
  [ "$s1" = Done ] && ok "F36: a verified done contract reads Done even without the marker" || no "F36: verified contract shows $s1"
  [ "$s2" = Unverified ] && ok "F36: no contract and no marker still reads Unverified" || no "F36: unverified shows $s2"
fi

if on F37; then
  # The delegate exited 0 and the supervisor (still alive) has not reconciled yet: status still running.
  mkjob f37 running '' 0
  s1="$(lib eval 'osrc_done_state() { echo not-done; }; _osrc_hub_job_state f37')"
  s2="$(lib eval 'osrc_done_state() { echo not-done; }; _osrc_hub_lane_job f37' | jq -r .status)"
  [ "$s1" = 'done?' ] && [ "$s2" = Unverified ] && ok "F37: exit 0 before reconcile reads Unverified, never Done first" || no "F37: state $s1, status $s2"
  mkjob f37b running '' 3
  [ "$(lib _osrc_hub_job_state f37b)" = failed ] && ok "F37: a non-zero exit still reads failed" || no "F37: rc 3 reads $(lib _osrc_hub_job_state f37b)"
fi

if on F38; then
  # Lanes that left the registry: nothing behind them, or a last status of Building or Idle, is "Closed";
  # only done evidence (a Done row) reads Done.
  r1="$(lib _osrc_hub_ended_lane gone-lane '{}' | jq -r '"\(.status)|\(.note)|\(.ended)"')"
  r2="$(lib eval '_osrc_hub_lane_absent() { return 1; }; _osrc_hub_lane_for() { printf "{\"id\":\"$1\",\"status\":\"Building\"}"; }; _osrc_hub_ended_lane b1 "{}"' | jq -r .status)"
  r3="$(lib eval '_osrc_hub_lane_absent() { return 1; }; _osrc_hub_lane_for() { printf "{\"id\":\"$1\",\"status\":\"Done\"}"; }; _osrc_hub_ended_lane d1 "{}"' | jq -r .status)"
  [ "$r1" = "Closed|session closed|true" ] && ok "F38: a lane with nothing left reads Closed, not Done" || no "F38: nothing left reads $r1"
  [ "$r2" = Closed ] && ok "F38: an ended lane last seen Building reads Closed" || no "F38: Building ended reads $r2"
  [ "$r3" = Done ] && ok "F38: an ended lane with done evidence still reads Done" || no "F38: Done ended reads $r3"
  r4="$(lib _osrc_hub_truth '{"lanes":[{"id":"c","status":"Closed","ended":true}]}' "$(date +%s)" | jq -c '{a: .lanes[0].attention, s: .derived.summary}')"
  case "$r4" in *'"a":"working"'*|*working*) no "F38: a Closed lane counts as working: $r4" ;; *) ok "F38: a Closed lane is not counted as working ($r4)" ;; esac
  grep -q "'Closed'" "$LIB/hub-assets/hub-home.js" && ok "F38: the page lists Closed among ended lanes" || no "F38: hub-home.js ENDED lacks Closed"
fi

if on F39; then
  # A review verdict MERGE is an approval; only a landed flag or a merged PR / closed-merged item says Merged.
  mkdir -p "$OSRC_HOME/remote" "$OSRC_HOME/review/items" "$OSRC_HOME/hub/cache"
  echo '{"branch":"feat-r1","head":"abc1234def","repo":"acme/widget"}' > "$OSRC_HOME/remote/r1.json"
  rs() { lib eval "osrc_remote_state() { echo $1; }; _osrc_review_verdict_for() { printf '%s' '$2'; }; _osrc_hub_lane_for_raw r1 '{}'" | jq -r '"\(.status)|\(.pct // "")"'; }
  a="$(rs done MERGE)"; b="$(rs done '')"
  [ "$a" = "Approved|" ] && ok "F39: a cloud lane with a MERGE verdict reads Approved" || no "F39: MERGE verdict reads $a"
  [ "$b" = "Done|100" ] && ok "F39: a done cloud lane with no verdict reads Done, not Merged" || no "F39: done, no verdict reads $b"
  echo '{"head":"abc1234def","state":"closed","closed_reason":"merged"}' > "$OSRC_HOME/review/items/r1-abc1234.json"
  c="$(rs done MERGE)"
  [ "$c" = "Merged|100" ] && ok "F39: a closed-as-merged review item reads Merged" || no "F39: closed-merged reads $c"
  mkjob j39 done
  d="$(lib _osrc_hub_lane_for_raw j39 '{"j39":"MERGE"}' | jq -r '"\(.status)|\(.pct // "")"')"
  [ "$d" = "Approved|" ] && ok "F39: a job with a MERGE verdict reads Approved, not Merged 100%" || no "F39: job MERGE reads $d"
  echo '{"prs":[{"number":7,"headRefName":"feat-j39","mergedAt":"2026-11-01T00:00:00Z","closedAt":"2026-11-01T00:00:00Z"}]}' > "$OSRC_HOME/hub/cache/gh-acme_widget.json"
  e="$(lib _osrc_hub_lanes_prs '[{"id":"j39","status":"Approved","branch":"feat-j39"}]' acme/widget | jq -r '.[0] | "\(.status)|\(.pct // "")|\(.prs)"')"
  [ "$e" = "Merged|100|#7" ] && ok "F39: an approved lane whose PR merged reads Merged" || no "F39: merged PR reads $e"
  r5="$(lib _osrc_hub_truth '{"lanes":[{"id":"x","status":"Approved"}]}' "$(date +%s)" | jq -r '.lanes[0].attention')"
  [ "$r5" = ready ] && ok "F39: an Approved lane is ready to land, not working" || no "F39: Approved attention $r5"
fi

if on F40; then
  # A stalled lane is not activity: the project's "no update for X h" alarm must be able to fire.
  for st in 'stalled?' no-progress-writes running; do
    id="f40-$(printf '%s' "$st" | tr -dc 'a-z')"; mkjob "$id" "$st"
    lv="$(lib eval 'osrc_done_state() { echo not-done; }; _osrc_hub_lane_activity '"$id")"; lv="${lv##* }"
    case "$st" in running) [ "$lv" = 1 ] && ok "F40: a running lane is live" || no "F40: running reads live=$lv" ;;
      *) [ "$lv" = 0 ] && ok "F40: a $st lane is not live activity" || no "F40: $st reads live=$lv" ;; esac
  done
fi

if on F41; then
  # No repo on the card: another repo's PR on a common branch name must not be borrowed.
  mkdir -p "$OSRC_HOME/hub/cache"
  echo '{"prs":[{"number":9,"headRefName":"main"}]}' > "$OSRC_HOME/hub/cache/gh-other_repo.json"
  a="$(lib _osrc_hub_lanes_prs '[{"id":"l","status":"Building","branch":"main"}]' '' | jq -r '.[0].prs // "none"')"
  b="$(lib _osrc_hub_lanes_prs '[{"id":"l","status":"Building","branch":"main"}]' other/repo | jq -r '.[0].prs // "none"')"
  [ "$a" = none ] && ok "F41: with no repo slug no PR is looked up" || no "F41: borrowed $a from another repo"
  [ "$b" = '#9' ] && ok "F41: with the card's repo the PR is found" || no "F41: own repo PR reads $b"
fi

if on F42; then
  # A pr:/check: contract that is already met: the one-shot `hub export` asks it now; only the serve loop
  # (OSRC_HUB_FAST=1) answers from the last verdict and queues the refresh.
  mkdir -p "$OSRC_HOME/done" "$OSRC_HOME/hub/cache/scr"
  echo '{"spec":"pr:acme/widget#7","cwd":"/"}' > "$OSRC_HOME/done/d42.json"
  q='osrc_done_state() { echo done; }; _osrc_done_cache_peek() { :; }; _osrc_hub_memo_begin; osrc_done_state d42; _osrc_hub_memo_end'
  a="$(OSRC_HUB_FAST=0 lib eval "$q")"; b="$(OSRC_HUB_FAST=1 lib eval "$q")"
  [ "$a" = done ] && ok "F42: a one-shot export resolves an uncached pr: contract inline" || no "F42: one-shot reads $a"
  [ "$b" = not-done ] && ok "F42: the serve loop keeps the cached, queued path" || no "F42: serve loop reads $b"
  printf '{"spec":"check:true","cwd":"%s"}\n' "$TMP" > "$OSRC_HOME/done/d42c.json"
  q='_osrc_hub_memo_begin; osrc_done_state d42c; _osrc_hub_memo_end'
  b="$(OSRC_HUB_FAST=1 lib eval "$q")"; a="$(OSRC_HUB_FAST=0 lib eval "$q")"
  [ "$b" = not-done ] && [ "$a" = done ] && ok "F42: a check: with no verdict yet runs in the one-shot export (serve loop: deferred)" || no "F42: check: one-shot=$a serve=$b"
  rm -f "$OSRC_HOME"/hub/cache/scr/.dwant.*
fi

if on F43; then
  # Two exports in a row with a slow check: contract: their detached workers must not run it together.
  mkdir -p "$OSRC_HOME/hub/cache/scr"; : > "$TMP/f43.log"
  ( unset OUTSOURCERER_DEPTH; OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
    _osrc_hub_rawosrc_done_state() { echo "start $1" >> "$TMP/f43.log"; sleep 2; echo "end $1" >> "$TMP/f43.log"; }
    for i in 1 2 3; do echo d43 > "$OSRC_HOME/hub/cache/scr/.dwant.$$"; _osrc_hub_scr_flush_wanted; sleep 0.3; done )
  sleep 5
  seq="$(tr '\n' ' ' < "$TMP/f43.log")"
  case "$seq" in "start d43 end d43 "|"start d43 end d43 start d43 end d43 "*) ok "F43: one done-probe worker at a time ($seq)" ;;
    *) no "F43: workers ran the same check together: $seq" ;; esac
  [ ! -d "$OSRC_HOME/hub/cache/scr/.dlock" ] && ok "F43: the worker lock is released" || no "F43: lock left behind"
fi

if on F44; then
  # Decisions written without ids get D1, D2...: answerable (the server's id regex) and distinct in the DOM.
  mkdir -p "$OSRC_HOME/hub/decisions"
  echo '{"decisions":[{"q":"First?"},{"q":"Second?"},{"id":"keep","q":"Third?"},{"id":"","q":"Fourth?"}]}' > "$OSRC_HOME/hub/decisions/s44.json"
  ids="$(lib _osrc_hub_decisions s44 | jq -c '[.[].id]')"
  [ "$ids" = '["D1","D2","keep","D4"]' ] && ok "F44: id-less decisions get D1, D2...; a given id is kept" || no "F44: ids $ids"
fi

if on F45; then
  # A row whose text says "error" keeps the rail; only output that is not a JSON array is dropped.
  a="$(lib eval '_osrc_hub_limits_cached() { printf "%s" "[{\"id\":\"cx\",\"name\":\"Codex\",\"state\":\"unknown\",\"note\":\"codex app-server refused: error\"}]"; }; cmd_hub_export' 2>/dev/null | jq -c '[.limits[].id]')"
  b="$(lib eval '_osrc_hub_limits_cached() { printf "error: probe crashed"; }; cmd_hub_export' 2>/dev/null | jq -c '.limits')"
  [ "$a" = '["cx"]' ] && ok "F45: a limits row whose note says 'error' stays on the rail" || no "F45: rail $a"
  [ "$b" = '[]' ] && ok "F45: output that is not a JSON array still empties the rail" || no "F45: bad output gave $b"
fi

if on F46; then
  # One bad project never drops out silently or takes the others with it.
  for p in s46a s46b s46c; do mkdir -p "$OSRC_HOME/owners/$p" "$OSRC_HOME/hub/seen/$p"; touch "$OSRC_HOME/hub/seen/$p/.beat"; mkjob "j-$p" running; : > "$OSRC_HOME/owners/$p/j-$p"; done
  echo '{"name":"Order typo","order":"first"}' > "$OSRC_HOME/hub/projects/s46a.json"
  echo '{"name":"Good B"}' > "$OSRC_HOME/hub/projects/s46b.json"; echo '{"name":"Good C"}' > "$OSRC_HOME/hub/projects/s46c.json"
  a="$(lib cmd_hub_export 2>/dev/null | jq -c '[.projects[] | select(.id | startswith("s46")) | .id] | sort')"
  [ "$a" = '["s46a","s46b","s46c"]' ] && ok "F46: a card with a non-numeric order still exports its project" || no "F46: projects $a"
  b="$(lib eval '_osrc_hub_build_project() { [ "$1" = s46b ] && return 1; printf "{\"id\":\"%s\",\"name\":\"%s\",\"lanes\":[],\"decisions\":[],\"liveLanes\":1}\n" "$1" "$1"; }; cmd_hub_export' 2>/dev/null \
    | jq -c '[.projects[] | select(.id | startswith("s46")) | {id, e: ((.exportError // "") != "")}] | sort_by(.id)')"
  [ "$b" = '[{"id":"s46a","e":false},{"id":"s46b","e":true},{"id":"s46c","e":false}]' ] && ok "F46: a project whose build fails is a stub with exportError" || no "F46: build failure gave $b"
  c="$(lib eval 'eval "$(declare -f _osrc_hub_truth | sed "1s/^_osrc_hub_truth /_rv_truth /")"; _osrc_hub_truth() { case "$1" in *\"s46c\"*) echo "not json" ;; *) _rv_truth "$@" ;; esac; }; cmd_hub_export' 2>/dev/null \
    | jq -c '[.projects[] | select(.id | startswith("s46")) | {id, e: ((.exportError // "") != "")}] | sort_by(.id)')"
  [ "$c" = '[{"id":"s46a","e":false},{"id":"s46b","e":false},{"id":"s46c","e":true}]' ] && ok "F46: one bad truth pass keeps every project (that one marked)" || no "F46: truth failure gave $c"
fi

if on F47; then
  # A screen served from the cache because its refresh keeps failing says how old it is.
  mkdir -p "$OSRC_HOME/hub/cache/scr"
  printf '200 0 %s\nworking\nlast seen working\n' "$(( $(date +%s) - 300 ))" > "$OSRC_HOME/hub/cache/scr/s47"
  q='_osrc_hub_memo_begin; printf "s47 100 200\n" > "$_OSRC_HUB_MEMO/tmux"; _osrc_hub_lane_live_fields "{\"id\":\"s47\",\"status\":\"Building\",\"note\":\"interactive session\"}" s47; _osrc_hub_memo_end'
  r="$(OSRC_HUB_FAST=1 lib eval "$q" | jq -c '{state, stateAgeMin, note}')"
  [ "$r" = '{"state":"working","stateAgeMin":5,"note":"interactive session; state from 5 min ago"}' ] && ok "F47: a stale cached screen carries 'state from N min ago'" || no "F47: $r"
  printf '200 0 %s\nworking\nlast seen working\n' "$(date +%s)" > "$OSRC_HOME/hub/cache/scr/s47"
  r="$(OSRC_HUB_FAST=1 lib eval "$q" | jq -c '{stateAgeMin, note}')"
  [ "$r" = '{"stateAgeMin":null,"note":"interactive session"}' ] && ok "F47: a fresh screen carries no age note" || no "F47: fresh $r"
fi

if on F48; then
  # Two sessions' D1 on one merged card: the Home buttons carry the owning session, as the decision cards do.
  H="$LIB/hub-assets/hub-home.js"
  for k in gn tp; do
    grep -Fq "b.id = '$k-' + p.id + '-' + d.id" "$H" && no "F48: $k- button ids use the card id, not the decision owner" \
      || { grep -Fq "b.id = '$k-' + (d.owner || p.id) + '-' + d.id" "$H" && ok "F48: $k- button ids carry the decision owner" || no "F48: no $k- button id found"; }
  done
fi

if on F49; then
  D="$HERE/../../references/hub.md"
  grep -Fq '<project-slug>--<decision-id>' "$D" && no "F49: references/hub.md still keys answers by the project slug" || ok "F49: no answer key by project slug"
  grep -Fq 'answers/<owner-session>--<id>.json' "$D" && grep -Fq '`<owner-session>--<decision-id>`' "$D" && ok "F49: references/hub.md documents the owner-session answer key" || no "F49: owner key not documented"
  grep -Fq "project: obj.project" "$LIB/hub.html" && grep -Fq "(d.owner || p.id) + '--' + d.id" "$LIB/hub-assets/hub-decide.js" && ok "F49: the page still writes that key" || no "F49: page key changed; update the doc"
fi

if on F50; then
  # A stranger on a probed port answers 200 to anything and logs what it gets: it must never see the token.
  cat > "$TMP/f50-listen.py" <<'PY'
import http.server, sys, json
log = open(sys.argv[1], "a")
class H(http.server.BaseHTTPRequestHandler):
    def _any(self):
        log.write(self.path + "\n" + "".join("%s: %s\n" % kv for kv in self.headers.items()) + "--\n"); log.flush()
        b = json.dumps({"proof": "0" * 64}).encode(); self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    do_GET = do_POST = _any
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H); print(s.server_address[1], flush=True); s.serve_forever()
PY
  : > "$TMP/f50.log"; python3 -I "$TMP/f50-listen.py" "$TMP/f50.log" > "$TMP/f50.port" & PIDS="$PIDS $!"
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/f50.port" ] && break; sleep 0.2; done
  FP="$(head -1 "$TMP/f50.port")"; FTOK=0123456789abcdef0123456789abcdef
  mkdir -p "$TMP/f50home/hub"; chmod 700 "$TMP/f50home/hub"; echo "$FTOK" > "$TMP/f50home/hub/token"
  r="$(OSRC_HOME="$TMP/f50home" OSRC_HUB_PORT="$FP" lib eval 'nohup() { :; }; sleep() { :; }; _osrc_mc_hub_reuse() { return 0; }; cmd_hub_mc' 2>&1)"
  grep -q "$FTOK" "$TMP/f50.log" && no "F50: mc sent the hub token to a stranger's port: $(grep -m1 "$FTOK" "$TMP/f50.log")" || ok "F50: a stranger on a probed port never receives the token"
  case "$r" in *"127.0.0.1:$FP/"*) no "F50: mc reused the stranger as Mission Control: $r" ;; *) ok "F50: the stranger is not taken for Mission Control" ;; esac
  # Our own hub (same token, recorded port) is still found and reused.
  if srv_start 'echo "{\"generated_at\":1,\"projects\":[]}"'; then
    echo "$SRV_TOK" > "$SRV_HOME/hub/token"; chmod 600 "$SRV_HOME/hub/token"
    r="$(OSRC_HOME="$SRV_HOME" OSRC_HUB_PORT="$SRV_PORT" lib eval 'nohup() { :; }; _osrc_mc_hub_reuse() { return 0; }; cmd_hub_mc' 2>&1)"
    case "$r" in *"Mission Control: http://127.0.0.1:$SRV_PORT/?t=$SRV_TOK"*) ok "F50: mc still finds and reuses its own hub" ;; *) no "F50: own hub not found: $r" ;; esac
  else no "F50: the hub did not start: $(cat "$SRV_HOME/err")"; fi
fi

if on F51; then
  # Restarting with a new key must revoke old URLs within hours, and /reopen answers browsers only.
  H51="$TMP/f51"; mkdir -p "$H51/hub"; chmod 700 "$H51/hub"
  OLD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; NEW=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  r="$(cd "$LIB" && T="$H51" python3 -I -c '
import json, os, sys, time; sys.path.insert(0, os.getcwd()); import hub_server as h
t = os.environ["T"]; h.Hub(t, "/bin/false", "hub.html", "'$OLD'"); hub = h.Hub(t, "/bin/false", "hub.html", "'$NEW'")
fresh = hub.retired_key_ok("'$OLD'")
ks = json.load(open(hub.keys_file)); [k.update(retired_at=int(time.time()) - 2 * 86400) for k in ks if not k.get("current")]
json.dump(ks, open(hub.keys_file, "w")); print(fresh, hub.retired_key_ok("'$OLD'"), hub.KEY_TTL <= 86400)
for k in ks: k.update(retired_at=int(time.time()) - 60) if not k.get("current") else None
json.dump(ks, open(hub.keys_file, "w"))' 2>&1)"
  [ "$r" = "True False True" ] && ok "F51: a key retired two days ago no longer reopens (TTL at most a day)" || no "F51: TTL: $r"
  if SRV_REUSE="$H51" SRV_TOK_SET="$NEW" srv_start 'echo "{\"generated_at\":1,\"projects\":[]}"'; then
    c1="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Hub-Old-Token: $OLD" "http://127.0.0.1:$SRV_PORT/reopen")"
    c2="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Hub-Old-Token: $OLD" -H "Origin: http://127.0.0.1:$SRV_PORT" -H "Sec-Fetch-Site: same-origin" "http://127.0.0.1:$SRV_PORT/reopen")"
    [ "$c1" = 403 ] && ok "F51: /reopen without browser same-origin headers is refused" || no "F51: headerless /reopen answered $c1"
    [ "$c2" = 200 ] && ok "F51: the page's own same-origin /reopen still works" || no "F51: same-origin /reopen answered $c2"
  else no "F51: the hub did not start: $(cat "$SRV_HOME/err")"; fi
fi

echo "RESULTS: $pass pass $fail fail"
[ "$fail" -eq 0 ]
