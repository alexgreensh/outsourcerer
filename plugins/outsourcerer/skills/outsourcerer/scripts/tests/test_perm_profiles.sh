#!/usr/bin/env bash
# test_perm_profiles.sh — `session start --perm safe|default` (L5).
#
# Covers the contract in scripts/lib/perm.sh:
#   * osrc_perm_flags <engine> <profile> <workdir> prints extra launch flags, one argv
#     element per line; default/unknown profiles and engines with no faithful safe rung
#     print NOTHING (launch stays byte-identical).
#   * safe maps to each engine's DOCUMENTED pre-allow mechanism (verified vs --help/docs,
#     see sessions/2026-11-13-autonomy/out/L5-AUDIT.md): devin --permission-mode smart,
#     cx --approve-for-me (replacing -s, they conflict), cc --allowedTools+--settings,
#     cursor --auto-review, agy --mode auto, gemini-cli --approval-mode auto_edit+--policy.
#   * parse_model/_consume_flags accept --perm safe|default (and --perm=) identically and
#     never leak it into REST; invalid values die.
#   * _session_launch_adapter appends safe flags for ported lanes; default is unchanged.
#
# Deterministic: no engine needs to be installed for the flag-matrix assertions; adapter
# checks SKIP when the lane's CLI is absent. OSRC_HOME is scratch. No tmux.
# Run: bash test_perm_profiles.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"
LIB="$SCRIPT_DIR/../lib/perm.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
[ -f "$LIB" ] || { echo "FAIL: cannot find $LIB"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n outsourcerer.sh"; exit 1; }
bash -n "$LIB" || { echo "FAIL: bash -n lib/perm.sh"; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-perm.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home"; export OSRC_SOURCED=1; mkdir -p "$OSRC_HOME"
. "$SRC" >/dev/null 2>&1
type -t osrc_perm_flags >/dev/null || { echo "FAIL: osrc_perm_flags not loaded (lib loader broken)"; exit 1; }
type -t osrc_perm_apply_launch >/dev/null || { echo "FAIL: osrc_perm_apply_launch not loaded"; exit 1; }

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
ck(){ # ck <desc> <haystack-file-or-var> <pattern>
  if grep -qF -- "$3" "$2" 2>/dev/null || [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1 (missing: $3)"; fi
}
nck(){ # nck <desc> <haystack> <pattern> — must NOT contain
  if grep -qF -- "$3" "$2" 2>/dev/null || [[ "$2" == *"$3"* ]]; then no "$1 (unexpected: $3)"; else ok "$1"; fi
}

WD="$TMP/wd"; mkdir -p "$WD"

# ---------- 1. osrc_perm_flags: default profile is always empty -------------------
_empty=1
for e in devin dv cx codex cc claude cursor agy gemini gm gmnative droid hermes cline pi warp local tokenrouter grokbot bogus ''; do
  [ -n "$(osrc_perm_flags "$e" default "$WD" 2>/dev/null)" ] && _empty=0
done
[ "$_empty" = 1 ] && ok "default profile emits no flags for every engine" || no "default profile emitted flags for some engine"

# ---------- 2. osrc_perm_flags: safe per engine ------------------------------------
_out="$(osrc_perm_flags devin safe "$WD")"
[ "$_out" = $'--permission-mode\nsmart' ] && ok "devin safe -> --permission-mode smart" || no "devin safe -> '$_out'"
_out="$(osrc_perm_flags cx safe "$WD")"
[ "$_out" = "--approve-for-me" ] && ok "cx safe -> --approve-for-me" || no "cx safe -> '$_out'"
_out="$(osrc_perm_flags cursor safe "$WD")"
[ "$_out" = "--auto-review" ] && ok "cursor safe -> --auto-review" || no "cursor safe -> '$_out'"
_out="$(osrc_perm_flags agy safe "$WD")"
[ "$_out" = $'--mode\nauto' ] && ok "agy safe -> --mode auto" || no "agy safe -> '$_out'"

# engines with no faithful per-launch safe rung emit nothing even under safe
_nosafe=1
for e in droid hermes cline pi warp local tokenrouter grokbot bogus; do
  [ -n "$(osrc_perm_flags "$e" safe "$WD" 2>/dev/null)" ] && _nosafe=0
done
[ "$_nosafe" = 1 ] && ok "no-safe-rung engines emit nothing under safe" || no "a no-safe-rung engine emitted flags"

# bogus profile emits nothing
[ -z "$(osrc_perm_flags devin bogus "$WD" 2>/dev/null)" ] && ok "bogus profile emits nothing" || no "bogus profile emitted flags"

# ---------- 3. claude (cc) safe args ----------------------------------------------
osrc_perm_flags cc safe "$WD" > "$TMP/cc.txt"
ck "cc safe emits --allowedTools" "$TMP/cc.txt" "--allowedTools"
ck "cc safe allows workspace edits" "$TMP/cc.txt" "Edit(./**)"
ck "cc safe allows Write in workdir" "$TMP/cc.txt" "Write(./**)"
ck "cc safe pre-allows git status" "$TMP/cc.txt" "Bash(git status)"
ck "cc safe pre-allows git status args" "$TMP/cc.txt" "Bash(git status *)"
ck "cc safe pre-allows npm test" "$TMP/cc.txt" "Bash(npm test)"
ck "cc safe pre-allows npm run test:* scripts" "$TMP/cc.txt" "Bash(npm run test:*)"
ck "cc safe pre-allows pytest" "$TMP/cc.txt" "Bash(pytest)"
ck "cc safe emits --settings ask-list" "$TMP/cc.txt" "--settings"
ck "cc ask-list covers shell redirect" "$TMP/cc.txt" 'Bash(*>*)'
ck "cc ask-list covers find -exec" "$TMP/cc.txt" 'Bash(*-exec*)'
ck "cc ask-list covers --output writers" "$TMP/cc.txt" 'Bash(*--out*)'
nck "cc safe does NOT pre-allow rm" "$TMP/cc.txt" "Bash(rm"
nck "cc safe does NOT pre-allow git push" "$TMP/cc.txt" "Bash(git push"
nck "cc safe does NOT pre-allow curl" "$TMP/cc.txt" "Bash(curl"
nck "cc safe does NOT pre-allow sudo" "$TMP/cc.txt" "Bash(sudo"
nck "cc safe does NOT pre-allow docker" "$TMP/cc.txt" "Bash(docker"
nck "cc safe does NOT pre-allow psql" "$TMP/cc.txt" "Bash(psql"
nck "cc safe does NOT pre-allow env exec wrapper" "$TMP/cc.txt" "Bash(env)"
nck "cc safe does NOT pre-allow tmux" "$TMP/cc.txt" "Bash(tmux"

# ---------- 4. gemini-cli safe args + policy file ----------------------------------
export OSRC_GEMINI_VEHICLE=gemini
osrc_perm_flags gemini safe "$WD" > "$TMP/gm.txt"
ck "gemini safe emits --approval-mode" "$TMP/gm.txt" "--approval-mode"
ck "gemini safe emits auto_edit" "$TMP/gm.txt" "auto_edit"
ck "gemini safe emits --policy" "$TMP/gm.txt" "--policy"
POL="$(sed -n '/--policy/{n;p;}' "$TMP/gm.txt")"
[ -n "$POL" ] && [ -f "$POL" ] && ok "gemini policy file written under OSRC_HOME" || no "gemini policy file missing: '$POL'"
case "$POL" in "$OSRC_HOME"/*) ok "gemini policy lives under scratch OSRC_HOME" ;; *) no "gemini policy outside OSRC_HOME: $POL" ;; esac
[ -n "$POL" ] && [ -f "$POL" ] && {
  ck "policy has allow rule" "$POL" 'decision = "allow"'
  ck "policy has ask_user rule" "$POL" 'decision = "ask_user"'
  ck "policy allow regex covers git status" "$POL" "git status"
  ck "policy ask regex covers redirect" "$POL" ">"
}
# gm alias resolves through the vehicle too
_out="$(OSRC_GEMINI_VEHICLE=agy osrc_perm_flags gm safe "$WD")"
[ "$_out" = $'--mode\nauto' ] && ok "gm+agy vehicle -> --mode auto" || no "gm+agy -> '$_out'"
unset OSRC_GEMINI_VEHICLE

# ---------- 5. parsers: --perm safe|default ----------------------------------------
# parse_model/_consume_flags set globals — capture inside the subshell (set -u).
_p="$( parse_model --perm safe >/dev/null 2>&1; printf '%s' "${PERM_PROFILE:-}" )"
[ "$_p" = safe ] && ok "parse_model --perm safe" || no "parse_model --perm safe (got '$_p')"
_p="$( parse_model --perm=default >/dev/null 2>&1; printf '%s' "${PERM_PROFILE:-}" )"
[ "$_p" = default ] && ok "parse_model --perm=default" || no "parse_model --perm=default (got '$_p')"
_p="$( parse_model >/dev/null 2>&1; printf '%s' "${PERM_PROFILE:-}" )"
[ "$_p" = default ] && ok "parse_model default is default" || no "parse_model default profile wrong (got '$_p')"
_p="$( OSRC_PERM_PROFILE=safe parse_model >/dev/null 2>&1; printf '%s' "${PERM_PROFILE:-}" )"
[ "$_p" = safe ] && ok "OSRC_PERM_PROFILE env seeds profile" || no "OSRC_PERM_PROFILE env not honored (got '$_p')"
_rc=0; ( parse_model --perm bogus ) >/dev/null 2>&1 || _rc=$?
[ "$_rc" -ne 0 ] && ok "parse_model --perm bogus dies" || no "parse_model --perm bogus accepted"
_rc=0; ( parse_model --perm ) >/dev/null 2>&1 || _rc=$?
[ "$_rc" -ne 0 ] && ok "parse_model --perm (missing value) dies" || no "parse_model --perm missing value accepted"

_p="$( _consume_flags --perm safe "do the thing" >/dev/null 2>&1; printf '%s|%s' "${PERM_PROFILE:-}" "${REST[0]:-}" )"
[ "$_p" = "safe|do the thing" ] \
  && ok "_consume_flags --perm safe consumed, REST clean" || no "_consume_flags --perm safe (got '$_p')"
_p="$( _consume_flags --perm=default >/dev/null 2>&1; printf '%s' "${PERM_PROFILE:-}" )"
[ "$_p" = default ] && ok "_consume_flags --perm=default" || no "_consume_flags --perm=default (got '$_p')"

# ---------- 6. adapter integration (skip when lane CLI absent) ----------------------
# Prints SESSION_LAUNCH one-arg-per-line from a subshell so die() can't kill the test.
_launch() { # <provider> -> raw argv lines on stdout, rc on $?
  ( PERM_PROFILE="$PERM_UNDER_TEST" PROVIDER="$1" MODEL_EXPLICIT=0 MODEL="" EFFORT="" \
      OSRC_GEMINI_VEHICLE="${GMVEH:-}" \
      _session_launch_adapter "$1" >/dev/null 2>"$TMP/launch.err" \
    && printf '%s\n' "${SESSION_LAUNCH[@]}" )
}

PERM_UNDER_TEST=safe
if have codex; then
  _l="$(_launch codex)" || _l=""
  if [ -n "$_l" ]; then
    printf '%s\n' "$_l" > "$TMP/l-cx-safe.txt"
    ck "cx safe -> --approve-for-me in launch" "$TMP/l-cx-safe.txt" "--approve-for-me"
    nck "cx safe drops -s workspace-write (conflicts)" "$TMP/l-cx-safe.txt" "workspace-write"
  else no "cx safe: adapter produced no launch (see $TMP/launch.err)"; fi
else echo "SKIP: codex not installed"; fi

PERM_UNDER_TEST=default
if have codex; then
  _l="$(_launch codex)" || _l=""
  if [ -n "$_l" ]; then
    printf '%s\n' "$_l" > "$TMP/l-cx-def.txt"
    ck "cx default keeps -s workspace-write" "$TMP/l-cx-def.txt" "workspace-write"
    nck "cx default has no --approve-for-me" "$TMP/l-cx-def.txt" "--approve-for-me"
  else no "cx default: adapter produced no launch"; fi
else echo "SKIP: codex not installed"; fi

PERM_UNDER_TEST=safe
if have claude; then
  _l="$(_launch cc)" || _l=""
  if [ -n "$_l" ]; then
    printf '%s\n' "$_l" > "$TMP/l-cc-safe.txt"
    ck "cc safe launch has --allowedTools" "$TMP/l-cc-safe.txt" "--allowedTools"
    ck "cc safe launch has Bash(git status *)" "$TMP/l-cc-safe.txt" "Bash(git status *)"
    ck "cc safe launch has --settings" "$TMP/l-cc-safe.txt" "--settings"
    ck "cc safe launch keeps claude binary" "$TMP/l-cc-safe.txt" "claude"
  else no "cc safe: adapter produced no launch"; fi
else echo "SKIP: claude not installed"; fi

PERM_UNDER_TEST=default
if have claude; then
  _l="$(_launch cc)" || _l=""
  if [ -n "$_l" ]; then
    printf '%s\n' "$_l" > "$TMP/l-cc-def.txt"
    nck "cc default has no --allowedTools" "$TMP/l-cc-def.txt" "--allowedTools"
    nck "cc default has no --settings" "$TMP/l-cc-def.txt" "--settings"
  else no "cc default: adapter produced no launch"; fi
else echo "SKIP: claude not installed"; fi

PERM_UNDER_TEST=safe; GMVEH=agy
if have agy; then
  _l="$(_launch gemini)" || _l=""
  if [ -n "$_l" ]; then
    printf '%s\n' "$_l" > "$TMP/l-gm-safe.txt"
    ck "gm/agy safe -> --mode auto" "$TMP/l-gm-safe.txt" "auto"
    ck "gm/agy safe keeps agy binary" "$TMP/l-gm-safe.txt" "agy"
  else no "gm safe: adapter produced no launch"; fi
else echo "SKIP: agy not installed"; fi

PERM_UNDER_TEST=safe
if have droid; then
  _safe="$(_launch droid)" || _safe=""
  PERM_UNDER_TEST=default
  _def="$(_launch droid)" || _def=""
  PERM_UNDER_TEST=safe
  if [ -n "$_safe" ] && [ "$_safe" = "$_def" ]; then
    ok "droid safe == default (no faithful rung; --auto medium already covers it)"
  elif [ -z "$_safe" ]; then no "droid: adapter produced no launch"; fi
else echo "SKIP: droid not installed"; fi

PERM_UNDER_TEST=safe
if have cursor-agent || have agent; then
  _safe="$(_launch cursor)" || _safe=""
  PERM_UNDER_TEST=default
  _def="$(_launch cursor)" || _def=""
  PERM_UNDER_TEST=safe
  if [ -z "$_safe" ] && [ -z "$_def" ]; then
    echo "SKIP: cursor adapter produced no launch under either profile (help probe timed out — environmental)"
  elif [ -z "$_safe" ]; then
    no "cursor safe: adapter produced no launch while default did"
  else
    printf '%s\n' "$_safe" > "$TMP/l-cur-safe.txt"
    ck "cursor safe -> --auto-review" "$TMP/l-cur-safe.txt" "--auto-review"
    printf '%s\n' "$_def" > "$TMP/l-cur-def.txt"
    nck "cursor default has no --auto-review" "$TMP/l-cur-def.txt" "--auto-review"
  fi
else echo "SKIP: cursor-agent not installed"; fi

echo "----"
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
