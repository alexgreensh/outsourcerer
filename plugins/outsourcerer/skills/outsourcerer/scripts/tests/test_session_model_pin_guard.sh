#!/usr/bin/env bash
# test_session_model_pin_guard.sh — the GENERAL model-pin guard for interactive sessions.
#
# The droid bug (P0 quota leak): the droid session lane appended --model to interactive `droid` on
# the strength of an unverified comment. `droid --help` has NO -m/--model (it lives under
# `droid exec`), so --model fell through into the prompt and the run billed Claude quota on the
# DEFAULT model (claude-opus-5). The fix generalizes the lesson: a lane may only append a model
# flag to an interactive launch when its own CLI documents that flag at the level being invoked;
# otherwise it must REFUSE loudly, naming the lane, never start on the default and bill silently.
#
# This test exercises the guard machinery (_session_help_has_model_flag +
# _session_assert_model_pinnable) with FAKE CLIs so the behavior is deterministic and does not
# depend on which real CLIs happen to be installed:
#   - a lane whose help documents --model  -> guard passes (returns 0, silent)
#   - a lane whose help documents -m only   -> guard passes (short form recognized)
#   - a lane whose help has NO model flag   -> guard REFUSES, naming the lane + "model"
#   - a lane whose help probe FAILS         -> guard REFUSES (no proof = not supported)
#   - a flag-like word that is NOT a model flag (--mode, -mode) must NOT false-positive
# Run: bash test_session_model_pin_guard.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-mpg.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home"; export OSRC_SOURCED=1; mkdir -p "$OSRC_HOME"
BIN="$TMP/bin"; mkdir -p "$BIN"

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

# --- fake CLIs for the assert_model_pinnable probe ---
# has-long:  documents --model <id>
cat > "$BIN/has-long" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] || exit 0
cat <<'HELP'
Usage: has-long [options]
  --model <id>   Model to use
  -h, --help     Show help
HELP
EOF
# has-short: documents only -m <model> (the short form)
cat > "$BIN/has-short" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] || exit 0
cat <<'HELP'
Usage: has-short [options]
  -m <model>   Override model
  -h, --help   Show help
HELP
EOF
# noflag: documents NO model flag (the droid shape)
cat > "$BIN/noflag" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] || exit 0
cat <<'HELP'
Usage: noflag [options] [prompt...]
  --auto <level>   Autonomy
  -h, --help       Show help
HELP
EOF
# near-miss: has --mode and -mode (must NOT match a model flag)
cat > "$BIN/near-miss" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] || exit 0
cat <<'HELP'
Usage: near-miss [options]
  --mode <mode>   Run mode
  -mode           Short mode
  -h, --help      Show help
HELP
EOF
# probe-fail: --help exits non-zero (simulates a broken/timed-out CLI)
cat > "$BIN/probe-fail" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

. "$SRC" >/dev/null 2>&1
type -t _session_help_has_model_flag   >/dev/null || { echo "FAIL: _session_help_has_model_flag not loaded"; exit 1; }
type -t _session_assert_model_pinnable >/dev/null || { echo "FAIL: _session_assert_model_pinnable not loaded"; exit 1; }

# --- _session_help_has_model_flag: pure text matcher ---
_session_help_has_model_flag "  --model <id>   Model" \
  && ok "has_model_flag: --model <id> recognized" || no "has_model_flag: --model <id> missed"
_session_help_has_model_flag "  -m, --model <MODEL>  Model" \
  && ok "has_model_flag: '-m, --model' recognized" || no "has_model_flag: '-m, --model' missed"
_session_help_has_model_flag "  -m <model>   Override model" \
  && ok "has_model_flag: short -m <model> recognized" || no "has_model_flag: short -m missed"
_session_help_has_model_flag "  --model=<id>   Model" \
  && ok "has_model_flag: --model=<id> recognized" || no "has_model_flag: --model=<id> missed"
