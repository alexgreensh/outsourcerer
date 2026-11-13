#!/usr/bin/env bash
# `session send "/effort ..."` must NEVER reach a Claude Code pane: /effort persists
# effortLevel into ~/.claude/settings.json, re-defaulting effort for EVERY future claude
# session (the 2026-11-13 TR-orchestrator leak — the intent was a per-session change, the
# global default moved instead). The guard refuses the send and names `session effort`,
# the per-session path that relaunches with env-scoped effort and cannot touch settings.
#
# Self-contained: sources the script with OSRC_SOURCED=1 and fakes tmux as a function,
# matching test_session_send_verify.sh. Temp HOME holds a fake ~/.claude/settings.json;
# the REAL user settings file is never read or written by any test or probe here.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "$PWD/.test-effort-guard.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"                       # fake HOME: claude settings resolve here only
export OSRC_HOME="$TMP/state"; mkdir -p "$OSRC_HOME/sessions"
mkdir -p "$HOME/.claude"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
OSRC_SOURCED=1; export OSRC_SOURCED; set --; . "$SRC" >/dev/null 2>&1

SETTINGS="$HOME/.claude/settings.json"
cat > "$SETTINGS" <<'JSON'
{"model":"opus","effortLevel":"medium","modelSettings":{"claude-opus-5-5":{"effortLevel":"medium","autoCompactWindow":500000}},"permissions":{"allow":["Bash(ls)"]},"env":{"OSRC_TEST_MARKER":"keep-me"}}
JSON
SNAP="$(shasum -a 256 "$SETTINGS" 2>/dev/null || cksum "$SETTINGS")"

# Fake tmux: session exists, capture returns a benign non-menu pane, send-keys is logged.
SEND_LOG="$TMP/send.log"; : > "$SEND_LOG"
CAPTURE_FILE="$TMP/capture"; printf 'working on the thing\n' > "$CAPTURE_FILE"
tmux() {
  case "$1" in
    has-session) return 0 ;;
    capture-pane) cat "$CAPTURE_FILE" 2>/dev/null; return 0 ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG"; return 0 ;;
    display-message) printf '4242\n'; return 0 ;;
    *) return 0 ;;
  esac
}

# Registry records: one cc session, one codex session, written directly (start-event tmux
# probes are irrelevant to the guard and would slow the suite).
mkdir -p "$OSRC_HOME/sessions"
printf '%s\n' \
  '{"schema_version":"1","event":"start","session_id":"sess-cc","provider":"cc","model":"fable","effort":"medium","state":"running","receipt":"","endpoint":"tmux:sess-cc","ts":"2026-11-13T00:00:00Z"}' \
  '{"schema_version":"1","event":"start","session_id":"sess-cx","provider":"codex","model":"sol","effort":"medium","state":"running","receipt":"","endpoint":"tmux:sess-cx","ts":"2026-11-13T00:00:00Z"}' \
  > "$OSRC_SESSION_REGISTRY"

# ---- the guard itself, unit level ---------------------------------------------------------

_session_send_effort_guard sess-cc "/effort high"; rc=$?
[ "$rc" -eq 1 ] && ok "guard refuses /effort high on a cc session" || bad "guard allowed /effort on cc (rc=$rc)"

_session_send_effort_guard sess-cc "/effort"; rc=$?
[ "$rc" -eq 1 ] && ok "guard refuses bare /effort on a cc session" || bad "guard allowed bare /effort on cc (rc=$rc)"

_session_send_effort_guard sess-cc "  /effort xhigh  "; rc=$?
[ "$rc" -eq 1 ] && ok "guard trims surrounding space before matching" || bad "guard missed spaced /effort (rc=$rc)"

_session_send_effort_guard sess-cx "/effort high"; rc=$?
[ "$rc" -eq 0 ] && ok "guard allows /effort on a non-claude session" || bad "guard refused /effort on codex (rc=$rc)"

