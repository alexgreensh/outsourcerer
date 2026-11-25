#!/usr/bin/env bash
# test_launch_sites.sh — forcing function for launch paths (torture-room arch F1). Every place that
# starts a model process — `tmux new-session` / `tmux respawn-pane`, a `delegate` / `delegate_*`
# call, the descriptor dispatch "$_df", `_cloudrun_launch`, and the session wrappers
# (_session_create_pane, _session_launch_adapter, _session_control_relaunch) and the Windows
# session broker — must sit in a
# function on the allowlist below, and each entry names the spend gate that covers it and the
# function holding that gate. A new launch site (a `session fork`, a watchdog restart, ...) fails
# here until someone adds it with its gate. Static: reads the source, runs nothing.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# file|function|primitive|gate@holder  (gate "none" needs a reason in the 5th field)
ALLOW='
lib/cloudrun.sh|_cloudrun_start|_cloudrun_launch|_osrc_spend_gate@_cloudrun_start
lib/cloudrun.sh|_cloudrun_launch|tmux-new-session|_osrc_spend_gate@_cloudrun_start
lib/leanlaunch.sh|_session_create_pane|tmux-new-session|_osrc_session_spend_gate@session
lib/plan-probe.sh|_osrc_probe_agy_screen|tmux-new-session|none|plan-meter read: opens agy, types /usage, sends no prompt
lib/spend-paths.sh|_osrc_session_relaunch_gated|_session_control_relaunch|_osrc_spend_gate@_osrc_session_relaunch_gated
outsourcerer.sh|_autodetach_run|tmux-new-session|_osrc_spend_gate@route_delegate
outsourcerer.sh|_session_control_relaunch|tmux-respawn-pane|_osrc_spend_gate@_osrc_session_relaunch_gated
outsourcerer.sh|_winpty_session|_session_launch_adapter|_osrc_session_spend_gate@_winpty_session
outsourcerer.sh|_winpty_session|winpty-broker|_osrc_session_spend_gate@_winpty_session
outsourcerer.sh|session|_session_create_pane|_osrc_session_spend_gate@session
outsourcerer.sh|session|_session_launch_adapter|_osrc_session_spend_gate@session
outsourcerer.sh|delegate_cc|delegate|_osrc_dv_launch_id@delegate
outsourcerer.sh|delegate_codex|delegate_cc|_osrc_or_member_gate@delegate_cc
outsourcerer.sh|route_delegate|"$_df"|_osrc_spend_gate@route_delegate
outsourcerer.sh|route_delegate|delegate|_osrc_spend_gate@route_delegate
outsourcerer.sh|route_delegate|delegate_local|_osrc_spend_gate@route_delegate
'

