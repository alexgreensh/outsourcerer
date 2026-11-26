#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_rv_watch.sh -- 0.18.0 release-review findings on status, the remote watcher, supervise and
# Mission Control (lane osrc-fx-rv-watch). Each block names the finding it pins.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
LIB="$HERE/../lib"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR%/}/.rvwatch-test.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }
KILL=""
cleanup_all() { local p; for p in $KILL; do kill -9 "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup_all EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
export OUTSOURCERER_DEPTH=0 OSRC_CATALOG_VALIDATE=0
mkdir -p "$HOME" "$XDG_CONFIG_HOME"; : > "$GIT_CONFIG_GLOBAL"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
osrc() {   # osrc <home> <code>: run code with the engine sourced
  OSRC_HOME="$1" OSRC_SOURCED=1 bash -c '. "$0" >/dev/null 2>&1; eval "$1"' "$SRC" "$2" 2>&1
}
home() { mkdir -p "$TMP/$1/jobs" "$TMP/$1/lanes"; printf '%s' "$TMP/$1"; }
lstart() { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g'; }

echo "=== F4: status keeps the progress text of a running job that is not disk-paused ==="
H="$(home f4)"; J=20261126-000000-bbbbbbbbbbbb; jd="$H/jobs/$J"; mkdir -p "$jd"
sleep 300 </dev/null >/dev/null 2>&1 & P=$!; KILL="$KILL $P"
echo running > "$jd/status"; echo "$P" > "$jd/pid"; lstart "$P" > "$jd/pid_start"; date +%s > "$jd/started_at"
printf '{"provider":"devin","model":"example-model","verb":"run"}\n' > "$jd/meta.json"
printf 'reading the parser\n' > "$jd/progress"
o="$(osrc "$H" "_status_line $J")"
grep -q "^$J running .*reading the parser" <<<"$o" && ok "running job shows its progress" || bad "status: $o"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
