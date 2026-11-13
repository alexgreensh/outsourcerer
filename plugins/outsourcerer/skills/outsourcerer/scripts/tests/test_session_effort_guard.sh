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
# display-message answers by format: FAKE_PANE_CMD is the pane's foreground command
# (default "codex" = identified non-claude; set to "" for an unidentifiable pane),
# FAKE_PANE_PID feeds the process-tree walk (default a pid that cannot exist).
SEND_LOG="$TMP/send.log"; : > "$SEND_LOG"
CAPTURE_FILE="$TMP/capture"; printf 'working on the thing\n' > "$CAPTURE_FILE"
tmux() {
  local last; for last; do :; done
  case "$1" in
    has-session) return 0 ;;
    capture-pane) cat "$CAPTURE_FILE" 2>/dev/null; return 0 ;;
    send-keys) printf 'SEND: %s\n' "$*" >> "$SEND_LOG"; return 0 ;;
    display-message)
      case "$last" in
        *pane_current_command*) printf '%s\n' "${FAKE_PANE_CMD-codex}"; return 0 ;;
        *pane_current_path*) printf '%s\n' "${FAKE_PANE_CWD-$PWD}"; return 0 ;;
        *pane_pid*) printf '%s\n' "${FAKE_PANE_PID-99999999}"; return 0 ;;
        *) printf '4242\n'; return 0 ;;
      esac ;;
    *) return 0 ;;
  esac
}

# Stubbed claude bin: --help advertises --effort unless $OSRC_TEST_NO_EFFORT_FLAG
# names an existing file (the "older claude" case). NEVER the real claude.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  printf 'Usage: claude [options]\n  --model <model>\n  -c, --continue  Continue the most recent conversation\n'
  [ -f "${OSRC_TEST_NO_EFFORT_FLAG:-/nonexistent-osrc-path}" ] || printf '  --effort <level>  Effort level for the current session\n'
fi
exit 0
EOF
chmod +x "$TMP/bin/claude"
PATH="$TMP/bin:$PATH"; export PATH
export OSRC_TEST_NO_EFFORT_FLAG="$TMP/no-effort-flag"

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

# ---- pane identity: stock claude screen, no registry record -------------------------------
# A stock Claude Code screen has NO ContextQ footer; pane_current_command is the proof.
FAKE_PANE_CMD=claude
printf 'working on the thing\n' > "$CAPTURE_FILE"
_session_send_effort_guard sess-stock "/effort high"; rc=$?
[ "$rc" -eq 1 ] && ok "guard refuses /effort when pane_current_command is claude (stock screen, no record)" \
  || bad "guard missed stock claude pane (rc=$rc)"

# Unidentifiable pane (no command, dead pid, no footer, no record): fail closed.
FAKE_PANE_CMD=
_session_send_effort_guard sess-mystery "/effort high"; rc=$?
[ "$rc" -eq 1 ] && ok "guard fails closed when the pane cannot be identified" \
  || bad "guard allowed /effort on an unidentified pane (rc=$rc)"

# Identified non-claude with no record at all: allowed.
FAKE_PANE_CMD=codex
_session_send_effort_guard sess-mystery "/effort high"; rc=$?
[ "$rc" -eq 0 ] && ok "guard allows /effort on an identified non-claude pane" \
  || bad "guard refused identified codex pane (rc=$rc)"

# Wrapper foreground (bash) with claude underneath in the process tree: refused.
FAKE_PANE_CMD=bash; FAKE_PANE_PID=9999
ps() { local last; for last; do :; done; case "$last" in 9999) printf '%s\n' -- '-zsh';; 9998) printf '%s\n' 'claude --model fable';; *) printf '%s\n' 'sleep 30';; esac; }
pgrep() { local last; for last; do :; done; [ "$last" = 9999 ] && printf '9998\n'; return 0; }
_session_send_effort_guard sess-wrap "/effort high"; rc=$?
unset -f ps pgrep
FAKE_PANE_PID=99999999; FAKE_PANE_CMD=codex
[ "$rc" -eq 1 ] && ok "guard refuses when the pane's process tree runs claude" \
  || bad "guard missed claude in the pane process tree (rc=$rc)"

# Remote shells are refused outright: a claude on the far side of ssh/mosh is
# invisible to every local check and /effort would change THAT machine's settings.
FAKE_PANE_CMD=ssh
_session_send_effort_guard sess-remote "/effort high"; rc=$?
[ "$rc" -eq 1 ] && ok "guard refuses /effort into an ssh pane" \
  || bad "guard allowed /effort into ssh (rc=$rc)"
