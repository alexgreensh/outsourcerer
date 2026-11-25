#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TMP="$(mktemp -d)"
export HOME="$TMP/home"
export OSRC_HOME="$TMP/state" OSRC_SESSION_LIVENESS_SECS=0
BIN="$TMP/bin"
mkdir -p "$HOME" "$BIN"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
case "${1:-}" in
  has-session) exit 0 ;;
  respawn-pane) printf '222\n' > "$TMUX_LOG.pid" ;;
  display-message)
    case " $* " in
      *" #{pane_pid} "*) cat "$TMUX_LOG.pid" ;;
      *" #{pane_current_command} "*) printf 'codex\n' ;;
    esac
    ;;
esac
exit 0
EOF
cat > "$BIN/droid" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  # Matches the REAL `droid --help` (verified live): top-level -r is RESUME, not reasoning-effort.
  # `-r, --reasoning-effort <level>` exists ONLY under `droid exec --help`. The old fake lied with
  # `-r, --reasoning <level>`, which masked the effort/resume collision bug.
  cat <<'HELP'
Usage: droid [options] [command] [prompt...]
  -r, --resume [sessionId]            Resume a session (defaults to last modified)
  --auto <level>                      Autonomy level: low|medium|high
  exec [options] [prompt]             Run non-interactively (for scripts/automation)
  droid                               Start interactive mode (default)
HELP
fi
EOF
chmod +x "$BIN/tmux"
chmod +x "$BIN/droid"
export PATH="$BIN:$PATH"
export TMUX_LOG="$TMP/tmux.log"
printf '111\n' > "$TMUX_LOG.pid"

set --
. "$SRC" >/dev/null 2>&1
_pid_start_identity() { printf 'Mon Jan 1 00:00:00 2024\n'; }
trap cleanup EXIT
# Hermetic arm gate. A sourced suite can never arm a real beacon: SCRIPT_PATH is this (non-
# executable) test file, so _heartbeat_start bails at its `-x` check and the relaunch reported
# NOT-ARMED. conformance.sh masked that by exporting OSRC_HEARTBEAT_DISABLED=1 (gate rc 2), so the
# suite passed there and failed standalone. Clear both knobs and stub the gate so standalone ==
# conformance; the call log proves the codex relaunch still goes THROUGH the gate.
unset OSRC_HEARTBEAT_DISABLED OSRC_FLEET_SUPERVISION
ARM_LOG="$TMP/arm-log"; : > "$ARM_LOG"
_heartbeat_arm_verify() { echo arm >> "$ARM_LOG"; return 0; }

SESSION_NAME=effort-test
# Each case below stands for `--provider <lane>` on the command line. Since L3, a session subcommand
# without --provider resolves the lane from the session's start record, so mark the lane explicit.
PROVIDER=codex
PROVIDER_EXPLICIT=1
MODEL=sol
MODEL_EXPLICIT=1
EFFORT=""
_session_registry_append start "$PROVIDER" "$MODEL" "" "started" "test" || bad "registry accepts start record"
[ -s "$OSRC_SESSION_REGISTRY" ] && ok "session start is recorded" || bad "session start was not recorded"

before="$(wc -l < "$OSRC_SESSION_REGISTRY")"
( session effort invalid >/dev/null 2>&1 ) && bad "invalid effort accepted" || ok "invalid effort rejected"
after="$(wc -l < "$OSRC_SESSION_REGISTRY")"
[ "$before" = "$after" ] && ok "invalid effort leaves registry unchanged" || bad "invalid effort changed registry"

: > "$TMUX_LOG"
# The relaunch is spend-gated (tests/test_spend_attack.sh); this case consents and checks bookkeeping.
out="$(OSRC_SPEND_OK=1 session effort high 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -s "$ARM_LOG" ] && grep -q 'receipt.*relaunch' <<<"$out" \
   && grep -q 'model_reasoning_effort=high' "$TMUX_LOG" \
   && tail -1 "$OSRC_SESSION_REGISTRY" | jq -e '.effort == "high" and .receipt == "relaunch"' >/dev/null; then
  ok "codex relaunch records effort and receipt"
else
  bad "codex effort relaunch was not recorded truthfully: rc=$rc out=$out"
fi

PROVIDER=devin
out="$(session effort low 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qi 'advisory' <<<"$out" \
   && ! grep -qi 'native-success\|live-applied' <<<"$out" \
   && tail -1 "$OSRC_SESSION_REGISTRY" | jq -e '.effort == "low" and .receipt == "advisory"' >/dev/null; then
  ok "Devin effort remains advisory"
else
  bad "Devin effort receipt is not advisory: rc=$rc out=$out"
fi

PROVIDER=droid
: > "$TMUX_LOG"
out="$(session effort xhigh 2>&1)"; rc=$?
# Droid interactive has NO reasoning-effort flag: top-level `-r, --resume [sessionId]` means
# RESUME a session, not effort (`-r, --reasoning-effort` is exec-only). A relaunch with `-r high`
# would try to RESUME a session named "high", find none, and exit 0 to a bare shell. So the
# effort relaunch must REFUSE (rc!=0), must NOT emit `-r` to tmux, and must NOT record a relaunch
# receipt (the prior session is left intact, per the relaunch contract).
if [ "$rc" -ne 0 ] && ! grep -q -- '-r ' "$TMUX_LOG" \
   && ! tail -1 "$OSRC_SESSION_REGISTRY" 2>/dev/null | jq -e '.receipt == "relaunch"' >/dev/null 2>&1; then
  ok "Droid effort relaunch REFUSES (no -r reasoning-effort at top level; -r = resume), leaves the session intact"
else
  bad "Droid effort relaunch did not refuse correctly: rc=$rc out=$out tmux=$(cat "$TMUX_LOG" 2>/dev/null)"
fi

PROVIDER=gemini
out="$(session effort medium 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qi 'advisory' <<<"$out" \
   && ! grep -qi 'native-success\|live-applied' <<<"$out"; then
  ok "Gemini effort remains advisory"
else
  bad "Gemini effort receipt is not advisory: rc=$rc out=$out"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
