# lib/heavy.sh — heavy-work gate (L10 add-on): full suites, builds, installs, benchmarks and
# anything estimated over ~2 minutes belong on a hosted box, not on the user's Mac.
#
#   osrc_heavy <command...>    -> rc 0 = heavy (reason on stderr), rc 1 = light
#   osrc_mac_load              -> prints "load_per_core=<f> swap_pct=<n> (...)"; "?" when unknown
#   _osrc_mac_overloaded       -> rc 0 when load/core > OSRC_MAC_LOAD_MAX_PC (2) or swap > 80%
#   _osrc_heavy_gate <check> <dir> <out> <secs>
#       sets OSRC_HEAVY_MODE: run (light) | nice (heavy, run locally niced) | done (handled here)
#       sets OSRC_HEAVY_RC / OSRC_HEAVY_NOTE; mode=done means $out already holds the result
#
# Wired into _loop_check, the single funnel for bounded check commands (crew grading, loop
# verify, land checks, done-contract `check:` evals). Cloud path reuses `cloud start` so every
# existing gate (preflight, secret scan, private names, consent, lane + done registration)
# applies unchanged. Sourced by outsourcerer.sh; defines functions only; bash 3.2.
#
# Escape hatches: OSRC_HEAVY_OFF=1 disables the gate; OSRC_HEAVY=1 forces a command heavy,
# OSRC_HEAVY=0 forces it light; OSRC_HEAVY_LOCAL=1 skips the cloud attempt (local/nice/stall only).

# ---- classification ----------------------------------------------------------------------------
# _osrc_heavy_reason <cmd> -> "heavy: <why>" or "light". Conservative: a false "heavy" costs one
# cloud attempt that falls back to niced-local; a false "light" overheats the Mac.
_osrc_heavy_reason() {
  local cmd="$1" lc est mins
  [ -n "${cmd//[[:space:]]/}" ] || { printf 'light'; return 0; }
  case "${OSRC_HEAVY:-auto}" in
    1) printf 'heavy: OSRC_HEAVY=1'; return 0 ;;
    0) printf 'light'; return 0 ;;
  esac
  lc="$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')"
  # Several suites/commands in parallel.
  if printf '%s' "$lc" | grep -qE '(^|[[:space:];|])&([[:space:]]|$)|\bparallel\b|xargs[^|]*-P[0-9]|\bmake\b[^|;&]*-[a-z]*j[[:space:]]*[0-9]|\b(jest|vitest|pytest)[^|;&]*--(workers|jobs|maxWorkers)[= ]+[0-9]'; then
    printf 'heavy: several suites or commands in parallel'; return 0
  fi
  # Explicit markers: a `# slow` / `# heavy` comment, --slow/--heavy flag, OSRC_SLOW=1.
  if printf '%s' "$lc" | grep -qE '#[[:space:]]*(slow|heavy)\b|(^|[[:space:]])--(slow|heavy)\b|\bosrc_slow=1\b|\bosrc_heavy=1\b'; then
    printf 'heavy: marked slow/heavy'; return 0
  fi
  # Estimated runtime marker: `# est 5m`, `est=90s`, `est: 2h` (unitless = minutes).
  est="$(printf '%s' "$lc" | grep -oE '\best\b[= :]*[0-9]+(\.[0-9]+)?[[:space:]]*[a-z]*' | head -1)"
  if [ -n "$est" ]; then
    mins="$(printf '%s' "$est" | awk '{
      if (match($0, /[0-9]+(\.[0-9]+)?/)) {
        num=substr($0, RSTART, RLENGTH)+0; rest=substr($0, RSTART+RLENGTH); unit="m"
        if (rest ~ /^[[:space:]]*(h|hr|hrs|hour|hours)/) unit="h"
        else if (rest ~ /^[[:space:]]*(s|sec|secs|second|seconds)/) unit="s"
        v=num; if (unit=="h") v*=60; else if (unit=="s") v/=60
        printf "%.2f", v
      }}')"
    if [ -n "$mins" ] && awk -v m="$mins" 'BEGIN{exit !(m>2)}'; then
      printf 'heavy: estimated %.0fmin (>2min)' "$mins"; return 0
    fi
  fi
  # Test suites / suite runners. A runner aimed at ONE explicit test FILE is an own-unit-test
  # run (delegates are told to run those) -> not heavy by this rule.
  if printf '%s' "$lc" | grep -qE '\bconformance\b|test_factory|\b(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?(test|ci|e2e)\b|\bmake[[:space:]]+test\b|\bgo[[:space:]]+test\b|\bcargo[[:space:]]+test\b|\bbazel[[:space:]]+test\b'; then
    printf 'heavy: test suite'; return 0
  fi
  if printf '%s' "$lc" | grep -qE '\b(pytest|py\.test|vitest|jest|mocha|ava|phpunit|rspec|ctest)\b'; then
    # A runner aimed at ONE explicit test FILE (arg ending in a source/test extension) is an
    # own-unit-test run; a bare runner, a directory, or a suite-wide flag is a full suite.
    if printf '%s' "$lc" | grep -qE '[a-z0-9_./-]+\.(py|py\.test|js|jsx|ts|tsx|sh|rb|php)([^a-z]|$)' \
       && ! printf '%s' "$lc" | grep -qE -- '--(all|coverage|watch|maxWorkers|workers)[= ]'; then
      : # single test file -> own unit test, falls through to remaining rules
    else
      printf 'heavy: test suite runner'; return 0
    fi
  fi
  # Builds.
  if printf '%s' "$lc" | grep -qE '\bcargo[[:space:]]+(build|check|clippy|doc|bench|install|publish|run|fix)\b|\bgo[[:space:]]+(build|install|generate)\b|\b(make|gmake|cmake|ninja|meson|bazel|buck2)\b|\bdocker[[:space:]]+(build|buildx|compose|run|pull|push)\b|\bxcodebuild\b|\bgradle(w)?\b|\b(mvn|mvnw|ant)\b|\b(terraform|pulumi|vagrant|packer)\b|\b(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?(build|compile|bundle|ci)\b'; then
    printf 'heavy: build'; return 0
  fi
  # Installs / dependency resolution.
  if printf '%s' "$lc" | grep -qE '\b(npm|pnpm|yarn|bun)[[:space:]]+(ci|install|i|add|remove|update|exec)\b|\bnpx\b|\b(pip3?|pipx|uv[[:space:]]+pip|poetry|conda|gem|composer|brew|apt(-get)?|snap|choco|winget)[[:space:]]+(install|add|i|upgrade|update|remove|uninstall)\b|\bcargo[[:space:]]+install\b|\bgo[[:space:]]+install\b'; then
    printf 'heavy: install'; return 0
  fi
  # Benchmarks / profiling at scale.
  if printf '%s' "$lc" | grep -qE '\b(benchmark|benchmarks|hyperfine|criterion|k6|artillery|autocannon|unixbench|phoronix)\b|\bwrk\b|\bsiege\b'; then
    printf 'heavy: benchmark'; return 0
  fi
  printf 'light'
}

