# factory-start.sh: `plan start`, the one entry from a list of tasks to a running plan (lane osrc-l5).
# Reached through cmd_plan's `cmd_plan_<sub>` dispatch in factory-tasks.sh. It only calls the task store
# (_plan_cli_new, _task_cli_add) and the scheduler (cmd_plan_run), so the old flow stays the one path:
# every task still goes through `task add`, every launch through `plan run`.
#
#   outsourcerer plan start <plan> <tasks-file|-> [--goal "..."] [--max-parallel N] [--run] [--dry-run]
#
# A tasks file has one task per line; blank lines and lines starting with # are skipped:
#   <key> | <what to do> [| after=k1,k2] [| files=src/a.sh,docs/] [| shape=ship|scout]
#         [| verb=run|research|edit|yolo] [| model=m] [| provider=p] [| check=cmd] [| retries=N]
#         [| hold=question [| default=answer | until=+2h] [| risk=reversible|irreversible|paid|publish]]
# `after` names keys of EARLIER lines, so a list can never form a cycle. Tasks with no `after` start
# together, up to the launch cap. Shared `files` never order tasks (each ship task branches from the
# plan base, so waiting would not give it the earlier work); the overlap is reported instead. hold=
# with default= and until= goes ahead with the default at the deadline unless risk= is
# irreversible/paid/publish. The default `check` is the repo profile's (lib/factory-parallel.sh).
# Default: one `plan run --once` pass, which launches the first wave and returns; --run drives the
# plan to the end. A rerun reuses the plan and skips keys that are already task titles in it.

_osrc_fs_usage() {
  echo 'usage: plan start <plan> <tasks-file|-> [--goal "..."] [--max-parallel N] [--run] [--dry-run]'
  echo '  each line: <key> | <what to do> [| after=k1,k2] [| files=a,b] [| shape=ship|scout] [| hold=question] ...'
}

# _osrc_fs_conflict <list-a> <list-b> (one path per line) -> "a -> b" for the first pair that is equal
# or nested (one a folder of the other), nothing when disjoint.
_osrc_fs_conflict() {
  awk 'NR == FNR { if ($0 != "") a[++n] = $0; next } $0 != "" { for (i = 1; i <= n; i++)
    if (a[i] == $0 || index(a[i], $0 "/") == 1 || index($0, a[i] "/") == 1) { print a[i] " -> " $0; exit } }' \
    <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

# _osrc_fs_lookup <map> <key> -> the value of "key=value" in a space-separated map (exact key match).
_osrc_fs_lookup() {
  local w
  for w in $1; do case "$w" in "$2="*) printf '%s' "${w#"$2="}"; return 0 ;; esac; done
}

