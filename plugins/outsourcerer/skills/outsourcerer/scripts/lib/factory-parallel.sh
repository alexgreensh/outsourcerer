# factory-parallel.sh: the one task-list-to-running-plan flow (lane osrc-l5-parallel).
# Sourced by outsourcerer.sh's lib/*.sh glob BEFORE the factory scripts; every function here only
# CALLS factory functions at run time, so load order does not matter. It also holds the scheduler
# functions moved out of factory-flow.sh (_ff_next_default, _ff_apply_defaults, _ff_dispatch,
# _ff_review_failed) so that file only shrinks under the 1,000-line ratchet.
#
#   outsourcerer plan run [plan] [--max-parallel N] [--once] [--auto-land] [--interval S]
#     runs a plan until it is done, blocked or escalated. Ready work starts in parallel by
#     default (cap: --max-parallel, else OSRC_FACTORY_PARALLEL, else the profile's factory.parallel,
#     else 3). Files each task declares (.files, or legacy .owns) conflict-serialize it against
#     running and same-batch tasks; free commands run locally on the host. The flow stops instead
#     of guessing: on a missing answer whose default is irreversible, paid or publishing (never
#     auto-applied), and on a review round past the cap without an escalation record.
#
# Safe per-repo overrides live in <repo>/.outsourcerer.toml (never .outsourcerer/config.toml,
# which owns shared budget defaults). Example:
#
#   [factory]
#   check = "scripts/check_file_size.py"
#   gate = "scripts/resource_gate.sh"
#   parallel = 4
#   [factory.heavy]
#   "npm test" = "devin"
#   "make test" = "devin"
#   [factory.bench]
#   "bench/" = true
#
# check: a free local command that verifies changed files (prose -> `git diff --check`).
# gate: an optional executable run as `<gate> can-run` before each launch pass; rc1 pauses launches
#   (absent file or rc>=2 fails open; the hard disk gate in the launch path still applies).
# parallel: default launch cap when --max-parallel and OSRC_FACTORY_PARALLEL are unset.
# heavy: command -> lane, run in an isolated worktree on a heavy lane. bench: path prefixes where
# a benchmark with numbers is justified.
#
# Settings: OSRC_FACTORY_PARALLEL (default cap, 1-16, default 3), OSRC_FACTORY_CHECK (overrides the
# profile check), OSRC_FACTORY_GATE (overrides the profile gate), OSRC_FACTORY_REVIEW_ROUNDS
# (review cap, default 3). "gate"/"check" paths resolve against the repo root or OSRC_FACTORY_ROOT.
# Decisions carry --default and a deadline; the flow applies the default at the deadline unless
# `task hold --risk` marks it irreversible, paid or publishing (any non-safe risk never
# auto-applies). A review round past the cap needs an approved escalation record at
# .outsourcerer/plans/<plan>/escalations/<reviewer>.json:
#   {"task":"t5","round":4,"reason":"why round four is justified","by":"who approved",
#    "approved":true,"at":"iso"}

