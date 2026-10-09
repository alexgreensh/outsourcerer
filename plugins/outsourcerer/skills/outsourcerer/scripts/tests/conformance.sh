#!/usr/bin/env bash
# conformance.sh — U5: per-lane conformance harness (the don't-ship-blind gate).
#
# TWO layers:
#   STATIC  (always): every Phase-0 security/routing invariant is wired (aggregates the unit tests +
#           cross-checks the source). Fast, deterministic, CI-safe, no cost.
#   LIVE    (opt-in, OSRC_CONFORMANCE_LIVE=1): drives each AVAILABLE lane under the effort x tools x
#           real-repo matrix that exposed every "passed the smoke test, failed the real run" bug —
#           asserts the lane actually runs a tool and honors the exit contract. Skips absent lanes.
#
# Run:  bash conformance.sh            # static gate only
#       OSRC_CONFORMANCE_LIVE=1 bash conformance.sh   # + live lane probes (uses quota/tokens)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Sweep stale scratch dirs from crashed runs so they don't accumulate across runs (only inside our tests dir).
if [ -d "$SCRIPT_DIR" ] && [ "$(cd "$SCRIPT_DIR" && pwd)" = "$SCRIPT_DIR" ]; then
  find "$SCRIPT_DIR" -maxdepth 1 -type d \( -name '.test-*' -o -name '.conformance-run-*' \) -exec rm -rf {} + 2>/dev/null
fi

pass=0; fail=0; skip=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }
note() { echo "SKIP: $1"; skip=$((skip+1)); }

echo "=== STATIC gate: Phase-0 invariants wired ==="

# 1. Every unit test suite is green (aggregate).
_ALL_SUITES="test_cloud_gate test_no_silent_escalation test_hardening test_escalation_classify \
         test_devin_tls_diagnostics test_devin_printmode_hang test_lane_fallback test_interactive_default test_session_capabilities \
         test_harness_isolation test_autodetach test_advise test_claudex test_copilot \
         test_loops test_job_lifecycle test_output_truncation test_lane_accounting \
         test_selfcontained_hardening test_trusted_lanes test_parity_links test_parity_hermes test_watch_digest \
         test_cc_devin_selfheal test_cloud_gate_coverage test_cost_disclosure \
         test_parser_parity test_resolved_lane test_limits_freshness test_gemini_lane test_watcher \
         test_marker_forgery test_loop_resume test_lane_liveness \
         test_with_injection test_no_phantom_jobs test_model_drift test_model_pin_enforcement test_perm_denial_precision test_devin_liveness test_windows_portability \
         test_devin_alias_resolution test_build_target test_mutation_state_durability test_wake_queue \
         test_heartbeat_ownership test_bearings test_external_sessions test_external_send_opt_in test_session_claims test_session_reply_safety test_obligations"
