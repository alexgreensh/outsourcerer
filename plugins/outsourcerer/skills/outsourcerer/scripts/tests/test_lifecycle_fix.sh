#!/usr/bin/env bash
# Regression coverage for the 0.10.1 lifecycle / registry / heartbeat supervision fixes.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
TMP="$(mktemp -d "$PWD/.test-lifecycle-fix.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

# A single finalizer owns the ordering used by every interactive launch path.
(
  set --
  export OSRC_HOME="$TMP/finalize-home" OSRC_HEARTBEAT_DISABLED=1 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  order=""
  _session_launch_liveness_check() { order="$order liveness"; return 0; }
  _session_registry_append() { [ "${SESSION_NAME:-}" = finalize ] || return 1; order="$order registry"; return 0; }
  _heartbeat_start() { order="$order heartbeat"; return 0; }
  _managed_endpoint_live() { [ "${1:-}" = finalize ] && [ "${2:-}" = finalize ] || return 1; order="$order endpoint"; return 0; }
  _session_launch_finalize finalize devin glm high 'devin --model glm'
  [ "$order" = ' liveness registry heartbeat endpoint' ]
) && ok "interactive launch finalizer proves liveness, persists registry, arms heartbeat, then registers endpoint" \
  || bad "interactive launch finalizer is missing or has the wrong order"

# Auto-detach must fail closed when tmux accepts the session but rejects the command handoff.
(
  set --
  export OSRC_HOME="$TMP/autodetach-home" OSRC_REQUIRE_INTERACTIVE=1 OSRC_SOURCED=1
  mkdir -p "$TMP/bin-auto"
  cat > "$TMP/bin-auto/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  new-session) exit 0 ;;
  send-keys) printf 'send-keys\n' >> "$OSRC_TMUX_LOG"; exit 1 ;;
  kill-session) printf 'kill-session\n' >> "$OSRC_TMUX_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$TMP/bin-auto/tmux"
  export PATH="$TMP/bin-auto:$PATH" OSRC_TMUX_LOG="$TMP/tmux-auto.log"
  PROVIDER=devin; MODEL=glm
  . "$SRC" >/dev/null 2>&1
  _bg_cloud_preack() { return 0; }
  set +e
  out="$(_autodetach_run run task 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && grep -q '^kill-session$' "$OSRC_TMUX_LOG" && ! printf '%s' "$out" | grep -q 'session :'
) && ok "auto-detach rejects send-keys failure and kills the new tmux session" \
  || bad "auto-detach reported success or failed to clean up after send-keys"

# Normal interactive session start must apply the same send-keys failure contract.
(
  set --
  export OSRC_HOME="$TMP/session-start-home" OSRC_CLOUD_ACK=1 OSRC_CLOUD_ACKED=1 OSRC_HEARTBEAT_DISABLED=1 OSRC_SOURCED=1
  mkdir -p "$OSRC_HOME"
  mkdir -p "$TMP/bin-session"
  cat > "$TMP/bin-session/devin" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then printf 'Logged in\n'; exit 0; fi
if [ "${1:-}" = --help ]; then printf '%s\n' '--model <MODEL>'; exit 0; fi
exit 0
SH
  cat > "$TMP/bin-session/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  has-session) exit 1 ;;
  new-session) exit 0 ;;
  send-keys) printf 'send-keys\n' >> "$OSRC_TMUX_LOG"; exit 1 ;;
  kill-session) printf 'kill-session\n' >> "$OSRC_TMUX_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$TMP/bin-session/devin" "$TMP/bin-session/tmux"
  export PATH="$TMP/bin-session:$PATH" OSRC_TMUX_LOG="$TMP/session-start-tmux.log"
  . "$SRC" >/dev/null 2>&1
  _devin_guard_before_delegation() { return 0; }
  _session_assert_model_pinnable() { return 0; }
  set +e
  out="$(session start -m glm 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && grep -q '^kill-session$' "$OSRC_TMUX_LOG" && ! printf '%s' "$out" | grep -q "Started tmux session"
) && ok "session start rejects send-keys failure and cleans up the new tmux session" \
  || bad "session start reported success or failed to clean up after send-keys"

