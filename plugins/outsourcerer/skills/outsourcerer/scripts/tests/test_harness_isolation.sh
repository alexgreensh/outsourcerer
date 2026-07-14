#!/bin/bash
# test_harness_isolation.sh — I1 invariant: a DELEGATED (headless) run must not inherit the user's
# live interactive harness surface (MCP servers, session/config) in a way that can wedge on
# interactive auth, bleed auth between lanes, or silently pull in unintended tools.
#
# Covers ALL headless delegate lanes:
#   - codex-exec lanes (codex-native, codex-openrouter, codex-image, local-agentic/codex,
#     run-or-codex.sh headless): --ignore-user-config gated by OSRC_CODEX_USER_CONFIG (v0.4.4).
#   - claude -p lanes (claude-native, cc/openrouter): --strict-mcp-config --mcp-config <empty>
#     by default via build_mcp_flags_cc (populates global array CC_MCP_FLAGS), gated by
#     OSRC_CLAUDE_USER_CONFIG (this patch). Fail-closed: nonzero return on setup failure.
#   - gemini -p lane: --allowed-mcp-server-names __none__ gated by OSRC_GEMINI_USER_MCP (this patch).
# Interactive session/TUI paths are OUT OF SCOPE (a human can answer prompts there).
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$DIR/outsourcerer.sh"
ORCODEX="$DIR/run-or-codex.sh"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

# ============================================================================
# CODEX LANES (v0.4.4 standard — regression guard)
# ============================================================================

# 1) Every REAL headless codex-exec invocation in the engine (matched by the actual command form
#    `codex exec --skip-git-repo-check` or `codex exec --cd`, not comments or `die` error strings)
#    carries the isolation flag on the same line: literal --ignore-user-config OR a gate array
#    expansion (iso/_iso/_or_iso). Comment lines (trimmed, starting with #) are excluded.
missing=0; sites=0
while IFS= read -r line; do
  trimmed="${line#"${line%%[![:space:]]*}"}"      # strip leading whitespace
  case "$trimmed" in \#*) continue ;; esac         # skip comments
  sites=$((sites+1))
  case "$line" in
    *"ignore-user-config"*|*'${iso['*|*'${_iso['*|*'${_or_iso['*) : ;;
    *) missing=$((missing+1)); echo "   unguarded: $line" ;;
  esac
done < <(grep -E 'codex exec --(skip-git-repo-check|cd) ' "$ENGINE")
# 4 delegate invocations (native/image/local/or); the doctor probe puts the flag first and is
# asserted separately in check #4 below.
{ [ "$missing" -eq 0 ] && [ "$sites" -ge 4 ]; } \
  && ok "codex: all $sites headless codex-exec delegate invocations carry the isolation gate" \
  || no "codex: $missing of $sites headless codex-exec invocation(s) missing --ignore-user-config"

# 2) The escape hatch exists and is spelled consistently everywhere it gates the flag.
n_gate="$(grep -c 'OSRC_CODEX_USER_CONFIG:-0.*ignore-user-config' "$ENGINE")"
[ "$n_gate" -ge 4 ] && ok "codex: OSRC_CODEX_USER_CONFIG opt-out gates the flag ($n_gate sites)" \
                    || no "codex: expected >=4 gated sites in engine, found $n_gate"

# 3) run-or-codex.sh: headless `codex exec` gets IUC; interactive TUI (`exec codex "..."`, no `exec`
#    subcommand) must NOT (–ignore-user-config is exec-only and would break the TUI).
# (headless invocation + its flag continuation line span 2 lines; check the block with -A2)
grep -A2 'exec codex exec --skip-git-repo-check' "$ORCODEX" | grep -q 'IUC\[@\]' \
  && ok "run-or-codex headless exec carries IUC" \
  || no "run-or-codex headless exec missing IUC"
if grep -Eq '^\s*exec codex "\$\{OR\[@\]\}"' "$ORCODEX"; then
  ok "run-or-codex interactive TUI does NOT pass the exec-only flag"
else
  no "run-or-codex TUI line changed — verify it does not pass --ignore-user-config"
fi

# 4) The doctor native-codex probe is isolated (a diagnostic must not wedge on MCP auth).
grep -Eq 'codex exec --ignore-user-config .*gpt-5.6-luna "reply PONG"' "$ENGINE" \
  && ok "doctor native-codex probe is isolated" \
  || no "doctor native-codex probe not isolated"

# ============================================================================
# CLAUDE -p LANES (claude-native, cc/openrouter — I1 parity, this patch)
# build_mcp_flags_cc populates global array CC_MCP_FLAGS with --strict-mcp-config --mcp-config <path>.
# Both delegate_ccnative and delegate_cc call it and use "${CC_MCP_FLAGS[@]+"${CC_MCP_FLAGS[@]}"}".
# ============================================================================

