# lib/heavy.sh — heavy-work gate (L10 add-on, round 2): full suites, builds, installs,
# benchmarks and anything estimated over ~2 minutes belong on a hosted box, not on the
# user's Mac.
#
#   osrc_heavy <command...>    -> rc 0 = heavy (reason on stderr), rc 1 = light
#   osrc_mac_load              -> prints "load_per_core=<f> swap_pct=<n> (...)"; "?" when unknown
#   _osrc_mac_overloaded       -> rc 0 when load/core > OSRC_MAC_LOAD_MAX_PC (2) or swap > 80%
#   _osrc_heavy_gate <check> <dir> <out> <secs>
#       sets OSRC_HEAVY_MODE: run (light) | nice (heavy, run locally niced) | done (handled here)
#       sets OSRC_HEAVY_RC / OSRC_HEAVY_NOTE; mode=done means $out already holds the result
#
# Round-2 contract (review L10-VERDICT): the gate NEVER launches a hosted session itself.
# With a usable vehicle AND a clean tree whose HEAD is fully on the remote, it emits
# `EVENT approval <id> <ts> heavy-check: <cmd>` + `NEXT <exact cloud start line>` (the
# orchestrator approves spend; `cloud start` then runs L7's spend gate + its own consent
# key). Identical check+sha reuses the in-flight lane id instead of re-asking. Otherwise
# local rules apply: never start on an overloaded Mac (queue + EVENT stalled), else run
# niced one at a time. rc 125 always means NOT RUN — never a pass, never a code failure.
#
# Wired into _loop_check, the single funnel for bounded check commands. Sourced by
# outsourcerer.sh; defines functions only; bash 3.2.
#
# Escape hatches: OSRC_HEAVY_OFF=1 disables the gate; OSRC_HEAVY=1 forces heavy,
# OSRC_HEAVY=0 forces light; OSRC_HEAVY_LOCAL=1 skips the cloud offer entirely.

# ---- classification ----------------------------------------------------------------------------
# Whole-command markers that apply before any splitting: explicit heavy/slow marks and
# runtime estimates (`# est 5m`, `est=90s`, `est: 2h`; unitless = minutes).
_osrc_heavy_markers() { # <cmd-lowercased> -> "heavy: <why>" | ""
  local lc="$1" est mins
  case "${OSRC_HEAVY:-auto}" in
    1) printf 'heavy: OSRC_HEAVY=1'; return 0 ;;
    0) printf 'light'; return 0 ;;
  esac
  if printf '%s' "$lc" | grep -qE '#[[:space:]]*(slow|heavy)\b|(^|[[:space:]])--(slow|heavy)\b|\bosrc_slow=1\b|\bosrc_heavy=1\b'; then
    printf 'heavy: marked slow/heavy'; return 0
  fi
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
  printf ''
}

