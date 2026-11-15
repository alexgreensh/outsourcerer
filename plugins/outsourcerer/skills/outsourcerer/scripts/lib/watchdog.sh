# lib/watchdog.sh: the job watchdog (_supervise) and its first-model-output proof.
# Moved verbatim out of outsourcerer.sh (size rule: that file may only shrink). Sourced by the
# lib loader; defines functions only, no side effects at load time.


# Positive initialization proof for the supervisor. A line is accepted only
# when it can be real agent/model output: semantic progress, a structured
# assistant/model event, or non-empty plain model text. Launcher disclosure,
# tier banners (for every tier), and stderr diagnostics never initialize a job.
_delegate_has_model_output() { # <out.log> <progress>
  local log="$1" progress="${2:-}"
  [ -s "$progress" ] && grep -aqE '^OSRC::(PROGRESS|PLAN|BLOCKED|NEED_INPUT|DONE)' "$progress" 2>/dev/null && return 0
  [ -f "$log" ] || return 1
  awk '
    /^[[:space:]]*$/ { next }
    # POSITIVE 1: our own orchestrator progress markers (same set the progress-file check accepts)
    /OSRC::(PROGRESS|PLAN|BLOCKED|NEED_INPUT|DONE)/ { found=1; exit }
    # POSITIVE 2: explicit assistant role provenance
    /"role"[[:space:]]*:[[:space:]]*"assistant"/ { found=1; exit }
    # POSITIVE 3: real token/content stream event TYPES (NOT bare "message", NOT lifecycle)
    /"type"[[:space:]]*:[[:space:]]*"(content_block_delta|content_block_start|output_text|output_text_delta|assistant_message|agent_message|model_output|item\.completed)"/ { found=1; exit }
    # From here down: definitely-not-output. Skip diagnostics/lifecycle/chatter, never set found.
    /^>>>[[:space:]]/ { next }
    /^[[:space:]]*tier=[^,[:space:]]+([,[:space:]]|$)/ { next }
    /^[[:space:]]*(ERROR|ERR|FATAL|WARN|WARNING)(:|[[:space:]])/ { next }
    /^[[:space:]]*\[[^]]*(ERROR|ERR|FATAL|WARN|WARNING)[^]]*\]/ { next }
    # Short status lines and retry churn are not model output.
    /^[[:space:]]*(Connecting|connecting|Connection|Reconnecting|Retrying|Waiting|Resuming|Authenticating|Authenticated|Connected)([.[:space:]:]|$)/ { next }
    /^[[:space:]]*(Loading|Starting|Initializing|Initialized|Warming|Ready|Preparing|Spawning|Launching)([.[:space:]:]|$)/ && (length($0) < 120 || /attempt [0-9]+ *of *[0-9]+|backoff [0-9]+s|will keep trying/) { next }
    # hook/tool/session lifecycle lines
    /^[[:space:]]*(Hook|Tool|SessionStart|SessionEnd|PreToolUse|PostToolUse|UserPromptSubmit|Notification|Stop|SubagentStop|PreCompact)(:|[[:space:]])/ { next }
    # generic "Word:" log-prefix (SessionStart: , Foo: ) and [bracketed] log prefixes
    /^[[:space:]]*[A-Za-z][A-Za-z0-9_-]*:[[:space:]]/ { next }
    /^[[:space:]]*\[[^]]*\][[:space:]]*/ { next }
    # spinner glyphs
    /^[[:space:]]*[|\\\/⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏-][[:space:]]*$/ { next }
    # any JSON/structural line that did NOT match the assistant-provenance positives above: NOT output
    /^[[:space:]]*[\{\[]/ { next }
    # POSITIVE 4 (last resort): substantive assistant PLAINTEXT — must contain a real
    # alpha word of >=3 letters AND total alpha>=16, after passing every denylist above.
    {
      alpha=$0; gsub(/[^A-Za-z]/,"",alpha)
      if (length(alpha) >= 16 && $0 ~ /[A-Za-z]{3,}/) { found=1; exit }
      next
    }
    END { exit(found ? 0 : 1) }
  ' "$log" 2>/dev/null
}

# _supervise <job-dir> <stall_warn> <stall_kill> <hard_timeout> -- <cmd...>
# Byte-growth watchdog + OSRC:: semantic layer + exit contract (0 done / 2 done? / 3 blocked /
# 124 timeout / 125 wedged / other = delegate rc).
_supervise() {
  local jd="$1" warn="$2" kill_after="$3" hard="$4"; shift 4
  [ "${1:-}" = "--" ] && shift
  # Job dir private, out.log restricted. The job dir usually already exists (the launcher claimed
  # it); _mkdir_private treats that as success and re-applies the mode either way. 600 out.log
  # because it can contain tool output. The chmod is best-effort for the same reason as the
  # directory mode: a filesystem without permission bits cannot be made to express one.
  _mkdir_private "$jd"
  : > "$jd/out.log"; chmod 600 "$jd/out.log" 2>/dev/null || true
  echo running > "$jd/status"
  # Launch the delegate as its OWN process-group leader so a wedged descendant that
  # re-parents to PID 1 when its parent dies can still be reached by `kill -- -PGID`.
  # The ppid tree walk alone misses exactly that case: a grandchild immune to SIGTERM
  # survives the TERM pass, its parent dies on TERM, it re-parents out of the tree, and
  # the KILL pass's re-snapshot never re-discovers it — so it keeps its inherited
  # socket/file and the stall-kill floor never reaps (incident: devin acp held an
  # ESTABLISHED TCP to the model backend 8.7x past the 1800s floor). PGID membership does
  # not change on reparenting, so a negative-PGID kill reaches it wherever it lands.
  # `set -m` makes a backgrounded job a group leader portably — macOS ships no `setsid` —
  # and the prior monitor state is restored so job control never leaks into the caller.
  # Same pattern as _fleet_name_model's bounded helper. The PGID is only acted on by
  # _kill_process_group (via _kill_job), which re-validates it is a real group and NOT
  # this shell's own, and falls back to a tree walk when isolation did not take; a
  # mis-recorded value therefore degrades to the old behaviour instead of mis-killing.
  local _mon=0; case "$-" in *m*) _mon=1 ;; esac
  [ "$_mon" = 1 ] || set -m
  ( exec "$@" </dev/null >> "$jd/out.log" 2>&1 ) &
  local pid=$! _pgid="" _shell_pgid=""
  _pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
  [ "$_mon" = 1 ] || set +m
  case "$_pgid" in ''|*[!0-9]*) _pgid="" ;; esac
  _shell_pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')"
  case "$_shell_pgid" in ''|*[!0-9]*) _shell_pgid="" ;; esac
  # Record the PGID only when it is a genuine isolated group (>1 and not our own), so the
  # file's presence means "kill this group" and a failed isolation leaves it absent and
  # _kill_job falls back to the tree walk instead of signalling the supervisor's group.
  if [ -n "$_pgid" ] && [ "$_pgid" -gt 1 ] 2>/dev/null && [ "$_pgid" != "$_shell_pgid" ]; then
    printf '%s\n' "$_pgid" > "$jd/pgid" 2>/dev/null || true
  fi
  local t0 last_size=0 last_change now size idle age _jcwd="" _idmt=""
  t0=$(date +%s); last_change=$t0
  echo "$pid" > "$jd/pid"
  # Persist the SUPERVISOR's own pid + start-time too. If this watchdog process is killed
  # but the delegate it spawned is orphaned and keeps running, none of the stall/timeout/print-mode
  # guards below can fire — and _status_line's delegate-pid `kill -0` would still report "running".
  # Recording the supervisor pid lets _status_line detect a dead watchdog over a live orphan.
  echo "$$" > "$jd/supervisor_pid"
  # Both start-time files are written under LC_ALL=C in the exact normalized form
  # _pid_start_identity produces, so every reader agrees regardless of the user's locale
  # (ps localizes lstart; a plain-locale write vs a C-locale read never matches). Job dirs
  # written by the previous release (plain-locale records) are still read correctly: the
  # readers go through _pid_start_file_match, which accepts either rendering of the SAME
  # live process.
  LC_ALL=C ps -o lstart= -p "$$" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g' > "$jd/supervisor_pid_start" 2>/dev/null || true
  # Record start time for PID-reuse detection through the one canonical helper (_pid_start_identity).
  # NO epoch fallback (#60): when the read fails the baseline stays UNKNOWN until the first real lstart
  # latches it in the loop below. An epoch placeholder can never equal a real lstart, so the first poll
  # after a transient ps failure would have killed a healthy child as a reused pid. A missing pid_start
  # file reads as "cannot tell" (rc 2) to every other reader, the fail-safe direction.
  local _stime; _stime="$(_pid_start_identity "$pid" 2>/dev/null)" || _stime=""
  [ -n "$_stime" ] && printf '%s\n' "$_stime" > "$jd/pid_start"
  # Signal trap: kill the delegate tree if the supervisor is signaled.
  trap '_kill_job "$jd" "$pid"; echo interrupted > "$jd/status"; printf "interrupted:signal\n" > "$jd/reason" 2>/dev/null || true; exit 130' TERM INT
  # Exploration-spiral guard: a mutating verb that reads/greps forever grows the log, so the
  # byte-growth timer never trips. Track WRITES too. First expose "exploring?" so it can be steered;
  # if it then remains both write-free AND output-silent for another bounded window, stop it as a
  # real stall. An observable warning without a terminal bound left jobs running forever.
  # Prefer the verb passed by run_job via env (always in scope at the call site); fall back to
  # meta.json only if it wasn't. Reading it ONLY from meta.json silently disabled the whole
  # exploring? guard for every mutating verb on a host without jq (or on a failed meta write): no
  # jq -> empty verb -> mutating=0 -> guard off. The env carry makes the watchdog jq-independent.
  local verb="${OSRC_JOB_VERB:-}"
  [ -n "$verb" ] || { [ -f "$jd/meta.json" ] && verb="$(jq -r '.verb // ""' "$jd/meta.json" 2>/dev/null)"; }
  [ -f "$jd/meta.json" ] && _jcwd="$(jq -r '.cwd // ""' "$jd/meta.json" 2>/dev/null)"
  [ -n "$_jcwd" ] || _jcwd="$PWD"
  : > "$jd/.fsmark" 2>/dev/null || true
  # Immutable "job started here" marker. .fsmark is RE-stamped on every sign of life, so it can only
  # answer "wrote something recently"; the exploring? guard needs "wrote anything at all, ever",
  # which requires a marker that is never moved.
  : > "$jd/.startmark" 2>/dev/null || true
  local mutating=0; case "$verb" in edit|research|yolo) mutating=1 ;; esac
  local nww="${OSRC_NOWRITE_WARN:-180}"
  local nww_kill="${OSRC_NOWRITE_KILL:-$nww}"
  # ZERO-WRITE WATCHDOG (progress, not silence). Every timer above measures SILENCE: byte growth,
  # idle, the exploring? kill arm (idle >= nww_kill). A model that streams reasoning tokens for 15
  # minutes while writing nothing keeps the log growing and trips none of them — the incident: a
  # delegate burned its whole output budget twice on pure reasoning with zero files, flagged
  # exploring? at 3 min but never bounded, and was only swapped by hand ~35 min in. This arm tracks
  # the NO-WRITE AGE instead: time since .startmark with still zero qualifying writes while alive.
  #   - past OSRC_NOPROGRESS_SECS (default 600; 0 disables) the job enters the DISTINCT state
  #     `no-progress-writes` — not stalled? (it is talking), not wedged (it is alive) — so status/
  #     heartbeat/the orchestrator see a live-but-unproductive burn and can steer or swap it;
  #   - it is SURFACE-ONLY by default. Only an explicit OSRC_NOPROGRESS_KILL_SECS (unset/0 = off) hard-
  #     bounds it like a stall, and only while still write-free. A legitimately thinking model is
  #     never killed early by default; the goal is to make the zero-write burn visible in ~10 min.
  #   - WRITE-EXPECTING verbs only: edit/yolo (their deliverable IS a file). `run`/`explore` are
  #     read-only and `research` is an output-deliverable verb (the exploring? guard already treats a
  #     write-free research job with fresh output as healthy) — none of them is ever flagged. TEXT-
  #     delegation lanes (local/tokenrouter, see _lane_text_only) never write by design: exempt.
  #   - a qualifying write (same _job_made_writes primitive, structured tool call OR a file newer than
  #     .startmark) clears the state back to running; the check runs each poll only while flagged.
  local nowrite_secs="${OSRC_NOPROGRESS_SECS:-600}" nowrite_kill="${OSRC_NOPROGRESS_KILL_SECS:-0}"
  case "$nowrite_secs" in ''|*[!0-9]*) nowrite_secs=600 ;; esac
  case "$nowrite_kill" in ''|*[!0-9]*) nowrite_kill=0 ;; esac
  # meta.json is the job's own record of its lane, so it wins when it has one; OSRC_JOB_LANE (exported by
  # run_job) is the fallback for hosts without jq or a failed meta write. Preferring the env first would
  # let a stray OSRC_JOB_LANE=dv in the caller's shell give another lane's job the Devin floor.
  local _jlane=""
  [ -f "$jd/meta.json" ] && _jlane="$(jq -r '.lane // ""' "$jd/meta.json" 2>/dev/null)"
  [ -n "$_jlane" ] || _jlane="${OSRC_JOB_LANE:-}"
  local _jmodel=""; [ -f "$jd/meta.json" ] && _jmodel="$(jq -r '.model // ""' "$jd/meta.json" 2>/dev/null)"
  local write_expecting=0; case "$verb" in edit|yolo) write_expecting=1 ;; esac
  _lane_text_only "$_jlane" && write_expecting=0
  [ "$nowrite_secs" -gt 0 ] || write_expecting=0
  # LANE-AWARE NO-WRITE FLOOR (devin, issue #58): the no-write kill's only inputs (out.log growth,
  # _job_made_writes) stay dark during any single long quiet dv command (print mode streams nothing, a
  # test suite's temp files live outside the job cwd), so its small default window pre-empted the
  # widened dv stall window and reaped healthy delegates mid-test-suite. Floor nww_kill up to the
  # stall-kill window, which owns the silence verdict on this lane. WARN/flag clocks are unchanged;
  # a higher user window is never lowered. OSRC_DEVIN_NOWRITE_KILL overrides the floor (0 = off, the
  # pre-fix behaviour); a malformed or oversized value falls back to the stall window rather than silently
  # switching the fix off.
  local _dvfloor="${OSRC_DEVIN_NOWRITE_KILL:-$kill_after}"
  case "$_dvfloor" in ''|*[!0-9]*|??????????*) _dvfloor="$kill_after" ;; esac   # non-numeric or 10+ digits (overflows test's integers): stall window
  if [ "$_jlane" = "dv" ] && [ "$_dvfloor" -gt 0 ] 2>/dev/null && [ "$nww_kill" -lt "$_dvfloor" ]; then nww_kill="$_dvfloor"; fi
  # A live process is not proof that the delegate reached its first model turn. SessionStart hooks
  # and parked cloud lanes can leave the child alive forever with only our disclosure header in the
  # log. Give initialization its own short, lane-agnostic deadline; after any real delegate output,
  # this arm is permanently disarmed and the existing stall/false-stall logic remains authoritative.
  local noinit="${OSRC_NOINIT_SECS:-150}" initialized=0 qt0="$t0" ni0="$t0" ni_start="$t0" ni_cap
  while kill -0 "$pid" 2>/dev/null; do
    # PID-reuse guard: verify the process is still ours.
    local _live_stime; _live_stime="$(_pid_start_identity "$pid" 2>/dev/null || printf '')"
    # Baseline unknown at spawn (#60): latch the first real read and heal pid_start. A pid recycled before
    # the latch is indistinguishable from the child; the stall and hard-timeout arms bound it, late but
    # never falsely.
    [ -n "$_live_stime" ] && [ -z "$_stime" ] && { _stime="$_live_stime"; printf '%s\n' "$_stime" > "$jd/pid_start" 2>/dev/null || true; }
    if [ -n "$_live_stime" ] && [ "$_live_stime" != "$_stime" ]; then
      echo "[outsourcerer] WARN: PID $pid reused by another process, treating job as dead" >&2
      echo interrupted > "$jd/status"; printf 'interrupted:pid-reuse\n' > "$jd/reason" 2>/dev/null || true; echo 130 > "$jd/exit"; return 130
    fi
    sleep "${OSRC_POLL:-10}"
    # The delegate can FINISH during that sleep. The loop condition is only re-tested at the top, so
    # without this the body goes on to judge a process that has already exited — using an `idle`
    # measured against a delegate that is no longer there. A job that went quiet and then completed
    # gets killed post-mortem and reported `wedged` instead of `done`. Break and let the normal
    # `wait` + OSRC:: classification below decide what actually happened.
    kill -0 "$pid" 2>/dev/null || break
    now=$(date +%s)
    size=$(wc -c < "$jd/out.log" 2>/dev/null || echo 0)
    # L7 add-on: per-lane usage cap on every supervise poll. A lane that crosses its cap gets ONE
    # EVENT limit + wrap-up NEXT (deduped per job+spec inside _osrc_cap_poll); the job is never
    # killed for it — "no new work" is enforced by the session-send gate and the pre-launch gate.
    _osrc_cap_poll "$(basename "$jd")" "$_jlane" "$_jmodel"
    if [ "$size" -gt "$last_size" ]; then
      last_size=$size; last_change=$now
      grep -a -E 'OSRC::(PROGRESS|PLAN|BLOCKED|NEED_INPUT|DONE)' "$jd/out.log" 2>/dev/null | tail -1 > "$jd/progress"
      case "$(cat "$jd/status" 2>/dev/null)" in
        stalled?) echo running > "$jd/status" ;;
        # A WRITE clears exploring? for edit/yolo (their deliverable IS a file write, so a write-free
        # spiral must stay flagged). But `research` is a read/tool-exec verb whose deliverable is its
        # OUTPUT, not a file — so for research, fresh output (we are inside the size>last_size branch)
        # is real progress and clears the flag, exactly as a write would. Without this a healthy
        # write-free research job stayed stuck on exploring? and was primed for the kill arm below.
        exploring?) { [ "$verb" = "research" ] || _job_made_writes "$jd" "$_jcwd"; } && echo running > "$jd/status" ;;
        no-progress-writes) _job_made_writes "$jd" "$_jcwd" && echo running > "$jd/status" ;;
      esac
    fi
    # A Devin dispatch queued on the skills-home grant lock (lockwait present) has not started its
    # delegate yet: the soft clocks (no-init, no-write, stall) start once it holds the lock. Honored
    # only before the delegate's first output, so a lockwait file left behind (or written by the
    # delegate itself) cannot disarm a running job; the hard timeout always counts from launch (t0).
    # The queue wait has its own bound (OSRC_DEVIN_LOCK_WAIT_MAX) and its log line names the holder.
    [ "$initialized" = "0" ] && [ -f "$jd/lockwait" ] && { qt0=$now; last_change=$now; ni0=$now; ni_start=$now; }
    idle=$(( now - last_change )); age=$(( now - qt0 ))
    # Require positive proof of a model/agent turn. Byte growth alone includes
    # launcher headers, blank lines, stderr diagnostics, and every tier banner.
    if [ "$initialized" = "0" ] && _delegate_has_model_output "$jd/out.log" "$jd/progress"; then
      initialized=1
    elif [ "$initialized" = "0" ] && [ "${OSRC_DEVIN_LIVENESS:-1}" = "1" ] && _idmt="$(_devin_live_mtime "$pid")" && [ -n "$_idmt" ] && [ "$_idmt" -gt "$ni0" ] && [ "$_idmt" -le "$(date +%s)" ]; then
      # Log activity can extend startup by at most four windows after lock wait.
      ni_cap=$(( ni_start + 4 * noinit ))
      if [ "$_idmt" -gt "$ni_cap" ]; then ni0="$ni_cap"; else ni0="$_idmt"; fi
    fi
    if [ "$initialized" = "0" ] && [ $(( now - ni0 )) -ge "$noinit" ]; then
      local _noinit_reason
      _noinit_reason="no-init: delegate never started within ${noinit}s (likely a hung SessionStart hook cold-start or parked lane) — retry, or run as a session to watch it boot"
      echo wedged > "$jd/status"
      printf '%s\n' "$_noinit_reason" > "$jd/reason" 2>/dev/null || true
      echo "[outsourcerer] job $(basename "$jd"): $_noinit_reason" >&2
      _kill_job "$jd" "$pid"; echo 125 > "$jd/exit"; return 125
    fi
    if [ "$mutating" = "1" ] && [ "$age" -ge "$nww" ] && [ "$(cat "$jd/status" 2>/dev/null)" = "running" ]; then
      _job_made_writes "$jd" "$_jcwd" || {
        echo "exploring?" > "$jd/status"
        echo "[outsourcerer] WARN job $(basename "$jd"): ${age}s on a mutating verb ($verb) with ZERO file writes — likely exploring, not producing. It will be stopped after ${nww_kill}s with no writes and no output growth. Only an actual FILE WRITE clears this (progress output alone does not) — give it a tighter 'write file X now' target, or re-run read-only work under 'run'/'explore', which is not subject to this guard." >&2; }
    fi
    # ZERO-WRITE WATCHDOG arm (see the setup comment above). Order: clear-on-write first, so a job that
    # wrote a file while SILENT (no log growth, so the growth-branch clear above never ran) is not
    # left flagged; then flag; then the opt-in bound. `age` is the no-write age: .startmark is stamped
    # at t0 and a qualifying write is exactly what clears the state, so while flagged the two coincide.
    if [ "$write_expecting" = "1" ] && [ "$(cat "$jd/status" 2>/dev/null)" = "no-progress-writes" ] \
       && _job_made_writes "$jd" "$_jcwd"; then
      echo running > "$jd/status"
      echo "[outsourcerer] job $(basename "$jd"): first file write landed after ${age}s — no-progress-writes cleared." >&2
    fi
    if [ "$write_expecting" = "1" ] && [ "$age" -ge "$nowrite_secs" ]; then
      case "$(cat "$jd/status" 2>/dev/null)" in
        running|exploring?)
          if ! _job_made_writes "$jd" "$_jcwd"; then
            echo "no-progress-writes" > "$jd/status"
            printf '%s\n' "$age" > "$jd/nowrite_age" 2>/dev/null || true
            if [ "$nowrite_kill" -gt 0 ]; then
              echo "[outsourcerer] WARN job $(basename "$jd"): ALIVE and streaming for ${age}s on a write-expecting verb ($verb) with ZERO file writes — a live-but-unproductive burn, not a stall. State: no-progress-writes. It will be stopped at ${nowrite_kill}s if still write-free (OSRC_NOPROGRESS_KILL_SECS). Steer it to a concrete 'write file X now' target, swap the model, or cancel it." >&2
            else
              echo "[outsourcerer] WARN job $(basename "$jd"): ALIVE and streaming for ${age}s on a write-expecting verb ($verb) with ZERO file writes — a live-but-unproductive burn, not a stall. State: no-progress-writes. Not killing it (set OSRC_NOPROGRESS_KILL_SECS to bound this); steer it to a concrete 'write file X now' target, swap the model, or cancel it." >&2
            fi
          fi ;;
      esac
    fi
    if [ "$write_expecting" = "1" ] && [ "$nowrite_kill" -gt 0 ] && [ "$age" -ge "$nowrite_kill" ] \
       && [ "$(cat "$jd/status" 2>/dev/null)" = "no-progress-writes" ] \
       && ! _job_made_writes "$jd" "$_jcwd"; then
      echo wedged > "$jd/status"
      printf 'no-progress-writes-timeout:%ss\n' "$age" > "$jd/reason" 2>/dev/null || true
      echo "[outsourcerer] job $(basename "$jd") stayed alive for ${age}s with ZERO file writes on a write-expecting verb ($verb); stopped at the OSRC_NOPROGRESS_KILL_SECS=${nowrite_kill}s bound. Re-run with a tighter write target or a different model." >&2
      _kill_job "$jd" "$pid"; echo 125 > "$jd/exit"; return 125
    fi
    # Once marked exploring, a fresh output line buys the delegate another exploration window, but
    # neither reading nor an old warning can keep it alive forever. The same content check used for
    # the warning proves it has still made no write before applying the real stall-kill. The same
    # silence bound applies once the job has moved on to no-progress-writes (a superset state: still
    # write-free), so the new state is never LESS bounded than exploring? was.
    # dv: at a tie with the floored window the stall-kill below owns the silence verdict (issue #58).
    if [ "$mutating" = "1" ] && [ "$idle" -ge "$nww_kill" ] && { [ "$_jlane" != "dv" ] || [ "$nww_kill" -lt "$kill_after" ]; } \
       && { [ "$(cat "$jd/status" 2>/dev/null)" = "exploring?" ] || [ "$(cat "$jd/status" 2>/dev/null)" = "no-progress-writes" ]; } \
       && ! _job_made_writes "$jd" "$_jcwd"; then
      echo wedged > "$jd/status"
      printf 'exploring-timeout\n' > "$jd/reason" 2>/dev/null || true
      echo "[outsourcerer] job $(basename "$jd") stayed in exploring? for ${nww_kill}s with ZERO file writes and no output growth; stopped as stalled. Re-run with a tighter write target if more exploration is genuinely needed." >&2
      _kill_job "$jd" "$pid"; echo 125 > "$jd/exit"; return 125
    fi
    # SELF-HEAL backstop (LANE-AGNOSTIC): a mutating job hitting repeated permission/sandbox denials is
    # walled off — headless delegates (claude/codex/devin/local) cannot answer an interactive prompt, so it
    # will spiral forever. Kill it fast with a clear next-step instead. Prevention (mode escalation) handles
    # the known ~/.claude case; this catches any OTHER lane/path that hits the same wall. OSRC_PERM_ABORT=0 disables.
    if [ "$mutating" = "1" ] && [ "${OSRC_PERM_ABORT:-3}" -gt 0 ] && [ "$(cat "$jd/status" 2>/dev/null)" != "permission-blocked" ]; then
      local _pd; _pd="$(_perm_denials "$jd/out.log")"; _pd="${_pd:-0}"
      if [ "$_pd" -ge "${OSRC_PERM_ABORT:-3}" ]; then
        echo "permission-blocked" > "$jd/status"
        printf 'permission-blocked:denials=%s\n' "$_pd" > "$jd/reason" 2>/dev/null || true
        echo "[outsourcerer] ABORT job $(basename "$jd"): $_pd permission/sandbox denials — the delegate is walled off (a protected path or sandbox that can't be auto-approved headless). Re-run with 'yolo' (bypassPermissions), from a different cwd, or with the right sandbox/--add-dir." >&2
        _kill_job "$jd" "$pid"; echo 3 > "$jd/exit"; return 3
      fi
    fi
    # DEVIN PRINT-MODE HANG (LANE-AGNOSTIC, immediate): a headless devin (`-p` / print mode) that
    # attempts a tool exec requiring confirmation cannot prompt, so it rejects the tool and then
    # HANGS — it does not exit, it does not retry, it goes silent. This is a hard wall (not a
    # retry spiral), so a single occurrence is a reliable death signal. Without this check the
    # only backstop is the byte-growth stall-kill (default 900s / 15min for capable tier), which
    # wastes a quarter-hour on a process that is already dead-in-the-water. Abort immediately.
    # Observed in the wild: devin finishes its file writes, hits this on a final validation/commit
    # command, hangs for hours until an external reaper kills the shell with an ambiguous status.
    # OSRC_NO_PRINTMODE_ABORT=1 disables (escape hatch for lanes that recover from print-mode rejects).
    #
    # Match devin's ACTUAL emission of the rejection, not the bare phrase: the phrase can appear in
    # ordinary delegate output (a delegate that reads/echoes source, greps a log, or summarizes an
    # error), and a bare-substring match there would wrongly abort a healthy job. Two anchors keep it
    # specific to a real hang:
    #   1. Require devin's log-module prefix `chisel::repl::handler:` — echoed prose/code never carries it.
    #   2. Scan only the recent TAIL: a genuine print-mode hang emits the line and then goes silent, so
    #      it sits at the end of the log; an incidental mid-run mention is pushed out of the tail.
    #   3. ASSEMBLE the needle at runtime (_printmode_needle) so this file does not contain it. Both
    #      anchors above miss the one source that matters most: this script itself. The literal used
    #      to sit right here, and a delegate that greps or reads outsourcerer.sh in its final actions
    #      would land it in the tail and abort ITSELF instantly — one occurrence, no threshold, at the
    #      end of a run that had already done all its work.
    # If devin's log format ever changes, the check simply no-ops and the 15-min byte-growth stall-kill
    # (still in place) reaps the hang instead — slower, but correct.
    if [ "${OSRC_NO_PRINTMODE_ABORT:-0}" != "1" ] && [ "$(cat "$jd/status" 2>/dev/null)" != "permission-blocked" ]; then
      # Capture the tail before matching: log lines are unbounded, so once the tail outgrows the
      # pipe buffer `tail | grep -q` takes grep's early-exit SIGPIPE (141) under pipefail and a
      # real print-mode hang reads as a miss.
      local _pm_scan; _pm_scan="$(tail -n "${OSRC_PRINTMODE_TAIL:-25}" "$jd/out.log" 2>/dev/null)"
      if grep -aq "$(_printmode_needle)" <<<"$_pm_scan"; then
        echo "permission-blocked" > "$jd/status"
        printf 'permission-blocked:print-mode-hang\n' > "$jd/reason" 2>/dev/null || true
        echo "[outsourcerer] ABORT job $(basename "$jd"): devin print-mode rejected a tool exec that requires confirmation — a headless delegate cannot prompt, so it will hang silently. Re-run with 'yolo' (bypassPermissions), or restructure the prompt so the delegate ends on a file write (move validation/commit/PR creation to the orchestrator)." >&2
        _kill_job "$jd" "$pid"; echo 3 > "$jd/exit"; return 3
      fi
    fi
    if [ $(( now - t0 )) -ge "$hard" ]; then
      echo timeout > "$jd/status"; printf 'hard-timeout:%ss\n' "$hard" > "$jd/reason" 2>/dev/null || true; _kill_job "$jd" "$pid"; echo 124 > "$jd/exit"; return 124
    fi
    # Before declaring a stall, look for progress the LOG cannot show. A delegate that prints nothing
    # while writing files is working, and killing it is the failure this watchdog causes rather than
    # prevents. The log cannot answer this — a silent delegate emits no tool-call markers either — so
    # ask the filesystem. Bounded and only consulted at the moment of judgement, so healthy jobs never
    # pay for it. OSRC_FS_PROGRESS=0 disables.
    #
    # KNOWN LIMITATION (not solved): this check cannot distinguish the delegate's own writes from
    # any other writer's under the same directory. The orchestrator, a concurrent job, an editor
    # autosave, or any process with write access to the cwd can touch a file newer than .fsmark and
    # extend the stall window as if the delegate were working. A previous round attempted to gate
    # this on the delegate's cumulative CPU (`ps -o time=`) to reject foreign writes, but that was
    # withdrawn: it killed healthy delegates on hosts where `ps` is denied (sandbox/container),
    # failed open on exactly those hosts (restoring unlimited foreign-writer liveness), and a
    # coarse whole-second cumulative CPU reading still killed legitimate low-CPU I/O writers. The
    # hard timeout remains the backstop for a truly wedged run that foreign writes keep propping
    # up. A correct fix needs a bounded renewal budget (cap how many times a foreign write can
    # extend the window) plus an activity counter finer than whole-second cumulative CPU. Until
    # then, this check accepts any filesystem change as liveness -- the same behavior it had before
    # the CPU gate was introduced.
    if [ "$idle" -ge "$warn" ] && [ "${OSRC_FS_PROGRESS:-1}" = "1" ] && [ -n "${_jcwd:-}" ] && [ -d "$_jcwd" ]; then
      local _newest
      # `-newer <file>` is POSIX; `-newermt @epoch` is a GNU extension that BSD find silently fails to
      # parse, which would make this check quietly never fire on macOS. Compare against a marker file
      # we re-stamp on every confirmed sign of life instead.
      _newest="$(find "$_jcwd" -maxdepth "${OSRC_FS_PROGRESS_DEPTH:-3}" \
                   \( -name .git -o -name node_modules -o -name .venv -o -name target -o -name dist \) -prune -o \
                   -type f -newer "$jd/.fsmark" -print 2>/dev/null | head -1)"
      if [ -n "$_newest" ]; then
        last_change=$now; idle=0; : > "$jd/.fsmark"
        [ "$(cat "$jd/status" 2>/dev/null)" = "stalled?" ] && echo running > "$jd/status"
      fi
    fi
    # DEVIN-LANE LIVENESS. The check above asks the filesystem "did the delegate write anything?",
    # which answers nothing for READ-ONLY verbs: `explore`/`research` produce no files by design, so
    # the fallback never fires for exactly the jobs most likely to run long and quiet. Combined with
    # devin's non-streaming print mode (see _devin_live_mtime) that left the watchdog with no signal
    # whatsoever on this lane, and it was reaping healthy delegates on a timer — every wedged job in
    # the local history is a devin one, killed within poll slop of the stall window while its own log
    # showed it still reading files. Ask devin's log directly instead. OSRC_DEVIN_LIVENESS=0 disables.
    if [ "$idle" -ge "$warn" ] && [ "${OSRC_DEVIN_LIVENESS:-1}" = "1" ]; then
      local _dmt
      if _dmt="$(_devin_live_mtime "$pid")" && [ -n "$_dmt" ] && [ "$_dmt" -gt "$last_change" ] && [ "$_dmt" -le "$(date +%s)" ]; then
        last_change="$_dmt"; idle=$(( now - last_change ))
        [ "$(cat "$jd/status" 2>/dev/null)" = "stalled?" ] && echo running > "$jd/status"
      fi
    fi
    # PRINT-MODE LIVENESS. Some lanes print nothing until the answer is complete (cursor-agent
    # --output-format text, e.g. a Grok model thinking for minutes), so silence is not a hang
    # (issue #48). A delegate tree still burning CPU is working; a wedged one waiting on a dead
    # socket burns none. The hard cap still bounds a process that spins forever.
    # OSRC_CPU_LIVENESS=0 disables.
    if [ "$idle" -ge "$warn" ] && [ "${OSRC_CPU_LIVENESS:-1}" = "1" ]; then
      local _cpu; _cpu="$(_tree_cpu_centis "$pid")"
      if [ -n "$_cpu" ] && [ -n "${_last_cpu:-}" ] && [ "$_cpu" -gt "$(( _last_cpu + ${OSRC_CPU_LIVENESS_MIN:-5} ))" ]; then
        last_change=$now; idle=0
        [ "$(cat "$jd/status" 2>/dev/null)" = "stalled?" ] && echo running > "$jd/status"
      fi
      [ -n "$_cpu" ] && _last_cpu="$_cpu"
    fi
    if [ "$idle" -ge "$kill_after" ]; then
      # A job that never emitted ANYTHING past the launch banner is a different failure from one that
      # produced work and then went quiet, and it has a different fix. The usual cause is a prompt that
      # told the delegate to stay silent (write to a file, print only at the end) — advice this tool
      # itself gives for output-token exhaustion. Following that advice makes a long job look identical
      # to a hung one, so say which case this is instead of a bare "wedged".
      echo wedged > "$jd/status"
      # "Never spoke" is decided by CONTENT, not by a byte count taken before the child had even
      # written its banner. Our own launcher lines all start with '>>> '; if the log holds nothing
      # else, the delegate contributed nothing and this is the silent-by-instruction case.
      if ! grep -aqv '^>>> ' "$jd/out.log" 2>/dev/null; then
        printf 'silent-delegate\n' > "$jd/reason" 2>/dev/null || true
        echo "[outsourcerer] job $(basename "$jd") produced NO output for ${idle}s and was stopped. It never printed anything past the launch banner, so there was no way to tell work from a hang. If you told the delegate to write to a file and print only at the end, ask it to also emit a periodic 'OSRC::PROGRESS <what it is doing>' line — that is what keeps the watchdog fed. If the work is genuinely long and silent, raise the stall window: OSRC_STALL_KILL=<seconds>." >&2
      else
        # Spoke then went silent: a real stall, not a silent-by-instruction run. Record the cause so
        # `explain`/`status` can show it instead of a bare `wedged` verdict.
        printf 'stall-kill\n' > "$jd/reason" 2>/dev/null || true
      fi
      _kill_job "$jd" "$pid"; echo 125 > "$jd/exit"; return 125
    fi
    if [ "$idle" -ge "$warn" ] && [ "$(cat "$jd/status" 2>/dev/null)" = "running" ]; then
      echo "stalled?" > "$jd/status"
      echo "[outsourcerer] WARN job $(basename "$jd"): no output for ${idle}s (kill at ${kill_after}s)" >&2
    fi
  done
  wait "$pid"; local rc=$?; echo "$rc" > "$jd/exit"
  # `cancel` kills the delegate out of band and writes `canceled` as the authoritative terminal state.
  # When the loop above exits on that kill, don't overwrite it with a post-mortem verdict (`failed`/
  # `done?`) — that would misreport a user cancel as a provider failure in the outcome ledger.
  case "$(cat "$jd/status" 2>/dev/null)" in
    canceled) return "$rc" ;;
  esac
  # A clean process exit is not a successful delegation when it emitted only launcher/disclosure
  # lines. Use the identical content test as the stall path: those lines begin with `>>> ` and do
  # not constitute a delegate result. This must run before marker/exit-code classification so an
  # empty rc=0 cannot masquerade as done? and an empty nonzero cannot hide its actual cause.
  if ! grep -aqv '^>>> ' "$jd/out.log" 2>/dev/null; then
    echo failed > "$jd/status"
    printf 'empty-output\n' > "$jd/reason" 2>/dev/null || true
    echo "[outsourcerer] job $(basename "$jd") exited without any delegate output beyond launcher/disclosure lines; marking it failed (empty-output). Do not treat this as a result." >&2
    [ "$rc" -eq 0 ] && rc=1
    echo "$rc" > "$jd/exit"
    return "$rc"
  fi
  # Classify on the LAST OSRC:: terminal marker, not the FIRST appearance. A delegate that ends with
  # OSRC::DONE is done even if "OSRC::BLOCKED" appeared earlier (e.g. it echoed the protocol
  # instructions, or reconsidered mid-run). Only a final BLOCKED/NEED_INPUT means blocked.
  # ANCHORED to line start. A delegate emits its terminal marker as its own line; the protocol text it
  # was given ("end with OSRC::DONE <summary> or OSRC::BLOCKED <reason>") embeds BOTH markers in one
  # sentence, so a delegate that finishes and then echoes that reminder would be graded on the echo and
  # its completed work reported as blocked. Same class as the print-mode and truncation scans: a
  # signature matched anywhere in a log is one the delegate can forge just by quoting it.
  local last; last="$(_last_marker "$jd/out.log")"
  case "$last" in
    OSRC::BLOCKED|OSRC::NEED_INPUT)
      echo blocked > "$jd/status"
      # Persist the delegate's own blocked/need-input text (the bit after the marker) so a bare
      # `blocked` verdict carries its reason. Bounded + best-effort: fall back to a marker token
      # if no trailing text is extractable. The reason file is private to the job dir (600).
      local _btxt
      _btxt="$(grep -aoE 'OSRC::(BLOCKED|NEED_INPUT)(#[0-9A-Fa-f]+)?[[:space:]].+' "$jd/out.log" 2>/dev/null | tail -1 \
              | sed -E 's/^OSRC::(BLOCKED|NEED_INPUT)(#[0-9A-Fa-f]+)?[[:space:]]*//' | cut -c1-200)"
      [ -n "$_btxt" ] || _btxt='blocked:delegate-marker'
      printf '%s\n' "$_btxt" > "$jd/reason" 2>/dev/null || true
      return 3 ;;
  esac
  # DEVIN NON-INTERACTIVE REJECT (post-exit). A current devin CLI that rejects a tool call needing
  # confirmation prints _noninteractive_reject_needle, ends the session and exits 0, so without this
  # the job reads as `done?` and nothing says the delegate stopped before its remaining steps (usually
  # the verification run). That is the permission-blocked state. Anchoring mirrors the print-mode
  # check: tail only, devin lane only (another lane quoting the line is not devin stopping), exit-0
  # only (a nonzero child keeps its real code on the exit-nonzero path below), and a delegate that
  # went on to sign OSRC::DONE is taken at its word. The lane comes from meta.json when it exists;
  # meta.json is jq-written, so without jq it is absent -- fall back to the provider env run_job
  # exports or the mapping silently never fires.
  local _jlane=""; [ -f "$jd/meta.json" ] && have jq && _jlane="$(jq -r '(.lane // .provider // "")' "$jd/meta.json" 2>/dev/null)"
  _jlane="${_jlane:-${OUTSOURCERER_PROVIDER:-}}"
  # Normalize the lane token before comparing: the env fallback can carry a case/whitespace
  # variant (an inherited OUTSOURCERER_PROVIDER is not guaranteed jq-clean), and a variant that
  # fails the exact match silently disables the mapping on the very job that needs it.
  _jlane="$(printf '%s' "$_jlane" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  local _pm_tail="${OSRC_PRINTMODE_TAIL:-25}"; case "$_pm_tail" in ''|*[!0-9]*) _pm_tail=25 ;; esac
  # Strip ANSI CSI before the fixed-string match: a colorized warning styles `warning:` as its
  # own span (ESC[33m ... ESC[0m), which inserts escape bytes INSIDE the needle and makes a
  # contiguous -F needle miss it entirely -- the blocked run then reads as done?. The same
  # strip the down-evidence sanitizer uses.
  local _esc; _esc="$(printf '\033')"
  # The tail is captured before the -q match: log lines are unbounded, so `tail | sed | grep -q`
  # can SIGPIPE the producers on grep's early exit and pipefail turns a real reject into a miss.
  local _pm_scan; _pm_scan="$(tail -n "$_pm_tail" "$jd/out.log" 2>/dev/null | LC_ALL=C sed -E "s/${_esc}\\[[0-9;]*[A-Za-z]//g")"
  if [ "$rc" -eq 0 ] && [ "$last" != "OSRC::DONE" ] && [ "${OSRC_NO_PRINTMODE_ABORT:-0}" != "1" ] \
     && { [ "$_jlane" = "dv" ] || [ "$_jlane" = "devin" ]; } \
     && grep -aqF "$(_noninteractive_reject_needle)" <<<"$_pm_scan"; then
    echo "permission-blocked" > "$jd/status"
    printf 'permission-blocked:noninteractive-reject\n' > "$jd/reason" 2>/dev/null || true
    echo "[outsourcerer] job $(basename "$jd"): devin rejected a tool call that needs confirmation and ended the run (non-interactive mode). Work before that point may have landed; the step it was attempting did not run. Run that step yourself, re-run with 'yolo', or use 'session' when the delegate must run tests." >&2
    echo 3 > "$jd/exit"
    return 3
  fi
  # Output-token exhaustion is a distinct, recoverable failure, but engines report it as a generic
  # non-zero exit with the partial answer still sitting in the log. Left unnamed it reads as "the run
  # broke"; the operator keeps the truncated output and never learns the result was cut, not wrong.
  # Scanned in the TAIL only: a real cut-off is the LAST thing in the log, whereas prose that merely
  # mentions truncation (a delegate discussing an API response, or reading a log containing the phrase)
  # lands mid-run and gets pushed out. Same anchoring discipline as the print-mode detector.
  # Same capture-then-match: a 15-line tail of long log lines can still exceed the pipe buffer,
  # and `tail | grep -q` would then miss a real token-limit cut via producer SIGPIPE (141).
  if [ "$rc" -ne 0 ] && grep -aqiE 'response truncated|max output token limit|finish_reason.*length' <<<"$(tail -n 15 "$jd/out.log" 2>/dev/null)"; then
    echo failed > "$jd/status"
    printf 'output-token-limit\n' > "$jd/reason" 2>/dev/null || true
    echo "[outsourcerer] job $(basename "$jd") hit the model's OUTPUT-TOKEN limit — the answer in out.log is CUT SHORT, not complete. Do not treat it as the result. Re-run split into smaller batches, or tell the delegate to WRITE ITS FINDINGS TO A FILE and end with a short summary instead of printing everything — in that case also ask it to print a periodic 'OSRC::PROGRESS <step>' line, or a long silent run looks identical to a hang and gets stopped." >&2
    return "$rc"
  fi
  if [ "$rc" -ne 0 ]; then
    echo failed > "$jd/status"
    printf 'exit-nonzero:rc=%s\n' "$rc" > "$jd/reason" 2>/dev/null || true
    return "$rc"
  elif [ "$last" = "OSRC::DONE" ]; then echo done > "$jd/status"; return 0
  else
    echo "done?" > "$jd/status"
    printf 'exited-0-without-OSRC-DONE\n' > "$jd/reason" 2>/dev/null || true
    echo "[outsourcerer] WARN: delegate exited 0 without OSRC::DONE, verify before trusting" >&2
    return 2
  fi
}