# 5) Structural: the isolation primitives exist in the engine.
grep -q '_emit_empty_mcp_cfg' "$ENGINE" \
  && ok "claude: _emit_empty_mcp_cfg isolation primitive present" \
  || no "claude: _emit_empty_mcp_cfg isolation primitive missing"
grep -q 'OSRC_CLAUDE_USER_CONFIG:-0' "$ENGINE" \
  && ok "claude: OSRC_CLAUDE_USER_CONFIG escape hatch present" \
  || no "claude: OSRC_CLAUDE_USER_CONFIG escape hatch missing"
grep -q 'CC_MCP_FLAGS' "$ENGINE" \
  && ok "claude: CC_MCP_FLAGS global array contract present" \
  || no "claude: CC_MCP_FLAGS global array contract missing"

# 6) Every headless `claude -p` delegate invocation in the engine carries the strict-MCP isolation
#    (via ${CC_MCP_FLAGS[@]} from build_mcp_flags_cc) OR --bare (which inherently drops MCP).
#    Match the actual `claude -p` command lines, excluding comments, the doctor probe (asserted
#    separately in #8), and the second-opinion/shim lines (those use --bare, asserted in #7).
missing_cc=0; sites_cc=0
while IFS= read -r line; do
  trimmed="${line#"${line%%[![:space:]]*}"}"
  case "$trimmed" in \#*) continue ;; esac
  case "$line" in
    *doctor*|*"reply PONG"*|*'_so_run'*|*'_local_agentic_shim'*) continue ;;
  esac
  sites_cc=$((sites_cc+1))
  # A guarded claude -p delegate line carries ${CC_MCP_FLAGS[@]} (the build_mcp_flags_cc output)
  # OR --bare (inherent isolation). The build_mcp_flags_cc call line is also guarded.
  case "$line" in
    *'CC_MCP_FLAGS'*|*'--bare'*|*'build_mcp_flags_cc'*) : ;;
    *) missing_cc=$((missing_cc+1)); echo "   unguarded claude -p: $line" ;;
  esac
done < <(grep -E 'claude -p ' "$ENGINE")
{ [ "$missing_cc" -eq 0 ] && [ "$sites_cc" -ge 2 ]; } \
  && ok "claude: all $sites_cc headless claude -p delegate invocations carry MCP isolation (CC_MCP_FLAGS or --bare)" \
  || no "claude: $missing_cc of $sites_cc headless claude -p invocation(s) missing MCP isolation"

# 7) The --bare paths (local-agentic/shim, second-opinion) are inherently isolated (no MCP auto-discovery).
grep -q 'claude -p --bare' "$ENGINE" \
  && ok "claude: --bare paths (shim/second-opinion) inherently isolated (no MCP auto-discovery)" \
  || no "claude: --bare paths missing (expected for shim/second-opinion)"

# 8) The doctor claude-native probe is isolated (a diagnostic must not wedge on MCP auth).
grep -Eq 'claude -p --strict-mcp-config --mcp-config .*reply PONG' "$ENGINE" \
  && ok "doctor claude-native probe is isolated (strict-empty MCP)" \
  || no "doctor claude-native probe not isolated"

# ============================================================================
# GEMINI -p LANE (gemini-cli fallback — I1 parity, this patch)
# delegate_gmnative gemini-cli path must pass --allowed-mcp-server-names __none__ by default,
# gated by OSRC_GEMINI_USER_MCP=1.
# ============================================================================

# 9) The gemini-cli delegate path carries the MCP isolation flag, gated by the escape hatch.
grep -q 'OSRC_GEMINI_USER_MCP:-0' "$ENGINE" \
  && ok "gemini: OSRC_GEMINI_USER_MCP escape hatch present" \
  || no "gemini: OSRC_GEMINI_USER_MCP escape hatch missing"
# The delegate invocation line must carry the gmcp array expansion (the gated flag).
grep -E 'gemini -p .*"\$\{gmcp\[@\]\}"' "$ENGINE" >/dev/null \
  && ok "gemini: delegate invocation carries gated --allowed-mcp-server-names (__none__)" \
  || no "gemini: delegate invocation missing gated MCP isolation"

# 10) The doctor gemini probe is isolated.
grep -Eq 'gemini -p "reply PONG" --allowed-mcp-server-names __none__' "$ENGINE" \
  && ok "doctor gemini probe is isolated (--allowed-mcp-server-names __none__)" \
  || no "doctor gemini probe not isolated"

