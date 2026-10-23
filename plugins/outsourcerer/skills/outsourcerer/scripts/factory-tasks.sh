# factory-tasks.sh -- Outsourcerer software factory, track B: the durable plan/task graph.
# Sourced by outsourcerer.sh (never run on its own). Defines functions only, no side effects.
#
# State (all under $OSRC_HOME, see ../references/factory-tasks-cli.md):
#   plans/current                 default plan name
#   plans/<plan>/plan.json        {"schema":1,"name","goal","repo","base_branch","created","updated"}
#   plans/<plan>/tasks/<tid>.json one task (tid = t1, t2, ... allocated under the plan lock)
#   plans/<plan>/tasks/<tid>/     brief.md (the exact prompt a worker got), evidence.json, report.md
#   plans/<plan>/events.jsonl     append-only {"ts","plan","task","event","from","to","note"}
#   plans/<plan>/.lock/           mkdir lock (owner = "pid start-identity"), stale holders reclaimed
#
# Library API (tracks C and D call these by name):
#   _plan_dir <plan>                     -> prints the plan directory path
#   _plan_resolve [plan]                 -> prints the plan name (arg, else current); dies if none
#   _task_get <plan> <tid>               -> prints task JSON; rc1 if missing or damaged
#   _task_update <plan> <tid> <jq-filter> [jq args...]
#                                        -> atomic under the plan lock, bumps .updated, logs a
#                                           state event when .state changes (note: FACTORY_EVENT_NOTE)
#   _task_list <plan>                    -> JSON array of tasks (id order); damaged files skipped
#   _task_view <plan>                    -> like _task_list, plus .derived (ready|blocked|<state>),
#                                           .blocked_by [{id,state}] and .depth
#   _task_ready <plan>                   -> newline list of ready tids (dependency order, then id)
#   _task_brief <plan> <tid>             -> writes tasks/<tid>/brief.md, prints its path
#   _task_dispatch <plan> <tid>          -> claim todo->running, brief, launch through bg; prints job id
#   _task_event <plan> <tid> <event> [note]
#   _task_new <plan> <task-json-fields>  -> allocates a tid under the lock, writes the task, prints tid

# ---------------------------------------------------------------- basics

# Native Windows jq emits CRLF. Preserve jq's exit status as well as normalized text.
_ft_jq() {
  jq "$@" | tr -d '\r'
  return "${PIPESTATUS[0]}"
}

_factory_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_factory_need_jq() {
  have jq || die "the plan and task commands need jq. Install it (brew install jq, apt install jq, or winget install jqlang.jq) and try again."
}

# _factory_optval <option> <args-left> -> die plainly when an option that takes a value is the last
# argument. Every option parser calls this before `shift 2`: bash refuses `shift 2` with one argument
# left and, without set -e, the parse loop would spin forever on the same option.
_factory_optval() {
  [ "${2:-0}" -ge 2 ] 2>/dev/null || die "$1 needs a value after it (for example: $1 \"...\")."
}

_plans_root() { printf '%s/plans' "$OSRC_HOME"; }

_plan_name_ok() {
  case "${1:-}" in
    ''|current|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

_task_id_ok() {
  case "${1:-}" in t[1-9]*) ;; *) return 1 ;; esac
  case "${1#t}" in *[!0-9]*) return 1 ;; esac
  return 0
}

_plan_dir() { printf '%s/%s' "$(_plans_root)" "$1"; }

_plan_current() {
  local c=""
  [ -f "$(_plans_root)/current" ] && c="$(head -n 1 "$(_plans_root)/current" 2>/dev/null | tr -d '\r\n')"
  _plan_name_ok "$c" || return 1
  printf '%s' "$c"
}

# _plan_resolve [plan] -> the plan name to use: the argument, else the current plan. Dies with a
# next step when neither names an existing plan.
_plan_resolve() {
  local p="${1:-}"
  if [ -z "$p" ]; then
    p="$(_plan_current)" || die "no plan selected. Make one with: outsourcerer plan new <name> --goal \"...\" (or pass --plan <name>)."
  fi
  _plan_name_ok "$p" || die "'$p' is not a valid plan name (letters, digits, dot, dash, underscore; up to 64)."
  [ -f "$(_plan_dir "$p")/plan.json" ] || die "there is no plan named '$p'. See your plans with: outsourcerer plan ls"
  printf '%s' "$p"
}

# _factory_write_json <path> <json> -> validate, then write via tmp + mv (atomic on one filesystem).
_factory_write_json() {
  local path="$1" json="$2" tmp
  printf '%s' "$json" | _ft_jq -e . >/dev/null 2>&1 || { echo "outsourcerer: refusing to write broken JSON to $path" >&2; return 1; }
  tmp="$path.tmp.$$.${RANDOM:-0}"
  ( umask 077; printf '%s\n' "$json" > "$tmp" ) 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# _factory_write_file <path> < stdin -> same atomic pattern for text (brief.md, report.md).
_factory_write_file() {
  local path="$1" tmp
  tmp="$path.tmp.$$.${RANDOM:-0}"
  ( umask 077; cat > "$tmp" ) 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# ---------------------------------------------------------------- the plan lock
# mkdir is the portable atomic (no flock on stock macOS). The owner file records "pid start-identity"
# so a waiter can prove the holder died and reclaim, the same pattern as _state_lock_acquire and the
# land queue lock. A LIVE holder is never robbed, however long it holds: the only escape hatches are a
# provably dead (or recycled) owner pid, and an ownerless lock older than 30s (holder killed between
# mkdir and publishing). The owner pid is the holder's REAL pid even inside a subshell on bash 3.2
# (no BASHPID there), so a subshell that dies holding the lock is reclaimable while its parent lives.
# The lock is re-entrant within one process tree (a nested call made while we hold it, including
# from a command substitution, proceeds).
_FACTORY_LOCK_PLAN=""
_FACTORY_LOCK_DEPTH=0
_FACTORY_LOCK_OWNER=""

# _factory_self_pid [scratch-dir] -> sets _FACTORY_SELF_PID to this process's own pid, also inside a
# subshell on bash 3.2 (no BASHPID there, and $$ is the PARENT's pid). `sh -c 'echo $PPID'` run as a
# plain command is forked by THIS shell, so its parent is us. It sets a variable instead of printing
# because a $(...) around it would itself be the forking subshell and report the wrong pid.
_FACTORY_SELF_PID=""
_factory_self_pid() {
  if [ -n "${BASHPID:-}" ]; then _FACTORY_SELF_PID="$BASHPID"; return 0; fi
  local d="${1:-$OSRC_HOME}" f p=""
  f="$d/.selfpid.$$.${RANDOM:-0}"
  sh -c 'echo $PPID' > "$f" 2>/dev/null && { read -r p < "$f"; } 2>/dev/null
  rm -f "$f" 2>/dev/null
  case "$p" in ''|*[!0-9]*) p="$$" ;; esac
  _FACTORY_SELF_PID="$p"
}

# _factory_owner_dead <pid> <start-identity> -> rc0 only when the owner is PROVABLY gone (ps works and
# the pid is absent, or the pid now belongs to a process with a different start time).
_factory_owner_dead() {
  local o_pid="$1" o_start="$2" cur probe _rc=0
  case "$o_pid" in ''|*[!0-9]*) return 1 ;; esac
  cur="$(_pid_start_identity "$o_pid" 2>/dev/null)" || _rc=$?
  [ "$_rc" -eq 2 ] && return 0
  [ "$_rc" -eq 0 ] && [ -n "$o_start" ] && [ "$cur" != "$o_start" ] && return 0
  # A denied signal is not proof of death. Only an explicit ESRCH diagnostic is.
  if [ "$_rc" -eq 1 ]; then
    probe="$(LC_ALL=C kill -0 "$o_pid" 2>&1)" || {
      case "$probe" in *"No such process"*) return 0 ;; esac
    }
  fi
  return 1
}

# _factory_lock_break <lock> <observed-owner-line|""> <me> -> remove a stale lock, but only if it is
# still the exact lock we judged. Breakers serialize on a steal guard ($lock.steal, itself a mkdir
# lock): inside it the owner is re-read, and the lock is moved aside only if unchanged (an ownerless
# lock: only if still ownerless). Without the guard, two waiters that both judged the same dead owner
# could each break in turn, and the second would delete the FIRST one's freshly acquired live lock.
# The moved corpse is re-read once more; if it is not the stale record, it goes back.
_factory_lock_break() {
  local lock="$1" seen="$2" me="$3" now_line="" corpse_line="" corpse guard gage rc=1
  guard="$lock.steal"
  if ! _mkdir_claim "$guard"; then
    # A breaker killed inside the guard would wedge every later break: the guard is held for
    # milliseconds, so one older than 30s is abandoned.
    gage="$(_mtime "$guard" 2>/dev/null || echo 0)"; case "$gage" in ''|*[!0-9]*) gage=0 ;; esac
    if [ "$gage" -gt 0 ] && [ $(( $(date +%s) - gage )) -ge 30 ]; then rmdir "$guard" 2>/dev/null || rm -rf "$guard" 2>/dev/null; fi
    return 1
  fi
  if [ -d "$lock" ]; then
    { IFS= read -r now_line < "$lock/owner"; } 2>/dev/null || now_line=""
    if [ "$now_line" = "$seen" ] && { [ -n "$seen" ] || [ ! -f "$lock/owner" ]; }; then
      corpse="$lock.stale.$me.${RANDOM:-0}"
      if mv "$lock" "$corpse" 2>/dev/null; then
        { IFS= read -r corpse_line < "$corpse/owner"; } 2>/dev/null || corpse_line=""
        if [ "$corpse_line" = "$seen" ]; then
          rm -rf "$corpse" 2>/dev/null; rc=0
        else
          [ -e "$lock" ] || mv "$corpse" "$lock" 2>/dev/null
        fi
      fi
    fi
  fi
  rmdir "$guard" 2>/dev/null || true
  return "$rc"
}

_plan_lock() {
  local plan="$1" lock owner tries=0 o_pid o_start o_line age me
  if [ "$_FACTORY_LOCK_PLAN" = "$plan" ] && [ "$_FACTORY_LOCK_DEPTH" -gt 0 ]; then
    _FACTORY_LOCK_DEPTH=$((_FACTORY_LOCK_DEPTH + 1)); return 0
  fi
  lock="$(_plan_dir "$plan")/.lock"; owner="$lock/owner"
  me=""
  while [ "$tries" -lt "${OSRC_PLAN_LOCK_TRIES:-150}" ]; do
    if _mkdir_claim "$lock"; then
      [ -n "$me" ] || { _factory_self_pid "$lock"; me="$_FACTORY_SELF_PID"; }
      _FACTORY_LOCK_OWNER="$me $(_pid_start_identity "$me" 2>/dev/null)"
      if ! { printf '%s\n' "$_FACTORY_LOCK_OWNER" > "$lock/owner.$me" 2>/dev/null \
        && mv -f "$lock/owner.$me" "$owner" 2>/dev/null; }; then
        rm -f "$lock/owner.$me" 2>/dev/null
        rmdir "$lock" 2>/dev/null || true
        _FACTORY_LOCK_OWNER=""
        echo "outsourcerer: could not publish the owner of plan '$plan'." >&2
        return 1
      fi
      _FACTORY_LOCK_PLAN="$plan"; _FACTORY_LOCK_DEPTH=1
      return 0
    fi
    if [ -f "$owner" ]; then
      o_line=""; { IFS= read -r o_line < "$owner"; } 2>/dev/null || o_line=""
      o_pid="${o_line%% *}"; o_start=""; case "$o_line" in *" "*) o_start="${o_line#* }" ;; esac
      if [ -n "$o_line" ] && _factory_owner_dead "$o_pid" "$o_start"; then
        [ -n "$me" ] || me="${BASHPID:-$$}"
        _factory_lock_break "$lock" "$o_line" "$me" && continue
      fi
    else
      age="$(_mtime "$lock" 2>/dev/null || echo 0)"; case "$age" in ''|*[!0-9]*) age=0 ;; esac
      if [ "$age" -gt 0 ] && [ $(( $(date +%s) - age )) -ge 30 ]; then
        [ -n "$me" ] || me="${BASHPID:-$$}"
        _factory_lock_break "$lock" "" "$me" && continue
      fi
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  echo "outsourcerer: plan '$plan' is busy (another command holds its lock). Try again in a moment." >&2
  return 1
}

_plan_unlock() {
  local plan="$1" lock cur=""
  [ "$_FACTORY_LOCK_PLAN" = "$plan" ] || return 0
  _FACTORY_LOCK_DEPTH=$((_FACTORY_LOCK_DEPTH - 1))
  [ "$_FACTORY_LOCK_DEPTH" -gt 0 ] && return 0
  lock="$(_plan_dir "$plan")/.lock"
  # Only remove the lock if it is still ours: if a waiter wrongly broke it and someone else now holds
  # the path, removing it would let a third writer in. No owner record at all means our own publish
  # failed (disk full), so the lock is still ours to remove.
  { IFS= read -r cur < "$lock/owner"; } 2>/dev/null || cur=""
  if [ -z "$_FACTORY_LOCK_OWNER" ] || [ -z "$cur" ] || [ "$cur" = "$_FACTORY_LOCK_OWNER" ]; then
    rm -f "$lock/owner" "$lock"/owner.* 2>/dev/null
    rmdir "$lock" 2>/dev/null || true
  fi
  _FACTORY_LOCK_PLAN=""; _FACTORY_LOCK_DEPTH=0; _FACTORY_LOCK_OWNER=""
}

