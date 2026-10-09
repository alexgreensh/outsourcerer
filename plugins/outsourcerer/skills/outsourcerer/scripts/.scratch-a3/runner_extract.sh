_SUITE_TIMEOUT_DEFAULT=600
_suite_descendants() {   # echo ALL descendant pids of $1 (recursive, parent-before-child order)
  local p
  if have pgrep; then
    for p in $(pgrep -P "$1" 2>/dev/null); do echo "$p"; _suite_descendants "$p"; done
  else
    # No pgrep (Git Bash / MSYS): derive children from `ps`. Column layout DIFFERS: System-V `ps -ef`
    # is "UID PID PPID ..." but MSYS `ps` is "PID PPID ...", so locate the PID/PPID columns from the
    # header instead of assuming positions.
    ps -ef 2>/dev/null | awk -v pp="$1" '
      NR==1 { for(i=1;i<=NF;i++){ u=toupper($i); if(u=="PID")pc=i; else if(u=="PPID")ppc=i } next }
      (pc && ppc && $ppc==pp) { print $pc }
    ' | while IFS= read -r p; do [ -n "$p" ] && { echo "$p"; _suite_descendants "$p"; }; done
  fi
}
_suite_kill_tree() {   # TERM the whole subtree deepest-first, then KILL survivors.
  local pid="$1" all rev p
  all="$pid $(_suite_descendants "$pid")"
  rev=""; for p in $all; do rev="$p $rev"; done          # reverse -> deepest child first, root last
  for p in $rev; do kill -TERM "$p" 2>/dev/null; done
  sleep 2
  all="$pid $(_suite_descendants "$pid")"; rev=""; for p in $all; do rev="$p $rev"; done
  for p in $rev; do kill -KILL "$p" 2>/dev/null; done
}
_suite_ppid_of() {   # echo the ppid of $1; empty when it cannot be determined (treated as "not ours")
  local out
  out="$(ps -o ppid= -p "$1" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$out" ]; then printf '%s' "$out"; return; fi
  # ps without -o/-p (some busybox/MSYS builds): locate the PID/PPID columns from the header,
  # same as the no-pgrep branch above.
  ps -ef 2>/dev/null | awk -v me="$1" '
    NR==1 { for(i=1;i<=NF;i++){ u=toupper($i); if(u=="PID")pc=i; else if(u=="PPID")ppc=i } next }
    (pc && ppc && $pc==me) { print $ppc }
  '
}
_run_unit_suite_bounded() {   # <suite.sh>; results in _suite_out, _suite_rc, _suite_timed_out, _suite_secs
  # Capture rather than discard: a failing suite whose output went to /dev/null makes a CI log say
  # "test_x FAILED" and nothing else, which is the difference between a fixable report and a mystery.
  # Output goes through a private file, not the command-substitution pipe: a missed grandchild
  # holding that pipe would keep the capture blocked long after the bound fired. Static suites must
  # not inherit a live status beacon; it can outlive a focused test and perturb unrelated
  # supervisor-label assertions. Fresh OSRC_HOME per suite: a shared home let one suite's
  # jobs/sessions/locks/registry state perturb a later tmux/session-heavy suite, so suites that
  # pass standalone failed only in the aggregate. Isolate the state (a suite that sets its own
  # OSRC_HOME still overrides this).
  local suite="$1" secs out_file pid_file expired _home root wd_pid _st
  _suite_out=""; _suite_rc=0; _suite_timed_out=0; _suite_secs=""
  case "${OSRC_SUITE_TIMEOUT:-}" in
    0) secs=0 ;;                                   # 0 explicitly disables the bound
    ''|*[!0-9]*) secs="$_SUITE_TIMEOUT_DEFAULT" ;; # unset or non-numeric falls back to the default
    *) secs="$OSRC_SUITE_TIMEOUT" ;;
  esac
  _suite_secs="$secs"
  out_file="$(mktemp "${TMPDIR:-/tmp}/osrc-suite-out.XXXXXX")" || { _suite_rc=127; return 127; }
  pid_file="$out_file.pid"
  expired="$out_file.expired"
  # Never risk an empty OSRC_HOME: the suite would run against the user's real ~/.outsourcerer.
  _home="$(mktemp -d)" || { rm -f "$out_file" 2>/dev/null; _suite_rc=127; return 127; }
  # The SUITE stays in the FOREGROUND. A background job starts with SIGINT/SIGQUIT ignored, and a
  # shell cannot trap or reset a signal that was ignored at entry, so every INT trap in a suite or
  # in the engine (_supervise, the obligation guard, the fifo streamer, the fallback runner) would
  # silently never install, and the suites would prove something different from before. Only the
  # WATCHDOG is backgrounded. The root pid reaches it through a file: bash -c writes its own pid
  # (exec keeps it, so it IS the suite root) plus the ppid it was launched with, and the watchdog
  # reads both after the bound expires. The ppid is recorded at launch instead of compared against
  # $$ later because $$ keeps the TOP-level shell's pid inside subshells (bash 3.2 has no
  # BASHPID), so any caller from a subshell would make a $$ comparison read the wrong parent.
  wd_pid=""
  if [ "$secs" -gt 0 ] 2>/dev/null; then
    # Pure-bash watchdog (works on macOS bash 3.2, Linux, Git Bash: no timeout/setsid/pgid kills).
    # When the suite finishes first, TERM makes this subshell kill its own sleep and exit, so no
    # stray sleep outlives the suite. When the timer wins, the suite is killed WITH its whole tree.
    (
      _wd_sleep=""
      trap '[ -n "$_wd_sleep" ] && kill "$_wd_sleep" 2>/dev/null; exit 0' TERM
      sleep "$secs" & _wd_sleep=$!
      wait "$_wd_sleep"
      # Tolerate a pidfile that does not exist yet, or a suite already gone.
      root=""; _pp0=""
      [ -f "$pid_file" ] && read -r root _pp0 < "$pid_file" 2>/dev/null
      case "$root" in ''|*[!0-9]*) exit 0 ;; esac
      case "${_pp0:-}" in ''|*[!0-9]*) exit 0 ;; esac
      # A zombie means the suite just exited on its own and is merely unreaped; its real exit
      # code must win over the bound.
      _st="$(ps -o state= -p "$root" 2>/dev/null | tr -d '[:space:]')"
      # ps without -o state= (busybox/Alpine) yields nothing even for a live PID; fall back to the
      # portable kill -0 liveness probe so the bound still fires.
      if [ -z "$_st" ] && kill -0 "$root" 2>/dev/null; then _st="R"; fi
      case "$_st" in Z*|"" ) exit 0 ;; esac
      # Never kill a recycled pid: act only while the root still has the ppid it was launched
      # with, which is the gate shell that ran it (the gate blocks on the foreground suite, so
      # the ppid cannot legitimately change while the suite is ours).
      [ "$(_suite_ppid_of "$root")" = "$_pp0" ] || exit 0
      : > "$expired" 2>/dev/null
      _suite_kill_tree "$root" 2>/dev/null
    ) &
    wd_pid=$!
  fi
  _suite_pid_file="$pid_file"
  # The caller's fd2 is scoped to /dev/null around the foreground run: when the watchdog kills
  # the suite, THIS shell would print a "Terminated: 15" diagnostic for its foreground child into
  # the gate log, which is exactly the noise the timeout report replaces. The suite's own stderr
  # is unaffected (its command redirect sends it to the capture file).
  { OSRC_HOME="$_home" OSRC_HEARTBEAT_DISABLED=1 bash -c 'echo "$$ $PPID" > "$1"; exec bash "$2"' _ "$pid_file" "$suite" >"$out_file" 2>&1; _suite_rc=$?; } 2>/dev/null
  _suite_pid_file=""
  if [ -n "$wd_pid" ] && [ -f "$expired" ]; then
    # Timer won: let the watchdog finish its kill, then walk the tree once more so a descendant
    # that ignored TERM (the wedged-tool shape) is KILLed rather than left spinning. The pidfile
    # is read exactly the way the watchdog reads it: it holds TWO numbers ("PID PPID"), and a
    # plain tr-glue once fused them into one bogus pid and aimed the walk at an unrelated
    # process. The same launch-ppid guard applies, and a root that is already gone is left alone.
    wait "$wd_pid" 2>/dev/null
    root=""; pp0=""
    [ -f "$pid_file" ] && read -r root pp0 < "$pid_file" 2>/dev/null
    case "$root" in ''|*[!0-9]*) root="" ;; esac
    case "${pp0:-}" in ''|*[!0-9]*) root="" ;; esac
    if [ -n "$root" ] && [ "$(_suite_ppid_of "$root")" = "$pp0" ]; then
      _suite_kill_tree "$root" 2>/dev/null
    fi
    _suite_timed_out=1
    _suite_rc=124
  elif [ -n "$wd_pid" ]; then
    kill "$wd_pid" 2>/dev/null; wait "$wd_pid" 2>/dev/null
  fi
  _suite_out="$(cat "$out_file" 2>/dev/null)"
  rm -f "$out_file" "$pid_file" "$expired" 2>/dev/null
  rm -rf "$_home" 2>/dev/null
  return 0
}
_report_unit_suite_result() {   # <suite-name>; reads the _suite_* state _run_unit_suite_bounded set
  if [ "$_suite_timed_out" -eq 1 ]; then
    bad "unit suite $1 TIMED OUT after ${_suite_secs}s"
    printf '%s\n' "$_suite_out" | grep -E '^(FAIL|SKIP)' | sed 's/^/      /'
  elif [ "$_suite_rc" -eq 0 ]; then ok "unit suite $1 green"
  else
    bad "unit suite $1 FAILED"
    printf '%s\n' "$_suite_out" | grep -E '^(FAIL|SKIP)' | sed 's/^/      /'
  fi
}
# Ctrl-C must still stop everything, including a suite that ignores INT: the terminal already
# signals the whole foreground group, this sweep also kills the current suite's tree, then the
# gate itself exits instead of rolling on to the next suite.
_gate_int_sweep() {
  [ -n "${_suite_pid_file:-}" ] && [ -f "$_suite_pid_file" ] || return 0
  local root pp0
  read -r root pp0 < "$_suite_pid_file" 2>/dev/null || return 0
  case "$root" in ''|*[!0-9]*) return 0 ;; esac
  case "${pp0:-}" in ''|*[!0-9]*) return 0 ;; esac
  # Same recycled-pid guard as the watchdog: only sweep a root that still has the ppid it was
  # launched with, i.e. a child of this gate.
  [ "$(_suite_ppid_of "$root")" = "$pp0" ] || return 0
  _suite_kill_tree "$root" 2>/dev/null
}
trap '_gate_int_sweep; exit 130' INT
