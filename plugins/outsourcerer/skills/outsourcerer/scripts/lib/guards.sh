# lib/guards.sh — repo guards: small scripts that fail a lane's change with a teaching message.
#
#   outsourcerer guards run [--base REF] [--mode off|observe|enforce] [--json] [--allow "<reason>"]
#                           [--lane ID]
#   outsourcerer guards list [--base REF]
#
# Run inside a lane worktree. Every guard sees one unified diff: the merge-base of <base> and HEAD
# against the working tree (so committed, staged and unstaged changes) plus untracked files. The diff
# is taken with --text --no-textconv --no-ext-diff --no-renames and core.quotePath=false, so a lane's
# .gitattributes cannot hide a file, a rename shows as delete + add, and non-ASCII names are scanned.
#
# A lane cannot edit its own checks. Guards and their config are read from the BASE ref with
# `git show <base>:...` into a temp dir, never from the worktree. A diff that touches
# .outsourcerer/guards/ (incl. guards/slop.allow), .outsourcerer/guards.conf, any .gitattributes,
# .file-size-allow or scripts/check_file_size.py is reported as guards_changed for the reviewer; the
# lane's copy never runs. Callers must pin --base to the branch the lane merges into: a base naming
# HEAD or the checked-out branch is refused (exit 2), because it would read the lane's own guards.
#
# Guards: built-ins ship in lib/guards/ (slop, slop-inflation, file-size); a repo adds its own in
# .outsourcerer/guards/ as <name>.sh, <name>.py or a file starting with #! (anything else there, such
# as slop.allow, is data). A repo guard overrides a built-in of the same name. lib/git-exclude.sh keeps
# these committable without -f.
# Contract for a guard: cwd = repo top; env OSRC_GUARD_DIFF (diff file), OSRC_GUARD_FILES (changed
# paths, one per line), OSRC_GUARD_BASE (merge-base sha), OSRC_GUARD_BASE_REF, OSRC_GUARD_CFGDIR
# (base copies of guards.conf / guards/slop.allow / .file-size-allow), OSRC_GUARD_TMP (scratch).
# Exit 0 = pass; non-zero = fail, printing `WHAT: <line>` lines and `FIX: <how to do it right>` lines
# (joined with " | "). Bound: 120 s (OSRC_GUARDS_SECS); a timeout is a failure.
#
# Modes, per guard: --mode overrides all; else `<guard> = <mode>` in guards.conf (from base); else the
# built-in's own default (slop = enforce: narration, excuse, unrequested markdown; slop-inflation =
# observe; file-size = observe); else `default = <mode>` there; else observe. off = skip; observe = log
# what would block to $OSRC_HOME/guard-state/observe.log and pass; enforce = exit 1 on failure.
#
# Never strands work: --allow "<reason>" passes an enforce failure and records the reason. A block is
# counted only for a diff not blocked before (its hash is stored in
# $OSRC_HOME/guard-state/blocks/<lane>); rerunning an unchanged diff stays blocked and is not counted.
# After 2 counted blocks the next NEW diff passes as "allowed after 2 blocks". Both are recorded in
# $OSRC_HOME/guard-state/allowed.log and set `allowed` + `reviewer_required` in the JSON. State lives in
# guard-state/, never under a guards/ dir, so it can never be collected or committed as a guard.
# Lane id: --lane, else $OSRC_LANE, else the branch name.
#
# Exit: 0 = pass (incl. observe failures, --allow, 2-block release); 1 = blocked; 2 = usage/error.
#
# JSON (--json; the ONLY stdout line, human lines go to stderr). Stable contract, consumed by the
# done check / proof run (lane S2). Extra keys may be added; these never change meaning:
#   { "mode":    "off|observe|enforce"   strongest mode among the guards that ran,
#     "passed":  bool                    the gate verdict: true exactly when exit is 0,
#     "failed":  [ { "guard": name, "mode": m, "what": [lines], "fix": "how to do it right" } ],
#     "guards_changed": bool,  "guards_changed_paths": [paths],
#     "allowed": null | "<reason>"      set when --allow or the 2-block release let a block pass,
#     "reviewer_required": bool          allowed != null or guards_changed: a person must look,
#     "ran": [names], "skipped": [names], "base": ref, "base_sha": sha, "lane": id, "elapsed_s": n }

_OSRC_GUARDS_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/guards"

_osrc_guards_state() { printf '%s/guard-state' "${OSRC_HOME:-$HOME/.outsourcerer}"; }
_osrc_guards_git() { git -c core.quotePath=false "$@"; }

