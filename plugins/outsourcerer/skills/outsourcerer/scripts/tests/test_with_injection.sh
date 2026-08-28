#!/usr/bin/env bash
# test_with_injection.sh — a granted capability must actually arrive, or the caller must be told it did not.
#
# `--with skills=<name>` resolved ONLY ~/.claude/skills/<name>/SKILL.md. Every skill that ships inside a
# PLUGIN (the entire ce-* family) lives in a versioned plugin cache instead, so it silently resolved to
# "NOT FOUND", the note went into the PROMPT where only the delegate could read it, and the caller went on
# believing the delegate had the skill. Delegations ran for a whole session without the capability they
# were briefed to use, and nothing anywhere said so.
#
# The second half is size. A SKILL.md can be ~100KB. Pasting several verbatim buys latency and spend on
# every delegation, and on a lane that prints nothing until it finishes, a bloated prompt is
# indistinguishable from a hang.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

. "$SRC" >/dev/null 2>&1
type -t _resolve_skill_file  >/dev/null || { echo "FAIL: _resolve_skill_file not loaded"; exit 1; }
type -t build_with_preamble  >/dev/null || { echo "FAIL: build_with_preamble not loaded"; exit 1; }
type -t _validate_with_token >/dev/null || { echo "FAIL: _validate_with_token not loaded"; exit 1; }

# --- an unrecognized --with spec must be REJECTED at parse time, not silently dropped ----------
# Only skills= and mcp= are honored at injection time. Anything else (e.g. a bare file path someone
# passes expecting file-attach) used to be stored and then dropped with NO error and NO warning, so
# the delegate ran with none of the intended context and nothing told the caller. _validate_with_token
# makes the footgun loud. die exits the process, so each check runs in a subshell.
( _validate_with_token "skills=a,b" ) >/dev/null 2>&1 && ok "skills= spec accepted" || bad "skills= spec wrongly rejected"
( _validate_with_token "mcp=x" )     >/dev/null 2>&1 && ok "mcp= spec accepted"     || bad "mcp= spec wrongly rejected"
( _validate_with_token "/tmp/brief.txt" ) >/dev/null 2>&1 && bad "a bare file path was accepted (silent no-op returns)" || ok "a bare file path is rejected, not silently dropped"
( _validate_with_token "attach=/tmp/brief.txt" ) >/dev/null 2>&1 && bad "an unknown form= spec was accepted" || ok "an unrecognized form= spec is rejected"
# The rejection message must name the spec and point at the valid forms, so the caller can fix it.
_werr="$( ( _validate_with_token "/tmp/brief.txt" ) 2>&1 >/dev/null )"
case "$_werr" in *"skills=a,b"*"mcp=x"*"/tmp/brief.txt"*) ok "the rejection names the spec and the valid forms" ;;
  *) bad "rejection message is missing guidance/spec: $_werr" ;; esac

# --- empty values (skills= / mcp=) are silent no-ops of the same class — must be rejected -------
( _validate_with_token "skills=" ) >/dev/null 2>&1 && bad "empty skills= was accepted (silent no-op)" || ok "empty skills= is rejected"
( _validate_with_token "mcp=" )    >/dev/null 2>&1 && bad "empty mcp= was accepted (silent no-op)"    || ok "empty mcp= is rejected"

# --- whitespace smuggling: a multi-token --with arg with an invalid trailing token -------------
# WITH_SPEC is space-delimited and iterated unquoted at injection time, so "skills=a,b /tmp/brief.txt"
# splits into two tokens. Validating only the prefix would let the bare path through and silently drop
# it at injection — the exact footgun this fix targets. Every token must be validated.
( _validate_with_token "skills=a,b mcp=x" ) >/dev/null 2>&1 && ok "a multi-token spec with all valid forms is accepted" || bad "a valid multi-token spec was wrongly rejected"
( _validate_with_token "skills=a,b /tmp/brief.txt" ) >/dev/null 2>&1 && bad "a multi-token spec with an invalid trailing token was accepted" || ok "a multi-token spec with an invalid trailing token is rejected"
_wsmerr="$( ( _validate_with_token "skills=a,b /tmp/brief.txt" ) 2>&1 >/dev/null )"
case "$_wsmerr" in *"/tmp/brief.txt"*) ok "the whitespace-smuggling rejection names the bad token, not just the prefix" ;;
  *) bad "whitespace-smuggling rejection does not name the bad token: $_wsmerr" ;; esac

