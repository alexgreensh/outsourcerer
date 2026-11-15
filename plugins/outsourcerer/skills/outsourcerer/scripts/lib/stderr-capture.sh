# _run_tee_stderr <errfile|""> <cmd...> -> run the command with stderr still shown live AND captured to the
# file; stdout is untouched and the return code is the command's. An empty errfile runs the command plain.
# Two contracts, both load-bearing:
#  1. DRAINED: the file is complete when this returns. The old `2> >(tee "$f" >&2)` form returned before tee
#     drained, so a classifier reading the file right after could see it empty (CI run 43739334624:
#     opencode expired key not marked down on ubuntu only). Bash 3.2 cannot `wait` a process substitution,
#     so tee reads a private FIFO as a background job whose PID we DO wait on.
#  2. IN-PROCESS: the command runs in the CURRENT shell, never the left side of a pipeline (a subshell).
#     _osrc_envrun is in-process by design; a pipeline silently drops every side effect of a shell-function
#     delegate (CI run 43747039353: the codex lane's argv capture came back empty on both OSes).
# If mkfifo is unavailable the foreground pipeline is the fallback: drained, but subshelled.
# Every delegate lane funnels through _osrc_nojob here so a nested outsourcerer call never inherits this
# job's OSRC_JOB_DIR consent/cap context (L7).
_run_tee_stderr() {
  local f="${1:-}" _rt_rc=0 _rt_p _rt_pid; shift
  [ -n "$f" ] || { _osrc_nojob "$@"; return $?; }
  _rt_p="$f.fifo"; rm -f "$_rt_p" 2>/dev/null
  if mkfifo -m 600 "$_rt_p" 2>/dev/null; then
    tee "$f" >&2 <"$_rt_p" & _rt_pid=$!
    _osrc_nojob "$@" 2>"$_rt_p" || _rt_rc=$?
    wait "$_rt_pid" 2>/dev/null
    rm -f "$_rt_p" 2>/dev/null
    return "$_rt_rc"
  fi
  { _osrc_nojob "$@" 2>&1 1>&3 3>&- | tee "$f" >&2; _rt_rc=${PIPESTATUS[0]}; } 3>&1
  return "$_rt_rc"
}
