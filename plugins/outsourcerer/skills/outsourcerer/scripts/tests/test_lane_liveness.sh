#!/usr/bin/env bash
# test_lane_liveness.sh — "installed" must never be reported as "will answer".
#
# A lane stays installed and authenticated while its subscription window is exhausted, its token has
# expired, or its backend has stopped answering. Reporting that lane as ready is how work gets routed
# somewhere that cannot take it — the same failure the gemini/agy probe was built for, still open on
# the three lanes people actually use most: codex-native, claude-native, and devin (whose `logged_in`
# is a login-FILE check that sends no request at all).
#
# Two properties are load-bearing and both are tested here:
#   1. A lane that does not answer is reported as NOT ANSWERING, never READY, and the probe is BOUNDED
#      (a dead lane must cost seconds; an unbounded probe hangs `doctor` itself).
#   2. The timeout knob is a BARE number of seconds. agy's OSRC_DOCTOR_PROBE_TIMEOUT carries an 's'
#      suffix for agy's own --print-timeout flag; feeding that to _timeout would break the probe, so
#      the two knobs must stay distinct.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

. "$SRC" >/dev/null 2>&1
type -t _timeout >/dev/null || { echo "FAIL: _timeout not loaded"; exit 1; }

# --- behavioural: a lane that hangs must be bounded and classified -------------------------------
# Use a stub lane that spawns a GRANDCHILD, because that is the case that actually broke: killing only
# the direct child leaves the grandchild holding the inherited stdout, and the `$( )` capture below
# stays blocked long after the bound fired. so a "bounded" probe can still block far past its limit.
# This must exercise the REAL _timeout from the script — a local copy of the logic would happily keep
# passing while the shipped function stayed broken.
dead_lane() { sh -c 'sleep 300' ; }

probe_classify() {   # mirrors the doctor() probe branch structure
  local _ppt _prc=0
  _ppt="$(_timeout 2 dead_lane 2>&1)" || _prc=$?
  if [ "$_prc" -eq 0 ] && printf '%s' "$_ppt" | grep -qi 'pong'; then
    echo "READY (probed just now, answered)"
  else
    case "$_ppt" in
      *[Aa]uth*|*401*|*403*|*[Uu]nauthor*) echo "INSTALLED BUT NOT ANSWERING — auth rejected." ;;
      *429*|*[Rr]ate*|*[Ll]imit*|*[Qq]uota*|*[Ee]xhaust*) echo "INSTALLED BUT NOT ANSWERING — plan window exhausted." ;;
      *) echo "INSTALLED BUT NOT ANSWERING (rc=$_prc) — a real request did not come back." ;;
    esac
  fi
}

t0=$(date +%s); out="$(probe_classify)"; el=$(( $(date +%s) - t0 ))

case "$out" in
  *"INSTALLED BUT NOT ANSWERING"*) ok "a lane that never answers is reported as NOT ANSWERING" ;;
  *) bad "a dead lane was not reported as NOT ANSWERING (got: $out)" ;;
esac
case "$out" in
  *READY*) bad "a dead lane produced a READY line" ;;
  *) ok "a dead lane never produces a READY line" ;;
esac
[ "$el" -lt 20 ] \
  && ok "the probe is bounded (${el}s) so a dead lane cannot hang doctor" \
  || bad "the probe ran unbounded (${el}s)"

# --- source-level: the three lanes must actually be probed, and honestly labelled ----------------
for lane in 'codex-native luna' 'claude-native haiku' 'devin liveness'; do
  grep -q "$lane: READY" "$SRC" && grep -q "$lane: INSTALLED BUT NOT ANSWERING" "$SRC" \
    && ok "$lane distinguishes READY from INSTALLED BUT NOT ANSWERING" \
    || bad "$lane has no real liveness classification"
done

grep -q 'NOT probed for liveness' "$SRC" \
  && ok "the unprobed lane lines say so instead of implying readiness" \
  || bad "lanes are still described as ready from binary existence alone"

# The devin probe must send a REAL request rather than re-reading the login file.
grep -q 'devin --model glm-5.2 --permission-mode auto -p "reply PONG"' "$SRC" \
  && ok "the devin lane is probed with a real bounded request" \
  || bad "the devin lane still reports readiness from a login-file check only"

# devin has no 'plan' permission mode (auto|accept-edits|smart|dangerous). An invalid flag would make
# a HEALTHY lane report as dead — a false alarm is its own bug.
grep -q 'permission-mode plan' "$SRC" \
  && bad "the devin probe uses a permission mode devin does not accept" \
  || ok "the devin probe uses a permission mode devin actually accepts"

# The two timeout knobs must not be conflated.
grep -q 'OSRC_DOCTOR_PING_TIMEOUT' "$SRC" \
  && ok "the ping probe has its own bare-seconds timeout knob" \
  || bad "no timeout knob for the native-lane probe"
awk '/_timeout "\$\{OSRC_DOCTOR_PROBE_TIMEOUT/{found=1} END{exit !found}' "$SRC" \
  && bad "agy's suffixed timeout var is being passed to _timeout (it would be rejected)" \
  || ok "agy's suffixed timeout var is never passed to _timeout"

# --- the launch banner must not assert a lane it cannot know -------------------------------------
# `-m terra` resolves to codex-native even when the default provider is devin, and that decision is
# made in the detached child AFTER the launch line prints. Reporting "provider=devin" for a job that
# ran on codex-native is the tool misreporting its own routing.
grep -q 'launched (provider=\$PROVIDER)' "$SRC" \
  && bad "the launch banner still states the default provider as if it were the resolved lane" \
  || ok "the launch banner does not claim a lane it cannot know yet"
grep -q 'default lane: \$PROVIDER' "$SRC" \
  && ok "the launch banner labels the provider as a default and points at the real record" \
  || bad "the launch banner gives no pointer to the lane actually used"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
