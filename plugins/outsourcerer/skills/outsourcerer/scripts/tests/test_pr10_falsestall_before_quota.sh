#!/usr/bin/env bash
# PR #10 regression: a killed job whose out.log merely NARRATES "429" / "rate limit" in prose must
# NOT be misrouted to RETRY-DIFFERENT-LANE credit-exhausted. The quota scan runs before the false-
# stall check and _DEVIN_QUOTA_RE matches a BARE 402/429/rate-limit -- correct against a captured
# Devin stderr file, wrong against a free-prose out.log (a task ABOUT HTTP 429 handling). Fix: the
# post-hoc prose scan only counts a quota token when it sits beside a real refusal/error marker
# (_classify_quota_confirm), so provable work (false-stall) is never discarded over narration. We
# also prove the fix does NOT over-suppress: a GENUINE quota refusal is still routed to the lane.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "$PWD/.test-pr10.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# A non-git working dir so the meta.cwd fallback ($PWD when jq is absent) can never hit a real repo
# and count unrelated commits as the delegate's work.
cd "$TMP"
export OSRC_HOME="$TMP/state"
unset OSRC_CONTRACT_KEYS OSRC_CONTRACT_RE 2>/dev/null || true
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
set --; . "$SRC" >/dev/null 2>&1

JOBS="$OSRC_HOME/jobs"

# mkjob <id> <status> <lane> -- create a bare job dir; caller adds out.log/last.txt/work as needed.
mkjob() {
  local id="$1" st="$2" lane="$3" jd="$JOBS/$1" work="$TMP/work-$1"
  mkdir -p "$jd" "$work"
  printf '%s' "$st" > "$jd/status"
  printf '137' > "$jd/exit"
  printf '{"cwd":"%s","lane":"%s"}\n' "$work" "$lane" > "$jd/meta.json"
  printf '%s\n' "$work"
}

# ---- case 1: PRIMARY regression -- wedged job, prose "429"/"rate limit", REAL in-window write -----
# The exact worst case from the review: a wedged job that WROTE ratelimit.py on a 429-handling task.
# Old code: quota scan matches the bare 429 in prose -> credit-exhausted, work discarded.
# Fixed code: no refusal marker beside the token -> falls through to false-stall:writes -> REUSE.
w1="$(mkjob wedge-write wedged glm)"
cat > "$JOBS/wedge-write/out.log" <<'EOF'
Reading the task: implement HTTP 429 handling for the API client.
Added exponential backoff and a rate limit token bucket to ratelimit.py.
Wrote the new module and started wiring it into the request path.
EOF
: > "$JOBS/wedge-write/last.txt"
printf 'def backoff(): pass\n' > "$w1/ratelimit.py"
# mtimes: .startmark (oldest) < work file (in-window) <= exit (newest) so the bounded FS scan counts it.
touch -t 202608060000 "$JOBS/wedge-write/.startmark"
touch -t 202608060001 "$w1/ratelimit.py"
touch -t 202608060002 "$JOBS/wedge-write/exit"
v1="$(_classify_job wedge-write)"
case "$v1" in
  RETRY-DIFFERENT-LANE*) bad "case1 MISROUTED to lane-block on prose 429 (got: $v1)" ;;
  "REUSE-OUTPUT	false-stall:writes") ok "case1 prose-429 + real write -> REUSE-OUTPUT false-stall:writes" ;;
  REUSE-OUTPUT*) ok "case1 prose-429 + real write -> REUSE-OUTPUT (got: $v1)" ;;
  *) bad "case1 unexpected verdict: $v1" ;;
esac

# ---- case 2: prose "429" with NO work -> REAL-FAIL, still NOT credit-exhausted --------------------
# Proves the fix is universal (a reorder-only fix would still misroute this: no work to win over the
# prose signal). No .startmark, empty last.txt -> false-stall skipped -> REAL-FAIL watchdog:wedged.
mkjob wedge-nowork wedged glm >/dev/null
cat > "$JOBS/wedge-nowork/out.log" <<'EOF'
Investigating the endpoint that returns 429 under load.
Notes on the rate limit behaviour, but produced no files before being killed.
EOF
: > "$JOBS/wedge-nowork/last.txt"
rm -f "$JOBS/wedge-nowork/.startmark"
v2="$(_classify_job wedge-nowork)"
case "$v2" in
  RETRY-DIFFERENT-LANE*) bad "case2 prose 429 with no work MISROUTED to lane-block (got: $v2)" ;;
  "REAL-FAIL	watchdog:wedged") ok "case2 prose-429 + no work -> REAL-FAIL watchdog:wedged" ;;
  *) bad "case2 unexpected verdict: $v2" ;;
