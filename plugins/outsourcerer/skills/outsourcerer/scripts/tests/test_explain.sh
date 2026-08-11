#!/usr/bin/env bash
# test_explain.sh — the `explain` verb + the "non-success terminal states persist a reason" invariant.
#
# For every NON-SUCCESS terminal state, the job dir MUST carry a non-empty $jd/reason (or $jd/error),
# and `explain <id>` MUST surface both the state and that reason. Ordinary success (`done`) needs no
# reason. `explain` degrades gracefully: a job dir with no meta.json, or with jq unavailable, must
# still print without crashing (rc 0).
#
# Run: bash test_explain.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required for this test"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-explain.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# OSRC_HOME must be set BEFORE sourcing: outsourcerer.sh pins OSRC_HOME/OSRC_JOBS at source time.
# OSRC_SOURCED=1 keeps the source guard from running main().
export OSRC_HOME="$TMP/home"
export OSRC_SOURCED=1
mkdir -p "$OSRC_HOME/jobs"
. "$SRC" >/dev/null 2>&1

# Refuse a false green: if the function under test did not load, the assertions would silently no-op.
type -t cmd_explain      >/dev/null || { echo "FAIL: cmd_explain not loaded";      exit 1; }
type -t _reconcile_status >/dev/null || { echo "FAIL: _reconcile_status not loaded"; exit 1; }
type -t _classify_job     >/dev/null || { echo "FAIL: _classify_job not loaded";     exit 1; }
type -t _last_marker      >/dev/null || { echo "FAIL: _last_marker not loaded";      exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

OSRC_JOBS="$OSRC_HOME/jobs"

# make_job <jid> <status> <reason> <exit-code> [out.log-line...]
# Writes status, reason, exit, a minimal meta.json, and out.log (with any lines passed after $4).
make_job() {
  local jid="$1" st="$2" rsn="$3" exitc="$4"; shift 4
  local jd="$OSRC_JOBS/$jid"
  mkdir -p "$jd"
  printf '%s\n' "$st" > "$jd/status"
  [ -n "$rsn" ] && printf '%s\n' "$rsn" > "$jd/reason"
  printf '%s\n' "$exitc" > "$jd/exit"
  printf '{"id":"%s","model":"glm-5-2","verb":"edit","provider":"devin","started":1700000000}\n' "$jid" > "$jd/meta.json"
  : > "$jd/out.log"
  local ln
  for ln in "$@"; do printf '%s\n' "$ln" >> "$jd/out.log"; done
}

# --- Build one fake job per terminal state. ---
make_job "j-perm"    "permission-blocked" "permission-blocked:denials=3" 3 \
  ">>> [route] devin --model glm-5-2" \
  "Tool execution was rejected: permission denied" \
  "Permission denied: rejected api_key=sk-live-SECRETKEY1234567890 in sandbox" \
  "Permission denied by sandbox"

make_job "j-timeout" "timeout"            "hard-timeout:3600s"           124
make_job "j-failed"  "failed"             "exit-nonzero:rc=1"            1
make_job "j-canceled" "canceled"          "canceled:operator"            130
make_job "j-doneq"   "done?"              "exited-0-without-OSRC-DONE"   0 \
  ">>> [route] devin --model glm-5-2" \
  "some partial work without a terminal marker"

# A plain success: NO reason file (the invariant exempts `done`).
make_job "j-done"    "done"              ""                             0 \
  "OSRC::DONE finished the task"
# `done` needs a non-refusal last.txt so _classify_job short-circuits to REUSE-OUTPUT.
printf 'the real deliverable body\n' > "$OSRC_JOBS/j-done/last.txt"

# A job dir with NO meta.json (old / pre-dispatch death) — explain must still print, rc 0.
mkdir -p "$OSRC_JOBS/j-nometa"
printf 'failed\n'            > "$OSRC_JOBS/j-nometa/status"
printf 'exit-nonzero:rc=2\n' > "$OSRC_JOBS/j-nometa/reason"
printf '2\n'                 > "$OSRC_JOBS/j-nometa/exit"
: > "$OSRC_JOBS/j-nometa/out.log"

# --- Helper: run explain, capture stdout + rc. ---
explain_out() { local id="$1"; cmd_explain "$id" 2>/dev/null; }

# --- Invariant: each NON-SUCCESS terminal job shows its state AND a non-empty reason. ---
check_state_and_reason() {
  # check_state_and_reason <jid> <expected-state-substring>
  local jid="$1" want="$2" out rsnline
  out="$(explain_out "$jid")" || { bad "$jid: explain returned non-zero"; return; }
  printf '%s\n' "$out" | grep -qE "^state:[[:space:]]+${want}" \
    && ok "$jid: state shown ($want)" \
    || bad "$jid: state not shown (want '$want'); got: [$(printf '%s\n' "$out" | grep '^state:')]"
  rsnline="$(printf '%s\n' "$out" | grep '^reason:' || true)"
  case "$rsnline" in
    "reason:"*"not recorded"*) bad "$jid: reason is (not recorded) for a non-success state" ;;
    "reason:"*[[:space:]]*)    ok "$jid: reason shown" ;;
    *)                         bad "$jid: reason line missing/empty; got: [$rsnline]" ;;
  esac
}

check_state_and_reason "j-perm"     "permission-blocked"
check_state_and_reason "j-timeout"  "timeout"
check_state_and_reason "j-failed"   "failed"
check_state_and_reason "j-canceled" "canceled"
check_state_and_reason "j-doneq"    "done\?"

