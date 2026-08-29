#!/bin/bash
# test_codex_code_mode_host.sh — BUG 3: the code_mode_host self-heal must be BIDIRECTIONAL.
#
# The old code only handled one direction: binary missing -> pass -c features.code_mode_host=false.
# The inverse bit: binary present but user's ~/.codex/config.toml says code_mode_host=false. Codex 0.150
# routes the shell tool through code mode, so every command failed with "code-mode host is disabled".
# The interactive session lane does NOT pass --ignore-user-config, so it inherits the stale config.
#
# Fix: ALWAYS pass -c features.code_mode_host=<true|false> explicitly. =true when the binary IS
# present (overrides a stale config=false), =false when absent (so file reads don't hang).
#
# Tests:
#   (a) _codex_code_mode_host_flag echoes "true" when the binary is present.
#   (b) _codex_code_mode_host_flag echoes "false" when the binary is absent.
#   (c) delegate_cxnative passes -c features.code_mode_host=true when binary is present.
#   (d) delegate_cxnative passes -c features.code_mode_host=false when binary is absent.
#   (e) The interactive tmux/winpty session lanes pass the flag (the key bug: no --ignore-user-config).
#   (f) Structural: every call site uses the bidirectional pattern (no old single-direction pattern).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TMP="$(mktemp -d)"
export OSRC_HOME="$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Load the source so the functions are defined. main is not run.
. "$SRC" >/dev/null 2>&1

echo "=== (a)(b) _codex_code_mode_host_flag: true when present, false when absent ==="
{
  # (a) Binary present: create a fake codex-code-mode-host on PATH.
  _FAKE_BIN="$TMP/fake-bin"
  mkdir -p "$_FAKE_BIN"
  cat > "$_FAKE_BIN/codex-code-mode-host" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$_FAKE_BIN/codex-code-mode-host"

  # Reset the cache and test with the fake binary on PATH.
  _OSRC_CODEMODE=""
  _FLAG_A="$(PATH="$_FAKE_BIN:$PATH" _codex_code_mode_host_flag)"
  if [ "$_FLAG_A" = "true" ]; then
    ok "(a) _codex_code_mode_host_flag echoes 'true' when binary is present"
  else
    bad "(a) _codex_code_mode_host_flag should echo 'true', got '$_FLAG_A'"
  fi

  # (b) Binary absent: reset cache, use a PATH without the fake binary, and HOME without it.
  _OSRC_CODEMODE=""
  _FLAG_B="$(PATH="/usr/bin:/bin" HOME="$TMP/empty-home" _codex_code_mode_host_flag)"
  if [ "$_FLAG_B" = "false" ]; then
    ok "(b) _codex_code_mode_host_flag echoes 'false' when binary is absent"
  else
    bad "(b) _codex_code_mode_host_flag should echo 'false', got '$_FLAG_B'"
  fi
}

echo ""
echo "=== (c)(d) delegate_cxnative passes the flag in both directions ==="
{
  # Mock the functions delegate_cxnative calls (same pattern as test_no_silent_escalation.sh).
  _tier_banner() { :; }
  record_ledger() { :; }
  _codex_quota_line() { :; }
  resolve_tier() { echo "mid"; }
  _build_prompt() { printf '%s' "$2"; }
  _lane_cost_disclosure() { echo "$1"; }
  _timeout() { shift; "$@"; }   # pass through

  # delegate_cxnative uses global REST[] and RESOLVED_ID, not args for the task.
  REST=("test task")
  RESOLVED_ID="sol"

  # Capture the codex exec args. Defining codex() also makes `have codex` return 0.
  CODEX_ARGS=""
  codex() { CODEX_ARGS="$*"; return 0; }

  # (c) Binary present -> flag should be true.
  _codex_code_mode_host() { return 0; }
  delegate_cxnative accept-edits >/dev/null 2>&1
  if printf '%s' "$CODEX_ARGS" | grep -q 'features.code_mode_host=true'; then
    ok "(c) delegate_cxnative passes -c features.code_mode_host=true when binary present"
  else
    bad "(c) delegate_cxnative missing features.code_mode_host=true (args=[$CODEX_ARGS])"
  fi

  # (d) Binary absent -> flag should be false.
  _codex_code_mode_host() { return 1; }
  delegate_cxnative accept-edits >/dev/null 2>&1
  if printf '%s' "$CODEX_ARGS" | grep -q 'features.code_mode_host=false'; then
    ok "(d) delegate_cxnative passes -c features.code_mode_host=false when binary absent"
  else
    bad "(d) delegate_cxnative missing features.code_mode_host=false (args=[$CODEX_ARGS])"
  fi

  # (c-extra) The self-heal notice only prints when binary is absent (false case).
  _codex_code_mode_host() { return 0; }
  _NOTICE_OUT="$(delegate_cxnative accept-edits 2>&1 >/dev/null)"
  if ! printf '%s' "$_NOTICE_OUT" | grep -q 'self-heal.*binary missing'; then
    ok "(c-extra) no self-heal notice when binary is present"
  else
    bad "(c-extra) self-heal notice printed when binary IS present (should not)"
  fi

  _codex_code_mode_host() { return 1; }
  _NOTICE_OUT="$(delegate_cxnative accept-edits 2>&1 >/dev/null)"
  if printf '%s' "$_NOTICE_OUT" | grep -q 'self-heal.*binary missing'; then
    ok "(d-extra) self-heal notice printed when binary is absent"
  else
    bad "(d-extra) self-heal notice missing when binary IS absent (notice=[$_NOTICE_OUT])"
  fi
}