esac

# ---- case 3: GENUINE quota refusal is STILL detected (no over-suppression), devin lane -----------
mkjob wedge-devin wedged devin >/dev/null
cat > "$JOBS/wedge-devin/out.log" <<'EOF'
Starting the task.
Error: 429 Too Many Requests -- rate limit exceeded; quota exhausted, upgrade your plan.
EOF
: > "$JOBS/wedge-devin/last.txt"
rm -f "$JOBS/wedge-devin/.startmark"
v3="$(_classify_job wedge-devin)"
[ "$v3" = "RETRY-DIFFERENT-LANE	quota-exhausted" ] \
  && ok "case3 genuine 429 refusal on devin -> RETRY-DIFFERENT-LANE quota-exhausted" \
  || bad "case3 genuine refusal not routed to lane-block (got: $v3)"

# ---- case 4: GENUINE quota refusal on a non-devin lane -> credit-exhausted (path still reachable) -
mkjob wedge-credit wedged glm >/dev/null
cat > "$JOBS/wedge-credit/out.log" <<'EOF'
Working on it.
FATAL: insufficient credits remaining -- payment required to continue.
EOF
: > "$JOBS/wedge-credit/last.txt"
rm -f "$JOBS/wedge-credit/.startmark"
v4="$(_classify_job wedge-credit)"
[ "$v4" = "RETRY-DIFFERENT-LANE	credit-exhausted" ] \
  && ok "case4 genuine credit refusal on glm -> RETRY-DIFFERENT-LANE credit-exhausted" \
  || bad "case4 genuine credit refusal not routed to lane-block (got: $v4)"

# ---- case 5: the confirm gate is wired at the classify choke point (source cross-check) -----------
grep -q '_classify_quota_confirm' "$SRC" \
  && ok "false-stall-before-quota fix present: _classify_quota_confirm gates the prose scan" \
  || bad "_classify_quota_confirm not wired into classify"

# ---- case 6: REORDER — a REAL deliverable wins over quota-prose even when the out.log carries a ----
# GENUINE quota refusal signature. This is the torture repro the PR#10 confirm-gate did NOT fix: the
# out.log here WOULD classify as quota (bare 429 beside a refusal marker), but last.txt is a usable
# deliverable that also happens to narrate "429 Too Many Requests". Because the false-stall/deliverable
# block now runs BEFORE the quota block, the committed/written/non-refusal work is REUSE-OUTPUT, never
# discarded to RETRY-DIFFERENT-LANE. A reorder-only fix is required; the confirm gate alone cannot see
# this (the out.log token DOES sit beside a refusal marker).
w6="$(mkjob deliverable-wins wedged devin)"
cat > "$JOBS/deliverable-wins/last.txt" <<'EOF'
# Rate limiter module (delivered)

Implemented a token-bucket limiter that handles the API's "429 Too Many Requests"
responses with exponential backoff and Retry-After parsing. Working code:

    def handle_429(resp):
        wait = int(resp.headers.get("Retry-After", "1"))
        time.sleep(wait); return retry()

Verified against 429 Too Many Requests; recovers cleanly.
EOF
cat > "$JOBS/deliverable-wins/out.log" <<'EOF'
Working the task.
Error: 429 Too Many Requests -- rate limit exceeded; quota exhausted, upgrade your plan.
EOF
rm -f "$JOBS/deliverable-wins/.startmark"   # no in-window writes/commits -> deliverable signal decides
v6="$(_classify_job deliverable-wins)"
case "$v6" in
  RETRY-DIFFERENT-LANE*) bad "case6 REORDER FAILED: real deliverable discarded to lane-block over quota-prose (got: $v6)" ;;
  REUSE-OUTPUT*)         ok "case6 real deliverable containing '429 Too Many Requests' -> REUSE-OUTPUT (reorder: work wins over quota-prose)" ;;
  *)                     bad "case6 unexpected verdict: $v6" ;;
esac
# Source cross-check: the false-stall/deliverable block must physically precede the quota block.
_fs_line="$(grep -n 'false-stall:deliverable' "$SRC" | head -1 | cut -d: -f1)"
_qz_line="$(grep -n 'if \[ -n "\$_quota_hit" \]' "$SRC" | head -1 | cut -d: -f1)"
{ [ -n "$_fs_line" ] && [ -n "$_qz_line" ] && [ "$_fs_line" -lt "$_qz_line" ]; } \
  && ok "source order: deliverable block precedes the quota block (line $_fs_line < $_qz_line)" \
  || bad "source order wrong: deliverable=$_fs_line quota=$_qz_line (deliverable must come first)"

echo "----"
echo "pr10-falsestall-before-quota: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