FAKE_PANE_CMD=mosh
_session_send_effort_guard sess-remote "/effort high"; rc=$?
[ "$rc" -eq 1 ] && ok "guard refuses /effort into a mosh pane" \
  || bad "guard allowed /effort into mosh (rc=$rc)"
FAKE_PANE_CMD=ssh
_session_send_effort_guard sess-remote "/effort high" 1; rc=$?
[ "$rc" -eq 0 ] && ok "allow flag overrides even an ssh pane (per-invocation)" \
  || bad "allow flag did not override ssh refusal (rc=$rc)"
FAKE_PANE_PID=99999999; FAKE_PANE_CMD=codex

# Explicit per-command override for a pane proven not to be Claude Code. The old
# env switch is gone on purpose: set once in a shell it stayed armed for every
# later send on every pane.
_session_send_effort_guard sess-cc "/effort high" 1; rc=$?
[ "$rc" -eq 0 ] && ok "allow flag overrides the guard for this send" \
  || bad "allow flag did not bypass the guard (rc=$rc)"
( OSRC_SEND_ALLOW_EFFORT=1; _session_send_effort_guard sess-cc "/effort high" ); rc=$?
[ "$rc" -eq 1 ] && ok "the retired env switch no longer disarms the guard" \
  || bad "OSRC_SEND_ALLOW_EFFORT still overrides (rc=$rc)"

out="$(SESSION_NAME=sess-cc session send --allow-effort "/effort high" 2>&1)"
printf '%s' "$out" | grep -q 'effortLevel into' \
  && bad "--allow-effort did not get past the guard at dispatch: [$out]" \
  || ok "session send --allow-effort gets past the guard"

# session reply parses the same flag and forwards it to _external_reply.
_external_reply() { printf 'REPLYARGS:%s\n' "$*"; return 0; }
out="$(session reply --allow-effort ext-1 hello world 2>&1)"
printf '%s' "$out" | grep -q 'REPLYARGS:ext-1 hello world 1' \
  && ok "session reply --allow-effort forwards the flag" \
  || bad "reply flag not forwarded: [$out]"
unset -f _external_reply

# ---- the per-session path: env cap + session-scoped --effort + --continue ---------------
Relaunch_out="$(_session_relaunch_cc fable high 2>/dev/null)"
printf '%s' "$Relaunch_out" | grep -q 'MAX_THINKING_TOKENS=24000' \
  && printf '%s' "$Relaunch_out" | grep -q -- '--effort high' \
  && printf '%s' "$Relaunch_out" | grep -q -- '--continue' \
  && ok "cc relaunch carries env cap + --effort high + --continue" \
  || bad "cc relaunch missing session-scoped effort/continue: [$Relaunch_out]"

Relaunch_min="$(_session_relaunch_cc fable minimal 2>/dev/null)"
printf '%s' "$Relaunch_min" | grep -q -- '--effort low' \
  && printf '%s' "$Relaunch_min" | grep -q 'MAX_THINKING_TOKENS=0' \
  && ok "minimal/none map to --effort low with the zero env cap" \
  || bad "minimal mapping wrong: [$Relaunch_min]"

Cmd_out="$(_session_relaunch_command cc fable high 2>/dev/null)"
printf '%s' "$Cmd_out" | grep -q -- '--effort high' \
  && printf '%s' "$Cmd_out" | grep -q -- '--continue' \
  && ok "session effort dispatch builds --effort + --continue for cc" \
  || bad "relaunch command lost the flags: [$Cmd_out]"

# ---- --resume pins THIS pane's conversation; --continue is only the fallback -----------
SID="3f8a2c1e-9b4d-4e5f-a6b7-c8d9e0f1a2b3"
Relaunch_res="$(_session_relaunch_cc fable high "$SID" 2>/dev/null)"
printf '%s' "$Relaunch_res" | grep -q -- "--resume $SID" \
  && ! printf '%s' "$Relaunch_res" | grep -q -- '--continue' \
  && ok "relaunch with a known session id uses --resume <id>, not --continue" \
  || bad "resume-id relaunch wrong: [$Relaunch_res]"

Cmd_res="$(_session_relaunch_command cc fable high "$SID" 2>/dev/null)"
printf '%s' "$Cmd_res" | grep -q -- "--resume $SID" \
  && ok "dispatch relaunch command carries --resume <id>" \
  || bad "relaunch command lost --resume: [$Cmd_res]"

# An invalid id falls back to --continue rather than emitting a bad flag.
Relaunch_badid="$(_session_relaunch_cc fable high 'bad id!!' 2>/dev/null)"
printf '%s' "$Relaunch_badid" | grep -q -- '--continue' \
  && ! printf '%s' "$Relaunch_badid" | grep -q -- '--resume' \
  && ok "invalid resume id falls back to --continue" \
  || bad "invalid id not handled: [$Relaunch_badid]"

