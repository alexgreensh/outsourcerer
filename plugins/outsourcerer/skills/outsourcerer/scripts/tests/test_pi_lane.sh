#!/usr/bin/env bash
# test_pi_lane.sh — the Pi engine lane (https://github.com/earendil-works/pi) must be registered,
# reachable by --provider pi, and send flags Pi actually accepts: print mode, no saved session,
# --model passthrough, --thinking for effort, and a read-only tool list for run/explore.
# A fake `pi` on PATH records its argv, so nothing real runs and no plan is spent.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-pi.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home"; mkdir -p "$OSRC_HOME" "$TMP/bin" "$TMP/work"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }

cat > "$TMP/bin/pi" <<EOF
#!/usr/bin/env bash
case "\$1" in --version|-v) echo "1.4.0"; exit 0 ;; --help|-h) echo "Usage: pi [options] --print --model --thinking --tools"; exit 0 ;; esac
printf '%s\n' "\$@" > "$TMP/argv"
echo "PI_OK"
EOF
chmod +x "$TMP/bin/pi"

run() { ( cd "$TMP/work" && PATH="$TMP/bin:$PATH" OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider pi "$@" 2>"$TMP/err" ); }
argv() { tr '\n' ' ' < "$TMP/argv" 2>/dev/null; }

echo "=== registration ==="
( export OSRC_SOURCED=1; source "$SRC" >/dev/null 2>&1
  case " $OSRC_LANE_REGISTRY " in *" pi "*) exit 0 ;; *) exit 1 ;; esac ) && ok "pi is in the lane registry" || no "pi missing from the registry"
( export OSRC_SOURCED=1; source "$SRC" >/dev/null 2>&1; [ "$(_lane_field pi dispatch)" = "delegate_pi" ] ) \
  && ok "the descriptor dispatches to delegate_pi" || no "descriptor dispatch wrong"
( export OSRC_SOURCED=1; source "$SRC" >/dev/null 2>&1
  [ "$(_pi_effort high)" = "high" ] && [ "$(_pi_effort max)" = "max" ] && [ "$(_pi_effort minimal)" = "minimal" ] && [ -z "$(_pi_effort junk)" ] ) \
  && ok "effort maps onto Pi's --thinking levels" || no "effort mapping wrong"
grep -q 'warp|cline|pi|' "$SRC" && ok "pi is listed in the provider help" || no "provider help lacks pi"

echo "=== run (read-only) ==="
out="$(run run "say ok")"; rc=$?
[ "$rc" -eq 0 ] && case "$out" in *PI_OK*) true ;; *) false ;; esac && ok "a run returns Pi's answer" || no "run rc=$rc out=[$out] err=$(tail -3 "$TMP/err")"
a="$(argv)"
case "$a" in "-p --no-session "*) ok "print mode with no saved session" ;; *) no "argv start: [$a]" ;; esac
case "$a" in *"--tools read,grep,find,ls"*) ok "run is read-only by tool list" ;; *) no "run lacks the read-only tool list: [$a]" ;; esac
case "$a" in *" -- "*) ok "the prompt follows --" ;; *) no "prompt not after --: [$a]" ;; esac

echo "=== edit with model and effort ==="
run edit -m anthropic/claude-sonnet-4-5 --effort high "fix it" >/dev/null; a="$(argv)"
case "$a" in *"--model anthropic/claude-sonnet-4-5"*) ok "-m passes through to --model" ;; *) no "model not passed: [$a]" ;; esac
case "$a" in *"--thinking high"*) ok "--effort maps to --thinking" ;; *) no "effort not passed: [$a]" ;; esac
case "$a" in *"--tools "*) no "edit should use Pi's default tools: [$a]" ;; *) ok "edit keeps Pi's default tools" ;; esac
grep -q "MUTATING" "$TMP/err" && ok "the banner says edit mutates" || no "banner lacks MUTATING"

echo "=== missing CLI ==="
out="$( cd "$TMP/work" && PATH="/usr/bin:/bin" OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" --provider pi run "x" 2>&1 )"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "pi CLI not on PATH" && ok "a missing pi fails loudly with the install hint" || no "missing-CLI path rc=$rc"
printf '%s' "$out" | grep -qE 'curl[^|]*\|[[:space:]]*(ba)?sh' && no "hint pipes a download to a shell" || ok "the install hint never pipes a download to a shell"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
