#!/usr/bin/env bash
# Session launch requires positive evidence that the selected CLI provides an interactive prompt.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TMP="$(mktemp -d)"
export HOME="$TMP/home"
export OSRC_HOME="$TMP/state"
BIN="$TMP/bin"
mkdir -p "$HOME" "$BIN"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

cat > "$BIN/droid" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] || exit 0
case "${DROID_HELP_MODE:-supported}" in
  supported)
    cat <<'HELP'
Usage: droid [options] [command] [prompt...]
  --auto <level>  Autonomy level: low|medium|high
  exec [prompt]   Run non-interactively (for scripts/automation)
  droid            Start interactive mode (default)
HELP
    ;;
  one-shot) echo 'exec [prompt]  Run non-interactively for automation' ;;
  fail) exit 7 ;;
esac
EOF

cat > "$BIN/cursor-agent" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] || exit 0
case "${CURSOR_HELP_MODE:-supported}" in
  supported)
    cat <<'HELP'
Cursor Agent
  -p, --print          Print responses for non-interactive use
  -m, --model <model>  Model to use
When starting in chat mode (default behavior), an initial prompt is optional.
HELP
    ;;
  one-shot) echo '--print  Run one prompt non-interactively' ;;
  fail) exit 8 ;;
esac
EOF

cat > "$BIN/hermes" <<'EOF'
#!/usr/bin/env bash
case "${HERMES_HELP_MODE:-supported}:${1:-}:${2:-}" in
  supported:--help:)
    cat <<'HELP'
  --cli        Force the classic prompt_toolkit REPL
  chat         Interactive or one-shot chat with the agent
  -z <prompt>  Scripted one-shot mode
HELP
    ;;
  supported:chat:--help)
    cat <<'HELP'
Usage: hermes chat [options]
  -q, --query <text>    One-shot, non-interactive prompt
  -m, --model <model>   Override the model for this run
HELP
    ;;
  one-shot:--help:) echo '-z <prompt>  Scripted one-shot mode' ;;
  one-shot:chat:--help) echo '--query <text>  One-shot prompt' ;;
  fail:*) exit 9 ;;
esac
EOF

cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
case "${1:-}" in has-session) exit 1 ;; esac
exit 0
EOF
chmod +x "$BIN/droid" "$BIN/cursor-agent" "$BIN/hermes" "$BIN/tmux"
export PATH="$BIN:$PATH"
export TMUX_LOG="$TMP/tmux.log"
export OSRC_CLOUD_ACK=1

set --
. "$SRC" >/dev/null 2>&1
trap cleanup EXIT

adapter_output() {
  local provider="$1" explicit="${2:-0}" model="${3:-default-model}"
  ( PROVIDER="$provider"; MODEL_EXPLICIT="$explicit"; MODEL="$model"
    SESSION_LAUNCH=()
    _session_launch_adapter
    printf '<%s>\n' "${SESSION_LAUNCH[@]}"
  ) 2>&1
}

out="$(adapter_output droid)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '<droid>' \
   && printf '%s' "$out" | grep -q '<--auto>' && printf '%s' "$out" | grep -q '<medium>'; then
  ok "Droid adapter selects its advertised interactive mode with bounded autonomy"
else
  bad "Droid supported probe did not produce the interactive launch: $out"
fi

out="$(adapter_output cursor 1 cursor-model)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '<cursor-agent>' \
   && printf '%s' "$out" | grep -q '<--model>' && printf '%s' "$out" | grep -q '<cursor-model>'; then
  ok "Cursor adapter preserves an advertised model override"
else
  bad "Cursor supported probe did not produce the interactive launch: $out"
fi

out="$(adapter_output hermes 1 provider/model)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '<hermes>' \
   && printf '%s' "$out" | grep -q '<chat>' && printf '%s' "$out" | grep -q '<provider/model>'; then
  ok "Hermes adapter selects interactive chat and preserves its model override"
else
  bad "Hermes supported probe did not produce the interactive launch: $out"
fi

out="$(adapter_output droid 1 unavailable-model)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '<droid>' \
   && printf '%s' "$out" | grep -q '<--model>' && printf '%s' "$out" | grep -q '<unavailable-model>'; then
  ok "Droid preserves a pinned model override"
else
  bad "Droid pinned model override did not produce the interactive launch: rc=$rc out=$out"
fi

for fixture in 'droid:DROID_HELP_MODE' 'cursor:CURSOR_HELP_MODE' 'hermes:HERMES_HELP_MODE'; do
  provider="${fixture%%:*}"; mode_var="${fixture#*:}"
  export "$mode_var=one-shot"
  out="$(adapter_output "$provider")"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'interactive' \
     && printf '%s' "$out" | grep -q ' run ' && printf '%s' "$out" | grep -q ' bg '; then
    ok "$provider rejects one-shot-only help and names run/bg alternatives"
  else
    bad "$provider accepted ambiguous one-shot help or omitted alternatives: rc=$rc out=$out"
  fi
  unset "$mode_var"
done

for provider in droid cursor hermes; do
  out="$(PATH=/usr/bin:/bin adapter_output "$provider")"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'PATH' \
     && printf '%s' "$out" | grep -q ' run ' && printf '%s' "$out" | grep -q ' bg '; then
    ok "$provider reports a missing CLI before launch and names run/bg alternatives"
  else
    bad "$provider did not fail closed when its CLI was missing: rc=$rc out=$out"
  fi
done

export DROID_HELP_MODE=fail
: > "$TMUX_LOG"
rm -rf "$OSRC_HOME/sessions"
out="$(PROVIDER=droid session start 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$TMUX_LOG" ] && [ ! -e "$OSRC_HOME/sessions" ]; then
  ok "a failing Unix probe creates no tmux or session state"
else
  bad "a failing Unix probe reached state creation: rc=$rc tmux=$(cat "$TMUX_LOG" 2>/dev/null)"
fi

rm -rf "$OSRC_HOME/sessions"
out="$(OSRC_PLATFORM=windows PROVIDER=droid _winpty_session start 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$OSRC_HOME/sessions" ]; then
  ok "the Windows launch path uses the same fail-closed adapter before state creation"
else
  bad "the Windows launch path created state after a failed probe: rc=$rc out=$out"
fi
unset DROID_HELP_MODE

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
