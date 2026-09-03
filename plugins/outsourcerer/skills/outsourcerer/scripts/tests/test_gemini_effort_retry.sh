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

# 5. NEGATIVE (locks in a torture-room finding): a BARE "not supported for model" that does NOT name
#    --effort is a mid-run capability warning, not the pre-execution effort rejection. The match is
#    anchored to require --effort on the same line, so this must NOT trigger a retry — otherwise a
#    mutating task that already ran would be re-executed, doubling its file edits.
cat > "$TMP/bin/agy" <<'STUB2'
#!/usr/bin/env bash
if [ "${1:-}" = "models" ]; then printf 'gemini-3.8-flash\tGemini 3.8 Flash\n'; exit 0; fi
case " $* " in *" --effort "*) echo "call effort=yes" >> "$AGY_CALLS" ;; *) echo "call effort=no" >> "$AGY_CALLS" ;; esac
# A mid-run diagnostic mentioning a model capability, with NO --effort token, then an unrelated failure.
echo 'warning: streaming is not supported for model gemini-3.5-flash in headless mode' >&2
exit 1
STUB2
chmod +x "$TMP/bin/agy"
: > "$AGY_CALLS"
REST=(review the code); RESOLVED_ID="gemini-flash"; EFFORT="medium"; TTIER=""
rc2=0
delegate_gmnative auto >/dev/null 2>&1 || rc2=$?
calls2="$(wc -l < "$AGY_CALLS" | tr -d ' ')"
[ "$calls2" = "1" ] && ok "a bare 'not supported for model' (no --effort) does NOT trigger a retry" \
  || bad "bare capability warning wrongly triggered a retry ($calls2 calls) — would double-run a mutating task"

# 6. NEGATIVE (spec-conformance finding): a SUCCESSFUL run (exit 0) that merely emits a 'not supported
#    for model' capability warning must NOT be reclassified as a failure or wipe the cached catalog —
#    the catalog-clear branch is gated on a nonzero exit.
cat > "$TMP/bin/agy" <<'STUB3'
#!/usr/bin/env bash
if [ "${1:-}" = "models" ]; then printf 'gemini-3.8-flash\tGemini 3.8 Flash\n'; exit 0; fi
echo 'note: streaming is not supported for model gemini-3.5-flash in headless mode' >&2
echo 'REVIEW_OK'   # real deliverable on stdout
exit 0             # SUCCESS
STUB3
chmod +x "$TMP/bin/agy"
mkdir -p "$OSRC_HOME/catalog"; : > "$OSRC_HOME/catalog/gm.txt"   # a cached catalog that must survive
REST=(review the code); RESOLVED_ID="gemini-flash"; EFFORT="medium"; TTIER=""
rc3=0; out3="$(delegate_gmnative auto 2>"$TMP/err3.txt")" || rc3=$?
printf '%s' "$out3" | grep -q 'REVIEW_OK' && ok "a successful run with a capability warning still returns its output" \
  || bad "a successful run's output was lost: $out3"
grep -qi 'refused model' "$TMP/err3.txt" \
  && bad "a SUCCESSFUL run's warning wrongly cleared the catalog (would thrash the catalog on every run)" \
  || ok "a successful run's 'not supported' warning does not clear the catalog"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