# _osrc_heavy_segment <seg-lowercased> -> "heavy: <why>" | "light". Matches the command
# WORD (first real token after env-assignments, wrappers, flags and numeric flag-values),
# never a substring: `grep -q make README` and `ls & wait` are light.
_osrc_heavy_segment() {
  local seg="$1" tok cmd="" seen=0 skipval=0
  local -a toks rest
  set -f
  # shellcheck disable=SC2206
  toks=( $seg )
  set +f
  rest=()
  for tok in "${toks[@]}"; do
    tok="${tok//\'/}"; tok="${tok//\"/}"
    [ "$skipval" = "1" ] && { skipval=0; continue; }
    if [ "$seen" = "0" ]; then
      case "$tok" in
        ''|[0-9]*) continue ;;
        [A-Za-z_]*=*) continue ;;
        sudo|doas|env|command|nice|time|nohup|exec|builtin|stdbuf|timeout|chronic|ionice|taskset|setsid|eatmydata) continue ;;
        -u|-g|-h|-p|-U|-C|-D|-r|-t|-T|-n|-o|-e|-i|-E|-S) skipval=1; continue ;;
        -*) continue ;;
      esac
      cmd="${tok##*/}"; seen=1; continue
    fi
    rest+=("$tok")
  done
  [ -n "$cmd" ] || { printf 'light'; return 0; }
  # This repo's heavy suites, matched as arg BASENAMES (bash conformance.sh, ./x test_factory_y).
  local a base
  for a in ${rest[@]+"${rest[@]}"}; do
    base="${a##*/}"
    case "$base" in conformance*|test_factory*) printf 'heavy: test suite'; return 0 ;; esac
  done
  # A suite runner aimed at ONE explicit test FILE is an own-unit-test run -> light, unless a
  # suite-wide flag (--coverage/--watch/--all/workers/xdist -n/...) is also present.
  case "$cmd" in
    pytest|py.test|trial|nosetests|vitest|jest|mocha|ava|jasmine|qunit|tap|tape|lab|uvu|phpunit|rspec|ctest|behave|lettuce|ginkgo)
      if [ "${#rest[@]}" -gt 0 ] \
         && printf '%s\n' "${rest[@]}" | grep -qE '\.(py|py\.test|js|jsx|ts|tsx|sh|rb|php)$' \
         && ! printf '%s\n' "${rest[@]}" | grep -qE '^(--config|--setupFiles|--globalSetup|--reporters|--coverage|--all|--watch|--ci|-n|--numprocesses|--dist|--workers|--jobs|maxWorkers|max-workers)'; then
        printf 'light'; return 0
      fi
      printf 'heavy: test suite runner'; return 0 ;;
  esac
  local sub="${rest[0]:-}"
  case "$cmd" in
    # ---- shell wrappers: `sh -c`/`bash -x -lc 'cmd'` — classify the -c payload ----
    sh|bash|zsh|dash|ash|ksh)
      local si=0 sj scmd="" smode=0
      for sj in ${rest[@]+"${rest[@]}"}; do
        si=$((si+1))
        if [ "$smode" = "1" ]; then scmd="$scmd $sj"; continue; fi
        case "$sj" in --*) ;; -c|-*c) smode=1 ;; esac
      done
      [ -n "${scmd// /}" ] && { _osrc_heavy_reason "$scmd"; return; } ;;
    # ---- test suites via package runners (flags may precede the subcommand) ----
    npm|pnpm|yarn|bun)
      local i psub="" pscript="" skipnext=0
      for i in ${rest[@]+"${rest[@]}"}; do
        if [ "$skipnext" = "1" ]; then skipnext=0; continue; fi
        case "$i" in
          --filter|-F|--prefix|--dir|-C|--cwd|--workspace) skipnext=1; continue ;;
          -*) continue ;;
        esac
        if [ -z "$psub" ]; then psub="$i"; continue; fi
        [ "$psub" = "run" ] && [ -z "$pscript" ] && { pscript="$i"; break; }
      done
      # bare `yarn` (no args at all) installs; `yarn --version`, bare npm/pnpm/bun are light
      if [ -z "$psub" ] && [ "$cmd" = "yarn" ] && [ "${#rest[@]}" -eq 0 ]; then printf 'heavy: yarn install'; return 0; fi
      case "$psub" in
        test|t|ci|e2e) printf 'heavy: test suite'; return 0 ;;
        run) case "$pscript" in test|test:*|ci|e2e|build|compile|bundle|dist) printf 'heavy: %s run %s' "$cmd" "$pscript"; return 0 ;; esac ;;
        install|i|add|remove|update|unlink) printf 'heavy: install'; return 0 ;;
      esac ;;
    # ---- python -m <runner> ----
    python|python3|python3.*|pypy|pypy3)
      local mi=0 mj mod="" margs
      for mj in ${rest[@]+"${rest[@]}"}; do
        mi=$((mi+1)); [ "$mj" = "-m" ] && { mod="${rest[$mi]:-}"; break; }
      done
      case "$mod" in
        pytest|py.test|nose|nose2|unittest|stestr|tox|nox)
          # light only when EVERY positional arg is an explicit test file (own unit tests)
          margs="$(printf '%s\n' "${rest[@]}" | tail -n +$((mi+2)) 2>/dev/null)"
          if [ -n "$margs" ] \
             && ! printf '%s\n' "$margs" | grep -qvE '^[[:space:]]*[^[:space:]]+\.(py|py\.test)(::[A-Za-z_][A-Za-z0-9_]*){0,2}[[:space:]]*$' \
             && ! printf '%s\n' "$margs" | grep -qE '^-'; then
            printf 'light'; return 0
          fi
          printf 'heavy: python -m %s' "$mod"; return 0 ;;
        pip|pip3) [ "${rest[$mi+1]:-}" = "install" ] && { printf 'heavy: python -m pip install'; return 0; } ;;
      esac ;;
    # ---- npx/bunx/uvx <runner> ----
    npx|bunx|uvx)
      local nj nsub=""
      for nj in ${rest[@]+"${rest[@]}"}; do
        case "$nj" in -*) continue ;; esac
        nsub="$nj"; break
      done
      case "$nsub" in
        jest|vitest|playwright|cypress|mocha|ava|pytest|py.test|nose|nose2|rspec|phpunit|ctest|tox|nox)
          printf 'heavy: %s %s' "$cmd" "$nsub"; return 0 ;;
      esac ;;
    # ---- env runners ----
    tox|nox) printf 'heavy: env runner'; return 0 ;;
    # ---- builds ----
    go) case "$sub" in test|build|install|generate|vet) printf 'heavy: go %s' "$sub"; return 0 ;; esac ;;
    cargo) case "$sub" in build|test|bench|install|clippy|check|doc|publish|run|fix|verify-project) printf 'heavy: cargo %s' "$sub"; return 0 ;; esac ;;
    make|gmake|bmake|rake)
      # Only named heavy targets or parallel flags count — bare `make` is NOT a signal
      # (L10 verdict: `make lint`, `make`, and any loose word-match were false positives).
      case "$sub" in -j*|--jobs|-l|-k) printf 'heavy: parallel %s' "$cmd"; return 0 ;;
        test|tests|build|all|install|compile|dist|release|check|coverage|e2e) printf 'heavy: %s %s' "$cmd" "$sub"; return 0 ;; esac ;;
    docker|podman) case "$sub" in build|buildx|compose|run|pull|push|save|load|import|export) printf 'heavy: %s %s' "$cmd" "$sub"; return 0 ;; esac ;;
    xcodebuild|gradle|gradlew|mvn|mvnw|ant|sbt|mill|ninja|meson|bazel|buck|buck2) printf 'heavy: build tool'; return 0 ;;
    cmake) case "$sub" in --version|--help|-version|-help|--help-manual) ;; *) printf 'heavy: cmake configure/build'; return 0 ;; esac ;;
    swift) case "$sub" in build|test) printf 'heavy: swift %s' "$sub"; return 0 ;; esac ;;
    terraform|tofu|opentofu|pulumi|packer) printf 'heavy: infra tool'; return 0 ;;
    vagrant) case "$sub" in up|provision|build|destroy|reload|resume) printf 'heavy: vagrant %s' "$sub"; return 0 ;; esac ;;
    # ---- installs ----
    pip|pip3|pipx) case "$sub" in install|i|download|wheel) printf 'heavy: pip install'; return 0 ;; esac ;;
    uv) case "$sub" in
          sync|add|tool|venv) printf 'heavy: uv %s' "$sub"; return 0 ;;
          run)
            # `uv run <cmd>` — classify the wrapped command (`uv run pytest` is heavy)
            local uin
            uin="$(printf '%s\n' "${rest[@]}" | tail -n +2 2>/dev/null | tr '\n' ' ')"
            [ -n "${uin// /}" ] && { _osrc_heavy_reason "$uin"; return; } ;;
          pip) [ "${rest[1]:-}" = "install" ] && { printf 'heavy: uv pip install'; return 0; } ;;
        esac ;;
    poetry) case "$sub" in install|add|update|sync|lock) printf 'heavy: poetry %s' "$sub"; return 0 ;; esac ;;
    conda|mamba) case "$sub" in install|create|env) printf 'heavy: conda %s' "$sub"; return 0 ;; esac ;;
    gem) case "$sub" in install|update|fetch) printf 'heavy: gem %s' "$sub"; return 0 ;; esac ;;
    bundle|bundler) case "$sub" in install|update|add|remove) printf 'heavy: bundle %s' "$sub"; return 0 ;; esac ;;
    composer) case "$sub" in install|update|require|remove) printf 'heavy: composer %s' "$sub"; return 0 ;; esac ;;
    brew) case "$sub" in install|upgrade|update|reinstall|tap|untap) printf 'heavy: brew %s' "$sub"; return 0 ;; esac ;;
    apt|apt-get|yum|dnf|pacman|zypper|apk|snap|choco|winget|scoop)
      case "$sub" in install|i|add|upgrade|dist-upgrade|remove|purge|reinstall) printf 'heavy: package install'; return 0 ;; esac ;;
    # ---- benchmarks ----
    hyperfine|k6|artillery|autocannon|wrk|siege|phoronix|unixbench) printf 'heavy: benchmark'; return 0 ;;
    # ---- several suites/commands in parallel (explicit tools only; `&`/`;` segments are
    #      classified independently above, so `ls & wait` stays light) ----
    parallel) printf 'heavy: parallel runner'; return 0 ;;
    xargs)
      # explicit parallel flag -> heavy regardless of the wrapped command. Segments are
      # lowercased, so -P arrives as -p (attached -p4 or `-p 4` forms).
      if [ "${#rest[@]}" -gt 0 ] \
         && { printf '%s\n' "${rest[@]}" | grep -qE '^-p[0-9]|--processes[= ][0-9]' \
              || { printf '%s\n' "${rest[@]}" | grep -A1 '^-p$' | grep -qE '^[0-9]+$'; }; }; then
        printf 'heavy: xargs -P'; return 0
      fi
      # otherwise the non-flag tokens ARE the wrapped command: classify it
      local xj xargs_cmd="" xskip=0
      for xj in ${rest[@]+"${rest[@]}"}; do
        if [ "$xskip" = "1" ]; then xskip=0; continue; fi
        case "$xj" in
          -n|-i|-d|-l|-s|-e) xskip=1; continue ;;
          -*) continue ;;
        esac
        xargs_cmd="$xargs_cmd $xj"
      done
      [ -n "${xargs_cmd// /}" ] && { _osrc_heavy_reason "$xargs_cmd"; return; } ;;
  esac
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

