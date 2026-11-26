#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
set -uo pipefail
D="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR%/}/p56r2.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/user" "$T/bin" "$T/work"
export OSRC_HOME="$T/home" HOME="$T/user" OSRC_SOURCED=1 OSRC_HEARTBEAT_DISABLED=1 PATH="$T/bin:$PATH"
# Lift the launch and pause disk floors for this fake home only (the host's free disk must not decide this test).
mkdir -p "$OSRC_HOME/disk-policy" && printf 'OSRC_DISK_MIN_GB=0\nOSRC_DISK_PAUSE_GB=0\n' > "$OSRC_HOME/disk-policy/settings"
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
_portable_bg_path() {
  { cat "$D/lib/bg-pin.sh"; sed -n '/^_osrc_bg_preflight()/,/^# ---- event emission/p' "$D/lib/spend.sh"; sed -n '/^_bg_launch() {/,/^}/p; /^cmd_bg() {/,/^}/p; /^run_job() {/,/^}/p; /^route_delegate() {/,/^}/p' "$D/outsourcerer.sh"; } > "$T/bg-path"
  ! grep -E 'python|mkfifo|fcntl|flock|setsid|/dev/fd' "$T/bg-path"
}
check _portable_bg_path
check test "$(_opencode_ver)" = 2
check test "$(lane_from_name opencode-go/glm-5.3-flash)" = opencode
check _opencode_route_check
check test "$(_lane_field opencode cost_class)" = credits
check test -z "$(_lane_field opencode plan_limited)"
check test -z "$(_resolve_run_cost opencode 0 /dev/null)"
# OpenCode is a native program on Windows: the carve-out must be in its path form
# (C:/...), computed here independently of the product helper. POSIX elsewhere.
work_native="$T/work"
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) work_native="$(cygpath -m "$T/work")" ;; esac
for mode in readonly scoped; do
  cfg="$(_opencode_config_json "$mode" "$T/work")"
  check jq -e --arg p "external_directory:$work_native/**" '[.policies[].resource]|index($p)!=null' <<< "$cfg"
