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
[ "$(_should research)" = 0 ] && ok "research -> session by default" || bad "research did not promote to session"
[ "$(_should run)" = 1 ]      && ok "run (read-only) stays bg by default" || bad "run wrongly promoted to session"
[ "$(_should explore)" = 1 ]  && ok "explore (read-only) stays bg by default" || bad "explore wrongly promoted"
[ "$(_should run OSRC_FORCE_SESSION=1)" = 0 ] && ok "run + OSRC_FORCE_SESSION -> session" || bad "OSRC_FORCE_SESSION did not force run into a session"
[ "$(_should run OSRC_MAX_MINUTES=10)" = 0 ] && ok "run + OSRC_MAX_MINUTES -> session (long work)" || bad "OSRC_MAX_MINUTES did not promote run"

# Loop foreground-completion contract: OSRC_NO_AUTODETACH=1 must stay headless (loops grade synchronously).
[ "$(_should edit OSRC_NO_AUTODETACH=1)" = 1 ] && ok "OSRC_NO_AUTODETACH=1 (loop contract) stays headless" || bad "OSRC_NO_AUTODETACH did not force headless — loops would grade stale files"

# Lane faithfulness: only lanes with a real session transport promote; OpenRouter/claudex fall to bg.
[ "$(_should edit DISP=ccnative)" = 0 ] && ok "ccnative (claude native) -> session" || bad "ccnative did not promote"
[ "$(_should edit DISP=cxnative)" = 0 ] && ok "cxnative (codex native) -> session" || bad "cxnative did not promote"
[ "$(_should edit DISP=ccor)" = 1 ]     && ok "ccor (OpenRouter) has no session transport -> bg" || bad "ccor wrongly promoted (would misroute to claude-native)"
[ "$(_should edit DISP=codexor)" = 1 ]  && ok "codexor (OpenRouter) -> bg" || bad "codexor wrongly promoted"
[ "$(_should edit DISP=claudex)" = 1 ]  && ok "claudex has no session transport -> bg" || bad "claudex wrongly promoted"
[ "$(_should edit DISP=droid)" = 0 ]    && ok "droid -> session" || bad "droid did not promote"

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

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
