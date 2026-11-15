#!/usr/bin/env bash
# test_noglob_splitting.sh — user-provided lists are split without pathname expansion, so a file
# in the cwd can never rewrite a --with spec or a --route pattern.
#
# Root cause guarded: `for tok in $spec` (unquoted) is word splitting AND globbing. In a directory
# holding a file named `skills=x`, `--with '*'` validated as a real spec while WITH_SPEC kept the raw
# `*` for injection, where it was dropped in silence. `--route 'gemini-3.5-*=glm'` silently missed
# next to a file named gemini-3.5-oops. A whitespace-only --with split to zero tokens, passed the
# validator, and then crashed _secret_scan on an empty array under set -u.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/.test-noglob.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
export HOME="$TMP/home"
mkdir -p "$OSRC_HOME" "$HOME" "$TMP/globdir"
touch "$TMP/globdir/skills=planted" "$TMP/globdir/mcp=planted" "$TMP/globdir/gemini-3.5-oops" "$TMP/globdir/k1"

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

set --
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
type -t _words_noglob >/dev/null || { echo "FAIL: _words_noglob not loaded"; exit 1; }
type -t _validate_with_token >/dev/null || { echo "FAIL: _validate_with_token not loaded"; exit 1; }
type -t _route_match >/dev/null || { echo "FAIL: _route_match not loaded"; exit 1; }

cd "$TMP/globdir"

# --- _words_noglob -------------------------------------------------------------------------------
_words_noglob '*'
[ "${#WORDS[@]}" = 1 ] && [ "${WORDS[0]}" = '*' ] && ok "_words_noglob keeps a literal * (no pathname expansion)" || bad "_words_noglob expanded * into: ${WORDS[*]:-}"
_words_noglob ''
[ "${#WORDS[@]}" = 0 ] && ok "_words_noglob yields an empty array for an empty string" || bad "_words_noglob gave ${#WORDS[@]} words for ''"
_words_noglob 'a b  c'
[ "${#WORDS[@]}" = 3 ] && ok "_words_noglob splits on runs of whitespace" || bad "_words_noglob gave ${#WORDS[@]} words for 'a b  c'"
case "$-" in *f*) bad "_words_noglob left globbing disabled in the caller" ;; *) ok "_words_noglob restores the caller's glob state" ;; esac
set -f; _words_noglob 'x'; case "$-" in *f*) ok "_words_noglob preserves a caller's own set -f" ;; *) bad "_words_noglob re-enabled globbing on a set -f caller" ;; esac; set +f
f() { _words_noglob 'p q'; printf '%s' "$#"; }
[ "$(f one two three)" = 3 ] && ok "_words_noglob leaves the caller's positional parameters alone" || bad "caller's \$# changed"

# --- --with validator ----------------------------------------------------------------------------
( _validate_with_token '*' ) >/dev/null 2>&1 && bad "--with '*' accepted in a cwd holding skills=planted (glob bypass)" || ok "--with '*' is rejected even when the cwd holds a skills=… file"
_err="$( ( _validate_with_token '*' ) 2>&1 >/dev/null )"
case "$_err" in *"got '*'"*) ok "the rejection names the literal spec, not a cwd filename" ;; *) bad "rejection names something else: $_err" ;; esac
_gerr="$( ( _validate_with_token 'skills=*' ) 2>&1 >/dev/null )"; _grc=$?
[ "$_grc" -ne 0 ] && ok "a glob-char skill name dies at validation (skills=* cannot name a skill)" || bad "skills=* passed validation"
case "$_gerr" in *"invalid name '*'"*) ok "the invalid-name rejection names the literal '*', never a cwd filename" ;; *) bad "invalid-name rejection wrong: $_gerr" ;; esac
( _validate_with_token ' ' ) >/dev/null 2>&1 && bad "a whitespace-only --with was accepted (silent no-op)" || ok "a whitespace-only --with is rejected"
( _validate_with_token '	' ) >/dev/null 2>&1 && bad "a tab-only --with was accepted" || ok "a tab-only --with is rejected"
_werr="$( ( _validate_with_token '  ' ) 2>&1 >/dev/null )"
case "$_werr" in *whitespace-only*) ok "the whitespace rejection says why" ;; *) bad "whitespace rejection message unclear: $_werr" ;; esac
( _validate_with_token 'skills=a,b mcp=x' ) >/dev/null 2>&1 && ok "a valid multi-token spec is still accepted" || bad "valid multi-token spec rejected"
_nlerr="$( ( _validate_with_token "$(printf 'skills=a\nmcp=x')" ) 2>&1 >/dev/null )"; _nlrc=$?
[ "$_nlrc" -ne 0 ] && case "$_nlerr" in *CR/LF*) ok "a literal newline in a --with spec dies naming the CR/LF rule" ;;
  *) bad "newline death wrong: $_nlerr" ;; esac
