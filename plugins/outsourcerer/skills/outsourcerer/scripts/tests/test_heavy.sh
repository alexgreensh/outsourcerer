#!/usr/bin/env bash
# test_heavy.sh — L10 add-on: osrc_heavy classification, osrc_mac_load, and the heavy-work gate
# inside _loop_check (cloud lane -> niced local -> stalled queue). OFFLINE ONLY: sysctl/uptime are
# PATH stubs reading OSRC_STUB_* env vars; cmd_cloud/_cloudrun_pick_vehicle are shadowed functions
# or PATH-stub CLIs; git runs against a LOCAL bare repo. No real load, network, or vehicle calls.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
if [ ! -f "$SRC" ]; then echo "FAIL: cannot find $SRC"; exit 1; fi

export OSRC_HOME="${TMPDIR:-/tmp}/osrc-test-L10h-home-$$"
mkdir -p "$OSRC_HOME"
export OSRC_CLOUD_ACK=1 OSRC_HEAVY_POLL=1 OSRC_HEAVY_LOCK_WAIT=5

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

# ---------- 1. osrc_heavy classification ----------
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
hv 0 "heavy: conformance"             "bash scripts/tests/conformance.sh"
hv 0 "heavy: test_factory"            "bash tests/test_factory_land.sh"
hv 0 "heavy: pytest bare"             "pytest"
hv 0 "heavy: pytest dir"              "pytest tests/"
hv 0 "heavy: pytest coverage"         "pytest --coverage"
hv 0 "heavy: npm test"                "npm test"
hv 0 "heavy: npm run build"           "npm run build"
hv 0 "heavy: cargo build"             "cargo build --release"
hv 0 "heavy: cargo test"              "cargo test"
hv 0 "heavy: npm install"             "npm install"
hv 0 "heavy: npm ci"                  "npm ci"
hv 0 "heavy: pip install"             "pip3 install -r requirements.txt"
hv 0 "heavy: make"                    "make"
hv 0 "heavy: make -j"                 "make -j8 all"
hv 0 "heavy: docker build"            "docker build -t x ."
hv 0 "heavy: xcodebuild"              "xcodebuild -scheme App build"
hv 0 "heavy: gradle"                  "./gradlew build"
hv 0 "heavy: benchmark"               "hyperfine 'ls -la'"
hv 0 "heavy: parallel suites"         "pytest tests/ & npm test"
hv 0 "heavy: est over 2min"           "deploy.sh # est 5m"
hv 0 "heavy: est hours"               "backup.sh # est: 2h"
hv 0 "heavy: marked slow"             "bash slow_job.sh # slow"
hv 0 "heavy: OSRC_SLOW=1"             "OSRC_SLOW=1 ./run.sh"
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

# ---------- 4. gate: cloud lane runs the check (shadowed vehicle + cmd_cloud) ----------
_cloudrun_pick_vehicle() { printf 'claude'; }
cmd_cloud() { # simulate the hosted agent: push cloud/<id> with RESULT+READY to origin
  echo "cmd_cloud $*" >> "$OSRC_STUB_LOG"
  local id="" base="main"
  while [ $# -gt 0 ]; do case "$1" in
    start) shift ;; --base) base="$2"; shift 2 ;; --repo|--brief|--vehicle|--where|--done-when|--env|--claude-env|--model) shift 2 ;;
    --*) shift ;; *) [ -z "$id" ] && id="$1"; shift ;; esac; done
  [ -n "$id" ] || return 1
  local box="$TMP/cloudbox-$id"
  git clone -q "$BARE" "$box" 2>/dev/null || return 1
  git -C "$box" checkout -qb "cloud/$id" "origin/$base" 2>/dev/null || git -C "$box" checkout -qb "cloud/$id" 2>/dev/null || return 1
  printf 'rc=0\ncloud check output: suite green\n' > "$box/$id.RESULT"
  printf 'READY %s\n' "$id" > "$box/$id.READY"
  git -C "$box" add -A >/dev/null 2>&1
  git -C "$box" -c user.email=t@t -c user.name=t commit -qm result >/dev/null 2>&1
  git -C "$box" push -q origin "cloud/$id" 2>/dev/null || return 1
  return 0
}
: > "$OSRC_STUB_LOG"
( cd "$WORK2" && _loop_check 30 "bash conformance.sh" "$TMP/cout" ); rc=$?
[ "$rc" = 0 ] && ok "gate: cloud lane rc propagates (rc=0)" || bad "gate: cloud lane rc=$rc"
grep -q 'cloud check output' "$TMP/cout" && ok "gate: RESULT written to check outfile" || bad "gate: outfile missing RESULT: $(cat "$TMP/cout" 2>/dev/null)"
grep -q 'cmd_cloud start heavy-' "$OSRC_STUB_LOG" && ok "gate: cloud start invoked with heavy- id" || bad "gate: no cloud start in stub log"
grep -q -- '--where cloud' "$OSRC_STUB_LOG" && ok "gate: launch forced --where cloud" || bad "gate: missing --where cloud"

