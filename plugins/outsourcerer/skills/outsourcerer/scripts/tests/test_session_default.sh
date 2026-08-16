#!/usr/bin/env bash
# test_session_default.sh — D4 interactive-default: mutating/approval-prone verbs (edit/yolo/research)
# open a STEERABLE session by default instead of headless bg, while the genuinely-headless callers
# (CI/detached/fanout/inside-a-job/preflight) and the explicit opt-out still get bg. The promotion
# branch must run BEFORE the auto-detach branch in route_delegate so the session default wins.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

# Extract just _session_should + _session_backend_available so we exercise the decision in isolation,
# with tmux forced "available" via a stub on PATH (the tests assert routing logic, not tmux itself).
STUB="$(mktemp -d)"; printf '#!/bin/sh\nexit 0\n' > "$STUB/tmux"; chmod +x "$STUB/tmux"
trap 'rm -rf "$STUB"' EXIT
_should() { # <verb> <env-assignments...> -> rc of _session_should (0=session, 1=bg); DISP env sets the lane
  local verb="$1"; shift
  local envs=( "$@" )
  ( PATH="$STUB:$PATH"; SCRIPT_DIR="$HERE/.."
    set --                       # clear positionals so sourcing doesn't try to dispatch a subcommand
    . "$SRC" >/dev/null 2>&1
    # neutralize any ambient exclusions unless the case sets them
    unset OSRC_NO_SESSION OSRC_NO_AUTODETACH OSRC_STREAM OSRC_JOB_DIR OSRC_FANOUT_CHILD OSRC_PREFLIGHT OSRC_CI OSRC_FORCE_SESSION OSRC_MAX_MINUTES CI GITHUB_ACTIONS 2>/dev/null || true
    local _disp=devin
    for e in ${envs[@]+"${envs[@]}"}; do case "$e" in DISP=*) _disp="${e#DISP=}" ;; *) export "$e" ;; esac; done
    _session_should "$verb" "$_disp"; echo $? ) 2>/dev/null | tail -1
}

[ "$(_should edit)" = 0 ]     && ok "edit -> session by default" || bad "edit did not promote to session"
[ "$(_should yolo)" = 0 ]     && ok "yolo -> session by default" || bad "yolo did not promote to session"
# RESEARCH NEVER PROMOTES TO A SESSION on ANY lane: the OS sandbox that DEFINES research is applied only
# in the fg/bg dispatch block, and `_session_run` carries no verb -> a promoted research session would
# silently run with the interactive default posture and DROP the sandbox (cursor/gemini unsandboxed;
# codex loses network/MCP isolation; devin bypasses --sandbox / OSRC_DEVIN_RESEARCH_WRITE). Verify every
# representative lane stays on the dispatch path (return 1), including when OSRC_FORCE_SESSION is set.
for _lane in devin cxnative ccnative gmnative droid cursor hermes cline warp; do
  [ "$(_should research DISP=$_lane)" = 1 ] && ok "research ($_lane) stays on the sandbox-aware dispatch path" || bad "research ($_lane) wrongly promoted to a session — drops its sandbox"
done
[ "$(_should research DISP=cursor OSRC_FORCE_SESSION=1)" = 1 ] && ok "OSRC_FORCE_SESSION cannot promote research to a session (sandbox stays)" || bad "OSRC_FORCE_SESSION promoted research — sandbox lost"
[ "$(_should run)" = 1 ]      && ok "run (read-only) stays bg by default" || bad "run wrongly promoted to session"
[ "$(_should explore)" = 1 ]  && ok "explore (read-only) stays bg by default" || bad "explore wrongly promoted"
[ "$(_should run OSRC_FORCE_SESSION=1)" = 0 ] && ok "run + OSRC_FORCE_SESSION -> session (explicit opt-in to a broader posture)" || bad "OSRC_FORCE_SESSION did not force run into a session"
# OSRC_MAX_MINUTES is a DURATION, not an authority grant. A read-only run/explore must NOT silently
# gain a writable/MCP-broad session just because it is long — that was a least-privilege break. Only the
# explicit OSRC_FORCE_SESSION promotes read-only verbs.
[ "$(_should run OSRC_MAX_MINUTES=10)" = 1 ] && ok "run + OSRC_MAX_MINUTES stays bg (duration must not widen a read-only verb's posture)" || bad "OSRC_MAX_MINUTES wrongly promoted read-only run to a broader session"
[ "$(_should explore OSRC_MAX_MINUTES=10)" = 1 ] && ok "explore + OSRC_MAX_MINUTES stays bg (same least-privilege rule)" || bad "OSRC_MAX_MINUTES wrongly promoted explore"

