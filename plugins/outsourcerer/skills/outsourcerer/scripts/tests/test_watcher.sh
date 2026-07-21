#!/usr/bin/env bash
# test_watcher.sh — a detached job must never run unobserved without the tool saying so.
#
# Observed repeatedly in real sessions: the orchestrator launches a background job and then moves on,
# and nobody notices it wedged until the user asks. Documentation did not fix it, because "remember to
# watch" is exactly the kind of instruction a busy session drops. So the tool tracks attention itself:
# it demands a watcher at launch, and any later invocation reports jobs nobody has looked at.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

run() { OSRC_HOME="$TMP" bash "$SRC" "$@"; }
mkjob() { mkdir -p "$TMP/jobs/$1"; printf '%s\n' "$2" > "$TMP/jobs/$1/status"
          printf '%s\n' "$(( $(date +%s) - ${3:-600} ))" > "$TMP/jobs/$1/started_at"; }

# --- a live job nobody has looked at must be reported, unprompted ---
mkjob lonely running 600
out="$(run doctor 2>&1)"
printf '%s' "$out" | grep -q 'nobody has looked at them' \
  && ok "an unobserved running job is reported on the next invocation" \
  || bad "a job running for 10 minutes with no observer went unmentioned"
printf '%s' "$out" | grep -q 'watch lonely' \
  && ok "the warning names the exact command to start watching" \
  || bad "warning does not give the watch command"

# --- looking at it counts; the tool must stop nagging once you have ---
run status lonely >/dev/null 2>&1
run doctor 2>&1 | grep -q 'nobody has looked at them' \
  && bad "still warned about a job that was just inspected" \
  || ok "the warning clears once someone actually looks"

# --- a finished job is not 'unwatched'; only live work can be neglected ---
mkjob finished done 900
run doctor 2>&1 | grep -q 'finished' \
  && bad "a completed job was reported as needing a watcher" \
  || ok "terminal jobs are never reported as unwatched"

# --- a job that just started gets a grace period, or every launch would cry wolf ---
mkjob fresh running 5
run doctor 2>&1 | grep -q 'fresh' \
  && bad "warned about a job that started seconds ago (cries wolf on every launch)" \
  || ok "a just-launched job is given a grace period before it counts as neglected"

# --- the grace period is tunable rather than a magic number ---
grep -q 'OSRC_UNWATCHED_AFTER' "$SRC" \
  && ok "the neglect threshold is configurable" || bad "neglect threshold is hardcoded"

# --- launching must TELL you to watch, not offer it as one option among three ---
grep -q 'NOW WATCH IT' "$SRC" \
  && ok "a launch instructs you to watch rather than listing poll options" \
  || bad "launch output still presents watching as optional"

# --- the commands that mean 'someone looked' must record it, or the warning never clears ---
for c in cmd_status cmd_watch cmd_result; do
  awk "/^$c\(\) \{/,/_mark_watched/" "$SRC" | grep -q '_mark_watched' \
    && ok "$c records that the job was observed" \
    || bad "$c does not record attention (warning would never clear)"
done

# --- a detached worker must not warn about itself: it IS the work ---
awk '/Surface neglected jobs on EVERY invocation/,/esac/' "$SRC" | grep -q '__runjob' \
  && ok "the detached job process is exempt from its own warning" \
  || bad "a running job would warn about itself"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