_osrc_guards_usage() {
  cat >&2 <<'EOF'
usage: outsourcerer guards run [--base REF] [--mode off|observe|enforce] [--json] [--allow "<reason>"] [--lane ID]
       outsourcerer guards list [--base REF]
EOF
}

# _osrc_guards_own_branch <ref>: 0 when <ref> is HEAD itself or the checked-out branch.
_osrc_guards_own_branch() {
  local cur full
  case "$1" in HEAD|@|HEAD^0|@^0) return 0 ;; esac
  cur="$(git symbolic-ref -q HEAD 2>/dev/null)" || return 1
  full="$(git rev-parse --symbolic-full-name "$1" 2>/dev/null)"
  [ -n "$full" ] && [ "$full" = "$cur" ]
}

# _osrc_guards_default_base -> first of $OSRC_GUARDS_BASE origin/main origin/master main master that
# exists and is not the lane's own branch.
_osrc_guards_default_base() {
  local c
  for c in ${OSRC_GUARDS_BASE:-} origin/main origin/master main master; do
    _osrc_guards_own_branch "$c" && continue
    git rev-parse -q --verify "$c^{commit}" >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# _osrc_guards_resolve_base <ref-or-empty> -> prints the base ref, or explains and returns 2.
_osrc_guards_resolve_base() {
  local base="$1"
  [ -n "$base" ] || base="$(_osrc_guards_default_base)" || { echo "guards: no base ref (pass --base)" >&2; return 2; }
  if _osrc_guards_own_branch "$base"; then
    echo "guards: --base $base is the lane's own branch, so its guards would come from the lane; pin --base to the branch the lane merges into" >&2
    return 2
  fi
  git rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || { echo "guards: base $base not found" >&2; return 2; }
  printf '%s' "$base"
}

# _osrc_guards_conf_get <conf-file> <key> -> value of `key = value` / `key value` (last wins).
_osrc_guards_conf_get() {
  [ -f "$1" ] || return 1
  awk -v k="$2" '{ sub(/#.*/, "") } { line = $0; sub(/^[ \t]+/, "", line) }
    { n = index(line, k) } n == 1 { rest = substr(line, length(k) + 1)
      if (rest ~ /^[ \t]*[=: \t]/) { sub(/^[ \t]*[=:]?[ \t]*/, "", rest); sub(/[ \t]+$/, "", rest); v = rest; f = 1 } }
    END { if (f) print v; else exit 1 }' "$1"
}

_osrc_guards_builtin_mode() {
  case "$1" in slop) printf enforce ;; slop-inflation|file-size) printf observe ;; *) return 1 ;; esac
}

_osrc_guards_mode_for() { # <name> <cfgdir> <flag-mode> <guard-path>
  local m="$3"
  [ -n "$m" ] || m="$(_osrc_guards_conf_get "$2/guards.conf" "$1" 2>/dev/null)"
  case "$m" in off|observe|enforce) printf '%s' "$m"; return ;; esac
  case "$4" in "$_OSRC_GUARDS_LIBDIR"/*) m="$(_osrc_guards_builtin_mode "$1")" && { printf '%s' "$m"; return; } ;; esac
  m="$(_osrc_guards_conf_get "$2/guards.conf" default 2>/dev/null)"
  case "$m" in off|observe|enforce) printf '%s' "$m" ;; *) printf observe ;; esac
}

# _osrc_guards_collect <base> <dest-dir>: built-ins, then the base ref's .outsourcerer/guards/ blobs
# that are guards (*.sh, *.py, or #!); same name overrides. Writes `<name>\t<path>` lines to <dest>/list.
_osrc_guards_collect() {
  local base="$1" d="$2" f n type sha path line
  mkdir -p "$d/repo" || return 1
  : >"$d/list.raw"
  for f in "$_OSRC_GUARDS_LIBDIR"/*.sh "$_OSRC_GUARDS_LIBDIR"/*.py; do
    [ -f "$f" ] || continue
    n="$(basename "$f")"; printf '%s\t%s\n' "${n%.*}" "$f" >>"$d/list.raw"
  done
  while IFS= read -r -d '' line; do
    line="${line#* }"; type="${line%% *}"; line="${line#* }"
    sha="${line%%	*}"; path="${line#*	}"
    [ "$type" = blob ] || continue
    f="$(basename "$path")"
    case "$f" in .*|*/*|'') continue ;; esac
    case "$f" in
      *.sh|*.py) ;;
      *) [ "$(git cat-file blob "$sha" 2>/dev/null | head -c 2)" = '#!' ] || continue ;;
    esac
    git cat-file blob "$sha" >"$d/repo/$f" 2>/dev/null || continue
    chmod 700 "$d/repo/$f"
    n="${f%.*}"; [ -n "$n" ] || n="$f"
    printf '%s\t%s\n' "$n" "$d/repo/$f" >>"$d/list.raw"
  done < <(git ls-tree -z "$base" -- .outsourcerer/guards/ 2>/dev/null)
  awk -F'\t' '{ if (!($1 in p)) o[++k] = $1; p[$1] = $2 } END { for (i = 1; i <= k; i++) print o[i] "\t" p[o[i]] }' \
    "$d/list.raw" >"$d/list"
}