[ "$_nlrc" -ne 0 ] || bad "a newline-bearing spec was accepted"
( _validate_with_token "$(printf 'skills=a\n/tmp/brief.txt')" ) >/dev/null 2>&1 && bad "a bad token after a newline slipped through" || ok "a bad token after a newline is still caught"

# --- _secret_scan survives a whitespace-only WITH_SPEC (defence in depth) --------------------------
_se="$( WITH_SPEC=' ' OSRC_SECRET_SCAN_DEEP=0 _secret_scan "hello" glm 2>&1 )"; _src=$?
case "$_se" in *"unbound variable"*) bad "_secret_scan crashed on a whitespace-only WITH_SPEC: $_se" ;; *) ok "_secret_scan tolerates a whitespace-only WITH_SPEC (rc=$_src)" ;; esac

# --- --route patterns ----------------------------------------------------------------------------
r="$(_route_match gemini-3.5-flash 'gemini-3.5-*=glm')"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = glm ] && ok "--route 'gemini-3.5-*=glm' matches next to a file named gemini-3.5-oops" || bad "--route glob pattern silently missed in a colliding cwd (rc=$rc, got '$r')"
r="$(_route_match k1 'k*=fast, other=slow')"; rc=$?
[ "$rc" -eq 0 ] && [ "$r" = fast ] && ok "--route multi-pair list with spaces still matches" || bad "--route multi-pair failed (rc=$rc, got '$r')"
_route_match nomatch 'gemini-3.5-*=glm' >/dev/null 2>&1 && bad "--route matched a label it should not" || ok "--route non-match still returns 1"
case "$-" in *f*) bad "_route_match left globbing disabled" ;; *) ok "_route_match restores the caller's glob state" ;; esac

# --- malformed comma lists FAIL, never silently normalize -------------------------------------------
# "mcp=one," used to return rc=0 having dropped the empty member: the grant written and the grant
# honored disagreed. Leading, trailing, adjacent, and whitespace-only members all die, for skills
# and mcp alike; a spaced list of real members stays legal.
for _spec in 'skills=,a' 'skills=a,' 'skills=a,,b' 'skills=a, ,b' \
             'mcp=,a' 'mcp=one,' 'mcp=a,,b' 'mcp=a, ,b' 'mcp=a, '; do
  ( _validate_with_token "$_spec" ) >/dev/null 2>&1 \
    && bad "malformed list accepted: $_spec" || ok "malformed list dies: $_spec"
done
_err="$( ( _validate_with_token 'mcp=one,' ) 2>&1 >/dev/null )"
case "$_err" in *malformed*"empty member"*) ok "the malformed-list death says why" ;;
  *) bad "malformed-list message wrong: $_err" ;; esac
( _validate_with_token 'mcp=a, b' ) >/dev/null 2>&1 \
  && ok "a spaced list with non-empty members stays legal" || bad "a legal spaced list was refused"

cd "$TMP"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
