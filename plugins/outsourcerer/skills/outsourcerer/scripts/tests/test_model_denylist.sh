#!/usr/bin/env bash
# test_model_denylist.sh — OSRC_MODEL_DENYLIST must keep a model out of BOTH the recommendation and
# the dispatch path, and must be inert when unset.
#
# Why a denylist at all: a model can be one the caller must not use for reasons the tool cannot infer
# — a lane whose data-handling terms are unacceptable for this repo, a model that keeps failing this
# codebase's checks, a deprecated id that still scores well on benchmarks, an org policy. Today the
# only lever is remembering to avoid it on every call, which fails exactly when advise picks a model
# on its own.
#
# Two enforcement points, because either alone leaves a hole: filtering advise stops auto-selection
# from RECOMMENDING a denied model but does nothing about `-m <denied>`, and gating dispatch alone
# would let advise keep recommending a model that then dies at the gate.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
ADVISE_LIB="$SCRIPT_DIR/../lib/advise.sh"   # cmd_advise lives here since 0.17.4
[ -f "$ADVISE_LIB" ] || { echo "FAIL: cannot find $ADVISE_LIB"; exit 1; }
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

TMP="$(mktemp -d)"; export OSRC_HOME="$TMP"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

. "$SRC" >/dev/null 2>&1

# Note: assertions below read the source via command substitution rather than `awk ... | grep -q`.
# Under `set -o pipefail`, grep -q exits on its first match, awk dies of SIGPIPE (141), and the
# pipeline reports failure even though the pattern WAS found — a false negative that would make this
# suite fail against correct code.
body_of() { awk -v f="^$1\\\\(\\\\)" '$0 ~ f, /^}/' "$SRC"; }

# --- inert by default: an absent or empty list must not change any routing decision ---
unset OSRC_MODEL_DENYLIST
if _model_denied gpt-5.6-sol; then bad "a model was denied with no denylist set"
else ok "with no denylist set nothing is denied (default behavior unchanged)"; fi
if OSRC_MODEL_DENYLIST="" _model_denied gpt-5.6-sol; then bad "an empty denylist denied a model"
else ok "an empty denylist is treated as no denylist"; fi

# --- exact ids ---
OSRC_MODEL_DENYLIST="gpt-5.5" _model_denied gpt-5.5 \
  && ok "an exact resolved id is denied" || bad "an exact id was not denied"
OSRC_MODEL_DENYLIST="gpt-5.5" _model_denied gpt-5.6-sol \
  && bad "denying gpt-5.5 also denied an unrelated model" \
  || ok "only the listed id is denied, neighbours are untouched"

# --- separators: a list is easier to get wrong than a single value, so accept both ---
for list in "gemini-3.5-flash,gpt-5.5" "gemini-3.5-flash gpt-5.5" "gemini-3.5-flash, gpt-5.5"; do
  if OSRC_MODEL_DENYLIST="$list" _model_denied gpt-5.5 \
     && OSRC_MODEL_DENYLIST="$list" _model_denied gemini-3.5-flash; then
    ok "multi-entry list parsed with separator style: '$list'"
  else
    bad "list '$list' did not deny both entries"
  fi
done

# --- globs: a family is denied without enumerating every dated release ---
OSRC_MODEL_DENYLIST="gemini-3.5-*" _model_denied gemini-3.5-flash \
  && ok "a glob denies a whole family" || bad "glob pattern did not match"
OSRC_MODEL_DENYLIST="gemini-3.5-*" _model_denied gemini-3.7-flash \
  && bad "the glob over-matched into another version" \
  || ok "the glob does not leak into a version it was not meant to cover"