# _osrc_heavy_split <cmd> -> one segment per line. Splits on ; & | ( ) ` OUTSIDE single and
# double quotes, so `echo "done; npm test"` stays one segment while `(npm test)`,
# `result=$(npm test)` and `` echo `npm test` `` still expose the inner command.
_osrc_heavy_split() {
  local s="$1" cur="" q="" c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    if [ -n "$q" ]; then cur="$cur$c"; [ "$c" = "$q" ] && q=""; continue; fi
    case "$c" in
      "'"|'"') q="$c"; cur="$cur$c" ;;
      ";"|"&"|"|"|"("|")"|"\`") printf '%s\n' "$cur"; cur="" ;;
      *) cur="$cur$c" ;;
    esac
  done
  printf '%s\n' "$cur"
}

# _osrc_heavy_reason <cmd> -> "heavy: <why>" | "light"
_osrc_heavy_reason() {
  local cmd="$1" lc m seg r segs
  [ -n "${cmd//[[:space:]]/}" ] || { printf 'light'; return 0; }
  lc="$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')"
  m="$(_osrc_heavy_markers "$lc")"
  [ -n "$m" ] && { printf '%s' "$m"; return 0; }
  # Compound commands: classify each separator-delimited segment; heavy if ANY is.
  segs="$(_osrc_heavy_split "$lc")"
  while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    [ -n "${seg//[[:space:]]/}" ] || continue
    r="$(_osrc_heavy_segment "$seg")"
    [ "$r" != "light" ] && { printf '%s' "$r"; return 0; }
  done <<_OSRC_HEAVY_SEGS
$segs
_OSRC_HEAVY_SEGS
  printf 'light'
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

# ---- events: L1's lanes/events.jsonl contract + stderr mirror -------------------------------
# _osrc_heavy_emit <kind> <target> <detail> <next> -> appends {ts,kind,target,detail,next,src}
# to $OSRC_HOME/lanes/events.jsonl (same schema as L7's _osrc_event / lib/supervise.sh) and
# prints the EVENT/NEXT pair to stderr so the caller's log shows it too.
_osrc_heavy_emit() {
  local kind="$1" target="$2" detail="$3" next="$4" src="${5:-heavy}"
  local ts f line
  ts="$(date +%s 2>/dev/null || echo 0)"
  if [ -n "${OSRC_HOME:-}" ]; then
    f="$OSRC_HOME/lanes/events.jsonl"; _mkdir_private "$OSRC_HOME/lanes" 2>/dev/null
    if have jq; then
      jq -cn --argjson ts "$ts" --arg k "$kind" --arg t "$target" --arg d "$detail" \
        --arg n "$next" --arg s "$src" \
        '{ts:$ts,kind:$k,target:$t,detail:$d,next:$n,src:$s}' >> "$f" 2>/dev/null || true
    else
      line="$(printf '%s' "$detail" | tr '\n"\\' '   ' | cut -c1-300)"
      printf '{"ts":%s,"kind":"%s","target":"%s","detail":"%s","next":"%s","src":"%s"}\n' \
        "$ts" "$kind" "$target" "$line" "$(printf '%s' "$next" | tr '\n"\\' '   ' | cut -c1-300)" "$src" >> "$f" 2>/dev/null || true
    fi
  fi
  printf 'EVENT %s %s %s %s\n' "$kind" "$target" "$ts" "$detail" >&2
  printf 'NEXT %s\n' "$next" >&2
}

# ---- lane id + brief (sha-pinned) --------------------------------------------------------------
# _osrc_heavy_lane_id <check> <sha> -> stable lane id for an identical check+sha. No epoch
# suffix: the SAME check on the SAME commit IS the same lane — that is the dedupe key.
_osrc_heavy_lane_id() {
  local c sha7 id
  c="$(printf '%s' "$1" | cksum 2>/dev/null | awk '{print $1}')"; c="${c:-0}"
  sha7="$(printf '%s' "$2" | cut -c1-7)"; sha7="${sha7:-unknown}"
  id="heavy-$c-$sha7"
  printf '%s' "$id"
}

# _osrc_heavy_brief <id> <check> <repo> <base> <sha> -> self-contained task file for `cloud
# start`; prints path. Pins the exact commit; RESULT must echo sha= and rc=.
_osrc_heavy_brief() {
  local id="$1" check="$2" repo="$3" base="$4" sha="$5" dir f
  [ -n "${OSRC_HOME:-}" ] || return 1
  dir="$OSRC_HOME/cloud"; _mkdir_private "$dir" 2>/dev/null || return 1
  f="$dir/$id.brief.md"
  {
    printf 'Run ONE command on the pinned commit and report its result.\n\n'
    printf 'Repository: %s\nBase branch: %s\nPinned commit: %s\n\n' "${repo:-the repository you cloned}" "${base:-the base branch}" "$sha"
    printf 'Check out commit `%s` (it is on the remote), then at the repository root run exactly:\n\n```\n%s\n```\n\n' "$sha" "$check"
    printf 'Then commit on branch `cloud/%s`:\n' "$id"
    printf -- '- `%s.RESULT`: first line `sha=%s`, second line `rc=<exit code of the command above>`, then the last ~80 lines of its combined output.\n' "$id" "$sha"
    printf -- '- `%s.READY` at the repository root containing exactly one line: `READY %s`.\n' "$id" "$id"
    printf -- '- push `cloud/%s`. Change nothing else; do not modify source files.\n' "$id"
    printf 'If the command cannot run in your environment, still write `%s.RESULT` with `sha=%s` and `rc=127` plus the error text, plus `%s.READY`, and push.\n' "$id" "$sha" "$id"
  } > "$f" 2>/dev/null || return 1
  chmod 600 "$f" 2>/dev/null
  printf '%s' "$f"
}

# ---- lane RESULT readback (finding B) --------------------------------------------------------------
# _osrc_heavy_lane_result <id> <repo> <top> <check-sha> <out>
#   rc 0 = RESULT found and sha-validated: OSRC_HEAVY_RC = its rc=, $out gets sha/rc + tail.
#   rc 1 = still in flight (fetch failed or no RESULT yet) — caller keeps rc 125.
#   rc 2 = RESULT sha mismatch — rejected, reason written to $out, OSRC_HEAVY_RC stays 125.
_osrc_heavy_lane_result() {
  local id="$1" repo="$2" top="$3" fsha="$4" out="$5"
  local res l1 l2 psha rc pack
  [ -n "$top" ] || return 1
  git -C "$top" fetch --quiet origin "cloud/$id" 2>/dev/null \
    || { [ -n "$repo" ] && git -C "$top" fetch --quiet "$repo" "cloud/$id" 2>/dev/null; } \
    || return 1
  res="$(git -C "$top" show "FETCH_HEAD:$id.RESULT" 2>/dev/null)" || return 1
  res="${res//$'\r'/}"   # CRLF line ends must not read as a sha mismatch
  l1="$(printf '%s\n' "$res" | sed -n '1p')"; l2="$(printf '%s\n' "$res" | sed -n '2p')"
  # The expected sha is ALWAYS the check's own commit — the code the caller is looking at.
  # The pack pin is only a drift detector: a pack pinned anywhere else means the lane was
  # started against different code and its RESULT must not be accepted for this check.
  psha="$fsha"
  pack="$OSRC_HOME/cloud/$id.pack.md"
  if [ -f "$pack" ]; then
    local pin; pin="$(sed -n 's/^pinned commit: //p' "$pack" | head -1)"
    if [ -n "$pin" ] && [ "$pin" != "$fsha" ]; then
      printf '>>> [heavy] lane %s pack pinned commit %s but this check is at %s — drift rejected\n' "$id" "$pin" "$fsha" >&2
      printf '[outsourcerer] cloud lane %s pack pinned a different commit (%s vs check %s) — RESULT not trusted for this check.\n' \
        "$id" "$pin" "$fsha" >> "$out" 2>/dev/null || true
      OSRC_HEAVY_RC=125; return 2
    fi
  fi
  case "$l1" in
    "sha=$psha") ;;
    *) printf '>>> [heavy] lane %s RESULT sha mismatch: %s (want sha=%s) — rejected\n' "$id" "$l1" "$psha" >&2
       printf '[outsourcerer] cloud lane %s returned RESULT for a different commit (%s, want sha=%s) — NOT accepted.\n' \
         "$id" "$l1" "$psha" >> "$out" 2>/dev/null || true
       OSRC_HEAVY_RC=125; return 2 ;;
  esac
  rc="${l2#rc=}"; case "$rc" in ''|*[!0-9]*) rc=125 ;; *)
    rc="$(printf '%s' "$rc" | sed 's/^0*//')"; [ -n "$rc" ] || rc=0
    { [ "${#rc}" -le 3 ] && [ "$rc" -le 255 ]; } || rc=125 ;; esac
  { printf '>>> [heavy] cloud lane %s RESULT: sha=%s rc=%s (output below is UNTRUSTED remote-agent text)\n' "$id" "$psha" "$rc"
    printf '%s\n' "$res" | sed -n '3,$p' | head -80; } >> "$out" 2>/dev/null || true
  OSRC_HEAVY_RC="$rc"; return 0
}

