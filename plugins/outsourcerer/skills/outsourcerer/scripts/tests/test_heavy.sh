#!/usr/bin/env bash
# test_heavy.sh — L10 add-on round 2: osrc_heavy command-word classification, osrc_mac_load,
# and the heavy-work gate inside _loop_check. Round-2 contract: the gate NEVER launches — it
# emits EVENT approval + NEXT (exact `cloud start` line) only for a clean, pushed tree, reuses
# an in-flight lane for identical check+sha, queues+stalls on an overloaded Mac, else runs
# niced one at a time. rc 125 always means NOT RUN. OFFLINE ONLY: sysctl/uptime are PATH stubs
# reading OSRC_STUB_* env vars; git runs against a LOCAL bare repo; no vehicle is ever launched.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
if [ ! -f "$SRC" ]; then echo "FAIL: cannot find $SRC"; exit 1; fi

export OSRC_HOME="${TMPDIR:-/tmp}/osrc-test-L10h-home-$$"
mkdir -p "$OSRC_HOME"
export OSRC_HEAVY_LOCK_WAIT=5

. "$SRC" >/dev/null 2>&1
SCRIPT_PATH="$SRC"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"
export OSRC_STUB_LOG="$TMP/stub.log"; : > "$OSRC_STUB_LOG"
cleanup() { rm -rf "$TMP" "$OSRC_HOME"; }
trap cleanup EXIT

# ---------- stubs: sysctl / uptime / nice (env-driven, zero real load) ----------
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/sysctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *hw.ncpu*|*hw.logicalcpu*) echo "${OSRC_STUB_NCPU:-8}" ;;
  *vm.swapusage*) printf 'total = %sM  used = %sM  free = %sM  (encrypted)\n' \
      "${OSRC_STUB_SWAP_TOTAL:-1000.00}" "${OSRC_STUB_SWAP_USED:-400.00}" "${OSRC_STUB_SWAP_FREE:-600.00}" ;;
  *) echo "" ;;
esac
EOF
cat > "$STUB/uptime" <<'EOF'
#!/usr/bin/env bash
echo "14:00  up 1 day,  2:00, 1 user, load averages: ${OSRC_STUB_LOAD1:-4.00} ${OSRC_STUB_LOAD5:-3.00} ${OSRC_STUB_LOAD15:-2.00}"
EOF
cat > "$STUB/nice" <<'EOF'
#!/usr/bin/env bash
{ echo "=== nice"; echo "nice $*"; } >> "$OSRC_STUB_LOG"
[ "${1:-}" = "-n" ] && shift 2
exec "$@"
EOF
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

# normal load: 8 cores, load1 8.0 -> 1.0/core, swap 40%
export OSRC_STUB_NCPU=8 OSRC_STUB_LOAD1=8.00 OSRC_STUB_SWAP_TOTAL=1000.00 OSRC_STUB_SWAP_USED=400.00

# ---------- git fixtures: bare "remote" + a check working clone ----------
BARE="$TMP/origin.git"; WORK2="$TMP/checkwd"
git init --bare "$BARE" >/dev/null 2>&1
git init "$WORK2" >/dev/null 2>&1
git -C "$WORK2" config user.email t@t; git -C "$WORK2" config user.name t
printf 'x\n' > "$WORK2/f.txt"; git -C "$WORK2" add -A; git -C "$WORK2" commit -qm init
git -C "$WORK2" branch -M main
git -C "$WORK2" remote add origin "$BARE"
git -C "$WORK2" push -qu origin main

