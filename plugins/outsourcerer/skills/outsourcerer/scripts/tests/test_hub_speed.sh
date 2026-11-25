#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_hub_speed.sh -- `hub export` stays fast without changing what the page says.
#   same     every lane state from an export (memo, cached readings, deferred probes) equals what the
#            uncached readers say for the same fixture: tmux panes, cloud lanes, jobs;
#   probe    a cloud lane's check: probe (a clone in real life, a sleep here) never sits on the export,
#            even though bash hands a saved copy of a redirected pipe to everything forked under it;
#   screen   a pane reading is reused while the pane text and its inputs are unchanged, never after;
#   stat     _osrc_hub_mt reads a path list in one stat and keeps the old answers;
#   prof     the profiler clock is a number when `date +%s%N` prints a literal N (macOS);
#   board    a board without task percents keeps the reported percent; .state is .status;
#   verify   `lane rm` and `cleanup --apply` remove unused verify clones and nothing else.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
command -v jq >/dev/null || { echo "SKIP: jq required"; exit 0; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-hub-speed.XXXXXX")" || { echo "FAIL: no scratch dir" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
FIX="$HERE/fixtures/supervise"
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc"
export OSRC_JOBS="$OSRC_HOME/jobs" OSRC_CLAUDE_SESSIONS_DIR="$HOME/.claude/sessions" OSRC_CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
export OSRC_HEARTBEAT_DISABLED=1 OSRC_HUB_NO_OPEN=1 OSRC_CATALOG_VALIDATE=0 GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects" "$OSRC_HOME/hub/projects" "$OSRC_JOBS" "$OSRC_HOME/remote" "$OSRC_HOME/done" "$OSRC_HOME/cloud" "$TMP/bin" "$TMP/panes"

# A fake tmux: a session is $TMP/panes/<name>.screen (its mtime is the window activity).
cat > "$TMP/bin/tmux" <<'EOF'
#!/bin/bash
D="${FAKE_PANES:?}"; cmd="$1"; shift; t=""
while [ "$#" -gt 0 ]; do case "$1" in -t) t="$2"; shift 2 ;; *) shift ;; esac; done
t="${t#=}"; t="${t%%:*}"
mt() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
case "$cmd" in
  list-sessions) for f in "$D"/*.screen; do [ -f "$f" ] && { n="${f##*/}"; echo "${n%.screen} 1000 $(mt "$f")"; }; done ;;
  has-session) [ -f "$D/$t.screen" ] ;;
  capture-pane) [ -f "$D/$t.screen" ] && cat "$D/$t.screen" ;;
  display-message|display) [ -f "$D/$t.screen" ] && echo "1000 $(mt "$D/$t.screen")" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/tmux"; export FAKE_PANES="$TMP/panes" PATH="$TMP/bin:$PATH"

lib() { ( unset CLAUDE_CODE_SESSION_ID OUTSOURCERER_DEPTH; OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
  _reconcile_status() { cat "$OSRC_JOBS/$1/status" 2>/dev/null; }
  "$@" ); }
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }
NOW="$(date +%s)"

# ---- fixture: one orchestrator, two panes, four cloud lanes, two jobs ----
own() { mkdir -p "$OSRC_HOME/owners/s-main"; : > "$OSRC_HOME/owners/s-main/$1"; }
printf '{"name":"Garden app","status":"building","pct":40,"reportedAt":"%s"}\n' "$(iso "$NOW")" > "$OSRC_HOME/hub/projects/s-main.json"
cp "$FIX/cc-idle-after-work.txt" "$TMP/panes/t-idle.screen"; own t-idle
cp "$FIX/cc-question-live.txt" "$TMP/panes/t-ask.screen"; own t-ask
cp "$FIX/cc-working-turn.txt" "$TMP/panes/t-busy.screen"; own t-busy
# Cloud lanes: two carry a check: contract whose probe takes 20 s (the clone); one has a cached
# verdict of done, one has none yet. The probe leaves a mark so the test sees it ran later.
for i in 1 2 3 4; do
  own "c-$i"
  printf '{"id":"c-%s","branch":"b%s","repo":"example/garden","url":"https://example.invalid/g.git","head":"abc%s","head_msg":"wip\\tstep","head_ready":%s,"created_ts":%s,"check":null}\n' \
    "$i" "$i" "$i" "$([ "$i" -le 2 ] && echo true || echo false)" "$NOW" > "$OSRC_HOME/remote/c-$i.json"