# osrc_heavy <command...> -> rc 0 heavy (reason on stderr), rc 1 light.
osrc_heavy() {
  local r; r="$(_osrc_heavy_reason "$*")"
  case "$r" in
    light) return 1 ;;
    *)     printf '%s\n' "$r" >&2; return 0 ;;
  esac
}

# ---- Mac load ----------------------------------------------------------------------------------
# osrc_mac_load -> "load_per_core=<f> swap_pct=<n> (load1=<x> cores=<n> swap=<u>M/<t>M)".
# Uses only sysctl + uptime (both stubbed in tests). "?" fields when unmeasurable -> the gate
# treats unknown load as NOT overloaded (fail-open; documented in the L10 report).
osrc_mac_load() {
  local cores load1 up swapline tot used pct lpc
  cores="$(sysctl -n hw.ncpu 2>/dev/null)"
  case "$cores" in ''|*[!0-9]*|0) cores="$(sysctl -n hw.logicalcpu 2>/dev/null)" ;; esac
  case "$cores" in ''|*[!0-9]*|0) cores=1 ;; esac
  up="$(uptime 2>/dev/null)"
  load1="$(printf '%s' "$up" | grep -oE 'load averages?:[^0-9]*[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+(\.[0-9]+)?$' | head -1)"
  swapline="$(sysctl -n vm.swapusage 2>/dev/null)"
  tot="$(printf '%s' "$swapline" | sed -n 's/.*total = \([0-9.]*\)[MG].*/\1/p' | head -1)"
  used="$(printf '%s' "$swapline" | sed -n 's/.*used = \([0-9.]*\)[MG].*/\1/p' | head -1)"
  lpc="?"; pct="?"
  [ -n "$load1" ] && lpc="$(awk -v l="$load1" -v c="$cores" 'BEGIN{printf "%.2f", l/c}')"
  if [ -n "$tot" ] && [ -n "$used" ]; then
    pct="$(awk -v u="$used" -v t="$tot" 'BEGIN{if (t+0>0) printf "%d", int(u*100/t+0.5); else print "?"}')"
  fi
  printf 'load_per_core=%s swap_pct=%s (load1=%s cores=%s swap=%sM/%sM)\n' \
    "$lpc" "$pct" "${load1:-?}" "$cores" "${used:-?}" "${tot:-?}"
}

