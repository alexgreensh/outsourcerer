#!/usr/bin/env bash
# test_relaunch_bookkeeping.sh — a relaunch never tears down the live pane over a bookkeeping
# failure, and non-start registry events carry the session's real model generation.
#
# Root causes guarded:
#   (a) _session_launch_finalize killed the tmux session on EVERY failure branch. Right for a fresh
#       launch that never came up; wrong for `session control relaunch` / `session effort` when only
#       the heartbeat failed to arm: the pane holds a live engine, the registry already names it, and
#       the user's work was destroyed over a supervision hiccup. (A registry write failure still
#       tears down: a stale record over a live pane is the reap-over-live hazard 0.10.1 closed.)
#   (b) `session effort` appended its record with no generation, so _session_registry_append
#       defaulted to 1 and stamped model_generation:1 over a generation-3 session. The model-pin
#       path keys its lock and restore obligation on that generation.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

TMP="$(mktemp -d "$PWD/.test-relaunch-bookkeeping.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"
export HOME="$TMP/home"
mkdir -p "$OSRC_HOME" "$HOME"
TMUX_LOG="$TMP/tmux.log"

pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
bad(){ echo "FAIL: $1"; fail=$((fail+1)); }

set --
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
type -t _session_launch_finalize >/dev/null || { echo "FAIL: _session_launch_finalize not loaded"; exit 1; }
type -t _session_current_generation >/dev/null || { echo "FAIL: _session_current_generation not loaded"; exit 1; }

# ---------------------------------------------------------------------------
# (b) first, with the real registry functions.
_pid_start_identity() { printf 'Mon Jan 1 00:00:00 2024\n'; }
SESSION_NAME=gen-test
  [ "$(_session_current_generation gen-test)" = 1 ] && ok "no start record: generation defaults to 1" || bad "default generation is [$(_session_current_generation gen-test)]"
  _session_registry_append start cc opus high started launch "" 3 || bad "could not seed a generation-3 start record"
  [ "$(_session_current_generation gen-test)" = 3 ] && ok "_session_current_generation reads the start record's generation" \
    || bad "generation read back as [$(_session_current_generation gen-test)], expected 3"
  _session_registry_append effort cc opus low advisory advisory "" "$(_session_current_generation gen-test)" || bad "effort append failed"
  last_gen="$(tail -1 "$OSRC_SESSION_REGISTRY" | jq -r '.model_generation')"
  [ "$last_gen" = 3 ] && ok "an effort record carries the session's real generation (3), not the default 1" \
    || bad "effort record stamped model_generation=$last_gen over a generation-3 session"

# ---------------------------------------------------------------------------
# (a) finalize teardown contract. tmux is shadowed by a function that records every call.
tmux() { printf '%s\n' "$*" >> "$TMUX_LOG"; return 0; }
_session_launch_liveness_check() { return 0; }
_heartbeat_arm_verify() { return 0; }
_managed_endpoint_live() { return 0; }
_session_registry_end() { return 0; }

killed() { grep -c '^kill-session' "$TMUX_LOG" 2>/dev/null || true; }

# registry write fails: torn down even on a relaunch. A live pane whose registry record still names
# the old process is the "crash-reap over a healthy replacement" hazard 0.10.1 closed
# (test_lifecycle_fix pins it), so consistency wins over keeping the pane here.
_session_registry_append() { return 1; }
  : > "$TMUX_LOG"
  _session_launch_finalize s1 cc m "" launch 2 1 >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && ok "relaunch: registry failure is still reported (rc=$rc)" || bad "relaunch: registry failure returned success"
  [ "$(killed)" -ge 1 ] && ok "relaunch: registry failure still tears down (a stale registry over a live pane is the reap-over-live hazard)" || bad "relaunch: registry failure left a live pane with a stale registry record"
  : > "$TMUX_LOG"
  _session_launch_finalize s1 cc m "" launch 2 >/dev/null 2>&1
  [ "$(killed)" -ge 1 ] && ok "fresh launch: registry failure still tears down" || bad "fresh launch: registry failure left the session up"

# heartbeat arm fails
_session_registry_append() { return 0; }
_heartbeat_arm_verify() { return 1; }
  : > "$TMUX_LOG"
  _session_launch_finalize s1 cc m "" launch 2 1 >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && ok "relaunch: heartbeat failure is still reported (rc=$rc)" || bad "relaunch: heartbeat failure returned success"
  [ "$(killed)" = 0 ] && ok "relaunch: heartbeat failure does NOT kill the live pane" || bad "relaunch: heartbeat failure killed the live pane"
  msg="$(_session_launch_finalize s1 cc m "" launch 2 1 2>&1 >/dev/null)"
  case "$msg" in *UNSUPERVISED*) ok "relaunch: the message says the pane is unsupervised" ;; *) bad "relaunch: message does not say unsupervised: $msg" ;; esac
  : > "$TMUX_LOG"
  _session_launch_finalize s1 cc m "" launch 2 >/dev/null 2>&1
  [ "$(killed)" -ge 1 ] && ok "fresh launch: heartbeat failure still tears down" || bad "fresh launch: heartbeat failure left the session up"

# the pane itself is wrong: torn down even for a relaunch
_heartbeat_arm_verify() { return 0; }
_session_registry_append() { return 0; }
_session_launch_liveness_check() { return 1; }
  : > "$TMUX_LOG"
  _session_launch_finalize s1 cc m "" launch 2 1 >/dev/null 2>&1
  [ "$(killed)" -ge 1 ] && ok "relaunch: a liveness failure (the pane is a bare shell) still tears down" || bad "relaunch: liveness failure left a dead pane registered"
  _session_launch_liveness_check() { return 0; }
  _managed_endpoint_live() { return 1; }
  : > "$TMUX_LOG"
  _session_launch_finalize s1 cc m "" launch 2 1 >/dev/null 2>&1
  [ "$(killed)" -ge 1 ] && ok "relaunch: an endpoint identity mismatch still tears down" || bad "relaunch: endpoint mismatch left the pane up"

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
