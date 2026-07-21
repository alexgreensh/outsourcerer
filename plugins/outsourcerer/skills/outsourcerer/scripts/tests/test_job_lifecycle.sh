#!/usr/bin/env bash
# test_job_lifecycle.sh — the launching->running->terminal lifecycle and the phantom-job guards:
# a detached worker that never comes up must NOT become a status=running job with a ~56-year age that
# no watcher reaps. It must become `failed` (stillborn) with a sane age and a reason, and it must stay
# VISIBLE in `status --json` (never silently dropped for lacking meta.json).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required"; exit 1; }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"; mkdir -p "$OSRC_HOME/jobs"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

run(){ OSRC_HOME="$OSRC_HOME" bash "$SRC" "$@"; }

# --- Scenario 1: a STILLBORN job (launching sentinel, old start, no pid/log) -> failed, sane age. ---
JD="$OSRC_HOME/jobs/20260101-000000-stillborn"; mkdir -p "$JD"
echo launching > "$JD/status"; echo $(( $(date +%s) - 120 )) > "$JD/started_at"
line="$(run status 2>/dev/null | grep stillborn)"
echo "$line" | grep -q ' failed ' && ok "stillborn launching job -> failed" || bad "stillborn not marked failed ($line)"
echo "$line" | grep -qE '\b(1[0-9]{2}|[1-9][0-9])s\b' && ok "stillborn age is sane seconds, not a 56-year epoch age" \
  || bad "stillborn age not sane ($line)"
[ -s "$JD/error" ] && grep -qi 'stillborn' "$JD/error" && ok "stillborn reason recorded (actionable)" || bad "no stillborn reason"

# --- Scenario 2: the phantom is VISIBLE in status --json (not silently dropped for missing meta). ---
js="$(run status --json 2>/dev/null)"
echo "$js" | jq -e '.jobs[] | select(.job_id|test("stillborn"))' >/dev/null 2>&1 \
  && ok "meta-less job appears in status --json (control plane sees it)" \
  || bad "meta-less job dropped from status --json (phantom invisible)"
echo "$js" | jq -e '.jobs[] | select(.job_id|test("stillborn")) | .status=="failed"' >/dev/null 2>&1 \
  && ok "json reflects the failed status" || bad "json status wrong"

# --- Scenario 3: a meta-less job with NO start time shows age '?', never a 56-year age. ---
JD2="$OSRC_HOME/jobs/20260101-000001-noage"; mkdir -p "$JD2"; echo running > "$JD2/status"
aline="$(run status 2>/dev/null | grep noage)"
echo "$aline" | grep -q ' ? ' && ok "unknown start time shows age '?', not a fabricated 56-year age" \
  || bad "unknown-age job did not show '?' ($aline)"
echo "$aline" | grep -qE '17[0-9]{8}s|5[0-9] year' && bad "56-year phantom age is back" || ok "no 56-year phantom age"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
