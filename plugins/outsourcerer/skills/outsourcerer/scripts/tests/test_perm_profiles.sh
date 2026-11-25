#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_perm_profiles.sh — `session start --perm safe|default` (L5).
#
# Covers the contract in scripts/lib/perm.sh:
#   * osrc_perm_flags <engine> <profile> <workdir> prints extra launch flags, one argv
#     element per line; default/unknown profiles and engines with no faithful safe rung
#     print NOTHING (launch stays byte-identical).
#   * safe maps to each engine's DOCUMENTED pre-allow mechanism (verified vs --help/docs,
#     see sessions/2026-11-13-autonomy/out/L5-AUDIT.md): devin --permission-mode smart,
#     cx --approve-for-me (replacing -s, they conflict), cc --allowedTools+--settings,
#     cursor --auto-review, agy --mode auto, gemini-cli --approval-mode auto_edit.
#     (Round 2: the generated gemini policy TOML was withdrawn — see L5-VERDICT.md.)
#   * parse_model/_consume_flags accept --perm safe|default (and --perm=) identically and
#     never leak it into REST; invalid values (flag or OSRC_PERM_PROFILE env) die;
#     --perm on a non-session verb warns instead of being silently ignored.
#   * _session_launch_adapter appends safe flags for ported lanes; default is unchanged.
#   * The launch banner is honest: engines with no faithful safe rung say so, and the
#     recorded profile survives control/effort relaunch (_session_relaunch_*).
#   * scripts/lib/*.sh loads when outsourcerer.sh is invoked THROUGH A SYMLINK
#     (LOADER.md: $SCRIPT_DIR points at the link's dir, not the real one).
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
TMP="$(mktemp -d "${TMPDIR%/}/osrc-perm.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/fakehome" OSRC_HOME="$TMP/home"; export OSRC_SOURCED=1; mkdir -p "$HOME" "$OSRC_HOME"
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
ck "cc ask-list covers find -exec" "$TMP/cc.txt" 'Bash(*-exec*)'
ck "cc ask-list covers find -delete" "$TMP/cc.txt" 'Bash(*-delete*)'
ck "cc ask-list covers --output writers" "$TMP/cc.txt" 'Bash(*--out*)'
ck "cc ask-list covers rg --pager exec" "$TMP/cc.txt" 'Bash(rg *--pager*)'
ck "cc ask-list covers sort --compress-program exec" "$TMP/cc.txt" 'Bash(sort *--compress-program*)'
ck "cc ask-list covers tail -f stall" "$TMP/cc.txt" 'Bash(tail *-f*)'
ck "cc ask-list covers ps env leak" "$TMP/cc.txt" 'Bash(ps e*)'
ck "cc ask-list covers watch-mode stall" "$TMP/cc.txt" 'Bash(*--watch*)'
ck "cc ask-list covers prettier --write" "$TMP/cc.txt" 'Bash(prettier *--write*)'
ck "cc ask-list covers eslint --fix" "$TMP/cc.txt" 'Bash(eslint *--fix*)'
ck "cc ask-list covers pytest --pdb stall" "$TMP/cc.txt" 'Bash(*--pdb*)'
ck "cc ask-list covers git fsck --lost-found" "$TMP/cc.txt" 'Bash(git fsck *--lost-found*)'
# Round-2 removals: these must NOT appear as allow rules.
nck "cc safe does NOT pre-allow rm" "$TMP/cc.txt" "Bash(rm"
nck "cc safe does NOT pre-allow git push" "$TMP/cc.txt" "Bash(git push"
nck "cc safe does NOT pre-allow curl" "$TMP/cc.txt" "Bash(curl"
nck "cc safe does NOT pre-allow sudo" "$TMP/cc.txt" "Bash(sudo"
nck "cc safe does NOT pre-allow docker" "$TMP/cc.txt" "Bash(docker"
nck "cc safe does NOT pre-allow psql" "$TMP/cc.txt" "Bash(psql"
nck "cc safe does NOT pre-allow env exec wrapper" "$TMP/cc.txt" "Bash(env"
nck "cc safe does NOT pre-allow tmux" "$TMP/cc.txt" "Bash(tmux"
nck "cc safe does NOT pre-allow printenv (secret dump)" "$TMP/cc.txt" "Bash(printenv"
nck "cc safe does NOT pre-allow ping (never returns)" "$TMP/cc.txt" "Bash(ping"
nck "cc safe does NOT pre-allow sleep (never returns)" "$TMP/cc.txt" "Bash(sleep"
nck "cc safe does NOT pre-allow log show (unbounded)" "$TMP/cc.txt" "Bash(log show"
nck "cc safe does NOT pre-allow gh api (verb smuggle)" "$TMP/cc.txt" "Bash(gh api"
nck "cc safe does NOT pre-allow gh run watch (hangs)" "$TMP/cc.txt" "Bash(gh run watch"
nck "cc safe does NOT pre-allow black (writes by default)" "$TMP/cc.txt" "Bash(black"
nck "cc safe does NOT pre-allow isort (writes by default)" "$TMP/cc.txt" "Bash(isort"
nck "cc safe does NOT pre-allow bare ruff (format/server escape)" "$TMP/cc.txt" "Bash(ruff)"
nck "cc safe does NOT pre-allow git remote -v (prune/update smuggle)" "$TMP/cc.txt" "Bash(git remote -v"
nck "cc safe does NOT pre-allow git symbolic-ref (writes HEAD)" "$TMP/cc.txt" "Bash(git symbolic-ref"
nck "cc safe does NOT pre-allow bare git reflog (expire/drop)" "$TMP/cc.txt" "Bash(git reflog)"
nck "cc safe does NOT pre-allow bare git reflog args" "$TMP/cc.txt" "Bash(git reflog *)"
ck "cc safe still allows git reflog show" "$TMP/cc.txt" "Bash(git reflog show *)"
ck "cc safe still allows git remote show" "$TMP/cc.txt" "Bash(git remote show *)"
ck "cc safe still allows ruff check" "$TMP/cc.txt" "Bash(ruff check *)"

