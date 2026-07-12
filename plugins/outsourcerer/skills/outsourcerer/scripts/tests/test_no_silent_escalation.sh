#!/usr/bin/env bash
# test_no_silent_escalation.sh — U2 conformance: no silent acceptEdits->bypassPermissions
# or sandbox->unsandboxed downgrade. Exercises the primitives OFFLINE (no real delegation).
# Run: bash test_no_silent_escalation.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
if [ ! -f "$SRC" ]; then echo FAIL: cannot find $SRC; exit 1; fi

# Keep every durable artifact inside this temp dir, never in ~/.outsourcerer.
TMP="$(mktemp -d)"
export OSRC_HOME="$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Load the source so the functions are defined. main is not run.
. "$SRC" >/dev/null 2>&1

pass=0; fail=0
ok()  { echo PASS: $1; pass=$((pass+1)); }
bad() { echo FAIL: $1; fail=$((fail+1)); }

# === Scenario 1: _perm_escalate default keeps acceptEdits on a protected path and warns. ===
OSRC_PROTECTED_PATHS="/tmp/protected"
OSRC_ALLOW_DOWNGRADE=0
OSRC_NO_BYPASS=0
mode="$(_perm_escalate acceptEdits "/tmp/protected/file" 2>"$TMP/err1.txt")"
err="$(cat "$TMP/err1.txt")"
if [ "$mode" = "acceptEdits" ]; then ok "default keeps caller mode (acceptEdits)" ; else bad "default changed mode to '$mode'"; fi
if printf '%s' "$err" | grep -q 'protected path needs --allow-downgrade'; then ok "default prints --allow-downgrade warning" ; else bad "default warning missing: $err"; fi
if printf '%s' "$err" | grep -q 'SECURITY DOWNGRADE'; then bad "default should NOT print SECURITY DOWNGRADE" ; else ok "default does not print SECURITY DOWNGRADE"; fi

# === Scenario 2: explicit per-run flag --allow-downgrade is consumed and escalates. ===
_consume_flags --allow-downgrade "some task"
if [ "${OSRC_ALLOW_DOWNGRADE:-0}" = "1" ]; then ok "--allow-downgrade flag sets OSRC_ALLOW_DOWNGRADE=1" ; else bad "--allow-downgrade not consumed"; fi
if [ "${REST[*]}" = "some task" ]; then ok "--allow-downgrade stripped from REST" ; else bad "REST still contains flag: ${REST[*]}"; fi

# === Scenario 3: OSRC_ALLOW_DOWNGRADE=1 causes escalation with a SECURITY DOWNGRADE banner. ===
OSRC_PROTECTED_PATHS="/tmp/protected"
OSRC_ALLOW_DOWNGRADE=1
mode="$(_perm_escalate acceptEdits "/tmp/protected/file" 2>"$TMP/err3.txt")"
err="$(cat "$TMP/err3.txt")"
if [ "$mode" = "bypassPermissions" ]; then ok "OSRC_ALLOW_DOWNGRADE=1 escalates to bypassPermissions" ; else bad "allow-downgrade did not escalate (got '$mode')"; fi
if printf '%s' "$err" | grep -q 'SECURITY DOWNGRADE'; then ok "escalation banner says SECURITY DOWNGRADE" ; else bad "escalation missing SECURITY DOWNGRADE banner: $err"; fi

# === Scenario 4: /tmp path is unchanged and produces no warning. ===
unset OSRC_PROTECTED_PATHS OSRC_ALLOW_DOWNGRADE
mode="$(_perm_escalate acceptEdits "/tmp/file.txt" 2>"$TMP/err4.txt")"
err="$(cat "$TMP/err4.txt")"
if [ "$mode" = "acceptEdits" ]; then ok "/tmp path keeps acceptEdits" ; else bad "/tmp path got '$mode'"; fi
if [ -z "$err" ]; then ok "/tmp path produces no warning" ; else bad "/tmp path produced warning: $err"; fi