# ---------------------------------------------------------------- events + wake

# _task_event_full <plan> <tid> <event> <from> <to> <note> -> one line in events.jsonl. A single
# O_APPEND write of one short line, so it is safe with or without the plan lock held.
_task_event_full() {
  local plan="$1" tid="$2" ev="$3" from="${4:-}" to="${5:-}" note="${6:-}" line
  line="$(_ft_jq -cn --arg ts "$(_factory_now)" --arg plan "$plan" --arg task "$tid" --arg event "$ev" \
           --arg from "$from" --arg to "$to" --arg note "$note" \
           '{ts:$ts,plan:$plan,task:$task,event:$event,from:$from,to:$to,note:($note|.[0:2000])}')" || return 1
  printf '%s\n' "$line" >> "$(_plan_dir "$plan")/events.jsonl" 2>/dev/null
}

# _task_event <plan> <tid> <event> [note]
_task_event() { _task_event_full "$1" "$2" "$3" "" "" "${4:-}"; }

# _factory_wake <plan> <tid> <state> <summary> -> push a held/failed task to the heartbeat wake
# queue so a headless orchestrator hears about it. Best-effort: never fails the caller.
_factory_wake() {
  type _wake_append >/dev/null 2>&1 || return 0
  local plan="$1" tid="$2" st="$3" summary="$4" eid
  eid="factory.$plan.$tid.$st.$(date +%s).${RANDOM:-0}"
  _wake_append "$(_ft_jq -cn --arg event_id "$eid" --arg plan "$plan" --arg task "$tid" --arg st "$st" --arg s "$summary" \
    '{event_id:$event_id,kind:"factory-task",plan:$plan,task:$task,state:"blocked",task_state:$st,task_summary:($s|.[0:200])}')" \
    >/dev/null 2>&1 || true
  return 0
}

# ---------------------------------------------------------------- task store

_task_file() { printf '%s/tasks/%s.json' "$(_plan_dir "$1")" "$2"; }
_task_dir()  { printf '%s/tasks/%s' "$(_plan_dir "$1")" "$2"; }

# _task_get <plan> <tid> -> task JSON on stdout; rc1 (with one plain line on stderr) when the task
# does not exist or its file is damaged.
_task_get() {
  local plan="$1" tid="$2" f out
  _task_id_ok "$tid" || { echo "outsourcerer: '$tid' is not a task id (they look like t1, t2, ...)." >&2; return 1; }
  f="$(_task_file "$plan" "$tid")"
  [ -f "$f" ] || { echo "outsourcerer: plan '$plan' has no task $tid. See its tasks with: outsourcerer task ls --plan $plan" >&2; return 1; }
  out="$(_ft_jq -ce 'if type == "object" and (.id|type) == "string" then . else error("bad") end' "$f" 2>/dev/null)" \
    || { echo "outsourcerer: task file $f is damaged (not valid task JSON). Fix it by hand or remove it." >&2; return 1; }
  printf '%s\n' "$out"
}

# _task_list <plan> -> JSON array of every readable task, sorted by numeric id. A damaged file is
# skipped with a warning instead of hiding every other task.
_task_list() {
  local plan="$1" f td
  td="$(_plan_dir "$plan")/tasks"
  {
    for f in "$td"/t*.json; do
      [ -f "$f" ] || continue
      _ft_jq -ce 'if type == "object" and (.id|type) == "string" then . else error("bad") end' "$f" 2>/dev/null \
        || echo "outsourcerer: skipping damaged task file $f" >&2
    done
  } | _ft_jq -cs 'sort_by(.id | ltrimstr("t") | tonumber? // 0)'
}