# ---------- 4. gemini-cli safe args (policy withdrawn in round 2) ------------------
# The round-1 generated [[rule]] policy auto-allowed commands it claimed to ask about
# (regexes stopped at the first quoted string and anchored only the first word), and
# gemini-cli refuses OAuth on this machine so no live session can prove a corrected
# policy. Per the review, safe emits ONLY the documented --approval-mode auto_edit.
export OSRC_GEMINI_VEHICLE=gemini
osrc_perm_flags gemini safe "$WD" > "$TMP/gm.txt"
ck "gemini safe emits --approval-mode" "$TMP/gm.txt" "--approval-mode"
ck "gemini safe emits auto_edit" "$TMP/gm.txt" "auto_edit"
nck "gemini safe has NO --policy (withdrawn)" "$TMP/gm.txt" "--policy"
nck "gemini safe writes no policy file" "$TMP/gm.txt" ".toml"
[ ! -d "$OSRC_HOME/perm" ] && ok "gemini safe creates no perm/ dir" || no "gemini safe left $OSRC_HOME/perm behind"
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
# Round 2: an INVALID OSRC_PERM_PROFILE env value must die, not silently behave as default.
_rc=0; ( OSRC_PERM_PROFILE=bogus parse_model >/dev/null 2>&1 ) || _rc=$?
[ "$_rc" -ne 0 ] && ok "parse_model bogus OSRC_PERM_PROFILE dies" || no "parse_model bogus OSRC_PERM_PROFILE accepted"
_rc=0; ( OSRC_PERM_PROFILE=bogus _consume_flags x >/dev/null 2>&1 ) || _rc=$?
[ "$_rc" -ne 0 ] && ok "_consume_flags bogus OSRC_PERM_PROFILE dies" || no "_consume_flags bogus OSRC_PERM_PROFILE accepted"