done
# Seam: fake MSYS (cygpath on PATH + windows platform) must convert, both config
# layers; the same fake cygpath on mac/linux must leave the POSIX path alone.
# MSYS argv rewriting is switched off so real Git Bash proves the product converts
# the path itself instead of leaning on MSYS's guess.
mkdir -p "$T/fakecyg"
printf '#!/bin/sh\n[ "$1" = -m ] || exit 9\nprintf "C:/fake%%s\\n" "$2"\n' > "$T/fakecyg/cygpath"; chmod +x "$T/fakecyg/cygpath"
_msys_seam() (
  export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
  PATH="$T/fakecyg:$PATH"; OSRC_PLATFORM=windows
  for v in 2 1; do
    _OPENCODE_VER=$v
    for mode in readonly scoped; do
      cfg="$(_opencode_config_json "$mode" /c/Users/x/work)"
      if [ "$v" = 2 ]; then
        jq -e '[.policies[].resource,.permissions[].resource]|index("external_directory:C:/fake/c/Users/x/work/**")!=null and index("external_directory:/c/Users/x/work/**")==null' <<< "$cfg" >/dev/null || { echo "v$v $mode: $cfg"; exit 1; }
      else
        jq -e '.permission.external_directory|has("C:/fake/c/Users/x/work/**") and (has("/c/Users/x/work/**")|not)' <<< "$cfg" >/dev/null || { echo "v$v $mode: $cfg"; exit 1; }
      fi
    done
  done
  OSRC_PLATFORM=mac; _OPENCODE_VER=2
  cfg="$(_opencode_config_json readonly /Users/x/work)"
  jq -e '[.policies[].resource]|index("external_directory:/Users/x/work/**")!=null' <<< "$cfg" >/dev/null || { echo "mac: $cfg"; exit 1; }
)
check _msys_seam
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
  _heartbeat_arm_verify() { :; }; _bg_cloud_preack() { :; }; _fanout_running() { echo 0; }; _osrc_fanout_preflight() { :; }
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
  _bg_cloud_preack() { :; }; _bg_launch() { : > "$T/forged-launch"; echo fakejob; }
  _wake_on_finish_hint() { :; }; _async_supervision_notice() { :; }
  cmd_bg run $'task\nOSRC_SPEND_PAIR=opencode|opencode-go/model' >/dev/null 2>&1
)
if _forged_preflight; then echo 'FAIL: forged preflight launched'; fail=$((fail+1)); elif [ -e "$T/forged-launch" ]; then echo 'FAIL: forged preflight launched'; fail=$((fail+1)); else echo 'PASS: forged preflight cannot launch'; pass=$((pass+1)); fi
_quiet_preflight() (
  local -a _pf_provider=() _pf_spend=() _pf_args=()
  cat > "$T/quiet-preflight" <<EOF_QUIET
#!/bin/bash
echo 'ordinary diagnostic' >&2
printf '__OSRC_ROUTE__%s|%s\n' "\$_osrc_preflight_key" 'local|local|local|local|0'
EOF_QUIET
  chmod +x "$T/quiet-preflight"
  _osrc_bg_preflight "$T/quiet-preflight" >"$T/quiet-pair" 2>"$T/quiet-log" || exit 1
  [ ! -s "$T/quiet-log" ] && [ "$(cat "$T/quiet-pair")" = 'local|local|local|local|0' ]
)
check _quiet_preflight
# Local routes still bind a leading spend flag before the background launch.
_local_bg() (
  export OSRC_SOURCED=0; SCRIPT_PATH="$D/outsourcerer.sh"; OSRC_SPEND_NEXT=x
  _bg_cloud_preack() { :; }; _wake_on_finish_hint() { :; }; _async_supervision_notice() { :; }
  _bg_launch() { [ "$_OSRC_PREFLIGHT_PAIR" = 'local|local' ] && [ "$PROVIDER" = local ] && [ "$*" = 'run -m local x' ] && echo 20261115-120000-local; }
  cmd_bg --spend-ok --provider local run 'x' >"$T/local-stdout" 2>"$T/local-stderr" || exit 1
  ! grep -E '\[route\]|\[spend\]|OSRC_SPEND_CONSENT' "$T/local-stderr"
)
check _local_bg
_factory_local() (
  export OSRC_SOURCED=0; SCRIPT_PATH="$D/outsourcerer.sh"; OSRC_SPEND_NEXT=x
  _bg_cloud_preack() { :; }; _wake_on_finish_hint() { :; }; _async_supervision_notice() { :; }
  _bg_launch() { [ "$_OSRC_PREFLIGHT_PAIR" = 'local|ollama:fixture' ] || return 1; mkdir -p "$OSRC_JOBS/20261115-120000-local"; echo 20261115-120000-local; }
  cmd_plan new p56local --no-repo --no-use >/dev/null 2>&1 || exit 1
  cmd_task add 'local factory' -m ollama:fixture --plan p56local >/dev/null 2>&1 || exit 1
  OSRC_SPEND_OK=1; cmd_task start t1 --plan p56local >/dev/null 2>&1 || exit 1
  [ "$(jq -r .job "$OSRC_HOME/plans/p56local/tasks/t1.json")" = 20261115-120000-local ] || exit 1
  ! grep -E '\[route\]|\[spend\]|OSRC_SPEND_CONSENT' "$OSRC_HOME/plans/p56local/tasks/t1/launch.log"
)
check _factory_local
# Neither descriptor is available to readiness or billing probes.
cat > "$T/bin/codex" <<EOF_PROBE
#!/bin/bash
echo attempted > "$T/codex-probed"
for fd in 3 4 5 6 7 8 9 10 11 12 19 20 21 22 23 24; do eval "echo 'cx|gpt-5.6-sol' >&\$fd" 2>/dev/null || :; done
if env | grep '^_osrc_preflight_key=' | grep -vq '^_osrc_preflight_key=attacker-controlled$'; then : > "$T/secret-leaked"; fi
echo 'Logged in using ChatGPT'
EOF_PROBE
chmod +x "$T/bin/codex"
mkdir -p "$T/hostile-bin"
cat > "$T/hostile-bin/dirname" <<EOF_PROBE
#!/bin/bash
: > "$T/dirname-probed"
for fd in 3 4 5 6 7 8 9 10 11 12; do eval "echo 'cx|gpt-5.6-sol|cxnative|codex|1' >&\$fd" 2>/dev/null || :; done
if env | grep '^_osrc_preflight_key=' | grep -vq '^_osrc_preflight_key=attacker-controlled$'; then : > "$T/secret-leaked"; fi
exec /usr/bin/dirname "\$@"
EOF_PROBE
chmod +x "$T/hostile-bin/dirname"
_probe_preflight() (
  export OSRC_SOURCED=0 _osrc_preflight_key=attacker-controlled
  local -a _pf_provider=(--provider codex) _pf_spend=() _pf_args=(run -m sol task)
  local probe_rc=0
  pair="$(_osrc_bg_preflight "$D/outsourcerer.sh")" || probe_rc=$?
  [ -e "$T/codex-probed" ] || { echo 'codex probe missing'; return 1; }
  [ ! -e "$T/secret-leaked" ] || { echo 'private key reached a probe'; return 1; }
  if [ "$probe_rc" != 0 ]; then [ -z "$pair" ]; else case "$pair" in 'cx|'*'|cxnative|cxnative|0') true ;; *) echo "probe record: $pair"; false ;; esac; fi
)
check _probe_preflight
_startup_probe() (
  export OSRC_SOURCED=0 _osrc_preflight_key=attacker-controlled PATH="$T/hostile-bin:$PATH"
  local -a _pf_provider=(--provider codex) _pf_spend=() _pf_args=(run -m sol task)
  local probe_rc=0
  pair="$(_osrc_bg_preflight "$D/outsourcerer.sh")" || probe_rc=$?
  [ -e "$T/dirname-probed" ] && [ ! -e "$T/secret-leaked" ] || return 1
  if [ "$probe_rc" != 0 ]; then [ -z "$pair" ]; else case "$pair" in 'cx|'*'|cxnative|cxnative|0') true ;; *) return 1 ;; esac; fi
)
check _startup_probe
cat > "$T/bin/opencode" <<EOF_PROBE
#!/bin/bash
for fd in 3 4 5 6 7 8 9 10 11 12 19; do eval "echo forged-\$fd >&\$fd" 2>/dev/null || :; done
echo 'OpenCode Go'
EOF_PROBE
chmod +x "$T/bin/opencode"
_probe_opencode() (
  OSRC_PREFLIGHT=1; _OSRC_PREFLIGHT_FD=1; PROVIDER=opencode; _osrc_preflight_key=fixture
  route_delegate() { _lane_ready_probe opencode >/dev/null || return 1; _osrc_preflight_record opencode opencode-go/model 0; ROUTE_LANE=opencode; }
  _osrc_route_dispatch auto run >"$T/probe-leak" || exit 1
  [ "$(tail -1 "$T/probe-leak")" = '__OSRC_ROUTE__fixture|opencode|opencode-go/model|opencode|opencode|0' ] || { echo "readiness record: $(cat "$T/probe-leak")"; return 1; }
)
check _probe_opencode
_cross_provider_pin() (
  export OSRC_SOURCED=0
  local -a _pf_provider=(--provider devin) _pf_spend=(--spend-ok) _pf_args=(run -m opencode-go/model task)
  pair="$(_osrc_bg_preflight "$D/outsourcerer.sh")" || exit 1
  [ "$pair" = 'opencode|opencode-go/model|opencode|opencode|1' ]
)
check _cross_provider_pin
printf '#!/bin/sh\nexit 0\n' > "$T/bin/flock"; chmod +x "$T/bin/flock"
_lock_preflight() (
  OSRC_PREFLIGHT=1; _OSRC_PREFLIGHT_FD=1; PROVIDER=local; _osrc_preflight_key=fixture
  route_delegate() { _state_lock_acquire "$T/route-state" || return 1; [ "$_STATE_LOCK_KIND" = flock ] || return 1; _state_lock_release "$T/route-state"; _osrc_preflight_record local model 0; ROUTE_LANE=local; }
  _osrc_route_dispatch auto run >"$T/lock-pair" || exit 1
  [ "$(tail -1 "$T/lock-pair")" = '__OSRC_ROUTE__fixture|local|model|local|local|0' ]
)
check _lock_preflight
cat > "$T/lock-preflight" <<EOF_LOCK
#!/bin/bash
OSRC_SOURCED=1 . "$D/outsourcerer.sh" >/dev/null 2>&1
OSRC_PREFLIGHT=1; _OSRC_PREFLIGHT_FD=1; PROVIDER=local
route_delegate() { _state_lock_acquire "$T/live-route-state" || return 1; [ "\$_STATE_LOCK_KIND" = flock ] || return 1; _state_lock_release "$T/live-route-state"; _osrc_preflight_record local model 0; ROUTE_LANE=local; }
_osrc_route_dispatch auto run
EOF_LOCK
chmod +x "$T/lock-preflight"
_relay_lock_preflight() (
  local -a _pf_provider=() _pf_spend=() _pf_args=()
  [ "$(_osrc_bg_preflight "$T/lock-preflight")" = 'local|model|local|local|0' ]
)
check _relay_lock_preflight
_unresolved_preflight() (
  OSRC_PREFLIGHT=1; _OSRC_PREFLIGHT_FD=1; ROUTE_LANE=stale; PROVIDER=devin
  route_delegate() { _osrc_preflight_record dv model 0; }
  _osrc_route_dispatch auto run >/dev/null 2>&1
)
if _unresolved_preflight; then echo 'FAIL: incomplete preflight reused stale route'; fail=$((fail+1)); else echo 'PASS: incomplete preflight refused'; pass=$((pass+1)); fi
# Exercise the terminal prompt branch even where the sandbox cannot allocate a pty.
_buffered_prompt() (
  [() { if test "${1:-}" = -t; then test "${2:-}" != 2; else builtin [ "$@"; fi; }
  unset OSRC_SPEND_OK _OSRC_SPEND_BOUND_LANE _OSRC_SPEND_BOUND_MODEL
  OSRC_PREFLIGHT=1; _OSRC_PREFLIGHT_FD=1
  _osrc_spend_gate opencode opencode-go/model opencode test 5>"$T/tty-prompt" <<< 'y' >/dev/null 2>&1 || exit 1
  grep -q 'approve spend for THIS command' "$T/tty-prompt" && [ "$_OSRC_PREFLIGHT_LANE|$_OSRC_PREFLIGHT_MODEL|$_OSRC_PREFLIGHT_AUTH" = 'opencode|opencode-go/model|1' ]
)
check _buffered_prompt
# Refusals preserve the original filtered EVENT/NEXT diagnostics.
cat > "$T/failing-preflight" <<'EOF_FAIL'
#!/bin/sh
echo 'route banner' >&2
echo 'EVENT approval cx 1 fixture' >&2
echo 'NEXT retry' >&2
echo 'ERROR: refused fixture' >&2
exit 1
EOF_FAIL
chmod +x "$T/failing-preflight"
_failure_diagnostics() (
  local -a _pf_provider=() _pf_spend=() _pf_args=()
  _osrc_bg_preflight "$T/failing-preflight" >"$T/failure-pair" 2>"$T/failure-log" && exit 1
  grep -q '^EVENT approval' "$T/failure-log" && grep -q '^NEXT retry' "$T/failure-log" && grep -q 'ERROR: refused fixture' "$T/failure-log" && ! grep -q 'route banner' "$T/failure-log"
)
check _failure_diagnostics
# Even an explicit auto-advise setting cannot change the detached child's default route.
_default_route_parity() (
  export OSRC_SOURCED=0 OSRC_ADVISE=1
  local -a _pf_provider=() _pf_spend=(--spend-ok) _pf_args=(run 'refactor parser')
  expected="$(_route_provider_default_model devin)"
  pair="$(_osrc_bg_preflight "$D/outsourcerer.sh")" || exit 1
  [ "$pair" = "dv|$expected|devin|devin|1" ]
)
check _default_route_parity
_pinned_bg_argv() (
  export OSRC_SOURCED=0 OSRC_ADVISE=1; SCRIPT_PATH="$D/outsourcerer.sh"; OSRC_SPEND_NEXT=x
  expected="$(_route_provider_default_model devin)"
  _bg_cloud_preack() { :; }; _wake_on_finish_hint() { :; }; _async_supervision_notice() { :; }
  _bg_launch() { [ "$PROVIDER" = devin ] && [ "$_OSRC_PIN_DISP" = devin ] && [ "$*" = "run -m $expected refactor parser" ] && echo 20261115-120000-pin; }
  cmd_bg --spend-ok run 'refactor parser' >/dev/null 2>&1
)
check _pinned_bg_argv
# Real bg launch with a stub Devin, including the detached child's argv.
cat > "$T/bin/devin" <<EOF_DEVIN
#!/bin/bash
case "\$*" in
  *round6-route-task*) printf '%s\n' "\$@" > "$T/real-child-argv"; echo 'OSRC::DONE fixture' ;;
  'auth status') echo 'Logged in' ;;
  *) echo 'fixture offline' ;;