_ALL_SUITES="$_ALL_SUITES test_reverdict_residuals"
_ALL_SUITES="$_ALL_SUITES test_session_effort"
_ALL_SUITES="$_ALL_SUITES test_model_selection_parity"
_ALL_SUITES="$_ALL_SUITES test_heartbeat_human"
_ALL_SUITES="$_ALL_SUITES test_endpoint_mutation_lock test_relaunch_bookkeeping test_noglob_splitting"
_ALL_SUITES="$_ALL_SUITES test_heartbeat_reclaim"
_ALL_SUITES="$_ALL_SUITES test_devin_org_policy_posture"
_ALL_SUITES="$_ALL_SUITES test_heartbeat_wake_push"
_ALL_SUITES="$_ALL_SUITES test_session_registry_end"
_ALL_SUITES="$_ALL_SUITES test_heartbeat_single_instance"
_ALL_SUITES="$_ALL_SUITES test_cc_model_restore"
_ALL_SUITES="$_ALL_SUITES test_vocab_hygiene"
_ALL_SUITES="$_ALL_SUITES test_tool_bugs_062"
_ALL_SUITES="$_ALL_SUITES test_managed_send"
_ALL_SUITES="$_ALL_SUITES test_parity_autoheal"
_ALL_SUITES="$_ALL_SUITES test_pr10_falsestall_before_quota"
_ALL_SUITES="$_ALL_SUITES test_cline_lane"
_ALL_SUITES="$_ALL_SUITES test_skill_bundle"
_ALL_SUITES="$_ALL_SUITES test_gemini_catalog"
_ALL_SUITES="$_ALL_SUITES test_tab_empty_ledger"
_ALL_SUITES="$_ALL_SUITES test_tokenrouter_lane"
_ALL_SUITES="$_ALL_SUITES test_fleet_cc_peers"
_ALL_SUITES="$_ALL_SUITES test_fleet_states"
_ALL_SUITES="$_ALL_SUITES test_fleet_names"
_ALL_SUITES="$_ALL_SUITES test_devin_free_guard"
_ALL_SUITES="$_ALL_SUITES test_fg_guard_forgery test_fanout_json test_version_gate test_version_parity test_explain"
_ALL_SUITES="$_ALL_SUITES test_tap_statusline"
_ALL_SUITES="$_ALL_SUITES test_detection test_pane_state test_wait test_feature_fixes test_droid_session"
_ALL_SUITES="$_ALL_SUITES test_loop_escalate test_second_opinion_agree test_catalog_validation"
_ALL_SUITES="$_ALL_SUITES test_value_router"
_ALL_SUITES="$_ALL_SUITES test_advise_dynamic_pool"
_ALL_SUITES="$_ALL_SUITES test_bg_provider_after_verb"
_ALL_SUITES="$_ALL_SUITES test_tmux_headless_fallback"
_ALL_SUITES="$_ALL_SUITES test_devin_catalog_free_tier"
_ALL_SUITES="$_ALL_SUITES test_require_interactive"
_ALL_SUITES="$_ALL_SUITES test_session_send_verify"
_ALL_SUITES="$_ALL_SUITES test_session_control"
_ALL_SUITES="$_ALL_SUITES test_codex_code_mode_host"
_ALL_SUITES="$_ALL_SUITES test_blind_turn_guard"
_ALL_SUITES="$_ALL_SUITES test_quota"
_ALL_SUITES="$_ALL_SUITES test_model_denylist"
_ALL_SUITES="$_ALL_SUITES test_utf8_guard"
_ALL_SUITES="$_ALL_SUITES test_supervise_pgroup_kill"
_ALL_SUITES="$_ALL_SUITES test_session_model_pin_guard"
_ALL_SUITES="$_ALL_SUITES test_session_exit_liveness"
_ALL_SUITES="$_ALL_SUITES test_lifecycle_fix"
_ALL_SUITES="$_ALL_SUITES test_state_lock_stale_breaker"
_ALL_SUITES="$_ALL_SUITES test_heartbeat_immortal_beacon"
_ALL_SUITES="$_ALL_SUITES test_gemini_effort_retry"
_ALL_SUITES="$_ALL_SUITES test_preflight_guard_exempt"
_ALL_SUITES="$_ALL_SUITES test_preflight_env_isolation"
_ALL_SUITES="$_ALL_SUITES test_heartbeat_arm_liveness test_heartbeat_autoarm test_heartbeat_stale_alarm test_heartbeat_rearm_command"
_ALL_SUITES="$_ALL_SUITES test_tier_churn"
_ALL_SUITES="$_ALL_SUITES test_lane_down_marker test_lane_down_gate test_delegate_attribution"
_ALL_SUITES="$_ALL_SUITES test_devin_plan_quota test_nowrite_watchdog test_advise_task_shape"
_ALL_SUITES="$_ALL_SUITES test_devin_plan_quota_probe"
_ALL_SUITES="$_ALL_SUITES test_lane_plan_limit"
_ALL_SUITES="$_ALL_SUITES test_failover_pick"
_ALL_SUITES="$_ALL_SUITES test_job_rc_guard_leak"
_ALL_SUITES="$_ALL_SUITES test_devin_edit_note"
_ALL_SUITES="$_ALL_SUITES test_conformance_suite_timeout"
# Per-suite wall-clock bound. A suite that wedges must fail the gate loudly and quickly, not park
# it: one contributor run sat for 16+ hours on ~7 cores because a busy-spinning suite had no time
# bound. Default 600s, override with OSRC_SUITE_TIMEOUT (seconds; 0 disables the bound; a
# non-numeric value falls back to the default). The kill reuses outsourcerer.sh's _kill_tree
# technique (recursive ppid walk, TERM, grace, KILL; no setsid, no `kill -- -PGID`, no `timeout`
# binary), because killing only the direct child leaves a suite's forked racers and background
# jobs spinning, and that is the incident itself. The engine is NOT sourced; the walk is mirrored
# here so the gate stays independent of the code it gates.
_SUITE_TIMEOUT_DEFAULT=600
_suite_descendants() {   # echo ALL descendant pids of $1 (recursive, parent-before-child order)
  local p
  if have pgrep; then
    for p in $(pgrep -P "$1" 2>/dev/null); do echo "$p"; _suite_descendants "$p"; done
  else
    # No pgrep (Git Bash / MSYS): derive children from `ps`. Column layout DIFFERS: System-V `ps -ef`
    # is "UID PID PPID ..." but MSYS `ps` is "PID PPID ...", so locate the PID/PPID columns from the
    # header instead of assuming positions.
    ps -ef 2>/dev/null | awk -v pp="$1" '
      NR==1 { for(i=1;i<=NF;i++){ u=toupper($i); if(u=="PID")pc=i; else if(u=="PPID")ppc=i } next }
      (pc && ppc && $ppc==pp) { print $pc }
    ' | while IFS= read -r p; do [ -n "$p" ] && { echo "$p"; _suite_descendants "$p"; }; done
  fi
}
_suite_kill_tree() {   # TERM the whole subtree deepest-first, then KILL survivors.
  local pid="$1" all rev p
  all="$pid $(_suite_descendants "$pid")"
  rev=""; for p in $all; do rev="$p $rev"; done          # reverse -> deepest child first, root last
  for p in $rev; do kill -TERM "$p" 2>/dev/null; done
  sleep 2
  all="$pid $(_suite_descendants "$pid")"; rev=""; for p in $all; do rev="$p $rev"; done
  for p in $rev; do kill -KILL "$p" 2>/dev/null; done
}
_suite_ppid_of() {   # echo the ppid of $1; empty when it cannot be determined (treated as "not ours")
  local out
  out="$(ps -o ppid= -p "$1" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$out" ]; then printf '%s' "$out"; return; fi
  # ps without -o/-p (some busybox/MSYS builds): locate the PID/PPID columns from the header,
  # same as the no-pgrep branch above.
  ps -ef 2>/dev/null | awk -v me="$1" '
    NR==1 { for(i=1;i<=NF;i++){ u=toupper($i); if(u=="PID")pc=i; else if(u=="PPID")ppc=i } next }
    (pc && ppc && $pc==me) { print $ppc }
  '
}
_run_unit_suite_bounded() {   # <suite.sh>; results in _suite_out, _suite_rc, _suite_timed_out, _suite_secs
  # Capture rather than discard: a failing suite whose output went to /dev/null makes a CI log say
  # "test_x FAILED" and nothing else, which is the difference between a fixable report and a mystery.
  # Output goes through a private file, not the command-substitution pipe: a missed grandchild
  # holding that pipe would keep the capture blocked long after the bound fired. Static suites must
  # not inherit a live status beacon; it can outlive a focused test and perturb unrelated
  # supervisor-label assertions. Fresh OSRC_HOME per suite: a shared home let one suite's
  # jobs/sessions/locks/registry state perturb a later tmux/session-heavy suite, so suites that
  # pass standalone failed only in the aggregate. Isolate the state (a suite that sets its own
  # OSRC_HOME still overrides this).
  local suite="$1" secs out_file pid_file expired _home root wd_pid _st
  _suite_out=""; _suite_rc=0; _suite_timed_out=0; _suite_secs=""
  case "${OSRC_SUITE_TIMEOUT:-}" in
    0) secs=0 ;;                                   # 0 explicitly disables the bound
    ''|*[!0-9]*) secs="$_SUITE_TIMEOUT_DEFAULT" ;; # unset or non-numeric falls back to the default
    *) secs="$OSRC_SUITE_TIMEOUT" ;;
  esac
  _suite_secs="$secs"
  out_file="$(mktemp "${TMPDIR:-/tmp}/osrc-suite-out.XXXXXX")" || { _suite_rc=127; return 127; }
  pid_file="$out_file.pid"
  expired="$out_file.expired"
  # Never risk an empty OSRC_HOME: the suite would run against the user's real ~/.outsourcerer.
  _home="$(mktemp -d)" || { rm -f "$out_file" 2>/dev/null; _suite_rc=127; return 127; }
  # The SUITE stays in the FOREGROUND. A background job starts with SIGINT/SIGQUIT ignored, and a
  # shell cannot trap or reset a signal that was ignored at entry, so every INT trap in a suite or
  # in the engine (_supervise, the obligation guard, the fifo streamer, the fallback runner) would
  # silently never install, and the suites would prove something different from before. Only the
  # WATCHDOG is backgrounded. The root pid reaches it through a file: bash -c writes its own pid
  # (exec keeps it, so it IS the suite root) plus the ppid it was launched with, and the watchdog
  # reads both after the bound expires. The ppid is recorded at launch instead of compared against
  # $$ later because $$ keeps the TOP-level shell's pid inside subshells (bash 3.2 has no
  # BASHPID), so any caller from a subshell would make a $$ comparison read the wrong parent.
  wd_pid=""
  if [ "$secs" -gt 0 ] 2>/dev/null; then
    # Pure-bash watchdog (works on macOS bash 3.2, Linux, Git Bash: no timeout/setsid/pgid kills).
    # When the suite finishes first, TERM makes this subshell kill its own sleep and exit, so no
    # stray sleep outlives the suite. When the timer wins, the suite is killed WITH its whole tree.
    (
      _wd_sleep=""
      trap '[ -n "$_wd_sleep" ] && kill "$_wd_sleep" 2>/dev/null; exit 0' TERM
      sleep "$secs" & _wd_sleep=$!
      wait "$_wd_sleep"
      # Tolerate a pidfile that does not exist yet, or a suite already gone.
      root=""; _pp0=""
      [ -f "$pid_file" ] && read -r root _pp0 < "$pid_file" 2>/dev/null
      case "$root" in ''|*[!0-9]*) exit 0 ;; esac
      case "${_pp0:-}" in ''|*[!0-9]*) exit 0 ;; esac
      # A zombie means the suite just exited on its own and is merely unreaped; its real exit
      # code must win over the bound.
      _st="$(ps -o state= -p "$root" 2>/dev/null | tr -d '[:space:]')"
      # ps without -o state= (busybox/Alpine) yields nothing even for a live PID; fall back to the
      # portable kill -0 liveness probe so the bound still fires.
      if [ -z "$_st" ] && kill -0 "$root" 2>/dev/null; then _st="R"; fi
      case "$_st" in Z*|"" ) exit 0 ;; esac
      # Never kill a recycled pid: act only while the root still has the ppid it was launched
      # with, which is the gate shell that ran it (the gate blocks on the foreground suite, so
      # the ppid cannot legitimately change while the suite is ours).
      [ "$(_suite_ppid_of "$root")" = "$_pp0" ] || exit 0
      : > "$expired" 2>/dev/null
      _suite_kill_tree "$root" 2>/dev/null
    ) &
    wd_pid=$!
  fi
  _suite_pid_file="$pid_file"
  # The caller's fd2 is scoped to /dev/null around the foreground run: when the watchdog kills
  # the suite, THIS shell would print a "Terminated: 15" diagnostic for its foreground child into
  # the gate log, which is exactly the noise the timeout report replaces. The suite's own stderr
  # is unaffected (its command redirect sends it to the capture file).
  { OSRC_HOME="$_home" OSRC_HEARTBEAT_DISABLED=1 bash -c 'echo "$$ $PPID" > "$1"; exec bash "$2"' _ "$pid_file" "$suite" >"$out_file" 2>&1; _suite_rc=$?; } 2>/dev/null
  _suite_pid_file=""
  if [ -n "$wd_pid" ] && [ -f "$expired" ]; then
    # Timer won: let the watchdog finish its kill, then walk the tree once more so a descendant
    # that ignored TERM (the wedged-tool shape) is KILLed rather than left spinning.
    wait "$wd_pid" 2>/dev/null
    root=""
    [ -f "$pid_file" ] && root="$(cat "$pid_file" 2>/dev/null | tr -d '[:space:]')"
    case "$root" in *[!0-9]*|"") root="" ;; *) _suite_kill_tree "$root" 2>/dev/null ;; esac
    _suite_timed_out=1
    _suite_rc=124
  elif [ -n "$wd_pid" ]; then
    kill "$wd_pid" 2>/dev/null; wait "$wd_pid" 2>/dev/null
  fi
  _suite_out="$(cat "$out_file" 2>/dev/null)"
  rm -f "$out_file" "$pid_file" "$expired" 2>/dev/null
  rm -rf "$_home" 2>/dev/null
  return 0
}
_report_unit_suite_result() {   # <suite-name>; reads the _suite_* state _run_unit_suite_bounded set
  if [ "$_suite_timed_out" -eq 1 ]; then
    bad "unit suite $1 TIMED OUT after ${_suite_secs}s"
    printf '%s\n' "$_suite_out" | grep -E '^(FAIL|SKIP)' | sed 's/^/      /'
  elif [ "$_suite_rc" -eq 0 ]; then ok "unit suite $1 green"
  else
    bad "unit suite $1 FAILED"
    printf '%s\n' "$_suite_out" | grep -E '^(FAIL|SKIP)' | sed 's/^/      /'
  fi
}
# Ctrl-C must still stop everything, including a suite that ignores INT: the terminal already
# signals the whole foreground group, this sweep also kills the current suite's tree, then the
# gate itself exits instead of rolling on to the next suite.
_gate_int_sweep() {
  [ -n "${_suite_pid_file:-}" ] && [ -f "$_suite_pid_file" ] || return 0
  local root pp0
  read -r root pp0 < "$_suite_pid_file" 2>/dev/null || return 0
  case "$root" in ''|*[!0-9]*) return 0 ;; esac
  case "${pp0:-}" in ''|*[!0-9]*) return 0 ;; esac
  # Same recycled-pid guard as the watchdog: only sweep a root that still has the ppid it was
  # launched with, i.e. a child of this gate.
  [ "$(_suite_ppid_of "$root")" = "$pp0" ] || return 0
  _suite_kill_tree "$root" 2>/dev/null
}
trap '_gate_int_sweep; exit 130' INT
for t in $_ALL_SUITES; do
  if [ -f "$SCRIPT_DIR/$t.sh" ]; then
    _run_unit_suite_bounded "$SCRIPT_DIR/$t.sh"
    _report_unit_suite_result "$t"
  else note "unit suite $t absent"; fi