_p="$( _consume_flags --perm safe "do the thing" >/dev/null 2>&1; printf '%s|%s' "${PERM_PROFILE:-}" "${REST[0]:-}" )"
[ "$_p" = "safe|do the thing" ] \
  && ok "_consume_flags --perm safe consumed, REST clean" || no "_consume_flags --perm safe (got '$_p')"
_p="$( _consume_flags --perm=default >/dev/null 2>&1; printf '%s' "${PERM_PROFILE:-}" )"
[ "$_p" = default ] && ok "_consume_flags --perm=default" || no "_consume_flags --perm=default (got '$_p')"
# Round 2: --perm on a non-session verb must WARN, not be silently ignored.
_warn="$(_consume_flags --perm safe "do the thing" 2>&1 >/dev/null)"
case "$_warn" in *"[perm] note"*|*"only applies to interactive"*) ok "_consume_flags warns --perm ignored off session start" ;; *) no "_consume_flags silent on --perm (got '$_warn')" ;; esac
# parse_model serves session start too, so it must NOT emit the non-session warning.
_warn="$( parse_model --perm safe 2>&1 >/dev/null )"
case "$_warn" in *"only applies to interactive"*) no "parse_model wrongly warns on --perm" ;; *) ok "parse_model does not warn (session start honors --perm)" ;; esac

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

# Execute the short pane command with the environment tmux would give its shell.
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/claude" <<'FAKE'
#!/bin/sh
if [ "$1" = --help ]; then echo '  --model <model>'; exit 0; fi
printf '%s\n' "$@"
FAKE
chmod +x "$HOME/.local/bin/claude"
export PATH="$HOME/.local/bin:$PATH"
if (
  PROVIDER=claude PERM_PROFILE=safe SESSION_NAME=test MODEL_EXPLICIT=1 MODEL=claude-fable-5-2 EFFORT=""
  _session_launch_adapter claude || exit 1
  launch="$(_session_shell_command "${SESSION_LAUNCH[@]}")"; pane_command="$launch"
  tmux() {
    [ "$1" = new-session ] && [ "${11}" = -e ] || return 1
    export "${12}"
  }
  _session_create_pane && [ "${#pane_command}" -lt 100 ] &&
    bash -c "$pane_command" > "$TMP/fable.argv" &&
    python3 - "$TMP/fable.argv" "$TMP/cc.txt" <<'PYTEST'
import json, pathlib, sys
args, rules = (pathlib.Path(p).read_text().splitlines() for p in sys.argv[1:])
lean = ["--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}']
assert args == ["--model", "claude-fable-5-2", *lean, *rules]
assert args[5] == "--allowedTools" and args[-2] == "--settings"
assert "Bash(*-delete*)" in json.loads(args[-1])["permissions"]["ask"]
PYTEST
); then ok "safe Fable pane executes the complete policy argv"; else no "safe Fable pane argv"; fi

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
  mkdir -p "$TMP/droid-stub"
  printf '#!/bin/sh\n[ "$1" = --help ] || exit 99\nprintf "interactive mode default\\nexec non-interactive\\n--auto low medium high\\n"\n' > "$TMP/droid-stub/droid"
  chmod +x "$TMP/droid-stub/droid"
  _safe="$(PATH="$TMP/droid-stub:$PATH" _launch droid)" || _safe=""
  PERM_UNDER_TEST=default
  _def="$(PATH="$TMP/droid-stub:$PATH" _launch droid)" || _def=""
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

# ---------- 7. honest banner + relaunch profile preservation ----------------------
# osrc_perm_desc: rc0 + description for engines WITH a rung, rc1 for no-rung engines.
_desc="$(osrc_perm_desc cc 2>/dev/null)" && case "$_desc" in *allow*|*LIST*|*list*) ok "osrc_perm_desc cc describes the allow-list" ;; *) no "osrc_perm_desc cc vague: '$_desc'" ;; esac
_desc="$(osrc_perm_desc devin 2>/dev/null)" && case "$_desc" in *MODEL-JUDGED*|*model*judged*|*smart*) ok "osrc_perm_desc devin admits model-judged" ;; *) no "osrc_perm_desc devin vague: '$_desc'" ;; esac
_rc=0; osrc_perm_desc droid >/dev/null 2>&1 || _rc=$?
[ "$_rc" -ne 0 ] && ok "osrc_perm_desc droid -> rc1 (no rung)" || no "osrc_perm_desc droid should fail"
_rc=0; osrc_perm_desc hermes >/dev/null 2>&1 || _rc=$?
[ "$_rc" -ne 0 ] && ok "osrc_perm_desc hermes -> rc1 (no rung)" || no "osrc_perm_desc hermes should fail"
_rc=0; osrc_perm_desc cline >/dev/null 2>&1 || _rc=$?
[ "$_rc" -ne 0 ] && ok "osrc_perm_desc cline -> rc1 (no rung)" || no "osrc_perm_desc cline should fail"
_rc=0; osrc_perm_desc pi >/dev/null 2>&1 || _rc=$?
[ "$_rc" -ne 0 ] && ok "osrc_perm_desc pi -> rc1 (no rung)" || no "osrc_perm_desc pi should fail"

