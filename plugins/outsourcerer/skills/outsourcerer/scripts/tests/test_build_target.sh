#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }

pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

assert_target() {
  [ "$#" -eq 4 ] || { echo "ERROR: expected root, branch, version, and commit" >&2; return 1; }
  local expected_root="$1" expected_branch="$2" expected_version="$3" expected_head="$4"
  local root branch head
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: repository root unavailable" >&2; return 1; }
  root="$(cd "$root" && pwd -P)" || return 1
  expected_root="$(cd "$expected_root" 2>/dev/null && pwd -P)" || { echo "ERROR: expected repository root unavailable" >&2; return 1; }
  branch="$(git branch --show-current 2>/dev/null)"
  head="$(git rev-parse HEAD 2>/dev/null)"
  [ "$root" = "$expected_root" ] || { echo "ERROR: repository root mismatch" >&2; return 1; }
  [ "$branch" = "$expected_branch" ] || { echo "ERROR: branch mismatch" >&2; return 1; }
  [ "$OSRC_VERSION" = "$expected_version" ] || { echo "ERROR: version mismatch" >&2; return 1; }
  [ "$head" = "$expected_head" ] || { echo "ERROR: commit mismatch" >&2; return 1; }
}

set --
. "$SRC" >/dev/null 2>&1
root="$(git rev-parse --show-toplevel)"
branch="$(git branch --show-current)"
head="$(git rev-parse HEAD)"

if assert_target "$root" "$branch" "$OSRC_VERSION" "$head"; then
  ok "current checkout matches its declared identity"
else
  bad "current checkout was rejected"
fi

for kind in root branch version commit; do
  case "$kind" in
    root) out="$(assert_target "$(dirname "$root")" "$branch" "$OSRC_VERSION" "$head" 2>&1)"; rc=$? ;;
    branch) out="$(assert_target "$root" "$branch-x" "$OSRC_VERSION" "$head" 2>&1)"; rc=$? ;;
    version) out="$(assert_target "$root" "$branch" "$OSRC_VERSION-x" "$head" 2>&1)"; rc=$? ;;
    commit) out="$(assert_target "$root" "$branch" "$OSRC_VERSION" "${head%?}x" 2>&1)"; rc=$? ;;
  esac
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "$kind mismatch"; then
    ok "$kind mismatch is rejected"
  else
    bad "$kind mismatch was not identified ($out)"
  fi
done

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