# _osrc_fs_trim <text> -> without leading and trailing blanks.
_osrc_fs_trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; printf '%s' "${v%"${v##*[![:space:]]}"}"; }

# _osrc_fs_parse <file> -> validated rows "key<FS>prompt<FS>after<FS>files<FS>extra-args<FS>hold" (FS = \036,
# never whitespace, so empty fields survive `read`). after/files are comma lists; extra-args and hold
# are "--opt<US>value<US>..." (US = \037); hold is `task hold`'s args when default/until/risk is set.
_osrc_fs_parse() {
  local file="$1" line n=0 key prompt f k v after files extra seen=" " a us hq hold
  us="$(printf '\037')"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="$(_osrc_fs_trim "$(printf '%s' "$line" | tr -d '\r')")"
    case "$line" in ''|\#*) continue ;; *'|'*) ;; *) die "plan start: line $n needs '<key> | <what to do>'" ;; esac
    key="$(_osrc_fs_trim "${line%%|*}")"; line="${line#*|}"
    prompt="$(_osrc_fs_trim "${line%%|*}")"
    case "$line" in *'|'*) line="${line#*|}" ;; *) line="" ;; esac
    case "$key" in ''|*[!A-Za-z0-9_.-]*) die "plan start: line $n: key '$key' may hold only letters, digits, dot, dash and underscore" ;; esac
    case "$seen" in *" $key "*) die "plan start: line $n: key '$key' is used twice" ;; esac
    [ -n "$prompt" ] || die "plan start: line $n ($key) says nothing to do"
    after=""; files=""; extra=""; hq=""; hold=""
    while [ -n "$line" ]; do
      f="$(_osrc_fs_trim "${line%%|*}")"
      case "$line" in *'|'*) line="${line#*|}" ;; *) line="" ;; esac
      [ -n "$f" ] || continue
      case "$f" in *=*) ;; *) die "plan start: line $n ($key): '$f' is not key=value" ;; esac
      k="$(_osrc_fs_trim "${f%%=*}")"; v="$(_osrc_fs_trim "${f#*=}")"
      case "$k" in
        after) after="$(printf '%s' "$v" | tr -d ' ')"
          case "$after" in *[!A-Za-z0-9_.,-]*) die "plan start: line $n ($key): after=$after may list only keys, separated by commas" ;; esac
          for a in $(printf '%s' "$after" | tr ',' ' '); do
            case "$seen" in *" $a "*) ;; *) die "plan start: line $n ($key): after=$a names no earlier line (list a task before the tasks that wait for it)" ;; esac
          done ;;
        files) files="$v" ;;
        shape|verb|model|provider|check|retries) extra="$extra--$k$us$v$us" ;;
        hold) hq="$v"; extra="$extra--hold$us$v$us" ;;
        default|until|risk) hold="$hold--$k$us$v$us" ;;
        *) die "plan start: line $n ($key): unknown field '$k' (after, files, shape, verb, model, provider, check, retries, hold, default, until, risk)" ;;
      esac
    done
    [ -z "$hold" ] || [ -n "$hq" ] || die "plan start: line $n ($key): default=, until= and risk= belong to a hold=question"
    [ -z "$hold" ] || hold="--reason$us$hq$us$hold"
    case "$extra" in *"--shape$us"*) ;; *) [ -z "$files" ] || extra="$extra--shape${us}ship$us" ;; esac
    seen="$seen$key "
    printf '%s\036%s\036%s\036%s\036%s\036%s\n' "$key" "$prompt" "$after" "$files" "$extra" "$hold"
  done < "$file"
  [ "$seen" != " " ] || die "plan start: $file lists no tasks"
}

# _osrc_fs_files <comma-list> -> one normalized path per line.
_osrc_fs_files() { printf '%s' "$1" | tr ',' '\n' | sed 's#^ *##; s# *$##; s#^\./##; s#/*$##'; }

# _osrc_fs_order <rows> -> one line per task: "starts now" or its declared `after`, then a note for
# every pair of tasks whose files overlap (they still run side by side; nothing orders by files).
_osrc_fs_order() {
  local rows="$1" key prompt after files extra hold k2 p2 a2 f2 e2 h2 cp
  while IFS="$(printf '\036')" read -r key prompt after files extra hold; do
    if [ -n "$after" ]; then printf '  %-16s after %s (declared)\n' "$key" "$(printf '%s' "$after" | sed 's/,/, /g')"
    else printf '  %-16s starts now\n' "$key"; fi
  done <<EOF
$rows
EOF
  while IFS="$(printf '\036')" read -r key prompt after files extra hold; do
    [ -n "$files" ] || continue
    while IFS="$(printf '\036')" read -r k2 p2 a2 f2 e2 h2; do
      [ "$k2" != "$key" ] || break
      cp="$(_osrc_fs_conflict "$(_osrc_fs_files "$files")" "$(_osrc_fs_files "$f2")")"
      [ -n "$cp" ] || continue
      printf '  note: %s and %s both touch %s\n' "$key" "$k2" "$cp"
    done <<EOF
$rows
EOF
  done <<EOF
$rows
EOF
}