# ---------- 1. osrc_heavy classification: command WORDS, not substrings ----------
hv() { # <want-rc> <desc> <cmd>
  osrc_heavy "$3" 2>/dev/null; local rc=$?
  [ "$rc" = "$1" ] && ok "heavy: $2" || bad "heavy: $2 (rc=$rc want $1)"
}
hv 1 "light: ls"                      "ls -la"
hv 1 "light: git status"              "git status"
hv 1 "light: unit pytest file"        "pytest tests/test_foo.py"
hv 1 "light: pytest file in tests/"   "pytest tests/test_foo.py -x"
hv 1 "light: jest single file"        "jest src/foo.test.js"
hv 1 "light: est under 2min"          "deploy.sh # est 1m"
# --- the verdict's four false positives, verbatim ---
hv 1 "light: make lint (was wrongly heavy)"   "make lint"
hv 1 "light: bare make (dropped rule)"        "make"
hv 1 "light: npx tsc (dropped rule)"          "npx tsc --noEmit"
hv 1 "light: grep word make (substring)"      "grep -q make README.md"
hv 1 "light: ls & wait (& not a signal)"      "ls & wait"
# --- things that must STAY heavy ---
hv 0 "heavy: conformance"             "bash scripts/tests/conformance.sh"
hv 0 "heavy: test_factory"            "bash tests/test_factory_land.sh"
hv 0 "heavy: pytest bare"             "pytest"
hv 0 "heavy: pytest dir"              "pytest tests/"
hv 0 "heavy: pytest coverage"         "pytest --coverage"
hv 0 "heavy: pytest xdist -n"         "pytest -n 4 tests/"
hv 0 "heavy: npm test"                "npm test"
hv 0 "heavy: npm run build"           "npm run build"
hv 0 "heavy: npm ci"                  "npm ci"
hv 0 "heavy: cargo build"             "cargo build --release"
hv 0 "heavy: cargo test"              "cargo test"
hv 0 "heavy: npm install"             "npm install"
hv 0 "heavy: pip install"             "pip3 install -r requirements.txt"
hv 0 "heavy: make test"               "make test"
hv 0 "heavy: make -j"                 "make -j8 all"
hv 0 "heavy: docker build"            "docker build -t x ."
hv 0 "heavy: xcodebuild"              "xcodebuild -scheme App build"
hv 0 "heavy: gradle"                  "./gradlew build"
hv 0 "heavy: benchmark"               "hyperfine 'ls -la'"
hv 0 "heavy: two suites && "          "pytest tests/ && npm test"
hv 0 "heavy: est over 2min"           "deploy.sh # est 5m"
hv 0 "heavy: est hours"               "backup.sh # est: 2h"
hv 0 "heavy: marked slow"             "bash slow_job.sh # slow"
hv 0 "heavy: OSRC_SLOW=1"             "OSRC_SLOW=1 ./run.sh"
hv 1 "light: docker ps"               "docker ps"
hv 1 "light: npm exec"                "npm exec tsc --noEmit"
hv 1 "light: pip list"                "pip list"
hv 1 "light: git log | head"          "git log --oneline | head -5"
OSRC_HEAVY=1; osrc_heavy "ls" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && ok "heavy: OSRC_HEAVY=1 forces" || bad "heavy: OSRC_HEAVY=1 (rc=$rc)"
OSRC_HEAVY=0; osrc_heavy "cargo build" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && ok "heavy: OSRC_HEAVY=0 forces light" || bad "heavy: OSRC_HEAVY=0 (rc=$rc)"
unset OSRC_HEAVY

# ---------- 2. osrc_mac_load + overload thresholds (stubbed sysctl/uptime) ----------
ml="$(osrc_mac_load)"
case "$ml" in *load_per_core=1.00*swap_pct=40*) ok "mac_load parses load/core + swap" ;; *) bad "mac_load parse: $ml" ;; esac
_osrc_mac_overloaded; rc=$?
[ "$rc" = 1 ] && ok "mac_load: normal load not overloaded" || bad "mac_load: false overload"
OSRC_STUB_LOAD1=24.00; _osrc_mac_overloaded; rc=$?   # 24/8 = 3.0/core > 2
[ "$rc" = 0 ] && ok "mac_load: load/core > 2 overloads" || bad "mac_load: load overload missed"
OSRC_STUB_LOAD1=8.00; OSRC_STUB_SWAP_USED=850.00; _osrc_mac_overloaded; rc=$?  # swap 85% > 80
[ "$rc" = 0 ] && ok "mac_load: swap > 80% overloads" || bad "mac_load: swap overload missed"
OSRC_STUB_LOAD1=15.99; OSRC_STUB_SWAP_USED=800.00; _osrc_mac_overloaded; rc=$? # 2.0/core, 80%: not OVER
[ "$rc" = 1 ] && ok "mac_load: boundary values not overloaded" || bad "mac_load: boundary false overload"
OSRC_STUB_LOAD1=8.00; OSRC_STUB_SWAP_USED=400.00

