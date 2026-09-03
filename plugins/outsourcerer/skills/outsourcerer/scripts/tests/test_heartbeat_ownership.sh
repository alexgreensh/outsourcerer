#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TMP="$(mktemp -d "$PWD/.test-heartbeat-ownership.XXXXXX")"
TEST_TMP="$TMP"
export OSRC_HOME="$TMP/state"
trap 'rm -rf "$TEST_TMP"' EXIT
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
rm -rf "$OSRC_HEARTBEAT/leader" "$OSRC_HEARTBEAT/.election"
mkdir "$OSRC_HEARTBEAT/.election"
printf '%s\n' '{"pid":999,"pid_start":"Thu Jul 31 01:02:03 2026"}' > "$OSRC_HEARTBEAT/.election/owner.json"
printf '%s\n' 'Sat Aug 2 01:02:03 2026' > "$HB_PS_MARKER"
if PATH="$TMP/bin:$PATH" _heartbeat_claim "$$" 'Sat Aug 2 01:02:03 2026' recovered ""; then
  ok "stale election directory cannot wedge flock-based recovery"
else
  bad "stale election directory wedged heartbeat recovery"
fi
rm -rf "$OSRC_HEARTBEAT/leader" "$OSRC_HEARTBEAT/.election"

# The forced mkdir route is the portable election path. It must never silently
# fall back to flock just because flock happens to be installed on the host.
OSRC_FORCE_MKDIR_ELECTION=1
if PATH="$TMP/bin:$PATH" _heartbeat_election_acquire "$OSRC_HEARTBEAT/.election" "$$" 'Sat Aug 2 01:02:03 2026' \
  && [ "${_HEARTBEAT_ELECTION_KIND:-}" = mkdir ]; then
  _heartbeat_election_release "$OSRC_HEARTBEAT/.election"
  ok "OSRC_FORCE_MKDIR_ELECTION exercises the mkdir election path"
else
  _heartbeat_election_release "$OSRC_HEARTBEAT/.election" 2>/dev/null || true
  bad "OSRC_FORCE_MKDIR_ELECTION did not force the mkdir election path"
fi

# A leader publish can be interrupted after mkdir creates canonical but before
# owner.json lands. This is recoverable state, not a permanent startup wedge.
mkdir -p "$OSRC_HEARTBEAT/leader/nested-pending"
if PATH="$TMP/bin:$PATH" _heartbeat_claim "$$" 'Sat Aug 2 01:02:03 2026' ownerless-recovered ''; then
  token="$(jq -r '.token' "$OSRC_HEARTBEAT/leader/owner.json" 2>/dev/null)"
  [ "$token" = ownerless-recovered ] && ok "owner-less leader tree is recovered" || bad "owner-less leader recovery wrote the wrong owner"
else
  bad "owner-less leader tree wedged heartbeat recovery"
fi

# Two no-flock contenders must leave one leader, then the winner's stop path
# removes recursive leader/election state so a later beacon can start cleanly.
rm -rf "$OSRC_HEARTBEAT/leader" "$OSRC_HEARTBEAT/.election"
( contender_pid="${BASHPID:-$$}"; PATH="$TMP/bin:$PATH" _heartbeat_claim "$contender_pid" 'Sat Aug 2 01:02:03 2026' contender-a ''; printf '%s\n' "$?" > "$TMP/contender-a.rc" ) & contender_a=$!
( contender_pid="${BASHPID:-$$}"; PATH="$TMP/bin:$PATH" _heartbeat_claim "$contender_pid" 'Sat Aug 2 01:02:03 2026' contender-b ''; printf '%s\n' "$?" > "$TMP/contender-b.rc" ) & contender_b=$!
wait "$contender_a"; wait "$contender_b"
winner_count="$(awk '$1 == 0 { count++ } END { print count + 0 }' "$TMP/contender-a.rc" "$TMP/contender-b.rc")"
winner_token="$(jq -r '.token // empty' "$OSRC_HEARTBEAT/leader/owner.json" 2>/dev/null)"
if [ "$winner_count" = 1 ] && { [ "$winner_token" = contender-a ] || [ "$winner_token" = contender-b ]; }; then
  PATH="$TMP/bin:$PATH" _heartbeat_stop "$winner_token" >/dev/null 2>&1
  [ ! -e "$OSRC_HEARTBEAT/leader" ] && [ ! -e "$OSRC_HEARTBEAT/.election" ] \
    && ok "two mkdir contenders leave cleanup-safe leader state" || bad "no-flock stop left leader or election state"
else
  bad "two mkdir contenders did not elect exactly one leader (wins=$winner_count token=$winner_token)"
fi
unset OSRC_FORCE_MKDIR_ELECTION

# Lifecycle: a leader remains only while supervised work exists. This is the
# condition the beacon checks between ticks before it releases its claim.
mkdir -p "$OSRC_JOBS/lifecycle"
printf '%s\n' running > "$OSRC_JOBS/lifecycle/status"
# A REAL running job always records its worker pid at launch (run_job writes it the moment it starts),
# so the fixture must too: _heartbeat_active_work now routes the status through _reconcile_status, which
# (correctly, and consistently with every other reader) treats a `running` job whose pid is not live as
# a dead/interrupted job — that is the immortal-beacon fix. An empty pid_start means "legacy/unknown
# start", so reconcile trusts the live kill -0; this process stands in for a live delegate.
printf '%s\n' "$$" > "$OSRC_JOBS/lifecycle/pid"
: > "$OSRC_JOBS/lifecycle/pid_start"
_heartbeat_active_work && ok "active supervised work keeps the beacon eligible" || bad "active work was not detected"
printf '%s\n' done > "$OSRC_JOBS/lifecycle/status"
_heartbeat_active_work && bad "terminal work kept the beacon alive" || ok "beacon exits once supervised work is terminal"

PATH="/usr/bin:/bin:$PATH" _heartbeat_stop recovered >/dev/null 2>&1 || true

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
