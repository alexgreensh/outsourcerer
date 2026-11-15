# _run_tee_stderr <errfile|""> <cmd...> -> run the command with stderr still shown live AND captured to the
# file; stdout is untouched and the return code is the command's. An empty errfile runs the command plain.
# Three contracts, all load-bearing:
#  1. DRAINED: the file is complete, and every byte of it has been echoed to stderr, when this returns.
#     The old `2> >(tee "$f" >&2)` form returned before tee drained, so a classifier reading the file right
#     after could see it empty (CI run 43739334624: opencode expired key not marked down on ubuntu only).
#  2. IN-PROCESS: the command runs in the CURRENT shell, never the left side of a pipeline (a subshell).
#     _osrc_envrun is in-process by design; a pipeline silently drops every side effect of a shell-function
#     delegate (CI run 43747039353: the codex lane's argv capture came back empty on both OSes).
#  3. PORTABLE: Windows Git Bash is supported, so no mkfifo, process substitution, /dev/fd, flock, setsid
#     or python. The command writes stderr straight to the plain file (`2>>"$f"`); a background pump
#     copies newly appended bytes to stderr every ~0.2s, so a delegate that reports progress on stderr
#     (codex exec does) still grows the job log and the watchdog never mistakes it for silence. The pump
#     does one final copy after the command returns, then exits; we wait on its PID (a plain background
#     job, which bash 3.2 can wait on), so nothing is lost or printed twice.
# Every delegate lane funnels through _osrc_nojob here so a nested outsourcerer call never inherits this
# job's OSRC_JOB_DIR consent/cap context (L7).
_run_tee_stderr() {
  local f="${1:-}" _rt_rc=0 _rt_stop _rt_pid; shift
  [ -n "$f" ] || { _osrc_nojob "$@"; return $?; }
  # An unwritable errfile must never block the delegate: run it plain (stderr live, nothing captured).
  { : > "$f"; } 2>/dev/null || { _osrc_nojob "$@"; return $?; }
  _rt_stop="$f.done"; rm -f "$_rt_stop" 2>/dev/null
  _osrc_stderr_pump "$f" "$_rt_stop" "${BASHPID:-$$}" >&2 </dev/null & _rt_pid=$!
  _osrc_nojob "$@" 2>>"$f" || _rt_rc=$?
  : > "$_rt_stop" 2>/dev/null || kill "$_rt_pid" 2>/dev/null
  wait "$_rt_pid" 2>/dev/null
  rm -f "$_rt_stop" 2>/dev/null
  return "$_rt_rc"
}

# _osrc_stderr_pump <file> <stopfile> <owner-pid> -> copy bytes appended to <file> to stdout until <stopfile>
# exists (then one last copy) or the owner shell is gone. The stop check comes BEFORE the size read, so the
# final pass sees every byte the command wrote before it returned. Pure POSIX tools: wc, tail, head, sleep.
_osrc_stderr_pump() {
  local f="$1" stop="$2" owner="$3" off=0 sz last=0
  while :; do
    [ -e "$stop" ] && last=1
    sz=$(wc -c < "$f" 2>/dev/null | tr -d ' '); case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    [ "$sz" -lt "$off" ] && off=0
    if [ "$sz" -gt "$off" ]; then
      tail -c +"$((off + 1))" "$f" 2>/dev/null | head -c "$((sz - off))"
      off=$sz
    fi
    [ "$last" = 1 ] && return 0
    kill -0 "$owner" 2>/dev/null || return 0
    sleep 0.2 2>/dev/null || sleep 1
  done
}