_osrc_fp_jq() { jq "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }

# ---------------------------------------------------------------- repo profile

# _osrc_fp_root [dir] -> prints the enclosing git root (absolute). rc 1 when not in a repo.
_osrc_fp_root() {
  local top
  top="$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null)" || return 1
  (cd "$top" && pwd -P)
}

# _osrc_fp_profile_file [root] -> prints the per-repo profile path (<root>/.outsourcerer.toml).
_osrc_fp_profile_file() { printf '%s/.outsourcerer.toml' "${1:-$OSRC_FACTORY_ROOT:-.}"; }

# _osrc_fp_parse_value <raw> -> normalized scalar from one TOML key = value line.
_osrc_fp_parse_value() {
  local v="$1"
  v="$(printf '%s' "$v" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

# _osrc_fp_get <section> <key> -> echoes the parsed value of <key> under [<section>] in the
# profile. <key> may be bare or quoted; both sides are unquoted before comparing. Never sources
# the file: each line is pattern-matched, so profile content cannot execute.
_osrc_fp_get() {
  local want_sec="$1" want_key="$2" file root line section="" k v
  want_key="${want_key%\"}"; want_key="${want_key#\"}"
  want_key="${want_key%\'}"; want_key="${want_key#\'}"
  [ -n "${OSRC_FACTORY_PROFILE:-}" ] && file="$OSRC_FACTORY_PROFILE" \
    || { root="$(_osrc_fp_root "${OSRC_FACTORY_ROOT:-.}" 2>/dev/null)" || return 0; file="$(_osrc_fp_profile_file "$root")"; }
  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      \[*\]*) section="$(printf '%s' "$line" | sed -e 's/^\[//; s/\].*//; s/[[:space:]]//g')"; continue ;;
      ''|\#*) continue ;;
    esac
    [ "$section" = "$want_sec" ] || continue
    k="$(printf '%s' "$line" | sed -n 's/^[[:space:]]*\("[^"]*"|'"'"'[^'"'"']*'"'"'\|[A-Za-z0-9_.-]*\)[[:space:]]*=.*/\1/p')"
    [ -n "$k" ] || continue
    k="${k%\"}"; k="${k#\"}"; k="${k%\'}"; k="${k#\'}"
    [ "$k" = "$want_key" ] || continue
    v="$(printf '%s' "$line" | sed -e 's/^[^=]*=//' -e 's/[[:space:]]*#.*$//')"
    v="$(_osrc_fp_parse_value "$v")"
    printf '%s' "$v"
    return 0
  done < "$file"
  return 0
}

# _osrc_fp_section <section> -> every "key = value" pair under [factory.<section>] as lines.
_osrc_fp_section() {
  local want="$1" file root line section="" k v
  [ -n "${OSRC_FACTORY_PROFILE:-}" ] && file="$OSRC_FACTORY_PROFILE" \
    || { root="$(_osrc_fp_root "${OSRC_FACTORY_ROOT:-.}" 2>/dev/null)" || return 0; file="$(_osrc_fp_profile_file "$root")"; }
  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      \[*\]*) section="$(printf '%s' "$line" | sed -e 's/^\[//; s/\].*//; s/[[:space:]]//g')"; continue ;;
      ''|\#*) continue ;;
    esac
    [ "$section" = "factory.$want" ] || continue
    k="$(printf '%s' "$line" | sed -n 's/^[[:space:]]*\([A-Za-z0-9_.-]*\)[[:space:]]*=.*/\1/p')"
    [ -n "$k" ] || continue
    v="$(printf '%s' "$line" | sed -e 's/^[^=]*=//' -e 's/[[:space:]]*#.*$//')"
    v="$(_osrc_fp_parse_value "$v")"
    [ -n "$k" ] && [ -n "$v" ] && printf '%s\t%s\n' "$k" "$v"
  done < "$file"
}

# _osrc_fp_check -> the repo's free local check: OSRC_FACTORY_CHECK, then profile "check", then
# "git diff --check". Printed once per launch so the check is visible in the run record.
_osrc_fp_check() {
  local c="${OSRC_FACTORY_CHECK:-}"
  [ -n "$c" ] || c="$(_osrc_fp_get factory check)"
  [ -n "$c" ] || c='git diff --check'
  printf '%s' "$c"
}

# _osrc_fp_heavy_for <cmd> -> the configured heavy lane for a command, else empty.
_osrc_fp_heavy_for() {
  local cmd="$1" k v
  while IFS="$(printf '\t')" read -r k v; do
    [ -n "$k" ] || continue
    case "$cmd" in "$k"|"$k "*|*" $k"|*" $k "*) printf '%s' "$v"; return 0 ;; esac
  done <<EOF
$(_osrc_fp_section heavy)
EOF
  return 0
}

# _osrc_fp_bench_for <path> -> "yes" when the path sits under a profile bench prefix.
_osrc_fp_bench_for() {
  local p="$1" k
  while IFS="$(printf '\t')" read -r k v; do
    case "$p" in "$k"*|*/"$k"*) [ "$v" != "false" ] && [ "$v" != "0" ] && { printf 'yes'; return 0; } ;;
    esac
  done <<EOF
$(_osrc_fp_section bench)
EOF
  return 0
}

# ---------------------------------------------------------------- file ownership

# _osrc_fp_task_files <plan> <task-id> -> prints one repo-relative path per line, from the
# task's .files field (explicit ownership) or the legacy .owns field. Empty when undeclared.
_osrc_fp_task_files() {
  local plan="$1" id="$2" t
  t="$(_task_get "$plan" "$id" 2>/dev/null)" || return 0
  printf '%s' "$t" | _osrc_fp_jq -r '(.files // .owns // [])[]? | strings' 2>/dev/null \
    | while IFS= read -r f; do
        printf '%s' "$f" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's#^\./##' -e 's#/$##'
      done | grep -v '^$' | sort -u
}

