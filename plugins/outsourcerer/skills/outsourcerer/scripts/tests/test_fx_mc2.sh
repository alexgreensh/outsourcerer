#!/usr/bin/env bash
# sealed-run-requires: process-inspection
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_fx_mc2.sh: the 0.18.0 release-gate fixes for Mission Control, the watcher and speed (lane
# osrc-fx-mc2). One section per review finding; every check failed before its fix.
# Run: bash test_fx_mc2.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"; FX="$SCRIPT_DIR/fixtures/supervise"
command -v jq >/dev/null || { echo "FAIL: jq required"; exit 1; }
TMP="$(mktemp -d "${TMPDIR%/}/.test-fxmc2.XXXXXX")" || exit 1; PIDS=""
trap 'for p in $PIDS; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/panes" "$TMP/home"
ln -s "$SCRIPT_DIR/fake-bin/tmux-files-next" "$TMP/bin/tmux"; export FAKE_TMUX_FILES="$SCRIPT_DIR/fake-bin/tmux-files"
export HOME="$TMP/home" PATH="$TMP/bin:$PATH" FAKE_TMUX_DIR="$TMP/panes" OSRC_HEARTBEAT_DISABLED=1 OSRC_BLIND_TURN_GUARD=0 OSRC_STREAM=1
export OSRC_CLAUDE_PROJECTS_DIR="$TMP/projects" OSRC_CLAUDE_SESSIONS_DIR="$TMP/ccsessions" OSRC_MC_AUTO_OPEN=0 OSRC_WATCH_NOTIFY=0
unset TMUX TMUX_PANE CLAUDE_CODE_SESSION_ID OSRC_WATCH_DELIVER_CMD OSRC_SUPERVISE_REMIND
export OSRC_SUPERVISE_POLL=1 OSRC_SUPERVISE_CONFIRM=0 OSRC_SUPERVISE_SETTLE=0 OSRC_SUPERVISE_TICK_SECS=86400
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
fresh() { export OSRC_HOME="$TMP/h$1"; mkdir -p "$OSRC_HOME/jobs" "$OSRC_HOME/sessions" "$OSRC_HOME/lanes"; rm -f "$TMP/panes"/*.screen; }
own() { mkdir -p "$OSRC_HOME/owners/$1"; : > "$OSRC_HOME/owners/$1/$2"; }
pane() { cp "$FX/$2" "$TMP/panes/$1.screen"; }
lib() { ( set +u; OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; "$@" ); }
S() { ( set +u; export OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; eval "$1" ); }
ago() { local t; t="$(date -r $(( $(date +%s) - $2 )) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$(( $(date +%s) - $2 )) +%Y%m%d%H%M.%S)"; touch -t "$t" "$1"; }
# A standing watcher that can wake every session: a live "watcher run" process holding the lock, a
# fresh tick, and a delivery command captured at install.
fake_watcher() {
  bash -c 'sleep 120; : watcher run' & local p=$!; PIDS="$PIDS $p"; sleep 0.2
  mkdir -p "$OSRC_HOME/watchsvc/run.lock"; echo "$p" > "$OSRC_HOME/watchsvc/run.lock/pid"
  date +%s > "$OSRC_HOME/watchsvc/alive"; echo fallback > "$OSRC_HOME/watchsvc/installed"
  printf 'export OSRC_WATCH_DELIVER_CMD=true\n' > "$OSRC_HOME/watchsvc/env"
}
N0="$(date +%s)"

echo "=== pattern F2: one 'is this session watched' rule ==="
fresh 1; own S w1; pane w1 cc-working-turn.txt; ago "$OSRC_HOME/owners/S/w1" 300
g="$(lib osrc_watcher_gap S)"; [ -n "$g" ] && ok "no watcher at all: the gap shows ($g)" || no "no gap without any watcher"
fake_watcher
lib _ws_covers S && ok "the fake standing watcher covers the session (stop guard's view)" || no "fake watcher does not cover"
g="$(lib osrc_watcher_gap S)" && no "watcher covers S but the gap still says '$g'" || ok "osrc_watcher_gap honors the standing watcher"
p="$(lib osrc_mc_alerts S '{"id":"S"}')"
jq -e 'has("watcher") | not' <<<"$p" >/dev/null && ok "hub export carries no watcher field while the watcher covers" || no "export: $p"
err="$(CLAUDE_CODE_SESSION_ID=S OUTSOURCERER_TMUX=w1 perl -e 'alarm 30; exec @ARGV' "$SRC" session read 2>&1 >/dev/null)"
grep -q 'no watcher' <<<"$err" && no "per-command warning fired under a covering watcher: [$err]" || ok "per-command warning is silent under a covering watcher"
out="$(printf '{"session_id":"S"}' | OSRC_CARD_GUARD=0 "$SRC" stop-guard 2>/dev/null)"
grep -q '"decision":"block"' <<<"$out" && no "stop guard blocked under the watcher [$out]" || ok "stop guard agrees: no waiter block"

echo "=== spec F2: every track says lane, model, issue and PR ==="
fresh 2; J=20261126-010101-abcd
mkdir -p "$OSRC_HOME/jobs/$J"; echo done > "$OSRC_HOME/jobs/$J/status"; echo 0 > "$OSRC_HOME/jobs/$J/exit"
jq -cn '{provider:"devin", lane:"dv", model:"swe-test-1", verb:"run", branch:"osrc/feature-x"}' > "$OSRC_HOME/jobs/$J/meta.json"
l="$(OSRC_JOBS="$OSRC_HOME/jobs" lib _osrc_hub_lane_job "$J")"
jq -e '.lane == "Devin" and .model == "swe-test-1"' <<<"$l" >/dev/null && ok "a derived job track carries its lane and model" || no "job lane: $l"
mkdir -p "$OSRC_HOME/remote"; jq -cn '{id:"r1", branch:"cloud/r1", head:"abc", vehicle:"claude", created_ts:1}' > "$OSRC_HOME/remote/r1.json"
l="$(lib _osrc_hub_lane_remote r1)"
jq -e '.lane == "Claude cloud" and .branch == "cloud/r1"' <<<"$l" >/dev/null && ok "a derived cloud lane carries its lane" || no "remote lane: $l"
mkdir -p "$OSRC_HOME/hub/cache"
jq -cn '{fetchedAt:1, ok:true, prs:[{number:7, headRefName:"cloud/r1", closedAt:"2026-01-01T00:00:00Z"}, {number:12, headRefName:"cloud/r1"}, {number:3, headRefName:"other"}]}' > "$OSRC_HOME/hub/cache/gh-acme_app.json"
l="$(lib _osrc_hub_lanes_prs '[{"id":"r1","branch":"cloud/r1"},{"id":"r2","branch":"none"},{"id":"r3","branch":"other","prs":"#99"}]')"
jq -e '.[0].prs == "#12" and (.[1] | has("prs") | not) and .[2].prs == "#99"' <<<"$l" >/dev/null \
  && ok "a lane branch with a known PR shows it (open PR wins; a given prs is kept)" || no "prs from branch: $l"
l="$(lib _osrc_hub_apply_lane_overrides '[{"id":"a","short":"x","status":"Building"}]' '{"lanes":{"a":{"prs":"#5","status":"Done"}}}')"
jq -e '.[0].prs == "#5" and .[0].status == "Building"' <<<"$l" >/dev/null && ok "prs passes through card overrides (status still computed)" || no "override: $l"
grep -q 'headRefName' "$SCRIPT_DIR/../lib/hub-history.sh" && ok "the one existing gh pr list call also fetches the head branch (no new call)" || no "no headRefName"
lk=0; for c in dv:Devin cx:Codex cc:"Claude Code" droid:"Factory Droid"; do
  [ "$(S "_osrc_hub_lane_label ${c%%:*}; printf %s \"\$_OSRC_LL\"")" = "${c#*:}" ] || { no "label ${c%%:*}"; lk=1; }; done; [ "${lk:-0}" = 0 ] && ok "lane codes read as human lane names"
own S w2; pane w2 cc-working-turn.txt
lib _sg_card_nag S >/dev/null && no "a card-less owner was nagged before its waiter check" || ok "the early card check still skips a session with no card"
r="$(_SG_CARD_OWNED=1 lib _sg_card_nag S)" && grep -q 'last reported never' <<<"$r" && ok "a session that owns lanes and never reported is asked for its card" || no "owned, no card: [$r]"
rm -rf "$OSRC_HOME/hub/card-nag"; fake_watcher
out="$(printf '{"session_id":"S"}' | "$SRC" stop-guard 2>/dev/null)"
grep -q 'last reported never' <<<"$out" && ok "stop guard (watched, so no waiter block) asks the card-less owner for a card" || no "stop guard: [$out]"
mkdir -p "$OSRC_HOME/hub/projects"
jq -cn '{reportedAt:(now|todate), board:{tasks:[{short:"Named", model:"m", lane:"l", branch:"cloud/r1"}, {short:"Fine", model:"m", lane:"l", branch:"x"}]}}' > "$OSRC_HOME/hub/projects/S.json"
u="$(lib _sg_board_unnamed "$OSRC_HOME/hub/projects/S.json")"
[ "$u" = "Named" ] && ok "a board track whose branch has a PR but no prs counts as unnamed" || no "unnamed: [$u]"

echo "=== spec F3: a missing watcher is visible and one step away ==="
fresh 3; own S w3
o1="$(CLAUDE_CODE_SESSION_ID=S lib osrc_mc_cmd_hook run x 2>&1)"; o2="$(CLAUDE_CODE_SESSION_ID=S lib osrc_mc_cmd_hook bg x 2>&1)"
grep -q 'no standing watcher is installed.*watcher install$' <<<"$o1" && [ -z "$o2" ] && ok "a launch with no watcher says so once per session, with the install command" || no "launch hint: [$o1] then [$o2]"
fresh 3b; own S w3; pane w3 cc-working-turn.txt; ago "$OSRC_HOME/owners/S/w3" 300
mkdir -p "$OSRC_HOME/jobs/w3"; echo running > "$OSRC_HOME/jobs/w3/status"; sleep 300 & jp=$!; PIDS="$PIDS $jp"; echo "$jp" > "$OSRC_HOME/jobs/w3/pid"; echo "$jp" > "$OSRC_HOME/jobs/w3/supervisor_pid"
b1="$(printf '{"session_id":"S"}' | OSRC_CARD_GUARD=0 "$SRC" stop-guard 2>/dev/null)"; b2="$(printf '{"session_id":"S"}' | OSRC_CARD_GUARD=0 "$SRC" stop-guard 2>/dev/null)"
grep -q 'no standing watcher is installed' <<<"$b1" && grep -q '"decision":"block"' <<<"$b2" && ! grep -q 'no standing watcher' <<<"$b2" \
  && ok "the stop guard names the install command once per session" || no "stop guard hint: [$b1] / [$b2]"
fresh 3c; own S w3; mkdir -p "$OSRC_HOME/watchsvc"; echo fallback > "$OSRC_HOME/watchsvc/installed"
[ -z "$(lib osrc_watcher_hint S)" ] && ok "no hint once a watcher is installed" || no "hint with a watcher installed"
kill "$jp" 2>/dev/null

echo "=== security F2: the installed watcher runs only an installed copy ==="
fresh 4; mkdir -p "$OSRC_HOME/watchsvc" "$HOME/.claude/plugins/cache/mkt/outsourcerer/9.9.9" "$TMP/devcopy"
inst="$HOME/.claude/plugins/cache/mkt/outsourcerer/9.9.8/outsourcerer.sh"
echo fallback > "$OSRC_HOME/watchsvc/installed"; echo "$inst" > "$OSRC_HOME/watchsvc/pinned"
printf '#!/bin/bash\n# script: %s\nexec bash %s watcher run\n' "$inst" "$inst" > "$OSRC_HOME/watchsvc/launch"
# Fallback backend respawns the loop: stub it here (no real daemon in this check).
e="$(S "_ws_spawn() { :; }; SCRIPT_PATH='$TMP/devcopy/outsourcerer.sh'; _ws_refresh" 2>&1)"; e2="$(S "_ws_spawn() { :; }; SCRIPT_PATH='$TMP/devcopy/outsourcerer.sh'; _ws_refresh" 2>&1)"
grep -qxF "# script: $inst" "$OSRC_HOME/watchsvc/launch" && ok "a dev checkout does not repoint the installed watcher" || no "repointed at a dev copy: $(cat "$OSRC_HOME/watchsvc/launch")"
grep -q 'keeps running' <<<"$e" && [ -z "$e2" ] && ok "and says so once (the watcher still follows the installed copy)" || no "dev-copy note: [$e] [$e2]"
S "_ws_spawn() { :; }; SCRIPT_PATH='$HOME/.claude/plugins/cache/mkt/outsourcerer/9.9.9/.outsourcerer/worktrees/d1/outsourcerer.sh'; _ws_refresh" 2>/dev/null
grep -qxF "# script: $inst" "$OSRC_HOME/watchsvc/launch" && ok "a delegate worktree never becomes the watcher's code" || no "repointed at a worktree"
S "_ws_spawn() { :; }; SCRIPT_PATH='$HOME/.claude/plugins/cache/mkt/outsourcerer/9.9.9/outsourcerer.sh'; _ws_refresh" 2>/dev/null
grep -q '9.9.9/outsourcerer.sh' "$OSRC_HOME/watchsvc/launch" && ok "a plugin update still repoints it" || no "plugin update not followed"
st="$(S '_ws_status' 2>&1)"; grep -q 'last_tick=never' <<<"$st" && grep -q 'launcher: BROKEN' <<<"$st" && ok "status: last_tick=never, and a launcher naming a missing file is called out" || no "status: [$st]"
n1="$(OSRC_HOME="$TMP/hA" S _ws_name)"; n2="$(OSRC_HOME="$TMP/hB" S _ws_name)"
case "$n1" in com.outsourcerer.watcher.????????) [ "$n1" != "$n2" ] && ok "a sandboxed OSRC_HOME gets its own unit name ($n1), never the account's" || no "same unit name for two homes" ;; *) no "sandbox home uses the shared label: $n1" ;; esac

echo "=== concurrency F2: one ticking watcher loop after a stale-lock takeover ==="
fresh 5; mkdir -p "$OSRC_HOME/watchsvc/run.lock"; osrc_test_dead_pid > "$OSRC_HOME/watchsvc/run.lock/pid"; ago "$OSRC_HOME/watchsvc/run.lock" 600
for i in 1 2 3 4 5 6; do
  OSRC_SOURCED=1 OSRC_WATCH_INTERVAL=1 bash -c '. "$0" >/dev/null 2>&1; _ws_tick() { echo $$ >> "$OSRC_HOME/ticks"; }; while [ ! -f "$OSRC_HOME/go" ]; do sleep 0.02; done; _ws_run' "$SRC" watcher run >/dev/null 2>&1 &
  PIDS="$PIDS $!"; done
sleep 1; : > "$OSRC_HOME/go"; i=0; until [ -s "$OSRC_HOME/ticks" ] || [ "$i" -ge 75 ]; do sleep 0.2; i=$((i+1)); done; sleep 2.5   # a winner ticks every second
n="$(sort -u "$OSRC_HOME/ticks" 2>/dev/null | grep -c .)"
[ "$n" = 1 ] && ok "six starters race a dead owner's lock: exactly one loop ticks" || no "$n loops ticked"
for p in $PIDS; do kill "$p" 2>/dev/null; done
fresh 5b; mkdir -p "$OSRC_HOME/watchsvc/limits"; echo fallback > "$OSRC_HOME/watchsvc/installed"; own S K
printf '#!/bin/sh\necho "$OUTSOURCERER_TMUX $*" >> %s/sent5\n' "$TMP" > "$TMP/bin/fake-osrc"; chmod +x "$TMP/bin/fake-osrc"
S "_sv_state_read K; SVS_LK='limit:1'; _sv_state_write K"; echo $(( $(date +%s) - 5 )) > "$OSRC_HOME/watchsvc/limits/K"
echo 1 > "$OSRC_HOME/watchsvc/limits/K.sending"   # another loop is sending this continue right now
S "SCRIPT_PATH='$TMP/bin/fake-osrc'; _ws_limits"
[ ! -s "$TMP/sent5" ] && ok "a continue another loop has claimed is never sent twice" || no "double continue: $(cat "$TMP/sent5")"
rm -f "$OSRC_HOME/watchsvc/limits/K.sending"; S "SCRIPT_PATH='$TMP/bin/fake-osrc'; _ws_limits"; S "SCRIPT_PATH='$TMP/bin/fake-osrc'; _ws_limits"
[ "$(grep -c . "$TMP/sent5" 2>/dev/null)" = 1 ] && [ ! -e "$OSRC_HOME/watchsvc/limits/K.sending" ] && ok "unclaimed: exactly one continue, and the claim is released" || no "sends: $(cat "$TMP/sent5" 2>/dev/null)"

echo "=== pattern F4 / architecture F7 / live F14: one hub-liveness rule ==="
fresh 6; mkdir -p "$OSRC_HOME/hub"; printf '0123456789abcdef0123456789abcdef\n' > "$OSRC_HOME/hub/token"
printf '#!/bin/sh\necho "$1" >> "$OSRC_HOME/opened.log"\n' > "$TMP/bin/open-rec"; chmod +x "$TMP/bin/open-rec"
desk() { OSRC_MC_AUTO_OPEN=1 OSRC_HUB_NO_OPEN=0 OSRC_MC_OPEN_CMD="$TMP/bin/open-rec" OSRC_MC_ASSUME_DESKTOP=1 "$@"; }
sleep 300 & rp=$!; PIDS="$PIDS $rp"   # a recycled pid: alive, but not a hub
printf '{"pid":%s,"port":8771}\n' "$rp" > "$OSRC_HOME/hub/serve.json"
! lib _osrc_mc_hub_live && ! lib _osrc_mc_url_live "http://127.0.0.1:8771/?t=x" && ok "a recycled pid in serve.json is no live hub (every opener)" || no "recycled pid counted as the hub"
: > "$OSRC_HOME/hub/autostart"   # the detached start is not under test here
desk lib osrc_mc_auto_open 2>/dev/null; [ ! -s "$OSRC_HOME/opened.log" ] && ok "auto-open never opens a recycled pid's port" || no "opened: $(cat "$OSRC_HOME/opened.log")"
bash -c "sleep 300; : hub_server.py --osrc-home $OSRC_HOME --engine $TMP/gone/outsourcerer.sh" & op=$!; PIDS="$PIDS $op"; sleep 0.2
printf '{"pid":%s,"port":8772,"ver":"0.0.1"}\n' "$op" > "$OSRC_HOME/hub/serve.json"
lib _osrc_mc_hub_live >/dev/null && ok "our own hub process is live" || no "fake hub not recognised"
e="$(desk lib osrc_mc_auto_open 2>&1)"; sleep 0.3
! grep -q 8772 "$OSRC_HOME/opened.log" 2>/dev/null && ! kill -0 "$op" 2>/dev/null && grep -q 'older code' <<<"$e" \
  && ok "auto-open replaces a hub running older code instead of opening it (as mc does)" || no "auto-open opened old code: [$e] opened=$(cat "$OSRC_HOME/opened.log" 2>/dev/null)"
bash -c "sleep 300; : hub_server.py --osrc-home $OSRC_HOME" & wp=$!; PIDS="$PIDS $wp"; sleep 0.2; kill -STOP "$wp"
printf '{"pid":%s,"port":8773}\n' "$wp" > "$OSRC_HOME/hub/serve.json"
e="$(lib _osrc_mc_hub_reuse "" 2>&1)"; rc=$?; sleep 0.3
[ "$rc" = 1 ] && ! kill -0 "$wp" 2>/dev/null && [ ! -f "$OSRC_HOME/hub/serve.json" ] && grep -q 'did not answer' <<<"$e" \
  && ok "mc stops its own wedged hub (SIGSTOP) before starting a new one, and says why" || no "wedged hub: rc=$rc alive=$(kill -0 "$wp" 2>/dev/null && echo y) [$e]"
bash -c "sleep 300; : hub_server.py --osrc-home $TMP/other" & xp=$!; PIDS="$PIDS $xp"; sleep 0.2
printf '{"pid":%s,"port":8774}\n' "$xp" > "$OSRC_HOME/hub/serve.json"
lib _osrc_mc_hub_reuse "" 2>/dev/null; kill -0 "$xp" && ok "another home's hub is never stopped" || no "killed a foreign hub"
kill "$xp" "$rp" 2>/dev/null

echo "=== concurrency F3: a killed screen refresh never freezes a lane on Mission Control ==="
fresh 7; d="$OSRC_HOME/hub/cache/scr"; mkdir -p "$d/L7.lock"; ago "$d/L7.lock" 600
printf '5 0 %s\nworking\n' $(( $(date +%s) - 900 )) > "$d/L7"; printf 'L7 6\n' > "$d/.wanted.99"
STUB='_osrc_hub_tmux_row() { echo "L7 6"; }; _osrc_hub_raw_sv_target_screen() { echo idle; }; _osrc_hub_scr_dep_epoch() { echo 0; };'
OSRC_HUB_FAST=1 S "$STUB _osrc_hub_scr_get L7" >/dev/null && no "a 15-min-old cached screen was still served" || ok "past its hard maximum age a cached screen is not served (the caller reads it)"
( set +u; export OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; eval "$STUB"; mv "$d/.wanted.99" "$d/.wanted.$$"; _osrc_hub_scr_flush_wanted; wait ) 2>/dev/null
i=0; until [ ! -d "$d/L7.lock" ] && grep -qx idle "$d/L7" 2>/dev/null || [ "$i" -ge 30 ]; do sleep 0.2; i=$((i+1)); done
grep -qx idle "$d/L7" && [ ! -d "$d/L7.lock" ] && ok "a lock left by a killed worker is broken and the screen refreshed" || no "stale lock kept the old screen: $(cat "$d/L7")"

echo "=== performance F1: the lane registry is read once per process ==="
fresh 9
r="$(S 'lane_descriptor_cx() { echo called >> "$OSRC_HOME/desc.calls"; }; lane_descriptor_dv() { echo called >> "$OSRC_HOME/desc.calls"; }
  a="$(_lane_field cx disp)"; b="$(_lane_by_provider gemini)"; c="$(_lane_by_token cc)"; d="$(_catalog_path dv)"; printf "%s|%s|%s|%s" "$a" "$b" "$c" "${d##*/}"')"
[ ! -e "$OSRC_HOME/desc.calls" ] && [ "$r" = "cxnative|gm|cc|dv.json" ] && ok "lookups after load never re-run a descriptor (table hit): $r" || no "descriptor re-read: calls=$(grep -c . "$OSRC_HOME/desc.calls" 2>/dev/null) r=$r"
r="$(S 'OSRC_LANE_REGISTRY="cx"; _lane_by_provider gemini; echo "|$(_lane_field cx disp)|$(_lane_field dv disp)"')"
[ "$r" = "|cxnative|" ] && ok "a changed registry rebuilds the table (no stale lane)" || no "registry change: $r"

echo "=== performance F4 + live finding: the remote-lane pass ==="
fresh 8; mkdir -p "$OSRC_HOME/remote" "$TMP/jqlog"; RJQ="$(command -v jq)"
printf '#!/bin/sh\necho x >> "%s/jqlog/n"\nexec "%s" "$@"\n' "$TMP" "$RJQ" > "$TMP/jqlog/jq"; chmod +x "$TMP/jqlog/jq"
lane() { jq -cn --arg id "$1" --argjson now "$N0" --arg ref "${2:-}" '{id:$id, branch:("cloud/" + $id), transport:"git", url:"/nonexistent", created_ts:($now - 3600),
  last_poll_ts:$now, err_count:0, err_kind:"", seen_branch:false, branch_deleted:false, head:"", head_ready:false, last_push_ts:($now - 3600), check:null, session_ref:$ref}' > "$OSRC_HOME/remote/$1.json"; }
cnt() { rm -f "$TMP/jqlog/n"; ( export PATH="$TMP/jqlog:$PATH" OSRC_NOW="$N0"; S 'osrc_remote_events >/dev/null 2>&1' ); grep -c . "$TMP/jqlog/n" 2>/dev/null || echo 0; }
lane r1 "url:https://example.invalid/session_a"; S 'osrc_remote_events' >/dev/null 2>&1   # first pass logs its one event
c1="$(cnt)"; for i in r2 r3 r4 r5; do lane $i "url:https://example.invalid/session_$i"; done; S 'osrc_remote_events' >/dev/null 2>&1; c5="$(cnt)"
per=$(( (c5 - c1) / 4 ))
[ "$per" -le 1 ] && ok "a throttled pass reads each lane file with one jq ($per per lane; $c5 for 5 lanes)" || no "throttled pass: $per jq per lane ($c1 for 1, $c5 for 5)"
fresh 8b; mkdir -p "$OSRC_HOME/remote"; lane s1 "url:https://claude.ai/code/session_x1"; lane s2 ""
ev="$(OSRC_NOW="$N0" S 'osrc_remote_events' 2>/dev/null)"
grep -q '^EVENT stalled s1 .*no push yet after 60m (session https://claude.ai/code/session_x1 is live' <<<"$ev" && ! grep -q 'EVENT failed s1' <<<"$ev" \
  && ok "a lane whose vehicle reported a live session is quiet (stalled), not 'failed: never started'" || no "live-session lane: $ev"
grep -q '^EVENT failed s2 .*never started' <<<"$ev" && ok "a launch with no session URL still reports never started" || no "no-session lane: $ev"
[ "$(S 'osrc_remote_state s1')" = live ] && ok "osrc_remote_state still answers from the one-jq record" || no "state: $(S 'osrc_remote_state s1')"

echo "=== performance F6: the Stop hook ==="
fresh 10; HOOKS="$SCRIPT_DIR/../../../../hooks/hooks.json"; hook="$(jq -r '.hooks.Stop[0].hooks[0].command' "$HOOKS")"
printf '#!/bin/sh\necho x >> "%s/jqlog/n"\nexec "%s" "$@"\n' "$TMP" "$RJQ" > "$TMP/jqlog/jq"; chmod +x "$TMP/jqlog/jq"
mkdir -p "$TMP/eng"; printf '#!/bin/sh\necho engine >> "%s/eng/ran"\ncat > "%s/eng/in"\n' "$TMP" "$TMP" > "$TMP/eng/outsourcerer.sh"; chmod +x "$TMP/eng/outsourcerer.sh"
mkdir -p "$TMP/eng/lib"; cp "$SCRIPT_DIR/../lib/stopguard_pre.sh" "$TMP/eng/lib/"
run_hook() { printf '%s' "$1" | CLAUDE_PLUGIN_ROOT="$TMP/plug" sh -c "$hook"; }
mkdir -p "$TMP/plug/skills/outsourcerer"; ln -sfn "$TMP/eng" "$TMP/plug/skills/outsourcerer/scripts"
run_hook '{"session_id":"quiet-1"}'
[ ! -e "$TMP/eng/ran" ] && ok "a session that owns nothing and has no card: the hook allows without loading the engine" || no "engine loaded for a quiet session"
own quiet-1 L1; run_hook '{"session_id": "quiet-1", "cwd":"/x"}'
grep -q engine "$TMP/eng/ran" 2>/dev/null && grep -qF '"session_id": "quiet-1"' "$TMP/eng/in" && ok "a session that owns a lane gets the full guard, its input unchanged" || no "owned session skipped or input lost: $(cat "$TMP/eng/in" 2>/dev/null)"
rm -f "$TMP/eng/ran"; run_hook '{"session_id":"we/ird"}'; [ -e "$TMP/eng/ran" ] && ok "an unusual session id is never short-circuited" || no "odd id short-circuited"
mkdir -p "$OSRC_HOME/hub/projects"
jq -cn '{name:"P", reportedAt:"2020-01-01T00:00:00Z", board:{tasks:[{short:"T", model:"m", lane:"l"}], decisions:[{id:"D1", q:"old?", askedAt:"2020-01-01T00:00:00Z"}]}}' > "$OSRC_HOME/hub/projects/quiet-1.json"
rm -f "$TMP/jqlog/n"; r="$(PATH="$TMP/jqlog:$PATH" S '_sg_card_nag quiet-1')"
[ "$(grep -c . "$TMP/jqlog/n")" -le 1 ] && grep -q 'D1 (old?)' <<<"$r" && grep -q 'for "P" was last reported' <<<"$r" \
  && ok "the card check reads the card with one jq ($(grep -c . "$TMP/jqlog/n")), same verdict" || no "card check: $(grep -c . "$TMP/jqlog/n") jq; [$r]"

echo "=== performance F5: hub export execs ==="
fresh 11; for i in $(seq 1 40); do own S "gone-$i"; done; ago "$OSRC_HOME/owners/S/gone-1" 600
printf '#!/bin/sh\necho x >> "%s/jqlog/stat"\nexec "%s" "$@"\n' "$TMP" "$(command -v stat)" > "$TMP/jqlog/stat"; chmod +x "$TMP/jqlog/stat"
rm -f "$TMP/jqlog/stat.n"; sed -i "s|jqlog/stat\"|jqlog/stat.n\"|" "$TMP/jqlog/stat"
( export PATH="$TMP/jqlog:$PATH"; S 'osrc_watcher_gap S >/dev/null' )
[ "$(grep -c . "$TMP/jqlog/stat.n" 2>/dev/null || echo 0)" -le 1 ] && ok "the watcher gap reads 40 owner markers with one stat" || no "watcher gap: $(grep -c . "$TMP/jqlog/stat.n") stat calls for 40 markers"
mkdir -p "$OSRC_HOME/supervise/S"
r="$(S 'cmd_hub_export() { printf "%s\n" "${OSRC_HUB_FAST:-0}" > "$OSRC_HOME/fast.seen"; echo "{\"projects\":[],\"limits\":[]}"; }; _sv_card_event() { :; }; _sv_tick "$OSRC_HOME/supervise/S" "$(date +%s)"; echo rc=$?')"
[ "$(cat "$OSRC_HOME/fast.seen" 2>/dev/null)" = 1 ] && ok "supervise's 10-min export uses the page's cached path (no inline plan probes)" || no "supervise export not cached: $(cat "$OSRC_HOME/fast.seen" 2>/dev/null) [$r]"

echo "=== live F1/F2: Mission Control never rounds a failed, unverified or paused lane up to Done ==="
fresh 12; mkdir -p "$OSRC_HOME/autodetach"; echo 1 > "$OSRC_HOME/autodetach/ad1.rc"
l="$(S '_owned_live_state() { echo done; }; osrc_done_state() { echo done; }; _osrc_hub_lane_fallback ad1')"
jq -e '.status == "Failed" and (has("pct") | not)' <<<"$l" >/dev/null && ok "an auto-detached run that exited 1 is Failed, never Done 100%" || no "autodetach rc 1: $l"
J=20261126-020202-beef; mkdir -p "$OSRC_HOME/jobs/$J"; echo done > "$OSRC_HOME/jobs/$J/status"; echo 0 > "$OSRC_HOME/jobs/$J/exit"
echo exited-0-without-OSRC-DONE > "$OSRC_HOME/jobs/$J/reason"; echo '{"provider":"devin","verb":"run"}' > "$OSRC_HOME/jobs/$J/meta.json"
l="$(OSRC_JOBS="$OSRC_HOME/jobs" S "_reconcile_status() { cat \"\$OSRC_JOBS/\$1/status\"; }; _osrc_hub_lane_job $J")"
jq -e '.status == "Unverified" and (has("pct") | not)' <<<"$l" >/dev/null && ok "exit 0 without a DONE marker is Unverified, not Done 100%" || no "exited-0: $l"
r="$(S '_osrc_hub_lane_status "done?" "" x')"; [ "${r%%|*}" = Unverified ] && [ "$(printf '%s' "$r" | cut -d'|' -f2)" = "" ] && ok "'done?' maps to Unverified with no percent" || no "done? -> $r"
l="$(S '_owned_live_state() { echo live; }; _osrc_disk_target_paused() { [ "$1" = ad2 ]; }; _osrc_hub_lane_fallback ad2')"
jq -e '.status == "Paused"' <<<"$l" >/dev/null && ok "a disk-paused lane renders as Paused" || no "paused: $l"
grep -q 's-unverified' "$SCRIPT_DIR/../lib/hub.html" && grep -q "failed: 'octagon-x'" "$SCRIPT_DIR/../lib/hub.html" && ok "the page styles Failed, Unverified and Paused chips" || no "hub.html chips"

echo "=== live F4: run flags after the verb never leak into the delegate's prompt ==="
lk=0; for fl in --wait --foreground "--no-advise --wait" "--tier budget --wait" "--provider=devin"; do
  r="$(S "parse_model $fl -m swe-test-1 'say hi'; printf '%s|' \"\${REST[@]}\"; printf '%s' \"\${OSRC_NO_AUTODETACH:-0}\"")"
  case "$r" in "say hi|"*) ;; *) no "parse_model $fl left REST=[$r]"; lk=1 ;; esac
done; [ "$lk" = 0 ] && ok "--wait, --foreground, --no-advise, --tier and --provider= after the verb are flags, not task text" || no "a run flag leaked into the prompt"
r="$(S "parse_model --wait 'x'; printf '%s' \"\${OSRC_NO_AUTODETACH:-0}\"")"; [ "$r" = 1 ] && ok "--wait after the verb still forces the foreground" || no "--wait not honored: $r"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
