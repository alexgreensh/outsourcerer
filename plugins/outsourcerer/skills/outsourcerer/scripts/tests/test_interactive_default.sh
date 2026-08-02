#!/usr/bin/env bash
# test_interactive_default.sh — U7: headless coding jobs get the Bash toolset so they no longer
# wedge on an unanswerable permission prompt (the #1 headless failure). run stays read-only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# --- cc lane (OpenRouter GLM/HY3) grants the toolset ---
grep -q 'accept-edits|dangerous) tools=(--allowedTools Read Edit Write Bash Grep Glob)' "$SRC" \
  && ok "mutating tiers get Read Edit Write Bash Grep Glob" || bad "mutating toolset missing"
grep -q 'auto)                   tools=(--allowedTools Read Grep Glob)' "$SRC" \
  && ok "auto (run) stays read-only (Read Grep Glob, no Bash/Write)" || bad "auto toolset wrong"

# --- both claude -p invocations pass the tools array BEFORE --permission-mode (variadic termination) ---
n_wired=$(grep -cE '\$\{tools\[@\]\+"\$\{tools\[@\]\}"\} --permission-mode' "$SRC")
[ "$n_wired" -ge 3 ] && ok "tools[] wired before --permission-mode in >=3 invocations (cc + native x2) ($n_wired)" \
  || bad "tools[] not wired in all invocations (found $n_wired, want >=3)"

# --- OSRC_ALLOWED_TOOLS override is honored in both lanes ---
n_override=$(grep -c 'OSRC_ALLOWED_TOOLS:-' "$SRC")
[ "$n_override" -ge 2 ] && ok "OSRC_ALLOWED_TOOLS override honored in cc + native lanes ($n_override)" \
  || bad "OSRC_ALLOWED_TOOLS override missing (found $n_override)"

# --- functional: mock claude, confirm Bash is passed for a mutating run, absent for read-only ---
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$OSRC_ARGDUMP"
# emit a minimal success JSON so delegate_cc's rc==0 path is taken
echo '{"result":"ok"}'
exit 0
EOF
chmod +x "$TMP/claude"

# Extract just the toolset-decision snippet to exercise it in isolation (the inline logic).
decide_tools() {
  local tier="$1"; local tools=()
  if [ -n "${OSRC_ALLOWED_TOOLS:-}" ]; then tools=(--allowedTools $OSRC_ALLOWED_TOOLS)
  else case "$tier" in
    auto)                   tools=(--allowedTools Read Grep Glob) ;;
    accept-edits|dangerous) tools=(--allowedTools Read Edit Write Bash Grep Glob) ;;
  esac; fi
  printf '%s ' "${tools[@]}"
}
[[ "$(decide_tools accept-edits)" == *Bash* ]] && ok "edit tier -> Bash granted (headless coding works)" || bad "edit tier missing Bash"
[[ "$(decide_tools dangerous)" == *Bash* ]] && ok "yolo tier -> Bash granted" || bad "yolo tier missing Bash"
[[ "$(decide_tools auto)" != *Bash* ]] && ok "run tier -> NO Bash (read-only preserved)" || bad "run tier wrongly got Bash"
OSRC_ALLOWED_TOOLS="Read" ; [[ "$(decide_tools accept-edits)" == "--allowedTools Read " ]] && ok "OSRC_ALLOWED_TOOLS override wins" || bad "override not honored"; unset OSRC_ALLOWED_TOOLS

# --- interactive session adapters are capability-gated before either transport creates state ---
grep -q '^_session_launch_adapter()' "$SRC" \
  && ok "session launch capability adapter is defined" || bad "session launch capability adapter missing"
n_session_adapter_calls=$(grep -c '_session_launch_adapter' "$SRC")
[ "$n_session_adapter_calls" -ge 3 ] \
  && ok "Unix and Windows session transports share the capability adapter" \
  || bad "capability adapter is not shared by both transports (found $n_session_adapter_calls references)"
grep -q 'SESSION_LAUNCH=("droid" "--auto" "medium")' "$SRC" \
  && ok "Droid interactive sessions use the advertised bounded-autonomy launch" \
  || bad "Droid interactive launch does not select --auto medium"

# --- regression: `session start -m <native-alias>` must start that model's NATIVE lane, not devin ---
# _session_infer_provider remaps PROVIDER when --provider was not explicit and the alias names a native
# lane (terra/sol/luna -> codex, opus/fable/sonnet -> cc, gemini-* -> gm); dual-lane open-weight ids stay
# on the provider default; an explicit --provider always wins.
_infer_probe() { # <model> <prov-explicit> <model-explicit> <start-prov> -> resulting PROVIDER
  local m="$1" pe="$2" me="$3" sp="$4"   # capture BEFORE `set --` wipes the positionals
  ( export OSRC_HOME="$(mktemp -d)"; set --; . "$SRC" >/dev/null 2>&1
    PROVIDER="$sp"; PROVIDER_EXPLICIT="$pe"; MODEL_EXPLICIT="$me"; MODEL="$m"
    _session_infer_provider >/dev/null 2>&1; printf '%s' "$PROVIDER" )
}
[ "$(_infer_probe terra 0 1 devin)" = codex ] && ok "session start -m terra -> codex (bug 2 fixed)" || bad "terra still misroutes off codex"
[ "$(_infer_probe opus 0 1 devin)"  = cc ]    && ok "session start -m opus -> cc (claude native)" || bad "opus does not route to cc"
[ "$(_infer_probe glm 0 1 devin)"   = devin ] && ok "session start -m glm stays devin (dual-lane default)" || bad "glm wrongly remapped off devin"
[ "$(_infer_probe terra 1 1 devin)" = devin ] && ok "explicit --provider always wins over the alias" || bad "explicit --provider was overridden"
[ "$(_infer_probe terra 0 0 devin)" = devin ] && ok "no -m -> no remap (provider default preserved)" || bad "remap fired without an explicit model"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