_osrc_guards_exec() { # <path>: interpreter by extension, else the #! line
  case "$1" in
    *.py) python3 -I "$1" ;;
    *.sh) bash "$1" ;;
    *) "$1" ;;
  esac
}

_osrc_guards_log() { # <file> <line>
  local d; d="$(_osrc_guards_state)"
  mkdir -p "$d" 2>/dev/null && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" >>"$d/$1"
}

# _osrc_guards_diff <merge-base> <dir>: writes <dir>/diff and <dir>/files (one path per line).
_osrc_guards_diff() {
  local mb="$1" d="$2" u
  _osrc_guards_git diff --no-color --no-ext-diff --no-textconv --text --no-renames "$mb" -- . >"$d/diff" 2>/dev/null
  _osrc_guards_git diff --name-only -z --no-renames "$mb" -- . 2>/dev/null | tr '\0' '\n' >"$d/files"
  while IFS= read -r -d '' u; do
    [ -f "$u" ] || continue
    _osrc_guards_git diff --no-color --no-ext-diff --no-textconv --text --no-index -- /dev/null "$u" >>"$d/diff" 2>/dev/null
    printf '%s\n' "$u" >>"$d/files"
  done < <(_osrc_guards_git ls-files -z --others --exclude-standard 2>/dev/null)
}

# _osrc_guards_blocks <lane> <diff-hash> <allow-reason>: decides an enforce failure.
# Prints `allowed <reason>`, `blocked <n> new` or `blocked <n> same`.
_osrc_guards_blocks() {
  local f n hashes
  f="$(_osrc_guards_state)/blocks/$1"
  hashes="$(grep -E '^[0-9a-f]{40}([0-9a-f]{24})?$' "$f" 2>/dev/null)"
  n="$(awk 'NF { k++ } END { print k + 0 }' <<<"$hashes")"
  if [ -n "$3" ]; then rm -f "$f"; printf 'allowed %s\n' "$3"; return; fi
  if grep -qxF "$2" <<<"$hashes"; then printf 'blocked %s same\n' "$n"; return; fi
  if [ "$n" -ge 2 ]; then rm -f "$f"; printf 'allowed allowed after 2 blocks\n'; return; fi
  mkdir -p "${f%/*}" && printf '%s\n' "$2" >>"$f"
  printf 'blocked %s new\n' "$((n + 1))"
}

osrc_guards_run() {
  ( _OSRC_GUARDS_T=""
    trap 'rm -rf "${_OSRC_GUARDS_T:-/nonexistent}"' EXIT
    trap 'exit 130' INT TERM HUP
    _osrc_guards_run "$@" )
}

_osrc_guards_run() {
  local base="" flag_mode="" json=0 allow="" lane="${OSRC_LANE:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="${2:-}"; shift 2 || { _osrc_guards_usage; return 2; } ;;
      --mode) flag_mode="${2:-}"; shift 2 || { _osrc_guards_usage; return 2; }
        case "$flag_mode" in off|observe|enforce) ;; *) echo "guards: --mode must be off|observe|enforce" >&2; return 2 ;; esac ;;
      --json) json=1; shift ;;
      --allow) allow="${2:-}"; shift 2 || { _osrc_guards_usage; return 2; }
        [ -n "$allow" ] || { echo "guards: --allow needs a reason" >&2; return 2; } ;;
      --lane) lane="${2:-}"; shift 2 || { _osrc_guards_usage; return 2; } ;;
      -h|--help) _osrc_guards_usage; return 0 ;;
      *) echo "guards: unknown flag $1" >&2; _osrc_guards_usage; return 2 ;;
    esac
  done
  local top t0=$SECONDS
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "guards: not inside a git worktree" >&2; return 2; }
  cd "$top" || return 2
  base="$(_osrc_guards_resolve_base "$base")" || return 2
  local base_sha mb
  base_sha="$(git rev-parse -q --verify "$base^{commit}")"
  mb="$(git merge-base "$base_sha" HEAD 2>/dev/null)" || mb="$base_sha"
  [ -n "$lane" ] || lane="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "$lane" ] && [ "$lane" != HEAD ] || lane="$(basename "$top")"
  lane="$(printf '%s' "$lane" | tr -c 'A-Za-z0-9._-' '_')"

  local T; T="$(mktemp -d "${TMPDIR:-/tmp}/osrc-guards.XXXXXX")" || return 2
  _OSRC_GUARDS_T="$T"
  mkdir -p "$T/cfg" "$T/out" "$T/scratch"
  git show "$base_sha:.outsourcerer/guards.conf" >"$T/cfg/guards.conf" 2>/dev/null || rm -f "$T/cfg/guards.conf"
  git show "$base_sha:.outsourcerer/guards/slop.allow" >"$T/cfg/slop.allow" 2>/dev/null || rm -f "$T/cfg/slop.allow"
  git show "$base_sha:.file-size-allow" >"$T/cfg/.file-size-allow" 2>/dev/null || rm -f "$T/cfg/.file-size-allow"
  _osrc_guards_diff "$mb" "$T"

  local u changed_paths=""
  while IFS= read -r u; do
    case "$u" in .outsourcerer/guards/*|.outsourcerer/guards.conf|.gitattributes|*/.gitattributes|.file-size-allow|scripts/check_file_size.py)
      changed_paths="$changed_paths$u
