#!/usr/bin/env bash
# A leader whose owner PID is provably dead must be reclaimable. Otherwise a beacon that exits
# without cleaning up (a kill, a power loss) wedges supervision forever for that home.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
TMP="$(mktemp -d "$PWD/.test-hb-reclaim.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"; export OSRC_HEARTBEAT="$OSRC_HOME/heartbeat"
pass=0; fail=0; ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

s="$SRC"; set --; . "$s" >/dev/null 2>&1
_state_sync() { return 0; }

# A definitely-dead PID (nothing running, kill -0 and ps -p both fail).
dead=99991; while kill -0 "$dead" 2>/dev/null || ps -p "$dead" >/dev/null 2>&1; do dead=$((dead-1)); done

# Stub ps so a live incumbent still LOOKS alive with a readable identity, but the dead PID is absent.
mkdir -p "$TMP/bin"; export HB_PS_MARKER="$TMP/marker"; printf '%s\n' 'Thu Jul 31 01:02:03 2026' > "$HB_PS_MARKER"
cat > "$TMP/bin/ps" <<SH
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in $dead) exit 1;; esac; done
cat "\$HB_PS_MARKER"
SH
chmod +x "$TMP/bin/ps"

# 1. Dead-PID leader is reclaimed.
mkdir -p "$OSRC_HEARTBEAT/leader"
jq -cn --argjson p "$dead" '{schema_version:"1",pid:$p,pid_start:"Fri Aug 1 01:02:03 2026",token:"stale",sink:null}' > "$OSRC_HEARTBEAT/leader/owner.json"
start="$(PATH="$TMP/bin:$PATH" _pid_start_identity "$$")"
if PATH="$TMP/bin:$PATH" _heartbeat_claim "$$" "$start" fresh "" ; then
  tok="$(jq -r '.token' "$OSRC_HEARTBEAT/leader/owner.json" 2>/dev/null)"
  [ "$tok" = fresh ] && ok "a provably-dead owner is reclaimed" || bad "reclaim did not republish (token=$tok)"
else
  bad "dead-PID leader was not reclaimed (claim rc=$?)"
fi

# 2. A live incumbent with an UNREADABLE identity is still preserved (not evicted).
rm -rf "$OSRC_HEARTBEAT/leader"; mkdir -p "$OSRC_HEARTBEAT/leader"
printf '%s\n' '?' > "$HB_PS_MARKER"   # readable-but-invalid marker => identity unprovable, but $$ is alive
jq -cn --argjson p "$$" '{schema_version:"1",pid:$p,pid_start:"Fri Aug 1 01:02:03 2026",token:"live",sink:null}' > "$OSRC_HEARTBEAT/leader/owner.json"
if PATH="$TMP/bin:$PATH" _heartbeat_claim "$$" "Fri Aug 1 01:02:03 2026" intruder "" ; then
  bad "a live-but-unreadable incumbent was evicted"
else
  rc=$?; tok="$(jq -r '.token' "$OSRC_HEARTBEAT/leader/owner.json")"
  [ "$rc" -eq 3 ] && [ "$tok" = live ] && ok "a live incumbent with unreadable identity is preserved" || bad "live incumbent not preserved (rc=$rc token=$tok)"
fi

echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