# --- done: state shown, reason is (not recorded), and explain does NOT error. ---
dout="$(explain_out "j-done")" || bad "j-done: explain returned non-zero for a done job"
printf '%s\n' "$dout" | grep -qE '^state:[[:space:]]+done' && ok "j-done: state shown (done)" || bad "j-done: state not shown"
printf '%s\n' "$dout" | grep -qE '^reason:[[:space:]]+\(not recorded\)' && ok "j-done: reason is (not recorded)" || bad "j-done: reason should be (not recorded)"
# done must NOT have a reason file on disk.
[ -s "$OSRC_JOBS/j-done/reason" ] && bad "j-done: a done job should NOT persist a reason" || ok "j-done: no reason file on disk"

# --- explain surfaces verb/model/provider (via _job_field) for a job with meta.json. ---
pout="$(explain_out "j-perm")"
printf '%s\n' "$pout" | grep -qE '^verb:[[:space:]]+edit'        && ok "j-perm: verb shown"        || bad "j-perm: verb not shown"
printf '%s\n' "$pout" | grep -qE '^model:[[:space:]]+glm-5-2'    && ok "j-perm: model shown"       || bad "j-perm: model not shown"
printf '%s\n' "$pout" | grep -qE '^provider:[[:space:]]+devin'   && ok "j-perm: provider shown"    || bad "j-perm: provider not shown"

# --- explain shows the last genuine marker + the _classify_job verdict. ---
vout="$(explain_out "j-done")"
printf '%s\n' "$vout" | grep -qE '^marker:[[:space:]]+OSRC::DONE' && ok "j-done: last marker shown" || bad "j-done: marker not shown"
printf '%s\n' "$vout" | grep -qE '^verdict:[[:space:]]+REUSE-OUTPUT' && ok "j-done: verdict shown (REUSE-OUTPUT)" || bad "j-done: verdict not shown"

# --- permission-blocked: a SANITIZED evidence excerpt is printed and credentials are redacted. ---
eout="$(explain_out "j-perm")"
printf '%s\n' "$eout" | grep -qE '^evidence:' && ok "j-perm: evidence excerpt printed" || bad "j-perm: evidence excerpt missing"
printf '%s\n' "$eout" | grep -q 'sk-live-SECRETKEY1234567890' && bad "j-perm: raw API key leaked in evidence" || ok "j-perm: no raw API key in evidence"
printf '%s\n' "$eout" | grep -q '\[REDACTED' && ok "j-perm: credential redacted in evidence" || bad "j-perm: credential not redacted in evidence"
# A non-permission-blocked job must NOT print an evidence block.
printf '%s\n' "$(explain_out "j-failed")" | grep -q '^evidence:' && bad "j-failed: evidence printed for a non-permission-blocked job" || ok "j-failed: no evidence block"

# --- Graceful degradation: missing meta.json -> still prints, rc 0, fields degrade to '?'. ---
nm_rc=0; nm_out="$(cmd_explain "j-nometa" 2>/dev/null)" || nm_rc=$?
[ "$nm_rc" -eq 0 ] && ok "j-nometa: explain rc 0 with no meta.json" || bad "j-nometa: explain rc=$nm_rc with no meta.json"
printf '%s\n' "$nm_out" | grep -qE '^state:[[:space:]]+failed' && ok "j-nometa: state shown" || bad "j-nometa: state not shown"
printf '%s\n' "$nm_out" | grep -qE '^verb:[[:space:]]+\?' && ok "j-nometa: verb degrades to ?" || bad "j-nometa: verb did not degrade to ?"
printf '%s\n' "$nm_out" | grep -qE '^reason:[[:space:]]+exit-nonzero:rc=2' && ok "j-nometa: reason still shown" || bad "j-nometa: reason missing"

# --- Graceful degradation: jq unavailable -> still prints, rc 0, fields degrade to '?'. ---
# Shadow `have` so `have jq` returns false (the script gates every jq use on `have jq`). The
# direct jq calls in _classify_job's quota branch are not reached for these terminal jobs.
have() { [ "$1" = "jq" ] && return 1; command -v "$1" >/dev/null 2>&1; }
jq_rc=0; jq_out="$(cmd_explain "j-perm" 2>/dev/null)" || jq_rc=$?
unset -f have
[ "$jq_rc" -eq 0 ] && ok "j-perm (no jq): explain rc 0" || bad "j-perm (no jq): explain rc=$jq_rc"
printf '%s\n' "$jq_out" | grep -qE '^state:[[:space:]]+permission-blocked' && ok "j-perm (no jq): state shown" || bad "j-perm (no jq): state not shown"
printf '%s\n' "$jq_out" | grep -qE '^verb:[[:space:]]+\?' && ok "j-perm (no jq): verb degrades to ?" || bad "j-perm (no jq): verb did not degrade to ?"
printf '%s\n' "$jq_out" | grep -qE '^reason:[[:space:]]+permission-blocked:denials=3' && ok "j-perm (no jq): reason still shown" || bad "j-perm (no jq): reason missing"

# --- Invariant on disk: every NON-SUCCESS terminal job has a non-empty reason OR error file. ---
for jid in j-perm j-timeout j-failed j-canceled j-doneq j-nometa; do
  jd="$OSRC_JOBS/$jid"
  if [ -s "$jd/reason" ] || [ -s "$jd/error" ]; then
    ok "$jid: on-disk reason/error present"
  else
    bad "$jid: on-disk reason AND error both empty (invariant violated)"
  fi
done

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
