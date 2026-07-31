#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TMP="$(mktemp -d)"
export OSRC_HOME="$TMP"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

set --
. "$SRC" >/dev/null 2>&1

record='{"schema_version":"1","event_id":"event-1"}'
if _state_append "$OSRC_WAKE_QUEUE" "$record"; then
  ok "valid record is appended"
else
  bad "valid record was rejected"
fi
if _state_jsonl_read "$OSRC_WAKE_QUEUE" | jq -e '.event_id == "event-1"' >/dev/null; then
  ok "appended record is valid JSON"
else
  bad "appended record cannot be read"
fi

before="$(wc -l < "$OSRC_WAKE_QUEUE" | tr -d ' ')"
if OSRC_STATE_RECORD_MAX=8 _state_append "$OSRC_WAKE_QUEUE" "$record" >/dev/null 2>&1; then
  bad "oversize record was accepted"
else
  after="$(wc -l < "$OSRC_WAKE_QUEUE" | tr -d ' ')"
  [ "$before" = "$after" ] && ok "oversize record fails before append" || bad "oversize record changed the file"
fi

printf '%s\n' '{"event_id":"complete"}' > "$OSRC_WAKE_QUEUE"
printf '%s' '{"event_id":' >> "$OSRC_WAKE_QUEUE"
readout="$(_state_jsonl_read "$OSRC_WAKE_QUEUE" 2>&1)"
if printf '%s' "$readout" | grep -q '"complete"' && printf '%s' "$readout" | grep -q 'ignored truncated final state record'; then
  ok "truncated final record is recovered"
else
  bad "truncated final record was not recovered ($readout)"
fi

flock() { return 1; }
before="$(wc -l < "$OSRC_WAKE_QUEUE" | tr -d ' ')"
if _state_append "$OSRC_WAKE_QUEUE" "$record" >/dev/null 2>&1; then
  bad "lock failure was accepted"
else
  after="$(wc -l < "$OSRC_WAKE_QUEUE" | tr -d ' ')"
  [ "$before" = "$after" ] && ok "lock failure prevents a record write" || bad "lock failure changed the file"
fi
unset -f flock

snapshot="$(_fleet_snapshot_collect)"
if _fleet_snapshot_write "$snapshot" && _fleet_snapshot_read | jq -e '.items | type == "array"' >/dev/null; then
  ok "snapshot is published and readable"
else
  bad "snapshot publish/read failed"
fi
if find "$OSRC_HOME" -name '.fleet-snapshot.*.tmp' -print | grep -q .; then
  bad "snapshot temporary file remains"
else
  ok "snapshot temporary file is replaced"
fi
digest="$(_fleet_digest "$snapshot")"
if printf '%s' "$digest" | grep -q "Captain's Call" && printf '%s' "$digest" | grep -q 'Charted Next'; then
  ok "digest renders all sections"
else
  bad "digest sections are incomplete ($digest)"
fi
if _heartbeat_line "$snapshot" | grep -q 'working='; then
  ok "heartbeat line renders counts"
else
  bad "heartbeat line did not render"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