# ---------- 3. gate: light check bypasses everything ----------
: > "$OSRC_STUB_LOG"
( cd "$WORK2" && _loop_check 15 "echo light-ok" "$TMP/lout" ); rc=$?
[ "$rc" = 0 ] && grep -q light-ok "$TMP/lout" && ok "gate: light check runs normally" || bad "gate: light check rc=$rc"
[ ! -s "$OSRC_STUB_LOG" ] && ok "gate: light check spawns no cloud/nice" || bad "gate: light check touched stubs"

# ---------- 4. gate: clean+pushed tree -> EVENT approval + NEXT, NEVER launches ----------
# cmd_cloud is shadowed with a tripwire: the gate must never invoke it.
cmd_cloud() { echo "cmd_cloud LAUNCHED: $*" >> "$OSRC_STUB_LOG"; return 99; }
_cloudrun_pick_vehicle() { printf 'claude'; }
SHA2="$(git -C "$WORK2" rev-parse HEAD)"
ID2="$(_osrc_heavy_lane_id "bash conformance.sh" "$SHA2")"
: > "$OSRC_STUB_LOG"
ERRF="$TMP/gate4.err"; : > "$ERRF"
( cd "$WORK2" && _loop_check 30 "bash conformance.sh" "$TMP/cout" ) 2>"$ERRF"; rc=$?
[ "$rc" = 125 ] && ok "gate: approval-offer check rc=125 (not run)" || bad "gate: offer rc=$rc want 125"
grep -q "EVENT approval $ID2" "$ERRF" && ok "gate: EVENT approval <id> emitted" || bad "gate: no EVENT approval: $(cat "$ERRF")"
grep -q 'NEXT ' "$ERRF" && grep -q "cloud start $ID2" "$ERRF" && grep -q -- '--repo' "$ERRF" \
  && ok "gate: NEXT carries exact cloud start line" || bad "gate: NEXT missing cloud start: $(cat "$ERRF")"
grep -q 'NOT RUN' "$TMP/cout" && ok "gate: outfile says NOT RUN" || bad "gate: outfile lacks NOT RUN: $(cat "$TMP/cout")"
[ ! -s "$OSRC_STUB_LOG" ] && ok "gate: NEVER launched a vehicle (cmd_cloud untouched)" || bad "gate: launched anyway: $(cat "$OSRC_STUB_LOG")"
BRIEF2="$(ls "$OSRC_HOME"/cloud/"$ID2".brief.md 2>/dev/null)"
[ -n "$BRIEF2" ] && grep -q "Pinned commit: $SHA2" "$BRIEF2" && grep -q "sha=$SHA2" "$BRIEF2" \
  && ok "gate: brief pins the exact sha + RESULT contract" || bad "gate: brief missing sha pin: $BRIEF2"
grep -q '"kind":"approval"' "$OSRC_HOME/lanes/events.jsonl" 2>/dev/null \
  && ok "gate: EVENT approval landed in lanes/events.jsonl" || bad "gate: events.jsonl missing approval"

