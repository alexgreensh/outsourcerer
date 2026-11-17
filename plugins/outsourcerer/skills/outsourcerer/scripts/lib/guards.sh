# lib/guards.sh — repo guards: small scripts that fail a lane's change with a teaching message.
#
#   outsourcerer guards run [--base REF] [--mode off|observe|enforce] [--json] [--allow "<reason>"]
#                           [--lane ID]
#   outsourcerer guards list [--base REF]
#
# Run inside a lane worktree. Every guard sees one unified diff: the merge-base of <base> and HEAD
# against the working tree (so committed, staged and unstaged changes) plus untracked files.
#
# A lane cannot edit its own checks. Guards and their config are read from the BASE ref with
# `git show <base>:...` into a temp dir, never from the worktree. A diff that touches
# .outsourcerer/guards/ (incl. guards/slop.allow), .outsourcerer/guards.conf, .file-size-allow or
# scripts/check_file_size.py is reported as guards_changed for the reviewer; the lane's copy never runs.
#
# Guards: built-ins ship in lib/guards/ (slop, file-size); a repo adds its own as files in
# .outsourcerer/guards/<name>[.sh|.py] (a repo guard overrides a built-in of the same name; *.allow,
# *.md, *.txt and dotfiles there are data, not guards). lib/git-exclude.sh keeps these addable without -f.
# Contract for a guard: cwd = repo top; env OSRC_GUARD_DIFF (diff file), OSRC_GUARD_FILES (changed
# paths, one per line), OSRC_GUARD_BASE (merge-base sha), OSRC_GUARD_BASE_REF, OSRC_GUARD_CFGDIR
# (base copies of guards.conf / guards/slop.allow), OSRC_GUARD_TMP (scratch). Exit 0 = pass; non-zero =
# fail, printing `WHAT: <line>` lines and `FIX: <how to do it right>` lines (joined with " | "). Bound: 120 s
# (OSRC_GUARDS_SECS); a timeout is a failure.
#
# Modes, per guard: --mode overrides all; else `<guard> = <mode>` in guards.conf (from base); else
# `default = <mode>` there; else observe. off = skip; observe = log what would block to
# $OSRC_HOME/guards/observe.log and pass; enforce = exit 1 on failure.
# Never strands work: --allow "<reason>" passes an enforce failure and records the reason; after 2
# enforce blocks for the same lane the next run passes, recording "allowed after 2 blocks". The
# block count lives in $OSRC_HOME/guards/blocks/<lane> and resets on any run that passes.
# Records: $OSRC_HOME/guards/allowed.log. Lane id: --lane, else $OSRC_LANE, else the branch name.
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
#     "ran": [names], "skipped": [names], "base": ref, "base_sha": sha, "lane": id, "elapsed_s": n }

_OSRC_GUARDS_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/guards"

_osrc_guards_dir() { printf '%s/guards' "${OSRC_HOME:-$HOME/.outsourcerer}"; }

_osrc_guards_usage() {
  cat >&2 <<'EOF'
usage: outsourcerer guards run [--base REF] [--mode off|observe|enforce] [--json] [--allow "<reason>"] [--lane ID]
       outsourcerer guards list [--base REF]
EOF
}

# _osrc_guards_default_base -> first ref of origin/main origin/master main master that exists.
_osrc_guards_default_base() {
  local c
  for c in ${OSRC_GUARDS_BASE:-} origin/main origin/master main master; do
    git rev-parse -q --verify "$c^{commit}" >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# _osrc_guards_conf_get <conf-file> <key> -> value of `key = value` / `key value` (last wins).
_osrc_guards_conf_get() {
  [ -f "$1" ] || return 1
  awk -v k="$2" '{ sub(/#.*/, "") } { line = $0; sub(/^[ \t]+/, "", line) }
    { n = index(line, k) } n == 1 { rest = substr(line, length(k) + 1)
      if (rest ~ /^[ \t]*[=: \t]/) { sub(/^[ \t]*[=:]?[ \t]*/, "", rest); sub(/[ \t]+$/, "", rest); v = rest; f = 1 } }
    END { if (f) print v; else exit 1 }' "$1"
}

_osrc_guards_mode_for() { # <name> <cfgdir> <flag-mode>
  local m="$3"
  [ -n "$m" ] || m="$(_osrc_guards_conf_get "$2/guards.conf" "$1" 2>/dev/null)"
  case "$m" in off|observe|enforce) ;; *) m="$(_osrc_guards_conf_get "$2/guards.conf" default 2>/dev/null)" ;; esac
  case "$m" in off|observe|enforce) printf '%s' "$m" ;; *) printf observe ;; esac
}