done
for i in 1 3; do
  printf '#!/bin/sh\n: > "%s/probe-ran.c-%s"; sleep 20; exit 1\n' "$TMP" "$i" > "$OSRC_HOME/cloud/c-$i.done.sh"; chmod 700 "$OSRC_HOME/cloud/c-$i.done.sh"
  printf '{"spec":"check:sh %s","cwd":"%s"}\n' "$OSRC_HOME/cloud/c-$i.done.sh" "$TMP" > "$OSRC_HOME/done/c-$i.json"
done
printf '%s done\n' "$((NOW - 3600))" > "$OSRC_HOME/done/c-1.checkcache"   # old verdict: done
for j in j-run:running j-ok:done; do
  id="${j%%:*}"; own "$id"; mkdir -p "$OSRC_JOBS/$id"; printf '%s\n' "${j#*:}" > "$OSRC_JOBS/$id/status"
  printf '{"provider":"codex","lane":"codex","verb":"run"}\n' > "$OSRC_JOBS/$id/meta.json"; echo "task $id" > "$OSRC_JOBS/$id/task_ref"
done

echo "=== same: export lane states equal the uncached readers ==="
slow() { ( unset CLAUDE_CODE_SESSION_ID OUTSOURCERER_DEPTH; OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
  _reconcile_status() { cat "$OSRC_JOBS/$1/status" 2>/dev/null; }
  for t in "$OSRC_HOME/owners/s-main"/*; do
    l="$(_osrc_hub_lane_for "${t##*/}" '{}')" && [ -n "$l" ] && _osrc_hub_lane_live_fields "$l" && echo
  done ) | jq -sc 'map({id, status, state}) | sort_by(.id)'; }
fast() { jq -c '[.projects[] | select(.id == "s-main") | .lanes[] | {id, status, state}] | sort_by(.id)' <<<"$1"; }
want="$(slow)"
t0="$(date +%s)"; e1="$(lib cmd_hub_export 2>/dev/null)"; dt=$(( $(date +%s) - t0 ))
got1="$(fast "$e1")"; e2="$(lib cmd_hub_export 2>/dev/null)"; got2="$(fast "$e2")"
[ "$(jq length <<<"$want")" = 9 ] && [ "$got1" = "$want" ] && [ "$got2" = "$want" ] \
  && ok "9 lanes: first and repeat export match the uncached readers" || no "lane states differ: slow=$want first=$got1 repeat=$got2"
jq -e 'map(select(.id == "c-1"))[0].state == "done" and map(select(.id == "c-3"))[0].state == "working"' >/dev/null <<<"$got1" \
  && ok "a check: lane answers from its last verdict (done stays done, none is not done)" || no "verdicts: $got1"
jq -e 'map(select(.id == "t-ask"))[0].state == "question" and map(select(.id == "t-busy"))[0].state == "working"' >/dev/null <<<"$got2" \
  && ok "pane states survive the reuse (question, working)" || no "pane states: $got2"