# Shared jq: derive ready/blocked + dependency depth from the stored states (never stored).
_FACTORY_JQ_VIEW='
def idn: (.id | ltrimstr("t") | tonumber? // 0);
def view:
  . as $all
  | (reduce $all[] as $t ({}; .[$t.id] = $t)) as $by
  | (reduce ($all | sort_by(idn))[] as $t ({};
        .[$t.id] = (if (($t.deps // []) | length) == 0 then 0
                    else 1 + ([ ($t.deps // [])[] as $d | (.[$d] // 0) ] | max) end))) as $depth
  | map(. as $t
      | ([ ($t.deps // [])[] as $d | {id: $d, state: ($by[$d].state // "missing")} | select(.state != "done") ]) as $bl
      | . + {depth: ($depth[$t.id] // 0), blocked_by: $bl,
             derived: (if $t.state == "todo" then (if ($bl | length) == 0 then "ready" else "blocked" end)
                       else $t.state end)});
'

_task_view() { _task_list "$1" | _ft_jq -c "$_FACTORY_JQ_VIEW view"; }

# _task_ready <plan> -> ready tids, one per line: shallower dependency depth first, then id.
_task_ready() {
  _task_list "$1" | _ft_jq -r "$_FACTORY_JQ_VIEW view | map(select(.derived == \"ready\")) | sort_by([.depth, idn]) | .[].id"
}

# _task_update_locked <plan> <tid> <filter> [jq args...] -> the write half of _task_update. Caller
# holds the plan lock. Sets _FACTORY_LAST_FROM/_FACTORY_LAST_TO for the caller's wake decision.
_FACTORY_LAST_FROM=""; _FACTORY_LAST_TO=""
_task_update_locked() {
  local plan="$1" tid="$2" filter="$3" cur new from to now f
  shift 3
  _FACTORY_LAST_FROM=""; _FACTORY_LAST_TO=""
  cur="$(_task_get "$plan" "$tid")" || return 1
  now="$(_factory_now)"
  new="$(printf '%s' "$cur" | _ft_jq -ce --arg __now "$now" "$@" "($filter) | if .state != \"verifying\" then del(.verifying_pid, .verifying_start, .verifying_at) else . end | .updated = \$__now" 2>/dev/null)" || {
    echo "outsourcerer: could not update $plan/$tid (the change did not apply to this task as it stands)." >&2; return 1; }
  f="$(_task_file "$plan" "$tid")"
  _factory_write_json "$f" "$new" || { echo "outsourcerer: could not save $f" >&2; return 1; }
  from="$(printf '%s' "$cur" | _ft_jq -r '.state // ""')"; to="$(printf '%s' "$new" | _ft_jq -r '.state // ""')"
  if [ "$from" != "$to" ]; then
    _task_event_full "$plan" "$tid" state "$from" "$to" "${FACTORY_EVENT_NOTE:-}" || true
    _FACTORY_LAST_FROM="$from"; _FACTORY_LAST_TO="$to"
  fi
  return 0
}

# _task_wake_if_needed <plan> <tid> -> after an update: a task that just became held or failed
# needs the captain, so tell the heartbeat. Called OUTSIDE the plan lock.
_task_wake_if_needed() {
  local plan="$1" tid="$2" t title why
  case "$_FACTORY_LAST_TO" in held|failed) ;; *) return 0 ;; esac
  t="$(_task_get "$plan" "$tid" 2>/dev/null)" || return 0
  title="$(printf '%s' "$t" | _ft_jq -r '.title // ""')"
  if [ "$_FACTORY_LAST_TO" = held ]; then why="$(printf '%s' "$t" | _ft_jq -r '.hold.reason // ""')"
  else why="$(printf '%s' "$t" | _ft_jq -r '.result // ""')"; fi
  _factory_wake "$plan" "$tid" "$_FACTORY_LAST_TO" "plan $plan task $tid $_FACTORY_LAST_TO: $title${why:+ ($why)}"
}

# _task_update <plan> <tid> <jq-filter> [--arg k v | --argjson k v ...]
# Applies the filter to the task atomically under the plan lock and bumps .updated. A filter that
# errors (for example `if .state != "todo" then error("no") else ... end`) changes nothing and
# returns 1, which makes guarded transitions race-free. A .state change appends a "state" event
# (note from FACTORY_EVENT_NOTE) and, for held/failed, a wake event.
_task_update() {
  local plan="$1" tid="$2" rc=0
  _plan_lock "$plan" || return 1
  _task_update_locked "$@" || rc=1
  _plan_unlock "$plan"
  [ "$rc" -eq 0 ] && _task_wake_if_needed "$plan" "$tid"
  return "$rc"
}

# Fields a caller of _task_new may not set: identity, bookkeeping the dispatcher and done contract own,
# and landing records. They are reset to their defaults whatever the caller passed.
_FACTORY_TASK_PROTECTED='["schema","id","plan","attempts","job","jobs","worktree","branch","base_sha","head_sha","evidence","created","updated","landed","landed_into","landed_sha","pr","claimed_at","claimed_by","launch_failed"]'

# _task_new <plan> <json-object> -> allocate the next tid under the lock, merge the fields over the
# defaults, validate deps exist, write the task, print the tid. Deps can only name tasks that already
# exist, so the graph is acyclic by construction. Protected fields (see above) are ignored; a new task
# starts todo, or held when the caller asks for a decision up front (state "held").
_task_new() {
  local plan="$1" fields="$2" n max=0 f tid now task missing d bad="" st
  fields="$(printf '%s' "$fields" | _ft_jq -c 'if type == "object" then . else error("not an object") end' 2>/dev/null)" \
    || { echo "outsourcerer: a new task must be described by a JSON object." >&2; return 1; }
  st="$(printf '%s' "$fields" | _ft_jq -r '.state // "todo"')"
  case "$st" in todo|held) ;; *) echo "outsourcerer: a new task starts as todo or held, not '$st'." >&2; return 1 ;; esac
  printf '%s' "$fields" | _ft_jq -e '(.deps // []) | type == "array" and all(.[]; type == "string")' >/dev/null 2>&1 \
    || { echo "outsourcerer: a task's deps must be a list of task ids (t1, t2, ...)." >&2; return 1; }
  for d in $(printf '%s' "$fields" | _ft_jq -r '(.deps // [])[]'); do
    _task_id_ok "$d" || bad="$bad $d"
  done
  [ -z "$bad" ] || { echo "outsourcerer: '${bad# }' is not a task id (they look like t1, t2, ...)." >&2; return 1; }
  _plan_lock "$plan" || return 1
  for f in "$(_plan_dir "$plan")"/tasks/t*.json "$(_plan_dir "$plan")"/tasks/t*; do
    [ -e "$f" ] || continue
    n="${f##*/}"; n="${n%.json}"; n="${n#t}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -gt "$max" ] && max="$n"
  done
  tid="t$((max + 1))"
  missing=""
  for d in $(printf '%s' "$fields" | _ft_jq -r '(.deps // [])[]'); do
    [ -f "$(_task_file "$plan" "$d")" ] || missing="$missing$d "
  done
  if [ -n "$missing" ]; then
    _plan_unlock "$plan"
    echo "outsourcerer: the dependency ${missing% } does not exist in plan '$plan'. Add that task first (see: outsourcerer task ls)." >&2
    return 1
  fi
  now="$(_factory_now)"
  task="$(printf '%s' "$fields" | _ft_jq -c --arg id "$tid" --arg plan "$plan" --arg now "$now" --argjson prot "$_FACTORY_TASK_PROTECTED" '
    . as $f | {schema:1,id:$id,plan:$plan,title:"",shape:"scout",state:"todo",deps:[],prompt:"",spec:"",check:"",
     verb:"",model:"",provider:"",deliver:"local",retries:1,attempts:0,job:"",jobs:[],
     worktree:"",branch:"",base_sha:"",head_sha:"",hold:{reason:"",until:"",answer:""},
     result:"",evidence:"",flow:{name:"",stage:""},created:$now,updated:$now}
    * ($f | delpaths([$prot[] | [.]])) | .id = $id | .plan = $plan
    | if .verb == "" then .verb = (if .shape == "ship" then "edit" else "run" end) else . end
    | if .prompt == "" then .prompt = .title else . end')" || { _plan_unlock "$plan"; return 1; }
  mkdir -p "$(_task_dir "$plan" "$tid")" 2>/dev/null
  if ! _factory_write_json "$(_task_file "$plan" "$tid")" "$task"; then
    _plan_unlock "$plan"; return 1
  fi
  _task_event_full "$plan" "$tid" created "" "$(printf '%s' "$task" | _ft_jq -r .state)" "$(printf '%s' "$task" | _ft_jq -r .title)" || true
  _plan_unlock "$plan"
  printf '%s\n' "$tid"
}

# ---------------------------------------------------------------- context handoff

# _factory_trim <max-chars> < text -> text capped at max chars (by character, not byte, so UTF-8
# never splits), with a visible marker when cut.
_factory_trim() {
  _ft_jq -Rrs --argjson n "$1" --arg w "${2:-at the path below}" 'if length > $n then .[0:$n] + "\n[... trimmed; the full text is \($w)]" else . end'
}

# _task_output_path <plan> <task-json> -> the best full-output file for a task: its report.md, else
# its job's last.txt. Empty when there is none.
_task_output_path() {
  local plan="$1" t="$2" tid job p
  tid="$(printf '%s' "$t" | _ft_jq -r .id)"; job="$(printf '%s' "$t" | _ft_jq -r '.job // ""')"
  p="$(_task_dir "$plan" "$tid")/report.md"
  [ -s "$p" ] && { printf '%s' "$p"; return 0; }
  if [ -n "$job" ] && [ -s "$OSRC_JOBS/$job/last.txt" ]; then printf '%s' "$OSRC_JOBS/$job/last.txt"; return 0; fi
  return 1
}

# _task_brief <plan> <tid> -> write tasks/<tid>/brief.md and print its path. This is the ONLY context
# a worker gets beyond the repo, so it carries: the plan goal, the task, the spec, the done rules,
# every direct dependency's result (bounded, with the path to the full text), and the captain's
# decisions. Complete but bounded, so a brief never balloons whatever the inputs hold: spec inline up
# to 64KB (else linked), the prompt 32KB, the goal 2KB, each dependency's summary 2KB and output 4KB,
# each captain answer 4KB, and at most OSRC_BRIEF_MAX_DEPS (12) dependency sections; the rest are
# listed by id with where their reports live. Every cut says where the full text is.
_FACTORY_BRIEF_MAX_DEPS_DEFAULT=12
_task_brief() {
  local plan="$1" tid="$2" t pj goal repo base title shape prompt spec check deps d dt dshape dtitle
  local dres out_path out_txt dbr dhead djob ans dans ddir brief attempts prev reason until sz
  local maxdeps ndeps shown more tdir_all
  t="$(_task_get "$plan" "$tid")" || return 1
  pj="$(_ft_jq -c . "$(_plan_dir "$plan")/plan.json" 2>/dev/null)" || pj='{}'
  goal="$(printf '%s' "$pj" | _ft_jq -r '.goal // ""' | _factory_trim 2000 "in $(_plan_dir "$plan")/plan.json")"
  repo="$(printf '%s' "$pj" | _ft_jq -r '.repo // ""')"
  base="$(printf '%s' "$pj" | _ft_jq -r '.base_branch // ""')"
  title="$(printf '%s' "$t" | _ft_jq -r '.title // "" | .[0:300]')"
  shape="$(printf '%s' "$t" | _ft_jq -r '.shape // "scout"')"
  prompt="$(printf '%s' "$t" | _ft_jq -r '.prompt // ""' | _factory_trim 32000 "in $(_task_file "$plan" "$tid") (field prompt)")"
  spec="$(printf '%s' "$t" | _ft_jq -r '.spec // ""')"
  check="$(printf '%s' "$t" | _ft_jq -r '.check // ""')"
  attempts="$(printf '%s' "$t" | _ft_jq -r '.attempts // 0')"
  prev="$(printf '%s' "$t" | _ft_jq -r '.result // ""' | _factory_trim 2000 "in $(_task_file "$plan" "$tid") (field result)")"
  ans="$(printf '%s' "$t" | _ft_jq -r '.hold.answer // ""' | _factory_trim 4000 "in $(_task_file "$plan" "$tid") (field hold.answer)")"
  reason="$(printf '%s' "$t" | _ft_jq -r '.hold.reason // ""' | _factory_trim 2000 "in $(_task_file "$plan" "$tid") (field hold.reason)")"
  maxdeps="${OSRC_BRIEF_MAX_DEPS:-$_FACTORY_BRIEF_MAX_DEPS_DEFAULT}"; case "$maxdeps" in ''|*[!0-9]*) maxdeps=$_FACTORY_BRIEF_MAX_DEPS_DEFAULT ;; esac
  tdir_all="$(_plan_dir "$plan")/tasks"
  ddir="$(_task_dir "$plan" "$tid")"; mkdir -p "$ddir" 2>/dev/null
  brief="$ddir/brief.md"
  {
    printf '# Task %s/%s: %s\n\n' "$plan" "$tid" "$title"
    [ -n "$goal" ] && printf 'Plan goal: %s\n' "$goal"
    if [ -n "$repo" ]; then
      printf 'Repository: %s%s\n' "$repo" "${base:+ (base branch: $base)}"
    fi
    printf 'Task type: %s\n\n' "$( [ "$shape" = ship ] && echo 'ship (you change code and commit it)' || echo 'scout (you investigate and write up; you change nothing)')"
    printf '## Your task\n\n%s\n\n' "$prompt"

    if [ -n "$spec" ]; then
      printf '## Spec\n\n'
      if [ -f "$spec" ]; then
        sz="$(wc -c < "$spec" 2>/dev/null | tr -d ' ')"; case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
        if [ "$sz" -gt 65536 ]; then
          printf 'The spec is large (%s bytes), so it is not pasted here. Read it in full before you start: %s\n\n' "$sz" "$spec"
        else
          printf '(from %s)\n\n' "$spec"; cat "$spec"; printf '\n\n'
        fi
      else
        printf 'A spec was named but is missing at %s. Say so in your result rather than guessing what it contained.\n\n' "$spec"
      fi
    fi

    printf '## Done when\n\n'
    if [ "$shape" = ship ]; then
      printf -- '- You are in an isolated git worktree made for this task, on its own branch. Commit your finished work on that branch.\n'
      printf -- '- Leave no uncommitted changes to tracked files. Do not push, merge, rebase onto other branches, or open a pull request.\n'
      printf -- '- Never commit secrets (keys, tokens, .env files). A secret in the diff blocks the task.\n'
    else
      printf -- '- Do not change any files. Your final message IS the deliverable.\n'
      printf -- '- Make it complete and self-contained: the next workers see only what you write, not your session.\n'
    fi
    [ -n "$check" ] && printf -- '- This check must pass (exit code 0) from the top of the repository: `%s`\n' "$check"
    printf -- '- End with a short summary: what you did, what you found or changed, anything left open. It is handed to the tasks that depend on this one.\n\n'

    deps="$(printf '%s' "$t" | _ft_jq -r '(.deps // [])[]')"
    if [ -n "$deps" ]; then
      printf '## Inputs from finished work\n\n'
      printf 'These tasks finished before yours and feed into it. Build on them; do not redo them.\n\n'
      ndeps="$(printf '%s\n' "$deps" | grep -c .)"; shown=0
      for d in $deps; do
        if [ "$shown" -ge "$maxdeps" ]; then
          more=$((ndeps - shown))
          printf '### %s more finished input(s) not shown here\n\n' "$more"
          printf 'They are: %s. Read each one'"'"'s full report at %s/<id>/report.md (or its brief.md for what it was asked).\n\n' \
            "$(printf '%s\n' "$deps" | sed -n "$((shown + 1)),\$p" | head -n 50 | tr '\n' ' ' | sed 's/ $//;s/ /, /g')$( [ "$more" -gt 50 ] && echo ', ...')" "$tdir_all"
          break
        fi
        shown=$((shown + 1))
        dt="$(_task_get "$plan" "$d" 2>/dev/null)" || { printf '### %s (missing)\nThis dependency could not be read.\n\n' "$d"; continue; }
        dtitle="$(printf '%s' "$dt" | _ft_jq -r '.title // "" | .[0:300]')"
        dshape="$(printf '%s' "$dt" | _ft_jq -r '.shape // "scout"')"
        dres="$(printf '%s' "$dt" | _ft_jq -r '.result // ""' | _factory_trim 2000 "in $(_task_file "$plan" "$d") (field result)")"
        dbr="$(printf '%s' "$dt" | _ft_jq -r '.branch // ""')"
        dhead="$(printf '%s' "$dt" | _ft_jq -r '.head_sha // ""')"
        djob="$(printf '%s' "$dt" | _ft_jq -r '.job // ""')"
        printf '### %s: %s (%s, %s)\n\n' "$d" "$dtitle" "$dshape" "$(printf '%s' "$dt" | _ft_jq -r .state)"
        [ -n "$dres" ] && printf 'Summary: %s\n\n' "$dres"
        if [ "$dshape" = ship ] && [ -n "$dbr" ]; then
          printf 'Code: branch `%s`%s. Its commits are not in your branch unless the plan merged them; read them with git if you need the exact change.\n\n' \
            "$dbr" "${dhead:+ at commit $dhead}"
        fi
        if out_path="$(_task_output_path "$plan" "$dt")"; then
          out_txt="$(_factory_trim 4000 < "$out_path")"
          if [ -n "$out_txt" ] && [ "$out_txt" != "$dres" ]; then
            printf 'Output:\n\n%s\n\n' "$out_txt"
          fi
          printf 'Full report: %s\n\n' "$out_path"
        elif [ -n "$djob" ]; then
          printf 'Full output: outsourcerer result %s\n\n' "$djob"
        fi
        dans="$(printf '%s' "$dt" | _ft_jq -r '.hold.answer // ""' | _factory_trim 4000 "in $(_task_file "$plan" "$d") (field hold.answer)")"
        [ -n "$dans" ] && printf 'Captain decided on %s: %s\n\n' "$d" "$dans"
      done
    fi

    if [ -n "$ans" ]; then
      printf '## Decision from the captain\n\n'
      [ -n "$reason" ] && printf 'Question: %s\n\n' "$reason"
      printf '%s\n\n' "$ans"
    fi

    if [ "$attempts" -gt 0 ] 2>/dev/null && [ -n "$prev" ]; then
      printf '## Earlier attempt\n\nA previous attempt at this task did not finish. What went wrong: %s\nAvoid repeating it.\n\n' "$prev"
    fi
  } | _factory_write_file "$brief" || { echo "outsourcerer: could not write $brief" >&2; return 1; }
  printf '%s\n' "$brief"
}

# ---------------------------------------------------------------- dispatch

# _task_bg_launch <workdir> <cmd_bg args...> -> job id on stdout. The one seam between the factory
# and the existing bg machinery; tests override it so no real delegate runs. The caller has already
# exported OSRC_WORKTREE / OSRC_WORKTREE_BASE / OSRC_TASK_REF in this subshell.
_task_bg_launch() {
  local wd="$1"; shift
  cd "$wd" 2>/dev/null || { echo "outsourcerer: cannot enter $wd" >&2; return 1; }
  cmd_bg "$@"
}

# _task_deps_blocking <plan> <task-json> -> "t1 (failed), t3 (missing)" for every dep that is not done;
# empty when all are done. Reads only the task's own dep files in ONE jq pass (cheap enough to run
# under the plan lock, even with hundreds of tasks on Git-Bash). rc1 when a dep file is unreadable.
_task_deps_blocking() {
  local plan="$1" t="$2" deps d f
  deps="$(printf '%s' "$t" | _ft_jq -r '(.deps // [])[]')"
  [ -n "$deps" ] || return 0
  for d in $deps; do
    f="$(_task_file "$plan" "$d")"
    if [ -f "$f" ]; then cat "$f"; printf '\n'; else printf '{"id":"%s","state":"missing"}\n' "$d"; fi
  done | _ft_jq -rs 'map(select(.state != "done") | "\(.id) (\(.state))") | join(", ")' 2>/dev/null
}

# _task_claim_locked <plan> <tid> [claimer] -> rc0 after moving a READY todo task to running
# (attempts+1, job cleared, claimed_at/claimed_by recorded). Caller holds the lock. Prints the refusal
# reason on stderr otherwise. Captain decisions, decision gates and land steps are never dispatched
# as workers: plan run (or land) handles those.
# _task_brief_lint <task-json> -> prints what is missing when a brief is too thin for a worker to
# act on, nothing when it is fine. Every task needs words (a prompt or a title). A ship task changes
# code, so it also needs a way to tell when it is done: a spec, a check, finished work it builds on
# (dependencies), or a captain's answer. Flow stages are exempt from the ship rule: their templates
# set what done means (best-of-n candidates, for one, may run with no check on purpose).
_task_brief_lint() {
  printf '%s' "$1" | _ft_jq -r '
    def has_text(f): ((f // "") | tostring | test("\\S"));
    if (has_text(.prompt) or has_text(.title) or has_text(.hold.answer)) | not then "it has no prompt or title"
    elif (.shape // "scout") == "ship" and ((.flow.name // "") == "")
         and ((has_text(.spec) or has_text(.check) or ((.deps // []) | length > 0) or has_text(.hold.answer)) | not)
      then "a ship task needs a spec, a check, or a task it builds on, so the worker knows when it is done"
    else empty end' 2>/dev/null
}

_task_claim_locked() {
  local plan="$1" tid="$2" claimer="${3:-}" t st bl kind
  t="$(_task_get "$plan" "$tid")" || return 1
  st="$(printf '%s' "$t" | _ft_jq -r .state)"
  case "$st" in
    todo) ;;
    held) echo "outsourcerer: $tid is held for a decision ($(printf '%s' "$t" | _ft_jq -r '.hold.reason // ""')). Release it first: outsourcerer task release $tid --plan $plan --answer \"...\"" >&2; return 1 ;;
    running|verifying)
      if [ "$st" = running ] && [ -z "$(printf '%s' "$t" | _ft_jq -r '.job // ""')" ]; then
        echo "outsourcerer: $tid is being launched right now (claimed $(printf '%s' "$t" | _ft_jq -r '.claimed_at // "?" | tostring')). If that launch died, recover it with: outsourcerer task retry $tid --plan $plan" >&2
      else
        echo "outsourcerer: $tid is already underway (job $(printf '%s' "$t" | _ft_jq -r '.job // "?"'))." >&2
      fi
      return 1 ;;
    *) echo "outsourcerer: $tid is $st, not waiting to start. To run it again: outsourcerer task retry $tid --plan $plan" >&2; return 1 ;;
  esac
  kind="$(printf '%s' "$t" | _ft_jq -r 'if (.land_target // "") != "" then "land:" + .land_target
                                    elif (.gate // false) == true or (.hold_after_deps // false) == true then "decision"
                                    else "" end')"
  case "$kind" in
    land:*) echo "outsourcerer: $tid is the land step for ${kind#land:}, not work for a worker. Run it with: outsourcerer land ${kind#land:} --plan $plan  (or let: outsourcerer plan run $plan)" >&2; return 1 ;;
    decision) echo "outsourcerer: $tid is a captain decision, not work for a worker. outsourcerer plan run $plan asks you when its inputs are ready; then answer with: outsourcerer task release $tid --plan $plan --answer \"...\"" >&2; return 1 ;;
  esac
  bl="$(_task_deps_blocking "$plan" "$t")" || { echo "outsourcerer: cannot read the dependencies of $tid (a task file is damaged). See: outsourcerer task ls --plan $plan" >&2; return 1; }
  if [ -n "$bl" ]; then
    echo "outsourcerer: $tid is not ready; it waits on $bl." >&2; return 1
  fi
  # A brief too thin to act on is held before a worker is spent on it (no attempt is used).
  local thin; thin="$(_task_brief_lint "$t")"
  if [ -n "$thin" ]; then
    FACTORY_EVENT_NOTE="brief too thin: $thin" _task_update_locked "$plan" "$tid" \
      'if .state != "todo" then error("not todo") else .state = "held"
         | .hold = ((.hold // {}) + {reason: ("the brief is too thin to start a worker: " + $w), answer: "", until: "", until_epoch: 0, default: ""}) end' \
      --arg w "$thin. Add it with: outsourcerer task release $tid --plan $plan --answer \"<what done looks like and how to check it>\"" >/dev/null 2>&1 || true
    echo "outsourcerer: $tid was not started because its brief is too thin: $thin. It is held; add the detail with: outsourcerer task release $tid --plan $plan --answer \"...\"" >&2
    return 1
  fi
  if [ -z "$claimer" ]; then
    _factory_self_pid "$(_plan_dir "$plan")"
    claimer="$_FACTORY_SELF_PID $(_pid_start_identity "$_FACTORY_SELF_PID" 2>/dev/null)"
  fi
  FACTORY_EVENT_NOTE="claimed for dispatch" _task_update_locked "$plan" "$tid" \
    'if .state != "todo" then error("not todo") else .state = "running" | .attempts = ((.attempts // 0) + 1) | .job = ""
       | .head_sha = "" | .evidence = "" | .launch_failed = false | .claimed_at = $at | .claimed_by = $by | .attempt_token = $tok end' \
    --argjson at "$(date +%s)" --arg by "$claimer" --arg tok "$(date +%s)-${claimer%% *}-${RANDOM:-0}-${RANDOM:-0}"
}

# _task_claim_stale <task-json> -> rc0 when a running task has no job and its claimer is provably gone
# (the dispatching process died between claim and recording the job) or the claim is older than
# OSRC_TASK_CLAIM_STALE_SECS (900s; a launch takes seconds, worktree setup on a huge repo minutes).
_task_claim_stale() {
  local t="$1" st job by at o_pid o_start lim
  st="$(printf '%s' "$t" | _ft_jq -r .state)"; job="$(printf '%s' "$t" | _ft_jq -r '.job // ""')"
  [ "$st" = running ] && [ -z "$job" ] || return 1
  by="$(printf '%s' "$t" | _ft_jq -r '.claimed_by // ""')"; at="$(printf '%s' "$t" | _ft_jq -r '.claimed_at // 0 | if type == "number" then floor else 0 end | tostring')"
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  lim="${OSRC_TASK_CLAIM_STALE_SECS:-900}"; case "$lim" in ''|*[!0-9]*) lim=900 ;; esac
  [ "$at" -eq 0 ] && return 0                     # claimed by an older version: no record, so nothing live to protect
  [ $(( $(date +%s) - at )) -ge "$lim" ] && return 0
  o_pid="${by%% *}"; o_start=""; case "$by" in *" "*) o_start="${by#* }" ;; esac
  [ -n "$by" ] && _factory_owner_dead "$o_pid" "$o_start" && return 0
  return 1
}

# _task_dispatch_fail <plan> <tid> <reason> <attempt-token> -> a claimed task that cannot start is failed with the
# reason (so the captain sees it and a wake fires), never left stuck in running. launch_failed:true
# tells the scheduler this was a launch problem, retryable within the task's retries budget (the
# attempt stays counted). Guarded: a task canceled meanwhile stays canceled.
_task_dispatch_fail() {
  FACTORY_EVENT_NOTE="launch failed: $3" _task_update "$1" "$2" \
    'if .state != "running" or (.job // "") != "" or (.attempt_token // "") != $tok then error("moved on") else .state = "failed" | .result = ("launch failed: " + $r) | .launch_failed = true end' \
    --arg r "$3" --arg tok "$4" >/dev/null 2>&1 || true
  echo "outsourcerer: $2 could not start: $3" >&2
}

# _task_worker_prompt <plan> <tid> <brief-path> -> the SHORT prompt passed on the worker's command
# line: the task title, the plan goal's first line, and the absolute path of the full brief to read
# first. The brief itself can be large (spec, dependency results), and a command line cannot: Linux
# caps one argument at 128KB and Windows a whole command line at 32,767 characters.
_task_worker_prompt() {
  local plan="$1" tid="$2" brief="$3" title goal
  # Task and plan JSON go through stdin, never jq's own argv (a huge prompt would hit the same limit).
  local firstline='def line(n): (. // "" | tostring | split("\n") | map(select(test("\\S"))) | (.[0] // "") | if length > n then .[0:n] + "..." else . end);'
  title="$(_task_get "$plan" "$tid" 2>/dev/null | _ft_jq -r "$firstline .title | line(200)" 2>/dev/null)"
  goal="$(_ft_jq -r "$firstline .goal | line(300)" "$(_plan_dir "$plan")/plan.json" 2>/dev/null)"
  printf 'Task %s/%s: %s\n' "$plan" "$tid" "$title"
  [ -n "$goal" ] && printf 'Plan goal: %s\n' "$goal"
  # Inline the brief when it fits: some lanes (sandboxed or chat-only) cannot read a file outside
  # their own workspace, and the brief lives under OSRC_HOME. 16KB keeps the whole command line well
  # under the Windows 32,767-character limit. Larger briefs go by path.
  local bsize; bsize="$(wc -c < "$brief" 2>/dev/null | tr -d ' ')"
  if [ -n "$bsize" ] && [ "$bsize" -le "${OSRC_BRIEF_INLINE_MAX:-16384}" ]; then
    printf '\nYour full brief follows. It is the whole assignment: the task, the spec, the rules for when you are done, and the results of earlier work you build on. Follow it exactly. (Saved copy: %s)\n\n' "$brief"
    cat "$brief"
    return 0
  fi
  printf '\nBefore anything else, read your full brief: %s\n' "$brief"
  printf 'It is the whole assignment: the task, the spec, the rules for when you are done, and the results of earlier work you build on. Follow it exactly.\n'
}

# Reuse the scheduler's fallback order when loaded; the task store also works alone.
_task_dispatch_model() {
  local t="$1" cur m
  if declare -F _ff_next_model >/dev/null; then
    _ff_next_model "$t" dispatch | tr -d '\r'
    return "${PIPESTATUS[0]}"
  fi
  cur="$(printf '%s' "$t" | _ft_jq -r '.model // ""')"
  if [ -n "$cur" ] && { ! declare -F _model_excluded >/dev/null || ! _model_excluded "$cur" >/dev/null 2>&1; }; then
    printf '%s' "$cur"; return 0
  fi
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if ! declare -F _model_excluded >/dev/null || ! _model_excluded "$m" >/dev/null 2>&1; then printf '%s' "$m"; return 0; fi
  done < <(printf '%s' "$t" | _ft_jq -r '(.fallback // [])[] | select(type == "string" and . != "")')
  # Empty delegates selection to the router, which applies exclusions too.
  return 0
}

# _task_dispatch <plan> <tid> -> claim, brief, launch. A cancel or replacement claim
# wins over the returning launcher, whose unattached job is stopped.
_task_dispatch() {
  local plan="$1" tid="$2" t pj repo base shape verb model provider brief prompt wd wt=0 base_sha="" jid out errf rc=0 me now_st tok
  _factory_need_jq
  _factory_self_pid "$(_plan_dir "$plan")"; me="$_FACTORY_SELF_PID"
  _plan_lock "$plan" || return 1
  _task_claim_locked "$plan" "$tid" "$me $(_pid_start_identity "$me" 2>/dev/null)" || rc=1
  if [ "$rc" -eq 0 ]; then
    t="$(_task_get "$plan" "$tid")" || rc=1
    tok="$(printf '%s' "$t" | _ft_jq -r '.attempt_token')"
  fi
  _plan_unlock "$plan"
  [ "$rc" -eq 0 ] || return 1

  pj="$(_ft_jq -c . "$(_plan_dir "$plan")/plan.json" 2>/dev/null)" || pj='{}'
  repo="$(printf '%s' "$pj" | _ft_jq -r '.repo // ""')"; base="$(printf '%s' "$pj" | _ft_jq -r '.base_branch // ""')"
  shape="$(printf '%s' "$t" | _ft_jq -r '.shape // "scout"')"
  verb="$(printf '%s' "$t" | _ft_jq -r '.verb // ""')"; [ -n "$verb" ] || { [ "$shape" = ship ] && verb=edit || verb=run; }
  model="$(_task_dispatch_model "$t")"
  _task_update "$plan" "$tid" \
    'if .state != "running" or (.attempt_token // "") != $tok then error("claim lost") else .model = $m end' \
    --arg tok "$tok" --arg m "$model" >/dev/null 2>&1 || return 1
  provider="$(printf '%s' "$t" | _ft_jq -r '.provider // ""')"

  wd="$PWD"
  if [ -n "$repo" ]; then
    if ! git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1; then
      _task_dispatch_fail "$plan" "$tid" "the plan's repo $repo is not a git repository any more" "$tok"; return 1
    fi
    wd="$repo"
  fi
  if [ "$shape" = ship ]; then
    if [ -z "$repo" ]; then
      _task_dispatch_fail "$plan" "$tid" "ship tasks change code in their own git worktree, and this plan has no repo. Make the plan with --repo <path>" "$tok"; return 1
    fi
    wt=1
    base_sha=""
    [ -n "$base" ] && base_sha="$(git -C "$repo" rev-parse --verify -q "$base^{commit}" 2>/dev/null)"
    [ -n "$base_sha" ] || base_sha="$(git -C "$repo" rev-parse --verify -q "HEAD^{commit}" 2>/dev/null)"
    [ -n "$base_sha" ] || { _task_dispatch_fail "$plan" "$tid" "cannot find the base commit in $repo" "$tok"; return 1; }
  fi

  brief="$(_task_brief "$plan" "$tid")" || { _task_dispatch_fail "$plan" "$tid" "could not write the brief" "$tok"; return 1; }
  case "$brief" in /*) ;; *) brief="$(cd "$(dirname "$brief")" 2>/dev/null && pwd -P)/$(basename "$brief")" ;; esac
  prompt="$(_task_worker_prompt "$plan" "$tid" "$brief")"

  # Persist the base before the child starts worktree setup. Recovery can reconstruct
  # its deterministic path/branch even before run_job publishes meta.json.
  _task_update "$plan" "$tid" \
    'if .state != "running" or (.job // "") != "" or (.attempt_token // "") != $tok then error("claim lost")
     else .base_sha = $s end' --arg tok "$tok" --arg s "$base_sha" >/dev/null 2>&1 || return 1
  # Last look before spending a worker: a cancel (or a scheduler reset) since the claim wins.
  now_st="$(_task_get "$plan" "$tid" 2>/dev/null | _ft_jq -r '.state // ""')"
  if [ "$now_st" != running ] || [ "$(_task_get "$plan" "$tid" | _ft_jq -r '.attempt_token // ""')" != "$tok" ]; then
    echo "outsourcerer: $tid was $now_st before its worker launched, so nothing was started." >&2
    return 1
  fi

  local -a args=()
  [ -n "$provider" ] && args+=(--provider "$provider")
  args+=("$verb")
  [ -n "$model" ] && args+=(-m "$model")
  args+=("$prompt")

  errf="$(_task_dir "$plan" "$tid")/launch.log"
  out="$( export OSRC_WORKTREE="$wt" OSRC_TASK_REF="$plan/$tid" OSRC_TASK_ATTEMPT="$tok"
          if [ "$wt" = 1 ]; then export OSRC_WORKTREE_BASE="$base_sha" OSRC_WORKTREE_REQUIRED=1; else unset OSRC_WORKTREE_BASE OSRC_WORKTREE_REQUIRED; fi
          _task_bg_launch "$wd" "${args[@]}" 2>"$errf" )" || rc=$?
  jid="$(printf '%s\n' "$out" | grep -E '^[0-9]{8}-[0-9]{6}-[0-9A-Za-z]+$' | tail -n 1)"
  if [ "$rc" -ne 0 ] || [ -z "$jid" ]; then
    [ -s "$errf" ] && grep -a -m 3 -E 'ERROR|refus|cannot|could not' "$errf" >&2
    _task_dispatch_fail "$plan" "$tid" "the worker did not launch (details: $errf)" "$tok"
    return 1
  fi
  [ -d "$OSRC_JOBS/$jid" ] && printf '%s/%s\n' "$plan" "$tid" > "$OSRC_JOBS/$jid/task_ref" 2>/dev/null
  [ -d "$OSRC_JOBS/$jid" ] && printf '%s\n' "$tok" > "$OSRC_JOBS/$jid/task_attempt" 2>/dev/null
  local wtp="" br=""
  if [ "$wt" = 1 ]; then wtp="$repo/.outsourcerer/worktrees/$jid"; br="outsourcerer/$jid"; fi
  # Guarded: only attach the job to the claim we made. If the task was canceled, reset by a scheduler,
  # or already got a job while we launched, this worker is an orphan: stop it instead of letting it
  # keep committing for a task nobody is tracking.
  if ! FACTORY_EVENT_NOTE="job $jid" _task_update "$plan" "$tid" \
    'if .state != "running" or ((.job // "") != "" and .job != $j) or (.attempt_token // "") != $tok then error("claim lost")
     else .job = $j | .jobs = ((.jobs // []) | if index($j) == null then . + [$j] else . end)
       | .worktree = $w | .branch = $b | .base_sha = $s | .claimed_by = "" end' \
    --arg tok "$tok" --arg j "$jid" --arg w "$wtp" --arg b "$br" --arg s "$base_sha" 2>/dev/null; then
    # Recovery may have adopted this exact job and already started checking it.
    # It remains owned by the task, so the returning launcher must not cancel it.
    t="$(_task_get "$plan" "$tid" 2>/dev/null)" || t='{}'
    if printf '%s' "$t" | _ft_jq -e --arg tok "$tok" --arg j "$jid" \
      '(.attempt_token // "") == $tok and .job == $j and (.state == "verifying" or .state == "done")' >/dev/null; then
      printf '%s\n' "$jid"; return 0
    fi
    now_st="$(_task_get "$plan" "$tid" 2>/dev/null | _ft_jq -r '.state // "?"')"
    _task_stop_launched_job "$jid"
    _task_event_full "$plan" "$tid" orphan-stopped "" "" "job $jid launched after the task became $now_st; stopped it" || true
    echo "outsourcerer: $tid became $now_st while its worker launched, so job $jid was stopped and not attached.${wtp:+ Its worktree, if any, can be removed with: outsourcerer cleanup $jid}" >&2
    return 1
  fi
  _task_event_full "$plan" "$tid" dispatched "" "" "job $jid" || true
  printf '%s\n' "$jid"
}

# _task_stop_launched_job <job> -> stop a job we just launched whatever its status says (it may not
# have written "running" yet). Best-effort, quiet.
_task_stop_launched_job() {
  local job="${1:-}"
  [ -n "$job" ] && [ -d "$OSRC_JOBS/$job" ] || return 0
  if type cmd_cancel >/dev/null 2>&1; then ( cmd_cancel "$job" ) >/dev/null 2>&1 || true
  else echo canceled > "$OSRC_JOBS/$job/status" 2>/dev/null || true; fi
}

# ---------------------------------------------------------------- done fallback (when track C is absent)

# _task_job_status <job> -> the job's status word ("" when unknown).
_task_job_status() {
  [ -n "${1:-}" ] || return 0
  head -n 1 "$OSRC_JOBS/$1/status" 2>/dev/null | tr -d '\r\n '
}

# _task_done_fallback <plan> <tid> -> rc0 when the job ended successfully with a non-empty result.
# Used only when factory-land.sh (the full done contract) is not loaded.
_task_done_fallback() {
  local plan="$1" tid="$2" t job st
  t="$(_task_get "$plan" "$tid")" || return 1
  job="$(printf '%s' "$t" | _ft_jq -r '.job // ""')"
  [ -n "$job" ] || { echo "no worker job is attached to $tid"; return 1; }
  st="$(_task_job_status "$job")"
  case "$st" in
    done|'done?') ;;
    running|launching|'') echo "job $job is still ${st:-starting}"; return 1 ;;
    *) echo "job $job ended as $st"; return 1 ;;
  esac
  [ -s "$OSRC_JOBS/$job/last.txt" ] || { echo "job $job finished but left no result"; return 1; }
  echo "job $job finished with a result (basic check only: the full done contract is not installed)"
}

# ---------------------------------------------------------------- CLI: plan

cmd_plan() {
  _factory_need_jq
  local sub="${1:-ls}"; [ $# -gt 0 ] && shift
  case "$sub" in
    new)  _plan_cli_new "$@" ;;
    ls|list) _plan_cli_ls "$@" ;;
    show) _plan_cli_show "$@" ;;
    use)  _plan_cli_use "$@" ;;
    rm|remove|delete) _plan_cli_rm "$@" ;;
    -h|--help|help) _plan_cli_help ;;
    run)
      if type cmd_plan_run >/dev/null 2>&1; then cmd_plan_run "$@"
      else die "plan run needs factory-flow.sh next to outsourcerer.sh, and it is not installed."; fi ;;
    *)
      case "$sub" in *[!a-z_]*) ;; *)
        if type "cmd_plan_$sub" >/dev/null 2>&1; then "cmd_plan_$sub" "$@"; return $?; fi ;;
      esac
      die "unknown plan command '$sub'. Try: plan new|ls|show|use|rm|run" ;;
  esac
}

_plan_cli_help() {
  cat <<'EOF'
outsourcerer plan new <name> [--goal "..."] [--repo <path> | --no-repo] [--base <branch>] [--no-use]
outsourcerer plan ls
outsourcerer plan show [name]
outsourcerer plan use <name>
outsourcerer plan rm <name> [--force]
outsourcerer plan run [name] ...        (needs factory-flow.sh)
EOF
}

# _plan_new_abort <plan-dir> <why> -> remove the plan folder this `plan new` just created, then die.
_plan_new_abort() {
  case "$1" in "$(_plans_root)"/?*) rm -rf "$1" 2>/dev/null ;; esac
  die "plan new: $2. Nothing was kept; fix that and run plan new again."
}

_plan_cli_new() {
  local name="" goal="" repo="" repo_set=0 base="" use=1 pd now top
  while [ $# -gt 0 ]; do
    case "$1" in
      --goal) _factory_optval "$1" $#; goal="$2"; shift 2 ;;
      --repo) _factory_optval "$1" $#; repo="$2"; repo_set=1; shift 2 ;;
      --no-repo) repo=""; repo_set=2; shift ;;
      --base) _factory_optval "$1" $#; base="$2"; shift 2 ;;
      --no-use) use=0; shift ;;
      -*) die "plan new: unknown option '$1'" ;;
      *) [ -z "$name" ] && name="$1" || goal="${goal:-$1}"; shift ;;
    esac
  done
  [ -n "$name" ] || die "plan new needs a name, e.g. outsourcerer plan new checkout-v2 --goal \"ship the new checkout\""
  _plan_name_ok "$name" || die "'$name' is not a valid plan name (letters, digits, dot, dash, underscore; up to 64; not 'current')."
  if [ "$repo_set" = 1 ]; then
    [ -d "$repo" ] || die "plan new: $repo is not a folder."
    top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || die "plan new: $repo is not inside a git repository."
    repo="$(cd "$top" && pwd -P)"
  elif [ "$repo_set" = 0 ]; then
    top="$(git rev-parse --show-toplevel 2>/dev/null)" && repo="$(cd "$top" && pwd -P)" || repo=""
  fi
  if [ -n "$repo" ] && [ -z "$base" ]; then
    base="$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null)" || base=""
  fi
  if [ -n "$repo" ] && [ -n "$base" ] && ! git -C "$repo" rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1; then
    die "plan new: branch '$base' does not exist in $repo."
  fi
  _mkdir_private "$(_plans_root)" || die "cannot create $(_plans_root)"
  pd="$(_plan_dir "$name")"
  mkdir "$pd" 2>/dev/null || die "a plan named '$name' already exists. Pick another name, or see it with: outsourcerer plan show $name"
  # From here on this call owns $pd (mkdir just made it): any failure removes it again, so a half-made
  # plan (no plan.json) never blocks the name or confuses plan ls.
  mkdir "$pd/tasks" 2>/dev/null || _plan_new_abort "$pd" "could not create $pd/tasks"
  now="$(_factory_now)"
  _factory_write_json "$pd/plan.json" "$(_ft_jq -cn --arg n "$name" --arg g "$goal" --arg r "$repo" --arg b "$base" --arg now "$now" \
    '{schema:1,name:$n,goal:$g,repo:$r,base_branch:$b,created:$now,updated:$now}')" || _plan_new_abort "$pd" "could not save $pd/plan.json"
  ( : > "$pd/events.jsonl" ) 2>/dev/null || _plan_new_abort "$pd" "could not create $pd/events.jsonl"
  _task_event_full "$name" "" plan-created "" "" "$goal" || true
  if [ "$use" = 1 ]; then
    printf '%s\n' "$name" | _factory_write_file "$(_plans_root)/current" \
      || _plan_new_abort "$pd" "could not make '$name' the current plan ($(_plans_root)/current)"
  fi
  echo "plan '$name' created${repo:+ for $repo}${base:+ (base branch $base)}$( [ "$use" = 1 ] && echo '; it is now the current plan')."
  [ -z "$repo" ] && echo "No repo is set, so this plan can hold scout tasks only. To build code, make it inside a git repo or pass --repo <path>."
  echo "Next: outsourcerer task add \"<what to do>\" [--shape ship|scout] [--deps t1,t2]"
}

_plan_cli_ls() {
  local root d n cur="" pj counts
  root="$(_plans_root)"
  cur="$(_plan_current 2>/dev/null)" || cur=""
  local any=0
  for d in "$root"/*/; do
    [ -f "$d/plan.json" ] || continue
    n="$(basename "$d")"; any=1
    pj="$(_ft_jq -c . "$d/plan.json" 2>/dev/null)" || pj='{"goal":"(plan.json is damaged)"}'
    counts="$(_task_view "$n" 2>/dev/null | _ft_jq -r 'group_by(.derived) | map("\(length) \(.[0].derived)") | join(", ")')"
    printf '%s %s  %s\n' "$( [ "$n" = "$cur" ] && echo '*' || echo ' ')" "$n" "$(printf '%s' "$pj" | _ft_jq -r '.goal // ""')"
    printf '      %s\n' "${counts:-no tasks yet}"
  done
  [ "$any" = 1 ] || echo "No plans yet. Make one with: outsourcerer plan new <name> --goal \"...\""
}

_plan_cli_use() {
  local p; [ -n "${1:-}" ] || die "plan use needs a plan name. See them with: outsourcerer plan ls"; p="$(_plan_resolve "$1")" || exit 1
  printf '%s\n' "$p" | _factory_write_file "$(_plans_root)/current" || die "could not save the current plan"
  echo "current plan: $p"
}

_plan_cli_rm() {
  local name="" force=0 pd running removed
  while [ $# -gt 0 ]; do
    case "$1" in --force|-f) force=1; shift ;; -*) die "plan rm: unknown option '$1'" ;; *) name="$1"; shift ;; esac
  done
  [ -n "$name" ] || die "plan rm needs a plan name."
  name="$(_plan_resolve "$name")" || exit 1
  pd="$(_plan_dir "$name")"
  _plan_lock "$name" || return 1
  running="$(_task_list "$name" | _ft_jq -r 'map(select(.state == "running" or .state == "verifying")) | map(.id) | join(", ")')"
  if [ -n "$running" ] && [ "$force" != 1 ]; then
    _plan_unlock "$name"
    die "plan '$name' still has work underway ($running). Cancel those tasks first, or pass --force to remove the plan anyway (their jobs keep running)."
  fi
  case "$pd" in "$(_plans_root)"/?*) ;; *) die "refusing to remove $pd" ;; esac
  # Unpublish atomically with the lock still inside. Recursive deletion of the
  # published path could remove .lock first and admit another writer mid-delete.
  removed="$(mktemp -d "$(_plans_root)/.removed.$name.XXXXXX")" \
    || { _plan_unlock "$name"; die "could not prepare removal of $pd"; }
  if ! mv "$pd" "$removed/plan"; then
    rmdir "$removed" 2>/dev/null || true
    _plan_unlock "$name"; die "could not remove $pd"
  fi
  _FACTORY_LOCK_PLAN=""; _FACTORY_LOCK_DEPTH=0; _FACTORY_LOCK_OWNER=""
  [ "$(_plan_current 2>/dev/null)" = "$name" ] && rm -f "$(_plans_root)/current"
  rm -rf "$removed" || die "plan '$name' was removed, but its old files still need cleanup at $removed"
  echo "plan '$name' removed. Its git worktrees and branches, if any, are untouched (outsourcerer cleanup <job> removes a worktree)."
}

# _plan_cli_show [plan] -> the four-bucket view + a compact dependency listing.
_plan_cli_show() {
  local plan="" json=0
  while [ $# -gt 0 ]; do
    case "$1" in --json) json=1; shift ;; --plan) _factory_optval "$1" $#; plan="$2"; shift 2 ;; -*) die "plan show: unknown option '$1'" ;; *) plan="$1"; shift ;; esac
  done
  plan="$(_plan_resolve "$plan")" || exit 1
  local pj view
  pj="$(_ft_jq -c . "$(_plan_dir "$plan")/plan.json" 2>/dev/null)" || pj="{\"name\":\"$plan\",\"goal\":\"(plan.json is damaged)\"}"
  view="$(_task_view "$plan")"
  if [ "$json" = 1 ]; then
    _ft_jq -n --argjson p "$pj" --argjson t "$view" '{plan:$p,tasks:$t}'; return 0
  fi
  printf '%s' "$view" | _ft_jq -r --argjson p "$pj" '
    def line(s): "  - \(.id) [\(s)] \(.title)";
    def first(s): (s // "" | tostring | split("\n")[0] | if length > 100 then .[0:100] + "..." else . end);
    def bucket(name; rows): [name] + (if (rows | length) == 0 then ["  (nothing)"] else rows end);
    . as $all
    | (reduce $all[] as $t ({}; .[$t.id] = $t)) as $by
    | ["Plan \($p.name // "?"): \($p.goal // "")"]
      + (if ($p.repo // "") != "" then ["Repo: \($p.repo)\(if ($p.base_branch // "") != "" then " (base \($p.base_branch))" else "" end)"] else [] end)
      + [""]
      + bucket("Captain'"'"'s Call";
          [ $all[] | select(.state == "held")
            | line("held") + " - needs a decision: \(first(.hold.reason))" + (if (.hold.until // "") != "" then " (by \(.hold.until))" else "" end) + (if (.hold.default // "") != "" then "; default if no answer: \(.hold.default)" else "" end)
              + "\n      answer with: outsourcerer task release \(.id) --plan \($p.name) --answer \"...\"" ]
          + [ $all[] | select(.state == "failed")
            | line("failed") + (if (.result // "") != "" then " - \(first(.result))" else "" end)
              + "\n      retry with: outsourcerer task retry \(.id) --plan \($p.name)   or drop it: outsourcerer task cancel \(.id) --plan \($p.name)" ])
      + [""]
      + bucket("Done";
          [ $all[] | select(.state == "done" or .state == "canceled")
            | line(if .state == "done" then (if .landed == true then "landed" else "done" end) else "canceled" end)
              + (if (.result // "") != "" then " - \(first(.result))" else "" end) ])
      + [""]
      + bucket("Underway";
          [ $all[] | select(.state == "running" or .state == "verifying")
            | line(.state) + (if (.job // "") != "" then " - job \(.job)" else "" end)
              + (if (.model // "") != "" then " on \(.model)" else "" end) ])
      + [""]
      + bucket("Next";
          [ $all[] | select(.derived == "ready") | line("ready") ]
          + [ $all[] | select(.derived == "blocked")
            | line("blocked") + " - waiting on "
              + (.blocked_by | map(.id + " (" + .state + ")"
                  + (if .state == "failed" or .state == "canceled" then ", needs the captain" elif .state == "held" then ", held for a decision" else "" end))
                 | join(", ")) ])
      + (if ([$all[] | select((.deps // []) | length > 0)] | length) > 0 then
           ["", "Dependencies"] + [ $all[] | select((.deps // []) | length > 0) | "  \(.id) <- \(.deps | join(", "))" ]
         else [] end)
    | .[]'
}

# ---------------------------------------------------------------- CLI: task

cmd_task() {
  _factory_need_jq
  local sub="${1:-ls}"; [ $# -gt 0 ] && shift
  case "$sub" in
    add|new)  _task_cli_add "$@" ;;
    ls|list)  _task_cli_ls "$@" ;;
    show)     _task_cli_show "$@" ;;
    ready)    _task_cli_ready "$@" ;;
    start|dispatch) _task_cli_start "$@" ;;
    hold)     _task_cli_hold "$@" ;;
    release)  _task_cli_release "$@" ;;
    done)     _task_cli_done "$@" ;;
    fail)     _task_cli_fail "$@" ;;
    cancel)   _task_cli_cancel "$@" ;;
    retry)    _task_cli_retry "$@" ;;
    brief)    _task_cli_brief "$@" ;;
    -h|--help|help) _task_cli_help ;;
    *) die "unknown task command '$sub'. Try: task add|ls|show|ready|start|hold|release|done|fail|cancel|retry" ;;
  esac
}

_task_cli_help() {
  cat <<'EOF'
outsourcerer task add "<title>" [--prompt "..." | --prompt-file f] [--shape ship|scout] [--deps t1,t2]
        [--spec file] [--check "cmd"] [--verb run|research|edit|yolo] [-m model] [--provider p]
        [--deliver local|branch|pr] [--retries N] [--hold "question"] [--plan p]
outsourcerer task ls [--state s] [--plan p]          outsourcerer task show <tid> [--json] [--plan p]
outsourcerer task ready [--plan p]                   outsourcerer task start <tid> [--plan p]
outsourcerer task hold <tid> --reason "..." [--until "..."]
outsourcerer task release <tid> --answer "..." [--done] [--plan p]
outsourcerer task done <tid> [--result "..."] [--force] [--plan p]
outsourcerer task fail <tid> [--reason "..."] [--plan p]  outsourcerer task cancel <tid> [--plan p]
outsourcerer task retry <tid> [--plan p]               outsourcerer task brief <tid> [--plan p]
EOF
}

# _task_cli_args: pull --plan out of the argv; leaves the rest in _TASK_ARGV and the plan in _TASK_PLAN.
_TASK_ARGV=(); _TASK_PLAN=""
_task_cli_args() {
  _TASK_ARGV=(); _TASK_PLAN=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --plan) _factory_optval "$1" $#; [ -n "$2" ] || die "--plan needs a plan name"; _TASK_PLAN="$2"; shift 2 ;;
      --plan=*) _TASK_PLAN="${1#--plan=}"; shift ;;
      *) _TASK_ARGV+=("$1"); shift ;;
    esac
  done
  _TASK_PLAN="$(_plan_resolve "$_TASK_PLAN")" || exit 1
}

_task_cli_add() {
  _task_cli_args "$@"; set -- ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}
  local plan="$_TASK_PLAN" title="" prompt="" shape="" deps="" spec="" check="" verb="" model="" provider=""
  local deliver="local" retries=1 hold="" flow="" stage="" fields tid
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt) _factory_optval "$1" $#; prompt="$2"; shift 2 ;;
      --prompt-file) _factory_optval "$1" $#; [ -f "$2" ] || die "task add: no such prompt file '${2:-}'"; prompt="$(cat "$2")"; shift 2 ;;
      --shape) _factory_optval "$1" $#; shape="$2"; shift 2 ;;
      --deps|--after) _factory_optval "$1" $#; deps="$2"; shift 2 ;;
      --spec) _factory_optval "$1" $#; spec="$2"; shift 2 ;;
      --check) _factory_optval "$1" $#; check="$2"; shift 2 ;;
      --verb) _factory_optval "$1" $#; verb="$2"; shift 2 ;;
      -m|--model) _factory_optval "$1" $#; model="$2"
        # Exclude list (#45): refuse at add time, not when the task later fails to launch.
        if [ -n "$model" ] && declare -F _exclude_refuse >/dev/null 2>&1; then _exclude_refuse "$model" "task add"; fi
        shift 2 ;;
      --provider) _factory_optval "$1" $#; provider="$2"; shift 2 ;;
      --deliver) _factory_optval "$1" $#; deliver="$2"; shift 2 ;;
      --retries) _factory_optval "$1" $#; retries="$2"; shift 2 ;;
      --hold) _factory_optval "$1" $#; hold="$2"; shift 2 ;;
      --flow) _factory_optval "$1" $#; flow="$2"; shift 2 ;;
      --stage) _factory_optval "$1" $#; stage="$2"; shift 2 ;;
      -*) die "task add: unknown option '$1'" ;;
      *) [ -z "$title" ] && title="$1" || die "task add: give one title (quote it). Extra text: '$1'"; shift ;;
    esac
  done
  [ -n "$title" ] || die "task add needs a title, e.g. outsourcerer task add \"map the auth flow\" --shape scout"
  # A global --provider (before or after the subcommand) is the lane for a task that names none.
  [ -z "$provider" ] && [ "${PROVIDER_EXPLICIT:-0}" = "1" ] && provider="${PROVIDER:-}"
  case "$verb" in ''|run|research|edit|yolo) ;; *) die "task add: --verb must be run, research, edit or yolo." ;; esac
  if [ -z "$shape" ]; then case "$verb" in edit|yolo) shape=ship ;; *) shape=scout ;; esac; fi
  case "$shape" in ship|scout) ;; *) die "task add: --shape must be ship (changes code) or scout (investigates)." ;; esac
  case "$deliver" in local|branch|pr) ;; *) die "task add: --deliver must be local, branch or pr." ;; esac
  case "$retries" in ''|*[!0-9]*) die "task add: --retries must be a whole number." ;; esac
  # Normalize: "007" -> 7 (a leading zero is not valid JSON), and keep it sane.
  retries="$(printf '%s' "$retries" | sed 's/^0*//')"; retries="${retries:-0}"
  [ "${#retries}" -le 3 ] || die "task add: --retries must be 999 or less."
  if [ -n "$spec" ]; then
    [ -f "$spec" ] || die "task add: the spec file '$spec' does not exist."
    spec="$(cd "$(dirname "$spec")" && pwd -P)/$(basename "$spec")"
  fi
  local d; deps="$(printf '%s' "$deps" | tr ', ' '\n\n' | sed '/^$/d')"
  for d in $deps; do _task_id_ok "$d" || die "task add: '$d' is not a task id (they look like t1, t2)."; done
  # The prompt (possibly a large --prompt-file) goes through stdin, not jq's argv.
  fields="$(printf '%s' "$prompt" | _ft_jq -Rsc --arg title "$title" --arg shape "$shape" --arg deps "$deps" --arg spec "$spec" \
    --arg check "$check" --arg verb "$verb" --arg model "$model" --arg provider "$provider" --arg deliver "$deliver" \
    --argjson retries "$retries" --arg hold "$hold" --arg flow "$flow" --arg stage "$stage" '
    . as $prompt | {title:$title,prompt:$prompt,shape:$shape,
     deps:($deps | split("\n") | map(select(. != "")) | reduce .[] as $d ([]; if any(.[]; . == $d) then . else . + [$d] end)),
     spec:$spec,check:$check,verb:$verb,model:$model,provider:$provider,deliver:$deliver,retries:$retries,
     flow:{name:$flow,stage:$stage}}
    + (if $hold != "" then {state:"held",hold:{reason:$hold,until:"",answer:""}} else {} end)')"
  tid="$(_task_new "$plan" "$fields")" || exit 1
  printf '%s\n' "$tid"
  echo "added $tid to plan '$plan' ($shape)${deps:+, after $(printf '%s' "$deps" | tr '\n' ' ' | sed 's/ $//;s/ /, /g')}${hold:+, held for a decision}." >&2
}