# Relaunch must run the same bounded liveness proof and must not claim success after registry failure.
(
  set --
  export OSRC_HOME="$TMP/relaunch-home" OSRC_HEARTBEAT_DISABLED=1 OSRC_SESSION_LIVENESS_SECS=1 OSRC_SOURCED=1
  mkdir -p "$OSRC_HOME/sessions"
  . "$SRC" >/dev/null 2>&1
  PANE=relaunch-live; PID_NOW=111; PANE_COMMAND=devin
  _pid_start_identity() { printf 'Mon Jan 1 00:00:00 2024\n'; }
  tmux() {
    case "${1:-}" in
      has-session) return 0 ;;
      display-message)
        case "${5:-}" in
          '#{pane_pid}') printf '%s\n' "$PID_NOW" ;;
          '#{pane_current_command}') printf '%s\n' "$PANE_COMMAND" ;;
          *) return 1 ;;
        esac ;;
      respawn-pane) PID_NOW=222; return 0 ;;
      kill-session) printf 'killed\n' >> "$TMP/relaunch-killed"; return 0 ;;
      *) return 0 ;;
    esac
  }
  SESSION_NAME="$PANE" _session_registry_append start devin glm high running receipt glm 1 >/dev/null
  _session_control_relaunch "$PANE" devin glm high >/dev/null 2>&1
  latest="$(jq -rs --arg id "$PANE" '[.[] | select(.session_id==$id)] | sort_by(.ts) | last' "$OSRC_SESSION_REGISTRY")"
  [ "$(printf '%s' "$latest" | jq -r '.event')" = start ] \
    && [ "$(printf '%s' "$latest" | jq -r '.model_generation')" = 2 ] \
    && [ "$(printf '%s' "$latest" | jq -r '.harness_pid')" = 222 ]
) && ok "relaunch records the new generation only after liveness succeeds" \
  || bad "relaunch did not finalize a live new generation"

(
  set --
  export OSRC_HOME="$TMP/relaunch-dead-home" OSRC_HEARTBEAT_DISABLED=1 OSRC_SESSION_LIVENESS_SECS=1 OSRC_SOURCED=1
  mkdir -p "$OSRC_HOME/sessions"
  . "$SRC" >/dev/null 2>&1
  PANE=relaunch-dead; PID_NOW=111; PANE_COMMAND=bash
  _pid_start_identity() { printf 'Mon Jan 1 00:00:00 2024\n'; }
  tmux() {
    case "${1:-}" in
      has-session) return 0 ;;
      display-message)
        case "${5:-}" in
          '#{pane_pid}') printf '%s\n' "$PID_NOW" ;;
          '#{pane_current_command}') printf '%s\n' "$PANE_COMMAND" ;;
          *) return 1 ;;
        esac ;;
      respawn-pane) PID_NOW=222; return 0 ;;
      kill-session) printf 'killed\n' >> "$TMP/relaunch-dead-killed"; return 0 ;;
      *) return 0 ;;
    esac
  }
  SESSION_NAME="$PANE" _session_registry_append start devin glm high running receipt glm 1 >/dev/null
  set +e
  _session_control_relaunch "$PANE" devin glm high >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && [ -s "$TMP/relaunch-dead-killed" ]
) && ok "relaunch rejects an immediate provider exit after the pane PID changes" \
  || bad "relaunch treated a bare shell as a healthy provider"