echo "=== probe: a 20 s clone check never holds the export ==="
[ "$dt" -lt 15 ] && ok "export with two 20 s probes took ${dt}s" || no "export waited on the probe: ${dt}s"
n=0; while [ ! -e "$TMP/probe-ran.c-3" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
[ -e "$TMP/probe-ran.c-3" ] && ok "the probe still runs, detached, after the export" || no "the deferred probe never ran"
# The probe's own shell must not hold the caller's pipe either: a capture of the whole engine returns.
t0="$(date +%s)"; rm -f "$OSRC_HOME"/done/*.checkcache "$OSRC_HOME"/done/*.checklock 2>/dev/null; rm -rf "$OSRC_HOME"/done/*.checklock*
out="$(bash "$SRC" hub export 2>/dev/null)"; dt=$(( $(date +%s) - t0 ))
[ "$dt" -lt 15 ] && jq -e '.projects | length > 0' >/dev/null <<<"$out" && ok "\$(outsourcerer hub export) returns in ${dt}s while probes run" || no "captured export took ${dt}s"
pkill -f "probe-ran" 2>/dev/null; pkill -f "$OSRC_HOME/cloud/c-" 2>/dev/null

echo "=== screen: a reading is reused only while pane and inputs are unchanged ==="
scr_case() {
  _osrc_hub_raw_sv_target_screen() { echo raw >> "$OSRC_HOME/raw.calls"; printf 'idle\nseen %s\n' "$(wc -l < "$OSRC_HOME/raw.calls" | tr -d ' ')"; }
  _osrc_screen_capture() { cat "$FAKE_PANES/t-idle.screen"; }
  mkdir -p "$OSRC_HOME/hub/cache/scr"; rm -f "$OSRC_HOME/raw.calls" "$OSRC_HOME/hub/cache/scr/t-idle.ck"
  local a b c d e
  a="$(_osrc_hub_scr_read t-idle)"; b="$(_osrc_hub_scr_read t-idle)"
  echo "more text" >> "$FAKE_PANES/t-idle.screen"; c="$(_osrc_hub_scr_read t-idle)"
  sleep 1; mkdir -p "$OSRC_HOME/lanes/state"; : > "$OSRC_HOME/lanes/state/t-idle"; d="$(_osrc_hub_scr_read t-idle)"
  rm -f "$OSRC_HOME/lanes/state/t-idle"; e="$(_osrc_hub_scr_read t-idle)"
  printf '%s|%s|%s|%s|%s\n' "${a#*seen }" "${b#*seen }" "${c#*seen }" "${d#*seen }" "${e#*seen }"
}
r="$(lib scr_case 2>/dev/null)"
[ "$r" = "1|1|2|3|4" ] && ok "same pane: reused; new pane text, a new or a deleted input: read again" || no "screen reuse: $r"

echo "=== stat: one stat per list, same answers ==="
mkdir -p "$TMP/mt"; : > "$TMP/mt/a"; : > "$TMP/mt/b"; touch -t 202001020304 "$TMP/mt/a"; touch -t 202101020304 "$TMP/mt/b"
want="$(cd "$TMP/mt" && { stat -c %Y b 2>/dev/null || stat -f %m b; })"
[ "$(lib _osrc_hub_mt "$TMP/mt/a" "$TMP/mt/missing" "$TMP/mt/b")" = "$want" ] && [ "$(lib _osrc_hub_mt "$TMP/mt/missing")" = 0 ] && [ "$(lib _osrc_hub_mt)" = 0 ] \
  && ok "_osrc_hub_mt: newest of the existing paths, 0 for none" || no "_osrc_hub_mt: $(lib _osrc_hub_mt "$TMP/mt/a" "$TMP/mt/b") want $want"

echo "=== prof: portable clock ==="
mkdir -p "$TMP/macbin"; real_date="$(command -v date)"
printf '#!/bin/sh\ncase "$1" in +%%s%%N) echo "$(%s +%%s)N" ;; *) exec %s "$@" ;; esac\n' "$real_date" "$real_date" > "$TMP/macbin/date"; chmod +x "$TMP/macbin/date"
line="$(PATH="$TMP/macbin:$PATH" OSRC_HUB_PROF=/dev/stdout bash -c 'unset EPOCHREALTIME; . "$1/../lib/hub-fast.sh"; _osrc_hub_prof x' _ "$HERE")"
line2="$(OSRC_HUB_PROF=/dev/stdout bash -c '. "$1/../lib/hub-fast.sh"; _osrc_hub_prof y' _ "$HERE")"
case "$line:$line2" in [0-9]*' x:'[0-9]*' y') case "${line%% *}${line2%% *}" in *[!0-9]*) no "prof clock: $line / $line2" ;; *) ok "profiler stamps are numbers with and without GNU date" ;; esac ;; *) no "prof clock: $line / $line2" ;; esac

echo "=== board: no task percent keeps the reported one; .state is .status ==="
b="$(lib _osrc_hub_apply_board '{"pct":80,"lanes":[]}' '{"board":{"tasks":[{"short":"Fix the login","state":"reviewing"},{"short":"Write the docs"}]}}')"
jq -e '.pct == 80 and .pctSource == "report" and .lanes[0].status == "reviewing" and (.lanes | all(has("pct") | not))' >/dev/null <<<"$b" \
  && ok "board without task percents: page keeps 80%, task .state read" || no "board pct: $(jq -c '{pct,pctSource,lanes}' <<<"$b")"
b="$(lib _osrc_hub_apply_board '{"pct":80,"lanes":[]}' '{"board":{"tasks":[{"short":"Fix the login","pct":"60%"},{"short":"Write the docs"},{"short":"Tidy the menu","pct":20}]}}')"
jq -e '.pct == 40 and .pctSource == "board"' >/dev/null <<<"$b" && ok "board percent averages only the tasks that have one (60, 20 -> 40)" || no "board avg: $(jq -c '{pct,pctSource}' <<<"$b")"
t="$(lib _osrc_hub_truth '{"liveLanes":1,"boardTracks":2,"pctSource":"report","pct":80,"reportedAt":"2020-01-01T00:00:00Z","reported":{"pct":80},"derived":{"n":1,"working":1,"blocked":0,"idle":0,"ready":0,"done":0,"merged":0,"failed":0,"canceled":0,"pick":{"blocked":[],"ready":[],"done":[],"failed":[]},"finished":[],"evidenceAt":0}}' "$NOW")"
jq -e 'has("pct") | not' >/dev/null <<<"$t" && ok "a reported percent behind a board ages out like any report" || no "truth kept stale report pct: $t"
printf '{"tasks":[{"short":"Fix the login","state":"building"}]}\n' > "$TMP/board.json"
said="$(cd "$TMP" && CLAUDE_CODE_SESSION_ID=s-board bash "$SRC" hub report --board "$TMP/board.json" --pct 80 2>&1)"
case "$said" in *"page shows 80%: your reported --pct"*) ok "hub report --board says the page shows the reported 80%" ;; *) no "report said: $said" ;; esac
c="$(lib cmd_hub_export --project s-board 2>/dev/null | jq -c '.projects[0] | {pct, status: .lanes[0].status}')"
[ "$c" = '{"pct":80,"status":"building"}' ] && ok "exported card shows 80% and the task's state" || no "exported board card: $c"

echo "=== verify: unused verify clones go, nothing else ==="
for id in c-1 c-2 gone-1; do mkdir -p "$OSRC_HOME/cloud/$id.verify.git/objects"; head -c 1000 /dev/zero > "$OSRC_HOME/cloud/$id.verify.git/objects/pack"; done
mkdir -p "$OSRC_HOME/cloud/notes.git"; : > "$OSRC_HOME/cloud/gone-1.done.sh"; : > "$OSRC_HOME/cloud/gone-1.launch.log"
lib cmd_lane rm c-2 >/dev/null 2>&1
[ ! -e "$OSRC_HOME/cloud/c-2.verify.git" ] && [ -d "$OSRC_HOME/cloud/c-1.verify.git" ] && ok "lane rm deletes its own verify clone only" || no "lane rm verify clone: $(ls "$OSRC_HOME/cloud")"
dry="$(lib cmd_cleanup 2>&1)"
case "$dry" in *"gone-1"*) ok "cleanup dry run lists the orphan clone" ;; *) no "dry run: $dry" ;; esac
[ -d "$OSRC_HOME/cloud/gone-1.verify.git" ] || no "dry run deleted something"
lib cmd_cleanup --apply >/dev/null 2>&1
[ ! -e "$OSRC_HOME/cloud/gone-1.verify.git" ] && [ -d "$OSRC_HOME/cloud/c-1.verify.git" ] && [ -d "$OSRC_HOME/cloud/notes.git" ] \
  && [ -f "$OSRC_HOME/cloud/gone-1.done.sh" ] && [ -f "$OSRC_HOME/cloud/gone-1.launch.log" ] \
  && ok "cleanup --apply removes the untracked lane's clone, keeps tracked clones and other files" || no "cleanup sweep: $(ls "$OSRC_HOME/cloud")"

echo "test_hub_speed: $pass passed, $fail failed"
[ "$fail" = 0 ]
