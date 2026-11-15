#!/usr/bin/env bash
# Guard: a test must never pick a "dead" pid by scanning for one `kill -0` rejects.
# kill -0 also rejects a pid whose process is still being created (macOS) and a free pid just ahead
# of the allocator, so the chosen pid can turn live mid-test. That made test_devin_free_guard flake
# on macOS CI ("got ''", run 43751567057). Use osrc_test_dead_pid from lib_scratch.sh instead:
# a child the test forked and reaped is provably dead until the pid counter wraps.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-$HERE}"
pass=0; fail=0
# A `while kill -0 <var>` loop whose body steps the same variable down or up by one.
pat='while[[:space:]]+kill[[:space:]]+-0[[:space:]]+"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?.*do[[:space:]]+\1=\$\(\([[:space:]]*\1[[:space:]]*[-+][[:space:]]*1[[:space:]]*\)\)'
hits="$(grep -rnE "$pat" "$ROOT" --include='*.sh' 2>/dev/null | grep -v '/test_no_dead_pid_scan.sh:' || true)"
if [ -z "$hits" ]; then
  echo "PASS: no test scans for a dead pid with kill -0"; pass=$((pass+1))
else
  echo "FAIL: dead-pid scan found (use osrc_test_dead_pid from lib_scratch.sh):"; printf '%s\n' "$hits" | sed 's/^/    /'; fail=$((fail+1))
fi
# Self-check: the pattern must catch both shapes this repo used, so a regex typo cannot pass silently.
T="$(mktemp -d)" || exit 1; trap 'rm -rf "$T"' EXIT
printf '%s\n' 'd=999999; while kill -0 "$d" 2>/dev/null; do d=$((d - 1)); done' > "$T/a.sh"
printf '%s\n' 'dead=99991; while kill -0 "$dead" 2>/dev/null || ps -p "$dead" >/dev/null 2>&1; do dead=$((dead-1)); done' > "$T/b.sh"
printf '%s\n' 'dead="$(osrc_test_dead_pid)"' > "$T/ok.sh"
n="$(grep -rlE "$pat" "$T" --include='*.sh' | wc -l | tr -d ' ')"
if [ "$n" = 2 ] && ! grep -qE "$pat" "$T/ok.sh"; then
  echo "PASS: guard pattern catches both scan shapes and allows the helper"; pass=$((pass+1))
else
  echo "FAIL: guard pattern self-check matched $n of 2 bad files"; fail=$((fail+1))
fi
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