(
  set --
  export OSRC_HOME="$TMP/relaunch-persist-home" OSRC_HEARTBEAT_DISABLED=1 OSRC_SESSION_LIVENESS_SECS=1 OSRC_SOURCED=1
  mkdir -p "$OSRC_HOME/sessions"
  . "$SRC" >/dev/null 2>&1
  PANE=relaunch-persist; PID_NOW=111; PANE_COMMAND=devin
  _pid_start_identity() { printf 'Mon Jan 1 00:00:00 2024\n'; }
  tmux() {
    case "${1:-}" in
      has-session) return 0 ;;
      display-message)
        case "${5:-}" in
          '#{pane_pid}') printf '%s\n' "$PID_NOW" ;;
          '#{pane_current_command}') printf '%s\n' "$PANE_COMMAND" ;;
          *) return 1 ;;
        esac ;;
      respawn-pane) PID_NOW=222; return 0 ;;
      kill-session) printf 'killed\n' >> "$TMP/relaunch-persist-killed"; return 0 ;;
      *) return 0 ;;
    esac
  }
  jq -cn '{schema_version:"1",event:"start",session_id:"relaunch-persist",provider:"devin",model:"glm",requested_model:"glm",resolved_model:"glm",model_generation:1,effort:"high",state:"running",receipt:"receipt",endpoint:"tmux:relaunch-persist",harness_pid:"111",pid_start:"Mon Jan 1 00:00:00 2024",owner:"managed",ts:"2026-01-01T00:00:00Z"}' > "$OSRC_SESSION_REGISTRY"
  _session_registry_append() { return 1; }
  set +e
  _session_control_relaunch "$PANE" devin glm high >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && [ -s "$TMP/relaunch-persist-killed" ]
) && ok "relaunch fails loudly and cleans up when registry persistence fails" \
  || bad "relaunch claimed success after registry persistence failure"

# F6: effort relaunch must use the same finalizer as control relaunch. Otherwise respawn-pane -k
# kills the old pane shell, leaves the old dead identity as the newest registry record, and the next
# reap writes crash-reap over the live new engine.
(
  set --
  export OSRC_HOME="$TMP/effort-relaunch-home" OSRC_HEARTBEAT_DISABLED=1 OSRC_SOURCED=1
  mkdir -p "$OSRC_HOME/sessions"
  . "$SRC" >/dev/null 2>&1
  SESSION_NAME=effort-relaunch
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid - 1)); done
  jq -cn --argjson pid "$dead_pid" '{schema_version:"1",event:"start",session_id:"effort-relaunch",provider:"codex",model:"sol",requested_model:"sol",resolved_model:"sol",model_generation:1,effort:"medium",state:"running",receipt:"receipt",endpoint:"tmux:effort-relaunch",harness_pid:($pid|tostring),pid_start:"Mon Jan 1 00:00:00 2024",owner:"managed",ts:"2026-01-01T00:00:00Z"}' > "$OSRC_SESSION_REGISTRY"
  PANE_PID="${BASHPID:-$$}"
  sleep 30 & NEW_PANE_PID=$!
  trap 'kill "$NEW_PANE_PID" 2>/dev/null || true; wait "$NEW_PANE_PID" 2>/dev/null || true' EXIT
  PID_NOW="$PANE_PID"
  tmux() {
    case "${1:-}" in
      has-session) return 0 ;;
      respawn-pane) PID_NOW="$NEW_PANE_PID"; return 0 ;;
      display-message)
        case " $* " in
          *" #{pane_pid} "*) printf '%s\n' "$PID_NOW" ;;
          *" #{pane_current_command} "*) printf 'codex\n' ;;
          *) return 1 ;;
        esac ;;
      *) return 0 ;;
    esac
  }
  _session_relaunch_command() { printf 'codex\n'; }
  _session_launch_liveness_check() { return 0; }
  _heartbeat_start() { return 0; }
  _managed_endpoint_live() { return 0; }
  _session_relaunch_effort codex sol high >/dev/null 2>&1 || exit 1
  latest="$(jq -rs --arg id "$SESSION_NAME" '[.[] | select(.session_id==$id)] | sort_by(.ts) | last' "$OSRC_SESSION_REGISTRY")"
  [ "$(printf '%s' "$latest" | jq -r '.event')" = start ] || exit 1
  [ "$(printf '%s' "$latest" | jq -r '.model_generation')" = 2 ] || exit 1
  _session_registry_reap_dead >/dev/null 2>&1
  [ "$(jq -rs --arg id "$SESSION_NAME" '[.[] | select(.session_id==$id)] | sort_by(.ts) | last | .event' "$OSRC_SESSION_REGISTRY")" = start ] || exit 1
  ! grep -q '"receipt":"crash-reap"' "$OSRC_SESSION_REGISTRY"
) && ok "effort relaunch records a live generation before reap and remains steerable" \
  || bad "effort relaunch left the old dead generation for the reaper"