# _osrc_mac_overloaded -> rc 0 when 1-min load per core exceeds OSRC_MAC_LOAD_MAX_PC (default 2)
# or swap use exceeds OSRC_MAC_SWAP_MAX_PCT (default 80). Unknown readings never overload.
_osrc_mac_overloaded() {
  local load lpc spct
  load="$(osrc_mac_load 2>/dev/null)"
  lpc="$(printf '%s' "$load" | sed -n 's/.*load_per_core=\([^ ]*\).*/\1/p')"
  spct="$(printf '%s' "$load" | sed -n 's/.*swap_pct=\([^ ]*\).*/\1/p')"
  case "$lpc" in ''|?|*[!0-9.]*) ;; *)
    awk -v a="$lpc" -v b="${OSRC_MAC_LOAD_MAX_PC:-2}" 'BEGIN{exit !(a+0>b+0)}' && return 0 ;;
  esac
  case "$spct" in ''|?|*[!0-9.]*) ;; *)
    awk -v a="$spct" -v b="${OSRC_MAC_SWAP_MAX_PCT:-80}" 'BEGIN{exit !(a+0>b+0)}' && return 0 ;;
  esac
  return 1
}

# ---- cloud brief + wait -------------------------------------------------------------------------
# _osrc_heavy_id <check> -> stable lane id; suffixes epoch when the id is already registered.
_osrc_heavy_id() {
  local c id
  c="$(printf '%s' "$1" | cksum 2>/dev/null | awk '{print $1}')"; c="${c:-0}"
  id="heavy-$c"
  [ -n "${OSRC_HOME:-}" ] && [ -e "$OSRC_HOME/remote/$id.json" ] && id="$id-$(date +%s)"
  printf '%s' "$id"
}

# _osrc_heavy_brief <id> <check> <repo> <base> -> writes the self-contained task file `cloud
# start` wraps into its context pack; prints the path. Teaches the RESULT contract the gate polls.
_osrc_heavy_brief() {
  local id="$1" check="$2" repo="$3" base="$4" dir f
  [ -n "${OSRC_HOME:-}" ] || return 1
  dir="$OSRC_HOME/cloud"; _mkdir_private "$dir" 2>/dev/null || return 1
  f="$dir/$id.brief.md"
  {
    printf 'Run ONE command on the pushed branch and report its result.\n\n'
    printf 'Repository: %s\nBase branch: %s\n\n' "${repo:-the repository you cloned}" "${base:-the base branch}"
    printf 'At the repository root run exactly this command:\n\n```\n%s\n```\n\n' "$check"
    printf 'Then commit on branch `cloud/%s`:\n' "$id"
    printf -- '- `%s.RESULT`: first line `rc=<exit code of the command above>`, then the last ~80 lines of its combined output.\n' "$id"
    printf -- '- `%s.READY` at the repository root containing exactly one line: `READY %s`.\n' "$id" "$id"
    printf -- '- push `cloud/%s`. Change nothing else; do not modify source files.\n' "$id"
    printf 'If the command cannot run in your environment, still write `%s.RESULT` with `rc=127` and the error text, plus `%s.READY`, and push.\n' "$id" "$id"
  } > "$f" 2>/dev/null || return 1
  chmod 600 "$f" 2>/dev/null
  printf '%s' "$f"
}

