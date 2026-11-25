#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_release_0175.sh -- regression checks for the 0.17.5 release:
#   1-5: card_fresh.sh GNU stat order, unwritable marker fail-open, no owners/ leak into adopt,
#        user-shipped override & closed-decisions-only exemption, jq safety on odd decision JSON & board decisions
#   6:   hub_board.sh odd inputs (string pct, string flow, object decisions, missing p.decisions,
#        non-string releaseNote, missing IDs, no hardcoded project themes, Idle excluded from sessionsNow)
#   7-8: hub.html theme k="" safe fallback, board3 CSS class (not inline gridTemplateColumns), <= 998 lines
#   9:   board preserves proofStops for hub-proof.js + _osrc_hub_visible keeps liveLanes > 0 visible
#   10:  spend.sh agy oauth token -> subscription even with GEMINI_API_KEY in ~/.env; limits.sh agy auth
#   11:  hub report --board "" rejected; valid --board persists
#   12:  mc restarts a running hub whose engine path or code version differs (old install), and
#       never kills a pid that is not this OSRC_HOME's hub server
#   13:  supervise reads an agy quota/backoff pane as EVENT limit (reset epoch + model detail +
#       move-to-another-lane NEXT), never 'stalled: screen unrecognised'
#   14:  devin '▲ Approval required' modal parses Exec(kind)+command; safe policy approves
#       VAR=... prefixes, &&/; chains of read-only parts, echo and nice -n N wrappers, still
#       holds rm -rf/redirects-out/unknown binaries/multi-line, and never approves Bypass mode
#   15:  session start slow-boot grace + agy composer mode-hint placeholder
#   16:  stale Mission Control content: stale card hides Next + shows 'Last update from its session',
#        stale open decision shows 'Not re-confirmed for X h, may be out of date' & sorts below fresh
#        (never auto-closed), quiet projects fold into collapsed 'Quiet', no lane counts on Home tiles,
#        prompt-text project titles fall back to folder name in sentence case
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/.."
SRC="$S/outsourcerer.sh"
LIB="$S/lib"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