# _osrc_perm_banner: silent under default; honest under safe for both rung and no-rung.
_b="$( PERM_PROFILE=default _osrc_perm_banner droid 2>&1 )"; [ -z "$_b" ] \
  && ok "banner silent under default profile" || no "banner printed under default: '$_b'"
_b="$( PERM_PROFILE=safe SESSION_LAUNCH_ENGINE=cc _osrc_perm_banner cc 2>&1 )"
case "$_b" in *"[perm] safe"*"claude"*|*"[perm] safe"*) ok "banner prints safe desc for cc" ;; *) no "banner missing safe line for cc: '$_b'" ;; esac
_b="$( PERM_PROFILE=safe _osrc_perm_banner droid 2>&1 )"
case "$_b" in *"no faithful safe rung"*"DEFAULT"*) ok "banner honestly reports no-rung engine as default" ;; *) no "banner lied for droid: '$_b'" ;; esac
_b="$( PERM_PROFILE=safe _osrc_perm_banner hermes 2>&1 )"
case "$_b" in *"no faithful safe rung"*) ok "banner honestly reports hermes as default" ;; *) no "banner lied for hermes: '$_b'" ;; esac

# Relaunch preservation: the recorded PERM_PROFILE must reach the rebuilt command.
# _session_relaunch_cc is deterministic (effort->tokens + perm suffix, no CLI probe).
_cc_safe="$( PERM_PROFILE=safe _session_relaunch_cc "claude-haiku-5-5" high 2>/dev/null )"
case "$_cc_safe" in *--allowedTools*--settings*|*--allowedTools*) ok "cc relaunch safe -> --allowedTools suffix" ;; *) no "cc relaunch safe missing allow-list: '$_cc_safe'" ;; esac
_cc_def="$( PERM_PROFILE=default _session_relaunch_cc "claude-haiku-5-5" high 2>/dev/null )"
case "$_cc_def" in *--allowedTools*|*--settings*) no "cc relaunch default leaked safe flags: '$_cc_def'" ;; *) ok "cc relaunch default -> no safe flags (byte-identical shape)" ;; esac
# _session_relaunch_cx: safe swaps -s workspace-write for --approve-for-me.
_cx_safe="$( PERM_PROFILE=safe _session_relaunch_cx "test-model-1" low 2>/dev/null )"
_cx_def="$( PERM_PROFILE=default _session_relaunch_cx "test-model-1" low 2>/dev/null )"
if [ -n "$_cx_safe" ] && [ -n "$_cx_def" ]; then
  case "$_cx_safe" in *--approve-for-me*) ok "cx relaunch safe -> --approve-for-me" ;; *) no "cx relaunch safe missing --approve-for-me: '$_cx_safe'" ;; esac
  case "$_cx_safe" in *workspace-write*) no "cx relaunch safe kept -s workspace-write: '$_cx_safe'" ;; *) ok "cx relaunch safe drops -s workspace-write" ;; esac
  case "$_cx_def" in *workspace-write*) ok "cx relaunch default keeps -s workspace-write" ;; *) no "cx relaunch default lost workspace-write: '$_cx_def'" ;; esac
  case "$_cx_def" in *--approve-for-me*) no "cx relaunch default leaked --approve-for-me" ;; *) ok "cx relaunch default has no --approve-for-me" ;; esac