done

# 2. Security choke points present in source (defense-in-depth cross-check).
grep -q '_cloud_disclose "$disp"'                 "$SRC" && ok "U1 cloud gate wired at route_delegate choke point" || bad "U1 gate missing"
grep -q 'protected path needs --allow-downgrade'  "$SRC" && ok "U2 no-silent-escalation default present"          || bad "U2 default missing"
grep -q 'SECURITY DOWNGRADE'                      "$SRC" && ok "U2 downgrade is labeled, not silent"               || bad "U2 label missing"
grep -q '_validate_model_token'                   "$SRC" && ok "U3 model-token injection guard present"            || bad "U3 guard missing"
grep -q '_is_transport_failure'                   "$SRC" && ok "U4 transport-vs-task classifier present"           || bad "U4 classifier missing"
grep -q '_devin_model_for'                        "$SRC" && ok "availability-aware routing present"             || bad "availability-aware routing missing"
grep -q 'Read Edit Write Bash Grep Glob'          "$SRC" && ok "U7 mutating coding toolset granted (no bash wedge)" || bad "U7 toolset missing"
grep -q '_autodetach_should'                       "$SRC" && ok "D3 auto-detach trigger present"                       || bad "D3 trigger missing"
grep -q '_lane_trusted_for_pwd'                    "$SRC" && ok "per-repo lane trust resolver present"                  || bad "trust resolver missing"
grep -qE 'export[[:space:]]+OSRC_TRUST_LANE_ONCE'  "$SRC" && bad "per-invocation trust grant is exported (child jobs would inherit it)" || ok "trust grant is never exported (no inheritance)"
grep -q '_autodetach_run.*_bg_launch\|_bg_launch'  "$SRC" && ok "D3 auto-detach reuses bg machinery"                    || bad "D3 reuse missing"
grep -q '_blind_turn_guard'                          "$SRC" && ok "blind-turn guard present (refuses to end blind on live work)" || bad "blind-turn guard missing"
grep -q 'OSRC_BLIND_TURN_GUARD'                      "$SRC" && ok "blind-turn guard has an escape hatch"                  || bad "blind-turn guard escape hatch missing"
awk '/^main\(\)/,0' "$SRC" | grep -q '_blind_turn_guard' && ok "blind-turn guard is wired at turn-end in main"        || bad "blind-turn guard not wired in main"