T="$(mktemp -d "${TMPDIR%/}/.rel0175.XXXXXX")" || { echo "FAIL: no scratch dir"; exit 1; }
PIDS=""
cleanup() { local p; for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
# Hard ~2 min per section: a hung section (e.g. `hub serve` scanning ports a real Mission
# Control owns) dies loudly instead of stalling the lane. Each `=== ` header re-arms the
# switch; a stale watchdog sees the generation moved on and never fires.
trap 'exit 124' TERM
SEC_LIMIT="${OSRC_TEST_SEC_LIMIT:-120}"
_SEC_GEN=0
_sec_arm() {
  _SEC_GEN=$(( _SEC_GEN + 1 ))
  [ -d "$T" ] || bad "scratch dir $T vanished mid-suite (section bound disarmed, fixture writes would be meaningless)"
  printf '%s' "$_SEC_GEN" > "$T/.secgen" 2>/dev/null
  ( sleep "$SEC_LIMIT"
    [ "$(cat "$T/.secgen" 2>/dev/null)" = "$_SEC_GEN" ] || exit 0
    for _c in $(pgrep -P "$$" 2>/dev/null); do [ "$_c" != "$BASHPID" ] && kill -TERM "$_c" 2>/dev/null; done
    sleep 1
    kill -TERM "$$" 2>/dev/null
    sleep 2
    kill -KILL "$$" 2>/dev/null ) >/dev/null 2>&1 &
}

export HOME="$T/home" OSRC_HOME="$T/osrc" OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0
unset CLAUDE_CODE_SESSION_ID OSRC_HUB_FAST OSRC_HUB_PORT OSRC_CARD_GUARD GEMINI_API_KEY GOOGLE_API_KEY
mkdir -p "$HOME" "$OSRC_HOME/hub/projects" "$OSRC_HOME/hub/decisions" "$OSRC_HOME/hub/status" "$OSRC_HOME/owners" "$OSRC_HOME/jobs" "$OSRC_HOME/proof" "$T/bin"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
guard() { printf '{"session_id":"%s"}' "$1" | bash "$SRC" stop-guard 2>/dev/null; }

echo "=== 1. card_fresh.sh: GNU stat -c %Y first (no Linux infinite block loop) ==="
_sec_arm
grep -q 'stat -c %Y "\$mk".*stat -f %m "\$mk"' "$LIB/card_fresh.sh" \
  && ok "card_fresh.sh tries GNU stat -c %Y before BSD stat -f %m" || bad "card_fresh.sh stat order wrong"
mkdir -p "$T/gnubin"
cat > "$T/gnubin/stat" <<'SH'
#!/bin/sh
if [ "$1" = "-f" ]; then
  printf '  File: "%s"\n    ID: 0 Namelen: 255 Type: ext2/ext3\n' "$3"
  exit 1
elif [ "$1" = "-c" ] && [ "$2" = "%Y" ]; then
  date +%s
  exit 0
fi
exec /usr/bin/stat "$@"
SH
chmod +x "$T/gnubin/stat"
echo '{"name":"LinuxProj","status":"building","reportedAt":"2020-01-01T00:00:00Z"}' > "$OSRC_HOME/hub/projects/sess-gnu.json"
g1="$(PATH="$T/gnubin:$PATH" guard sess-gnu)"
g2="$(PATH="$T/gnubin:$PATH" guard sess-gnu)"
jq -e '.decision == "block"' >/dev/null 2>&1 <<<"$g1" && [ -z "$g2" ] \
  && ok "GNU stat shim: 1st stop blocks, 2nd stop within 30 min is allowed" || bad "GNU stat loop: g1=[$g1] g2=[$g2]"

echo "=== 2. card_fresh.sh: unwritable marker fails open ==="
_sec_arm
mkdir -p "$OSRC_HOME/hub/card-nag/sess-unw"
echo '{"name":"Unw","status":"building","reportedAt":"2020-01-01T00:00:00Z"}' > "$OSRC_HOME/hub/projects/sess-unw.json"
u1="$(guard sess-unw)"
[ -z "$u1" ] && ok "unwritable marker (directory at marker path) fails open" || bad "unwritable marker blocked: $u1"
rmdir "$OSRC_HOME/hub/card-nag/sess-unw"
ln -s "$T/victim" "$OSRC_HOME/hub/card-nag/sess-sym"
echo '{"name":"Sym","status":"building","reportedAt":"2020-01-01T00:00:00Z"}' > "$OSRC_HOME/hub/projects/sess-sym.json"
u2="$(guard sess-sym)"
[ -z "$u2" ] && [ ! -e "$T/victim" ] && ok "symlinked marker fails open and never writes target" || bad "symlinked marker: $u2"

echo "=== 3. card_fresh.sh: marker stays outside owners/ (no adopt leak or rmdir block) ==="
_sec_arm
[ ! -d "$OSRC_HOME/owners/sess-gnu" ] && ok "card nag never creates owners/<sid>/ for a lane-less session" || bad "created owners/sess-gnu"
ad="$(bash "$SRC" adopt --list 2>/dev/null)"
grep -q 'sess-gnu' <<<"$ad" && bad "card nag leaked into adopt --list: $ad" || ok "adopt --list does not list card-nag markers"
mkdir -p "$OSRC_HOME/owners/sess-clean" "$OSRC_HOME/jobs/j-done"
echo done > "$OSRC_HOME/jobs/j-done/status"; echo 0 > "$OSRC_HOME/jobs/j-done/exit"
: > "$OSRC_HOME/owners/sess-clean/j-done"
echo '{"name":"Clean","status":"building","reportedAt":"2020-01-01T00:00:00Z"}' > "$OSRC_HOME/hub/projects/sess-clean.json"
c1="$(guard sess-clean)"; c2="$(guard sess-clean)"
jq -e '.decision == "block"' >/dev/null 2>&1 <<<"$c1" && [ -z "$c2" ] && [ ! -d "$OSRC_HOME/owners/sess-clean" ] \
  && ok "after nag, stop-guard still reaps finished lanes and removes owners/<sid>/" || bad "cleanup blocked: c1=[$c1] c2=[$c2] dir=$(ls -la "$OSRC_HOME/owners/sess-clean" 2>/dev/null)"

echo "=== 4. card_fresh.sh: user-shipped override and closed-decisions-only exempt ==="
_sec_arm
echo '{"name":"ShippedByUser","status":"building","reportedAt":"2020-01-01T00:00:00Z"}' > "$OSRC_HOME/hub/projects/sess-ship.json"
echo '{"status":"shipped","shippedBy":"user","prevStatus":"building"}' > "$OSRC_HOME/hub/status/sess-ship.json"
s1="$(guard sess-ship)"
[ -z "$s1" ] && ok "project marked shipped by user in hub/status/ is not blocked" || bad "user-shipped blocked: $s1"
echo '[{"id":"D1","q":"Already done?","status":"done"}]' > "$OSRC_HOME/hub/decisions/sess-done.json"
s2="$(guard sess-done)"
[ -z "$s2" ] && ok "decisions-only session with all closed decisions is not blocked" || bad "done-only blocked: $s2"

echo "=== 5. card_fresh.sh: odd decision JSON and board.decisions ==="
_sec_arm
now_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf '{"name":"OddDec","status":"building","reportedAt":"%s","board":{"tasks":[{"id":"t1","short":"Fix auth bug","pct":50}]}}\n' "$now_iso" > "$OSRC_HOME/hub/projects/sess-odd.json"
echo '[{"id":"D1","q":123,"askedAt":"2020-01-01T00:00:00Z"}]' > "$OSRC_HOME/hub/decisions/sess-odd.json"
o1="$(guard sess-odd)"
jq -e '.decision == "block" and (.reason | test("D1 \\(123\\)"))' >/dev/null 2>&1 <<<"$o1" \
  && ok "numeric .q in stale decision still detected without jq crash" || bad "numeric .q missed: $o1"
printf '{"name":"BadDf","status":"building","reportedAt":"%s","board":{"tasks":[{"id":"t1","short":"Fix auth bug","pct":50,"model":"Opus 5.5","lane":"Claude cloud"}]}}\n' "$now_iso" > "$OSRC_HOME/hub/projects/sess-baddf.json"
echo '{"decisions":"bad"}' > "$OSRC_HOME/hub/decisions/sess-baddf.json"
o2="$(guard sess-baddf)"
[ -z "$o2" ] && ok "malformed decisions field does not crash fresh card" || bad "malformed decisions blocked fresh card: $o2"
printf '{"name":"BoardDec","status":"building","reportedAt":"%s","board":{"tasks":[{"id":"t1","short":"Fix auth bug","pct":50}],"decisions":[{"id":"B1","q":"Stale board question?","askedAt":"2020-01-01T00:00:00Z"}]}}\n' "$now_iso" > "$OSRC_HOME/hub/projects/sess-bdec.json"
o3="$(guard sess-bdec)"
jq -e '.decision == "block" and (.reason | test("B1 \\(Stale board question"))' >/dev/null 2>&1 <<<"$o3" \
  && ok "stale open decision inside .board.decisions is detected" || bad "board decision missed: $o3"

echo "=== 6. hub_board.sh: odd inputs, synthesized IDs, no hardcoded themes, Idle excluded ==="
_sec_arm
(
  . "$LIB/hub_board.sh"
  base='{"id":"p1","name":"Test","lanes":[{"id":"j1","status":"Idle","state":"idle"},{"id":"j2","status":"Building","state":"working"}]}'
  c='{"board":{"tasks":[{"short":"Fix login bug","pct":"80%"},{"short":"Write unit tests","pct":20}],"flow":["Build","Review","Live"],"decisions":{"open":[{"id":"X","q":"obj"}]},"release":"Fri","releaseNote":123}}'
  out="$(_osrc_hub_apply_board "$base" "$c")"
  jq -e '.boardTracks == 2 and .pct == 50 and .lanes[0].id == "T1" and .lanes[1].id == "T2" and .sessionsNow == 1 and .sessionsRun == 2 and (.flow | length == 3 and .[0].t == "Build") and (has("themes") | not)' >/dev/null <<<"$out" \
    || { echo "FAIL: odd board: $out"; exit 1; }
  c2='{"board":{"tasks":[{"id":"t1","short":"Fix login","pct":50}],"decisions":[{"short":"Ship tonight?","options":"not-an-array"}]}}'
  out2="$(_osrc_hub_apply_board "$base" "$c2")"
  jq -e '.decisions[0].id == "D1" and .decisions[0].q == "Ship tonight?" and .decisions[0].options == []' >/dev/null <<<"$out2" \
    || { echo "FAIL: missing dec id/q/opts: $out2"; exit 1; }
) && ok "hub_board.sh handles string pct, string flow, object decisions, missing p.decisions, missing IDs, Idle, and omits hardcoded themes" \
  || bad "hub_board.sh odd input handling failed"
grep -qi 'Cowork and cloud\|Ready for the waitlist\|_OSRC_BOARD_THEMES' "$LIB/hub_board.sh" \
  && bad "hub_board.sh still contains hardcoded project themes" || ok "hub_board.sh has no hardcoded project themes"

echo "=== 7-8. hub.html: theme k=\"\" safe, board3 responsive CSS, <= 998 lines ==="
_sec_arm
hlines="$(wc -l < "$LIB/hub.html" | tr -d ' ')"
[ "$hlines" -le 998 ] && ok "hub.html line count is $hlines (<= 998)" || bad "hub.html grew to $hlines (> 998)"
grep -q "stats.style.gridTemplateColumns = '1.4fr 1fr 1fr'" "$LIB/hub.html" \
  && bad "hub.html still sets inline gridTemplateColumns on .stats" || ok "hub.html uses board3 class instead of inline gridTemplateColumns"
grep -q "stats.classList.add('board3')" "$LIB/hub.html" && grep -q '@media (min-width: 861px) { \.stats\.board3 { grid-template-columns: 1\.4fr 1fr 1fr; } }' "$LIB/hub-assets/hub-mc3.css" \
  && ok "board3 hero grid is gated to desktop (>= 861px) so mobile stacks to 1fr" || bad "board3 CSS wiring missing"
grep -q "typeof th.f === 'function' ? lanes.filter(th.f) : lanes" "$LIB/hub.html" \
  && ok "hub.html guards th.f when a theme has empty/missing k" || bad "hub.html still calls lanes.filter(th.f) unguarded"

echo "=== 9. board preserves proofStops + _osrc_hub_visible keeps live board projects ==="
_sec_arm
sleep 60 & P=$!; PIDS="$PIDS $P"
mkdir -p "$OSRC_HOME/owners/sess-vis" "$OSRC_HOME/jobs/j-live"
echo running > "$OSRC_HOME/jobs/j-live/status"; echo "$P" > "$OSRC_HOME/jobs/j-live/pid"
echo '{"provider":"codex","model":"gpt-5.5"}' > "$OSRC_HOME/jobs/j-live/meta.json"
: > "$OSRC_HOME/owners/sess-vis/j-live"
mkdir -p "$OSRC_HOME/proof/j-live"
echo '{"fails":3,"stopped":true,"counted":[],"last":{"why":"tests failed","lines":["FAIL: auth"]}}' > "$OSRC_HOME/proof/j-live/rounds.json"
echo '{"name":"Boarded Live","status":"building","board":{"tasks":[{"id":"t1","short":"Fix auth bug","pct":50}]}}' > "$OSRC_HOME/hub/projects/sess-vis.json"
touch -t "$(date -v-48H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '48 hours ago' '+%Y%m%d%H%M.%S')" "$OSRC_HOME/hub/projects/sess-vis.json"
ex="$(bash "$SRC" hub export 2>/dev/null)"
vp="$(jq -c '.projects[] | select(.id == "sess-vis")' <<<"$ex")"
jq -e '.boardTracks == 1 and .liveLanes == 1 and (.proofStops | length == 1 and .[0].proof.stopped == true)' >/dev/null 2>&1 <<<"$vp" \
  && ok "live board project (>24h card, no beat) stays visible and preserves proofStops" || bad "board visibility/proofStops: $vp"
if command -v node >/dev/null 2>&1; then
  pf="$(node -e '
    const fs = require("fs"), vm = require("vm");
    const win = {}; vm.runInNewContext(fs.readFileSync(process.argv[1], "utf8"), { window: win });
    const el = (t, c, x) => ({ t, c: c || "", x, kids: [], classList: { contains: (k) => (c || "").split(" ").includes(k) }, append(...a) { this.kids.push(...a); } });
    const p = JSON.parse(process.argv[2]);
    const lines = win.OSRC_HUB_PROOF.tileLines(p, { el, ic: () => el("i") }).filter((n) => n.classList.contains("stop"));
    console.log(JSON.stringify({ stopLines: lines.length, needs: win.OSRC_HUB_PROOF.needs([p]) }));
  ' "$LIB/hub-assets/hub-proof.js" "$vp" 2>&1)"
  jq -e '.stopLines == 1 and .needs == 1' >/dev/null 2>&1 <<<"$pf" \
    && ok "hub-proof.js surfaces stopped proof lanes for board projects" || bad "hub-proof.js: $pf"
else echo "SKIP: node not installed"; fi

echo "=== 10. spend.sh & limits.sh: agy oauth token -> subscription even with GEMINI_API_KEY ==="
_sec_arm
mkdir -p "$HOME/.gemini/antigravity-cli"
echo "oauth-tok" > "$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
echo "GEMINI_API_KEY=AIzaFakeKey1234567890" > "$HOME/.env"
b="$(OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1; have() { [ "$1" = agy ] && return 0; command -v "$1" >/dev/null 2>&1; }; osrc_lane_billing gm' _ "$SRC")"
[ "$b" = "subscription" ] && ok "osrc_lane_billing gm returns subscription with oauth token + GEMINI_API_KEY in ~/.env" || bad "gm billing: $b"
OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1; _osrc_harness_auth agy' _ "$SRC" \
  && ok "_osrc_harness_auth agy detects CLI-only oauth token without ~/.antigravity" || bad "_osrc_harness_auth agy missed oauth token"

echo "=== 11. hub report --board rejects empty path and stores valid board ==="
_sec_arm
CLAUDE_CODE_SESSION_ID=sess-brd bash "$SRC" hub report --board "" >/dev/null 2>&1 \
  && bad "hub report --board \"\" was accepted" || ok "hub report --board \"\" is rejected"
echo '{"tasks":[{"id":"t1","short":"Ship fix cleanly","pct":75}]}' > "$T/board.json"
CLAUDE_CODE_SESSION_ID=sess-brd bash "$SRC" hub report --board "$T/board.json" >/dev/null 2>&1 \
  && jq -e '.board.tasks[0].short == "Ship fix cleanly"' "$OSRC_HOME/hub/projects/sess-brd.json" >/dev/null 2>&1 \
  && ok "hub report --board <valid.json> saves .board" || bad "valid --board failed"

echo "=== 12. mc restarts a stale hub (old version or other script path), never a foreign pid ==="
_sec_arm
dead_pid() { local s; s="$(ps -p "$1" -o stat= 2>/dev/null | tr -d ' ')"; case "$s" in ''|*Z*|*z*) return 0 ;; *) return 1 ;; esac; }
wait_dead() { local i; for i in $(seq 1 40); do dead_pid "$1" && return 0; sleep 0.25; done; return 1; }
wait_serve() { local i; for i in $(seq 1 60); do [ -f "$OSRC_HOME/hub/serve.json" ] && return 0; sleep 0.25; done; return 1; }
mcurl() { OSRC_HUB_NO_OPEN=1 bash "$SRC" mc 2>/dev/null; }
if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  # A random free HIGH port, never the 8788-8798 scan range: a real Mission Control can own
  # 127.0.0.1:8788, and a default `hub serve` would scan into it (and `mc`'s probe would wait
  # on it). OSRC_HUB_PORT covers `mc`'s detached respawn; --port pins the direct serves.
  HUBPORT="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null)"
  case "$HUBPORT" in ''|*[!0-9]*) HUBPORT="" ;; esac
