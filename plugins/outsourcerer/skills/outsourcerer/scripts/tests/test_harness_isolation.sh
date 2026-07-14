#!/bin/bash
# test_harness_isolation.sh — I1 invariant: a DELEGATED (headless) codex-exec run must not inherit
# the user's live ~/.codex config surface (above all its mcp_servers, which can wedge a sandboxed
# run demanding interactive OAuth — the failure that sandbox-blocked Sol). Every headless `codex exec`
# delegate site must carry `--ignore-user-config` (gated by the OSRC_CODEX_USER_CONFIG escape hatch),
# and the interactive TUI path must NOT (it's an exec-only flag + a human can answer an auth prompt).
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$DIR/outsourcerer.sh"
ORCODEX="$DIR/run-or-codex.sh"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

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
  && ok "all $sites headless codex-exec delegate invocations carry the isolation gate" \
  || no "$missing of $sites headless codex-exec invocation(s) missing --ignore-user-config"

# 2) The escape hatch exists and is spelled consistently everywhere it gates the flag.
n_gate="$(grep -c 'OSRC_CODEX_USER_CONFIG:-0.*ignore-user-config' "$ENGINE")"
[ "$n_gate" -ge 4 ] && ok "OSRC_CODEX_USER_CONFIG opt-out gates the flag ($n_gate sites)" \
                    || no "expected >=4 gated sites in engine, found $n_gate"

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

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