esac
EOF_DEVIN
chmod +x "$T/bin/devin"
real_expected="$(_route_provider_default_model devin)"
real_out="$(cd "$T/work" && OSRC_SOURCED=0 OSRC_ADVISE=1 OSRC_CLOUD_ACK=1 OSRC_HEARTBEAT_DISABLED=1 "$D/outsourcerer.sh" bg --spend-ok run 'round6-route-task' 2>&1)"; real_rc=$?
real_id="$(printf '%s\n' "$real_out" | awk 'NF==1 && $1 ~ /^[0-9]{8}-[0-9]{6}-/ {print $1; exit}')"
check test "$real_rc" = 0
check test -n "$real_id"
if [ -n "$real_id" ]; then
  for _i in $(seq 1 45); do [ -s "$T/real-child-argv" ] && break; sleep 1; done
  if [ -s "$T/real-child-argv" ] && grep -q -x -- "$real_expected" "$T/real-child-argv" && [ "$(jq -r '.model' "$OSRC_JOBS/$real_id/meta.json")" = "$real_expected" ]; then echo 'PASS: real bg child ran the preflight model'; pass=$((pass+1)); else echo "FAIL: real bg child did not run pinned model: $real_out"; fail=$((fail+1)); fi
  OSRC_SOURCED=0 "$D/outsourcerer.sh" wait "$real_id" >/dev/null 2>&1; check test "$?" = 0
