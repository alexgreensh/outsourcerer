#!/usr/bin/env bash
# scripts/preflight.sh [--base REF] [--static-only]: the local gate that runs BEFORE a lane says done and
# before any push, so CI never meets a failure the Mac could have caught for free.
#
# Built from the last 40 red CI runs (2026-11-16, out/ci-failure-history.tsv): the top classes were
#   1. a new suite nobody registered in conformance.sh ("never run by the gate", 18 failures),
#   2. static lints such as quiet grep in a pipe (test_no_pipe_grep_q, 8),
#   3. suites that cover the file just changed (test_hub 16, test_hub_home 11, test_limit_gate 7, ...),
#      including a lib that only works when the engine's loader sourced its sibling first.
# Order is cheapest first; the first failing stage stops the run.
# PREFLIGHT_OUT (default <repo>/out, git-ignored): where load-sensitive suites are recorded as tasks.
set -uo pipefail
T=plugins/outsourcerer/skills/outsourcerer/scripts/tests

# Suites that reach a file only through the engine, so no suite names it and the basename grep below
# misses them (S2 changed supervise_watch.sh, remote.sh and done.sh and test_supervise never ran).
_extra_suites() { # <basename> -> suite names
  case "$1" in
    supervise_watch.sh|remote.sh|done.sh|lane_life.sh|owner_state.sh|supervise_dedupe.sh) echo test_supervise test_supervise_dedupe ;;
  esac
}