_task_cli_ls() {
  _task_cli_args "$@"; set -- ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}
  local st="" json=0
  while [ $# -gt 0 ]; do
    case "$1" in --state) _factory_optval "$1" $#; st="$2"; shift 2 ;; --json) json=1; shift ;; *) die "task ls: unknown option '$1'" ;; esac
  done
  local view; view="$(_task_view "$_TASK_PLAN")"
  [ "$json" = 1 ] && { printf '%s\n' "$view" | _ft_jq --arg s "$st" 'map(select($s == "" or .state == $s or .derived == $s))'; return 0; }
  printf '%s' "$view" | _ft_jq -r --arg s "$st" '
    map(select($s == "" or .state == $s or .derived == $s))
    | if length == 0 then "No tasks\(if $s != "" then " in state \($s)" else "" end). Add one with: outsourcerer task add \"...\""
      else (["ID", "STATE", "SHAPE", "AFTER", "JOB", "TITLE"] | @tsv),
           (.[] | [.id, .derived, .shape, ((.deps // []) | join(",") | if . == "" then "-" else . end),
                   (if (.job // "") == "" then "-" else .job end), .title] | @tsv)
      end' | { if have column; then column -t -s "$(printf '\t')"; else cat; fi; }
}

_task_one_arg() {   # <usage> -> sets _TASK_TID from the first positional in _TASK_ARGV
  _TASK_TID="${_TASK_ARGV[0]:-}"
  [ -n "$_TASK_TID" ] || die "$1"
  _task_id_ok "$_TASK_TID" || die "'$_TASK_TID' is not a task id (they look like t1, t2)."
}

_task_cli_show() {
  _task_cli_args "$@"
  local json=0 a rest=()
  for a in ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}; do [ "$a" = "--json" ] && json=1 || rest+=("$a"); done
  _TASK_ARGV=(${rest[@]+"${rest[@]}"})
  _task_one_arg "task show needs a task id, e.g. outsourcerer task show t3 --plan $_TASK_PLAN"
  local t; t="$(_task_get "$_TASK_PLAN" "$_TASK_TID")" || exit 1
  [ "$json" = 1 ] && { printf '%s\n' "$t" | _ft_jq .; return 0; }
  local derived; derived="$(_task_view "$_TASK_PLAN" | _ft_jq -r --arg id "$_TASK_TID" '.[] | select(.id == $id) | .derived + (if (.blocked_by|length) > 0 then " (waiting on " + (.blocked_by | map(.id + " " + .state) | join(", ")) + ")" else "" end)')"
  printf '%s' "$t" | _ft_jq -r --arg d "$derived" --arg bd "$(_task_dir "$_TASK_PLAN" "$_TASK_TID")" '
    "\(.plan)/\(.id): \(.title)",
    "  state:    \($d)",
    "  shape:    \(.shape)   verb: \(.verb)\(if .model != "" then "   model: " + .model else "" end)\(if .provider != "" then "   provider: " + .provider else "" end)",
    (if (.deps|length) > 0 then "  after:    \(.deps | join(", "))" else empty end),
    (if .check != "" then "  check:    \(.check)" else empty end),
    (if .spec != "" then "  spec:     \(.spec)" else empty end),
    "  attempts: \(.attempts) of \((.retries // 0) + 1)",
    (if .job != "" then "  job:      \(.job)   (all: \(.jobs | join(", ")))" else empty end),
    (if .branch != "" then "  branch:   \(.branch) at \(.worktree)\(if .base_sha != "" then " (base " + .base_sha[0:12] + ")" else "" end)" else empty end),
    (if .hold.reason != "" then "  question: \(.hold.reason)\(if .hold.until != "" then " (by " + .hold.until + ")" else "" end)" else empty end),
    (if (.hold.default // "") != "" and .state == "held" then "  default:  \(.hold.default) (used if nobody answers by \(.hold.until))" else empty end),
    (if .hold.answer != "" then "  answer:   \(.hold.answer)\(if (.hold.defaulted // false) then " (the default; nobody answered in time)" else "" end)" else empty end),
    (if .result != "" then "  result:   \(.result)" else empty end),
    (if .evidence != "" then "  evidence: \(.evidence)" else empty end),
    (if .landed == true then "  landed:   yes\(if (.landed_into // "") != "" then " into " + .landed_into else "" end)\(if (.landed_sha // "") != "" then " at " + (.landed_sha | tostring | .[0:12]) else "" end)" else empty end),
    (if (.pr // "") != "" then "  pr:       \(.pr)" else empty end),
    "  files:    \($bd)/",
    "  prompt:",
    (.prompt | split("\n") | .[0:12][] | "    " + .)'
  local ev; ev="$(_plan_dir "$_TASK_PLAN")/events.jsonl"
  if [ -s "$ev" ]; then
    echo "  recent events:"
    _ft_jq -r --arg id "$_TASK_TID" 'select(.task == $id) | "    \(.ts) \(.event)\(if .from != "" or .to != "" then " " + .from + " -> " + .to else "" end)\(if .note != "" then " (" + .note + ")" else "" end)"' "$ev" 2>/dev/null | tail -n 8
  fi
}

_task_cli_ready() {
  _task_cli_args "$@"
  local ids; ids="$(_task_ready "$_TASK_PLAN")"
  [ -n "$ids" ] || { echo "Nothing is ready in plan '$_TASK_PLAN'. See why with: outsourcerer plan show" >&2; return 0; }
  _task_list "$_TASK_PLAN" | _ft_jq -r --arg ids "$ids" '($ids | split("\n")) as $o | INDEX(.id) as $by | $o[] | "\(.)\t\($by[.].title)"'
}

_task_cli_brief() {
  _task_cli_args "$@"
  _task_one_arg "task brief needs a task id"
  local p; p="$(_task_brief "$_TASK_PLAN" "$_TASK_TID")" || exit 1
  cat "$p"; echo; echo "(saved at $p)" >&2
}

_task_cli_start() {
  _task_cli_args "$@"
  _task_one_arg "task start needs a task id, e.g. outsourcerer task start t2 --plan $_TASK_PLAN"
  local jid; jid="$(_task_dispatch "$_TASK_PLAN" "$_TASK_TID")" || exit 1
  printf '%s\n' "$jid"
  echo "$_TASK_TID started as job $jid. Its brief: $(_task_dir "$_TASK_PLAN" "$_TASK_TID")/brief.md. Watch it: outsourcerer watch $jid" >&2
}

# _task_deadline <when> -> "<epoch> <ISO-UTC>" for +30m / +2h / +1d (also s and w) or an ISO time
# like 2026-10-24T09:00Z or 2026-10-24T09:00:00Z. Fails on anything else. jq does the date math, so
# it behaves the same on macOS and Linux.
_task_deadline() {
  local w="$1" n u e now
  now="$(date +%s)"
  case "$w" in
    +[0-9]*[smhdw])
      n="${w#+}"; u="${n##*[0-9]}"; n="${n%"$u"}"
      case "$n" in ''|*[!0-9]*) return 1 ;; esac
      case "$u" in s) e=$((now + n)) ;; m) e=$((now + n * 60)) ;; h) e=$((now + n * 3600)) ;; d) e=$((now + n * 86400)) ;; w) e=$((now + n * 604800)) ;; *) return 1 ;; esac ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]Z) e="$(_ft_jq -nr --arg t "${w%Z}:00Z" '$t | fromdateiso8601' 2>/dev/null)" || return 1 ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) e="$(_ft_jq -nr --arg t "$w" '$t | fromdateiso8601' 2>/dev/null)" || return 1 ;;
    *) return 1 ;;
  esac
  case "$e" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s %s\n' "$e" "$(_ft_jq -nr --argjson e "$e" '$e | todate')"
}