# _osrc_fp_hit <x> <y> -> rc0 when two repo-relative paths collide (equal, or one a "/"-boundary
# prefix of the other: "src/a.sh" vs "src").
_osrc_fp_hit() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  if [ "$1" = "$2" ] || [ "${1%/}/" = "${2%/}/" ]; then return 0; fi
  case "$2" in "$1"/*) return 0 ;; esac
  case "$1" in "$2"/*) return 0 ;; esac
  return 1
}

# _osrc_fp_overlap <list-a> <list-b> -> rc 0 when any path in the newline-separated lists
# prefix-collides. Empty lists never overlap.
_osrc_fp_overlap() {
  local a="$1" b="$2" x y
  [ -n "$a" ] && [ -n "$b" ] || return 1
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    while IFS= read -r y; do
      [ -n "$y" ] || continue
      _osrc_fp_hit "$x" "$y" && return 0
    done <<EOF2
$b
EOF2
  done <<EOF1
$a
EOF1
  return 1
}

# _osrc_fp_conflict <list-a> <list-b> -> prints "path-a -> path-b" for the first colliding pair,
# nothing when the lists are disjoint. Used for the "why is this task waiting" line.
_osrc_fp_conflict() {
  local a="$1" b="$2" x y
  [ -n "$a" ] && [ -n "$b" ] || return 0
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    while IFS= read -r y; do
      [ -n "$y" ] || continue
      if _osrc_fp_hit "$x" "$y"; then printf '%s -> %s' "$x" "$y"; return 0; fi
    done <<EOF2
$b
EOF2
  done <<EOF1
$a
EOF1
  return 0
}

# ---------------------------------------------------------------- resource gate

# _osrc_fp_gate_can_run -> rc0 when new worker launches may proceed this pass.
# The gate is OPTIONAL: no profile "gate" key and no OSRC_FACTORY_GATE means open. When set it
# names an executable (absolute, or relative to the repo root) run as `<gate> can-run`:
#   rc0  -> launch; rc1 -> pause launches this pass (its stdout is the reason, kept in
#           _OSRC_FP_GATE_REASON); any other rc or a spawn failure -> warn once and FAIL OPEN,
#           because the hard disk gate inside the launch path still protects every real launch.
# A missing file also fails open. This is a scheduling hint only; it never marks a task failed.
_OSRC_FP_GATE_REASON=""
_osrc_fp_gate_can_run() {
  local g root out rc
  _OSRC_FP_GATE_REASON=""
  g="${OSRC_FACTORY_GATE:-}"
  [ -n "$g" ] || g="$(_osrc_fp_get factory gate)"
  [ -n "$g" ] || return 0
  case "$g" in /*) ;; *)
    root="$(_osrc_fp_root "${OSRC_FACTORY_ROOT:-.}" 2>/dev/null)" || return 0
    g="$root/$g" ;;
  esac
  [ -f "$g" ] || return 0
  if [ -x "$g" ]; then out="$("$g" can-run 2>&1)"; rc=$?
  else out="$(sh "$g" can-run 2>&1)"; rc=$?; fi
  case "$rc" in
    0) return 0 ;;
    1) _OSRC_FP_GATE_REASON="$(printf '%s' "$out" | head -1 | cut -c1-200)"; [ -n "$_OSRC_FP_GATE_REASON" ] || _OSRC_FP_GATE_REASON="resource gate $g said no"; return 1 ;;
    *) printf 'outsourcerer: resource gate %s failed (rc=%s); ignoring it this pass\n' "$g" "$rc" >&2; return 0 ;;
  esac
}

# ---------------------------------------------------------------- concurrency

# _osrc_fp_max_parallel [explicit] -> the effective launch cap: explicit flag, else
# OSRC_FACTORY_PARALLEL, else the repo profile's factory.parallel, else 3. Whole number 1-16;
# rc1 (message on stderr) on a bad value.
_osrc_fp_max_parallel() {
  local v="${1:-}" src=flag
  if [ -z "$v" ]; then v="${OSRC_FACTORY_PARALLEL:-}"; [ -n "$v" ] && src=env; fi
  if [ -z "$v" ]; then v="$(_osrc_fp_get factory parallel)"; [ -n "$v" ] && src=profile; fi
  [ -n "$v" ] || { printf '3'; return 0; }
  case "$v" in ''|*[!0-9]*) printf 'outsourcerer: parallel limit (%s) must be a whole number\n' "$src" >&2; return 1 ;; esac
  while [ "${#v}" -gt 1 ] && [ "${v#0}" != "$v" ]; do v="${v#0}"; done
  v="${v:-0}"
  [ "$v" -ge 1 ] && [ "$v" -le 16 ] || { printf 'outsourcerer: parallel limit must be 1-16\n' >&2; return 1; }
  printf '%s' "$v"
}

# ---------------------------------------------------------------- held decisions

# _osrc_fp_defaultable <task-json> -> rc0 when the hold may auto-apply at its deadline.
# A hold is defaultable only with a non-empty default and a future/past positive deadline AND a
# risk class that allows automation: .hold.risk absent/empty/"reversible"/"safe". Any other risk
# (irreversible, paid, publish, or an unknown label) NEVER auto-applies: those waits end only with
# the captain's answer.
_osrc_fp_defaultable() {
  printf '%s' "$1" | _osrc_fp_jq -e '
    (.state == "held")
    and (((.hold.default // "") | test("\\S")))
    and (((.hold.until_epoch // 0) | type) == "number") and ((.hold.until_epoch // 0) > 0)
    and (((.hold.risk // "") as $r | $r == "" or $r == "reversible" or $r == "safe"))' \
    >/dev/null 2>&1
}

# _osrc_fp_risky_hold <task-json> -> rc0 when the hold declares a risk that forbids auto-apply.
_osrc_fp_risky_hold() {
  printf '%s' "$1" | _osrc_fp_jq -e '
    (.state == "held") and (((.hold.risk // "") as $r | $r != "" and $r != "reversible" and $r != "safe"))' \
    >/dev/null 2>&1
}

# ---------------------------------------------------------------- review cap + escalation

# _osrc_fp_review_cap -> max review rounds before an escalation record is required.
# OSRC_FACTORY_REVIEW_ROUNDS, default 3; a non-numeric or <1 value falls back to 3.
_osrc_fp_review_cap() {
  local v="${OSRC_FACTORY_REVIEW_ROUNDS:-3}"
  case "$v" in ''|*[!0-9]*) v=3 ;; esac
  while [ "${#v}" -gt 1 ] && [ "${v#0}" != "$v" ]; do v="${v#0}"; done
  [ "${v:-0}" -ge 1 ] || v=3
  printf '%s' "$v"
}

# _osrc_fp_esc_path <plan> <tid> -> the escalation record path for a task.
_osrc_fp_esc_path() { printf '%s/escalations/%s.json' "$(_plan_dir "$1")" "$2"; }

# _osrc_fp_escalation_ok <plan> <tid> <round> -> rc0 when an APPROVED escalation record exists for
# exactly that review round: {"task":"t5","round":4,"reason":"...","by":"...","approved":true}.
# A pending record (no approved:true) does not count. Never executes record content.
_osrc_fp_escalation_ok() {
  local f
  f="$(_osrc_fp_esc_path "$1" "$2")"
  [ -f "$f" ] || return 1
  _osrc_fp_jq -e --argjson r "$3" '.approved == true and (.round == $r)' "$f" >/dev/null 2>&1
}

# _osrc_fp_escalation_write <plan> <tid> <round> <reason> -> create a PENDING escalation record when
# none exists (an approved record is never overwritten). Prints the path. Best-effort: rc1 when the
# directory cannot be written; callers treat that as "hold anyway".
_osrc_fp_escalation_write() {
  local plan="$1" tid="$2" round="$3" reason="$4" f d
  f="$(_osrc_fp_esc_path "$plan" "$tid")"
  [ -f "$f" ] && _osrc_fp_jq -e '.approved == true' "$f" >/dev/null 2>&1 && { printf '%s' "$f"; return 0; }
  d="$(dirname "$f")"; mkdir -p "$d" 2>/dev/null || return 1
  _osrc_fp_jq -n --arg t "$tid" --argjson r "$round" --arg reason "$reason" --arg at "$(_factory_now)" \
    '{task:$t, round:$r, reason:$reason, status:"pending", approved:false, at:$at}' > "$f.tmp" 2>/dev/null \
    && mv -f "$f.tmp" "$f" 2>/dev/null || { rm -f "$f.tmp"; return 1; }
  printf '%s' "$f"
}

# ================================================================ scheduler (moved from factory-flow.sh)
# These functions live here so the parallel/file-ownership/resource/cap changes land in a module
# under the 1,000-line ratchet instead of growing factory-flow.sh / factory-tasks.sh. They are
# defined before the factory scripts are sourced but only CALLED at run time, so every
# _ff_*/_task_* they use resolves normally. Guarded callers (_ff_need_fns) still verify the pieces.