# _session_cc_resume_id: registry cc_session_id fallback, live sessions-dir proof.
printf '%s\n' '{"schema_version":"1","event":"start","session_id":"sess-resume","provider":"cc","model":"fable","effort":"high","state":"running","receipt":"","endpoint":"tmux:sess-resume","cc_session_id":"reg-sid-1","cc_pid":4242,"cwd":"/tmp/x","ts":"2026-11-13T00:00:00Z"}' >> "$OSRC_SESSION_REGISTRY"
mkdir -p "$HOME/.claude/sessions"   # deliberately empty: live lookup finds nothing
got="$(_session_cc_resume_id sess-resume 2>/dev/null)"
[ "$got" = "reg-sid-1" ] && ok "resume id falls back to the registry cc_session_id" \
  || bad "registry fallback gave [$got]"

# Live proof beats the registry: a ~/.claude/sessions file for a pid inside the
# pane resolves the CURRENT sessionId (registry can be one respawn stale).
printf '{"pid":9998,"cwd":"%s","startedAt":%s,"sessionId":"live-sid-1","procStart":"x"}\n' \
  "$(pwd -P)" "$(( $(date +%s) * 1000 ))" > "$HOME/.claude/sessions/9998.json"
FAKE_PANE_PID=9999
ps() { case "$*" in *ppid*9998*) printf ' 9999\n';; *) printf '\n';; esac; }
got="$(_session_cc_resume_id sess-resume 2>/dev/null)"
unset -f ps
FAKE_PANE_PID=99999999
[ "$got" = "live-sid-1" ] && ok "live ~/.claude/sessions proof beats the registry id" \
  || bad "live lookup gave [$got]"

# Wiring: _session_control_relaunch resolves the id and hands it to the vector.
CAPTURE_ARGS="$TMP/relaunch-args"; : > "$CAPTURE_ARGS"
_session_relaunch_command() { printf '%s\n' "$*" > "$CAPTURE_ARGS"; printf 'stub-launch'; }
OSRC_CONTROL_VERIFY_POLLS=1 _session_control_relaunch sess-resume cc fable high >/dev/null 2>&1 || true
unset -f _session_relaunch_command
# pane_pid is the dead default -> live lookup misses -> registry id is what ships.
grep -q 'reg-sid-1' "$CAPTURE_ARGS" \
  && ok "control relaunch hands the pane's cc sessionId to the relaunch vector" \
  || bad "relaunch vector did not get the session id: [$(cat "$CAPTURE_ARGS")]"

# Older claude without --effort in --help: env cap still applies, flag omitted.
touch "$OSRC_TEST_NO_EFFORT_FLAG"
Relaunch_old="$(_session_relaunch_cc fable high 2>/dev/null)"
printf '%s' "$Relaunch_old" | grep -q 'MAX_THINKING_TOKENS=24000' \
  && ! printf '%s' "$Relaunch_old" | grep -q -- '--effort' \
  && ok "claude without --effort keeps the env cap and omits the flag" \
  || bad "unsupported-claude relaunch wrong: [$Relaunch_old]"
rm -f "$OSRC_TEST_NO_EFFORT_FLAG"

# Session START path: same session-scoped flag when EFFORT is set.
MODEL=fable; MODEL_EXPLICIT=0; EFFORT=high; SESSION_LAUNCH=()
_session_launch_cc 2>/dev/null
joined="$(printf '%s ' "${SESSION_LAUNCH[@]}")"
printf '%s' "$joined" | grep -q -- '--effort high' \
  && ok "session start launch includes --effort high" \
  || bad "start launch missing --effort: [$joined]"

touch "$OSRC_TEST_NO_EFFORT_FLAG"; EFFORT=high; SESSION_LAUNCH=()
_session_launch_cc 2>/dev/null
joined="$(printf '%s ' "${SESSION_LAUNCH[@]}")"
! printf '%s' "$joined" | grep -q -- '--effort' \
  && printf '%s' "$joined" | grep -q 'MAX_THINKING_TOKENS=24000' \
  && ok "start on old claude keeps env cap, omits --effort" \
  || bad "start launch on old claude wrong: [$joined]"
rm -f "$OSRC_TEST_NO_EFFORT_FLAG"
EFFORT=minimal; SESSION_LAUNCH=()
_session_launch_cc 2>/dev/null
joined="$(printf '%s ' "${SESSION_LAUNCH[@]}")"
printf '%s' "$joined" | grep -q -- '--effort low' \
  && ok "start maps minimal -> --effort low" \
  || bad "start minimal mapping wrong: [$joined]"
unset EFFORT MODEL MODEL_EXPLICIT SESSION_LAUNCH

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