_task_cli_hold() {
  _task_cli_args "$@"; set -- ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}
  local tid="" reason="" until="" def="" dl="" ue=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) _factory_optval "$1" $#; reason="$2"; shift 2 ;;
      --until) _factory_optval "$1" $#; until="$2"; shift 2 ;;
      --default) _factory_optval "$1" $#; def="$2"; shift 2 ;;
      -*) die "task hold: unknown option '$1'" ;;
      *) tid="$1"; shift ;;
    esac
  done
  _task_id_ok "$tid" || die "task hold needs a task id, e.g. outsourcerer task hold t3 --plan $_TASK_PLAN --reason \"pick A or B\""
  [ -n "$reason" ] || die "task hold needs --reason \"<the question for the captain>\"."
  if [ -n "$until" ]; then
    if dl="$(_task_deadline "$until")"; then ue="${dl%% *}"; until="${dl#* }"
    elif [ -n "$def" ]; then die "task hold: --until '$until' is not a time. Use +30m, +2h, +1d, or an ISO time like 2026-10-24T09:00Z."
    fi
  fi
  if [ -n "$def" ] && [ "$ue" -eq 0 ]; then
    die "task hold: --default needs --until, so the captain knows when the default kicks in (e.g. --until +2h)."
  fi
  FACTORY_EVENT_NOTE="$reason" _task_update "$_TASK_PLAN" "$tid" \
    'if (.state == "todo" or .state == "failed" or .state == "verifying" or .state == "held") | not
       then error("bad state") else .state = "held" | .hold = {reason:$r, until:$u, until_epoch:$ue, default:$d, answer:""} end' \
    --arg r "$reason" --arg u "$until" --argjson ue "$ue" --arg d "$def" \
    || die "$tid can be held only while it waits, is being checked, or has failed. If it is running, cancel it first."
  echo "$tid is held for a decision ($reason). Answer with: outsourcerer task release $tid --plan $_TASK_PLAN --answer \"...\""
  [ -n "$def" ] && echo "With no answer by $until, plan run goes ahead with the default: $def"
  return 0
}