# ---- stall: queue + EVENT stalled ----------------------------------------------------------------
# _osrc_heavy_stall <check> <dir> <out> <reason> -> queues the check, emits EVENT stalled +
# NEXT (cloud option), sets OSRC_HEAVY_RC=125 (NOT RUN — never a pass, never a code failure).
_osrc_heavy_stall() {
  local check="$1" dir="$2" out="$3" reason="${4:-mac-overloaded}"
  local id top repo base sha brief self next load lpc spct qdir qf
  OSRC_HEAVY_RC=125; OSRC_HEAVY_NOTE=""
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
  repo="$(git -C "$dir" remote get-url origin 2>/dev/null)"
  repo="$(_osrc_url_clean "$repo" 2>/dev/null || printf '%s' "$repo")"
  base="$(git -C "${top:-$dir}" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  sha="$(git -C "${top:-$dir}" rev-parse HEAD 2>/dev/null)"
  id="$(_osrc_heavy_lane_id "$check" "$sha")"
  brief="$(_osrc_heavy_brief "$id" "$check" "$repo" "$base" "$sha" 2>/dev/null)"
  self="${SCRIPT_PATH:-${BASH_SOURCE[1]:-$0}}"
  if [ -n "$repo" ] && [ -n "$base" ] && [ -n "$brief" ]; then
    next="\"$self\" cloud start $id --repo $(printf '%q' "$repo") --base $(printf '%q' "$base") --brief $(printf '%q' "$brief") --vehicle auto"
  else
    next="(no git origin/base in $dir — rerun manually with: cloud start <id> --repo <owner/name> --base <branch> --brief <file>)"
  fi
  if [ -n "${OSRC_HOME:-}" ]; then
    qdir="$OSRC_HOME/heavy-queue"; _mkdir_private "$qdir" 2>/dev/null
    qf="$qdir/$id.cmd"
    { printf '# queued heavy check %s (%s) — NOT RUN locally (rc 125 means not-run)\n' "$(date +%s)" "$reason"
      printf 'dir: %s\ncheck: %s\nsha: %s\n' "$dir" "$check" "$sha"
      printf 'cloud option: %s\n' "$next"; } > "$qf" 2>/dev/null || true
  fi
  load="$(osrc_mac_load 2>/dev/null)"
  lpc="$(printf '%s' "$load" | sed -n 's/.*load_per_core=\([^ ]*\).*/\1/p')"; lpc="${lpc:-?}"
  spct="$(printf '%s' "$load" | sed -n 's/.*swap_pct=\([^ ]*\).*/\1/p')"; spct="${spct:-?}"
  _osrc_heavy_emit stalled "$id" "heavy-check: $(printf '%s' "$check" | cut -c1-120) ($reason) load_per_core=$lpc swap_pct=$spct" "$next" heavy >&2
  printf '[outsourcerer] heavy check queued as lane %s (%s); it did NOT run locally. Cloud option:\n%s\n' \
    "$id" "$reason" "$next" >> "$out" 2>/dev/null || true
  return 0
}