# _task_worker_prompt <plan> <tid> <brief-path> -> the SHORT prompt passed on the worker's command
# line: the task title, the plan goal's first line, and the absolute path of the full brief to read
# first. The brief itself can be large (spec, dependency results), and a command line cannot: Linux
# caps one argument at 128KB and Windows a whole command line at 32,767 characters.
# (Moved from factory-tasks.sh for the size ratchet; dispatch support lives with the scheduler.)
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

# _ff_next_default <plan> -> "<epoch> <tid>" of the soonest held decision whose default may
# auto-apply, else empty. Holds with a risky .hold.risk never auto-apply, so they are not waited on.
_ff_next_default() {
  _task_list "$1" | _ff_jq -r '[.[] | select(.state == "held" and ((.hold.default // "") | test("\\S"))
      and ((.hold.until_epoch // 0) | type == "number") and (.hold.until_epoch // 0) > 0
      and (((.hold.risk // "") as $r | $r == "" or $r == "reversible" or $r == "safe")))]
    | sort_by(.hold.until_epoch) | first // empty | "\(.hold.until_epoch | floor) \(.id)"' 2>/dev/null
}

# _ff_apply_defaults <plan>: every reconcile, apply the default of a held decision whose deadline
# passed — UNLESS the hold is risky (.hold.risk irreversible/paid/publish/unknown): those wait for
# the captain forever and are never auto-applied.
_ff_apply_defaults() {
  local plan="$1" tid now d
  now="$(date +%s)"
  for tid in $(_task_list "$plan" | _ff_jq -r --argjson now "$now" '.[]
      | select(.state == "held" and ((.hold.default // "") | test("\\S")) and ((.hold.until_epoch // 0) | type == "number")
               and (.hold.until_epoch // 0) > 0 and (.hold.until_epoch // 0) <= $now
               and (((.hold.risk // "") as $r | $r == "" or $r == "reversible" or $r == "safe"))) | .id'); do
    d="$(_task_get "$plan" "$tid" | _ff_jq -r '.hold.default // ""')"
    FACTORY_EVENT_NOTE="no answer by the deadline; used the default: $d" _task_update "$plan" "$tid" \
      'if .state != "held" or ((.hold.until_epoch // 0) > $now) or (.hold.until_epoch // 0) <= 0 or (.hold.default // "") == "" then error("moved")
       else .state = "todo" | .hold.answer = .hold.default | .hold.defaulted = true | .hold.until_epoch = 0 end' \
      --argjson now "$now" >/dev/null 2>&1 || continue
    printf '  %s: nobody answered by the deadline, so it goes ahead with the default: %s\n' "$tid" "$d"
  done
}

_FF_MOVED=0
_ff_dispatch() {   # <plan> <max-parallel>
  local plan="$1" max="$2" tasks active tid t out rc st answer target m lf ready
  _FF_MOVED=0
  _plan_lock "$plan" || return 1
  if [ -f "$(_plan_dir "$plan")/flow-expansion.json" ]; then _plan_unlock "$plan"; return 1; fi
  _ff_pair_recover "$plan" || { _plan_unlock "$plan"; return 1; }
  ready="$(_task_ready "$plan")"
  _plan_unlock "$plan"
  tasks="$(_task_list "$plan")" || return 1
  active="$(printf '%s' "$tasks" | _ff_jq '[.[] | select(.state == "running" or .state == "verifying")] | length')"
  # File-ownership serialization (lane osrc-l5-parallel): a ready task whose declared .files/.owns
  # touch a running task's or an already-picked task's declared files waits, and the reason names
  # the owner and the colliding paths. Tasks that declare no files never conflict on files; declared
  # deps still order everything. owners = ids running now; picked = ids launched this pass.
  local owners picked cf of oid cp gate_ok gate_said
  owners="$(printf '%s' "$tasks" | _ff_jq -r '.[] | select(.state == "running" or .state == "verifying") | .id')"
  picked=""
  gate_ok=1; gate_said=0
  _osrc_fp_gate_can_run || gate_ok=0
  for tid in $ready; do
    _ff_out_of_time && return 0
    t="$(_task_get "$plan" "$tid")" || continue
    [ "$(printf '%s' "$t" | _ff_jq -r '.state')" = todo ] || continue
    if [ "$(printf '%s' "$t" | _ff_jq -r '.hold_after_deps // false')" = "true" ]; then
      _ff_hold "$plan" "$tid" "captain's decision: $(printf '%s' "$t" | _ff_jq -r '.title // ""')$(_ff_pick_hint "$plan" "$t" "$tasks"). Decide: $(_ff_cmd "$plan" task release "$tid" --answer '"<your decision>"')" '.state == "todo"'
      _FF_MOVED=1
      continue
    fi
    target="$(printf '%s' "$t" | _ff_jq -r '.land_target // ""')"
    if [ -n "$target" ]; then
      _ff_land_stage "$plan" "$tid" "$target"
      continue
    fi
    answer="$(printf '%s' "$t" | _ff_jq -r '.hold.answer // ""')"
    if [ "$(printf '%s' "$t" | _ff_jq -r '.gate // false')" = "true" ]; then
      # A decision gate is done only with the captain's answer (`task release --answer`).
      if [ -z "$answer" ]; then
        _ff_hold "$plan" "$tid" "captain's decision: $(printf '%s' "$t" | _ff_jq -r '.title // ""'). Decide: $(_ff_cmd "$plan" task release "$tid" --answer '"<your decision>"')" '.state == "todo"'
      else
        _task_update "$plan" "$tid" 'if .state != "todo" then error("moved") else . end | .state = "done" | .result = $a' --arg a "$answer" >/dev/null 2>&1 \
          && printf '  %s: decided by the captain: %s\n' "$tid" "$answer"
      fi
      _FF_MOVED=1
      continue
    fi
    # A reviewer the captain released after a FAIL: the answer asks for one more redo of the build.
    if [ -n "$answer" ] && [ -n "$(printf '%s' "$t" | _ff_jq -r '.verdict_failed.target // ""')" ]; then
      _ff_review_failed "$plan" "$tid" "$tasks" captain && _FF_MOVED=1
      continue
    fi
    [ "$active" -lt "$max" ] || continue
    # Optional resource gate (profile "gate" / OSRC_FACTORY_GATE): when it says no, launches pause
    # but holds, lands and decisions above still run. Tasks stay todo; nothing is marked failed.
    if [ "$gate_ok" != 1 ]; then
      [ "$gate_said" = 1 ] || { printf '  launches paused: %s\n' "${_OSRC_FP_GATE_REASON:-the resource gate said no}"; gate_said=1; }
      continue
    fi
    # File overlap vs running tasks and tasks picked this pass.
    cf="$(_osrc_fp_task_files "$plan" "$tid")"; cp=""
    if [ -n "$cf" ]; then
      for oid in $owners $picked; do
        [ "$oid" != "$tid" ] || continue
        of="$(_osrc_fp_task_files "$plan" "$oid")"
        cp="$(_osrc_fp_conflict "$cf" "$of")"
        if [ -n "$cp" ]; then
          printf '  %s: waits — its files touch %s (%s); it starts after that work finishes\n' "$tid" "$oid" "$cp"
          break
        fi
      done
      [ -z "$cp" ] || continue
    fi
    # Model: skip one the exclude list now names; the stored fallbacks keep the stage's intent.
    m="$(_ff_next_model "$t" dispatch)"
    if [ "$m" != "$(printf '%s' "$t" | _ff_jq -r '.model // ""')" ]; then
      _task_update "$plan" "$tid" 'if .state != "todo" then error("moved") else . end | .model = $m' --arg m "$m" >/dev/null 2>&1 \
        && printf '  %s: model %s is excluded now; using %s\n' "$tid" "$(printf '%s' "$t" | _ff_jq -r '.model // "(none)"')" "${m:-whatever the router picks}"
    fi
    if [ "$(printf '%s' "$t" | _ff_jq -r '.require_verdict // false')" = true ]; then
      target="$(_ff_review_target "$t" "$(_task_list "$plan")")"
      if [ -n "$target" ]; then
        # review_rounds counts dispatches to review; _ff_review_failed caps them (escalation past
        # OSRC_FACTORY_REVIEW_ROUNDS, default 3).
        _task_update "$plan" "$tid" 'if .state != "todo" then error("moved") else . end
          | .reviewed_head = $h | .review_target = $t | .review_rounds = ((.review_rounds // 0) + 1)' \
          --arg h "$(_task_get "$plan" "$target" | _ff_jq -r '.head_sha // ""')" --arg t "$target" >/dev/null 2>&1 || continue
      fi
    fi
    out="$( _task_dispatch "$plan" "$tid" 2>&1 )"; rc=$?
    if [ "$rc" -eq 0 ]; then
      active=$((active + 1)); picked="$picked $tid"
      printf '  %s: started job %s\n' "$tid" "$(printf '%s' "$out" | tail -1)"
    else
      out="$(printf '%s' "$out" | tail -2 | tr '\n' ' ' | sed 's/^ERROR: //' | cut -c1-200)"
      t="$(_task_get "$plan" "$tid")"
      st="$(printf '%s' "$t" | _ff_jq -r '.state')"
      if [ "$st" = failed ]; then
        # A launch failure counts as a failed attempt: retried within the task's budget. The task
        # store marks it with launch_failed:true when it can; older stores leave the reason text.
        lf="$(printf '%s' "$t" | _ff_jq -r 'if has("launch_failed") then (.launch_failed | tostring) else ((.result // "") | test("did not launch") | tostring) end')"
        if [ "$lf" = true ]; then
          _ff_fail_or_retry "$plan" "$tid" "the worker did not launch: $out" "$(_ff_guard "$t")"
        else
          printf '  %s: could not start: %s\n' "$tid" "$out"
        fi
      elif [ "$st" = held ]; then printf '  %s: held for the captain: %s\n' "$tid" "$(printf '%s' "$t" | _ff_jq -r '.hold.reason // ""')"
      else printf '  %s: not started this pass (%s); will try again\n' "$tid" "$out"; fi
    fi
  done
}

# _ff_review_failed <plan> <reviewer-tid> <tasks-json>: the reviewer said FAIL. Send the build it
# reviewed back for a redo (with the reviewer's reason in its brief) and re-run the review after it,
# while the build still has retries left AND the review-round cap allows another round. Otherwise
# hold the reviewer with the exact commands. $1..$3 plus optional 4th arg "captain" = the captain
# asked for one more round (the captain's own answer IS the escalation; the cap does not apply).
#
# Review-round cap (lane osrc-l5-parallel): .review_rounds counts dispatches to review (set in
# _ff_dispatch). Past OSRC_FACTORY_REVIEW_ROUNDS (default 3) the next round needs an approved
# escalation record at <plan>/escalations/<reviewer>.json naming that round; until then the
# reviewer is held and a PENDING record is written so the ask is visible and durable.
_ff_review_failed() (
  local plan="$1" vt="$2" tasks="$3" who="${4:-}" v r target n retries rstate landed br head out note vnote answer cmds pd
  _plan_lock "$plan" || return 1
  trap '_plan_unlock "$plan"' EXIT
  _ff_pair_recover "$plan" || return 1
  v="$(_task_get "$plan" "$vt")" || return 1
  local expected="${5:-$v}" guard nv nt
  guard="$(_ff_guard "$expected")"
  printf '%s' "$v" | _ff_jq -e "$guard" >/dev/null || return 1
  if [ "$who" = captain ]; then
    [ "$(printf '%s' "$v" | _ff_jq -r .state)" = todo ] || return 1
  else
    [ "$(printf '%s' "$v" | _ff_jq -r .state)" = verifying ] || return 1
  fi
  pd="$(_plan_dir "$plan")"
  # This pass's verdict line; the reason stored at the last hold only when the captain asks for a redo.
  if [ "$who" = captain ]; then r="$(printf '%s' "$v" | _ff_jq -r '.verdict_failed.reason // ""')"
  else r="${_FF_VERDICT_LINE#VERDICT: FAIL}"; r="${r# - }"; fi
  [ -n "$r" ] || r="no reason given"
  answer="$(printf '%s' "$v" | _ff_jq -r '.hold.answer // ""')"
  # The build under review: the reviewer's direct dependencies that are build (ship) tasks.
  target="$(printf '%s' "$tasks" | _ff_jq -r --argjson d "$(printf '%s' "$v" | _ff_jq -c '.deps // []')" \
    '[.[] | select((.id as $i | $d | index($i)) != null) | select((.shape // "") == "ship") | .id] | if length == 1 then .[0] else "" end')"
  out="$OSRC_JOBS/$(printf '%s' "$v" | _ff_jq -r '.job // ""')/last.txt"
  [ -f "$out" ] || out="$pd/tasks/$vt/report.md"
  cmds="Accept the build anyway: $(_ff_cmd "$plan" task done "$vt" --force). One more redo: $(_ff_cmd "$plan" task release "$vt" --answer '"<what to fix>"'). Stop here: $(_ff_cmd "$plan" task cancel "$vt")"
  if [ -z "$target" ]; then
    _task_update "$plan" "$vt" '.verdict_failed = {target: "", reason: $r} | .result = ("reviewer said FAIL: " + $r)' --arg r "$r" >/dev/null 2>&1
    _ff_hold "$plan" "$vt" "the reviewer said FAIL ($r) and there is no single build task to redo. Read the review: $out. $cmds" || return 1
    return 0
  fi
  local t; t="$(_task_get "$plan" "$target")" || return 1
  rstate="$(printf '%s' "$t" | _ff_jq -r '.state')"; landed="$(printf '%s' "$t" | _ff_jq -r '.landed // false')"
  n="$(_ff_num "$(_ff_attempts "$t")" 0)"; retries="$(_ff_num "$(printf '%s' "$t" | _ff_jq -r '.retries // 0')" 0)"
  if [ "$rstate" != done ] || [ "$landed" = true ] || { [ "$who" != captain ] && [ "$n" -gt "$retries" ]; }; then
    local why="its redo budget is used up ($n attempt(s))"
    [ "$rstate" != done ] && why="$target is $rstate, not done"
    [ "$landed" = true ] && why="$target has already landed"
    _task_update "$plan" "$vt" '.verdict_failed = {target: $t, reason: $r} | .result = ("reviewer said FAIL: " + $r)' \
      --arg t "$target" --arg r "$r" >/dev/null 2>&1
    _ff_hold "$plan" "$vt" "the reviewer said FAIL on $target ($r); $why. Read the review: $out. $cmds" || return 1
    return 0
  fi
  # Review-round cap: the redo below starts another review round. Past the cap (default 3) it needs
  # an approved escalation record naming that round; the captain's own redo request skips this gate.
  if [ "$who" != captain ]; then
    local rounds need cap ep
    rounds="$(_ff_num "$(printf '%s' "$v" | _ff_jq -r '.review_rounds // 0')" 0)"
    cap="$(_osrc_fp_review_cap)"; need=$(( rounds + 1 ))
    if [ "$need" -gt "$cap" ] && ! _osrc_fp_escalation_ok "$plan" "$vt" "$need"; then
      ep="$(_osrc_fp_escalation_write "$plan" "$vt" "$need" "review round $need of $target after FAIL: $r" 2>/dev/null)"
      [ -n "$ep" ] || ep="$(_osrc_fp_esc_path "$plan" "$vt")"
      _task_update "$plan" "$vt" '.verdict_failed = {target: $t, reason: $r} | .result = ("review round cap (" + $cap + ") reached; round " + $n + " needs an escalation: " + $r)' \
        --arg t "$target" --arg r "$r" --arg n "$need" --arg cap "$cap" >/dev/null 2>&1
      _ff_hold "$plan" "$vt" "the review cap is $cap round(s) and round $need of $target would be next (the reviewer said FAIL: $r). Approve it with an escalation record at $ep — set \"approved\": true and \"round\": $need — or decide yourself: $(_ff_cmd "$plan" task release "$vt" --answer '"<your decision>"'). $cmds" || return 1
      return 0
    fi
  fi
  br="$(printf '%s' "$t" | _ff_jq -r '.branch // ""')"; head="$(printf '%s' "$t" | _ff_jq -r '.head_sha // ""')"
  note="A reviewer ($vt) did not pass your previous attempt: $r"
  [ -n "$answer" ] && note="$note
The captain adds: $answer"
  note="$note
Full review: $out"
  [ -n "$br" ] && note="$note
Your previous attempt is on branch $br${head:+ at commit $head}; you may start from it (for example: git merge $br) and fix what the reviewer found."
  # The build goes back in line with the review in its prompt (replaced, never piled up); its retries
  # budget counts this redo. The captain's extra round raises the budget by one so the count stays honest.
  nt="$(printf '%s' "$t" | _ff_jq -c \
    'if .state != "done" or (.landed // false) then error("moved") else . end
     | .prompt_orig = (.prompt_orig // .prompt)
     | .prompt = (.prompt_orig + "\n\n## Review of your previous attempt\n\n" + $note)
     | .state = "todo" | .job = "" | .worktree = "" | .branch = "" | .base_sha = "" | .head_sha = "" | .evidence = ""
     | .result = "" | del(.land_error) | (if $cap == "1" then .retries = ((.retries // 0) + 1) else . end)' \
    --arg note "$note" --arg cap "$( [ "$who" = captain ] && echo 1 || echo 0)")" || return 1
  vnote="You reviewed an earlier attempt of $target and failed it: $r
That build was redone. Review the new attempt from scratch, and check that this problem is fixed."
  nv="$(printf '%s' "$v" | _ff_jq -c \
    '.prompt_orig = (.prompt_orig // .prompt)
     | .prompt = (.prompt_orig + "\n\n## Earlier review\n\n" + $note)
     | .state = "todo" | .job = "" | .evidence = "" | .result = "" | del(.verdict_failed)
     | .hold = ((.hold // {}) + {answer: ""}) | del(.verifying_at) | del(.verifying_pid, .verifying_start, .verifying_token)
     | .attempt_base = ([(.attempts // 0), ((.jobs // []) | length)] | max)' \
    --arg note "$vnote")" || return 1
  _ff_pair_commit "$plan" "$t" "$nt" "$v" "$nv" || return 1
  _ff_event "$plan" "$vt" review-failed "redo $target: $r"
  printf '  %s: reviewer said FAIL (%s); %s goes back for a redo, then %s reviews again\n' "$vt" "$r" "$target" "$vt"
  _FF_MOVED=1
)
