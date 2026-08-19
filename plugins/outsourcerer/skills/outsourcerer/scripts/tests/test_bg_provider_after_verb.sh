#!/usr/bin/env bash
# test_bg_provider_after_verb.sh — an explicit --provider is AUTHORITATIVE in the bg lane, wherever it sits.
#
# The bug (lane routing): cmd_bg's flag loop only consumed a --provider written BEFORE the verb. So
# `bg run --provider droid -m kimi-k3` left PROVIDER at the devin DEFAULT, and the detached child wrote
# meta.json with provider=devin / lane=dv (plus the devin stall-floor and a devin ledger row) even though
# the user explicitly asked for the droid lane. The open-weight alias kimi-k3 then resolved to a Devin id
# and the job ran on the WRONG engine — in the field, onto an exhausted Devin quota. `bg --provider droid
# run …` (provider before the verb) always worked; only the post-verb position silently fell back. The
# claude/codex aliases hard-die on the wrong lane, so this open-weight silent-fallback was the asymmetry.
#
# Two layers:
#   UNIT  — _bg_capture_provider (the fix's seam) sets PROVIDER/PROVIDER_EXPLICIT from a --provider ANYWHERE
#           in the argv and strips it, for EVERY lane and both flag positions. Fast, deterministic, no I/O.
#   E2E   — a real `bg run --provider <lane> …` records that lane in meta.json and NEVER dv. Sandboxed via
#           OSRC_HOME with fake lane CLIs. Two lanes (droid/warp) as an integration smoke; SKIPs w/o jq.
#
# Run: bash test_bg_provider_after_verb.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Source functions only (drop the `main "$@"` dispatcher) so nothing runs on load.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-bgprov.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
SRC_ONLY="$TMP/src.sh"
sed '/^[[:space:]]*main "\$@"[[:space:]]*$/d' "$SRC" > "$SRC_ONLY"
export OSRC_HOME="$TMP/home"; export OSRC_SOURCED=1; mkdir -p "$OSRC_HOME"
# shellcheck disable=SC1090
. "$SRC_ONLY" >/dev/null 2>&1
type -t _bg_capture_provider >/dev/null || { echo "FAIL: _bg_capture_provider not defined (fix missing?)"; exit 1; }

# ------------------------------------------------------------------------------------------------------
# UNIT: _bg_capture_provider sets PROVIDER (+EXPLICIT) and strips the flag, for every lane / position.
# ------------------------------------------------------------------------------------------------------
# <desc> <want-provider> <expected-remaining-argv-joined-by-space> -- <argv...>
capture_case() {
  local desc="$1" wantp="$2" wantargv="$3"; shift 3; [ "$1" = "--" ] && shift
  PROVIDER=devin; PROVIDER_EXPLICIT=0; _BG_ARGV=()
  _bg_capture_provider "$@"
  local gotargv="${_BG_ARGV[*]}"
  if [ "$PROVIDER" != "$wantp" ]; then
    bad "$desc: PROVIDER='$PROVIDER' (expected '$wantp')"
  elif [ "$PROVIDER_EXPLICIT" != "1" ]; then
    bad "$desc: PROVIDER_EXPLICIT='$PROVIDER_EXPLICIT' (expected 1 — explicit lane not marked authoritative)"
  elif [ "$gotargv" != "$wantargv" ]; then
    bad "$desc: stripped argv='$gotargv' (expected '$wantargv')"
  else
    ok "$desc: PROVIDER=$wantp, flag stripped"
  fi
}

# Every lane, --provider AFTER the verb (the bug): captured, and never left as the devin default.
for lane in devin cc codex droid cursor hermes warp cline gemini gm claudex local; do
  capture_case "post-verb $lane" "$lane" "run -m kimi-k3 the task" -- run --provider "$lane" -m kimi-k3 "the task"
done
# Position independence: --provider before the verb, and interleaved after -m.
capture_case "pre-verb droid"          droid "run -m kimi-k3 t" -- --provider droid run -m kimi-k3 t
capture_case "after -m, cline"         cline "run -m kimi-k3 t" -- run -m kimi-k3 --provider cline t
capture_case "trailing, warp"          warp  "run -m glm t"     -- run -m glm t --provider warp
# Last --provider wins (a later flag overrides).
capture_case "last wins: droid->warp"  warp  "run -m kimi-k3 t" -- run --provider droid -m kimi-k3 --provider warp t

# No --provider at all: PROVIDER stays the default and EXPLICIT stays 0 (the default path is untouched).
PROVIDER=devin; PROVIDER_EXPLICIT=0; _BG_ARGV=()
_bg_capture_provider run -m glm "a task"
if [ "$PROVIDER" = "devin" ] && [ "$PROVIDER_EXPLICIT" = "0" ] && [ "${_BG_ARGV[*]}" = "run -m glm a task" ]; then
  ok "no --provider: default lane + argv preserved, EXPLICIT stays 0"