# _suites_for <changed paths, one per line> -> the suites to run, in first-seen order.
_suites_for() {
  local p b s out=""
  _add() { case " $out " in *" $1 "*) ;; *) [ -f "$T/$1.sh" ] && out="$out $1" ;; esac; }
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      "$T"/test_*.sh) _add "$(basename "$p" .sh)" ;;
      plugins/outsourcerer/skills/outsourcerer/scripts/*)
        b="$(basename "$p")"; [ "$b" = outsourcerer.sh ] && continue   # the engine: every suite; CI owns that
        for s in $(grep -lF "$b" "$T"/test_*.sh 2>/dev/null); do _add "$(basename "$s" .sh)"; done
        for s in $(_extra_suites "$b"); do _add "$s"; done ;;
    esac
  done <<<"$1"
  printf '%s' "$out"
}

# A suite that failed under parallel load and passed alone is not green, it is an open task (0.17
# flaky rule: fix or delete, never retry). It does not block, but it is printed and appended to
# $PREFLIGHT_OUT/LOAD-SENSITIVE.md with its failing lines.
_record_load_sensitive() { # <suite> <failing lines>
  local d="${PREFLIGHT_OUT:-out}" f
  f="$d/LOAD-SENSITIVE.md"; mkdir -p "$d" 2>/dev/null
  echo "load-sensitive: $1"; printf '%s\n' "$2" | sed '/^$/d; s/^/     ? /'
  { [ -s "$f" ] || printf '# Load-sensitive suites (written by scripts/preflight.sh; each entry is a task)\n'
    printf '\n## %s %s\n\n' "$(date '+%Y-%m-%d %H:%M')" "$1"
    printf -- '- branch %s at %s, PREFLIGHT_JOBS=%s, load %s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" \
      "$(git rev-parse --short HEAD 2>/dev/null)" "${PREFLIGHT_JOBS:-4}" "$( (sysctl -n vm.loadavg 2>/dev/null || cut -d' ' -f1-3 /proc/loadavg 2>/dev/null) | tr -d '{}' | xargs)"
    printf -- '- failed under load, passed alone. Root-cause it, then fix or delete the case; never add sleeps or retries.\n'
    printf '%s\n' "$2" | sed '/^$/d; s/^/    /'
  } >>"$f" 2>/dev/null && echo "     recorded in $f" || echo "     (could not write $f)"
}
[ "${PREFLIGHT_SOURCE_ONLY:-0}" = 1 ] && return 0 2>/dev/null

cd "$(git rev-parse --show-toplevel)" || exit 2
BASE=origin/main; STATIC_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --static-only) STATIC_ONLY=1; shift ;;
    *) echo "usage: scripts/preflight.sh [--base REF] [--static-only]" >&2; exit 2 ;;
  esac
done
fail=0; loadsens=""; t0=$(date +%s)
stage() { printf '\n== %s\n' "$1"; }
run() { # <label> <cmd...>
  local s=$(date +%s) log; log="$(mktemp "${TMPDIR:-/tmp}/preflight.XXXXXX")"
  if "${@:2}" >"$log" 2>&1; then echo "ok   $1 ($(( $(date +%s) - s ))s)"
  else echo "FAIL $1 ($(( $(date +%s) - s ))s)"; tail -25 "$log" | sed 's/^/     | /'; fail=1; fi
  rm -f "$log"
}

stage "1. registration: every test file is in the conformance runner"
_suites_of() { # <var>: every name assigned to _ALL_SUITES / _PYTHON_SUITES in conformance.sh (strings span lines)
  python3 -I -c 'import re,sys
s=open(sys.argv[1],encoding="utf-8").read()
print(" ".join(n for m in re.finditer(r"^"+sys.argv[2]+r"=\"([^\"]*)\"",s,re.M) for n in m.group(1).split() if n.startswith("test_")))' "$T/conformance.sh" "$1"
}
_ALL_SUITES="$(_suites_of _ALL_SUITES)"; _PYTHON_SUITES="$(_suites_of _PYTHON_SUITES)"
[ -n "$_ALL_SUITES" ] || { echo "FAIL could not read the suite list from $T/conformance.sh"; exit 1; }
unreg=""
for f in "$T"/test_*.sh; do n="$(basename "$f" .sh)"; case " $_ALL_SUITES " in *" $n "*) ;; *) unreg="$unreg $n" ;; esac; done
for f in "$T"/test_*.py; do [ -e "$f" ] || continue; n="$(basename "$f" .py)"; case " $_PYTHON_SUITES " in *" $n "*) ;; *) unreg="$unreg $n" ;; esac; done
if [ -z "$unreg" ]; then echo "ok   all suites registered"; else echo "FAIL not in tests/conformance.sh:$unreg"; fail=1; fi

stage "2. static lints"
for l in test_no_pipe_grep_q test_sandbox_guard test_no_real_browser test_python_utf8 test_no_dead_pid_scan test_tests_set_home; do
  run "$l" bash "$T/$l.sh"
done
run "file size" python3 scripts/check_file_size.py
[ "$fail" = 0 ] || { echo; echo "preflight: FAILED at the static stage ($(( $(date +%s) - t0 ))s). Fix before running suites."; exit 1; }
[ "$STATIC_ONLY" = 1 ] && { echo; echo "preflight: static stages green ($(( $(date +%s) - t0 ))s)."; exit 0; }

stage "3. suites covering what changed since $BASE"
git rev-parse -q --verify "$BASE" >/dev/null || { echo "FAIL base $BASE not found (git fetch?)"; exit 1; }
changed="$(git diff --name-only "$BASE"...HEAD; git diff --name-only HEAD; git ls-files --others --exclude-standard)"
suites="$(_suites_for "$changed")"
[ -n "$suites" ] || echo "ok   no changed file is covered by a suite"
# Parallel pool (PREFLIGHT_JOBS, default 4): run serially, 15 hub suites took 23 min on 2026-11-16.
J="${PREFLIGHT_JOBS:-4}"; L="$(mktemp -d "${TMPDIR:-/tmp}/preflight.XXXXXX")"
# Suites run on a clock where it is 23:xx local (PREFLIGHT_TZ overrides; "keep" keeps the Mac's zone).
# A "+N hours" renewal then crosses midnight, as it does on CI near UTC midnight (test_hub_mc4 said
# "in 6 days" on CI and "in 5 days" here, 2026-11-17).
if [ -z "${PREFLIGHT_TZ:-}" ]; then
  _off=$(( (23 - 10#$(date -u +%H) + 36) % 24 - 12 ))   # UTC offset that makes it 23:xx, in -12..+11
  if [ "$_off" -ge 0 ]; then PREFLIGHT_TZ="Etc/GMT-$_off"; else PREFLIGHT_TZ="Etc/GMT+${_off#-}"; fi   # POSIX sign is inverted
fi
[ "$PREFLIGHT_TZ" = keep ] || { export TZ="$PREFLIGHT_TZ"; echo "     (suites run with TZ=$TZ, local time $(date +%H:%M))"; }
for s in $suites; do
  case " $_ALL_SUITES " in *" $s "*) ;; *) continue ;; esac   # helpers, not suites
  # Same isolation as conformance.sh's pool: job control (set -m) so INT traps install in background
  # jobs, and a fresh HOME + OSRC_HOME per suite (exactly conformance.sh:270) so one suite's state never perturbs another.
  mkdir -p "$L/$s.home/home"; set -m
  ( st=$(date +%s); HOME="$L/$s.home/home" OSRC_HOME="$L/$s.home" OSRC_HEARTBEAT_DISABLED=1 nice -n 19 bash "$T/$s.sh" >"$L/$s.log" 2>&1; echo "$? $(( $(date +%s) - st ))" >"$L/$s.rc" ) &
  set +m
  while [ "$(jobs -rp | wc -l)" -ge "$J" ]; do sleep 1; done
done
wait
for s in $suites; do
  [ -f "$L/$s.rc" ] || continue; read -r rc secs <"$L/$s.rc"
  if [ "$rc" = 0 ]; then echo "ok   $s (${secs}s)"; continue; fi
  # Failed under parallel load: run it alone to classify. A failure that repeats alone is real; one
  # that passes alone is load-sensitive: recorded as a task, not blocking, never counted as green.
  rm -rf "$L/$s.home"; mkdir -p "$L/$s.home/home"; first="$(grep -E 'FAIL' "$L/$s.log" | head -10)"
  if HOME="$L/$s.home/home" OSRC_HOME="$L/$s.home" OSRC_HEARTBEAT_DISABLED=1 bash "$T/$s.sh" >"$L/$s.solo.log" 2>&1; then
    _record_load_sensitive "$s" "$first"; loadsens="$loadsens $s"
    continue
  fi
  # Fails alone: run the same suite on BASE in the same environment. Only FAIL lines that base does not
  # also print block; lines base fails too are this machine's (test_hub's /api/projects under a fake HOME
  # fails on this Mac at every commit and passes on CI, 2026-11-16).
  if [ ! -d "$L/base" ]; then git worktree add -q --detach "$L/base" "$BASE" >/dev/null 2>&1 || mkdir -p "$L/base.broken"; fi
  grep -E '^ *FAIL' "$L/$s.solo.log" | sed 's/^ *//' | sort -u >"$L/$s.new"
  if [ -f "$L/base/$T/$s.sh" ]; then
    rm -rf "$L/$s.bh"; mkdir -p "$L/$s.bh/home"
    (cd "$L/base" && HOME="$L/$s.bh/home" OSRC_HOME="$L/$s.bh" OSRC_HEARTBEAT_DISABLED=1 bash "$T/$s.sh" 2>&1) | grep -E '^ *FAIL' | sed 's/^ *//' | sort -u >"$L/$s.base"
  else : >"$L/$s.base"; fi
  only="$(comm -23 "$L/$s.new" "$L/$s.base")"
  if [ -z "$only" ]; then
    echo "warn $s fails here, but base $BASE fails the same lines on this machine (not this change):"; sed 's/^/     ? /' "$L/$s.new"
  else
    echo "FAIL $s (new versus $BASE)"; sed 's/^/     | /' <<<"$only"; tail -6 "$L/$s.solo.log" | sed 's/^/     ~ /'; fail=1
  fi
done
[ -d "$L/base" ] && git worktree remove --force "$L/base" >/dev/null 2>&1
rm -rf "$L"

echo
[ -z "$loadsens" ] || echo "load-sensitive (not blocking, open tasks in ${PREFLIGHT_OUT:-out}/LOAD-SENSITIVE.md):$loadsens"
if [ "$fail" = 0 ]; then echo "preflight: GREEN ($(( $(date +%s) - t0 ))s). Not covered here: Windows Git Bash and uutils (CI jobs) and suites reached only through outsourcerer.sh."; exit 0; fi
echo "preflight: FAILED ($(( $(date +%s) - t0 ))s)."; exit 1