# 2a. TEST REGISTRATION: a suite that exists but is not in the list above never runs. Four suites sat
# unregistered in this directory for a full release cycle, green locally and never executed by the
# gate. An unrun test is indistinguishable from no test, except that it looks like coverage.
_unreg=""
for _f in "$SCRIPT_DIR"/test_*.sh; do
  _n="$(basename "$_f" .sh)"
  case " $_ALL_SUITES " in *" $_n "*) ;; *) _unreg="$_unreg $_n" ;; esac
done
[ -z "$_unreg" ] && ok "every test_*.sh in this directory is registered with the runner" \
  || bad "test suite(s) present but never run by the gate:$_unreg"

# 2b. INSTALL DRIFT: a second installed copy running different code than this one is the failure that
# makes every other gate here meaningless — the suite passes against a tree the user never executes.
# It has bitten twice: a stale standalone copy running old code, and edits made in one copy silently
# overwritten by a sync from the other.
_alt="$HOME/.claude/skills/outsourcerer/scripts/outsourcerer.sh"
if [ -f "$_alt" ] && [ "$(cd "$(dirname "$_alt")" && pwd -P)" != "$(cd "$(dirname "$SRC")" && pwd -P)" ]; then
  if cmp -s "$SRC" "$_alt"; then ok "second installed copy is byte-identical to this one"
  else bad "INSTALL DRIFT: $_alt differs from the tree under test — one of them is running stale code"; fi
