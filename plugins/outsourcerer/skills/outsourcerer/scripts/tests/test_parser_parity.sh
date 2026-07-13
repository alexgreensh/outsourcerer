#!/usr/bin/env bash
# test_parser_parity.sh — T4: parse_model and _consume_flags must not diverge on the shared flag
# namespace (-m/--tier/--with/--effort). parse_model historically dropped --tier/--with and skipped
# --effort validation; this asserts parity. Run: bash test_parser_parity.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n"; exit 1; }
. "$SRC" >/dev/null 2>&1

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

DEFAULT_MODEL="glm"

# --- parse_model sets tier + effort state (was silently dropped) ---
unset OSRC_TIER_OVERRIDE
parse_model -m sol --tier frontier --with skills=a,b --effort high "the task" 2>/dev/null
[ "$MODEL" = "sol" ]                  && ok "parse_model: -m captured"            || bad "parse_model: -m missed ($MODEL)"
[ "${TIER_FLAG:-}" = "frontier" ]     && ok "parse_model: --tier -> TIER_FLAG"    || bad "parse_model: TIER_FLAG='${TIER_FLAG:-}'"
[ "${OSRC_TIER_OVERRIDE:-}" = "frontier" ] && ok "parse_model: --tier -> OSRC_TIER_OVERRIDE" || bad "parse_model: OSRC_TIER_OVERRIDE unset (T4 regression)"
case "${WITH_SPEC:-}" in *skills=a,b*) ok "parse_model: --with -> WITH_SPEC" ;; *) bad "parse_model: WITH_SPEC='${WITH_SPEC:-}'" ;; esac
[ "$EFFORT" = "high" ]                 && ok "parse_model: --effort captured"      || bad "parse_model: EFFORT='$EFFORT'"
[ "${REST[*]}" = "the task" ]         && ok "parse_model: task in REST, flags stripped" || bad "parse_model: REST='${REST[*]}'"

# --- parse_model validates --effort identically to _consume_flags ---
( parse_model -m sol --effort bogus "t" >/dev/null 2>&1 ) && bad "parse_model: invalid --effort accepted (T4 regression)" || ok "parse_model: invalid --effort rejected"
( _consume_flags -m sol --effort bogus "t" >/dev/null 2>&1 ) && bad "_consume_flags: invalid --effort accepted" || ok "_consume_flags: invalid --effort rejected"

# --- both parsers agree on a valid effort value ---
parse_model -m sol --effort low "t" 2>/dev/null;  pe="$EFFORT"
_consume_flags -m sol --effort low "t";           ce="$EFFORT"
[ "$pe" = "low" ] && [ "$ce" = "low" ] && ok "both parsers accept --effort low" || bad "effort divergence (parse_model=$pe consume=$ce)"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
