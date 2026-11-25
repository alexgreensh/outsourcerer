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
#         [| hold=question]
# `after` names keys of EARLIER lines, so a list can never form a cycle. Tasks with no `after` and no
# shared files start together, up to the launch cap. Tasks sharing files wait for the earlier one;
# the order and its reason are printed before anything starts. The default `check` is the repo
# profile's free local check (lib/factory-parallel.sh), when one is declared.
# Default: one scheduler pass (`plan run --once`), which launches the first wave in parallel and
# returns; `plan run <plan>` (or the heartbeat) keeps driving it. --run drives it to the end here.

_osrc_fs_usage() {
  echo 'usage: plan start <plan> <tasks-file|-> [--goal "..."] [--max-parallel N] [--run] [--dry-run]'
  echo '  each line: <key> | <what to do> [| after=k1,k2] [| files=a,b] [| shape=ship|scout] [| hold=question] ...'
}

# _osrc_fs_trim <text> -> without leading and trailing blanks.
_osrc_fs_trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; printf '%s' "${v%"${v##*[![:space:]]}"}"; }

# _osrc_fs_parse <file> -> validated rows "key<FS>prompt<FS>after<FS>files<FS>extra-args" (FS = \036, never
# whitespace, so empty fields survive `read`). after/files are comma lists; extra-args is
# "--opt<US>value<US>..." (US = \037). die on errors.
_osrc_fs_parse() {
  local file="$1" line n=0 key prompt f k v after files extra seen=" " a us
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
    after=""; files=""; extra=""
    while [ -n "$line" ]; do
      f="$(_osrc_fs_trim "${line%%|*}")"
      case "$line" in *'|'*) line="${line#*|}" ;; *) line="" ;; esac
      [ -n "$f" ] || continue
      case "$f" in *=*) ;; *) die "plan start: line $n ($key): '$f' is not key=value" ;; esac
      k="$(_osrc_fs_trim "${f%%=*}")"; v="$(_osrc_fs_trim "${f#*=}")"
      case "$k" in
        after) after="$(printf '%s' "$v" | tr -d ' ')"
          for a in $(printf '%s' "$after" | tr ',' ' '); do
            case "$seen" in *" $a "*) ;; *) die "plan start: line $n ($key): after=$a names no earlier line (list a task before the tasks that wait for it)" ;; esac
          done ;;
        files) files="$v" ;;
        shape|verb|model|provider|check|retries|hold) extra="$extra--$k$us$v$us" ;;
        *) die "plan start: line $n ($key): unknown field '$k' (after, files, shape, verb, model, provider, check, retries, hold)" ;;
      esac
    done
    case "$extra" in *"--shape$us"*) ;; *) [ -z "$files" ] || extra="$extra--shape${us}ship$us" ;; esac
    seen="$seen$key "
    printf '%s\036%s\036%s\036%s\036%s\n' "$key" "$prompt" "$after" "$files" "$extra"
  done < "$file"
  [ "$seen" != " " ] || die "plan start: $file lists no tasks"
}

# _osrc_fs_order <rows> -> one line per task: when it starts and why. Mirrors the scheduler: declared
# `after` first, then the first earlier task whose files collide (_osrc_fp_conflict).
_osrc_fs_order() {
  local rows="$1" key prompt after files extra k2 p2 a2 f2 e2 cp why
  while IFS="$(printf '\036')" read -r key prompt after files extra; do
    why=""
    [ -z "$after" ] || why="after $(printf '%s' "$after" | sed 's/,/, /g') (declared)"
    if [ -z "$why" ] && [ -n "$files" ]; then
      while IFS="$(printf '\036')" read -r k2 p2 a2 f2 e2; do
        [ "$k2" != "$key" ] || break
        cp="$(_osrc_fp_conflict "$(printf '%s' "$files" | tr ',' '\n' | sed 's#^ *##; s# *$##; s#^\./##; s#/*$##')" \
                                "$(printf '%s' "$f2" | tr ',' '\n' | sed 's#^ *##; s# *$##; s#^\./##; s#/*$##')")"
        [ -z "$cp" ] || { why="after $k2 (both touch $cp)"; break; }
      done <<EOF
$rows
EOF
    fi
    printf '  %-16s %s\n' "$key" "${why:-starts now}"
  done <<EOF
$rows
EOF
}

cmd_plan_start() {
  local plan="" file="" goal="" max="" run=0 dry=0 rows key prompt after files extra tid deps a map=" " us out
  local -a args
  while [ $# -gt 0 ]; do
    case "$1" in
      --goal) _factory_optval "$1" $#; goal="$2"; shift 2 ;;
      --max-parallel) _factory_optval "$1" $#; max="$2"; shift 2 ;;
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
  _plan_cli_new "$plan" ${goal:+--goal "$goal"} >/dev/null || return 1
  us="$(printf '\037')"
  while IFS="$(printf '\036')" read -r key prompt after files extra; do
    deps=""
    for a in $(printf '%s' "$after" | tr ',' ' '); do
      deps="$deps,$(printf '%s' "$map" | tr ' ' '\n' | sed -n "s/^$a=//p")"
    done
    args=()
    while [ -n "$extra" ]; do args+=("${extra%%"$us"*}"); extra="${extra#*"$us"}"; done
    case " ${args[*]+${args[*]}} " in *" --check "*) ;; *)
      [ -z "$(_osrc_fp_check)" ] || args+=(--check "$(_osrc_fp_check)") ;; esac
    out="$(_task_cli_add "$key" --prompt "$prompt" --plan "$plan" ${deps:+--deps "${deps#,}"} ${files:+--files "$files"} \
      ${args[@]+"${args[@]}"} 2>&1)" || die "plan start: could not add '$key': $(printf '%s' "$out" | tail -1). Plan '$plan' holds the tasks added so far."
    tid="$(printf '%s\n' "$out" | grep -E '^t[0-9]+$' | head -1)"
    [ -n "$tid" ] || die "plan start: '$key' was added but no task id came back: $out"
    map="$map$key=$tid "
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