# _osrc_heavy_cloud_wait <id> <dir> <out> <secs> -> polls origin for cloud/<id> carrying
# <id>.RESULT; writes the report to $out and sets OSRC_HEAVY_RC. rc124 on timeout (lane keeps
# running remotely; `cloud ls` / lane events show it).
_osrc_heavy_cloud_wait() {
  local id="$1" dir="$2" out="$3" secs="${4:-300}" start now elapsed res rc
  start="$(date +%s)"
  while :; do
    if git -C "$dir" fetch -q origin "+refs/heads/cloud/$id:refs/remotes/osrc-cloud/$id" 2>/dev/null; then
      res="$(git -C "$dir" show "refs/remotes/osrc-cloud/$id:$id.RESULT" 2>/dev/null)"
      if [ -n "$res" ]; then
        rc="$(printf '%s' "$res" | sed -n 's/^rc=//p' | head -1 | tr -dc '0-9')"
        case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
        printf '%s\n' "$res" > "$out" 2>/dev/null || true
        printf '>>> [heavy] cloud lane %s reported rc=%s\n' "$id" "$rc" >&2
        OSRC_HEAVY_RC="$rc"; return 0
      fi
    fi
    now="$(date +%s)"; elapsed=$(( now - start ))
    [ "$elapsed" -ge "$secs" ] && break
    sleep "${OSRC_HEAVY_POLL:-5}"
  done
  printf '[outsourcerer] heavy check TIMED OUT after %ss waiting for cloud lane %s (branch cloud/%s still running remotely; see `cloud ls`).\n' \
    "$secs" "$id" "$id" >> "$out" 2>/dev/null || true
  printf '>>> [heavy] cloud lane %s did not report within %ss — it keeps running remotely\n' "$id" "$secs" >&2
  OSRC_HEAVY_RC=124; return 0
}

# ---- stall: queue + EVENT/NEXT -----------------------------------------------------------------
# _osrc_heavy_stall <check> <dir> <out> <reason> -> queues the check under $OSRC_HOME/heavy-queue,
# prints the CONTRACT pair, sets OSRC_HEAVY_RC=125 (check did not run).
_osrc_heavy_stall() {
  local check="$1" dir="$2" out="$3" reason="${4:-mac-overloaded}"
  local id top repo base brief self next load lpc spct qdir qf
  OSRC_HEAVY_RC=125; OSRC_HEAVY_NOTE=""
  id="$(_osrc_heavy_id "$check")"
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
  repo="$(git -C "$dir" remote get-url origin 2>/dev/null)"
  base="$(git -C "${top:-$dir}" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  brief="$(_osrc_heavy_brief "$id" "$check" "$repo" "$base" 2>/dev/null)"
  self="${SCRIPT_PATH:-${BASH_SOURCE[1]:-$0}}"
  if [ -n "$repo" ] && [ -n "$base" ] && [ -n "$brief" ]; then
    next="\"$self\" cloud start $id --repo $(printf '%q' "$repo") --base $(printf '%q' "$base") --brief $(printf '%q' "$brief") --vehicle auto"
  else
    next="(no git origin/base in $dir — rerun manually with: cloud start <id> --repo <owner/name> --base <branch> --brief <file>)"
  fi
  if [ -n "${OSRC_HOME:-}" ]; then
    qdir="$OSRC_HOME/heavy-queue"; _mkdir_private "$qdir" 2>/dev/null
    qf="$qdir/$id.cmd"
    { printf '# queued heavy check %s (%s) — not run locally\n' "$(date +%s)" "$reason"
      printf 'dir: %s\ncheck: %s\n' "$dir" "$check"
      printf 'cloud option: %s\n' "$next"; } > "$qf" 2>/dev/null || true
  fi
  load="$(osrc_mac_load 2>/dev/null)"
  lpc="$(printf '%s' "$load" | sed -n 's/.*load_per_core=\([^ ]*\).*/\1/p')"; lpc="${lpc:-?}"
  spct="$(printf '%s' "$load" | sed -n 's/.*swap_pct=\([^ ]*\).*/\1/p')"; spct="${spct:-?}"
  printf 'EVENT stalled %s %s %s load_per_core=%s swap_pct=%s\n' "$id" "$(date +%s)" "$reason" "$lpc" "$spct" >&2
  printf 'NEXT %s\n' "$next" >&2
  printf '[outsourcerer] heavy check queued as lane %s (%s); it did NOT run locally. Cloud option:\n%s\n' \
    "$id" "$reason" "$next" >> "$out" 2>/dev/null || true
  return 0
}

# ---- local serialization: one heavy check at a time ----------------------------------------------
# mkdir lock under $OSRC_HOME/heavy-local.lock.d holding "<epoch>"; stale after
# OSRC_HEAVY_LOCK_STALE (default 7200s) so a dead holder cannot wedge the queue forever.
_osrc_heavy_lockdir() { printf '%s/heavy-local.lock.d' "${OSRC_HOME:-${TMPDIR:-/tmp}/osrc-home}"; }