# ============================================================================
# BEHAVIORAL TEST: execute build_mcp_flags_cc in a controlled temp env and assert its output.
# This is the REAL negative control Sol demanded: not just text-presence, but actual execution.
# We extract the function from the engine, source it, run it, and check the array + file contents.
# Then we MUTATE the function (remove the isolation) and verify the same assertion FAILS.
# ============================================================================
TMPDIR_ISOL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ISOL" 2>/dev/null' EXIT

# Extract die(), have(), CC_MCP_FLAGS=(), build_mcp_flags_cc(), _emit_empty_mcp_cfg() from the engine
# into a sourceable file. This lets us run the REAL function code in isolation.
EXTRACT="$TMPDIR_ISOL/funcs.sh"
{
  awk '/^die\(\)/,/^}/' "$ENGINE"
  awk '/^have\(\)/,/^}/' "$ENGINE"
  echo 'CC_MCP_FLAGS=()'
  # Extract build_mcp_flags_cc (from the comment block before the function through the closing brace)
  awk '/^# build_mcp_flags_cc/,/^}$/' "$ENGINE" | grep -v '^#'
  awk '/^# _emit_empty_mcp_cfg/,/^}$/' "$ENGINE" | grep -v '^#'
} > "$EXTRACT" 2>/dev/null

# Helper: run build_mcp_flags_cc with a given OSRC_HOME and return the result + array state.
# Sets $BEH_RC, $BEH_FLAGS, $BEH_CFGPATH, $BEH_CFG_CONTENTS in the caller's scope.
_run_beh() {
  local home="$1"; shift
  local extra_env="$1"; shift
  OSRC_HOME="$home" $extra_env build_mcp_flags_cc 2>/dev/null
  BEH_RC=$?
  BEH_FLAGS="${CC_MCP_FLAGS[*]:-}"
  BEH_CFGPATH="${CC_MCP_FLAGS[2]:-}"
  BEH_CFG_CONTENTS=""
  [ -n "$BEH_CFGPATH" ] && [ -f "$BEH_CFGPATH" ] && BEH_CFG_CONTENTS="$(cat "$BEH_CFGPATH" 2>/dev/null)"
}

# --- (a) DEFAULT: emits --strict-mcp-config --mcp-config <path> with {"mcpServers":{}} ---
source "$EXTRACT"
BEH_HOME="$TMPDIR_ISOL/beh-default"
_run_beh "$BEH_HOME" ""
if [ "$BEH_RC" -eq 0 ] \
  && [ "${CC_MCP_FLAGS[0]:-}" = "--strict-mcp-config" ] \
  && [ "${CC_MCP_FLAGS[1]:-}" = "--mcp-config" ] \
  && [ -n "$BEH_CFGPATH" ] && [ -f "$BEH_CFGPATH" ] \
  && [ "$BEH_CFG_CONTENTS" = '{"mcpServers":{}}' ]; then
  ok "behavioral: DEFAULT emits --strict-mcp-config --mcp-config <path> with {\"mcpServers\":{}} (file verified)"
else
  no "behavioral: DEFAULT failed (rc=$BEH_RC, flags=[$BEH_FLAGS], contents=[$BEH_CFG_CONTENTS])"
fi

# --- (b) escape hatch: OSRC_CLAUDE_USER_CONFIG=1 emits NOTHING ---
source "$EXTRACT"
BEH_HOME="$TMPDIR_ISOL/beh-escape"
OSRC_CLAUDE_USER_CONFIG=1 OSRC_HOME="$BEH_HOME" build_mcp_flags_cc 2>/dev/null
BEH_RC=$?
if [ "$BEH_RC" -eq 0 ] && [ "${#CC_MCP_FLAGS[@]}" -eq 0 ]; then
  ok "behavioral: OSRC_CLAUDE_USER_CONFIG=1 emits nothing (escape hatch works)"
else
  no "behavioral: escape hatch failed (rc=$BEH_RC, count=${#CC_MCP_FLAGS[@]}, flags=[${CC_MCP_FLAGS[*]:-}])"
fi
unset OSRC_CLAUDE_USER_CONFIG

# --- (c) fail-closed: unwritable OSRC_HOME returns nonzero (never silently emit no flags) ---
source "$EXTRACT"
BEH_HOME="/nonexistent-root-cannot-create/with mcp"
OSRC_HOME="$BEH_HOME" build_mcp_flags_cc 2>/dev/null
BEH_RC=$?
if [ "$BEH_RC" -ne 0 ] && [ "${#CC_MCP_FLAGS[@]}" -eq 0 ]; then
  ok "behavioral: fail-closed on mkdir failure (nonzero return, no flags emitted)"
else
  no "behavioral: fail-closed failed (rc=$BEH_RC, count=${#CC_MCP_FLAGS[@]}) — would inherit live MCP!"