cmd_plan_start() {
  local plan="" file="" goal="" max="" run=0 dry=0 rows key prompt after files extra hold tid deps a map=" " us out reuse=0
  local -a args
  while [ $# -gt 0 ]; do
    case "$1" in
      --goal) _factory_optval "$1" $# || return 1; goal="$2"; shift 2 ;;
      --max-parallel) _factory_optval "$1" $# || return 1; max="$2"; shift 2 ;;
      --run) run=1; shift ;;
      --dry-run) dry=1; shift ;;
      -h|--help) _osrc_fs_usage; return 0 ;;
      -?*) die "plan start: unknown option '$1'. $(_osrc_fs_usage | head -1)" ;;
      *) if [ -z "$plan" ]; then plan="$1"; elif [ -z "$file" ]; then file="$1"; else die "plan start: too many arguments. $(_osrc_fs_usage | head -1)"; fi; shift ;;
    esac
  done
  [ -n "$plan" ] && [ -n "$file" ] || die "$(_osrc_fs_usage | head -1)"
  max="$(_osrc_fp_max_parallel "$max")" || return 1
  if [ "$file" = - ]; then rows="$(_osrc_fs_parse /dev/stdin)" || return 1
  else [ -f "$file" ] || die "plan start: no such tasks file: $file"; rows="$(_osrc_fs_parse "$file")" || return 1; fi
  echo "Order (up to $max at once; ready tasks start together):"
  _osrc_fs_order "$rows"
  [ "$dry" = 0 ] || { echo "(dry run: nothing was created)"; return 0; }
  # An existing plan is reused when it holds some of these tasks, or none at all (a first `task add`
  # that failed right after the plan was created: the message says to rerun the same list).
  if [ -f "$(_plan_dir "$plan")/plan.json" ]; then
    _task_list "$plan" | _osrc_fp_jq -e --argjson ks "$(printf '%s\n' "$rows" | cut -d "$(printf '\036')" -f1 | jq -R . | jq -cs .)" \
      'length == 0 or any(.[]; .title as $t | $ks | index($t))' >/dev/null 2>&1 \
      || die "plan start: plan '$plan' already exists and none of its tasks are in $file. Pick a new plan name (or add tasks with task add)."
    [ -z "$goal" ] || echo "plan '$plan' exists, so --goal is ignored (the plan keeps its goal)."
    reuse=1; echo "plan '$plan' exists; tasks already in it are kept, the rest are added."
  else _plan_cli_new "$plan" ${goal:+--goal "$goal"} >/dev/null || return 1; fi
  us="$(printf '\037')"
  while IFS="$(printf '\036')" read -r key prompt after files extra hold; do
    if [ "$reuse" = 1 ]; then
      tid="$(_task_list "$plan" | _osrc_fp_jq -r --arg k "$key" '[.[] | select(.title == $k)] | first | .id // empty')"
      if [ -n "$tid" ]; then map="$map$key=$tid "; continue; fi
    fi
    deps=""
    for a in $(printf '%s' "$after" | tr ',' ' '); do deps="$deps,$(_osrc_fs_lookup "$map" "$a")"; done
    args=()
    while [ -n "$extra" ]; do args+=("${extra%%"$us"*}"); extra="${extra#*"$us"}"; done
    case " ${args[*]+${args[*]}} " in *" --check "*) ;; *)
      [ -z "$(_osrc_fp_check)" ] || args+=(--check "$(_osrc_fp_check)") ;; esac
    out="$(_task_cli_add "$key" --prompt "$prompt" --plan "$plan" ${deps:+--deps "${deps#,}"} ${files:+--files "$files"} \
      ${args[@]+"${args[@]}"} 2>&1)" || die "plan start: could not add '$key': $(printf '%s' "$out" | tail -1). Rerun the same list to finish the plan."
    tid="$(printf '%s\n' "$out" | grep -E '^t[0-9]+$' | head -1)"
    [ -n "$tid" ] || die "plan start: '$key' was added but no task id came back: $out"
    map="$map$key=$tid "
    # The task is already held (--hold); this adds its default, deadline and risk. On failure it stays
    # held for the captain, which is the safe side.
    [ -n "$hold" ] || continue
    args=(); while [ -n "$hold" ]; do args+=("${hold%%"$us"*}"); hold="${hold#*"$us"}"; done
    out="$(_task_cli_hold "$tid" --plan "$plan" "${args[@]}" 2>&1)" \
      || die "plan start: '$key' is held, but its default could not be set: $(printf '%s' "$out" | tail -1)"
  done <<EOF
$rows
EOF
  echo "plan '$plan' holds $(printf '%s' "$map" | wc -w | tr -d ' ') task(s):$(printf '%s' "$map" | sed 's/=/ -> /g')"
  if [ "$run" = 1 ]; then cmd_plan_run "$plan" --max-parallel "$max"; return $?; fi
  cmd_plan_run "$plan" --once --max-parallel "$max"
  local rc=$?
  [ "$rc" = 124 ] && { echo "Keep it moving with: outsourcerer plan run $plan   (or let the heartbeat drive it)"; return 0; }
  return "$rc"
}