_task_cli_release() {
  _task_cli_args "$@"; set -- ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}
  local tid="" answer="" mkdone=0
  while [ $# -gt 0 ]; do
    case "$1" in --answer) _factory_optval "$1" $#; answer="$2"; shift 2 ;; --done) mkdone=1; shift ;; -*) die "task release: unknown option '$1'" ;; *) tid="$1"; shift ;; esac
  done
  _task_id_ok "$tid" || die "task release needs a task id, e.g. outsourcerer task release t3 --plan $_TASK_PLAN --answer \"go with B\""
  [ -n "$answer" ] || die "task release needs --answer \"<your decision>\". It is handed to this task and the ones after it."
  if [ "$mkdone" = 1 ]; then
    FACTORY_EVENT_NOTE="$answer" _task_update "$_TASK_PLAN" "$tid" \
      'if .state != "held" then error("not held") else .state = "done" | .hold.answer = $a | .hold.defaulted = false | .hold.until_epoch = 0 | .result = $a end' --arg a "$answer" \
      || die "$tid is not held, so there is nothing to release."
    echo "$tid is done with your decision; the tasks after it now see it."
  else
    FACTORY_EVENT_NOTE="$answer" _task_update "$_TASK_PLAN" "$tid" \
      'if .state != "held" then error("not held") else .state = "todo" | .hold.answer = $a | .hold.defaulted = false | .hold.until_epoch = 0 end' --arg a "$answer" \
      || die "$tid is not held, so there is nothing to release."
    echo "$tid released with your answer; it goes back in line to run."
  fi
}

