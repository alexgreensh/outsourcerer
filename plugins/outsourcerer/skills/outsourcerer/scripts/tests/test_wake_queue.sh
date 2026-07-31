#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TMP="$(mktemp -d)"
export OSRC_HOME="$TMP"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

set --
. "$SRC" >/dev/null 2>&1

if _wake_append '{"event_id":"wake-1","kind":"blocked"}' && _wake_append '{"event_id":"wake-2","kind":"unknown"}'; then
  ok "wake records append"
else
  bad "wake append failed"
fi
pending="$(_wake_drain)"
if printf '%s' "$pending" | grep -q 'wake-1' && printf '%s' "$pending" | grep -q 'wake-2'; then
  ok "unacknowledged wakes drain"
else
  bad "wake drain omitted a pending event"
fi

if _wake_ack wake-1; then
  ok "wake acknowledgement appends"
else
  bad "wake acknowledgement failed"
fi
pending="$(_wake_drain)"
if ! printf '%s' "$pending" | grep -q 'wake-1' && printf '%s' "$pending" | grep -q 'wake-2'; then
  ok "acknowledged wake is excluded without losing the next wake"
else
  bad "wake acknowledgement filtering is wrong ($pending)"
fi

if _wake_append '{"kind":"missing-id"}' >/dev/null 2>&1; then
  bad "wake without an id was accepted"
else
  ok "wake without an id is rejected"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