# Loop foreground-completion contract: OSRC_NO_AUTODETACH=1 must stay headless (loops grade synchronously).
[ "$(_should edit OSRC_NO_AUTODETACH=1)" = 1 ] && ok "OSRC_NO_AUTODETACH=1 (loop contract) stays headless" || bad "OSRC_NO_AUTODETACH did not force headless — loops would grade stale files"

# Lane faithfulness: only lanes with a real session transport promote; OpenRouter/claudex fall to bg.
[ "$(_should edit DISP=ccor)" = 1 ]     && ok "ccor (OpenRouter) has no session transport -> bg" || bad "ccor wrongly promoted (would misroute to claude-native)"
[ "$(_should edit DISP=codexor)" = 1 ]  && ok "codexor (OpenRouter) -> bg" || bad "codexor wrongly promoted"
[ "$(_should edit DISP=claudex)" = 1 ]  && ok "claudex has no session transport -> bg" || bad "claudex wrongly promoted"
[ "$(_should edit DISP=droid)" = 0 ]    && ok "droid -> session" || bad "droid did not promote"

# INTERACTIVE-DEFAULT (owner decision): edit + yolo promote to a steerable session on EVERY promotable
# lane, INCLUDING the managed native lanes (claude/codex/gemini). A promoted session inherits the user's
# real MCP + settings by design — for a WATCHED session that is desired, not a leak (the headless path
# keeps its MCP isolation; the session does not). Robustness is enforced in _session_run (it returns the
# fallback sentinel so route_delegate runs the work headless if a session cannot start), NOT by refusing
# to promote. Verify all 8 promotable lanes promote both mutating verbs.
for _plane in devin cxnative ccnative gmnative droid cursor hermes cline; do
  [ "$(_should edit DISP=$_plane)" = 0 ] && ok "$_plane EDIT -> steerable session" || bad "$_plane edit did not promote"
  [ "$(_should yolo DISP=$_plane)" = 0 ] && ok "$_plane YOLO -> steerable session" || bad "$_plane yolo did not promote"
done
# WARP has no interactive session adapter (session start dies for it), so it must NOT be promotable for
# ANY verb — promoting would kill the run at launch instead of steering it.
[ "$(_should edit DISP=warp)" = 1 ] && ok "warp edit stays bg (no session adapter -> would die at launch)" || bad "warp edit wrongly promoted — session start has no warp adapter, run would die"
[ "$(_should yolo DISP=warp)" = 1 ] && ok "warp yolo stays bg (no session adapter)" || bad "warp yolo wrongly promoted"