# _osrc_guards_collect <base> <dest-dir>: built-ins, then the base ref's .outsourcerer/guards/ blobs
# (same name overrides). Writes one `<name>\t<path>` line per guard to <dest-dir>/list.
_osrc_guards_collect() {
  local base="$1" d="$2" f n mode type sha path line
  mkdir -p "$d/repo" || return 1
  : >"$d/list.raw"
  for f in "$_OSRC_GUARDS_LIBDIR"/*; do
    [ -f "$f" ] || continue
    n="$(basename "$f")"; n="${n%.*}"
    printf '%s\t%s\n' "$n" "$f" >>"$d/list.raw"
  done
  while IFS= read -r line; do
    mode="${line%% *}"; line="${line#* }"; type="${line%% *}"; line="${line#* }"
    sha="${line%%	*}"; path="${line#*	}"
    [ "$type" = blob ] || continue
    f="$(basename "$path")"
    case "$f" in .*|*.md|*.txt|*.allow|README*) continue ;; esac
    git cat-file blob "$sha" >"$d/repo/$f" 2>/dev/null || continue
    chmod 700 "$d/repo/$f"
    n="${f%.*}"; [ -n "$n" ] || n="$f"
    printf '%s\t%s\n' "$n" "$d/repo/$f" >>"$d/list.raw"
  done < <(git ls-tree "$base" -- .outsourcerer/guards/ 2>/dev/null)
  # Last entry per name wins, order of first appearance kept.
  awk -F'\t' '{ if (!($1 in p)) o[++k] = $1; p[$1] = $2 } END { for (i = 1; i <= k; i++) print o[i] "\t" p[o[i]] }' \
    "$d/list.raw" >"$d/list"
}

_osrc_guards_exec() { # <path>: interpreter by extension or shebang
  case "$1" in
    *.py) python3 -I "$1" ;;
    *.sh) bash "$1" ;;
    *) if [ "$(head -c 2 "$1" 2>/dev/null)" = '#!' ]; then "$1"; else bash "$1"; fi ;;
  esac
}

_osrc_guards_log() { # <file> <line>
  local d; d="$(_osrc_guards_dir)"
  mkdir -p "$d" 2>/dev/null && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" >>"$d/$1"
}

osrc_guards_run() {
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
  [ -n "$base" ] || base="$(_osrc_guards_default_base)" || { echo "guards: no base ref (pass --base)" >&2; return 2; }
  local base_sha mb
  base_sha="$(git rev-parse -q --verify "$base^{commit}" 2>/dev/null)" || { echo "guards: base $base not found" >&2; return 2; }
  mb="$(git merge-base "$base_sha" HEAD 2>/dev/null)" || mb="$base_sha"
  [ -n "$lane" ] || lane="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "$lane" ] && [ "$lane" != HEAD ] || lane="$(basename "$top")"
  lane="$(printf '%s' "$lane" | tr -c 'A-Za-z0-9._-' '_')"

  local T; T="$(mktemp -d "${TMPDIR:-/tmp}/osrc-guards.XXXXXX")" || return 2
  mkdir -p "$T/cfg" "$T/out" "$T/scratch"
  git show "$base_sha:.outsourcerer/guards.conf" >"$T/cfg/guards.conf" 2>/dev/null || rm -f "$T/cfg/guards.conf"
  git show "$base_sha:.outsourcerer/guards/slop.allow" >"$T/cfg/slop.allow" 2>/dev/null || rm -f "$T/cfg/slop.allow"

  # One diff: merge-base vs working tree, then every untracked file as a new file.
  git diff --no-color --no-ext-diff "$mb" -- . >"$T/diff" 2>/dev/null
  git diff --name-only "$mb" -- . >"$T/files" 2>/dev/null
  local u
  while IFS= read -r u; do
    [ -f "$u" ] || continue
    git diff --no-color --no-ext-diff --no-index -- /dev/null "$u" >>"$T/diff" 2>/dev/null
    printf '%s\n' "$u" >>"$T/files"
  done < <(git ls-files --others --exclude-standard 2>/dev/null)

  local changed_paths=""
  while IFS= read -r u; do
    case "$u" in .outsourcerer/guards/*|.outsourcerer/guards.conf|.file-size-allow|scripts/check_file_size.py)
      changed_paths="$changed_paths$u
" ;; esac
  done <"$T/files"

  _osrc_guards_collect "$base_sha" "$T/g"
  local name path mode rc top_mode=off ran="" skipped="" failed_json="" enforce_fail=0 secs="${OSRC_GUARDS_SECS:-120}"
  local human="$T/human"; : >"$human"
  printf 'guards: base %s (%s), lane %s, %s changed file(s)\n' "$base" "$(printf '%s' "$mb" | cut -c1-9)" "$lane" \
    "$(awk 'NF { n++ } END { print n + 0 }' "$T/files")" >>"$human"
  while IFS='	' read -r name path; do
    [ -n "$name" ] || continue
    mode="$(_osrc_guards_mode_for "$name" "$T/cfg" "$flag_mode")"
    if [ "$mode" = off ]; then skipped="$skipped $name"; printf 'skip  %s [off]\n' "$name" >>"$human"; continue; fi
    ran="$ran $name"
    case "$top_mode:$mode" in off:*|observe:enforce) top_mode="$mode" ;; esac
    rc=0
    if type _timeout >/dev/null 2>&1; then
      ( export OSRC_GUARD_DIFF="$T/diff" OSRC_GUARD_FILES="$T/files" OSRC_GUARD_BASE="$mb" OSRC_GUARD_BASE_REF="$base_sha" \
          OSRC_GUARD_CFGDIR="$T/cfg" OSRC_GUARD_TMP="$T/scratch"
        _timeout "$secs" _osrc_guards_exec "$path" </dev/null ) >"$T/out/$name" 2>&1 || rc=$?
    else
      ( export OSRC_GUARD_DIFF="$T/diff" OSRC_GUARD_FILES="$T/files" OSRC_GUARD_BASE="$mb" OSRC_GUARD_BASE_REF="$base_sha" \
          OSRC_GUARD_CFGDIR="$T/cfg" OSRC_GUARD_TMP="$T/scratch"
        _osrc_guards_exec "$path" </dev/null ) >"$T/out/$name" 2>&1 || rc=$?
    fi
    if [ "$rc" = 0 ]; then printf 'ok    %s [%s]\n' "$name" "$mode" >>"$human"; continue; fi
    local what fix
    what="$(sed -n 's/^WHAT: *//p' "$T/out/$name")"
    fix="$(sed -n 's/^FIX: *//p' "$T/out/$name" | awk 'NR > 1 { printf " | " } { printf "%s", $0 }')"
    if [ -z "$what" ]; then
      what="$(grep -v '^[[:space:]]*$' "$T/out/$name" | tail -5)"
      [ "$rc" = 124 ] && what="timed out after ${secs}s${what:+
$what}"
      [ -n "$what" ] || what="exit $rc"
    fi
    [ -n "$fix" ] || fix="read the guard's output and fix what it names"
    [ "$mode" = enforce ] && enforce_fail=1
    printf 'FAIL  %s [%s]%s\n' "$name" "$mode" "$([ "$mode" = observe ] && printf ' (observe: would block in enforce)')" >>"$human"
    printf '%s\n' "$what" | sed 's/^/      WHAT: /' >>"$human"
    printf '      FIX: %s\n' "$fix" >>"$human"
    if [ "$mode" = observe ]; then
      _osrc_guards_log observe.log "$lane $name would-block: $(printf '%s\n' "$what" | head -1)"
    fi
    failed_json="$failed_json$(jq -cn --arg g "$name" --arg m "$mode" --arg w "$what" --arg f "$fix" \
      '{guard:$g, mode:$m, what:($w | split("\n") | map(select(length > 0))), fix:$f}')