fi
if [ -n "${HUBPORT:-}" ]; then
  export OSRC_HUB_PORT="$HUBPORT"
  eng_rp="$(cd "$(dirname "$SRC")" && pwd -P)/$(basename "$SRC")"
  ver_cur="$(sed -n 's/^OSRC_VERSION="\(.*\)"$/\1/p' "$SRC" | head -1)"; [ -n "$ver_cur" ] || ver_cur="0.17.3"
  OSRC_HUB_NO_OPEN=1 bash "$SRC" hub serve --port "$HUBPORT" --no-open >"$T/mc-serve-1.log" 2>&1 &
  HP1=$!; PIDS="$PIDS $HP1"
  wait_serve || { echo "FAIL: hub serve wrote no serve.json"; cat "$T/mc-serve-1.log"; exit 1; }
  pid1="$(jq -r .pid "$OSRC_HOME/hub/serve.json")"; port1="$(jq -r .port "$OSRC_HOME/hub/serve.json")"
  kill -0 "$pid1" 2>/dev/null && [ "$port1" = "$HUBPORT" ] \
    && jq -e --arg e "$eng_rp" --arg v "$ver_cur" '.engine == $e and .ver == $v' "$OSRC_HOME/hub/serve.json" >/dev/null \
    && ok "hub serve records pid, port, engine path and engine version in serve.json" \
    || bad "serve.json record: $(cat "$OSRC_HOME/hub/serve.json") pid1=$pid1"

  out1="$(mcurl)"
  [ "$(jq -r .pid "$OSRC_HOME/hub/serve.json")" = "$pid1" ] && kill -0 "$pid1" 2>/dev/null \
    && case "$out1" in *"127.0.0.1:$port1/"*) true ;; *) false ;; esac \
    && ok "mc reuses a hub running the current engine and version" || bad "mc restart-happy: $out1"

  jq '.ver = "0.17.2"' "$OSRC_HOME/hub/serve.json" > "$T/sj.tmp" && mv "$T/sj.tmp" "$OSRC_HOME/hub/serve.json"
  out2="$(mcurl)"
  pid2="$(jq -r .pid "$OSRC_HOME/hub/serve.json" 2>/dev/null)"
  wait_dead "$pid1" && [ "$pid2" != "$pid1" ] && kill -0 "$pid2" 2>/dev/null \
    && jq -e --arg v "$ver_cur" '.ver == $v' "$OSRC_HOME/hub/serve.json" >/dev/null \
    && case "$out2" in *"127.0.0.1:"*) true ;; *) false ;; esac \
    && ok "mc kills and respawns a hub whose recorded version is older (0.17.2)" \
    || bad "version-stale hub survived: pid1=$pid1 pid2=$pid2 out=$out2"
  wait "$HP1" 2>/dev/null || true

  # Script path differs: a copied tree's server serves this OSRC_HOME; same version, other path.
  # The old-tree server binds the same strict port: wait (bounded) until the hub holding it is dead.
  pid2="$(jq -r .pid "$OSRC_HOME/hub/serve.json")"; kill "$pid2" 2>/dev/null; wait_dead "$pid2" || bad "hub $pid2 did not stop on TERM"
  rm -f "$OSRC_HOME/hub/serve.json"
  cp -R "$S" "$T/oldtree" 2>/dev/null
  OSRC_HUB_NO_OPEN=1 bash "$T/oldtree/outsourcerer.sh" hub serve --port "$HUBPORT" --no-open >"$T/mc-serve-old.log" 2>&1 &
  HP2=$!; PIDS="$PIDS $HP2"
  wait_serve || { echo "FAIL: old-tree serve wrote no serve.json"; exit 1; }
  pid3="$(jq -r .pid "$OSRC_HOME/hub/serve.json")"
  jq -e --arg e "$eng_rp" '.engine != $e' "$OSRC_HOME/hub/serve.json" >/dev/null \
    && ok "old-tree server records its own engine path in serve.json" || bad "oldtree engine recorded wrong"
  out3="$(mcurl)"
  pid4="$(jq -r .pid "$OSRC_HOME/hub/serve.json" 2>/dev/null)"
  wait_dead "$pid3" && [ "$pid4" != "$pid3" ] && kill -0 "$pid4" 2>/dev/null \
    && jq -e --arg e "$eng_rp" '.engine == $e' "$OSRC_HOME/hub/serve.json" >/dev/null \
    && ok "mc restarts a hub launched from a different script path (same version)" \
    || bad "path-stale hub survived: pid3=$pid3 pid4=$pid4 out=$out3"
  wait "$HP2" 2>/dev/null || true
  PIDS="$PIDS $pid4"

  # A foreign pid named in serve.json is never killed; lsof finds the real hub, which is current.
  sleep 300 & FPID=$!; PIDS="$PIDS $FPID"
  port4="$(jq -r .port "$OSRC_HOME/hub/serve.json")"
  printf '{"pid":%s,"port":%s,"started":1,"engine":"/tmp/nope","ver":"0.0.1"}\n' "$FPID" "$port4" > "$OSRC_HOME/hub/serve.json"
  out4="$(mcurl)"
  kill -0 "$FPID" 2>/dev/null && kill -0 "$pid4" 2>/dev/null \
    && case "$out4" in *"127.0.0.1:$port4/"*) true ;; *) false ;; esac \
    && ok "a non-hub pid in serve.json is never killed; the real hub is reused" \
    || bad "foreign pid killed or hub lost: fpid=$FPID pid4=$pid4 out=$out4"
  printf '{"pid":%s,"port":%s,"started":1,"engine":"%s","ver":"%s"}\n' "$pid4" "$port4" "$eng_rp" "$ver_cur" > "$OSRC_HOME/hub/serve.json"

  if command -v lsof >/dev/null 2>&1; then
    rm -f "$OSRC_HOME/hub/serve.json"
    out5="$(mcurl)"
    kill -0 "$pid4" 2>/dev/null && case "$out5" in *"127.0.0.1:$port4/"*) true ;; *) false ;; esac \
      && ok "with serve.json gone, mc identifies the live hub via lsof and still reuses it" \
      || bad "missing serve.json: hub killed unnecessarily: $out5"
  else echo "SKIP: lsof not installed"; fi

  ! grep -nE 'hub serve[^|]*\|[[:space:]]*head' "$SRC" "$LIB"/*.sh >/dev/null 2>&1 \
    && ok "no 'hub serve | head' pipeline anywhere in the start path" || bad "hub serve is piped into head"
else echo "SKIP: curl/python3 missing or no free high port"; fi

echo "=== 13. agy quota/backoff panes -> EVENT limit, never 'stalled: screen unrecognised' ==="
_sec_arm
# The reported pane tail: '⚠ Individual quota reached ... Resets in 1h13m1s.' + 'Error ID: ...' +
# an empty '>' prompt read as `unknown`, so supervise woke the user with EVENT stalled/unrecognised.
# File-backed fake tmux serves the fixtures; supervise internals run in a sourced subshell.
mkdir -p "$T/bin" "$T/panes" "$OSRC_HOME/owners/S" "$OSRC_HOME/lanes" "$OSRC_HOME/supervise/S"
ln -sf "$HERE/fake-bin/tmux-files" "$T/bin/tmux"
export PATH="$T/bin:$PATH" FAKE_TMUX_DIR="$T/panes" \
  OSRC_SUPERVISE_POLL=1 OSRC_SUPERVISE_CONFIRM=0 OSRC_SUPERVISE_SETTLE=0 OSRC_SUPERVISE_TICK_SECS=86400
date +%s > "$OSRC_HOME/supervise/S/tick.time"
svobs() { ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _sv_observe_emit "$1" "$(date +%s)" supervise S
  printf '%s|%s|%s' "${SV_K:-none}" "$SV_D" "$SV_NX" ); }
svscreen() { ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _sv_target_screen "$1" ); }

cp "$HERE/fixtures/supervise/agy-quota-reached.txt" "$T/panes/n1.screen"; : > "$OSRC_HOME/owners/S/n1"
scr="$(svscreen n1)"
[ "$(printf '%s\n' "$scr" | head -1)" = limit ] \
  && ok "agy quota pane -> limit (was 'unknown' -> stalled/unrecognised)" \
  || bad "agy quota pane -> '$(printf '%s\n' "$scr" | head -1)'"
det="$(printf '%s\n' "$scr" | sed -n 2p)"
case "$det" in
  "Neon quota reached, resets "[0-9][0-9]":"[0-9][0-9]" (epoch "[0-9]*")")
    ok "limit detail is plain-English + epoch: '$det'" ;;
  *) bad "limit detail wrong: '$det'" ;;
esac
ep="${det##*epoch }"; ep="${ep%)}"; now_s="$(date +%s)"
case "$ep" in ''|*[!0-9]*) bad "no numeric epoch in '$det'" ;;
  *) [ "$ep" -gt "$now_s" ] && [ "$ep" -le $(( now_s + 4381 + 120 )) ] \
     && ok "'Resets in 1h13m1s' parses to an epoch ~4381s ahead" \
     || bad "epoch $ep not ~1h13m ahead of $now_s" ;;
esac
obs="$(svobs n1)"
case "$obs" in
  limit\|*) ok "observe emits EVENT limit" ;;
  *) bad "observe kind wrong: '$obs'" ;;
esac
nx="$(jq -r 'select(.target=="n1" and .kind=="limit") | .next' "$OSRC_HOME/lanes/events.jsonl" 2>/dev/null | tail -1)"
case "$nx" in *"another lane"*) ok "NEXT suggests moving the work to another lane" ;; *) bad "NEXT missing move-lane advice: '$nx'" ;; esac
jq -e 'select(.target=="n1" and .kind=="limit") | select(.detail | test("quota reached, resets [0-9]{2}:[0-9]{2} \\(epoch [0-9]+\\)"))' \
  "$OSRC_HOME/lanes/events.jsonl" >/dev/null 2>&1 \
  && ok "events.jsonl limit row carries clock + epoch" || bad "no limit row with epoch in events.jsonl"

# agy parked on its own retry/backoff timer is the same class of wait: a limit, never a stall.
cp "$HERE/fixtures/supervise/agy-retry-backoff.txt" "$T/panes/n2.screen"; : > "$OSRC_HOME/owners/S/n2"
scr="$(svscreen n2)"
[ "$(printf '%s\n' "$scr" | head -1)" = limit ] \
  && ok "agy retry-backoff pane -> limit (never stalled)" \
  || bad "agy backoff pane -> '$(printf '%s\n' "$scr" | head -1)'"
det="$(printf '%s\n' "$scr" | sed -n 2p)"
grep -q 'waiting on its own timer.*epoch [0-9]' <<<"$det" \
  && ok "backoff detail names the model's own timer: '$det'" \
  || bad "backoff detail wrong: '$det'"
obs="$(svobs n2)"
case "$obs" in
  limit\|*) ok "backoff observe emits EVENT limit" ;;
  *) bad "backoff observe: '$obs'" ;;
esac

# Repeated identical polls of either parked screen still yield limit rows, never a stalled one.
svobs n1 >/dev/null; svobs n2 >/dev/null
! jq -e 'select(.target=="n1" or .target=="n2") | select(.kind=="stalled")' "$OSRC_HOME/lanes/events.jsonl" >/dev/null 2>&1 \
  && ok "no 'stalled' event for the parked agy lanes" || bad "a stalled event was emitted"

# The loose timer/backoff shapes are agy-gated: the same words on another engine's pane are not a limit.
printf 'polishing the docs\nyour trial resets in 5m\n$ \n' > "$T/panes/g1.screen"; : > "$OSRC_HOME/owners/S/g1"
[ "$(svscreen g1 | head -1)" != limit ] \
  && ok "'resets in 5m' on a non-agy pane is not a limit" || bad "non-agy pane read as limit"

echo "=== 14. devin 'Approval required' modal: Exec(kind)+command -> policy verdicts ==="
_sec_arm
# Reported pane: '▲ Approval required / This action requires your approval. / <command> /
# ❭ Allow ← ◼◼◼◼ → Once   Exec(jq) / Bypass mode / Deny' -- kind stayed 'other', so the safe
# policy held it as 'unrecognised prompt kind: other' even for a read-only jq.
scranz() { ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1; _osrc_screen_analyze_text devin < "$HERE/fixtures/screen/$1.ansi"
  printf '%s|%s|%s|%s|%s|%s' "$OSRC_SCR_STATE" "$OSRC_SCR_KIND" "$OSRC_SCR_SEL" "$OSRC_SCR_SCOPE" "$OSRC_SCR_PATH" "$OSRC_SCR_CMD" ); }
FXR="$T/repo14"; mkdir -p "$FXR/src" "$FXR/out"; git -C "$FXR" init -q
classify() { ( cd "$FXR" && printf '%s' "$1" | python3 -I "$LIB/approver_classify.py" --root "$FXR" --kind shell --path "$2" ); }

row="$(scranz dv-approval-modal)"
[ "${row%%|*}" = approval ] || bad "modal not approval: $row"
IFS='|' read -r _st _kind _sel _scope _path _cmd <<EOF
$row
EOF
[ "$_kind" = shell ] && [ "$_sel" = Allow ] && [ "$_scope" = once ] && [ "$_path" = jq ]   && ok "modal -> kind=shell (Exec tag) sel=Allow scope=once tag=jq"   || bad "modal fields wrong: $_kind|$_sel|$_scope|$_path"
[ "$_cmd" = 'SCRATCH=/tmp/osrc-scratch && jq -r .name /tmp/osrc-scratch/report.json; echo done' ]   && ok "command extracted from between the header and the menu"   || bad "cmd wrong: '$_cmd'"
v="$(classify "$_cmd" "$_path")"
# An ALL-CAPS standalone assignment holds -- 'PAGER=evil; git log' showed the approver
# cannot tell a private variable from an already-exported one. The reported command parses
# correctly now (shell/jq/Allow/once) and holds on the exported-name rule, never 'other'.
case "$v" in hold\ *possibly-exported*) ok "SCRATCH=.. standalone holds (possibly exported; lowercase scratch= approves)" ;;
  *) bad "SCRATCH=.. standalone: $v" ;; esac
v="$(classify 'scratch=out && jq -r .name out/report.json; echo done' '')"
case "$v" in approve\ *) ok "lowercase scratch=.. && jq ..; echo .. approves" ;;
  *) bad "lowercase scratch assign held: $v" ;; esac
v="$(classify 'PAGER=evil; git log' '')"
case "$v" in hold\ *) ok "'PAGER=evil; git log' holds (exported-name hole closed)" ;; *) bad "PAGER hole: $v" ;; esac

row="$(scranz dv-approval-modal-box)"
IFS='|' read -r _st _kind _sel _scope _path _cmd <<EOF
$row
EOF
[ "$_kind" = shell ] && [ -z "$_cmd" ] && ok "boxed command (3 rows) gives no command" || bad "boxed cmd read: '$_cmd' kind=$_kind"
v="$(classify "$_cmd" "$_path")"; case "$v" in hold\ *) ok "boxed jq holds" ;; *) bad "boxed jq approved: $v" ;; esac

row="$(scranz dv-approval-modal-rm)"
IFS='|' read -r _st _kind _sel _scope _path _cmd <<EOF
$row
EOF
v="$(classify "$_cmd" "$_path")"; case "$v" in hold\ *) ok "Exec(rm) 'rm -rf ~' still holds" ;; *) bad "rm -rf approved: $v" ;; esac

# The pre-modal '└ $' shape gives no command, so it holds.
row="$(scranz dv-approval)"; IFS='|' read -r _st _kind _sel _scope _path _cmd <<EOF
$row
EOF
[ "$_kind" = shell ] && [ -z "$_cmd" ] && ok "old '└ $' prompt gives no command" || bad "old prompt read: $_kind '$_cmd'"

# 'Bypass mode' can never be an approve-once row, whatever the command is.
( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
  OSRC_SCR_ENGINE=devin OSRC_SCR_SEL='Bypass mode' OSRC_SCR_SCOPE=once
  _osrc_approver_once_row )   && bad "'Bypass mode' passed _osrc_approver_once_row"   || ok "'Bypass mode' can never approve"
( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
  OSRC_SCR_ENGINE=devin OSRC_SCR_SEL=Allow OSRC_SCR_SCOPE=once
  _osrc_approver_once_row )   && ok "Allow+once is the one-time approve row"   || bad "Allow+once stopped passing once_row"

# Wrapped/multi-line commands still hold: joining rows with spaces could merge two real
# commands into one safe-looking line ('ls' + 'rm -rf x' -> 'ls rm -rf x'), so \n it stays.
v="$(printf 'ls -la src &&\nrm -rf ~/Documents' | (cd "$FXR" && python3 -I "$LIB/approver_classify.py" --root "$FXR" --kind shell))"
case "$v" in hold\ *) ok "multi-line command still holds (deliberate: no space-join)" ;; *) bad "multi-line approved: $v" ;; esac

echo "=== 15. session start slow-boot grace + agy composer mode-hint placeholder ==="
_sec_arm
# (a) Slow boots (agy/devin take 10-20s): the liveness check gets a second bounded window that
# keeps waiting ONLY while the pane shell has a live descendant — never re-runs the launch.
grep -q 'OSRC_SESSION_LIVENESS_GRACE_SECS' "$SRC" \
  && ok "grace window env exists" || bad "no OSRC_SESSION_LIVENESS_GRACE_SECS in outsourcerer.sh"
# This check sources the engine DIRECTLY inside the command substitution (no inner ( )
# wrapper like the others) - the shape is deliberate: it is the exit-chain arm-level
# regression (bash 3.2 fires a $( ) EXIT trap with BASH_SUBSHELL=0; the chain must not
# run this suite's cleanup here). test_exit_trap_chain.sh (i)/(j) own the focused cases.
_desc_out="$( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
  bash -c 'bash -c "sleep 30; true" & wait' & w=$!
  # The launch check polls; so does this. A fork right after `&` may not have its child yet.
  r=none; n=0; while [ "$n" -lt 30 ]; do _session_pane_descendant "$w" && { r=found; break; }; sleep 0.1; n=$((n + 1)); done
  s=""; sleep 30 & s=$!
  _session_pane_descendant "$s" || r="$r+childless-none"
  kill "$w" "$s" 2>/dev/null; printf '%s' "$r" )"
grep -qx 'found+childless-none' <<<"$_desc_out" \
  && ok "_session_pane_descendant: grandchild behind a shell child found; childless pid missed" \
  || bad "_session_pane_descendant misread the boot/descendant shapes"
# A dead pane (no descendants) must refuse at the FIRST grace poll, not after the full budget —
# test_session_exit_liveness.sh §7 owns the timing assertion end-to-end with a fake tmux.
grep -q '_session_pane_descendant' "$SRC" \
  && ok "grace gate is wired into the launch check" || bad "descendant probe not called by the check"

_sec_arm   # each source of the engine is slow on a loaded runner; (b) gets its own bound
# (b) agy's empty-composer mode hint ('Auto mode: ... (shift+tab to cycle)', rendered in a
# muted 38;5;1xx the dim probe misses) read as 'unsent text'. The live capture is the fixture.
v="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
  _osrc_screen_analyze_text agy < "$SCRIPT_DIR/fixtures/screen/agy-mode-hint.ansi"
  printf '%s|%s' "$OSRC_SCR_STATE" "$OSRC_SCR_COMPOSER" ) )"
[ "$v" = "composer|" ] && ok "agy mode hint reads as an empty composer, not unsent text" \
  || bad "agy mode hint still leaks: '$v'"
for m in "Plan mode: research & plan only (shift+tab to cycle)" \
         "Accept-edits mode: file edits auto-approved (shift+tab to cycle)" \
         "Best-of-N mode: fork into parallel arms and pick a winner (shift+tab to cycle)"; do
  { printf '%s\n' '────' "> $m" '────' '? for shortcuts   auto' > "$T/box.txt" && [ -s "$T/box.txt" ]; } \
    || bad "mode-hint fixture unwritable (scratch $T intact?)"
  v="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
    _osrc_screen_analyze_text agy < "$T/box.txt"
    printf 'FOUND=%s|%s' "${OSRC_SCR_COMPOSER_FOUND:-unset}" "${OSRC_SCR_COMPOSER:-}" ) )"
  [ "$v" = "FOUND=1|" ] && ok "mode hint variant clears: ${m%%:*}" \
    || bad "mode hint variant check wrong (want 'FOUND=1|'): '$v'"
done
{ printf '%s\n' '────' '> ship the release by noon' '────' '? for shortcuts   auto' > "$T/box.txt" && [ -s "$T/box.txt" ]; } \
  || bad "real-draft fixture unwritable (scratch $T intact?)"
v="$( ( OSRC_SOURCED=1; . "$SRC" >/dev/null 2>&1
  _osrc_screen_analyze_text agy < "$T/box.txt"
  printf 'FOUND=%s|%s' "${OSRC_SCR_COMPOSER_FOUND:-unset}" "${OSRC_SCR_COMPOSER:-}" ) )"
[ "$v" = "FOUND=1|ship the release by noon" ] && ok "a real typed draft is still reported" \
  || bad "placeholder filter ate a real draft (or analyze never ran): '$v'"

echo "=== 16. stale content: cards, decisions, Quiet fold, no lane counts, prompt-title fallback ==="
_sec_arm
N3T="$T/n3"; mkdir -p "$N3T/home/.claude/projects" "$N3T/osrc/hub/projects" "$N3T/osrc/hub/decisions" "$N3T/osrc/hub/seen" "$N3T/osrc/owners" "$N3T/osrc/jobs" "$N3T/work/Prompts" "$N3T/work/my-cool-app" "$N3T/work/outsourcerer"
now_s="$(date +%s)"
iso_ago() { local e=$(( now_s - $1 )); date -u -r "$e" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$e" '+%Y-%m-%dT%H:%M:%SZ'; }
t10h="$(iso_ago $((10 * 3600)))"
t13h="$(iso_ago $((13 * 3600)))"
t10m="$(iso_ago $((10 * 60)))"
t30h="$(iso_ago $((30 * 3600)))"

# (a) Stale card (10 h old) + 13 h old unconfirmed decision + fresh 10 min decision (confirmedAt overrides old askedAt)
cat > "$N3T/osrc/hub/projects/s-stale.json" <<EOF
{"name":"Total Recall 1.9.86","status":"building","pct":73,"eta":"Fri noon","next":"Neon quota died 01:00, merge 09:00","reportedAt":"$t10h","summary":"90 lanes: 1 building, 89 done","summaryAt":"$t10m"}
EOF
cat > "$N3T/osrc/hub/decisions/s-stale.json" <<EOF
[
  {"id":"D1","q":"Old question from 13h ago?","short":"Old question","status":"wait","weight":"Critical","askedAt":"$t13h"},
  {"id":"D2","q":"Fresh re-confirmed question?","short":"Fresh question","status":"wait","weight":"High","askedAt":"$t13h","confirmedAt":"$t10m"},
  {"id":"D3","q":"Code-word affects as a string?","short":"Code-word","status":"wait","weight":"Low","askedAt":"$t10m","affects":"INV"},
  {"id":"D4","q":"Mixed affects array?","short":"Mixed","status":"wait","weight":"Low","askedAt":"$t10m","affects":["INV","Cost"]}
]
EOF

# (b) Quiet project (no live lane, no open decision, no card update in 24 h) + prompt-text title starting with '[' / READ BEFORE
mkdir -p "$N3T/osrc/hub/seen/s-prompt" "$N3T/home/.claude/projects/-n3-prompts"
touch "$N3T/osrc/hub/seen/s-prompt/.beat"
printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"[ACK FIRST - READ BEFORE ANYTHING] do work"}}\n' "$N3T/work/Prompts" > "$N3T/home/.claude/projects/-n3-prompts/s-prompt.jsonl"

# (c) Prompt-text title > 40 chars -> falls back to folder name in sentence case ("My cool app")
mkdir -p "$N3T/osrc/hub/seen/s-long" "$N3T/home/.claude/projects/-n3-app"
touch "$N3T/osrc/hub/seen/s-long/.beat"
printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"start"}}\n{"type":"ai-title","aiTitle":"Outsourcerer 0.16.3 orchestrator handover"}\n' "$N3T/work/my-cool-app" > "$N3T/home/.claude/projects/-n3-app/s-long.jsonl"

# (d) Quiet project with card older than 24 h (30 h ago), fresh beat so it stays exported
mkdir -p "$N3T/osrc/hub/seen/s-quiet"
touch "$N3T/osrc/hub/seen/s-quiet/.beat"
cat > "$N3T/osrc/hub/projects/s-quiet.json" <<EOF
{"name":"Quiet Card","status":"idle","reportedAt":"$t30h"}
EOF

# (e) Fresh card (10 min old) -> Next stays visible, not stale, not quiet
cat > "$N3T/osrc/hub/projects/s-fresh.json" <<EOF
{"name":"Fresh Proj","status":"building","pct":40,"next":"Finish unit tests","reportedAt":"$t10m"}
EOF

# (f) Lifetime sessions for s-fresh: seen x2 + owners x1 + job meta x1 = 4 distinct; .beat and watch.* never count
mkdir -p "$N3T/osrc/hub/seen/s-fresh" "$N3T/osrc/owners/s-fresh" "$N3T/osrc/jobs/j-seen1"
touch "$N3T/osrc/hub/seen/s-fresh/lane-a" "$N3T/osrc/hub/seen/s-fresh/lane-b" "$N3T/osrc/hub/seen/s-fresh/.beat"
touch "$N3T/osrc/owners/s-fresh/lane-c" "$N3T/osrc/owners/s-fresh/watch.999"
printf '{"id":"j-seen1","owner":"s-fresh","started":1}\n' > "$N3T/osrc/jobs/j-seen1/meta.json"
echo done > "$N3T/osrc/jobs/j-seen1/status"
touch -t 202001010000.00 "$N3T/osrc/jobs/j-seen1" 2>/dev/null || touch -d '2020-01-01' "$N3T/osrc/jobs/j-seen1" 2>/dev/null || true

ex16="$(HOME="$N3T/home" OSRC_HOME="$N3T/osrc" OSRC_CLAUDE_PROJECTS_DIR="$N3T/home/.claude/projects" OSRC_HUB_FAST=0 bash "$SRC" hub export 2>/dev/null)"
jq -e '.projects[] | select(.id == "s-stale") | .cardStale == true and (has("next") | not) and .cardAgeMin >= 595' >/dev/null 2>&1 <<<"$ex16" \
  && ok "export marks 10h card cardStale=true and hides stale Next text" || bad "stale card export: $(jq -c '.projects[]|select(.id=="s-stale")|{cardStale,next,cardAgeMin,reportedAt}' <<<"$ex16")"
jq -e '.projects[] | select(.id == "s-fresh") | .cardStale == false and .next == "Finish unit tests" and .quiet == false' >/dev/null 2>&1 <<<"$ex16" \
  && ok "export keeps fresh (10m) card Next text and quiet=false" || bad "fresh card export: $(jq -c '.projects[]|select(.id=="s-fresh")|{cardStale,next,quiet}' <<<"$ex16")"
ex16_wide="$(HOME="$N3T/home" OSRC_HOME="$N3T/osrc" OSRC_CLAUDE_PROJECTS_DIR="$N3T/home/.claude/projects" OSRC_HUB_FAST=0 OSRC_CARD_STALE_MIN=720 OSRC_DECISION_STALE_H=24 bash "$SRC" hub export 2>/dev/null)"
jq -e '.projects[] | select(.id == "s-stale") | .cardStale == false and .next == "Neon quota died 01:00, merge 09:00" and (.decisions[] | select(.id == "D1") | .stale == false)' >/dev/null 2>&1 <<<"$ex16_wide" \
  && ok "OSRC_CARD_STALE_MIN and OSRC_DECISION_STALE_H knobs govern export staleness" || bad "knobs ignored: $(jq -c '.projects[]|select(.id=="s-stale")|{cardStale,next,decs:[.decisions[]|{id,stale}]}' <<<"$ex16_wide")"
jq -e '.projects[] | select(.id == "s-stale") | (.decisions[] | select(.id == "D1") | .status == "wait" and .stale == true and .staleHours >= 12) and (.decisions[] | select(.id == "D2") | .status == "wait" and .stale == false)' >/dev/null 2>&1 <<<"$ex16" \
  && ok "13h open decision marked stale without auto-closing; fresh confirmedAt stays fresh" || bad "decision staleness export: $(jq -c '.projects[]|select(.id=="s-stale")|.decisions' <<<"$ex16")"
jq -e '.projects[] | select(.id == "s-prompt") | .name == "Prompts" and .quiet == true' >/dev/null 2>&1 <<<"$ex16" \
  && ok "prompt title ('[ACK FIRST - READ BEFORE...') falls back to folder name 'Prompts' and quiet=true" || bad "s-prompt: $(jq -c '.projects[]|select(.id=="s-prompt")|{name,folder,quiet}' <<<"$ex16")"
jq -e '.projects[] | select(.id == "s-long") | .name == "My cool app" and .quiet == true' >/dev/null 2>&1 <<<"$ex16" \
  && ok ">40 char title ('Outsourcerer 0.16.3 orchestrator handover') falls back to folder name in sentence case ('My cool app')" || bad "s-long: $(jq -c '.projects[]|select(.id=="s-long")|{name,folder,quiet}' <<<"$ex16")"
jq -e '.projects[] | select(.id == "s-quiet") | .quiet == true' >/dev/null 2>&1 <<<"$ex16" \
  && ok "project with no live lane, no open decision, and >24h card is tagged quiet (not deleted)" || bad "s-quiet: $(jq -c '.projects[]|select(.id=="s-quiet")|{name,quiet,reportedAt}' <<<"$ex16")"
jq -e '.projects[] | select(.id == "s-fresh") | .sessionsTotal == 4 and .sessionsRun == 4 and .sessionsNow == 0' >/dev/null 2>&1 <<<"$ex16" \
  && ok "sessionsTotal counts every distinct lane ever owned (seen+owners+job meta, deduped; .beat/watch.* ignored); sessionsRun/sessionsNow export with it" || bad "sessions count: $(jq -c '.projects[]|select(.id=="s-fresh")|{sessionsTotal,sessionsRun,sessionsNow}' <<<"$ex16")"
jq -e '.projects[] | select(.id == "s-stale") | .sessionsTotal == 0 and .sessionsRun == 0' >/dev/null 2>&1 <<<"$ex16" \
  && ok "project with no lane history exports sessionsTotal/sessionsRun 0 so the page line hides" || bad "zero sessions: $(jq -c '.projects[]|select(.id=="s-stale")|{sessionsTotal,sessionsRun}' <<<"$ex16")"
jq -e '.projects[] | select(.id == "s-stale") | (.decisions[] | select(.id == "D3") | .affects == ["INV"]) and (.decisions[] | select(.id == "D4") | .affects == ["INV","Cost"])' >/dev/null 2>&1 <<<"$ex16" \
  && ok "decision affects normalize string->array and keep arrays (code-word filtering stays render-side)" || bad "affects normalize: $(jq -c '.projects[]|select(.id=="s-stale")|.decisions' <<<"$ex16")"

if command -v node >/dev/null 2>&1; then
  n3r="$(node - "$LIB/hub-assets/hub-home.js" "$LIB/hub-assets/hub-decide.js" "$ex16" <<'EOF' 2>&1
const fs = require('fs'), vm = require('vm');
function mk(tag, cls, txt) {
  return { tag, className: cls || '', text: txt == null ? '' : String(txt), children: [], dataset: {}, style: {}, id: '', title: '', attrs: {},
    append(...k) { this.children.push(...k); }, appendChild(k) { this.children.push(k); return k; }, prepend(...k) { this.children.unshift(...k); }, replaceChildren(...k) { this.children = k; },
    setAttribute(k, v) { this.attrs[k] = v; }, addEventListener() {}, remove() {},
    classList: { contains: (c) => (cls || '').split(' ').includes(c), add(c) { this.added = (this.added || []).concat(c); }, toggle() {}, remove() {} } };
}
const win = {};
const ctxEnv = { window: win, document: { createTextNode: (t) => ({ tag: '#text', text: String(t), children: [] }), createElement: (t) => mk(t), body: { appendChild() {} } }, setTimeout, clearTimeout, requestAnimationFrame: () => {} };
vm.runInNewContext(fs.readFileSync(process.argv[2], 'utf8'), ctxEnv);
vm.runInNewContext(fs.readFileSync(process.argv[3], 'utf8'), ctxEnv);
const data = JSON.parse(process.argv[4]);
const projects = data.projects.map((p) => win.OSRC_HUB_CLEAN.project(p));
const ORDER = ['Critical', 'High', 'Medium', 'Low'];
const byWeight = (a, b) => ORDER.indexOf(a.weight) - ORDER.indexOf(b.weight);
const openDecs = (p) => (p.decisions || []).filter((d) => d.status !== 'done').sort(byWeight);
const main = mk('main');
const H = win.OSRC_HUB_HOME({ $: (id) => (id === 'main' ? main : null), el: (t, c, x) => mk(t, c, x), ic: () => mk('i'), pri: (w) => mk('span', 'pri', w),
  paint() {}, openDecs, byWeight, stPill: () => mk('span', 'pill'), go() {}, staleCheck() {}, db: {}, canWrite: null, mode: 'local', projects, limits: [] });
H.renderHome();
const walk = (n, fn) => { if (!n || typeof n !== 'object') return; fn(n); (n.children || []).forEach((c) => walk(c, fn)); };
const textOf = (n) => { const s = []; walk(n, (x) => { if (x.text) s.push(x.text); }); return s.join(' '); };
const byCls = (root, cls) => { const r = []; walk(root, (x) => { if ((x.className || '').split(' ').includes(cls)) r.push(x); }); return r; };
const byId = (root, id) => { let r = null; walk(root, (x) => { if (x.id === id) r = x; }); return r; };
const tpRows = byCls(main, 'tprow');
const staleTile = byId(main, 'tile-s-stale');
const freshTile = byId(main, 'tile-s-fresh');
const qFold = byId(main, 'quiet-fold');
const qTiles = qFold ? byCls(qFold, 'ptile').map((x) => x.id).sort() : [];
const mainSections = main.children.filter((x) => x.tag === 'section' && !x.className.includes('toppri'));
const activeTiles = mainSections.length ? byCls(mainSections[0], 'ptile').map((x) => x.id).sort() : [];
// Also check hub-decide.js renders stale note on D1 and not on D2
const D = win.OSRC_HUB_DECIDE({ el: (t, c, x) => mk(t, c, x), ic: () => mk('i'), tags: () => mk('div'), flush() {}, db: {} });
const sp = projects.find((p) => p.id === 's-stale');
const dc1 = D.decCard(sp, sp.decisions.find((d) => d.id === 'D1'));
const dc2 = D.decCard(sp, sp.decisions.find((d) => d.id === 'D2'));
// Also check OSRC_HUB_CLEAN directly hides stale Next even if raw input still had it
const rawClean = win.OSRC_HUB_CLEAN.project({ id: 'r', name: '[ACK FIRST] prompt', folder: 'my_repo', next: 'Old next', reportedAt: new Date(Date.now() - 10 * 3600000).toISOString() });
// Updated stamps show the last session report time, never the export/activity stamp.
const fp = projects.find((p) => p.id === 's-fresh');
const host = mk('header', 'ph'); H.projFresh(sp, host);
const stEl = byCls(host, 'stamp-top')[0] || null, staleEl = byCls(host, 'pt-stale')[0] || null;
console.log(JSON.stringify({
  tpOrder: tpRows.map((r) => byCls(r, 'tpt')[0].text),
  tpStaleLines: tpRows.map((r) => (byCls(r, 'tp-stale')[0] || {}).text || ''),
  staleTileStaleLine: (byCls(staleTile, 'pt-stale')[0] || {}).text || '',
  staleTileHasNext: byCls(staleTile, 'pt-next').length,
  staleTileHasPsum: byCls(staleTile, 'psum').length,
  staleTileTextHas90Lanes: /90 lanes/.test(textOf(staleTile)),
  freshTileHasNext: byCls(freshTile, 'pt-next').length,
  freshTileHasStale: byCls(freshTile, 'pt-stale').length,
  activeTiles,
  qFoldCollapsed: qFold ? !qFold.open : false,
  qFoldSummary: qFold ? (qFold.children[0] || {}).text : '',
  qTiles,
  dc1Stale: (byCls(dc1, 'dec-stale')[0] || {}).text || '',
  dc2Stale: (byCls(dc2, 'dec-stale')[0] || {}).text || '',
  rawCleanName: rawClean.name,
  rawCleanHasNext: 'next' in rawClean,
  shipEta: [win.OSRC_HUB_CLEAN.shipEta('Ship target 17:00 today'), win.OSRC_HUB_CLEAN.shipEta('Ships Friday'), win.OSRC_HUB_CLEAN.shipEta('done'), win.OSRC_HUB_CLEAN.shipEta(''), win.OSRC_HUB_CLEAN.shipEta('target 18:00')],
  sessPick: win.OSRC_HUB_CLEAN.sessionStamp(sp) === Date.parse(sp.reportedAt),
  sessFallback: win.OSRC_HUB_CLEAN.sessionStamp({ updatedAt: sp.updatedAt }) === Date.parse(sp.updatedAt),
  sessNull: win.OSRC_HUB_CLEAN.sessionStamp({}) === null,
  stampAtReported: stEl ? Date.parse(stEl.dataset.at) === Date.parse(sp.reportedAt) : false,
  stampFirst: host.children[0] === stEl,
  stampTextUpdated: stEl ? /^Updated /.test(textOf(stEl)) : false,
  heroStale: staleEl ? staleEl.text : '',
  etaAsofStale: H.etaAsOf(sp),
  etaAsofFresh: H.etaAsOf(fp),
  etaAsofFreshEta: H.etaAsOf({ id: 'x', name: 'X', status: 'building', pct: 1, eta: 'Soon', reportedAt: new Date().toISOString() }),
}));
EOF
)"
  jq -e '.tpOrder == ["Fresh question","Old question"]
    and .tpStaleLines[0] == ""
    and (.tpStaleLines[1] | test("^Not re-confirmed for 1[23] h, may be out of date$"))' >/dev/null 2>&1 <<<"$n3r" \
    && ok "Home top-priority: fresh High decision sorts above stale Critical; stale shows 'Not re-confirmed for 13 h, may be out of date'" || bad "top-priority order/stale: $n3r"
  jq -e '(.staleTileStaleLine | test("^Last update from its session: 10 h ago$"))
    and .staleTileHasNext == 0 and .staleTileHasPsum == 0 and .staleTileTextHas90Lanes == false
    and .freshTileHasNext == 1 and .freshTileHasStale == 0' >/dev/null 2>&1 <<<"$n3r" \
    && ok "Home tile: stale card shows 'Last update from its session: 10 h ago', hides Next, and removes '90 lanes...' count; fresh card keeps Next" || bad "stale/fresh tile: $n3r"
  jq -e '.activeTiles == ["tile-s-fresh","tile-s-stale"] and .qFoldCollapsed == true and .qFoldSummary == "Quiet (3)" and .qTiles == ["tile-s-long","tile-s-prompt","tile-s-quiet"]' >/dev/null 2>&1 <<<"$n3r" \
    && ok "Home hides quiet projects in a collapsed 'Quiet (3)' fold (not deleted)" || bad "quiet fold: $n3r"
  jq -e '(.dc1Stale | test("^Not re-confirmed for 1[23] h, may be out of date$")) and .dc2Stale == "" and .rawCleanName == "My repo" and .rawCleanHasNext == false' >/dev/null 2>&1 <<<"$n3r" \
    && ok "hub-decide.js shows stale note on old decision only; OSRC_HUB_CLEAN cleans prompt title & strips stale Next" || bad "decide/clean: $n3r"
  jq -e '.shipEta == ["Ships target 17:00 today","Ships Friday","","","Ships target 18:00"]' >/dev/null 2>&1 <<<"$n3r" \
    && ok "shipEta never doubles the ship verb ('Ships Ship target…' -> 'Ships target…') and hides status-word etas" || bad "shipEta: $n3r"
  jq -e '.sessPick == true and .sessFallback == true and .sessNull == true' >/dev/null 2>&1 <<<"$n3r" \
    && ok "sessionStamp prefers reportedAt over fresher updatedAt (never export time); falls back to updatedAt; null when unknown" || bad "sessionStamp: $n3r"
  jq -e '.stampAtReported == true and .stampFirst == true and .stampTextUpdated == true and (.heroStale | test("^Last update from its session: 10 h ago$"))' >/dev/null 2>&1 <<<"$n3r" \
    && ok "project page 'Updated' chip shows session report time + stale hero line 'Last update from its session: 10 h ago'" || bad "projFresh: $n3r"
  jq -e '(.etaAsofStale | startswith("as of ")) and .etaAsofFresh == "" and .etaAsofFreshEta == ""' >/dev/null 2>&1 <<<"$n3r" \
    && ok "stale 'Release goes live' text marked 'as of <session time>'; fresh projects untouched" || bad "etaAsOf: $n3r"
  plr="$(node - "$LIB/hub-assets/hub-plans.js" <<'EOF' 2>&1
const fs = require('fs'), vm = require('vm');
const win = {};
vm.runInNewContext(fs.readFileSync(process.argv[2], 'utf8'), { window: win, setInterval: () => 0, clearInterval: () => {} });
const P = win.OSRC_HUB_PLANS;
const btn = { disabled: false, hidden: true, textContent: 'Refresh', dataset: {}, onclick: null };
let res; const refresh = () => new Promise((r) => { res = r; });
P.startChecks(btn, refresh);
const during = { state: btn.dataset.state, text: btn.textContent, hidden: btn.hidden };
res();
setTimeout(() => console.log(JSON.stringify({ during, after: { state: btn.dataset.state, text: btn.textContent, disabled: btn.disabled } })), 50);
EOF
)"
  jq -e '.during.state == "checking" and .during.text == "Checking…" and .after.state == "idle" and .after.text == "Check again" and .after.disabled == false' >/dev/null 2>&1 <<<"$plr" \
    && ok "hub-plans.js exposes dataset.state checking->idle so the plans stamp yields to one 'Checking…' state" || bad "plans state: $plr"
  grep -q "dataset.state === 'checking'" "$LIB/hub.html" \
    && ok "hub.html renderLimits suppresses the 'Checked …' stamp while a plans check runs" || bad "plans stamp suppression missing"
else echo "SKIP: node not installed"; fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
