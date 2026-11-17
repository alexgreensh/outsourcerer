#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib_scratch.sh" || exit 1
# test_preflight_map.sh — scripts/preflight.sh picks suites a file reaches only through the engine
# (explicit map), and a suite that failed under load but passed alone becomes a recorded task
# (load-sensitive: <suite> + out/LOAD-SENSITIVE.md), never a silent warn. Sources the script's
# functions only (PREFLIGHT_SOURCE_ONLY=1): no suite runs, no git worktree is made.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; TOP="$(git -C "$HERE" rev-parse --show-toplevel)"
TMP="$(mktemp -d "${TMPDIR%/}/.test-preflight-map.XXXXXX")" || { echo "FAIL: cannot create scratch directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" OSRC_HOME="$TMP/osrc"; mkdir -p "$HOME" "$OSRC_HOME"
pass=0; fail=0
ok(){ echo "PASS: $1"; pass=$((pass+1)); }
no(){ echo "FAIL: $1"; fail=$((fail+1)); }
has() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }
cd "$TOP" || exit 1
out="$(PREFLIGHT_SOURCE_ONLY=1; . scripts/preflight.sh; echo sourced)"
[ "$out" = sourced ] && ok "PREFLIGHT_SOURCE_ONLY=1 defines the functions and runs no stage" || no "sourcing ran stages: $out"
PREFLIGHT_SOURCE_ONLY=1; . scripts/preflight.sh; unset PREFLIGHT_SOURCE_ONLY
T=plugins/outsourcerer/skills/outsourcerer/scripts/tests
L=plugins/outsourcerer/skills/outsourcerer/scripts/lib
for f in supervise_watch.sh remote.sh done.sh; do
  got="$(_suites_for "$L/$f")"
  has "$got" test_supervise && ok "lib/$f -> test_supervise (explicit map)" || no "lib/$f missed test_supervise: [$got]"
done
got="$(_suites_for "$L/guards.sh")"; has "$got" test_guards && ok "basename grep still maps lib/guards.sh -> test_guards" || no "guards: [$got]"
got="$(_suites_for "$T/test_guards.sh")"; [ "$got" = " test_guards" ] && ok "a changed suite runs itself" || no "suite: [$got]"
got="$(_suites_for "$(printf '%s\n%s\n' "$L/remote.sh" "$L/done.sh")")"
[ "$(printf '%s\n' $got | grep -c '^test_supervise$')" = 1 ] && ok "a suite reached twice is listed once" || no "dup: [$got]"
got="$(_suites_for "plugins/outsourcerer/skills/outsourcerer/scripts/outsourcerer.sh")"; [ -z "$got" ] && ok "the engine itself maps to nothing here (CI runs all)" || no "engine: [$got]"

export PREFLIGHT_OUT="$TMP/out"
o1="$(_record_load_sensitive test_x "$(printf 'FAIL: a timed out\nFAIL: b')")"
o2="$(_record_load_sensitive test_y "FAIL: c")"
f="$TMP/out/LOAD-SENSITIVE.md"
grep -qx 'load-sensitive: test_x' <<<"$o1" && ok "prints 'load-sensitive: <suite>'" || no "print: [$o1]"
grep -q 'FAIL: a timed out' "$f" && grep -q 'FAIL: b' "$f" && grep -q '^## .* test_x$' "$f" && ok "LOAD-SENSITIVE.md holds the suite and its failing lines" || no "file: $(cat "$f" 2>/dev/null)"
grep -q '^## .* test_y$' "$f" && [ "$(grep -c '^# Load-sensitive' "$f")" = 1 ] && ok "appends: second entry added, header written once" || no "append: $(cat "$f")"
grep -q 'never add sleeps or retries' "$f" && ok "the entry is a task (fix or delete), not a pass" || no "task text"
grep -q 'passed alone (load-sensitive)' scripts/preflight.sh && no "the old warn line is still there" || ok "the old 'passed alone -> warn' line is gone"
git check-ignore -q out/LOAD-SENSITIVE.md && ok "<repo>/out/ is git-ignored, so the task file never enters a lane diff" || no "out/ not ignored"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