fi
_engine_defaults() (
  local lane default
  for lane in droid cursor hermes warp cline pi grokbot; do
    default="$(_lane_field "$lane" default_model)"
    _osrc_preflight_unpack "$lane|$default|$lane|$lane|1" || return 1
    _osrc_pin_argv run --spend-ok 'engine task' || return 1
    [ "${_OSRC_PIN_ARGV[*]}" = 'run --spend-ok engine task' ] || return 1
    MODEL="$default"; MODEL_EXPLICIT=0; PROVIDER="$lane"
    _lane_cli_gate() { :; }
    _osrc_pinned_resolve || return 1
    [ "$disp" = "$lane" ] && [ "$RESOLVED_ID" = "$default" ] && [ "$_OSRC_PREFLIGHT_PAIR" = "$lane|$default" ] || return 1
  done
)
check _engine_defaults
_pin_flag_forms() (
  _OSRC_PIN_DISP=devin; _OSRC_PIN_MODEL=pinned
  _osrc_pin_argv run --model=old -mold --tier capable 'task -m text' || return 1
  [ "${_OSRC_PIN_ARGV[*]}" = 'run -m pinned --model=old -mold --tier capable task -m text' ] || return 1
  _osrc_pin_argv run -mold 'task -m text' || return 1
  [ "${_OSRC_PIN_ARGV[*]}" = 'run -m pinned -mold task -m text' ] || return 1
  ! _osrc_pin_argv run --tier && ! _osrc_pin_argv run -m
)
check _pin_flag_forms
_bg_prompt_words() (
  export OSRC_SOURCED=0; SCRIPT_PATH="$D/outsourcerer.sh"; OSRC_SPEND_NEXT=x
  _bg_cloud_preack() { :; }; _wake_on_finish_hint() { :; }; _async_supervision_notice() { :; }
  _bg_launch() {
    [ "$1|$2|$3" = 'run|-m|local' ] || return 1; shift 3
    [ "$#" = "${#expected[@]}" ] || return 1
    local word; for word in "${expected[@]}"; do [ "$1" = "$word" ] || return 1; shift; done
    echo 20261115-120000-prompt
  }
  local -a expected=('-mention the timeout')
  cmd_bg --provider local run '-mention the timeout' >/dev/null 2>&1 || return 1
  expected=(--model=opus fix)
  cmd_bg --provider local run --model=opus fix >/dev/null 2>&1
)
check _bg_prompt_words
_engine_default_bg() (
  export OSRC_SOURCED=0; SCRIPT_PATH="$D/outsourcerer.sh"; OSRC_SPEND_NEXT=x
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/droid"; chmod +x "$T/bin/droid"
  _bg_cloud_preack() { :; }; _wake_on_finish_hint() { :; }; _async_supervision_notice() { :; }
  _bg_launch() { [ "$PROVIDER|$_OSRC_PIN_DISP|$_OSRC_PREFLIGHT_PAIR|$*" = 'droid|droid|droid|droid-default|run task' ] || return 1; echo 20261115-120000-default; }
  cmd_bg --spend-ok --provider droid run task >/dev/null 2>&1
)
check _engine_default_bg
_native_job_metadata() (
  local lane output id i
  for lane in ccnative cxnative gmnative; do [ "$(_osrc_pin_provider "$lane")" = "$lane" ] || return 1; done
  cat > "$T/bin/codex" <<EOF_NATIVE
#!/bin/bash
case "\${1:-}" in exec) printf '%s' "\$OUTSOURCERER_PROVIDER" > "$T/native-child-provider"; echo 'OSRC::DONE fixture' ;; *) echo 'Logged in using ChatGPT' ;; esac
EOF_NATIVE
  chmod +x "$T/bin/codex"
  output="$(cd "$T/work" && OSRC_SOURCED=0 OSRC_CLOUD_ACK=1 "$D/outsourcerer.sh" bg --spend-ok run -m sol 'native metadata fixture' 2>&1)" || return 1
  id="$(printf '%s\n' "$output" | awk 'NF==1 && $1 ~ /^[0-9]{8}-[0-9]{6}-/ {print $1; exit}')"
  [ -n "$id" ] || return 1
  for i in $(seq 1 45); do [ -s "$T/native-child-provider" ] && [ -f "$OSRC_JOBS/$id/meta.json" ] && break; sleep 1; done
  [ "$(jq -r '.provider + "|" + .lane' "$OSRC_JOBS/$id/meta.json")" = 'cxnative|cx' ] && [ "$(cat "$T/native-child-provider")" = cxnative ] || return 1
  OSRC_SOURCED=0 "$D/outsourcerer.sh" wait "$id" >/dev/null 2>&1
)
check _native_job_metadata
_child_disables_advise() (
  export OSRC_ADVISE=1; unset OSRC_NO_ADVISE
  _OSRC_PIN_DISP=devin; _OSRC_PIN_MODEL=swe-2-high
  _supervise() { printf '%s' "${OSRC_NO_ADVISE:-}" > "$T/child-no-advise"; printf '%s\n' "$@" > "$T/child-argv"; return 0; }
  run_job advise-test devin run 'refactor parser' >/dev/null 2>&1 || true
  [ "$(cat "$T/child-no-advise" 2>/dev/null)" = 1 ] && grep -q '^--osrc-pinned-route$' "$T/child-argv" && grep -q '^swe-2-high$' "$T/child-argv"
)
check _child_disables_advise
_pinned_catalog_drift() (
  MODEL=swe-2-high; PROVIDER=devin; _OSRC_PIN_DISP=devin; _OSRC_PIN_MODEL=swe-2-high
  _devin_resolve_model() { echo changed-model; }
  _osrc_pinned_resolve || exit 1
  [ "$RESOLVED_ID" = swe-2-high ] && [ "$disp" = devin ] && ! _fallback_enabled && ! _failover_hop auto run
)
check _pinned_catalog_drift
if ( MODEL=claude-forged; PROVIDER=devin; _OSRC_PIN_DISP=devin; _OSRC_PIN_MODEL="$MODEL"; _osrc_pinned_resolve ) >/dev/null 2>&1; then echo 'FAIL: pinned native family bypass accepted'; fail=$((fail+1)); else echo 'PASS: pinned native family bypass refused'; pass=$((pass+1)); fi
if ( MODEL=image-forged; PROVIDER=devin; _OSRC_PIN_DISP=devin; _OSRC_PIN_MODEL="$MODEL"; resolve_model_row() { echo 'image-forged|gi|frontier'; }; _osrc_pinned_resolve ) >/dev/null 2>&1; then echo 'FAIL: pinned image bypass accepted'; fail=$((fail+1)); else echo 'PASS: pinned image bypass refused'; pass=$((pass+1)); fi
_preflight_native_id() (
  _OSRC_PREFLIGHT_FD=1; disp=devin; RESOLVED_ID=alias
  _devin_resolve_model() { echo native-model-id; }; _exclude_refuse_resolved() { :; }
  _osrc_preflight_native && [ "$RESOLVED_ID" = native-model-id ] || exit 1
  disp=opencode; RESOLVED_ID=glm-5.3-flash
  _osrc_preflight_native && [ "$RESOLVED_ID" = opencode-go/glm-5.3-flash ]
)
check _preflight_native_id
if ( _OSRC_PIN_DISP=devin; _OSRC_PIN_MODEL=one; _osrc_pinned_assert devin two ) >/dev/null 2>&1; then echo 'FAIL: changed route accepted'; fail=$((fail+1)); else echo 'PASS: changed route refused'; pass=$((pass+1)); fi
check test -z "$(find "$OSRC_HOME" -maxdepth 1 -name '.preflight.*' -print)"
# The fake preflight refuses before a launch can be started.
cat > "$T/interrupt-preflight" <<'EOF_INT'
#!/bin/sh
exit 130
EOF_INT
chmod +x "$T/interrupt-preflight"
_interrupted_preflight() (
  SCRIPT_PATH="$T/interrupt-preflight"; OSRC_SPEND_NEXT=x; _OSRC_PREFLIGHT_PAIR=""
  _bg_launch() { : > "$T/interrupted-launch"; echo unexpected; }
  trap 'printf "%s" "${_OSRC_PREFLIGHT_PAIR:-}" > "$T/interrupted-pair"' EXIT
  cmd_bg run task >/dev/null 2>&1
)
_interrupted_preflight; int_rc=$?
check test "$int_rc" != 0
check test -f "$T/interrupted-pair"
check test ! -s "$T/interrupted-pair"
check test ! -e "$T/interrupted-launch"
# Process groups (os.killpg) and pseudo-terminals (pty) do not exist for Windows Python, so these two
# real-signal/real-terminal cases run on macOS and Linux only; every other check above runs under Git Bash too.
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) _p56_posix=0 ;; *) _p56_posix=1 ;; esac
if [ "$_p56_posix" = 0 ]; then
  echo 'SKIP: Ctrl-C process-group and pseudo-terminal cases need POSIX (Windows Git Bash)'