# _task_finish_from_output <plan> <tid> -> after a passed done check: copy a scout's output to
# report.md and fill .result with a short summary when nothing set one.
_task_finish_from_output() {
  local plan="$1" tid="$2" t job shape rep sum
  t="$(_task_get "$plan" "$tid")" || return 0
  job="$(printf '%s' "$t" | _ft_jq -r '.job // ""')"; shape="$(printf '%s' "$t" | _ft_jq -r '.shape // ""')"
  rep="$(_task_dir "$plan" "$tid")/report.md"
  if [ "$shape" = scout ] && [ ! -s "$rep" ] && [ -n "$job" ] && [ -s "$OSRC_JOBS/$job/last.txt" ]; then
    _factory_write_file "$rep" < "$OSRC_JOBS/$job/last.txt" || true
  fi
  if [ -z "$(printf '%s' "$t" | _ft_jq -r '.result // ""')" ]; then
    if [ -s "$rep" ]; then sum="$(_factory_trim 600 < "$rep")"
    elif [ -n "$job" ] && [ -s "$OSRC_JOBS/$job/last.txt" ]; then sum="$(_factory_trim 600 < "$OSRC_JOBS/$job/last.txt")"
    else sum=""; fi
    [ -n "$sum" ] && _task_update "$plan" "$tid" '.result = $s' --arg s "$sum" || true
  fi
}

# Interrupt handling for `task done`: the check can run for minutes. Ctrl-C (or a kill) during it must
# not leave the task stuck in verifying, where start says "underway" and retry refuses.
_TASK_DONE_PLAN=""; _TASK_DONE_TID=""; _TASK_DONE_PREV=""
_TASK_DONE_TOKEN=""; _TASK_DONE_PID=""; _TASK_DONE_START=""; _TASK_DONE_AT=0
_task_done_update() {
  local filter="$1"; shift
  _task_update "$_TASK_DONE_PLAN" "$_TASK_DONE_TID" \
    'if .state != "verifying" or (.attempt_token // "") != $tok
        or (.verifying_pid | tostring) != $pid or (.verifying_start // "") != $start
        or .verifying_at != $at then error("verification ownership lost") else . end | '"$filter" \
    --arg tok "$_TASK_DONE_TOKEN" --arg pid "$_TASK_DONE_PID" --arg start "$_TASK_DONE_START" \
    --argjson at "$_TASK_DONE_AT" "$@"
}
_task_done_interrupted() {
  if [ -n "$_TASK_DONE_TID" ]; then
    if FACTORY_EVENT_NOTE="done check interrupted" _task_done_update '.state = $p' --arg p "$_TASK_DONE_PREV" >/dev/null 2>&1; then
      echo "outsourcerer: the done check for $_TASK_DONE_TID was interrupted; it is back to $_TASK_DONE_PREV." >&2
    fi
  fi
  trap - INT TERM HUP
  exit 130
}

_task_cli_done() {
  _task_cli_args "$@"; set -- ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}
  local tid="" result="" force=0 why rc=0 prev verdict
  while [ $# -gt 0 ]; do
    case "$1" in --result) _factory_optval "$1" $#; result="$2"; shift 2 ;; --force) force=1; shift ;; -*) die "task done: unknown option '$1'" ;; *) tid="$1"; shift ;; esac
  done
  _task_id_ok "$tid" || die "task done needs a task id, e.g. outsourcerer task done t2 --plan $_TASK_PLAN"
  local t; t="$(_task_get "$_TASK_PLAN" "$tid")" || exit 1
  prev="$(printf '%s' "$t" | _ft_jq -r .state)"
  case "$prev" in
    done) echo "$tid is already done."; return 0 ;;
    canceled) die "$tid was canceled. Run it again with: outsourcerer task retry $tid --plan $_TASK_PLAN" ;;
  esac
  if [ "$force" = 1 ]; then
    FACTORY_EVENT_NOTE="marked done by hand${result:+: $result}" _task_update "$_TASK_PLAN" "$tid" \
      'if .state == "canceled" then error("canceled") else .state = "done" | (if $r != "" then .result = $r else . end) end' --arg r "$result" \
      || die "$tid could not be marked done (it was canceled meanwhile?). See: outsourcerer task show $tid --plan $_TASK_PLAN"
    echo "$tid marked done by hand (no check was run)."
    return 0
  fi
  case "$prev" in
    running|failed) ;;
    verifying) die "$tid is already being checked (by plan run or another task done). Wait for it, then see: outsourcerer task show $tid --plan $_TASK_PLAN" ;;
    *) die "$tid has not run yet ($prev). Start it with: outsourcerer task start $tid --plan $_TASK_PLAN  (or mark it done by hand with --force)" ;;
  esac
  # The interrupt handler goes in first (it only ever undoes OUR verifying, so arming it early is safe).
  _TASK_DONE_PLAN="$_TASK_PLAN"; _TASK_DONE_TID="$tid"; _TASK_DONE_PREV="$prev"
  _TASK_DONE_TOKEN="$(printf '%s' "$t" | _ft_jq -r '.attempt_token // ""')"
  _factory_self_pid "$(_plan_dir "$_TASK_PLAN")"; _TASK_DONE_PID="$_FACTORY_SELF_PID"
  _TASK_DONE_START="$(_pid_start_identity "$_TASK_DONE_PID" 2>/dev/null)"
  _TASK_DONE_AT="$(date +%s)"
  trap _task_done_interrupted INT TERM HUP
  # Claim the check: only from the exact state we saw, so a concurrent cancel is never resurrected and
  # a concurrent `plan run` verify (which also moves the task to verifying) never runs it twice.
  if ! FACTORY_EVENT_NOTE="done check" _task_update "$_TASK_PLAN" "$tid" \
    'if .state != $p or (.attempt_token // "") != $tok then error("moved on")
     else .state = "verifying" | .verifying_pid=$pid | .verifying_start=$start | .verifying_at=$at end' \
    --arg p "$prev" --arg tok "$_TASK_DONE_TOKEN" --arg pid "$_TASK_DONE_PID" \
    --arg start "$_TASK_DONE_START" --argjson at "$_TASK_DONE_AT" >/dev/null 2>&1; then
    trap - INT TERM HUP; _TASK_DONE_TID=""
    die "$tid changed while starting its check (it is now $(_task_get "$_TASK_PLAN" "$tid" 2>/dev/null | _ft_jq -r '.state // "?"')). See: outsourcerer task show $tid --plan $_TASK_PLAN"
  fi
  if type _factory_done_check >/dev/null 2>&1; then
    why="$(_factory_done_check "$_TASK_PLAN" "$tid")" || rc=$?
  else
    why="$(_task_done_fallback "$_TASK_PLAN" "$tid")" || rc=$?
  fi
  if [ "$rc" -eq 0 ] && [ "$(printf '%s' "$t" | _ft_jq -r '.require_verdict // false')" = true ]; then
    if declare -F _factory_review_verdict >/dev/null; then
      verdict="$(_factory_review_verdict "$_TASK_PLAN" "$tid")" || rc=$?
      if [ "$rc" -ne 0 ] || [ "$verdict" != PASS ]; then
        rc=1; why="review verdict is ${verdict:-AMBIGUOUS}"
      fi
    else
      rc=1; why="review verdict checker is unavailable"
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    _plan_lock "$_TASK_PLAN" || { _task_done_interrupted; }
    # A review closed by hand binds to the build it approved, so a replacement build needs a new review.
    local rtarget="" rhead=""
    if [ "$(printf '%s' "$t" | _ft_jq -r '.require_verdict // false')" = true ] && declare -F _ff_review_target >/dev/null; then
      rtarget="$(_ff_review_target "$t" "$(_task_list "$_TASK_PLAN")")"
      [ -n "$rtarget" ] && rhead="$(_task_get "$_TASK_PLAN" "$rtarget" | _ft_jq -r '.head_sha // ""')"
    fi
    if ! FACTORY_EVENT_NOTE="$why" _task_done_update \
         '.state = "done" | if $r != "" then .result = $r else . end
          | if $rt != "" and (has("reviewed_head") | not) then .reviewed_head = $rh | .review_target = $rt else . end' \
         --arg r "$result" --arg rt "$rtarget" --arg rh "$rhead" 2>/dev/null; then
      _plan_unlock "$_TASK_PLAN"
      trap - INT TERM HUP; _TASK_DONE_TID=""
      die "$tid passed its check, but it was changed meanwhile (now $(_task_get "$_TASK_PLAN" "$tid" 2>/dev/null | _ft_jq -r '.state // "?"')), so it was left as is."
    fi
    trap - INT TERM HUP; _TASK_DONE_TID=""
    _task_finish_from_output "$_TASK_PLAN" "$tid"
    _plan_unlock "$_TASK_PLAN"
    echo "$tid is done: $why"
    return 0
  fi
  FACTORY_EVENT_NOTE="not done: $why" _task_done_update '.state = $p' --arg p "$prev" >/dev/null 2>&1 || true
  trap - INT TERM HUP; _TASK_DONE_TID=""
  echo "$tid is not done: $why" >&2
  echo "If the work is good anyway: outsourcerer task done $tid --plan $_TASK_PLAN --force. If it is bad: outsourcerer task fail $tid --plan $_TASK_PLAN --reason \"...\"" >&2
  return 1
}