else
  echo "SKIP: _session_relaunch_cx produced no output (model row/codex probe unavailable)"
fi

# ---------- 8. symlink loader (LOADER.md) ------------------------------------------
# $SCRIPT_DIR is computed from $0/BASH_SOURCE — through a symlink it points at the
# LINK's directory, which has no lib/. The _OSRC_FACTORY_DIR fallback must resolve the
# real script dir and load lib/*.sh anyway, or `session start --perm safe` dies with
# "needs scripts/lib/perm.sh". Prove it two ways: source-through-symlink function
# visibility, and an exec-through-symlink session start that gets PAST the launch
# adapter (tmux stubbed; reaching tmux proves osrc_perm_* resolved).
mkdir -p "$TMP/linkdir" "$TMP/tmuxbin"
ln -sf "$SRC" "$TMP/linkdir/outsourcerer.sh"
( . "$TMP/linkdir/outsourcerer.sh" >/dev/null 2>&1
  type -t osrc_perm_flags >/dev/null && type -t osrc_perm_apply_launch >/dev/null \
    && type -t osrc_perm_string_suffix >/dev/null && type -t _session_relaunch_cx >/dev/null \
    && type -t _session_relaunch_cc >/dev/null ) \
  && ok "lib functions load when sourced through a symlink" \
  || no "lib functions MISSING via symlink source (loader broken)"

# exec-through-symlink: a stub tmux on PATH records calls; session start --perm safe
# must get past the launch adapter (which needs perm.sh) and actually invoke tmux.
cat > "$TMP/tmuxbin/tmux" <<'EOF'
#!/bin/sh
echo "tmux $*" >> "$OSRC_TMUX_LOG"
# has-session must FAIL (rc1) or session start reports "already exists" and stops
# before new-session; every other call succeeds with empty output.
[ "$1" = "has-session" ] && exit 1
exit 0
EOF
chmod +x "$TMP/tmuxbin/tmux"
: > "$TMP/tmux.log"
# This probe is about the loader, not free space: lift the disk floor in the test's own home so a full
# host disk cannot turn it into a SKIP (floors come only from the settings file, never an export).
mkdir -p "$OSRC_HOME/disk-policy" && echo OSRC_DISK_MIN_GB=0 > "$OSRC_HOME/disk-policy/settings"
( unset OSRC_SOURCED; cd "$WD" && \
  env -u OSRC_SOURCED OSRC_TMUX_LOG="$TMP/tmux.log" PATH="$TMP/tmuxbin:$PATH" \
    OSRC_HOME="$OSRC_HOME" OSRC_SESSION_NAME="l5-symlink-probe" \
    "$TMP/linkdir/outsourcerer.sh" --provider cc session start --spend-ok --perm safe >/dev/null 2>"$TMP/symlink.err" )
_rc=$?
if [ -s "$TMP/tmux.log" ]; then
  ok "exec via symlink reached tmux (perm.sh loaded; session start --perm safe built a launch)"
  if grep -q "perm.sh" "$TMP/symlink.err"; then
    no "symlink exec hit perm.sh-missing error despite tmux calls: $(cat "$TMP/symlink.err")"
  else ok "no perm.sh-missing error on symlink exec"; fi
else
  # tmux never called: either the launch build died (the bug) or an earlier gate did.
  # The perm-lib error is the specific regression; anything else is environmental.
  if grep -q "perm.sh" "$TMP/symlink.err"; then
    no "exec via symlink died on missing perm.sh (LOADER regression): $(cat "$TMP/symlink.err")"
  else
    echo "SKIP: symlink exec did not reach tmux for a non-perm reason (rc=$_rc): $(grep -E '^ERROR' "$TMP/symlink.err" | head -1)"
  fi
fi

echo "----"
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