fi

# 3. bash -n on the script + all sibling shell scripts.
for f in "$SRC" "$SCRIPT_DIR"/../run-or-model.sh "$SCRIPT_DIR"/../run-or-codex.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then ok "bash -n clean: $(basename "$f")"; else bad "bash -n FAILED: $(basename "$f")"; fi
done

echo
echo "=== LIVE lane matrix (effort x tools x real-repo) ==="
if [ "${OSRC_CONFORMANCE_LIVE:-0}" != "1" ]; then
  note "live lane probes skipped (set OSRC_CONFORMANCE_LIVE=1 to run; uses quota/tokens)"
else
  # Build a tiny real-repo fixture with a nonce the lane must READ (proves a real tool call).
  FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
  nonce="OSRC-$$-CONFORMANCE"
  printf '%s\n' "$nonce" > "$FIX/nonce.txt"
  probe_lane() { # <label> <args...>
    local label="$1"; shift
    local out rc
    # OSRC_NO_AUTODETACH=1: the probe captures stdout (non-TTY), which would trigger D3 auto-detach
    # on capable/frontier tiers and return a job-id receipt instead of the answer — a false FAIL.
    out="$( cd "$FIX"; OSRC_CLOUD_ACK=1 OSRC_NO_AUTODETACH=1 "$SRC" "$@" --effort high "Read ./nonce.txt and reply with ONLY its contents." 2>&1 )"; rc=$?
    if printf '%s' "$out" | grep -q "$nonce"; then ok "LIVE $label: read the fixture (real tool call), rc=$rc"
    elif [ "$rc" -ne 0 ]; then note "LIVE $label: lane unavailable/failed (rc=$rc) — $(printf '%s' "$out" | tail -1)"
    else bad "LIVE $label: ran but did NOT read the nonce (tool grant broken?)"; fi
  }
  # Devin GLM (availability-aware routing fix — this is the exact path that used to 403 on OpenRouter).
  if have devin && devin auth status 2>/dev/null | grep -qi "logged in"; then
    probe_lane "devin/glm" run -m glm
  else note "LIVE devin: not installed / not logged in"; fi
  # Native Claude (subscription) if present.
  if have claude; then probe_lane "claude-native" run -m haiku; else note "LIVE claude-native: claude CLI absent"; fi
  # OpenRouter cc lane only if a key is present AND not over quota (best-effort).
  if grep -qE '^[[:space:]]*(export[[:space:]]+)?OPENROUTER_API_KEY=' "$HOME/.env" 2>/dev/null; then
    probe_lane "cc/openrouter-glm" --provider cc run -m glm
  else note "LIVE cc/openrouter: no OPENROUTER_API_KEY"; fi
fi

echo
echo "RESULT: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