echo ""
echo "=== (e) Interactive session lanes pass the flag (no --ignore-user-config) ==="
{
  # The interactive session lane (session start -m <codex-model>) does NOT pass --ignore-user-config,
  # so it inherits the user's config. The explicit -c features.code_mode_host=true is the ONLY thing
  # that overrides a stale config=false. Verify the launch string includes the flag.

  # tmux session lane: ccmh built from _codex_code_mode_host_flag + interpolated into launch.
  if grep -q 'ccmh=.*features.code_mode_host=$(_codex_code_mode_host_flag)' "$SRC" \
     && grep -q 'launch="codex .*workspace-write$ccmh"' "$SRC"; then
    ok "(e) tmux session lane: ccmh built from _codex_code_mode_host_flag + interpolated into launch"
  else
    bad "(e) tmux session lane: ccmh or launch wiring missing"
  fi

  # winpty session lane: _ccmh built from _codex_code_mode_host_flag + appended to LAUNCH.
  if grep -q '_ccmh=.*features.code_mode_host=$(_codex_code_mode_host_flag)' "$SRC" \
     && grep -q 'LAUNCH+=.*_ccmh' "$SRC"; then
    ok "(e) winpty session lane: _ccmh built from _codex_code_mode_host_flag + appended to LAUNCH"
  else
    bad "(e) winpty session lane: _ccmh or LAUNCH wiring missing"
  fi

  # Functional: build the launch string the same way the session start codex arm does, with the
  # binary present, and verify it contains features.code_mode_host=true (not false).
  _codex_code_mode_host() { return 0; }
  _OSRC_CODEMODE=""
  _ccmh_flag="$(_codex_code_mode_host_flag)"
  _test_launch="codex -m 'sol' -s workspace-write -c features.code_mode_host=$_ccmh_flag"
  if printf '%s' "$_test_launch" | grep -q 'features.code_mode_host=true'; then
    ok "(e) functional: session launch string has features.code_mode_host=true (binary present, overrides stale config)"
  else
    bad "(e) functional: session launch string has wrong flag (got $_ccmh_flag)"
  fi

  # And with the binary absent -> false.
  _codex_code_mode_host() { return 1; }
  _OSRC_CODEMODE=""
  _ccmh_flag="$(_codex_code_mode_host_flag)"
  _test_launch="codex -m 'sol' -s workspace-write -c features.code_mode_host=$_ccmh_flag"
  if printf '%s' "$_test_launch" | grep -q 'features.code_mode_host=false'; then
    ok "(e) functional: session launch string has features.code_mode_host=false (binary absent)"
  else
    bad "(e) functional: session launch string has wrong flag for absent binary (got $_ccmh_flag)"
  fi
}

echo ""
echo "=== (f) Structural: every call site uses the bidirectional pattern ==="
{
  # No old single-direction pattern should remain.
  if ! grep -q '_codex_code_mode_host ||' "$SRC"; then
    ok "(f) no old single-direction pattern (_codex_code_mode_host || ...) remains"
  else
    bad "(f) old single-direction pattern still present"
  fi

  # The helper function itself must be defined.
  if grep -q '^_codex_code_mode_host_flag()' "$SRC"; then
    ok "(f) _codex_code_mode_host_flag function is defined"
  else
    bad "(f) _codex_code_mode_host_flag function definition missing"
  fi

  # Every delegate path that invokes codex must pass the flag. 5 sites use the function directly,
  # 1 site (delegate_cxnative) stores it in a variable first (for the self-heal notice). Total = 6.
  _DIRECT_SITES="$(grep -c 'features.code_mode_host=$(_codex_code_mode_host_flag)' "$SRC" 2>/dev/null)"
  _VARIABLE_SITES="$(grep -c 'features.code_mode_host=\$_cmh_flag' "$SRC" 2>/dev/null)"
  _TOTAL=$((_DIRECT_SITES + _VARIABLE_SITES))
  if [ "$_TOTAL" -ge 6 ]; then
    ok "(f) features.code_mode_host flag passed at $_TOTAL sites (5 direct + 1 variable, expected >= 6)"
  else
    bad "(f) only $_TOTAL sites pass the flag ($_DIRECT_SITES direct + $_VARIABLE_SITES variable, expected >= 6)"
  fi

  # _codex_code_mode_host_flag referenced enough times (function def + call sites + comments).
  _NEW_COUNT="$(grep -c '_codex_code_mode_host_flag' "$SRC" 2>/dev/null)"
  if [ "$_NEW_COUNT" -ge 8 ]; then
    ok "(f) _codex_code_mode_host_flag referenced $_NEW_COUNT times (function + call sites + comments)"
  else
    bad "(f) _codex_code_mode_host_flag only referenced $_NEW_COUNT times (expected >= 8)"
  fi
}

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