# Every non-start registry event must preserve the last known process identity.
(
  set --
  export OSRC_HOME="$TMP/identity-home" OSRC_SOURCED=1
  mkdir -p "$OSRC_HOME/sessions"
  . "$SRC" >/dev/null 2>&1
  SESSION_NAME=identity-session
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid - 1)); done
  jq -cn --argjson pid "$dead_pid" '{schema_version:"1",event:"start",session_id:"identity-session",provider:"devin",model:"glm",requested_model:"glm",resolved_model:"glm",model_generation:1,effort:"high",state:"running",receipt:"receipt",endpoint:"tmux:identity-session",harness_pid:($pid|tostring),pid_start:"Mon Jan 1 00:00:00 2024",owner:"managed",ts:"2026-01-01T00:00:00Z"}' > "$OSRC_SESSION_REGISTRY"
  tmux() { return 1; }
  _session_registry_append effort devin glm high advisory advisory >/dev/null
  latest="$(jq -rs 'sort_by(.ts) | last' "$OSRC_SESSION_REGISTRY")"
  [ "$(printf '%s' "$latest" | jq -r '.harness_pid')" = "$dead_pid" ] \
    && [ "$(printf '%s' "$latest" | jq -r '.pid_start')" = 'Mon Jan 1 00:00:00 2024' ]
  _session_registry_reap_dead >/dev/null 2>&1
  [ "$(jq -rs 'sort_by(.ts) | last | .event' "$OSRC_SESSION_REGISTRY")" = end ]
) && ok "non-start registry events preserve identity so dead sessions are reaped" \
  || bad "non-start registry events erased the process identity"

# A relaunch that wins after the reaper snapshot must not be followed by a stale crash-reap end.
(
  set --
  export OSRC_HOME="$TMP/reap-race-home" OSRC_SOURCED=1
  mkdir -p "$OSRC_HOME/sessions"
  . "$SRC" >/dev/null 2>&1
  SESSION_NAME=reap-race
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid - 1)); done
  jq -cn --argjson pid "$dead_pid" '{schema_version:"1",event:"start",session_id:"reap-race",provider:"devin",model:"glm",requested_model:"glm",resolved_model:"glm",model_generation:1,effort:"high",state:"running",receipt:"receipt",endpoint:"tmux:reap-race",harness_pid:($pid|tostring),pid_start:"Mon Jan 1 00:00:00 2024",owner:"managed",ts:"2026-01-01T00:00:00Z"}' > "$OSRC_SESSION_REGISTRY"
  hook="$TMP/reap-race-hook"
  _session_harness_alive() {
    if [ "$1" = "$dead_pid" ] && [ ! -e "$hook" ]; then
      : > "$hook"
      jq -cn '{schema_version:"1",event:"start",session_id:"reap-race",provider:"devin",model:"glm",requested_model:"glm",resolved_model:"glm",model_generation:2,effort:"high",state:"running",receipt:"relaunch",endpoint:"tmux:reap-race",harness_pid:"222",pid_start:"Mon Jan 1 00:00:00 2024",owner:"managed",ts:"2099-01-01T00:00:00Z"}' >> "$OSRC_SESSION_REGISTRY"
    fi
    return 1
  }
  _session_registry_reap_dead >/dev/null 2>&1
  ! grep -q '"receipt":"crash-reap"' "$OSRC_SESSION_REGISTRY" \
    && [ "$(jq -rs '[.[] | select(.model_generation==2)] | length' "$OSRC_SESSION_REGISTRY")" = 1 ]
) && ok "dead-session reap skips a newer relaunch generation" \
  || bad "dead-session reap appended an end over a newer relaunch"

# State rewrites must retain a stable lock inode when flock is available.
(
  set --
  export OSRC_HOME="$TMP/lock-home" OSRC_SOURCED=1
  mkdir -p "$TMP/bin-flock"
  cat > "$TMP/bin-flock/flock" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$TMP/bin-flock/flock"
  export PATH="$TMP/bin-flock:$PATH"
  . "$SRC" >/dev/null 2>&1
  file="$OSRC_HOME/state.jsonl"
  mkdir -p "$OSRC_HOME"; printf '%s\n' '{"x":1}' > "$file"
  _state_lock_acquire "$file"
  [ -f "$file.lock" ] || exit 1
  old_inode="$(stat -f '%i' "$file" 2>/dev/null || stat -c '%i' "$file")"
  _state_file_rewrite_locked "$file" '{"x":2}'
  new_inode="$(stat -f '%i' "$file" 2>/dev/null || stat -c '%i' "$file")"
  [ "$old_inode" != "$new_inode" ] && [ -f "$file.lock" ] || exit 1
  _state_lock_release "$file"
  _state_append "$file" '{"x":3}'
  [ "$(jq -rs 'map(.x) | join(",")' "$file")" = '2,3' ]
) && ok "flock protects a stable sibling across state-file replacement" \
  || bad "state-file replacement invalidated the flock lock"

