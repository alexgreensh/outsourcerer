#!/usr/bin/env bash
# test_gemini_effort_retry.sh — the keyless Gemini (agy) lane self-heals the effort/model mismatch.
#
# Root cause guarded: _agy_model_token can resolve a family alias to a concrete id (e.g.
# `gemini-3.5-flash`) that this build of agy treats as effort-less and hard-rejects when paired with
# `--effort` ("--effort is not supported for model ..."). The model is valid; only the flag is wrong.
# The old code lumped that error in with "invalid model selection", cleared the (healthy) catalog, and
# gave up — so the whole lane died on a default `run`. The fix retries ONCE with the flag dropped.
#
# This drives the real delegate through a STUB `agy`: it fails the first call (the one carrying
# --effort) exactly as the live CLI does, and succeeds on the retry that omits it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed for $SRC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "$PWD/.test-gmretry.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export OSRC_HOME="$TMP/state"; export HOME="$TMP/home"
mkdir -p "$OSRC_HOME" "$HOME" "$TMP/bin"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# Stub agy: serves a catalog for `agy models`, and for each real `-p` delegate call logs ONE line
# recording whether --effort was present, rejects the --effort pairing once, accepts the retry.
cat > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "models" ]; then
  printf 'gemini-3.8-flash\tGemini 3.8 Flash\n'
  exit 0
fi
if [ "$*" = "--version" ] || [ "${1:-}" = "--version" ]; then echo "agy 0.0-test"; exit 0; fi
case " $* " in
  *" --effort "*)
    echo "call effort=yes" >> "$AGY_CALLS"
    echo 'Error: --effort is not supported for model "gemini-3.5-flash"' >&2
    exit 1 ;;
  *)
    echo "call effort=no" >> "$AGY_CALLS"
    echo 'REVIEW_OK'
    exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/agy"
export AGY_CALLS="$TMP/agy_calls.txt"; : > "$AGY_CALLS"
export PATH="$TMP/bin:$PATH"
export OSRC_GEMINI_VEHICLE=agy

set --
OSRC_SOURCED=1 . "$SRC" >/dev/null 2>&1
type -t delegate_gmnative >/dev/null || { echo "FAIL: delegate_gmnative not loaded"; exit 1; }

# Drive the delegate the way the run path does: a resolved flash id, a default medium effort, read-only.
REST=(review the code)
RESOLVED_ID="gemini-flash"
EFFORT="medium"
TTIER=""
rc=0
out="$(delegate_gmnative auto 2>"$TMP/err.txt")" || rc=$?

calls="$(wc -l < "$AGY_CALLS" | tr -d ' ')"

# 1. It retried: the delegate ran agy twice (first with --effort, then without).
[ "$calls" = "2" ] && ok "agy delegate was retried exactly once (2 -p calls total)" || bad "expected 2 delegate calls, got $calls: $(tr '\n' '|' < "$AGY_CALLS")"

# 2. The first call carried --effort, the second dropped it.
[ "$(sed -n '1p' "$AGY_CALLS")" = "call effort=yes" ] && ok "first call carried --effort (reproduces the reject)" || bad "first call was: $(sed -n '1p' "$AGY_CALLS")"
if [ "$calls" = "2" ]; then
  [ "$(sed -n '2p' "$AGY_CALLS")" = "call effort=no" ] && ok "retry dropped --effort" || bad "retry line was: $(sed -n '2p' "$AGY_CALLS")"
fi

# 3. The lane ultimately succeeded and returned the model's output instead of dying.
[ "$rc" -eq 0 ] && ok "gemini lane exits 0 after the self-heal retry" || bad "gemini lane exited $rc despite a retry that should succeed"
printf '%s' "$out" | grep -q 'REVIEW_OK' && ok "delegate returned the retried run's output" || bad "delegate did not surface the successful retry output: $out"

# 4. It did NOT nuke the healthy catalog for what was only a flag error.
grep -qi 'refused model' "$TMP/err.txt" && bad "treated the effort error as an invalid-model error (would clear the catalog)" || ok "effort error is not misclassified as an invalid-model error"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
