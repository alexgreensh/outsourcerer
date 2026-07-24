#!/usr/bin/env bash
# test_watch_digest.sh — the watcher periodic digest (OSRC_WATCH_DIGEST_SECS) must:
#   1) emit the documented OSRC::PROGRESS digest format,
#   2) fall back to the default on a non-numeric / zero / negative interval (no set -u error, no spam),
#   3) emit exactly ONE terminal digest and never double it with a periodic one (Sol review).
# Built from the pain it fixes: a watched job that goes dark for its whole running phase reads as a
# hang; and an unvalidated interval either errors under set -u or emits every single poll.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Source-level: the feature + its validation must be present.
grep -q '_watch_digest()' "$SRC" && ok "_watch_digest helper defined" || bad "_watch_digest missing"
grep -q 'OSRC_WATCH_DIGEST_SECS' "$SRC" && ok "OSRC_WATCH_DIGEST_SECS wired" || bad "digest interval env missing"
grep -q "in ''|\*\[!0-9\]\*|0) digest_secs=420" "$SRC" \
  && ok "digest interval is validated (positive integer, else default)" \
  || bad "digest interval is not validated"

# Behavioural: isolated fake job dirs under a temp OSRC_HOME.
export OSRC_HOME="$(mktemp -d)"; export OSRC_JOBS="$OSRC_HOME/jobs"
trap 'rm -rf "$OSRC_HOME"' EXIT
mkdir -p "$OSRC_JOBS/term"
date +%s > "$OSRC_JOBS/term/started_at"
echo done > "$OSRC_JOBS/term/status"

# Terminal digest: exactly one "fetch result", zero "continuing" (no double-emit), correct format.
out="$( . "$SRC" >/dev/null 2>&1; OSRC_WATCH_DIGEST_SECS=1 OSRC_POLL=1 cmd_watch term 2>&1 )"
fr=$(printf '%s' "$out" | grep -c 'next: fetch result')
cw=$(printf '%s' "$out" | grep -c 'continuing watch')
[ "$fr" -eq 1 ] && ok "terminal state emits exactly one 'fetch result' digest" || bad "expected 1 terminal digest, got $fr"
[ "$cw" -eq 0 ] && ok "terminal iteration does not also emit a periodic digest (no double-emit)" || bad "double-emit: $cw periodic digests alongside terminal"
printf '%s' "$out" | grep -q 'OSRC::PROGRESS watch term periodic digest' \
  && ok "digest uses the documented OSRC::PROGRESS header" || bad "digest header missing/wrong"
printf '%s' "$out" | grep -qE '^- state: ' && printf '%s' "$out" | grep -qE '^- elapsed: ' \
  && ok "digest carries state + elapsed bullets" || bad "digest bullets missing"

# Bad interval must not error under set -u and must not spam: a running job watched --for 2 with a
# garbage interval falls back to 420, so NO periodic 'continuing' digest fires in that window.
mkdir -p "$OSRC_JOBS/run"; date +%s > "$OSRC_JOBS/run/started_at"; echo running > "$OSRC_JOBS/run/status"
out2="$( . "$SRC" >/dev/null 2>&1; OSRC_WATCH_DIGEST_SECS=abc OSRC_POLL=1 cmd_watch run --for 2 2>&1 )"
cw2=$(printf '%s' "$out2" | grep -c 'continuing watch')
[ "$cw2" -eq 0 ] \
  && ok "non-numeric interval falls back to default (no per-poll spam, no set -u error)" \
  || bad "bad interval emitted $cw2 periodic digests (validation failed)"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