else
  bad "no --provider: PROVIDER='$PROVIDER' EXPLICIT='$PROVIDER_EXPLICIT' argv='${_BG_ARGV[*]}' (nothing should change)"
fi

# Equals spelling (`--provider=X`) must be captured too, not left in argv to silently ride the default.
capture_case "equals-form, post-verb droid" droid "run -m kimi-k3 t" -- run --provider=droid -m kimi-k3 t
capture_case "equals-form, before verb warp" warp  "run -m kimi-k3 t" -- --provider=warp run -m kimi-k3 t
capture_case "equals wins over prior space"  cline "run -m kimi-k3 t" -- run --provider droid -m kimi-k3 --provider=cline t

# A dangling --provider with no value must die (matches the leading-loop parser).
if ( _bg_capture_provider run --provider ) >/dev/null 2>&1; then
  bad "dangling --provider with no value did not die"
else
  ok "dangling --provider with no value dies (parser parity)"
fi
# An empty value in either spelling must die loud, not set PROVIDER="" EXPLICIT=1.
if ( _bg_capture_provider run --provider "" ) >/dev/null 2>&1; then
  bad "empty space-form value did not die"
else
  ok "empty --provider '' value dies loud"
fi
if ( _bg_capture_provider run --provider= ) >/dev/null 2>&1; then
  bad "empty equals-form value did not die"
else
  ok "empty --provider= value dies loud"
fi
# The happy path must return 0 — a bare `&& die` as the last line would leak exit status 1 into a
# future `set -e` / `|| die` caller. (Regression guard for fable-5's finding.)
PROVIDER=devin; PROVIDER_EXPLICIT=0; _BG_ARGV=()
_bg_capture_provider run --provider droid -m kimi-k3 t; rc=$?
[ "$rc" = "0" ] && ok "capture returns 0 on the happy path" || bad "capture returned rc=$rc on the happy path (leaks into set -e callers)"

# A newline in the task text must not corrupt argv splitting (arrays, not word-splitting).
PROVIDER=devin; PROVIDER_EXPLICIT=0; _BG_ARGV=()
_bg_capture_provider run --provider droid -m kimi-k3 "$(printf 'line1\nline2')"
if [ "$PROVIDER" = "droid" ] && [ "${#_BG_ARGV[@]}" = "4" ] && [ "${_BG_ARGV[3]}" = "$(printf 'line1\nline2')" ]; then
  ok "multiline task preserved as one argv element"
else
  bad "multiline task mangled: count=${#_BG_ARGV[@]} last='${_BG_ARGV[*]: -1}'"
fi

# ------------------------------------------------------------------------------------------------------
# E2E: a real `bg run --provider <lane>` writes that lane into meta.json, never dv. (droid/warp smoke.)
# ------------------------------------------------------------------------------------------------------
if have jq; then
  FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
  for b in droid oz; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/$b"; chmod +x "$FAKEBIN/$b"; done
  e2e_lane() {   # <lane> <bg-args...>
    local lane="$1"; shift
    local home="$TMP/e2e.$RANDOM"; mkdir -p "$home"
    local id
    # OSRC_SOURCED must be UNSET for the child: we exported it =1 to source functions above, but the child
    # is a real run and OSRC_SOURCED=1 would make it skip main() and never launch.
    id="$( PATH="$FAKEBIN:$PATH" OSRC_HOME="$home" OSRC_SOURCED= OSRC_CLOUD_ACK=1 OUTSOURCERER_DEPTH=0 OSRC_NO_ADVISE=1 \
           bash "$SRC" bg "$@" 2>/dev/null | head -1 )"
    local jd="$home/jobs/$id" i=0
    while [ "$i" -lt 60 ]; do [ -f "$jd/meta.json" ] && break; i=$((i+1)); sleep 0.1; done
    [ -f "$jd/meta.json" ] || { bad "e2e $lane: no meta.json was written"; return; }
    local got; got="$(jq -r '.lane // ""' "$jd/meta.json" 2>/dev/null)"
    if [ "$got" = "$lane" ]; then ok "e2e post-verb --provider $lane -> meta.json lane=$lane (not dv)"
    else bad "e2e post-verb --provider $lane -> meta.json lane='$got' (expected $lane; dv means the bug)"; fi
  }
  e2e_lane droid run --provider droid -m kimi-k3 "say hi"
  e2e_lane warp  run --provider warp  -m kimi-k3 "say hi"
else
  echo "SKIP: jq absent — end-to-end meta.json checks skipped (unit layer still ran)"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
