#!/usr/bin/env bash
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
ok() { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
case "${1:-}" in has-session) exit 0 ;; esac
exit 0
EOF
cat > "$BIN/droid" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  printf '%s\n' '  -r, --reasoning <level>  Reasoning effort'
fi
EOF
chmod +x "$BIN/tmux"
chmod +x "$BIN/droid"
export PATH="$BIN:$PATH"
export TMUX_LOG="$TMP/tmux.log"

set --
. "$SRC" >/dev/null 2>&1
trap cleanup EXIT

SESSION_NAME=effort-test
PROVIDER=codex
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
out="$(session effort high 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'receipt.*relaunch' \
   && grep -q 'model_reasoning_effort=high' "$TMUX_LOG" \
   && tail -1 "$OSRC_SESSION_REGISTRY" | jq -e '.effort == "high" and .receipt == "relaunch"' >/dev/null; then
  ok "codex relaunch records effort and receipt"
else
  bad "codex effort relaunch was not recorded truthfully: rc=$rc out=$out"
fi

PROVIDER=devin
out="$(session effort low 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi 'advisory' \
   && ! printf '%s' "$out" | grep -qi 'native-success\|live-applied' \
   && tail -1 "$OSRC_SESSION_REGISTRY" | jq -e '.effort == "low" and .receipt == "advisory"' >/dev/null; then
  ok "Devin effort remains advisory"
else
  bad "Devin effort receipt is not advisory: rc=$rc out=$out"
fi

PROVIDER=droid
: > "$TMUX_LOG"
out="$(session effort xhigh 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'receipt.*relaunch' \
   && grep -q -- '-r high' "$TMUX_LOG" \
   && tail -1 "$OSRC_SESSION_REGISTRY" | jq -e '.effort == "xhigh" and .receipt == "relaunch"' >/dev/null; then
  ok "Droid relaunch uses its advertised effort control"
else
  bad "Droid effort relaunch was not recorded truthfully: rc=$rc out=$out"
fi

PROVIDER=gemini
out="$(session effort medium 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi 'advisory' \
   && ! printf '%s' "$out" | grep -qi 'native-success\|live-applied'; then
  ok "Gemini effort remains advisory"
else
  bad "Gemini effort receipt is not advisory: rc=$rc out=$out"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