# A malformed live owner must not make heartbeat arming report success.
(
  set --
  export OSRC_HOME="$TMP/malformed-owner-home" OSRC_HEARTBEAT="$TMP/malformed-owner-home/heartbeat" OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  mkdir -p "$OSRC_HEARTBEAT/leader"
  jq -cn --argjson pid "$$" '{schema_version:"1",pid:$pid,pid_start:"not-a-process-start-marker",token:"old",sink:null}' > "$OSRC_HEARTBEAT/leader/owner.json"
  fake="$TMP/malformed-beacon"; printf '#!/usr/bin/env bash\n: > "$TMP/malformed-spawned"\n' > "$fake"; chmod +x "$fake"
  export OSRC_HEARTBEAT_EXECUTABLE="$fake"
  set +e
  _heartbeat_start >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && [ ! -e "$TMP/malformed-spawned" ] && grep -q 'not-a-process-start-marker' "$OSRC_HEARTBEAT/leader/owner.json"
) && ok "heartbeat refuses to arm against a malformed live owner" \
  || bad "heartbeat reported arm success for a malformed owner"

# Stale eviction is serialized with the spawn decision under the election lock.
(
  set --
  export OSRC_HOME="$TMP/election-home" OSRC_HEARTBEAT="$TMP/election-home/heartbeat" OSRC_HEARTBEAT_DISABLED=0 OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  mkdir -p "$OSRC_HEARTBEAT"
  marker="$TMP/election-lock-marker"
  _heartbeat_election_acquire() { _HEARTBEAT_ELECTION_KIND=flock; return 0; }
  _heartbeat_election_release() { _HEARTBEAT_ELECTION_KIND=""; return 0; }
  _heartbeat_leader_evict_stale() {
    if [ -n "${_HEARTBEAT_ELECTION_KIND:-}" ]; then printf locked > "$marker"; else printf unlocked > "$marker"; fi
    return 0
  }
  fake="$TMP/election-beacon"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
mkdir -p "$OSRC_HEARTBEAT/leader"
start="$(LC_ALL=C ps -o lstart= -p "$$" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g')"
jq -cn --argjson pid "$$" --arg start "$start" --arg token "${1:-}" '{schema_version:"1",pid:$pid,pid_start:$start,token:$token,sink:null}' > "$OSRC_HEARTBEAT/leader/owner.json"
sleep 1
SH
  chmod +x "$fake"
  export OSRC_HEARTBEAT_EXECUTABLE="$fake" OSRC_HEARTBEAT_START_TIMEOUT=1
  _heartbeat_start >/dev/null 2>&1 || true
  [ "$(cat "$marker" 2>/dev/null)" = locked ]
  rm -rf "$OSRC_HEARTBEAT/leader" "$OSRC_HEARTBEAT/.election"
) && ok "heartbeat stale eviction runs under the election lock" \
  || bad "heartbeat stale eviction ran outside the election lock"