"
  done <"$T/g/list"

  [ -z "$changed_paths" ] || printf '%s' "$changed_paths" | sed '/^$/d; s/^/guards-changed: /; s/$/ (lane edited its own checks; the base copy ran; reviewer must look)/' >>"$human"

  local passed=true allowed="" bdir n=0
  bdir="$(_osrc_guards_dir)/blocks"
  if [ "$enforce_fail" = 1 ]; then
    [ -f "$bdir/$lane" ] && n="$(cat "$bdir/$lane" 2>/dev/null)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ -n "$allow" ]; then allowed="$allow"
    elif [ "$n" -ge 2 ]; then allowed="allowed after 2 blocks"
    fi
    if [ -n "$allowed" ]; then
      rm -f "$bdir/$lane"
      _osrc_guards_log allowed.log "$lane allowed: $allowed"
      printf 'guards: ALLOWED past an enforce failure: %s\n' "$allowed" >>"$human"
    else
      passed=false; mkdir -p "$bdir" && printf '%s\n' "$((n + 1))" >"$bdir/$lane"
      printf 'guards: BLOCKED (block %s of 2; fix and rerun, or pass --allow "<reason>")\n' "$((n + 1))" >>"$human"
    fi
  else
    rm -f "$bdir/$lane" 2>/dev/null
    printf 'guards: PASS%s\n' "$([ -n "$failed_json" ] && printf ' (observe-only failures logged)')" >>"$human"
  fi

  local elapsed=$((SECONDS - t0))
  if [ "$json" = 1 ]; then
    cat "$human" >&2
    printf '%s' "$failed_json" | jq -cs --arg mode "$top_mode" --argjson passed "$passed" \
      --arg cp "$changed_paths" --arg allowed "$allowed" --arg ran "$ran" --arg sk "$skipped" \
      --arg base "$base" --arg bs "$base_sha" --arg lane "$lane" --argjson el "$elapsed" \
      '{mode:$mode, passed:$passed, failed:., guards_changed:($cp != ""),
        guards_changed_paths:($cp | split("\n") | map(select(length > 0))),
        allowed:(if $allowed == "" then null else $allowed end),
        ran:($ran | split(" ") | map(select(length > 0))), skipped:($sk | split(" ") | map(select(length > 0))),
        base:$base, base_sha:$bs, lane:$lane, elapsed_s:$el}'
  else
    cat "$human"
  fi
  rm -rf "$T"
  [ "$passed" = true ]
}