# === Scenario 5: continue does not force accept-edits. ===
# Override devin and auth to capture the actual invocation.
DEVIN_CALLED=0
DEVIN_ARGS=""
devin() { DEVIN_ARGS="$*"; DEVIN_CALLED=1; return 0; }
need_devin() { :; }
logged_in() { :; }
continue_turn "hello again"
if [ "$DEVIN_CALLED" = "1" ]; then ok "continue calls devin" ; else bad "continue did not call devin"; fi
if printf '%s' "${DEVIN_ARGS[*]}" | grep -q -- '--permission-mode'; then
  bad "continue still passes --permission-mode"
else
  ok "continue no longer forces --permission-mode"
fi
if printf '%s' "${DEVIN_ARGS[*]}" | grep -q 'accept-edits'; then
  bad "continue still passes accept-edits"
else
  ok "continue no longer forces accept-edits"
fi

# === Scenario 6: codex->cc self-heal is gated by --allow-downgrade. ===
# Mock the codex CLI so delegate_codex sees a tool-type-400 failure.
OSRC_ALLOW_DOWNGRADE=0
unset REST
OR_OFFLOAD_CHAIN="hy3"
codex() { echo "does not support the native namespace tool type"; return 1; }
_or_load_key() { :; }
_codex_code_mode_host() { return 0; }
_tier_banner() { :; }
record_ledger() { :; }
DELEGATE_CC_CALLED=0
delegate_cc() { echo "DELEGATE_CC"; DELEGATE_CC_CALLED=1; return 0; }
# Run delegate_codex in the current shell so DELEGATE_CC_CALLED is visible; capture output to a file.
delegate_codex accept-edits "task" > "$TMP/out6.txt" 2>&1
rc=$?
out="$(cat "$TMP/out6.txt")"
if [ "$DELEGATE_CC_CALLED" = "0" ]; then ok "codex->cc self-heal without ack does NOT call delegate_cc" ; else bad "delegate_cc was called without ack"; fi
if printf '%s' "$out" | grep -q 'SECURITY DOWNGRADE'; then ok "self-heal refusal banner says SECURITY DOWNGRADE" ; else bad "self-heal refusal missing SECURITY DOWNGRADE: $out"; fi
if printf '%s' "$out" | grep -q 'requires --allow-downgrade'; then ok "self-heal refusal tells user to use --allow-downgrade" ; else bad "self-heal refusal missing --allow-downgrade hint: $out"; fi

# === Scenario 7: codex->cc self-heal with --allow-downgrade does drop sandbox and calls cc. ===
OSRC_ALLOW_DOWNGRADE=0
DELEGATE_CC_CALLED=0
delegate_codex accept-edits --allow-downgrade "task" > "$TMP/out7.txt" 2>&1
rc=$?
out="$(cat "$TMP/out7.txt")"
if [ "$DELEGATE_CC_CALLED" = "1" ]; then ok "self-heal with --allow-downgrade calls delegate_cc" ; else bad "delegate_cc not called with --allow-downgrade"; fi
if printf '%s' "$out" | grep -q 'SECURITY DOWNGRADE'; then ok "self-heal escalation banner says SECURITY DOWNGRADE" ; else bad "self-heal escalation missing SECURITY DOWNGRADE: $out"; fi

# === Scenario 8: source no longer auto-escalates in the continue / self-heal blocks. ===
if grep -q 'permission-mode.*accept-edits' "$SRC"; then
  # The only remaining accept-edits permission-mode is inside non-continue lanes.
  # We ensure the continue_turn block itself is clean.
  if grep -A2 'continue_turn()' "$SRC" | grep -q 'permission-mode.*accept-edits'; then
    bad "continue_turn still forces accept-edits"
  else
    ok "continue_turn does not force accept-edits"
  fi
else
  ok "no remaining forced accept-edits in source"
fi

if grep -q '\[self-heal\].*cc lane\|self-heal.*cc.*standard tools' "$SRC"; then
  bad "old ungated self-heal message still present"
else
  ok "old self-heal message replaced by SECURITY DOWNGRADE gate"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