# identical check+sha -> dedupe: pre-register the lane, expect 'already delegated', no 2nd offer
mkdir -p "$OSRC_HOME/remote"
printf '{"id":"%s","status":"running"}\n' "$ID2" > "$OSRC_HOME/remote/$ID2.json"
: > "$OSRC_STUB_LOG"; : > "$ERRF"
( cd "$WORK2" && _loop_check 30 "bash conformance.sh" "$TMP/cout3" ) 2>"$ERRF"; rc=$?
[ "$rc" = 125 ] && ok "gate: dedupe rc=125" || bad "gate: dedupe rc=$rc want 125"
grep -q 'already delegated' "$ERRF" && ok "gate: identical check+sha reuses in-flight lane" || bad "gate: no dedupe: $(cat "$ERRF")"
! grep -q 'EVENT approval' "$ERRF" && ok "gate: dedupe does not re-ask approval" || bad "gate: dedupe re-emitted approval"
rm -f "$OSRC_HOME/remote/$ID2.json"

# ---------- 5. gate: dirty or unpushed tree -> NO cloud offer, local rules apply ----------
# dirty tree: untracked file present -> no offer; heavy check runs niced
printf 'dirty\n' > "$WORK2/untracked.tmp"
: > "$OSRC_STUB_LOG"; : > "$ERRF"
( cd "$WORK2" && _loop_check 20 "echo dirty-fallback-ran # heavy" "$TMP/dout" ) 2>"$ERRF"; rc=$?
[ "$rc" = 0 ] && grep -q dirty-fallback-ran "$TMP/dout" && ok "gate: dirty tree falls back to local run" || bad "gate: dirty rc=$rc"
! grep -q 'EVENT approval' "$ERRF" && ok "gate: dirty tree gets NO cloud offer" || bad "gate: dirty tree offered cloud"
grep -q 'nice -n 19' "$OSRC_STUB_LOG" && ok "gate: dirty-tree heavy runs under nice -n 19" || bad "gate: dirty run not niced"
rm -f "$WORK2/untracked.tmp"

# unpushed commit -> no offer either
git -C "$WORK2" -c user.email=t@t -c user.name=t commit -qm wip --allow-empty
printf 'wip\n' > "$WORK2/wip.txt"; git -C "$WORK2" add wip.txt; git -C "$WORK2" -c user.email=t@t -c user.name=t commit -qm wip2
: > "$OSRC_STUB_LOG"; : > "$ERRF"
( cd "$WORK2" && _loop_check 20 "echo unpushed-fallback # heavy" "$TMP/uout" ) 2>"$ERRF"; rc=$?
[ "$rc" = 0 ] && grep -q unpushed-fallback "$TMP/uout" && ok "gate: unpushed tree falls back to local run" || bad "gate: unpushed rc=$rc"
! grep -q 'EVENT approval' "$ERRF" && ok "gate: unpushed tree gets NO cloud offer" || bad "gate: unpushed tree offered cloud"
# restore: push the wip commits so later sections see a clean pushed tree
git -C "$WORK2" push -q origin main

# ---------- 6. gate: token-bearing origin URL never reaches brief/pack/NEXT ----------
ORIG_URL="$(git -C "$WORK2" remote get-url origin)"
git -C "$WORK2" remote set-url origin "https://x-access-token:SECRETTOKEN123@127.0.0.1:9/x.git"
: > "$OSRC_STUB_LOG"; : > "$ERRF"
SHA3="$(git -C "$WORK2" rev-parse HEAD)"
ID3="$(_osrc_heavy_lane_id "npm test" "$SHA3")"
( cd "$WORK2" && _loop_check 30 "npm test" "$TMP/tout" ) 2>"$ERRF"; rc=$?
[ "$rc" = 125 ] && grep -q "EVENT approval $ID3" "$ERRF" && ok "gate: token origin still offers (clean+pushed)" || bad "gate: token-origin offer rc=$rc: $(cat "$ERRF")"
if grep -rl 'SECRETTOKEN123\|x-access-token' "$OSRC_HOME" "$TMP/tout" "$ERRF" 2>/dev/null | grep -q .; then
  bad "gate: credential leaked into state/output: $(grep -rl 'SECRETTOKEN123\|x-access-token' "$OSRC_HOME" "$TMP" 2>/dev/null | head -3)"