_osrc_heavy_lock() { # <wait-secs> -> rc0 while holding the lock
  local dir waited=0 max="${1:-120}" ep now
  dir="$(_osrc_heavy_lockdir)"; mkdir -p "$(dirname "$dir")" 2>/dev/null
  until mkdir "$dir" 2>/dev/null; do
    ep="$(cat "$dir/epoch" 2>/dev/null)"; now="$(date +%s)"
    case "$ep" in ''|*[!0-9]*) ep=0 ;; esac
    if [ $(( now - ep )) -gt "${OSRC_HEAVY_LOCK_STALE:-7200}" ] 2>/dev/null; then
      rm -rf "$dir" 2>/dev/null; continue
    fi
    [ "$waited" -ge "$max" ] && return 1
    sleep 2; waited=$(( waited + 2 ))
  done
  date +%s > "$dir/epoch" 2>/dev/null
  return 0
}

_osrc_heavy_unlock() { rm -rf "$(_osrc_heavy_lockdir)" 2>/dev/null; return 0; }

# ---- the gate ------------------------------------------------------------------------------------
# _osrc_heavy_gate <check> <dir> <out> <secs> -> sets OSRC_HEAVY_MODE (run|nice|done).
# Order per the add-on: cloud vehicle available -> run there; else local niced one-at-a-time;
# overloaded Mac -> never start, queue + EVENT stalled. Called from _loop_check before spawn.
_osrc_heavy_gate() {
  OSRC_HEAVY_MODE="run"; OSRC_HEAVY_RC=1; OSRC_HEAVY_NOTE=""
  [ "${OSRC_HEAVY_OFF:-0}" = "1" ] && return 0
  local check="$1" dir="$2" out="$3" secs="${4:-300}" reason
  reason="$(_osrc_heavy_reason "$check")"
  [ "$reason" = "light" ] && return 0    # light -> normal path
  printf '%s\n' "$reason" >&2
  local top repo base id brief veh launch_log
  # --- try a cloud lane first ---------------------------------------------------------------
  if [ "${OSRC_HEAVY_LOCAL:-0}" != "1" ] && declare -F cmd_cloud >/dev/null 2>&1 \
     && declare -F _cloudrun_pick_vehicle >/dev/null 2>&1; then
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
    repo="$(git -C "$dir" remote get-url origin 2>/dev/null)"
    base="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ -n "$top" ] && [ -n "$repo" ] && [ -n "$base" ] \
       && veh="$(_cloudrun_pick_vehicle auto "${OSRC_CODEX_CLOUD_ENV:-}" 2>/dev/null)" \
       && id="$(_osrc_heavy_id "$check")" \
       && brief="$(_osrc_heavy_brief "$id" "$check" "$repo" "$base" 2>/dev/null)"; then
      launch_log="${OSRC_HOME:-}/cloud/$id.heavy.log"
      printf '>>> [heavy] %s — delegating to cloud lane %s (%s)\n' "$reason" "$id" "$veh" >&2
      if ( cd "$dir" && cmd_cloud start "$id" --repo "$repo" --base "$base" --brief "$brief" --vehicle "$veh" --where cloud ) >"$launch_log" 2>&1; then
        _osrc_heavy_cloud_wait "$id" "$dir" "$out" "$secs"
        OSRC_HEAVY_MODE="done"; return 0
      fi
      OSRC_HEAVY_NOTE="cloud lane refused ($(tail -1 "$launch_log" 2>/dev/null | cut -c1-120)); falling back to local rules"
      printf '>>> [heavy] %s\n' "$OSRC_HEAVY_NOTE" >&2
    fi
  fi
  # --- local: never start heavy work on an overloaded Mac ------------------------------------
  if _osrc_mac_overloaded; then
    _osrc_heavy_stall "$check" "$dir" "$out" "mac-overloaded"
    OSRC_HEAVY_MODE="done"; return 0
  fi
  # --- local niced, one at a time --------------------------------------------------------------
  OSRC_HEAVY_NOTE="running locally, niced (nice -n ${OSRC_HEAVY_NICE:-19}), one heavy check at a time"
  printf '>>> [heavy] %s: %s\n' "$OSRC_HEAVY_NOTE" "$(printf '%s' "$check" | cut -c1-100)" >&2
  OSRC_HEAVY_MODE="nice"
  return 0
}

# _osrc_heavy_prompt -> the testing-discipline block injected into generated lane briefs.
_osrc_heavy_prompt() {
  cat <<'OSRCHEAVY'
TESTING RULE: run your own unit tests only, one at a time, niced (nice -n 19). Full/heavy suites
(conformance, builds, installs, benchmarks) run in the cloud — do NOT run them on this machine;
if the task genuinely needs one, say so in your result instead of running it.
OSRCHEAVY
}
