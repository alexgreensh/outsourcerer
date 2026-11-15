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
_quiet_preflight() (
  local -a _pf_provider=() _pf_spend=() _pf_args=()
  _osrc_bg_preflight "$T/fake-preflight" >"$T/quiet-pair" 2>"$T/quiet-log" || exit 1
  [ ! -s "$T/quiet-log" ] && [ -z "$(cat "$T/quiet-pair")" ]
)
check _quiet_preflight
# Local routes still bind a leading spend flag before the background launch.
_local_bg() (
  export OSRC_SOURCED=0; SCRIPT_PATH="$D/outsourcerer.sh"; OSRC_SPEND_NEXT=x
  _bg_cloud_preack() { :; }; _wake_on_finish_hint() { :; }; _async_supervision_notice() { :; }
  _bg_launch() { [ "$_OSRC_PREFLIGHT_PAIR" = 'local|local' ] && echo 20261115-120000-local; }
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
echo 'cx|gpt-5.6-sol' >&3 2>/dev/null || :
echo 'cx|gpt-5.6-sol' >&9 2>/dev/null || :
echo 'Logged in using ChatGPT'
EOF_PROBE
chmod +x "$T/bin/codex"
_probe_preflight() (
  export OSRC_SOURCED=0
  local -a _pf_provider=(--provider codex) _pf_spend=() _pf_args=(run -m sol task)
  pair="$(_osrc_bg_preflight "$D/outsourcerer.sh")" || exit 1
  [ -e "$T/codex-probed" ] && [ -z "$pair" ]
)
check _probe_preflight
cat > "$T/bin/opencode" <<EOF_PROBE
#!/bin/bash
echo 'opencode|fake' >&3 2>/dev/null || :
echo 'opencode|fake' >&9 2>/dev/null || :
echo 'OpenCode Go'
EOF_PROBE
chmod +x "$T/bin/opencode"
_probe_opencode() (
  exec 9>"$T/probe-leak" 3>&-
  _lane_ready_probe opencode >/dev/null || exit 1
  [ ! -s "$T/probe-leak" ]
)
check _probe_opencode
# Exercise the terminal prompt branch even where the sandbox cannot allocate a pty.
_buffered_prompt() (
  [() { if test "${1:-}" = -t; then test "${2:-}" != 2; else builtin [ "$@"; fi; }
  unset OSRC_SPEND_OK _OSRC_SPEND_BOUND_LANE _OSRC_SPEND_BOUND_MODEL
  OSRC_PREFLIGHT=1; _OSRC_PREFLIGHT_FD=1
  _osrc_spend_gate opencode opencode-go/model opencode test 8>"$T/tty-prompt" 9>"$T/tty-pair" <<< 'y' >/dev/null 2>&1 || exit 1
  grep -q 'approve spend for THIS command' "$T/tty-prompt" && [ "$(cat "$T/tty-pair")" = 'opencode|opencode-go/model' ]
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
  [ "$pair" = "dv|$expected" ]
)
check _default_route_parity
_child_disables_advise() (
  export OSRC_ADVISE=1; unset OSRC_NO_ADVISE
  _supervise() { printf '%s' "${OSRC_NO_ADVISE:-}" > "$T/child-no-advise"; return 0; }
  run_job advise-test devin run 'refactor parser' >/dev/null 2>&1 || true
  [ "$(cat "$T/child-no-advise" 2>/dev/null)" = 1 ]
)
check _child_disables_advise
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
# Deliver Ctrl-C to the isolated process group while the fake preflight is running.
cat > "$T/wait-preflight" <<EOF_WAIT
#!/bin/sh
: > "$T/preflight-ready"
while :; do sleep 1; done
EOF_WAIT
chmod +x "$T/wait-preflight"
python3 - "$D/outsourcerer.sh" "$T/wait-preflight" "$T/preflight-ready" "$T/ctrlc-pair" "$T/ctrlc-launch" <<'PY_INT'
import os, signal, subprocess, sys, time
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
    if rc == 0 or not os.path.exists(pair) or os.path.getsize(pair) or os.path.exists(launch):
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
printf 'PAIR=%s EXPECT=dv|%s\n' "$pair" "$expected"
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
        'PAIDPAIR=opencode|opencode-go/model' not in text or '[advise]' in text or
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
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