if _session_help_has_model_flag "  --auto <level>   Autonomy"; then
  no "has_model_flag: --auto falsely matched as a model flag"
else
  ok "has_model_flag: --auto correctly NOT matched"
fi
if _session_help_has_model_flag "  --mode <mode>   Run mode"$'\n'"  -mode           Short mode"; then
  no "has_model_flag: --mode / -mode falsely matched as a model flag (near-miss)"
else
  ok "has_model_flag: --mode / -mode correctly NOT matched (near-miss rejected)"
fi

# --- _session_assert_model_pinnable: probe + refuse ---
# Passes silently when the flag is documented (long form).
if ( _session_assert_model_pinnable fakelong has-long --help ) 2>"$TMP/e1"; then
  ok "assert_model_pinnable: lane with --model passes (long form)"
else
  no "assert_model_pinnable: lane with --model wrongly refused: $(cat "$TMP/e1")"
fi
# Passes silently when the flag is documented (short form only).
if ( _session_assert_model_pinnable fakeshort has-short --help ) 2>"$TMP/e2"; then
  ok "assert_model_pinnable: lane with -m only passes (short form)"
else
  no "assert_model_pinnable: lane with -m only wrongly refused: $(cat "$TMP/e2")"
fi
# REFUSES when no model flag is documented (the droid shape), naming the lane + "model".
_rc=0; ( _session_assert_model_pinnable droid noflag --help ) >"$TMP/o3" 2>"$TMP/e3" || _rc=$?
if [ "$_rc" -ne 0 ] && grep -qi 'droid' "$TMP/e3" && grep -qi 'model' "$TMP/e3"; then
  ok "assert_model_pinnable: lane with NO model flag REFUSES naming the lane + model"
else
  no "assert_model_pinnable: lane with NO model flag did not refuse correctly: rc=$_rc err=$(cat "$TMP/e3")"
fi
# REFUSES when the probe itself fails (no proof = not supported), naming the lane.
_rc=0; ( _session_assert_model_pinnable broken probe-fail --help ) >"$TMP/o4" 2>"$TMP/e4" || _rc=$?
if [ "$_rc" -ne 0 ] && grep -qi 'broken' "$TMP/e4"; then
  ok "assert_model_pinnable: a FAILED probe REFUSES (no proof = not supported), naming the lane"
else
  no "assert_model_pinnable: a failed probe did not refuse correctly: rc=$_rc err=$(cat "$TMP/e4")"
fi
# Near-miss (--mode / -mode) must REFUSE — it is not a model flag.
_rc=0; ( _session_assert_model_pinnable near near-miss --help ) >"$TMP/o5" 2>"$TMP/e5" || _rc=$?
if [ "$_rc" -ne 0 ]; then
  ok "assert_model_pinnable: --mode/-mode (near-miss) REFUSES (not a model flag)"
else
  no "assert_model_pinnable: --mode/-mode wrongly passed as a model flag"
fi

# --- source-level: the guard is wired into BOTH session-start switches for the lanes that build
#     their launch inline (devin/codex/cc/gemini), so a future CLI dropping --model can't bill
#     silently on those lanes either. droid refuses unconditionally inside the adapter. ---
_n_assert=$(grep -c '_session_assert_model_pinnable' "$SRC")
[ "$_n_assert" -ge 9 ] \
  && ok "guard wired in >=9 sites (helper def + droid-refuse comment-free + devin/codex/cc/gemini x2 switches): $_n_assert" \
  || no "guard not wired into all session-start switches (found $_n_assert references, want >=9)"
# droid must NOT append --model in the adapter (the bug shape is gone).
if grep -A30 '^    droid)' "$SRC" | grep -q 'SESSION_LAUNCH+=("--model"'; then
  no "droid adapter still appends --model (the bug is NOT fixed)"
else
  ok "droid adapter no longer appends --model to the interactive launch"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