# --- resolution must cover more than the user's own skills dir ------------------------------------
# Fixture: a plugin-cache layout and a parity dir, neither of which the old resolver looked at.
mkdir -p "$TMP/home/.claude/skills/mine" \
         "$TMP/home/.config/devin/skills/parityskill" \
         "$TMP/home/.claude/plugins/cache/mkt/someplugin/1.0.0/skills/plugskill" \
         "$TMP/home/.claude/plugins/cache/mkt/someplugin/2.0.0/skills/plugskill"
printf 'mine\n'        > "$TMP/home/.claude/skills/mine/SKILL.md"
printf 'parity\n'      > "$TMP/home/.config/devin/skills/parityskill/SKILL.md"
printf 'old version\n' > "$TMP/home/.claude/plugins/cache/mkt/someplugin/1.0.0/skills/plugskill/SKILL.md"
printf 'new version\n' > "$TMP/home/.claude/plugins/cache/mkt/someplugin/2.0.0/skills/plugskill/SKILL.md"

HOME_REAL="$HOME"; HOME="$TMP/home"
r_mine="$(_resolve_skill_file mine 2>/dev/null)"
r_par="$(_resolve_skill_file parityskill 2>/dev/null)"
r_plug="$(_resolve_skill_file plugskill 2>/dev/null)"
r_none="$(_resolve_skill_file definitely-not-a-skill 2>/dev/null)"
HOME="$HOME_REAL"

[ -n "$r_mine" ] && ok "a skill in the user's own dir still resolves" || bad "user skill no longer resolves"
[ -n "$r_par" ]  && ok "a skill in the parity dir resolves"           || bad "parity skill not found"
[ -n "$r_plug" ] && ok "a PLUGIN-cache skill resolves (this is the whole ce-* family)" \
                 || bad "plugin-cache skill still not found"
case "$r_plug" in *2.0.0*) ok "the NEWEST plugin version wins, so an upgrade is not shadowed by an old copy" ;;
  *) bad "resolved a stale plugin version: $r_plug" ;; esac
[ -z "$r_none" ] && ok "a genuinely missing skill still resolves to nothing" || bad "invented a path for a missing skill"

# --- a capability that does NOT arrive must be reported to the CALLER, not only to the delegate ----
err="$(WITH_SPEC="skills=definitely-not-a-skill" build_with_preamble 2>&1 >/dev/null)"
case "$err" in *"NOT FOUND"*) ok "a missing skill is announced on stderr where the caller can see it" ;;
  *) bad "a missing skill is still reported only inside the prompt" ;; esac
case "$err" in *"WITHOUT it"*) ok "the warning states the delegate is running without the capability" ;;
  *) bad "the warning does not say the delegate lacks the skill" ;; esac

# --- injection must be bounded --------------------------------------------------------------------
mkdir -p "$TMP/home/.claude/skills/huge"
head -c 90000 /dev/zero | tr '\0' 'x' > "$TMP/home/.claude/skills/huge/SKILL.md"
HOME="$TMP/home"
out="$(WITH_SPEC="skills=huge" OSRC_WITH_MAX_BYTES=5000 build_with_preamble 2>/dev/null)"
werr="$(WITH_SPEC="skills=huge" OSRC_WITH_MAX_BYTES=5000 build_with_preamble 2>&1 >/dev/null)"
HOME="$HOME_REAL"

[ "$(printf '%s' "$out" | wc -c)" -lt 20000 ] \
  && ok "an oversized skill is truncated instead of pasted whole into every prompt" \
  || bad "the whole oversized skill was injected ($(printf '%s' "$out" | wc -c) bytes)"
case "$out" in *TRUNCATED*) ok "the truncation is visible to the delegate, with the full path to read" ;;
  *) bad "truncation is silent, so the delegate cannot tell it got a partial doc" ;; esac
case "$werr" in *OSRC_WITH_MAX_BYTES*) ok "the caller is told, and told which knob raises the cap" ;;
  *) bad "truncation is not surfaced to the caller" ;; esac

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