fi

# --- (d) fail-closed: OSRC_HOME is a file (not a dir), mkdir fails ---
source "$EXTRACT"
BEH_HOME="$TMPDIR_ISOL/a-file-not-a-dir"
touch "$BEH_HOME"
OSRC_HOME="$BEH_HOME" build_mcp_flags_cc 2>/dev/null
BEH_RC=$?
if [ "$BEH_RC" -ne 0 ] && [ "${#CC_MCP_FLAGS[@]}" -eq 0 ]; then
  ok "behavioral: fail-closed when OSRC_HOME is a file (nonzero return, no flags emitted)"
else
  no "behavioral: fail-closed on file-as-dir failed (rc=$BEH_RC, count=${#CC_MCP_FLAGS[@]})"
fi

# --- (e) whitespace-safe: OSRC_HOME with spaces works (path is correct, file is written) ---
source "$EXTRACT"
BEH_HOME="$TMPDIR_ISOL/dir with spaces"
OSRC_HOME="$BEH_HOME" build_mcp_flags_cc 2>/dev/null
BEH_RC=$?
BEH_CFGPATH="${CC_MCP_FLAGS[2]:-}"
BEH_CFG_CONTENTS=""
[ -n "$BEH_CFGPATH" ] && [ -f "$BEH_CFGPATH" ] && BEH_CFG_CONTENTS="$(cat "$BEH_CFGPATH" 2>/dev/null)"
if [ "$BEH_RC" -eq 0 ] && [ -n "$BEH_CFGPATH" ] && [ -f "$BEH_CFGPATH" ] && [ "$BEH_CFG_CONTENTS" = '{"mcpServers":{}}' ]; then
  ok "behavioral: whitespace-safe path works (OSRC_HOME with spaces, file written correctly)"
else
  no "behavioral: whitespace-safe path failed (rc=$BEH_RC, path=[$BEH_CFGPATH])"
fi

# ============================================================================
# REAL NEGATIVE CONTROL: mutate the function (remove isolation) and verify (a) FAILS.
# This proves the behavioral test actually catches a regression, not just passing vacuously.
# We sabotage the extracted function so the DEFAULT path returns early with no flags (simulating
# a regression that removes the isolation gate), then run the SAME assertion as (a) and require
# it to FAIL. If the assertion still passes on the sabotaged code, the test is vacuous.
# ============================================================================
SABOTAGED="$TMPDIR_ISOL/sabotaged.sh"
# Sabotage: flip the escape-hatch gate so it ALWAYS returns early (|| return 0 instead of && return 0),
# meaning build_mcp_flags_cc never reaches the isolation code on ANY path.
sed 's/\[ "${OSRC_CLAUDE_USER_CONFIG:-0}" = "1" \] && return 0/[ "${OSRC_CLAUDE_USER_CONFIG:-0}" = "1" ] || return 0/' \
  "$EXTRACT" > "$SABOTAGED" 2>/dev/null

# Verify the sabotage actually changed the file (sed worked).
if ! grep -q '\[ "${OSRC_CLAUDE_USER_CONFIG:-0}" = "1" \] && return 0' "$SABOTAGED" 2>/dev/null \
   && grep -q '\[ "${OSRC_CLAUDE_USER_CONFIG:-0}" = "1" \] || return 0' "$SABOTAGED" 2>/dev/null; then
  # Run the SAME assertion as (a) against the sabotaged function. It MUST FAIL (the function returns
  # early with no flags, so CC_MCP_FLAGS is empty, not --strict-mcp-config --mcp-config <path>).
  source "$SABOTAGED"
  BEH_HOME="$TMPDIR_ISOL/sabotaged-run"
  OSRC_HOME="$BEH_HOME" build_mcp_flags_cc 2>/dev/null
  BEH_RC=$?
  BEH_CFGPATH="${CC_MCP_FLAGS[2]:-}"
  # The assertion from (a): rc=0, flags[0]=--strict-mcp-config, file exists with {"mcpServers":{}}
  if [ "$BEH_RC" -eq 0 ] \
    && [ "${CC_MCP_FLAGS[0]:-}" = "--strict-mcp-config" ] \
    && [ -n "$BEH_CFGPATH" ] && [ -f "$BEH_CFGPATH" ] \
    && [ "$(cat "$BEH_CFGPATH" 2>/dev/null)" = '{"mcpServers":{}}' ]; then
    no "negative control: sabotaged function STILL passes the isolation assertion — test is vacuous!"
  else
    ok "negative control: sabotaged function FAILS the isolation assertion (test catches the regression)"
  fi
else
  no "negative control: could not sabotage the function (sed did not flip the gate)"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