else
# Deliver Ctrl-C to the isolated process group while the fake preflight is running.
cat > "$T/wait-preflight" <<EOF_WAIT
#!/bin/sh
: > "$T/preflight-ready"
while :; do sleep 1; done
EOF_WAIT
chmod +x "$T/wait-preflight"
python3 - "$D/outsourcerer.sh" "$T/wait-preflight" "$T/preflight-ready" "$T/ctrlc-pair" "$T/ctrlc-launch" <<'PY_INT'
import glob, os, signal, subprocess, sys, time
script, fake, ready, pair, launch = sys.argv[1:]
command = '''. "$1" >/dev/null 2>&1; SCRIPT_PATH="$2"; PAIR_PATH="$3"; LAUNCH_PATH="$4"; OSRC_SPEND_NEXT=x; _OSRC_PREFLIGHT_PAIR=""
_bg_launch() { : > "$LAUNCH_PATH"; echo unexpected; }
trap 'printf "%s" "${_OSRC_PREFLIGHT_PAIR:-}" > "$PAIR_PATH"; exit 130' INT TERM
trap 'printf "%s" "${_OSRC_PREFLIGHT_PAIR:-}" > "$PAIR_PATH"' EXIT
cmd_bg run task'''
proc = subprocess.Popen(['/bin/bash', '-c', command, 'test', script, fake, pair, launch], start_new_session=True,
                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    deadline = time.monotonic() + 15
    while not os.path.exists(ready) and proc.poll() is None and time.monotonic() < deadline:
        time.sleep(0.05)
    if not os.path.exists(ready):
        raise RuntimeError('preflight never started')
    os.killpg(proc.pid, signal.SIGINT)
    rc = proc.wait(timeout=15)
    deadline = time.monotonic() + 5
    while not os.path.exists(pair) and time.monotonic() < deadline:
        time.sleep(0.05)
    deadline = time.monotonic() + 5
    remaining = glob.glob(os.path.join(os.environ['OSRC_HOME'], '.preflight.*'))
    while remaining and time.monotonic() < deadline:
        time.sleep(0.05)
        remaining = glob.glob(os.path.join(os.environ['OSRC_HOME'], '.preflight.*'))
    if rc == 0 or not os.path.exists(pair) or os.path.getsize(pair) or os.path.exists(launch) or remaining:
        raise RuntimeError('interrupted preflight rc=%s, pair or launch incorrect' % rc)
except Exception as exc:
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
    print(exc, file=sys.stderr)
    sys.exit(1)
PY_INT
check test "$?" = 0
# A real terminal exercises routing parity and the interactive spend prompt.
python3 - "$D/outsourcerer.sh" <<'PY_PTY'
import errno, os, pty, select, signal, subprocess, sys, time
try:
    master, slave = pty.openpty()
except OSError as exc:
    print('SKIP: pseudo-terminal unavailable: %s' % exc)
    sys.exit(77)
cmd = r'''. "$1" >/dev/null 2>&1; expected="$(_route_provider_default_model devin)"
export OSRC_SOURCED=0 OSRC_ADVISE=1
_pf_provider=(); _pf_spend=(--spend-ok); _pf_args=(run 'refactor parser')
pair="$(_osrc_bg_preflight "$1")" || exit 11
printf 'PAIR=%s EXPECT=dv|%s|devin|devin|1\n' "$pair" "$expected"
_pf_provider=(--provider opencode); _pf_spend=(); _pf_args=(run -m opencode-go/model task)
pair="$(_osrc_bg_preflight "$1")" || exit 12
printf 'PAIDPAIR=%s\n' "$pair"'''
proc = subprocess.Popen(['/bin/bash', '-c', cmd, 'pty-test', sys.argv[1]], stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
os.close(slave)
output = b''; answered = False; deadline = time.monotonic() + 45
try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.2)
        if ready:
            try: chunk = os.read(master, 8192)
            except OSError as exc:
                if exc.errno == errno.EIO: break
                raise
            if not chunk: break
            output += chunk
            if b'approve spend for THIS command only' in output and not answered:
                os.write(master, b'y\n'); answered = True
        if proc.poll() is not None and not ready: break
    rc = proc.wait(timeout=3)
    text = output.decode('utf-8', 'replace')
    pairline = next((line for line in text.splitlines() if line.startswith('PAIR=')), '')
    if (rc or not answered or not pairline.startswith('PAIR=dv|') or
        pairline.split(' EXPECT=', 1)[0][5:] != pairline.split(' EXPECT=', 1)[-1] or
        'PAIDPAIR=opencode|opencode-go/model|opencode|opencode|1' not in text or '[advise]' in text or
        'OSRC_SPEND_CONSENT' in text):
        raise RuntimeError('rc=%s terminal output=%r' % (rc, text))
except Exception as exc:
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGKILL); proc.wait()
    print(exc, file=sys.stderr); sys.exit(1)
finally:
    os.close(master)
PY_PTY
pty_rc=$?
if [ "$pty_rc" = 77 ]; then echo 'SKIP: terminal test needs a pseudo-terminal'; else check test "$pty_rc" = 0; fi
fi
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
