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

# Session effort accepts the same vocabulary as launch-time effort.
for level in minimal low medium high xhigh max none; do
  _session_effort_validate "$level" && ok "session effort accepts $level" || bad "session effort rejected $level"
done
( _session_effort_validate bogus ) && bad "session effort accepted invalid level" || ok "session effort rejects invalid level"

# Provider provenance follows both parser entry points.
PROVIDER=devin; PROVIDER_EXPLICIT=0
parse_model --provider cc "t" 2>/dev/null
[ "$PROVIDER" = "cc" ] && [ "$PROVIDER_EXPLICIT" = "1" ] && ok "parse_model: --provider is explicit" || bad "parse_model: provider provenance lost"
PROVIDER=devin; PROVIDER_EXPLICIT=0
_consume_flags --provider codex "t"
[ "$PROVIDER" = "codex" ] && [ "$PROVIDER_EXPLICIT" = "1" ] && ok "consume_flags: --provider is explicit" || bad "consume_flags: provider provenance lost"
grep -q 'OSRC_PROVIDER:-' "$SRC" && ok "OSRC_PROVIDER is an explicit environment selection" || bad "OSRC_PROVIDER environment selection missing"
grep -q 'PROVIDER_EXPLICIT=1; shift 2' "$SRC" && ok "global provider flag records provenance" || bad "global provider provenance missing"

parse_model "t" 2>/dev/null
[ -z "$MODEL" ] && ok "implicit parser model remains empty" || bad "implicit parser inherited a provider model"
[ "$(_route_provider_default_model gemini)" = gemini-flash-lite ] && ok "Gemini resolves its own implicit model (symbolic; the concrete id is picked from the live catalog)" || bad "Gemini inherited the Devin default"
[ "$(_route_provider_default_model local)" = local ] && ok "local resolves its own implicit model" || bad "local inherited the Devin default"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
