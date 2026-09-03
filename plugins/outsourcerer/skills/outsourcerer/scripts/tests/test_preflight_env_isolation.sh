#!/usr/bin/env bash
# test_preflight_env_isolation.sh — an INHERITED OSRC_PREFLIGHT env var can never turn a real run into
# a silent no-op; preflight is signaled only by our own private argv sentinel.
#
# Root cause guarded (torture-room security finding): OSRC_PREFLIGHT gates a dispatch-suppressing early
# return that fires BEFORE the cloud/secret gate and before dispatch. Read as ${OSRC_PREFLIGHT:-0} and
# never reset, an inherited `OSRC_PREFLIGHT=1` (dotfiles, direnv, CI, a wrapper) silently turned every
# real top-level run into a fake-success no-op that skipped the credential hard-block and reported exit
# 0 having done nothing — the same inherited-env-defeats-a-gate class already closed for OSRC_CLOUD_ACKED.
# The fix: main() unsets any inherited OSRC_PREFLIGHT and honors ONLY the internal `--osrc-preflight-internal`
# argv sentinel (argv does not leak through the environment); the bg/fanout preflight re-exec passes it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "$PWD/.test-pfenv.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"; export HOME="$TMP/home"
mkdir -p "$OSRC_HOME" "$HOME"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# 1. THE vuln: an inherited env OSRC_PREFLIGHT=1 must NOT make a real run a silent exit-0 no-op. After
#    the fix the run engages the pipeline (reaches the cloud disclosure / a dispatch attempt), so its
#    output is non-empty; before the fix it printed nothing and returned 0.
out="$(OSRC_PREFLIGHT=1 bash "$SRC" --cloud-ack run -m glm-5.2 "echo hi" 2>&1)"; rc=$?
if [ -z "$out" ] && [ "$rc" = "0" ]; then
  bad "inherited OSRC_PREFLIGHT=1 still produced a silent exit-0 no-op (the vuln is present)"
else
  ok "inherited OSRC_PREFLIGHT=1 no longer silently no-ops a real run (rc=$rc, output present)"
fi
# stronger: it actually reached the cloud disclosure / dispatch layer, not an early no-op return.
printf '%s' "$out" | grep -qiE 'cloud disclosure|delegat|devin|lane' \
  && ok "the run reached the dispatch/cloud-gate layer despite the inherited env var" \
  || bad "the run did not reach the dispatch layer (may still be short-circuiting)"

# 2. The legitimate internal sentinel STILL triggers preflight (a dry, no-dispatch check that returns 0),
#    so the security fix did not break the mechanism bg/fanout depend on.
rc=0; ( bash "$SRC" --osrc-preflight-internal --cloud-ack run -m glm-5.2 "echo hi" ) >/dev/null 2>&1 || rc=$?
[ "$rc" = "0" ] && ok "the internal --osrc-preflight-internal sentinel still preflights cleanly (rc=0)" \
  || bad "the internal preflight sentinel is broken (rc=$rc) — bg/fanout launches would refuse"

# 3. End-to-end: a real bg launch (which uses the preflight internally) still succeeds.
outb="$(bash "$SRC" --cloud-ack bg run -m glm-5.2 "echo hi" 2>&1)"
printf '%s' "$outb" | grep -qi 'launched' \
  && ok "bg launch still passes its route preflight and starts the job" \
  || bad "bg launch broke: $(printf '%s' "$outb" | tail -1)"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