# Housekeeping failures must be visible and make the tick unknown.
(
  set --
  export OSRC_HOME="$TMP/housekeeping-home" OSRC_HEARTBEAT="$TMP/housekeeping-home/heartbeat" OSRC_SOURCED=1
  export OSRC_HEARTBEAT_WAKE="" OSRC_HEARTBEAT_SINK="" OSRC_HEARTBEAT_WAKE_DIGEST=0
  . "$SRC" >/dev/null 2>&1
  _session_registry_reap_dead() { return 1; }
  _session_registry_compact() { return 1; }
  _wake_queue_compact() { return 1; }
  _heartbeat_log_rotate() { return 1; }
  _fleet_snapshot_collect() { jq -cn '{schema_version:"1",generation:"g",captured_at:"2026-08-30T00:00:00Z",items:[]}'; }
  _fleet_snapshot_write() { return 0; }
  _heartbeat_log_append() { printf '%s\n' "$1" >> "$TMP/housekeeping-log"; return 0; }
  _heartbeat_emit_attached() { return 0; }
  _wake_consume() { return 0; }
  set +e
  out="$(_heartbeat_tick 2>&1)"
  rc=$?
  set -e
  report="$out$(cat "$TMP/housekeeping-log" 2>/dev/null)"
  [ "$rc" -ne 0 ] && case "$report" in
    *registry-reap*registry-compact*state=unknown*) : ;;
    *) false ;;
  esac
) && ok "heartbeat housekeeping failures are reported and downgrade supervision to unknown" \
  || bad "heartbeat housekeeping failures were silently discarded"

# A stale fleet snapshot must not be treated as a current blocked delegate.
(
  set --
  export OSRC_HOME="$TMP/stale-guard-home" OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  mkdir -p "$OSRC_HOME"
  jq -cn '{schema_version:"1",generation:"old",captured_at:"2020-01-01T00:00:00Z",items:[{owner:"managed",job_id:"old-job",state:"blocked",display_name:"old",waiting_for:"old",cwd:"/old"}]}' > "$OSRC_FLEET_SNAPSHOT"
  set +e
  out="$(_blind_turn_guard 2>&1)"
  rc=$?
  set -e
  [ "$rc" -ne 7 ] && printf '%s' "$out" | grep -qi 'unknown'
) && ok "blind-turn guard refuses to block on an arbitrarily stale snapshot" \
  || bad "blind-turn guard treated stale blocked state as current"

# Codex relaunch and effort commands must carry the same explicit code-mode-host override.
(
  set --
  export OSRC_HOME="$TMP/codex-relaunch-home" OSRC_SOURCED=1
  . "$SRC" >/dev/null 2>&1
  resolve_model_row() { printf '%s\n' "$1"; }
  _codex_code_mode_host_flag() { printf 'true\n'; }
  cmd="$(_session_relaunch_command codex sol high)"
  printf '%s' "$cmd" | grep -q 'features.code_mode_host=true'
) && ok "Codex relaunch command preserves the explicit code-mode-host override" \
  || bad "Codex relaunch command dropped code-mode-host"

# Ended registry records must not become managed unknown observations or wakes.
(
  set --
  export OSRC_HOME="$TMP/ended-observation-home" HOME="$TMP/ended-observation-home-home" OSRC_SOURCED=1
  mkdir -p "$OSRC_HOME/sessions" "$HOME"
  . "$SRC" >/dev/null 2>&1
  _pid_start_identity() { printf 'Mon Jan 1 00:00:00 2024\n'; }
  tmux() { return 1; }
  jq -cn --argjson pid "$$" '{schema_version:"1",event:"start",session_id:"ended-observation",provider:"devin",model:"glm",requested_model:"glm",resolved_model:"glm",model_generation:1,effort:"high",state:"running",receipt:"receipt",endpoint:"tmux:ended-observation",harness_pid:($pid|tostring),pid_start:"Mon Jan 1 00:00:00 2024",owner:"managed",ts:"2026-01-01T00:00:00Z"}' > "$OSRC_SESSION_REGISTRY"
  jq -cn --argjson pid "$$" '{schema_version:"1",event:"end",session_id:"ended-observation",provider:"devin",model:"glm",requested_model:"glm",resolved_model:"glm",model_generation:1,effort:"high",state:"ended",receipt:"stop",endpoint:"tmux:ended-observation",harness_pid:($pid|tostring),pid_start:"Mon Jan 1 00:00:00 2024",owner:"managed",ts:"2099-01-01T00:00:00Z"}' >> "$OSRC_SESSION_REGISTRY"
  items="$(_external_session_observations '[]' 2>/dev/null)"
  [ "$(printf '%s' "$items" | jq -r '[.[] | select(.session_id=="ended-observation")] | length')" = 0 ]
) && ok "ended registry sessions do not emit managed unknown observations" \
  || bad "ended registry sessions still emitted an unknown observation"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
