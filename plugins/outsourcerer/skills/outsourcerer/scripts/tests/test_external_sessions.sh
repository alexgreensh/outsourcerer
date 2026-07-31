#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "$PWD/.test-external.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; ok(){ echo "PASS: $1"; pass=$((pass+1)); }; bad(){ echo "FAIL: $1"; fail=$((fail+1)); }
OSRC_HOME="$TMP/state" HOME="$TMP/home"; export OSRC_HOME HOME; mkdir -p "$HOME/.claude/sessions" "$HOME/.codex/sessions"
printf '%s\n' '{"event":"start","session_id":"owned","provider":"cc"}' > "$OSRC_HOME-registry"
mkdir -p "$OSRC_HOME/sessions"; mv "$OSRC_HOME-registry" "$OSRC_HOME/sessions/registry.jsonl"
printf '%s\n' '{}' > "$HOME/.claude/sessions/a.jsonl"; printf '%s\n' '{}' > "$HOME/.codex/sessions/b.jsonl"
set --; . "$SRC" >/dev/null 2>&1
_pid_start_identity(){ printf 'Mon Jan 1 00:00:00 2024\n'; }
tmux(){ case "$1" in list-panes) printf 'other:0.0\t42\tclaude\n';; *) return 1;; esac; }
snapshot="$(_fleet_snapshot_collect)"
printf '%s' "$snapshot" | jq -e '.items[] | select(.session_id=="owned" and .owner=="managed" and .state=="unknown")' >/dev/null && ok "managed registry is observed without a live-state claim" || bad "managed registry observation missing"
printf '%s' "$snapshot" | jq -e '[.items[] | select(.owner=="external" and .state=="unknown")] | length >= 3' >/dev/null && ok "external sources are unknown observations" || bad "external observations were missing or promoted"
cmd_rundown >/dev/null && ok "rundown renders discovery without terminal input" || bad "rundown failed"
echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
