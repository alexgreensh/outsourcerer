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
# Bound consent must skip an uncovered paid candidate, including in both pickers.
_picker_cases() (
  OSRC_SPEND_OK=1; _OSRC_SPEND_BOUND_LANE=cx; _OSRC_SPEND_BOUND_MODEL=original
  osrc_lane_billing() { case "$1" in opencode) echo metered ;; *) echo subscription ;; esac; }
  _fallback_lane_ready() { return 0; }; _lane_down_active() { return 1; }
  _lane_field() { case "$2" in fallback_ready_fn) echo ready ;; esac; }
  _model_excluded() { return 1; }; _model_denied() { return 1; }
  _failover_lane_is_cash() { return 1; }
  got="$(_fallback_pick '' $'paid|other|opencode\nfree|model|gm')"
  [ "$got" = 'free|model|gm' ] || exit 1
  _failover_lane_ok opencode run other && exit 1
  _failover_lane_ok gm run model || exit 1
  _failover_same_model_on() { case "$1" in opencode) echo other ;; gm) echo model ;; esac; }
  OSRC_FAILOVER_LANES='opencode gm'
  [ "$(_failover_pick cx model run)" = 'gm|model|same-model' ] || exit 1
  OSRC_FAILOVER_LANES=opencode; OSRC_MODEL_TABLE=''
  [ -z "$(_failover_pick cx model run)" ] || exit 1
  case " $(_failover_spend_skipped) " in *' opencode '*) ;; *) exit 1 ;; esac
  _failover_nothing_notice cx limit 2>"$T/picker-refusal"
  grep -q 'opencode.*metered or unproven' "$T/picker-refusal" || exit 1
  [ -z "$(_fallback_pick '' 'paid|other|opencode')" ]
)
check _picker_cases
# Exercise the fanout launcher and its real marker writer with a stub child gate.
_fanout_consent() (
  _heartbeat_arm_verify() { :; }; _bg_cloud_preack() { :; }; _fanout_running() { echo 0; }
  _bg_launch() {
    local jd="$OSRC_JOBS/fanout-child"; mkdir -p "$jd"; OSRC_JOB_TOKEN=fixture
    _osrc_spend_marker_write "$jd" "$PROVIDER" "$@"
    OSRC_JOB_DIR="$jd"; export OSRC_JOB_DIR OSRC_JOB_TOKEN
    ( _osrc_spend_gate opencode opencode-go/other opencode child && : > "$T/wrong-child-ran" ) >"$T/fanout-mismatch" 2>&1 && return 1
    grep -q 'spend gate:' "$T/fanout-mismatch" || return 1
    ( _osrc_spend_gate opencode opencode-go/model opencode child && : > "$T/matching-child-ran" ) >"$T/fanout-match" 2>&1 || return 1
    echo child
  }
  cmd_fanout --provider opencode --spend-ok -m opencode-go/model -- 'task' >/dev/null 2>&1
)
check _fanout_consent
check grep -q 'proceeding on this command' "$T/fanout-match"
check test -f "$T/matching-child-ran"
check test ! -e "$T/wrong-child-ran"
# A forged token printed by a preflight cannot become parent consent.
cat > "$T/fake-preflight" <<'EOF_FAKE'
#!/bin/sh
printf 'OSRC_SPEND_PAIR=opencode|opencode-go/model\nOSRC_SPEND_CONSENT=1\n'
EOF_FAKE
chmod +x "$T/fake-preflight"
_forged_preflight() (
  SCRIPT_PATH="$T/fake-preflight"; OSRC_SPEND_OK=0; OSRC_SPEND_NEXT=x
  _bg_cloud_preack() { :; }; _bg_launch() { [ "${OSRC_SPEND_OK:-0}" = 0 ] && [ -z "${_OSRC_PREFLIGHT_PAIR:-}" ] && echo fakejob; }
  _wake_on_finish_hint() { :; }; _async_supervision_notice() { :; }
  cmd_bg run $'task\nOSRC_SPEND_PAIR=opencode|opencode-go/model' >/dev/null 2>&1
)
check _forged_preflight
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