# ---- local serialization: one heavy check at a time ----------------------------------------------
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
# NEVER launches: cloud is an OFFER (EVENT approval + NEXT) only when a vehicle is usable AND
# the tree is clean with HEAD fully on the remote; the sha is pinned into the brief.
_osrc_heavy_gate() {
  OSRC_HEAVY_MODE="run"; OSRC_HEAVY_RC=1; OSRC_HEAVY_NOTE=""
  [ "${OSRC_HEAVY_OFF:-0}" = "1" ] && return 0
  local check="$1" dir="$2" out="$3" secs="${4:-300}" reason
  reason="$(_osrc_heavy_reason "$check")"
  [ "$reason" = "light" ] && return 0
  printf '%s\n' "$reason" >&2
  local top repo base sha id brief veh self next dirty unpushed
  # --- cloud OFFER (never a launch) ----------------------------------------------------------
  if [ "${OSRC_HEAVY_LOCAL:-0}" != "1" ] && declare -F cmd_cloud >/dev/null 2>&1 \
     && declare -F _cloudrun_pick_vehicle >/dev/null 2>&1; then
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
    repo="$(git -C "$dir" remote get-url origin 2>/dev/null)"
    repo="$(_osrc_url_clean "$repo" 2>/dev/null || printf '%s' "$repo")"
    base="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    sha="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
    if [ -n "$top" ] && [ -n "$repo" ] && [ -n "$base" ] && [ -n "$sha" ]; then
      dirty="$(git -C "$dir" status --porcelain 2>/dev/null | head -1)"
      unpushed="$(git -C "$dir" rev-list --count HEAD --not --remotes 2>/dev/null)"
      case "$unpushed" in ''|*[!0-9]*) unpushed=0 ;; esac
      if [ -z "$dirty" ] && [ "$unpushed" = "0" ]; then
        if veh="$(_cloudrun_pick_vehicle auto "${OSRC_CODEX_CLOUD_ENV:-}" 2>/dev/null)"; then
          id="$(_osrc_heavy_lane_id "$check" "$sha")"
          self="${SCRIPT_PATH:-${BASH_SOURCE[1]:-$0}}"
          if [ -n "${OSRC_HOME:-}" ] && [ -e "$OSRC_HOME/remote/$id.json" ]; then
            # identical check+sha already has a lane: read its RESULT back if it landed
            local lrrc=0
            _osrc_heavy_lane_result "$id" "$repo" "$top" "$sha" "$out" && { OSRC_HEAVY_MODE="done"; return 0; }
            lrrc=$?
            if [ "$lrrc" = "2" ]; then
              # RESULT rejected (sha mismatch / pack drift): terminal for this lane id.
              # One `failed` event per id; the outfile says how to retire the lane and re-offer.
              local evf="$OSRC_HOME/lanes/events.jsonl" evhits=""
              [ -f "$evf" ] && evhits="$(grep -F "\"target\":\"$id\"" "$evf" 2>/dev/null)"
              grep -q '"kind":"failed"' <<<"$evhits" \
                || _osrc_heavy_emit failed "$id" "heavy-check RESULT rejected: sha mismatch (see lane log)" "\"$self\" cloud ls" heavy >&2
              printf '[outsourcerer] heavy check NOT RUN: cloud lane %s returned a RESULT that failed sha validation — rejected. To retire the lane and re-offer: rm -f %s/remote/%s.json %s/cloud/%s.brief.md %s/cloud/%s.pack.md, then rerun this check.\n' \
                "$id" "$OSRC_HOME" "$id" "$OSRC_HOME" "$id" "$OSRC_HOME" "$id" >> "$out" 2>/dev/null || true
            else
              # still in flight: reuse the lane, never re-ask
              printf '>>> [heavy] identical check+sha already delegated to lane %s — not re-asking\n' "$id" >&2
              _osrc_heavy_emit delegated "$id" "heavy-check already in flight: $(printf '%s' "$check" | cut -c1-100) @ ${sha:0:7}" "\"$self\" cloud ls" heavy >&2
              printf '[outsourcerer] heavy check NOT RUN: identical check+sha already delegated to cloud lane %s (see `cloud ls`).\n' "$id" >> "$out" 2>/dev/null || true
            fi
            OSRC_HEAVY_RC=125; OSRC_HEAVY_MODE="done"; return 0
          fi
          brief="$(_osrc_heavy_brief "$id" "$check" "$repo" "$base" "$sha" 2>/dev/null)"
          if [ -n "$brief" ]; then
            # NEXT carries the EXACT offered vehicle + pinned sha (never --vehicle auto,
            # never a drifting HEAD); devin's metered lane needs the per-launch --spend-ok.
            local spendflag="" evf evhits dup=0
            [ "$veh" = "devin" ] && spendflag=" --spend-ok"
            next="\"$self\" cloud start $id --repo $(printf '%q' "$repo") --base $(printf '%q' "$base") --brief $(printf '%q' "$brief") --vehicle $veh$spendflag --sha $sha"
            # one approval EVENT per lane id — repeats of the same offer do not re-ask
            evf="$OSRC_HOME/lanes/events.jsonl"
            if [ -f "$evf" ]; then
              evhits="$(grep -F "\"target\":\"$id\"" "$evf" 2>/dev/null)"
              grep -q '"kind":"approval"' <<<"$evhits" && dup=1
            fi
            printf '>>> [heavy] %s — cloud lane %s offered (%s); awaiting approval, NOT launched\n' "$reason" "$id" "$veh" >&2
            [ "$dup" = "0" ] && _osrc_heavy_emit approval "$id" \
              "heavy-check: $(printf '%s' "$check" | cut -c1-120) @ ${sha:0:7} — clean pushed tree; NEXT approves the hosted session (local alt: rerun this check with OSRC_HEAVY_LOCAL=1, niced+serialized)" \
              "$next  # local alternative: OSRC_HEAVY_LOCAL=1 <same check> (niced, one at a time)" heavy >&2
            printf '[outsourcerer] heavy check NOT RUN locally: cloud lane %s offered (EVENT approval above). To approve: %s\nLocal niced alternative: rerun the same check with OSRC_HEAVY_LOCAL=1 (serialized, nice -n 19).\n' \
              "$id" "$next" >> "$out" 2>/dev/null || true
            OSRC_HEAVY_RC=125; OSRC_HEAVY_MODE="done"; return 0
          fi
        fi
      else
        OSRC_HEAVY_NOTE="cloud not offered: tree not clean/pushed (dirty or unpushed commits)"
        printf '>>> [heavy] %s — falling back to local rules\n' "$OSRC_HEAVY_NOTE" >&2
      fi
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

# _osrc_loop_notrun <kind> <lid> <attempt> <ldir> -> rc-125 NOT RUN bookkeeping for loop
# callers: persist the reason where `loop status`/resume reads it and announce the stop on
# stderr. Best-effort — the caller's state change is what matters.
_osrc_loop_notrun() {
  printf 'acceptance check NOT RUN (heavy-work gate: cloud approval pending, lane already delegated, or Mac overloaded)\n' \
    > "$4/last_fail" 2>/dev/null || true
  echo "[loop $1] $2: acceptance check NOT RUN on attempt $3 — the heavy-work gate did not execute it (see EVENT/NEXT above and $4/last_fail). Stopping: there is no result to iterate or escalate on." >&2
}

# _osrc_heavy_prompt -> the testing-discipline block injected into generated lane briefs.
_osrc_heavy_prompt() {
  cat <<'OSRCHEAVY'
TESTING RULE: run your own unit tests only, one at a time, niced (nice -n 19). Full/heavy suites
(conformance, builds, installs, benchmarks) run in the cloud — do NOT run them on this machine;
if the task genuinely needs one, say so in your result instead of running it.
OSRCHEAVY
}