# _task_stop_job <job> -> best-effort stop of a live worker job (cancel/fail of a running task).
_task_stop_job() {
  local job="${1:-}" st
  [ -n "$job" ] || return 0
  st="$(_task_job_status "$job")"
  case "$st" in running|launching)
    if type cmd_cancel >/dev/null 2>&1; then ( cmd_cancel "$job" ) >/dev/null 2>&1 || true; echo "stopped job $job." ; fi ;;
  esac
}

_task_cli_fail() {
  _task_cli_args "$@"; set -- ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}
  local tid="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in --reason) _factory_optval "$1" $#; reason="$2"; shift 2 ;; -*) die "task fail: unknown option '$1'" ;; *) tid="$1"; shift ;; esac
  done
  _task_id_ok "$tid" || die "task fail needs a task id, e.g. outsourcerer task fail t2 --plan $_TASK_PLAN --reason \"tests still red\""
  local t; t="$(_task_get "$_TASK_PLAN" "$tid")" || exit 1
  [ -n "$reason" ] || reason="marked failed by hand"
  FACTORY_EVENT_NOTE="$reason" _task_update "$_TASK_PLAN" "$tid" \
    'if (.state == "done" or .state == "canceled") then error("final") else .state = "failed" | .result = $r end' --arg r "$reason" \
    || die "$tid is already finished ($(printf '%s' "$t" | _ft_jq -r .state)); nothing to fail."
  # Read the job AFTER the state change: a dispatch that attaches a job does so only while the task is
  # still running, so this sees every job that can exist for it.
  _task_stop_job "$(_task_get "$_TASK_PLAN" "$tid" 2>/dev/null | _ft_jq -r '.job // ""')"
  echo "$tid failed: $reason. Tasks after it stay blocked until you retry or cancel it."
}

_task_cli_cancel() {
  _task_cli_args "$@"; set -- ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}
  local tid="${1:-}"
  _task_id_ok "$tid" || die "task cancel needs a task id, e.g. outsourcerer task cancel t2 --plan $_TASK_PLAN"
  local t; t="$(_task_get "$_TASK_PLAN" "$tid")" || exit 1
  FACTORY_EVENT_NOTE="canceled by hand" _task_update "$_TASK_PLAN" "$tid" \
    'if .state == "done" then error("done") else .state = "canceled" end' \
    || die "$tid is already done; there is nothing to cancel."
  _task_stop_job "$(_task_get "$_TASK_PLAN" "$tid" 2>/dev/null | _ft_jq -r '.job // ""')"
  echo "$tid canceled. Tasks after it stay blocked until you retry it or cancel them too."
}

# _task_release_worktree <plan> <task-json> -> before a retry forgets a ship task's worktree, remove it
# when that is safe: it lives under the plan repo's .outsourcerer/worktrees/, its job is not running,
# and it has no uncommitted changes. The branch (and so any commits) is always kept. Prints one plain
# line saying what happened; never fails the caller.
_task_release_worktree() {
  local plan="$1" t="$2" wt br job repo st
  wt="$(printf '%s' "$t" | _ft_jq -r '.worktree // ""')"; br="$(printf '%s' "$t" | _ft_jq -r '.branch // ""')"
  job="$(printf '%s' "$t" | _ft_jq -r '.job // ""')"
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  repo="$(_ft_jq -r '.repo // ""' "$(_plan_dir "$plan")/plan.json" 2>/dev/null)"
  case "$wt" in "$repo"/.outsourcerer/worktrees/?*) ;; *) return 0 ;; esac
  case "$wt" in */../*|*/..) return 0 ;; esac
  st="$(_task_job_status "$job")"
  case "$st" in running|launching)
    echo "kept the old worktree $wt: its job $job is still running."; return 0 ;;
  esac
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null | head -1)" ]; then
    echo "kept the old worktree $wt: it has uncommitted changes. Look, then remove it with: outsourcerer cleanup $job --force"
    return 0
  fi
  if git -C "$repo" worktree remove "$wt" >/dev/null 2>&1; then
    echo "removed the old worktree $wt${br:+ (branch $br is kept, with its commits)}."
  else
    echo "could not remove the old worktree $wt; remove it with: outsourcerer cleanup $job"
  fi
}

# Find only jobs from this claim. Legacy claims without tokens are accepted only when
# exactly one unrecorded receipt matches; choosing the newest could adopt a nested job.
_task_find_job_by_ref() {
  local plan="$1" tid="$2" t="$3" tok f ref jt j found=""
  tok="$(printf '%s' "$t" | _ft_jq -r '.attempt_token // ""')"
  for f in "$OSRC_JOBS"/*/task_ref; do
    [ -f "$f" ] || continue
    ref="$(head -n 1 "$f" | tr -d '\r\n')"
    [ "$ref" = "$plan/$tid" ] || continue
    j="${f%/task_ref}"; j="${j##*/}"
    printf '%s' "$t" | _ft_jq -e --arg j "$j" '(.jobs // []) | index($j) != null' >/dev/null && continue
    jt="$(head -n 1 "$OSRC_JOBS/$j/task_attempt" 2>/dev/null | tr -d '\r\n')"
    [ "$jt" = "$tok" ] || continue
    if [ -n "$found" ]; then
      echo "outsourcerer: multiple jobs match $plan/$tid; inspect them before retrying." >&2
      return 2
    fi
    found="$j"
  done
  printf '%s' "$found"
}

# Read the durable worktree receipt as well as the launch metadata. Caller guards
# the update with the attempt token observed before searching for the job.
_task_adopt_job() {
  local plan="$1" tid="$2" job="$3" tok="$4" receipt='{}' meta='{}' jd t repo wt="" br=""
  jd="$OSRC_JOBS/$job"
  t="$(_task_get "$plan" "$tid")" || return 1
  if [ "$(printf '%s' "$t" | _ft_jq -r '.shape // "scout"')" = ship ]; then
    repo="$(_ft_jq -r '.repo // ""' "$(_plan_dir "$plan")/plan.json")" || return 1
    [ -n "$repo" ] || return 1
    wt="$repo/.outsourcerer/worktrees/$job"; br="outsourcerer/$job"
  fi
  [ ! -f "$jd/meta.json" ] || meta="$(_ft_jq -ce . "$jd/meta.json")" || return 1
  [ ! -f "$jd/worktree.json" ] || receipt="$(_ft_jq -ce . "$jd/worktree.json")" || return 1
  _task_update "$plan" "$tid" \
    'if .state != "running" or (.job // "") != "" or (.attempt_token // "") != $tok then error("claim lost")
     else .job=$j | .jobs=((.jobs // []) + [$j]) | .claimed_by=""
       | .worktree=($r.path // $m.worktree // $w) | .branch=($r.branch // $m.branch // $b)
       | .base_sha=($r.base_sha // $m.base_sha // .base_sha // "") end' \
    --arg j "$job" --arg tok "$tok" --arg w "$wt" --arg b "$br" --argjson m "$meta" --argjson r "$receipt"
}

_task_cli_retry() {
  _task_cli_args "$@"; set -- ${_TASK_ARGV[@]+"${_TASK_ARGV[@]}"}
  local tid="${1:-}" t note tok job
  _task_id_ok "$tid" || die "task retry needs a task id, e.g. outsourcerer task retry t2 --plan $_TASK_PLAN"
  t="$(_task_get "$_TASK_PLAN" "$tid")" || exit 1
  tok="$(printf '%s' "$t" | _ft_jq -r '.attempt_token // ""')"
  # A task stuck "running" with no job is a launch that died between claim and recording its job.
  # Retry may recover it, but only when that claim is provably dead or old (never a live launch).
  if _task_claim_stale "$t"; then
    job="$(_task_find_job_by_ref "$_TASK_PLAN" "$tid" "$t")" || return 1
    if [ -n "$job" ]; then
      _task_adopt_job "$_TASK_PLAN" "$tid" "$job" "$tok" || return 1
      echo "$tid recovered its existing worker $job. See: outsourcerer task show $tid --plan $_TASK_PLAN"
      return 0
    fi
    FACTORY_EVENT_NOTE="recovered a launch that never finished" _task_update "$_TASK_PLAN" "$tid" \
      'if .state != "running" or (.job // "") != "" or (.attempt_token // "") != $tok or (.claimed_at // 0) != $at then error("moved on")
       else .state = "todo" | .worktree = "" | .branch = "" | .base_sha = "" | .head_sha = "" | .evidence = "" | .claimed_by = "" end' \
      --arg tok "$tok" --argjson at "$(printf '%s' "$t" | _ft_jq -c '.claimed_at // 0')" \
      || die "$tid changed while recovering it. See: outsourcerer task show $tid --plan $_TASK_PLAN"
    echo "$tid was stuck starting (its launcher stopped before the worker began); it is back in line."
    return 0
  fi
  FACTORY_EVENT_NOTE="retry by hand" _task_update "$_TASK_PLAN" "$tid" \
    'if (.attempt_token // "") != $tok or ((.state == "failed" or .state == "canceled") | not) then error("not retryable")
     else .state = "todo" | .job = "" | .worktree = "" | .branch = "" | .base_sha = "" | .head_sha = "" | .evidence = "" | .launch_failed = false end' \
    --arg tok "$tok" \
    || die "only a failed or canceled task can be retried; $tid is $(_task_get "$_TASK_PLAN" "$tid" 2>/dev/null | _ft_jq -r '.state // "unknown"')."
  note="$(_task_release_worktree "$_TASK_PLAN" "$t")"
  [ -n "$note" ] && echo "$note"
  echo "$tid is back in line. It runs when its dependencies are done (start it now with: outsourcerer task start $tid --plan $_TASK_PLAN)."
}