osrc_guards_list() {
  local base=""
  case "${1:-}" in --base) base="${2:-}" ;; esac
  git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "guards: not inside a git worktree" >&2; return 2; }
  cd "$(git rev-parse --show-toplevel)" || return 2
  [ -n "$base" ] || base="$(_osrc_guards_default_base)" || { echo "guards: no base ref (pass --base)" >&2; return 2; }
  local T name path; T="$(mktemp -d "${TMPDIR:-/tmp}/osrc-guards.XXXXXX")" || return 2
  mkdir -p "$T/cfg"
  git show "$base:.outsourcerer/guards.conf" >"$T/cfg/guards.conf" 2>/dev/null || rm -f "$T/cfg/guards.conf"
  _osrc_guards_collect "$base" "$T/g"
  while IFS='	' read -r name path; do
    case "$path" in "$T"/*) path="$base:.outsourcerer/guards/$(basename "$path")" ;; esac
    printf '%-12s %-8s %s\n' "$name" "$(_osrc_guards_mode_for "$name" "$T/cfg" "")" "$path"
  done <"$T/g/list"
  rm -rf "$T"
}

cmd_guards() {
  local sub="${1:-}"; [ $# -gt 0 ] && shift
  case "$sub" in
    run) osrc_guards_run "$@" ;;
    list|ls) osrc_guards_list "$@" ;;
    ""|-h|--help|help) _osrc_guards_usage ;;
    *) echo "guards: unknown subcommand '$sub'" >&2; _osrc_guards_usage; return 2 ;;
  esac
}
