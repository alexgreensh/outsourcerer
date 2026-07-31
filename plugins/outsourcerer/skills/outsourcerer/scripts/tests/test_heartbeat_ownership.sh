#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TMP="$(mktemp -d "$PWD/.test-heartbeat-ownership.XXXXXX")"
export OSRC_HOME="$TMP/state"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

src="$SRC"; set --; . "$src" >/dev/null 2>&1
_state_sync() { return 0; }

mkdir -p "$TMP/bin"
export HB_PS_MARKER="$TMP/ps-marker"
cat > "$TMP/bin/ps" <<'SH'
#!/usr/bin/env bash
cat "$HB_PS_MARKER"
SH
chmod +x "$TMP/bin/ps"
printf '%s\n' 'Thu Jul 31 01:02:03 2026' > "$HB_PS_MARKER"
start="$(PATH="$TMP/bin:$PATH" _pid_start_identity "$$")"
if [ -n "$start" ] && PATH="$TMP/bin:$PATH" _heartbeat_claim "$$" "$start" first ""; then
  ok "first owner acquires the atomic leader claim"
else
  bad "first owner could not acquire the leader claim"
fi

if PATH="$TMP/bin:$PATH" _heartbeat_claim "$$" "$start" second ""; then
  bad "a live owner was replaced"
else
  rc=$?
  token="$(jq -r '.token' "$OSRC_HEARTBEAT/leader/owner.json" 2>/dev/null)"
  [ "$rc" -eq 2 ] && [ "$token" = first ] \
    && ok "a second arm no-ops for a verified live owner" \
    || bad "live-owner no-op was not preserved (rc=$rc token=$token)"
fi

new_start='Fri Aug 1 01:02:03 2026'
printf '%s\n' "$new_start" > "$HB_PS_MARKER"
if PATH="$TMP/bin:$PATH" _heartbeat_claim "$$" "$new_start" takeover ""; then
  token="$(jq -r '.token' "$OSRC_HEARTBEAT/leader/owner.json")"
  [ "$token" = takeover ] && ok "a proven PID-start mismatch permits stale takeover" \
    || bad "stale takeover wrote the wrong identity"
else
  bad "a proven stale owner was not replaced"
fi

printf '%s\n' '?' > "$HB_PS_MARKER"
if PATH="$TMP/bin:$PATH" _heartbeat_claim "$$" 'Fri Aug 1 01:02:03 2026' refused ""; then
  bad "an unprovable owner identity was replaced"
else
  rc=$?
  token="$(jq -r '.token' "$OSRC_HEARTBEAT/leader/owner.json")"
  [ "$rc" -eq 3 ] && [ "$token" = takeover ] \
    && ok "unprovable ownership remains observation-only" \
    || bad "unprovable ownership did not preserve the claim (rc=$rc token=$token)"
fi

# A stale mkdir-era election directory must not wedge a new owner: the flock
# lease is tied to the process FD, not directory cleanup by a crashed owner.
rm -f "$OSRC_HEARTBEAT/leader/owner.json"; rmdir "$OSRC_HEARTBEAT/leader"
mkdir "$OSRC_HEARTBEAT/.election"
printf '%s\n' '{"pid":999,"pid_start":"Thu Jul 31 01:02:03 2026"}' > "$OSRC_HEARTBEAT/.election/owner.json"
printf '%s\n' 'Sat Aug 2 01:02:03 2026' > "$HB_PS_MARKER"
if PATH="$TMP/bin:$PATH" _heartbeat_claim "$$" 'Sat Aug 2 01:02:03 2026' recovered ""; then
  ok "stale election directory cannot wedge flock-based recovery"
else
  bad "stale election directory wedged heartbeat recovery"
fi
rmdir "$OSRC_HEARTBEAT/.election" 2>/dev/null || true

PATH="/usr/bin:/bin:$PATH" _heartbeat_stop recovered >/dev/null 2>&1 || true

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