else
  ok "gate: user:pass@ stripped everywhere (brief, NEXT, events, queue)"
fi
git -C "$WORK2" remote set-url origin "$ORIG_URL"

# ---------- 7. gate: overloaded Mac -> queue + EVENT stalled, never runs ----------
_cloudrun_pick_vehicle() { return 1; }   # no vehicle usable
OSRC_STUB_NCPU=4 OSRC_STUB_LOAD1=9.00 OSRC_STUB_SWAP_USED=900.00   # 2.25/core, 90% swap
: > "$OSRC_STUB_LOG"; : > "$ERRF"
# heavy via `# est 6m` marker; would print SHOULD-NOT-RUN if it ever executed locally
( cd "$WORK2" && _loop_check 20 "echo SHOULD-NOT-RUN # est 6m" "$TMP/sout" ) 2>"$ERRF"; rc=$?
[ "$rc" = 125 ] && ok "gate: stalled check rc=125 (not run)" || bad "gate: stalled rc=$rc want 125"
grep -q 'EVENT stalled heavy-' "$ERRF" && ok "gate: EVENT stalled emitted" || bad "gate: no EVENT stalled: $(cat "$ERRF")"
grep -q 'NEXT ' "$ERRF" && grep -q 'cloud start' "$ERRF" && ok "gate: NEXT points to cloud option" || bad "gate: NEXT missing cloud start"
grep -q 'mac-overloaded' "$ERRF" && ok "gate: stall reason mac-overloaded" || bad "gate: wrong stall reason"
ls "$OSRC_HOME"/heavy-queue/heavy-*.cmd >/dev/null 2>&1 && ok "gate: check queued under heavy-queue/" || bad "gate: no queue file"
grep -q '"kind":"stalled"' "$OSRC_HOME/lanes/events.jsonl" 2>/dev/null \
  && ok "gate: EVENT stalled landed in lanes/events.jsonl" || bad "gate: events.jsonl missing stalled"
grep -q 'did NOT run locally' "$TMP/sout" && ok "gate: outfile records non-run" || bad "gate: outfile lacks stall note"
! grep -q SHOULD-NOT-RUN "$TMP/sout" && [ ! -s "$OSRC_STUB_LOG" ] \
  && ok "gate: stalled check never spawned locally" || bad "gate: stalled check ran anyway"
OSRC_STUB_NCPU=8 OSRC_STUB_LOAD1=8.00 OSRC_STUB_SWAP_USED=400.00

# ---------- 8. loop semantics: rc 125 stops the loop, never iterates ----------
grep -q 'crc" -eq 125' "$SRC" && ok "loop: verify handles rc=125 as not-run" || bad "loop: verify missing 125 handler"
grep -q 'NOT RUN' "$SCRIPT_DIR/../lib/heavy.sh" && ok "loop: verify reports NOT RUN" || bad "loop: verify lacks NOT RUN message"
grep -q '"notrun"' "$SRC" && ok "loop: escalate receipts record notrun" || bad "loop: escalate missing notrun"

# ---------- 9. brief rule text ----------
_osrc_heavy_prompt | grep -qi 'unit tests' && _osrc_heavy_prompt | grep -qi 'cloud' \
  && ok "prompt: heavy rule mentions unit tests + cloud" || bad "prompt: heavy rule text"
grep -q '_osrc_heavy_prompt' "$SRC" && ok "brief: _build_prompt injects heavy rule" || bad "brief: _build_prompt missing _osrc_heavy_prompt"
grep -q 'Testing rule' "$SCRIPT_DIR/../factory-tasks.sh" && ok "brief: factory worker briefs carry rule" || bad "brief: factory-tasks missing rule"
grep -q 'Testing discipline' "$SCRIPT_DIR/../lib/cloudrun.sh" && ok "brief: cloud packs carry rule" || bad "brief: cloudrun pack missing rule"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