# Exclusions: the genuinely-headless callers + opt-out must stay bg even for a mutating verb.
[ "$(_should edit OSRC_NO_SESSION=1)" = 1 ]  && ok "OSRC_NO_SESSION=1 forces headless bg" || bad "OSRC_NO_SESSION not honored"
[ "$(_should edit OSRC_STREAM=1)" = 1 ]      && ok "inside a bg job (OSRC_STREAM) stays bg" || bad "OSRC_STREAM not excluded"
[ "$(_should edit OSRC_JOB_DIR=/tmp/x)" = 1 ]&& ok "inside a bg job (OSRC_JOB_DIR) stays bg" || bad "OSRC_JOB_DIR not excluded"
[ "$(_should edit OSRC_FANOUT_CHILD=1)" = 1 ]&& ok "a fanout member stays a headless one-shot" || bad "OSRC_FANOUT_CHILD not excluded"
[ "$(_should edit OSRC_PREFLIGHT=1)" = 1 ]   && ok "preflight probe does not mint a session" || bad "OSRC_PREFLIGHT not excluded"
[ "$(_should edit CI=true)" = 1 ]            && ok "CI=true cannot drive a TUI -> bg" || bad "CI not excluded"
[ "$(_should edit GITHUB_ACTIONS=1)" = 1 ]   && ok "GITHUB_ACTIONS -> bg" || bad "GITHUB_ACTIONS not excluded"

# Backend gating: with NO tmux on PATH, even a mutating verb must fall back to bg.
notmux="$( ( PATH="/usr/bin:/bin"; SCRIPT_DIR="$HERE/.."; . "$SRC" >/dev/null 2>&1
  unset OSRC_NO_SESSION OSRC_STREAM OSRC_JOB_DIR OSRC_FANOUT_CHILD OSRC_PREFLIGHT CI GITHUB_ACTIONS 2>/dev/null || true
  command -v tmux >/dev/null 2>&1 && { echo SKIP; exit; }
  _session_should edit devin; echo $? ) 2>/dev/null | tail -1 )"
case "$notmux" in
  SKIP) echo "SKIP: tmux present in /usr/bin:/bin, cannot test no-backend fallback here" ;;
  1) ok "no session backend available -> falls back to bg" ;;
  *) bad "no-backend case did not fall back to bg (got '$notmux')" ;;
esac

# Ordering: the session-promotion branch must appear BEFORE the auto-detach branch in route_delegate.
sp_line=$(grep -n '_session_should "\$verb" "\$disp"' "$SRC" | head -1 | cut -d: -f1)
ad_line=$(grep -n '_autodetach_should "\$disp" "\$RESOLVED_ID"' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$sp_line" ] && [ -n "$ad_line" ] && [ "$sp_line" -lt "$ad_line" ]; then
  ok "session-promotion branch runs before auto-detach in route_delegate ($sp_line < $ad_line)"
else
  bad "session-promotion branch is NOT before auto-detach (session=$sp_line autodetach=$ad_line)"
fi

# NEVER-A-DEAD-END: a promoted session that cannot start/deliver must FALL BACK to headless, not die.
grep -q 'OSRC_SESSION_FALLBACK_RC=97' "$SRC" \
  && ok "the session fallback sentinel is defined" || bad "no OSRC_SESSION_FALLBACK_RC sentinel"
# _session_run must RETURN the sentinel (not die) on a start/deliver failure.
if awk '/^_session_run\(\)/,/^}/' "$SRC" | grep -q 'return "\$OSRC_SESSION_FALLBACK_RC"'; then
  ok "_session_run returns the fallback sentinel instead of dying on session failure"
else bad "_session_run still dies on session failure — a lane whose TUI rejects a flag would kill the delegation"; fi
# _session_run must no longer `die` on start/deliver failure (only the empty-task guard may die).
if awk '/^_session_run\(\)/,/^}/' "$SRC" | grep -qE "die .*(session start|task delivery|no session transport)"; then
  bad "_session_run still has a die on a session start/deliver/transport failure (should fall back)"
else ok "_session_run has no die on start/deliver/transport failure (all fall back to headless)"; fi
# route_delegate must CATCH the sentinel and fall through (restore depth), not return it to the caller.
grep -q 'if \[ "\$_sr_rc" != "\${OSRC_SESSION_FALLBACK_RC:-97}" \]; then return "\$_sr_rc"; fi' "$SRC" \
  && ok "route_delegate catches the fallback sentinel and falls through to the headless path" \
  || bad "route_delegate does not catch the fallback sentinel — a failed session would surface rc=97 to the caller"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