" ;; esac
  done <"$T/files"

  _osrc_guards_collect "$base_sha" "$T/g"
  local name path mode rc top_mode=off ran="" skipped="" failed_json="" enforce_fail=0 secs="${OSRC_GUARDS_SECS:-120}"
  local human="$T/human" what fix i=0; : >"$human"
  printf 'guards: base %s (%s), lane %s, %s changed file(s)\n' "$base" "$(printf '%s' "$mb" | cut -c1-9)" "$lane" \
    "$(awk 'NF { n++ } END { print n + 0 }' "$T/files")" >>"$human"
  while IFS='	' read -r name path; do
    [ -n "$name" ] || continue
    mode="$(_osrc_guards_mode_for "$name" "$T/cfg" "$flag_mode" "$path")"
    if [ "$mode" = off ]; then skipped="$skipped$name
"; printf 'skip  %s [off]\n' "$name" >>"$human"; continue; fi
    ran="$ran$name
"
    case "$top_mode:$mode" in off:*|observe:enforce) top_mode="$mode" ;; esac
    rc=0; i=$((i + 1))
    if type _timeout >/dev/null 2>&1; then
      ( export OSRC_GUARD_DIFF="$T/diff" OSRC_GUARD_FILES="$T/files" OSRC_GUARD_BASE="$mb" OSRC_GUARD_BASE_REF="$base_sha" \
          OSRC_GUARD_CFGDIR="$T/cfg" OSRC_GUARD_TMP="$T/scratch"
        _timeout "$secs" _osrc_guards_exec "$path" </dev/null ) >"$T/out/$i" 2>&1 || rc=$?
    else
      ( export OSRC_GUARD_DIFF="$T/diff" OSRC_GUARD_FILES="$T/files" OSRC_GUARD_BASE="$mb" OSRC_GUARD_BASE_REF="$base_sha" \
          OSRC_GUARD_CFGDIR="$T/cfg" OSRC_GUARD_TMP="$T/scratch"
        _osrc_guards_exec "$path" </dev/null ) >"$T/out/$i" 2>&1 || rc=$?
    fi
    if [ "$rc" = 0 ]; then printf 'ok    %s [%s]\n' "$name" "$mode" >>"$human"; continue; fi
    what="$(sed -n 's/^WHAT: *//p' "$T/out/$i")"
    fix="$(sed -n 's/^FIX: *//p' "$T/out/$i" | awk 'NR > 1 { printf " | " } { printf "%s", $0 }')"
    if [ -z "$what" ]; then
      what="$(grep -v '^[[:space:]]*$' "$T/out/$i" | tail -5)"
      [ "$rc" = 124 ] && what="timed out after ${secs}s${what:+
$what}"
      [ -n "$what" ] || what="exit $rc"
    fi
    [ -n "$fix" ] || fix="read the guard's output and fix what it names"
    [ "$mode" = enforce ] && enforce_fail=1
    printf 'FAIL  %s [%s]%s\n' "$name" "$mode" "$([ "$mode" = observe ] && printf ' (observe: would block in enforce)')" >>"$human"
    printf '%s\n' "$what" | sed 's/^/      WHAT: /' >>"$human"
    printf '      FIX: %s\n' "$fix" >>"$human"
    [ "$mode" = observe ] && _osrc_guards_log observe.log "$lane $name would-block: $(printf '%s\n' "$what" | head -1)"
    failed_json="$failed_json$(jq -cn --arg g "$name" --arg m "$mode" --arg w "$what" --arg f "$fix" \
      '{guard:$g, mode:$m, what:($w | split("\n") | map(select(length > 0))), fix:$f}')