_session_send_effort_guard sess-cc "please read /effort docs and tell me"; rc=$?
[ "$rc" -eq 0 ] && ok "guard allows /effort inside prose (not a leading command)" || bad "guard refused prose mention (rc=$rc)"

_session_send_effort_guard sess-cc "run the tests now"; rc=$?
[ "$rc" -eq 0 ] && ok "guard allows ordinary text" || bad "guard refused ordinary text (rc=$rc)"

_session_send_effort_guard sess-cc "/effortful ideas"; rc=$?
[ "$rc" -eq 0 ] && ok "guard allows /effortful (word boundary required)" || bad "guard refused /effortful (rc=$rc)"

_session_send_effort_guard sess-cc "/EFFORT high"; rc=$?
[ "$rc" -eq 1 ] && ok "guard refuses uppercase /EFFORT too" || bad "guard missed /EFFORT (rc=$rc)"

# ---- footer proof: no registry record, no provider flag, but the pane IS claude ------------
# An external/unmanaged claude pane has no start record; the live footer is the only proof.
printf 'Opus 5 | high | /repo | ContextQ: 42%% used\n' > "$CAPTURE_FILE"
_session_send_effort_guard sess-ext "/effort max"; rc=$?
[ "$rc" -eq 1 ] && ok "guard refuses on claude footer proof with no registry record" \
  || bad "guard missed unmanaged claude pane (rc=$rc)"

printf 'working on the thing\n' > "$CAPTURE_FILE"
_session_send_effort_guard sess-ext "/effort max"; rc=$?
[ "$rc" -eq 0 ] && ok "guard allows /effort when the pane is provably not claude" || bad "guard refused non-claude pane (rc=$rc)"

# ---- through the real `session send` dispatch (subshell: die exits) ------------------------
out="$(SESSION_NAME=sess-cc session send "/effort high" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'session effort' \
  && ok "session send refuses /effort on cc and names the safe path" \
  || bad "session send did not refuse (rc=$rc): [$out]"
! grep -q '/effort' "$SEND_LOG" \
  && ok "no /effort keystrokes reached the pane" \
  || bad "send-keys log shows /effort was typed: $(cat "$SEND_LOG")"

out="$(SESSION_NAME=sess-cx session send "/effort high" 2>&1)"; rc=$?
# A codex send gets PAST the guard into _managed_session_send, which then fails endpoint
# proof in this fixture — what matters is the refusal reason is NOT the effort guard.
printf '%s' "$out" | grep -q 'effortLevel into' \
  && bad "codex send was refused by the effort guard: [$out]" \
  || ok "codex send is not stopped by the effort guard (fails later on endpoint proof, as expected)"

# ---- the settings file is never touched -----------------------------------------------------
NOW="$(shasum -a 256 "$SETTINGS" 2>/dev/null || cksum "$SETTINGS")"
[ "$NOW" = "$SNAP" ] \
  && ok "settings.json byte-identical after every guard path" \
  || bad "settings.json changed!"

# Absent settings.json: the guard must still refuse (it never needed the file) and must not create one.
rm -f "$SETTINGS"
_session_send_effort_guard sess-cc "/effort low"; rc=$?
[ "$rc" -eq 1 ] && [ ! -e "$SETTINGS" ] \
  && ok "guard refuses with settings.json absent and creates nothing" \
  || bad "guard behaved wrongly with settings.json absent (rc=$rc)"

# ---- the per-session path itself: cc relaunch is env-scoped, never a settings write ----------
Relaunch_out="$(_session_relaunch_cc fable high 2>/dev/null)"
printf '%s' "$Relaunch_out" | grep -q 'MAX_THINKING_TOKENS=24000' \
  && printf '%s' "$Relaunch_out" | grep -q 'claude' \
  && ok "session effort relaunch carries MAX_THINKING_TOKENS (env, per-process)" \
  || bad "cc relaunch lost the env effort: [$Relaunch_out]"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
