#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
set -uo pipefail
D="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR%/}/p56r2.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/user" "$T/bin" "$T/work"
export OSRC_HOME="$T/home" HOME="$T/user" OSRC_SOURCED=1 OSRC_HEARTBEAT_DISABLED=1 PATH="$T/bin:$PATH"
cat > "$T/bin/opencode" <<EOF_STUB
#!/bin/sh
[ "\${1:-}" = --standalone ] && shift
case "\${1:-}" in
  --version) echo 2.2.6 ;;
  auth) echo "OpenCode Go api" ;;
  run) : > "$T/dispatched"; echo OK ;;
  *) echo OK ;;
esac
EOF_STUB
chmod +x "$T/bin/opencode"
export _OPENCODE_VER=1
. "$D/outsourcerer.sh" >/dev/null 2>&1
pass=0; fail=0
check() { if "$@"; then echo "PASS: $*"; pass=$((pass+1)); else echo "FAIL: $*"; fail=$((fail+1)); fi; }
check test "$(_opencode_ver)" = 2
check test "$(lane_from_name opencode-go/glm-5.3-flash)" = opencode
check _opencode_route_check
check test "$(_lane_field opencode cost_class)" = credits
check test -z "$(_lane_field opencode plan_limited)"
check test -z "$(_resolve_run_cost opencode 0 /dev/null)"
for mode in readonly scoped; do
  cfg="$(_opencode_config_json "$mode" "$T/work")"
  check jq -e --arg p "external_directory:$T/work/**" '[.policies[].resource]|index($p)!=null' <<< "$cfg"
done
for mode in scoped allowall; do
  cfg="$(_opencode_config_json "$mode")"
  check jq -e '[.policies[]|select(.resource=="task:*" and .effect=="deny")]|length>0' <<< "$cfg"
done
# Simulate tty detection only; stdin carries two answers in one shell.
_tty_two() (
  [() { if test "${1:-}" = -t; then return 0; fi; builtin [ "$@"; }
  unset OSRC_SPEND_OK _OSRC_SPEND_BOUND_LANE _OSRC_SPEND_BOUND_MODEL
  _osrc_spend_gate opencode opencode-go/model opencode first || exit
  _failover_rebuild_argv or provider/model 0 opencode opencode-go/model || exit
  _osrc_spend_gate or provider/model or second || exit
)
printf 'y\ny\n' | _tty_two >"$T/two" 2>&1; rc=$?
check test "$rc" = 0
check test "$(grep -c 'PAID LANE:' "$T/two")" = 2
_script_hop() (
  OSRC_SPEND_OK=1; unset _OSRC_SPEND_BOUND_LANE _OSRC_SPEND_BOUND_MODEL
  _osrc_spend_gate opencode opencode-go/model opencode first || exit
  _failover_rebuild_argv or provider/model 0 opencode opencode-go/model || exit
  _osrc_spend_gate or provider/model or second
)
_script_hop >"$T/scripted" 2>&1; rc=$?
check test "$rc" != 0
check grep -q 'spend gate:.*OpenRouter' "$T/scripted"
_same_lane_switch() (
  OSRC_SPEND_OK=1; unset _OSRC_SPEND_BOUND_LANE _OSRC_SPEND_BOUND_MODEL
  _osrc_spend_gate opencode opencode-go/model opencode first || exit
  _osrc_spend_gate opencode opencode-go/other opencode second
)
_same_lane_switch >"$T/same-lane" 2>&1; rc=$?
check test "$rc" != 0
check grep -q 'spend gate:.*opencode-go/other' "$T/same-lane"
_free_hop() (
  OSRC_SPEND_OK=1; unset _OSRC_SPEND_BOUND_LANE _OSRC_SPEND_BOUND_MODEL
  _osrc_spend_gate opencode opencode-go/model opencode first || exit
  _osrc_spend_gate local model local second
)
check _free_hop
# A supervised child must not let a forwarded flag override its pair-bound marker.
_marker_mismatch() (
  mkdir -p "$OSRC_JOBS/p56"
  OSRC_JOB_DIR="$OSRC_JOBS/p56"; OSRC_JOB_TOKEN=fixture; OSRC_SPEND_OK=1
  unset _OSRC_SPEND_BOUND_LANE _OSRC_SPEND_BOUND_MODEL
  printf '#osrc-spend-ok token=fixture\nopencode|opencode-go/model\n' > "$OSRC_JOB_DIR/.spend-ok"
  _osrc_spend_ok or provider/model
)
if _marker_mismatch; then echo "FAIL: forwarded flag bypassed bound job marker"; fail=$((fail+1)); else echo "PASS: forwarded flag cannot bypass bound job marker"; pass=$((pass+1)); fi
# Consent after the verb must survive preflight as the exact model marker.
bgout="$(cd "$T/work" && OSRC_SOURCED=0 OSRC_CLOUD_ACK=1 OSRC_NO_ADVISE=1 "$D/outsourcerer.sh" --provider opencode bg run --spend-ok -m opencode-go/model x 2>&1)"; bg_rc=$?
bgid="$(printf '%s\n' "$bgout" | awk 'NF==1 && $1 ~ /^[0-9]{8}-[0-9]{6}-/ {print $1; exit}')"
check test "$bg_rc" = 0
check test -n "$bgid"
if [ -n "$bgid" ]; then
  for _i in $(seq 1 30); do [ -e "$T/dispatched" ] && break; sleep 1; done
  if [ -e "$T/dispatched" ] && [ -s "$OSRC_HOME/jobs/$bgid/out.log" ] && ! grep -q 'spend gate' "$OSRC_HOME/jobs/$bgid/out.log"; then echo 'PASS: background consent accepted'; pass=$((pass+1)); else echo 'FAIL: background consent missing or refused'; fail=$((fail+1)); fi
fi
check test "$(grep -c -- '--provider requires a name .*opencode' "$D/outsourcerer.sh")" = 8
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