# scan <files...> -> "file|function|primitive" for every launch site (comments ignored)
scan() {
  awk '
  FNR == 1 { fn = ""; f = FILENAME; sub(/^.*\/scripts\//, "", f) }
  /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { fn = $1; sub(/\(\).*/, "", fn); next }
  {
    l = $0; if (l ~ /^[ \t]*#/) next
    if ((l ~ /tmux/ && l ~ /(new-session|respawn-pane)/) || l ~ /=\((new-session|respawn-pane)/)
      print f "|" fn "|" ((l ~ /respawn-pane/) ? "tmux-respawn-pane" : "tmux-new-session")
    if (l ~ /nohup "\$broker"/) print f "|" fn "|winpty-broker"
    s = l
    while (match(s, /(^|[;&|({!]|then |else |do |\$\()[ \t]*([A-Za-z_]+=[^ "'"'"']* )*(delegate_[a-z]+|delegate|"\$_df"|_cloudrun_launch|_session_create_pane|_session_launch_adapter|_session_control_relaunch)([ ;)]|$)/)) {
      m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      sub(/[ ;)]$/, "", m); sub(/^.*[ \t(;&|!]/, "", m); sub(/^.*=/, "", m)
      print f "|" fn "|" m
    }
  }' "$@" | sort -u
}
# body <function> -> the function as bash parsed it (comments dropped), from the sourced engine
BODIES="$(mktemp)"; export HOME="$(mktemp -d)"
OSRC_HOME="$HOME/osrc" OSRC_SOURCED=1 bash -c '. "$1" >/dev/null 2>&1; declare -f' _ "$ROOT/outsourcerer.sh" > "$BODIES" 2>/dev/null
body() { awk -v n="$1" '$0 == n" () " {p=1} p {print} p && /^}$/ {exit}' "$BODIES"; }

cd "$ROOT" || exit 1
found="$(scan outsourcerer.sh lib/*.sh factory*.sh)"
[ -n "$found" ] && ok "scanner found $(printf '%s\n' "$found" | wc -l | tr -d ' ') launch sites" || bad "scanner found nothing"
while IFS= read -r site; do
  [ -n "$site" ] || continue
  entry="$(printf '%s\n' "$ALLOW" | grep -F -- "$site|" | head -n 1)"
  [ -n "$entry" ] || { bad "unlisted launch site $site — add it to ALLOW with the gate that covers it"; continue; }
  g="$(printf '%s' "$entry" | cut -d'|' -f4)"
  if [ "$g" = none ]; then
    [ -n "$(printf '%s' "$entry" | cut -d'|' -f5)" ] && ok "$site: no model request ($(printf '%s' "$entry" | cut -d'|' -f5))" || bad "$site: gate none without a reason"
    continue
  fi
  holder="${g#*@}"; gate="${g%@*}"
  hb="$(body "$holder")"   # into a var: grep -q on a pipe SIGPIPEs the producer under pipefail
  if grep -qE "(^|[^A-Za-z0-9_])$gate([^A-Za-z0-9_]|$)" <<<"$hb"; then ok "$site covered by $gate in $holder"
  else bad "$site: $holder does not call $gate"; fi
done <<EOF
$found
EOF
# stale allowlist rows hide a removed gate path: every row must still match a real site
while IFS='|' read -r f fn p _rest; do
  [ -n "$f" ] || continue
  printf '%s\n' "$found" | grep -qxF -- "$f|$fn|$p" || bad "stale ALLOW row $f|$fn|$p (no such launch site)"
done <<EOF
$ALLOW
EOF
# order: in the holder that launches, the gate runs BEFORE the launch
for pair in 'route_delegate|_osrc_spend_gate "${_cap_lane|"$_df"' 'session|_osrc_session_spend_gate|_session_create_pane' \
            '_winpty_session|_osrc_session_spend_gate|nohup "$broker"' '_cloudrun_start|_osrc_spend_gate|_cloudrun_launch "' \
            '_osrc_session_relaunch_gated|_osrc_spend_gate|_session_control_relaunch'; do
  fn="${pair%%|*}"; r="${pair#*|}"; g="${r%%|*}"; l="${r#*|}"; l="${l%|}"
  b="$(body "$fn")"
  gl="$(printf '%s\n' "$b" | grep -nF -- "$g" | head -n 1 | cut -d: -f1)"
  ll="$(printf '%s\n' "$b" | grep -nF -- "$l" | head -n 1 | cut -d: -f1)"
  [ -z "$ll" ] && continue
  [ -n "$gl" ] && [ "$gl" -lt "$ll" ] && ok "$fn: gate before launch" || bad "$fn: launch ($l, line $ll) before gate ($g, line ${gl:-none})"
done
# self-test: a new, unlisted launch site is caught
T="$(mktemp -d)"; trap 'rm -rf "$T" "$BODIES" "$HOME"' EXIT; mkdir -p "$T/scripts/lib"
printf '_session_fork() {\n  tmux new-session -d -s fork "$launch"\n}\n_restart_lane() {\n  delegate_cc auto "$@"\n}\n' > "$T/scripts/lib/new.sh"
got="$(scan "$T/scripts/lib/new.sh" | tr '\n' ' ')"
[ "$got" = "lib/new.sh|_restart_lane|delegate_cc lib/new.sh|_session_fork|tmux-new-session " ] \
  && ok "self-test: a new fork/restart launch site is detected" || bad "self-test: scanner missed new sites: '$got'"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
