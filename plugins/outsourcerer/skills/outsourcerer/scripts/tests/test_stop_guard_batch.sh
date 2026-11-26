#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_stop_guard_batch.sh -- the stop hook reads every owned marker in one batch
# (_owned_live_states, lib/owner_state.sh) instead of ~10-18 ms of jq/ps forks per marker.
#   1. the batch gives exactly the per-id answer (_owned_live_state) for every kind of marker:
#      remote lanes (live, ready, failed, unreadable file), jobs (live pid, dead pid, terminal,
#      launching, no pid record), a hand-in watch, an unknown id.
#   2. the cost does not grow per marker: 20 remote lanes and 20 jobs take a bounded number of
#      jq and ps calls in one stop-hook pass (it was one jq per lane and two ps per job).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "${TMPDIR%/}/.test-stop-guard-batch.XXXXXX")" || { echo "FAIL: scratch" >&2; exit 1; }
SP=""; trap '[ -z "$SP" ] || kill "$SP" 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
export OSRC_HOME="$TMP/state" HOME="$TMP/home" OSRC_HEARTBEAT_DISABLED=1 OSRC_CARD_GUARD=0 CLAUDE_CODE_SESSION_ID=sg-batch
O="$OSRC_HOME/owners/sg-batch"; mkdir -p "$OSRC_HOME/jobs" "$OSRC_HOME/remote" "$OSRC_HOME/watch" "$O" "$HOME" "$TMP/bin"
sleep 600 & SP=$!
now="$(date +%s)"
lane() { printf '{"id":"%s","branch":"b","transport":"git","url":"/x","created_ts":%s,"last_poll_ts":%s%s}\n' "$1" "$now" "$now" "${2:-}" > "$OSRC_HOME/remote/$1.json"; : > "$O/$1"; }
job() { # <id> <status> [pid] [start-record]
  local d="$OSRC_HOME/jobs/$1"; mkdir -p "$d"; echo "$2" > "$d/status"; echo "$now" > "$d/started_at"
  [ -z "${3:-}" ] || echo "$3" > "$d/pid"; [ -z "${4:-}" ] || echo "$4" > "$d/pid_start"; : > "$O/$1"; }
lane rl-live; lane rl-ready ',"head":"abc","head_ready":true,"ready_head":"abc"'; lane rl-del ',"branch_deleted":true'
printf '{broken' > "$OSRC_HOME/remote/rl-bad.json"; : > "$O/rl-bad"
LST="$(LC_ALL=C ps -o lstart= -p "$SP")"
job 20261126-000001-live running "$SP" "$LST"
job 20261126-000002-dead running 999999 "Thu Jan  1 00:00:00 2001"
job 20261126-000003-done done
job 20261126-000004-lnch launching
job 20261126-000005-nopid running
job 20261126-000006-other running "$SP" "Thu Jan  1 00:00:00 2001"
echo "$TMP" > "$OSRC_HOME/watch/watch.abc.path"; : > "$O/watch.abc"; : > "$O/watch.gone"; : > "$O/nosuch"
OSRC_SOURCED=1; export OSRC_SOURCED; set --; . "$SRC" >/dev/null 2>&1
export OSRC_RECONCILE_READ_ONLY=1   # compare answers without the first reader flipping a dead job

ids="$(ls -1 "$O")"
batch="$(_owned_live_states $ids)"
for id in $ids; do
  one="$(_owned_live_state "$id" 2>/dev/null)"; b="$(awk -v i="$id" '$1==i{print $2}' <<<"$batch")"
  [ -n "$one" ] && [ "$b" = "$one" ] && ok "batch = per-id for $id ($one)" || bad "$id: batch '$b' vs per-id '$one'"
done
[ "$(grep -c . <<<"$batch")" = "$(grep -c . <<<"$ids")" ] && ok "one answer per marker" || bad "answers: $batch"

# ---- cost: 20 remote lanes + 20 jobs in one stop-hook pass --------------------------------------
rm -f "$O"/*; rm -rf "$OSRC_HOME/remote"/* "$OSRC_HOME/jobs"/*
for i in $(seq 1 20); do lane "cl$i"; job "20261126-0001$(printf %02d "$i")-j" running "$SP" "$LST"; done
for b in jq ps; do
  real="$(command -v "$b")"
  printf '#!/bin/sh\necho x >> "%s/%s.count"\nexec "%s" "$@"\n' "$TMP" "$b" "$real" > "$TMP/bin/$b"; chmod +x "$TMP/bin/$b"
done
rm -f "$TMP"/*.count
osrc_session_watched() { return 1; }; _waited_ids() { :; }
PATH="$TMP/bin:$PATH"; hash -r
printf '{"session_id":"sg-batch"}' | OSRC_STOP_GUARD_MAX=999 cmd_stop_guard >/dev/null 2>&1
PATH="${PATH#"$TMP/bin:"}"; hash -r
nj="$(grep -c . "$TMP/jq.count" 2>/dev/null || echo 0)"; np="$(grep -c . "$TMP/ps.count" 2>/dev/null || echo 0)"
[ "$nj" -le 10 ] && ok "jq calls for 20 remote lanes in one pass: $nj (was one per lane)" || bad "jq calls grow per marker: $nj"
[ "$np" -le 6 ] && ok "ps calls for 20 jobs in one pass: $np (was two per job)" || bad "ps calls grow per marker: $np"
[ "$(ls -1 "$O" | grep -c .)" = 40 ] && ok "live markers are all kept" || bad "markers: $(ls -1 "$O" | grep -c .)"

echo "test_stop_guard_batch: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