# --- bracket-bearing ids are literal, not glob classes (torture regression) ---
# Real model ids carry brackets, e.g. claude-opus-4-8[1m]. An unquoted `case $id in $pat` reads the
# `[1m]` as a character class, so denying the id by its own literal string silently did nothing AND
# the pattern over-matched unrelated ids like claude-opus-4-81. An exact-match-first pass fixes both.
OSRC_MODEL_DENYLIST="claude-opus-4-8[1m]" _model_denied "claude-opus-4-8[1m]" \
  && ok "a bracket-bearing id is denied by its own literal string" \
  || bad "a bracket id was NOT denied by its exact entry (the [..] was treated as a glob class)"
OSRC_MODEL_DENYLIST="claude-opus-4-8[1m]" _model_denied "claude-opus-4-81" \
  && bad "the bracket entry over-matched an unrelated id (claude-opus-4-81)" \
  || ok "a bracket entry does not over-match a neighbouring id"
# and the documented '*' family glob still works after the fix
OSRC_MODEL_DENYLIST="gemini-3.5-*" _model_denied "gemini-3.5-flash" \
  && ok "a '*' family glob still matches after the bracket fix" \
  || bad "the '*' family glob stopped working"

# --- the list is split with globbing OFF, so the cwd cannot rewrite an entry (torture regression) ---
# Splitting an unquoted list performs PATHNAME expansion as well as word splitting. Run from a
# directory that happens to hold a file matching the pattern and `gemini-3.5-*` becomes that
# filename, so the family entry silently stops denying its family — a deny that fails only on some
# machines, in some directories. The fix splits under `set -f`.
mkdir -p "$TMP/globdir"
touch "$TMP/globdir/gemini-3.5-oops"
if ( cd "$TMP/globdir" && OSRC_MODEL_DENYLIST='gemini-3.5-*' _model_denied gemini-3.5-flash ); then
  ok "a '*' family entry still denies from a cwd holding a file that matches the pattern"
else
  bad "the cwd's files rewrote the '*' family entry and the model was not denied"
fi

# --- and the caller's glob state comes back exactly as it was ---
# `set -f` is process-wide: leaving it on would break every later unquoted expansion in the script
# (path globs in dispatch, receipts, log rotation), and turning it off would silently re-enable
# globbing for a caller that deliberately disabled it.
OSRC_MODEL_DENYLIST='gemini-3.5-*' _model_denied gemini-3.5-flash
case "$-" in
  *f*) bad "_model_denied left globbing disabled (-f leaked into the caller)" ;;
  *)   ok "_model_denied restores globbing for a caller that had it on" ;;
esac
set -f
OSRC_MODEL_DENYLIST='gemini-3.5-*' _model_denied gemini-3.5-flash
case "$-" in
  *f*) ok "_model_denied preserves a caller's own 'set -f'" ;;
  *)   bad "_model_denied re-enabled globbing for a caller that had set -f" ;;
esac
set +f

# --- bracket ids stay literal even from a cwd that could expand them ---
# The exact-match-first pass and the -f split have to hold together: with a file named
# claude-opus-4-81 sitting in the cwd, an unguarded split expands `claude-opus-4-8[1m]` to that
# filename, which both loses the deny on the real id and invents one on its neighbour.
touch "$TMP/globdir/claude-opus-4-81"
if ( cd "$TMP/globdir" && OSRC_MODEL_DENYLIST='claude-opus-4-8[1m]' _model_denied 'claude-opus-4-8[1m]' ); then
  ok "a bracket-bearing id is denied by its literal string even from a cwd holding a matching file"
else
  bad "the cwd's files rewrote the bracket entry and the id was not denied"
fi
if ( cd "$TMP/globdir" && OSRC_MODEL_DENYLIST='claude-opus-4-8[1m]' _model_denied 'claude-opus-4-81' ); then
  bad "the bracket entry over-matched claude-opus-4-81 from a cwd holding that filename"
else
  ok "a bracket entry does not over-match a neighbouring id from such a cwd"
fi

