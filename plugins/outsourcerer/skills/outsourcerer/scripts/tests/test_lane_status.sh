#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_lane_status.sh -- honest remote-lane status: a missing cloud branch means "starting" (gh HTTP 422),
# a lane that never pushes is reported once as "never started", real network errors still surface,
# and `lane ls` derives its state from evidence (age, branch), not from a stale cached `live`.
# Offline: a PATH stub stands in for gh; the clock is fake (OSRC_NOW, OSRC_TIME_UNIT=1).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "${TMPDIR%/}/.test-lane-status.XXXXXX")" || { echo "FAIL: scratch" >&2; exit 1; }; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
export OSRC_HOME="$TMP/state" HOME="$TMP/home" CLAUDE_CODE_SESSION_ID="sess-test-lane-status"
mkdir -p "$OSRC_HOME" "$HOME" "$TMP/bin"
export OSRC_TIME_UNIT=1 OSRC_REMOTE_POLL_SECS=0 OSRC_SELF=osrc OSRC_NOW=1000000 OSRC_REMOTE_STALL=90 OSRC_REMOTE_NEVER_START=45
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
if [ -f "$GH_ERR" ]; then cat "$GH_ERR" >&2; exit 1; fi
cat "$GH_OUT"
SH
chmod +x "$TMP/bin/gh"; export GH_ERR="$TMP/gh.err" GH_OUT="$TMP/gh.out" PATH="$TMP/bin:$PATH"
OSRC_SOURCED=1; export OSRC_SOURCED; set --; . "$SRC" >/dev/null 2>&1

add() { cmd_lane add "$1" --branch "cloud/$1" --repo acme/widgets >/dev/null 2>&1; }
errs() { jq -r '.err_count' "$OSRC_HOME/remote/$1.json"; }

# Incident: gh answered HTTP 422 five times for a cloud/<id> branch not pushed yet -> EVENT failed.
printf 'gh: No commit found for SHA: cloud/c1 (HTTP 422)\n' > "$GH_ERR"
add c1
for _ in 1 2 3 4 5 6; do cmd_lane poll c1; done
[ "$(errs c1)" = 0 ] && ok "HTTP 422 on a not-yet-pushed branch is not a poll error" || bad "422 counted as error ($(errs c1))"
out="$(osrc_remote_events 2>&1)"
grep -q 'EVENT failed c1' <<<"$out" && bad "healthy starting lane reported failed: $out" || ok "no EVENT failed while the branch is missing"
[ "$(osrc_remote_state c1)" = live ] && ok "state stays live (starting)" || bad "state $(osrc_remote_state c1)"
grep -q 'starting' <<<"$(cmd_lane ls)" && ok "lane ls says starting" || bad "ls: $(cmd_lane ls)"

# A lane that never pushes: one 'never started' event, then silence.
OSRC_NOW=$((1000000 + 46)); export OSRC_NOW
out="$(osrc_remote_events 2>&1)"
grep -q 'EVENT failed c1 .*never started' <<<"$out" && ok "never-pushed lane reports 'never started'" || bad "no never-started event: $out"
out="$(osrc_remote_events 2>&1)"
grep -q 'never started' <<<"$out" && bad "never-started repeated" || ok "never-started is reported once"
grep -q 'stale' <<<"$(cmd_lane ls)" && ok "lane ls shows the never-pushed lane stale" || bad "ls: $(cmd_lane ls)"

# Real network errors still surface (and a missing branch must not mask them).
OSRC_NOW=1000000; export OSRC_NOW
printf 'gh: error connecting to api.github.com\n' > "$GH_ERR"
add c2
for _ in 1 2 3 4 5 6; do cmd_lane poll c2; done
osrc_remote_events 2>&1 | grep -q 'EVENT failed c2 .*polling failed' && ok "real network errors still surface" || bad "network error hidden"

# Evidence-based ls: a lane that pushed once, then went quiet past the stall timeout, is stale not live.
rm -f "$GH_ERR"
printf '{"sha":"%s","commit":{"message":"wip"},"files":[]}\n' "$(printf 'a%.0s' $(seq 40))" > "$GH_OUT"
add c3; cmd_lane poll c3
grep -E '^c3 ' <<<"$(cmd_lane ls)" | grep -q ' live ' && ok "fresh push shows live" || bad "ls: $(cmd_lane ls)"
OSRC_NOW=$((1000000 + 91)); export OSRC_NOW
grep -E '^c3 ' <<<"$(cmd_lane ls)" | grep -q ' stale ' && ok "no evidence past the timeout shows stale" || bad "ls: $(cmd_lane ls)"

echo "=== $pass passed, $fail failed ==="; [ "$fail" -eq 0 ]