"
  done <"$T/g/list"

  [ -z "$changed_paths" ] || printf '%s' "$changed_paths" | sed '/^$/d; s/^/guards-changed: /; s/$/ (lane edited its own checks; the base copy ran; reviewer must look)/' >>"$human"

  local passed=true allowed="" verdict
  if [ "$enforce_fail" = 1 ]; then
    verdict="$(_osrc_guards_blocks "$lane" "$(git hash-object "$T/diff")" "$allow")"
    case "$verdict" in
      allowed\ *)
        allowed="${verdict#allowed }"
        _osrc_guards_log allowed.log "$lane allowed: $allowed"
        printf 'guards: ALLOWED past an enforce failure: %s (reviewer must look)\n' "$allowed" >>"$human" ;;
      *\ same)
        passed=false
        printf 'guards: BLOCKED again on an unchanged diff (not counted; %s of 2 blocks so far)\n' "$(set -- $verdict; echo "$2")" >>"$human" ;;
      *)
        passed=false
        printf 'guards: BLOCKED (block %s of 2; fix and rerun, or pass --allow "<reason>")\n' "$(set -- $verdict; echo "$2")" >>"$human" ;;
    esac
  else
    rm -f "$(_osrc_guards_state)/blocks/$lane" 2>/dev/null
    printf 'guards: PASS%s\n' "$([ -n "$failed_json" ] && printf ' (observe-only failures logged)')" >>"$human"
  fi

  local elapsed=$((SECONDS - t0))
  if [ "$json" = 1 ]; then
    cat "$human" >&2
    printf '%s' "$failed_json" | jq -cs --arg mode "$top_mode" --argjson passed "$passed" \
      --arg cp "$changed_paths" --arg allowed "$allowed" --arg ran "$ran" --arg sk "$skipped" \
      --arg base "$base" --arg bs "$base_sha" --arg lane "$lane" --argjson el "$elapsed" \
      '($cp | split("\n") | map(select(length > 0))) as $paths
       | {mode:$mode, passed:$passed, failed:., guards_changed:($paths | length > 0), guards_changed_paths:$paths,
          allowed:(if $allowed == "" then null else $allowed end),
          reviewer_required:($allowed != "" or ($paths | length > 0)),
          ran:($ran | split("\n") | map(select(length > 0))), skipped:($sk | split("\n") | map(select(length > 0))),
          base:$base, base_sha:$bs, lane:$lane, elapsed_s:$el}'
  else
    cat "$human"
  fi
  [ "$passed" = true ]
}

osrc_guards_list() {
  ( _OSRC_GUARDS_T=""; trap 'rm -rf "${_OSRC_GUARDS_T:-/nonexistent}"' EXIT; trap 'exit 130' INT TERM HUP
    local base="" T name path
    case "${1:-}" in --base) base="${2:-}" ;; esac
    cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null && [ -n "$(git rev-parse --show-toplevel 2>/dev/null)" ] \
      || { echo "guards: not inside a git worktree" >&2; exit 2; }
    base="$(_osrc_guards_resolve_base "$base")" || exit 2
    T="$(mktemp -d "${TMPDIR:-/tmp}/osrc-guards.XXXXXX")" || exit 2
    _OSRC_GUARDS_T="$T"; mkdir -p "$T/cfg"
    git show "$base:.outsourcerer/guards.conf" >"$T/cfg/guards.conf" 2>/dev/null || rm -f "$T/cfg/guards.conf"
    _osrc_guards_collect "$base" "$T/g"
    while IFS='	' read -r name path; do
      local shown="$path"
      case "$path" in "$T"/*) shown="$base:.outsourcerer/guards/$(basename "$path")" ;; esac
      printf '%-15s %-8s %s\n' "$name" "$(_osrc_guards_mode_for "$name" "$T/cfg" "" "$path")" "$shown"
    done <"$T/g/list" )
}

cmd_guards() {
  local sub="${1:-}"; [ $# -gt 0 ] && shift
  case "$sub" in
    run) osrc_guards_run "$@" ;;
    list|ls) osrc_guards_list "$@" ;;
    -h|--help|help) _osrc_guards_usage ;;
    "") _osrc_guards_usage; return 2 ;;
    *) echo "guards: unknown subcommand '$sub'" >&2; _osrc_guards_usage; return 2 ;;
  esac
}