# --- matched against the RESOLVED id, never the alias ---
# An alias is a nickname; several can point at one model, and new ones get added. Denying the alias
# would leave every other route to the same model open, which is a denylist that does not deny.
OSRC_MODEL_DENYLIST="z-ai/glm-5.2" _model_denied "$(resolve_model_row glm | cut -d'|' -f1)" \
  && ok "denying a resolved id catches the model no matter which alias reaches it" \
  || bad "a denied model was reachable through one of its aliases"

# --- both enforcement points are wired, and neither is the only one ---
# cmd_advise hands the denylist to the scorer in lib/advise.sh; the behavioural check below proves
# the scorer honours it, so this only pins that the hand-off is still wired.
case "$(awk '/^cmd_advise\(\)/,/^}/' "$ADVISE_LIB")" in
  *OSRC_MODEL_DENYLIST*) ok "advise passes the denylist to its candidate scoring" ;;
  *) bad "advise no longer passes OSRC_MODEL_DENYLIST to its scorer" ;;
esac
# Behaviour: with a seeded benchmark cache and two candidates, a denied model must disappear from
# advise output, and must be present without the denylist (so the absence is the denylist's doing).
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  _adv_json() {  # <denylist> -> the candidate model ids advise lists, one per line
    ( refresh_benchmarks() { return 1; }
      OSRC_MODEL_DENYLIST="$1" cmd_advise --json "refactor the parser" 2>/dev/null | jq -r '.candidates[].model' )
  }
  mkdir -p "$OSRC_HOME/catalogs"
  cat > "$OSRC_BENCH_JSON" <<'BJSON'
{"data":[
 {"model_permaslug":"openai/gpt-5.6-sol-20260709","intelligence_index":58.9,"coding_index":77.4,"agentic_index":54,"pricing":{"prompt":"0.000005","completion":"0.00003"}},
 {"model_permaslug":"z-ai/glm-5.2-20260616","intelligence_index":51.1,"coding_index":68.8,"agentic_index":43.1,"pricing":{"prompt":"0.0000014","completion":"0.0000044"}}],
 "meta":{"as_of":"2026-11-19T00:00:00.000Z","model_count":2}}
BJSON
  printf 'gpt-5.6-sol|openai/gpt-5.6-sol|cx|raw\nglm-5.2|z-ai/glm-5.2|or|raw\n' > "$OSRC_HOME/models.local"
  _open="$(_adv_json "")"; _denied="$(_adv_json "openai/gpt-5.6-sol")"
  case "$_open" in *openai/gpt-5.6-sol*) ok "control: without a denylist advise lists the model" ;;
    *) bad "control failed: advise did not list openai/gpt-5.6-sol with no denylist: $_open" ;; esac
  case "$_denied" in
    *openai/gpt-5.6-sol*) bad "advise listed a denied model: $_denied" ;;
    *z-ai/glm-5.2*) ok "advise drops a denied model and keeps the allowed one" ;;
    *) bad "denylist emptied advise instead of filtering one model: '$_denied'" ;;
  esac
  rm -f "$OSRC_HOME/models.local"
else
  echo "SKIP: jq or python3 absent (advise behaviour check)"
fi
case "$(body_of route_delegate)" in
  *_model_denied*) ok "dispatch refuses a denied model, so an explicit -m cannot bypass the list" ;;
  *) bad "-m <denied> still reaches a delegate" ;;
esac
# The refusal must land before the route is announced/receipted, like the quota gate: announcing a
# route that then dies reads as a lane failure rather than a policy decision the user configured.
_order="$(body_of route_delegate | grep -n '_model_denied\|_route_resolution "\$disp"' | head -2)"
case "$_order" in
  *_model_denied*_route_resolution*|*_model_denied*) ok "the denylist refusal precedes the route announcement" ;;
  *) bad "a denied model is announced as a route before being refused" ;;
esac

# The error has to name the knob: a refusal the user cannot trace back to their own config reads as
# a bug in the tool.
grep -q 'OSRC_MODEL_DENYLIST and will not be dispatched' "$SRC" \
  && ok "the refusal names the setting that caused it" \
  || bad "the refusal does not say why the model was refused"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
