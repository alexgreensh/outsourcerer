#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib_race_barrier.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/osrc-atomic-claim.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/home" HOME="$TMP/home" OSRC_HEARTBEAT_DISABLED=1
mkdir -p "$HOME"
set --
. "$DIR/../outsourcerer.sh" >/dev/null 2>&1
trap 'rm -rf "$TMP"' EXIT

# Mimic an external mkdir that reports success to every caller on an existing
# directory. The control proves the stub creates the double-winner condition.
mkdir() { command mkdir -p "$@"; }
mkdir "$TMP/control" && mkdir "$TMP/control" || { echo 'FAIL: lying mkdir control'; exit 1; }
echo 'PASS: lying mkdir reports success twice'

for mode in native perl shell; do
  if [ "$mode" = perl ] && ! command -v perl >/dev/null 2>&1; then
    echo 'SKIP: Perl is unavailable'; continue
  fi
  gate="$TMP/gate-$mode"; claim="$TMP/claim-$mode"
  command mkdir "$gate"
  pids=()
  for i in 1 2 3 4 5 6 7 8 9 10; do
    (
      osrc_race_ready "$gate" "$i" || exit 125
      if [ "$mode" != native ]; then
        command() {
          case "${1:-}:${2:-}" in
            -v:python3) return 1 ;;
            -v:perl) [ "$mode" != shell ] || return 1 ;;
          esac
          builtin command "$@"
        }
      fi
      _mkdir_claim "$claim"; printf '%s\n' "$?" > "$gate/result.$i"
    ) & pids[$i]=$!
  done
  osrc_race_release "$gate" 10 || exit 1
  for i in 1 2 3 4 5 6 7 8 9 10; do wait "${pids[$i]}" || exit 1; done
  wins=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    read -r rc < "$gate/result.$i"
    [ "$rc" != 0 ] || wins=$((wins + 1))
  done
  [ "$wins" = 1 ] || { echo "FAIL: $mode helper allowed $wins winners"; exit 1; }
  echo "PASS: $mode helper elects exactly one owner despite lying mkdir"
done
