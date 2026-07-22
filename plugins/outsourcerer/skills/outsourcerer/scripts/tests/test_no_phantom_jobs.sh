#!/usr/bin/env bash
# test_no_phantom_jobs.sh — an invalid invocation must never mint a job id.
#
# What makes an invalid invocation expensive is not the error, it is the ORDER of events. cmd_bg accepted anything it did
# not recognise as a task, _bg_launch minted a job dir, nohup-detached, and printed an id. The caller got
# an id and believed work had started. The command only died later inside the detached child, which wrote
# the error into out.log and set status=failed. A caller therefore moves on from work that never ran, and
# the only record lives in a job nobody reads. A wrong quoting pattern can emit a whole run of these,
# every one launched from a literal, unexpanded variable.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Each case runs in its own OSRC_HOME so "did a job dir appear?" is an exact question.
# cmd_bg is invoked in a SUBSHELL because it `die`s, and die exits the process.
try_bg() {   # <desc> -> echoes "<exit>|<jobdirs>"
  local home; home="$(mktemp -d)"
  local out rc
  out="$( OSRC_HOME="$home" bash "$SRC" bg "$@" 2>&1 )"; rc=$?
  local n; n="$(ls -1d "$home"/jobs/*/ 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s|%s|%s' "$rc" "$n" "$out"
  rm -rf "$home"
}

# --- the literal unexpanded variable: a classic quoting bug, and a phantom-job source ---------------
r="$(try_bg '$cmd' 'some task')"
rc="${r%%|*}"; rest="${r#*|}"; n="${rest%%|*}"; msg="${rest#*|}"
[ "$n" = "0" ] && ok "an unexpanded shell variable mints NO job dir" \
               || bad "a bogus first argument still created $n job dir(s)"
[ "$rc" != "0" ] && ok "it exits non-zero instead of reporting a launch" || bad "exited 0 on a bogus launch"
case "$msg" in *"unexpanded shell variable"*) ok "the error names the actual caller bug (quoting)" ;;
  *) bad "the error does not explain the quoting mistake: $msg" ;; esac
case "$msg" in *"Nothing was started"*) ok "it states plainly that nothing was started" ;;
  *) bad "the caller is not told that nothing started" ;; esac

# --- flags with no task at all ---------------------------------------------------------------------
r="$(try_bg run -m glm)"
rest="${r#*|}"; n="${rest%%|*}"; msg="${rest#*|}"
[ "$n" = "0" ] && ok "a flags-only invocation mints NO job dir" || bad "flags-only created $n job dir(s)"
case "$msg" in *"no task text"*) ok "the error says the task is missing" ;; *) bad "unclear flags-only error"; esac

# --- -m before the verb: the second most common caller mistake -------------------------------------
# This used to die with "unknown subcommand '-m'". It is unambiguous, so it must be ACCEPTED, not
# refused: refusing it costs a whole round trip to teach the caller our argument order.
r="$(try_bg -m glm --dry-run-parse-only 'a real task')"
msg="${r#*|}"; msg="${msg#*|}"
case "$msg" in
  *"unknown subcommand '-m'"*) bad "-m before the verb is still rejected instead of hoisted" ;;
  *) ok "-m before the verb is accepted rather than rejected" ;;
esac

# --- unroutable model/lane combinations must also die in the parent -------------------------------
# These are only caught after lane resolution, which used to happen inside the DETACHED child: the
# caller got an id and a "launched" line for a combination that could never run. Only invalid cases are
# exercised here — they die before any dispatch, so this suite never spends quota or touches the network.
try_bg_acked() {   # <args...> -> "<exit>|<jobdirs>|<output>"
  local home; home="$(mktemp -d)"
  local out rc
  out="$( OSRC_HOME="$home" OSRC_CLOUD_ACK=1 bash "$SRC" bg "$@" 2>&1 )"; rc=$?
  local n; n="$(ls -1d "$home"/jobs/*/ 2>/dev/null | wc -l | tr -d ' ')"
  # Safety net: if a case ever DOES dispatch, do not leave it running.
  local d; for d in "$home"/jobs/*/; do [ -d "$d" ] && kill "$(cat "$d/pid" 2>/dev/null)" 2>/dev/null; done
  printf '%s|%s|%s' "$rc" "$n" "$out"
  rm -rf "$home"
}

check_unroutable() {  # <desc> <expected-substring> <args...>
  local desc="$1" want="$2"; shift 2
  local r; r="$(try_bg_acked "$@")"
  local rc="${r%%|*}" rest="${r#*|}"; local n="${rest%%|*}" msg="${rest#*|}"
  [ "$n" = "0" ] && ok "$desc mints no job dir" || bad "$desc still created $n job dir(s)"
  [ "$rc" != "0" ] && ok "$desc exits non-zero" || bad "$desc exited 0"
  case "$msg" in *"$want"*) ok "$desc explains why it cannot run" ;;
    *) bad "$desc gave no usable reason" ;; esac
}

check_unroutable "a Claude-only model forced through Codex" "Claude-backend-only" --provider codex run -m haiku 'x'
check_unroutable "a ChatGPT-only model forced through cc"   "ChatGPT-backend-only" --provider cc run -m sol 'x'
check_unroutable "an image model used as a text lane"       "image-generation"     run -m gpt-image 'x'

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