# cloud lane reports failure -> rc propagates
cmd_cloud() {
  echo "cmd_cloud $*" >> "$OSRC_STUB_LOG"
  local id=""; while [ $# -gt 0 ]; do case "$1" in start) shift ;; --*) shift 2 ;; *) [ -z "$id" ] && id="$1"; shift ;; esac; done
  local box="$TMP/cloudbox-f$id"; git clone -q "$BARE" "$box" 2>/dev/null
  git -C "$box" checkout -qb "cloud/$id" "origin/main" 2>/dev/null
  printf 'rc=3\n3 tests failed\n' > "$box/$id.RESULT"; printf 'READY %s\n' "$id" > "$box/$id.READY"
  git -C "$box" add -A >/dev/null 2>&1; git -C "$box" -c user.email=t@t -c user.name=t commit -qm r >/dev/null 2>&1
  git -C "$box" push -q origin "cloud/$id" 2>/dev/null; return 0
}
( cd "$WORK2" && _loop_check 30 "npm test" "$TMP/cout2" ); rc=$?
[ "$rc" = 3 ] && ok "gate: cloud rc=3 propagates" || bad "gate: cloud rc=$rc want 3"

# ---------- 5. gate: cloud refused -> local niced, one at a time ----------
cmd_cloud() { echo "cmd_cloud $*" >> "$OSRC_STUB_LOG"; return 1; }   # preflight refusal
_cloudrun_pick_vehicle() { printf 'devin'; }
: > "$OSRC_STUB_LOG"
# heavy via `# heavy` marker but actually runnable (echo) so the fallback can execute it
( cd "$WORK2" && _loop_check 20 "echo fallback-ran # heavy" "$TMP/nout" ); rc=$?
[ "$rc" = 0 ] && grep -q fallback-ran "$TMP/nout" && ok "gate: refused cloud falls back to local run" || bad "gate: fallback rc=$rc out=$(cat "$TMP/nout" 2>/dev/null)"
grep -q 'nice -n 19' "$OSRC_STUB_LOG" && ok "gate: local heavy runs under nice -n 19" || bad "gate: no nice -n 19 in stub log: $(cat "$OSRC_STUB_LOG")"
[ ! -d "$OSRC_HOME/heavy-local.lock.d" ] && ok "gate: heavy lock released after run" || bad "gate: lock leaked"

# ---------- 6. gate: overloaded Mac -> queue + EVENT stalled, never runs ----------
_cloudrun_pick_vehicle() { return 1; }   # no vehicle usable
OSRC_STUB_NCPU=4 OSRC_STUB_LOAD1=9.00 OSRC_STUB_SWAP_USED=900.00   # 2.25/core, 90% swap
: > "$OSRC_STUB_LOG"; ERRF="$TMP/gate6.err"; : > "$ERRF"
# heavy via `# est 6m` marker; would print SHOULD-NOT-RUN if it ever executed locally
( cd "$WORK2" && _loop_check 20 "echo SHOULD-NOT-RUN # est 6m" "$TMP/sout" ) 2>"$ERRF"; rc=$?
[ "$rc" = 125 ] && ok "gate: stalled check rc=125" || bad "gate: stalled rc=$rc want 125"
grep -q 'EVENT stalled heavy-' "$ERRF" && ok "gate: EVENT stalled emitted" || bad "gate: no EVENT stalled: $(cat "$ERRF")"
grep -q 'NEXT ' "$ERRF" && grep -q 'cloud start' "$ERRF" && ok "gate: NEXT points to cloud option" || bad "gate: NEXT missing cloud start"
grep -q 'mac-overloaded' "$ERRF" && ok "gate: stall reason mac-overloaded" || bad "gate: wrong stall reason"
ls "$OSRC_HOME"/heavy-queue/heavy-*.cmd >/dev/null 2>&1 && ok "gate: check queued under heavy-queue/" || bad "gate: no queue file"
grep -q 'did NOT run locally' "$TMP/sout" && ok "gate: outfile records non-run" || bad "gate: outfile lacks stall note"
! grep -q SHOULD-NOT-RUN "$TMP/sout" && [ ! -s "$OSRC_STUB_LOG" ] \
  && ok "gate: stalled check never spawned locally" || bad "gate: stalled check ran anyway"

# ---------- 7. brief rule text ----------
_osrc_heavy_prompt | grep -qi 'unit tests' && _osrc_heavy_prompt | grep -qi 'cloud' \
  && ok "prompt: heavy rule mentions unit tests + cloud" || bad "prompt: heavy rule text"
grep -q '_osrc_heavy_prompt' "$SRC" && ok "brief: _build_prompt injects heavy rule" || bad "brief: _build_prompt missing _osrc_heavy_prompt"
grep -q 'Testing rule' "$SCRIPT_DIR/../factory-tasks.sh" && ok "brief: factory worker briefs carry rule" || bad "brief: factory-tasks missing rule"
grep -q 'Testing discipline' "$SCRIPT_DIR/../lib/cloudrun.sh" && ok "brief: cloud packs carry rule" || bad "brief: cloudrun pack missing rule"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
