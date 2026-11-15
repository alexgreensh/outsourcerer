# _run_tee_stderr <errfile|""> <cmd...> -> run the command with stderr still shown live AND captured to the
# file; stdout is untouched and the return code is the command's. An empty errfile runs the command plain.
# The old `2> >(tee "$f" >&2)` form returned before tee drained, so a classifier reading the file right after
# could see it empty (CI run 43739334624: opencode expired key not marked down on ubuntu only). A foreground
# pipeline waits for tee on Bash 3.2. Every delegate lane funnels through _osrc_nojob here so a nested
# outsourcerer call never inherits this job's OSRC_JOB_DIR consent/cap context (L7).
_run_tee_stderr() {
  local f="${1:-}" rc; shift
  [ -n "$f" ] || { _osrc_nojob "$@"; return $?; }
  { _osrc_nojob "$@" 2>&1 1>&3 3>&- | tee "$f" >&2; rc=${PIPESTATUS[0]}; } 3>&1
  return "$rc"
}
