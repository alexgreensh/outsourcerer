#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib_race_barrier.sh"
TMP="$(mktemp -d "${TMPDIR%/}/osrc-lock-paths.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state" HOME="$TMP/home" OSRC_HEARTBEAT_DISABLED=1 OSRC_FORCE_MKDIR_ELECTION=1 OSRC_PLAN_LOCK_TRIES=2
mkdir -p "$HOME" "$OSRC_HOME"
set --
. "$DIR/../outsourcerer.sh" >/dev/null 2>&1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OSRC_HOME/done" "$OSRC_HEARTBEAT" "$(_plan_dir race)"

# Every mkdir invocation lies about an existing directory, just like the
# observed uutils race. Keep the first successful owner alive until all finish.
mkdir() { command mkdir -p "$@"; }
sleep() { command sleep 0.002; }
failed=0
for kind in mutex heartbeat factory plan_create remote done heavy; do
  gate="$TMP/$kind-gate"; command mkdir "$gate"; pids=()
  for i in 1 2; do
    (
      osrc_race_ready "$gate" "$i" || exit 125
      rc=0
      case "$kind" in
        mutex) _osrc_guarded_mutex_acquire "$TMP/mutex" || rc=$? ;;
        heartbeat) pid="${BASHPID:-$$}"; start="$(_pid_start_identity "$pid")"
          _heartbeat_election_acquire "$OSRC_HEARTBEAT/election" "$pid" "$start" || rc=$? ;;
        factory) _plan_lock race >/dev/null 2>&1 || rc=$? ;;
        plan_create) ( _plan_cli_new race-new --no-repo --no-use ) >/dev/null 2>&1 || rc=$? ;;
        remote) _osrc_lock "$TMP/remote-lock" || rc=$? ;;
        done) _osrc_done_check_lock race || rc=$? ;;
        heavy) _osrc_heavy_lock 0 || rc=$? ;;
      esac
      printf '%s\n' "$rc" > "$gate/result.$i"
      if [ "$rc" = 0 ]; then
        deadline=$((SECONDS + 20))
        while [ ! -e "$gate/finish" ]; do [ "$SECONDS" -lt "$deadline" ] || exit 125; sleep 0.01; done
        case "$kind" in
          mutex) _osrc_guarded_mutex_release "$TMP/mutex" ;;
          heartbeat) _heartbeat_election_release "$OSRC_HEARTBEAT/election" ;;
          factory) _plan_unlock race ;;
          remote) _osrc_unlock "$TMP/remote-lock" ;;
          heavy) _osrc_heavy_unlock ;;
        esac
      fi
    ) > "$gate/out.$i" 2>&1 & pids[$i]=$!
  done
  osrc_race_release "$gate" 2 || exit 1
  deadline=$((SECONDS + 20))
  while [ ! -f "$gate/result.1" ] || [ ! -f "$gate/result.2" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "FAIL: $kind timed out"; : > "$gate/finish"; exit 1; }
    sleep 0.01
  done
  wins=0
  for i in 1 2; do read -r rc < "$gate/result.$i"; [ "$rc" != 0 ] || wins=$((wins + 1)); done
  : > "$gate/finish"
  for i in 1 2; do wait "${pids[$i]}" || failed=1; done
  if [ "$wins" = 1 ]; then echo "PASS: $kind elects one owner with lying mkdir"
  else echo "FAIL: $kind elected $wins owners"; cat "$gate"/out.*; failed=1; fi
done

# A cache becoming fresh at the wait deadline does not give this process
# ownership of the other fetcher's still-held lock.
mkdir() { command mkdir "$@"; }
command mkdir "$TMP/catalog.json.lock.d"
_catalog_path() { printf '%s\n' "$TMP/catalog.json"; }
fresh_calls=0
_catalog_fresh() { fresh_calls=$((fresh_calls + 1)); [ "$fresh_calls" -ge 3 ]; }
OSRC_CATALOG_FETCH_TIMEOUT=0 _catalog_fetch race || failed=1
if [ -d "$TMP/catalog.json.lock.d" ]; then
  echo 'PASS: catalog waiter leaves the other fetcher lock intact'
else
  echo 'FAIL: catalog waiter removed another fetcher lock'; failed=1
fi
exit "$failed"
